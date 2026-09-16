.syntax unified
.cpu cortex-m0
.thumb
.text
/* No compiler plan is used to write these witnesses. */
.macro endpoint name, row
.global \name
.thumb_func
\name:
  push {r4,r5}
  ldr r4, =capture + (\row * 44)
  stmia r4!, {r0-r3}
  add r5, sp, #8
  str r5, [r4, #24]
  .rept 6
  ldr r0, [r5]
  str r0, [r4]
  adds r5, #4
  adds r4, #4
  .endr
  pop {r4,r5}
.endm
endpoint capture_gap, 0
  bx lr
endpoint capture_split, 1
  bx lr
endpoint capture_stack, 2
  bx lr
endpoint capture_sret, 3
  ldr r0, =capture + 132
  ldr r0, [r0]
  movs r1, #1
  strb r1, [r0]
  movs r1, #2
  strb r1, [r0, #1]
  movs r1, #3
  strb r1, [r0, #2]
  movs r1, #4
  strb r1, [r0, #3]
  movs r1, #5
  strb r1, [r0, #4]
  bx lr
endpoint capture_small, 4
  ldr r0, =0x00332211
  bx lr
endpoint capture_varargs, 5
  bx lr
endpoint capture_floatpair, 6
  movs r0, #0
  ldr r1, =0x3ff80000
  bx lr
.global assembly_return4
.thumb_func
assembly_return4:
  ldr r0, =0x44332211
  bx lr
.global assembly_return64
.thumb_func
assembly_return64:
  ldr r0, =0x44332211
  ldr r1, =0x88776655
  bx lr
.global assembly_return_double
.thumb_func
assembly_return_double:
  movs r0, #0
  ldr r1, =0x3ff80000
  bx lr
.global assembly_return_i8
.thumb_func
assembly_return_i8:
  movs r0, #7
  rsbs r0, #0
  bx lr

.global assembly_calls
.thumb_func
assembly_calls:
  push {r4-r7,lr}
  sub sp, #36
  mov r0, r8
  str r0, [sp, #20]
  mov r0, r9
  str r0, [sp, #24]
  mov r0, r10
  str r0, [sp, #28]
  mov r0, r11
  str r0, [sp, #32]
  movs r0, #88
  mov r8, r0
  movs r0, #99
  mov r9, r0
  movs r0, #100
  mov r10, r0
  movs r0, #111
  mov r11, r0
  movs r4, #44
  movs r5, #55
  movs r6, #66
  movs r7, #77
  movs r0, #1
  movs r1, #2
  str r1, [sp]
  ldr r2, =0x44332211
  ldr r3, =0x88776655
  bl c_wide
  ldr r2, =0x44332210
  cmp r0, r2
  bne bad_c
  ldr r2, =0x88776657
  cmp r1, r2
  bne bad_c
  ldr r0, =0x00332211
  bl c_small
  lsls r0, #8
  lsrs r0, #8
  ldr r1, =0x00332211
  cmp r0, r1
  bne bad_c
  add r0, sp, #8
  movs r1, #1
  bl c_large
  add r0, sp, #8
  ldrb r1, [r0]
  cmp r1, #1
  bne bad_c
  ldrb r1, [r0, #4]
  cmp r1, #5
  bne bad_c
  cmp r4, #44
  bne bad_c
  cmp r5, #55
  bne bad_c
  cmp r6, #66
  bne bad_c
  cmp r7, #77
  bne bad_c
  mov r0, r8
  cmp r0, #88
  bne bad_c
  mov r0, r9
  cmp r0, #99
  bne bad_c
  mov r0, r10
  cmp r0, #100
  bne bad_c
  mov r0, r11
  cmp r0, #111
  bne bad_c
  ldr r0, =0x620
  b end_c
bad_c:
  movs r0, #0
end_c:
  ldr r1, [sp, #20]
  mov r8, r1
  ldr r1, [sp, #24]
  mov r9, r1
  ldr r1, [sp, #28]
  mov r10, r1
  ldr r1, [sp, #32]
  mov r11, r1
  add sp, #36
  pop {r4-r7,pc}

/* Landin contract witness: result address, two evidence pointers, address
   of an eight-byte value, then an aligned u64 stack argument. */
.global internal_entry
.thumb_func
internal_entry:
  mov r12, r3
  mov r3, r11
  push {r3,lr}
  mov r11, sp
  push {r4,r5}
.global native_frame_ready
native_frame_ready:
  mov r4, r12
  ldr r3, [r1]             /* direct evidence size */
  cmp r3, #8
  bne native_bad
  ldr r3, [r2, #4]         /* separate parent alignment */
  cmp r3, #4
  bne native_bad
  ldr r3, [r4]             /* callee's value copy, no alias mutation */
  ldr r5, [sp, #16]        /* low half of u64 at incoming sp */
  adds r3, r3, r5
  str r3, [r0]
  ldr r3, [sp, #20]
  str r3, [r0, #4]
  bl internal_parent      /* nested frame and a recovered declared error */
  movs r3, #0
  mov r12, r3              /* success, independently of result storage */
  b native_leave
native_bad:
  movs r3, #7
  mov r12, r3
native_leave:
  pop {r4,r5}
  pop {r2,r3}
  mov r11, r2
  bx r3
.global internal_parent
.thumb_func
internal_parent:
  mov r3, r11
  push {r3,lr}
  mov r11, sp
.global parent_frame_ready
parent_frame_ready:
  movs r3, #7
  mov r12, r3
  pop {r2,r3}
  mov r11, r2
  bx r3

/* Erased dispatch inserts only the data pointer, not a table parameter. */
.global erased_entry
.thumb_func
erased_entry:
  mov r3, r11
  push {r3,lr}
  mov r11, sp
  movs r1, #23
  str r1, [r0]
  movs r3, #0
  mov r12, r3
  movs r0, #23
  pop {r2,r3}
  mov r11, r2
  bx r3

/* Internal u64/f64 use the same two core-bit carriers as base PCS, while
   declared failure remains separate. Every Landin entry keeps its frame. */
.thumb_func
internal_wide:
  mov r3, r11
  push {r3,lr}
  mov r11, sp
  movs r3, #0
  mov r12, r3
  pop {r2,r3}
  mov r11, r2
  bx r3

/* Multiple results use one natural-layout destination: u8 then u64. */
.thumb_func
internal_multi:
  mov r3, r11
  push {r3,lr}
  mov r11, sp
  strb r1, [r0]
  movs r2, #24
  str r2, [r0, #8]
  movs r2, #25
  str r2, [r0, #12]
  movs r3, #0
  mov r12, r3
  pop {r2,r3}
  mov r11, r2
  bx r3

.global internal_calls
.thumb_func
internal_calls:
  push {r4-r7,lr}
  sub sp, #36
  mov r4, r11
  movs r5, #0
  mov r11, r5
  movs r5, #9
  str r5, [sp]
  movs r5, #10
  str r5, [sp, #4]
  movs r5, #11
  str r5, [sp, #8]
  add r0, sp, #16
  ldr r1, =direct_table
  ldr r2, =parent_table
  add r3, sp, #8
  ldr r5, [r1, #8]        /* Thumb address in direct evidence */
  movs r6, #1
  tst r5, r6
  beq bad_native
  blx r5
  mov r5, r12
  cmp r5, #0
  bne bad_native
  mov r5, r11
  cmp r5, #0
  bne bad_native
  ldr r5, [sp, #8]
  cmp r5, #11
  bne bad_native
  ldr r5, [sp, #16]
  cmp r5, #20
  bne bad_native
  ldr r5, [sp, #20]
  cmp r5, #10
  bne bad_native
  bl internal_parent
  mov r5, r12
  cmp r5, #7
  bne bad_native
  ldr r5, =erased_value
  ldr r0, [r5]
  ldr r5, [r5, #4]
  ldr r5, [r5, #8]
  blx r5
  cmp r0, #23
  bne bad_native
  ldr r5, =erased_data
  ldr r5, [r5]
  cmp r5, #23
  bne bad_native
  ldr r0, =0x44332211
  ldr r1, =0x88776655
  bl internal_wide
  mov r5, r12
  cmp r5, #0
  bne bad_native
  ldr r5, =0x44332211
  cmp r0, r5
  bne bad_native
  ldr r5, =0x88776655
  cmp r1, r5
  bne bad_native
  add r0, sp, #16
  movs r1, #26
  bl internal_multi
  mov r5, r12
  cmp r5, #0
  bne bad_native
  add r5, sp, #16
  ldrb r6, [r5]
  cmp r6, #26
  bne bad_native
  ldr r6, [r5, #8]
  cmp r6, #24
  bne bad_native
  ldr r6, [r5, #12]
  cmp r6, #25
  bne bad_native
  ldr r0, =0x620
  b end_native
bad_native:
  movs r0, #0
end_native:
  mov r11, r4
  add sp, #36
  pop {r4-r7,pc}
