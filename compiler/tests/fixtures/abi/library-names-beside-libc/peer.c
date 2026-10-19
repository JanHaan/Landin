#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

/* The peer's own global `reset`.  The library's `reset` is a local symbol,
   so the two definitions do not collide when the image is linked. */
int reset(int value) { return value + 100; }

/* C's read, errno and environ are the C library's: none of them is the
   library's routine or datum of the same name. */
int peer_check(void)
{
    int ends[2];
    char byte = 0;
    if (pipe(ends) != 0)
        return 1;
    if (write(ends[1], "L", 1) != 1)
        return 2;
    if (read(ends[0], &byte, 1) != 1 || byte != 'L')
        return 3;
    close(ends[0]);
    close(ends[1]);
    errno = 0;
    if (read(-1, &byte, 1) != -1 || errno != EBADF)
        return 4;
    if (setenv("LANDIN_SYMBOL_PROBE", "beside", 1) != 0)
        return 5;
    const char *value = getenv("LANDIN_SYMBOL_PROBE");
    if (value == NULL || strcmp(value, "beside") != 0)
        return 6;
    for (char **entry = environ; entry != NULL && *entry != NULL; ++entry)
        if (strcmp(*entry, "LANDIN_SYMBOL_PROBE=beside") == 0)
            return 0;
    return 7;
}
