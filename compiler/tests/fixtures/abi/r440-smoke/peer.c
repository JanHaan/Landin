#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

#ifndef SMOKE_INCREMENT
#error "the fixture's c-args did not reach the C compiler"
#endif

extern int32_t r440_landin_step(int32_t value);

int32_t r440_c_roundtrip(int32_t value)
{
    int32_t result = r440_landin_step(value) + SMOKE_INCREMENT;

    if (printf("%" PRId32 "\n", result) < 0) {
        return 2;
    }
    return result;
}
