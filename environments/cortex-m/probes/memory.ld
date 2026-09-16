ENTRY(reset)
MEMORY {
  FLASH (rx) : ORIGIN = 0, LENGTH = 32K
  RAM (rw) : ORIGIN = 0x20000000, LENGTH = 16K
}
SECTIONS {
  .isr_vector : { KEEP(*(.isr_vector)) } > FLASH
  .text : { *(.text*) *(.rodata*) } > FLASH
  .bss (NOLOAD) : {
    __bss_start = .; *(.bss*) *(COMMON) . = ALIGN(4); __bss_end = .;
  } > RAM
  .data : { *(.data*) } > RAM
  /DISCARD/ : { *(.comment) *(.note*) *(.ARM.exidx*) }
}
ASSERT(SIZEOF(.data) == 0, "probe startup does not copy data")
ASSERT(__bss_end <= 0x20003000, "reserve 4 KiB stack")
ASSERT(SIZEOF(.isr_vector) == 192, "48 vector words required")
