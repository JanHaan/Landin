#define _GNU_SOURCE 1
#include <fcntl.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* platform/linux's file_status is the kernel's struct statx, one layout on
   every Linux architecture. */
_Static_assert(sizeof(struct statx) == 256, "statx extent");
_Static_assert(offsetof(struct statx, stx_mask) == 0, "mask offset");
_Static_assert(offsetof(struct statx, stx_mode) == 28, "mode offset");
_Static_assert(offsetof(struct statx, stx_ino) == 32, "inode offset");
_Static_assert(offsetof(struct statx, stx_dev_major) == 136, "device major");
_Static_assert(offsetof(struct statx, stx_dev_minor) == 140, "device minor");
_Static_assert(STATX_INO == 0x100, "statx_ino");
_Static_assert(AT_FDCWD == -100, "at_fdcwd");

static char directory[128];
static char paths[5][160];

size_t identity_record_size(void) { return sizeof(struct statx); }

/* The C library's statx of the same path fills the same fields. */
bool identity_record_agrees(const char *path, const unsigned char *record)
{
    struct statx own, theirs;
    memcpy(&theirs, record, sizeof theirs);
    if (statx(AT_FDCWD, path, 0, STATX_INO, &own) != 0) return false;
    return (theirs.stx_mask & STATX_INO) != 0
        && own.stx_ino == theirs.stx_ino
        && own.stx_dev_major == theirs.stx_dev_major
        && own.stx_dev_minor == theirs.stx_dev_minor
        && own.stx_mode == theirs.stx_mode;
}

const unsigned char *identity_path(int32_t which)
{ return (const unsigned char *)paths[which]; }

void identity_cleanup(void)
{
    for (int i = 0; i < 5; ++i) unlink(paths[i]);
    rmdir(directory);
}

bool identity_setup(void)
{
    strcpy(directory, "/tmp/landin-linux-identity-XXXXXX");
    if (!mkdtemp(directory)) return false;
    for (int i = 0; i < 5; ++i)
        snprintf(paths[i], sizeof paths[i], "%s/%d", directory, i);
    int fd = open(paths[0], O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (fd < 0) { identity_cleanup(); return false; }
    close(fd);
    if (link(paths[0], paths[1]) || symlink(paths[0], paths[2])) {
        identity_cleanup(); return false;
    }
    fd = open(paths[3], O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (fd < 0) { identity_cleanup(); return false; }
    close(fd);
    return true; /* paths[4] deliberately does not exist. */
}
