/* External generated-code test harness for the RV32 lanes: backend-start.S's
 * counterpart.  These are not Landin startup, trap or section capabilities.
 * The tested entry is ordinary main.
 *
 * The harness links with the selected profile's derived linker script, the
 * one refine writes for a firmware build of that profile (D545), so it
 * supplies what that script places and reads: a `.boot2` prefix for a boot
 * kind that has one, the entry word `_landin_firmware_entry` in
 * `.text.landin_entry`, which the script puts first at the text region's
 * origin, where QEMU's sifive_e mask ROM jumps, and which jumps to
 * `_landin_firmware_reset` in `.text.landin_reset`, the vectored trap
 * table in `.isr_vector`, LANDIN_VECTOR_WORDS four-byte jumps, which the
 * script puts 64 bytes on, an `.embedded_block` of the length a boot kind
 * places after it, and the `_landin_firmware_*` data, RAM-code, BSS and
 * stack symbols the script defines.  backend.py
 * assembles it with the profile's facts, LANDIN_BOOT_PREFIX and
 * LANDIN_BOOT_SUFFIX zeros here: the harness's image is loaded with
 * -kernel, never booted.
 *
 * Interrupts stay disabled: mstatus.MIE is cleared before mtvec is set.  An
 * exception enters slot 0 in vectored mode, and the harness records it in
 * backend_fault: a one, mcause, mepc, mtval and the sp it was taken on, as
 * the Cortex harness records the HardFault's exception number and frame.
 * Any interrupt reaching its slot is unexpected and loops there.  The
 * harness's own entries stay in the `_landin` prefix the compiler keeps for
 * its own symbols, so a program's public routine cannot collide with them. */
.option norelax
#if LANDIN_BOOT_PREFIX
.section .boot2,"a",@progbits
.space LANDIN_BOOT_PREFIX
#endif
.section .isr_vector,"ax",@progbits
.option push
.option norvc
.balign 64
_landin_harness_table:
  j _landin_harness_trap
.rept LANDIN_VECTOR_WORDS - 1
  j _landin_harness_unexpected
.endr
.option pop
#if LANDIN_BOOT_SUFFIX
.section .embedded_block,"a",@progbits
.space LANDIN_BOOT_SUFFIX
#endif
.section .text.landin_entry,"ax",@progbits
.global _landin_firmware_entry
_landin_firmware_entry:
.option push
.option norvc
  j _landin_firmware_reset
.option pop
.section .text.landin_reset,"ax",@progbits
.global _landin_firmware_reset
_landin_firmware_reset:
  csrci mstatus, 8
  la sp, _landin_firmware_stack_top
  la t0, _landin_harness_table
  ori t0, t0, 1
  csrw mtvec, t0
  la a0, _landin_firmware_data_load
  la a1, _landin_firmware_data_start
  la a2, _landin_firmware_data_end
  call _landin_harness_copy
  la a0, _landin_firmware_ramtext_load
  la a1, _landin_firmware_ramtext_start
  la a2, _landin_firmware_ramtext_end
  call _landin_harness_copy
  la a0, _landin_firmware_bss_start
  la a1, _landin_firmware_bss_end
3: bgeu a0, a1, 4f
  sb zero, 0(a0)
  addi a0, a0, 1
  j 3b
4: la a0, _landin_firmware_stack_bottom
  la a1, _landin_firmware_stack_top
  li a2, 0xa55ac33c
5: sw a2, 0(a0)
  addi a0, a0, 4
  bltu a0, a1, 5b
  fence.i
/* The callee-saved registers' sentinels, which main must return; s0 is
 * zero, the end of a frame-pointer chain, and gp and tp, which the
 * compiler does not use, are painted too. */
  li s0, 0
  li s1, 44
  li s2, 55
  li s3, 66
  li s4, 77
  li s5, 88
  li s6, 99
  li s7, 100
  li s8, 111
  li s9, 122
  li s10, 133
  li s11, 144
  li gp, 0x9e9e9e9e
  li tp, 0x7e7e7e7e
/* The stack is painted: a debugger watching its guard starts here. */
.global backend_painted
backend_painted:
  call main
  la t0, backend_result
  sw a0, 0(t0)
  sw a1, 4(t0)
.global backend_done
backend_done:
  j backend_done
.text
/* Copy the bytes from a0 to a1 until a1 reaches a2. */
_landin_harness_copy:
1: bgeu a1, a2, 2f
  lbu t0, 0(a0)
  sb t0, 0(a1)
  addi a0, a0, 1
  addi a1, a1, 1
  j 1b
2: ret
.balign 4
_landin_harness_trap:
  la t0, backend_fault
  li t1, 1
  sw t1, 0(t0)
  csrr t1, mcause
  sw t1, 4(t0)
  csrr t1, mepc
  sw t1, 8(t0)
  csrr t1, mtval
  sw t1, 12(t0)
  sw sp, 16(t0)
.global backend_fault_done
backend_fault_done:
  j backend_fault_done
.balign 4
_landin_harness_unexpected:
  j _landin_harness_unexpected
.bss
.balign 4
.global backend_result
backend_result: .space 12
.global backend_fault
backend_fault: .space 20

.section .note.GNU-stack,"",@progbits
