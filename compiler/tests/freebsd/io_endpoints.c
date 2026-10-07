/* Reuse the portable fault endpoints with ELF interposition names. Normal
 * paths still reach FreeBSD libc through RTLD_NEXT. This is fixture setup,
 * not a replacement hosted runtime. */
#define r550_open open
#define r550_write write
#define r550_close close
#include "../darwin/io_endpoints.c"
