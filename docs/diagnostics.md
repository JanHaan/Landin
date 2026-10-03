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

Give `--target=` only once. Repeating it is a misuse even when both names
are the same; the driver does not choose between target selections.

`--toolchain=NAME` and `--linker=NAME` require `--emit=exe`: checking and
assembly emission do not run a linker. They are also incompatible with
`--help` and `--identify`, which do not compile. Each selection must have a
nonempty value and may be given only once.

### L0003

A source named on the command line is missing or cannot be read. Check the
path and its permissions.

### L0004

`--target=` names no target the compiler describes, or none was named and
this compiler's own host is not a described target, so a build has nothing
to compile for until one is named. `refine --identify` lists the described
targets.

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

### L0009

`--level=`, or the language server's `level` option, names no CPU feature
level of the selected target's family (D255). A level belongs to one family,
so `armv8.1-a` is refused with `--target=linux-x86-64`, and synthetic-32 has
no level to select. `refine --identify` lists each target's levels.

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

A value's type is not the one its context or operation requires [1890], and
no conversion is implied [0310]. This includes a literal that its context
cannot type [1880] [0210] [0260], an expression with no value type where one
is needed, a type-qualified name its type does not have [0240], an operation
such as indexing, slicing, selection or a call applied to a value whose type
has none [1820], an operator given an operand class it does not admit, a struct of another nominal type [0710], an array of another length
or element type, a function of another signature [1000], or a reference of
another permission [0440]. The second label shows where the requirement was
stated. Change the value, or convert it explicitly where a conversion exists.

```landin
flag: bool = true
count: u8 = flag
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
image. A pointer, function address, atom set without a zero identity, or
aggregate containing one has no such image, and `zeroed` nested in an
expression or used as an operand has no destination to take its type from.
Give an explicit initializer that constructs a valid value, use a type with a
zero image, or write `zeroed` as the whole value of a typed destination.

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
`fail` carries exactly one atom of the function's declared error set. A call
to a failing function handles the outcome with `else` or propagates it with
`try`, and neither form applies to a call that cannot fail. A public or
first-class signature writes a concrete error set instead of `! ...`. Add the
atom to the error set, handle or propagate the call, or remove the handling
from an infallible call.

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
into an assembly block.

```landin
record: (first: u32, second: u32) -> none = end record
f: (value: u32) -> none =
    record(1, in x: u32 at r0 = value)
end f
```

### L0331

A call's result is used in a way its signature does not allow. A result that
is handed back must be used or discarded with `_ =` [1020], and a call that
returns none has no value to use, infer from, or discard [1920] [1930].
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

A control expression does not produce its value on every exit [1190] (D124).
Every `break` out of a loop used as an expression carries `with`, and a
finite loop leaves through `break with` when it completes. Every fallthrough
path of a value-producing `if` or block produces the value. A labelled bare
block or a statement loop takes no value. Add the missing value, or use the
construct as a statement.

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
subject at most once (D77) [0640] [0480]. A `ptr` arm matches only a pointer
union and binds one read-only pointer [1220]. Atom arms bind no payload [0630]. A wildcard arm
comes last and binds nothing. Variant payload names are positional and
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
array is copied, passed, returned or discarded whole [0670] [0520]. A
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
names the empty case. A pointer case is constructed only from a pointer, and
a known zero address is reserved for the union's empty atom [0460]. Match the
union, or construct it from an atom or a pointer.

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
a scalar operand (D228). Correct the layout, or work through the containing
image and its fields.

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
and a `sink` argument is a place rooted in a binding [0910]. Store the value
in a binding first, or pass two different places.

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
reference [0790]. A `caller` parameter has the exact source-position struct
(D192). Rename or remove the duplicate, or correct the clause.

```landin
duplicated: type = (value: i32, value: bool) -> none
```

### L0340

A generic call cannot deduce and instantiate one concrete routine (D138).
Deduction matches each runtime argument against its written parameter
pattern; it never uses the return context, conversions or constraints, and
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
concept it names.

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
value; every entry takes the erased `self` pointer first; an entry is called
directly and is not a bound value; a concrete pointer selects exactly one
conformance, and the closed program has a runtime table for it; and a module
`any` binding has no implicit null pair. Pass a pointer, write the
`any C` context, or adjust the concept's entries.

### L0343

A noreturn routine breaks its contract [0890]. A noreturn signature is
ordinary and infallible, and every reachable path of its body diverges.
Remove the error set, or end every path in a call that does not return.

```landin
stop: () -> noreturn =
end stop
```

### L0344

A memory intrinsic is used outside its explicit contract [1620] (D227).
Each operation takes the operand types, permissions and memory orderings its
contract lists, the target must support it, and an intrinsic cannot fail.
Use an ordering and operand the operation admits on this target.

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
[1580]. A C signature is infallible and nongeneric, with scalars, pointers,
fixed C callbacks or `layout(c)` structs, and at most one result. A
`layout(c)` struct holds only C representations. A variadic call takes
positional scalar, pointer or callback arguments. Pass a pointer to an
aggregate, or change the type to one C represents.

```landin
extern(c) collect: (count: i32, ...) -> none
bad: () -> none =
    collect(count: 1)
end bad
```

### L0347

A link symbol, helper import or firmware placement breaks [1610]'s or
[1640]'s contract. A link symbol denotes one compatible function and at most
one definition. A compiler-owned helper import keeps its source types,
permissions and nullability. Only the entry module's hosted `main` takes the
`main` symbol. Cortex data symbols and sections use the spellings,
alignments and vectors [1640] lists. Rename the symbol or correct the
declaration.

```landin
extern(c) link(symbol: "foreign_entry+8") bad: () -> none
```

### L0348

A `for` source is not something the loop can traverse [1150]. A range
traversal runs over integers, an array or slice is walked by element, and a
struct or `any C` source selects one exact iterable conformance with one
`Cur` and `Item` pair (D180). An ordinary pointer is not a `cstring` (D184).
Traverse an integer range or a traversable value, or declare one iterable
conformance.

```landin
public main: () -> (code: i32) =
    code = 1
    for item in false..true do
        _ = 0
    end for
end main
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
