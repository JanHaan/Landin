/* Independent RV32 harness controls (D695): hand-written mains that
 * rv32_controls.py links with rv32-start.S and runs on both RV32 machines
 * before any compiler output does, so the harness, its session and the
 * image checks are shown to tell a return, a trap, an overrun stack and
 * an A-extension instruction apart.  LANDIN_CONTROL selects one:
 *   1  return 42, through a frame that saves and restores s0 and s1;
 *   2  trap at an unimp, the instruction the backend's traps are;
 *   3  overrun the stack reservation, writing below it;
 *   4  return 42 after amoadd.w, amoswap.w and an lr.w/sc.w pair, each
 *      checked, which only the rv32imac lane assembles. */
.option norelax
.text
.global main
.balign 4
main:
#if LANDIN_CONTROL == 1
  addi sp, sp, -16
  sw ra, 12(sp)
  sw s0, 8(sp)
  sw s1, 4(sp)
  addi s0, sp, 16
  li s1, 40
  addi a0, s1, 2
  lw s1, 4(sp)
  lw s0, 8(sp)
  lw ra, 12(sp)
  addi sp, sp, 16
  ret
#elif LANDIN_CONTROL == 2
  unimp
#elif LANDIN_CONTROL == 3
1: addi sp, sp, -16
  sw zero, 0(sp)
  j 1b
#elif LANDIN_CONTROL == 4
  la t0, control_cell
  li t1, 5
  sw t1, 0(t0)
  li t2, 3
  amoadd.w t3, t2, (t0)
  li a0, 1
  li t4, 5
  bne t3, t4, 9f
  li t2, 30
  amoswap.w t3, t2, (t0)
  li a0, 2
  li t4, 8
  bne t3, t4, 9f
1: lr.w t3, (t0)
  addi t3, t3, 12
  sc.w t4, t3, (t0)
  bnez t4, 1b
  lw a0, 0(t0)
9: ret
.bss
.balign 4
control_cell: .space 4
#endif

.section .note.GNU-stack,"",@progbits
