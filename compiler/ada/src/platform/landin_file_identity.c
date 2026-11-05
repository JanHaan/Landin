/* Host-only identity adapter. No target facts, namespace mutations or
   guessed lexical resolution.  Return 0 only for proven distinct paths,
   1 for aliases, and -1 when the host cannot establish identity. */
#ifdef __linux__
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#endif
#ifdef __APPLE__
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#endif
#include <errno.h>
#include <pthread.h>
#include <dirent.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include "landin_owned_directory.h"
#ifdef __APPLE__
#include <sys/mount.h>
#endif
#ifdef __linux__
#include <linux/fs.h>
#include <linux/magic.h>
#include <sys/ioctl.h>
#include <sys/vfs.h>
#endif

int landin_same_file(const char *left, const char *right);
int landin_same_existing_file(const char *left, const char *right);
int landin_existing_file_key(const char *path, char *key, size_t length);
int landin_overlaps_any(const char *left, const char *const *rights,
                        size_t count);
int landin_names_alias(const char *left_name, const char *right_name,
                       int rules);
int landin_directory_access_denied(const char *path);
int landin_private_directory(const char *prefix, char *path,
                             size_t capacity);
int landin_remove_tree(const char *path);
int landin_private_parent(const char *, char **, char **);

/* A failed Ada.Directories.Exists can mean either absence or a parent that
   refused traversal. Probe only that failure path, preserving the host's
   errno rather than guessing from an empty listing. */
int landin_directory_access_denied(const char *path)
{
    DIR *directory = opendir(path);
    int denied;

    if (directory) {
        closedir(directory);
        return 0;
    }
    denied = errno == EACCES || errno == EPERM;
    return denied;
}

int landin_file_identity(const char *path, uint64_t *device, uint64_t *inode)
{
    struct stat object;
    if (stat(path, &object) != 0)
        return 0;
    *device = (uint64_t)object.st_dev;
    *inode = (uint64_t)object.st_ino;
    return 1;
}

/* A directory lock has no replaceable lock-file inode. All cooperating
   compiler invocations naming a destination in this directory serialize
   backup, tool run, verification and recovery. The descriptor closes on
   process death. */
int landin_lock_output_directory(const char *path)
{
    char copy[PATH_MAX], resolved[PATH_MAX], *slash;
    const char *parent;
    int fd;
    if (!*path || strlen(path) >= sizeof(copy))
        return -1;
    strcpy(copy, path);
    slash = strrchr(copy, '/');
    if (slash) {
        *slash = '\0';
        parent = slash == copy ? "/" : copy;
    } else {
        parent = ".";
    }
    if (!realpath(parent, resolved))
        return -1;
    fd = open(resolved, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    if (flock(fd, LOCK_EX) != 0) {
        /* In particular EINTR must reach normal cancellation unwinding. */
        close(fd);
        return -1;
    }
    return fd;
}

void landin_unlock_output_directory(int fd)
{
    if (fd >= 0)
        close(fd);
}

/* link creates the destination only if no entry is present, including a
   dangling symlink. Both names are beside one another, so no cross-device
   move is needed. Return 1 on success, 0 for missing source, -1 otherwise. */
int landin_move_file_noreplace(const char *from, const char *to)
{
    struct stat source;
    if (lstat(from, &source) != 0)
        return errno == ENOENT ? 0 : -1;
    if (S_ISDIR(source.st_mode))
        return -1;
    if (link(from, to) != 0)
        return -1;
    if (unlink(from) != 0) {
        unlink(to);
        return -1;
    }
    return 1;
}

int landin_unlink_file(const char *path)
{
    char *directory = NULL, *name = NULL;
    int parent = landin_private_parent(path, &directory, &name);
    if (parent != -2) {
        int result, error;
        if (parent < 0) return -1;
        result = unlinkat(parent, name, 0); error = errno;
        close(parent); free(directory); free(name); errno = error;
        return result == 0 ? 1 : (errno == ENOENT ? 0 : -1);
    }
    if (unlink(path) == 0)
        return 1;
    return errno == ENOENT ? 0 : -1;
}

/* Roots made through the private-directory API retain their actual parent
   and root descriptors until cleanup. Finished records remain tombstones so
   a repeated cleanup cannot mistake a replacement for an unregistered tree. */
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
static int landin_private_directory_locked(const char *prefix, char *path,
    size_t capacity);
static int landin_remove_tree_locked(const char *path);
static int landin_private_parent_locked(const char *path, char **parent_path,
    char **name);
static int landin_private_open_locked(const char *path, int flags, mode_t mode);
static int landin_private_read_descriptor_locked(const char *path);
static int landin_private_path_current_locked(const char *path);
static int landin_private_mkdir_locked(const char *path);
static int landin_private_write_locked(const char *path, const char *bytes, size_t size);
static int landin_private_argument_directory_locked(const char *argument);
static int landin_private_rebase_argument_locked(const char *argument, int directory,
    char *result, size_t room);

struct landin_private_root {
    struct landin_owned_directory owned;
    struct landin_private_root *next;
};
static struct landin_private_root *landin_private_roots;
static _Thread_local char landin_private_reason[PATH_MAX * 2 + 1024];
void landin_private_directory_set_hook(void (*hook)(const char *, const char *))
{ landin_owned_hook = hook; }
const char *landin_remove_tree_reason(void) { return landin_private_reason; }
static int landin_private_directory_locked(const char *prefix, char *path,
    size_t capacity)
{
    struct landin_private_root *root = calloc(1, sizeof *root);
    landin_private_reason[0] = '\0';
    if (!root) return -1;
    if (landin_owned_create(prefix, &root->owned) != 0) { free(root); return -1; }
    if (strlen(root->owned.path) >= capacity) {
        landin_owned_remove(&root->owned);
        close(root->owned.parent); free(root); errno = ENAMETOOLONG; return -1;
    }
    strcpy(path, root->owned.path);
    root->next = landin_private_roots; landin_private_roots = root;
    if (landin_owned_hook) landin_owned_hook("created", path);
    return 0;
}

static int landin_remove_tree_locked(const char *path)
{
    struct landin_private_root *root;
    landin_private_reason[0] = '\0';
    for (root = landin_private_roots; root; root = root->next) {
        if (!strcmp(root->owned.path, path)) {
            int result = landin_owned_remove(&root->owned);
            if (result < 0) {
                snprintf(landin_private_reason, sizeof landin_private_reason,
                          "%s", root->owned.reason);
            }
            return result;
        }
    }
    /* Explicit caller-owned fixture work trees predate this API. Live
       compiler scratch roots always take the registered branch above. */
    {
        int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0) return errno == ENOENT ? 0 : -1;
        if (landin_owned_empty(fd) != 0) return -1;
        return rmdir(path) == 0 ? 1 : -1;
    }
}

static struct landin_private_root *landin_private_match(const char *path,
                                                        const char **relative)
{
    struct landin_private_root *root;
    for (root = landin_private_roots; root; root = root->next) {
        size_t n = strlen(root->owned.path);
        if (!strncmp(path, root->owned.path, n)
            && (path[n] == '/' || path[n] == '\0')) {
            *relative = path + n;
            if (**relative == '/') ++*relative;
            return root;
        }
    }
    return NULL;
}
/* -2 means this is not a registered private namespace. A registered but
   finished/retained namespace never falls back to a new public pathname. */
static int landin_private_parent_locked(const char *path, char **parent_path,
    char **name)
{
    const char *relative;
    struct landin_private_root *root = landin_private_match(path, &relative);
    char *copy, *save = NULL, *part, *next;
    int fd;
    if (!root) return -2;
    if (root->owned.finished || root->owned.retained || !*relative) {
        errno = ESTALE; return -1;
    }
    fd = fcntl(root->owned.root, F_DUPFD_CLOEXEC, 3);
    copy = strdup(relative);
    if (fd < 0 || !copy) { if (fd >= 0) close(fd); free(copy); return -1; }
    part = strtok_r(copy, "/", &save);
    while (part) {
        next = strtok_r(NULL, "/", &save);
        if (!strcmp(part, ".") || !strcmp(part, "..")) {
            close(fd); free(copy); errno = EINVAL; return -1;
        }
        if (!next) break;
        int inner = openat(fd, part,
                           O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd); fd = inner;
        if (fd < 0) { free(copy); return -1; }
        part = next;
    }
    if (!part) { close(fd); free(copy); errno = EINVAL; return -1; }
    *name = strdup(part);
    *parent_path = strdup(path);
    if (!*name || !*parent_path) {
        free(*name); free(*parent_path); close(fd); free(copy); return -1;
    }
    char *slash = strrchr(*parent_path, '/');
    if (slash) *slash = '\0';
    free(copy);
    return fd;
}
static int landin_private_open_locked(const char *path, int flags, mode_t mode)
{
    char *parent_path = NULL, *name = NULL;
    int parent = landin_private_parent_locked(path, &parent_path, &name), result, error;
    if (parent < 0) return parent;
    result = openat(parent, name, flags | O_CLOEXEC | O_NOFOLLOW, mode);
    error = errno;
    close(parent); free(parent_path); free(name); errno = error;
    return result;
}
static int landin_private_read_descriptor_locked(const char *path)
{ return landin_private_open_locked(path, O_RDONLY | O_NONBLOCK, 0); }
static int landin_private_path_current_locked(const char *path)
{
    const char *relative;
    struct landin_private_root *root = landin_private_match(path, &relative);
    struct stat current;
    if (!root) return 1;
    return !root->owned.finished && !root->owned.retained
        && stat(root->owned.path, &current) == 0
        && landin_owned_same(&current, &root->owned.identity);
}
static int landin_private_mkdir_locked(const char *path)
{
    char *parent_path = NULL, *name = NULL;
    const char *relative;
    struct landin_private_root *root = landin_private_match(path, &relative);
    int parent, result, error;
    if (!root) return -2;
    if (!*relative && !root->owned.finished && !root->owned.retained) return 0;
    parent = landin_private_parent_locked(path, &parent_path, &name);
    if (parent < 0) return -1;
    result = mkdirat(parent, name, 0700);
    if (result != 0 && errno == EEXIST) {
        int fd = openat(parent, name,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (fd >= 0) { close(fd); result = 0; }
    }
    error = errno;
    close(parent); free(parent_path); free(name); errno = error;
    return result;
}
static int landin_private_write_locked(const char *path, const char *bytes, size_t size)
{
    int fd = landin_private_open_locked(path, O_WRONLY | O_CREAT, 0600), result;
    size_t used = 0;
    struct stat st;
    if (fd < 0) return fd;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd); errno = EINVAL; return -1;
    }
    while (used < size) {
        ssize_t count = write(fd, bytes + used, size - used);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(fd); return -1; }
        used += (size_t)count;
    }
    result = ftruncate(fd, (off_t)size);
    if (result == 0) result = fsync(fd);
    close(fd); return result;
}
static int landin_private_argument_directory_locked(const char *argument)
{
    struct landin_private_root *root;
    for (root = landin_private_roots; root; root = root->next) {
        const char *at = strstr(argument, root->owned.path);
        size_t n = strlen(root->owned.path);
        if (at && (at[n] == '/' || at[n] == '\0')) {
            if (root->owned.finished || root->owned.retained) {
                errno = ESTALE; return -2;
            }
            return fcntl(root->owned.root, F_DUPFD_CLOEXEC, 3);
        }
    }
    return -1;
}
static int landin_private_rebase_argument_locked(const char *argument, int directory,
                                    char *result, size_t room)
{
    struct landin_private_root *root;
    struct stat selected;
    if (fstat(directory, &selected) != 0) return -1;
    for (root = landin_private_roots; root; root = root->next) {
        const char *at = strstr(argument, root->owned.path);
        size_t n = strlen(root->owned.path), before;
        if (!at || (at[n] && at[n] != '/')) continue;
        if (!landin_owned_same(&selected, &root->owned.identity)
            || root->owned.finished || root->owned.retained) {
            errno = EXDEV; return -1;
        }
        before = (size_t)(at - argument);
        if (before + 1 + strlen(at + n) + 1 > room) {
            errno = ENAMETOOLONG; return -1;
        }
        memcpy(result, argument, before); result[before] = '.';
        strcpy(result + before + 1, at + n);
        return 0;
    }
    if (strlen(argument) >= room) { errno = ENAMETOOLONG; return -1; }
    strcpy(result, argument); return 0;
}

struct destination {
    struct stat object;
    struct stat parent;
    int exists;
    char directory[PATH_MAX];
    char name[PATH_MAX];
};

/* Resolve the actual parent, not a lexical collapse of the entire path.
   A dangling final symlink still denotes its target when opened for writing.
   Missing intermediate directories and loops are indeterminate, not distinct.
   The fixed host PATH_MAX bounds fail closed rather than truncating names. */
static int destination(const char *path, struct destination *out, int links)
{
    char copy[PATH_MAX];
    char target[PATH_MAX];
    char joined[PATH_MAX];
    char *slash;
    const char *parent;
    struct stat leaf;
    ssize_t length;
    size_t prefix;

    if (!*path || strlen(path) >= sizeof(copy) || links > 40)
        return -1;
    if (stat(path, &out->object) == 0) {
        out->exists = 1;
        return 0;
    }
    if (errno != ENOENT)
        return -1;
    out->exists = 0;
    strcpy(copy, path);
    slash = strrchr(copy, '/');
    if (slash) {
        strcpy(out->name, slash + 1);
        *slash = '\0';
        parent = slash == copy ? "/" : copy;
    } else {
        strcpy(out->name, copy);
        parent = ".";
    }
    if (!*out->name || !realpath(parent, out->directory)
        || stat(out->directory, &out->parent) != 0
        || !S_ISDIR(out->parent.st_mode))
        return -1;
    if (lstat(path, &leaf) != 0)
        return errno == ENOENT ? 0 : -1;
    if (!S_ISLNK(leaf.st_mode))
        return -1;
    length = readlink(path, target, sizeof(target) - 1);
    if (length < 0 || (size_t)length >= sizeof(target) - 1)
        return -1;
    target[length] = '\0';
    if (target[0] == '/')
        return destination(target, out, links + 1);
    prefix = strlen(out->directory);
    if (prefix + 1 + (size_t)length >= sizeof(joined))
        return -1;
    memcpy(joined, out->directory, prefix);
    joined[prefix] = '/';
    memcpy(joined + prefix + 1, target, (size_t)length + 1);
    return destination(joined, out, links + 1);
}

/* 1: byte-sensitive; 2: ASCII-sensitive, Unicode equivalence unknown;
   0: case-insensitive, Unicode equivalence unknown; -1: unknown filesystem.
   Never infer volume behaviour from the host OS or lowercase a whole path.
   Linux casefold is a directory property, not just a filesystem property. */
static int name_rules(const char *directory)
{
#ifdef __APPLE__
    struct statfs fs;
    long sensitive;

    if (statfs(directory, &fs) != 0
        || (strcmp(fs.f_fstypename, "apfs") != 0
            && strcmp(fs.f_fstypename, "hfs") != 0))
        return -1;
    sensitive = pathconf(directory, _PC_CASE_SENSITIVE);
    return sensitive < 0 ? -1 : sensitive ? 2 : 0;
#elif defined(__linux__)
    struct statfs fs;
    int fd;
    int result = -1;
    int flags;

    fd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    if (fstatfs(fd, &fs) == 0) {
        switch ((unsigned long)fs.f_type) {
        case EXT4_SUPER_MAGIC:
        case F2FS_SUPER_MAGIC:
            if (ioctl(fd, FS_IOC_GETFLAGS, &flags) == 0)
                result = (flags & FS_CASEFOLD_FL) ? 0 : 1;
            break;
        /* These namespaces compare bytes. Overlayfs does not support
           casefolded layers; do not extend this list to remote filesystems
           whose server may apply different name-equivalence rules. */
        case TMPFS_MAGIC:
        case RAMFS_MAGIC:
        case BTRFS_SUPER_MAGIC:
        case OVERLAYFS_SUPER_MAGIC:
            result = 1;
            break;
        default:
            break;
        }
    }
    close(fd);
    return result;
#else
    (void)directory;
    return -1;
#endif
}

/* Whether two names absent from one directory would name one object once
   created there, under name_rules' answer for that directory. Exported so
   the platform suite can hold the unknown-filesystem answers without
   mounting one. Even an unknown filesystem cannot make two ASCII names
   equal that still differ after ASCII case folding: the equivalences that
   exist (case, Unicode forms, vfat short names, NTFS streams, and vfat and
   SMB dropping a trailing dot or space) each need a folded match, a
   non-ASCII byte, a '~' or ':', or such a trailing byte; those stay
   indeterminate. */
int landin_names_alias(const char *left_name, const char *right_name,
                       int rules)
{
    const unsigned char *left = (const unsigned char *)left_name;
    const unsigned char *right = (const unsigned char *)right_name;
    size_t i;

    if (strcmp(left_name, right_name) == 0)
        return 1;
    if (rules == 1)
        return 0;
    /* Host Unicode normalization/folding versions are not a compiler
       table. Without a filesystem proof, non-ASCII missing names remain
       indeterminate (existing leaves are compared by inode above). */
    for (i = 0; left[i]; ++i)
        if (left[i] >= 128)
            return -1;
    for (i = 0; right[i]; ++i)
        if (right[i] >= 128)
            return -1;
    if (rules == 2)
        return 0;
    if (rules < 0) {
        size_t l = strlen(left_name);
        size_t r = strlen(right_name);

        if (l == 0 || r == 0
            || left[l - 1] == '.' || left[l - 1] == ' '
            || right[r - 1] == '.' || right[r - 1] == ' '
            || strpbrk(left_name, "~:") || strpbrk(right_name, "~:"))
            return -1;
    }
    for (i = 0; left[i] && right[i]; ++i) {
        unsigned char l = left[i];
        unsigned char r = right[i];
        if (l >= 'A' && l <= 'Z')
            l = (unsigned char)(l + ('a' - 'A'));
        if (r >= 'A' && r <= 'Z')
            r = (unsigned char)(r + ('a' - 'A'));
        if (l != r)
            return 0;
    }
    if (left[i] != right[i])
        return 0;
    return rules < 0 ? -1 : 1;
}

static int same_name(const struct destination *a, const struct destination *b)
{
    if (strcmp(a->name, b->name) == 0)
        return 1;
    return landin_names_alias(a->name, b->name, name_rules(a->directory));
}

static int destinations_overlap(const struct destination *a,
                                const struct destination *b)
{
    if (a->exists && b->exists)
        return a->object.st_dev == b->object.st_dev
            && a->object.st_ino == b->object.st_ino;
    /* In a stable namespace, an existing and an absent object cannot alias. */
    if (a->exists != b->exists)
        return 0;
    if (a->parent.st_dev != b->parent.st_dev
        || a->parent.st_ino != b->parent.st_ino)
        return 0;
    return same_name(a, b);
}

int landin_same_file(const char *left, const char *right)
{
    struct destination a;
    struct destination b;

    if (destination(left, &a, 0) != 0 || destination(right, &b, 0) != 0)
        return -1;
    return destinations_overlap(&a, &b);
}

/* One preflight destination against the loaded sources. A failed lookup is
   overlap, just as landin_same_file's -1 is at the Ada boundary. */
int landin_overlaps_any(const char *left, const char *const *rights,
                        size_t count)
{
    struct destination a;
    struct destination b;
    size_t i;

    if (count == 0)
        return 0;
    if (destination(left, &a, 0) != 0)
        return 1;
    for (i = 0; i < count; ++i) {
        if (destination(rights[i], &b, 0) != 0
            || destinations_overlap(&a, &b) != 0)
            return 1;
    }
    return 0;
}

/* Input deduplication needs positive existing-object identity. In particular,
   two missing output leaves that overlap do not prove a loaded source alias. */
int landin_same_existing_file(const char *left, const char *right)
{
    struct stat a;
    struct stat b;

    if (stat(left, &a) != 0 || stat(right, &b) != 0)
        return -1;
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

/* One stat per input. The textual form keeps the host's dev_t/ino_t layout
   out of the Ada ABI; a failed lookup yields no key. */
int landin_existing_file_key(const char *path, char *key, size_t length)
{
    struct stat found;
    int written;

    if (stat(path, &found) != 0)
        return -1;
    written = snprintf(key, length, "%jx:%jx",
                       (uintmax_t)found.st_dev, (uintmax_t)found.st_ino);
    return written >= 0 && (size_t)written < length ? 0 : -1;
}

/* Public registry boundaries. No lock spans a child process lifetime. */
int landin_private_directory(const char *prefix, char *path, size_t capacity)
{
    registry_lock();
    int result = landin_private_directory_locked(prefix, path, capacity);
    registry_unlock();
    return result;
}
int landin_remove_tree(const char *path)
{
    registry_lock();
    int result = landin_remove_tree_locked(path);
    registry_unlock();
    return result;
}
int landin_private_parent(const char *path, char **parent_path, char **name)
{
    registry_lock();
    int result = landin_private_parent_locked(path, parent_path, name);
    registry_unlock();
    return result;
}
int landin_private_open(const char *path, int flags, mode_t mode)
{
    registry_lock();
    int result = landin_private_open_locked(path, flags, mode);
    registry_unlock();
    return result;
}
int landin_private_read_descriptor(const char *path)
{
    registry_lock();
    int result = landin_private_read_descriptor_locked(path);
    registry_unlock();
    return result;
}
int landin_private_path_current(const char *path)
{
    registry_lock();
    int result = landin_private_path_current_locked(path);
    registry_unlock();
    return result;
}
int landin_private_mkdir(const char *path)
{
    registry_lock();
    int result = landin_private_mkdir_locked(path);
    registry_unlock();
    return result;
}
int landin_private_write(const char *path, const char *bytes, size_t size)
{
    registry_lock();
    int result = landin_private_write_locked(path, bytes, size);
    registry_unlock();
    return result;
}
int landin_private_argument_directory(const char *argument)
{
    registry_lock();
    int result = landin_private_argument_directory_locked(argument);
    registry_unlock();
    return result;
}
int landin_private_rebase_argument(const char *argument, int directory, char *result,
    size_t room)
{
    registry_lock();
    int status = landin_private_rebase_argument_locked(argument, directory, result,
    room);
    registry_unlock();
    return status;
}
