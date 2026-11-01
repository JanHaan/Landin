/* Start for the C/assembly controls run on QEMU's mps2-an500, a Cortex-M7
 * with FPv5-D16 (D616).  Not Landin startup: code and its table at 0, RAM
 * at 0x20000000, and CP10/CP11 given full access in CPACR before any
 * float instruction, which faults NOCP until then. */
.syntax unified
.thumb
.section .isr_vector,"a",%progbits
.global vectors
vectors:
.word 0x20010000, reset, unexpected, hardfault
.rept 12
.word unexpected
.endr
.section .text
.thumb_func
.global reset
reset:
  ldr r0, =0xe000ed88
  ldr r1, [r0]
  orr r1, r1, #(0xf << 20)
  str r1, [r0]
  dsb
  isb
  ldr r0, =__bss_start
  ldr r1, =__bss_end
  movs r2, #0
1: cmp r0, r1
  bcs 2f
  str r2, [r0], #4
  b 1b
2: bl probe
.global done
.thumb_func
done:
  b done
.thumb_func
.global hardfault
hardfault:
  mrs r0, ipsr
  ldr r1, =fault_seen
  str r0, [r1]
.global fault_done
.thumb_func
fault_done:
  b fault_done
.thumb_func
unexpected:
  b unexpected
.bss
.balign 4
.global fault_seen
fault_seen: .space 4

.section .note.GNU-stack,"",%progbits
