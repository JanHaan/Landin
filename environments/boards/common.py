#!/usr/bin/env python3
"""What every board tool shares (D646).

Each board keeps its own script and its own oracle, written from that
chip's documents and from what its host sent; this module holds only what
does not depend on the chip:

  * `Failed` and `require`, the one way a check refuses;
  * the trace's framing: STX, a tag letter, fields of a key letter, `=` and
    eight lowercase hex digits after a space, then ETX and LF, found
    between the echoed bytes, and the echo left when they are taken out;
  * `Run`, which runs each command, keeps its log and records its status
    and time;
  * an ELF32 reader for sections and the bytes loaded at an address, and
    the symbols `nm` lists;
  * `Probe`, probe-rs for one chip through one probe: a probehive slot over
    its CMSIS-DAP UDP transport or a bridge's TCP port, or an ST-LINK named
    by its serial; reading words, and flashing with verification and a
    readback;
  * the hub's power cycle: one `uhubctl -a cycle` of one port, only after
    the hub's listing shows the device the port must hold, or a guarded
    port holding the device that must never lose power, run through
    `sg GROUP -c` when the session is not in the group that may switch it;
  * probehive's bridge, started for a run or shared between runs and
    left running;
  * a console over probehive's UART bridge, a TCP port, or over a tty such
    as an ST-LINK's virtual COM port, found by its USB serial;
  * the record a passed run writes.

Nothing here touches a board unless a tool calls it, and nothing needs more
than the standard library, so scripts/tests/test_board_common.py runs it on
the gate's Python with no board, probe or hub.
"""

import grp
import hashlib
import json
import os
import re
import select
import shlex
import socket
import struct
import subprocess
import sys
import termios
import threading
import time
import tty
from pathlib import Path

STX, ETX, LF = 0x02, 0x03, 0x0A
FIELD = re.compile(r' ([a-z])=([0-9a-f]{8})')


class Failed(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Failed(message)


def frames(stream):
    """Every STX ... ETX frame in STREAM, as (tag, {key: value}), and the
    stream with the frames and the LF after each removed: the echo."""
    found, echo, i = [], bytearray(), 0
    while i < len(stream):
        if stream[i] == STX:
            end = stream.index(ETX, i)
            text = stream[i + 1:end].decode('ascii')
            fields = dict((k, int(v, 16)) for k, v in FIELD.findall(text))
            found.append((text[0], fields))
            i = end + 2 if end + 1 < len(stream) and stream[end + 1] == LF else end + 1
        else:
            echo.append(stream[i])
            i += 1
    return found, bytes(echo)


def complete(stream):
    """STREAM without a frame still arriving at its end."""
    start, end = stream.rfind(bytes([STX])), stream.rfind(bytes([ETX]))
    return stream if start <= end else stream[:start]


def frames_safe(stream):
    return frames(complete(stream))[0]


def echo_of(stream):
    return frames(complete(stream))[1]


def tagged(stream, tag):
    """The fields of every complete frame of STREAM tagged TAG, in order."""
    return [fields for t, fields in frames_safe(stream) if t == tag]


def frame_record(stream):
    """Every complete frame of STREAM as a result writes it."""
    return [dict(tag=t, **{k: '%08x' % v for k, v in f.items()})
            for t, f in frames_safe(stream)]


def ask(console, byte, tag, count, seconds=5):
    """Send BYTE, a command whose answer is a frame tagged TAG, and return
    that frame, the COUNT-th of its tag counting from zero."""
    console.send(bytes([byte]))
    stream = console.wait(lambda s: len(tagged(s, tag)) > count, seconds,
                          '%r frame %d' % (tag, count + 1))
    return tagged(stream, tag)[count]


class Run:
    """Every command a tool runs, its log under OUT and its record kept."""
    def __init__(self, out):
        self.out = out
        self.commands = []

    def command(self, name, argv, timeout=120, check=True, **kw):
        started = time.time()
        result = subprocess.run([str(a) for a in argv], capture_output=True, text=True,
                                timeout=timeout, **kw)
        (self.out / (name + '.log')).write_text(
            '$ ' + ' '.join(map(str, argv)) + '\n' + result.stdout + result.stderr)
        self.commands.append(dict(name=name, argv=[str(a) for a in argv],
                                  status=result.returncode,
                                  seconds=round(time.time() - started, 3)))
        if check:
            require(result.returncode == 0, '%s failed (%d); see %s.log'
                    % (name, result.returncode, self.out / name))
        return result.stdout


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def elf_sections(image):
    """Each section's (address, file offset, size) by name, from the ELF32
    header; nothing but the standard library."""
    data = Path(image).read_bytes()
    require(data[:4] == b'\x7fELF' and data[4] == 1 and data[5] == 1, 'not an ELF32 LE image')
    shoff, = struct.unpack_from('<I', data, 0x20)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', data, 0x2e)
    headers = [struct.unpack_from('<IIIIIIIIII', data, shoff + i * shentsize) for i in range(shnum)]
    names = headers[shstrndx][4]
    sections = {}
    for h in headers:
        name = data[names + h[0]:data.index(b'\0', names + h[0])].decode()
        sections[name] = (h[3], h[4], h[5])
    return data, sections


def loaded(image, address, size):
    """The SIZE bytes the ELF's loadable segments put at physical ADDRESS,
    which is where a flash programmer writes them."""
    data = Path(image).read_bytes()
    require(data[:4] == b'\x7fELF' and data[4] == 1 and data[5] == 1, 'not an ELF32 LE image')
    phoff, = struct.unpack_from('<I', data, 0x1c)
    phentsize, phnum = struct.unpack_from('<HH', data, 0x2a)
    for i in range(phnum):
        kind, offset, _, paddr, filesz, _, _, _ = struct.unpack_from('<8I', data, phoff + i * phentsize)
        if kind == 1 and paddr <= address and address + size <= paddr + filesz:
            return data[offset + address - paddr:offset + address - paddr + size]
    raise Failed('the image loads nothing for %d bytes at %#x' % (size, address))


def parse_nm(listing):
    """`nm`'s listing as {name: address}, for the symbols it gives one."""
    return {f[2]: int(f[0], 16) for f in (l.split() for l in listing.splitlines()) if len(f) == 3}


def symbols(run, nm, image):
    return parse_nm(run.command('symbols', [nm, image]))


def udp_slot(host, slot=0):
    """probe-rs's selector for a probehive slot over CMSIS-DAP UDP."""
    return '0000:0002:%s/%d' % (host, slot)


def stlink(serial, vid_pid='0483:374e'):
    """probe-rs's selector for an ST-LINK by its USB serial; 0483:374e is
    the STLINK-V3E's identity."""
    return '%s:%s' % (vid_pid, serial)


class Probe:
    """probe-rs for one CHIP through one PROBE, as probe-rs's --probe names it."""
    def __init__(self, run, probe_rs, chip, probe):
        self.run, self.probe_rs, self.chip, self.probe = run, probe_rs, chip, probe

    def argv(self, *rest):
        return [self.probe_rs, *rest, '--chip', self.chip, '--probe', self.probe]

    def read_words(self, name, address, count):
        """COUNT words from ADDRESS, read while the core runs."""
        text = self.run.command(name, self.argv('read', 'b32', hex(address), str(count)))
        # Each line begins with its address and a colon.
        words = [int(w, 16) for w in text.split() if not w.endswith(':')]
        require(len(words) == count, '%s read %d words, not %d' % (name, len(words), count))
        return words

    def flash(self, elf, address, expected, what):
        """Flash ELF and verify it, then read len(EXPECTED) bytes back from
        ADDRESS, which must be EXPECTED: WHAT says which bytes they are."""
        self.run.command('flash', self.argv('download', '--verify', elf), timeout=300)
        count = len(expected) // 4
        back = struct.pack('<%dI' % count, *self.read_words('flash-readback', address, count))
        require(back == expected, 'flash does not hold %s' % what)
        return back


def hub_ports(status):
    """uhubctl's listing of one hub as {port number: its line}."""
    return {int(k): v for k, v in re.findall(r'^\s+Port (\d+): (.*)$', status, re.MULTILINE)}


def in_group(group):
    """Whether this session may act as GROUP: a missing group is no group
    to lack."""
    try:
        gid = grp.getgrnam(group).gr_gid
    except KeyError:
        return True
    return gid == os.getgid() or gid in os.getgroups()


def as_group(argv, group, sg):
    """ARGV as it runs in GROUP: itself when the session is in it, and
    through `sg GROUP -c` when it is not, as a group added to a user after
    their login is reached."""
    if group is None or in_group(group):
        return [str(a) for a in argv]
    return [str(sg), group, '-c', shlex.join(str(a) for a in argv)]


class InGroup:
    """RUN's commands as GROUP runs them, through `as_group`: a hub's port
    files may belong to a group the session lacks."""
    def __init__(self, run, group='dialout', sg='/run/wrappers/bin/sg'):
        self.run, self.group, self.sg = run, group, sg

    def command(self, name, argv, **kw):
        return self.run.command(name, as_group(argv, self.group, self.sg), **kw)


def port_device(status, port):
    """The USB device uhubctl lists on PORT, `[VID:PID ...]`, or None when
    the port holds none, as a board running firmware without USB does."""
    line = hub_ports(status).get(port)
    found = re.search(r'\[([0-9a-f]{4}:[0-9a-f]{4}[^\]]*)\]', line or '')
    return found.group(1) if found else None


def power_cycle(hub, location, port, off_seconds, holds=None, keeps=None, holds_if_any=None):
    """Cut PORT of the hub at LOCATION and restore it, in one call.

    HOLDS is the serial the switched port must show, so that only the
    device named loses power; KEEPS is (port, serial), a port that must
    show that serial and is never switched, so that a hub whose listing is
    not the one expected is never touched.  HOLDS_IF_ANY is a serial the
    switched port must show if it shows a device at all, for a board whose
    firmware does not enumerate.  HUB has `command(name, argv)`:
    an `InGroup`, or a `Run`."""
    status = hub.command('hub-status', ['uhubctl', '-l', location])
    ports = hub_ports(status)
    if keeps:
        guard_port, guard_serial = keeps
        require(guard_port in ports and guard_serial in ports[guard_port],
                'port %d of hub %s does not hold %s; refusing to switch this hub'
                % (guard_port, location, guard_serial))
        require(port != guard_port, 'refusing to switch the guarded port')
    if holds:
        require(port in ports and holds in ports[port],
                'port %d of hub %s does not hold %s; refusing to switch it'
                % (port, location, holds))
    if holds_if_any:
        require(port in ports, 'hub %s has no port %d' % (location, port))
        device = port_device(status, port)
        require(device is None or holds_if_any in device,
                'port %d of hub %s holds %s, not %s; refusing to switch it'
                % (port, location, device, holds_if_any))
    # One call: switching the port off re-enumerates the hub's inner hubs,
    # and a second call can meet their new device nodes before udev has
    # given them the group that may switch them.
    hub.command('power-cycle', ['uhubctl', '-l', location, '-p', str(port), '-a', 'cycle',
                                '-d', '%g' % off_seconds])


class ProbehiveBridge:
    """probehive's scripts/dap_bridge.py for SLOTS slots, started for a run:
    slot N's SWD on DEBUG_PORT + N and its UART on UART_PORT + N.  A bridge
    started DETACHED is left running when the run ends, for the next tool,
    which may be another board's on another slot, to reuse."""
    def __init__(self, run, probehive, host, slots=1, debug_port=4441, uart_port=4461,
                 detached=False):
        self.path = run.out / 'bridge.log'
        self.log = open(self.path, 'w')
        self.detached = detached
        self.process = subprocess.Popen([
            sys.executable, str(Path(probehive) / 'scripts/dap_bridge.py'), '--host', host,
            '--slots', str(slots), '--listen', '127.0.0.1:%d' % debug_port,
            '--uart-listen', '127.0.0.1:%d' % uart_port], stdout=self.log, stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL, start_new_session=detached)
        deadline = time.time() + 10
        while time.time() < deadline:
            if self.path.read_text().count('listening on') >= 2 * slots:
                return
            require(self.process.poll() is None, 'the bridge exited; see bridge.log')
            time.sleep(0.1)
        raise Failed('the bridge did not listen within 10 s; see bridge.log')

    def close(self):
        if not self.detached:
            self.process.terminate()
            self.process.wait(5)
        self.log.close()


def listening(port, host='127.0.0.1'):
    """Whether something accepts a connection on PORT."""
    try:
        socket.create_connection((host, port), 1).close()
        return True
    except OSError:
        return False


def shared_bridge(run, probehive, host, slot, slots=6, debug_port=4441, uart_port=4461):
    """A probehive bridge serving SLOT's SWD and UART: the one already
    listening on both of its ports, never stopped by this run, or else one
    started detached for all SLOTS of the probe and left running, so that
    a tool on another slot reuses it rather than meeting a second client
    of the probe.  Returns (bridge or None, 'reused' or 'started')."""
    if listening(debug_port + slot) and listening(uart_port + slot):
        return None, 'reused'
    require(not listening(debug_port + slot) and not listening(uart_port + slot),
            'only one of ports %d and %d listens: something else holds them'
            % (debug_port + slot, uart_port + slot))
    return ProbehiveBridge(run, probehive, host, slots, debug_port, uart_port,
                           detached=True), 'started'


def bridged(port, host='127.0.0.1'):
    """probe-rs's selector for a slot through a bridge's TCP port."""
    return '0000:0001:%s:%d' % (host, port)


class ProbehivePins:
    """The probe's GPIO PIN through probehive's scripts/gpio.py, which needs
    the LiteX its own development shell carries: that shell's Python and its
    environment are found once, each read runs the script with them, and
    the pin is released to an input first."""
    def __init__(self, run, probehive, build, pin):
        self.run, self.probehive, self.build, self.pin = run, Path(probehive), build, pin
        found = run.command('gpio-environment', ['nix', 'develop', self.probehive, '-c',
            'python3', '-c',
            'import json, os, sys, litex; print(json.dumps([sys.executable, dict(os.environ)]))'],
            timeout=300, cwd=self.probehive)
        self.python, self.env = json.loads(found.strip().splitlines()[-1])
        self.release()

    def gpio(self, name, *pins):
        return self.run.command(name, [self.python, self.probehive / 'scripts/gpio.py',
                                       self.build, *pins], env=self.env)

    def release(self):
        self.gpio('gpio-release', self.pin + '=z')

    def level(self, name):
        for line in self.gpio(name).splitlines():
            fields = line.split()
            if fields and fields[0] == self.pin:
                require(fields[1] == 'input', '%s is driven by the probe' % fields[0])
                return int(fields[2])
        raise Failed('gpio.py listed no %s' % self.pin)


class Console:
    """A serial line as a tool sees it: every byte received and sent kept,
    and the received ones read by a thread of its own."""
    def __init__(self, baud=115200):
        self.baud = baud
        self.received = bytearray()
        self.sent = bytearray()
        self.lock = threading.Lock()
        self.alive = True
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        while self.alive:
            try:
                data = self.receive()
            except OSError:
                return
            if data is None:
                continue
            if not data:
                return
            with self.lock:
                self.received += data

    def send(self, data, pace=64):
        # In pieces a little faster than the line, so a probe's 64-byte
        # buffer toward the target is never asked to hold more.
        for i in range(0, len(data), pace):
            piece = bytes(data[i:i + pace])
            self.transmit(piece)
            self.sent += piece
            time.sleep(len(piece) * 10 / self.baud * 0.9)

    def wait(self, predicate, seconds, what):
        deadline = time.time() + seconds
        while time.time() < deadline:
            with self.lock:
                if predicate(bytes(self.received)):
                    return bytes(self.received)
            time.sleep(0.02)
        raise Failed('waited %g s for %s; received %d bytes' % (seconds, what, len(self.received)))

    def close(self):
        if self.alive:
            self.alive = False
            self.shut()
            self.reader.join(1)


class TcpConsole(Console):
    """A UART served as a TCP port, as probehive's bridge serves a slot's."""
    def __init__(self, port, host='127.0.0.1', baud=115200):
        self.socket = socket.create_connection((host, port), 5)
        self.socket.settimeout(0.05)
        super().__init__(baud)

    def receive(self):
        try:
            return self.socket.recv(4096)
        except socket.timeout:
            return None

    def transmit(self, piece):
        self.socket.sendall(piece)

    def shut(self):
        self.socket.close()


BAUDS = {9600: termios.B9600, 19200: termios.B19200, 38400: termios.B38400,
         57600: termios.B57600, 115200: termios.B115200}


class TtyConsole(Console):
    """A tty in raw mode at BAUD, 8 data bits, no parity, one stop bit."""
    def __init__(self, path, baud=115200):
        self.path = str(path)
        self.fd = os.open(self.path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        tty.setraw(self.fd)
        attributes = termios.tcgetattr(self.fd)
        attributes[2] = (attributes[2] & ~(termios.PARENB | termios.CSTOPB | termios.CRTSCTS)
                         | termios.CS8 | termios.CLOCAL | termios.CREAD)
        attributes[4] = attributes[5] = BAUDS[baud]
        termios.tcsetattr(self.fd, termios.TCSANOW, attributes)
        termios.tcflush(self.fd, termios.TCIOFLUSH)
        super().__init__(baud)

    def receive(self):
        ready, _, _ = select.select([self.fd], [], [], 0.05)
        if not ready:
            return None
        try:
            return os.read(self.fd, 4096)
        except BlockingIOError:
            return None

    def transmit(self, piece):
        view = memoryview(piece)
        while view:
            try:
                view = view[os.write(self.fd, view):]
            except BlockingIOError:
                select.select([], [self.fd], [], 0.05)
        termios.tcdrain(self.fd)

    def shut(self):
        os.close(self.fd)


def find_tty(serial, sysfs=Path('/sys/class/tty'), dev=Path('/dev')):
    """The tty whose USB device has SERIAL, as sysfs links each to its
    device, or None; with two, the one on the lowest interface."""
    found = []
    for entry in sorted(Path(sysfs).glob('*')):
        device = entry / 'device'
        if not device.exists():
            continue
        at = device.resolve()
        interface = (at / 'bInterfaceNumber')
        while at != at.parent:
            if (at / 'serial').is_file() and (at / 'idVendor').is_file():
                if (at / 'serial').read_text().strip() == serial:
                    number = interface.read_text().strip() if interface.is_file() else ''
                    found.append((number, Path(dev) / entry.name))
                break
            at = at.parent
    return min(found)[1] if found else None


def wait_for_tty(serial, seconds, sysfs=Path('/sys/class/tty'), dev=Path('/dev')):
    """The tty of SERIAL once it appears and can be opened, as a device that
    re-enumerates after its power cycle comes back."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        path = find_tty(serial, sysfs, dev)
        if path is not None and os.access(path, os.R_OK | os.W_OK):
            return path
        time.sleep(0.1)
    raise Failed('no tty for USB serial %s appeared within %g s' % (serial, seconds))


def gaps(sent, echo, probe=8):
    """Where ECHO, which should be SENT with spans left out, leaves them
    out: (offset in SENT, length) for each, found by resuming at the next
    PROBE bytes of the echo; the last is open, length None, when the echo
    no longer follows SENT.  A run that fails on its counters keeps these,
    so where it lost bytes is read from its result, not worked out by hand."""
    found, i, j = [], 0, 0
    while i < len(sent) and j < len(echo):
        if sent[i] == echo[j]:
            i, j = i + 1, j + 1
            continue
        k = sent.find(echo[j:j + probe], i)
        if k < 0:
            found.append((i, None))
            break
        found.append((i, k - i))
        i = k
    return found


def record(result, kept, sent, commands, keep_tags):
    """A passed run's record: RESULT's KEPT entries, the hash of what was
    SENT, the frames tagged one of KEEP_TAGS and the last frame, and the
    name of every command it ran."""
    out = {k: result[k] for k in kept}
    out['sent_sha256'] = hashlib.sha256(bytes(sent)).hexdigest()
    out['frames'] = [f for f in result['frames'] if f['tag'] in keep_tags] + result['frames'][-1:]
    out['commands'] = [c['name'] for c in commands]
    return out


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + '\n')
