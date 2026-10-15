/*
 * Holds the facts platform/libc and platform/linux keep for pipes,
 * spawning and waiting to this system's own C headers.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

extern int32_t l_o_cloexec(void);
extern int32_t l_f_setfd(void);
extern int32_t l_fd_cloexec(void);
extern int32_t l_f_dupfd_cloexec(void);
#if defined(__linux__)
extern bool l_linux_agrees(void);
extern int64_t l_sigchld(void);
extern uint32_t l_close_range_cloexec(void);
#else
extern size_t l_spawn_object_size(void);
#endif
#if defined(__APPLE__)
extern int16_t l_cloexec_default(void);
#endif

int main(void)
{
    if (l_o_cloexec() != O_CLOEXEC)
        return 1;
    if (l_f_setfd() != F_SETFD || l_fd_cloexec() != FD_CLOEXEC)
        return 2;
    if (l_f_dupfd_cloexec() != F_DUPFD_CLOEXEC)
        return 3;
#if defined(__linux__)
    if (!l_linux_agrees())
        return 4;
    if (l_sigchld() != SIGCHLD)
        return 5;
    /* CLOSE_RANGE_CLOEXEC, (1U << 2) in linux/close_range.h, which not
       every C library's headers carry. */
    if (l_close_range_cloexec() != (1U << 2))
        return 6;
#else
    if (l_spawn_object_size() != sizeof(posix_spawn_file_actions_t)
        || l_spawn_object_size() != sizeof(posix_spawnattr_t))
        return 7;
#endif
#if defined(__APPLE__)
    if (l_cloexec_default() != POSIX_SPAWN_CLOEXEC_DEFAULT)
        return 8;
#endif
    return 42;
}
