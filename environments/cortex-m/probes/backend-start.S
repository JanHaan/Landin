/* External generated-code test harness. These are not Landin startup, vector,
 * interrupt or section capabilities. The tested entry is ordinary main. */
.syntax unified
.cpu cortex-m0
.thumb
.section .isr_vector,"a",%progbits
.word 0x20004000, reset, unexpected, hardfault
.rept 44
.word unexpected
.endr
.text
.global reset
.thumb_func
reset:
  movs r0, #0
  mov r11, r0
  ldr r0, =__data_load
  ldr r1, =__data_start
  ldr r2, =__data_end
1: cmp r1, r2
  bcs 2f
  ldrb r3, [r0]
  strb r3, [r1]
  adds r0, #1
  adds r1, #1
  b 1b
2: ldr r0, =__bss_start
  ldr r1, =__bss_end
  movs r2, #0
3: cmp r0, r1
  bcs 4f
  str r2, [r0]
  adds r0, #4
  b 3b
4: ldr r0, =0x20003000
  ldr r1, =0x20004000
  ldr r2, =0xa55ac33c
5: str r2, [r0]
  adds r0, #4
  cmp r0, r1
  bcc 5b
  movs r4, #44
  movs r5, #55
  movs r6, #66
  movs r7, #77
  movs r0, #88
  mov r8, r0
  movs r0, #99
  mov r9, r0
  movs r0, #100
  mov r10, r0
  bl main
  ldr r1, =backend_result
  str r0, [r1]
  mov r0, r12
  str r0, [r1, #4]
.global backend_done
.thumb_func
backend_done:
  b backend_done
.thumb_func
hardfault:
  mrs r0, ipsr
  ldr r1, =backend_fault
  str r0, [r1]
.global backend_fault_done
.thumb_func
backend_fault_done:
  b backend_fault_done
.thumb_func
unexpected:
  b unexpected
.bss
.balign 4
.global backend_result
backend_result: .space 8
.global backend_fault
backend_fault: .space 4

.section .note.GNU-stack,"",%progbits
