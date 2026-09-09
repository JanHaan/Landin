#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

struct large {
    uint64_t first;
    double second;
    uint64_t third;
};
typedef struct large (*producer)(uint64_t, double, uint64_t);

_Static_assert(sizeof(struct large) == 24, "MEMORY result size");
_Static_assert(_Alignof(struct large) == 8, "MEMORY result alignment");
_Static_assert(offsetof(struct large, first) == 0, "first offset");
_Static_assert(offsetof(struct large, second) == 8, "second offset");
_Static_assert(offsetof(struct large, third) == 16, "third offset");

extern struct large r440_l_sret(uint64_t, double, uint64_t);
struct large r440_c_sret(uint64_t first, double second, uint64_t third) {
    return (struct large){first + 1, second + 0.5, third + 3};
}

extern int r440_probe_sret_direct(struct large *, uint64_t, double, uint64_t);
extern int r440_probe_sret_indirect(struct large *, producer,
                                    uint64_t, double, uint64_t);
extern struct large r440_bad_sret(uint64_t, double, uint64_t);

/* SysV entry rsp is 8 mod 16. Saving rbx aligns every nested call and
   preserves both the caller's rbx and our original hidden destination.
   Compare rax immediately on return, before C can ignore that register.
   Direct explicit arguments already occupy rsi/xmm0/rdx; the indirect
   wrapper moves its function pointer aside and shifts only its GP values. */
__asm__(".text\n"
        ".globl r440_probe_sret_direct\n"
        ".type r440_probe_sret_direct, @function\n"
        "r440_probe_sret_direct:\n"
        "pushq %rbx\n"
        "movq %rdi, %rbx\n"
        "call r440_l_sret\n"
        "cmpq %rbx, %rax\n"
        "sete %al\n"
        "movzbl %al, %eax\n"
        "popq %rbx\n"
        "ret\n"
        ".size r440_probe_sret_direct, .-r440_probe_sret_direct\n"
        ".globl r440_probe_sret_indirect\n"
        ".type r440_probe_sret_indirect, @function\n"
        "r440_probe_sret_indirect:\n"
        "pushq %rbx\n"
        "movq %rdi, %rbx\n"
        "movq %rsi, %r11\n"
        "movq %rdx, %rsi\n"
        "movq %rcx, %rdx\n"
        "call *%r11\n"
        "cmpq %rbx, %rax\n"
        "sete %al\n"
        "movzbl %al, %eax\n"
        "popq %rbx\n"
        "ret\n"
        ".size r440_probe_sret_indirect, .-r440_probe_sret_indirect\n"
        /* Deliberately break only the returned-pointer obligation. The C
           producer still writes correct fields; the observer must fail. */
        ".globl r440_bad_sret\n"
        ".type r440_bad_sret, @function\n"
        "r440_bad_sret:\n"
        "pushq %rbx\n"
        "call r440_c_sret\n"
        "xorl %eax, %eax\n"
        "popq %rbx\n"
        "ret\n"
        ".size r440_bad_sret, .-r440_bad_sret\n");

static int fields_equal(struct large actual, struct large expected) {
    return actual.first == expected.first && actual.second == expected.second
        && actual.third == expected.third;
}

int main(void) {
    struct large calibration = {0, 0.0, 0};
    struct large broken = {0, 0.0, 0};
    struct large direct = {0, 0.0, 0};
    struct large indirect = {0, 0.0, 0};
    if (r440_probe_sret_indirect(&calibration, r440_c_sret, 10, 20.25, 30) != 1
        || !fields_equal(calibration, r440_c_sret(10, 20.25, 30))) return 1;
    if (r440_probe_sret_indirect(&broken, r440_bad_sret, 40, -50.25, 60) != 0
        || !fields_equal(broken, r440_c_sret(40, -50.25, 60))) return 2;
    if (r440_probe_sret_direct(&direct, 70, 80.25, 90) != 1
        || !fields_equal(direct, r440_c_sret(70, 80.25, 90))) return 3;
    if (r440_probe_sret_indirect(&indirect, r440_l_sret, 100, -110.25, 120) != 1
        || !fields_equal(indirect, r440_c_sret(100, -110.25, 120))) return 4;
    if (!fields_equal(r440_l_sret(130, 140.25, 150),
                      r440_c_sret(130, 140.25, 150))) return 5;
    puts("sret pointer observation ok");
    return 42;
}
