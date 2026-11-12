#!/usr/bin/env python3
"""Execute the compiler-owned firmware path; never use backend-start.S."""
import argparse
import contextlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time

from backend import LANE_ROOT, derived, image_contract
from packed_native import PROFILES
from packed import TRACE
from machine import Machine
from models import EncodingPeripheral, PrototypePeripheral
from run import Run, gdb_listener, oracle, require, stop
from setup import DEFAULT, installed_tools, inventory, sha, supported_host


BREAK_AT_LINE = re.compile(r'break (\S+):(\d+)$')


def landed(commands):
    """COMMANDS with each `break FILE:LINE` followed by GDB's own check that
    the breakpoint is on LINE.  GDB moves a breakpoint on a line with no
    code to the next one that has some, so a stop whose source moved would
    otherwise wait for a line that never runs and end as a timeout."""
    checked = []
    for command in commands:
        checked.append(command)
        found = BREAK_AT_LINE.match(command)
        if found:
            path, line = found.group(1), int(found.group(2))
            checked += ['python',
                        'lines = sorted({l.source[1] for l in gdb.breakpoints()[-1].locations})',
                        f'assert lines == [{line}], "break {path}:{line} has no code on line'
                        f' {line}; GDB put it on line(s) %s" % lines',
                        'end']
    return checked


def execute(run, elf, commands=None, marker="R660_FIRMWARE_BOOT_PASS", machine='microbit',
            trace=()):
    listener, port, stub = gdb_listener()
    script = run.out / 'firmware.gdb'
    # Poison RAM before execution to distinguish reset initialization from
    # the emulator loader or its power-on memory contents. Reset twice.
    boot = [
        'set pagination off', 'set confirm off',
        f'target remote 127.0.0.1:{port}',
        'python', 'import gdb',
        'def v(s): return int(gdb.parse_and_eval(s)) & 0xffffffff',
        'assert v("$sp") == 0x20004000',
        'assert v("*(unsigned*)0") == 0x20004000',
        'assert v("*(unsigned*)4") & 1 == 1',
        'assert v("$pc") == v("*(unsigned*)4") & ~1',
        'for slot in (4,5,6,7,8,9,10,12,13,21,42,43,44,45,46,47):',
        '    assert v("*(unsigned*)%d" % (slot*4)) == 0',
        'end',
        *sum(([
            'set *(unsigned*)&initialized = 0xaaaaaaaa',
            'set *(unsigned*)&cleared = 0xbbbbbbbb',
            'set *(unsigned*)&observed = 0xcccccccc',
            'break *start', 'continue', 'python',
            'assert v("$sp") == 0x20004000',
            'assert v("$r11") == 0 and v("$r9") == 0',
            'assert v("*(unsigned*)&initialized") == 0x12345678',
            'assert v("*(unsigned*)&cleared") == 0',
            'assert v("&initialized") >= 0x20000000',
            'assert v("&immutable") < 0x8000',
            'end', 'delete breakpoints',
            'break _landin_firmware_returned', 'continue', 'python',
            'assert v("*(unsigned*)&observed") == 0x12345685',
            'assert v("$sp") == 0x20004000 and v("$r11") == 0',
            'assert v("$r12") == 0', 'end', 'delete breakpoints',
            *(['monitor system_reset', 'maintenance flush register-cache']
              if boot == 0 else [])] for boot in range(2)), []),
        'break _landin_firmware_unhandled', 'continue', 'python',
        'assert v("$xpsr") & 0x1ff == 3',
        'assert v("*(unsigned short*)*(unsigned*)($sp+24)") == 0xde01',
        'assert v("$sp") >= 0x20003000 and v("$sp") % 8 == 0',
        'print("R660_FIRMWARE_BOOT_PASS")', 'end', 'quit', '']
    script.write_text('\n'.join(boot if commands is None else [
        'set pagination off', 'set confirm off',
        f'target remote 127.0.0.1:{port}',
        'python', 'import gdb',
        'def v(s): return int(gdb.parse_and_eval(s)) & 0xffffffff',
        'end', *landed(commands), 'quit', '']))
    argv = [str(run.bin / 'qemu-system-arm'), '-M', machine, '-accel',
            'tcg,thread=single', '-display', 'none', '-monitor', 'none',
            '-serial', 'none', '-kernel', str(elf), '-S', *stub,
            *(['-D', str(run.out / 'trace.log')] if trace else []),
            *(argument for event in trace for argument in ('-trace', event))]
    record = {'name': 'qemu-firmware', 'argv': argv, 'timeout_seconds': 25}
    run.commands.append(record)
    tick = time.monotonic()
    with (run.out / 'qemu.log').open('wb') as log:
        with listener:
            process = subprocess.Popen(argv, cwd=run.out, env=run.env, stdout=log,
                                       stderr=log, start_new_session=True,
                                       pass_fds=(listener.fileno(),))
        try:
            #  The stub's socket is listening before QEMU starts, so GDB's
            #  connection waits in its backlog rather than racing the start.
            require(process.poll() is None, 'QEMU exited before connection')
            text = run.debug('gdb-firmware', elf, script, timeout=20)
            oracle(text, marker)
        finally:
            stop(process)
            record['seconds'] = time.monotonic() - tick
            record['exit'] = process.returncode
            (run.out / 'commands.json').write_text(json.dumps(run.commands, indent=2)+'\n')


#  examples.md's firmware program and the line its serial port carries.
EXAMPLE = (Path(__file__).resolve().parents[2]
           / 'compiler/tests/fixtures/end-to-end/example-firmware-serial')


def example(run, refine):
    """Build and run examples.md's firmware program as the page tells a
    reader to, and hold what the serial port carried to the fixture's
    `serial.txt`.

    The page's build is `refine compile --target=cortex-m0
    --firmware-entry=start main.ldn -o firmware.elf`, with the driver on
    PATH; the lane names its own pinned driver.  The page's run sends the
    machine's serial port to the terminal, `-serial stdio`; here it goes to
    a file.  The program returns once the line is sent and the compiler's
    return trap then loops, so the emulator runs until it is stopped: the
    case waits for the bytes, then a moment more for any that should not
    follow.
    """
    (run.out / 'main.ldn').write_bytes((EXAMPLE / 'main.ldn').read_bytes())
    run.command('compile', [refine, 'compile', '--target=cortex-m0',
        '--firmware-entry=start', '--toolchain=' + str(run.arm / 'arm-eabi-gcc'),
        'main.ldn', '-o', 'firmware.elf'], timeout=60)
    expected = (EXAMPLE / 'serial.txt').read_bytes()
    serial = run.out / 'serial.txt'
    argv = [str(run.bin / 'qemu-system-arm'), '-M', 'microbit', '-display', 'none',
            '-monitor', 'none', '-serial', 'file:' + serial.name,
            '-kernel', 'firmware.elf']
    record = {'name': 'qemu-example', 'argv': argv, 'timeout_seconds': 25}
    run.commands.append(record)
    tick = time.monotonic()
    carried = b''
    with (run.out / 'qemu.log').open('wb') as log:
        process = subprocess.Popen(argv, cwd=run.out, env=run.env, stdout=log,
                                   stderr=log, start_new_session=True)
        try:
            settled = None
            while time.monotonic() - tick < record['timeout_seconds']:
                require(process.poll() is None, 'QEMU exited while the example ran')
                carried = serial.read_bytes() if serial.exists() else b''
                if len(carried) >= len(expected):
                    if settled is None:
                        settled = time.monotonic()
                    elif time.monotonic() - settled >= 0.5:
                        break
                time.sleep(0.05)
        finally:
            stop(process)
            record['seconds'] = time.monotonic() - tick
            record['exit'] = process.returncode
            (run.out / 'commands.json').write_text(json.dumps(run.commands, indent=2)+'\n')
    require(carried == expected, 'the example\'s serial port carried %r, and'
            ' examples.md and the fixture\'s serial.txt say %r' % (carried, expected))
    return [{'kind': 'example', 'machine': 'microbit', 'status': 'passed'}]


def build(run, refine, program=None, optimize="none", specialize="off", debug='none',
          level="armv6-m", root=None, roots=(), profile=None):
    source = run.out / 'boot.ldn'
    if root is not None:
        (run.out / 'app').mkdir()
        source = run.out / 'app/main.ldn'
    source.write_text(program if program is not None else '''mut initialized: u32 = 0x12345678
mut cleared: u32 = 0
mut observed: u32 = 0
immutable: [2]u32 = [5, 8]
start: () -> none =
    observed = initialized + cleared + immutable[0] + immutable[1]
end start
''')
    elf = run.out / 'firmware.elf'
    run.command('compile', [refine, '--target=cortex-m0', '--level='+level,
        *(['--root='+str(root)] if root is not None else []),
        *('--root=' + str(one) for one in roots), '--firmware-entry=start',
        '--emit=exe', '--debug='+debug, '--toolchain=' + str(run.arm / 'arm-eabi-gcc'),
        '--optimize='+optimize, '--specialize='+specialize,
        'app' if root is not None else source.name, '-o', elf.name], timeout=60)
    run.command('elf', [run.arm / 'arm-eabi-readelf', '-h', '-A', '-S', '-l', '-r', elf])
    run.command('disassembly', [run.arm / 'arm-eabi-objdump', '-dr', elf])
    symbols = run.command('symbols', [run.arm / 'arm-eabi-nm', '-n', elf])
    names = {line.split()[-1] for line in symbols.splitlines() if line.split()}
    #  A C runtime routine would be global; a Landin routine is a local
    #  symbol under its own name (D415), an instance of `free` among them
    #  (D421), so only the global symbols are the closure's runtime.
    exported = {parts[-1] for line in symbols.splitlines()
                if len(parts := line.split()) >= 2 and parts[-2].isupper()}
    require(not exported & {'malloc', 'calloc', 'realloc', 'free', 'exit', '_exit',
                         '__libc_init_array', '__libc_start_main', '_sbrk'},
            'firmware imported a hosted runtime dependency')
    mapping = (run.out / 'firmware.elf.map').read_text()
    require('libc.a' not in mapping and 'crt0.o' not in mapping,
            'firmware linked an implicit hosted startup or libc')
    require(not run.command('undefined', [run.arm / 'arm-eabi-nm', '-u', elf]).strip(),
            'firmware contains unresolved symbols')
    (run.out / 'image.json').write_text(json.dumps(image_contract(elf, profile), indent=2)+'\n')
    return elf


FLOAT_UNIT = """import descriptions/mps2_an500
mut values: [4]f64
mut handled: u32 = 0
mut seen: f64 = 0.0
link(vector: 15)
extern(interrupt) tick: () -> none =
    handled = handled + 1
    seen = values[2] * 2.0
end tick
pend: () -> none =
    assembler.block(\"\"\"
        ldr r0, =0xe000ed04
        ldr r1, =0x04000000
        str r1, [r0]
        dsb sy
        isb sy
        \"\"\")
end pend
mix: (a: f64, b: f64) -> (r: f64) =
    r = a * b + a
    pend()
    r = r / b
end mix
start: () -> none =
    values[0] = 1.5
    values[1] = 2.5
    values[2] = 3.0
    values[3] = mix(values[0], values[1])
end start
"""


def float_unit(parent, refine):
    """D618: compiler-owned reset on the mps2-an500 lane, a Cortex-M7 with
    FPv5-D16 (D619).  Reset has granted CP10 and CP11 before `start`; a
    SysTick pended in the middle of a float computation is taken with the
    float context active, so its EXC_RETURN is 0xffffffe9 and the extended
    frame is reserved lazily; the handler's own float instruction fills it,
    the return restores the interrupted d0, and the computation ends with
    its IEEE value.  The image carries the unit's attributes, and a
    soft-float C object linked into it is refused, as are the mixed pairs
    `mixed_objects` links (D780)."""
    out = parent.out
    run = Run(out, parent.tools)
    profile = derived(run, refine, 'mps2-an500', out / 'profiles')
    elf = build(run, refine, FLOAT_UNIT, level='armv7e-m', roots=(LANE_ROOT,), profile=profile)
    #  D617: GCC selects the hard multilib from the flags refine passes.
    helper = run.command('float-runtime-archive', [
        run.arm / 'arm-eabi-gcc', '-mcpu=cortex-m7', '-mthumb', '-mfloat-abi=hard',
        '-mfpu=fpv5-d16', '-print-libgcc-file-name']).strip()
    require(helper.endswith('/thumb/v7e-m+dp/hard/libgcc.a'),
            'hard float selects the runtime archive ' + helper)
    require('/thumb/v7e-m+dp/hard/libgcc.a' in (out / 'firmware.elf.map').read_text(),
            'the firmware did not link the hard-float runtime archive')
    attributes = (out / 'elf.log').read_text()
    require('Tag_FP_arch: FPv5/FP-D16 for ARMv8' in attributes
            and 'Tag_ABI_VFP_args: VFP registers' in attributes,
            'the firmware image does not carry the float unit\'s attributes')
    execute(run, elf, [
        'break *start', 'continue', 'delete breakpoints', 'python',
        'assert v("*(unsigned*)0xe000ed88") & (0xf << 20) == 0xf << 20, "reset left CP10/CP11 closed"',
        'assert v("*(unsigned*)0xe000ef34") & 0xc0000000 == 0xc0000000, "lazy stacking is not its reset default"',
        'end',
        'break *tick', 'continue', 'delete breakpoints', 'python',
        'assert v("$lr") == 0xffffffe9, "EXC_RETURN is %#x, not a thread on MSP with an extended frame" % v("$lr")',
        'assert v("*(unsigned*)0xe000ef34") & 1 == 1, "the float state was not preserved lazily"',
        'assert v("*(unsigned*)0xe000ef38") == v("$sp") + 32, "the lazy frame is not above the basic one"',
        'before = bytes(gdb.selected_frame().read_register("d0").bytes)',
        'resume = v("*(unsigned*)($sp+24)")',
        'gdb.execute("break *%d" % resume)',
        'end',
        'continue', 'delete breakpoints', 'python',
        'assert v("*(unsigned*)&handled") == 1',
        'assert float(gdb.parse_and_eval("*(double*)&seen")) == 6.0',
        'assert bytes(gdb.selected_frame().read_register("d0").bytes) == before, "the interrupted d0 was not restored"',
        'end',
        'break _landin_firmware_returned', 'continue', 'python',
        'assert float(gdb.parse_and_eval("((double*)&values)[3]")) == (1.5 * 2.5 + 1.5) / 2.5',
        'print("D618_FLOAT_UNIT_PASS")', 'end'], marker='D618_FLOAT_UNIT_PASS',
        machine='mps2-an500')
    #  D617: a soft-float object does not link into the hard-float image.
    (out / 'soft.c').write_text('double twice(double x) { return x * 2.0; }\n')
    run.command('soft-object', [run.arm / 'arm-eabi-gcc', '-mcpu=cortex-m7', '-mthumb',
                '-mfloat-abi=soft', '-fno-short-enums', '-O1', '-c', 'soft.c', '-o', 'soft.o'])
    try:
        run.command('mixed-link', [run.arm / 'arm-eabi-gcc', '-mcpu=cortex-m7', '-mthumb',
                    '-mfloat-abi=hard', '-mfpu=fpv5-d16', '-nostdlib', '-nostartfiles',
                    '-Wl,-T,firmware.elf.ld', 'firmware.elf.o', 'soft.o', '-lgcc',
                    '-o', 'mixed.elf'])
    except RuntimeError:
        log = (out / 'mixed-link.log').read_text()
        require('uses VFP register arguments' in log,
                'the mixed link failed for another reason; inspect ' + str(out / 'mixed-link.log'))
    else:
        raise RuntimeError('a soft-float object linked into the hard-float image')
    mixed_objects(run, Run(out / 'soft-float', parent.tools), refine)
    return [{'kind': 'float-unit', 'level': 'armv7e-m', 'optimize': 'none',
             'specialize': 'off', 'status': 'passed', 'lane': 'mps2-an500'}]


FLOAT_DEBUG = """import descriptions/mps2_an500
mut handled: u32 = 0
mut seen: f64 = 0.0
mut result: f64 = 0.0
mut whole: u32 = 0
link(vector: 15)
extern(interrupt) tick: () -> none =
    handled = handled + 1
    seen = result * 2.0
end tick
pend: () -> none =
    assembler.block(\"\"\"
        ldr r0, =0xe000ed04
        ldr r1, =0x04000000
        str r1, [r0]
        dsb sy
        isb sy
        \"\"\")
end pend
keep: (seed: u32, a: f64, b: f32, scale: f64) -> (r: f64) =
    whole = assembler.block(
        "vmov s16, {s}\\nvmov s31, {s}\\nvmov {r}, s16\\nadds {r}, #1",
        in s: u32 at general = seed, out r: u32 at general,
        out _ at d8, out _ at d15)
    r = a * scale + f64(b)
    result = r
    pend()
    r = r / scale
end keep
start: () -> none =
    result = keep(7, 1.5, 0.25, 2.5)
end start
"""


def float_debug(parent, refine):
    """A debugger's view of the float unit on the mps2-an500 lane, by
    unwinding rather than by the corpus's sentinels.

    The image is built with line and frame information.  At `keep`'s first
    instruction GDB reads its arguments where AAPCS-VFP banks them: the
    integer in r0, the f64s in d0 and d2 and the f32 between them in s2.
    `keep` holds an assembly block that names d8 and d15, so it is a
    framed routine that saves d8-d15 (D617); once the block has written
    both, GDB reads d8-d15 in the caller's frame as the session set them
    in `start`, which only the routine's CFI for the saved registers
    gives.  A SysTick pended in `pend` is taken with an extended frame,
    EXC_RETURN 0xffffffe9; ordinary unwinding stops at interrupt entry, so
    the session selects the interrupted context above the frame's 26
    words, as the `leaf` control does above a basic frame's 8, and unwinds
    `pend`, `keep`, `start` and reset from there, reading the caller's
    d8-d15 again.  At the return they are the session's, and the
    computation has its IEEE value.
    """
    import source_debug
    out = parent.out
    run = Run(out, parent.tools)
    profile = derived(run, refine, 'mps2-an500', out / 'profiles')
    elf = build(run, refine, FLOAT_DEBUG, level='armv7e-m', debug='lines',
                roots=(LANE_ROOT,), profile=profile)
    line = source_debug.source_line(run, 'boot.ldn', 'result = r')
    sentinels = {8 + index: 100.5 + index for index in range(8)}
    held = ('for n, want in %r.items(): assert d(%%s, n) == want, (n, d(%%s, n))'
            % sentinels)
    execute(run, elf, [
        *source_debug.search(elf), *source_debug.PRELUDE,
        'python', 'import struct',
        'def d(frame, n): return float(frame.read_register("d%d" % n))',
        'def raw(frame, n): return bytes(frame.read_register("d%d" % n).bytes)',
        'end',
        'break *start', 'continue', 'delete breakpoints',
        *('set $d%d = %r' % item for item in sentinels.items()),
        'python', held % ('gdb.newest_frame()', 'gdb.newest_frame()'), 'end',
        #  The arguments where the procedure call standard banks them.
        'break *keep', 'continue', 'delete breakpoints', 'python',
        'f = gdb.newest_frame()',
        'assert v("$r0") == 7, "the integer argument is %d in r0" % v("$r0")',
        'assert d(f, 0) == 1.5, "the first f64 is %r in d0" % d(f, 0)',
        'assert float(f.read_register("s2")) == 0.25, "the f32 is %r in s2" % float(f.read_register("s2"))',
        'assert d(f, 2) == 2.5, "the second f64 is %r in d2" % d(f, 2)',
        'end',
        #  d8-d15 as the caller left them, through the callee's CFI, once
        #  the block has written d8's low half and d15's high one.
        'break boot.ldn:%d' % line, 'continue', 'delete breakpoints', 'python',
        'chain(["keep", "start", "_landin_firmware_reset"])',
        'f = gdb.newest_frame()',
        'assert struct.unpack("<I", raw(f, 8)[:4])[0] == 7, "the block did not write s16"',
        'assert struct.unpack("<I", raw(f, 15)[4:])[0] == 7, "the block did not write s31"',
        held % ('f.older()', 'f.older()'),
        'end', 'bt',
        #  The handler entered over an extended frame, and the interrupted
        #  context selected above it.
        'break *tick', 'continue', 'delete breakpoints', 'python',
        'assert v("$lr") == 0xffffffe9, "EXC_RETURN is %#x, not an extended frame\'s" % v("$lr")',
        'assert v("$xpsr") & 511 == 15',
        'assert gdb.newest_frame().older() is None',
        'saved = {r: v("$" + r) for r in ("sp", "pc", "lr")}',
        'hw = struct.unpack("<8I", bytes(gdb.selected_inferior().read_memory(saved["sp"], 32)))',
        'gdb.execute("set $sp = %d" % (saved["sp"] + 104 + (4 if hw[7] & 512 else 0)))',
        'gdb.execute("set $lr = %d" % hw[5])',
        'gdb.execute("set $pc = %d" % hw[6])',
        'chain(["pend", "keep", "start", "_landin_firmware_reset"])',
        'gdb.execute("bt")',
        'f = gdb.newest_frame().older().older()',
        held % ('f', 'f'),
        'gdb.execute("frame 0")',
        'for reg, value in saved.items(): gdb.execute("set $%s = %d" % (reg, value))',
        'end',
        'break _landin_firmware_returned', 'continue', 'python',
        'assert v("*(unsigned*)&handled") == 1',
        'assert v("*(unsigned*)&whole") == 8',
        'assert float(gdb.parse_and_eval("*(double*)&result")) == (1.5 * 2.5 + 0.25) / 2.5',
        'assert float(gdb.parse_and_eval("*(double*)&seen")) == (1.5 * 2.5 + 0.25) * 2.0',
        held % ('gdb.newest_frame()', 'gdb.newest_frame()'),
        'print("FLOAT_DEBUG_PASS")', 'end'], marker='FLOAT_DEBUG_PASS', machine='mps2-an500')
    return [{'kind': 'float-debug', 'level': 'armv7e-m', 'optimize': 'none',
             'specialize': 'off', 'status': 'passed', 'lane': 'mps2-an500'}]


CACHE_SEQUENCE = """import core/cache
import descriptions/mps2_an500_cached
import platform/cortex_m/l1
link(align: 32)
mut buffer: [64]u8 = zeroed
mut started: u32 = 0
mut sizes: u32 = 0
mut refused: u32 = 0
mut observed: u32 = 0
start: () -> none =
    control: ptr u32 = ptr(0xe000_ed14)
    started = compiler.volatile_load(control)
    sizes = l1.geometry()
    caches := l1.new()
    cache.clean(caches, buffer[0..<64]) else (problem)
        _ = problem
        return
    end
    cache.invalidate(caches, buffer[32..<64]) else (problem)
        _ = problem
        return
    end
    cache.clean_invalidate(caches, buffer[0..<32]) else (problem)
        _ = problem
        return
    end
    cache.invalidate(caches, buffer[1..<33]) else (problem)
        if problem == cache.misaligned then refused += 1 end if
    end
    cache.clean(caches, buffer[0..<48]) else (problem)
        if problem == cache.misaligned then refused += 1 end if
    end
    cache.clean_invalidate(caches, buffer[16..<48]) else (problem)
        if problem == cache.misaligned then refused += 1 end if
    end
    observed = 0x600d0000 + u32(cache.line(caches))
end start
"""

#  The SCB registers a cached profile's code writes and reads, by the name
#  each one's literal stands for in the listing.
SCB_NAMES = {0xe000ed14: 'CCR', 0xe000ed80: 'CCSIDR', 0xe000ed84: 'CSSELR',
             0xe000ed88: 'CPACR', 0xe000ef50: 'ICIALLU', 0xe000ef5c: 'DCIMVAC',
             0xe000ef60: 'DCISW', 0xe000ef68: 'DCCMVAC', 0xe000ef70: 'DCCIMVAC',
             0xe000ef74: 'DCCISW'}
LISTED = re.compile(r'^\s*([0-9a-f]+):\s+(?:[0-9a-f]{4}\s?){1,2}\s+(\S+)\s*(.*)$')
LITERAL = re.compile(r'@ \(([0-9a-f]+) <')
ROUTINE = re.compile(r'^([0-9a-f]+) <([^>]+)>:$')
#  The backend's own labels inside a routine, which the listing heads as
#  symbols of their own.
INNER = re.compile(r'^L(?:cm_step_)?\d+(?:_\w+)?$')


def listed_routines(listing):
    """Each routine of an objdump -d LISTING: its instructions, each
    (address, mnemonic, operands), and every literal word by address."""
    routines, words, current = {}, {}, None
    for line in listing.splitlines():
        head = ROUTINE.match(line)
        if head:
            if not (INNER.match(head.group(2)) and current is not None):
                current = routines.setdefault(head.group(2), [])
            continue
        found = LISTED.match(line)
        if not found or current is None:
            continue
        address, mnemonic, operands = int(found.group(1), 16), found.group(2), found.group(3)
        if mnemonic == '.word':
            words[address] = int(operands.split()[0], 16)
        else:
            current.append((address, mnemonic, operands))
    return routines, words


def scb_sequence(instructions, words):
    """INSTRUCTIONS as the steps the cache contract orders: each SCB literal
    loaded, by its register's name, each barrier, the interrupt masks and
    the entry's call."""
    steps = []
    for _, mnemonic, operands in instructions:
        literal = LITERAL.search(operands)
        if mnemonic.startswith('ldr') and literal and words.get(int(literal.group(1), 16)) in SCB_NAMES:
            steps.append(SCB_NAMES[words[int(literal.group(1), 16)]])
        elif mnemonic in ('dsb', 'isb', 'cpsie', 'cpsid', 'orrs', 'bics'):
            steps.append(mnemonic)
        elif mnemonic.startswith('bl') and operands.endswith('<start>'):
            steps.append('bl start')
    return steps


def cache_sequence(parent, refine):
    """D977: the cached profile's sequences on the mps2-an500 lane, a
    Cortex-M7 QEMU models no cache for, so this is the order of the
    operations and nothing of a cache's behaviour.  The linked reset
    invalidates the data cache by set and way and the instruction cache
    and sets CCR's IC and DC, each completed by DSB and the enable by ISB,
    after the data, RAM code and BSS are written, and the return cleans
    and invalidates by set and way before clearing them; each by-address
    operation lies between two completion barriers, ISB after the second.
    Run with QEMU's trace of the System Control Space's writes, every
    write reset, the program and the return make is in that order, each
    maintenance write the line address its range says, a refused range
    writing none; and GDB reads, at the return, the three refusals, the
    line and CCR's IC and DC clear."""
    out = parent.out
    run = Run(out, parent.tools)
    #  The cached lane description's map is the mps2-an500 lane's, which
    #  descriptions.json records, so the image is held to that profile.
    profile = derived(run, refine, 'mps2-an500', out / 'profiles')
    elf = build(run, refine, CACHE_SEQUENCE, level='armv7e-m', roots=(LANE_ROOT,),
                profile=profile)
    routines, words = listed_routines((out / 'disassembly.log').read_text())
    reset = scb_sequence(routines['_landin_firmware_reset'], words)
    #  Each set and way pass combines its way and its set with an ORRS.
    expected = ['cpsid', 'CPACR', 'orrs', 'dsb', 'isb', 'dsb', 'isb',
                'CSSELR', 'dsb', 'CCSIDR', 'DCISW', 'orrs', 'dsb', 'ICIALLU', 'dsb', 'isb',
                'CCR', 'orrs', 'dsb', 'isb', 'cpsie', 'bl start',
                'cpsid', 'CSSELR', 'dsb', 'CCSIDR', 'DCCISW', 'orrs', 'dsb',
                'CCR', 'bics', 'dsb', 'isb', 'ICIALLU', 'dsb', 'isb']
    require(reset == expected, 'the cached reset orders its steps %s, not %s' % (reset, expected))
    maintain = [m for m in routines if m == 'maintain' or m.startswith('maintain')]
    require(maintain, 'the image has no maintain routine')
    for name in maintain:
        body = routines[name]
        barriers = [(i, m) for i, (_, m, _) in enumerate(body) if m in ('dsb', 'isb')]
        require([m for _, m in barriers] == ['dsb', 'dsb', 'isb'],
                '%s issues %s, not DSB, DSB and ISB' % (name, [m for _, m in barriers]))
        first, second = barriers[0][0], barriers[1][0]
        backward = [i for i, (address, m, operands) in enumerate(body)
                    if m.startswith('b') and not m.startswith('bl')
                    and re.match(r'([0-9a-f]+) <', operands)
                    and int(operands.split()[0], 16) < address]
        require(backward and all(first < i < second for i in backward),
                "%s's loop of stores does not lie between its completion barriers" % name)
    commands = [
        'break _landin_firmware_returned', 'continue', 'python',
        'assert v("&buffer") % 32 == 0',
        'assert v("*(unsigned*)&refused") == 3, "%d of the three misaligned ranges were refused" % v("*(unsigned*)&refused")',
        'assert v("*(unsigned*)&observed") == 0x600d0020',
        'assert v("*(unsigned*)0xe000ed14") & 0x30000 == 0, "CCR is %#x at the return" % v("*(unsigned*)0xe000ed14")',
        'print("D977_CACHE_SEQUENCE buffer %#x started %#x ccsidr %#x" % (v("&buffer"), v("*(unsigned*)&started"), v("*(unsigned*)&sizes")))',
        'print("D977_CACHE_SEQUENCE_PASS")', 'end']
    execute(run, elf, commands, marker='D977_CACHE_SEQUENCE_PASS', machine='mps2-an500',
            trace=('nvic_sysreg_write',))
    buffer = int(re.search(r'D977_CACHE_SEQUENCE buffer (0x[0-9a-f]+)',
                           (out / 'gdb-firmware.log').read_text()).group(1), 16)
    writes = [(0xe000e000 + int(a, 16), int(d, 16)) for a, d in re.findall(
        r'nvic_sysreg_write .*?addr 0x([0-9a-f]+) data 0x([0-9a-f]+)',
        (out / 'trace.log').read_text())]
    named = [(SCB_NAMES.get(a, hex(a)), d) for a, d in writes]
    (out / 'scb-writes.json').write_text(json.dumps(
        [[name, '%#010x' % data] for name, data in named], indent=1) + '\n')
    def runs(steps):
        """STEPS with each run of one register's writes as one step and
        its count, except where the values are the evidence."""
        folded = []
        for name, data in steps:
            if folded and folded[-1][0] == name and name in ('DCISW', 'DCCISW'):
                folded[-1][2] += 1
            else:
                folded.append([name, data, 1])
        return folded
    folded = runs(named)
    order = [step[0] for step in folded]
    want = ['CPACR', 'CSSELR', 'DCISW', 'ICIALLU', 'CCR',
            'DCCMVAC', 'DCCMVAC', 'DCIMVAC', 'DCCIMVAC',
            'CSSELR', 'DCCISW', 'CCR', 'ICIALLU']
    require(order == want, 'the System Control Space is written %s, not %s' % (order, want))
    lines = [(step[0], step[1]) for step in folded if step[0] in ('DCCMVAC', 'DCIMVAC', 'DCCIMVAC')]
    require(lines == [('DCCMVAC', buffer), ('DCCMVAC', buffer + 32), ('DCIMVAC', buffer + 32),
                      ('DCCIMVAC', buffer)],
            'the maintenance writes are %s, not the ranges\' lines' % [(n, hex(d)) for n, d in lines])
    ccr = [step[1] for step in folded if step[0] == 'CCR']
    require(ccr[0] & 0x30000 == 0x30000 and ccr[1] & 0x30000 == 0,
            'reset writes CCR %#x and the return %#x' % tuple(ccr))
    passes = [step[2] for step in folded if step[0] in ('DCISW', 'DCCISW')]
    require(passes[0] == passes[1], 'reset and the return pass over %d and %d sets and ways'
            % tuple(passes))
    return [{'kind': 'cache-sequence', 'level': 'armv7e-m', 'optimize': 'none',
             'specialize': 'off', 'status': 'passed', 'lane': 'mps2-an500',
             'set_way_writes': passes[0], 'scb_writes': len(writes),
             'evidence': 'sequencing only: QEMU models no cache'}]


SOFT_FLOAT = """mut values: [2]f64
twice: (x: f64) -> (r: f64) =
    r = x * 2.0
end twice
start: () -> none =
    values[1] = twice(values[0])
end start
"""


def mixed_objects(run, soft, refine):
    """D780: refine's object without a unit, built under SOFT, declares the
    float attributes GCC's soft-float object at the Cortex-M7 declares, and
    it and a hard-float GCC object refuse each other in either order, as
    RUN's hard-float refine object and the soft-float GCC object do.  Each
    pair is linked alone and relocatably, so no other object, libgcc's
    among them, takes part; the soft pair links, so the link is sound."""
    soft.out.mkdir()
    build(soft, refine, SOFT_FLOAT, level='armv7e-m')
    gcc, out = run.arm / 'arm-eabi-gcc', run.out
    (out / 'hard.c').write_text('double twice(double x) { return x * 2.0; }\n')
    run.command('hard-object', [gcc, '-mcpu=cortex-m7', '-mthumb', '-mfloat-abi=hard',
                                '-mfpu=fpv5-d16', '-fno-short-enums', '-O1', '-c', 'hard.c',
                                '-o', 'hard.o'])
    refine_soft, refine_hard = soft.out / 'firmware.elf.o', out / 'firmware.elf.o'

    def floats(name, path):
        said = run.command(name, [run.arm / 'arm-eabi-readelf', '-A', path])
        return [line.strip() for line in said.splitlines()
                if 'Tag_ABI_FP_number_model' in line or 'Tag_ABI_VFP_args' in line]
    declared = floats('soft-attributes', refine_soft)
    require(declared == floats('gcc-soft-attributes', out / 'soft.o')
            == ['Tag_ABI_FP_number_model: IEEE 754'],
            'refine\'s soft-float object declares %s, not what GCC\'s does' % declared)
    pairs = [('soft-with-hard', refine_soft, out / 'hard.o'),
             ('hard-with-soft', out / 'hard.o', refine_soft),
             ('refine-hard-with-soft', refine_hard, out / 'soft.o'),
             ('soft-with-refine-hard', out / 'soft.o', refine_hard)]
    for name, first, second in pairs + [('soft-with-soft', refine_soft, out / 'soft.o')]:
        argv = [gcc, '-nostdlib', '-r', first, second, '-o', name + '.o']
        if name == 'soft-with-soft':
            run.command(name, argv)
            continue
        try:
            run.command(name, argv)
        except RuntimeError:
            log = (out / (name + '.log')).read_text()
            require('uses VFP register arguments' in log
                    and 'failed to merge target specific data' in log,
                    'the %s link failed for another reason; inspect %s'
                    % (name, out / (name + '.log')))
        else:
            raise RuntimeError('a soft-float and a hard-float object linked: %s' % name)


def cpu_levels(parent, refine):
    """Link the scoped CPU module through compiler-owned startup at each level."""
    root = Path(__file__).resolve().parents[2]
    program = """import platform/cortex_m
mut observed: u32 = 0
start: () -> none =
    saved := cortex_m.disable_interrupts()
    observed = cortex_m.interrupt_mask()
    cortex_m.compiler_barrier()
    cortex_m.device_barrier()
    cortex_m.completion_barrier()
    cortex_m.restore_interrupts(saved)
end start
"""
    inputs = {str(p.relative_to(root)): sha(p)
              for p in sorted((root / 'platform/cortex_m').glob('*.ldn'))}
    controls = []
    for level in ('armv6-m', 'armv7-m', 'armv7e-m', 'armv8-m.main'):
        out = parent.out / level
        out.mkdir()
        run = Run(out, parent.tools)
        build(run, refine, program, level=level, root=root)
        (out / 'inputs.json').write_text(json.dumps(inputs, indent=2)+'\n')
        controls.append({'kind': 'cpu-level', 'level': level, 'optimize': 'none',
                         'specialize': 'off', 'status': 'passed',
                         'lane': 'compile-link'})
    return controls


def interrupts(run, elf):
    execute(run, elf, [
        'break *start', 'continue', 'delete breakpoints',
        'python',
        'gdb.selected_inferior().write_memory(0x20003000, bytes([0xa5])*4096)',
        'end',
        'set $r8=0x88888888', 'set $r9=0x99999999',
        'set $r10=0xaaaaaaaa', 'set $r12=0xcccccccc',
        'break *svc_handler', 'continue', 'delete breakpoints', 'python',
        'assert v("$lr") == 0xfffffff9',
        'assert v("$xpsr") & 511 == 11',
        'assert v("*(unsigned*)44") == v("&svc_handler") | 1',
        'assert v("*(unsigned*)64") == v("&irq_handler") | 1',
        'assert v("$sp") % 8 == 0',
        'outersp = v("$sp")',
        'outer = [v("*(unsigned*)($sp+%d)" % (i*4)) for i in range(8)]',
        'callee = [v("$r%d" % i) for i in range(4,12)]',
        'assert outer[:5] == [17,34,51,68,0xcccccccc]',
        'assert outer[7] & 0xf00001ff == 0x60000000',
        'assert callee[:4] == [85,102,119,136]',
        'assert callee[4:7] == [0x88888888,0x99999999,0xaaaaaaaa]',
        'end', 'break *irq_handler', 'continue', 'delete breakpoints', 'python',
        'assert v("$lr") == 0xfffffff1',
        'assert v("$xpsr") & 511 == 16',
        'assert v("$sp") % 8 == 0 and v("$sp") >= 0x20003000',
        'assert v("*(unsigned*)($r11+4)") == 0xfffffff9',
        'inner = [v("*(unsigned*)($sp+%d)" % (i*4)) for i in range(8)]',
        'inner_callee = [v("$r%d" % i) for i in range(4,12)]',
        'assert inner[7] & 511 == 11',
        'gdb.execute("break *%d" % inner[6])', 'end',
        'continue', 'delete breakpoints', 'python',
        'assert [v("$r%d" % i) for i in (0,1,2,3,12)] == inner[:5]',
        'assert [v("$r%d" % i) for i in range(4,12)] == inner_callee',
        'assert v("$lr") == inner[5]',
        'assert v("$xpsr") & 0xf00001ff == inner[7] & 0xf00001ff',
        'gdb.execute("break *%d" % outer[6])', 'end',
        'continue', 'delete breakpoints', 'python',
        'assert [v("$r%d" % i) for i in (0,1,2,3,12)] == outer[:5]',
        'assert [v("$r%d" % i) for i in range(4,12)] == callee',
        'assert v("$lr") == outer[5] and v("$sp") == outersp+32',
        'assert v("$xpsr") & 0xf00001ff == outer[7] & 0xf00001ff',
        'end', 'break _landin_firmware_returned', 'continue', 'python',
        'assert v("*(unsigned*)&completed") == 4',
        'assert v("*(unsigned*)&seen") == 2',
        'assert v("*(unsigned*)&nested") == 1',
        'assert v("*(unsigned*)&helper_calls") == 1',
        'assert v("&retained") < 0x8000 and v("&retained") % 64 == 0',
        'assert v("&initialized") % 16 == 0 and v("&seen") % 32 == 0',
        'assert v("*(unsigned*)&handler_ref") == v("&address_only") | 1',
        'assert v("*(unsigned*)*(unsigned*)&message") == 0x746f6f62',
        'assert v("*(unsigned*)&shared_zero") == 0',
        'assert v("*(unsigned*)&shared_value") == 321',
        'assert v("&zero_array") < 0x8000 and v("&zero_array") % 32 == 0',
        'assert v("&zero_record") < 0x8000 and v("&zero_record") % 16 == 0',
        'assert bytes(gdb.selected_inferior().read_memory(v("&zero_array"),16)) == bytes(16)',
        'assert v("*(unsigned*)&zero_record") == 0',
        'assert v("$sp") == 0x20004000 and v("$r11") == 0',
        'assert v("$r9") == 0x99999999 and v("$r12") == 0',
        'stack = bytes(gdb.selected_inferior().read_memory(0x20003000, 4096))',
        'assert stack[:64] == bytes([0xa5])*64',
        'first = next(i for i, b in enumerate(stack) if b != 0xa5)',
        'print("R660_OBSERVED_STACK_BYTES %d" % (4096-first))',
        'print("R660_INTERRUPT_PASS")', 'end',
    ], 'R660_INTERRUPT_PASS')


def fibre(run, refine, optimize, specialize):
    """D447/D460: an interrupt taken while a prepared stack runs.

    The fibre runs on PSP.  Exception entry stacks the interrupted
    context's eight words on PSP, the fibre's own stack, and the handler
    then runs on MSP: at its first instruction MSP is exactly what start
    left when it switched away, so nothing of the exception reached the
    main stack, and its own frames and a nested call go below that, while
    the fibre's backing below the hardware frame stays painted.  The
    return resumes the fibre on PSP with every stacked register, and the
    fibre switches back to start on MSP.  The same program built with
    line information is then stepped through both switches, an instruction
    at a time: GDB's walk names the leaving context's frames until CONTROL
    selects the resumed stack, and the resumed one's after it, and a
    prepared stack's walk ends at its start routine.
    """
    program = (Path(__file__).parent / 'probes/firmware-fibre.ldn').read_text()
    elf = build(run, refine, program, optimize, specialize)
    execute(run, elf, [
        'break *start', 'continue', 'delete breakpoints', 'python',
        'base = v("&backing")',
        'gdb.selected_inferior().write_memory(base, bytes([0xa5])*1024)',
        'gdb.selected_inferior().write_memory(0x20003000, bytes([0xa5])*(v("$sp")-0x20003000))',
        'assert v("$control") & 2 == 0 and v("$sp") == v("$msp") == 0x20004000',
        'end',
        'break *irq_handler', 'continue', 'delete breakpoints', 'python',
        'assert v("$lr") == 0xfffffffd, "the exception did not interrupt a PSP thread"',
        'assert v("$xpsr") & 511 == 16',
        'saved = v("*(unsigned*)&main_saved")',
        'psp = v("$psp")',
        'assert v("$msp") == v("$sp") == saved, "the exception wrote to the main stack"',
        'assert base <= psp and psp + 32 <= base + 1024 and psp % 8 == 0',
        'frame = [v("*(unsigned*)(%d)" % (psp + 4*i)) for i in range(8)]',
        'assert frame[7] & 511 == 0, "the stacked context was not thread mode"',
        'assert gdb.execute("info symbol %d" % frame[6], to_string=True).startswith("fibre")',
        'resume = psp + 32 + (4 if frame[7] & 0x200 else 0)',
        'paint = bytes([0xa5])*(psp-base)',
        'assert bytes(gdb.selected_inferior().read_memory(base, psp-base)) == paint',
        'end',
        'break *deeper', 'continue', 'delete breakpoints', 'python',
        'assert v("$xpsr") & 511 == 16',
        'assert v("$sp") < saved and v("$sp") >= 0x20003000, "a handler frame left the main stack"',
        'assert v("$psp") == psp',
        'assert bytes(gdb.selected_inferior().read_memory(base, psp-base)) == paint, '
        '"a handler frame reached the fibre stack"',
        'gdb.execute("break *%d" % frame[6])', 'end',
        'continue', 'delete breakpoints', 'python',
        'assert v("$xpsr") & 511 == 0 and v("$control") & 2 == 2',
        'assert v("$sp") == v("$psp") == resume',
        'assert [v("$r%d" % i) for i in (0,1,2,3,12)] == frame[:5]',
        'assert v("$lr") == frame[5]',
        'assert v("*(unsigned*)&handled") == 11',
        'end', 'break _landin_firmware_returned', 'continue', 'python',
        'assert v("*(unsigned*)&finished") == 1111',
        'assert v("*(unsigned*)&observed") == 111',
        'assert v("$control") & 2 == 0',
        'assert v("$sp") == v("$msp") == 0x20004000 and v("$r11") == 0',
        'stack = bytes(gdb.selected_inferior().read_memory(0x20003000, 4096))',
        'fibre_stack = bytes(gdb.selected_inferior().read_memory(base, 1024))',
        'main_first = next(i for i, b in enumerate(stack) if b != 0xa5)',
        'fibre_first = next(i for i, b in enumerate(fibre_stack) if b != 0xa5)',
        'assert 0x20003000 + main_first < saved',
        'print("R1420_OBSERVED_STACK_BYTES main %d fibre %d" % (4096-main_first, 1024-fibre_first))',
        'print("R1420_FIBRE_INTERRUPT_PASS")', 'end',
    ], 'R1420_FIBRE_INTERRUPT_PASS')
    unwind = run.out / 'unwind'
    unwind.mkdir()
    run = Run(unwind, run.tools)
    elf = build(run, refine, program, optimize, specialize, debug='lines')
    execute(run, elf, [
        'python',
        'def names():',
        '    f, found = gdb.newest_frame(), []',
        '    while f is not None and len(found) < 8:',
        '        found.append(f.name() or hex(f.pc())); f = f.older()',
        '    return found',
        'switch = v("&\'landin.stack_switch\'")',
        'gdb.execute("break *%d" % switch)',
        'def across(before, after):',
        '    gdb.execute("continue")',
        '    phases = set()',
        '    for step in range(40):',
        '        found = names()',
        '        if found[0] != "landin.stack_switch": break',
        '        above = after if v("$control") & 2 == want else before',
        '        assert found[1:] == above, (hex(v("$pc")), found, above)',
        '        phases.add(above is after)',
        '        gdb.execute("stepi", to_string=True)',
        '    assert phases == {False, True}, phases',
        '    return names()',
        'want = 2',
        'assert across(["start", "_landin_firmware_reset"], ["landin.stack_start"]) == ["landin.stack_start"]',
        'gdb.execute("delete breakpoints")',
        'gdb.execute("break *%d" % v("&fibre"))', 'gdb.execute("continue")',
        'assert names() == ["fibre", "landin.stack_start"], names()',
        'gdb.execute("delete breakpoints")',
        'gdb.execute("break *%d" % switch)',
        'want = 0',
        'assert across(["fibre", "landin.stack_start"], ["start", "_landin_firmware_reset"]) == ["start", "_landin_firmware_reset"]',
        'print("R1420_FIBRE_UNWIND_PASS")', 'end',
    ], 'R1420_FIBRE_UNWIND_PASS')


def dma(run, refine, optimize="none", specialize="off"):
    here = Path(__file__).resolve().parent
    source = here / 'probes/firmware-dma.ldn'
    elf = build(run, refine, source.read_text(), optimize, specialize)
    dma_execute(run, elf)


def dma_execute(run, elf):
    text = run.command('dma-symbols', [run.arm / 'arm-eabi-nm', elf])
    symbols = {parts[2]: int(parts[0],16) for line in text.splitlines()
               if len(parts := line.split()) == 3}
    stage = symbols['stage']
    model = PrototypePeripheral()
    with Machine(run, elf, 'dma', poll=[stage]) as m:
        m.map(0x40020000, 0x7000, model)
        m.trap(symbols['_landin_firmware_unhandled'], 'unhandled exception')
        u32 = m.u32
        m.until(lambda: u32(stage) == 1)
        require(model.configuration == 0x80000407 and model.remaining == 4, 'ready: descriptor')
        require(model.transfers == 0 and model.errors == 0, 'ready: transfers')
        require(model.count_half_writes == 1 and model.count_word_writes == 0, 'ready: count width')
        model.feed(42)
        model.feed(43)
        m.settle()
        require(u32(symbols['notifications']) == 1, 'half: notifications')
        require(u32(symbols['completed']) == 0 and u32(symbols['result']) == 0, 'half: state')
        require(model.transfers == 2 and model.remaining == 2, 'half: model')
        m.write_u32(stage, 2)
        m.until(lambda: u32(stage) == 3)
        model.feed(44)
        model.feed(45)
        m.settle()
        require(u32(symbols['notifications']) == 1, 'masked: delivered while masked')
        require(u32(symbols['completed']) == 0, 'masked: completed while masked')
        require(model.transfers == 4 and model.remaining == 0, 'masked: model')
        require(u32(symbols['buffer']) == 0x2d2c2b2a, 'masked: buffer')
        m.write_u32(stage, 4)
        m.until(lambda: u32(stage) == 5)
        m.settle()
        require(u32(symbols['result']) == 174, 'done: result')
        require(u32(symbols['notifications']) == 2 and u32(symbols['completed']) == 1,
                'done: notifications')
    require(model.transfers == 4 and model.errors == 0 and model.remaining == 0, 'done: model')
    require(model.configuration == 0x80000406, 'done: configuration')
    require(model.count_half_reads == 1 and model.count_word_reads == 0, 'done: count reads')
    require(model.count_half_writes == 1 and model.count_word_writes == 0, 'done: count writes')
    require(model.reads == 3 and model.writes == 7, 'done: access counts')
    (run.out / 'dma-trace.txt').write_text('notifications=2;half-read=1;half-write=1;'
        'status-read=2;clear-write=2;transfers=4;sum=174\n')


def machine(run, refine, optimize="none", specialize="off"):
    source = Path(__file__).parent / 'probes/firmware-machine.ldn'
    elf = build(run, refine, source.read_text(), optimize, specialize)
    execute(run, elf, [
        'break *start', 'continue', 'delete breakpoints', 'python',
        'assert v("$sp") == 0x20004000 and v("$r11") == 0',
        'assert v("*(unsigned*)&assembly_data") == 18', 'end',
        'break *worker', 'continue', 'delete breakpoints', 'python',
        'assert v("$sp") == 0x20003800 and v("$r11") == 0', 'end',
        'break *naked_handler', 'continue', 'delete breakpoints', 'python',
        'assert v("$lr") == 0xfffffffd',
        'assert v("$sp") == 0x20004000',
        'assert 0x20003000 <= v("$r11") < 0x20003800',
        'assert v("*(unsigned*)$r11") == 0',
        'assert v("*(unsigned*)&assembly_data") == 99', 'end',
        'break _landin_firmware_returned', 'continue', 'python',
        'assert v("$sp") == 0x20003800 and v("$r11") == 0',
        'assert v("$xpsr") & 511 == 0',
        'assert v("*(unsigned*)&observed") == 124',
        'assert v("*(unsigned*)&naked_hits") == 1',
        'assert v("$r9") == 0 and v("$r12") == 0',
        'print("R660_NAKED_PSP_ASSEMBLY_PASS")', 'end',
    ], 'R660_NAKED_PSP_ASSEMBLY_PASS')


def veneers(run, refine, optimize="none", specialize="off"):
    source = Path(__file__).parent / 'probes/firmware-veneer.ldn'
    elf = build(run, refine, source.read_text(), optimize, specialize)
    disassembly = (run.out / 'disassembly.log').read_text()
    require('__ram_worker_veneer' in disassembly,
            'flash-to-RAM transfer did not exercise a linker veneer')
    require('__flash_helper_veneer' in disassembly,
            'RAM-to-flash transfer did not exercise a linker veneer')
    require('__aeabi_uldivmod' in disassembly,
            'firmware helper closure was not exercised')
    execute(run, elf, [
        'python',
        'low=v("&_landin_firmware_ramtext_start")',
        'high=v("&_landin_firmware_ramtext_end")',
        'assert high > low',
        'gdb.selected_inferior().write_memory(low, bytes([0xcc])*(high-low))',
        'end',
        'break *start', 'continue', 'delete breakpoints', 'python',
        'assert 0x20000000 <= v("&ram_worker") < 0x20003000',
        'assert 0x20000000 <= v("&ram_irq") < 0x20003000',
        'assert v("&flash_helper") < 0x8000',
        'assert v("*(unsigned*)44") == v("&ram_irq") | 1',
        'low=v("&_landin_firmware_ramtext_start")',
        'high=v("&_landin_firmware_ramtext_end")',
        'load=v("&_landin_firmware_ramtext_load")',
        'assert load < 0x8000 and low >= 0x20000000 and high > low',
        'mem=gdb.selected_inferior()',
        'assert mem.read_memory(low,high-low).tobytes() == mem.read_memory(load,high-low).tobytes()',
        'end', 'break _landin_firmware_returned', 'continue', 'python',
        'assert v("*(unsigned*)&observed") == 42',
        'assert v("*(unsigned*)&irq_seen") == 1',
        'assert v("$r12") == 0 and v("$r11") == 0',
        'assert v("$sp") == 0x20004000',
        'print("R660_FIRMWARE_VENEER_PASS")', 'end',
    ], 'R660_FIRMWARE_VENEER_PASS')


def fallthrough(run, refine, optimize, specialize):
    elf = build(run, refine, 'extern(naked) start: () -> none = '
                'assembler.block("nop") end start\n', optimize, specialize)
    execute(run, elf, [
        'break _landin_firmware_unhandled', 'continue', 'python',
        'assert v("$xpsr") & 511 == 3',
        'assert v("$sp") == 0x20003fe0 and v("$r11") == 0',
        'assert v("*(unsigned short*)*(unsigned*)($sp+24)") == 0xde01',
        'assert v("*(unsigned*)($sp+24)") == (v("&start") & ~1)+2',
        'print("R660_NAKED_FALLTHROUGH_PASS")', 'end',
    ], 'R660_NAKED_FALLTHROUGH_PASS')


def independent(run):
    here = Path(__file__).resolve().parent / 'probes'
    elf = run.out / 'control.elf'
    run.command('independent-build', [run.arm / 'arm-eabi-gcc',
        '-mcpu=cortex-m0', '-mthumb', '-mfloat-abi=soft', '-mabi=aapcs',
        '-Os', '-Wall', '-Wextra', '-Werror', '-ffreestanding', '-fno-short-enums',
        '-fno-builtin', '-ffunction-sections', '-fdata-sections',
        '-nostdlib', '-nostartfiles', '-nodefaultlibs',
        here / 'firmware-control.S', here / 'firmware-control.c',
        '-Wl,--gc-sections,--build-id=none,-T,' + str(here / 'firmware-control.ld'),
        '-Wl,-Map,control.map', '-o', elf])
    run.command('independent-elf', [run.arm / 'arm-eabi-readelf', '-h','-A','-S','-l','-r', elf])
    run.command('independent-disassembly', [run.arm / 'arm-eabi-objdump', '-dr', elf])
    execute(run, elf, [
        'set *(unsigned*)&control_initial = 0xaaaaaaaa',
        'set *(unsigned*)&control_calls = 0xbbbbbbbb',
        'break *control_svc', 'continue', 'delete breakpoints', 'python',
        'assert v("$lr") == 0xfffffffd and v("$sp") == 0x20004000',
        'assert v("*(unsigned*)&control_initial") == 18',
        'assert v("*(unsigned*)&control_calls") == 0',
        'assert v("*(unsigned*)0x200037f4") & 0x200',
        'assert v("*(unsigned*)0x200037f4") & 0xf00001ff == 0x60000000',
        'end', 'break *control_irq', 'continue', 'delete breakpoints', 'python',
        'assert v("$lr") == 0xfffffff1 and v("$sp") == 0x20003fd8',
        'assert v("*(unsigned*)($sp+28)") & 511 == 11',
        'assert v("*(unsigned*)&control_initial") == 25',
        'end', 'break control_done', 'continue', 'python',
        'assert v("$sp") == 0x200037fc and v("$xpsr") & 511 == 0',
        'assert v("$xpsr") & 0xf0000000 == 0x60000000',
        'assert [v("$r%d" % i) for i in range(8)] == [17,34,51,68,85,102,119,136]',
        'assert v("*(unsigned*)&control_initial") == 32',
        'assert v("*(unsigned*)&control_calls") == 2',
        'print("R660_INDEPENDENT_FRAME_PASS")', 'end',
    ], 'R660_INDEPENDENT_FRAME_PASS')


def failures(parent, refine):
    cases = [
        #  Within D537's budget but past the map once the vectors and the
        #  reset code are added: the linker remains the map's authority.
        ('flash-overflow', 'link(keep) image: [32700]u8 = [of 1]', 'L0501', 'FLASH'),
        ('stack-overlap', 'link(keep) mut image: [12289]u8 = zeroed', 'L0501', 'reserved 4 KiB stack'),
        ('bounded-materialization', 'link(keep) image: [8388609]u8 = [of 1]', 'L0505',
         'past the 32768 bytes that the flash of'),
        ('flash-budget', 'image: [32769]u8 = [of 1]', 'L0505', 'constrained reference profile holds'),
        ('ram-budget', 'link(keep) mut image: [16385]u8 = [of 1]', 'L0505', '16384 bytes that the RAM of'),
        ('missing-symbol', 'link(keep) extern(naked) h: () -> none = assembler.block("bl missing_firmware_symbol") end h', 'L0501', 'missing_firmware_symbol'),
        ('unsupported-encoding', 'link(keep) h: () -> none = assembler.block("ldr r0, [r1, #4096]") end h', 'L0501', 'firmware assembly failed'),
        ('reserved-instruction', 'h: () -> none = assembler.block("ldrex r0, [r1]") end h', 'L0330',
         'is not an instruction of the armv6-m level'),
        ('misplaced-vector', 'link(section: ".isr_vector", keep) image: [48]u32 = zeroed', 'L0347', 'placement'),
        ('owned-reset-vector', 'link(vector: 1) extern(interrupt) h: () -> none = end h', 'L0347', 'placement'),
        ('invalid-entry', 'start: (value: u32) -> none = end start', 'L0502', 'firmware-entry'),
        ('reserved-symbol', 'link(symbol: "_landin_firmware_reset") value: u32 = 1', 'L0347', 'datum symbol'),
    ]
    for name, program, code, detail in cases:
        out = parent.out / name
        out.mkdir()
        run = Run(out, parent.tools)
        source = out / 'refused.ldn'
        source.write_text(program + ('\n' if name == 'invalid-entry' else
                          '\nstart: () -> none = end start\n'))
        try:
            run.command('refusal', [refine, '--target=cortex-m0',
                '--firmware-entry=start', '--emit=exe',
                '--toolchain='+str(run.arm / 'arm-eabi-gcc'),
                '-o', 'refused.elf', source.name], timeout=60)
        except RuntimeError:
            record = run.commands[-1]
            require(record.get('exit') == 1 and not record.get('timed_out'),
                    'refusal was not a bounded reported compiler failure: ' + name)
        else:
            raise RuntimeError('invalid firmware was accepted: ' + name)
        diagnostic = (out / 'refusal.log').read_text()
        require(code in diagnostic and detail in diagnostic,
                'unexpected firmware refusal: ' + name)
        require(not (out / 'refused.elf').exists(), 'refusal left a firmware ELF')


def peripheral(run, refine, kind, optimize, specialize):
    here = Path(__file__).resolve().parent
    source = here / ('probes/packed-cortex-hole.ldn' if kind == 'hole' else
                     'probes/backend-byte.ldn' if kind == 'byte' else
                     'probes/packed-cortex.ldn')
    program = source.read_text() + '''
link(symbol: "firmware_fault") mut firmware_fault: u32 = 0
mut firmware_result: u32 = 0
link(vector: 3) extern(naked) firmware_hardfault: () -> none =
    assembler.block("""
        mrs r0, ipsr
        ldr r1, =firmware_fault
        str r0, [r1]
        cpsid i
        1:
        wfi
        b 1b
        """)
end firmware_hardfault
link(vector: 11) extern(interrupt) firmware_svc: () -> none =
    firmware_result = main()
end firmware_svc
start: () -> none =
    assembler.block("svc #0")
    loop do assembler.block("wfi") end loop
end start
'''
    elf = build(run, refine, program, optimize, specialize)
    text = run.command('peripheral-symbols', [run.arm / 'arm-eabi-nm', elf])
    symbols = {parts[2]: int(parts[0],16) for line in text.splitlines()
               if len(parts := line.split()) == 3}
    trace = ('r32:4:0000009b' if kind == 'hole' else
             'r8:18:a5;r8:18:00;w8:19:41;w8:1a:02;r8:1a:f1' if kind == 'byte' else TRACE)
    model = EncodingPeripheral()
    with Machine(run, elf, 'device') as m:
        m.map(0x40030000, 0x20, model)
        m.settle()
        fault, result = m.u32(symbols['firmware_fault']), m.u32(symbols['firmware_result'])
    require(fault == (3 if kind == 'hole' else 0), 'firmware device fault status')
    require(result == (0 if kind == 'hole' else 42 if kind == 'byte' else 0x640),
            'firmware device result')
    require(model.trace == trace, 'firmware device trace differs: ' + model.trace)
    if kind == 'images':
        require(model.normal == 0xa50000d0 and model.command == 0x51 and model.pending == 0xf1
                and model.count == 0xffff and model.ones == 0xffffff51, 'firmware device images')
    elif kind == 'byte':
        require(model.byte_command == 0x41 and model.byte_pending == 0xf1, 'firmware byte images')
    (run.out / 'device-trace.txt').write_text(model.trace + '\n')


@contextlib.contextmanager
def case(name):
    """Name the firmware case a failure belongs to, ahead of the failure itself."""
    try:
        yield
    except RuntimeError as error:
        raise RuntimeError('compiler firmware ' + name + ': ' + str(error)) from error


#  The lane's cases, in the order it runs them: eight once, the rest at
#  each profile.  `boot` is the cold-booted image built twice.
ONCE = ('cpu-levels', 'refusals', 'independent-c-assembly', 'compact-images', 'float-unit',
        'float-debug', 'cache-sequence', 'example')
KINDS = ('interrupts', 'fibre', 'dma', 'machine', 'veneers', 'fallthrough', 'images',
         'hole', 'byte')
CASES = ONCE + ('boot',) + KINDS


def execute_suite(parent, refine, profiles=PROFILES, cases=None):
    """Every case, or CASES, at PROFILES; a selection is FILTERED."""
    unknown = sorted(set(cases or ()) - set(CASES))
    require(not unknown, 'unknown firmware case %s; the cases are %s'
            % (', '.join(unknown), ', '.join(CASES)))
    chosen = set(cases or CASES)
    root = parent.out / 'firmware'
    root.mkdir()
    refine = refine.resolve(strict=True)
    compiler_hash = sha(refine)
    parent.command('firmware-refine-identity', [refine, '--identify'])
    helper = parent.command('firmware-runtime-archive', [
        parent.arm / 'arm-eabi-gcc', '-mcpu=cortex-m0', '-mthumb',
        '-mfloat-abi=soft', '-print-libgcc-file-name']).strip()
    require(helper.endswith('/thumb/v6-m/nofp/libgcc.a'),
            'firmware selected the wrong runtime archive')
    controls = []
    if 'cpu-levels' in chosen:
        out = root / 'cpu-levels'
        out.mkdir()
        with case('cpu-levels'):
            controls += cpu_levels(Run(out, parent.tools), refine)
    if 'float-unit' in chosen:
        out = root / 'float-unit'
        out.mkdir()
        with case('float-unit'):
            controls += float_unit(Run(out, parent.tools), refine)
    if 'float-debug' in chosen:
        out = root / 'float-debug'
        out.mkdir()
        with case('float-debug'):
            controls += float_debug(Run(out, parent.tools), refine)
    if 'cache-sequence' in chosen:
        out = root / 'cache-sequence'
        out.mkdir()
        with case('cache-sequence'):
            controls += cache_sequence(Run(out, parent.tools), refine)
    if 'example' in chosen:
        out = root / 'example'
        out.mkdir()
        with case('example'):
            controls += example(Run(out, parent.tools), refine)
    if 'refusals' in chosen:
        out = root / 'refusals'
        out.mkdir()
        with case('refusals'):
            failures(Run(out, parent.tools), refine)
    if 'independent-c-assembly' in chosen:
        out = root / 'independent-c-assembly'
        out.mkdir()
        with case('independent-c-assembly'):
            independent(Run(out, parent.tools))
    if 'compact-images' in chosen:
        out = root / 'compact-images'
        out.mkdir()
        with case('compact-images'):
            #  D536/D537 with this lane's assembler: compact sources cost the
            #  assembly and the assembler the source's size, and the giant
            #  firmware image is refused before any tool runs.
            Run(out, parent.tools).command('image-bounds', [
                sys.executable, Path(__file__).resolve().parents[2] / 'scripts/image_bounds.py',
                '--refine=' + str(refine), '--target=cortex-m0',
                '--toolchain=' + str(parent.arm / 'arm-eabi-gcc')], timeout=900)
    for optimize, specialize in profiles if chosen - set(ONCE) else ():
        profile = root / (optimize + '-' + specialize)
        profile.mkdir()
        if 'boot' in chosen:
            images = []
            for name in ('first', 'fresh'):
                out = profile / name
                out.mkdir()
                run = Run(out, parent.tools)
                with case('%s at %s/%s' % (name, optimize, specialize)):
                    elf = build(run, refine, optimize=optimize, specialize=specialize)
                    execute(run, elf)
                images.append(out)
            for suffix in ('', '.o', '.s', '.ld', '.map'):
                require((images[0] / ('firmware.elf' + suffix)).read_bytes() ==
                        (images[1] / ('firmware.elf' + suffix)).read_bytes(),
                        'fresh firmware artifact differs: ' + suffix)
        for kind in (kind for kind in KINDS if kind in chosen):
            out = profile / kind
            out.mkdir()
            run = Run(out, parent.tools)
            with case('%s at %s/%s' % (kind, optimize, specialize)):
                if kind == 'interrupts':
                    program = (Path(__file__).parent / 'probes/firmware-irq.ldn').read_text()
                    elf = build(run, refine, program, optimize, specialize)
                    symbols = (out / 'symbols.log').read_text().splitlines()
                    present = {parts[-1] for line in symbols if (parts := line.split())}
                    require('discarded' not in present and 'discarded_handler' not in present,
                            'unreferenced sections survived garbage collection')
                    require({'retained','svc_handler','irq_handler'} <= present,
                            'retained/vector-referenced sections disappeared')
                    interrupts(run, elf)
                elif kind == 'fibre':
                    fibre(run, refine, optimize, specialize)
                elif kind == 'dma':
                    dma(run, refine, optimize, specialize)
                elif kind == 'machine':
                    machine(run, refine, optimize, specialize)
                elif kind == 'fallthrough':
                    fallthrough(run, refine, optimize, specialize)
                elif kind == 'veneers':
                    veneers(run, refine, optimize, specialize)
                else:
                    peripheral(run, refine, kind, optimize, specialize)
                fresh = out / 'fresh'
                fresh.mkdir()
                build(Run(fresh, parent.tools), refine,
                      (out / 'boot.ldn').read_text(), optimize, specialize)
                for suffix in ('', '.o', '.s', '.ld', '.map'):
                    require((out / ('firmware.elf' + suffix)).read_bytes() ==
                            (fresh / ('firmware.elf' + suffix)).read_bytes(),
                            'fresh ' + kind + ' artifact differs: ' + suffix)
            controls.append({'kind': kind, 'optimize': optimize,
                             'specialize': specialize, 'status': 'passed'})
        if 'boot' in chosen:
            controls.append({'kind': 'cold-boot-reset-fresh', 'optimize': optimize,
                             'specialize': specialize, 'status': 'passed'})
        print('compiler firmware: ' + profile.name + ' passed', flush=True)
    require(sha(refine) == compiler_hash, 'compiler changed during firmware execution')
    record = {'status': 'passed', 'compiler_sha256': compiler_hash,
              'scope': 'every case' if cases is None else 'FILTERED: ' + ', '.join(
                  one for one in CASES if one in chosen),
              'runtime_archive': helper, 'runtime_archive_sha256': sha(Path(helper)),
              'controls': controls,
              'artifacts': {str(p.relative_to(root)): sha(p)
                            for p in sorted(root.rglob('*')) if p.is_file()}}
    (root / 'result.json').write_text(json.dumps(record, indent=2)+'\n')
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=DEFAULT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--all-profiles', action='store_true')
    parser.add_argument('--case', action='append', choices=CASES,
                        help='run only this case; repeat for more.  The eight run once,'
                             ' the rest at each profile; a selection is FILTERED')
    args = parser.parse_args()
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
    import refine_revision
    refine_revision.warn(args.refine)  # is it this checkout's?
    supported_host(args.output)
    args.tools = installed_tools(args.tools)
    before = inventory(args.tools)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    record = {'status': 'failed', 'tools': before,
              'scope': 'development compiler-owned firmware; not acceptance'}
    try:
        record['firmware'] = execute_suite(Run(args.output, args.tools.resolve()),
            args.refine, PROFILES if args.all_profiles else PROFILES[:1], args.case)
        require(inventory(args.tools) == before, 'embedded tool inventory changed')
        record['status'] = 'passed'
    finally:
        record['files'] = {str(p.relative_to(args.output)): sha(p)
                          for p in sorted(args.output.rglob('*')) if p.is_file()}
        (args.output / 'result.json').write_text(json.dumps(record, indent=2)+'\n')
    print('DEVELOPMENT / NOT ACCEPTANCE: compiler firmware controls passed'
          + ('' if not args.case else ' (FILTERED: the cases %s only)' % ', '.join(args.case)))


if __name__ == '__main__':
    main()
