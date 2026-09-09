#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

/*
 * GNU ld redirects the compiler-emitted bridge's undefined libc references to
 * these functions.  Landin therefore still calls _landin_host_open_read,
 * _landin_host_read, and their siblings; only the libc endpoint is scripted.
 */

enum scenario {
    OPEN_READ_RETRY = 1,
    OPEN_WRITE_RETRY = 2,
    READ_PARTIAL_EOF = 3,
    WRITE_PARTIAL_RETRY = 4,
    CLOSE_TERMINAL = 5,
    READ_TERMINAL = 6,
    WRITE_ZERO_PROGRESS = 7,
    WRITE_FAILURE_CLEANUP = 8
};

_Static_assert(EINTR == 4, "fixture requires Linux errno values");
_Static_assert(EIO == 5, "fixture requires Linux errno values");

static int selected;
static int fault;
static unsigned int open_calls;
static unsigned int read_calls;
static unsigned int write_calls;
static unsigned int close_calls;
static const char *first_path;
static int first_flags;
static mode_t first_mode;
static unsigned char *first_read_data;
static size_t first_read_length;
static const unsigned char *first_write_data;
static size_t first_write_length;
static unsigned char accepted_bytes[6];
static size_t accepted_length;
static int32_t recorded_detail;

static void mark_fault(int code)
{
    if (fault == 0) {
        fault = code;
    }
}

static int path_is(const char *actual, const char *expected)
{
    return strcmp(actual, expected) == 0;
}

static int bytes_are(const unsigned char *actual,
                     const unsigned char *expected,
                     size_t length)
{
    return memcmp(actual, expected, length) == 0;
}

static void accept_bytes(const unsigned char *data, size_t length)
{
    if (accepted_length + length > sizeof accepted_bytes) {
        mark_fault(90);
        return;
    }
    memcpy(accepted_bytes + accepted_length, data, length);
    accepted_length += length;
}

void r440_errno_select(int32_t scenario_number)
{
    selected = (int)scenario_number;
    fault = 0;
    open_calls = 0;
    read_calls = 0;
    write_calls = 0;
    close_calls = 0;
    first_path = NULL;
    first_flags = 0;
    first_mode = (mode_t)0;
    first_read_data = NULL;
    first_read_length = 0;
    first_write_data = NULL;
    first_write_length = 0;
    memset(accepted_bytes, 0, sizeof accepted_bytes);
    accepted_length = 0;
    recorded_detail = 0;
}

void r440_errno_record(int32_t detail)
{
    recorded_detail = detail;
    /* Cleanup must not be able to change the already copied Landin value. */
    errno = ENOTTY;
}

int __wrap_open(const char *path, int flags, ...)
{
    mode_t mode = (mode_t)0;

    if ((flags & O_CREAT) != 0) {
        va_list arguments;

        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, unsigned int);
        va_end(arguments);
    }

    ++open_calls;
    if (selected == OPEN_READ_RETRY) {
        if (!path_is(path, "r440-read") || flags != O_RDONLY
            || mode != (mode_t)0) {
            mark_fault(11);
        }
        if (open_calls == 1) {
            first_path = path;
            first_flags = flags;
            first_mode = mode;
            errno = EINTR;
            return -1;
        }
        if (open_calls == 2) {
            if (path != first_path || flags != first_flags
                || mode != first_mode) {
                mark_fault(12);
            }
            return 101;
        }
    } else if (selected == OPEN_WRITE_RETRY) {
        if (!path_is(path, "r440-write")
            || flags != (O_WRONLY | O_CREAT | O_TRUNC)
            || mode != (mode_t)0666) {
            mark_fault(21);
        }
        if (open_calls == 1) {
            first_path = path;
            first_flags = flags;
            first_mode = mode;
            errno = EINTR;
            return -1;
        }
        if (open_calls == 2) {
            if (path != first_path || flags != first_flags
                || mode != first_mode) {
                mark_fault(22);
            }
            return 102;
        }
    }

    mark_fault(19);
    errno = EIO;
    return -1;
}

ssize_t __wrap_read(int descriptor, void *data, size_t length)
{
    unsigned char *bytes = data;

    ++read_calls;
    if (descriptor != STDOUT_FILENO) {
        mark_fault(31);
    }

    if (selected == READ_PARTIAL_EOF) {
        if (read_calls == 1) {
            first_read_data = bytes;
            first_read_length = length;
            if (length != 4) {
                mark_fault(32);
            }
            errno = EINTR;
            return -1;
        }
        if (read_calls == 2) {
            if (bytes != first_read_data || length != first_read_length) {
                mark_fault(33);
            }
            if (length >= 3) {
                bytes[0] = 65;
                bytes[1] = 66;
                bytes[2] = 67;
            } else {
                mark_fault(34);
            }
            return 3;
        }
        if (read_calls == 3) {
            if (length != 4) {
                mark_fault(35);
            }
            return 0;
        }
    } else if (selected == READ_TERMINAL) {
        if (read_calls == 1) {
            first_read_data = bytes;
            first_read_length = length;
            if (length != 2) {
                mark_fault(61);
            }
            errno = EINTR;
            return -1;
        }
        if (read_calls == 2) {
            if (bytes != first_read_data || length != first_read_length) {
                mark_fault(62);
            }
            errno = EIO;
            return -1;
        }
    }

    mark_fault(39);
    errno = EIO;
    return -1;
}

ssize_t __wrap_write(int descriptor, const void *data, size_t length)
{
    static const unsigned char expected[6] = {10, 20, 30, 40, 50, 60};
    const unsigned char *bytes = data;

    ++write_calls;
    if (descriptor != STDOUT_FILENO) {
        mark_fault(41);
    }

    if (selected == WRITE_PARTIAL_RETRY) {
        if (write_calls == 1) {
            first_write_data = bytes;
            first_write_length = length;
            if (length != sizeof expected
                || !bytes_are(bytes, expected, sizeof expected)) {
                mark_fault(42);
            }
            accept_bytes(bytes, 2);
            return 2;
        }
        if (write_calls == 2) {
            if (bytes != first_write_data + 2
                || length != first_write_length - 2
                || !bytes_are(bytes, expected + 2, length)) {
                mark_fault(43);
            }
            errno = EINTR;
            return -1;
        }
        if (write_calls == 3) {
            if (bytes != first_write_data + 2
                || length != first_write_length - 2
                || !bytes_are(bytes, expected + 2, length)) {
                mark_fault(44);
            }
            accept_bytes(bytes, 1);
            return 1;
        }
        if (write_calls == 4) {
            if (bytes != first_write_data + 3
                || length != first_write_length - 3
                || !bytes_are(bytes, expected + 3, length)) {
                mark_fault(45);
            }
            accept_bytes(bytes, length);
            return (ssize_t)length;
        }
    } else if (selected == WRITE_ZERO_PROGRESS) {
        if (write_calls == 1) {
            if (length != sizeof expected
                || !bytes_are(bytes, expected, sizeof expected)) {
                mark_fault(71);
            }
            /* A nonnegative zero is not a libc failure indication. */
            errno = EDOM;
            return 0;
        }
    } else if (selected == WRITE_FAILURE_CLEANUP) {
        if (write_calls == 1) {
            first_write_data = bytes;
            first_write_length = length;
            if (length != sizeof expected
                || !bytes_are(bytes, expected, sizeof expected)) {
                mark_fault(81);
            }
            errno = EINTR;
            return -1;
        }
        if (write_calls == 2) {
            if (bytes != first_write_data || length != first_write_length
                || !bytes_are(bytes, expected, sizeof expected)) {
                mark_fault(82);
            }
            errno = EIO;
            return -1;
        }
    }

    mark_fault(49);
    errno = EIO;
    return -1;
}

int __wrap_close(int descriptor)
{
    ++close_calls;

    if (selected == OPEN_READ_RETRY) {
        if (close_calls == 1 && descriptor == 101) {
            return 0;
        }
    } else if (selected == OPEN_WRITE_RETRY) {
        if (close_calls == 1 && descriptor == 102) {
            return 0;
        }
    } else if (selected == CLOSE_TERMINAL) {
        if (close_calls == 1 && descriptor == STDOUT_FILENO) {
            errno = EINTR;
            return -1;
        }
    } else if (selected == WRITE_FAILURE_CLEANUP) {
        if (close_calls == 1 && descriptor == STDOUT_FILENO) {
            /* Success leaves ambient errno dirty, but provider detail is zero. */
            errno = EBADF;
            return 0;
        }
    }

    mark_fault(59);
    errno = EBADF;
    return -1;
}

int32_t r440_errno_check(int32_t scenario_number)
{
    static const unsigned char expected[6] = {10, 20, 30, 40, 50, 60};

    if ((int)scenario_number != selected) {
        return 99;
    }
    if (fault != 0) {
        return (int32_t)fault;
    }

    switch (selected) {
    case OPEN_READ_RETRY:
    case OPEN_WRITE_RETRY:
        return open_calls == 2 && close_calls == 1 ? 0 : 91;
    case READ_PARTIAL_EOF:
        return read_calls == 3 ? 0 : 92;
    case WRITE_PARTIAL_RETRY:
        return write_calls == 4 && accepted_length == sizeof expected
                   && bytes_are(accepted_bytes, expected, sizeof expected)
               ? 0
               : 93;
    case CLOSE_TERMINAL:
        return close_calls == 1 ? 0 : 94;
    case READ_TERMINAL:
        return read_calls == 2 ? 0 : 95;
    case WRITE_ZERO_PROGRESS:
        return write_calls == 1 ? 0 : 96;
    case WRITE_FAILURE_CLEANUP:
        return write_calls == 2 && close_calls == 1
                   && recorded_detail == EIO
               ? 0
               : 97;
    default:
        return 98;
    }
}
