/* External generated-code execution harness, not a language linker/startup feature. */
ENTRY(reset)
MEMORY {
  FLASH (rx) : ORIGIN = 0, LENGTH = 32K
  RAM (rw) : ORIGIN = 0x20000000, LENGTH = 16K
}
SECTIONS {
  .isr_vector : { KEEP(*(.isr_vector)) } > FLASH
  .text : { *(.text*) *(.rodata*) } > FLASH
  .data : {
    __data_start = .; *(.data*) . = ALIGN(4); __data_end = .;
  } > RAM AT> FLASH
  __data_load = LOADADDR(.data);
  .bss (NOLOAD) : {
    __bss_start = .; *(.bss*) *(COMMON) . = ALIGN(4); __bss_end = .;
  } > RAM
  /DISCARD/ : { *(.comment) *(.note*) *(.ARM.exidx*) }
}
ASSERT(__bss_end <= 0x20003000, "external test harness reserves 4 KiB stack")
ASSERT(SIZEOF(.isr_vector) == 192, "external harness has 48 vector words")
