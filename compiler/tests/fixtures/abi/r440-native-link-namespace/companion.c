extern int r440_link_identity(void);

int foo(void) { return 40; }
int landin_1_foo(void) { return 100; }
int payload(void) { return 300; }
int block_foreign(void) __asm__(".L1_1");
int retry_foreign(void) __asm__(".L_1_1");
int block_foreign(void) { return 11; }
int retry_foreign(void) { return 13; }

int main(void)
{
    /* The private function, private datum and colliding candidate are not
       definitions or aliases of any of these real C functions. Nor may
       compiler-local labels capture an explicitly linked dot-prefixed name. */
    int expected = 1 + foo() + landin_1_foo() + 5 + 7 + payload()
        + block_foreign() + retry_foreign();
    return r440_link_identity() == expected ? 42 : 1;
}
