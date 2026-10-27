# Landin — orientation

Everything a fresh reader, or a fresh session, needs before touching
anything. Kept current at specification **0.2.8**, the eighth under the
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
The stated 32 TB hosted endpoint is an unverified project goal: what it
measures and the evidence needed to prove it remain open. Existing hosted
runs do not establish a 32 TB bound.

---

## The design, in one page

**Memory** is manual, and arenas are the idiom. No garbage collector,
no reference counting, no destructors. Allocation is an ordinary
concept, so a container runs on a heap, in an arena, or on a fixed
buffer with no dynamic allocation at all — and a deliberately failing
allocator makes the out-of-memory paths testable, which almost nobody
bothers with in C because it is too awkward. An ordinary arena or counted
arena accepts only backing the caller may retain; a frame buffer requires
the explicitly named unchecked constructor because allocator results carry
no backing origin. What is edited, a list or a map, is passed `inout`; a
service, an allocator or an I/O provider, is a handle: a small copyable value
passed `in` that refers to state its caller declares, checked once where it
is made, so sharing one locks nothing.

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
inference was shown to get the allocator wrong. A checked arena constructor
therefore rejects frame backing before its origin-erasing allocation path can
hide that frame lifetime.

**Errors** are atoms in a dedicated register, declared per function
after `!`, with `fail`, `try` and an `else` clause on the call. A
`try for` propagates a streaming iterator's declared per-step failure;
the caller can handle it with that same call `else`. No
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
must be proved, hidden evidence positions selected by the checked instance body
and hidden result positions remain, and heterogeneous `any` dispatch needs no
specialization. Size/auto defaults are independent of
build mode. `unchecked` establishes no optimizer facts. D210 reorders only an
explicitly optimal struct on a strict padded-size win, and reports remain
off-target rather than imposing runtime machinery on a 32 KB device.

**Capabilities** replace effects in interfaces. An allocator, an Io, a
diagnostics log, a peripheral handle are values a function can receive.
Their parameters show which supplied values it uses, but do not bound
what the function can do: any ordinary hosted routine can call the public
host I/O or heap constructor, and a driver can form an address literal.
Passing roots from the entry point is a convention, not a checked effect
boundary.
Provider parameters still let callers substitute an in-memory world or
bounded allocator for code that uses them. A whole-call-tree claim needs
inspection of its calls and imports; signatures alone do not establish it.

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
assembly text for the platform assembler and linker. Hosted routines keep an
ordinary frame pointer; eligible Cortex-M leaves use SP-relative homes and
preserve r11. Linux x86-64 comes first, native macOS arm64 second, and emulator-first Cortex-M third. Not
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

- **Require a capability, do not track an effect.** Interfaces pass
  capabilities as ordinary arguments. The argument list exposes the
  supplied dependencies; it cannot rule out a fresh host root or an
  address literal in an ordinary routine. Substitution is reliable for
  uses of the supplied provider, not a proof that the entire call tree
  avoids the host. There is no effect system.
- **One mechanism with two readings beats two mechanisms.** Static
  generics and runtime dispatch are one thing from two sides.
- **Atoms are the same idea wherever they appear.**
- **Check once, then carry the proof.** A buffer that passed the
  alignment test becomes a `dma_buffer`, and the interface asks for
  nothing else. The checked value carries the proof; a preceding guard
  on an ordinary integer does not itself give that integer a range
  subtype or remove the check when it enters one (D188).
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

The specification is coherent and mechanically checked. Five prototypes
exist. The first four's findings are all worked in; the fifth's are open and
belong to the concurrency phase. Independent reviews are folded
back into the specification, roadmap and executable evidence rather than kept
as a second authority.

The current compiler capabilities, targets, execution coverage and recorded
limits are maintained in [the README](README.md#current-compiler-capabilities).
The [construct matrix](compiler/tests/constructs.matrix) records each
normative construct's state and evidence; completed roadmap items record
what landed and where its exit evidence is.

Every inherited item and later discovery has a terminal disposition, and
the transferred ones are owned by the successor families in the current
roadmap's register. Feature-complete pre-v1 is a claim about coverage.
The broader standard library remains successor work. `ROADMAP.md` is the
sole work authority. Outstanding grammar, representation, ABI, guarantee,
and diagnostic questions are settled by the first slice that needs them
rather than forming one blanket front-end barrier.

The first major compiler milestone was a complete derived version of
the parser prototype with useful diagnostics, evidence-table dispatch,
and `any`, explicitly without specialization. Work then proceeded through
the complete hosted Linux x86-64 path, native macOS arm64, and
emulator-first Cortex-M.

The first roadmap's endpoint was feature-complete pre-v1, and it closed
there. The current `ROADMAP.md` starts where it stopped: a frontend that
scales and serves an editor, assembly with operands, more hosted targets, the
RP2040, RP2350, STM32 and ESP32 families, a library split into freestanding
and hosted halves, concurrency and measured optimization. A build
tool, package acquisition, release versioning and self-hosting stay outside
it, owned by the successor families its register names. Its identities are
cited in `ROADMAP.md` and nowhere else.

**Next roadmap item: R14.20 — Stackful fibres (planned).**

## Versions

The specification's version is the README's status line; the tour repeats
it. What each version changed, with the decisions in `spec.md` that record
it:

| version | what it changed |
|---|---|
| 0.1.0 | The first version of the specification proper, after seventeen pre-release revisions, four prototype programs and two outside reviews. |
| 0.2.0 | Sealed the first implementation roadmap: a working compiler, with the specification held to what that compiler could be made to do. |
| 0.2.1 | The specification arranged by subject under the second roadmap, and the rules an outside review found unwritten or wrong: D243 to D245, and where Darwin puts a small composite on the stack [1975]. |
| 0.2.2 | Assembly with typed operands bound to registers [1630], D248, lowered on Cortex-M0, x86-64 and arm64. A refusal by name says what the form is, D246; a routine or struct holds at most a stated number of what it declares, D247. |
| 0.2.3 | The compiler as a tool. A warning is the compiler's judgement with the exact fix that settles it, D251; a source has one layout, which `refine fmt` gives it, D252; an editor is answered by `refine lsp`, past a broken routine body, D253; a doc comment is about the declaration directly below it, [2000] and D254. A UTF-8 index decodes the codepoint it selects, D249, and a range selection is a view and not a place, D250. |
| 0.2.4 | Linux arm64, the standard AAPCS64 with an unsigned plain char, D256. A build assumes a CPU feature level that changes no layout, D255, and targets the compiler's own host unless another is named, D257. A traversal that can fail is written `try for`, [0960] and [1320]; a capability parameter selects a provider without excluding new roots, D258; a UTF-8 ordinal index spans the whole text view, D259. |
| 0.2.5 | A parse's mistake stays inside its construct and the reports it causes are suppressed, D260; a refused statement is reported as the smallest change that mends it, offered to tools as a repair, D261; an import without a root is refused at the import, D262; a checker refusal poisons what it refused, D263. |
| 0.2.6 | FreeBSD x86-64 and arm64, with hosted system identity separate from C transport, D264; Linux RV64 with LP64D and explicit ISA extension sets, D265; conversions that apply the type as written, D266. `refine` gets explicit commands, shared presentation options and build-system dependency files; warnings may also advise without a repair, and command-line policy can enable, suppress or deny them, D251. |
| 0.2.7 | The compiler identifies its exact release, its development commit and a modified checkout. |
| 0.2.8 | A standard library in three roots, `core`, `hosted` and `platform`, found beside the compiler and shipped in its archive, D267 to D279; services are handles, D288; a hosted library over a POSIX layer: files, directories, standard input, the environment, processes, time, randomness, sockets, the rest of the file system and dynamic loading; static Linux programs make their system calls in source, D279 and D280. Several labels share a `match` arm, D405; a value call's failure is ignored under a discard with `else none`, D406; byte-packed C records, `offsetof` and flexible members, D410 to D414; only exports reach the C namespace, D415 to D418; a parameter whose type names no generic formal is an ordinary context, D419 and D420; distinct types compare, update and zero as their bases do, a pointer union compares with an atom and `_ (rest):` binds the atoms no arm named, D427 to D436; module values read compiler facts and size arrays, D437 and D438. The tour, the C guide, the examples and the library reference are rewritten for a reader new to Landin. |

The history before 0.1.0 is kept in a separate archive. The part of it with
lasting value is at the end of the tour, under WHAT WAS TRIED AND DROPPED.

---

## Working style

German conversation, English keywords, identifiers and documents
throughout. Backticks mark code, names and paths, never emphasis. Prefer
deciding over deferring, and
say plainly where a decision is a guess. Push back with reasons rather
than agreeing.
