/* A protected instruction probe establishes actual hardware execution,
   independently of cpuinfo's interpretation of vendor extension strings. */
#include <stdint.h>
#include <stdio.h>
#include <signal.h>
#include <stdlib.h>
static void unsupported(int signal_number) { (void)signal_number; _Exit(77); }
int main(void) {
    signal(SIGILL, unsupported);
    volatile uint64_t base = 10, index = 4;
    uint64_t result;
    __asm__ volatile ("th.addsl %0, %1, %2, 3" : "=r"(result) : "r"(base), "r"(index));
    if (result != 42) return 1;
    puts("physical xtheadba operation executed: 42");
    return 0;
}
