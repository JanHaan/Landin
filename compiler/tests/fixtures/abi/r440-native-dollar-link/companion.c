#if defined(__APPLE__)
#define OBJECT_NAME(name) "_" name
#define QUOTED_NAME(name) OBJECT_NAME(name)
#else
#define OBJECT_NAME(name) name
#define QUOTED_NAME(name) "\"" name "\""
#endif

extern int landin_export(int value) __asm__(QUOTED_NAME("$r440_export"));
int foreign(int value) __asm__(QUOTED_NAME("$r440_foreign"));

int foreign(int value) { return value + 1; }

static int (*volatile callback)(int) = landin_export;

int main(void)
{
    if (landin_export(13) != 3 * foreign(13)) return 1;
    return callback(13) == 42 ? 42 : 2;
}
