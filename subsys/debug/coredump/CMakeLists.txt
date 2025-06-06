# Copyright (c) 2020 Intel Corporation.
# SPDX-License-Identifier: Apache-2.0

zephyr_library()

zephyr_library_include_directories(
  ${ZEPHYR_BASE}/kernel/include
  ${ZEPHYR_BASE}/arch/${ARCH}/include
  )

zephyr_library_sources(
  coredump_core.c
  coredump_memory_regions.c
  )

zephyr_library_sources_ifdef(
  CONFIG_DEBUG_COREDUMP_BACKEND_LOGGING
  coredump_backend_logging.c
  )

zephyr_library_sources_ifdef(
  CONFIG_DEBUG_COREDUMP_BACKEND_FLASH_PARTITION
  coredump_backend_flash_partition.c
  )

zephyr_library_sources_ifdef(
  CONFIG_DEBUG_COREDUMP_BACKEND_INTEL_ADSP_MEM_WINDOW
  coredump_backend_intel_adsp_mem_window.c
  )

zephyr_library_sources_ifdef(
  CONFIG_DEBUG_COREDUMP_SHELL
  coredump_shell.c
  )

zephyr_library_sources_ifdef(
  CONFIG_DEBUG_COREDUMP_BACKEND_IN_MEMORY
  coredump_backend_in_memory.c
  )

  # @Intent: Set XTENSA_TOOLCHAIN_VARIANT macro required for Xtensa coredump
if(CONFIG_XTENSA)
  if(${ZEPHYR_TOOLCHAIN_VARIANT} STREQUAL "zephyr")
    zephyr_compile_options(-DXTENSA_TOOLCHAIN_VARIANT=1)
  elseif(${ZEPHYR_TOOLCHAIN_VARIANT} STREQUAL "xcc")
    zephyr_compile_options(-DXTENSA_TOOLCHAIN_VARIANT=2)
  elseif(${ZEPHYR_TOOLCHAIN_VARIANT} STREQUAL "espressif")
    zephyr_compile_options(-DXTENSA_TOOLCHAIN_VARIANT=3)
  else()
    zephyr_compile_options(-DXTENSA_TOOLCHAIN_VARIANT=0)
  endif()
endif()
