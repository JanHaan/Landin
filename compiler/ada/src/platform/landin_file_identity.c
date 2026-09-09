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
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
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

static int same_name(const struct destination *a, const struct destination *b)
{
    const unsigned char *left = (const unsigned char *)a->name;
    const unsigned char *right = (const unsigned char *)b->name;
    int rules;
    size_t i;

    if (strcmp(a->name, b->name) == 0)
        return 1;
    rules = name_rules(a->directory);
    if (rules == 1)
        return 0;
    if (rules < 0)
        return -1;
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
    return left[i] == right[i];
}

int landin_same_file(const char *left, const char *right)
{
    struct destination a;
    struct destination b;

    if (destination(left, &a, 0) != 0 || destination(right, &b, 0) != 0)
        return -1;
    if (a.exists && b.exists)
        return a.object.st_dev == b.object.st_dev
            && a.object.st_ino == b.object.st_ino;
    /* In a stable namespace, an existing and an absent object cannot alias. */
    if (a.exists != b.exists)
        return 0;
    if (a.parent.st_dev != b.parent.st_dev
        || a.parent.st_ino != b.parent.st_ino)
        return 0;
    return same_name(&a, &b);
}
