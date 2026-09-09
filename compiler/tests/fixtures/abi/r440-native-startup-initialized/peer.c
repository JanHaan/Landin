#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern void _landin_host_initialize_arguments(int argc, char **argv);
extern bool l_plain(int32_t input, int32_t output);
extern bool l_root(void);
typedef bool (*callback)(const void *state, int32_t depth);

static int original_argc;
static char **original_argv;
static unsigned visits;

static bool plain_io(void)
{
    int input[2];
    int output[2];
    char copied[4] = {0};
    if (pipe(input) != 0)
        return false;
    if (pipe(output) != 0) {
        close(input[0]);
        close(input[1]);
        return false;
    }
    bool ok = write(input[1], "pipe", 4) == 4;
    close(input[1]);
    ok = ok && l_plain(input[0], output[1]);
    close(input[0]);
    close(output[1]);
    ok = ok && read(output[0], copied, sizeof copied) == 4;
    close(output[0]);
    return ok && memcmp(copied, "pipe", 4) == 0;
}

bool c_argument_storage(size_t count, char *const *table, const char *first)
{
    return count == (size_t)(original_argc - 1)
        && table == original_argv + 1 && first == original_argv[1];
}

bool c_reenter(const void *state, callback visit, int32_t depth)
{
    ++visits;
    /* An identical startup request is idempotent, including while a world is
       live on a Landin frame. Neither this nor callback entry resets it. */
    _landin_host_initialize_arguments(original_argc, original_argv);
    return plain_io() && visit(state, depth);
}

int main(int argc, char **argv)
{
    if (argc != 3 || strcmp(argv[1], "alpha") || strcmp(argv[2], "42"))
        return 1;
    /* Genuine read/write plus core/io copying before any argv initialization.
       Merely retaining core/io's unused argument routines must still link. */
    if (!plain_io())
        return 2;
    original_argc = argc;
    original_argv = argv;
    _landin_host_initialize_arguments(argc, argv);
    _landin_host_initialize_arguments(argc, argv);
    if (!l_root() || visits != 4 || !plain_io())
        return 3;
    puts("native startup ok");
    return 42;
}
