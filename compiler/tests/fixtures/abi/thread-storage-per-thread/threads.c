#include <pthread.h>
#include <stdint.h>

/* Each worker counts through the exported Landin routine, waiting first
 * until every worker has started, so that all four count at once, and
 * then until every worker has counted and taken its instance's address,
 * so that all four instances are alive when their addresses are compared:
 * Darwin makes a thread's block at its first access and may reuse an
 * ended thread's memory for it. */
extern uint64_t r1440_thread_count(uint32_t rounds, uint64_t mark);
extern uintptr_t r1440_thread_counter_address(void);

enum { workers = 4, rounds = 100000 };

static pthread_mutex_t gate_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_condition = PTHREAD_COND_INITIALIZER;
static int arrived;

struct worker {
    uint64_t mark;
    uint64_t result;
    uintptr_t address;
};

/* Wait until `count` workers have reached this gate. */
static void meet(int *reached, int count)
{
    pthread_mutex_lock(&gate_mutex);
    ++*reached;
    pthread_cond_broadcast(&gate_condition);
    while (*reached < count) {
        pthread_cond_wait(&gate_condition, &gate_mutex);
    }
    pthread_mutex_unlock(&gate_mutex);
}

static int counted;

static void *run_worker(void *opaque)
{
    struct worker *work = opaque;

    meet(&arrived, workers);
    work->result = r1440_thread_count(rounds, work->mark);
    work->address = r1440_thread_counter_address();
    meet(&counted, workers);
    return NULL;
}

int32_t r1440_run_counting_threads(void)
{
    pthread_t threads[workers];
    struct worker work[workers];
    uintptr_t own = r1440_thread_counter_address();

    for (int index = 0; index < workers; ++index) {
        work[index].mark = 1000 + (uint64_t)index;
        work[index].result = 0;
        work[index].address = 0;
        if (pthread_create(&threads[index], NULL, run_worker,
                           &work[index]) != 0) {
            return 1;
        }
    }
    for (int index = 0; index < workers; ++index) {
        if (pthread_join(threads[index], NULL) != 0) {
            return 2;
        }
    }
    for (int index = 0; index < workers; ++index) {
        if (work[index].result != rounds + work[index].mark) {
            return 10 + index;
        }
        if (work[index].address == own || work[index].address == 0) {
            return 20 + index;
        }
        for (int other = 0; other < index; ++other) {
            if (work[other].address == work[index].address) {
                return 30 + index;
            }
        }
    }
    return 42;
}
