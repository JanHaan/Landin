/* D524: an archive the program finds only through the -L its build names. */
typedef struct {
    float x;
    float y;
} Vec2;

Vec2 PointScale(Vec2 v, float by)
{
    Vec2 scaled = { v.x * by, v.y * by };
    return scaled;
}
