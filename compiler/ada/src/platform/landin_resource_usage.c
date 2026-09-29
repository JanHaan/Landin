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
#include <mach/mach.h>
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
   hblkhd, which is where a large source or table goes.

   Darwin's own count, malloc_zone_statistics' size_in_use, is not that
   number for this program. The GNAT link records an SDK version of 10.21,
   and under it the allocator keeps freed blocks of a hundred kilobytes and
   more cached and still counts them, by amounts that differ between two
   identical runs and can fall below zero; a C program linked for the
   current SDK does not. So on Darwin every zone is asked for the ranges it
   holds in use and their sizes are summed, which is exact however the
   binary was linked. A zone is locked while it is walked, so an allocation
   on another thread cannot change it mid-walk, and nothing called while
   it is locked allocates. */
#ifdef __APPLE__
static kern_return_t landin_read_self(task_t task, vm_address_t address,
                                      vm_size_t size, void **local)
{
    (void)task;
    (void)size;
    *local = (void *)address;
    return KERN_SUCCESS;
}

static void landin_sum_ranges(task_t task, void *context, unsigned type,
                              vm_range_t *ranges, unsigned count)
{
    long long *sum = context;
    unsigned index;

    (void)task;
    (void)type;
    for (index = 0; index < count; index++)
        *sum += (long long)ranges[index].size;
}
#endif

long long landin_allocated_bytes(void)
{
#ifdef __APPLE__
    vm_address_t *zones;
    unsigned count, index;
    long long sum = 0;

    if (malloc_get_all_zones(mach_task_self(), landin_read_self, &zones,
                             &count) != KERN_SUCCESS)
        return -1;
    for (index = 0; index < count; index++) {
        malloc_zone_t *zone = (malloc_zone_t *)zones[index];
        malloc_introspection_t *look = zone->introspect;

        if (look == NULL || look->enumerator == NULL)
            continue;
        if (look->force_lock != NULL)
            look->force_lock(zone);
        look->enumerator(mach_task_self(), &sum,
                         MALLOC_PTR_IN_USE_RANGE_TYPE, zones[index],
                         landin_read_self, landin_sum_ranges);
        if (look->force_unlock != NULL)
            look->force_unlock(zone);
    }
    return sum;
#else
    struct mallinfo2 info = mallinfo2();

    return (long long)info.uordblks + (long long)info.hblkhd;
#endif
}
