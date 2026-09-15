/* Fixture-only endpoints for Linux paths absent from Darwin. Ordinary paths
 * still reach libSystem; only the two named fault endpoints are scripted.
 * The shared Landin source, helper bridge, errno capture and output oracle
 * are unchanged. Native interposition cases separately cover all I/O edges. */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stddef.h>
#include <string.h>
#include <unistd.h>

static int full_descriptor = -1;

int r550_open(const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
    }
    if (!strcmp(path, "/sys/landin-r420-denied")) {
        errno = EACCES;
        return -1;
    }
    int (*native_open)(const char *, int, ...) = dlsym(RTLD_NEXT, "open");
    if (!native_open) { errno = EIO; return -1; }
    if (!strcmp(path, "/dev/full")) {
        full_descriptor = native_open("/dev/null", flags, mode);
        return full_descriptor;
    }
    return native_open(path, flags, mode);
}

ssize_t r550_write(int descriptor, const void *data, size_t length)
{
    if (descriptor == full_descriptor) {
        errno = ENOSPC;
        return -1;
    }
    ssize_t (*native_write)(int, const void *, size_t) = dlsym(RTLD_NEXT, "write");
    if (!native_write) { errno = EIO; return -1; }
    return native_write(descriptor, data, length);
}

int r550_close(int descriptor)
{
    if (descriptor == full_descriptor) full_descriptor = -1;
    int (*native_close)(int) = dlsym(RTLD_NEXT, "close");
    if (!native_close) { errno = EIO; return -1; }
    return native_close(descriptor);
}
