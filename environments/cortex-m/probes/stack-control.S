/* Independent ARMv6-M stack witnesses: no compiler frame plan or startup. */
.syntax unified
.cpu cortex-m0
.thumb
.text
.global probe
.thumb_func
probe:
  mov r8, lr
  sub sp, #256
.global unwritten_gap
unwritten_gap:
  add sp, #256
  ldr r0, =0xe000ed1c
  ldr r1, =0xc0000000
  str r1, [r0]
  ldr r0, =0xe000e100
  movs r1, #1
  str r1, [r0]
  dsb sy
  isb sy
  sub sp, #4
  svc #0
.global after_svc
after_svc:
  add sp, #4
  bx r8
.global svc
.thumb_func
svc:
  push {r4,lr}
  ldr r0, =0xe000e200
  movs r1, #1
  str r1, [r0]
  dsb sy
  isb sy
  pop {r4,r5}
  mov lr, r5
  bx lr
.global device_irq
.thumb_func
device_irq:
  bx lr
.global pendsv, systick
.thumb_func
pendsv:
  b pendsv
.thumb_func
systick:
  b systick
.comm fault_seen,4,4
