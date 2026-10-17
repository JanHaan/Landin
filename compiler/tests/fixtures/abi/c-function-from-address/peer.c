/*
 * Gives the Landin program the addresses of C functions as plain integers,
 * as a loader's symbol lookup does, and checks that what the program makes
 * of them reaches C again as the same function pointer.
 */
#include <stdint.h>

static int add(int a, int b) { return a + b; }

static double scaled(double value, int times) { return value * times; }

uintptr_t address_of_add(void) { return (uintptr_t)&add; }

uintptr_t address_of_scaled(void) { return (uintptr_t)&scaled; }

/* Calls back what it is given, and says whether it is `add` itself. */
int same_as_add(int (*given)(int, int)) {
    return given == &add ? given(20, 22) : -1;
}
