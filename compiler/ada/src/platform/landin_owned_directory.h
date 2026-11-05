#ifndef LANDIN_OWNED_DIRECTORY_H
#define LANDIN_OWNED_DIRECTORY_H
/* Private scratch lifetime shared by process captures and run/bindings roots.
   A parent is selected once. Its later namespace position is not frozen.
   Cleanup captures the actual public entry into a private retirement slot,
   checks it against the retained root, and never empties a replacement root.
   As with publication arenas, hostile same-UID access inside freshly created
   mode-0700 private helpers is outside this contract. */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif

struct landin_owned_directory {
    int parent, root, finished, retained;
    struct stat identity;
    char path[PATH_MAX], parent_path[PATH_MAX], name[NAME_MAX + 1];
    char reason[PATH_MAX * 2 + 1024];
};
/* Test-only: configure while quiescent; callbacks do not reenter their
   enclosing Capture or Private registry. */
static void (*landin_owned_hook)(const char *, const char *);
static int landin_owned_same(const struct stat *a, const struct stat *b)
{ return a->st_dev == b->st_dev && a->st_ino == b->st_ino; }
static int landin_owned_random(char *name, size_t room, const char *prefix)
{
    unsigned char random[12];
    size_t used = 0, i, n = strlen(prefix);
    int fd;
    if (n + 25 > room || strchr(prefix, '/')) { errno = EINVAL; return -1; }
    fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    while (used < sizeof random) {
        ssize_t count = read(fd, random + used, sizeof random - used);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(fd); return -1; }
        used += (size_t)count;
    }
    close(fd);
    memcpy(name, prefix, n);
    for (i = 0; i < sizeof random; ++i)
        snprintf(name + n + 2 * i, room - n - 2 * i, "%02x", random[i]);
    return 0;
}
static int landin_owned_allocate(int parent, const char *parent_path,
                                  const char *prefix,
                                  struct landin_owned_directory *owned)
{
    unsigned attempt;
    int count;
    memset(owned, 0, sizeof *owned);
    owned->root = -1;
    owned->parent = fcntl(parent, F_DUPFD_CLOEXEC, 3);
    if (owned->parent < 0) return -1;
    if (strlen(parent_path) >= sizeof owned->parent_path) {
        errno = ENAMETOOLONG; goto fail;
    }
    strcpy(owned->parent_path, parent_path);
    for (attempt = 0; attempt < 100; ++attempt) {
        if (landin_owned_random(owned->name, sizeof owned->name, prefix) != 0)
            goto fail;
        count = snprintf(owned->path, sizeof owned->path, "%s/%s", parent_path,
                          owned->name);
        if (count < 0 || (size_t)count >= sizeof owned->path) {
            errno = ENAMETOOLONG; goto fail;
        }
        if (mkdirat(owned->parent, owned->name, 0700) == 0) break;
        if (errno != EEXIST) goto fail;
    }
    if (attempt == 100) { errno = EEXIST; goto fail; }
    owned->root = openat(owned->parent, owned->name,
                         O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (owned->root < 0 || fstat(owned->root, &owned->identity) != 0) goto fail;
    return 0;
fail:
    if (owned->root >= 0) close(owned->root);
    close(owned->parent);
    owned->root = owned->parent = -1;
    return -1;
}
static int landin_owned_create(const char *prefix,
                                struct landin_owned_directory *owned)
{
    const char *directory = getenv("TMPDIR");
    int fd, result, error;
    if (!directory || !*directory) directory = "/tmp";
    fd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return -1;
    char *cwd = NULL, *absolute = NULL;
    const char *named = directory;
    if (*directory != '/') {
        cwd = getcwd(NULL, 0);
        if (!cwd) { close(fd); return -1; }
        absolute = malloc(strlen(cwd) + strlen(directory) + 2);
        if (!absolute) { free(cwd); close(fd); return -1; }
        sprintf(absolute, "%s/%s", cwd, directory); named = absolute;
    }
    result = landin_owned_allocate(fd, named, prefix, owned);
    free(cwd); free(absolute);
    error = errno;
    close(fd); errno = error;
    return result;
}
static int landin_owned_empty(int fd)
{
    DIR *listing = fdopendir(fd);
    struct dirent *item;
    struct stat about;
    int failed = 0;
    if (!listing) { close(fd); return -1; }
    rewinddir(listing);
    while (!failed && (errno = 0, item = readdir(listing)) != NULL) {
        if (!strcmp(item->d_name, ".") || !strcmp(item->d_name, "..")) continue;
        if (fstatat(dirfd(listing), item->d_name, &about,
                     AT_SYMLINK_NOFOLLOW) != 0) {
            failed = errno != ENOENT; continue;
        }
        if (S_ISDIR(about.st_mode)) {
            int child = openat(dirfd(listing), item->d_name,
                                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (child < 0 || landin_owned_empty(child) != 0
                || unlinkat(dirfd(listing), item->d_name, AT_REMOVEDIR) != 0)
                failed = 1;
        } else if (unlinkat(dirfd(listing), item->d_name, 0) != 0
                   && errno != ENOENT) failed = 1;
    }
    if (!item && errno) failed = 1;
    closedir(listing);
    return failed ? -1 : 0;
}
static int landin_owned_restore(int from, const char *name, int to,
                                const char *target, mode_t mode)
{
#ifdef __linux__
#ifdef SYS_renameat2
    if (syscall(SYS_renameat2, from, name, to, target, 1U) == 0) return 0;
    if (errno != ENOSYS && errno != EINVAL && errno != EOPNOTSUPP) return -1;
#endif
#endif
#ifdef __APPLE__
    if (renameatx_np(from, name, to, target, RENAME_EXCL) == 0) return 0;
    if (errno != ENOTSUP && errno != EINVAL) return -1;
#endif
    /* linkat is a no-clobber restoration for captured files/links. A
       directory without a host no-replace rename remains named in recovery. */
    if (!S_ISDIR(mode) && linkat(from, name, to, target, 0) == 0)
        return unlinkat(from, name, 0);
    if (S_ISDIR(mode)) errno = ENOTSUP;
    return -1;
}
/* A retained parent may have moved. Only call a spelling current after
   reopening it and comparing identity; portable fallback is explicitly stale. */
static void landin_owned_describe(int directory, const char *last_known,
                                   const char *entry, char *out, size_t room)
{
    char observed[PATH_MAX];
    struct stat pinned, named;
    int valid = fstat(directory, &pinned) == 0, resolved = 0;
#ifdef __linux__
    char descriptor[64];
    snprintf(descriptor, sizeof descriptor, "/proc/self/fd/%d", directory);
    ssize_t size = readlink(descriptor, observed, sizeof observed - 1);
    if (size >= 0 && (size_t)size < sizeof observed - 1) {
        observed[size] = 0; resolved = valid;
    }
#elif defined(__APPLE__)
    resolved = valid && fcntl(directory, F_GETPATH, observed) == 0;
#endif
    if (resolved) {
        int fd = open(observed, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        resolved = fd >= 0 && fstat(fd, &named) == 0
            && landin_owned_same(&named, &pinned);
        if (fd >= 0) close(fd);
    }
    if (resolved) {
        snprintf(out, room, "%s%s%s", observed,
                 *entry && strcmp(observed, "/") ? "/" : "", entry);
    } else if (valid) {
        snprintf(out, room,
                 "last-known spelling %s%s%s (parent device=%ju inode=%ju; current path unavailable; directory may have moved)",
                 last_known, *entry && strcmp(last_known, "/") ? "/" : "",
                 entry, (uintmax_t)pinned.st_dev, (uintmax_t)pinned.st_ino);
    } else {
        snprintf(out, room,
                 "last-known spelling %s/%s (current path and parent identity unavailable)",
                 last_known, entry);
    }
}
static int landin_owned_remove(struct landin_owned_directory *owned)
{
    struct landin_owned_directory retired;
    struct stat actual;
    int error, copied, replacement = 0;
    char original[PATH_MAX + 256], recovery[PATH_MAX + 256];
    landin_owned_describe(owned->parent, owned->parent_path, owned->name,
                           original, sizeof original);
    if (owned->finished) {
        if (fstatat(owned->parent, owned->name, &actual,
                     AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT) return 0;
        snprintf(owned->reason, sizeof owned->reason,
                 "replacement private-directory entry preserved at %s; inspect it before cleanup",
                 original);
        return -1;
    }
    if (owned->retained) return -1;
    owned->reason[0] = '\0';
    if (fstatat(owned->parent, owned->name, &actual, AT_SYMLINK_NOFOLLOW) != 0
        || !landin_owned_same(&actual, &owned->identity)) {
        snprintf(owned->reason, sizeof owned->reason,
                 "private directory name changed at %s; replacement preserved; inspect the original parent before cleanup",
                 original);
        return -1;
    }
    if (landin_owned_allocate(owned->parent, owned->parent_path,
                               ".refine-cleanup-", &retired) != 0) {
        snprintf(owned->reason, sizeof owned->reason,
                 "cannot create private cleanup recovery for %s; retry cleanup in its original parent",
                 original);
        return -1;
    }
    landin_owned_describe(retired.root, retired.path, "entry",
                           recovery, sizeof recovery);
    if (landin_owned_hook) landin_owned_hook("before-capture", owned->path);
    if (renameat(owned->parent, owned->name, retired.root, "entry") != 0) {
        landin_owned_describe(owned->parent, owned->parent_path, owned->name,
                               original, sizeof original);
        snprintf(owned->reason, sizeof owned->reason,
                 "private directory changed before capture at %s; inspect its original parent",
                 original);
        goto fail_empty;
    }
    if (landin_owned_hook) landin_owned_hook("after-capture", owned->path);
    landin_owned_describe(owned->parent, owned->parent_path, owned->name,
                           original, sizeof original);
    landin_owned_describe(retired.root, retired.path, "entry",
                           recovery, sizeof recovery);
    if (fstatat(retired.root, "entry", &actual, AT_SYMLINK_NOFOLLOW) != 0
        || !landin_owned_same(&actual, &owned->identity)) {
        if (fstatat(retired.root, "entry", &actual, AT_SYMLINK_NOFOLLOW) == 0
            && landin_owned_restore(retired.root, "entry", owned->parent,
                                     owned->name, actual.st_mode) == 0) {
            snprintf(owned->reason, sizeof owned->reason,
                     "replacement private directory restored at %s; inspect the original directory before retrying cleanup",
                     original);
            goto fail_empty;
        }
        owned->retained = 1;
        snprintf(owned->reason, sizeof owned->reason,
                 "changed private-directory entry retained at %s; inspect it and %s before restoring it without replacement",
                 recovery, original);
        goto fail_retained;
    }
    copied = fcntl(owned->root, F_DUPFD_CLOEXEC, 3);
    if (copied < 0 || landin_owned_empty(copied) != 0
        || unlinkat(retired.root, "entry", AT_REMOVEDIR) != 0) {
        owned->retained = 1;
        snprintf(owned->reason, sizeof owned->reason,
                 "owned private directory retained at %s; inspect it before retrying cleanup",
                 recovery);
        goto fail_retained;
    }
    replacement = fstatat(owned->parent, owned->name, &actual,
                          AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT;
    landin_owned_describe(retired.root, retired.path, "",
                           recovery, sizeof recovery);
    close(retired.root);
    error = unlinkat(retired.parent, retired.name, AT_REMOVEDIR);
    close(retired.parent);
    owned->finished = 1;
    close(owned->root); owned->root = -1;
    if (replacement || error != 0) {
        snprintf(owned->reason, sizeof owned->reason,
                 "owned private directory removed; replacement or cleanup entry preserved at %s or %s; inspect these names",
                 original, recovery);
        return -1;
    }
    return 1;
fail_empty:
    close(retired.root);
    unlinkat(retired.parent, retired.name, AT_REMOVEDIR);
    close(retired.parent);
    return -1;
fail_retained:
    close(retired.root); close(retired.parent);
    return -1;
}
#endif
