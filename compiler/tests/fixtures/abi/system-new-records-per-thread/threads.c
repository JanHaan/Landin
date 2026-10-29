#include <errno.h>
#include <pthread.h>
#include <stdint.h>

/* Both workers fail an open through the one shared handle before either
 * reads its errno back, so a cell the two shared would hold the later
 * failure for both. */
extern int32_t r1440_fail_open(void *shared, int32_t which);
extern int32_t r1440_last_errno(void *shared);

static pthread_mutex_t gate_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_condition = PTHREAD_COND_INITIALIZER;
static int failed;

struct worker {
    void *shared;
    int32_t which;
    int32_t failed;
    int32_t number;
};

static void *run_worker(void *opaque)
{
    struct worker *work = opaque;

    work->failed = r1440_fail_open(work->shared, work->which);
    pthread_mutex_lock(&gate_mutex);
    ++failed;
    pthread_cond_broadcast(&gate_condition);
    while (failed < 2) {
        pthread_cond_wait(&gate_condition, &gate_mutex);
    }
    pthread_mutex_unlock(&gate_mutex);
    work->number = r1440_last_errno(work->shared);
    return NULL;
}

int32_t r1440_run_failing_threads(void *shared)
{
    pthread_t threads[2];
    struct worker work[2] = {{shared, 0, 0, 0}, {shared, 1, 0, 0}};

    for (int index = 0; index < 2; ++index) {
        if (pthread_create(&threads[index], NULL, run_worker,
                           &work[index]) != 0) {
            return 1;
        }
    }
    for (int index = 0; index < 2; ++index) {
        if (pthread_join(threads[index], NULL) != 0) {
            return 2;
        }
    }
    if (work[0].failed != 1 || work[1].failed != 1) {
        return 3;
    }
    if (work[0].number != ENOENT) {
        return 4;
    }
    if (work[1].number != ENOTDIR) {
        return 5;
    }
    return 42;
}
