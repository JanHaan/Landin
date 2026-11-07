"""Independent Cortex-M0 layout measurements and hand-written calling witnesses.

The VFP profile (D616) is measured the same way on QEMU's mps2-an500: GCC
at -mfloat-abi=hard -mfpu=fpv5-d16 calls hand-written endpoints that record
where each argument arrived, and saves exactly the registers the convention
makes it preserve.
"""
import json
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
CONTRACT = ROOT / 'compiler/tests/cortex-m.contract'
GOLDEN = ROOT / 'compiler/tests/layout.targets'
LAYOUT_KEYS = ('u8 u16 u32 u64 i8 i16 i32 i64 usize isize f32 f64 bool '
               'a b c d variant payload wrapped child nested multiple evidence0 evidence any').split()
CALL_COUNTS = dict(gap=3, split=5, stack=7, sret=3, small=3, varargs=4, floatpair=3, native=4, multi=1)
#  D616's VFP profile rows, `vfp.NAME`, each with the first single slot of
#  s0-s15 (16 for none) and the count of single slots after the base five.
VFP_COUNTS = dict(mixed=5, hfa=3, spill=11, varargs=3, large=2, native=4)
#  What GCC compiles the VFP control with, and the multilib that selects.
HARD_FLAGS = ['-mcpu=cortex-m7', '-mthumb', '-mfloat-abi=hard', '-mfpu=fpv5-d16', '-mabi=aapcs',
              '-ffreestanding', '-fno-builtin', '-fno-omit-frame-pointer', '-g3', '-O1',
              '-Wall', '-Wextra', '-Werror', '-nostdlib']


def contract(text):
    rows = {}
    for line in text.splitlines():
        key, *values = line.split()
        if key in rows or not values:
            raise ValueError('duplicate or empty contract row')
        rows[key] = [int(v) for v in values]
    required = set(LAYOUT_KEYS)
    for name, count in CALL_COUNTS.items():
        required.add(name + '.result')
        required.update(name + '.arg' + str(i) for i in range(1, count + 1))
    for name, count in VFP_COUNTS.items():
        required.add('vfp.' + name + '.result')
        required.update('vfp.' + name + '.arg' + str(i) for i in range(1, count + 1))
    required.add('vfp.preserved')
    if set(rows) != required or any(v < 0 for row in rows.values() for v in row):
        raise ValueError('incomplete or invalid ABI contract')
    for name, count in VFP_COUNTS.items():
        for key in ['vfp.%s.result' % name] + ['vfp.%s.arg%d' % (name, i)
                                               for i in range(1, count + 1)]:
            row = rows[key]
            if len(row) != 7 or row[5] + row[6] > 16 or (row[6] and row[5] == 16):
                raise ValueError('invalid VFP contract row ' + key)
    if rows['vfp.preserved'] != [16, 31]:
        raise ValueError('the VFP call-preserved registers are s16-s31')
    for name, count in CALL_COUNTS.items():
        if len(rows[name + '.result']) != 5:
            raise ValueError('invalid result contract')
        for i in range(1, count + 1):
            row = rows[name + '.arg' + str(i)]
            if len(row) != 5 or row[0] + row[1] > 4 or row[2] % 4 or row[3] % 4:
                raise ValueError('invalid argument contract')
    return rows


def synthetic_agreement(rows, text):
    """Compare every pre-existing synthetic scalar/aggregate/variant/table row."""
    small = text.split('target synthetic-32\n', 1)[1].split('\ntarget ', 1)[0]
    lines = [line.split() for line in small.splitlines()]
    for key in LAYOUT_KEYS[:13]:
        values = next(line for line in lines if line and line[0] == key and len(line) == 4)
        if rows[key] != list(map(int, values[2:])):
            raise ValueError('synthetic scalar mismatch: ' + key)
    expected = {
        'u8 u32 u8': rows['a'][2:] + rows['a'][:2],
        'u8 u8 u32': rows['b'][2:] + rows['b'][:2],
        'u8 usize': rows['c'][2:] + rows['c'][:2],
        'u64 u8': rows['d'][2:] + rows['d'][:2],
        'u8 | usize u8 | [3]u16': [0, rows['payload'][0]] + rows['variant'][:2],
        'u8 variant u16': rows['wrapped'][2:] + rows['wrapped'][:2],
        'u16 {u8 usize [3]u16} u8': [rows['nested'][3]] + rows['nested'][:2],
    }
    for label, wanted in expected.items():
        tokens = label.split()
        found = [line[len(tokens):] for line in lines if line[:len(tokens)] == tokens]
        if len(found) != 1 or list(map(int, found[0])) != wanted:
            raise ValueError('synthetic aggregate mismatch: ' + label)
    empty = next(line for line in lines if '-' in line)
    if empty != ['0', '0', '4', '-', *map(str, rows['evidence0'])]:
        raise ValueError('synthetic empty evidence mismatch')
    evidence = rows['evidence']
    if next(line for line in lines if line and line[0] == '2') != list(map(str,
            [2, *evidence[2:5], *evidence[:2]])):
        raise ValueError('synthetic evidence mismatch')
    if lines[-1] != list(map(str, rows['any'][2:] + rows['any'][:2])):
        raise ValueError('synthetic any mismatch')


def execute(run):
    # Use the existing timeout/session owner and tool inventory. The original CPU
    # and peripheral lanes still run independently before this additional lane.
    from run import require, oracle, stop
    rows = contract(CONTRACT.read_text())
    synthetic_agreement(rows, GOLDEN.read_text())
    shutil.copyfile(CONTRACT, run.out / 'cortex-m.contract')
    shutil.copyfile(GOLDEN, run.out / 'layout.targets')
    run.build('abi', extra=[HERE / 'probes/abi.S'])
    run.command('disassemble-abi', [run.arm / 'arm-eabi-objdump', '-d', 'abi.elf'])
    run.command('macros-abi', [run.arm / 'arm-eabi-gcc', '-mcpu=cortex-m0',
                '-mthumb', '-mfloat-abi=soft', '-mabi=aapcs', '-dM', '-E', '-x', 'c', '/dev/null'])
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    # Words supplied by the independently compiled C caller. Unspecified
    # padding and skipped registers are never compared as meaningful data.
    arguments = {
        'gap': [[0x11111111], [0x44332211, 0x88776655], [0x22222222]],
        'split': [[1], [2], [3], [0x44332211, 0x88776655, 0xccbbaa99], [4]],
        'stack': [[1], [2], [3], [4], [0xfffffff9], [0, 0x3ff80000], [0xabcd]],
        'sret': [[0x11111111], [0x44332211, 0x88776655], [0x22222222]],
        'small': [[0xfffffff9], [0xabcd], [0x3fc00000]],
        'varargs': [[1], [0xfffffff9], [0, 0x3ff80000], [9]],
        'floatpair': [[1], [0x3fc00000, 0x40200000], [2]],
    }
    python = [
        'import gdb, json',
        'def v(expr): return int(gdb.parse_and_eval(expr))',
        'assert v("$sp") % 8 == 0',
        'assert v("*(unsigned*)$r11") == 0',
        'assert v("*(unsigned*)($r11+4)") == v("$lr")',
        'assert v("$r11") == v("$sp") + 8',
        'assert v("*(unsigned*)$r1") == 8',
        'assert v("*(unsigned*)($r2+4)") == 4',
    ]
    gdb = [f'target remote 127.0.0.1:{port}', 'set pagination off', 'set confirm off',
           'break native_frame_ready', 'continue', 'python', *python, 'end',
           'delete breakpoints', 'break parent_frame_ready', 'continue', 'python',
           'assert v("$sp") % 8 == 0',
           'assert v("$r11") == v("$sp")',
           'assert v("*(unsigned*)$r11") == v("$sp") + 16',
           'assert v("*(unsigned*)($r11+4)") == v("$lr")',
           'assert v("**(unsigned**)$r11") == 0', 'end',
           'delete breakpoints', 'break done', 'continue', 'python',
           'assert v("result") == 0x620', 'assert v("asm_result") == 0x620',
           'assert v("native_result") == 0x620', 'assert v("thumb_address") & 1',
           'measurements = {}']
    for key in LAYOUT_KEYS:
        gdb += [f'measurements[{key!r}] = [v("layout_{key}[" + str(i) + "]") for i in range({len(rows[key])})]',
                f'assert measurements[{key!r}] == {rows[key]!r}, {key!r}']
    for index, (name, args) in enumerate(arguments.items()):
        gdb += [f'assert v("capture[{index}][10]") % 8 == 0']
        for arg_index, words in enumerate(args, 1):
            first, count, stack_at, stack_bytes, indirect = rows[f'{name}.arg{arg_index}']
            require(not indirect and count + stack_bytes // 4 == len(words), 'inconsistent call extent')
            for word, wanted in enumerate(words):
                at = first + word if word < count else 4 + stack_at // 4 + word - count
                gdb += [f'assert v("capture[{index}][{at}]") == {wanted}, "{name} argument {arg_index} word {word}"']
    gdb += ['assert 0x20000000 <= v("capture[3][0]") < 0x20004000',
            'with open("abi-measurements.json", "w") as f: json.dump(measurements, f, sort_keys=True)',
            'print("R620_ABI_PASS")', 'end', 'quit']
    (run.out / 'abi.gdb').write_text('\n'.join(gdb) + '\n')
    argv = [str(run.bin / 'qemu-system-arm'), '-M', 'microbit', '-accel', 'tcg,thread=single',
            '-display', 'none', '-monitor', 'none', '-serial', 'null', '-kernel', 'abi.elf',
            '-S', '-gdb', f'tcp:127.0.0.1:{port}']
    record = {'name': 'qemu-abi', 'argv': argv, 'timeout_seconds': 25}
    run.commands.append(record)
    tick = time.monotonic()
    with (run.out / 'qemu-abi.log').open('wb') as log:
        p = subprocess.Popen(argv, cwd=run.out, env=run.env, stdout=log, stderr=log,
                             start_new_session=True)
        try:
            deadline = time.monotonic() + 3
            while True:
                require(p.poll() is None, 'ABI QEMU exited before debugger connection')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1):
                        break
                except OSError:
                    require(time.monotonic() < deadline, 'ABI debugger startup timed out')
                    time.sleep(.02)
            text = run.debug('gdb-abi', 'abi.elf', 'abi.gdb', timeout=20)
            oracle(text, 'R620_ABI_PASS')
        finally:
            stop(p)
            record.update(exit=p.returncode, seconds=time.monotonic()-tick,
                          stopped_by_supervisor=True)
            (run.out / 'commands.json').write_text(json.dumps(run.commands, indent=2)+'\n')
    execute_vfp(run)
    binding_layouts(run)
    require(CONTRACT.read_bytes() == (run.out / 'cortex-m.contract').read_bytes()
            and GOLDEN.read_bytes() == (run.out / 'layout.targets').read_bytes(),
            'ABI contracts changed during probes')


def words32(value):
    return [struct.unpack('<I', struct.pack('<f', value))[0]]


def words64(value):
    return list(struct.unpack('<II', struct.pack('<d', value)))


#  The words abi-vfp.c passes each endpoint, in its argument order, and
#  the endpoint's row of vfp_capture.  Unspecified padding and skipped
#  registers are never compared.
VFP_ARGUMENTS = {
    'mixed': (0, [words32(1.5), words64(2.5), words32(3.5), [0x11223344], words64(4.5)]),
    'hfa': (1, [words32(1.25) + words32(2.25) + words32(3.25), words64(6.5) + words64(7.5),
                words32(5.5)]),
    'spill': (2, [words32(1.0)] + [words64(float(n)) for n in range(2, 9)]
              + [words64(6.5) + words64(7.5), words32(14.0), [0x55667788]]),
    'varargs': (3, [words64(2.5), words64(3.5), [0x99aabbcc]]),
    'large': (4, [words32(9.0) + words32(10.0) + words32(11.0) + words32(12.0) + words32(13.0),
                  words32(15.0)]),
}


def vfp_checks(rows):
    """GDB assertions holding each recorded argument word where the row says."""
    from run import require
    lines = []
    for name, (index, args) in VFP_ARGUMENTS.items():
        lines.append(f'assert v("vfp_capture[{index}][26]") % 8 == 0, "{name} sp alignment"')
        for arg_index, words in enumerate(args, 1):
            first, count, stack_at, stack_bytes, _, vfp, singles = rows[
                'vfp.%s.arg%d' % (name, arg_index)]
            require(count + singles + stack_bytes // 4 == len(words),
                    'inconsistent VFP call extent: %s argument %d' % (name, arg_index))
            for word, wanted in enumerate(words):
                if singles:
                    at = 4 + vfp + word
                elif word < count:
                    at = first + word
                else:
                    at = 20 + stack_at // 4 + word - count
                lines.append(f'assert v("vfp_capture[{index}][{at}]") == {wanted}, '
                             f'"{name} argument {arg_index} word {word}"')
    return lines


def execute_vfp(run):
    """GCC's VFP variant against the contract's `vfp.` rows, on mps2-an500."""
    from run import require, oracle, stop
    rows = contract(CONTRACT.read_text())
    run.command('build-abi-vfp', [run.arm / 'arm-eabi-gcc', *HARD_FLAGS,
                '-Wl,-T,' + str(HERE / 'probes/an500.ld') + ',--gc-sections,-Map,abi-vfp.map',
                HERE / 'probes/an500-start.S', HERE / 'probes/abi-vfp.c',
                HERE / 'probes/abi-vfp.S', '-o', 'abi-vfp.elf'])
    attributes = run.command('elf-abi-vfp', [run.arm / 'arm-eabi-readelf', '-A', 'abi-vfp.elf'])
    require('Tag_FP_arch: FPv5/FP-D16 for ARMv8' in attributes
            and 'Tag_ABI_VFP_args: VFP registers' in attributes,
            'the VFP control is not a hard-float FPv5-D16 image')
    text = run.command('disassemble-abi-vfp', [run.arm / 'arm-eabi-objdump', '-d', 'abi-vfp.elf'])
    clobber = text.split('<vfp_clobber>:', 1)[1].split('\n\n', 1)[0]
    pushes = re.findall(r'\tvpush\t(\{[^}]*\})', clobber)
    require(pushes == ['{d8-d15}'],
            'GCC saves %s around a body that clobbers every VFP register, not d8-d15 alone'
            % (pushes or 'nothing'))
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    gdb = [f'target remote 127.0.0.1:{port}', 'set pagination off', 'set confirm off',
           'break done', 'break fault_done', 'continue', 'python', 'import gdb',
           'def v(expr): return int(gdb.parse_and_eval(expr))',
           'assert v("*(unsigned int*)&fault_seen") == 0, "the VFP control faulted: %d" % v("*(unsigned int*)&fault_seen")',
           'assert v("vfp_result") == 0x616, "GCC\'s caller saw a result other than the endpoint\'s"',
           'assert v("vfp_preserved") == 1, "a d8-d15 sentinel did not survive"',
           *vfp_checks(rows),
           'print("D616_VFP_ABI_PASS")', 'end', 'quit']
    (run.out / 'abi-vfp.gdb').write_text('\n'.join(gdb) + '\n')
    argv = [str(run.bin / 'qemu-system-arm'), '-M', 'mps2-an500', '-accel', 'tcg,thread=single',
            '-display', 'none', '-monitor', 'none', '-serial', 'null', '-kernel', 'abi-vfp.elf',
            '-S', '-gdb', f'tcp:127.0.0.1:{port}']
    record = {'name': 'qemu-abi-vfp', 'argv': argv, 'timeout_seconds': 25}
    run.commands.append(record)
    tick = time.monotonic()
    with (run.out / 'qemu-abi-vfp.log').open('wb') as log:
        p = subprocess.Popen(argv, cwd=run.out, env=run.env, stdout=log, stderr=log,
                             start_new_session=True)
        try:
            deadline = time.monotonic() + 3
            while True:
                require(p.poll() is None, 'VFP ABI QEMU exited before debugger connection')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1):
                        break
                except OSError:
                    require(time.monotonic() < deadline, 'VFP ABI debugger startup timed out')
                    time.sleep(.02)
            text = run.debug('gdb-abi-vfp', 'abi-vfp.elf', 'abi-vfp.gdb', timeout=20)
            oracle(text, 'D616_VFP_ABI_PASS')
        finally:
            stop(p)
            record.update(exit=p.returncode, seconds=time.monotonic()-tick,
                          stopped_by_supervisor=True)
            (run.out / 'commands.json').write_text(json.dumps(run.commands, indent=2)+'\n')


#  D987: the generated Cortex-M bindings' layouts against both compilers
#  at both of AAPCS32's rows.  Each binding fixture's adapters.c carries
#  the generator's static assertions of every native record's size,
#  alignment and field offsets and of each enum's size; compiled with
#  -fsyntax-only, each compiler holds them to its own layout.  A record's
#  layout is the same in both variants, so the VFP fixture's records must
#  hold at the base row too; the CMSIS fixture's RP2040 header refuses a
#  float unit by its own #error, which the VFP row must meet.
BINDING_ROWS = {
    'thumbv6m': {'gcc': ['-mcpu=cortex-m0', '-mthumb', '-mfloat-abi=soft'],
                 'clang': ['--target=thumbv6m-none-eabi', '-mfloat-abi=soft']},
    'thumbv7em-hard': {'gcc': ['-mcpu=cortex-m7', '-mthumb', '-mfpu=fpv5-d16',
                               '-mfloat-abi=hard'],
                       'clang': ['--target=thumbv7em-none-eabihf', '-mfpu=fpv5-d16',
                                 '-mfloat-abi=hard']},
}
BINDING_FIXTURES = {
    'cortex-cmsis-bindings': {'thumbv6m': True, 'thumbv7em-hard': False},
    'cortex-vfp-bindings': {'thumbv6m': True, 'thumbv7em-hard': True},
}
#  The header's refusal of a float unit the CMSIS fixture must meet.
NO_FPU = 'Compiler generates FPU instructions for a device without an FPU'


def binding_layouts(run):
    """Compile each binding fixture's adapters with the pinned GCC and with
    Clang, $CLANG or clang-19 where one is on PATH, at both rows, and hold
    each to its expected verdict.  Writes binding-layouts.json; a missing
    Clang is recorded and printed as SKIPPED, never passed."""
    from run import require
    sys.path.insert(0, str(HERE))
    from backend import C_STANDARD, fetched_inputs, metadata
    fixtures = ROOT / 'compiler/tests/fixtures/abi'
    gcc_include = run.command('binding-gcc-include', [
        run.arm / 'arm-eabi-gcc', '-print-file-name=include']).strip()
    clang = shutil.which(os.environ.get('CLANG', 'clang-19'))
    resource = None
    if clang:
        resource = run.command('binding-clang-resource', [clang, '-print-resource-dir']).strip()
    compilers = {'gcc': [str(run.arm / 'arm-eabi-gcc'), '-isystem', gcc_include]}
    if clang:
        compilers['clang'] = [clang, '--no-default-config', '-isystem', resource + '/include',
                              '-Wno-error=unused-command-line-argument']
    found = {'clang': clang or 'SKIPPED: no $CLANG or clang-19 on PATH', 'verdicts': {}}
    for name, holds in BINDING_FIXTURES.items():
        base = fixtures / name
        meta = metadata(base / 'fixture.meta')
        includes = ['-I', str(base)]
        for directory in fetched_inputs(meta):
            includes += ['-I', str(directory)]
        for row, flags in BINDING_ROWS.items():
            for compiler, command in compilers.items():
                label = '%s-%s-%s' % (name, row, compiler)
                argv = [command[0], *flags[compiler], *command[1:], '-ffreestanding',
                        *C_STANDARD, '-Wall', '-Wextra', '-Werror', *meta.c_args, *includes,
                        '-fsyntax-only', base / 'adapters.c']
                try:
                    run.command('binding-' + label, argv)
                    verdict = 'held'
                except Exception:
                    log = (run.out / ('binding-' + label + '.log')).read_text(errors='replace')
                    verdict = 'refused by its header' if NO_FPU in log else 'failed'
                wanted = 'held' if holds[row] else 'refused by its header'
                require(verdict == wanted, '%s\'s generated adapters at %s under %s: %s, and'
                        ' they must be %s; inspect %s' % (name, row, compiler, verdict, wanted,
                                                          run.out / ('binding-' + label + '.log')))
                found['verdicts'][label] = verdict
    (run.out / 'binding-layouts.json').write_text(json.dumps(found, indent=2) + '\n')
    if not clang:
        print('Cortex-M ABI binding layouts: Clang SKIPPED, no $CLANG or clang-19 on PATH;'
              ' GCC held both rows', flush=True)
