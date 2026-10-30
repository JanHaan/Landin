#include <pthread.h>
#include <stdint.h>

/* Both workers start their overflowing task only once both are ready, so
 * that their checks fail within a moment of each other. */
extern void r1440_overflow(int32_t which);

static pthread_mutex_t gate_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_condition = PTHREAD_COND_INITIALIZER;
static int arrived;

static void *run_worker(void *opaque)
{
    int32_t which = (int32_t)(intptr_t)opaque;

    pthread_mutex_lock(&gate_mutex);
    ++arrived;
    pthread_cond_broadcast(&gate_condition);
    while (arrived < 2) {
        pthread_cond_wait(&gate_condition, &gate_mutex);
    }
    pthread_mutex_unlock(&gate_mutex);
    r1440_overflow(which);
    return NULL;
}

int32_t r1440_run_overflowing_threads(void)
{
    pthread_t threads[2];

    for (intptr_t index = 0; index < 2; ++index) {
        if (pthread_create(&threads[index], NULL, run_worker,
                           (void *)index) != 0) {
            return 1;
        }
    }
    for (int index = 0; index < 2; ++index) {
        (void)pthread_join(threads[index], NULL);
    }
    return 2;
}
