/* Independent legal encoding boundaries, not compiler-generated code. */
.syntax unified
.cpu cortex-m0
.thumb
.text
.balign 4
.global main
.thumb_func
main:
  push {r4,lr}
  bl literal_max
  ldr r1, =0x12345678
  cmp r0, r1
  bne bad
  bl branch_max
  cmp r0, #42
  bne bad
  movs r0, #1
  bl conditional_max
  cmp r0, #42
  bne bad
  movs r0, #42
  b done
bad:
  movs r0, #1
done:
  movs r1, #0
  mov r12, r1
  pop {r4,pc}
.ltorg
.balign 4
.thumb_func
literal_max:
  ldr r0, literal
  bx lr
  .space 1020
literal: .word 0x12345678
.balign 4
.thumb_func
branch_max:
  b far_branch
  .space 2048
far_branch:
  movs r0, #42
  bx lr
.balign 4
.thumb_func
conditional_max:
  cmp r0, #1
  beq far_condition
  bx lr
  .space 254
far_condition:
  movs r0, #42
  bx lr
.section .note.GNU-stack,"",%progbits
