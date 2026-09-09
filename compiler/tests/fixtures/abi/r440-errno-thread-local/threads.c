#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

/* Each C worker calls an exported Landin routine, which reaches this wrapper
 * only through the compiler-emitted _landin_host_open_read bridge. */
extern int32_t r440_errno_thread_probe(void *state, int32_t expected);

struct worker {
    void *state;
    int32_t expected;
    int32_t result;
};

static pthread_mutex_t rendezvous_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t rendezvous_condition = PTHREAD_COND_INITIALIZER;
static unsigned int arrived;
static int released;
static atomic_uint errno_ready = ATOMIC_VAR_INIT(0);

_Static_assert(ATOMIC_INT_LOCK_FREE == 2,
               "x86-64 fixture requires lock-free atomic integers");
_Static_assert(EIO == 5 && ENOSPC == 28,
               "fixture requires Linux errno values");

static _Thread_local int32_t local_expected;
static _Thread_local unsigned int local_open_calls;
static _Thread_local int local_fault;

static int rendezvous(void)
{
    int result = pthread_mutex_lock(&rendezvous_mutex);
    int unlock_result;

    if (result != 0) {
        return result;
    }

    ++arrived;
    if (arrived == 2) {
        released = 1;
        result = pthread_cond_broadcast(&rendezvous_condition);
    }
    while (!released && result == 0) {
        result = pthread_cond_wait(&rendezvous_condition,
                                   &rendezvous_mutex);
    }

    unlock_result = pthread_mutex_unlock(&rendezvous_mutex);
    return result != 0 ? result : unlock_result;
}

static void release_waiter(void)
{
    atomic_store_explicit(&errno_ready, 2, memory_order_seq_cst);
    if (pthread_mutex_lock(&rendezvous_mutex) == 0) {
        released = 1;
        (void)pthread_cond_broadcast(&rendezvous_condition);
        (void)pthread_mutex_unlock(&rendezvous_mutex);
    }
}

int __wrap_open(const char *path, int flags, ...)
{
    ++local_open_calls;
    if (local_open_calls != 1 || flags != O_RDONLY
        || strcmp(path, "r440-thread") != 0) {
        local_fault = 1;
    }

    if (local_open_calls == 1 && rendezvous() != 0) {
        local_fault = 2;
    }

    /* Both threads assign their distinct real libc slots before either bridge
     * can capture one.  The post-assignment rendezvous is lock-free C11 code,
     * so no unrelated libc call occurs between this assignment and return. */
    errno = (int)local_expected;
    (void)atomic_fetch_add_explicit(&errno_ready, 1, memory_order_seq_cst);
    while (atomic_load_explicit(&errno_ready, memory_order_seq_cst) < 2) {
        /* Wait only for the other actual pthread to publish its errno. */
    }
    return -1;
}

static void *run_worker(void *opaque)
{
    struct worker *work = opaque;

    local_expected = work->expected;
    local_open_calls = 0;
    local_fault = 0;
    work->result = r440_errno_thread_probe(work->state, work->expected);
    if (work->result == 42 && local_open_calls != 1) {
        local_fault = 3;
    }
    if (local_fault != 0) {
        work->result = 100 + local_fault;
    }
    return NULL;
}

int32_t r440_run_errno_threads(void *first, void *second)
{
    pthread_t first_thread;
    pthread_t second_thread;
    struct worker workers[2] = {
        {first, EIO, 0},
        {second, ENOSPC, 0}
    };
    int first_create;
    int second_create;
    int first_join;
    int second_join;

    arrived = 0;
    released = 0;
    atomic_store_explicit(&errno_ready, 0, memory_order_seq_cst);

    first_create = pthread_create(&first_thread, NULL, run_worker, &workers[0]);
    if (first_create != 0) {
        return 1;
    }

    second_create = pthread_create(&second_thread, NULL, run_worker,
                                    &workers[1]);
    if (second_create != 0) {
        release_waiter();
        (void)pthread_join(first_thread, NULL);
        return 2;
    }

    first_join = pthread_join(first_thread, NULL);
    second_join = pthread_join(second_thread, NULL);
    if (first_join != 0 || second_join != 0) {
        return 3;
    }
    if (workers[0].result != 42 || workers[1].result != 42) {
        return 4;
    }
    return 42;
}
