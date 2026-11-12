/*
 * Takes the addresses a Landin program gives as plain integers: says
 * whether one is the function pointer C has for `add`, and calls one
 * through a function pointer made from it.
 */
#include <stdint.h>

int add(int a, int b) { return a + b; }

int is_add(uintptr_t address) {
    return address == (uintptr_t)&add ? 1 : 0;
}

int call_at(uintptr_t address, int a, int b) {
    int (*called)(int, int) = (int (*)(int, int))address;
    return called(a, b);
}
