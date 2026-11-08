#!/usr/bin/env python3
"""Prototype 5's firmware counterpart on QEMU's micro:bit, its trace judged (D448).

The complete program under compiler/tests/counterpart takes request lines
on prototype 1's synthetic UART and answers them one at a time, in the
order they came, from two fibres over core/fibre's round of turns.  Each
scenario feeds lines while the program runs, `NOW b` once `WAIT 200 a` is
being answered, so the request for two operations in flight is presented,
and reads back what the device wrote and its own trace: each request's
arrival, the start and the end of its answering, and each refusal, with the
SysTick tick it happened at.  `judge` is the oracle, independent of the
firmware: every answer present and right, in request order, none started
before the one before it finished, no wait answered early, no refusal but
for a full queue, no trap, no timeout.  The controls build the same source
with one mutation each and require the oracle, or the session, to fail it
for the reason the mutation makes.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import shutil
import sys
from backend import LANE_ROOT, derived
from machine import Machine, Trapped
from models import DriverPeripheral
from packed_native import PROFILES
from run import Run, require, workers
from setup import DEFAULT, installed_tools, inventory, sha, supported_host

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = ROOT / 'compiler/tests/counterpart'
#  What the program is made of, staged into one root as the driver lane
#  stages prototype 1's: the counterpart's own modules, the protocol the
#  hosted server shares, prototype 1's receive driver, its device's
#  generated registers, the library and the micro:bit's lane description.
STAGED = (('firmware', SOURCE), ('app/protocol', ROOT / 'examples/derived_server'),
          ('drivers/uart', ROOT / 'compiler/tests/driver'),
          ('rp2040/uart0', ROOT / 'devices/generated'), ('rp2040/dma', ROOT / 'devices/generated'),
          ('rp2040/io_bank0', ROOT / 'devices/generated'), ('core', ROOT),
          ('platform/cortex_m', ROOT), ('descriptions/microbit', LANE_ROOT))
DEVICE = 'microbit'
#  The synthetic device prototype 1's driver drives (models.DriverPeripheral).
MODEL_BASE, MODEL_SIZE = 0x40070000, 0x2000
#  A tick is a millisecond of the emulator's clock (firmware/tick), which
#  under machine.py's -icount reaches the next tick across each stop the
#  harness makes at an access to the synthetic device: a trace's ticks
#  order its events and bound each wait from below, and do not measure how
#  long the firmware's own instructions took.  A scenario ends once every line
#  it fed has been answered and QUIET more ticks have passed with nothing
#  more written, or at DEADLINE ticks after the first line, whatever the
#  trace then holds; a firmware that stops making progress, so that no
#  stop comes within BUDGET seconds, has timed out.
QUIET, DEADLINE, BUDGET = 50, 3000, 5
#  firmware/trace's kinds and firmware/app's queue depth and longest line.
RECEIVED, STARTED, FINISHED, REFUSED = 1, 2, 3, 4
KINDS = {RECEIVED: 'received', STARTED: 'started', FINISHED: 'finished', REFUSED: 'refused'}
DEPTH, LONGEST, LONGEST_WAIT = 4, 64, 60000
PAINT = 0xa5

#  What each scenario feeds and when: once the receiver is running, or once
#  the request numbered N has started being answered.  `presented` names
#  the pairs (first, second) whose second request must arrive while the
#  first is being answered: the request for two operations in flight.
SCENARIOS = {
    'two-in-flight': {'feed': [('ready', b'WAIT 200 a\n'), (('started', 1), b'NOW b\n')],
                      'presented': [(1, 2)]},
    'queue-full': {'feed': [('ready', b'WAIT 200 a\n'),
                            (('started', 1), b'NOW b\nNOW c\nNOW d\nNOW e\nNOW f\n')],
                   'presented': [(1, 2)]},
    'refusals': {'feed': [('ready', b'NOW\n' + b'NOW ' + b'x' * 70 + b'\n' + b'WAIT 5 z\r\n')],
                 'presented': []},
}

#  Each control: the mutation applied to firmware/app's source, as exact
#  replacements each of which must match once, the scenario it runs and
#  the failure it must produce.
CONTROLS = {
    #  Two answerers over the same queue: D448's declined alternative,
    #  answers overlapping through turns.
    'overlap': {'scenario': 'two-in-flight', 'fails': 'overlap', 'replace': [
        ('mut fibre_backing: [2 * 2048 + 48]u8', 'mut fibre_backing: [3 * 2048 + 48]u8'),
        ('mut round_entries: [3]usize', 'mut round_entries: [4]usize'),
        ('fibre.turns_over(runs, fibre_backing, 2)', 'fibre.turns_over(runs, fibre_backing, 3)'),
        ('    fibre.join(both) else (problem)',
         '    second: answerer = (send: port, device: device)\n'
         '    fibre.admit(both, answer_lines, second) else (problem)\n'
         '        _ = problem\n'
         '        halt(3)\n'
         '    end\n'
         '    fibre.join(both) else (problem)')]},
    #  The second request's answering runs and its answer is never written.
    'missing': {'scenario': 'two-in-flight', 'fails': 'missing answer', 'replace': [
        ('            try protocol.answer(self.device, out, asked)',
         '            if number <> 2 then\n'
         '                try protocol.answer(self.device, out, asked)\n'
         '            end if')]},
    #  A take reads one row past the queue, which its bounds check traps.
    'trap': {'scenario': 'two-in-flight', 'fails': 'trap', 'replace': [
        ('                line[i] = queue.lines[at][i]',
         '                line[i] = queue.lines[at + depth][i]')]},
    #  SysTick never starts, so the first sleep never ends and the idle
    #  round's wait for an interrupt never returns.
    'timeout': {'scenario': 'two-in-flight', 'fails': 'timeout', 'replace': [
        ('    tick.start_counting()\n', '')]},
}


def build(run, refine, optimize, specialize, mutation=None):
    """Stage the program, apply MUTATION's replacements, and link it."""
    source = run.out / 'source'
    for module, origin in STAGED:
        shutil.copytree(origin / module, source / module)
    shutil.copy(LANE_ROOT / 'lane-microbit.ldn', source / 'firmware/app/lane-microbit.ldn')
    if mutation is not None:
        path = source / 'firmware/app/main.ldn'
        text = path.read_text()
        for old, new in CONTROLS[mutation]['replace']:
            require(text.count(old) == 1, 'control %s: its mutation does not match the source once: %r'
                    % (mutation, old))
            text = text.replace(old, new)
        path.write_text(text)
    elf = run.out / 'core.elf'
    run.command('compile', [refine, '--root=source', '--library=source', '--target=cortex-m0',
        '--firmware-entry=start', '--emit=exe', '--debug=none',
        '--toolchain=' + str(run.arm / 'arm-eabi-gcc'),
        '--optimize=' + optimize, '--specialize=' + specialize, '--build-report=build.json',
        'source/firmware/app/main.ldn', 'source/firmware/app/lane-microbit.ldn',
        '-o', elf.name], timeout=120)
    attributes = run.command('elf', [run.arm / 'arm-eabi-readelf', '-h', '-A', '-l', elf])
    require('Tag_CPU_arch: v6S-M' in attributes and 'Tag_THUMB_ISA_use: Thumb-1' in attributes,
            'counterpart ELF is not the selected ARMv6-M profile')
    require(not run.command('undefined', [run.arm / 'arm-eabi-nm', '-u', elf]).strip(),
            'unresolved counterpart symbol')
    names = run.command('symbols', [run.arm / 'arm-eabi-nm', '-S', '-n', elf])
    symbols, sizes = {}, {}
    for line in names.splitlines():
        part = line.split()
        if len(part) == 4:
            symbols[part[3]], sizes[part[3]] = int(part[0], 16), int(part[1], 16)
        elif len(part) == 3:
            symbols[part[2]] = int(part[0], 16)
    report = json.loads((run.out / 'build.json').read_text())
    firmware = report['firmware']
    want = derived(run, refine, DEVICE)
    differ = sorted(k for k in ('device', 'regions', 'placed', 'vector_address', 'vector_words',
                                'stack_reserved') if firmware[k] != want[k])
    require(not differ, 'the counterpart was not linked to the micro:bit description: ' + ', '.join(differ))
    return elf, symbols, sizes, firmware


def take(m, symbols):
    """The trace the firmware recorded: its events, and whether it lost any."""
    count = m.u32(symbols['count'])
    raw = m.read(symbols['events'], 8 * min(count, 32))
    events = [{'at': int.from_bytes(raw[i:i + 4], 'little'), 'kind': KINDS.get(raw[i + 4], raw[i + 4]),
               'request': raw[i + 5]} for i in range(0, len(raw), 8)]
    return events, m.u32(symbols['lost'])


def session(run, elf, symbols, sizes, name, scenario, fibres=2):
    """Run SCENARIO on QEMU's micro:bit and return what was observed.

    The outcome is `settled` when every line fed was answered and the
    device then stayed quiet, `deadline` when DEADLINE ticks passed first,
    `trap: NAME` at a fault, `stopped: STEP` when the firmware halted, and
    `timeout` when it stopped making progress.
    """
    plan = list(SCENARIOS[scenario]['feed'])
    lines = sum(part.count(b'\n') for _, part in plan)
    m = Machine(run, elf, name, idle=False)
    model = DriverPeripheral()
    observed = {'scenario': scenario, 'fed': [], 'outcome': None}
    with m:
        m.map(MODEL_BASE, MODEL_SIZE, model)
        m.trap(symbols['_landin_firmware_unhandled'], 'unhandled exception')
        #  Paint the fibres' backing and the main stack before anything
        #  runs on them: each fibre's peak is read below its stack's top.
        m.run_to(symbols['start'], 'start')
        backing, size = symbols['fibre_backing'], sizes['fibre_backing']
        m.write(backing, bytes([PAINT]) * size)
        sp = m.register('sp')
        m.write(0x20003000, bytes([PAINT]) * (sp - 0x20003000 - 64))
        first = last_write = None
        try:
            while True:
                now = m.u32(symbols['ticks'])
                if plan:
                    when, part = plan[0]
                    events, _ = take(m, symbols)
                    ready = (model.busy if when == 'ready' else
                             any(e['kind'] == 'started' and e['request'] == when[1] for e in events))
                    #  The model takes a byte only while the driver's DMA
                    #  channel is enabled, and the driver disables it while
                    #  it reads the count, so a line is fed between reads.
                    if ready and model.configuration & 1:
                        plan.pop(0)
                        for value in part:
                            model.feed(value)
                        observed['fed'].append({'at': now, 'bytes': part.decode()})
                        first = now if first is None else first
                if m.u32(symbols['stopped']):
                    observed['outcome'] = 'stopped: %d' % m.u32(symbols['stopped'])
                    break
                if len(model.output_bytes) != (last_write or (0, 0))[0]:
                    last_write = (len(model.output_bytes), now)
                answered = bytes(model.output_bytes).count(b'\n')
                if not plan and answered >= lines and now - last_write[1] >= QUIET:
                    observed['outcome'] = 'settled'
                    break
                if first is not None and now - first >= DEADLINE:
                    observed['outcome'] = 'deadline'
                    break
                m.step(BUDGET)
        except Trapped as trapped:
            observed['outcome'] = 'trap: %s' % trapped
        except RuntimeError as error:
            if 'no stop within' not in str(error):
                raise
            observed['outcome'] = 'timeout'
        observed['ticks'], observed['stops'] = m.u32(symbols['ticks']), m.stops
        observed['events'], observed['lost'] = take(m, symbols)
        observed['output'] = bytes(model.output_bytes).decode(errors='replace')
        observed['rejected'] = model.rejected
        painted = m.read(backing, size)
        observed['backing_untouched'] = painted.count(bytes([PAINT]))
        main = m.read(0x20003000, 4096)
        observed['main_stack_painted'] = 4096 - next(
            (i for i, b in enumerate(main) if b != PAINT), 4096)
        observed['fibre_peaks'] = fibre_peaks(backing, painted, fibres)
    return observed


def fibre_peaks(address, painted, count):
    """Each fibre's deepest write below its stack's top, read from the paint
    of a backing at ADDRESS that core/fibre's group cut into COUNT equal
    stacks: from its first 16-byte boundary, past the ledger's 32 bytes,
    each stack with its record at its base, which the group writes."""
    skip = (16 - address % 16) % 16
    size = (len(painted) - skip - 32) // count // 16 * 16
    peaks = []
    for index in range(count):
        base = skip + 32 + index * size
        region = painted[base:base + size]
        untouched = next((i for i, b in enumerate(region[64:], 64) if b != PAINT), size)
        peaks.append(size - untouched)
    return peaks


def answer_of(line):
    """What the protocol answers LINE, without its ending: app/protocol's
    rules, written again here rather than read from the firmware."""
    if len(line) > LONGEST:
        return 'malformed', 0
    words = line.split(b' ')
    if len(words) == 3 and words[0] == b'WAIT' and words[1].isdigit() and words[2]:
        wait = int(words[1])
        return (words[2].decode() + ' done', wait) if wait <= LONGEST_WAIT else ('malformed', 0)
    if len(words) == 2 and words[0] == b'NOW' and words[1]:
        return words[1].decode() + ' done', 0
    return 'malformed', 0


def judge(observed, presented=()):
    """The oracle: the problems with one run, empty when it gave the
    single-core answer (D448).  Each problem starts with its kind."""
    problems = []
    outcome = observed['outcome']
    if outcome.startswith('trap'):
        problems.append('trap: the firmware reached %s' % outcome[6:])
    elif outcome == 'timeout':
        problems.append('timeout: the firmware stopped making progress at tick %d'
                        % observed.get('ticks', 0))
    elif outcome.startswith('stopped'):
        problems.append('stopped: the firmware halted at its step %s' % outcome[9:])
    if observed['lost']:
        problems.append('lost: the trace overflowed')
    if observed.get('rejected'):
        problems.append('lost: the device refused %d bytes fed to it' % observed['rejected'])
    fed = []
    for part in observed['fed']:
        fed += [line[:-1] if line.endswith(b'\r') else line
                for line in part['bytes'].encode().split(b'\n')[:-1]]
    events = observed['events']
    order = [e for e in events if e['kind'] in ('received', 'refused')]
    numbers = [e['request'] for e in order]
    if numbers != list(range(1, len(numbers) + 1)):
        problems.append('order: requests were numbered %s on arrival' % numbers)
    #  What the device must have written, in the order its trace says: a
    #  refusal's `busy` when it refused, an answer when its answering ended.
    expected, waiting, answering, finished, last_end = [], [], {}, set(), None
    for e in events:
        n = e['request']
        if e['kind'] == 'received':
            if len(waiting) >= DEPTH:
                problems.append('busy: request %d was queued behind %d waiting' % (n, len(waiting)))
            waiting.append(n)
        elif e['kind'] == 'refused':
            if len(waiting) < DEPTH:
                problems.append('busy: request %d was refused with %d waiting' % (n, len(waiting)))
            expected.append('busy')
        elif e['kind'] == 'started':
            for other in answering:
                problems.append('overlap: request %d started while %d was being answered'
                                % (n, other))
            if not waiting or waiting[0] != n:
                problems.append('order: request %d started before %s'
                                % (n, waiting[0] if waiting else 'it arrived'))
            if n in waiting:
                waiting.remove(n)
            if last_end is not None and e['at'] < last_end:
                problems.append('overlap: request %d started at tick %d, before tick %d'
                                % (n, e['at'], last_end))
            answering[n] = e['at']
        elif e['kind'] == 'finished':
            if n not in answering:
                problems.append('order: request %d finished without being answered' % n)
                continue
            began = answering.pop(n)
            if n - 1 < len(fed):
                text, wait = answer_of(fed[n - 1])
                if e['at'] - began < wait:
                    problems.append('early: request %d answered %d ticks after it started, '
                                    'asked to wait %d' % (n, e['at'] - began, wait))
                expected.append(text)
            finished.add(n)
            last_end = e['at']
    for first, second in presented:
        positions = {(e['kind'], e['request']): i for i, e in enumerate(events)}
        arrived, began, ended = (positions.get(('received', second)), positions.get(('started', first)),
                                 positions.get(('finished', first)))
        if None in (arrived, began) or arrived < began or (ended is not None and arrived > ended):
            problems.append('presented: request %d did not arrive while %d was being answered'
                            % (second, first))
    for n, e in enumerate(order, 1):
        if e['kind'] == 'received' and n not in finished:
            problems.append('missing answer: request %d (%r) was never answered'
                            % (n, fed[n - 1].decode(errors='replace') if n - 1 < len(fed) else ''))
    if len(order) < len(fed):
        problems.append('missing answer: %d lines were fed and %d taken' % (len(fed), len(order)))
    written = observed['output'].split('\n')
    if written[-1] != '':
        problems.append('output: the device left a line unended: %r' % written[-1])
    written = written[:-1]
    if written != expected:
        missing = [line for line in expected if line not in written]
        problems.append(('missing answer: %s never written' % missing) if missing else
                        'output: the device wrote %r where its trace says %r' % (written, expected))
    return problems


def describe(observed):
    """The trace as text: each request, its line, when it arrived, began and
    ended, and the answer, then everything the device wrote."""
    fed = []
    for part in observed['fed']:
        fed += part['bytes'].split('\n')[:-1]
    rows = {}
    for e in observed['events']:
        rows.setdefault(e['request'], {})[e['kind']] = e['at']
    out = ['scenario %s: %s at tick %d, after %d stops at the device' % (
        observed['scenario'], observed['outcome'], observed['ticks'], observed['stops'])]
    for n in sorted(rows):
        r = rows[n]
        line = fed[n - 1] if n - 1 < len(fed) else '?'
        if 'refused' in r:
            out.append('  %d %-22r refused busy at %d' % (n, line, r['refused']))
        else:
            out.append('  %d %-22r received %s, started %s, finished %s' % (
                n, line, r.get('received', '-'), r.get('started', '-'), r.get('finished', '-')))
    out.append('  wrote %r' % observed['output'])
    out.append('  fibre stacks painted %s of 2048 bytes; main stack %d of 4096'
               % (observed['fibre_peaks'], observed['main_stack_painted']))
    return '\n'.join(out) + '\n'


def scenario_run(run, refine, profile, scenario):
    optimize, specialize = profile
    elf, symbols, sizes, firmware = build(run, refine, optimize, specialize)
    observed = session(run, elf, symbols, sizes, scenario, scenario)
    problems = judge(observed, SCENARIOS[scenario]['presented'])
    observed.update(problems=problems, flash=firmware['flash_used'],
                    static_ram=firmware['static_ram_used'])
    (run.out / 'trace.json').write_text(json.dumps(observed, indent=2) + '\n')
    (run.out / 'trace.txt').write_text(describe(observed))
    require(not problems, 'counterpart %s-%s %s: %s' % (optimize, specialize, scenario,
                                                         '; '.join(problems)))
    for peak in observed['fibre_peaks']:
        require(peak + 36 <= 2048 - 32, 'counterpart %s: a fibre painted %d bytes' % (scenario, peak))
    return observed


def control_run(run, refine, profile, name):
    """Build the mutated source, run its scenario, and require the failure."""
    control = CONTROLS[name]
    optimize, specialize = profile
    elf, symbols, sizes, _ = build(run, refine, optimize, specialize, name)
    observed = session(run, elf, symbols, sizes, name, control['scenario'],
                       3 if name == 'overlap' else 2)
    problems = judge(observed, SCENARIOS[control['scenario']]['presented'])
    observed.update(problems=problems)
    (run.out / 'trace.json').write_text(json.dumps(observed, indent=2) + '\n')
    (run.out / 'trace.txt').write_text(describe(observed))
    kinds = [p.split(':')[0] for p in problems]
    require(control['fails'] in kinds, 'control %s did not fail %s: %s'
            % (name, control['fails'], problems or 'the oracle passed it'))
    return {'control': name, 'fails': control['fails'], 'problems': problems}


def execute_suite(parent, refine, profiles=PROFILES, scenarios=None, controls=None):
    """Every scenario at PROFILES and every control at the first; a
    selection is FILTERED."""
    refine = refine.resolve()
    root = parent.out / 'counterpart'
    root.mkdir()
    compiler_hash = sha(refine)
    scenarios = list(SCENARIOS) if scenarios is None else scenarios
    controls = list(CONTROLS) if controls is None else controls
    work = ([('scenario', p, s) for p in profiles for s in scenarios] +
            [('control', profiles[0], c) for c in controls])

    def one(item):
        kind, profile, name = item
        out = root / ('-'.join(profile)) / name
        out.mkdir(parents=True)
        run = Run(out, parent.tools)
        if kind == 'scenario':
            observed = scenario_run(run, refine, profile, name)
            return {'profile': '-'.join(profile), 'scenario': name, 'status': 'passed',
                    'ticks': observed['ticks'], 'flash': observed['flash'],
                    'static_ram': observed['static_ram'], 'fibre_peaks': observed['fibre_peaks'],
                    'main_stack_painted': observed['main_stack_painted']}
        result = control_run(run, refine, profile, name)
        return dict(result, profile='-'.join(profile), status='passed')

    results = []
    with ThreadPoolExecutor(max_workers=workers()) as pool:
        for result in pool.map(one, work):
            results.append(result)
            what = result.get('scenario') or 'control ' + result['control']
            print('counterpart: %s/%s passed' % (result['profile'], what), flush=True)
    require(sha(refine) == compiler_hash, 'counterpart compiler drift')
    traces = '\n'.join((root / r['profile'] / (r.get('scenario') or r['control']) / 'trace.txt')
                       .read_text() for r in results)
    (root / 'traces.txt').write_text(traces)
    record = {'status': 'passed', 'compiler_sha256': compiler_hash, 'results': results,
              'scope': 'complete' if (scenarios == list(SCENARIOS) and controls == list(CONTROLS)
                                      and list(profiles) == list(PROFILES)) else 'FILTERED'}
    (root / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--refine', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--tools', type=Path, default=DEFAULT)
    p.add_argument('--all-profiles', action='store_true')
    p.add_argument('--profile', action='append', choices=['-'.join(p) for p in PROFILES])
    p.add_argument('--scenario', action='append', choices=list(SCENARIOS))
    p.add_argument('--control', action='append', choices=list(CONTROLS))
    a = p.parse_args()
    supported_host(a.output)
    a.tools = installed_tools(a.tools)
    before = inventory(a.tools)
    a.output.mkdir(parents=True, exist_ok=False)
    profiles = ([tuple(x.split('-')) for x in a.profile] if a.profile else
                PROFILES if a.all_profiles else PROFILES[:1])
    selected = a.scenario is not None or a.control is not None
    record = {'status': 'failed', 'tools': before, 'scope': 'development; not acceptance'}
    try:
        record['counterpart'] = execute_suite(
            Run(a.output.resolve(), a.tools.resolve()), a.refine.resolve(), profiles,
            a.scenario if selected else None, (a.control or []) if selected else None)
        require(inventory(a.tools) == before, 'embedded tool drift')
        record['status'] = 'passed'
        print('counterpart: %s, %s' % (record['status'], record['counterpart']['scope']))
    finally:
        record['files'] = {str(p.relative_to(a.output)): sha(p)
                           for p in sorted(a.output.rglob('*')) if p.is_file()}
        (a.output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')


if __name__ == '__main__':
    main()
