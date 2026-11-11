/* A C library whose state is set up by a constructor, which firmware
   startup never runs. */
static unsigned ready;

__attribute__((constructor)) static void sensor_setup(void)
{
    ready = 1;
}

unsigned sensor_read(void)
{
    return ready;
}
