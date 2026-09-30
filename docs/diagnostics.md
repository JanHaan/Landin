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

### L0003

A source named on the command line is missing or cannot be read. Check the
path and its permissions.

### L0004

`--target=` names no target the compiler describes. `refine --identify` lists
the described targets.

### L0005

An output file cannot be written: its directory is missing or read-only.
Choose another path with `-o`.

### L0006

No import root holds the module an import names [1420]. Roots are searched in
the order `--root=` gives them, and a path's segments are directories under a
root, spelled exactly. When a directory near the missing segment is there, the
diagnostic offers it as a likely fix.

### L0007

With `--root=`, the entry module is a directory [1410], and the operand given
is not a readable one. Pass the directory, not a file inside it.

### L0008

`refine fmt --check` found a source that is not in the layout D252 decides
and `docs/format.md` shows. The diagnostic points at the first line that
would change. Nothing is wrong with the program: run `refine fmt` on the file
to put it in the layout, which changes its space and nothing else.

## Lexical, and what is not enabled

### L0010

The program uses a construct the tour describes and the kernel does not enable
yet [1830]. The two notes name the tour paragraph and whether the form is a
recorded boundary, withdrawn with a replacement, or transferred to later work.
Write the program without it, or with what the note says replaces it.

```landin
point: type = struct
    x: i32
end point

state: point = point(of zeroed)
```

### L0011

An integer literal has a digit its base does not have, or runs straight into a
name [1770]. `0x` takes hexadecimal digits, `0b` binary and `0o` octal, and a
literal needs a separator before a following name.

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

A quoted literal that is never closed on its line [0260]. Close it, or write a
raw literal for text that spans lines [0280].

```landin
value := "never closed
```

## The parser

### L0100

A name belongs here and something else stands there [1760]. A keyword is never
a name, including a control word in any position (D225), and `_` alone is the
discard. Choose another name, such as `begin_value` for `begin`.

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
likely fix.

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
used as a name (D225), or a line left from an edit.

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
imported module, never a name out of scope or inaccessible.

```landin
state := nowhere(value: 1)
```

### L0202

A declaration of another module is used and it is not `public` [1410]. The
second label shows the declaration. Make it `public` in its module, or use
something that module does export.

### L0203

A tool namespace, `compiler`, `assembler` or `linker`, is bound or used in a
way it does not allow [1560] (D202). Those three are in scope without an
import and cannot be imported, rebound or given a member they do not have.

## Types

### L0300

A value known at compile time does not fit the type its context gives it
[1880], or the target cannot hold it. Write a smaller value or give the
context a wider type.

```landin
over: u8 = 300
```

### L0301

Two types that must agree do not [1890]. The second label shows where the
requirement was stated. When the disagreement is a named argument no
parameter carries [0980], the diagnostic offers the parameter label near it as
a likely fix.

```landin
v: i32 = 1
n: v = 2
```

### L0302

A name is read on a path that does not assign it first [1910]. Assign it on
every path before the read, or give it a value where it is declared.

```landin
make: () -> (result: [2]i32) =
end make
```

### L0303

A place that may not be written [1900]: an immutable binding, an `in`
parameter, an atom, a function, or storage reached through a read-only
reference. When the place is a local or module binding of one name, the
diagnostic offers `mut` on its declaration as a likely fix.

```landin
f: (x: u32) -> none =
    x = 1
end f
```

### L0304

A name used in a way the kernel does not enable [1920], found once the
checker knows what the name is. The two notes are [1830]'s: the tour
paragraph and the form's standing.

```landin
wide: u128 = 1
```

### L0305

A value required before the program runs, which the compiler's closed fold
cannot produce [1940] (D136): a module value or an array bound that names a
runtime value, calls a function, or depends on itself.

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

A struct literal or a struct names a field more than once [0710].

```landin
bad: type (item: type) = struct
    value: u8
    value: item
end bad
```

### L0310

A struct literal gives no value for a field and no `of` covers it [0710].

```landin
point: type = struct
    x: i32
    y: i32
end point

f: () -> none =
    local: point = (x: 1)
end f
```

### L0311

A match names one variant case twice [1210].

### L0312

An exhaustive match does not name every case [1210]. Add the missing arms, or
an `else` arm.

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

A reference is kept past the storage it points into [0770] [0780]: the address
of a local returned, or stored where the local cannot outlive it.

```landin
bad: () -> (pointer: ptr u32) =
    value: u32 = 1
    pointer = addr value
end bad
```

### L0315

A place is changed while a view derived from it is still in use [0800] [0830].
Finish with the view first, or take it again after the change.

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
names [0790]. Name the source, or return something derived from it.

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

```landin
cell: type (t: type is zeroable) = struct
    value: t
end cell

bad: type = cell(ptr i32)
```

### L0319

The compiler owns `zeroable` and its conformances; a program declares neither.

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
one [0210] [0220] [0230].

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

An implementation limit, not a rule of the language: a routine declares, or a
struct holds, more than the compiler admits (D247). Split it.

### L0326

A warning, and the program is accepted: a local binding is declared `mut` and
nothing writes it, steps it, passes it `inout` or takes a mutable view of it.
Without `mut` it means the same, so the diagnostic offers removing the word
as an exact fix. The language permits the `mut`; the warning is the compiler's
judgement and not a rule (D251). A shared declaration is warned about only
when none of its names is written, and a module binding never is, since a
linked routine or a debugger may write it.

```landin
count_up: () -> (total: u32) =
    mut step: u32 = 2
    total = step + 1
end count_up
```

## The backend and its toolchain

### L0500

No assembler and linker for the selected target were found on this host
[1550]. The note names the program looked for; `--toolchain=` names another.

### L0501

The platform assembler or linker refused what the compiler emitted [1550]. The
tool's own output follows the diagnostic.

### L0502

`--emit=exe` needs an entry: a hosted `main` of the one shape [1970] in the
entry module, or the firmware routine `--firmware-entry=` names.

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
