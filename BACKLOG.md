# Landin — backlog

Everything collected and not yet resolved, as of specification
**0.1.0**.

Sources are marked so a claim can be traced. `[NNN]` is a construct in
`tour.txt`. `Xn`, `Yn`, `Zn`, `Wn` are findings at the end of
prototypes 1 to 4, where each keeps the wording that turned out wrong
beside its resolution. `R§n` and `H§n` are sections of an outside
review and an implementation handoff, both kept in the design archive
rather than here.

What is already resolved is not in this list. The specification's
closing section, WHAT WAS TRIED AND DROPPED, keeps the half of
that history worth carrying — what was tried and dropped, and why —
because that is the part a reader who does not know it will propose
back.

---

## A. Blocking a compiler

These have to exist before a front end can be written without guessing.

**A1. A normative grammar.** The tour decides everything and states
nothing as a grammar. Needed: lexical rules, the operator precedence
table as a table rather than as prose scattered through the OPERATORS
section, and
the statement and expression grammar. `H§P0.1`, `R` bottom line.

**A2. Raw storage as a type.** `[0510]` withdrew the claim that
`slice_from` answered uninitialised storage, and `small(T, N)` is
restricted to a zeroable `T` until this exists — so `small(ptr node, 4)`
does not. The shape wanted: capacity apart from initialised count, one
slot admitted at a time, release only for what was initialised. Let it
come out of container code rather than be guessed. `R§2`, `H§4`, `Z8`

**A3. Value layout, in full.** The variant part above all: tag width,
tag position, payload alignment, and whether the compiler may fold a
tag into spare bits. Deliberately left to a prototype with
measurements, and the prototype has not been written.

**A4. What an invalid packed encoding does.** A three-bit field with
three named values has five patterns hardware can still return. Trap
on load, an unknown case, raw bits, or undefined — the tour does not
say, and a driver cannot be written without knowing. With it: raw
register image versus validated value, and reserved-bit behaviour per
access mode. `R§6`

**A5. The guarantee table.** For every operation: prevented
statically, trapped at run time, permitted only where the lifetime
system has been left behind, or outside the guarantees. The pieces are
decided and scattered across `[0310]`, `[0430]`, `[0470]`, `[0770]`,
`[0910]`, `[1120]`; the page that adds them up is missing, and until it
exists the honest claim is the one at `[1720]`. `R§4`, `H§5`

**A6. How a compiler-supplied conformance fits.** `[0550]` gives
`zeroable`, which the compiler supplies because only it knows a type's
bit patterns. `[1280]` says conformances are declared and a collision
is an error. Those two need reconciling, and the set of
compiler-supplied ones has to be closed and named — otherwise it is
the first crack toward reflection.

**A7. The generic evidence ABI.** What the table physically is: its
layout, entry order, and where size and alignment sit in it `[1310]`.
Needed in the first implementation, not later, because `any` needs it —
see D3. `R§12`

**A8. Diagnostics.** Stable codes, and what an origin or borrow
rejection actually prints. A language whose selling point is that the
compiler tells you when you are being an idiot has to be good at
exactly this. `R§P1.5`

---

## B. Needed before the language is usable, not before a compiler starts

**B1. The concurrency memory model.** Data races, what each atomic
ordering means, happens-before, volatile ordering and tearing,
interrupt visibility, compiler versus hardware barriers, DMA coherence
and cache maintenance. For a language that targets 32 KB parts this is
core semantics, not an advanced library topic — the driver prototype
hands DMA an ordinary slice and reads it back after observing hardware
state, which is exactly the case that needs rules. `R§5`

**B2. The C ABI subset.** `c_int` and friends and the signedness of
`char`, aggregate argument and return lowering, enums, unions,
bitfields, varargs, callbacks, thread-local storage, errno, foreign
ownership, what happens when a failure meets the boundary, and calling
convention as part of function-type identity. Narrow but complete, plus
a binding generator: hand-written declarations will not scale.
`R§9`, `R§10`

**B3. Separate compilation.** A machine-readable interface: public
declarations and layouts, concrete error sets, `escaping` and `from`
contracts, visible conformances, the evidence ABI, package identity,
language version, interface hashes. And a specialisation policy that
is stated rather than heuristic — `shared`, `specialized`, `auto` —
because "the build report says what happened" is not a performance
contract. `R§12`

**B4. Package, build and generator design.** Manifests, lock files,
content hashes, deterministic roots, target triples and sysroots,
freestanding versus hosted profiles, linker scripts, startup objects,
firmware images. And sandboxed generators with declared inputs and
outputs, because refusing compile-time execution makes source
generation load-bearing. `R§13`

**B5. The standard library.** Layering between freestanding and
hosted, the allocator interface in detail, raw syscalls or libc, and
what it deliberately omits.

**B6. Naming authority for packages.** Deliberately postponed. The
search path is project-first, so a collision can always be overridden
locally and no dispute is fatal. `[1480]`

---

## C. Parked, each with the condition that would bring it in

- **Affine values**, which cannot be copied. Would give resource
  ownership, peripheral singletons and typestate from one mechanism —
  and would turn `sink` from a use-after-consume check into ownership,
  which `[0910]` now says plainly it is not. *Trigger:* a peripheral or
  resource prototype that is unpleasant without them. Note that affine
  means *at most* once, so a forgotten flash-unlock token still leaks;
  linear would fix that and cost verbosity. `R§3`, `H§3`
- **Conformances as named values**, passed explicitly. *Trigger:*
  collisions hurting in real libraries.
- **Restricting root capability minting to the entry module**, which
  would make "this subtree cannot touch the world" checkable on the
  hosted side. It cannot close the freestanding side, because a driver
  must be able to write an address literal. *Trigger:* wanting to run
  code you do not trust. `[1680]`
- **Generational observers** for graphs; **uniqueness** as an inferred
  property.
- **soa collections**, deferred at 0.0.5 and kept as a design record.
  *Trigger:* a simulation prototype that needs one field contiguous.
  `[0620]`
- **`unchecked`.** In the design at `[1120]` and not implemented first,
  because what an optimiser may then assume is a decision that should
  wait for a compiler that can be measured. `[1720]`, `H§5`

---

## D. Positions held — do not reopen without new evidence

Each of these has been argued against by an outside reader and kept on
purpose. Reopening is allowed; doing it quietly is not.

**D1. Integer indexing of utf8 stays.** `text[5]` is a linear scan by
codepoint ordinal, kept for ergonomics. Three independent voices
against. `[0610]`

**D2. No weak conformances, and no orphan rule yet.** Weak was tried
and removed: an application quietly changing generic behaviour inside a
library is the wrong shape here. A collision is simply an error, and
the escapes are a `distinct` wrapper or passing the functions
explicitly. The review is right that this composes poorly at ecosystem
scale; the answer waits for an ecosystem. `[1280]`, `R§11`

**D3. No comptime and no macros.** The accepted cost is that generated
tables, SoA and SVD bindings move to generator programs, so the build
story has to be good instead — see B4. Two such cases exist; a third
would be a signal worth taking seriously. `[1540]`

**D4. `escaping` and `from` are written, not inferred.** Inference
means interprocedural analysis and local compilation is worth more —
and for `from` inference was shown to get the allocator wrong, so this
position has two applications and a counterexample behind it.
`[0790]`, `[0900]`

**D5. Own backend.** QBE's IL as the model, assembly text out, arm64
and x86-64 first. Not LLVM, which is a dependency larger than the
language, and not C, which loses the calling convention, the traps and
the debug information the design spends its precision on. `HANDOFF.md`
proposed C or LLVM for the first host target; declined. `[1550]`

**D6. One version of a package name per program.** Duplicated code is
untenable at 32 KB, the types are nominal, and there is one conformance
register. A conflict is a hard error and somebody upgrades. `[1470]`

---

## E. Watch items

Not tasks. Observations that would mean something if they recur.

- **Control flow nobody used.** Loop labels, `break with` and
  `complete` were needed by exactly one of four prototypes. They were
  the right features for a search and a parser is a different shape. If
  a fifth program does not want them either, that is an argument.
  `Y4`, `Z15`
- **Concept width.** The pull to widen a concept until it fits the
  hungriest implementation is strong and gives everyone the sum of
  everyone's needs. `[1260]` says resist it; watch whether real
  libraries can. `W4`
- **Source generation count.** Two cases stand (generated tables,
  SVD bindings). A third is the signal in D3.

---

## F. Process

**F1. The prototypes become executable conformance tests.** They are
the test suite already, and maintaining them as prose has cost two
patch releases. Positive tests for what must be accepted, and negative
tests for what must be rejected — including the examples that were
contradictory before 0.0.17, which are the most valuable of the lot.
`R§P0.8`, `H` definition of success

**F2. `check.py` grows as the rules do.** It found most of what 0.0.15
through 0.1.0 fixed. Every new rule that can be checked cheaply belongs
in it, and every defect it missed once belongs in it as a case.

**F3. The implementation order** is `HANDOFF.md`'s, with one amendment:
the evidence table and `any` belong in the first subset and
*specialisation* does not. `[1310]` says the table is the foundation and
specialising is the optimisation, the table is by far the simpler of
the two — a pair and an indirect call against a heuristic over loop
depth, entry count and code size — and both the parser and the hosted
prototypes need `any` for their diagnostics log and their Io. A first
compiler that specialises before it can dispatch has built the
optional half.
