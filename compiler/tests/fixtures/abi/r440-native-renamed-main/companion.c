#include <stddef.h>

extern void _landin_host_initialize_arguments(int argc, char **argv);
extern void r440_explicit_start(int argc, char **argv);
extern size_t r440_retained_count(void);
extern int r440_call_renamed(void);

/* An explicit foreign identity cannot alias the compiler's private argv
   storage, even though its spelling used to be that generated data label. */
int r440_foreign_state(void) __asm__(".Llandin_host_argv");
int r440_foreign_state(void) { return 42; }

/* This ordinary SysV wrapper gives the no-argument callback deliberately
   invalid argc/argv carriers. It is not an inline-asm call hidden from the
   compiler's stack alignment or register allocation. */
__asm__(".text\n"
        ".type r440_call_renamed, @function\n"
        "r440_call_renamed:\n"
        "subq $8, %rsp\n"
        "movl $-1, %edi\n"
        "xorl %esi, %esi\n"
        "call r440_renamed_main\n"
        "addq $8, %rsp\n"
        "ret\n"
        ".size r440_call_renamed, .-r440_call_renamed\n");

int main(int argc, char **argv)
{
    if (r440_call_renamed() != 42) return 1;
    r440_explicit_start(argc, argv);
    if (r440_retained_count() != (size_t)(argc > 0 ? argc - 1 : 0)) return 2;
    if (r440_call_renamed() != 42) return 3;
    if (r440_retained_count() != (size_t)(argc > 0 ? argc - 1 : 0)) return 4;
    _landin_host_initialize_arguments(argc, argv);
    return r440_call_renamed();
}
