#include <stdint.h>
#include <stdio.h>
typedef struct { uint64_t first; uint64_t second; } pair_i;
typedef struct { uint64_t first; double second; } mixed;
typedef struct { double first; double second; } pair_s;
typedef struct { uint64_t first; double second; uint64_t third; } large;
typedef struct { uint8_t first; uint8_t second; uint8_t third; } partial;
int32_t c_gp_mixed(uint64_t p0, uint64_t p1, uint64_t p2, uint64_t p3, uint64_t p4, uint64_t p5, mixed p6, double p7, uint64_t p8, partial p9, large p10, double p11) {
    return p0 == 3 &&
           p1 == 6 &&
           p2 == 9 &&
           p3 == 12 &&
           p4 == 15 &&
           p5 == 18 &&
           p6.first == 21 &&
           p6.second == 22.5 &&
           p7 == 24.5 &&
           p8 == 27 &&
           p9.first == 30 &&
           p9.second == 31 &&
           p9.third == 32 &&
           p10.first == 33 &&
           p10.second == 34.5 &&
           p10.third == 35 &&
           p11 == 36.5 ? 42 : 1;
}
extern int32_t l_gp_mixed(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, mixed, double, uint64_t, partial, large, double);
int32_t c_gp_pair(uint64_t p0, uint64_t p1, uint64_t p2, uint64_t p3, uint64_t p4, pair_i p5, uint64_t p6, uint64_t p7) {
    return p0 == 3 &&
           p1 == 6 &&
           p2 == 9 &&
           p3 == 12 &&
           p4 == 15 &&
           p5.first == 18 &&
           p5.second == 19 &&
           p6 == 21 &&
           p7 == 24 ? 42 : 1;
}
extern int32_t l_gp_pair(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, pair_i, uint64_t, uint64_t);
int32_t c_sse_mixed(double p0, double p1, double p2, double p3, double p4, double p5, double p6, double p7, mixed p8, uint64_t p9, double p10) {
    return p0 == 3.5 &&
           p1 == 6.5 &&
           p2 == 9.5 &&
           p3 == 12.5 &&
           p4 == 15.5 &&
           p5 == 18.5 &&
           p6 == 21.5 &&
           p7 == 24.5 &&
           p8.first == 27 &&
           p8.second == 28.5 &&
           p9 == 30 &&
           p10 == 33.5 ? 42 : 1;
}
extern int32_t l_sse_mixed(double, double, double, double, double, double, double, double, mixed, uint64_t, double);
int32_t c_sse_pair(double p0, double p1, double p2, double p3, double p4, double p5, double p6, pair_s p7, double p8, uint64_t p9) {
    return p0 == 3.5 &&
           p1 == 6.5 &&
           p2 == 9.5 &&
           p3 == 12.5 &&
           p4 == 15.5 &&
           p5 == 18.5 &&
           p6 == 21.5 &&
           p7.first == 24.5 &&
           p7.second == 25.5 &&
           p8 == 27.5 &&
           p9 == 30 ? 42 : 1;
}
extern int32_t l_sse_pair(double, double, double, double, double, double, double, pair_s, double, uint64_t);
int32_t c_both(uint64_t p0, uint64_t p1, uint64_t p2, uint64_t p3, uint64_t p4, uint64_t p5, double p6, double p7, double p8, double p9, double p10, double p11, double p12, double p13, pair_i p14, pair_s p15, mixed p16, partial p17) {
    return p0 == 3 &&
           p1 == 6 &&
           p2 == 9 &&
           p3 == 12 &&
           p4 == 15 &&
           p5 == 18 &&
           p6 == 21.5 &&
           p7 == 24.5 &&
           p8 == 27.5 &&
           p9 == 30.5 &&
           p10 == 33.5 &&
           p11 == 36.5 &&
           p12 == 39.5 &&
           p13 == 42.5 &&
           p14.first == 45 &&
           p14.second == 46 &&
           p15.first == 48.5 &&
           p15.second == 49.5 &&
           p16.first == 51 &&
           p16.second == 52.5 &&
           p17.first == 54 &&
           p17.second == 55 &&
           p17.third == 56 ? 42 : 1;
}
extern int32_t l_both(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, double, double, double, double, double, double, double, double, pair_i, pair_s, mixed, partial);
int32_t c_memory_live(large p0, uint64_t p1, double p2, large p3, uint64_t p4, double p5) {
    return p0.first == 3 &&
           p0.second == 4.5 &&
           p0.third == 5 &&
           p1 == 6 &&
           p2 == 9.5 &&
           p3.first == 12 &&
           p3.second == 13.5 &&
           p3.third == 14 &&
           p4 == 15 &&
           p5 == 18.5 ? 42 : 1;
}
extern int32_t l_memory_live(large, uint64_t, double, large, uint64_t, double);
large c_sret(uint64_t p0, uint64_t p1, uint64_t p2, uint64_t p3, uint64_t p4, mixed p5, double p6, uint64_t p7, large p8) {
    return p0 == 3 &&
           p1 == 6 &&
           p2 == 9 &&
           p3 == 12 &&
           p4 == 15 &&
           p5.first == 18 &&
           p5.second == 19.5 &&
           p6 == 21.5 &&
           p7 == 24 &&
           p8.first == 27 &&
           p8.second == 28.5 &&
           p8.third == 29 ? (large){42, 43.5, 44} : (large){1, 1, 1};
}
extern large l_sret(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, mixed, double, uint64_t, large);
extern int32_t landin_check(void);
int main(void) {
    if (landin_check() != 42) return 1;
    int32_t result_0 = l_gp_mixed(3, 6, 9, 12, 15, 18, (mixed){21, 22.5}, 24.5, 27, (partial){30, 31, 32}, (large){33, 34.5, 35}, 36.5);
    if (result_0 != 42) return 2;
    int32_t result_1 = l_gp_pair(3, 6, 9, 12, 15, (pair_i){18, 19}, 21, 24);
    if (result_1 != 42) return 3;
    int32_t result_2 = l_sse_mixed(3.5, 6.5, 9.5, 12.5, 15.5, 18.5, 21.5, 24.5, (mixed){27, 28.5}, 30, 33.5);
    if (result_2 != 42) return 4;
    int32_t result_3 = l_sse_pair(3.5, 6.5, 9.5, 12.5, 15.5, 18.5, 21.5, (pair_s){24.5, 25.5}, 27.5, 30);
    if (result_3 != 42) return 5;
    int32_t result_4 = l_both(3, 6, 9, 12, 15, 18, 21.5, 24.5, 27.5, 30.5, 33.5, 36.5, 39.5, 42.5, (pair_i){45, 46}, (pair_s){48.5, 49.5}, (mixed){51, 52.5}, (partial){54, 55, 56});
    if (result_4 != 42) return 6;
    int32_t result_5 = l_memory_live((large){3, 4.5, 5}, 6, 9.5, (large){12, 13.5, 14}, 15, 18.5);
    if (result_5 != 42) return 7;
    large result_6 = l_sret(3, 6, 9, 12, 15, (mixed){18, 19.5}, 21.5, 24, (large){27, 28.5, 29});
    if (result_6.first != 42 || result_6.second != 43.5 || result_6.third != 44) return 8;
    puts("native banks ok");
    return 42;
}
