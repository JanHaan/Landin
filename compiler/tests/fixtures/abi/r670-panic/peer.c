#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

extern void run_path(uint32_t mode, int32_t value);
static volatile uint32_t *events;
static uint32_t selected;

void record(uint32_t kind, uint32_t site)
{
    events[0]++;
    events[1] = kind;
    events[2] = site;
}
void finish(void) { _exit(42); }
void mark(uint32_t value) { events[3] = value; }
_Bool recurse(void) { return selected == 9; }
void wrongly_returns(void) { }

int main(void)
{
    /* Independent source-byte pins, not values read from generated assembly.
       Each byte reserves four family slots: 1 + 4*offset + family-1. */
    static const uint32_t kinds[] = {2,3,1,2,1,3,4,2,2,2,4,3,3,3};
    static const uint32_t sites[] = {3642,3863,4173,4402,4593,4791,4972,3642,2910,3642,0,5447,5855,6659};
    static const int32_t values[] = {1,256,2,0,-1,2,0,1,0,1,0,0,0,255};
    struct rlimit limit = {0, 0};
    if (setrlimit(RLIMIT_CORE, &limit) != 0) return 1;
    events = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                  MAP_SHARED | MAP_ANON, -1, 0);
    if (events == MAP_FAILED) return 2;
    for (selected = 0; selected < 14; ++selected) {
        for (unsigned i = 0; i < 4; ++i) events[i] = 0;
        pid_t child = fork();
        if (child < 0) return 3;
        if (child == 0) { run_path(selected, values[selected]); _exit(99); }
        int status;
        if (waitpid(child, &status, 0) != child) return 4;
        if (events[0] != 1 || events[1] != kinds[selected] ||
            events[2] != sites[selected] || events[3] != 0) return 10 + selected;
        if (selected != 9) {
            if (!WIFEXITED(status) || WEXITSTATUS(status) != 42) return 5;
        } else {
#ifdef __APPLE__
            const int expected = SIGTRAP;
#else
            const int expected = SIGILL;
#endif
            if (!WIFSIGNALED(status) || WTERMSIG(status) != expected) return 6;
        }
    }
    if (munmap((void *)events, 4096) != 0) return 7;
    return 42;
}
