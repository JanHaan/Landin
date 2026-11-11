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
#include <stdatomic.h>
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
void landin_cancellation_hold(void);
void landin_cancellation_release(void);
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

/* Invocation cancellation.  A signal that finds nothing to recover ends the
   process at once, from the handler: a command that is only reading and
   computing holds nothing a signal could leave half done, so the handler
   writes the line a recovered cancellation ends with and exits with 128
   plus the number, the one outcome a caller sees whether or not anything
   was held (D1046).  It does so itself, with write and _exit alone, so
   that a stage that is running, or will never end, is stopped there and
   then; asking between stages would cost the rest of the stage, and
   asking inside one would reach every loop of the compiler.  While
   something is held (an open
   publication, a private directory, a tool's capture, a source being
   rewritten) the signal is recorded instead, and the supervising thread
   unwinds: no filesystem work, Ada cleanup, or potentially reused
   process-group identifier reaches a handler, and the supervisor forwards
   the signal while it still owns an unreaped child.  A recorded signal
   also starts the grace period below, so a stage that never looks at the
   record cannot keep the process alive.  Inherited ignored signals stay
   ignored.

   SIGPIPE is one of them: refine writing its own report into a closed pipe
   while `refine run` holds a private directory must reach the removal of
   that directory, and with nothing held it still ends the process by its
   default action, quietly: the report's reader is the one that left.

   SIGXFSZ is ignored for the invocation, so a write past the file-size
   limit returns EFBIG to the adapters, whose recovery is written for that
   error; its default action would end the process inside the write.  A
   child gets the inherited disposition back in its spawn attributes. */
static volatile sig_atomic_t landin_cancel_signal = 0;
static atomic_int landin_cancel_holds;
static int landin_cancel_active = 0;
enum { LANDIN_CANCEL_COUNT = 4, LANDIN_CANCEL_GRACE_SECONDS = 10 };
static const int landin_cancel_numbers[LANDIN_CANCEL_COUNT] =
    {SIGINT, SIGTERM, SIGHUP, SIGPIPE};
static struct sigaction landin_cancel_saved[LANDIN_CANCEL_COUNT];
static struct sigaction landin_cancel_saved_limit, landin_cancel_saved_alarm;
static int landin_cancel_limit_ignored = 0, landin_cancel_grace = 0;

/* One hold for each thing a signal's default action would leave behind.
   The handler only reads the count; a signal racing a change is the same
   signal arriving just before or just after it. */
void landin_cancellation_hold(void)
{
    atomic_fetch_add(&landin_cancel_holds, 1);
}
void landin_cancellation_release(void)
{
    atomic_fetch_sub(&landin_cancel_holds, 1);
}

/* End by NUMBER's default action from inside a handler. */
static void landin_cancel_default(int number)
{
    struct sigaction action;
    sigset_t only;
    memset(&action, 0, sizeof action);
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    sigaction(number, &action, NULL);
    sigemptyset(&only);
    sigaddset(&only, number);
    raise(number);
    /* Blocked while its own handler runs: deliver it here, not on return,
       so no further instruction of the interrupted stage executes. */
    pthread_sigmask(SIG_UNBLOCK, &only, NULL);
}

/* End from inside a handler as a recovered cancellation ends: the last
   line on standard error, then 128 plus NUMBER.  Only write and _exit are
   called, both async-signal-safe; nothing buffered is flushed and no
   cleanup runs, which is right because nothing is held.  A standard error
   that cannot take the line changes nothing: the status still says it. */
static void landin_cancel_report(int number)
{
    static const char head[] = "refine: cancelled by signal ";
    char line[sizeof head + 16];
    char digits[12];
    size_t length = 0, count = 0;
    int rest = number;
    for (; length < sizeof head - 1; ++length)
        line[length] = head[length];
    do {
        digits[count++] = (char)('0' + rest % 10);
        rest /= 10;
    } while (rest != 0 && count < sizeof digits);
    while (count != 0)
        line[length++] = digits[--count];
    line[length++] = '\n';
    while (count < length) {
        ssize_t wrote = write(STDERR_FILENO, line + count, length - count);
        if (wrote <= 0) {
            if (wrote < 0 && errno == EINTR)
                continue;
            break;
        }
        count += (size_t)wrote;
    }
    _exit(128 + number);
}

static void landin_cancel_notify(int number)
{
    int saved = errno;
    if (landin_cancel_signal == 0) {
        if (atomic_load(&landin_cancel_holds) <= 0) {
            if (number == SIGPIPE)
                landin_cancel_default(number);
            landin_cancel_report(number);
        }
        landin_cancel_signal = number;
        if (landin_cancel_grace)
            alarm(LANDIN_CANCEL_GRACE_SECONDS);
    }
    errno = saved;
}

/* The recorded signal was not answered within the grace period: whatever
   is running has not reached a point that looks.  End by that signal as
   SIGKILL would end it, leaving what the publication records describe. */
static void landin_cancel_expire(int number)
{
    int recorded = (int)landin_cancel_signal;
    (void)number;
    if (recorded != 0)
        landin_cancel_default(recorded);
}

/* The dispositions a child of this invocation starts with by default:
   the file-size signal refine ignores for itself, unless the caller had
   already ignored it. */
static void landin_cancel_child_defaults(sigset_t *defaults)
{
    if (landin_cancel_limit_ignored
        && landin_cancel_saved_limit.sa_handler != SIG_IGN)
        sigaddset(defaults, SIGXFSZ);
}

int landin_cancellation_begin(void)
{
    struct sigaction action, ignore, expire;
    size_t index = 0;
    if (landin_cancel_active)
        return 0;
    memset(&action, 0, sizeof action);
    action.sa_handler = landin_cancel_notify;
    sigemptyset(&action.sa_mask);
    for (index = 0; index < LANDIN_CANCEL_COUNT; ++index)
        sigaddset(&action.sa_mask, landin_cancel_numbers[index]);
    sigaddset(&action.sa_mask, SIGALRM);
    memset(&ignore, 0, sizeof ignore);
    ignore.sa_handler = SIG_IGN;
    sigemptyset(&ignore.sa_mask);
    memset(&expire, 0, sizeof expire);
    expire.sa_handler = landin_cancel_expire;
    sigemptyset(&expire.sa_mask);
    landin_cancel_signal = 0;
    index = 0;
    if (sigaction(SIGXFSZ, &ignore, &landin_cancel_saved_limit) != 0)
        return errno;
    landin_cancel_limit_ignored = 1;
    /* A caller that ignores the alarm keeps it ignored, and has no grace
       period. */
    if (sigaction(SIGALRM, NULL, &landin_cancel_saved_alarm) != 0)
        goto failed;
    if (landin_cancel_saved_alarm.sa_handler != SIG_IGN) {
        if (sigaction(SIGALRM, &expire, NULL) != 0)
            goto failed;
        landin_cancel_grace = 1;
    }
    for (index = 0; index < LANDIN_CANCEL_COUNT; ++index) {
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
        if (landin_cancel_grace)
            sigaction(SIGALRM, &landin_cancel_saved_alarm, NULL);
        landin_cancel_grace = 0;
        sigaction(SIGXFSZ, &landin_cancel_saved_limit, NULL);
        landin_cancel_limit_ignored = 0;
        return error;
    }
}

void landin_cancellation_end(void)
{
    size_t index;
    if (!landin_cancel_active)
        return;
    for (index = 0; index < LANDIN_CANCEL_COUNT; ++index)
        sigaction(landin_cancel_numbers[index], &landin_cancel_saved[index],
                   NULL);
    if (landin_cancel_grace) {
        alarm(0);
        sigaction(SIGALRM, &landin_cancel_saved_alarm, NULL);
        landin_cancel_grace = 0;
    }
    sigaction(SIGXFSZ, &landin_cancel_saved_limit, NULL);
    landin_cancel_limit_ignored = 0;
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
    /* Held from before the directory exists until it is removed. */
    landin_cancellation_hold();
    if (landin_owned_create("landin-tool-", &capture->owned) != 0) {
        error = errno;
        landin_cancellation_release();
        free(capture); errno = error; return -1;
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
    close(capture->owned.parent); free(capture);
    landin_cancellation_release();
    errno = error; return -1;
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
        landin_cancellation_release();
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
    if (error == 0) {
        sigset_t defaults;
        sigemptyset(&defaults);
        landin_cancel_child_defaults(&defaults);
        error = posix_spawnattr_setsigdefault(&attributes, &defaults);
    }
    if (error == 0)
        error = posix_spawnattr_setflags
            (&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF);
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
    if (error == 0) {
        *child = (int)pid;
        /* An unreaped tool is something to recover: it is stopped and
           reaped by its supervisor, not orphaned by a signal's default
           action. Held until this adapter reaps it. */
        landin_cancellation_hold();
    }
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
        landin_cancellation_release();
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
        int error = errno, observed = 0;
        memset(&info, 0, sizeof info);
        if (error != EPERM
            || (observed = waitid(P_PID, (id_t)child, &info,
                                  WEXITED | WNOHANG | WNOWAIT)) != 0
            || info.si_pid != (pid_t)child) {
            /* Ownership-aware callers must see a known lost reservation. */
            if (error == EPERM && observed != 0 && errno == ECHILD) return -1;
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

/* Test-only synchronous lifecycle observation; configure while no program
   run is active. Stages are exited-but-reserved, handlers-restored, reaped. */
static void (*landin_program_hook)(int, int);
void landin_program_set_hook(void (*hook)(int, int))
{
    landin_program_hook = hook;
}

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
   child preserves inherited ignored interrupt and quit signals; otherwise
   it starts with their default action. Refine ignores both while the child
   runs, so a terminal's ^C and ^\
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
    siginfo_t ended;
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
    /* An explicit inherited ignore survives exec, just as direct execution
       would preserve it. Query before installing our temporary ignores. */
    if (sigaction(SIGINT, NULL, &old_interrupt) != 0
        || sigaction(SIGQUIT, NULL, &old_quit) != 0) {
        error = errno;
        posix_spawnattr_destroy(&attributes);
        pthread_sigmask(SIG_SETMASK, &old_mask, NULL);
        return error;
    }
    if (old_interrupt.sa_handler != SIG_IGN) sigaddset(&defaults, SIGINT);
    if (old_quit.sa_handler != SIG_IGN) sigaddset(&defaults, SIGQUIT);
    landin_cancel_child_defaults(&defaults);
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
    /* From here a termination or hangup is forwarded, so the invocation's
       grace period ends; one recorded just before is the program's too. */
    if (landin_cancel_active) {
        int recorded = (int)landin_cancel_signal;
        if (landin_cancel_grace) alarm(0);
        if (recorded == SIGTERM || recorded == SIGHUP)
            landin_program_pending = recorded;
    }
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
        memset(&ended, 0, sizeof ended);
        do {
            error = waitid(P_PID, (id_t)pid, &ended, WEXITED | WNOWAIT);
        } while (error < 0 && errno == EINTR);
        error = error < 0 ? errno : 0;
        if (error == 0 && landin_program_hook) landin_program_hook(pid, 1);
        /* The exited child still reserves its identifier while forwarding
           is active. Restore the handlers and clear their target before
           the final reap releases that reservation. */
        sigaction(SIGTERM, &old_terminate, NULL);
        sigaction(SIGHUP, &old_hangup, NULL);
        landin_program_child = 0;
        if (error == 0) {
            if (landin_program_hook) landin_program_hook(pid, 2);
            do {
                reaped = waitpid(pid, &word, 0);
            } while (reaped < 0 && errno == EINTR);
            if (reaped < 0) error = errno;
            else if (landin_program_hook) landin_program_hook(pid, 3);
        }
        if (error == 0 && WIFSIGNALED(word))
            *signal_number = WTERMSIG(word);
        else if (error == 0)
            *status = WEXITSTATUS(word);
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
