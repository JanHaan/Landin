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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int landin_open_update(const char *, char **, size_t *, int *, char *, size_t);
int landin_replace_update(int, const char *, size_t, char *, size_t);
void landin_close_update(int);
static char scratch[4096], why[8192];
static unsigned passed;
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
int main(void)
{
    const char *tmp = getenv("TMPDIR"); if (!tmp || !*tmp) tmp = "/tmp";
    REQUIRE(snprintf(scratch, sizeof scratch, "%s/landin-publication-XXXXXX", tmp) > 0);
    REQUIRE(mkdtemp(scratch) != NULL);
    ordinary_group(); capture_actual(); absence_and_noclobber(); protected_alias();
    anchored_stage_and_roots(); directory_snapshot(); fmt_original_descriptor();
    printf("publication native: %u controls passed; retained scratch %s\n", passed, scratch);
    return 0;
}
