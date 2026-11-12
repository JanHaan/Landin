OUTPUT_FORMAT("elf32-littlearm")
OUTPUT_ARCH(arm)
ENTRY(_landin_firmware_reset)
MEMORY {
  FLASH (rx) : ORIGIN = 0, LENGTH = 32768
  RAM (rwx) : ORIGIN = 536870912, LENGTH = 16384
}
_landin_firmware_stack_top = ORIGIN(RAM) + LENGTH(RAM);
_landin_firmware_stack_bottom = _landin_firmware_stack_top - 4096;
SECTIONS {
  .isr_vector ORIGIN(FLASH) : { KEEP(*(.isr_vector)) } > FLASH
  .text : { *(.text .text.*) } > FLASH
  .ARM.extab : { *(.ARM.extab*) } > FLASH
  .ARM.exidx : { *(.ARM.exidx*) } > FLASH
  .data : ALIGN(8) {
    _landin_firmware_data_start = .;
    *(.data .data.*)
    _landin_firmware_data_end = .;
  } > RAM AT> FLASH
  _landin_firmware_data_load = LOADADDR(.data);
  .ramtext : ALIGN(8) {
    _landin_firmware_ramtext_start = .;
    *(.ramtext.*)
    _landin_firmware_ramtext_end = .;
  } > RAM AT> FLASH
  _landin_firmware_ramtext_load = LOADADDR(.ramtext);
  .bss (NOLOAD) : AT(ADDR(.bss)) ALIGN(8) {
    _landin_firmware_bss_start = .;
    *(.bss .bss.* COMMON)
    _landin_firmware_bss_end = .;
  } > RAM
  .rodata _landin_firmware_stack_bottom : { *(.rodata .rodata.*) } > RAM AT> FLASH
  /DISCARD/ : { *(.comment .note.GNU-stack) }
}
ASSERT(ADDR(.isr_vector) == 0, "vectors must start at zero")
ASSERT(SIZEOF(.isr_vector) == 192, "vectors must contain 48 words")
ASSERT((_landin_firmware_stack_top & 7) == 0, "unaligned initial stack")
ASSERT(_landin_firmware_bss_end <= _landin_firmware_stack_bottom,
       "RAM image overlaps the reserved 4 KiB stack")
ASSERT(LOADADDR(.ramtext) + SIZEOF(.ramtext) <= ORIGIN(FLASH) + LENGTH(FLASH),
       "initialized image exceeds flash")
