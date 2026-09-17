/* Independent GCC-owned code, not Landin's C source surface or runtime. */
volatile unsigned control_initial = 18;
volatile unsigned control_calls;
void control_increment(void) {
    control_initial += 7;
    control_calls++;
}
