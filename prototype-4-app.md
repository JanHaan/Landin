# Landin prototype 4 — a hosted application

```landin
Current with specification 0.1.0. Its own findings W1-W7 are all
resolved below.

A log filter: read a file, run every line through a chain of filters
picked on the command line, hand what survives to a destination picked
the same way, print a summary. Deliberately ordinary, because the
point is not the program.

What it presses on, none of which the first three prototypes touched:

  any        real heterogeneous dispatch. The chain is built from
             argv, so its shape is unknown until run time and no
             generic can express it
  arenas     one for the program and blocks for scratch, side by side
  Io         which the tour has never specified at all
  the root   where a capability comes from when nobody handed you one
  entry      argc and argv, and what a hosted program is handed
  callbacks  a function and a state pointer, since nothing captures

Where a spelling had to be invented, the line is marked [Wn] and the
question is written out at the end.
```

---

## core/mem  —  one addition to what prototype 3 sketched

A single object rather than a slice. No from clause: what comes
back is independent of the allocator, which is why two live
allocations from one allocator are unremarkable [0790].
```landin
public new: (T: type, A: type is allocator, inout a: A)
            -> (p: ptr mut T) ! out_of_memory = ... end

```

## core/io  —  the host capability

```landin
public not_found: atom
public no_access: atom
public io_failed: atom
public at_end:    atom

public none_open: atom

```
A descriptor, distinct so it cannot become arithmetic by accident.
```landin
public file: type = distinct i32

```
Everything that can block or touch the world goes through this, so
a function that was not given one can do neither.

A concept and not a type, which is the whole point: the program
below never learns which one it got. A first draft of this file
had it as a struct, and the capability story was worthless,
because nothing else could be put in its place.

close takes the handle by sink, so using that place afterwards is
refused rather than merely wrong. Say exactly what that is worth,
though: the handle is a copyable value, so a copy taken before
the close is not refused anything, and closing through both is
the double-close this does not prevent. It is a use-after-consume
check on one place, not ownership. Affine values would be the
other thing, and they are parked with a condition in BACKLOG.md. And
inout
on the read buffer means, since 0.0.10, hand me a writable view;
nothing is written back to the slice value and there would be
nothing to write it back to.
```landin
public world: type = concept (H: type)
    open_read:  (inout h: H, path: utf8) -> (f: file) ! not_found | no_access
    open_write: (inout h: H, path: utf8) -> (f: file) ! no_access
    close:      (inout h: H, sink f: file) -> none
    read:       (inout h: H, f: file, into: []mut u8) -> (n: usize) ! io_failed
    write:      (inout h: H, f: file, bytes: []u8) -> none ! io_failed
    out:        (h: H) -> (f: file)
    err:        (h: H) -> (f: file)
end world

```
The real one.
```landin
public system: type = struct
    reserved: u32
end system

system is world (open_read: sys_open_read, open_write: sys_open_write,
                 close: sys_close, read: sys_read, write: sys_write,
                 out: sys_out, err: sys_err)

```
And here is the one place a capability appears from nowhere. Every
other one in this program is passed in; this one is minted,
because the entry point is where the program meets the machine.
```landin
public host: () -> (h: system) = ... end

```
A second root, for tests, built out of ordinary data rather than
minted. This is what makes the concept worth having.
```landin
public memory: type = struct ... end
memory is world (...)

public in_memory: (files: [](name: utf8, body: utf8)) -> (h: memory) = ... end
public written:   (h: memory) -> (text: utf8 from h) = ... end

```
The arguments as a slice. A hosted main is handed argc and argv in
the C shape by [1650], and turning those into something indexable
needs slice_from, which is core-only by [0500], so core hands the
program a slice instead.
```landin
public args: () -> (a: []cstring) = ... end

```

## app/read  —  a buffered line reader

```landin
import core/mem
import core/io

public reader: type = struct
    f:    io.none_open | io.file
    buf:  []mut u8
    fill: usize
    pos:  usize
end reader

public open: (A: type is allocator, inout h: any io.world, inout a: A,
              path: utf8, size: usize) -> (r: reader) ! ... =
    f := try io.open_read(h, path)
    undo io.close(h, f)

    buf := try mem.new_slice(T: u8, a: a, n: size)

    r = (f: f, buf: buf, fill: 0, pos: 0)
end open
```
Two fallible acquisitions and one undo entry, which is the shape
prototype 3 argued for, in the small. Nothing fallible follows the
commit — and here the commit is one assignment at the end, so the
discipline [1200] asks for is easy to keep rather than merely
stated.

The line is a view into the reader's own buffer, so the signature
says so. The caller may read it and may not refill while holding
it, which is the bug this would otherwise be.
```landin
public next_line: (inout r: reader, inout h: any io.world)
                  -> (line: []u8 from r) ! io.io_failed | io.at_end =
    loop do
        k := newline_in(r.buf[r.pos ..< r.fill])
        match k
            not_present: try refill(r, h)
            found (at):
                start := r.pos
                r.pos = r.pos + at + 1
                line  = r.buf[start ..< start + at]
                return
        end match
    end loop
end next_line

refill: (inout r: reader, inout h: any io.world)
        -> none ! io.io_failed | io.at_end = ... end

```
shut consumes the reader, which is what makes it read like close.
The alternative was to sink r.f out of an inout parameter and then
have nothing to assign back, since there is no i32 that means
closed. [W3]
```landin
public shut: (A: type is allocator, sink r: reader,
              inout h: any io.world, inout a: A) -> none =
    match r.f
        none_open: _ = 0
        file (fd): io.close(h, fd)
    end match
    mem.drop_slice(a, r.buf)
end shut

```

## app/filter  —  runtime dispatch, one

'self: ptr mut T', because a filter may count. The permission is
in the type since 0.1.0, so the entry says what it does without
also claiming it might re-point the pointer — which the older
inout spelling did claim, and which was never true.
```landin
public filter: type = concept (T: type)
    keep: (self: ptr mut T, line: []u8) -> (yes: bool)
end filter

```
1. Threshold on the level field.
```landin
public level_filter: type = struct
    least: u8
end level_filter

level_keep: (self: ptr mut level_filter, line: []u8) -> (yes: bool) =
    yes = level_of(line) >= self.val.least
end level_keep

level_filter is filter (keep: level_keep)

```
2. Substring.
```landin
public match_filter: type = struct
    needle: utf8
end match_filter

match_keep: (self: ptr mut match_filter, line: []u8) -> (yes: bool) =
    yes = text.contains(utf8(line), self.val.needle)
end match_keep

match_filter is filter (keep: match_keep)

```
3. Every nth line, which is why the concept is inout: this one
writes to itself on every call.
```landin
public sample_filter: type = struct
    every: u32
    seen:  u32
end sample_filter

sample_keep: (self: ptr mut sample_filter, line: []u8) -> (yes: bool) =
    self.val.seen = self.val.seen + 1
    yes = self.val.seen % self.val.every == 0
end sample_keep

sample_filter is filter (keep: sample_keep)

```

## app/dest  —  runtime dispatch, two

```landin
import core/mem
import core/io

public dest: type = concept (T: type)
    emit: (self: ptr mut T, inout h: any io.world, line: []u8)
          -> none ! io.io_failed
    done: (self: ptr mut T, inout h: any io.world)
          -> none ! io.io_failed
end dest

```
1. Write the lines out, through a buffer of its own.
```landin
public text_dest: type = struct
    f:    io.file
    buf:  []u8
    used: usize
end text_dest

public open_text_dest: (A: type is allocator, inout h: any io.world,
                        inout a: A, path: utf8, size: usize)
                       -> (d: text_dest) ! ... =
    f := try io.open_write(h, path)
    undo io.close(h, f)

    buf := try mem.new_slice(T: u8, a: a, n: size)

    d = (f: f, buf: buf, used: 0)
end open_text_dest

text_emit: (self: ptr mut text_dest, inout h: any io.world, line: []u8)
           -> none ! io.io_failed = ... end
text_done: (self: ptr mut text_dest, inout h: any io.world)
           -> none ! io.io_failed = ... end

text_dest is dest (emit: text_emit, done: text_done)

```
2. Count by level and print a table at the end.
The counts are a fixed array rather than a map, and that was
not a shortcut: the concept has no allocator among its entries,
because the other implementation has no use for one. So this
one cannot ask for memory while emitting, and the honest answer
was to pick a representation that never needs any. [W4]
```landin
public count_dest: type = struct
    by_level: [8]u32
    total:    u32
end count_dest

count_emit: (self: ptr mut count_dest, inout h: any io.world, line: []u8)
            -> none ! io.io_failed =
    lvl := level_of(line)
    self.val.by_level[lvl] = self.val.by_level[lvl] + 1
    self.val.total = self.val.total + 1
end count_emit

count_done: (self: ptr mut count_dest, inout h: any io.world)
            -> none ! io.io_failed = ... end

count_dest is dest (emit: count_emit, done: count_done)

```

## app/config  —  building the chain from argv

```landin
import core/mem
import core/text
import core/vec
import config/diag
import core/io
import app/filter
import app/dest

public bad_argument: atom

```
The reason any exists. The chain's length and the types in it are
decided by the command line, so []T cannot hold it and no generic
function can be written over it. [1400] says so; here it is.
```landin
public config: type = struct
    chain: vec.list(any filter.filter)
    to:    any dest.dest
    input: utf8
end config

public build: (A: type is allocator, inout h: any io.world, inout a: A,
               args: []cstring, inout d: any diag.log)
              -> (c: config) ! ... =
    mut chain := vec.new_list(T: any filter.filter)
    mut input:   utf8 = ""
    mut to_file: utf8 = ""

    mut k: usize = 1
    while k < lenof args do
        arg := text.from_c(args[k])

        if text.eq(arg, "--level") then
            k = k + 1
            fail bad_argument when k >= lenof args
            f := try mem.new(T: filter.level_filter, a: a)
            f.val = (least: try level_named(text.from_c(args[k])))
            try vec.push(chain, a, any(f))

        elsif text.eq(arg, "--match") then
            k = k + 1
            fail bad_argument when k >= lenof args
            f := try mem.new(T: filter.match_filter, a: a)
            f.val = (needle: text.from_c(args[k]))
            try vec.push(chain, a, any(f))

        elsif text.eq(arg, "--every") then
            k = k + 1
            fail bad_argument when k >= lenof args
```

[0950] in one line: a bad number here is foreseeable
from what we already hold, so it is reported and
worked around rather than routed through the channel.
The else arm yields the value, and nobody had to
invent a placeholder.
```landin
            mut n := text.to_u32(text.from_c(args[k])) else (e)
                d.note(text.nowhere, diag.error,
                       "--every wants a number, using 1")
                1
            end
```
and zero is a number, which would be a modulo by zero
three hundred lines away. Foreseeable from what we
hold, so [0950] says check it here.
```landin
            if n == 0 then
                d.note(text.nowhere, diag.error,
                       "--every 0 makes no sense, using 1")
                n = 1
            end if
            f := try mem.new(T: filter.sample_filter, a: a)
            f.val = (every: n, seen: 0)
            try vec.push(chain, a, any(f))

        elsif text.eq(arg, "--out") then
            k = k + 1
            fail bad_argument when k >= lenof args
            to_file = text.from_c(args[k])

        else
            input = arg
        end if

        k = k + 1
    end while

```
The only place the two destinations are chosen between, and
the only place their concrete types appear. Everything
downstream sees 'any dest'.
```landin
    mut chosen: any dest.dest
    if lenof to_file > 0 then
        t := try mem.new(T: dest.text_dest, a: a)
        t.val  = try dest.open_text_dest(h, a, to_file, 8 * 1024)
        chosen = any(t)
    else
        t := try mem.new(T: dest.count_dest, a: a)
        t.val  = (by_level: zeroed, total: 0)
        chosen = any(t)
    end if

    c = (chain: chain, to: chosen, input: input)
end build

```

## app  —  the program

```landin
import core/mem
import core/text
import core/vec
import config/diag
import core/io
import app/read
import app/dest
import app/config

```
Everything for the whole run comes out of one arena: the filters,
the destination, the reader's buffer. None of it is freed one
piece at a time.
args is a parameter and not io.args(): a run handed an in-memory
world must be handed its command line too, or the root is only
half replaced and the test cannot say what it is testing.
```landin
run: (inout h: any io.world, inout a: arena, inout d: any diag.log,
      args: []cstring) -> (kept: u32) ! ... =
    mut cfg := try config.build(h, a, args, d)

    fail config.bad_argument when lenof cfg.input == 0

    mut r := try read.open(h, a, cfg.input, 64 * 1024)
    defer read.shut(r, h, a)

    kept = 0
    loop do
        line := read.next_line(r, h) else (e)
            break when e == io.at_end
            fail e
        end

```
The chain, and what the whole prototype exists for. The
elements are writable because the list's storage is, and
the entries say 'ptr mut T' so a counting filter works.
Indexed rather than 'for f in cfg.chain', because
iterable hands out a copy of the element and there is
nothing to write back through [1160].
```landin
        mut pass := true
        xs := vec.used(cfg.chain)
        for k in 0..<lenof xs do
            pass = xs[k].keep(line)
            break when not pass
        end for

        if pass then
            try cfg.to.emit(h, line)
            inc kept
        end if
    end loop

    try cfg.to.done(h)
end run

```
A callback not worth a concept: one use, one shape, no second
implementation on the horizon. So it is the pair from [1000],
written out, and the contrast with the chain above is the point.
A concept earns its place when the set of implementations is
open; a pair is enough when it is not.
```landin
public on_progress: type = struct
    call:  (state: ptr u8, done: u32) -> none
    state: ptr u8
end on_progress

```
Hosted entry. No arguments: argc and argv in the C shape cannot
be indexed without core's slice_from, so the arguments come from
core as a slice instead.
```landin
public main: () -> (code: i32) =
    mut h := io.host()
    w := any(addr h)

    arena program do
        mut logger := diag.to(w.err())
        d := any(addr logger)

        kept := run(w, program, d, io.args()) else (e)
            report_failure(w, e)
            code = 1
            return
        end

        print_summary(w, kept)
        code = if d.failed() then 1 else 0 end if
    end program
end main

```
And what the root buys, which is the reason for all of it. run
never learns which world it was handed.
```landin
test_drops_debug_lines: () -> none =
    mut h := io.in_memory([(name: "in.log", body: "DEBUG a\nERROR b\n")])
    w := any(addr h)
    arena scratch do
        mut logger := diag.new_log(N: 32)
        d := any(addr logger)
        kept := run(w, scratch, d, ["logtool", "in.log"]) else 0
        assert(kept == 1)
        assert(text.eq(io.written(h), "ERROR b\n"))
    end scratch
end test_drops_debug_lines
```
The arena is a block, so its extent is exact and everything the
program allocated dies with it [0820]. Hosted, that is the same
moment the process exits, so the block is bookkeeping rather than
necessity — but it is the same code that would run where it is
necessary, which was the point of the range from 32KB to 32TB.
What is not stated anywhere is what happens to that frame origin
when the arena is passed on as a parameter, which it is here. [W7]

---

```landin
[W] WHAT THIS ONE FOUND
The resolutions below cite the pre-release revisions this
specification passed through, 0.0.1 to 0.0.17, on the way to 0.1.0.
They are kept because when one thing was settled relative to another
still carries information.

```

---

```landin
Seven, which is fewer than the container library and about what a
program that uses the language rather than stretching it should
produce. All are worked into tour 0.0.13. Two of them changed something
larger than themselves: W1 made [1680] tell the truth about its own
claim, and W3 resolved itself by pushing the design somewhere better
while the file was being written.

W1  RESOLVED at 0.0.13, and it did more than fill a gap: it made an
    existing principle honest. [1680] said a function given no
    allocator cannot allocate, enforced by nothing more exotic than
    an argument list. That claimed more than the language delivers,
    because any function can reach for a root — io.host() here, or
    ptr(0x4002_0000) in a driver. So the principle now says it
    exactly: below a root the argument list is the whole
    enforcement, the roots are two and both nameable, and at those
    it is a habit. Restricting the first to the entry module is
    available later and cannot close the second, since a driver has
    to be able to write an address.

    Writing this also found an error in this file. Io was a struct,
    which made the whole capability story worthless: nothing else
    could be put in its place. It is a concept now, travelling as
    'any io.world' rather than as a type parameter, because an
    indirect call in front of a system call costs nothing where an
    allocator sits in hot loops and is threaded generically.

    The original finding, for the record.

    Where a capability comes from. Every capability here is passed in
    from somewhere — the allocator, the Io, the diagnostics sink.
    Follow the chain up and it ends at main, where io.host() mints one
    out of nothing. That call is the whole testability story of the
    language in a single line, and the tour never mentions it.

    It should say at least this much: capabilities bottom out at the
    entry point, that is the only place one is created rather than
    passed, and everything below main can be handed a different one —
    which is what makes a hosted program testable and what lets the
    same code run freestanding on a different root.

    Whether minting is restricted to the entry point or merely
    conventional is a real question. Restricting it would make "this
    subtree cannot touch the world" a checkable claim rather than a
    habit, which is a large promise and should be made or refused
    deliberately rather than by omission.

W2  RESOLVED at 0.0.13: the no-argument main is the ordinary form and
    the arguments come from core as a slice. The C shape stays
    available for whoever wants it.

    The original finding, for the record.

    What a hosted program is handed. [1650] says main follows the
    system C ABI, so it gets argc and argv. Turning those into
    something indexable needs slice_from, which is core-only by [0500].
    So either the runtime hands the program a []cstring or core
    provides the helper written here as io.args(). Either is fine;
    neither is written down, and until one is, a program cannot read
    its own arguments.

W3  RESOLVED while writing, and worth recording because the rule
    pushed the design somewhere better. shut first sank r.f out of an
    inout parameter, which [0910] then wants assigned again before
    returning — and there is nothing to assign, since io.file is a
    distinct i32 and no i32 means closed. Inventing a reserved
    invalid descriptor would have reintroduced exactly the sentinel
    that removing null was meant to avoid.

    Two things came out of it instead. The field became
    none_open | io.file, which is honest — a reader that has been shut
    has no file — but not free, and this finding said it was. [0480]
    promises the niche for an atom and a pointer, because a pointer
    has a bit pattern nobody else can use. io.file is a distinct i32
    and every i32 is a plausible descriptor, so the union carries a
    tag and the reader is a word wider. That is a fair price and it
    should be stated as one. And shut took
    the whole reader by sink, so it reads like close and the question
    does not arise. Both are better than what was there.

W4  RESOLVED at 0.0.13, written beside [1260] where the same thing is
    said about error sets: a concept fixes the shape for every
    implementation there will ever be, and widening one until it fits
    the hungriest hands everyone the sum of everyone's needs.

    The original finding, for the record.

    A concept fixes what every implementation may ask for. count_dest
    would like to allocate while emitting and cannot, because the
    concept it shares with text_dest has no allocator among its
    entries and text_dest has no use for one. The honest answer was to
    pick a representation that never needs memory — a fixed array of
    counts rather than a map.

    That is not a defect. It is what [1260] says about error sets, one
    level up: a concept fixes the shape for every implementation there
    will ever be. It belongs written down beside it, because the pull
    to widen a concept until it fits the hungriest implementation is
    strong, and gives every implementation the union of everyone's
    needs. When it genuinely does not fit, the answer is two concepts.

W5  RESOLVED at 0.0.13, and smaller than this finding claimed. [1150]'s
    example is correct: items there is a slice, and a slice element
    is a place. What was missing is the boundary — inout on a loop
    binding is for arrays and slices, and over anything else that
    satisfies iterable the binding is a value, because item hands out
    a copy. A container that wants to be walked and changed hands out
    a writable view, which is what this file does. No second concept,
    no pointer as a loop binding, no change to [1150].

    The original finding, overstated, for the record.

    [1150] and [1320] contradict each other, and it is reached at once.

        for inout item, idx in items do
            item = item + i32(idx)
        end for

    That is [1150]. But iterable at [1320] has

        item: (s: T, c: Cur) -> (v: Item)

    which hands out a copy, so assigning to the binding writes to the
    copy. There is no entry a traversal can write back through, and so
    [1150]'s example cannot work for any type that satisfies iterable —
    which is every container in prototype 3.

    Written around here by taking a writable view and indexing it,
    which works and reads acceptably. But it means the mutating for
    loop the tour advertises does not exist.

    Two ways to fix it. Have item return a reference derived from the
    collection, (v: Item from s), and let the loop's convention demand
    a writable one — 0.0.9's machinery doing what it was built for,
    needing Item to be able to be a place rather than a value. Or a
    second concept for mutable traversal whose item hands back a ptr,
    which is more honest about what is happening and costs a concept.
    The first is smaller and fits what is already decided, and needs a
    careful look at what Item then is.

W6  RESOLVED at 0.0.13: the pair carries both. Whether the pointee may
    be written through, which comes from how the pair was reached, so
    a stateful implementation behind an inout self works — which is
    most of them. And the pointee's origin for [0840], so an 'any'
    over something with frame origin cannot be stored where it would
    outlive the frame.

    The original finding, for the record.

    Whether an 'any' carries the permission of what it points at. The
    chain is walked through used_mut so the elements are writable, and
    the entries take inout self, since a filter may count. Nothing
    says the pair's data pointer inherits writability from how the
    pair was reached. It has to — a stateful implementation behind
    runtime dispatch is not exotic, it is most of them — but [1370]
    describes the pair as a data pointer and a table and stops there.

    Unstated and related: whether the origin of what an 'any' points
    at travels with the pair for [0840]. It should, and then a
    frame-origin any could not be stored in a longer-lived list, which
    is the bug worth catching here.

W7  RESOLVED at 0.0.13 the way this finding argued: passed on as a
    parameter, an arena is an ordinary allocator again, and what
    comes out of it there is allocated rather than frame. It has to
    be, or a block arena would be useless beyond its own function,
    and it is sound because the block is the outermost extent.

    The original finding, for the record.

    What happens to an arena block's frame origin when the arena is
    passed on. [0820] says everything from a block has frame origin and
    nothing from it may leave the block. main opens a block and hands
    the arena to run, which allocates from it and returns a config
    holding those pointers.

    If frame origin travelled through the parameter, run could not
    return anything it allocated, and a block arena would be useless
    beyond the function that opened it — which is most of what one is
    for. If it does not travel, the block's guarantee holds only where
    the block is, and the tour overstates it.

    The second is right and is also sound, and the reason is worth
    stating rather than leaving implicit: the block is the outermost
    extent, so anything that would outlive it has to pass the block on
    its way out, and the check at the block catches it there. Through
    a parameter the arena is an ordinary allocator. That sentence is
    missing, and without it [0820] and [0770] disagree.
```

---
