/* D523/D524: an archive the program finds through linker.directory("lib"),
   beside its source.  Its names are C's own, in mixed case, and it calls
   libm itself, so libm must follow it on the link line. */
#include <math.h>

typedef struct {
    float x;
    float y;
} Vec2;

int AddInts(int a, int b)
{
    return a + b;
}

float Vec2Length(Vec2 v)
{
    return sqrtf(v.x * v.x + v.y * v.y);
}
