#include <stddef.h>

extern char **environ;
extern void _landin_host_initialize_arguments(int argc, char **argv,
                                              char **envp);
extern size_t l_root(void);
static char replacement_name[] = "replacement";
static char *replacement[] = {replacement_name, NULL};

void c_replace_root(const void *state)
{
    (void)state;
    /* This is a valid, genuinely backed argument vector, but not the vector
       whose capability is already live in the calling Landin frame. */
    _landin_host_initialize_arguments(1, replacement, environ);
}

int main(int argc, char **argv)
{
    if (argc != 1)
        return 1;
    _landin_host_initialize_arguments(argc, argv, environ);
    (void)l_root();
    return 2;
}
