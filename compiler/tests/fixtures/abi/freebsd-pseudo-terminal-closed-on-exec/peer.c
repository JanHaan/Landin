/*
 * The program's own posix_openpt, which the executable's definition makes
 * the one platform/posix calls: it records the flags it is given and makes
 * FreeBSD's system call.  The controller must be asked for close-on-exec
 * as it is opened, and be close-on-exec afterwards.
 */
#include <fcntl.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <unistd.h>

extern void _landin_host_initialize_arguments(int argc, char **argv,
                                              char **envp);
extern int32_t l_controller(void);

static char program[] = "freebsd-pseudo-terminal-closed-on-exec";
static char *arguments[] = { program, 0 };
static int asked = -1;

int posix_openpt(int flags)
{
    asked = flags;
    return (int)syscall(SYS_posix_openpt, flags);
}

int main(void)
{
    _landin_host_initialize_arguments(1, arguments, 0);
    int controller = l_controller();
    if (controller < 0)
        return 1;
    if (asked < 0 || (asked & O_CLOEXEC) == 0)
        return 2;
    int flags = fcntl(controller, F_GETFD);
    if (flags < 0 || (flags & FD_CLOEXEC) == 0)
        return 3;
    return 42;
}
