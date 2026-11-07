/* What the program and its C peer exchange, as C declares it.  The
   program declares the same in Landin (program.ldn); every C routine here
   checks each value it receives against the one the program sends and
   returns 0, or the code of the first check that failed, a code of its
   own for each. */
#ifndef CORTEX_C_PEER_H
#define CORTEX_C_PEER_H

#include <stdbool.h>
#include <stdint.h>

/* AAPCS32 under the pinned GCC: plain char unsigned, long 32 bits, an
   enum int-sized with -fno-short-enums, as platform/c says (D921). */
_Static_assert((char)-1 > 0, "plain char is unsigned");
_Static_assert(sizeof(long) == 4 && sizeof(long long) == 8, "ILP32");
_Static_assert(_Alignof(long long) == 8 && _Alignof(double) == 8, "eight-byte doublewords");
_Static_assert(sizeof(void *) == 4, "ILP32 pointers");

enum peer_level { PEER_LOW = -1, PEER_HIGH = 0x7fffffff };
_Static_assert(sizeof(enum peer_level) == 4, "an int-sized enum");

/* Four bytes, returned in r0. */
struct peer_small {
    uint8_t tag;
    int16_t value;
};
_Static_assert(sizeof(struct peer_small) == 4, "small is one word");

/* Sixteen bytes aligned to eight: a word, padding, a doubleword. */
struct peer_medium {
    uint32_t first;
    uint64_t second;
};
_Static_assert(sizeof(struct peer_medium) == 16 && _Alignof(struct peer_medium) == 8,
               "medium is four words");

/* Thirty-two bytes, past r0-r3: by value it is split between the last
   argument registers and the stack, and returned through a result
   address. */
struct peer_large {
    uint32_t words[5];
    int8_t mark;
    int64_t tail;
};
_Static_assert(sizeof(struct peer_large) == 32 && __builtin_offsetof(struct peer_large, tail) == 24,
               "large is eight words, its tail at 24");

/* The C global the program reads and writes through its address. */
struct peer_log {
    uint32_t calls;
    int32_t last;
    uint64_t total;
};

typedef int64_t (*peer_step)(int32_t value, int64_t wide);

int peer_scalars(uint8_t a, int8_t b, uint16_t c, int16_t d, uint32_t e,
                 int32_t f, bool g, char h, long i, enum peer_level j);
int peer_pairs(uint32_t a, uint64_t b, uint32_t c, int64_t d, uint32_t e,
               uint64_t f);
int peer_floats(float a, double b, float c, double d);
uint64_t peer_wide(void);
int8_t peer_narrow(void);
char peer_char(void);
long peer_long(void);
double peer_double(float half);
struct peer_small peer_small_round(struct peer_small value);
int peer_medium_check(uint32_t before, struct peer_medium value);
int peer_large_check(uint32_t r0, struct peer_large value, uint32_t after);
struct peer_large peer_large_make(int32_t seed);
int peer_large_read(const struct peer_large *value);
void peer_large_fill(struct peer_large *into, int32_t seed);
int peer_apply(peer_step step);
int peer_exports(void);
struct peer_log *peer_log_address(void);
int peer_log_check(void);

/* The program's own, which the peer calls. */
int64_t landin_step(int32_t value, int64_t wide);
int landin_check_large(struct peer_large value);
struct peer_small landin_small(uint8_t tag, int16_t value);
uint64_t landin_wide(uint32_t low, uint64_t high);
extern uint32_t landin_seen;

#endif
