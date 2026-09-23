#include <stdint.h>
#include <stdio.h>
typedef struct { uint8_t v[3]; } p3;
typedef struct { uint8_t v[5]; } p5;
typedef struct { float a; float b; float c; } h3;
int32_t c_packed(int64_t a0, int64_t a1, int64_t a2, int64_t a3, int64_t a4, int64_t a5, int64_t a6, int64_t a7, p3 s, uint8_t c, p5 t, int16_t d) {
    return a0 == 10 &&
           a1 == 11 &&
           a2 == 12 &&
           a3 == 13 &&
           a4 == 14 &&
           a5 == 15 &&
           a6 == 16 &&
           a7 == 17 &&
           s.v[0] == 1 &&
           s.v[1] == 2 &&
           s.v[2] == 3 &&
           c == 9 &&
           t.v[0] == 4 &&
           t.v[1] == 5 &&
           t.v[2] == 6 &&
           t.v[3] == 7 &&
           t.v[4] == 8 &&
           d == 77 ? 42 : 1;
}
extern int32_t l_packed(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, p3, uint8_t, p5, int16_t);
int32_t c_mixed(int64_t a0, int64_t a1, int64_t a2, int64_t a3, int64_t a4, int64_t a5, int64_t a6, int64_t a7, double f0, double f1, double f2, double f3, double f4, double f5, double f6, double f7, h3 h, uint8_t c, h3 k, p3 s, float x, int16_t d) {
    (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
    (void)f1; (void)f2; (void)f3; (void)f4; (void)f5; (void)f6;
    return a0 == 20 &&
           a7 == 27 &&
           f0 == 0.5 &&
           f7 == 7.5 &&
           h.a == 1.5f &&
           h.b == 2.5f &&
           h.c == 3.5f &&
           c == 10 &&
           k.a == 4.5f &&
           k.b == 5.5f &&
           k.c == 6.5f &&
           s.v[0] == 7 &&
           s.v[1] == 8 &&
           s.v[2] == 9 &&
           x == 11.5f &&
           d == 12 ? 42 : 1;
}
extern int32_t l_mixed(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, double, double, double, double, double, double, double, double, h3, uint8_t, h3, p3, float, int16_t);
extern int32_t landin_check(void);
int main(void) {
    if (landin_check() != 42) return 1;
    int32_t result_0 = l_packed(10, 11, 12, 13, 14, 15, 16, 17, (p3){{1, 2, 3}}, 9, (p5){{4, 5, 6, 7, 8}}, 77);
    if (result_0 != 42) return 2;
    int32_t result_1 = l_mixed(20, 21, 22, 23, 24, 25, 26, 27, 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, (h3){1.5f, 2.5f, 3.5f}, 10, (h3){4.5f, 5.5f, 6.5f}, (p3){{7, 8, 9}}, 11.5f, 12);
    if (result_1 != 42) return 3;
    puts("stack composite slots ok");
    return 42;
}
