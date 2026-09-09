#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern size_t l_length(const uint8_t *);
extern size_t l_copy(int32_t, int32_t, uint8_t *, size_t);
extern bool l_heap(void);
int main(void) {
    if (l_length((const uint8_t *)"hello") != 5 || !l_heap()) return 1;
    int input[2], output[2];
    if (pipe(input) || pipe(output)) return 2;
    uint8_t buffer[5] = {0}, received[5] = {0};
    if (write(input[1], "hello", 5) != 5) return 3;
    if (l_copy(input[0], output[1], buffer, 5) != 5) return 4;
    if (read(output[0], received, 5) != 5 || memcmp(received, "hello", 5)) return 5;
    if (close(input[0]) || close(input[1]) || close(output[0]) || close(output[1])) return 6;
    puts("native hosted ok");
    return 42;
}
