#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

/* These are actual recursive C array fields, not byte arrays or wrapper rows. */
typedef struct {
    double values[2][3];
} large_matrix;

typedef struct {
    double values[2][1];
} small_matrix;

typedef struct {
    uint8_t tag;
    float values[2][1];
} mixed_matrix;

_Static_assert(sizeof(large_matrix) == 48, "large matrix size");
_Static_assert(_Alignof(large_matrix) == 8, "large matrix alignment");
_Static_assert(offsetof(large_matrix, values) == 0, "large values offset");
_Static_assert(offsetof(large_matrix, values) + 5 * sizeof(double) == 40,
               "large last element offset");

_Static_assert(sizeof(small_matrix) == 16, "small matrix size");
_Static_assert(_Alignof(small_matrix) == 8, "small matrix alignment");
_Static_assert(offsetof(small_matrix, values) == 0, "small values offset");
_Static_assert(offsetof(small_matrix, values) + sizeof(double) == 8,
               "small last element offset");

_Static_assert(sizeof(mixed_matrix) == 12, "mixed matrix size");
_Static_assert(_Alignof(mixed_matrix) == 4, "mixed matrix alignment");
_Static_assert(offsetof(mixed_matrix, tag) == 0, "mixed tag offset");
_Static_assert(offsetof(mixed_matrix, values) == 4, "mixed values offset");
_Static_assert(offsetof(mixed_matrix, values) + sizeof(float) == 8,
               "mixed last element offset");

static const large_matrix c_large_image = {
    .values = {{1.0, 2.0, 3.0}, {4.0, 5.0, 6.0}}
};
static const small_matrix c_small_image = {.values = {{7.0}, {8.0}}};
static const mixed_matrix c_mixed_image = {
    .tag = 9,
    .values = {{10.0f}, {11.0f}}
};

static bool large_is(large_matrix value,
                     double v00, double v01, double v02,
                     double v10, double v11, double v12) {
    return value.values[0][0] == v00
        && value.values[0][1] == v01
        && value.values[0][2] == v02
        && value.values[1][0] == v10
        && value.values[1][1] == v11
        && value.values[1][2] == v12;
}

static bool small_is(small_matrix value, double v00, double v10) {
    return value.values[0][0] == v00 && value.values[1][0] == v10;
}

static bool mixed_is(mixed_matrix value, uint8_t tag, float v00, float v10) {
    return value.tag == tag
        && value.values[0][0] == v00
        && value.values[1][0] == v10;
}

large_matrix c_large(large_matrix value) {
    value.values[0][0] += 1.0;
    value.values[0][1] += 2.0;
    value.values[0][2] += 3.0;
    value.values[1][0] += 4.0;
    value.values[1][1] += 5.0;
    value.values[1][2] += 6.0;
    return value;
}

small_matrix c_small(small_matrix value) {
    value.values[0][0] += 3.0;
    value.values[1][0] += 4.0;
    return value;
}

mixed_matrix c_mixed(mixed_matrix value) {
    value.tag += 1;
    value.values[0][0] += 2.0f;
    value.values[1][0] += 3.0f;
    return value;
}

void c_touch_large(large_matrix *value) {
    value->values[0][0] += 100.0;
    value->values[1][2] += 600.0;
}

bool c_layout(int32_t which, size_t size, size_t alignment) {
    switch (which) {
    case 0:
        return size == sizeof(large_matrix)
            && alignment == _Alignof(large_matrix)
            && offsetof(large_matrix, values) == 0
            && offsetof(large_matrix, values) + 5 * sizeof(double) == 40;
    case 1:
        return size == sizeof(small_matrix)
            && alignment == _Alignof(small_matrix)
            && offsetof(small_matrix, values) == 0
            && offsetof(small_matrix, values) + sizeof(double) == 8;
    case 2:
        return size == sizeof(mixed_matrix)
            && alignment == _Alignof(mixed_matrix)
            && offsetof(mixed_matrix, tag) == 0
            && offsetof(mixed_matrix, values) == 4
            && offsetof(mixed_matrix, values) + sizeof(float) == 8;
    default:
        return false;
    }
}

extern large_matrix l_large(large_matrix value);
extern small_matrix l_small(small_matrix value);
extern mixed_matrix l_mixed(mixed_matrix value);
extern void l_touch_large(large_matrix *value);
extern int32_t landin_check(void);

int main(void) {
    if (landin_check() != 42) {
        return 1;
    }

    large_matrix direct_large = l_large(c_large_image);
    large_matrix (*volatile indirect_large_call)(large_matrix) = l_large;
    large_matrix indirect_large = indirect_large_call(c_large_image);
    if (!large_is(direct_large, 11.0, 22.0, 33.0, 44.0, 55.0, 66.0)
        || !large_is(indirect_large, 11.0, 22.0, 33.0, 44.0, 55.0, 66.0)
        || !large_is(c_large_image, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0)) {
        return 2;
    }

    small_matrix direct_small = l_small(c_small_image);
    small_matrix (*volatile indirect_small_call)(small_matrix) = l_small;
    small_matrix indirect_small = indirect_small_call(c_small_image);
    if (!small_is(direct_small, 17.0, 28.0)
        || !small_is(indirect_small, 17.0, 28.0)
        || !small_is(c_small_image, 7.0, 8.0)) {
        return 3;
    }

    mixed_matrix direct_mixed = l_mixed(c_mixed_image);
    mixed_matrix (*volatile indirect_mixed_call)(mixed_matrix) = l_mixed;
    mixed_matrix indirect_mixed = indirect_mixed_call(c_mixed_image);
    if (!mixed_is(direct_mixed, 19, 30.0f, 41.0f)
        || !mixed_is(indirect_mixed, 19, 30.0f, 41.0f)
        || !mixed_is(c_mixed_image, 9, 10.0f, 11.0f)) {
        return 4;
    }

    large_matrix pointed = c_large_image;
    l_touch_large(&pointed);
    if (!large_is(pointed, 1001.0, 2.0, 3.0, 4.0, 5.0, 6006.0)) {
        return 5;
    }

    puts("native recursive array fields ok");
    return 42;
}
