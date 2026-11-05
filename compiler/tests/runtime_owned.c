#ifndef __FreeBSD__
#define _POSIX_C_SOURCE 200809L
#endif
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "landin_publication.h"
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
int landin_tool_capture(char *, size_t);
int landin_tool_capture_read(int, char **, size_t *);
void landin_tool_capture_free(char *);
int landin_tool_capture_close(int, char *, size_t);
int landin_private_directory(const char *, char *, size_t);
int landin_remove_tree(const char *);
const char *landin_remove_tree_reason(void);
void landin_private_directory_set_hook(void (*)(const char *, const char *));
int landin_private_mkdir(const char *);
int landin_private_write(const char *, const char *, size_t);
int landin_private_read_descriptor(const char *);
int landin_private_argument_directory(const char *);
int landin_private_rebase_argument(const char *, int, char *, size_t);
int landin_private_path_current(const char *);
int landin_read_snapshot(const char *, char **, size_t *, uint64_t *, uint64_t *);
void landin_snapshot_free(char *);
int landin_tool_start_in_directory(char *const [], char *const [], int, int,
                                    int, int, int, int *);
int landin_tool_wait(int, int *, int);
static char scratch[4096], why[16384], race_saved[4096], race_actual[4096];
static int race_kind;
static unsigned passed;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, \
    "runtime ownership failure line %d: %s errno=%d (%s), %s\n", \
    __LINE__, #x, errno, strerror(errno), why); exit(1); } } while (0)
static void join(char *out, const char *a, const char *b)
{
    size_t n = strlen(a), m = strlen(b);
    REQUIRE(n + m + 2 < 4096);
    memcpy(out, a, n); out[n] = '/'; memcpy(out + n + 1, b, m + 1);
}
static const char *leaf(const char *path)
{ const char *at = strrchr(path, '/'); return at ? at + 1 : path; }
static void put(const char *name, const char *text)
{
    int fd = open(name, O_CREAT | O_EXCL | O_WRONLY, 0600);
    REQUIRE(fd >= 0 && write(fd, text, strlen(text)) == (ssize_t)strlen(text));
    REQUIRE(close(fd) == 0);
}
static int content(const char *name, const char *text)
{
    char bytes[128]; int fd = open(name, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return 0;
    ssize_t count = read(fd, bytes, sizeof bytes); close(fd);
    return count == (ssize_t)strlen(text) && !memcmp(bytes, text, (size_t)count);
}
static void absent(const char *name)
{ struct stat st; REQUIRE(lstat(name, &st) != 0 && errno == ENOENT); }
static void parent(char *out, const char *name)
{ join(out, scratch, name); REQUIRE(mkdir(out, 0700) == 0); REQUIRE(setenv("TMPDIR", out, 1) == 0); }
static void capture_normal(void)
{
    char directory[4096], root[4096], *bytes;
    const char binary[] = {'\0', 'x', (char)255, '\0'};
    size_t size; struct stat st, selected;
    parent(directory, "capture-normal");
    int fd = landin_tool_capture(root, sizeof root);
    REQUIRE(fd >= 0 && fstat(fd, &st) == 0 && stat(directory, &selected) == 0);
    REQUIRE(st.st_nlink == 0 && st.st_dev == selected.st_dev);
    REQUIRE(write(fd, binary, sizeof binary) == sizeof binary);
    REQUIRE(landin_tool_capture_read(fd, &bytes, &size) == 0);
    REQUIRE(size == sizeof binary && !memcmp(bytes, binary, size));
    landin_tool_capture_free(bytes);
    REQUIRE(landin_tool_capture_close(fd, why, sizeof why) == 0);
    absent(root); ++passed;
}
static void capture_ancestor(void)
{
    char directory[4096], root[4096], moved[4096], foreign[4096], file[4096];
    char *bytes; size_t size;
    parent(directory, "capture-ancestor");
    int fd = landin_tool_capture(root, sizeof root);
    REQUIRE(fd >= 0 && write(fd, "owned", 5) == 5);
    join(moved, scratch, "capture-original-parent"); REQUIRE(rename(directory, moved) == 0);
    REQUIRE(mkdir(directory, 0700) == 0); join(foreign, directory, leaf(root));
    REQUIRE(mkdir(foreign, 0700) == 0); join(file, foreign, "capture"); put(file, "foreign-save");
    REQUIRE(landin_tool_capture_read(fd, &bytes, &size) == 0);
    REQUIRE(size == 5 && !memcmp(bytes, "owned", 5)); landin_tool_capture_free(bytes);
    REQUIRE(landin_tool_capture_close(fd, why, sizeof why) == 0);
    REQUIRE(content(file, "foreign-save")); join(root, moved, leaf(foreign)); absent(root);
    ++passed;
}
static void capture_replaced_root(void)
{
    char directory[4096], root[4096], moved[4096], file[4096];
    parent(directory, "capture-replaced-root");
    int fd = landin_tool_capture(root, sizeof root);
    REQUIRE(fd >= 0); join(moved, directory, "saved-owned-root");
    REQUIRE(rename(root, moved) == 0 && mkdir(root, 0700) == 0);
    join(file, root, "sentinel"); put(file, "foreign-save");
    REQUIRE(landin_tool_capture_close(fd, why, sizeof why) != 0);
    REQUIRE(content(file, "foreign-save") && strstr(why, "preserved"));
    REQUIRE(fcntl(fd, F_GETFD) == -1 && errno == EBADF); ++passed;
}
static void root_normal(void)
{
    char directory[4096], root[4096], file[4096], link[4096], outside[4096];
    parent(directory, "root-normal");
    REQUIRE(landin_private_directory("refine-run-", root, sizeof root) == 0);
    join(file, root, "owned"); put(file, "owned");
    join(outside, directory, "outside"); REQUIRE(mkdir(outside, 0700) == 0);
    join(file, outside, "sentinel"); put(file, "outside-save");
    join(link, root, "link"); REQUIRE(symlink(outside, link) == 0);
    REQUIRE(landin_remove_tree(root) == 1); absent(root);
    REQUIRE(content(file, "outside-save"));
    REQUIRE(landin_remove_tree(root) == 0);
    REQUIRE(mkdir(root, 0700) == 0); join(file, root, "sentinel"); put(file, "new-save");
    REQUIRE(landin_remove_tree(root) == -1 && content(file, "new-save")); ++passed;
}
static void root_ancestor_and_io(void)
{
    char directory[4096], root[4096], moved[4096], foreign[4096], relative[4096];
    char headers[4096], file[4096], actual[4096], stage[4096], *bytes;
    size_t size; uint64_t device, inode; int token, child, status;
    parent(directory, "root-ancestor");
    REQUIRE(landin_private_directory("refine-bindings-", root, sizeof root) == 0);
    join(moved, scratch, "root-original-parent"); REQUIRE(rename(directory, moved) == 0);
    REQUIRE(mkdir(directory, 0700) == 0); join(foreign, directory, leaf(root));
    REQUIRE(mkdir(foreign, 0700) == 0); join(headers, foreign, "headers");
    REQUIRE(mkdir(headers, 0700) == 0); join(file, headers, "input.h"); put(file, "foreign-save");
    REQUIRE(landin_private_mkdir(headers) == 0);
    REQUIRE(landin_private_write(file, "owned", 5) == 0 && content(file, "foreign-save"));
    REQUIRE(landin_read_snapshot(file, &bytes, &size, &device, &inode) == 0);
    REQUIRE(size == 5 && !memcmp(bytes, "owned", 5)); landin_snapshot_free(bytes);
    join(actual, moved, leaf(root)); join(headers, actual, "headers"); join(actual, headers, "input.h");
    REQUIRE(content(actual, "owned"));
    join(file, root, "product");
    REQUIRE(landin_publication_open(file, 0, "", &token, stage, sizeof stage, why, sizeof why) == 0);
    REQUIRE(landin_publication_stage_write(stage, "product", 7) == 0);
    for (int action = 0; action <= 2; ++action)
        REQUIRE(landin_publication_step(token, action, NULL, 0, NULL, 0, why, sizeof why) == 0);
    REQUIRE(landin_publication_step(token, 4, NULL, 0, NULL, 0, why, sizeof why) == 0);
    join(actual, moved, leaf(root)); join(headers, actual, "product"); REQUIRE(content(headers, "product"));
    join(file, root, "tool-result");
    int fd = landin_private_argument_directory(file);
    REQUIRE(fd >= 0 && landin_private_rebase_argument(file, fd, relative, sizeof relative) == 0);
    int capture = landin_tool_capture(stage, sizeof stage);
    REQUIRE(capture >= 0);
    char *args[] = {"/bin/sh", "-c", "printf tool-owned > \"$1\"", "control", relative, NULL};
    REQUIRE(landin_tool_start_in_directory(args, NULL, 0, -1, capture, -1, fd, &child) == 0);
    REQUIRE(landin_tool_wait(child, &status, 0) == child && status == 0); close(fd);
    REQUIRE(landin_tool_capture_close(capture, why, sizeof why) == 0);
    join(actual, moved, leaf(root)); join(headers, actual, "tool-result"); REQUIRE(content(headers, "tool-owned"));
    join(headers, foreign, "tool-result"); absent(headers);
    REQUIRE(!landin_private_path_current(file));
    REQUIRE(landin_remove_tree(root) == 1);
    join(headers, foreign, "headers"); join(file, headers, "input.h"); REQUIRE(content(file, "foreign-save"));
    ++passed;
}
static void root_race(const char *event, const char *path)
{
    if (!race_kind || strcmp(event, "before-capture")) return;
    race_kind = 0;
    REQUIRE(rename(path, race_saved) == 0 && mkdir(path, 0700) == 0);
    char sentinel[4096]; join(sentinel, path, "sentinel"); put(sentinel, "raced-save");
}
static void retained_entry(const char *reason, const char *actual_parent,
                             char *recovery)
{
    const char *retained = strstr(reason, "retained at ");
    REQUIRE(retained != NULL); retained += strlen("retained at ");
    if (!strncmp(retained, "last-known spelling ", 20)) {
        char path[4096];
        REQUIRE(strstr(reason, "device=") && strstr(reason, "inode=")
                && strstr(reason, "may have moved"));
        DIR *listing = opendir(actual_parent); REQUIRE(listing != NULL);
        struct dirent *entry; int found = 0;
        while ((entry = readdir(listing)) != NULL) {
            if (strncmp(entry->d_name, ".refine-cleanup-", 16)) continue;
            join(path, actual_parent, entry->d_name); found = 1; break;
        }
        REQUIRE(closedir(listing) == 0 && found);
        join(recovery, path, "entry");
    } else {
        const char *end = strchr(retained, ';');
        REQUIRE(end && end - retained < 4000 && strstr(retained, actual_parent));
        memcpy(recovery, retained, (size_t)(end - retained));
        recovery[end - retained] = 0;
    }
}
static void root_capture_inspection(void)
{
    char directory[4096], root[4096], file[4096];
    parent(directory, "root-capture");
    REQUIRE(landin_private_directory("refine-run-", root, sizeof root) == 0);
    join(race_saved, directory, "saved-owned-root");
    race_kind = 1; landin_private_directory_set_hook(root_race);
    REQUIRE(landin_remove_tree(root) == -1);
    landin_private_directory_set_hook(NULL);
    const char *reason = landin_remove_tree_reason();
    join(file, root, "sentinel");
    if (!content(file, "raced-save")) {
        char recovery[4096]; retained_entry(reason, directory, recovery);
        join(file, recovery, "sentinel"); REQUIRE(content(file, "raced-save"));
    }
    REQUIRE(strstr(reason, "restor") || strstr(reason, "retained")); ++passed;
}
static void moved_root_race(const char *event, const char *path)
{
    char sentinel[4096];
    (void)path;
    if (!strcmp(event, "before-capture")) {
        REQUIRE(rename(race_actual, race_saved) == 0);
        REQUIRE(mkdir(race_actual, 0700) == 0);
        join(sentinel, race_actual, "sentinel"); put(sentinel, "captured-save");
    } else if (!strcmp(event, "after-capture")) {
        REQUIRE(mkdir(race_actual, 0700) == 0);
        join(sentinel, race_actual, "sentinel"); put(sentinel, "occupied-save");
    }
}
static void moved_root_recovery_diagnostic(void)
{
    char directory[4096], root[4096], moved[4096], foreign[4096], file[4096];
    char recovery[4096];
    parent(directory, "root-moved-conflict");
    REQUIRE(landin_private_directory("refine-run-", root, sizeof root) == 0);
    join(file, root, "owned"); put(file, "owned-save");
    join(moved, scratch, "root-moved-conflict-original");
    REQUIRE(rename(directory, moved) == 0 && mkdir(directory, 0700) == 0);
    join(foreign, directory, leaf(root)); REQUIRE(mkdir(foreign, 0700) == 0);
    join(file, foreign, "sentinel"); put(file, "foreign-save");
    join(race_actual, moved, leaf(root)); join(race_saved, moved, "saved-owned");
    landin_private_directory_set_hook(moved_root_race);
    REQUIRE(landin_remove_tree(root) == -1);
    landin_private_directory_set_hook(NULL);
    const char *reason = landin_remove_tree_reason();
    retained_entry(reason, moved, recovery);
    join(file, recovery, "sentinel"); REQUIRE(content(file, "captured-save"));
    join(file, foreign, "sentinel"); REQUIRE(content(file, "foreign-save"));
    join(file, race_actual, "sentinel"); REQUIRE(content(file, "occupied-save"));
    join(file, race_saved, "owned"); REQUIRE(content(file, "owned-save"));
    ++passed;
}
int main(void)
{
    const char *tmp = getenv("TMPDIR");
    REQUIRE(tmp && strlen(tmp) + 32 < sizeof scratch);
    snprintf(scratch, sizeof scratch, "%s/landin-runtime-owned-XXXXXX", tmp);
    REQUIRE(mkdtemp(scratch) != NULL);
    capture_normal(); capture_ancestor(); capture_replaced_root();
    root_normal(); root_ancestor_and_io(); root_capture_inspection();
    moved_root_recovery_diagnostic();
    printf("runtime ownership native: %u/%u controls passed\n", passed, passed);
    return 0;
}
