/*
 * Hands the argument initializer tables of four kinds, each in a process
 * of its own, since a root is established once: tables a C main built on
 * its own stack, C's environ after setenv has moved it, a copy of the
 * real tables in the heap, and the real initial stack's argv and envp.
 * Only the last is adopted, and what platform/linux then reports is what
 * the C library's getauxval reports.
 */
#define _GNU_SOURCE
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern void _landin_host_initialize_arguments(int count, char **values,
                                              char **environment);
extern uint64_t l_auxiliary(uint64_t tag);
extern size_t l_page_size(void);
extern bool l_vdso(void);
extern bool l_environment(void);
extern int64_t l_monotonic(void);

extern char **environ;

/* Nothing adopted: no vector, the fallback page size, no vDSO, no
   environment, and the clock still read through the system call. */
static int refused(void)
{
    if (l_auxiliary(AT_PAGESZ) != 0 || l_page_size() != 4096 || l_vdso()
        || l_environment())
        return 1;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    int64_t before = (int64_t)now.tv_sec * 1000000000 + now.tv_nsec;
    int64_t ours = l_monotonic();
    return ours >= before ? 0 : 2;
}

/* Run SCENARIO in a child and report its exit status. */
static int in_child(int scenario, int argc, char **argv)
{
    pid_t child = fork();
    if (child == 0) {
        if (scenario == 1) {
            /* argv and envp contiguous, as the kernel lays them, but on
               C's own stack with their strings in read-only data. */
            char *tables[] = {"program", NULL, "NAME=value", NULL};
            _landin_host_initialize_arguments(1, tables, tables + 2);
        } else if (scenario == 2) {
            setenv("LANDIN_MOVED", "1", 1);
            _landin_host_initialize_arguments(argc, argv, environ);
        } else {
            /* A heap copy, contiguous, of the real tables. */
            size_t count = 0;
            while (environ[count] != NULL)
                count++;
            char **copy = calloc((size_t)argc + count + 2, sizeof *copy);
            memcpy(copy, argv, (size_t)argc * sizeof *copy);
            memcpy(copy + argc + 1, environ, count * sizeof *copy);
            _landin_host_initialize_arguments(argc, copy, copy + argc + 1);
        }
        _exit(refused());
    }
    int status = 0;
    if (child < 0 || waitpid(child, &status, 0) != child
        || !WIFEXITED(status))
        return 100;
    return WEXITSTATUS(status);
}

int main(int argc, char **argv, char **envp)
{
    for (int scenario = 1; scenario <= 3; scenario++)
        if (in_child(scenario, argc, argv) != 0)
            return scenario;
    _landin_host_initialize_arguments(argc, argv, envp);
    if (!l_environment())
        return 4;
    /* Not AT_HWCAP: glibc's getauxval answers it with a value of its
       own on x86-64, not the kernel's. */
    const unsigned long tags[] = {AT_PAGESZ, AT_SYSINFO_EHDR, AT_RANDOM,
                                  AT_ENTRY, AT_PHDR, AT_EXECFN, AT_UID};
    for (size_t at = 0; at < sizeof tags / sizeof tags[0]; at++)
        if (l_auxiliary(tags[at]) != getauxval(tags[at]))
            return 5;
    if (l_page_size() != getauxval(AT_PAGESZ))
        return 6;
    if (!l_vdso())
        return 7;
    return 42;
}
