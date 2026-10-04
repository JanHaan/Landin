/* Standard input, output and error as a byte channel for the language
   server. Reads and writes are the descriptors' own, with no buffering of
   ours, so a message is on the wire when the server says it is; a read is
   retried when a signal interrupts it, and a write until every byte has
   gone. Nothing here reads a file or reaches a target fact. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <poll.h>
#include <unistd.h>

long landin_channel_read(char *into, long length);
int landin_channel_pending(void);
int landin_channel_write(int descriptor, const char *item, long length);

/* The bytes read, 0 at the end of input, or -1 when the host refuses. */
long landin_channel_read(char *into, long length)
{
    for (;;) {
        ssize_t got = read(0, into, (size_t)length);
        if (got >= 0)
            return (long)got;
        if (errno != EINTR)
            return -1;
    }
}

/* 1 when a read would not wait, 0 when it would, -1 when the host refuses.
   The end of input and a hang-up count as readable: the read says so. */
int landin_channel_pending(void)
{
    struct pollfd watched;

    watched.fd = 0;
    watched.events = POLLIN;
    watched.revents = 0;
    for (;;) {
        int ready = poll(&watched, 1, 0);
        if (ready >= 0) {
            if (ready > 0 && (watched.revents & POLLNVAL))
                return -1;
            return ready > 0 ? 1 : 0;
        }
        if (errno != EINTR)
            return -1;
    }
}

/* 0 when every byte was written, -1 when the host refused one. */
int landin_channel_write(int descriptor, const char *item, long length)
{
    long done = 0;

    while (done < length) {
        ssize_t wrote = write(descriptor, item + done, (size_t)(length - done));
        if (wrote < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        done += (long)wrote;
    }
    return 0;
}
