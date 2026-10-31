"""The device accesses a linked ARMv6-M firmware image makes, found by
evaluating its instructions (D561).

No emulator models the STM32H753, and none is needed to know what the
compiled consumer asks of it: the image's instructions, from its reset
vector, over memory that is nothing but the image's own bytes, determine
every load and store it makes outside that memory.  This evaluates the
ARMv6-M Thumb instruction set the Cortex-M backend emits -- every 16-bit
encoding, BL, MRS, MSR and the three barriers -- and records, in order,
each access to a window the caller names as a device, with its address,
its width and the value stored.  A load from a device window returns zero,
or what the caller's `reads` answers.  It stops at the first WFI, and
refuses an instruction it does not know, an access outside the image's
memory and the device windows, a misaligned access, or more steps than its
limit.

It models no peripheral, no exception, no interrupt and no clock: it is a
reading of the linked image, not a run of a chip, and an image whose
accesses depend on a device's behaviour is outside it.
"""
import struct


class Refused(Exception):
    """The image did something this evaluation does not follow."""


class Image:
    """A 32-bit little-endian ARM ELF executable's loadable bytes."""

    def __init__(self, data):
        if data[:4] != b'\x7fELF' or data[4] != 1 or data[5] != 1:
            raise Refused('not a 32-bit little-endian ELF file')
        (self.entry, phoff, shoff, _, _, phentsize, phnum,
         shentsize, shnum, shstrndx) = struct.unpack_from('<IIIIHHHHHH', data, 24)
        self.segments = []
        for index in range(phnum):
            (kind, offset, vaddr, paddr, filesz, memsz, flags,
             _) = struct.unpack_from('<IIIIIIII', data, phoff + index * phentsize)
            if kind == 1:
                self.segments.append((paddr, data[offset:offset + filesz], memsz))
        self.symbols = {}
        sections = [struct.unpack_from('<IIIIIIIIII', data, shoff + i * shentsize)
                    for i in range(shnum)]
        for (_, kind, _, _, offset, size, link, _, _, entsize) in sections:
            if kind == 2:
                strings = sections[link]
                for at in range(offset, offset + size, entsize):
                    name, value, _, info, _, _ = struct.unpack_from('<IIIBBH', data, at)
                    start = strings[4] + name
                    label = data[start:data.index(b'\0', start)].decode()
                    if label:
                        self.symbols[label] = value


class Evaluation:
    def __init__(self, image, devices, ram, reads=None, limit=2_000_000):
        self.memory = {}
        self.regions = []
        for address, content, size in image.segments:
            self.regions.append((address, max(size, len(content))))
            for i, byte in enumerate(content):
                self.memory[address + i] = byte
        self.regions.append(ram)
        self.devices = devices
        self.reads = reads or (lambda address, width: 0)
        self.limit = limit
        self.accesses = []
        self.pc = 0
        self.r = [0] * 16
        self.n = self.z = self.c = self.v = False
        vectors = image.symbols.get('_landin_firmware_vectors', 0)
        self.r[13] = self.load(vectors, 4)
        self.r[15] = self.load(vectors + 4, 4) & ~1

    # Memory -----------------------------------------------------------
    def device(self, address):
        return any(base <= address < base + size for base, size in self.devices)

    def inside(self, address, width):
        return any(base <= address and address + width <= base + size
                   for base, size in self.regions)

    def load(self, address, width, record=True):
        if address % width:
            raise Refused('misaligned %d-byte load at %#x' % (width, address))
        if self.device(address):
            value = self.reads(address, width) & ((1 << 8 * width) - 1)
            if record:
                self.accesses.append(('r', address, width, value))
            return value
        if not self.inside(address, width):
            raise Refused('a %d-byte load at %#x, outside the image, its RAM'
                          ' and the devices, from %#x' % (width, address, self.pc))
        return int.from_bytes(bytes(self.memory.get(address + i, 0)
                                    for i in range(width)), 'little')

    def store(self, address, width, value):
        value &= (1 << 8 * width) - 1
        if address % width:
            raise Refused('misaligned %d-byte store at %#x' % (width, address))
        if self.device(address):
            self.accesses.append(('w', address, width, value))
            return
        if not self.inside(address, width):
            raise Refused('a %d-byte store at %#x, outside the image, its RAM'
                          ' and the devices, from %#x' % (width, address, self.pc))
        for i in range(width):
            self.memory[address + i] = value >> 8 * i & 0xff

    # Arithmetic -------------------------------------------------------
    def add(self, a, b, carry, flags):
        unsigned = a + b + carry
        result = unsigned & 0xffffffff
        if flags:
            signed = to_signed(a) + to_signed(b) + carry
            self.n, self.z = bool(result >> 31), result == 0
            self.c, self.v = unsigned > 0xffffffff, to_signed(result) != signed
        return result

    def logic(self, result, carry=None):
        result &= 0xffffffff
        self.n, self.z = bool(result >> 31), result == 0
        if carry is not None:
            self.c = carry
        return result

    def condition(self, code):
        n, z, c, v = self.n, self.z, self.c, self.v
        return [z, not z, c, not c, n, not n, v, not v, c and not z,
                not c or z, n == v, n != v, not z and n == v, z or n != v,
                True][code]

    def shift(self, kind, value, amount, carry):
        if amount == 0:
            return value, carry
        if kind == 0:
            result = (value << amount) & 0xffffffff if amount < 32 else 0
            out = bool(value >> (32 - amount) & 1) if amount <= 32 else False
        elif kind == 1:
            result = value >> amount if amount < 32 else 0
            out = bool(value >> (amount - 1) & 1) if amount <= 32 else False
        elif kind == 2:
            signed = to_signed(value)
            result = (signed >> min(amount, 31)) & 0xffffffff
            out = bool(signed >> (min(amount, 32) - 1) & 1)
        else:
            amount %= 32
            result = ((value >> amount) | (value << (32 - amount))) & 0xffffffff
            out = bool(result >> 31)
        return result, out

    # Execution --------------------------------------------------------
    def run(self):
        for _ in range(self.limit):
            if self.step():
                return self.accesses
        raise Refused('no WFI within %d steps' % self.limit)

    def step(self):
        r = self.r
        self.pc = pc = r[15]
        h = self.load(pc, 2, record=False)
        r[15] = pc + 2
        read = lambda n: (pc + 4 if n == 15 else r[n])  # noqa: E731
        top = h >> 11
        if h >> 13 == 0 and top != 3:
            kind, amount = h >> 11 & 3, h >> 6 & 31
            if kind and amount == 0:
                amount = 32
            r[h & 7], carry = self.shift(kind, r[h >> 3 & 7], amount, self.c)
            self.logic(r[h & 7], carry)
        elif top == 3:
            operand = h >> 6 & 7 if h >> 10 & 1 else r[h >> 6 & 7]
            a = r[h >> 3 & 7]
            r[h & 7] = (self.add(a, ~operand & 0xffffffff, 1, True) if h >> 9 & 1
                        else self.add(a, operand, 0, True))
        elif h >> 13 == 1:
            op, d, imm = h >> 11 & 3, h >> 8 & 7, h & 0xff
            if op == 0:
                r[d] = self.logic(imm)
            elif op == 1:
                self.add(r[d], ~imm & 0xffffffff, 1, True)
            elif op == 2:
                r[d] = self.add(r[d], imm, 0, True)
            else:
                r[d] = self.add(r[d], ~imm & 0xffffffff, 1, True)
        elif h >> 10 == 0x10:
            self.data_processing(h >> 6 & 15, h >> 3 & 7, h & 7)
        elif h >> 10 == 0x11:
            op, d, m = h >> 8 & 3, (h >> 4 & 8) | (h & 7), h >> 3 & 15
            if op == 0:
                result = (read(d) + read(m)) & 0xffffffff
                self.write_register(d, result)
            elif op == 1:
                self.add(read(d), ~read(m) & 0xffffffff, 1, True)
            elif op == 2:
                self.write_register(d, read(m))
            else:
                target = read(m)
                if h >> 7 & 1:
                    r[14] = (pc + 2) | 1
                r[15] = target & ~1
        elif top == 9:
            r[h >> 8 & 7] = self.load(((pc + 4) & ~3) + (h & 0xff) * 4, 4)
        elif h >> 12 == 5:
            op, m, n, t = h >> 9 & 7, h >> 6 & 7, h >> 3 & 7, h & 7
            address = (r[n] + r[m]) & 0xffffffff
            if op == 0:
                self.store(address, 4, r[t])
            elif op == 1:
                self.store(address, 2, r[t])
            elif op == 2:
                self.store(address, 1, r[t])
            elif op == 3:
                r[t] = sign(self.load(address, 1), 8)
            elif op == 4:
                r[t] = self.load(address, 4)
            elif op == 5:
                r[t] = self.load(address, 2)
            elif op == 6:
                r[t] = self.load(address, 1)
            else:
                r[t] = sign(self.load(address, 2), 16)
        elif h >> 13 == 3:
            byte, loading = h >> 12 & 1, h >> 11 & 1
            width = 1 if byte else 4
            address = (r[h >> 3 & 7] + (h >> 6 & 31) * width) & 0xffffffff
            if loading:
                r[h & 7] = self.load(address, width)
            else:
                self.store(address, width, r[h & 7])
        elif h >> 12 == 8:
            address = (r[h >> 3 & 7] + (h >> 6 & 31) * 2) & 0xffffffff
            if h >> 11 & 1:
                r[h & 7] = self.load(address, 2)
            else:
                self.store(address, 2, r[h & 7])
        elif h >> 12 == 9:
            address = (r[13] + (h & 0xff) * 4) & 0xffffffff
            if h >> 11 & 1:
                r[h >> 8 & 7] = self.load(address, 4)
            else:
                self.store(address, 4, r[h >> 8 & 7])
        elif h >> 12 == 10:
            base = r[13] if h >> 11 & 1 else (pc + 4) & ~3
            r[h >> 8 & 7] = (base + (h & 0xff) * 4) & 0xffffffff
        elif h >> 12 == 11:
            return self.miscellaneous(h, pc)
        elif h >> 12 == 12:
            n, registers = h >> 8 & 7, h & 0xff
            address = r[n]
            for i in range(8):
                if registers >> i & 1:
                    if h >> 11 & 1:
                        r[i] = self.load(address, 4)
                    else:
                        self.store(address, 4, r[i])
                    address += 4
            if not (h >> 11 & 1 and registers >> n & 1):
                r[n] = address & 0xffffffff
        elif h >> 12 == 13:
            cond = h >> 8 & 15
            if cond >= 14:
                raise Refused('%s at %#x' % ('UDF' if cond == 14 else 'SVC', pc))
            if self.condition(cond):
                r[15] = (pc + 4 + sign(h & 0xff, 8) * 2) & 0xffffffff
        elif top == 0x1c:
            r[15] = (pc + 4 + sign(h & 0x7ff, 11) * 2) & 0xffffffff
        elif top in (0x1d, 0x1e, 0x1f):
            self.wide(h, self.load(pc + 2, 2, record=False), pc)
        else:
            raise Refused('the instruction %#06x at %#x' % (h, pc))
        return False

    def write_register(self, d, value):
        if d == 15:
            self.r[15] = value & ~1
        else:
            self.r[d] = value & 0xffffffff

    def data_processing(self, op, m, d):
        r = self.r
        a, b = r[d], r[m]
        if op == 0:
            r[d] = self.logic(a & b)
        elif op == 1:
            r[d] = self.logic(a ^ b)
        elif op in (2, 3, 4, 7):
            kind = {2: 0, 3: 1, 4: 2, 7: 3}[op]
            result, carry = self.shift(kind, a, b & 0xff, self.c)
            r[d] = self.logic(result, carry)
        elif op == 5:
            r[d] = self.add(a, b, int(self.c), True)
        elif op == 6:
            r[d] = self.add(a, ~b & 0xffffffff, int(self.c), True)
        elif op == 8:
            self.logic(a & b)
        elif op == 9:
            r[d] = self.add(~b & 0xffffffff, 0, 1, True)
        elif op == 10:
            self.add(a, ~b & 0xffffffff, 1, True)
        elif op == 11:
            self.add(a, b, 0, True)
        elif op == 12:
            r[d] = self.logic(a | b)
        elif op == 13:
            r[d] = self.logic(a * b)
        elif op == 14:
            r[d] = self.logic(a & ~b)
        else:
            r[d] = self.logic(~b)

    def miscellaneous(self, h, pc):
        r = self.r
        if h >> 8 == 0xb0:
            delta = (h & 0x7f) * 4
            r[13] = (r[13] - delta if h >> 7 & 1 else r[13] + delta) & 0xffffffff
        elif h >> 8 == 0xb2:
            value = r[h >> 3 & 7]
            op = h >> 6 & 3
            r[h & 7] = [sign(value & 0xffff, 16), sign(value & 0xff, 8),
                        value & 0xffff, value & 0xff][op]
        elif h >> 9 == 0x5a:
            registers = [i for i in range(8) if h >> i & 1] + ([14] if h >> 8 & 1 else [])
            address = r[13] - 4 * len(registers)
            r[13] = address
            for i in registers:
                self.store(address, 4, r[i])
                address += 4
        elif h >> 9 == 0x5e:
            registers = [i for i in range(8) if h >> i & 1] + ([15] if h >> 8 & 1 else [])
            address = r[13]
            for i in registers:
                value = self.load(address, 4)
                address += 4
                if i == 15:
                    r[15] = value & ~1
                else:
                    r[i] = value
            r[13] = address
        elif h & 0xffef == 0xb662:
            pass  # CPSIE/CPSID i: no interrupt is modelled.
        elif h >> 8 == 0xba:
            value, op = r[h >> 3 & 7], h >> 6 & 3
            swapped = int.from_bytes(value.to_bytes(4, 'little'), 'big')
            if op == 0:
                r[h & 7] = swapped
            elif op == 1:
                r[h & 7] = ((value & 0x00ff00ff) << 8 | (value >> 8) & 0x00ff00ff) & 0xffffffff
            elif op == 3:
                r[h & 7] = sign(((value & 0xff) << 8) | (value >> 8 & 0xff), 16)
            else:
                raise Refused('the instruction %#06x at %#x' % (h, pc))
        elif h >> 8 == 0xbe:
            raise Refused('BKPT at %#x' % pc)
        elif h == 0xbf30:
            return True
        elif h >> 8 == 0xbf and h & 0xff in (0x00, 0x10, 0x20, 0x40):
            pass  # NOP, YIELD, WFE, SEV.
        else:
            raise Refused('the instruction %#06x at %#x' % (h, pc))
        return False

    def wide(self, first, second, pc):
        r = self.r
        r[15] = pc + 4
        if first >> 11 == 0x1e and second >> 14 == 3 and second >> 12 & 1:
            s = first >> 10 & 1
            j1, j2 = second >> 13 & 1, second >> 11 & 1
            i1, i2 = 1 - (j1 ^ s), 1 - (j2 ^ s)
            offset = (s << 24 | i1 << 23 | i2 << 22 | (first & 0x3ff) << 12
                      | (second & 0x7ff) << 1)
            r[14] = (pc + 4) | 1
            r[15] = (pc + 4 + sign(offset, 25)) & 0xffffffff
        elif first == 0xf3ef and second >> 12 == 8:
            r[second >> 8 & 15] = 0  # MRS: PRIMASK and CONTROL read as reset.
        elif first & 0xfff0 == 0xf380 and second >> 8 == 0x88:
            pass  # MSR: no special register is modelled.
        elif first == 0xf3bf and second & 0xfff0 in (0x8f40, 0x8f50, 0x8f60):
            self.accesses.append(('barrier', {0x8f40: 'dsb', 0x8f50: 'dmb',
                                              0x8f60: 'isb'}[second & 0xfff0]))
        else:
            raise Refused('the instruction %#06x %#06x at %#x' % (first, second, pc))


def to_signed(value):
    value &= 0xffffffff
    return value - (1 << 32) if value >> 31 else value


def sign(value, bits):
    return value - (1 << bits) if value >> (bits - 1) & 1 else value


def accesses(data, devices, ram, reads=None, limit=2_000_000):
    """Every device access the ELF image DATA makes until its first WFI."""
    return Evaluation(Image(data), devices, ram, reads, limit).run()
