/* External reach control: only compiler routine 4 (cm_leaf) runs in SRAM.
 * Placement forces a GNU Thumb veneer across flash/RAM's >4 MiB gap.
 * This is no Landin section, startup or linker surface.  It keeps the
 * constrained reference's map and defines the startup symbols the derived
 * script would, which backend-start.S reads. */
ENTRY(_landin_firmware_reset)
MEMORY {
  FLASH (rx) : ORIGIN = 0, LENGTH = 32K
  RAM (rw) : ORIGIN = 0x20000000, LENGTH = 16K
}
_landin_firmware_stack_top = ORIGIN(RAM) + LENGTH(RAM);
_landin_firmware_stack_bottom = _landin_firmware_stack_top - 4096;
SECTIONS {
  .isr_vector : { KEEP(*(.isr_vector)) } > FLASH
  .data : {
    _landin_firmware_data_start = .; KEEP(*(.text.landin_4)) *(.data*) . = ALIGN(4);
    _landin_firmware_data_end = .;
  } > RAM AT> FLASH
  _landin_firmware_data_load = LOADADDR(.data);
  .text : { *(.text*) *(.rodata*) } > FLASH
  .ramtext : {
    _landin_firmware_ramtext_start = .; *(.ramtext.*) _landin_firmware_ramtext_end = .;
  } > RAM AT> FLASH
  _landin_firmware_ramtext_load = LOADADDR(.ramtext);
  .bss (NOLOAD) : {
    _landin_firmware_bss_start = .; *(.bss*) *(COMMON) . = ALIGN(4);
    _landin_firmware_bss_end = .;
  } > RAM
  /DISCARD/ : { *(.comment) *(.note*) *(.ARM.exidx*) }
}
ASSERT(_landin_firmware_bss_end <= _landin_firmware_stack_bottom,
       "external test harness reserves 4 KiB stack")
ASSERT(SIZEOF(.isr_vector) == 192, "external harness has 48 vector words")

ASSERT(cm_leaf >= 0x20000000 && cm_leaf < 0x20003000, "leaf must execute in RAM")
