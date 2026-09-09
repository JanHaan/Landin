extern int landin_export(int value) __asm__("\"$r440_export\"");
int foreign(int value) __asm__("\"$r440_foreign\"");

int foreign(int value) { return value + 1; }

static int (*volatile callback)(int) = landin_export;

int main(void)
{
    if (landin_export(13) != 3 * foreign(13)) return 1;
    return callback(13) == 42 ? 42 : 2;
}
