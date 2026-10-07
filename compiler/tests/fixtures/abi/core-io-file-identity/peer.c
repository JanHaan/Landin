#define _DARWIN_C_SOURCE 1
#define _GNU_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Independent native header checks for the private Landin binding. */
_Static_assert(_Alignof(struct stat) == 8, "stat alignment");
_Static_assert(offsetof(struct stat, st_dev) == 0, "device offset");
_Static_assert(offsetof(struct stat, st_ino) == 8, "inode offset");
_Static_assert(sizeof(((struct stat *)0)->st_ino) == 8, "inode width");
#if defined(__FreeBSD__)
_Static_assert(sizeof(struct stat) == 224, "FreeBSD stat extent");
_Static_assert(sizeof(((struct stat *)0)->st_dev) == 8, "FreeBSD device width");
_Static_assert(offsetof(struct stat, st_size) == 112, "FreeBSD trailing fields");
#elif defined(__APPLE__)
_Static_assert(sizeof(struct stat) == 144, "Darwin stat extent");
_Static_assert(sizeof(((struct stat *)0)->st_dev) == 4, "Darwin device width");
_Static_assert(offsetof(struct stat, st_size) == 96, "Darwin trailing fields");
#elif defined(__aarch64__) || (defined(__riscv) && __riscv_xlen == 64)
_Static_assert(sizeof(struct stat) == 128, "asm-generic Linux stat extent");
_Static_assert(sizeof(((struct stat *)0)->st_dev) == 8, "Linux device width");
_Static_assert(offsetof(struct stat, st_size) == 48, "asm-generic Linux trailing fields");
#elif defined(__x86_64__)
_Static_assert(sizeof(struct stat) == 144, "SysV stat extent");
_Static_assert(sizeof(((struct stat *)0)->st_dev) == 8, "Linux device width");
_Static_assert(offsetof(struct stat, st_size) == 48, "SysV trailing fields");
#else
#error unsupported fixture host
#endif

static int scenario, calls, fault;
static char directory[128];
static char paths[5][160];

void identity_select(int32_t value) { scenario = value; calls = fault = 0; }
bool identity_check(int32_t expected) { return calls == expected && !fault; }

/* Overrides the exact libc symbol selected by this host's own header.
   Real filesystem controls use fstatat to avoid calling this override again. */
int stat(const char *path, struct stat *result)
{
    if (!scenario) return fstatat(AT_FDCWD, path, result, 0);
    ++calls;
    if ((uintptr_t)result % _Alignof(struct stat) != 0 || calls > 2 ||
        strcmp(path, calls == 1 ? "left" : "right") != 0) fault = 1;
    if (((scenario == 5 || scenario == 7) && calls == 1) || (scenario >= 4 && calls == 2)) {
        errno = scenario <= 5 ? ENOENT : scenario == 8 ? EIO : EACCES;
        return -1;
    }
    memset(result, calls == 1 ? 0x51 : 0x72, sizeof *result);
    result->st_dev = (dev_t)UINT64_C(0x1234567876543210);
    result->st_ino = (ino_t)UINT64_C(0x123456789abcdef0);
    /* Metadata differs between observations without changing identity. */
    result->st_mode = calls == 1 ? 0600 : 0644;
    result->st_nlink = calls == 1 ? 2 : 3;
    if (calls == 2 && scenario == 2) result->st_ino ^= UINT64_C(1) << 40;
    if (calls == 2 && scenario == 3) {
#if defined(__APPLE__)
        result->st_dev ^= 0x40000000;
#else
        result->st_dev ^= UINT64_C(1) << 40;
#endif
    }
    return 0;
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
    strcpy(directory, "/tmp/landin-identity-XXXXXX");
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
