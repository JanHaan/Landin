"""Off-target SP observations and complete-application resource scenarios.

Paint measures written bytes. Breakpoints also observe unwritten stack
reservations, at every statically decoded SP change's successor, every
function entry and every exception handler's entry.  They read CPU registers
and ordinary stack RAM only, never device registers.

Sampling stops the CPU at every site, so a scenario pays one debugger round
trip per sample.  The exhaustion scenario, which streams 65,535 bytes
through the ring and samples about four million times, is measured by paint
alone; `stack_control` calibrates the observer on the independent program,
and the other scenarios run the same application code under it.
"""
import json
import re

from driver import machine
from machine import Machine
from run import require

TOP, BOTTOM, GUARD = 0x20004000, 0x20003000, 256


def hook_addresses(disassembly):
    addresses = set()
    instructions = []
    for line in disassembly.splitlines():
        label = re.match(r'^([0-9a-f]+) <[^>]+>:', line)
        if label:
            addresses.add(int(label[1], 16))
        match = re.match(r'^\s*([0-9a-f]+):\s+((?:[0-9a-f]{4}\s+)+)\s*(\S+)\s*(.*)', line)
        if match:
            pc, raw, op, args = match.groups()
            if op.startswith('.'):
                continue
            instructions.append((int(pc,16), len(raw.split())*2, op, args))
    changes = []
    for pc, size, op, args in instructions:
        if op in ('push','pop') or re.match(r'(?:sp|r13)\b', args) or (
                op == 'msr' and args.startswith(('MSP','PSP','msp','psp'))):
            addresses.add(pc+size)
            changes.append(dict(pc=pc, successor=pc+size, opcode=op, operands=args))
    require(changes, 'no independently decoded stack changes')
    return sorted(addresses), changes


class StackObserver:
    """The minimum SP at the sampled sites, with its frame-record chain.

    An SP outside the reservation fails the lane at once.  At an exception
    handler's entry the SP is also recorded per IPSR.
    """

    def __init__(self, machine, addresses, handlers):
        self.handlers = handlers
        self.minimum, self.samples, self.record, self.interrupts = TOP, 0, None, {}
        machine.sample(addresses, self.sample)

    def sample(self, m, pc):
        sp = m.register('sp')
        require(BOTTOM <= sp <= TOP, 'stack escaped reservation: sp %#x at %#x' % (sp, pc))
        self.samples += 1
        if pc in self.handlers:
            ipsr = m.register('xpsr') & 511
            self.interrupts[ipsr] = min(sp, self.interrupts.get(ipsr, TOP + 1))
        if sp >= self.minimum:
            return
        self.minimum = sp
        fp, lr, psr = m.register('r11'), m.register('lr'), m.register('xpsr')
        frames, cursor = [], fp
        while sp <= cursor < TOP - 8 and cursor % 4 == 0:
            previous, incoming = m.u32(cursor), m.u32(cursor + 4)
            frames.append([cursor, previous, incoming])
            if incoming >= 0xfffffff0 or previous <= cursor:
                break
            cursor = previous
        self.record = dict(pc=pc, sp=sp, fp=fp, lr=lr, xpsr=psr, frame_records=frames)

    def observations(self):
        return dict(samples=self.samples, minimum_sp=self.minimum, minimum=self.record,
                    interrupt_ipsr={str(k): v for k, v in sorted(self.interrupts.items())})


def install(run, m):
    """Paint the reservation and sample SP; return a snapshot function."""
    addresses, changes = hook_addresses((run.out/'disassembly.log').read_text())
    (run.out/'stack-hooks.json').write_text(json.dumps(dict(
        addresses=addresses, instructions=changes),indent=2)+'\n')
    handlers = {m.u32(slot*4) & ~1 for slot in range(2, 48)} - {0}
    observer = StackObserver(m, sorted(set(addresses) | handlers), handlers)
    return painted(m, observer)


def painted(m, observer=None):
    m.write(BOTTOM, bytes([165]) * (TOP - BOTTOM))
    snapshots = []

    def snapshot(name):
        paint = m.read(BOTTOM, TOP - BOTTOM)
        require(paint[:GUARD] == bytes([165]) * GUARD, 'low stack guard changed')
        written = (TOP - BOTTOM) - next((i for i, b in enumerate(paint) if b != 165),
                                        TOP - BOTTOM)
        row = dict(scenario=name, written_bytes=written, sp=m.register('sp'))
        if observer is not None:
            observations = observer.observations()
            row['observed_reserved_bytes'] = TOP - observations['minimum_sp']
            require(written <= row['observed_reserved_bytes'], 'SP coverage missed a stack write')
            row['observations'] = observations
        snapshots.append(row)
        return row
    snapshot.rows = snapshots
    return snapshot


def application(run, elf, symbols, scenario):
    """Run the unchanged complete application, with an independent host oracle."""
    s = symbols
    m, model = machine(run, elf, s, 'resources-' + scenario)
    with m:
        u32 = m.u32
        sampled = scenario != 'exhaustion'
        snapshot = install(run, m) if sampled else painted(m)

        def state(name, handled, recoveries=0, status=2):
            m.settle(budget=30)
            require(u32(s['handled']) == handled,
                    '%s: handled %d, not %d' % (name, u32(s['handled']), handled))
            require(u32(s['recoveries']) == recoveries, name + ': recoveries')
            require(u32(s['app_state']) == status, name + ': state')
            snapshot(name)

        if scenario == 'open-failure':
            model.inject_error()
            state('open-failure', 0, status=1)
        else:
            state('cold-boot', 0)
            require(model.remaining == 65535 and model.busy, 'cold-boot: ring')
            if scenario == 'receive':
                for i in range(200):
                    model.feed(65 + i % 26)
                state('partial-and-coalesced', 200)
                require(model.remaining == 65335, 'partial: ring')
                for i in range(128):
                    model.feed(97 + i % 26)
                state('wrapped', 328)
                expected = [65 + i % 26 for i in range(200)] + [97 + i % 26 for i in range(128)]
                require(model.output_text == ','.join(map(str, expected)), 'wrapped: output')
                require(model.remaining == 65207, 'wrapped: ring')
                model.delay_stop(3, 90)
                model.feed(49)
                model.tick(1000)
                state('delayed-drain', 330)
                require(model.output_text.endswith(',49,90'), 'delayed-drain: output')
                model.delay_stop(0, -1)
                for _ in range(300):
                    model.feed(70)
                state('overrun-recovered', 330, 1)
                require(model.remaining == 65535, 'overrun: ring')
                model.feed(48)
                model.tick(1000)
                state('echo-after-recovery', 331, 1)
                require(model.output_text.endswith(',48'), 'echo: output')
                model.delay_stop(20, -1)
                model.feed(65)
                model.tick(1000)
                state('timeout-retains-storage', 331, 1, 3)
                require(model.busy, 'timeout: ring retained')
            elif scenario == 'transfer-fault':
                model.inject_error()
                state('external-repair-required', 0, 1, 3)
                require(not model.busy, 'fault: ring')
            elif scenario == 'exhaustion':
                # Service every 256 bytes, retaining all 65535 monotone
                # production counts.  The final short read is echoed before
                # exhaustion fails.
                for epoch in range(1, 256):
                    for _ in range(256):
                        model.feed(65)
                    m.settle(budget=30)
                    require(model.remaining == 65535 - epoch * 256, 'epoch %d: ring' % epoch)
                    require(u32(s['handled']) == epoch * 256, 'epoch %d: handled' % epoch)
                    model.clear_trace()
                for _ in range(255):
                    model.feed(66)
                state('final-epoch-bytes', 65535)
                require(model.remaining == 0, 'final epoch: ring')
                model.tick(1000)
                state('finite-epoch-exhaustion', 65535, 1)
                require(model.remaining == 65535, 'exhausted: ring')
                require(model.output_text == ','.join(['65'] * 65280 + ['66'] * 255),
                        'exhausted: output')
            else:
                raise ValueError(scenario)
    rows = snapshot.rows
    if sampled:
        require(rows[-1]['observations']['samples'] > 0, 'no SP samples')
    (run.out/('resources-'+scenario+'.json')).write_text(
        json.dumps(rows, sort_keys=True, indent=2) + '\n')
    return rows


def terminated(control, elf, expected):
    """Separate helper/veneer controls, including the default return trap."""
    names=control.command('control-symbols',[control.bin/'arm-none-eabi-nm','-n',elf])
    symbols={s[2]:int(s[0],16) for line in names.splitlines() if len(s:=line.split())==3}
    # These controls end in the firmware's terminal trap on purpose: it is
    # the idle WFI they settle at, not a failure.
    m = Machine(control, elf, 'control-resources')
    with m:
        snapshot = install(control, m)
        m.settle()
        for name, values in expected.items():
            for i, value in enumerate(values):
                require(m.u32(symbols[name] + i * 4) == value, name + ': observed value')
        require(m.register('xpsr') & 511 == 3, 'control did not end in the terminal trap')
        snapshot('control-through-terminal-trap')
    rows = snapshot.rows
    (control.out/'control-resources.json').write_text(json.dumps(rows, indent=2) + '\n')
    return rows
