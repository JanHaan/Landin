/* External reach control: only compiler routine 4 (cm_leaf) runs in SRAM.
 * Placement forces a GNU Thumb veneer across flash/RAM's >4 MiB gap.
 * This is no Landin section, startup or linker surface. */
ENTRY(reset)
MEMORY {
  FLASH (rx) : ORIGIN = 0, LENGTH = 32K
  RAM (rw) : ORIGIN = 0x20000000, LENGTH = 16K
}
SECTIONS {
  .isr_vector : { KEEP(*(.isr_vector)) } > FLASH
  .data : {
    __data_start = .; KEEP(*(.text.landin_4)) *(.data*) . = ALIGN(4); __data_end = .;
  } > RAM AT> FLASH
  __data_load = LOADADDR(.data);
  .text : { *(.text*) *(.rodata*) } > FLASH
  .bss (NOLOAD) : {
    __bss_start = .; *(.bss*) *(COMMON) . = ALIGN(4); __bss_end = .;
  } > RAM
  /DISCARD/ : { *(.comment) *(.note*) *(.ARM.exidx*) }
}
ASSERT(__bss_end <= 0x20003000, "external test harness reserves 4 KiB stack")
ASSERT(SIZEOF(.isr_vector) == 192, "external harness has 48 vector words")

ASSERT(cm_leaf >= 0x20000000 && cm_leaf < 0x20003000, "leaf must execute in RAM")
