/* Independent literal control: no generated headers or Landin declarations. */
typedef unsigned int u32;
#define R(a) (*(volatile u32 *)(a))
volatile u32 fault_seen, stage, notifications, completed, result;
unsigned char buffer[4];
void svc(void) { }
void pendsv(void) { }
void systick(void) { }
void device_irq(void)
{
    u32 pending = R(0x40071400);
    notifications++;
    if (pending != 0) {
        u32 count = R(0x40071008);
        __asm__ volatile ("dmb sy" ::: "memory");
        if (count == 0) completed = 1;
    }
    R(0x40071400) = 1;
    __asm__ volatile ("dsb sy" ::: "memory");
}
void probe(void)
{
    u32 gpio = R(0x40070004);
    R(0x40070004) = (gpio & ~31u) | 2;
    R(0x40070114) = 0x12;
    R(0x40070118) = 2;
    if (R(0x40070110) != 16) return;
    u32 first = R(0x40070200), second = R(0x40070200);
    if (first != 0x41 || second != 0x42) return;
    R(0x40070200) = 0x55;
    R(0x40070244) = 0x10;
    if (R(0x40070218) != 0x90) return;
    R(0x40070310) = 7;
    R(0x40070334) = 1;
    R(0x40070334) = 0;
    if (R(0x40070334) != 2) return;
    R(0xe000e100) = 1;
    R(0x40071000) = 0x40070200;
    R(0x40071004) = (u32)buffer;
    R(0x40071008) = 4;
    R(0x4007100c) = 0xa8020;
    R(0x40071404) = 1;
    __asm__ volatile ("dmb sy" ::: "memory");
    R(0x4007100c) = 0xa8021;
    stage = 1;
    while (stage == 1) __asm__ volatile ("nop" ::: "memory");
    __asm__ volatile ("cpsid i" ::: "memory");
    stage = 3;
    while (stage == 3) __asm__ volatile ("nop" ::: "memory");
    __asm__ volatile ("cpsie i\nisb sy" ::: "memory");
    while (completed == 0) __asm__ volatile ("nop" ::: "memory");
    __asm__ volatile ("dmb sy" ::: "memory");
    result = buffer[0] + buffer[1] + buffer[2] + buffer[3];
    stage = 5;
    for (;;) __asm__ volatile ("wfi" ::: "memory");
}
