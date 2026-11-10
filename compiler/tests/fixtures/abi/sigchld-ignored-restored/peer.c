/*
 * A process started by one that ignores SIGCHLD inherits the ignore across
 * the exec, and the system then reaps each of its children as it ends, so
 * that waiting for one fails with ECHILD.  This C main puts the process in
 * that state before it calls the argument initializer, which gives SIGCHLD
 * its default back (D1125): Landin's spawn and wait then report how a shell
 * ended.
 */
#define _POSIX_C_SOURCE 200809L
#include <signal.h>
#include <stdint.h>
#include <string.h>

extern void _landin_host_initialize_arguments(int argc, char **argv,
                                              char **envp);
extern int32_t l_shell_code(void);

static char program[] = "sigchld-ignored-restored";
static char *arguments[] = { program, 0 };

int main(void)
{
    struct sigaction ignoring;
    memset(&ignoring, 0, sizeof ignoring);
    ignoring.sa_handler = SIG_IGN;
    sigemptyset(&ignoring.sa_mask);
    if (sigaction(SIGCHLD, &ignoring, 0) != 0)
        return 1;
    _landin_host_initialize_arguments(1, arguments, 0);
    struct sigaction now;
    if (sigaction(SIGCHLD, 0, &now) != 0 || now.sa_handler != SIG_DFL)
        return 2;
    /* The shell exits with 7, and the wait says so. */
    if (l_shell_code() != 7)
        return 3;
    return 42;
}
