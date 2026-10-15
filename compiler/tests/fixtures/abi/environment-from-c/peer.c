/*
 * A C main starts Landin with an environment table of its own, built here
 * rather than the process's, and hands it to Landin through the argument
 * root.  Landin lists it and looks names up; this side checks that the
 * value it was lent is the table's own string, not a copy.  A second
 * initialization with a null table is the identical root only when the
 * first was null too, so this peer makes one call.
 */
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

extern void _landin_host_initialize_arguments(int argc, char **argv,
                                              char **envp);
extern int32_t l_environment(void);

static char program[] = "environment-from-c";
static char *arguments[] = { program, 0 };
static char text[] = "TEXT=hello";
static char bytes[] = "BYTES=\xff\xfe";
static char equals[] = "EQUALS=a=b";
static char empty[] = "EMPTY=";
static char bare[] = "BARE";
static char twice[] = "TEXT=second";
static char *environment[] = { text, bytes, equals, empty, bare, twice, 0 };

/* Whether Landin was lent the first TEXT's value inside its own entry. */
bool c_value_is_entry(const unsigned char *value, size_t length)
{
    return (const char *)value == text + 5 && length == 5;
}

int main(void)
{
    _landin_host_initialize_arguments(1, arguments, environment);
    return l_environment();
}
