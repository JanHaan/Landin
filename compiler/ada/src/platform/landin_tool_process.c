/* Host-only POSIX process operations. Create the group before exec so a
   tool cannot spawn descendants before its timeout ownership is established.
   Capture files are created here, in the host's temporary directory; Ada
   owns deadlines, their removal, diagnostics and argument storage. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

int landin_tool_capture(char *path, size_t capacity);
int landin_tool_start(char *const args[], int input, int capture, int errors,
                      int *child);
int landin_tool_wait(int child, int *status, int no_hang);
int landin_tool_stop(int child, int *status);

/* Create one capture file under $TMPDIR, or /tmp when that is unset or
   empty, and return its open descriptor with its name in path. GNAT's own
   temporary files are relative to the current directory, which put every
   capture beside the caller's sources and failed in a read-only one. */
int landin_tool_capture(char *path, size_t capacity)
{
    const char *directory = getenv("TMPDIR");
    int written;

    if (directory == NULL || directory[0] == '\0')
        directory = "/tmp";
    written = snprintf(path, capacity, "%s/landin-tool-XXXXXX", directory);
    if (written < 0 || (size_t)written >= capacity) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return mkstemp(path);
}

/* Move SOURCE above the standard descriptors when it is one of them, once
   for each number, recording the copy in MOVED: the descriptor every
   action reads, or -1 with errno set.  A negative SOURCE is returned as it
   is. */
static int landin_tool_source(int source, int moved[3])
{
    if (source < 0 || source > STDERR_FILENO)
        return source;
    if (moved[source] < 0)
        moved[source] = fcntl(source, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
    return moved[source];
}

/* A negative input inherits the caller's standard input; otherwise the
   descriptor becomes the child's.  A negative errors merges the error
   stream into the capture.

   A caller whose standard descriptors are closed has its capture files, and
   its input, opened at those numbers, where an action replacing one of them
   would destroy a source a later action still reads: the input made the
   child's stdout, or the capture closed as its stdin.  So every source
   among 0 to 2 is first moved above them, and each action reads a
   descriptor no action writes; the moved copies are closed after the call.
   A caller with no standard input of its own whose capture took that
   number gives the child none rather than the capture. */
int landin_tool_start(char *const args[], int input, int capture, int errors,
                      int *child)
{
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    pid_t pid;
    int error;
    int moved[3] = {-1, -1, -1};
    const int no_input = input < 0
        && (capture == STDIN_FILENO || errors == STDIN_FILENO);
    const int given_input = input;
    const int given_capture = capture;
    const int given_errors = errors;
    int index;

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
    if (error == 0) {
        input = landin_tool_source(given_input, moved);
        capture = landin_tool_source(given_capture, moved);
        errors = landin_tool_source(given_errors, moved);
        if ((given_input >= 0 && input < 0) || capture < 0
            || (given_errors >= 0 && errors < 0))
            error = errno != 0 ? errno : EBADF;
    }
    /* Every source is above 2 now, so no duplication below reads a
       descriptor an earlier one wrote. */
    if (error == 0 && input >= 0)
        error = posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO);
    if (error == 0)
        error = posix_spawn_file_actions_adddup2(&actions, capture, STDOUT_FILENO);
    /* A negative error descriptor requests the original merged stream. */
    if (error == 0)
        error = posix_spawn_file_actions_adddup2(&actions,
                                                errors < 0 ? STDOUT_FILENO
                                                           : errors,
                                                STDERR_FILENO);
    if (error == 0 && no_input)
        error = posix_spawn_file_actions_addclose(&actions, STDIN_FILENO);
    /* Each source once: the moved copies are closed on exec already, but
       the caller's own are not. */
    if (error == 0 && input >= 0)
        error = posix_spawn_file_actions_addclose(&actions, input);
    if (error == 0 && capture != input)
        error = posix_spawn_file_actions_addclose(&actions, capture);
    if (error == 0 && errors >= 0 && errors != capture && errors != input)
        error = posix_spawn_file_actions_addclose(&actions, errors);
    if (error == 0)
        error = posix_spawn(&pid, args[0], &actions, &attributes, args, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    for (index = 0; index <= STDERR_FILENO; index++)
        if (moved[index] >= 0)
            close(moved[index]);
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
