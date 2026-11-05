/* Native controls for the production POSIX tool-process helper.
   No cancellation implementation is copied here. Each controller owns its
   spawned group until the production helper stops and reaps its leader. */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

int landin_tool_start(char *const[], char *const[], int, int, int, int, int *);
int landin_tool_wait(int, int *, int);
int landin_tool_wait_reserved(int, int *, int, int *);
int landin_tool_start_in_directory(char *const[], char *const[], int, int, int,
                                    int, int, int *);
int landin_program_run(char *const[], int *, int *, int *);
const char *landin_process_start_error(int);
int landin_tool_cancel(int, int *);
void landin_tool_cancel_set_hook(void (*)(int, int, int));
int landin_tool_stop(int, int *);
int landin_cancellation_begin(void);
void landin_cancellation_end(void);
int landin_cancellation_requested(void);

static int owned_child;
static volatile sig_atomic_t received;
static volatile sig_atomic_t restored;
static volatile sig_atomic_t timed_out;
static const int numbers[] = {SIGINT, SIGTERM, SIGHUP};

static unsigned int delivery_calls;
static int delivery_target, delivery_number, delivery_result;
static void record_delivery(int target, int number, int result)
{
    ++delivery_calls;
    delivery_target = target; delivery_number = number; delivery_result = result;
}

static void fail(const char *message)
{
    int status;
    int saved = errno;
    if (owned_child > 0) {
        siginfo_t info;
        memset(&info, 0, sizeof info);
        /* A failed assertion never signals a group after losing its direct
           child reservation. This is failure cleanup, not a test substitute. */
        if (waitid(P_PID, (id_t)owned_child, &info,
                   WEXITED | WNOHANG | WNOWAIT) == 0) {
            int stopped = landin_tool_stop(owned_child, &status);
            /* Preserve a failing stop assertion, but reap an already-dead
               direct child even if the production stop helper refused it. */
            if (stopped < 0 && info.si_pid == (pid_t)owned_child)
                (void)waitpid((pid_t)owned_child, &status, 0);
        }
    }
    fprintf(stderr, "FAIL: %s (errno=%d)\n", message, saved);
    exit(2);
}

static void require(int yes, const char *message)
{
    if (!yes)
        fail(message);
}

static void notification(int number)
{
    if (received == 0)
        received = number;
}

static void original(int number)
{
    restored = number;
}

static void deadline(int number)
{
    (void)number;
    timed_out = 1;
}

static void handler(int number, void (*function)(int))
{
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = function;
    sigemptyset(&action.sa_mask);
    sigaddset(&action.sa_mask, SIGUSR2);
    require(sigaction(number, &action, NULL) == 0, "install handler");
}

static void byte_read(int fd)
{
    char byte;
    ssize_t count;
    do {
        require(!timed_out, "read deadline");
        count = read(fd, &byte, 1);
    } while (count < 0 && errno == EINTR);
    require(count == 1, "read readiness acknowledgement");
}

/* Block the signals before testing the flag, then atomically unblock them
   while waiting. There is no readiness timing window or polling interval. */
static void await_signal(int cancellation)
{
    sigset_t blocked, previous;
    size_t index;
    sigemptyset(&blocked);
    for (index = 0; index < 3; ++index)
        sigaddset(&blocked, numbers[index]);
    sigaddset(&blocked, SIGALRM);
    require(sigprocmask(SIG_BLOCK, &blocked, &previous) == 0, "block signals");
    while ((cancellation ? landin_cancellation_requested() : received) == 0) {
        require(!timed_out, "signal deadline");
        (void)sigsuspend(&previous);
    }
    require(sigprocmask(SIG_SETMASK, &previous, NULL) == 0, "restore mask");
}

static void dispositions(int ignored)
{
    size_t index;
    for (index = 0; index < 3; ++index)
        handler(numbers[index], numbers[index] == ignored ? SIG_IGN : original);
}

static void check_restored(int ignored)
{
    size_t index;
    for (index = 0; index < 3; ++index) {
        struct sigaction action;
        int number = numbers[index];
        require(sigaction(number, NULL, &action) == 0, "get disposition");
        require(action.sa_handler == (number == ignored ? SIG_IGN : original),
                "original disposition restored");
        require(sigismember(&action.sa_mask, SIGUSR2) == 1,
                "original handler mask restored");
        restored = 0;
        require(raise(number) == 0, "raise restored signal");
        require(restored == (number == ignored ? 0 : number),
                "restored handler executes");
    }
    require(landin_cancellation_requested() == 0, "end resets request");
}

static void reaped(int child)
{
    int word;
    owned_child = 0;
    errno = 0;
    require(waitpid((pid_t)child, &word, WNOHANG) == -1 && errno == ECHILD,
            "direct child already reaped by production helper");
    owned_child = 0;
    puts("DIRECT_REAPED");
}

static void tool(int events, int ready, int stubborn)
{
    int acknowledgement[2];
    pid_t descendant;
    size_t index;
    for (index = 0; index < 3; ++index)
        handler(numbers[index], notification);
    require(pipe(acknowledgement) == 0, "descendant acknowledgement pipe");
    descendant = fork();
    require(descendant >= 0, "fork descendant");
    if (descendant == 0) {
        close(acknowledgement[0]);
        received = 0;
        require(write(acknowledgement[1], "R", 1) == 1, "descendant ready");
        close(acknowledgement[1]);
        await_signal(0);
        dprintf(events, "DESCENDANT_SIGNAL %d\n", (int)received);
        if (stubborn) {
            /* Only production's bounded SIGKILL escalation ends this role.
               Keep the event descriptor open, so EOF proves it stopped. */
            for (;;)
                pause();
        }
        _exit(0);
    }
    close(acknowledgement[1]);
    byte_read(acknowledgement[0]);
    close(acknowledgement[0]);
    require(write(ready, "R", 1) == 1, "tool and descendant ready");
    close(ready);
    await_signal(0);
    dprintf(events, "TOOL_SIGNAL %d\n", (int)received);
    if (stubborn) {
        for (;;)
            pause();
    } else {
        int word;
        pid_t result;
        do {
            result = waitpid(descendant, &word, 0);
        } while (result < 0 && errno == EINTR);
        require(result == descendant && WIFEXITED(word)
                && WEXITSTATUS(word) == 0, "tool reaps its own descendant");
        dprintf(events, "DESCENDANT_REAPED_BY_TOOL\n");
        _exit(0);
    }
}

static int start(const char *self, const char *role, int number,
                 int ready, int events)
{
    char ready_arg[32], event_arg[32], number_arg[32];
    char *args[7];
    int input, capture, child = 0;
    snprintf(ready_arg, sizeof ready_arg, "%d", ready);
    snprintf(event_arg, sizeof event_arg, "%d", events);
    snprintf(number_arg, sizeof number_arg, "%d", number);
    args[0] = (char *)self;
    args[1] = (char *)role;
    args[2] = event_arg;
    args[3] = ready_arg;
    args[4] = number_arg;
    args[5] = NULL;
    input = open("input", O_CREAT | O_EXCL | O_RDWR, 0600);
    capture = open("capture", O_CREAT | O_EXCL | O_RDWR, 0600);
    require(input >= 0 && capture >= 0, "owned input/capture files");
    require(landin_tool_start(args, NULL, 0, input, capture, -1, &child) == 0,
            "start actual production tool group");
    owned_child = child;
    close(input);
    close(capture);
    return child;
}

/* The rejected program would write a byte through an inherited pipe. EOF
   after closing our write end proves no writer was started, without signaling
   any PID or invoking stop/cancel after a failed wait. */
static int rejected_child_policy(const char *self, int no_wait)
{
    struct sigaction action, previous, configured, observed;
    int channel[2], child, error, nullfd, status, number, owned = 1;
    char descriptor[32], byte;
    memset(&action, 0, sizeof action);
    action.sa_handler = no_wait ? SIG_DFL : SIG_IGN;
    action.sa_flags = no_wait ? SA_NOCLDWAIT : 0;
    sigemptyset(&action.sa_mask);
    sigaddset(&action.sa_mask, SIGUSR2);
    require(sigaction(SIGCHLD, &action, &previous) == 0, "set child policy");
    /* Darwin adds SA_NOCLDWAIT when SIG_IGN is installed for SIGCHLD.
       Compare the actual installed policy, including its normalized flags. */
    require(sigaction(SIGCHLD, NULL, &configured) == 0,
            "observe installed child policy");
    require(pipe(channel) == 0, "own rejected child notification pipe");
    snprintf(descriptor, sizeof descriptor, "%d", channel[1]);
    char *args[] = {(char *)self, "policy-child", descriptor, NULL};
    nullfd = open("/dev/null", O_RDWR);
    require(nullfd >= 0, "open rejected child streams");
    for (int api = 0; api < 3; ++api) {
        child = 123;
        if (api == 0)
            error = landin_tool_start(args, NULL, 0, nullfd, nullfd, -1, &child);
        else if (api == 1)
            error = landin_tool_start_in_directory(args, NULL, 0, nullfd,
                                                    nullfd, -1, -1, &child);
        else
            error = landin_program_run(args, &number, &status, &child);
        const char *reason = landin_process_start_error(error);
        require(error != 0 && child == 0 && reason != NULL,
                "C entrypoint refuses before creating any child");
        require(strstr(reason, no_wait ? "SA_NOCLDWAIT" : "SIGCHLD is ignored")
                    != NULL, "actionable inherited child policy reason");
        require(sigaction(SIGCHLD, NULL, &observed) == 0
                && observed.sa_handler == configured.sa_handler
                && observed.sa_flags == configured.sa_flags,
                "inherited child handler and flags remain unchanged");
        /* Native sigsets cover at most their storage's bit capacity. Query
           membership rather than comparing opaque storage or padding bytes. */
        for (size_t signal = 1; signal <= sizeof(sigset_t) * CHAR_BIT; ++signal)
            require(sigismember(&observed.sa_mask, (int)signal)
                    == sigismember(&configured.sa_mask, (int)signal),
                    "inherited child signal mask remains unchanged");
    }
    require(close(channel[1]) == 0 && read(channel[0], &byte, 1) == 0,
            "no rejected child wrote its startup sentinel");
    close(channel[0]); close(nullfd);
    /* Our own PID cannot be our child: exercise the structured lost-reservation
       result without creating, signaling, or risking reuse of any child PID. */
    require(landin_tool_wait_reserved((int)getpid(), &status, 1, &owned) < 0
            && errno == ECHILD && owned == 0, "lost reservation is explicit");
    require(sigaction(SIGCHLD, &previous, NULL) == 0, "restore child policy");
    puts("CHILD_POLICY_REFUSED"); puts("PASS");
    return 0;
}

int main(int argc, char **argv)
{
    int number, events, child, status = 0;
    int automatic = 0;
    int ready[2];
    const char *mode;
    if (argc >= 2 && strcmp(argv[1], "policy-child") == 0) {
        require(argc == 3 && write(atoi(argv[2]), "X", 1) == 1,
                "rejected child startup sentinel");
        return 0;
    }
    if (argc >= 3 && strcmp(argv[1], "exec-ignored") == 0) {
        struct sigaction action;
        memset(&action, 0, sizeof action); action.sa_handler = SIG_IGN;
        sigemptyset(&action.sa_mask);
        require(sigaction(SIGCHLD, &action, NULL) == 0, "inherit ignored child policy");
        execv(argv[2], argv + 2);
        fail("exec actual refine with ignored child policy");
    }
    if (argc == 2 && strcmp(argv[1], "--all") == 0) {
        const int selected_numbers[] = {SIGINT, SIGTERM, SIGHUP};
        const char *modes[] = {"cancel", "before", "ignore", "stubborn"};
        char *self = realpath(argv[0], NULL);
        char root[] = "tool-cancellation-XXXXXX";
        unsigned int at;
        require(self != NULL && mkdtemp(root) != NULL,
                "own automatic control root");
        for (at = 0; at < 15; ++at) {
            char name[64], mode_arg[64], signal_arg[32], directory[256];
            const char *selected = at == 0 ? "normal"
                : at == 13 ? "reap-ignore" : at == 14 ? "reap-nowait"
                : modes[(at - 1) / 3];
            int selected_signal = at == 0 || at >= 13 ? 0
                : selected_numbers[(at - 1) % 3];
            snprintf(name, sizeof name, "%s-%d", selected, selected_signal);
            snprintf(directory, sizeof directory, "%s/%s", root, name);
            snprintf(mode_arg, sizeof mode_arg, "auto-%s", selected);
            snprintf(signal_arg, sizeof signal_arg, "%d", selected_signal);
            require(mkdir(directory, 0700) == 0, "own automatic case directory");
            pid_t controller = fork();
            require(controller >= 0, "fork automatic control");
            if (controller == 0) {
                require(chdir(directory) == 0, "enter automatic case");
                execl(self, self, mode_arg, signal_arg, (char *)NULL);
                _exit(127);
            }
            int word;
            require(waitpid(controller, &word, 0) == controller
                    && WIFEXITED(word) && WEXITSTATUS(word) == 0,
                    "automatic control passed");
        }
        free(self);
        puts("cancellation native: 15 controls passed");
        return 0;
    }
    require(argc >= 3, "mode and signal arguments");
    mode = argv[1];
    if (strncmp(mode, "auto-", 5) == 0) {
        automatic = 1;
        mode += 5;
    }
    if (strcmp(mode, "tool") == 0 || strcmp(mode, "stubborn-tool") == 0) {
        require(argc == 5, "tool arguments");
        tool(atoi(argv[2]), atoi(argv[3]), strcmp(mode, "stubborn-tool") == 0);
        return 2;
    }
    if (strcmp(mode, "quick") == 0) {
        struct sigaction action;
        require(argc == 5, "quick arguments");
        number = atoi(argv[4]);
        if (number != 0) {
            require(sigaction(number, NULL, &action) == 0
                    && action.sa_handler == SIG_IGN, "tool inherits ignore");
            require(raise(number) == 0, "tool ignores inherited signal");
            dprintf(atoi(argv[2]), "TOOL_INHERITED_IGNORE\n");
        }
        return 23;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    handler(SIGALRM, deadline);
    alarm(12);
    number = atoi(argv[2]);
    if (!strcmp(mode, "reap-ignore") || !strcmp(mode, "reap-nowait"))
        return rejected_child_policy(argv[0], !strcmp(mode, "reap-nowait"));
    dispositions(strcmp(mode, "ignore") == 0 ? number : 0);
    require(landin_cancellation_begin() == 0, "begin cancellation");
    events = dup(STDOUT_FILENO);
    require(events >= 0, "inheritable event descriptor");
    if (strcmp(mode, "before") == 0) {
        if (automatic)
            require(raise(number) == 0, "automatic before-spawn signal");
        else
            puts("READY");
        await_signal(1);
        require(landin_cancellation_requested() == number, "before spawn signal");
    }
    require(pipe(ready) == 0, "tool readiness pipe");
    child = start(argv[0],
                  strcmp(mode, "normal") == 0 || strcmp(mode, "ignore") == 0
                      ? "quick" : strcmp(mode, "stubborn") == 0
                          ? "stubborn-tool" : "tool",
                  strcmp(mode, "ignore") == 0 ? number : 0, ready[1], events);
    close(ready[1]);
    if (strcmp(mode, "normal") == 0 || strcmp(mode, "ignore") == 0) {
        int result = landin_tool_wait(child, &status, 0);
        if (result == child)
            owned_child = 0;
        require(result == child && status == 23, "normal exit status");
        reaped(child);
        if (strcmp(mode, "ignore") == 0) {
            if (!automatic) {
                puts("READY");
                byte_read(STDIN_FILENO);
            }
            require(raise(number) == 0, "raise inherited ignored signal");
        }
        require(landin_cancellation_requested() == 0, "no cancellation");
    } else {
        byte_read(ready[0]);
        if (strcmp(mode, "before") != 0) {
            if (automatic)
                require(raise(number) == 0, "automatic cancellation signal");
            else
                puts("READY");
            await_signal(1);
        }
        require(landin_cancellation_requested() == number,
                "original invocation signal recorded");
        require(landin_cancellation_begin() == 0, "nested begin is idempotent");
        require(raise(number == SIGINT ? SIGTERM : SIGINT) == 0,
                "later signal delivered");
        require(landin_cancellation_requested() == number,
                "first cancellation signal retained");
        {
            delivery_calls = 0;
            landin_tool_cancel_set_hook(record_delivery);
            int result = landin_tool_cancel(child, &status);
            landin_tool_cancel_set_hook(NULL);
            if (result == child)
                owned_child = 0;
            require(result == child,
                    "production cancel stops and reaps direct child");
            require(delivery_calls == 1 && delivery_target == -child
                    && delivery_number == number && delivery_result == 0,
                    "one original-signal delivery to the ordinary tool group");
        }
        require(status == (strcmp(mode, "stubborn") == 0 ? -1 : 0),
                "cooperative versus forced stop status");
        reaped(child);
    }
    close(ready[0]);
    close(events);
    landin_cancellation_end();
    check_restored(strcmp(mode, "ignore") == 0 ? number : 0);
    landin_cancellation_end();
    alarm(0);
    puts("PASS");
    return 0;
}
