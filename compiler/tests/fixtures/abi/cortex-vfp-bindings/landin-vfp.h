/* A float and double interface bound under AAPCS32's VFP variant, which
   passes these arguments and results in the float unit's registers. */
#ifndef LANDIN_VFP_H
#define LANDIN_VFP_H

/* Defined by the fixture's C peer and called directly. */
extern double vfp_peer_mix(double total, float sample, int count);

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

#endif
