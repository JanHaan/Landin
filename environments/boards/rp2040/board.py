#!/usr/bin/env python3
"""Flash the prototype-1 board port to a Raspberry Pi Pico, boot it from
power-on and check its trace against the physical oracle.

    python3 environments/boards/rp2040/board.py --refine REFINE \
        --probehive DIR --probe-rs PROBE_RS --output NEW_DIRECTORY

A developer tool, not a compiler dependency: refine builds the image, and
this checks what the board does with it.  The board is reached through a
probehive slot (https://github.com/JanHaan/probehive): probe-rs reaches
its SWD through `--probe`, and the probe's bridge, DIR/scripts/dap_bridge.py,
serves its UART as a TCP port while the scenario runs; the two never hold
the slot at once.  The Pico's power is its USB port on
a hub uhubctl can switch.  The steps, each recorded under NEW_DIRECTORY:

  1. build the image and check, from the ELF alone, that its second stage
     carries the CRC-32 the boot ROM checks and that vector word 21 is the
     USBCTRL_IRQ handler;
  2. flash it with probe-rs, verify it, and read the first 256 bytes of
     flash back to compare with the image;
  3. with the probe detached, cut the Pico's power and restore it, after
     checking that the port is not the guarded one (the Arty's, whose
     bitstream lives in SRAM);
  4. read the boot frame and drive the scenario over the UART, comparing
     every echoed byte and every frame with what the host sent;
  5. read the counters back over SWD and compare them with the last frame.

The oracle is written here, from what the host sends and from the RP2040
datasheet, never from the firmware's own idea of itself; see README.md.
"""

import argparse
import hashlib
import json
import os
import random
import re
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SOURCE = ROOT / 'compiler/tests/board/rp2040'

# The board's command bytes, which it also echoes.
IRQ5, REPORT, STALL = 0x05, 0x11, 0x12
STX, ETX = 0x02, 0x03
BUDGET = 4096           # the application's DMA epoch
RING = 256              # its receive ring
CHIP_RESET_HAD_POR = 0x100
VECTORS = 0x10000100    # the second stage points VTOR past itself
CLK_REF_XOSC = 4        # CLK_REF_SELECTED's bit for source 2, the crystal
USBCTRL_SLOT = 21


class Failed(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Failed(message)


def crc32_mpeg2(data):
    """The boot ROM's CRC-32: poly 0x04C11DB7, initial 0xFFFFFFFF, no
    reflection and no final XOR (RP2040 datasheet, 2.8.1.3.1)."""
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7 if crc & 0x80000000 else crc << 1) & 0xFFFFFFFF
    return crc


def frames(stream):
    """Every STX ... ETX frame in STREAM, as (tag, {key: value}), and the
    stream with the frames and the LF after each removed: the echo."""
    found, echo, i = [], bytearray(), 0
    while i < len(stream):
        if stream[i] == STX:
            end = stream.index(ETX, i)
            text = stream[i + 1:end].decode('ascii')
            fields = dict((k, int(v, 16)) for k, v in re.findall(r' ([a-z])=([0-9a-f]{8})', text))
            found.append((text[0], fields))
            i = end + 2 if end + 1 < len(stream) and stream[end + 1] == 0x0A else end + 1
        else:
            echo.append(stream[i])
            i += 1
    return found, bytes(echo)


class Run:
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
    data = image.read_bytes()
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


def symbols(run, nm, image):
    listing = run.command('symbols', [nm, image])
    return {f[2]: int(f[0], 16) for f in (l.split() for l in listing.splitlines()) if len(f) == 3}


def build(run, args):
    elf = run.out / 'board.elf'
    run.command('compile', [args.refine, '--root=' + str(ROOT / 'devices'),
        '--root=' + str(ROOT / 'devices/generated'), '--root=' + str(ROOT / 'compiler/tests/driver'),
        '--root=' + str(SOURCE), '--target=cortex-m0', '--firmware-entry=start', '--emit=exe',
        '--build-report=' + str(run.out / 'build.json'), str(SOURCE / 'app'), '-o', str(elf)])
    data, sections = elf_sections(elf)
    address, offset, size = sections['.boot2']
    require(address == 0x10000000 and size == 256, '.boot2 is not 256 bytes at 0x10000000')
    stage = data[offset:offset + 256]
    crc = crc32_mpeg2(stage[:252])
    require(struct.unpack_from('<I', stage, 252)[0] == crc,
            'the second stage does not carry its CRC-32 %08x' % crc)
    require(any(stage[:252]), 'the second stage is empty')
    address, offset, size = sections['.isr_vector']
    require(address == VECTORS, 'the vector table is not at 0x10000100')
    words = struct.unpack_from('<%dI' % (size // 4), data, offset)
    names = symbols(run, args.nm, elf)
    require(words[USBCTRL_SLOT] == names['usb_irq'] | 1, 'vector word 21 is not the USBCTRL_IRQ handler')
    return elf, stage, crc, names


class Bridge:
    """probehive's bridge for one slot, started for this run."""
    def __init__(self, run, args):
        self.log = open(run.out / 'bridge.log', 'w')
        self.process = subprocess.Popen([sys.executable, str(args.probehive / 'scripts/dap_bridge.py'),
            '--host', args.probe_host, '--slots', '1', '--listen', '127.0.0.1:%d' % args.debug_port,
            '--uart-listen', '127.0.0.1:%d' % args.uart_port], stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.time() + 10
        while time.time() < deadline:
            text = (run.out / 'bridge.log').read_text()
            if text.count('listening on') >= 2:
                return
            require(self.process.poll() is None, 'the bridge exited; see bridge.log')
            time.sleep(0.1)
        raise Failed('the bridge did not listen within 10 s; see bridge.log')

    def close(self):
        self.process.terminate()
        self.process.wait(5)
        self.log.close()


def probe_rs(args, *rest):
    return [args.probe_rs, *rest, '--chip', 'RP2040', '--probe', args.probe]


def read_words(run, args, name, address, count):
    text = run.command(name, probe_rs(args, 'read', 'b32', hex(address), str(count)))
    words = [int(w, 16) for w in text.split()]
    require(len(words) == count, '%s read %d words, not %d' % (name, len(words), count))
    return words


def flash(run, args, elf, stage):
    run.command('flash', probe_rs(args, 'download', '--verify', elf), timeout=300)
    back = struct.pack('<64I', *read_words(run, args, 'flash-readback', 0x10000000, 64))
    require(back == stage, 'flash does not hold the image\'s second stage')
    return back


def hub(run, args, *rest, name):
    return run.command(name, ['uhubctl', '-l', args.hub, *rest])


def power_cycle(run, args):
    status = hub(run, args, name='hub-status')
    ports = dict(re.findall(r'^\s+Port (\d+): (.*)$', status, re.MULTILINE))
    require(str(args.guard_port) in ports and args.guard_serial in ports[str(args.guard_port)],
            'port %d of hub %s does not hold %s; refusing to switch this hub'
            % (args.guard_port, args.hub, args.guard_serial))
    require(args.port != args.guard_port, 'refusing to switch the guarded port')
    hub(run, args, '-p', str(args.port), '-a', 'off', name='power-off')
    time.sleep(args.off_seconds)
    hub(run, args, '-p', str(args.port), '-a', 'on', name='power-on')


class Console:
    """The slot's UART through the bridge, every byte kept."""
    def __init__(self, port):
        self.socket = socket.create_connection(('127.0.0.1', port), 5)
        self.socket.settimeout(0.05)
        self.received = bytearray()
        self.sent = bytearray()
        self.lock = threading.Lock()
        self.alive = True
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        while self.alive:
            try:
                data = self.socket.recv(4096)
            except socket.timeout:
                continue
            except OSError:
                return
            if not data:
                return
            with self.lock:
                self.received += data

    def send(self, data, pace=64):
        # In pieces a little faster than the line, so the probe's 64-byte
        # buffer toward the target is never asked to hold more.
        for i in range(0, len(data), pace):
            piece = bytes(data[i:i + pace])
            self.socket.sendall(piece)
            self.sent += piece
            time.sleep(len(piece) * 10 / 115200 * 0.9)

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
            self.socket.close()
            self.reader.join(1)


def complete(stream):
    """STREAM without a frame still arriving at its end."""
    start, end = stream.rfind(bytes([STX])), stream.rfind(bytes([ETX]))
    return stream if start <= end else stream[:start]


def frames_safe(stream):
    return frames(complete(stream))[0]


def echo_of(stream):
    return frames(complete(stream))[1]


def report(console, count):
    """Ask for a telemetry frame and return it."""
    console.send(bytes([REPORT]))
    stream = console.wait(lambda s: sum(1 for t, _ in frames_safe(s) if t == 't') > count, 5,
                          'telemetry frame %d' % (count + 1))
    return [f for t, f in frames_safe(stream) if t == 't'][count]


def scenario(console, run, seed):
    """The board-port scenario and its oracle.  Returns the verdicts and
    the last telemetry frame."""
    verdicts = {}
    stream = console.wait(lambda s: any(t == 'b' for t, _ in frames_safe(s)), 5, 'the boot frame')
    boot = [f for t, f in frames_safe(stream) if t == 'b'][0]
    require(boot['r'] == CHIP_RESET_HAD_POR,
            'CHIP_RESET is %08x, not a power-on reset alone' % boot['r'])
    require(boot['v'] == VECTORS, 'VTOR is %08x: the second stage did not run' % boot['v'])
    require(boot['k'] == CLK_REF_XOSC, 'clk_ref is not on the crystal: %08x' % boot['k'])
    verdicts['boot'] = dict(chip_reset=boot['r'], vtor=boot['v'], clk_ref_selected=boot['k'])
    seen = 0
    # The indicator: 1 sets GPIO2, 0 clears it; the pad's input reads it back.
    console.send(b'x1')
    high = report(console, seen); seen += 1
    console.send(b'y0')
    low = report(console, seen); seen += 1
    require(high['g'] == 4 and low['g'] == 0,
            'GPIO2 read back %x after 1 and %x after 0' % (high['g'], low['g']))
    verdicts['indicator'] = dict(after_1=high['g'], after_0=low['g'])
    # IRQ5, set pending in the NVIC: slot 21's handler runs once, in
    # exception 21.
    console.send(bytes([IRQ5]))
    usb = report(console, seen); seen += 1
    require(usb['u'] == 1 and usb['p'] == USBCTRL_SLOT,
            'USBCTRL_IRQ ran %d times in exception %d' % (usb['u'], usb['p']))
    verdicts['irq5'] = dict(entries=usb['u'], exception=usb['p'])
    epoch = len(console.sent)
    require(epoch < RING, 'the scenario overran before its burst')
    # An overrun: the application stops reading for 100 ms after echoing
    # STALL, and a burst longer than the ring arrives meanwhile.  It is
    # discarded, never echoed, and the ring restarts.
    console.send(bytes([STALL]))
    console.wait(lambda s: STALL in echo_of(s), 2, 'the echo of STALL')
    rng = random.Random(seed)
    burst = bytes(rng.randrange(0x20, 0x7f) for _ in range(300))
    console.send(burst, pace=300)
    time.sleep(0.3)
    overrun = report(console, seen); seen += 1
    require(overrun['c'] == 1, 'the overrun made %d recoveries, not 1' % overrun['c'])
    verdicts['overrun'] = dict(burst=len(burst), recoveries=overrun['c'])
    epoch = 1                   # REPORT, the restarted ring's first byte
    # A stream across two exhaustions: every byte echoed, in order.
    stream_bytes = bytes(rng.randrange(0x20, 0x7f) for _ in range(12000))
    console.send(stream_bytes)
    epoch += len(stream_bytes)
    before = report(console, seen); seen += 1
    epoch += 1
    exhaustions = epoch // BUDGET
    final = report(console, seen); seen += 1
    require(final['c'] == 1 + exhaustions, '%d recoveries, not %d' % (final['c'], 1 + exhaustions))
    require(final['d'] == exhaustions, '%d DMA completions, not %d' % (final['d'], exhaustions))
    require(final['m'] > before['m'] > high['m'], 'the timer did not advance')
    echo = echo_of(console.wait(lambda s: True, 1, 'the stream'))
    start = bytes(console.sent).index(burst)
    expected = bytes(console.sent[:start] + console.sent[start + len(burst):])
    require(echo == expected, 'the echo differs from what was sent, first at byte %d'
            % next((i for i, (a, b) in enumerate(zip(echo, expected)) if a != b), min(len(echo), len(expected))))
    require(final['h'] == len(expected), 'handled %d bytes, not %d' % (final['h'], len(expected)))
    verdicts['stream'] = dict(bytes=len(stream_bytes), exhaustions=exhaustions,
                              recoveries=final['c'], dma_completions=final['d'],
                              timer_events=final['m'], echoed=len(echo))
    return verdicts, final


def cross_check(run, args, names, final):
    """The counters as SWD reads them, without halting, against the frame."""
    pairs = [('handled', 'h'), ('recoveries', 'c'), ('dma_events', 'd'), ('usb_events', 'u')]
    read = {name: read_words(run, args, 'swd-' + name, names[name], 1)[0] for name, _ in pairs}
    for name, key in pairs:
        require(read[name] == final[key], '%s reads %d over SWD, %d in the frame'
                % (name, read[name], final[key]))
    count = read_words(run, args, 'swd-trans-count', 0x50000008, 1)[0]
    require(count == final['n'], 'TRANS_COUNT reads %d over SWD, %d in the frame' % (count, final['n']))
    return dict(read, trans_count=count)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--probehive', type=Path, required=True, help='a probehive checkout')
    parser.add_argument('--probe-rs', type=Path, default=shutil.which('probe-rs'),
                        help='a probe-rs that reaches the probe named by --probe')
    parser.add_argument('--probe', default='0000:0002:10.42.0.50/0',
                        help="probe-rs's --probe for the slot: its CMSIS-DAP UDP transport by default,"
                             " or 0000:0001:HOST:PORT for TCP through a bridge of its own")
    parser.add_argument('--nm', default=shutil.which('arm-eabi-nm') or shutil.which('arm-none-eabi-nm'))
    parser.add_argument('--output', type=Path, required=True, help='a new directory')
    parser.add_argument('--probe-host', default='10.42.0.50')
    parser.add_argument('--debug-port', type=int, default=4441)
    parser.add_argument('--uart-port', type=int, default=4461)
    parser.add_argument('--hub', default='7-2.3.3', help="the Pico's hub, as uhubctl -l names it")
    parser.add_argument('--port', type=int, default=1, help="the Pico's port on it")
    parser.add_argument('--guard-port', type=int, default=4, help='a port never switched')
    parser.add_argument('--guard-serial', default='210319B3E738',
                        help='the serial the guarded port must show, or the hub is not switched')
    parser.add_argument('--off-seconds', type=float, default=1.0)
    parser.add_argument('--seed', type=int, default=1220)
    args = parser.parse_args()
    require(args.probe_rs, 'no probe-rs: name one with --probe-rs')
    require(args.nm, 'no arm-eabi-nm or arm-none-eabi-nm on PATH: name one with --nm')
    args.output = args.output.resolve()
    args.output.mkdir(parents=True)
    run = Run(args.output)
    result = dict(status='failed')
    bridge = console = None
    try:
        elf, stage, crc, names = build(run, args)
        result.update(image_sha256=sha(elf), second_stage_crc32='%08x' % crc,
                      second_stage_sha256=hashlib.sha256(stage).hexdigest())
        flash(run, args, elf, stage)
        result['flash_readback'] = 'matches'
        bridge = Bridge(run, args)
        console = Console(args.uart_port)
        power_cycle(run, args)
        verdicts, final = scenario(console, run, args.seed)
        result['verdicts'] = verdicts
        console.close()
        bridge.close()
        bridge = None
        result['swd'] = cross_check(run, args, names, final)
        result['status'] = 'passed'
    except (Failed, subprocess.TimeoutExpired, OSError) as error:
        result['failure'] = str(error)
    finally:
        if console:
            console.close()
            (args.output / 'uart.bin').write_bytes(bytes(console.received))
            (args.output / 'sent.bin').write_bytes(bytes(console.sent))
            result['uart_sha256'] = hashlib.sha256(bytes(console.received)).hexdigest()
            result['frames'] = [dict(tag=t, **{k: '%08x' % v for k, v in f.items()})
                                for t, f in frames_safe(bytes(console.received))]
        if bridge:
            bridge.close()
        result['commands'] = run.commands
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('board %s: %s%s' % (result['status'], args.output,
                              '' if result['status'] == 'passed' else ': ' + result['failure']))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
