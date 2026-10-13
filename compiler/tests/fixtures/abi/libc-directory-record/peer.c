/* What each system's own C headers say of the directory declarations in
   hosted/libc: struct dirent's layout, the flags and the mode and type
   bits.  The Landin program holds its declarations to these answers. */
#define _DARWIN_C_SOURCE 1
#define _GNU_SOURCE 1
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>

size_t record_size(void) { return sizeof(struct dirent); }
size_t record_alignment(void) { return _Alignof(struct dirent); }
size_t record_inode(void) { return offsetof(struct dirent, d_ino); }
size_t record_length(void) { return offsetof(struct dirent, d_reclen); }
size_t record_kind(void) { return offsetof(struct dirent, d_type); }
size_t record_name(void) { return offsetof(struct dirent, d_name); }
size_t record_name_room(void) { return sizeof(((struct dirent *)0)->d_name); }

/* glibc's record has no name length: the name ends at its NUL. */
size_t record_name_length(void)
{
#if defined(__linux__)
    return SIZE_MAX;
#else
    return offsetof(struct dirent, d_namlen);
#endif
}

int32_t flag_directory(void) { return O_DIRECTORY; }
int32_t flag_nofollow(void) { return AT_SYMLINK_NOFOLLOW; }
int32_t flag_removedir(void) { return AT_REMOVEDIR; }
int32_t working_directory(void) { return AT_FDCWD; }
int32_t errno_exists(void) { return EEXIST; }
uint32_t mode_mask(void) { return S_IFMT; }
uint32_t mode_directory(void) { return S_IFDIR; }
uint32_t mode_regular(void) { return S_IFREG; }
uint32_t mode_link(void) { return S_IFLNK; }
uint32_t type_unknown(void) { return DT_UNKNOWN; }
uint32_t type_directory(void) { return DT_DIR; }
uint32_t type_regular(void) { return DT_REG; }
uint32_t type_link(void) { return DT_LNK; }
