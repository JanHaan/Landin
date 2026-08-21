# Landin compiler roadmap

## Authority and scope

`tour.txt` is the normative language specification. This file is the sole
durable authority for open work, implementation dependencies, phases,
dispositions and completion gates. The prototype text files remain
specification stress tests and design records. Derived executable programs
and conformance cases belong under `compiler/tests/`. Local `.scratch/`
issues may hold execution detail, but every durable discovery, dependency or
disposition must be promoted here before the issue closes.

This roadmap begins a production-quality bootstrap compiler in Ada 2022. It
ends at a feature-complete pre-v1 compiler and toolchain slice. It does not
claim production readiness, assign a release, change a version, or schedule
self-hosting. Any version or release designation requires a separate explicit
decision; Landin does not assume SemVer.

Implementation starts with executable vertical slices. A language or
architecture question is resolved when the first slice needs it, not by a
separate prerequisite review. Legacy A1–A8 were blanket prerequisites to
writing any front end; this roadmap explicitly supersedes that blanket barrier
and assigns each question to the first executable slice that needs it. A
semantic change updates `tour.txt`, affected prototype-derived tests, this
roadmap, guarantee coverage and diagnostics together. Source syntax may change
throughout this pre-v1 roadmap. Diagnostic codes remain stable; an exceptional
code change requires an explicit synchronized update to the specification,
catalogue, roadmap, and fixtures.

The endpoint includes the Ada compiler, shared conformance suite, the Landin
`core/*` modules and minimal target support needed by the four complete
derived prototype programs, and thin build orchestration. Package acquisition,
version solving, publishing and the broader ecosystem remain outside scope.

## Selected implementation constraints

- The bootstrap implementation uses Ada 2022, pinned GNAT and GPRbuild,
  minimal dependencies, a repository-owned test harness and no SPARK.
- Ada sources live under `compiler/ada/`; implementation-independent `.ldn`
  fixtures and derived programs live under `compiler/tests/`.
- `.ldn` is the source suffix. `refine` is the direct compiler executable.
  The thin build driver and companion package tool remain unnamed; this
  roadmap does not assign the name `molasses`.
- The parser is hand-written and recovering, using recursive descent and Pratt
  parsing where appropriate.
- The compiler sees and checks a whole program. Private caches are permitted,
  but they do not form a stable separate-compilation interface.
- Landin keeps its own native backends. The internal IR is target-neutral,
  verified and free to evolve from implementation evidence; no flat shape or
  serialized stage protocol is frozen in advance. C and LLVM are not product
  backends.
- Correct, deterministic baseline code generation comes before competitive
  optimization. Shared evidence-table execution precedes specialization.
- Target order is Linux x86-64, native macOS arm64, then emulator-first
  Cortex-M. Apple Container running linux/amd64 under Rosetta is the local
  Linux loop; native Linux x86-64 CI is authoritative for Linux behavior.
  Hosting is git.sr.ht with builds.sr.ht for that gate, decided at R0.70.
  Only `.build.yml` names it; the commands it runs are the ordinary ones.
- Native macOS arm64 has its own compiler build, platform-tool and debugger
  gate. A Linux container is not evidence for Darwin behavior.
- Ada package specifications and stage fixtures are tested seams so a future
  self-hosting roadmap can replace stages incrementally. This roadmap does not
  implement mixed Ada/Landin stages or freeze their transport.
- The frame pointer is always present. Source and type provenance are carried
  from the first frontend slice so later debug information is not a retrofit.
- Licensing is deliberately not an implementation-entry gate. Distribution,
  contribution and license decisions belong to the release-readiness
  successor roadmap.

## Roadmap mechanics

Capability phases use stable IDs `R0` through `R7`. Executable work uses
stable IDs such as `R2.30`, spaced in increments of ten. Work IDs are never
reused or renumbered when work moves. Every work section has exactly one
status and dependency line in this form:

```text
Status: planned
Depends on: R2.10, R2.20
```

Allowed statuses are `planned`, `active`, `blocked` and `complete`. `blocked`
means the work cannot proceed for a reason that is not its own dependencies —
access to a machine, a decision that has not been taken — and the reason is
recorded where the work can be read.
Dependencies name work IDs only. `none` is the only empty dependency value.
A phase closes only when every work item in it is complete and its phase gate
has reproducible evidence. Exploration may run early when dependencies allow,
but phases are claimed in order. There are no dates, estimates or release
versions in this roadmap.

A rejected normative construct must first be removed or explicitly deferred
in `tour.txt`; the roadmap cannot overrule the specification. A transferred
item names a successor roadmap and cannot satisfy a still-normative in-scope
capability. Historical finding sections and `tour.txt`'s WHAT WAS TRIED AND
DROPPED section retain rejected wording.

## Successor roadmaps

- **Scale and self-hosting:** stable separate compilation and interface files,
  scale-driven caching, explicit cross-language stage transport and
  incremental replacement of tested Ada stages.
- **Companion tool and ecosystem:** package acquisition, version solving,
  manifests, locks, publishing, naming authority, generator orchestration and
  the still-unnamed user-facing build/package tool.
- **Broader standard library:** library layers beyond the core/runtime required
  by the four prototype programs.
- **Competitive optimization:** optimization beyond correct deterministic
  baseline code generation and the specialization required by the amended
  normative tour.
- **Language evolution:** parked and watch items whose implementation triggers
  do not occur during this roadmap.
- **Release readiness:** licensing, distribution, production claims and every
  release or version decision.

## Cross-cutting evidence

The following registers grow with implementation and are gate evidence rather
than parallel work lists:

- A construct matrix maps every `[NNNN]` to its grammar, implementation phase,
  positive and negative tests, applicable targets and final disposition.
- A guarantee matrix classifies every operation as statically prevented,
  runtime trapped, permitted only after leaving the checked model, or outside
  the guarantees.
- A diagnostic catalogue records the current code, triggering rule, primary
  span, required secondary spans or notes, and negative fixtures. Codes may
  change pre-v1, but never silently.
- A conformance and evidence matrix records concepts, ordinary and
  compiler-supplied conformances, table layout, `any` use and target ABI
  coverage.
- A prototype derivation matrix maps every complete derived `.ldn` program and
  negative fixture back to source lines, constructs and findings in the
  original prototype.
- A target applicability matrix assigns prototype 1 to the Cortex-M reference
  target; prototypes 2 and 4 to Linux x86-64 and macOS arm64; prototype 3 to
  hosted targets, with only explicitly reduced freestanding derivatives; and
  shared semantic cases to every applicable target.

## R0 — Bootstrap chassis

R0 creates a reproducible Ada project and an implementation-independent test
surface without pretending that a Landin frontend already exists.

### R0.10 — Establish bootstrap repository layout
Status: complete
Depends on: none

Create the Ada 2022 GPRbuild project under `compiler/ada/`, shared tests under
`compiler/tests/`, and the `refine` entry point. Keep public package
specifications narrow and representations private. Do not name the companion
build tool.

Exit evidence: a clean Ada project builds `refine`; source layout and package
ownership are documented; no Landin semantic decision is embedded in the
chassis.

### R0.20 — Pin the canonical Ada toolchain
Status: complete
Depends on: R0.10

Select and record one current GNAT/GPRbuild release at implementation kickoff.
Use provider-neutral commands. Newer local toolchains may be used only while
the canonical toolchain remains green. Do not introduce Alire as an authority,
AUnit, GNATCOLL or SPARK.

Exit evidence: the exact compiler and builder versions, runtime profile and
warning policy are recorded and reproduced from a clean environment.

### R0.30 — Establish shared fixtures and custom harness
Status: complete
Depends on: R0.10

Build a repository-owned harness for unit, positive, negative, runtime, ABI,
debugger and end-to-end fixtures. Preserve the original prototype files;
derived `.ldn` programs and derivation manifests are separate. Test discovery,
ordering and result rendering are deterministic.

Exit evidence: the harness discovers each fixture class, rejects duplicate or
malformed metadata, and proves deterministic ordering without a third-party
test framework.

### R0.40 — Establish source and diagnostic foundations
Status: complete
Depends on: R0.10

Implement immutable source snapshots, byte-oriented locations and spans,
line maps, diagnostic transport and deterministic rendering. Carry source
identity and declared-type provenance in forms that later AST, IR and debug
stages can preserve.

Exit evidence: unit cases cover invalid offsets, line endings, multi-label
diagnostics and stable ordering.

### R0.50 — Establish compiler and platform-tool boundaries
Status: complete
Depends on: R0.20, R0.30, R0.40

Define the `refine` request/result boundary and narrow adapters for filesystem,
process execution, assembler and linker tools. Expected source failures are
data; Ada exceptions are reserved for compiler defects, exhausted host
resources and failed external tools.

Exit evidence: a no-language driver reports deterministic help/version-neutral
identity, invokes fake tool adapters in tests and distinguishes diagnostics
from infrastructure failures.

### R0.60 — Establish tested stage and target seams
Status: complete
Depends on: R0.20, R0.30

Define one stage-neutral Ada package seam — a compilation context plus a
stage interface — that later source, syntax, semantics, target-neutral IR and
target lowering stages plug into without the seam naming them; each of those
per-stage packages arrives with the slice that introduces it. Define host and
target facts without assuming host widths are target widths. Do not freeze an
on-disk AST, IR or cross-language protocol.

Exit evidence: contract tests exercise fake stages and at least one synthetic
32-bit target description on the 64-bit development host.

### R0.70 — Establish development and validation environments
Status: complete
Depends on: R0.50, R0.60

Make Apple Container with linux/amd64 under Rosetta the local Linux loop and a
native Linux x86-64 job the authoritative Linux gate. Keep commands
provider-neutral until repository hosting is selected. Record that native
macOS validation arrives in R5 and that QEMU full-system x86 is supplemental,
not the daily loop.

Exit evidence: the same documented commands build and run the chassis in the
local container and a native x86-64 Linux environment; tool versions are
captured with results.

Both halves are done and recorded in `docs/environments.md`. The pinned
container image builds the chassis and runs the suite with a transcript
byte-identical to the macOS one, and `.build.yml` runs the same commands on
x86-64 hardware at builds.sr.ht, from clean, in debug and release. Hosting
was selected here: git.sr.ht for the repository, builds.sr.ht for the gate.

### R0 gate

- The pinned Ada toolchain builds `refine` from a clean checkout.
- The custom harness and deterministic diagnostics pass locally and on native
  Linux x86-64.
- Stage and target seams have contract tests.
- No source-level Landin compatibility or version claim has been made.

The gate is closed. `docs/environments.md` records the environments and their
captured results; `compiler/ada/README.md` records the package layout and
ownership; `compiler/ada/TOOLCHAIN.md` records the pinned toolchain and the
warning policy; `compiler/tests/README.md` records the fixture format. Between
them: the pinned toolchain builds `refine` from a clean checkout on macOS
arm64, in the pinned linux/amd64 container, and on x86-64 hardware at
builds.sr.ht; the harness and its deterministic diagnostics pass in all three,
in debug and in release; the stage and target seams have contract tests
including a synthetic 32-bit description; and the executable makes no version
claim, which the gate job prints rather than merely asserting.

R0 is complete. R1 is next, and R1.10 is unblocked.

## R1 — Executable language kernel

R1 implements the smallest honest frontend-to-native vertical slice. It does
not wait for raw storage, generics or Cortex-M, but it includes the minimum
SysV/ELF ABI needed to run rather than calling verified IR an executable.

### R1.10 — Add the normative kernel grammar
Status: complete
Depends on: R0.30

Add lexical rules, the precedence table, and statement/expression productions
for the enabled kernel to `tour.txt`, which remains the normative grammar
home. A machine-readable inventory may be derived from it but never becomes a
second independent grammar. Trace every production to constructs and fixtures.

Sources: legacy A1; `H§P0.1`; `R` bottom line.

Exit evidence: every enabled production and precedence relation has positive,
negative and ambiguity cases; constructs outside the kernel are explicitly
not yet enabled rather than guessed.

The grammar is `[1740]`–`[1830]`, and `check.py` reads it rather than trusting
it: every rule defined and reachable, every `.ldn` under
`compiler/tests/fixtures/positive` derivable, every one under `negative` not,
and every construct named by a fixture. Thirty-seven positive and nineteen
negative cases; nine of the negatives are constructs the tour describes and
the kernel refuses by `[1830]`, and one is the multi-error file R1.40 needs.
Two rounds of reading the grammar by hand found sixty-eight defects and still
missed that a lone `_` parsed as a name, which is why the corpus exists.

### R1.20 — Implement lexical analysis
Status: complete
Depends on: R1.10, R0.40

Implement byte-oriented tokenization, literal validation, comments and unknown
input recovery. Preserve source spans and never infer syntax from `check.py`'s
keyword heuristics.

`[1750]` states the line terminator: LF, CR LF, or a CR not followed by LF,
and a file need not end with one. That rule is R1.10's, because a terminator
is a lexical rule; implementing and testing it is this item's, and R0.40's
line map already keeps it.

Exit evidence: the lexical corpus covers valid tokens, unknown bytes,
boundaries and deterministic recovery, and the Ada scanner agrees with the
grammar on every program in `compiler/tests/fixtures`.

`Landin.Tokens` holds the vocabulary and `Landin.Tokens.Lexer` is the only
unit that can build a token; `Landin.Source.Names` interns identifiers so a
later stage compares identities rather than bytes. The scanner is held to the
grammar twice over: `check.py` compares its reserved words with the tour's own
`keyword` production and every deferred lexeme with the construct it names,
and the harness lexes all 65 corpus programs and compares each token with
what `check.py`'s independent tokeniser produced.

Invalid escapes are struck from this item's evidence, with the reason
recorded rather than the clause quietly dropped: the kernel's only literals
are integers and the two booleans `[1770]`, and character, text and raw
literals `[0250]` `[0260]` `[0280]` -- the only constructs that define an
escape at all -- are refused by `[1830]`. No enabled rule reads a byte as an
escape, so neither a valid nor an invalid one can be written. The clause
belongs to the work that enables a literal carrying escapes, and R4.10 owns
the remaining hosted literal forms.

### R1.30 — Establish the diagnostic catalogue
Status: complete
Depends on: R0.40, R1.20

Assign current diagnostic codes and required primary/secondary spans for the
kernel, including representative syntax and name failures. Codes are testable
but may change pre-v1 through synchronized updates.

The chassis already holds four codes, assigned in R0.50 because a driver that
cannot explain itself cannot be tested: `L0001` no language frontend is
enabled, `L0002` unknown option, `L0003` source not found or not readable,
`L0004` unknown target. The catalogue this item builds starts from them and
owns every code after them.

Sources: legacy A8; `R§P1.5`.

`Landin.Diagnostics.Catalogue` is the catalogue and the only place in the
compiler where a code is written; `check.py` refuses a code literal anywhere
else under `compiler/ada/src`, which is how `L0001`-`L0004` stopped being
literals in the driver. Each column is an exhaustive case over the code names,
so a code with no row does not compile. The reading copy at
`compiler/tests/diagnostics.catalogue` is generated from the table and checked
fresh on every full run.

Nine codes: the driver's four, and `L0010` for a construct the tour describes
and `[1830]` refuses, `L0011` a digit outside its base, `L0012` bytes no rule
spells, `L0013` an unclosed block comment, `L0014` an unclosed literal. One
code for the refusal rather than one per deferred lexeme, because the question
a user asks is what in their program is not enabled yet, and the construct is
named in a note rather than in the number. Bands are reserved but unassigned:
`L0100`-`L0199` for R1.40's syntax failures, `L0200`-`L0299` for R1.50's
names, `L0300`-`L0399` for R1.60's types. A retired code keeps its row, so a
number is never handed to a second rule.

The catalogue holds no prose. `L0003` is raised with two sentences, for a
source that is missing and one that cannot be read, because one rule was
violated and the difference is wording; a code split for a wording reason is
the worst use of a stable identifier. What a code requires of every
occurrence -- a source, a non-empty span, how many secondary labels, how many
notes -- is in the row, and `Landin.Diagnostics.Lexical` checks the row
against the diagnostic it just built rather than trusting itself.

Exit evidence: negative cases assert code and spans separately from prose
rendering; terminal rendering has focused golden tests.

Both hold. The catalogue suite asserts codes, spans, label counts and note
counts with no prose in the assertion, and one golden case renders a refusal
in full so that what a user sees cannot change unnoticed. Deferred with the
reason recorded: a per-fixture `report:` file listing every diagnostic's code
and spans waits for R1.40, because until a parser runs there is no program
that produces more than one diagnostic worth ordering.

### R1.40 — Implement the recovering parser
Status: planned
Depends on: R1.20, R1.30

Implement hand-written recursive descent and Pratt parsing, explicit recovery
points and a syntax representation that preserves source provenance needed by
semantics and debugging.

Exit evidence: malformed files produce multiple ordered diagnostics without a
crash; recovery resumes at declared boundaries; every kernel production is
covered.

### R1.50 — Collect declarations and resolve names
Status: planned
Depends on: R1.40

Implement module-local declaration collection, forward references, scopes,
shadowing and deterministic duplicate/unresolved-name diagnostics for the
kernel.

Exit evidence: positive and negative fixtures prove order-independent module
names and source-stable diagnostics.

### R1.60 — Check the executable kernel
Status: planned
Depends on: R1.50

Implement the minimum static types, constants, functions, scalar operations,
branches and returns needed by the first native program. Reject unsupported
constructs explicitly.

Exit evidence: each enabled construct has acceptance and rejection cases; no
host integer width leaks into target semantics.

### R1.70 — Implement target-neutral IR and verification
Status: planned
Depends on: R1.60, R0.60

Introduce the smallest evolvable target-neutral IR, preserving source
locations, lexical scopes, declared types and stable value identity. Verify
control flow, value definitions, types and call shapes before lowering.

Exit evidence: malformed-IR tests are rejected; round-trip textual dumps are
canonical test artifacts but not stable public interfaces.

### R1.80 — Implement the minimal Linux x86-64 native path
Status: planned
Depends on: R1.70, R0.50, R0.70

Implement the scalar data layout, frame-pointer rule, minimum SysV calling
convention, hosted `main`, ELF-compatible assembly and platform
assemble/link/run path needed for a constant-return program. Keep aggregate,
error-register and evidence calls in R2.

Sources: `[1550]`, `[1650]`.

Exit evidence: `refine` compiles a kernel `.ldn` program to deterministic
assembly, assembles, links and executes it on native Linux x86-64 with the
expected status.

### R1.90 — Close the executable-kernel corpus
Status: planned
Depends on: R1.80

Tie grammar, diagnostics, syntax, checking, IR and native behavior together in
one construct-indexed corpus.

Exit evidence: positive, negative, verifier and runtime cases all run through
the real driver; the construct matrix has no unexplained kernel row.

### R1 gate

- The enabled grammar is normative in `tour.txt`.
- Recovery produces multiple useful diagnostics.
- A real `.ldn` program compiles, links and runs on native Linux x86-64.
- Unrelated representation and freestanding questions remain owned by later
  work rather than silently answered.

## R2 — Semantic and representation core

R2 supplies the target-parametric representation and evidence foundations
needed by the hosted parser. Raw storage remains container-driven and closes
in R3 rather than being designed in isolation.

### R2.10 — Establish target-parametric data layout
Status: planned
Depends on: R1.60, R1.70

Implement target facts, scalar widths/alignment and checked layout arithmetic.
Add synthetic 32-bit layout goldens before a Cortex backend exists.

Exit evidence: Linux x86-64 measurements and synthetic 32-bit cases agree with
the target model; overflow and impossible alignment are diagnosed.

### R2.20 — Implement aggregates, variants and complete value layout
Status: planned
Depends on: R2.10

Implement arrays, ordinary/C/packed structs, variants, tags, payload alignment
and the policy for spare-bit folding. Use measured fixtures rather than host
Ada representation as authority.

Sources: legacy A3, which had no tracked citation.

Exit evidence: deterministic layouts cover every value family, including
variant tag width/position and folded/unfolded cases; debugger type provenance
survives.

### R2.30 — Implement functions, control flow and declared errors
Status: planned
Depends on: R2.20, R1.70, R1.80

Implement full function values, named returns, control-flow expressions,
traps, declared atom-set errors, `fail`, `try`, call-site `else`, `defer` and
`undo`, together with Linux x86-64 internal calling/lowering rules.

Exit evidence: ABI tests cover ordinary and failing calls, aggregate values,
indirect calls and every control-flow exit path.

### R2.40 — Implement fixed parameters and compile-time substitution
Status: planned
Depends on: R2.10, R1.50

Implement type and fixed parameters, substitution, constant array lengths,
deduction and fixed conditional declarations without introducing compile-time
execution.

Exit evidence: generic shape fixtures and negative non-fixed cases pass; no
user code executes during compilation.

### R2.50 — Implement references and local lifetime checks
Status: planned
Depends on: R2.20, R2.30

Implement pointers, slices, permissions, origins, `escaping`, `from`, local
borrows, escape rejection and use-after-consume checking. Preserve the honest
unsafe boundary around integer pointers and foreign code.

Sources: `[0430]`, `[0470]`, `[0770]`, `[0790]`, `[0830]`, `[0900]`, `[0910]`.

Exit evidence: the origin/borrow corpus includes required spans and notes;
accepted escape cases and deliberately unchecked boundaries remain explicit.

### R2.60 — Implement concepts and conformance collection
Status: planned
Depends on: R2.20, R2.40

Implement concepts, parameterized conformances, whole-program collision
checking and a closed named set of compiler-supplied conformances. Reconcile
compiler-supplied `zeroable` with ordinary declared conformances without
opening reflection.

Sources: legacy A6; `[0550]`, `[1280]`.

Exit evidence: lookup and collision tests pass; users cannot synthesize or
override compiler-supplied entries; the supplied set is closed and documented.

### R2.70 — Implement the generic evidence schema
Status: planned
Depends on: R2.10, R2.30, R2.60, R1.80

Define target-neutral entry ordering and semantics for concept functions, size
and alignment; instantiate the physical Linux x86-64 ABI; and test synthetic
32-bit physical layouts. Do not freeze an x86-only byte representation as the
semantic schema.

Sources: legacy A7; `[1310]`, `R§12`.

Exit evidence: shared generic bodies make indirect evidence calls; table
layout, entry order, size and alignment are ABI-tested; specialization is not
required.

### R2.80 — Implement `any C`
Status: planned
Depends on: R2.50, R2.70

Implement explicit construction, the data-pointer/table pair, mutable and
immutable entries, origin propagation, storage in aggregates and runtime
dispatch.

Sources: `[1370]`, `[1380]`, `[1390]`.

Exit evidence: at least two heterogeneous conformances dispatch through real
tables; origin and permission failures are diagnosed.

### R2.90 — Establish guarantee and semantic coverage registers
Status: planned
Depends on: R2.30, R2.50, R2.60, R2.70, R2.80

Classify every implemented operation as statically prevented, runtime trapped,
permitted only beyond lifetime checking, or outside guarantees. Tie each row
to acceptance, rejection, trap or explicit non-guarantee evidence.

Sources: legacy A5; `[0310]`, `[0430]`, `[0470]`, `[0770]`, `[0910]`, `[1120]`,
`[1720]`, `R§4`, `H§5`.

Exit evidence: no implemented semantic operation lacks a guarantee class,
diagnostic behavior and test owner.

### R2 gate

- Representation, errors, references, conformances and evidence are executable
  on Linux x86-64 and target-parametric for later 32-bit lowering.
- Shared generics and `any` dispatch without specialization.
- The guarantee, diagnostic and conformance registers cover every implemented
  operation.

## R3 — Hosted parser

R3 is the first major compiler milestone. It derives raw storage from real
container pressure, implements the minimum normative module and hosted-service
surfaces, and runs a complete parser workload written in Landin.

### R3.10 — Implement minimum modules and ordered roots
Status: planned
Depends on: R1.50, R2.40, R2.60, R0.50

Implement module directories, per-file imports, visibility, deterministic
ordered roots and whole-program conformance collection needed by the parser.
Add the unnamed thin orchestration seam without package acquisition.

Sources: `[1410]`, `[1420]`, `[1450]`, `[1480]`.

Exit evidence: a multi-module program resolves deterministic roots and rejects
ambiguous/colliding conformances.

### R3.20 — Build the allocator and container pressure case
Status: planned
Depends on: R2.50, R2.60, R2.70

Implement the minimum allocator protocol and executable `vec` pressure case
that distinguishes capacity from initialized elements, including a
non-zeroable pointer element. Use it to discover the raw-storage operations;
do not bless the old dishonest `slice_from` contract.

Sources: `[0510]`, Z8, `R§2`, `H§4`.

Exit evidence: the pressure fixture demonstrates the exact initialization and
release transitions the type must represent.

### R3.30 — Implement honest raw storage and `core/mem`
Status: planned
Depends on: R3.20, R2.10

Specify and implement raw storage with separate capacity and initialized count,
one-slot admission and release of initialized values only. Fold the resulting
semantics into `tour.txt` and the guarantee matrix.

Sources: legacy A2; `[0510]`, Z8.

Exit evidence: positive state transitions and negative uninitialized-read,
double-admit and invalid-release cases pass; containers no longer pretend
uninitialized bytes are `T`.

### R3.40 — Implement parser-support core modules
Status: planned
Depends on: R3.30, R2.70, R2.80

Implement the required Landin `core/mem`, `core/vec` and `core/text` layers,
arenas and deliberately failing allocators. Add only map/tree pieces the parser
actually needs; broader container completion belongs to R4.

Exit evidence: allocator failure paths, arena-origin behavior and pointer
vectors pass through compiled Landin code.

### R3.50 — Implement the minimum hosted ABI and I/O
Status: planned
Depends on: R1.80, R2.30, R3.10

Choose and document the smallest Linux hosted service route needed for
arguments, files and streams, using a narrow libc boundary unless executable
evidence justifies direct syscalls. Keep the general C ABI matrix in R4.

Exit evidence: Landin `core/io` reads parser input, writes diagnostics and
reports world-dependent failures through declared errors.

### R3.60 — Implement diagnostics as runtime dispatch
Status: planned
Depends on: R1.30, R2.80, R3.50

Implement the parser's diagnostic capability, bounded and streaming
implementations, and calls through `any` evidence tables.

Exit evidence: two logger implementations receive identical ordered notes;
bounded overflow and hosted I/O failure follow their specified channels.

### R3.70 — Complete and run the derived parser program
Status: planned
Depends on: R3.10, R3.40, R3.60, R2.90

Turn prototype 2 into a complete `.ldn` program with a derivation manifest,
inputs and expected outcomes. The original remains a design record. The
workload is a program compiled by `refine`, not the Ada compiler frontend
itself.

Sources: prototype 2; F1; F3.

Exit evidence: the parser compiles and runs on native Linux x86-64, reports and
recovers from multiple foreseeable syntax errors, propagates allocation and
I/O failures, and proves real shared evidence-table and `any` dispatch with no
specialization.

### R3 gate

- A complete hosted parser program executes from a clean checkout.
- The evidence ABI and `any` are semantic foundations; specialization is absent.
- Raw storage came from container pressure and is normative.
- Diagnostics are useful, deterministic and traceable to current codes and
  spans.

## R4 — Complete hosted Linux x86-64 path

R4 closes the hosted language surface on Linux, completes the container and
application workloads, adds usable source debugging and implements only
baseline measured optimization.

### R4.10 — Close the hosted construct matrix
Status: planned
Depends on: R3.70

Implement or explicitly amend every remaining hosted normative construct,
including text, literals, patterns, loops, `unchecked`, modules, builtin
directives and hosted entry behavior.

Exit evidence: every hosted `[NNNN]` row has implementation and positive or
negative evidence; no omission is hidden by prototype coverage.

### R4.20 — Complete hosted core containers and library slice
Status: planned
Depends on: R3.40, R4.10

Complete the Landin `core/vec`, `core/map`, `core/tree`, allocator and hosted
library pieces required by prototypes 3 and 4. Document freestanding/hosted
layering, raw syscall versus libc choices and deliberate omissions.

Sources: legacy B5, which had no tracked citation.

Exit evidence: containers run with heap, arena, fixed and failing allocators;
all omission and layering choices are recorded.

### R4.30 — Complete hosted modules and toolchain directives
Status: planned
Depends on: R3.10, R4.10

Implement the remaining ordered-root, fixed option, `landin/compiler`,
`landin/assembler` and `landin/linker` behavior needed by hosted programs.
Preserve whole-program compilation.

Sources: `[1480]`, `[1500]`, `[1530]`, `[1560]`.

Exit evidence: deterministic root and option cases pass; private caches expose
no stable interface.

### R4.40 — Implement the narrow complete C ABI and bindings
Status: planned
Depends on: R2.30, R4.30

Cover `c_int` and related types, `char` signedness, aggregate arguments and
returns, enums, unions, bitfields, varargs, callbacks, thread-local storage,
`errno`, foreign ownership, failure boundaries and calling convention as part
of function identity. Provide binding generation sufficient to avoid a
hand-written-declaration workflow, without turning the compiler into a header
parser.

Sources: legacy B2; `R§9`, `R§10`.

Exit evidence: ABI differential tests call in both directions; unsupported C
forms fail explicitly; generated declarations are deterministic.

### R4.50 — Implement baseline code generation and specialization
Status: planned
Depends on: R1.70, R2.70, R4.10

Implement deterministic local simplification, instruction selection, a simple
register allocator and measured specialization after shared dispatch works.
Implement the amended normative specialization policy and build report without
claiming competitive optimization.

Sources: `[0590]`, `[1310]`.

Exit evidence: disabling specialization preserves behavior; build reports state
what happened; scalar loop lowering and code-quality smoke measurements meet
the documented baseline.

### R4.60 — Implement usable Linux source debugging
Status: planned
Depends on: R1.70, R1.80, R4.50

Emit source line tables, symbolic frames and inspectable parameters/locals for
core scalar, pointer, aggregate and variant types. Preserve the frame pointer
and source/type provenance through lowering.

Exit evidence: scripted debugger sessions prove breakpoints, stepping, stacks
and selected locals in unoptimized and baseline-optimized builds.

### R4.70 — Complete and run the derived container program
Status: planned
Depends on: R4.20, R4.50, R4.60

Turn prototype 3 into a complete hosted `.ldn` program and negative corpus,
with derivation mapping and deliberately failing allocator cases.

Exit evidence: list, small vector, map and tree paths execute on Linux x86-64;
raw-storage, evidence and origin invariants are exercised.

### R4.80 — Complete and run the derived hosted application
Status: planned
Depends on: R4.20, R4.30, R4.40, R4.70

Turn prototype 4 into a complete hosted `.ldn` program with heterogeneous
runtime dispatch and I/O, retaining traceability to prototype 2 and 3 support.

Exit evidence: the application selects heterogeneous implementations at
runtime, processes hosted I/O and executes on Linux x86-64.

### R4.90 — Close Linux hosted parity
Status: planned
Depends on: R4.60, R4.70, R4.80

Run the full applicable construct, conformance, ABI, diagnostics, determinism,
debugger and prototype suites on native Linux x86-64.

Exit evidence: all applicable matrices are complete; equivalent builds produce
identical assembly and behavior under the pinned toolchain.

### R4 gate

- The hosted normative tour is implemented on Linux x86-64.
- Complete derived prototypes 2, 3 and 4 run with useful debugging.
- Correct baseline code generation is measured; competitive optimization is
  not a gate.

## R5 — Native macOS arm64 parity

R5 proves target isolation on the actual development platform before the
freestanding backend begins.

### R5.10 — Establish the native macOS compiler environment
Status: planned
Depends on: R0.70, R4.90

Pin or bound the macOS arm64 GNAT/GPRbuild, Apple SDK, assembler, linker and
debugger environment. Build and run `refine` natively; the Linux container is
not accepted as Darwin evidence.

Exit evidence: provider-neutral commands build `refine` and run its harness on
native macOS arm64 with captured tool versions.

### R5.20 — Isolate target contracts
Status: planned
Depends on: R4.90, R0.60

Refine target descriptions, ABI queries, assembly emission and debug emission
so Darwin support does not enter parsing, checking or target-neutral IR
semantics.

Exit evidence: target-independent stage fixtures are byte-for-byte or
canonically equal across hosts where specified; target differences are
localized and reviewed.

### R5.30 — Implement Darwin arm64 lowering
Status: planned
Depends on: R5.10, R5.20, R2.30

Implement the arm64 data layout, Darwin calling conventions, native assembly,
object/link integration, hosted entry and minimal platform runtime.

Exit evidence: ABI differential and end-to-end cases execute natively on macOS
arm64.

### R5.40 — Implement macOS arm64 source debugging
Status: planned
Depends on: R5.30, R4.60

Emit and validate line, frame and selected local/type information through the
Apple debugger/toolchain while preserving the always-present frame pointer.

Exit evidence: scripted native debugger sessions provide the same selected
source experience as Linux where platform facilities permit.

### R5.50 — Close hosted target parity
Status: planned
Depends on: R5.30, R5.40, R4.70, R4.80

Run all shared hosted conformance cases and complete derived prototypes 2, 3
and 4 on macOS arm64, comparing semantics and diagnostics with Linux.

Exit evidence: differences are either eliminated or explicitly target-defined;
no target-specific logic leaked into semantic stages.

### R5 gate

- `refine` builds and runs natively on macOS arm64.
- Hosted semantics, diagnostics, ABI and prototype behavior match the declared
  cross-target contract.
- Source debugging is usable on both hosted targets.

## R6 — Freestanding Cortex-M path

R6 selects a reproducible reference environment at phase entry, then closes the
language's hardware pressure. Emulator evidence has separate CPU/startup and
peripheral-behavior lanes; physical hardware remains supplemental.

### R6.10 — Select the Cortex-M execution profile
Status: planned
Depends on: R5.50

Select an exact QEMU-supported core/board, EABI toolchain and debugger at R6
entry. Record which GPIO, UART, DMA and interrupt behaviors are actually
modeled. Add a deterministic peripheral harness when QEMU does not model the
prototype's devices.

Exit evidence: the profile can test boot/vectors/traps/debugging and names a
separate reproducible route for every required MMIO/DMA behavior.

### R6.20 — Instantiate the 32-bit layout and ABI
Status: planned
Depends on: R2.10, R5.20, R6.10

Implement Cortex-M scalar, aggregate, variant, error and evidence-table layouts
and the selected embedded ABI from the target-parametric schema.

Exit evidence: prior synthetic 32-bit goldens agree with emitted layout and ABI
probes; no x86 pointer-size assumption survives.

### R6.30 — Define and implement the concurrency memory model
Status: planned
Depends on: R2.90, R5.20, R6.10

Specify data races, atomic orderings, happens-before, volatile ordering and
tearing, interrupt visibility, compiler and hardware barriers, DMA coherence
and cache maintenance. Preserve the ordinary-slice DMA pressure case.

Sources: legacy B1; `R§5`.

Exit evidence: normative text and executable/model cases cover atomics,
volatile access, barriers, interrupts, DMA and cache behavior.

### R6.40 — Define and implement packed invalid encodings
Status: planned
Depends on: R2.20, R6.20

Decide the behavior of unnamed hardware bit patterns, raw register images,
validated values and reserved bits per access mode. Implement packed layouts
without optimizer assumptions that exceed the decision.

Sources: legacy A4; `R§6`.

Exit evidence: positive and negative encoded-value cases and reserved-bit
read/modify/write behavior pass through the peripheral harness.

### R6.50 — Implement the Cortex-M backend
Status: planned
Depends on: R5.20, R6.20, R6.30, R6.40

Implement instruction selection, frame layout, register allocation, traps and
assembly emission for the selected core while retaining the always-present
frame pointer.

Exit evidence: the shared target-applicable IR corpus assembles and executes in
the selected emulator profile.

### R6.60 — Implement startup, vectors and machine directives
Status: planned
Depends on: R4.30, R6.30, R6.40, R6.50

Implement linker scripts, startup, firmware entry, vector placement,
interrupt/naked conventions, sections, keep rules and inline assembly.

Exit evidence: firmware boots, vectors and interrupts execute, sections land at
expected addresses and link/map evidence is deterministic.

### R6.70 — Implement the freestanding Landin core slice
Status: planned
Depends on: R3.30, R3.40, R6.30, R6.50, R6.60

Implement the minimal freestanding memory, collections, panic, CPU and device
support required by the driver. Hosted dependencies must not enter its closure.

Exit evidence: the linker closure contains only declared freestanding modules
and startup/toolchain shims; allocator and panic behavior fit the profile.

### R6.80 — Establish checked-in generated device fixtures
Status: planned
Depends on: R6.10, R6.40

Provide deterministic checked-in `.ldn` modules representing the ugly vendor
SVD pressure. Transfer the SVD generator and general sandboxed generator
orchestration to the companion-tool roadmap.

Exit evidence: fixture provenance and regeneration requirements are documented;
the compiler gate does not depend on an unbuilt package ecosystem.

### R6.90 — Complete and run the derived driver program
Status: planned
Depends on: R6.60, R6.70, R6.80

Turn prototype 1 into a complete `.ldn` program with derivation mapping. Run
CPU/startup behavior in QEMU and MMIO/DMA behavior through the selected modeled
peripheral lane.

Exit evidence: register images, volatile access, interrupts, vector placement,
DMA handoff/visibility and failure behavior execute with recorded outcomes.

### R6.100 — Close freestanding evidence
Status: planned
Depends on: R6.90

Retain firmware map, flash/RAM size, bounded stack, line/function debug and
applicable conformance evidence. Add a physical-board smoke test only as
supplemental evidence.

Exit evidence: emulator and peripheral lanes are reproducible in CI; artifacts
show the implementation remains viable for the selected constrained profile.

### R6 gate

- The complete derived driver runs against reproducible CPU and peripheral
  evidence.
- Packed encoding and concurrency semantics are normative and tested.
- The freestanding closure contains no hosted dependency.

## R7 — Full-tour feature-complete pre-v1 closure

R7 closes coverage and dispositions. It does not release, declare production
readiness or begin self-hosting.

### R7.10 — Audit every normative construct
Status: planned
Depends on: R5.50, R6.100

Complete the construct-matrix inventory for every current `[NNNN]`. For every
construct still normative in `tour.txt`, record its implementation state,
applicable targets and the work item owning any open row. A rejection or
transfer first amends the tour so the roadmap never overrides the specification.

Exit evidence: no construct row is missing, unowned or unexplained.

### R7.20 — Close deferred normative behavior
Status: planned
Depends on: R4.50, R7.10

Use measured compiler evidence to implement or amend remaining normative work,
including any specialization/reporting behavior not already closed. Deferred
SoA `[0620]` is not normative implementation work unless its trigger caused a
tour amendment.

Exit evidence: `[1310]` and every other formerly delayed normative row have
implementation and tests or an evidence-backed tour amendment.

### R7.30 — Disposition every inherited item
Status: planned
Depends on: R7.10

Mark each inherited open, parked, held and watch item implemented, rejected with
evidence, or transferred to one named successor roadmap. Watch observations do
not become blockers merely because they were observed.

Exit evidence: the 32-row migration appendix and all later discoveries have an
explicit terminal disposition.

### R7.40 — Close all evidence registers
Status: planned
Depends on: R2.90, R7.20, R7.30

Close construct, grammar, guarantee, diagnostic, conformance/evidence,
prototype-derivation and target-applicability matrices.

Exit evidence: `tour.txt` contains lexical, precedence, statement and expression
grammar for every still-normative construct; no matrix contains a gap, stale
test, unowned target or contradictory disposition.

### R7.50 — Prove deterministic baseline toolchain behavior
Status: planned
Depends on: R4.90, R5.50, R6.100, R7.40

Run correct baseline code generation, assembly determinism, ABI and selected
debug evidence across Linux x86-64, macOS arm64 and the Cortex-M reference
profile. Do not add competitive benchmark targets.

Exit evidence: equivalent closures produce declared deterministic artifacts and
all target-specific debugger/map requirements pass.

### R7.60 — Run complete derived prototype coverage
Status: planned
Depends on: R3.70, R4.70, R4.80, R5.50, R6.90, R7.50

Run all four complete derived prototypes according to the applicability matrix,
plus their positive and negative conformance derivatives. Do not demand hosted
I/O programs on Cortex-M or the full 64 KiB container pool on a 32 KiB target.

Exit evidence: every derivation row has inputs, outputs, target results and a
trace back to the original design record.

### R7.70 — Declare the roadmap endpoint
Status: planned
Depends on: R7.60

Record that the compiler/toolchain slice is feature-complete pre-v1 and name all
successor ownership. Do not edit a version, assign a release, claim production
readiness, select a license or start self-hosting.

Exit evidence: every work item is complete, all transferred scope has a named
successor, and repository authority documents agree on the endpoint.

### R7 gate

- Every construct still normative in the amended tour is implemented on every
  applicable target.
- All complete derived prototypes and evidence matrices pass.
- Every durable item has an explicit terminal disposition.
- The result remains pre-v1, unreleased and not self-hosted.

## Inherited review register and migration parity

This appendix preserves all 32 legacy backlog entries exactly once. It records
why each exists, its sources and its roadmap owner. Parked and watch entries do
not block phases unless their stated trigger fires. At R7 each row receives a
terminal disposition.

D1–D6 are held positions, each challenged by an outside reader and deliberately
retained. Reopen one only with new evidence that answers its preserved rationale,
and record the reopening explicitly.

| Legacy item | Preserved decision, trigger and sources | Roadmap owner or successor |
|---|---|---|
| A1 — Normative grammar | Add lexical rules, an explicit precedence table, statement grammar and expression grammar. Sources: `H§P0.1`; `R` bottom line. | Incremental ownership starts in R1.10 and continues with each construct phase; complete normative grammar closes in R7.40. |
| A2 — Raw storage as a type | `[0510]` withdrew `slice_from` as an honest answer. Track capacity apart from initialized count, admit one slot at a time and release only initialized values; derive the shape from containers. Sources: `[0510]`, Z8, `R§2`, `H§4`. | R3.20, R3.30 |
| A3 — Full value layout | Decide variant tag width/position, payload alignment and spare-bit folding through implementation measurements. The legacy item had no tracked citation. | R2.10, R2.20 |
| A4 — Invalid packed encodings | Decide trap, unknown/raw or other behavior for unnamed hardware patterns; distinguish raw image, validated value and reserved bits by access mode. Source: `R§6`. | R6.40 |
| A5 — Guarantee table | Classify every operation as statically prevented, runtime trapped, permitted only beyond lifetime checking or outside guarantees. Sources: `[0310]`, `[0430]`, `[0470]`, `[0770]`, `[0910]`, `[1120]`, `[1720]`, `R§4`, `H§5`. | R2.90; closes R7.40 |
| A6 — Compiler-supplied conformances | Reconcile compiler-supplied `zeroable` with declared conformances and collision errors; keep the supplied set closed and named to avoid reflection. Sources: `[0550]`, `[1280]`. | R2.60 |
| A7 — Generic evidence ABI | Define physical layout, entry order and size/alignment positions; `any` needs the table in the first major milestone. Sources: `[1310]`, `R§12`. | R2.70, R2.80 |
| A8 — Diagnostics | Maintain concrete codes and useful origin/borrow output. Source: `R§P1.5`. Codes may change pre-v1 only through synchronized updates. | R1.30; closes R7.40 |
| B1 — Concurrency memory model | Define data races, atomic orderings, happens-before, volatile ordering/tearing, interrupt visibility, compiler/hardware barriers, DMA coherence and cache maintenance; preserve the ordinary-slice DMA case. Source: `R§5`. | R6.30 |
| B2 — C ABI subset | Cover C scalar aliases and `char`, aggregates, enums, unions, bitfields, varargs, callbacks, TLS, `errno`, foreign ownership, failure boundaries and calling-convention identity; provide binding generation. Sources: `R§9`, `R§10`. | R4.40 |
| B3 — Separate compilation | Preserve proposed interfaces containing declarations/layouts, concrete errors, `escaping`/`from`, conformances, evidence ABI, package identity, language version and hashes, plus an explicit `shared`/`specialized`/`auto` policy rather than heuristics. Source: `R§12`. | Whole-program choice in R0.60/R4.30; stable interfaces transfer to Scale and self-hosting. |
| B4 — Package, build and generators | Preserve manifests, locks, hashes, deterministic roots, targets/sysroots, hosted/freestanding profiles, linker scripts, startup, firmware and sandboxed generators with declared inputs and outputs. Source: `R§13`. | Required thin pieces in R3.10/R4.30/R6.60; acquisition and general generator orchestration transfer to Companion tool and ecosystem. |
| B5 — Standard library | Preserve hosted/freestanding layering, detailed allocator interface, raw-syscall/libc choice and deliberate omissions. The legacy item had no tracked citation. | Required slices in R3.40/R4.20/R6.70; remainder transfers to Broader standard library. |
| B6 — Package naming authority | Keep project-first override and postpone global authority. Source: `[1480]`. | Companion tool and ecosystem. |
| C1 — Affine values | Could support resource ownership, peripheral singletons and typestate, but would change `[0910]`'s non-ownership `sink`; affine is at-most-once and can still leak. Trigger: a peripheral/resource prototype unpleasant without it. Sources: `[0910]`, `R§3`, `H§3`. | Parked; transfer to Language evolution if R6 does not trigger it. |
| C2 — Conformances as named values | Trigger: collisions hurting in real libraries. The legacy item had no tracked citation. | Parked; transfer to Language evolution if untriggered. |
| C3 — Restrict root capability minting | Would make hosted subtrees checkable but cannot close freestanding address literals. Trigger: wanting to run untrusted code. Source: `[1680]`. | Parked; transfer to Language evolution if untriggered. |
| C4 — Generational observers for graphs and inferred uniqueness | Preserve both parked ideas together. The legacy item gave no trigger or citation; do not invent one. | Parked; transfer to Language evolution unless later evidence supplies a trigger. |
| C5 — SoA collections | Deferred design record. Trigger: a simulation prototype needing one field contiguous. Source: `[0620]`. | Parked; transfer to Language evolution if untriggered. |
| C6 — `unchecked` | Already normative but not first; optimizer assumptions wait for a measurable compiler. Sources: `[1120]`, `[1720]`, `H§5`. | Implement Linux semantics in R4.10; prove applicable target parity in R5 and R6. |
| D1 — Integer indexing of UTF-8 | Keep linear codepoint-ordinal indexing for ergonomics despite three independent objections. Source: `[0610]`. | Implement in R4.10; reopen only with new program/measurement evidence. |
| D2 — No weak conformances or orphan rule yet | Weak conformances let applications silently change generic library behavior. Collisions remain errors; use `distinct` or explicit functions. Ecosystem-scale composition remains the trigger. Sources: `[1280]`, `R§11`. | Implement in R2.60; reopen only on concrete ecosystem evidence. |
| D3 — No comptime or macros | Generated tables, SoA and SVD bindings move to programs, making build/generator design load-bearing. Two cases exist; a third is the review trigger. Source: `[1540]`. | Held throughout; generator work follows B4 or Companion tool and ecosystem. |
| D4 — Write `escaping` and `from` | Preserve local compilation and the allocator counterexample to inferred `from`. Sources: `[0790]`, `[0900]`. | Implement in R2.50; reopen only with evidence preserving both properties. |
| D5 — Own backend | Assembly out, with QBE as design influence; not LLVM due dependency size and not C due calling convention, traps and debug precision. The historical handoff proposed C/LLVM and was declined. Sources: archived `HANDOFF.md` (declined C/LLVM first-host proposal); current `handoff.md` and `[1550]` (settled native-backend position). | Implement across R1.80, R5.30 and R6.50. |
| D6 — One package-name version per program | Preserve 32 KB code-size pressure, nominal types and one conformance register; a conflict is a hard error. Source: `[1470]`. | Companion tool and ecosystem: arrange the ordered roots supplied to `refine` so only one version is reachable; a conflict detected while arranging roots is a hard error requiring an upgrade. |
| E1 — Control flow nobody used | Labels, `break with` and `complete` appeared in one of four prototypes. A fifth program not needing them is evidence, not automatic removal. Sources: Y4, Z15. | Watch through R7; transfer to Language evolution if inconclusive. |
| E2 — Concept width | Resist widening concepts to the hungriest implementation; watch real libraries. Sources: `[1260]`, W4. | Watch R3/R4; transfer to Language evolution if inconclusive. |
| E3 — Source-generation count | Two cases stand: generated tables and SVD bindings. A third triggers D3 review. The legacy item had no independent citation. | Watch R3-R6; transfer to Language evolution if no third case appears. |
| F1 — Executable prototype conformance | Preserve positive and negative cases, especially formerly contradictory pre-0.0.17 examples; prose-only prototypes cost two patch releases. Sources: `R§P0.8`; `H` definition of success. | R0.30 and complete derived programs at R3.70/R4.70/R4.80/R6.90/R7.60. |
| F2 — Grow `check.py` | Every cheap new rule and every defect once missed becomes a check; it found most 0.0.15-through-0.1.0 defects. The legacy item had no citation. | Roadmap-wide process and mechanical gate. |
| F3 — First implementation amendment | Evidence tables and `any` belong in the first major subset; specialization does not. The table is the foundation and specialization the optimization; parser and hosted I/O need dispatch. Source: `[1310]`. | R2.70/R2.80 and R3.70; specialization starts only at R4.50. |
