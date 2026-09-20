# Landin

> Ada, but small. Zig, but sweeter. One systems language from 32 KB to
> 32 TB. Move fast, keep the pointers, and let the compiler tell you
> when you are being an idiot.

A systems programming language, its compiler and a small standard
library, designed and built from scratch. Named after Peter Landin, who
coined the term *syntactic sugar* and wrote *The Next 700 Programming
Languages* in 1966 — this one is the 701st.

One target range, and the same way of writing code across all of it: a
Cortex-M0 with 32 KB of flash at one end, a hosted desktop application
at the other.

**Status: specification 0.1.0. The compiler can build and run Landin programs
for Linux x86-64 and native macOS arm64. It handles functions, user-defined data types, generic
routines, pointers, errors, control flow, modules, evidence-table dispatch and
`any`. Hosted containers, allocators, text and I/O in `core`, a complete
recovering configuration parser and a hosted log filter now run alongside the
automatically tested FizzBuzz, number-theory, searching
and sorting programs, plus correctness-scale fannkuch-redux, Mandelbrot and
FASTA workloads. Microcontroller support and the broader standard library
are still to come.**

## What is here

| file | what it is |
| --- | --- |
| `handoff.md` | start here. The design in one page, the principles behind it, how the work is done, and which decisions must not be quietly reversed. |
| `spec.md` | the normative specification: the grammar of the enabled kernel, the rules the tour left unsaid, and the register of decisions taken while implementing them. |
| `tour.md` | the language explained, as a numbered "learn X in Y minutes". Teaches; does not decide. |
| `examples.md` | ten complete programs the compiler emits and the native hosted gates run today: seven small algorithms plus correctness-scale fannkuch-redux, Mandelbrot and FASTA workloads. |
| `ROADMAP.md` | the sole durable authority for open work, implementation dependencies, phase gates, and dispositions. Read it before proposing or scheduling work. |
| `AGENTS.md` | how to work in this repository: the authority order, the commands, and the rules the chassis already keeps. |
| `check.py` | mechanical checks over the live documents, grammar and fixture corpus. Run it after touching any of them. |
| `compiler/ada/` | the Ada 2022 bootstrap compiler: `refine`, its frontend and verified IR, the Linux x86-64 and Darwin arm64 backends and native toolchain paths, and its own test harness. |
| `docs/ir.md` | the intermediate representation explained: its structure and rationale, maintained as a derived account of the implementation, never an authority. |
| `compiler/tests/` | fixtures, in a format that outlives the implementation checking them. |
| `examples/config_parser/` | the complete lexer and recovering parser derived from prototype 2; its executable host and exact input/output oracle live in `compiler/tests/fixtures/runtime/derived-parser`. |
| `examples/derived_containers/` | the complete prototype-3-derived client of the ordinary `core` containers and allocator capabilities; `compiler/tests/fixtures/runtime/derived-containers` supplies its host, status oracle and derivation manifest. |
| `examples/derived_hosted/` | the complete prototype-4-derived log filter, with runtime-selected filters and destinations, complete line reading, retained arguments and explicit delivery retry; its derivation and memory-world oracle live in `compiler/tests/fixtures/runtime/derived-hosted-memory`. |
| `scripts/` | build, test, clean and toolchain commands. Provider-neutral, except `linux-loop.sh`, which drives Apple Container by name. |
| `environments/` | the pinned `linux/amd64` image the local Linux loop builds, and `pins.sh`, the one place a toolchain version or checksum is written. |
| `flake.nix` | `nix develop`, for people who work that way: a shell holding the same pinned toolchain, read from `environments/pins.sh` rather than from nixpkgs. |
| `docs/` | the environments that produce evidence, the agent-facing notes, and the site generator. |
| `highlight/` | the shared lexical scanner and installable Pygments, TextMate, tree-sitter and packages for the major editor families, from VS Code and JetBrains IDEs through Vim, Emacs and Notepad++. |
| `prototype-1-driver.md` | a driver written from an ugly vendor SVD: GPIO, an interrupt-driven DMA UART, a vector table, and not one hand-written bitmask. |
| `prototype-2-parser.md` | a parser that recovers, because a real one must not stop at the first mistake. |
| `prototype-3-containers.md` | a generic container library: growing array, small vector, hash map, arena-backed tree. |
| `prototype-4-app.md` | a hosted application whose shape is decided by its command line, so it cannot be written without runtime dispatch. |

The prototypes are not illustrations. They are the test suite: each was
written to make the specification fail, each ends with the list of
places where it did, and each keeps the wording that turned out wrong
beside its resolution. Between them they have recorded forty-two
findings, including several that reversed a decision.

## Reading it online

Every document here is published as a syntax-highlighted reading copy at
**<https://www.701.dev>** — the tour, the specification, the running examples,
the four prototypes, the roadmap, and the implementation notes. Every
`[NNNN]` citation links to the construct it names, and hovering one shows what
it says.

The site also has an [editor and IDE support guide](https://www.701.dev/editors.html)
with installation paths for the Landin extensions and plugins for Zed, VS
Code and its relatives, Neovim, Vim, Emacs, Helix, Sublime Text, Visual
Studio, JetBrains IDEs, Eclipse, Notepad++, Kate and Nano, plus the Pygments
lexer.

The canonical repository the pages are generated from is at
**<https://git.sr.ht/~sinnfrei/landin>**:

```sh
git clone https://git.sr.ht/~sinnfrei/landin
```

An automatically maintained GitHub mirror is at
**<https://github.com/JanHaan/Landin>**. Changes still originate on SourceHut;
the mirror copies its branches and tags.

Explicit native acceptance approves an exact committed revision. SourceHut
publishes the reading copies after approved promotion to canonical `main`;
manual publication uses the same guard. See
`environments/native-ci/README.md` for acceptance operations. To render or publish:

```sh
./scripts/site.sh              # render, verify, package
./scripts/site.sh --publish    # and upload
```

## Checking

```sh
python3 check.py
```

Keywords standing where names belong, spellings a decision retired,
`when` outside an exit statement, convention markers at call sites,
two declarations of one name in one module, `end` closing nothing,
citations pointing at constructs that do not exist. It resolves the
files next to itself, so it runs from anywhere.

It is not a parser and does not pretend to be one. It is the set of
invariants that are cheap to check and tedious to re-check by hand,
and it found most of what the last several revisions fixed. Every rule
that can be checked cheaply belongs in it, and so does every defect it
missed once.

## Where the history is

The design was argued out over a long sequence of numbered revisions,
four prototypes and two outside reviews, and that archive is kept
separately — the conversation, the review, the implementation handoff
and the full revision log. Nothing here depends on it.

What was worth carrying came along: the tour's closing
section, WHAT WAS TRIED AND DROPPED, keeps
the reversals, the things that were designed and then taken out again,
because a reader who does not know them will propose them back.

## Building

```sh
export LANDIN_GNAT_HOME=...      # the pinned GNAT, see compiler/ada/TOOLCHAIN.md
export LANDIN_GPRBUILD_HOME=...  # the pinned GPRbuild

./scripts/build.sh
./scripts/test.sh
```

On macOS, use `./scripts/dev-test.sh --host` for compiler checks and add an
exact `--suite` or `--case` selector while editing. Every selected case must
pass. Run Linux workloads and GDB in native Linux development slots; run Darwin
workloads and LLDB natively on the Mac. The unfiltered harness includes Linux
execution and cannot supply a successful Mac compiler-host result.
See [the development and acceptance workflow](docs/process.md).

For checksum-safe focused feedback during an edit, use
`./scripts/dev-test.sh --suite=NAME`, `--case=SUITE/NAME`, or
`--fixture=CLASS/NAME`. These runs say `FILTERED`; the no-argument command
above remains the complete suite.

On a nix machine, `nix develop` puts the pinned toolchain on `PATH` for you.

`refine --identify` will tell you what it is. Giving it one or more `.ldn`
files runs the frontend, lowering and verification over them as one module.
Without `--emit` an accepted program deliberately writes no output file;
`--emit=asm -o program.s` writes assembly for the selected target (Linux by
default; `--target=darwin-arm64` selects native Mac output), and `--emit=exe -o
program` assembles and links a hosted executable when the target toolchain and
[1970]'s entry point are present. A program it refuses gets a report with a
span, a caret and a note. If what you wrote is a construct the tour describes
and the kernel omits, the note names the paragraph that describes it and the
roadmap item that enables it.

## What comes next

Implementation proceeds in executable vertical slices rather than waiting for
every design foundation to be settled in advance. R0's Ada 2022 bootstrap
chassis and R1's executable language kernel are complete. The compiler builds
on macOS arm64; exact-revision runtime acceptance runs natively on
Linux x86-64 and Darwin arm64 for their respective target contracts. The pinned
container remains available for explicit environment troubleshooting. R2.10 establishes target-derived sizes, alignments and checked
layout arithmetic, including synthetic 32-bit evidence. R2.20's
target-parametric aggregate and variant representation and
R2.30's functions, control-flow expressions, lexical cleanup, declared errors
and internal aggregate ABI are complete. R2.40's fixed parameters,
compile-time substitution, generic routine instances, fixed conditional
selection and per-instance inferred errors are complete. R2.50's pointers,
slices, conventions, local origins and borrows, `escaping`, `from`, consume
checking and target reference carriers are complete. R2.60's concepts,
constraints, whole-program conformance register and closed compiler `zeroable`
family are complete. R2.70's target-neutral evidence order, target-derived
Linux/synthetic-32 table layout, hidden evidence arguments, indirect concept
calls and representation-compatible shared machine bodies are complete.
R2.80's exact `any C` identity, explicit/inferred pointer erasure, two-word
pair, object-safe mutable/immutable dispatch, flattened composed tables,
origin propagation and aggregate/shaped ABI are complete. R2.90's guarantee,
diagnostic, conformance/evidence, prototype-derivation and target-applicability
registers are complete and mechanically checked against their executable
owners. R3.10's directory modules, file-local import scopes, public qualified
lookup, ordered roots, deterministic graph closure and entry-module selection
are complete. R3.20's allocator/vector pressure case derives honest raw-storage
transitions from executable non-zeroable pointer storage, including
transactional growth and drain-before-free. R3.30's repository-owned
`core/mem` now enforces that initialized-prefix state machine, keeps its
representation private and exercises rollback and publication through compiled
Landin code. R3.40 adds the allocator interface, explicit and deliberately
failing arenas, a transactional pointer-capable `core/vec`, and the parser's
byte-oriented `core/text` positions and subslices, with backing origins and
failure behavior pinned by compiled fixtures. R3.50 adds the scalar/pointer
`extern(c)` seam, captures hosted arguments through a libc-backed runtime
bridge, and builds `core/io` as an ordinary world capability with declared
file and stream failures. R3.60 adds the object-safe `core/diag.log` capability,
bounded and streaming implementations, ordered dispatch through `any`, direct
bounded-overflow accounting and propagated hosted-write failure. R3.70 composes
those pieces into a complete arena-backed recursive configuration parser,
executes it through bounded and streaming erased loggers, recovers three syntax
faults in order, and separately proves allocation and diagnostic I/O failure.
R4.10 closes the hosted construct surface: loop transfers, labels, values and
every traversal form; the quoted, raw, character and float literal families;
compound assignment; the complete enabled scalar conversion matrix; and
condition declarations, caller parameters, `unchecked` regions, range subtypes
and the atom-or-pointer union. Every hosted construct row now carries fixture
evidence or a refusal that names the item enabling it, and `check.py` audits
that whenever the item is not active.

R4.20 completes the hosted `core` library slice: explicit heap, arena, pool
and failing allocators; initialized storage, vectors, small vectors, maps,
trees and sorting; checked runtime text helpers; and interchangeable system
and memory I/O worlds. Compiled clients exercise their bounded composition,
allocation failures and rollback. R4.70 completes the derived container
program. R4.80 adds the complete hosted log filter in
`examples/derived_hosted`: runtime-selected heterogeneous filters and
destinations, arbitrary-length lines, copied arguments, explicit message
retry and real file I/O. Ordinary `core/region` provides bulk cleanup over a
caller-supplied allocator. D212 withdraws the former builtin arena syntax
and its unsupported transitive escape promise; local origin checks remain.

R4.21 repairs the earlier review's flow, origin, lowering and diagnostic gaps.
R4.30 adds import aliases, selected imports, typed global options, compiler
facts, assertions and ordered static-library directives. R4.40 implements the
selected Linux x86-64 C ABI and `layout(c)`, callbacks and variadic call
transport. Its separate header generator and policy-driven C adapters cover
the supported enum, union, bitfield, global/TLS and incoming-varargs boundaries;
unsupported C forms receive explicit refusals. ROADMAP.md records their
contracts and historical closure evidence; R4.91 records the subsequent
review repairs and their acceptance binding.

R4.50 completes deterministic baseline code generation: compact numeric-array
loops, strict-saving `layout(optimal)` placement, independently controlled
evidence-proved specialization and factual build reports. The authoritative
native Linux x86-64 gate passed for the exact implementation revision; the
closure evidence is recorded in ROADMAP.md.

R4.60 completes usable Linux source debugging: DWARF source lines, symbolic
frames and inspectable parameters/locals, including optimized caller frames.
The authoritative native gate passed scripted GDB acceptance with debug and
release compiler builds. ROADMAP.md records the complete closure evidence.
Debug provenance remains independent of DWARF encoding for a possible future
PDB emitter; PDB support is not implemented.

R4.90 closes Linux hosted parity, including distinct representations,
inline struct declarations, homogeneous field fills, parameterized atom unions,
atom storage and recovered-error generic discovery. Complete derived prototypes
2, 3 and 4 retain native execution and debugging coverage. ROADMAP.md binds the
exact containing revision's acceptance and delivery evidence to its annotated
approval tag and durable native bundle.

**Next roadmap item: R7.60 — Run complete derived prototype coverage (planned).**

R4.91 closes the reviewed compiler, tooling and documentation repairs. Its
completion is bound to its closure revision's exact native acceptance, approval
and canonical delivery recorded in ROADMAP.md. R5.10 has established the native
macOS compiler environment; R5.20 isolates target contracts. R5.30 implements
native Darwin arm64 lowering, C transport, hosted runtime and linking, with
matching-revision native Mac acceptance required alongside Linux approval.
R5.40 implements native LLDB source debugging, dSYM packaging and exact Mach-O
source identity. R5.50 closes complete hosted parity through the dual-native milestone binding
in ROADMAP.md, retaining its explicit large-image loader limitation.
R5.51 closes the retained-debt and acceptance-workflow follow-up through its
exact-revision dual-native binding in ROADMAP.md. Routine policy retains full
release hosted coverage; debugger risk adds full release GDB/LLDB. Retained
debt has explicit owners and activation conditions; R6/R7 language work remains
scheduled and Nix CI deferred. R6.10 establishes the pinned
[Cortex-M execution profile](environments/cortex-m/README.md): QEMU M0
CPU/startup probes and a deterministic Renode peripheral lane. Its completion
has the same exact-revision dual-native binding. R6.20 instantiates 32-bit
layouts and external AAPCS/internal Landin ABI planning, checked independently
by native Linux C/assembly execution controls and the existing synthetic-32
goldens. Its closure has the same dual-native binding. R6.50 subsequently adds
Cortex assembly; R6.60 adds compiler-owned startup/linking, while source
debugging is enabled by R6.100.

R6.30 defines D227's concurrency memory model and implements scalar atomics,
volatile accesses and explicit barriers on both hosted targets. Ordinary-slice
DMA visibility, interrupt exclusion and cache obligations have independent
executable/model controls, bound by the same exact-revision dual-native gate.
R6.50 lowers the admitted Cortex-M memory subset with exact scalar accesses
and retained alignment checks.

R6.40 implements D228's packed raw images, checked encoded-field extraction,
indexed fields and explicit register-image access policies on both hosted
backends. Raw copies preserve unnamed patterns; extraction traps even under
`unchecked`. Independent C controls and compiler-generated Renode execution
retain exact access traces and reserved-bit checks. The containing revision's
dual-native approval and guarded delivery bind closure; R6.50 now owns the
Cortex-M instruction-selection path, while R6.80 retains generated-device fixtures.

R6.50 adds ARMv6-M Thumb assembly, reusable stack homes, the always-present r11
frame chain, internal calls/results/failures/evidence, soft scalar arithmetic,
packed-image checks and the admitted memory/barrier operations. Its
[generated-code corpus](environments/cortex-m/README.md#r650-compiler-generated-execution)
runs on the selected QEMU profile; synthetic Renode tests execute actual Cortex
register and ordinary-slice DMA code. The external test startup/linker harness
does not enable those language surfaces. Exact-revision validation and closure
remain recorded in ROADMAP.md.

`refine --debug=full --emit=exe program.ldn -o program` requests Linux source
debugging. The default is `--debug=none`; debugging metadata is independent of
the program's optimization and source build-mode settings. Add
`--target=darwin-arm64` for native macOS output, then open `lldb ./program`.
See [source debugging and identity](docs/targets.md#native-source-debugging).

D209--D211 specify compact numeric-array arithmetic, explicit optimal field
placement and optional evidence-proved specialization. The driver selects
size/auto by default; `--optimize=none --specialize=off` selects the reference,
and `--build-report=PATH` requests deterministic off-target JSON. Build mode
remains independent. The mandatory runtime-profile matrix and
`./scripts/quality.sh` object acceptance passed; ROADMAP.md records the
native-gate closure rather than inferring it from implemented switches alone.

Language and architecture questions are resolved when the first vertical
slice needs them.

The first major compiler milestone is R3: a complete derived version of the
parser prototype with useful diagnostics, evidence-table dispatch, and `any`;
specialization is explicitly not part of that gate. Target work then proceeds
through the complete hosted Linux x86-64 path, native macOS arm64, and
emulator-first Cortex-M.

The endpoint is feature-complete pre-v1, not production or self-hosting.
Package acquisition, competitive optimization, release versioning, and
self-hosting belong to successor roadmaps or later decisions. No version or
release designation changes automatically.

## License

Copyright (c) 2026 Jan Haan. `MIT OR Apache-2.0`: use this under either
[the MIT license](LICENSE-MIT) or [the Apache License, Version
2.0](LICENSE-APACHE), at your option. [`LICENSE`](LICENSE) says which file
governs what.

What `refine` produces is not a derivative work of `refine`. Compiling a
program places no licensing condition on that program, and neither does
linking `core/*` into it — which is the point of a language that has to fit
in 32 KB of somebody else's flash.


R6.60 implements compiler-owned reset, data/RAM-code copying, BSS clearing,
typed interrupt/naked functions, vector references, placement/retention and
fixed assembly with explicit effects. Firmware uses the selected 32 KiB flash,
16 KiB RAM and 4 KiB stack reservation. The
[firmware execution lane](environments/cortex-m/README.md#r660-compiler-owned-firmware)
checks generated boot, nested exceptions, PSP return, veneers and peripheral
traces alongside independent C/assembly controls. Its exact-revision dual-native
binding and remaining limits belong to ROADMAP.md. R6.70 owns the freestanding
core and adds ordinary CPU support, nonreturning signatures and panic dispatch
with optional source maps. Its closure is bound to the containing revision’s dual-native approval and
guarded delivery in ROADMAP.md. R6.80 adds [generated device fixtures](devices/README.md):
30 RP2040 registers with retained vendor inputs, deterministic regeneration and
compiler-generated firmware/peripheral consumers. R6.90 adds the [complete derived driver](compiler/tests/driver/DERIVATION.md),
including its explicit synthetic DMA loss/stop/recovery protocol. R6.100
adds Cortex `--debug=lines` and complete firmware/resource evidence; its
exact-revision dual-native milestone binding closes the R6 gate within the
measured bounds recorded in ROADMAP.md.

R7.10 audits every normative construct into the generated construct
inventory in `compiler/tests/constructs.matrix`: each of the 201 rows records
its state, applicable targets, per-target evidence, named refusals and open
owner, and `check.py` refuses a missing, stale, unowned or unexplained row.
The described forms it found unfinished are routed to R7.20, target gaps and
stale refusal notes to R7.40. Its exact-revision dual-native routine binding
in ROADMAP.md owns closure.

R7.20 decides every one of those rows from measured evidence. Shared names,
labelled bare blocks, the several-atom pointer union and the remaining general
aggregate values are implemented on Linux x86-64, Darwin arm64 and Cortex-M0,
with GDB and LLDB presentation of the new union. Range-subtype composition is
a recorded boundary; `volatile ptr`, `register(...)`, `set(X)`, per-field byte
order, the machine attribute words and the vector intrinsics are withdrawn in
favour of existing mechanisms; u128, i128 and f16 go to the Language evolution
successor and the atomic wrapper type to the Broader standard library. Spec
decisions D233-D241 record each choice with its alternative, and the
exact-revision dual-native routine binding with debugger coverage in
ROADMAP.md owns closure.

R7.30 gives every inherited item and every later discovery a terminal
disposition. Nineteen of the 32 inherited appendix rows are implemented and
thirteen are transferred to named successors. No parked item's trigger fired
and no watch concluded in the four complete derived programs, so C1-C5, the
E1-E3 watches and the stackful-fibre exploration join D237's scalars with the
Language evolution successor, each with its trigger and completion evidence.
A new ledger does the same for the limits R6.10-R7.20
recorded, giving physical-board evidence to Release readiness and the
structural editor grammar's drift to R7.40, and `check.py` now refuses a row
without a terminal disposition. Its exact-revision dual-native routine
binding in ROADMAP.md owns closure.

R7.40 closes every evidence register. The four compile-time rows whose
Cortex-M column was empty now carry a measured verdict rather than an argument
that the frontend is target-neutral: the same sources compile to a
byte-identical verdict on all three targets, and `check.py` counts such a
claim only from a fixture that selects the target it names. That rule found
five fixtures claiming hosted refusals their programs do not make. [1610]'s
Cortex-M link names are attributed to the firmware probe that resolves them,
recorded where the runner can be checked. The two notes that still promised a
finished item are gone: [1350]'s says which boundary R2.40 records, and
[1580]'s refusal entry, which nothing raised, is removed in favour of the C
signature error the boundary actually reports. D242 gives a refused selected
import a continuation identity, so its verdict and exact report stand while
later uses of the name stop repeating a misspelling they are not, and the
structural editor grammar is transcribed back onto the enabled kernel. Its
exact-revision dual-native routine binding in ROADMAP.md owns closure.

R7.50 proves deterministic baseline toolchain behavior. [1550] already said
the compiler emits deterministic assembly text and relies on the platform's
assembler and linker; until now nothing could refuse a violation of it. The
item states the relation first — two compilations are equivalent closures when
they agree on source, closure, target and build options, and may differ in
build directory, working directory, output path, environment, repetition and
order — and then gates it. Target code and the build report are identical
under that whole relation on Linux x86-64, Darwin arm64 and Cortex-M0; debug
metadata is identical too once the compilation directory is fixed, and when
that directory moves it may differ in the recorded directory and the identity
hashed over it and in nothing else, so an instruction that followed the build
directory fails. The hosted linked image is deliberately not claimed: two
Linux links of one unchanged assembly differ in six bytes because the GNU
driver writes its own random temporary object name into the symbol table, in
the same directory from the same command. Baseline code generation was
measured and left alone; Darwin's frames are about twice Linux's for the same
programs, which is recorded against the optimization row whose trigger it
fires and acted on by nobody here. Its exact-revision dual-native routine
binding with debugger coverage in ROADMAP.md owns closure.
