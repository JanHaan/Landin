#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef int32_t (*handler)(int32_t);

/* These are actual C arrays of function pointers, including a nested array. */
typedef struct {
    handler handlers[2];
} callback_pair;

typedef struct {
    handler handlers[3];
} callback_triple;

typedef struct {
    handler handlers[2][2];
} callback_nested;

_Static_assert(sizeof(handler) == 8, "SysV callback carrier size");
_Static_assert(_Alignof(handler) == 8, "SysV callback carrier alignment");
_Static_assert(sizeof(callback_pair) == 16, "callback pair size");
_Static_assert(_Alignof(callback_pair) == 8, "callback pair alignment");
_Static_assert(offsetof(callback_pair, handlers) == 0, "pair field offset");
_Static_assert(offsetof(callback_pair, handlers) + sizeof(handler) == 8,
               "pair last callback offset");
_Static_assert(sizeof(callback_triple) == 24, "callback triple size");
_Static_assert(_Alignof(callback_triple) == 8, "callback triple alignment");
_Static_assert(offsetof(callback_triple, handlers) == 0, "triple field offset");
_Static_assert(offsetof(callback_triple, handlers) + 2 * sizeof(handler) == 16,
               "triple last callback offset");
_Static_assert(sizeof(callback_nested) == 32, "nested callback size");
_Static_assert(_Alignof(callback_nested) == 8, "nested callback alignment");
_Static_assert(offsetof(callback_nested, handlers) == 0, "nested field offset");
_Static_assert(offsetof(callback_nested, handlers) + 3 * sizeof(handler) == 24,
               "nested last callback offset");

int32_t c_add_one(int32_t value) { return value + 1; }
int32_t c_add_two(int32_t value) { return value + 2; }
int32_t c_add_three(int32_t value) { return value + 3; }
int32_t c_add_four(int32_t value) { return value + 4; }

static const callback_pair c_pair_value = {
    .handlers = {c_add_one, c_add_two}
};
static const callback_triple c_triple_value = {
    .handlers = {c_add_one, c_add_two, c_add_three}
};
static const callback_nested c_nested_value = {
    .handlers = {{c_add_one, c_add_two}, {c_add_three, c_add_four}}
};

callback_pair c_pair(callback_pair value) {
    callback_pair result = {
        .handlers = {value.handlers[1], value.handlers[0]}
    };
    return result;
}

callback_triple c_triple(callback_triple value) {
    callback_triple result = {
        .handlers = {value.handlers[2], value.handlers[0], value.handlers[1]}
    };
    return result;
}

callback_nested c_nested(callback_nested value) {
    callback_nested result = {
        .handlers = {
            {value.handlers[1][1], value.handlers[1][0]},
            {value.handlers[0][1], value.handlers[0][0]}
        }
    };
    return result;
}

callback_pair c_pair_image(void) { return c_pair_value; }
callback_triple c_triple_image(void) { return c_triple_value; }
callback_nested c_nested_image(void) { return c_nested_value; }

void c_touch_pair(callback_pair *value) {
    value->handlers[0] = c_add_three;
    value->handlers[1] = c_add_four;
}

void c_touch_nested(callback_nested *value) {
    value->handlers[0][0] = c_add_four;
    value->handlers[1][1] = c_add_one;
}

bool c_layout(int32_t which, size_t size, size_t alignment) {
    switch (which) {
    case 0:
        return size == sizeof(callback_pair)
            && alignment == _Alignof(callback_pair)
            && offsetof(callback_pair, handlers) == 0
            && offsetof(callback_pair, handlers) + sizeof(handler) == 8;
    case 1:
        return size == sizeof(callback_triple)
            && alignment == _Alignof(callback_triple)
            && offsetof(callback_triple, handlers) == 0
            && offsetof(callback_triple, handlers) + 2 * sizeof(handler) == 16;
    case 2:
        return size == sizeof(callback_nested)
            && alignment == _Alignof(callback_nested)
            && offsetof(callback_nested, handlers) == 0
            && offsetof(callback_nested, handlers) + 3 * sizeof(handler) == 24;
    default:
        return false;
    }
}

extern callback_pair l_pair(callback_pair value);
extern callback_triple l_triple(callback_triple value);
extern callback_nested l_nested(callback_nested value);
extern callback_pair l_pair_image(void);
extern callback_triple l_triple_image(void);
extern callback_nested l_nested_image(void);
extern void l_touch_pair(callback_pair *value);
extern void l_touch_nested(callback_nested *value);
extern int32_t landin_check(void);

static bool pair_is(callback_pair value, int32_t first, int32_t second) {
    return value.handlers[0](100) == first
        && value.handlers[1](100) == second;
}

static bool triple_is(callback_triple value,
                      int32_t first, int32_t second, int32_t third) {
    return value.handlers[0](100) == first
        && value.handlers[1](100) == second
        && value.handlers[2](100) == third;
}

static bool nested_is(callback_nested value,
                      int32_t v00, int32_t v01,
                      int32_t v10, int32_t v11) {
    return value.handlers[0][0](100) == v00
        && value.handlers[0][1](100) == v01
        && value.handlers[1][0](100) == v10
        && value.handlers[1][1](100) == v11;
}

int main(void) {
    if (landin_check() != 42) {
        return 1;
    }

    callback_pair landin_pair_image = l_pair_image();
    callback_triple landin_triple_image = l_triple_image();
    callback_nested landin_nested_image = l_nested_image();
    if (!pair_is(landin_pair_image, 110, 120)
        || !triple_is(landin_triple_image, 110, 120, 130)
        || !nested_is(landin_nested_image, 110, 120, 130, 140)) {
        return 2;
    }

    callback_pair direct_pair = l_pair(c_pair_value);
    callback_pair (*volatile pair_function)(callback_pair) = l_pair;
    callback_pair indirect_pair = pair_function(c_pair_value);
    if (!pair_is(direct_pair, 102, 101)
        || !pair_is(indirect_pair, 102, 101)
        || !pair_is(c_pair_value, 101, 102)) {
        return 3;
    }

    callback_triple direct_triple = l_triple(c_triple_value);
    callback_triple (*volatile triple_function)(callback_triple) = l_triple;
    callback_triple indirect_triple = triple_function(c_triple_value);
    if (!triple_is(direct_triple, 103, 101, 102)
        || !triple_is(indirect_triple, 103, 101, 102)
        || !triple_is(c_triple_value, 101, 102, 103)) {
        return 4;
    }

    callback_nested direct_nested = l_nested(c_nested_value);
    callback_nested (*volatile nested_function)(callback_nested) = l_nested;
    callback_nested indirect_nested = nested_function(c_nested_value);
    if (!nested_is(direct_nested, 104, 103, 102, 101)
        || !nested_is(indirect_nested, 104, 103, 102, 101)
        || !nested_is(c_nested_value, 101, 102, 103, 104)) {
        return 5;
    }

    callback_pair pointed_pair = c_pair_value;
    l_touch_pair(&pointed_pair);
    if (!pair_is(pointed_pair, 130, 140)) {
        return 6;
    }

    callback_nested pointed_nested = c_nested_value;
    l_touch_nested(&pointed_nested);
    if (!nested_is(pointed_nested, 140, 102, 103, 110)) {
        return 7;
    }

    puts("native callback array fields ok");
    return 42;
}
