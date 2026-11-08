/* A float and double interface bound under AAPCS32's VFP variant, which
   passes these arguments and results in the float unit's registers. */
#ifndef LANDIN_VFP_H
#define LANDIN_VFP_H

/* A mixed record, bound native: its generated static assertions hold
   GCC's and Clang's layout to Landin's layout(c).  A double after a float
   and a short array after a byte pad it in two places, and the 64-bit
   integer aligns it to eight. */
typedef struct vfp_sample {
    float gain;
    double offset;
    unsigned char channel;
    short trim[3];
    long long stamp;
} vfp_sample;

/* A homogeneous aggregate of two doubles, which the VFP variant passes and
   returns in d0 and d1 rather than in core registers or memory. */
typedef struct vfp_pair {
    double re;
    double im;
} vfp_pair;

/* Defined by the fixture's C peer and called directly. */
extern double vfp_peer_mix(double total, float sample, int count);

/* Defined by the C peer: every argument checked exactly, a distinct code
   for each, 0 when all hold.  a and c share d0 (s0, then s1 back-filled),
   b and d through i fill d1-d7, so j, the seventeenth single slot, is on
   the stack, and count, the only integer, is in r0. */
extern int vfp_peer_check(float a, double b, float c, double d, double e,
                          double f, double g, double h, double i, float j,
                          int count);

/* Defined by the C peer: it calls the program's exported float routines
   and checks each result, a distinct code for each, 0 when all hold. */
extern int vfp_peer_calls_back(void);

/* Internal inline definitions, reached through generated adapters. */
static inline float vfp_half(float value)
{
    return value * 0.5f;
}

/* first in s0, second in d1, and third back-filled into s1. */
static inline double vfp_backfill(float first, double second, float third)
{
    return (double)first + second * 2.0 + (double)third * 4.0;
}

/* The record by address: each field read where Landin wrote it. */
static inline double vfp_apply(const vfp_sample *sample, double value)
{
    return value * (double)sample->gain + sample->offset
        + (double)sample->channel
        + (double)(sample->trim[0] + sample->trim[1] + sample->trim[2])
        + (double)sample->stamp;
}

/* The record's address back: its middle trim moved by `by`, read through
   the returned pointer. */
static inline vfp_sample *vfp_retrim(vfp_sample *sample, short by)
{
    sample->trim[1] = (short)(sample->trim[1] + by);
    return sample;
}

/* The aggregate by value, in d0-d1 both ways, with a float in s4 after it. */
static inline vfp_pair vfp_turn(vfp_pair z, float scale)
{
    vfp_pair turned = { -z.im * (double)scale, z.re * (double)scale };
    return turned;
}

#endif
