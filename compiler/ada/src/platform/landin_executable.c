/* Host-only lookup of the running executable's own path, every link
   resolved, which is how the compiler finds the library installed beside
   it. Each host answers in its own way; a host with none answers nothing,
   and the compiler then has no library unless it is told where one is.
   Nothing here reaches target facts or program output. */
#ifdef __linux__
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#endif
#ifdef __APPLE__
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#endif
#include <limits.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#if defined(__linux__)
#include <unistd.h>
#elif defined(__APPLE__)
#include <mach-o/dyld.h>
#include <stdint.h>
#elif defined(__FreeBSD__)
#include <sys/types.h>
#include <sys/sysctl.h>
#endif

int landin_executable_path(char *into, size_t length);

/* Return 0 with the absolute path in INTO, terminated, or -1 when the host
   cannot say or the path does not fit: a truncated path names something
   else, so it is never returned. */
int landin_executable_path(char *into, size_t length)
{
    if (into == NULL || length == 0)
        return -1;
    into[0] = '\0';
#if defined(__linux__)
    {
        ssize_t written = readlink("/proc/self/exe", into, length);

        if (written <= 0 || (size_t)written >= length)
            return -1;
        into[written] = '\0';
        return 0;
    }
#elif defined(__APPLE__)
    {
        char named[PATH_MAX];
        char resolved[PATH_MAX];
        uint32_t size = sizeof named;

        /* The loader's name may be relative or pass through a link. */
        if (_NSGetExecutablePath(named, &size) != 0
            || realpath(named, resolved) == NULL
            || strlen(resolved) >= length)
            return -1;
        memcpy(into, resolved, strlen(resolved) + 1);
        return 0;
    }
#elif defined(__FreeBSD__)
    {
        int name[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1};
        size_t size = length;

        if (sysctl(name, 4, into, &size, NULL, 0) != 0 || size == 0
            || size > length || into[size - 1] != '\0')
            return -1;
        return 0;
    }
#else
    return -1;
#endif
}
