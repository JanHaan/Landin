/* Independent vendor-C side of the windowed ABI contract. No libc. */
typedef unsigned char u8;
typedef unsigned int u32;
typedef unsigned long long u64;
typedef unsigned int unsigned_vector128 __attribute__((vector_size(16)));
#define ASSERT(test) _Static_assert(test, #test)
ASSERT(__XTENSA_WINDOWED_ABI__ == 1);
ASSERT(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__);
ASSERT(sizeof(void *) == 4 && _Alignof(void *) == 4);
ASSERT(sizeof(short) == 2 && sizeof(int) == 4 && sizeof(long) == 4);
ASSERT(_Alignof(short) == 2 && _Alignof(int) == 4 && _Alignof(long) == 4);
ASSERT(sizeof(_Bool) == 1 && _Alignof(_Bool) == 1);
ASSERT(sizeof(char) == 1 && _Alignof(char) == 1);
ASSERT(sizeof(u64) == 8 && _Alignof(u64) == 8);
ASSERT((char)-1 > 0);
ASSERT(sizeof(float) == 4 && _Alignof(float) == 4);
ASSERT(sizeof(double) == 8 && _Alignof(double) == 8);
ASSERT(sizeof(long double) == 8 && _Alignof(long double) == 8);
ASSERT(sizeof(unsigned_vector128) == 16 && _Alignof(unsigned_vector128) == 16);
struct padded { u8 byte; u64 wide; u32 word; };
ASSERT(__builtin_offsetof(struct padded, wide) == 8);
ASSERT(__builtin_offsetof(struct padded, word) == 16);
ASSERT(sizeof(struct padded) == 24 && _Alignof(struct padded) == 8);
struct two { u32 a, b; };
struct three { u32 a, b, c; };
struct four { u32 a, b, c, d; };
struct five { u32 a, b, c, d, e; };

/* Actual compiler-emitted Landin routines, using only matching scalars. */
extern u64 landin_abi_mix(u32, u64, u32, u64, u32);
extern double landin_abi_float(double, float);
extern float landin_abi_single(float, float);

/* Handwritten native peers independently check GCC's actual carriers. */
extern u64 abi_integer_carriers(u32, u64, u32, u64, u32);
extern double abi_float_carriers(u32, float, double, float);
extern u32 abi_aggregate_carriers(u32, struct three, u32);
extern u32 abi_aggregate_stack(u32, u32, u32, u32, u32, struct two, u32);
extern struct three abi_return_three(void);
extern struct four abi_return_four(void);
extern struct five abi_return_five(u32);

#ifndef ABI_FAILURE
#define ABI_FAILURE 0
#endif
int xtensa_abi_run(void)
{
    struct three three = { 22, 33, 44 };
    struct two two = { 66, 77 };
    if (landin_abi_mix(1, 0x100000001ULL, 3, 0x200000002ULL, 5)
            != 0x30000000cULL) return 1;
    if (landin_abi_float(2.5, 4.0f) != 11.5) return 2;
    if (landin_abi_single(7.0f, 2.0f) != 3.5f) return 3;
    if (abi_integer_carriers(11, 0x1122334455667788ULL, 22,
            0x2233445566778899ULL, 33) != 0x123456789abcdef0ULL) return 4;
    if (abi_float_carriers(11, 1.5f, 2.5, 3.5f) != 4.5) return 5;
    if (abi_aggregate_carriers(11, three, 55) != 0) return 6;
    if (abi_aggregate_stack(11, 22, 33, 44, 55, two, 88) != 0) return 7;
    three = abi_return_three();
    if (three.a != 11 || three.b != 22 || three.c != 33) return 8;
    struct four four = abi_return_four();
    if (four.a != 11 || four.b != 22 || four.c != 33 || four.d != 44) return 9;
    struct five five = abi_return_five(55);
    if (five.a != 11 || five.b != 22 || five.c != 33 || five.d != 44
            || five.e != 55) return 10;
    return ABI_FAILURE;
}
