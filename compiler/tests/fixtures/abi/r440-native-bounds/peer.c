#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
typedef struct { uint8_t values[3]; } bytes3;
bytes3 c_bytes3(bytes3 value) {
    for (size_t i = 0; i < 3; ++i) value.values[i] += 1;
    return value;
}
extern void l_bytes3(const bytes3 *, bytes3 *);
typedef struct { uint8_t values[5]; } bytes5;
bytes5 c_bytes5(bytes5 value) {
    for (size_t i = 0; i < 5; ++i) value.values[i] += 1;
    return value;
}
extern void l_bytes5(const bytes5 *, bytes5 *);
typedef struct { uint8_t values[7]; } bytes7;
bytes7 c_bytes7(bytes7 value) {
    for (size_t i = 0; i < 7; ++i) value.values[i] += 1;
    return value;
}
extern void l_bytes7(const bytes7 *, bytes7 *);
typedef struct { uint8_t values[12]; } bytes12;
bytes12 c_bytes12(bytes12 value) {
    for (size_t i = 0; i < 12; ++i) value.values[i] += 1;
    return value;
}
extern void l_bytes12(const bytes12 *, bytes12 *);
typedef struct { uint8_t values[24]; } bytes24;
bytes24 c_bytes24(bytes24 value) {
    for (size_t i = 0; i < 24; ++i) value.values[i] += 1;
    return value;
}
extern void l_bytes24(const bytes24 *, bytes24 *);
int main(void) {
    long page_value = sysconf(_SC_PAGESIZE);
    if (page_value <= 0) return 1;
    size_t page = (size_t)page_value;
    unsigned char *source = mmap(NULL, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    unsigned char *target = mmap(NULL, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (source == MAP_FAILED || target == MAP_FAILED) return 2;
    if (mprotect(source + page, page, PROT_NONE) || mprotect(target + page, page, PROT_NONE)) return 3;
    {
        bytes3 *input = (bytes3 *)(source + page - sizeof(bytes3));
        bytes3 *output = (bytes3 *)(target + page - sizeof(bytes3));
        for (size_t i = 0; i < 3; ++i) input->values[i] = (uint8_t)(10 + i);
        memset(target, 0xA5, page);
        l_bytes3(input, output);
        for (size_t i = 0; i < 3; ++i) {
            if (output->values[i] != (uint8_t)(11 + i) || input->values[i] != (uint8_t)(10 + i)) return 3;
        }
        if (target[page - sizeof(bytes3) - 1] != 0xA5) return 40;
        struct { uint8_t before; bytes3 value; uint8_t after[8]; } guarded;
        memset(&guarded, 0xA5, sizeof guarded);
        l_bytes3(input, &guarded.value);
        if (guarded.before != 0xA5) return 41;
        for (size_t i = 0; i < sizeof guarded.after; ++i)
            if (guarded.after[i] != 0xA5) return 43;
    }
    {
        bytes5 *input = (bytes5 *)(source + page - sizeof(bytes5));
        bytes5 *output = (bytes5 *)(target + page - sizeof(bytes5));
        for (size_t i = 0; i < 5; ++i) input->values[i] = (uint8_t)(10 + i);
        memset(target, 0xA5, page);
        l_bytes5(input, output);
        for (size_t i = 0; i < 5; ++i) {
            if (output->values[i] != (uint8_t)(11 + i) || input->values[i] != (uint8_t)(10 + i)) return 5;
        }
        if (target[page - sizeof(bytes5) - 1] != 0xA5) return 40;
        struct { uint8_t before; bytes5 value; uint8_t after[8]; } guarded;
        memset(&guarded, 0xA5, sizeof guarded);
        l_bytes5(input, &guarded.value);
        if (guarded.before != 0xA5) return 41;
        for (size_t i = 0; i < sizeof guarded.after; ++i)
            if (guarded.after[i] != 0xA5) return 43;
    }
    {
        bytes7 *input = (bytes7 *)(source + page - sizeof(bytes7));
        bytes7 *output = (bytes7 *)(target + page - sizeof(bytes7));
        for (size_t i = 0; i < 7; ++i) input->values[i] = (uint8_t)(10 + i);
        memset(target, 0xA5, page);
        l_bytes7(input, output);
        for (size_t i = 0; i < 7; ++i) {
            if (output->values[i] != (uint8_t)(11 + i) || input->values[i] != (uint8_t)(10 + i)) return 7;
        }
        if (target[page - sizeof(bytes7) - 1] != 0xA5) return 40;
        struct { uint8_t before; bytes7 value; uint8_t after[8]; } guarded;
        memset(&guarded, 0xA5, sizeof guarded);
        l_bytes7(input, &guarded.value);
        if (guarded.before != 0xA5) return 41;
        for (size_t i = 0; i < sizeof guarded.after; ++i)
            if (guarded.after[i] != 0xA5) return 43;
    }
    {
        bytes12 *input = (bytes12 *)(source + page - sizeof(bytes12));
        bytes12 *output = (bytes12 *)(target + page - sizeof(bytes12));
        for (size_t i = 0; i < 12; ++i) input->values[i] = (uint8_t)(10 + i);
        memset(target, 0xA5, page);
        l_bytes12(input, output);
        for (size_t i = 0; i < 12; ++i) {
            if (output->values[i] != (uint8_t)(11 + i) || input->values[i] != (uint8_t)(10 + i)) return 12;
        }
        if (target[page - sizeof(bytes12) - 1] != 0xA5) return 40;
        struct { uint8_t before; bytes12 value; uint8_t after[8]; } guarded;
        memset(&guarded, 0xA5, sizeof guarded);
        l_bytes12(input, &guarded.value);
        if (guarded.before != 0xA5) return 41;
        for (size_t i = 0; i < sizeof guarded.after; ++i)
            if (guarded.after[i] != 0xA5) return 43;
    }
    {
        bytes24 *input = (bytes24 *)(source + page - sizeof(bytes24));
        bytes24 *output = (bytes24 *)(target + page - sizeof(bytes24));
        for (size_t i = 0; i < 24; ++i) input->values[i] = (uint8_t)(10 + i);
        memset(target, 0xA5, page);
        l_bytes24(input, output);
        for (size_t i = 0; i < 24; ++i) {
            if (output->values[i] != (uint8_t)(11 + i) || input->values[i] != (uint8_t)(10 + i)) return 24;
        }
        if (target[page - sizeof(bytes24) - 1] != 0xA5) return 40;
        struct { uint8_t before; bytes24 value; uint8_t after[8]; } guarded;
        memset(&guarded, 0xA5, sizeof guarded);
        l_bytes24(input, &guarded.value);
        if (guarded.before != 0xA5) return 41;
        for (size_t i = 0; i < sizeof guarded.after; ++i)
            if (guarded.after[i] != 0xA5) return 43;
    }
    if (munmap(source, page * 2) || munmap(target, page * 2)) return 44;
    puts("native bounds ok");
    return 42;
}
