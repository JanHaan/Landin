/* An existing formatter input is replaced only after its new bytes are safe
 * in a sibling file.  The path is resolved so a symlink remains a symlink.
 * Hard links are refused: replacing one name cannot update its other names.
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

int landin_replace_existing_file(const char *path, const char *data, size_t size)
{
    static const char suffix[] = ".fmt-XXXXXX";
    char *target = realpath(path, NULL);
    char *temporary = NULL;
    struct stat original;
    struct stat current;
    int fd = -1;
    int result = -1;

    if (!target)
        return -1;
    if (stat(target, &original) != 0 || !S_ISREG(original.st_mode)
        || original.st_nlink != 1 || original.st_uid != geteuid()
        || (original.st_mode & 0222) == 0 || access(target, W_OK) != 0)
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

    /* If the host refuses the source's owner or group, leave it intact. */
    if (fchown(fd, original.st_uid, original.st_gid) != 0)
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
    if (rename(temporary, target) != 0)
        goto done;
    result = 0;

done:
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
