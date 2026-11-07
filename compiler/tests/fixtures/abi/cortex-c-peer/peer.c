/* The C peer of the program, freestanding: no C library, and only the
   freestanding headers.  See peer.h for what each routine checks. */
#include "peer.h"

static struct peer_large large_value(int32_t seed)
{
    struct peer_large made;
    for (int i = 0; i < 5; i++)
        made.words[i] = (uint32_t)(seed + i * 0x01010101);
    made.mark = -7;
    made.tail = -(int64_t)seed * 0x100000001LL;
    return made;
}

static int large_differs(const struct peer_large *value, int32_t seed)
{
    struct peer_large wanted = large_value(seed);
    for (int i = 0; i < 5; i++)
        if (value->words[i] != wanted.words[i])
            return 1 + i;
    if (value->mark != wanted.mark)
        return 6;
    if (value->tail != wanted.tail)
        return 7;
    return 0;
}

/* Every narrow width extended to its type, signed ones negative. */
int peer_scalars(uint8_t a, int8_t b, uint16_t c, int16_t d, uint32_t e,
                 int32_t f, bool g, char h, long i, enum peer_level j)
{
    if (a != 0xfe) return 1;
    if (b != -5) return 2;
    if (c != 0xfedc) return 3;
    if (d != -1234) return 4;
    if (e != 0xdeadbeefu) return 5;
    if (f != -123456789) return 6;
    if (g != true) return 7;
    /* 200 as a plain char: unsigned, so neither negative nor -56. */
    if (h != (char)200 || (int)h != 200) return 8;
    if (i != -2L) return 9;
    if (j != PEER_LOW) return 10;
    return 0;
}

/* a in r0, b in r2:r3 with r1 skipped, c on the stack at 0, d at 8 with
   4 skipped, e at 16 and f at 24, again aligned to eight. */
int peer_pairs(uint32_t a, uint64_t b, uint32_t c, int64_t d, uint32_t e,
               uint64_t f)
{
    if (a != 1) return 11;
    if (b != 0x0123456789abcdefULL) return 12;
    if (c != 3) return 13;
    if (d != -0x0102030405060708LL) return 14;
    if (e != 5) return 15;
    if (f != 0xfedcba9876543210ULL) return 16;
    return 0;
}

/* The base standard passes floats in core registers: a in r0, b in
   r2:r3, c and d on the stack. */
int peer_floats(float a, double b, float c, double d)
{
    if (a != 0.5f) return 21;
    if (b != -1.0e300) return 22;
    if (c != 3.25f) return 23;
    if (d != 1.0 / 3.0) return 24;
    return 0;
}

uint64_t peer_wide(void) { return 0x8000000100000002ULL; }
int8_t peer_narrow(void) { return -128; }
char peer_char(void) { return (char)0xf0; }
long peer_long(void) { return -0x7fffffffL - 1; }
double peer_double(float half) { return (double)half * 2.0; }

struct peer_small peer_small_round(struct peer_small value)
{
    struct peer_small back = { (uint8_t)(value.tag + 1), (int16_t)(value.value * 2) };
    return back;
}

struct peer_tiny peer_tiny_make(uint8_t base)
{
    struct peer_tiny made = { base, (uint8_t)(base + 1), (uint8_t)(base + 2) };
    return made;
}

int peer_tiny_check(struct peer_tiny value, uint8_t base)
{
    if (value.a != base || value.b != base + 1 || value.c != base + 2) return 35;
    return 0;
}

/* before in r0, the record in r2-r3 and the stack's first two words. */
int peer_medium_check(uint32_t before, struct peer_medium value)
{
    if (before != 0x11) return 31;
    if (value.first != 0x22222222u) return 32;
    if (value.second != 0x3333333344444444ULL) return 33;
    return 0;
}

/* r0, then the record in r2, r3 and the stack (8-aligned, so r1 is
   skipped), then after on the stack past it. */
int peer_large_check(uint32_t r0, struct peer_large value, uint32_t after)
{
    if (r0 != 0x55) return 41;
    int differs = large_differs(&value, 1000);
    if (differs) return 41 + differs;
    if (after != 0x66) return 49;
    return 0;
}

struct peer_large peer_large_make(int32_t seed) { return large_value(seed); }

int peer_large_read(const struct peer_large *value)
{
    int differs = large_differs(value, 3000);
    return differs ? 50 + differs : 0;
}

void peer_large_fill(struct peer_large *into, int32_t seed) { *into = large_value(seed); }

/* A C function pointer to a Landin routine, called with a value in r0 and
   a doubleword in r2:r3, and the program's exports called by name. */
int peer_apply(peer_step step)
{
    if (step != landin_step) return 61;
    if (step(-3, 0x100000000LL) != 0x100000000LL * 2 - 3) return 62;
    if (step(7, -1) != 5) return 63;
    return 0;
}

int peer_exports(void)
{
    if (landin_check_large(large_value(2000)) != 0) return 71;
    struct peer_small small = landin_small(0x81, -300);
    if (small.tag != 0x82 || small.value != -301) return 72;
    if (landin_wide(0xffffffffu, 0x100000000ULL) != 0x1ffffffffULL) return 73;
    if (landin_seen != 4) return 74;
    landin_seen = 0x77;
    return 0;
}

/* In .bss, and beside it one in .data, so the image's start-up is seen to
   clear the one and copy the other. */
struct peer_log peer_log_object;
uint32_t peer_started = 0x5eed;

struct peer_log *peer_log_address(void) { return &peer_log_object; }

int peer_log_check(void)
{
    /* The program counted from a cleared object. */
    if (peer_log_object.calls != 3) return 81;
    if (peer_log_object.last != -9) return 82;
    if (peer_log_object.total != 0x100000003ULL) return 83;
    if (peer_started != 0x5eed) return 84;
    return 0;
}
