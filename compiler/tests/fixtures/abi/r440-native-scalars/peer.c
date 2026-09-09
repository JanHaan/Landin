#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
int8_t c_i8(int8_t value) { return value + 1; }
int8_t callback_i8(int8_t (*handler)(int8_t), int8_t value) { return handler(value); }
extern int8_t l_i8(int8_t);
uint8_t c_u8(uint8_t value) { return value + 1; }
uint8_t callback_u8(uint8_t (*handler)(uint8_t), uint8_t value) { return handler(value); }
extern uint8_t l_u8(uint8_t);
int16_t c_i16(int16_t value) { return value + 1; }
int16_t callback_i16(int16_t (*handler)(int16_t), int16_t value) { return handler(value); }
extern int16_t l_i16(int16_t);
uint16_t c_u16(uint16_t value) { return value + 1; }
uint16_t callback_u16(uint16_t (*handler)(uint16_t), uint16_t value) { return handler(value); }
extern uint16_t l_u16(uint16_t);
int32_t c_i32(int32_t value) { return value + 1; }
int32_t callback_i32(int32_t (*handler)(int32_t), int32_t value) { return handler(value); }
extern int32_t l_i32(int32_t);
uint32_t c_u32(uint32_t value) { return value + 1; }
uint32_t callback_u32(uint32_t (*handler)(uint32_t), uint32_t value) { return handler(value); }
extern uint32_t l_u32(uint32_t);
int64_t c_i64(int64_t value) { return value + 1; }
int64_t callback_i64(int64_t (*handler)(int64_t), int64_t value) { return handler(value); }
extern int64_t l_i64(int64_t);
uint64_t c_u64(uint64_t value) { return value + 1; }
uint64_t callback_u64(uint64_t (*handler)(uint64_t), uint64_t value) { return handler(value); }
extern uint64_t l_u64(uint64_t);
intptr_t c_isize(intptr_t value) { return value + 1; }
intptr_t callback_isize(intptr_t (*handler)(intptr_t), intptr_t value) { return handler(value); }
extern intptr_t l_isize(intptr_t);
uintptr_t c_usize(uintptr_t value) { return value + 1; }
uintptr_t callback_usize(uintptr_t (*handler)(uintptr_t), uintptr_t value) { return handler(value); }
extern uintptr_t l_usize(uintptr_t);
float c_f32(float value) { return value + 1; }
float callback_f32(float (*handler)(float), float value) { return handler(value); }
extern float l_f32(float);
double c_f64(double value) { return value + 1; }
double callback_f64(double (*handler)(double), double value) { return handler(value); }
extern double l_f64(double);
bool c_bool(bool value) { return !value; }
extern bool l_bool(bool);
extern int32_t landin_check(void);
int main(void) {
    if (landin_check() != 42) return 1;
    if (l_i8((int8_t)(-100)) != (int8_t)((-100) + 2)) return 2;
    if (l_u8((uint8_t)(230)) != (uint8_t)((230) + 2)) return 3;
    if (l_i16((int16_t)(-30000)) != (int16_t)((-30000) + 2)) return 4;
    if (l_u16((uint16_t)(60000)) != (uint16_t)((60000) + 2)) return 5;
    if (l_i32((int32_t)(-2000000000)) != (int32_t)((-2000000000) + 2)) return 6;
    if (l_u32((uint32_t)(4000000000)) != (uint32_t)((4000000000) + 2)) return 7;
    if (l_i64((int64_t)(-5000000000)) != (int64_t)((-5000000000) + 2)) return 8;
    if (l_u64((uint64_t)(10000000000)) != (uint64_t)((10000000000) + 2)) return 9;
    if (l_isize((intptr_t)(-6000000000)) != (intptr_t)((-6000000000) + 2)) return 10;
    if (l_usize((uintptr_t)(11000000000)) != (uintptr_t)((11000000000) + 2)) return 11;
    if (l_f32((float)(12.5)) != (float)((12.5) + 2)) return 12;
    if (l_f64((double)(-123.25)) != (double)((-123.25) + 2)) return 13;
    if (l_bool(true) || !l_bool(false)) return 20;
    puts("native scalars ok");
    return 42;
}
