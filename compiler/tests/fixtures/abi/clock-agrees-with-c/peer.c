/*
 * Holds the clock facts platform/libc and platform/linux keep to this
 * system's own C headers, and reads the C library's clocks around
 * platform/posix's: the monotonic reading falls between two of C's, and
 * the realtime readings agree within a second.
 */
#define _GNU_SOURCE
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

extern int32_t l_clock_realtime(void);
extern int32_t l_clock_monotonic(void);
extern size_t l_timespec_size(void);
#if defined(__linux__)
extern bool l_linux_agrees(void);
#endif
extern int64_t l_monotonic(void);
extern int64_t l_realtime(void);

static int64_t c_clock(clockid_t clock)
{
    struct timespec now;
    if (clock_gettime(clock, &now) != 0)
        return -1;
    return (int64_t)now.tv_sec * 1000000000 + now.tv_nsec;
}

int main(void)
{
    if (l_clock_realtime() != CLOCK_REALTIME
        || l_clock_monotonic() != CLOCK_MONOTONIC)
        return 1;
    if (l_timespec_size() != sizeof(struct timespec)
        || sizeof(clockid_t) != sizeof(int32_t)
        || offsetof(struct timespec, tv_nsec) != 8)
        return 2;
#if defined(__linux__)
    if (!l_linux_agrees())
        return 3;
#endif
    for (int round = 0; round < 1000; round++) {
        int64_t before = c_clock(CLOCK_MONOTONIC);
        int64_t between = l_monotonic();
        int64_t after = c_clock(CLOCK_MONOTONIC);
        if (before < 0 || between < before || after < between)
            return 4;
    }
    int64_t ours = l_realtime();
    int64_t theirs = c_clock(CLOCK_REALTIME);
    if (ours < 0 || theirs < ours || theirs - ours > 1000000000)
        return 5;
    return 42;
}
