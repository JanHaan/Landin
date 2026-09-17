/* Independent internal-Landin caller. The C controls remain in abi.S/abi.c.
 * These literal words and offsets come from the accepted R6.20 contract. */
.syntax unified
.cpu cortex-m0
.thumb
.text
.global main
.thumb_func
main:
  push {r4-r7,lr}
  sub sp, #44
  movs r0, #2
  str r0, [sp]
  movs r0, #1
  ldr r2, =0x44332211
  ldr r3, =0x88776655
  movs r1, #117
  mov r12, r1             /* not a source atom or an incoming parameter */
  bl cm_gap
  ldr r2, =0x44332214
  cmp r0, r2
  bne bad
  ldr r2, =0x88776655
  cmp r1, r2
  bne bad
  mov r2, r12
  cmp r2, #0
  bne bad
  add r0, sp, #8
  movs r1, #26
  bl cm_many
  add r2, sp, #8
  ldrb r3, [r2]
  cmp r3, #26
  bne bad
  ldr r3, [r2, #8]
  cmp r3, #24
  bne bad
  ldr r3, [r2, #12]
  cmp r3, #25
  bne bad
  movs r0, #1
  bl cm_failure
  mov r2, r12
  cmp r2, #1
  bne bad
  movs r0, #0
  bl cm_failure
  cmp r0, #42
  bne bad
  mov r2, r12
  cmp r2, #0
  bne bad
  movs r0, #41
  ldr r4, =cm_parent
  movs r2, #1
  tst r4, r2
  beq bad
  blx r4
  cmp r0, #42
  bne bad
  add r1, sp, #24
  movs r3, #17
  str r3, [r1]
  movs r3, #19
  str r3, [r1, #4]
  mov r2, r1             /* alias caller place and by-value source */
  add r0, sp, #8         /* caller-owned aggregate result */
  bl cm_copy
  ldr r3, [sp, #24]
  cmp r3, #99
  bne bad
  ldr r3, [sp, #8]
  cmp r3, #17            /* copied before the inout mutation */
  bne bad
  ldr r3, [sp, #12]
  cmp r3, #19
  bne bad
  movs r0, #7
  movs r1, #0
  movs r2, #42
  movs r3, #0
  bl cm_helpers
  cmp r0, #42
  bne bad
  cmp r1, #0
  bne bad
  movs r0, #42
  b leave
bad:
  movs r0, #1
leave:
  movs r2, #0
  mov r12, r2
  add sp, #44
  pop {r4-r7,pc}
.ltorg
.section .note.GNU-stack,"",%progbits
