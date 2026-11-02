#!/usr/bin/env python3
"""Compiler-generated ARMv6-M execution through the external test harness.

This development selector is not the complete applicability/acceptance gate.
"""
import argparse
import json
import re
from pathlib import Path
import struct
import subprocess
import sys
import threading
import time

from run import FLAGS, CommandFailed, Run, gdb_listener, oracle, require, stop
from setup import DEFAULT, HERE, arm_archive, installed_tools, inventory, sha, supported_host

ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / 'compiler/tests'))
import fixture_meta  # noqa: E402
COUNTERPARTS = ROOT / 'compiler/tests/cortex-m'

#  The CPU feature levels (D255) the corpus executes, each with the
#  processor arguments the external harness assembles and links with, the
#  libgcc multilib that selects, the ELF attributes the image must carry,
#  the QEMU machine that executes it and the profile its map is.  QEMU's
#  micro:bit is a Cortex-M0 whatever -cpu says, so a higher level runs on an
#  MPS2 board's core, from the same locked binary: Armv7-M on the AN385's
#  Cortex-M3, whose memory is where the constrained reference puts it;
#  Armv8-M Mainline on the AN505's Cortex-M33, which boots from 0x10000000
#  (D607); and Armv7E-M with FPv5-D16 on the AN500's Cortex-M7, whose float
#  unit is a description's (D615, D619).  Only the corpus runs there,
#  because the synthetic peripheral windows are real devices on those boards.
#
#  A profile other than the reference is a lane's: an emulator's map, which
#  a description under lanes/descriptions/ beside this file states, and the
#  program reaches it through one more entry-module file, lanes/lane-NAME.ldn,
#  which imports it (D619).  A key that is no level of refine's names the
#  one it builds at as `level`: `armv7e-m+fpv5-d16` is `armv7e-m` on a
#  description with that float unit, and hard float selects the
#  `v7e-m+dp/hard` multilib, which GCC finds from the flags alone.
LEVELS = {
    'armv6-m': {'flags': ['-mcpu=cortex-m0'], 'multilib': '/thumb/v6-m/nofp/',
                'attributes': ['Tag_CPU_arch: v6S-M', 'Tag_THUMB_ISA_use: Thumb-1'],
                'machine': 'microbit', 'profile': 'constrained-reference'},
    'armv7-m': {'flags': ['-march=armv7-m'], 'multilib': '/thumb/v7-m/nofp/',
                'attributes': ['Tag_CPU_arch: v7', 'Tag_CPU_arch_profile: Microcontroller',
                               'Tag_THUMB_ISA_use: Thumb-2'],
                'machine': 'mps2-an385', 'profile': 'constrained-reference'},
    'armv8-m.main': {'flags': ['-march=armv8-m.main'], 'multilib': '/thumb/v8-m.main/nofp/',
                     'attributes': ['Tag_CPU_arch: v8-M.mainline',
                                    'Tag_CPU_arch_profile: Microcontroller'],
                     'machine': 'mps2-an505', 'profile': 'mps2-an505'},
    'armv7e-m+fpv5-d16': {
        'flags': ['-mcpu=cortex-m7', '-mfloat-abi=hard', '-mfpu=fpv5-d16'],
        'multilib': '/thumb/v7e-m+dp/hard/',
        'attributes': ['Tag_CPU_arch: v7E-M', 'Tag_CPU_arch_profile: Microcontroller',
                       'Tag_THUMB_ISA_use: Thumb-2', 'Tag_FP_arch: FPv5/FP-D16 for ARMv8',
                       'Tag_ABI_VFP_args: VFP registers'],
        'machine': 'mps2-an500', 'level': 'armv7e-m', 'profile': 'mps2-an500'},
}

#  The refine levels whose instructions are Thumb-2's, at which no image may
#  ask the runtime for a product or a 32-bit quotient (D255, D605).
THUMB_2 = ('armv7-m', 'armv7e-m', 'armv8-m.main')

#  The root the lanes' descriptions and entry-module files are found under.
LANE_ROOT = HERE / 'lanes'


def level_flags(level):
    """FLAGS with the processor and float arguments the level selects."""
    require(level in LEVELS, 'unknown Cortex level: ' + level)
    own = LEVELS[level]['flags']
    replaced = ['-mcpu='] + (['-mfloat-abi='] if any(
        f.startswith('-mfloat-abi=') for f in own) else [])
    return own + [f for f in FLAGS if not f.startswith(tuple(replaced))]


def hard_float(level):
    """Whether LEVEL's lane passes floats in the VFP bank (D616)."""
    return '-mfloat-abi=hard' in LEVELS[level]['flags']


def refine_level(level):
    """The --level refine builds LEVEL's programs at."""
    return LEVELS[level].get('level', level)


def lane_of(level):
    """The lane LEVEL runs on, or None for the constrained reference's map."""
    profile = LEVELS[level]['profile']
    return profile if profile in LANE_PROFILES else None


def lane_inputs(level, inputs):
    """INPUTS as LEVEL's lane compiles them: with its entry-module file,
    which imports its description, and a module directory's own sources
    in place of the directory, since a rooted request names one entry
    directory or its files (L0002)."""
    lane = lane_of(level)
    if lane is None:
        return list(inputs)
    result = ['--root=' + str(LANE_ROOT)]
    for one in inputs:
        path = Path(one)
        if not one.startswith('-') and path.is_dir():
            result += sorted(str(p) for p in path.glob('*.ldn'))
        else:
            result.append(one)
    return result + [str(LANE_ROOT / ('lane-' + lane + '.ldn'))]


#  The described devices, recorded apart from the compiler; descriptions.py
#  holds every linked image's facts to them.  A program that imports no
#  description is given the constrained reference (D543), which is the
#  profile the corpus executes on QEMU's micro:bit and AN385.  The lane
#  profiles are the descriptions of an emulator's map, not of a chip: each
#  is Landin source under lanes/ beside this file, recorded as a device is.
RECORDS = json.loads((HERE / 'descriptions.json').read_text())
DESCRIPTIONS = RECORDS['devices']
#  No limited verdict is linked again against a lane's map, which is no
#  device's (D619).
LANE_PROFILES = RECORDS['lanes']
REFERENCE = 'constrained-reference'

#  A profile's facts, as the firmware build report states them, with the
#  stack top read from the linked image.  `boot_prefix` and `boot_suffix`
#  are the bytes its boot image kind puts before and after the vector
#  table (D545), which the harness start supplies as zeros: the report is
#  where the harness learns a boot kind's layout.
FACTS = ('device', 'boot', 'float_unit', 'regions', 'placed', 'vector_address',
         'vector_words', 'boot_prefix', 'boot_suffix', 'flash_limit',
         'static_ram_limit', 'stack_reserved')


def region(profile, part):
    """The region PROFILE places PART in: text, data or stack."""
    name = profile['placed'][part]
    return next(r for r in profile['regions'] if r['name'] == name)


def stack_bottom(profile):
    return profile['stack_top'] - profile['stack_reserved']


def recorded(device=REFERENCE):
    """DEVICE's profile as descriptions.json records it, apart from the
    compiler, with the capacities a firmware build report derives (D545):
    the text region's length, and the data region's less a stack it holds."""
    want = {**DESCRIPTIONS, **LANE_PROFILES}[device]
    profile = {key: want[key] for key in FACTS if key in want}
    profile.update(device=device, stack_top=want['stack_top'], script=None)
    ram = region(profile, 'data')['length']
    if want['placed']['stack'] == want['placed']['data']:
        ram -= want['stack_reserved']
    profile.update(flash_limit=region(profile, 'text')['length'], static_ram_limit=ram)
    return profile


#  Each device's derived profile, once per compiler and process: deriving
#  it is one firmware build, and the corpus links every program with it.
DERIVED = {}
DERIVING = threading.Lock()

#  What each device's profile is derived from (D589): its description, or a
#  module of nothing for the reference, which the library supplies when
#  the program reaches no description.  A lane profile's module is named in
#  its record, under this directory's root.
def probe_source(device):
    if device in LANE_PROFILES:
        return 'import descriptions/%s\n' % LANE_PROFILES[device]['module']
    return '' if device == REFERENCE else 'import descriptions/%s\n' % device


def probe_root(device):
    """The module root a profile's description is found under."""
    return LANE_ROOT if device in LANE_PROFILES else ROOT / 'devices'


def probe_level(device):
    """The level DEVICE's description builds at: its float unit's, or the
    default for one without (D615)."""
    want = {**DESCRIPTIONS, **LANE_PROFILES}[device]
    return ['--level=' + want['level']] if want['float_unit'] != 'none' else []


def said_why(error):
    """A failed compiler command with the compiler's first diagnostic, so
    the failure says why rather than only which log to read."""
    first = next((line.strip() for line in Path(error.log).read_text(
        errors='replace').splitlines() if line.startswith('error[')), '')
    return CommandFailed(error.name, error.log, error.ended + (': ' + first if first else ''))


def derived(run, refine, device=REFERENCE, where=None):
    """DEVICE's profile as refine derives it: the linker script a firmware
    build of a program selecting it writes (D545), and the limits its build
    report gives, written without a program by `--emit=linker-script`
    (D589) in WHERE/DEVICE, by default `profiles/DEVICE` beside RUN's
    output.

    The facts are held to descriptions.json's record, so a profile the
    harness links with is the one descriptions.py compares.
    """
    key = (str(refine), device)
    with DERIVING:
        if key in DERIVED:
            return DERIVED[key]
        out = (where or run.out.parent / 'profiles') / device
        out.mkdir(parents=True, exist_ok=True)
        (out / 'profile.ldn').write_text(probe_source(device))
        probe = Run(out, run.tools)
        try:
            probe.command('derive-profile', [
                refine, 'compile', '--root=' + str(probe_root(device)), '--target=cortex-m0',
                *probe_level(device), '--emit=linker-script', '--build-report=profile.json',
                'profile.ldn', '-o', 'profile.ld'], timeout=60)
        except CommandFailed as error:
            raise said_why(error) from None
        report = json.loads((out / 'profile.json').read_text())['firmware']
        profile = {key: report[key] for key in FACTS}
        profile.update(stack_top=report['stack_top'], script=str(out / 'profile.ld'))
        want = recorded(device)
        differ = sorted(k for k in FACTS + ('stack_top',) if profile[k] != want[k])
        require(not differ, '%s: refine derives %s other than descriptions.json records'
                % (device, ', '.join(differ)))
        (out / 'facts.json').write_text(json.dumps(profile, indent=2) + '\n')
        DERIVED[key] = profile
        return profile


def metadata(path):
    """The metadata of the fixture whose `fixture.meta` is PATH, read as
    the test program reads it (compiler/tests/fixture_meta.py)."""
    return fixture_meta.read(path.parent)


def session(run, port, expected, traps, before=(), profile=None, vfp=False):
    """The debugger session that runs one harness image and holds it to its oracle.

    EXPECTED is the exit byte the program must return, or None to observe
    whatever it returns or traps with, as `backend_corpus.py --program`
    does; TRAPS that it must reach the harness's HardFault at a UDF #1.
    Once the harness has painted the stack, a write watchpoint covers the
    reservation's lowest 16 bytes, so a stack that overruns its
    reservation stops at the instruction that reached the guard, and the
    failure names that routine, its caller and how much of which stack was
    in use, rather than an assertion after the fact.
    """
    profile = profile or recorded()
    top, bottom, reserved = profile['stack_top'], stack_bottom(profile), profile['stack_reserved']
    observe = expected is None
    finish = []
    if observe:
        finish = [
            'result = value("*(unsigned int*)&backend_result")',
            'observed = {"status": result & 255, "result": result,'
            ' "r12": value("*((unsigned int*)&backend_result+1)"),'
            ' "trapped": fault == 3, "stopped": where(value("$pc"))}',
            'if fault:',
            '    observed["stacked_pc"] = where(frame[6])',
            '    observed["udf_1"] = value("*(unsigned short*)%d" % (frame[6] & ~1)) == 0xde01',
            f'with open({str(run.out / "observed.json")!r}, "w") as f: json.dump(observed, f)']
    elif traps:
        finish = [
            'check(fault == 3, "backend_fault is %d, expected 3" % fault)',
            'check(value("$pc") == value("&backend_fault_done"), "the program did not stop at backend_fault_done")',
            'check(value("*(unsigned short*)*(unsigned int*)(%d+24)" % frame_at) == 0xde01, '
            '"the stacked pc is no udf #1, the trap instruction")']
    else:
        finish = [
            'check(fault == 0, "backend_fault is %d, expected 0" % fault)',
            'check(value("$pc") == value("&backend_done"), "the program did not stop at backend_done")',
            f'check(value("*(unsigned int*)&backend_result") & 255 == {expected}, '
            f'"the result is %d, expected {expected}" % (value("*(unsigned int*)&backend_result") & 255))',
            'check(value("*((unsigned int*)&backend_result+1)") == 0, "r12 was not zero at return")',
            f'check(value("$sp") == {top}, "sp is %#x at return, expected {top:#x}" % value("$sp"))',
            'check(value("$r11") == 0, "r11 is not zero at return")',
            'check([value("$r%d" % i) for i in range(4, 11)] == [44,55,66,77,88,99,100], '
            '"a callee-saved register r4-r10 was not preserved")']
        if vfp:
            #  D616: the harness painted d8-d15 before main and compared
            #  them after it returned.
            finish.append('check(value("*((unsigned int*)&backend_result+2)") == 1, '
                          '"a callee-saved register d8-d15 was not preserved")')
    return '\n'.join([
        'set pagination off', 'set confirm off',
        f'target remote 127.0.0.1:{port}',
        'break backend_painted', 'continue', 'delete breakpoints', *before,
        'delete breakpoints',
        'python', 'import gdb',
        #  An ordinary watchpoint, which the server's discard between
        #  sessions removes; an internal one would outlive this session.
        f'guard = gdb.Breakpoint("*(unsigned char (*)[16]){bottom}", gdb.BP_WATCHPOINT, gdb.WP_WRITE)',
        #  A software watchpoint would single-step the whole program.
        'assert guard.type == gdb.BP_HARDWARE_WATCHPOINT, "the stack guard is no hardware watchpoint"',
        'end',
        'break backend_done', 'break backend_fault_done', 'continue',
        'python', 'import json, struct',
        'def value(expr): return int(gdb.parse_and_eval(expr))',
        #  Where the program stopped, said before anything is held to it:
        #  the exception the harness recorded (3, HardFault, for a trap or
        #  a fault), the stop, and after an exception the frame the core
        #  stacked, whose pc is the faulting instruction.
        'def where(address):',
        '    said = gdb.execute("info symbol %#x" % address, to_string=True).strip()',
        '    line = gdb.execute("info line *%#x" % address, to_string=True).strip()',
        '    return "%#x (%s; %s)" % (address, said, line.split(" and ends")[0])',
        'def check(holds, what):',
        '    if not holds: raise gdb.GdbError("LANDIN-CHECK " + what + "; " + state)',
        'pc = value("$pc")',
        'if pc not in (value("&backend_done"), value("&backend_fault_done")):',
        '    sp = value("$sp")',
        '    which = "process stack (PSP)" if value("$control") & 2 else "main stack (MSP)"',
        '    state = "stopped by the write watchpoint on the guard"',
        f'    check(False, "the stack overran its {reserved}-byte reservation: %s wrote into'
        f' its lowest 16 bytes at {bottom:#x}, called from %s, with sp %#x and %d bytes of the'
        f' %s in use" % (where(pc), where(value("$lr") & ~1), sp, {top} - sp, which))',
        'fault = value("*(unsigned int*)&backend_fault")',
        'state = "fault=%d%s pc=%s" % (fault, " (HardFault)" if fault == 3 else "", where(value("$pc")))',
        'frame = None',
        #  The harness records the stack the exception frame is on, which
        #  is a fibre's own when the fault was taken there.
        'frame_at = value("*((unsigned int*)&backend_fault+1)")',
        'if fault:',
        '    frame = [value("*(unsigned int*)(%d+%d)" % (frame_at, 4 * i)) for i in range(8)]',
        '    state += " stacked pc=%s lr=%s xpsr=%#x" % (where(frame[6]), where(frame[5] & ~1), frame[7])',
        'print("LANDIN-STATE " + state)',
        *finish,
        #  One read of the reservation rather than a round trip a word.
        f'words=list(struct.unpack("<{reserved // 4}I", bytes(gdb.selected_inferior().read_memory({bottom}, {reserved}))))',
        f'check(words[:4] == [0xa55ac33c]*4, "the stack overran its {reserved}-byte reservation")',
        f'check(value("$sp") >= {bottom}, "sp is below the stack reservation")',
        'first=next((i for i,w in enumerate(words) if w != 0xa55ac33c), len(words))',
        f'with open({str(run.out / "stack-observation.json")!r}, "w") as f: json.dump({{"lowest_changed_word":{bottom}+4*first,"reserved_bytes":{reserved},"is_stack_bound":False}},f)',
        'print("R650_GENERATED_QEMU_PASS")', 'end', 'quit', ''])


def execute(run, elf, expected, traps, before=(), level='armv6-m', profile=None):
    """Run ELF under QEMU and hold it to its oracle; see `session`.

    PROFILE is the one the image was linked for, which must be the level's
    own: QEMU's machines have the reference's map or a lane profile's, not
    a chip's.
    """
    machine = LEVELS[level]['profile']
    require(profile is None or profile['device'] == machine,
            'an image linked for %s does not run on QEMU\'s %s, whose map is %s\'s;'
            ' a chip\'s images are linked, not run'
            % (profile and profile['device'], LEVELS[level]['machine'], machine))
    profile = profile or recorded(machine)
    listener, port, stub = gdb_listener()
    script = run.out / 'backend.gdb'
    script.write_text(session(run, port, expected, traps, before, profile,
                              vfp=hard_float(level)))
    argv = [str(run.bin / 'qemu-system-arm'), '-M', LEVELS[level]['machine'], '-accel',
            'tcg,thread=single', '-display', 'none', '-monitor', 'none',
            '-serial', 'none', '-kernel', str(elf), '-S', *stub]
    record = {'name': 'qemu-backend', 'argv': argv, 'timeout_seconds': 25}
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
            try:
                text = run.debug('gdb-backend', elf, script, timeout=SESSION_LIMIT)
            except CommandFailed as error:
                if error.ended.startswith('timed out'):
                    raise timed_out(error, process, time.monotonic() - tick) from None
                raise RuntimeError(session_failure(error)) from None
            oracle(text, 'R650_GENERATED_QEMU_PASS')
        finally:
            stop(process)
            record['seconds'] = time.monotonic() - tick
            record['exit'] = process.returncode
            (run.out / 'commands.json').write_text(json.dumps(run.commands, indent=2)+'\n')


#  How long one program may take, from GDB connecting to its result
#  breakpoint, under single-threaded QEMU.
SESSION_LIMIT = 20


def session_failure(error):
    """A failed session's line: which check failed, the exception and the
    stop, read from the session's own log, rather than its name alone."""
    said = []
    try:
        text = Path(error.log).read_text(errors='replace')
    except OSError:
        text = ''
    for marker in ('LANDIN-CHECK ', 'LANDIN-STATE '):
        found = next((line[line.index(marker) + len(marker):].strip()
                      for line in text.splitlines() if marker in line), None)
        if found:
            said.append(found)
            break
    return '%s %s%s; inspect %s' % (error.name, error.ended,
                                   ': ' + said[0] if said else '', error.log)


def timed_out(error, process, elapsed):
    """A debugger session's timeout, saying whose time ran out.

    QEMU still running when the session ends means the program never
    reached either result breakpoint: the fixture, not the debugger, took
    longer than the limit.  An emulator that had already exited is the
    other case, and says so.
    """
    if process.poll() is None:
        return RuntimeError(
            'the program ran for %.1f s under QEMU and reached neither backend_done nor '
            'backend_fault_done within the debugger\'s %d-second session limit: the fixture '
            'takes longer than a corpus program may; inspect %s'
            % (elapsed, SESSION_LIMIT, error.log))
    return RuntimeError(
        'QEMU exited with status %s %.1f s after it started, before the program reached a '
        'result breakpoint, and the %d-second debugger session ran out waiting; inspect %s'
        % (process.returncode, elapsed, SESSION_LIMIT, error.log))


class ImageLimit(RuntimeError):
    """An image the harness will not assemble for the selected profile: a
    materialization past its resource guard, or a routine frame past the
    stack.  The linker's own overflow is a failed `assemble-link`."""


def load_extents(path, profile):
    """Flash and static RAM a linked image occupies, read from its LOAD headers.

    Flash is the end of the last file-backed segment in the text region,
    and static RAM the end of the last segment in the data region, each
    counted from the region's origin, as the firmware build report counts
    them (D545).  Unlike image_contract this holds the image to no bound,
    so it measures an image linked with the enlarged map as well as a
    fitting one.
    """
    text, data_region = region(profile, 'text'), region(profile, 'data')
    data = path.read_bytes()
    header = struct.unpack_from('<16sHHIIIIIHHHHHH', data)
    flash, ram = text['origin'], data_region['origin']
    for index in range(header[10]):
        kind, _, virtual, physical, file_size, memory_size, _, _ = struct.unpack_from(
            '<8I', data, header[5] + index * 32)
        if kind != 1:
            continue
        if file_size and physical >= text['origin']:
            flash = max(flash, physical + file_size)
        if data_region['origin'] <= virtual < data_region['origin'] + (1 << 28):
            ram = max(ram, virtual + memory_size)
    return {'FLASH': flash - text['origin'], 'RAM': ram - data_region['origin']}


def routine_sizes(listing):
    """Each routine's bytes, largest first, from `nm -S --defined-only`.

    A routine is a sized symbol in a code section, `T` or `t`; Thumb
    addresses and the vector table's words are not routines and have no
    size there.  Equal sizes keep the order of their names.
    """
    sizes = {}
    for line in listing.splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[2] in ('T', 't'):
            sizes[parts[3]] = int(parts[1], 16)
    return dict(sorted(sizes.items(), key=lambda item: (-item[1], item[0])))


#  A data section of the compiler's object: `.data`, `.bss` or `.rodata`,
#  each item's own subsection of them, or a region's (D547).
DATA_SECTION = re.compile(r'\.(data|bss|rodata)(\.|$)|\.landin_region\.[^.]+\.(data|bss|rodata)\.')


def datum_symbols(listing):
    """Each symbol `readelf -S -s -W` lists as defined in a data section,
    with its type, size and section-relative address, and each data
    section's size, from the section table readelf prints first.

    A mapping symbol (`$d`, `$t`), a section or a file symbol is not a
    datum.
    """
    names, sizes, symbols = {}, {}, {}
    for line in listing.splitlines():
        found = re.match(r'\s*\[\s*(\d+)\]\s+(\S+)\s+(\S+)\s+[0-9a-f]+\s+[0-9a-f]+\s+([0-9a-f]+)\s', line)
        if found:
            names[found.group(1)] = found.group(2)
            sizes[found.group(2)] = int(found.group(4), 16)
            continue
        fields = line.split()
        if len(fields) != 8 or not fields[0].endswith(':') or not fields[0][:-1].isdigit():
            continue
        _, value, size, kind, _, _, index, name = fields
        section = names.get(index, '')
        if kind in ('SECTION', 'FILE') or name.startswith('$') or not DATA_SECTION.match(section):
            continue
        symbols[name] = {'type': kind, 'size': int(size, 0), 'address': int(value, 16),
                         'section': section}
    return symbols, sizes


def check_datum_symbols(run, obj):
    """Every module datum is typed and sized in the symbol table, with an
    initial image or without, as the other ELF backends' are, so that its
    extent is read from `nm -S` or readelf rather than from the next
    symbol's address (D470): an object symbol, whose size reaches no
    further than the next datum of its section or the section's end, and
    is nonzero unless the section is empty.  Writes `datum-symbols.json`."""
    symbols, sizes = datum_symbols(run.command(
        'datum-symbols', [run.arm / 'arm-eabi-readelf', '-S', '-s', '-W', obj]))
    faults = []
    for name, symbol in sorted(symbols.items()):
        ends = [other['address'] for other in symbols.values()
                if other['section'] == symbol['section'] and other['address'] > symbol['address']]
        limit = min(ends + [sizes[symbol['section']]])
        if symbol['type'] != 'OBJECT':
            faults.append(name + ' is ' + symbol['type'] + ', not OBJECT')
        elif symbol['address'] + symbol['size'] > limit:
            faults.append(name + ' overruns ' + symbol['section'])
        elif symbol['size'] == 0 and limit > symbol['address']:
            faults.append(name + ' has no size in ' + symbol['section'])
    require(not faults, 'module data not typed and sized: ' + '; '.join(faults))
    (run.out / 'datum-symbols.json').write_text(json.dumps(symbols, indent=2, sort_keys=True) + '\n')
    return symbols


def image_sizes(run, elf, profile, name='sections'):
    """Each region's use against the limit the profile's build report
    gives, each allocated section's size and each routine's, so where an
    image's bytes go is read from the corpus rather than from hand-run
    tools, overflowing or not.  `FLASH` is the text region and `RAM` the
    static RAM of the data region, whatever the description names them."""
    listing = run.command(name, [run.arm / 'arm-eabi-size', '-A', elf])
    sections = {}
    for line in listing.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0].startswith('.') and parts[1].isdigit():
            if parts[0] in ('.isr_vector', '.text', '.data', '.bss') and int(parts[1]):
                sections[parts[0]] = int(parts[1])
    routines = routine_sizes(run.command(
        name + '-routines', [run.arm / 'arm-eabi-nm', '-S', '--defined-only', elf]))
    used = load_extents(elf, profile)
    limits = {'FLASH': profile['flash_limit'], 'RAM': profile['static_ram_limit']}
    return {'regions': {part: {'used': used[part], 'limit': limit}
                        for part, limit in limits.items()},
            'sections': sections, 'routines': routines}


def describe_routines(sizes, count=3):
    """The largest routines of an image, for a corpus line; "" without any."""
    routines = list(sizes.get('routines', {}).items())[:count]
    if not routines:
        return ''
    return 'largest routines ' + ', '.join('%s %d' % item for item in routines)


def describe_sizes(sizes):
    """One corpus-line clause: every region against its limit, and its sections."""
    members = {'FLASH': ('.isr_vector', '.text', '.data'), 'RAM': ('.data', '.bss')}
    parts = []
    for part, record in sizes['regions'].items():
        text = '%s %d of %d' % (part, record['used'], record['limit'])
        if record['used'] > record['limit']:
            text += ', over by %d' % (record['used'] - record['limit'])
        inside = ['%s %d' % (section, sizes['sections'][section])
                  for section in members[part] if section in sizes['sections']]
        if inside:
            text += ' (' + ', '.join(inside) + ')'
        parts.append(text)
    return '; '.join(parts)


def harness_start(run, profile, level='armv6-m', name='input-0.o'):
    """backend-start.S assembled for PROFILE: its table's length and its
    boot kind's prefix and suffix."""
    obj = run.out / name
    run.command('assemble-start' if name == 'input-0.o' else 'assemble-' + Path(name).stem,
                [run.arm / 'arm-eabi-gcc', *level_flags(level),
                 '-DLANDIN_VECTOR_WORDS=%d' % profile['vector_words'],
                 '-DLANDIN_BOOT_PREFIX=%d' % profile['boot_prefix'],
                 '-DLANDIN_BOOT_SUFFIX=%d' % profile['boot_suffix'],
                 '-DLANDIN_FPU=%d' % hard_float(level),
                 '-c', HERE / 'probes/backend-start.S', '-o', obj])
    return obj


def link(run, objects, script, level, elf, name='assemble-link'):
    run.command(name, [run.arm / 'arm-eabi-gcc', *level_flags(level),
                '-Wl,-T,' + str(script) + ',--gc-sections,-Map,' + elf.stem + '.map',
                *objects, '-lgcc', '-o', elf])


def measure_overflow(run, profile, objects=None, level='armv6-m'):
    """The sizes an image that overflowed the map would have had.

    The objects the failed link left are relinked against a copy of the
    profile's derived script with its text and data regions enlarged and
    its assertions removed.  The result is a measurement and never runs.
    """
    text = Path(profile['script']).read_text()
    for part in ('text', 'data'):
        name = region(profile, part)['name']
        line = re.search(r'^  %s \((\w+)\) : ORIGIN = (\d+), LENGTH = (\d+)$' % name, text, re.M)
        require(line is not None, 'the derived script has no MEMORY line for ' + name)
        text = text.replace(line.group(0), '  %s (%s) : ORIGIN = %s, LENGTH = 256M'
                            % (name, line.group(1), line.group(2)))
    require('\nASSERT(' in text, 'the derived script asserts nothing')
    text = text[:text.index('\nASSERT(')]
    script = run.out / 'measure-memory.ld'
    script.write_text('/* Measurement only: never executed. */\n' + text + '\n')
    if objects is None:
        objects = sorted(run.out.glob('input-*.o'), key=lambda p: int(p.stem.split('-')[1]))
    elf = run.out / 'measure.elf'
    link(run, objects, script, level, elf, 'measure-link')
    return image_sizes(run, elf, profile, 'measure-sections')


def preflight(assembly):
    """Bound materialization before invoking as, even for giant .rept images.

    This is a resource guard, not an encoding or physical-image verdict,
    and independent of the compiler's own image budget (D537), which
    holds assembly without a firmware request to the 32-bit address space.
    It counts what .rept, .zero, .space and .fill materialize.  The
    linker remains authoritative for the selected flash/RAM map.
    """
    total = 0
    nesting = []
    factor = 1
    for line in assembly.read_text().splitlines():
        text = line.strip()
        if text.startswith('.rept '):
            count = int(text.split()[1])
            nesting.append(factor)
            factor *= count
        elif text == '.endr':
            require(bool(nesting), 'unbalanced assembly repetition')
            factor = nesting.pop()
        elif text.startswith(('.zero ', '.space ')):
            total += factor * int(text.split()[1].split(',')[0])
        elif text.startswith('.fill '):
            count, size = (int(part) for part in text[6:].split(',')[:2])
            total += factor * count * size
        elif text.startswith(('.byte ', '.short ', '.long ', '.quad ', '.word ')):
            width = {'.byte': 1, '.short': 2, '.long': 4, '.quad': 8, '.word': 4}
            directive, values = text.split(None, 1)
            total += factor * width[directive] * len(values.split(','))
        elif text and not text.startswith(('.', '@')) and not text.endswith(':'):
            total += factor * 4
        if total > MATERIALIZATION:
            raise ImageLimit('bounded assembly materialization exceeds 8 MiB')
    require(not nesting, 'unclosed assembly repetition')
    return total


#  What preflight lets the assembler materialize.
MATERIALIZATION = 8 * 1024 * 1024


def image_contract(path, profile=None):
    """Independently read actual ELF LOAD extents, rather than trust a map label.

    Every loaded segment lies in the profile's text region or below its
    static RAM limit in the data region, and the vector table at the
    profile's address holds its stack top and the entry.  PROFILE is the
    one the image was linked for; without one it is the constrained
    reference as descriptions.json records it, the profile the firmware
    lanes build for.
    """
    profile = profile or recorded()
    text, data_region = region(profile, 'text'), region(profile, 'data')
    flash_lo, flash_hi = text['origin'], text['origin'] + text['length']
    ram_lo = data_region['origin']
    ram_hi = ram_lo + profile['static_ram_limit']
    data = path.read_bytes()
    require(len(data) >= 52 and data[:6] == b'\x7fELF\x01\x01', 'expected little-endian ELF32')
    header = struct.unpack_from('<16sHHIIIIIHHHHHH', data)
    require(header[1:4] == (2, 40, 1) and header[8] == 52 and header[9] == 32,
            'unexpected ELF identity or program header')
    require(header[4] & 1 and flash_lo <= header[4] < flash_hi,
            'entry loses Thumb identity or flash bound')
    flash_end, ram_end, vectors = flash_lo, ram_lo, False
    table = profile['vector_address']
    for index in range(header[10]):
        offset = header[5] + index * 32
        require(offset + 32 <= len(data), 'truncated ELF program header')
        kind, file_at, virtual, physical, file_size, memory_size, _, _ = struct.unpack_from('<8I', data, offset)
        if kind != 1:
            continue
        require(file_size <= memory_size and file_at + file_size <= len(data), 'invalid ELF load extent')
        if flash_lo <= virtual < flash_hi:
            require(virtual + memory_size <= flash_hi, 'ELF exceeds selected flash')
        else:
            require(ram_lo <= virtual and virtual + memory_size <= ram_hi,
                    'ELF intrudes on selected RAM/stack boundary')
            ram_end = max(ram_end, virtual + memory_size)
        if file_size:
            require(flash_lo <= physical and physical + file_size <= flash_hi,
                    'ELF load image exceeds selected flash')
            flash_end = max(flash_end, physical + file_size)
        if virtual == physical and physical <= table < physical + file_size:
            require(table + 4 * profile['vector_words'] <= physical + file_size,
                    'missing external vectors')
            require(struct.unpack_from('<II', data, file_at + table - physical)
                    == (profile['stack_top'], header[4]),
                    'external initial SP/reset words disagree')
            vectors = True
    require(vectors, 'no external vector load segment')
    return {'flash_load_extent': flash_end - flash_lo, 'ram_static_extent': ram_end - ram_lo,
            'stack_reserved': profile['stack_reserved'], 'entry': header[4]}


def build(run, refine, inputs, optimize, specialize, extra=(), linker=None,
          level='armv6-m', profile=None):
    """Compile INPUTS to assembly and link them with the external harness.

    The image is linked with PROFILE's derived script, by default the
    profile of LEVEL's machine, and held to the limits its build report
    gives; LINKER replaces the script for a control that places a routine
    of its own, keeping the profile's facts.
    """
    profile = profile or derived(run, refine, LEVELS[level]['profile'])
    flags = level_flags(level)
    selected = [] if level == 'armv6-m' else ['--level=' + refine_level(level)]
    assembly = run.out / 'program.s'
    try:
        run.command('compile', [refine, *lane_inputs(level, inputs), '--target=cortex-m0',
                    *selected, '--emit=asm',
                    '--optimize=' + optimize, '--specialize=' + specialize,
                    '-o', assembly, '--build-report=' + str(run.out / 'build.json')],
                    timeout=60)
    except CommandFailed as error:
        raise said_why(error) from None
    preflight(assembly)
    report = json.loads((run.out / 'build.json').read_text())['build']
    if any(r['frame_bytes'] > profile['stack_reserved'] for r in report['routines']):
        raise ImageLimit('routine frame exceeds the selected %d-byte stack reservation'
                         % profile['stack_reserved'])
    elf = run.out / 'program.elf'
    objects = [harness_start(run, profile, level)]
    for index, source in enumerate([assembly, *extra], start=1):
        obj = run.out / ('input-' + str(index) + '.o')
        run.command('assemble-' + str(index), [run.arm / 'arm-eabi-gcc', *flags,
                    '-c', source, '-o', obj])
        objects.append(obj)
    run.command('object-disassembly', [run.arm / 'arm-eabi-objdump', '-dr', objects[1]])
    check_datum_symbols(run, objects[1])
    link(run, objects, linker or profile['script'], level, elf)
    image = image_contract(elf, profile)
    image.update(image_sizes(run, elf, profile))
    image['profile'] = profile['device']
    (run.out / 'image.json').write_text(json.dumps(image, indent=2)+'\n')
    attributes = run.command('elf', [run.arm / 'arm-eabi-readelf', '-h', '-A', '-S', elf])
    require(all(tag in attributes for tag in LEVELS[level]['attributes']),
            'ELF does not describe the selected ' + level + ' profile')
    require('Tag_ARM_ISA_use: Yes' not in attributes
            and ('VFP registers' in attributes) == hard_float(level),
            'ELF requires an unsupported instruction or floating ABI')
    run.command('disassembly', [run.arm / 'arm-eabi-objdump', '-dr', elf])
    run.command('size', [run.arm / 'arm-eabi-size', elf])
    require(not run.command('undefined', [run.arm / 'arm-eabi-nm', '-u', elf]).strip(),
            'freestanding test image has unresolved dependencies')
    library = Path(run.command('libgcc-path', [run.arm / 'arm-eabi-gcc', *flags,
                   '-print-libgcc-file-name']).strip()).resolve(strict=True)
    require(LEVELS[level]['multilib'] in str(library), 'wrong Arm runtime multilib')
    (run.out / 'helpers.json').write_text(json.dumps({
        'library': str(library), 'sha256': sha(library),
        'requested': sorted(set(re.findall(r'\bbl (__aeabi_\w+)', assembly.read_text()))),
        'unresolved': [], 'provenance': 'pinned ' + arm_archive()['file'],
    }, indent=2) + '\n')
    return elf


def fixture(run, refine, name, optimize, specialize, level='armv6-m',
            include_compiler_sha256=True):
    source = ROOT / 'compiler/tests/fixtures' / name
    meta = metadata(source / 'fixture.meta')
    require(meta['class'] == 'runtime', 'development selector requires runtime fixture')
    inputs = meta.module_arguments(source)
    counterparts = json.loads((COUNTERPARTS / 'counterparts.json').read_text())['replacements']
    if source.name in counterparts:
        inputs = ['--root=' + str(ROOT), str(COUNTERPARTS / 'cases' / source.name)]
    require(not meta.get('args'), 'fixture has explicit compiler arguments')
    require(not meta.get('run_args') and not meta.get('run_files')
            and not meta.get('run_expect') and not meta.get('stdin'),
            'fixture requires hosted input/output')
    #  Both link and run on LEVEL's own profile: the reference's, or its
    #  lane's description's.
    elf = build(run, refine, inputs, optimize, specialize, level=level)
    execute(run, elf, 1 if name == 'runtime/fixed-conditional-runtime' else
            meta.status_at(refine_level(level)), meta.traps, level=level)
    result = {'fixture': name, 'optimize': optimize, 'specialize': specialize,
              'status': 'passed'}
    if include_compiler_sha256:
        result['compiler_sha256'] = sha(refine)
    return result


def levels_of(meta):
    """The M-profile levels a fixture's `levels:` names beyond the default."""
    if not isinstance(meta, fixture_meta.Metadata):
        meta = fixture_meta.Metadata.of(meta, 'runtime/')
    return [one for one in meta.levels_for('cortex-m0') if one in LEVELS]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=DEFAULT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--fixture', action='append', required=True)
    parser.add_argument('--optimize', default='none', choices=['none', 'size', 'speed'])
    parser.add_argument('--specialize', default='off', choices=['off', 'auto', 'all'])
    args = parser.parse_args()
    supported_host(args.output)
    args.tools = installed_tools(args.tools)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    tools_before = inventory(args.tools.resolve())
    results = []
    for name in args.fixture:
        output = args.output / name.replace('/', '--')
        output.mkdir(exist_ok=False)
        run = Run(output, args.tools.resolve())
        try:
            result = fixture(run, args.refine.resolve(), name,
                             args.optimize, args.specialize)
            result['artifacts'] = {str(p.relative_to(run.out)): sha(p)
                                   for p in sorted(run.out.rglob('*')) if p.is_file()}
            (run.out / 'result.json').write_text(json.dumps(result, indent=2)+'\n')
            print('DEVELOPMENT / FILTERED / NOT ACCEPTANCE: ' + name + ' passed', flush=True)
        except Exception as error:
            result = {'fixture': name, 'status': 'failed', 'error': str(error)}
            (run.out / 'failure.json').write_text(json.dumps(result, indent=2)+'\n')
            print('FAILED: ' + name + ': ' + str(error), flush=True)
        results.append(result)
    require(inventory(args.tools.resolve()) == tools_before, 'embedded tools changed')
    (args.output / 'result.json').write_text(json.dumps(
        {'scope': 'development-filtered', 'tools': tools_before, 'results': results},
        indent=2)+'\n')
    require(all(r['status'] == 'passed' for r in results), 'one or more fixtures failed')


if __name__ == '__main__':
    main()
