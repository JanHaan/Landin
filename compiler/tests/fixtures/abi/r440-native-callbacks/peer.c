#include <stdint.h>
#include <stdio.h>
#include <stddef.h>

typedef int32_t (*handler)(int32_t);
typedef struct { handler callback; int32_t bias; } box;
_Static_assert(sizeof(box) == 16, "callback box size");
_Static_assert(offsetof(box, bias) == 8, "callback box offset");
static int32_t c_step(int32_t value) { return value + 1; }
handler c_make(void) { return c_step; }
box c_box(void) { return (box){c_step, 4}; }
int32_t c_apply(box candidate, int32_t value) {
    return candidate.callback(value) + candidate.bias;
}
int32_t c_bounce(handler callback, int32_t value) {
    return callback(value) + 1;
}
int32_t *c_optional(int32_t want, int32_t *value) {
    return want ? value : NULL;
}
extern handler l_make(void);
extern box l_box(void);
extern int32_t l_apply(box, int32_t);
extern int32_t l_recur(int32_t);
extern int32_t *l_optional(int32_t, int32_t *);
extern int32_t r440_public_first(int32_t);
extern int32_t r440_public_second(int32_t);
extern int32_t landin_check(void);
int main(void) {
    if (landin_check() != 42) return 1;
    handler callback = l_make();
    box candidate = l_box();
    if (callback(10) != 12 || candidate.callback(10) != 12) return 2;
    if (candidate.bias != 3 || l_apply(c_box(), 10) != 15) return 3;
    if (l_recur(16) != 42) return 4;
    if (r440_public_first(39) != 42 || r440_public_second(39) != 42) return 5;
    int32_t cell = 40;
    if (l_optional(0, &cell) != NULL || l_optional(1, &cell) != &cell) return 6;
    puts("native callbacks ok");
    return 42;
}
