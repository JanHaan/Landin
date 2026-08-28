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
grammar twice over: `check.py` compares its reserved words with the tour's own
`keyword` production and every deferred lexeme with the construct it names,
and the harness lexes all 65 corpus programs and compares each token with
what `check.py`'s independent tokeniser produced.

Invalid escapes are struck from this item's evidence, with the reason
recorded rather than the clause quietly dropped: the kernel's only literals
are integers and the two booleans `[1770]`, and character, text and raw
literals `[0250]` `[0260]` `[0280]` — the only constructs that define an
escape at all — are refused by `[1830]`. No enabled rule reads a byte as an
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
a machine width, so `check.py` holds it to the tour's own `type` rule and to
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
|---|---|---|
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
with the rest of the ABI at R4.40; until then this is a stated limit rather
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
kernel corpus behind it; stack arguments wait for R4.40, `Landin.Checking`'s
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
Status: active
Depends on: R2.10

[1795] and D15 are the first slice: a program may declare a type, and one
declared without [0650]'s `distinct` is another name for the type it was
written from. The kernel has only the scalar names to alias, so
`count: type = u32` is the whole of what it can say — but saying it moved a
boundary that had been in one place since R1.40.

The parser stopped owning the type namespace. A type position used to hold
one of eleven names the parser recognised by interned identity, and anything
else was refused there as "not a type the kernel enables". A program can now
declare one, so the parser builds a name and resolution answers for it: the
grammar's `type` rule became `scalar_name | identifier`, resolution resolves
a type name like any other, and the checker follows a declared one to what it
was declared from. That is the shape the tour already described — [1760]
says the eleven are "ordinary declared names [0120] that the kernel happens
to predeclare" — and the implementation had been reading it the other way.

Two refusals had to move with it, and both are the same lesson. `distinct`
and an inline struct body used to be met while reading a *declaration*, and
are now met while reading a *type*, because that is where they stand. A
third could not move: `u128` and `i128` are refused by the parser on a name
basis, which was sound while the grammar spelled every type and is not now
that `type` derives an identifier. Their negative fixture was removed rather
than weakened — the corpus rule that a frontend refusal must not derive is
right, and the refusal is what is in the wrong stage.

That debt is paid, and paying it found the problem was general rather than
about two names. Every entry in the parser's refused-type table had the same
flaw — `f32` and `utf8` were refused there too, and only escaped notice
because their fixtures carried a float or a text *literal* the scanner
refuses first, so the program stayed underivable for a reason that had
nothing to do with the type. The table moved to
`Landin.Diagnostics.Checking`, which already described exactly this: "the
constructs the tour describes, the kernel omits, and only the checker can
recognise, because recognising one means knowing what a name resolved to."
Resolution now leaves an unresolved *type* name to the checker rather than
reporting the weaker answer first, and the checker names the construct or
says the name is declared nowhere.

The refusals became `L0304`, [1830]'s half that belongs to the checker, and
each type got the fixture it never had: `f32`, `utf8` and `u128` are refused
by name in programs the grammar derives, which is what the corpus rule wanted
all along. The two literal fixtures kept their literals and lost the type
they had been carrying, so each now refuses one thing. `compiler/tests/README.md`
lost an example with them — it cited `float-literal-not-enabled` for why
`codes` is a list and not a set, and that fixture names one code now.

The layout arithmetic came next and before any language change, because it
can be proved without one. `Landin.Targets.Placement` is [0750] and nothing
else: fields keep the order they were written, each begins at its own
alignment rounded up from where the last ended, and the whole rounds up to
the widest alignment any field asked for so that an array of them keeps
every element aligned. `layout(optimal)` and `layout(c)` are the other two
policies [0750] names and arrive with the attributes.

The order is the evidence. `u8 u32 u8` occupies twelve bytes and `u8 u8 u32`
occupies eight, and a layout that reordered fields to save padding would
make both answers the same — which is the sentence [0750] is written to
prevent, so the two orders are a case and both are recorded. The goldens now
carry four worked aggregates per target, where `u8 usize` is sixteen bytes
against Linux x86-64 and eight against the synthetic 32-bit description
while `u64 u8` is sixteen against both: the pointer width moving, and not
the whole model.

[0670]'s block form is declared next, and only declared. `point: type =
struct x: i32 y: i32 end point` parses, its fields are checked, each may name
a type declared elsewhere, and a struct with no fields is refused because a
struct is its fields. What is not enabled is a *value* of one: a binding, a
parameter or a return of a struct type is refused as `L0304`, at the binding
rather than at the declaration, so the report names the thing that cannot be
made rather than the type that can.

That boundary is where the work actually is. Carrying an aggregate needs a
frame cell wider than a register, an ABI rule for passing one, an initialiser
and field access, and each is its own slice. `Landin.Types` grew one literal
for it — `Aggregate`, in `Settled` and outside `Scalar_Name` — and nothing
else changed, which is the point: every place that handles a scalar takes a
`Scalar_Name` and an aggregate reaching one fails a precondition rather than
being quietly mistreated. Which aggregate is not in `Landin.Types` either;
[0710] makes two of them one type when they came from one declaration, so
identity is which declaration wrote it, and that belongs where what every
node has already lives.

That identity now has its side tables in `Landin.Checking`: a struct body and
its declaration carry the declaration's identity, while a direct, chained or
forward alias carries the identity it names. The forward case found that the
resolver had been reading each module declaration's written type while it was
still collecting module names, so a type alias could name only a declaration
above it even though [1840] makes the module a set. Collection and resolution
are separate passes now, just as lowering creates every item before filling
one. A checker case distinguishes two same-shaped declarations and follows the
three alias shapes; the positive struct fixture puts its alias first so the
language-facing path pins the ordering too.

A declared ordinary struct now has the [0750] placement its scalar fields ask
for, recorded beside that identity in `Landin.Checking`; direct and forward
aliases query that same canonical layout. The checker passes the fields in
declaration order to `Landin.Targets.Placement`; it does not put an
aggregate datum into the scalar IR, enable a value, or infer layout from the
host. `Landin.Types.Storage_Size` is the one shared conversion from a scalar to
ordinary unpacked storage, so frame layout and aggregate layout cannot disagree
about `bool` or pointer-width integers. The checker case works `i32 i32 bool`
to offsets 0, 4 and 8, extent 9, alignment 4 and size 12, then checks
`usize bool` as size 16 on Linux x86-64 and 8 on the synthetic 32-bit target. That is the
first source-declared layout and proves both source order and target dependence
through the frontend seam while values remain deliberately refused.

The first value of one follows, and it is the one that needs nothing this
kernel cannot already emit: [1740]'s module state with no initialiser. D10
makes a binding with no value zero and `false` for a `bool`, so its whole
storage is zero and no aggregate has to be constructed, copied, passed or
returned to have it. The checker enables exactly that shape — a module binding,
no value, a declared type name rather than an inline body — and every other
place a struct type could stand is still `L0304`, which the negative fixture
now pins at a local binding instead. An aggregate `Datum` carries its fields'
types in declaration order rather than their offsets, for the reason
`Measure_Size` carries a type: an offset needs a target and `Landin.IR` has
none. The backend lays those fields out with the same `Landin.Targets.Placement`
the checker used and emits `.zero` of the whole size at the aggregate's own
alignment, so `u32 u32 bool` is twelve bytes aligned to four and a `usize`
field widens the state to sixteen on Linux x86-64. A datum's block ends in a
leave that carries no value at all, which the verifier now reads as the
aggregate case rather than as a missing operand.

A local of one came next, and it is the first aggregate to need a frame cell
rather than a data symbol. An IR slot could hold only one of [1790]'s eleven,
so it now holds [0670]'s aggregate too and carries its fields' types the way an
aggregate item does — the types and not the offsets, for the reason
`Measure_Size` carries a type. `Landin.Backend` gives such a cell the whole
[0750] placement its fields ask for and answers where one field sits inside it,
and because a cell grows downward while a struct lays out upward, field 1 is
furthest below the frame pointer and the last field is nearest: `u32 u32 bool`
fills a twelve-byte cell from -12 to -4, so a hexdump of it reads in source
order. A field operation now carries either a datum or a slot, and the verifier
holds both to naming an aggregate that has the field and to the field's own
type.

D16 is the rule that made this possible and it was a decision rather than a
transcription: [1910] tracks the thing an assignment writes, and for a struct
that is the field, so `p.x = 1` assigns `p.x` and nothing else and reading `p.y`
after it is refused and names `p.y`. Every arm of an `if` merges its fields the
way [1910] already merges its names, so a field assigned in one arm and not
another is not assigned after it. The alternatives — treating the binding as
assigned once every field is, or zeroing a struct local where it is declared —
are recorded with it: the first refuses a function that fills two fields of
three and reads only those two, and the second is a store per field at a place
the source does not mention. The flow set grew a column per field to carry it,
which is a declarations-by-fields rectangle and both small and simple to merge.

The boundary moved with it. A struct value is now a module binding or a local,
each without a value; a parameter of one is what `negative/struct-value-not-enabled`
pins now, because carrying an aggregate into or out of a function is an ABI rule
R2.30 owns. Construction, whole-value reads, copies and returns stay refused.

Copying one whole came last of the four, and it is the one expression position a
struct may stand in: `q = p` moves the bytes from one place straight to another,
so nothing has to carry an aggregate anywhere. [0710] decides what agrees —
two structs are one type when one declaration wrote both — so the checker
compares the nominal identities rather than the shapes, and two same-shaped
declarations are refused with `L0301`. It is lowered as a field read and a field
write each, in [0750]'s order, and needs no opcode of its own: a whole-struct
move would say nothing these do not, and either side is module state or a frame
cell without the copy having to know which.

D16 extends to it without a new rule. A copy assigns every field of the place at
once, which is the one way a struct becomes assigned other than a field at a
time, and reading one whole wants every field — so the report names the first
field no path assigned rather than the binding, because that is what a reader
fixes next. The runtime fixture carries the two shapes that look like they might
not work and do: a copy across D15's alias, which is a copy within one type
because an alias keeps the identity, and a copy into the place it came from,
which carries the same bytes to the same bytes and changes nothing.

Zeroed module state is reserved rather than written, which is a defect the
aggregate work introduced and a review of the cost found. D10 makes a binding
with no value zero, and the backend emitted that zero into `.data` — a PROGBITS
section, so every byte of it was a byte of the object and of the image. `.bss`
reserves the same addresses and costs nothing in either. Three 32-byte zeroed
structs and one non-zero scalar measure 116 bytes of `.data` before and 20
after, with the 96 moving to `.bss` and the executable 96 bytes smaller. That
matters at the 32 KB end of the range this compiler is for, where a zeroed
buffer would otherwise be paid for twice, once in flash and once in RAM. A
scalar whose fold reaches zero is reserved too, so what decides is the value and
not the type. Each section is still one run with its directive written once,
written data first.

Reading the whole of one is a value like any other and is refused where the
name stands, which review found accepted: `_ = state` passed the checker, became
a `Load_Datum` of an aggregate, and reached a backend that reads a datum's type
as a scalar. It is `L0304` now, with its own fixture, and the verifier refuses a
datum load or store that names an aggregate as well — the stage that cannot be
wrong about it is the one that checks the IR rather than the one that emits it.

That defect also found one in `check.py`: the token dump recovered each
token's offset by searching the source for its spelling, so a token whose
spelling occurred in a comment above it was recorded at the comment's bytes.
The tokeniser now carries its own offsets. Nothing had noticed because no
fixture had written a word in a comment and then as a token.

Reading a field came next, and it is the first construct the kernel gained
since R1.40 that the grammar did not already spell. [1820]'s `primary` became
a `selection`, `identifier ("." identifier)*`, so the dot is a kernel sign
rather than one [1830] refuses by name — the first of [0420]'s four kinds of
member selection to be enabled, and the only one this kernel can make sense of.
A selection is its own node kind and carries the name it selects, because no
scope [1090] answers for a field: which field it is depends on the type of what
stands to its left, so the resolver walks past it and the checker looks the name
up against the struct body [0750] the identity names. A field the struct was not
declared with is `L0308`, and a selection from anything but a struct is `L0301`.

The IR gained one opcode, `Load_Field`, carrying which field and never where it
sits — an offset needs a target, which is `Measure_Size`'s reason and the reason
an aggregate item carries its fields' types. The backend places those fields with
the same `Landin.Targets.Placement` the checker used and adds the offset to the
datum's own symbol, so `u32 u32 bool` reads at `state`, `state+4` and `state+8`
and the first field needs no displacement at all. The verifier holds a field load
to naming an aggregate, to a field that aggregate has, and to the field's own
type; the builder checks only that what it is handed exists, which is where that
line already sat for a datum load naming a routine.

Enabling the dot found that `check.py`'s tokeniser would have read `1.5` as an
integer, a selection and an integer, which the scanner never produces — it takes
[0210]'s float as one lexeme and refuses it. The tokeniser refuses it too now, so
the dump still agrees with the scanner about the fixture that pins it.

Writing a field completed the pair, and it needed no new rule: [1810]'s `place`
became the same `selection` an expression reads, because a field is written
exactly as the binding holding it is, and what may be written stayed [1900]'s.
So `Check_Place` walks left through however many dots were written and asks
about the binding at the end of them — a field of a binding that is not `mut`
is the same `L0303` the binding itself would be, pointing at the declaration.
`Store_Field` is `Load_Field`'s pair and carries the same field index and no
offset, and `inc state.misses` is what it always was: a load, a one, a trapping
add and a store, now all at the field's own displacement.

Enabling it moved one boundary in the parser that had nothing to do with
fields. [1800] offers an expression body instead of a block, and the parser
decided between them by looking at the token after a leading name: `:` or `:=`
opened a binding and `=` an assignment, and anything else was an expression. A
dot is now part of the name being looked past, because `state.hits = 7` is an
assignment and reading it as an expression made it [0390]'s
assignment-in-an-expression instead. What decides is the token after the whole
selector chain and never the one after the first name: review caught the first
attempt, which read a dot itself as the signal and so turned
`get: () -> (r: u32) = state.hits end get` — a selection standing as [1800]'s
expression body — into a place that had lost its `=`. The statement dispatch
asks the same question, so a place is parsed as a place in both positions.

Definite assignment [1910] was left alone deliberately and says so in code:
writing one field does not assign the binding, so a selection marks nothing, and
the name it selects from is a read because that is where the field is. Nothing
tracked could be a struct at that slice — a local of one was still refused —
so this was the rule written down before D47 made it reachable rather than a
behaviour change at D44.

Arrays begin where structs began: a type a program can declare and lay out,
with a value of one still refused. [1790]'s `type` gained `array_type ::= "["
integer "]" type`, so `[` and `]` left the refused band the way `.` did, and the
bound is [1770]'s integer in whatever base. The element is a type like any
other, so the grammar derives an array of an array on purpose and the checker
refuses the element it cannot yet lay out end to end — the [1830] split again, with the
grammar saying what derives and the checker saying what is enabled.

D17 settles what two arrays being one type means, and it is not [0710]'s rule.
An array is structural: its identity is its length and its element, so `[4]u8`
written twice is one type, and D15's alias keeps that identity like any other.
[0710] is about a struct because a struct body introduces a type where no
existing type was; `[4]u8` introduces nothing, it describes a shape the length
and the element already determine. The alternative — one type per declaration —
would leave a program no way to write the type of something it did not declare,
which `sizeof [4]u8` and a parameter of `[16]u8` both need.

Layout is the element repeated, which needs a target and so is asked with one:
`[4]usize` is thirty-two bytes aligned to eight against Linux x86-64 and sixteen
aligned to four against the synthetic 32-bit description. A length of zero takes
no room and aligns to a byte, which is a case that is written down rather than
one the arithmetic gives: the size falls out of the multiplication, and the
alignment does not, because an empty array has no element to be aligned as. It
is [0580]'s shape one step early — an empty slice still has a base — and the
rule it belongs to arrives with the value slices that can make one.

Whether a program may *write* `[0]u8` is a different question and is not
decided: the checker accepts one today because nothing refuses it, and no
fixture pins that, deliberately. The arithmetic is pinned at the seam instead,
so the answer can be either without the layout moving. It belongs with [0580],
which is about what an empty thing still has rather than whether one may be
written.

Module state came first among the values, as it did for structs and for the
same reason: D10 supplies the value and `.bss` already supplies the storage, so
`mut buffer: [4]u32` needs nothing that does not exist. The extent is one
multiplication rather than a run — an aggregate item carries its fields' types,
but a length reaches four billion, so an array item carries one element and a
count and the backend multiplies. D17 is why an array may be written inline
where a struct may not: `[3]usize` carries its identity wherever it stands,
while an anonymous struct body declares none, so the one is state and the other
is not.

An array local was initially refused, which was then the one place arrays and
structs differed: a struct local had a frame cell and an array's was a later
slice. That refusal had to be written rather than inherited — the module-level
test that D10 needs had been deleted when struct locals were enabled, and
without it an array local was accepted and reached the frame as a defect. The
suite caught it as a status of seventy rather than a silent crash, which is the
report-keeping from the slice before this one doing its job the first time it
was needed. The known-element local slice below has now replaced that refusal.

An element by an index the compiler knows came next, and it is the first
construct to reach [1950]'s table since the shifts. [1820]'s `primary` gained
`indexed ::= selection ("[" expression "]")*`, and [1810]'s `place` is the same
rule, so an element is written where it is read; neither derives from a call or
a parenthesis, because [1820] indexes what a selection named and each of those
is its own production.

[1950] gained a third row. It is not a binary operator and belongs there anyway,
because it is the same question with the same answer: [1720] says this language
checks bounds and [0580] says indexing checks the length before it computes an
address, so what was left unsaid was only which of refusing and trapping applies
where — and the paragraph already decided that for the divisor and the shift.
`a[4]` on a `[4]u8` is refused exactly as `x / 0` is and `a[i]` is left
to the trap. D18 later made an array index exactly `usize`, so a negative
expression is refused by its type before this row applies.

At that point the trap was still the next slice, so an index the compiler could
not work out was named rather than reaching one — including `0 - 1`, which looks
known and is not: [1880] makes a literal and a unary minus over one known and
nothing else, which is the same line D7 drew against believing a condition.

Review found four things wrong with the first attempt, and one of them was the
worst kind. `Check_Place` walked past a field to the binding holding it and did
not walk past an element, so an element of a binding that is not `mut` was
written with no complaint at all — [1900] silently not enforced, where the same
program through a struct field was refused. The same omission left `inc
words[0]` reaching a defect, because the place was never typed. Both are one
line: a place reached through a bracket is a place in the binding at the end of
it, exactly as one reached through a dot is.

The other three: `words[0].x` parsed although [1820] derives no dot after a
bracket, which is the parser and the grammar disagreeing about legal source and
is refused by name now; `-0` was refused as outside the length, which it is not,
since [1880] makes it known and its value is zero; and a part position was a
host `Natural`, so an array of four billion elements — a length this compiler
accepts and reserves — could not be indexed at all. Positions are as wide as
the widest enabled target index now.

The literal exposed the semantic question D18 settles. [0200]'s `i32` default
is for a literal with no context, while an index participates in address
arithmetic and [0160] names `usize` for that job. An untyped index literal
therefore receives `usize` context, and a value already typed `u32` or any
other integer is refused rather than converted implicitly. The fixture with an
index above `i32` now reaches [1950]'s length refusal, while a separate fixture
pins the typed-`u32` mismatch.

The same decision removed the fixed 32-bit array-count ceiling. The internal
count and IR part ranges hold every enabled 64-bit `usize`, while legality is
target-parametric: `length * sizeof element` must fit the target's `usize`,
checked by division before multiplication can overflow. Thus a 2**32-byte
array is accepted by the Linux x86-64 description and refused by the synthetic
32-bit description, independent of the host running the compiler.

The IR needed one idea rather than a new opcode. A field of a struct and an
element of an array are one question to everything downstream — which one, by
position, and what type it is — so `Load_Field` and `Store_Field` carry both and
an item answers `Part_Count` and `Nth_Part` whichever it is. Only the recording
differs, because a struct's fields each have their own type and an array's do
not, and the backend turns a part into an offset by walking the fields or by one
multiplication accordingly. D18 exposed one target limit there: an x86-64
RIP-relative memory operand has only a signed 32-bit displacement. A larger
valid constant offset now materialises the datum address and full offset in
registers; `runtime/large-array-offset-is-addressed` writes and reads byte
2147483647 on Linux, where the symbol-to-instruction distance pushes the
relocation beyond that signed limit, rather than leaving it to the linker.

A computed `usize` index now completes the other half of [1950]'s row for a
module array. Unlike a known position it is a value in the IR, so
`Load_Element` carries that operand and `Store_Element` carries it before the
value to store; the verifier requires the operand to be `usize` and both result
and stored value to be the array's element type. The x86-64 backend compares
index and length as unsigned values, traps with `ud2` unless the index is below
the length, and only beyond that branch scales the index or forms the address,
which makes [0580]'s ordering visible in the instructions rather than merely in
the checker.

Lowering performs the destination's computed index before an assignment's
right-hand side, as [0410] requires. If that value crosses blocks because the
right-hand side short-circuits, a temporary cell carries it to the final store;
otherwise the verifier would rightly reject an operand defined in the earlier
block. `inc words[i]` and its decrement sibling lower that index once, then use
the same IR value for both the element load and the store; evaluating it twice
would turn one source place into two potentially different places once calls
and other effectful index expressions arrive. The former
`computed-index-not-enabled` refusal is consequently replaced by Linux runtime
cases that read and write both ends of an array, carry an index across a
short-circuiting value, and deliberately trap at the length.

A declaration-only fixed-array local now has one compact frame cell and may be
reached through compiler-known indexes. As for module arrays, its slot records
one element type and one target-width length rather than a field per element;
the generic frame layout reserves `length * sizeof element` bytes and derives a
known part's offset by multiplication. Constant local element loads and stores
therefore reuse the slot-targeted `Load_Field` and `Store_Field` operations,
with the verifier accepting either a struct field or an in-range array element.
No opcode or metadata grows with the declared length. The current x86-64
backend still addresses every frame cell with a signed 32-bit `%rbp`
displacement and subtracts the extent in the prologue; `L0504` refuses a
verified routine whose complete lowered frame exceeds that encoding before any
assembly is written. This is an explicit backend limit, not a smaller limit on
D18's array type, and replaces an arithmetic exception or assembler failure.

D19 supplies the source-level state rule: each known element has its own sparse
definite-assignment fact. Writing element zero does not assign element one, a
read or `inc` requires its selected element on every arriving path, and branch
merge intersects the facts. The sparse representation matters because D18
permits an array whose target extent cannot be enumerated by the compiler host.
The Linux runtime case lays out `u32`, `u8`, and `u16` locals together, updates a
known element, and reads an element assigned in both branch arms.

D19 leaves that computed local case for D22 below to answer, once the
whole-array fact D20 records is what a computed read can require. Whole-array
local values and initializers also remain refused here; declaration-only
storage needs neither.

D20 admits the one whole-array value position that can stay between storage
places: `destination = source`. D17 decides agreement from length and element
type, so aliases copy and either mismatch is `L0301`; every other expression
position still meets `L0304`. The source may be module state or a local whose
every element is definitely assigned, and the destination may be either kind
of mutable storage. A copy reads every source element and assigns every
destination element, including exact self-copy once the source was assigned.

The flow state represents that with one whole-array fact beside D19's sparse
element facts. Completeness is either that fact or a count of sparse facts
equal to the declared length — never a walk through the target-sized extent.
Branch merge intersects meanings rather than encodings: whole with sparse
keeps the sparse side, while two whole paths stay whole. The negative cases pin
an untouched local and a copy present on only one branch; the Linux runtime
case makes the other merge arm assign each element independently and exercises
module-to-module, module-to-local, local-to-local, local-to-module, alias, and
self copies.

The IR likewise has one `Copy_Array` instruction with two discriminated storage
references — datum or frame slot — and no operand run proportional to the
length. Its verifier proves both ends are arrays of the same shape and that a
slot belongs to the routine. The x86-64 backend forms the two addresses,
computes the target byte extent, and emits `rep movsb`; the fixed instruction
sequence copies a D18 extent without enumerating it and exact self-copy is the
only overlap current source forms can express.

D21 turns the same `Copy_Array` into a local array's initializer. The
explicitly typed `[mut] name: [N]T = source` checks D17 identity; the inferred
`[mut] name := source` takes the direct storage name's exact D17 length and
element type. Either is lowered exactly as `name = source` once the slot has
been reserved, and the destination is wholly assigned by the copy alone
rather than by subsequent element writes. The source is read before the
local's binding scope begins [0110], so a local cannot initialize itself and
an outer name may be shadowed. Mutable and immutable destinations both accept
the value because a declaration is not an assignment [0080].

The module form admits those same typed and inferred spellings only when
`source` is one direct module storage name of the exact D17 shape. Initial-image
validation follows declaration IDs through forward references and chains,
which must terminate at an omitted-initializer module array; returning to a
visiting declaration reports [1940] once for the cycle. Every terminating
image available now is D10's zero image, but lowering keeps one datum per
declaration and the backend reserves one distinct `.bss` symbol per datum, so
initialization copies bytes rather than aliases storage without introducing
code before [1460]'s entry point. D23 later admits one contextual local array
literal; module and inferred literals, `zeroed`, repetition, slices, calls,
selections, index results, and every other value shape stay refused;
no global array `Name_Reference` value is synthesized and each broader form
remains its own later slice.

D22 answers the question D19 left open and enables a computed index into a
local fixed-array frame slot on the same [1950] terms module arrays met. A
runtime `usize` reads the element only when every arriving path has assigned
the whole array, whether by D20's copy, by D21's initializer, or by D19's
sparse facts filling the declared length; a write establishes no element
fact on its own, and — the useful half of the answer — it preserves an
existing whole-array fact, so a computed write between two reads does not
undo an earlier copy or initializer. The alternatives, treating one write as
a whole assignment or as an unknown range, were declined for the same reason
D19 refused to widen one element write to the whole local: both would admit
uninitialized reads from positions no path assigned.

The IR extends `Load_Element` and `Store_Element` to reach either a datum
or a frame slot, the way `Load_Field` and `Store_Field` already did; no new
opcode is needed and `Reaches_A_Slot` decides. The verifier holds the
slot-reaching form to naming a fixed-array cell of this item, and both
forms still hold the index to `usize` and the value or result to the array's
element type. The x86-64 backend computes the same bounds check and scaling
either way, and then either forms a RIP-relative datum address or reads the
slot's own `%rbp` displacement; the trap and the scaling precede the
address so [0580]'s ordering stays visible in the instructions rather than
being asserted by prose. A positive fixture pins accepting the pair,
`negative/local-array-computed-read-not-whole-assigned` and
`negative/local-array-computed-write-establishes-no-fact` pin the two DA
refusals, and `runtime/local-array-computed-index-reads-and-writes` reads
and writes both ends of a computed local after copying from a module
source, while `runtime/local-array-computed-index-traps` and
`runtime/local-array-computed-store-traps` pin the trap at the length on
both sides of the operation.

The next slice enables [0370]'s `lenof identifier` when that direct name holds
a fixed array. D17 already records the element count on the declaration, so
the checker gives the expression `usize` and lowering emits that count as the
existing Number IR: there is no measurement opcode, target query, or storage
read. In particular, an uninitialized local array may be measured without
satisfying definite assignment. A scalar reaches the ordinary type mismatch,
and a missing name remains resolution's one report. `lenof` stays contextual;
slices, literals, selections and general expression operands remain for later
slices. `positive/lenof-uninitialized-fixed-array`, `negative/lenof-scalar`,
and the migrated `negative/lenof-unresolved-name` pin those boundaries;
`runtime/lenof-named-fixed-arrays` observes the same constant for module and
uninitialized local storage declared through one array alias.

The next slice enables [0370]'s `sizeof` and `alignof` for a fixed-array type,
both inline and through any chain of D15 aliases. The checker dispatches the
resolved checked type rather than the syntax kind: scalars and fixed arrays are
accepted, an unresolved type keeps its one owning report, and a struct remains
`L0304`. Lowering needs no opcode and no target fact of its own. `sizeof`
emits the scalar element's `Measure_Size`, the array length as an existing
`usize` Number, and Multiply; nonempty `alignof` emits the element's
`Measure_Align`. The internally represented zero-element shape keeps zero size
and alignment one without deciding whether `[0]T` is source programmers may
write. `positive/measurement-of-fixed-arrays` pins the inline and alias-chain
forms, and `runtime/measurements-answer-for-the-target` observes nonzero array
answers. D44 later migrates the ordinary scalar-field struct boundary to
positive evidence; the remaining one-report
`negative/measuring-refused-types` pins an unresolved measured type without a
duplicate diagnostic. The focused backend case emits an aliased size and inline
alignment from one source against the 64-bit and synthetic 32-bit target
descriptions.

The next slice is D23's nonempty array literal [0520] in one contextual
position: an explicitly typed local fixed-array initializer. The written D17
shape supplies the exact element count and scalar context; the checker rejects
a shorter or longer source run and checks every element against that scalar.
Lowering evaluates each element left to right and immediately writes its
one-based position into the existing compact array frame slot, so no array
value, temporary, new IR instruction or backend operation is introduced. The
initialized local is whole for D22, which the runtime fixture observes through
a computed index. `positive/local-array-literal-initializer`, the count and
element mismatch fixtures, and
`runtime/local-array-literal-initializes-elements` pin the admitted form;
separate negatives keep module and inferred literals, general assignment, and
[0560]'s repetition outside it. Requiring at least one literal element does not
settle whether `[0]T` is a source type programmers may write.

D24 lifts the same nonempty literal into module scope on the same
written-type terms: `[mut] name: [N]T = [first, ...]` is admitted when
`T` is a scalar and every element folds to a value the type holds.
[1940] already refuses a call and any non-known name reference at
module scope, and the checker now runs its per-element fold against
the element type so `[3]u8 = [200 + 100]` is refused for the same
reason the whole-value fold of a scalar module binding is. A forward
name reference to a scalar module binding is admitted like any other
module scalar image: [1740] makes a module a set, so `a: u32 = 5`
below the array literal is a name the compiler knows when it reads it.
Every [1820] operator [1940] admits is folded target-aware during
checking and again while lowering records the verified image — arithmetic,
wrapping arithmetic at the operand type's own width so `255 +% 1` on u8 is
zero and every unsigned or signed size wraps the same way, comparisons,
logical words with short-circuiting, bitwise set, shifts, complement and the
three measurements. Both syntax walks take widths from the compilation's
target facts; the backend separately folds verified scalar IR. The positive
operator corpus and negative fold-agreement fixtures hold checking to settling
every image or invalid operand before lowering. A member selection, an
element index and a nested array literal are refused by the checker
as D24-excluded constructs so no `arr[0]` or `p.x` at this position
becomes a stage crash during image resolution; each will arrive with
its own slice. The refusal walks each element's whole subtree, so
`source[0] + 1` and `state.x == 3` earn the same refusal a bare
`source[0]` or a bare `state.x` does rather than passing the checker
and defecting during the lowering's fold. The adjacent scalar [1940]
path now refuses the same two storage selections before its backend fold;
neither static aggregate nor array images exist for it to read yet. An arithmetic fold that
walks past the compiler's widest kernel value is now distinguished
from an unfoldable subtree and reported at the element (or, at scalar
module scope, at the binding value) rather than deferred silently and
crashing the backend's own Ty.Folded arithmetic. The IR verifier now
holds every per-position image value to its element type at the
compilation's target facts, so an u8 that holds 300, a bool that
holds 2, or a `usize` that overflows a 32-bit description is a
builder defect that never reaches an object. It also holds image
runs to the same partition rule the other item runs already had —
no run may cross another and no byte of the shared vector may
belong to no item — so a corrupt base or count is caught before
Nth_Image is asked one.
Lowering resolves each element to a `Folded` value and records the
image against the datum in one compact per-item run; the same pass
follows a D21 direct-name chain to the terminal literal or the D10
zero, and every destination on the chain owns distinct storage
initialized with the same terminal image. The IR datum image never
allocates a per-position run for an omitted or zero-target array —
that datum's `Image_Length` is zero and the backend keeps it in
`.bss` — while a nonzero or mixed image reaches `.data` with one
directive per position at the element's own alignment.
`positive/module-array-literal-initializer`,
`positive/module-array-literal-forward-scalar-reference`,
`positive/module-array-literal-1820-operators`,
`negative/module-array-literal-length-mismatch`,
`negative/module-array-literal-element-mismatch`,
`negative/module-array-literal-element-not-known`,
`negative/module-array-literal-element-out-of-range`,
`negative/module-array-literal-index-element`,
`negative/module-array-literal-selection-element`,
`negative/module-array-literal-nested-index`,
`negative/module-array-literal-nested-selection`,
`negative/module-array-literal-fold-overflow`,
`negative/module-scalar-fold-overflow`,
`negative/module-array-fold-agreement`,
`negative/module-scalar-fold-agreement`,
`negative/module-scalar-storage-selection`,
`positive/module-scalar-wrapping-arithmetic`,
`positive/module-array-literal-wrapping-arithmetic`, and
`runtime/module-array-literal-holds-its-image` pin the admitted form
and its refusal boundary; `runtime/module-array-initializers-copy-images`
already exercises the D21 chain that terminates at D10 zero and is
unchanged, and the retired `negative/module-array-literal-not-enabled`
is replaced by the D24 negatives above.

D25 admits [0530] in its first local position: a nonempty literal directly
initializing an inferred local binding supplies D17's finite element count and
takes its scalar element type from the first source expression. An untyped
integer first element receives [0200]'s default `i32`; every later expression
is checked in that one scalar context, so there is no common-type search or
conversion rule. The complete inferred extent is held to D18's target `usize`
before its shape is recorded. The declaration and literal carry the same
compact shape metadata, after which D23's existing lowering evaluates and
stores the source run left to right and marks the local whole. This does not
introduce a general array value or temporary.
`positive/local-array-literal-inferred-length`,
`negative/local-array-literal-inferred-element-mismatch`, and
`runtime/local-array-literal-infers-and-initializes` pin the admitted form.

D26 applies that same inferred shape at module scope, then asks D24's independent
[1940] question of every element. The nonempty source count and first scalar
context settle `[N]T`; each source expression must then be known, fold
Target-aware to a value `T` holds, and become one source-order datum image.
D21's typed and inferred direct-name destinations copy the terminal image into
distinct storage exactly as they do for a written D24 literal. Calls, storage
selections, nested arrays, fold overflow and out-of-range results retain D24's
checker-owned refusals, and no general array value or IR operation is added.
`positive/module-array-literal-inferred-length`,
`negative/module-array-literal-inferred-boundaries`,
`negative/module-array-literal-inferred-fold`, and
`runtime/module-array-literal-infers-static-image` pin the shape, image and
refusal boundary.

D27 enables [0540]'s `zeroed` in one contextual position: an explicitly typed
module fixed-array initializer. The written D17 shape supplies its context and
every scalar element the kernel currently admits has an all-bits-zero image, so
the complete array does too without enumerating its D18 extent. Checker image
validation treats it as a terminal zero image; lowering deliberately records no
finite datum image, preserving D10's `.bss` representation and distinct storage
through D21 chains. It is not synthesized as a general value and introduces no
IR operation, so inferred bindings, assignment and scalar contexts remain
refused. `positive/module-array-zeroed-initializer`, the two focused negative
boundaries, and `runtime/module-array-zeroed-reads-zero` pin the source and
emitted-storage behavior.

D28 gives an explicitly typed local fixed array the same contextual image, but
clears its complete compact frame slot at runtime. Lowering records one
operandless and resultless `Clear_Array` carrying only that slot identity rather
than enumerating D18's target-sized extent or inventing a zero source array. The
verifier resolves the destination through the same storage-shape seam as an
array copy, rejects scalar or unowned storage, and admits no clear in a static
datum image. Linux x86-64 forms the frame address and emits one `rep stosb` over
the target byte extent; focused backend evidence makes `[3]usize` 24 bytes there
and 12 under the synthetic 32-bit description. Existing flow treatment of an
initializer assigns the array as a whole, which a computed-index positive case
pins. `positive/local-array-zeroed-initializer`, the two unchanged negative
boundaries, and `runtime/local-array-zeroed-reads-zero` pin the source, lowering,
target-width and runtime behavior.

D29 admits a nonempty array literal as the contextual value of an assignment to
a mutable fixed-array place. The destination's D17 shape fixes the exact count
and scalar context. After reaching that destination, lowering evaluates and
writes each element in source order, so a later expression observes any earlier
write and a failure can leave the completed prefix changed. This creates no
hidden array-sized temporary and no new IR operation: the finite source run
becomes the existing scalar-expression and field-store pairs against either a
local slot or module datum. Flow checks every source read against the incoming
state and marks the array wholly assigned after normal completion. The focused
lowering case pins both storage kinds; the two positive fixtures distinguish a
runtime module assignment from its static initializer, three negative fixtures
pin shape, type and incoming definite-assignment state, and
`runtime/array-literal-assignment-is-source-ordered` pins computed-index
assignment and observable order.

D30 admits `zeroed` as the other contextual assignment value for a mutable
fixed-array place. It has no source expressions: after reaching the destination,
lowering emits D28's one operandless `Clear_Array` against either a frame slot or
module datum, and flow marks a local destination assigned as a whole. The
verifier's existing storage-shape seam accepts both; Linux x86-64 forms the
appropriate address and clears the target byte extent with one `rep stosb`.
Focused lowering pins both destinations, and focused backend evidence makes a
module `[3]usize` clear 24 bytes under Linux x86-64 and 12 under the synthetic
32-bit facts. `positive/array-zeroed-assignment` pins computed-index definite
assignment, while `runtime/array-zeroed-assignment-clears-storage` proves the
complete local and module effect. D49 later extends that compact operation with
a declaration-order field identity for one contextual array-field clear.

D31 admits [0370]'s parenthesized nonempty array literal as the second `lenof`
operand. Its parentheses preserve `lenof[index]` as indexing when `lenof` is an
ordinary binding, rather than silently making the contextual spelling reserve
that position. D25's first-element rule supplies one scalar shape and checks
every later expression,
but none of those expressions is evaluated, read, folded, lowered or stored: the
source run alone supplies one target-neutral `usize` Number. The same count is a
static module image even when an element is a call, and no object exists to be
limited by D18's maximum extent. The positive fixture pins unassigned local
operands; two negative fixtures pin scalar agreement and reject an aggregate
first element with one type report; and
`runtime/lenof-array-literal-is-compile-time` pins a module count whose calls
must not run while an ordinary array named `lenof` remains indexable. Slices and
every other expression operand remain separate.

D32 admits [0560]'s full-array repetition for an explicitly typed local
initializer and for assignment to a mutable fixed-array place. A written count
must equal the contextual D17 length; in assignment, `[of expression]` takes that
length from the destination. The one scalar expression is checked against the
element type, read from incoming definite-assignment state and evaluated exactly
once. Lowering emits one compact `Fill_Array` with that scalar operand and the frame-slot or
module-datum destination; verification checks both its storage shape and operand
type. Linux x86-64 derives the target element count and width and emits the
matching `rep stosb`, `stosw`, `stosl` or `stosq`, with runtime evidence across
all four enabled widths. The positive and four focused type/flow/context
negatives pin the source boundary, the old repetition refusal now pins only the
mixed-prefix form, and `runtime/array-repetition-evaluates-once` pins one
execution and complete local and module fills.

D33 lets a counted full-array repetition supply an inferred local binding's D17
shape. Its nonzero integer count is the length; its one scalar expression is the
element-type source, with an untyped integer taking [0200]'s default just as
D25's first literal element does. The inferred byte extent is checked against
the target `usize`, then D32's existing checker, definite-assignment walk,
compact `Fill_Array`, verifier and backend paths apply unchanged. A written zero
count remains refused rather than deciding [0580]'s open source-level empty-array
question. The positive fixture pins typed and defaulted scalar inference; three
focused negatives pin target extent, incoming state and zero count; module and
general-value negatives preserve those boundaries; and the existing runtime case
now infers its side-effecting local while proving one evaluation and a complete
fill.

D34 admits either `[N of expression]` or contextual `[of expression]` for an
explicitly typed local or module fixed-array initializer whose written length is
nonzero. It therefore lifts D32's artificial count requirement for a typed local.
A written count must still equal the contextual D17 length. A module expression
uses D24's existing [1940] static scalar boundary and target-aware fold, producing
one pattern rather than a per-position run. IR carries a nonzero repetition as
one folded scalar plus the compact array shape, preserves that representation
through D21 module-name chains, and keeps a zero pattern as the absent image used
for loader-zeroed `.bss`; image resolution, verification and dumping never walk
the extent. Linux x86-64 emits a constant-size `.rept` around one `.byte`,
`.word`, `.long` or `.quad`, preserving all eight bytes without GNU `.fill`'s
four-byte value truncation. The public checker, IR, lowering and backend seams pin
the rule, a target-sized positive fixture pins compact through-chain handling,
focused negatives pin zero context and non-static elements, and the runtime case
reads 1/2/4/8-byte module patterns plus zero and through images. A zero contextual
length is refused by repetition without admitting or rejecting `[0]T` source, so
[0580] remains open.

D35 admits counted nonzero repetition as an inferred module initializer. Its
written count supplies D17's length, its scalar expression supplies the element
type, and [0200] defaults an untyped integer to `i32`; the inferred byte extent
is checked against the selected target's `usize`. Module repetition now shares
one [1940] target-aware fold/range path for D34's typed and D35's inferred forms,
so a non-static, out-of-range or overflowing pattern is refused by the checker
rather than reaching lowering's defect guard. D34's compact repeated image,
through-chain copying, full-width backend directives and absent zero image apply
unchanged. Public checker and lowering cases pin inferred shape and compact
images; a positive fixture pins typed/defaulted inference, through copying and
zero patterns; focused negatives pin staticness, target extent and both typed
and inferred folds; and the runtime fixture reads inferred data, through and
`.bss` images. Zero-count, count-less inferred, mixed-prefix and general-value
forms remain refused.

D36 admits `[e1, ..., ek, of repeated]` only as an explicitly typed local
fixed-array initializer, with `1 <= k < N` for the written destination length
`N`. The checker gives every prefix expression and the repeated expression the
written scalar context while preserving incoming definite-assignment checks.
Lowering evaluates and stores the prefix left to right, evaluates the repeated
expression once, and emits one compact `Fill_Array` for the suffix without an
array temporary. `Fill_Array` now carries a one-based `First` part; all prior
full fills pass `First = 1`, the verifier holds it within the destination, the
dump records it, and Linux x86-64 derives both the byte offset and remaining
element count. The parser's public case pins that `of` remains contextual; public
checker, IR, verifier, lowering and backend cases pin shape, bounds, compactness,
order, offset and count. A positive fixture, six focused context/shape
negatives, and `runtime/mixed-array-repetition-is-source-ordered` pin the source
and executable boundary. Module, inferred, nested and general-value mixed forms
remain refused; assignment is admitted separately by D37.

D37 admits `[e1, ..., ek, of repeated]` as the right-hand side of assignment to
a mutable fixed-array place of type `[N]T`, with `1 <= k < N`. The destination
supplies the shape and scalar context. Its place is reached before every
right-hand expression; lowering then evaluates and immediately stores each
prefix expression left to right before evaluating `repeated` once and reusing
D36's compact `Fill_Array` from `k + 1`. The destination may be a local frame
slot or module datum, and neither path creates a temporary or a new IR, verifier
or backend operation. Definite-assignment checks all right-hand reads against the
incoming state and establishes the whole destination only after successful
completion. Public checker and lowering cases pin contextual shape, both storage
kinds, immediate order, one suffix value, `First` and absence of a hidden slot.
A positive fixture pins both destination kinds and whole-destination assignment;
focused negatives pin mutability, prefix and suffix types, `k < N`, and incoming
state; the Linux x86-64 runtime fixture pins prefix visibility and exactly-once
suffix evaluation for both storage kinds. Typed module initialization remained separate for D38; inferred initialization,
nested and general-value mixed forms remain refused.

D38 admits `[e1, ..., ek, of repeated]` for an explicitly typed module fixed
array `[N]T`, with `1 <= k < N`. Every prefix and suffix expression takes the
written scalar context and must be [1940] static-known under the selected target;
each target-aware fold must fit `T`. Lowering records one compact hybrid image:
the finite prefix followed by one repeated suffix value and the declared shape.
IR, verification, dumping, direct-name image copying and Linux x86-64 emission
never expand `N - k`. A zero suffix remains a present `.data` hybrid and emits a
compact zero directive after its prefix, while D34's full zero repetition remains
an absent image in `.bss`. The backend emits width-matched prefix directives and
then `.rept N - k` around one suffix directive, preserving complete 64-bit
patterns. Public checker, IR, verifier, lowering and backend cases pin the
boundary; a target-sized positive fixture pins compact through-name copying;
focused negatives pin prefix and suffix staticness and target fold range; and the
Linux x86-64 runtime fixture reads every enabled width, a zero suffix, a full
zero image and a through-name hybrid. Inferred initialization, nested and
general-value mixed forms remain refused.

D39 admits `zeroed` as the complete initializer of an explicitly typed module
scalar binding, `[mut] name: T = zeroed`. The written type may be an alias chain
and must resolve to an enabled scalar; it supplies the context that makes the
compile-time-known value false for `bool` and zero for every integer. Lowering
reuses D10's false `Truth` and typed zero `Number`, and the backend consequently
keeps the absent zero image in loader-zeroed `.bss` rather than writing `.data`.
Public checker, lowering and backend cases pin the resolved context, existing IR
and storage selection. A positive fixture covers an alias and both scalar kinds;
focused negatives retain inferred initialization and nested/general contexts;
and the Linux x86-64 runtime fixture reads both values.
No general scalar `zeroed` value was admitted.

D40 admits `zeroed` as the complete initializer of an explicitly typed local
scalar binding, `[mut] name: T = zeroed`. As in D39, the written type may be an
alias chain and must resolve to an enabled scalar; it supplies false for `bool`
and zero for every integer. The ordinary local scalar lowering emits that
existing `Truth` or typed `Number` and its existing frame-slot `Store`, and the
initializer makes the binding definitely assigned before any later read. Public
checker and lowering cases pin the resolved context, assignment state and
constant/store path. A positive fixture covers an alias and both scalar kinds,
and the Linux x86-64 runtime fixture reads both values. Inferred `:= zeroed`,
nested/general contexts and every non-initializer scalar use remain refused; no
general scalar `zeroed` value was admitted.

D41 admits `zeroed` as the complete right-hand side of assignment to a mutable
scalar local slot or module datum. The destination's type may be an alias chain
and must resolve to an enabled scalar; it supplies false for `bool` and zero for
every integer. The ordinary place check and destination-first evaluation remain
in force, so immutable, invalid-place and invalid-type destinations retain their
refusals. Lowering reuses D10's typed `Truth` or `Number` followed by the ordinary
slot `Store` or `Store_Datum`, with no new value, temporary, IR operation or
backend path. Successful completion establishes definite assignment. Public
checker and lowering cases pin both storage kinds, alias resolution, typed
constants, ordinary stores and local assignment state. A positive fixture covers
both destinations, a focused negative retains immutability, and the Linux x86-64
runtime fixture overwrites nonzero integer and true bool values and reads zero and
false back. D42 separately governs scalar field and element subobjects, and D43
separately governs a scalar named return. Inferred initialization, nested/general
contexts and every other scalar `zeroed` use remain refused; no general scalar
value was admitted.

D42 admits `zeroed` as the complete right-hand side of assignment to an ordinary
scalar struct field or fixed-array element selected immediately from a mutable
local slot or module datum. The selected type resolves aliases and supplies false
for `bool` or typed integer zero. The ordinary place check, destination-first
order, exactly-once index evaluation, computed-index bounds check and definite-
assignment effects remain unchanged. Lowering reuses `Store_Field` for a
compiler-known position and `Store_Element` for a computed one, including their
slot-reaching forms, without a new value, temporary, IR operation or backend path.
Public checker and lowering cases pin alias resolution, false/zero selection,
source order and both existing stores. The promoted positive fixture pins module
and local field/element assignment and per-subobject definite assignment; focused
negatives retain direct and subobject immutability, named-return separation,
inference and nested/general refusals. Linux x86-64 runtime fixtures overwrite and
read back both scalar kinds, count one computed index evaluation, and retain the
ordinary out-of-bounds trap. D41 remains the direct-binding rule; nested
subobjects, named returns and general scalar `zeroed` values were not admitted.

D43 admits `zeroed` as the complete right-hand side of assignment to a scalar
named return. Its declared type may be an alias chain and must resolve to an
enabled scalar; it supplies false for `bool` or typed integer zero. The ordinary
place check and assignment flow remain in force, so successful completion marks
the named return assigned for [0930], and explicit or implicit `return` follows
the existing load and `Leave` path. Lowering reuses D10's `Truth` or `Number` and
the named return's ordinary frame-slot `Store`, without new IR or backend work.
Public checker and lowering cases pin alias resolution, definite assignment and
the existing store path. `positive/named-return-zeroed-assignment` covers both
scalar kinds, and `runtime/named-return-zeroed-reads-zero` reads both returned
values on Linux x86-64. D39--D42's contexts are unchanged; invalid destinations,
named-return subobjects, inferred initialization and nested/general uses remain
refused, and no general scalar `zeroed` value was admitted.

D44 admits `sizeof T` and `alignof T` when `T` resolves directly or through
aliases to a named ordinary struct whose fields are all enabled scalars. Lowering
records only those declaration-order scalar field types on the measurement IR;
there are no checker-computed offsets or byte answers. The backend replays the
run through `Landin.Targets` and therefore derives padded size and alignment from
the selected target, including module-scalar folds. The checker evaluates the
same leaf for [1940]'s target-aware validation, and lowering reads the checked
layout when a static module array image needs the concrete answer; ordinary
measurement IR remains target-neutral. The verifier pins `usize` as the result
and the dump exposes the compact run. The lowering and backend public-seam cases
compare direct and aliased shapes and the Linux x86-64 and synthetic 32-bit
answers. `positive/measurement-of-structs`, the one-report
`negative/measuring-refused-types`,
`negative/struct-measurement-fold-overflow`, the recorded IR, and
`runtime/measurements-answer-for-the-target` provide corpus and executable
evidence. Scalar and fixed-array measurements are unchanged; aggregate values,
aggregate fields, nested composition, inline anonymous measurement and `lenof`
structs remain outside this slice.

D45 admits a fixed array of an enabled scalar as one field of a named ordinary
struct for layout and measurement. The field may name an array alias and is
placed once as the compact element/count shape D17 already gives it; an internal
zero-element shape keeps D17's size zero and alignment one without deciding
whether source may spell `[0]T`. The complete padded struct must fit the selected
target's `usize`. If it does not, L0300 owns one report at the struct body, no
layout is recorded, and a later measurement adds no second report. Lowering
carries only a declaration-order scalar or element/count leaf run; the backend
derives every byte answer from its own target facts, while module folds and
static images use the same checked layout as D44. The verifier rejects a
noncanonical scalar measurement leaf and the dump exposes an array leaf as
`[N]element`. Checker and target seam cases pin target-dependent fits, field and
tail padding overflow, exact fits and invalid alignment; lowering and backend
cases pin compactness and 64/32-bit answers.
`positive/measurement-of-struct-array-fields`,
`negative/struct-array-field-layout-overflow`, the reworked one-report
`negative/struct-with-an-array-field`, the recorded IR and
`runtime/measurements-answer-for-the-target` provide corpus and executable
evidence. Runtime values of a struct with an aggregate field, struct fields of
struct type, nested composition, inline anonymous measurement and `lenof`
structs remain outside this slice.

D46 admits a declaration-only module binding whose direct or aliased named
ordinary struct has scalar and fixed-scalar-array fields. D10 supplies the
complete zero image, so the backend reserves the padded target extent without
expanding either fields or elements; scalar siblings remain ordinary readable
and writable fields, including one after an array. Lowering records each datum
field as the same neutral scalar or compact element/count shape D45 established
for measurement, in a separate item run. The verifier holds scalar shapes to
canonical length one and refuses scalar field operations aimed at an array
shape. Backend cases pin 64/32-bit placement and the x86-64 register-formed
address required for a scalar sibling beyond a signed displacement.
`positive/struct-array-field-module-state`,
`negative/struct-array-field-selection-not-enabled`,
the recorded IR and
`runtime/struct-array-field-state-scalar-siblings` provide corpus and executable
evidence. At D46, local storage, initialized module state, whole reads and copies,
parameters, returns and selection of the array field remain refused; D47 below
supersedes the local-storage boundary, D48 indexed access, D54 whole copy and
D55/D56 the explicitly typed or inferred local direct-storage-name initializer.
Struct fields of struct type and broader nested composition are still outside
the laid-out kernel.

D47 admits a declaration-only local binding whose direct or aliased named
ordinary struct has scalar and fixed-scalar-array fields. It is one compact
frame cell and is not implicitly zeroed: D16 still requires every scalar
sibling read to have been assigned on every arriving path. The array field is
inaccessible and carries no D16 fact, so a refused selection produces L0304
without a second whole-struct assignment report. Lowering gives an aggregate
slot the same neutral scalar or element/count field shape D45 and D46 use, in
its own slot run. The verifier holds scalar slot shapes to canonical length one
and rejects scalar field operations aimed at an array slot field before any
scalar accessor is used. The backend replays the shared shape through target
placement; cases pin 64/32-bit frame extents and post-array scalar offsets, the
internal empty-array identity extent, and L0504 ownership when a nested array
field makes an x86-64 frame unaddressable.
`positive/struct-array-field-local-storage`, the one-report
`negative/struct-with-an-array-field`,
`negative/struct-array-field-local-selection-not-enabled`,
`negative/struct-array-field-local-unassigned-scalar`, the recorded IR and
`runtime/struct-array-field-local-scalar-siblings` provide corpus and executable
evidence. Local initialization, whole reads and copies, parameters, returns,
selection of the array field remains refused; D48 below supersedes indexed
access, D54 whole copy and D55/D56 the explicitly typed or inferred direct-
storage-name local initializer. Struct fields of struct type and broader nested
composition are still outside the laid-out kernel.

D48 admits `s.f[i]` when `s` directly names D46 module state or a D47 local and
`f` is a fixed array of enabled scalars. The selection is typed as an array only
as that index base: the field as a whole value, place, copy endpoint or `zeroed`
target remains refused. D18's exact `usize` index, [1950]'s compiler-known bound
refusal, [0580]'s runtime trap and [1900]'s root mutability apply unchanged.
Module state keeps D10's complete image. Local definite-assignment facts are
keyed by binding, field and compiler-known position; a computed local read
requires every position of that field on every arriving path, while a computed
write establishes no fact. Lowering extends the existing element operations
with a declaration-order containing field, zero for direct array storage, and
never carries a target offset. The verifier checks the field exists and is an
array before its shape access. Backends derive the field offset and length from
the selected target; x86-64 traps before address arithmetic, uses a full-width
register offset for module fields and an L0504-bounded displacement for frame
fields. Public IR, verifier, lowering and backend cases pin transport, malformed
fields, target-dependent placement and wide offsets. The promoted module/local
positive fixtures, focused negative fixtures, recorded IR, sibling runtimes and
module/local computed-trap runtimes provide corpus and executable evidence.
Whole array-field values and copies, initialized aggregate storage, parameters,
returns, fields of elements, struct-of-struct fields and nested arrays remain
separate slices; D49 below supersedes the `zeroed` field-assignment boundary
alone.

D49 admits `s.f = zeroed` where `s` directly names D46 module state or a D47
local and `f` is a fixed array of enabled scalars. The selection is typed as an
array only for that complete contextual assignment; at this boundary reads,
copies, non-`zeroed` destinations, operands and nested expressions keep D48's
L0304 boundary, while root immutability still owns L0303. A local clear records
one whole-field fact
keyed by binding and field, so known and computed reads become valid without
assigning a sibling or another array field, and branch merging retains the fact
only from every arriving path. Lowering adds the declaration-order field identity
to `Clear_Array`, leaving copy and fill field-zero-only at this boundary. The
verifier checks the
field exists and has an array shape before reading it. Backends derive the field
extent and offset from target facts; x86-64 register-forms a wide module offset,
uses the bounded frame displacement for a local, and treats an internal empty
field as a zero-byte clear. Public checker, IR, verifier, lowering and backend
cases pin the seams. The positive fixture, contextual and mutability refusals,
the non-copy destination refusal, field/branch definite-assignment negatives,
recorded IR and the two sibling runtimes provide corpus and executable evidence.
Whole field copies, initialized aggregate storage, parameters, returns, fields
of elements, struct-of-struct fields and nested arrays remain separate slices;
D50 below supersedes the copy-endpoint boundary alone.

D50 admits a fixed-array field as either endpoint of D20's contextual whole
copy: field to field and field to or from a direct array name, across module and
local storage, including exact self-copy. The two endpoints must have one D17
shape; destination-root mutability remains [1900]'s first report. A local source
uses D48's sparse facts and D49/D50's binding-and-field whole fact rather than
D16's scalar-field bit, so it must be complete on every arriving path and an
internal zero-length field is vacuously complete. Normal completion records the
destination field whole without affecting a sibling, and merges keep it only
from every path. Lowering carries one declaration-order identity per endpoint
through compact `Copy_Array`, zero for direct array storage. The verifier checks
each positive field exists and has an array shape before comparing shapes.
Backends derive both offsets and the extent from target facts; x86-64
register-forms a D18-wide module field on either side, uses L0504-bounded frame
displacements, and emits one forward byte copy, including a zero-count internal
empty field. Public checker, IR, verifier, lowering and backend cases pin the
seams. The positive fixture, mutability/shape/context/definite-assignment
negatives, recorded IR, and the module/local sibling runtime provide corpus and
executable evidence. Module initializers from a field, general field values,
literals and repetitions into a field, whole copies of the containing struct,
parameters, returns, fields of elements, struct-of-struct fields and nested
arrays remain separate slices; D51 below supersedes the local-initializer
boundary, D52 the literal-destination boundary, D53 the repetition-destination
boundary and D54 the containing-struct-copy boundary.

D51 admits a directly selected fixed-array field as the source of either D21
local initializer spelling. The explicitly typed form requires the written D17
shape to match; the inferred form takes the field's shape. The source is read
before the new name exists and as a whole, so a local field must be complete on
every arriving path through D48's sparse facts or D49/D50's whole fact, while a
module field is complete under D10 and an internal empty field is vacuous.
Lowering reuses compact `Copy_Array`, carrying D50's source-field identity into
the fresh frame slot at field zero; the verifier and backend reuse the existing
checked shape and target-derived address paths. Public checker, lowering and
backend cases pin the seams. Typed/inferred module and local roots, aliases,
source-order shadowing, shape and definite-assignment negatives, the recorded
IR, and an executable independence fixture provide corpus evidence. Module
initializers from a field, general field values, literals and repetitions into
a field, containing-struct copies, parameters, returns, fields of elements,
struct-of-struct fields and nested arrays remain separate slices; D52 and D53
below supersede the literal and repetition destination boundaries, and D54
supersedes the containing-struct-copy boundary.

D52 admits D29's nonempty contextual array literal as the destination value of
a directly selected fixed-array field on D46 module state or a D47 local. The
field supplies the D17 length and scalar element type; [1900] still makes root
mutability the first check. Source expressions are checked against incoming
definite-assignment state, then evaluated and stored left to right, and normal
completion establishes only that binding-and-field whole fact. Lowering reuses
D48's `Store_Element` identity with one constant `usize` index per written
element, leaving D29's direct-array `Store_Field` run unchanged and adding no
IR operation. The verifier and backend reuse the checked field shape and derive
wide module and 32/64-bit local addresses from target facts. Public checker,
lowering and backend cases pin the seams. Context, mutability, incoming-state
and branch negatives, recorded IR, and an executable source-order and sibling-
independence fixture provide corpus evidence. Full and mixed repetition into a
field, module initializers, general field values, containing-struct copies,
parameters, returns, fields of elements, struct-of-struct fields and nested
arrays remain separate slices; D53 below supersedes the repetition boundary
and D54 the containing-struct-copy boundary.

D53 admits D32's full and D37's mixed repetition assignment to a directly
selected fixed-array field on D46 module state or a D47 local. The field
supplies the exact nonzero length and scalar element type; [1900] still makes
root mutability the first check. Source reads use incoming definite-assignment
state. Full repetition evaluates its scalar once; mixed repetition stores its
prefix left to right, evaluates the repeated suffix once, and normal completion
establishes only the binding-and-field whole fact. Lowering gives `Fill_Array`
the declaration-order destination field identity: full fill starts at one,
while mixed prefixes reuse D52's constant-index `Store_Element` sequence and
the suffix fill starts at `k + 1`. Direct D32/D37 operations remain field zero.
The verifier checks an aggregate field exists and is an array before reading
its shape, then reuses the existing start and scalar-type rules. The backend
derives the field address, suffix offset, count and width from target facts;
x86-64 register-forms a D18-wide module field and uses the L0504-bounded 64/32-
bit frame displacement. Public checker, IR, verifier, lowering and backend
cases pin the seams. Count/prefix/type/mutability/incoming-state/branch
negatives, the recorded IR, and an executable once/order/sibling-independence
fixture provide corpus and executable evidence. Initializers from field
repetition, general field values, containing-struct copies, parameters,
returns, fields of elements, struct-of-struct fields and nested arrays remain
separate slices; D54 below supersedes the containing-struct-copy boundary.

D54 admits contextual whole assignment between direct module or declaration-
only local names of one nominal ordinary struct whose fields are enabled
scalars or fixed arrays of enabled scalars. A tracked local source is complete
only when each scalar has D16's field fact and each array field has a
D49/D50/D52/D53 whole fact or a complete D48 sparse element set; module state is complete under
D10, an internal empty field is vacuous, and self-copy cannot launder missing
facts. Normal completion assigns each destination scalar bit and array-field
whole fact independently. Lowering preserves declaration order: scalar fields
reuse `Load_Field`/`Store_Field`, while each array field is one compact D50
`Copy_Array` with the same positive source and destination field identity. The
verifier and backend reuse D50/D53's checked shapes and target-derived
addresses, including a full-width module offset and 64/32-bit frame placement.
The direct source must resolve to storage; the name of a struct type declaration
owns no runtime address and is refused with the existing whole-value report.
Public checker, lowering and backend seams, the positive module/local/alias/
self-copy fixture, mutability/flow/initialization/nominal-identity negatives,
the recorded IR and an executable independence fixture provide evidence.
Initializers, arguments, returns, discards, operands, bare aggregate reads,
struct-of-struct fields, fields of elements and nested arrays remain separate
slices; D55 and D56 below supersede the explicitly typed and inferred local
direct-storage-name initializer boundaries.

D55 admits an explicitly typed mutable or immutable local ordinary-struct
binding initialized from a direct module or earlier local storage name of the
same nominal type, including aliases and both scalar-only and fixed-array-field
layouts. The source uses D54's complete whole-read rule, so every scalar bit and
array-field whole or complete sparse fact must arrive on every path; module
state remains complete, an internal empty field is vacuous, and [0110] makes a
same-spelled source denote an outer binding. Lowering allocates the fresh
aggregate slot and reuses D54's declaration-ordered scalar load/store pairs and
compact D50 array-field copies into it. No new IR or backend invariant is
introduced; public checker, lowering and backend seams pin nominal context,
fresh storage and 64/32-bit field addresses. The positive module/local/alias/
self-shadow fixture, source-completeness, contextual-form and nominal-identity
negatives, the recorded IR and an executable independence fixture provide
evidence. Inferred local initialization remains separate in this slice and is
admitted by D56 only from a direct storage name. All module struct
initializers remain separate in this slice; D59 admits the typed zero image and
D60 the typed direct-name image chain. Non-name values, struct literals, calls,
returns and general aggregate values remain separate slices at D55; D57 later
admits contextual `zeroed` and D64--D68 the contextual labelled-literal forms.

D56 admits a mutable or immutable inferred local ordinary-struct binding from
a direct module or earlier local storage name. The checker carries the source's
nominal body declaration onto the new local before settling it as an aggregate;
this closes the bodyless inferred-aggregate hole without introducing structural
typing or a general aggregate value. D54/D55's complete source read and fresh,
declaration-ordered slot copy apply unchanged, including compact array-field
copies and target-derived 64/32-bit addresses. A type declaration is not
storage and is refused in the D20/D21 array paths and D54--D56 struct paths.
Public checker, lowering and backend seams, module/local/alias/self-shadow and
runtime independence positives, source-completeness negatives, recorded dumps
and explicit type-name refusals provide evidence. Module inference, non-name
initializers, aggregate `zeroed`, static struct images, calls, returns and
general aggregate values remain separate slices in D56; D61 later admits the
direct-name module form by reusing D60's static image chain.

D57 admits `zeroed` as the contextual initializer of an explicitly typed local
ordinary struct. One existing `Clear_Array` instruction with field zero clears
the fresh aggregate slot's complete padded extent; field-zero array and
positive array-field meanings remain unchanged. The verifier admits array or
aggregate whole storage explicitly, and the backend derives 64/32-bit padded
extent and address from target facts, so padding is all bits zero as [0540]
requires. Public checker/lowering/verifier/backend seams, contextual-boundary
negatives, recorded dumps and a runtime field-read fixture provide evidence.
Module images in this slice, inference, assignment in this slice and general
aggregate values remain separate; D58 below admits the whole-place assignment
context and D59 the explicit module zero image.

D58 admits `place = zeroed` when a direct mutable module or local place has an
enabled named ordinary-struct layout. The place supplies the literal's nominal
body, root mutability keeps L0303 first and alone, and the existing whole-write
flow rule marks every scalar and fixed-array field complete for a tracked local.
Lowering reuses D57's one field-zero `Clear_Array` for datum or slot storage;
the verifier's whole-aggregate admission and the backend's target-derived
padded extent now serve both storage classes, while copy and fill remain
array-only. Public checker/lowering/verifier/backend seams, mutability and merge
negatives, recorded dumps and a runtime re-clear fixture provide evidence.
Module initial images in this slice, inference, nested expressions and general
aggregate values remain separate; D59 below admits the typed module zero image.

D59 admits `zeroed` as the static initializer of an explicitly typed mutable or
immutable module ordinary struct, including aliases. The checker reuses D57's
aggregate and nominal-body context; lowering deliberately emits the same
field-shaped, operandless aggregate datum as D10's omitted initializer, with no
runtime clear or finite image. The backend reserves the target-derived padded
extent in `.bss`, so every field and padding byte is zero without making
compiler work proportional to a D18-sized field. Checker, lowering and backend
seams, explicit/inferred and static-name boundary fixtures, recorded dumps and
a runtime distinct-storage fixture provide evidence. Inference, module copies,
nested expressions and general aggregate values remain separate slices; D60
below admits the typed direct-name module image chain.

D60 admits an explicitly typed mutable or immutable module ordinary struct
initialized from a direct module storage name of the same nominal type. Like
D21's array rule, the static image chain follows declaration identities across
aliases and forward references, owns distinct storage at every declaration and
must terminate rather than returning to itself; the latter reports [1940]'s
existing L0305 once. At this slice every terminal image was D10/D59's all-zero
image, so lowering emitted the same compact field-shaped aggregate datum with
no instruction or finite image, and the backend reserved each target-derived
padded extent separately in `.bss` on 64- and 32-bit descriptions. D66 later
adds a declaration-order folded image and copies it through the same chain. A
refused written initializer is not reread for [1940], preserving its owning
report. Checker/lowering/backend seams, forward/alias/nominal/cycle/type-name
fixtures, recorded dumps and a runtime storage-independence fixture provide
evidence. Inferred module initialization, non-name images, nested expressions
and general aggregate values remain separate slices; D61 below admits the
inferred direct-name form and D66 the scalar-labelled nonzero terminal.

D61 admits a mutable or immutable inferred module ordinary struct from a
direct module storage name. The checker reuses D56's nominal-body transfer
before settling the destination and D60's declaration-identity static image
chain afterward. Forward names and aliases therefore preserve one nominal
body; an all-inferred cycle reports [1940]'s L0305 once during settling, while
a mixed typed/inferred cycle settles its bodies and reports once in the image
validator. At this slice every declaration owned a distinct compact aggregate
datum with no instruction or finite image, and each backend reserved its
target-derived padded extent separately in `.bss`; D66 later carries a written
terminal image through the same chain. Checker/lowering/backend seams, typed and
inferred forward chains, pure and mixed cycle ownership, type-name and non-name
refusals, recorded dumps and a runtime independence fixture provide evidence.
Non-name images, nested expressions and general aggregate values remain
separate slices; D66 later admits the scalar-labelled nonzero terminal.

D62 admits `zeroed` as the complete right-hand side of assignment to a scalar
element reached through a D48 fixed-array field on directly named mutable module
or local struct storage. It amends D42's structural place list without making
the array field a whole value: the ordinary place check keeps root mutability,
index typing, compiler-known bounds and destination-first ownership; D48 keeps
exactly-once computed-index traps and per-`(binding, field, position)` definite-
assignment facts. Lowering reuses D42's typed false or integer zero and D48's
field-qualified `Store_Element`, so the verifier, backend, target layout and
module static-image rules are unchanged. Checker/lowering seams, focused
mutability, nesting and sparse-fact fixtures, the recorded dump and a runtime
bounds trap provide evidence. Every deeper scalar place and general `zeroed`
value remains separate. D63 below supplies the named parser refusal and pinned
before-state required before an ordinary-struct literal slice migrates source.

D63 refuses [0710]'s value-position ordinary-struct field image and [0700]'s
call-shaped construction once by name with the frontend's existing L0010 while
both remain outside [1810]'s enabled grammar. The parser recognizes `(` followed
by `identifier :`, an unambiguous contextual `(of expression)`, and a call
whose first argument begins `identifier :`; it skips balanced nested
parentheses or stops at end of input and suppresses a second indexing refusal
during recovery. Ordinary parenthesized expressions, positional calls and
binary expressions over bindings named `of` remain unchanged. No dormant
syntax node, resolution rule, checker value,
lowering operation, verifier invariant, backend layout or diagnostic code is
introduced. Parser public-seam, focused negative and automatic truncation
cases plus regenerated construct and token records provide evidence. D64 below
adds the grammar and real field-labelled node for the nonempty labelled form.
The all-fill and call-shaped spellings remain parser refusals at that point.
D64 later adds the labelled literal node, D66--D71 its target-neutral module
static image, and D72 its nominal construction spelling.

D64 enables [0710]'s nonempty labelled ordinary-struct literal in an explicitly
typed local initializer and as the complete right-hand side of assignment to a
directly named mutable module or local ordinary struct. The contextual nominal
body resolves labels and scalar types; labels are freely ordered but unique,
and a literal without a fill names every field. L0309 owns a duplicate label
and relates it to the first; L0310 owns omitted fields. A trailing `of zeroed`
fills unnamed scalar fields with typed zero/false and clears unnamed fixed-array
fields compactly. Named array fields, general `of expression`, module images,
inference, call-shaped construction, the all-fill spelling and general
aggregate values remain refused in D64; D65 below admits the existing
contextual scalar-zero and fixed-array assignment forms at a label. Named
fields evaluate and commit in source
order, then the fill runs in declaration order; successful assignment records
the existing complete aggregate definite-assignment facts. Parser, checker and
lowering seams, focused diagnostics, positive/runtime fixtures and regenerated
catalogue, construct, token and IR records provide evidence. No new IR,
verifier, backend, layout or static-image invariant is introduced. D66 later
admits the scalar-labelled subset as a module static image.

D65 makes each D64 label the contextual destination of the field it names. A
scalar label accepts D42's typed `zeroed`; a fixed-array label accepts D52's
literal, D53's full or mixed repetition, D49's `zeroed`, and D50's direct or
selected same-shape array source. Each form retains its existing immediate
store, once-then-fill, compact copy or compact clear rule in label source order,
before D64's declaration-order trailing fill. The checker reuses the existing
shape, count, element and incoming-state checks, and lowering reuses the
field-qualified D49--D53 operation family. Focused positive, runtime, mismatch,
source-assignment, immutable-root and nested-value fixtures plus checker and
lowering seams and regenerated token/IR records provide evidence. General
`of expression` remains refused because one node cannot carry several field
types without conversion or re-evaluation; inferred literals wait for
construction, which D72 later supplies; module literals remain outside D65,
and the all-fill synonym and
general aggregate values remain refused. D66 later supplies D60's nonzero
image carrier for scalar labels, D67 its finite-or-zero array-field form, and
D68 its repeated and hybrid field images.
No grammar,
syntax, diagnostic, IR, verifier, backend, target or layout invariant changes.

D66 admits an explicitly typed mutable or immutable module ordinary struct
initialized by D64's nonempty labelled literal when every named field is
scalar and known under [1940]. D64's label, duplicate, missing and `of zeroed`
rules remain; D67 later supersedes the explicit-array-label refusal with a
compact finite-or-zero field image and D68 adds repeated and hybrid forms. IR
records one target-neutral folded entry per
declaration-order field, using zero for unnamed scalar fields and for the
absent image of every array field; verifier checks hold the run to the field
count, array placeholders to zero and scalar folds to the selected target.
The backend derives offsets, widths and padded extent from the existing field
shapes, writes scalar directives and zeroes array fields and every padding gap
in `.data`. Even an all-zero labelled literal is a written image, while omitted
and whole-`zeroed` initializers stay absent `.bss` images. D60/D61 chains copy
the folded terminal into distinct datums. IR/verifier/checker/lowering/backend
seams, focused static-image refusals, regenerated records and a runtime
distinct-storage fixture provide evidence. Inferred literals, labelled array
images beyond D68's finite, zero and repetition forms, heterogeneous fills,
construction and general aggregate values remain separate slices.

D67 admits a labelled fixed-array field in D66's explicitly typed module
struct literal when its value is a nonempty finite array literal of exactly the
field's D17 shape or contextual `zeroed`. Elements keep D24's known-value,
static-subtree, fold and selected-target range owners; zero-length fields admit
only the absent `zeroed` image. D66's flat declaration-order fold run and zero
array placeholders stay intact beside a compact per-field descriptor run and
concatenated finite element folds. The verifier proves descriptor counts,
canonical offsets, field kinds, finite lengths and target fit before access,
and reserves repeated and hybrid forms for D68's producer. The backend emits
finite elements with target-derived widths at D45's placed field offset and
zeroes absent fields and padding; an all-zero finite literal remains written
`.data`. D60/D61 image chains copy descriptors and elements into distinct
datums. IR/verifier/checker/lowering/backend seams, static-image refusals,
generated records and a runtime chain-and-independence fixture provide
evidence. D68 later supplies the repeated and hybrid producers, D69 follows a
direct module-array image, D70 permits an ordinary module array to take a
selected field, and D71 permits a labelled field to take another selected
field. Inferred literals, heterogeneous fills, construction and general
aggregate values remain separate slices.

D68 admits full and mixed-prefix repetition for a fixed-array label in D66's
typed module struct literal. It gives D67's reserved `Repeated` and `Hybrid`
descriptors D34/D38's canonical meanings: a nonzero full pattern occupies no
element run, a zero full pattern becomes `Absent`, and a hybrid carries its
source-order prefix plus one suffix pattern. The checker reuses the existing
count, element, static-subtree, known-value and fold owners. The verifier proves
form-specific counts, offsets and selected-target fit before reading a compact
prefix or pattern; the backend emits target-width prefix directives and one
`.rept` suffix at D45's placed field offset, retaining all padding. D60/D61
chains copy the completed descriptor unchanged. IR/verifier/checker/lowering/
backend seams, focused diagnostics, generated records and the runtime
independence fixture provide evidence. D69 below admits direct array-image
copy, D70 admits selected-field copy into an ordinary module array, and D71
admits the selected-field label. Inferred literals, heterogeneous fills,
construction and general aggregate values remain separate.

D69 admits a direct module fixed-array datum as a fixed-array label in D66's
typed module struct literal when D17's length and element type agree. Image
resolution visits the source first across forward D21 chains, then copies its
absent, finite, repeated or hybrid image into D67's existing field descriptor
at a canonical concatenated-element offset. Each struct and array datum keeps
distinct storage; all-zero finite and hybrid images remain written while an
omitted, explicit-zero or zero-repetition source remains absent. Existing
array-cycle ownership supplies one L0305, D17 owns shape mismatch with L0301,
and a type name, selected field or other source remains L0304 in this slice.
The checker and lowering seams, focused positive and negative fixtures,
generated records and the runtime independence case provide evidence. No IR,
verifier, backend,
target, grammar, syntax or diagnostic representation changes. Selected-field
image copy waits in this slice; D70 below supplies the ordinary module-array
initializer boundary, and D71 then admits the label while keeping inferred
literals, heterogeneous fills, construction and general aggregate values
separate.

D70 admits typed and inferred module fixed arrays initialized from a directly
selected fixed-array field of module ordinary struct storage. The written form
requires D17's exact shape and the inferred form carries it; both copy the
field's resolved absent, finite, repeated or hybrid image into distinct array
storage. Validation and lowering resolve the containing struct first, so
forward aggregate chains and D69-filled fields work, while the new
array-to-struct edge and D69's struct-to-array edge may form a real image cycle.
The existing declaration-state walk reports that cycle once from either
declaration order. Existing array-image setters, verifier rules and backend
emission consume the extracted field descriptor without an IR, verifier,
backend, target, grammar, syntax or diagnostic representation change. Checker
and lowering seams, shape/refused-source/cycle fixtures, generated records and
a runtime independence case provide evidence. A selected field remains a
contextual initializer rather than a general value; D71 gives the same source
one separate struct-literal-label context.

D71 admits a directly selected fixed-array field as a fixed-array label in
D66's explicitly typed module struct literal when D17's length and element
type agree. Validation resolves the containing struct before accepting the
edge; lowering copies its absent, finite, repeated or hybrid descriptor and
re-bases any carried prefix into the destination aggregate's compact element
run. Pure struct-to-struct cycles and cycles mixing D21/D69/D70/D71 retain
[1940]'s one L0305 through the existing declaration-state walk. Each datum
keeps distinct storage, and scalar, indexed, nested and type-root selections
remain refused. Checker and lowering seams, shape/boundary/refused-source and
cycle fixtures, generated records and a runtime independence case provide
evidence. No IR, verifier, backend, target, grammar, syntax or diagnostic
representation changes.

D72 enables [0700]'s call-shaped ordinary-struct construction as a nominally
typed spelling of D64's labelled literal. `T(field: value, ...[, of zeroed])`
is admitted as a typed or inferred local or module initializer and as the
complete right-hand side of whole assignment to directly named mutable struct
storage. A typed destination must share `T`'s [0710] body; an inferred binding
carries that body before settling. The existing D64--D71 field, ordering,
definite-assignment and static-image rules apply unchanged, so construction
writes directly to its contextual destination and introduces no aggregate
temporary or new IR/backend representation. Scalar, function and binding
callees are L0301; positional conversion, the all-`of` form, bare inferred
literals and every general-value use remain refused. Parser, checker and
lowering seams, focused positive/negative fixtures, regenerated records and a
runtime source-order/module-image case provide evidence.

D73 gave [0680]'s contextual ordinary-struct variant part one parser-owned
L0010 and recovery through its matching `end field` closer, while `variant`
remained an ordinary identifier. D74 migrates that boundary into the enabled
grammar and syntax tree: cases are module-visible declaration identities;
scalar/fixed-array payloads and an unfolded source-order tag have one
target-neutral layout; and `sizeof`/`alignof` replay it on both target
descriptions. The tag is first and uses `u8`, `u16` or `u32` according to case
count; each payload uses D44/D45 layout and the part reserves the maximum padded
payload at their maximum alignment. A target-neutral IR carrier transports the
tag and per-case shape runs through the verifier and backend. D75 reuses that
carrier for distinct module datums and aggregate frame slots, makes tag zero
select the first source-order case, and admits only declaration storage plus
typed `zeroed` initialization and whole assignment. Module storage stays one
padded absent image in `.bss`; runtime zeroing is one D57/D58 whole-storage
clear over the same target-derived extent. Parser, resolution, lowering,
verifier and target seams, focused positive/negative fixtures, generated
records and Linux runtime cases provide evidence. D76 adds contextual bare and
labelled case construction for typed local literals, whole assignments and a
directly selected mutable variant part. Selection clears one padded part and
writes its source-order tag before scalar payload fields are evaluated once in
written order; IR, verifier and backend seams plus focused diagnostics and a
Linux runtime case provide evidence. D77 adds exhaustive tag-only matching on
a directly selected module or local variant part. Every source-order case is
named exactly once (L0311 duplicate, L0312 missing); the subject is read once,
arm definite-assignment facts intersect, and payload bytes remain untouched.
One target-neutral `Load_Variant_Tag` is carried through a scalar slot into the
existing comparison/branch IR, while the verifier and backend derive the tag
type and address from D74's shape. Parser, IR, lowering, verifier and backend
seams, focused diagnostics and a Linux runtime case provide evidence. D78 adds
positional scalar payload aliases to those arms: plain names are immutable,
`inout` names update the matched storage directly, and each sibling arm owns
its scope. One target-neutral payload load joins D76's existing payload store;
the verifier and backend derive the scalar leaf and target offset from D74's
shape. Parser, IR, lowering and verifier seams, resolution/checking fixtures,
focused diagnostics and a Linux backend/runtime case provide evidence.
Fixed-array payload aliases remain a separate decision.

D79 admits call-shaped case construction for an inferred local binding. The
constructor supplies D74's nominal body before inference settles the binding,
and the fresh aggregate slot is the contextual destination D76's existing
write sequence needs. No representation changes: checker and lowering seams,
positive and focused negative fixtures, generated records and the Linux
runtime case provide evidence. Inferred module construction remains refused
in this slice; D81 supplies the nonzero static variant image and admits it.

D80 admits contextual whole copy of a variant-bearing struct between direct
runtime storage places, including typed and inferred local direct-name
initializers. Common scalar and fixed-array fields keep D54's operations; one
target-neutral `Copy_Variant` carries the two storage identities and their
shared field identity for the unfolded part. The verifier proves both complete
variant shapes before access, and the backend copies the target-derived padded
part as one byte run on both target descriptions. Definite-assignment,
self-copy and distinct-storage behavior are pinned by focused fixtures, public
seams, generated records and a Linux runtime case. Module initializers remain
static-image rules, which D81 supplies rather than turning into runtime copies.

D81 admits typed and inferred module case construction and copies the resulting
selected-case image through D60/D61 module chains. One target-neutral selected
descriptor points at declaration-order payload descriptors; the verifier proves
their case shapes and target fit before access, and the backend replays D74's
tag, payload placement and zero padding on both target descriptions. Static
fold ownership, forward chains, distinct storage and Linux execution are pinned
by focused fixtures, public seams and generated records. Fixed-array payload
literals/repetitions and fixed-array match aliases remain separate decisions.

What is still refused: whole-array values outside the contextual storage forms.
Initializers admit D21's direct storage name, D23--D28's literal and `zeroed`,
D33--D36/D38's repetitions, and D51/D70's selected field for a local or module
binding;
assignments admit D20's direct storage name, D29/D30/D32/D37's literal,
`zeroed` and repetitions, plus D49/D50/D52/D53's field-qualified forms. Bare
whole-array reads, arguments, returns, discards and operands remain refused.
Within a struct literal D65 admits those runtime array-field destinations and
D67/D68 admit finite, zero, repeated and hybrid module field images, D69 copies
those forms from a direct module array name, and D71 copies them from a directly
selected field. D70 also copies a selected field into an ordinary module array.

Inferred scalar initialization; count-less inferred and general-value full or
mixed repetition [0560]; slices [0570]; and `lenof` operands other than D14's
direct name and D31's literal remain refused. `zeroed` remains contextual: its
enabled sites are D27/D28/D30, D39--D43, D49, D57--D59, D62, D64--D67 and
D75/D76;
named-return subobjects, deeper nested places and every general value use stay
outside those rules.

Struct initialization is contextual too: D55/D56 admit typed and inferred local
direct-name copies; D57 and D59 typed local and module zero images; D60/D61
typed and inferred module image chains; D64/D65 typed local labelled literals
and whole assignments; D66--D71 typed module labelled images; and D72 nominal
construction in typed or inferred local/module initializers and whole
assignments. D76 adds contextual variant-case writes inside those typed local
literal and assignment destinations, and D77 exhaustively matches the tag of
a directly selected variant part. General whole values, bare inferred struct literals,
heterogeneous or all-field fills, positional conversion and construction in a
general expression remain refused. Parameters and returns of any struct type
require R2.30's aggregate ABI. An array field may otherwise be reached
only through D48's indexed elements, D49's contextual clear, D50's copy
endpoints, D51's local initializer source, and D52/D53's literal or repetition
destination. Each remaining boundary is its own slice rather than an implicit
extension of the contextual forms above.

Variant declarations and target-dependent measurements are enabled by D74;
D75 adds module and local storage plus typed initialization and whole
assignment with the complete zero image. D76 admits contextual case
construction in typed local labelled literals and whole assignments, plus
assignment to a directly selected mutable variant part. D77 admits exhaustive
matching of that selected part, and D78 binds scalar payload fields as
arm-local `in`/`inout` aliases. D79 admits inferred local case construction.
D80 admits runtime whole copies and local direct-name initializers. D81 adds
static selected-case images, inferred module construction and module image
chains. General reads of the part, fixed-array payload construction beyond
`zeroed`, and fixed-array payload bindings remain refused. Parameters and
returns retain R2.30's aggregate ABI owner.

[0540] says a type *has* a zero image when all-zero is a valid value for it,
which is what lets D27/D28/D30's surrounding array and D39--D43's scalar be zeroed
at all. Every element this kernel admits is a scalar and every scalar has one, so the check is
vacuous today; it stops being vacuous when a pointer can be an element, because
[0540] gives a pointer no zero image and there is no null to stand for one.

Promoting `[` took away more refusals than the three that are obvious, and a
third review round measured what each one used to do. `sizeof [4]u8` — the very
expression D17 cites as its evidence — went from `L0010` to an internal defect,
because [0370]'s measurement had only ever met one of the eleven and read
anything else as a hole the parser had already reported. A struct with an array
field went from `L0010` to being accepted silently, and then to a defect at the
first value of that struct, because the field loop named an aggregate field and
let every other unlayable field through. At that boundary both were refused by
name again and both had fixtures; the measurement fixture covered a declared
name as well, which had the same hole before arrays existed. The later
measurement slices above migrated first the array and then D44's named ordinary
scalar-field struct refusals to positive evidence. D45 then migrated a fixed
scalar array field to layout and measurement evidence while keeping its runtime
value and every broader aggregate boundary pinned. D46 migrated the containing
declaration-only module storage and its scalar-field operations to executable
evidence while keeping local storage, array-field selection and the whole-value
boundary pinned. D47 migrated the containing declaration-only local storage
and its scalar field operations to executable evidence while keeping initialization,
array-field selection and the whole-value boundary pinned. D48 migrated an
indexed element of that field for both storage classes while keeping the field
itself and every whole-value boundary pinned. D49 migrated the one contextual
whole-field clear while keeping reads, copies, other destinations and every
general-value boundary pinned. D50 migrated contextual whole-field copy
endpoints while keeping initializers, other destinations, containing-struct
copies and every general-value boundary pinned. D51 migrated the local
initializer source in both D21 spellings while keeping module initializers and
every general-value boundary pinned. D52 migrated D29's contextual literal
destination while keeping repetition and every general-value boundary pinned.
D53 migrated D32/D37's contextual repetition destination while keeping
initializers and every general-value boundary pinned. D54 migrated contextual
whole copy of the containing struct while keeping initializers, calls, returns
and every general-value boundary pinned. D55 migrated the explicitly typed
local direct-name struct initializer while keeping inference, module images,
calls, returns and every general-value boundary pinned.
D56 migrated the inferred local direct-storage-name struct initializer while
keeping module images, non-name initializers, calls, returns and every
general-value boundary pinned; its audit also pinned that a type declaration
name is not runtime storage in the D20/D21 and D54--D56 contextual copy paths.
D57 migrated the explicitly typed local struct zero image while keeping module
images, inference, assignment and every general-value boundary pinned.
D58 migrated whole-struct zero assignment for mutable module and local storage
while keeping static images, inference, nested expressions and general values
pinned.
D59 migrated the explicitly typed module struct zero image while keeping
inference, module copies, nested expressions and general values pinned.
D60 migrated the explicitly typed module direct-storage-name struct image
chain while keeping inference, non-name and nonzero static images, nested
expressions and general values pinned.
D61 migrated the inferred module direct-storage-name struct image chain while
keeping non-name and nonzero static images, nested expressions and general
values pinned.
D62 migrated scalar `zeroed` assignment through a D48 fixed-array field element
while keeping every deeper place and general contextual value pinned.
D63 replaced the accidental ordinary-struct literal and call-shaped
construction syntax cascades with one named frontend refusal per construct,
while keeping both spellings outside the enabled grammar for their later
migration slice.
D64 migrated the nonempty labelled spelling to contextual local initialization
and whole assignment while keeping call-shaped construction, the all-fill
spelling, module images, inference and every general aggregate value pinned.
D65 migrated scalar `zeroed` and D49--D53's fixed-array forms into each written
label while keeping heterogeneous fills, module images, inference, construction
and every general aggregate value pinned.
D66 migrated the scalar-labelled typed module struct literal into a
target-neutral static field image while keeping inferred literals, labelled
array-field images, heterogeneous fills, construction and every general
aggregate value pinned.
D67 migrated finite and `zeroed` labelled fixed-array fields into that
target-neutral module struct image, while keeping repetition, image-copy,
inference, heterogeneous fills, construction and every general aggregate
value pinned.
D68 migrated full and mixed repetition labels into D67's compact field-image
carrier, while keeping direct or selected image-copy, inference, heterogeneous
fills, construction and every general aggregate value pinned.
D69 migrated a direct module array image into a labelled fixed-array field,
while keeping selected-field image copy, inference, heterogeneous fills,
construction and every general aggregate value pinned.
D70 migrated a selected fixed-array field into typed and inferred module array
images, while keeping the selected-field label, every general array value,
construction and aggregate inference pinned.
D71 migrated a selected fixed-array field into a typed module struct literal's
label, while keeping scalar, indexed, nested and type-root selections,
inference, construction and every general aggregate value pinned.
D72 migrated call-shaped nominal construction into typed and inferred local or
module initializers and whole assignment, while keeping bare inference,
positional conversion, all-`of`, aggregate temporaries, general values and the
R2.30 struct ABI pinned.
D73 replaced the accidental cascade for [0680]'s contextual variant part with
one parser-owned refusal and recovery through its own closer, while keeping
variant declarations, layout, values, construction and matching outside the
enabled grammar and representation.
D74 migrated that refusal into declaration syntax, module-visible case
identities and a measured tag-first unfolded layout, while keeping every
variant storage and value form, construction and matching pinned for the next
variant slices.
D75 migrated declaration storage and the complete zero image onto that same
target-neutral carrier, while keeping copies, literals, inferred values,
construction, direct part access, matching and payload bindings pinned.
D76 migrated contextual case construction into typed local storage and whole
assignment while keeping static images, inference and general values pinned.
D77 migrated exhaustive tag matching while keeping payload access pinned.
D78 migrated positional scalar payload aliases while keeping fixed-array
payload aliases pinned.
D79 migrated inferred local case construction while keeping module inference
with the static-image boundary.
D80 migrated whole variant-bearing copies and local direct-name initializers
while keeping module copies behind the nonzero static-image boundary.
D81 migrated typed and inferred module case construction plus module image
chains onto a target-neutral selected-case and payload-descriptor carrier,
while keeping general aggregate values and the fixed-array payload extensions
pinned.

Both of those reached a defect, and finding them twice in one afternoon showed
a third thing wrong that was nothing to do with arrays: a defect threw away the
report. `Landin.Driver.Execute` let one escape, so `refine` printed `internal
compiler defect` and exited, and everything the run had already decided about
the source went with it — including, in both cases above, the one sentence a
reader needed. A defect is now an outcome that boundary returns rather than an
exception that leaves it: the report is rendered from what the compilation
holds, the defect is written under it, and `Status_Defect` is sysexits'
EX_SOFTWARE named where the other three statuses already were. The handler in
`refine` stays as the backstop for a defect raised outside that boundary, where
there is nothing to render.

Holding a compiler to that needs a defect to hold it to, and no source can be
relied on to cause one — every one that could is a bug to be fixed, and the two
above were. So the fakes grew `Raise_On_Run` and
`Raise_On_Read`, which is fault injection in the testing library where it
belongs, each arming one defect and clearing itself on the one it fires.

Which of the two a case uses is not a preference. A tool runs only on a
compilation that was not refused, so a defect there can never have a diagnostic
before it; a read happens after the driver has already reported an unknown
option, which is the only place in this driver where a defect meets a report
that already exists. Review found the first attempt at this case proving
nothing — it used an ordinary refused program and no injection at all — and the
case now fails, as it should, when the handler renders the defect without the
report under it.

A third hole was older still and the arrays only added a second way into it: a
struct one of whose fields was refused has no layout, and reading a field that
is fine asked it for one anyway, which reached a precondition rather than a
report — and the defect took the refusal down with it, because a defect
discards what the run had already accumulated. Reading a field of a struct that
has none now answers with the type it cannot have, and the refusal above it
stands as the one report. Two fixtures pin it, one entered through an array
field and one through a struct field, because the second is the shape that
predates this work.

Three more had been refused by the brackets being a lexeme the kernel
omitted, and enabling `[` took that away: review found `[]f32`, `[1, 2]` and
`g[0]` reporting a missing length, a missing expression and a stray token
instead of naming themselves. [1830] promises better than that, so the parser
names each where it now has to tell them apart — a slice by having nothing
between the brackets, a literal by a `[` where a value belongs, and an index by
a `[` at any postfix boundary, which is what `a`, `a.b` and `f()` each are: the
first attempt asked only after a bare name, so an index after a selection or a
call still fell through, and a second review caught it. The second overcorrected: routing a call through the selection loop made `size().x`
derive, where [1820] spells a selection from a name and gives a call its own
production. The index refusal is its own step now, and a fixture pins that
nothing selects from a call. The third round found two positions still missing —
an assignment target and a parenthesised value — so the fixture now writes an
index in all five places one can be written and reads five refusals back. A refused bracketed run is stepped over by nesting so one
report does not become three.

Complete ordinary structs, fixed arrays and the language's default variant
layout, including tags, payload alignment and the spare-bit policy. Use
measured fixtures rather than host Ada representation as authority. D74's
policy is tag-first and unfolded; a future explicit `layout(optimal)` policy
belongs to R4.50, `layout(c)` to R4.40, and packed encodings and layout to
R6.40.

Sources: legacy A3, which had no tracked citation.

Exit evidence: deterministic target-parametric layouts cover scalars, fixed
arrays, ordinary structs and the unfolded default variant representation;
executable cases cover tag width and position, payload alignment, images,
construction and inspection. Source and declared-type provenance remain in the
target-neutral lowering so R4.60 can emit debugger information without
reconstructing it.

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
semantics into `tour.md` and the guarantee matrix.

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
of function identity. Implement `layout(c)` here against that same selected
ABI rather than treating the host Ada representation as authority. Stack
arguments arrive here too: R1.80 emits [1650]'s
six register arguments and refuses a seventh as `L0503` rather than passing
one, so this is the item that has to make that refusal stop being needed. Provide binding generation sufficient to avoid a
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
