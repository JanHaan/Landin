#!/usr/bin/env python3
"""Board timing runs: the `cycles` class of docs/measurement.md.

    python3 environments/boards/timing.py build --refine REFINE --output NEW_DIRECTORY
        [--board BOARD ...] [--workload NAME ...] [--profile none-off ...]
    python3 environments/boards/timing.py run --bundle BUNDLE --board BOARD
        --output NEW_DIRECTORY [--repeat N] [--image DIGEST ...] [board options]
    python3 environments/boards/timing.py remote --bundle BUNDLE --output NEW_DIRECTORY
        [--board BOARD ...] [--repeat N] [--ram-loader PI_HELPER] [-- board options]
    python3 environments/boards/timing.py noise --results DIRECTORY ... --output FILE
    python3 environments/boards/timing.py figures (--results DIRECTORY ... | --evidence DIRECTORY)
        --output FILE
    python3 environments/boards/timing.py compare FIGURES [--base REV]
    python3 environments/boards/timing.py record FIGURES [--board BOARD ...] [--key KEY ...]

`build`, on the build host, compiles each workload of the firmware set in
compiler/tests/measure/workloads.json at each of the nine profiles as each
board's RAM image, its own `main` entered through
compiler/tests/measure/firmware/entry.ldn, and keeps one copy of each
distinct image, naming every profile that gave it.  It touches no rig.

`run`, on rigpi, holds the rig lock across one board's whole batch and runs
each image REPEAT times through the SRAM helper's timing plan: the helper
loads it as a warm RAM run does, starts the board's counter, stops the
program with a breakpoint where its entry returns, and reads there the
status, the trap count and the counter the program read just before it
called `main` and just after `main` returned, whose difference is the
figure.  A status other than the fixture's, a trap, a program that does
not stop, or a figure past 2^31 fails the run.

`remote` copies a bundle and the matching board tools to rigpi, runs `run`
there for each board in turn, and retrieves every result.  `noise` writes
the noise study's record, compiler/tests/measure/noise/cycles.json, from
results whose images ran at least ten times; `figures` writes every
configuration's figure, keyed `board/level/profile/workload`, and the
limits, from a full pass's results or from the gate's board evidence;
`compare` holds them to the base commit's baselines,
compiler/tests/measure/baselines/BOARD.cycles.json, with each board's
tolerance from the noise study's record, and `record` writes them there.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import statistics
import struct
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import bundle  # noqa: E402
import common  # noqa: E402
from common import Failed, require  # noqa: E402

FORMAT = 'landin-board-timing-1'
OPTIMIZE = ('none', 'size', 'speed')
SPECIALIZE = ('off', 'auto', 'all')
PROFILES = tuple('%s-%s' % (o, s) for o in OPTIMIZE for s in SPECIALIZE)
ENTRY = 'compiler/tests/measure/firmware/entry.ldn'
COUNTERS = 'compiler/tests/measure/firmware/boards'
STATUS = 'measured_status'
BEFORE, AFTER = 'measured_before', 'measured_after'
LIMIT = 1 << 31

# Each port's target and level, as the board bundles are built
# (build.TARGETS), less the STM32H753's cached profile, whose caches a
# warm load refuses after it ran.
BOARDS = dict(rp2040=('cortex-m0', None), rp2350=('cortex-m0', 'armv8-m.main'),
              stm32h753=('cortex-m0', 'armv7e-m'), rp2350_hazard3=('rv32', 'rv32imac'),
              esp32c3=('rv32', 'rv32imc'), esp32c5=('rv32', 'rv32imac'),
              esp32=('xtensa', 'xtensa-esp32'), esp32s3=('xtensa', 'xtensa-esp32s3'))

# The probe each board tool selects by default on the maintainer's rig:
# probehive's UDP slots for the RP chips and the classic ESP32, the
# ST-LINK and the ESP chips' own USB-Serial-JTAG otherwise.
PROBES = dict(rp2040=common.udp_slot('10.42.0.50', 0),
              rp2350=common.udp_slot('10.42.0.50', 1),
              rp2350_hazard3=common.udp_slot('10.42.0.50', 1),
              stm32h753=common.stlink('001900293137511339383538'),
              esp32c3='303a:1001:A0:76:4E:42:57:F8',
              esp32c5='303a:1001:D0:CF:13:E0:87:F0',
              esp32='0000:0002:10.42.0.50/4',
              esp32s3='303a:1001:E8:3D:C1:F5:C4:EC')

# The RAM each board's description gives, by name, for the placement a
# figure is keyed by: where the program's text, data and stack are.
REGIONS = {
    'rp2040': ((0x20000000, 0x20042000, 'sram'),),
    'rp2350': ((0x20000000, 0x20082000, 'sram'),),
    'rp2350_hazard3': ((0x20000000, 0x20082000, 'sram'),),
    'stm32h753': ((0x00000000, 0x00010000, 'itcm'), (0x20000000, 0x20020000, 'dtcm'),
                  (0x24000000, 0x24080000, 'axi-sram'), (0x30000000, 0x30048000, 'sram1-3'),
                  (0x38000000, 0x38010000, 'sram4')),
    'esp32c3': ((0x40380000, 0x403a0000, 'iram'), (0x3fca0000, 0x3fcc8000, 'dram')),
    'esp32c5': ((0x40800000, 0x4084e000, 'hp-sram'),),
    'esp32': ((0x40080000, 0x400a0000, 'iram0'), (0x3ffb0000, 0x3ffd0000, 'dram0')),
    'esp32s3': ((0x40378000, 0x40398000, 'iram'), (0x3fca8000, 0x3fcd0000, 'dram')),
}


def region(board, address):
    for low, high, name in REGIONS[board]:
        if low <= address < high:
            return name
    raise Failed('%#x is in no RAM of %s' % (address, board))


def placement(board, elf):
    """Where the image's text, data and stack are, as `text:R,data:R,stack:R`."""
    _, sections = common.elf_sections(elf)
    names = common.elf_symbols(elf)
    data = next((sections[name][0] for name in ('.data', '.bss') if name in sections
                 and sections[name][2]), names['_landin_firmware_stack_bottom'])
    return 'text:%s,data:%s,stack:%s' % (region(board, sections['.text'][0]), region(board, data),
                                         region(board, names['_landin_firmware_stack_bottom']))


def loaded_digest(elf):
    """The identity of what a board runs: SHA-256 over each loaded
    segment's address, memory and file sizes, flags and bytes, then the
    entry.  Profiles whose
    images load the same bytes differ in their ELF files only by what is
    not loaded, the line and frame tables, and are timed once."""
    data = Path(elf).read_bytes()
    require(data[:6] == b'\x7fELF\x01\x01', 'not an ELF32 LE image: %s' % elf)
    phoff, = struct.unpack_from('<I', data, 0x1c)
    size, count = struct.unpack_from('<HH', data, 0x2a)
    value = hashlib.sha256()
    for index in range(count):
        kind, offset, _, address, filesz, memsz, flags, _ = struct.unpack_from(
            '<8I', data, phoff + index * size)
        if kind == 1 and memsz:
            value.update(struct.pack('<4I', address, memsz, filesz, flags))
            value.update(data[offset:offset + filesz])
    value.update(data[24:28])
    return value.hexdigest()


# Instruction SRAM the helper writes only in whole words (its
# instruction_ram), as the bus allows only aligned four-byte accesses.
INSTRUCTION_RAM = dict(esp32c3=(0x40380000, 0x403a0000), esp32=(0x40080000, 0x400a0000),
                       esp32s3=(0x40378000, 0x40398000))


def refused(board, elf):
    """Why the helper's warm load refuses ELF before any probe opens, for
    the rule a build can meet: a segment of instruction SRAM that is not
    whole words.  None when it does not."""
    if board not in INSTRUCTION_RAM:
        return None
    low, high = INSTRUCTION_RAM[board]
    data = Path(elf).read_bytes()
    phoff, = struct.unpack_from('<I', data, 0x1c)
    size, count = struct.unpack_from('<HH', data, 0x2a)
    for index in range(count):
        kind, _, address, _, filesz, memsz, _, _ = struct.unpack_from('<8I', data, phoff + index * size)
        if kind == 1 and memsz and low <= address < high and (address | filesz | memsz) % 4:
            return ('its instruction SRAM segment at %#x holds %d bytes, not whole words, which the'
                    ' warm load refuses' % (address, filesz))
    return None


def firmware_workloads(selected=None):
    """The firmware set of workloads.json, each with its fixture's status."""
    sys.path.insert(0, str(ROOT / 'compiler/tests'))
    import fixture_meta
    record = json.loads((ROOT / 'compiler/tests/measure/workloads.json').read_text())
    require(record.get('schema') == 1, 'unknown workloads.json schema')
    found = []
    for workload in record.get('firmware', []):
        if selected and workload['name'] not in selected:
            continue
        directory = ROOT / 'compiler/tests/fixtures' / workload['fixture']
        meta = fixture_meta.read(directory)
        found.append(dict(workload, directory=directory, meta=meta))
    missing = sorted(set(selected or ()) - {w['name'] for w in found})
    require(not missing, 'no firmware workload named %s in workloads.json' % ', '.join(missing))
    return found


def sources(workload):
    """The workload's source operands: a rooted fixture's root and its
    `.ldn` files, since the entry joins its module by file (L0002), and
    otherwise its program and `with` files."""
    meta, directory = workload['meta'], workload['directory']
    root = meta.get('root', '')
    if root:
        base = (directory / root).resolve()
        return ['--root=' + str(base)] + [str(p) for p in sorted(directory.glob('*.ldn'))]
    return [str(directory / meta.get('program'))] + [str(directory / one) for one in meta.with_sources]


def build(args):
    output = args.output.resolve()
    bundle.check_output(output, ROOT)
    output.mkdir(parents=True)
    source = bundle.source_identity(ROOT)
    run = common.Run(output)
    refine = args.refine.resolve()
    workloads = firmware_workloads(args.workload)
    manifest = dict(format=FORMAT, source_identity=source['sha256'],
                    compiler=dict(sha256=bundle.sha(refine), name=refine.name), boards={})
    started = time.monotonic()
    for board in args.board or BOARDS:
        target, level = BOARDS[board]
        work = output / 'work' / board
        work.mkdir(parents=True)
        images, limits = {}, []
        for workload in workloads:
            status = workload['meta'].status_at(level or 'armv6-m')
            for profile in args.profile or PROFILES:
                optimize, specialize = profile.split('-')
                stem = '%s-%s' % (workload['name'], profile)
                elf = work / (stem + '.elf')
                run.command('compile-%s-%s' % (board, stem), [
                    refine, 'compile', '--root=' + str(ROOT / 'devices'),
                    '--root=' + str(ROOT / 'devices/generated'), *sources(workload),
                    str(ROOT / ENTRY), str(ROOT / COUNTERS / (board + '.ldn')),
                    '--target=' + target, *(['--level=' + level] if level else []),
                    '--firmware-entry=start', '--emit=exe', '--firmware-layout=ram',
                    '--optimize=' + optimize, '--specialize=' + specialize,
                    '--build-report=' + str(work / (stem + '.json')), '-o', str(elf)],
                    timeout=300)
                common.validate_ram_image(elf, board)
                why = refused(board, elf)
                if why:
                    limits.append(dict(workload=workload['name'], profile=profile, reason=why))
                    continue
                digest = loaded_digest(elf)
                if digest not in images:
                    kept = output / 'images' / board / (digest + '.elf')
                    kept.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(elf, kept)
                    images[digest] = dict(
                        digest=digest, elf_sha256=bundle.sha(kept),
                        elf=kept.relative_to(output).as_posix(),
                        workload=workload['name'], fixture=workload['fixture'], status=status,
                        checksum=workload.get('checksum'), profiles=[],
                        placement=placement(board, elf))
                require(images[digest]['workload'] == workload['name'],
                        'two workloads gave one image: %s' % digest)
                images[digest]['profiles'].append(profile)
        manifest['boards'][board] = dict(target=target, level=level, images=list(images.values()),
                                         limits=limits)
        print('%s: %d images for %d configurations%s' % (
            board, len(images), len(workloads) * len(args.profile or PROFILES),
            ', %d refused' % len(limits) if limits else ''), flush=True)
        for limit in limits:
            print('  %s %s: %s' % (limit['workload'], limit['profile'], limit['reason']))
    manifest['build_seconds'] = round(time.monotonic() - started, 3)
    after = bundle.source_identity(ROOT)
    require(after == source, 'the source changed while building; build again')
    (output / 'commands.json').write_text(json.dumps(run.commands, indent=1) + '\n')
    (output / 'timing.json').write_text(json.dumps(manifest, indent=2) + '\n')
    shutil.rmtree(output / 'work')
    print('bundle: %s' % output)
    return 0


def read_bundle(directory):
    directory = Path(directory).resolve()
    manifest = json.loads((directory / 'timing.json').read_text())
    require(manifest.get('format') == FORMAT, 'not a %s bundle: %s' % (FORMAT, directory))
    for board in manifest['boards'].values():
        for image in board['images']:
            path = directory / image['elf']
            require(path.resolve().is_relative_to(directory) and path.is_file(),
                    'the bundle has no %s' % image['elf'])
            require(bundle.sha(path) == image['elf_sha256'] and loaded_digest(path) == image['digest'],
                    '%s does not match its digests' % path)
    return manifest


def decode_clock(board, clock):
    """The clock a run started from, as {source, hz}: the RP chips' crystal
    the helper selects and the Xtensa chips' crystal its cleanup selects as
    they are; the STM32H753's and the ESP32 RISC-V chips' from their registers.
    A state these do not know is kept by its registers alone, so that a
    change of it is a change of the figure's key rather than a guess."""
    if 'hz' in clock:
        return dict(source=clock['source'], hz=clock['hz'])
    values = {int(address, 16): value for address, value in clock['registers'].items()}
    if board == 'stm32h753':
        cr, cfgr, d1cfgr = values[0x58024400], values[0x58024410], values[0x58024418]
        prescale = (d1cfgr >> 8) & 0xf
        divide = 1 if prescale < 8 else (2, 4, 8, 16, 64, 128, 256, 512)[prescale - 8]
        if (cfgr >> 3) & 7 == 0:  # SWS: HSI
            return dict(source='hsi', hz=(64000000 >> ((cr >> 3) & 3)) // divide)
    if board == 'esp32c3':
        sysclk = values[0x600c0058]
        if (sysclk >> 10) & 3 == 0:  # SOC_CLK_SEL: XTAL, divided by PRE_DIV_CNT + 1
            return dict(source='xtal', hz=40000000 // ((sysclk & 0x3ff) + 1))
    if board == 'esp32c5':
        # ESP-IDF's rtc_clk_cpu_freq_get_config: PCR_SOC_CLK_SEL 0 is the
        # crystal, PCR_CLK_XTAL_FREQ its MHz, PCR_CPU_DIV_NUM + 1 the divider.
        sysclk, cpu = values[0x60096110], values[0x60096118]
        if (sysclk >> 16) & 3 == 0:
            return dict(source='xtal', hz=((sysclk >> 24) & 0x7f) * 1000000 // ((cpu & 0xff) + 1))
    return dict(source='registers', registers=clock['registers'])


def clock_key(clock):
    if clock.get('hz'):
        return '%s-%dhz' % (clock['source'], clock['hz'])
    return 'registers-' + '-'.join('%s=%#x' % item for item in sorted(clock['registers'].items()))


def time_load(run, args, board, image, elf, attempt):
    """One timing run of ELF through the helper, held to its oracle."""
    stem = '%s-%s-%d' % (image['workload'], image['digest'][:12], attempt)
    plan, output = run.out / (stem + '-plan.json'), run.out / (stem + '.json')
    common.write_json(plan, dict(format_version=1, board=board, mode='time', probe=args.probe,
                                 elf=str(elf.resolve()), status=STATUS, seconds=args.seconds,
                                 words=[dict(symbol=BEFORE, count=1), dict(symbol=AFTER, count=1)]
                                 + ([dict(symbol=image['checksum'], count=1)]
                                    if image.get('checksum') else [])))
    args.pace.before('timing load')
    try:
        common.probe_command(run, 'time-' + stem, [args.ram_loader, '--plan', plan,
                                                   '--output', output], timeout=60 + args.seconds)
    except Failed as error:
        said = json.loads(output.read_text()).get('error') if output.is_file() else None
        raise Failed('%s: %s' % (stem, said or error)) from error
    report = json.loads(output.read_text())
    require(report.get('format_version') == 1 and report.get('status') == 'passed'
            and report.get('mode') == 'time' and report.get('flash_written') is False
            and report.get('board') == board and report.get('elf_sha256') == image['elf_sha256']
            and report.get('helper_source_sha256') == common.helper_source_hash(),
            '%s: the helper did not return matching timing evidence' % stem)
    args.pace.before('timing load completion')
    args.pace.after('timing load')
    timed = report['timing']
    require(timed['status'] == image['status'], '%s: the program returned %d, expected %d'
            % (stem, timed['status'], image['status']))
    if image.get('checksum'):
        # The program checks its own checksum before it returns its status;
        # the word is kept, as the instruction counts keep it.
        timed['checksum'] = timed['words'][image['checksum']][0]
    # The figure is what the program read around `main`; the probe's own
    # span, from its zeroing to its read at the stop, is kept beside it.
    timed['probe_count'] = timed.pop('count')
    count = (timed['words'][AFTER][0] - timed['words'][BEFORE][0]) % (1 << 32)
    require(count < LIMIT, '%s: the count %d is past 2^31' % (stem, count))
    hz = decode_clock(board, timed['clock']).get('hz')
    rate = 1e6 if timed['unit'] == 'microseconds' else hz
    require(not rate or timed['host_seconds'] * rate < LIMIT,
            '%s: the program ran %.3f s, long enough for its counter to pass 2^31'
            % (stem, timed['host_seconds']))
    timed['count'] = count
    return timed


def run_board(args):
    board = args.board
    manifest = read_bundle(args.bundle)
    require(board in manifest['boards'], 'the bundle has no %s images' % board)
    images = [image for image in manifest['boards'][board]['images']
              if (not args.image or image['digest'] in args.image or image['workload'] in args.image)
              and (not args.profile or set(args.profile) & set(image['profiles']))]
    require(images, 'no image of the bundle is selected')
    args.output = args.output.resolve()
    args.output.mkdir(parents=True)
    args.probe = args.probe or PROBES[board]
    args.mode = 'ram'
    args.pace = common.Pace(args.spacing, args.quiet)
    require(args.ram_loader, 'no SRAM helper: name one with --ram-loader')
    common.verify_ram_helper(args)
    pico = board in ('rp2350', 'rp2350_hazard3')
    if pico:
        require(args.hub and args.port and args.power_only,
                'the Pico 2 runs from the rig only on its power-only cable: name --hub, --port and'
                ' --power-only as rig.json does', common.NeedsSetup)
        common.place_hubs(args, 'hub')
    run = common.Run(args.output)
    run.pace = args.pace
    result = dict(status='failed', mode='time', board=board, bundle_source=manifest['source_identity'],
                  compiler=manifest['compiler'], probe=args.probe, repeat=args.repeat, images=[],
                  limits=manifest['boards'][board].get('limits', []))
    began = time.monotonic()
    lock = common.rig_lock('timing.py %s' % board)
    try:
        lock.acquire()
        for image in images:
            if pico:
                import pico2
                pico2.refuse_bootsel(common.InGroup(run, args.hub_group), args, False)
            elf = Path(args.bundle).resolve() / image['elf']
            runs = [time_load(run, args, board, image, elf, attempt)
                    for attempt in range(1, args.repeat + 1)]
            counts = [one['count'] for one in runs]
            clock = decode_clock(board, runs[0]['clock'])
            require(all(decode_clock(board, one['clock']) == clock for one in runs),
                    '%s: the clock changed between runs' % image['workload'])
            checksums = {one.get('checksum') for one in runs}
            require(len(checksums) == 1, '%s: the checksum changed between runs: %s'
                    % (image['workload'], sorted(checksums)))
            row = dict(workload=image['workload'], digest=image['digest'], profiles=image['profiles'],
                       placement=image['placement'], counter=runs[0]['counter'], unit=runs[0]['unit'],
                       clock=clock, clock_key=clock_key(clock), counts=counts,
                       median=statistics.median_low(counts), minimum=min(counts), maximum=max(counts),
                       probe_counts=[one['probe_count'] for one in runs],
                       halted_drift=[one['halted_drift'] for one in runs],
                       host_seconds=[round(one['host_seconds'], 6) for one in runs],
                       setup=runs[0]['setup'], **({'checksum': '%#010x' % runs[0]['checksum']}
                                                  if image.get('checksum') else {}))
            result['images'].append(row)
            print('%s %s %s: %s %s, median %s (%s..%s)' % (
                board, image['workload'], ','.join(image['profiles']), row['counter'],
                row['unit'], row['median'], row['minimum'], row['maximum']), flush=True)
        result['status'] = 'passed'
    except (Failed, OSError, subprocess.TimeoutExpired) as error:
        common.fail(result, error)
    finally:
        common.retain_kernel_usb(args.pace, result)
        lock.release()
        result['seconds'] = round(time.monotonic() - began, 3)
        result['commands'] = run.commands
        common.write_result(args.output / 'result.json', result, run)
    print('timing %s: %s%s' % (board, result['status'], '' if result['status'] == 'passed'
                                 else ': ' + result['failure']))
    return 0 if result['status'] == 'passed' else 1


def noise(args):
    """The noise study's record from timing runs' results: per board, each
    workload's counts at one profile and their spread."""
    boards = {}
    for directory in args.results:
        for path in sorted(Path(directory).glob('*/result.json')):
            result = json.loads(path.read_text())
            require(result.get('status') == 'passed', '%s did not pass' % path)
            board = result['board']
            require(board not in boards, '%s is in two results' % board)
            target, level = BOARDS[board]
            rows = {}
            for image in result['images']:
                counts = image['counts']
                require(len(counts) >= args.least, '%s %s has %d runs, fewer than %d'
                        % (board, image['workload'], len(counts), args.least))
                spread, median = max(counts) - min(counts), statistics.median_low(counts)
                rows[image['workload']] = dict(
                    digest=image['digest'], profiles=image['profiles'], runs=len(counts),
                    median=median, minimum=min(counts), maximum=max(counts),
                    spread=spread, relative_spread=round(spread / median, 6),
                    counts=counts)
            first = result['images'][0]
            boards[board] = dict(
                target=target, level=level, counter=first['counter'], unit=first['unit'],
                clock=first['clock_key'], placement=first['placement'],
                compiler=result['compiler']['sha256'], bundle_source=result['bundle_source'],
                seconds=result['seconds'], workloads=rows,
                largest_relative_spread=max(row['relative_spread'] for row in rows.values()))
    require(boards, 'no results under %s' % ', '.join(map(str, args.results)))
    record = dict(schema=1, kind='cycles', runner='rig', note=args.note, boards=dict(sorted(boards.items())))
    if Path(args.output).exists():
        # The tolerance set above the spread is a decision, kept across a
        # new study until it is set again.
        kept = json.loads(Path(args.output).read_text())
        record.update({key: kept[key] for key in ('tolerance_rule', 'tolerance') if key in kept})
    Path(args.output).write_text(json.dumps(record, indent=1) + '\n')
    for board, row in sorted(boards.items()):
        print('%-15s %-11s %-12s largest relative spread %.4f%%' % (
            board, row['counter'], row['unit'], 100 * row['largest_relative_spread']))
    return 0


def latest_legs(root):
    """Each board leg's time results under ROOT, a directory of the gate's
    board-evidence artifacts, from the latest attempt of each port: the
    leg's transfer.json names its port and attempt, and gate.py writes each
    time step's output as evidence/BOARD-time."""
    legs = {}
    for transfer in sorted(Path(root).rglob('transfer.json')):
        try:
            leg = json.loads(transfer.read_text())
            port, attempt = leg['port'], int(leg['run_attempt'])
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if attempt >= legs.get(port, (0, None))[0]:
            legs[port] = (attempt, transfer.parent)
    return sorted(path for _, directory in legs.values()
                  for path in (directory / 'evidence').glob('*-time*/result.json'))


def figures(args):
    """Every configuration's figure from timing runs' results, keyed as
    `board/level/profile/workload` with its counter, clock and placement;
    a configuration whose image another profile also gave cites its digest."""
    paths = [path for directory in args.results or ()
             for path in sorted(Path(directory).glob('*/result.json'))]
    paths += latest_legs(args.evidence) if args.evidence else []
    found = {}
    for path in paths:
        result = json.loads(path.read_text())
        require(result.get('status') == 'passed', '%s did not pass' % path)
        board = result['board']
        _, level = BOARDS[board]
        for image in result['images']:
            for profile in image['profiles']:
                key = '%s/%s/%s/%s' % (board, level or 'armv6-m', profile, image['workload'])
                require(key not in found, '%s is in two results' % key)
                found[key] = dict(figure=statistics.median_low(image['counts']),
                                  unit=image['unit'], counter=image['counter'],
                                  clock=image['clock_key'], placement=image['placement'],
                                  runs=len(image['counts']), spread=max(image['counts'])
                                  - min(image['counts']), image=image['digest'],
                                  compiler=result['compiler']['sha256'],
                                  **({'checksum': image['checksum']} if 'checksum' in image else {}))
        for limit in result.get('limits', []):
            key = '%s/%s/%s/%s' % (board, level or 'armv6-m', limit['profile'], limit['workload'])
            found[key] = dict(limit=limit['reason'])
    require(found, 'no time results in %s' % ', '.join(map(str, list(args.results or ())
                                                           + ([args.evidence] if args.evidence else []))))
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_text(json.dumps(dict(schema=1, kind='cycles', figures=dict(
        sorted(found.items()))), indent=1) + '\n')
    print('%d configurations, %d limits: %s' % (len(found), sum('limit' in v for v in found.values()),
                                                args.output))
    return 0


BASELINES = ROOT / 'compiler/tests/measure/baselines'
NOISE = ROOT / 'compiler/tests/measure/noise/cycles.json'


def baseline_path(board):
    return BASELINES / ('%s.cycles.json' % board)


def read_baseline(board, rev=None):
    """BOARD's committed cycles baseline, at REV or as the checkout has it."""
    path = baseline_path(board)
    if rev is None:
        return json.loads(path.read_text()) if path.exists() else {}
    shown = subprocess.run(['git', 'show', '%s:%s' % (rev, path.relative_to(ROOT).as_posix())],
                           cwd=ROOT, capture_output=True, text=True)
    return json.loads(shown.stdout) if shown.returncode == 0 else {}


def tolerances():
    """{board: (relative, absolute)} from the noise study's record: a figure
    within the larger of the two of its baseline is the same figure."""
    record = json.loads(NOISE.read_text()) if NOISE.exists() else {}
    return {board: (one['relative'], one['absolute'])
            for board, one in record.get('tolerance', {}).items()}


def within(old, new, tolerance):
    relative, absolute = tolerance
    return abs(new - old) <= max(relative * old, absolute)


def split(key):
    board, rest = key.split('/', 1)
    return board, rest


def compare(args):
    """The figures against the base commit's baselines.  A figure beyond
    its board's tolerance, slower or faster, fails unless the candidate's
    own baseline records it; so does a configuration with no baseline, a
    changed placement or a changed limit.  A changed clock is the runner's,
    not the code's: it is reported for recording and does not fail."""
    measured = json.loads(Path(args.figures).read_text())
    require(measured.get('kind') == 'cycles', '%s holds no cycles figures' % args.figures)
    if args.base:
        base = args.base
    else:
        sys.path.insert(0, str(ROOT / 'scripts'))
        import measure
        base = measure.default_base()
    allowed = tolerances()
    before, after = {}, {}
    undeclared, declared, unrecorded, clocks, ok = [], [], [], [], 0
    for key, figure in sorted(measured['figures'].items()):
        board, name = split(key)
        if board not in before:
            before[board] = read_baseline(board, base).get('entries', {})
            after[board] = read_baseline(board).get('entries', {})
        old, new = before[board].get(name), after[board].get(name)
        tolerance = allowed.get(board, (0.0, 0))

        def same(entry):
            if entry is None:
                return False
            if 'limit' in figure or 'limit' in entry:
                return entry.get('limit') == figure.get('limit')
            return (entry['placement'] == figure['placement'] and entry['clock'] == figure['clock']
                    and within(entry['cycles'], figure['figure'], tolerance))
        if same(old):
            ok += 1
        elif old is not None and 'limit' not in old and 'limit' not in figure \
                and old['clock'] != figure['clock']:
            clocks.append('%s: the base ran at %s, this at %s' % (key, old['clock'], figure['clock']))
        elif same(new):
            declared.append((key, old, figure))
        elif old is None:
            unrecorded.append(key)
        else:
            undeclared.append((key, old, figure))

    def change(old, figure):
        if old is None:
            return 'new'
        if 'limit' in old or 'limit' in figure:
            return '%s -> %s' % (old.get('limit', old.get('cycles')), figure.get('limit', figure.get('figure')))
        moved = '' if old['placement'] == figure['placement'] else ', placement %s -> %s' % (
            old['placement'], figure['placement'])
        return '%d -> %d (%+.2f%%)%s' % (old['cycles'], figure['figure'],
                                        100.0 * (figure['figure'] - old['cycles']) / old['cycles'], moved)
    for title, rows in (('declared by the candidate\'s baselines', declared), ('UNDECLARED', undeclared)):
        if rows:
            print('%s: %d configurations' % (title, len(rows)))
            for key, old, figure in rows:
                print('  %s: %s' % (key, change(old, figure)))
    if clocks:
        print('the runner changed: these ran at another clock than their baseline, so they are'
              ' recorded again rather than compared (timing.py record):')
        for line in clocks:
            print('  ' + line)
    if unrecorded:
        print('UNRECORDED: %d configurations have no baseline, such as %s' % (len(unrecorded), unrecorded[0]))
    print('compared %d configurations\' cycles with %s: %d within tolerance, %d declared, %d undeclared,'
          ' %d unrecorded, %d at another clock' % (len(measured['figures']), base, ok, len(declared),
                                                  len(undeclared), len(unrecorded), len(clocks)))
    if undeclared or unrecorded:
        print('a deliberate change is declared by recording it: environments/boards/timing.py record'
              ' FIGURES.json, the figures a gate run kept as its measure-cycles artifact, and the'
              ' commit message says why', file=sys.stderr)
        return 1
    return 0


def record(args):
    """Write the figures into each board's baseline: the whole board's
    record unless --key names the configurations to write."""
    measured = json.loads(Path(args.figures).read_text())
    require(measured.get('kind') == 'cycles', '%s holds no cycles figures' % args.figures)
    wanted = set(args.key or ())
    boards = {}
    for key, figure in measured['figures'].items():
        board, name = split(key)
        if (args.board and board not in args.board) or (wanted and key not in wanted):
            continue
        boards.setdefault(board, {})[name] = (
            dict(limit=figure['limit']) if 'limit' in figure else dict(
                cycles=figure['figure'], unit=figure['unit'], counter=figure['counter'],
                clock=figure['clock'], placement=figure['placement'], image=figure['image'],
                runs=figure['runs'], **({'checksum': figure['checksum']} if 'checksum' in figure else {})))
    require(boards, 'no figures selected in %s' % args.figures)
    BASELINES.mkdir(parents=True, exist_ok=True)
    written = 0
    for board, entries in sorted(boards.items()):
        target, level = BOARDS[board]
        current = read_baseline(board) or dict(schema=1, kind='cycles', board=board, target=target,
                                               level=level or 'armv6-m', entries={})
        if not wanted:
            # A whole record is the board's whole baseline: a configuration
            # no workload measures any more goes with it.
            current['entries'] = {}
        current['entries'].update(entries)
        current['entries'] = dict(sorted(current['entries'].items()))
        baseline_path(board).write_text(json.dumps(current, indent=1) + '\n')
        written += len(entries)
    print('recorded %d configurations under %s' % (written, BASELINES))
    return 0


def remote(args, board_args):
    """Copy the bundle and a matching source snapshot to the rig host, run
    each board there in turn, and retrieve every result."""
    sys.path.insert(0, str(HERE))
    import run as wrapper
    read_bundle(args.bundle)
    output = args.output.resolve()
    bundle.check_output(output, ROOT)
    output.mkdir(parents=True)
    stage = output / 'prepared'
    stage.mkdir()
    shutil.copytree(Path(args.bundle).resolve(), stage / 'bundle')
    bundle.snapshot(stage / 'source', ROOT)
    ssh = ['ssh', '-i', str(args.identity.expanduser()), '-o', 'BatchMode=yes', args.host]
    scp = ['scp', '-i', str(args.identity.expanduser()), '-o', 'BatchMode=yes']
    made = subprocess.run(ssh + ['umask 077; mktemp -d /tmp/landin-timing.XXXXXXXX'],
                          capture_output=True, text=True)
    remote_dir = made.stdout.strip()
    require(made.returncode == 0 and re.fullmatch(r'/tmp/landin-timing\.[A-Za-z0-9]+', remote_dir),
            'remote staging failed: %s' % made.stderr.strip())
    started = time.monotonic()
    transfer = dict(host=args.host, directory=remote_dir, boards={})
    try:
        require(wrapper.transport(scp + ['-r', str(stage), args.host + ':' + remote_dir + '/prepared'],
                                  output / 'copy.log') == 0, 'copy failed; see copy.log')
        tool = remote_dir + '/prepared/source/environments/boards/timing.py'
        for board in args.board or BOARDS:
            command = ['python3', tool, 'run', '--board=' + board, '--bundle=' + remote_dir
                       + '/prepared/bundle', '--output=' + remote_dir + '/' + board,
                       '--repeat=%d' % args.repeat] + [
                '--profile=' + profile for profile in args.profile or ()] + [
                '--image=' + image for image in args.image or ()] + (
                ['--ram-loader=' + args.ram_loader] if args.ram_loader else []) + list(board_args)
            if board in ('rp2350', 'rp2350_hazard3'):
                # The Pico 2's place on the rig, as rig.json gives the gate it.
                place = json.loads((HERE / 'rig.json').read_text())['ports']['pico2']['location']
                require(place and place.get('hub') and place.get('port'),
                        'rig.json gives the Pico 2 no location', common.NeedsSetup)
                command += ['--hub=' + place['hub'], '--port=%d' % place['port'], '--power-only']
            tick = time.monotonic()
            status = wrapper.transport(ssh + [shlex.join(command)], output / (board + '-run.log'),
                                       live=True)
            copied = wrapper.transport(scp + ['-r', args.host + ':' + remote_dir + '/' + board,
                                              str(output / board)], output / (board + '-retrieve.log'))
            transfer['boards'][board] = dict(exit_status=status, retrieval_status=copied,
                                             seconds=round(time.monotonic() - tick, 3))
    finally:
        transfer['seconds'] = round(time.monotonic() - started, 3)
        wrapper.transport(ssh + ['rm -rf -- ' + shlex.quote(remote_dir)], output / 'remote-cleanup.log')
        (output / 'transfer.json').write_text(json.dumps(transfer, indent=2) + '\n')
    failed = [b for b, one in transfer['boards'].items() if one['exit_status'] or one['retrieval_status']]
    print('timing: %s; results %s' % ('failed: ' + ', '.join(failed) if failed else 'passed', output))
    return 1 if failed else 0


def main(argv=None):
    arguments = list(sys.argv[1:] if argv is None else argv)
    board_args = []
    if '--' in arguments:
        split = arguments.index('--')
        arguments, board_args = arguments[:split], arguments[split + 1:]
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    made = commands.add_parser('build', help='compile every workload at every profile for each board')
    made.add_argument('--refine', type=Path, required=True)
    made.add_argument('--output', type=Path, required=True, help='a new directory')
    made.add_argument('--board', choices=BOARDS, action='append', help='repeat; default every board')
    made.add_argument('--workload', action='append', help='repeat; default the whole firmware set')
    made.add_argument('--profile', choices=PROFILES, action='append', help='repeat; default all nine')
    timed = commands.add_parser('run', help="time one board's images, on the rig host")
    timed.add_argument('--bundle', type=Path, required=True)
    timed.add_argument('--board', choices=BOARDS, required=True)
    timed.add_argument('--output', type=Path, required=True, help='a new directory')
    timed.add_argument('--repeat', type=int, default=1, help='runs of each image')
    timed.add_argument('--image', action='append', help='an image digest or workload name; repeat')
    timed.add_argument('--profile', choices=PROFILES, action='append',
                       help='only the images one of these profiles gave; repeat')
    timed.add_argument('--seconds', type=int, default=20, help='how long a program may take to stop')
    timed.add_argument('--ram-loader', type=Path, default=common.RIG_STATE / 'bin/landin-ram-run')
    timed.add_argument('--probe', help="probe-rs's selector; the board tool's default otherwise")
    timed.add_argument('--hub', help="the Pico 2's hub, relative to the cascade as rig.json names it")
    timed.add_argument('--port', type=int, help="the Pico 2's port")
    timed.add_argument('--power-only', action='store_true',
                       help="the Pico 2's cable carries no USB data (rig.json's pico2 steps)")
    timed.add_argument('--hub-group', default='dialout')
    common.cascade_argument(timed)
    common.pace_arguments(timed)
    wrapped = commands.add_parser('remote', help='run boards on the rig host from here')
    wrapped.add_argument('--bundle', type=Path, required=True)
    wrapped.add_argument('--output', type=Path, required=True, help='a new directory')
    wrapped.add_argument('--board', choices=BOARDS, action='append', help='repeat; default every board')
    wrapped.add_argument('--repeat', type=int, default=1)
    wrapped.add_argument('--profile', choices=PROFILES, action='append',
                         help='only the images one of these profiles gave; repeat')
    wrapped.add_argument('--image', action='append', help='an image digest or workload name; repeat')
    wrapped.add_argument('--ram-loader', help="the helper's path on the rig host; the rig state's"
                                              ' by default')
    wrapped.add_argument('--host', default='jan@10.42.0.60')
    wrapped.add_argument('--identity', type=Path, default=Path('~/.ssh/epycmicro-2026-09-17'))
    studied = commands.add_parser('noise', help="write the noise study's record from run results")
    studied.add_argument('--results', type=Path, action='append', required=True,
                         help="a `remote` output directory, or a directory of `run` outputs; repeat")
    studied.add_argument('--output', type=Path, required=True)
    studied.add_argument('--least', type=int, default=10, help='fewest runs an image may have')
    studied.add_argument('--note', default='', help='what the record is, kept in it')
    listed = commands.add_parser('figures', help="every configuration's figure from run results")
    listed.add_argument('--results', type=Path, action='append',
                        help="a `remote` output directory, or a directory of `run` outputs; repeat")
    listed.add_argument('--evidence', type=Path,
                        help="the gate's board-evidence artifacts, each port's latest attempt")
    listed.add_argument('--output', type=Path, required=True)
    held = commands.add_parser('compare', help="hold figures to the base commit's baselines")
    held.add_argument('figures', type=Path)
    held.add_argument('--base', help="the commit compared with; measure.py's base by default")
    kept = commands.add_parser('record', help='write figures as the baselines')
    kept.add_argument('figures', type=Path)
    kept.add_argument('--board', choices=BOARDS, action='append', help='only this board; repeat')
    kept.add_argument('--key', action='append', help='only this BOARD/LEVEL/PROFILE/WORKLOAD; repeat')
    args = parser.parse_args(arguments)
    if args.command == 'noise':
        return noise(args)
    if args.command == 'figures':
        require(args.results or args.evidence, 'name --results or --evidence')
        return figures(args)
    if args.command == 'compare':
        return compare(args)
    if args.command == 'record':
        return record(args)
    if args.command == 'build':
        common.warn_stale_refine(args)  # is it this checkout's?
        return build(args)
    if args.command == 'remote':
        return remote(args, board_args)
    require(not board_args, 'run takes no arguments after --')
    return run_board(args)


if __name__ == '__main__':
    sys.exit(common.tool_main(main))
