/* The Landin program's exports, by the names its link annotations give. */
extern int landin_export_scaled(int value);
extern const int landin_export_limit;
extern int landin_export_written;

int peer_uses_exports(void)
{
    if (landin_export_scaled(5) != 15)
        return 1;
    if (landin_export_limit != 14)
        return 2;
    landin_export_written = 9;
    return 0;
}
