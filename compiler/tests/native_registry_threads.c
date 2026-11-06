/* Production registries are process-wide; resources may cross worker threads.
   No hook or process-wide signal/environment configuration changes while live. */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L
#include "landin_publication.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
int landin_tool_capture(char *, size_t);
int landin_tool_capture_read(int, char **, size_t *);
int landin_tool_capture_close(int, char *, size_t);
int landin_private_directory(const char *, char *, size_t);
int landin_remove_tree(const char *);
int landin_private_mkdir(const char *);
int landin_private_write(const char *, const char *, size_t);
int landin_private_argument_directory(const char *);
int landin_private_rebase_argument(const char *, int, char *, size_t);
int landin_open_update(const char *, char **, size_t *, int *, char *, size_t);
int landin_update_identity(int, uint64_t *, uint64_t *);
int landin_replace_update(int, const char *, size_t, char *, size_t);
void landin_close_update(int);
#define THREADS 8
#define ROUNDS 24
#define CHECK(x) do { if (!(x)) { fprintf(stderr, \
    "registry thread failure line %d: %s errno=%d\n", __LINE__, #x, errno); \
    exit(1); } } while (0)
static char scratch[4096];
struct resources {
    int capture, publication, lease;
    char root[4096], private_file[8192], output[8192], source[8192], stage[4096];
};
static struct resources resources[THREADS];
/* pthread_barrier_t is not available on Darwin. This reusable rendezvous also
   establishes the memory ordering for deliberate handle handoff. */
static pthread_mutex_t rendezvous_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t rendezvous_condition = PTHREAD_COND_INITIALIZER;
static unsigned arrived, generation;
static void rendezvous(void)
{
    CHECK(pthread_mutex_lock(&rendezvous_mutex) == 0);
    unsigned observed = generation;
    if (++arrived == THREADS) {
        arrived = 0; ++generation;
        CHECK(pthread_cond_broadcast(&rendezvous_condition) == 0);
    } else while (generation == observed)
        CHECK(pthread_cond_wait(&rendezvous_condition, &rendezvous_mutex) == 0);
    CHECK(pthread_mutex_unlock(&rendezvous_mutex) == 0);
}
static void put(const char *path, const char *text)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    CHECK(fd >= 0 && write(fd, text, strlen(text)) == (ssize_t)strlen(text));
    CHECK(close(fd) == 0);
}
static void snapshot(const char *path, const char *expected)
{
    char *bytes; size_t size; uint64_t device, inode;
    CHECK(landin_read_snapshot(path, &bytes, &size, &device, &inode) == 0);
    if (size != strlen(expected) || memcmp(bytes, expected, size) || !inode) {
        fprintf(stderr, "snapshot mismatch: %s expected=%s length=%zu\n", path, expected, size);
        exit(1);
    }
    landin_snapshot_free(bytes);
}
static void *worker(void *argument)
{
    unsigned slot = *(unsigned *)argument;
    for (unsigned round = 0; round < ROUNDS; ++round) {
        struct resources *own = &resources[slot];
        char reason[16384], capture_path[4096], *bytes;
        size_t size; uint64_t device, inode;
        rendezvous();
        own->capture = landin_tool_capture(capture_path, sizeof capture_path);
        CHECK(own->capture >= 0 && write(own->capture, "capture", 7) == 7);
        CHECK(landin_private_directory("registry-thread-", own->root, sizeof own->root) == 0);
        char private_path[sizeof own->private_file];
        int path_size = snprintf(private_path, sizeof private_path, "%s/nested", own->root);
        CHECK(path_size > 0 && (size_t)path_size + sizeof "/file" <= sizeof private_path);
        memcpy(own->private_file, private_path, (size_t)path_size + 1);
        CHECK(landin_private_mkdir(own->private_file) == 0);
        memcpy(own->private_file + path_size, "/file", sizeof "/file");
        CHECK(landin_private_write(own->private_file, "private", 7) == 0);
        CHECK(snprintf(own->output, sizeof own->output, "%s/output-%u-%u", scratch, slot, round) > 0);
        CHECK(snprintf(own->source, sizeof own->source, "%s/source-%u-%u", scratch, slot, round) > 0);
        put(own->output, "old"); put(own->source, "old");
        CHECK(landin_publication_open(own->output, 0, "", &own->publication,
            own->stage, sizeof own->stage, reason, sizeof reason) == 0);
        CHECK(landin_publication_stage_write(own->stage, "published", 9) == 0);
        CHECK(landin_open_update(own->source, &bytes, &size, &own->lease,
                                 reason, sizeof reason) == 0);
        CHECK(size == 3 && !memcmp(bytes, "old", 3)); free(bytes);
        rendezvous();
        /* Every resource is now consumed by a different thread. */
        struct resources *peer = &resources[(slot + 1) % THREADS];
        CHECK(landin_tool_capture_read(peer->capture, &bytes, &size) == 0);
        CHECK(size == 7 && !memcmp(bytes, "capture", 7)); free(bytes);
        CHECK(landin_tool_capture_close(peer->capture, reason, sizeof reason) == 0);
        snapshot(peer->private_file, "private");
        int directory = landin_private_argument_directory(peer->private_file);
        char rebased[8192];
        CHECK(directory >= 0 && landin_private_rebase_argument(peer->private_file,
            directory, rebased, sizeof rebased) == 0 && !strcmp(rebased, "./nested/file"));
        CHECK(close(directory) == 0);
        directory = landin_publication_stage_directory(peer->stage);
        CHECK(directory >= 0 && landin_publication_rebase_argument(peer->stage,
            directory, rebased, sizeof rebased) == 0 && rebased[0] == '.');
        CHECK(close(directory) == 0);
        snapshot(peer->stage, "published");
        for (int action = 0; action <= 2; ++action)
            CHECK(landin_publication_step(peer->publication, action, NULL, 0,
                NULL, 0, reason, sizeof reason) == 0);
        CHECK(landin_publication_step(peer->publication, 4, NULL, 0,
            NULL, 0, reason, sizeof reason) == 0);
        snapshot(peer->output, "published");
        errno = EDOM;
        CHECK(landin_update_identity(peer->lease, &device, &inode) == 0 && inode);
        CHECK(errno == EDOM);
        CHECK(landin_replace_update(peer->lease, "formatted", 9, reason, sizeof reason) == 0);
        landin_close_update(peer->lease); snapshot(peer->source, "formatted");
        CHECK(landin_remove_tree(peer->root) == 1);
        CHECK(unlink(peer->source) == 0 && unlink(peer->output) == 0);
        rendezvous();
    }
    return NULL;
}
int main(void)
{
    const char *tmp = getenv("TMPDIR");
    CHECK(snprintf(scratch, sizeof scratch, "%s/landin-registry-threads-XXXXXX",
                    tmp ? tmp : "/tmp") > 0);
    CHECK(mkdtemp(scratch) != NULL);
    pthread_t threads[THREADS]; unsigned slots[THREADS];
    for (unsigned i = 0; i < THREADS; ++i) {
        slots[i] = i; CHECK(pthread_create(&threads[i], NULL, worker, &slots[i]) == 0);
    }
    for (unsigned i = 0; i < THREADS; ++i) CHECK(pthread_join(threads[i], NULL) == 0);
    CHECK(rmdir(scratch) == 0);
    printf("native registry threads: %u workers, %u rounds, %u cross-thread handoffs passed\n",
           THREADS, ROUNDS, THREADS * ROUNDS * 4);
    return 0;
}
