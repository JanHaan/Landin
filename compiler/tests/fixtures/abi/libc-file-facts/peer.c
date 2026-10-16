/*
 * Holds the facts platform/libc and platform/linux keep for the rest of
 * the file system, terminals and the account databases to this system's
 * own C headers, and what platform/posix reads and writes to what C reads
 * of the same file and account.
 */
#define _GNU_SOURCE 1
#define _DARWIN_C_SOURCE 1
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__linux__)
#include <asm/termbits.h>
#else
#include <termios.h>
#endif

/* What every system's C library says, in platform/libc's order. */
static const int64_t shared[] = {
    LOCK_SH, LOCK_EX, LOCK_NB, LOCK_UN,
    F_GETLK, F_SETLK, F_SETLKW, F_RDLCK, F_WRLCK, F_UNLCK, SEEK_SET,
    O_NOCTTY, AT_SYMLINK_FOLLOW,
    sizeof(struct flock), offsetof(struct flock, l_type),
    offsetof(struct flock, l_whence), offsetof(struct flock, l_start),
    offsetof(struct flock, l_len), offsetof(struct flock, l_pid),
    sizeof(struct winsize), offsetof(struct winsize, ws_col),
    sizeof(struct passwd), offsetof(struct passwd, pw_name),
    offsetof(struct passwd, pw_passwd), offsetof(struct passwd, pw_uid),
    offsetof(struct passwd, pw_gid), offsetof(struct passwd, pw_gecos),
    offsetof(struct passwd, pw_dir), offsetof(struct passwd, pw_shell),
    sizeof(struct group), offsetof(struct group, gr_name),
    offsetof(struct group, gr_passwd), offsetof(struct group, gr_gid),
    offsetof(struct group, gr_mem),
    TCSANOW, TCSADRAIN, TCSAFLUSH,
};

/* A terminal's record and its modes: the kernel's on Linux, which
   platform/linux reads with ioctl, and the C library's elsewhere. */
static const int64_t terminal[] = {
    sizeof(struct termios), offsetof(struct termios, c_oflag),
    offsetof(struct termios, c_cflag), offsetof(struct termios, c_lflag),
    offsetof(struct termios, c_cc), NCCS, VMIN, VTIME,
    IGNBRK, BRKINT, PARMRK, ISTRIP, INLCR, IGNCR, ICRNL, IXON, OPOST,
    CSIZE, CS8, PARENB, ECHO, ECHONL, ICANON, ISIG, IEXTEN,
    TIOCGWINSZ, TIOCSWINSZ,
};

#if defined(__linux__)
/* The kernel's own requests and flags, which platform/linux makes. */
static const int64_t kernel[] = {
    TCGETS, TCSETS, TCSETSW, TCSETSF, TIOCSPTLCK, TIOCGPTPEER, TIOCGPTN,
    offsetof(struct termios, c_line), STATX_BASIC_STATS, AT_EMPTY_PATH,
};
#endif

int64_t c_shared(int32_t index)
{
    if (index < 0 || (size_t)index >= sizeof shared / sizeof shared[0])
        return -1;
    return shared[index];
}

int64_t c_terminal(int32_t index)
{
    if (index < 0 || (size_t)index >= sizeof terminal / sizeof terminal[0])
        return -1;
    return terminal[index];
}

#if defined(__linux__)
int64_t c_kernel(int32_t index)
{
    if (index < 0 || (size_t)index >= sizeof kernel / sizeof kernel[0])
        return -1;
    return kernel[index];
}
#endif

#if defined(__APPLE__)
int32_t c_full_sync(void) { return F_FULLFSYNC; }
#endif

/* What C's stat reads of the file platform/posix made: its permission
   bits, size, owner, links and times. */
int32_t c_status_agrees(const char *path, uint32_t permissions, int64_t size,
                        uint32_t user, uint64_t links, int64_t seconds,
                        int64_t nanoseconds)
{
    struct stat found;
    if (lstat(path, &found) != 0)
        return 0;
#if defined(__APPLE__)
    struct timespec modified = found.st_mtimespec;
#else
    struct timespec modified = found.st_mtim;
#endif
    return (found.st_mode & 07777) == permissions && found.st_size == size
           && found.st_uid == user && (uint64_t)found.st_nlink == links
           && modified.tv_sec == seconds && modified.tv_nsec == nanoseconds;
}

/* What C reads of a symbolic link platform/posix made. */
int32_t c_link_agrees(const char *path, const char *target)
{
    char room[256];
    ssize_t count = readlink(path, room, sizeof room - 1);
    if (count < 0)
        return 0;
    room[count] = 0;
    return strcmp(room, target) == 0;
}

/* What the C library's own lookup gives of user zero's account. */
int32_t c_account_agrees(const char *name, const char *home, const char *shell,
                         uint32_t group)
{
    struct passwd record;
    struct passwd *found = NULL;
    char buffer[4096];
    if (getpwuid_r(0, &record, buffer, sizeof buffer, &found) != 0 || !found)
        return 0;
    return strcmp(found->pw_name, name) == 0
           && strcmp(found->pw_dir, home) == 0
           && strcmp(found->pw_shell, shell) == 0 && found->pw_gid == group;
}

/* What the C library's own lookup gives of group zero. */
int32_t c_group_agrees(const char *name, uint64_t members)
{
    struct group record;
    struct group *found = NULL;
    char buffer[4096];
    if (getgrgid_r(0, &record, buffer, sizeof buffer, &found) != 0 || !found)
        return 0;
    uint64_t count = 0;
    for (char **member = found->gr_mem; *member; member++)
        if (**member)
            count++;
    return strcmp(found->gr_name, name) == 0 && count == members;
}
