/* Literal independent membership oracle; every byte is exercised. */
#include <assert.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <unistd.h>
extern int32_t decode(uint8_t);
int main(void) {
    const struct rlimit no_core = {0, 0};
    assert(setrlimit(RLIMIT_CORE, &no_core) == 0);
    for (unsigned raw = 0; raw != 256; ++raw) {
        unsigned field = (raw / 4) % 8;
        if (field == 0 || field == 1 || field == 4) {
            assert(decode((uint8_t)raw) == (field == 0 ? 10 : field == 1 ? 20 : 30));
        } else {
            pid_t child = fork();
            assert(child >= 0);
            if (child == 0) { (void)decode((uint8_t)raw); _Exit(99); }
            int status;
            assert(waitpid(child, &status, 0) == child);
            assert(WIFSIGNALED(status));
#ifdef __APPLE__
            assert(WTERMSIG(status) == SIGTRAP);
#else
            assert(WTERMSIG(status) == SIGILL);
#endif
        }
    }
    return 42;
}
