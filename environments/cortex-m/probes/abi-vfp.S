/* Hand-written VFP endpoints for abi-vfp.c (D616); no compiler plan is
 * used to write them.  Each records r0-r3, s0-s15, six stack words and
 * the SP it was called with in its row of vfp_capture, then returns a
 * known value where the convention says a result goes. */
.syntax unified
.thumb
.text
.macro endpoint name, row
.global \name
.thumb_func
\name:
  push {r4, r5}
  ldr r4, =vfp_capture + (\row * 108)
  stmia r4!, {r0-r3}
  vstmia r4!, {s0-s15}
  add r5, sp, #8
  .rept 6
  ldr r0, [r5], #4
  str r0, [r4], #4
  .endr
  add r5, sp, #8
  str r5, [r4]
  pop {r4, r5}
.endm
endpoint capture_mixed, 0
  ldr r0, =0x3fc00000
  vmov s0, r0
  bx lr
endpoint capture_hfa, 1
  movs r0, #0
  ldr r1, =0x3ff80000
  vmov d0, r0, r1
  ldr r1, =0x40120000
  vmov d3, r0, r1
  bx lr
endpoint capture_spill, 2
  movs r0, #0
  ldr r1, =0x3ff80000
  vmov d0, r0, r1
  bx lr
endpoint capture_varargs, 3
  movs r0, #0
  ldr r1, =0x3ff80000
  bx lr
endpoint capture_large, 4
  ldr r0, =vfp_capture + (4 * 108)
  ldr r0, [r0]
  ldr r1, =0x3fc00000
  str r1, [r0]
  ldr r1, =0x40900000
  str r1, [r0, #16]
  bx lr

/* d8-d15 hold sentinels across a GCC routine that clobbers every VFP
 * register; the result is one when every sentinel survived. */
.macro sentinel n
  ldr r0, =0x5a5a0000 + \n
  movs r1, #\n
  vmov d\n, r1, r0
.endm
.macro survived n
  vmov r1, r0, d\n
  ldr r2, =0x5a5a0000 + \n
  cmp r0, r2
  bne 2f
  cmp r1, #\n
  bne 2f
.endm
.global preserved_probe
.thumb_func
preserved_probe:
  push {r3-r7, lr}
  vpush {d8-d15}
  sentinel 8
  sentinel 9
  sentinel 10
  sentinel 11
  sentinel 12
  sentinel 13
  sentinel 14
  sentinel 15
  bl vfp_clobber
  survived 8
  survived 9
  survived 10
  survived 11
  survived 12
  survived 13
  survived 14
  survived 15
  movs r0, #1
  b 1f
2: movs r0, #0
1: vpop {d8-d15}
  pop {r3-r7, pc}
.ltorg

.section .note.GNU-stack,"",%progbits
