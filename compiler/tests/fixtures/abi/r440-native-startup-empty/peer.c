#include <stdbool.h>
#include <stdio.h>

extern void _landin_host_initialize_arguments(int argc, char **argv);
extern bool l_root(void);
static char **original_argv;

bool c_argument_table(char *const *table)
{
    return table == original_argv + 1;
}

int main(int argc, char **argv)
{
    if (argc != 1)
        return 1;
    original_argv = argv;
    _landin_host_initialize_arguments(argc, argv);
    if (!l_root())
        return 2;
    puts("native empty arguments ok");
    return 42;
}
