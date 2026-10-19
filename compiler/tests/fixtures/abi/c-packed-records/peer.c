/* The C side of D410 and D413: byte-packed records as GCC and Clang lay
   out __attribute__((packed)), and records ending in a flexible array
   member.  No packed member's address is taken. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct __attribute__((packed)) wire {
    uint8_t kind;
    uint16_t half;
    uint32_t word;
    uint64_t wide;
    int32_t number;
    float single;
    double twice;
    bool flag;
    size_t size;
    uint8_t bytes[3];
};

struct __attribute__((packed)) frame {
    uint8_t lead;
    struct wire body;
    uint16_t tail;
};

struct entry {
    uint64_t inode;
    int64_t offset;
    uint16_t length;
    uint8_t kind;
    char name[];
};

struct words {
    uint8_t kind;
    uint32_t data[];
};

size_t wire_size(void) { return sizeof(struct wire); }
size_t wire_alignment(void) { return _Alignof(struct wire); }
size_t frame_size(void) { return sizeof(struct frame); }
size_t entry_size(void) { return sizeof(struct entry); }
size_t entry_alignment(void) { return _Alignof(struct entry); }
size_t words_size(void) { return sizeof(struct words); }

size_t wire_offset(int32_t which)
{
    switch (which) {
    case 0: return offsetof(struct wire, half);
    case 1: return offsetof(struct wire, word);
    case 2: return offsetof(struct wire, wide);
    case 3: return offsetof(struct wire, number);
    case 4: return offsetof(struct wire, single);
    case 5: return offsetof(struct wire, twice);
    case 6: return offsetof(struct wire, flag);
    case 7: return offsetof(struct wire, size);
    case 8: return offsetof(struct wire, bytes);
    case 9: return offsetof(struct frame, body);
    case 10: return offsetof(struct frame, tail);
    case 11: return offsetof(struct entry, name);
    case 12: return offsetof(struct words, data);
    default: return SIZE_MAX;
    }
}

/* Fill a record wherever the caller put it, an odd address included. */
void wire_fill(struct wire *record)
{
    record->kind = 7;
    record->half = 0x1234;
    record->word = 0x89abcdefu;
    record->wide = 0x0102030405060708u;
    record->number = -123456;
    record->single = 1.5f;
    record->twice = -2.25;
    record->flag = true;
    record->size = 0x77665544u;
    record->bytes[0] = 1;
    record->bytes[1] = 2;
    record->bytes[2] = 3;
}

/* Whether a record holds what the Landin side wrote. */
int32_t wire_check(const struct wire *record)
{
    return record->kind == 9 && record->half == 0x4321
        && record->word == 0x0a0b0c0du && record->wide == 0x1112131415161718u
        && record->number == -7 && record->single == 0.25f
        && record->twice == 1024.5 && !record->flag
        && record->size == 0x10203u && record->bytes[1] == 5 ? 42 : 1;
}

int32_t frame_check(const struct frame *record)
{
    return record->lead == 3 && record->body.word == 0xfeedfaceu
        && record->tail == 0xbeef ? 42 : 1;
}

/* An entry and its name, as getdents64 would leave one. */
void entry_fill(struct entry *record)
{
    record->inode = 99;
    record->offset = -1;
    record->length = (uint16_t)(offsetof(struct entry, name) + 6);
    record->kind = 4;
    record->name[0] = 'h';
    record->name[1] = 'e';
    record->name[2] = 'l';
    record->name[3] = 'l';
    record->name[4] = 'o';
    record->name[5] = 0;
}
