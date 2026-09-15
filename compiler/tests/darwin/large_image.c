/* Native toolchain control for the existing 2 GiB reserved-storage fixture.
 * This deliberately has the same virtual reservation and status-42 oracle.
 * It creates no multi-gigabyte file and touches only the last byte. */
static volatile unsigned char far[2147483648ULL];
int main(void)
{
    far[2147483647ULL] = 42;
    return far[2147483647ULL];
}
