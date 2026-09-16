/* Independently observe shared backing after a child traps before its store. */
#define _GNU_SOURCE
#include <assert.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <unistd.h>
uint32_t invalid(uint32_t mode) { return mode ? 0 : 0x100; }
extern void guarded(uint32_t *, uint32_t);
int main(void) {
    const struct rlimit no_core = {0, 0};
    assert(setrlimit(RLIMIT_CORE, &no_core) == 0);
    uint32_t *word = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                         MAP_SHARED | MAP_ANON, -1, 0);
    assert(word != MAP_FAILED);
    for (uint32_t mode = 0; mode != 2; ++mode) {
        *word = 0xdeadbeef;
        pid_t child = fork();
        assert(child >= 0);
        if (child == 0) { guarded(word, mode); _Exit(99); }
        int status;
        assert(waitpid(child, &status, 0) == child);
        assert(WIFSIGNALED(status));
#ifdef __APPLE__
        assert(WTERMSIG(status) == SIGTRAP);
#else
        assert(WTERMSIG(status) == SIGILL);
#endif
        assert(*word == 0xdeadbeef);
    }
    assert(munmap(word, 4096) == 0);
    return 42;
}
