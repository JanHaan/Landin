#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>

typedef int32_t (*callback)(int32_t);
extern int32_t r440_callback(int32_t);
extern int32_t r440_check_pointer_tails(int32_t *, int32_t *);

/* Real, distinct nonnull storage gives C an independent identity oracle;
   neither pointer is fabricated from an integer or merely compared to zero. */
static int32_t data_cell = 314;
static int32_t optional_cell = -271;
static unsigned register_calls;
static unsigned stack_calls;

int32_t r440_collect_pointers(int32_t placement, ...) {
    va_list arguments;
    va_start(arguments, placement);
    if (placement == 1) {
        static const int fillers[] = {11, 22, 33, 44, 55};
        for (unsigned i = 0; i < sizeof fillers / sizeof fillers[0]; ++i) {
            if (va_arg(arguments, int) != fillers[i]) {
                va_end(arguments);
                return 1;
            }
        }
    } else if (placement != 0) {
        va_end(arguments);
        return 2;
    }
    /* All three data carriers have exactly int32_t * type, including the
       named nullable union's empty arm. Code uses its function pointer type,
       never void *, uintptr_t, or any data/function-pointer cast. */
    int32_t *data = va_arg(arguments, int32_t *);
    int32_t *present = va_arg(arguments, int32_t *);
    int32_t *absent = va_arg(arguments, int32_t *);
    callback function = va_arg(arguments, callback);
    va_end(arguments);
    if (data != &data_cell || present != &optional_cell || absent != NULL)
        return 3;
    if (*data != 314 || *present != -271) return 4;
    if (function != r440_callback) return 5;
    if (function(*data) != 633 || function(*present) != -537) return 6;
    if (placement == 0) ++register_calls;
    else ++stack_calls;
    return 42;
}

int main(void) {
    /* Independently compile the same protocols as ordinary C variadic calls
       before asking Landin to produce them. A typed null avoids passing int. */
    if (r440_collect_pointers(0, &data_cell, &optional_cell,
                              (int32_t *)NULL, r440_callback) != 42) return 1;
    if (r440_collect_pointers(1, 11, 22, 33, 44, 55,
                              &data_cell, &optional_cell,
                              (int32_t *)NULL, r440_callback) != 42) return 2;
    register_calls = 0;
    stack_calls = 0;
    if (r440_check_pointer_tails(&data_cell, &optional_cell) != 42) return 3;
    if (register_calls != 2 || stack_calls != 2) return 4;
    if (data_cell != 314 || optional_cell != -271) return 5;
    puts("varargs pointer callback ok");
    return 42;
}
