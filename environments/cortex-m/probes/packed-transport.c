/* Transport only: no field masks, encodings, or expected device images. */
#include <assert.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/resource.h>
static uint32_t reply(void) {
    uint32_t value;
    assert(scanf("%" SCNu32, &value) == 1);
    return value;
}
uint32_t read32(uint32_t offset) {
    printf("R32 %" PRIu32 "\n", offset); fflush(stdout); return reply();
}
uint16_t read16(uint32_t offset) {
    printf("R16 %" PRIu32 "\n", offset); fflush(stdout);
    uint32_t value = reply(); assert(value <= UINT16_MAX); return (uint16_t)value;
}
void write32(uint32_t offset, uint32_t value) {
    printf("W32 %" PRIu32 " %" PRIu32 "\n", offset, value); fflush(stdout);
    assert(reply() == 1);
}
void write16(uint32_t offset, uint16_t value) {
    printf("W16 %" PRIu32 " %" PRIu16 "\n", offset, value); fflush(stdout);
    assert(reply() == 1);
}
extern uint32_t scenario(void);
int main(void) {
    const struct rlimit no_core = {0, 0};
    assert(setrlimit(RLIMIT_CORE, &no_core) == 0);
    uint32_t result = scenario();
    printf("DONE %" PRIu32 "\n", result); fflush(stdout);
    return result == 0x640 ? 0 : 1;
}
