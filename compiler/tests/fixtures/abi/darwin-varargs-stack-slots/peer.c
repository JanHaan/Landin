#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int32_t cell = 314;

static int32_t collect(int32_t count, va_list arguments) {
    if (count != 12) return 1;
    if (va_arg(arguments, int) != -7) return 2;
    if (va_arg(arguments, int) != 250) return 3;
    if (va_arg(arguments, int) != -30000) return 4;
    if (va_arg(arguments, int) != 60000) return 5;
    if (va_arg(arguments, int) != 1) return 6;
    if (va_arg(arguments, double) != 0.5) return 7;
    if (va_arg(arguments, double) != 1.5) return 8;
    if (va_arg(arguments, int64_t) != -5000000000LL) return 9;
    if (va_arg(arguments, uint64_t) != 0xfedcba9876543210ULL) return 10;
    if (va_arg(arguments, int32_t *) != &cell) return 11;
    if (va_arg(arguments, int32_t *) != NULL) return 12;
    if (va_arg(arguments, double) != 9.25) return 13;
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
    return bias == 12.5 ? result : 14;
}

/* Where Apple's ABI places them, which va_arg cannot show: the named count
   in w0 and all twelve unnamed arguments on the stack, one eight-byte slot
   each in argument order from the caller's sp.  A promoted int fills the
   low word of its slot and the rest is unspecified, so only that word is
   compared.  The standard AAPCS64 would have put the first seven integers
   in x1-x7 and the doubles in d0-d2 instead. */
struct slots {
    int64_t count;
    int64_t stack[12];
};
struct slots seen;
__asm__(".text\n"
        ".globl _observe_slots\n"
        ".p2align 2\n"
        "_observe_slots:\n"
        "adrp x9, _seen@PAGE\n"
        "add x9, x9, _seen@PAGEOFF\n"
        "str x0, [x9, #0]\n"
        "ldp x10, x11, [sp, #0]\n"
        "stp x10, x11, [x9, #8]\n"
        "ldp x10, x11, [sp, #16]\n"
        "stp x10, x11, [x9, #24]\n"
        "ldp x10, x11, [sp, #32]\n"
        "stp x10, x11, [x9, #40]\n"
        "ldp x10, x11, [sp, #48]\n"
        "stp x10, x11, [x9, #56]\n"
        "ldp x10, x11, [sp, #64]\n"
        "stp x10, x11, [x9, #72]\n"
        "ldp x10, x11, [sp, #80]\n"
        "stp x10, x11, [x9, #88]\n"
        "b _observed\n");

int32_t observed(void);
int32_t observed(void) {
    static const int32_t promoted[] = {-7, 250, -30000, 60000, 1};
    double reals[3];
    if ((int32_t)seen.count != 12) return 15;
    for (int i = 0; i < 5; ++i)
        if ((int32_t)seen.stack[i] != promoted[i]) return 16;
    memcpy(&reals[0], &seen.stack[5], sizeof(double));
    memcpy(&reals[1], &seen.stack[6], sizeof(double));
    memcpy(&reals[2], &seen.stack[11], sizeof(double));
    if (reals[0] != 0.5 || reals[1] != 1.5 || reals[2] != 9.25) return 17;
    if (seen.stack[7] != -5000000000LL
        || (uint64_t)seen.stack[8] != 0xfedcba9876543210ULL)
        return 18;
    if ((uintptr_t)seen.stack[9] != (uintptr_t)&cell || seen.stack[10] != 0)
        return 19;
    return 42;
}

extern int32_t landin_check(int32_t *cell);
int main(void) {
    if (c_collect(12, -7, 250, -30000, 60000, 1, 0.5, 1.5, -5000000000LL,
                  0xfedcba9876543210ULL, &cell, (int32_t *)NULL, 9.25) != 42)
        return 1;
    int32_t checked = landin_check(&cell);
    if (checked != 42) {
        printf("darwin varargs failed %d\n", checked);
        return 2;
    }
    puts("darwin varargs ok");
    return 42;
}
