# Landin — orientation

Everything a fresh reader, or a fresh session, needs before touching
anything. Kept current at specification **0.1.0** while the bootstrap compiler
advances through the roadmap.

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
compiler-supplied conformances, beginning with `zeroable`; their exact
interaction with explicit conformances is resolved from implementation
evidence at R2. Generic code is a value plus evidence that its type
satisfies a concept; `any C` is the same evidence with the type erased,
which makes static generics and runtime dispatch one mechanism seen from
two sides. The evidence table is the foundation and specialising is an
optimisation weighed per instantiation against code size.

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
Semicolons optional.

**The machine** is served by Landin's own native backends. The bootstrap
compiler is written in Ada 2022 with pinned GNAT/GPRbuild, minimal
dependencies, no SPARK, and a custom test harness. It compiles whole
programs, may keep private caches, and lowers through a verified,
target-neutral internal IR that evolves from implementation evidence to
assembly text for the platform assembler and linker. The frame pointer
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
   needs them, and record the decision, dependencies, evidence, and
   disposition in `ROADMAP.md`.
3. Turn the prototypes into derived positive and negative conformance
   tests while preserving their historical finding sections.
4. When implementation changes semantics, update `tour.md`, the
   affected prototype-derived tests, and `ROADMAP.md` together, then
   reread the prototypes against the revision and against each other.
5. Run `check.py`. Every new cheap invariant, and every defect it once
   missed, belongs there.

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
reopen them are in `ROADMAP.md`'s inherited review register.

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

**The bootstrap compiler is working.** R0's Ada chassis, R1's executable
kernel, R2.20's aggregate/value-layout work and R2.30's functions, control,
declared errors, function fields, recursive module images, computed aggregate
elements and lexical `defer`/failure-only `undo` cleanup are complete. R2.40's
fixed parameters, compile-time substitution, generic routine instances and
fixed conditional declarations are complete. R2.50's pointers, slices,
conventions, local origins and borrows, `escaping`, `from`, consume checking
and target reference carriers are complete. R2.60's concepts, constraints,
whole-program conformance register and closed compiler `zeroable` family are
complete.

R2.70's target-neutral evidence order, target-derived Linux/synthetic-32 table
layout, hidden evidence arguments, indirect concept calls and
representation-compatible shared machine bodies are complete. R2.80's exact
`any C` identity, explicit/inferred pointer erasure, object-safe
mutable/immutable dispatch, flattened composed tables, two-word target layout,
origin propagation and aggregate/shaped ABI are complete. R2.90's guarantee,
diagnostic, conformance/evidence, prototype-derivation and target-applicability
registers are complete, mechanically closed over the implementation corpus and
owned by executable rejection, trap or explicit non-guarantee evidence.

**Current roadmap work: R3.10 — Implement minimum modules and ordered roots.**

`refine` runs the frontend, lowers and
verifies target-neutral IR, emits Linux x86-64 assembly, and can assemble and
link a hosted executable whose runtime behaviour the native x86-64 gate
checks. macOS arm64 and Cortex-M backends and the standard library remain
future work. `ROADMAP.md` is the sole durable work authority. Outstanding
grammar, representation, ABI, guarantee, and diagnostic questions are settled
by the first phase that needs them rather than forming one blanket front-end
barrier.

The first major compiler milestone is R3: a complete derived version of
the parser prototype with useful diagnostics, evidence-table dispatch,
and `any`, explicitly without specialization. Work then proceeds through
the complete hosted Linux x86-64 path, native macOS arm64, and
emulator-first Cortex-M.

The endpoint is feature-complete pre-v1. Production claims, release
versioning, package acquisition, competitive optimization, and
self-hosting are outside this roadmap. A future self-hosting roadmap may
replace tested Ada stages incrementally, but none is scheduled now.

---

## Working style

German conversation, English keywords, identifiers and documents
throughout. No backticks in prose. Prefer deciding over deferring, and
say plainly where a decision is a guess. Push back with reasons rather
than agreeing.
