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

/* Only this observation needs assembly: C's va_start distinguishes zero
   from nonzero but does not expose the exact vector-register count. The
   actual variadic transport above is independently checked by C va_arg. */
__asm__(".text\n"
        ".globl probe_al\n"
        ".type probe_al, @function\n"
        "probe_al:\n"
        "movzbl %al, %eax\n"
        "ret\n"
        ".size probe_al, .-probe_al\n");
extern int32_t landin_check(void);
int main(void) {
    if (c_collect(10, -7, 0.5, 250, 1.5, -30000, 2.5, 60000, 3.5,
                  1, 4.5, 6, 5.5, 7, 6.5, 8, 7.5, 9, 8.5, 10, 9.5) != 42)
        return 1;
    if (landin_check() != 42) return 2;
    puts("native varargs ok");
    return 42;
}
