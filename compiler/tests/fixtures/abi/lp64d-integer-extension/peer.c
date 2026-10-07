#include <stdint.h>
#include <stdio.h>
_Static_assert((char)255 == 255 && sizeof(long) == 8, "LP64D unsigned char and LP64 long");
uint32_t unsigned_value(void) { return UINT32_C(0xf1234567); }
uint32_t unsigned_identity(uint32_t value) { return value; }
/* RV64 sign-extends 32-bit integers to XLEN even for unsigned values. */
__asm__(".text\n.globl observe_unsigned_argument\n"
        ".type observe_unsigned_argument,@function\n"
        "observe_unsigned_argument:\n"
        "li t0, -249346713\n"
        "bne a0, t0, 1f\n"
        "li a0, 42\nret\n"
        "1: li a0, 1\nret\n"
        ".size observe_unsigned_argument,.-observe_unsigned_argument\n");
/* With all eight integer argument registers occupied, the ninth unsigned
   word must fill its complete stack slot with the same canonical value. */
__asm__(".text\n.globl observe_stacked_unsigned\n"
        ".type observe_stacked_unsigned,@function\n"
        "observe_stacked_unsigned:\n"
        "ld t0, 0(sp)\nli t1, -249346713\n"
        "bne t0, t1, 1f\nli a0, 42\nret\n"
        "1: li a0, 1\nret\n"
        ".size observe_stacked_unsigned,.-observe_stacked_unsigned\n");
/* Observe the full return register too, without C truncating it to uint32_t. */
__asm__(".text\n.globl observe_unsigned_return\n"
        ".type observe_unsigned_return,@function\n"
        "observe_unsigned_return:\n"
        "addi sp, sp, -16\nsd ra, 8(sp)\n"
        "li a0, -249346713\ncall landin_unsigned\n"
        "li t0, -249346713\nbne a0, t0, 1f\n"
        "li a0, 42\nj 2f\n1: li a0, 1\n"
        "2: ld ra, 8(sp)\naddi sp, sp, 16\nret\n"
        ".size observe_unsigned_return,.-observe_unsigned_return\n");
extern int32_t observe_unsigned_return(void);
extern uint32_t landin_unsigned(uint32_t);
extern uint32_t landin_stacked_unsigned(uint64_t, uint64_t, uint64_t, uint64_t,
    uint64_t, uint64_t, uint64_t, uint64_t, uint32_t);
extern int32_t landin_check(void);
int main(void) {
    if (landin_unsigned(UINT32_C(0xf1234567)) != UINT32_C(0xf1234567)) return 3;
    if (landin_stacked_unsigned(0, 0, 0, 0, 0, 0, 0, 0,
                               UINT32_C(0xf1234567)) != UINT32_C(0xf1234567)) return 5;
    if (observe_unsigned_return() != 42) return 6;
    if (landin_check() != 42) return 4;
    puts("lp64d integer extension ok");
    return 42;
}
