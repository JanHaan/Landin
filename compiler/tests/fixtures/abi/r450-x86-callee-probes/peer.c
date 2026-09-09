#include <stdint.h>

struct large {
    uint8_t bytes[8199];
    uint64_t marker;
};

int64_t r450_step(int64_t x)
{
    /* Force every volatile GP bank to be unavailable across this call. */
    __asm__ volatile ("" : : : "rax", "rcx", "rdx", "rsi", "rdi",
                      "r8", "r9", "r10", "r11", "cc", "memory");
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
