OUTPUT_FORMAT("elf32-littlearm")
OUTPUT_ARCH(arm)
ENTRY(control_reset)
MEMORY {
  FLASH (rx) : ORIGIN = 0, LENGTH = 32768
  RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 12288
}
SECTIONS {
  .isr_vector 0 : { KEEP(*(.isr_vector)) } > FLASH
  .text : { *(.text*) *(.rodata*) } > FLASH
  .ARM.exidx : { *(.ARM.exidx*) } > FLASH
  .data : ALIGN(4) {
    control_data_start = .;
    *(.data*)
    . = ALIGN(4);
    control_data_end = .;
  } > RAM AT> FLASH
  control_data_load = LOADADDR(.data);
  .bss (NOLOAD) : ALIGN(4) {
    control_bss_start = .;
    *(.bss*)
    . = ALIGN(4);
    control_bss_end = .;
  } > RAM
  /DISCARD/ : { *(.comment .note.GNU-stack) }
}
ASSERT(SIZEOF(.isr_vector) == 192, "independent control vector size")
