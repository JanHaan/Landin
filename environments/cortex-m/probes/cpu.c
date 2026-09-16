typedef unsigned int u32;
#define REG(a) (*(volatile u32 *)(a))
volatile u32 svc_seen, pend_seen, tick_seen, irq_seen, fault_seen, result;
void svc(void) { svc_seen++; }
void pendsv(void) { pend_seen++; }
void systick(void) { REG(0xe000e010) = 0; tick_seen++; }
void device_irq(void) { irq_seen++; }
void probe(void) {
    __asm__ volatile ("svc #0" ::: "memory");
    __asm__ volatile ("cpsid i" ::: "memory");
    REG(0xe000e100) = 1;
    REG(0xe000e200) = 1;
    if (irq_seen != 0) { result = 1; return; }
    __asm__ volatile ("cpsie i\n nop\n nop" ::: "memory");
    REG(0xe000ed04) = 1u << 28;
    __asm__ volatile ("dsb\n isb" ::: "memory");
    REG(0xe000e014) = 100000;
    REG(0xe000e018) = 0;
    REG(0xe000e010) = 7;
    while (!tick_seen) __asm__ volatile ("wfi" ::: "memory");
    /* Nordic GPIO, not the prototype GPIO. */
    REG(0x50000518) = 1u << 3;
    REG(0x50000508) = 1u << 3;
    if ((REG(0x50000504) & (1u << 3)) == 0) { result = 2; return; }
    REG(0x5000050c) = 1u << 3;
    if ((REG(0x50000504) & (1u << 3)) != 0) { result = 3; return; }
    /* Nordic UART TX task and data register. */
    REG(0x40002500) = 4;
    REG(0x40002008) = 1;
    const char *p = "R610 UART\n";
    while (*p) REG(0x4000251c) = (u32)*p++;
    result = (svc_seen == 1 && pend_seen == 1 && tick_seen == 1 && irq_seen == 1)
        ? 0x610 : 4;
}
