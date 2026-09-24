"""Execute memory-model independent M0 instructions and bounded abstract models."""
import json
import socket
import subprocess
import time
from pathlib import Path
HERE = Path(__file__).resolve().parent


def execute(run):
    from run import require, oracle, stop
    from memory_model import run as model
    (run.out / 'memory-model.json').write_text(json.dumps(model(), indent=2)+'\n')
    run.build('memory')
    disassembly = run.command('disassemble-memory',
        [run.bin / 'arm-none-eabi-objdump', '-d', 'memory.elf'])
    require(all(op in disassembly for op in ('dmb', 'dsb', 'isb', 'strb', 'strh', 'ldrb', 'ldrh')),
            'missing memory width/barrier controls')
    require('__atomic_' not in disassembly, 'unexpected atomic runtime helper')
    # Independently compile an unsupported RMW to an object: the pinned GCC
    # requires an external helper rather than inventing an M0 exclusive pair.
    source = run.out / 'unsupported-rmw.c'
    source.write_text('unsigned bump(unsigned *p) { return __atomic_fetch_add(p,1,5); }\n')
    run.command('compile-unsupported-rmw', [run.bin / 'arm-none-eabi-gcc',
        '-mcpu=cortex-m0', '-mthumb', '-O2', '-c', source, '-o', 'unsupported-rmw.o'])
    symbols = run.command('unsupported-rmw-symbols',
        [run.bin / 'arm-none-eabi-nm', '-u', 'unsupported-rmw.o'])
    require('__atomic_fetch_add_4' in symbols, 'M0 RMW helper control changed')
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    (run.out / 'memory.gdb').write_text('\n'.join([
        f'target remote 127.0.0.1:{port}', 'set pagination off', 'set confirm off',
        'break done', 'continue', 'python', 'import gdb',
        'assert int(gdb.parse_and_eval("result")) == 0x630',
        'assert int(gdb.parse_and_eval("fault_seen")) == 0',
        'print("R630_MEMORY_PASS")', 'end', 'quit'])+'\n')
    argv = [str(run.bin / 'qemu-system-arm'), '-M', 'microbit', '-accel',
            'tcg,thread=single', '-display', 'none', '-monitor', 'none',
            '-serial', 'null', '-kernel', 'memory.elf', '-S', '-gdb', f'tcp:127.0.0.1:{port}']
    record = dict(name='qemu-memory', argv=argv, timeout_seconds=25)
    run.commands.append(record)
    tick = time.monotonic()
    with (run.out / 'qemu-memory.log').open('wb') as log:
        p = subprocess.Popen(argv, cwd=run.out, env=run.env, stdout=log, stderr=log,
                             start_new_session=True)
        try:
            deadline = time.monotonic()+3
            while True:
                require(p.poll() is None, 'memory QEMU exited before debugger')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1): break
                except OSError:
                    require(time.monotonic() < deadline, 'memory debugger startup timed out')
                    time.sleep(.02)
            text = run.command('gdb-memory', [run.bin / 'gdb-multiarch', '-q', '-nx',
                               '-batch', 'memory.elf', '-x', 'memory.gdb'], timeout=20)
            oracle(text, 'R630_MEMORY_PASS')
        finally:
            stop(p)
            record.update(exit=p.returncode, seconds=time.monotonic()-tick,
                          stopped_by_supervisor=True)
            (run.out / 'commands.json').write_text(json.dumps(run.commands, indent=2)+'\n')
