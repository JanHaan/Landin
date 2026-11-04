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
  * the hub cascade's root, found by its hub's identity, and each board's
    hub placed relative to it;
  * the hub's power cycle: one `uhubctl -a cycle` of one port, or ports
    switched off and on together, and a wait for the hub to list again
    and show the device the next step needs; each only after
    the hub's listing shows the device the port must hold, or a guarded
    port holding the device that must never lose power, run through
    `sg GROUP -c` when the session is not in the group that may switch it;
  * probehive's bridge, started for a run or shared between runs and
    left running;
  * a console over probehive's UART bridge, a TCP port, or over a tty such
    as an ST-LINK's virtual COM port, found by its USB serial or, for a
    bridge with none, by the hub port it is plugged into, and opened, when
    its modem lines drive a board's reset, with DTR and RTS inactive;
  * the ESP application image both ESP32 ROMs load, read on its own from
    its bytes, and the log those ROMs write while they load it;
  * the record a passed run writes;
  * the rig's one lock, held by every run's hardware phase, and the pace
    of the actions that disconnect a device on its hub cascade, which stops
    a run at any USB trouble the kernel logged since the last one and which
    `python3 common.py acknowledge REASON` tells that the USB trouble the
    kernel logged so far is understood.

Nothing here touches a board unless a tool calls it, and nothing needs more
than the standard library, so scripts/tests/test_board_common.py runs it on
the gate's Python with no board, probe or hub.
"""

import argparse
import fcntl
import grp
import hashlib
import json
import os
import re
import select
import shlex
import shutil
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


class USBGuardError(Failed):
    """A USB stop that must never be treated as a retryable probe failure."""


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


RIG_LOCK = Path.home() / '.cache/landin/rig.lock'


def lock_holders(path, locks='/proc/locks'):
    """The processes holding a flock on PATH, from LOCKS."""
    inode = os.stat(path).st_ino
    holders = set()
    for line in Path(locks).read_text().splitlines():
        fields = line.split()
        # 1: FLOCK  ADVISORY  WRITE PID MAJ:MIN:INODE START END
        if len(fields) >= 6 and fields[1] == 'FLOCK' and fields[5].rsplit(':', 1)[-1] == str(inode):
            holders.add(int(fields[4]))
    return holders


def ancestors(pid=None, proc=Path('/proc')):
    """PID, by default this process, and every process above it."""
    found, pid = [], os.getpid() if pid is None else pid
    while pid > 1:
        found.append(pid)
        stat = (Path(proc) / str(pid) / 'stat').read_text()
        pid = int(stat[stat.rindex(')') + 2:].split()[1])
    return found


class RigLock:
    """The rig's one host-wide lock, an exclusive flock on PATH, held while
    a run switches power, flashes or reads a board: the runs share the
    cascade's hubs, the probe and its bridge, and a switch or a reset one
    run makes takes away a device another may be reading, so two runs at
    once disturb each other.  While another holds it, WHO waits and
    says whom for; the holder's name and process are kept in the file.  A
    run started under `flock PATH` by hand already holds it through its
    parent, and goes on.  `acquire` and `release`, or a `with` block."""
    def __init__(self, who, path=RIG_LOCK, report=None, locks='/proc/locks'):
        self.who, self.path, self.locks = who, Path(path), locks
        self.report = report or (lambda text: print(text, file=sys.stderr, flush=True))
        self.file = None

    def acquire(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.file = open(self.path, 'a+')
        try:
            fcntl.flock(self.file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if lock_holders(self.path, self.locks) & set(ancestors()[1:]):
                self.file.close()
                self.file = None
                return self
            self.file.seek(0)
            holder = self.file.read().strip() or 'a process that names none'
            self.report('%s waits for the rig lock %s, held by %s' % (self.who, self.path, holder))
            fcntl.flock(self.file, fcntl.LOCK_EX)
        self.file.seek(0)
        self.file.truncate()
        self.file.write('%s, process %d, since %s\n'
                        % (self.who, os.getpid(), time.strftime('%Y-%m-%d %H:%M:%S')))
        self.file.flush()
        return self

    def release(self):
        if self.file:
            self.file.seek(0)
            self.file.truncate()
            self.file.flush()
            fcntl.flock(self.file, fcntl.LOCK_UN)
            self.file.close()
            self.file = None

    def __enter__(self):
        return self.acquire()

    def __exit__(self, *_):
        self.release()


def rig_lock(who, path=RIG_LOCK, report=None):
    """The rig lock for WHO, a board tool's name."""
    return RigLock(who, path, report)


USB_TROUBLE = re.compile(r'error -\d+|not accepting address|unable to enumerate|attempt power cycle'
                         r'|Timeout while waiting for setup device|HC died|host controller.*(?:dead|timeout)'
                         r'|controller.*timed out|xHCI.*not responding', re.IGNORECASE)


class Pace:
    """The watch kept over a run's actions that disconnect a USB device on
    the rig's hub cascade: a download, which ends in the chip's reset, a
    port switched off or on, or a chip reset through a bridge's modem
    lines.  Any USB error the kernel logged since the last such action, by
    any tool on the host, stops the run before the next (D725); what an
    action needs before it goes, the hub listing again and the device it
    acts on present, each tool waits for itself.  With SPACING, an action
    also waits until that many seconds have passed since the last one, and
    with QUIET until the kernel has logged nothing of USB for that many
    seconds, stopping when it is not quiet within LIMIT seconds; neither is
    a default, since on the cascade's present port a switch disconnects
    only the device on the port switched.  The last action's time is kept
    in STATE beside the rig's lock; KERNEL(seconds) is the kernel's USB
    lines of the last SECONDS, as (unix time, text)."""
    def __init__(self, spacing=0, quiet=0, state=None, kernel=None, clock=time.time,
                 sleep=time.sleep, report=None, limit=600):
        self.spacing, self.quiet, self.limit = spacing, quiet, limit
        self.state = Path(state) if state else RIG_LOCK.with_name('rig.pace')
        self.kernel = kernel or kernel_usb_lines
        self.clock, self.sleep = clock, sleep
        self.report = report or (lambda text: print(text, file=sys.stderr, flush=True))
        self.started = self.until = self.clock()
        self.usb_lines = set()
        self.blocked = None

    def last(self):
        try:
            return float(self.state.read_text().split()[0])
        except (OSError, ValueError, IndexError):
            return 0.0

    def check(self, what, now=None):
        """Retain this run's USB delta and stop on unacknowledged trouble."""
        now = self.clock() if now is None else now
        last = self.last()
        self.until = max(self.until, now)
        try:
            lines = self.kernel(max(1, int(now - min(last, self.started)) + 1))
        except (Failed, OSError, subprocess.TimeoutExpired) as error:
            self.blocked = self.blocked or 'cannot read the kernel USB journal: %s' % error
            raise USBGuardError(self.blocked) from error
        self.usb_lines.update((when, text) for when, text in lines if when >= self.started)
        self.until = max(self.until, max((when for when, _ in self.usb_lines), default=now))
        trouble = [text for when, text in lines
                   if when >= last and USB_TROUBLE.search(text)]
        if trouble:
            self.blocked = self.blocked or ('the kernel logged USB trouble since the last action; stopping before'
                         ' %s: %s.  Once its cause is known and the rig is quiet,'
                         ' `python3 environments/boards/common.py acknowledge REASON` lets the'
                         ' next action go' % (what, trouble[0]))
        if self.blocked:
            raise USBGuardError(self.blocked)
        return lines

    def before(self, what):
        self.check(what)
        last = self.last()
        if self.spacing <= 0 and self.quiet <= 0:
            return
        began = self.clock()
        while True:
            now = self.clock()
            lines = self.check(what, now)
            if now - began >= self.limit:
                self.blocked = ('the kernel kept logging USB lines for %g s;'
                    ' stopping before %s: a device on the cascade keeps resetting' % (self.limit, what))
                raise USBGuardError(self.blocked)
            wait = max(last + self.spacing - now, 0)
            recent = [when for when, _ in lines if when >= now - self.quiet] if self.quiet > 0 else []
            if recent:
                wait = max(wait, max(recent) + self.quiet - now)
            if wait <= 0:
                return
            self.report('%s waits %.0f s for the rig to settle' % (what, wait))
            self.sleep(min(wait, 30))

    def after(self, what):
        # Commit the checked timestamp, never a later timestamp that could
        # hide an error logged between the scan and the state write.
        completed = self.clock()
        self.check('completion of ' + what, completed)
        self._save(what, completed)

    def _save(self, what, when):
        self.state.parent.mkdir(parents=True, exist_ok=True)
        self.state.write_text('%f %s\n' % (when, what))

    def evidence(self):
        out = dict(since=self.started, until=self.until,
                   lines=[dict(time=when, text=text) for when, text in sorted(self.usb_lines)],
                   status='failed' if self.blocked else 'captured')
        if self.blocked:
            out['error'] = self.blocked
        return out

    def acknowledge(self, reason):
        """Record that the USB trouble the kernel logged before now is
        understood, for REASON: only trouble logged after it stops a run,
        and a spacing, when the pace has one, counts from now (D835)."""
        require(reason.strip(), 'say why the trouble is understood')
        self._save('acknowledged: ' + ' '.join(reason.split()), self.clock())
        self.blocked = None


def paced(pace, what, action, guard=None, cascade=None):
    """ACTION, which may disconnect a device on the rig's hub cascade, taken
    only while PACE finds no USB trouble since the last such action on the
    host, with a completion check before recording it as the last even
    when ACTION fails; a USB failure never advances that record. With GUARD,
    a USB serial, only while that device is present and off CASCADE, as
    the probe's Arty must be (D725)."""
    if guard:
        off_cascade(guard, cascade)
    pace.before(what)
    try:
        result = action()
    except BaseException as original:
        try:
            pace.after(what)
        except (Failed, OSError, subprocess.TimeoutExpired) as completion:
            if not isinstance(original, Exception):
                raise original from completion
            failure = USBGuardError if isinstance(completion, USBGuardError) else Failed
            raise failure('%s; action completion: %s' % (original, completion)) from original
        raise
    else:
        pace.after(what)
        return result


def retain_kernel_usb(pace, result):
    """Final read-only guard/evidence capture; preserve an earlier failure."""
    try:
        pace.check('run completion')
    except (Failed, OSError, subprocess.TimeoutExpired) as error:
        result['status'] = 'failed'
        previous = result.get('failure', '')
        result['failure'] = previous if str(error) in previous else (previous + '; ' if previous else '') + str(error)
    result['kernel_usb'] = pace.evidence()


def pace_arguments(parser):
    """The options that set a tool's Pace (D725): none waits by default."""
    parser.add_argument('--spacing', type=float, default=0.0,
                        help='seconds between two actions that may disconnect a device on the'
                             ' hub cascade, by any tool on the host; none by default')
    parser.add_argument('--quiet', type=float, default=0.0,
                        help='seconds the kernel must have logged nothing of USB before one;'
                             ' none by default')


def kernel_usb_lines(seconds):
    """The kernel's USB lines of the last SECONDS, as (unix time, text)."""
    journal = subprocess.run(['journalctl', '-k', '--since', '-%ds' % seconds, '--no-pager',
                              '-o', 'short-unix'], capture_output=True, text=True)
    require(journal.returncode == 0, 'cannot read the kernel USB journal: ' + journal.stderr.strip())
    found = journal.stdout
    lines = []
    for line in found.splitlines():
        fields = line.split(None, 1)
        if len(fields) == 2 and re.search(r'\busb\b|xhci|HC died|host controller', fields[1], re.IGNORECASE):
            try:
                lines.append((float(fields[0]), fields[1]))
            except ValueError:
                continue
    return lines


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


def board_arguments(parser):
    """Shared development/boot selection; bundles need no compiler on the rig."""
    parser.add_argument('--mode', choices=('ram', 'boot'), default='ram')
    parser.add_argument('--bundle', type=Path, help='a checked offline board bundle')
    parser.add_argument('--ram-loader', type=Path, default=shutil.which('landin-ram-run'),
                        help='the pinned persistent-session SRAM loader')
    parser.add_argument('--fixed-image', type=Path, help='the resident image restored after a boot check')


def firmware_layout(args):
    return ['--firmware-layout=ram'] if getattr(args, 'mode', 'boot') == 'ram' else []


HELPER_PROBE_REVISION = '6f9946fe748edd0e55604dc42bc0f7ea3e7485da'


def helper_source_hash():
    return sha(Path(__file__).parent / 'ram-run/main.rs')


def verify_ram_helper(args):
    """Describe the installed executable without opening a probe."""
    rebuild = ('rebuild from this source with `nix build .#board-ram-run`'
        ' (or `nix build .#board-ram-run-rigpi` on epycmicro for rigpi),'
        ' then select the rebuilt bin/landin-ram-run with --ram-loader;'
        ' see environments/boards/README.md')
    try:
        described = subprocess.run([str(args.ram_loader), '--describe'],
            capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Failed('cannot describe SRAM helper %s: %s; %s' % (args.ram_loader, error, rebuild)) from error
    require(described.returncode == 0,
            'SRAM helper --describe failed: %s; %s' % (described.stderr.strip(), rebuild))
    try:
        identity = json.loads(described.stdout)
    except (ValueError, TypeError) as error:
        raise Failed('SRAM helper --describe returned invalid JSON; ' + rebuild) from error
    expected = dict(protocol_version=1, source_sha256=helper_source_hash(),
                    probe_rs_revision=HELPER_PROBE_REVISION)
    require(isinstance(identity, dict), 'SRAM helper metadata is not an object; ' + rebuild)
    for field, value in expected.items():
        require(type(identity.get(field)) is type(value) and identity.get(field) == value,
                'stale or incompatible SRAM helper: %s is %r, expected %r; %s'
                % (field, identity.get(field), value, rebuild))
    args.helper_identity = identity
    args.helper_source_sha256 = expected['source_sha256']
    return identity


def board_preflight(args, board):
    """Pure preflight, before taking the lock or touching USB."""
    if board.startswith('rp'):
        require(args.ram_loader,
                'RP readback needs the pinned single-core helper: name --ram-loader')
    elif board in ('esp32', 'esp32s3'):
        require(args.ram_loader,
                'this board needs the pinned single-core helper: name --ram-loader')
    if getattr(args, 'bundle', None):
        import bundle
        prepared = bundle.validate(args.bundle, board=board, mode=args.mode)
        if args.mode == 'boot' and not getattr(args, 'fixed_image', None):
            args.fixed_image = bundle.artifact(prepared, 'fixed_image')
    else:
        require(args.refine, 'name --bundle or --refine before running a board')
    if args.mode == 'ram':
        require(args.ram_loader, 'no SRAM loader: name one with --ram-loader')
        require(not any(getattr(args, k, False) for k in ('recover', 'block_control', 'image_control')),
                'boot/recovery controls require --mode=boot; RAM runs never reset or write flash')
        if getattr(args, 'record', None):
            require(args.record.name != 'record.json',
                    'RAM evidence is separate: use --record=ram-record.json')
    else:
        require(getattr(args, 'fixed_image', None),
                'a boot check needs --fixed-image to restore the resident image')
        require(args.fixed_image.is_file(), 'the fixed resident image does not exist')
        validate_fixed_image(args.fixed_image, board)
        fixed_marker_address(fixed_elf(args, board))
        require(not getattr(args, 'block_control', False),
                'Pico 2 corrupt controls require physical off-cascade UF2 recovery; no probe attaches in BOOTSEL')
    if args.mode == 'ram' or board.startswith('rp') or board in ('esp32', 'esp32s3'):
        verify_ram_helper(args)


def validate_fixed_image(image, board):
    """Check the recovery artifact before a boot check can touch hardware."""
    if board in ('esp32c3', 'esp32c5', 'esp32', 'esp32s3'):
        parsed = esp_image(Path(image).read_bytes())
        require(parsed['chip'] == dict(esp32c3=5, esp32c5=23, esp32=0, esp32s3=9)[board],
                'the fixed image names another ESP chip')
        return
    data, sections = elf_sections(image)
    machine = struct.unpack_from('<H', data, 18)[0]
    require(machine == (243 if board == 'rp2350_hazard3' else 40),
            'the fixed image uses another architecture')
    if board == 'rp2040':
        require('.boot2' in sections and sections['.boot2'][0] == 0x10000000
                and sections['.boot2'][2] == 256, 'fixed image lacks RP2040 boot2')
    elif board.startswith('rp2350'):
        require('.embedded_block' in sections, 'fixed image lacks a Pico 2 IMAGE_DEF block')
    require('.isr_vector' in sections, 'fixed image has no vector/trap table')
    vectors = sections['.isr_vector'][0]
    require(0x08000000 <= vectors < 0x08200000 if board == 'stm32h753'
            else 0x10000000 <= vectors < 0x10400000,
            'fixed image vectors are outside the board flash')


def finish_boot(args, result, restore):
    """Restore a resident image, unless the USB guard forbids further hardware work."""
    if args.mode != 'boot':
        return
    try:
        args.pace.before('resident image restoration')
        marker = restore()
        require(isinstance(marker, dict) and marker.get('value') == FIXED_READY_MAGIC,
                'resident restoration has no startup readiness proof')
        args.pace.before('resident image restoration completion')
        result['fixed_restore'] = dict(status='passed', sha256=sha(args.fixed_image), marker=marker)
    except (Failed, OSError, subprocess.TimeoutExpired) as error:
        result['fixed_restore'] = dict(status='pending', reason=str(error))
        result['status'] = 'failed'
        result['failure'] = result.get('failure', '') + '; resident image restoration pending: ' + str(error)


RAM_REGIONS = {
    'rp2040': ((0x20000000, 0x20042000),),
    'rp2350': ((0x20000000, 0x20082000),),
    'rp2350_hazard3': ((0x20000000, 0x20082000),),
    'stm32h753': ((0x00000000, 0x00010000), (0x20000000, 0x20020000),
                 (0x24000000, 0x24080000), (0x30000000, 0x30048000),
                 (0x38000000, 0x38010000)),
    'esp32c3': ((0x40380000, 0x403a0000), (0x3fca0000, 0x3fcc8000)),
    'esp32c5': ((0x40800000, 0x4084e000),),
    'esp32': ((0x40080000, 0x400a0000), (0x3ffb0000, 0x3ffd0000)),
    'esp32s3': ((0x40378000, 0x40398000), (0x3fca8000, 0x3fcd0000)),
}


def validate_ram_image(elf, board):
    """Check all allocated storage, including sections outside PT_LOAD."""
    data = Path(elf).read_bytes()
    headers, programs = _elf32_tables(data)
    if board in ('esp32', 'esp32s3'):
        require(struct.unpack_from('<H', data, 18)[0] == 94,
                'Xtensa RAM image has another ELF machine')
    names_header = headers[struct.unpack_from('<H', data, 50)[0]]
    strings = data[names_header[4]:names_header[4] + names_header[5]]
    sections = {}
    for header in headers:
        name_at = header[0]
        require(name_at < len(strings), 'ELF32 section name exceeds string table')
        end = strings.find(b'\0', name_at)
        require(end >= 0, 'unterminated ELF32 section name')
        try:
            name = strings[name_at:end].decode('utf-8')
        except UnicodeDecodeError as error:
            raise Failed('invalid ELF32 section name') from error
        sections[name] = header
    require(not ({'.boot2', '.embedded_block'} & sections.keys()),
            'RAM image contains boot-only sections; rebuild with --firmware-layout=ram')
    symbols = elf_symbols(elf)
    bottom, top = '_landin_firmware_stack_bottom', '_landin_firmware_stack_top'
    stack = None
    def in_ram(start, size):
        return any(lo <= start and start + size <= hi for lo, hi in RAM_REGIONS[board])
    def outside_stack(start, size):
        return stack is None or start + size <= stack[0] or start >= stack[1]
    if bottom in symbols or top in symbols:
        require(bottom in symbols and top in symbols, 'RAM ELF has incomplete reserved stack symbols')
        stack = symbols[bottom], symbols[top]
        require(stack[0] < stack[1] and in_ram(stack[0], stack[1] - stack[0]),
                'reserved stack is outside SRAM; use --mode=boot for the boot check')
    loads = [program for program in programs if program[0] == 1]
    require(any(p[4] for p in loads), 'RAM image has no loadable bytes')
    for _, offset, vaddr, paddr, filesz, memsz, _, _ in loads:
        require(in_ram(vaddr, memsz),
                'image memory exceeds SRAM; use --mode=boot for the boot check')
        require(vaddr == paddr, 'RAM ELF has a relocated load address; rebuild with --firmware-layout=ram')
        require(not memsz or outside_stack(vaddr, memsz), 'RAM segment overlaps reserved stack')
    for header in headers:
        _, kind, flags, address, offset, size, _, _, _, _ = header
        if not flags & 2 or not size:
            continue
        require(in_ram(address, size),
                'allocated section exceeds SRAM; use --mode=boot for the boot check')
        require(outside_stack(address, size), 'allocated section overlaps reserved stack')
        if kind != 8:  # SHT_NOBITS needs storage, but has no bytes to load.
            require(any(vaddr <= address and address + size <= vaddr + filesz
                        and offset == segment_offset + address - vaddr
                        for _, segment_offset, vaddr, _, filesz, _, _, _ in loads),
                    'initialized allocated section is not covered by a matching PT_LOAD')
    prefix = '_landin_firmware_'
    bss_starts = {name[:-6] for name in symbols if name.startswith(prefix) and name.endswith('_bss_start')}
    bss_ends = {name[:-4] for name in symbols if name.startswith(prefix) and name.endswith('_bss_end')}
    for name in bss_starts | bss_ends:
        require(name in bss_starts and name in bss_ends, 'RAM ELF has incomplete BSS symbols: ' + name)
        start, end = symbols[name + '_start'], symbols[name + '_end']
        require(start <= end, 'RAM ELF has reversed BSS symbols: ' + name)
        if start != end:
            require(in_ram(start, end - start), 'BSS symbols exceed SRAM; use --mode=boot for the boot check')
            require(outside_stack(start, end - start), 'BSS symbols overlap reserved stack')
    require('.isr_vector' in sections, 'RAM image has no vector/trap table')
    if board in ('esp32', 'esp32s3'):
        vectors = sections['.isr_vector']
        require(vectors[3] == RAM_REGIONS[board][0][0] and vectors[3] % 1024 == 0
                and vectors[5] == 1024, 'Xtensa RAM image needs the aligned 1 KiB vector block')
        entry = struct.unpack_from('<I', data, 24)[0]
        require(entry == vectors[3] + 1024, 'Xtensa RAM entry is not immediately after vectors')
        require(stack is not None and stack[0] % 16 == 0 and stack[1] % 16 == 0,
                'Xtensa RAM image needs its aligned reserved stack')
    return sections['.isr_vector'][3]


def consume_board(run, args, board):
    import bundle
    try:
        prepared = bundle.consume(run, args, board)
    except bundle.Invalid as error:
        raise Failed('board bundle: ' + str(error)) from error
    elf = bundle.artifact(prepared, 'elf')
    if args.mode == 'ram':
        validate_ram_image(elf, board)
    return elf, prepared['metadata'], prepared['symbols']


def ram_load(run, args, board, elf):
    """One checked session, without a flash loader or reset convenience path."""
    validate_ram_image(elf, board)
    plan, output = run.out / 'ram-plan.json', run.out / 'ram-load.json'
    write_json(plan, dict(format_version=1, board=board, mode='ram',
                          probe=args.probe, elf=str(elf.resolve())))
    args.pace.before('RAM load')
    run.command('ram-load', [args.ram_loader, '--plan', plan, '--output', output], timeout=120)
    report = json.loads(output.read_text())
    require(report.get('format_version') == 1 and report.get('status') == 'passed'
            and report.get('mode') == 'warm' and report.get('flash_written') is False
            and report.get('board') == board and report.get('elf_sha256') == sha(elf)
            and report.get('helper_source_sha256') == helper_source_hash(),
            'the SRAM loader did not return matching successful warm-load evidence')
    # Check before recording a new pacing timestamp, preserving all errors
    # since the previous action as well as those during this session.
    args.pace.before('RAM load completion')
    args.pace.after('RAM load')
    return report


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


FIXED_READY_SYMBOL = '_landin_fixed_ready'
FIXED_READY_MAGIC = 0x4c465831


def _elf32_tables(data):
    """Bounded section and program tables of a little-endian ELF32 file."""
    require(len(data) >= 52 and data[:7] == b'\x7fELF\x01\x01\x01',
            'not an ELF32 LE image')
    require(struct.unpack_from('<I', data, 20)[0] == 1
            and struct.unpack_from('<H', data, 40)[0] == 52,
            'invalid ELF32 header')
    phoff, shoff = struct.unpack_from('<II', data, 28)
    phsize, phnum, shsize, shnum, shnames = struct.unpack_from('<5H', data, 42)
    require(not phnum or (phsize == 32 and phoff >= 52
            and phoff + phnum * phsize <= len(data)), 'invalid ELF32 program table')
    require(shnum and shsize == 40 and shoff >= 52
            and shoff + shnum * shsize <= len(data), 'invalid ELF32 section table')
    headers = [struct.unpack_from('<10I', data, shoff + i * shsize) for i in range(shnum)]
    programs = [struct.unpack_from('<8I', data, phoff + i * phsize) for i in range(phnum)]
    for header in headers:
        if header[1] != 8:
            require(header[4] + header[5] <= len(data), 'ELF32 section exceeds file')
    require(shnames < shnum and headers[shnames][1] == 3,
            'invalid ELF32 section names')
    for kind, offset, _, physical, size, memory, _, _ in programs:
        require(offset + size <= len(data) and (kind != 1 or size <= memory)
                and physical + size <= 0x100000000, 'invalid ELF32 segment extent')
    return headers, programs


def _elf32_symbol_entries(image):
    data = Path(image).read_bytes()
    headers, _ = _elf32_tables(data)
    found, bindings, ambiguous = {}, {}, set()
    for header in headers:
        if header[1] != 2:
            continue
        offset, size, linked, entry_size = header[4], header[5], header[6], header[9]
        require(entry_size == 16 and size % entry_size == 0,
                'invalid ELF32 symbol table entries')
        require(linked < len(headers) and headers[linked][1] == 3,
                'invalid ELF32 symbol names')
        strings_at, strings_size = headers[linked][4:6]
        strings = data[strings_at:strings_at + strings_size]
        for position in range(offset, offset + size, entry_size):
            name_at, address, length, info, _, section = struct.unpack_from('<IIIBBH', data, position)
            require(name_at < len(strings), 'ELF32 symbol name exceeds string table')
            end = strings.find(b'\0', name_at)
            require(end >= 0, 'unterminated ELF32 symbol name')
            try:
                name = strings[name_at:end].decode('utf-8')
            except UnicodeDecodeError as error:
                raise Failed('invalid ELF32 symbol name') from error
            if not name or section == 0:
                continue
            require(section < len(headers) or section >= 0xff00,
                    'ELF32 symbol names an absent section')
            entry = (address, length, info & 15, section)
            binding = info >> 4
            # Arm mapping symbols such as $t/$d repeat at each code/data
            # boundary. Ambiguous local names have no single address.
            if name in ambiguous or (name in found and found[name] != entry):
                require(name != FIXED_READY_SYMBOL and binding == 0
                        and bindings.get(name, 0) == 0,
                        'conflicting ELF32 symbol definitions: ' + name)
                found.pop(name, None)
                ambiguous.add(name)
                continue
            found[name], bindings[name] = entry, binding
    return found, headers


def elf_symbols(image):
    """Defined ELF32 addresses, omitting ambiguous local symbol names."""
    entries, _ = _elf32_symbol_entries(image)
    return {name: entry[0] for name, entry in entries.items()}


def fixed_elf(args, board):
    """The ELF accompanying the resident image, including an ESP binary."""
    image = Path(args.fixed_image)
    if image.read_bytes()[:4] == b'\x7fELF':
        return image
    if getattr(args, 'bundle', None):
        import bundle
        try:
            prepared = bundle.validate(args.bundle, board=board, mode='boot')
            elf = bundle.artifact(prepared, 'fixed_elf')
        except bundle.Invalid as error:
            raise Failed('fixed resident ELF: ' + str(error)) from error
    else:
        elf = image.with_suffix('')
    require(elf.is_file(), 'resident readiness needs the ELF accompanying the fixed image: ' + str(elf))
    parsed = esp_image(image.read_bytes())
    data = elf.read_bytes()
    _elf32_tables(data)
    require(parsed['entry'] == struct.unpack_from('<I', data, 24)[0]
            and parsed['segments'] == [(address, body) for address, body, _ in elf_segments(elf)],
            'fixed ESP binary does not match its companion ELF')
    return elf


def fixed_marker_address(image):
    """An aligned mutable u32 marker defined by the resident ELF itself."""
    entries, headers = _elf32_symbol_entries(image)
    require(FIXED_READY_SYMBOL in entries, 'fixed ELF has no resident readiness marker')
    address, size, kind, section = entries[FIXED_READY_SYMBOL]
    require(size == 4 and kind == 1 and address % 4 == 0 and section < len(headers),
            'fixed readiness marker is not an aligned u32 datum')
    header = headers[section]
    require(header[2] & 3 == 3 and header[3] <= address
            and address + 4 <= header[3] + header[5],
            'fixed readiness marker is not in writable allocated storage')
    return address


def read_fixed_marker(probe, image):
    """Prove startup reached the resident program after its cold start."""
    address = fixed_marker_address(image)
    value, = probe.read_words('resident-ready', address, 1)
    require(value == FIXED_READY_MAGIC,
            'resident image did not reach its park loop: readiness at %#x is %#x, expected %#x'
            % (address, value, FIXED_READY_MAGIC))
    return dict(symbol=FIXED_READY_SYMBOL, address=address, value=value, elf_sha256=sha(image))


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


def elf_segments(image):
    """Each loadable segment of the ELF32 IMAGE with bytes in the file, as
    (physical address, its bytes, writable)."""
    data = Path(image).read_bytes()
    require(data[:4] == b'\x7fELF' and data[4] == 1 and data[5] == 1, 'not an ELF32 LE image')
    phoff, = struct.unpack_from('<I', data, 0x1c)
    phentsize, phnum = struct.unpack_from('<HH', data, 0x2a)
    found = []
    for i in range(phnum):
        kind, offset, _, paddr, filesz, _, flags, _ = struct.unpack_from(
            '<8I', data, phoff + i * phentsize)
        if kind == 1 and filesz:
            found.append((paddr, data[offset:offset + filesz], bool(flags & 2)))
    return found


ESP_MAGIC = 0xE9
ESP_CHECKSUM_SEED = 0xEF


def esp_checksum(segments):
    """The image's checksum byte: every segment byte exclusive-ored into
    0xEF (ESP-IDF's esp_image_format.h, ESP_ROM_CHECKSUM_INITIAL)."""
    value = ESP_CHECKSUM_SEED
    for _, body in segments:
        for byte in body:
            value ^= byte
    return value


def esp_image(data):
    """The ESP application image DATA, read from its bytes alone as ESP-IDF
    v6.1's esp_app_format.h and esp_image_format.h lay it out, and refused
    unless every part is as they say: the 8-byte header, magic 0xE9, the
    segment count, the flash mode, size and frequency byte and the entry;
    the 16-byte extended header, its chip id, revisions and the hash flag;
    each segment's 8-byte header and bytes; zero padding to the last byte
    of a 16-byte boundary, which is the checksum; the SHA-256 of all that,
    and nothing after it."""
    require(len(data) >= 24 and data[0] == ESP_MAGIC, 'the image does not begin with 0xE9')
    count, mode, size_freq, entry = data[1], data[2], data[3], struct.unpack_from('<I', data, 4)[0]
    wp_pin = data[8]
    drive = data[9:12]
    chip, legacy_min, min_rev, max_rev = struct.unpack_from('<HBHH', data, 12)
    reserved, hash_appended = data[19:23], data[23]
    require(reserved == bytes(4), 'the extended header\'s reserved bytes are not zero')
    at, segments = 24, []
    for _ in range(count):
        require(at + 8 <= len(data), 'segment %d\'s header runs past the image' % len(segments))
        address, length = struct.unpack_from('<II', data, at)
        at += 8
        require(at + length <= len(data), 'segment at %#x runs past the image' % address)
        segments.append((address, data[at:at + length]))
        at += length
    end = at | 15
    require(end < len(data), 'the image ends before its checksum')
    require(data[at:end] == bytes(end - at), 'the padding before the checksum is not zero')
    checksum = data[end]
    require(checksum == esp_checksum(segments), 'the checksum is %#04x, not %#04x'
            % (checksum, esp_checksum(segments)))
    body = data[:end + 1]
    require(hash_appended == 1, 'the image says no SHA-256 follows it')
    require(len(data) == len(body) + 32, 'the image is %d bytes, not %d'
            % (len(data), len(body) + 32))
    digest = hashlib.sha256(body).digest()
    require(data[len(body):] == digest, 'the appended SHA-256 is not the image\'s')
    return dict(entry=entry, chip=chip, min_revision=min_rev, max_revision=max_rev,
                legacy_min_revision=legacy_min, flash_mode=mode, size_freq=size_freq,
                wp_pin=wp_pin, drive=bytes(drive), segments=segments, checksum=checksum,
                sha256=digest.hex(), bytes=len(data))


ROM_RESET = re.compile(r'rst:0x([0-9a-f]+) \(([A-Z_]+)\),boot:0x([0-9a-f]+) \(([A-Z_]+)\)')
ROM_LOAD = re.compile(r'^load:0x([0-9a-f]+),len:(0x[0-9a-f]+|[0-9]+)', re.MULTILINE)
ROM_ENTRY = re.compile(r'^entry 0x([0-9a-f]+)', re.MULTILINE)
ROM_CHECKSUM = re.compile(r'Checksum failure\. Calculated 0x([0-9a-f]+) stored 0x([0-9a-f]+)')
ROM_SHA = re.compile(r'SHA-256 comparison failed:\s*Calculated: ([0-9a-f]{64})\s*Expected: ([0-9a-f]{64})')


def rom_log(text):
    """What an ESP32-C3's or ESP32-C5's ROM said while it booted: its reset
    and boot mode, each segment it loaded, the entry it took, and a
    checksum or SHA-256 it found wrong, each None when it said nothing of
    it; only the first boot in TEXT is read."""
    reset = ROM_RESET.search(text)
    if reset:
        following = ROM_RESET.search(text, reset.end())
        text = text[reset.start():following.start() if following else len(text)]
    checksum, sha = ROM_CHECKSUM.search(text), ROM_SHA.search(text)
    entry = ROM_ENTRY.search(text)
    return dict(
        reset=(int(reset.group(1), 16), reset.group(2)) if reset else None,
        boot=(int(reset.group(3), 16), reset.group(4)) if reset else None,
        loads=[(int(a, 16), int(n, 16 if n.startswith('0x') else 10))
               for a, n in ROM_LOAD.findall(text)],
        entry=int(entry.group(1), 16) if entry else None,
        checksum=(int(checksum.group(1), 16), int(checksum.group(2), 16)) if checksum else None,
        sha=(sha.group(1), sha.group(2)) if sha else None)


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
    def __init__(self, run, probe_rs, chip, probe, ram_loader=None, *, require_hart1_halted=False,
                 require_cpu1_stalled=False):
        self.run, self.probe_rs, self.chip, self.probe = run, probe_rs, chip, probe
        self.ram_loader = ram_loader
        self.require_hart1_halted = require_hart1_halted
        self.require_cpu1_stalled = require_cpu1_stalled

    def argv(self, *rest):
        pace = getattr(self.run, 'pace', None)
        if pace:
            pace.before('probe ' + (str(rest[0]) if rest else 'command'))
        return [self.probe_rs, *rest, '--chip', self.chip, '--probe', self.probe]

    def read_words(self, name, address, count):
        """COUNT words from ADDRESS, read while the core runs."""
        boards = {'RP2040': 'rp2040', 'RP235x': 'rp2350',
                  'RP235x_riscv': 'rp2350_hazard3', 'esp32': 'esp32', 'esp32s3': 'esp32s3'}
        if self.chip in boards:
            # A full two-core Session tries to access the reset-held RP
            # core 1 on drop and can leave the executing core halted.
            require(self.ram_loader, 'RP readback needs --ram-loader')
            plan, output = self.run.out / (name + '-plan.json'), self.run.out / (name + '.json')
            board = boards[self.chip]
            request = dict(format_version=1, board=board, mode='read',
                           probe=self.probe, address=address, count=count)
            if board == 'rp2350_hazard3' and self.require_hart1_halted:
                request['require_hart1_halted'] = True
            if board in ('esp32', 'esp32s3') and self.require_cpu1_stalled:
                request['require_cpu1_stalled'] = True
            write_json(plan, request)
            pace = getattr(self.run, 'pace', None)
            if pace:
                pace.before('probe read')
            self.run.command(name, [self.ram_loader, '--plan', plan, '--output', output])
            report = json.loads(output.read_text())
            words = report.get('words')
            require(report.get('format_version') == 1 and report.get('status') == 'passed'
                    and report.get('mode') == 'read' and report.get('board') == board
                    and report.get('flash_written') is False
                    and report.get('helper_source_sha256') == helper_source_hash()
                    and report.get('address') == address and report.get('count') == count
                    and isinstance(words, list) and len(words) == count
                    and all(type(word) is int and 0 <= word <= 0xffffffff for word in words),
                    'single-core readback returned invalid or mismatched evidence')
            if self.require_hart1_halted:
                require(report.get('hart1_halted') is True,
                        'single-core readback did not prove hart 1 remains halted')
            if self.require_cpu1_stalled:
                require(report.get('cpu1_stalled') is True,
                        'single-core readback did not prove CPU1 remains stalled')
            if pace:
                pace.before('probe read completion')
            return words
        text = self.run.command(name, self.argv('read', 'b32', hex(address), str(count)))
        # Each line begins with its address and a colon.
        words = [int(w, 16) for w in text.split() if not w.endswith(':')]
        require(len(words) == count, '%s read %d words, not %d' % (name, len(words), count))
        return words

    def download_bin(self, image, base):
        """Write the raw IMAGE to flash at BASE and verify it, as an ESP
        image goes where its ROM reads it (D685)."""
        self.run.command('flash', self.argv('download', '--binary-format', 'bin',
                                            '--base-address', hex(base), '--verify', image),
                         timeout=300)

    def read_bytes(self, name, address, size):
        """SIZE bytes from ADDRESS, a multiple of four, read as words."""
        words = self.read_words(name, address, size // 4)
        return struct.pack('<%dI' % len(words), *words)

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


def rerun_in_group(group, sg='/run/wrappers/bin/sg', argv=None, execv=os.execv):
    """This tool run again, ARGV as Python was given it, through `sg GROUP
    -c` when the session is not in GROUP, and nothing when it is (D836).
    A process cannot join a group it lacks, as a session started before its
    user joined one lacks it, and a tty such as a board's console belongs
    to that group, so a tool that opens one runs wholly in it."""
    if group is None or in_group(group):
        return
    execv(str(sg), [str(sg), group, '-c',
                    shlex.join([sys.executable] + list(sys.argv if argv is None else argv))])


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


def device_location(serial, sysfs=Path('/sys/bus/usb/devices')):
    """Where the USB device with SERIAL is, its hub path such as 5-1.2, or
    None."""
    for entry in sorted(Path(sysfs).glob('*')):
        if ':' in entry.name:
            continue
        try:
            if (entry / 'serial').read_text().strip() == serial:
                return entry.name
        except OSError:
            continue
    return None


def off_cascade(serial, cascade, sysfs=Path('/sys/bus/usb/devices')):
    """Require that the device with SERIAL is present and not on the hub
    cascade at CASCADE, a hub path such as 5-1: a device that must never
    lose power or re-enumerate, the probe's Arty on the rig, is kept off
    the cascade whose ports the tools switch (D725).  Returns where it is."""
    found = device_location(serial, sysfs)
    require(found is not None, 'no USB device with serial %s: refusing to switch' % serial)
    require(found != cascade and not found.startswith(cascade + '.'),
            'the device with serial %s is at %s, on the cascade %s whose ports are switched;'
            ' refusing to switch' % (serial, found, cascade))
    return found


# The rig's hub cascade is built of Realtek RTS5411 hubs, of which the
# USB2 side is this VID:PID; the cascade's root is the one such hub whose
# parent is not one (D833).
CASCADE_HUB = '0bda:5411'


def usb_identity(device):
    """The VID:PID of the USB device at DEVICE, its sysfs directory, or
    None."""
    try:
        return '%s:%s' % ((Path(device) / 'idVendor').read_text().strip(),
                          (Path(device) / 'idProduct').read_text().strip())
    except OSError:
        return None


def cascade_root(identity=CASCADE_HUB, sysfs=Path('/sys/bus/usb/devices')):
    """The hub path of the rig's hub cascade, as sysfs names its root, such
    as 5-1: the one hub that is IDENTITY, a VID:PID, and whose parent is
    not, under any controller and on any port.  The tools name each board's
    hub relative to it, so moving the cascade needs no edit (D833).
    Refuses when no hub or several are such a root."""
    roots = []
    for entry in sorted(Path(sysfs).glob('*')):
        if ':' in entry.name or entry.name.startswith('usb') or usb_identity(entry) != identity:
            continue
        parent = entry.name.rpartition('.')[0]
        if not parent or usb_identity(Path(sysfs) / parent) != identity:
            roots.append(entry.name)
    require(roots, 'no USB hub %s whose parent is another is attached, so no hub cascade was'
            ' found: attach it, or name its root with --cascade' % identity)
    require(len(roots) == 1, 'the hubs %s are each a USB hub %s whose parent is another, so the'
            ' hub cascade is not one of them alone: name its root with --cascade'
            % (', '.join(roots), identity))
    return roots[0]


RELATIVE_HUB = re.compile(r'(\.[1-9][0-9]*)+')


def on_cascade(location, cascade):
    """LOCATION, a hub path as uhubctl and sysfs name it: one relative to
    the cascade, such as .3.3, is placed under CASCADE, and any other is
    taken as it is (D833)."""
    if not location.startswith('.'):
        return location
    require(RELATIVE_HUB.fullmatch(location),
            'the hub %r is neither a hub path nor one relative to the cascade, such as .3.3'
            % location)
    return cascade + location


def cascade_argument(parser):
    """The --cascade option every tool takes: its default, None, is the root
    `cascade_root` finds."""
    parser.add_argument('--cascade',
                        help='the hub cascade whose ports are switched, as sysfs names its root;'
                             ' by default the one USB hub %s whose parent is not one, wherever'
                             ' it is attached' % CASCADE_HUB)


def place_hubs(parser, args, *names, sysfs=Path('/sys/bus/usb/devices')):
    """args.cascade found by `cascade_root` when it was not given, and each
    of NAMES, the attribute of ARGS naming a hub, placed on it by
    `on_cascade`; either refusing is PARSER's error, before anything runs."""
    try:
        if args.cascade is None:
            args.cascade = cascade_root(sysfs=sysfs)
        for name in names:
            setattr(args, name, on_cascade(getattr(args, name), args.cascade))
    except Failed as error:
        parser.error(str(error))


class Listings:
    """HUB's commands, a listing of a hub asked again while it fails until
    SECONDS have passed: a listing that meets a hub re-enumerating, or its
    nodes before udev has regrouped them, fails, and on the cascade's
    earlier port a switch, a device's reset or a listing that resumed a hub
    the kernel had suspended re-enumerated the whole tree (D832).  A
    switch, `-a`, is never asked again."""
    def __init__(self, hub, seconds):
        self.hub, self.seconds = hub, seconds

    def command(self, name, argv, **kw):
        if '-a' in argv:
            return self.hub.command(name, argv, **kw)
        deadline = time.time() + self.seconds
        while True:
            try:
                return self.hub.command(name, argv, **kw)
            except Failed:
                if time.time() >= deadline:
                    raise
                time.sleep(0.5)


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
    # One call: on the cascade's earlier port switching a port off
    # re-enumerated the hub's inner hubs, and a second call could meet their
    # new device nodes before udev had given them the group that may switch
    # them.
    hub.command('power-cycle', ['uhubctl', '-l', location, '-p', str(port), '-a', 'cycle',
                                '-d', '%g' % off_seconds])


def wait_for_hub(hub, location, shows, seconds, interval=0.5):
    """The hub at LOCATION's listing once it lists again and each (port,
    text) of SHOWS shows its text: what an action that disconnects a device
    waits for before the next.  A device switched or reset comes back in a
    few seconds, and a hub re-enumerating, as the whole cascade did on its
    earlier port (D725), lists nothing meanwhile.  With SHOWS empty, the
    hub listing at all is what is waited for."""
    deadline = time.time() + seconds
    while True:
        status = hub.command('hub-wait', ['uhubctl', '-l', location], check=False)
        ports = hub_ports(status)
        if ('Current status for hub %s ' % location in status
                and all(port in ports and text in ports[port] for port, text in shows)):
            return status
        if time.time() >= deadline:
            raise Failed('hub %s did not list %swithin %g s' % (
                location, ''.join('%s on port %d, ' % (text, port) for port, text in shows)[:-2]
                + ' ' if shows else '', seconds))
        time.sleep(interval)


def listing(hub, location, seconds, interval=0.5, name='hub-status'):
    """uhubctl's listing of the hub at LOCATION, once it lists again: a hub
    lists nothing while it re-enumerates, and a listing taken
    while udev regroups the new nodes is refused for permissions.  NAME is
    the step the listing is logged under."""
    deadline = time.time() + seconds
    while True:
        status = hub.command(name, ['uhubctl', '-l', location], check=False)
        if 'Current status for hub %s ' % location in status:
            return status
        require(time.time() < deadline, 'hub %s did not list within %g s' % (location, seconds))
        time.sleep(interval)


def switch_ports(hub, location, ports, action, holds=(), keeps=None, name=None, tries=3,
                 wait_seconds=20):
    """Switch every port of PORTS of the hub at LOCATION `off` or `on`
    together, in one call: a board fed through two of them, such as a USB
    serial bridge's port beside its debug port, loses all its power, and
    one port may come back before the other.

    HOLDS is (port, text) pairs, each a switched port whose listing must
    show TEXT, a serial or a VID:PID, before it is switched off;
    KEEPS is (port, text), a port that must show TEXT and is never
    switched, as `power_cycle`'s are."""
    require(action in ('off', 'on'), 'no uhubctl action %r' % action)
    status = listing(hub, location, wait_seconds)
    found = hub_ports(status)
    if keeps:
        guard_port, guard_text = keeps
        require(guard_port in found and guard_text in found[guard_port],
                'port %d of hub %s does not hold %s; refusing to switch this hub'
                % (guard_port, location, guard_text))
        require(guard_port not in ports, 'refusing to switch the guarded port')
    for port, text in holds if action == 'off' else ():
        require(port in ports, 'port %d is held but not switched' % port)
        require(port in found and text in found[port],
                'port %d of hub %s does not hold %s; refusing to switch it'
                % (port, location, text))
    # The hub may be re-enumerating after the last switch, when uhubctl
    # finds no hub and switches nothing: wait for it to list again, and
    # switch again.
    for attempt in range(tries):
        switched = hub.command(name or 'power-' + action,
                               ['uhubctl', '-l', location, '-p', ','.join(str(p) for p in ports),
                                '-a', action], check=False)
        if 'New status for hub %s ' % location in switched:
            return
        require(attempt < tries - 1, 'uhubctl did not switch port %s of hub %s %s'
                % (','.join(str(p) for p in ports), location, action))
        wait_for_hub(hub, location, [keeps] if keeps else [], wait_seconds)


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
    the LiteX its lightweight GPIO shell carries: that shell's Python and its
    environment are found once, when this is made, which touches nothing of
    the rig, so a tool makes it before its hardware phase; each read runs
    the script with them, and the tool releases the pin to an input before
    its first.  A shell that does not open within SECONDS is refused,
    naming the command that prepares it. The GPIO shell is available on
    arm64 without the FPGA development toolchain."""
    def __init__(self, run, probehive, build, pin, seconds=300):
        self.run, self.probehive, self.build, self.pin = run, Path(probehive), build, pin
        try:
            found = run.command('gpio-environment', ['nix', 'develop', str(self.probehive) + '#gpio', '-c',
                'python3', '-c',
                'import json, os, sys, litex; print(json.dumps([sys.executable, dict(os.environ)]))'],
                timeout=seconds, cwd=self.probehive)
        except subprocess.TimeoutExpired:
            raise Failed('probehive\'s lightweight GPIO shell, which gives scripts/gpio.py its LiteX,'
                         ' did not open within %g s; prepare it with `nix develop %s#gpio -c true`'
                         ' and run again' % (seconds, self.probehive))
        self.python, self.env = json.loads(found.strip().splitlines()[-1])

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
    """A tty in raw mode at BAUD, 8 data bits, no parity, one stop bit.

    With QUIET, DTR and RTS are made inactive as soon as the tty is open,
    and stay so when it closes: on a board whose bridge drives its reset and
    a boot strap from them, as an ESP32 board's auto-reset transistors do,
    either alone resets the chip or selects its download mode.  Linux raises
    both together when a tty opens and lowers both together when it
    closes, and that circuit holds neither line low while both are active,
    so that moment changes nothing; HUPCL is cleared so the close does not
    move them."""
    def __init__(self, path, baud=115200, quiet=False):
        self.path = str(path)
        self.fd = os.open(self.path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        if quiet:
            quiet_lines(self.fd)
        tty.setraw(self.fd)
        attributes = termios.tcgetattr(self.fd)
        attributes[2] = (attributes[2] & ~(termios.PARENB | termios.CSTOPB | termios.CRTSCTS)
                         | termios.CS8 | termios.CLOCAL | termios.CREAD)
        if quiet:
            attributes[2] &= ~termios.HUPCL
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


def quiet_lines(fd):
    """DTR and RTS inactive on the tty FD, both in one request."""
    fcntl.ioctl(fd, termios.TIOCMBIC, struct.pack('I', termios.TIOCM_DTR | termios.TIOCM_RTS))


def set_lines(fd, rts=None, dtr=None):
    """RTS, DTR or both made active (True) or inactive (False) on the tty
    FD, each named line in its own request."""
    for line, value in ((termios.TIOCM_RTS, rts), (termios.TIOCM_DTR, dtr)):
        if value is not None:
            fcntl.ioctl(fd, termios.TIOCMBIS if value else termios.TIOCMBIC, struct.pack('I', line))


def modem_lines(fd):
    """Which of DTR and RTS are active on the tty FD."""
    bits, = struct.unpack('I', fcntl.ioctl(fd, termios.TIOCMGET, struct.pack('I', 0)))
    return dict(dtr=bool(bits & termios.TIOCM_DTR), rts=bool(bits & termios.TIOCM_RTS))


def tty_at(location, sysfs=Path('/sys/class/tty'), dev=Path('/dev')):
    """The tty of the USB device at LOCATION, a hub path such as 5-1.3.4.4,
    as sysfs places it, or None; with two, the one on the lowest interface.
    A bridge without a serial of its own is told apart by where it is
    plugged in."""
    found = []
    for entry in sorted(Path(sysfs).glob('*')):
        device = entry / 'device'
        if not device.exists():
            continue
        # An ACM tty's device is its interface; a usb-serial tty's, a port
        # beneath it.
        for interface in (device.resolve(), device.resolve().parent):
            if interface.parent.name == location and interface.name.startswith(location + ':'):
                found.append((interface.name, Path(dev) / entry.name))
                break
    return min(found)[1] if found else None


def unopened(path, what, seconds):
    """The refusal for WHAT's tty, which did not appear within SECONDS, or
    appeared at PATH and could not be opened."""
    if path is None or not Path(path).exists():
        return Failed('no tty %s appeared within %g s' % (what, seconds))
    try:
        group = grp.getgrgid(os.stat(path).st_gid).gr_name
    except (KeyError, OSError):
        group = 'its group'
    return Failed('the tty %s, %s, appeared but this process may not open it: it belongs to %s,'
                  ' which the session is not in; a tool that opens a tty runs itself through'
                  ' `sg GROUP -c` with --hub-group naming that group' % (what, path, group))


def wait_for_tty_at(location, seconds, sysfs=Path('/sys/class/tty'), dev=Path('/dev')):
    """The tty at hub path LOCATION once it appears and can be opened."""
    deadline = time.time() + seconds
    path = None
    while time.time() < deadline:
        path = tty_at(location, sysfs, dev)
        if path is not None and os.access(path, os.R_OK | os.W_OK):
            return path
        time.sleep(0.05)
    raise unopened(path, 'at USB location %s' % location, seconds)


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
    path = None
    while time.time() < deadline:
        path = find_tty(serial, sysfs, dev)
        if path is not None and os.access(path, os.R_OK | os.W_OK):
            return path
        time.sleep(0.1)
    raise unopened(path, 'for USB serial %s' % serial, seconds)


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
    if 'kernel_usb' in result:
        out['kernel_usb'] = result['kernel_usb']
    out['sent_sha256'] = hashlib.sha256(bytes(sent)).hexdigest()
    out['frames'] = [f for f in result['frames'] if f['tag'] in keep_tags] + result['frames'][-1:]
    out['commands'] = [c['name'] for c in commands]
    return out


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + '\n')


def main(argv=None):
    """`acknowledge REASON`: the rig's pace told that the USB trouble the
    kernel logged so far is understood, under the rig's lock."""
    parser = argparse.ArgumentParser(description=main.__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    acknowledge = commands.add_parser(
        'acknowledge', help='let the next board run go after USB trouble whose cause is known;'
                            ' only trouble logged after now stops one')
    acknowledge.add_argument('reason', help='what the trouble was, kept in the pace file')
    args = parser.parse_args(argv)
    pace = Pace()
    try:
        with rig_lock('common.py acknowledge'):
            pace.acknowledge(args.reason)
    except Failed as error:
        parser.error(str(error))
    print('acknowledged in %s: %s' % (pace.state, pace.state.read_text().strip()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
