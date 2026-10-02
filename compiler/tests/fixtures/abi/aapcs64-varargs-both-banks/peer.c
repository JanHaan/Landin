#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>

static int32_t collect(int32_t count, va_list arguments) {
    static const int expected[] = {-7, 250, -30000, 60000, 1, 6, 7, 8, 9, 10};
    if (count != 10) return 1;
    for (int i = 0; i < count; ++i) {
        int integer = va_arg(arguments, int);
        double real = va_arg(arguments, double);
        if (integer != expected[i] || real != i + 0.5) return 2;
    }
    return 42;
}
int32_t c_collect(int32_t count, ...) {
    va_list arguments;
    va_start(arguments, count);
    int32_t result = collect(count, arguments);
    va_end(arguments);
    return result;
}
int32_t c_fixed(double bias, int32_t count, ...) {
    va_list arguments;
    va_start(arguments, count);
    int32_t result = collect(count, arguments);
    va_end(arguments);
    return bias == 12.5 ? result : 3;
}

/* Where the standard places them, which va_arg cannot show: the count in
   w0, the first seven integers in w1-w7 and the first eight doubles in
   d0-d7, then whatever is left on the stack in argument order, each in its
   own eight-byte slot: 8, 9, 8.5, 10 and 9.5, since 7.5 still had d7.  An
   int fills the low word of its slot and the rest is unspecified, so only
   that word is compared.  This is the placement GCC makes for the same
   call.  Apple's variant would have put all twenty on the stack and left
   these registers holding nothing. */
struct banks {
    int64_t x[8];
    double d[8];
    int64_t stack[5];
};
struct banks seen;
__asm__(".text\n"
        ".globl observe_banks\n"
        ".type observe_banks, %function\n"
        "observe_banks:\n"
        "adrp x9, seen\n"
        "add x9, x9, :lo12:seen\n"
        "stp x0, x1, [x9, #0]\n"
        "stp x2, x3, [x9, #16]\n"
        "stp x4, x5, [x9, #32]\n"
        "stp x6, x7, [x9, #48]\n"
        "stp d0, d1, [x9, #64]\n"
        "stp d2, d3, [x9, #80]\n"
        "stp d4, d5, [x9, #96]\n"
        "stp d6, d7, [x9, #112]\n"
        "ldp x10, x11, [sp, #0]\n"
        "stp x10, x11, [x9, #128]\n"
        "ldp x10, x11, [sp, #16]\n"
        "stp x10, x11, [x9, #144]\n"
        "ldr x10, [sp, #32]\n"
        "str x10, [x9, #160]\n"
        "b observed\n"
        ".size observe_banks, .-observe_banks\n");

int32_t observed(void);
int32_t observed(void) {
    static const int32_t integers[] = {10, -7, 250, -30000, 60000, 1, 6, 7};
    static const double reals[] = {0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5};
    for (int i = 0; i < 8; ++i) {
        if ((int32_t)seen.x[i] != integers[i]) return 3;
        if (seen.d[i] != reals[i]) return 4;
    }
    double tail_real[2];
    __builtin_memcpy(&tail_real[0], &seen.stack[2], sizeof(double));
    __builtin_memcpy(&tail_real[1], &seen.stack[4], sizeof(double));
    if ((int32_t)seen.stack[0] != 8 || (int32_t)seen.stack[1] != 9
        || tail_real[0] != 8.5 || (int32_t)seen.stack[3] != 10
        || tail_real[1] != 9.5)
        return 5;
    return 42;
}

extern int32_t landin_check(void);
int main(void) {
    if (c_collect(10, -7, 0.5, 250, 1.5, -30000, 2.5, 60000, 3.5,
                  1, 4.5, 6, 5.5, 7, 6.5, 8, 7.5, 9, 8.5, 10, 9.5) != 42)
        return 1;
    int32_t checked = landin_check();
    if (checked != 42) {
        printf("aapcs64 varargs failed %d\n", checked);
        return 2;
    }
    puts("aapcs64 varargs ok");
    return 42;
}
