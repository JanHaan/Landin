/* `refine fmt` writes a formatted source into the file it read (D358).
 *
 * The file keeps its inode, so every attribute it carries stays with it:
 * owner, group, extended attributes and ACLs, including those the caller
 * cannot list, such as Linux's trusted.* namespace, and every other name a
 * hard link gives it.  Writing in place is not atomic, so before the first
 * byte changes the original bytes are copied into a sibling file and
 * synced, together with the directory that names it.  A write that fails
 * puts the original bytes back and removes the copy; one that cannot even
 * do that leaves the copy and says where it is.  A crash during the write
 * leaves the copy beside the file under the name a refusal would give.
 *
 * Writing is what a process without privilege may do to a file it may
 * write, so the replacement needs none.  What writing itself can take away
 * is checked first: set-user-ID and set-group-ID bits, which the system
 * clears on a write and which only the owner, in the file's group for the
 * second, can set again; and on Linux a file's capabilities, which a write
 * removes and which only a privileged process can give back.
 *
 * Every refusal writes its cause into the caller's buffer.
 */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/xattr.h>
#endif

static void say(char *reason, size_t room, const char *format, ...)
{
    va_list arguments;
    if (room == 0)
        return;
    va_start(arguments, format);
    vsnprintf(reason, room, format, arguments);
    va_end(arguments);
}

static int write_all(int fd, const char *data, size_t size)
{
    off_t at = 0;
    while (size != 0) {
        ssize_t written = pwrite(fd, data, size, at);
        if (written < 0 && errno == EINTR)
            continue;
        if (written < 0)
            return -1;
        if (written == 0) {
            errno = EIO;
            return -1;
        }
        data += written;
        at += written;
        size -= (size_t)written;
    }
    return 0;
}

/* Where the data lasts.  Darwin's fsync leaves it in the drive's cache. */
static int sync_file(int fd)
{
#ifdef __APPLE__
    if (fcntl(fd, F_FULLFSYNC) == 0)
        return 0;
#endif
    return fsync(fd);
}

/* The whole content, read back through the descriptor that will be written,
 * so the copy is of the bytes this file holds now. */
static char *read_all(int fd, size_t *length)
{
    size_t room = 4096, used = 0;
    char *bytes = malloc(room);
    if (!bytes)
        return NULL;
    for (;;) {
        if (used == room) {
            char *wider;
            if (room > SIZE_MAX / 2) {
                free(bytes);
                errno = EFBIG;
                return NULL;
            }
            wider = realloc(bytes, room * 2);
            if (!wider) {
                free(bytes);
                return NULL;
            }
            bytes = wider;
            room *= 2;
        }
        ssize_t got = pread(fd, bytes + used, room - used, (off_t)used);
        if (got < 0 && errno == EINTR)
            continue;
        if (got < 0) {
            int error = errno;
            free(bytes);
            errno = error;
            return NULL;
        }
        if (got == 0)
            break;
        used += (size_t)got;
    }
    *length = used;
    return bytes;
}

static int in_group(gid_t group)
{
    if (getegid() == group)
        return 1;
    int count = getgroups(0, NULL);
    if (count <= 0)
        return 0;
    gid_t *groups = malloc((size_t)count * sizeof *groups);
    if (!groups)
        return 0;
    count = getgroups(count, groups);
    int found = 0;
    for (int index = 0; index < count; ++index)
        if (groups[index] == group)
            found = 1;
    free(groups);
    return found;
}

/* The directory that names the copy, synced so that the copy's name lasts
 * before the original's bytes begin to change.  A file system that cannot
 * sync a directory says EINVAL, and there is then nothing more to do. */
static int sync_directory(const char *target)
{
    const char *slash = strrchr(target, '/');
    size_t length = slash == NULL ? 0 : (size_t)(slash - target);
    char *directory = malloc(length + 2);
    if (!directory)
        return -1;
    if (length == 0) {
        directory[0] = slash == NULL ? '.' : '/';
        directory[1] = '\0';
    } else {
        memcpy(directory, target, length);
        directory[length] = '\0';
    }
    int fd = open(directory, O_RDONLY);
    free(directory);
    if (fd < 0)
        return -1;
    int result = fsync(fd);
    int error = errno;
    close(fd);
    if (result != 0 && error == EINVAL)
        return 0;
    errno = error;
    return result;
}

int landin_replace_existing_file(const char *path, const char *data,
                                 size_t size, char *reason, size_t room)
{
    static const char suffix[] = ".fmt-original-XXXXXX";
    char *target = NULL;
    char *copy = NULL;
    char *original = NULL;
    size_t original_size = 0;
    struct stat before;
    struct stat now;
    int fd = -1;
    int kept = -1;
    int result = -1;

    say(reason, room, "%s", "");
    target = realpath(path, NULL);
    if (!target) {
        say(reason, room, "cannot find it: %s", strerror(errno));
        goto done;
    }
    fd = open(target, O_RDWR | O_NOFOLLOW);
    if (fd < 0) {
        int error = errno;
        if (stat(target, &now) == 0 && !S_ISREG(now.st_mode))
            say(reason, room, "it is not an ordinary file");
        else if (stat(target, &now) == 0 && (now.st_mode & 0222) == 0)
            say(reason, room, "it is read-only");
        else
            say(reason, room, "cannot open it to write: %s", strerror(error));
        goto done;
    }
    if (fstat(fd, &before) != 0) {
        say(reason, room, "cannot read its status: %s", strerror(errno));
        goto done;
    }
    if (!S_ISREG(before.st_mode)) {
        say(reason, room, "it is not an ordinary file");
        goto done;
    }
    /* A process its permissions do not stop, as root, still leaves alone a
     * file nobody may write. */
    if ((before.st_mode & 0222) == 0) {
        say(reason, room, "it is read-only");
        goto done;
    }
    if ((before.st_mode & (S_ISUID | S_ISGID)) != 0
        && before.st_uid != geteuid()) {
        say(reason, room, "writing clears its set-user-ID and set-group-ID"
            " bits, and only its owner can set them again");
        goto done;
    }
    if ((before.st_mode & S_ISGID) != 0 && !in_group(before.st_gid)) {
        say(reason, room, "writing clears its set-group-ID bit, which only"
            " a member of its group can set again");
        goto done;
    }
#ifdef __linux__
    if (fgetxattr(fd, "security.capability", NULL, 0) >= 0) {
        say(reason, room, "it carries file capabilities, which writing"
            " removes and only a privileged process can give back");
        goto done;
    }
    if (errno != ENODATA && errno != ENOTSUP) {
        say(reason, room, "cannot learn whether it carries file"
            " capabilities: %s", strerror(errno));
        goto done;
    }
#endif

    original = read_all(fd, &original_size);
    if (!original) {
        say(reason, room, "cannot read it: %s", strerror(errno));
        goto done;
    }

    size_t length = strlen(target);
    if (length > SIZE_MAX - sizeof suffix) {
        say(reason, room, "its path is too long");
        goto done;
    }
    copy = malloc(length + sizeof suffix);
    if (!copy) {
        say(reason, room, "no memory for its copy's name");
        goto done;
    }
    memcpy(copy, target, length);
    memcpy(copy + length, suffix, sizeof suffix);
    kept = mkstemp(copy);
    if (kept < 0) {
        say(reason, room, "cannot keep a copy of it in its directory: %s",
            strerror(errno));
        free(copy);
        copy = NULL;
        goto done;
    }
    if (write_all(kept, original, original_size) != 0
        || sync_file(kept) != 0) {
        say(reason, room, "cannot keep a copy of it in its directory: %s",
            strerror(errno));
        goto done;
    }
    if (close(kept) != 0) {
        kept = -1;
        say(reason, room, "cannot keep a copy of it in its directory: %s",
            strerror(errno));
        goto done;
    }
    kept = -1;
    if (sync_directory(target) != 0) {
        say(reason, room, "cannot sync its directory: %s", strerror(errno));
        goto done;
    }

    /* An editor that saved the file by renaming another onto it while this
     * one was formatted has a new file there, which this must not miss. */
    if (stat(target, &now) != 0 || now.st_dev != before.st_dev
        || now.st_ino != before.st_ino) {
        say(reason, room, "it was replaced while it was being formatted");
        goto done;
    }

    if (write_all(fd, data, size) != 0 || ftruncate(fd, (off_t)size) != 0
        || sync_file(fd) != 0) {
        int error = errno;
        if (write_all(fd, original, original_size) == 0
            && ftruncate(fd, (off_t)original_size) == 0
            && sync_file(fd) == 0) {
            say(reason, room, "writing it failed: %s; its bytes are as they"
                " were", strerror(error));
        } else {
            say(reason, room, "writing it failed: %s; its original bytes are"
                " kept in %s", strerror(error), copy);
            free(copy);
            copy = NULL;
        }
        goto done;
    }

    /* The bits a write cleared, set again; set-group-ID was checked to be
     * the caller's to set, and the result is read back rather than trusted,
     * because chmod may succeed and still clear it. */
    if (fstat(fd, &now) != 0) {
        say(reason, room, "it is formatted, but its mode cannot be read: %s",
            strerror(errno));
        goto done;
    }
    if ((now.st_mode & 07777) != (before.st_mode & 07777)
        && (fchmod(fd, before.st_mode & 07777) != 0 || fstat(fd, &now) != 0
            || (now.st_mode & 07777) != (before.st_mode & 07777))) {
        say(reason, room, "it is formatted, but its mode %04o could not be"
            " restored", (unsigned)(before.st_mode & 07777));
        goto done;
    }
    if ((before.st_mode & (S_ISUID | S_ISGID)) != 0 && sync_file(fd) != 0) {
        say(reason, room, "it is formatted, but its restored mode cannot be"
            " synced: %s", strerror(errno));
        goto done;
    }
    result = 0;

done:
    if (kept >= 0)
        close(kept);
    if (fd >= 0)
        close(fd);
    if (copy) {
        if (unlink(copy) != 0 && result == 0) {
            say(reason, room, "it is formatted, but its copy %s could not be"
                " removed: %s", copy, strerror(errno));
            result = -1;
        }
        free(copy);
    }
    free(original);
    free(target);
    return result;
}
