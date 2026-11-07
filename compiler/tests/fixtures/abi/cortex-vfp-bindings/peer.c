/* The C side of the VFP bindings: a direct call taking a double, a float
   and an int, which the VFP variant passes in d0, s2 and r0. */
#include "exports.h"

double vfp_peer_mix(double total, float sample, int count)
{
    return total + (double)sample * (double)count;
}
