#ifdef __linux__
#define _GNU_SOURCE
#endif
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#ifndef __FreeBSD__
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#endif
#include "landin_publication.h"
#include <errno.h>
#include <pthread.h>
#include <dirent.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif

int landin_private_open(const char *, int, mode_t);
int landin_private_parent(const char *, char **, char **);

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
static int landin_publication_stage_directory_locked(const char *text);
static int landin_publication_rebase_argument_locked(const char *arg, int directory,
    char *out, size_t room);
static int landin_publication_stage_write_locked(const char *path, const char *bytes,
    size_t size);
static int landin_publication_stage_mkdir_locked(const char *path);
static int landin_read_snapshot_locked(const char *path, char **bytes, size_t *size,
    uint64_t *device, uint64_t *inode);
static int landin_publication_open_locked(const char *path, int deletion,
    const char *root, int *token, char *stage, size_t stage_room, char *why,
    size_t room);
static int landin_publication_step_locked(int token, int action,
    const char *const *paths, size_t path_count, const uint64_t *ids, size_t count,
    char *why, size_t room);

struct arena {
    int parent, private_fd, recovery_fd, root_fd;
    int producer_fd;
    struct stat parent_id;
    char *path, *name, *recovery_path;
    unsigned refs;
    int retained;
    struct arena *next;
};
struct publication {
    int token, absent, deletion, captured, installed, unchanged, finished;
    int rollback_pending, expected_fd, capture_valid, finish_failed;
    /* 0: no destination record; 1: its building name exists with
       journal_id; 2: sealed under journal. */
    int journal_state;
    char journal[64];
    struct stat journal_id;
    struct arena *arena;
    struct root_anchor *anchor;
    char *path, *name, *stage, *recovery, *rollback;
    struct stat expected, fresh;
    char *bytes;
    size_t size;
    struct tree_entry *expected_tree, *fresh_tree;
    struct publication *next;
};
struct root_anchor {
    char *path;
    int fd;
    struct stat identity;
    unsigned refs;
    struct root_anchor *next;
};
static struct root_anchor *roots;
static struct arena *arenas;
static struct publication *publications;
static void describe_recovery(const struct arena *, char *, size_t);
static void quarantine(struct arena *a)
{
    int saved = errno;
    a->retained = 1;
    if (a->producer_fd >= 0) { close(a->producer_fd); a->producer_fd = -1; }
    errno = saved;
}
static int next_token = 1;
extern int landin_cancellation_requested(void);
extern int landin_overlaps_any(const char *, const char *const *, size_t);
extern int landin_entry_names_alias(int, const char *, const char *);
static landin_publication_hook fault_hook;
void landin_publication_set_hook(landin_publication_hook hook) { fault_hook = hook; }
void landin_publication_notify(const char *event, const char *path)
{ if (fault_hook) fault_hook(event, path); }
#define barrier landin_publication_notify
static void reason(char *out, size_t room, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    if (room) vsnprintf(out, room, format, args);
    va_end(args);
}
static int same(const struct stat *a, const struct stat *b)
{ return a->st_dev == b->st_dev && a->st_ino == b->st_ino; }
static void prune_anchors(void)
{
    struct root_anchor **link = &roots;
    int saved = errno;
    while (*link) {
        struct root_anchor *root = *link;
        if (root->refs) { link = &root->next; continue; }
        *link = root->next;
        close(root->fd); free(root->path); free(root);
    }
    errno = saved;
}
static void release_anchor(struct publication *p)
{
    if (p->anchor) { --p->anchor->refs; p->anchor = NULL; }
    prune_anchors();
}
static char *read_bytes(int fd, size_t *size)
{
    size_t used = 0, capacity = 4096;
    char *bytes = malloc(capacity);
    if (!bytes) return NULL;
    for (;;) {
        ssize_t got;
        if (used == capacity) {
            char *more;
            if (capacity > SIZE_MAX / 2) { free(bytes); errno = EFBIG; return NULL; }
            capacity *= 2;
            more = realloc(bytes, capacity);
            if (!more) { free(bytes); return NULL; }
            bytes = more;
        }
        got = pread(fd, bytes + used, capacity - used, (off_t)used);
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) { free(bytes); return NULL; }
        if (!got) break;
        used += (size_t)got;
    }
    bytes[used] = 0;
    *size = used;
    return bytes;
}
struct tree_entry {
    char *name, *bytes;
    int fd;
    size_t size;
    struct stat identity;
    struct tree_entry *children, *next;
};
static void free_tree(struct tree_entry *tree)
{
    while (tree) {
        struct tree_entry *next = tree->next;
        free_tree(tree->children);
        if (tree->fd >= 0) close(tree->fd);
        free(tree->name); free(tree->bytes);
        free(tree); tree = next;
    }
}
static struct tree_entry *snapshot_entry(int parent, const char *name)
{
    struct tree_entry *entry = calloc(1, sizeof *entry);
    int fd = -1;
    struct stat actual;
    if (!entry) return NULL;
    entry->fd = -1;
    entry->name = strdup(name);
    if (!entry->name || fstatat(parent, name, &entry->identity,
                                AT_SYMLINK_NOFOLLOW) != 0) goto fail;
    if (!S_ISDIR(entry->identity.st_mode) && !S_ISREG(entry->identity.st_mode))
        { errno = ELOOP; goto fail; }
    fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                 | (S_ISDIR(entry->identity.st_mode) ? O_DIRECTORY : 0));
    if (fd < 0 || fstat(fd, &actual) != 0
        || !same(&actual, &entry->identity)) { errno = EAGAIN; goto fail; }
    if (S_ISDIR(actual.st_mode)) {
        DIR *directory = fdopendir(dup(fd));
        struct dirent *child;
        if (!directory) goto fail;
        errno = 0;
        while ((child = readdir(directory)) != NULL) {
            if (!strcmp(child->d_name, ".") || !strcmp(child->d_name, "..")) continue;
            struct tree_entry *item = snapshot_entry(fd, child->d_name);
            if (!item) { closedir(directory); goto fail; }
            item->next = entry->children; entry->children = item;
            errno = 0;
        }
        int error = errno;
        closedir(directory);
        if (error) { errno = error; goto fail; }
    } else {
        entry->bytes = read_bytes(fd, &entry->size);
        if (!entry->bytes) goto fail;
    }
    entry->fd = fd;
    return entry;
fail:
    if (fd >= 0) close(fd);
    free_tree(entry); return NULL;
}
static int equal_tree(const struct tree_entry *a, const struct tree_entry *b,
                       int identities)
{
    if (!a || !b || (identities && !same(&a->identity, &b->identity))
        || S_ISDIR(a->identity.st_mode) != S_ISDIR(b->identity.st_mode)) return 0;
    if (S_ISREG(a->identity.st_mode))
        return a->size == b->size && !memcmp(a->bytes, b->bytes, a->size);
    size_t a_count = 0, b_count = 0;
    const struct tree_entry *x, *y;
    for (x = a->children; x; x = x->next) {
        ++a_count;
        for (y = b->children; y; y = y->next) if (!strcmp(x->name, y->name)) break;
        if (!y || !equal_tree(x, y, identities)) return 0;
    }
    for (y = b->children; y; y = y->next) ++b_count;
    return a_count == b_count;
}
/* Remove exactly the snapshotted private entries. Unknown names prevent the
   final rmdir; they are never swept recursively. */
static int discard_known_tree(int parent, const char *name, const struct tree_entry *tree)
{
    struct stat actual;
    if (fstatat(parent, name, &actual, AT_SYMLINK_NOFOLLOW) != 0
        || !same(&actual, &tree->identity)) { errno = EAGAIN; return -1; }
    if (S_ISDIR(actual.st_mode)) {
        int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        const struct tree_entry *child;
        if (fd < 0) return -1;
        for (child = tree->children; child; child = child->next)
            if (discard_known_tree(fd, child->name, child) != 0) { close(fd); return -1; }
        close(fd);
        return unlinkat(parent, name, AT_REMOVEDIR);
    }
    return unlinkat(parent, name, 0);
}
static int discard_tree(int parent, const char *name, const struct tree_entry *tree)
{
    struct tree_entry *current = snapshot_entry(parent, name);
    int matches = current && equal_tree(tree, current, 1);
    free_tree(current);
    if (!matches) { errno = EAGAIN; return -1; }
    return discard_known_tree(parent, name, tree);
}
static struct arena *stage_arena(const char *path, const char **relative)
{
    struct arena *a;
    for (a = arenas; a; a = a->next) {
        size_t n = strlen(a->path);
        if (!strncmp(path, a->path, n) && (path[n] == '/' || !path[n])) {
            *relative = path + n + (path[n] == '/'); return a;
        }
    }
    return NULL;
}
/* This component namespace is reserved for invocation-owned publication
   staging. Once its live registry entry is gone, spelling it cannot recreate
   authority through the ordinary pathname fallback. Inspect components, not
   filename substrings. Reserve the whole arena component, including alternate
   empty/dot separators before stage. Tool arguments also have value boundaries.
   This is a spelling guard, not filesystem canonicalization through aliases. */
static int reserved_stage(const char *path, int argument)
{
    const char *at = path;
    while ((at = strstr(at, ".refine-publication-")) != NULL) {
        const char *end = strchr(at, '/');
        if ((at == path || at[-1] == '/'
             || (argument && (at[-1] == '=' || at[-1] == ',')))
            && (!end || end > at + strlen(".refine-publication-"))
            && at[strlen(".refine-publication-")]) return 1;
        ++at;
    }
    return 0;
}
static int stage_open(const char *path, int flags, mode_t mode)
{
    const char *relative;
    struct arena *a = stage_arena(path, &relative);
    if (!a) {
        if (reserved_stage(path, 0)) { errno = ESTALE; return -1; }
        return -2;
    }
    if (!a->refs) { errno = ESTALE; return -1; }
    if (!*relative) { errno = EISDIR; return -1; }
    char *walk = strdup(relative), *save = NULL, *part;
    int fd = dup(a->private_fd), result = -1;
    if (!walk || fd < 0) { free(walk); if (fd >= 0) close(fd); return -1; }
    part = strtok_r(walk, "/", &save);
    while (part) {
        char *next = strtok_r(NULL, "/", &save);
        if (!strcmp(part, ".") || !strcmp(part, "..")) { errno = EINVAL; break; }
        if (!next) { result = openat(fd, part, flags | O_NOFOLLOW | O_CLOEXEC, mode); break; }
        int child = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd); fd = child;
        if (fd < 0) break;
        part = next;
    }
    if (fd >= 0) close(fd);
    free(walk); return result;
}
static int landin_publication_stage_mkdir_locked(const char *path)
{
    const char *relative;
    struct arena *a = stage_arena(path, &relative);
    if (!a) {
        if (reserved_stage(path, 0)) { errno = ESTALE; return -1; }
        return -2;
    }
    if (!a->refs) { errno = ESTALE; return -1; }
    if (!*relative) {
        struct stat st;
        return fstat(a->private_fd, &st) == 0 && S_ISDIR(st.st_mode) ? 0 : -1;
    }
    char *walk = strdup(relative), *save = NULL, *part;
    int fd = dup(a->private_fd), result = -1;
    if (!walk || fd < 0) { free(walk); if (fd >= 0) close(fd); return -1; }
    part = strtok_r(walk, "/", &save);
    while (part) {
        char *next = strtok_r(NULL, "/", &save);
        if (!strcmp(part, ".") || !strcmp(part, "..")) { errno = EINVAL; break; }
        if (!next) {
            /* The arena already supplies privacy. Preserve ordinary directory
               creation's umask, but never adopt an occupied staged entry. */
            result = mkdirat(fd, part, 0777);
            break;
        }
        int child = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd); fd = child;
        if (fd < 0) break;
        part = next;
    }
    if (fd >= 0) close(fd);
    free(walk); return result;
}
static int landin_publication_stage_directory_locked(const char *text)
{
    struct arena *a;
    for (a = arenas; a; a = a->next) {
        const char *found = strstr(text, a->path);
        if (a->refs && found
            && (!found[strlen(a->path)] || found[strlen(a->path)] == '/'
                || found[strlen(a->path)] == '=')) {
            int fd = dup(a->private_fd);
            return fd < 0 ? -2 : fd;
        }
    }
    if (reserved_stage(text, 1)) { errno = ESTALE; return -2; }
    return -1;
}
static int landin_publication_rebase_argument_locked(const char *arg, int directory,
                                       char *out, size_t room)
{
    struct stat selected;
    size_t used = 0;
    if (fstat(directory, &selected) != 0) return -1;
    while (*arg) {
        struct arena *a;
        int matched = 0;
        for (a = arenas; a; a = a->next) {
            size_t n = strlen(a->path);
            struct stat actual;
            if (!a->refs || strncmp(arg, a->path, n)
                || (arg[n] && arg[n] != '/' && arg[n] != '=')) continue;
            if (fstat(a->private_fd, &actual) != 0 || !same(&actual, &selected)) return -1;
            if (used + 1 >= room) return -1;
            out[used++] = '.'; arg += n; matched = 1; break;
        }
        if (!matched) {
            if (used + 1 >= room) return -1;
            out[used++] = *arg++;
        }
    }
    if (used >= room) return -1;
    out[used] = 0;
    if (reserved_stage(out, 1)) { errno = ESTALE; return -1; }
    return 0;
}
static int landin_publication_stage_write_locked(const char *path, const char *bytes,
    size_t size)
{
    int fd = stage_open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0 && fd != -2 && errno == EEXIST)
        fd = stage_open(path, O_WRONLY, 0);
    if (fd < 0) return fd;
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int error = errno;
        close(fd); errno = error; return -1;
    }
    if (!S_ISREG(st.st_mode)) {
        close(fd); errno = EINVAL; return -1;
    }
    size_t used = 0;
    while (used < size) {
        ssize_t wrote = write(fd, bytes + used, size - used);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) {
            int error = wrote == 0 ? EIO : errno;
            close(fd); errno = error; return -1;
        }
        used += (size_t)wrote;
    }
    int result = ftruncate(fd, (off_t)size);
    if (result == 0) result = fsync(fd);
    int error = errno;
    if (close(fd) != 0 && result == 0) return -1;
    errno = error; return result;
}
static int landin_read_snapshot_locked(const char *path, char **bytes, size_t *size,
                         uint64_t *device, uint64_t *inode)
{
    struct stat st;
    int fd = stage_open(path, O_RDONLY | O_NONBLOCK, 0), result = -1;
    if (fd == -2) fd = landin_private_open(path, O_RDONLY | O_NONBLOCK, 0);
    if (fd == -2) fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    *bytes = NULL;
    if (fd < 0) return errno == ENOENT ? 1 : -1;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode)
        && (*bytes = read_bytes(fd, size)) != NULL) {
        *device = (uint64_t)st.st_dev; *inode = (uint64_t)st.st_ino;
        result = 0;
    }
    close(fd);
    return result;
}
void landin_snapshot_free(char *bytes) { free(bytes); }
/* Anchor selection is permitted to resolve ancestors once. The chosen root
   itself, and every component below it, must be ordinary directories. */
static void strip_dots(char *path)
{
    char *dot;
    while ((dot = strstr(path, "/./")) != NULL) memmove(dot, dot + 2, strlen(dot + 2) + 1);
    size_t n = strlen(path);
    if (n >= 2 && !strcmp(path + n - 2, "/.")) path[n-2 ? n-2 : 1] = 0;
}
static int parent_for(const char *path, const char *root, char **parent_path,
                      char **name, int require_absent,
                      struct root_anchor **anchor)
{
    char *absolute = NULL, *root_abs = NULL, *walk = NULL, *save = NULL, *part;
    struct root_anchor *chosen = NULL;
    *anchor = NULL;
    if (reserved_stage(path, 0) || reserved_stage(root, 0)) {
        errno = ESTALE; return -1;
    }
    int fd = landin_private_parent(path, parent_path, name);
    if (fd != -2) return fd;
    fd = -1;
    if (!*path) { errno = EINVAL; return -1; }
    char *cwd = getcwd(NULL, 0);
    if (!cwd) return -1;
    size_t n = strlen(cwd) + strlen(path) + strlen(root) + 8;
    absolute = malloc(n); root_abs = malloc(n);
    if (!absolute || !root_abs) goto done;
    snprintf(absolute, n, "%s%s%s", *path == '/' ? "" : cwd,
             *path == '/' ? "" : "/", path);
    char *slash = strrchr(absolute, '/');
    if (!slash || !slash[1] || !strcmp(slash + 1, ".") || !strcmp(slash + 1, ".."))
        { errno = EINVAL; goto done; }
    *name = strdup(slash + 1);
    if (!*name) goto done;
    if (slash == absolute) slash[1] = 0;
    else *slash = 0;
    strip_dots(absolute);
    if (*root) {
        snprintf(root_abs, n, "%s%s%s", *root == '/' ? "" : cwd,
                 *root == '/' ? "" : "/", root);
        strip_dots(root_abs);
        size_t len = strlen(root_abs);
        while (len > 1 && root_abs[len-1] == '/') root_abs[--len] = 0;
        if (strncmp(absolute, root_abs, len)
            || (len > 1 && absolute[len] && absolute[len] != '/')) { errno = EINVAL; goto done; }
        fd = open(root_abs, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (fd < 0 && errno == ENOENT) {
            /* Create an explicitly requested root through pinned, no-follow
               components. Existing aliases below / (except system anchors)
               are refused rather than followed during creation. */
            fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
            walk = strdup(root_abs);
#ifdef __APPLE__
            if (!strncmp(root_abs, "/tmp/", 5) || !strcmp(root_abs, "/tmp")) {
                close(fd); fd = open("/tmp", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
                free(walk); walk = strdup(root_abs + 4);
            } else if (!strncmp(root_abs, "/var/", 5) || !strcmp(root_abs, "/var")) {
                close(fd); fd = open("/var", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
                free(walk); walk = strdup(root_abs + 4);
            }
#endif
            if (!walk || fd < 0) {
                int error = errno;
                if (fd >= 0) close(fd);
                fd = -1; errno = error; goto done;
            }
            for (part = strtok_r(walk, "/", &save); part;
                 part = strtok_r(NULL, "/", &save)) {
                if (!strcmp(part, ".")) continue;
                if (!strcmp(part, "..")) { close(fd); fd = -1; errno = EINVAL; goto done; }
                int child = openat(fd, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
                if (child < 0 && errno == ENOENT) {
                    if (mkdirat(fd, part, 0755) != 0 && errno != EEXIST)
                        { close(fd); fd = -1; goto done; }
                    child = openat(fd, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
                }
                close(fd); fd = child;
                if (fd < 0) goto done;
            }
            free(walk); walk = NULL;
        }
        if (fd < 0) goto done;
        struct stat selected;
        if (fstat(fd, &selected) != 0) { close(fd); fd = -1; goto done; }
        struct root_anchor *known;
        for (known = roots; known; known = known->next)
            if (!strcmp(known->path, root_abs)) break;
        if (known) {
            if (!same(&selected, &known->identity)) {
                close(fd); fd = -1; errno = ESTALE; goto done;
            }
        } else {
            known = calloc(1, sizeof *known);
            if (!known || !(known->path = strdup(root_abs))) {
                free(known); close(fd); fd = -1; goto done;
            }
            known->fd = dup(fd);
            if (known->fd < 0) {
                free(known->path); free(known); close(fd); fd = -1; goto done;
            }
            known->identity = selected;
            known->next = roots; roots = known;
        }
        chosen = known;
        walk = strdup(absolute + len + (absolute[len] == '/'));
        if (!walk) { close(fd); fd = -1; goto done; }
        save = NULL;
        for (part = strtok_r(walk, "/", &save); part;
             part = strtok_r(NULL, "/", &save)) {
            if (!strcmp(part, ".")) continue;
            if (!strcmp(part, "..")) { close(fd); fd = -1; errno = EINVAL; goto done; }
            int child = openat(fd, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            if (child < 0 && errno == ENOENT) {
                if (mkdirat(fd, part, 0755) != 0 && errno != EEXIST)
                    { close(fd); fd = -1; goto done; }
                child = openat(fd, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            }
            close(fd); fd = child;
            if (fd < 0) goto done;
        }
    } else if (require_absent) {
        /* An absent generated tree keeps the old missing-root policy: pin
           the existing parent chain without following user aliases or making
           any public directories. The ordinary output-path policy below is
           unchanged. Darwin's system anchors are selected as before. */
        fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        walk = strdup(absolute);
#ifdef __APPLE__
        if (!strncmp(absolute, "/tmp/", 5) || !strcmp(absolute, "/tmp")) {
            close(fd); fd = open("/tmp", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
            free(walk); walk = strdup(absolute + 4);
        } else if (!strncmp(absolute, "/var/", 5) || !strcmp(absolute, "/var")) {
            close(fd); fd = open("/var", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
            free(walk); walk = strdup(absolute + 4);
        }
#endif
        if (!walk || fd < 0) {
            int error = errno;
            if (fd >= 0) close(fd);
            fd = -1; errno = error; goto done;
        }
        for (part = strtok_r(walk, "/", &save); part;
             part = strtok_r(NULL, "/", &save)) {
            if (!strcmp(part, ".")) continue;
            if (!strcmp(part, "..")) { close(fd); fd = -1; errno = EINVAL; goto done; }
            int child = openat(fd, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            close(fd); fd = child;
            if (fd < 0) goto done;
        }
    } else {
        /* The explicitly selected parent is the anchor. No implicit creation
           for ordinary compiler output paths. Final-component links refuse. */
        fd = open(absolute, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    }
    if (fd >= 0) {
        *parent_path = strdup(absolute);
        if (!*parent_path) { close(fd); fd = -1; }
    }
done:
    if (fd >= 0 && chosen) { ++chosen->refs; *anchor = chosen; }
    prune_anchors();
    free(cwd); free(absolute); free(root_abs); free(walk);
    return fd;
}
static int no_replace(int fromfd, const char *from, int tofd, const char *to,
                       int directory)
{
#ifdef __linux__
#ifdef SYS_renameat2
    if (syscall(SYS_renameat2, fromfd, from, tofd, to, 1U) == 0) return 0;
    if (errno != ENOSYS && errno != EINVAL && errno != EOPNOTSUPP) return -1;
#endif
#elif defined(__APPLE__)
    if (renameatx_np(fromfd, from, tofd, to, RENAME_EXCL) == 0) return 0;
    if (errno != ENOTSUP && errno != EINVAL) return -1;
#endif
    if (directory) { errno = ENOTSUP; return -1; }
    if (linkat(fromfd, from, tofd, to, 0) != 0) return -1;
    /* Both names belong to this transaction now; failure leaves a safe extra
       private link and is dealt with by Finish, never by public unlink. */
    (void)unlinkat(fromfd, from, 0);
    return 0;
}
static struct publication *lookup(int token)
{
    struct publication *p;
    for (p = publications; p; p = p->next) if (p->token == token) return p;
    return NULL;
}
static struct arena *arena_for(int parent, const char *path)
{
    struct stat st;
    struct arena *a;
    if (fstat(parent, &st) != 0) return NULL;
    for (a = arenas; a; a = a->next) if (a->refs && !a->retained
                                       && same(&st, &a->parent_id)) {
        close(parent); ++a->refs; return a;
    }
    a = calloc(1, sizeof *a);
    if (!a) return NULL;
    a->producer_fd = -1;
    size_t n = strlen(path) + 80;
    a->path = malloc(n);
    if (!a->path) { free(a); return NULL; }
    /* Allocate relative to the pinned parent; never reopen its pathname. */
    unsigned char entropy[12];
    int random_fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (random_fd < 0 || read(random_fd, entropy, sizeof entropy) != sizeof entropy) {
        if (random_fd >= 0) close(random_fd);
        free(a->path); free(a); return NULL;
    }
    close(random_fd);
    char leaf[64];
    snprintf(leaf, sizeof leaf, ".refine-publication-%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
             entropy[0], entropy[1], entropy[2], entropy[3], entropy[4], entropy[5],
             entropy[6], entropy[7], entropy[8], entropy[9], entropy[10], entropy[11]);
    if (mkdirat(parent, leaf, 0700) != 0) { free(a->path); free(a); return NULL; }
    snprintf(a->path, n, "%s/%s", path, leaf);
    a->name = strdup(strrchr(a->path, '/') + 1);
    a->root_fd = openat(parent, a->name,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (a->root_fd < 0) { free(a->name); free(a->path); free(a); return NULL; }
    if (mkdirat(a->root_fd, "stage", 0700) != 0
        || mkdirat(a->root_fd, "recovery", 0700) != 0) {
        close(a->root_fd); free(a->name); free(a->path); free(a); return NULL;
    }
    a->private_fd = openat(a->root_fd, "stage",
                           O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    a->recovery_fd = openat(a->root_fd, "recovery",
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (a->private_fd < 0 || a->recovery_fd < 0) {
        if (a->private_fd >= 0) close(a->private_fd);
        if (a->recovery_fd >= 0) close(a->recovery_fd);
        close(a->root_fd); free(a->name); free(a->path); free(a); return NULL;
    }
    a->recovery_path = malloc(n);
    if (!a->recovery_path) {
        close(a->private_fd); close(a->recovery_fd); close(a->root_fd);
        free(a->name); free(a->path); free(a); return NULL;
    }
    snprintf(a->recovery_path, n, "%s/recovery", a->path);
    strcat(a->path, "/stage");
    a->parent = parent; a->parent_id = st; a->refs = 1;
    a->next = arenas; arenas = a;
    return a;
}
static int own_arena_name(int parent, const char *name)
{
    struct stat st;
    struct arena *a;
    if (fstat(parent, &st) != 0) return 0;
    for (a = arenas; a; a = a->next)
        if (a->refs && !a->retained && same(&st, &a->parent_id)
            && !strcmp(name, a->name)) return 1;
    return 0;
}
struct known_name {
    char *name;
    struct known_name *next;
};
static void free_names(struct known_name *names)
{
    while (names) {
        struct known_name *next = names->next;
        free(names->name); free(names); names = next;
    }
}
static int add_name(struct known_name **names, const char *name, size_t length)
{
    struct known_name *item = malloc(sizeof *item);
    if (!item) return -1;
    item->name = malloc(length + 1);
    if (!item->name) { free(item); return -1; }
    memcpy(item->name, name, length); item->name[length] = 0;
    item->next = *names; *names = item; return 0;
}
static int numbered(const char *name, const char *prefix)
{
    size_t length = strlen(prefix);
    if (strncmp(name, prefix, length) || !name[length]
        || strlen(name + length) > 10) return 0;
    for (name += length; *name; ++name) if (*name < '0' || *name > '9') return 0;
    return 1;
}
/* With no published records, an empty allow-list proves this is only setup:
   stage/recovery may be absent or empty, never linked or unexplained. */
static int entries_known(int root, const char *directory, struct known_name *names,
                         int live_producer)
{
    int fd = openat(root, directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return errno == ENOENT;
    DIR *listing = fdopendir(fd);
    struct dirent *item;
    int known = 1;
    if (!listing) { close(fd); return 0; }
    while (known) {
        errno = 0; item = readdir(listing);
        if (!item) { if (errno) known = 0; break; }
        if (!strcmp(item->d_name, ".") || !strcmp(item->d_name, "..")) continue;
        struct known_name *match;
        for (match = names; match; match = match->next)
            if (!strcmp(match->name, item->d_name)) break;
        if (!match && !live_producer) known = 0;
    }
    closedir(listing); return known;
}
#ifdef __APPLE__
/* APFS can retain a removed directory's former link count. Classify only its
   observable content here, without inferring deletion or future liveness.
   root was freshly opened and has not been enumerated, so its duplicated fd
   starts at the beginning. Even dot entries make this disconnected root live
   or uncertain, rather than an acceptable empty snapshot. */
static int disconnected_workspace_empty(int root, int parent, const char *name)
{
    int fd = dup(root);
    if (fd < 0) return 0;
    DIR *contents = fdopendir(fd);
    if (!contents) { close(fd); return 0; }
    errno = 0;
    int empty = readdir(contents) == NULL && errno == 0;
    if (closedir(contents) != 0) empty = 0;
    if (!empty) return 0;
    barrier("discovery-empty", name);
    struct stat replacement;
    return fstatat(parent, name, &replacement, AT_SYMLINK_NOFOLLOW) < 0
        && errno == ENOENT;
}
#endif
/* Records are atomically published. The shared root lock prevents a newly
   completed record (and its later stage) from racing this allow-list scan;
   record construction remains private and does not hold that lock. */
static int retained_workspace(int parent, const char *parent_path,
                               const char *target, char *why, size_t room)
{
    struct stat parent_id;
    if (fstat(parent, &parent_id) != 0) return -1;
    for (struct arena *a = arenas; a; a = a->next) {
        if (a->retained && same(&parent_id, &a->parent_id)) {
            char location[PATH_MAX + 256];
            describe_recovery(a, location, sizeof location);
            reason(why, room, "retained publication recovery directory %s; inspect it before preparing more outputs in this parent",
                   location);
            errno = EBUSY; return -1;
        }
    }
    /* Own live arenas bypass disk discovery, but independent transactions
       must not receive authority to the same stage entry. Keep finished
       siblings reserved until their arena retires, as foreign journals do. */
    for (struct publication *p = publications; p; p = p->next) {
        if (p->arena->refs && same(&parent_id, &p->arena->parent_id)
            && landin_entry_names_alias(parent, target, p->name) != 0) {
            reason(why, room, "output %s is reserved by or cannot be proved separate from active publication %s; check paths and retry after that transaction completes",
                   target, p->path);
            errno = EBUSY; return -1;
        }
    }
    DIR *directory = fdopendir(dup(parent));
    struct dirent *item;
    int refused = 0;
    if (!directory) return -1;
    rewinddir(directory);
    while (!refused) {
        errno = 0; item = readdir(directory);
        if (!item) { refused = errno != 0; break; }
        if (strncmp(item->d_name, ".refine-publication-", 20)
            || own_arena_name(parent, item->d_name)) continue;
        int root = openat(parent, item->d_name,
                           O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (root < 0 && errno == ENOENT) continue;
        if (root >= 0) barrier("discovery-opened", target);
        DIR *records = NULL;
        struct known_name *stage_names = NULL, *recovery_names = NULL;
        int live_producer = 0;
        if (root >= 0 && flock(root, LOCK_SH) == 0) {
            struct stat pinned, named;
            if (fstat(root, &pinned) == 0 && S_ISDIR(pinned.st_mode)) {
                int found = fstatat(parent, item->d_name, &named, AT_SYMLINK_NOFOLLOW);
                int disconnected = found < 0 && errno == ENOENT;
                /* Finish can remove the empty root before this scanner locks
                   its retained fd. Linux/FreeBSD zero links prove successful
                   empty-directory removal. Darwin uses only a readable, raw
                   zero-entry snapshot plus a second anchored absence check.
                   The SH lock blocks new destination records/publication, not
                   all owner staging writes. No private contents are deleted
                   here; unexplained contents, replacements and errors refuse.
                   This is not a claim about future noncooperating writers. */
#ifdef __APPLE__
                int ignorable = disconnected
                    && disconnected_workspace_empty(root, parent, item->d_name);
#else
                int ignorable = disconnected && pinned.st_nlink == 0;
#endif
                if (ignorable) {
                    (void)flock(root, LOCK_UN); close(root); continue;
                }
                if (pinned.st_nlink > 0 && found == 0
                    && S_ISDIR(named.st_mode) && same(&pinned, &named)) {
                    int record_fd = dup(root);
                    if (record_fd >= 0) {
                        records = fdopendir(record_fd);
                        if (!records) close(record_fd);
                    }
                }
            }
        }
        if (!records) refused = 1;
        struct dirent *record;
        while (records && !refused) {
            errno = 0; record = readdir(records);
            if (!record) { refused = errno != 0; break; }
            const char *name = record->d_name;
            if (!strcmp(name, ".") || !strcmp(name, "..")
                || !strcmp(name, "stage") || !strcmp(name, "recovery")) continue;
            if (numbered(name, ".destination-building-")) {
                struct stat temporary;
                if (fstatat(root, name, &temporary, AT_SYMLINK_NOFOLLOW) != 0
                    || !S_ISREG(temporary.st_mode)) refused = 1;
                continue;
            }
            if (!numbered(name, "destination-")) { refused = 1; break; }
            int fd = openat(root, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
            size_t length = 0;
            struct stat record_id;
            char *bytes = fd < 0 || fstat(fd, &record_id) != 0
                || !S_ISREG(record_id.st_mode) ? NULL : read_bytes(fd, &length);
            const char magic[] = "LANDIN-PUBLICATION-1\n";
            const char end[] = "END-LANDIN-PUBLICATION-1\n";
            if (!bytes || length < sizeof magic + sizeof end - 2
                || memcmp(bytes, magic, sizeof magic - 1)
                || memcmp(bytes + length - (sizeof end - 1), end, sizeof end - 1)) refused = 1;
            else {
                char *after = NULL;
                size_t name_length = strtoul(bytes + sizeof magic - 1, &after, 10);
                size_t offset = after ? (size_t)(after - bytes) + 1 : length;
                if (!after || *after != '\n' || offset > length
                    || name_length > length - offset || !name_length
                    || memchr(bytes + offset, 0, name_length)
                    || memchr(bytes + offset, '/', name_length)) refused = 1;
                else {
                    char *record_target = bytes + offset;
                    if (add_name(&stage_names, record_target, name_length) != 0) refused = 1;
                    char slot[80];
                    snprintf(slot, sizeof slot, ".previous-%.10s", name + 12);
                    if (add_name(&recovery_names, slot, strlen(slot)) != 0) refused = 1;
                    snprintf(slot, sizeof slot, ".rollback-%.10s", name + 12);
                    if (add_name(&recovery_names, slot, strlen(slot)) != 0) refused = 1;
                    if (name_length == strlen(target)
                        && !memcmp(record_target, target, name_length)) refused = 1;
                    else if (!refused) {
                        /* Both records describe entries in this pinned parent.
                           Their public objects change during Capture/Install;
                           that must not turn an unrelated name into an alias.
                           General protected-input identity checks remain below. */
                        if (landin_entry_names_alias(parent, target,
                                                     stage_names->name) != 0)
                            refused = 1;
                        else barrier("discovery-distinct", stage_names->name);
                    }
                }
            }
            if (!refused && fd >= 0) {
                /* Query only: readers never create locks which another reader
                   could mistake for a producer. The actual sealed record is
                   pinned by fd; no PID number is used as authority. */
                struct flock lease = {0};
                lease.l_type = F_WRLCK; lease.l_whence = SEEK_SET;
                if (fcntl(fd, F_GETLK, &lease) == 0 && lease.l_type == F_WRLCK)
                    live_producer = 1;
            }
            if (fd >= 0) close(fd);
            free(bytes);
        }
        /* A producer may create arbitrary temporary stage entries. A live
           writer lease on a validated, sealed journal permits observing them,
           never adopting or deleting them. All journals/target names and the
           recovery allow-list remain strict. Liveness is a snapshot: if the
           producer dies after this query, each publication still captures and
           inspects its own destination and installs without replacement. */
        if (!refused && (!entries_known(root, "stage", stage_names, live_producer)
                         || !entries_known(root, "recovery", recovery_names, 0))) refused = 1;
        free_names(stage_names); free_names(recovery_names);
        if (records) closedir(records);
        if (root >= 0) { (void)flock(root, LOCK_UN); close(root); }
        if (refused) {
            reason(why, room, "retained or active publication for %s in %s/%s; inspect its destination records and recover the previous or new output before retrying",
                   target, parent_path, item->d_name);
        }
    }
    if (refused && !item)
        reason(why, room, "cannot inspect retained publication entries in %s; retry after checking the output directory",
               parent_path);
    closedir(directory); return refused ? -1 : 0;
}
static int write_journal(struct publication *p)
{
    char building[80];
    snprintf(p->journal, sizeof p->journal, "destination-%d", p->token);
    snprintf(building, sizeof building, ".destination-building-%d", p->token);
    int fd = openat(p->arena->root_fd, building,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (fstat(fd, &p->journal_id) == 0) p->journal_state = 1;
    barrier("journal-building", p->path);
    int result = dprintf(fd, "LANDIN-PUBLICATION-1\n%zu\n%s\nlogical=%s\nstaged=%s\nprevious=%s/%s\ncaptured-new=%s/%s\nexpected=%s device=%ju inode=%ju\nEND-LANDIN-PUBLICATION-1\n",
                         strlen(p->name), p->name, p->path, p->stage,
                         p->arena->recovery_path, p->recovery,
                         p->arena->recovery_path, p->rollback,
                         p->absent ? "absent" : "existing",
                         (uintmax_t)p->expected.st_dev, (uintmax_t)p->expected.st_ino);
    if (result >= 0) result = fstat(fd, &p->journal_id);
    if (result == 0) result = fsync(fd);
    /* Keep the first sealed journal's write lease until the whole arena is
       retired or quarantined. POSIX record locks are process-owned: closing
       ANY descriptor for this inode would release it. The owner never reopens
       its journal (live own arenas skip discovery; retirement uses fstatat).
       The first publication may Finish/Discard while other references remain. */
    int first = p->arena->producer_fd < 0;
    if (result == 0 && first) {
        struct flock lease = {0};
        lease.l_type = F_WRLCK; lease.l_whence = SEEK_SET;
        result = fcntl(fd, F_SETLK, &lease);
    }
    if (result == 0) {
        if (flock(p->arena->root_fd, LOCK_EX) != 0) { close(fd); return -1; }
        result = no_replace(p->arena->root_fd, building,
                            p->arena->root_fd, p->journal, 0);
        if (result == 0) p->journal_state = 2;
        if (result == 0 && fsync(p->arena->root_fd) != 0 && errno != EINVAL) result = -1;
        int error = errno;
        (void)flock(p->arena->root_fd, LOCK_UN); errno = error;
    }
    if (result == 0 && first) { p->arena->producer_fd = fd; fd = -1; }
    if (fd >= 0) { int error = errno; close(fd); errno = error; }
    if (result == 0) barrier("journal-ready", p->path);
    return result < 0 ? -1 : 0;
}
static int finish_journals(struct arena *arena)
{
    struct publication *p;
    for (p = publications; p; p = p->next) {
        struct stat st;
        if (p->arena != arena) continue;
        if (!p->finished || fstatat(arena->root_fd, p->journal, &st,
                                   AT_SYMLINK_NOFOLLOW) != 0
            || !same(&st, &p->journal_id)) { errno = EAGAIN; return -1; }
    }
    for (p = publications; p; p = p->next)
        if (p->arena == arena && unlinkat(arena->root_fd, p->journal, 0) != 0) return -1;
    return 0;
}
static void free_finished_arena(struct arena *arena)
{
    /* finish_journals needs the finished siblings until the last reference.
       Reclaim them only after every known entry and the root were removed. */
    struct publication **link = &publications;
    while (*link) {
        struct publication *p = *link;
        if (p->arena != arena) { link = &p->next; continue; }
        *link = p->next;
        if (p->expected_fd >= 0) close(p->expected_fd);
        free(p->bytes); free_tree(p->expected_tree); free_tree(p->fresh_tree);
        free(p->path); free(p->name); free(p->stage);
        free(p->recovery); free(p->rollback); free(p);
    }
    struct arena **at = &arenas;
    while (*at != arena) at = &(*at)->next;
    *at = arena->next;
    close(arena->private_fd); close(arena->recovery_fd);
    close(arena->root_fd); close(arena->parent);
    if (arena->producer_fd >= 0) close(arena->producer_fd);
    free(arena->path); free(arena->name); free(arena->recovery_path); free(arena);
}
/* A publication refused while it was being prepared has captured and
   installed nothing. Its arena holds the empty stage and recovery
   directories and at most the destination record this call created. Remove
   exactly those, the record by its identity and each directory by rmdir,
   which fails if anything else is inside; any doubt retains the workspace
   for the caller to name. A shared arena only loses this record. */
static int discard_unprepared(struct publication *p)
{
    struct arena *a = p->arena;
    struct stat st;
    char building[80];
    snprintf(building, sizeof building, ".destination-building-%d", p->token);
    if (p->journal_state) {
        const char *name = p->journal_state == 2 ? p->journal : building;
        if (fstatat(a->root_fd, name, &st, AT_SYMLINK_NOFOLLOW) != 0
            || !same(&st, &p->journal_id) || unlinkat(a->root_fd, name, 0) != 0)
            return -1;
    }
    if (a->refs > 1) { --a->refs; return 0; }
    if (a->producer_fd >= 0 || flock(a->root_fd, LOCK_EX) != 0) return -1;
    if (unlinkat(a->root_fd, "stage", AT_REMOVEDIR) != 0
        || unlinkat(a->root_fd, "recovery", AT_REMOVEDIR) != 0
        || unlinkat(a->parent, a->name, AT_REMOVEDIR) != 0) {
        int error = errno;
        (void)flock(a->root_fd, LOCK_UN); errno = error; return -1;
    }
    (void)flock(a->root_fd, LOCK_UN);
    a->refs = 0;
    free_finished_arena(a);
    p->arena = NULL;
    return 0;
}
/* What to do about a preparation refused for ERROR: the cause decides the
   route, so a full disk is not told to choose another output root. */
static const char *preparation_route(int error)
{
    switch (error) {
    case EFBIG: case ENOSPC:
#ifdef EDQUOT
    case EDQUOT:
#endif
        return "free space or raise the file-size limit, then retry";
    case EACCES: case EPERM: case EROFS:
        return "make the output directory writable, or choose another output path";
    case ELOOP: case ENOTDIR:
        return "choose an ordinary output root";
    case EINTR:
        return "the invocation was cancelled";
    default:
        return "check the output directory, or choose another output path";
    }
}
static int landin_publication_open_locked(const char *path, int deletion,
    const char *root,
                            int *token, char *stage, size_t stage_room,
                            char *why, size_t room)
{
    struct publication *p = calloc(1, sizeof *p);
    char *parent_path = NULL;
    int parent = -1, fd = -1, absence_conflict = 0;
    int require_absent = (deletion & LANDIN_PUBLICATION_REQUIRE_ABSENT) != 0;
    *token = 0; if (stage_room) *stage = 0;
    if (!p) goto fail;
    p->expected_fd = -1;
    if (deletion & ~(LANDIN_PUBLICATION_DELETE_ONLY | LANDIN_PUBLICATION_REQUIRE_ABSENT))
        { errno = EINVAL; goto fail; }
    deletion &= LANDIN_PUBLICATION_DELETE_ONLY;
    if (landin_cancellation_requested()) { errno = EINTR; goto fail; }
    p->path = strdup(path);
    parent = parent_for(path, root, &parent_path, &p->name, require_absent,
                        &p->anchor);
    if (parent < 0) goto fail;
    if (retained_workspace(parent, parent_path, p->name, why, room) != 0) {
        release_anchor(p);
        close(parent); free(parent_path); free(p->path); free(p->name); free(p);
        return -1;
    }
    barrier("before-snapshot", p->path);
    if (fstatat(parent, p->name, &p->expected, AT_SYMLINK_NOFOLLOW) == 0) {
        if (require_absent) { absence_conflict = 1; errno = EEXIST; goto fail; }
        if (S_ISDIR(p->expected.st_mode)) {
            p->expected_tree = snapshot_entry(parent, p->name);
            if (!p->expected_tree) goto fail;
        } else if (!S_ISREG(p->expected.st_mode)) { errno = ELOOP; goto fail; }
        if (S_ISREG(p->expected.st_mode)) {
        fd = openat(parent, p->name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        struct stat actual;
        if (fd < 0 || fstat(fd, &actual) != 0 || !same(&actual, &p->expected))
            { errno = EAGAIN; goto fail; }
        p->bytes = read_bytes(fd, &p->size);
        if (!p->bytes) goto fail;
        p->expected_fd = fd; fd = -1;
        }
    } else if (errno == ENOENT) p->absent = 1;
    else goto fail;
    p->arena = arena_for(parent, parent_path);
    if (!p->arena) goto fail;
    parent = -1;
    barrier("arena-ready", p->path);
    p->token = next_token++; p->deletion = deletion;
    size_t n = strlen(p->arena->path) + strlen(p->name) + 2;
    p->stage = malloc(n); p->recovery = malloc(40); p->rollback = malloc(40);
    if (!p->stage || !p->recovery || !p->rollback) goto fail;
    snprintf(p->stage, n, "%s/%s", p->arena->path, p->name);
    snprintf(p->recovery, 40, ".previous-%d", p->token);
    snprintf(p->rollback, 40, ".rollback-%d", p->token);
    if (strlen(p->stage) >= stage_room) { errno = ENAMETOOLONG; goto fail; }
    if (write_journal(p) != 0) goto fail;
    strcpy(stage, p->stage); *token = p->token;
    p->next = publications; publications = p;
    free(parent_path); reason(why, room, ""); return 0;
fail:
    {
        int failure = errno;
        if (absence_conflict) {
            reason(why, room, "cannot prepare %s: destination exists but absence was required; choose another output or restart with its existing contents preserved",
                   path);
        } else if (p && p->arena && discard_unprepared(p) == 0) {
            reason(why, room, "cannot prepare %s: %s; nothing was replaced and no publication workspace remains; %s",
                   path, strerror(failure), preparation_route(failure));
        } else if (p && p->arena) {
            quarantine(p->arena);
            char known[PATH_MAX + 80], location[PATH_MAX + 256];
            size_t length = strlen(p->arena->path);
            /* Arena paths end in /stage; the whole root remains inspectable
               when construction fails before returning a publication handle. */
            snprintf(known, sizeof known, "%.*s", (int)(length - 6),
                     p->arena->path);
            landin_publication_describe_entry
                (p->arena->root_fd, known, "", location, sizeof location);
            reason(why, room, "cannot prepare %s: %s; retained publication workspace %s; inspect its stage, recovery and destination records before retrying",
                   path, strerror(failure), location);
        } else {
            reason(why, room, "cannot prepare %s: %s; %s",
                   path, strerror(failure), preparation_route(failure));
        }
        errno = failure;
    }
    if (fd >= 0) close(fd);
    if (parent >= 0) close(parent);
    if (p) {
        release_anchor(p);
        if (p->expected_fd >= 0) close(p->expected_fd);
        free(p->path); free(p->name); free(p->bytes); free(p->stage);
        free(p->recovery); free(p->rollback);
        free_tree(p->expected_tree); free_tree(p->fresh_tree); free(p); }
    free(parent_path); return -1;
}
/* The pinned directory can move after anchor selection. Report an observed
   current pathname only after checking that spelling still names this fd;
   other hosts retain an identity-qualified last-known location. */
int landin_publication_describe_entry(int directory, const char *last_known,
                                      const char *entry, char *out, size_t room)
{
    char observed[PATH_MAX], identity[128];
    struct stat pinned, named;
    int valid = fstat(directory, &pinned) == 0;
    int resolved = 0;
    if (valid)
        reason(identity, sizeof identity, "directory device=%ju inode=%ju",
               (uintmax_t)pinned.st_dev, (uintmax_t)pinned.st_ino);
    else
        reason(identity, sizeof identity, "directory identity unavailable");
#ifdef __linux__
    char descriptor[64];
    snprintf(descriptor, sizeof descriptor, "/proc/self/fd/%d", directory);
    ssize_t size = readlink(descriptor, observed, sizeof observed - 1);
    if (size >= 0 && (size_t)size < sizeof observed - 1) {
        observed[size] = 0;
        resolved = valid;
    }
#elif defined(__APPLE__)
    resolved = valid && fcntl(directory, F_GETPATH, observed) == 0;
#endif
    if (resolved) {
        int fd = open(observed, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        resolved = fd >= 0 && fstat(fd, &named) == 0 && same(&named, &pinned);
        if (fd >= 0) close(fd);
    }
    if (resolved) {
        size_t n = strlen(observed);
        const char *slash = *entry && (n != 1 || observed[0] != '/') ? "/" : "";
        reason(out, room, "%s%s%s (%s)", observed, slash, entry, identity);
    } else {
        const char *slash = *entry && strcmp(last_known, "/") ? "/" : "";
        reason(out, room, "current directory path unavailable; last-known spelling %s%s%s; directory may have moved; %s",
               last_known, slash, entry, identity);
    }
    return resolved;
}
static void describe_recovery(const struct arena *a, char *out, size_t room)
{
    char location[PATH_MAX + 256];
    int resolved = landin_publication_describe_entry
        (a->recovery_fd, a->recovery_path, "", location, sizeof location);
    reason(out, room, "%s%s (output parent device=%ju inode=%ju)",
           resolved ? "observed current path " : "", location,
           (uintmax_t)a->parent_id.st_dev, (uintmax_t)a->parent_id.st_ino);
}
static int matches_bytes(int fd, const char *name, const char *bytes, size_t size)
{
    int file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    size_t actual_size;
    char *actual;
    int equal;
    if (file < 0) return 0;
    actual = read_bytes(file, &actual_size); close(file);
    equal = actual && actual_size == size && !memcmp(actual, bytes, size);
    free(actual); return equal;
}
static int protected_object(const struct stat *st, const char *const *paths,
                            size_t path_count, const uint64_t *ids, size_t count)
{
    for (size_t i = 0; i < count; ++i)
        if ((uint64_t)st->st_dev == ids[2*i] && (uint64_t)st->st_ino == ids[2*i+1])
            return 1;
    for (size_t i = 0; i < path_count; ++i) {
        struct stat input;
        if (stat(paths[i], &input) == 0 && same(st, &input)) return 1;
    }
    return 0;
}
static int protected_tree(const struct tree_entry *tree,
                           const char *const *paths, size_t path_count,
                           const uint64_t *ids, size_t count)
{
    for (; tree; tree = tree->next)
        if (protected_object(&tree->identity, paths, path_count, ids, count)
            || protected_tree(tree->children, paths, path_count, ids, count)) return 1;
    return 0;
}
static int landin_publication_step_locked(int token, int action,
    const char *const *paths,
                            size_t path_count, const uint64_t *ids, size_t count,
                            char *why, size_t room)
{
    struct publication *p = lookup(token);
    struct stat st;
    int parent, private_fd, recovery_fd;
    reason(why, room, "");
    if (!p) return 0;
    if (p->finished && p->finish_failed) {
        char location[PATH_MAX + 256];
        describe_recovery(p->arena, location, sizeof location);
        reason(why, room, "retained publication recovery directory %s; inspect it before retrying cleanup",
               location);
        errno = EBUSY; return -1;
    }
    if (p->finished) return 0;
    parent = p->arena->parent; private_fd = p->arena->private_fd;
    recovery_fd = p->arena->recovery_fd;
    if (action <= 2 && landin_cancellation_requested()) { errno = EINTR; goto fail; }
    if (action == 0) {
        if (p->deletion) {
            if (!p->absent && !S_ISREG(p->expected.st_mode)) {
                reason(why, room, "%s is a directory, not a stale generated file; choose another output",
                       p->path); return -1;
            }
            return 0;
        }
        if (fstatat(private_fd, p->name, &p->fresh, AT_SYMLINK_NOFOLLOW) != 0
            || (!S_ISREG(p->fresh.st_mode) && !S_ISDIR(p->fresh.st_mode))) goto fail;
        if (!p->absent
            && S_ISDIR(p->expected.st_mode) != S_ISDIR(p->fresh.st_mode)) {
            /* Snapshot a private staged directory so abort may remove only
               this verified tree. The public destination remains untouched. */
            if (S_ISDIR(p->fresh.st_mode)) {
                p->fresh_tree = snapshot_entry(private_fd, p->name);
                if (!p->fresh_tree) goto fail;
            }
            reason(why, room, "%s is %s, but the generated artifact is %s; choose another output",
                   p->path, S_ISDIR(p->expected.st_mode) ? "a directory" : "a regular file",
                   S_ISDIR(p->fresh.st_mode) ? "a directory" : "a regular file");
            return -1;
        }
        if (S_ISREG(p->fresh.st_mode)) {
            int fd = openat(private_fd, p->name, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
            if (fd < 0) goto fail;
            int synced = fsync(fd); close(fd);
            if (synced != 0) goto fail;
            p->unchanged = !p->absent && matches_bytes(private_fd, p->name,
                                                       p->bytes, p->size);
        }
        if (S_ISDIR(p->fresh.st_mode)) {
            p->fresh_tree = snapshot_entry(private_fd, p->name);
            if (!p->fresh_tree) goto fail;
            p->unchanged = p->expected_tree
                && equal_tree(p->expected_tree, p->fresh_tree, 0);
        }
        barrier("validated", p->path); return 0;
    }
    if (action == 1) {
        if (p->captured || p->installed || p->rollback_pending) {
            errno = EALREADY; goto fail;
        }
        if (path_count && landin_overlaps_any(p->path, paths, path_count) != 0) {
            reason(why, room, "%s aliases a protected input name; choose another output",
                   p->path); return -1;
        }
        barrier("before-capture", p->path);
        if (renameat(parent, p->name, recovery_fd, p->recovery) != 0) {
            if (errno == ENOENT && p->absent) return 0;
            goto fail;
        }
        p->captured = 1;
        barrier("captured", p->path);
        if (fstatat(recovery_fd, p->recovery, &st, AT_SYMLINK_NOFOLLOW) != 0
            || p->absent || !same(&st, &p->expected)
            || protected_object(&st, paths, path_count, ids, count)
            || (S_ISREG(st.st_mode)
                && !matches_bytes(recovery_fd, p->recovery, p->bytes, p->size))
            || (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode))) {
            char location[PATH_MAX + 256];
            describe_recovery(p->arena, location, sizeof location);
            reason(why, room, "%s changed or aliases an input; rerun or choose another output; recovery directory %s; previous entry %s",
                   p->path, location, p->recovery); return -1;
        }
        if (p->expected_tree) {
            struct tree_entry *captured = snapshot_entry(recovery_fd, p->recovery);
            int matches = captured && equal_tree(p->expected_tree, captured, 1)
                && !protected_tree(captured, paths, path_count, ids, count);
            free_tree(captured);
            if (!matches) { errno = EAGAIN; goto fail; }
        }
        p->capture_valid = 1;
        return 0;
    }
    if (action == 2) {
        if (p->deletion) return 0;
        barrier("before-install", p->path);
        if (p->unchanged) {
            if (no_replace(recovery_fd, p->recovery, parent, p->name,
                           S_ISDIR(p->expected.st_mode)) != 0) goto fail;
            p->captured = 0; return 0;
        }
        if (fstatat(private_fd, p->name, &st, AT_SYMLINK_NOFOLLOW) != 0
            || !same(&st, &p->fresh)) { errno = EAGAIN; goto fail; }
        if (no_replace(private_fd, p->name, parent, p->name,
                       S_ISDIR(p->fresh.st_mode)) != 0) goto fail;
        p->installed = 1; barrier("installed", p->path);
        if (fsync(parent) != 0 && errno != EINVAL) goto fail;
        return 0;
    }
    if (action == 3) {
        if (p->rollback_pending) { errno = EALREADY; goto fail; }
        if (p->installed) {
            barrier("before-rollback-capture", p->path);
            if (renameat(parent, p->name, recovery_fd, p->rollback) != 0) {
                if (errno != ENOENT) goto fail;
            } else {
                p->rollback_pending = 1;
                barrier("rollback-captured", p->path);
                if (fstatat(recovery_fd, p->rollback, &st, AT_SYMLINK_NOFOLLOW) != 0)
                    goto fail;
                if (!same(&st, &p->fresh)) {
                    if (no_replace(recovery_fd, p->rollback, parent, p->name,
                                   S_ISDIR(st.st_mode)) != 0) goto fail;
                    p->rollback_pending = 0;
                    errno = EAGAIN; goto fail;
                }
                if (S_ISDIR(st.st_mode)) {
                    if (!p->fresh_tree || discard_tree(recovery_fd, p->rollback,
                                                        p->fresh_tree) != 0) goto fail;
                } else if (unlinkat(recovery_fd, p->rollback, 0) != 0) goto fail;
                p->rollback_pending = 0;
            }
            p->installed = 0;
        }
        if (p->captured) {
            if (fstatat(recovery_fd, p->recovery, &st, AT_SYMLINK_NOFOLLOW) != 0) goto fail;
            if (no_replace(recovery_fd, p->recovery, parent, p->name,
                           S_ISDIR(st.st_mode)) != 0) goto fail;
            p->captured = 0;
        }
        return 0;
    }
    if (action == 4) {
        /* Only proven ordinary old outputs may be discarded. Exceptional
           captured entries are retained even when the group is abandoned. */
        if (p->captured) {
            if (fstatat(recovery_fd, p->recovery, &st, AT_SYMLINK_NOFOLLOW) != 0)
                goto fail;
            /* A captured copy that is not the snapshot is kept, and the
               reason must not borrow a stale errno for it. */
            if (p->absent || !p->capture_valid || !same(&st, &p->expected))
                { errno = EAGAIN; goto fail; }
            if (S_ISDIR(st.st_mode)) {
                if (!p->expected_tree || discard_tree(recovery_fd, p->recovery,
                                                       p->expected_tree) != 0) goto fail;
            } else if (!S_ISREG(st.st_mode)
                       || unlinkat(recovery_fd, p->recovery, 0) != 0) goto fail;
            p->captured = 0;
        }
        if (fstatat(private_fd, p->name, &st, AT_SYMLINK_NOFOLLOW) == 0) {
            /* No recursive cleanup: a tool-created directory may contain
               evidence the transaction cannot establish ownership of. */
            if (S_ISDIR(st.st_mode)) {
                if (!p->fresh_tree || discard_tree(private_fd, p->name,
                                                   p->fresh_tree) != 0) goto fail;
            } else if (!S_ISREG(st.st_mode)
                       || unlinkat(private_fd, p->name, 0) != 0) goto fail;
        } else if (errno != ENOENT) goto fail;
        p->finished = 1;
        release_anchor(p);
        if (--p->arena->refs == 0) {
            if (flock(p->arena->root_fd, LOCK_EX) != 0) goto fail;
            /* rmdir succeeds only when every known artifact is gone. */
            if (unlinkat(p->arena->root_fd, "stage", AT_REMOVEDIR) != 0
                || unlinkat(p->arena->root_fd, "recovery", AT_REMOVEDIR) != 0
                || finish_journals(p->arena) != 0
                || unlinkat(parent, p->arena->name, AT_REMOVEDIR) != 0) {
                int error = errno;
                quarantine(p->arena);
                p->finish_failed = 1;
                (void)flock(p->arena->root_fd, LOCK_UN);
                char location[PATH_MAX + 256];
                describe_recovery(p->arena, location, sizeof location);
                reason(why, room, "retained publication directory %s: %s",
                       location, strerror(error)); return -1;
            }
            (void)flock(p->arena->root_fd, LOCK_UN);
            free_finished_arena(p->arena);
            return 0;
        }
        if (p->expected_fd >= 0) { close(p->expected_fd); p->expected_fd = -1; }
        free(p->bytes); p->bytes = NULL;
        free_tree(p->expected_tree); p->expected_tree = NULL;
        free_tree(p->fresh_tree); p->fresh_tree = NULL;
        return 0;
    }
    errno = EINVAL;
fail:
    {
        int error = errno;
        if (action == 3 || action == 4) quarantine(p->arena);
        if (action == 4 && p->finished) p->finish_failed = 1;
        char location[PATH_MAX + 256], previous[96] = "", captured[96] = "";
        describe_recovery(p->arena, location, sizeof location);
        /* Name only the recovery entries this publication holds: a reader
           told of a previous copy that was never captured looks for it. */
        if (p->captured)
            snprintf(previous, sizeof previous, "; previous entry %s", p->recovery);
        if (p->rollback_pending)
            snprintf(captured, sizeof captured, "; captured new or concurrent entry %s",
                     p->rollback);
        reason(why, room, "%s %s failed: %s; recovery directory %s%s%s",
               action == 3 ? "rollback of" : action == 4 ? "cleanup of" : "publication of",
               p->path, strerror(error), location, previous, captured);
        return -1;
    }
}

/* Public registry boundaries. No lock spans a child process lifetime. */
int landin_publication_stage_directory(const char *text)
{
    registry_lock();
    int result = landin_publication_stage_directory_locked(text);
    registry_unlock();
    return result;
}
int landin_publication_rebase_argument(const char *arg, int directory, char *out,
    size_t room)
{
    registry_lock();
    int result = landin_publication_rebase_argument_locked(arg, directory, out, room);
    registry_unlock();
    return result;
}
int landin_publication_stage_write(const char *path, const char *bytes, size_t size)
{
    registry_lock();
    int result = landin_publication_stage_write_locked(path, bytes, size);
    registry_unlock();
    return result;
}
int landin_publication_stage_write_reason(const char *path, const char *bytes, size_t size,
    char *reason, size_t room)
{
    registry_lock();
    int result = landin_publication_stage_write_locked(path, bytes, size);
    int error = errno;
    if (room > 0) snprintf(reason, room, "%s",
                           result == -1 ? strerror(error) : "");
    registry_unlock();
    errno = error;
    return result;
}

int landin_publication_stage_mkdir(const char *path)
{
    registry_lock();
    int result = landin_publication_stage_mkdir_locked(path);
    registry_unlock();
    return result;
}
int landin_read_snapshot(const char *path, char **bytes, size_t *size, uint64_t *device,
    uint64_t *inode)
{
    registry_lock();
    int result = landin_read_snapshot_locked(path, bytes, size, device, inode);
    registry_unlock();
    return result;
}
int landin_publication_open(const char *path, int deletion, const char *root, int *token,
    char *stage, size_t stage_room, char *why, size_t room)
{
    registry_lock();
    int result = landin_publication_open_locked(path, deletion, root, token, stage,
    stage_room, why, room);
    registry_unlock();
    return result;
}
int landin_publication_step(int token, int action, const char *const *paths,
    size_t path_count, const uint64_t *ids, size_t count, char *why, size_t room)
{
    registry_lock();
    int result = landin_publication_step_locked(token, action, paths, path_count, ids,
    count, why, room);
    registry_unlock();
    return result;
}
