/*
 * A C main that drives Landin installs its own SIGPIPE handler before it
 * calls the argument initializer, which keeps it.  A write through the
 * hosted provider's writer concept to a connection whose peer has gone
 * must then fail with EPIPE without raising SIGPIPE: on Linux only a send
 * with MSG_NOSIGNAL keeps a socket quiet, and a write would run the
 * handler.
 */
#define _POSIX_C_SOURCE 200809L
#include <signal.h>
#include <stdint.h>
#include <string.h>

extern void _landin_host_initialize_arguments(int argc, char **argv,
                                              char **envp);
extern int32_t l_connection_write(void);

static char program[] = "socket-write-raises-no-sigpipe";
static char *arguments[] = { program, 0 };
static volatile sig_atomic_t raised;

static void count(int signal)
{
    (void)signal;
    raised++;
}

int main(void)
{
    struct sigaction handler;
    memset(&handler, 0, sizeof handler);
    handler.sa_handler = count;
    sigemptyset(&handler.sa_mask);
    if (sigaction(SIGPIPE, &handler, 0) != 0)
        return 1;
    _landin_host_initialize_arguments(1, arguments, 0);
    int32_t result = l_connection_write();
    if (raised != 0)
        return 2;
    if (result != 1)
        return 10 + result;
    return 42;
}
