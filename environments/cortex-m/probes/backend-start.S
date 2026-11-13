/* External generated-code test harness. These are not Landin startup, vector,
 * interrupt or section capabilities. The tested entry is ordinary main.
 *
 * The harness links with the selected profile's derived linker script, the
 * one refine writes for a firmware build of that profile (D545), so it
 * supplies what that script places and reads: a `.boot2` prefix for a boot
 * kind that has one, a vector table of the profile's length in
 * `.isr_vector`, an `.embedded_block` of the length a boot kind places
 * after it, its entry `_landin_firmware_reset`, and the
 * `_landin_firmware_*` data, RAM-code, BSS and stack symbols the script
 * defines.  backend.py assembles it with the profile's facts:
 * LANDIN_VECTOR_WORDS, the table's length, LANDIN_BOOT_PREFIX, the
 * bytes the boot kind puts before it, and LANDIN_BOOT_SUFFIX, those it
 * puts after it, zeros here: the harness's image is linked, never booted.  The harness's own fault and
 * unexpected entries stay in the `_landin` prefix the compiler keeps for
 * its own symbols, so a program's public routine, `arena.reset` among them,
 * cannot collide with them.
 *
 * LANDIN_FPU, set for a lane whose description has a float unit (D616),
 * gives CP10 and CP11 full access before anything else runs, paints d8-d15
 * before main and records in the result's third word whether main
 * preserved them, as the core registers' sentinels are checked. */
.syntax unified
#if LANDIN_FPU
.arch armv7e-m
.fpu fpv5-d16
.eabi_attribute Tag_ABI_FP_number_model, 3
.eabi_attribute Tag_ABI_VFP_args, 1
#else
.cpu cortex-m0
#endif
.thumb
#if LANDIN_BOOT_PREFIX
.section .boot2,"a",%progbits
.space LANDIN_BOOT_PREFIX
#endif
.section .isr_vector,"a",%progbits
.word _landin_firmware_stack_top, _landin_firmware_reset, _landin_harness_unexpected, _landin_harness_hardfault
.rept LANDIN_VECTOR_WORDS - 4
.word _landin_harness_unexpected
.endr
#if LANDIN_BOOT_SUFFIX
.section .embedded_block,"a",%progbits
.space LANDIN_BOOT_SUFFIX
#endif
/* Reset's own section, which a derived script that copies the text keeps
 * with the vector table (D1359), and otherwise links with the rest of the
 * text, where `.text` would be.  A profile that copies the text is linked
 * here and never run, so the harness copies none. */
.section .text.landin_firmware_reset,"ax",%progbits
.global _landin_firmware_reset
.thumb_func
_landin_firmware_reset:
#if LANDIN_FPU
  ldr r0, =0xe000ed88
  ldr r1, [r0]
  movs r2, #15
  lsls r2, r2, #20
  orrs r1, r2
  str r1, [r0]
  dsb sy
  isb sy
#endif
  movs r0, #0
  mov r11, r0
  ldr r0, =_landin_firmware_data_load
  ldr r1, =_landin_firmware_data_start
  ldr r2, =_landin_firmware_data_end
  bl copy
  ldr r0, =_landin_firmware_ramtext_load
  ldr r1, =_landin_firmware_ramtext_start
  ldr r2, =_landin_firmware_ramtext_end
  bl copy
  ldr r0, =_landin_firmware_bss_start
  ldr r1, =_landin_firmware_bss_end
  movs r2, #0
3: cmp r0, r1
  bcs 4f
  strb r2, [r0]
  adds r0, #1
  b 3b
4: ldr r0, =_landin_firmware_stack_bottom
  ldr r1, =_landin_firmware_stack_top
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
#if LANDIN_FPU
  .irp n, 8, 9, 10, 11, 12, 13, 14, 15
  ldr r0, =0x5a5a0000 + \n
  vmov d\n, r0, r0
  .endr
  movs r0, #100
#endif
/* The stack is painted: a debugger watching its guard starts here. */
.global backend_painted
.thumb_func
backend_painted:
  bl main
  ldr r1, =backend_result
  str r0, [r1]
  mov r0, r12
  str r0, [r1, #4]
#if LANDIN_FPU
  movs r0, #0
  .irp n, 8, 9, 10, 11, 12, 13, 14, 15
  vmov r2, r3, d\n
  ldr r4, =0x5a5a0000 + \n
  cmp r2, r4
  bne 9f
  cmp r3, r4
  bne 9f
  .endr
  movs r0, #1
9: str r0, [r1, #8]
  movs r4, #44
#endif
.global backend_done
.thumb_func
backend_done:
  b backend_done
/* Copy the bytes from r0 to r1 until r1 reaches r2. */
.thumb_func
copy:
1: cmp r1, r2
  bcs 2f
  ldrb r3, [r0]
  strb r3, [r1]
  adds r0, #1
  adds r1, #1
  b 1b
2: bx lr
.thumb_func
_landin_harness_hardfault:
  mrs r0, ipsr
  ldr r1, =backend_fault
  str r0, [r1]
/* The exception frame is on the stack the faulting code ran on, which
 * EXC_RETURN's bit 2 names: the main stack, or a fibre's process stack. */
  mov r2, lr
  movs r3, #4
  tst r2, r3
  bne 1f
  mrs r2, msp
  b 2f
1: mrs r2, psp
2: str r2, [r1, #4]
.global backend_fault_done
.thumb_func
backend_fault_done:
  b backend_fault_done
.thumb_func
_landin_harness_unexpected:
  b _landin_harness_unexpected
.bss
.balign 4
.global backend_result
backend_result: .space 12
.global backend_fault
backend_fault: .space 8

.section .note.GNU-stack,"",%progbits
