# The Ada bootstrap compiler

This directory holds the bootstrap implementation described by `ROADMAP.md`.
It is a real compiler under construction, not a prototype: `spec.md` is the
normative language specification and `tour.md` explains the language, and
nothing here may quietly decide language semantics.

## Layout

```
compiler/ada/
  landin_common.gpr     build policy: language version, warnings, modes
  landin_lib.gpr        the compiler library, built by everything else
  refine.gpr            the `refine` executable
  landin_tests.gpr      the repository's own test program
  TOOLCHAIN.md          the pinned toolchain and warning policy
  src/
    base/               the root package and the exceptions
    source/             source snapshots, spans, line maps, provenance
    diagnostics/        diagnostic transport and text rendering
    platform/           host adapters and their native implementations
    stages/             target facts and the stage/pipeline seams
    syntax/             the tokens, the scan, the syntax table and the parse
    resolution/         declarations, scopes and what each name means
    checking/           the language's types, what each node has, and the IR
    backend/            the frame, and the assembly emitted against it
    driver/             the request/result boundary
    main/               the `refine` entry point
  tests/src/            the harness, the fakes and the suites
```

`compiler/tests/` sits outside this directory on purpose. Fixtures describe
the language, not this implementation, and must survive the bootstrap being
replaced.

## Package ownership

| package | owns | must not |
|---|---|---|
| `Landin` | the namespace and the three exceptions | contain any logic |
| `Landin.Source` | immutable snapshots, byte offsets, spans, line maps | read a file, or know an encoding beyond bytes |
| `Landin.Source` storage | heap-allocated text and line maps, never freed while the process lives | put a source file in an automatic object |
| `Landin.Source.Sets` | a compilation's snapshots and their identities | acquire bytes from a host |
| `Landin.Provenance` | origins and the declaration side table | know what a declaration means |
| `Landin.Source.Names` | identities for the byte runs a program names | know that a spelling is reserved |
| `Landin.Tokens` | the lexical vocabulary, the token, the fault, the stream | render prose, assign a diagnostic code, or build a token |
| `Landin.Tokens.Lexer` | the scan, and the only construction of a token | know what a token means |
| `Landin.Syntax` | the node table, extents, anchors, origins, soundness | know that types or IR values exist, or hold a diagnostic |
| `Landin.Syntax.Precedence` | [1820] as data: levels, operators, folds, first sets | contain a parsing decision |
| `Landin.Syntax.Parser` | the parse, and the only construction of a tree | assign a diagnostic code, or read a byte |
| `Landin.Syntax.Dump` | a canonical text for a tree | be a stable interface or a serialisation |
| `Landin.Syntax.Forest` | one tree per source for the whole compilation, on the heap and never freed | hand out a tree that can be copied or written to |
| `Landin.Resolution` | declarations, scopes, and which declaration each name means | hold a diagnostic, or decide what a name may be called |
| `Landin.Types` | the eleven scalar names, their widths, and ordinary storage size against a target | hold a machine fact of its own, or ask the host for one |
| `Landin.Checking` | what type every node and declaration has, including a nominal aggregate's identity and scalar/fixed-array declared layout | decide a rule, or ask the host for a width |
| `Landin.IR` | the target-neutral instructions: items, slots, blocks, values, an aggregate datum or slot's scalar or compact fixed-array fields, the same neutral shapes in a separate measurement run, and the only construction of one | hold a scope tree, name a machine, ask a width, or hold an offset |
| `Landin.Backend` | where a routine's cells live, the target extent of one neutral field shape, where a scalar field sits inside an aggregate datum or slot, and the layout of a scalar/fixed-array field run, counted in target bytes | name a machine, choose a register, or ask the host a width |
| `Landin.Backend.X86_64` | the assembly text for one target, and every register in it | decide a layout, write a file, or run a tool |
| `Landin.Backend.Toolchain` | the one command line that finishes a compilation, and the triplet it is found by | know what ELF is, invoke a linker directly, or search a PATH |
| `Landin.Backend.Entry_Point` | [1970]'s one hosted entry shape, asked of the IR | raise a defect for a module that simply has no `main` |
| `Landin.Diagnostics` | codes, severities, labels, notes, ordering | render, or own the catalogue of codes |
| `Landin.Diagnostics.Text` | deterministic rendering | decide severity or ordering policy |
| `Landin.Diagnostics.Catalogue` | every diagnostic code, and what each requires of its occurrences | hold a message, or a code nothing raises |
| `Landin.Diagnostics.Lexical` | turning a scanner fault into a diagnostic | invent a code, or a roadmap item |
| `Landin.Diagnostics.Syntactic` | turning a parse failure into a diagnostic, and naming the constructs only the parser can meet | invent a code, a construct, or a roadmap item |
| `Landin.Diagnostics.Resolution` | turning a duplicate or an unknown name into a diagnostic | invent a code, or attach a sentence to no place |
| `Landin.Diagnostics.Checking` | turning a type that does not agree into a diagnostic | invent a code, a construct, or a roadmap item |
| `Landin.Platform` | the host interfaces every effect goes through | perform an effect |
| `Landin.Platform.Native` | the only filesystem implementation | be reached except through the interface |
| `Landin.Platform.Native.Tools` | the only process spawning, and the only GNAT-specific dependency | grow a second host concern |
| `Landin.Targets` | target facts and layout arithmetic | ask the host how wide a pointer is |
| `Landin.Stages` | the compilation context, the stage interface, pipelines, and everything a stage builds that outlives it | know which stages exist, or which order they run in |
| `Landin.Stages.Syntax` | running the scan and the parse over a compilation | keep anything of its own, or decide reporting policy |
| `Landin.Stages.Resolution` | the order the trees are walked in | own the resolution table, or a code |
| `Landin.Stages.Checking` | the three type passes and the assignment walk | own a table, a code, or a width |
| `Landin.Stages.Lowering` | the walk that builds the IR, and refusing to run on a refused program | own the Unit, work out a scope, or raise a diagnostic |
| `Landin.Driver` | argument classification and the result | implement a language rule |
| `Refine` | printing and the exit status | contain a decision |

Public specifications stay narrow, and a representation is private wherever a
caller could otherwise assemble a value the package would not have produced:
`Landin.Targets.Target_Facts` is private because a description must come from
a named target, not from a record literal that happens to describe the
development host. Where a type is limited, that is deliberate too: a
compilation cannot be copied out from under its stages.

A snapshot's bytes and line map are allocated once and not freed. A
compilation owns its sources for as long as it exists, the process is short,
and a compiler that frees source text while a diagnostic still points into it
has traded a leak for a dangling span. That is a decision, not an oversight;
when the roadmap needs a longer-lived process it will be revisited there. R1.50
extends it to the trees for the same reason, and to the four tables a
compilation now owns.

A compilation owns everything a stage builds that outlives the stage that built
it: the interned identities, the declaration sites, the trees, and what every
name in them means. Two facts about the seam decide that it has to be there
rather than in a stage. `Run` takes `Item` as an `in` parameter of a limited
interface, so a stage cannot keep anything in itself; and `Stage_Reference` is a
library-level access type, so a stage object cannot be a local of one
compilation either — `Append (Line, Local'Access)` on a local instance is
rejected as "non-local pointer cannot point to local object". The price is that
`Landin.Stages` gains one `with` clause per representation as the roadmap adds
them. The line that keeps it a seam is exact: this package may depend on a
representation and may never depend on a stage. Ada enforces that for the
specification only — a parent's spec may not `with` its own child — and a
parent's *body* may, so `landin-stages.adb` growing a `with
Landin.Stages.Syntax` to build a default pipeline is how the rule would
actually be broken. Nothing but the rule stops it, and `Landin.Driver` is
what owns the pipeline.

## What is deliberately absent

`Landin.Backend` lays out a routine's frame and
`Landin.Backend.X86_64` emits assembly for the current scalar kernel: literals,
truths, slot traffic, checked and wrapping add, subtract and multiply,
division, remainder, negation, complement, logical not, the three bitwise
operators, both shifts, comparisons, calls, jumps, branches, returns, and
module values as folded data reached by name. That is every opcode `Landin.IR`
spells, so the case that dispatches them is exhaustive: a new opcode fails to
compile rather than raising `Compiler_Defect` at run time. What it cannot do
is pass a seventh argument: [1650] hands six in registers and the stack half
is not written, so the driver refuses a wider routine as `L0503` before
anything is emitted rather than letting an accepted program meet an internal
defect. `ROADMAP.md` R4.40 owns the stack arguments that retire it.

What is reachable is the path around it. `--emit=asm` writes the assembly and
`--emit=exe` assembles and links it through the driver
`Landin.Backend.Toolchain` names, so a constant-return `main` runs and exits
with its own `code`. The assembly half is host-independent by the rule that
nothing outside `Landin.Targets` may ask the host anything: emitting for
`linux-x86-64` produces identical bytes on macOS and on Linux. The finishing
half is not, and says so — a host without the target's triplet-prefixed
driver reports `L0500` rather than reaching for whatever `gcc` names, which
on macOS would hand ELF-only assembly to a toolchain that emits Mach-O.

The `Runtime` fixture class compiles programs, links them, runs them on the
target and checks their statuses. The Linux gate therefore proves literal
return, checked arithmetic across every fixed integer width, wrapping add,
subtract and multiply across signed and unsigned boundaries, signed and
unsigned division and remainder, the unary and bitwise operators, shifts
within and beyond the width, calls that carry six arguments and recurse,
folded module values and module state a function updates, and
comparison-driven control flow on the
hardware the backend emits for. A
host without the target toolchain fails
rather than silently skipping that evidence. `ROADMAP.md` R1.80 owns the
remaining backend work.

What does exist behind it is the whole frontend: `refine` scans and parses
every `.ldn` file it is given, resolves every name in them as one module,
checks the type of everything and that every name is assigned before it is
read, reports what none of the four could read, lowers every function it
accepted into `Landin.IR`, verifies it and can dump it.

A width is a function of a type and a target description, never a property of
either alone, and `Landin.Types.Width` is the only place one is formed.
`usize` is [0160]'s pointer-width integer, so it is as wide as
`Landin.Targets.Pointer_Width` says and no wider — which is how a 32-bit
target description stays 32-bit on a 64-bit host. A literal's value is held in
`Landin.Types.Magnitude`, whose bound is written out as `2 ** 64 - 1` because
that is a fact about `u64`; a host width leaking in would be
`Long_Long_Integer`, whose range is a fact about the machine running the
compiler.
`L0001` is retired — the catalogue said it retires when the frontend is wired
to the driver, and R1.40 is where that happened — and its row stays so its
number is never handed to another rule.

Both halves are held to the grammar from both sides. `check.py` compares
`Landin.Tokens`' reserved words with the tour's own `keyword` production,
derives every positive program in the corpus from the grammar and refuses
every negative one the frontend rejects, and compares
`Landin.Syntax.Precedence` with [1820]'s own
levels, operators, fold and first sets. The harness lexes every program in the
corpus and compares each token with what `check.py`'s independent tokeniser
produced, parses every one and requires the same verdict `check.py` reached,
and parses every truncation of every one to prove that a half-written file
yields a tree and not a crash.

`Landin.Syntax` is a flat table, not a pointer structure: a `Node_Id` is a
dense integer, so R1.50's names, R1.60's types and R1.70's values each go in
an array of their own rather than a map keyed on an access value. R1.50 is the
first to take that up, and it does it once for the whole compilation: one array
of `Declaration_Id` with one run per source and a first index, which is what
`Landin.Syntax` already does with a node's children. A child's
index is lower than its parent's and a child's extent lies inside it, both as
postconditions. A construct the parser could not read becomes an error node of
the band it needed — one per band, so a case over a band still covers the
hole — and `Is_Sound` propagates upward so that one syntax mistake does not
become a cascade of type errors about a hole. Trees live in the compilation's
`Landin.Syntax.Forest`, one per source and none freed, which is R1.50's answer
to where they live: a tree cannot be an element of a container, because it is
limited with unknown discriminants, and an initialised allocator whose value is
the parse is the one form Ada gives for building one where it will outlive the
call.

A diagnostic code is written in exactly one place, `Landin.Diagnostics.Catalogue`, and `check.py` refuses a code literal anywhere else in `src/`. Each column of the catalogue is an exhaustive case over the code names, so a code with no row is a missing-case error rather than a warning. The catalogue holds no prose: `L0003` is raised with two sentences, for a source that is missing and one that cannot be read, because one rule was violated and the difference between them is wording. What a code requires of every occurrence — a source, a non-empty span, how many secondary labels, how many notes — is in the row, and `Landin.Diagnostics.Lexical` checks the row against the diagnostic it just built.

`Landin.Tokens` knows two things the kernel grammar does not, both on
purpose. A band of deferred lexemes — `1.5`, `"text"`, `+=`, `!` — is read
as one token each so that `[1830]` can refuse a construct by name instead of
reporting a stray byte, and so that enabling one later cannot change how a
file that never used it was read. Every deferred kind names the tour
construct it belongs to, and `check.py` holds it to naming one that exists
and to not being a lexeme the grammar already spells.

The stage seam is one interface and one pipeline, contract-tested with fake
stages. Named per-stage packages arrive as each stage is written, which is
what keeps the seam a seam rather than an empty directory tree with
aspirational names in it.

## Building

See `TOOLCHAIN.md`. From the repository root:

```sh
./scripts/build.sh
./scripts/test.sh
```
