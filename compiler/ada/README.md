# The Ada bootstrap compiler

This directory holds the bootstrap implementation described by `ROADMAP.md`.
It is a real compiler under construction, not a prototype: `spec.md` is the
normative language specification and `tour.md` explains the language, and
nothing here may quietly decide language semantics.

## Layout

```text
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
    stages/             target facts, fixed-configuration activity and seams
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
| --- | --- | --- |
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
| `Landin.Types` | the scalar names and value categories, their widths, and ordinary scalar storage size against a target | hold a machine fact of its own, or ask the host for one |
| `Landin.Checking` | what type every runtime node and declaration has, including concrete parameterized-alias application shapes and D136's canonical folded array counts but no template/formal syntax metadata; opaque checker-owned nominal instances interned by source template and an ordered normalized scalar, structural atom-set, exact fixed-array, nominal, structural function-signature or mathematical fixed-value actual tuple, with descriptor keys bound to their limited compilation table and bounded typed traversal of each stored tuple; every enabled nonparameterized struct is its template's canonical empty tuple, while D137's structs separate identity-only function/type-actual mentions from by-value field/payload/array edges for both parameterized instances and canonical empty-actual ordinary structs, following ordinary nominal aliases without forcing layout; retain transient nonconcrete nominal obligations for unused-template recursion checks, reconstruct interned concrete bindings to promote nested nominal and nominal-array descriptors lazily at value uses, and build one selected-target layout per canonical instance without mutating their template; per-instance unseen/building/ready/invalid layout state, with bounded invalid-layout replay for each application-local diagnostic; structural atom/error sets, fixed-array and anonymous result shapes, aggregate element identity, recursive first-class target-neutral function signatures on values and aggregate fields, ordered result runs, and target-dependent scalar/fixed-array/unfolded-variant/recursively nested ordinary runtime layout kept outside target-independent nominal keys | decide a rule, execute user code, synthesize a source declaration, mutate a template, or ask the host for a width |
| `Landin.Cleanup` | target-neutral exit kinds and the defer/undo applicability policy | parse a cleanup, track definite assignment, emit a call, or name a target |
| `Landin.IR` | the target-neutral instructions: items, slots, blocks and values; a deterministic IR-owned nominal identity map retaining each checker instance's source template without making an item; atom-set descriptors, atom identities, orthogonal call-failure slots and failure exits; recursive callable signature descriptors with ordered result runs on declared or anonymous routines, static function datums, code addresses, function-value slots, nominal aggregate storage, aggregate fields and calls; scalar, compact fixed-array, unfolded variant, anonymous result and recursively nested ordinary shapes carrying nominal child and element identity; recursively indexed folded aggregate images, routine relocations and compact child/payload segments; arbitrary-depth neutral paths through contextual, variant and indexed-element operations; and checked internal addresses for whole aggregate elements at computed indexes | hold a scope tree, name a machine, ask a width, synthesize a declaration, or hold an offset, register or padding byte |
| `Landin.IR.Verifier` | release-build well-formedness of a completed Unit, including atom/error set membership, descriptor/carrier, multiple-result slot and static function-image agreement, call-failure slots and exits, valid neutral subobject paths and recursive image descriptors, plus target-aware fit of every static fold | diagnose source, repair malformed IR, or choose backend policy |
| `Landin.IR.Dump` | canonical human-readable text for a Unit | be a stable interface, a reader, or a serialisation |
| `Landin.Backend` | where a routine's cells live, the recursive target extent of one neutral field shape, where a scalar or fixed-array leaf at any path depth sits inside an aggregate datum or slot, how wide one element of an array of either is, and the target-byte replay of scalar, fixed-array and unfolded variant runs | name a machine, choose a register, or ask the host a width |
| `Landin.Backend.X86_64` | the assembly text for one target, every register in it, and the target-width scalar, finite-array, compact repetition, nested-child and selected-variant directives and padding for recursively written aggregate images | decide a layout, write a file, or run a tool |
| `Landin.Backend.Toolchain` | the one command line that finishes a compilation, and the triplet it is found by | know what ELF is, invoke a linker directly, or search a PATH |
| `Landin.Backend.Entry_Point` | [1970]'s one hosted entry shape, asked of the IR | raise a defect for a module that simply has no `main` |
| `Landin.Diagnostics` | codes, severities, labels, notes, ordering | render, or own the catalogue of codes |
| `Landin.Diagnostics.Text` | deterministic rendering | decide severity or ordering policy |
| `Landin.Diagnostics.Catalogue` | every diagnostic code, and what each requires of its occurrences | hold a message, or a code nothing raises |
| `Landin.Diagnostics.Lexical` | turning a scanner fault into a diagnostic | invent a code, or a roadmap item |
| `Landin.Diagnostics.Syntactic` | turning a parse failure into a diagnostic, and naming the constructs only the parser can meet | invent a code, a construct, or a roadmap item |
| `Landin.Diagnostics.Resolution` | turning a duplicate or an unknown name into a diagnostic | invent a code, or attach a sentence to no place |
| `Landin.Diagnostics.Checking` | turning a type that does not agree or a checker-recognised deferred use into a diagnostic, including the refused-type table and L0304 ownership | invent a code, a construct, or a roadmap item |
| `Landin.Platform` | the host interfaces every effect goes through | perform an effect |
| `Landin.Platform.Native` | the only filesystem implementation | be reached except through the interface |
| `Landin.Platform.Native.Tools` | the only process spawning, and the only GNAT-specific dependency | grow a second host concern |
| `Landin.Targets` | target facts, typed architecture identity and layout arithmetic | ask the host how wide a pointer is |
| `Landin.Targets.Capabilities` | which described targets have a backend and the triplet selected to finish their output | infer capability from width, invoke a tool, or canonicalise a triplet |
| `Landin.Configuration` | D138's immutable active-declaration view after target selection | mutate syntax, resolve a source name, or expose a general compiler module |
| `Landin.Stages` | the compilation context, the stage interface, pipelines, and everything a stage builds that outlives it | know which stages exist, or which order they run in |
| `Landin.Stages.Syntax` | running the scan and the parse over a compilation | keep anything of its own, or decide reporting policy |
| `Landin.Stages.Configuration` | validate and select D138 fixed declaration arms before resolution | execute code, mutate syntax, or add a runtime declaration |
| `Landin.Stages.Resolution` | the order the trees are walked in through the activity view | own the resolution table, or a code |
| `Landin.Stages.Checking` | the three type passes, compile-time-only positional substitution, D136's closed target-independent fixed-expression evaluator, scalar/fixed-array normalization of parameterized aliases, symbolic validation of unused nominal templates, canonical `(template, normalized actual tuple)` struct interning, identity-only versus value-layout requirements for generic and ordinary signature recursion, ordinary alias-chain identity lookup, transient symbolic nominal obligations across used-formal wrappers, lazy recursive promotion from interned concrete actual tuples, substituted per-instance layout, bounded repeated-invalid replay, D137/L0313 by-value recursion separation, and checking-stage diagnostic order | own a table, a code, execute user code, synthesize a declaration, or choose a target-dependent operator width |
| `Landin.Stages.Checking.Flow` | definite assignment, explicit fallthrough/return-compatible edge facts, and lexical cleanup execution states | decide a type, believe a condition, or lower a value |
| `Landin.Stages.Lowering` | the walk that eagerly maps checker nominal identities into deterministic IR order, then builds and verifies the IR without creating items for type templates; including caller-owned scalar and shaped control joins, checked computed-element address slots, plus reverse-order cleanup calls on selected exits, and refusing to run on a refused program | own the Unit, work out a scope, derive target layout, synthesize a declaration, or raise a diagnostic |
| `Landin.Driver` | argument and `--emit` classification, pipeline orchestration, output/toolchain selection and the result | implement a language rule |
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
`Landin.Backend.X86_64` emits assembly for every operation in the enabled
kernel: scalar constants and arithmetic, expression-valued non-loop control
flow and calls; module and
local fixed-array indexing, copying, clearing and filling; and recursively
nested ordinary structs with scalar, fixed-array, ordinary-child and unfolded
variant fields, contextual construction, inspection, whole copies and clears,
and arbitrary-depth scalar, array, child, payload and known- and
computed-element paths. A computed whole aggregate element is bounds-checked
once and retained as an internal shaped address; it remains a
source value/place rather than exposing a pointer.
Folded module images recursively contain ordinary-child and ordinary-payload
images in a neutral descriptor tree; only the selected target supplies their
widths, offsets and padding. That is every
opcode `Landin.IR`
spells, so the case that dispatches them is exhaustive: a new opcode fails to
compile rather than raising `Compiler_Defect` at run time. R2.30's internal
scalar convention passes six arguments in registers and every later one in an
aligned run of eight-byte stack slots, so `L0503`'s former register-only limit
is retired. A flat ordinary-struct or fixed-array argument occupies one such
position as an internal address and is copied into independent shaped callee
storage before the body runs; a direct field or depth-one child path preserves
its neutral field identities on that address, contextual `zeroed` clears a
fresh shaped caller temporary, array literals or repetitions fill one in
source order with compact suffix fills, and flat struct construction fills one
by nominal scalar, fixed-array or variant labels. Variant-bearing storage and
constructed temporaries retain compact case and payload shapes across the copy;
a complete depth-one ordinary child and its literal construction retain their
nested field runs as well. Struct and fixed-array results use a hidden
destination pointing to caller-owned shaped storage and copy from an independent
named-result slot on leave; runtime evidence covers flat, variant-bearing and
depth-one nested struct shapes. Matching calls can fill typed locals, direct or
field-qualified assignments, and named returns without an aggregate SSA value;
a local can infer that returned nominal body or array shape as well. Calls can
also feed returned storage directly into a matching aggregate argument, or run
to completion in a shaped temporary before explicit discard. An `if`,
exhaustive `match`, or bare `begin` block can produce a scalar, fixed-array or
currently enabled aggregate value, or a function value with its recursive
signature. Explicit fallthrough and return facts make only continuing arms
fill one consumer-owned neutral join slot; returning arms use the ordinary
named-result exit, and no condition is believed. A typed binding, assignment
or return supplies storage directly, while an argument or discard owns a fresh
shaped temporary. Every aggregate argument and result context enabled by the
kernel uses that internal convention; R4.40 later completes the separate C ABI
classification. Inferred and explicitly typed local or module function values
are represented by target code addresses and called through verified
`Indirect_Call` IR. A first-class recursive neutral descriptor, not a concrete
callee item, carries each complete signature through checking, routine and
static-datum items, address values, slots and calls. Mutable replacement
requires an agreeing signature; function-valued parameters and named results
occupy one ordinary code-address carrier and share aggregate-result and
stack-argument conventions. Two or more signature results form one anonymous
structural aggregate: its ordered fields retain names for whole binding,
selection and by-name destructuring, while function-value agreement ignores
those labels and compares the ordered types. One hidden caller destination and
one callee result slot carry it through direct, indirect, early-return and
control-expression paths. Static module chains resolve to one declared or
anonymous routine address and have no implicit zero image. A no-capture
anonymous function sees the module and its own signature/body declarations,
lowers to a deterministic routine item and receives a backend-local symbol.
Function-valued ordinary and variant-payload fields retain that descriptor and
one `usize` carrier through construction, assignment, whole copies, nested and
indexed aggregate paths, caller-owned ABI storage and indirect calls. Static
aggregate images carry verified routine relocations, and a containing aggregate
has no implicit zero image when its active zero shape contains a function.
Atom declarations and
unions are structural declaration-identity sets carried as ordinary values.
Concrete error sets are part of recursive function signatures; private `! ...`
routines are solved as a whole-module least fixed point before lowering. Direct
and indirect failing calls keep their successful scalar, function or caller-
owned aggregate convention and add one neutral failure slot. `try`, `fail`, and
call-site `else` become explicit control edges, including recovery values and
exhaustive atom matches. Active deferred cleanups and failure-only undo entries
run in one lexical reverse order before a failure leaves their blocks; only
defer runs on normal and successful-return exits, and traps unwind neither.
Cleanup syntax retains the ordinary complete callee, so a selected function
field is evaluated late with its arguments. On
Linux x86-64 ordinary atoms use dense nonzero 32-bit
codes and the normal argument/`%eax` result positions; `%r10d` is the dedicated
error carrier, with zero meaning success. It consumes no source parameter or
result position. Completion into
an aggregate destination contributes an ordinary whole-place flow fact, so
branch joins and guarded-return edges require no call-specific exception. Each
early or final aggregate-result exit copies that complete independent slot to
the hidden caller destination.

What is reachable is the path around it. `--emit=asm` writes the assembly and
`--emit=exe` assembles and links it through the driver
`Landin.Backend.Toolchain` names, so a constant-return `main` runs and exits
with its own `code`. The assembly half is host-independent by the rule that
nothing outside `Landin.Targets` may ask the host anything: emitting for
`linux-x86-64` produces identical assembly text on macOS and on Linux. The finishing
half is not, and says so — a host without the target's triplet-prefixed
driver reports `L0500` rather than reaching for whatever `gcc` names, which
on macOS would hand ELF-only assembly to a toolchain that emits Mach-O.

The `Runtime` fixture class compiles programs, links them, runs them on the
target and checks their statuses. The Linux gate therefore proves the scalar
arithmetic and non-loop expression-valued control-flow kernel, early returns,
lexical deferred and failure-only undo cleanup, declared atom errors and source
order, register/stack and recursive calls, folded module values, fixed arrays,
ordinary structs and their target-derived module and frame layouts on the
hardware the backend emits for. A host without the target toolchain fails
rather than silently skipping that evidence. The later R2 items own extensions
to the semantic and representation core; later target
and ABI work remains with the roadmap items that name it.

The native path sits behind the whole frontend: `refine` scans and parses every
`.ldn` file it is given, resolves every name in them as one module, checks the
type of everything and that every name is assigned before it is read, reports
what none of the four could read, lowers every function it accepted into
`Landin.IR`, verifies it and can dump it. Fully applied positional
parameterized aliases and structs are compile-time-only templates. Checking
substitutes type and fixed integer actuals, including a fixed formal passed to a
nested application. An alias records only the resulting ordinary scalar or
fixed-array descriptor; a struct interns D137's canonical nominal identity and
builds its selected-target field and variant layout only when a value site
requires one. Function-signature and type-actual normalization retain identity
without creating a by-value edge. Ordinary signature parameters and results
likewise use a struct's preallocated empty-actual identity through aliases, so
self and mutual signature-only recursion never enters the ordinary layout
recursion guard; routine ABI positions request any needed concrete layout when
checking the body, with direct multiple results materialized before their
caller-owned aggregate is placed. Substituting a generic descriptor at a value use
reconstructs its canonical binding and recursively materializes nested nominal
or nominal-array layout there, including D18 checks. Symbolic declaration
validation retains a checker-local template and binding obligation for a
nonconcrete identity, follows it only when another template uses that formal by
value, and interns no guessed instance. It rejects invalid free names,
decidable fixed-formal/result or field shapes, duplicate labels, unconditional
expansion cycles and impossible by-value nominal recursion in an unused
template. Concrete instances use the
same contextual aggregate storage, images, calls and control paths as ordinary
structs. Templates and formals create no IR and retain no instantiation-specific
checking metadata.

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
`Landin.Tokens`' reserved words with `spec.md`'s own `keyword` production,
derives every positive program in the corpus from the grammar and refuses
every negative one the frontend rejects, and compares
`Landin.Syntax.Precedence` with [1820]'s own
levels, operators, fold and first sets. The harness lexes every program in the
corpus and compares each token with what `check.py`'s independent tokeniser
produced, parses every one and requires the same verdict `check.py` reached,
parses every truncation of every one, mutates every corpus program by byte
insertion, deletion and replacement, and parses fixed-seed raw byte streams.
Each must yield a tree whose invariants hold rather than a crash.

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

`scripts/dev-build.sh` uses GPRbuild checksum recompilation for the edit loop,
and `scripts/dev-test.sh` accepts an exact `--suite`, `--case`, or `--fixture`
selector. Filtered runs identify themselves and do not replace the complete
no-argument suite.
