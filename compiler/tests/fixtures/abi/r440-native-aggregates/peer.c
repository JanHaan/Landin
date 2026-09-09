#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

/* Real C caller and callee. No assembly or Landin-generated C shims. */
typedef struct { uint64_t value; } one_i;
typedef struct { double value; } one_s;
typedef struct { uint64_t first; uint64_t second; } two_ii;
typedef struct { uint64_t first; double second; } two_is;
typedef struct { double first; uint64_t second; } two_si;
typedef struct { double first; double second; } two_ss;
typedef struct { float values[2]; } floats2;
typedef struct { float values[3]; } floats3;
typedef struct { uint8_t values[3]; } partial3;
typedef struct { uint8_t values[5]; } partial5;
typedef struct { uint8_t values[7]; } partial7;
typedef struct { int32_t values[3]; } partial12;
typedef struct { double values[3]; } large;
typedef struct { one_s values[2]; } nested;
typedef struct { two_is values[2]; } nested_large;
one_i c_one_i(one_i value) {
    value.value += 1;
    return value;
}
extern one_i l_one_i(one_i);
one_i callback_one_i(one_i (*handler)(one_i), one_i value) {
    return handler(value);
}

one_s c_one_s(one_s value) {
    value.value += 1;
    return value;
}
extern one_s l_one_s(one_s);
one_s callback_one_s(one_s (*handler)(one_s), one_s value) {
    return handler(value);
}

two_ii c_two_ii(two_ii value) {
    value.first += 1;
    value.second += 1;
    return value;
}
extern two_ii l_two_ii(two_ii);
two_ii callback_two_ii(two_ii (*handler)(two_ii), two_ii value) {
    return handler(value);
}

two_is c_two_is(two_is value) {
    value.first += 1;
    value.second += 1;
    return value;
}
extern two_is l_two_is(two_is);
two_is callback_two_is(two_is (*handler)(two_is), two_is value) {
    return handler(value);
}

two_si c_two_si(two_si value) {
    value.first += 1;
    value.second += 1;
    return value;
}
extern two_si l_two_si(two_si);
two_si callback_two_si(two_si (*handler)(two_si), two_si value) {
    return handler(value);
}

two_ss c_two_ss(two_ss value) {
    value.first += 1;
    value.second += 1;
    return value;
}
extern two_ss l_two_ss(two_ss);
two_ss callback_two_ss(two_ss (*handler)(two_ss), two_ss value) {
    return handler(value);
}

floats2 c_floats2(floats2 value) {
    value.values[0] += 1;
    value.values[1] += 1;
    return value;
}
extern floats2 l_floats2(floats2);
floats2 callback_floats2(floats2 (*handler)(floats2), floats2 value) {
    return handler(value);
}

floats3 c_floats3(floats3 value) {
    value.values[0] += 1;
    value.values[1] += 1;
    value.values[2] += 1;
    return value;
}
extern floats3 l_floats3(floats3);
floats3 callback_floats3(floats3 (*handler)(floats3), floats3 value) {
    return handler(value);
}

partial3 c_partial3(partial3 value) {
    value.values[0] += 1;
    value.values[1] += 1;
    value.values[2] += 1;
    return value;
}
extern partial3 l_partial3(partial3);
partial3 callback_partial3(partial3 (*handler)(partial3), partial3 value) {
    return handler(value);
}

partial5 c_partial5(partial5 value) {
    value.values[0] += 1;
    value.values[1] += 1;
    value.values[2] += 1;
    value.values[3] += 1;
    value.values[4] += 1;
    return value;
}
extern partial5 l_partial5(partial5);
partial5 callback_partial5(partial5 (*handler)(partial5), partial5 value) {
    return handler(value);
}

partial7 c_partial7(partial7 value) {
    value.values[0] += 1;
    value.values[1] += 1;
    value.values[2] += 1;
    value.values[3] += 1;
    value.values[4] += 1;
    value.values[5] += 1;
    value.values[6] += 1;
    return value;
}
extern partial7 l_partial7(partial7);
partial7 callback_partial7(partial7 (*handler)(partial7), partial7 value) {
    return handler(value);
}

partial12 c_partial12(partial12 value) {
    value.values[0] += 1;
    value.values[1] += 1;
    value.values[2] += 1;
    return value;
}
extern partial12 l_partial12(partial12);
partial12 callback_partial12(partial12 (*handler)(partial12), partial12 value) {
    return handler(value);
}

large c_large(large value) {
    value.values[0] += 1;
    value.values[1] += 1;
    value.values[2] += 1;
    return value;
}
extern large l_large(large);
large callback_large(large (*handler)(large), large value) {
    return handler(value);
}

nested c_nested(nested value) {
    value.values[0].value += 1;
    value.values[1].value += 1;
    return value;
}
extern nested l_nested(nested);
nested callback_nested(nested (*handler)(nested), nested value) {
    return handler(value);
}

nested_large c_nested_large(nested_large value) {
    value.values[0].first += 1;
    value.values[0].second += 1;
    value.values[1].first += 1;
    value.values[1].second += 1;
    return value;
}
extern nested_large l_nested_large(nested_large);
nested_large callback_nested_large(nested_large (*handler)(nested_large), nested_large value) {
    return handler(value);
}

typedef struct { float real; uint32_t integer; } merged0;
_Static_assert(sizeof(merged0) == 8 && _Alignof(merged0) == 4, "merged layout");
_Static_assert(offsetof(merged0, integer) == 4, "merged offset");
merged0 c_merged0(merged0 value) { value.real += 1; value.integer += 1; return value; }
extern merged0 l_merged0(merged0);
typedef struct { uint32_t integer; float real; } merged1;
_Static_assert(sizeof(merged1) == 8 && _Alignof(merged1) == 4, "merged layout");
_Static_assert(offsetof(merged1, real) == 4, "merged offset");
merged1 c_merged1(merged1 value) { value.real += 1; value.integer += 1; return value; }
extern merged1 l_merged1(merged1);

bool c_layout(int32_t which, size_t size, size_t alignment) {
    switch (which) {
    case 0: return size == sizeof(one_i) && alignment == _Alignof(one_i);
    case 1: return size == sizeof(one_s) && alignment == _Alignof(one_s);
    case 2: return size == sizeof(two_ii) && alignment == _Alignof(two_ii);
    case 3: return size == sizeof(two_is) && alignment == _Alignof(two_is);
    case 4: return size == sizeof(two_si) && alignment == _Alignof(two_si);
    case 5: return size == sizeof(two_ss) && alignment == _Alignof(two_ss);
    case 6: return size == sizeof(floats2) && alignment == _Alignof(floats2);
    case 7: return size == sizeof(floats3) && alignment == _Alignof(floats3);
    case 8: return size == sizeof(partial3) && alignment == _Alignof(partial3);
    case 9: return size == sizeof(partial5) && alignment == _Alignof(partial5);
    case 10: return size == sizeof(partial7) && alignment == _Alignof(partial7);
    case 11: return size == sizeof(partial12) && alignment == _Alignof(partial12);
    case 12: return size == sizeof(large) && alignment == _Alignof(large);
    case 13: return size == sizeof(nested) && alignment == _Alignof(nested);
    case 14: return size == sizeof(nested_large) && alignment == _Alignof(nested_large);
    default: return false;
    }
}

_Static_assert(offsetof(two_ii, second) == 8, "two_ii second");
_Static_assert(offsetof(two_is, second) == 8, "two_is second");
_Static_assert(offsetof(two_si, second) == 8, "two_si second");
_Static_assert(offsetof(two_ss, second) == 8, "two_ss second");
extern int32_t landin_check(void);
int main(void) {
    if (landin_check() != 42) return 1;
    one_i input_0 = {10};
    one_i result_0 = l_one_i(input_0);
    if (result_0.value != input_0.value + 2) return 2;
    one_s input_1 = {10.0};
    one_s result_1 = l_one_s(input_1);
    if (result_1.value != input_1.value + 2) return 3;
    two_ii input_2 = {10, 11};
    two_ii result_2 = l_two_ii(input_2);
    if (result_2.first != input_2.first + 2) return 4;
    if (result_2.second != input_2.second + 2) return 4;
    two_is input_3 = {10, 11.0};
    two_is result_3 = l_two_is(input_3);
    if (result_3.first != input_3.first + 2) return 5;
    if (result_3.second != input_3.second + 2) return 5;
    two_si input_4 = {10.0, 11};
    two_si result_4 = l_two_si(input_4);
    if (result_4.first != input_4.first + 2) return 6;
    if (result_4.second != input_4.second + 2) return 6;
    two_ss input_5 = {10.0, 11.0};
    two_ss result_5 = l_two_ss(input_5);
    if (result_5.first != input_5.first + 2) return 7;
    if (result_5.second != input_5.second + 2) return 7;
    floats2 input_6 = {{10.0, 11.0}};
    floats2 result_6 = l_floats2(input_6);
    if (result_6.values[0] != input_6.values[0] + 2) return 8;
    if (result_6.values[1] != input_6.values[1] + 2) return 8;
    floats3 input_7 = {{10.0, 11.0, 12.0}};
    floats3 result_7 = l_floats3(input_7);
    if (result_7.values[0] != input_7.values[0] + 2) return 9;
    if (result_7.values[1] != input_7.values[1] + 2) return 9;
    if (result_7.values[2] != input_7.values[2] + 2) return 9;
    partial3 input_8 = {{10, 11, 12}};
    partial3 result_8 = l_partial3(input_8);
    if (result_8.values[0] != input_8.values[0] + 2) return 10;
    if (result_8.values[1] != input_8.values[1] + 2) return 10;
    if (result_8.values[2] != input_8.values[2] + 2) return 10;
    partial5 input_9 = {{10, 11, 12, 13, 14}};
    partial5 result_9 = l_partial5(input_9);
    if (result_9.values[0] != input_9.values[0] + 2) return 11;
    if (result_9.values[1] != input_9.values[1] + 2) return 11;
    if (result_9.values[2] != input_9.values[2] + 2) return 11;
    if (result_9.values[3] != input_9.values[3] + 2) return 11;
    if (result_9.values[4] != input_9.values[4] + 2) return 11;
    partial7 input_10 = {{10, 11, 12, 13, 14, 15, 16}};
    partial7 result_10 = l_partial7(input_10);
    if (result_10.values[0] != input_10.values[0] + 2) return 12;
    if (result_10.values[1] != input_10.values[1] + 2) return 12;
    if (result_10.values[2] != input_10.values[2] + 2) return 12;
    if (result_10.values[3] != input_10.values[3] + 2) return 12;
    if (result_10.values[4] != input_10.values[4] + 2) return 12;
    if (result_10.values[5] != input_10.values[5] + 2) return 12;
    if (result_10.values[6] != input_10.values[6] + 2) return 12;
    partial12 input_11 = {{10, 11, 12}};
    partial12 result_11 = l_partial12(input_11);
    if (result_11.values[0] != input_11.values[0] + 2) return 13;
    if (result_11.values[1] != input_11.values[1] + 2) return 13;
    if (result_11.values[2] != input_11.values[2] + 2) return 13;
    large input_12 = {{10.0, 11.0, 12.0}};
    large result_12 = l_large(input_12);
    if (result_12.values[0] != input_12.values[0] + 2) return 14;
    if (result_12.values[1] != input_12.values[1] + 2) return 14;
    if (result_12.values[2] != input_12.values[2] + 2) return 14;
    nested input_13 = {{{10.0}, {11.0}}};
    nested result_13 = l_nested(input_13);
    if (result_13.values[0].value != input_13.values[0].value + 2) return 15;
    if (result_13.values[1].value != input_13.values[1].value + 2) return 15;
    nested_large input_14 = {{{10, 11.0}, {11, 12.0}}};
    nested_large result_14 = l_nested_large(input_14);
    if (result_14.values[0].first != input_14.values[0].first + 2) return 16;
    if (result_14.values[0].second != input_14.values[0].second + 2) return 16;
    if (result_14.values[1].first != input_14.values[1].first + 2) return 16;
    if (result_14.values[1].second != input_14.values[1].second + 2) return 16;
    merged0 merged_result0 = l_merged0((merged0){.real = 4.5f, .integer = 25});
    if (merged_result0.real != 6.5f || merged_result0.integer != 27) return 20;
    merged1 merged_result1 = l_merged1((merged1){.real = 4.5f, .integer = 25});
    if (merged_result1.real != 6.5f || merged_result1.integer != 27) return 20;
    puts("native aggregates ok");
    return 42;
}
