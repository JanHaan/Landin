/* Memory-model independent C/assembly control: cacheless ARMv6-M, no Landin code. */
typedef unsigned int u32;
#define REG(a) (*(volatile u32 *)(a))
volatile u32 result, fault_seen;
static u32 shared, observed, irq_seen;
static unsigned char byte;
static unsigned short half;
static u32 word;
void svc(void) {}
void pendsv(void) {}
void systick(void) {}
void device_irq(void) {
    observed = shared;
    shared = 42;
    irq_seen++;
}
static u32 mask(void) {
    u32 prior;
    __asm__ volatile("mrs %0, primask\n cpsid i" : "=r"(prior) :: "memory");
    return prior;
}
static void restore(u32 prior) {
    __asm__ volatile("msr primask, %0\n dsb\n isb" :: "r"(prior) : "memory");
}
void probe(void) {
    u32 outer = mask(), inner = mask();
    if (outer != 0 || inner != 1) { result = 1; return; }
    shared = 17;
    REG(0xe000e100) = 1;
    REG(0xe000e200) = 1;
    restore(inner);
    if (irq_seen) { result = 2; return; }
    restore(outer);
    __asm__ volatile("dmb\n dsb\n isb" ::: "memory");
    if (observed != 17 || shared != 42 || irq_seen != 1) { result = 3; return; }
    __atomic_store_n(&byte, 0xa5, __ATOMIC_RELEASE);
    __atomic_store_n(&half, 0x5aa5, __ATOMIC_SEQ_CST);
    __atomic_store_n(&word, 0x12345678, __ATOMIC_RELAXED);
    if (__atomic_load_n(&byte, __ATOMIC_ACQUIRE) != 0xa5 ||
        __atomic_load_n(&half, __ATOMIC_SEQ_CST) != 0x5aa5 ||
        __atomic_load_n(&word, __ATOMIC_RELAXED) != 0x12345678) {
        result = 4; return;
    }
    result = 0x630;
}
