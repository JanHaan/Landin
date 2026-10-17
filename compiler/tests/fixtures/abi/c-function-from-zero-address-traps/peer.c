/* A lookup's address that is zero, which the compiler cannot see. */
#include <stdint.h>

uintptr_t zero_address(void) { return 0; }
