# Landin prototype 1 — a driver from a vendor SVD

Current with specification 0.2.1. Its own findings X1-X9 are all
resolved below. The bootstrap compiler exists, but this Cortex-M program uses
future constructs and deliberate omissions, so it remains a specification
test: every line is meant to follow a rule that is written down, and every
place where the tour was silent is recorded at the end, under WHERE THE
SPECIFICATION WAS SILENT.

The target is a Cortex-M0 class part. GPIO, a timer, and a UART that
receives by DMA and signals completion from an interrupt handler.

[1975]'s hosted C boundary selects Linux SysV AMD64 LP64, not this hardware
ABI. Its `layout(c)` subset does not enable the register, packed-field or
vector-table forms below; SVD generation remains distinct from C header adapters. Interrupt,
naked, ordinary Landin and C function conventions are not interchangeable merely
because a vector entry or field holds a code address. The Cortex-M0 target
instantiates the ordinary 32-bit layout and ABI with independent C/assembly
controls. Language interrupt/startup entry rules are the compiler-owned
firmware rules [1990] (D229); no vector table is enabled by the ordinary
function-address representation.

D210's explicit optimal layout likewise never reorders a register image or a
vector table. Natural/C layouts keep their existing rules, and packed storage
remains separate work. D211's build evidence stays off target: neither a
profiler nor allocation/report metadata becomes mandatory runtime storage on
this 32 KB device. A synthetic-32 layout test is not Cortex-M execution proof.

---

D228 distinguishes each packed register image from the validated atom values
extracted from it. A copied hardware image may contain unnamed encodings;
reading an encoded field checks membership. Configuration updates preserve
unselected image bits, while a one-clears command starts from a zero image.
D228's fixtures carry the source, compiler and bounded peripheral evidence.
The checked-in [device fixtures](devices/README.md) derive a bounded real
RP2040 surface into explicit D228 images, encoded unions and D227/D228 scalar
accesses. The conceptual map below is not an RP2040 description: pin count,
DMA stream/count geometry and addresses differ. Separate modules preserve
GPIO control/SIO commands, timer alarms, UART FIFO/flags and DMA channel images;
explicit synthetic bases adapt only the execution lane. D238 withdraws the
`volatile ptr` type, the `register(t, ...)` wrapper and automatic `set(X)`:
a device access is D227's or D228's explicit operation over an ordinary
pointer, and a generator writes the per-register functions and named bool
fields. The sketch below keeps those spellings as its design record, and the
derivation maps each one to that form. The historical findings below remain
historical. The complete derived driver owns its full derivation mapping,
consumption and overrun protocol. Prototype 3's caller-backed storage,
explicit allocator capabilities and local origin obligations remain unchanged;
these fixtures acquire no allocator. The ordinary-slice DMA and D227 barrier
contract are unchanged.

The complete executable derivation is indexed in
[`compiler/tests/driver/DERIVATION.md`](compiler/tests/driver/DERIVATION.md).
It maps every module, omission and X1-X9 finding to source, execution or an
explicit device adaptation. That derivation is the executable evidence; this
sketch and its historical syntax remain unchanged.

## chip/vendor/gpio  —  generated from the SVD

How a pin is driven. The encoding is the datasheet's, not ours.
```landin
public input:     atom
public output:    atom
public alternate: atom
public analog:    atom

public pin_mode: type = (input = 0 | output = 1
                         | alternate = 2 | analog = 3)

public push_pull:  atom
public open_drain: atom

public out_type: type = (push_pull = 0 | open_drain = 1)
```
One bit, because that is the smallest width that holds the
largest encoding. No base type is written.

```landin
public low:    atom
public medium: atom
public high:   atom
public very_high: atom

public out_speed: type = (low = 0 | medium = 1
                          | high = 2 | very_high = 3)

```
Sixteen pins per port, two bits each, filling the register.
```landin
public moder: type = layout(packed) struct
    pins: [16]pin_mode at 0..31
end moder
```
An array as a packed field: sixteen elements of two bits
fill the range exactly, and element zero takes the low bits.

```landin
public otyper: type = layout(packed) struct
    pins: [16]out_type at 0..15
end otyper

public ospeedr: type = layout(packed) struct
    pins: [16]out_speed at 0..31
end ospeedr

```
Alternate function selection: sixteen pins, four bits each,
split across two registers by the hardware.
```landin
public afr_low: type = layout(packed) struct
    pins: [8]u4 at 0..31
end afr_low

public afr_high: type = layout(packed) struct
    pins: [8]u4 at 0..31
end afr_high

```
The output data register is sixteen independent bits addressed by
number, which is an array of bool and not a set of atoms. A set
earns its place when the members mean something; a numbered bank
of lines means nothing beyond its number.
```landin
public odr: type = layout(packed) struct
    pins: [16]bool at 0..15
end odr

```
The peripheral itself: one struct of registers, laid out at the
offsets the SVD gives, which is what layout(c) with explicit
field order buys us.
```landin
public port: type = layout(c) struct
    mode:      register(moder,   read: normal, write: normal,
                                 reset: 0x0000_0000)
    otype:     register(otyper,  read: normal, write: normal,
                                 reset: 0x0000_0000)
    ospeed:    register(ospeedr, read: normal, write: normal,
                                 reset: 0x0000_0000)
    pupd:      register(u32,     read: normal, write: normal,
                                 reset: 0x0000_0000)
    input_dat: register(u16,     read: normal, write: none,
                                 reset: 0x0000_0000)
    pad0:      u16
    output_dat:register(odr,     read: normal, write: normal,
                                 reset: 0x0000_0000)
    pad1:      u16
    set_reset: register(u32,     read: none,   write: normal,
                                 reset: 0x0000_0000)
    lock:      register(u32,     read: normal, write: normal,
                                 reset: 0x0000_0000)
    af_low:    register(afr_low,  read: normal, write: normal,
                                 reset: 0x0000_0000)
    af_high:   register(afr_high, read: normal, write: normal,
                                 reset: 0x0000_0000)
end port

public gpioa: volatile ptr mut port = ptr(0x4002_0000)
public gpiob: volatile ptr mut port = ptr(0x4002_0400)

```

## chip/vendor/dma  —  generated from the SVD

```landin
public transfer_complete: atom
public half_transfer:     atom
public transfer_error:    atom

```
A union used as a set carries its encodings, because for a set
the encoding is the bit number. Without them the bit assignment
would hang on declaration order.
```landin
public dma_event: type = (transfer_complete = 0
                          | half_transfer    = 1
                          | transfer_error   = 2)

public peripheral_to_memory: atom
public memory_to_peripheral: atom

public direction: type = (peripheral_to_memory = 0
                          | memory_to_peripheral = 1)

public stream_config: type = layout(packed) struct
    enable:     bool           at 0
    dir:        direction      at 6..7
    circular:   bool           at 8
    mem_inc:    bool           at 10
    interrupts: set(dma_event) at 1..3
end stream_config
```
Bits 4, 5, 9 and everything from 11 upward are claimed by
nobody, so they are reserved by that fact: they cannot be
named, they survive a read-modify-write untouched, and they
do not appear in completion.

```landin
public stream: type = layout(c) struct
    config:    register(stream_config, read: normal, write: normal,
                                       reset: 0x0000_0000)
    count:     register(u16, read: normal, write: normal,
                             reset: 0x0000_0000)
    pad0:      u16
    periph_ad: register(u32, read: normal, write: normal,
                             reset: 0x0000_0000)
    mem_ad:    register(u32, read: normal, write: normal,
                             reset: 0x0000_0000)
end stream

public controller: type = layout(c) struct
    status:  register(u32, read: normal, write: none,
                           reset: 0x0000_0000)
    clear:   register(u32, read: none,   write: one_clears,
                           reset: 0x0000_0000)
    streams: [8]stream
end controller

public dma1: volatile ptr mut controller = ptr(0x4002_6000)

```

## drivers/uart  —  written by hand, against the generated modules

```landin
import chip/vendor/gpio
import chip/vendor/dma
import chip/vendor/usart
import core/sets

public busy:          atom
public bad_baud:      atom
public buffer_too_big: atom

```
A receive buffer that DMA writes into. Because the hardware keeps
writing after the call that started it returns, handing it over is
an escaping use, and the origin rule then does the work for us.
```landin
public rx: type = struct
    port:   volatile ptr mut usart.device
    stream: volatile ptr mut dma.stream
    buf:    []u8
    head:   usize
end rx

```
Baud is a range subtype, so a nonsense value is a compile error
when it is known and a trap when it is not.
```landin
public baud_rate: type = u32 range 1_200..12_000_000

```

---

Pin setup. Every write is a whole register: read it, change the
local copy, write it back. Writing a single field through a
volatile pointer is forbidden, and this is what that forces.

---

```landin
configure_pin: (p: volatile ptr mut gpio.port, n: usize,
                mode: gpio.pin_mode, af: u4) -> none =
    mut m := p.val.mode
    m.pins[n] = mode
    p.val.mode = m

    mut s := p.val.ospeed
    s.pins[n] = gpio.very_high
    p.val.ospeed = s

    if n < 8 then
        mut a := p.val.af_low
        a.pins[n] = af
        p.val.af_low = a
    else
        mut a := p.val.af_high
        a.pins[n - 8] = af
        p.val.af_high = a
    end if
end configure_pin

```

---

Bringing the receiver up. The buffer is a parameter, marked
escaping because the stream keeps writing into it long after this
function has returned.

---

```landin
public buffer_empty: atom

public open: (port: volatile ptr mut usart.device,
              stream: volatile ptr mut dma.stream,
              pins: volatile ptr mut gpio.port,
              tx_pin: usize, rx_pin: usize,
              rate: baud_rate,
              escaping buf: []mut u8)
             -> (r: rx) ! bad_baud | buffer_too_big | buffer_empty =

    fail buffer_empty   when lenof buf == 0
    fail buffer_too_big when lenof buf > 65_535

    configure_pin(pins, tx_pin, gpio.alternate, 7)
    configure_pin(pins, rx_pin, gpio.alternate, 7)

    divisor := try usart.divisor_for(rate)
    port.val.brr = divisor

```
An explicit configuration image read, local field updates, then one write.
The old image supplies reserved bits. A fresh constructor cannot preserve bits
it never read, and the final write must not synthesize a hidden read. This
sequence is valid only for this normal-read/normal-write register and is not
atomic against interrupt or hardware updates. A one-clears command must not
be built by reading and writing back pending status.
```landin
    mut cfg := stream.val.config
    cfg.enable = false
    cfg.dir = dma.peripheral_to_memory
    cfg.circular = true
    cfg.mem_inc = true
    cfg.interrupts = (transfer_complete: true, transfer_error: true,
                      of false)

    stream.val.periph_ad = u32(addr port.val.dr)
    stream.val.mem_ad    = u32(addr buf[0])
    stream.val.count     = u16(lenof buf)
    stream.val.config    = cfg

    compiler.device_barrier()
    cfg.enable = true
    stream.val.config = cfg

    r = rx(port: port, stream: stream, buf: buf, head: 0)
end open

```

---

Reading what the hardware has delivered. The DMA counter runs
down, so the write position is the far end minus what is left.
D227 requires the device to publish each byte before its count observation.
The following barrier invalidates compiler knowledge of the ordinary slice;
on a cached noncoherent target a platform cache protocol is required too.
This sketch assumes the consumed interval is not overwritten during the copy
and that a full wrap cannot go undetected. Interrupt masking cannot establish
those conditions. The complete derived driver owns their executable controls.

---

```landin
public available: (in r: rx) -> (n: usize) =
    remaining := usize(r.stream.val.count)
    compiler.device_barrier()
    tail := lenof r.buf - remaining
    if tail >= r.head then
        n = tail - r.head
    else
        n = lenof r.buf - r.head + tail
    end if
end available

public read: (inout r: rx, out_buf: []mut u8) -> (n: usize) =
    have := available(r)
    n = have
    if lenof out_buf < have then
        n = lenof out_buf
    end if

    for i in 0..<n do
        out_buf[i] = r.buf[(r.head + i) % lenof r.buf]
    end for

    r.head = (r.head + n) % lenof r.buf
end read

```

---

The interrupt handler. It follows the C ABI through the interrupt
convention, it has an empty error set because there is nobody to
fail to, and it is placed in the vector table by address.

---

```landin
mut rx_events: u32 = 0

public extern(interrupt) dma1_stream5_handler: () -> none =
    pending := dma.dma1.val.status
    if pending & 0x20 <> 0 then
        dma.dma1.val.clear = 0x20
        inc rx_events
    end if
end dma1_stream5_handler

```

---

A critical section, because the handler and the main loop share
rx_events. On this part there is no load-exclusive instruction, so
the only way is to mask interrupts; defer puts them back on every
path out of the block.

---

```landin
public take_events: () -> (n: u32) =
    begin
        prev := cpu.disable_interrupts()
        defer cpu.restore_interrupts(prev)

        n = rx_events
        rx_events = 0
    end
end take_events

```

## app  —  freestanding, no main

```landin
import core/cpu
import drivers/uart
import chip/vendor/gpio
import chip/vendor/dma
import chip/vendor/usart

```
Static storage, so the buffer outlives every frame and may be
handed to hardware.
```landin
mut rx_storage: [256]u8 = zeroed

start: () -> noreturn =
    mut console := uart.open(
        usart.usart2, addr dma.dma1.val.streams[5], gpio.gpioa,
        2, 3, 115_200, rx_storage[0..<lenof rx_storage]
    ) else (e)
        match e
            uart.bad_baud:       halt()
            uart.buffer_too_big: halt()
            uart.buffer_empty:   halt()
        end match
    end

    mut scratch: [64]u8 = zeroed

    loop do
        events := uart.take_events()
        if events > 0 then
            n := uart.read(console, scratch[0..<lenof scratch])
            _ = handle(scratch[0..<n])
        end if
        cpu.wait_for_interrupt()
    end loop
end start

```
D231 makes the `noreturn` entry and nonreturning failure recovery concrete.
`core-noreturn.ldn` exercises those edges through compiler-owned startup, and
`abi/r670-noreturn` checks the same generic/evidence and cleanup contracts on
both hosted targets. The return form does not relax escaping-buffer origins
or establish DMA completion. These are bounded derivative tests, not the
complete driver. D232 adds the canonical `core/panic` hook: bounded
`core-panic.ldn` derivatives exercise its ordinary two-scalar calls at failed
checks, inside a real interrupt and after entry return. The default requires
no reporting storage. These changes do not alter the ordinary-slice DMA
completion protocol or add an allocator to a collection; prototype 3's explicit
capability and failure contracts continue to apply.

What the escape rule rejects, and the reason the prototype was
worth writing:

```landin
bad_start: () -> noreturn =
    mut local: [256]u8 = zeroed
    c := uart.open(..., local[0..<256])   -- error
    ...
end bad_start
```

open takes its buffer as escaping, so the argument must outlive
the call. local has frame origin. The compiler refuses, and the
bug it refuses is the one that would have shown up as corrupted
memory hours later, on a device with no debugger attached.

The complete physical device binding remains a separate driver concern. The
bounded Cortex-M0 derivative uses the compiler-owned vector image described by
[1640] and [1990]: SP and reset are compiler entries, reserved slots are zero,
and source contributes a typed handler reference. For that synthetic lane,
IRQ0 is vector slot 16. It is not the STM32 DMA1 stream 5 interrupt number.

```landin
-- Applied to the handler declaration in the bounded synthetic derivative:
link(vector: 16)
extern(interrupt) synthetic_handler: () -> none =
    assembler.block("nop")
end synthetic_handler
```

The real handler body above still has an empty error set. A handler is an
`extern(interrupt) () -> none` value, and a naked entry has its own distinct
function convention; neither can be converted to or called as an ordinary
`() -> none` function. Shared handler work therefore belongs in an ordinary
helper called from the interrupt body, not in an ordinary call to another
handler. A kept image retains the handlers its relocations name;
`extern(interrupt)` alone does not imply keep. The selected source annotation
is such a reference in the compiler-owned kept image, not a new retention
property of the function type.

The older heterogeneous stack/reset/handler table pressure is retained by the
compiler's image and relocation tests rather than an ordinary array of
addresses. Data and code addresses remain distinct, and the reset loader does
not run user module initializers. The complete device-specific driver and its
generated register modules retain their roadmap gates.

---

## WHERE THE SPECIFICATION WAS SILENT

The resolutions below cite the pre-release revisions this
specification passed through, 0.0.1 to 0.0.17, on the way to 0.1.0.
They are kept because when one thing was settled relative to another
still carries information.

---

X1  RESOLVED in the tour. An encoded union leaves out its base type
and takes the smallest width that holds its largest encoding, so
a two-value union is one bit and u1 is not missed.

X2  RESOLVED in the tour. An array may be a packed field: element
width times count must equal the range, element zero takes the
low bits.

X3  RESOLVED in the tour. A function type is an ordinary type and a
function an ordinary value of it, so no function-pointer type is
needed and addr is not used on functions. A callback is a pair
of a function value and a state pointer, written out.

X4  RESOLVED at 0.0.12, by removing rather than deciding. A set is
not a kind of its own: set(X) generates a packed struct of bool,
one field per member, each at the bit its encoding names. So
membership is a field read, adding and removing a member is a
field write, and building one is the ordinary struct literal
with 'of' filling what was not named. No set literal, no set
operators, no membership operator — and the braces used here
were an intruder, since the language has none anywhere else.
What made it work is a partial struct literal, which the whole
language gains from and which had been missing since [0980]
refused default values.

X5  RESOLVED at 0.0.12, as assumed. A field of register(T, ...) type
reads as a T and is assigned a T, and the access behaviour is
checked there. Written down with it: reset initialises nothing,
it records what the hardware leaves behind.

X6  RESOLVED at 0.0.12. addr on a volatile field yields the address
and nothing more, because volatility is a property of the access
path rather than of the number. Both directions between pointer
and integer are the ordinary conversion with no special word,
and the tour now says what the round trip costs: an integer that
used to be a pointer has no origin left. The half about
functions had already gone with X3.

X7  RESOLVED at 0.0.12, said in the tour: ordinary code, a shift by
a computed amount inside a register image, with the same bounds
check any index gets — and on an image only, never straight
through the volatile pointer.

X8  RESOLVED at 0.0.12 with a rule rather than a list: something is
builtin when the compiler has to know it. Atomics are, because
opaque assembly in a hot loop wrecks the allocation around it.
Masking interrupts is not — being opaque is exactly what a
critical section wants. So cpu is an ordinary core module per
target, written with assembler.block behind a fixed if, and the
calls in this file stand as they are. If an intrinsic later
turns out to be uniform across targets, the rule promotes it.

X9  RESOLVED at 0.0.12: reachability from something kept is what
keeps a handler, and the table carries keep and names them.
extern(interrupt) does not imply it, because a calling
convention is what the program means and keep is an instruction
to the toolchain — two things [0760] separated on purpose.

---

The Cortex-M [execution profile](environments/cortex-m/README.md) retains the
M0 CPU pressure in QEMU and supplies a separately named synthetic Renode
peripheral lane for this sketch's register/DMA behavior. It does not identify
this combined map as a real vendor part or turn these sketches into an
implemented Landin program.
