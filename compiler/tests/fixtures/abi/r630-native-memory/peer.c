/* Independent pthread scheduling and C atomic controls. No C racy accesses. */
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdatomic.h>
extern void add_many(uint32_t *);
extern void publish(uint32_t *, uint32_t *);
extern uint32_t consume(const uint32_t *, const uint32_t *);
extern uint32_t alias_bytes(uint32_t *);
extern uint64_t swap_value(uint64_t *, uint64_t, uint64_t);
extern uint32_t fenced(uint32_t *, const uint32_t *);
static uint32_t count, data, flag, x, y, r0, r1;
static void *fence_left(void *unused) {
    (void)unused;
    r0 = fenced(&x, &y);
    return 0;
}
static void *fence_right(void *unused) {
    (void)unused;
    r1 = fenced(&y, &x);
    return 0;
}
static _Atomic uint32_t control;
static void *add(void *unused) {
    (void)unused;
    add_many(&count);
    for (int i = 0; i < 2000; ++i)
        atomic_fetch_add_explicit(&control, 1, memory_order_relaxed);
    return 0;
}
static void *send(void *unused) {
    (void)unused;
    publish(&data, &flag);
    return 0;
}
int main(void) {
    pthread_t workers[4];
    for (int i = 0; i < 4; ++i) assert(!pthread_create(&workers[i], 0, add, 0));
    for (int i = 0; i < 4; ++i) assert(!pthread_join(workers[i], 0));
    assert(count == 8000 && atomic_load(&control) == 8000);
    for (int i = 0; i < 32; ++i) {
        data = flag = 0;
        assert(!pthread_create(&workers[0], 0, send, 0));
        uint32_t observed = consume(&data, &flag);
        assert(!pthread_join(workers[0], 0));
        assert(observed == 42);
    }
    /* Bounded litmus: absence of 0/0 corroborates, never proves, the model. */
    for (int i = 0; i < 32; ++i) {
        x = y = 0;
        assert(!pthread_create(&workers[0], 0, fence_left, 0));
        assert(!pthread_create(&workers[1], 0, fence_right, 0));
        assert(!pthread_join(workers[0], 0));
        assert(!pthread_join(workers[1], 0));
        assert(r0 <= 1 && r1 <= 1 && (r0 || r1));
    }
    uint64_t value = UINT64_MAX;
    assert(swap_value(&value, 0, 17) == UINT64_MAX && value == UINT64_MAX);
    assert(swap_value(&value, UINT64_MAX, 17) == UINT64_MAX && value == 17);
    assert(alias_bytes(&count) == 42);
    return 42;
}
