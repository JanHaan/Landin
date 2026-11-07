/* The C side of the VFP bindings.  vfp_peer_mix is a direct call taking a
   double, a float and an int, which the VFP variant passes in d0, s2 and
   r0.  vfp_peer_check receives eleven arguments from the program and
   checks each exactly; vfp_peer_calls_back calls the program's exported
   routines with floats and doubles and checks what each returns.  Each
   check has a code of its own, so a status names the value that arrived
   wrong; 0 is every value as sent. */
#include "exports.h"

/* The program's exports (program.ldn). */
extern float landin_vfp_scale(float value, double by, float offset);
extern double landin_vfp_sum(double a, float b, double c, float d, int count);
extern double landin_vfp_spread(vfp_pair z, float by);

double vfp_peer_mix(double total, float sample, int count)
{
    return total + (double)sample * (double)count;
}

int vfp_peer_check(float a, double b, float c, double d, double e,
                   double f, double g, double h, double i, float j,
                   int count)
{
    if (a != 0.25f) return 1;
    if (b != -1.5) return 2;
    if (c != 3.0f) return 3;
    if (d != 1e300) return 4;
    if (e != -0.0 || !__builtin_signbit(e)) return 5;
    if (f != 6.5) return 6;
    if (g != 7.75) return 7;
    if (h != 8.125) return 8;
    if (i != 1.0 / 1024.0) return 9;
    if (j != -16777216.0f) return 10;
    if (count != 11) return 11;
    return 0;
}

int vfp_peer_calls_back(void)
{
    /* 2 * 1.5 + 0.5, the float in s0, the double in d1, the second float
       back-filled into s1. */
    if (landin_vfp_scale(2.0f, 1.5, 0.5f) != 3.5f) return 21;
    if (landin_vfp_scale(-0.0f, 4.0, 0.0f) != 0.0f) return 22;
    /* 1.25 + 2.5 + 3.75 + 0.5, then the integer in r0. */
    if (landin_vfp_sum(1.25, 2.5f, 3.75, 0.5f, 4) != 8.0 * 4) return 23;
    /* (1.5 - -2.25) * 2, the aggregate in d0-d1 and the float in s4. */
    vfp_pair z = { 1.5, -2.25 };
    if (landin_vfp_spread(z, 2.0f) != 7.5) return 24;
    return 0;
}
