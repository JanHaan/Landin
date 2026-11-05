#ifdef __linux__
#define _GNU_SOURCE
#endif
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include "landin_publication.h"
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif

struct arena {
    int parent, private_fd;
    struct stat parent_id;
    char *path, *name;
    unsigned refs;
    struct arena *next;
};
struct publication {
    int token, absent, deletion, captured, installed, unchanged, finished;
    struct arena *arena;
    char *path, *name, *stage, *recovery, *rollback;
    struct stat expected, fresh;
    char *bytes;
    size_t size;
    struct tree_entry *expected_tree, *fresh_tree;
    struct publication *next;
};
static struct arena *arenas;
static struct publication *publications;
static int next_token = 1;
extern int landin_cancellation_requested(void);
static landin_publication_hook fault_hook;
void landin_publication_set_hook(landin_publication_hook hook) { fault_hook = hook; }
static void barrier(const char *event, const char *path)
{ if (fault_hook) fault_hook(event, path); }
static void reason(char *out, size_t room, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    if (room) vsnprintf(out, room, format, args);
    va_end(args);
}
static int same(const struct stat *a, const struct stat *b)
{ return a->st_dev == b->st_dev && a->st_ino == b->st_ino; }
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
    *size = used;
    return bytes;
}
struct tree_entry {
    char *name, *bytes;
    size_t size;
    struct stat identity;
    struct tree_entry *children, *next;
};
static void free_tree(struct tree_entry *tree)
{
    while (tree) {
        struct tree_entry *next = tree->next;
        free_tree(tree->children); free(tree->name); free(tree->bytes);
        free(tree); tree = next;
    }
}
static struct tree_entry *snapshot_entry(int parent, const char *name)
{
    struct tree_entry *entry = calloc(1, sizeof *entry);
    int fd = -1;
    struct stat actual;
    if (!entry) return NULL;
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
    close(fd); return entry;
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
static int discard_tree(int parent, const char *name, const struct tree_entry *tree)
{
    struct stat actual;
    if (fstatat(parent, name, &actual, AT_SYMLINK_NOFOLLOW) != 0
        || !same(&actual, &tree->identity)) { errno = EAGAIN; return -1; }
    if (S_ISDIR(actual.st_mode)) {
        int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        const struct tree_entry *child;
        if (fd < 0) return -1;
        for (child = tree->children; child; child = child->next)
            if (discard_tree(fd, child->name, child) != 0) { close(fd); return -1; }
        close(fd);
        return unlinkat(parent, name, AT_REMOVEDIR);
    }
    return unlinkat(parent, name, 0);
}
static struct arena *stage_arena(const char *path, const char **relative)
{
    struct arena *a;
    for (a = arenas; a; a = a->next) {
        size_t n = strlen(a->path);
        if (a->refs && !strncmp(path, a->path, n) && path[n] == '/') {
            *relative = path + n + 1; return a;
        }
    }
    return NULL;
}
static int stage_open(const char *path, int flags, mode_t mode)
{
    const char *relative;
    struct arena *a = stage_arena(path, &relative);
    if (!a) return -2;
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
int landin_publication_stage_directory(const char *text)
{
    struct arena *a;
    for (a = arenas; a; a = a->next) {
        const char *found = strstr(text, a->path);
        if (a->refs && found && found[strlen(a->path)] == '/') {
            int fd = dup(a->private_fd);
            return fd < 0 ? -2 : fd;
        }
    }
    return -1;
}
int landin_publication_rebase_argument(const char *arg, int directory,
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
            if (!a->refs || strncmp(arg, a->path, n) || arg[n] != '/') continue;
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
    out[used] = 0; return 0;
}
int landin_publication_stage_write(const char *path, const char *bytes, size_t size)
{
    int fd = stage_open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) return fd;
    size_t used = 0;
    while (used < size) {
        ssize_t wrote = write(fd, bytes + used, size - used);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) { close(fd); return -1; }
        used += (size_t)wrote;
    }
    int result = fsync(fd); close(fd); return result;
}
int landin_read_snapshot(const char *path, char **bytes, size_t *size,
                         uint64_t *device, uint64_t *inode)
{
    struct stat st;
    int fd = stage_open(path, O_RDONLY | O_NONBLOCK, 0), result = -1;
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
static int parent_for(const char *path, const char *root, char **parent_path,
                      char **name)
{
    char *absolute = NULL, *root_abs = NULL, *walk = NULL, *save = NULL, *part;
    int fd = -1;
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
    if (*root) {
        snprintf(root_abs, n, "%s%s%s", *root == '/' ? "" : cwd,
                 *root == '/' ? "" : "/", root);
        size_t len = strlen(root_abs);
        while (len > 1 && root_abs[len-1] == '/') root_abs[--len] = 0;
        if (strncmp(absolute, root_abs, len)
            || (absolute[len] && absolute[len] != '/')) { errno = EINVAL; goto done; }
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
            if (!walk || fd < 0) goto done;
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
    for (a = arenas; a; a = a->next) if (a->refs && same(&st, &a->parent_id)) {
        close(parent); ++a->refs; return a;
    }
    a = calloc(1, sizeof *a);
    if (!a) return NULL;
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
    a->private_fd = openat(parent, a->name,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (a->private_fd < 0) { free(a->name); free(a->path); free(a); return NULL; }
    a->parent = parent; a->parent_id = st; a->refs = 1;
    a->next = arenas; arenas = a;
    return a;
}
int landin_publication_open(const char *path, int deletion, const char *root,
                            int *token, char *stage, size_t stage_room,
                            char *why, size_t room)
{
    struct publication *p = calloc(1, sizeof *p);
    char *parent_path = NULL;
    int parent = -1, fd = -1;
    *token = 0; if (stage_room) *stage = 0;
    if (!p) goto fail;
    if (landin_cancellation_requested()) { errno = EINTR; goto fail; }
    p->path = strdup(path);
    parent = parent_for(path, root, &parent_path, &p->name);
    if (parent < 0) goto fail;
    if (fstatat(parent, p->name, &p->expected, AT_SYMLINK_NOFOLLOW) == 0) {
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
        close(fd); fd = -1;
        if (!p->bytes) goto fail;
        }
    } else if (errno == ENOENT) p->absent = 1;
    else goto fail;
    p->arena = arena_for(parent, parent_path);
    if (!p->arena) goto fail;
    parent = -1;
    p->token = next_token++; p->deletion = deletion;
    size_t n = strlen(p->arena->path) + strlen(p->name) + 2;
    p->stage = malloc(n); p->recovery = malloc(40); p->rollback = malloc(40);
    if (!p->stage || !p->recovery || !p->rollback) goto fail;
    snprintf(p->stage, n, "%s/%s", p->arena->path, p->name);
    snprintf(p->recovery, 40, ".previous-%d", p->token);
    snprintf(p->rollback, 40, ".rollback-%d", p->token);
    if (strlen(p->stage) >= stage_room) { errno = ENAMETOOLONG; goto fail; }
    strcpy(stage, p->stage); *token = p->token;
    p->next = publications; publications = p;
    free(parent_path); reason(why, room, ""); return 0;
fail:
    reason(why, room, "cannot prepare %s: %s; choose an ordinary output root",
           path, strerror(errno));
    if (fd >= 0) close(fd);
    if (parent >= 0) close(parent);
    if (p) { free(p->path); free(p->name); free(p->bytes); free(p->stage);
        free(p->recovery); free(p->rollback);
        free_tree(p->expected_tree); free_tree(p->fresh_tree); free(p); }
    free(parent_path); return -1;
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
int landin_publication_step(int token, int action, const char *const *paths,
                            size_t path_count, const uint64_t *ids, size_t count,
                            char *why, size_t room)
{
    struct publication *p = lookup(token);
    struct stat st;
    int parent, private_fd;
    reason(why, room, "");
    if (!p || p->finished) return 0;
    parent = p->arena->parent; private_fd = p->arena->private_fd;
    if (action <= 2 && landin_cancellation_requested()) { errno = EINTR; goto fail; }
    if (action == 0) {
        if (p->deletion) return 0;
        if (fstatat(private_fd, p->name, &p->fresh, AT_SYMLINK_NOFOLLOW) != 0
            || (!S_ISREG(p->fresh.st_mode) && !S_ISDIR(p->fresh.st_mode))) goto fail;
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
        barrier("before-capture", p->path);
        if (renameat(parent, p->name, private_fd, p->recovery) != 0) {
            if (errno == ENOENT && p->absent) return 0;
            goto fail;
        }
        p->captured = 1;
        barrier("captured", p->path);
        if (fstatat(private_fd, p->recovery, &st, AT_SYMLINK_NOFOLLOW) != 0
            || p->absent || !same(&st, &p->expected)
            || protected_object(&st, paths, path_count, ids, count)
            || (S_ISREG(st.st_mode)
                && !matches_bytes(private_fd, p->recovery, p->bytes, p->size))
            || (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode))) {
            reason(why, room, "%s changed or aliases an input; rerun or choose another output; recovery %s/%s",
                   p->path, p->arena->path, p->recovery); return -1;
        }
        if (p->expected_tree) {
            struct tree_entry *captured = snapshot_entry(private_fd, p->recovery);
            int matches = captured && equal_tree(p->expected_tree, captured, 1);
            free_tree(captured);
            if (!matches) { errno = EAGAIN; goto fail; }
        }
        return 0;
    }
    if (action == 2) {
        if (p->deletion) return 0;
        barrier("before-install", p->path);
        if (p->unchanged) {
            if (no_replace(private_fd, p->recovery, parent, p->name,
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
        if (p->installed) {
            barrier("before-rollback-capture", p->path);
            if (renameat(parent, p->name, private_fd, p->rollback) != 0) {
                if (errno != ENOENT) goto fail;
            } else {
                if (fstatat(private_fd, p->rollback, &st, AT_SYMLINK_NOFOLLOW) != 0
                    || !same(&st, &p->fresh)) {
                    if (no_replace(private_fd, p->rollback, parent, p->name,
                                   S_ISDIR(st.st_mode)) != 0) goto fail;
                    errno = EAGAIN; goto fail;
                }
                if (S_ISDIR(st.st_mode)) {
                    if (!p->fresh_tree || discard_tree(private_fd, p->rollback,
                                                        p->fresh_tree) != 0) goto fail;
                } else if (unlinkat(private_fd, p->rollback, 0) != 0) goto fail;
            }
            p->installed = 0;
        }
        if (p->captured) {
            if (fstatat(private_fd, p->recovery, &st, AT_SYMLINK_NOFOLLOW) != 0) goto fail;
            if (no_replace(private_fd, p->recovery, parent, p->name,
                           S_ISDIR(st.st_mode)) != 0) goto fail;
            p->captured = 0;
        }
        return 0;
    }
    if (action == 4) {
        /* Only proven ordinary old outputs may be discarded. Exceptional
           captured entries are retained even when the group is abandoned. */
        if (p->captured) {
            if (fstatat(private_fd, p->recovery, &st, AT_SYMLINK_NOFOLLOW) != 0
                || p->absent || !same(&st, &p->expected)) goto fail;
            if (S_ISDIR(st.st_mode)) {
                if (!p->expected_tree || discard_tree(private_fd, p->recovery,
                                                       p->expected_tree) != 0) goto fail;
            } else if (!S_ISREG(st.st_mode)
                       || unlinkat(private_fd, p->recovery, 0) != 0) goto fail;
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
        if (--p->arena->refs == 0) {
            /* rmdir succeeds only when every known artifact is gone. */
            if (unlinkat(parent, p->arena->name, AT_REMOVEDIR) != 0) {
                reason(why, room, "retained publication directory %s: %s",
                       p->arena->path, strerror(errno)); return -1;
            }
        }
        return 0;
    }
    errno = EINVAL;
fail:
    reason(why, room, "publication of %s failed: %s; retained recovery directory %s",
           p->path, strerror(errno), p->arena->path);
    return -1;
}
