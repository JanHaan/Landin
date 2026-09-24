# Landin — orientation

Everything a fresh reader, or a fresh session, needs before touching
anything. Kept current at specification **0.2.1**, the first under the
second implementation roadmap.

---

## What this is

A systems language, a compiler and a small standard library, built from
scratch as a serious learning project. The scale is Odin, Hare, Crystal
— one person, several years.

**The range is the point.** A Cortex-M0 with 32 KB of flash at one end,
a hosted application at the other, and the same way of writing code on
both. Every decision in the specification was taken against both ends
at once, and several of them look odd until you remember the small end.

---

## The design, in one page

**Memory** is manual, and arenas are the idiom. No garbage collector,
no reference counting, no destructors. Allocation is an ordinary
concept, so a container runs on a heap, in an arena, or on a fixed
buffer with no dynamic allocation at all — and a deliberately failing
allocator makes the out-of-memory paths testable, which almost nobody
bothers with in C because it is too awkward.

**References** answer two independent questions in two places. `mut` on
the binding says whether the name may be re-pointed. `mut` inside the
type — `ptr mut T`, `[]mut T` — says whether the thing may be written.
A `mut` reference satisfies a plain one, one way only; that is not an
implicit conversion, because no bit changes and a permission is merely
forgotten. Permission is shallow: an `in` parameter protects the value,
not what it points at, because deeper protection needs to know what a
value owns and this language does not track ownership.

**Lifetime** has no borrow checker and no annotations. Every reference
carries an origin — static, allocated or frame — and frame origin may
not be returned or stored anywhere longer-lived. Origins join to the
shortest-lived part. `escaping` marks a parameter the callee may keep;
a `from` clause marks a returned reference as borrowing what it came
from. Both are written rather than inferred, deliberately: inference
across calls lets a distant body change a signature, and for `from`
inference was shown to get the allocator wrong.

**Errors** are atoms in a dedicated register, declared per function
after `!`, with `fail`, `try` and an `else` clause on the call. No
exceptions, no unwinding, no catchable panics. And only half of what
goes wrong belongs in that channel: the test is whether it can be
determined from what you already hold. A syntax mistake is in the bytes
you are looking at, so check it and work around it; out of memory hangs
on the world, so `fail`. `undo` is defer's machinery under a condition,
running only when its block is left by `fail`.

**Types** are static with local inference and no implicit conversions.
Atoms are identity without payload and serve as enumerations, error
sets, variant tags, register encodings and panic kinds alike — there is
no `enum`, because nothing is left for it to be. Structs may carry a
variant part. `distinct` inherits no operations. Range subtypes are
checked. Overflow traps and wrapping is a separate operator.

**Generics** take the type as an ordinary compile-time parameter.
Concepts are named requirement bundles with explicit conformances,
declared anywhere, and a collision is simply an error. The inherited
design also requires a closed, named set of representation-derived
compiler-supplied conformances. D143 settled `zeroable` as a closed
compiler concept family: source conformances can neither add an entry nor
override one. Generic code is a value plus evidence that its type
satisfies a concept; `any C` is the same evidence with the type erased,
which makes static generics and runtime dispatch one mechanism seen from
two sides. The evidence table is the foundation and specialising is an
optimisation weighed per instantiation against code size. D211 distinguishes
semantic instantiation from optional dispatch specialization: incoming evidence
must be proved, hidden evidence/result ABI positions remain, and heterogeneous
`any` dispatch needs no specialization. Size/auto defaults are independent of
build mode. `unchecked` establishes no optimizer facts. D210 reorders only an
explicitly optimal struct on a strict padded-size win, and reports remain
off-target rather than imposing runtime machinery on a 32 KB device.

**Capabilities** replace effects. An allocator, an Io, a diagnostics
log, a peripheral handle are values a function is given, so a function
that was given none cannot do the thing — below a root. There are two
roots and both are nameable: the entry point, and an address literal in
a driver. Between them it is enforced; at them it is a habit, and the
specification says so rather than claiming more.

**Syntax** is `name: type = value`, with the name always left of the
colon. Immutable by default. Keyword blocks closed by `end`, and blocks
are expressions — a block has the value of its last expression, and
`if`, `match`, `else` clauses and loops all follow from that one rule.
Statements need no terminator.

**The machine** is served by Landin's own native backends. The bootstrap
compiler is written in Ada 2022 with pinned GNAT/GPRbuild, minimal
dependencies, no SPARK, and a custom test harness. It compiles whole
programs, may keep private caches, and lowers through a verified,
target-neutral internal IR that evolves from implementation evidence to
assembly text for the platform assembler and linker. The ordinary frame pointer
is always present. Linux x86-64 comes first, native macOS arm64 second, and emulator-first Cortex-M third. Not
LLVM, which is a dependency larger than the language, and not C, which
loses the calling convention, traps and debug information the design
spends its precision on. Ada package boundaries are tested seams for
possible stage replacement under a future self-hosting roadmap;
self-hosting is not part of the current roadmap and no cross-language
stage protocol is frozen now.

**Deliberately absent:** classes, inheritance, methods, runtime type
information, exceptions, unwinding, garbage collection, reference
counting, destructors, capturing closures, implicit conversions, null,
positional tuples, function name overloading, multiple dispatch,
user-defined operators, macros, compile-time execution, separate
interface files, header parsing.

---

## The principles

- **Require a capability, do not track an effect.** Below a root, a
  function can do only what it was given, and the argument list is the
  whole enforcement. That is why there is no effect system.
- **One mechanism with two readings beats two mechanisms.** Static
  generics and runtime dispatch are one thing from two sides.
- **Atoms are the same idea wherever they appear.**
- **Check once, then carry the proof.** A buffer that passed the
  alignment test becomes a `dma_buffer`, and the interface asks for
  nothing else.
- **How a new feature earns its place.** Can an existing mechanism
  express it? Then a library. Can the compiler work it out? Then no
  syntax. Must the programmer say it, and does saying it remove another
  mechanism? Then a candidate. Does it only solve this one case? Then
  not yet. A new mechanism should let two old ones leave the building —
  and one of them actually has.

---

## How the work is done

1. Start with the smallest executable vertical slice; do not require
   unrelated language foundations to be settled first.
2. Resolve language and architecture questions when the first slice
   needs them. Record the decision, its alternative and the fixture that
   pins it in `spec.md`'s register of decisions, and any work it leaves in
   `ROADMAP.md`.
3. Turn the prototypes into derived positive and negative conformance
   tests while preserving their historical finding sections.
4. When implementation changes semantics, update `tour.md`, the
   affected prototype-derived tests, and `ROADMAP.md` together, then
   reread the prototypes against the revision and against each other.
5. Run `check.py`. Every new cheap invariant, and every defect it once
   missed, belongs there.
6. State the relation before measuring the property. A determinism,
   parity or reproducibility claim with no stated equivalence — what may
   differ between two runs and still count as the same build — is not a
   claim, and it will be read later as stronger than it was. Say what
   varies, say what is not claimed, and give the claim a gate that can
   refuse it; a check nobody can fail reports success while the property
   rots.

Two habits that produced most of the good outcomes, and that are worth
keeping deliberately. **Disagreement gets argued out rather than
smoothed over** — the best decisions here came from someone pushing
back with a reason. And **an overstated claim gets corrected in place**:
several findings said more than was true, several principles claimed
more than the language delivered, and saying so plainly was worth more
than the claim.

---

## Positions held — do not reopen quietly

Each of these has been argued against by an outside reader and kept on
purpose. Reopening is allowed; doing it quietly is not, and doing it
without new evidence is a waste. The reasons and evidence required to
reopen them are in `ROADMAP.md`'s retained positions.

- Integer indexing of `utf8` stays, at a linear scan, for ergonomics.
- No weak conformances and no orphan rule yet.
- No compile-time execution and no macros.
- `escaping` and `from` are written, not inferred.
- Its own backend, not LLVM and not C.
- One version of a package name per program.

And one thing that is *not* a held position but reads like one: `sink`
is a use-after-consume check on one place, not ownership. A copy taken
beforehand is refused nothing. Affine values are the other thing, and
they are parked with a condition rather than refused.

---

## Where the work stands

The specification is coherent and mechanically checked. Four prototypes
exist and all their findings are worked in. Independent reviews are folded
back into the specification, roadmap and executable evidence rather than kept
as a second authority.

**The bootstrap compiler is working.** It scans, parses, resolves and checks
whole programs, lowers them into verified target-neutral IR and emits
assembly for three targets. What it covers, by capability:

- **The language.** Functions, aggregates and variants, function fields,
  recursive module images, block-valued control, declared errors, lexical
  `defer` and failure-only `undo` cleanup, every loop and literal family, the
  enabled scalar conversions, condition declarations, caller parameters,
  range subtypes, `unchecked` regions and the atom-or-pointer unions.
  Generics take fixed parameters by compile-time substitution, with fixed
  conditional declarations and per-instance inferred errors. Concepts carry a
  whole-program conformance register and the closed compiler `zeroable`
  family. One target-neutral evidence order serves hidden evidence arguments,
  indirect concept calls, shared machine bodies and `any C`'s two-word pair
  with object-safe dispatch and flattened composed tables. Pointers and slices
  get local origins and borrows, `escaping`, `from` and consume checking.
  Directory modules have file-local import scopes, aliases, selected imports,
  public qualified lookup, typed global options, compiler facts, assertions
  and ordered roots with deterministic graph closure. D227's concurrency
  memory model supplies scalar atomics, volatile accesses and explicit
  barriers, and D228 packed raw images with checked encoded-field extraction
  and explicit reserved-bit and access policies. Every normative construct has
  a row in `compiler/tests/constructs.matrix` with its state, targets and
  evidence, and `check.py` refuses a missing, stale or unexplained one.
- **The library.** `core` threads heap, arena, pool and failing allocators as
  capabilities, and `core/mem`, `core/vec`, `core/small`, `core/map`,
  `core/tree` and `core/sort` sit on honest raw storage with every container
  transition, allocation rollback and unsafe obligation written down.
  `core/text` has byte-oriented positions and validated conversions, `core/io`
  interchangeable system and memory worlds, `core/diag.log` bounded and
  streaming providers dispatched through `any`, and `core/region` explicit
  bulk cleanup over a supplied provider. D212 withdraws both builtin arena
  forms and W7's transitive escape promise while preserving ordinary local
  origins. A freestanding slice adds CPU support, nonreturning signatures and
  panic dispatch with optional source maps. Of the eleven running examples, the
  four that write output — FizzBuzz and the three Benchmark Game programs —
  import `core` and are held to exact output oracles.
- **The C boundary.** Each hosted target's C ABI, `layout(c)`, callbacks and
  variadic call transport. A separate header generator and policy-driven C
  adapters cover the supported enum, union, bitfield, global/TLS and
  incoming-varargs boundaries; unsupported C forms receive explicit refusals.
- **Targets.** Linux x86-64 and Darwin arm64 build and run hosted executables,
  Darwin with an explicit large-image loader limitation. Cortex-M0 lowers to
  ARMv6-M Thumb with 32-bit layouts, the external AAPCS and Landin's internal
  ABI, r11 frame chains and soft scalar arithmetic. D229 enables its
  compiler-owned reset, data/RAM-code copying, BSS clearing, typed
  interrupt/naked functions, vector references, placement/retention and fixed
  assembly with explicit effects, within the selected 32 KiB flash, 16 KiB RAM
  and 4 KiB stack reservation. The
  [firmware execution lane](environments/cortex-m/README.md#compiler-owned-firmware)
  runs it on pinned QEMU and synthetic Renode peripherals beside independent
  C/assembly controls, and thirty RP2040 registers are checked in as generated
  device fixtures.
- **Code generation.** Deterministic baseline code: target code and the build
  report are identical under a stated relation of build directory, working
  directory, output path, environment, repetition and order on all three
  targets, and the hosted linked image is deliberately not claimed. Compact
  numeric-array loops, strict-saving `layout(optimal)` placement and
  independently controlled evidence-proved specialization are optional and
  reported factually.
- **Debugging.** DWARF source lines, symbolic frames and inspectable
  parameters and locals under GDB on Linux, including optimized caller frames;
  LLDB with exact Mach-O/dSYM identity on Darwin; line and function debugging
  on Cortex-M0. Debug provenance remains independent of DWARF encoding for a
  possible future PDB emitter; PDB support is not implemented.
- **Derived programs.** Prototype 2's recursive configuration parser retains
  valid nested AST nodes while recovering three ordered syntax faults, and
  runs unchanged through bounded and streaming `any diag.log`
  implementations. Prototype 3's container client and prototype 4's log
  filter — runtime-selected filters and destinations, complete lines across
  arbitrary chunks, copied arguments and explicit delivery retry — run beside
  it on Linux and macOS with native debugging coverage. Prototype 1's driver
  runs on the Cortex-M0 emulators. Each derivation row carries a generated
  oracle, and its derivation manifest keeps the evidence traceable to its
  prototype.

The Linux gate runs the corpus; Darwin and Cortex-M results come from native
runs nothing automates. Every inherited item and later discovery has a
terminal disposition, and the transferred ones are owned by the successor
families the current roadmap's register carries. Feature-complete pre-v1 is a
claim about coverage and nothing else, and the recorded boundaries stand
exactly as measured. The broader standard library remains successor work.
`ROADMAP.md` is the sole work authority. Outstanding grammar,
representation, ABI, guarantee, and diagnostic questions are settled by the
first slice that needs them rather than forming one blanket front-end
barrier.

The first major compiler milestone was a complete derived version of
the parser prototype with useful diagnostics, evidence-table dispatch,
and `any`, explicitly without specialization. Work then proceeded through
the complete hosted Linux x86-64 path, native macOS arm64, and
emulator-first Cortex-M.

The first roadmap's endpoint was feature-complete pre-v1, and it closed
there. The current `ROADMAP.md` starts where it stopped: a frontend that
scales and serves an editor, assembly with operands, more hosted targets, the
RP2040, RP2350, STM32 and ESP32 families, a library split into freestanding
and hosted halves, concurrency, Windows and measured optimization. A build
tool, package acquisition, release versioning and self-hosting stay outside
it, owned by the successor families its register names. Its identities are
cited in `ROADMAP.md` and nowhere else.

**Next roadmap item: R8.10 — Remove the first roadmap's citations (planned).**

---

## Working style

German conversation, English keywords, identifiers and documents
throughout. Backticks mark code, names and paths, never emphasis. Prefer
deciding over deferring, and
say plainly where a decision is a guess. Push back with reasons rather
than agreeing.
