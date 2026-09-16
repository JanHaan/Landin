/* Independent GCC layout and base-PCS control. No Landin emitter is used. */
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

struct A { uint8_t x; uint32_t y; uint8_t z; };
struct B { uint8_t x, y; uint32_t z; };
struct C { uint8_t x; uintptr_t y; };
struct Multiple { uint8_t x; uint64_t y; };
struct Evidence0 { uintptr_t size, alignment; };
struct D { uint64_t x; uint8_t y; };
struct Wide { uintptr_t x; uint8_t y; };
struct Variant { uint8_t tag; union { struct Wide wide; uint16_t row[3]; } payload; };
struct Wrapped { uint8_t x; struct Variant y; uint16_t z; };
struct Child { uint8_t x; uintptr_t y; uint16_t z[3]; };
struct Nested { uint16_t x; struct Child y; uint8_t z; };
struct Evidence { uintptr_t size, alignment; void (*first)(void); void (*second)(void); };
struct Any { void *data; const struct Evidence *table; };
struct Slice { uint8_t *base; uintptr_t length; };
struct FPair { float first, second; };
struct R4 { uint8_t bytes[4]; };
struct R3 { uint8_t bytes[3]; };
struct R5 { uint8_t bytes[5]; };
struct R12 { uint8_t bytes[12]; };

#define SCALAR(n, t) const unsigned layout_##n[] = {sizeof(t), _Alignof(t)}
#define OFF(t, f) offsetof(struct t, f)
#define LAYOUT2(n, t) const unsigned layout_##n[] = {sizeof(struct t), _Alignof(struct t), OFF(t,x), OFF(t,y)}
#define LAYOUT3(n, t) const unsigned layout_##n[] = {sizeof(struct t), _Alignof(struct t), OFF(t,x), OFF(t,y), OFF(t,z)}
SCALAR(u8, uint8_t); SCALAR(u16, uint16_t); SCALAR(u32, uint32_t); SCALAR(u64, uint64_t);
SCALAR(i8, int8_t); SCALAR(i16, int16_t); SCALAR(i32, int32_t); SCALAR(i64, int64_t);
SCALAR(usize, uintptr_t); SCALAR(isize, intptr_t); SCALAR(f32, float); SCALAR(f64, double);
SCALAR(bool, bool);
LAYOUT3(a, A); LAYOUT3(b, B); LAYOUT2(c, C); LAYOUT2(d, D);
const unsigned layout_variant[] = {sizeof(struct Variant), _Alignof(struct Variant), 0};
const unsigned layout_payload[] = {OFF(Variant, payload)};
LAYOUT3(wrapped, Wrapped); LAYOUT3(child, Child); LAYOUT3(nested, Nested);
LAYOUT2(multiple, Multiple);
SCALAR(evidence0, struct Evidence0);
const unsigned layout_evidence[] = {sizeof(struct Evidence), _Alignof(struct Evidence),
    OFF(Evidence,size), OFF(Evidence,alignment), OFF(Evidence,first), OFF(Evidence,second)};
const unsigned layout_any[] = {sizeof(struct Any), _Alignof(struct Any), OFF(Any,data), OFF(Any,table)};
_Static_assert(sizeof(void*) == 4 && sizeof(void (*)(void)) == 4, "address widths");
_Static_assert(sizeof(struct Slice) == 8 && OFF(Slice,length) == 4, "slice carrier");
_Static_assert(_Alignof(uint64_t) == 8 && _Alignof(double) == 8, "wide alignment");
_Static_assert(sizeof(long) == 4 && sizeof(int) == 4, "ILP32 C model");
_Static_assert((char)-1 > 0, "pinned Arm plain char is unsigned");

/* Each assembly endpoint records r0-r3, six stack words and incoming SP. */
volatile uint32_t capture[7][11];
volatile uint32_t result, fault_seen, asm_result, native_result;
volatile uintptr_t thumb_address;
extern void capture_gap(uint32_t, uint64_t, uint32_t);
extern void capture_split(uint32_t, uint32_t, uint32_t, struct R12, uint32_t);
extern void capture_stack(uint32_t, uint32_t, uint32_t, uint32_t, int8_t, double, uint16_t);
extern struct R5 capture_sret(uint32_t, uint64_t, uint32_t);
extern struct R3 capture_small(int8_t, uint16_t, float);
extern void capture_varargs(uint32_t, ...);
extern double capture_floatpair(uint32_t, struct FPair, uint32_t);
extern struct R4 assembly_return4(void);
extern uint32_t assembly_calls(void);
extern uint32_t internal_calls(void);
extern uint64_t assembly_return64(void);
extern double assembly_return_double(void);
extern int8_t assembly_return_i8(void);
extern void internal_entry(void);
extern void internal_parent(void);
extern void erased_entry(void);
uint32_t erased_data;
const struct Evidence erased_table = {4, 4, erased_entry, internal_parent};
const struct Any erased_value = {&erased_data, &erased_table};
const struct Evidence direct_table = {8, 4, internal_entry, internal_parent};
const struct Evidence parent_table = {8, 4, internal_parent, internal_entry};

/* GCC callees are in a separate translation boundary from the hand caller. */
__attribute__((noinline)) uint64_t c_wide(uint32_t a, uint64_t b, uint32_t c) {
    return b ^ ((uint64_t)c << 32) ^ a;
}
__attribute__((noinline)) struct R3 c_small(uint32_t x) {
    struct R3 r = {{(uint8_t)x, (uint8_t)(x >> 8), (uint8_t)(x >> 16)}};
    return r;
}
__attribute__((noinline)) struct R5 c_large(uint32_t x) {
    struct R5 r = {{(uint8_t)x, 2, 3, 4, 5}};
    return r;
}
void svc(void) {} void pendsv(void) {} void systick(void) {} void device_irq(void) {}

void probe(void) {
    const uint64_t wide = UINT64_C(0x8877665544332211);
    const struct R12 split = {{0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xaa,0xbb,0xcc}};
    capture_gap(0x11111111, wide, 0x22222222);
    capture_split(1, 2, 3, split, 4);
    capture_stack(1, 2, 3, 4, -7, 1.5, 0xabcd);
    struct R5 five = capture_sret(0x11111111, wide, 0x22222222);
    struct R3 three = capture_small(-7, 0xabcd, 1.5f);
    capture_varargs(1, (int8_t)-7, 1.5f, (uint32_t)9);
    if (five.bytes[0] != 1 || five.bytes[1] != 2 || five.bytes[2] != 3 ||
        five.bytes[3] != 4 || five.bytes[4] != 5 || three.bytes[0] != 0x11 ||
        three.bytes[1] != 0x22 || three.bytes[2] != 0x33) return;
    uint64_t (*volatile callback)(void) = assembly_return64;
    thumb_address = (uintptr_t)callback;
    if (!(thumb_address & 1) || callback() != wide) return;
    union { double d; uint64_t u; } floating;
    const struct FPair pair = {1.5f, 2.5f};
    floating.d = capture_floatpair(1, pair, 2);
    if (floating.u != UINT64_C(0x3ff8000000000000)) return;
    struct R4 four = assembly_return4();
    if (four.bytes[0] != 0x11 || four.bytes[3] != 0x44) return;
    floating.d = assembly_return_double();
    if (floating.u != UINT64_C(0x3ff8000000000000) || assembly_return_i8() != -7) return;
    asm_result = assembly_calls();
    native_result = internal_calls();
    if (asm_result != 0x620 || native_result != 0x620) return;
    result = 0x620;
}
