/* Host-only POSIX process operations. Create the group before exec so a
   tool cannot spawn descendants before its timeout ownership is established.
   Capture files are created here, in the host's temporary directory; Ada
   owns deadlines, their removal, diagnostics and argument storage. */
#ifdef __linux__
#define _GNU_SOURCE
#endif
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#ifndef __FreeBSD__
#define _POSIX_C_SOURCE 200809L
#endif
#include <errno.h>
#include <pthread.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "landin_owned_directory.h"

extern char **environ;

int landin_tool_capture(char *path, size_t capacity);
int landin_tool_start(char *const args[], char *const env[], int isolated,
                      int input, int capture, int errors, int *child);
int landin_tool_start_in_directory(char *const args[], char *const env[],
                                    int isolated, int input, int capture,
                                    int errors, int directory, int *child);
int landin_tool_wait(int child, int *status, int no_hang);
int landin_tool_wait_reserved(int child, int *status, int no_hang, int *owned);
int landin_tool_stop(int child, int *status);
int landin_tool_cancel(int child, int *status);
int landin_tool_cancel_reserved(int child, int *status, int *owned);
int landin_cancellation_begin(void);
void landin_cancellation_end(void);
int landin_cancellation_requested(void);
int landin_program_run(char *const args[], int *signal_number,
                       int *status, int *child);
const char *landin_signal_name(int signal_number);

/* A direct child reserves its PID/PGID only while its exit status remains
   waitable. Keep inherited SIGCHLD policy unchanged: reject automatic reaping
   before spawning, including callers that bypass the Ada adapter. Process-wide
   signal policy must stay quiescent while children are live, and no competing
   waiter or SIGCHLD handler may reap children owned by these APIs. */
enum { LANDIN_CHILD_IGNORED = -1, LANDIN_CHILD_NO_WAIT = -2 };
static int landin_child_wait_policy(void)
{
    struct sigaction action;
    if (sigaction(SIGCHLD, NULL, &action) != 0) return errno;
    if (action.sa_handler == SIG_IGN) return LANDIN_CHILD_IGNORED;
    if (action.sa_flags & SA_NOCLDWAIT) return LANDIN_CHILD_NO_WAIT;
    return 0;
}
const char *landin_process_start_error(int error)
{
    if (error == LANDIN_CHILD_IGNORED)
        return "SIGCHLD is ignored; start refine with SIGCHLD set to its default"
               " disposition so child exit status remains waitable";
    if (error == LANDIN_CHILD_NO_WAIT)
        return "SIGCHLD has SA_NOCLDWAIT set; clear SA_NOCLDWAIT before starting"
               " refine so child exit status remains waitable";
    return NULL;
}

/* Invocation cancellation is notification only. No filesystem work, Ada
   cleanup, or potentially reused process-group identifier reaches a handler.
   The supervising thread forwards the signal while it still owns an
   unreaped child. Inherited ignored signals stay ignored. */
static volatile sig_atomic_t landin_cancel_signal = 0;
static int landin_cancel_active = 0;
static const int landin_cancel_numbers[] = {SIGINT, SIGTERM, SIGHUP};
static struct sigaction landin_cancel_saved[3];

static void landin_cancel_notify(int number)
{
    int saved = errno;
    if (landin_cancel_signal == 0)
        landin_cancel_signal = number;
    errno = saved;
}

int landin_cancellation_begin(void)
{
    struct sigaction action;
    size_t index;
    if (landin_cancel_active)
        return 0;
    memset(&action, 0, sizeof action);
    action.sa_handler = landin_cancel_notify;
    sigemptyset(&action.sa_mask);
    for (index = 0; index < 3; ++index)
        sigaddset(&action.sa_mask, landin_cancel_numbers[index]);
    landin_cancel_signal = 0;
    for (index = 0; index < 3; ++index) {
        int number = landin_cancel_numbers[index];
        if (sigaction(number, NULL, &landin_cancel_saved[index]) != 0)
            goto failed;
        if (landin_cancel_saved[index].sa_handler != SIG_IGN
            && sigaction(number, &action, NULL) != 0)
            goto failed;
    }
    landin_cancel_active = 1;
    return 0;
failed:
    {
        int error = errno;
        while (index != 0) {
            --index;
            sigaction(landin_cancel_numbers[index],
                       &landin_cancel_saved[index], NULL);
        }
        return error;
    }
}

void landin_cancellation_end(void)
{
    size_t index;
    if (!landin_cancel_active)
        return;
    for (index = 0; index < 3; ++index)
        sigaction(landin_cancel_numbers[index], &landin_cancel_saved[index],
                   NULL);
    landin_cancel_active = 0;
    landin_cancel_signal = 0;
}

int landin_cancellation_requested(void)
{
    return (int)landin_cancel_signal;
}

/* Captures are unlinked within a freshly created private directory and
   stay open through reading. A changed TMPDIR ancestor cannot substitute
   bytes or make cleanup unlink an unrelated public filename. */
/* Registry operations are serialized, including descriptor borrowing and
   teardown. Handles may be handed to another thread after caller synchronization.
   Lock order is Publication -> Private; Format and Capture never take Private.
   Test hooks are installed only while quiescent and must not reenter this
   registry. Spawned/execed peer controls have independent process state. */
static pthread_mutex_t registry_mutex = PTHREAD_MUTEX_INITIALIZER;
static void registry_lock(void)
{
    int saved = errno;
    if (pthread_mutex_lock(&registry_mutex) != 0) abort();
    errno = saved;
}
static void registry_unlock(void)
{
    int saved = errno;
    if (pthread_mutex_unlock(&registry_mutex) != 0) abort();
    errno = saved;
}
static int landin_tool_capture_locked(char *path, size_t capacity);
static int landin_tool_capture_read_locked(int fd, char **bytes, size_t *length);
static int landin_tool_capture_close_locked(int fd, char *reason, size_t capacity);

struct landin_capture {
    int fd;
    struct landin_owned_directory owned;
    struct landin_capture *next;
};
static struct landin_capture *landin_captures;
void landin_tool_capture_set_hook(void (*hook)(const char *, const char *))
{ landin_owned_hook = hook; }
static int landin_tool_capture_locked(char *path, size_t capacity)
{
    struct landin_capture *capture = calloc(1, sizeof *capture);
    int error;
    if (!capture) return -1;
    if (landin_owned_create("landin-tool-", &capture->owned) != 0) {
        free(capture); return -1;
    }
    capture->fd = openat(capture->owned.root, "capture",
                         O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (capture->fd < 0 || unlinkat(capture->owned.root, "capture", 0) != 0)
        goto failed;
    if (strlen(capture->owned.path) >= capacity) {
        errno = ENAMETOOLONG; goto failed;
    }
    strcpy(path, capture->owned.path);
    capture->next = landin_captures; landin_captures = capture;
    if (landin_owned_hook) landin_owned_hook("created", path);
    return capture->fd;
failed:
    error = errno;
    if (capture->fd >= 0) close(capture->fd);
    landin_owned_remove(&capture->owned);
    if (capture->owned.root >= 0) close(capture->owned.root);
    close(capture->owned.parent); free(capture); errno = error; return -1;
}
static int landin_tool_capture_read_locked(int fd, char **bytes, size_t *length)
{
    size_t used = 0, room = 65536;
    char *data = malloc(room);
    if (!data) return -1;
    *bytes = NULL; *length = 0;
    for (;;) {
        ssize_t count;
        if (used == room) {
            char *larger;
            if (room > SIZE_MAX / 2) { free(data); errno = EOVERFLOW; return -1; }
            room *= 2;
            larger = realloc(data, room);
            if (!larger) { free(data); return -1; }
            data = larger;
        }
        count = pread(fd, data + used, room - used, (off_t)used);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { free(data); return -1; }
        if (count == 0) break;
        used += (size_t)count;
    }
    *bytes = data; *length = used; return 0;
}
void landin_tool_capture_free(char *bytes) { free(bytes); }
/* Consumes the data descriptor even when directory cleanup refuses. */
static int landin_tool_capture_close_locked(int fd, char *reason, size_t capacity)
{
    struct landin_capture **entry = &landin_captures;
    int result, closed;
    if (capacity) reason[0] = '\0';
    while (*entry && (*entry)->fd != fd) entry = &(*entry)->next;
    if (!*entry) { errno = EBADF; return -1; }
    {
        struct landin_capture *capture = *entry;
        *entry = capture->next;
        result = landin_owned_remove(&capture->owned);
        closed = close(fd);
        if (result < 0 && capacity)
            snprintf(reason, capacity, "%s", capture->owned.reason);
        else if (closed != 0 && capacity)
            snprintf(reason, capacity, "cannot close anonymous tool capture");
        if (capture->owned.root >= 0) close(capture->owned.root);
        close(capture->owned.parent); free(capture);
    }
    return result >= 0 && closed == 0 ? 0 : -1;
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
   number gives the child none rather than the capture.

   An isolated tool runs with exactly ENV, a NULL-terminated list of
   NAME=VALUE strings, rather than the caller's environment. */
int landin_tool_start_in_directory(char *const args[], char *const env[],
                                    int isolated, int input, int capture,
                                    int errors, int directory, int *child)
{
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    pid_t pid;
    int error;
    int moved[3] = {-1, -1, -1};
    const int no_input = input < 0
        && (capture == STDIN_FILENO || errors == STDIN_FILENO
            || directory == STDIN_FILENO);
    const int given_input = input;
    const int given_capture = capture;
    const int given_errors = errors;
    const int given_directory = directory;
    int index;

    *child = 0;
    error = landin_child_wait_policy();
    if (error != 0) return error;
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
        directory = landin_tool_source(given_directory, moved);
        if ((given_input >= 0 && input < 0) || capture < 0
            || (given_errors >= 0 && errors < 0)
            || (given_directory >= 0 && directory < 0))
            error = errno != 0 ? errno : EBADF;
    }
    /* Tool output paths are relative to a directory already pinned by the
       publication transaction, independent of a renamed public ancestor. */
    if (error == 0 && directory >= 0) {
#ifdef __APPLE__
        error = posix_spawn_file_actions_addfchdir(&actions, directory);
#else
        error = posix_spawn_file_actions_addfchdir_np(&actions, directory);
#endif
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
    if (error == 0 && directory >= 0 && directory != capture
        && directory != input && directory != errors)
        error = posix_spawn_file_actions_addclose(&actions, directory);
    if (error == 0)
        error = posix_spawn(&pid, args[0], &actions, &attributes, args,
                            isolated ? env : environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    for (index = 0; index <= STDERR_FILENO; index++)
        if (moved[index] >= 0)
            close(moved[index]);
    if (error == 0)
        *child = (int)pid;
    return error;
}

int landin_tool_start(char *const args[], char *const env[], int isolated,
                      int input, int capture, int errors, int *child)
{
    return landin_tool_start_in_directory(args, env, isolated, input,
                                           capture, errors, -1, child);
}

int landin_tool_wait_reserved(int child, int *status, int no_hang, int *owned)
{
    int word;
    pid_t reaped;

    *owned = child > 0;
    if (child <= 0) {
        errno = EINVAL;
        return -1;
    }
    do {
        reaped = waitpid((pid_t)child, &word, no_hang ? WNOHANG : 0);
    } while (reaped < 0 && errno == EINTR);
    if (reaped > 0) {
        *owned = 0;
        *status = WIFEXITED(word) ? WEXITSTATUS(word) : -1;
    } else if (reaped < 0 && errno == ECHILD) {
        *owned = 0;
    }
    return (int)reaped;
}

/* Preserve the original waitpid-compatible ABI for existing C callers. */
int landin_tool_wait(int child, int *status, int no_hang)
{
    int owned;
    return landin_tool_wait_reserved(child, status, no_hang, &owned);
}

int landin_tool_stop(int child, int *status)
{
    if (child <= 0) {
        errno = EINVAL;
        return -1;
    }
    /* The unreaped direct child reserves this group ID. Never signal a
       caller group, and never retry against a PID already reaped by Ada. */
    if (kill(-(pid_t)child, SIGKILL) != 0 && errno != ESRCH) {
#ifdef __APPLE__
        /* Darwin reports EPERM for a group containing only its zombie
           leader. Confirm the leader has exited without reaping it before
           treating that result as no remaining ordinary signal target.
           Tools that change credentials or escape their group are outside
           this supervisor's process-family contract. */
        siginfo_t info;
        int error = errno;
        memset(&info, 0, sizeof info);
        if (error != EPERM
            || waitid(P_PID, (id_t)child, &info,
                      WEXITED | WNOHANG | WNOWAIT) != 0
            || info.si_pid != (pid_t)child) {
            errno = error;
            return -1;
        }
#else
        return -1;
#endif
    }
    /* Still stop the direct child if it has changed its own group. It has
       not been reaped, so this PID cannot yet designate another process. */
    if (kill((pid_t)child, SIGKILL) != 0 && errno != ESRCH)
        return -1;
    return landin_tool_wait(child, status, 0);
}

/* Test-only observer: configure while no cancellation call is active; it must
   not reenter cancellation. Production leaves it NULL. Count delivery attempts
   rather than relying on standard signals not coalescing in a fast handler. */
static void (*landin_cancel_delivery_hook)(int, int, int);
void landin_tool_cancel_set_hook(void (*hook)(int, int, int))
{ landin_cancel_delivery_hook = hook; }
static int landin_cancel_forward(pid_t target, int number)
{
    int result = kill(target, number), error = errno;
    if (landin_cancel_delivery_hook)
        landin_cancel_delivery_hook((int)target, number, result);
    errno = error;
    return result;
}

/* Forward the original cancellation, allow a bounded ordinary shutdown,
   then stop remaining group members before reaping the leader. waitid's
   WNOWAIT keeps its PID reserved throughout signaling. This supervises
   descendants that keep the tool's group; it is not a daemon sandbox. */
int landin_tool_cancel_reserved(int child, int *status, int *owned)
{
    int number = landin_cancellation_requested();
    unsigned int attempts;
    *owned = child > 0;
    if (child <= 0 || number == 0) {
        errno = EINVAL;
        return -1;
    }
    /* The group includes its ordinary leader. A successful delivery must
       never be repeated to that leader: a catchable handler may already be
       running by the time kill returns. */
    if (landin_cancel_forward(-(pid_t)child, number) != 0) {
        int error = errno, observed;
        siginfo_t info;
        if (error != ESRCH
#ifdef __APPLE__
            && error != EPERM
#endif
            ) return -1;
        /* Only an unreaped child permits the direct fallback. WNOWAIT checks
           its state without releasing that reservation; no competing reaper
           or signal-policy change is allowed during this owned lifetime. */
        do {
            memset(&info, 0, sizeof info);
            observed = waitid(P_PID, (id_t)child, &info,
                               WEXITED | WNOHANG | WNOWAIT);
        } while (observed != 0 && errno == EINTR);
        if (observed != 0) {
            if (errno == ECHILD) *owned = 0;
            return -1;
        }
        if (info.si_pid == 0) {
            /* A missing group can leave the live direct child elsewhere.
               EPERM does not authorize retrying a live target. */
            if (error != ESRCH) { errno = error; return -1; }
            if (landin_cancel_forward((pid_t)child, number) != 0
                && errno != ESRCH) return -1;
        } else if (info.si_pid != (pid_t)child) {
            *owned = 0; errno = ECHILD; return -1;
        }
        /* No catchable signal is needed for an exited child. In particular,
           Darwin can report EPERM for its zombie-only group; Stop below
           handles that state while retaining the leader through cleanup. */
    }
    for (attempts = 0; attempts < 50; ++attempts) {
        siginfo_t info;
        const struct timespec interval = {0, 20000000};
        memset(&info, 0, sizeof info);
        if (waitid(P_PID, (id_t)child, &info,
                   WEXITED | WNOHANG | WNOWAIT) != 0 && errno != EINTR) {
            if (errno == ECHILD) *owned = 0;
            return -1;
        }
        if (info.si_pid != 0)
            break;
        nanosleep(&interval, NULL);
    }
    int result = landin_tool_stop(child, status);
    if (result == child || (result < 0 && errno == ECHILD)) *owned = 0;
    return result;
}

/* Preserve the original cancellation ABI for C callers owning their child. */
int landin_tool_cancel(int child, int *status)
{
    int owned;
    return landin_tool_cancel_reserved(child, status, &owned);
}

/* The program landin_program_run is waiting for, and a termination or
   hangup that arrived before it was known, for the handler below. */
static volatile sig_atomic_t landin_program_child = 0;
static volatile sig_atomic_t landin_program_pending = 0;

/* Pass a termination or hangup sent to refine on to its program, which
   ends by it, so refine is left to remove the program's directory and
   report how it ended rather than end first and leave both behind. */
static void landin_program_forward(int signal_number)
{
    int saved = errno;

    if (landin_program_child > 0)
        kill((pid_t)landin_program_child, signal_number);
    else
        landin_program_pending = signal_number;
    errno = saved;
}

/* Forward NUMBER while the program runs, saving its disposition in OLD,
   unless refine was started with it ignored, as nohup starts a command:
   then it stays ignored, and the program inherits that. */
static void landin_program_catch(int number, struct sigaction *old)
{
    struct sigaction forward;

    sigaction(number, NULL, old);
    if (old->sa_handler == SIG_IGN)
        return;
    memset(&forward, 0, sizeof forward);
    forward.sa_handler = landin_program_forward;
    sigemptyset(&forward.sa_mask);
    forward.sa_flags = SA_RESTART;
    sigaction(number, &forward, NULL);
}

/* D526: run the program refine run built, attached to the caller's
   terminal: its standard descriptors, its process group, no limit.  The
   child starts with the default action for the interrupt and quit signals,
   which refine ignores while the child runs, so a terminal's ^C and ^\
   reach the program and refine stays to remove its directory and report
   how it ended.  A termination or hangup sent to refine alone, as kill
   or a closed session sends it, is forwarded to the program for the same
   reason; both are blocked until the program is known, so one sent while
   it starts is forwarded once it has.  Returns 0 with STATUS the exit
   status, or with SIGNAL_NUMBER nonzero when a signal ended it; otherwise
   an errno value, CHILD nonzero when the program was started and could
   not be waited for. */
int landin_program_run(char *const args[], int *signal_number,
                       int *status, int *child)
{
    posix_spawnattr_t attributes;
    struct sigaction ignore, old_interrupt, old_quit, old_terminate,
        old_hangup;
    sigset_t defaults, forwarded, old_mask;
    pid_t pid;
    pid_t reaped;
    int word = 0;
    int error;

    *signal_number = 0;
    *status = 0;
    *child = 0;
    error = landin_child_wait_policy();
    if (error != 0) return error;
    sigemptyset(&forwarded);
    sigaddset(&forwarded, SIGTERM);
    sigaddset(&forwarded, SIGHUP);
    error = pthread_sigmask(SIG_BLOCK, &forwarded, &old_mask);
    if (error != 0)
        return error;
    error = posix_spawnattr_init(&attributes);
    if (error != 0) {
        pthread_sigmask(SIG_SETMASK, &old_mask, NULL);
        return error;
    }
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGQUIT);
    error = posix_spawnattr_setsigdefault(&attributes, &defaults);
    /* The program starts with refine's mask as it was before the block. */
    if (error == 0)
        error = posix_spawnattr_setsigmask(&attributes, &old_mask);
    if (error == 0)
        error = posix_spawnattr_setflags
            (&attributes, POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);
    if (error != 0) {
        posix_spawnattr_destroy(&attributes);
        pthread_sigmask(SIG_SETMASK, &old_mask, NULL);
        return error;
    }
    memset(&ignore, 0, sizeof ignore);
    ignore.sa_handler = SIG_IGN;
    sigemptyset(&ignore.sa_mask);
    sigaction(SIGINT, &ignore, &old_interrupt);
    sigaction(SIGQUIT, &ignore, &old_quit);
    landin_program_child = 0;
    landin_program_pending = 0;
    landin_program_catch(SIGTERM, &old_terminate);
    landin_program_catch(SIGHUP, &old_hangup);
    error = posix_spawn(&pid, args[0], NULL, &attributes, args, environ);
    posix_spawnattr_destroy(&attributes);
    if (error != 0) {
        /* No program to pass them to: what was sent is refine's again. */
        sigaction(SIGTERM, &old_terminate, NULL);
        sigaction(SIGHUP, &old_hangup, NULL);
    } else {
        *child = (int)pid;
        landin_program_child = (sig_atomic_t)pid;
    }
    /* What was blocked is delivered here, to the program or to refine. */
    pthread_sigmask(SIG_SETMASK, &old_mask, NULL);
    if (error != 0 && landin_program_pending != 0)
        raise(landin_program_pending);
    if (error == 0) {
        if (landin_program_pending != 0)
            kill(pid, landin_program_pending);
        do {
            reaped = waitpid(pid, &word, 0);
        } while (reaped < 0 && errno == EINTR);
        if (reaped < 0)
            error = errno;
        else if (WIFSIGNALED(word))
            *signal_number = WTERMSIG(word);
        else
            *status = WEXITSTATUS(word);
    }
    if (*child != 0) {
        sigaction(SIGTERM, &old_terminate, NULL);
        sigaction(SIGHUP, &old_hangup, NULL);
    }
    landin_program_child = 0;
    sigaction(SIGINT, &old_interrupt, NULL);
    sigaction(SIGQUIT, &old_quit, NULL);
    return error;
}

/* The host's name for a signal number, or NULL for one not listed. */
const char *landin_signal_name(int signal_number)
{
    switch (signal_number) {
    case SIGHUP: return "SIGHUP";
    case SIGINT: return "SIGINT";
    case SIGQUIT: return "SIGQUIT";
    case SIGILL: return "SIGILL";
    case SIGTRAP: return "SIGTRAP";
    case SIGABRT: return "SIGABRT";
    case SIGBUS: return "SIGBUS";
    case SIGFPE: return "SIGFPE";
    case SIGKILL: return "SIGKILL";
    case SIGUSR1: return "SIGUSR1";
    case SIGSEGV: return "SIGSEGV";
    case SIGUSR2: return "SIGUSR2";
    case SIGPIPE: return "SIGPIPE";
    case SIGALRM: return "SIGALRM";
    case SIGTERM: return "SIGTERM";
    case SIGCHLD: return "SIGCHLD";
    case SIGCONT: return "SIGCONT";
    case SIGSTOP: return "SIGSTOP";
    case SIGTSTP: return "SIGTSTP";
    case SIGTTIN: return "SIGTTIN";
    case SIGTTOU: return "SIGTTOU";
    case SIGURG: return "SIGURG";
    case SIGXCPU: return "SIGXCPU";
    case SIGXFSZ: return "SIGXFSZ";
    case SIGVTALRM: return "SIGVTALRM";
    case SIGPROF: return "SIGPROF";
    case SIGSYS: return "SIGSYS";
    default: return NULL;
    }
}

/* Public registry boundaries. No lock spans a child process lifetime. */
int landin_tool_capture(char *path, size_t capacity)
{
    registry_lock();
    int result = landin_tool_capture_locked(path, capacity);
    registry_unlock();
    return result;
}
int landin_tool_capture_read(int fd, char **bytes, size_t *length)
{
    registry_lock();
    int result = landin_tool_capture_read_locked(fd, bytes, length);
    registry_unlock();
    return result;
}
int landin_tool_capture_close(int fd, char *reason, size_t capacity)
{
    registry_lock();
    int result = landin_tool_capture_close_locked(fd, reason, capacity);
    registry_unlock();
    return result;
}
