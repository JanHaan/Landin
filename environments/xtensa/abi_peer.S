/* Reviewed windowed ABI carriers, independent of the C and Landin emitters.
 * A CALL8 peer sees a2..a7 and stack arguments at its incoming SP. ENTRY
 * reserves 32 bytes, so incoming stack offset zero is a1+32 below.
 */
.text
.macro FUNCTION name
.balign 4
.global \name
.type \name, @function
\name:
    entry a1, 32
    /* Every incoming SP and frame is sixteen-byte aligned. */
    extui a9, a1, 0, 4
    CHECK a9, 0
.endm
.macro CHECK reg, value
    movi a8, \value
    bne \reg, a8, .Lbad_\@
    j .Lok_\@
.Lbad_\@:
    movi a2, -1
    movi a3, -1
    retw
.Lok_\@:
.endm
.macro STACK offset, value
    l32i a9, a1, (32 + \offset)
    CHECK a9, \value
.endm

FUNCTION abi_integer_carriers
    CHECK a2, 11
    CHECK a4, 0x55667788
    CHECK a5, 0x11223344
    CHECK a6, 22
    STACK 0, 0x66778899
    STACK 4, 0x22334455
    STACK 8, 33
    movi a2, 0x9abcdef0
    movi a3, 0x12345678
    retw

FUNCTION abi_float_carriers
    CHECK a2, 11
    CHECK a3, 0x3fc00000 /* 1.5f */
    CHECK a4, 0
    CHECK a5, 0x40040000 /* 2.5 */
    CHECK a6, 0x40600000 /* 3.5f */
    movi a2, 0
    movi a3, 0x40120000 /* 4.5 */
    retw

FUNCTION abi_aggregate_carriers
    CHECK a2, 11
    CHECK a3, 22
    CHECK a4, 33
    CHECK a5, 44
    CHECK a6, 55
    movi a2, 0
    retw

FUNCTION abi_aggregate_stack
    CHECK a2, 11
    CHECK a3, 22
    CHECK a4, 33
    CHECK a5, 44
    CHECK a6, 55
    STACK 0, 66
    STACK 4, 77
    STACK 8, 88
    movi a2, 0
    retw

FUNCTION abi_return_three
    movi a2, 11
    movi a3, 22
    movi a4, 33
    retw

FUNCTION abi_return_four
    movi a2, 11
    movi a3, 22
    movi a4, 33
    movi a5, 44
    retw

FUNCTION abi_return_five
    /* The first carrier is the hidden result pointer, the next is arg. */
    movi a8, 11
    s32i a8, a2, 0
    movi a8, 22
    s32i a8, a2, 4
    movi a8, 33
    s32i a8, a2, 8
    movi a8, 44
    s32i a8, a2, 12
    s32i a3, a2, 16
    retw
