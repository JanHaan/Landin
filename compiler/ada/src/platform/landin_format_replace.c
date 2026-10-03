/* An existing formatter input is replaced only after its new bytes are safe
 * in a sibling file.  The path is resolved so a symlink remains a symlink.
 * Hard links are refused: replacing one name cannot update its other names.
 */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#if defined(__linux__) || defined(__APPLE__)
#include <sys/xattr.h>
#endif
#ifdef __APPLE__
#include <sys/acl.h>
#endif

/* Replacing a file must not silently drop ACLs or extended attributes.
 * Until the adapter can copy every platform's metadata, conservatively
 * refuse files carrying any, and refuse if absence cannot be established.
 * Linux exposes POSIX ACLs through system.posix_acl_access. Darwin's ACL
 * is separate from its xattr list and needs its own query.
 */
static int metadata_is_plain(int fd)
{
#if defined(__linux__)
    ssize_t count = flistxattr(fd, NULL, 0);
    return count == 0 || (count < 0 && errno == ENOTSUP);
#elif defined(__APPLE__)
    ssize_t count = flistxattr(fd, NULL, 0, 0);
    if (count != 0 && !(count < 0 && errno == ENOTSUP))
        return 0;
    acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
    if (!acl)
        /* acl_get_fd_np delegates to FILESEC_ACL: an absent property on
         * the existing open file is ENOENT, not an empty allocated ACL. */
        return errno == ENOENT || errno == ENOTSUP;
    acl_entry_t entry;
    int present = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry);
    int error = errno;
    acl_free(acl);
    /* Darwin returns zero for an entry, and EINVAL at the end. */
    return present == -1 && error == EINVAL;
#else
    (void)fd;
    return 0;
#endif
}

/* Linux can hide trusted.* names from an unprivileged listxattr caller.
 * On the new, disposable inode, prove this namespace is accessible (or
 * unsupported) before treating an empty source list as complete. Refusal
 * deliberately includes ordinary files when the proof is unavailable.
 */
static int metadata_visibility_known(int fd)
{
#ifdef __linux__
    static const char name[] = "trusted.landin-format-visibility";
    if (fsetxattr(fd, name, "", 0, XATTR_CREATE) != 0)
        return errno == ENOTSUP;
    return fremovexattr(fd, name) == 0;
#else
    (void)fd;
    return 1;
#endif
}

int landin_replace_existing_file(const char *path, const char *data, size_t size)
{
    static const char suffix[] = ".fmt-XXXXXX";
    char *target = realpath(path, NULL);
    char *temporary = NULL;
    struct stat original;
    struct stat current;
    int fd = -1;
    int source = -1;
    int result = -1;

    if (!target)
        return -1;
    source = open(target, O_RDONLY | O_NOFOLLOW);
    if (source < 0 || fstat(source, &original) != 0
        || !S_ISREG(original.st_mode)
        || original.st_nlink != 1 || original.st_uid != geteuid()
        || (original.st_mode & 0222) == 0 || access(target, W_OK) != 0)
        goto done;
    if (!metadata_is_plain(source))
        goto done;

    size_t length = strlen(target);
    if (length > SIZE_MAX - sizeof suffix)
        goto done;
    temporary = malloc(length + sizeof suffix);
    if (!temporary)
        goto done;
    memcpy(temporary, target, length);
    memcpy(temporary + length, suffix, sizeof suffix);
    fd = mkstemp(temporary);
    if (fd < 0)
        goto done;

    if (!metadata_visibility_known(fd))
        goto done;

    /* A same-owner/group chown can still require group membership on
     * Darwin. Do not request changes when inheritance already matched. */
    if (fstat(fd, &current) != 0)
        goto done;
    uid_t owner = current.st_uid == original.st_uid
        ? (uid_t)-1 : original.st_uid;
    gid_t group = current.st_gid == original.st_gid
        ? (gid_t)-1 : original.st_gid;
    if ((owner != (uid_t)-1 || group != (gid_t)-1)
        && fchown(fd, owner, group) != 0)
        goto done;
    while (size != 0) {
        ssize_t written = write(fd, data, size);
        if (written < 0 && errno == EINTR)
            continue;
        if (written <= 0)
            goto done;
        data += written;
        size -= (size_t)written;
    }
    /* Writing can clear setuid and setgid; set the final mode afterward. */
    if (fchmod(fd, original.st_mode & 07777) != 0)
        goto done;
    /* chmod may succeed while silently clearing a disallowed setgid bit.
     * Establish the actual result before replacing the original inode. */
    if (fstat(fd, &current) != 0 || current.st_uid != original.st_uid
        || current.st_gid != original.st_gid
        || (current.st_mode & 07777) != (original.st_mode & 07777))
        goto done;
    /* Default directory ACLs may also add metadata to the temporary file. */
    if (!metadata_is_plain(fd))
        goto done;
    if (fsync(fd) != 0)
        goto done;
    if (close(fd) != 0) {
        fd = -1;
        goto done;
    }
    fd = -1;

    /* Refuse an observed replacement of the source during formatting. */
    if (stat(target, &current) != 0 || current.st_dev != original.st_dev
        || current.st_ino != original.st_ino || current.st_nlink != 1)
        goto done;
    if (!metadata_is_plain(source))
        goto done;
    if (rename(temporary, target) != 0)
        goto done;
    result = 0;

done:
    if (source >= 0)
        close(source);
    if (fd >= 0)
        close(fd);
    if (temporary) {
        if (result != 0)
            unlink(temporary);
        free(temporary);
    }
    free(target);
    return result;
}
