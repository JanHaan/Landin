typedef unsigned int u32;
#define REG(a) (*(volatile u32 *)(a))
#define CFG REG(0x40026058)
#define COUNT (*(volatile unsigned short *)0x4002605c)
volatile u32 fault_seen, result, irq_seen, events, stage;
unsigned char buffer[4]; /* ordinary memory, reloaded across an opaque barrier */
void svc(void) { }
void pendsv(void) { }
void systick(void) { }
void device_irq(void) {
    u32 pending = REG(0x40026000);
    REG(0x40026004) = pending;
    events |= pending;
    irq_seen++;
}
void probe(void) {
    REG(0x40020000) = 0xa5a50000;
    u32 mode = REG(0x40020000);
    REG(0x40020000) = (mode & ~(3u << 4)) | (2u << 4);
    REG(0x40020020) = 7u << 8;
    REG(0x40020018) = 8;
    if (REG(0x40020014) != 8 || REG(0x40020000) != 0xa5a50020) { result=1; return; }
    REG(0x40020018) = 8u << 16;
    if (REG(0x40020014) != 0) { result=2; return; }
    REG(0x40021000) = 139; /* explicit synthetic baud divisor register */
    REG(0x40026060) = 0x40021004;
    REG(0x40026064) = (u32)buffer;
    COUNT = 4;
    CFG = 0x8000050e; /* reserved high bit, circular, increment, IRQs, disabled */
    REG(0xe000e100) = 1;
    stage = 1;
    while (stage == 1) __asm__ volatile ("nop" ::: "memory");
    if (COUNT != 4 || buffer[0] != 0) { result=3; return; }
    CFG = CFG | 1;
    stage = 3;
    while (stage == 3) __asm__ volatile ("nop" ::: "memory");
    if (COUNT != 2 || buffer[0] != 'A' || buffer[1] != 'B' || events != 0x40) { result=4; return; }
    __asm__ volatile ("cpsid i" ::: "memory");
    stage = 5;
    while (stage == 5) __asm__ volatile ("nop" ::: "memory");
    if (COUNT != 4 || buffer[2] != 'C' || buffer[3] != 'D' || irq_seen != 1) { result=5; return; }
    __asm__ volatile ("cpsie i\n dsb\n isb" ::: "memory");
    stage = 7;
    while (stage == 7) __asm__ volatile ("nop" ::: "memory");
    if (COUNT != 3 || buffer[0] != 'E' || events != 0x60 || irq_seen != 2) { result=6; return; }
    stage = 9;
    while (stage == 9) __asm__ volatile ("nop" ::: "memory");
    if (events != 0xe0 || irq_seen != 3 || (CFG & 1) != 0 || REG(0x40026000) != 0) { result=7; return; }
    if ((CFG & 0x80000000) == 0) { result=8; return; }
    result = 0x610;
}
