"""Independent Cortex-M0 layout measurements and hand-written calling witnesses."""
import json
from pathlib import Path
import shutil
import socket
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
CONTRACT = ROOT / 'compiler/tests/cortex-m.contract'
GOLDEN = ROOT / 'compiler/tests/layout.targets'
LAYOUT_KEYS = ('u8 u16 u32 u64 i8 i16 i32 i64 usize isize f32 f64 bool '
               'a b c d variant payload wrapped child nested multiple evidence0 evidence any').split()
CALL_COUNTS = dict(gap=3, split=5, stack=7, sret=3, small=3, varargs=4, floatpair=3, native=4, multi=1)


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
    if set(rows) != required or any(v < 0 for row in rows.values() for v in row):
        raise ValueError('incomplete or invalid ABI contract')
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
    # and Renode lanes still run independently before this additional lane.
    from run import require, oracle, stop
    rows = contract(CONTRACT.read_text())
    synthetic_agreement(rows, GOLDEN.read_text())
    shutil.copyfile(CONTRACT, run.out / 'cortex-m.contract')
    shutil.copyfile(GOLDEN, run.out / 'layout.targets')
    run.build('abi', extra=[HERE / 'probes/abi.S'])
    run.command('disassemble-abi', [run.bin / 'arm-none-eabi-objdump', '-d', 'abi.elf'])
    run.command('macros-abi', [run.bin / 'arm-none-eabi-gcc', '-mcpu=cortex-m0',
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
            text = run.command('gdb-abi', [run.bin / 'gdb-multiarch', '-q', '-nx', '-batch',
                                         'abi.elf', '-x', 'abi.gdb'], timeout=20)
            oracle(text, 'R620_ABI_PASS')
        finally:
            stop(p)
            record.update(exit=p.returncode, seconds=time.monotonic()-tick,
                          stopped_by_supervisor=True)
            (run.out / 'commands.json').write_text(json.dumps(run.commands, indent=2)+'\n')
    require(CONTRACT.read_bytes() == (run.out / 'cortex-m.contract').read_bytes()
            and GOLDEN.read_bytes() == (run.out / 'layout.targets').read_bytes(),
            'ABI contracts changed during probes')
