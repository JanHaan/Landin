/* Independent unsigned-image controls, not Landin-generated firmware. */
#include <stdint.h>

volatile uint32_t result;
volatile uint32_t stage;
static uint32_t failures;

#define IMAGE(offset) (*(volatile uint32_t *)(0x40030000u + (offset)))
#define COUNT (*(volatile uint16_t *)0x40030010u)

volatile uint32_t fault_seen;

void device_irq(void) {}
void svc(void) {}
void pendsv(void) {}
void systick(void) {}

static void require(int ok) { if(!ok) failures++; }
static uint32_t extract(uint32_t raw, unsigned first, unsigned bits)
{
    return (raw >> first) & ((1u << bits) - 1u);
}
static uint32_t insert(uint32_t raw, uint32_t value,
                       unsigned first, unsigned bits)
{
    uint32_t mask = ((1u << bits) - 1u) << first;
    return (raw & ~mask) | (value << first);
}
static int named(uint32_t raw) { return raw == 0 || raw == 1 || raw == 4; }

void probe(void)
{
    /* Exhaust all three-bit patterns. Membership is independently specified
       by a table; unnamed patterns remain ordinary unsigned data. */
    static const uint8_t valid[8] = {1, 1, 0, 0, 1, 0, 0, 0};
    for(unsigned raw = 0; raw != 256; raw++) {
        for(unsigned i = 0; i != 4; i++) {
            unsigned value = extract(raw, 2 * i, 2);
            require(insert(raw, value, 2 * i, 2) == raw);
            require(insert(raw, 0, 2 * i, 2) == (raw & ~(3u << (2 * i))));
        }
        require(named(extract(raw, 0, 3)) == valid[raw % 8]);
    }

    uint32_t raw = IMAGE(0);
    require(raw == 0xa50000f0);
    raw = insert(raw, 1, 4, 2); /* indexed pin two, preserve all other bits */
    require(raw == 0xa50000d0);
    IMAGE(0) = raw;
    raw = IMAGE(0);
    require(extract(raw, 4, 3) == 5 && !named(extract(raw, 4, 3)));

    raw = IMAGE(4); /* destructive: one read, local reuse causes no reread */
    require(raw == 0x9b && extract(raw, 0, 3) == 3 && !named(raw & 7));
    require(IMAGE(4) == 0);
    IMAGE(8) = 0x51; /* write-only: no preparatory read */
    IMAGE(12) = 2; /* one-clears command, not an old-image RMW */
    require(IMAGE(12) == 0xf1);
    IMAGE(12) = 0;
    require(IMAGE(12) == 0xf1);
    require(COUNT == 0xffff);
    COUNT = 0;
    require(COUNT == 0);
    COUNT = 0xffff;
    IMAGE(20) = 0xffffff51;
    require(IMAGE(20) == 0xffffff51);
    result = failures == 0 ? 0x640 : 0xbad;
    stage = 1;
    for(;;) {}
}
