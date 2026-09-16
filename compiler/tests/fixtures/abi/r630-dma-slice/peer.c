/* Serialized device model. Writes precede count; no physical DMA/cache claim. */
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
static uint8_t *buffer;
static uint32_t count;
void arm(uint8_t *p, size_t size) { assert(size == 4); buffer = p; count = 0; }
void feed(void) { for (unsigned i=0; i<4; ++i) buffer[i] = (uint8_t)(10+i); count = 4; }
uint32_t completed(void) { return count; }
extern uint32_t scenario(void);
int main(void) { assert(scenario() == 56); return 42; }
