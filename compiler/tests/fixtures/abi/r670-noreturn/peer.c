#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

extern void run_path(uint32_t mode);
static volatile uint32_t *events;

void mark(uint32_t value) { *events = value; }
void finish(uint32_t value) { _exit(value == 42 ? 42 : 1); }
/* Deliberate foreign contract violation: Landin must guard the return. */
void wrongly_returns(void) { *events = 8; }

int main(void)
{
    struct rlimit limit = {0, 0};
    if (setrlimit(RLIMIT_CORE, &limit) != 0) return 1;
    events = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                  MAP_SHARED | MAP_ANON, -1, 0);
    if (events == MAP_FAILED) return 2;
    for (uint32_t mode = 0; mode < 7; ++mode) {
        *events = 0;
        pid_t child = fork();
        if (child < 0) return 3;
        if (child == 0) { run_path(mode); _exit(99); }
        int status;
        if (waitpid(child, &status, 0) != child) return 4;
        if (*events != (mode == 4 ? 7u : mode == 6 ? 8u : 0u)) return 5;
        if (mode < 6) {
            if (!WIFEXITED(status) || WEXITSTATUS(status) != 42) return 6;
        } else {
#ifdef __APPLE__
            const int expected = SIGTRAP;
#else
            const int expected = SIGILL;
#endif
            if (!WIFSIGNALED(status) || WTERMSIG(status) != expected) return 7;
        }
    }
    if (munmap((void *)events, 4096) != 0) return 8;
    return 42;
}
