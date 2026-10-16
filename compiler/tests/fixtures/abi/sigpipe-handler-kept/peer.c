/*
 * A C main that drives Landin installs its own SIGPIPE handler before it
 * calls the argument initializer, which ignores SIGPIPE only when it finds
 * the default: the handler is kept.  A Landin write to a pipe nobody reads
 * then runs the handler and fails with EPIPE; a send on a socket of
 * platform/posix's raises nothing, since its sockets ask for no SIGPIPE.
 */
#define _POSIX_C_SOURCE 200809L
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

extern void _landin_host_initialize_arguments(int argc, char **argv,
                                              char **envp);
extern bool l_ignored(void);
extern int32_t l_pipe_write(void);
extern int32_t l_socket_send(void);

static char program[] = "sigpipe-handler-kept";
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
    struct sigaction now;
    if (sigaction(SIGPIPE, 0, &now) != 0 || now.sa_handler != count)
        return 2;
    if (l_ignored())
        return 3;
    /* Landin reports EPIPE from the write, and the handler ran once. */
    if (l_pipe_write() != 1 || raised != 1)
        return 4;
    /* A socket of platform/posix's raises no SIGPIPE at all. */
    if (l_socket_send() != 1 || raised != 1)
        return 5;
    return 42;
}
