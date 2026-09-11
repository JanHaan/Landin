#include <stdint.h>
struct pair { double x; uint32_t y; };
extern uint32_t landin_number(uint32_t);
extern float landin_real(float);
extern struct pair landin_pair(struct pair);
uint32_t c_number(uint32_t value) { return landin_number(value) + 1; }
float c_real(float value) { return landin_real(value) + 1.0f; }
const int32_t *c_address(const int32_t *value) { return value; }
struct pair c_pair(struct pair value) {
    value = landin_pair(value);
    value.x += 1.0;
    value.y += 1;
    return value;
}
