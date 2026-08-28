# Learn Landin in Y minutes

Ada, but small. Zig, but sweeter. One systems language from 32KB to
32TB. Move fast, keep the pointers, and let the compiler tell you when
you are being an idiot.

Named after Peter Landin, who coined the term "syntactic sugar" and
wrote "The Next 700 Programming Languages". This one is the 701st.

Version 0.1.0 — the first version of the specification proper. It was
arrived at over seventeen pre-release revisions, four prototype
programs and two outside reviews. That history is kept in a separate
archive; the part of it with lasting value is at the end of this file,
under WHAT WAS TRIED AND DROPPED.

Numbering: [NNNN] is stable, which is the point of it — an insert never
renumbers anything, so the order things are read in and the order of
the numbers need not agree. They agree today, at 0.1.0, and they will
drift, and that is the numbering working rather than failing. Gaps of
ten leave room. Sections carry titles and no numbers, because nothing
cites a section. Refer to decisions by number.

This file explains the language and does not decide it. `spec.md` is the
normative document: it holds the grammar of the kernel the compiler
enables today, the rules this file left unsaid, and the register of
decisions taken while implementing them. Where the two could be read
differently, `spec.md` decides. Everything still open, every
implementation dependency and every disposition is owned by ROADMAP.md,
not by a second list here.

---

## COMMENTS

These three are shown by being written, so each is kept exactly as it
appears in a program: the marker is the comment.

### [0010] Line comment, to end of line

```landin
-- [0010] Line comment, to end of line.
```

### [0020] Block comment. Nests properly

```landin
--( [0020] Block comment. Nests properly.
    --( so this inner one is fine )--
)--
```

### [0030] Doc comment. Attaches to the declaration that follows

```landin
--- [0030] Doc comment. Attaches to the declaration that follows.
```

## DECLARATIONS

### [0040] Full form: name, type, value

Full form: name, type, value. Immutable by default.
```landin
greeting: utf8 = "hello"

```

### [0050] Type inferred from the value

Type inferred from the value.
```landin
count := 7

```

### [0060] Mutable binding

Mutable binding.
```landin
mut total: u32 = 0

```

### [0070] Two questions about a reference

Two questions about a reference, and they are independent:
may the name be pointed somewhere else, and may the thing it
points at be written? mut on the binding answers the first.
The type answers the second, with mut inside it, as the
POINTERS section shows — and nothing else answers either.
```landin
mut cursor: ptr u32 = addr first                 -- re-pointable, reads
knob:  ptr mut u32 = addr setting                -- fixed, writes
gpioa: volatile ptr mut port = ptr(0x4002_0000)  -- fixed, writes

```

### [0080] Declaration only

Declaration only. Must be assigned before use.
```landin
mut result: u32

```

### [0090] Exported from the module

Exported from the module. Without it, module-internal.
```landin
public version: u32 = 3

```

### [0100] Several names may share one declaration

Several names may share one declaration, which is the same
form field lists already use.
```landin
public red, green, blue: u8
north, south, east, west: atom

```

### [0110] Left of ':' is always the name being introduced

Left of ':' is always the name being introduced.
Right of ':' is what fills it: a type, or (with '=') a value.

### [0120] Types are declared like any other value, with 'type'

Types are declared like any other value, with 'type'.
```landin
point: type = struct
    x: f32
    y: f32
end point

```

### [0130] Order inside a module does not matter

Order inside a module does not matter. Forward references
are fine; the compiler collects names before resolving them.

### [0140] An inner scope may shadow an outer name

An inner scope may shadow an outer name.

## NUMBERS AND LITERALS

### [0150] Integers: u8 u16 u32 u64 u128, i8 i16 i32 i64 i128

Integers: u8 u16 u32 u64 u128, i8 i16 i32 i64 i128.
Any other width exists as well — u4, u12, u23 — for the
packed fields of [0730], where the datasheet decides how
many bits a thing gets. Outside a packed struct one
occupies the next machine width, and a one-bit field is
spelt bool.

### [0160] Pointer-width integers: usize, isize

Pointer-width integers: usize, isize.

### [0170] Floating point: f16, f32, f64

Floating point: f16, f32, f64. No f80.

### [0180] bool, with true and false

bool, with true and false.

### [0190] Integer literals are untyped

Integer literals are untyped. They take the type of their
context, and are checked at that point.
```landin
tiny:  u8  = 5
large: u64 = 5
-- bad: u8 = 300      is a compile error
```

### [0200] With no context, an integer literal defaults to i32

With no context, an integer literal defaults to i32.
```landin
plain := 5

```

### [0210] Float literals are always recognisable as such

Float literals are always recognisable as such. There is no
silent slide between the two classes.
```landin
ratio: f32 = 5.0
-- wrong: f32 = 5     is a compile error
half := 1.0 / 2.0     -- 0.5
zero := 1 / 2         -- 0, integer division

```

### [0220] Bases, separators, exponents

Bases, separators, exponents.
```landin
hex_value := 0xDEAD_BEEF
bin_value := 0b1010_0101
oct_value := 0o755
big_value := 1_000_000
sci_value := 1.5e10
neg_exp   := 1.0e-6

```

### [0230] Hex float literals express every representable value exactly

Hex float literals express every representable value exactly,
including subnormals.
```landin
pi_exact: f64 = 0x1.921fb54442d18p+1
smallest: f32 = 0x1.0p-126

```

### [0240] IEEE special values

IEEE special values. The sign of a literal is preserved by
constant folding. The sign of a NaN produced by arithmetic
is not specified.
```landin
neg_zero:  f64 = -0.0
pos_inf:   f64 = f64.infinity
neg_inf:   f64 = -f64.infinity
quiet_nan: f64 = f64.nan
neg_nan:   f64 = -f64.nan

```

### [0250] Character literal is a codepoint, typed u32

Character literal is a codepoint, typed u32.
```landin
letter_a := 'a'

```

### [0260] Text literals are untyped too

Text literals are untyped too. They take utf8, []u8, utf16
or cstring from context; with no context, utf8.
Every literal carries a trailing NUL that the length does
not count, so passing one to C costs nothing.
```landin
name:  utf8    = "hello"
cname: cstring = "hello"
```
A literal lives in read-only storage, so a reference to one
cannot be written through by [0070] however the binding is
declared. Writable text is a copy into storage you asked
for.
```landin
-- greeting: []u8 = "abc"
-- greeting[0] = 0x78          -- error, the literal is static
```

### [0270] The escape set is closed and small

The escape set is closed and small:
  \n \r \t \e      newline, return, tab, escape
  \\ \" \'         the characters themselves
  \xNN             one byte, exactly two hex digits
  \u{...}          one codepoint, any number of digits
There is no octal form and no \0; write \x00. An unknown
escape is a compile error, never silently the character.
\xNN is only valid where bytes are meant, \u{...} only where
text is meant, so a literal can never be invalid UTF-8.
```landin
line  := "col\tsep\n"
smile := "\u{1F600}"
byte  := "\xFF"          -- []u8 context only

```

### [0280] Raw literals: N quotes on each side, N at least three

Raw literals: N quotes on each side, N at least three.
If the content contains three, use four. Nothing is escaped.
The indentation of the closing delimiter is stripped from
every line, so a block can sit indented in the code and
still start at the left margin.
```landin
help := """
        usage: tool [options]
          -v    verbose
        """

```

## OPERATORS

### [0290] Arithmetic

Arithmetic: + - * / %
Integer division truncates toward zero; the remainder takes
the sign of the dividend.
```landin
q := -7 / 2      -- -3
r := -7 % 2      -- -1

```

### [0300] Overflow traps

Overflow traps. Wrapping is a separate operator: +% -% *%

### [0310] No implicit conversion

No implicit conversion. Conversion is a type applied to a
value. If the value is known at compile time, an impossible
conversion is a compile error; otherwise it traps.
```landin
-- bad: u8 = u8(300)        compile error
runtime_narrow := u8(measured)   -- traps if out of range

```

### [0320] Shifts fill with zeros beyond the width, for any amount

Shifts fill with zeros beyond the width, for any amount.
Signed >> keeps the sign. One form only.
```landin
z := 1 << 40     -- 0 in a u32 context

```

### [0330] Bitwise

Bitwise: & | ^ ~ << >>
These bind TIGHTER than comparisons, unlike C.
```landin
flag := status & 1 == 0     -- means (status & 1) == 0

```

### [0340] Logical: and, or, not

Logical: and, or, not. Words, so '!' stays free for the
error channel.
```landin
ok := a < b and not done

```

### [0350] Comparison

Comparison: == <> < <= > >=
Inequality is <>, not !=.

### [0360] Ranges

Ranges, inclusive unless narrowed:
0..9  inclusive     0..<10  half-open
A range is an ordinary value from core that satisfies
iterable, not a concept of its own. Left-exclusive forms
are gone; step(0, 10, 2) and friends are library calls.

### [0370] sizeof, alignof and lenof

sizeof, alignof and lenof.
On an array the length is a compile-time value; on a slice
it is a run-time value; on a literal it is compile-time.
The expressions in a literal measured by lenof are checked for one
scalar element type but are not evaluated or read.
```landin
w1 := sizeof u32
a1 := alignof u64
n1 := lenof grid
n2 := lenof ([next(), next(), next()]) -- 3; next is not called

```

### [0380] addr takes an address

addr takes an address, .val names the pointee — reading on
the right of an assignment, written on the left.

### [0390] Assignment is a statement

Assignment is a statement, never an expression:
=  +=  -=  *=  /=  %=  &=  |=  ^=  <<=  >>=
and the wrapping forms  +%=  -%=  *%=

### [0400] No `++` and no `--`

No `++` and no `--`. There are inc and dec statements, though
`x += 1` says the same thing.
```landin
inc total
dec total

```

### [0410] Evaluation order is fixed

Evaluation order is fixed, because a language whose point
is that costs are visible cannot leave where they happen to
the compiler. Operands and call arguments evaluate left to
right. Aggregate fields initialise in the order they are
written, whatever order the layout puts them in. 'and' and
'or' short-circuit, left to right. An assignment evaluates
its destination place first, then the value.
A deferred call is the one thing that does not evaluate
where it is written, and [1100] says when it does instead.

### [0420] The dot is not only field access

The dot is not only field access. All of these are member
selection: p.val (pointer target), T.less (concept entry),
http.get (module member), f64.nan (named value of a type).
Separate tokens: .. (range), ... (inferred error set), and
the decimal point.

## POINTERS

### [0430] Pointer type, address, dereference

Pointer type, address, dereference. All words, no sigils.
mut inside the type says the pointee may be written; without
it the pointee is read-only. .val names the pointee, so it
reads on the right of an assignment and, with mut, is an
ordinary target on the left.
```landin
mut value: u32 = 42
p: ptr mut u32 = addr value
v := p.val
p.val = 43
ro: ptr u32 = addr value         -- same address, read-only through ro
-- ro.val = 1              -- error
```

### [0440] A mut reference satisfies a plain one, never the reverse

A mut reference satisfies a plain one, never the reverse.
That is not a conversion and [0310] is not bent: no bit
changes and nothing is lost, a permission is forgotten. It
is the one relaxation the language has, it goes one way,
and it is what makes a read-only parameter usable at all.
```landin
add_up: (xs: []i32) -> (total: i32) = ... end
add_up(writable_slice)           -- fine, []mut i32 relaxes to []i32

```

### [0450] Permission is shallow

Permission is shallow: it comes from the reference type and
from nowhere else. An immutable binding or an 'in' parameter
protects the value it holds, not what that value points at —
so a list handed over as 'in' still yields writable elements
if its storage is writable.
Deeper protection would mean knowing which references a
value owns and which it merely borrows, and this language
does not track ownership [0910]. Where a read-only view is
wanted, hand one out: that is what an accessor is for, and
the caller relaxes what it gets by [0440].

### [0460] Address literal

Address literal. The pointee type comes from context, and a
register is written through, so it is a mut pointee sitting
in an immutable binding — which is exactly the pair [0070]
separates.
```landin
gpio: volatile ptr mut u32 = ptr(0x4001_0000)

```

### [0470] Both directions between a pointer and an integer are the

Both directions between a pointer and an integer are the
ordinary conversion of [0700], a type applied to a value.
No special word: this is the one conversion the language
marks by what it costs rather than by how it is spelled.
```landin
dma_source := u32(addr port.val.dr)
```
What it costs: an integer that used to be a pointer has no
origin. Build a pointer back out of one and you get
something that borrows nothing, whose lifetime nobody
knows, and about which the compiler will say nothing ever
again. It is the one place inside the language where the
lifetime system is deliberately left behind, on the same
footing as the C boundary. Taking the address of a
volatile field is unremarkable by comparison: volatility
is a property of the access path, not of the number.

### [0480] There is no null

There is no null. "maybe a pointer" is an ordinary union of
an atom and a pointer type; the compiler represents it as a
plain pointer with 0 for the empty case.
```landin
none_found: atom
maybe_ptr: type = none_found | ptr mut u32

```

### [0490] Pointers are a system tool

Pointers are a system tool: hardware, the C boundary, and
library internals. Everyday code uses slices, handles and
indices.

### [0500] Three operations sit between pointers and slices

Three operations sit between pointers and slices, and core
has them where nothing else does. Every allocator needs all
three, and none can be written in the language proper.
```landin
mem.offset:     (p: ptr mut u8, n: usize) -> (q: ptr mut u8)
mem.base_of:    (T: type, s: []T) -> (p: ptr u8)
mem.base_of:    (T: type, s: []mut T) -> (p: ptr mut u8)
mem.slice_from: (T: type, p: ptr mut u8, n: usize) -> (s: []mut T)
```

### [0510] slice_from is where uninitialised storage is smuggled in

slice_from is where uninitialised storage is smuggled in,
and calling that an answer was too kind to it. It hands
back a []mut T over memory holding no T, so the type says
more than is true from the allocation until the write, and
nothing checks the gap. Containers hold the invariant
themselves — a growing array by its length, a hash table by
its state array — and that works, for a container whose
author is careful.
Where it does not work is inline storage. small(T, N) holds
an [N]T that is not full yet, and there is no honest value
to put in the empty slots: [0540] forbids zeroed for a T with
no zero image, and ptr is such a T. So until there is a way
to say uninitialised in a type, that shape is restricted to
a T that has a zero image, and general uninitialised
generic storage is not supported.
The answer remains a distinct raw-storage type — one that
tracks capacity apart from the initialised count and admits
one slot at a time. Its exact operations and invariants are
decided from executable container cases in ROADMAP.md at R3.20
and R3.30, not guessed as a prerequisite to the first front end.

## ARRAYS, SLICES AND TEXT

### [0520] Array: a value

Array: a value. Assignment copies. Size is part of the type.
An array literal assigned to existing storage is formed there in written order:
each element is evaluated and written before the next one begins. A later
element can therefore observe an earlier write, and a failure can leave the
written prefix changed; no hidden array-sized temporary is implied. An explicitly
typed local may finish a nonempty written prefix with [0560]'s repeated suffix;
the same direct formation and ordering apply.
```landin
grid: [4]f32 = [1.0, 2.0, 3.0, 4.0]
mut next: [4]f32
next = [grid[0], grid[1], grid[2], grid[3]]

```

### [0530] The length may be inferred from the literal

The length may be inferred from the literal.
```landin
triple := [1.0, 2.0, 3.0]        -- [3]f32

```

### [0540] zeroed is the all-bits-zero image of a type

zeroed is the all-bits-zero image of a type. Two separate
properties decide where it may appear. A type HAS a zero
image when all-zero is a valid value for it; that is what
lets a surrounding struct or array be zeroed. A type ACCEPTS
the word zeroed only when that image has one obvious
reading. Numbers, bool, ranges containing zero and
aggregates of those accept it. Named value sets do not:
write the name. Pointers and 'any' have no zero image at
all, because there is no null. Where the destination supplies
that context, assignment writes the complete zero image as one
value rather than spelling its parts.
```landin
mut buffer: [256]u8 = zeroed
buffer = zeroed                 -- clear the existing array as a whole
irqs:   set(irq) = zeroed       -- fine: a set is bools, see [0730]
-- mode: clock_mode = zeroed    -- error, write 'internal'
-- p:    ptr u32     = zeroed   -- error, no zero image
```

### [0550] The first of those two properties is also a concept

The first of those two properties is also a concept, so
generic code can ask for it. It is supplied by the compiler
rather than declared, which is the only kind of conformance
that is: the compiler is the only thing that knows a type's
bit patterns.
```landin
zeroable: type = concept (T: type)
end zeroable

```
Which is what lets a shape that needs a value for storage it
has not filled yet say so, instead of pretending — see
small at [1350] and the reason at [0510].

### [0560] Repetition, for static patterns that live in flash

Repetition, for static patterns that live in flash.
```landin
pattern: [256]u8 = [256 of 0xFF]
filled:  [256]u8 = [of 0xFF]         -- length from the type

read_header: () -> none =
    header: [8]u8 = [0x7F, 0x45, of 0]
end read_header

```
The repeated expression runs once, not once for every element. In the mixed form
`[e1, ..., ek, of repeated]`, an explicitly typed local, explicitly typed module
binding or assignment to a mutable fixed array requires `1 <= k < N`. A local or
assignment evaluates and stores the prefix left to right, then evaluates
`repeated` once and compactly fills the suffix. An assignment reaches its
destination first; all right-hand reads use the incoming definite-assignment
state, and successful completion assigns the whole array. A module initializer
requires every prefix and suffix expression to be compile-time known [1940] and
keeps a compact static image: the finite prefix plus one repeated suffix pattern.
Inference, nesting and general-value mixed forms remain refused. `of` stays
contextual: `[of, other, of]` and `[of + 1]` remain ordinary literals when `of`
names a binding. A nonzero written fixed-array type accepts either full-array
form for module state or a local; at module scope the expression must be a
compile-time known scalar [1940]. A counted repetition
may also supply an inferred local or module binding's length and scalar element
type; an untyped integer element defaults to `i32`. Assignment to an existing
fixed array accepts an explicit count or takes it from the destination:
```landin
flash: [4]u32 = [of 0xFFFF_FFFF]
header_image: [8]u8 = [0x7F, 0x45, of 0]
mut row: [4]u32 = [of next()]
inferred := [4 of next()]
row = [of next()]                 -- each call to next happens once
row = [header(), of padding()]     -- prefix first, then one padding call

```
A zero contextual length and a zero count in the inferred form are refused while
[0580]'s empty-array decision remains open. A count-less inferred initializer
and other general array value positions remain later compiler slices. Every
inferred extent must fit the target's `usize`. A module
repetition uses [1940]'s target-aware fold and range rules; its compact repeated
image survives direct-name chains, while a folded zero pattern has the same
loader-zeroed image as omitted or `zeroed` state.

### [0570] Slice: a view

Slice: a view. Pointer plus length. Copies nothing. mut
inside the type says the elements may be written.
```landin
view:  []f32     = grid[0..<2]      -- read-only elements
edit:  []mut f32 = grid[0..<2]      -- writable, since grid is mut

```

### [0580] An empty slice still has a base

An empty slice still has a base. It is a canonical aligned
address that is not null and may not be dereferenced, so
base_of on an empty slice yields that and nothing pretends
otherwise. Indexing checks the length before it computes an
address, so an empty slice cannot produce one.

### [0590] Fixed arrays are the vector type

Fixed arrays are the vector type. Arithmetic and comparison
on them are element-wise, so there is no second type with
the same shape and different rules. The first backend
lowers them to scalar loops; real vector instructions come
later, as an optimisation, and never on a target without
them.
```landin
va: [4]f32 = [1.0, 1.0, 1.0, 1.0]
vb := va * va
sc := va * 2.0        -- a scalar on either side is fine
s  := reduce_add(vb)
```
Arithmetic applies element by element between arrays of the
same element type and the same length; differing lengths do
not broadcast, they are a type error. Overflow traps per
element, +% wraps per element.
Comparison is deliberately not element-wise: == and <> ask
about the whole array and yield one bool, and the ordering
operators are not defined on arrays. Masks come from named
library functions, so no operator changes result type with
its operands.
[4096]f32 + [4096]f32 is a loop and a 16 KB temporary. That
is visible in the type, but worth saying out loud.

### [0600] Text types are distinct views

Text types are distinct views, not one string type:
utf8    distinct []u8      text, UTF-8 by convention
utf16   distinct []u16
cstring distinct ptr u8    no length, NUL terminated

### [0610] Indexing utf8 by an integer yields the bytes of one

Indexing utf8 by an integer yields the bytes of one
codepoint and is a linear scan. Indexing by a position is
O(1). Both conformances exist; the argument type decides.

### [0620] DEFERRED to a later version, kept here as a design record

DEFERRED to a later version, kept here as a design record.
It touches aliasing, generics, slicing, addr, layout, debug
information and the optimiser all at once, and no program
has yet proved it necessary.
A collection may be stored transposed: one array per field
instead of one array of structs. That is a property of the
collection, not of the struct, so it is not a layout
attribute. Field access through an index goes straight into
that field's array, reading a whole element gathers a copy,
and the address of a whole element does not exist. The
point of it is the last line: one field, contiguous.
```landin
world: type = struct
    items: soa [4096]entity
    count: usize
end world

advance: (inout w: world, dt: f32) -> none =
    for i in 0..<w.count do
        w.items[i].x += w.items[i].vx * dt
    end for

    xs: []f32 = w.items.x
    shift_all(xs, dt)

    first := w.items[0]          -- a copy
    --  p := addr w.items[0]     -- error: the fields are apart
end advance
```
Only for structs without a variant part. Layout attributes
do not apply, because there is no single element layout.

## TYPES YOU DECLARE

### [0630] Atoms: one declaration, one value, its own type

Atoms: one declaration, one value, its own type. This is
the one place where a declaration introduces a type and a
value at once, because they coincide.
```landin
not_found: atom
no_access: atom

```

### [0640] An enumeration is a union of atoms

An enumeration is a union of atoms.
north, south, east and west were declared at [0100].
```landin
compass: type = north | south | east | west

```

### [0650] Distinct type

Distinct type: same representation, different type, no
operations inherited.
```landin
meter:  type = distinct f32
second: type = distinct f32
```
meter + second is a compile error.

### [0660] Range subtype: checked at assignment and conversion

Range subtype: checked at assignment and conversion.
```landin
percent: type = u8 range 0..100

```

### [0670] Struct, block form and inline form

Struct, block form and inline form. Same thing. The inline
form is also the parameter, return and payload list.
```landin
size2: type = (w: u32, h: u32)

```

### [0680] Struct with a variant part

Struct with a variant part. Common fields need no ceremony.
```landin
figure: type = struct
    label: utf8
    area:  f32
    kind: variant
        circle:    (radius: f32) |
        rectangle: (width: f32, height: f32)
    end kind
end figure

```

### [0690] A case with no payload is written bare

A case with no payload is written bare. It is an atom,
and [1700] holds wherever atoms appear, so a variant reads
as the union it is.
```landin
node_kind: type = struct
    kind: variant
        leaf |
        branch: (first: node_id, count: u32)
    end kind
end node_kind

```

### [0700] Construction and conversion use the same form

Construction and conversion use the same form: a type
applied to arguments.
```landin
origin := point(x: 0.0, y: 0.0)
metres := meter(1.5)
```
A variant case is built the same way: the case name applied
to its payload. The tour showed variants being matched long
before it showed one being built.
```landin
mut f: figure = (label: "disc", area: 0.0, kind: circle(radius: 2.0))
f.kind = rectangle(width: 3.0, height: 4.0)

```

### [0710] A struct literal is untyped

A struct literal is untyped, the way a number literal is,
and takes its type from the context — named or anonymous.
What does not convert is a value already typed as an
anonymous struct, a return list for instance: two anonymous
types match when field names, types and order all match,
and neither ever becomes a same-shaped named type.
```landin
here: point = (x: 1.0, y: 2.0)
pair: (quot: i32, rem: i32) = divide(10, 3)
-- named: point_pair = divide(10, 3)     -- no, that is named
```

### [0720] 'of' fills every field the literal did not name

'of' fills every field the literal did not name, which is
the same word and the same place array literals use it in
at [0560]. It has to typecheck for each of them, so 'of
false' works where the rest are bool and 'of zeroed' works
wherever the rest have a zero image.
This is not a default value: [0980] refused those on
declarations, because a new parameter would then fit every
existing call silently. Here the choice is made at each
literal by whoever writes it. The trade is still real and
belongs to that writer — a literal with 'of' picks up a
field added later without a word, one without it breaks
loudly.
```landin
cfg: control = (enable: true, mode: external, of zeroed)

```

### [0730] A register has three kinds of field

A register has three kinds of field, and confusing them is
the classic driver bug. A flag is one bit. A selection is a
set of mutually exclusive named values, encoded as the
datasheet says. A set is independent flags at once. And a
plain number is a plain number.
A set earns its place when its members mean something. A
numbered bank of lines does not: sixteen output pins are
[16]bool at 0..15, not sixteen invented atoms.
```landin
irq_rx:  atom
irq_tx:  atom
irq_err: atom

internal: atom
external: atom
pll:      atom

```
The encoding belongs to the union, not to the atom, so the
same atom may be encoded differently in another register.
The width is the smallest that holds the largest encoding,
so it is usually left out; a base type is written only when
the datasheet gives the field more room than it needs.
```landin
polarity: type = (active_low = 0 | active_high = 1)   -- one bit
clock_mode: type = (internal = 0 | external = 1 | pll = 4)
divider_sel: type = u4 (by_1 = 0 | by_2 = 1)   -- four bits, as given

```
A set is not a kind of its own. set(X) generates a packed
struct of bool, one field per member of X, each sitting at
the bit its encoding names — so membership is a field read,
adding and removing a member is a field write, and building
one is the ordinary struct literal with 'of' from [0720].
There is no set literal, no set operator and no membership
operator, because none of them is needed once it is a
struct.
A union used as a set must carry its encodings, since the
encoding is the bit number. Leaving them out would put the
bit assignment back at the mercy of declaration order,
which is the hole this section closed.
```landin
irq: type = (irq_rx = 0 | irq_tx = 1 | irq_err = 2)

control: type = layout(packed) struct
    enable:  bool        at 0
    mode:    clock_mode  at 4..6
    irqs:    set(irq)    at 8..10
    divider: u12         at 16..27
end control
```
Bit positions are written down rather than implied by the
order of the fields. Every bit nobody claims is reserved by
that fact alone: it cannot be named, it survives a
read-modify-write untouched, and it appears in no
completion list. That removes a field kind, removes the
silent rule that the first field takes the low bits, and
removes the dependence of the encoding on declaration
order — which matters, because reordering fields of a
published register would otherwise be a breaking change
nobody sees.
Within one packed struct it is all or nothing: if one field
carries a position, all of them do.
A field may be an array, which is how every real peripheral
describes sixteen two-bit pin settings in one word. The
element width times the count has to equal the range, and
element zero takes the low bits.
```landin
moder: type = layout(packed) struct
    pins: [16]pin_mode at 0..31
end moder
```
Indexing such a field by a value known only at run time is
ordinary code: it is a shift by a computed amount inside a
register image, with the same bounds check any index gets.
On an image, that is — never straight through the volatile
pointer, for the reason [0740] gives.
```landin
set_pin: (inout m: moder, n: usize, mode: pin_mode) -> none =
    m.pins[n] = mode
end set_pin

```

### [0740] Access behaviour is data, not keywords

Access behaviour is data, not keywords. A register is a
parameterised type carrying how it reads, how it writes and
what it holds after reset, so an SVD generator can express
write-one-to-clear, clear-on-read, write-once and whatever
the next vendor invents without the language growing a word
for each. Writing a single field through a volatile pointer
stays forbidden: build the whole value, write it once.
```landin
status: register(control, read: normal, write: none,
                 reset: 0x0000_0400)
clear:  register(set(irq), read: normal, write: one_clears,
                 reset: 0x0000_0000)

```
A field of register(T, ...) type reads as a T and is
assigned a T, and the access behaviour is checked exactly
there: reading one whose read is 'none' is an error, and so
is writing one whose write is 'none'. Together with the
rule above that gives the shape of every driver — read the
whole image, change it locally, write it back whole.
'reset' initialises nothing. It is what the datasheet says
the register holds after a reset, recorded so that tools
and readers know what they are starting from. The hardware
puts it there, not the program.
```landin
reset_flags: (c: volatile ptr mut control) -> none =
    c.val = (enable: true, mode: external,
             irqs: (irq_rx: true, of false), of zeroed)
end reset_flags

read_modify_write: (c: volatile ptr mut control, n: u32) -> none =
    mut image := c.val
    image.divider = n
    c.val = image
end read_modify_write

```

### [0750] Fields keep the order you wrote them

Fields keep the order you wrote them, with natural alignment
and padding in between, so a hexdump matches the source and
the layout does not shift under a new compiler.
layout(optimal) lets the compiler reorder to save padding.
layout(c) applies the C rules. Byte order is per field.
```landin
packet: type = layout(c) struct
    kind:   u8
    length: big u16
    id:     big u32
end packet

```

### [0760] Attributes are prefix words, from a closed set

Attributes are prefix words, from a closed set. Arguments
are always parenthesised. Closed value sets are atoms;
arbitrary linker names stay strings.
```text
mut public volatile align(n) layout(c|optimal|packed)
```
and 'at' for a bit position, which is why a field or an
entry cannot be called that — the same goes for 'from',
'of', 'with' and 'align' itself.
```text
big little escaping caller fixed option
link(section: "...", symbol: "...", keep, weak,
     inline, noinline)
extern(c|interrupt|naked|...)
```
packed folded into layout, naked into extern, option implies
fixed, and the five toolchain words became one attribute with
named arguments. Register access is data now, not keywords.

## LIFETIME AND ESCAPE

### [0770] There is no borrow checker and there are no lifetime

There is no borrow checker and there are no lifetime
annotations. Instead every pointer, slice and 'any' carries
the origin of what it refers to: static, allocated, or
frame. Frame-origin may not be returned, and may not be
stored where something longer-lived keeps it.
```landin
bad: () -> (p: ptr u32) =
    x := 42
    p = addr x           -- error: a frame origin escapes
end bad

```

### [0780] Parameters are non-escaping by default

Parameters are non-escaping by default, so a callee may use
a pointer freely but not keep it. Keeping it is declared.
```landin
push_front: (inout head: ptr mut node, escaping item: ptr mut node)
            -> none =
    item.val.next = head
    head = item
end push_front

build: (a: arena) -> (head: ptr node) =
    n := try mem.new(T: node, a: a)
    push_front(head, n)             -- allocated, fine

    mut local: node = zeroed
    push_front(head, addr local)    -- error: a frame origin escapes
end build

```

### [0790] The other direction

The other direction. What a returned reference was derived
from is written down, because the caller cannot otherwise
know that the thing it came from has to hold still now.
That, and only that: whether the view may be written is the
return type's business [0430].
```landin
used: (T: type, l: list(T)) -> (s: []mut T from l) = ... end
```
One accessor, not two. It hands out the widest permission
the storage has, and a caller who wants less relaxes it by
[0440] — 'xs: []T = vec.used(l)'. The pair of accessors that
every language with deep const ends up needing is not needed
here.
Named from several parameters at once it borrows all of
them.
With no from clause the result is independent: it borrows
nothing. That is what an allocator returns, and it is why
two live allocations out of one allocator are unremarkable.
Both halves are checked where the function is written.
Returning something derived from a parameter without saying
so is an error, and naming a parameter it did not come from
is an error too, so the clause cannot drift away from the
body.
In obligation it is the mirror of escaping. escaping says
the callee keeps a reference to what the caller handed in;
from says the caller keeps a reference to what the callee
handed back.
It is written rather than inferred, for the reason escaping
is: inference across calls lets a distant body change a
signature, and local compilation is worth more. Writing it
also leaves nothing to carve out — function pointers,
concept entries and the C boundary need no special rule
here, because nothing was ever being inferred.

### [0800] The borrow of reaches across the call from there

The borrow of [0830] reaches across the call from there,
with the derivation supplied by the signature instead of
being visible in one expression. No new checking, and the
fix is the same one: take the view again afterwards.
```landin
xs := vec.used(numbers)
try vec.push(numbers, a, 5)     -- error: numbers is borrowed by xs
use(xs)
```
Nothing is written at the call. A convention is part of the
declaration and appears nowhere else: the compiler has it,
and a caller that misuses what it got is told so at the
next use, so a marker would buy legibility rather than
safety. That is an editor's job, the same way the resolved
error set is. escaping already works this way — it puts an
obligation on the caller and lives only in the signature.

### [0810] Derivation stops at the three primitives of

Derivation stops at the three primitives of [0500]. offset,
base_of and slice_from yield a reference independent of
what went in, and core answers for that. It is the same
privilege and the same place as the promise about
uninitialised storage — one place to audit, two promises —
and it is what lets an allocator hand out storage that
points into itself without the storage borrowing it.
```landin
bump_alloc: (inout a: bump, size: usize, alignment: usize)
            -> (p: ptr mut u8) ! out_of_memory =
    p = mem.offset(a.base, off)     -- no from: offset cut the chain
end bump_alloc

```

### [0820] arena is built in

arena is built in, both as the block below and as the type
a parameter is written with at [0780]. There is nothing to
import for it.
A scratch arena is a block, so its extent is exact rather
than guessed. Everything from it has frame origin, which is
why a local may be referenced from inside it. Nothing from
it may leave the block. There is no general reset: to start
over, open another block.
Passed on as a parameter the arena is an ordinary allocator
again, and what comes out of it there is allocated rather
than frame. That has to be so, or a block arena would be
useless beyond the function that opened it — and it is
sound for a reason worth saying rather than leaving
implicit: the block is the outermost extent, so anything
that would outlive it passes the block on its way out, and
the check there catches it.
```landin
report: (data: []u8) -> none =
    arena scratch do
        mut buf := try mem.new_slice(T: u8, a: scratch, n: 1024)
        format_into(buf, data)
        write_out(buf)
    end scratch
end report

```

### [0830] A view derived from a local borrows it

A view derived from a local borrows it. While the view is
still in use, that local may not be handed on as inout or
sink, which is what stops a container from moving under a
slice into it. The check is local to one function body, so
there is nothing to annotate and the fix is always nearby:
take the view again afterwards. It only applies where the
storage can actually move, and unchecked turns it off with
everything else.
```landin
grow_and_use: (inout l: list, v: i32) -> none =
    xs := l.items
    push(l, v)           -- error: l is borrowed by xs
    use(xs)
end grow_and_use

```

### [0840] Origins join to the shortest-lived part

Origins join to the shortest-lived part. A struct holding
one frame pointer is frame as a whole, and a value chosen
between two branches takes the more restrictive of the two.
Returns need no analysis across function boundaries at all:
frame origin cannot leave a function, so whatever does
leave is allocated or static by construction. A value that
holds no references at all is unconstrained, which is
another reason the idiom is handles and indices.

### [0850] Volatile is exempt from the borrow rule and from every

Volatile is exempt from the borrow rule and from every
aliasing assumption. Hardware routinely needs several typed
windows on one address — a byte view and a word view of the
same register — and that is legal, deliberately.

### [0860] What this does not catch

What this does not catch, said plainly: two different
arenas are indistinguishable, pointers that travel through
a struct field and are read back later, and anything across
the C boundary. A view taken through an accessor used to
be on this list; [0790] took it off. What is left would
need regions or generation counters, and both are
deliberately out.

## FUNCTIONS

### [0870] A function is a value of a function type

A function is a value of a function type. No 'fn' keyword.
'=' opens the body, 'end' closes it, always.
```landin
double: (x: i32) -> (r: i32) =
    r = x * 2
end double

```

### [0880] A single-expression body still takes an end

A single-expression body still takes an end. The expression
fills the named return.
```landin
triple_it: (x: i32) -> (r: i32) = x * 3 end

```

### [0890] Nothing returned

Nothing returned, and never returns:
```landin
log_it:  (m: utf8) -> none = ... end
halt_it: () -> noreturn = loop do end loop end halt_it

```

### [0900] Three parameter conventions

Three parameter conventions, and they are about the value
you were handed — never about what it points at, which the
type says by [0450].
| convention | what it promises |
|---|---|
| `in` | I will not change the value. The default, unmarked. |
| `inout` | I may replace it, exclusively, and the change comes back. Implies mut. |
| `sink` | consumed. The place the caller named is dead afterwards — see [0910], since a place is not always a binding. |

So a function that writes registers through a pointer it
will never re-point takes it as 'in' and the pointer type
carries the mut. That reads as what it does, which the older
rule could not say.
Outputs are not a convention: returns are named.
Orthogonal to all three, 'escaping' says the callee may
keep what a pointer, slice or 'any' refers to beyond the
call, so the caller must prove it lives long enough. In
obligation it is the opposite of sink: sink ends the
caller's duty, escaping extends it.
On a generic parameter escaping says the right thing at
both extremes with no special case. For T = u32 it is
vacuous, since [0840] already leaves a value holding no
references unconstrained; for T = ptr node it is exact.
The origin travels with the type, so one word covers both.
An inout argument need not be a binding. A pointer target,
c.inner.val, is an ordinary one.
```landin
process: (source: []u8, inout target: []u8, sink owned: buffer)
         -> (written: u32) =
    written = 0
end process

```

### [0910] sink takes a place

sink takes a place, and a field of a binding is a place,
so releasing a container's storage needs no ceremony. The
path has to be rooted in a binding and contain no
dereference and no computed index, which is the line where
the analysis is still provable: two pointers may name one
place, so p.val.items is refused, and a computed index
names none in particular, so xs[i].items is too.
A place that was sunk is dead. Reading it before it is
assigned again is an error, and that is what closes the
window between releasing storage and repointing the field
— the window a temporary binding would have left open.
Say plainly what this is and is not. It is a
use-after-consume check on one place. It is not ownership:
the value is copyable, so a copy made before the sink is
refused nothing, and consuming through both is not caught.
Making it ownership means values that cannot be copied.
Affine values remain parked with their resource-prototype
trigger in ROADMAP.md's inherited review register.
A place sunk out of an inout parameter must be assigned
again before the function returns, or the caller would get
its struct back with a dead field and nobody tracking it.
That is [0930]'s rule for named returns, applied to fields.
```landin
release: (T: type, A: type is allocator, inout l: list(T), inout a: A)
         -> none =
    mem.drop_slice(a, l.items)     -- l.items is dead from here
    l.items = []                   -- and live again from here
    l.len   = 0
end release

```

### [0920] Multiple named returns

Multiple named returns.
```landin
divide: (a: i32, b: i32) -> (quot: i32, rem: i32) =
    quot = a / b
    rem  = a % b
end divide

```

### [0930] Every named return must be assigned before return

Every named return must be assigned before return. On the
fail path they need not be, and the caller may not read them.

### [0940] Errors: a declared set of atoms in one dedicated register

Errors: a declared set of atoms in one dedicated register.
```landin
open_file: (path: utf8) -> (handle: u32) ! not_found | no_access =
    fail no_access when lenof path == 0
    handle = 1
end open_file

```

### [0950] Not everything that goes wrong belongs in that channel

Not everything that goes wrong belongs in that channel,
and the question to ask is whether it can be determined
from what you already hold. A syntax mistake is entirely
in the bytes the parser is looking at, so it is checked,
reported and recovered from — a parser that stops at the
first mistake hides the other twelve. Out of memory, a
file that is not there, a device someone unplugged hang on
the world instead of on your data, and checking first
would only be a race, so those are what fail is for.
Put briefly: check what you can foresee, and where you can
foresee it, prefer working around it to reporting it.
fail is for what cannot be foreseen or cannot be dealt
with where it happens.
Reporting needs somewhere to report to, and that is an
ordinary parameter. A diagnostics sink is a capability by
[1680]: a function that was given none cannot report, which
is enforced by an argument list and nothing else.
```landin
parse: (src: utf8, inout d: diagnostics)
       -> (tree: ptr node) ! out_of_memory | too_deep = ... end

```

### [0960] Propagating: try, visible at the call site

Propagating: try, visible at the call site.
'...' means: plus whatever my callees can fail with. Not
allowed where the set must be concrete: function pointers,
concept entries [1260], anything exported to C — and
anything public. A public signature is a promise, and one
that a change three modules down can rewrite silently is
not a promise. Inside a module, where the compiler sees
every caller anyway, '...' is a convenience and stays.
```landin
read_config: (path: utf8) -> (data: []u8) ! ... =
    h := try open_file(path)
    data = []
end read_config

```

### [0970] Early exit

Early exit: return and fail, each with an optional
'when <condition>'.

### [0980] Calls: positional first, then named

Calls: positional first, then named. No default values.
```landin
r1 := divide(10, 3)
r2 := process(source: src, target: dst, owned: buf)

```

### [0990] A return list is an anonymous struct

A return list is an anonymous struct, so a result can be
bound whole and read by field, or destructured. Binding by
name, never by position.
```landin
whole       := divide(10, 3)
sum         := whole.quot + whole.rem
(quot, rem) := divide(10, 3)
(quot: q2)  := divide(20, 3)
(quot, _)   := divide(30, 3)

```

### [1000] A function type is an ordinary type

A function type is an ordinary type, and a function is an
ordinary value of it, represented as a code address. There
is no separate function-pointer type and addr is not used
on functions: the type is written the way the signature is.
```landin
handler: type = () -> none
mut current: handler = default_handler

```
A callback is therefore a pair of that and a state pointer,
written out because nothing is captured.
```landin
on_byte: type = struct
    call:  (state: ptr u8, b: u8) -> none
    state: ptr u8
end on_byte

```

### [1010] Anonymous functions

Anonymous functions. No capture: they see only their
parameters. State travels as an explicit parameter.
```landin
less_i32 := (a: i32, b: i32) -> (yes: bool) = a < b end

```

### [1020] Discarding a result must be explicit

Discarding a result must be explicit.
```landin
_ = double(5)

```

### [1030] Handling

Handling, not just propagating: an else clause on the call,
binding the error atom. It either yields a value or leaves
the function. try is sugar for the second line.
```landin
h1 := open_file(path) else 0
h2 := open_file(path) else (e) fail e end
h3 := open_file(path) else (e)
    match e
        not_found: create(path)
        _:         fail e
    end match
end open_file
```
The else clause yields a value, or transfers control out of
the block that encloses it: return, fail, break, continue.
That is the same rule an if-expression arm follows, so an
arm that leaves needs no value and nobody has to invent a
placeholder to satisfy the type.
It does not assign to the binding it is initialising, which
would need a rule about writing an immutable binding inside
its own initialiser.
Being an expression, it also works in argument position:
```landin
use(read_config(path) else (e) default_config() end)
```
A call that can fail and whose result is discarded is an
error. Write 'try f()' or discard through an else.
else is for the error channel only, not for unions.

### [1040] A caller parameter is filled in by the compiler with the

A caller parameter is filled in by the compiler with the
site of the call, so assertions and logging work without
macros. It may only be passed on from another caller
parameter, otherwise a wrapper would report itself.
```landin
site: type = distinct u32

assert: (cond: bool, caller where: site) -> none =
    if not cond then
        panic_handler(assertion, where)
    end if
end assert
```
used as: assert(count > 0)

## CONTROL FLOW

```landin
demo_flow: (x: i32, items: []i32) -> (out: i32) =
    out = 0

```

### [1050] Branch

Branch. 'then' closes the condition, which must be bool.
```landin
    if x > 0 then
        out = 1
    elsif x < 0 then
        out = -1
    else
        out = 0
    end if

```

### [1060] Every construct has a one-line form

Every construct has a one-line form. No newline is ever
required; 'end' closes.
```landin
    if x > 0 then out = 1 end if

```

### [1070] A declaration is allowed in a condition

A declaration is allowed in a condition. It is a plain
type error unless it is bool.
```landin
    if ok := is_ready() then
        out = 1
    end if

```

### [1080] A block has the value of its last expression

A block has the value of its last expression, and that
is the whole rule: if, match, else clauses, bare blocks
and loops are expressions wherever one is wanted.
Rust needs a semicolon to decide whether the last line
is the value; here discarding is already explicit with
'_ =', so a bare expression at the end is unambiguous.
```landin
    sign := if x > 0 then 1 else -1 end if

    doubled := begin
        a := expensive()
        a * 2
    end

```

### [1090] Bare block, for scoping

Bare block, for scoping.
```landin
    scope: begin
        tmp := x * 2
        out = out + tmp
    end scope

```

### [1100] defer runs at the end of its block, in reverse order

defer runs at the end of its block, in reverse order.
The call is evaluated where it runs, not where it was
written: it names places, and reads them then. So a
defer that sinks something sinks it at the end, which
is why the thing stays usable in between — and if a
named place has been re-pointed by then, the defer sees
what is there now. Registering one costs nothing and
reserves nothing.
```landin
    defer cleanup()

```

### [1110] undo is the same machinery under a condition

undo is the same machinery under a condition. It is
registered when control reaches it, runs in reverse
order at the end of its block, and runs only if the
block is left by fail — which includes a try that
propagates and a fail arriving from deeper in. Not on
return, not on break, and not on a panic, since panics
do not unwind.
It is its own word rather than a flavour of defer,
because it is not the same thing: to defer is to do it
later, and this may never be done at all. English
calls it a contingency, or a compensating action.
```landin
    undo release(handle)

```

### [1120] Checks may be switched off for a region, visibly

Checks may be switched off for a region, visibly.
```landin
    unchecked begin
        out = out + items[0]
    end unchecked

```

### [1130] Unconditional loop

Unconditional loop.
```landin
    counter: loop do
        break when x == 0
    end counter

```

### [1140] Conditional loop

Conditional loop.
```landin
    mut i: u32 = 0
    while i < 10 do
        inc i
        continue when i == 3
    end while

```

### [1150] Traversal

Traversal. Bindings default to in; inout implies mut.
```landin
    for item in items do
        out += item
    end for

    for item, idx in items do
        item = item + i32(idx)      -- items is []mut i32, so this writes
    end for

    for k in 0..<10 do
        out += k
    end for

```

### [1160] There is no marker on a loop binding

There is no marker on a loop binding, because the type
already decided: over a []mut T an element is a writable
place, over a []T it is not. Over anything else that
satisfies iterable the binding is a copy, since item at
[1320] hands out a value — so assigning to it is an error
rather than a silent write to nothing.
```landin
    xs := vec.used(l)               -- []mut i32
    for k in 0..<lenof xs do
        xs[k] = xs[k] * 2
    end for

```

### [1170] complete runs when the loop finished without break

complete runs when the loop finished without break.
```landin
    for item in items do
        break when item == 42
    complete
        out = -1
    end for

```

### [1180] Labels use the ordinary name form

Labels use the ordinary name form, on loops and bare
blocks only. break and continue take one.
```landin
    outer: for a in items do
        for b in items do
            break outer when a == b
        end for
    end outer

```

### [1190] break carries a value with 'with'

break carries a value with 'with', which is what makes a
search an expression instead of a mutable variable and a
flag. Every break of a loop used as an expression must
yield the same type, and complete supplies the value for
running out; loop do needs none, having no other exit.
'with' is required because a bare identifier after break
could otherwise be either a label or a value.
```landin
    found := for item in items do
        break with item when item > 40
    complete
        break with 0
    end for
    out += found
end demo_flow

```

### [1200] Because entries are registered where control reaches

Because entries are registered where control reaches
them, the triangular cleanup of several fallible
acquisitions falls out of the order instead of being
written: the first failing frees nothing, the second
frees one, the third frees two.
```landin
grow: (K: type, V: type, A: type is allocator,
       inout m: map(K, V), inout a: A, want: usize)
      -> none ! out_of_memory =
    ns := try mem.new_slice(T: slot, a: a, n: want)
    undo mem.drop_slice(a, ns)

    nk := try mem.new_slice(T: K, a: a, n: want)
    undo mem.drop_slice(a, nk)

    m.state = ns          -- committed from here, and nothing
    m.keys  = nk          -- fallible follows
end grow
```
And the discipline it asks for, which has to be said out
loud: undo cleans up what is still yours. Once a resource
has been handed on, its cleanup is somebody else's, but
the entry is still registered. So acquire everything
fallible first, commit afterwards, and let nothing
fallible stand between the commit and the end of the
block. Where that order cannot be had, the entry would
have to be called off, and there is deliberately no way to
do that — a construct for calling one off turned out to be
bookkeeping for a question the block's exit already
answers.
The pattern this replaces is a flag and a conditional
defer. That is linear rather than quadratic, so it was
never about the number of lines. It is that forgetting to
set a flag frees storage that is still in use, and under
an arena, where free does nothing, the mistake is silent
until somebody runs the same container on a real
allocator.

### [1210] Pattern matching

Pattern matching: constant patterns, case patterns with
binding, and the wildcard. No fallthrough; list several
labels instead. A missing case is a compile error.
```landin
area: (f: figure) -> (a: f32) =
    a = 0.0
    match f.kind
        circle (radius):
            a = 3.14159 * radius * radius
        rectangle (width, height):
            a = width * height
    end match
end area

```

### [1220] A pattern binding carries a parameter convention

A pattern binding carries a parameter convention: in by
default, inout to write into the payload that was matched.
Nothing new is needed, because the conventions of [0900] are
already the mechanism — and without them a [N]T payload
would be copied in order to be read and could not be
written at all.
An inout binding borrows the matched value for the arm, by
the rule at [0830]. So an arm may assign to the variant
field it was bound out of, but only once the binding has
had its last use, exactly as any other borrow ends.
```landin
spill: (inout s: store, v: i32) -> none =
    match s.kind
        inline (inout buf): buf[0] = v
        spilled (heap):     use(heap)
    end match
end spill

describe: (c: compass) -> (name: utf8) =
    match c
        north, south: name = "along"
        _:            name = "across"
    end match
end describe

```

## CONCEPTS AND GENERIC CODE

### [1230] A concept names a bundle of requirements on a type

A concept names a bundle of requirements on a type.
```landin
ordered: type = concept (T: type)
    less: (a: T, b: T) -> (yes: bool)
end ordered

```

### [1240] A conformance registers one type against one concept

A conformance registers one type against one concept.
```landin
i32 is ordered (less: less_i32)

```

### [1250] A conformance for a parameterised type binds its variables

A conformance for a parameterised type binds its variables
in front, because the conformance holds for every one of
them. The binder is an ordinary parameter list — the same
form functions take and the same form a parameterised type
takes — so a variable may carry a constraint, and a fixed
value parameter may appear among them.
```landin
(T: type) list(T) is iterable (Cur: usize, Item: T,
                               first: list_first, at_end: list_at_end,
                               item:  list_item,  next:   list_next)

(A: type is allocator) counted(A) is allocator
    (alloc: counted_alloc, free: counted_free)
```
The functions supplying the entries are generic themselves.
Instantiating the conformance supplies their type argument
and leaves a function of exactly the concept's shape, so
nothing beyond the binder is needed.
Free variables are never quantified by inference. A name
that is not in scope is a misspelling, not a new variable,
which is the rule build options already follow at [1530].
Without this there is no generic container that can be
traversed, sorted or handed to any other generic code.

### [1260] A concept entry's error set has to be concrete

A concept entry's error set has to be concrete. The entry
is reached through a table, [0960] forbids an inferred set
there, and so a concept fixes the error set once for every
type that will ever satisfy it. That is right for
allocation — out of memory is out of memory — but it is a
constraint on how concepts are designed, not a detail.
The same holds one level up, for what an implementation may
ask for. A concept with no allocator among its parameters
means no implementation of it can allocate, however much
one of them would like to. Resist widening the concept
until it fits the hungriest: that hands every
implementation the sum of everyone's needs. Either the
hungry one picks a shape that does not need it, or there
are two concepts.

### [1270] The register is keyed by (type

The register is keyed by (type, concept, input types), so a
type may satisfy the same concept more than once. Which
concepts exist, and how finely they distinguish what an
operation costs, is the standard library's business. The
language checks nothing about cost and knows no vocabulary
for it: a guarantee should not depend on how clever the
compiler happens to be.
```landin
indexable: type = concept (T: type, Idx: type, Item: type)
    get: (s: T, i: Idx) -> (item: Item)
end indexable

utf8 is indexable (Idx: u32,      Item: []u8, get: utf8_nth)
utf8 is indexable (Idx: position, Item: []u8, get: utf8_at_pos)

```

### [1280] Conformances may be declared anywhere

Conformances may be declared anywhere, and two for the
same key are simply an error. There is no precedence, no
orphan rule and no override: until a rule turns up that is
worth its weight, the compiler reports the collision and
somebody sorts it out. A wrapper through distinct, or
passing the functions explicitly at the call, both work
without anyone changing anyone else's library.
The alternative that was tried and dropped had libraries
declare weak conformances and applications override them
with strong ones. It worked, but it meant an application
could quietly change the behaviour of generic code inside
a library, which is a strange thing for a language whose
whole point is that costs and effects are visible.

### [1290] A generic function takes the type as an ordinary parameter

A generic function takes the type as an ordinary parameter,
constrained by 'is'. Type and fixed parameters are
compile-time, and their order in the list does not matter:
a parameter may be used in the type of one that comes
before it, exactly as declarations inside a module may.
The compiler collects the names first and resolves the
types afterwards, so
  report: (inout d: sink(N), N: fixed u32, ...)
is as good as putting N first, and at the call site N is
deduced from whatever argument pins it down.
Concept entries are reached through the type parameter, so
two constrained parameters never collide: A.less, B.less.
```landin
sort: (T: type is ordered, data: []mut T) -> none =
    for k in 1..<lenof data do
        mut j := k
        while j > 0 and T.less(data[j], data[j - 1]) do
            tmp        := data[j]
            data[j]     = data[j - 1]
            data[j - 1] = tmp
            dec j
        end while
    end for
end sort

```

### [1300] At the call site the type is inferred from the arguments

At the call site the type is inferred from the arguments.
Naming it explicitly stays possible.
```landin
sort_demo: (values: []i32) -> none =
    sort(values)
    sort(T: i32, data: values)
end sort_demo

```

### [1310] Generic code can always be compiled once and handed a table

Generic code can always be compiled once and handed a table
of the concept's functions. That table is the foundation,
because 'any' needs it and so do calls through function
pointers. Everywhere the concrete type is known, the
compiler weighs specialising against it: loop depth at the
call, how many concept entries the body calls, and the size
of the type on the one side, code size on the other. With a
single instantiation it always specialises, since the table
version then becomes dead. Optimising for size raises the
bar, optimising for speed lowers it, and identical machine
code from different types is folded into one copy. The
build report lists what was specialised and what was not.
The evidence is not only the concept's functions. It
carries the size and the alignment of the type as well,
because sizeof T and alignof T are constants only where
the call was specialised, and a generic container that
cannot ask how big its element is cannot allocate.

### [1320] Traversal is a concept

Traversal is a concept. This is what 'for x in s' uses.
```landin
iterable: type = concept (T: type, Cur: type, Item: type)
    first:  (s: T) -> (c: Cur)
    at_end: (s: T, c: Cur) -> (yes: bool)
    item:   (s: T, c: Cur) -> (v: Item)
    next:   (s: T, c: Cur) -> (c2: Cur)
end iterable

```

### [1330] A range is not a concept

A range is not a concept. '0..<10' builds an ordinary value
from core that satisfies iterable, and the spelling is
built in for integer-like types only. Anything else a type
wants to be traversed by, it satisfies iterable for. Custom
stepping is a library call, so the step is visible where it
is used rather than hidden in a type.
```landin
step_range: type (T: type) = struct
    low:  T
    high: T
    by:   T
end step_range

step: (T: type, low: T, high: T, by: T) -> (r: step_range(T)) = ... end
```
used as: for i in step(0, 10, 2) do ... end for

### [1340] Concepts compose

Concepts compose. A combined concept is named, so a table
is generated per (type, concept) and the value stays two
words. Conformance is declared explicitly, even when the
body is empty.
```landin
drawable: type = concept (T: type)
    draw: (self: ptr T, target: ptr mut canvas) -> none
end drawable

clickable: type = concept (T: type)
    click: (self: ptr mut T, x: u32, y: u32) -> none
end clickable

widget: type = concept (T: type) is drawable, clickable
    focus: (self: ptr mut T) -> none
end widget

button is drawable  (draw:  button_draw)
button is clickable (click: button_click)
button is widget    (focus: button_focus)
```
All three, because the composed declaration supplies only
what it adds. Nothing is inherited by having the parts.

### [1350] Types take parameters through a declaration form of their

Types take parameters through a declaration form of their
own, not through a function that returns a type — that
would be the compile-time evaluation this language does not
have. Substitution, not execution.
```landin
list: type (T: type) = struct
    items: []T
    len:   usize
end list

```
The parameter list is the same one everywhere: a variable
may be constrained, and a fixed value parameter may stand
among the type parameters.
```landin
map: type (K: type is hashable, V: type) = struct ... end map
small: type (T: type is zeroable, fixed N: u32) = struct ... end small

```

### [1360] Allocation is an ordinary concept

Allocation is an ordinary concept, so the same container
runs on the heap, in an arena, or on a fixed buffer with no
dynamic allocation at all. A failing allocator makes the
out-of-memory paths testable, which almost nobody bothers
with in C because it is too awkward.
```landin
allocator: type = concept (A: type)
    alloc: (inout a: A, size: usize, alignment: usize)
           -> (p: ptr mut u8) ! out_of_memory
    free:  (inout a: A, p: ptr mut u8, size: usize) -> none
end allocator

push: (T: type, A: type is allocator, inout l: list(T), inout a: A, v: T)
      -> none ! out_of_memory = ... end
```
The allocator is threaded, not stored in the container, and
the reason is stronger than visibility: a stored allocator
makes the type list(T, A), so a list in an arena and a list
on the heap become different types and no function takes
both. Threading keeps the type parameterised by T alone,
and costs one argument at every call that can allocate.

## RUNTIME DISPATCH

### [1370] 'any C' is a value of some type satisfying concept C

'any C' is a value of some type satisfying concept C,
decided at run time: a data pointer plus a concept table,
two words. That pair is an ordinary copyable value and can
sit in a variable, a field or a slice. What it points at is
never copied, because its size is unknown; the pointee has
to live somewhere the pair outlives, typically an arena.
The pair needs no permission marker of its own: the
concept's entries already carry it. An entry declared with
'self: ptr mut T' can only be satisfied by a pointer that
has the permission, so a stateful implementation behind
runtime dispatch works and nothing had to be invented for
it.
What the pair does carry is the origin of the pointee for
[0840], so an 'any' over something with frame origin cannot
be put in a list that outlives the frame.

### [1380] Building one is explicit

Building one is explicit. The concept comes from context
where it can; otherwise name it.
```landin
screen: (a: arena) -> (items: []any widget) ! out_of_memory =
    b := try mem.new(T: button, a: a)
    b.val = button(text: "OK")

    items = try mem.new_slice(T: any widget, a: a, n: 1)
    items[0] = any(b)
end screen

```

### [1390] Calls go through the table

Calls go through the table, with the data pointer as the
first argument. This is the only place that reads like a
method call.
```landin
paint: (items: []any widget, target: ptr canvas) -> none =
    for w in items do
        w.draw(target)
    end for
end paint

```

### [1400] This is what generics cannot do

This is what generics cannot do: one array holding values
of different types. []T is always one T.

## MODULES

### [1410] A module is a directory

A module is a directory. Every file in it sees the others
with no import. Two levels of visibility: module-internal
(the default) and public. No separate interface file.

### [1420] An import path is a directory path, and nothing cleverer

An import path is a directory path, and nothing cleverer.
'import net/http' looks for a directory net holding a
directory http, under each of the import roots the compiler
was given, in order, and takes the first that has it. From
that directory it takes every source file — not
recursively — and follows their imports in turn. A
subdirectory is a module of its own, reached by its own
path. What is bound is the last segment.
Which is why a segment has to be a plain identifier:
lowercase letters, digits and underscore, not starting with
a digit. Lowercase because a case-sensitive and a
case-insensitive filesystem must both agree on what a name
is; an identifier because the last segment becomes a name
in the importing file, so a hyphen would need an alias
every time. Nothing else — no dots, no spaces, no case, no
characters that some filesystem somewhere will not carry.
The separator in source is always '/', on every host. The
compiler turns it into whatever the filesystem wants.
```landin
import net/http

```

### [1430] Alias, for collisions

Alias, for collisions.
```landin
import net/http as h

```

### [1440] Pull selected names into scope, by name

Pull selected names into scope, by name. No wildcard.
```landin
import net/http (get, post)

```

### [1450] Imports are per file, so every file reads on its own

Imports are per file, so every file reads on its own.

### [1460] Values at module level must be known at compile time

Values at module level must be known at compile time.
Nothing runs before the entry point. Immutable ones can
stay in flash; mutable ones cost RAM and are conspicuous.
```landin
table: [4]u32 = [1, 2, 4, 8]
mut call_count: u32 = 0

```

### [1470] A package is a named collection of modules with a version

A package is a named collection of modules with a version
and an origin. Names have two levels, owner and package,
and a directory under a search root is the package it names.
Exactly one version of a package name exists in a program:
duplicated code is untenable at 32KB, the types are
nominal, and there is one conformance register. A version
conflict is therefore a hard error and somebody upgrades.

### [1480] The roots are the project

The roots are the project, then the user's landin home,
then the system-wide one, and vendoring is just the first
of those. Whether the leading segments of a path mean an
owner and a package is a convention for people and for the
companion tool; the compiler sees directories under roots,
as [1420] says, and nothing else.
So it receives an ordered list of roots and no more than
that. Fetching, version solving, lock files and naming
authority all live in a companion tool that ships
alongside but stays separable — a compiler you can read is
worth more than one that can download things. Arranging
the roots so that only one version of anything is
reachable is that tool's job, which is what makes [1470]'s
one-version rule keepable.
core and landin are reserved, and both are used. core is
the standard library: core/mem, core/text, core/vec. landin
holds the toolchain modules of [1560] — landin/compiler,
landin/assembler, landin/linker — which are available
without an import, and that is why the bare names
compiler, assembler and linker are taken.
Naming authority remains deliberately deferred to the companion
tool and ecosystem successor in ROADMAP.md. The search path is
project-first, so any collision can be overridden locally and
no dispute is fatal.

## COMPILE TIME

### [1490] 'fixed' marks what is known at compile time

'fixed' marks what is known at compile time.

### [1500] Conditional compilation

Conditional compilation.
```landin
fixed if compiler.arch == arm64 then
    word_bits: u32 = 64
elsif compiler.arch == cortex_m0 then
    word_bits: u32 = 32
end if

```

### [1510] Compile-time assertion

Compile-time assertion. Not a keyword: it is a builtin
call like the rest of [1560], because the compiler is what
has to know it, and that leaves the word 'assert' to the
library function at [1040] where it belongs.
```landin
compiler.assert(sizeof usize == 8)

```

### [1520] A compile-time value parameter

A compile-time value parameter.
```landin
make_buffer: (fixed N: u32, T: type) -> (b: [N]T) = ... end

```

### [1530] Your own build switches

Your own build switches. Declared, typed, with a default,
settable from the build description. A misspelt name is a
compile error, never a silent false. Names are global, so
each is declared exactly once.
```landin
option log_level: u32 = 0

```

### [1540] There are no compile-time loops and no compile-time

There are no compile-time loops and no compile-time
function calls. That line is deliberate.
The builtin modules at [1560] look like an exception and are
not one: their calls are directives to the compiler, the
assembler and the linker, they take only fixed arguments,
and nobody can write another. Nothing of yours runs while
the program is being built. What that costs is a generated
table or an SoA layout, which comes from a program that
writes source and is run by the build — twice so far, and a
third would be worth taking seriously.

## THE TOOLCHAIN, C, AND THE MACHINE

### [1550] Landin has its own native backends

Landin has its own native backends. A verified,
target-neutral intermediate representation takes QBE's IL as a
design influence without freezing one flat or serialised stage
shape before implementation evidence exists. The compiler emits
deterministic assembly text and relies on the assembler and
linker of the platform. Linux x86-64 comes first, native macOS
arm64 second, and emulator-first Cortex-M third. The frame
pointer is always set up. The whole program is compiled together
[1480], with optional private caches that do not create a stable
separate-compilation interface.
Not LLVM and not C: LLVM is a dependency larger than the
language and C loses the calling convention, the traps and the
debug information that the design spends its precision on. The
cost is owned deliberately — every target is work that nobody
else does.

### [1560] Three builtin modules are the way to the tools

Three builtin modules are the way to the tools. They are
modules of the reserved landin package — landin/compiler
and its siblings — and are in scope without an import,
which is why their bare names are not available to anyone
else.
| module | what it reaches |
|---|---|
| `compiler` | target, word size, byte order, build mode, and the atomic and vector intrinsics |
| `assembler` | inline assembly |
| `linker` | libraries, sections, entry |

Their calls are builtin, take only fixed arguments, and
cannot be written by hand.
Where the line runs: something is builtin when the compiler
has to know it. Atomics are, because opaque assembly in a
hot loop wrecks the register allocation around it. Masking
interrupts is not, because being opaque is exactly right
there — a critical section wants nothing reordered across
it. So cpu.disable_interrupts and its kin are an ordinary
core module per target, written with assembler.block behind
a fixed if and inlined, not a fourth builtin module whose
contents would change with the target.
If one of them later turns out to exist on every target
and mean the same thing everywhere, the way the atomics and
the vector operations do, it can be promoted into compiler
then. The rule decides it, not a list.

### [1570] Calling conventions are a growing set of atoms behind one

Calling conventions are a growing set of atoms behind one
spelling rather than a keyword each: extern(c) today,
extern(interrupt) for handlers whose entry, exit and vector
placement differ, extern(naked) for no prologue at all, and
room for extern(aapcs), extern(sysv), extern(win64) later.
The ones worth real work eventually are Fortran, whose ABI
is trivial and whose numeric libraries are everywhere, and
Swift, which puts its error in a register of its own just
as Landin does. Zig, Odin, Rust and Python all speak C, so
there is nothing to gain there.

### [1580] Importing from C

Importing from C. Declarations are written by hand; no
header is ever read.
A C pointer may be null and a Landin pointer may not, so the
two are not the same type and a declaration says which it
means. malloc returns something that may be nothing, which
is the union of [0480] and costs no bits.
```landin
none_returned: atom
extern(c) malloc: (n: usize) -> (p: none_returned | ptr mut u8)
extern(c) free:   (p: ptr mut u8) -> none
```
ptr(0) is refused, so null cannot be minted on this side
either. Where a foreign interface hands back a pointer that
may be null, it is declared as the union and matched on; the
compiler represents that as the plain pointer it already
was.

### [1590] Linking a static library

Linking a static library, next to the declarations that
need it rather than in a separate build file.
```landin
linker.library("m")

```

### [1600] Exporting to C

Exporting to C. No error channel crosses the boundary, so
the error set must be empty.
```landin
public extern(c) my_add: (a: i32, b: i32) -> (r: i32) =
    r = a + b
end my_add

```

### [1610] A symbol name the language's identifiers cannot spell

A symbol name the language's identifiers cannot spell.
```landin
link(symbol: "__aeabi_uidiv") udiv: (a: u32, b: u32) -> (q: u32) = ... end

```

### [1620] Atomics are builtins

Atomics are builtins, not assembly, so the compiler knows
which memory they touch and can still allocate registers
around them. The ordering is a compile-time atom. The
standard library wraps these into a pleasant type.
```landin
bump: (p: ptr u32) -> none =
    _ = compiler.atomic_add(p, 1, acq_rel)
end bump

```

### [1630] Inline assembly, for what has no builtin

Inline assembly, for what has no builtin. Opaque to the
compiler, which therefore assumes it may touch any memory
and must not be reordered.
```landin
extern(naked) reset_handler: () -> none =
    assembler.block("""
        ldr r0, =_stack_top
        mov sp, r0
        bl  start
        """)
end reset_handler
```
'start' and not 'main': freestanding there is no main, and
the build description names the entry [1650].

### [1640] Kept against section garbage collection, and placed

Kept against section garbage collection, and placed. The
table is a struct, not an array of addresses: a function
type is an ordinary type [1000], so a handler is written as
one, and the first word is a stack pointer rather than a
handler at all. 'handler' is the function type from [1000].
```landin
vector_table: type = layout(c) struct
    stack_top: usize
    reset:     handler
    rest:      [46]handler
end vector_table

link(section: ".isr_vector", keep)
vectors: vector_table = (
    stack_top: stack_top_address,
    reset:     start,
    rest:      [of default_handler]
)
```
Being reachable from something kept is what keeps a
handler. The table carries keep and names them, so they
survive by being named. extern(interrupt) does not imply
it and should not: a calling convention is what the
program means, keep is an instruction to the toolchain,
and [0760] separated those two on purpose.

### [1650] Entry point

Entry point. Hosted, main follows the system C ABI. The
no-argument form is the ordinary one, because argc and argv
in the C shape cannot be indexed without slice_from, which
is core's by [0500] — so the arguments come from core as a
slice instead. The C form stays available for whoever wants
it. Freestanding there is no main; the build description
names the entry.

### [1660] And this is where capabilities come from

And this is where capabilities come from. Everything below
is handed what it may do — an allocator, an Io, a
diagnostics log — and the entry point is the one place
where a root is minted rather than passed. So the whole of
main is an argument list being filled.
```landin
public main: () -> (code: i32) =
    args := io.args()           -- []cstring, from core
    mut h := io.host()          -- out of nothing, once, here
    mut w := any(addr h)
    arena program do
        mut logger := diag.to(w.err())
        mut d := any(addr logger)
        code = run(w, program, d, args) else 1
    end program
end main
```
Which is what makes the same run testable and portable
without it knowing: hand it a different root and it does
not learn the difference.
```landin
test_drops_debug: () -> none =
    mut h := io.in_memory([(name: "in.log", body: "DEBUG a\nERROR b\n")])
    mut w := any(addr h)
    arena scratch do
        mut logger := diag.new_log(N: 32)
        mut d := any(addr logger)
        kept := run(w, scratch, d, []) else 0
        assert(kept == 1)
    end scratch
end test_drops_debug
```
For that to work at all, Io has to be a concept and not a
type, so something else can satisfy it. It travels as
'any io' rather than as a type parameter: an indirect call
in front of a system call costs nothing, where an allocator
is threaded generically because it sits in hot loops. Same
machinery, [1690], chosen per case.

### [1670] A failed check calls a fixed, never-returning symbol

A failed check calls a fixed, never-returning symbol.
Two scalars, no strings: 'site' is a number the compiler
assigns per check, and the file and line for it live in a
side table that constrained builds simply omit.
```landin
panic_kind: type = out_of_range | overflow | bad_conversion | unreachable

public panic_handler: (kind: panic_kind, site: u32) -> noreturn =
    loop do
    end loop
end panic_handler

```

## THE PRINCIPLES BEHIND THE DECISIONS

### [1680] Require a capability, do not track an effect

Require a capability, do not track an effect.
Where another language would record in a type that a
function performs input and output, allocates, or reads the
clock, Landin makes it take the thing: an allocator, an Io,
a peripheral handle, a random source. This is why there is
no effect system and why there does not need to be one.
Said exactly, because the obvious wording claims more than
is true. A function below a root can do only what it was
given, and the argument list is the whole enforcement. The
roots are where authority is minted rather than passed, and
there are two, both nameable: the entry point, where the
host capability comes from [1660], and an address literal
in a driver, where a peripheral does [0460]. Nothing stops
an ordinary function reaching for either. So between the
roots it is enforced, and at them it is a habit.
Restricting the first to the entry module would be cheap,
and would turn "this subtree cannot touch the world" from a
habit into a checkable claim. It would not close the
second, because a driver has to be able to write
ptr(0x4002_0000). That asymmetry is why this is stated
rather than enforced — and it is a tightening available
later rather than a repair that is owed.

### [1690] One mechanism, two readings, is better than two mechanisms

One mechanism, two readings, is better than two mechanisms.
Generic code is a value plus evidence that its type
satisfies a concept. When the compiler knows the type it
can specialise and the evidence disappears; when it does
not, the evidence is carried and the type is erased, and
that is exactly what 'any C' is. Static generics and
runtime dispatch are one thing seen from two sides, not
two features.

### [1700] Atoms are the same idea wherever they appear

Atoms are the same idea wherever they appear: identity
without payload. Enumerations, error sets, variant tags,
register encodings and panic kinds are uses of atoms, not
separate categories. There is no 'enum' in the language
because there is nothing left for it to be.

### [1710] How a new feature earns its place

How a new feature earns its place. When a program cannot
be written cleanly, in order:
| ask, in order | then |
|---|---|
| can an existing mechanism express it? | a library |
| can the compiler work it out itself? | no syntax |
| must the programmer say it, and does saying it generalise or remove another mechanism? | a candidate |
| does it only solve this one case? | not yet |

A new mechanism should let two old ones leave the building.

### [1720] What the language claims, at this version, plainly

What the language claims, at this version, plainly. It
performs local checks: origins and escape, consumption
[0910], reference permission [0430], bounds, conversions and
arithmetic. It is not a memory-safe language and not a
resource-safe one. Pointer-to-integer conversion and the C
boundary leave the checked model altogether [0470], a copy
taken before a sink is refused nothing [0910], and two
arenas are indistinguishable [0860].
That is a smaller claim than 'safe' and a larger one than
C's. The table that lets a reader see exactly which operation
falls where does not exist yet; ROADMAP.md grows it alongside
executable cases at R2.90 and closes the matrix at R7.40.
Until then, read the claim as: deliberately unsafe, with
static help that is worth having.
Checks stay on by default. unchecked exists in the design
[1120] and is not implemented first, because defining what
an optimiser may then assume is a decision that should wait
for a compiler that can be measured.

### [1730] Check once, then carry the proof

Check once, then carry the proof. A successful test yields
a value that stands for what was checked — a buffer that
passed the alignment test becomes a dma_buffer, and the
DMA interface asks for nothing else. distinct types, range
subtypes and error sets are enough to do this; it needs no
feature of its own, only the habit.

## WHAT LANDIN DELIBERATELY DOES NOT HAVE

no classes, inheritance, methods or runtime type information
no exceptions, no stack unwinding, no catchable panics
no garbage collection and no reference counting
no destructors
no closures that capture
no implicit conversions
no null
no positional tuples: anonymous records with named fields exist
no function name overloading and no multiple dispatch
no user-defined operators and no macros
no compile-time execution
no separate interface files
no header parsing

## WHAT IS STILL OPEN

ROADMAP.md, and not a second list here. `spec.md` is the normative
authority for language semantics and this file explains them; ROADMAP.md
is the sole durable
authority for open work, implementation dependencies, phase gates,
dispositions and completion evidence. Every inherited item is traced to
the construct, prototype finding or archived review section it came from.

The bootstrap compiler now exists. R0's Ada chassis and R1's executable
kernel are complete: `refine` checks and lowers a program, emits Linux x86-64
assembly, and can assemble and link a hosted executable. R2 is settling the
semantic and representation core from executable cases. The first major
compiler milestone is R3, a complete derived parser program with evidence-
table dispatch and `any` but without specialization. Target work continues
through native macOS arm64 and emulator-first Cortex-M.

The endpoint is feature-complete pre-v1. Production status, release
versioning, package acquisition, competitive optimization and
self-hosting are outside this roadmap. A future roadmap may replace
tested Ada stages incrementally; no self-hosting work or serialized
cross-language stage protocol is scheduled now.

## WHAT WAS TRIED AND DROPPED

The revision log this replaces recorded every change across a long
sequence of versions. Most of it was arrival. What is worth carrying
is the other kind of entry: the thing that was designed, sometimes
built, and then taken out again — because a reader who does not know
that will propose it back, and because a design is partly defined by
what it refused.

- an ambient environment, carried in a register, holding the allocator
  and the diagnostics and the Io — Odin's context. Designed in
  full, then removed. Once the argument was that every property it
  needed made it visible anyway, the only thing left was its
  implicit flow, and that was the thing worth losing. It became an
  ordinary parameter and the ABI lost a reserved register [1680].
- compile-time execution, refused twice. It would have given generics,
  macros and configuration from one mechanism, and it costs an
  interpreter inside the compiler. The accepted price is that
  generated tables and vendor bindings come from generator
  programs [1540].
- witness tables as the only story, then monomorphisation as the only
  story: both refused. The table is the foundation and specialising
  is an optimisation weighed per instantiation [1310].
- cost annotations on a conformance, and the concepts that went with
  them. Removed entirely: how finely a concept distinguishes what
  an operation costs is a library's business, and no language
  guarantee should rest on how clever an optimiser happens to be
  [1270].
- a concept for ranges. A range is an ordinary value satisfying
  iterable, and left-exclusive forms went with it [0360].
- a second type with the shape of a fixed array and different
  operator rules. Fixed arrays are the vector type [0590].
- transposed collections, designed and deferred: they touch aliasing,
  generics, slicing, addr, layout, debug information and the
  optimiser at once, and no program has yet needed one [0620].
- weak conformances, built and removed. Libraries would declare
  weakly and applications override strongly, which worked — and
  meant an application could quietly change the behaviour of
  generic code inside a library. A collision is simply an error
  [1280].
- labels on if and match, removed; they earn their place on loops and
  bare blocks only [1180].
- errdefer, refused, and then arrived at from the other side. A
  cancellable defer was tried first and dropped, because the
  cancel always sits where the block succeeds and is hand-made
  bookkeeping for a question the exit already answers. defer with
  an argument was dropped because it reads as a call. What went in
  is undo, its own word, because to defer is to do it later and
  this may never be done at all [1110].
- read-only reference types spelled as a second form of every
  reference — considered twice and refused both times, then
  arrived at anyway from the other end. What was refused was deep
  const with an implicit widening; what went in is permission in
  the type with one stated relaxation, and it removed two
  mechanisms rather than adding one [0430].
- permission derived from where a reference came from, which lasted
  one version. It rescued the register case and could not express
  the commonest signature in a driver, so it was replaced by
  permission in the type [0430].
- inferred derivation for the from clause, refused with a
  counterexample rather than an argument: mechanically an
  allocator's result does come out of the allocator, so inference
  forbids a second live allocation [0790].
- braces, which were never a decision. They crept into two register
  examples and a set literal and were taken out again; the
  language has none [0730].
- a keyword for the compile-time assertion. The collision with the
  ordinary assertion was resolved by subtraction: it is
  compiler.assert now, a builtin call like the rest, and the
  language has one keyword fewer [1510].
- sets as a kind of their own, with a literal, three operators and a
  membership operator, all of which were designed and then not
  needed: set(X) generates a packed struct of bool, so membership
  is a field read [0730].
- affine values, which cannot be copied. Not refused — parked, with
  the condition that would bring them in, and with sink honestly
  described in the meantime as a use-after-consume check on one
  place rather than as ownership [0910].
- async and await, and the stackless coroutines under them, refused
  before either was built. Concurrency is not a property of a
  function here; it is a capability the caller hands down, so the
  same code blocks or does not depending on the Io it was given
  [1660]. One implementation of that Io ships first and it blocks,
  which is a scheduler not yet written rather than a limit in the
  language. Stackless is the refusal proper: cutting a function
  into a state machine is a compiler project of its own, and it
  colours every function type that reaches one — the same
  objection that removed the ambient environment above [1680].
  Stackful fibres are the route to take instead, and the design
  already pays for them: the frame pointer is always present, the
  callee-saved discipline is explicit, and nothing rides in a
  reserved register.

