/* Independent GCC control of AAPCS32's VFP variant (D616), compiled
 * -mcpu=cortex-m7 -mfloat-abi=hard -mfpu=fpv5-d16 and run on QEMU's
 * mps2-an500.  No Landin emitter or plan is used: the hand-written
 * endpoints in abi-vfp.S record where GCC put each argument, and abi.py
 * compares that with the planner's rows in compiler/tests/cortex-m.contract. */
#include <stdint.h>

struct F3 { float x[3]; };
struct D2 { double x[2]; };
struct D4 { double x[4]; };
struct F5 { float x[5]; };

/* Each endpoint records r0-r3, s0-s15, six stack words and its incoming SP. */
volatile uint32_t vfp_capture[5][27];
volatile uint32_t vfp_result, vfp_preserved;

extern float capture_mixed(float, double, float, uint32_t, double);
extern struct D4 capture_hfa(struct F3, struct D2, float);
extern double capture_spill(float, double, double, double, double, double, double,
                            double, struct D2, float, uint32_t);
extern double capture_varargs(double, ...);
extern struct F5 capture_large(struct F5, float);
extern uint32_t preserved_probe(void);

/* GCC saves exactly the registers the convention makes it preserve: this
 * body clobbers every VFP register, and its prologue may push only d8-d15. */
__attribute__((noinline)) void vfp_clobber(void) {
    __asm__ volatile("vmov.f64 d0, #1.0\n\tvmov.f64 d15, #1.0" ::: "s0", "s1", "s2", "s3",
                     "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "s12", "s13", "s14",
                     "s15", "s16", "s17", "s18", "s19", "s20", "s21", "s22", "s23", "s24",
                     "s25", "s26", "s27", "s28", "s29", "s30", "s31");
}

static int bits32(float value, uint32_t want) {
    union { float f; uint32_t u; } v = {value};
    return v.u == want;
}

static int bits64(double value, uint64_t want) {
    union { double d; uint64_t u; } v = {value};
    return v.u == want;
}

void probe(void) {
    const struct F3 three = {{1.25f, 2.25f, 3.25f}};
    const struct D2 two = {{6.5, 7.5}};
    const struct F5 five = {{9.0f, 10.0f, 11.0f, 12.0f, 13.0f}};
    if (!bits32(capture_mixed(1.5f, 2.5, 3.5f, 0x11223344u, 4.5), 0x3fc00000u)) return;
    struct D4 four = capture_hfa(three, two, 5.5f);
    if (!bits64(four.x[0], UINT64_C(0x3ff8000000000000))
        || !bits64(four.x[3], UINT64_C(0x4012000000000000))) return;
    if (!bits64(capture_spill(1.0f, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, two, 14.0f,
                              0x55667788u), UINT64_C(0x3ff8000000000000))) return;
    if (!bits64(capture_varargs(2.5, 3.5, 0x99aabbccu), UINT64_C(0x3ff8000000000000)))
        return;
    struct F5 large = capture_large(five, 15.0f);
    if (!bits32(large.x[0], 0x3fc00000u) || !bits32(large.x[4], 0x40900000u)) return;
    vfp_preserved = preserved_probe();
    vfp_result = 0x616;
}
