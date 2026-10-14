/*
 * A C main starts the process with an argument that is not UTF-8, the
 * Latin-1 bytes of "host-string-\xe9.txt", and hands it to Landin through
 * the argument root.  Landin passes it on as a path; this side then looks
 * for a file named with exactly those bytes, which Linux and FreeBSD make,
 * and Darwin, whose file systems take only UTF-8 names, refuses.
 */
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

extern void _landin_host_initialize_arguments(int argc, char **argv);
extern int32_t l_pass_through(void);

static char program[] = "host-string-pass-through";
static char name[] = "host-string-\xe9.txt";
static char *arguments[] = { program, name, 0 };

/* Whether Landin was lent argv[1] itself, not a copy of it. */
bool c_argument_is_argv(const unsigned char *bytes, size_t length)
{
    return (const char *)bytes == name && length == strlen(name);
}

int main(void)
{
    unlink(name);
    _landin_host_initialize_arguments(2, arguments);
    int32_t code = l_pass_through();
    if (code != 42)
        return code;
#ifdef __APPLE__
    /* The system refused the name, so there is nothing to find. */
    return access(name, F_OK) == 0 ? 3 : 42;
#else
    char contents[16] = {0};
    int file = open(name, O_RDONLY);
    if (file < 0)
        return 4;
    ssize_t got = read(file, contents, sizeof contents);
    close(file);
    unlink(name);
    return got == 7 && memcmp(contents, "passed\n", 7) == 0 ? 42 : 5;
#endif
}
