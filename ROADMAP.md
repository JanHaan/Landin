# Landin compiler roadmap

## Authority and scope

`spec.md` is the normative language specification and `tour.md` explains
the language. This file is the sole
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
semantic change updates `tour.md`, affected prototype-derived tests, this
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
  The nix shell is checked by a second manifest, `.builds/nix.yml`, which is
  not a gate and produces evidence for nothing in the table: it exists only
  because that shell has broken twice on what nothing else reaches, and it
  runs only when a file that shell is made of changed.
- Native macOS arm64 has its own compiler build, platform-tool and debugger
  gate. A Linux container is not evidence for Darwin behavior.
- Ada package specifications and stage fixtures are tested seams so a future
  self-hosting roadmap can replace stages incrementally. This roadmap does not
  implement mixed Ada/Landin stages or freeze their transport.
- The frame pointer is always present. Source and type provenance are carried
  from the first frontend slice so later debug information is not a retrofit.
- The license is settled and is not an implementation gate: `MIT OR
  Apache-2.0`, decided while the author was still the sole one, because that
  is the only point at which relicensing costs one commit. `LICENSE` governs
  the whole tree. Distribution and the contribution process remain with the
  release-readiness successor roadmap.

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
in `tour.md`; the roadmap cannot overrule the specification. A transferred
item names a successor roadmap and cannot satisfy a still-normative in-scope
capability. Historical finding sections and `tour.md`'s WHAT WAS TRIED AND
DROPPED section retain rejected wording.

## The specification documents

Recorded here because it changed the authority order, and because the reason
it was needed is a fact about the project rather than about a document.

The tour was a tutorial that had been declared a specification. It teaches
by example, and a tutorial omits what a reader supplies for themselves, so
three roadmap items in a row found it silent on rules their implementation
could not proceed without: three constructs added at R1.50, eight at R1.60.
Each was written into a section titled "THE GRAMMAR OF THE ENABLED KERNEL",
which says of itself that it covers the constructs the compiler enables
today — so permanent rules were accumulating in a container defined as
temporary, and that section had doubled in two items.

So the documents split. `spec.md` is normative and holds the grammar of the
enabled kernel, which shrinks as the language grows, plus the rules the tour
left unsaid, which do not, plus the register below. `tour.md` explains,
[0010]-[1730]. No construct was renumbered and no id is defined in both.

Seven of the eighteen rules added at R1.50 and R1.60 were decisions rather
than transcriptions, and in the tour's voice a decision is indistinguishable
from a rule that was always there — which is how [1050], "the condition,
which must be bool", was missed twice by a reader who assumed the surrounding
text was settled. `spec.md` ends with a register naming each: what the tour
said before, what was chosen, the alternative a competent reader could have
chosen, and the fixture that pins it. Writing it found three of the seven
unpinned, and those fixtures now exist. A decision leaves the register when
something closes it: a program that cannot be written, a target that cannot
be reached, or a paragraph that turns out to have settled it.

All five documents are Markdown, because the `.txt` form could not tell a
rule from an example. A heading is a definition and a fenced block is an
example, and neither can be mistaken for the other; `AGENTS.md` records the
invariants the form carries.

The rule going forward, so this does not recur: a construct is written only
where two competent implementers reading the specification would disagree. A
forced consequence gets a comment in the code citing what forces it, and a
decision gets a register entry. Half of what was added at R1.50 and R1.60 was
a forced consequence and should have been the former.

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
  specification.
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

R2.20 profiling added exact suite, case and fixture selectors to the same
harness. A selected run identifies itself as `FILTERED`, exercises the real
fixture path, and cannot be mistaken for gate evidence; the no-argument run
remains the complete deterministic suite. Recording and then running may share
one build, but remain two binary modes so a case never writes a golden.

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

R2.20 profiling found that container startup was below one second while clean
builds and whole-corpus execution dominated the development loop. The local
loop therefore keeps one-shot containers, avoids building twice in its
default command, and has checksum-based developer wrappers for minimum
recompilation and focused harness runs. Canonical debug and release commands
still clean on a changed source manifest and still run the whole suite.

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

R0 is complete. R1 followed and is complete too.

## R1 — Executable language kernel

R1 implements the smallest honest frontend-to-native vertical slice. It does
not wait for raw storage, generics or Cortex-M, but it includes the minimum
SysV/ELF ABI needed to run rather than calling verified IR an executable.

### R1.10 — Add the normative kernel grammar

Status: complete
Depends on: R0.30

Add lexical rules, the precedence table, and statement/expression productions
for the enabled kernel to `tour.md`, which was the normative grammar home
when this item ran; the split recorded above moved the grammar to `spec.md`.
A machine-readable inventory may be derived from it but never becomes a
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
grammar twice over: `check.py` compares its reserved words with `spec.md`'s own
`keyword` production and every deferred lexeme with the construct it names,
and the harness lexes all 65 corpus programs and compares each token with
what `check.py`'s independent tokeniser produced.

Invalid escapes were struck from this item's original evidence, with the
reason recorded rather than the clause quietly dropped: at R1.20 the kernel's
only literals were integers and the two booleans `[1770]`, while character,
text and raw literals `[0250]` `[0260]` `[0280]` were refused by `[1830]`.
D161's seventh R4.10 increment now enables the direct `[]u8` text-literal
context and puts its escape-aware scan, shared decoding and L0320 malformed
spelling at this lexical seam. Character and raw literals, and the remaining
text contexts, stay with R4.10.

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
occurrence — a source, a non-empty span, how many secondary labels, how many
notes — is in the row, and `Landin.Diagnostics.Lexical` checks the row
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

Status: complete
Depends on: R1.20, R1.30

Implement hand-written recursive descent and Pratt parsing, explicit recovery
points and a syntax representation that preserves source provenance needed by
semantics and debugging.

`Landin.Syntax` is a flat table of nodes indexed by a dense `Node_Id`, not a
pointer structure, and the reason is the four stages that read it. R1.50 wants
to say which declaration a name resolves to, R1.60 what type an expression
has, R1.70 which IR value a node produced, R4.60 where a node came from —
and none of them may add a field to `Landin.Syntax`, which must not know that
types or values exist. With a dense integer each of them says it in an array
of its own, sized once and indexed in constant time. A tree of tagged records
would have made those side tables maps keyed on access values, and an access
value is not something a deterministic report can be ordered by.

Two invariants come out of building the table bottom up, and both are
postconditions rather than paragraphs: a child's index is lower than its
parent's, so `1 .. Last_Node` is a post-order and a stage that only
synthesises is one forward loop with no recursion and no work list; and a
child's extent lies inside its parent's, because a parent's extent is the
union of its own tokens and its children's. The parser suite walks every slot
of every node of every corpus file, and of every truncation of one, which is
what makes a debug build check them.

A hole is a node. There are four — one per band, so a case over a band still
covers the hole instead of falling out of it — and `Is_Sound` propagates
upward, so R1.60 checks a subtree only when no descendant is a hole and one
missing `then` does not become a cascade of type errors about a hole.

[1820] is a table rather than ten procedures: `Landin.Syntax.Precedence`
transcribes the levels, the operators, the fold and the first sets, and
`check.py`'s `check_precedence_table` compares the transcription with the
grammar it transcribes. That is the whole argument for the shape — ten
procedures are ten paraphrases and there is nothing to compare a paraphrase
to. Seven mutations were tried from both sides (a level renamed, an operator
moved between levels, the wrong level made non-associative, a prefix operator
dropped, the discard dropped from a first set, an operator added to the tour,
the comparison chain made repeatable) and each was reported.

Recovery is a forward scan at declared boundaries, with four rules about a
second failure inside an already-failed construct. A token no kernel rule
spells is consumed as a leaf, or skipped and the requirement retried,
silently, because the scanner already reported it. Reporting is monotone in
token index, which kills same-position cascades. And an `end` that is not
this construct's is left where it is for whatever construct needs it, so one
missing `end` is one report rather than two. A refused construct closes
itself — `end loop` closes a loop — so swallowing its own closer keeps one
refusal from becoming three reports. No cap on diagnostics per file: a cap is
reporting policy, the driver owns policy, and [0950] already refuses the
smaller version of the idea. A nesting limit is different and is set here,
because Storage_Error is not a diagnostic.

`Landin.Diagnostics.Syntactic` owns the twelve new codes and the parser
contains none, the same rule `Landin.Diagnostics.Lexical` already keeps. It
also owns the other half of [1830]: [1760] reserves seventeen words, so
`loop`, `while`, `for`, `match`, `defer`, `undo`, `try`, `fail`, `break` and
`continue` all lex as ordinary identifiers and the scan cannot refuse one.
Without a word table the compiler would say that `loop` is a name needing a
colon, which is true and useless. `check.py`'s `check_refused_constructs`
holds every spelling to a word the tour writes and not one the grammar
reserves, every citation to a paragraph that exists, every named roadmap item
to an item that exists, and the eleven scalar names to the grammar's own
`type` rule.

Two amendments, recorded rather than done quietly. `L0001` is retired: the
catalogue said it retires when the frontend is wired to the driver, and this
item is where `compiler/ada/README.md` said that wiring happens. An empty
file is now accepted, because `program ::= declaration*` derives no
declarations. And `struct-not-enabled`'s summary cited `[0670]`, the struct on
the right of the `=`; the diagnostic cites `[0120]`, which is what [1790]
itself names for "types the program declares", because the parser refuses at
the type position and never reaches the value. The summary was corrected to
match the rule that is actually broken.

Trees are dropped after parsing. Nothing reads one yet, and where they live
for a whole compilation is R1.50's question: a vector of a limited type is not
a thing Ada has, so the answer is a real decision and wiring one in now would
be guessing with a data structure.

Exit evidence: malformed files produce multiple ordered diagnostics without a
crash; recovery resumes at declared boundaries; every kernel production is
covered.

All three hold. Every one of the 42 positive programs in the corpus parses
with no diagnostic and every one of the 23 negative programs is rejected,
which is the same verdict `check.py` reaches from the grammar independently.
Each negative fixture now names the exact ordered sequence of codes its report
carries — `several-independent-errors` carries three, from three separate
mistakes — and `check.py` refuses a negative fixture that names none, so a
rejection whose shape nobody checked is no longer possible. The corpus is
truncated at every byte of every file and each of the ~2,000 prefixes yields a
tree whose invariants hold; that pass found a real defect on its first run, a
code raised without the secondary label its catalogue row requires, which is
now impossible because `Expect` no longer defaults those two parameters.
Deferred with the reason recorded: `Landin.Syntax.Dump` exists and no fixture
records a golden tree, because the corpus agreement above is a stronger claim
than a dump nobody reads, and R1.70 will want the same file for its IR.

A later adversarial review found that truncation is only one shape of damaged
input. The same parser case now makes deterministic byte insertions, deletions
and replacements in every corpus program and parses fixed-seed raw byte
streams. Every mutation must still yield a nonempty tree whose invariants
hold; a discovered failure becomes a minimized fixture rather than a new
random seed.

### R1.50 — Collect declarations and resolve names

Status: complete
Depends on: R1.40

Implement module-local declaration collection, forward references, scopes,
shadowing and deterministic duplicate/unresolved-name diagnostics for the
kernel.

**This item needed normative text the tour did not have, and adding it is the
first thing to read here.** [0130] and [0140] are two sentences — order
inside a module does not matter, an inner scope may shadow an outer name —
and neither says which scopes exist, that two declarations of one name in one
scope is an error, or that a name resolving to nothing is one. A rule about an
inner scope means nothing until the inner ones are named, so three constructs
were added to the kernel section: [1840] names the three scopes the grammar
has and says which of them is ordered, [1850] refuses one name declared twice
in one scope, and [1860] refuses a name that names nothing. Each cites the
sentence it comes from. The duplicate rule was already repository policy
before it was specification — `check.py` has enforced "two declarations of
one name in one module" as a textual invariant since R0, and `README.md`
advertises it — so [1850] wrote down what the checker already believed. A
first attempt at this item attributed all three rules to [0130] and [0140]
directly; an adversarial reading found that neither paragraph says any of
them, which is what sent the work to the tour instead of to a citation.

Where the trees live is answered, which R1.40 deferred. `Landin.Syntax.Forest`
owns one heap-allocated tree per source and frees none, which is the decision
`Landin.Source` already recorded for a snapshot's bytes and for the same
reason: a compiler that frees a tree while a diagnostic still points into it
has traded a leak for a dangling span. A `Tree` is limited with unknown
discriminants, so an initialised allocator whose value is the parse is the one
form Ada gives for building one somewhere that outlives the call.

The compilation owns it, and three more tables with it: the interned names,
the declaration sites, and the resolution. Two facts about the seam force
that. `Run` takes `Item` as an `in` parameter of a limited interface, so a
stage cannot keep anything in itself; and `Stage_Reference` is a library-level
access type, so a stage object cannot be a local of one compilation either.
The line that keeps `Landin.Stages` a seam is exact and is now written in its
header: it may depend on a representation and may never depend on a stage.
Ada enforces that for the specification only — a parent's spec may not `with`
its own child, and a parent's *body* may — so the rule and not the compiler
is what stops `landin-stages.adb` from building a default pipeline.

A resolution is one array of `Declaration_Id` per compilation, one run per
source, exactly as `Landin.Syntax` lays every node's children end to end.
That is the flat tree's payoff arriving: a reference costs one addition and
one index, with no map and no order that depends on where the host put an
object. Lookup is hashed and never iterated, and the report order is the order
the sources were added and then the order the declarations were written —
which is what makes it source-stable rather than identity-stable.

Two passes, because [1840] gives the kernel one unordered scope and two
ordered kinds. Every module declaration of every file is collected before any
body is walked, so a name may be used above the line that introduces it and
across a file boundary; a local is declared when the walk reaches it, so a
binding's own value is read before its name exists [0110]. One mechanism, two
readings: what is in the table when a lookup runs is what that lookup can see,
with no visibility flag anywhere.

Two codes and not more. `L0200` a name declared twice in one scope, `L0201` a
name declared in no visible scope. `L0200` is the first diagnostic in the
compiler whose second label can point into another file, which is why
`Landin.Diagnostics.Resolution` takes a `Landin.Provenance.Origin` rather than
a span: until now a scan and a parse never crossed a file, so both places were
always in one.

`check.py` gained the classification a name-error fixture needs. A program
refused for a reason of names is syntactically legal, so the grammar must
derive it — the opposite of what `negative/` used to mean. The stage is read
out of `Landin.Diagnostics.Lexical` and `Landin.Diagnostics.Syntactic`, the two
packages that turn a fault into a code, and never out of the number: the
catalogue's header forbids reading a stage off a code, and `L0010` is the
standing proof, raised by the scanner and by the parser both. A first attempt
used the band arithmetic and was rejected for exactly that reason.

Deferred with the reason recorded. [0080]'s "assigned before use" and [0930]'s
"every named return assigned before the function returns" are R1.60's, not
this item's: in `mut n: u32` then `x = n` the name resolves and what is missing
is an assignment on some path, which is a merge over the arms and a reading of
`return` as an exit. `public` [0090] is recorded on every declaration and
consulted by nobody, because with one module and no importer there is nothing
for it to mean until R3.10.

Exit evidence: positive and negative fixtures prove order-independent module
names and source-stable diagnostics.

Both hold. Twelve fixtures were added, four positive and eight negative, and
the corpus is now 46 positives and 31 negatives. A name is resolved across two
files in either command-line order with the same result, a module name is used
above the line that introduces it, a local shadows a parameter, and one name is
declared in both arms of an `if` — all accepted. A duplicate in a module, in a
body, between two parameters and between a parameter and the named return; a
name declared nowhere, one from another arm, one after the branch closes, and
one used above its own declaration — all refused, each with the exact ordered
code sequence its fixture names, checked by running `Landin.Driver.Execute` the
way a user runs it rather than by assembling the stages in a test.

### R1.60 — Check the executable kernel

Status: complete
Depends on: R1.50

Implement the minimum static types, constants, functions, scalar operations,
branches and returns needed by the first native program. Reject unsupported
constructs explicitly.

**This item needed eight new normative constructs, and that is the largest
thing in it.** R1.50 found the tour silent on scopes; R1.60 found it silent on
almost the whole of typing. [0310] says there is no implicit conversion and
[0290], [0330], [0340] and [0350] list the operators, but nothing said that
two operands of a binary operator must share a type, what the result type is,
that a comparison yields a bool, or that `and` takes one. Nothing forbade
assigning an immutable binding: [0040] says "immutable by default" and states
a property, exactly as [0130] stated one before [1850] had to state the
refusal. Nothing said what a call must match, what may be discarded, or —
sharpest of all — what "the type of its context" in [0190] actually means,
which a checker cannot ask for until the positions are listed.

So [1870] says what each of the eleven types holds, [1880] lists every
position that gives a literal a type, [1890] says what each operator takes
and gives, [1900] says what may be written, [1910] says a name must be
assigned by every path that reaches a read, [1920] says what a call means,
[1930] what may be discarded, and [1940] that a module value is one the
compiler knows when it reads it. Each cites the sentence it derives from.

Two things the tour already said were missed on the first reading and found by
an adversarial one, and both are recorded here because they are the kind of
mistake this process exists to catch. [1050] states "the condition, which must
be bool" — it sits indented inside a code example, so a scan anchored at
column 0 does not see it, and the whole grammar section is written that way.
And [1460] states "Values at module level must be known at compile time.
Nothing runs before the entry point", which is [1940]'s source and settles
`k := f()` without any new text. Two drafted rules were struck as a result.

Two rules were narrowed rather than adopted as drafted. [1880] first folded
every all-literal operator before the range check; that would make
`u8 = 200 + 100` a static error, and [0300] says overflow *traps*. So only a
unary minus folds, which is the one case that is forced — without it
`i8 = -128` is unwritable, because `integer` [1770] spells no sign and `-` is
an operator [1820]. And [1940] first promised a report naming every
declaration a cycle runs through; a diagnostic carries an exact number of
labels by contract, so it names the one the chain came back to.

Nothing asks the host how wide anything is. A width is a function of a type
*and* a `Landin.Targets.Target_Facts`, formed only in `Landin.Types.Width`, so
`usize` is as wide as a description says and a 32-bit target stays 32-bit on a
64-bit host. A literal's value lives in `Landin.Types.Magnitude`, whose bound
is written out as `2 ** 64 - 1`: that is a fact about `u64`, where
`Long_Long_Integer` would have been a fact about the machine running the
compiler — the same move `Landin.Targets.Byte_Count` already made and states
its reason for. `Fits` builds `2 ** Usable - 1` one bit at a time, because
forming it directly is one past `Magnitude'Last` in exactly the `u64` case it
exists to answer. Sign is separate from magnitude because the grammar
separates them, so no signed 65-bit type is ever needed.

R1.50's entry guessed that R1.60 would be "the pass that gets to be a forward
loop". That is true of a pass that only synthesises, and typing is not one:
[0190] makes a literal's type come from its context, so information flows from
a parent into a subtree a forward loop has already passed. The honest shape is
three passes and a fourth walk. Pass one settles every declaration that writes
its type down, over every tree, before any body is read, because [1840]'s
module scope is a set and crosses files. Pass two infers [1790]'s `:=` form on
demand with `Underway` marking what is already being asked, which is the whole
of the cycle check. Pass three reads the bodies. Inside an expression the walk
is two mutually recursive halves — a node is either asked what type it has or
required to have one — because that second half is the only way a literal
ever gets a type at all. What the flat table still buys is the answer: one
array indexed by `Node_Id`, no map anywhere.

[1910] is its own walk, and R1.50 deferred it here by name. One Boolean per
declaration, copied at a branch and merged after it, with the merge being
`and` over every path that does not exit. No condition is believed, so
`if true then r = 1 end if` leaves `r` unassigned and a branch with no `else`
contributes a path that changes nothing. A `return when` is a return whose
flow below is reachable, which is why [1810] says only exits carry `when`.

Six codes, `L0300`-`L0305`. `L0304` is the checker's half of [1830] and is
separate from the parser's `L0010` for a reason of information rather than of
stage: `u8(x)` is a perfectly good `call` production, and what makes it
[0700]'s conversion is what `u8` turned out to name. Reusing `L0010` would
also have made its fixture unwritable, because `check_grammar_corpus` requires
a frontend-code fixture *not* to derive and this one does — which an
adversarial reading caught before it was written.

One defect, found by R1.70's design and fixed under this item's number
because it is this item's rule that was incomplete. `over: u8 = 200 + 100`
was accepted. Inside a body that is right — [0300] says overflow traps, and
narrowing [1880]'s folding rule to leave it to the trap was correct. At module
level it is wrong, and the reason is the interaction of two rules that are
each correct alone: [1460] says nothing runs before the entry point, so a
module value has no moment in which to trap and no value to stand for it. So
[1940] gained the rule, and a module value's operators are folded and refused
when no type holds the answer. Folding needs a signed value where a literal's
`Magnitude` is unsigned — `x: i32 = 1 - 2` is negative — so `Landin.Types`
gained `Folded`, bounded by `u64`'s span and its negation for `Magnitude`'s
reason. The bitwise and shift levels are deliberately not folded: their answer
depends on a width, and a width belongs to a target. Division by zero is not
folded either, for the same reason a module value cannot trap — and at
R1.70 that turned out to be a hole rather than a decision, because
declining was silent. [1950] closes it.

Exit evidence: each enabled construct has acceptance and rejection cases; no
host integer width leaks into target semantics.

Both hold. Twenty-two fixtures were added, eight positive and thirteen
negative, and the corpus is now 54 positives and 44 negatives; every new
construct [1870]-[1940] is named by both an acceptance and a rejection case,
which `check.py` enforces by refusing a grammar construct no fixture names.
Two coverage gaps an adversarial reading found are closed: no fixture anywhere
assigned a mutable *binding* before now, and `function-parameters` was being
counted as the acceptance case for a call's arity while containing no call.
`Landin.Types` spells the eleven a second time because it owns the mapping to
a machine width, so `check.py` holds it to `spec.md`'s own `type` rule and to
the parser's table; three mutations were tried from both sides and each was
reported. 78 cases, 1671 checks.

### R1.70 — Implement target-neutral IR and verification

Status: complete
Depends on: R1.60, R0.60

Introduce the smallest evolvable target-neutral IR, preserving source
locations, lexical scopes, declared types and stable value identity. Verify
control flow, value definitions, types and call shapes before lowering.

`Landin.IR` is landed: basic blocks with an explicit terminator, and the
shape is forced rather than chosen. A structured IR would be `Landin.Syntax`
plus `Landin.Checking` under new names and R1.80 would still have to
linearise it, and "exactly one terminator, in last position" is a property a
tree cannot violate and therefore cannot test — which would make this item's
own exit evidence vacuous. Blocks are forced by the kernel and not deferred
to loops: [0410] makes `and` and `or` short-circuit, observably, so the
logical words are control flow and `Opcode` has no `Logical_And` and no
`Logical_Or`. No phi and no block parameter, and that is a fact about the
kernel: [1840] says a name declared in one arm is not visible in another and
[1080]'s branch-as-an-expression is not enabled, so nothing crosses a merge.
Operands are block-local, which makes the value-definition rule one
comparison instead of a dominance relation and is the same invariant
`Landin.Syntax` states as `Slot'Result < Id`. A value's identity is the
position of the instruction that defines it, so "exactly one definition" is
the shape of the table rather than a rule to verify. The builder's
preconditions are structural only — a wrong-arity call and a mid-block
terminator are buildable on purpose, because a precondition there would make
malformed IR unconstructible and so untestable.

The lowering has landed for routines. `Landin.Stages.Lowering` is a fourth
frontend stage, wired into `refine`, so every positive fixture is lowered by
the fixture suite and `Landin.Tests.Lowering_Suite` reads the Unit back for
five of them. Two passes, and the first is forced rather than tidy: [1740]
makes a module a set, so `f` may call `g` written below it and `Emit_Call`
needs `g`'s item to exist by then — every item is created over every tree
before any is filled, and then each is filled alone, because
`Landin.IR.Open_Run` refuses an interleaved fill.

R1.80's first backend walk exposed one more consequence of the block-local
operand rule above. [0410] evaluates call arguments and binary operands left
to right, but a later `and` or `or` changes blocks. The lowering retained the
earlier value directly, so both `choose(a, b and c)` and
`a == (b and c)` reached the verifier with an operand defined in the entry
block and consumed in the join block; each legal program became a compiler
defect. The disposition stays inside R1.70's unoptimised IR: every call
argument that has another after it, and every binary left operand, is stored
in an anonymous typed temporary slot before the later expression is lowered
and loaded again where the call or operation is emitted. The focused lowering
cases assert both the block-local reload and the identity of the saved value;
each fails against the corresponding direct-value lowering rather than merely
checking that the verifier happened not to raise.

The stage refuses to run on a refused program on its own first line rather
than relying on the pipeline stopping before it. That is what makes this
item's no-diagnostic-code argument a fact instead of an accident of the
driver's ordering: malformed IR cannot come from a source program only while
nothing lowers one, and nothing in `Landin.IR` enforced that.
`positive/...`-style evidence for it is a case, not a fixture: a program with
a type error produces a Unit with zero items.

A third defect of the same family, found by an adversarial reading of the
verifier's design and fixed here. `Open_Run` guards four vectors and there
are five: every instruction but a call records its operands in the same call
that creates them, so those runs cannot interleave, but a call's arguments
arrive afterwards and `Enter` asks only that *this* item has no open block.
So two items could be open at once, and a call was handed one value and read
back the other item's — in debug and in release, with every precondition
satisfied and nothing to notice. `Add_Argument` opens its own run now, and
`Emit_Call` no longer takes a base at creation, which is the same sentence
as the first two fixes. The case that pins it fails against the old body.

A datum's value block has landed with it. A `Binding` gets its item and its
block: the value, or D10's zero where there is none, and a `Leave` carrying
it. Nothing about it is special-cased — it is `Lower_Expression` over the
same machinery a body uses, which is what keeps the logical case free.

The verifier has landed with it. `Landin.IR.Verifier` is a child of the IR,
because two of its rules read the private part: an item's four runs and a
call's operand run have to partition their vectors, and no public function
can see a run. Those two run first, since a wrong base makes `Nth_Value`
raise before any later rule could speak. `Landin.Stages.Lowering` verifies
every Unit it builds, in every build mode, so all 58 positive fixtures are
verified by the fixture suite rather than by a probe.

What it does not check is as deliberate as what it does, and the package
header says which is which. Nothing whose violation the table's shape
already forbids — "every value has exactly one definition" is what a
`Value_Id` *is*, and a test for it could not fail. Nothing that belongs to
someone else — whether a `Number` fits its type needs a width and a width
is `Landin.Targets`'; whether a `Scope_Id` names a real scope is R1.50's and
asking again would be the second authority the IR's header refuses.

One rule was written and then dropped, which is worth recording because it
was this item's own reasoning that produced it. `Datum_Has_Control_Flow`
followed from the folding plan above; when that plan was reversed the rule
became a verifier that refuses what the lowering correctly builds, and it
would have raised `Compiler_Defect` on `k: bool = true and false`. That is
the shape of mistake this design is most exposed to: because a failure is a
defect and not a diagnostic, a *wrong* rule is a crash on a legal program
rather than a red test.

`Landin.Tests.Verifier_Suite` builds fifteen malformed shapes the builder
accepts and asserts the exact fault for each. All fifteen were run against a
verifier stubbed to find nothing and all fifteen failed there.

The textual dump has landed with it, and R1.70 is complete.
`Landin.IR.Dump` renders a Unit as one line per item, slot, block and
instruction; `compiler/tests/lowering.ir` is every positive fixture
rendered, written by `./scripts/test.sh --record` and compared by the
suite. 811 lines, longest line 78 columns.

Three things about it are decisions rather than transcriptions, and each is
argued in `landin-ir-dump.ads` rather than assumed.

- **No origin is printed.** Every instruction carries one, and a byte offset
  in a golden moves when a comment above it is edited, so every
  documentation change would rewrite the artefact and the diff would stop
  meaning anything. Measured: inserting one comment line changes 27 of the
  28 lines of the *syntax* dump — which is right, because spans are what a
  tree is — and none of this one. What R4.60 needs pinned is that an
  instruction is attributed to the right token, and that is a case about one
  program rather than a column in every line of a corpus-wide file.
- **"Round trip" is read as regenerate and compare.** It cannot mean parse
  back: `Landin.IR`'s header forecloses a reader, because one would be both
  a second constructor of an IR and the first half of the serialised stage
  protocol R0.60 refused to freeze. Whether that is what this item's exit
  sentence meant is R1.90's to settle when it closes the corpus.
- **Recording is a mode of the test program**, `--record`, which writes the
  file and runs no case. `check.py` generates the other two artefacts
  because it owns their sources; it owns nothing here, since producing this
  one means running four compiler stages. The consequence is written into
  `compiler/tests/README.md`: this is the one recorded artefact `check.py`
  will not tell you is stale.

Left open rather than answered: whether a Unit is target-independent.
Nothing target-shaped is in the table, but *acceptance* is
target-dependent, and no document says whether two targets could produce
two Units for one accepted program. The artefact pins `linux-x86-64` in its
banner rather than assuming the invariant; R2.10 is where it becomes real.

Exit evidence: malformed-IR tests are rejected; round-trip textual dumps are
canonical test artifacts but not stable public interfaces.

Two defects in `landin-ir.adb`, found by designing the verifier and fixed
here. Both corrupted a Unit silently in a release build, and neither could
have been found by running the compiler, because nothing calls `Landin.IR`:
a representation with no caller has no test, and this item shipped one.

- **A run's base was taken when an item was created.** [1740] makes a module
  a set, so `f` may call `g` written below it, and `Emit_Call`'s
  `Holds (Into, Callee)` therefore forces a lowering to create every item
  before it fills any. Every item then got the same base, and the second
  item's slots read back as the first's — caught by `Add_Slot`'s own
  postcondition in debug and silent in release. A run's base is now taken on
  its first append.
- **A block's first value was taken when the block was created.** This
  package's own header says blocks are created out of fill order — "an
  `if`'s else-entry is created before the then-arm's inner blocks and filled
  after them" — so every block but the first reported the instructions of
  whichever was filled first. It is taken in `Enter` now, whose precondition
  already says the block is empty.

`Open_Run` is the third thing, and it is a rule rather than a fix: a `Run` is
a base and a count, so an item's entities have to be contiguous, and going
back to an item after starting another silently interleaves two runs. No
precondition said so, so the body says it, in every mode — the rule
`Landin.Targets` learnt when a release build accepted an alignment of twelve
that only a precondition had refused.

`Landin.Tests.IR_Suite` is new and is what would have caught all three. Each
of its three cases was run against the unfixed body and each failed there,
which is the only evidence that a regression test regresses.

What a module value can be, surveyed against the compiler rather than
guessed, because the lowering has to lower every one of them. Eight forms
were run and all eight are accepted today. Six lower without argument: a
comparison, `not`, a bitwise operator and a shift all have opcodes, and
`x: u8 = 200 + 100 - 100` folds at `Folded` width and is a legal program
whose intermediate never exists at run time — a verifier that constant
folded a datum in the instruction's own type would refuse it, which is a
trap worth naming here.

Two do not, and each needed something.

- **`k: bool = true and false` has no opcode to lower to.** [0410] makes the
  logical words short-circuit, so `Landin.IR` deliberately has no
  `Logical_And` and no `Logical_Or`. This item first recorded that the
  lowering would fold the logical level inside a datum. That was wrong, and
  the correction is worth keeping rather than quietly replacing. Folding the
  logical level needs the comparison level under it, and
  `k: bool = (1 << 2) < 8 and true` is accepted — measured, not supposed —
  so it needs the bitwise and shift levels too, and those need a width. That
  is a second constant folder beside the checker's, over the whole of
  [1820], and two authorities on one question is what this compiler refuses
  everywhere else: it is the argument `Landin.IR`'s header makes against
  holding a scope tree, and the one D4 makes against two spellings of one
  type. So a datum gets the blocks a body would, from the same
  `Lower_Short_Circuit`, and no new evaluator exists to disagree with the
  checker. What it costs is that R1.80 reads a datum's block instead of one
  folded constant — which it had to do regardless, because [1940]'s fold
  stops at the arithmetic level and the header already said the bitwise and
  shift levels arrive as instructions.
- **`later: i32` has no value to describe.** Reading one was accepted too —
  `r = later` compiles, and [1910] excludes module bindings from its walk by
  name, so nothing catches it. Settled as D10: it holds zero, false for a
  bool. The alternatives are recorded there.

Neither was reachable from reading the source; both came out of running the
eight forms through `refine`.

Settled while designing it, and recorded because it changes what the verifier
is: malformed IR cannot be caused by a source program, since the frontend
refuses every ill-formed program before lowering runs. So a verifier failure
is a `Landin.Compiler_Defect` and this item assigns no diagnostic code at
all; `L0400`-`L0499` stays unassigned. `landin.ads` states the rule the
argument rests on: "A source program must never be able to raise it: an
ill-formed program is data, not an exception."

Two language questions surfaced here and are now answered, in [1950] and in
D8 and D9. Both were the user's to decide and neither was guessed; what the
decision rested on was measured rather than recalled, on this repository's
own first three targets.

| | shift amount, over-wide or negative | a zero divisor |
| --- | --- | --- |
| x86-64 | masks the count to 5 bits, 6 at 64-bit | `IDIV` raises a hardware fault |
| AArch64 | masks the same way | `SDIV` answers 0, silently |
| Cortex-M0 | takes the low 8 bits and saturates: >= 32 gives 0 | no divide instruction exists at all |

The first two rows disagree with [0320], which fills with zeros beyond the
width for any amount, so `refine` already owes a guard on both of R1.80's and
R5.30's targets for an ordinary over-wide shift — and a negative amount
therefore costs no code generation that was not already owed. The division
rows disagree with each other, which is what rules out leaving a zero divisor
to the machine: one program would mean two things.

- **[0320] did not say what a shift by a negative amount does.** [1950] now
  does, and D9 records the three alternatives with the measurement that
  argues against each. D6 is what makes a negative amount writable, so the
  check exists only where the left operand is signed.
- **[0290] did not say what division by zero does.** [1950] now does, and D8
  records it. `%` goes with `/`, because the divisor is the same operand.

Both take [0310]'s shape rather than a new one: refused where the compiler
knows the operand, trapped where it does not, and refused at module level
always, since [1460] leaves no moment there in which to trap. Emitting the
trap is R1.80's; refusing the known operand is done, as `L0306`.

Closed with it, and found by writing the rule rather than by the rule
itself: `d: u32 = 7 / 0` was accepted. [1940] already said a module value is
folded and a fold no type holds is refused, and overflow was caught by it,
but a zero divisor set the fold to *not known* and the refusal only fired on
known-and-does-not-fit. A quotient that does not exist is a stronger case
than a sum that does not fit, and it was the one getting through.

### R1.80 — Implement the minimal Linux x86-64 native path

Status: complete
Depends on: R1.70, R0.50, R0.70

Implement the scalar data layout, frame-pointer rule, minimum SysV calling
convention, hosted `public main: () -> (code: i32)` entry, ELF-compatible
assembly and platform assemble/link/run path needed for a constant-return
program. Keep aggregate, error-register and evidence calls in R2. [1970]
requires exactly that public, no-argument entry and passes its named `i32`
return to the host as the program status.

[1950] hands this item three obligations, and what was measured to settle
them is recorded under R1.70 rather than repeated here. A zero divisor and a
negative shift amount the compiler does not know must trap, and only this
item can emit that trap: `L0306` refuses the ones it knows and says nothing
about the rest. A shift whose amount reaches or passes the width must yield
zero [0320], and x86-64 masks the count instead — five bits at 32-bit, six
at 64 — so `1u32 << 40` needs a guard the hardware does not give, on every
shift whose amount the compiler cannot bound. And the lowest value of a
signed type over -1 traps as the overflow [0300] already makes it, which
`IDIV` gives here for nothing and R5.30 will have to construct.

[1960] now fixes what a trap does. It is synchronous and non-returning at the
operation's point in evaluation order, and no later Landin action occurs. The
operating system's signal, status or other encoding is not stable program
behaviour. This backend deliberately emits `ud2` for a trap rather than
inheriting the incidental fault or value of the arithmetic instruction; D11
records the alternatives before lowering hardens around one.

The frame is laid out before anything is emitted against it, and two of its
rules are this item's rather than a paragraph's. Every *value* gets a cell and
not only every slot: `Landin.IR` keeps values block-local so that a backend
never computes dominance, and the cheapest correct way to honour that is to
store each defined value and reload it where it is used. That is unoptimised
by construction — every operand is a memory reference — and it is the
"deterministic baseline code generation before competitive optimization" this
roadmap already asked for, with promoting a cell to a register left to R4.50
where a register allocator is actually being written. A cell is then placed at
the first distance below the frame pointer that is at least its own size and a
multiple of its alignment, so the address it names is aligned rather than
merely the count that reaches it.

A bool is one byte, and that is a boundary worth naming rather than leaving in
a body. [0150] says a one-bit field outside a packed struct "occupies the next
machine width", and the next machine width above one bit is a byte, so this is
a transcription and not a twelfth decision. But `Landin.Types` says in its own
header that how a bool is stored is R2.10's, and a frame cannot be laid out
without an answer. R2.10 owns a bool inside an aggregate and may say more; a
frame cell is not an aggregate, and what it settles must agree with this.

What is emitted so far is the straight-line kernel — a literal, a truth, a
slot read and written, ordinary and wrapping add, subtract and multiply,
division, remainder, the unary and bitwise operators, both shifts, all six
comparisons, a call, a jump, a branch, a return and a module value —
against a prologue that sets up [1550]'s frame pointer and stores [1650]'s
argument registers into their parameter slots. Ordinary add and subtract use
the result type's width, test signed overflow or unsigned carry/borrow before
anything can change the flags,
and reach an explicit `ud2` on the failing edge; only the successful edge
stores a result. Multiply uses the one-operand `imul` or `mul`, whose implicit
high half lets overflow mean a non-sign-extension for signed values or a
nonzero high half for unsigned ones, and tests overflow or carry at that same
point. Their wrapping forms ignore those flags and immediately retain the
low-width result. Division and remainder guard an unknown zero divisor and
reach `ud2` before `div` or `idiv`; signed division likewise recognizes its
minimum over minus one and traps deliberately. Signed remainder recognizes the
same pair as its specified zero instead, because executing `idiv` would
incidentally fault.

Unary minus is checked on the same footing, and that is [1890]'s doing rather
than a new rule: it gives its own integer type back, so the lowest signed value
has no negation the type holds and no unsigned value but zero has one at all.
`neg` reports the first as overflow and the second as carry, so one instruction
answers both without a comparison. [0330]'s `~`, `&`, `^` and `|` cannot leave
their own type, so they carry no edge and no signed variant. [0340]'s `not` is
the one that is not a width-wide operation: [1870] fixes a bool at zero or one,
so it flips the low bit and a `notb` would give 254 for `not false`.

A comparison loads its left operand and uses GAS's
`cmp right, left` order at the operands'
width, then materializes [1890]'s one-byte bool with equality or the appropriate
signed or unsigned ordering condition. `bool` ordering uses its specified zero
and one as unsigned values.

A shift is where this backend emits most of what the hardware does not give,
and both of the obligations above are now discharged there. The amount is
tested against the type's own width, because x86-64 masks the count — five
bits at 32-bit, six at 64 — while [0320] fills with zeros beyond it for any
amount, so `1u32 << 40` would otherwise shift by 8. A signed amount is tested
for being negative first, because D6 gives the amount the left operand's type
and [1950] leaves the ones `L0306` could not read to the trap; an unsigned
amount cannot be negative and carries no such test. `<<` is `shl`, an unsigned
`>>` is `shr` and a signed one is `sar`, and the count reaches `%cl` only
after both tests have passed.

That left a sentence in [0320] to settle rather than transcribe, since "fill
with zeros beyond the width, for any amount" and "Signed >> keeps the sign"
disagree exactly where a signed `>>` reaches its width. D13 records the
decision and its alternative: the zeros sentence governs, so `-1i32 >> 31` is
-1 while `-1i32 >> 32` is 0, and `runtime/shifts-fill-with-zeros-beyond-the-width`
is what proves it on the hardware.

A call is where [1650]'s ABI is finally read from the other side. [1920] gives
it every parameter once and in order, so its operands are already the argument
list and the six registers are filled from them in that order, each at its own
parameter's width rather than at one the call site picks. The result comes
back in the accumulator and becomes a frame cell like any other value, and a
callee returning none leaves nothing there to take — which is [1930]'s rule
seen from the backend, since a discard is about who reads a result and not
about what ran. Nothing is pushed for a call: the frame is already a multiple
of the target's stack alignment, so `%rsp` meets the ABI where the call is
made. A seventh argument is not reachable yet and says so rather than picking
a register, and R2 still owns aggregate, error-register and evidence calls.

Any other opcode raises a compiler defect rather
A module value is the one item that is data rather than code, and folding it
is this item's work rather than the checker's. [1460] says nothing runs before
the entry point, so a datum's block describes a value and is never executed;
`Landin.IR`'s header already recorded why the fold could not finish earlier,
which is that the checker declines the bitwise and shift levels because
[0320]'s zero-fill needs a width and a width needs a target. So the backend
folds the block it was handed, at each value's own width, and writes an
initialized object into `.data` at its own alignment. A binding with no value
folds to zero, which is D10 and not a new rule, and a routine reaches one by
name RIP-relative rather than through a frame cell.

Two things about that fold were wrong before the runtime fixture compared it
with the hardware, and both are worth keeping written down. A negative
arithmetic shift took its complement at the fold's own 64 bits rather than at
the type's, so `-1i8 >> 1` folded to 127. And a checked operator narrowed at
every step, which is not what a checked operator means here: [1460] gives a
module value no moment in which to trap, so the whole expression is worked out
and [1940]'s refusal falls on the answer, which is what `L0300` already says
when it reports what a fold "works out to". Narrowing each step made
`u16 = (40000 + 30000) / 2` emit 2232, which is neither the 35000 the checker
computes nor anything a program could have meant. [0300]'s wrapping forms are
the ones that are about a width and say so by name, so those do narrow at each
step, and the bitwise set and the shifts likewise.

With that the backend spells every opcode `Landin.IR` has, so the case that
dispatches them is exhaustive rather than ending in a defect: a new opcode now
fails to compile instead of failing at run time, which is the earlier the two
can be found.

One measurement belongs to a later item rather than this one. Folding a datum
that names another is memoized here, because `b = a + a` reaches `a` twice and
a chain of those would otherwise double with every link. The checker's own
fold has that shape and is not memoized: twenty-one such declarations take
9.5 seconds and twenty-five take two and a half minutes, all of it in the
frontend, measured on the development host. Nothing in the kernel corpus is
written that way and no fixture is slow, so this is recorded rather than
fixed. Whichever item next opens `Landin.Checking`'s module-value fold should
memoize it there for the same reason, and the fix is the same few lines.

The path from `refine` to a running process is now reachable, and a
constant-return `main` compiled, linked and executed inside the pinned Linux
image exits with the status [1970] promises. `--emit=asm` writes the
assembly and `--emit=exe` assembles and links it, with `-o` naming either.

Two of the first plan's assumptions were wrong, and measuring is what found
both. `cc` does not exist on the Linux gate at all: the container recipe and
`.build.yml` install `binutils` and `libc6-dev` and deliberately not
`build-essential`, so a link driven by `cc` would have failed CI rather than
this host. And the pinned GNAT is already a complete toolchain — `as`, `ld`
and `gcc` all resolve inside its own `bin/`, ahead of `/usr/bin` — so the
finishing step needs no new dependency and no second C toolchain. It is the
one pinned toolchain this repository already committed to.

A driver is named, never a linker. The crt startup objects, `-lc` and the
dynamic loader's path live in the compiler driver and differ per
distribution; invoking `ld` directly would move every one of them into this
compiler, where no paragraph could say what they are.

Which driver is a decision, and it is the GNU convention rather than a new
one. Cross tools carry the `--target` argument as a prefix — GCC's own
internals documentation states it, and the pinned GNAT installs itself as
`x86_64-pc-linux-gnu-gcc` on Linux and `aarch64-apple-darwin24.6.0-gcc` on
the macOS host, both measured. So `Landin.Targets.Capabilities` carries a
triplet and `refine` runs `<triplet>-gcc`. That package and not
`Target_Facts`, because its header already claims exactly this ground —
"the external tools needed to finish a program for that machine" — while
`Target_Facts` says a description holds "nothing about what a program may
name". A target with no backend has no triplet, which is the same fact its
backend column already states.

The triplet is not canonicalised and is not a target name. One machine is
`x86_64-pc-linux-gnu` to the pinned GNAT, `x86_64-linux-gnu` to Debian's
cross packages and `x86_64-unknown-linux-gnu` to LLVM and to the Homebrew
tap that cross-compiles from macOS. Autoconf's own manual says not to
duplicate `config.sub`'s canonicalisation, so one spelling is carried
verbatim per target and `--toolchain=NAME` settles every other. That
override is not hypothetical: it is exactly what a macOS host with the
`messense/macos-cross-toolchains` tap needs, since that tap spells the
triplet the third way.

There is deliberately no fall back to a bare `gcc`. A host whose
triplet-prefixed driver is absent cannot finish this target, and reaching
for whatever `gcc` names would, on the macOS development host, hand ELF-only
assembly to a toolchain that emits Mach-O. Making that a stated refusal
costs one diagnostic; making it a fallback would cost a host-detection rule
this compiler has nowhere to put. Whether the driver exists is not asked
twice either: `Landin.Platform`'s interface already separates a tool that
could not be started from one that ran and failed, and the first is exactly
what a host without the toolchain falls on.

Zig was read rather than assumed, since `tour.md`'s third line is "Zig, but
sweeter". Zig builds for every target independently of the host and buys
that by vendoring the finishing step — LLD as a multi-format cross-linker
and libc *sources* for 97+ targets. [1550] has already declined that
mechanism, and LLVM by name. But the property separates from the mechanism:
source to assembly text is host-independent here *already*, by the rule that
nothing outside `Landin.Targets` may ask the host anything, so `--emit=asm`
for `linux-x86-64` produces identical bytes on macOS and on Linux. Only the
finishing step ever needed a toolchain, and that is the half the triplet
convention answers.

GAS is the only assembler and that is not a flag: the emitted text is
already GAS-specific in AT&T operand order, `@function` and
`.note.GNU-stack`, so a second assembler would be a second emission dialect
and therefore a backend variant. mold is a `--linker=NAME` pass-through
appending `-fuse-ld=NAME`, which is all it costs because all three ways mold
documents go through a compiler driver for the reason above. What this
repository owns is the command line, and a case asserts it exactly; no
environment here runs mold, so that flag is argv-tested and never executed,
and this sentence is where that gap is recorded rather than implied.

Four codes were assigned, and `L0500`-`L0599` is a new band for the backend
and its toolchain. `L0005` sits in the driver band instead, beside `L0003`,
because an output that cannot be written is the same rule as a source that
cannot be read from the other side.

Two ways of reaching a target this repository has no backend for were
proposed here and both are declined, recorded because each will be proposed
again. Vendoring Apple's `.tbd` stubs, which is how Zig cross-compiles to
macOS without an SDK: declined because it is the vendoring [1550] already
refused, and because Landin does not need it — macOS arm64's answer is a
macOS runner, not a Mach-O cross-linker, and Xcode on a Mac is exactly what
Apple's agreement contemplates. And building cross toolchains and retaining
the artefacts: declined for three separate reasons, one per target. Cortex-M
needs no build at all, since `arm-none-eabi-gcc` is packaged on both
Homebrew and Debian. A Linux cross toolchain for a macOS host is legally
clean and duplicates work the `messense/macos-cross-toolchains` tap already
does, which is also the role `scripts/env.sh` declines in one sentence —
"the pin is a version, not a distributor". And retaining a macOS artefact
where the Linux gate could fetch it does not avoid the licence question but
relocates it: osxcross states it cannot ship the SDK "for legal reasons",
and Apple's agreement says the SDKs may not be installed, used or run "on
any non-Apple-branded computer", which is the Linux gate exactly. That is
not a legal opinion and Apple's own forum answer to the question is to
consult a lawyer; it is the reason this project will not be the one to find
out.

What outranks all three: no backend exists for macOS arm64 or Cortex-M, so a
cross toolchain for either would have nothing to assemble. Building one now
would ship infrastructure nothing exercises, which is the failure this
roadmap has already recorded against itself once.

The `runtime` fixture class has landed with it, so the gate proves the
executed path rather than a person having run it by hand once.
`runtime/constant-return-exits-with-its-code` is compiled, linked and run by
the suite, and its own exit status is what is asserted. The separate
`runtime/add-exits-with-its-sum` case computes `40 + 2` in the function body
and crosses successful signed and unsigned add and subtract operations, so
the same status now proves emitted arithmetic and distinct continuation
labels rather than a literal alone. And
`runtime/comparisons-exit-with-their-verdict` reaches 42 only when asymmetric
signed and unsigned operands produce the verdict all six source comparisons
promise; reversing `cmp`'s operands or using a signed condition for `255u8 >
1u8` reaches the other status. Finally,
`runtime/wrapping-add-and-subtract-cross-the-boundaries` proves `255u8 +% 1`
and `127i8 +% 1` cross their upper bounds while `0u8 -% 1` and `-128i8 -% 1`
cross their lower ones. `runtime/multiplication-exits-with-its-products`
exercises representable signed and unsigned products at 8, 16, 32 and 64 bits,
so all four one-operand instruction widths and both flag interpretations run on
the emitted-for hardware. `runtime/wrapping-multiplication-keeps-low-products`
multiplies each fixed-width signed maximum and unsigned maximum by two and
observes the low-width result across the same matrix.
`runtime/division-and-remainder-exit-with-their-results` executes signed and
unsigned quotient and remainder operations at all four fixed widths, including
negative truncation toward zero and a remainder with the dividend's sign.
`runtime/minimum-remainder-minus-one-is-zero` executes the non-trapping special
case at every signed width, rather than merely finding its branch in text.
`runtime/unary-and-bitwise-exit-with-their-results` negates a signed, an
unsigned zero and a 64-bit value, complements at two widths, applies each
bitwise operator at 8, 32 and 64 bits, and reads both directions of `not`, so a
width-wide complement standing in for `not` reaches the other status.
`runtime/shifts-fill-with-zeros-beyond-the-width` shifts within the width at
8, 32 and 64 bits, then past it in both directions, and every over-wide amount
in it is one x86-64's masking would answer differently: `1u8 << 32` masks to a
shift by nothing rather than to zero, as do `1u64 << 64` and
`4294967295u32 >> 32`, while `1i32 << 40` masks to a shift by 8. `-1i32 >> 32`
and `-1i8 >> 8` are D13's own case, and both are -1 on a backend that lets
`sar` exhaust itself.
`runtime/calls-return-through-the-abi` carries six arguments of six different
widths and checks each against its own value inside the callee, so a register
filled out of order or at the wrong width reaches the other status; it also
recurses ten deep for a triangular number, calls a function returning none as
a statement, and discards a result.
`runtime/module-values-hold-and-are-updated` reads folded module values back
on the hardware — an arithmetic fold, one that names another, D13's shift
beyond the width, a complement at a byte's width, a negative one, `u64`'s
largest and a comparison — and then calls a function twice that adds to a
`mut` module binding declared with no value, so D10's zero is where the count
starts from. It also runs four of those expressions a second time as
instructions and compares the two answers, which is the check that matters
for a fold: a shift, a division and a remainder over negative values are
where a folder and a processor can disagree, and one of them was wrong until
that comparison existed.
Three more came out of asking what this item had proved rather than what it
had emitted, and the question was worth asking: every positive fixture emitted
assembly, and emitting is not running. Four of [1810]'s statement forms had
never executed — `return when`, a bare `return` inside a body, an `elsif`
chain, and `inc`/`dec` — so a wrong branch edge or a mis-emitted epilogue
would have passed the whole gate on the strength of the compiler having
accepted the program. `runtime/statements-run-as-they-read` runs all four.
Every executed call had carried integers, so `runtime/bools-cross-the-abi`
passes and returns [1870]'s one-byte bool through [1650]'s registers. And
`runtime/recursive-fibonacci` is the first program here that is a program
rather than a probe: a function that calls itself twice with one call's result
feeding a checked `+`, over a frame that has to survive both, 242785
activations deep at `fib(25)`. All three passed on the first run, which is the
outcome to be suspicious of and the reason to record that they had been
missing rather than to note that they pass.

Their programs are held to the grammar exactly as a positive fixture's is,
since they are legal source the compiler must accept; `check.py` derives each
and reports a fixture the grammar cannot.

The audit found one more, and it is the shape of defect this item can produce
at all: a program the frontend accepts and the backend cannot emit. Nothing in
the kernel bounds a parameter list, [1650] hands six integer arguments in
registers and the rest on the stack, and the stack half is not written — so a
seventh parameter met `Argument_Register`'s compiler defect and `refine`
exited 70 saying "internal compiler defect". That is the one answer an
accepted program must never get: it is neither a compilation nor a diagnostic,
and it reads as a bug in the compiler rather than as a limit of it. `L0503`
now names the routine and says what it exceeded, the driver asks before
anything is written for [1970]'s reason, and `Register_Arguments` is a single
constant so the number cannot disagree with itself. Stack arguments belong
with the internal ABI at R2.30; until then this is a stated limit rather
than a crash.

The audit's last finding was not this item's to cause and is this item's to
have exposed. [1940]'s cycle rule was implemented in one place only — the
guard that catches a module value whose *type* is being inferred from itself
— so `a: i32 = b + 1` beside `b: i32 = a + 1` slipped past it: both write
their types down, nothing is ever Underway, and the checker's own fold walked
the chain to its depth limit and returned quietly. `refine` accepted the
program and said nothing, and the only thing that noticed was this item's
folder meeting the cycle three stages later and raising a compiler defect.
The fold now carries its own guard over the declarations it is standing
inside, and reports [1940]'s refusal naming the declaration the chain came
back to. A chain of three reports three times, once per member, because each
member is separately a value no type holds — which is the rule
`compiler/tests/README.md` already states about `codes` being a list rather
than a set.

That guard also retired a depth limit that was doing semantic work it should
never have done. The fold stopped at sixty-four links and returned quietly,
which was written when the only thing that could recur forever was a cycle
[1940] was assumed to have reported already. It was accepting two kinds of
program in silence: a cycle longer than the limit, and — worse, because it
is legal source — an honest chain longer than it, whose fold was then never
checked against its type. A chain of three hundred `u8` bindings each one
more than the last was accepted entire; it now reports the forty-five links
whose answer no `u8` holds. Nothing bounds the walk now except the cycle
guard and the parser's own nesting limit, which is where a bound on how deep
a program may be written belongs.

It has no home in the negative corpus, which is worth recording because the
next backend-only refusal will meet the same wall. A negative fixture is run
as `refine program.ldn` with no `--emit`, and this program is accepted there:
it is refused only when something is asked to be emitted for a target. So it
is an end-to-end fixture, which runs `refine` with the fixture's own arguments
and compares the bytes.

What none of this shows is that the language works. The enabled kernel is
[1740]-[1830] and the tour is the whole language, so `while`, `for`, `loop`,
`match`, `defer`, `undo`, `try`, `fail`, `break`, `continue`, `type` and every
construct built on it, the three float widths and the three text views are all
refused by name, each citing the paragraph that describes it and the item that
enables it. There is no I/O either, so a program's exit status is the only
thing a fixture can observe. R1.80 is a working vertical slice through a small
language and not a working language, and the fixtures above should be read as
evidence for exactly that.

[1960]'s native trap evidence is here too, and getting it needed the runtime
seam widened rather than a fixture written. A `Tool_Result` carried an integer,
and an integer cannot tell a program a signal killed from one that exited with
some number — so a trapping fixture could only have been written by freezing
the encoding [1960] declares unstable. `Landin.Platform` now answers how a run
ended as well as what it returned, in two values and not a number: `Exited`
with a status, or `Signaled` with none. No signal number reaches the record,
which is the whole point of the distinction. The decoding is measured rather
than assumed — the pinned GNAT's own spawn answers -1 for a child killed by
SIGILL and by SIGSEGV and the true status otherwise, and a POSIX exit status is
one byte and so can never be -1 — and `compiler/tests/README.md` records what
that measurement was.

A fixture says `traps: yes` in place of `status`, because a program that
trapped has no status and claiming both is claiming an answer nobody can
observe. `runtime/checked-overflow-traps` is the one that discriminates: it
adds one to a `255u8` the compiler cannot read, and without the backend's own
overflow check the instruction keeps the low byte and the program returns 42.
Removing that edge and running the gate turns the fixture red, which is
measured rather than argued. `runtime/a-zero-divisor-traps` proves [1950]'s
other obligation but cannot tell the deliberate `ud2` from the fault x86-64
raises anyway; deterministic assembly is what pins D11's choice between those,
and this is recorded so the fixture is not read as evidence it is not.

Widening that seam found a defect one level up, which is the argument for
widening it rather than reading a number more cleverly at the fixture. The
driver asked whether the assembler's status was zero, and a tool a signal
killed has no status: with the two folded into one integer it read -1 and
reported a failure by luck, and with them apart it would have read the zero
beside `Signaled` and called a dead assembler a success that wrote nothing.
The driver now asks how the run ended before it asks what it returned, and a
case pins it; the fixture harness asks the same before reading a recorded
status or sending a compiled program to be run, since a `refine` that died
after writing the right bytes would otherwise satisfy a fixture expecting
zero, and a compile that died would send a stale executable from an earlier
run to be executed as this fixture's answer.

The decoding itself is measured on whichever host runs the suite rather than
once on Linux and assumed elsewhere: a platform case kills a shell with SIGILL
through the real adapter and holds the answer to being `Signaled`, beside one
that exits 3 and carries its status. That case touches the real host on
purpose — how a killed process is reported is a fact about the host and the
pinned runtime, and a fake would only repeat what this adapter was told to
believe.

A host that cannot finish the target fails rather than skipping, and that was
a decision with a real alternative. Skipping keeps a macOS run green, and
`compiler/tests/README.md` already refuses it in one sentence — "A fixture
that records an expectation nobody runs is [a fault]" — because a green run
that tested nothing is worse than a red one, and because the same silence
would hide the Linux gate losing its own toolchain. The failure carries
`refine`'s report, so `L0500`'s note is what tells the reader which toolchain
would satisfy it. This is the rule `scripts/env.sh` already applies one level
up, where a machine without the pinned GNAT is told so and stops rather than
quietly building nothing; a third outcome beside pass and fail was considered
and declined as machinery bought for one case.

Sources: `[1550]`, `[1650]`, `[1950]`, `[1960]`, `[1970]`.

Exit evidence: `refine` compiles a kernel `.ldn` program to deterministic
assembly, assembles, links and executes it on native Linux x86-64 with the
expected status; a program whose divisor is zero only at run time traps
rather than returning a value, and a shift past the width yields zero on
hardware that would have masked the count.

Closed against those four clauses one at a time, which is what found the
three things wrong with them. Deterministic was asserted in this item, in the
backend's own header and in `compiler/ada/README.md`, and nothing checked it:
a case now lowers one source through two compilations and compares the text,
and the emitted bytes were measured identical on macOS arm64 and on Linux
x86-64 by hand. A seventh parameter met a compiler defect and exited 70,
which is the one answer an accepted program must never get; it is `L0503`
now. And [1940]'s cycle rule was implemented for the chains that have a type
to infer and no others, so a typed one was accepted in silence — twice over,
because the fold's depth limit was quietly accepting long chains as well.

The last of those is the shape worth remembering rather than the individual
bug. Every one of them was found by asking what this item had *proved*
instead of what it had *built*: every positive fixture emitted assembly, and
four of [1810]'s statement forms had still never run. Emitting is not
running, and a corpus that stops at "the compiler accepted it" says nothing
about what the machine then does.

What is finished is a vertical slice and not a language. R1.90 closes the
kernel corpus behind it; internal stack arguments wait for R2.30, `Landin.Checking`'s
own module fold is still exponential on a chain nobody writes, and a runtime
fixture still cannot name two source files. Each is recorded above where the
work that meets it will find it.

### R1.90 — Close the executable-kernel corpus

Status: complete
Depends on: R1.80

Tie grammar, diagnostics, syntax, checking, IR and native behavior together in
one construct-indexed corpus.

R1.80's audit leaves this item three things to start from, each recorded
where it was found. No positive fixture is executed, only emitted, so the
matrix has to say for each construct whether it was accepted, emitted or run — those are three different claims and only the third is
evidence about a machine. A runtime fixture names one `program`, so a
multi-file module cannot be expressed as one at all, though the driver
compiles several sources as one module. And a refusal that only a backend can
raise has no home in the negative corpus, because a negative fixture is run
without `--emit`; `L0503` is an end-to-end fixture for that reason.

The first of those is closed. Every positive fixture is now handed to a
backend as well as to a parser: the suite runs `refine --emit=asm` over all
of them and fails on a program that was accepted and could not be emitted,
carrying `refine`'s own report. It is measured rather than assumed — with
[1650]'s register count temporarily cut to one, the case reports
`positive/call-fills-every-parameter: accepted but not emitted` and names
`L0503` as the reason. What a positive fixture still does not do is run;
that is the runtime class, and the distinction is the one this item's exit
evidence now asks each row to state.

The corpus now says what it is evidence about. A fixture carrying a program
names the constructs it exercises, and `check.py` holds every one of them to a
paragraph `tour.md` or `spec.md` defines while the harness holds it to being
four digits — each half asked of the side that can answer it. A fixture with
no program names none, because an unknown option and the identity text are
about the tool rather than the language.

It is a written list and not a reading of the summary, and that is the same
decision the fenced-block rule already made one level up: a citation in prose
is there to explain the fixture to a person, may name a paragraph the fixture
merely mentions, and a heuristic over English is how a check ends up believing
114 lines of it were code. The 118 fixtures that already cited a construct
were seeded from those citations and the remaining 17 were written by hand,
which is why the list is a starting point to be corrected rather than a
finding: 51 constructs are named so far, and all ten of [1740]-[1830] are
among them.

The matrix itself is generated, for the reason the catalogue and the token
dump already are: a hand-kept index of 197 rows is an index that will be
wrong. `check.py --matrix` writes `compiler/tests/constructs.matrix` and a
full run refuses it when stale. Every construct either document defines gets
a row, against the three claims the corpus can make about it — accepted,
emitted, executed — plus whether the parser refuses it by name and cites the
paragraph, which is what explains a row for a construct the kernel does not
enable.

It reads at 197 constructs, 61 with evidence and 136 with neither, and all
twenty-four of [1740]-[1970] are covered. The 136 are mostly the language the
kernel has not reached, and the file says in its own header what it is
measuring: evidence is what a fixture *claims* out of its `constructs:` list
and not what the program in it actually exercises, so a runtime program full
of literals says nothing about [1770] unless it names it. Under-claiming is
the expected state of a list seeded from prose, and the first pass over it is
done: every construct of [1740]-[1970] that can be executed now is, and the
four that are not — [1830], [1850], [1860] and [1910] — are rules about what
a compiler refuses or checks, which nothing runs. Sixty-one constructs carry
evidence.

The rule that keeps that number worth reading is written into
`compiler/tests/README.md`: name a construct when the fixture's passing would
change if it were implemented wrong, not when it appears in the text. Every
runtime program contains literals, so claiming [1770] everywhere would fill a
column and say nothing. That rule caught one of this pass's own claims —
`runtime/statements-run-as-they-read` was given [1840] while declaring nothing
inside an `if` arm, which is not evidence about arm scopes — and the fixture
grew a function that declares the same name in both arms rather than the claim
being quietly kept.

Reading the bare rows separated two things that had looked like one. Most of
the 136 were the language the kernel has not reached — floats, characters,
text, ranges, `sizeof`, pointers, arrays, slices — and their silence is
correct. But a second group was covered all along and unattributed: a fixture
demonstrating an inferred binding cited [1790], the kernel rule it was written
against, and not [0050], the paragraph that teaches the thing. The tour is
where the language is explained, so a fixture that demonstrates a tour rule is
evidence about it, and thirteen such attributions were added after reading
each paragraph against the program that claims it.

Two rows were neither, and both became fixtures. [0150] names `u128` and
`i128` while [1790]'s type rule does not, and the kernel already refuses one
by name — `L0101`, rather than reading it as a name that declares nothing —
with nothing pinning that. And [0410] fixes evaluation order, which no fixture
could have observed: every runtime program until now asserted a *value*, and a
value is the same whichever operand ran first. `runtime/evaluation-order-is-left-then-right`
watches it through module state instead, since the kernel has no I/O to watch:
`step(1) + step(2)` leaves a trace reading 12 rather than 21, and the
arguments of one call leave 34 rather than 43. Asserting the reverse exits 1,
which is what makes it evidence rather than decoration.

The matrix reads 76 with evidence and 121 with neither, and what is left in
that 121 is language the kernel does not have.

The last of the three is closed too. A runtime fixture named one `program`,
so [1840]'s own sentence — the module scope is "every file compiled
together" — was a claim the corpus had no way to make, though the driver has
compiled several sources as one module since R1.50. A fixture may now name
`with`, the rest of the module, and `runtime/one-module-across-two-files`
executes a program whose `main` calls a function and reads a module value
declared in the other file while that file reads one declared back in the
first. Neither file is self-contained, which is what makes it evidence about
a set rather than about two programs that happen to link: deleting the `with`
line leaves `refine` unable to resolve either name.

The fourth word in this item's exit evidence turned out to be asking for
something the design forbids, and the wording is corrected below rather than
the design bent to it. There can be no verifier *fixture*:
`Landin.IR.Verifier`'s own header argues that malformed IR cannot be caused
by a source program — the frontend refuses every ill-formed one and this
stage refuses to run on a refused one — and the `L0400`-`L0499` band is left
unassigned precisely so that no code promises otherwise. A fixture class for
it would be a promise `landin.ads` forbids.

What the clause can honestly ask is that the verifier *runs* in the real
driver path, and it does: `Landin.Stages.Lowering` verifies every Unit it
builds, in every build mode, and its body raises rather than asserting so a
release build does not quietly skip it. Both halves were measured.

That left one thing worth guarding. Because no fixture can reach the
verifier, deleting the call would turn all of its rules off without a single
case going red — the failure this item exists to find, in the machinery of
the item itself. `check.py` now holds the lowering stage to making that call,
which is the same kind of structural rule as the one that keeps every code
literal in the catalogue: some invariants are about where a line is and not
about what a run produces.

Closing it found what closing R1.80 found, in the same shape and one level
up: the corpus had a second layer of rows that were covered and unattributed.
[0880]'s single-expression body that still takes an `end`, [0890]'s `-> none`,
[0930]'s named return assigned before the return, [1020]'s explicit discard,
[1050]'s branch and [0870]'s function value all had fixtures citing the kernel
rule and not the paragraph that teaches the thing. Ten more attributions, and
the matrix reads 82 with evidence against 115 that are language the kernel
does not have.

One row was left deliberately. [1550] says Landin keeps its own native
backends, which is true and which every runtime fixture depends on — and no
fixture *discriminates* it: a Landin that emitted LLVM IR would exit 42 just
the same. Claiming it would be the failure the claiming rule exists to
prevent, so the row stays bare and this sentence is why.

And one row was a divergence rather than a gap. [1670] says a failed check
calls a fixed never-returning `panic_handler` taking an atom and a site
number, and R1.80 emits `ud2`; nothing in either document reconciled the two,
and D11 read as though calling a routine had been considered and declined.
It had not: `panic_kind` is a `type` over atoms and `noreturn` is a return
form, and [1790] enables none of them, so [1670] is a paragraph this kernel
cannot reach rather than one it rejected. D11 now says so and names R6.70,
which owns panic behaviour.

Exit evidence: positive, negative and runtime cases all run through the real
driver and the verifier runs inside it on every Unit lowered; the construct
matrix has no unexplained kernel row, and each row says whether the construct
was accepted, emitted or executed.

Closed with the corpus indexed and the index generated. What the item is not
is a claim that the corpus is finished: 82 rows carry evidence, 115 are
language the kernel does not have, and every one of those 115 becomes work
for whichever item enables it. The matrix is the place that will say so,
which is the whole reason for building it rather than counting fixtures.

Two habits came out of it and both are written where they will be met.
Attribute a fixture to the paragraph that teaches the thing and not only to
the kernel rule it was written against — two passes of this item found rows
covered all along and unattributed, and the second pass found them after the
first had already looked. And name a construct only when the fixture's
passing would change if it were implemented wrong, which is what keeps a
column from filling up with rows that mean nothing; [1550] is bare for that
reason and says so.

### R1 gate

- The enabled grammar is normative in `spec.md`.
- Recovery produces multiple useful diagnostics.
- A real `.ldn` program compiles, links and runs on native Linux x86-64.
- Unrelated representation and freestanding questions remain owned by later
  work rather than silently answered.

## R2 — Semantic and representation core

R2 supplies the target-parametric representation and evidence foundations
needed by the hosted parser. Raw storage remains container-driven and closes
in R3 rather than being designed in isolation.

### R2.10 — Establish target-parametric data layout

Status: complete
Depends on: R1.60, R1.70

Implement target facts, scalar widths/alignment and checked layout arithmetic.
Add synthetic 32-bit layout goldens before a Cortex backend exists.

Most of the model arrived with the chassis: `Landin.Targets` has held the
facts, the widths, the alignments and the checked arithmetic since R0.60, and
cases already refuse an alignment it will not guess and report an overflow.
What it did not have was a way for a *program* to observe any of it, which is
what "measurements agree with the target model" asks for — so [0370] is
enabled, and `sizeof` and `alignof` are the first constructs of the tour to be
turned on since the kernel was drawn.

Two decisions came with them and both are D14. A measurement is a `usize`,
because a size is a count of bytes on the machine being compiled for and that
is what [0160] says `usize` is; and the answer is not folded by the checker or
the lowering. `Landin.IR` carries `Measure_Size` and `Measure_Align` with the
type asked about, and the backend answers, because a size needs a width and a
width needs a target — the same seam [0320]'s zero-fill already sits on, and
the one that keeps the IR target-neutral. A case emits one source against two
descriptions and reads 8 against Linux x86-64 and 4 against the synthetic
32-bit one, from a host that is neither.

The goldens are the other half, and they are recorded rather than generated:
producing one means asking the target model, which `check.py` cannot do, so
`./scripts/test.sh --record` writes `compiler/tests/layout.targets` beside
`lowering.ir` and a case holds it to what the model says now. Both described
targets are in it rather than the synthetic one alone — what a reader needs
is the two columns beside each other, because the defect being guarded
against is a description quietly inheriting the development host's answers,
and a `usize` reading eight in both would be exactly that.

`lenof` is the third of [0370] and is not enabled with them: it measures an
array or a slice, [1790]'s type rule has neither, and R2.20 is where they
arrive. It is refused by name and cites the paragraph, like every other
construct the tour describes and the kernel omits — and refusing it took
consuming the name it was measuring, because leaving that behind turned one
answered question into three reports about a statement shape.

Closing it against those clauses found one defect and one overstatement.

The defect was in the slice above rather than in the model: an expression
body would not take a measurement. [1800] says a body may be one expression,
and `Parse_Body` decided what one was from its own list of tokens — a
literal, a paren, a prefix sign — written before [1820] had a first set to
ask. Adding `sizeof` to that first set did not add it here, so
`g: () -> (r: usize) = sizeof u64 end` was refused with "this begins no
statement" while `g: () -> (r: usize) = 8 end` was fine. The body now asks
`Begins_Expression`, which is the question it meant, and a fixture pins the
case. The lesson is the one a second list always teaches: the duplicate was
right when it was written and wrong the moment the thing it duplicated grew.

The overstatement is "diagnosed". Aligning past the end of `Byte_Count` and
an alignment that is not a power of two both raise `Compiler_Defect`, which
is correct today and is not a diagnostic: no source program can ask for
either, because the kernel has no aggregate to lay out and a frame of local
scalars cannot approach 2**48 bytes. R2.20 is where a program can first
describe a layout of its own, and where these become reachable from source
and so need codes rather than defects. The clause below says what is true
now and names the item that changes it.

The first clause is honestly met and worth saying why: the runtime fixture's
constants are read out of the System V ABI rather than out of `Landin.Targets`,
so a model that disagreed with the machine would fail it. A fixture that
asserted the model against itself would pass whatever the model said.

Exit evidence: a program measures its own target with [0370] and the answers
are the System V ABI's; the synthetic 32-bit description differs from the
Linux x86-64 one in `compiler/tests/layout.targets` where a pointer width
should make it differ and nowhere else; overflow and impossible alignment
raise a compiler defect, which R2.20 turns into a diagnosis when a program
can first cause one.

### R2.20 — Implement aggregates, variants and complete value layout

Status: complete
Depends on: R2.10

R2.20 established the target-parametric representation and executable
storage operations for the first aggregate kernel. The normative choices and
their alternatives live in `spec.md`'s decision register; this completed item
records the capability boundary, implementation architecture and evidence
without repeating the case-by-case development diary.

The slice delivered four connected results:

- D15 moved type names out of parser-owned scalar recognition. Type positions
  now resolve ordinary identifiers, aliases follow their declarations, and
  deferred scalar names are refused by the checker as `L0304`.
- D17--D43 established fixed arrays: structural identity, `usize` extents and
  indexing, per-element definite assignment, whole copies, contextual and
  inferred literals, compact repetition and mixed repetition, `lenof`, and
  complete `zeroed` assignment.
- D44--D72 and D86--D87 established ordinary aggregate storage: ordered,
  target-measured fields; fixed-array fields; contextual and inferred local
  values; static module images; labelled literals; field and whole-value
  copies; and depth-one nested ordinary structs.
- D73--D85 established the default variant representation and its first value
  operations: named cases, contextual construction, static selected-case
  images, exhaustive `match`, and scalar or fixed-array payload aliases.

The layout authority is `Landin.Targets`, not the Ada host representation.
Fields retain source order, each field is aligned at its placement, and the
whole value rounds to its widest alignment. The default variant policy is
D74's unfolded tag-first representation with an explicitly measured payload
offset and alignment. `layout(optimal)` remains R4.50 work, `layout(c)` remains
R4.40 work, and packed representation remains R6.40 work.

The checker carries declared aggregate identity and source shape separately
from scalar type kind. Lowering preserves declaration, field and case
provenance in target-neutral IR; target offsets and padding enter only in the
layout/backend path. Static module images remain compact instead of expanding
repetitions into element lists. Definite assignment tracks struct fields,
known array elements and whole-array facts, intersecting those facts at
control-flow joins.

Review during the slice also closed three frontend and driver boundaries that
became visible once aggregate syntax was admitted:

- the parser gives precise refusals for deferred slices, array literals and
  postfix indexing in every reachable postfix position;
- a refused field or aggregate never reaches a missing-layout precondition;
- diagnostics already accumulated by a compilation survive an injected host
  or tool defect, with the driver returning `Status_Defect`.

The intentional boundary is general aggregate values. Aggregate parameters
and returns, deeper recursive composition, aggregate array elements and the
remaining construction/copy forms belong to R2.30's aggregate-value and
internal-ABI work. R2.20 proves their representation and storage substrate; it
does not claim their calling convention.

Sources: legacy A3, which had no tracked citation.

Exit evidence: D17--D45 and D86--D87 measure scalar, fixed-array, ordinary and
depth-one nested layouts against both target descriptions. D74 measures tag
position, tag width, payload offset and alignment. D24/D34/D38, D46--D72 and
D75--D85 exercise static images, runtime construction, copying and inspection
through verified target-neutral IR and the Linux x86-64 runtime corpus.
`layout.targets`, the lowering/verifier/backend public seams and the fixture
matrix make that evidence reproducible.

### R2.30 — Implement functions, control flow and declared errors

Status: complete
Depends on: R2.20, R1.70, R1.80

Implement full function values, named returns, non-loop control-flow
expressions, traps, declared atom-set errors, `fail`, `try`, call-site `else`,
`defer` and `undo`, together with Linux x86-64 internal calling/lowering rules.
R4.10 owns loops and their `break`/`continue` transfers; their syntactic
refusals name that item rather than this one. The first
completed increment retains the six-register scalar prefix and places every
later scalar argument in an aligned run of eight-byte stack slots, copied into
ordinary callee slots and reclaimed by the caller. Its runtime case crosses
both a seventh and an eighth argument, and `L0503` is retired rather than
reassigned.

The second increment opens D87's first nonzero path: a scalar leaf may be read
or written through one depth-one ordinary child. Definite assignment keeps the
parent and child identities, lowering and verified IR retain both without a
target offset, and the backend recursively places them against the selected
target. The intermediate child remains no general aggregate value.

The third increment extends that path to a scalar element of a fixed-array
leaf in the child. Known-element and whole-array assignment facts retain the
two field identities, the verifier checks the bounded child shape, and the
backend places both fields before adding the checked scaled index.

The fourth increment gives that fixed-array leaf the contextual assignment
forms direct array fields already have: literals, repetitions, `zeroed` and
storage-to-storage copies. Compact IR operations keep an independent
parent/child pair for each endpoint.

The fifth increment makes the ordinary child itself a contextual assignment
place for `zeroed`, matching labelled or nominal construction, and copies from
direct or child storage of the same nominal type. Lowering clears its padded
extent or visits its scalar and fixed-array leaves with independent endpoint
identities.

The sixth increment admits the nested child and fixed-array leaf as copy
sources for explicitly typed local initializers. Their written destination
type supplies the identity and fresh storage; module initializers remain
deferred.

The seventh increment lets a local infer that same nominal child identity or
fixed-array shape from the complete nested storage source. It remains a direct
copy into a fresh slot, not a general value; module inference, parameters,
returns and discards remain deferred.

The eighth increment admits a direct storage name as an argument for a flat
ordinary struct with scalar or fixed-array fields. One source parameter takes
one internal ABI position carrying an unspellable storage address; the callee
copies the target-derived padded extent into its own shaped parameter slot
before running. Nested and variant-bearing structs, construction arguments and
all aggregate returns remain deferred.

The ninth increment applies that one-position transport and defensive callee
copy to direct fixed-array storage names. Length and scalar element identity
stay on the parameter slot; literals and other array expressions remain
contextual rather than becoming general argument values.

The tenth increment carries the existing contextual source paths across that
boundary: a depth-one ordinary child, direct array field or nested child array
leaf may supply a matching aggregate parameter. Parent and child identities
stay neutral until the backend derives the selected target address.

The eleventh increment lets an aggregate parameter context type `zeroed`.
Lowering clears a fresh shaped caller temporary and transports its address
through the same convention, so no second all-zero ABI rule or general
aggregate expression is introduced.

The twelfth increment lets a fixed-array parameter context type an array
literal. Its elements fill a shaped caller temporary in source order before
that same one-position transport and defensive callee copy.

The thirteenth increment gives full and mixed array repetition the same
argument context. Explicit prefix elements are stored in order and one
repeated expression produces a compact suffix fill, including at D18 lengths.

The fourteenth increment lets a scalar-field ordinary-struct parameter context
type bare or matching nominal construction. Labels fill a shaped caller
temporary in source order and `of zeroed` fills omitted scalar fields before
ordinary transport.

The fifteenth increment extends that literal temporary to fixed-array fields.
Their existing literal, repetition, zero, storage-copy and fill forms retain
compact field-qualified IR and source-order evaluation.

The sixteenth increment admits variant-bearing struct storage as a parameter.
The shaped callee slot retains tag, case and payload runs, while definite
assignment requires a complete selected variant before a local crosses the
call.

The seventeenth increment constructs variant-labelled struct arguments in a
shaped caller temporary. Case selection clears the unfolded part before
source-ordered scalar or fixed-array payload writes and ordinary transport.

The eighteenth increment admits a complete struct parameter containing one
ordinary child. Its compact child field run remains nested in the parameter
slot, and definite assignment requires that whole child before transport.

The nineteenth increment constructs an ordinary child inside an outer literal
argument. Bare or matching nominal literals, zero images and direct storage
copies retain parent/child identities in the shaped caller temporary.

The twentieth increment adds struct results. One hidden internal parameter
names caller-owned shaped storage; the callee keeps an independent named-result
slot and copies its complete target-derived extent on leave. Calls therefore
carry no aggregate IR value and do not expose target ABI classification.

The twenty-first increment applies the same caller-owned convention to fixed
arrays. Their result slot retains only scalar element type and length, and
whole-array definite assignment reaches every successful leave.

The twenty-second increment routes a matching aggregate-returning call
directly into a typed local, direct assignment or named return, including an
expression body. Each source call boundary keeps its by-value copy without an
aggregate SSA value.

The twenty-third increment qualifies that hidden destination with neutral
field identities. Struct calls can fill an ordinary child, and array calls can
fill direct or nested array fields without an intermediate aggregate copy.

The twenty-fourth increment lets a local infer a returned struct's nominal
body or a returned array's scalar shape. Its fresh inferred slot becomes the
same hidden destination; module call inference remains forbidden.

The twenty-fifth increment composes result and argument boundaries. An inner
aggregate call fills a shaped caller temporary before the outer call transports
its address and performs the ordinary defensive parameter copy.

The twenty-sixth increment gives an explicitly discarded aggregate call a
shaped temporary lifetime through completion, then drops it without reading a
field or forming an aggregate IR value.

The twenty-seventh increment closes executable result evidence over every
aggregate shape R2.20 enables: flat and array-bearing structs, unfolded
variants, depth-one ordinary children and fixed arrays all retain independent
caller storage across repeated calls.

The twenty-eighth increment makes a direct function name an inferred local code
address and calls it indirectly. Verified IR retains the source signature as
type evidence while the backend calls the runtime address.

The twenty-ninth increment checks mutable replacement for complete signature
equality and proves indirect aggregate results plus register/stack arguments
reuse the direct internal convention without counting the code address as a
source parameter.

The thirtieth increment closes ordinary control-flow evidence for aggregate
calls: completion contributes a normal whole-place assignment fact, branch
joins intersect it, and guarded-return continuing edges preserve it.

The thirty-first increment closes early-exit evidence for aggregate results:
each accepted `return` performs the final copy from the independent named slot
to caller-owned storage, while a path without that complete slot is refused.

The thirty-second increment makes complete signatures first-class,
target-neutral descriptors in checking and verified IR. Declared routines,
written types, inferred values, code-address values, explicitly typed local
slots and calls carry descriptors rather than treating one concrete callee as
type evidence. [1800]'s infallible signature becomes a written type that a type
declaration may name and an explicitly typed local may store and call. The
verifier rejects malformed descriptors, mismatched function-value stores and
indirect address/signature disagreement before the x86-64 backend sees them.

The thirty-third increment generalises the target-neutral subobject path.
Every operation that names part of an aggregate carries a run of steps rather
than a parent/child pair, the verifier walks that run against the shapes, and
the backend sums one derived offset per step. No source form changes; the
recorded IR gains the base field and every step of every field operation.

The thirty-fourth increment removes the depth from ordinary nesting. A struct
field may be a struct that has one, layout recurses through the child's own
already-computed extent, and every scalar or fixed-array leaf is a value and a
place however many selections reach it. Definite assignment keeps one fact per
part named by the run, and a fact about a part follows from a fact about
anything containing it. A whole child below depth one, and a variant part
inside a child, remain refused.

The thirty-fifth increment gives a whole ordinary child the assignment forms
it has at depth one, at any depth: `zeroed`, a matching literal or nominal
construction, a storage copy, an explicitly typed local initializer and local
inference. A nominal construction whose body has an ordinary child is
admitted. A module binding's static image containing a child value remained
refused at this increment because [1940] folds an image rather than copying it;
the forty-eighth increment closes that carrier.

The thirty-sixth increment gives a variant case payload field an ordinary
struct type, with the contextual values a labelled child takes and a match
alias that names the whole struct. A payload struct holding a variant part of
its own stays refused. A module image containing an ordinary payload remained
refused at this increment because [1940] folds an image rather than copying it,
and D67's folded run had no carrier for a child's own image; the forty-eighth
increment supplies that carrier.

The thirty-seventh increment gives a fixed array an ordinary struct element.
Layout is that struct's padded extent repeated; whole storage is zeroed and
copied as any array is; and `a[i].f` selects a leaf of an element, which
[1820]'s `indexed` now derives. A whole element is not yet a value or a place,
because an index is a value and the contextual forms reach one through
identities alone; an array of a struct with a variant part has no carrier
either. Both refusals name this item.

The thirty-eighth increment makes infallible function signatures recursive and
carries one code-address value through parameters, named results and typed or
inferred module storage. Static module chains resolve to declared or anonymous
routine items and have no implicit zero image. Mutable module replacement,
stack-position callbacks, function-returning calls and aggregate results all
reuse the existing internal convention. Anonymous functions open a signature
scope directly inside the module, capture no enclosing routine declaration and
lower after module items in deterministic source/post-order to backend-local
routine symbols.

The thirty-ninth increment replaces the flow checker's Boolean exit summary
with explicit fallthrough and return-compatible edge facts. Only continuing
states participate in definite-assignment joins; guarded and unconditional
returns retain their distinct consequences, including when nested inside an
index or another expression whose later actions must not run.

The fortieth increment enables expression-valued `if`, exhaustive `match`, and
bare `begin` blocks. Every reachable fallthrough block supplies one scalar,
function-value, fixed-array or currently enabled aggregate shape, while a
returning edge needs no placeholder and still proves its named result.
Arm-local and bare-block scopes, contextual inference, malformed closers and
missing-value/type diagnostics are pinned through parser, resolver, checker
and flow cases.

The forty-first increment carries those values through caller-owned neutral
join storage. Scalar and function-value joins use unnamed slots, with function
signatures retained on code-address carriers; stored shapes retain their array
extent or nominal field run in one consumer-owned destination across bindings,
assignments, arguments, returns and explicit discards. The verifier sees
ordinary shaped storage and control edges, the x86 backend alone derives frame
offsets and copy extents, and runtime cases cover scalar, function-value,
fixed-array, ordinary-struct, variant-match, early-exit and source-order paths.

The forty-second increment gives the five variant operations D118's run, so
a variant part sits wherever an ordinary struct may: inside an ordinary child
and inside a variant payload. A match subject may be any chain that reaches
one, including a chain rooted at a payload alias. Composing a run and a
selected case fixes their order — the run reaches the part, the case is
selected inside it — and a run below a payload is a case step of the same run,
so nothing follows the payload.

The forty-third increment makes a known index one identity of the run rather
than a value, so a whole array element at one is a value and a place wherever
a whole ordinary child is, and an array whose element is a struct with a
variant part follows. Where a run may start became one question: base zero with
no run is the storage itself, base zero with a run is whole array storage, and
a positive base is a struct's field or an array's element position. This
increment left a computed index refused because reaching a whole element there
needed an address the contextual forms did not form; the fiftieth increment
closes that boundary.

The forty-fourth increment gives [0920]'s two-or-more named returns one
anonymous structural aggregate. Ordered result runs extend recursive function
signatures while labels remain call-site field names rather than function-type
identity. One hidden destination carries the complete padded result through
direct or indirect calls; each named return writes its field of an independent
callee slot, and every early or final leave uses the existing aggregate copy.
Whole inferred bindings, field reads, by-name partial destructuring, aggregate
and function-valued fields, and control-expression joins all retain that one
shape without a source-level tuple type or another ABI convention.

The forty-fifth increment enables `defer` over a lexical cleanup stack. A
reached statement registers only its call syntax; callee and argument
evaluation happens in reverse order after a block's final value on ordinary
fallthrough, and across every active inner-to-outer frame before a successful
return. Definite assignment is consequently checked at each execution edge,
while resolution remains source ordered at the statement. Cleanup calls lower
to the existing direct or indirect internal convention, including register and
stack arguments, function values, stored aggregate arguments and caller-owned
aggregate results. The neutral exit selector already distinguishes normal,
successful-return, failure and structured-transfer edges from a trap, which
never unwinds. D129 reserves its failure-only cleanup policy for `undo`, while
the forty-ninth increment supplies that spelling and R4.10 still owns every
loop transfer.

The forty-sixth increment enables payload-free atoms and declared errors.
Atom declarations mint identity; aliases and unions flatten to structural sets,
and singleton values widen only into containing sets. Concrete error sets join
recursive function signatures, while private `! ...` routines are solved as a
whole-module least fixed point, including mutual recursion. `fail`, `try`,
direct and indirect failing calls, standalone propagation and call-site `else`
use explicit fallthrough/failure edges across scalar, atom, function, fixed-
array and aggregate results; recovery names are scoped atom values, and atom
matches are exhaustive. Neutral IR carries atom-set runs, atom identities,
call failure slots, `Failure_Test` and `Fail`; malformed membership, signatures,
slots and exits are verifier faults. Linux x86-64 assigns dense nonzero `u32`
atom codes and reserves `%r10d`, with zero for success, without consuming an
ordinary argument or result position. Positive, negative, generated-IR and
Linux runtime evidence covers module/local values, recursive inference,
register/stack calls, direct/indirect calls, recovery and propagation. Failure
edges run every active deferred cleanup under the existing exit selector and
provide the failure-only edge consumed by the forty-ninth increment.

The forty-seventh increment completes the function-value storage form D117 and
D123 retained: an ordinary or variant-payload struct field carries one `usize`
code address plus its complete recursive signature descriptor. Construction,
field replacement, whole copy, aggregate arguments/results, nested children,
payload aliases and arrays of such structs all reuse the existing neutral paths
and internal ABI. A selected field is evaluated before its call arguments and
has its own definite-assignment fact. Static module struct and selected-payload
images carry verified routine relocations through named, anonymous or static
binding chains; no omitted, whole-zero or trailing-zero image may invent a null
function address. Linux runtime evidence crosses direct declarations and
indirect field calls, module mutation, computed indexes, failing signatures and
caller-owned aggregate storage.

The forty-eighth increment recursively extends folded aggregate images over
ordinary children and ordinary-struct variant payloads. One `Nested`
descriptor points into the item-owned declaration-order descriptor run; nested
children and selected payloads may point farther into that run, while scalar,
function-relocation and compact-array images retain their leaf forms. Neither
run carries a target offset, width or padding byte. Static constructions,
direct image names and directly selected ordinary children preserve nominal
identity, forward references, aliases, distinct storage and the existing
single-owner image cycle diagnostic. The release-build verifier rejects
malformed recursive counts, offsets, forms, partitions, routine targets and
target-range folds. The backend alone replays the neutral shapes into
synthetic-32 and Linux x86-64 widths, internal gaps, inactive variant tails and
aggregate tail padding. Linux runtime evidence mutates copied nested and
payload storage independently.

The forty-ninth increment enables `undo` on the failure-only edge established
by the forty-sixth. A reached statement joins the same lexical cleanup stack as
`defer`, so all applicable calls execute in one reverse registration order,
inner frame before outer. Direct and guarded `fail`, a failed `try`, and failure
arriving through deeper calls select undo while leaving `if`, exhaustive
`match`, bare `begin` and function blocks. Ordinary fallthrough, successful
return, a call recovered inside the block, structured transfer and trap stop do
not. Resolution remains source ordered; indirect callee and argument evaluation
is delayed until the selected edge, and definite assignment is checked against
that execution state. Lowering saves the declared atom across the ordinary
cleanup calls and then emits the existing failure terminator. Direct and
indirect calls, register and stack arguments, fixed arrays, aggregates and
anonymous multiple results retain their ordinary target-neutral convention and
caller-owned discard temporary, leaving the verifier and x86 backend no
unwind-specific form. R4.10 remains the owner of loops and their transfers.

The fiftieth increment performs the completion audit rather than treating the
preceding implementation diary as proof of closure. D134 gives every D127
whole-aggregate element context a computed index. Each such index is evaluated
and bounds-checked once before its use, then retained across control edges as
an unspellable address slot carrying the complete neutral element shape. Chains
may contain several computed indexes. Known positions remain identity steps;
the verifier rejects a non-`usize` index, a non-array base, a mismatched shape
or an ordinary integer substituted for the address, and the x86 backend alone
derives the padded stride and offsets. Typed and inferred copies, construction,
`zeroed`, direct and failing call results, non-loop control values, arguments,
named results and nested variant subjects and destinations all cross that one
carrier. Aggregate parameters and named returns are ordinary storage sources in
those copies.

The same audit removes refusal rows whose enabling work had already landed:
`try` and `fail` leave the parser refusal catalogue; a missing module function
image is [1940]'s `L0305`, not an R2.30 feature refusal; and calling a
non-function is [1920]'s `L0301` type mismatch. The aggregate-ABI refusal had
no reachable raise after parameters and results were enabled and is removed
rather than preserved as dead authority. `defer` and `undo` now parse the
ordinary complete call after their contextual word, so a selected function
field is delayed with its arguments just like a direct or locally stored
callee. R4.40 still owns C ABI classification and changes none of this internal
convention.

D118--D127 close the nested-ordinary forms R2.20 left contextual: whole
nested field selection, construction and copy, deeper recursive composition,
aggregate variant payloads, D17's fixed arrays whose element is an aggregate,
a variant part anywhere a struct may sit, and a whole array element at a known
position. D134 gives that element every computed-index context without changing
its definite-assignment rule. D132 closes the remaining static-image boundary for ordinary-child
and ordinary-payload values while preserving R2.20's neutral shape provenance
and leaving target layout in the backend.

Error atoms remain identity without payload. This item does not invent a
second error mechanism without executable pressure: R3.50's hosted I/O and
R4.40's `errno` boundary are the triggers. Each must demonstrate that an
ordinary diagnostics capability or other explicit parameter carries the
needed detail, or record language-evolution work when that program proves it
does not.

Exit evidence: ABI tests cover ordinary and failing calls, aggregate values,
inferred and explicitly typed indirect calls, function-valued parameters and
results, multiple named structural results and by-name destructuring, static
and mutable module addresses, no-capture anonymous routines, function-valued
ordinary and variant-payload fields through nested and indexed storage,
expression-valued non-loop controls, lexical reverse-order deferred cleanup,
failure-only undo interleaved with defer, late direct and indirect cleanup
arguments, more arguments than the register-only stopgap accepted and every
enabled control-flow exit path. `runtime/r230-composition` composes those
claims in one program: direct and function-field failing calls, register and
stack arguments, aggregate and anonymous multiple results, by-name
reconstruction, call recovery and propagation, function-valued control joins,
late aggregate cleanup arguments, normal fallthrough, successful and guarded
return, direct and guarded fail, failed `try`, local recovery, `if`, `match` and
bare-block exits. `runtime/r230-composition-trap` composes a computed aggregate
bounds trap with delayed function-field cleanups and proves registration does
not evaluate them; `runtime/computed-aggregate-elements` covers every computed
whole-element carrier, including nested indexes and scalar, fixed-array and
ordinary-aggregate variant payloads.
Malformed IR also proves
that a runtime address, malformed recursive image descriptor or static routine
target cannot substitute for its neutral descriptor. Recursive module image
evidence covers forward aliases and cycles, ordinary children and ordinary
variant payloads, distinct runtime storage, and both 32- and 64-bit target
layout facts.

### R2.40 — Implement fixed parameters and compile-time substitution

Status: complete
Depends on: R2.10, R1.50

Implement type and fixed parameters, substitution, constant array lengths,
deduction and fixed conditional declarations without introducing compile-time
execution.

D135's first increment now admits explicitly and fully applied parameterised
aliases whose substituted result is an enabled scalar or fixed-array shape.
Type applications are positional as [1350] writes them; generic call arguments
are a separate call-matching question. Type and fixed formals are compile-time
bindings, never runtime values, ABI positions or IR slots. The checker
normalises an alias application before equality, layout or lowering, so this
slice creates no nominal family identity and requires no generic routine item.
It accepts unconstrained type formals and fixed integer formals, substitutes a
fixed value into an array length, and refuses partial application, a wrong
actual kind, a non-fixed bound and recursive expansion. Symbolic declaration
validation rejects invalid free names, decidable formal or result kind errors,
and unconditional expansion cycles even when a template is unused. That
increment admitted only unconstrained formals; R2.60's D142 now adds direct
concept constraints without changing D135's substitution.

D136's next increment now gives fixed-array bounds one closed fixed-expression
fold. Direct bounds such as `[64 * 1024]u8` and alias-template bounds such as
`[n * 2]t` use the same evaluator over integer literals, fixed formals and the
target-independent non-wrapping arithmetic operators. Calls and runtime names
are rejected without execution; impossible operands, negative answers and
overflow are distinct diagnostics. D136 explicitly accepts source `[0]T` and
any admitted bound expression that folds to zero as D17's canonical
zero-element shape; empty literals and zero-length repetition remain separate.
When a failure depends on substituted actuals, its primary is the application
and its related label is the template expression. The result remains D17's
canonical count, D18 still checks target extent, and no instantiation answer is
written
onto a template node. Fixed actuals in type applications remain literals or
forwarded formals for this slice.

D137's nominal increment now carries that parsed struct body end to end. A
fully applied struct interns one checker-owned identity from its source template
and complete ordered normalized actual tuple. Alias-normalized actuals reuse a
key; different actuals or templates remain different even when unused or laid
out identically. Every enabled concrete identity may be a type actual, while
the substituted field or payload position decides its legality. Fixed formals
substitute bounds. Symbolic validation checks unused templates, and L0313
distinguishes impossible by-value nominal recursion from L0307 alias expansion.
Function-signature and type-actual normalization request identity only; the
same requirement now resolves an ordinary struct's preallocated empty-actual
identity through ordinary aliases for parameter, result and nested signature
positions. Self and declaration-order-permuted mutual signature cycles therefore
lay out only their pointer carriers. A declared or anonymous routine's direct
multiple-result ABI parts materialize before D128 places their caller-owned
aggregate, without promoting a nested callback signature. Fields, payloads and
nominal array elements request value layout, including at zero length. During unused-template validation a nonconcrete nominal or
nominal-array identity retains a transient symbolic template/binding
obligation; a used-formal value site follows it through nested wrappers and
reports a return to an active obligation as L0313, while phantom and function
mentions leave it identity-only. No symbolic obligation interns a guessed
actual or annotates syntax. For concrete applications the same value site
lazily reconstructs the interned binding and recursively promotes nested
nominal and nominal-array actuals, reporting a building identity as L0313 and
applying D18 only there. Each canonical identity
receives one selected-target layout when such a site requires it, without AST
mutation or a synthetic declaration. An invalid
layout is re-evaluated at another use of the same key so every dependent failure
retains its own application primary without duplicating identity. Existing
contextual aggregate storage,
images, construction, copies, calls, control joins, arrays, nested children and
variants then use the ordinary nominal shape path. Templates and formals make
no IR item, slot or ABI position.

D138 now extends substitution to direct generic calls across every enabled
normalized descriptor. The checker interns `(template, normalized actual
tuple)` routine identities, checks and lowers each through a fact overlay on the
shared source, publishes a signature before same-key recursion, rejects active
same-template unequal-tuple expansion, and maps each ready key to one local IR
routine item. Deduction synthesizes runtime arguments without parameter context;
a context-free literal therefore deduces `i32`. It recursively unifies each
written parameter pattern with that independent descriptor. Direct type formals
bind complete scalar, structural atom-set, fixed-array, nominal or concrete
function descriptors. Fixed arrays recurse through exact element and bound
patterns. A direct fixed bound binds the length; a computed D136 bound is never
inverted, waits for formals bound elsewhere, then folds and compares exactly.
Only-computed occurrences remain undeduced.

Parameterized nominal patterns require the same source template and recursively
match their stored normalized tuple, including phantom actuals. Parameterized
aliases expand symbolically without a guessed actual. Function patterns recurse
through parameter and result runs and their infallible, concrete or inferred
error form while ignoring labels. Repeats agree exactly. A saturated explicit
static tuple bypasses binding and validates all patterns by the same exact walk.
Fixed values and declared integer ranges are checked after the complete tuple.
No return context, conversion, constraint lookup, arithmetic inversion or user
code participates. Static formals remain outside signatures, slots and the ABI.
Explicit static call syntax is one named call list: when one static formal is
written, every static formal is named and the tuple is ordered by declaration;
runtime arguments remain [0980]'s positional prefix and named suffix. Fixed
conditional declaration lists are D139's completed increment.
Deduction does not use return context or constraint lookup. Concrete declared
atom error sets are substituted onto each instance signature and bound the
ordinary call graph. A private generic `! ...` template has no standalone
signature; every interned routine identity publishes an initially inferred
signature, scans the shared body through its own fact overlay and joins ordinary
and generic callees in one deterministic least fixed point. Call targets come
from that active overlay, including same-key direct and mutual recursion and
calls across different templates or keys. Equal keys share one node; unequal
keys retain separate finalized sets when their concrete callees differ. Empty
sets become infallible and nonempty sets become concrete before body checking,
recovery, cleanup, lowering, verification or backend emission. No static ABI
position or generic error operation is introduced. No correctness step executes
a user routine. R2.70 remains the owner of shared generic evidence and R4.50
the owner of choosing specialisation as an optimisation.

D139's completed increment now enables target-selected fixed conditional
declaration lists. It parses every arm immutably, then a compilation-owned
configuration stage selects module declarations after target selection and
before resolution. The selected view reaches resolution, checking, identity
interning and lowering; inactive branches retain lexical and parser reports
but have no semantic effect. Its closed evaluator admits only booleans, D136
mathematical integers and typed target architecture identity through intrinsic
`compiler.arch`; no generic formal, option, compiler call or user routine is
introduced. Linux, synthetic-32 and every future target constructor choose an
architecture explicitly rather than parsing a target label. D139 leaves the
full `landin/compiler` module, options and directives to R4.30. Integration
coverage keeps selected generic templates active through deduction and lowering:
`runtime/fixed-conditional-generic-runtime` executes one selected instance,
`positive/fixed-conditional-generic-activity` proves nested selection, inactive
malformed-template silence and mutually exclusive same-name templates,
`negative/fixed-conditional-active-generic-error` retains an active template's
error, `negative/fixed-conditional-inactive-parser-error` retains parser
reporting, and the lowering seam records that an inactive template creates no
item while a selected generic instance does.

The ordinary named-call checkpoint is now complete before explicit generic
statics. One shared checked match records every labelled application's runtime
argument role and formal position in the resolution table. A positional prefix
fills runtime formals in order and a named suffix may reorder the remainder;
duplicate, unknown and missing labels are L0301 with the first occurrence or
formal as related source. Direct declarations, stored function values and
selected function fields use the same match, while source-declared callable
signatures require unique parameter labels and structural signature identity
continues to ignore them. Checking, flow, error inference, generic discovery,
cleanup/recovery and lowering visit runtime expressions in written order;
lowering preserves that order through temporaries and emits ABI arguments in
formal order without moving hidden aggregate destinations or error carriers.
A rejected match records no routine target and lowering refuses an incomplete
match. The Linux `runtime/named-runtime-call-order` fixture covers direct,
indirect, function-field, indexed-selection and deduced-generic runtime calls,
including reordered side effects and differing declaration/type labels; the
`negative/named-call-*`, `negative/indirect-call-static-role-label` and
`negative/function-type-parameter-name-duplicate` fixtures pin the refusal
surface. D72 construction projections remain unchanged.

The structural generic-routine deduction surface is closed together with its
per-instance error graph. Inferred instance signatures are finalized in place,
so body checking and lowering cannot observe a stale `No_Atom_Set`; generic
recovery bindings are settled in the concrete caller view. A template still has
no standalone function value or guessed instance, and inactive D139 templates
remain absent. D138's implemented deduction does not use return context,
constraint lookup or arithmetic inversion. Parameterised nominal types
and generic routines already receive identities derived from a template and
normalised actual tuple rather than reusing one source declaration identity for
unequal instances. No correctness step executes a user routine. R2.70 remains
the owner of shared generic evidence and R4.50 the owner of choosing
specialisation as an optimisation.

Exit evidence: generic shape, nominal identity/layout, parser, resolution,
checking, lowering and verifier seams pass. Positive, negative and runtime
fixtures cover canonical reuse, alias normalization, unequal phantom actuals,
fixed layout changes, every enabled substituted field family, contextual value
transport, target overflow, malformed unused templates, declaration-order
independence, identity-only recursive signature and phantom nesting, lazy
nested nominal and nominal-array value promotion, repeated same-key application
provenance, alias-cycle classification, ordinary self/alias/mutual
signature-only cycles in both declaration orders, multiple named generic
nominal and nominal-array results, and nominal recursion including unused
order-permuted, mutual and multi-wrapper symbolic formal paths plus direct
field, payload and zero-length array edges. Routine evidence covers overlay
separation on one source node, equal-key reuse, unequal scalar items, deduced
`u8`/`i32`, context-free literal `i32`, unequal atom-set/function-signature/
nominal descriptors with aggregate transport and layout, exact `[n]t`
fixed/element deduction, nested nominal tuples, phantom actuals, parameterized
alias expansion, recursive function-signature matching, zero-length nominal
array element identity through direct, aliased and nested function signature
parts, a fixed formal bound in one relation followed by an exact computed-bound
check in another, explicit
computed checks, same-key recursion, repeated nested type/fixed-formal
conflicts, no-inversion undeduced formals, wrong nominal templates, non-finite
unequal-key recursion, declared and inferred per-instance error propagation,
call-site recovery, `try` through deduced and reordered explicit instance
targets, ordinary/generic and generic/generic fixed-point seams, direct and
mutual same-key recursion, unequal function-signature keys with
distinct inferred sets, finalized infallible instances, failure cleanup,
template-not-function-value refusal, unconditional unused-template defects,
and absence of static ABI positions or generic error IR. Direct and
expression-folded zero lengths and a syntactically valid rejected call in an
array bound remain covered; no user code executes during compilation.

### R2.50 — Implement references and local lifetime checks

Status: complete
Depends on: R2.20, R2.30

Implement pointers, slices, permissions, origins, `escaping`, `from`, local
borrows, escape rejection and use-after-consume checking. Preserve the honest
unsafe boundary around integer pointers and foreign code. Measure both
`atom | ptr T` and `a | b | ptr T` against R2.20's target-parametric variant
layout: only the one-atom case may assume the plain-pointer zero encoding
[0480] describes.

Sources: `[0430]`, `[0470]`, `[0770]`, `[0790]`, `[0830]`, `[0900]`, `[0910]`.

The first vertical increment is syntax foundation only. The enabled grammar,
reserved vocabulary, recovering parser and syntax table represent `ptr [mut]
T`, `[] [mut] T`, `addr` over a place, ordinary `.val` selection, explicit and
implicit `in`, `inout`, `sink`, `escaping`, and ordered `from` sources on named
returns. Resolution associates each retained `from` name with its runtime
parameter position for declared, anonymous and written function signatures.
D140 fixes the otherwise unstated modifier order. This increment deliberately
adds no reference type checking, permission or lifetime rule, origin/borrow
analysis, consume checking, IR operation, ABI carrier, backend emission, or
full-pipeline fixture; later R2.50 increments own all of those.

The second increment makes references complete checked types. Pointer and slice
descriptors retain their recursive referred type and shallow permission through
aliases, fields, generic actuals and recursive function signatures. `mut`
relaxes only to read-only. Pointer fields occupy one target pointer carrier;
slice fields occupy a target-aligned base/length pair. One-atom pointer unions
measure as the zero-optimized pointer carrier, while two-or-more-atom forms
replay the ordinary tag-plus-payload placement on both synthetic-32 and Linux
x86-64 descriptions. `addr`, `.val`, slice ranges, indexing, `lenof`, the
contextual empty slice, `ptr(integer)` and pointer-to-integer conversion are
checked without asking the host for a width.

The third increment gives conventions and references their executable carrier.
`inout` passes one internal address on register or stack and reads and writes
the caller's scalar, pointer, array or aggregate place; `sink` remains a value
carrier and kills the exact caller place until assignment. Verified IR carries
indirect scalar loads/stores, checked slice-address formation, canonical empty
slice bases, conversions, semantic conventions, `escaping`, and ordered return
source positions. The Linux x86-64 backend derives every pointer width, slice
stride, field offset and fit check from target facts. The runtime reference
composition fixture crosses pointer and aggregate dereference, direct and
aggregate `inout`, writable and relaxed slices, empty slices and both integer
conversion directions.

The fourth increment is the local lifetime pass. Values carry only frame and
symbolic parameter origins plus local derivation identities; integer-created
pointers explicitly leave that analysis. Every return edge agrees exactly with
its declared `from` positions, frame origins cannot return or reach an
`escaping` use, and a live derived view prevents `inout` or `sink` on its source
until that view is replaced. Sunk binding-rooted paths reject reads until
assignment, including branch joins, and a part sunk out of `inout` must be live
again on every return edge. This remains the deliberately local check [0860]
rather than ownership, regions or an interprocedural borrow checker.

Exit evidence: parser, resolution, checking, flow, lowering, IR, verifier,
backend, target-layout and fixture suites pass. `negative/frame-origin-return`,
`returned-reference-missing-from`, `escaping-frame-reference`,
`borrowed-source-inout`, `use-after-sink`, `sunk-inout-not-restored`,
`readonly-slice-write` and `sink-through-dereference` pin the diagnostic rules,
primary spans, related sources and notes. `positive/reference-origins-and-consume`
pins accepted derivation, unsafe integer origin termination, retaking a view and
reviving a sunk place. `runtime/r250-references` composes scalar and aggregate
pointer dereference, direct and aggregate `inout`, writable and relaxed slices,
inclusive/half-open bounds, empty local and static slices, static pointer and
slice fields, pointer/integer conversion and pointer/slice size and alignment.
The checker measures one-atom and two-atom pointer unions under both synthetic
32-bit and Linux x86-64 facts. The complete pinned Linux x86-64 gate passes 374
cases and 8,181 checks, including every runtime fixture.

### R2.60 — Implement concepts and conformance collection

Status: complete
Depends on: R2.20, R2.40

Concept declarations now retain their collected type formals, complete
signature-only entries and finite named composition graph. Type formals in
parameterized types, declared routines, concepts and conformance binders may
carry one direct constraint. Conformance declarations retain an optional
static binder, normalized target, direct concept identity, labelled concept
inputs and supplying functions. Concrete functions are checked against the
substituted entry signature; composed conformances require every parent
explicitly.

The checker owns a whole-program register keyed by normalized represented type,
concept identity and ordered input-type tuple. It collects concrete keys before
body checking, reports cross-file collisions without precedence, override or
an orphan rule, and interns a selected parameterized key when a constrained
application supplies its tuple. D142 makes that parameterized source form one
complete positional nominal family: this admits the container conformances
that forced [1250] while keeping unrequested collision collection finite and
introducing no specialization search. A second family or concrete exception in
that target-template/concept space is a collision. Supplying generic functions
and their selected binder tuple are retained for R2.70's evidence schema; no
table or dispatch operation is emitted here.

D143 makes `zeroable` the sole closed compiler concept identity. Programs need
no declaration for it and cannot declare either that identity or one of its
conformances. Its supplied family is the enabled scalars, fixed arrays exactly
when their element is zeroable (including length zero), and recursively
zero-imaged nominal aggregates; atoms, functions, pointers and slices are
excluded. The same recursive predicate checks contextual aggregate `zeroed`,
so ordinary image checking and generic lookup cannot drift, and no reflection
surface or synthetic source declaration is opened.

Sources: legacy A6; `[0550]`, `[1230]`--`[1290]`, `[1340]`; D142, D143.

Exit evidence: parser and resolution cases retain contextual words, collected
scopes and neutral labelled RHS forms; the checker register case pins closed
concept identity and normalized lookup. `positive/concepts-and-conformances`,
`positive/parameterized-conformance-lookup` and
`positive/compiler-zeroable-conformances` pass through emission. Ordinary and
unrequested parameterized collisions, a cyclic composition graph, missing
direct and composed constraints,
entry-signature disagreement, non-zeroable pointer and zero-length aggregate
elements, and attempted compiler conformance are pinned by their corresponding
negative fixtures. The complete pinned Linux x86-64 debug and release loops
pass 376 cases and 8,569 checks with the generated grammar, diagnostic, lexical
and IR records current.

### R2.70 — Implement the generic evidence schema

Status: complete
Depends on: R2.10, R2.30, R2.60, R1.80

D144 gives every concrete conformance one target-neutral evidence identity.
Its logical run is represented-type size, alignment, then direct concept
functions in declaration order; parent conformances remain separate. The
checker retains provider and routine-evidence runs, settles `T.entry` to its
concrete direct or inherited conformance and substituted signature, and gives
each constrained routine view hidden table parameters for the separate direct
constraint/parent closure in deterministic declaration order. Static
formals remain outside the source signature and ABI.

IR owns evidence descriptors, static table addresses and verified
source-order function loads. An evidence function is an ordinary signed
function value feeding the existing `Indirect_Call`, including its result,
error and cleanup paths. The verifier checks table partitioning, represented
shape, entry bounds, routine targets and signatures. Linux x86-64 emits private
relocation-bearing tables and derives every load offset from target facts. Each
physical member is one pointer-width cell, so size/alignment/first-function are
0/8/16 and an N-function table is `(N + 2) * 8` bytes there; synthetic-32
proves 0/4/8 and `(N + 2) * 4` without acquiring a backend.

The deterministic baseline keeps concrete D138 views but folds
representation-compatible evidence-only views onto one emitted machine body
after a bounded IR/ABI comparison. Evidence identity may differ because the
hidden argument supplies it; signed arithmetic, aggregates and every operation
whose physical meaning was not proved prevent folding. Failing that proof
emits separate bodies and cannot change correctness. No direct-call
specialization or devirtualization is required or introduced; R4.50 still owns
that optimization policy.

Sources: legacy A7; `[1310]`, `R§12`; D144.

Exit evidence: `runtime/generic-evidence-indirect` executes two fallible
conformances through two real tables and one representation-compatible emitted
body. `runtime/generic-composed-evidence` reaches a separately registered
parent entry through a child constraint. `runtime/generic-parameterized-evidence`
instantiates and dispatches a selected generic family provider, while its
negative counterpart pins the
post-substitution signature boundary. The backend case pins indirect dispatch,
table directives and body aliasing; target cases pin semantic order plus Linux
x86-64 and synthetic-32 offsets, extents, alignments and target-size overflow;
checker, IR, lowering and verifier suites retain the evidence identity and
signatures. The complete pinned debug and release loops pass 378 cases and
8,608 checks with recorded artefacts current; direct specialization is
not required.

### R2.80 — Implement `any C`

Status: complete
Depends on: R2.50, R2.70

D145 makes `any` reserved and gives `any C` exact direct-concept identity.
`any(pointer)` selects the contextual exact conformance, including a
parameterized family/provider, or infers only one unambiguous collected source
concept. D146 requires every exposed direct/inherited entry to have one first
object-safe `self: ptr [mut] T`, prevents hidden T from escaping elsewhere in
the signature, checks construction permission once, and carries the pointee's
origin through copies, aggregates, calls and results. Pair binding mutability
controls replacement rather than revoking pointer authority.

D147 fixes the pair as data then table, two target pointer-width cells aligned
to pointer alignment. Linux x86-64 is 0/8 and 16/8; synthetic-32 is 0/4 and
8/4. The direct D144 generic tables stay unchanged. A conformance used by
`any` additionally emits a size/alignment-prefixed erased table whose function
run flattens direct entries then each distinct represented-formal
constraint/parent closure in declaration order. Dispatch loads that dynamic
function, injects data as argument one, and reuses the verified indirect
result, error and cleanup paths. The pair uses shaped parameter/result/copy
storage and may occupy aggregate fields; `zeroed` cannot manufacture it.

Sources: `[1370]`, `[1380]`, `[1390]`; D145--D147.

Exit evidence: `runtime/any-heterogeneous-dispatch` executes immutable and
mutable entries through two heterogeneous real tables;
`runtime/any-composed-dispatch` executes direct and separately conformed parent
entries; `runtime/any-aggregate-storage`, `runtime/any-return-origin`,
`runtime/any-inferred-construction` and `runtime/any-parameterized-provider`
pin storage, shaped ABI, origin, inference and family materialization. The
negative any fixtures pin source shape, exact concept identity, ambiguity,
object safety, pointer permission and frame-origin escape. Target tests pin
both physical pair layouts while the existing evidence verifier checks the
flattened table descriptors. The complete pinned debug and release loops pass
379 cases and 8,702 checks with generated grammar, lexical, target-layout and
IR records current.

### R2.90 — Establish guarantee and semantic coverage registers

Status: complete
Depends on: R2.30, R2.50, R2.60, R2.70, R2.80

Classify every implemented operation as statically prevented, runtime trapped,
permitted only beyond lifetime checking, or outside guarantees. Tie each row
to acceptance, rejection, trap or explicit non-guarantee evidence.

Sources: legacy A5; `[0310]`, `[0430]`, `[0470]`, `[0770]`, `[0910]`, `[1120]`,
`[1720]`, `R§4`, `H§5`.

Exit evidence: no implemented semantic operation lacks a guarantee class,
diagnostic behavior and test owner.

Delivered: D148 classifies every accepted semantic boundary as `static`,
`trap`, `beyond-lifetime` or `outside`, and D149 makes the locally provable
part of `inout` exclusivity exact without claiming alias analysis. The source
registers cover guarantee boundaries, conformance/evidence mechanisms,
prototype derivations and target applicability; `check.py --coverage`
generates their four reading matrices and fails on stale rows, unknown
constructs, decisions, findings, fixtures or targets. Every fixture now names
its applicable targets.

The diagnostic matrix crosses every live catalogue contract with its emitter
and executable owner. Missing lexical/parser owners gained direct fixtures,
L0111 gained a bounded nesting-limit unit owner, L0005 gained a deterministic
fake-host owner, and malformed generic/erased evidence positions gained
verifier corruption cases. Runtime witnesses now distinguish every arithmetic
trap family, slice read/write and range trap boundaries, pointer narrowing,
unchecked pointer aliasing, copied-before-sink state and untracked erased
origins. That inventory also exposed and fixed shaped `any` results discarded
without a caller temporary. The pinned Linux debug and release gates pass 381
cases and 8,749 checks with every generated and recorded artefact current.

#### Prototype derivation coverage

A row means the fixture is a completed executable or negative derivation of
the named pressure, not merely that it uses a construct the prototype also
used. Source line numbers in the generated reading copy are recovered from the
finding labels, so moving prose cannot stale a hand-copied location.

| Fixture | Prototype | Findings | Pressure |
| --- | --- | --- | --- |
| `runtime/diagnostic-loggers-dispatch` | P2 | Y1 | recoverable diagnostics use a bounded or streaming capability without becoming parser failure |
| `runtime/derived-parser` | P2 | Y1, Y4, Y5, Y6, Y7 | a complete recursive parser builds an arena AST, logs and recovers from syntax faults, and propagates allocation or diagnostic-delivery failure through shared erased evidence |
| `runtime/parameterized-struct-values` | P3 | Z2 | type and fixed parameters on nominal values |
| `runtime/r250-references` | P3 | Z3, Z18 | pointer/slice carriers and implicit conventions |
| `negative/borrowed-source-inout` | P3 | Z5, Z16 | a derived view prevents moving its source |
| `runtime/variant-match-payload-bindings-update-storage` | P3 | Z7, Z14 | pattern conventions and payload-free cases |
| `runtime/generic-declared-errors` | P3 | Z9 | concept entries retain concrete declared errors |
| `runtime/generic-composed-evidence` | P3 | Z11 | explicit direct and parent conformances compose |
| `negative/sink-through-dereference` | P3 | Z12, Z13 | inout/sink place and permission boundary |
| `runtime/struct-literal-order-and-fill` | P3 | Z17 | contextual anonymous aggregate construction |
| `runtime/undo-cleanups-follow-failure-edges` | P3 | Z19 | failure cleanup moves its arguments at execution |
| `runtime/generic-parameterized-evidence` | P3 | Z1, Z4 | parameterized providers receive target-derived evidence |
| `negative/parameterized-conformance-entry-signature-mismatch` | P3 | Z1, Z4 | substituted provider signatures must agree |
| `runtime/constant-return-exits-with-its-code` | P4 | W2 | hosted entry uses the ordinary no-argument shape |
| `runtime/generic-composed-evidence` | P4 | W4 | a narrow concept composes rather than widening |
| `runtime/any-heterogeneous-dispatch` | P4 | W6 | erased state retains mutable permission and dispatch identity |
| `negative/any-frame-origin-escape` | P4 | W6 | erased state retains pointee origin |

#### Target applicability coverage

These are applicability assignments, not backend claims. Fixture metadata
makes the finer assignment and the generated matrix lists every fixture; a
missing `targets:` is a gate failure. `synthetic-32` is the executable target
model used before the Cortex-M backend exists.

| Scope | Targets |
| --- | --- |
| `prototype-1` | cortex-m |
| `prototype-2` | linux-x86-64, macos-arm64 |
| `prototype-3` | linux-x86-64, macos-arm64, cortex-m, synthetic-32 |
| `prototype-4` | linux-x86-64, macos-arm64 |

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

Status: complete
Depends on: R1.50, R2.40, R2.60, R0.50

Implement module directories, per-file imports, visibility, deterministic
ordered roots and whole-program conformance collection needed by the parser.
Add the unnamed thin orchestration seam without package acquisition.

Delivered: repeated `--root=DIR` options plus one entry directory close a
deterministically ordered graph of shallow directory modules before semantic
stages run. Plain import preludes bind file-local qualified namespaces;
cross-module lookup enforces public visibility for values, types, concepts and
inherited variant cases. Cycles load once, first matching roots do not merge,
only the entry module supplies hosted `main`, and all reached conformances
share the existing collision register. Legacy explicit-file invocation remains
the single-module compatibility surface. D150 records the decisions and the
module diagnostics have dedicated catalogue rows. Import aliases [1430] and
selected imports [1440] are named refusals assigned to R4.30.

Sources: `[1410]`, `[1420]`, `[1450]`, `[1480]`.

Exit evidence: a multi-module program resolves deterministic roots and rejects
ambiguous/colliding conformances.

### R3.20 — Build the allocator and container pressure case

Status: complete
Depends on: R2.50, R2.60, R2.70

The minimum allocator protocol remains [1360]'s two operations: allocate a
byte extent at an alignment with declared `out_of_memory`, and free that same
extent. The allocator is an ordinary constrained generic actual threaded
through each container operation; the container does not store it.

`runtime/allocator-vec-pressure` is an executable bounded-vector state model,
not proposed raw-storage syntax. Its element is `ptr node`, which has no zero
image. The trace reserves capacity two with zero initialized elements, admits
three pointers while growing to capacity four, releases one initialized tail,
drains the remaining initialized prefix before freeing, and proves that a
failed allocation publishes no replacement. Allocation/free counts, byte
extents and alignment are checked at each ownership boundary.

That case derives the R3.30 contract: reserve raw capacity with initialized
count zero; query capacity and initialized count separately; admit exactly the
next slot; expose only the initialized prefix; release only its final slot;
free only at initialized count zero; and grow transactionally by allocating an
empty region, transferring the initialized prefix, releasing and freeing the
old region, then publishing the replacement. The type must make reads outside
the prefix, double admission and invalid release unrepresentable or rejected.
It must not revive `slice_from`, whose `[]mut T` claims uninitialized bytes
already contain values.

Building the pressure case also closed three completed-prerequisite seams:
generic nominal layouts retain pointer fields, `try` preserves pointer result
descriptors and carries a successful pointer result through a block-local
spill, and `sizeof T`/`alignof T` inside a concrete generic routine view resolve
to that instance's type actual. Variant match bindings remain D78 aliases, so
the model explicitly saves a payload before D76's destination-first case
selection when a transition retains it.

Sources: `[0510]`, Z8, `R§2`, `H§4`.

Exit evidence: `runtime/allocator-vec-pressure` returns 42 only when its
seven-bit transition trace equals 127 for a non-zeroable pointer element,
including failed-growth publication and drain-before-free.

### R3.30 — Implement honest raw storage and `core/mem`

Status: complete
Depends on: R3.20, R2.10

`core/mem` is now an ordinary Landin module whose private generic `raw(item)`
representation keeps a byte pointer, capacity and initialized-prefix count.
Its public operations reserve empty storage, report the two counts separately,
admit exactly the next value, read only below the initialized count, release
only the tail, and dispose only an empty region. The declared `raw_full`,
`uninitialized`, `raw_empty` and `raw_not_empty` atoms make every rejected
transition recoverable without claiming that spare bytes already contain
values. D151 records the state machine, its deliberately absent spare-capacity
slice and the transactional grow protocol.

Module visibility now keeps the nominal identity usable through public
signatures while rejecting cross-module selection of its private fields. The
generic type-actual and lowering paths carry pointer, slice and `any`
descriptors and distinguish labelled generic calls from labelled aggregate
construction. Rooted runtime fixtures can consequently compile the actual
repository `core/*` module instead of a copied test implementation. `[0510]`,
Z8 and the guarantee matrix carry the settled contract.

Sources: legacy A2; `[0510]`, Z8.

Exit evidence: `runtime/core-mem-raw-storage` returns 42 only when a
non-zeroable pointer element passes capacity/prefix separation, double-admit,
uninitialized-read, tail-release, empty-dispose and failed/successful
transactional-growth paths. `negative/core-mem-private-representation` pins
the L0202 refusal for direct representation access.

### R3.40 — Implement parser-support core modules

Status: complete
Depends on: R3.30, R2.70, R2.80

`core/mem` now exposes an allocator concept, a caller-backed monotonic arena
and a budgeted failing allocator. Allocation reports `out_of_memory`; the
returned arena handle retains the supplied base's origin; and deterministic
counters pin successful allocation and free calls. This is an ordinary
library allocator over explicitly unsafe backing, not [0820]'s future lexical
arena block.

`core/vec` composes D151's opaque raw storage into an allocator-threaded
`list(item)`. It reserves and grows through an empty replacement, transfers
only initialized values, drains and frees the old allocation before
publication, and leaves the old vector unchanged when allocation fails. The
runtime case uses pointer elements, so the implementation neither assumes a
zero image nor describes spare capacity as values. `core/text` provides the
parser's byte-oriented opaque positions, traversal, checked byte access and
origin-preserving subslices. Full text semantics and the broader vector,
map/tree and iterable surface remain in R4 because the parser needs none of
them here.

This composition also settled the general language seams it exercised:
parameterized aliases may normalize to nominal aggregates; selected calls are
valid statement calls; qualified declarations may appear in error sets; and
reference analysis follows selected calls and retains the origins of array
and slice views across module boundaries. D152 records the boundary and its
deliberate omissions.

Sources: prototype 2; prototype 3; `[0430]`, `[0470]`, `[0510]`, `[0600]`,
`[0770]`, `[0820]`, `[0940]`, `[1350]`, `[1360]`; Z3, Z8, Z9, Z10.

Exit evidence: `runtime/core-mem-allocators` exercises aligned arena
allocation, extent exhaustion and budgeted failure;
`negative/core-arena-frame-escape` pins L0314 for the retained backing origin;
`runtime/core-vec-pointer-storage` exercises successful and failed growth,
pointer values and drain-before-free; `runtime/core-text-byte-positions`
exercises parser byte traversal and subslicing; and the two text negatives pin
the subslice origin and private position representation. The complete pinned
Linux gate passes 389 cases and 9,124 checks.

### R3.50 — Implement the minimum hosted ABI and I/O

Status: complete
Depends on: R1.80, R2.30, R3.10

The first foreign declaration is the bodyless
`extern(c) name: declared_signature`. The checker deliberately admits only
fixed scalar and pointer parameters and zero or one scalar or pointer result;
generic declarations, parameter modes other than `in`, declared errors,
aggregates, variadics and the rest of the C ABI matrix remain R4.40. Lowering
keeps such a declaration as a signature-only neutral-IR routine item, the
verifier recognises its absence of blocks as intentional, and Linux x86-64
emits calls to its source symbol without emitting a definition.

The selected hosted entry captures C `argc`/`argv` before its ordinary
no-argument Landin body. A small compiler-owned bridge exposes arguments after
`argv[0]` and fixed wrappers for read-only `open`, `read`, `write`, `close`,
`strlen` and `errno`. The wrappers use libc rather than direct Linux syscalls:
the existing executable path already links the C runtime, libc supplies the
portable hosted contract this slice needs, and no executable evidence called
for a kernel-specific boundary.

`core/io` builds on that seam as an ordinary library module. Its opaque file
descriptor and public argument view sit below a `world(provider)` concept;
generic `open_read`, `close`, `read`, `write`, stream and argument operations
thread the provider, while `host()` is the single concrete root mint. The
system provider maps `ENOENT`, `EACCES` and other host failures to declared
`not_found`, `no_access` and `io_failed` atoms. The C declaration itself is
infallible: `errno` is interpreted only in the library wrapper where the
world-dependent operation is given its Landin error channel. D153 records the
boundary and the wider designs it leaves open.

Runtime fixture metadata now has `run_args`, distinct from the arguments that
invoke `refine`, so executable evidence can test the hosted argument route.

Exit evidence: `runtime/hosted-io-reads-parser-input` receives one hosted
argument, opens and reads the named parser-input file through `core/io`, writes
`OK` to the diagnostic stream, and returns 42 only after a deliberately
missing path takes a declared recovery edge. The external-boundary fixtures
pin acceptance of the scalar subset and L0301 for an aggregate signature. The
complete pinned Linux gate passes 389 cases and 9,140 checks.

### R3.80 — Ship editor and forge language support

Status: complete
Depends on: R3.50

Make the language immediately usable in the editor families that dominate the
current systems-programming workflow without granting any editor grammar
semantic authority. The existing standard-library-only scanner remains the
single lexical vocabulary for the site and Pygments. Deterministic renderings
now provide a TextMate grammar and VS Code extension, native Vim, Nano and Kate
definitions, a Notepad++ UDL, and the Sublime package; the TextMate extension
is also the importable bundle for JetBrains and Eclipse IDEs and the source
consumed by Visual Studio.

A checked tree-sitter grammar transcribes the enabled kernel, retains nested
comments and contextual words, and ships highlighting, indentation, folds,
locals, brackets and text-object queries. Thin packages make it usable from
Neovim, Helix and Zed. Emacs has a native major mode and selects its structural
mode when the grammar is installed. Each package owns file recognition,
comments and installation instructions rather than exposing only a bare
grammar. The suffix is R3.80 because R3.60 and R3.70 are stable identities;
physical order and the dependency below place this effort immediately after
R3.50 without renumbering them.

Sources: `[1740]`–`[1820]`; `highlight/README.md`.

Exit evidence: the standard-library generator reproduces every lexical
adapter byte for byte; the isolated highlighter fixtures exercise lexical and
structural behaviour without building or invoking `refine`; native Vim and
Neovim smoke tests assert file recognition and real syntax/parser results; the
generated tree-sitter parser also parses every positive, runtime and `core/*`
source without an error node in the optional integration pass; TextMate and
editor manifests parse as JSON, TOML, XML, Vim script, Lua or Emacs Lisp as
applicable; and `check.py` holds the package inventory and generated
renderings to their shared sources.

### R3.60 — Implement diagnostics as runtime dispatch

Status: complete
Depends on: R1.30, R2.80, R3.50, R3.80

Implement the parser's diagnostic capability, bounded and streaming
implementations, and calls through `any` evidence tables.

Exit evidence: two logger implementations receive identical ordered notes;
bounded overflow and hosted I/O failure follow their specified channels.

Delivered: `core/diag.log` is the parser's object-safe diagnostic capability.
Its bounded parameterized provider retains the first N notes, reports later
ones through `dropped`, and records error severity independently of retention.
Its streaming provider writes severity, byte position and message immediately
through `core/io`, propagating a declared `io_failed`. Message slices are
`escaping`, so the bounded provider may retain their backing address without
accepting frame storage. Private bounded and entry representations are reached
through checked accessors.

One producer sends the same sequence through `any diag.log` to both real
evidence tables. That composition required fixed formals to become
per-routine-instance IR constants without gaining ABI positions, and required
aggregate places below pointer `.val` to use the existing runtime-address
storage path. Runtime fixture metadata now has `run_expect`, distinct from
`expect`, so execution checks the logger's exact merged byte stream as well as
its exit status. D154 records the retention, failure, lifetime and dispatch
contract.

The negative `core-diag-frame-message-escape` derivation pins the capability's
retained-message boundary at L0314; the runtime case uses module-backed message
bytes and therefore crosses that same boundary legally. The complete pinned
Linux x86-64 debug and release gates pass 389 cases and 9,146 checks each.

### R3.70 — Complete and run the derived parser program

Status: complete
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

Delivered: `examples/config_parser/lexer` retains every source byte as a
positioned token, and `examples/config_parser/parser` is a complete recursive
descent parser over it. The parser builds a recursive arena-backed variant AST
through `core/vec`, reports syntax mistakes through `any core/diag.log`,
recovers at newline and brace boundaries, and exposes only allocation or
diagnostic-delivery failure from its public operation. R4.10 still owns loops
and full UTF-8 text, so the same scanner, recovery and sequence walks are
spelled recursively over R3's byte-oriented positions.

`runtime/derived-parser` reads its input through the real hosted `core/io`
provider and runs the same parser with bounded and streaming loggers. It keeps
valid nodes around three ordered syntax faults, checks the nested AST, forces a
one-byte arena to report `out_of_memory`, and directs a streaming logger at a
closed descriptor to report `io_failed`. Its `DERIVATION.md` maps the executable
program back to prototype 2 without editing that design record.

That composition closed five general compiler seams rather than adding parser
privileges. A standalone `try` followed by another statement parses as a
statement; a pointer target requests nominal identity without recursively
laying out the target through a generic wrapper; concrete call recovery is
checked even when the call is first visited during initializer inference;
aggregate call/control results use caller-owned temporaries before copies into
nested or indirect places; and module-local symbols are mangled when they
collide with another module or with the backend's private libc dependencies.
D155 records those boundaries. The parser's public lexer operation named
`open` is the executable regression for the last: it cannot interpose on the
host bridge's libc `open` call.

The complete pinned Linux x86-64 debug and release gates pass 389 cases and
9,153 checks each, including the exact three-line merged diagnostic output and
the program's own exit status.

### R3 gate

- A complete hosted parser program executes from a clean checkout.
- The evidence ABI and `any` are semantic foundations; specialization is absent.
- Major editor families recognise and highlight `.ldn` from checked shared artifacts.
- Raw storage came from container pressure and is normative.
- Diagnostics are useful, deterministic and traceable to current codes and
  spans.

## R4 — Complete hosted Linux x86-64 path

R4 closes the hosted language surface on Linux, completes the container and
application workloads, adds usable source debugging and implements only
baseline measured optimization.

### R4.10 — Close the hosted construct matrix

Status: active
Depends on: R3.70

Implement or explicitly amend every remaining hosted normative construct,
including text, literals, patterns, loops, `unchecked`, modules, builtin
directives and hosted entry behavior.

The first increment enables unlabelled `loop` and `while` statements with
unlabelled, valueless `break` and `continue`, including guarded transfers,
backward neutral-IR edges, conservative definite assignment and lexical
`defer` cleanup on iteration transfers. D156 records why no loop opcode was
added. The second increment adds ordinary-name loop labels and targeted
transfers, plus the conditional loop's natural-only `complete` edge. D157
keeps both features as neutral CFG structure. The third
increment adds `break with` and value-producing `loop`/`while` expressions for
scalar, function, pointer and atom results, reusing the existing caller-owned
control join. The fourth increment carries fixed arrays, structs, slices and
`any` through that same destination-aware block-value path, including literal
formation before cleanup. The fifth increment parses the complete `for`
header and enables ascending half-open and inclusive integer ranges, including
one-time bound evaluation, immutable element and `usize` index bindings,
labels, `continue`, natural completion and loop values. D159 keeps this as
ordinary CFG and reserves collection traversal for the next increment. The
sixth increment enables traversal of slices and fixed arrays: the source is
evaluated once, the element is an aliased place in its storage, writable
through `[]mut T` or an assignable array and read-only otherwise, and the
index is the hidden counter. D160 records the alias lowering and keeps
array, slice and `any` elements and iterable-evidence sources as the named
refusal. The seventh increment enables quoted text in a direct read-only
`[]u8` context, including byte escapes, UTF-8 source validation, an uncounted
trailing NUL, content-pooled read-only data and static slice relocations.
D161 keeps `utf8`, `utf16`, `cstring` and codepoint escapes deferred while
giving malformed spelling lexical L0320.

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
Enable import aliases [1430] and selected imports [1440], and preserve
whole-program compilation.

Sources: `[1430]`, `[1440]`, `[1480]`, `[1500]`, `[1530]`, `[1560]`.

Exit evidence: deterministic root and option cases pass; private caches expose
no stable interface.

### R4.40 — Implement the narrow complete C ABI and bindings

Status: planned
Depends on: R2.30, R4.30

Cover `c_int` and related types, `char` signedness, aggregate arguments and
returns, enums, unions, bitfields, varargs, callbacks, thread-local storage,
`errno`, foreign ownership, failure boundaries and calling convention as part
of function identity. Implement `layout(c)` here against that same selected
ABI rather than treating the host Ada representation as authority. R2.30
already passes ordinary Landin arguments on the stack; this item supplies the
C ABI's stack classification, alignment and interoperation rules. Provide
binding generation sufficient to avoid a
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
Implement the explicit `layout(optimal)` field-reordering policy here, where
its size benefit can be measured without changing the source-order default.
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

- Every hosted construct the tour describes is implemented on Linux x86-64.
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

Natively, and that word is load-bearing rather than incidental. R1.80
declined cross-linking Mach-O from the Linux gate and recorded why; the
consequence lands here, because "execute natively on macOS arm64" needs a
macOS host to execute on. R0.70's local macOS loop is what this item
promotes to a gate, and until it does, no Linux run can produce this item's
evidence.

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
construct the tour still describes, record its implementation state,
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

Exit evidence: `spec.md` contains lexical, precedence, statement and expression
grammar for every construct the tour still describes; no matrix contains a gap, stale
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
readiness, change the license or start self-hosting.

Exit evidence: every work item is complete, all transferred scope has a named
successor, and repository authority documents agree on the endpoint.

### R7 gate

- Every construct the amended tour still describes is implemented on every
  applicable target.
- All complete derived prototypes and evidence matrices pass.
- Every durable item has an explicit terminal disposition.
- The result remains pre-v1, unreleased and not self-hosted.

## The concurrency execution model

Legacy B1 and R6.30 own the concurrency *memory* model: races, orderings,
volatile access, interrupt visibility, DMA. They do not own the execution
model. This section records it, because a settled position that is written
nowhere reads as an open question and gets reopened.

Concurrency is not a property of a function. It is a capability — an Io the
caller hands down, an ordinary parameter like an allocator, minted at the
entry point `[1660]` and enforced below it `[1680]`. The same code blocks or
does not depending on the Io it was given, so no keyword, no second calling
convention and no colored function type is needed to say it. The refusal
this replaces is recorded in `tour.md` under WHAT WAS TRIED AND DROPPED.

Three positions follow from that. None of them is a work item here, and none
of them may be satisfied by inventing one.

- **One Io implementation, and it blocks.** Signatures and the `core/*`
  slice are concurrency-capable from the hosted I/O work at R3.50 onward
  without any scheduler existing. Nothing in this roadmap builds a second
  implementation, and nothing in it may assume one.
- **Stackless coroutines are a non-goal.** Cutting functions into state
  machines is a compiler project of its own, and it puts the property into
  every function type that reaches one — the same coloring the ambient
  environment was removed to avoid. This is a refusal, not a park: no
  trigger reopens it, only a decision to reverse it.
- **Stackful fibres are the route to explore, and the backend keeps them
  reachable on purpose.** This one is a direction rather than a park. The
  intended answer to concurrency beyond blocking is a stack switch, not a
  compiler rewrite, and from R1.80 onward a backend decision that forecloses
  switching stacks is a defect in that backend rather than a trade-off.
  The conditions it needs are already held for other reasons: the frame
  pointer is always present, the callee-saved discipline is explicit, and no
  capability rides in a reserved register. The exploration itself belongs to
  the Language evolution successor roadmap. Its trigger is the first derived
  program that needs two things in flight at once; the case to design
  against is a single-core freestanding target, where the honest answer to a
  request for concurrency is that there is none.

## Inherited review register and migration parity

This appendix preserves all 32 legacy backlog entries exactly once. It records
why each exists, its sources and its roadmap owner. Parked and watch entries do
not block phases unless their stated trigger fires. At R7 each row receives a
terminal disposition.

D1–D6 are held positions, each challenged by an outside reader and deliberately
retained. Reopen one only with new evidence that answers its preserved rationale,
and record the reopening explicitly.

| Legacy item | Preserved decision, trigger and sources | Roadmap owner or successor |
| --- | --- | --- |
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
| D2 — No weak conformances or orphan rule yet | Weak conformances let applications silently change generic library behavior. Collisions remain errors; use `distinct` or explicit functions. Ecosystem-scale composition remains the trigger. Sources: `[1280]`, `R§11`. | Implemented in R2.60; reopen only on concrete ecosystem evidence. |
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
