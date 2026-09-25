/* Host-only resource measurement for this process. It reads what the host
   already counts: processor time spent in this process and its peak resident
   set. Children are excluded, so a tool the driver runs is not charged to
   the compiler. Nothing here reaches target facts or program output. */
#define _POSIX_C_SOURCE 200809L
#include <sys/resource.h>

int landin_resource_usage(long long *cpu_microseconds, long long *peak_kib);

/* Return 0 and both measurements, or -1 when the host refuses. Linux counts
   ru_maxrss in KiB and Darwin in bytes; the answer is KiB on both. */
int landin_resource_usage(long long *cpu_microseconds, long long *peak_kib)
{
    struct rusage usage;

    if (getrusage(RUSAGE_SELF, &usage) != 0)
        return -1;
    *cpu_microseconds =
        ((long long)usage.ru_utime.tv_sec + (long long)usage.ru_stime.tv_sec)
            * 1000000LL
        + (long long)usage.ru_utime.tv_usec + (long long)usage.ru_stime.tv_usec;
#ifdef __APPLE__
    *peak_kib = (long long)usage.ru_maxrss / 1024LL;
#else
    *peak_kib = (long long)usage.ru_maxrss;
#endif
    return 0;
}
