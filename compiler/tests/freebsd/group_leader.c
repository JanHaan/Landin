/* Run a fixture's program as the leader of a process group of its own, as
   the test program's tool runner and Darwin's parity runner start every
   program: `group_leader PROGRAM ARGUMENT...`.  The guest script runs each
   program under timeout(1), which makes itself the group's leader, so
   without this a program that signals its own group (runtime/
   posix-kill-group) would find it led by timeout and stop, and one that
   did signal it would signal timeout too. */
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc < 2) {
        fputs("usage: group_leader PROGRAM ARGUMENT...\n", stderr);
        return 125;
    }
    if (setpgid(0, 0) != 0) {
        perror("group_leader: setpgid");
        return 125;
    }
    execv(argv[1], argv + 1);
    perror("group_leader: execv");
    return 126;
}
