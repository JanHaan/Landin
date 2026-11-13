OUTPUT_FORMAT("elf32-littlearm")
OUTPUT_ARCH(arm)
ENTRY(_landin_firmware_reset)
MEMORY {
  FLASH (rx) : ORIGIN = 134217728, LENGTH = 32768
  ITCM (rwx) : ORIGIN = 0, LENGTH = 16384
  RAM (rw) : ORIGIN = 536870912, LENGTH = 16384
}
_landin_firmware_stack_top = ORIGIN(RAM) + LENGTH(RAM);
_landin_firmware_stack_bottom = _landin_firmware_stack_top - 4096;
SECTIONS {
  .isr_vector ORIGIN(FLASH) : { KEEP(*(.isr_vector)) } > FLASH
  .landin_boot : { *(.text.landin_firmware_reset_stage) *(.text.landin_firmware_reset .text.landin_reset) *(.text.landin_firmware_unhandled) *(.text.landin_firmware_trap .text.landin_firmware_vector_addresses) } > FLASH
  .text : {
    _landin_firmware_text_start = .; . = . + (ABSOLUTE(.) < 8 ? 8 - ABSOLUTE(.) : 0);
    *(.text .text.*)
    _landin_firmware_text_end = .;
  } > ITCM
  _landin_firmware_text_load = LOADADDR(.text);
  .rodata : { *(.rodata .rodata.*) } > FLASH
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
  /DISCARD/ : { *(.comment .note.GNU-stack) }
}
ASSERT(ADDR(.isr_vector) == 134217728, "vectors must start at 0x8000000")
ASSERT(SIZEOF(.isr_vector) == 192, "vectors must contain 48 words")
ASSERT((_landin_firmware_stack_top & 7) == 0, "unaligned initial stack")
ASSERT(_landin_firmware_bss_end <= _landin_firmware_stack_bottom,
       "RAM image overlaps the reserved 4 KiB stack")
ASSERT(LOADADDR(.ramtext) + SIZEOF(.ramtext) <= ORIGIN(FLASH) + LENGTH(FLASH),
       "initialized image exceeds flash")
