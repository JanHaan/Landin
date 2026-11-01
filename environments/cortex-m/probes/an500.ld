/* The mps2-an500 controls' map: 4 MiB of code memory at 0, 4 MiB of RAM at
 * 0x20000000, a 64 KiB stack at its bottom.  Unmapped space there reads
 * zero without faulting, so the controls stay inside these two. */
ENTRY(reset)
MEMORY {
  FLASH (rx) : ORIGIN = 0, LENGTH = 4M
  RAM (rw) : ORIGIN = 0x20000000, LENGTH = 4M
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
ASSERT(__bss_end <= 0x20000000 + 0x8000, "the stack is above 32 KiB")
