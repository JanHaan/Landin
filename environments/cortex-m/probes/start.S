.syntax unified
.cpu cortex-m0
.thumb
.section .isr_vector,"a",%progbits
.global vectors
vectors:
.word 0x20004000, reset, unexpected, hardfault
.rept 7
.word unexpected
.endr
.word svc
.word unexpected, unexpected, pendsv, systick
.word device_irq
.rept 31
.word unexpected
.endr
.section .text
.thumb_func
.global reset
reset:
  ldr r0, =__bss_start
  ldr r1, =__bss_end
  movs r2, #0
1: cmp r0, r1
  bcs 2f
  str r2, [r0]
  adds r0, #4
  b 1b
2: bl probe
.global done
.thumb_func
done:
  b done
.global fault_probe
.thumb_func
fault_probe:
  udf #0
  b unexpected
.thumb_func
.global hardfault
hardfault:
  mrs r0, ipsr
  ldr r1, =fault_seen
  str r0, [r1]
.global fault_done
fault_done:
  b fault_done
.thumb_func
unexpected:
  b unexpected
