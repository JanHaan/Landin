/* Standalone controls exercise production publication and fmt adapters.
   The callback is synchronous, making namespace races deterministic on every
   supported POSIX host; no sleeps, scheduler assumptions, or duplicate model. */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include "landin_publication.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <signal.h>
#include <sys/resource.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int landin_observe_identity(const char *, uint64_t *, uint64_t *, int *);
int landin_entry_names_alias(int, const char *, const char *);
int landin_names_alias(const char *, const char *, int);
void landin_file_identity_set_hook(void (*)(const char *, const char *));
int landin_open_update(const char *, char **, size_t *, int *, char *, size_t);
int landin_replace_update(int, const char *, size_t, char *, size_t);
void landin_close_update(int);
int landin_tool_start_in_directory(char *const [], char *const [], int,
                                    int, int, int, int, int *);
int landin_tool_wait(int, int *, int);
static char scratch[4096], why[8192];
static unsigned passed;
static const char *self_program;
static const char *event_to_race;
static char raced_path[4096], replacement[4096];
static int race_kind;
#define REQUIRE(x) do { if (!(x)) { \
    fprintf(stderr, "publication native failure line %d: %s (errno %d: %s), %s\n", \
            __LINE__, #x, errno, strerror(errno), why); exit(1); } } while (0)
static void path(char *out, size_t room, const char *leaf)
{ REQUIRE(snprintf(out, room, "%s/%s", scratch, leaf) > 0); }
static void put(const char *name, const char *text)
{
    int fd = open(name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    REQUIRE(fd >= 0);
    size_t n = strlen(text); REQUIRE(write(fd, text, n) == (ssize_t)n);
    REQUIRE(close(fd) == 0);
}
static int content(const char *name, const char *expected)
{
    char buffer[1024];
    int fd = open(name, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return 0;
    ssize_t n = read(fd, buffer, sizeof buffer); close(fd);
    return n == (ssize_t)strlen(expected) && !memcmp(buffer, expected, (size_t)n);
}
static int step(int token, int action)
{ return landin_publication_step(token, action, NULL, 0, NULL, 0, why, sizeof why); }
static int prepare(const char *name, int deletion, const char *root, char *stage)
{
    int token;
    REQUIRE(landin_publication_open(name, deletion, root, &token, stage, 4096,
                                    why, sizeof why) == 0);
    return token;
}
static void staged(const char *stage, const char *text)
{ REQUIRE(landin_publication_stage_write(stage, text, strlen(text)) == 0); }
static void race(const char *event, const char *name)
{
    (void)name;
    if (!event_to_race || strcmp(event, event_to_race)) return;
    event_to_race = NULL;
    if (race_kind == 1) REQUIRE(rename(replacement, raced_path) == 0);
    else if (race_kind == 2) REQUIRE(symlink("never-created", raced_path) == 0);
    else if (race_kind == 3) put(raced_path, "editor-save");
}
static void arm(const char *event, const char *name, const char *saved, int kind)
{
    event_to_race = event; race_kind = kind;
    strcpy(raced_path, name); strcpy(replacement, saved ? saved : "");
    landin_publication_set_hook(race);
}
static void clear_hook(void)
{ landin_publication_set_hook(NULL); event_to_race = NULL; }
static void ordinary_group(void)
{
    char a[4096], b[4096], sa[4096], sb[4096];
    path(a, sizeof a, "group-a"); path(b, sizeof b, "group-b");
    put(a, "old-a"); put(b, "old-b");
    int ta = prepare(a, 0, "", sa), tb = prepare(b, 0, "", sb);
    staged(sa, "new-a"); staged(sb, "new-b");
    REQUIRE(step(ta, 0) == 0 && step(tb, 0) == 0);
    REQUIRE(step(ta, 1) == 0 && step(tb, 1) == 0);
    REQUIRE(step(ta, 2) == 0 && step(tb, 2) == 0);
    REQUIRE(content(a, "new-a") && content(b, "new-b"));
    REQUIRE(step(tb, 3) == 0 && step(ta, 3) == 0);
    REQUIRE(content(a, "old-a") && content(b, "old-b"));
    REQUIRE(step(ta, 4) == 0 && step(tb, 4) == 0); ++passed;
}
static void capture_actual(void)
{
    char output[4096], save[4096], stage[4096];
    path(output, sizeof output, "capture"); path(save, sizeof save, "save");
    put(output, "old"); put(save, "editor-save");
    int token = prepare(output, 0, "", stage);
    staged(stage, "generated"); REQUIRE(step(token, 0) == 0);
    arm("before-capture", output, save, 1);
    REQUIRE(step(token, 1) != 0); clear_hook();
    REQUIRE(step(token, 3) == 0 && content(output, "editor-save"));
    REQUIRE(step(token, 4) == 0); ++passed;
}
static void absence_and_noclobber(void)
{
    char output[4096], stage[4096];
    path(output, sizeof output, "absent-save");
    int token = prepare(output, 0, "", stage);
    staged(stage, "generated"); REQUIRE(step(token, 0) == 0);
    arm("before-capture", output, NULL, 3);
    REQUIRE(step(token, 1) != 0); clear_hook();
    REQUIRE(step(token, 3) == 0 && content(output, "editor-save"));
    REQUIRE(step(token, 4) == 0);
    path(output, sizeof output, "dangling-install");
    token = prepare(output, 0, "", stage);
    staged(stage, "generated"); REQUIRE(step(token, 0) == 0 && step(token, 1) == 0);
    arm("before-install", output, NULL, 2);
    REQUIRE(step(token, 2) != 0); clear_hook();
    struct stat st; REQUIRE(lstat(output, &st) == 0 && S_ISLNK(st.st_mode));
    REQUIRE(step(token, 3) == 0 && step(token, 4) == 0); ++passed;
}
static void protected_alias(void)
{
    char input[4096], output[4096], stage[4096];
    path(input, sizeof input, "input"); path(output, sizeof output, "alias");
    put(input, "input-original"); REQUIRE(link(input, output) == 0);
    int token = prepare(output, 0, "", stage);
    staged(stage, "generated"); REQUIRE(step(token, 0) == 0);
    struct stat st; REQUIRE(stat(input, &st) == 0);
    uint64_t identity[] = {(uint64_t)st.st_dev, (uint64_t)st.st_ino};
    REQUIRE(landin_publication_step(token, 1, NULL, 0, identity, 1, why, sizeof why) != 0);
    REQUIRE(step(token, 3) == 0 && content(input, "input-original")
            && content(output, "input-original"));
    REQUIRE(step(token, 4) == 0); ++passed;
}
static void anchored_stage_and_roots(void)
{
    char root[4096], moved[4096], output[4096], stage[4096], second[4096];
    path(root, sizeof root, "root"); path(moved, sizeof moved, "root-moved");
    REQUIRE(snprintf(output, sizeof output, "%s/one", root) > 0);
    int token = prepare(output, 0, root, stage);
    REQUIRE(rename(root, moved) == 0 && mkdir(root, 0700) == 0);
    /* A pathname-only writer would follow the replacement root. */
    staged(stage, "anchored");
    char *bytes; size_t size; uint64_t dev, ino;
    REQUIRE(landin_read_snapshot(stage, &bytes, &size, &dev, &ino) == 0);
    REQUIRE(size == 8 && !memcmp(bytes, "anchored", 8)); free(bytes);
    REQUIRE(snprintf(second, sizeof second, "%s/two", root) > 0);
    int ignored; char ignored_stage[4096];
    REQUIRE(landin_publication_open(second, 0, root, &ignored, ignored_stage,
                                    sizeof ignored_stage, why, sizeof why) != 0);
    REQUIRE(step(token, 3) == 0 && step(token, 4) == 0);
    /* Trailing slash never licenses following a linked chosen root. */
    char linked[4096], link_slash[4096];
    path(linked, sizeof linked, "root-link"); REQUIRE(symlink(root, linked) == 0);
    REQUIRE(snprintf(link_slash, sizeof link_slash, "%s/", linked) > 0);
    REQUIRE(snprintf(output, sizeof output, "%s/no", linked) > 0);
    REQUIRE(landin_publication_open(output, 0, link_slash, &ignored,
                                    ignored_stage, sizeof ignored_stage,
                                    why, sizeof why) != 0); ++passed;
}
static void directory_snapshot(void)
{
    char output[4096], stage[4096], oldleaf[4096], newleaf[4096];
    path(output, sizeof output, "program.dSYM"); REQUIRE(mkdir(output, 0700) == 0);
    REQUIRE(snprintf(oldleaf, sizeof oldleaf, "%s/old", output) > 0); put(oldleaf, "old-debug");
    int token = prepare(output, 0, "", stage);
    REQUIRE(mkdir(stage, 0700) == 0);
    REQUIRE(snprintf(newleaf, sizeof newleaf, "%s/new", stage) > 0); put(newleaf, "new-debug");
    REQUIRE(step(token, 0) == 0 && step(token, 1) == 0);
#if defined(__linux__) || defined(__APPLE__)
    REQUIRE(step(token, 2) == 0);
    REQUIRE(step(token, 3) == 0 && content(oldleaf, "old-debug"));
#else
    /* FreeBSD 14.4 has no directory no-replace rename: explicit refusal. */
    REQUIRE(step(token, 2) != 0);
    REQUIRE(step(token, 3) != 0 && strstr(why, "recovery"));
    return;
#endif
    REQUIRE(step(token, 4) == 0); ++passed;
}
static void mismatch_finish_preserves_tree(void)
{
    char output[4096], stage[4096], first[8192], changed[8192], old[8192];
    path(output, sizeof output, "mismatch.dSYM"); REQUIRE(mkdir(output, 0700) == 0);
    REQUIRE(snprintf(first, sizeof first, "%s/first", output) > 0); put(first, "keep-first");
    REQUIRE(snprintf(changed, sizeof changed, "%s/changed", output) > 0); put(changed, "old-child");
    int token = prepare(output, 0, "", stage); REQUIRE(mkdir(stage, 0700) == 0);
    REQUIRE(step(token, 0) == 0);
    REQUIRE(unlink(changed) == 0); put(changed, "new-child");
    REQUIRE(step(token, 1) != 0 && step(token, 4) != 0);
    char *at = strstr(stage, "/stage/"); REQUIRE(at != NULL);
    REQUIRE(snprintf(old, sizeof old, "%.*s/recovery/.previous-%d/first",
                      (int)(at - stage), stage, token) > 0);
    REQUIRE(content(old, "keep-first"));
#if defined(__linux__) || defined(__APPLE__)
    REQUIRE(step(token, 3) == 0 && content(first, "keep-first")
            && content(changed, "new-child"));
#endif
    ++passed;
}
static void different_output_kind_is_refused(void)
{
    char output[4096], sentinel[8192], stage[4096];
    struct stat before, after;
    path(output, sizeof output, "firmware.bin"); REQUIRE(mkdir(output, 0700) == 0);
    REQUIRE(snprintf(sentinel, sizeof sentinel, "%s/sentinel", output) > 0);
    put(sentinel, "unowned directory contents"); REQUIRE(stat(output, &before) == 0);
    int token = prepare(output, 0, "", stage); staged(stage, "generated image");
    REQUIRE(step(token, 0) != 0 && strstr(why, "directory") != NULL);
    REQUIRE(step(token, 3) == 0 && step(token, 4) == 0);
    REQUIRE(stat(output, &after) == 0 && before.st_dev == after.st_dev
            && before.st_ino == after.st_ino && content(sentinel, "unowned directory contents"));
    ++passed;
    path(output, sizeof output, "file-before-directory"); put(output, "unowned file");
    REQUIRE(stat(output, &before) == 0);
    token = prepare(output, 0, "", stage); REQUIRE(mkdir(stage, 0700) == 0);
    REQUIRE(step(token, 0) != 0 && strstr(why, "regular file") != NULL);
    REQUIRE(step(token, 3) == 0 && step(token, 4) == 0);
    REQUIRE(stat(output, &after) == 0 && before.st_dev == after.st_dev
            && before.st_ino == after.st_ino && content(output, "unowned file"));
    ++passed;
    path(output, sizeof output, "stale-directory"); REQUIRE(mkdir(output, 0700) == 0);
    REQUIRE(snprintf(sentinel, sizeof sentinel, "%s/sentinel", output) > 0);
    put(sentinel, "stale path is a directory"); REQUIRE(stat(output, &before) == 0);
    token = prepare(output, 1, "", stage);
    REQUIRE(step(token, 0) != 0 && step(token, 3) == 0 && step(token, 4) == 0);
    REQUIRE(stat(output, &after) == 0 && before.st_dev == after.st_dev
            && before.st_ino == after.st_ino && content(sentinel, "stale path is a directory"));
    ++passed;
}
static void staged_rewrite(void)
{
    char output[4096], stage[4096];
    path(output, sizeof output, "stage-rewrite");
    int token = prepare(output, 0, "", stage);
    staged(stage, "object-before-checksum"); staged(stage, "patched");
    char *bytes; size_t size; uint64_t dev, ino;
    REQUIRE(landin_read_snapshot(stage, &bytes, &size, &dev, &ino) == 0);
    REQUIRE(size == 7 && !memcmp(bytes, "patched", 7)); free(bytes);
    REQUIRE(step(token, 0) == 0 && step(token, 1) == 0 && step(token, 2) == 0);
    REQUIRE(content(output, "patched") && step(token, 4) == 0); ++passed;
}
static void fmt_read_boundaries(void)
{
    char output[4096], saved[4096];
    path(output, sizeof output, "fmt-before-read");
    path(saved, sizeof saved, "fmt-before-read-save");
    put(output, "stale"); put(saved, "new-read-object");
    int lease; char *bytes; size_t size;
    arm("update-before-read", output, saved, 1);
    REQUIRE(landin_open_update(output, &bytes, &size, &lease, why, sizeof why) == 0);
    clear_hook();
    REQUIRE(size == 15 && !memcmp(bytes, "new-read-object", 15)); free(bytes);
    REQUIRE(landin_replace_update(lease, "formatted-new", 13, why, sizeof why) == 0);
    landin_close_update(lease); REQUIRE(content(output, "formatted-new"));
    path(output, sizeof output, "fmt-after-read");
    path(saved, sizeof saved, "fmt-after-read-save");
    put(output, "original-read"); put(saved, "editor-after-read");
    arm("update-read", output, saved, 1);
    REQUIRE(landin_open_update(output, &bytes, &size, &lease, why, sizeof why) == 0);
    clear_hook();
    REQUIRE(size == 13 && !memcmp(bytes, "original-read", 13)); free(bytes);
    REQUIRE(landin_replace_update(lease, "formatted", 9, why, sizeof why) != 0);
    landin_close_update(lease); REQUIRE(content(output, "editor-after-read"));
    ++passed;
}
static void collision_names(void)
{
    char first[4096], other[4096], stage[4096], other_stage[4096];
    path(first, sizeof first, "collision-first"); put(first, "first-old");
    int one = prepare(first, 0, "", stage);
    REQUIRE(snprintf(other, sizeof other, "%s/.previous-%d", scratch, one) > 0);
    put(other, "other-old"); int two = prepare(other, 0, "", other_stage);
    staged(stage, "first-new"); staged(other_stage, "other-new");
    REQUIRE(step(one, 0) == 0 && step(two, 0) == 0);
    REQUIRE(step(one, 1) == 0);
    char *bytes; size_t size; uint64_t dev, ino;
    REQUIRE(landin_read_snapshot(other_stage, &bytes, &size, &dev, &ino) == 0);
    REQUIRE(size == 9 && !memcmp(bytes, "other-new", 9)); free(bytes);
    REQUIRE(step(two, 1) == 0 && step(one, 2) == 0 && step(two, 2) == 0);
    REQUIRE(step(one, 4) == 0 && step(two, 4) == 0);
    REQUIRE(content(first, "first-new") && content(other, "other-new")); ++passed;
}
static void rollback_race(const char *event, const char *name)
{
    if (!strcmp(event, "before-rollback-capture"))
        REQUIRE(rename(replacement, name) == 0);
    else if (!strcmp(event, "rollback-captured")) put(name, "second-save");
}
static void repeated_abort_retains_recovery(void)
{
    char output[4096], stage[4096], save[4096], recovery[8192], rollback[8192];
    path(output, sizeof output, "rollback-output"); path(save, sizeof save, "rollback-editor");
    put(output, "old-output"); put(save, "first-save");
    int token = prepare(output, 0, "", stage); staged(stage, "generated");
    REQUIRE(step(token, 0) == 0 && step(token, 1) == 0 && step(token, 2) == 0);
    strcpy(replacement, save); landin_publication_set_hook(rollback_race);
    REQUIRE(step(token, 3) != 0); clear_hook();
    char *at = strstr(stage, "/stage/"); REQUIRE(at != NULL);
    REQUIRE(snprintf(recovery, sizeof recovery, "%.*s/recovery/.previous-%d",
                      (int)(at - stage), stage, token) > 0);
    REQUIRE(snprintf(rollback, sizeof rollback, "%.*s/recovery/.rollback-%d",
                      (int)(at - stage), stage, token) > 0);
    REQUIRE(content(output, "second-save") && content(recovery, "old-output")
            && content(rollback, "first-save"));
    REQUIRE(step(token, 3) != 0);
    REQUIRE(content(output, "second-save") && content(recovery, "old-output")
            && content(rollback, "first-save")); ++passed;
}
static void recovery_discovery(void)
{
    char output[4096]; path(output, sizeof output, "rollback-output");
    char *args[] = {(char *)self_program, "--discover", output, NULL};
    int nullfd = open("/dev/null", O_RDWR), child, status; REQUIRE(nullfd >= 0);
    REQUIRE(landin_tool_start_in_directory(args, NULL, 0, nullfd, nullfd,
                                            nullfd, -1, &child) == 0);
    REQUIRE(landin_tool_wait(child, &status, 0) == child && status == 0);
    close(nullfd); ++passed;
}
static void moved_rollback_race(const char *event, const char *name)
{
    (void)name;
    if (!strcmp(event, "before-rollback-capture"))
        REQUIRE(rename(replacement, raced_path) == 0);
    else if (!strcmp(event, "rollback-captured")) put(raced_path, "second-save");
}
static void moved_anchor_recovery_diagnostic(void)
{
    char root[4096], moved[4096], output[4096], moved_output[4096];
    char stage[4096], save[4096], recovery[8192], parent_identity[160];
    path(root, sizeof root, "diagnostic-root"); path(moved, sizeof moved, "diagnostic-moved");
    path(save, sizeof save, "diagnostic-save"); REQUIRE(mkdir(root, 0700) == 0);
    REQUIRE(snprintf(output, sizeof output, "%s/output", root) > 0); put(output, "old-output");
    REQUIRE(snprintf(moved_output, sizeof moved_output, "%s/output", moved) > 0);
    struct stat parent; REQUIRE(stat(root, &parent) == 0);
    int token = prepare(output, 0, root, stage); staged(stage, "generated");
    REQUIRE(step(token, 0) == 0 && step(token, 1) == 0 && step(token, 2) == 0);
    REQUIRE(rename(root, moved) == 0 && mkdir(root, 0700) == 0); put(save, "first-save");
    strcpy(raced_path, moved_output); strcpy(replacement, save);
    landin_publication_set_hook(moved_rollback_race);
    REQUIRE(step(token, 3) != 0); clear_hook();
    REQUIRE(snprintf(parent_identity, sizeof parent_identity, "device=%ju inode=%ju",
                      (uintmax_t)parent.st_dev, (uintmax_t)parent.st_ino) > 0);
    REQUIRE(strstr(why, parent_identity) != NULL);
#if defined(__linux__) || defined(__APPLE__)
    REQUIRE(strstr(why, "observed current path") != NULL && strstr(why, moved) != NULL);
#else
    REQUIRE(strstr(why, "current directory path unavailable") != NULL
            && strstr(why, "last-known spelling") != NULL);
#endif
    char *at = strstr(stage, "/stage/"); REQUIRE(at != NULL);
    REQUIRE(snprintf(recovery, sizeof recovery, "%s%.*s/recovery/.previous-%d",
                      moved, (int)(at - stage - (ptrdiff_t)strlen(root)),
                      stage + strlen(root), token) > 0);
    REQUIRE(content(recovery, "old-output") && content(moved_output, "second-save"));
    ++passed;
}
static void child_staging_directory(void)
{
    char root[4096], moved[4096], output[4096], stage[4096], relative[8192];
    path(root, sizeof root, "child-root"); path(moved, sizeof moved, "child-moved");
    REQUIRE(snprintf(output, sizeof output, "%s/child-output", root) > 0);
    int token = prepare(output, 0, root, stage);
    int directory = landin_publication_stage_directory(stage);
    REQUIRE(directory >= 0);
    REQUIRE(landin_publication_rebase_argument(stage, directory, relative, sizeof relative) == 0);
    REQUIRE(rename(root, moved) == 0 && mkdir(root, 0700) == 0);
    char *args[] = {"/bin/sh", "-c", "printf child-anchored > \"$1\"", "stage", relative, NULL};
    int nullfd = open("/dev/null", O_RDWR); REQUIRE(nullfd >= 0);
    int child, status;
    REQUIRE(landin_tool_start_in_directory(args, NULL, 0, nullfd, nullfd,
                                            nullfd, directory, &child) == 0);
    REQUIRE(landin_tool_wait(child, &status, 0) == child && status == 0);
    close(directory); close(nullfd);
    char *bytes; size_t size; uint64_t dev, ino;
    REQUIRE(landin_read_snapshot(stage, &bytes, &size, &dev, &ino) == 0);
    REQUIRE(size == 14 && !memcmp(bytes, "child-anchored", 14)); free(bytes);
    REQUIRE(step(token, 3) == 0 && step(token, 4) == 0); ++passed;
}
static void fmt_moved_race(const char *event, const char *name)
{
    if (strcmp(event, "update-before-write")) return;
    REQUIRE(rename(raced_path, replacement) == 0 && mkdir(raced_path, 0700) == 0);
    put(name, "editor-save");
}
static void fmt_moved_parent_diagnostic(void)
{
    char root[4096], moved[4096], output[4096], moved_output[4096];
    char recovered[8192], identity[160];
    path(root, sizeof root, "fmt-diagnostic-root");
    path(moved, sizeof moved, "fmt-diagnostic-moved"); REQUIRE(mkdir(root, 0700) == 0);
    REQUIRE(snprintf(output, sizeof output, "%s/source", root) > 0); put(output, "original");
    REQUIRE(snprintf(moved_output, sizeof moved_output, "%s/source", moved) > 0);
    struct stat parent; REQUIRE(stat(root, &parent) == 0);
    int lease; char *bytes; size_t size;
    REQUIRE(landin_open_update(output, &bytes, &size, &lease, why, sizeof why) == 0); free(bytes);
    strcpy(raced_path, root); strcpy(replacement, moved);
    landin_publication_set_hook(fmt_moved_race);
    REQUIRE(landin_replace_update(lease, "formatted", 9, why, sizeof why) != 0);
    clear_hook(); landin_close_update(lease);
    REQUIRE(content(output, "editor-save") && content(moved_output, "formatted"));
    REQUIRE(snprintf(identity, sizeof identity, "device=%ju inode=%ju",
                      (uintmax_t)parent.st_dev, (uintmax_t)parent.st_ino) > 0);
    REQUIRE(strstr(why, identity) != NULL);
#if defined(__linux__) || defined(__APPLE__)
    REQUIRE(strstr(why, moved) != NULL);
#else
    REQUIRE(strstr(why, "current directory path unavailable") != NULL
            && strstr(why, "last-known spelling") != NULL);
#endif
    DIR *directory = opendir(moved); REQUIRE(directory != NULL);
    struct dirent *item; int found = 0;
    while ((item = readdir(directory)) != NULL) {
        if (strncmp(item->d_name, ".fmt-original-", 14)) continue;
        REQUIRE(snprintf(recovered, sizeof recovered, "%s/%s", moved, item->d_name) > 0);
        REQUIRE(content(recovered, "original")); ++found;
    }
    closedir(directory); REQUIRE(found == 1); ++passed;
}
static void fmt_readonly_is_write_refusal(void)
{
    char output[4096]; path(output, sizeof output, "fmt-readonly"); put(output, "original");
    REQUIRE(chmod(output, 0444) == 0);
    int lease; char *bytes; size_t size;
    REQUIRE(landin_open_update(output, &bytes, &size, &lease, why, sizeof why) == 0);
    REQUIRE(size == 8 && !memcmp(bytes, "original", 8)); free(bytes);
    REQUIRE(landin_replace_update(lease, "formatted", 9, why, sizeof why) != 0);
    landin_close_update(lease);
    REQUIRE(strstr(why, "it is read-only") != NULL && content(output, "original"));
    REQUIRE(chmod(output, 0600) == 0); ++passed;
}
static unsigned journal_hook_count;
static void run_peer(const char *mode, const char *target)
{
    char *args[] = {(char *)self_program, (char *)mode, (char *)target, NULL};
    int nullfd = open("/dev/null", O_RDWR), child, status; REQUIRE(nullfd >= 0);
    REQUIRE(landin_tool_start_in_directory(args, NULL, 0, nullfd, nullfd,
                                            nullfd, -1, &child) == 0);
    REQUIRE(landin_tool_wait(child, &status, 0) == child && status == 0);
    close(nullfd);
}
static void journal_concurrency_hook(const char *event, const char *target)
{
    if (strcmp(event, "arena-ready") && strcmp(event, "journal-building")
        && strcmp(event, "journal-ready")) return;
    char peer[8192];
    REQUIRE(snprintf(peer, sizeof peer, "%s-peer-%u", target, ++journal_hook_count) > 0);
    run_peer("--publish-peer", peer); REQUIRE(content(peer, "peer-generated"));
    if (!strcmp(event, "journal-ready")) run_peer("--discover", target);
}
static void journal_concurrency(void)
{
    char parent[4096], output[8192], stage[4096];
    path(parent, sizeof parent, "journal-concurrency"); REQUIRE(mkdir(parent, 0700) == 0);
    REQUIRE(snprintf(output, sizeof output, "%s/main", parent) > 0);
    journal_hook_count = 0; landin_publication_set_hook(journal_concurrency_hook);
    int token = prepare(output, 0, "", stage); clear_hook();
    REQUIRE(journal_hook_count == 3);
    staged(stage, "generated");
    REQUIRE(step(token, 0) == 0 && step(token, 1) == 0 && step(token, 2) == 0 && step(token, 4) == 0);
    REQUIRE(content(output, "generated")); ++passed;
}
static int retirement_ready, retirement_release;
static int retirement_late_replacement;
static unsigned retirement_barriers;
static void retirement_hook(const char *event, const char *target)
{
    (void)target;
    if (strcmp(event, "discovery-opened")
        && !(retirement_late_replacement && !strcmp(event, "discovery-empty"))) return;
    char byte;
    ++retirement_barriers;
    REQUIRE(write(retirement_ready, "R", 1) == 1);
    REQUIRE(read(retirement_release, &byte, 1) == 1 && byte == 'R');
}
static void discovery_retirement_case(unsigned replacement_kind)
{
    char parent[4096], owner[8192], peer[8192], stage[4096];
    char arena[4096], parked[8192], sentinel[8192];
    struct stat sentinel_before, sentinel_after;
    struct stat observed_before, parked_after;
    char ready_arg[32], release_arg[32], byte;
    int ready[2], release[2], child, status;
    REQUIRE(snprintf(parent, sizeof parent, "%s/discovery-retirement-%u",
                     scratch, replacement_kind) > 0);
    REQUIRE(mkdir(parent, 0700) == 0);
    REQUIRE(snprintf(owner, sizeof owner, "%s/owner", parent) > 0);
    REQUIRE(snprintf(peer, sizeof peer, "%s/peer", parent) > 0);
    int token = 0;
    if (replacement_kind == 3) {
        put(owner, "owner-generated");
        REQUIRE(snprintf(arena, sizeof arena, "%s/.refine-publication-live-empty", parent) > 0);
        REQUIRE(mkdir(arena, 0700) == 0);
    } else {
        token = prepare(owner, 0, "", stage); staged(stage, "owner-generated");
        REQUIRE(strlen(stage) < sizeof arena); strcpy(arena, stage);
        char *slash = strrchr(arena, '/'); REQUIRE(slash != NULL); *slash = 0;
        slash = strrchr(arena, '/'); REQUIRE(slash != NULL); *slash = 0;
        REQUIRE(step(token, 0) == 0 && step(token, 1) == 0 && step(token, 2) == 0);
    }
    int observed = open(arena, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    REQUIRE(observed >= 0 && fstat(observed, &observed_before) == 0);
    REQUIRE(pipe(ready) == 0 && pipe(release) == 0);
    REQUIRE(fcntl(ready[0], F_SETFD, FD_CLOEXEC) == 0
            && fcntl(release[1], F_SETFD, FD_CLOEXEC) == 0);
    REQUIRE(snprintf(ready_arg, sizeof ready_arg, "%d", ready[1]) > 0);
    REQUIRE(snprintf(release_arg, sizeof release_arg, "%d", release[0]) > 0);
    char *args[] = {(char *)self_program,
                    replacement_kind == 4 ? "--retirement-late-refusal-peer"
                    : replacement_kind ? "--retirement-refusal-peer" : "--retirement-peer", peer,
                    ready_arg, release_arg, NULL};
    int nullfd = open("/dev/null", O_RDWR); REQUIRE(nullfd >= 0);
    REQUIRE(landin_tool_start_in_directory(args, NULL, 0, nullfd,
                STDOUT_FILENO, STDERR_FILENO, -1, &child) == 0);
    close(nullfd); close(ready[1]); close(release[0]);
    REQUIRE(read(ready[0], &byte, 1) == 1 && byte == 'R');
    /* The scanner has opened the arena but has not locked it. Retire the
       owner's arena, optionally replacing its name with unexplained entries;
       a renamed live root must also remain a refusal. */
    if (replacement_kind == 2 || replacement_kind == 3) {
        REQUIRE(snprintf(parked, sizeof parked, "%s/moved-arena", parent) > 0);
        REQUIRE(rename(arena, parked) == 0);
    } else {
        REQUIRE(step(token, 4) == 0);
        struct stat retired, missing;
        REQUIRE(fstat(observed, &retired) == 0 && S_ISDIR(retired.st_mode));
#ifndef __APPLE__
        REQUIRE(retired.st_nlink == 0);
#endif
        errno = 0; REQUIRE(lstat(arena, &missing) != 0 && errno == ENOENT);
        errno = 0; int listing_fd = dup(observed); REQUIRE(listing_fd >= 0);
        DIR *listing = fdopendir(listing_fd); int opening_error = errno;
        errno = 0; struct dirent *entry = listing ? readdir(listing) : NULL;
        int listing_error = listing ? errno : opening_error;
#ifdef __APPLE__
        REQUIRE(listing != NULL && entry == NULL && listing_error == 0);
#else
        REQUIRE(entry == NULL && (listing_error == 0 || listing_error == ENOENT));
#endif
        if (listing) closedir(listing); else close(listing_fd);
        printf("retired arena: nlink=%ju absent-parent-entry=1 raw-entries=0 readdir-errno=%d\n",
               (uintmax_t)retired.st_nlink, listing_error);
    }
    close(observed);
    if (replacement_kind == 4) {
        REQUIRE(write(release[1], "R", 1) == 1);
        REQUIRE(read(ready[0], &byte, 1) == 1 && byte == 'R');
    }
    if (replacement_kind == 1 || replacement_kind == 2 || replacement_kind == 4) {
        REQUIRE(mkdir(arena, 0700) == 0);
        REQUIRE(snprintf(sentinel, sizeof sentinel, "%s/unknown", arena) > 0);
        put(sentinel, "unexplained-recovery");
        REQUIRE(lstat(sentinel, &sentinel_before) == 0);
    }
    REQUIRE(write(release[1], "R", 1) == 1); close(release[1]); close(ready[0]);
    REQUIRE(landin_tool_wait(child, &status, 0) == child && status == 0);
    REQUIRE(content(owner, "owner-generated"));
    if (replacement_kind == 2 || replacement_kind == 3) {
        REQUIRE(lstat(parked, &parked_after) == 0 && S_ISDIR(parked_after.st_mode)
                && observed_before.st_dev == parked_after.st_dev
                && observed_before.st_ino == parked_after.st_ino
                && observed_before.st_mode == parked_after.st_mode);
    }
    if (replacement_kind == 3) REQUIRE(access(peer, F_OK) != 0);
    else if (replacement_kind) {
        REQUIRE(content(sentinel, "unexplained-recovery") && access(peer, F_OK) != 0
                && lstat(sentinel, &sentinel_after) == 0
                && sentinel_before.st_dev == sentinel_after.st_dev
                && sentinel_before.st_ino == sentinel_after.st_ino
                && sentinel_before.st_mode == sentinel_after.st_mode);
    } else REQUIRE(content(peer, "peer-generated"));
}
static void discovery_during_retirement(void)
{
    for (unsigned kind = 0; kind < 4; ++kind) discovery_retirement_case(kind);
#ifdef __APPLE__
    discovery_retirement_case(4);
#endif
    ++passed;
}
static int changing_ready, changing_release;
static unsigned changing_barriers;
static const char *changing_path;
static void changing_wait(char phase)
{
    char byte;
    ++changing_barriers;
    REQUIRE(write(changing_ready, &phase, 1) == 1);
    REQUIRE(read(changing_release, &byte, 1) == 1 && byte == 'R');
}
static void changing_identity_hook(const char *event, const char *name)
{
    if (!strcmp(event, "destination-absent") && !strcmp(name, changing_path))
        changing_wait('S');
}
static void changing_publication_hook(const char *event, const char *name)
{
    const char *leaf = strrchr(changing_path, '/');
    if (!strcmp(event, "discovery-distinct")
        && !strcmp(name, leaf ? leaf + 1 : changing_path)) changing_wait('C');
}
static void discovery_during_publication(void)
{
    for (unsigned hard_link = 0; hard_link < 2; ++hard_link) {
        char parent[4096], canonical[4096], owner[8192], peer[8192], stage[4096];
        char ready_arg[32], release_arg[32], phase;
        int ready[2], release[2], child, status;
        REQUIRE(snprintf(parent, sizeof parent, "%s/discovery-changing-%u",
                         scratch, hard_link) > 0);
        REQUIRE(mkdir(parent, 0700) == 0 && realpath(parent, canonical));
        REQUIRE(snprintf(owner, sizeof owner, "%s/owner", canonical) > 0);
        REQUIRE(snprintf(peer, sizeof peer, "%s/peer", canonical) > 0);
        put(owner, "old-output");
        if (hard_link) REQUIRE(link(owner, peer) == 0);
        else put(peer, "other-old");
        int token = prepare(owner, 0, "", stage); staged(stage, "owner-generated");
        REQUIRE(step(token, 0) == 0 && step(token, 1) == 0);
        REQUIRE(content(peer, hard_link ? "old-output" : "other-old"));
        REQUIRE(pipe(ready) == 0 && pipe(release) == 0);
        REQUIRE(fcntl(ready[0], F_SETFD, FD_CLOEXEC) == 0
                && fcntl(release[1], F_SETFD, FD_CLOEXEC) == 0);
        REQUIRE(snprintf(ready_arg, sizeof ready_arg, "%d", ready[1]) > 0);
        REQUIRE(snprintf(release_arg, sizeof release_arg, "%d", release[0]) > 0);
        char *args[] = {(char *)self_program, "--changing-peer", peer, owner,
                        ready_arg, release_arg, NULL};
        int nullfd = open("/dev/null", O_RDWR); REQUIRE(nullfd >= 0);
        REQUIRE(landin_tool_start_in_directory(args, NULL, 0, nullfd,
                    STDOUT_FILENO, STDERR_FILENO, -1, &child) == 0);
        close(nullfd); close(ready[1]); close(release[0]);
        REQUIRE(read(ready[0], &phase, 1) == 1 && (phase == 'S' || phase == 'C'));
        close(ready[0]);
        /* S is the old stat-miss window; C is classification by stable entry
           names. Keep both barriers so restoring the old path lookup reliably
           recreates its failure, even when the two names began as hard links. */
        REQUIRE(step(token, 2) == 0);
        REQUIRE(write(release[1], "R", 1) == 1); close(release[1]);
        REQUIRE(landin_tool_wait(child, &status, 0) == child);
        REQUIRE(step(token, 4) == 0);
        printf("discovery changing peer: hard_link=%u barrier=%c status=%d\n",
               hard_link, phase, status);
        REQUIRE(status == 0 && content(owner, "owner-generated")
                && content(peer, "peer-generated"));
        ++passed;
    }
}
static void pinned_entry_name_equivalence(void)
{
    char parent[4096], first[8192], folded[8192], stage[4096];
    path(parent, sizeof parent, "entry-name-equivalence");
    REQUIRE(mkdir(parent, 0700) == 0);
    int fd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    REQUIRE(fd >= 0);
    REQUIRE(landin_entry_names_alias(fd, "same", "same") == 1);
    REQUIRE(landin_entry_names_alias(fd, "first", "other") == 0);
    REQUIRE(landin_entry_names_alias(-1, "first", "other") < 0);
    REQUIRE(landin_entry_names_alias(fd, "../first", "other") < 0);
    REQUIRE(landin_names_alias("\xC3\xA9", "e\xCC\x81", -1) < 0);
    REQUIRE(landin_names_alias("Case", "case", -1) < 0);
    REQUIRE(landin_names_alias("Case", "case", 0) == 1);
    REQUIRE(snprintf(first, sizeof first, "%s/Case", parent) > 0);
    REQUIRE(snprintf(folded, sizeof folded, "%s/case", parent) > 0);
    put(first, "existing-owner");
    int token = prepare(first, 0, "", stage);
    int aliases = landin_entry_names_alias(fd, "Case", "case");
    /* A case alias on this volume must refuse. An unknown volume's folded
       name remains uncertain; a proven byte-sensitive directory can publish. */
    run_peer(aliases == 0 ? "--publish-peer" : "--discover", folded);
    REQUIRE(content(first, "existing-owner"));
    REQUIRE(step(token, 4) == 0); close(fd);
    ++passed;
}
static int constructor_failure_child(const char *output)
{
    struct stat before, after;
    struct rlimit original, limited;
    struct sigaction ignore, previous;
    char stage[4096], parent[4096], canonical[4096], retained[8192] = "";
    int token, status;
    REQUIRE(stat(output, &before) == 0);
    const char *slash = strrchr(output, '/'); REQUIRE(slash != NULL);
    REQUIRE(snprintf(parent, sizeof parent, "%.*s", (int)(slash - output), output) > 0
            && realpath(parent, canonical));
    REQUIRE(getrlimit(RLIMIT_FSIZE, &original) == 0);
    memset(&ignore, 0, sizeof ignore); ignore.sa_handler = SIG_IGN;
    sigemptyset(&ignore.sa_mask);
    REQUIRE(sigaction(SIGXFSZ, &ignore, &previous) == 0);
    limited = original; limited.rlim_cur = 0;
    REQUIRE(setrlimit(RLIMIT_FSIZE, &limited) == 0);
    status = landin_publication_open(output, 0, "", &token, stage,
                                     sizeof stage, why, sizeof why);
    REQUIRE(setrlimit(RLIMIT_FSIZE, &original) == 0
            && sigaction(SIGXFSZ, &previous, NULL) == 0);
    REQUIRE(status != 0 && token == 0 && stat(output, &after) == 0);
    REQUIRE(before.st_dev == after.st_dev && before.st_ino == after.st_ino
            && before.st_mode == after.st_mode && content(output, "original-output"));
    DIR *directory = opendir(canonical); REQUIRE(directory != NULL);
    struct dirent *entry; unsigned count = 0;
    while ((entry = readdir(directory)) != NULL) {
        if (strncmp(entry->d_name, ".refine-publication-", 20)) continue;
        ++count;
        REQUIRE(snprintf(retained, sizeof retained, "%s/%s", canonical, entry->d_name) > 0);
    }
    closedir(directory);
    REQUIRE(count == 1 && stat(retained, &after) == 0 && S_ISDIR(after.st_mode));
    printf("constructor failure retained: %s; diagnostic: %s\n", retained, why);
    REQUIRE(strstr(why, retained) != NULL && strstr(why, "inspect") != NULL);
    return 0;
}
static void constructor_failure_is_discoverable(void)
{
    char parent[4096], output[8192]; struct stat before, after;
    path(parent, sizeof parent, "constructor-failure"); REQUIRE(mkdir(parent, 0700) == 0);
    REQUIRE(snprintf(output, sizeof output, "%s/output", parent) > 0);
    put(output, "original-output"); REQUIRE(stat(output, &before) == 0);
    char *args[] = {(char *)self_program, "--constructor-failure", output, NULL};
    int nullfd = open("/dev/null", O_RDWR), child, status; REQUIRE(nullfd >= 0);
    REQUIRE(landin_tool_start_in_directory(args, NULL, 0, nullfd,
                STDOUT_FILENO, STDERR_FILENO, -1, &child) == 0);
    close(nullfd);
    REQUIRE(landin_tool_wait(child, &status, 0) == child);
    REQUIRE(stat(output, &after) == 0 && before.st_dev == after.st_dev
            && before.st_ino == after.st_ino && before.st_mode == after.st_mode
            && content(output, "original-output"));
    REQUIRE(status == 0); ++passed;
}
static void unknown_unready_recovery_refuses(void)
{
    for (unsigned kind = 0; kind < 3; ++kind) {
        char parent[4096], arena[8192], entry[16384], output[8192], stage[4096];
        REQUIRE(snprintf(parent, sizeof parent, "%s/unknown-unready-%u", scratch, kind) > 0);
        REQUIRE(mkdir(parent, 0700) == 0);
        REQUIRE(snprintf(arena, sizeof arena, "%s/.refine-publication-unknown", parent) > 0);
        REQUIRE(mkdir(arena, 0700) == 0);
        REQUIRE(snprintf(output, sizeof output, "%s/output", parent) > 0);
        const char *bytes = "unexplained retained bytes";
        if (kind == 0) REQUIRE(snprintf(entry, sizeof entry, "%s/foreign", arena) > 0);
        else if (kind == 1) {
            REQUIRE(snprintf(entry, sizeof entry, "%s/recovery", arena) > 0);
            REQUIRE(mkdir(entry, 0700) == 0);
            REQUIRE(snprintf(entry, sizeof entry, "%s/recovery/foreign", arena) > 0);
        } else {
            REQUIRE(snprintf(entry, sizeof entry, "%s/destination-1", arena) > 0);
            bytes = "LANDIN-PUBLICATION-1\n1\nx\n";
        }
        put(entry, bytes);
        int token;
        REQUIRE(landin_publication_open(output, 0, "", &token, stage,
                                        sizeof stage, why, sizeof why) != 0);
        REQUIRE(strstr(why, "retained or active publication") != NULL && content(entry, bytes));
        ++passed;
    }
}
static void fmt_original_descriptor(void)
{
    char output[4096], saved[4096], original_alias[4096];
    path(output, sizeof output, "fmt-source"); path(saved, sizeof saved, "fmt-editor");
    path(original_alias, sizeof original_alias, "fmt-hardlink");
    put(output, "original"); REQUIRE(link(output, original_alias) == 0); put(saved, "editor-save");
    int lease; char *bytes; size_t size;
    REQUIRE(landin_open_update(output, &bytes, &size, &lease, why, sizeof why) == 0);
    REQUIRE(size == 8 && !memcmp(bytes, "original", 8)); free(bytes);
    arm("update-before-write", output, saved, 1);
    REQUIRE(landin_replace_update(lease, "formatted", 9, why, sizeof why) != 0);
    clear_hook(); landin_close_update(lease);
    REQUIRE(content(output, "editor-save") && content(original_alias, "formatted"));
    REQUIRE(strstr(why, "retained")); ++passed;
}
static void identity_observations(void)
{
    char parent[4096], leaf[8192], missing[8192], dangling[8192], invalid[8192];
    uint64_t device = 0, inode = 0; int resolved = -1;
    path(parent, sizeof parent, "identity-observation");
    REQUIRE(mkdir(parent, 0700) == 0);
    REQUIRE(snprintf(leaf, sizeof leaf, "%s/tool", parent) > 0);
    REQUIRE(landin_observe_identity(leaf, &device, &inode, &resolved) == 0
            && resolved == 1);
    REQUIRE(snprintf(missing, sizeof missing, "%s/missing/tool", parent) > 0);
    REQUIRE(landin_observe_identity(missing, &device, &inode, &resolved) == 0
            && resolved == 0);
    put(leaf, "not executable and not read");
    struct stat before; REQUIRE(stat(leaf, &before) == 0);
    REQUIRE(chmod(leaf, 0000) == 0);
    int found = landin_observe_identity(leaf, &device, &inode, &resolved);
    REQUIRE(chmod(leaf, 0600) == 0);
    REQUIRE(found == 1 && device == (uint64_t)before.st_dev
            && inode == (uint64_t)before.st_ino);
    REQUIRE(snprintf(invalid, sizeof invalid, "%s/child", leaf) > 0);
    REQUIRE(landin_observe_identity(invalid, &device, &inode, &resolved) < 0);
    REQUIRE(snprintf(dangling, sizeof dangling, "%s/dangling", parent) > 0);
    REQUIRE(symlink("missing/target", dangling) == 0);
    REQUIRE(landin_observe_identity(dangling, &device, &inode, &resolved) < 0);
    REQUIRE(snprintf(invalid, sizeof invalid, "%s/child/tool", dangling) > 0);
    REQUIRE(landin_observe_identity(invalid, &device, &inode, &resolved) < 0);
    if (geteuid() != 0) {
        REQUIRE(chmod(parent, 0000) == 0);
        int denied = landin_observe_identity(leaf, &device, &inode, &resolved);
        REQUIRE(chmod(parent, 0700) == 0);
        REQUIRE(denied < 0);
    }
    REQUIRE(snprintf(invalid, sizeof invalid, "%s/missing", parent) > 0);
    REQUIRE(mkdir(invalid, 0700) == 0);
    REQUIRE(landin_observe_identity(missing, &device, &inode, &resolved) == 0
            && resolved == 1);
    put(missing, "new tool");
    REQUIRE(landin_observe_identity(missing, &device, &inode, &resolved) == 1);
    REQUIRE(content(leaf, "not executable and not read") && content(missing, "new tool"));
    ++passed;
}
static int prepare_absent(const char *output, char *stage)
{
    int token;
    REQUIRE(landin_publication_open(output, LANDIN_PUBLICATION_REQUIRE_ABSENT,
                "", &token, stage, 4096, why, sizeof why) == 0);
    return token;
}
static void required_absence_snapshot(void)
{
    char parent[4096], output[8192], foreign[8192], leaf[16384], stage[4096];
    path(parent, sizeof parent, "required-absence"); REQUIRE(mkdir(parent, 0700) == 0);
    for (unsigned kind = 0; kind < 3; ++kind) {
        REQUIRE(snprintf(output, sizeof output, "%s/existing-%u", parent, kind) > 0);
        if (kind == 0) put(output, "existing-file");
        else if (kind == 1) REQUIRE(mkdir(output, 0700) == 0);
        else REQUIRE(symlink("absent-target", output) == 0);
        struct stat before, after; REQUIRE(lstat(output, &before) == 0);
        int token = -1;
        REQUIRE(landin_publication_open(output, LANDIN_PUBLICATION_REQUIRE_ABSENT,
                    "", &token, stage, sizeof stage, why, sizeof why) != 0
                && token == 0 && !*stage && strstr(why, "absence was required"));
        REQUIRE(lstat(output, &after) == 0 && before.st_dev == after.st_dev
                && before.st_ino == after.st_ino && before.st_mode == after.st_mode);
        if (kind == 0) REQUIRE(content(output, "existing-file"));
    }
    REQUIRE(snprintf(output, sizeof output, "%s/appeared-before-snapshot", parent) > 0);
    REQUIRE(snprintf(foreign, sizeof foreign, "%s/foreign", parent) > 0);
    REQUIRE(mkdir(foreign, 0700) == 0);
    REQUIRE(snprintf(leaf, sizeof leaf, "%s/sentinel", foreign) > 0); put(leaf, "foreign-tree");
    struct stat before, after; REQUIRE(stat(foreign, &before) == 0);
    arm("before-snapshot", output, foreign, 1);
    int token;
    REQUIRE(landin_publication_open(output, LANDIN_PUBLICATION_REQUIRE_ABSENT,
                "", &token, stage, sizeof stage, why, sizeof why) != 0 && token == 0);
    clear_hook();
    REQUIRE(stat(output, &after) == 0 && before.st_dev == after.st_dev
            && before.st_ino == after.st_ino && before.st_mode == after.st_mode);
    REQUIRE(snprintf(leaf, sizeof leaf, "%s/sentinel", output) > 0 && content(leaf, "foreign-tree"));
    char actual[8192], linked[8192], child[16384];
    REQUIRE(snprintf(actual, sizeof actual, "%s/actual", parent) > 0 && mkdir(actual, 0700) == 0);
    REQUIRE(snprintf(child, sizeof child, "%s/child", actual) > 0 && mkdir(child, 0700) == 0);
    REQUIRE(snprintf(linked, sizeof linked, "%s/alias", parent) > 0 && symlink(actual, linked) == 0);
    REQUIRE(snprintf(output, sizeof output, "%s/child/new-root", linked) > 0);
    REQUIRE(landin_publication_open(output, LANDIN_PUBLICATION_REQUIRE_ABSENT,
                "", &token, stage, sizeof stage, why, sizeof why) != 0 && token == 0);
    /* Ordinary compiler output retains its existing chosen-parent policy. */
    token = prepare(output, 0, "", stage);
    REQUIRE(step(token, 3) == 0 && step(token, 4) == 0 && access(output, F_OK) != 0);
#ifdef __APPLE__
    for (unsigned anchor = 0; anchor < 2; ++anchor) {
        char system[4096];
        REQUIRE(snprintf(system, sizeof system, "%s/landin-absence-XXXXXX",
                         anchor ? "/var/tmp" : "/tmp") > 0 && mkdtemp(system));
        REQUIRE(snprintf(output, sizeof output, "%s/out", system) > 0);
        token = prepare_absent(output, stage);
        REQUIRE(step(token, 4) == 0 && access(output, F_OK) != 0 && rmdir(system) == 0);
    }
#endif
    ++passed;
}
static void absent_directory_publication(void)
{
    char parent[4096], output[8192], baseline[8192], stage[4096], child[8192], file[8192];
    path(parent, sizeof parent, "absent-directory"); REQUIRE(mkdir(parent, 0700) == 0);
    REQUIRE(snprintf(output, sizeof output, "%s/out", parent) > 0);
    REQUIRE(snprintf(baseline, sizeof baseline, "%s/mode-baseline", parent) > 0 && mkdir(baseline, 0777) == 0);
    int token = prepare_absent(output, stage);
    REQUIRE(access(output, F_OK) != 0 && access(stage, F_OK) != 0);
    REQUIRE(landin_publication_stage_mkdir(stage) == 0);
    struct stat ordinary, staged_mode;
    REQUIRE(stat(baseline, &ordinary) == 0 && stat(stage, &staged_mode) == 0
            && (ordinary.st_mode & 07777) == (staged_mode.st_mode & 07777));
    REQUIRE(snprintf(child, sizeof child, "%s/nested", stage) > 0
            && landin_publication_stage_mkdir(child) == 0);
    REQUIRE(snprintf(file, sizeof file, "%s/bindings.ldn", child) > 0);
    staged(file, "generated-binding");
    char *bytes; size_t size; uint64_t device, inode;
    REQUIRE(landin_read_snapshot(file, &bytes, &size, &device, &inode) == 0
            && size == 17 && !memcmp(bytes, "generated-binding", 17)); landin_snapshot_free(bytes);
    REQUIRE(step(token, 0) == 0 && step(token, 1) == 0);
#if defined(__linux__) || defined(__APPLE__)
    REQUIRE(step(token, 2) == 0);
    REQUIRE(snprintf(file, sizeof file, "%s/nested/bindings.ldn", output) > 0
            && content(file, "generated-binding"));
    REQUIRE(step(token, 3) == 0 && access(output, F_OK) != 0);
#else
    REQUIRE(step(token, 2) != 0 && strstr(why, "support"));
    REQUIRE(access(output, F_OK) != 0 && step(token, 3) == 0);
#endif
    REQUIRE(step(token, 4) == 0);
    REQUIRE(landin_publication_stage_mkdir(stage) == -1);
    ++passed;
}
static void absent_root_arrivals(void)
{
    for (unsigned phase = 1; phase <= 2; ++phase) {
        char parent[4096], output[8192], spare[8192], stage[4096], leaf[16384];
        REQUIRE(snprintf(parent, sizeof parent, "%s/absent-arrival-%u", scratch, phase) > 0
                && mkdir(parent, 0700) == 0);
        REQUIRE(snprintf(output, sizeof output, "%s/out", parent) > 0);
        REQUIRE(snprintf(spare, sizeof spare, "%s/foreign", parent) > 0 && mkdir(spare, 0700) == 0);
        REQUIRE(snprintf(leaf, sizeof leaf, "%s/sentinel", spare) > 0); put(leaf, "foreign-tree");
        struct stat before, after; REQUIRE(stat(spare, &before) == 0);
        int token = prepare_absent(output, stage);
        REQUIRE(landin_publication_stage_mkdir(stage) == 0);
        REQUIRE(snprintf(leaf, sizeof leaf, "%s/generated", stage) > 0); staged(leaf, "generated");
        REQUIRE(step(token, 0) == 0);
        if (phase == 2) REQUIRE(step(token, 1) == 0);
        arm(phase == 1 ? "before-capture" : "before-install", output, spare, 1);
        REQUIRE(step(token, (int)phase) != 0); clear_hook();
#if !defined(__linux__) && !defined(__APPLE__)
        if (phase == 1) {
            REQUIRE(step(token, 3) != 0 && strstr(why, "recovery"));
            char recovery[8192]; char *split = strstr(stage, "/stage/"); REQUIRE(split);
            REQUIRE(snprintf(recovery, sizeof recovery, "%.*s/recovery/.previous-%d",
                             (int)(split - stage), stage, token) > 0);
            REQUIRE(stat(recovery, &after) == 0 && before.st_dev == after.st_dev
                    && before.st_ino == after.st_ino && before.st_mode == after.st_mode);
            REQUIRE(snprintf(leaf, sizeof leaf, "%s/sentinel", recovery) > 0 && content(leaf, "foreign-tree"));
            REQUIRE(step(token, 4) != 0); continue;
        }
#endif
        REQUIRE(step(token, 3) == 0 && step(token, 4) == 0);
        REQUIRE(stat(output, &after) == 0 && before.st_dev == after.st_dev
                && before.st_ino == after.st_ino && before.st_mode == after.st_mode);
        REQUIRE(snprintf(leaf, sizeof leaf, "%s/sentinel", output) > 0 && content(leaf, "foreign-tree"));
    }
    ++passed;
}
static void pinned_stage_directories(void)
{
    char parent[4096], parked[4096], output[8192], stage[4096], arena[4096];
    char nested[8192], file[16384], actual[16384], outside[4096];
    path(parent, sizeof parent, "mkdir-parent"); REQUIRE(mkdir(parent, 0700) == 0);
    path(parked, sizeof parked, "mkdir-parent-moved");
    REQUIRE(snprintf(output, sizeof output, "%s/out", parent) > 0);
    int token = prepare_absent(output, stage);
    REQUIRE(rename(parent, parked) == 0 && mkdir(parent, 0700) == 0);
    strcpy(arena, stage); char *last = strrchr(arena, '/'); REQUIRE(last); *last = 0;
    last = strrchr(arena, '/'); REQUIRE(last); *last = 0;
    REQUIRE(mkdir(arena, 0700) == 0); *last = '/';
    REQUIRE(mkdir(arena, 0700) == 0); /* Foreign duplicate arena/stage spelling. */
    REQUIRE(landin_publication_stage_mkdir(stage) == 0 && access(stage, F_OK) != 0);
    REQUIRE(snprintf(actual, sizeof actual, "%s%s", parked, stage + strlen(parent)) > 0);
    struct stat found; REQUIRE(stat(actual, &found) == 0 && S_ISDIR(found.st_mode));
    REQUIRE(snprintf(nested, sizeof nested, "%s/nested", stage) > 0
            && landin_publication_stage_mkdir(nested) == 0);
    REQUIRE(snprintf(file, sizeof file, "%s/data", nested) > 0); staged(file, "pinned-data");
    path(outside, sizeof outside, "mkdir-outside"); REQUIRE(mkdir(outside, 0700) == 0);
    REQUIRE(snprintf(file, sizeof file, "%s/bad", actual) > 0 && symlink(outside, file) == 0);
    REQUIRE(snprintf(nested, sizeof nested, "%s/bad/no", stage) > 0
            && landin_publication_stage_mkdir(nested) == -1);
    REQUIRE(snprintf(nested, sizeof nested, "%s/no", outside) > 0 && access(nested, F_OK) != 0);
    REQUIRE(unlink(file) == 0);
    REQUIRE(step(token, 0) == 0 && step(token, 3) == 0 && step(token, 4) == 0);
    REQUIRE(landin_publication_stage_mkdir(stage) == -1 && access(stage, F_OK) != 0);
    for (unsigned kind = 0; kind < 2; ++kind) {
        REQUIRE(snprintf(parent, sizeof parent, "%s/occupied-stage-%u", scratch, kind) > 0 && mkdir(parent, 0700) == 0);
        REQUIRE(snprintf(output, sizeof output, "%s/out", parent) > 0);
        token = prepare_absent(output, stage);
        if (kind == 0) {
            REQUIRE(mkdir(stage, 0700) == 0);
            REQUIRE(snprintf(file, sizeof file, "%s/unknown", stage) > 0); put(file, "unknown-private");
        } else REQUIRE(symlink(outside, stage) == 0);
        struct stat before, after; REQUIRE(lstat(stage, &before) == 0);
        REQUIRE(landin_publication_stage_mkdir(stage) == -1);
        REQUIRE(step(token, 3) == 0 && step(token, 4) != 0 && strstr(why, "recovery"));
        REQUIRE(lstat(stage, &after) == 0 && before.st_dev == after.st_dev
                && before.st_ino == after.st_ino && before.st_mode == after.st_mode);
        if (kind == 0) REQUIRE(content(file, "unknown-private"));
        REQUIRE(access(output, F_OK) != 0);
    }
    ++passed;
}

int main(int argc, char **argv)
{
    self_program = argv[0];
    if (argc == 3 && !strcmp(argv[1], "--constructor-failure"))
        return constructor_failure_child(argv[2]);
    if (argc == 6 && !strcmp(argv[1], "--changing-peer")) {
        changing_path = argv[3];
        changing_ready = atoi(argv[4]); changing_release = atoi(argv[5]);
        landin_file_identity_set_hook(changing_identity_hook);
        landin_publication_set_hook(changing_publication_hook);
        char stage[4096]; int token = prepare(argv[2], 0, "", stage);
        clear_hook(); landin_file_identity_set_hook(NULL);
        REQUIRE(changing_barriers == 1);
        close(changing_ready); close(changing_release);
        staged(stage, "peer-generated");
        REQUIRE(step(token, 0) == 0 && step(token, 1) == 0
                && step(token, 2) == 0 && step(token, 4) == 0);
        return 0;
    }
    if (argc == 5 && (!strcmp(argv[1], "--retirement-peer")
                     || !strcmp(argv[1], "--retirement-refusal-peer")
                     || !strcmp(argv[1], "--retirement-late-refusal-peer"))) {
        retirement_ready = atoi(argv[3]); retirement_release = atoi(argv[4]);
        retirement_late_replacement = !strcmp(argv[1], "--retirement-late-refusal-peer");
        landin_publication_set_hook(retirement_hook);
        char stage[4096]; int token;
        int result = landin_publication_open(argv[2], 0, "", &token, stage,
                                             sizeof stage, why, sizeof why);
        clear_hook(); REQUIRE(retirement_barriers == (retirement_late_replacement ? 2u : 1u));
        close(retirement_ready); close(retirement_release);
        if (strcmp(argv[1], "--retirement-peer")) {
            REQUIRE(result != 0 && token == 0 && strstr(why, "retained or active publication"));
            return 0;
        }
        REQUIRE(result == 0);
        staged(stage, "peer-generated");
        REQUIRE(step(token, 0) == 0 && step(token, 1) == 0
                && step(token, 2) == 0 && step(token, 4) == 0);
        return 0;
    }
    if (argc == 3 && !strcmp(argv[1], "--publish-peer")) {
        char stage[4096]; int token = prepare(argv[2], 0, "", stage);
        staged(stage, "peer-generated");
        REQUIRE(step(token, 0) == 0 && step(token, 1) == 0
                && step(token, 2) == 0 && step(token, 4) == 0);
        return 0;
    }
    if (argc == 3 && !strcmp(argv[1], "--discover")) {
        int token; char stage[4096];
        REQUIRE(landin_publication_open(argv[2], 0, "", &token, stage,
                                        sizeof stage, why, sizeof why) != 0);
        REQUIRE(strstr(why, "retained or active publication") != NULL);
        return 0;
    }
    const char *tmp = getenv("TMPDIR"); if (!tmp || !*tmp) tmp = "/tmp";
    REQUIRE(snprintf(scratch, sizeof scratch, "%s/landin-publication-XXXXXX", tmp) > 0);
    REQUIRE(mkdtemp(scratch) != NULL);
    if (argc == 2 && !strcmp(argv[1], "--identity-observation")) {
        identity_observations();
        printf("publication native: %u controls passed (identity observation)\n", passed);
        return 0;
    }
    identity_observations();
    required_absence_snapshot(); absent_directory_publication();
    absent_root_arrivals(); pinned_stage_directories();
    ordinary_group(); capture_actual(); absence_and_noclobber(); protected_alias();
    anchored_stage_and_roots(); directory_snapshot(); staged_rewrite();
    fmt_read_boundaries(); fmt_original_descriptor(); collision_names();
    repeated_abort_retains_recovery(); recovery_discovery();
    child_staging_directory(); mismatch_finish_preserves_tree();
    moved_anchor_recovery_diagnostic(); fmt_moved_parent_diagnostic();
    fmt_readonly_is_write_refusal(); different_output_kind_is_refused();
    journal_concurrency(); discovery_during_retirement();
    discovery_during_publication(); pinned_entry_name_equivalence();
    unknown_unready_recovery_refuses(); constructor_failure_is_discoverable();
    printf("publication native: %u controls passed; retained scratch %s\n", passed, scratch);
    return 0;
}
