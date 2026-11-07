/* The four routines GCC requires of a freestanding environment (D985).
 *
 * GCC's manual says a freestanding program must still provide memcpy,
 * memmove, memset and memcmp, which it calls for a structure copy, clear
 * or comparison whatever -ffreestanding says, and the pinned arm-eabi-gcc
 * does for a record of a C peer returned or assigned by value.  An ABI
 * fixture's C has no C library to take them from, so the corpus links
 * these with every one, each in its own section, which the link keeps
 * only if something calls it.  They are byte loops, compiled with
 * -fno-tree-loop-distribute-patterns so that GCC does not turn a loop
 * back into a call of itself.  Refine's own code calls none of them. */
#include <stddef.h>

void *memcpy(void *restrict into, const void *restrict from, size_t count)
{
    unsigned char *to = into;
    const unsigned char *source = from;
    while (count--)
        *to++ = *source++;
    return into;
}

void *memmove(void *into, const void *from, size_t count)
{
    unsigned char *to = into;
    const unsigned char *source = from;
    if (to < source) {
        while (count--)
            *to++ = *source++;
    } else {
        while (count--)
            to[count] = source[count];
    }
    return into;
}

void *memset(void *into, int value, size_t count)
{
    unsigned char *to = into;
    while (count--)
        *to++ = (unsigned char)value;
    return into;
}

int memcmp(const void *left, const void *right, size_t count)
{
    const unsigned char *a = left, *b = right;
    for (; count; count--, a++, b++)
        if (*a != *b)
            return *a < *b ? -1 : 1;
    return 0;
}
