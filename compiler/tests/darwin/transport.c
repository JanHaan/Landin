#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <errno.h>
#include <fcntl.h>

_Static_assert(sizeof(void *) == 8 && _Alignof(void *) == 8, "pointer");
_Static_assert(sizeof(long) == 8 && sizeof(int) == 4 && (char)-1 < 0, "LP64");
_Static_assert(EPERM == 1 && ENOENT == 2 && EINTR == 4 && EACCES == 13 && EROFS == 30,
               "shared core/io errno mapping");
_Static_assert((O_WRONLY | O_CREAT | O_TRUNC) == 1537, "Darwin open flags");
_Static_assert(sizeof(float) == 4 && _Alignof(float) == 4 &&
               sizeof(double) == 8 && _Alignof(double) == 8, "float layout");
typedef struct { double values[4]; } hfa;
typedef struct { uint64_t a, b; } pair;
typedef struct { uint64_t a, b, c; } large;
extern int32_t l_narrow(int8_t i0, int8_t i1, int8_t i2, int8_t i3, int8_t i4, int8_t i5, int8_t i6, int8_t i7, int8_t i8, int8_t i9, int16_t tail);
int32_t c_narrow(int8_t i0, int8_t i1, int8_t i2, int8_t i3, int8_t i4, int8_t i5, int8_t i6, int8_t i7, int8_t i8, int8_t i9, int16_t tail) { return i0 == -1 && i1 == -2 && i2 == -3 && i3 == -4 && i4 == -5 && i5 == -6 && i6 == -7 && i7 == -8 && i8 == -9 && i9 == -10 && tail == -1234 ? 42 : 1; }
extern int32_t l_gp(uint64_t i0, uint64_t i1, uint64_t i2, uint64_t i3, uint64_t i4, uint64_t i5, uint64_t i6, pair p, int8_t tail);
int32_t c_gp(uint64_t i0, uint64_t i1, uint64_t i2, uint64_t i3, uint64_t i4, uint64_t i5, uint64_t i6, pair p, int8_t tail) { return i0 == 1 && i1 == 2 && i2 == 3 && i3 == 4 && i4 == 5 && i5 == 6 && i6 == 7 && p.a == 20 && p.b == 21 && tail == -12 ? 42 : 1; }
extern int32_t l_fp(double f0, double f1, double f2, double f3, double f4, double f5, hfa h, float tail);
int32_t c_fp(double f0, double f1, double f2, double f3, double f4, double f5, hfa h, float tail) { return f0 == 1.0 && f1 == 2.0 && f2 == 3.0 && f3 == 4.0 && f4 == 5.0 && f5 == 6.0 && h.values[0] == 10.0 && h.values[1] == 11.0 && h.values[2] == 12.0 && h.values[3] == 13.0 && tail == 14.0 ? 42 : 1; }
extern int32_t l_check(void);
int32_t _r530_double(void) { return 42; }
int32_t punctuation(void) __asm__("_.$r530");
int32_t punctuation(void) { return 42; }
extern int32_t l_frame(void);
__attribute__((noinline)) int32_t c_frame(void) {
    uintptr_t *frame = __builtin_frame_address(0);
    uintptr_t parent = frame[0];
    /* This C routine was entered from Landin. Its saved parent is the
       Landin frame, and its return address belongs to l_frame. */
    uintptr_t pc = frame[1];
    uintptr_t entry = (uintptr_t)&l_frame;
    return parent > (uintptr_t)frame && parent % 16 == 0 &&
           pc > entry && pc - entry < 4096 ? 42 : 1;
}
extern large l_large(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
large c_large(uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f, uint64_t g, uint64_t h) { return (large){a+b+c,d+e+f,g+h}; }
int main(void) {
    if (l_frame() != 42) return 3;
    if (l_narrow(-1, -2, -3, -4, -5, -6, -7, -8, -9, -10, -1234) != 42) return 1;
    if (l_gp(1, 2, 3, 4, 5, 6, 7, (pair){20,21}, -12) != 42) return 1;
    if (l_fp(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, (hfa){{10,11,12,13}}, 14.0) != 42) return 1;
    large value = l_large(1,2,3,4,5,6,7,8);
    if (value.a != 6 || value.b != 15 || value.c != 15 || l_check() != 42) return 2;
    puts("Darwin transport ok");
    return 42;
}
