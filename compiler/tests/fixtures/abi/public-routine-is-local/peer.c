/* Resolves to null unless some object defines a global `visible_probe`. */
extern int visible_probe(int value) __attribute__((weak));

int peer_finds_probe(void)
{
    return visible_probe != 0;
}
