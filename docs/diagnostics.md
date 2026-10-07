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

An output file cannot be written, or `refine fmt` cannot safely replace its
input. For emitted output, check that the destination directory exists and is
writable, or choose another path with `-o`.

Formatting needs a writable ordinary file owned by the caller and write
permission in its directory. Hard links, ACLs, extended attributes and an
inability to establish their absence cause refusal. On Linux, ordinary users
may be unable to inspect privileged attributes even on apparently plain files.
Editor formatting can return edits without replacing the file. A refused
formatter replacement leaves the original bytes intact; see
[formatter file handling](format.md) for the full contract.

### L0006

No import root holds the module an import names [1420]. Roots are searched in
the order `--root=` gives them, and a path's segments are directories under a
root, spelled exactly. When a directory near the missing segment is there, the
diagnostic offers it as a likely fix.

### L0007

With `--root=`, the entry module must be a readable directory [1410]. Pass
the directory, not a file inside it. This code also reports an import root or
intermediate directory that cannot be listed while searching in root order
[1420]. Check the named path and its permissions; a genuinely absent module
is reported by L0006.

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
unknown fixed name or form, or depend on itself. Change such an expression to
one the closed fold can evaluate. A module function binding without an
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

A match names one variant case twice [1210].

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
declare the source parameter `escaping` and make its callers satisfy that
contract. Otherwise, keep the use non-retaining or update storage within the
same origin. Keeping the storage alive longer alone does not grant retention
permission.

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
from an infallible call. The implicit provider calls in `try for` also
propagate their declared errors: the enclosing routine must declare or infer
those atoms, and its caller may recover them through ordinary call `else`.

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
[1580]. On a target with C ABI support, a C signature is infallible and
nongeneric, with at most one result. Each parameter and result part uses
implicit or explicit `in`, without `caller` or a constraint. Its type is a
scalar, pointer (including a named optional pointer union), fixed infallible
C callback, or `layout(c)` struct; slices, `any`, atoms and by-value arrays
are excluded. A `layout(c)` struct has at least one field and holds only C
representations: scalars, pointers, fixed C callbacks, nonempty fixed arrays
or recursively `layout(c)` structs, with no tagged variants. A variadic C
declaration needs at least one fixed parameter and target support; a variadic
definition needs a generated adapter. Variadic calls take positional scalar,
pointer or fixed C callback tail arguments, without labels or static
arguments. Change `inout` or `sink` to `in`; pass a pointer if C must write
through a parameter. Remove `caller` and constraints, specialize generics,
represent errors through an ordinary C result, and combine multiple results
into one C-representable result. Pass a pointer to a by-value array or other
unsupported aggregate, or change the type or layout to one C represents.

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
literal can be removed without changing the program's meaning (D251). The
warning offers that removal as an exact fix when the declaration occupies its
own line. A declaration whose initializer may perform work is not warned
about.

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
forbids `linker.library`, no toolchain is selected, or the named tool is
unavailable. Choose a target with a backend, change the debug or firmware
configuration, or select or install a toolchain as the note directs.
`--toolchain=` only helps when a toolchain is absent or unavailable.

### L0501

Executable emission failed [1550]. The assembler or linker may have refused
the emitted code, or the requested output could not be produced, verified, or
restored. The note describes the failure, names paths needed for recovery,
and includes tool output when available.

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

### L0507

One routine's saved registers and local frame exceed the selected 4 KiB firmware
stack reservation [1990]. Move large local storage elsewhere or make it smaller.
This check does not bound calls or interrupt nesting.
