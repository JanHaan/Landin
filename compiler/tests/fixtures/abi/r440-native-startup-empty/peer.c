#include <stdbool.h>
#include <stdio.h>

extern char **environ;
extern void _landin_host_initialize_arguments(int argc, char **argv,
                                              char **envp);
extern bool l_root(void);

int main(int argc, char **argv)
{
    if (argc != 1)
        return 1;
    _landin_host_initialize_arguments(argc, argv, environ);
    if (!l_root())
        return 2;
    puts("native empty arguments ok");
    return 42;
}
