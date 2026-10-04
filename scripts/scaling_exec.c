/* Run the compiler from a small native process image. getrusage's peak RSS
 * survives exec, so forking directly from the Python generator can attribute
 * the generator's resident memory to the compiler. This extra fork resets
 * that history after the native image has replaced Python. POSIX hosts only,
 * like the compiler's supported Linux and Darwin hosts. */
#include <errno.h>
#include <stdio.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    pid_t child = fork();
    if (child < 0) {
        perror("scaling fork");
        return 2;
    }
    if (child == 0) {
        execv(argv[1], argv + 1);
        perror("scaling exec");
        _exit(127);
    }
    int status;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) {
            perror("scaling wait");
            return 2;
        }
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
