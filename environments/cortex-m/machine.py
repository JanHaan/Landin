"""Synthetic peripherals on the pinned QEMU, through its debugger stub.

QEMU's microbit leaves 0x40000000..0x5fffffff unimplemented, so a model can
own a window there.  An access watchpoint on the window stops the CPU before
the access, because QEMU's Arm target stops before a watched access.  The
harness decodes the load or store at the stopped PC, performs it against the
model, writes a load's result register and moves PC past the instruction.
`decode` refuses every form that is not one Thumb load or store, and a model
refuses every width, direction and offset its contract does not name, so no
access reaches a model unexamined.

A model acts only while the CPU is stopped.  A DMA transfer writes RAM
through the stub.  An interrupt line is level-sensitive, as ARMv6-M
defines it: while the line is asserted and its handler is not the active
exception, the NVIC holds it pending, and deasserting the line does not
withdraw a pending interrupt.  The harness re-evaluates every line at every
stop and writes the set-pending register for each asserted one.

Time does not pass for a lane; the firmware runs until it is idle.  It is
idle at a WFI with no enabled interrupt pending, at a branch to itself with
none it could take, or in a polling loop whose state repeats exactly: the
same load at the same instruction with the same registers, the same RAM and
the same model state, twice, with no interrupt it could take and SysTick
off.  A deterministic CPU in a repeated state repeats forever.  A WFI with
an enabled interrupt pending completes, exactly as the instruction does.
QEMU counts instructions rather than host time (`-icount`), so the same
image stops at the same instruction on every host.

Everything runs in the caller's thread: one socket, one QEMU, no logger.  A
failure is an exception naming its cause.  The one exception is `relay`,
which puts the harness between a debugger and QEMU for a source-level
session: the relay's thread serves the model while the debugger drives.
"""
import json
import re
import socket
import struct
import subprocess
import threading
import time

from run import gdb_listener, require, stop

NVIC_ISER, NVIC_ISPR, SYST_CSR = 0xe000e100, 0xe000e200, 0xe000e010
RAM, RAM_SIZE = 0x20000000, 0x4000
REGISTERS = {'r11': 11, 'sp': 13, 'lr': 14, 'pc': 15, 'xpsr': 25, 'primask': 28}
WFI, SELF_BRANCH = 0xbf30, 0xe7fe
#  QEMU's two expected lines: an instruction-count clock with no timer to
#  wake it, and the harness ending the process.
QEMU_NOTICES = re.compile(
    r'^qemu-system-arm: (?:warning: icount sleep disabled and no active timers'
    r'|terminating on signal 15 from pid \d+ \([^)]*\))$')


class Refused(Exception):
    """A model or the decoder refused an access: the lane has failed."""


class Trapped(Exception):
    """The firmware reached a breakpoint the lane named as its end or a fault."""


def decode(half):
    """One Thumb-1 load or store: (write, width, signed, rt, rn, rm, imm).

    Only the register- and immediate-offset forms can reach a device through
    an arbitrary base register.  PC- and SP-relative forms and every
    multiple transfer are refused rather than guessed at.
    """
    top5 = half >> 11
    rt, rn, imm5 = half & 7, (half >> 3) & 7, (half >> 6) & 31
    immediate = {0b01100: (True, 4), 0b01101: (False, 4), 0b01110: (True, 1),
                 0b01111: (False, 1), 0b10000: (True, 2), 0b10001: (False, 2)}
    if top5 in immediate:
        write, width = immediate[top5]
        return write, width, False, rt, rn, None, imm5 * width
    if half >> 12 == 0b0101:
        write, width, signed = ((True, 4, False), (True, 2, False), (True, 1, False),
                                (False, 1, True), (False, 4, False), (False, 2, False),
                                (False, 1, False), (False, 2, True))[(half >> 9) & 7]
        return write, width, signed, rt, rn, (half >> 6) & 7, 0
    raise Refused('not a single Thumb load or store: %04x' % half)


LOAD_STORE = re.compile(
    r'^\s*[0-9a-f]+:\s+([0-9a-f]{4})\s+(ldr|str|ldrb|strb|ldrh|strh|ldrsb|ldrsh)\s+'
    r'r(\d), \[r(\d)(?:, (?:#(\d+)|r(\d)))?\]')


def agree(disassembly):
    """Hold `decode` to the disassembler on every single load and store it lists.

    Returns how many it compared.  A disagreement, or a load or store the
    disassembler shows through a base register that `decode` refuses, fails.
    """
    widths = {'': 4, 'b': 1, 'h': 2, 'sb': 1, 'sh': 2}
    compared = 0
    for line in disassembly.splitlines():
        match = LOAD_STORE.match(line)
        if not match:
            continue
        half, op, rt, rn, immediate, rm = match.groups()
        want = (op.startswith('str'), widths[op[3:]], op[3:].startswith('s'), int(rt), int(rn),
                int(rm) if rm is not None else None, int(immediate or 0))
        got = decode(int(half, 16))
        require(got == want, 'decoder disagrees with the disassembler: %s decodes as %s'
                % (line.strip(), got))
        compared += 1
    return compared


class Stub:
    """A GDB remote-protocol client for one QEMU.

    The pinned QEMU does not offer no-acknowledgement mode, so every packet
    received is acknowledged, and the stub's acknowledgements are skipped.
    """

    def __init__(self, port, deadline):
        while True:
            try:
                self.socket = socket.create_connection(('127.0.0.1', port), timeout=.1)
                break
            except OSError:
                require(time.monotonic() < deadline, 'QEMU debugger startup timed out')
                time.sleep(.02)
        self.socket.settimeout(None)
        self.socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.pending = b''
        # QEMU's stub steps with interrupts and timers held off by default;
        # a step here is ordinary execution, so it may take an interrupt.
        self.ok('Qqemu.sstep=1', 'single-step flags')

    def send(self, data):
        body = data.encode()
        self.socket.sendall(b'$' + body + b'#%02x' % (sum(body) & 0xff))

    def receive(self):
        while True:
            match = re.match(rb'^\+*\$([^#]*)#[0-9a-fA-F]{2}', self.pending, re.S)
            if match:
                self.pending = self.pending[match.end():]
                self.socket.sendall(b'+')
                return match.group(1).decode()
            chunk = self.socket.recv(65536)
            require(chunk, 'QEMU closed its debugger connection')
            self.pending += chunk

    def packet(self, data):
        self.send(data)
        return self.receive()

    def ok(self, data, what):
        reply = self.packet(data)
        require(reply == 'OK', what + ' refused by QEMU: ' + reply)

    def register(self, number):
        return struct.unpack('<I', bytes.fromhex(self.packet('p%x' % number)))[0]

    def set_register(self, number, value):
        self.ok('P%x=%s' % (number, struct.pack('<I', value & 0xffffffff).hex()),
                'register %d write' % number)

    #  QEMU's stub holds one packet in a buffer of about 4 KiB; a longer
    #  one is dropped unanswered.  Hex doubles a transfer, so move 1 KiB.
    CHUNK = 1024

    def read(self, address, length):
        data = b''
        for offset in range(0, length, self.CHUNK):
            size = min(self.CHUNK, length - offset)
            reply = self.packet('m%x,%x' % (address + offset, size))
            require(not reply.startswith('E'), 'memory read %#x refused: %s'
                    % (address + offset, reply))
            data += bytes.fromhex(reply)
        return data

    def write(self, address, data):
        data = bytes(data)
        for offset in range(0, len(data), self.CHUNK):
            part = data[offset:offset + self.CHUNK]
            self.ok('M%x,%x:%s' % (address + offset, len(part), part.hex()),
                    'memory write %#x' % (address + offset))

    def execute(self, command, budget):
        """Send `c` or `s` and wait for the stop; interrupt and fail after BUDGET."""
        self.send(command)
        self.socket.settimeout(budget)
        try:
            return self.receive()
        except socket.timeout:
            self.socket.settimeout(None)
            self.socket.sendall(b'\x03')
            self.receive()
            raise RuntimeError('no stop within %g seconds of execution' % budget)
        finally:
            self.socket.settimeout(None)


class Machine:
    """One microbit QEMU under the harness.

    POLL names the RAM words the firmware waits on.  Every load and store of
    one is performed by the harness, so a lane can see the firmware wait and
    can change a word the firmware is about to read.
    """

    def __init__(self, run, elf, name, poll=(), idle=True):
        self.run, self.name = run, name
        listener, _, chardev = gdb_listener()
        argv = [str(run.bin / 'qemu-system-arm'), '-M', 'microbit',
                '-accel', 'tcg,thread=single', '-icount', 'shift=0,align=off,sleep=off',
                '-display', 'none', '-monitor', 'none', '-serial', 'none',
                '-kernel', str(elf), '-S', *chardev]
        self.record = {'name': name, 'argv': argv, 'harness': 'machine.py'}
        run.commands.append(self.record)
        self.tick = time.monotonic()
        self.log = (run.out / (name + '.log')).open('wb')
        with listener:
            self.process = subprocess.Popen(argv, cwd=run.out, env=run.env, stdout=self.log,
                                            stderr=self.log, start_new_session=True,
                                            pass_fds=(listener.fileno(),))
            self.stub = Stub(listener.getsockname()[1], time.monotonic() + 5)
        self.models = []
        self.words = set()
        self.roles = {}
        self.observer = None
        self.stops = 0
        self.relayed = None
        disassembly = run.command(name + '-idle-sites', [run.bin / 'arm-none-eabi-objdump', '-d', elf])
        self.record['decoder_agreed'] = agree(disassembly)
        for line in disassembly.splitlines() if idle else ():
            site = re.match(r'^\s*([0-9a-f]+):\s+([0-9a-f]{4})\s', line)
            if site and int(site[2], 16) in (WFI, SELF_BRANCH):
                self.role(int(site[1], 16), 'wfi' if int(site[2], 16) == WFI else 'spin')
        for word in poll:
            self.stub.ok('Z4,%x,4' % word, 'watchpoint')
            self.words.add(word)

    def __enter__(self):
        return self

    def __exit__(self, kind, error, trace):
        stop(self.process)
        if self.relayed is not None:
            self.relayed.join(timeout=5)
            if kind is None and self.relay_failure is not None:
                raise self.relay_failure
        self.log.close()
        self.record.update(seconds=round(time.monotonic() - self.tick, 3), stops=self.stops,
                           exit=self.process.returncode)
        (self.run.out / 'commands.json').write_text(json.dumps(self.run.commands, indent=2)+'\n')
        text = (self.run.out / (self.name + '.log')).read_text(errors='replace')
        if kind is None:
            other = [line for line in text.splitlines() if not QEMU_NOTICES.match(line)]
            require(not other, 'QEMU reported: ' + '\n'.join(other))
        return False

    # Memory and registers, while stopped.
    def u32(self, address):
        return struct.unpack('<I', self.stub.read(address, 4))[0]

    def u8(self, address):
        return self.stub.read(address, 1)[0]

    def read(self, address, length):
        return self.stub.read(address, length)

    def write_u32(self, address, value):
        self.stub.write(address, struct.pack('<I', value & 0xffffffff))

    def write(self, address, data):
        self.stub.write(address, data)

    def register(self, name):
        return self.stub.register(REGISTERS[name])

    def set_register(self, name, value):
        self.stub.set_register(REGISTERS[name], value)

    def assert_lines(self):
        """Pend every asserted line whose handler is not the active exception."""
        asserted = 0
        for _, _, model in self.models:
            for name, irq in model.LINES.items():
                if model.level(name):
                    asserted |= 1 << irq
        if asserted:
            active = (self.register('xpsr') & 0x1ff) - 16
            if active >= 0:
                asserted &= ~(1 << active)
            if asserted:
                self.write_u32(NVIC_ISPR, asserted)

    # What stops the CPU.
    def map(self, base, size, model):
        """Map MODEL at BASE..BASE+SIZE; every access to it stops the CPU."""
        self.stub.ok('Z4,%x,%x' % (base, size), 'watchpoint')
        self.models.append((base, size, model))
        model.attach(self, base)

    def role(self, address, role):
        address &= ~1
        if address not in self.roles:
            self.stub.ok('Z1,%x,2' % address, 'breakpoint')
            self.roles[address] = set()
        self.roles[address].add(role)

    def trap(self, address, name):
        """End the lane with Trapped(NAME) if the firmware reaches ADDRESS."""
        self.role(address, ('trap', name))

    def sample(self, addresses, observer):
        """Call OBSERVER(machine, pc) at each of ADDRESSES and carry on."""
        for address in addresses:
            self.role(address, 'sample')
        self.observer = observer

    def deliverable(self):
        """An enabled interrupt is pending, and PRIMASK would let it be taken."""
        waiting = self.u32(NVIC_ISER) & self.u32(NVIC_ISPR)
        return waiting, waiting != 0 and self.register('primask') & 1 == 0

    def perform(self, handler):
        """Perform the load or store at PC through HANDLER, then step past it."""
        pc = self.register('pc')
        write, width, signed, rt, rn, rm, offset = decode(
            struct.unpack('<H', self.stub.read(pc, 2))[0])
        values = {n: self.stub.register(n) for n in {rt, rn} | ({rm} - {None})}
        address = (values[rn] + (values[rm] if rm is not None else offset)) & 0xffffffff
        if address % width:
            raise Refused('misaligned %d-byte access at %#x' % (width, address))
        if write:
            value = values[rt] & ((1 << 8 * width) - 1)
            handler(True, address, width, value)
        else:
            value = handler(False, address, width, None)
            loaded = value - (1 << 8 * width) if signed and value >> (8 * width - 1) & 1 else value
            self.stub.set_register(rt, loaded)
        self.stub.set_register(15, pc + 2)
        return pc, write, address, value

    def memory(self, write, address, width, value):
        if write:
            self.stub.write(address, value.to_bytes(width, 'little'))
            return None
        return int.from_bytes(self.stub.read(address, width), 'little')

    def watched(self, reply):
        """Serve the watchpoint REPLY names; return the event it was."""
        hit = int(re.search(r'watch:([0-9a-f]+);', reply).group(1), 16)
        if hit in self.words:
            pc, write, address, value = self.perform(self.memory)
            return ('store' if write else 'load', pc, address, value)
        for base, size, model in self.models:
            if base == hit:
                pc, write, address, value = self.perform(model.bus)
                return ('write' if write else 'access', pc, address, value)
        raise RuntimeError('stop at an unknown watchpoint %#x' % hit)

    def step(self, budget=5):
        """Resume to the next event: (kind, pc, address, value).

        KIND is 'access' or 'write' for a model, 'load' or 'store' for a
        polled word, 'idle' or 'woke' at a WFI or self-branch.
        """
        while True:
            self.assert_lines()
            self.stops += 1
            reply = self.stub.execute('c', budget)
            if 'watch:' in reply:
                event = self.watched(reply)
                self.assert_lines()
                return event
            require(reply.startswith('T05'), 'unexpected stop: ' + reply)
            self.assert_lines()
            pc = self.register('pc')
            roles = self.roles.get(pc)
            require(roles is not None, 'stop at %#x, which is no breakpoint' % pc)
            for role in roles:
                if isinstance(role, tuple):
                    raise Trapped(role[1])
            if 'sample' in roles:
                self.observer(self, pc)
            if 'wfi' in roles:
                waiting, _ = self.deliverable()
                if not waiting:
                    return ('idle', pc, None, None)
                self.stub.set_register(15, pc + 2)
                return ('woke', pc, None, None)
            if 'spin' in roles and not self.deliverable()[1]:
                return ('idle', pc, None, None)
            event = self.step_over(pc)
            if event is not None:
                return event

    def step_over(self, pc):
        """Execute the one instruction at a sampling breakpoint.

        QEMU stops at a breakpoint again when continued on it, but a single
        step ignores breakpoints; a step that meets a watchpoint is served
        like any other, and a step may take an interrupt, after which the
        breakpoint is met again on the way back.
        """
        reply = self.stub.execute('s', 5)
        return self.watched(reply) if 'watch:' in reply else None

    def state(self, event):
        """Everything a polling load's future depends on, but RAM."""
        return event, self.stub.packet('g'), tuple(m.state() for _, _, m in self.models)

    def settle(self, budget=5, limit=200000):
        """Run until the firmware is idle (see the module); return the idle event."""
        last = snapshot = None
        for _ in range(limit):
            event = self.step(budget)
            if event[0] == 'idle':
                return event
            if event[0] not in ('load', 'access'):
                last = snapshot = None
                continue
            current = self.state(event)
            if current != last:
                last, snapshot = current, None
                continue
            if self.deliverable()[1] or self.u32(SYST_CSR) & 1:
                continue
            memory = self.read(RAM, RAM_SIZE)
            if memory == snapshot:
                return ('idle', event[1], None, None)
            snapshot = memory
        raise RuntimeError('firmware not idle within %d events' % limit)

    def until(self, predicate, budget=5, limit=200000):
        """Serve events until PREDICATE() holds; it is checked before each.

        Firmware idle at a WFI or a branch to itself cannot make it hold,
        so reaching one first fails at once, naming where.
        """
        for _ in range(limit):
            if predicate():
                return
            event = self.step(budget)
            if event[0] == 'idle' and not predicate():
                raise RuntimeError('firmware idle at %#x before the awaited condition' % event[1])
        raise RuntimeError('condition not reached within %d events' % limit)

    def run_to(self, address, name, budget=5):
        """Serve every event until the firmware reaches ADDRESS."""
        self.trap(address, name)
        try:
            while True:
                self.step(budget)
        except Trapped as reached:
            require(str(reached) == name, 'firmware reached %s, not %s' % (reached, name))
        self.roles[address & ~1].discard(('trap', name))


    def rearm(self):
        for word in self.words:
            self.stub.ok('Z4,%x,4' % word, 'watchpoint')
        for base, size, _ in self.models:
            self.stub.ok('Z4,%x,%x' % (base, size), 'watchpoint')
        for address in self.roles:
            self.stub.ok('Z1,%x,2' % address, 'breakpoint')

    # A debugger between the lane and QEMU.
    def relay(self, commands):
        """Listen for one debugger; return its port.

        Its packets go to QEMU unchanged, except that a resume which stops
        at a model access is served and resumed again, so the debugger sees
        only its own stops, and `monitor NAME ARGS` calls COMMANDS[NAME]
        with integer arguments while the CPU is stopped.  Detach and kill
        end the relay without reaching QEMU, which the lane stops itself.
        """
        # The debugger decides where the CPU stops; the harness's idle
        # sites would show it stops it never asked for.
        for address, roles in list(self.roles.items()):
            roles -= {'wfi', 'spin'}
            if not roles:
                self.stub.ok('z1,%x,2' % address, 'breakpoint removal')
                del self.roles[address]
        server = socket.socket()
        server.bind(('127.0.0.1', 0))
        server.listen(1)
        self.relay_failure = None

        def serve():
            try:
                with server:
                    server.settimeout(30)
                    connection, _ = server.accept()
                with connection:
                    connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    self.serve_debugger(connection, commands)
            except Exception as failure:  # reported by __exit__
                self.relay_failure = failure
        self.relayed = threading.Thread(target=serve, daemon=True)
        self.relayed.start()
        return server.getsockname()[1]

    def serve_debugger(self, connection, commands):
        pending = b''
        while True:
            match = re.match(rb'^[+-]*\$([^#]*)#[0-9a-fA-F]{2}', pending, re.S)
            if not match:
                pending = pending.lstrip(b'+-')
                require(not pending.startswith(b'\x03'), 'debugger interrupted the relay')
                chunk = connection.recv(65536)
                if not chunk:
                    return
                pending += chunk
                continue
            pending = pending[match.end():]
            packet = match.group(1).decode()
            connection.sendall(b'+')
            if packet in ('D', 'k') or packet.startswith('D;'):
                reply = 'OK'
            elif packet.startswith('qRcmd,'):
                words = bytes.fromhex(packet[6:]).decode().split()
                require(words and words[0] in commands, 'unknown monitor command: %s' % words)
                commands[words[0]](*map(int, words[1:]))
                self.assert_lines()
                reply = 'OK'
            elif packet in ('c', 's') or packet.startswith(('vCont;c', 'vCont;s')):
                step = packet == 's' or packet.startswith('vCont;s')
                while True:
                    self.assert_lines()
                    reply = self.stub.execute('s' if step else 'c', 30)
                    if 'watch:' not in reply:
                        break
                    self.watched(reply)
                    if step:
                        reply = 'T05thread:01;'
                        break
            else:
                reply = self.stub.packet(packet)
                if packet == '?':
                    # QEMU removes every breakpoint and watchpoint when a
                    # debugger asks why the target stopped, as GDB does on
                    # connecting; the harness's own are armed again.
                    self.rearm()
            body = reply.encode()
            connection.sendall(b'$' + body + b'#%02x' % (sum(body) & 0xff))
            if packet == 'k':
                return


class Model:
    """A synthetic device.  Subclasses name their offsets; others are refused.

    LINES maps each interrupt line's name to its NVIC number; `level(name)`
    says whether the line is asserted now.  TALLIES names the attributes
    that only record what happened, so that `state()` is what a read could
    change for the next one.
    """
    LINES = {}
    TALLIES = ('events',)

    def state(self):
        return tuple(sorted((k, repr(v)) for k, v in vars(self).items()
                            if k not in self.TALLIES and k not in ('machine', 'base')))

    def attach(self, machine, base):
        self.machine, self.base = machine, base

    def bus(self, write, address, width, value):
        offset = address - self.base
        return self.write(offset, width, value) if write else self.read(offset, width)

    def ram(self, address, value):
        """A DMA byte: written while the CPU is stopped."""
        self.machine.write(address, bytes([value]))
