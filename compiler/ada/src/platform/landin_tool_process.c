/* Host-only POSIX process operations. Create the group before exec so a
   tool cannot spawn descendants before its timeout ownership is established.
   Ada owns deadlines, capture files, diagnostics and argument storage. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

int landin_tool_start(char *const args[], int capture, int errors, int *child);
int landin_tool_wait(int child, int *status, int no_hang);
int landin_tool_stop(int child, int *status);

int landin_tool_start(char *const args[], int capture, int errors, int *child)
{
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    pid_t pid;
    int error;
    int error_copy = -1;

    *child = 0;
    error = posix_spawnattr_init(&attributes);
    if (error != 0)
        return error;
    error = posix_spawn_file_actions_init(&actions);
    if (error != 0) {
        posix_spawnattr_destroy(&attributes);
        return error;
    }
    error = posix_spawnattr_setpgroup(&attributes, 0);
    if (error == 0)
        error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
    /* A parent with closed standard descriptors may allocate the error
       capture as fd 1. Preserve it before the stdout action replaces fd 1. */
    if (error == 0 && errors == STDOUT_FILENO && capture != STDOUT_FILENO) {
        error_copy = fcntl(errors, F_DUPFD_CLOEXEC, 3);
        if (error_copy < 0)
            error = errno;
        else
            errors = error_copy;
    }
    if (error == 0)
        error = posix_spawn_file_actions_adddup2(&actions, capture, STDOUT_FILENO);
    /* A negative error descriptor requests the original merged stream. */
    if (error == 0)
        error = posix_spawn_file_actions_adddup2(&actions,
                                                errors < 0 ? STDOUT_FILENO
                                                           : errors,
                                                STDERR_FILENO);
    if (error == 0 && capture != STDOUT_FILENO && capture != STDERR_FILENO)
        error = posix_spawn_file_actions_addclose(&actions, capture);
    if (error == 0 && errors >= 0 && errors != capture
        && errors != STDOUT_FILENO && errors != STDERR_FILENO)
        error = posix_spawn_file_actions_addclose(&actions, errors);
    if (error == 0)
        error = posix_spawn(&pid, args[0], &actions, &attributes, args, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    if (error_copy >= 0)
        close(error_copy);
    if (error == 0)
        *child = (int)pid;
    return error;
}

int landin_tool_wait(int child, int *status, int no_hang)
{
    int word;
    pid_t reaped;

    if (child <= 0) {
        errno = EINVAL;
        return -1;
    }
    do {
        reaped = waitpid((pid_t)child, &word, no_hang ? WNOHANG : 0);
    } while (reaped < 0 && errno == EINTR);
    if (reaped > 0)
        *status = WIFEXITED(word) ? WEXITSTATUS(word) : -1;
    return (int)reaped;
}

int landin_tool_stop(int child, int *status)
{
    if (child <= 0) {
        errno = EINVAL;
        return -1;
    }
    /* The unreaped direct child reserves this group ID. Never signal a
       caller group, and never retry against a PID already reaped by Ada. */
    if (kill(-(pid_t)child, SIGKILL) != 0 && errno != ESRCH)
        return -1;
    /* Still stop the direct child if it has changed its own group. It has
       not been reaped, so this PID cannot yet designate another process. */
    if (kill((pid_t)child, SIGKILL) != 0 && errno != ESRCH)
        return -1;
    return landin_tool_wait(child, status, 0);
}
