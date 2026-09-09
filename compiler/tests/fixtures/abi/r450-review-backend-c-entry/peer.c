#include <stdint.h>

int64_t r450_review_probe3932(int64_t x);
int64_t r450_review_probe3948(int64_t x);
int64_t r450_review_probe3964(int64_t x);
int64_t r450_review_probe3980(int64_t x);

struct outcome {
    int64_t integer;
    double fraction;
    int64_t next;
};

struct outcome r450_review_mixed(int64_t x, double y);

int32_t r450_review_c_entry(void)
{
    /* Deliberate Linux x86-64 execution peer, not a compiler host effect. */
    const int64_t x = INT64_C(123456789);
    struct outcome result = r450_review_mixed(x, 3.25);
    return !(r450_review_probe3932(x) == x
             && r450_review_probe3948(x) == x
             && r450_review_probe3964(x) == x
             && r450_review_probe3980(x) == x
             && result.integer == x && result.fraction == 3.25
             && result.next == x + 1);
}
