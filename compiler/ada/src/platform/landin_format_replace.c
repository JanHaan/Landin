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
#include "landin_publication.h"
#include <errno.h>
#include <pthread.h>
#include <fcntl.h>
#include <limits.h>
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
static int landin_open_update_locked(const char *path, char **bytes, size_t *size,
    int *token, char *reason, size_t room);
static int landin_update_identity_locked(int token, uint64_t *device, uint64_t *inode);
static void landin_close_update_locked(int token);
static int landin_replace_update_locked(int token, const char *data, size_t size,
    char *reason, size_t room);

struct update_lease {
    int token, fd, parent, write_error;
    char *target, *name, *original;
    size_t original_size;
    struct stat before;
    struct update_lease *next;
};
static struct update_lease *leases;
static int next_lease = 1;
extern int landin_cancellation_requested(void);
extern void landin_cancellation_hold(void);
extern void landin_cancellation_release(void);
static struct update_lease *find_lease(int token)
{
    struct update_lease *lease;
    for (lease = leases; lease; lease = lease->next)
        if (lease->token == token) return lease;
    return NULL;
}
static int landin_open_update_locked(const char *path, char **bytes, size_t *size,
                       int *token, char *reason, size_t room)
{
    struct update_lease *lease = calloc(1, sizeof *lease);
    *bytes = NULL; *token = 0;
    say(reason, room, "%s", "");
    if (!lease) goto fail;
    lease->fd = -1; lease->parent = -1;
    landin_publication_notify("update-before-read", path);
    lease->target = realpath(path, NULL);
    if (!lease->target) goto fail;
    char *directory = strdup(lease->target);
    if (!directory) goto fail;
    char *slash = strrchr(directory, '/');
    lease->name = slash ? strdup(slash + 1) : NULL;
    if (!lease->name) { free(directory); goto fail; }
    if (slash == directory) slash[1] = 0; else *slash = 0;
    lease->parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    free(directory);
    if (lease->parent < 0) goto fail;
    lease->fd = openat(lease->parent, lease->name,
                       O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (lease->fd < 0 && (errno == EACCES || errno == EPERM || errno == EROFS)) {
        /* Read the actual source even when writing is refused. This lease
           never reacquires write access; Replace reports the write refusal. */
        lease->write_error = errno;
        lease->fd = openat(lease->parent, lease->name,
                           O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    }
    if (lease->fd < 0 || fstat(lease->fd, &lease->before) != 0) goto fail;
    if (!S_ISREG(lease->before.st_mode)) { errno = EINVAL; goto fail; }
    lease->original = read_all(lease->fd, &lease->original_size);
    if (!lease->original) goto fail;
    *bytes = malloc(lease->original_size ? lease->original_size : 1);
    if (!*bytes) goto fail;
    memcpy(*bytes, lease->original, lease->original_size);
    *size = lease->original_size;
    lease->token = next_lease++; *token = lease->token;
    lease->next = leases; leases = lease;
    landin_publication_notify("update-read", lease->target);
    return 0;
fail:
    {
        int error = errno;
        say(reason, room, "cannot read it for updating: %s; use fmt --stdout", strerror(error));
        if (lease) {
            if (lease->fd >= 0) close(lease->fd);
            if (lease->parent >= 0) close(lease->parent);
            free(lease->target); free(lease->name); free(lease->original); free(lease);
        }
        return error == ENOENT ? 1 : -1;
    }
}
static int landin_update_identity_locked(int token, uint64_t *device, uint64_t *inode)
{
    struct update_lease *lease = find_lease(token);
    if (!lease) return -1;
    *device = lease->before.st_dev; *inode = lease->before.st_ino;
    return 0;
}
static void landin_close_update_locked(int token)
{
    struct update_lease **at = &leases;
    while (*at) {
        struct update_lease *lease = *at;
        if (lease->token == token) {
            *at = lease->next;
            close(lease->fd); close(lease->parent);
            free(lease->target); free(lease->name); free(lease->original);
            free(lease); return;
        }
        at = &lease->next;
    }
}

static void describe_copy(const struct update_lease *lease, const char *entry,
                           char *out, size_t room)
{
    const char *slash = strrchr(lease->target, '/');
    size_t length = slash ? (size_t)(slash - lease->target) : 0;
    char *directory = malloc(length + 2);
    if (!directory) {
        say(out, room, "current directory path unavailable; recovery entry %s; original directory could not be described", entry);
        return;
    }
    if (!length) { directory[0] = '/'; directory[1] = 0; }
    else { memcpy(directory, lease->target, length); directory[length] = 0; }
    (void)landin_publication_describe_entry
        (lease->parent, directory, entry, out, room);
    free(directory);
}

static int landin_replace_update_locked(int token, const char *data,
                          size_t size, char *reason, size_t room)

{
    struct update_lease *lease = find_lease(token);
    static unsigned recovery_counter;
    char copy_name[96], copy_location[PATH_MAX + 256];
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
    if (!lease) { say(reason, room, "update lease is closed"); goto done; }
    if (landin_cancellation_requested()) {
        say(reason, room, "formatting interrupted before writing"); goto done;
    }
    target = strdup(lease->target);
    if (!target) goto done;
    fd = dup(lease->fd);
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
    if (before.st_dev != lease->before.st_dev || before.st_ino != lease->before.st_ino) {
        say(reason, room, "the original read object changed; rerun or use fmt --stdout");
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
    if (lease->write_error) {
        say(reason, room, "cannot open it to write: %s; use fmt --stdout",
            strerror(lease->write_error));
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

    if (original_size != lease->original_size
        || memcmp(original, lease->original, original_size)) {
        say(reason, room, "its bytes changed after the original read; rerun or use fmt --stdout");
        goto done;
    }

    size_t length = strlen(target);
    copy = malloc(length + sizeof copy_name + 4);
    if (!copy) { say(reason, room, "no memory for recovery name"); goto done; }
    for (unsigned attempt = 0; attempt < 100; ++attempt) {
        snprintf(copy_name, sizeof copy_name, ".fmt-original-%ld-%u",
                 (long)getpid(), ++recovery_counter);
        kept = openat(lease->parent, copy_name,
                       O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (kept >= 0 || errno != EEXIST) break;
    }
    char *last_slash = strrchr(target, '/');
    snprintf(copy, length + sizeof copy_name + 4, "%.*s/%s",
             (int)(last_slash - target), target, copy_name);
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
    if (fsync(lease->parent) != 0 && errno != EINVAL) {
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

    landin_publication_notify("update-before-write", target);
    if (landin_cancellation_requested()) {
        say(reason, room, "formatting interrupted before writing"); goto done;
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
            describe_copy(lease, copy_name, copy_location, sizeof copy_location);
            say(reason, room, "writing it failed: %s; its original bytes are"
                " kept in %s", strerror(error), copy_location);
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
    landin_publication_notify("update-written", target);
    if (stat(target, &now) != 0 || now.st_dev != before.st_dev
        || now.st_ino != before.st_ino) {
        describe_copy(lease, copy_name, copy_location, sizeof copy_location);
        say(reason, room, "the public name changed during formatting; the original read object was formatted; original bytes retained in %s", copy_location);
        free(copy); copy = NULL;
        goto done;
    }
    result = 0;

done:
    if (kept >= 0)
        close(kept);
    if (fd >= 0)
        close(fd);
    if (copy) {
        if (unlinkat(lease->parent, copy_name, 0) != 0 && result == 0) {
            int error = errno;
            describe_copy(lease, copy_name, copy_location, sizeof copy_location);
            say(reason, room, "it is formatted, but its copy %s could not be"
                " removed: %s", copy_location, strerror(error));
            result = -1;
        }
        free(copy);
    }
    free(original);
    free(target);
    return result;
}

/* Compatibility seam: new callers acquire a lease at their original read. */
static int landin_replace_existing_file_locked(const char *path, const char *data,
                                 size_t size, char *reason, size_t room)
{
    char *bytes;
    size_t length;
    int token;
    if (landin_open_update_locked(path, &bytes, &length, &token, reason, room) != 0)
        return -1;
    free(bytes);
    int result = landin_replace_update_locked(token, data, size, reason, room);
    landin_close_update_locked(token);
    return result;
}

/* Public registry boundaries. No lock spans a child process lifetime. */
int landin_open_update(const char *path, char **bytes, size_t *size, int *token,
    char *reason, size_t room)
{
    registry_lock();
    int result = landin_open_update_locked(path, bytes, size, token, reason, room);
    registry_unlock();
    return result;
}
int landin_update_identity(int token, uint64_t *device, uint64_t *inode)
{
    registry_lock();
    int result = landin_update_identity_locked(token, device, inode);
    registry_unlock();
    return result;
}
void landin_close_update(int token)
{
    registry_lock();
    landin_close_update_locked(token);
    registry_unlock();
}
int landin_replace_update(int token, const char *data, size_t size, char *reason,
    size_t room)
{
    /* The rewrite is the one part of a lease a signal must not cut short:
       reading and formatting hold nothing. */
    landin_cancellation_hold();
    registry_lock();
    int result = landin_replace_update_locked(token, data, size, reason, room);
    registry_unlock();
    landin_cancellation_release();
    return result;
}

int landin_replace_existing_file(const char *path, const char *data,
                                 size_t size, char *reason, size_t room)
{
    landin_cancellation_hold();
    registry_lock();
    int result = landin_replace_existing_file_locked(path, data, size, reason, room);
    registry_unlock();
    landin_cancellation_release();
    return result;
}
