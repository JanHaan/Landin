"""The device accesses a run of RV32 code makes, found by evaluating its
instructions.

It is `thumb.py`'s reading for the RISC-V devices: an ESP description's
watchdog stage (D684) runs from the image's entry word to reset with no
RAM and no stack, so the code's instructions, over memory that is nothing
but the image's own bytes, determine every load and store it makes outside
that memory.  This evaluates RV32I, M and the integer encodings of C, and
records, in order, each access to a window the caller names as a device,
with its address, its width and the value stored.  A load from a device
window returns zero, or what the caller's `reads` answers.  It stops when
`until` holds of the program counter, and refuses an instruction it does
not know (a CSR access, an atomic, a float, a system call or the all-zero
word), an access outside the image's memory and the device windows, a
misaligned access or branch target, or more steps than its limit.

It models no peripheral, no trap, no interrupt and no clock: it is a
reading of the linked image, not a run of a chip, and an image whose
accesses depend on a device's behaviour is outside it.
"""
from thumb import Image, Refused  # noqa: F401  (an ELF32's loadable bytes)

MASK = 0xffffffff


def signed(value, bits=32):
    """VALUE's low BITS as a two's-complement integer."""
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def bits(word, high, low):
    return word >> low & ((1 << high - low + 1) - 1)


class Evaluation:
    def __init__(self, image, devices, ram, reads=None, limit=100_000, start=None,
                 until=None):
        self.memory = {}
        self.regions = []
        for address, content, size in image.segments:
            self.regions.append((address, max(size, len(content))))
            for i, byte in enumerate(content):
                self.memory[address + i] = byte
        if ram[1]:
            self.regions.append(ram)
        self.devices = devices
        self.reads = reads or (lambda address, width: 0)
        self.limit = limit
        self.until = until
        self.accesses = []
        self.x = [0] * 32
        start = start or {}
        self.pc = start.get('pc', image.entry)
        self.x[2] = start.get('sp', 0)
        self.x[1] = start.get('ra', 0)

    # Memory -----------------------------------------------------------
    def device(self, address):
        return any(base <= address < base + size for base, size in self.devices)

    def inside(self, address, width):
        return any(base <= address and address + width <= base + size
                   for base, size in self.regions)

    def load(self, address, width, record=True):
        address &= MASK
        if address % width:
            raise Refused('misaligned %d-byte load at %#x, from %#x' % (width, address, self.pc))
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
        address &= MASK
        value &= (1 << 8 * width) - 1
        if address % width:
            raise Refused('misaligned %d-byte store at %#x, from %#x' % (width, address, self.pc))
        if self.device(address):
            self.accesses.append(('w', address, width, value))
            return
        if not self.inside(address, width):
            raise Refused('a %d-byte store at %#x, outside the image, its RAM'
                          ' and the devices, from %#x' % (width, address, self.pc))
        for i in range(width):
            self.memory[address + i] = value >> 8 * i & 0xff

    def fetch(self, address):
        """The instruction at ADDRESS and its length, never a device's."""
        if address % 2:
            raise Refused('a misaligned instruction at %#x' % address)
        if not self.inside(address, 2):
            raise Refused('execution left the image at %#x' % address)
        low = self.load(address, 2, record=False)
        if low & 3 != 3:
            return low, 2
        if not self.inside(address, 4):
            raise Refused('execution left the image at %#x' % address)
        return low | self.load(address + 2, 2, record=False) << 16, 4

    def write(self, register, value):
        if register:
            self.x[register] = value & MASK

    # Execution --------------------------------------------------------
    def run(self):
        for _ in range(self.limit):
            if self.until is not None and self.until(self.pc):
                return self.accesses
            self.step()
        raise Refused('no end within %d steps, at %#x' % (self.limit, self.pc))

    def step(self):
        word, length = self.fetch(self.pc)
        following = (self.pc + length) & MASK
        target = (self.compressed(word) if length == 2 else self.wide(word))
        if target is None:
            target = following
        if target % 2:
            raise Refused('a jump to the odd address %#x, from %#x' % (target, self.pc))
        self.pc = target & MASK

    def unknown(self, word, length):
        return Refused('an instruction this evaluation does not follow, %0*x at %#x'
                       % (2 * length, word, self.pc))

    def arithmetic(self, function, a, b, alternate):
        """RV32I's register operations by funct3, ALTERNATE its bit 30."""
        if function == 0:
            return a - b if alternate else a + b
        if function == 1:
            return a << (b & 31)
        if function == 2:
            return int(signed(a) < signed(b))
        if function == 3:
            return int(a < b)
        if function == 4:
            return a ^ b
        if function == 5:
            return signed(a) >> (b & 31) if alternate else a >> (b & 31)
        if function == 6:
            return a | b
        return a & b

    def multiply(self, function, a, b):
        """The M extension by funct3, with its results for a zero divisor
        and for the one overflowing quotient."""
        if function == 0:
            return a * b
        if function == 1:
            return signed(a) * signed(b) >> 32
        if function == 2:
            return signed(a) * b >> 32
        if function == 3:
            return a * b >> 32
        if function in (4, 6):
            if b == 0:
                return MASK if function == 4 else a
            if a == 0x80000000 and b == MASK:
                return a if function == 4 else 0
            #  Division rounds towards zero; the remainder has the
            #  dividend's sign.
            quotient = abs(signed(a)) // abs(signed(b))
            if (signed(a) < 0) != (signed(b) < 0):
                quotient = -quotient
            return quotient if function == 4 else signed(a) - quotient * signed(b)
        if b == 0:
            return MASK if function == 5 else a
        return a // b if function == 5 else a % b

    def branch(self, function, a, b):
        taken = {0: a == b, 1: a != b, 4: signed(a) < signed(b), 5: signed(a) >= signed(b),
                 6: a < b, 7: a >= b}
        if function not in taken:
            return None
        return taken[function]

    def wide(self, word):
        """One 32-bit instruction; its jump target, or None to go on."""
        opcode, rd, function = word & 0x7f, bits(word, 11, 7), bits(word, 14, 12)
        rs1, rs2 = bits(word, 19, 15), bits(word, 24, 20)
        a, b = self.x[rs1], self.x[rs2]
        immediate = signed(word >> 20, 12)
        if opcode == 0x37:                                         # lui
            self.write(rd, word & 0xfffff000)
        elif opcode == 0x17:                                       # auipc
            self.write(rd, self.pc + (word & 0xfffff000))
        elif opcode == 0x6f:                                       # jal
            offset = signed(bits(word, 31, 31) << 20 | bits(word, 19, 12) << 12
                            | bits(word, 20, 20) << 11 | bits(word, 30, 21) << 1, 21)
            self.write(rd, self.pc + 4)
            return self.pc + offset
        elif opcode == 0x67 and function == 0:                     # jalr
            target = (a + immediate) & ~1
            self.write(rd, self.pc + 4)
            return target
        elif opcode == 0x63:                                       # branches
            taken = self.branch(function, a, b)
            if taken is None:
                raise self.unknown(word, 4)
            if taken:
                return self.pc + signed(bits(word, 31, 31) << 12 | bits(word, 7, 7) << 11
                                        | bits(word, 30, 25) << 5 | bits(word, 11, 8) << 1, 13)
        elif opcode == 0x03 and function in (0, 1, 2, 4, 5):       # loads
            width = 1 << (function & 3)
            value = self.load(a + immediate, width)
            self.write(rd, value if function & 4 else signed(value, 8 * width))
        elif opcode == 0x23 and function in (0, 1, 2):             # stores
            offset = signed(bits(word, 31, 25) << 5 | bits(word, 11, 7), 12)
            self.store(a + offset, 1 << function, b)
        elif opcode == 0x13:                                       # immediates
            if function in (1, 5):
                #  A shift's immediate is five bits, under funct7.
                if bits(word, 31, 25) not in ((0,) if function == 1 else (0, 0x20)):
                    raise self.unknown(word, 4)
                self.write(rd, self.arithmetic(function, a, rs2, bool(word >> 30 & 1)))
            else:
                self.write(rd, self.arithmetic(function, a, immediate & MASK, False))
        elif opcode == 0x33 and bits(word, 31, 25) in (0, 0x20):   # register operations
            alternate = bool(word >> 30 & 1)
            if alternate and function not in (0, 5):
                raise self.unknown(word, 4)
            self.write(rd, self.arithmetic(function, a, b, alternate))
        elif opcode == 0x33 and bits(word, 31, 25) == 1:           # M
            self.write(rd, self.multiply(function, a, b))
        elif opcode == 0x0f and function == 0:                     # fence: no other hart
            pass
        else:
            raise self.unknown(word, 4)
        return None

    def compressed(self, word):
        """One 16-bit instruction, as the 32-bit one it abbreviates."""
        quadrant, function = word & 3, bits(word, 15, 13)
        full, low = bits(word, 11, 7), bits(word, 6, 2)
        near1, near2 = 8 + bits(word, 9, 7), 8 + bits(word, 4, 2)
        immediate = signed(bits(word, 12, 12) << 5 | low, 6)
        x = self.x
        if word == 0:
            raise self.unknown(word, 2)
        if quadrant == 0:
            if function == 0:                                      # c.addi4spn
                amount = (bits(word, 10, 7) << 6 | bits(word, 12, 11) << 4
                          | bits(word, 5, 5) << 3 | bits(word, 6, 6) << 2)
                if not amount:
                    raise self.unknown(word, 2)
                self.write(near2, x[2] + amount)
                return None
            offset = bits(word, 5, 5) << 6 | bits(word, 12, 10) << 3 | bits(word, 6, 6) << 2
            if function == 2:                                      # c.lw
                self.write(near2, self.load(x[near1] + offset, 4))
                return None
            if function == 6:                                      # c.sw
                self.store(x[near1] + offset, 4, x[near2])
                return None
        elif quadrant == 1:
            if function == 0:                                      # c.addi, c.nop
                self.write(full, x[full] + immediate)
                return None
            if function in (1, 5):                                 # c.jal, c.j
                offset = signed(
                    bits(word, 12, 12) << 11 | bits(word, 8, 8) << 10 | bits(word, 10, 9) << 8
                    | bits(word, 6, 6) << 7 | bits(word, 7, 7) << 6 | bits(word, 2, 2) << 5
                    | bits(word, 11, 11) << 4 | bits(word, 5, 3) << 1, 12)
                if function == 1:
                    self.write(1, self.pc + 2)
                return self.pc + offset
            if function == 2:                                      # c.li
                self.write(full, immediate)
                return None
            if function == 3:
                if full == 2:                                      # c.addi16sp
                    amount = signed(
                        bits(word, 12, 12) << 9 | bits(word, 4, 3) << 7 | bits(word, 5, 5) << 6
                        | bits(word, 2, 2) << 5 | bits(word, 6, 6) << 4, 10)
                    if not amount:
                        raise self.unknown(word, 2)
                    self.write(2, x[2] + amount)
                    return None
                if not immediate:
                    raise self.unknown(word, 2)
                self.write(full, immediate << 12)                  # c.lui
                return None
            if function == 4:
                kind = bits(word, 11, 10)
                if kind < 2:                                       # c.srli, c.srai
                    if word >> 12 & 1:
                        raise self.unknown(word, 2)
                    self.write(near1, self.arithmetic(5, x[near1], low, kind == 1))
                elif kind == 2:                                    # c.andi
                    self.write(near1, x[near1] & immediate & MASK)
                elif word >> 12 & 1:
                    raise self.unknown(word, 2)
                else:                                              # c.sub, c.xor, c.or, c.and
                    operation, alternate = ((0, True), (4, False), (6, False),
                                            (7, False))[bits(word, 6, 5)]
                    self.write(near1, self.arithmetic(operation, x[near1], x[near2], alternate))
                return None
            if function in (6, 7):                                 # c.beqz, c.bnez
                offset = signed(
                    bits(word, 12, 12) << 8 | bits(word, 6, 5) << 6 | bits(word, 2, 2) << 5
                    | bits(word, 11, 10) << 3 | bits(word, 4, 3) << 1, 9)
                if (x[near1] == 0) == (function == 6):
                    return self.pc + offset
                return None
        elif quadrant == 2:
            if function == 0 and not word >> 12 & 1:               # c.slli
                self.write(full, x[full] << low)
                return None
            if function == 2 and full:                             # c.lwsp
                offset = bits(word, 3, 2) << 6 | bits(word, 12, 12) << 5 | bits(word, 6, 4) << 2
                self.write(full, self.load(x[2] + offset, 4))
                return None
            if function == 6:                                      # c.swsp
                offset = bits(word, 8, 7) << 6 | bits(word, 12, 9) << 2
                self.store(x[2] + offset, 4, x[low])
                return None
            if function == 4:
                if not word >> 12 & 1:
                    if low:                                        # c.mv
                        self.write(full, x[low])
                        return None
                    if full:                                       # c.jr
                        return x[full] & ~1
                elif low:                                          # c.add
                    self.write(full, x[full] + x[low])
                    return None
                elif full:                                         # c.jalr
                    target = x[full] & ~1
                    self.write(1, self.pc + 2)
                    return target
        raise self.unknown(word, 2)
