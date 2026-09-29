/* Host-only resource measurement for this process. It reads what the host
   already counts: processor time spent in this process, its peak resident
   set, and how many bytes the process's allocator is holding for it right
   now. Children are excluded, so a tool the driver runs is not charged to
   the compiler. Nothing here reaches target facts or program output. */
/* Strict POSIX hides ru_maxrss on Darwin, where it is a BSD field, and
   mallinfo2 on glibc, where it is a GNU one. */
#ifdef __APPLE__
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#else
#define _GNU_SOURCE
#endif
#include <sys/resource.h>
#ifdef __APPLE__
#include <malloc/malloc.h>
#else
#include <malloc.h>
#endif

int landin_resource_usage(long long *cpu_microseconds, long long *peak_kib);
long long landin_allocated_bytes(void);

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

/* The bytes of every allocation the process has not yet freed, as the
   allocator counts them. Unlike the resident set this goes down when
   storage is returned, and it does not depend on where the allocator placed
   anything or on what the kernel paged in, so two identical runs of one
   deterministic request leave it at the same number. glibc counts blocks
   it carved from its arenas in uordblks and blocks it mapped directly in
   hblkhd, which is where a large source or table goes. */
long long landin_allocated_bytes(void)
{
#ifdef __APPLE__
    malloc_statistics_t statistics;

    malloc_zone_statistics(NULL, &statistics);
    return (long long)statistics.size_in_use;
#else
    struct mallinfo2 info = mallinfo2();

    return (long long)info.uordblks + (long long)info.hblkhd;
#endif
}
