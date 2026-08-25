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
today -- so permanent rules were accumulating in a container defined as
temporary, and that section had doubled in two items.

So the documents split. `spec.md` is normative and holds the grammar of the
enabled kernel, which shrinks as the language grows, plus the rules the tour
left unsaid, which do not, plus the register below. `tour.md` explains,
[0010]-[1730]. No construct was renumbered and no id is defined in both.

Seven of the eighteen rules added at R1.50 and R1.60 were decisions rather
than transcriptions, and in the tour's voice a decision is indistinguishable
from a rule that was always there -- which is how [1050], "the condition,
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
Status: complete
Depends on: R1.20, R1.30

Implement hand-written recursive descent and Pratt parsing, explicit recovery
points and a syntax representation that preserves source provenance needed by
semantics and debugging.

`Landin.Syntax` is a flat table of nodes indexed by a dense `Node_Id`, not a
pointer structure, and the reason is the four stages that read it. R1.50 wants
to say which declaration a name resolves to, R1.60 what type an expression
has, R1.70 which IR value a node produced, R4.60 where a node came from --
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

A hole is a node. There are four -- one per band, so a case over a band still
covers the hole instead of falling out of it -- and `Is_Sound` propagates
upward, so R1.60 checks a subtree only when no descendant is a hole and one
missing `then` does not become a cascade of type errors about a hole.

[1820] is a table rather than ten procedures: `Landin.Syntax.Precedence`
transcribes the levels, the operators, the fold and the first sets, and
`check.py`'s `check_precedence_table` compares the transcription with the
grammar it transcribes. That is the whole argument for the shape -- ten
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
itself -- `end loop` closes a loop -- so swallowing its own closer keeps one
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
carries -- `several-independent-errors` carries three, from three separate
mistakes -- and `check.py` refuses a negative fixture that names none, so a
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
first thing to read here.** [0130] and [0140] are two sentences -- order
inside a module does not matter, an inner scope may shadow an outer name --
and neither says which scopes exist, that two declarations of one name in one
scope is an error, or that a name resolving to nothing is one. A rule about an
inner scope means nothing until the inner ones are named, so three constructs
were added to the kernel section: [1840] names the three scopes the grammar
has and says which of them is ordered, [1850] refuses one name declared twice
in one scope, and [1860] refuses a name that names nothing. Each cites the
sentence it comes from. The duplicate rule was already repository policy
before it was specification -- `check.py` has enforced "two declarations of
one name in one module" as a textual invariant since R0, and `README.md`
advertises it -- so [1850] wrote down what the checker already believed. A
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
Ada enforces that for the specification only -- a parent's spec may not `with`
its own child, and a parent's *body* may -- so the rule and not the compiler
is what stops `landin-stages.adb` from building a default pipeline.

A resolution is one array of `Declaration_Id` per compilation, one run per
source, exactly as `Landin.Syntax` lays every node's children end to end.
That is the flat tree's payoff arriving: a reference costs one addition and
one index, with no map and no order that depends on where the host put an
object. Lookup is hashed and never iterated, and the report order is the order
the sources were added and then the order the declarations were written --
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
derive it -- the opposite of what `negative/` used to mean. The stage is read
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
declared in both arms of an `if` -- all accepted. A duplicate in a module, in a
body, between two parameters and between a parameter and the named return; a
name declared nowhere, one from another arm, one after the branch closes, and
one used above its own declaration -- all refused, each with the exact ordered
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
refusal. Nothing said what a call must match, what may be discarded, or --
sharpest of all -- what "the type of its context" in [0190] actually means,
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
be bool" -- it sits indented inside a code example, so a scan anchored at
column 0 does not see it, and the whole grammar section is written that way.
And [1460] states "Values at module level must be known at compile time.
Nothing runs before the entry point", which is [1940]'s source and settles
`k := f()` without any new text. Two drafted rules were struck as a result.

Two rules were narrowed rather than adopted as drafted. [1880] first folded
every all-literal operator before the range check; that would make
`u8 = 200 + 100` a static error, and [0300] says overflow *traps*. So only a
unary minus folds, which is the one case that is forced -- without it
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
compiler -- the same move `Landin.Targets.Byte_Count` already made and states
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
is two mutually recursive halves -- a node is either asked what type it has or
required to have one -- because that second half is the only way a literal
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
a frontend-code fixture *not* to derive and this one does -- which an
adversarial reading caught before it was written.

One defect, found by R1.70's design and fixed under this item's number
because it is this item's rule that was incomplete. `over: u8 = 200 + 100`
was accepted. Inside a body that is right -- [0300] says overflow traps, and
narrowing [1880]'s folding rule to leave it to the trap was correct. At module
level it is wrong, and the reason is the interaction of two rules that are
each correct alone: [1460] says nothing runs before the entry point, so a
module value has no moment in which to trap and no value to stand for it. So
[1940] gained the rule, and a module value's operators are folded and refused
when no type holds the answer. Folding needs a signed value where a literal's
`Magnitude` is unsigned -- `x: i32 = 1 - 2` is negative -- so `Landin.Types`
gained `Folded`, bounded by `u64`'s span and its negation for `Magnitude`'s
reason. The bitwise and shift levels are deliberately not folded: their answer
depends on a width, and a width belongs to a target. Division by zero is not
folded either, for the same reason a module value cannot trap -- and at
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
tree cannot violate and therefore cannot test -- which would make this item's
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
preconditions are structural only -- a wrong-arity call and a mid-block
terminator are buildable on purpose, because a precondition there would make
malformed IR unconstructible and so untestable.

The lowering has landed for routines. `Landin.Stages.Lowering` is a fourth
frontend stage, wired into `refine`, so every positive fixture is lowered by
the fixture suite and `Landin.Tests.Lowering_Suite` reads the Unit back for
five of them. Two passes, and the first is forced rather than tidy: [1740]
makes a module a set, so `f` may call `g` written below it and `Emit_Call`
needs `g`'s item to exist by then -- every item is created over every tree
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
back the other item's -- in debug and in release, with every precondition
satisfied and nothing to notice. `Add_Argument` opens its own run now, and
`Emit_Call` no longer takes a base at creation, which is the same sentence
as the first two fixes. The case that pins it fails against the old body.

A datum's value block has landed with it. A `Binding` gets its item and its
block: the value, or D10's zero where there is none, and a `Leave` carrying
it. Nothing about it is special-cased -- it is `Lower_Expression` over the
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
already forbids -- "every value has exactly one definition" is what a
`Value_Id` *is*, and a test for it could not fail. Nothing that belongs to
someone else -- whether a `Number` fits its type needs a width and a width
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
  item's slots read back as the first's -- caught by `Add_Slot`'s own
  postcondition in debug and silent in release. A run's base is now taken on
  its first append.
- **A block's first value was taken when the block was created.** This
  package's own header says blocks are created out of fill order -- "an
  `if`'s else-entry is created before the then-arm's inner blocks and filled
  after them" -- so every block but the first reported the instructions of
  whichever was filled first. It is taken in `Enter` now, whose precondition
  already says the block is empty.

`Open_Run` is the third thing, and it is a rule rather than a fix: a `Run` is
a base and a count, so an item's entities have to be contiguous, and going
back to an item after starting another silently interleaves two runs. No
precondition said so, so the body says it, in every mode -- the rule
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
whose intermediate never exists at run time -- a verifier that constant
folded a datum in the instruction's own type would refuse it, which is a
trap worth naming here.

Two do not, and each needed something.

- **`k: bool = true and false` has no opcode to lower to.** [0410] makes the
  logical words short-circuit, so `Landin.IR` deliberately has no
  `Logical_And` and no `Logical_Or`. This item first recorded that the
  lowering would fold the logical level inside a datum. That was wrong, and
  the correction is worth keeping rather than quietly replacing. Folding the
  logical level needs the comparison level under it, and
  `k: bool = (1 << 2) < 8 and true` is accepted -- measured, not supposed --
  so it needs the bitwise and shift levels too, and those need a width. That
  is a second constant folder beside the checker's, over the whole of
  [1820], and two authorities on one question is what this compiler refuses
  everywhere else: it is the argument `Landin.IR`'s header makes against
  holding a scope tree, and the one D4 makes against two spellings of one
  type. So a datum gets the blocks a body would, from the same
  `Lower_Short_Circuit`, and no new evaluator exists to disagree with the
  checker. What it costs is that R1.80 reads a datum's block instead of one
  folded constant -- which it had to do regardless, because [1940]'s fold
  stops at the arithmetic level and the header already said the bitwise and
  shift levels arrive as instructions.
- **`later: i32` has no value to describe.** Reading one was accepted too --
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
R5.30's targets for an ordinary over-wide shift -- and a negative amount
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
zero [0320], and x86-64 masks the count instead -- five bits at 32-bit, six
at 64 -- so `1u32 << 40` needs a guard the hardware does not give, on every
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
by construction -- every operand is a memory reference -- and it is the
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

What is emitted so far is the straight-line kernel -- a literal, a truth, a
slot read and written, ordinary and wrapping add, subtract and multiply,
division, remainder, the unary and bitwise operators, both shifts, all six
comparisons, a call, a jump, a branch, a return and a module value --
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
tested against the type's own width, because x86-64 masks the count -- five
bits at 32-bit, six at 64 -- while [0320] fills with zeros beyond it for any
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
callee returning none leaves nothing there to take -- which is [1930]'s rule
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
this host. And the pinned GNAT is already a complete toolchain -- `as`, `ld`
and `gcc` all resolve inside its own `bin/`, ahead of `/usr/bin` -- so the
finishing step needs no new dependency and no second C toolchain. It is the
one pinned toolchain this repository already committed to.

A driver is named, never a linker. The crt startup objects, `-lc` and the
dynamic loader's path live in the compiler driver and differ per
distribution; invoking `ld` directly would move every one of them into this
compiler, where no paragraph could say what they are.

Which driver is a decision, and it is the GNU convention rather than a new
one. Cross tools carry the `--target` argument as a prefix -- GCC's own
internals documentation states it, and the pinned GNAT installs itself as
`x86_64-pc-linux-gnu-gcc` on Linux and `aarch64-apple-darwin24.6.0-gcc` on
the macOS host, both measured. So `Landin.Targets.Capabilities` carries a
triplet and `refine` runs `<triplet>-gcc`. That package and not
`Target_Facts`, because its header already claims exactly this ground --
"the external tools needed to finish a program for that machine" -- while
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
that by vendoring the finishing step -- LLD as a multi-format cross-linker
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
refused, and because Landin does not need it -- macOS arm64's answer is a
macOS runner, not a Mach-O cross-linker, and Xcode on a Mac is exactly what
Apple's agreement contemplates. And building cross toolchains and retaining
the artefacts: declined for three separate reasons, one per target. Cortex-M
needs no build at all, since `arm-none-eabi-gcc` is packaged on both
Homebrew and Debian. A Linux cross toolchain for a macOS host is legally
clean and duplicates work the `messense/macos-cross-toolchains` tap already
does, which is also the role `scripts/env.sh` declines in one sentence --
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
on the hardware -- an arithmetic fold, one that names another, D13's shift
beyond the width, a complement at a byte's width, a negative one, `u64`'s
largest and a comparison -- and then calls a function twice that adds to a
`mut` module binding declared with no value, so D10's zero is where the count
starts from. It also runs four of those expressions a second time as
instructions and compares the two answers, which is the check that matters
for a fold: a shift, a division and a remainder over negative values are
where a folder and a processor can disagree, and one of them was wrong until
that comparison existed.
Three more came out of asking what this item had proved rather than what it
had emitted, and the question was worth asking: every positive fixture emitted
assembly, and emitting is not running. Four of [1810]'s statement forms had
never executed -- `return when`, a bare `return` inside a body, an `elsif`
chain, and `inc`/`dec` -- so a wrong branch edge or a mis-emitted epilogue
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
registers and the rest on the stack, and the stack half is not written -- so a
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
have exposed. [1940]'s cycle rule was implemented in one place only -- the
guard that catches a module value whose *type* is being inferred from itself
-- so `a: i32 = b + 1` beside `b: i32 = a + 1` slipped past it: both write
their types down, nothing is ever Underway, and the checker's own fold walked
the chain to its depth limit and returned quietly. `refine` accepted the
program and said nothing, and the only thing that noticed was this item's
folder meeting the cycle three stages later and raising a compiler defect.
The fold now carries its own guard over the declarations it is standing
inside, and reports [1940]'s refusal naming the declaration the chain came
back to. A chain of three reports three times, once per member, because each
member is separately a value no type holds -- which is the rule
`compiler/tests/README.md` already states about `codes` being a list rather
than a set.

That guard also retired a depth limit that was doing semantic work it should
never have done. The fold stopped at sixty-four links and returned quietly,
which was written when the only thing that could recur forever was a cycle
[1940] was assumed to have reported already. It was accepting two kinds of
program in silence: a cycle longer than the limit, and -- worse, because it
is legal source -- an honest chain longer than it, whose fold was then never
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
some number -- so a trapping fixture could only have been written by freezing
the encoding [1960] declares unstable. `Landin.Platform` now answers how a run
ended as well as what it returned, in two values and not a number: `Exited`
with a status, or `Signaled` with none. No signal number reaches the record,
which is the whole point of the distinction. The decoding is measured rather
than assumed -- the pinned GNAT's own spawn answers -1 for a child killed by
SIGILL and by SIGSEGV and the true status otherwise, and a POSIX exit status is
one byte and so can never be -1 -- and `compiler/tests/README.md` records what
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
purpose -- how a killed process is reported is a fact about the host and the
pinned runtime, and a fake would only repeat what this adapter was told to
believe.

A host that cannot finish the target fails rather than skipping, and that was
a decision with a real alternative. Skipping keeps a macOS run green, and
`compiler/tests/README.md` already refuses it in one sentence -- "A fixture
that records an expectation nobody runs is [a fault]" -- because a green run
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
to infer and no others, so a typed one was accepted in silence -- twice over,
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
Status: planned
Depends on: R1.80

Tie grammar, diagnostics, syntax, checking, IR and native behavior together in
one construct-indexed corpus.

R1.80's audit leaves this item three things to start from, each recorded
where it was found. No positive fixture is executed, only emitted, so the
matrix has to say for each construct whether it was accepted, emitted or run -- those are three different claims and only the third is
evidence about a machine. A runtime fixture names one `program`, so a
multi-file module cannot be expressed as one at all, though the driver
compiles several sources as one module. And a refusal that only a backend can
raise has no home in the negative corpus, because a negative fixture is run
without `--emit`; `L0503` is an end-to-end fixture for that reason.

The first of those is closed. Every positive fixture is now handed to a
backend as well as to a parser: the suite runs `refine --emit=asm` over all
of them and fails on a program that was accepted and could not be emitted,
carrying `refine`'s own report. It is measured rather than assumed -- with
[1650]'s register count temporarily cut to one, the case reports
`positive/call-fills-every-parameter: accepted but not emitted` and names
`L0503` as the reason. What a positive fixture still does not do is run;
that is the runtime class, and the distinction is the one this item's exit
evidence now asks each row to state.

The corpus now says what it is evidence about. A fixture carrying a program
names the constructs it exercises, and `check.py` holds every one of them to a
paragraph `tour.md` or `spec.md` defines while the harness holds it to being
four digits -- each half asked of the side that can answer it. A fixture with
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
a row, against the three claims the corpus can make about it -- accepted,
emitted, executed -- plus whether the parser refuses it by name and cites the
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
four that are not -- [1830], [1850], [1860] and [1910] -- are rules about what
a compiler refuses or checks, which nothing runs. Sixty-one constructs carry
evidence.

The rule that keeps that number worth reading is written into
`compiler/tests/README.md`: name a construct when the fixture's passing would
change if it were implemented wrong, not when it appears in the text. Every
runtime program contains literals, so claiming [1770] everywhere would fill a
column and say nothing. That rule caught one of this pass's own claims --
`runtime/statements-run-as-they-read` was given [1840] while declaring nothing
inside an `if` arm, which is not evidence about arm scopes -- and the fixture
grew a function that declares the same name in both arms rather than the claim
being quietly kept.

Reading the bare rows separated two things that had looked like one. Most of
the 136 were the language the kernel has not reached -- floats, characters,
text, ranges, `sizeof`, pointers, arrays, slices -- and their silence is
correct. But a second group was covered all along and unattributed: a fixture
demonstrating an inferred binding cited [1790], the kernel rule it was written
against, and not [0050], the paragraph that teaches the thing. The tour is
where the language is explained, so a fixture that demonstrates a tour rule is
evidence about it, and thirteen such attributions were added after reading
each paragraph against the program that claims it.

Two rows were neither, and both became fixtures. [0150] names `u128` and
`i128` while [1790]'s type rule does not, and the kernel already refuses one
by name -- `L0101`, rather than reading it as a name that declares nothing --
with nothing pinning that. And [0410] fixes evaluation order, which no fixture
could have observed: every runtime program until now asserted a *value*, and a
value is the same whichever operand ran first. `runtime/evaluation-order-is-left-then-right`
watches it through module state instead, since the kernel has no I/O to watch:
`step(1) + step(2)` leaves a trace reading 12 rather than 21, and the
arguments of one call leave 34 rather than 43. Asserting the reverse exits 1,
which is what makes it evidence rather than decoration.

The matrix reads 76 with evidence and 121 with neither, and what is left in
that 121 is language the kernel does not have.

Exit evidence: positive, negative, verifier and runtime cases all run through
the real driver; the construct matrix has no unexplained kernel row, and each
row says whether the construct was accepted, emitted or executed.

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
of function identity. Stack arguments arrive here too: R1.80 emits [1650]'s
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
