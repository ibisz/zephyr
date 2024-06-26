/*
 * Copyright (c) 2019 Intel Corporation
 * SPDX-License-Identifier: Apache-2.0
 */
#define LOAPIC_BASE_ADDRESS DT_REG_ADDR(DT_NODELABEL(intc_loapic))

#include <zephyr/toolchain.h>
#include <zephyr/arch/x86/multiboot.h>
#include <zephyr/arch/x86/efi.h>
#include <zephyr/sys/util.h>
#include <zephyr/arch/x86/msr.h>
#include <kernel_arch_data.h>
#include <offsets_short.h>
#include <zephyr/drivers/interrupt_controller/loapic.h>
#include <zephyr/arch/cpu.h>
#include <zephyr/kernel/mm.h>

/*
 * Definitions/macros for enabling paging
 */

/* Long mode, no-execute, syscall */
#define EFER_BITS (X86_EFER_MSR_LME | X86_EFER_MSR_NXE | X86_EFER_MSR_SCE)

/* Paging, write-protect */
#define CR0_BITS (CR0_PG | CR0_WP)

/* PAE, SSE */
#define CR4_BITS (CR4_PAE | CR4_OSFXSR)

.macro set_efer
	movl $X86_EFER_MSR, %ecx
	rdmsr
	orl $EFER_BITS, %eax
	wrmsr
.endm

.macro install_pagetables_32
	movl %cr4, %eax
	orl $CR4_BITS, %eax
	movl %eax, %cr4
	clts

	/* Page tables created at build time by gen_mmu.py
	 * NOTE: Presumes phys=virt
	 */
	movl $K_MEM_PHYS_ADDR(z_x86_kernel_ptables), %eax
	movl %eax, %cr3

	set_efer

	movl %cr0, %eax
	orl $CR0_BITS, %eax
	movl %eax, %cr0
.endm

.macro install_pagetables_64
	/* Here, we are already in long mode with paging enabled and
	 * just need to switch to our own page tables, but let's be
	 * paranoid and ensure CR4, CR0, and EFER_MSR are set up
	 * exactly how we expect. Logic is the same as install_pagetables_32
	 */
	movq %cr4, %rax
	orq $CR4_BITS, %rax
	movq %rax, %cr4
	clts

	/* NOTE: Presumes phys=virt */
	movq $K_MEM_PHYS_ADDR(z_x86_kernel_ptables), %rax
	movq %rax, %cr3

	set_efer

	movq %cr0, %rax
	/* Use 32-bit instructions due to assembler fussiness with large
	 * immediate values with `orq`, CR0_PG is bit 31. We don't ever set any
	 * high bits in cr0 anyway.
	 */
	orl $CR0_BITS, %eax
	movq %rax, %cr0
.endm

.macro DEFINE_TSS_STACK_ARRAY
	.irp idx, DEFINE_STACK_ARRAY_IDX
		.word __X86_TSS64_SIZEOF-1
		.word tss\idx
		.word 0x8900
		.word 0, 0, 0, 0, 0
	.endr
.endm

/* The .locore section begins the page-aligned initialization region
 * of low memory.  The first address is used as the architectural
 * entry point for auxiliary CPUs being brought up (in real mode!)
 * via a startup IPI.  It's is ALSO used by some loaders (well,
 * ACRN...) who hard-coded the address by inspecting _start on a
 * non-SMP build.
 *
 *               === OUTRAGEOUS HACK FOLLOWS ===
 *
 * Therefore it needs to start at OS entry with a 32 bit jump to the
 * 32 bit entry point, and gets clobbered later (see the beginning of
 * __start32) with NOP bytes such that the next CPU will fall through
 * to the 16 bit SMP entry.
 *
 * We write out the JMP followed by 8 NOPs for simplicity.  No i386
 * JMP encodes with more than 8 bytes, so we can come back later and
 * scribble over it with 8 0x90 bytes (which is the 1-byte NOP) and be
 * sure to get all of it without overwriting anything.
 */
.section .locore,"ax"
.code32
.globl __start
__start:
	jmp __start32
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop

.code16
.global x86_ap_start
x86_ap_start:
	/*
	 * First, we move to 32-bit protected mode, and set up the
	 * same flat environment that the BSP gets from the loader.
	 */
	lgdt gdt48
	lidt idt48
	movl %cr0, %eax
	or $1, %eax
	movl %eax, %cr0

	jmpl $X86_KERNEL_CS_32, $1f
.code32
1:	movw $X86_KERNEL_DS_32, %ax
	movw %ax, %ds
	movw %ax, %es
	movw %ax, %ss
	movw %ax, %fs

	/*
	 * Now, reverse-map our local APIC ID to our logical CPU ID
	 * so we can locate our x86_cpuboot[] bundle. Put it in EBP.
	 */

	movl LOAPIC_BASE_ADDRESS+LOAPIC_ID, %eax
	shrl $24, %eax
	andl $0xFF, %eax		/* local APIC ID -> EAX */

	movl $x86_cpuboot, %ebp
	xorl %ebx, %ebx
1:	cmpl $CONFIG_MP_MAX_NUM_CPUS, %ebx
	jz unknown_loapic_id
	cmpb %al, x86_cpu_loapics(%ebx)
	je go64				/* proceed to 64-bit mode */
	incl %ebx
	addl $__X86_CPUBOOT_SIZEOF, %ebp
	jmp 1b

unknown_loapic_id:
	jmp unknown_loapic_id

.code32
.globl __start32
__start32:
	/*
	 * kernel execution begins here in 32-bit mode, with flat-mode
	 * descriptors in all segment registers, interrupts disabled.
	 */

	/* See note above, re: OUTRAGEOUS HACK */
	movl $__start, %ebp
	movb $0x90, 0(%ebp)
	movb $0x90, 1(%ebp)
	movb $0x90, 2(%ebp)
	movb $0x90, 3(%ebp)
	movb $0x90, 4(%ebp)
	movb $0x90, 5(%ebp)
	movb $0x90, 6(%ebp)
	movb $0x90, 7(%ebp)
	wbinvd

	lgdt gdt48
	lidt idt48

#include "../common.S"

	/*
	 * N.B.: if multiboot info struct is present, "common.S"
	 * has left a pointer to it in EBX.
	 */

	movl $x86_cpu_boot_arg, %ebp

	/* Inserting boot type */
	movl $MULTIBOOT_BOOT_TYPE, __x86_boot_arg_t_boot_type_OFFSET(%ebp)
	/* and multiboot info */
	movl %ebx, __x86_boot_arg_t_arg_OFFSET(%ebp)

	movl $x86_cpuboot, %ebp         /* BSP is always logical CPU id 0 */

go64:	/* Install page tables and transition to long mode */
	install_pagetables_32
	jmpl $X86_KERNEL_CS, $enter_code64

	/* Long mode entry point.  Arrive here from the code
	 * immediately above (shared between main CPU startup and AP
	 * startup), or from EFI entry in __start64.
	 *
	 * Here we reload the segment registers,
	 * and configure per-CPU stuff: GS, task register, stack.
	 */
	.code64
enter_code64:
	movl $X86_KERNEL_DS, %eax
	movw %ax, %ds
	movw %ax, %es
	movw %ax, %ss
	movw %ax, %fs

	/* On Intel processors, if GS is not zero and is being set to
	 * zero, GS_BASE is also being set to zero. This would interfere
	 * with the actual use of GS_BASE for usespace. To avoid accidentally
	 * clearing GS_BASE, simply set GS to 0 at boot, so any subsequent
	 * clearing of GS will not clear GS_BASE.
	 */
	mov $0, %eax
	movw %ax, %gs

	movw __x86_cpuboot_t_tr_OFFSET(%rbp), %ax
	ltr %ax

	/* Set up MSRs for GS / KERNEL_GS base */
	movq __x86_cpuboot_t_gs_base_OFFSET(%rbp), %rax
	movq %rax, %rdx
	shrq $32, %rdx
	/* X86_KERNEL_GS_BASE and X86_GS_BASE are swapped by the 'swapgs'
	 * instruction.
	 */
	movl $X86_KERNEL_GS_BASE, %ecx
	wrmsr
	/* X86_GS_BASE shadows base fields of %gs, effectively setting %gs */
	movl $X86_GS_BASE, %ecx
	wrmsr

	movq __x86_cpuboot_t_sp_OFFSET(%rbp), %rsp
	movq %rsp, %gs:__x86_tss64_t_ist1_OFFSET

	/* finally, complete environment for the C runtime and go. */
	cld	/* GCC presumes a clear direction flag */

#ifdef CONFIG_INIT_STACKS
	movq $0xAAAAAAAAAAAAAAAA, %rax
	movq %rsp, %rdi
	subq __x86_cpuboot_t_stack_size_OFFSET(%rbp), %rdi
	movq __x86_cpuboot_t_stack_size_OFFSET(%rbp), %rcx
	shr $3, %rcx /* moving 8 bytes a time, so fewer repeats */
	rep stosq
#endif

#ifdef CONFIG_STACK_CANARIES_TLS
	movq %rsp, %rdi
	pushq %rsp
	call z_x86_early_tls_update_gdt
	popq %rsp
#endif

	/* Enter C domain now that we have a stack set up, never to return */
	movq %rbp, %rdi

	call z_x86_cpu_init

	/* 64 bit OS entry point, used by EFI support.  UEFI
	 * guarantees an identity-mapped page table that covers
	 * physical memory, and the loader stub already used it to
	 * write all of the Zephyr image, so we know it works for what
	 * we need.  Other things need fixups to match what multiboot
	 * 32 bit startup does.
	 */
.globl __start64
__start64:
	/* Zero the TSC */
	xorq %rax, %rax
	xorq %rdx, %rdx
	movq $X86_TIME_STAMP_COUNTER_MSR, %rcx
	wrmsr

	lidt idt80
	lgdt gdt80

	install_pagetables_64

	/* Disable 8259 PIT.  Almost certainly not needed on modern
	 * UEFI platforms taking this code path, but...
	 */
	movb $0xff, %al
	outb %al, $0x21
	outb %al, $0xA1

	movq $x86_cpu_boot_arg, %rbp
	/* Inserting boot type */
	movq $EFI_BOOT_TYPE, __x86_boot_arg_t_boot_type_OFFSET(%rbp)
	/* and EFI boot arg (if any) */
	movq %rbx, __x86_boot_arg_t_arg_OFFSET(%rbp)

	movq $x86_cpuboot, %rbp		/* BSP is always logical CPU id 0 */

	mov jmpdesc, %rax
	jmp *%rax
jmpdesc:
	.quad enter_code64
	.short X86_KERNEL_CS

/*
 * void x86_sse_init(struct k_thread *thread);
 *
 * Initialize floating-point state to something sane. If 'thread' is
 * not NULL, then the resulting FP state is saved to thread->arch.sse.
 */

.global x86_sse_init
x86_sse_init:
	fninit
	ldmxcsr mxcsr
	testq %rdi, %rdi
	jz 1f
	fxsave _thread_offset_to_sse(%rdi)
1:	retq

mxcsr:	.long X86_MXCSR_SANE

/*
 * void z_x86_switch(void *switch_to, void **switched_from);
 *
 * Note that switch_handle for us is simply a pointer to the containing
 * 'struct k_thread', thus:
 *
 * RDI = (struct k_thread *) switch_to
 * RSI = (struct k_thread **) address of output thread switch_handle field
 */

.globl z_x86_switch
z_x86_switch:
	/* RSI contains the switch_handle field to which we are
	 * notionally supposed to store.  Offset it to get back to the
	 * thread handle instead.
	 */
	subq $___thread_t_switch_handle_OFFSET, %rsi

	andb $~X86_THREAD_FLAG_ALL, _thread_offset_to_flags(%rsi)

	popq %rax
	movq %rax, _thread_offset_to_rip(%rsi)
	pushfq
	popq %rax
	movq %rax, _thread_offset_to_rflags(%rsi)
	movq %rsp, _thread_offset_to_rsp(%rsi)
	movq %rbx, _thread_offset_to_rbx(%rsi)
	movq %rbp, _thread_offset_to_rbp(%rsi)
	movq %r12, _thread_offset_to_r12(%rsi)
	movq %r13, _thread_offset_to_r13(%rsi)
	movq %r14, _thread_offset_to_r14(%rsi)
	movq %r15, _thread_offset_to_r15(%rsi)
#ifdef CONFIG_USERSPACE
	/* We're always in supervisor mode if we get here, the other case
	 * is when __resume is invoked from irq_dispatch
	 */
	movq $X86_KERNEL_CS, _thread_offset_to_cs(%rsi)
	movq $X86_KERNEL_DS, _thread_offset_to_ss(%rsi)
#endif
	/* Store the handle (i.e. our thread struct address) into the
	 * switch handle field, this is a synchronization signal that
	 * must occur after the last data from the old context is
	 * saved.
	 */
	movq %rsi, ___thread_t_switch_handle_OFFSET(%rsi)

	movq %gs:__x86_tss64_t_ist1_OFFSET, %rsp

	/* fall through to __resume */

/*
 * Entry:
 *   RSP = top of CPU interrupt stack
 *   RDI = (struct k_thread *) thread to resume
 */

__resume:
#ifdef CONFIG_THREAD_LOCAL_STORAGE
	/*
	 * Write the TLS base pointer to FS_BASE MSR,
	 * where GCC emits code to access TLS data via
	 * offset to FS.
	 * Since wrmsr write EDX:EAX to MSR indicated by
	 * ECX, the high 32-bit needs to be loaded into
	 * RDX and right shifted by 32 bits so EDX has
	 * the higher 32-bit value.
	 */
	movl $X86_FS_BASE, %ecx
	movq _thread_offset_to_tls(%rdi), %rax
	movq _thread_offset_to_tls(%rdi), %rdx
	shrq $32, %rdx
	wrmsr
#endif
#if (!defined(CONFIG_X86_KPTI) && defined(CONFIG_USERSPACE)) \
		|| defined(CONFIG_INSTRUMENT_THREAD_SWITCHING)
	pushq %rdi	/* Caller-saved, stash it */
#if !defined(CONFIG_X86_KPTI) && defined(CONFIG_USERSPACE)
	/* If KPTI is enabled we're always on the kernel's page tables in
	 * this context and the appropriate page table switch takes place
	 * when trampolining back to user mode
	 */
	call z_x86_swap_update_page_tables
#endif
#ifdef CONFIG_INSTRUMENT_THREAD_SWITCHING
	call z_thread_mark_switched_in
#endif
	popq %rdi
#endif /* (!CONFIG_X86_KPTI && CONFIG_USERSPACE) || \
	   CONFIG_INSTRUMENT_THREAD_SWITCHING */

#ifdef CONFIG_USERSPACE
	/* Set up exception return stack frame */
	pushq _thread_offset_to_ss(%rdi)	/* SS */
#else
	pushq $X86_KERNEL_DS			/* SS */
#endif /* CONFIG_USERSPACE */
	pushq _thread_offset_to_rsp(%rdi)	/* RSP */
	pushq _thread_offset_to_rflags(%rdi)	/* RFLAGS */
#ifdef CONFIG_USERSPACE
	pushq _thread_offset_to_cs(%rdi)	/* CS */
#else
	pushq $X86_KERNEL_CS			/* CS */
#endif
	pushq _thread_offset_to_rip(%rdi)	/* RIP */

#ifdef CONFIG_ASSERT
	/* Poison the old thread's saved RIP pointer with a
	 * recognizable value near NULL, to easily catch reuse of the
	 * thread object across CPUs in SMP.  Strictly speaking this
	 * is not an assertion, but it's very cheap and worth having
	 * on during routine testing.
	 */
	movq $0xB9, _thread_offset_to_rip(%rdi)
#endif


	movq _thread_offset_to_rbx(%rdi), %rbx
	movq _thread_offset_to_rbp(%rdi), %rbp
	movq _thread_offset_to_r12(%rdi), %r12
	movq _thread_offset_to_r13(%rdi), %r13
	movq _thread_offset_to_r14(%rdi), %r14
	movq _thread_offset_to_r15(%rdi), %r15
#ifdef CONFIG_USERSPACE
	/* Set correct privilege elevation stack to manually switch to in
	 * z_x86_syscall_entry_stub()
	 */
	movq _thread_offset_to_psp(%rdi), %rax
	movq %rax, %gs:__x86_tss64_t_psp_OFFSET
#endif

	testb $X86_THREAD_FLAG_ALL, _thread_offset_to_flags(%rdi)
	jz 1f

	fxrstor _thread_offset_to_sse(%rdi)
	movq _thread_offset_to_rax(%rdi), %rax
	movq _thread_offset_to_rcx(%rdi), %rcx
	movq _thread_offset_to_rdx(%rdi), %rdx
	movq _thread_offset_to_rsi(%rdi), %rsi
	movq _thread_offset_to_r8(%rdi), %r8
	movq _thread_offset_to_r9(%rdi), %r9
	movq _thread_offset_to_r10(%rdi), %r10
	movq _thread_offset_to_r11(%rdi), %r11
	movq _thread_offset_to_rdi(%rdi), %rdi  /* do last :-) */

#ifdef CONFIG_USERSPACE
	/* Swap GS register values if we are returning to user mode */
	testb $0x3, 8(%rsp)
	jz 1f
#ifdef CONFIG_X86_KPTI
	jmp z_x86_trampoline_to_user
#else
	swapgs
#endif /* CONFIG_X86_KPTI */
#endif /* CONFIG_USERSPACE */
1:
#ifdef CONFIG_X86_BOUNDS_CHECK_BYPASS_MITIGATION
	/* swapgs variant of Spectre V1. Disable speculation past this point */
	lfence
#endif /* CONFIG_X86_BOUNDS_CHECK_BYPASS_MITIGATION */
	iretq


#ifdef CONFIG_X86_KPTI
#define EXCEPT_CODE(nr, ist)						\
	vector_ ## nr: pushq %gs:__x86_tss64_t_ist ## ist ## _OFFSET;	\
	pushq $nr;							\
	jmp except
#define EXCEPT(nr, ist)							\
	vector_ ## nr: pushq $0;					\
	pushq %gs:__x86_tss64_t_ist ## ist ## _OFFSET;			\
	pushq $nr; \
	jmp except
#else
#define EXCEPT_CODE(nr) vector_ ## nr: pushq $nr; jmp except
#define EXCEPT(nr)	vector_ ## nr: pushq $0; pushq $nr; jmp except
#endif

/*
 * When we arrive at 'except' from one of the EXCEPT(X) stubs,
 * we're on the exception stack with irqs unlocked (or the trampoline stack
 * with irqs locked if KPTI is enabled) and it contains:
 *
 *   SS
 *   RSP
 *   RFLAGS
 *   CS
 *   RIP
 *   Error Code if pushed by CPU, else 0
 *   IST index in TSS
 *   Vector number <- RSP points here
 *
 */

except: /*
	 * finish struct NANO_ESF on stack. 'vector' .. 'ss' are
	 * already there from hardware trap and EXCEPT_*() stub.
	 */

	pushq %r11

#ifdef CONFIG_USERSPACE
	/* Swap GS register values and page tables if we came from user mode */
	testb $0x3, 40(%rsp)
	jz 1f
	swapgs
#ifdef CONFIG_X86_KPTI
	/* Load kernel's page table. NOTE: Presumes phys=virt */
	movq $z_x86_kernel_ptables, %r11
	movq %r11, %cr3
#endif /* CONFIG_X86_KPTI */
1:
#ifdef CONFIG_X86_BOUNDS_CHECK_BYPASS_MITIGATION
	/* swapgs variant of Spectre V1. Disable speculation past this point */
	lfence
#endif /* CONFIG_X86_BOUNDS_CHECK_BYPASS_MITIGATION */
#ifdef CONFIG_X86_KPTI
	/* Save old trampoline stack pointer in R11 */
	movq %rsp, %r11

	/* Switch to the correct stack */
	movq 16(%r11), %rsp

	/* Transplant trampoline stack contents */
	pushq 64(%r11)	/* SS */
	pushq 56(%r11)	/* RSP */
	pushq 48(%r11)	/* RFLAGS */
	pushq 40(%r11)	/* CS */
	pushq 32(%r11)	/* RIP */
	pushq 24(%r11)	/* Error code */
	pushq 8(%r11)	/* Vector */
	pushq (%r11)	/* Stashed R11 */
	movq $0, (%r11) /* Cover our tracks */

	/* We're done, it's safe to re-enable interrupts. */
	sti
#endif /* CONFIG_X86_KPTI */
#endif /* CONFIG_USERSPACE */

	/* In addition to r11, push the rest of the caller-saved regs */
	/* Positioning of this fxsave is important, RSP must be 16-byte
	 * aligned
	 */
	subq $X86_FXSAVE_SIZE, %rsp
	fxsave (%rsp)
	pushq %r10
	pushq %r9
	pushq %r8
	pushq %rdi
	pushq %rsi
	pushq %rdx
	pushq %rcx
	pushq %rax
	pushq %rbp
#ifdef CONFIG_EXCEPTION_DEBUG
	/* Callee saved regs */
	pushq %r15
	pushq %r14
	pushq %r13
	pushq %r12
	pushq %rbx
#endif /* CONFIG_EXCEPTION_DEBUG */
	movq %rsp, %rdi

	call z_x86_exception

	/* If we returned, the exception was handled successfully and the
	 * thread may resume (the pushed RIP may have been modified)
	 */
#ifdef CONFIG_EXCEPTION_DEBUG
	popq %rbx
	popq %r12
	popq %r13
	popq %r14
	popq %r15
#endif /* CONFIG_EXCEPTION_DEBUG */
	popq %rbp
	popq %rax
	popq %rcx
	popq %rdx
	popq %rsi
	popq %rdi
	popq %r8
	popq %r9
	popq %r10
	fxrstor (%rsp)
	addq $X86_FXSAVE_SIZE, %rsp
	popq %r11

	/* Drop the vector/err code pushed by the HW or EXCEPT_*() stub */
	add $16, %rsp

#ifdef CONFIG_USERSPACE
	/* Swap GS register values if we are returning to user mode */
	testb $0x3, 8(%rsp)
	jz 1f
	cli
#ifdef CONFIG_X86_KPTI
	jmp z_x86_trampoline_to_user
#else
	swapgs
#endif /* CONFIG_X86_KPTI */
1:
#endif /* CONFIG_USERSPACE */

	iretq

#ifdef CONFIG_X86_KPTI
EXCEPT      ( 0, 7); EXCEPT      ( 1, 7); EXCEPT       (2, 6); EXCEPT      ( 3, 7)
EXCEPT      ( 4, 7); EXCEPT      ( 5, 7); EXCEPT       (6, 7); EXCEPT      ( 7, 7)
EXCEPT_CODE ( 8, 7); EXCEPT      ( 9, 7); EXCEPT_CODE (10, 7); EXCEPT_CODE (11, 7)
EXCEPT_CODE (12, 7); EXCEPT_CODE (13, 7); EXCEPT_CODE (14, 7); EXCEPT      (15, 7)
EXCEPT      (16, 7); EXCEPT_CODE (17, 7); EXCEPT      (18, 7); EXCEPT      (19, 7)
EXCEPT      (20, 7); EXCEPT      (21, 7); EXCEPT      (22, 7); EXCEPT      (23, 7)
EXCEPT      (24, 7); EXCEPT      (25, 7); EXCEPT      (26, 7); EXCEPT      (27, 7)
EXCEPT      (28, 7); EXCEPT      (29, 7); EXCEPT      (30, 7); EXCEPT      (31, 7)

/* Vector reserved for handling a kernel oops; treat as an exception
 * and not an interrupt
 */
EXCEPT(Z_X86_OOPS_VECTOR, 7);
#else
EXCEPT      ( 0); EXCEPT      ( 1); EXCEPT      ( 2); EXCEPT      ( 3)
EXCEPT      ( 4); EXCEPT      ( 5); EXCEPT      ( 6); EXCEPT      ( 7)
EXCEPT_CODE ( 8); EXCEPT      ( 9); EXCEPT_CODE (10); EXCEPT_CODE (11)
EXCEPT_CODE (12); EXCEPT_CODE (13); EXCEPT_CODE (14); EXCEPT      (15)
EXCEPT      (16); EXCEPT_CODE (17); EXCEPT      (18); EXCEPT      (19)
EXCEPT      (20); EXCEPT      (21); EXCEPT      (22); EXCEPT      (23)
EXCEPT      (24); EXCEPT      (25); EXCEPT      (26); EXCEPT      (27)
EXCEPT      (28); EXCEPT      (29); EXCEPT      (30); EXCEPT      (31)

/* Vector reserved for handling a kernel oops; treat as an exception
 * and not an interrupt
 */
EXCEPT(Z_X86_OOPS_VECTOR);
#endif /* CONFIG_X86_KPTI */

/*
 * When we arrive at 'irq' from one of the IRQ(X) stubs,
 * we're on the "freshest" IRQ stack (or the trampoline stack if we came from
 * user mode and KPTI is enabled) and it contains:
 *
 *   SS
 *   RSP
 *   RFLAGS
 *   CS
 *   RIP
 *   (vector number - IV_IRQS) <-- RSP points here
 */

.globl x86_irq_funcs	/* see irq_manage.c .. */
.globl x86_irq_args	/* .. for these definitions */

irq:
	pushq %rsi

#ifdef CONFIG_USERSPACE
	/* Swap GS register values if we came in from user mode */
	testb $0x3, 24(%rsp)
	jz 1f
	swapgs
#ifdef CONFIG_X86_KPTI
	/* Load kernel's page table. NOTE: presumes phys=virt */
	movq $z_x86_kernel_ptables, %rsi
	movq %rsi, %cr3
#endif /* CONFIG_X86_KPTI */
1:
#ifdef CONFIG_X86_BOUNDS_CHECK_BYPASS_MITIGATION
	/* swapgs variant of Spectre V1. Disable speculation past this point */
	lfence
#endif /* CONFIG_X86_BOUNDS_CHECK_BYPASS_MITIGATION */
#ifdef CONFIG_X86_KPTI
	/* Save old trampoline stack pointer in RSI */
	movq %rsp, %rsi

	/* Switch to the interrupt stack stack */
	movq %gs:__x86_tss64_t_ist1_OFFSET, %rsp

	/* Transplant trampoline stack contents */
	pushq 48(%rsi)	/* SS */
	pushq 40(%rsi)	/* RSP */
	pushq 32(%rsi)	/* RFLAGS */
	pushq 24(%rsi)	/* CS */
	pushq 16(%rsi)	/* RIP */
	pushq 8(%rsi)	/* Vector */
	pushq (%rsi)	/* Stashed RSI value */
	movq $0, (%rsi) /* Cover our tracks, stashed RSI might be sensitive */
#endif /* CONFIG_X86_KPTI */
#endif /* CONFIG_USERSPACE */

	movq %gs:__x86_tss64_t_cpu_OFFSET, %rsi

	/*
	 * Bump the IRQ nesting count and move to the next IRQ stack.
	 * That's sufficient to safely re-enable interrupts, so if we
	 * haven't reached the maximum nesting depth yet, do it.
	 */

	incl ___cpu_t_nested_OFFSET(%rsi)
	subq $CONFIG_ISR_SUBSTACK_SIZE, %gs:__x86_tss64_t_ist1_OFFSET
	cmpl $CONFIG_ISR_DEPTH, ___cpu_t_nested_OFFSET(%rsi)
	jz 1f
	sti
1:	cmpl $1, ___cpu_t_nested_OFFSET(%rsi)
	je irq_enter_unnested

	/*
	 * if we're a nested interrupt, we have to dump the state to the
	 * stack. we play some games here to re-arrange the stack thusly:
	 *
	 * SS RSP RFLAGS CS RIP RAX RSI
	 * RCX RDX RDI R8 R9 R10 R11
	 * X86_FXSAVE_SIZE bytes of SSE data <-- RSP points here
	 *
	 * note that the final value of RSP must be 16-byte aligned here,
	 * both to satisfy FXSAVE/FXRSTOR but also to honor the C ABI.
	 */

irq_enter_nested: /* Nested IRQ: dump register state to stack. */
	pushq %rcx
	movq 16(%rsp), %rcx /* RCX = vector */
	movq %rax, 16(%rsp) /* looks like we pushed RAX, not the vector */
	pushq %rdx
	pushq %rdi
	pushq %r8
	pushq %r9
	pushq %r10
	pushq %r11
	subq $X86_FXSAVE_SIZE, %rsp
	fxsave (%rsp)
	jmp irq_dispatch

irq_enter_unnested: /* Not nested: dump state to thread struct for __resume */
	movq ___cpu_t_current_OFFSET(%rsi), %rsi
	orb $X86_THREAD_FLAG_ALL, _thread_offset_to_flags(%rsi)
	fxsave _thread_offset_to_sse(%rsi)
	movq %rbx, _thread_offset_to_rbx(%rsi)
	movq %rbp, _thread_offset_to_rbp(%rsi)
	movq %r12, _thread_offset_to_r12(%rsi)
	movq %r13, _thread_offset_to_r13(%rsi)
	movq %r14, _thread_offset_to_r14(%rsi)
	movq %r15, _thread_offset_to_r15(%rsi)
	movq %rax, _thread_offset_to_rax(%rsi)
	movq %rcx, _thread_offset_to_rcx(%rsi)
	movq %rdx, _thread_offset_to_rdx(%rsi)
	movq %rdi, _thread_offset_to_rdi(%rsi)
	movq %r8, _thread_offset_to_r8(%rsi)
	movq %r9, _thread_offset_to_r9(%rsi)
	movq %r10, _thread_offset_to_r10(%rsi)
	movq %r11, _thread_offset_to_r11(%rsi)
	popq %rax /* RSI */
	movq %rax, _thread_offset_to_rsi(%rsi)
	popq %rcx /* vector number */
	popq %rax /* RIP */
	movq %rax, _thread_offset_to_rip(%rsi)
	popq %rax /* CS */
#ifdef CONFIG_USERSPACE
	movq %rax, _thread_offset_to_cs(%rsi)
#endif
	popq %rax /* RFLAGS */
	movq %rax, _thread_offset_to_rflags(%rsi)
	popq %rax /* RSP */
	movq %rax, _thread_offset_to_rsp(%rsi)
	popq %rax /* SS */
#ifdef CONFIG_USERSPACE
	movq %rax, _thread_offset_to_ss(%rsi)
#endif

irq_dispatch:
#ifdef CONFIG_SCHED_THREAD_USAGE
	pushq %rcx
	call z_sched_usage_stop
	popq %rcx
#endif
	movq x86_irq_funcs(,%rcx,8), %rax
	movq x86_irq_args(,%rcx,8), %rdi
	call *%rax

	xorq %rax, %rax
#ifdef CONFIG_X2APIC
	xorl %edx, %edx
	movl $(X86_X2APIC_BASE_MSR + (LOAPIC_EOI >> 4)), %ecx
	wrmsr
#else /* xAPIC */
	movq Z_TOPLEVEL_RAM_NAME(LOAPIC_REGS_STR), %rdx
	movl %eax, LOAPIC_EOI(%rdx)
#endif /* CONFIG_X2APIC */

	movq %gs:__x86_tss64_t_cpu_OFFSET, %rsi

	cli
	addq $CONFIG_ISR_SUBSTACK_SIZE, %gs:__x86_tss64_t_ist1_OFFSET
	decl ___cpu_t_nested_OFFSET(%rsi)
	jnz irq_exit_nested

	/* not nested; ask the scheduler who's up next and resume it */

	movq ___cpu_t_current_OFFSET(%rsi), %rdi
	call z_get_next_switch_handle
	movq %rax, %rdi
	jmp __resume

irq_exit_nested:
	fxrstor (%rsp)
	addq $X86_FXSAVE_SIZE, %rsp
	popq %r11
	popq %r10
	popq %r9
	popq %r8
	popq %rdi
	popq %rdx
	popq %rcx
	popq %rsi
	popq %rax
	iretq

#define IRQ(nr) vector_ ## nr: pushq $(nr - IV_IRQS); jmp irq

IRQ( 33); IRQ( 34); IRQ( 35); IRQ( 36); IRQ( 37); IRQ( 38); IRQ( 39)
IRQ( 40); IRQ( 41); IRQ( 42); IRQ( 43); IRQ( 44); IRQ( 45); IRQ( 46); IRQ( 47)
IRQ( 48); IRQ( 49); IRQ( 50); IRQ( 51); IRQ( 52); IRQ( 53); IRQ( 54); IRQ( 55)
IRQ( 56); IRQ( 57); IRQ( 58); IRQ( 59); IRQ( 60); IRQ( 61); IRQ( 62); IRQ( 63)
IRQ( 64); IRQ( 65); IRQ( 66); IRQ( 67); IRQ( 68); IRQ( 69); IRQ( 70); IRQ( 71)
IRQ( 72); IRQ( 73); IRQ( 74); IRQ( 75); IRQ( 76); IRQ( 77); IRQ( 78); IRQ( 79)
IRQ( 80); IRQ( 81); IRQ( 82); IRQ( 83); IRQ( 84); IRQ( 85); IRQ( 86); IRQ( 87)
IRQ( 88); IRQ( 89); IRQ( 90); IRQ( 91); IRQ( 92); IRQ( 93); IRQ( 94); IRQ( 95)
IRQ( 96); IRQ( 97); IRQ( 98); IRQ( 99); IRQ(100); IRQ(101); IRQ(102); IRQ(103)
IRQ(104); IRQ(105); IRQ(106); IRQ(107); IRQ(108); IRQ(109); IRQ(110); IRQ(111)
IRQ(112); IRQ(113); IRQ(114); IRQ(115); IRQ(116); IRQ(117); IRQ(118); IRQ(119)
IRQ(120); IRQ(121); IRQ(122); IRQ(123); IRQ(124); IRQ(125); IRQ(126); IRQ(127)
IRQ(128); IRQ(129); IRQ(130); IRQ(131); IRQ(132); IRQ(133); IRQ(134); IRQ(135)
IRQ(136); IRQ(137); IRQ(138); IRQ(139); IRQ(140); IRQ(141); IRQ(142); IRQ(143)
IRQ(144); IRQ(145); IRQ(146); IRQ(147); IRQ(148); IRQ(149); IRQ(150); IRQ(151)
IRQ(152); IRQ(153); IRQ(154); IRQ(155); IRQ(156); IRQ(157); IRQ(158); IRQ(159)
IRQ(160); IRQ(161); IRQ(162); IRQ(163); IRQ(164); IRQ(165); IRQ(166); IRQ(167)
IRQ(168); IRQ(169); IRQ(170); IRQ(171); IRQ(172); IRQ(173); IRQ(174); IRQ(175)
IRQ(176); IRQ(177); IRQ(178); IRQ(179); IRQ(180); IRQ(181); IRQ(182); IRQ(183)
IRQ(184); IRQ(185); IRQ(186); IRQ(187); IRQ(188); IRQ(189); IRQ(190); IRQ(191)
IRQ(192); IRQ(193); IRQ(194); IRQ(195); IRQ(196); IRQ(197); IRQ(198); IRQ(199)
IRQ(200); IRQ(201); IRQ(202); IRQ(203); IRQ(204); IRQ(205); IRQ(206); IRQ(207)
IRQ(208); IRQ(209); IRQ(210); IRQ(211); IRQ(212); IRQ(213); IRQ(214); IRQ(215)
IRQ(216); IRQ(217); IRQ(218); IRQ(219); IRQ(220); IRQ(221); IRQ(222); IRQ(223)
IRQ(224); IRQ(225); IRQ(226); IRQ(227); IRQ(228); IRQ(229); IRQ(230); IRQ(231)
IRQ(232); IRQ(233); IRQ(234); IRQ(235); IRQ(236); IRQ(237); IRQ(238); IRQ(239)
IRQ(240); IRQ(241); IRQ(242); IRQ(243); IRQ(244); IRQ(245); IRQ(246); IRQ(247)
IRQ(248); IRQ(249); IRQ(250); IRQ(251); IRQ(252); IRQ(253); IRQ(254); IRQ(255)

.section .lorodata,"a"

/*
 * IDT.
 */

/* Descriptor type. Traps don't implicitly disable interrupts. User variants
 * can be invoked by software running in user mode (ring 3).
 *
 * For KPTI everything lands on the trampoline stack and we must get off of
 * it before re-enabling interrupts; use interrupt gates for everything.
 */
#define INTR		0x8e
#define USER_INTR	0xee
#ifdef CONFIG_X86_KPTI
#define TRAP		INTR
#define USER_TRAP	UINTR
#else
#define TRAP		0x8f
#define USER_TRAP	0xef
#endif

#define IDT(nr, type, ist) \
	.word vector_ ## nr, X86_KERNEL_CS; \
	.byte ist, type; \
	.word 0, 0, 0, 0, 0

/* Which IST entry in TSS to use for automatic stack switching, or 0 if
 * no automatic switch is to take place. Stack page must be present in
 * the current page tables, if KPTI is on only the trampoline stack and
 * the current user stack can be accessed.
 */
#ifdef CONFIG_X86_KPTI
/* Everything lands on ist2, which is set to the trampoline stack.
 * Interrupt/exception entry updates page tables and manually switches to
 * the irq/exception stacks stored in ist1/ist7
 */
#define	IRQ_STACK	2
#define EXC_STACK	2
#define BAD_STACK	2
#define NMI_STACK	2
#else
#define	IRQ_STACK	1
#define NMI_STACK	6 /* NMI stack */
#define EXC_STACK	7
#define BAD_STACK	7 /* Horrible things: double faults, MCEs */
#endif

.align 16
idt:
	IDT(  0, TRAP, EXC_STACK); IDT(  1, TRAP, EXC_STACK)
	IDT(  2, TRAP, NMI_STACK); IDT(  3, TRAP, EXC_STACK)
	IDT(  4, TRAP, EXC_STACK); IDT(  5, TRAP, EXC_STACK)
	IDT(  6, TRAP, EXC_STACK); IDT(  7, TRAP, EXC_STACK)
	IDT(  8, TRAP, BAD_STACK); IDT(  9, TRAP, EXC_STACK)
	IDT( 10, TRAP, EXC_STACK); IDT( 11, TRAP, EXC_STACK)
	IDT( 12, TRAP, EXC_STACK); IDT( 13, TRAP, EXC_STACK)
	IDT( 14, TRAP, EXC_STACK); IDT( 15, TRAP, EXC_STACK)
	IDT( 16, TRAP, EXC_STACK); IDT( 17, TRAP, EXC_STACK)
	IDT( 18, TRAP, BAD_STACK); IDT( 19, TRAP, EXC_STACK)
	IDT( 20, TRAP, EXC_STACK); IDT( 21, TRAP, EXC_STACK)
	IDT( 22, TRAP, EXC_STACK); IDT( 23, TRAP, EXC_STACK)
	IDT( 24, TRAP, EXC_STACK); IDT( 25, TRAP, EXC_STACK)
	IDT( 26, TRAP, EXC_STACK); IDT( 27, TRAP, EXC_STACK)
	IDT( 28, TRAP, EXC_STACK); IDT( 29, TRAP, EXC_STACK)
	IDT( 30, TRAP, EXC_STACK); IDT( 31, TRAP, EXC_STACK)

	/* Oops vector can be invoked from Ring 3 and runs on exception stack */
	IDT(Z_X86_OOPS_VECTOR, USER_INTR, EXC_STACK); IDT( 33, INTR, IRQ_STACK)
	IDT( 34, INTR, IRQ_STACK); IDT( 35, INTR, IRQ_STACK)
	IDT( 36, INTR, IRQ_STACK); IDT( 37, INTR, IRQ_STACK)
	IDT( 38, INTR, IRQ_STACK); IDT( 39, INTR, IRQ_STACK)
	IDT( 40, INTR, IRQ_STACK); IDT( 41, INTR, IRQ_STACK)
	IDT( 42, INTR, IRQ_STACK); IDT( 43, INTR, IRQ_STACK)
	IDT( 44, INTR, IRQ_STACK); IDT( 45, INTR, IRQ_STACK)
	IDT( 46, INTR, IRQ_STACK); IDT( 47, INTR, IRQ_STACK)
	IDT( 48, INTR, IRQ_STACK); IDT( 49, INTR, IRQ_STACK)
	IDT( 50, INTR, IRQ_STACK); IDT( 51, INTR, IRQ_STACK)
	IDT( 52, INTR, IRQ_STACK); IDT( 53, INTR, IRQ_STACK)
	IDT( 54, INTR, IRQ_STACK); IDT( 55, INTR, IRQ_STACK)
	IDT( 56, INTR, IRQ_STACK); IDT( 57, INTR, IRQ_STACK)
	IDT( 58, INTR, IRQ_STACK); IDT( 59, INTR, IRQ_STACK)
	IDT( 60, INTR, IRQ_STACK); IDT( 61, INTR, IRQ_STACK)
	IDT( 62, INTR, IRQ_STACK); IDT( 63, INTR, IRQ_STACK)
	IDT( 64, INTR, IRQ_STACK); IDT( 65, INTR, IRQ_STACK)
	IDT( 66, INTR, IRQ_STACK); IDT( 67, INTR, IRQ_STACK)
	IDT( 68, INTR, IRQ_STACK); IDT( 69, INTR, IRQ_STACK)
	IDT( 70, INTR, IRQ_STACK); IDT( 71, INTR, IRQ_STACK)
	IDT( 72, INTR, IRQ_STACK); IDT( 73, INTR, IRQ_STACK)
	IDT( 74, INTR, IRQ_STACK); IDT( 75, INTR, IRQ_STACK)
	IDT( 76, INTR, IRQ_STACK); IDT( 77, INTR, IRQ_STACK)
	IDT( 78, INTR, IRQ_STACK); IDT( 79, INTR, IRQ_STACK)
	IDT( 80, INTR, IRQ_STACK); IDT( 81, INTR, IRQ_STACK)
	IDT( 82, INTR, IRQ_STACK); IDT( 83, INTR, IRQ_STACK)
	IDT( 84, INTR, IRQ_STACK); IDT( 85, INTR, IRQ_STACK)
	IDT( 86, INTR, IRQ_STACK); IDT( 87, INTR, IRQ_STACK)
	IDT( 88, INTR, IRQ_STACK); IDT( 89, INTR, IRQ_STACK)
	IDT( 90, INTR, IRQ_STACK); IDT( 91, INTR, IRQ_STACK)
	IDT( 92, INTR, IRQ_STACK); IDT( 93, INTR, IRQ_STACK)
	IDT( 94, INTR, IRQ_STACK); IDT( 95, INTR, IRQ_STACK)
	IDT( 96, INTR, IRQ_STACK); IDT( 97, INTR, IRQ_STACK)
	IDT( 98, INTR, IRQ_STACK); IDT( 99, INTR, IRQ_STACK)
	IDT(100, INTR, IRQ_STACK); IDT(101, INTR, IRQ_STACK)
	IDT(102, INTR, IRQ_STACK); IDT(103, INTR, IRQ_STACK)
	IDT(104, INTR, IRQ_STACK); IDT(105, INTR, IRQ_STACK)
	IDT(106, INTR, IRQ_STACK); IDT(107, INTR, IRQ_STACK)
	IDT(108, INTR, IRQ_STACK); IDT(109, INTR, IRQ_STACK)
	IDT(110, INTR, IRQ_STACK); IDT(111, INTR, IRQ_STACK)
	IDT(112, INTR, IRQ_STACK); IDT(113, INTR, IRQ_STACK)
	IDT(114, INTR, IRQ_STACK); IDT(115, INTR, IRQ_STACK)
	IDT(116, INTR, IRQ_STACK); IDT(117, INTR, IRQ_STACK)
	IDT(118, INTR, IRQ_STACK); IDT(119, INTR, IRQ_STACK)
	IDT(120, INTR, IRQ_STACK); IDT(121, INTR, IRQ_STACK)
	IDT(122, INTR, IRQ_STACK); IDT(123, INTR, IRQ_STACK)
	IDT(124, INTR, IRQ_STACK); IDT(125, INTR, IRQ_STACK)
	IDT(126, INTR, IRQ_STACK); IDT(127, INTR, IRQ_STACK)
	IDT(128, INTR, IRQ_STACK); IDT(129, INTR, IRQ_STACK)
	IDT(130, INTR, IRQ_STACK); IDT(131, INTR, IRQ_STACK)
	IDT(132, INTR, IRQ_STACK); IDT(133, INTR, IRQ_STACK)
	IDT(134, INTR, IRQ_STACK); IDT(135, INTR, IRQ_STACK)
	IDT(136, INTR, IRQ_STACK); IDT(137, INTR, IRQ_STACK)
	IDT(138, INTR, IRQ_STACK); IDT(139, INTR, IRQ_STACK)
	IDT(140, INTR, IRQ_STACK); IDT(141, INTR, IRQ_STACK)
	IDT(142, INTR, IRQ_STACK); IDT(143, INTR, IRQ_STACK)
	IDT(144, INTR, IRQ_STACK); IDT(145, INTR, IRQ_STACK)
	IDT(146, INTR, IRQ_STACK); IDT(147, INTR, IRQ_STACK)
	IDT(148, INTR, IRQ_STACK); IDT(149, INTR, IRQ_STACK)
	IDT(150, INTR, IRQ_STACK); IDT(151, INTR, IRQ_STACK)
	IDT(152, INTR, IRQ_STACK); IDT(153, INTR, IRQ_STACK)
	IDT(154, INTR, IRQ_STACK); IDT(155, INTR, IRQ_STACK)
	IDT(156, INTR, IRQ_STACK); IDT(157, INTR, IRQ_STACK)
	IDT(158, INTR, IRQ_STACK); IDT(159, INTR, IRQ_STACK)
	IDT(160, INTR, IRQ_STACK); IDT(161, INTR, IRQ_STACK)
	IDT(162, INTR, IRQ_STACK); IDT(163, INTR, IRQ_STACK)
	IDT(164, INTR, IRQ_STACK); IDT(165, INTR, IRQ_STACK)
	IDT(166, INTR, IRQ_STACK); IDT(167, INTR, IRQ_STACK)
	IDT(168, INTR, IRQ_STACK); IDT(169, INTR, IRQ_STACK)
	IDT(170, INTR, IRQ_STACK); IDT(171, INTR, IRQ_STACK)
	IDT(172, INTR, IRQ_STACK); IDT(173, INTR, IRQ_STACK)
	IDT(174, INTR, IRQ_STACK); IDT(175, INTR, IRQ_STACK)
	IDT(176, INTR, IRQ_STACK); IDT(177, INTR, IRQ_STACK)
	IDT(178, INTR, IRQ_STACK); IDT(179, INTR, IRQ_STACK)
	IDT(180, INTR, IRQ_STACK); IDT(181, INTR, IRQ_STACK)
	IDT(182, INTR, IRQ_STACK); IDT(183, INTR, IRQ_STACK)
	IDT(184, INTR, IRQ_STACK); IDT(185, INTR, IRQ_STACK)
	IDT(186, INTR, IRQ_STACK); IDT(187, INTR, IRQ_STACK)
	IDT(188, INTR, IRQ_STACK); IDT(189, INTR, IRQ_STACK)
	IDT(190, INTR, IRQ_STACK); IDT(191, INTR, IRQ_STACK)
	IDT(192, INTR, IRQ_STACK); IDT(193, INTR, IRQ_STACK)
	IDT(194, INTR, IRQ_STACK); IDT(195, INTR, IRQ_STACK)
	IDT(196, INTR, IRQ_STACK); IDT(197, INTR, IRQ_STACK)
	IDT(198, INTR, IRQ_STACK); IDT(199, INTR, IRQ_STACK)
	IDT(200, INTR, IRQ_STACK); IDT(201, INTR, IRQ_STACK)
	IDT(202, INTR, IRQ_STACK); IDT(203, INTR, IRQ_STACK)
	IDT(204, INTR, IRQ_STACK); IDT(205, INTR, IRQ_STACK)
	IDT(206, INTR, IRQ_STACK); IDT(207, INTR, IRQ_STACK)
	IDT(208, INTR, IRQ_STACK); IDT(209, INTR, IRQ_STACK)
	IDT(210, INTR, IRQ_STACK); IDT(211, INTR, IRQ_STACK)
	IDT(212, INTR, IRQ_STACK); IDT(213, INTR, IRQ_STACK)
	IDT(214, INTR, IRQ_STACK); IDT(215, INTR, IRQ_STACK)
	IDT(216, INTR, IRQ_STACK); IDT(217, INTR, IRQ_STACK)
	IDT(218, INTR, IRQ_STACK); IDT(219, INTR, IRQ_STACK)
	IDT(220, INTR, IRQ_STACK); IDT(221, INTR, IRQ_STACK)
	IDT(222, INTR, IRQ_STACK); IDT(223, INTR, IRQ_STACK)
	IDT(224, INTR, IRQ_STACK); IDT(225, INTR, IRQ_STACK)
	IDT(226, INTR, IRQ_STACK); IDT(227, INTR, IRQ_STACK)
	IDT(228, INTR, IRQ_STACK); IDT(229, INTR, IRQ_STACK)
	IDT(230, INTR, IRQ_STACK); IDT(231, INTR, IRQ_STACK)
	IDT(232, INTR, IRQ_STACK); IDT(233, INTR, IRQ_STACK)
	IDT(234, INTR, IRQ_STACK); IDT(235, INTR, IRQ_STACK)
	IDT(236, INTR, IRQ_STACK); IDT(237, INTR, IRQ_STACK)
	IDT(238, INTR, IRQ_STACK); IDT(239, INTR, IRQ_STACK)
	IDT(240, INTR, IRQ_STACK); IDT(241, INTR, IRQ_STACK)
	IDT(242, INTR, IRQ_STACK); IDT(243, INTR, IRQ_STACK)
	IDT(244, INTR, IRQ_STACK); IDT(245, INTR, IRQ_STACK)
	IDT(246, INTR, IRQ_STACK); IDT(247, INTR, IRQ_STACK)
	IDT(248, INTR, IRQ_STACK); IDT(249, INTR, IRQ_STACK)
	IDT(250, INTR, IRQ_STACK); IDT(251, INTR, IRQ_STACK)
	IDT(252, INTR, IRQ_STACK); IDT(253, INTR, IRQ_STACK)
	IDT(254, INTR, IRQ_STACK); IDT(255, INTR, IRQ_STACK)
idt_end:

idt48:  /* LIDT descriptor for 32 bit mode */
	.word (idt_end - idt - 1)
	.long idt

idt80:  /* LIDT descriptor for 64 bit mode */
	.word (idt_end - idt - 1)
	.quad idt

.section .gdt,"ad"

/*
 * GDT - a single GDT is shared by all threads (and, eventually, all CPUs).
 * This layout must agree with the selectors in
 * include/arch/x86/intel64/thread.h.
 *
 * The 64-bit kernel code and data segment descriptors must be in sequence as
 * required by 'syscall'
 *
 * The 32-bit user code, 64-bit user code, and 64-bit user data segment
 * descriptors must be in sequence as required by 'sysret'
 */
.align 8

gdt:
	.word 0,      0, 0,      0	/* 0x00: null descriptor */
	.word 0xFFFF, 0, 0x9A00, 0x00CF	/* 0x08: 32-bit kernel code */
	.word 0xFFFF, 0, 0x9200, 0x00CF	/* 0x10: 32-bit kernel data */
	.word 0,      0, 0x9800, 0x0020	/* 0x18: 64-bit kernel code */
	.word 0,      0, 0x9200, 0x0000	/* 0x20: 64-bit kernel data */
	.word 0xFFFF, 0, 0xFA00, 0x00CF /* 0x28: 32-bit user code (unused) */
	.word 0,      0, 0xF200, 0x0000	/* 0x30: 64-bit user data */
	.word 0,      0, 0xF800, 0x0020	/* 0x38: 64-bit user code */

	/* Remaining entries are TSS for each enabled CPU */

	DEFINE_TSS_STACK_ARRAY

gdt_end:

gdt48:  /* LGDT descriptor for 32 bit mode */
	.word (gdt_end - gdt - 1)
	.long gdt

gdt80:  /* LGDT descriptor for long mode */
	.word (gdt_end - gdt - 1)
	.quad gdt
