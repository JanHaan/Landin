.syntax unified
.cpu cortex-m0
.thumb
.section .isr_vector,"a",%progbits
.word 0x20004000, control_reset, control_fault, control_fault
.word 0,0,0,0,0,0,0
.word control_svc
.word 0,0,control_fault,control_fault
.word control_irq
.rept 31
.word 0
.endr
.section .text.control_reset,"ax",%progbits
.global control_reset
.thumb_func
control_reset:
  ldr r0, =control_data_load
  ldr r1, =control_data_start
  ldr r2, =control_data_end
1: cmp r1, r2
  bcs 2f
  ldr r3, [r0]
  str r3, [r1]
  adds r0, #4
  adds r1, #4
  b 1b
2: ldr r1, =control_bss_start
  ldr r2, =control_bss_end
  movs r3, #0
3: cmp r1, r2
  bcs 4f
  str r3, [r1]
  adds r1, #4
  b 3b
4: ldr r0, =0xe000ed1c
  ldr r1, =0xc0000000
  str r1, [r0]
  ldr r0, =0xe000e100
  movs r1, #1
  str r1, [r0]
  ldr r0, =0x200037fc
  msr psp, r0
  movs r0, #2
  msr control, r0
  isb sy
  movs r0, #17
  movs r1, #34
  movs r2, #51
  movs r3, #68
  movs r4, #85
  movs r5, #102
  movs r6, #119
  movs r7, #136
  cmp r0, r0
  svc #0
.global control_done
control_done:
  b control_done
.ltorg
.section .text.control_svc,"ax",%progbits
.global control_svc
.thumb_func
control_svc:
  push {r4, lr}
  bl control_increment
  ldr r0, =0xe000e200
  movs r1, #1
  str r1, [r0]
  dsb sy
  isb sy
  pop {r4, pc}
.ltorg
.section .text.control_irq,"ax",%progbits
.global control_irq
.thumb_func
control_irq:
  push {r4, lr}
  bl control_increment
  pop {r4, pc}
.section .text.control_fault,"ax",%progbits
.thumb_func
control_fault:
  b control_fault
.section .note.GNU-stack,"",%progbits
