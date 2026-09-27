"""The synthetic device contracts the Cortex-M lanes execute against.

Each class is a literal contract: its offsets, masks and replies are written
here, independently of the generated device modules, the SVD metadata and
the firmware under test.  An access the contract does not name raises
Refused, which fails the lane.  Stimulus methods (`feed`, `tick`,
`inject_error`, ...) are the test's, called while the CPU is stopped.

`EncodingPeripheral` has no CPU behind it in the hosted lane: its `bus` is
called directly by the line transport.
"""
from machine import Model, Refused


def check(value, mask):
    if value & ~mask:
        raise Refused('reserved bits')


class FixturePeripheral(Model):
    """Generated device fixtures' literal contract.  Not an RP2040 emulator."""
    LINES = {'irq': 0}

    def __init__(self):
        self.events = []
        self.gpio, self.fifo = 31, 0
        self.output = self.transmitted = 0
        self.remaining = self.transfers = self.configuration = self.pending = 0
        self.source = self.destination = self.enabled = 0
        self.timer_pending, self.alarm = 3, 0

    @property
    def trace(self):
        return ';'.join(self.events)

    def level(self, name):
        return (self.pending & self.enabled) != 0

    def read(self, offset, width):
        if width != 4:
            raise Refused('word transaction required')
        if offset == 4: value = self.gpio
        elif offset == 0x104: value = 0
        elif offset == 0x110: value = self.output
        elif offset == 0x200:
            if self.fifo > 1:
                raise Refused('empty synthetic FIFO')
            value = 0x41 + self.fifo
            self.fifo += 1
        elif offset == 0x218: value = 0x90
        elif offset == 0x328: value = 7
        elif offset == 0x334: value = self.timer_pending
        elif offset == 0x1008: value = self.remaining
        elif offset == 0x100c:
            value = self.configuration | (0x1000000 if self.remaining else 0)
        elif offset == 0x1400: value = self.pending
        else:
            raise Refused('forbidden read or unknown fixture register')
        self.events.append('r32:%x:%08x' % (offset, value))
        return value

    def write(self, offset, width, value):
        if width != 4:
            raise Refused('word transaction required')
        if offset == 4: check(value, 0x3003331f); self.gpio = value
        elif offset == 0x114: check(value, 0x3fffffff); self.output |= value
        elif offset == 0x118: check(value, 0x3fffffff); self.output &= ~value
        elif offset == 0x200: check(value, 0xff); self.transmitted = value
        elif offset == 0x244: check(value, 0x7ff)
        elif offset == 0x310: self.alarm = value
        elif offset == 0x334: check(value, 0xf); self.timer_pending &= ~value
        elif offset == 0x1000: self.source = value
        elif offset == 0x1004: self.destination = value
        elif offset == 0x1008:
            if value != 4:
                raise Refused('only four-byte fixture DMA')
            self.remaining = value
        elif offset == 0x100c:
            if value not in (0xa8020, 0xa8021):
                raise Refused('unsupported synthetic DMA config')
            self.configuration = value
        elif offset == 0x1400: check(value, 0xffff); self.pending &= ~value
        elif offset == 0x1404: check(value, 1); self.enabled = value
        else:
            raise Refused('forbidden write or unknown fixture register')
        self.events.append('w32:%x:%08x' % (offset, value))

    # Explicit stopped-time premise: byte first, count/status afterward.  The
    # half notification is synthetic and is not an RP2040 DMA feature.
    def feed(self, value):
        if (value > 255 or not self.configuration & 1 or not self.remaining or
                self.source != 0x40070200 or self.destination < 0x20000000 or
                self.destination + 4 > 0x20003000):
            raise Refused('invalid synthetic DMA descriptor')
        self.ram(self.destination + self.transfers, value)
        self.transfers += 1
        self.remaining -= 1
        self.events.append('dma8:%d:%02x' % (self.transfers - 1, value))
        if self.remaining in (2, 0):
            self.pending = 1
        if self.remaining == 0:
            self.configuration &= ~1


class PrototypePeripheral(Model):
    """Prototype 1's synthetic GPIO/UART/DMA contract.  Not an STM32 model."""
    LINES = {'irq': 0}
    TALLIES = ('reads', 'writes', 'count_half_reads', 'count_word_reads',
               'count_half_writes', 'count_word_writes')
    KNOWN = {0, 4, 8, 12, 0x10, 0x14, 0x18, 0x1c, 0x20, 0x24,
             0x1000, 0x1004, 0x6058, 0x605c, 0x6060, 0x6064}

    def __init__(self):
        self.reset()

    def reset(self):
        self.regs = {}
        self.count = self.initial = self.position = self.status = 0
        self.count_half_reads = self.count_half_writes = 0
        self.count_word_reads = self.count_word_writes = 0
        self.transfers = self.errors = self.reads = self.writes = 0

    def get(self, offset):
        return self.regs.get(offset, 0)

    @property
    def remaining(self):
        return self.count

    @property
    def configuration(self):
        return self.get(0x6058)

    def level(self, name):
        cfg = self.get(0x6058)
        return ((self.status & 0x20 and cfg & 2) or (self.status & 0x40 and cfg & 4)
                or (self.status & 0x80 and cfg & 8)) != 0

    def read(self, offset, width):
        if width == 2:
            if offset not in (0x10, 0x14, 0x605c):
                raise Refused('unsupported halfword read')
            if offset == 0x605c:
                self.count_half_reads += 1
                self.reads += 1
                return self.count & 0xffff
            return self.read(offset, 4) & 0xffff
        if width != 4:
            raise Refused('unsupported byte access')
        self.reads += 1
        if offset == 0x6000:
            return self.status
        if offset == 0x605c:
            self.count_word_reads += 1
            return self.count
        if offset in (0x6004, 0x18):
            raise Refused('read from write-only register')
        if offset not in self.KNOWN:
            raise Refused('unsupported register read')
        return self.get(offset)

    def write(self, offset, width, value):
        if width == 2:
            if offset not in (0x14, 0x605c):
                raise Refused('unsupported halfword write')
            self.write(offset, 4, value)
            if offset == 0x605c:
                self.count_half_writes += 1
                self.count_word_writes -= 1
            return
        if width != 4:
            raise Refused('unsupported byte access')
        self.writes += 1
        if offset in (0x6000, 0x10):
            raise Refused('write to read-only register')
        if offset == 0x6004:
            self.status &= ~value
            return
        if offset == 0x18:
            self.regs[0x14] = (self.get(0x14) | (value & 0xffff)) & ~(value >> 16)
            return
        if offset not in self.KNOWN:
            raise Refused('unsupported register write')
        if offset == 0x605c:
            self.count_word_writes += 1
            if value > 65535:
                raise Refused('count exceeds 16 bits')
            self.count = self.initial = value
            self.position = 0
        self.regs[offset] = value

    def set_input(self, value):
        self.regs[0x10] = value

    # One UART byte per call, while the CPU is stopped.
    def feed(self, value):
        if value > 255:
            raise Refused('not a byte')
        self.regs[0x1004] = value
        cfg = self.get(0x6058)
        if not cfg & 1:
            return
        if (self.count == 0 or cfg & 0xc0 or self.get(0x6060) != 0x40021004
                or self.get(0x6064) < 0x20000000 or self.get(0x6064) + self.initial > 0x20003000):
            self.error()
            return
        self.ram(self.get(0x6064) + (self.position if cfg & 0x400 else 0), value)
        self.transfers += 1
        self.position += 1
        self.count -= 1
        if self.count == self.initial // 2:
            self.status |= 0x40
        if self.count == 0:
            self.status |= 0x20
            if cfg & 0x100:
                self.count, self.position = self.initial, 0
            else:
                self.regs[0x6058] = cfg & ~1

    def error(self):
        self.errors += 1
        self.status |= 0x80
        self.regs[0x6058] = self.get(0x6058) & ~1


class EncodingPeripheral(Model):
    """Packed-image access contract, independent of the firmware's bit algebra."""
    LINES = {}

    def __init__(self):
        self.events = []
        self.normal, self.destructive = 0xa50000f0, 0x9b
        self.command, self.pending, self.count = 0, 0xf3, 0xffff
        self.ones = 0xffffff00
        self.byte_destructive, self.byte_command, self.byte_pending = 0xa5, 0, 0xf3

    @property
    def trace(self):
        return ';'.join(self.events)

    def read(self, offset, width):
        if width == 4:
            if offset == 0: value = self.normal
            elif offset == 4: value, self.destructive = self.destructive, 0
            elif offset == 8: raise Refused('write-only image')
            elif offset == 12: value = self.pending
            elif offset == 20: value = self.ones
            else: raise Refused('wrong read width or address')
            self.events.append('r32:%x:%08x' % (offset, value))
        elif width == 2:
            if offset != 16:
                raise Refused('wrong halfword read')
            value = self.count
            self.events.append('r16:10:%04x' % value)
        else:
            if offset == 24: value, self.byte_destructive = self.byte_destructive, 0
            elif offset == 26: value = self.byte_pending
            else: raise Refused('wrong byte read or write-only port')
            self.events.append('r8:%x:%02x' % (offset, value))
        return value

    def write(self, offset, width, value):
        if width == 4:
            if offset == 0:
                # The device, not the bit algorithm, pins reserved bits 8..31.
                if value & 0xffffff00 != 0xa5000000:
                    raise Refused('reserved image changed')
                self.normal = value
            elif offset == 8:
                if value & 0xffffff00:
                    raise Refused('command reserved bits must be zero')
                self.command = value
            elif offset == 12:
                if value & 0xffffff00:
                    raise Refused('clear reserved bits must be zero')
                self.pending &= ~value
            elif offset == 20:
                if value & 0xffffff00 != 0xffffff00:
                    raise Refused('reserved bits must be one')
                self.ones = value
            else:
                raise Refused('forbidden write or width')
            self.events.append('w32:%x:%08x' % (offset, value))
        elif width == 2:
            if offset != 16:
                raise Refused('wrong halfword write')
            self.count = value
            self.events.append('w16:10:%04x' % value)
        else:
            if offset == 25: self.byte_command = value
            elif offset == 26: self.byte_pending &= ~value
            else: raise Refused('wrong byte write')
            self.events.append('w8:%x:%02x' % (offset, value))


class DriverPeripheral(Model):
    """The derived driver's synthetic protocol.  Not an RP2040 emulator.

    The count never reloads within an epoch; half and full are coalescing
    hints.  EN-clear requests a drain and BUSY-clear acknowledges it, which
    RP2040's EN-clear does not promise.
    """
    LINES = {'irq': 0, 'timer': 1}
    TALLIES = ('events', 'output_bytes')

    def __init__(self):
        self.events, self.output_bytes = [], []
        self.gpio0 = self.gpio1 = 0x3000001f
        self.remaining = self.transfers = self.configuration = self.output = 0
        self.pending = self.alarm = 0
        self.integer_divisor = self.fraction_divisor = self.line_control = 0
        self.dma_control = self.rejected = 0
        self.source = self.destination = self.enabled = 0
        self.timer_pending = self.clock = self.errors = 0
        self.busy = self.alarm_armed = False
        self.stop_reads = self.stop_delay = 0
        self.pending_byte = -1

    @property
    def trace(self):
        return ';'.join(self.events)

    @property
    def output_text(self):
        return ','.join(str(b) for b in self.output_bytes)

    @property
    def alarm_pending(self):
        return self.timer_pending != 0

    def level(self, name):
        if name == 'irq':
            return (self.pending & self.enabled) != 0
        return self.timer_pending != 0

    def clear_trace(self):
        self.events.clear()

    def delay_stop(self, reads, value):
        if reads < 0 or value > 255 or value < -1:
            raise Refused('bad stop injection')
        self.stop_delay, self.pending_byte = reads, value

    def inject_error(self):
        self.errors = 0x20000000
        self.configuration &= ~1
        self.busy = False
        self.pending |= 1

    def repair(self):
        """Explicit external maintenance after proven quiescence."""
        if self.busy:
            raise Refused('repair while active')
        self.errors = 0

    def tick(self, amount):
        distance = (self.alarm - self.clock) & 0xffffffff
        self.clock = (self.clock + amount) & 0xffffffff
        if self.alarm_armed and distance <= amount:
            self.alarm_armed = False
            self.timer_pending |= 1

    def read(self, offset, width):
        if width != 4:
            raise Refused('word MMIO required')
        if offset == 4: value = self.gpio0
        elif offset == 12: value = self.gpio1
        elif offset == 0x110: value = self.output
        elif offset == 0x218: value = 0x90
        elif offset == 0x328: value = self.clock
        elif offset == 0x334: value = self.timer_pending
        elif offset == 0x1008: value = self.remaining
        elif offset == 0x100c:
            if not self.configuration & 1 and self.busy:
                if self.pending_byte >= 0:
                    self.transfer(self.pending_byte)
                    self.pending_byte = -1
                if self.stop_reads > 0:
                    self.stop_reads -= 1
                else:
                    self.busy = False
            value = self.configuration | self.errors | (0x01000000 if self.busy else 0)
        elif offset == 0x1400: value = self.pending
        else:
            raise Refused('forbidden driver read')
        self.events.append('r32:%x:%08x' % (offset, value))
        return value

    def write(self, offset, width, value):
        if width != 4:
            raise Refused('word MMIO required')
        if offset == 4: check(value, 0x3003331f); self.gpio0 = value
        elif offset == 12: check(value, 0x3003331f); self.gpio1 = value
        elif offset == 0x114: check(value, 0x3fffffff); self.output |= value
        elif offset == 0x118: check(value, 0x3fffffff); self.output &= ~value
        elif offset == 0x200: check(value, 255); self.output_bytes.append(value)
        elif offset == 0x224: check(value, 65535); self.integer_divisor = value
        elif offset == 0x228: check(value, 63); self.fraction_divisor = value
        elif offset == 0x22c: check(value, 255); self.line_control = value
        elif offset == 0x248: check(value, 7); self.dma_control = value
        elif offset == 0x244: check(value, 0x7ff)
        elif offset == 0x310: self.alarm, self.alarm_armed = value, True
        elif offset == 0x334: check(value, 15); self.timer_pending &= ~value
        elif offset == 0x1000: self.idle(); self.source = value
        elif offset == 0x1004: self.idle(); self.destination = value
        elif offset == 0x1008:
            self.idle()
            if value == 0 or value > 65535:
                raise Refused('finite DMA count')
            self.remaining, self.transfers = value, 0
        elif offset == 0x100c:
            check(value, 0xffffff)
            if value & ~0x3c1 != 0xa8420:
                raise Refused('wrong byte/ring/request config')
            if not value & 1 and self.configuration & 1:
                self.stop_reads = self.stop_delay
            self.configuration = value
            if value & 1:
                size = 1 << ((value >> 6) & 15)
                if (size < 2 or size > 256 or self.destination % size or
                        self.source != 0x40070200 or self.destination < 0x20000000 or
                        self.destination + size > 0x20003000 or self.errors):
                    raise Refused('invalid ring descriptor')
                self.busy = self.remaining != 0
            elif self.stop_reads == 0 and self.pending_byte < 0:
                self.busy = False
        elif offset == 0x1400: check(value, 1); self.pending &= ~value
        elif offset == 0x1404: check(value, 1); self.enabled = value
        else:
            raise Refused('forbidden driver write')
        self.events.append('w32:%x:%08x' % (offset, value))

    def feed(self, value):
        if value > 255:
            raise Refused('not a byte')
        if not self.configuration & 1 or self.remaining == 0 or self.errors:
            self.rejected += 1
            return
        self.transfer(value)

    def transfer(self, value):
        if self.remaining == 0:
            raise Refused('counter exhausted')
        size = 1 << ((self.configuration >> 6) & 15)
        index = self.transfers % size
        self.ram(self.destination + index, value)
        self.events.append('dma8:%d:%02x' % (index, value))
        self.transfers += 1
        self.remaining -= 1
        # Data publication precedes the monotone count.  Ring addresses wrap;
        # this transfer count never reloads.
        if self.transfers % (size // 2) == 0 or self.remaining == 0:
            self.pending |= 1
        if self.remaining == 0:
            self.configuration &= ~1
            self.busy = False

    def idle(self):
        if self.busy:
            raise Refused('descriptor changed before drain')
