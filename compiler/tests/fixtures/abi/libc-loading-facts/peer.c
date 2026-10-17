/*
 * Holds the dlopen modes platform/libc keeps to this system's own
 * <dlfcn.h>: Darwin's RTLD_LOCAL and RTLD_GLOBAL are not Linux's and
 * FreeBSD's, and Darwin's default is global, which is why platform/posix
 * always names one.
 */
#include <dlfcn.h>
#include <stdint.h>

static const int64_t modes[] = { RTLD_NOW, RTLD_LOCAL, RTLD_GLOBAL };

int64_t loading_fact(int64_t index) {
    return index >= 0 && index < (int64_t)(sizeof modes / sizeof modes[0])
        ? modes[index] : -1;
}
