#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

/* Match the classifier regression's actual recursive shape, not float[3]. */
typedef struct { float value; } leaf;
typedef struct { leaf values[3]; } nested;
_Static_assert(sizeof(leaf) == 4 && _Alignof(leaf) == 4, "leaf layout");
_Static_assert(sizeof(nested) == 12 && _Alignof(nested) == 4, "nested layout");
_Static_assert(offsetof(nested, values[0].value) == 0, "first leaf offset");
_Static_assert(offsetof(nested, values[1].value) == 4, "second leaf offset");
_Static_assert(offsetof(nested, values[2].value) == 8, "third leaf offset");

nested c_nested3(nested value) {
    value.values[0].value += 8.0f;
    value.values[1].value += 16.0f;
    value.values[2].value += 32.0f;
    return value;
}

nested callback_nested3(nested (*handler)(nested), nested value) {
    return handler(value);
}

bool c_layout(size_t leaf_size, size_t leaf_alignment,
              size_t nested_size, size_t nested_alignment) {
    return leaf_size == sizeof(leaf) && leaf_alignment == _Alignof(leaf)
        && nested_size == sizeof(nested) && nested_alignment == _Alignof(nested);
}

extern nested l_nested3(nested);
extern int32_t landin_check(void);

int main(void) {
    if (landin_check() != 42) return 1;
    nested input = {{{0.5f}, {-3.25f}, {101.5f}}};
    nested result = l_nested3(input);
    if (result.values[0].value != 1.5f
        || result.values[1].value != -1.25f
        || result.values[2].value != 105.5f) return 2;
    if (input.values[0].value != 0.5f
        || input.values[1].value != -3.25f
        || input.values[2].value != 101.5f) return 3;
    puts("native nested shape ok");
    return 42;
}
