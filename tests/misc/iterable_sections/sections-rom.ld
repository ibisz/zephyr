#include <zephyr/linker/iterable_sections.h>

ITERABLE_SECTION_ROM(test_rom, Z_LINK_ITERABLE_SUBALIGN)
ITERABLE_SECTION_ROM(test_rom2, Z_LINK_ITERABLE_SUBALIGN)
ITERABLE_SECTION_ROM(test_rom_named, Z_LINK_ITERABLE_SUBALIGN)
ITERABLE_SECTION_ROM_NUMERIC(test_rom_numeric, Z_LINK_ITERABLE_SUBALIGN)
ITERABLE_SECTION_ROM(romn_alt, Z_LINK_ITERABLE_SUBALIGN)
