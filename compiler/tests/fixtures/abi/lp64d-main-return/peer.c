/* Linker wrapping preserves the ordinary Landin hosted entry.  Observe its
   complete a0 register before C can narrow the returned int to 32 bits. */
#if !defined(__riscv) || __riscv_xlen != 64
#error This independent LP64D observer requires native RV64 assembly
#endif
__asm__(
    ".text\n"
    ".globl __wrap_main\n"
    ".type __wrap_main, @function\n"
    "__wrap_main:\n"
    "addi sp, sp, -16\n"
    "sd ra, 8(sp)\n"
    "call __real_main\n"
    "li t0, -1\n"
    "li t1, 1\n"
    "bne a0, t0, 1f\n"
    "li t1, 42\n"
    "1: mv a0, t1\n"
    "ld ra, 8(sp)\n"
    "addi sp, sp, 16\n"
    "ret\n"
    ".size __wrap_main, .-__wrap_main\n"
);
