#include <stdint.h>

struct large {
    uint8_t bytes[8199];
    uint64_t marker;
};

int64_t r450_step(int64_t x)
{
    /* Force every volatile GP bank to be unavailable across this call. */
#if defined(__APPLE__)
    __asm__ volatile ("" : : :
        "x0", "x1", "x2", "x3", "x4", "x5",
        "x6", "x7", "x8", "x9", "x10", "x11",
        "x12", "x13", "x14", "x15", "x16", "x17",
        "v0", "v1", "v2", "v3", "v4", "v5",
        "v6", "v7", "v16", "v17", "v18", "v19",
        "v20", "v21", "v22", "v23", "v24", "v25",
        "v26", "v27", "v28", "v29", "v30", "v31",
        "cc", "memory");
#else
    __asm__ volatile ("" : : : "rax", "rcx", "rdx", "rsi", "rdi",
                      "r8", "r9", "r10", "r11", "cc", "memory");
#endif
    return x + 1;
}

struct large r450_large(struct large value)
{
    value.bytes[0] += 1;
    value.bytes[4095] += 1;
    value.bytes[8198] += 1;
    value.marker += 1;
    return value;
}

/* This peer owns the Linux x86-64 host boundary deliberately.  Five pushes
 * leave the call site 16-byte aligned, and all original saves are restored
 * even when an observed Landin return is wrong. */
#if defined(__APPLE__)
__asm__(
    ".text\n"
    ".globl _r450_registers\n"
    "_r450_registers:\n"
    "stp x29, x30, [sp, #-160]!\n"
    "mov x29, sp\n"
    "stp x19, x20, [sp, #16]\n"
    "stp x21, x22, [sp, #32]\n"
    "stp x23, x24, [sp, #48]\n"
    "stp x25, x26, [sp, #64]\n"
    "stp x27, x28, [sp, #80]\n"
    "stp d8, d9, [sp, #96]\n"
    "stp d10, d11, [sp, #112]\n"
    "stp d12, d13, [sp, #128]\n"
    "stp d14, d15, [sp, #144]\n"
    "mov x19, #119\n"
    "mov x20, #120\n"
    "mov x21, #121\n"
    "mov x22, #122\n"
    "mov x23, #123\n"
    "mov x24, #124\n"
    "mov x25, #125\n"
    "mov x26, #126\n"
    "mov x27, #127\n"
    "mov x28, #128\n"
    "mov x9, #108\n"
    "fmov d8, x9\n"
    "mov x9, #109\n"
    "fmov d9, x9\n"
    "mov x9, #110\n"
    "fmov d10, x9\n"
    "mov x9, #111\n"
    "fmov d11, x9\n"
    "mov x9, #112\n"
    "fmov d12, x9\n"
    "mov x9, #113\n"
    "fmov d13, x9\n"
    "mov x9, #114\n"
    "fmov d14, x9\n"
    "mov x9, #115\n"
    "fmov d15, x9\n"
    "mov x0, #10\n"
    "bl _r450_loop\n"
    "cmp x0, #145\n"
    "b.ne 1f\n"
    "cmp x19, #119\n"
    "b.ne 1f\n"
    "cmp x20, #120\n"
    "b.ne 1f\n"
    "cmp x21, #121\n"
    "b.ne 1f\n"
    "cmp x22, #122\n"
    "b.ne 1f\n"
    "cmp x23, #123\n"
    "b.ne 1f\n"
    "cmp x24, #124\n"
    "b.ne 1f\n"
    "cmp x25, #125\n"
    "b.ne 1f\n"
    "cmp x26, #126\n"
    "b.ne 1f\n"
    "cmp x27, #127\n"
    "b.ne 1f\n"
    "cmp x28, #128\n"
    "b.ne 1f\n"
    "fmov x9, d8\n"
    "cmp x9, #108\n"
    "b.ne 1f\n"
    "fmov x9, d9\n"
    "cmp x9, #109\n"
    "b.ne 1f\n"
    "fmov x9, d10\n"
    "cmp x9, #110\n"
    "b.ne 1f\n"
    "fmov x9, d11\n"
    "cmp x9, #111\n"
    "b.ne 1f\n"
    "fmov x9, d12\n"
    "cmp x9, #112\n"
    "b.ne 1f\n"
    "fmov x9, d13\n"
    "cmp x9, #113\n"
    "b.ne 1f\n"
    "fmov x9, d14\n"
    "cmp x9, #114\n"
    "b.ne 1f\n"
    "fmov x9, d15\n"
    "cmp x9, #115\n"
    "b.ne 1f\n"
    "mov w0, #0\n"
    "b 2f\n"
    "1: mov w0, #1\n"
    "2:\n"
    "ldp d8, d9, [sp, #96]\n"
    "ldp d10, d11, [sp, #112]\n"
    "ldp d12, d13, [sp, #128]\n"
    "ldp d14, d15, [sp, #144]\n"
    "ldp x19, x20, [sp, #16]\n"
    "ldp x21, x22, [sp, #32]\n"
    "ldp x23, x24, [sp, #48]\n"
    "ldp x25, x26, [sp, #64]\n"
    "ldp x27, x28, [sp, #80]\n"
    "ldp x29, x30, [sp], #160\n"
    "ret\n"
);
#else
__asm__(
    ".text\n"
    ".globl r450_registers\n"
    ".type r450_registers,@function\n"
    "r450_registers:\n"
    "pushq %rbx\n"
    "pushq %r12\n"
    "pushq %r13\n"
    "pushq %r14\n"
    "pushq %r15\n"
    "movq $101,%rbx\n"
    "movq $102,%r12\n"
    "movq $103,%r13\n"
    "movq $104,%r14\n"
    "movq $105,%r15\n"
    "movl $10,%edi\n"
    "call r450_loop\n"
    "cmpq $145,%rax\n"
    "jne 1f\n"
    "cmpq $101,%rbx\n"
    "jne 1f\n"
    "cmpq $102,%r12\n"
    "jne 1f\n"
    "cmpq $103,%r13\n"
    "jne 1f\n"
    "cmpq $104,%r14\n"
    "jne 1f\n"
    "cmpq $105,%r15\n"
    "jne 1f\n"
    "xorl %eax,%eax\n"
    "jmp 2f\n"
    "1: movl $1,%eax\n"
    "2: popq %r15\n"
    "popq %r14\n"
    "popq %r13\n"
    "popq %r12\n"
    "popq %rbx\n"
    "ret\n"
    ".size r450_registers,.-r450_registers\n"
);
#endif
