# Landin roadmap

## Authority and scope

`spec.md` decides the language and `tour.md` explains it. This file is the
sole authority for open work: its phases, dependencies and gates, and the
register of work that waits for a trigger. A work item cannot overrule the
specification. A semantic change updates `tour.md` or `spec.md`, the fixtures
that pin it and this file together.

The first roadmap, R0 to R7, built the bootstrap compiler from an empty
repository to a feature-complete pre-v1 slice for Linux x86-64, macOS arm64
and Cortex-M0, and closed at R7.70. Its full text is in the history, last at
commit `335b0814`; what it left open is in the register below, and its item
titles are indexed at the end of this file so that the citations it left in
the tree still resolve until R8.10 removes them.

This roadmap takes the compiler from that slice to one that other people can
use on the machines they have: a frontend that scales and serves an editor,
assembly with operands, more hosted targets, the microcontrollers people
actually buy, a library split along the line the capability model already
draws, concurrency, Windows, and measured optimization.

Outside it, and staying outside: a build tool and a package manager, which
the Companion tool and ecosystem family owns; self-hosting; and every release
or version decision, each of which needs an explicit decision of its own.
Landin does not assume SemVer.

Work item and register identities stay in this file. Code, diagnostics,
fixtures, generated files and the other documents never cite a work item,
save the one status pointer `README.md` and `handoff.md` carry, because an item is finished long before the text that cites it is, and a
citation that outlives its item is a question nobody can answer. `check.py`
refuses a citation of this roadmap's items anywhere else. The first roadmap's
citations are the exception until R8.10 removes them.

## Mechanics

Phases are `R8`, `R9` and onward, in order, and each ends in one gate. Work
items are `R8.10`, `R8.20` and so on, spaced in tens, so that work found
necessary between two items is inserted with a unit identity, as the first
roadmap's R4.21 sits after R4.20 and before R4.30. Identities are never reused
or renumbered, including the first roadmap's.
Every item has exactly one status line and one dependency line:

```text
Status: planned
Depends on: R8.10, R8.20
```

A status is `planned`, `active`, `blocked` or `complete`. `blocked` means the
item cannot proceed for a reason other than its dependencies, and the reason
is one nonempty `Blocked because:` line in the item. A complete item's
dependencies are all complete. `none` is the only empty dependency value.
Phases are claimed in order; the next item is the first dependency-ready
planned item in roadmap order, and `README.md` and `handoff.md` name it.
There are no dates, estimates or versions here.

An item is complete when its exit evidence exists: the gate green on the
completing commit for every host the gate runs, and, for a claim about a host
it does not run, a named run recorded in the item. Completing an item adds a
short `Done:` paragraph saying what landed and where its evidence is. The
reasoning belongs in the commits and in `spec.md`'s register of decisions,
not here; the first roadmap grew to thirteen thousand lines narrating itself.

Nothing accepts a revision. The gate is a safety net, not a verdict, and no
item claims otherwise.

## R8 — Stand on its own

Pay what the move off the first roadmap left owing: the citations it left in
the tree, a frontend whose time grows with roughly the cube of a program's
size, and a gate that runs one of the three targets.

### R8.10 — Remove the first roadmap's citations

Status: planned
Depends on: none

About eighteen hundred citations of R0 to R7 items, in about two hundred
and eighty files, and some fifty of the first roadmap's ledger records sit in
compiler sources and comments, diagnostic text and the goldens that record
it, fixtures, `spec.md`, `tour.md`, the prototypes, the evidence registers
and the guides, and nearly two hundred lines name `ROADMAP.md`, many of them
sending a reader there for closure evidence and acceptance records that are
now only in the history. Each is rewritten to say what it meant, or removed
where it said nothing. A refusal that names the work enabling its construct
names the construct's state instead, which amends [1830]'s note and the two
refusal tables. The construct inventory loses its Phase column.

Exit evidence: no file outside `ROADMAP.md` cites a work item or register
identity of either roadmap beyond the status pointer, `check.py` refuses one, the first roadmap's index
is deleted from this file, and every changed diagnostic is pinned by its
recorded report.

### R8.20 — Make the frontend scale

Status: planned
Depends on: none

Measured with the release compiler on one Linux host: a synthetic file of 250,
500, 1,000 and 2,000 trivial functions compiles in 0.36, 1.9, 12 and 89
seconds, and 85.7 of the 89 are spent before lowering. The derived log filter
and the `core` it uses, about 3,500 lines, spend 6.6 of 7.9 seconds there.
Nothing larger than a prototype can be written against that, and no editor can
wait for it. Find the superlinear passes and replace them. This takes on
register records R551-06 and R551-10 and the corpus timing question SR-02.

Exit evidence: a scaling benchmark in the repository, generated inputs of
growing size up to at least 16,000 declarations plus the derived programs,
whose frontend time, the median of five runs, grows by no more than 2.5 times
per doubling across the range; the derived log filter checks in under half a
second with the release compiler on the host that measured the numbers above;
the same inputs, and a struct of 20,000 fields, check without exhausting the
host, with each stage's storage measured and a named refusal past a stated
bound; and the gate runs the benchmark and fails when a ratio exceeds 2.5,
which does not depend on the runner's speed.

### R8.30 — Run every existing target in the gate

Status: planned
Depends on: none

The gate builds and tests on Linux x86-64 in debug mode and nothing else.
Add macOS arm64 on GitHub's arm64 macOS runners, the release build, the
Cortex-M QEMU and Renode lanes on Linux, the GDB and LLDB sessions, and the
structural editor grammar's integration pass. Add the runners nothing runs
today: the determinism closures and their controls, the bindings tests, the
object-quality lane, `scripts/tests`, and `check.py`'s control suite; and run
the fixture execution suite with many workers, which is how a race in the
harness's reads went unseen. This takes on R730-22 and R730-25.

Exit evidence: `gate.yml` runs each of those on every push, a failure in any
fails the gate, every end-to-end target claim is a verdict in a record the
coverage readers read rather than a run, and the documents stop describing
the gate as Linux and debug only.

### R8 gate

- Nothing outside `ROADMAP.md` cites a work item but the status pointer.
- The frontend's scaling benchmark holds in the gate.
- Every target the compiler has runs in the gate on every push.

## R9 — Inline assembly

Assembly with operands, early, because the microcontroller work needs it and
because every tool written after it has to know it exists.

### R9.10 — Specify assembly with operands

Status: planned
Depends on: none

Today `assembler.block` exists on Cortex-M0 only, with one `u32` passed through
`r0`, and the hosted targets refuse assembly. Specify typed operands bound to a
register or a target's register class, as inputs, outputs or both, with
declared clobbers and memory effects, in [1630] and a register decision. Not
GCC's constraint strings: a target-specific language inside a string literal is
exactly what a type checker cannot see into. The form must keep the verified
IR's view of the block as one instruction with declared effects, keep the
frame pointer, and reserve no register, which the stackful-fibre direction
needs.

Exit evidence: [1630] and the grammar amended, the decision recorded with its
alternative, and positive and negative fixtures the grammar derives.

### R9.20 — Implement assembly with operands on every target

Status: planned
Depends on: R9.10

Lower the specified form on Cortex-M0, x86-64 and arm64, allocate its operands
and honour its clobbers, and describe it to the debugger.

Exit evidence: executed fixtures on all three targets, including one per
target that the IR verifier refuses, and `core/cpu` written on the new form.

### R9 gate

- One source form of assembly with operands runs on every target.

## R10 — A frontend for tools

A language server that runs inside the compiler, a formatter, and diagnostics
that say how to fix what they found. The compiler is already a library behind
tested stage seams and a host interface, so the server is its third client
after `refine` and the test program.

### R10.10 — Reclaim a compilation's memory

Status: planned
Depends on: R8.20

Sources, trees and every stage table are allocated for the life of the
process and never freed, which is right for a batch compiler and wrong for a
server that checks on every edit. Give a compilation its own storage and free
it as one.

Exit evidence: a test that checks the same program many times in one process
with memory that stays flat, and a driver that behaves identically.

### R10.20 — Keep comments and layout

Status: planned
Depends on: none

Comments produce no token and layout is discarded. Keep both in a side table
beside the token stream without changing what the parser sees.

Exit evidence: every source in the corpus and `core` reproduced byte for byte
from its tokens and the side table.

### R10.30 — Make diagnostics say how to fix it

Status: planned
Depends on: R8.10

Suggestions for misspelt names and near misses; machine-applicable edits
attached to a diagnostic; `refine explain` for every catalogue code; and lints
as warnings in the catalogue, with codes, rather than a second tool with a
second opinion.

Exit evidence: each edit pinned by a fixture that applies it and then compiles
clean, every catalogue code explained, and every lint a catalogued code with a
negative fixture.

### R10.40 — Format source

Status: planned
Depends on: R10.20

`refine fmt`: one style and no options.

Exit evidence: formatting is idempotent and preserves every comment over the
whole corpus, and `core` and the examples are formatted, which the gate holds.

### R10.50 — Serve an editor

Status: planned
Depends on: R10.10, R10.30, R10.40

A language server linked against the compiler library, over standard input
and output: diagnostics, definitions, hover types, formatting and the edits of
R10.30 as code actions. Analysis continues past a syntax error as far as the
parser recovers. Whether it is `refine lsp` or its own executable is decided
here.

Exit evidence: scripted sessions in the gate for each capability, and a
bounded run over mutated corpus sources that never crashes the server, which
takes on the frontend part of R551-19.

### R10 gate

- An editor gets diagnostics, navigation, types, formatting and fixes from a
  server running the compiler's own stages.

## R11 — More hosted targets

The targets GitHub's runners reach, with the target description growing
feature levels before it grows targets.

### R11.10 — Describe CPU feature levels

Status: planned
Depends on: none

A target description carries a feature level: x86-64 v1 to v4, arm64's
architecture extensions, the Cortex-M profiles, RISC-V's extensions. It is
selected per build and visible to `fixed if`.

Exit evidence: feature levels selectable on every target, visible as
compiler facts, and one feature-dependent lowering per target family executed
at two levels.

### R11.20 — Linux arm64

Status: planned
Depends on: R11.10

The arm64 backend with the standard AAPCS64 and ELF, and a pinned toolchain so
`refine` itself runs there.

Exit evidence: the corpus and the GDB sessions on GitHub's arm64 Linux
runners in the gate.

### R11.30 — FreeBSD x86-64 and arm64

Status: planned
Depends on: R11.20

The hosted layer and platform driver for FreeBSD, emitted from Linux and run
in a FreeBSD virtual machine on a Linux runner.

Exit evidence: the runtime corpus executed in that machine in the gate.

### R11.40 — RISC-V rv64 Linux

Status: planned
Depends on: R11.10

A RISC-V backend, RV64GC with the LP64D convention, whose instruction selection
R12.40 reuses for rv32.

Exit evidence: the corpus and GDB sessions on RISC-V hardware in the gate,
through the RISE project's runners, with QEMU user emulation as the fallback
if that service goes away.

### R11 gate

- Linux arm64, FreeBSD and rv64 Linux run the corpus in the gate.

## R12 — Microcontrollers

The chips people buy: RP2040 and RP2350, STM32, and Espressif's ESP32,
ESP32-S and ESP32-C series. Emulators first, as before, and boards beside
them rather than instead of them.

### R12.10 — Describe devices

Status: planned
Depends on: R11.10

A general SVD generator, memory profiles and linker configuration selected per
device instead of the one fixed 32 KiB profile, and boot image formats as
target facts. This schedules the SVD and linker halves of R551-33, R730-05's
larger profiles and the Cortex-M toolchain move SR-01.

Exit evidence: the RP2040 fixture regenerated byte for byte by the general
generator, a second device family generated, and every capacity verdict rerun
against each selected profile with the 32 KiB reference retained.

### R12.20 — The first board

Status: planned
Depends on: R12.10

Raspberry Pi Pico, an RP2040 with the ARMv6-M the backend already emits: its
second-stage boot, flashing through a debug probe, and a smoke procedure
checked against the emulator lanes' oracles.

Exit evidence: the derived driver running on the board, its captured trace
checked against the same oracle, and the run recorded here.

### R12.30 — Thumb-2, Cortex-M33 and M4F

Status: planned
Depends on: R12.20

The ARMv7-M and ARMv8-M instruction sets and the hardware floating point of
the M4F, for RP2350 and an STM32 Nucleo board, with QEMU's M33 machine as the
emulator lane.

Exit evidence: the Cortex-M corpus on the emulator lane in the gate, and a
recorded run on each board.

### R12.40 — RISC-V microcontrollers

Status: planned
Depends on: R11.40, R12.10

rv32imac for RP2350's Hazard3 cores and ESP32-C3 and C6, including the ESP
application image format.

Exit evidence: the freestanding corpus on an emulator lane in the gate, and a
recorded run on each board.

### R12.50 — Xtensa, ESP32 and ESP32-S3

Status: planned
Depends on: R12.10

A backend for the Xtensa LX6 and LX7, assembled with Espressif's toolchain and
run on Espressif's QEMU, which emulates both chips. Decided here: the windowed
calling convention, whose window overflow and underflow handlers compiler-owned
startup then provides, or CALL0 throughout, which has none.

Exit evidence: the freestanding corpus on Espressif's QEMU in the gate, and a
recorded run on each board.

### R12.60 — Boards in the gate

Status: planned
Depends on: R12.20, R12.30, R12.40, R12.50

A self-hosted runner with the boards attached, run for `main` and by hand and
never for a pull request from a fork. This takes on R730-01.

Exit evidence: every board this phase supports runs its smoke procedure in the
gate, beside the emulator lanes it does not replace.

### R12 gate

- RP2040, RP2350, an STM32 board, ESP32, ESP32-S3 and ESP32-C run
  compiler-owned firmware in emulation and on hardware.

## R13 — The library

A standard library split where the capability model already splits it.

### R13.10 — Split freestanding from hosted

Status: planned
Depends on: none

`core/*` becomes what every target has, and hosted modules move under a
sibling root so that firmware cannot import them by accident. The root's name
is decided here, with [1480] and [1660] amended.

Exit evidence: the amended paragraphs, every existing module on its side of
the line, and a firmware build that refuses a hosted import by name.

### R13.20 — The freestanding library

Status: planned
Depends on: R13.10, R12.30

What firmware on the R12 boards needs, each facility driven by a complete
consumer: peripheral configuration beyond one baud rate, cache maintenance for
the cached profiles, and C on Cortex-M. This schedules R551-34's freestanding
part, and B5's, and R730-02, R730-07 and R730-09.

Exit evidence: each facility's consumer running on its targets with failure
oracles and measured cost on the constrained profiles.

### R13.30 — The hosted library

Status: planned
Depends on: R13.10

Files and directories, processes, the environment, time and sockets, each
driven by a complete consumer, with the operating system reached through the
same capabilities as now. This takes R551-34's hosted part, and with it B5's.

Exit evidence: each consumer running on every hosted target with failure
oracles.

### R13 gate

- The library's two halves are separate, and every facility has a consumer.

## R14 — Concurrency

Beyond blocking, by switching stacks rather than rewriting functions; "The
concurrency execution model" below binds this phase.

### R14.10 — Prototype 5

Status: planned
Depends on: none

A concurrent program written as a specification stress test, as the first four
prototypes were: a small network server with two operations in flight, and a
firmware counterpart that has to answer the same request on a single core.
Its findings are recorded as the first four's were.

Exit evidence: `prototype-5` with its findings, checked by `check.py` like the
other four.

### R14.20 — Stackful fibres

Status: planned
Depends on: R14.10

A stack switch on every target, specified with a register decision. This takes
on the stackful-fibre part of R551-35.

Exit evidence: fibres switching on every target with debugger backtraces
through a switch, and the single-core freestanding answer specified.

### R14.30 — A second Io

Status: planned
Depends on: R14.20, R13.30

An event-driven Io that runs fibres over epoll and kqueue.

Exit evidence: prototype 5's derived server running on the hosted targets over
both implementations of Io, unchanged.

### R14.40 — Threads and the atomic wrapper

Status: planned
Depends on: R14.20

Hosted threads, and the atomic wrapper type over D227's builtins that answers
Cortex-M0's missing read-modify-write explicitly. This takes on R730-21.

Exit evidence: consumers of both on every applicable target, with failure
oracles.

### R14 gate

- Prototype 5's derived programs run.

## R15 — Windows

### R15.10 — Windows x86-64

Status: planned
Depends on: R11.10

The Win64 calling convention, COFF objects, the unwind tables Windows requires
of every function that calls, and a hosted layer over the Windows API. Which
assembler and linker is decided here.

Exit evidence: the corpus on GitHub's Windows runners in the gate.

### R15.20 — Windows debugging

Status: planned
Depends on: R15.10

CodeView debug information in the objects, and PDB files from the linker
rather than written by the compiler.

Exit evidence: scripted debugger sessions on Windows in the gate.

### R15.30 — Windows arm64

Status: planned
Depends on: R15.20, R11.20

The same on arm64, which reuses the arm64 backend with Windows' variant of
its calling convention.

Exit evidence: the corpus and debugger sessions on GitHub's arm64 Windows
runners in the gate.

### R15 gate

- Windows runs the corpus and its debugger sessions on both architectures.

## R16 — Optimization

Measured first, and then only where the measurement says.

### R16.10 — Measure generated code

Status: planned
Depends on: none

Benchmarks with recorded time and size per target, tracked by the gate, and a
build report that counts the same things on every backend. This takes on
R730-24.

Exit evidence: baselines recorded for every target, and the gate failing on a
regression beyond a stated tolerance.

### R16.20 — Register allocation

Status: planned
Depends on: R16.10

Allocation for the arm64 backend's stack homes and the remaining x86-64 and
Cortex-M cases, the bounds check an indexed increment keeps, and the atomic
and barrier lowering, which is baseline. This takes on R551-12.

Exit evidence: measured improvement against R16.10's baselines with unchanged
behaviour, ABI and debugger evidence.

### R16 gate

- Every optimization is measured against a recorded baseline.

## The concurrency execution model

Carried from the first roadmap, because a settled position written nowhere
reads as an open question and gets reopened.

Concurrency is not a property of a function. It is a capability — an Io the
caller hands down, an ordinary parameter like an allocator, minted at the
entry point [1660] and enforced below it [1680]. The same code blocks or does
not depending on the Io it was given, so no keyword, no second calling
convention and no colored function type is needed to say it. The refusal this
replaces is recorded in `tour.md` under WHAT WAS TRIED AND DROPPED.

- **One Io implementation today, and it blocks.** Signatures and `core` are
  concurrency-capable without any scheduler existing. R14.30 adds the second.
- **Stackless coroutines are a non-goal.** Cutting functions into state
  machines is a compiler project of its own, and it puts the property into
  every function type that reaches one — the coloring the ambient environment
  was removed to avoid. This is a refusal, not a park: no trigger reopens it,
  only a decision to reverse it.
- **Stackful fibres are the route, and the backends keep them reachable on
  purpose.** A backend decision that forecloses switching stacks is a defect
  in that backend rather than a trade-off. The conditions are held for other
  reasons already: the frame pointer is always present, the callee-saved
  discipline is explicit, and no capability rides in a reserved register. The
  case to design against is a single-core freestanding target, where the
  honest answer to a request for concurrency is that there is none.

## Successor families

The first roadmap named six families as destinations for what it did not do.
They are kept as the owners of register records, not as roadmaps of their
own; a record that an item here takes on says so, and one that none does
waits for its activation.

- **Scale and self-hosting:** separate compilation and interface files,
  caching, cross-language stage transport and the incremental replacement of
  tested Ada stages.
- **Companion tool and ecosystem:** a build tool, package acquisition, version
  solving, manifests, locks, publishing, naming authority and generator
  orchestration. A build description between Zig's build program and a
  makefile was discussed when this roadmap was written and left out of it.
- **Broader standard library:** library facilities beyond what the prototypes
  needed.
- **Competitive optimization:** optimization beyond correct deterministic
  baseline code.
- **Language evolution:** parked constructs, watches and proposals whose
  triggers have not fired.
- **Release readiness:** distribution, production claims and every release or
  version decision.

## Register

What waits for a trigger. A record keeps the identity it was given — R551 and
R730 for the first roadmap's two debt ledgers, a letter and a number for the
review register it inherited, SR for records added since — because the first
roadmap's text refers to them. Merged records are folded into the record they
joined.

A status is `open`, waiting for its activation; `limit`, a measured boundary
that stands until its activation; `watch`, an observation waiting for
evidence; `scheduled` followed by the item that takes it on; or `retired`,
with the reason it no longer applies.

| Record | Family | What stands | Activation | Completion | Status |
| --- | --- | --- | --- | --- | --- |
| R551-06 | Scale and self-hosting | Flow snapshots, declaration-origin matrices, folding and dependency walks and IR scratch arrays have storage and stack costs that grow with input size. | A workload exceeding the recorded envelope, or before a persistent compiler service. | Bounded declaration, field and dependency measurements, owned storage and stated failure behaviour. | scheduled R8.20 |
| R551-07 | Scale and self-hosting | Final linker placement is not preflighted: Linux RIP-relative reach, Darwin's 2 GiB static-image collision and arm64 branch reach. Merged: R730-05, seventeen shared programs exceed the 32 KiB flash, 16 KiB RAM and 4 KiB stack profile in 72 capacity verdicts. | Before general large-image support, or a workload that needs it. | Bounded reach and layout evidence with the native control and its status-42 oracle retained. R12.10 takes R730-05's larger profiles. | open |
| R551-08 | Scale and self-hosting | Compact source or IR can still ask for enormous assembler repetition; small compiler output does not bound assembler memory or object size. | Before admitting larger images or generation policies. | A bounded emission policy tested on tiny shapes, with the forbidden giant-fixture boundary kept. | open |
| R551-09 | Competitive optimization | Guarded cleanups can expand quickly despite correct pop-before-run order. | A measured cleanup workload with unacceptable growth. | Selectors, effects and order preserved, with bounded size compared before and after. | open |
| R551-10 | Competitive optimization | Atom and symbol allocation and imported-module lookup repeat identity scans; simplification keeps size-dependent scratch work. | A measured lookup or simplification bottleneck, which R8.20's measurements are. | Complete identity keys with time and memory evidence on bounded inputs. | scheduled R8.20 |
| R551-11 | Competitive optimization | Frame and allocation planning is repeated by preflight, emission and debug output. | Profiling justifies sharing the plans. | One immutable plan owning emission and debug locations, with debugger agreement. | open |
| R551-12 | Competitive optimization | An indexed increment can keep an extra bounds check, and Darwin stack homes have no register allocation. Merged: R730-04, atomic and barrier lowering is baseline, not competitive. | Measured code-quality pressure. | Single evaluation, traps, addresses, ABI and debugger evidence preserved under measured improvement. | scheduled R16.20 |
| R551-15 | Scale and self-hosting | Nix provides a development shell and a flake built by hand, not cached derivations or CI. | An explicit decision to revisit Nix CI. | Builders, SDK identity, debugger permissions and cache provenance accounted for. | limit |
| R551-16 | Scale and self-hosting | Large nested stage procedures, duplicate construction helpers and unused interfaces such as `Needs_Source` remain. | Replacing or splitting the affected stage, or a change it obstructs. | Refactoring behind existing seams with strict warnings, removing only demonstrated dead interfaces. | open |
| R551-19 | Release readiness | No broad driver mutation or fuzz coverage; parser mutation is not whole-pipeline fuzzing. | Before robustness or production claims. | Fixed seeds, bounded resources, stage and target reach, crash classes and minimal reproducers. R10.50 takes the frontend part. `compiler/tests/fuzz/` is the seed: a single-file source mutator over the corpus, run by hand, with two recorded runs and the twelve reproducers they found. | open |
| R551-20 | Release readiness | Fake-host failure controls do not establish native device, capture or exhaustion failure paths. | Before claiming those native failure guarantees. | Controlled fault injection with cleanup and diagnostic oracles on each host. | open |
| R551-22 | Release readiness | The code face was removed from all history and the acceptance tags re-issued; only the vendored Nunito Sans remains. Its redistribution, which the pages depend on, is not settled. | Before distribution, or a font policy change. | A distribution decision keeping the private-font boundary. | open |
| R551-25 | Language evolution | Source-debug CFI is not a promise of foreign-exception unwinding. | An explicit proposal for runtime foreign unwinding. | Semantic, ABI and failure decisions, then native evidence. | limit |
| R551-26 | Language evolution | LLDB shows C scalar spellings and manual tag and payload selection, with no Landin expression evaluator. Merged: R730-12, Cortex-M0 debugging is lines and functions only. | A concrete debugger-usability proposal. | Truthful types and locations with native sessions for each new promise. | limit |
| R551-27 | Release readiness | Linux driver overrides follow the GNU contract; Darwin emits thin arm64 Mach-O, not universal binaries; no Clang header parsing. | A requested driver or distribution expansion. | Pinned producer and consumer, packaging and identity evidence. | limit |
| R551-28 | Language evolution | No callback-identity counterexample exists, and static rejection of known slice-range endpoints is not a normative requirement. | A valid counterexample or an explicit semantic proposal. | Present-contract defects go to their implementation owner; semantic changes need specification and tests. | watch |
| R551-32 | Scale and self-hosting | Stable separate compilation and interfaces, package identity in interfaces, cross-language stage transport and incremental self-hosting. | An explicit scope decision; planning R8 considered it and left it outside. | Tested seams and complete interface and package identity with whole-program semantics preserved. | open |
| R551-33 | Companion tool and ecosystem | Package acquisition, version solving, manifests, locks, naming authority, deterministic roots, generators and sandboxing; the binding generator's replacement of its four files is not atomic. Merged: R730-08, the RP2040 fixture is a bounded selection and no general SVD generator exists; R730-11, the firmware linker script is fixed. | Before acquisition, general generation or concurrent build consumers are offered. | Declared inputs and outputs, immutable publication, reproducible roots and single-version conflicts. R12.10 takes the SVD and linker halves. | open |
| R551-34 | Broader standard library | Library facilities beyond the prototypes' slices. Merged: R730-02, cache maintenance for cached device profiles; R730-09, UART configuration beyond one baud rate; R730-21, the atomic wrapper type. | A concrete program needs an omitted facility. | Capability-passed allocation and I/O, constrained-target costs, complete consumers and failure oracles. R14.40 takes the atomic wrapper. | scheduled R13.20 |
| R551-35 | Language evolution | The stackful-fibre exploration, and the parked and watched rows C1 to C5 and E1 to E3, each below. | For fibres, a program needing two operations in flight; each row's own trigger otherwise. | A tour amendment and register decision; stackless coroutines stay rejected. | scheduled R14.20 |
| R551-36 | Release readiness | Licensing and distribution, release and version designation, production and operational claims. | Explicit maintainer decisions. | Separate decisions, each with evidence. | open |
| R730-01 | Release readiness | Only emulators have run firmware; nothing is claimed about physical timing, bus, electrical or interrupt-arrival behaviour. | Before any physical-device or production firmware claim. | A pinned board and smoke procedure checked against the emulator lanes' oracles, which stay mandatory. | scheduled R12.60 |
| R730-03 | Release readiness | D227's ordering trials and bounded store-buffer models are evidence, not a formal proof; no wait-free or timing bound is claimed. | Before a claim beyond the bounded models, or any timing bound. | A stated proof or checked model agreeing with the native trials. | open |
| R730-06 | Release readiness | Stack paint and SP observation are measurements, not worst-case bounds; 64 spare flash bytes is a fit, not a budget; reset assumes no NMI or fault in its window. | Before a production budget, worst-case stack or fault-tolerant reset claim. | A workload and interrupt model with a checked bound, and reset-window behaviour with executable evidence. | open |
| R730-07 | Broader standard library | Cortex-M0 C source capabilities, `core/c` and header generation are disabled; 33 shared programs are general-C restrictions there. | A freestanding program that must call or be called from C. | An ILP32 `core/c`, Cortex-M0 C signatures enabled and executable C-boundary fixtures, with the 33 restrictions re-decided. | scheduled R13.20 |
| R730-13 | Release readiness | Source and debug identity selection is matching, not authentication or protection against concurrent replacement. | Before stronger provenance or attestation claims. | An attestation design with verified restore; the seven negative selections stay. | limit |
| R730-17 | Language evolution | A call returning a plain pointer cannot fill a several-atom pointer union through an atom `else`; D235 keeps it refused. | A program that needs that recovery to widen. | D235 amended with a recovery lowering and evidence on every target. | open |
| R730-20 | Language evolution | D237 leaves u128, i128 and f16 out. | A program that needs 128-bit arithmetic or binary16 values. | D237's recorded plan on every target. | open |
| R730-22 | Companion tool and ecosystem | No job runs the structural editor grammar's integration pass. | Before the editor packages are gated artifacts. | The pass in a named job that fails, with a pinned tree-sitter CLI. | scheduled R8.30 |
| R730-23 | Release readiness | A linked hosted image is not bit-reproducible: the GNU driver writes a random temporary object name, six bytes. | Before a reproducible-distribution claim. | Byte-identical images on both hosted targets, with the assembly-identity check kept. | open |
| R730-24 | Competitive optimization | Build-report counters are filled differently per backend, so a cross-target comparison from them is unsafe. | Before any cross-target code-quality comparison from the report. | Every declared counter filled on every backend, or the report saying which it does not measure. | scheduled R16.10 |
| R730-25 | Release readiness | `end-to-end/refine-identity`'s macOS arm64 evidence is a run, not a record the coverage readers read. | Before an end-to-end per-target claim is cited. | Every end-to-end target claim backed by a readable record. | scheduled R8.30 |
| B3 | Scale and self-hosting | Separate compilation: whole-program checking is done; stable interfaces are R551-32's. | As R551-32. | As R551-32. | open |
| B4 | Companion tool and ecosystem | Package, build and generators beyond the thin pieces the compiler owns; R551-33's. | As R551-33. | As R551-33. | open |
| B5 | Broader standard library | The standard library beyond the sixteen `core` modules; R551-34's. | As R551-34. | As R551-34. | scheduled R13.20 |
| B6 | Companion tool and ecosystem | Package naming authority, keeping the project-first override [1480]. | Before acquisition or a naming authority is offered. | A naming policy that keeps the project-first override. | open |
| D6 | Companion tool and ecosystem | One version of a package name per program [1470]; the compiler's first-root rule is done and arranging roots is the tool's. | Before acquisition or root arrangement is offered. | Roots arranged so one version is reachable, a conflict a hard error. | open |
| C1 | Language evolution | Affine values, which would change [0910]'s non-ownership `sink`. Merged: R730-10, the derived driver's device authority, descriptor linearity and stop are manual obligations. | A peripheral or resource program unpleasant without them. | [0910] amended with a register decision answering R730-10's obligations, on every target. | open |
| C2 | Language evolution | Conformances as named values. | Conformance collisions hurting in real libraries. | A register decision weighed against retained position D2, with library consumers. | open |
| C3 | Language evolution | Restricting root capability minting to the entry module [1680]. | Wanting to run untrusted code. | [1680] amended with a register decision. | open |
| C4 | Language evolution | Generational observers and inferred uniqueness; no trigger was ever given. | None until later evidence supplies one, recorded first. | That trigger recorded, then a design with its own evidence. | open |
| C5 | Language evolution | Structure-of-arrays collections [0620]. | A simulation program needing one field contiguous. | [0620] enabled by amendment and register decision, with executable evidence. | open |
| E1 | Language evolution | Labels, `break with` and `complete` are implemented and none of the four derived programs uses them. | A proposal to remove or reshape them, with evidence beyond non-use. | A tour amendment and register decision. | watch |
| E2 | Language evolution | Concept width [1260]: one case each way. | A real library whose concept must widen or split. | [1260] confirmed or amended. | watch |
| E3 | Language evolution | Two kinds of generated source exist, SVD modules and C bindings; a third starts the review of retained position D3. Generating the compiler's transcription tables from `spec.md` would be a third. | A third kind of generated source. | That review recorded against D3's rationale. | watch |
| SR-01 | Release readiness | The Cortex-M lane pins `arm-none-eabi-gcc` 14.2.1; the same publisher's `arm-eabi-gcc` 16.1.0 builds a valid image, and moving changes every recorded firmware hash and disassembly. | R12's new cores rebaseline the firmware records anyway. | The toolchain moved with every Cortex-M record rebaselined in one change. | scheduled R12.10 |
| SR-02 | Scale and self-hosting | The corpus at one worker measured 4,523 s on CI against 3,592 s before the parallelism change; single shared-hardware samples cannot tell variance from a regression. | R8.20's measurements. | Settled by repeated measurement, or made moot by R8.20. | scheduled R8.20 |
| SR-03 | Language evolution | A module value cannot hold `addr` of storage: [1940]'s known values are numbers, and a static address is a data relocation no backend emits. L0305 refuses it; its note names the first roadmap's closed vector-table item as the owner, and R8.10 rewrites the note to say what state the construct is in, which leaves this record as its only owner. | A program needing a static pointer: a vector table it owns, a table of pointers into module storage, or a statically linked structure. | [1940] amended with a register decision, data relocations emitted on every target, and `negative/r491-construction-static-address` turned into executable fixtures. | open |
| R551-13 | Scale and self-hosting | Workload scheduling and artifact reuse for the exact-revision acceptance. | — | — | retired: the acceptance was removed |
| R551-14 | Scale and self-hosting | Interrupted Darwin acceptance could not resume. | — | — | retired: the acceptance was removed |
| R551-21 | Release readiness | The original R1 to R3 acceptance bundles are unrecoverable. | — | — | retired: nothing accepts revisions, and no claim rests on them |
| R551-23 | Release readiness | Native acceptance evidence had no backup, expiry or attestation. | — | — | retired: nothing produces native evidence now. The Linux and Darwin bundles of the last approval before 0.2.0, `ci/accepted/57d1c76a`, remain on the maintainer's Mac, and on 2026-09-23 their records and source archive matched that tag's hashes; they have no backup, and no claim rests on them. R730-13 stands on its own |
| R551-24 | Release readiness | Two-domain publication was not atomic. | — | — | retired: `pages.yml` is the one publisher |

## Retained positions

Six positions an outside review challenged and the project kept. Reopen one
only with new evidence that answers its rationale, and record the reopening.
These D labels are the review's, not `spec.md`'s decisions.

| Position | What was kept, and why |
| --- | --- |
| D1 | Integer indexing of UTF-8 text by codepoint ordinal, linear, for ergonomics [0610]; reopen only with program or measurement evidence. |
| D2 | No weak conformances and no orphan rule: a collision is an error, answered with `distinct` or an explicit function [1280], because a weak conformance lets an application silently change a generic library's behaviour; reopen on ecosystem-scale evidence. |
| D3 | No compile-time execution and no macros; generated source comes from programs the build runs [1540]. A third kind of generated source starts its review (E3). |
| D4 | `escaping` and `from` are written, not inferred, to keep checking local and because an allocator is a counterexample to inferred `from` [0790] [0900]. |
| D5 | Landin's own backends emitting assembly; not LLVM, a dependency larger than the language, and not C, which loses the calling convention, the traps and the debug information [1550]. |
| D6 | One version of a package name per program: 32 KB of flash, nominal types and one conformance register [1470]. |

## The first roadmap

Every item of R0 to R7, all complete. The text is at commit `335b0814`; this
index exists so that the citations R8.10 removes resolve until it does, and
R8.10 deletes it.

| Item | Title |
| --- | --- |
| R0.10 | Establish bootstrap repository layout |
| R0.20 | Pin the canonical Ada toolchain |
| R0.30 | Establish shared fixtures and custom harness |
| R0.40 | Establish source and diagnostic foundations |
| R0.50 | Establish compiler and platform-tool boundaries |
| R0.60 | Establish tested stage and target seams |
| R0.70 | Establish development and validation environments |
| R1.10 | Add the normative kernel grammar |
| R1.20 | Implement lexical analysis |
| R1.30 | Establish the diagnostic catalogue |
| R1.40 | Implement the recovering parser |
| R1.50 | Collect declarations and resolve names |
| R1.60 | Check the executable kernel |
| R1.70 | Implement target-neutral IR and verification |
| R1.80 | Implement the minimal Linux x86-64 native path |
| R1.90 | Close the executable-kernel corpus |
| R2.10 | Establish target-parametric data layout |
| R2.20 | Implement aggregates, variants and complete value layout |
| R2.30 | Implement functions, control flow and declared errors |
| R2.40 | Implement fixed parameters and compile-time substitution |
| R2.50 | Implement references and local lifetime checks |
| R2.60 | Implement concepts and conformance collection |
| R2.70 | Implement the generic evidence schema |
| R2.80 | Implement `any C` |
| R2.90 | Establish guarantee and semantic coverage registers |
| R3.10 | Implement minimum modules and ordered roots |
| R3.20 | Build the allocator and container pressure case |
| R3.30 | Implement honest raw storage and `core/mem` |
| R3.40 | Implement parser-support core modules |
| R3.50 | Implement the minimum hosted ABI and I/O |
| R3.60 | Implement diagnostics as runtime dispatch |
| R3.70 | Complete and run the derived parser program |
| R3.80 | Ship editor and forge language support |
| R4.10 | Close the hosted construct matrix |
| R4.20 | Complete hosted core containers and library slice |
| R4.21 | Repair review-found soundness and correctness defects |
| R4.30 | Complete hosted modules and toolchain directives |
| R4.40 | Implement the narrow complete C ABI and bindings |
| R4.50 | Implement baseline code generation and specialization |
| R4.60 | Implement usable Linux source debugging |
| R4.70 | Complete and run the derived container program |
| R4.80 | Complete and run the derived hosted application |
| R4.90 | Close Linux hosted parity |
| R4.91 | Resolve post-R4 review findings |
| R5.10 | Establish the native macOS compiler environment |
| R5.20 | Isolate target contracts |
| R5.30 | Implement Darwin arm64 lowering |
| R5.40 | Implement macOS arm64 source debugging |
| R5.50 | Close hosted target parity |
| R5.51 | Organize retained debt and repair phase handoffs |
| R6.10 | Select the Cortex-M execution profile |
| R6.20 | Instantiate the 32-bit layout and ABI |
| R6.30 | Define and implement the concurrency memory model |
| R6.40 | Define and implement packed invalid encodings |
| R6.50 | Implement the Cortex-M backend |
| R6.60 | Implement startup, vectors and machine directives |
| R6.70 | Implement the freestanding Landin core slice |
| R6.80 | Establish checked-in generated device fixtures |
| R6.90 | Complete and run the derived driver program |
| R6.100 | Close freestanding evidence |
| R7.10 | Audit every normative construct |
| R7.20 | Close deferred normative behavior |
| R7.30 | Disposition every inherited item |
| R7.40 | Close all evidence registers |
| R7.50 | Prove deterministic baseline toolchain behavior |
| R7.60 | Run complete derived prototype coverage |
| R7.70 | Declare the roadmap endpoint |
