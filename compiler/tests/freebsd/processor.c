/* Ask the guest OS and CPU, before executing a higher-level consumer. */
#include <stdio.h>
#if defined(__aarch64__)
#include <sys/auxv.h>
#include <machine/elf.h>
int main(void)
{
    unsigned long capabilities = 0;
    if (elf_aux_info(AT_HWCAP, &capabilities, sizeof capabilities)) return 1;
    printf("FreeBSD HWCAP=%#lx\n", capabilities);
    const unsigned long selected = HWCAP_ATOMICS | HWCAP_CRC32 | HWCAP_ASIMDRDM;
    if ((capabilities & selected) != selected) return 2;
    puts("confirmed armv8.1-a: lse crc32 rdm");
    return 0;
}
#else
#include <cpuid.h>
int main(void)
{
    unsigned int a, b, c, d;
    if (!__get_cpuid(1, &a, &b, &c, &d)) return 1;
    /* v2 plus v3: CPUID leaf 1, leaf 7 and extended leaf 1; XCR0 proves
       that the OS enables AVX state as well as the CPU advertising it. */
    unsigned int leaf1 = (1u<<0)|(1u<<9)|(1u<<13)|(1u<<19)|(1u<<20)|(1u<<23);
    unsigned int avx = (1u<<12)|(1u<<22)|(1u<<26)|(1u<<27)|(1u<<28)|(1u<<29);
    printf("CPUID.1 ECX=%#x\n", c);
    if ((c & (leaf1 | avx)) != (leaf1 | avx)) return 2;
    unsigned int xlo, xhi;
    __asm__ volatile("xgetbv" : "=a"(xlo), "=d"(xhi) : "c"(0));
    if ((xlo & 6) != 6) return 3;
    if (!__get_cpuid_count(7, 0, &a, &b, &c, &d)) return 4;
    printf("CPUID.7 EBX=%#x XCR0=%#x:%#x\n", b, xhi, xlo);
    unsigned int leaf7 = (1u<<3)|(1u<<5)|(1u<<8);
    if ((b & leaf7) != leaf7) return 5;
    if (!__get_cpuid(0x80000001, &a, &b, &c, &d)) return 6;
    if ((c & ((1u<<0)|(1u<<5))) != ((1u<<0)|(1u<<5))) return 7;
    puts("confirmed x86-64-v3");
    return 0;
}
#endif
