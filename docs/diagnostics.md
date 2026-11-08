# What each diagnostic means

`refine explain CODE` prints one section of this page. Each section says what
rule the code enforces, cites the paragraph or decision that states it, and
says what to change. The citations a section or a note carries are answered
too: `refine explain [1760]` or `1760` names a construct's title, document
and page on the site, `refine explain D275` or `d275` a decision's, with the
section of the register it is in, and `--full` adds the construct's text or
the decision's chosen rule (D530). zsh reads `[1760]` as a pattern, so quote
it there or write `1760`. It is derived: `spec.md` and `tour.md` decide what a
program means, and the diagnostic catalogue in
`compiler/ada/src/diagnostics/landin-diagnostics-catalogue.ads` decides which
codes exist and what each occurrence must carry. `check.py` holds every
catalogued code to exactly one section here and every citation to a paragraph
or decision that exists, and generates the compiler's copy of this text.

A section's example, where it has one, is a program the code refuses; the
test program's `catalogue` case `every code is explained` compiles it, on a
file system holding the example alone, and requires its report to begin with
that code. An example is one file, compiled with no option on the default
hosted target, unless its first line names the options it needs, as a code
only a Cortex-M build raises does:

```text
-- refine: --target=cortex-m0
```

The line is a comment, so the example is still the whole program, and
`refine --target=cortex-m0 example.ldn` reproduces the report. Each option
begins `--`, with one space before it, and none names a file, since the
example is the only one it is compiled with (D599); `check.py` and the test
program refuse any other `-- refine:` line, naming it. A code whose program
needs a file beside it, the library refine finds, a developer's linker
script or the object the assembler writes, shows no example.

A code whose diagnostic offers a fix says so. A fix is shown as a `help` line
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
2, which says the request and not a program was wrong. An option without its
value is told the values it takes, `--debug needs a value; it takes none,
full or lines`, and an unknown one the nearest option, or the one another
compiler's spelling means here: `-g` is `--debug=full`, `-g1`
`--debug=lines` and `-g0` `--debug=none`.

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

A source or supplied tool input is missing or cannot be read. Check the
path and its permissions. Assembly `.include` and `.incbin`, and linker
`INCLUDE`, `INPUT`, `GROUP`, `SEARCH_DIR` and `STARTUP` directives must use
plain absolute paths so their inputs can be protected while the tool runs
in private staging. Replace relative or indirect forms with plain absolute
paths, or supply a standalone assembly input or linker script. Nested text
inputs are limited to sixteen levels.

### L0004

`--target=` names no target the compiler describes, or none was named and
this compiler's own host is not a described target, so a build has nothing
to compile for until one is named. `refine --identify` lists the described
targets. A misspelt target is offered the nearest described one, a name cut
short the one it begins, and a system named alone, `linux` or `macos`,
every target of that system (D857).

### L0005

An output cannot be written, published or recovered, or `refine fmt` cannot
rewrite its input. Check the destination directory and its permissions, or
choose another output path. A protected-input alias or changed destination
requires a different output path or a fresh invocation after the change is
understood (D907).

A missing output or report parent is named before collision checks. Create
the parent directory or choose an output pathname under an existing
directory, then retry. Refine does
not create compilation output or report parents. An unavailable identity is
refused conservatively with a path/access route; it is not proof of a source
collision. Bindings retains its separately specified staged output-tree
creation behavior.

A late failure can follow successful staging or installation. The diagnostic
names the previous recovery entry and any captured new or concurrent entry
that could not be restored safely. Keep those paths: inspect the named
`.refine-publication-...` directory's `destination-...` records, `stage` and
`recovery` entries, recover the version you need without overwriting a
concurrent save, then remove the retained workspace before retrying. An
unresolved earlier publication is refused rather than discarded. A cleanup
failure can leave the new output installed and its prior version retained;
the diagnostic does not promise that nothing changed.

Formatting retains its original read descriptor and writes into that inode.
It needs a writable ordinary file and write permission in its directory for
the recovery copy (D358). The diagnostic names a read-only file, a directory
that refuses the copy, a set-user-ID or set-group-ID bit the caller cannot
restore, a Linux file with capabilities, or a failed write. It says whether
the original bytes were restored or names the retained `.fmt-original-...`
copy. If an editor renamed a save over the source, refine leaves that save
alone; a late name change can leave the original inode formatted, with its
original bytes retained. Inspect the named copy before restoring it, and do
not copy it over a newer save. A failure restoring mode bits can leave the
file formatted and says which mode could not be restored. Concurrent writes
through another descriptor to the same inode remain unsupported.
`refine fmt --stdout` prints the layout without acquiring a writable lease.
See [formatter file handling](format.md) for the full contract.

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
enabled C ABIs, the four LP64 ones or Cortex-M's AAPCS32 (D920), so RV32 and
Xtensa refuse it; the submodules of `platform/cortex_m`, its constrained
reference description among them, require an M-profile target, including its
higher supported feature levels. `platform/cortex_m` itself is available on
every target and declares its operations only on an M-profile one (D575), so
a program for every target imports it and calls it from a `fixed if
compiler.arch == cortex_m0` arm; a call outside one is L0201 on a hosted
target. Select an applicable target or remove the import. Project-first root
selection cannot change namespace availability.

### L0016

A warning: an import of `core`, `hosted` or `platform` was read from the
compiler's own library, and a `--root=` directory also holds a module at that
path, which was not read (D275, D366). The library always supplies those three
namespaces, so a project's copy of `core` never replaces it. To compile against
that copy instead, name its directory with `--library=DIR`; to silence the
warning, rename or remove the project's directory.

### L0532

An import named a directory under the first root that holds one, that
directory holds no `.ldn` source, and a later root holds a directory of the
same path that does (D563). Roots are searched in the order given and the
first directory found is the module, so the empty one would hide the module
that was meant: an `import rp2040` under `--root=devices/generated`, whose
`rp2040/` holds only register-module directories, would select no device
description. The message names the empty directory and the later one. Name
the root that holds the module first, or give the empty directory its source.
An empty module no later root rivals is still legal.

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

A run of bytes no lexical rule spells [1750], or a word with a capital in it.
A name is lower case [1760], and a byte outside the source alphabet belongs in
a text literal. A word of letters, digits and underscores that holds a capital
is one report over the whole word, and the program is read on as if it were a
name, so nothing else is said about it; the note offers its lower-case
spelling, `init_window` for `InitWindow`. A C function keeps C's spelling as
its link symbol and takes a lower-case Landin name, which the note shows when
the word names an `extern(c)` function without one:
`extern(c) link(symbol: "InitWindow") init_window: ...` [1610] (D528).

A semicolon is not a statement terminator: omit it. Braces do not delimit
Landin blocks: write `if condition then ... end if`, a loop's `do ... end`,
or an explicit `begin ... end` as appropriate. C-family comments use Landin's
`--` line comment or `--( ... )--` block comment instead.

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
token written twice, which is exact. No change moves `lenof` or the operand
it measures, which would read the word as a name nobody declared (D864). A
report stands on a token: a missing one at a line's end stands on the token
it belongs after.

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
of its own (D405). An import's module path is names and slashes and is never
quoted: `import core/text`, not `import "core/text"` (D862). `addr` of a
measure, `addr lenof items`, would take the address of a value: bind the
measure to a name first and take the address of the name (D863).

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
operand, or a separator where a value belongs. An exit written as a call's
`else` value, `f() else return`, is refused here too, because a recovery that
leaves holds its `return`, `fail`, `break` or `continue` in a block [1030]:
the likely fix writes `else begin return end` (D870).

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
type is declared [1350]. A match arm runs one statement or one expression,
so a second statement under an arm is refused at its first token, naming the
bare block that holds several, `case: begin`, the statements, then `end`
(D860). A type alone after `->`, another language's unnamed result, is
refused naming the return with a name, `-> (result: i32)`, and the function
is still closed by its own `end`; so are named returns written without their
parentheses, `-> code: i32` (D861). `defer` and `undo` register a call, so an
assignment after either is refused as an assignment: write it in a routine of
its own that takes the place as `inout`, and register a call to that
[1100] [1110] (D873).

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

`return` carries no value [1810]. Assign the named return, then write a bare
`return`. For a routine with result `r: i32`, replace `return a + b` with
`r = a + b` followed by `return`:

```landin
f: (a: i32, b: i32) -> (r: i32) =
    return a + b
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
(D437). `when` after a statement that is no exit, `code = 1 when ready`, is
refused naming the four exits that take it, `return`, `fail`, `break` and
`continue`; any other statement runs on a condition inside `if` (D865).

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

A configuration-option collision is reported at the option declaration,
with the conflicting module declaration or import as a related source.
Rename the option or conflicting binding. One option produces one collision
report, and uses of the refused binding do not add configuration-only or
missing-member noise. Independent resolution errors are still reported.

### L0201

A name that is declared in no scope this use reaches [1860]. There is no
implicit declaration, so it is a misspelling or a name used outside its scope.
When a declared name the position could mean is near it, the diagnostic offers
that name as a likely fix: a local or parameter, a type, a public member of an
imported module, never a name out of scope or inaccessible. A member a module
declares only in a `fixed if` arm this target does not select, a Linux call
written for Darwin among them, is named as one this system does not have,
since no spelling of it would be found here. One declared under an arm that
reads `compiler.feature.cache`, `platform/cortex_m/l1`'s provider, is named
as a cached profile's on a firmware profile whose description declares no
cache, and the note says to import a cached description or to maintain
through `core/cache`'s cacheless provider (D972).

`core/io` has no `print`, `println`, `printf` or `puts`: one call writes a
template and its values to a file (D527). Asked for one of those, the note
shows that call spelt with the name the program reaches the module by,
`io.write_format(host, io.out(host), "{}\n", [any(addr x)]) else none`, with
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

An option is read only in fixed conditions, option defaults and compiler
assertions (D202) [1530], so a module value or a routine that reads one is
told the option is configuration-only. The note gives the way: declare the
value in each arm of a module-level `fixed if` whose condition reads the
option.

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
`hosted/heap` handle is `mem.allocate(memory, ...)`. When no public routine
forwards the entry, evidence still reaches it, and the note writes that
call: a routine generic over the concept, `(p: type is fibre.turns, value:
p)`, calls `p.start(value, ...)` and is given the value.

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
pass `addr name[0]`, since the literal ends in NUL (D442). An atom `else` on a
call that returns a plain pointer does not widen it into a union of several
atoms and that pointer (D235): the refusal names the one-atom union to
recover into, whose value widens into the larger one (D874).

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
its two notes give the tour paragraph and the form's standing, and a third,
where the checker knows one, the form to write instead (D761).

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
from the arguments, the third note names the binding to pass instead,
`values := [...]`, or `values: [N]E = [...]` when an element such as
`any(addr x)` needs a context, which an inferred binding does not give.
A struct literal passed to a parameter takes the parameter's type when its
fields are values; one with a reference field does not, and the third note
writes the binding to make and pass instead, `task: state = (host: host)`.

An `f32` or `f64` assembly operand [1630] is placed in a float register, and
a profile with no float registers, a Cortex-M with no float unit among them,
has none to place it in (D630). There a block takes integer operands only.

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
alive longer alone does not grant retention permission. A thread's instance
of `link(thread)` storage ends with its thread, so its address is not kept
in a module binding every thread reads (D772); keep it in a local or pass
it on as an argument.

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
borrows nothing, and [0810]'s conversion says so (D440). When the
alternative that derives from no named parameter is a module binding's
storage, the note names the binding: module storage needs no `from`, so
return it in a result of its own, or read and write it where it is chosen,
and a result that derives from no parameter is declared without `from`.

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
The refusal names the type and the concept as the program writes them,
`f64` and `text.formattable`, and for a concept that refines others, those
the type does conform to. An `any C` provides C and every concept C
refines, and no other (D492):
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
parameter [0980]; a static type argument names a value, a function or a
field rather than a type, bare or qualified by its module; a `caller` parameter is filled other than by forwarding
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
`else (problem)`. A failing call that ends a body with returns is read as the
routine's value [1080], and the refusal says so; its result is held to the
returns only once the failure is handled (D871). The hosted `main` takes no
`!` set [1970], so a `try` or an unhandled call there is not mended by
widening one: handle the failure with `else`, or move the work into a routine
whose set holds it and handle that call's failure in `main` (D872).

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
in the template names one operand. A naked body is exactly one block. The
text holds instructions, one a line, with no directive or statement
separator, a label only in a naked body (D598), and a comment only in the
target's own form: `@` on Cortex-M,
`//` on arm64, `#` on x86-64 and RV64 (D597). Its numbers are the
assembler's and take no digit separator, so `0x1800_0000` is written
`0x18000000`. Change the operand, register, template or text as the message
says, or move the operands into an assembly block. A pointer crosses as `usize(p)`, and the routine around
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
some are left (D434). A variant part takes no wildcard arm: its match names
every case, and the refusal names the cases the `_` was to cover, to be
listed in one arm, `full, spare:`, with no missing-case report for each
(D866). Variant payload names are positional and
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
the note names, at a position that takes it. A whole struct passed where a
parameter takes something else is named with its type beside the
parameter's, and the note names a field of the parameter's type to select
when the struct has one.

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
and the diagnostic then names the parameter as the cause (D381). A binding
that holds an anonymous function is a value, not a declared function, and
supplies no entry; the diagnostic names the binding and says to declare it
as a function.

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
operand the operation admits on this target. A refusal that names the target
is made only where the program reaches the call (D564): a builtin in an
imported routine nothing calls refuses nothing, and a module compiled with no
`main` reaches everything it holds.

A pointer the operation does not take is named as the program writes its
type. A `core/atomic` cell is not a scalar: it is read and written by its own
operations, `atomic.load` and `atomic.store` among them, and the refusal of a
builtin given one names them.

A `core/atomic` cell the target's atomics cannot carry is refused the same
way where the program uses it (D510): on Cortex-M0 and RV32 a `u64` cell,
and on Cortex-M0 and RV32 at `rv32imc` a cell's `exchange`, `add`,
`add_relaxed` and `compare_exchange`. On RV32 the read-modify-writes are the
level's (D690): build at `rv32imac`, with `--level=rv32imac` or the language
server's `level`, where the core has the A extension. A cell one context
alone writes adds with `atomic.sole_add`, a load and a store; state several
contexts write takes `platform/cortex_m`'s or `platform/riscv`'s critical
section.

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
[1580]. A target with no enabled C ABI yet, as RV32 and Xtensa have none, has
no C signature and lays out no `layout(c)` record, and the diagnostic says so
by the target's name; a byte-packed `layout(c, packed)` record needs no C
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
definition needs a generated adapter. Cortex-M's AAPCS32 calls no variadic C
function yet (D922): its refusal names the target, and the repair is a C
function of fixed arity that makes the variadic call, linked with the program
and declared `extern(c)` instead. Variadic calls take positional scalar,
pointer or fixed C callback tail arguments, without labels or static
arguments. Change `inout` or `sink` to `in`; pass a pointer if C must write
through a parameter. Remove `caller` and constraints, specialize generics,
represent errors through an ordinary C result, and combine multiple results
into one C-representable result. Pass a pointer to a by-value array or other
unsupported aggregate, or change the type or layout to one C represents.
Pass `ptr` to a packed record or one with a flexible member. A struct
declared without `layout(c)` has Landin's layout [0750], which C does not
share, so a signature taking or returning one by value, or a C record holding
one, is refused naming the part and the struct, as in "C cannot take
`tint`: `color` is not `layout(c)`", and the repair is to declare it
`layout(c) struct` (D529).

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
both (D441). A public naked or interrupt routine with no link name is a
global symbol under its own spelling, held to the same rule (D770): to make
a C import a naked routine's view (D516), give the routine the import's
`link(symbol: ...)`. `link(thread)` places a module `mut` binding that has no
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

The atom names are every value a fixed fact is compared with (D855),
including architecture, operating-system, byte-order and build-mode values.
The refusal's note lists the current names from the compiler's table. An
option of one of those names would be read in
the atom's place, so `compiler.os == linux` would compare a system with
the option. The refusal's note lists them.

```landin
option debug: u32 = 1
```

### L0391

A tool directive breaks [1510]/[1590]/D202 when it has other than one
positional argument, or when `linker.library` has an argument that is not a
quoted text literal with a portable library name, or `linker.directory` one
that is not a quoted, nonempty directory (D524). A `linker.directory` naming
a directory that does not exist is refused here too, before any tool runs,
by `refine check` as well: a relative directory is read against the
directory of the file that declares it. Give `compiler.assert` one fixed
bool expression.
Give `linker.library` one quoted text literal containing a portable library
name; its argument must have the required form and name characters. Give
`linker.directory` the directory that holds the library, relative to the
declaring file or absolute.

```landin
linker.library("-bad")
```

### L0398

A register image known at compile time violates its reserved-bit write policy
[0740] (D228). Supply zero in every unnamed bit for `write_zero`, or one in
every unnamed bit for `write_one`. A whole-image write cannot repair those
bits by reading the device. The image may fit its carrier type; L0300 instead
reports a value that its type or target cannot hold.

### L0399

A device description's directive has arguments that are not the forms its
row in D542 says: the wrong number of them, a text where an integer belongs
or the reverse, a name outside its spelling, a core, boot image kind,
placement or access the compiler does not know, an integer outside the
32-bit address space, a stack that is not a positive multiple of 8 bytes, or
a size given to a placement other than the stack's. The message says which
argument and the note how the directive is written, such as
`linker.region("FLASH", 0x1000_0000, 2 * 1024 * 1024, "rx")`.

```landin
compiler.device("RP2040")
```

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

### L0350

A float literal converted to an integer, `u64(1.0e18)`, has no type of its
own, so it is an `f32` [0210], and the conversion truncates the `f32`
(D171). Where that rounding changes the integer the conversion gives, or
whether it gives one, the conversion is refused (D760): `u64(1.0e18)` would
be 999999984306749440. The report names both integers. Write `f64(...)`
around the literal to convert its `f64` value, or `f32(...)` to keep the
rounding on purpose. A literal whose rounding gives the same integer, as
`i64(45.7)` does, is converted as written.

```landin
big: () -> (n: u64) =
    n = u64(1.0e18)
end big
```

### L0600

`compiler.utf8_unvalidated(bytes)` makes text of bytes without reading
them (D949), so it is admitted only where the program says it answers for
them: inside `unchecked begin ... end unchecked`. Bytes that are not UTF-8
then go unnoticed, and what reads them as text reads them wrongly. Where
the bytes come from input, convert them with `utf8(bytes)`, which traps on
malformed bytes, or `text.from_bytes`, which reports `invalid_text`. Where
they are valid by construction, because the program has just checked them
or wrote only whole scalars, put the call in an `unchecked` region.

```landin
trusted: (source: []u8) -> (result: utf8 from source) =
    result = compiler.utf8_unvalidated(source)
end trusted
```

## The backend and its toolchain

### L0500

The requested output cannot be made with the selected target, settings or
available toolchain [1550]. The diagnostic and its note identify the cause:
the target has no backend, its source debug mode is unsupported, firmware
forbids `linker.library`, `linker.directory` and `-L`, a static Linux link
cannot be made (no library holding `platform/linux` was found, or the program
asks for `linker.library`, `linker.directory` or `-L` (D524) or
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
Tools are refused before spawning when `SIGCHLD` is ignored or
`SA_NOCLDWAIT` would discard their exit status. Start refine with `SIGCHLD`
at its default disposition and `SA_NOCLDWAIT` clear. The refusal preserves
the inherited policy and keeps this corrective action ahead of long paths.

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

The program's static images exceed the image budget, which every target checks
before anything is emitted (D537). The budget counts every image the
compilation lowers, before section garbage collection, because the assembler
is given every one: what a program's public `main` reaches, and every module
value of a firmware image or an object. A firmware image is held to its
profile: its written images to the profile's flash and its mutable ones to its
RAM, 32 KiB and 16 KiB in the constrained reference profile. Any other image
is held to how far the target addresses static data: 2 GiB under x86-64's
small code model, Darwin's static image and RV64's AUIPC, 4 GiB under arm64's
ADRP, and the 32-bit address space on Cortex-M. Zero images, which take no
object bytes, are held only to the address space. The message gives what the
images take, the part of the budget they exceed and what sets it. Make the
static data smaller, or allocate it when the program runs; a value that is
zero until the program writes it reserves its bytes rather than writing them.

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
deepest path. When the handler's calls reach a foreign call, recursion, a
runtime helper or assembly that moves the stack, its depth cannot be known,
and the message names the opening's kind and points at it; a call through
`any`, a generic's table or a function value counts the deepest routine of
the program it can reach (D570), and opens the graph only when there is
none. Make the handler's frame
smaller, call less from it, or call through nothing that opens its graph; a
handler that only records the kind and switches away fits on every target.
A program with no `compiler.stack_prepare`, and one that selects no
handler, is not refused: the default report always fits. The rule is
decided from the frames the backend emits at the profile being compiled
(D474); `refine check` emits them in memory at its own profile, `none`
unless `--optimize` says otherwise, and `refine lsp` at `none`, so both
refuse what compiling at that profile refuses (D572).

### L0509

A link failed, and a library a `linker.library` directive asks for is in no
directory the link searched (D525): not in a directory `-L` or
`linker.directory` names, as `libNAME.so` or `libNAME.a` (on Darwin
`libNAME.tbd`, `libNAME.dylib` or `libNAME.a`), and not where the C driver's
`-print-file-name` finds its own. The message names the library at its
directive, every named directory with where it was named, and says that the
driver's own directories were searched as well. refine looks only after a
link has failed; a failed link whose libraries are all found stays L0501
with the linker's own text. Name the directory that holds the library with
`linker.directory("DIR")`, relative to the declaring file, or with
`-L DIR` when building, or install the library where the C driver finds it.

### L0513

A device description is not one module of its own directives (D542, D543): a
description directive stands in a module that names no device with
`compiler.device`, or inside a fixed arm, active or not; a description module
holds an import or a declaration other than its directives; a description
names its device, core, vector table or boot image kind twice, or none, names
an interrupt or IRQ twice, repeats a region's name, or places a part of the
image twice or not at all; or the program reaches a second description. A
program is built for one device, and selects it by importing its
description; write each directive once, beside `compiler.device`.

```landin
linker.region("FLASH", 0, 32 * 1024, "rx")
```

### L0514

A device description's parts do not fit together (D543): two regions
overlap, a placement names a region the description does not have or one
whose access does not fit, as code in an `"rw"` region or data in an `"rx"`
one, the vector table does not fit its region or would start unaligned, an
interrupt's slot lies past the vector table, the table is longer than the
core's architecture allows, or the stack is larger than its region. The
message names the region or the slot.

```landin
compiler.device("board")
compiler.core("cortex-m0plus")
compiler.vectors(48)
compiler.boot("vector-table")
linker.region("FLASH", 0x1000_0000, 2 * 1024 * 1024, "rx")
linker.region("RAM", 0x2000_0000, 256 * 1024, "rwx")
linker.region("MORE", 0x2000_2000, 16 * 1024, "rw")
linker.place("vectors", "FLASH")
linker.place("text", "FLASH")
linker.place("rodata", "FLASH")
linker.place("data", "RAM")
linker.place("bss", "RAM")
linker.place("stack", "RAM", 4 * 1024)
```

### L0515

A device description's core does not execute what the request builds
(D543): the target is not `cortex-m0`, or `--level` is above the core's own,
`armv6-m` for `cortex-m0` and `cortex-m0plus`, `armv7-m` for `cortex-m3`,
`armv7e-m` for `cortex-m4` and `cortex-m7`, and `armv8-m.main` for
`cortex-m33`. A lower M-profile level is accepted: a `cortex-m4` builds at
`armv7-m` or `armv6-m` too, and a `cortex-m33` at `armv7-m` or `armv6-m`,
though not at `armv7e-m`, whose DSP instructions its core may lack; a
description with a float unit builds at its unit's level alone (L0546).
Build with the target and a level the note names. The constrained reference profile, which applies when no
description is imported, is the one description used at every level.

```landin
-- refine: --target=cortex-m0 --level=armv7-m
compiler.device("board")
compiler.core("cortex-m0plus")
compiler.vectors(48)
compiler.boot("vector-table")
linker.region("FLASH", 0x1000_0000, 2 * 1024 * 1024, "rx")
linker.region("RAM", 0x2000_0000, 256 * 1024, "rwx")
linker.place("vectors", "FLASH")
linker.place("text", "FLASH")
linker.place("rodata", "FLASH")
linker.place("data", "RAM")
linker.place("bss", "RAM")
linker.place("stack", "RAM", 4 * 1024)
```

### L0516

Retired. A device description selected `esp-app-image`, a boot image kind
refine reserved and did not build (D545). D683 builds it, so nothing raises
this.

### L0517

A `link(region: "NAME")` placement cannot be met (D547): the selected
description has no region of that name, the declaration also names its
section, which a region placement chooses itself, or the region's access does
not hold it: a routine needs a region code runs in, and a mutable datum a
writable one. On a hosted target placement is refused as L0347 is.

### L0518

A firmware request, a vector placement or a region placement needs a device
profile, and none can be selected (D543): the program imports no
description, and the library refine found holds no
`platform/cortex_m/reference`, or no library was found. Import the device's
description, or name a library that holds the reference with
`--library=DIR`.

### L0519

A firmware image linked with `--linker-script=FILE`, or any RAM-layout
firmware image, breaks its checked layout contract (D546, D900). The
message names the clause: the
vector table at the description's boot address with its whole length, a
`_landin_firmware_*` startup symbol missing, the stack outside a writable
region of the description or of another size, or an initialized image whose
load address is not in the region text is placed in. A description-owned
initialization stage is the reset-vector entry when present. In RAM layout,
loaded sections must be in SRAM, their load and runtime addresses equal,
and their ranges clear of the reserved stack. Change the script so the
clause holds; the derived script refine writes beside the image as `OUT.ld`
meets every clause.

### L0525

`refine svd` read an SVD that is not XML in the subset it reads (D555). The
message says what was met and the line and column it was met at: bytes that
are not UTF-8, an end tag that does not close the element open, an attribute
given twice, an entity other than XML's five, a document type declaration,
or text outside the root element. An SVD is a vendor's file, fetched by its
hash and never edited; one that is refused here is not the file its policy
names, or is truncated. Fetch it again with `scripts/fetch_inputs.py`.

### L0526

`refine svd` cannot read its selection policy (D556): the policy is not JSON,
not schema 2, lacks a member it needs, names a member refine does not read,
or gives one of the wrong shape, such as a read policy other than `normal`,
`modify` or `refused`, or a mask that is not a `0x` 32-bit value. The message
names the member. A reviewer's notes belong under `provenance`, which is not
read. `devices/README.md` describes every member.

### L0527

The SVD `refine svd` was given is not the one its policy was reviewed against
(D556): its SHA-256, its device name or its version differs from the
policy's. A policy's access policies and corrections were reviewed for one
file, and a different file is not covered by that review. Fetch the SVD the
policy names, or review the policy against the new file and give its hash.

### L0528

A selected register of the SVD uses a form `refine svd` does not read
(D557): an array (`dim`) of peripherals, registers or fields, a register in a
`cluster`, a register or field derived from another, an `alternateGroup`, a
derived peripheral that adds registers or is derived from a derived one, a
width other than 32 bits, a default enumerated value or one with don't-care
bits, or a number with a multiplier. The message names the element and the
line it is at. Select registers that use the forms D557 lists, or extend the
importer.

An enumerated value whose name is not an ASCII letter followed by letters,
digits and underscores, such as RP2040's `1_15MHZ` or `2mA`, cannot be an
atom. Every selected field with one is named in a single refusal, each with
its first such name; list each in the policy's `numeric_enums`, which reads
the field as a plain number.

### L0529

The SVD describes a selected register in a way that cannot be generated as
it says (D557): two fields overlap, a field lies outside its register, an
enumerated value does not fit its field or encodes a value twice, a property
the register needs is given nowhere it inherits from, an address is not a
word-aligned 32-bit address, an alternate register is at another address, or
two vendor names become one Landin name once lowercased and joined. The
message names the element. Leave the register out of the selection, or
record a reviewed correction.

### L0530

The policy selects what the SVD does not have (D556): a peripheral, a
register, or a register's alternate. A register that is part of a `dim`
array is not found by its expanded name, and the message says so when the
peripheral has arrays. Correct the selection's spelling against the SVD.

### L0531

`refine svd` cannot prepare its output group (D558, D907): the output
root is missing, a link or not a directory; a destination is a directory or
link, or aliases a protected input; a retained publication needs recovery;
or the manifest names a file outside the output directory. Correct the
named path or manifest, or choose another `--out-dir`. For a retained
`.refine-publication-...` workspace, inspect its `destination-...` records
and recover the previous or new output before removing it and retrying.
Preparation can already have created private staging; later publication or
cleanup failures are L0005 and can leave recovered or retained versions.
Follow those recovery messages rather than assuming nothing was written.

### L0533

A `link(boot_stage)` marks something other than a device description's
second-stage boot routine (D587): a module binding, an ordinary routine or
an interrupt handler, or a naked routine that also names a section, symbol,
region, vector, alignment, `keep` or `thread`. A boot stage is
`link(boot_stage) extern(naked) NAME: () -> none`, whose body is the one
`assembler.block` the boot ROM enters, and the boot kind alone says where
it goes. Write the attribute alone on such a routine, or remove it.

```landin
-- refine: --target=cortex-m0
compiler.device("board")
compiler.core("cortex-m0plus")
compiler.vectors(48)
compiler.boot("rp2040-boot2")
linker.region("FLASH", 0x1000_0000, 2 * 1024 * 1024, "rx")
linker.region("RAM", 0x2000_0000, 256 * 1024, "rwx")
linker.place("vectors", "FLASH")
linker.place("text", "FLASH")
linker.place("rodata", "FLASH")
linker.place("data", "RAM")
linker.place("bss", "RAM")
linker.place("stack", "RAM", 4 * 1024)

link(boot_stage) stage: () -> none = end stage
```

### L0534

A `link(boot_stage)` routine is outside the device description the program
selects, or the program imports none and is given the constrained reference
(D587). The second stage is the device's, as its boot kind is, so it is
declared in the description's own module, beside `compiler.boot`. Move it
into the description's directory.

```landin
link(boot_stage) extern(naked) stage: () -> none =
    assembler.block("bx lr")
end stage

start: () -> none = end start
```

### L0535

A device description holds a stage, and its boot kind runs none (D587,
D653): an `rp2350-image-block` image begins with the vector table, which
the boot ROM finds through the image block, and runs nothing of the
description's before reset. An `rp2040-boot2` image begins with a second
stage, and a `vector-table` image may run one from its reset vector before
reset. Remove the routine, or select the boot kind that runs it.

```landin
-- refine: --target=cortex-m0 --level=armv8-m.main
compiler.device("board")
compiler.core("cortex-m33")
compiler.vectors(48)
compiler.boot("rp2350-image-block")
linker.region("FLASH", 0x1000_0000, 2 * 1024 * 1024, "rx")
linker.region("RAM", 0x2000_0000, 256 * 1024, "rwx")
linker.place("vectors", "FLASH")
linker.place("text", "FLASH")
linker.place("rodata", "FLASH")
linker.place("data", "RAM")
linker.place("bss", "RAM")
linker.place("stack", "RAM", 4 * 1024)

link(boot_stage) extern(naked) stage: () -> none =
    assembler.block("bx lr")
end stage
```

### L0536

A device description holds a second `link(boot_stage)` routine (D587). The
boot kind's slot holds one stage, which the boot ROM enters at its first
byte. The message names the first; remove one of them.

```landin
-- refine: --target=cortex-m0
compiler.device("board")
compiler.core("cortex-m0plus")
compiler.vectors(48)
compiler.boot("rp2040-boot2")
linker.region("FLASH", 0x1000_0000, 2 * 1024 * 1024, "rx")
linker.region("RAM", 0x2000_0000, 256 * 1024, "rwx")
linker.place("vectors", "FLASH")
linker.place("text", "FLASH")
linker.place("rodata", "FLASH")
linker.place("data", "RAM")
linker.place("bss", "RAM")
linker.place("stack", "RAM", 4 * 1024)

link(boot_stage) extern(naked) stage: () -> none =
    assembler.block("bx lr")
end stage

link(boot_stage) extern(naked) second: () -> none =
    assembler.block("bx lr")
end second
```

### L0537

A device description selects `rp2040-boot2`, whose image begins with a
second stage, and holds no `link(boot_stage)` routine (D587). Without one
the slot would hold no code, and the boot ROM would refuse its checksum and
stay in its USB boot mode. Add the stage to the description as a
`link(boot_stage) extern(naked)` routine of at most 252 bytes once
assembled, literals included; `devices/descriptions/rp2040/boot2.ldn` in
the repository is a port of pico-sdk's generic one.

```landin
-- refine: --target=cortex-m0
compiler.device("board")
compiler.core("cortex-m0plus")
compiler.vectors(48)
compiler.boot("rp2040-boot2")
linker.region("FLASH", 0x1000_0000, 2 * 1024 * 1024, "rx")
linker.region("RAM", 0x2000_0000, 256 * 1024, "rwx")
linker.place("vectors", "FLASH")
linker.place("text", "FLASH")
linker.place("rodata", "FLASH")
linker.place("data", "RAM")
linker.place("bss", "RAM")
linker.place("stack", "RAM", 4 * 1024)
```

### L0538

The assembled second stage cannot be sealed with the boot ROM's checksum
(D588). refine reads the `.boot2` section of the object the assembler wrote
before linking it: a section that is not 256 bytes means the stage and its
literal pool outgrew the 252 bytes before the checksum, and the message
gives their size; a relocation in the stage, or one elsewhere in the image
that refers to it, would make the bytes the boot ROM copies and runs at
another address differ from the ones summed, and the message names the
relocation and its symbol. Make the stage shorter, or write it with no
symbol outside itself and refer to it from nowhere.

### L0545

A device description names a float unit refine does not build, or one its
core cannot have (D615). A float unit is a fact of the core a chip was built
with, written in the description's hand-written half as
`compiler.float_unit("NAME")`, and refine builds one: `fpv5-d16`, the
Cortex-M7's single- and double-precision FPv5 with sixteen double
registers, on a `cortex-m7`. The note says which unit the description's
core may have. Write `compiler.float_unit("fpv5-d16")` in a Cortex-M7's
description, or leave the directive out: a core with no float unit
computes in software, as every other core refine builds for does.

```landin
-- refine: --target=cortex-m0 --level=armv7e-m
compiler.device("board")
compiler.core("cortex-m4")
compiler.float_unit("fpv5-d16")
compiler.vectors(48)
compiler.boot("vector-table")
linker.region("FLASH", 0, 1024 * 1024, "rx")
linker.region("RAM", 0x2000_0000, 128 * 1024, "rwx")
linker.place("vectors", "FLASH")
linker.place("text", "FLASH")
linker.place("rodata", "FLASH")
linker.place("data", "RAM")
linker.place("bss", "RAM")
linker.place("stack", "RAM", 4 * 1024)
```

### L0546

A device description has a float unit, and the request builds it at a
level whose architecture lacks that unit (D615). A float unit changes the C
ABI, single- and double-precision values travel in its registers, so code
built for the description assumes the unit, and the level that holds
`fpv5-d16` is `armv7e-m`. Build with the level the note names; a
lower level of the same core is accepted only for a description with no
float unit.

```landin
-- refine: --target=cortex-m0 --level=armv7-m
compiler.device("board")
compiler.core("cortex-m7")
compiler.float_unit("fpv5-d16")
compiler.vectors(48)
compiler.boot("vector-table")
linker.region("FLASH", 0, 1024 * 1024, "rx")
linker.region("RAM", 0x2000_0000, 128 * 1024, "rwx")
linker.place("vectors", "FLASH")
linker.place("text", "FLASH")
linker.place("rodata", "FLASH")
linker.place("data", "RAM")
linker.place("bss", "RAM")
linker.place("stack", "RAM", 4 * 1024)
```

### L0555

The assembled image block is not the IMAGE_DEF block an `rp2350-image-block`
image carries (D638). refine emits the block directly after the vector table
and reads the `.embedded_block` section of the object the assembler wrote
before linking it: the section must be the 20 bytes of one block linked to
itself, its start and end markers, one IMAGE_TYPE item of one word saying an
Arm executable for RP2350 that runs in Secure state, and the LAST item giving
that word, with no relocation in it. The message names the part that is
not. refine writes these words itself, so this is a defect of refine or of the
assembler it ran rather than of the program; report it with the message.

### L0560

A `vector-table` description's stage does not branch to compiler-owned
reset (D653). The reset vector enters the stage before reset has copied
the initialized data or cleared the zeroed, and the stage ends by entering
reset, `_landin_firmware_reset`, which it names: nothing else runs reset,
and a stage that falls off its end traps. Finish it with
`ldr r0, =_landin_firmware_reset` and `bx r0`, which reach reset from
anywhere in flash. On `rv32` the image's entry word enters the stage of an
`esp-app-image` or `vector-table` description (D684), and the stage ends
with `j _landin_firmware_reset`.

```landin
-- refine: --target=cortex-m0 --level=armv7e-m
compiler.device("board")
compiler.core("cortex-m7")
compiler.vectors(48)
compiler.boot("vector-table")
linker.region("FLASH", 0x0800_0000, 2 * 1024 * 1024, "rx")
linker.region("RAM", 0x2400_0000, 512 * 1024, "rwx")
linker.place("vectors", "FLASH")
linker.place("text", "FLASH")
linker.place("rodata", "FLASH")
linker.place("data", "RAM")
linker.place("bss", "RAM")
linker.place("stack", "RAM", 16 * 1024)

link(boot_stage) extern(naked) supply: () -> none =
    assembler.block("nop")
end supply
```

### L0561

A `vector-table` description's stage uses the stack (D653). The stage runs
before compiler-owned reset, on the stack pointer the core loaded from the
vector table, and before any memory may be written: a chip such as the
STM32H753 permits no write to its RAM until its supply is configured. The
message names the word that reaches the stack, `push`, `pop`, `sp`, `r13`,
`msp` or `psp`; on `rv32`, where reset has not yet set the stack pointer
when the entry word enters the stage (D684), `sp`, `x2` or a compressed
instruction that addresses through it, `lwsp`, `swsp`, `addi16sp` or
`addi4spn`. Keep what the stage needs in registers. Xtensa entry prepares
its window state, vectors and internal DRAM spill stack before its device
stage; that architecture's stage may use the prepared stack for windowed
ROM calls, while static storage remains uninitialized.

```landin
-- refine: --target=cortex-m0 --level=armv7e-m
compiler.device("board")
compiler.core("cortex-m7")
compiler.vectors(48)
compiler.boot("vector-table")
linker.region("FLASH", 0x0800_0000, 2 * 1024 * 1024, "rx")
linker.region("RAM", 0x2400_0000, 512 * 1024, "rwx")
linker.place("vectors", "FLASH")
linker.place("text", "FLASH")
linker.place("rodata", "FLASH")
linker.place("data", "RAM")
linker.place("bss", "RAM")
linker.place("stack", "RAM", 16 * 1024)

link(boot_stage) extern(naked) supply: () -> none =
    assembler.block("push {r0}\nldr r0, =_landin_firmware_reset\nbx r0")
end supply
```

### L0575

A device description's boot kind and its ESP chip facts disagree (D683).
An `esp-app-image` names the chip it is for and the revisions it runs on,
which the ESP32's ROM checks before it loads the image, and where in flash
the ROM reads it: a description that selects the kind writes
`compiler.esp_image(chip, min_revision, max_revision, flash_offset)` beside
`compiler.boot`, with the chip id ESP-IDF's `esp_chip_id_t` gives, the
revisions as major * 100 + minor, and the offset as a multiple of 4096. A
description with another boot kind has no use for the directive. Add the
facts the chip's technical reference manual gives, or remove the directive.

```landin
-- refine: --target=rv32
compiler.device("board")
compiler.core("esp-rv32imc")
compiler.vectors(32)
compiler.boot("esp-app-image")
linker.region("SRAM", 0x4038_0000, 256 * 1024, "rwx")
linker.place("vectors", "SRAM")
linker.place("text", "SRAM")
linker.place("rodata", "SRAM")
linker.place("data", "SRAM")
linker.place("bss", "SRAM")
linker.place("stack", "SRAM", 16 * 1024)
```

### L0576

A device description selects a boot image kind its core's family does not
boot (D681). An `rp2040-boot2` image begins with a second stage of Thumb
code that RP2040's boot ROM enters, so it is an Arm core's; an
`esp-app-image` is what an ESP32-C3's or ESP32-C5's ROM loads, so it is a
RISC-V core's. `vector-table` and `rp2350-image-block` serve both families.
Write the kind the core's boot ROM reads.

```landin
-- refine: --target=cortex-m0
compiler.device("board")
compiler.core("cortex-m0plus")
compiler.vectors(48)
compiler.boot("esp-app-image")
compiler.esp_image(5, 3, 199, 0x0)
linker.region("FLASH", 0x1000_0000, 2 * 1024 * 1024, "rx")
linker.region("RAM", 0x2000_0000, 256 * 1024, "rwx")
linker.place("vectors", "FLASH")
linker.place("text", "FLASH")
linker.place("rodata", "FLASH")
linker.place("data", "RAM")
linker.place("bss", "RAM")
linker.place("stack", "RAM", 4 * 1024)
```

### L0577

The linked executable cannot become the ESP application image an
`esp-app-image` description asks for, or the image refine wrote does not
read back as it was made (D685). refine writes `OUT.bin` from the linked
ELF's loaded segments: every one must lie in a region of the description,
there may be at most 16, and the image's entry must be
`_landin_firmware_entry`. After writing it refine reads the file again and
holds its header, extended header, segments, checksum and SHA-256 to the
executable; the message names the first that is not. A segment outside the
description's regions comes from a developer's linker script or an object
of a developer's own; the read-back is a defect of refine or of the host's
filesystem, so report it with the message.

### L0578

A routine placed in RAM, `link(section: ".ramtext.NAME")`, has nowhere to
run (D688). Reset copies RAM code into the description's data region, so
that region must be one code runs in, `"rwx"`; an `esp-app-image` places
its RAM code with its text instead, which the ROM already loaded into RAM.
A data region that is `"rw"`, as the ESP32-C3's data-bus alias of its
SRAM is, would hold bytes the core cannot fetch, and the first call would
fault. Place the routine in `.text`, or in an executable region of the
description with `link(region: "NAME")`.

### L0579

`refine bindings` cannot read its policy (D820): it is not UTF-8 JSON, names
a key twice, is not schema 1, lacks a key it needs or names one refine does
not read, gives one of the wrong shape, or binds for another ABI than
`--target` names, a data model or calling convention among them, which
`cortex-m0`'s policy must name (D935). The message names the key or the declaration. A policy's
every key is described in the
[binding policy reference](../bindings/README.md). With an installed compiler,
run `refine help bindings` for the address of its generated reading copy.

### L0580

The Clang `refine bindings` was given cannot be used as asked (D820): it
cannot be run, a root it is given is not a directory, it failed, and the
message carries its error output with the request's paths replaced by
names that do not depend on where it ran, or it describes another ABI than
the target's: another triple, data model, byte order, sign of plain
`char` or, on Cortex-M, procedure call standard, float unit, enum size or
hosted environment (D935). A header reached through an absolute path under none of the roots
the request names is refused too, since what is generated could then depend
on where it was. A relative dependency that escapes Clang's retained
workspace, even if it reenters, is also refused: its external directory
authority cannot be retained by normalizing the path. Use an absolute
include under a declared root, or name the header through `--include-dir`.
Name the pinned Clang with `--clang`, and every root a header needs with
`--include-dir` or `--system-include-dir`.

An incompatible child-exit signal policy also refuses Clang before it starts:
use the default `SIGCHLD` disposition with `SA_NOCLDWAIT` clear, as L0501
explains.

### L0581

A declaration the policy selects cannot be bound (D820), and the message
names the policy declaration and the position: the header no longer has it
(a stale policy), a reference position has no policy or a scalar one has
one, or the declaration uses a form `bindings/README.md` lists as refused,
such as an extended floating type, a calling convention attribute, an
anonymous aggregate or a wrapper that would forward a C variadic tail, or,
on freestanding `cortex-m0`, a nullable callback or a `_Thread_local` object,
whose adapters need a C library (D938). A
Landin name two declarations would share is refused here too. Correct the
policy, or select another declaration.

### L0582

`refine bindings` cannot prepare its output group (D820, D907): the output
root is a symbolic link or not a directory, an output is a directory or link,
an output aliases a protected header, policy, response file or selected tool,
or an earlier publication needs recovery. Correct the named path or choose
another `--out-dir`. Keep a named `.refine-publication-...` workspace until
its `destination-...` records and retained previous or new outputs have been
inspected and recovered; remove it only after recovery. Preparation can
already have created private staging. A later publication or cleanup failure
is L0005 and can leave outputs installed or recovery entries retained, as
that diagnostic reports.

### L0587

A firmware image linked with C archives, through `linker.library` with
`linker.directory` or `-L DIR`, holds something compiler-owned startup cannot
honour (D923, D924). Reset copies data, clears BSS and calls the firmware
entry; it runs no C constructor, has one thread and no thread pointer, and
loads nothing at run time. So the image is refused, and removed, when an
archive brought C constructors, an `.init_array`, `.preinit_array` or
`.ctors` section that the derived script keeps so that it cannot be dropped
unseen; thread-local storage, a `.tdata` or `.tbss` section from a
`_Thread_local` or `__thread` variable; or a dynamic linkage, which a shared
object would bring. The message names the section. Build the library without
constructors and call its initialisation from the firmware entry; declare a
thread-local variable as ordinary static data; and link the library's static
archive built for the firmware's core.

### L0610

A device description names a cache refine does not build, or one its core
cannot have (D971). A cache is a fact of the core a chip was built with,
written in the description's hand-written half as
`compiler.cache("KIND", LINE)`, and refine builds one kind:
`armv7-m-l1`, Armv7-M's level 1 instruction and data caches with the
maintenance operations of the System Control Block, which among the cores
refine builds for only a `cortex-m7` has. A description that declares it
is a cached profile: reset enables the caches and the entry's return
disables them (D973), and `platform/cortex_m` declares its maintenance
provider there. Write `compiler.cache("armv7-m-l1", 32)` in a
Cortex-M7's description, or leave the directive out for a cacheless
profile, whose DMA buffers need no maintenance.

```landin
-- refine: --target=cortex-m0 --level=armv7e-m
compiler.device("board")
compiler.core("cortex-m4")
compiler.cache("armv7-m-l1", 32)
compiler.vectors(48)
compiler.boot("vector-table")
linker.region("FLASH", 0, 1024 * 1024, "rx")
linker.region("RAM", 0x2000_0000, 128 * 1024, "rwx")
linker.place("vectors", "FLASH")
linker.place("text", "FLASH")
linker.place("rodata", "FLASH")
linker.place("data", "RAM")
linker.place("bss", "RAM")
linker.place("stack", "RAM", 4 * 1024)
```

### L0611

A device description's cache names a line that is not its core's (D971).
The line is the unit every maintained range is a whole number of, and
`core/cache` refuses a range that is not, so a description that said
another would let a program align its DMA buffers to lines the hardware
does not have. A Cortex-M7's `armv7-m-l1` lines are 32 bytes, as its
CCSIDR says for both caches; write `compiler.cache("armv7-m-l1", 32)`.

```landin
-- refine: --target=cortex-m0 --level=armv7e-m
compiler.device("board")
compiler.core("cortex-m7")
compiler.cache("armv7-m-l1", 64)
compiler.vectors(48)
compiler.boot("vector-table")
linker.region("FLASH", 0, 1024 * 1024, "rx")
linker.region("RAM", 0x2000_0000, 128 * 1024, "rwx")
linker.place("vectors", "FLASH")
linker.place("text", "FLASH")
linker.place("rodata", "FLASH")
linker.place("data", "RAM")
linker.place("bss", "RAM")
linker.place("stack", "RAM", 4 * 1024)
```
