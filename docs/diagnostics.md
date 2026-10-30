# What each diagnostic means

`refine explain CODE` prints one section of this page. Each section says what
rule the code enforces, cites the paragraph or decision that states it, and
says what to change. It is derived: `spec.md` and `tour.md` decide what a
program means, and the diagnostic catalogue in
`compiler/ada/src/diagnostics/landin-diagnostics-catalogue.ads` decides which
codes exist and what each occurrence must carry. `check.py` holds every
catalogued code to exactly one section here and every citation to a paragraph
or decision that exists, and generates the compiler's copy of this text.

A section's example, where it has one, is a program the code refuses; the
test program compiles it and requires its report to begin with that code. A
code whose diagnostic offers a fix says so. A fix is shown as a `help` line
and handed to an editor as an edit; a likely fix is a guess, an exact one is
what the rule itself requires.

A retired code is never raised. Its section says so and what retired it, so
its number is never read as belonging to another rule.

## Migrating diagnostic consumers

Checker diagnostics now distinguish refusal families that previously shared
L0301, L0305 or L0300. This reclassification does not change which programs
are accepted. Update scripts, editor filters and stored expectations that
match these codes according to the rule they intend to identify:

| Previous code | Rule | Current code |
| --- | --- | --- |
| L0301 | Value type disagreement | L0301 |
| L0301 | Call arguments and static formals | L0327 |
| L0301 | Zero image or zeroed context | L0328 |
| L0301 | Error contract | L0329 |
| L0301 | Assembly block contract | L0330 |
| L0301 | Result use | L0331 |
| L0301 | Control values | L0332 |
| L0301 | Match-arm form | L0333 |
| L0301 | Aggregate form | L0334 |
| L0301 | Pointer-union reads | L0335 |
| L0301 | Packed images | L0336 |
| L0301 | Required places | L0337 |
| L0301 | Type declarations and positions | L0338 |
| L0301 | Signature form | L0339 |
| L0301 | Generic deduction | L0340 |
| L0301 | Concept and conformance form | L0341 |
| L0301 | Erased dispatch contract | L0342 |
| L0301 | Noreturn contract | L0343 |
| L0301 | Memory intrinsics | L0344 |
| L0301 | Machine entries | L0345 |
| L0301 | C boundary | L0346 |
| L0301 | Linkage and placement | L0347 |
| L0301 | Traversal source contract | L0348 |
| L0305 | Invalid option declaration | L0390 |
| L0305 | Invalid tool directive | L0391 |
| L0305 | Fixed-value failure or required function initial image | L0305 |
| L0300 | Known register image violates reserved-bit policy | L0398 |
| L0300 | Numeric or target-width overflow | L0300 |

There is no single replacement or compatibility alias for an old catch-all
code. Use the individual explanations below to select the relevant families.
The reclassified reports retain their messages, source locations and notes.
The named-argument spelling fix follows its report to L0327; an editor should
consume the offered edit rather than assume it belongs to L0301.

## The driver

### L0001

Retired. A source was read and no frontend was wired to the driver. The
frontend has been wired since the first executable slice, so nothing raises
this and the number is kept so no other rule can take it.

### L0002

The command line asked for something the driver does not define: an unknown
option, an option without its value or repeated where it may not be, or a
combination the driver refuses, such as `--emit` with no source, an output
that would overwrite a source or another output, or `refine explain` with a
code no catalogue row holds. `refine --help` lists the options. The status is
2, which says the request and not a program was wrong.

An option that belongs to a command is written after it. One written before
its command, or with no command at all, is refused naming the commands it
belongs to and where it goes, as it was written: `refine --root=lib compile
main.ldn` is told `refine compile --root=lib ...`, and `refine -o x.s
main.ldn` that `-o x.s` is an option of `compile` (D384).

Give `--target=` only once. Repeating it is a misuse even when both names
are the same; the driver does not choose between target selections.

`--toolchain=NAME` and `--linker=NAME` require `--emit=exe`: checking and
assembly emission do not run a linker. They are also incompatible with
`--help` and `--identify`, which do not compile. Each selection must have a
nonempty value and may be given only once.

`--link=static|libc` chooses how a hosted executable is linked, and under
`refine check` which C runtime the program is checked with; `static` needs a
Linux target, and a target with no hosted system takes neither. `check`
takes `--firmware-entry` and `--build-report` as `compile` does, and refuses
an entry that names no firmware routine (D383).

### L0003

A source named on the command line is missing or cannot be read. Check the
path and its permissions.

### L0004

`--target=` names no target the compiler describes, or none was named and
this compiler's own host is not a described target, so a build has nothing
to compile for until one is named. `refine --identify` lists the described
targets.

### L0005

An output file cannot be written, or `refine fmt` cannot rewrite its input.
For emitted output, check that the destination directory exists and is
writable, or choose another path with `-o`.

Formatting writes into the file it read, so it needs a writable ordinary file
and, for the copy of the original it keeps until the new bytes last, write
permission in the file's directory (D358). The diagnostic names what it met:
a read-only file, a directory that refuses the copy, a set-user-ID or
set-group-ID bit the caller could not set again, a Linux file with
capabilities, or a write that failed, and then whether the original bytes
are back or where their copy is kept. `refine fmt --stdout` prints the
layout without writing anything. See [formatter file handling](format.md)
for the full contract.

### L0006

No import root holds the module an import names [1420]. Roots are searched in
the order `--root=` gives them, and a path's segments are directories under a
root, spelled exactly; the note names every directory looked for, in that
order, so `import lexer/lexer` under `--root .` says it looked for
`./lexer/lexer` (D384). When a directory near the missing segment is there, the
diagnostic offers it as a likely fix; named files with no `--root` are offered
the library's `core`, `hosted` or `platform` when the first segment is near
one. An import of `core`, `hosted` or `platform` when `refine` found no
library beside itself, as a copied `refine` does not, names where it looked;
name the library's directory with `--library=DIR` (D363).

### L0007

With `--root=`, the entry module is a readable directory [1410], or the
entry module's own source files, which are then one module as named files
are without a root (D383). A path that is neither is refused. This code also
reports an import root or intermediate directory that cannot be listed while
searching in root order [1420]. Check the named path and its permissions; a
genuinely absent module is reported by L0006.

### L0008

`refine fmt --check` found a line that is not in the layout D252 decides
and `docs/format.md` shows. There is one diagnostic for every such line, and
its note shows the line as the layout writes it, or says that the layout
removes the blank line or changes its line end (D359). A line whose spacing
changes is marked where it differs, from the first byte the layout changes
to the last, and the note names the column it differs from (D385). Nothing is
wrong with the program: run `refine fmt` on the file to put it in the layout,
which changes its space and nothing else, or `refine fmt --stdout` to see the
whole file laid out.

### L0009

`--level=`, or the language server's `level` option, names no CPU feature
level of the selected target's family (D255). A level belongs to one family,
so `armv8.1-a` is refused with `--target=linux-x86-64`, and synthetic-32 has
no level to select. `refine --identify` lists each target's levels.

### L0015

An import names a source namespace unavailable for the selected target (D267).
`hosted/*` requires a hosted target; `platform/c` requires one of the currently
enabled LP64 C ABIs; `platform/cortex_m` requires an M-profile target, including its
higher supported feature levels. Select an applicable target or remove the
import. Project-first root selection cannot change namespace availability.

### L0016

A warning: an import of `core`, `hosted` or `platform` was read from the
compiler's own library, and a `--root=` directory also holds a module at that
path, which was not read (D275, D366). The library always supplies those three
namespaces, so a project's copy of `core` never replaces it. To compile against
that copy instead, name its directory with `--library=DIR`; to silence the
warning, rename or remove the project's directory.

## Lexical, and what is not enabled

### L0010

The program uses a construct the tour describes and the kernel does not enable
yet [1830]. The two notes name the tour paragraph and whether the form is a
recorded boundary, withdrawn with a replacement, or transferred to later work.
Write the program without it, or with what the note says replaces it. A call's
result is no place, so indexing one is a recorded boundary: bind the result to
a name, then index the name.

```landin
point: type = struct
    x: i32
end point

state: point = point(of zeroed)
```

### L0011

An integer literal is malformed if a base prefix has no digits, a digit is not
in its base, an underscore begins or ends the digit run, or the literal runs
straight into a name [1770]. `0x` takes hexadecimal digits, `0b` binary and
`0o` octal. Keep underscores between digits, and put a separator before a
following name.

```landin
mask: u64 = 1u64
```

### L0012

A run of bytes no lexical rule spells [1750]. A name is lower case [1760], and
a byte outside the source alphabet belongs in a text literal.

```landin
X: u32 = 1
```

### L0013

A block comment that is never closed [1780]. Every opener needs its closer;
the second label shows where the comment began.

```landin
--( this one never closes
f: () -> (r: i32) = 1 end
```

### L0014

An ordinary quoted text or character literal must close before its line ends
[0250] [0260]. A raw text literal may span lines [0280]. Its maximal opening
quote run sets the delimiter width; only a later run of at least that many
quotes closes it. A shorter run remains content. Close the ordinary literal
on its line, or add enough closing quotes to the raw literal.

```landin
value := "never closed
unclosed_raw: []u8 = """"never closed"""
```

## The parser

A parser report is about the first mistake on its line and is given once.
When one change of a single token makes the line parse (D261), the report
says what that change is, shows the line as it would read, and offers it as
a fix: a token removed, written, swapped with its neighbour or moved to the
statement's start, or a value written where a line break left one out. The
fix is likely, a guess at what was meant, except removing one copy of a
token written twice, which is exact. A report stands on a token: a missing
one at a line's end stands on the token it belongs after.

A spelling another language gives a construct is named for what Landin
writes instead (D367), under the code the parser would have raised:
`elif` and `elseif` are `elsif`, `fn name(...)` is `name: (...) -> (...) =`,
`x as i32` is `i32(x)`, `x++` is `inc x`, `*u8` is `ptr u8`, `&&` and `||`
are `and` and `or`, and `!=` is `<>`. The report begins "Landin writes", and
where one edit writes the Landin form it offers that edit as a likely fix.

### L0100

A name belongs here and something else stands there [1760]. A keyword is never
a name, including a control word in any position (D225), and `_` alone is the
discard. Choose another name, such as `begin_value` for `begin`. A keyword
written as a binding's name is reported once, and its later uses as a value
are the same mistake (D368).

A `match` arm that begins with a number names a value where a case belongs:
compare values with `if` and `elsif` (D369). Statements on the lines under a
bare `else` were meant as a recovery block, which binds the error first:
`else (problem)`, closed by `end` (D370). `_` among several labels of one
arm is refused too: it covers every case no other arm names, so it is an arm
of its own (D405).

```landin
_: u32 = 1
```

### L0101

A type position holds nothing the kernel enables as a type [1790].

```landin
empty: type = ()
```

### L0102

An expression was required and none begins here [1820]: an operator with no
operand, or a separator where a value belongs.

### L0103

A token the grammar requires is absent [1810]. The second label points at the
construct that required it. When a name near the required keyword stands in
its place, such as `thne` for `then`, the diagnostic offers the keyword as a
likely fix. An arm that names several cases binds no payload, so bindings
after them are refused here: give the case whose payload is bound an arm of
its own (D405). Only a name is indexed [0570], so a text literal followed by
`[` is refused with the route, a name given to the text first; no repair
removes the literal, which would change what the line computes. Nor is an
applied type called to make a value: `list(i32)(items: ..., len: 3)` is
refused naming the form that works, the fields in parentheses where the
type is declared [1350].

```landin
extern(c) bad: (...) -> none
```

### L0104

A construct opened and its `end` never arrived [1800]. The second label shows
where it opened; close it there.

```landin
f: () -> (r: i32) =
    r = 1
```

### L0105

Assignment is a statement and never an expression [0390]. `==` compares. When
the assignment is an `=`, the diagnostic offers `==` as a likely fix.

```landin
f: () -> (r: i32) =
    mut n: i32 = 0
    r = (n = 1)
end f
```

### L0106

A comparison takes at most one operator [1820]: `a < b < c` compares a `bool`
with `c`. Write `a < b and b < c`.

```landin
f: (a: i32, b: i32, c: i32) -> (r: bool) = a < b < c end
```

### L0107

`return` carries no value [1810]. Assign the named return, then `return`.

```landin
f: () -> (r: i32) =
    return 1
end f
```

### L0108

`public` belongs on a module declaration and never on a statement [1740].

```landin
f: () -> none =
    public n: u32 = 1
end f
```

### L0109

The name after `end` must be the name of what it closes [1800], or be absent
where the construct allows that. The diagnostic offers the declared name as an
exact fix.

```landin
f: () -> none =
end g
```

### L0110

A run of tokens begins no declaration or statement [1740]. Often a keyword
used as a name (D225), or a line left from an edit. A `fixed if` inside a
routine body is one too: it selects module declarations [1500], so declare a
routine per system in a module-level `fixed if`, or branch with `if` on a
module value that holds the fact, `on_linux: bool = compiler.os == linux`
(D437).

```landin
begin = 10
```

### L0111

An implementation limit, not a rule of the language: a construct nests more
deeply than the parser holds. Split the expression or the block into named
parts.

### L0112

A positional argument follows a named one [0980]. Every positional argument
comes first.

```landin
take: (first: i32, second: i32, third: i32) -> none =
end take

bad: () -> none =
    take(first: 1, 2, 3)
end bad
```

## Names

### L0200

One scope gives one name to one thing [1850]. Two declarations of one name in
one scope, or two imports with one final segment, are refused, and the second
label shows the first. An inner scope may shadow an outer name; that is not
this.

```landin
first: u32 = 1
first: u32 = 2
```

### L0201

A name that is declared in no scope this use reaches [1860]. There is no
implicit declaration, so it is a misspelling or a name used outside its scope.
When a declared name the position could mean is near it, the diagnostic offers
that name as a likely fix: a local or parameter, a type, a public member of an
imported module, never a name out of scope or inaccessible. A member a module
declares only in a `fixed if` arm this target does not select, a Linux call
written for Darwin among them, is named as one this system does not have,
since no spelling of it would be found here.

`core/io` has no `print`, `println`, `printf` or `puts`: one call writes a
template and its values to a file (D527). Asked for one of those, the note
shows that call spelt with the name the program reaches the module by,
`io.write_format(host, io.out(host), "{}\n", [any(addr x)])`, with
`host` from `hosted/blocking`'s `blocking.new()` on a hosted system, and
for a selected import says to select `write_format` and `out` instead.

A name applied to type arguments, `shlf(item)`, is the same misspelling and
is offered the same near names. A payload-free case of a variant another
module declares is written with that module's name, as everything public in
it is [1440], so a bare `leaf` naming an imported module's case is offered
`shapes.leaf`. A scalar type written as a positional argument of a generic
routine is a type where a value belongs; the note writes the call with every
argument named, the type given to the routine's type formal [1300], as
`make_buffer(capacity: 4, t: u8)`.

A parameter, result or local may hide an import of its own name [1450], so
`time.duration` written where a result is called `time` names no type. The
diagnostic says so, names the local and the import it hides, and points at
the local; rename it (D381).

```landin
state := nowhere(value: 1)
```

### L0202

A declaration of another module is used and it is not `public` [1410]. The
second label shows the declaration. Make it `public` in its module, or use
something that module does export. A module-internal type's member that is an
entry of a concept the type conforms to is reached through the public
routine of the concept's module that calls it [1240], and the note names
that routine as this file calls it: `memory.alloc(64, 1)` on a
`hosted/heap` handle is `mem.allocate(memory, ...)`.

### L0203

A tool namespace, `compiler`, `assembler` or `linker`, is bound or used in a
way it does not allow [1560] (D202). Those three are in scope without an
import and cannot be imported, rebound or given a member they do not have.
A compiler fact is read in a fixed condition and in a module value (D437),
never in a routine body: bind it, `fast: bool = compiler.feature.popcnt`, and
let the body read the binding. `compiler.os` and the other atom facts are read
compared with one of their atoms, `compiler.os == linux`.

## Types

### L0300

A value known at compile time does not fit the type its context gives it
[1880], or the target cannot hold it. Write a smaller value or give the
context a wider type.

```landin
over: u8 = 300
```

### L0301

A value's type is not the one its context or operation requires [1890], and
no conversion is implied [0310]. This includes a literal that its context
cannot type [1880] [0210] [0260], an expression with no value type where one
is needed, a type-qualified name its type does not have [0240], an operation
such as indexing, slicing, selection or a call applied to a value whose type
has none [1820], an operator given an operand class it does not admit, a struct of another nominal type [0710], an array of another length
or element type, a function of another signature [1000], or a reference of
another permission [0440]. The second label shows where the requirement was
stated. Change the value, or convert it explicitly where a conversion exists.
A text literal takes `utf8`, `[]u8`, `utf16` or `cstring` from its context but
never a pointer; for a `ptr u8` parameter, bind it, `name: []u8 = "..."`, and
pass `addr name[0]`, since the literal ends in NUL (D442).

```landin
flag: bool = true
count: u8 = flag
```

### L0302

Required storage is not definitely assigned at a read or an exit [1910]. A
read needs the place assigned on every path that reaches it. Reading a whole
aggregate also reads its parts; a computed local-array index requires the
whole array assigned (D19-D22). Assign the needed place before the read on
every arriving path, or give it a value where it is declared.

After `sink`, the consumed place is dead until assigned again [0910]. Assign
it or its enclosing aggregate before a later read. A consumed part of an
`inout` parameter must also be restored on every exit, including `fail` and
`try` failure propagation: the caller can observe that storage after a
recovered failure. Assign it on each exit path, either before the exit or in
an applicable `defer` or `undo` cleanup, which runs before this check.
A named result must be fully assigned on successful return [0930], including
any part consumed by `sink`; failure exits do not require the named result.

```landin
unavailable: atom
consume: (sink value: i32) -> none = end consume
bad: (inout value: i32) -> none ! unavailable =
    consume(value)
    fail unavailable
end bad
```

### L0303

A place that may not be written [1900]: an immutable binding, an `in`
parameter, an atom, a function, or storage reached through a read-only
reference. When the place is a local or module binding of one name, the
diagnostic offers `mut` on its declaration as a likely fix. A binding written
several times is reported once, at its first write, and a refused write still
counts as assigning the place, so later reads are not reported (D263).

```landin
f: (x: u32) -> none =
    x = 1
end f
```

### L0304

A known form used where the language does not permit it [1830], found once
the checker knows what the form means. The report names the specific rule;
its two notes give the tour paragraph and the form's standing.

For a variant [0680]-[0690] (D75/D76/D241), its part belongs to the
enclosing struct and has no standalone value. Match the part to inspect its
case, or copy the whole struct. To change the part, write one of its cases
to a directly selected part of a mutable struct, or supply that case while
constructing the struct. A case cannot initialize an unrelated binding as
a standalone value: its destination must supply its variant part. A case
without payload may be bare; write a payload case with labelled fields.

An array literal [0520] takes its shape from where it is written: an array
destination, an inferred binding, or the argument of a read-only slice
parameter, which it lends a slice of storage made in the caller's frame for
the call. A generic routine's slice parameter gives one only when its element
type names no formal (D419); where the element type is a formal, deduced
from the arguments, the report names the binding to pass instead,
`values := [...]`, or `values: [N]E = [...]` when an element such as
`any(addr x)` needs a context, which an inferred binding does not give.

```landin
holder: type = struct
    kind: variant
        dot |
        box: (w: u8)
    end kind
end holder

f: () -> none =
    mut h: holder = zeroed
    h.kind = dot      -- permitted: the part is the destination
    part := h.kind    -- L0304: the part has no standalone value
    alone := dot      -- L0304: the case needs its part as destination
end f
```

### L0305

A required static value or initial image cannot be established before the
program runs [1940] (D136, D202). A module value, array bound or fixed
configuration expression can depend on a runtime value or call, contain an
unknown fixed name or form, or depend on itself, within one module or through
several. A fixed condition or option default measures scalar types only: a
declared type's size, alignment or field offset is measured by
`compiler.assert`, once checking has laid the type out (D412). An array bound
may name an immutable module integer whose own image is a count, literals,
compiler facts and other such integers under `+ - * / %`, but not a `mut` one,
which the program may write (D438). Change such an expression to one the closed fold can evaluate. A value
another module exports, named through that module as `sizes.page`, is known as
it is in its own module; a field of a record image, an element of an array
image and a call are not, in either. A module function binding without an
initializer has no implicit zero function address; give it an initial function
address, such as a declared function or another module function value whose
image is known.

```landin
a: i32 = b + 1
b: i32 = a + 1
```

### L0306

An operand the operation cannot take, where the compiler knows it [1950]: a
divisor of zero, a shift by a negative amount, an index outside a fixed
array, or a range subtype whose bounds are reversed.

```landin
quotient: u32 = 7 / 0
```

### L0307

A chain of type aliases that never reaches a type [1795].

```landin
a: type = b
b: type = a
```

### L0308

A field a struct, a variant case or a result was not declared with [0750]
[0990]. When a declared field is near the written name, the diagnostic offers
it as a likely fix.

```landin
point: type = struct
    x: i32
end point

f: () -> none =
    local: point = (z: 1, of zeroed)
end f
```

### L0309

A struct declaration [0670] or literal [0710] repeats a field name, a variant
case declaration [0680] (D74) repeats a payload field name, or a case
construction (D76) supplies the same payload field twice. Remove or rename a
repeated declaration field; in a literal or construction, supply each field
once.

```landin
bad: type (item: type) = struct
    value: u8
    value: item
end bad

choice: type = struct
    kind: variant
        pair: (first: u8, first: bool)
    end kind
end choice
```

For a case declared as `pair: (first: u8, second: bool)`, the construction
`pair(first: 1, first: 2, second: true)` repeats `first`.

### L0310

A struct literal [0710] or variant case construction (D76) omits a field
without a trailing `of zeroed`. Supply the missing field, or use `of zeroed`
when every omitted field has a zero image.

```landin
point: type = struct
    x: i32
    y: i32
end point

f: () -> none =
    local: point = (x: 1)
end f
```

For a case declared as `pair: (first: u8, second: bool)`, the construction
`pair(first: 1)` omits `second`.

### L0311

A match names one case twice [1210]: a variant case, an atom of a set or a
pointer union's case, twice in one arm or once in each of two (D405). Keep
one label and delete the other.

### L0312

A match leaves a case unnamed [1210]. For a variant part, add an arm naming
each missing case. For an atom set or pointer union, name the missing cases
or put a `_:` arm last to cover them.

```landin
north, south: atom
compass: type = north | south

f: (direction: compass) -> (value: i32) =
    value = match direction
        north: 1
    end match
end f
```

### L0313

A struct holds itself by value, so its layout could never be finite (D137).
Hold it through a pointer.

```landin
node: type = struct
    next: node
end node
```

### L0314

Retaining a reference requires both storage that remains live and permission
from its origin [0770] [0780]. A reference into this function's frame cannot
be returned, passed to a retaining (`escaping`) parameter, or stored outside
the frame. Move the referenced value to storage that actually outlives the
retention, or stop retaining the reference. Declaring a parameter `escaping`
does not extend the lifetime of frame storage.

Parameters are non-escaping by default. A reference derived from one cannot
be passed to a retaining (`escaping`) call or stored in another origin, even
if the referenced storage will remain live. If that retention is intended,
declare the source parameter `escaping`, or `escaping into` the parameter
whose storage keeps it (D445), and make its callers satisfy that contract.
A reference kept `escaping into` a parameter must outlive that argument's
origin: a frame reference never outlives a parameter's storage, and a local
only the storage of locals declared after it (D455). Otherwise, keep the use
non-retaining or update storage within the same origin. Keeping the storage
alive longer alone does not grant retention permission.

```landin
bad: () -> (pointer: ptr u32) =
    value: u32 = 1
    pointer = addr value
end bad
```

### L0315

A place is changed while a view derived from it is still in use [0800] [0830].
Finish with the view first, or take it again after the change. An argument
passed `inout` or `sink` counts as changed whether or not the routine writes
it: the convention locks it, and the diagnostic names the parameter whose
convention does, the view still in use, and, for `inout`, that a routine
which only reads the parameter may take it without `inout`.

```landin
mutate: (inout source: []mut u32) -> none =
end mutate
bad: (source: []mut u32) -> (result: u32) =
    mut local := source
    view := addr local[0]
    mutate(local)
    result = view.val
end bad
```

### L0316

A returned reference must derive from exactly the parameters its `from`
names [0790]. Name the source, or return something derived from it. A
provider's entry whose result has no `from`, such as an allocator's `resize`
returning the block it was given, returns `ptr(usize(block))`: an allocation
borrows nothing, and [0810]'s conversion says so (D440).

```landin
bad: (source: ptr u32) -> (pointer: ptr u32) =
    pointer = source
end bad
```

### L0317

Two conformances of one type to one concept [1280]. There is one register for
the whole program; remove one, or give one type `distinct` identity.

```landin
ordered: type = concept (t: type)
end ordered

i32 is ordered ()
i32 is ordered ()
```

### L0318

A type given for a formal lacks a conformance the formal requires [1290].
An `any C` provides C and every concept C refines, and no other (D492):
erase the provider as an `any` of the wanted concept where it is made.
Its address is not erased again; pass the `any C` itself.

```landin
cell: type (t: type is zeroable) = struct
    value: t
end cell

bad: type = cell(ptr i32)
```

### L0319

The compiler owns `zeroable` and its conformances, and the conformance by
which an `any C` provides C and the concepts it refines (D492); a program
declares none of them.

```landin
i32 is zeroable ()
```

### L0320

A text literal holds an escape the language does not define, or bytes that are
not UTF-8 [0270] [1750].

```landin
name: []u8 = "bad\q"
```

### L0321

A float literal needs its fraction, and an exponent where its form requires
one [0210] [0220] [0230]. It also needs a separator before a following name
[1770], so a width suffix such as `f32` makes the whole literal malformed:
drop the suffix and let the binding's type give the width.

```landin
ratio: f64 = 1e10
```

### L0322

A character literal holds exactly one Unicode scalar value [0250] [0270].

```landin
bad: u32 = ''
```

### L0323

A raw literal's content is UTF-8, and each line that is not blank starts with
the closing delimiter's indentation [0280] [1750].

```landin
bad: []u8 = """
    enough
  short
    """
```

### L0324

A compile-time assertion is false [1510].

### L0325

An implementation limit, not a rule of the language: a routine has too many
declarations, or a struct body or variant case has too many fields (D247).
Split the routine or reduce the fields in the body or case.

### L0326

A warning about legal source: a local binding is declared `mut` and
nothing writes it, steps it, passes it `inout` or takes a mutable view of it.
An address erased into `any C` whose entries only read through their receiver
is a read, so it does not count.
Without `mut` it means the same, so the diagnostic offers removing the word
as an exact fix when only blanks separate it from the name. Comments or line
breaks retain the observation without an automatic edit. The language permits
the `mut`; the warning is the compiler's
judgement and not a rule (D251). A shared declaration is warned about only
when none of its names is written, and a module binding never is, since a
linked routine or a debugger may write it. A normal warning does not fail the
invocation; `--deny=L0326` explicitly promotes it to an invocation error.

```landin
count_up: () -> (total: u32) =
    mut step: u32 = 2
    total = step + 1
end count_up
```

### L0327

A call's arguments do not match what the callee takes [1920]. A runtime
argument is missing, extra or given twice; a named argument names no
parameter [0980]; a `caller` parameter is filled other than by forwarding
another one (D186); a static argument is given where the callee has no static
formal [1300], or a static formal is used as a runtime value [1290]; a generic
call gives a different number of arguments than its template (D138); or a
conversion is not given exactly one value [0700]. Supply every parameter
exactly once, in the callee's declared form. The second label points to the
signature or parameter. When a named argument names no parameter, the
diagnostic offers the parameter label near it as a likely fix.

```landin
add: (a: i32, b: i32) -> (r: i32) = a + b end add
f: () -> (r: i32) = add(a: 1) end f
```

### L0328

`zeroed` or an implicit initializer has no complete zero image to supply
[0540]. `zeroed`, an implicit module initializer, and a module atom binding
without an initializer [0630] each need the destination type's all-bits-zero
image. A pointer, function address, atom set without a zero identity, a
distinct type over one, or aggregate containing one has no such image, and
`zeroed` nested in an expression or used as an operand has no destination to
take its type from. A distinct type over a number has its base's image, so a
record holding one is zeroed, but `zeroed` does not construct the identity
itself: write `name(0)` (D428).
Give an explicit initializer that constructs a valid value, use a type with a
zero image, or write `zeroed` as the whole value of a typed destination.
Thread storage, `link(thread)`, begins zeroed in every thread and takes no
value (D496), so its type is the one to change: keep a pointer in it as a
`usize` or as a pointer union with an atom, or keep the referenced value
itself.

Two routes cover most programs. An array whose element has no zero image is
filled from one valid element, `[n of value]`, rather than zeroed; an array of
none has no element to fill it from, and `[0 of value]` is refused, so it is
declared a slice of the element type and given `[]`, which holds none. A
service's state is declared `zeroed` beside the caller's other storage, so it
holds only scalars, and the references the service needs, the backing it was
given or the provider it stacks on, live in the handle `over` returns from
that state (D288): `arena.space` holds counters, and the arena's handle
holds the base.

```landin
node: type = struct
    value: i32
end node
bad: () -> none =
    value: [3]ptr node = zeroed
end bad
```

### L0329

A failure does not follow the declared error contract [0940] [0960] [1030].
`fail` carries exactly one atom of the function's declared error set. A body
that can fail with an atom outside it is told which atom, and the `fail`, the
call or the `try for` it first came through is labelled (D382). A call
to a failing function handles the outcome with `else` or propagates it with
`try`, and neither form applies to a call that cannot fail. A public or
first-class signature writes a concrete error set instead of `! ...`. Add the
atom to the error set, handle or propagate the call, or remove the handling
from an infallible call. The implicit provider calls in `try for` also
propagate their declared errors: the enclosing routine must declare or infer
those atoms, and its caller may recover them through ordinary call `else`. In
an `if` arm, `else value` after a call divides the `if` [1820], which leaves
the call unrecovered: write `(f() else 0)`, or bind the error with
`else (problem)`.

```landin
missing, denied: atom
f: () -> none ! missing =
    fail denied
end f
```

### L0330

An assembly block, operand or template breaks [1630]'s block contract or
[1990]'s register rules. Only `assembler.block` accepts operands. Each
operand is one integer register, named by its target-wide name or chosen with
`general`, and never a stack, frame, link or reserved register. Every `{name}`
in the template names one operand. A naked body is exactly one block. Change
the operand, register or template as the note says, or move the operands
into an assembly block. A pointer crosses as `usize(p)`, and the routine around
the block takes the storage as `ptr mut u8` or `[]mut u8`, the permission its
callers are checked against (D440).

```landin
record: (first: u32, second: u32) -> none = end record
f: (value: u32) -> none =
    record(1, in x: u32 at r0 = value)
end f
```

### L0331

A call's result is used in a way its signature does not allow. A result that
is handed back must be used or discarded with `_ =` [1020], and a call that
returns none has no value to use, infer from, or discard [1920] [1930], nor
one for its `else` to yield in place of a result [1030]: `else none` ignores
its failure, and is refused on a call that does return a value (D376)
unless the call is the whole operand of a discard, `_ = f() else none`
(D406); to use the value, handle the error with `else (problem) ... end`.
An `if`, `match` or bare `begin` used as a statement takes no value from its
branches, so a branch that ends with one would drop it; in an `if` arm that
value is often a call's `else value` the `if` took as its own [1820].
A `noreturn` call never returns at all [0890], so it is no value either: it
ends the path where it stands, and the note says so rather than calling it a
call that returns none.
Destructuring binds the names of a multiple result, each at most once [0990].
Discard the result explicitly, use a call that returns one, or bind the
result names the signature declares.

```landin
double: (x: i32) -> (r: i32) = r = x * 2 end double
f: () -> none =
    double(5)
end f
```

### L0332

A `break` must carry a value exactly when its target needs one [1180] [1190];
every value-producing fallthrough must supply one (D124). Every `break` out
of a loop used as an expression carries `with`. A finite expression loop
leaves through `break with` when it completes. Every fallthrough path of a
value-producing `if` or block produces a value; an early return need not.
A labelled bare block and a statement loop take no value. Add `with` and a
value to a break from an expression loop. Remove `with` from a break to a
statement loop or labelled bare block. Supply a value on each fallthrough
path, or use the construct as a statement. A value-producing construct
missing its value on several paths is reported once, against the construct
(D263).

```landin
public main: () -> (code: i32) =
    code = loop do
        break when true
        break with 1
    end loop
end main
```

### L0333

A `match` arm does not fit its subject [1210]. A subject is an atom set, a
variant part or a pointer union. Each arm names a case or atom of that
subject at most once (D77) [0640] [0480], and a name twice is L0311. A `ptr` arm matches only a pointer
union and binds one read-only pointer, or one `sink` pointer that consumes
the matched place [1220] (D433); no other binding is `sink`. Atom arms bind
no payload [0630]. A wildcard arm comes last; on an atom set it may bind one
read-only name, `_ (rest):`, to the atoms no other arm names, and only when
some are left (D434). Variant payload names are positional and
complete (D78). Rewrite the arm in the form its subject admits, or compare
numbers with `if` and `elsif`.

```landin
f: (n: u32) -> none =
    match n
        _: _ = 1
    end match
end f
```

### L0334

A struct, variant or array value is built or used outside its admitted form
[0700] [0720]. A construction applies a struct type to labelled field values,
and its fill supplies one value for the omitted fields. A variant case is
written where its part is the destination [0690] (D76). A whole struct or
array is copied, passed, returned or discarded whole [0670] [0520], and an
array is lent whole as the argument of a slice parameter [0570]. A
repetition prefix leaves a suffix to fill (D36). Write the value in the form
the note names, at a position that takes it.

```landin
record: type = struct
    first: bool
end record
f: () -> none = value: record = (first: true, of false) end f
```

### L0335

A union of atoms and one pointer is used as a pointer before it is matched
[0480]. Match it first: the `ptr` arm binds the pointer, and each atom arm
names the empty case. Asking which case it holds, `m == none_found`, needs
no match, but two unions do not compare (D429). A pointer case is constructed
only from a pointer, and
a known zero address is reserved for the union's empty atom [0460]. Match the
union, or construct it from an atom or a pointer. A C function value is not
made from a known zero address either, since no code is there [1975]: a
lookup that finds nothing is a failure to recover from, not a function.

```landin
none_found: atom
maybe_ptr: type = none_found | ptr mut u32

bad: () -> (value: u32) =
    mut cell: u32 = 1
    m: maybe_ptr = addr cell
    value = m.val
end bad
```

### L0336

A packed image or its layout is used outside [0730]'s rules. Packed fields
have explicit, disjoint bit positions within one unsigned image, and an
encoded union has distinct atoms and encodings. A packed width such as `u2`
is a field representation, not an ordinary value type. A packed field has no address
of its own, cannot be passed `inout`, and cannot be sliced; the image is not
a scalar operand (D228). A field of a `layout(c, packed)` record, at any
depth, has no address of its own either (D410): it is read and written by
copy. Correct the layout, or work through the containing image or record
and its fields.

```landin
image: type = layout(packed) struct
    value: u2 at 0..1
end image
f: () -> none =
    mut x: image = zeroed
    _ = addr x.value
end f
```

### L0337

An operation that needs a distinct addressable place was given something
else. `addr` takes a storage place [0430], not a computed value such as a
utf8 index result [0610]. Two `inout` arguments cannot be one place [0900],
and a `sink` argument is a place rooted in a binding [0910]; a match arm's
binding is one only when written `ptr (sink p)`, and then only over a
subject that is such a place (D433). Store the value in a binding first, or
pass two different places.

```landin
replace: (inout left: u32, inout right: u32) -> none =
    left = 1
    right = 2
end replace

public main: () -> (code: i32) =
    mut value: u32 = 0
    replace(value, value)
    code = 0
end main
```

### L0338

A type position or type declaration is not well formed. A type position names
a scalar type or a `type` declaration, and a type name is not a runtime value
[1795]. A type alias is applied with its exact positional arguments [1350]. A
union holds atoms and at most one pointer type [0640]; a range subtype
restricts an integer type [0660]; a fixed-array bound is an integer count
(D136). Correct the declaration or name a type.

```landin
bytes: type (t: type, fixed n: u32) = [n]t
bad: type = bytes(u8)
```

### L0339

A written signature is not well formed. A function type gives each parameter
a distinct label [0980] and each result a distinct name [0990]. A `from`
clause names borrowed runtime parameters, once each, on a result that holds a
reference [0790]. An `escaping into` names another runtime parameter whose
type holds a reference (D445). A `caller` parameter has the exact
source-position struct (D192). Rename or remove the duplicate, or correct the
clause.

```landin
duplicated: type = (value: i32, value: bool) -> none
```

### L0340

A generic call cannot deduce and instantiate one concrete routine (D138).
Deduction matches each runtime argument against its written parameter
pattern, an untyped literal last, when it takes the type its parameter then
names (D372); it never uses the return context, conversions or constraints, and
repeated deductions must agree, and the deduced actuals must give a
concrete, enabled signature whose fixed values fit their formals. A generic
template has no function value until it is called. Recursion that keeps changing the actual tuple never ends,
and a circular error-set dependency cannot be resolved (D215). Give the type
argument explicitly, pass arguments that agree, or call a concrete routine.

```landin
phantom: (t: type, value: i32) -> (result: i32) = value end phantom

public main: () -> (code: i32) = phantom(7) end main
```

### L0341

A concept or conformance declaration is not well formed [1230]-[1270]. A
concept is parameterized by types and names each entry once. Composition is
finite, and a static entry name is unique across the concept closure (D221).
Every entry fixes one concrete error set. A conformance names a
declared concept, supplies each input and entry once by label, and provides
each entry with a function of exactly the required signature. A parameterized
conformance applies its complete binder. Correct the declaration against the
concept it names. A conformance refused for what it lacks is reported once:
a use that needs it is not refused again for want of one. A parameter or local named after a concept hides it [0140],
and the diagnostic then names the parameter as the cause (D381).

```landin
left: type = concept (t: type) is right
end left

right: type = concept (t: type) is left
end right
```

### L0342

An `any` value or its dispatch is used outside the erased contract [1370]
[1380] [1390] (D145-D147). `any C` names a concept with runtime entries,
each dispatch name unique across its closure, and erases a pointer, never a
value; every entry takes the erased `self` first, as a pointer or as a record
the dispatch copies from that pointer; an entry is called
directly and is not a bound value; a concrete pointer selects exactly one
conformance, or the report names the pointee and every concept it conforms
to; and a module `any` binding has no implicit null pair. A call
through a concept no conformance answers is not refused: no value can reach
it, and it traps as `unreachable` (D377). An entry taking `self: ptr mut`
needs a mutable address, so a read-only one is refused at the address with
the receiver that writes beside it [0440]. Pass a pointer, write the
`any C` context, `name: any C = any(addr x)` or `name: [N]any C = [...]`,
or adjust the concept's entries.

### L0343

A noreturn routine breaks its contract [0890]. A noreturn signature is
ordinary and infallible, and every reachable path of its body diverges.
Remove the error set, or end every path in a call that does not return.

```landin
stop: () -> noreturn =
end stop
```

### L0344

A memory intrinsic is used outside its explicit contract [1620] (D227), or a
stack builtin outside its own (D450, D453). Each operation takes the operand
types, permissions and memory orderings its contract lists, the target must
support it, and an intrinsic cannot fail. `compiler.stack_prepare` takes a
`[]mut u8`, an ordinary `(argument: usize) -> noreturn` entry and a `usize`;
`compiler.stack_switch` takes a `ptr mut usize` and a `usize` (D472); a target
whose backend does not emit them yet refuses both by name. Use an ordering and
operand the operation admits on this target.

A `core/atomic` cell the target's atomics cannot carry is refused the same
way where the program uses it (D510): on Cortex-M0 a `u64` cell, and a
cell's `exchange`, `add`, `add_relaxed` and `compare_exchange`. A cell one
context alone writes adds with `atomic.sole_add`, a load and a store; state
several contexts write takes `platform/cortex_m`'s critical section.

### L0345

An interrupt or naked routine is used outside its machine-entry contract
[1570]. The machine convention is Cortex-M0's and takes a nongeneric
`() -> none` signature without errors. A naked body is one assembly block. A
machine entry is entered by its vector and is never called as a routine.
Correct the signature or body, or call an ordinary routine instead.

```landin
extern(interrupt) tick: (count: u32) -> none = end tick
```

### L0346

A C boundary declaration or call is something the C ABI cannot carry
[1580]. A target with no C ABI yet, as Cortex-M0 has none, has no C
signature and lays out no `layout(c)` record, and the diagnostic says so by
the target's name; a byte-packed `layout(c, packed)` record needs no C
alignment and stands there. The refusal of a signature names the part C
cannot carry beside it. On a target with C ABI support, a C signature is infallible and
nongeneric, with at most one result. Each parameter and result part uses
implicit or explicit `in`, without `caller` or a constraint. Its type is a
scalar, pointer (including a named optional pointer union), fixed infallible
C callback, or `layout(c)` struct; slices, `any`, atoms and by-value arrays
are excluded. A `layout(c)` struct has at least one field and holds only C
representations: scalars, pointers, fixed C callbacks, nonempty fixed arrays
or recursively `layout(c)` structs, with no tagged variants; the label names
the field that is not one. Its last field may be a `[0]T` flexible array
member after at least one other field (D413), and a record ending in one is
not a field of another C record. A `layout(c, packed)` record holds an array
or nested record by value only when its alignment is one: `u8`, `i8`, `bool`
or a packed record (D410). A packed record, a record with a flexible member,
and a record holding either cross a C signature only by pointer (D414). A variadic C
declaration needs at least one fixed parameter and target support; a variadic
definition needs a generated adapter. Variadic calls take positional scalar,
pointer or fixed C callback tail arguments, without labels or static
arguments. Change `inout` or `sink` to `in`; pass a pointer if C must write
through a parameter. Remove `caller` and constraints, specialize generics,
represent errors through an ordinary C result, and combine multiple results
into one C-representable result. Pass a pointer to a by-value array or other
unsupported aggregate, or change the type or layout to one C represents.
Pass `ptr` to a packed record or one with a flexible member.

```landin
extern(c) collect: (count: i32, ...) -> none
bad: () -> none =
    collect(count: 1)
end bad
```

### L0347

A link symbol, hosted initializer, firmware placement or thread storage
breaks [1610]'s, [1975]'s, [1640]'s or [1996]'s contract. A link symbol denotes one compatible function
and at most one definition. Beside a hosted entry, a declaration carrying
`_landin_host_initialize_arguments` is exactly
`extern(c) (count: i32, values: ptr ptr u8, environment: ptr ptr u8) -> none`,
which takes C's `argc`, `argv` and `envp`. Only the entry module's hosted `main` takes the
`main` symbol. A datum's link symbol on a hosted target has a routine's
shape and is never `main`; Cortex data symbols and sections use the
spellings, alignments and vectors [1640] lists. Rename the symbol or correct
the declaration. Two declarations of one C symbol that differ only in
`escaping` are refused too, and the report names the parameter: a Landin
caller of either is checked against what it says, so repeat `escaping` on
both (D441). `link(thread)` places a module `mut` binding that has no
value, one instance in every thread (D496): it places no routine, takes no
initializer, and takes no link symbol or section, which would name or place
one instance for all of them. Drop the value, make the binding `mut`, or
drop the other attribute.

```landin
extern(c) link(symbol: "foreign_entry+8") bad: () -> none
```

### L0348

A `for` source is not something the loop can traverse [1150]. A range
traversal runs over integers, an array or slice is walked by element, and a
struct or `any C` source selects one exact iterable conformance with one
`Cur` and `Item` pair (D180). An ordinary pointer is not a `cstring` (D184).
Traverse an integer range or a traversable value, or declare one iterable
conformance. Each provider takes a read-only, non-escaping `ptr T` to the
retained source, with the exact cursor, item, permission and origin contract
at [1320]; migrate a by-value source parameter to that pointer contract.

If the source supplies `fallible_iterable`, use `try for` and declare or infer
its provider errors in the enclosing routine. That conformance has one exact
shared atom error set across all four providers. Ordinary `for` only selects
infallible `iterable`; `try for` prefers `fallible_iterable` when both exist
and may use ordinary `iterable` when there is no fallible conformance.

```landin
public main: () -> (code: i32) =
    code = 1
    for item in false..true do
        _ = 0
    end for
end main
```

### L0390

An `option` declaration breaks [1530]/D202: it is inside a fixed arm, reuses
a compiler-owned configuration atom name, or declares a type other than `bool`
or an enabled integer scalar. Move the option outside every fixed arm, choose
an available name, or change its type, respectively. A fixed default value
does not make any of those declarations valid.

```landin
option debug: u32 = 1
```

### L0391

A tool directive breaks [1510]/[1590]/D202 when it has other than one
positional argument, or when `linker.library` has an argument that is not a
quoted text literal with a portable static library name. Give
`compiler.assert` one fixed bool expression.
Give `linker.library` one quoted text literal containing a portable static
library name; its argument must have the required form and name characters.

```landin
linker.library("-bad")
```

### L0398

A register image known at compile time violates its reserved-bit write policy
[0740] (D228). Supply zero in every unnamed bit for `write_zero`, or one in
every unnamed bit for `write_one`. A whole-image write cannot repair those
bits by reading the device. The image may fit its carrier type; L0300 instead
reports a value that its type or target cannot hold.

### L0349

An immutable local that is never used and is initialized by a direct scalar
literal, including a negated integer or float literal, can be removed without
changing the program's meaning (D251). The
warning offers that removal as an exact fix when the declaration occupies its
own line without comments or attached documentation. Otherwise it reports the
observation without an edit. Shared declarations, module bindings and
declarations whose initializer may perform work are not warned about.
`--allow=L0349` suppresses this observation; `--deny=L0349` enables it as an
invocation error before emission.

```landin
unused: () -> none =
    count: i32 = 42
end unused
```

## The backend and its toolchain

### L0500

The requested output cannot be made with the selected target, settings or
available toolchain [1550]. The diagnostic and its note identify the cause:
the target has no backend, its source debug mode is unsupported, firmware
forbids `linker.library`, a static Linux link cannot be made (no library
holding `platform/linux` was found, or the program asks for `linker.library` or
refers to C symbols nothing in it defines, each named with the routine that
refers to it, as `platform/posix`'s loader refers to `dlopen`; `refine check`
gives the last two as a compilation would), no toolchain
is selected, or no driver the target names can be started. On Linux the
message lists every driver looked for, the target's own GCC and the names
Debian, Ubuntu and Fedora give it, and the note says which package to
install, through `nix-shell -p gcc` on Nix (D364), and that `refine check`,
`fmt` and `lsp`, and `compile --emit=asm` or `--emit=ir`, need no C driver
(D384); the program's own refusals come first, so a static link that
meets a C symbol is refused for that before anything asks for a driver.
Choose a target with a backend, change the debug or firmware configuration,
link with `--link=libc`, or select or install a toolchain as the note
directs. `--toolchain=` only helps when a toolchain is absent or
unavailable.

### L0501

Executable emission failed [1550]. The assembler or linker may have refused
the emitted code, or the requested output could not be produced, verified, or
restored. The note describes the failure, names paths needed for recovery,
and includes tool output when available.

### L0502

`--emit=exe` needs an entry: a hosted `main` of the one shape [1970] in the
entry module, or the firmware routine `--firmware-entry=` names. A `public
main` in a hosted program's entry module that is not of that shape is refused
when the program is checked or emitted as assembly too, where the linker would
otherwise find no `main` (D443); a C-convention `main` is [1650]'s own form.

### L0503

Retired. An internal call could only pass arguments in registers. The internal
calling convention now places every argument after the sixth on the stack, so
nothing raises this.

### L0504

A verified frame is larger than x86-64's signed 32-bit displacement reaches.
Move the large local storage into a module value or an allocation.

### L0505

Firmware static images exceed what the assembler is given to materialize
[1640]. Make the static data smaller, or hold it in fewer, larger values.

### L0506

The panic handler is invalid, or the program has more check sites than their
identifier space holds [1670].

### L0507

One routine's saved registers and local frame exceed the selected 4 KiB firmware
stack reservation [1990]. Move large local storage elsewhere or make it smaller.
This check does not bound calls or interrupt nesting.

### L0508

A program that prepares a stack selects a panic handler that does not fit
the target's stack margin [1670]. A failed check enters the handler on the
stack that overflowed, so the handler and everything it calls run in the
margin a prepared stack keeps above its base (D472): 640 bytes on x86-64 and
arm64, 768 on RV64 and 384 on Cortex-M0. The message gives what the handler
needs, the margin and the target: what the margin pays before the handler,
and the handler's depth from the stack report's `trap` figure, by its
deepest path. When the handler's calls reach an `any` call, a call through a
generic's table or a function value, a foreign call, recursion, a runtime
helper or assembly that moves the stack, its depth cannot be known, and the
message names the opening's kind and points at it. Make the handler's frame
smaller, call less from it, or call through nothing that opens its graph; a
handler that only records the kind and switches away fits on every target.
A program with no `compiler.stack_prepare`, and one that selects no
handler, is not refused: the default report always fits. The rule is
decided from emitted frames, so `refine check` does not raise it (D474).
