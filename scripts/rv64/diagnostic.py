#!/usr/bin/env python3
"""Fail-fast native RISE feasibility checks; not Landin backend evidence."""
import pathlib
import platform
import shutil
import subprocess
import sys


def run(*command):
    print('+', ' '.join(map(str, command)), flush=True)
    return subprocess.run(command, check=True, text=True, timeout=120)


def main():
    if platform.machine() != 'riscv64':
        raise SystemExit('native riscv64 hardware is required')
    output = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'rv64-diagnostic')
    output.mkdir(parents=True, exist_ok=True)
    cpu = pathlib.Path('/proc/cpuinfo').read_text()
    (output / 'cpuinfo.txt').write_text(cpu)
    print(cpu, flush=True)
    run('uname', '-a')
    for tool in ('gcc', 'as', 'ld', 'objdump', 'gdb'):
        if not shutil.which(tool):
            raise SystemExit(f'required native tool is missing: {tool}')
        run(tool, '--version')
    source = output / 'probe.c'
    source.write_text('''#include <stdint.h>
#include <stdio.h>
#include <signal.h>
#include <stdlib.h>
__attribute__((noinline)) uint64_t operation(uint64_t base, uint64_t index) {
    uint64_t result;
#ifdef EXTENDED
    __asm__ volatile ("th.addsl %0, %1, %2, 3" : "=r"(result) : "r"(base), "r"(index));
#else
    __asm__ volatile ("slli %0, %2, 3\\n\\tadd %0, %0, %1" : "=&r"(result) : "r"(base), "r"(index));
#endif
    return result;
}
static void unsupported(int signal) { (void)signal; _Exit(77); }
int main(void) {
    signal(SIGILL, unsupported);
    volatile uint64_t base = 10, index = 4;
    uint64_t result = operation(base, index);
    printf("result=%lu\\n", (unsigned long)result);
    return result != 42;
}
''')
    for name, isa in (('baseline', 'rv64gc'), ('extended', 'rv64gc_xtheadba')):
        executable = output / name
        command = ['gcc', '-g', '-O0', '-mabi=lp64d', '-march=' + isa]
        if name == 'extended':
            command.append('-DEXTENDED')
        run(*command, str(source), '-o', str(executable))
        with (output / (name + '.disassembly.txt')).open('w') as stream:
            subprocess.run(['objdump', '-d', str(executable)], stdout=stream, check=True)
        # A protected isolated instruction probe verifies actual execution support.
        run(str(executable.resolve()))
        print(name + ' instruction execution: PASS', flush=True)
    refused = subprocess.run(['gcc', '-mabi=lp64d', '-march=rv64gc', '-DEXTENDED',
                              '-c', str(source), '-o', str(output / 'refused.o')],
                             text=True, capture_output=True, timeout=60)
    (output / 'baseline-refusal.txt').write_text(refused.stdout + refused.stderr)
    if refused.returncode == 0 or 'xtheadba' not in refused.stderr.lower():
        raise SystemExit('baseline assembler did not refuse the extension')
    print('baseline assembler refusal: PASS', flush=True)
    commands = output / 'session.gdb'
    commands.write_text('''set pagination off
set confirm off
set disable-randomization off
break operation
run
bt
info args
print base
print index
finish
quit
''')
    debugger = subprocess.run(['gdb', '-q', '-batch', '-x', str(commands),
                               str(output / 'baseline')], text=True,
                              capture_output=True, timeout=120)
    transcript = debugger.stdout + debugger.stderr
    (output / 'gdb.txt').write_text(transcript)
    print(transcript, flush=True)
    if debugger.returncode or not all(fragment in transcript for fragment in
                                     ('Breakpoint 1, operation', 'base=10',
                                      'index=4', '#1', 'Value returned is')):
        raise SystemExit('native GDB launching/values/unwinding failed')
    print('native GDB feasibility: PASS', flush=True)


if __name__ == '__main__':
    main()
