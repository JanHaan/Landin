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
  Hosting remains canonical git.sr.ht. Explicit exact-revision native
  acceptance now owns the Linux gate through `scripts/ci/policy.json` and
  `scripts/ci/controller.py`; R0.70's original SourceHut evidence remains
  historical. SourceHut runs approved-main Pages and GitHub mirroring only.
  The Nix shell is checked explicitly on native Nix when its inputs change;
  that supplemental check is not a required acceptance job.
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
stable IDs such as `R2.30`, spaced in increments of ten so that work found
necessary between two existing items can be inserted with a unit ID such as
`R4.21`, which sits after `R4.20` and before `R4.30`. Work IDs are never
reused or renumbered when work moves. Every work section has exactly one
status and dependency line in this form:

```text
Status: planned
Depends on: R2.10, R2.20
```

Allowed statuses are `planned`, `active`, `blocked` and `complete`. `blocked`
means the work cannot proceed for a reason that is not its own dependencies —
access to a machine, a decision that has not been taken — and the reason is
recorded in one nonempty `Blocked because:` line in that work section.
A completed item requires every declared dependency to be complete.
Dependencies name work IDs only. `none` is the only empty dependency value.
A phase closes only when every work item in it is complete and its phase gate
has reproducible evidence. Exploration may run early when dependencies allow,
but phases are claimed in order. Between active items, the published next item is the first dependency-ready
planned item in roadmap order; several ready items do not start work implicitly.
There are no dates, estimates or release versions in this roadmap.

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

The R4.70 integration subsequently migrates current acceptance authority to
explicit committed-revision native runs. `scripts/ci/policy.json` retains the
complete eight-job matrix; source/tree/policy and retained evidence hashes
bind an annotated administrative `ci/accepted/FULL_COMMIT` approval. Maintainer
Git write access is the trust root. The controller exports a verified durable
copy before approval and atomically promotes approval plus fast-forward main.
SourceHut retains only Pages and mirror; both automatic and manual publication
require the shared canonical approval guard. Failed/partial runs never approve,
and approved evidence has no automatic expiry. Deployment, recovery and
supplemental Nix commands are in `environments/native-ci/README.md`. Original
R0.70 environment results above remain historical evidence.

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
spelling at this lexical seam. D163's ninth increment likewise enables one
decoded `u32` character and gives malformed character spelling L0322. D164's
tenth enables raw byte text with matching quote runs and indentation stripping.
D181's later R4.10 increment supplies the remaining text contexts.

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
whose answer no `u8` holds. The arbitrary sixty-four-link cutoff was removed.
The cycle guard prevents dependency cycles; the parser bounds syntax nesting
only. Dependencies across separate declarations still consume host resources
and are not bounded by that syntax limit. R4.91's readiness intake below
records the measured repairs and remaining resource limitations.

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
emitted, executed — plus whether the parser or checker refuses it by name and
cites the paragraph, which is what explains a row for a construct the kernel
does not enable.

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

Historical source witness: `c3facac53b6e174e73103ddba9353d5f96669615`
is the retained R1.90 closure record and an ancestor of the R4.91 review base.
At that revision, the generated construct matrix attributes 82 covered rows;
`runtime/constant-return-exits-with-its-code`,
`runtime/calls-return-through-the-abi` and
`runtime/evaluation-order-is-left-then-right` retain native result oracles.
The grammar and diagnostic corpus are in that same source tree. This identifies
replayable source, not a recovered native run bundle. R4.91 M6 records the
remaining historical evidence gap and the rewrite mapping.

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
Loops and their `break`/`continue` transfers were R4.10's, which has since
enabled them; while they were deferred their syntactic refusals named that
item rather than this one, and no refusal table names it now. The first
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
the forty-ninth increment supplies that spelling and every loop transfer was
R4.10's.

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
unwind-specific form. Loops and their transfers were R4.10's.

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
part of `inout` exclusivity exact without claiming alias analysis. The four
D148 source registers cover guarantee boundaries, conformance/evidence
mechanisms, prototype derivations and target applicability;
`check.py --coverage` generates their reading matrices and fails on stale rows, unknown
constructs, decisions, findings, fixtures or targets. Every fixture now names
its applicable targets. R4.10's later construct applicability register is
checked directly against the generated construct matrix and roadmap owners.

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
| `runtime/derived-containers` | P3 | Z1, Z2, Z3, Z4, Z5, Z6, Z7, Z8, Z9, Z10, Z11, Z12, Z13, Z14, Z15, Z16, Z17, Z18, Z19 | the complete client composes initialized containers, explicit and failing providers, sorting, tree and heterogeneous evidence; its derivation manifest distinguishes executable resolutions from preserved no-gap or superseded sketches |
| `negative/r470-container-entry-live-map` | P3 | Z5, Z16 | a pointer-bearing enumerated entry keeps its map live across insertion and release |
| `negative/r470-container-entry-wrong-from` | P3 | Z5 | entry extraction retains the exact map origin |
| `negative/r470-container-missing-order-evidence` | P3 | Z2 | a constrained generic application call requires its concrete ordering conformance |
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
| `runtime/allocator-vec-pressure` | P3 | Z6 | an escaping generic value parameter is vacuous for a scalar item and exact for a pointer item |
| `negative/parameterized-conformance-entry-signature-mismatch` | P3 | Z1, Z4 | substituted provider signatures must agree |
| `runtime/derived-hosted-memory` | P4 | W1, W2, W3, W4, W5, W6, W7 | the complete log-filter application selects filters and destinations from retained arguments, reads whole lines across arbitrary chunks, buffers messages with explicit retry, and closes handles through the supplied world |
| `runtime/r480-arena-independent-results` | P4 | W7 | simultaneous ordinary allocations and helper-returned pointers, aggregates, slices, any and callback state remain independent; a helper-retained pointer survives the provider frame without passing a returned-value boundary |
| `runtime/r480-arena-nested-exhaustion` | P4 | W3, W7 | explicitly backed nested providers exhaust independently and ordinary defer runs across normal, failure, return, break and continue exits |
| `negative/r480-callback-frame-escape` | P4 | W6, W7 | ordinary callback-state aggregates retain the tracked frame escape refusal |
| `negative/r480-helper-frame-retention` | P4 | W7 | a helper still cannot retain a tracked nonescaping frame reference in module storage |
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

#### Construct applicability coverage

This register assigns every normative construct to the first target slice that
must account for it. `hosted-now` is the R4.10 closure set: each such row must
have corpus evidence or a named refusal, and R4.10 cannot close while one of
its own named refusals remains. R4.90 tightens closure to a Linux runtime or ABI
program oracle for every hosted row, except the explicitly audited compile-time
rules in its register. Refusal alone cannot demonstrate an implemented operation. The other classes are scheduled later in R4,
belong to the freestanding path, are explicitly deferred, or state a principle
that has no implementation owner.

| Construct | Applicability | Owner | Disposition |
| --- | --- | --- | --- |
| `[0010]` | hosted-now | R1.20 | matrix evidence |
| `[0020]` | hosted-now | R1.20 | matrix evidence |
| `[0030]` | hosted-now | R1.20 | matrix evidence |
| `[0040]` | hosted-now | R1.50 | matrix evidence |
| `[0050]` | hosted-now | R1.50 | matrix evidence |
| `[0060]` | hosted-now | R1.50 | matrix evidence |
| `[0070]` | hosted-now | R2.50 | matrix evidence |
| `[0080]` | hosted-now | R1.50 | matrix evidence |
| `[0090]` | hosted-now | R3.10 | matrix evidence |
| `[0100]` | hosted-now | R1.50 | matrix evidence for atom name lists; shared ordinary declaration names remain named refusals owned by R7.20 |
| `[0110]` | hosted-now | R1.50 | matrix evidence |
| `[0120]` | hosted-now | R2.20 | matrix evidence and named refusal |
| `[0130]` | hosted-now | R1.50 | matrix evidence |
| `[0140]` | hosted-now | R1.50 | matrix evidence |
| `[0150]` | hosted-now | R4.10 | matrix evidence for the enabled widths; u128 and i128 are named refusals owned by R7.20; the arbitrary field widths this construct hands to [0730] are no spelling [1790] admits and are that freestanding row's work |
| `[0160]` | hosted-now | R2.10 | matrix evidence |
| `[0170]` | hosted-now | R4.10 | matrix evidence for f32 and f64; f16 is a named refusal owned by R7.20 |
| `[0180]` | hosted-now | R1.60 | matrix evidence |
| `[0190]` | hosted-now | R1.60 | matrix evidence |
| `[0200]` | hosted-now | R1.60 | matrix evidence |
| `[0210]` | hosted-now | R4.10 | matrix evidence |
| `[0220]` | hosted-now | R4.10 | matrix evidence |
| `[0230]` | hosted-now | R4.10 | matrix evidence |
| `[0240]` | hosted-now | R4.10 | matrix evidence |
| `[0250]` | hosted-now | R4.10 | matrix evidence |
| `[0260]` | hosted-now | R4.10 | matrix evidence |
| `[0270]` | hosted-now | R4.10 | matrix evidence |
| `[0280]` | hosted-now | R4.10 | matrix evidence |
| `[0290]` | hosted-now | R1.60 | matrix evidence |
| `[0300]` | hosted-now | R1.60 | matrix evidence |
| `[0310]` | hosted-now | R1.60 | matrix evidence |
| `[0320]` | hosted-now | R1.60 | matrix evidence |
| `[0330]` | hosted-now | R1.60 | matrix evidence |
| `[0340]` | hosted-now | R1.60 | matrix evidence |
| `[0350]` | hosted-now | R1.60 | matrix evidence |
| `[0360]` | hosted-now | R1.60 | matrix evidence |
| `[0370]` | hosted-now | R2.10 | matrix evidence |
| `[0380]` | hosted-now | R2.50 | implemented; fixture attribution in this increment |
| `[0390]` | hosted-now | R1.60 | matrix evidence |
| `[0400]` | hosted-now | R1.60 | matrix evidence |
| `[0410]` | hosted-now | R1.60 | matrix evidence |
| `[0420]` | hosted-now | R1.60 | matrix evidence |
| `[0430]` | hosted-now | R2.50 | matrix evidence |
| `[0440]` | hosted-now | R2.50 | matrix evidence |
| `[0450]` | hosted-now | R2.50 | matrix evidence |
| `[0460]` | hosted-now | R2.50 | matrix evidence |
| `[0470]` | hosted-now | R2.50 | matrix evidence |
| `[0480]` | hosted-now | R4.10 | matrix evidence and named refusal |
| `[0490]` | principle | none | system-tool policy; no implementation claim |
| `[0500]` | hosted-now | R4.20 | D196 records `offset` and `base_of` as unneeded; D151 rejects `slice_from`; ordinary address conversion remains the implementation |
| `[0510]` | hosted-now | R3.30 | matrix evidence |
| `[0520]` | hosted-now | R2.20 | matrix evidence and named refusal |
| `[0530]` | hosted-now | R2.20 | matrix evidence |
| `[0540]` | hosted-now | R2.20 | matrix evidence and named refusal |
| `[0550]` | hosted-now | R2.60 | matrix evidence |
| `[0560]` | hosted-now | R2.20 | matrix evidence and named refusal |
| `[0570]` | hosted-now | R2.20 | matrix evidence and named refusal |
| `[0580]` | hosted-now | R2.20 | matrix evidence |
| `[0590]` | hosted-now | R4.50 | D209 and matrix evidence |
| `[0600]` | hosted-now | R4.10 | matrix evidence |
| `[0610]` | hosted-now | R4.10 | matrix evidence |
| `[0620]` | deferred | R7.20 | explicitly deferred structure-of-arrays design |
| `[0630]` | hosted-now | R2.20 | matrix evidence |
| `[0640]` | hosted-now | R2.20 | matrix evidence |
| `[0650]` | hosted-now | R2.20 | named refusal |
| `[0660]` | hosted-now | R4.10 | matrix evidence and named refusal |
| `[0670]` | hosted-now | R2.20 | matrix evidence and named refusal |
| `[0680]` | hosted-now | R2.20 | matrix evidence and named refusal |
| `[0690]` | hosted-now | R2.20 | matrix evidence |
| `[0700]` | hosted-now | R2.20 | matrix evidence |
| `[0710]` | hosted-now | R2.20 | matrix evidence |
| `[0720]` | hosted-now | R2.20 | matrix evidence and named refusal |
| `[0730]` | freestanding | R6.80 | scheduled device-register work |
| `[0740]` | freestanding | R6.80 | scheduled device-register work |
| `[0750]` | hosted-now | R2.20 | matrix evidence |
| `[0760]` | freestanding | R6.80 | scheduled generated-device attribute work |
| `[0770]` | hosted-now | R2.50 | matrix evidence |
| `[0780]` | hosted-now | R2.50 | matrix evidence |
| `[0790]` | hosted-now | R2.50 | matrix evidence |
| `[0800]` | hosted-now | R2.50 | matrix evidence |
| `[0810]` | hosted-now | R4.20 | D196 states [0470]'s actual derivation cut; the `pointer.integer-origin` evidence pins its non-guarantee |
| `[0820]` | hosted-now | R4.80 | D212 withdraws the lexical block and builtin parameter type; explicit ordinary allocator authority, capacity and cleanup replace the unsupported transitive escape promise |
| `[0830]` | hosted-now | R2.50 | matrix evidence |
| `[0840]` | hosted-now | R2.50 | matrix evidence |
| `[0850]` | freestanding | R6.80 | scheduled volatile-access work |
| `[0860]` | hosted-now | R2.50 | matrix evidence |
| `[0870]` | hosted-now | R2.30 | matrix evidence |
| `[0880]` | hosted-now | R2.30 | matrix evidence |
| `[0890]` | hosted-now | R2.30 | `none` has matrix evidence; `noreturn` has a named refusal owned by R6.70 |
| `[0900]` | hosted-now | R2.50 | matrix evidence |
| `[0910]` | hosted-now | R2.50 | matrix evidence |
| `[0920]` | hosted-now | R2.30 | matrix evidence |
| `[0930]` | hosted-now | R2.30 | matrix evidence |
| `[0940]` | hosted-now | R2.30 | matrix evidence |
| `[0950]` | hosted-now | R2.30 | matrix evidence |
| `[0960]` | hosted-now | R2.30 | matrix evidence |
| `[0970]` | hosted-now | R2.30 | matrix evidence |
| `[0980]` | hosted-now | R2.30 | matrix evidence |
| `[0990]` | hosted-now | R2.30 | matrix evidence |
| `[1000]` | hosted-now | R2.30 | matrix evidence |
| `[1010]` | hosted-now | R2.30 | matrix evidence |
| `[1020]` | hosted-now | R2.30 | matrix evidence |
| `[1030]` | hosted-now | R2.30 | matrix evidence |
| `[1040]` | hosted-now | R4.10 | D192 and matrix evidence |
| `[1050]` | hosted-now | R2.30 | matrix evidence |
| `[1060]` | hosted-now | R2.30 | matrix evidence |
| `[1070]` | hosted-now | R4.10 | D185 and matrix evidence |
| `[1080]` | hosted-now | R2.30 | matrix evidence |
| `[1090]` | hosted-now | R2.30 | unlabelled begin/end blocks; labelled blocks are outside [1810] |
| `[1100]` | hosted-now | R2.30 | matrix evidence |
| `[1110]` | hosted-now | R2.30 | matrix evidence |
| `[1120]` | hosted-now | R4.10 | D187 and matrix evidence; the division, shift, bool, float and text edges it never removes are named there rather than refused |
| `[1130]` | hosted-now | R4.10 | matrix evidence |
| `[1140]` | hosted-now | R4.10 | matrix evidence |
| `[1150]` | hosted-now | R4.10 | matrix evidence |
| `[1160]` | hosted-now | R4.10 | matrix evidence |
| `[1170]` | hosted-now | R4.10 | matrix evidence |
| `[1180]` | hosted-now | R4.10 | matrix evidence |
| `[1190]` | hosted-now | R4.10 | matrix evidence |
| `[1200]` | hosted-now | R2.30 | implemented; fixture attribution in this increment |
| `[1210]` | hosted-now | R2.20 | matrix evidence |
| `[1220]` | hosted-now | R2.30 | matrix evidence |
| `[1230]` | hosted-now | R2.60 | matrix evidence |
| `[1240]` | hosted-now | R2.60 | matrix evidence |
| `[1250]` | hosted-now | R2.60 | matrix evidence |
| `[1260]` | hosted-now | R2.60 | matrix evidence |
| `[1270]` | hosted-now | R2.60 | matrix evidence |
| `[1280]` | hosted-now | R2.60 | matrix evidence |
| `[1290]` | hosted-now | R2.40 | matrix evidence and named refusal |
| `[1300]` | hosted-now | R2.40 | matrix evidence |
| `[1310]` | hosted-now | R2.70 | matrix evidence |
| `[1320]` | hosted-now | R2.60 | matrix evidence |
| `[1330]` | hosted-now | R4.10 | implemented; fixture attribution in this increment |
| `[1340]` | hosted-now | R2.60 | matrix evidence |
| `[1350]` | hosted-now | R2.40 | matrix evidence and named refusal |
| `[1360]` | hosted-now | R3.20 | matrix evidence |
| `[1370]` | hosted-now | R2.80 | matrix evidence |
| `[1380]` | hosted-now | R2.80 | matrix evidence |
| `[1390]` | hosted-now | R2.80 | matrix evidence |
| `[1400]` | hosted-now | R2.80 | enforced absence; fixture attribution in this increment |
| `[1410]` | hosted-now | R3.10 | matrix evidence |
| `[1420]` | hosted-now | R3.10 | matrix evidence |
| `[1430]` | hosted-now | R4.30 | D201 aliases retain file-local namespace lookup |
| `[1440]` | hosted-now | R4.30 | D201 selected imports retain original public declaration identities |
| `[1450]` | hosted-now | R3.10 | implemented; fixture attribution in this increment |
| `[1460]` | hosted-now | R1.60 | matrix evidence |
| `[1470]` | deferred | R7.20 | companion-tool package policy remains deferred |
| `[1480]` | hosted-now | R4.30 | explicit ordered roots; arranging project/user/system defaults belongs to the companion tool |
| `[1490]` | hosted-now | R2.40 | implemented; fixture attribution in this increment |
| `[1500]` | hosted-now | R2.40 | matrix evidence |
| `[1510]` | hosted-now | R4.30 | D202 and fixed assertion fixtures |
| `[1520]` | hosted-now | R2.40 | implemented; fixture attribution in this increment |
| `[1530]` | hosted-now | R4.30 | D202 and deterministic typed option cases |
| `[1540]` | hosted-now | R2.40 | matrix evidence |
| `[1550]` | principle | none | native-backend policy; implementations have target owners |
| `[1560]` | hosted-now | R4.30 | D202 hosted tool facts/directives; machine operations have named owners |
| `[1570]` | hosted-now | R3.50 | matrix evidence |
| `[1580]` | hosted-now | R4.40 | D203--D205 and `extern.c-boundary` cover the selected boundary; native gate 1884079 passed |
| `[1590]` | hosted-now | R4.30 | D202 and runtime/r430-static-library archive execution |
| `[1600]` | hosted-now | R4.40 | C definitions are implemented and classified by `extern.c-boundary`; native gate 1884079 passed |
| `[1610]` | hosted-now | R4.40 | independent native/C symbol overrides are implemented and classified by `functions.linkage`; native gate 1884079 passed |
| `[1620]` | freestanding | R6.30 | scheduled atomics work |
| `[1630]` | freestanding | R6.60 | scheduled inline-assembly work |
| `[1640]` | freestanding | R6.60 | scheduled keep and placement work |
| `[1650]` | hosted-now | R1.80 | matrix evidence |
| `[1660]` | hosted-now | R3.50 | matrix evidence |
| `[1670]` | hosted-now | R1.80 | matrix evidence |
| `[1680]` | hosted-now | R3.60 | matrix evidence |
| `[1690]` | hosted-now | R2.50 | matrix evidence |
| `[1700]` | hosted-now | R2.30 | matrix evidence |
| `[1710]` | principle | none | admission criterion; no implementation claim |
| `[1720]` | hosted-now | R2.90 | matrix and guarantee evidence |
| `[1730]` | principle | none | proof-carrying principle; no implementation claim |
| `[1740]` | hosted-now | R3.10 | matrix evidence |
| `[1750]` | hosted-now | R1.20 | matrix evidence |
| `[1760]` | hosted-now | R1.20 | matrix evidence |
| `[1770]` | hosted-now | R4.10 | matrix evidence |
| `[1780]` | hosted-now | R1.20 | matrix evidence |
| `[1790]` | hosted-now | R1.60 | matrix evidence |
| `[1795]` | hosted-now | R2.20 | matrix evidence |
| `[1800]` | hosted-now | R2.30 | matrix evidence |
| `[1810]` | hosted-now | R2.30 | matrix evidence |
| `[1820]` | hosted-now | R1.40 | matrix evidence |
| `[1830]` | hosted-now | R1.30 | matrix evidence |
| `[1840]` | hosted-now | R1.50 | matrix evidence |
| `[1850]` | hosted-now | R1.50 | matrix evidence |
| `[1860]` | hosted-now | R1.50 | matrix evidence |
| `[1870]` | hosted-now | R1.60 | matrix evidence |
| `[1880]` | hosted-now | R1.60 | matrix evidence |
| `[1890]` | hosted-now | R1.60 | matrix evidence |
| `[1900]` | hosted-now | R1.60 | matrix evidence |
| `[1910]` | hosted-now | R1.60 | matrix evidence |
| `[1920]` | hosted-now | R2.30 | matrix evidence |
| `[1930]` | hosted-now | R2.30 | matrix evidence |
| `[1940]` | hosted-now | R1.60 | matrix evidence |
| `[1950]` | hosted-now | R1.60 | matrix evidence |
| `[1960]` | hosted-now | R1.80 | matrix evidence |
| `[1970]` | hosted-now | R1.80 | matrix evidence |
| `[1975]` | hosted-now | R3.50 | matrix evidence |
| `[1980]` | hosted-now | R2.30 | matrix evidence |

### R2 gate

- Representation, errors, references, conformances and evidence are executable
  on Linux x86-64 and target-parametric for later 32-bit lowering.
- Shared generics and `any` dispatch without specialization.
- The guarantee, diagnostic and conformance registers cover every implemented
  operation.

Historical source witness: `f0967732f32bd3daa70d88ce57281223a95a4916`
retains R2.90's guarantee, diagnostic, conformance and target registers and its
recorded Linux debug/release result of 381 cases and 8,749 checks. In that tree,
`runtime/any-composed-dispatch`, `runtime/generic-composed-evidence` and
`runtime/declared-errors-direct-and-inferred` are concrete execution oracles;
the target cases retain synthetic 32-bit layout checks. The recorded result
belongs to that historical source, not today's suite. R4.91 M6 records source
provenance separately from the unrecovered original run bundle.

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
arena block, which D191 re-owned to R4.20 and D196 transfers to R4.80.

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
diagnostic-delivery failure from its public operation. R4.10 had not yet
enabled loops or full UTF-8 text, so the same scanner, recovery and sequence
walks are spelled recursively over R3's byte-oriented positions.

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

### R3 gate

- A complete hosted parser program executes from a clean checkout.
- The evidence ABI and `any` are semantic foundations; specialization is absent.
- Major editor families recognise and highlight `.ldn` from checked shared artifacts.
- Raw storage came from container pressure and is normative.
- Diagnostics are useful, deterministic and traceable to current codes and
  spans.

Historical source witness: `58bef7c8f34a85f6f0d9ce2d681242450f6e42fc`
retains R3.70's complete derived parser, its derivation mapping and the recorded
Linux debug/release result of 389 cases and 9,153 checks. The
`runtime/derived-parser` metadata names its input, exact merged output and
status 42; the program exercises recovery, allocator and diagnostic-delivery
failures through the shared evidence path. The earlier editor-support commit
`dcf6aec6` and its generated artifacts are ancestors of that source. This is a
historical source/result record; R4.91 M6 retains the missing original run-bundle
question and does not claim that a current run replayed this phase gate.

## R4 — Complete hosted Linux x86-64 path

R4 closes the hosted language surface on Linux, completes the container and
application workloads, adds usable source debugging and implements only
baseline measured optimization.

### R4.10 — Close the hosted construct matrix

Status: complete
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
refusal. A later collection increment enables fixed-array and slice elements,
carrying their complete storage shape through the element alias and through
fixed-array or slice loop results while retaining `any` elements and
iterable-evidence sources as the named refusal. D178 records the boundary. The
next collection increment enables `any C` elements in fixed arrays and slices,
retaining their erased concept identity and evidence through the storage alias
and `any` loop-result transport. Computed slice sources still run once, and
permissions, indices, control transfers and cleanup retain D160's rules.
Iterable-evidence sources remain the named refusal. D179 records the boundary.
The following collection increment enables [1320] traversal of struct and
`any C` sources through one exact `iterable` conformance. It evaluates and
retains the source once, preserves the complete cursor and copied Item
identities, calls providers in concept order through ordinary evidence,
advances an optional `usize` index with `next`, and retains existing cleanup,
control and loop-result transport. An erased source remains an `any` pair and
is never treated as slice storage. D180 records the rule and its L0301/L0303
boundaries.
The next increment enables [0600]'s distinct hosted `utf8`, `utf16` and
`cstring` views in every direct [0260]/[0280] literal context. D181 preserves
their immutable reference identities through signatures, aggregates, generic
actuals and origins; validates and decodes Unicode scalars into UTF-8 or
UTF-16; and extends pooled static literal images to `u16` data and cstring
relocations. Every datum has one uncounted trailing zero element. [0610]
indexing remains a separate named refusal, as do slicing and traversal that
would otherwise expose a backing slice accidentally.
The following text increment enables [0610]'s two `utf8` indexing operations.
D182 selects a linear codepoint-ordinal scan for an exact `u32` and O(1)
access for the exact public `core/text.position` identity; both return one
codepoint's read-only source-derived byte slice. Out-of-range ordinals and
positions at the end or off a codepoint boundary trap through the existing
checked slice-address path. The other text identities, pooling, terminators,
permissions and errors retain D181's rules, while text slicing and traversal
remain separate work.
The next text increment enables range slicing for the exact length-bearing
`utf8` and `utf16` identities. D183 gives both exact `usize` code-unit bounds,
requires scalar-boundary endpoints, makes the inclusive form consume the
complete upper scalar, and preserves the immutable source identity and origin.
It evaluates and retains the source before evaluating each bound once in
written order. `cstring` remains unsliceable because it has no length; invalid
bounds and split encodings trap through checked slice addresses. D181/D182
validation, pooling, terminators, indexing, errors and ordinary range behavior
remain unchanged, and traversal remains separate work.
The following text increment enables [0600]/[1320] traversal of the exact
`utf8`, `utf16` and `cstring` identities through three intrinsic conformances.
D184 gives each a private `usize` code-unit cursor and immutable copied `u32`
item, decodes one validated Unicode scalar per iteration, and stops `cstring`
before its first NUL. It retains the source once, preserves D180's provider,
cleanup, transfer and optional-index order, and neither searches nor changes
ordinary evidence. D181--D183 and existing range/array/slice/evidence behavior
remain unchanged.
The seventh increment enables quoted text in a direct read-only
`[]u8` context, including byte escapes, UTF-8 source validation, an uncounted
trailing NUL, content-pooled read-only data and static slice relocations.
D161 keeps `utf8`, `utf16`, `cstring` and codepoint escapes deferred while
giving malformed spelling lexical L0320.
The eighth increment enables contextual and default-f32 decimal literals for
f32 and f64, their storage and internal call carriers, IEEE runtime `+`, `-`,
`*`, `/`, unary minus and comparisons, including signed zero, infinities and
unordered NaN comparisons. D162 keeps f16 and named special values, scalar
conversions, module float arithmetic and the floating-point C ABI as explicit
later boundaries, leaves hexadecimal spelling to the twelfth increment, and
gives malformed exponents lexical L0321.
The ninth increment enables [0250]'s character literals as fixed-`u32`
Unicode scalar values, accepting raw shortest-form UTF-8, the simple [0270]
escapes and `\u{...}` while rejecting empty, multiple, nonscalar and
byte-escape contents with lexical L0322. D163 shares one decoder across
lexing, static folding and lowering and keeps the text representation types
and their indexing work separate.
The tenth increment enables [0280]'s raw literals in the same direct read-only
`[]u8` context as quoted byte text. Matching runs of three or more quotes make
shorter quote runs content, escapes remain uninterpreted, and a line-leading
closer's exact indentation is stripped from nonblank lines. D164 assigns
malformed UTF-8 or indentation lexical L0323 and shares the pooled datum path
with ordinary text.
The eleventh increment enables [0390]'s thirteen compound assignments over
scalar places. Each evaluates and retains its destination once, reads the old
value before evaluating the right-hand side, applies the corresponding checked,
wrapping, shift or bitwise operator, and writes through the ordinary assignment
permission path. D165 preserves the existing operator diagnostics and traps
and makes an unassigned destination a read-before-write failure.
The twelfth increment enables [0230]'s hexadecimal f32 and f64 literals with a
required binary exponent. D166 converts their significant, round and sticky
bits without host floating-point arithmetic, preserves exact normal and
subnormal values, rounds other values to nearest with ties to even, and removes
the scanner's final deferred-token family. Malformed exponents remain L0321 and
a finite spelling that becomes infinity remains L0300.
The thirteenth increment enables [0240]'s `f32.infinity`, `f64.infinity`,
`f32.nan` and `f64.nan` as inherently typed IEEE constants. D167 chooses one
canonical quiet NaN pattern per width, makes unary minus flip only the sign
bit, admits the names throughout scalar and aggregate module images, and gives
unknown type-qualified members or a contextual width mismatch L0301. f16,
explicit integer/float conversions, module float arithmetic and the external
float ABI remain later boundaries.
The fourteenth increment enables [0310]'s explicit conversions among every
enabled integer type. D168 rejects an impossible literal or module-known value
with L0300, sign- or zero-extends a runtime source before checking the exact
destination range, and traps rather than truncating, wrapping or reinterpreting
an out-of-range value. It reuses [0470]'s target-neutral conversion operation;
float/integer and bool conversions remain named R4.10 refusals.
The fifteenth increment enables explicit conversion between f32 and f64.
D169 makes widening exact, narrows to nearest with ties to even, preserves
signed zero and the infinity/NaN class, folds module-known carrier bits without
host float arithmetic, and gives a finite f64-to-f32 overflow L0300 when known
or a runtime trap otherwise. Integer/float and bool conversions remain named
R4.10 refusals.
The sixteenth increment enables explicit conversion from every enabled integer
type to f32 or f64. D170 rounds the mathematical integer to nearest with ties
to even, folds module images without host floating-point arithmetic, and
handles the upper half of u64 explicitly in the Linux backend. Every enabled
integer lies in both floats' finite range, so this direction never traps;
bool conversion remains a named R4.10 refusal.
The seventeenth increment enables explicit conversion from f32 or f64 to every
enabled integer type. D171 truncates finite values toward zero before checking
the exact destination range, rejects known out-of-range, infinity and NaN
sources with L0300, and gives the equivalent runtime cases a trap. Module and
runtime conversion both decode IEEE carrier bits without host floating-point
arithmetic, including the upper half of u64; bool conversion remains refused.
The eighteenth increment enables explicit conversion from bool to every
enabled integer type. D172 fixes false's image at zero and true's at one,
making this direction total across every signed and unsigned width and across
runtime and module values. Conversion to bool and float conversion from bool
remain named refusals rather than acquiring an implicit truthiness rule.
The nineteenth increment enables explicit conversion from every enabled
integer type to bool. D173 accepts only the canonical images zero and one,
giving other known values L0300 and equivalent runtime values a trap rather
than implicit nonzero truthiness. Float-to-bool conversion remains refused.
The twentieth increment enables explicit conversion from f32 or f64 to bool.
D174 maps either signed zero to false and exactly positive one to true, while
every other known value receives L0300 and its runtime equivalent traps. This
was recorded as completing the enabled scalar conversion matrix, but the
existing bool-to-float refusal remained and is reconciled below.
The twenty-first increment enables module-level f32 and f64 `+`, `-`, `*`,
`/` and comparisons, including scalar and aggregate images. D175 evaluates
IEEE carriers with bounded integer work, rounds to nearest with ties to even,
keeps gradual underflow and signed zero, produces infinities for arithmetic
overflow or division by zero, canonicalizes arithmetic NaNs, and preserves
unordered comparison without borrowing the compiler host's float operations.
The twenty-second increment enables explicit conversion from bool to f32 and
f64. D176 maps false to exactly positive floating zero and true to exactly
positive floating one for module-known scalar expressions, aggregate images
and runtime values. Both results are exact and this direction is total. It
completes the enabled scalar conversion matrix while f16 and the external
floating-point ABI remain deferred.
The twenty-third increment repairs module-known bool conformance already
required by [0340], [0410], [1460] and [1940]. D177 folds `not`, `and` and `or`
over literal, named, forward, chained and comparison operands into scalar and
aggregate static images, preserving left-to-right short-circuiting without
executing an initializer. Scalar bool datums now carry their zero-or-one image
directly, so routine CFG `Branch` instructions cannot reach datum emission.

The accounting increment classifies every normative construct in the
construct-applicability register and makes that register the mechanical R4.10
closure test. It also removes the unreachable generic scalar-conversion and
collection-traversal refusal kinds after D176 and D180/D184 respectively, and
moves the still-live u128/i128 and f16 refusals wholly to the checker that
recognises those resolved type names. The finite hosted gap list is [0480]'s
atom-or-pointer union, [0660]'s range subtype, [1040]'s caller parameter,
[1070]'s condition declaration, [1120]'s `unchecked` region, the u128/i128
part of [0150], the f16 part of [0170], and the ownership disposition for
[0500]'s pointer/slice operations, [0810]'s derivation primitives and [0820]'s
lexical `arena` block. No language decision is made by this inventory.
Each entry is marked closed below rather than struck from the finding: D185
closed [1070], D192 supersedes D186 and closes [1040], D187 closed [1120],
D188 closed [0660] and D189 closed [0480]; D190 re-owned the u128/i128 part of [0150] and the f16
part of [0170] to R7.20, and D191 settled the ownership disposition by
re-owning [0500], [0810] and [0820] to R4.20. The hosted gap list is empty.

The condition-declaration increment enables [1070]'s initialized inferred and
typed bindings in `if`, every `elsif`, and `while`. D185 gives each binding the
scope of exactly the body it guards, evaluates its initializer before that
scope exists, requires its stored value to be `bool`, and reinitializes a
`while` binding at every test. Sibling arms, `else`, `complete`, and following
statements do not see the name; an outer declaration may be shadowed, while a
second declaration in the guarded body is a same-scope duplicate.

The caller-parameter increment enables [1040] with D192, superseding D186's
refused string representation. An omitted caller position receives an ordinary
12-byte struct of three u32 fields: file_id, line and column. Line and byte
column remain usable when filenames are omitted from a constrained deployment.
The off-target file table records each used source once; its assembly digest
and the matching ELF build ID bind lookup to the emitted build. No source text
or per-site static datum enters the program. Explicit named forwarding,
caller-skipping positional matching, immutable bindings and structural signature
identity survive; the two-token contextual word remains an ordinary name in
programs that do not write the modifier. Runtime evidence covers returned
coordinates, forwarding, omission, generic and indirect calls, multiple caller
positions, separate source files and the 12-byte value size.

The final closure repair also resolves the two pre-existing crashes found by
the closure audit. An inline struct argument with a refused field now retains
its source diagnostic without querying an absent layout. Loop-exit discovery
walks expression children, so a break in a value-position begin creates the
exit block it reaches. The caller increment additionally exposed and repaired
aggregate assignment from a named-argument call. The grammar preamble now
names the contextual loop words as well, with a mechanical completeness check.
These are implementation corrections to existing rules, not deferred items.

The unchecked-region increment enables [1120] with D187's Linux semantics.
`unchecked begin ... end unchecked` is a statement and a lexical block spelled
with a contextual word, and inside it the compiler emits no integer overflow
edge for `+`, `-`, `*` and unary `-`, no element-index or slice-range edge, and
no destination-range edge for an integer-to-integer or pointer-to-integer
conversion. Division, shift, bool-conversion, float-conversion and text
boundary edges are never removed, because their behaviour without one is not
one thing on every target Landin describes; every static refusal is untouched.
The region is lexical rather than dynamic, carries one Boolean through the
neutral IR to the backend, and grants an optimizer nothing, which leaves
R4.50 owning what an optimizer may assume and R5/R6 owning C6's target parity.

The range-subtype increment enables [0660] with D188. A range subtype is its
base integer type constrained and not a new type: the representation, the
operands and every operator result are the base's, so `p + 1` is a `u8` and
[0650]'s distinct type remains its complement. The constraint is checked where
[0660] says it is and nowhere else — storing into a place whose declared type
is the subtype, and applying the subtype name to a value [0700] — reusing
D168's exact-range path, so a known value outside the bounds is L0300 and a
runtime one traps at [1950]'s edge. [1730]'s habit is mechanical: a value
whose own subtype's bounds lie inside the destination's is not checked again.
Composite and reference positions, `addr` of a constrained place and a
generic type argument are refused by name and belong to R7.20, because
`[]percent` and `[]u8` would otherwise be one type; an `extern (c)` signature
refuses one through [1580]'s existing hosted-scalar boundary.
The increment also extends [0700]'s conversion to a declared scalar name, so
D15's alias converts as the name it aliases does.

The pointer-union increment enables [0480] with D189. A union that flattens to
exactly one atom identity and one pointer type is that pointer type carrying
the atom as its empty case, occupying one target pointer carrier with zero
reserved for the atom, which is the measurement R2.50 recorded and now has a
caller for. A plain pointer and the atom's singleton widen into the union and
neither direction reverses, `match` is the only way back out, its two cases
are the atom name and the reserved word `ptr` with an optional read-only
binding, and exhaustiveness over the two is L0312. Every position that would
read the empty case as an address is refused by name, one negative fixture
each: `.val` in a read, in an assignment target and under `addr`, an integer
conversion, `any` construction, a comparison, `ptr(n)` into a union position
and a `ptr T` argument or result. The bound pointer carries the subject's own
origin and the empty case carries none, so a union built from `addr local`
still refuses an escaping use of the binding. A union of several atoms and a
pointer needs [1870]'s tagged carrier and is refused by name against R7.20.
D189 also records an unresolved contradiction it does not own: `ptr(0)` is
accepted today [0470] and `runtime/core-mem-allocators` uses it as a failure
sentinel five times, while [1580] states that it is refused, so null remains
mintable on the pointer side. That belongs to [1580] and R4.40 below.

The scalar-width increment re-owns rather than implements. D190 records that
u128, i128 and f16 are refused by name against R7.20 and not by this item.
The refusal was already the specification's: [1790]'s `scalar_name` spells
thirteen names and has never spelled these three, and [1870] already stated
that they are described in the tour and not enabled. This item's scope names
text, literals, patterns, loops, `unchecked`, modules, builtin directives and
hosted entry behavior and has never included widening the scalar set; the
compiler's table said R4.10 because D162 was an R4.10 increment when it
deferred f16, which is an accident of order rather than a decision. [0150] is
already split across owners, since the packed widths the same paragraph names
belong to R6.40 and R6.80. Both constructs keep this item as their
applicability owner, because it accounted for them as far as the kernel
enables them, and only the residual refusal moves — the shape D188 gave
[0660] and D189 gave [0480]. D190 enumerates what R7.20 inherits, and
`negative/refused-widths-name-their-owner` pins the rendered report that
names it.

The region-ownership increment discharges the last three unsettled rows the
way [1830] says an omission is discharged: by recognising the syntax and
naming the work that enables it. D191 finds that [0500]'s three operations
are ordinary `core` functions with no compiler privilege — D151 already
rejected `slice_from` permanently, and the cut [0810] attributes to `offset`
is the one `core/mem`'s `arena_alloc` makes today through [0470]'s
integer-to-pointer conversion, which the `pointer.integer-origin` guarantee
row already classifies with four fixtures behind it. [0820]'s lexical block
is language syntax, but everything it means is allocator semantics: the type
its name has and how it meets [1360]'s contract, where its bytes come from
and how many on a host and on a 32 KB part, whether exhaustion fails or
traps, and how its frame-origin rule survives [0790]'s rule that an
allocator's result borrows nothing. All three rows move to `later-r4` under
R4.20, the shape [1430] and [1440] already have, and what this item pays is a
named diagnostic in place of a parse cascade: the parser refuses
`arena name do` on the word and swallows the block's own closer, and the
checker refuses the `arena` type name [0780] writes. `arena` stays unreserved
by [1760], so `core/mem`'s own `arena` struct and every parameter spelled
`arena` are untouched.

Delivered: D156 to D192, with D192 superseding D186, close the hosted construct
surface. Loops arrived first — transfers, labels, values, integer ranges and
then traversal of slices, arrays, `any` elements, struct sources and the three
text views — followed by the literal families (quoted, raw, character, decimal
and hexadecimal float, and the IEEE special names), the thirteen compound
assignments, the complete enabled scalar conversion matrix in both directions
across integers, floats and bool, module-level float arithmetic and
module-known bool folding, and finally [1070]'s condition declaration,
[1040]'s caller parameter, [1120]'s `unchecked` region, [0660]'s range subtype
and [0480]'s atom-or-pointer union. The accounting increment turned the
question this item exists to answer into a command: the construct
applicability register classifies all 200 normative constructs, and `check.py`
audits it as soon as this item stops being active, so closing it requires that
each of the 174 `hosted-now` rows carry fixture evidence or a refusal named
against the item that enables it, and that neither refusal table still name
R4.10. The matrix reads 178 of 200 constructs with evidence.

What the item deliberately left is named rather than open, and every one of
the twenty-two remaining bare rows is `later-r4`, `freestanding`, `deferred`
or `principle`. The accounting increment left a gap list of eight entries over
ten constructs, and three of those entries were settled by re-owning rather
than implementing, which is the honest outcome where the work belongs
elsewhere: u128, i128 and f16 have never been spelled by [1790]'s
`scalar_name`, so their refusal was already the specification's and D190 moved
only the enabling item to R7.20; and [0500]'s derivation conveniences,
[0810]'s primitives and [0820]'s lexical `arena` block are allocator
semantics, so D191 moved them to R4.20 with the four questions neither
document answers written down there. Both re-ownings were paid for here with a
refusal that names its inheritor rather than a parse cascade. The other five
entries were implemented: [1070]'s condition declaration, [1040]'s caller
parameter, [1120]'s `unchecked` region, [0660]'s range subtype and [0480]'s
atom-or-pointer union, the last two of which also leave a named part to R7.20.
Target parity for `unchecked`, what an optimizer may assume, and [1580]'s
unminted null remain with R5/R6, R4.50 and R4.40 respectively.

The complete pinned Linux x86-64 debug and release gates pass 395 cases and
10,384 checks each, and `python3 check.py` is clean over all seven documents.

Exit evidence: every hosted `[NNNN]` row has implementation and positive or
negative evidence; no omission is hidden by prototype coverage.

### R4.20 — Complete hosted core containers and library slice

Status: complete
Depends on: R3.40, R4.10

Complete the Landin `core/vec`, `core/map`, `core/tree`, allocator and hosted
library pieces required by prototypes 3 and 4. Document freestanding/hosted
layering, raw syscall versus libc choices and deliberate omissions.

The first bounded increment corrects the two existing `core/mem` arena
providers without widening the library surface. D193 makes their zero and
arithmetic boundaries explicit: alignment is applied to the absolute backing
address; zero alignment means byte alignment; zero-size requests are valid;
and an extent, address-rounding or allocation-end calculation that cannot fit
`usize` reports `out_of_memory` before the arena offset or failing-provider
budget and counters change. `runtime/core-mem-arena-boundaries` exercises a
deliberately misaligned base, exact exhaustion, zero requests, maximum-`usize`
size/alignment and base-plus-used boundaries, including successful arithmetic
at the last representable address.

The second bounded increment applies D194 to `core/vec`: checked byte extents
and geometric growth precede provider calls, zero-sized items have explicit
logical-slot/zero-byte allocation behavior, and initialized-prefix transfer
and drain use bounded-stack loops. Failed growth preserves pointer items and
list shape; retry and exact allocation/free extents execute. The large case
grows, reads and releases 65,536 initialized items. Its required compiler
repairs preserve enabled fixed-array whole stores/copies through pointer and
computed destinations, including variant payload offsets and destination
recovery returns, and type traversal headers before generic-call discovery.
Match payload bindings are established before dependent traversal/generic
discovery, and array traversal retains the selected variant payload path.
Runtime-address array literals and mixed repetitions retain source-order
element writes. Pointer and slice place operands may recover by returning:
address formation stops on that exit, and a slice descriptor survives any
index recovery blocks. These repairs implement existing enabled compositions;
they do not change vector arithmetic, the public API or [1820].
The bounded compiler follow-up closes the separate pre-existing nested-array
store defect: a field-zero destination is direct array storage only when its
neutral path is empty. A constant index into an array of fixed arrays retains
that path on the existing element-store operation, so verification and each
target derive every containing dimension before selecting the scalar element.
Literal and mixed-repetition writes, whole copies and fills now compose through
that path, including a fixed-array field reached inside a constant-indexed
struct element. This is not a change to array legality or normalization and
does not force a source index to become dynamic.
The scalar-leaf follow-up restricts the flat-array store shortcut to a directly
named array. A nested scalar assignment or increment/decrement retains the
containing path instead of asking resolution to bind an intermediate index
expression as a name. Compound writeback likewise retains that path,
materializing only its already-constant leaf index when no runtime index was
saved. `runtime/nested-scalar-array-stores` pins module and frame arrays,
neighboring values, compound updates and RHS call counts.
The later vector/sort, map and tree increments below complete this library
composition with named runtime evidence.

The growth error translation follows [1820]'s existing disambiguation rule:
a call-site `else` yields to an enclosing `then` or `elsif` arm, and
parentheses around the recovered call make an inner recovery explicit.
The minimal binding `next: usize = (grown() else (problem)` with its recovery
closed by `end)` compiles under that rule. The private `next_growth` routine
is an ordinary factoring choice; it is not required to avoid a compiler
defect. No parser widening or additional compiler prerequisite follows from
this composition.

The bounded generic-reference prerequisite now admits symbolic pointer and
slice fields, preserving their concrete reference descriptors when the nominal
instance is built. D138's structural deduction descends through exact pointer
and slice patterns and compares repeated erased actuals by concept identity,
including actuals recovered from nominal instances. Lowering uses the existing
stored shapes for slice/any dereferences and copies complete any fields in
ordinary structs. No grammar, representation, origin rule or core-name
privilege changes. `runtime/generic-reference-results`,
`runtime/generic-reference-carriers` and
`runtime/generic-any-nominal-transport` cover typed construction, field writes,
copy, return and mutable erased dispatch; the carrier actuals include scalars,
pointers, reference-containing structs, slices and erased concepts. The
checking case `reference actuals keep complete identity` separates permission,
referent and concept keys while reusing aliases. The corresponding
`negative/generic-reference-*`, `negative/generic-slice-field-*` and
`negative/generic-any-*` cases retain permission, exact referent extent,
concept, frame-escape, live-view and wrong-source refusals.

The bounded array-reference prerequisite carries complete immediate
pointer/slice/any element descriptors through fixed-array referents, generic
normalization and keys, results, local inference and ordinary array fields.
D138, D178 and D179 supply the existing identity and representation contract;
no new decision, operation or core privilege is introduced. Lowering reuses the
runtime-address path for stores and whole-array copies through pointer or slice
storage, and verified IR signatures retain nested array element shapes. The
x86-64 parameter prologue copies the complete stored shape using the existing
target extent calculation, including slice descriptors and erased values.
`runtime/fixed-array-reference-shapes` and `runtime/fixed-array-any-shapes`
execute bounds one and three, generic copies and stored fields, typed pointer
stores and slices, including heterogeneous mutable erased providers. The
checking cases `array actuals keep complete identity` and
`array reference fields follow target` distinguish extent, permission,
referent and concept identities and measure pointer/slice/any fields against
both 32-bit and 64-bit target facts. The corresponding `negative/array-reference-*`
and `negative/array-any-*` cases retain whole-array identity, field identity,
frame-return and zero-image refusals. The verifier case
`nested array address shapes keep children` rejects malformed child shapes.
The verifier case `array routine parts keep complete children` retains only
legacy scalar/canonical nominal part compatibility and rejects scalar parts
paired with wider descriptors or variant children, conflicting explicit scalar
metadata and mismatched descriptor extents. Nested fixed-array struct fields
retain the existing L0304 boundary pinned by
the original `parameterized-struct-unused-shape` and template-order controls
(now positive under R4.90/D216);
their recursive field representation and range composition belong to R4.70.
R4.20 retains the evidenced direct-array and typed-copy source forms.

The reference-storage dispatch follow-up retains scalar destinations in an
existing checked address slot before the RHS or old-value load. Plain
assignment and `inc`/`dec` reuse that address; destination recovery that leaves
the routine emits no later address, RHS, load or writeback. Compound updates
retain their old-value-before-RHS order and stop after terminating destination
evaluation. `runtime/reference-place-assignment-order` counts the pointer-array
index and branching RHS independently; `runtime/reference-place-updates`
alternates slice indices and checks scalar pointer fields, untouched neighbors
and the compound old value. `runtime/reference-place-bounds-before-rhs` traps
before an RHS return,
and `runtime/reference-place-update-recovery` covers both failure-edge recovery
and unconditional destination exits for assignment, increment, decrement and
compound update. These repair [0410]/[1900] lowering without changing reference
identity or the separately owned nested fixed-array store paths.

These prerequisites do not close the initialized-view library increment. The
selected route remains an initialized slice witness, with ordinary typed
stores before publishing an extended prefix; the constrained opaque-view
alternative is not selected. Genuine initialized arrays supply the compiler
evidence, not a forged larger allocation or byte-buffer substitute. Raw
transitions, initialized allocation helpers and allocator-backed vector growth
retain their own execution obligations, including zero-sized elements and
heterogeneous mutable dispatch after growth.

The named-call statement repair brings [1810]'s grammar into agreement with
[0980]: ordinary and value-producing blocks accept positional or named calls,
including explicit static actuals and selected function values. The parser
keeps a non-final labelled call as a statement in either block form, and
resolution still distinguishes a call from a construction. The latter retains
its existing destination requirement and L0304 refusal when written as a
standalone statement. `runtime/named-call-statements` pins source-order
arguments, once-only selected-callee evaluation, generic calls and the
expression-body boundary; `negative/construction-is-not-call-statement`
pins both ordinary and value-block refusals. Cleanup registration keeps its
separately specified `call` grammar.
The compound-statement boundary follow-up treats D165's compound assignment
operators like `=` when distinguishing a statement from an expression at a
function body, value-bearing block or direct match arm. It retains the existing
assignment grammar and expression refusal. `runtime/compound-statement-boundaries`
pins plain and selected destinations in all three positions, with computed
values and an unchanged neighboring field.
The value-block traversal follow-up includes `for` beside `while` and `loop`
when classifying a parsed control expression as a non-final statement.
`runtime/for-value-block-statements` pins a traversal followed by the block's
computed answer. This changes no loop syntax or value-transfer rule.
The reference expression-body follow-up supplies the declared pointer or slice
result descriptor to contextual checking, as it already does for other result
shapes. `runtime/reference-expression-bodies` exercises mutable pointers,
read-only relaxation, slices and a pointer-backed slice of zero-sized arrays;
`negative/reference-expression-body-permission` retains the refusal to
strengthen permission. This repairs missing expected type evidence without
changing reference identity or return-source rules. The allocator-backed
zero-sized initialized-prefix runtime is supplied by
`runtime/core-mem-zero-prefix`.

The bounded erased-result staging repair removes the early provider-access defect.
An inferred `erased.entry()` now derives its complete concrete signature from
the selected exact concept and already-interned conformance key rather than
reading the provider run before its later validation. Provider finalization
remains in its dependency-ordered phase and still proves every implementation
against that signature. `runtime/any-inferred-entry-staging` compares inferred
and explicit bindings across reversed declaration order and heterogeneous
mutable providers, including declared error recovery and a mutable pointer
result with its `from` source plus an inferred `any` result round trip. The
checking case pins the former no-crash seam,
and `negative/any-inferred-result-frame-escape` retains that result's origin.
No generic, library-name or provider-order privilege is introduced.
The staging-consistency follow-up keeps the exact concept entry's
caller-visible parameter and result labels on both inferred and contextual
calls. A finalized provider signature is reused only when those labels already
preserve the concept interface; otherwise the call keeps a separate exact
concept signature while its dispatch record still names the validated provider
entry. The runtime case uses differently labelled implementations in reversed
heterogeneous conformance order, and the checking case compares inferred and
explicitly typed calls with a named concept argument. The frame-escape case now
uses a module receiver so only its `from` argument is local;
`negative/any-provider-result-source-mismatch` proves that ignoring provider
labels for conformance does not ignore a mismatched result-source map. Provider
validation and dispatch identity are unchanged, and no language rule changes.

The bounded generic erased-`try` repair lets [0960]'s successful call value
use the existing local nominal-aggregate call destination even after generic
instance setup has published that destination's concrete descriptor. The
checker therefore reaches the ordinary `try` synthesis path and records the
erased call's complete argument match and result type in every routine-instance
overlay instead of silently skipping the initializer before lowering.
`runtime/generic-erased-aggregate-try` executes two distinct generic type keys
against heterogeneous stateful providers whose parameter and result labels
differ from the concept entry, with named reordering, both failure paths and a
successful retry pinned by exact call counts. Error propagation, concept-label
matching and provider conformance remain unchanged. This adds no array-valued
`try`, general struct pseudo-value, return-context deduction or library-name
privilege.

The initialized-prefix library represents its count with a genuine
slice witness. `mem.admit` stores a complete value before constructing the
first singleton view or extending the existing prefix; `mem.transfer` saves
an initialized source value before publishing the target's next slot.
`mem.used` returns only that prefix `from storage`, and `mem.replace` checks
an initialized index and requires an escaping inserted value. Pointer and
heterogeneous `any` growth, writable replacement, frame/permission/exact-source
refusals and live-view transition refusals have focused evidence. The generic
array-selection transfer repair supplies the zero-sized prefix composition;
`runtime/core-mem-zero-prefix` retains its genuine `[0]u8` item throughout.
The complete pinned Linux debug and release suites each pass 403 cases and
10,814 checks, including the original zero-prefix fixture; the font-aware
repository check is clean. The authoritative native Linux integration gate
remains required after publication. No capacity view,
built-in raw-storage kind or integer reconstruction of the returned view is
introduced.

The bounded contextual-text follow-up closes the generic-call double-check
defect. When a text-literal argument's written parameter pattern normalizes to
a concrete reference using only a saturated explicit static tuple, generic
deduction now applies that exact context before context-free synthesis can
choose the `utf8` default. Runtime-deduced bindings never contribute to that
context: each argument remains independently synthesized as D138 requires, so
repeated-formal agreement is identical in either source order. Ordinary
call validation may revisit the literal, but accepts the prior answer only
when kind, view, permission and complete referent identity agree; a different
identity remains a mismatch, and `Landin.Checking.Note` keeps its once-only
contract. `runtime/generic-contextual-text-literals` compares inferred and
explicit calls for `utf8`, `utf16`, `cstring` and ordinary byte literals,
observes their runtime data, and pins once-only argument and callee effects.
The `negative/generic-text-literal-*` cases retain read-only permission and
Unicode/byte-escape validation; the two `generic-text-literal-repeated-*`
cases pin the same exact conflict with the literal before and after a `utf16`
actual. This implements [0260]/[0270] for a context the signature or explicit
static tuple already states and changes no language rule.

The earlier literal-deduction reference-publication observation is superseded
by `runtime/generic-text-literal-deduction` on the integrated checker. A text
literal itself deduces the default `utf8` item in block and expression-bodied
generic identity routines with an exact `from` clause; empty input preserves
the same result identity. A separately typed `utf16` actual retains its own
identity. The case observes exact lengths and call counts, complementing the
contextual-literal and repeated-formal refusal controls above.

The bounded runtime-text increment implements D199's four exact ordinary
source-derived conversions between immutable byte slices, `utf8` and
first-NUL `cstring`. The descriptor matrix rejects mutable sources/results,
`utf16` representation conversion, an unmatched optional C string and
pointer-to-cstring extent invention;
successful and empty conversions preserve the actual base, permission and
origin. Byte-to-text and C-to-text validate shortest-form UTF-8 and direct
conversion traps on malformed input, while ordinary `core/text.from_bytes`
and `from_c` report `invalid_text`. Foreign cstring scalar traversal performs
the same validation before decoding, including in `unchecked`, and never reads
past the first NUL. Literal pooling retains its stronger valid-encoding
construction.

`core/text` now supplies exact byte equality and substring search, checked
decimal `u32` parsing, source-derived byte views, and caller-buffer byte and
decimal writers. Decimal overflow is reported before arithmetic can trap, and
writer capacity is preflighted before mutation. The prototype-4 configuration
sketch recovers or propagates every fallible C-text conversion without losing
its `escaping args`/`from args` contract; its file-line matcher treats malformed
bytes as no match, separately from `--every` decimal recovery. Runtime evidence
covers empty, ASCII, multibyte, embedded-NUL, malformed, truncated, overlong,
surrogate and out-of-range input, zero/maximum/overflow decimal values,
substring edges and refusal-preserving output. A fixture publishes an argument
as a foreign `cstring`, then uses the existing explicitly unsafe
integer-pointer round trip to install `C2 00` followed by an ignored byte; its
byte scan yields one byte, checked UTF-8 rejects it, and traversal traps even
inside `unchecked`. This adds no pointer-to-cstring conversion. No allocator,
text opcode, core-name privilege, mutable alias or origin erasure is introduced.
Matched-present optional C text retains its view and converts normally; both
carrier forms also pin that a terminating source emits no later conversion
work, while successful effectful sources run exactly once.

The initialized-allocation library adds ordinary `mem.new`/`delete`: allocation
is followed by a complete typed store of the supplied escaping value, including
reference-containing and zero-sized objects. It promises no generic zero image.
The byte-buffer owner stores its initialized witness and allocation extent
privately; `new_bytes` initializes every byte before publication, while an empty
request makes no provider call. `drop_bytes` clears the owner before freeing the
saved original base and extent. Unexpected admission refusal rolls back with
the saved allocation rather than inferred or fabricated storage metadata.
Focused heap/failing-provider evidence covers initialization, failure, exact
free identity, surviving neighbors, repeated empty disposal and borrowed-view
refusals. The P4 construction contract marks retained argv backing escaping;
a borrowed-text aggregate refusal pins that requirement. The finalized
initialized-prefix prerequisite is integrated. Complete pinned Linux debug and
release suites each pass 403 cases and 10,842 checks, and the font-aware
repository check is clean. The authoritative native integration gate remains
required after publication; full P4 application cleanup is not claimed here.

The vector-view and sort increment uses ordinary `vec.used` to expose the
initialized prefix `from value`. `core/sort` supplies the exact `ordered.less`
concept and a bounded-stack, allocation-free selection sort; the caller must
supply a strict ordering and stability is not promised. Runtime pressure
includes empty, singleton, reverse, duplicate and already sorted views, twenty
numbers and their squares, and copied pointer/heterogeneous `any` traversal.
The prototype traversals now use `vec.used`: [1320]'s source-free `item` entry
cannot implement a storage-derived reference result, and the exact mismatch
has a negative control. No universal vector `iterable` conformance or origin
cut is introduced. The scalar traversal-origin repair and initialized-prefix
prerequisite are integrated. The font-aware invariant check is clean, and
complete pinned Linux debug and release gates each pass 403 cases and 10,838
checks on unchanged source. Authoritative native execution remains required
after integration and publication.

The index-tree increment uses append-only nodes and explicit retained-name
contracts. Its node ID is a private single-`u32` nominal wrapper, with explicit
construction/extraction; [0650]'s general `distinct` syntax stays refused.
Branches may select only existing contiguous children. Empty branches count
zero, and shared children count with path multiplicity. A checked cached `u32`
leaf total avoids recursion and refuses overflow before mutation. Neither
integer edges nor the cache erase the `utf8` names' backing origins, and no
serialization claim follows. Source-built Linux preflight covers heap, arena
and fixed-provider allocation failure/retry, unchanged IDs and names, exact
release accounting, and cached leaf-count overflow before mutation. New
negative controls refuse retained frame names, escaping borrowed nodes and
out-of-range ID literals. With the reviewed generic-call text-literal repair,
the original runtime also executes deep chains, shared and empty branches,
retained names after growth, and invalid child ranges. Complete pinned Linux
debug and release gates each pass 404 cases and 10,855 checks on unchanged
source. The font-aware repository check is clean; authoritative native
validation remains required after integration and publication.

Tree clients use immediate content assertions, ordinary scalar-returning
length helpers and explicit call-site error forwarding. A direct saved `lenof`
can retain its operand's origin and encounter false L0315 across later mutation;
the scalar call-result and member/index repairs do not settle that operator.
R4.70 owns this remaining scalar-operator origin normalization. The later
local aggregate-`try` repair below supersedes only the initializer observation;
its runtime pins the admitted local call destination without claiming every
aggregate transport shape or the complete P3-derived program.

The bounded map increment selects D198's initialized bucket plus dense-prefix
representation. `core/map` provides its own composed `equatable`/`hashable`
concepts and ordinary construction, insertion, lookup, removal, length and
release. Pointer K/V instances require no zero image. Every probe is bounded.
Insert searches for and updates an existing equal key before consulting load
pressure or the allocator; an absent-key placement remembers the first
tombstone. Hash reduction stays in `u64` until after modulo, and nonoverflowing
pressure counts both live and dead records. Rehash preflights all three extents,
acquires and migrates privately, publishes last, and makes no fallible call
after that point. The three injected acquisition failures free exactly zero,
one and two new extents while the old map remains intact, and each retries
successfully on the reclaiming six-slot pool. Successful growth and final
release each free their three owned extents exactly once. The same runtime
first replaces a key after a tombstone at six-of-eight pressure with an
allocation budget of zero; length, provider attempts and live extents stay
unchanged.

The map remains a public composition rather than an encapsulated abstraction:
its storages and counters are fields, `mem.used` exposes initialized K/V entries
including dead dense positions, and inferred views can copy opaque whole bucket
records. The private bucket identity and opaque raw representation do not hide
that state. Composition below the public map operations therefore carries the
manual obligation to preserve equal capacities, full bucket initialization,
paired dense prefixes, one valid used/dead record per dense position, and exact
counters. Equality must be an equivalence relation; equal keys must hash
alike; and both results must remain stable while stored, including across
mutation reached through a pointer/reference key. None of these laws or map
invariants gains compiler enforcement or a deep-safety claim.

The only compiler-surface reductions encountered were existing enabled-kernel
boundaries, not missing map semantics: a generic-call aggregate actual needs a
typed local before the call; a generic returned struct containing an atom union
is still outside the substituted-field shape admitted by R2.20; and the arena
fixture's first collision hash tried to discard its whole struct argument,
whose value use R2.20 does not enable, before reducing to an ordinary scalar
field read. D198 therefore uses typed bucket temporaries and a private scalar
bucket tag, while the fixture computes its constant collision from the key's
scalar identity. It does not widen contextual aggregate arguments,
parameterized struct fields, raw storage, origins or permissions, and it does
not duplicate the separately owned contextual text-literal staging work.

The bounded erased-recovery staging follow-up addresses a dependency exposed
by the hosted world capability. An explicitly typed result or statement call
could reach error inference before its erased interface was synthesized,
leaving a named recovery binding without a storable atom type. Inferred result
bindings had already synthesized the same interface. Missing erased member
signatures are queued by source node and generic overlay during discovery.
Direct typed `any` initializers first materialize their contextual concrete
conformance, including parameterized providers. Rechecking a successful
construction reuses only its same concept and evidence identity. The queued
interfaces then pass through ordinary synthesis before error inference sizes
its graph, preserving once-only dispatch metadata, the concept's exact labels
and declared errors. Error closure asserts that its signature inventory does
not grow. A checker regression inspects recovery binding types and
error sets; runtime controls cover typed, inferred and statement calls, exact
error identity, rethrow and `try` propagation through outer recovery,
successful calls and once-only dispatch. The parameterized-provider runtime
places its erased consumer before the construction, uses two concrete generic
overlays and an effectful construction operand, and recovers the exact provider
error through named rethrow. Discovery of contextual constructions in fields,
assignments, returns and arguments is not established by this direct-binding
seam. An unhandled typed call remains refused. This changes no language rule
or I/O contract. Complete pinned Linux debug and release gates each pass 405
cases and 10,909 checks on unchanged compiler source and fixtures. The full
font-aware document check passes; authoritative integration remains required.

The initialized-view implementation must also retain [0860]'s shallow alias
limit: a reference inserted through an alias is not generally propagated back
to every other view of that storage, so writable views do not establish
whole-program escape safety.

The bounded storage-address origin repair distinguishes a reference descriptor
from the storage it addresses. `addr` through a slice index or pointer
dereference retains the source reference's local origin facts, including
through local descriptor aliases and subsequent field/array selections.
`runtime/derived-storage-address-origin` pins reads, writes and once-only index
evaluation; `runtime/derived-address-empty-slice-traps` retains the dynamic
bound check. The `negative/derived-address-*` cases retain frame-array and
local-descriptor refusals, exact `from`, permission, escaping and live-view
checks. This repairs the monomorphic prerequisite for initialized views without
changing [0860]'s shallow alias limit or using an untracked pointer conversion.

The array-shape fixtures consume their slices locally; they do not waive the
return-source obligation or select the constrained owner alternative. The
separate storage-origin and constant nested-store repairs retain their own
fixtures and scope alongside this shape transport.

The bounded fixed-array-view origin follow-up applies that same storage walk
when a range slice publishes a view of a fixed array. Direct local storage,
inline local fields and by-value array parameters remain frame-origin, while a
fixed array reached through a pointer dereference or slice element inherits
the descriptor's exact source facts. `runtime/derived-array-slice-origin`
retains pointer aliases, nested slice-element selection, mutable and read-only
views, the empty case, content sentinels and observable mutation. The four
`negative/derived-array-slice-*` cases pin local, local-field, by-value and
wrong-`from` refusals. This is an origin-analysis repair only: it changes no
array normalization, lowering route, reference permission or ownership rule.

The retained-wrapper composition also preserves a nominal result inferred
through `try` before generic-call discovery. Explicit static argument positions
are excluded from runtime argument origin mapping, so a named type argument
cannot hide the source named by `from`. `runtime/try-nominal-inference` checks
local generic pointer use and error propagation; the explicit generic frame
negative and `negative/core-failing-frame-escape` retain L0314.

The bounded scalar-call origin repair transfers a one-result signature's
written `from` facts only when the concrete result part contains references.
This lets a generic result instantiated as `u32` remain an ordinary copied
value across a later `inout` use of its source, while the call's escaping and
borrow argument checks still run before result construction. Pointer, slice,
`any` and reference-containing aggregate results retain their exact source
facts. `runtime/generic-scalar-result-origin` exercises the accepted scalar
instance; `negative/generic-pointer-result-live-view` applies the same generic
to a pointer and retains L0315; and
`negative/generic-scalar-result-escaping` retains L0314 at the argument
boundary. This repair is deliberately confined to call results. The separate
scalar-selection defect is closed by the following increment, preserving
reference-bearing results rather than erasing their origins.

The bounded scalar-selection follow-up closes that recorded defect for
concrete scalar member and element values only. Reference checking still
visits the selection target and every index operand, so nested calls retain
their escaping and borrow checks, but a result in [1790]'s `Scalar_Name` band
contributes no storage-origin fact to the copied value. Pointer, slice, `any`
and reference-containing aggregate selections retain the prior facts; `addr`
and range slicing continue through their storage-origin paths with exact
`from` agreement. This is whole-value classification, not field-sensitive
alias analysis, and it neither erases general origin facts nor changes place
evaluation or lowering. `runtime/scalar-selection-copies` observes composed
pointer-backed field comparisons after sinking the pointer and a copied slice
element after advancing the descriptor.
`negative/selected-pointer-live-view` retains L0315 for a selected pointer;
`negative/scalar-selection-operand-escaping` retains argument checks in a
nested target and direct index; and
`negative/scalar-selection-derived-origins` retains L0316 for both an address
and a range that claim the wrong source.

The bounded scalar-traversal follow-up applies the same whole-value boundary
at D160's ordinary array/slice element binding. The traversal source is still
evaluated through reference checking before the element is classified, but
its fact is installed on the loop binding only when that binding's concrete
type contains references. Scalar arithmetic therefore cannot turn an
accumulator into a false live view of the traversed storage. Pointer, `any`
and reference-containing aggregate elements retain the source fact through
the existing descriptor classifier, and D180's evidence-driven iterable item
remains source-free. This is confined to the `For_Statement` origin mapping;
it adds no general scalar-fact erasure or field-sensitive alias claim.
`runtime/scalar-traversal-values` observes a squares accumulator after sinking
the fixed storage behind an ordinary scalar slice;
`negative/reference-traversal-value-live-view` retains L0315 for a pointer
element; and `negative/scalar-traversal-source-escaping` retains L0314 for a
call nested in the traversal source.

The bounded initialized-prefix transfer follow-up closes the remaining
fixed-array selection metadata defect. A typed local fixed-array initializer
may name one complete element reached through a member-and-element storage
chain; concrete generic checking now visits that chain and records its slice
type and field index before lowering. Module initial images retain their
direct-name-or-field restriction. The
`runtime/r420-generic-array-selection-transfer` case copies an actual
`[0]u8` item and a nonzero `[2]u8` control through slice-backed generic
selection, observes the selecting call once, recovers an out-of-range request
before that call, and checks the exact source, destination neighbours and
guard values. This is checker metadata completion, not a zero-extent skip or
the separately owned place-evaluation repair.

The scalar index directly chained onto a pointer- or slice-backed fixed-array
element now follows the existing addressed-storage path rather than treating
its reference boundary as a named field. `runtime/reference-array-scalar-index`
checks constant and computed indices, once-only selector/index effects, local
recovery and propagated index failure. The array-valued struct-member range
composition remains a distinct nested-array field representation dependency,
owned by R4.70. R4.20's transfer uses genuine direct array backing and typed
array copies, as its fixture shows; this does not claim nested-array field
range normalization or substitute byte carriers for zero-sized items.

The bounded small-vector increment implements `core/small.small(item, N)` with
the written closed-family `item is zeroable` constraint and an initialized
inline `[N]item`. Its variant's spilled arm owns a `core/vec.list(item)`, so
the first spill reserves, copies the inline prefix and admits the new item in a
private list before publishing the arm, while every later growth uses D194's
checked vector protocol. Zero inline capacity grows first to eight; a nonzero
capacity is doubled only after the `usize` bound. `used` returns only the
initialized mutable prefix `from` the inout container, `pop` removes one tail,
and `release` frees a spilled extent before restoring the empty inline arm.
The constraint deliberately continues to reject pointer items: D151 solved
general raw storage for `vec`, not the honest initialized image required by
the inline array.

Three finite compiler composition repairs were required by that ordinary
source. Match payload bindings keep separate value and storage facts. A
reference-carrying payload value retains the matched subject's value origin,
while a scalar payload copy carries none. Storage selected below a payload
alias follows the actual lowering place: named local and by-value storage is
frame-origin, named `inout` storage retains its parameter source, and a
computed or pointer/slice-backed match follows lowering's independent frame
copy. A result source whose formal is `inout` derives from the argument place
rather than only from references already carried in its value; this is what
makes an inline returned slice frame-origin and live against a later mutation.
Finally,
runtime-address array aliases distinguish an ordinary traversal binding from
a variant payload before forming indexed loads/stores, and ordinary
scalar/reference fields copied while publishing an aggregate payload form
addresses through the existing neutral field/case path. Variant matching's
subject policy is unchanged: computed and pointer/slice-backed subjects retain
their independent one-time copy. No source pointer, target offset, `core`
privilege or deep alias propagation is added. The existing
`runtime/derived-parser` and `runtime/for-aggregate-element-traversal` cases
pin those two boundaries alongside the new small-vector execution.

`negative/variant-match-copied-array-view-escape` refuses returned array
payload views for pointer-backed, slice-backed, local and by-value matches;
`negative/variant-match-reference-payload-live-view` retains the corresponding
reference-value borrow across mutation. `runtime/variant-match-origin-channels`
accepts a scalar payload saved across mutation, a returned view into genuine
named `inout` match storage, and actual reference payloads copied out of both
pointer-backed and slice-backed match temporaries. This is the shallow split
[0860] requires: it neither treats scalar copies as views nor makes temporary
payload storage outlive its match frame.

`runtime/r420-small-vector` covers N=0, N=1 and N=3, no provider call below
the inline bound, writable initialized views, first-spill and later-growth
failure with retry, exact freeing extents, pop and release.
`runtime/r420-small-vector-providers` runs spilled and growth paths through the
host heap, monotonic arena, reclaiming fixed pool and counted failing wrapper;
the pool rejects any mismatched free extent. `negative/core-small-live-view`,
`negative/core-small-frame-view` and `negative/core-small-pointer-item` pin
borrow blocking, inline frame escape and the written zeroable boundary.

The aggregate zeroable domain is exercised by `runtime/r420-small-aggregate`.
Fixed-array match payload bindings now retain their element's nominal identity
beside length and scalar/reference shape, so `small.push`, `used` and `pop`
agree on the ordinary struct item. The case mutates inline and spilled views,
pops in both states, grows beyond the first spilled allocation, verifies the
preserved prefix, releases all allocations, and reuses inline storage. This
is ordinary match metadata completion; it grants no library privilege.

Generic-only erased constructions are inventoried under each ready routine
view before lowering maps evidence. `runtime/generic-any-construction-evidence`
constructs a composed concept only inside a generic routine, instantiates two
heterogeneous providers, calls parent and child entries and checks independent
state. The base-view inventory had missed these constructions. The repair
preserves ordinary conformance/provider selection and flattened closure order;
lowering neither synthesizes nor instantiates additional routines.

Runtime-text source obligations have explicit refusal evidence:
`negative/text-conversion-wrong-from` pins all four ordinary conversion paths;
`negative/text-empty-conversion-frame` retains frame origins for direct and
checked empty conversion; `negative/core-text-adapter-wrong-from` checks the
recoverable adapters, including an empty slice; and
`negative/core-text-written-frame` retains the backing of an empty written
prefix. These are L0314/L0316 controls for existing D199 source semantics.

The bounded erased-argument save repair completes [0410]'s existing call
staging for `any`. An erased actual is already passed by the address of its
two-word descriptor; when a later runtime actual may change blocks, lowering
now saves that address in the same `usize` carrier used for aggregate,
fixed-array and slice addresses rather than asking the erased value for a
nonexistent scalar carrier. `runtime/any-argument-save` exercises positional
and reversed named/formal order with once-only effects, an erased field loaded
through a pointer, and a later propagated failure that prevents both the call
and following statement. Dispatch, source evaluation order, termination and
origin rules are unchanged.

The hosted-world increment applies D146 directly to `core/io.world`: every
entry receives an exact self pointer, the system conformance works through
`any world`, and generic wrappers remain for statically known providers. The
private system value stores the actual `argv + 1` table and bounded user count;
capability-aware indexed bridge lookup takes that table explicitly, so
`argument from self` is a real source-derived contract shared with the
caller-backed memory provider, not an annotation over hidden global storage.
Its distinct symbol leaves the established one-index foreign helper unchanged.
The public argument remains the
bounded pointer-and-length descriptor already used by hosted clients. It does
not become `cstring` merely because the system instance happens to point into
C argument backing, and no integer-created pointer is used to fabricate its
origin.

Write-open is the narrow libc bridge for `O_WRONLY | O_CREAT | O_TRUNC` with
mode `0666` and the process umask. Both opens distinguish `ENOENT`,
`EPERM`/`EACCES`/`EROFS` and other failures. Writes iterate with bounded stack until
the offered slice is complete and reject zero progress, the failure sentinel
or an oversized host count. Public `open_read_text`/`open_write_text` obtain a
byte view through `core/text`, then share the byte adapters that validate empty
input, embedded NUL and caller scratch capacity
before copying or appending the terminator; there is no allocator or silent
truncation. D133 gives cleanup precedence: a close failure is `io_failed` on
an otherwise successful path but cannot replace an already propagating atom
when close runs as `undo`.

`core/diag.streaming` now retains a pointer to an erased world and a borrowed
file, so delivery is provider-independent while both retained addresses keep
their ordinary origin obligations. The derived parser and logger dispatch
clients use the same dynamic route. `runtime/core-io-erased-system` covers the
argument boundary, EOF, read/write open, exact output, empty writes, missing
and denied paths, `/dev/full`, close and byte/UTF-8 path validation. The scoped
`negative/core-io-*` and `negative/core-diag-frame-world-escape` cases retain
receiver permission, sink consumption and logger retention refusals. The
separately recorded erased-recovery staging and erased-argument address-save
repairs are prerequisites, not I/O-specific compiler behavior. The following
memory-world increment supplies deterministic short-write schedules,
in-memory handles and output ownership.

The bounded memory-world increment supplies an ordinary `core/io.memory`
conformance from caller-owned file, argument and output tables. D153 records
its first-match existing-file policy, bounded transfers, zero-progress
refusal distinct from true EOF, partial-write prefixes, injected close
semantics, empty no-ops and manual backing, nonoverlap, counter and copied-
handle obligations. Construction, argument lookup and written-output views
retain their exact source clauses. `runtime/r420-memory-world` and
`runtime/r420-memory-world-boundaries` execute short reads, true EOF, failure
atomicity, partial writes, exact output, standard streams, injected failures
and zero-limit boundaries without ambient host state.

`core/io.copy_argument` bridges the public pointer-and-length argument shape
to ordinary text without manufacturing a slice: it preflights exact caller
scratch, copies into its initialized prefix and returns that view `from`
scratch. Valid source backing, representable address arithmetic and
source/destination nonoverlap remain caller obligations.
`runtime/r420-argument-text-worlds` runs the same copy,
`text.from_bytes` and numeric validation through system and memory worlds;
both sequences exclude `argv[0]`. The dedicated frame refusal retains the
scratch origin. `runtime/r420-reader-cleanup` executes open-then-allocation
failure, successful consumption, read/close failure precedence, exactly-once
handle cleanup and exact buffer frees. `runtime/r420-stateful-filter-list`
retains two mutable evidence identities across vector growth, and
`runtime/r420-memory-delivery` runs two erased delivery implementations plus
the repository `core/diag.streaming` logger against the supplied memory
world. These complete library clients do not complete R4.80's application,
command-line parsing or arbitrary-length line policy.

D196 settles D191's inherited construct rows. [0500]'s `mem.offset` and
`mem.base_of` are unneeded conveniences for this slice: existing [0470]
address conversion and checked element addressing serve their actual callers.
D151's `slice_from` remains rejected. [0810] now describes the conversion
that actually ends tracked derivation, with no privileged `core` name.

Both [0820] forms, the lexical block and builtin parameter type, remain
refused by name against R4.80. That item inherits all four D191 questions:
type and allocator conformance without frontend dependence on `core/mem`;
backing authority and capacity on hosted and constrained targets; exhaustion;
and the direct-frame/helper-independent origin relationship. It also owns the
counterexample W7's historical proof misses: a helper can retain an allocated
pointer in module state without returning it through the lexical boundary.
R4.80 must settle that behavior before the complete application and hosted
gate. This handoff creates no reverse dependency and enables no region syntax.


Sources: legacy B5, which had no tracked citation; `[0500]`, `[0810]`,
`[0820]` and `[1360]`, re-owned here by D191.

Increment evidence: `runtime/core-mem-allocators` retains the original arena
and failing-provider behavior, while `runtime/core-mem-arena-boundaries` pins
absolute alignment, failure atomicity, exact exhaustion and checked arithmetic
at the target `usize` boundary.

Vector increment evidence: `runtime/r420-vec-capacity-boundaries`,
`runtime/r420-vec-growth-boundary`, `runtime/r420-vec-growth-transaction`,
`runtime/r420-vec-large-list` and
`runtime/r420-fixed-array-pointer-whole-copy` pin D194 and its compiler
composition repairs. Existing `runtime/core-vec-pointer-storage` remains
regression evidence. `runtime/variant-match-array-payload-bindings-update-storage`
adds scalar accumulation and a generic element call inside payload traversal;
`runtime/r420-runtime-array-writes` checks literal/mixed writes through pointers
and computed array destinations, sentinels and evaluation counts;
`runtime/r420-array-place-recovery` checks destination/source pointer recovery
and slice-index recovery, including all-return operands and suppressed RHS/copy.
`runtime/r420-static-nested-array-stores` checks literal and mixed repetition,
whole copy and fill through first and last constant array indexes, plus
containing-struct fields, sentinels, evaluation counts and both nested
fixed-array bounds.

D195 supplies the hosted allocator lane: `core/heap` is a separately imported
libc-backed provider over [1975]'s fixed scalar/pointer runtime seam. Its
alignment, zero-size, maximum-size and failure policies are recorded there;
runtime audit evidence observes simultaneous vector extents and exact release.
It adds no dependency to the freestanding `core/mem` protocol or its
caller-backed providers.

D197 supplies the finite and deterministic test lanes. `core/pool` takes
explicit caller backing, uniform slot size/alignment/count, and a caller-owned
initialized metadata slice whose length is the finite bookkeeping capacity;
exact free reclaims a slot and no hidden heap can extend it.
`core/failing.counted(A)` retains an ordinary mutable pointer to any supplied
provider, including a local pool or hosted heap, and distinguishes injected
failure from delegated inner failure while forwarding every free. Runtime
evidence covers a six-live-slot map-rehash bound and pointer-vector rollback
and retry without putting an allocator in the container.
For tracked base and metadata actuals, `from base, bookkeeping` joins both
origins. D197 also records the existing whole-value Untracked-OR limit: an
integer-derived base makes the returned provider untracked, so the checker
does not independently enforce a tracked metadata origin in that mixed case.

D198 supplies the open-addressed map lane. `runtime/r420-map-operations`
executes explicit composed evidence, pointer key/value migration, collisions,
wraparound, a preceding-tombstone update, churn, growth and bounded missing
searches through deliberately full and all-dead bucket records.
`runtime/r420-map-arena` separately executes the actual `core/mem` monotonic
arena: collisions, replacement, deletion and growth precede bounded arena
exhaustion; the failed growth preserves the old logical map, and release resets
the map while the arena's no-op free leaves its used offset unchanged.
`runtime/r420-map-failure-rollback` executes allocation failures one, two and
three over D197's counted reclaiming provider. Before each failure it replaces
an existing key after a preceding tombstone at the growth threshold with zero
allocation budget and no provider attempt. It then proves exact rollback and
old contents for an absent key, retries each case, checks every exact free
through the pool, and finishes with no live allocation.
`negative/core-map-missing-parent-conformance`,
`negative/core-map-key-frame-escape` and
`negative/core-map-value-frame-escape` retain the separate parent evidence and
escaping insertion boundaries.

The allocator acceptance matrix is recorded here as a durable mapping from
each workload and provider column to the fixture that executes it. Every
fixture named below reaches the repository-owned `core` modules through its
`root` metadata rather than carrying a fixture-local copy, and each cell is
executed behavior rather than a compiled generic instance.

| Workload | Heap | Arena | Fixed pool | Failing wrapper |
| --- | --- | --- | --- | --- |
| provider contract | `runtime/hosted-heap-provider` | `runtime/core-mem-arena-boundaries` | `runtime/r420-pool-provider` | `runtime/r420-failing-providers` |
| `list(pointer)` | `runtime/r420-reference-provider-matrix` | `runtime/r420-list-real-exhaustion` | `runtime/r420-list-real-exhaustion` | `runtime/r420-reference-provider-matrix` |
| `list(any)` | `runtime/r420-reference-provider-matrix` | `runtime/r420-list-real-exhaustion` | `runtime/r420-list-real-exhaustion` | `runtime/r420-reference-provider-matrix` |
| `small(zeroable, N)` | `runtime/r420-small-vector-providers` | `runtime/r420-small-real-exhaustion` | `runtime/r420-small-real-exhaustion` | `runtime/r420-small-vector-providers` |
| `map(K, V)` | `runtime/r420-map-reference-providers` | `runtime/r420-map-arena` | `runtime/r420-map-reference-providers` | `runtime/r420-map-failure-rollback` |
| tree | `runtime/core-tree-provider-failures` | `runtime/r420-tree-real-exhaustion` | `runtime/r420-tree-real-exhaustion` | `runtime/core-tree-provider-failures` |
| initialized objects, byte buffers | `runtime/r420-object-buffer-providers` | `runtime/r420-buffer-real-exhaustion` | `runtime/r420-buffer-real-exhaustion` | `runtime/r420-object-buffer-providers` |

An injected refusal from `core/failing` is evidence about the wrapper column
and about container rollback. It is not evidence that an inner provider was
exhausted, so the arena and fixed-pool columns are carried by fixtures whose
refusals come from the backing extent or the slot count themselves.
`runtime/r420-list-real-exhaustion` runs both list rows through the same two
shapes. It spends an arena on two growths and has the third refused, then uses
a one-slot pool to show that a vector growth needs the old and the new block
at the same time and a two-slot pool to show the same growth succeeding; the
released slot is reused by a later list. The pointer row checks every stored
address and pointee after the refusal; the `list(any)` row checks that every
retained descriptor still dispatches to the pointee it was built over, with
the erased values constructed in `main` and passed in as escaping arguments
so that [1380]'s explicit construction is not what is under measurement.
`runtime/r420-small-real-exhaustion` covers both states of the spilled path
with real extents: a refused first spill leaves the inline arm, its count and
its capacity unchanged at zero and at nonzero inline capacity, a refused later
growth leaves the spilled arm and its contents unchanged, and one pool slot
limits the spill until an exact free lets a second container reuse it.
`runtime/r420-buffer-real-exhaustion` consumes an arena to its exact extent and
then observes that a refused buffer binds no descriptor and that a refused
object takes the failure arm, whose caller-supplied fallback is null rather
than an allocator result. A neighbouring buffer is taken again and checked
intact after each of those two refusals, and the arena offset never moves. Its
pool case covers zero, one and full occupancy, refusal by slot count and
separately by slot width, and reuse of an exactly freed slot.

`runtime/r420-reference-provider-matrix` runs a pointer list and an
`any counter` list through the heap, arena and pool under the counted wrapper:
the initial and growth refusals leave length, capacity and contents unchanged,
retry succeeds, stored pointees and erased dispatch survive, and every extent
is freed exactly once. `runtime/r420-map-reference-providers` runs pointer keys
and values with a deliberately colliding hash through the same three
providers, replaces a key after a preceding tombstone at the growth threshold
with no allocation budget and no provider attempt, and fails replacement
allocations one, two and three separately with the matching rollback frees.
`runtime/r420-object-buffer-providers` covers zero-count buffers, a refused
object whose initial value was still evaluated, aligned pointer-containing
objects, written byte buffers, repeated disposal and retry.
`runtime/r420-tree-real-exhaustion` exhausts a node-sized arena and a one-slot
pool, checks that the refused leaf and branch appends leave the count,
ordinals and names unchanged, and reuses the pool slot after release.

R4.20 delivers the reusable hosted library slice and bounded pressure clients.
The following is the API correspondence for the live prototype sketches; it
does not claim that their ellipses form complete programs.

| Required surface | Delivered API or equivalent | Deliberate boundary |
| --- | --- | --- |
| Allocator authority | `mem.allocator`, caller-backed `arena_over`, `pool.over`, `heap.host`, `failing.count_down` | Containers receive the provider on allocating/freeing operations; no stored allocator, implicit cleanup or hidden heap fallback. |
| Initialized storage | `mem.storage`, `reserve`, `admit`, `replace`, `get`, `transfer`, `used`, `release`, `dispose` | Only the initialized prefix is exposed; raw backing and alias writes retain D151's unsafe obligations. |
| Initialized objects/buffers | `mem.new`/`delete`, `new_bytes`/`bytes`/`drop_bytes` | Values are initialized before publication; explicit release retains the original extent. |
| Vector and sorting | `vec.new_list`, `reserve`, `push`, `pop`, `get`, `used`, `release`; `sort.ordered` with strict `less`, and `sort.sort` over a writable slice | Sorting is allocation-free, bounded-stack and unstable. `vec.used` supplies source-derived traversal; D180's source-free iterable item cannot promise retained pointer/any origins. |
| Small vector | `small.new`, `push`, `pop`, `used`, `release` | Inline items retain the written zeroable constraint; aggregate zeroable items execute. |
| Map | `map.new_map`, `insert`, `get`, `remove`, `release_map` | D198's public bucket/dense-prefix composition, explicit hash/equality laws and three-stage transactional rehash. |
| Tree | `tree.new_tree`, `add_leaf`, `add_branch`, `get`, `count_leaves`, `release` | Nominal u32 IDs, checked existing child ranges and retained UTF-8 names; no serialized-pointer claim. |
| Runtime text | Exact D199 conversions; `text.from_bytes`, `from_c`, `bytes`, `eq`, `contains`, `to_u32`, `write_byte`, `write_u32`, `written` | Checked UTF-8, exact byte equality and decimal u32; no normalization, locale, regex or general formatting. |
| Hosted I/O | Object-safe `io.world`, generic wrappers, `io.system`, `io.memory`, read/write opens, reads, writes and close | Provider-local copyable handles and manual cleanup; no generational ownership guarantee. |
| Paths and arguments | `terminate_path`, byte/text open wrappers, `copy_argument` followed by `text.from_bytes` | Explicit caller scratch; no fabricated slice, implicit terminator storage or truncation. User arguments exclude argv[0]. |
| Diagnostics and application pressure | `diag.bounded` for retained diagnostics and `diag.streaming` through the supplied world; reader cleanup, stateful erased filter list and delivery clients | Named runtime evidence covers bounded composition, not the complete P4 application. |

Freestanding `core/mem`, containers, pool, sort and text use ordinary source
capabilities. Importing them does not import `core/heap`. The explicit hosted
heap and system world use libc through [1975]'s fixed scalar/pointer bridge;
R4.20 adds neither raw-syscall policy nor the general foreign ABI owned by
R4.40. The memory world has caller-owned backing and no host calls or hidden
allocation. Actual freestanding deployment and execution remain R6.70;
this evidence establishes source layering and no implicit heap dependency.
D151/D197/D198's backing, alias, counter and public-composition
obligations remain visible; these APIs establish useful local checks rather
than ownership or transitive memory safety.

R4.70 owns the complete P3-derived program, full derivation mapping,
specialization/debugging integration and remaining nested-array field
representation/range composition. R4.80 owns the complete line reader across
chunk boundaries, long-line and final-unterminated-line policy; configuration
and argument retention; full filter/destination selection; arbitrary message
buffering and delivery/retry policy; and the four D191 lexical-arena questions
already transferred by D196. Neither a chunk-reader cleanup fixture nor a
caller-known suffix retry closes those complete application obligations.

The example refresh `da42169` landed after that closure and is not in its
counts: it added and rewrote running examples and their fixtures under the
completed slice, and R4.21's gates, which re-ran the complete debug and
release suites on the tree containing it, are its evidence.

Historical pre-rewrite closure evidence: reviewed integrated commit
`22c18b8` passes complete
pinned Linux debug and release suites, each with 405/405 cases and
11,070 checks. The full-font repository check is clean. Authoritative
native Linux [job 1882927](https://builds.sr.ht/~sinnfrei/job/1882927) passes
both build modes and repository checks on that same commit. These integrated
results supersede the increment-local gate notes above.

Exit evidence: containers run with heap, arena, fixed and failing allocators;
all omission and layering choices are recorded; `[0820]`'s block is either
enabled with the four answers above written down, or its refusal names the
item that inherits it.

### R4.21 — Repair review-found soundness and correctness defects

Status: complete
Depends on: R2.50, R4.10, R4.20

Two independent reviews of `da42169`, kept as local scratch notes while
the work runs and whose durable content is this section, reproduced
defects in slices already marked complete. This
item repairs them before R4.30 widens the language further. The work is
ordered by consequence: the language's own safety claims first, then silent
miscompiles and compiler crashes, then the gates that let them through.

1. Loop and traversal soundness in the flow and reference analyses. Escape
   checks did not traverse `if` and `while` conditions, nested call
   arguments, or `defer`; loop bodies were checked on a discarded copy so
   consumption facts vanished at the exit and no back edge was revisited;
   origin analysis assumed one body pass joined with entry was a fixed
   point; borrow liveness compared source offsets, so an assignment that
   never executed ended a borrow and a read above the mutating call in a
   loop body was invisible. R2.50's "facts only grow" reasoning is
   superseded: both lattices are finite and the analyses iterate to
   convergence over the actual execution edges, with no iteration cutoff.
   Repairing this exposed two further gaps and settled two readings. A
   binding made inside an expression-position block had no origin at
   all, and `break with` inside `complete` had no loop to leave;
   `runtime/core-mem-raw-storage` had read values out of frame-backed raw
   storage into `admit`'s escaping parameter, which [0840] refuses, and
   now backs its storage with module arrays. A borrower is a
   reference-bearing binding: a scalar computed from a view carries
   derivation facts for [0790] but is not [0830]'s "view derived from a
   local", which `positive/scalar-from-view-is-not-a-borrow` pins. The
   function-end return check runs only when the body falls through.
2. Checker correctness: `sizeof` of a nominal-element array folded to the
   element count; slice and `any` comparison reached lowering and raised an
   internal defect; pointers to different referents compared as equal types;
   a negative bitwise operand in a module-level range-subtype binding was an
   internal defect.
3. Lowering: an aggregate `in` argument was passed by saved address and
   copied when the callee started, so a later argument's side effect was
   visible to the callee, against [0410] and D94/D95. Narrow `extern(c)`
   scalars the checker already admits were passed without the 32-bit
   extension C callees rely on; the caller now sign- or zero-extends a
   one- or two-byte argument to a C callee into the 32-bit register, and
   into the whole slot on the stack, which is the x86-64 caller's
   obligation and one R5's arm64 contract states for itself. New C ABI
   shapes remain R4.40.
4. Literals and lexer: decimal `f32` literals delegated to the host float
   conversion and missed a rounding midpoint, against D162; decoding
   stopped at the first `\u{}` so a later malformed escape was an internal
   defect; iteratively parsed postfix chains escaped the nesting limit.
5. Gates: `check.py`'s code-rule pass selected a fence kind no document
   produces and so ran on nothing, including the untagged-fence rule; the
   tree-sitter grammar had no loop statement and its integration pass
   failed on 127 sources, so R3.80's all-source claim did not hold;
   `scripts/build.sh` compared the manifest only when one existed and had
   no lock, so a failed build was eligible for timestamp reuse and two
   same-tag runs corrupted each other. The repairs: the rules run over the
   `landin` blocks with module headings kept visible, and a bare fence is
   a fault; the structural grammar transcribes [1810]'s statements,
   [1130]-[1190]'s loops, transfers and `complete`, condition
   declarations, compound assignment, `unchecked`, range subtypes,
   pointer unions, `caller` parameters, scalar-headed expressions and
   every literal, and the compiler and `core` corpus parses clean; the
   build takes a per-tag-and-mode lock, records the toolchain on `PATH`
   and the scripts in its manifest, publishes the manifest atomically
   after both projects, and rebuilds from clean when it finds objects
   without one. The native tool runner bounds a run at ten minutes and
   reports one it stopped, so a fixture that never ends names itself; the
   driver refuses `--emit` or `-o` without a source and an empty
   `--root=`.

Document drift (thirteen scalar names, phase status, the macOS `test.sh`
verdict, tour and README inconsistencies) is exit evidence rather than a
numbered increment. A third review of the same commit read the register
and the prototypes: 41 decisions recorded a choice and a pin but no
alternative, two recorded evidence under another heading, and the
register's own promise was not held by any check. Every entry now names
its alternative and its pin, and `check.py` holds the register to both;
the prototype accounting, the R4.20 closure's scope over `da42169`, and
the highlighter vocabulary against the grammar's productions are held the
same way. Every fixture this item touches must fail on the defect
it pins; a negative whose code a wrong refusal could also raise carries its
expected text, and the 194 negatives that pinned bare `L0301` now carry
theirs and are executed. Fixtures land with their repair; the suite is never pushed
red.

Recorded elsewhere from the same reviews: `core/map` tombstone compaction and
entry enumeration (R4.70), `core/io` `errno` fidelity and `EINTR` (R4.40),
codegen-scale items such as the verifier's unreachable-island pass and the
stack probe (R4.50).

The last increment folds constants once: `Landin.Stages.Folding` is the
one walk both stages instantiate, the checker's `Fold` and `Fold_Float` and
lowering's `Fold_Constant` are wrappers over it, and the recorded IR corpus
was byte-identical before and after, which is the equivalence proof the
merge needed. The 194 negatives that pinned bare `L0301` are executed with
their exact reports, and the low rows of the second review are closed.

Historical pre-rewrite closure evidence: twelve commits from `5580220` to
`7814476`, each green on
the authoritative native gate, the last as
[job 1883339](https://builds.sr.ht/~sinnfrei/job/1883339). Complete pinned
Linux debug and release suites pass 410/410 cases with 11,856 checks on the
closing tree; the Mac suite is 409/410 with fixture execution red by
design; `check.py` and the full-font site render are clean;
`highlight/test.sh --integration` parses every compiler and core source.

Exit evidence: every reproducer the reviews shipped is a fixture with its
documented verdict; complete pinned Linux debug and release suites
pass; `highlight/test.sh --integration` passes on every compiler and core
source; `check.py`'s code rules run on the tagged fences and refuse an
untagged one; the authoritative native gate is green on the closing commit.

### R4.30 — Complete hosted modules and toolchain directives

Status: complete
Depends on: R3.10, R4.10

Implement the remaining ordered-root, fixed option, `landin/compiler`,
`landin/assembler` and `landin/linker` behavior needed by hosted programs.
Enable import aliases [1430] and selected imports [1440], and preserve
whole-program compilation.

The hosted scope retains D150's explicit ordered-root request. The companion
tool arranges project, user and system roots; this compiler does not invent
environment defaults. D201 extends the source-file import scope with aliases
and selected public declarations while retaining their original identities.
`runtime/import-alias-selected-identities` executes generic, type, concept,
error, variant and mutable-value references through both import forms;
`runtime/import-contextual-as` pins contextual spelling and qualified-only
namespace shadowing. Rooted negatives distinguish private/missing members,
duplicate bindings, immutable writes and private representations.
D202 adds unconditional global typed options, effective override defaults,
compiler target facts and assertions, and ordered static-library requests.
The new positive and negative configuration corpus pins invalid defaults,
cycles, inactive directives and exact builtin import refusals;
`runtime/r430-fixed-tools` executes the selected program and
`runtime/r430-static-library` calls `fegetround` from the platform archive.
The built-in module scope names deferred machine operations precisely:
inline assembly and section/entry placement remain R6.60, atomics R6.30.

Sources: `[1430]`, `[1440]`, `[1480]`, `[1500]`, `[1510]`, `[1530]`,
`[1540]`, `[1560]`, `[1590]`.

Historical pre-rewrite closure evidence: the tested implementation tree
`22f74589f212f64f6c08da810e35daf208826bb6`, based on `a9c44eba`, passes
the authoritative native Linux gate as
[job 1883395](https://builds.sr.ht/~sinnfrei/job/1883395). The job verifies
the source snapshot before running the ordinary clean build, complete debug
and release suites, document checks and compiler identity check. Both suites
pass 418/418 cases with 12,425 checks. The Mac suite passes 417/418 with
12,109 checks; only Linux fixture execution is red by design. Coverage,
catalogue, grammar, lexical and IR records are synchronized; `check.py`,
`highlight/test.sh --integration` and the full-font site render pass.
The independent review's remaining selected-import diagnostic continuation
refinement is recorded under R7.40.

Exit evidence: deterministic root and option cases pass; private caches expose
no stable interface.

### R4.40 — Implement the narrow complete C ABI and bindings

Status: complete
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

The selected contract is D203--D208 and [1975]: Linux x86-64 SysV AMD64
LP64, signed plain C char, guarded ordinary `core/c` aliases, C convention and
variadicness in recursive function identity, and independent import/body,
visibility and symbol facts. A standalone `link(symbol: text)` also names a
native Landin definition without changing its convention or making its body
optional. Private/public C definitions, C function types, explicit symbol
overrides, scalar/floating/callback transport, recursive nonempty `layout(c)`
structs, register exhaustion and inline stack records are in scope. The internal Landin calling convention and failure channel remain
unchanged.

The separate deterministic clang-AST generator owns header extraction and C
adapters for enums, unions, bitfields, globals, TLS, nullable callbacks and
schema-defined incoming varargs. Policy supplies facts headers cannot infer,
not handwritten replacement signatures. Native receiving-varargs definitions
and unsupported `va_list` forwarding, selected extended/x87 or 128-bit scalars,
complex, vector, atomic or volatile types, old-style or non-C-convention
functions, packed, overaligned, flexible or zero-size by-value records,
anonymous unaliased declarations, unsupported arrays, and unsafe, stale or
missing policy must fail explicitly. The required enum, union, bitfield,
global/TLS, nullable-callback and incoming-schema categories cannot be refused
wholesale as a completion shortcut. No native union/bitfield/TLS grammar and no
C or LLVM backend are introduced. `bindings/README.md` owns the current
invocation: it requires an
explicit Clang executable, target, sysroot, one or more relocatable header
mappings, policy and output directory, with include roots and definitions named
rather than inherited. Its `python3 bindings/test.py` route requires real Clang;
`check.py` only discovers and syntax-checks the Python entry points.

D189's former null-construction gap is addressed by refusing known zero after
target-width conversion, including folded zero, and trapping dynamic zero
always, including `unchecked`. Named pointer unions replace actual absent
allocator backing; no `ptr(1)` sentinel substitutes for an allocation.
Repeated `core/mem.dispose` reports `raw_empty`. On an optional return,
[0790]'s exact `from` comparison applies only when an edge actually returns the
reference; a provably empty arm has no origin and is not `Untracked`, as D189
requires. The derived parser consequently retains `from arena` on its optional
entry result and `escaping inout arena` on the allocating path. Its runtime case
now supplies real module-static arrays, while `negative/r440-parser-frame-arena`
records the continuing refusal of frame-backed arena authority.

The hosted provider captures errno before other C calls, retains exact terminal
detail in explicit state, retries only safe no-progress EINTR attempts and
consumes close exactly once.

The selected hosted bridge emits the global hidden ELF entry
`void _landin_host_initialize_arguments(int argc, char **argv);`. A normal
no-argument Landin `main` calls it with the incoming carriers before its body. A
C-owned startup driving an export-only unit calls it explicitly before
`io.host` or any thread that may acquire argument authority; startup-independent
bridge calls need no argument initialization, and exports and callbacks never
reset it. The first valid call retains the exact nonnegative-count,
non-null-table root without copying or allocation. Identical repetition is a
no-op; use before initialization, invalid input or root replacement traps. The C
owner keeps the table and strings live for every capability derived from them.

Implementation and verification are complete. Recorded source and library
cases include `positive/r440-c-aliases`, `positive/r440-c-signatures`,
`positive/r440-external-float`, `positive/r440-compatible-link-declarations`,
`negative/r440-link-does-not-change-convention`,
`negative/r440-parser-frame-arena`, `runtime/r440-c-aliases`,
`runtime/r440-errno-detail`, `runtime/r440-io-partial-progress`,
`runtime/null-pointer-dynamic-traps`, `runtime/null-pointer-unchecked-traps`,
`runtime/null-pointer-union-call-else`, `runtime/core-mem-dispose-empty`,
`abi/r440-bindings-generated`, `abi/r440-native-startup-initialized`,
`abi/r440-native-startup-empty`, `abi/r440-native-startup-uninitialized` and
`abi/r440-native-startup-replaced`. Clean local integration passes unfiltered
Linux x86-64 debug and release suites in the pinned Apple Container through
Rosetta, each with 486/486 cases and 14,795 checks. The clean Mac suite ran 486
cases with 485 passed, one failed and 14,423 checks; the failing case contained
only the expected missing-Linux-toolchain failures and zero compiler defects.
The pinned Clang 19 generator suite passed 41/41, full `check.py` passed, and
generated IR/layout records were refreshed. These local results remain
supplemental evidence. The authoritative native Linux x86-64 SourceHut gate
closed R4.40: `hut builds show 1884079` reports `SUCCESS` for
`c1efeb1d556b8407c9a8919787644f504b860214`, titled
"Implement R4.40 C ABI and generated bindings", with `checks`, `identity`,
`pages`, `toolchain`, `identify`, `build`, `test`, `release` and `bindings`
all passed, including clean debug and release validation. The job is
<https://builds.sr.ht/~sinnfrei/job/1884079>. That revision identifies the
pre-rewrite gate input, not an ancestor claimed in the rewritten history;
`origin/main` after the history rewrite is
`7bef5c0c67d35aa800847b9d22af1dfab1bcd2e4`. R4.50 was then active.

Sources: `[0480]`, `[0790]`, `[1580]`, `[1600]`, `[1610]`, `[1975]`,
legacy B2; `R§9`, `R§10`.

Exit evidence: ABI differential tests call in both directions; unsupported C
forms fail explicitly; generated declarations are deterministic; C-owned
startup proves initialized, empty, uninitialized and replacement cases against
the one retained argument root; `ptr(0)` is refused as [1580] states, with the
pointer union carrying what it stood for.

### R4.50 — Implement baseline code generation and specialization

Status: complete
Depends on: R1.70, R2.70, R4.10

Implement deterministic local simplification, instruction selection, a simple
register allocator and measured specialization after shared dispatch works.
Implement the explicit `layout(optimal)` field-reordering policy here, where
its size benefit can be measured without changing the source-order default.
Implement the amended normative specialization policy and build report without
claiming competitive optimization.

The selected contract is D209--D211: compact numeric array loops with retained
operand values; explicit stable optimal placement only on a strict padded-size
win; and independently controlled, evidence-proved specialization that retains
the hidden ABI. `unchecked` establishes no optimizer facts. Defaults are
`--optimize=size --specialize=auto`, independent of source build mode; none/off
is the explicit reference. The driver writes source-aware factual JSON through
the platform, never through the diagnostic stream.

Implementation and verification are complete. The
fixture-execution harness specifies four mandatory profiles for every runtime
and ABI case:
none/off, size/off, size/auto and speed/auto. Focused generic/erased cases add
none/all and speed/all. Each run must meet its own original exit/trap and exact
output oracle; a timeout cannot satisfy a trap. Source fixtures and their
runtime arguments are not rewritten to select profiles.

`compiler/tests/quality/check.py`, invoked by `scripts/quality.sh` in the
existing native gate for both compiler build modes, specifies numeric object
acceptance using gcc, objdump and size from the checksum-pinned Linux toolchain.
For both scalar-chain and scalar-loop symbols, optimized static stack traffic
and each routine's frame must fall by at least 50%, and instruction counts by
at least 20%. Neither routine's actual object bytes, total scalar object text
nor summed reported frames may grow. The tiny leaf may gain no instructions,
object bytes or frame space, and must not acquire callee-save overhead. Existing
insertion-sort and sieve-of-eratosthenes workloads retain their status-42 and
empty-output oracles; optimized object text may grow by at most 10% over the
reference. Changing array length from 4 to 4096 may add at most
32 instructions to its arithmetic routine and 2048 bytes to complete object
text, including bounded stack-probe loop setup. The explicit optimal record
must report natural 24 bytes, selected 16 bytes, offsets `[8, 0, 9]` and exactly
8 saved bytes. Equivalent requests must repeat assembly and JSON byte-for-byte.
The single-instance evidence probe must retain indirect calls with specialization
off and eliminate all of them with auto/all, retain hidden-ABI evidence and
add no more than 128 bytes of total object text over none/off. The private
identity-body folding probe must report actual sharing and strictly smaller
object text for every optimized objective. Large-array object disassembly must
contain page-by-page 4096-byte stack adjustment and memory touches; merely
reporting a large frame is not probe evidence. The report retains measured
disassembly, size output and compiler/assembly/object hashes.
These are acceptance bounds, not a benchmark claim. Initial pinned-container
debug measurements establish the following reference baseline; each optimized
column was identical for size/off, size/auto and speed/auto on these witnesses.
The traffic counts are static stack-memory instruction sites, including the
prologue, not dynamic accesses.

| Witness and metric | none/off reference | optimized |
|---|---:|---:|
| Scalar object `.text` bytes | 1866 | 1130 |
| Scalar summed frame bytes | 832 | 368 |
| Scalar chain instructions / stack sites | 127 / 112 | 78 / 26 |
| Scalar chain frame / function bytes | 448 / 794 | 176 / 321 |
| Scalar loop instructions / stack sites | 68 / 49 | 51 / 18 |
| Scalar loop frame / function bytes | 176 / 307 | 80 / 171 |
| Tiny leaf instructions / stack sites | 14 / 8 | 12 / 6 |
| Tiny leaf frame / function bytes | 32 / 45 | 32 / 37 |
| Insertion-sort object `.text` bytes | 3445 | 2062 |
| Sieve-of-eratosthenes object `.text` bytes | 3445 | 1999 |
| Array routine instructions, length 4 / 4096 | 103 / 109 | 101 / 107 |
| Array object `.text` bytes, length 4 / 4096 | 1669 / 1768 | 1208 / 1304 |
| Folding object `.text` bytes | 773 | 669 |

These observations use GNAT GCC 16.1.0 and GNU Binutils 2.46.1. The scalar
traffic reductions exceed the preselected 50% floor; changing array length
adds six instructions rather than expanding the body per element. The
specialization object measured 766 bytes with none/off, 767 with none/all,
714 with size/off and 700 with size/auto, speed/auto and speed/all. Only the
off profiles retained indirect dispatch. The optimal-layout witness measured
the 24-to-16-byte placement stated above. The runner preserves its actual
observations in the host build tree's `quality/measurements.json`; it never
rewrites these acceptance thresholds from a run. These are supplemental
container observations, not a native gate or final-tree closure claim. The
scalar, insertion-sort and sieve none/off assembly also matches byte-for-byte
the captured R4.40 reference compiler's output at
`36c1324af3353ebb34ac23adf34b188533e6b4f7`; this is a measured baseline, not
universal reference-output identity.

The source-level two-instance threshold probe supplies eight entry calls,
loop depth four and four represented bytes per instance: benefit 321 versus
estimated growth 209. Size/auto declines at its four-times-growth threshold;
speed/auto selects at its one-times-growth threshold, while all forces both
proved instances. The runner pins these source-derived inputs and decisions.
The two fallback instances share one machine body with eight physical indirect
call sites; selected bodies have eight direct calls each and cannot share
because their provider relocations differ. Actual object text is 1805 bytes
for none/off, 1158 for size/off and size/auto, 1565 for speed/auto and speed/all,
and 2724 for none/all. This deliberately records the size/speed tradeoff rather
than requiring every specialization to shrink text.

Report collision preflight now delegates exclusively to authoritative platform
identity: actual symbolic parents, native device/inode identity and destination
filesystem name rules. It does not collapse `..` lexically across a symlink or
infer case sensitivity from the operating system. Fake-driver and native cases
cover aliases of sources and artifacts, including absent and dangling leaves.
Missing-name proofs cover APFS/HFS ASCII case rules, Linux ext4/f2fs directory
casefold flags and recognized byte-sensitive Linux filesystems. Unknown rules
and unproved Unicode equivalences remain conservatively indeterminate; there
is no concurrent filesystem-replacement guarantee.

Post-integration focused validation passed with pinned GNAT 16.1.0 and
GPRbuild 26.0.0: fifteen Mac suites in each compiler build mode (435 cases and
4314 checks per mode), and ten Linux-container suites plus 112 selected
positive/negative/runtime/ABI fixtures in each mode. Every selected executable
ran its required four or six profiles. The object-quality runner passed all
42 profile observations in both compiler build modes; numeric measurements and
factual build reports agreed between modes, and each repeated request produced
identical assembly and JSON. Real Clang 19 bindings integration passed all
41 tests. Full document checks and the pinned tree-sitter generator, corpus,
compiler/core parsing and canonical queries passed. These are focused local
observations, not substitutes for complete gates or native hardware evidence.

The subsequent independent-review repairs retain nonreading array aliases,
qualified module storage identities and permissions, and D124's returning
operands in array and literal-scalar arithmetic without accepting a missing
fallthrough answer. Placement is computed once while retaining unpadded extent.
Backend sharing eligibility is cached per emission; uncaptured machine streams
still count instructions. Heap-owned scratch permits the 24,000-statement
reference routine, and C-entry scratch participates in page probing. Shared
shape measurement preserves the backend's target-object limit and the cost
model's separate represented-byte limit. Reports retain whole discriminated
plans and share one byte encoder with source maps. C/header inventory changes
invalidate developer builds as well as ordinary builds.

After these repairs, sixteen focused suites passed in each of Darwin and the
Linux container, in both compiler build modes: 378 cases and 177816 checks per
host/mode. All 48 R4.50 fixtures passed in each Linux compiler mode, including
six mandatory profiles for each of their runtime/ABI cases. Native identity
passed ten tests per host/mode; the build-inventory runner passed five tests.
Object quality passed all 42 observations in each Linux mode with matching
numeric measurements and factual reports. The local container measurements
used its own `/tmp` filesystem because its virtiofs mount cannot prove the
host volume's absent-name case rules; no acceptance bound or program oracle
changed. The native identity and inventory runners are wired into the existing
gate. These remain focused local observations, not complete-gate evidence.

Complete local validation now supplements those focused observations. In the
pinned Linux amd64 container through Rosetta, the unfiltered debug and release
suites each passed 544/544 cases and 188739 checks. Each executed 1910
runtime/ABI oracle attempts: 1806 runtime attempts across 416 fixtures and 104
ABI attempts across 25 fixtures, against their recorded output, status and trap
oracles. The complete Mac debug and release suites each passed 543/544 cases
and 187009 checks. Their sole failing case was the documented missing Linux
cross-toolchain runtime case; it supplies no runtime-correctness evidence.

Final-tree validation also passed: native report identity passed ten tests for
each host/build combination; Clang 19 bindings passed 41 tests; the build
inventory runner passed five tests; and object quality passed all 42 profiles
in each Linux compiler mode. Full `check.py`, whitespace, generated highlight,
highlight default/integration, tree-sitter corpus and non-publishing site
checks passed. Pygments, TextMate tokenizer and native Emacs optional smokes
were skipped because their dependencies were absent, and are not claimed as
executed. The numeric table above remains the initial pinned-container
reference baseline; final quality validation checked its unchanged acceptance
bounds, reports and measured objects against the final sources rather than
substituting new baseline values.

Independent finished-change reviews and final contextual-repair verification
passed. Confirmed findings were repaired and did not regress in the completed
gates. The locally reported source fingerprints use different algorithms, but
their exact per-file inventories reconcile; this records no source drift.

The authoritative native Linux x86-64 SourceHut gate closed R4.50: `hut builds
show 1884559` reports `SUCCESS` for the exact committed revision
`1722e1f4ebabed03ebd2812e530818094517b94d`, titled "Implement R4.50 baseline
code generation and specialization". Its `toolchain`, `identify`, `build`,
`test`, `release`, `report-identity`, `quality`, `bindings`, `checks`,
`identity` and `pages` tasks all succeeded, including clean debug and release
validation. The `pages` task correctly skipped publication on this feature
branch; no site publication is claimed. The job is
<https://builds.sr.ht/~sinnfrei/job/1884559>.

Sources: `[0590]`, `[0750]`, `[1120]`, `[1310]`, `[1720]`.

Exit evidence: disabling specialization preserves behavior; build reports state
what happened; scalar loop lowering and code-quality smoke measurements meet
the documented baseline.

### R4.60 — Implement usable Linux source debugging

Status: complete
Depends on: R1.70, R1.80, R4.50

Emit source line tables, symbolic frames and inspectable parameters/locals for
core scalar, pointer, aggregate and variant types. Preserve the frame pointer
and source/type provenance through lowering. D192's caller file IDs must use
that same source identity table; extend or replace the bootstrap off-target
file-map packaging without changing the three-u32 caller ABI. Preserve exact
build matching and optional filename deployment. Native debugger support does
not gate caller-coordinate generation, which R4.10 already implements.

The driver exposes `--debug=none|full`, defaulting to none independently of
source build mode and optimization. Full requests emit non-allocated DWARF 4
and frame information while preserving the ordinary frame pointer. Register
allocation and evidence specialization remain enabled; identical-body sharing
is suppressed so distinct source routines keep distinct breakpoint locations.
Represented types and physical locations come from immutable IR and the same
backend placement plans as code emission. Declaration syntax supplies names
and source extents, never a second physical layout.

DWARF is the selected Linux interchange format, not Landin's internal debug
model. Source identities, declaration/type provenance and variable-location
facts must remain independent of its record encodings. A future PDB emitter
may consume those same facts; this item neither implements PDB nor adds a
Windows target to the roadmap. Format-specific records and section packaging
belong at emission, rather than becoming language or IR contracts.

Version 4 is sufficient for this slice's type descriptions and variable
location lists. It keeps the first emitter on that direct representation;
the choice is not a claim that the pinned debugger lacks version 5 support.
Assembler-generated line and frame tables retain their independently
versioned formats; a compilation-unit version does not force every section
header to that number.
Changing the output version later need not change source identities, runtime
caller coordinates or the compiler's internal provenance model.

The complete debug source table uses the compilation's source IDs in their
original order, as do assembler file entries and D192's caller values. Full
debugging expands `.sources.json` to every snapshot; none retains the previous
caller-only packaging. GNU assembler quoting preserves arbitrary filename
bytes. The map's exact assembly/build identity remains mandatory for lookup,
and stripping the optional debugger sections preserves program behavior and
the caller ABI.

`scripts/debug.sh` owns debugger acceptance independently of the Ada harness.
It defaults to native GDB; an explicit QEMU remote-stub mode supplies local
feedback because Rosetta cannot implement GDB's ptrace register operations.
The authoritative native Linux gate has no fallback and runs the script with
both debug and release compiler builds.

Finished-change validation used the same 211 compiler source/project
checksum entries in Mac and Linux debug/release builds. The focused
debugging suite passed all 11 cases and 129 checks. Complete local Linux
suites passed all 555 cases and 188,868 checks in each compiler mode.
Complete Mac suites each ran 555 cases and 187,138 checks, passing 554
cases; the sole failed case was the expected Linux runtime-execution case
because the cross-toolchain is absent. Native report identity passed ten
tests in every host/compiler-mode combination.

Scripted local QEMU debugger acceptance passed none/off, size/auto and the
conditional size/all profile with both compiler builds. Auto factually
declined the two concrete instances on cost; size/all specialized both with
eight direct calls each. Every profile proved source breakpoints, stepping,
nested stacks, caller locals (including saved-register values under
optimization), represented types, match/destructuring/loop aliases, exact
source maps and build IDs, and stripped-copy execution without debug
sections or source filenames. Observed compilation-unit, line-table and CIE
versions were respectively 4, 3 and 1. Omitted debug and explicit none
produced identical assembly and caller-only maps in all six source build-
mode and optimization combinations.

Object quality passed all 42 profiles in each Linux compiler mode. A local
shared-mount artifact-identity collision was fixed by placing the harness's
private files in local temporary storage while retaining its complete
measured evidence; both reruns passed with every oracle unchanged. Clang 19
bindings passed all 41 tests. Full document checks, the five build-inventory
tests, the six roadmap-progress tests and complete no-drop site rendering
passed. Independent finished-change source reviews approved the compiler,
debugger harness and environment fixes; confirmed initialization, source-
alias, source-member-name and debugger-oracle findings were repaired and
verified.

The authoritative native Linux x86-64 SourceHut gate closed R4.60: `hut builds
show 1884951` reports `SUCCESS` for the exact committed revision
`0e854b7da159990e403e75cefbfbb886b9d6e0ff`, titled "Use local temporary storage
for object quality artifacts". Its `toolchain`, `identify`, `build`, `test`,
`release`, `report-identity`, `quality`, `debugging`, `bindings`, `checks`,
`identity` and `pages` tasks all succeeded. This includes clean debug and
release validation and strict native GDB acceptance in both compiler modes.
The `pages` task correctly skipped publication on this feature branch; no
site publication is claimed. The job is
<https://builds.sr.ht/~sinnfrei/job/1884951>. The separate Nix shell check also
passed its complete suite and four dynamic-libc profiles in job 1884933 at
`08c46850dfa1023351b4884d588734a1b5ab8c8f`; it remains a non-gate.

Exit evidence: scripted debugger sessions prove breakpoints, stepping, stacks
and selected locals in unoptimized and baseline-optimized builds.

### R4.70 — Complete and run the derived container program

Status: complete
Depends on: R4.20, R4.50, R4.60

Turn prototype 3 into a complete hosted `.ldn` program and negative corpus,
with derivation mapping and deliberately failing allocator cases.

`runtime/derived-containers` now hosts the reusable
`examples/derived_containers/workload` module. Its `DERIVATION.md` maps every
prototype section and Z1--Z19, explicitly retaining historical/no-gap
resolutions instead of reviving obsolete raw-storage sketches. The program
uses the ordinary `core` modules: it reverses the twenty-number seed, grows
and sorts a list, maps numbers to squares, exercises small-vector spill,
initialized pointer storage, colliding map keys and entry walks, indexed tree
nodes and names, and a heterogeneous `list(any drawable)`. Every allocating
operation receives its provider. Reclaiming pool/countdown combinations pin
vector and small-vector rollback, all three map-compaction acquisition
failures, tree append refusal, retry and exact final cleanup; arena no-op
`free` is not counted as reclamation evidence. The entry returns 42 only when
all fourteen path booleans hold and writes no output. Its three new negatives
cover missing ordering evidence and enumerated-entry live-view/exact-source
origins; the manifest cites the existing stronger raw-storage, frame-escape
and composed-conformance controls rather than duplicating them.

Complete direct scalar-operator origin normalization, including saved `lenof`
across later source mutation. R4.20 uses ordinary scalar-returning length
helpers and immediate assertions; that equivalent does not close the operator
limitation. [1910] and [0840] distinguish the reference-free result from its
operand's storage provenance: saving a number retains no view, while address
and range formation still derive from the selected backing. The repair must
preserve evaluated-operand checks, short-circuit joins and D14/D31's
unevaluated measurement rules.

The scalar repair now separates computed scalar values from place storage
facts after operand checking and control-flow joins. The runtime
`r470-scalar-operator-origins` saves direct slice lengths across `inout` and
`sink`, combines unary, arithmetic, comparison and logical results, and observes
operand effects and short-circuiting. Its fixed-array field case measures a
legal copied-array binding; the grammar still does not admit general `lenof`
selection expressions. `negative/r470-scalar-reference-controls` retains
ordered L0314/L0315/L0316 checks for operand escapes, genuine live pointer/slice
views and exact `from`. Focused Linux feedback passes; this does not substitute
for the complete item's native exit gate.

Own the remaining nested-array field range normalization observed by R4.20:
a range over a struct field whose elements are fixed arrays must preserve the
complete nested element descriptor. The R4.20 container protocol already uses
direct array backing and typed whole-array selection copies; this additional
composition must be implemented or explicitly amended before complete P3
parity is claimed.

The R4.40 recursive descriptor machinery already preserves the complete
supported element shape through checking and neutral-IR shape construction.
R4.70's checking and lowering cases pin concrete nested-array field ranges,
including deep children, zero-length children, nominal and reference-bearing
elements, and read-only/mutable views. `runtime/r470-array-field-range` observes
the concrete composition. At R4.70 closure, the older
`parameterized-struct-unused-shape` and template-order negatives remained L0304:
they contained atom-set array elements outside that slice. R4.90/D216 now
accepts those original source bytes as positive fixtures and executes atom
storage separately; the R4.70 nested-array oracle is unchanged.

Guarded payload lowering did need repair. An array match alias followed by
child selection must carry both the selected payload step and the full child
path; compact direct variant selectors are valid only when no child follows.
`runtime/r470-nested-guarded-field-range` exercises a variant payload's nested
array ranges and reads back writes made through its aliases.

Repair the direct fixed-array parameter access exposed by the running
fannkuch example. Changing `reverse_prefix` in
`runtime/benchmark-game-fannkuch-redux` from `(values: []mut u8)` to
`(inout values: [7]u8)` and passing `permutation` directly makes the pinned
R4.20 compiler report an internal defect. Its prefix-swap body also reproduces
the failure in isolation. The writable-slice equivalent did not close the
direct-parameter composition defect.

The repaired lowering forwards a root `inout` parameter's existing runtime
address instead of taking the address of its pointer slot. Selected ordinary
storage still uses the ordinary place-address path. The fannkuch source and
its `examples.md` listing now use the direct fixed-array parameter and call;
the output oracle remains checksum 228 and maximum 16.
`runtime/r470-array-inout-parameter` and the one-address lowering case pin
forwarding, reads, swaps, writes and evaluation order;
`negative/r470-array-inout-parameter-shape-mismatch` retains rejection of a
wrong fixed extent. The array partition's eight focused Linux selectors pass
85 checks; complete and native integrated gates remain separate obligations.

Also close R4.21's transferred map tombstone compaction and entry enumeration:
reclaim dead pressure without unnecessary capacity growth, retain the existing
three-acquisition rollback transaction, and enumerate only live entries with
their exact reference origins. The complete derivative supplies the real
container workload for R4.50's specialization/object measurements and R4.60's
source-debugger acceptance, as transferred by R4.20.

Exit evidence: list, small vector, map and tree paths execute on Linux x86-64;
raw-storage, evidence and origin invariants are exercised.

R4.70 closed with native Linux x86-64 SourceHut
[job 1885323](https://builds.sr.ht/~sinnfrei/job/1885323) for
`72f6fffbe496329f880fd6300221059cdd3da51a`: clean debug/release complete
suites, native report identity, object quality, native GDB, Clang-19 bindings
and document checks all passed. The complete suite passed 559 cases and
188984 checks in both native compiler modes; the derived container workload
ran all six fixture/quality profiles and all three native debugger profiles.
The independent implementation review and retained mutation controls precede
that exact-revision gate. This historical result remains R4.70's closure
proof as acceptance moves to the tracked native runner. R4.80 owns the
complete hosted application.

### R4.80 — Complete and run the derived hosted application

Status: complete
Depends on: R4.20, R4.30, R4.40, R4.70

Turn prototype 4 into a complete hosted `.ldn` program with heterogeneous
runtime dispatch and I/O, retaining traceability to prototype 2 and 3 support.

D196 transfers both [0820] refusals here from R4.20. Before claiming the
complete prototype, decide or explicitly amend all four D191 questions:

- Specify the block value's type and how it meets the ordinary two-operation
  allocator contract without frontend recognition of `core/mem`.
- Specify backing authority, extent and capacity for hosted and constrained
  targets, and cleanup on normal, failure and control-transfer exits. A
  hidden guessed frame buffer is not an answer.
- Specify and exercise exhaustion behavior, including deterministic failure
  and nested blocks.
- Reconcile the block-frame promise with independent no-`from` allocator
  results. Exercise direct and helper-returned references, aggregates, slices,
  `any`, callback state and helper-side-effect escapes into module storage.
  Permit simultaneous allocations and helper results used within the block;
  preserve explicit unsafe conversion as a non-guarantee. Adding a borrow of
  the allocator would prohibit the ordinary simultaneous-allocation idiom.

The last requirement pays for W7's missing path: a helper-retained pointer
need never return through the block's boundary. Preserve ordinary identifiers
named `arena`, generic and erased allocator calls, and explicit caller-backed
`mem.arena`. Enable the promised construct with evidence or amend its
normative promise on evidence before the hosted parity gate.

The complete source is `examples/derived_hosted`, with the section-by-section
and W1-W7 mapping in
`compiler/tests/fixtures/runtime/derived-hosted-memory/DERIVATION.md`.
The app directly reuses prototype 2's text and diagnostic capabilities and
prototype 3's initialized storage, vectors and allocator providers. The
separately complete parser and container support programs remain in the
acceptance corpus; command-line options do not require a recursive parser.

D212 discharges both [0820] forms and all four inherited questions:

- Both builtin forms are withdrawn, with named migration diagnostics. The
  value is an ordinary declared allocator type, with ordinary two-operation
  conformance. `core/mem` has no frontend privilege. The object-safe erased
  adapter remains distinct from `mem.allocator`'s generic inout contract.
- Backing and capacity are explicit. `core/region` records payload extents
  against its supplied parent, with ledger storage charged to that same
  authority. The hosted root chooses the heap; finite callers choose their
  own backing. Explicit release returns payloads and ledger to the parent;
  an arena parent's no-op free does not reclaim its consumed extent. `defer`
  supplies ordinary cleanup across normal, failure and control-transfer exits.
- Finite providers report deterministic `out_of_memory`; nested explicit
  backing and nested region wrappers have no hidden capacity or heap fallback.
  A refused ledger acquisition returns the just-acquired payload to the
  parent, while previous live allocations remain intact.
- Allocation results retain their ordinary independent no-`from` behavior.
  Direct and helper-returned pointers, aggregates, slices, `any` and callback
  state remain useful, including simultaneous allocations. The helper-side-
  effect module-store counterexample disproves W7's old lexical guarantee.
  Unsafe address conversion stays a non-guarantee. Tracked direct frame
  references and provider handles retain their existing escape checks.

The reader grows complete lines across arbitrary explicit chunks, preserves
empty and final unterminated lines, and returns a view derived from its reader.
Configuration copies all retained argument bytes before parsing. Level,
substring and sampling filters are ordered runtime-selected `any` values;
text and counting destinations are selected through the same ordinary evidence
mechanism. Recoverable sampling diagnostics use the parser's `any diag.log`.
Messages own arbitrary copied bytes and a committed cursor. One-byte writes
make progress exact under the repository world providers; the application
retries once from that cursor and terminates on a second failure. Counts and
diagnostics terminate on write failure without replaying an unknown prefix.
Read/allocation failures are terminal for the reader. Files close once on
normal and handled failure exits; close failure never triggers another close.

The full reader exposed a compiler liveness defect: the loop fixed point kept
a prior iteration's local view alive while declaring its replacement. A fresh
binding now clears that old fact before initialization, and future-use scans
recognize the new declaration lifetime. `runtime/r480-loop-fresh-view` pins
both a view-returning mutator and mutation before the next declaration;
existing loop-carried, conditional-replacement and live-reader negatives
retain their original refusal oracles.

Contextual discovery of a generic initializer used by `any` also exposed a
cached-call defect: its successful value was known before error inference
finished, so the later body walk skipped an unchecked recovery subtree.
Finalized cached generic calls now check that subtree in their own instance
view. `runtime/r480-generic-nested-recovery` exercises nested erased cleanup
and failure propagation; all six profiles fail internally with the old path
and execute correctly with the repair.
The recovery's generic calls are also discovered explicitly before freezing
the error graph: syntax stores that subtree beside ordinary child slots.
`negative/r480-nested-infallible-recovery` and independent review probes
require one appropriate diagnostic instead of an internal failure. Bounded
re-review confirmed both infallible-call and mismatched-recovery refusals;
the native checking suite passed all 83 cases and 1184 checks.

Explicitly constrained generic conformance providers exposed a separate
evidence-entry ABI mismatch. A target-neutral entry now binds their concrete
evidence and forwards the unchanged concept signature to the ordinary generic
body. `any` retains its two-word representation. The six-profile
`runtime/r480-generic-provider-entry` regression covers nested evidence,
direct and erased dispatch, aggregate arguments/results, inout arrays and
failure propagation; its old lowering fails internally in every profile.

The complete reader then exposed the same separate-subtree mistake in loop
exit discovery: a break in call recovery had no destination block. The
six-profile `runtime/r480-recovery-loop-transfer` now covers conditional
break/continue, a labeled outer break, slice results and cleanup on every
edge. A fresh independent review traced that representation through the
remaining checks and found four further omissions: recovery-only borrower
reads, exposed-storage mutations, definite assignment beneath an operator,
and literal operand diagnostics. The corresponding
`negative/r480-recovery-retains-borrow`,
`negative/r480-recovery-exposed-storage`,
`negative/r480-recovery-assignment` and
`negative/r480-recovery-zero-divisor` now retain exactly L0315, L0316, L0302
and L0306. Valid assignment within a recovery remains accepted. Bounded
re-review found no remaining issue in these repairs.
The original positive IR corpus also required discovery to defer a match
header until its inferred error binding has a real atom set, while still
discovering generic calls in every arm. Concrete sets are already known and
are supplied before generic deduction from an error value. The corpus stays
byte-for-byte unchanged, and `runtime/r480-concrete-error-deduction` preserves
that previously accepted form across six profiles. A separately reproduced
canonical defect involving an inferred error actual is recorded under the
still-planned R4.90 parity item.
The stronger recovery walk also exposed discarded scalar and aggregate calls
in the earlier container workload and runtime fixtures whose handlers omitted
the fallback value required by [1030]. Their sources now supply that value
or call an ordinary none-returning helper, preserving every failure flag,
control-flow path, allocation count and existing status/output oracle.

`runtime/derived-hosted-memory` specifies the complete deterministic workload:
long/chunked/final/empty lines, retained arguments after source mutation,
heterogeneous selection, arbitrary binary message copying, committed-prefix
retry, exact diagnostics, finite/nested regions, allocation-failure sweeps
including ledger growth, and read/write/close/configuration failure cleanup.
`runtime/r480-hosted-count` and `runtime/r480-hosted-text` use actual hosted
arguments and files; the text case reads back its long final line and removes
its temporary file. Negative controls also keep the region provider's origin
and ledger privacy. `check.py` holds the derivation to the source inventory,
P2/P3 support and complete W1-W7 register.

Every `r480` and `derived-hosted` runtime fixture runs all six required
optimization/specialization profiles. The complete memory workload also runs
six object-quality profiles and three native GDB profiles, retaining source
identity, report/assembly determinism, indirect dispatch, provider state,
call stacks and stripped-image oracles. These supplement every existing
runtime/ABI/workload, identity, bindings and document check; none replaces
full native acceptance. R4.90 remains planned.

Closure records implementation and bounded independent review in this
candidate. At candidate preparation, focused native execution, quality and
GDB checks had passed; full eight-job acceptance, verified durable export,
administrative approval, canonical promotion and publication verification
were still pending delivery steps. Acceptance of the exact containing
revision is recorded externally by its annotated `ci/accepted/FULL_COMMIT`
tag and bound native run bundle, rather than a later source edit. Canonical
Pages publication requires that approval through the existing guard. The
complete acceptance matrix, approval and publication records are the delivery
evidence; the focused runs above cannot substitute for them.

Exit evidence: the application selects heterogeneous implementations at
runtime, processes hosted I/O and executes on Linux x86-64.

### R4.90 — Close Linux hosted parity

Status: complete
Depends on: R4.60, R4.70, R4.80

Run the full applicable construct, conformance, ABI, diagnostics, determinism,
debugger and prototype suites on native Linux x86-64.

The applicable audit found actual hosted gaps behind otherwise populated rows:
[0650]'s distinct identities, [0670]'s inline declaration bodies, [0720]'s
homogeneous nonzero field fills and [1350]'s parameterized atom-union aliases. Inline bodies preserve the original refused
source unchanged as a positive fixture. D214 supersedes D65's overly broad
homogeneous-fill refusal using one complete descriptor and one evaluated value;
its heterogeneous and absent-context refusals preserve useful diagnostics.
D135 now substitutes union members without caching template answers or partial
sets. Canonical keys flatten aliases, qualify members and deduplicate atom
identities. Optional-pointer alias flattening retains its original empty atom,
so adding a different atom still reaches D189's multi-atom refusal; it no longer
silently replaces the first atom. Malformed direct composite members are
refused before syntax construction, while named nonatom members retain their
semantic diagnostic.
The atom-comparison probe separately exposed a verifier that required set
inclusion for identity equality. D200 now states the existing checker rule
precisely: disjoint and overlapping sets compare declaration identities, while
stores still require inclusion and ordering remains forbidden.
D216 closes the same identity gap in ordinary and generic atom fields, variant
payloads and fixed arrays. Exact descriptors survive storage, slice views,
static images and generic keys; indirect writes admit member subsets while
loads retain the full destination set. Nonmember, numeric, arithmetic,
unequal-copy, zero-image and unequal-fill refusals pin the other side. The three
older template-order/unused-shape declarations move unchanged to positive
fixtures. The dependent-errors source also retains its original bytes, but
remains negative with L0301 at both omitted module initializers: its shapes
are now admitted, while an implicit zero atom is not. Independent review found
and corrected the missing atom check in recursive aggregate zeroability and
the nominal-only module-array check; complete element descriptors now govern
omitted images, including callback and reference elements.
Independent review's distinct probes additionally pin Boolean and pointer image
extraction, reject a type declaration used as a value, and preserve the existing
[1940]/R6.60 module storage-address refusal. Supported null, numeric-pointer and
C-string images execute without changing their carrier or relocation rules.
The complete container migration exposed fixed generic formals being sent to
binding-initializer inference during conversion discovery; fixed actuals now
retain their existing expression typing through that discovery path. The
regression uses unequal views, match bodies, nested forwarding and distinct
construction/extraction. `core/tree.node_id` and `core/io.file` now use the
prototype's actual distinct identities, with the original workload oracles.

[1270]'s conformance-input key was previously attributed only to a collision
refusal. Positive unequal-key collection and alias-normalized collision controls
now pin both sides, and D148 includes the previously missing guarantee coverage.
The lexical/module probe observes public imported results, comments, grouped
atoms and local shadowing. Generic cleanup/recovery checks late argument
execution under both `defer` and `undo`. The parser derivation's recursion is
recorded as a chosen implementation, not as evidence that loops remain absent.
The handoff's unsupported semicolon claim is corrected to the actual grammar.

The debugging audit found that the complete parser executed in the runtime
suite but lacked a workload in the GDB runner. It now joins the complete
containers and hosted application in all three workload profiles: none/off,
size/auto and size/all. Its original input, ordered diagnostic output and
status-42 oracle apply to ordinary, debugger and stripped execution. Source
stops inspect initialized parser state, recursive frames, recovery, nesting
depth and the final success/failure flags. The common source inventory, build
identity and line-table checks cover its reached library closure. Transcript
refusal controls reject missing or incorrect state, frames, lines and exits;
`check.py` independently requires every complete prototype and profile in the
runner's workload schedule.
The same audit found that repeated assembly and build-report comparisons covered
the complete containers and hosted application but not the complete parser.
The parser now runs all six quality profiles with its original input and output
oracle, retaining the exact repeated-build comparison and measured-object
execution. Its object sizes remain observations, with no new optimization
budget.

The audit also distinguishes scoped obligations from future work. D188's range
compositions, D189's multi-atom pointer unions and D190's u128/i128/f16 remain
explicitly owned by R7.20 under the current normative restrictions. Native macOS
arm64 belongs to R5 and the freestanding target and hardware constructs to R6;
prototype 1 is not a Linux hosted workload. D212's two builtin arena forms stay
withdrawn, with their migration diagnostics and ordinary-identifier controls.
Caller-backed allocation, independent simultaneous results, generic/erased
providers, `core/region`, explicit capacity, local origin checks and `defer`
cleanup remain executed obligations. None of those is withdrawn by the parity
closure or replaced with an allocator special case.

The progress renderer and status check select the first dependency-ready planned
item in roadmap order when no item is active. This accommodates the R4-to-R5
boundary without activating either R5 item or inventing a dependency between them.

R4.80's recovery review isolated a pre-existing inference-frontier defect for
this parity item. On canonical `5b2db329`, the program below exited 70: generic
deduction needs the recovered error's inferred atom set, and discovering its
instance during error finalization changes the supposedly frozen signature
inventory. Native GDB pinned the signature-count assertion immediately after
`Finalize_Error_Sets`. This item owns closing that dependency without guessed
atom sets or silently disabling an otherwise ordinary generic call. The
concrete-error-set form already worked on that baseline and remains covered
by `runtime/r480-concrete-error-deduction`; the complete hosted application
and its support programs did not depend on the unresolved inferred form.
R4.90 reproduces it on `795f7052` and closes it through D215's dependency
frontier: inference publishes only complete component sets before resuming
recovery-dependent generic discovery, and freezes inventory only at completion.
Meaningful controls cover exact-key interning, unequal keys, aliases, nested
recoveries, traversal headers, recursion, immutable recovery values and the
precise circular-key refusal. Independent review additionally reproduced an
alias-only rethrow losing its effect (and crashing inside an ordinary recursive
component), and an erased parameterized provider being selected before its
recovered actual was complete. Following alias initializers into effect edges
and delaying contextual provider discovery resolve both, with chained aliases,
mutual recursion and separate generic-view controls. The broader fixture check
also exposed a repeated nested-handler diagnostic; finalized handlers now retain
their facts without issuing that diagnostic twice. Existing R4.80 concrete-error,
nested recovery and control-transfer oracles remain unchanged.

The first native acceptance candidate, `a5d3491f`, exposed three further
composition regressions in the release suite. Its failed run
`20260911T163146Z-05257869374f` is retained and supplies no approval. Ordinary
IEEE named constants had entered an array-field image path after D213 widened
module-image discovery; ordinary scalar and atom data now retain their existing
lowering path after distinct representation folding. Nonreading `lenof` on a
type alias now uses the type path rather than the ordinary-value refusal path.
Forward callback and reference image dependencies use their complete declared
descriptors before their initializer expressions have been checked. The static
dependency graph and its cycle refusals remain unchanged. These fixes preserve
the original named-float, imported/128-alias measurement and huge recursive
static-selection oracles. Added compositions cover generic distinct IEEE images,
nonreading type/value measurements and callback/atom/distinct static selection;
the existing module scalar-field-read refusal remains pinned separately.

```landin
problem: atom
leaf: () -> none ! ... = fail problem end leaf
observe: (t: type, value: t) -> none = _ = value end observe
public main: () -> (code: i32) =
    leaf() else (error) observe(error) end
    code = 42
end main
```

#### Hosted compile-time evidence

These rules are observed while compiling. Every other hosted applicability row
requires a Linux runtime/ABI fixture with a program and an attributed construct;
`check.py` also rejects surviving `later-r4` rows and incomplete R4 owners when
R4.90 closes. The metadata is an auditable claim, not proof of the source oracle's
adequacy. The independent review reads those oracles and the native gate executes
them. This table does not withdraw any construct.

| Construct | Accepted | Refused | Rationale |
| --- | --- | --- | --- |
| `[1270]` | `positive/r490-conformance-input-keys` | `negative/conformance-collision`, `negative/r490-conformance-input-alias-collision` | Whole-program conformance keys include normalized input tuples; unequal keys coexist and equal keys collide before runtime. |
| `[1400]` | none | `negative/local-array-literal-inferred-element-mismatch` | Heterogeneous implicit boxing is deliberately absent; mismatched element types are rejected. Ordinary explicit `any` dispatch has separate executed rows. |
| `[1860]` | none | `negative/name-declared-nowhere`, `negative/condition-declaration-out-of-scope` | Every name must resolve in its scope; the observable failure is a compiler diagnostic. |

Closure records the complete applicable implementation and independent review
in this candidate. At candidate preparation, focused native fixtures, the full
parser and verifier suites, recorded positive IR, object-quality profiles and
the complete parser's three native GDB profiles had passed. The acceptance
repairs also passed the complete checking, frontend-review and lowering suites
in both compiler modes and their focused runtime/refusal controls. The complete
derived parser, containers and
hosted application retain their behavioral oracles, source identities, build
report/assembly determinism and debugging profiles. Baseline code generation
retains its existing numeric/object bounds; no competitive optimization claim
is made.

Full eight-job native acceptance, verified durable export, administrative
approval, canonical promotion and guarded publication verification were still
pending delivery steps at candidate preparation. The mandatory GDB jobs still
have to validate the integrated P3/P4 debugger workloads in both compiler modes;
the focused parser sessions do not substitute for them. Acceptance of this exact
containing revision is bound externally by its annotated
`ci/accepted/FULL_COMMIT` tag and durable native run bundle. No later source
bookkeeping edit supplies that evidence. Filtered development checks cannot
approve the revision, and Pages must pass the existing approval guard.

Exit evidence: all applicable matrices are complete; equivalent builds produce
identical assembly and behavior under the pinned toolchain. The bound acceptance
record, approval tag and guarded publication records establish delivery.

### R4.91 — Resolve post-R4 review findings

Status: complete
Depends on: R4.90

Review of accepted revision `66927e93` reproduced four defects in implemented
hosted constructs. The initial implementation repairs generic fixed-array field
arguments, missing contextual diagnostics for `[]`, undiagnosed statement
recovery, and the public-conformance diagnostic's secondary-label contract.
The follow-up comparison with the independent reviews of `66b3b659` expands
this slice. R4.90 acceptance did not close every finding in those older reviews.

Sources: [0430], [0480], [0570], [0580], [0770], [0780], [0790], [0830],
[0900], [0910], [0950], [1220], [1280], [1300], [1800], [1810], [1880],
[1910]; D78, D85, D96, D134, D138, D140, D141, D151, D187, D217. The original review's unconfirmed float-resource and
varargs observations remain unconfirmed and supply no implementation mandate.

Implementation is in the isolated `r491` worktree. The first batch retains full
array descriptors in generic deduction; contextualizes empty slices before
ordinary and concrete generic argument checking; refuses context-free empty
slices; and repairs the five reviewed diagnostic-label violations without
relaxing the catalogue. Recovery at end of input uses a point-capable diagnostic,
and the syntax stage refuses to advance an undiagnosed unsound tree even in
release builds. Runtime cases cover independent array copies, nested/module
fields, atom/callback/pointer elements and empty-slice contexts.
Driver cases check that refused sources attempt no writes or host-tool calls.

The second batch now also preserves source files against output collisions,
validates build modes and holds build locks through compiler use and cleanup,
and checks consumed storage across containing reads, replacement assignments
and every observable exit. The next implementation also checks retained
reference stores against their actual backing, preserves origins through known
local alias writes, and keeps scalar variant payload aliases live through reads,
writes, derived views, cleanup and inner-loop uses. Same-origin updates, declared
retention, last-use retags and independent sibling storage remain permitted.
Pointer-backed retags now use captured holder storage in lowering. The private
raw transfer uses the same explicit destination-address boundary for its first
and later slots; ordinary stores retain the origin check.
The origin/payload group completes this batch's confirmed repairs. The third
batch also repairs contextual constructor arguments and variant-array
initialization, alongside the follow-up parser recovery/lookahead group.
Final-body values completed that batch. Parser depth, native failures and
bounded inference storage were subsequent batches, recorded below; this
historical sequence is not the current remaining-work list.

Development evidence for the preceding output/consume group: Linux debug and release pass the driver
(46 cases), checking (85), lowering (93), complete recorded-diagnostic case
(971 checks), and all three new consume fixtures. The runtime restoration
fixture passes four optimization profiles in each mode. The parser corpus also
passes both modes (23 cases, 5403 checks), and the earlier output/report checks
pass both modes. On macOS, the driver and 72 script/roadmap tests pass with the
one existing Linux-only runner test skipped; all 13 build-lock/inventory tests
pass on Linux. Full `check.py` and rendered-word preservation checks pass.
This is development evidence; exact-revision acceptance remains outstanding.

Origin/payload development evidence: Linux debug and release pass checking
(85 cases, 1197 checks), lowering (93, 949), driver (46, 448), and the complete
recorded-diagnostic case (977 checks). The two new negative fixtures pin ten
origin/retention refusals and eleven payload-alias refusals. Both new runtime
fixtures pass four optimization profiles in each mode, including retained
variant references, pointer rebinding, initializer effects and computed
copy-back. Existing initialized-object and pointer-vector growth fixtures pass
four profiles in each mode. The complete container and hosted derivatives pass
all six profiles with the final release compiler. The final two added runtime
controls were rerun in both modes. Full `check.py` passes on macOS; no exact
acceptance, debugger session or publication was run.

Construction implementation adds a shared guard on runtime field, payload and
fill roles before reading their expression projection. It keeps static type
arguments separate. Trailing `of` fills require an expression under [1810];
the parser consumes a type-only RHS for balanced recovery and reports L0102.
Seven field/payload cases pin L0301 and four fill cases pin L0102.
The module storage-address exclusion now precedes the
contextual struct early return, so nominal constructors cannot hide an address
that an ordinary module value refuses. A callback's own body remains outside
the static-image walk. No new syntax, static relocation form or language rule
is introduced.

For variant-array construction, the checker seam confirms both selected case
indices were already present. The failing conversion was the destination's
zero base field, not the case index. The contextual writer captures a reached
variant-bearing aggregate as typed address storage before its field writes;
it retains source order and uses the existing IR/address-verification contract.
The new runtime fixture covers root and nested arrays, wrapped children,
repetition and replacement without large images.

Construction validation uses bounded development runs. The new checker and
lowering seam cases pass on macOS debug and Linux release, alongside the
selected constructor and variant-copy controls on macOS. All three new
negative fixtures and the no-effects driver case pass; the final parser-fill
split is rerun on both hosts. The positive static-argument, value-fill,
local-address and callback controls pass on both hosts. The small runtime
fixture exits 42 on Linux with `none/off`: its exact 13,445-byte assembly was
inspected before one bounded pinned GNU-toolchain invocation; the only size
directives were `.zero 8` and `.zero 4`. This is one runtime profile, not a
complete profile gate. Generated fixture tables and full `check.py` pass.
No giant fixture, assembler sweep, debugger session or exact acceptance was
run for this repair group. R4.91 remained active at that batch boundary.

Final-body validation uses nine selected cases in macOS debug and Linux
release: two parser controls, three lowering controls, the R4.91 no-effects
driver case, the two new negative fixtures and the existing return-payload
refusal. Both compilers emit the small new runtime fixture successfully. Its
single Linux `none/off` execution exits 42; the exact 33,582-byte assembly was
inspected before one foreground pinned GNU-toolchain invocation capped at
30 seconds. Its only size directives were `.zero 8` and `.zero 4`.
The fixture also checks that cleanup may read a just-filled result and that a
final local value is captured before cleanup changes that local. Full
`check.py` and regenerated fixture tables pass. This is bounded development
evidence, not all-profile or exact-revision acceptance; R4.91 stayed active
at that batch boundary.

#### Older review reconciliation

Paseo coordinator `27030a0b-54d1-4423-ab3b-82dfe079ece4` commissioned the
independent Codex and Claude reviews of `66b3b659`. `A1` through `A9` below refer to
the Codex report's numbered findings; `C`, `M` and `m` refer to the Claude
report's original identifiers, not this roadmap's inherited review register.
Their original severity labels are not automatically adopted. This comparison
uses retained report text, source differences through `66927e93`, and small
ordinary compiler regression inputs. It runs no new mutation campaign, debugger
session, destructive output-collision experiment or resource-exhaustion sweep.

| Older finding | Current disposition and evidence | Repair order |
| --- | --- | --- |
| A1: artifact/source collisions | Repaired: every actual output is compared with all discovered sources and other outputs through the filesystem identity seam before any write or tool call. Fake-host regressions cover explicit/imported sources, aliases, assembly/executable/map collisions and inactive-map controls. K33 aligns build-report reservations with that same actual-output list. | Second batch implementation |
| C1: diagnostic label contracts | All five sites still violated the catalogue at the baseline; the four sibling minimal cases still exited 70. Initial implementation repairs imports, fixed conditionals, conformances, unconditional completion and continue-with-value. | First batch |
| A2, C2, M3: final values and silent recovery | Repaired: function blocks admit the existing statement-prefix/final-value grammar, including `r = zeroed(42)` as an assignment followed by a parenthesized value. The final value fills named result storage before cleanup, with matching assignment and origin facts. Final none-returning calls, try calls and statement controls retain named assignments; mixed value/no-value control edges remain refused, including reference results. Unconditional exits and unchecked regions still cannot prefix a final expression. The runtime fixture covers scalar, shaped, reference, generic, anonymous and fallible results; negative controls retain early-return, typing, escape and grammar refusals. | Recovery in first batch; final values implemented in third batch |
| A3: type-shaped construction arguments | Repaired: seven type-only field/payload cases receive L0301 before value access; four type-only trailing fills receive L0102 under the existing expression grammar. Controls cover module, local and instantiated types. The variant-array initializer had valid case metadata; its root-array destination had base field zero. Lowering now captures the reached aggregate in the existing typed-address form before selecting its variant. Construction also preserves the existing L0305 module storage-address exclusion, including nested fields and payload fills; runtime-local addresses and callback bodies remain allowed. | Third batch implementation |
| C3: retained reference origins | Implemented: destination storage checks cover inout parameters, pointees, slice elements and reference-bearing ordinary/variant fields. Known local alias writes preserve stored frame/parameter origins; an untracked sibling cannot mask them. Runtime controls retain declared retention, same-origin updates and independent pointer descriptors. Both build modes pass the focused suites and fixture profiles. | Second batch implementation |
| C4: variant payload alias lifetime | Implemented: payload storage lifetime is independent of reference-bearing type. Direct and known-alias replacements, inout calls, derived addresses, cleanup and reachable loop uses participate; runtime controls cover last use, siblings, copied computed subjects and descriptor rebinding. D217 pins the construction boundary, and pointer-backed retags preserve initializer effects. Both build modes pass the focused suites and fixture profiles. | Second batch implementation |
| C5: dense inference matrices | Implemented: the three dense matrices and four signature/declaration arrays now use heap storage owned by one limited controlled object, including partial-allocation, incomplete-pass and exceptional exits. The existing fixed-point algorithm and completeness boundary remain intact. Six exact selectors pass 33 checks in each build mode; no exhaustion threshold or scaling stress was rerun. Dense storage growth remains an explicit limitation. | Third batch |
| C6: nested-call depth | Implemented with J37: shared call-depth accounting includes recovery clauses, and refused calls skip their balanced argument list. Exact boundary and following-declaration controls pass in both modes; no overflow reproduction. | Exact acceptance open |
| M1: conformance lookahead | Repaired in the follow-up parser group: lookahead stops at the binding initializer delimiter. Small literal/call initializer controls preserve a following `is` binding; existing parameterized and ordinary conformance syntax stays covered. | Third batch implementation |
| M2: consumed subplaces | Repaired bare element, enclosing-aggregate and descendant reads after sink. Field paths above and below an array index retain separate identities; computed reads account for possibly consumed elements. Assigning an ancestor restores its consumed descendants without reviving a consumed ancestor through a partial write. Ten negative cases and runtime sibling/copy/restoration controls pin the result. | Second batch implementation |
| M4, M16: tour and prototype drift | Named facets reconciled after reading all four complete prototypes: live formals and conformance labels use lowercase names without colliding with runtime parameters; tour allocations use initialized object/byte-buffer APIs; explicit legacy prototype calls supply every static formal; retired worklist links name this roadmap; the reader consumes one file handle with the whole reader. Historical findings remain byte-identical and deliberately retained raw-storage sketches stay labelled historical. The prototypes remain specification sketches, not newly enabled programs. | Fourth batch |
| M5: font history | Local ancestry and tree inventory confirm the font-addition commit remains reachable from `66927e93`. The maintainer chose to leave the font files for now. R4.91 therefore makes no font deletion or history rewrite; this disposition does not change license terms or erase the retained finding. | Disposed by maintainer: retain for now |
| M6: historical closure anchors | Source provenance reconciled: R1/R2/R3 gate sections now name retained source witnesses, and the R4.20/R4.21/R4.30 records explicitly identify pre-rewrite inputs. Nine old/rewritten pairs differ only by three removed agent-guidance documents; the R4.30 tested tree differs from its committed successor only in three closure documents. Closed by maintainer disposition: original R1/R2/R3 run bundles have not been recovered, so those historical runs remain explicitly unverifiable. Retained source witnesses are preserved; current acceptance proves only its own revision and does not fill the historical evidence gap. | Fourth batch |
| M7: R4.70 obligations | Superseded by R4.70/R4.90: closure now records complete derivation, scalar-origin normalization, nested field ranges and direct parameter coverage. Preserve their fixtures and later full acceptance evidence. | Existing coverage |
| M8: stale decisions/citations | Implemented for the named findings: D203–D207 distinguish completed historical R4.40 evidence from current R4.91 acceptance; D14/D31 retain admitted slice length; D74/D75/D89/D102 cite the actual variant, selection and matching rules, and the current unassigned variant-return pin remains with D106. check.py rejects evidence paragraphs calling a non-active roadmap owner active. No semantic rule or historical acceptance input changes. | Fourth batch |
| A5, M9: source-path bytes | Implemented: the offline decoder writes exact path bytes and an ASCII coordinate suffix through binary stdout. Build identity remains mandatory. The existing non-UTF-8/quoted/colon path control now runs under strict UTF-8 and strict ASCII output policies with bounded subprocess timeouts. | Third batch implementation |
| M10: diagnostic rendering growth | Implemented with J13: terminator-free line spans support bounded local excerpts, and the report renderer shares one explicit text budget across messages, labels and notes. Structured reports and original byte locations remain intact. The old stress measurement was not rerun. | Third batch |
| A4, M11: native failures | Implemented with J112: native reads/writes retain ordinary device-failure outcomes; failed capture reads raise External_Tool_Failed through owned cleanup instead of becoming empty successful output. Tiny file/capture and fake host-exception controls pass. Device exhaustion and active-capture fault injection were not run. Layout exception conflation remains J65. | Third batch implementation |
| M12: stage organization | Large nested stage procedures and duplicated construction helpers remain. Refactor only with established behavioural controls; size alone is not a correctness finding. | Fourth batch |
| M13: build mode and locks | Repaired: mode validation precedes path construction. Inherited OS locks cover build plus test execution; cleanup takes both mode locks or an exclusive all-tag lock. Permanent lock files survive cleanup, with no PID reclamation race. Disposable-tree regressions cover contention, nested builds, concurrent modes/tags, cleanup, stale context and termination. Rejected modes are tested only by loading the environment. | Second batch implementation |
| M14: harness contracts | Stream repair implemented: recorded, runtime and ABI oracles honor the selected stream and require empty stderr for output-only expectations, using separately captured native stderr. Fake wrong-stream/additional-stderr controls and tiny native captures pass. Suite inventory is repaired too: startup checks missing and unlisted suite names, while check.py compares every suite source with its registration and expected name. Corpus accounting now compares Ada discovery with the independently generated target inventory, then checks attempted programs, recorded outputs and runtime/ABI profiles against metadata obligations. Named nonempty categories remain required. Validation is metadata-only; complete corpus execution and exact acceptance remain open. | Fourth batch implementation |
| M15: profile selection | Implemented with N17/J20: every runtime/ABI fixture declares standard or specialization profiles in validated metadata. Renaming cannot alter its matrix. The migration preserves all previous profiles and adds forced specialization to the four erased-dispatch fixtures. Metadata-only development validation is recorded below; executing the expanded matrix remains exact-acceptance work under the resource limits. | Fourth batch implementation |
| A8, M18: publication and CI | Guarded publication replaces the obsolete automatic compiler manifest and checks approved canonical main before private-font access and again before upload. The audit confirms that uploads from independent jobs still lack a shared lock; a recheck cannot prevent an older in-flight upload from finishing last, and domain uploads are separate. No stale upload was performed or observed. SourceHut publication serialization is implemented through a canonical Git lease; write-permission verification subsequently passed in job 1888216; the first approved publication remains delivery work. Font subset and shared highlighter checks are present; M5 separately owns history. Guide resolution is repaired to use each source directory, avoid repeated README basename collisions and route unrendered repository guides to their source view. Documentation states the selected guide inventory and the participating-job publication guarantee and activation requirements accurately. | Fourth batch; permission verified, publication pending |
| A6: text traversal wording | Reconciled: [1810] and the tour distinguish validated utf8/utf16 and literal C strings from D199 foreign C strings. D184 already requires scalar validation and malformed-encoding traps even in unchecked; no atom error or runtime contract changed. Existing fixture and prototype coverage is retained. | Fourth batch documentation repair |
| A7, M19: emitted operand identities and stride | The stride guard is implemented with J61/N6/K29 using bounded scalar and emitted-text evidence. The shared renderer now quotes a whole-name dot as well as leading dollar names. Fourteen selected checks pass on each host; bounded pinned-GNU object inspection confirms exact dot/dollar identities, function sizes and direct/runtime/static relocations. No linking or execution was used. Exact-revision acceptance remains open. | Third batch |
| A9, m18: third-party inventory | Implemented: the root inventory names the existing Lucide, SourceHut and Nunito Sans notices, and the Tree-sitter support headers now carry their pinned upstream MIT notice. All three headers match v0.26.9 upstream bytes. Optional private MonoLisa remains separately documented. Project and upstream license terms are unchanged; M5 still owns any historical font disposition. | Fourth batch documentation repair |
| M17: stale refusal ownership | R4.90 changed the implicated notes to describe source-form boundaries and implemented distinct/fill forms. The earlier blanket enabled-yet report is superseded; retain bounded checks for any remaining inaccurate sites. | Existing coverage |

The remaining minor observations retain these explicit dispositions rather than
being silently promoted to bugs or discarded:

| Older minor identifiers | Disposition |
| --- | --- |
| m1 | Code-only negative fixtures prove ordered diagnostic identity, not full report wording, span or causal fidelity. Exact reports and focused source/IR assertions remain necessary where a repair depends on those distinctions. The historical inventory is not a current coverage count; no blanket negative-fixture replay or bulk oracle regeneration is authorized. |
| m2 | Oracle repaired: the defer/undo no-unwind fixtures now register exit(99), so reaching cleanup before or after a fault produces an ordinary exit and fails the trap expectation. A fake outcome pins that distinction. The tiny fixtures compile to assembly text only; their revised runtime/profile evidence remains outstanding. The operating-system signal remains deliberately unspecified under [1960], and timeout remains refused as trap evidence. |
| m3 | Implemented: each positive assembly, runtime executable and ABI assembly/link attempt removes its expected output before the producer runs. Removal refusal, missing output, directories, abnormal termination and nonzero exit cannot satisfy the attempt. Fake producer cases pin stale and repeated attempts without executing tools. Type-only or external-only positive modules may legitimately emit no function; emitted coverage does not claim instruction semantics. |
| m4 | Reconciled: lex metadata belongs to check.py's independent grammar scanner. The Ada reader accepts it but never treats Python complaint wording as its diagnostic oracle. The fixture guide now states that boundary and points to ordered codes, optional exact reports and lexer span/token cases. No claim of full Ada wording coverage follows from lex metadata. |
| m5 | Implemented: successful fake writes replace visible bytes and their latest-write record; reads, existence checks and shallow listings see them. Refused writes preserve previous bytes. Single-file removal has native and fake adapters with directory preservation and injected refusal. Fake filesystem and tool state have controlled owners, releasing vectors and captured bytes on normal or exceptional scope exit. Fake tools can raise a chosen one-shot host failure; driver cases distinguish missing-tool advice from capture failures while preserving the original cause. N13 retains the earlier directory-identity repair. |
| m6 | Generator repaired: fixed 32-bit xor/shift mixing replaces reduction of the LCG state's low bits. An arithmetic-only case uses 288 draws to reject the old 256-byte repetition and forced alternating parity, check byte diversity and retain fixed-seed reproducibility. No generated input reaches the compiler in that case. The changed source-mutation campaign has not been run and historical campaign evidence does not validate its new stream. |
| m7 | Broader driver mutation coverage remains absent. Targeted checker/lowering/driver regressions cover confirmed repairs but do not establish fuzz coverage. No unbounded or broad campaign is authorized. |
| m8 | Implemented under the existing [1930] explicit-discard rule: a valued break targeting a statement loop is refused with L0301. Ordinary, guarded, completion, range and labelled transfers keep their selected target; `_ =` explicitly consumes an unwanted loop result. Small checker controls cover both accepted and refused forms without assembling or executing a program. |
| m9 | Reconciled with the explicit R1.70 decision: ordinary module folds use the kernel’s wider signed range, then check the final destination width. D224/[1940] now state that existing contract; the u8 intermediate-300 example remains accepted, while runtime u8 arithmetic remains checked. Exact image and positive/negative fold-limit controls cover both target widths. No new folding behavior or unbounded integer type was adopted. |
| m11 | Refuted against D138: a saturated explicit static tuple performs the same exact recursive validation as deduction. An independently synthesized singleton atom therefore does not equal a wider explicit atom-set actual. First assigning the atom to a binding of that set type is accepted. Paired tiny compile-only probes retain this existing contract; no generic conversion rule changed. |
| m10 | Confirmed against [1910]'s every-return-edge obligation and repaired: explicit, guarded and propagated failure check consumed `inout` places after applicable cleanup. Expression-body completion now checks the same obligation. A consumed named result is also refused on successful return. Five refusal cases and successful `defer`/`undo` and result restoration controls pin these exit obligations. |
| m12 | Integer productions now require a final base digit while preserving repeated internal underscores, matching the existing scanner. The character grammar defines unicode_scalar through an explicit shortest-form UTF-8 scalar primitive; used lexical names no longer bypass undefined-rule checking. Independent grammar controls pin valid/invalid separators and scalar boundaries. D162/D166 explicitly require the same boundaries for every float component. The scanner now checks the formerly omitted whole-part run, and decimal_digits/hex_digits end in a digit; the bounded whole-part fixture and eighteen lexical controls pin malformed runs, valid repeated separators and recovery. |
| m13 | Wording repaired: [1790] distinguishes thirteen scalar and three text-view predeclared names; [1900] and the tour explicitly describe addr retaining place writability. The old D124 permission note is superseded by the current complete type/shape/permission diagnostic, as pinned by derived-address-readonly. Reference permissions and their one-way relaxation are unchanged. |
| m22 | Integer guidance repaired: L0011 now describes required digits, allowed underscores and valid start/end digits, covering empty prefixes and trailing separators as well as out-of-base digits. Tiny lexical controls retain codes and full-run spans; repeated internal underscores and the current 12z token split remain accepted by the lexer. Comment encoding is repaired under [1750]: the scanner uses the literal decoder's shortest-form UTF-8 check, reports the first invalid byte per comment with L0012, and retains delimiter/token recovery. D164 already chooses the maximal opening quote run: six adjacent quotes are an unterminated six-quote opener, not empty raw text. The grammar now requires content; the tour and tiny lexer/decoder controls pin later closers, shorter runs, retained line endings and ordinary empty quoted text. |
| m14 | Sampled unused helpers and the unused Needs_Source catalogue facet remain maintenance observations; exception routing is reconciled separately with J109. |
| m16 | The inherited D-label namespace and F2's roadmap-wide process ownership are explicit. C6 now assigns hosted parity to R5.50 and freestanding evidence to R6.100. Mechanical checks reject a completed item with an incomplete dependency and require one nonempty Blocked because line for a blocked item. The alleged global D-number resolution is refuted: the specification lookup is confined to conformance-register Rules cells, not inherited roadmap labels. Narrative gate accounts are reconciled: historical source witnesses and missing original bundles are distinguished under M6; R4 and R4.91 remained active at that batch boundary, with both project status pointers naming R4.91 and R5 depending on it. The closure record below supersedes those status pointers. No development transcript supplies a new acceptance tag or closes a phase. |
| m17 | Implemented: README and handoff include R2.10, R4.21, R4.30 and R4.40, with the selected C ABI and separate binding generator explicitly described. The zeroable account names settled D143 behavior. Four aggregate fixture summaries now cite the decisions that actually pin them, without changing any source or expected compiler verdict. |
| m21 | D190 and R7.20 retain the actual carrier ranges without stale source-reference counts. A new tiny negative fixture pins D202's L0305 refusal when an option reuses the compiler-owned debug atom, including its full diagnostic. |
| m15 | Implemented: the compiler guide now covers all 71 package specifications, including the 18 formerly missing packages for allocation, machine evidence, IR transforms, reports and layout policy. Directory descriptions name the current responsibilities; parent and child package boundaries are explicitly distinct. A mechanical check compares the ownership rows with private, generic and ordinary package specs and rejects missing, repeated or obsolete rows. |
| m23 | Source attachment is contractually dense and ordered: Attach_Source requires the next Source_Id and guarantees its module mapping; its sole caller passes the identity just appended to the compilation source set. Ignoring the argument in the append implementation therefore does not lose an admissible identity. Imported_Module still performs a linear source/node lookup; this is a maintenance cost observation, with no established wrong result or new stress run. |
| m19 | The automatic Nix manifest was retired, so that skip-path claim is obsolete. J77/J78 repair manifest/image-tag failure propagation with bounded fake-command controls on both hosts. Container pin duplication remains a source-level observation. |
| m20 | The quality facet is superseded by the current threshold witness: size/auto must decline while speed/auto selects, with exact source cost inputs, decision reasons and independently counted machine indirect calls. Treating the two objectives identically would fail those assertions. Debugger coverage includes function-name entry stops, stepping, expected local values and stack shape in addition to line-number round trips; those round trips alone remain insufficient proof of every line mapping. This is source-oracle reconciliation, not a new quality/debugger run or acceptance claim. |
| m24 | Reconciled with implemented J91/K21/K22: bounded block runs partition each item and every instruction agrees with its owning block; orphan and overlapping claims are refused. The separate one-pass reachability concern is refuted with J98: Pointer_Provenance unconditionally builds the full control-flow graph before acceptance. Existing focused malformed-IR and reachable/unreachable-cycle controls remain the evidence; no broad verifier case was rerun. |
| m25 | Refuted as a current valid-IR simplifier failure. Simplification verifies its input and output. A pointer-carrying range check either receives matching pointee metadata or an explicit integer-to-usize Conversion. An ordinary Load obtains its pointee from its slot, and pointer/address slots are excluded from store-to-load forwarding. A raw usize Load cannot supply the conversion witness; the verifier refuses that proposed input. Required_Proof therefore pins the actual Conversion on the admissible construction path. This is source-contract evidence, not a newly reproduced optimizer failure or a changed pass. |
| m26 | Implemented: 26 expressions with sibling emitting calls now evaluate those calls in explicit written order, including slice descriptors, UTF validation, text traversal and nested decoding helpers. IR.Dump.Text offers a detailed metadata view with pointee definitions/edges, signature/result/slot/value annotations, nominal shape identities and Place_Address endpoints. The default compact format remains compatible; it is not an oracle for metadata equality. Tiny UTF8/UTF16/cstring lowering controls and a metadata-only dump difference control pin these boundaries. No broad golden regeneration or excluded fixture replay was performed. |
| m27 | Reconciled with [0410] and D106: an assignment's destination is selected before its RHS call; the callee's separate named aggregate result is transferred on return. Thus value.p = shrink(value) overwrites p with the returned pair while preserving inout writes to sibling q. The result destination is not a second source inout parameter under D149. A focused IR case and a small runtime fixture pin this existing behavior; revised runtime execution remains outstanding. |
| m28 | Confirmed baseline cost limitation: two tiny none/off assembly-text witnesses show two bounds checks for indexed inc and one for +=, with exactly one index-function call in each. The inc witness also uses a smaller frame (32 versus 64 bytes), so replacing its path wholesale is not an established improvement. No wrong result or repeated index evaluation was found. Retain this cost observation without a correctness repair; guard elimination needs separate optimization evidence. No assembler or performance campaign ran. |
| m29 | Compact compiler repetition still emits assembler repetition for some static images. Assembly cost remains a separate resource concern: the named giant fixtures and enormous expansion directives must never be assembled. Any emission optimization needs tiny shape/text controls; no large timing or memory experiment is authorized. |
| m30 | Disposed as a driver-compatibility limitation: the supported Linux finishing path selects the triplet GNU driver; an override must accept the same emitted dialect and argument contract. Explicit .L ELF names remain permitted and Unused_Local_Prefix avoids generated-label collisions. The separate Clang header frontend is not an LLVM assembler compatibility promise. The compiler guide now states that boundary. No new namespace restriction, LLVM probe or ABI-fixture replay was introduced. |
| m31 | Implemented: relative assembly and output filenames beginning with `-` or `@` gain a `./` prefix in the toolchain argv, retaining native file identity while avoiding option/response-file interpretation. Absolute, already-prefixed, ordinary and spaced paths retain their spelling; ordered libraries, selected linker and build ID remain intact. Pure argument-construction controls perform no filesystem writes or external invocations. |
| m32 | No current counterexample established. In the retained tiny factory witness, both unoptimized factories already return anonymous item 4; size folding aliases only the factory bodies, preserving that callback address. The current optimized path excludes actual address exposures, including instruction, image and evidence references; its baseline comparison only considers instances of one generic template under D138/D144 and a bounded allowed-op proof. The attempted provider witness failed conformance checking and is not optimizer evidence. Retain the observation without changing policy or claiming proof for every callback program; no assembler or repeated probe ran. |

#### Follow-up review at the repair revision

Paseo agent `1d4fbfe5-e992-4fdc-aacd-554f81557713` reviewed `0a3d0a28`,
including the first three repair commits. Its completed source-only sweep and
verifier/synthesis records have been reconciled here. The synthesis contains
27 ranked entries, including repeated open work, informational observations
and an explicitly refuted claim; these are not 27 newly reproduced defects.
`N1` through `N27` below identify positions in that synthesis's ranked list, not its
presentation's separately numbered major findings. No new agents, assembler
sweep, debugger or stress campaign was used for this reconciliation.

| Follow-up entries | Disposition and next action |
| --- | --- |
| N1, N4: frontend and R5 readiness | Duplicate A2/C2/M3, A3, C5, C6 and M1 above. R5 remains planned behind R4.91 and exact acceptance. The review adds no new measured exhaustion threshold. |
| N2: declaration recovery | Confirmed with small parser inputs and repaired: recovery retains `extern`, array/pointer/erased conformance heads and ordinary named conformances. A C declaration retains both its bodyless flag and convention. |
| N3: statement recovery | Confirmed and repaired for contextual loops, transfers, match, cleanup and blocks, plus selected assignment/call heads. The focused seam compares the valid source with one stray token inserted before it, requiring one report and preserved node kinds, names, child slots and C convention. |
| N5, N7, N8: fixture inventory and low floors | Implemented with M14: discovery must match every identity/target row in the independently generated inventory; parser and execution loops account for all eligible programs, recorded outputs and selected profiles, with explicit nonempty categories and metadata-error stops. No historical fixed counts were adopted. Counts cannot prove semantic coverage after intentional deletion and regeneration. Validation uses fake catalogues and real metadata only; no fixture-deletion experiment or broad corpus run was performed. |
| N6: wide slice stride | Implemented with J61 and A7/M19/K29: shared immediate-width selection and a register multiply for larger strides. Development evidence uses scalar boundary constants and tiny emitted-text controls; no giant extent or assembler reproduction. |
| N9: negatives without `program` | Implemented with J79: recorded and source negative executions share termination, declared/default status and exact ordered-code checks. Recorded bytes remain independently checked, including CLI fixtures without a program. Exact acceptance remains open. |
| N10: duplicate operand diagnostics | Repaired: failed compound operators retain their ill-typed result, and the late operand check skips that operator after visiting its children. Seven float remainder/shift refusals each report L0301 once; an independent nested integer division by zero still reports L0306. Existing integer zero-divisor and negative-shift controls retain their diagnostics. The new fixture and four selected existing controls pass in macOS debug and Linux release with 30-second per-case limits; no source is assembled. |
| N11: `Expect` recovery after a refused lexeme | Implemented with J101: Expect skips only scanner-refused tokens and leaves the next kernel token to its caller. Existing bounded preservation controls retain following declarations and local type recovery without duplicate lexical reports; the earlier broad forward-search description is superseded. |
| N12, N23: `12z` and `!=` diagnostics | N23 implemented: parser reports at adjacent `!=` name the existing `<>` operator under [0350]. The hint follows the primary source span after recovery, preserving tokenization, codes and recovery. Six fixed sources cover comparison/condition typos, the correct operator, ordinary/spaced error syntax, literals and comments. N12 is disposed under the existing token boundary: 12z is integer 12 followed by name z, and r = 12z = 3 can validly start the next assignment. A tiny accepted assembly-text probe confirms that boundary. It is not one accepted numeric suffix. Widening malformed-number runs would reject existing programs; the current 12a malformed-base-digit guidance and parser-context diagnostics remain unchanged. |
| N13: fake filesystem paths | Implemented under m5: registered directories accept trailing separators for existence, identity, listing and directory-read refusal. File paths retain exact spelling; missing paths gain no identity and other aliases remain explicit. Four entry/root combinations and the existing file/module identity, shallow listing and read-status controls pass on both hosts. |
| N14: L0010 ownership comments | Repaired the catalogue, syntactic wrapper, fixture guide, checker docstring and repository guidance. D164 already records removal of the scanner's final deferred family; L0010 is now parser-only. Numeric bands still do not determine ownership. |
| N15: parser determinism oracle | Implemented under m1--m7: three fixed small inputs are each parsed three times, comparing canonical node/slot text, full diagnostic text, status and counts across reused and independently seeded name tables. Independent acceptance/refusal and declaration-count checks keep the comparison non-vacuous. Twenty-four checks pass on each host. No corpus, truncation, generated-input or mutation campaign was run. |
| N16, N17, N18 | Duplicates A4/M11 native failures, M15 explicit profile selection, and M10 diagnostic excerpts. Keep their existing repair order and evidence requirements. |
| N19: real-host exception comments | Repaired the two missing comments and the corpus agreement case's misleading claim to mutate files. These cases read the native repository corpus and alter strings only. Their broad generated-input workloads were not rerun. |
| N20: undocumented `r480` profiles | Repaired the fixture guide to match existing selection. This closes the documentation omission, while M15 still owns replacing name-based policy with explicit metadata. |
| N21: assignment through payload aliases | Refuted as a repair request: D78/D217 make an inout payload name an alias to storage, not a descriptor that assignment can rebind. Writing it remains a use of that storage. The existing negative write-after-retag control intentionally enforces this rule; removing the pattern-binding exclusion would weaken it. |
| N22: runtime unwind tables | Confirmed limitation: emitted CFI is debug-only `.debug_frame`; `.eh_frame` consumers are not promised. Keep the existing source-debugging/frame-pointer contract. Runtime foreign exception unwinding requires a separate explicit semantic/ABI decision and is outside this repair slice; no debugger or unwind experiment was run. |
| N24: retired No_Frontend source shape | Clarified the catalogue comment: file-independent driver errors need no source, source-attached errors do, and the retired row keeps its original contract. No live diagnostic or retired identifier is changed. |
| N25, N26: range and sequencing | Passing review observations; no implementation task. Preserve the recorded resource model, backend order and R4.91 dependency gate. |
| N27: chained-comparison poisoning | The review itself refuted this claim. Error diagnostics already stop the pipeline before checking; a structurally sound node does not override that stop. No repair is needed. |

The follow-up review's nine coverage gaps remain explicit limits on its claims:
expression/conformance recovery, extreme input scaling, diagnostic actionability,
target-width arithmetic, fixture inventory, backend/tool integration, native
failure modes, driver gating, and IR/reader-guide currency. The first eight map
to the open rows above and the older minor register. The IR partition reported
no surviving defect; absence of the IR reader guide at the reviewed commit is a coverage
note, not a request to undo the separately authored guide. Future representation,
verification-boundary or optimization changes must check that guide's integrated
version. Source-only review and prior development tests do not establish full
runtime or exact-revision acceptance.

Follow-up development evidence: the macOS debug compiler builds with one
build worker, and five targeted cases pass 295 checks: recovery heads,
conformances, C-syntax recovery, parameterized alias recovery, and the fake-host
R4.91 refusal-without-effects case. The new recovery case contains 17 short
controls; two additional controls pin the conformance lookahead boundary.
Each selected test has a 30-second timeout; the two diagnostic reproductions
have 10-second timeouts. Release validation of this group remains outstanding.
No Landin fixture was assembled, and existing broad coverage was not rerun.

#### Additional review at the same repair baseline

Paseo agent `60e74218-b6c7-416c-b259-2619912dcfc7` also reviewed
`0a3d0a28`. Its retained report, decisions and raw verification records were
reconciled against R4.91 at `7250d298`. This intake adds no new review agents
or coverage campaign. `J1` through `J139` identify the report's presentation
order: twelve critical headings, forty-eight major headings, then seventy-nine
minor table rows. These are stable intake identifiers, not the raw JSON order.
The original severity labels describe that review's ranking; they are not an
independent assessment of current severity or evidence.

The report contains 139 distinct observations: 124 marked confirmed by source
inspection or reproduction, fifteen plausible, and thirteen separately refuted
claims excluded from that total. Those refuted claims are not reopened here.
The table preserves baseline evidence as `C` or `P`; an open row is an owned
investigation/repair obligation, not a claim that this intake independently
reproduced it. In particular, J53 retains the verifier's narrower plausible
restoration question rather than its refuted general aliasing rationale.
J45 is disposed below and J70 implements the existing loop rule; latent IR/API observations do
not establish accepted-source failures merely by naming absent guards.

The original review built and checked on macOS, with the documented Linux
runtime case unavailable. It did not execute Linux runtime fixtures or validate
release behavior. Its statement that disabled debug preconditions necessarily
hand malformed IR to the backend in release is an untested prediction, not
adopted evidence. No previous broad run was repeated to fill those gaps.

Current intake evidence comprises eleven explicitly selected compiler-only
runs in macOS debug, each with a ten-second timeout and optimization and
specialization disabled. J1, J2 and J3 were accepted while their positional,
direct-destination and bound-result controls respectively produced L0302,
L0314 and L0302. J7, J9 and J10 each exited 70 without a source diagnostic;
J12 accepted the constrained generic type case; J39 reproduced the false
unclosed-function report. These establish eight current findings, not release
or runtime outcomes. Sources and exact transcripts are retained locally in
`.scratch/r491-review-60e74218/`, alongside the original report and a mapping
from every J identifier to its raw record. No source was assembled or linked.

| Intake | Baseline observation | Evidence | Disposition and repair scope |
| --- | --- | --- | --- |
| J1 | A labeled application in statement position bypasses definite-assignment and use-after-sink analysis entirely | C | Repaired: labelled statements use the same flow dispatch as positional calls, including ordered runtime arguments, sink consumption and recovery. Paired initialized/unassigned and sink controls pass in both modes; driver refusals have no output/tool effects. |
| J2 | A joined storage fact launders the escape check: a frame address can be written into caller or module storage and be accepted | C | Implemented: body-local joins retain every external/parameter destination, and the approved D222 writable-return contract rejects hidden independent storage behind a `from` clause. Explicit fallback arguments retain their destinations at direct and indirect calls. The final batch passes 217 selected checks per host plus compile-only mem/vec/small accessor probes. Empty, raw, read-only, generic, provider and same-origin controls remain pinned. Exact acceptance remains open; no callee-body inference was added. |
| J3 | A `sink` argument is not consumed when the call sits inside an ordinary expression, so use-after-sink is accepted | C | Repaired: evaluated nested calls retain mutable flow state in operators, literals, constructions, indexes, receivers and assignment destinations. Short-circuit joins retain possible consumption; fixed-array measurements and anonymous bodies remain unevaluated in the enclosing flow. Source-order and restoration controls pass in both modes. |
| J4 | Lower_Slice loads a slice descriptor's two words through two independent lowerings of the same place, so a call in the access path runs twice and base/length can come from different objects | C | Repaired: Lower_Slice evaluates the stored access path once and captures a reached runtime descriptor before either carrier load. Component loading consumes that retained place. Tiny struct/array slice, index, traversal and text controls retain one side-effecting index call; terminating paths retain their existing guard. |
| J5 | A block struct whose closer does not name it swallows every declaration up to a later matching `end <name>`, with no diagnostic | C | Repaired: a struct checks its immediate end and optional repeated name, preserving later declarations instead of scanning for a distant matching closer. Missing ends and mismatched names report at the current boundary. Field-type refusal retains its existing recovery and diagnostic without a second missing-end report. |
| J6 | Module identity is the raw directory string, so a non-canonical or relative entry-directory spelling loads the entry module twice and splits its module state | C | Implemented: the driver reuses a loaded directory when the platform proves existing-object identity, preserving its first path spelling and module state. Exact paths retain the fast lookup; uncertain or distinct directories remain separate. Relative/trailing/dotted fake paths, native relative/trailing paths, diagnostic spelling, root order and graph controls pass in both modes. |
| J7 | An inline parameterized type application in a declared type makes the R2.20 "not enabled yet" refusal silent, so checking accepts and lowering exits 70 | C | Repaired: unsupported array/struct initializers report L0304 even when the written application already has a normalized type. Existing refusals report once; valid literal/construction initializers retain acceptance. Driver controls reject before output or host tools in both modes. |
| J8 | A call to a user declaration whose name is a builtin scalar or text name is silently read as a [0700] conversion, so the declaration is never called | C | Repaired: resolved declarations take precedence over builtin scalar/text spelling in checking and lowering. Direct, indirect and generic calls retain their targets; scalar/text aliases retain their actual conversion type. Calls cannot masquerade as folded static initializers. |
| J9 | Comparing two function values is accepted by the checker and then crashes the IR verifier (exit 70) | C | Repaired: the temporary carrying the left operand across right-operand evaluation retains its function signature. Named, local, parameter and control-flow function comparisons satisfy the existing verifier on 32/64-bit targets; a right-side mutation does not change the saved left value. Mismatched signatures remain refused. |
| J10 | Range slicing a non-array, non-slice value is accepted with no diagnostic and crashes lowering (exit 70) | C | Repaired: a non-array/non-slice target reports L0301 before lowering. Scalar, pointer, aggregate and callback refusals preserve the existing cstring and bound-type diagnostics; fixed-array, slice and utf8 controls remain accepted. Driver controls reject before output or host tools in both modes. |
| J11 | Runtime variant case construction accepts a non-storage aggregate payload that lowering can only copy from storage (exit 70) | C | Implemented: nonzero aggregate payloads use the ordinary shaped-value writer, preserving the selected case path while materializing call results, distinct conversions, control values and computed elements. Selecting the case still supplies the zero image for zeroed payloads. |
| J12 | Actual_Key erases [0660] range-subtype constraints, so a parameterized type application silently turns `percent` into `u8` | C | Repaired: type-template actuals retain D188/R7.20 refusal before interning an unconstrained identity. Normalized pointer/slice targets and array elements also enforce the existing constrained-composition boundary. Direct, aliased, nested and unused actuals refuse once; ordinary constrained values and unconstrained type/deduction controls remain accepted. |
| J13 | Rendered diagnostic report is quadratic and unbounded; past Integer'Last the run dies with exit 70 and loses every diagnostic | P | Rendering growth repaired with M10: line excerpts use bounded slices and the complete text defaults to a 1 MiB budget with an explicit truncation notice. Full structured reports remain intact. The old exhaustion/exit-70 magnitude claim remains unmeasured; no stress case was replayed. |
| J14 | The optional struct end name in [1795] is not optional: a bare `end` on a struct is refused as a stray token | C | Already repaired with J5: block structs consume their immediate `end`, optionally consume a repeated name, and preserve following declarations. The retained J5 bare-closer/parser and source-to-IR controls cover this duplicate finding; no separate feature or stress run is needed. |
| J15 | The named refusal [1830] promises is missing for `noreturn`, `volatile` and multi-name bindings | C | Implemented: noreturn retains its [0890]/R6.70 refusal. The type-position volatile ptr shape now receives one [0850]/R6.80 L0010 while ordinary volatile names remain legal. Shared bindings, fields, parameters and returns receive a [0100]/R7.20 L0010; additional names are consumed once for recovery. Atom declaration lists retain their existing implementation. Focused cases retain following declarations and pin primary wording, code and ownership notes. Labelled bare blocks remain the separate J40 item. |
| J16 | `lenof` on a slice is treated as a non-reading type constant, so an unassigned or sunk slice descriptor is read | C | Repaired: lenof reads a live, assigned slice descriptor. Fixed-array names and measured literal elements remain unevaluated. Slice length and index refusals include consumed descriptors without duplicate reports; both compiler modes pass the controls. |
| J17 | `Require_Element` compares the sub-element run for equality instead of prefix containment, so a whole-child write inside an array element does not cover its leaves | C | Repaired: reads and branch merges use ancestor containment for an element's field path. Eleven paired controls pass in both modes: whole-child writes cover descendants, either branch order preserves common leaves, and siblings, other indices, parents and consumed descendants retain their independent obligations. Lookup walks only the selected path's ancestors. |
| J18 | Match_Subject_Is_Copied disagrees with Lower_Variant_Match about a payload alias root, rejecting valid code as a frame escape | C | Implemented: checking retains runtime-address aliases through nested computed match subjects and builtin collection elements. Captured slice and array backing supplies address origins and store destinations; frame temporaries and copied iterable/text/index values remain distinct. Nested retags now retain C4 payload-lifetime checks. Bounded controls pass in both modes. |
| J19 | A `try` nested in a non-control expression skips its failure-propagation edge: sunk `inout` parameters and `undo` arguments go unchecked | C | Repaired: nested try expressions retain their propagated failure edge, including undo reads and inout restoration after applicable cleanup. The success-only restoration is refused; restoration inside a failure cleanup is accepted. Both modes pass. |
| J20 | Forced-specialization profiles silently skip the runtime/erased-* evidence-dispatch fixtures | C | Implemented with M15/N17: all four erased-dispatch fixtures explicitly select the six-profile specialization matrix. Required profile metadata replaces name matching for runtime and ABI selection. Validation checks metadata and selection only; no expanded runtime sweep was run. |
| J21 | Array-literal element containing a variant part crashes lowering (Constraint_Error on Positive (Destination.Base)) | C | Already repaired by 1aa0746a under A3: normalize the root variant-array destination into typed storage. Retain the existing debug/release and runtime evidence; do not replay it. |
| J22 | Several expression-lowering paths emit IR after the flow has already terminated, so a program the frontend accepts dies with an internal compiler defect (exit 70) | C | Repaired: slice bounds/sources, descriptor copies, addresses, inout and slice actuals, conversions and any operands stop after terminated evaluation. UTF8 indexing creates decoder blocks only after its ordinal continues. Twenty-five tiny sources verify reachable calls and complete IR on both target widths in both modes. J23/J26 retain their separate merge/loop work. |
| J23 | Lower_If leaves an orphan merge block when a later arm's condition terminates the flow, and the IR verifier then rejects the unit | C | Repaired: a terminating later condition reopens an existing merge from earlier continuing arms before returning to its caller. Remaining tests/arms stay unevaluated. First-condition, all-return, multiple-arm and value-position controls pass on both target widths in both modes. |
| J24 | Destructuring binding from a labelled-argument call or `try` raises a compiler defect (exit 70) | C | Repaired: destructuring dispatch admits labelled calls and try expressions into the existing typed temporary path. Positional, reordered-labelled, try and labelled-try forms retain their named fields and verified IR on both target widths in both modes. |
| J25 | Assignment to an anonymous multi-result aggregate from a labelled call, `try`, or loop value violates `Res.Bound_To`'s precondition | C | Repaired: anonymous-result assignments route labelled calls, try and loop/while/for values through caller-owned result storage instead of name-only storage lookup. Positional, labelled, propagated-error and all three loop forms pass in both modes. |
| J26 | A `complete` body that never falls through leaves the post-loop block with no predecessor, producing malformed IR | C | Repaired: breaks and completing bodies allocate their shared exit only when an emitted edge reaches it. Returning, continuing and failing complete bodies leave no orphan post-loop block. Nested labelled breaks, break values, cleanup and continuing completion controls pass in both modes; source-only break scanning is removed. |
| J27 | Aggregate assignment to a computed or reference-borne place from a loop value raises "a contextual storage value has no rooted place" | C | Repaired: dynamic/reference aggregate destinations admit loop/while/for values into the existing shaped temporary and copy path. Array-indexed, pointer and inout destinations pass; explicit call-order checks retain one destination evaluation before the RHS, and an all-return RHS skips copying its temporary. |
| J28 | Anonymous function with a pointer result gets the wrong IR item result kind (exit 70) | C | Repaired: anonymous routine items lower pointer results to the same usize carrier as named routines. Read-only/mutable, array, nominal and cstring referents, local callbacks and named/scalar controls retain their full signature and from metadata on both target widths in both modes. |
| J29 | `Made` is set for an array-root image the code deliberately did not store, so the copy path violates `Image_Length`'s `Has_Image` precondition | C | Repaired: recursive array construction marks an explicit image made only when it stores one. Implicit/explicit zero aggregate arrays, copy chains and forward copies retain distinct zero-initialized storage; finite images and empty pointer-array controls pass on both target widths in both modes. |
| J30 | Module struct slice field initialized from a name or member selection raises "a static slice field has no image form" | C | Repaired: slice-bearing struct images use the existing complete descriptor builder; the verifier selects its recursive checker when any descriptor carries a slice. Direct, named, member, nested, empty and variant slice images retain backing targets, offsets, lengths, element shapes and tags on 32/64-bit targets. Explicit malformed descriptors retain bounds/shape refusals. This also repairs the valid variant slice literal found during K1. |
| J31 | Module `ptr`/`cstring` binding with no initializer passes `Ty.Pointer_Value` to `IR.Emit_Number`'s `Integer_Name` parameter | C | Repaired: omitted module pointer/cstring initializers report L0301 at the checker boundary, applying the existing no-all-zero-reference rule. Explicit pointer addresses and cstrings remain accepted, as do local references assigned before use. Driver checks prove no output or tool invocation. |
| J32 | Module slice binding with no initializer calls `Slice_Shape` with `Syn.No_Node` | C | Repaired with J31: omitted module slice/utf8/utf16 initializers report L0301 before image lowering. Explicit empty slices retain their non-null base; explicit text, aliases and mutable-slice controls preserve the existing zeroability rule. |
| J33 | Erased evidence table is built for a conformance whose sibling entry is not object-safe, with no D146 gate on that path | C | Implemented: selection validates every distinct closure entry before recording erased evidence, sharing construction's object-safety predicate and retaining pointer-permission checks. Safe tables and unused any transport remain accepted; exact acceptance remains open. |
| J34 | A struct field whose type is a user type named `variant` is misparsed as a variant part when the field name equals the struct name | C | Repaired: empty-variant recovery cannot consume the enclosing struct's own closer. A real case still establishes a variant part, including one sharing the struct's name. Earlier/later scalar aliases and an aggregate user type retain ordinary field selection and measurement; empty and mismatched parts retain their diagnostics. |
| J35 | A function closed with a bare `end` swallows the next declaration's name, rejecting a valid file | C | Repaired: optional function-end names leave recognizable following declarations intact. A matching repeated name retains its closing role; a different explicit closing name still reports L0109. Paired syntax controls cover eighteen declaration forms, and both target widths retain distinct module items and the correct direct callee. |
| J36 | `Else_Closes_Arm` leaks into loops, bare blocks and unchecked regions nested in an `if` arm, rejecting a valid `call else value` | C | Repaired: nested control scopes and delimited expressions save and restore enclosing arm context. Loops, blocks, matches, anonymous bodies, nested else arms, arguments, literals, conversions and selected bounds keep their own call recovery. A direct then/elsif arm still owns its else; parentheses retain explicit recovery priority. |
| J37 | Nested call expressions have no depth guard: unhandled STORAGE_ERROR, raw traceback, exit 1 | C | Implemented with C6: guard nested calls and recovery clauses; read refused public prefixes iteratively. Bounded parser controls pass in both modes; exact acceptance remains open. |
| J38 | A bare `break`/`continue` consumes the following `complete` as its label, deleting the complete clause's scope | C | Implemented: retain completion boundaries; D225 now reserves `complete`, so it cannot name a loop; preserve declarations, assignments and nested labels with that spelling. Selected parser, verified-IR and refusal controls pass in both modes; exact acceptance remains open. |
| J39 | Parser recovery skips the very anchor token it needs, producing a false "function is never closed" and corrupting all following declarations | C | Repaired: list recovery preserves an already-current anchor and advances only when it must find one. Its callers consume their opener or exit the list before handing the boundary back. Paired valid/broken syntax tests preserve following functions, mutability, calls, fields and array elements; existing same-token diagnostic suppression still reports nested missing closers once. |
| J40 | A labelled bare block `scope: begin ... end scope` is parsed as a binding, and its `end` closes the enclosing function | C | Documentation reconciled with [1810]: the tour and prototype 1 now spell their scoping blocks as begin/end without a label. Labelled bare blocks remain outside the enabled grammar; no parser keyword or speculative interception is added. D225 later renames the example's ordinary type to block_value because begin is now reserved. The exact positive selector passes three checks on each host; exact acceptance open. |
| J41 | `break`/`continue` inside an anonymous function body is accepted by the parser when the enclosing function has a loop, then crashes the checker (exit 70) | C | Repaired: an anonymous function establishes a loop-stack floor, so neither unnamed nor labelled transfers can target its enclosing routine. The outer label stack survives nested anonymous functions. Its body also clears the outer contextual complete marker and restores it on return. Invalid transfers retain L0110 before checking; local loops and outer completion remain valid. |
| J42 | Labelled application with an indexed or sliced callee raises an internal compiler defect (exit 70) in resolution | C | Repaired: only a Name_Reference supplies a lexical callee name. Indexed, sliced and selected callees resolve their complete expression before arguments. Stored callbacks reach verified indirect calls; indexed/sliced non-functions retain L0301 instead of an accessor failure. |
| J43 | An unclassified labelled application leaves callee and arguments unresolved; the typo is reported as a struct-construction context error | C | Repaired: absent direct callee names and available runtime argument projections use ordinary resolution, even when the application cannot be classified. Missing names report L0201; type-only arguments await known formals. A shared conversion-name predicate preserves builtin checker ownership and declared-name shadowing. |
| J44 | Runtime parameters and named returns resolve their types before later binders are collected, so parameter order changes acceptance | C | Repaired: declared and anonymous routines collect all runtime parameters and returns before resolving their written types, sharing one delayed type walk. Later value binders shadow outer aliases just like earlier ones. Static formals, no-capture scope, written function-type labels and return-source positions retain their existing contracts. |
| J45 | Any pre-flight CLI diagnostic silently disables the entire frontend (syntax/name/type checking) for the given sources | C | Disposed as a diagnostic-policy observation, not an established correctness defect. An invalid CLI request already fails with its configuration diagnostic; no contract requires syntax/name/type results under that invalid configuration. The driver deliberately gates stages after errors. Retain that boundary rather than broadening R4.91 into speculative checking after a refused request. |
| J46 | Multi-result placement check overflows Byte_Count and crashes with exit 70 on a written function type | C | Repaired with J60: result placement uses the existing recursive shape measurement with a non-raising Fits result, which guards every target-sized product before multiplication. Final placement still checks field and tail padding. The oversized source witness was not executed; bounded result signatures and scalar placement-boundary checks provide development evidence. |
| J47 | Duplicate member names in a non-parameterized struct body are never checked, so the second member is silently unreachable | C | Repaired: ordinary and template structs share label-uniqueness checks for common fields, variant-part labels and each payload's own fields. Collisions report L0309 at the later label with the earlier label related. Separate payloads and nested structs retain independent namespaces; invalid ordinary types propagate refusal to their consumers. |
| J48 | Static generic `T.entry(...)` silently resolves an inherited entry-name collision by parent declaration order instead of diagnosing it | C | D221 resolves static lookup explicitly: distinct declaring concepts make a selected name ambiguous, including direct/inherited collisions; a diamond visits its shared ancestor once. The checker refuses the selection without adding a runtime-type cascade. Unused collisions and distinct names remain legal. Six exact selectors pass 70 checks on each host; ordinary/template field-name findings retain their separate dispositions. Exact-revision acceptance remains open. |
| J49 | Any malformed concrete conformance entry list raises "a collected conformance lost its normalized key" (exit 70) instead of reporting its diagnostic | C | Repaired: collection marks invalid entry lists and colliding declarations refused. Provider validation skips those declarations and retains their original diagnostics; valid single/multi-input keys and providers still validate. Missing associated input labels also cover K13. |
| J50 | Cyclic concept constraint on the represented formal recurses without a visited set and overflows the stack | C | Repaired: the existing finite concept-graph walk includes type-formal constraint edges as well as named parents. Tiny self, mutual, mixed and unused cycles report L0301 before lookup; an acyclic constrained-formal control passes. The exhaustion witness was not executed before the guard. |
| J51 | A used parameterized conformance with a bad entry list raises "selected conformance lost a provider" instead of reporting it | C | Repaired: parameterized provider selection skips declarations refused during collection. A missing entry retains L0301 and its consumer reports the ordinary L0318 unsatisfied constraint, without creating incomplete evidence or raising a compiler defect. Valid generic providers and signature refusals retain their contracts. |
| J52 | Select_Iterable_Conformance calls Template_Of with No_Nominal_Type for a nominal-less aggregate traversal source | C | Repaired: iterable family matching requires an actual nominal identity before reading its template. A multi-result aggregate now reports the existing L0301 missing-iterable diagnostic; a real nominal family retains traversal selection. |
| J53 | Restoration after sinking through a slice view of an inout array | P | D220 resolves the place-form question through the existing no-dereference boundary: slice indexes reach referenced backing and are refused, including literal indexes through local views. Whole descriptor fields and fixed-array elements remain eligible and retain inout restoration. The broad alias-safety rationale remains refuted; no alias-remapping or ownership rule is added. Six exact selectors pass 63 checks on each host, including instantiated generic controls, paired descriptor/array acceptance and reference-boundary refusals. Exact-revision acceptance remains open. |
| J54 | `sizeof`/`alignof` of an atom, atom-union or function type raises Landin.Compiler_Defect (exit 70) | C | Repaired: checking admits atom and function measurements; lowering uses their U32 and target-word carriers. Static image folding also covers these carriers and pointer/slice/any measurements, with two words only for slice/any size. Existing target-independent array-bound and C-ABI restrictions remain in force. |
| J55 | Check_Aggregate_Payload tests the distinct-conversion escape on the wrong node (`Value` instead of `Given`), falsely refusing a module variant payload | C | Repaired with K6: query the payload expression's distinct conversion, retaining matching, mismatched-nominal and ordinary-field controls. |
| J56 | A range subtype's bounds are never applied to a value that arrives through a control expression, so a statically-known out-of-range value compiles into an unconditional `ud2` | C | Implemented: check literal control results and matching loop transfers without broadening the known-value rule; preserve one owed store check. Scalar implicit routine results now meet their declared range too. Selected controls pass in both modes; J116 is separately disposed against its narrower normative contract; exact acceptance remains open. |
| J57 | Module image `bool` elements are never range-checked, so a non-0/1 bool image reaches lowering and aborts the compiler (exit 70) | C | Repaired: one scalar/recursive image-field walk includes bool bounds for array elements, ordinary fields, variant payload constructors and value fills. Invalid known bool carriers report L0300 before lowering; false/true boundaries and callback relocations remain valid. A shared fill is checked once even when several fields consume it. |
| J58 | `Check_Struct_Image`'s ordinary aggregate-field branch drops the distinct-conversion alternative its three sibling branches have, so a distinct-typed struct field image is never folded (exit 70) | C | Repaired with J57: ordinary and variant aggregate fields use the same distinct-conversion recursion as array elements and distinct representations. Nested distinct overflow, including value fills, reports L0300; valid nominal images retain their identity and pass both modes. |
| J59 | A scalar or text conversion written with any argument count other than 1 crashes the compiler (exit 70, no diagnostic) | C | Repaired: scalar/text conversion identities are classified independently of arity, and a malformed conversion reports L0301 before indexing operands or lowering. Aliases and range subtypes keep the same rule; resolved user functions retain their own arities. Refused origin facts no longer manufacture a secondary from-clause mismatch. |
| J60 | Two named returns where one names a struct whose field type failed to resolve: Layout_Size precondition failure loses the whole report | C | Repaired: routine placement requires settled nominal leaves; written callback signatures wait until all active layouts are complete. Bad field types retain L0304 through scalar, array and nested-array result uses without a false zero-image refusal. Forward, alias, self and mutual callback results are accepted and verified on both target widths. |
| J61 | Slice_Address scales the slice lower bound with an unguarded imm32 `imulq`, so an element extent >= 2 GiB emits an unencodable instruction | C | Implemented with A7/M19/N6/K29: slice scaling and both indexed-access paths share the nonnegative signed-imm32 predicate. Larger strides load a full-width scratch register before multiplication. Scalar boundary and tiny slice controls replace the forbidden giant-array reproduction. |
| J62 | Storage_Address's Frame_Slot arm has no unhomed-slot guard, unlike Slot_Address and Value_Address | P | Implemented as a defensive guard: Storage_Address checks Has_Slot_Home before either whole-slot or field offset arithmetic. Current allocator pinning already prevents a live source trigger. The frame seam distinguishes an unhomed promoted slot from a real zero-byte home, and small address emission remains valid. |
| J63 | A routine's named result binding gets an empty DWARF location list when its assignment is the last instruction that produces code | C | Implemented: initialized, in-scope bindings remain available during return/failure preparation, including implicit returns with earlier routine anchors. Each terminal ends its DWARF range before the first register restore. Tiny text-emission and initialization/scope controls pass; no debugger or native assembly ran. |
| J64 | The DWARF alias walk calls Whole_Slot_Array_Shape and Nth_Field_Shape without the Is_Array and Field>0 guards | P | Implemented as release-checked metadata guards: a zero-field alias must name array storage before a whole-array or positive-field query. A small DWARF seam refuses whole scalar slot/datum aliases and accepts whole one-element array aliases. Current lowering did not produce the invalid metadata. |
| J65 | Frame_Is_Addressable's handler turns any Compiler_Defect from allocation or C ABI classification into a 'frame too wide' diagnostic | C | Implemented: shared checked stack addition/alignment raises a dedicated limit exception, and x86 preflight catches only that exception. Frame and C stack planners receive the actual displacement budget; allocation, ABI and malformed-IR failures remain visible. Tiny budget tests cover size, padding and invalid inputs. |
| J66 | The hosted entry-point refusal (L0502) carries no source span (also behave-diag) | C | Implemented: L0502 points at an active entry-module `main` declaration when present, otherwise the first entry source at byte zero. Imported and local names cannot supply the anchor. The same early refusal still precedes output and tools. |
| J67 | The DW_OP_bregN arm for a register-held address slot is unreachable, and the GP variable path omits the deref | C | Implemented as consistent DWARF serialization: direct values use a register location; indirect bindings use the address in that register with zero displacement. Alias and variable paths share the formatter. The allocator still pins address slots, so this is latent-path maintenance rather than a reproduced source miscompile. |
| J68 | Fill_Array adds a large element offset as a raw 32-bit immediate, while every nearby site loads the constant with movabsq first | P | Guard repaired as backend consistency: suffix offsets share the arithmetic-immediate predicate, using a full-width scratch register above signed imm32. The large-source reachability claim was not replayed; scalar encoding-boundary and three/four-element fill controls cover the repair without a giant image. |
| J69 | Caret and underline are laid out in source bytes under a line echoed raw, so a label after a tab or multi-byte UTF-8 is misaligned | C | Implemented: snippets display tabs as `\t` and bytes outside printable ASCII as `\xNN`; underlines count their displayed characters. Headers and structured spans retain original byte coordinates. This deterministic byte display covers valid UTF-8, invalid bytes and control bytes without a locale/font width assumption. |
| J70 | A `while ... complete` block establishes definite assignment after the loop, which spec.md:505 says it must not | C | Implemented against the existing [1810]/D156/D157 rule: post-loop assignment is limited to entry and condition facts, preserving evaluated for-header effects. The iterative head and actual exit joins still retain consumption and restoration. Scalar, sparse/whole-array and nested-field refusals pass; incoming values, loop results, header effects and early returns remain valid. |
| J71 | tour [0220]'s `hex_value := 0xDEAD_BEEF` does not compile | C | Duplicate M4/M16 document parity work. Check complete examples against the enabled grammar, preserving historical finding sections. |
| J72 | tour [0990]'s destructuring block cannot be written as printed: `whole.rem` glues onto the next line's `(` | C | Duplicate M4/M16 document parity work. Check complete examples against the enabled grammar, preserving historical finding sections. |
| J73 | `addr` of a D160 traversal element binding is classified frame origin, refusing a legal `from`-declared return | C | Implemented: checking retains runtime-address aliases through nested computed match subjects and builtin collection elements. Captured slice and array backing supplies address origins and store destinations; frame temporaries and copied iterable/text/index values remain distinct. Nested retags now retain C4 payload-lifetime checks. Bounded controls pass in both modes. |
| J74 | A compound assignment through an indexed member selection reads its index twice and emits a duplicate diagnostic | C | Repaired: destination evaluation reads the index once before the assigned value. Assignment marking only updates facts, so an unassigned compound indexed-field index reports L0302 once. Small write-order and independent-field controls pass in both modes. |
| J75 | `Widest_Struct` rescans every node of every source file on each call and is invoked once per read | C | Implemented: the ten later queries reuse `Tracked_Field'Last`, whose subtype elaboration already computes the immutable forest width once per flow invocation. No cross-compilation cache or invalidation state is introduced. |
| J76 | First_Derivation points the escape diagnostic's related span at a module binding and calls it "the shorter-lived reference source" | C | Implemented: frame-source selection includes frame-backed payload bindings and value parameters, while excluding external payload storage and inout parameters from that preference. Four exact L0314 reports preserve refusal behavior and identify the actual shorter-lived source. |
| J77 | Pipeline failures in build.sh's content manifest are silently swallowed | C | Implemented under m19: capture and check manifest producers before sorting, propagate inventory/fixed-row failures, and check saved-manifest reads. Bounded fake-command tests preserve the existing manifest format and rebuild decisions on both hosts; exact acceptance remains open. |
| J78 | linux-loop.sh silently collapses to a constant image tag if the Containerfile cksum fails | P | The masked checksum failure is repaired with J77: require a successful, numeric recipe checksum before container inspection. Fake-container tests pin default/override tags and early refusal. The historical claim about a real container accepting an empty tag remains unestablished; no daemon was started. |
| J79 | Run_Negative hardcodes exit status 1, silently ignoring a negative fixture's own `status` metadata | C | Implemented with N9: honor explicit status and default negatives to 1 at metadata parsing; compare ordered codes on both execution paths. Fake outcomes pin status 2, default 1, code order/multiplicity and abnormal termination. Exact acceptance remains open. |
| J80 | Slot_Element_Shape_Is_Valid returns False for every D84/D85 element operation whose base field is a variant part | C | Implemented: the shared slot-element query resolves root-array paths, field paths, separate variant selectors and below-element selections before returning the selected array length or scalar type. Invalid/mixed selections return False. Source variant controls and direct IR controls cover both target facts; this was an API contract defect, with no production caller established. Exact acceptance remains open. |
| J81 | Emit_Function_Address is the only Emit_* without Is_Emitting in its precondition | P | Builder-contract gap repaired: Emit_Function_Address now requires an open emission block and known provenance, matching neighboring producers. Its target/signature requirements remain. No accepted-source failure or new release-time guard is claimed. Exact acceptance remains open. |
| J82 | Enter's "once per block, one at a time" rule is a precondition only; a re-Enter silently rebases the block's First_Value | P | Not an accepted-source defect: nonempty or overlapping re-entry violates the documented caller preconditions. Clarified that Enter opens an empty block and permits only one open block per item; harmless empty re-entry needs no extra permanent state. The structural builder/program verifier boundary remains explicit. Exact acceptance remains open. |
| J83 | Set_Slice_Image has no `not Has_Image` guard, unlike the five other image setters | P | Builder-contract gap repaired: Set_Slice_Image requires an item with no existing image, consistently with peer setters. Production callers resolve each image once; this does not add a release-time guard or establish a source-triggered overwrite. Exact acceptance remains open. |
| J84 | Specialization reports retains_fallback=false for any specialized instance, even when indirect calls it could not devirtualize survive in that body | C | Implemented: decisions report actual surviving indirect calls, including partial erased dispatch, and scalar measurement dumps name the measured type. Independent IR/report assertions cover both target widths; the nine affected scalar golden lines and compiler reader guide are updated. Exact golden comparison and acceptance remain open. |
| J85 | The IR dump never renders Measured_Of, so every scalar sizeof/alignof records as the same line and a wrong measured type cannot move the golden file | C | Implemented: decisions report actual surviving indirect calls, including partial erased dispatch, and scalar measurement dumps name the measured type. Independent IR/report assertions cover both target widths; the nine affected scalar golden lines and compiler reader guide are updated. Exact golden comparison and acceptance remain open. |
| J86 | Dead first branch in Rooted_Steps: its guard is strictly implied by the next one and the bodies are identical | C | Implemented maintenance: one active-alias branch owns Rooted_Steps, and Storage_For alone supplies alias storage. The aggregate-only duplicate branches are removed; the predicate's independent initializer use remains. Exact acceptance remains open. |
| J87 | The slice-element arm of Lower_Unconstrained is unreachable, because every slice index already satisfies Has_Reference_Storage and is taken by the earlier guard | C | Implemented maintenance: removed the slice-index branch and its similarly dominated reference-array sibling. The earlier complete stored-place guard owns both, including single evaluation and typed indirect loads. Exact acceptance remains open. |
| J88 | Redundant inout test inside a branch already known to be non-inout | C | Implemented maintenance: removed the always-true non-inout conjunct inside the non-inout aggregate-argument branch. Argument copying and evaluation order are unchanged. Exact acceptance remains open. |
| J89 | `Held = Ty.Bool` arm in `Lower_Datum`'s zero path is unreachable | C | Implemented maintenance: removed the unreachable bool arm from scalar zero emission and replaced the obsolete zero-only aggregate-image comment with the current static-image ownership. Exact acceptance remains open. |
| J90 | `Set_Image_From_Struct_Field` and its dispatch arm are unreachable since the member-selection redirect | C | Implemented maintenance: removed the obsolete shallow field-image helper and dispatch. Accepted array/aggregate selections return through recursive image resolution; scalar/function/bool/slice/C-string paths return separately, other pointer selections are refused, and any data are outside this resolver inventory. Exact acceptance remains open. |
| J91 | Block membership is never verified: block-run/In_Block agreement and the block partition of an item's value run go unchecked | C | Implemented with K21/K22: bounded block runs partition each item and agree with instruction membership before consumers read them; final item and operand cursors consume their vectors. Small malformed-IR seams and valid reordered/prefixed controls cover both target widths. No accepted-source defect is inferred; exact acceptance remains open. |
| J92 | A variant shape's tag type is not held to being wide enough for its case count | C | Implemented: variant shapes require D74's smallest unsigned tag that represents every zero-based case. Bounded 255/256/257-case metadata controls cover datum fields, slot fields and measurements on both target widths, rejecting narrow and nonminimal tags. No giant case-count witness ran; exact acceptance remains open. |
| J93 | The item's Aliases run, and the Paths run inside each alias, are never bounded or validated by the verifier | C | Implemented: alias runs are bounded and partition their vector, alias path runs are bounded before allocation, and every binding/provenance/storage selection is checked after all root shapes. Small malformed-IR controls and existing source alias/payload cases pass in debug and release. No debugger session was started; exact acceptance remains open. |
| J94 | Scalar_Field_Of converts an unbounded Part_Position with Natural() on the runtime-address path, turning a Fault into a Constraint_Error | C | Implemented: runtime-address field comparisons widen the field count before narrowing a validated index. One-field load/store controls include the first excluded index, an index beyond Natural and the Part_Position maximum, on both target widths. Exact acceptance remains open. |
| J95 | Store into an aggregate or array slot is not refused, while Load from one is | C | Implemented: scalar stores refuse struct and array slots before Type_Of is called. Tiny controls retain scalar, struct-field and array-element stores in debug and release; this is a malformed-IR backstop, not a source miscompilation claim. Exact acceptance remains open. |
| J96 | Load_Datum / Store_Datum refuse only an aggregate datum, not a fixed-array datum, and Load_Datum's result is never checked at all | C | Implemented: scalar datum operations refuse nonscalar storage; Load_Datum checks retained callable and atom metadata against its datum. Tiny builder-only controls expose metadata attached after a load. The alleged caller-supplied result-kind mismatch remains refuted: the builder derives that immutable result. Exact acceptance remains open. |
| J97 | Flat aggregate-image path never checks Aggregate_Field_Image.Slice on variant payload leaves, but the backend acts on it | C | Superseded by J30 (abbdb466): any slice-bearing descriptor, including a variant payload, selects the complete recursive verifier. The reported three-byte array descriptor is now refused; genuine slice payloads retain target/range/shape checks. Dedicated small regressions pin that disposition without changing the verifier again. Exact acceptance remains open. |
| J98 | Block_Unreachable only checks that an edge exists, so an unreachable cycle of blocks passes | C | Refuted on current and reviewed source: the cited incoming-edge scan is followed unconditionally by Pointer_Provenance, which checks true entry reachability through Control_Flow.Make. Both 0a3d0a28 and 66927e93 already contain this check. Tiny self/pair islands are refused without slots or pointers; reachable cycles pass. No reachability implementation change was needed. |
| J99 | An upper-case letter gets the generic L0012 'no rule spells these bytes' citing [1750] | C | Repaired: an all-uppercase invalid-byte run retains L0012 and its original token/span boundaries while explaining lower-case identifier spelling with [1760]. Mixed invalid runs retain the generic byte report and recovery. Exact lexer and rendered-report controls pin both paths. |
| J100 | Repeated delimiter-free conformance/signature lookahead on malformed input | C | Implemented for the reported repeated scans: a per-parse delimiter index answers signature matching and unmatched-opener refusal; zero-depth conformance suffixes cache their result. Both delimiter counters and contextual-is rules are preserved. Small exact diagnostics replace any need to repeat old scaling runs; no universal parser complexity claim is made. |
| J101 | Expect's post-lexical-error forward scan crosses construct boundaries and mangles the parse | C | Implemented with N11: Expect skips only scanner-refused tokens, leaving the next kernel token to its caller. Missing parameter/return colons recover locally through type parsing, preserving nested type delimiters, sibling parameters and subsequent declarations without duplicate lexical reports. |
| J102 | Parse_Fixed_Conditional consumes the arm's condition when `if` is missing, producing a three-diagnostic cascade | C | Implemented with J103: fixed-conditional openers are consumed once when present; a missing if leaves its condition in hand. The bounded source reproduction now reports only the original L0103. One-, two- and three-arm syntax controls preserve conditions and following declarations. Exact acceptance remains open. |
| J103 | Dead Is_Else guard in Parse_Fixed_Conditional's arm loop | C | Removed with J102: the fixed-conditional loop handles only conditional arms and exits before the separately parsed else arm, so its never-true Is_Else guard and assignments are gone. Accepted and missing-opener controls cover the remaining branches. |
| J104 | Contextual control words conflict with the intended reserved-word rule | C | D225 supersedes the initial ordinary-binding repair: reserve begin, break, complete, continue, defer, do, for, loop, match, unchecked, undo, while and with in every name position. Parentheses are not an identifier escape; existing name uses require renaming. Token dispatch, grammar and scope controls now enforce that decision; the editor grammar has the same reserved set. Sixteen exact selectors pass 1,482 checks on each of macOS debug and Linux release; exact acceptance remains open. |
| J105 | Diagnostic and recovery for return followed by a name | C | Superseded by 7250d298: the return-followed-by-name witness now has one L0110 at the final value and retains its function closer. The recorded r491-function-final-value-prefix fixture pins the exact report. More specific return-carries-value prose would be optional diagnostic refinement, not an outstanding recovery repair. |
| J106 | Two `link(symbol:)` diagnostics cite [1580] (Importing from C) instead of [1610] | C | Implemented: all link-annotation notes consistently cite [1610] and the normative `text` parameter type. Missing-colon and missing-close probes retain their original L0103 code and single report. Exact acceptance remains open. |
| J107 | Match-arm control classification omits For_Statement, diverging from the three sibling lists | C | Implemented: a match arm classifies For_Statement alongside loop and while before assigning its value slot. Small syntax controls preserve loops with value-carrying breaks and place ordinary loops in the statement run. No accepted-source miscompilation is claimed; exact acceptance remains open. |
| J108 | The same source passed twice under two spellings is read twice, so every declaration in it is reported as declared twice | C | Implemented: explicit inputs retain the first successful snapshot and spelling, skipping only repeated names or proven existing-object aliases. The new platform identity predicate keeps uncertainty distinct from output-overlap refusal. Equal-content files remain distinct, and rooted module ownership is unchanged. |
| J109 | Only Compiler_Defect is caught around the pipeline, so an internal Constraint_Error/Program_Error discards the already-decided report | P | Implemented: Execute retains collected diagnostics for unexpected exceptions before returning Status_Defect. Compiler_Defect, Constraint_Error, Program_Error and Assertion_Error are pinned by one-shot fake reads; Host_Exhausted, Storage_Error and External_Tool_Failed retain their dedicated outer handling. Exact acceptance remains open. |
| J110 | --root= with an empty value is left in the Roots list and could in principle drive a filesystem-root search | P | Not a current source defect: the empty-root diagnostic marks the context failed before discovery, and the queue exits before import lookup can reach Select_Module_Directory. This independently confirms the retained review critic's unreachable-path analysis. Preserve that validation boundary when changing module recovery; no real-root traversal was run. |
| J111 | Padded() silently truncates a target name longer than 24 bytes instead of asserting | C | Implemented private constructor contract: target labels longer than their fixed storage raise Compiler_Defect in every build mode; valid labels copy in full and remain space-padded. Current named constructors are unchanged and no arbitrary target constructor was added. Exact acceptance remains open. |
| J112 | Read_File/Write_File only catch Name_Error and Use_Error, not other Ada.IO_Exceptions | P | Implemented expected-outcome handling under A4/M11: Device_Error joins Name_Error/Use_Error for native reads and writes, and failure cleanup suppresses only those expected close outcomes. Programming/resource exceptions retain their separate path. Device failure was not induced; bounded ordinary-file and host-exception controls pass. |
| J113 | An ordinary local binding resolves its declared type after its own name enters scope, unlike a D185 condition binding | C | D218 explicitly settles the previously unstated type-scope rule: written type and initializer resolve before the local is introduced. Small scalar, reference, fixed-bound and generic list-element controls accompany self-reference and later-shadow refusals. Seven exact selectors pass 29 checks on each of macOS debug and Linux release; exact acceptance open. |
| J114 | A namespace import used as a value is reported as a misspelling that is not declared in any scope | C | Implemented: an otherwise unresolved bare value use of a file-local imported namespace reports that it needs a member selection, with the existing L0201 code/use anchor and a [1860] note. Ordinary lexical lookup still wins, including same-named module values; aliases, parameter shadows, selected imports and sibling-file scope retain their rules. Exact acceptance remains open. |
| J115 | Resolution's retained call formal is order-dependent and read by no compiler stage | C | Implemented maintenance: removed the unused formal-declaration field, query and order-dependent signature-scope lookup. Argument roles and role-local positions remain; checking remaps runtime positions from the complete signature. The existing classification case now calls a later declaration and asserts its static position. Exact acceptance remains open. |
| J116 | A statically known out-of-range slice bound over a fixed array is not refused | P | Not established as a normative defect. [1950] explicitly limits its known-bound refusal to an element index; neither that text nor its index-only D148 evidence extends it to slice range endpoints. The implementation checks endpoint types and retains runtime range checks outside unchecked. D187 explicitly removes the slice-range edge inside unchecked. Extending static endpoint rejection requires a new semantic decision, not the J56 range-subtype repair. |
| J117 | An untyped literal lower bound of a `for` range is committed to i32 before the upper bound is consulted, and the diagnostic blames the upper bound | C | D219 explicitly settles the former context omission: either typed integer endpoint supplies an untyped peer; two untyped bounds retain i32. Known typed mismatches and out-of-range literals remain refused. Small prototype-derived headers and diagnostic controls accompany the change. Four exact selectors pass 20 checks on each of macOS debug and Linux release; exact acceptance open. |
| J118 | `zeroed` against a pointer/slice/atom context reports L0304 'needs a directly supplied initializer' pointing at completed R2.20, though the context is supplied and the refusal is permanent (also docs-code) | C | Implemented: the generic zeroed fallback reports L0301 with the permanent contextual requirement at [0540], instead of L0304 promising completed R2.20 enablement. Seven fixture code lists are corrected; unrelated deferred aggregate-initializer refusals remain L0304. Admitted scalar, array and struct zeroed paths remain accepted. Exact acceptance remains open. |
| J119 | Distinct-type identity and zeroed mismatches are reported with struct wording and notes citing [0710] and function addresses | C | Implemented: nominal copy and assignment refusals describe identity independently of representation, contextual distinct results name the distinct type category, and zeroed diagnostics use general type/place labels. The reported distinct-u32 refusal no longer invents a struct or function address. Exact acceptance remains open. |
| J120 | A refused range-subtype reference target cascades into a spurious L0303 about writing through an `in` parameter | C | Implemented: Check_Place stops at a settled ill-typed root instead of treating a failed reference projection as replacement of its in parameter. The original range-reference refusal remains the sole report for that write. Exact acceptance remains open. |
| J121 | A parameterized layout(c) struct's C-representation check is skipped in the symbolic template pass | C | Implemented: symbolic descriptors preserve proven non-C shapes through aliases, arrays and nominal applications. Unused C-layout templates reject those proofs and tagged variants without guessing unknown fields' layouts. Eight exact L0301 reports and valid formal/pointer/array/C-callback controls pass. |
| J122 | Shown returns phrases that already carry an article, producing "this does not have the a pointer shape required here" (also check-5, behave-types, docs-code, check-3) | C | Implemented: contextual mismatches name the required pointer, slice, function, aggregate or erased type without doubled articles or the unknown-type fallback. Their explanation applies to the complete required context rather than asserting every site is a D124 control expression. Exact acceptance remains open. |
| J123 | Reject_C_Signature and Validate_C_Layout pass the same origin as both primary span and Related span, printing the snippet twice | C | Implemented in text rendering: a first related label sharing the primary source and complete span supplies the one rendered snippet. C signature/layout labels, every structured diagnostic field and catalogue requirements remain intact; different files or span ends remain separate. Exact acceptance remains open. |
| J124 | Multi-result placement sizes a fixed-array result by its U8 element placeholder, so the too-large check under-counts by the element size | C | Repaired with J46/J60: placement measures each result's complete descriptor, including nested arrays, nominal elements and reference carriers, instead of its scalar placeholder. Tiny nested/reference/empty array signature controls pass; no oversized source or generated image was executed. |
| J125 | `sizeof`/`alignof` of an array type bounded by a fixed formal is refused inside a bound generic routine instance | C | Implemented: type normalization and fixed-bound folding retain the active routine instance's type/fixed actuals in newly encountered type positions. Direct, arithmetic, type-formal and parameterized-alias measurements keep separate two/four-element instances. Negative, impossible and runtime bounds retain their specific refusals. Exact acceptance remains open. |
| J126 | `Require` commits an untyped integer literal to `bool` for every non-scalar expected type, producing a bool-flavoured [1890] diagnostic for struct/array/pointer/any contexts | C | Implemented: Require commits integer literals only to real scalar contexts, and refuses non-scalar contexts with the original required-site origin and label. No default numeric commitment or invented bool precedes that report. Struct, two-element array and function argument witnesses are pinned; pointer/slice/erased arguments already use independent paths. Exact acceptance remains open. |
| J127 | Out-of-range constant index diagnostic is missing its noun: "this index is outside the 2 this array has" | C | Implemented: constant-index diagnostics include `element` for length one and `elements` otherwise, using the target-sized count directly. Empty, singleton and two-element probes retain one L0306 report each. Exact acceptance remains open. |
| J128 | Is_Zeroed_Scalar_Place's Is_Direct_Named_Return alternative is dead | C | Implemented maintenance: removed the direct-named-return alternative already implied by Is_Direct_Binding_Name. Named returns and their allowed scalar subobjects retain the same zeroed contexts. Exact acceptance remains open. |
| J129 | Inferred `[n of x]` with a non-scalar repeated element emits no diagnostic of its own and leaves the value un-refused, so the user gets only a false "needs a counted inferred binding" message | C | Implemented: a non-scalar repeated element receives the shared explicit-element-type refusal unless its own error already explains the failure. Every rejected inferred repetition retains an ill-typed expression fact before its binding is settled, preventing the later false counted-binding report. Four source errors now produce four reports instead of seven. Exact acceptance remains open. |
| J130 | A match arm's ordinary-struct payload alias may be copied by assignment but not used as an explicitly typed binding's initializer | C | Implemented: local typed payload copies are admitted before match-header types are available, then checked against their nominal destination. Inferred aliases and chains wait for the match header, retain their nominal descriptor and resume in the body walk; this also repairs a related inferred-copy internal defect. Read-only/writable, unused, chained, generic and different-nominal controls cover both target widths. Exact acceptance remains open. |
| J131 | Two refusal sites lack the `Ill_Typed` guard their siblings have, so an already-refused operand draws a second, wrong-first diagnostic | C | Implemented: range traversal preserves an ill-typed lower endpoint without a second type report, and pointer conversion refuses an already ill-typed operand before numeric checks or pointer facts. Independent non-integer refusals remain. Exact acceptance remains open. |
| J132 | `any(...)` over a refused pointer union runs conformance selection before the union guard, emitting a spurious L0318 ahead of the real refusal | C | Implemented: pointer-union refusal precedes all any-construction conformance lookup and instantiation. A real missing conformance still reports L0318; its related origin now names the current required any type rather than the first same-concept reference elsewhere in the program. Exact acceptance remains open. |
| J133 | One mistake in a generic template body is reported once per instantiation, so an actual-independent error is printed N times with identical span and text | C | Implemented: checking attributes new diagnostics at instance-view transitions and coalesces identical complete reports across instances of the same template. Early discovery, nested views and final body checks share the policy; different spans, labels, notes or actual-type messages remain. Ordinary checking and transport retain duplicates. |
| J134 | `Checked_Instance_Count` is set to the post-loop instance count, so any routine instance created while the ready-instance loop itself runs is never offered to `Check_Routine_Body` | P | Bookkeeping contract repaired: capture the initial instance count before its fixed-bound body pass and retain that exact visited boundary for the late pass. Any instances created during body checking remain eligible afterward. The small provider witness already accepted/refused correctly before this change, so no reached source miscompilation is claimed. Exact acceptance remains open. |
| J135 | Referents_Agree returns False for an erased `any` carrier, so References_Agree says an `any C` reference is not equal to itself | C | Implemented: erased carriers compare their directly held concept before the referent-kind switch; pointers and slices to any retain their existing referent checks. Small table controls pin reflexivity, duplicate identity, concept mismatches, permissions and nested references. No reached source miscompilation was established; exact acceptance remains open. |
| J136 | Note_Owed_Check is the only node fact with neither a routine-instance overlay nor a double-write guard | C | Implemented as table-invariant maintenance: owed checks use the current routine overlay, retain global fallback when unwritten, and refuse conflicting rewrites within a layer. A two-instance seam covers ownership and restoration; no instance-varying constrained actual is claimed as enabled. The separate written-constraint loss found during validation is R4.91-F2 below. |
| J137 | Field_Array_Element answers `bool` for an array field whose element is a struct, reference or nested array | P | Implemented as API maintenance: removed the scalar-only query and migrated its two callers to complete element shapes. The alleged source miscompile remains refuted: recursive images already bypassed this scalar path and ordinary type checking refused mismatches. |
| J138 | Out-of-scope type name in an anonymous function's signature gives duplicated and misleading L0304 diagnostics | C | Implemented: ordinary unresolved type names use L0201 with a scope note, and normalization retains an already-refused name without adding a parameterized-type feature report. The anonymous two-name fixture retains exactly two reports; named deferred widths keep L0304. Standalone generic normalization remains a separate report path. |
| J139 | Struct refused for a non-zeroable atom/pointer/slice/distinct field is told "a function address has no zero image" (also docs-code) | C | Implemented: aggregate and omitted module initializers explain that the complete type must permit a zero image, including atom, pointer, slice and distinct restrictions. Existing function-field refusals retain their code and source spans. Exact acceptance remains open. |

The flow-dispatch repair closes J1/J3/J16/J19 and the related duplicate-index
report J74. `checking/nested calls retain flow effects` contains 32 small
accepted/refused controls spanning labelled calls, argument order, literals,
short-circuiting, indexing, slice receivers, assignment destinations and nested
failure cleanup. Reading a slice descriptor preserves independent element
liveness: a consumed element stays dead, its known sibling stays live, and
lenof reads neither element. The case also preserves the unevaluated fixed-array
measurement and separately checked anonymous-body boundaries. Four new fake-host driver inputs
require one L0302 and zero output writes/tool runs for both assembly and
executable requests. No language rule or aliasing guarantee was widened.

Development evidence for this group: ten explicitly selected cases pass 267
checks in each of macOS debug and Linux release. Besides the new checker and
driver controls, these cover fallthrough merges, defer/undo reads, the two
existing unevaluated-lenof fixtures, consumed subplaces, sunk-inout exit edges
and final-value refusals. Builds use one worker; each selected test has a
30-second timeout. Logs are retained in `.scratch/r491-flow-effects/`. No
Landin assembly, linker sweep, runtime execution, debugger or mutation campaign
was run. These filtered checks establish the repair group's development
evidence, not the full R4.91 acceptance gate.

The J2/J17 development batch adds `checking/joined destinations keep escape
obligations` and `checking/assigned children cover element descendants`, with
30 small accepted/refused sources. Two additional fake-host driver inputs
require one L0314 and no output writes or tool invocations for both assembly
and executable requests. Sixteen explicitly selected cases pass 356 checks in
each of macOS debug and Linux release, including the retained C3/C4 origin,
payload and consumed-place controls. The existing
`runtime/r491-reference-store-origins` source also passes compiler-only checking
in both modes; its executable was not built or run. Builds use one worker,
selected tests have 30-second timeouts, and that source check has a 15-second
timeout. Evidence is retained in `.scratch/r491-origin-joins/`. No Landin
assembly, linking, runtime execution or debugger was used. This is filtered
development evidence; exact acceptance remains outstanding.

The body-local J2 repair exposed a separate call-return contract question.
A helper could return a choice between a parameter and a module address while
satisfying its declared parameter-only `from` set. The caller reconstructed
only that source and lost the module destination. The retained compiler-only
`call-summary.ldn` witness in the same evidence directory was accepted at that
revision. D222 below resolves this facet through an approved written contract;
the earlier body-local repair alone did not provide that promise.

J2's writable-return recommendation was approved by the language owner after
reviewing the hidden-module witness and an explicit two-input `choose`.
D222 adopts the stronger contract: a writable `from` result cannot conceal
known independent storage. Passing the fallback explicitly and naming both
sources preserves `choose`; the module actual remains visible to the caller,
while a same-origin update stays valid. Read-only results, ordinary container
accessors, independent allocator results and [0470]'s explicit boundary retain
their stated contracts. Nested writable references and erased/aggregate
carriers use conservative permissions and origins.

Implementation and bounded validation are complete for this facet. The checker uses its
existing external-origin fact at the return boundary and retains each
independent anonymous result before joining it with other results. Controls
cover hidden wrappers, indirect calls, providers, concrete generic instances,
empty and raw boundaries and the explicit two-destination API. This work does
not add callee-body inference, authorize excluded stress tests or close exact
revision acceptance.

Both single-worker builds pass: macOS debug and pinned Linux release. The
39-source checker case makes 156 assertions over the synthetic 32-bit and
Linux 64-bit targets. The existing 38 joined-destination checks, paired new
fixtures (5 and 3 checks), three accepted origin fixtures (3 each), and the
retained-store negative fixture (6) bring the final selected total to 217 per
host. Positive fixture selectors emit assembly text only. A separate tiny
compile-only client of `mem.used`, `vec.used` (scalar and pointer elements)
and inline/spilled `small.used` passes on both hosts. No generated executable,
assembler, linker, debugger, giant fixture or broad sweep ran for this batch.
The four fixture inventories and full `python3 check.py` pass. Evidence is in
`.scratch/r491-writable-from/` and the matching final-values logs. Initial
control syntax corrections and the empty-carrier proof adjustment are retained
in those logs; the final counts above describe the corrected sources.

This intake extends the scope of the earlier repairs without erasing their
controls: C3 covers the recorded direct destination/alias cases, and J2 now
covers body-local joined destination facts; M2 covers the recorded consumed
places. The J1/J3/J16/J19 repairs extend flow dispatch and nested effects, and
J17 extends descendant initialization within an array element.
C4's lifetime repairs remain in force while J18/J73 compare reference roots.
J21 is already repaired, J105 is partly superseded, and J100 remains distinct
from the repaired initializer lookahead. Existing N-series dispositions and
all earlier delivery evidence remain unchanged.

Older minor-review closure: m24 maps to the completed block-partition and
reachability work (J91/K21/K22/J98). The m25 source audit follows the verifier's
range-check witness, storage-derived load metadata and the simplifier's
pointer/address-slot exclusion; its proposed forwarded raw Load cannot be a
valid incoming witness. No optimizer or verifier change or broad replay was
needed for those dispositions.

For m22's comment encoding repair, single-worker macOS debug and pinned Linux
release builds pass. Fourteen fixed byte sequences supply 53 assertions for
encoding, first-invalid-byte spans and recovery. Existing comment, quoted,
character and raw literal controls plus exhaustive fault/code mapping bring
the total to 101 checks per host. The decoder shares one bounded scalar
validator and no comment-sized temporary buffer. Full `python3 check.py`
passes, with the diagnostic matrix refreshed. Evidence is in
`.scratch/r491-comment-utf8/` and the matching build log. No assembly, generated
program, debugger, mutation campaign or broad fixture sweep ran.

For m16, seven temporary roadmap snapshots check the live state, completed
work depending on active/planned work, absent/empty/repeated blocking reasons,
and a valid recorded reason. All controls and full `python3 check.py` pass.
Evidence is in `.scratch/r491-roadmap-invariants/`. No live work status was
changed, and no execution or acceptance evidence was inferred from prose.

For m17/m21, the four corrected fixture citations match their normative
Pinned by entries; fixture source programs and previous verdicts are unchanged.
The new compiler-atom option refusal passes six checks on each host using the
unchanged macOS debug and pinned Linux release binaries, including exact
report bytes. All four fixture-record generators and full `python3 check.py`
pass. Evidence is in `.scratch/r491-review-docs/` and matching final-values
logs. No rebuild, assembly or generated-program execution was needed.

For m15, eight disposable-tree controls check ordinary, private and generic
package specifications, missing/repeated/obsolete rows, unreadable declaration
syntax and a missing guide. The live 71-package inventory and full
`python3 check.py` pass. Logs and controls are under
`.scratch/r491-package-guide/`. This is a documentation/invariant repair;
no Ada source changed and no compiler build or fixture run was needed.

For m22's integer guidance, both single-worker builds pass. The ten-input
lexical case has 24 assertions, covering missing digits, wrong-base digits,
separator placement and unchanged accepted token runs. Existing catalogue
code/span and rendering controls add six, for 30 checks per host. The generated
diagnostic catalogue/matrix is refreshed for the note. Full `python3 check.py`
passes after regeneration. Evidence is in `.scratch/r491-lexical-guidance/`
and matching final-values logs. No fixture verdict, lexer rule, assembler or
runtime behavior changed; m12 and m22's other facets remain open.

For m8, macOS debug and pinned Linux release single-worker builds pass.
Fourteen small sources check statement and value loops, guards, completion,
ranges, aggregate discard and labelled targets across nesting. The new case
has 35 assertions including diagnostic guidance; the existing assignment-boundary
case adds 32, for 67 checks per host. Full `python3 check.py` passes.
Evidence is in `.scratch/r491-loop-discard/` and matching final-values logs.
These checks stop at checking; no Landin assembly, linking or execution ran.
The change enforces [1930], with [1190] teaching the explicit-discard form;
prototype loop examples retain their existing plain-break behavior.
Exact-revision acceptance remains open.

For m31, both single-worker builds pass. The new pure argv case has six path
pairs and 12 assertions; the existing linker-selection case adds four, for
16 checks per host in macOS debug and pinned Linux release. They create no
files and run no toolchain. Full `python3 check.py` passes. Evidence is in
`.scratch/r491-file-operands/` and the matching final-values logs. Compiler
file identity, library order and selected linker/build ID remain unchanged;
only the driver-facing spelling of leading `-`/`@` file operands is guarded.
Exact-revision acceptance remains open.

N23 development evidence: the single-worker macOS debug and pinned Linux
release builds pass. Four exact parser cases pass 100 checks per host: the
six-source inequality hint case (24), canonical tree/report determinism (24),
lexical signature-boundary recovery (24) and named noreturn refusals (28).
Recovery may leave a structurally sound tree alongside errors, so the controls
check diagnostics and retained declaration boundaries separately. The source
spans are half-open; adjacent `!=` gains guidance, spaced `! =` does not.
No lexer rule, diagnostic code, fixture inventory or language acceptance rule
changes. Full `python3 check.py` passes. Logs are in
`.scratch/r491-inequality-hint/` and the matching final-values files; no
assembler, linker, generated executable or broad parser campaign ran.

K12/D223 delays consumption until call entry, as explicitly selected by the
user. Arguments keep left-to-right evaluation and capture; later reads are
accepted, and an argument exit leaves pending places live. Entered nested calls
retain their effects. Commit checks preserve repeated/overlapping sink refusal
and require every `inout` place to remain live after the sink commits. Recovery
and cleanup after an entered call see the consumed state. The descriptor and
handle derivatives update prototypes 3 and 4 with the specification and tour.

The newly accepted descriptor call exposed an existing IR carrier gap: saving
an ordinary aggregate's address before a later argument discarded the storage
shape, so the verifier rejected the reload at call entry. All saved aggregate,
array and descriptor arguments now retain a shaped address slot. The snapshot
still occurs at argument evaluation; the change preserves its proof across
later evaluation without changing the callee ABI. A bounded lowering control
checks a separate saved snapshot before a mutating argument and no outer call
on an early-return path. No verifier condition was weakened.

K12 development validation passes 221 selected assertions on each host
(macOS debug and pinned Linux release), including 29 small call-entry checker
sources, the snapshot/early-exit IR case, existing place and cleanup controls,
and the two new fixtures. The positive fixture emits assembly text only;
the negative fixture runs compile-only. Three older nested-flow slice sources
now retain D220's exact refusals, including the existing consumed-read follow-on,
with fixed-array companions preserving their original flow distinctions.
Both single-worker builds and full `python3 check.py` pass. Evidence is in
`.scratch/r491-sink-entry/` and matching final-values logs. No assembler,
linker, generated program, debugger or broad campaign ran. Exact-revision
acceptance remains open.

For m12, the normative integer productions now match the scanner's existing
start/end-digit boundary. Internal repeated underscores remain legal. The
previously undefined `unicode_scalar` now has an explicit scalar primitive,
including delimiter exclusions and shortest-form UTF-8 interpretation. The
grammar checker requires every used name to be defined, including lexical
names it treats atomically when recognizing tokens. Twenty small invariant
examples pin integer and scalar boundaries. Six disposable grammar defects
(undefined scalar/digit/raw rules, trailing decimal/hex separators and a
permissive scalar) are caught; six character derivations check the new primitive
and existing escapes. Compiler tokenization is unchanged, including the separate
float-component separator question. The existing m22 scanner evidence remains
applicable; no compiler suite, assembler or runtime work was replayed.

For m9, D224 records the already explicit R1.70 folding decision in [1940]
and the decision register. The extended fitting-fold fixture and a new bounded
IR case preserve exact static images on 32-bit and 64-bit target descriptions,
including signed and pointer-width arithmetic. The same u8 body expression
retains its two checked runtime operations. Final destination overflow and
both signs of fold-range overflow remain L0300. The controls pass 29 assertions
per host in macOS debug and pinned Linux release; both single-worker builds
pass. Evidence is in `.scratch/r491-module-fold-width/` and matching final-values
logs. The fixture emits only assembly text; no generated program is executed
and no arithmetic implementation changes.

The remaining m12 float-component question is resolved by source authority:
D162 and D166 already require complete digit runs on both sides of the dot and
in the exponent. Four bounded compile-only witnesses (`1_.5`, `0x1_.8p0`,
`0x.8p0`, `0x_1.8p0`) were incorrectly accepted because `Finish_Float` checked
only fraction and exponent runs. It now also checks the whole run; malformed
spelling retains one full-span L0321 and the following token. The two float
component productions and independent grammar controls match the same rule.
This enforces existing decisions and preserves repeated internal underscores.

For m22's final raw facet, D164's maximal opening run already fixes the result:
six adjacent quotes open a six-quote raw literal and supply no closer. Raw
content is therefore nonempty, and even the newline between delimiters remains
content. The grammar's former nullable content is tightened and the tour states
the consequence; lexer behavior is unchanged. Small controls distinguish this
from ordinary empty quoted text and from later matching or shorter quote runs.

The final m12/m22 batch passes 120 selected checks on each host: 84 float-run
assertions, 19 existing literal controls, five compile-only fixture assertions,
and twelve raw opener/decoder controls. Single-worker macOS debug and pinned
Linux release builds pass. Evidence is in `.scratch/r491-float-digit-runs/`
and matching final-values logs. Eleven independent float grammar examples and
the empty-raw-content check supplement the previous scalar/integer invariants.
No assembler, linker, generated program or broad parser campaign ran.

For m2--m5, the shared production helper requires a fresh output for each
attempt. Ten fake producer scenarios exercise stale, repeated, missing,
directory, removal-refused, unsuccessful, timed-out and unavailable production.
The fake filesystem now exposes replacement writes consistently and both fake
host implementations release their indirect storage through controlled owners.
Two one-shot tool failures retain the driver's missing-tool/capture distinction.
The fixture guide separates stage emission, ordered codes, exact reports and
the independent Python scanner's lex metadata.

The final bounded selection passes 94 assertions on each of macOS debug and
pinned Linux release. Both single-worker builds pass. The no-unwind fixtures
now register exit(99); a fake ordinary exit is refused by the trap oracle.
Both revised fixtures emit small assembly text on both hosts. They were not
assembled or executed, so revised runtime/profile evidence remains outstanding.
Evidence is in `.scratch/r491-fresh-artifacts/`,
`.scratch/r491-trap-oracles/` and the matching final-values logs. No assembler,
linker, generated program, debugger or mutation campaign ran for this group;
exact-revision acceptance remains open.

For m27, the new six-assertion IR case and existing aggregate-return control
pass twelve assertions per host in macOS debug and pinned Linux release. The
call carries a selected result address and an inout address into the same
frame object; its callee keeps distinct named result storage and performs the
three inout writes before filling that result. The small runtime fixture pins
p = (4, 5) and q = 3 after the overlapping assignment. Both hosts emit its
none/off assembly text; no execution verdict is claimed. Evidence is in
`.scratch/r491-result-overlap/` and matching final-values logs.
Two additional tiny text witnesses in `.scratch/r491-index-cost/` confirm m28's
single index evaluation, redundant inc check and differing frame sizes.

For m6, the arithmetic-only generator control passes four assertions on each
host. The fixed-seed byte sequence differs after 256 draws, does not force
alternating parity, covers over half the byte domain in its first 256 draws,
and repeats when reseeded. Both single-worker builds pass. This does not run
or approve the changed parser mutation stream: that campaign remains excluded.
Evidence is in `.scratch/r491-mutation-generator/` and matching final-values
logs. No assembler, linker, generated program or debugger ran for this group.

The m26 emission/dump repair passes seven exact cases and 159 assertions on
each of macOS debug and Linux release, after single-worker bootstrap builds.
Three tiny UTF8/UTF16/cstring traversal sources check sequencing and verified IR
on both target widths. The dump control distinguishes metadata-only changes,
retains nested pointer and array edges, and preserves legacy scalar array
spelling. Existing bounded slice, callback and aggregate-overlap controls also
pass. Evidence is in `.scratch/r491-emission-order/` and the matching
final-values logs. No golden corpus was regenerated and no Landin assembly,
linker, runtime, debugger or mutation campaign ran. Exact-revision acceptance
remains outstanding.

The final minor-finding source audit disposes m30 against the documented GNU
finishing-driver contract, m32 against the retained tiny factory comparison and
current address-exposure exclusions, and N12 against an accepted adjacent-name
assignment. The last probe emits assembly text only; it does not assemble or
execute. A8/M18's guide repair passes four focused Python cases (repeated
basenames, relative paths, repository fallbacks, query/fragment preservation,
external links and word-loss detection) and a full nonpublishing render with
content/structure verification. Current font/highlighter wiring is inspected;
this does not validate editor parser execution or resolve private-font history.
Evidence is retained in `.scratch/r491-minor-dispositions/`.

A8/M18's cross-job upload race is confirmed by the source sequence, not by
performing stale uploads. The user chose to retain SourceHut publication.
The shared publisher now acquires a unique canonical Git lock tag with an
atomic create-only lease, then rechecks the exact candidate before rendering
and before uploading. It holds the lock across both domain uploads and renders
into an isolated temporary directory. Release requires the same owner object;
failed or timed-out uploads retain the lock because server completion may be
uncertain. Busy waits and external processes are bounded; locks never expire
or get stolen automatically. The ordinary and manual entry points share this
path. A mechanical invariant rejects bypassing the publisher wrapper.

Activation remains separate: confirm canonical lock-ref write permission for
the SourceHut job's existing SSH identity, finish/cancel older jobs that do not
participate in the lock, and update manual publishers before the first guarded
live upload. Documentation records inspection and exact-lease recovery after
an interrupted/uncertain upload. No live publisher, lock tag, approval tag or
canonical promotion was invoked during implementation.

Publication development evidence: eleven focused Python cases pass against
disposable local Git remotes and mocked publishers. They cover mutual exclusion,
a racing create, lost acquisition acknowledgement, stale-owner release,
revision changes before/after rendering, both-domain ordering, uncertain upload
retention, render failure and archive modes/isolation. The isolated --to render
passes full document content/structure verification. The source/manifest wiring
checks require entry through the shared publisher; their own file readers now
close handles instead of issuing ResourceWarnings. These are local protocol and
rendering controls, not SourceHut credential or live-upload evidence. Logs are
in `.scratch/r491-publication-lock/`.

At the user's request, integration also includes canonical main through
`3a3caca4`, its derived IR guide, and the six pending main-worktree files captured
for the next push. These include the README's consistent backtick reference,
the task-directed context-pack helper and its eight focused tests, compiler
guidance, and matching registration in the existing documents acceptance job.
The site keeps source-relative links and the IR guide's non-authoritative role;
the guide now explains the compact/detailed dump distinction. No Ada compiler
source changes during this integration. Its context-pack, publication and link
checks are bounded Python tests; they do not execute a compiler corpus, a model
request, a live publisher or exact-revision native acceptance.

Planning estimate at `4e6fcad9`: 137 commits since the review baseline and
64 new fixture records are committed. The assessed J/K intake contains 175
findings, alongside the older and N-series reviews. Most compiler repairs are
implemented, but grouped minor observations still need individual disposition.
The working estimate is 85–90% of repair work and 70–80% of complete delivery,
with roughly 10–15 remaining work packages (30–60 focused hours). These are
planning ranges, not acceptance evidence or measured historical work hours;
missing original run bundles and new validation failures can extend closure.

D222's approved J2 contract and bounded controls are implemented.
D223 implements K12's user-selected call-entry sink timing. J15's named
refusals now distinguish deferred source shapes from ordinary identifiers and
implemented atom lists. D225 implements J104's user-selected reservation of
control words in every identifier position.
N12 retains the existing adjacent-token contract. K28/M12 remain scoped maintenance
observations. M6 is closed by maintainer disposition with the original
historical native runs explicitly unverifiable; their bundles remain unrecovered.
M5 is disposed by the maintainer's decision to leave the font files for now; no history rewrite is authorized. The intake
rows retain each other disposition and any outstanding evidence. Complete
fixture accounting, diagnostic/document agreement and focused IR review
before seeking exact acceptance. Passing filtered checks cannot close an
untested group, and excluded giant images remain source/seam work only.
The review intake is reconciled; implementation and acceptance remain active.

#### Additional review consolidated at 1aa0746a

Paseo agent `ea7e191d-6563-4a86-9dd7-8bb195813ec6` consolidated a review of
`1aa0746a4e2d464f79142025fc10161c072aa4b4`, using the snapshot
`/tmp/landin-review-1aa0746a.16TElI`. This predates the final-value and nested-flow
repairs. Its 37 reported identifiers are reconciled into 36 rows below;
D1a/D1b share one call-classification mechanism. K identifiers name this intake
only, so the review's A/B/C identifiers cannot be confused with earlier ones.
The original consolidation, available finder reports, source anchors and ten
small current debug checks are retained in `.scratch/r491-review-ea7e191d/`.
Current comparisons are against `ab2cc3fa`.

The review mixes coordinator-reproduced cases, finder-only observations and
explicitly unresolved contracts. Those distinctions survive intake: an old
exit status is not current validation, and malformed-IR observations are not
automatically source-reachable defects. Its C/G partitions were partial and
the planned independent verification workflow did not complete. Historical
debugger evidence for C1 is retained as provenance only; no debugger was run
for this intake. No compiler build, Landin emission, assembly, linking,
runtime execution or scaling campaign was performed here. The ten new source
checks used the existing debug binary, sequentially, with 10-second timeouts.

| Intake | Review identifier and observation | Current disposition and repair scope |
| --- | --- | --- |
| K1 | A1: runtime call in a reference-valued module struct field reaches lowering | Repaired: ordinary and variant reference fields require a compile-time-known value when forming a module image. Runtime calls, including nested fields and fills, report L0305 before lowering; an already ill-typed field keeps its original diagnostic. Local calls and permitted static references still pass checking. J30 separately owns accepted slice-image lowering, including the additional valid variant literal found here. |
| K2 | A2: statements followed by a function's final value are refused | Already repaired by 7250d298 under A2/C2/M3. Reuse the final-value grammar, checking and runtime evidence; no replay needed. |
| K3 | A3: labelled construction treats `any(...)` as a type | Repaired: argument lookahead distinguishes the expression `any(...)` from the type `any C`, as it already does for pointer syntax. Parser projections remain separate; contextual and nominal erased-value constructions pass checking. Existing neutral type-argument and type-only refusal controls remain required. |
| K4 | A4: repeated or non-trailing `of` fills are accepted | Repaired: a labelled application reports L0103 once when another argument follows its fill, while retaining the argument tree and later source. Controls cover repeated fills, later labels/positionals, nested valid and invalid fills, a field named `of`, and recovery. Fake-host driver refusals require no output/tool effects; D214's valid evaluation order is unchanged. |
| K5 | A5: static-address search descends into unevaluated literal `lenof` | Repaired: the address walk skips D31's unevaluated literal measurement, and field/array/repetition static exclusions stop at measurements too. Small scalar, struct, variant, literal-array and repetition controls accept these measurements; actual address images remain L0305. Slice descriptor reads remain covered by the existing nested-flow controls. |
| K6 | A6: distinct extraction inside a variant payload tests the outer node | Repaired with J55: the payload's `Given`, rather than the enclosing case construction, owns the distinct-conversion exemption. A matching static distinct payload passes; a different nominal identity remains L0301, and the ordinary-field control is retained. |
| K7 | B1: indexed-field and pointer assignment destinations miss reads before the RHS | Repaired by 0f708770 under J1/J3/J74. Both imported current debug witnesses now produce exactly one L0302, including the formerly crashing unassigned pointer destination. |
| K8 | B2: propagated `try` failure omits reference-origin cleanup checks | Repaired: the reference pass runs failure-applicable cleanups after the call's arguments, then restores success-path origins. Fourteen controls cover direct/propagated failure, defer/undo, nested and labelled calls, escaping/static values, recovery, early transfers and independent success facts. A driver refusal requires one L0314 and no output/tool effects. Both modes pass; J19's definite-assignment repair remains independently covered. |
| K9 | B3: discard/operator wrappers hide nested sink effects | Already repaired by 0f708770 under J3. Preserve the selected nested-call controls and their debug/release evidence; no second dispatch repair or broad rerun is needed. |
| K10 | B4: missing-value checking omits pointer, slice and erased carriers | Already repaired by 7250d298: current `Needs_Value` includes all three carriers. Retain the existing final-value refusal controls and both-mode evidence. |
| K11 | B5: a fresh loop binding inherits a consumed fact from the previous iteration | Repaired: each executed declaration clears its prior instance's assigned and consumed facts, including sparse fields/elements. Ordinary, condition and traversal bindings start fresh; destructured results retain their existing sink restriction. Twenty-one controls preserve outer loop-carried consumption, initializer effects, uninitialized reads and repeated reads after a sink. This applies [0080]/[1910] without changing the sink point or adding ownership. |
| K12 | B6: sink consumption occurs before later arguments finish evaluating | D223 adopts the user-selected call-entry timing: callee and arguments evaluate first, then pending sink places are consumed. Early argument exits preserve the outer call’s pending places; entered nested calls retain their effects. Repeated/overlapping sinks and consumed inout places remain refused at entry. The checker, captured aggregate carrier, cleanup and prototype derivatives are implemented; bounded validation is recorded below. Exact acceptance remains open. |
| K13 | C1: multi-formal concept conformance loses its normalized key | Integrated under repaired J49. The finder transcript says its conformances omitted associated input labels, contrary to D142. The current valid multi-input fixture passes; omitting its required input reproduces J49. The broad claim that every multi-formal conformance crashes is not supported. Valid keys, reordered labels and malformed-entry refusals have separate controls; no debugger was run. |
| K14 | C2: an all-return slice lower bound emits into terminated flow | Repaired with J22: lower/upper returns, array/slice/text sources and ordinary/partially returning bound controls pass in both modes. |
| K15 | D1a/D1b: scalar/text spelling overrides a resolved callable | Repaired under J8: resolved user functions and callback bindings keep their call semantics, including scalar and text names. The source-to-IR controls retain direct/indirect calls and the small before/after assembly text restores the missing call to u8. |
| K16 | D2: `Covers` accepts a different syntax forest with matching source ID and node count | API contract repaired: both semantic tables retain immutable tree object identities and compare them in Covers, in addition to source membership and node count. Same-sized different text, independently parsed identical text and absent-source controls accompany acceptance of the owned tree. Three exact cases pass 29 checks on each of macOS debug and Linux release; no CLI failure is claimed and exact acceptance remains open. |
| K17 | E1: array fill/element atom writes require exact sets | Implemented: Fill_Array and Store_Element allow source atom subsets under D216; reads and whole copies retain exact descriptors. A two-element source fill reproduced exit 70 and now exits 0. Named/parameter direct-store source controls already passed; their Store_Element contract is independently pinned with small IR cases. Exact acceptance remains open. |
| K18 | E2: ordinary internal aggregate/array calls check only address carrier width | Verifier shape checks now cover ordinary direct and indirect calls as well as erased dispatch. Hidden result and shaped argument addresses must retain their declared extent, element and nominal identity; C and erased-self checks remain. Bounded malformed-IR and valid nested/indexed controls cover both target widths. Four exact selectors pass 107 checks on each host; no accepted-source overwrite is claimed and exact acceptance remains open. |
| K19 | E3: pointer metadata can be erased or mixed in stores, calls and operations | Contract distinction: plain usize storage/parameters and integer comparisons deliberately transport address bits without a source-pointer promise. They do not restore pointee evidence; typed stores/calls and Pointer_Address still demand it. Documented this existing IR boundary and added small accepted raw-word/refused forged-restoration cases, with the source pointer-comparison refusal as a separate control. Three exact cases pass 81 checks on each host. Disposed as an IR/source-contract conflation, not an established accepted-source defect; no blanket raw-carrier ban or language change. Exact acceptance remains open. |
| K20 | E4: scalar `Store` accepts a shaped slot or violates an accessor contract | Implemented with J95: scalar stores refuse struct and array slots before Type_Of, with tiny valid scalar/field/element controls passing in debug and release. This is a malformed-IR backstop, not a source miscompilation claim; exact acceptance remains open. |
| K21 | E5: instruction `In_Block` disagrees with its enclosing block run | Implemented with J91: every instruction, including a no-operand Leave, must agree with its block run before consumers use it. Small direct seam tests cover both target widths. |
| K22 | E6: final run cursors allow trailing orphan entries | Implemented with J91: the final slot, parameter, block, value, field and operand cursors must consume their complete vectors. Three-instruction controls append one unclaimed entry at a time; exact acceptance remains open. |
| K23 | F1: repeated module references cause exponential folding | Implemented a per-query map of completed module-binding values in the shared checker/lowering folder. Recursive references reuse known, non-overflowing results; unknown/overflowed folds retain cycle/diagnostic behavior, and a later query gets a fresh map for current semantic facts. Four exact cases pass 89 checks on each of macOS debug and Linux release, and four bounded compile-only probes retain their complete diagnostic transcripts on both hosts. The historical long timing chain was not replayed; exact acceptance remains open. |
| K24 | F2: shared aggregate shapes are remeasured recursively without a cache | Implemented a memo shared by recursive calls within one public measurement query, keyed by complete shape. Unit, target and maximum are fixed for that query; no result survives return or failure. Small shared graphs cover layout policy, target width, size limits, unit identity, arrays and variants. Four exact cases pass 111 checks on each host, including one small cycle guard. Scalar queries avoid memo allocation. No long timing runs or giant images; exact acceptance remains open. |
| K25 | F3: devirtualization leaves a typed function-address projection live | Repaired: backward demand may remove a verified pure Function_Address despite its signature metadata. Live users still retain the instruction and its signature; numeric folding remains restricted to plain values. Small dead/live/no-optimization controls cover both target widths. Three exact cases pass 39 checks on each of macOS debug and Linux release; exact acceptance open. |
| K26 | F4: address-exposure analysis rescans the unit per routine even with specialization off | Implemented a shared retained-reference traversal for specialization and final-body sharing. Consumers mark their existing pass-local arrays once; explicit/imported roots, scalar and aggregate images, evidence entries and runtime function addresses share one policy with the single-routine query. Seven exact callback-count and decision/identity cases pass 134 checks on each host; no timing sweep or persistent cache. Exact acceptance remains open. |
| K27 | F5: profitability recounts eligible instances for every instance | Implemented a pass-local ordered count per normalized template before profitability selection. This removes the nested recount while preserving the same proven/non-exposed/static-entry predicate and decision order. A three-instance, two-template test covers exposed-root exclusion and independent single-instance selection on both target widths. Three exact cases pass 70 checks on each host; no timing or stress campaign. Exact acceptance remains open. |
| K28 | F6: preflight, emission and full-debug output repeat allocation/frame planning | Maintenance/scaling observation, not wrong code. Evaluate reuse only with explicit unit/options/target ownership and debug-location agreement; retain J65's independent exception-classification question. No large-routine benchmark is needed. |
| K29 | G1: wide slice stride uses an unencodable immediate multiply | Implemented with A7/M19/N6/J61. Bounded scalar and emitted-text evidence covers the shared encoding decision; no giant extent or image reproduction. |
| K30 | G3: first-class external C function address uses a bare PC-relative address | Confirmed with one inspected 1,275-byte assembly file and a foreground 20-second-capped invocation of the pinned triplet-selected GNU driver: PIE linking refuses the PC32 puts relocation. Imported runtime function addresses now load through GOTPCREL; defined routines retain relative addresses and quoting is preserved. Two exact backend cases pass eight checks on each host. The inspected replacement links as a PIE and readelf confirms the puts GLOB_DAT relocation; no generated program was executed and exact acceptance remains open. |
| K31 | G4: outgoing stack sizes lack a wide-immediate fallback | The focused source audit found an internal-call gap; C incoming/outgoing areas were already bounded. Internal entry and direct/indirect call areas now share checked count/alignment arithmetic with emission, preserving the signed displacement budget and the incoming frame/call prefix. Four exact cases pass 52 checks on each host, using scalar counts at encoding boundaries and an eight-argument direct/indirect control. No huge argument list or image is constructed; exact acceptance remains open. |
| K32 | G10: stack-argument start uses max(8, its alignment) | Disposed as no established defect in the supported subset. Under [1975], scalar leaves have at most eight-byte alignment; nested C records take their widest field alignment and fixed arrays inherit their element alignment. Thus max(8, alignment) is eight for every admitted stack argument. Vectors, extended scalars and over-aligned records are excluded. The existing C classification case passes 19 checks on each host; retained native-bank fixture sources cover multiple spills and partial records, without rerunning native execution. Exact acceptance remains open. |
| K33 | H1: build-report collision checks reserve inactive product/map paths | Confirmed for an inactive map: report preflight now shares the actual artifact list. Product_Path already equals the assembly destination for non-executable emission, so no independent inactive-product defect was established. Fake-host controls cover both emission modes, map production by full debug or caller coordinates, aliases and real source/artifact collisions. Four exact cases pass 194 checks on each host; no real overwrite or tool run is used. Exact acceptance remains open. |
| K34 | H2: help/identify bypass invalid deferred options | Confirmed by four bounded direct CLI probes. Informational responses now wait for all command-line validation, including target, build mode, override shape/duplicates and root/emit arity. Valid help/identity requests still return before source discovery or reads; unknown targets retain status 1 and option misuse status 2. Fake-host controls cover both action positions and valid counterparts. Five exact cases pass 301 checks on each host; J45's invalid-configuration stage boundary remains and exact acceptance stays open. |
| K35 | H3: build manifest omits the selected C compiler identity | Implemented a native GPR configuration snapshot shared by both project builds. The manifest records its content hash and the selected C driver's absolute path, binary hash and complete version response; both ordinary and checksum modes clean on identity changes. Configuration failures preserve the previous build, and wrapper configuration overrides cannot bypass the snapshot. Thirteen disposable build-inventory tests pass on each host, as do both single-worker bootstrap builds, 13 native-adapter checks and an unchanged developer fast-path check. No machine compiler installation is changed; exact acceptance remains open. |
| K36 | H4: timeout kills only the direct tool PID | Repaired: POSIX spawn establishes a private process group before exec; a monotonic timeout kills that group and reaps the direct child. Adapter exceptions also stop an owned child. Five focused native cases pass in both modes, including a short-lived descendant's delayed write, literal argument bytes, capture modes, exit/signal distinctions and missing executables. This supervises ordinary group members, not descendants deliberately leaving the group; all assembly limits still apply. |

The K8/K36 batch passes 15 selected cases and 359 checks in each of macOS debug
and Linux release: five native process cases and ten checker/driver/fixture
cases. Three small positive fixtures verify assembly-text emission only;
no assembler, linker or generated Landin executable was invoked. The native
timeout witness forks one harmless child, whose delayed marker must remain
absent; both processes expire within two seconds even with a broken runner.
The failure-cleanup origin snapshot uses heap storage and is released on both
ordinary and exceptional paths. Existing origin forwarding, untaken cleanup,
payload, nested-flow and destination-join controls remain green.

Builds used one worker. The first clean Linux build hit its 300-second wrapper
limit before tests ran and was stopped; the retry completed under an explicit
900-second build limit. Selected test invocations were limited to at most
20 seconds. Logs are retained in `.scratch/r491-tool-timeouts/` and
`.scratch/r491-try-origins/`. These are development results, not exact-revision
acceptance; the resource restrictions below remain mandatory.

K11 development evidence: eight selected cases pass 160 checks in each of
macOS debug and Linux release. The new checker case has 21 small sources;
related cases cover nested call effects, descendant initialization, fallthrough
joins, defer/undo and consumed-place exit obligations. Both builds use one
worker; each selected test has a timeout of at most 30 seconds. Logs are in
`.scratch/r491-fresh-bindings/` and `.scratch/r491-final-values/`. These checks
run no assembler, linker or generated Landin executable and do not replace
exact-revision acceptance. No language sequencing rule changed.

K3/K4 development evidence: nine selected cases pass 355 checks in each of
macOS debug and Linux release. Fourteen small parser sources exercise the fill
boundary and recovery; neutral projections, full erased-value constructions,
ordinary nominal construction and prior type-only refusals remain covered.
Two fake-host driver sources reject invalid fills without output or tool effects.
The debug build first reported overlong test lines; after formatting corrections,
the required clean rebuild passed under its 300-second limit. Both builds use
one worker, and selected tests have timeouts of at most 30 seconds. Logs are in
`.scratch/r491-construction-boundaries/` and `.scratch/r491-final-values/`.
No assembler, linker or generated Landin executable ran. These are filtered
development checks, not exact-revision acceptance.

K1/K5/K6 development evidence: ten selected cases pass 377 checks in each of
macOS debug and Linux release. Twenty-three small checker sources cover static
reference calls, fields/fills and payloads, runtime counterparts, literal
measurements and distinct nominal identity. Four pre-existing negative fixtures
retain storage-read/static-call refusals; nested-flow controls retain slice
reads. Driver checks require one L0305 and no output/tool effects for both
ordinary and variant runtime reference initializers. The debug build reported
one overlong test line before a corrected clean rebuild; both final builds use
one worker and selected tests have timeouts of at most 30 seconds. Evidence is
in `.scratch/r491-static-fields/` and `.scratch/r491-final-values/`. No assembler,
linker or generated Landin executable ran. J30's valid variant slice remains an
explicit lowering gap, not a successful end-to-end positive control in this
checker batch. Exact-revision acceptance remains outstanding.

J30 development evidence: seven selected cases pass 94 checks in each of
macOS debug and Linux release. The source-to-IR case checks complete slice
images on 32-bit and 64-bit target facts; nine small verifier scenarios retain
range, target, offset, shape and representation checks. Existing recursive
image, relocation and backend text/placement controls pass. One 16-declaration
source also emits a small inspected assembly text with the expected shared
literal address, subslice offsets and variant placement. No assembler, linker
or generated Landin executable ran. The existing recursive-static-selection
case contains a billion-element array and was deliberately not rerun. Builds
use one worker, selected tests have timeouts of at most 30 seconds, and the
single text emission has a 15-second limit. Logs and text are retained in
`.scratch/r491-slice-images/` and `.scratch/r491-final-values/`. This reuses the
existing descriptor representation and is filtered development evidence;
exact-revision acceptance remains outstanding.

J7/J10 development evidence: five selected cases pass 344 checks in each of
macOS debug and Linux release. Thirty small checker sources cover invalid and valid initializers and
range-slice targets; the driver case now checks 248 refusal/output invariants.
Existing parameterized alias, nominal interning and construction controls pass.
Single-worker builds and selected checks with timeouts of at most 30 seconds
pass. No assembler, linker or generated Landin executable ran in this batch. Logs are retained in
`.scratch/r491-refusal-boundaries/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains outstanding.

J12 development evidence: seven selected cases pass 342 checks in each of
macOS debug and Linux release.
Twenty small checker sources cover constrained type actuals and their aliases,
nested pointer/slice/array actuals, unused formals and accepted counterparts.
The driver case checks 264 refusal/output invariants, and the existing generic,
slice and struct range-subtype refusal fixtures retain their reports. An early
slice-alias control encountered the existing R2.40 alias-result refusal; the
passing slice control uses an enabled struct instance and does not widen that
boundary. Single-worker builds and selected checks with timeouts of at most
30 seconds pass. No assembler, linker or generated Landin executable ran in
this batch. Logs are retained in
`.scratch/r491-range-actuals/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains outstanding.

J49/J50/J51/J52/K13 development evidence: eight selected cases pass 358
checks in each of macOS debug and Linux release. Sixteen small checker sources
retain ordered reports,
valid concrete and generic providers, associated inputs, nominal traversal and
finite formal-requirement graphs. The driver case checks 296 refusal/output
invariants. Existing cycle, collision, alias-key and generic-provider-signature
fixtures retain their exact reports. Builds use one worker; each selected test
has a timeout of at most 30 seconds.
The K13 finder transcript and bounded current witnesses are retained beside the
logs in `.scratch/r491-conformance-boundaries/`; local logs also live under
`.scratch/r491-final-values/`. No debugger, assembler, linker or generated
Landin executable ran in this batch. Exact-revision acceptance remains open.

J8/K15 development evidence: six selected cases pass 400 checks in each of
macOS debug and Linux release. Seventeen source-to-IR cases verify direct and indirect call kinds,
concrete targets, generic calls, scalar conversion types and the verifier;
scalar and text conversion controls preserve their range, identity and origin
refusals. The driver case checks 312 refusal/output invariants. A test initially
used the slot-type accessor for an IR value; correcting it required a clean
single-worker rebuild, which passed. A tiny ten-second assembly-text emission
before/after the repair changes the silent scalar witness from no user call to
`call u8`. No assembler, linker or generated Landin executable ran. Builds
use one worker and selected checks have timeouts of at most 30 seconds. Logs and the inspected small texts are retained
in `.scratch/r491-call-classification/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J59 development evidence: eight selected cases pass 541 checks in each of
macOS debug and Linux release.
Twenty-four tiny checker sources cover missing/excess scalar and text operands,
aliases, range subtypes, and ordinary user functions with zero/two arguments.
A refused value now carries an invalid origin fact through joins, separately
from raw-address origins, so text refusals do not manufacture L0316. The
existing joined-origin, try-cleanup and genuine wrong-from controls pass.
The driver case checks 344 refusal/output invariants; the preceding 68 IR
call/conversion checks also pass after the classification refactor. Builds
use one worker and selected checks have
timeouts of at most 30 seconds. No assembler, linker or generated Landin
executable ran in this batch. Logs are retained in
`.scratch/r491-conversion-arity/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J9 development evidence: five selected cases pass 413 checks in each of
macOS debug and Linux release.
Seven source-to-IR cases run against both 32-bit and 64-bit target facts,
checking retained signatures, equality/inequality, control values and operand
order. The new inequality controls initially used a foreign spelling; they now
use the normative `<>`. The driver case checks 352 refusal/output invariants,
including incompatible function comparisons. Existing function-assignment,
pointer-comparison and scalar backend controls pass. Builds use one worker
and selected tests have timeouts of at most
30 seconds. No assembler, linker or generated Landin executable ran in this
batch. Logs are retained in `.scratch/r491-function-comparisons/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J22/K14 development evidence: five selected cases pass 178 checks in each of
macOS debug and Linux release. Twenty-five tiny sources run against 32-bit and
64-bit target facts. They check that evaluation stops before later calls,
retains earlier calls, preserves a continuing branch, and leaves every IR block
reachable and finished. The first conversion and UTF8 ordinal test drafts were
untyped and correctly refused; typed all-return controls now exercise those
paths. Existing control-value, all-return, callback/inout and UTF8 storage
regressions pass. Builds use one worker and selected tests have timeouts of at
most 30 seconds. No assembler, linker or generated Landin executable ran.
Logs are retained in `.scratch/r491-terminated-expressions/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J23/J26 development evidence: four selected cases pass 283 checks in each of
macOS debug and Linux release. Twenty tiny sources run against both target
widths, checking later-condition termination, reachable earlier arms, while/
range/array completion, return/continue/fail, nested labelled breaks, loop
values, unreachable transfers and break cleanup. The preceding terminated-
expression regression and existing cleanup/loop-depth controls pass. Builds
use one worker and selected tests have timeouts of at most 30 seconds.
No assembler, linker or generated Landin executable ran. Logs are retained in
`.scratch/r491-control-continuations/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

The additional current-source traversal inference defect found during J26 is
repaired. `for n in 0 ..< 2 do v := n complete return end for` previously
reached lowering with an unstorable inferred local and exited 70. Inference
now asks the owning traversal header for its checked element/index type,
retaining the existing wait for provisional error-set sources. This preserves
inferred scalar, array, struct, pointer and text identities, nested range
inputs and generic arguments without adding a new language rule.

Traversal-inference development evidence: five selected cases pass 634 checks
in each of macOS debug and Linux release. Twelve tiny sources run against both
target widths. Invalid scalar collection sources and noninteger range bounds
retain L0301 with no output or tool invocation; the driver case now checks 368
refusal/output invariants. Existing fresh-binding, conformance and control-
continuation cases pass. Builds use one worker and selected tests have timeouts
of at most 30 seconds. No assembler, linker or generated Landin executable ran.
Logs are retained in `.scratch/r491-traversal-inference/`,
`.scratch/r491-control-continuations/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J24/J25/J27 development evidence: five selected cases pass 254 checks in each
of macOS debug and Linux release. Eighteen tiny sources run against both target
widths, checking positional/labelled/try result destructuring, result assignment
from each loop form, indexed/pointer/inout aggregate assignment, exact call
order and all-return temporary handling. Existing construction storage,
control-value, continuation and failure-cleanup cases pass. Builds use one
worker and selected tests have timeouts of at most 30 seconds. No assembler,
linker or generated Landin executable ran. Logs are retained in
`.scratch/r491-stored-control-values/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J28 development evidence: three selected cases pass 88 checks in each of
macOS debug and Linux release. Eight tiny sources check anonymous pointer
result carriers, exact referent and return-source metadata, local callback
storage and named/scalar controls on both target widths. Existing capture and
incompatible-function-signature refusals pass. Builds use one worker and
selected tests have timeouts of at most 30 seconds. No assembler, linker or
generated Landin executable ran. Logs are retained in
`.scratch/r491-anonymous-results/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J29/J31/J32 development evidence: five selected cases pass 554 checks in each
of macOS debug and Linux release. Fifteen tiny accepted sources check reference
initializers, local assignment before use, zero/finite/forward/chained array
copies and the existing empty module-array exception on both target widths.
Eight new driver inputs cover omitted pointer, cstring, slice, text and alias
initializers; its 432 checks retain no-output/no-tool refusal guarantees.
Existing static slice descriptors, missing callback images and static-image
cycle refusals pass. The reference refusal applies [0540], D141 and the same
Descriptor_Has_Zero_Image rule already used for fields; it introduces no new
language rule. Builds use one worker and selected tests have timeouts of at
most 30 seconds. No assembler, linker or generated Landin executable ran.
Logs are retained in `.scratch/r491-module-images/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J57/J58 development evidence: five selected cases pass 753 checks in each of
macOS debug and Linux release. Nineteen tiny accepted images run against both
target widths; sixteen out-of-range sources extend the driver to 560 refusal/
output checks. The first checks confirmed that payload constructors and `of`
fills also bypassed folding. They now use the same recursive field walk as
ordinary fields and array elements. Boolean boundaries, distinct upper bounds,
shared fills, array-valued fills and callback-valued fills retain valid images;
one bad shared fill reports once. Existing module-image, static slice and
literal-overflow controls pass. Builds use one worker and selected tests have
timeouts of at most 30 seconds. No assembler, linker or generated Landin
executable ran. Logs are retained in `.scratch/r491-image-folds/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J54 development evidence: four selected cases pass 133 checks in each of
macOS debug and Linux release. Twelve tiny sources exercise atom, atom-union,
function, pointer, cstring, slice, text, any and scalar measurements. Static
array images retain exact target size/alignment, while ordinary expressions
retain their IR carrier on both target widths; the synthetic target's absent
C ABI keeps its existing refusal. The initial array-extent test draft correctly
hit D136's target-independent-expression restriction and was replaced with
one-element image initializers. Existing aggregate measurements and unresolved
measured-type refusal pass. Builds use one worker and selected tests have
30-second or shorter timeouts. No assembler, linker or generated Landin
executable ran. Logs are retained in `.scratch/r491-measurements/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J46/J60/J124 development evidence: six selected cases pass 660 checks in each
of macOS debug and Linux release. Nine tiny accepted sources exercise forward,
aliased, self and mutual callback results, nested/reference/empty arrays and
none/scalar result controls on both target widths. Four bad-field sources
extend the driver to 592 checks, retaining one L0304 and no output/tool effects
through ordinary, written-signature, array and nested-array result uses. The
first checks exposed zero-image and assignment cascades after layout refusal;
those uses now retain the original diagnostic. Existing nominal identity,
generic array signatures, hidden result destinations and scalar placement
boundary checks pass. Size computation now shares the already checked
recursive shape walk; no giant source, array image or generated assembly was
used to reproduce overflow. Builds use one worker and selected tests have
30-second or shorter timeouts. No assembler, linker or generated Landin
executable ran. Logs are retained in `.scratch/r491-result-layouts/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J41 development evidence: four selected cases pass 789 checks in each of
macOS debug and Linux release. Six tiny accepted sources exercise local,
labelled and nested anonymous loops, a body-local complete binding, outer
completion and an anonymous return. They reach verified IR on both target
widths. Six invalid cross-function transfer inputs extend the driver to 640
checks with exactly one L0110 and no output or tool effects. Existing control
continuations and capture refusal pass. Builds use one worker and selected
tests have 30-second or shorter timeouts. No assembler, linker or generated
Landin executable ran. Logs are retained in `.scratch/r491-anonymous-loops/`
and `.scratch/r491-final-values/`. Exact-revision acceptance remains open.

Additional build-probe repair: the J46/J60/J124 Linux transcript emitted
`fatal error: disk full` during the `gnatls --version | head -n 1` banner probe,
then built and passed all selected checks. Both hosts had ample free space
and inodes; a complete GNATLS banner read exited successfully. Early closure
of the banner pipe is the working explanation, not a confirmed storage
failure. Both toolchain reporting and build-manifest version pipelines now
use sed to retain the first line while consuming the complete output, so the
producer is not interrupted by head's early exit. Shell syntax checks and
standalone macOS debug/Linux release banner probes pass with unchanged
reported toolchain versions. No compiler build or fixture run was needed for
this shell-only change. Probe logs are in `.scratch/r491-version-banners/`;
the untruncated original transcript remains with the result-layout batch.

J39 development evidence: four selected cases pass 748 checks in each of
macOS debug and Linux release. Nine paired valid/broken syntax cases preserve
node kinds, names, child structure and binding mutability after a missing list
closer. They cover later functions, positional/labelled calls, mutable bindings,
call/array/field separators and nested missing parentheses. Two driver sources
extend the no-output/no-tool refusal case to 656 checks. Existing recovery of
valid declaration/statement heads and match-arm refusal pass. No truncation,
mutation or fixture-wide sweep was run. Builds use one worker and selected
tests have 30-second or shorter timeouts. No assembler, linker or generated
Landin executable ran. Logs are retained in `.scratch/r491-list-recovery/`
and `.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J35 development evidence: four selected cases pass 770 checks in each of
macOS debug and Linux release. Eighteen paired explicit/bare-end sources keep
identical declaration syntax, including functions, bindings, types, atoms,
options, directives, linkage and conformances. Both target widths retain
three module items and the later function's direct call to the first. Two
mismatched-name sources extend driver refusals to 672 checks; existing list
recovery still preserves current anchors. The prior version-banner script
change correctly triggered clean builds on both hosts. Builds use one worker
and selected tests have 30-second or shorter timeouts. No assembler, linker
or generated Landin executable ran. Logs are retained in
`.scratch/r491-function-ends/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J34 development evidence: four selected cases pass 58 checks in each of
macOS debug and Linux release. Three tiny accepted modules reach verified IR
on both target widths and measure one ordinary field without a variant tag.
Parser controls preserve following declarations, forward type names and a
real variant part sharing the struct's name. Existing empty-part and
mismatched-closer fixtures retain L0101 and L0109/L0102 respectively. This
applies [1795] and D74's existing contextual-word rule. Builds use one worker
and selected tests have 30-second or shorter timeouts. No assembler, linker
or generated Landin executable ran. Logs are retained in
`.scratch/r491-variant-name/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J36 development evidence: four selected cases pass 942 checks in each of
macOS debug and Linux release. Seventeen tiny programs compile directly and
inside an if arm on both target widths, retaining one fallible call and
verified recovery continuations. They cover loop/while/for, bare/unchecked
blocks, nested else arms, anonymous functions, match, positional/labelled
arguments, struct fields, array elements/repetition/fills, indexes, slice
bounds and pointer conversion. Ten parser controls retain the exact number
of call recovery clauses and enclosing else bodies, including direct then/
elsif priority, parentheses and any construction. Existing list recovery and
672 driver refusal/output checks pass. This applies [1820]'s existing direct
arm-boundary rule. Builds use one worker and selected tests have 30-second or
shorter timeouts. No assembler, linker or generated Landin executable ran.
Logs are retained in `.scratch/r491-nested-recovery/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J5 development evidence: four selected cases pass 760 checks in each of
macOS debug and Linux release. Nine small parser cases retain the ordered
module declarations through bare, wrong and missing closers, compact syntax
and field-type refusal. An accepted module keeps both struct identities and
both functions, including the correct direct call, in verified IR on both
target widths. Four driver inputs extend refusal/output checks to 704. The
first run exposed an extra missing-end report after field-type recovery; that
path now retains its original diagnostic and following declaration. Existing
contextual variant controls pass. This applies [1795]'s existing optional
struct-end name. Builds use one worker and selected tests have 30-second or
shorter timeouts. No assembler, linker or generated Landin executable ran.
Logs are retained in `.scratch/r491-struct-closers/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J4 development evidence: two selected cases pass 156 checks in each of
macOS debug and Linux release. Six tiny sources cover slicing and indexing a
struct slice field, traversing it, indexing an array of slices, ordinary slice
copy and text slicing. Each retains exactly one call to the side-effecting
index routine and verified storage/bounds operations on both target widths.
The 120 existing continuation checks retain early returns from indexes,
bounds and slice sources, with no later operations lowered after termination.
The two descriptor loads share the captured stored place; simple module/frame
fields keep direct identity loads. Builds use one worker and selected tests
have 30-second or shorter timeouts. No assembler, linker or generated Landin
executable ran. Logs are retained in `.scratch/r491-slice-evaluation/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J47 development evidence: two selected cases pass 826 checks in each of
macOS debug and Linux release. Seven tiny accepted layouts preserve common,
compact, nested, payload and generic field positions on both target widths.
Ten duplicate-label sources extend driver refusal/output checks to 784,
covering both field/part orders, repeated parts, payload fields, templates,
parameter use and nested use. The first checks exposed a follow-on layout
report for a nested invalid type; duplicate-labelled ordinary types now
propagate refusal and retain the original L0309. Existing template diagnostic
wording and related-label ownership are preserved by the shared validator.
Builds use one worker and selected tests have 30-second or shorter timeouts.
No assembler, linker or generated Landin executable ran. Logs are retained in
`.scratch/r491-field-names/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J42/J43 development evidence: three selected cases pass 940 checks in each
of macOS debug and Linux release. Four tiny accepted sources retain one
verified indirect call through an indexed array, indexed slice, selected
field and positional control on both target widths. Eight driver sources
extend refusal/output checks to 848: indexed/sliced non-functions report
L0301, missing callees and runtime arguments report L0201, and the existing
builtin labelled-conversion refusal remains L0304. Typed construction
contexts, nested missing names and type-only arguments retain those stage
boundaries. All 68 existing builtin/alias/shadowed call checks pass. Builds
use one worker and selected tests have 30-second or shorter timeouts. No
assembler, linker or generated Landin executable ran. Logs are retained in
`.scratch/r491-labeled-callees/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J44 development evidence: three selected cases pass 925 checks in each of
macOS debug and Linux release. Six accepted sources exercise enclosing aliases,
both type-formal orders, written function-type labels, anonymous module scope
and a later fixed formal on both target widths. Six refused sources extend
driver refusal/output checks to 896, covering both runtime-parameter orders,
later return names and both anonymous orders; each retains one L0304. The
existing return-source position case passes its five checks. A generic-call
test draft lacking array-literal context was replaced with a declared
two-element array to isolate fixed-formal visibility. This applies [1840]'s
existing complete-signature collection rule. Builds use one worker and
selected tests have 30-second or shorter timeouts. No assembler, linker or
generated Landin executable ran. Logs are retained in
`.scratch/r491-signature-binders/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J38 development evidence: three selected cases pass 990 checks in each of
macOS debug and Linux release. Ten tiny accepted sources retain completion
blocks after transfers, matching and nested labels named `complete`, ordinary
bindings and assignments with that spelling, separate completion scope and
anonymous-function loop floors. Parser checks pin completion and transfer
nodes; lowering checks verify both target widths. Three refused sources
extend driver refusal/output checks to 920, covering body-local reads from
completion, unconditional-loop completion and an anonymous transfer that
cannot see an outer label. Builds use one worker and selected tests have
30-second or shorter timeouts. No assembler, linker or generated Landin
executable ran. Logs are retained in `.scratch/r491-complete-transfers/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J37/C6 development evidence: three selected parser cases pass 78 checks in
each of macOS debug and Linux release under five-second test timeouts. Six
sources, each under two KiB, cover the last permitted call, first refused
positional and labelled calls, recovery nesting, shallow recovery and three
refused public prefixes. Following functions survive every case. The first
test draft counted a function body as a nesting level and used an unsupported
return spelling; corrected controls isolate the existing 128-level limit and
statement recovery. One indentation warning was fixed before a clean,
one-worker rebuild. No overflow reproduction, assembler, linker or generated
Landin executable ran. Logs are retained in `.scratch/r491-call-depth/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J33 development evidence: four selected cases pass 1,066 checks in each of
macOS debug and Linux release. A tiny compile-only version of the reported
aggregate-sibling source still exited 70 before the repair. Eleven refused
sources now extend driver refusal/output checks to 1,008, covering absent,
misnamed, inout and nested receivers, hidden represented arguments/results,
parent and represented-formal constraints, and construction permissions. Six
accepted sources retain safe sibling and inherited tables, mutable and
read-only construction, ordinary providers and unused unsafe-any transport.
IR checks pin erased table and entry counts and verify both target widths.
The two existing object-safety/readonly negative fixtures pass. Builds use
one worker and selected tests have 30-second or shorter timeouts. No assembler,
linker or generated Landin executable ran. Logs are retained in
`.scratch/r491-erased-closure/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J56 development evidence: four selected cases pass 1,224 checks in each of
macOS debug and Linux release. A tiny bare-block literal reproduction was
accepted before the repair. A further scalar implicit-result reproduction
exposed a missing return constraint; declared and anonymous routine bodies
now apply the same constraint as explicit named-result assignment. Sixteen
refused sources extend driver refusal/output checks to 1,136, covering block,
branch, match, loop/complete, recovery, conversion, assignment, argument and
result boundaries. Thirteen accepted sources verify both target widths and
pin one range check per dynamic store, zero for direct known proofs and
non-arriving values, and isolation of nested-loop/anonymous transfers.
Arithmetic stays outside the literal-only rule. The first refusal run caught
an incorrect recovery-body accessor and an invalid atom-set test spelling;
both were corrected. Existing direct-literal and zeroed-exclusion negative
fixtures pass. Builds use one worker and selected tests have 30-second or
shorter timeouts. No assembler, linker or generated Landin executable ran.
Logs are retained in `.scratch/r491-control-ranges/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J79/N9 development evidence: four selected cases pass 87 checks in each of
macOS debug and Linux release. The shared outcome checker compares termination,
metadata status and ordered codes for source and recorded negatives. Metadata
now makes the historical source-negative default of 1 explicit, while other
classes retain default 0; explicit status 2 is honored. Fake metadata/outcomes
pin wrong status, reordered and missing duplicate codes, timeout and signal
refusals. The first test draft lacked required targets; corrected metadata and
the existing discovery case pass. All existing recorded negatives already
write an explicit status. A CLI fixture without a program retains exact report
bytes and status 2 while gaining a code check; a source fixture retains default
status 1. Builds use one worker and selected tests have 30-second or shorter
timeouts. No assembler, linker or generated Landin executable ran. Logs are
retained in `.scratch/r491-negative-contracts/` and
`.scratch/r491-final-values/`. Runtime stream selection and independent
inventory obligations under M14 remain open, as does exact acceptance.

J77/J78 development evidence: all nine build-inventory/shell test methods
pass on macOS and Linux. Explicit, bounded fake-command cases cover failed
source discovery, checksums for sources/projects/scripts, sorting, version
banners, saved-manifest reads and inventory/fixed-row extraction. A failure
leaves the previous manifest intact; successful output retains the existing
format and clean/incremental decisions. Recipe checks retain default and
override tags, while failed or empty checksums reach no fake-container call.
Every subprocess has a five-second limit and the test run has a 30-second
limit. Shell syntax checks pass. No real compiler build, container, assembler,
linker or generated Landin executable ran. Logs are retained in
`.scratch/r491-shell-status/`. A later compiler build will correctly clean
because build-script identity changed. Exact-revision acceptance remains open.

J84/J85 development evidence: four selected cases pass 44 checks in each of
macOS debug and Linux release. Partially specialized function-value and erased-evidence dispatch each
retain one indirect call and report it, while fully specialized dispatch
reports no fallback. Scalar size/alignment dump assertions distinguish measured
types and retain aggregate measurement fields on both target widths. Only the
nine scalar lines identified from their source fixtures were updated in the
lowering golden; no fixture-wide regeneration or comparison ran. The compiler
README defines the report field at the post-specialization boundary; this
revision has no separate IR reader guide. Both clean builds passed with one worker;
selected tests have 30-second or shorter timeouts. No Landin assembler, linker or generated executable ran.
Logs are retained in `.scratch/r491-ir-observability/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J91/K21/K22 development evidence: three selected cases pass 103 checks in
each of macOS debug and Linux release.
The block membership case covers omitted instructions, overlapping block runs,
wrong/missing/out-of-range membership, a no-operand Leave, reordered emission
and a nonzero item offset. A three-instruction unit exercises final cursors
for slots, parameters, blocks, values, fields and operands, appending only one
unclaimed entry to each vector. The initial test helper used an indexed vector
reference while appending; copying the element avoids Ada's cursor-tampering
exception. These are malformed-IR backstops, not new accepted-source claims.
Both single-worker builds passed; selected tests have 30-second or shorter
timeouts. No giant-array sound-unit case, Landin assembler, linker or generated
executable ran. Logs are retained in
`.scratch/r491-block-membership/`, `.scratch/r491-final-cursors/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J94/J95 development evidence: three selected cases pass 27 checks in each of
macOS debug and Linux release. Runtime-address load/store bounds use one-field
objects, including indices beyond Natural and at Part_Position's maximum;
large indices do not size storage. Scalar-store cases refuse whole struct and
two-element array slots while retaining ordinary scalar and field/element
stores. The existing invalid-address-store case passes. A mistaken test-helper
name was corrected before a clean, single-worker debug rebuild; Linux's
single-worker build passes. Selected tests have 30-second or shorter timeouts.
No Landin assembler, linker or generated executable ran. Logs are retained in
`.scratch/r491-address-field-bounds/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J96 development evidence and J98 disposition: two selected cases pass 34
checks in each of macOS debug and Linux release. Scalar datum operations keep
ordinary scalar access and refuse whole struct/two-element array access.
Atom and function loads retain their metadata when attached before emission;
metadata attached after emission is refused with the corresponding fault.
No result-type corruption hook was added for the refuted builder claim.
J98's cited incoming-edge scan is followed by an unconditional entry-reachability
check already present in both reviewed commits. At most three instructions,
without slots or pointers, prove self/pair islands are refused and connected
cycles pass. No reachability implementation changed. Both single-worker builds
passed; selected tests have 30-second or shorter timeouts. No Landin assembler,
linker or generated executable ran. Logs are retained in
`.scratch/r491-datum-loads/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J92 development evidence: the selected verifier case passes 36 checks in each
of macOS debug and Linux release. D74 already requires the smallest unsigned
tag; the verifier now enforces that count-dependent rule. The controls contain
at most 257 empty case descriptors, with no payload storage, and cover both
sides of the u8 boundary in datum fields, slot fields and measurements. They
also refuse nonminimal u16/u32 tags. The u16 upper transition is source-inspected,
not exercised by a large generated case. Both single-worker builds passed;
selected tests have 30-second or shorter timeouts. No Landin assembler, linker
or generated executable ran. Logs are retained in
`.scratch/r491-variant-tag-width/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J93 development evidence: five selected cases pass 158 checks in each of
macOS debug and Linux release. Seventy new checks cover root, nested, variant,
array, runtime-address and module selections, invalid identities/provenance,
and invalid alias/path runs without allocating their claimed large counts.
The existing storage-run case now includes aliases (14 checks), and the final
cursor case includes an orphan alias (42). Named-result/destructuring leaf
availability and variant-payload source lowering pass. The selection fixture's
initial variant payload run used a zero-based first position; correcting that
test setup made its valid controls reach the alias boundary. Both single-worker
builds passed; selected tests have 30-second or shorter timeouts. No debugger
session, Landin assembler, linker or generated executable ran. Logs are retained
in `.scratch/r491-source-aliases/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

K17 development evidence: six selected cases pass 106 checks in each of macOS
debug and Linux release. A tiny two-element fill from a named singleton atom
exited 70 before the repair and exits 0 afterward, through the default
compile-only driver under a ten-second limit. Six source forms cover named,
parameter, complete-set and struct-field fills plus the named/parameter direct
stores that already passed. IR controls independently prove subset writes,
exact reads/copies, unrelated-atom refusals and numeric/atom separation. The
existing typed-indirect case and three source-negative fixtures retain their
verdicts. Both single-worker builds passed; selected tests have 30-second or
shorter timeouts. No Landin assembler, linker or generated executable ran.
Logs are retained in `.scratch/r491-atom-array-writes/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J80 development evidence: three selected cases pass 121 checks in each of
macOS debug and Linux release. Ninety-six direct checks cover variant paths,
separate selectors, root-array paths, below-element leaves and invalid or mixed
selections. The source variant-payload control now asserts the queried length
and scalar type; the existing frame-array control still passes. The initial
macOS build caught a missing operator-visibility declaration in the new test;
that declaration was corrected and the required clean rebuild passed. Both
single-worker builds passed; selected tests have 30-second or shorter timeouts.
No Landin assembler, linker or generated executable ran. Logs are retained in
`.scratch/r491-slot-element-queries/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J97 development evidence: two selected cases pass 44 checks in each of
macOS debug and Linux release. Thirteen new tiny variant-payload scenarios
cover the reported three-element u8 array, wrong carrier/scalar flags, target
and range errors, offset/form errors and orphan descriptors. Genuine empty
and backed slice payloads pass; the existing top-level descriptor controls
also pass. Source history locates the complete descriptor scan in J30's
abbdb466 repair, so no verifier implementation change was needed here. The
initial test registration used the wrong harness operation name; that typo
was corrected and the required clean macOS rebuild passed. Both single-worker
builds passed; selected tests have 30-second or shorter timeouts. No Landin
assembler, linker or generated executable ran. Logs are retained in
`.scratch/r491-variant-slice-images/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J102/J103/J107 development evidence: three selected parser cases pass 95
checks in each of macOS debug and Linux release. Six fixed-conditional forms
preserve arm conditions, declarations and the following module binding, with
one L0103 only when the first if is absent. The tiny compile-only reproduction
retains exit 1 while its former L0103/L0102/L0103 cascade becomes one L0103.
Six match-arm forms classify loop, while and for consistently with and without
value-carrying breaks. The first match test wrote break 7; correcting that test
to the required break with 7 made its positive controls valid. Existing import
and directive boundary controls pass. Both single-worker builds passed;
selected tests have 30-second or shorter timeouts, and the compile-only
reproduction has a ten-second limit. No Landin assembler, linker or generated
executable ran. Logs are retained in `.scratch/r491-fixed-conditional/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J135 development evidence: three selected cases pass 137 checks in each of
macOS debug and Linux release. The new table case has 116 checks across both
target facts, covering identical and duplicate erased carriers, absent or
other concepts, permission direction, carrier-versus-pointer distinctions,
pointers/slices to any and nested pointers. Existing generic reference-actual
identity and three-element reference-array layout controls retain their
verdicts. Both single-worker builds passed; selected tests have 30-second or
shorter timeouts. No Landin assembler, linker or generated executable ran.
Logs are retained in `.scratch/r491-any-reference-identity/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J130 development evidence: four selected cases pass 240 checks in each of
macOS debug and Linux release. Thirty-two tiny source forms cover typed,
mutable, inferred, assigned, unused, chained and generic-call copies, plus
nominal mismatches, through read-only and writable aliases on both target
facts. Accepted copies have independent complete local slots and verified IR.
The original typed form exited 1 and the related inferred form exited 70;
both now exit 0 under the ten-second compile-only limit, while the assignment
control stays accepted. Initial tests exposed the additional pre-header
admission/inference timing issue; aliases now wait for their owning match
header, and unused inferred bindings resume during the body check. Existing
traversal, erased-recovery and alias-origin controls pass. Both single-worker
builds passed; selected tests have 30-second or shorter timeouts. No Landin
assembler, linker or generated executable ran. Logs are retained in
`.scratch/r491-payload-copy/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J125 development evidence: five selected cases pass 242 checks in each of
macOS debug and Linux release. Eight small accepted sources pin two concrete
instances each, including their element measurement types and count scales.
Six negative sources retain L0300 for a negative count, L0306 for a zero
divisor and L0305 for runtime storage used as a bound. Their initial generic
call used an untyped integer against u32; explicitly typing that argument
made the controls reach the intended bound checks. Existing target-carrier,
runtime-bound and scalar-range refusals pass. The original direct sizeof and
alignof sources now exit 0 instead of L0305; a local array declaration with
lenof remains a passing control. Both single-worker builds passed; selected
tests have 30-second or shorter timeouts, and compile-only reproductions have
a ten-second limit. No Landin assembler, linker or generated executable ran.
Logs are retained in `.scratch/r491-fixed-measurements/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J106/J127 development evidence: five ten-second compile-only probes pass in
both macOS debug and Linux release, covering the two corrected link notes
and array lengths zero, one and two. The existing constant-index negative
fixture also passes five checks in each mode, preserving L0306/L0300 ordering.
Both single-worker builds passed. No Landin assembler, linker or generated
executable ran. Native probe output and local build/fixture logs are retained
in `.scratch/r491-diagnostic-wording/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J86-J90 development evidence: six selected source-to-IR cases pass 239 checks
in each of macOS debug and Linux release. They cover struct and scalar/array
payload aliases, computed slice access with one evaluation, static bools,
finite/repeated/hybrid/zero array-field images, and aggregate call carriers.
The deleted branches are dominated by their existing live paths; the
non-inout conjunct is true from its enclosing branch. A ten-second
compile-only pointer-field probe confirms that the checker closes the
remaining non-C-string pointer route to the obsolete image helper. Any data
are excluded from that resolver's inventory. Both single-worker builds passed;
selected tests have 30-second or shorter timeouts. No Landin assembler, linker
or generated executable ran. Logs are retained in
`.scratch/r491-lowering-maintenance/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J120/J131/J132 development evidence: seven selected negative cases pass 39
checks in each of macOS debug and Linux release. The new exact-report fixture
retains the four root errors from an eight-report bounded reproduction, then
pins independent missing-conformance and non-integer-pointer controls. The
former exposed a first-reference related-span error; conformance reporting now
accepts the current required-type origin while ordinary constraints retain
their declared origin. Existing read-only caller/slice, non-integer traversal,
pointer-union-with-conformance, operand-cascade and ordinary constraint
refusals pass unchanged. Both single-worker builds passed; selected tests have
30-second or shorter limits, and the direct reproductions have ten-second
limits. No Landin assembler, linker or generated executable ran. Logs are
retained in `.scratch/r491-refused-operands/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J111/J115/J128 development evidence: six selected cases pass 83 checks in
each of macOS debug and Linux release. Resolution preserves type/fixed/runtime
argument roles for a later-declared callee; direct, indirect and field calls
retain their checked positions, and four one-element callable controls retain
verified IR. Named-return/field zeroed controls and both complete target
descriptions pass. The first macOS build found the now-unused Scope_Id import;
removing it allowed the required clean single-worker rebuild to pass. The
Linux single-worker build passed. The private target-label overflow branch is
established by inspection; no arbitrary-target seam or oversized fixture was
introduced. Selected tests have 30-second or shorter timeouts. No Landin
assembler, linker or generated executable ran. Logs are retained in
`.scratch/r491-unused-facts/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J122 development evidence: nine selected exact-report fixtures pass 54 checks
in each of macOS debug and Linux release. They retain their L0301 codes,
primary/related spans and refusal behavior while correcting the expected type
name and general contextual explanation. A ten-second macOS compile-only
module-binding probe also retains one L0301 and no irrelevant D124 note.
Both single-worker builds passed; selected tests have 30-second or shorter
limits. No Landin assembler, linker or generated executable ran. Logs are
retained in `.scratch/r491-context-wording/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J109 development evidence: four selected fake-host driver cases pass 33 checks
in each of macOS debug and Linux release. Seven explicit, one-shot exception
identities test four defect reports and three preserved host/tool exceptions;
no actual resource exhaustion is induced. Existing fake-tool failure,
refused-program/no-output and unknown-option controls pass. Both single-worker
builds passed; selected tests have 30-second or shorter limits. No Landin
assembler, linker or generated executable ran. Logs are retained in
`.scratch/r491-driver-exceptions/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J81-J83 development evidence: four selected source-to-IR and builder/verifier
controls pass 84 checks in each of macOS debug and Linux release. Four
one-element callable sources, four-byte static slice backing, ten tiny image
metadata scenarios, and a three-block instruction-run case preserve the live
builder paths. The wide scalar controls store one 2^32 number; their arrays
contain at most two elements per dimension and allocate no large image.
Production slice-image calls remain within once-per-item image resolution;
the callable controls exercise ordinary block emission. Both single-worker builds passed;
selected tests have 30-second or shorter limits. No Landin assembler, linker
or generated executable ran. Logs are retained in
`.scratch/r491-ir-builder-contracts/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J119/J139 development evidence: six selected negative fixtures pass 36 checks
in each of macOS debug and Linux release, preserving diagnostic codes and
source spans while updating wording and related labels. Eight separate
compile-only probes cover atom/pointer/slice-containing structs, omitted and
explicit zeroed distinct values, distinct assignment and expression results.
Each probe retains exactly one L0301; distinct reports contain no struct
wording. The last label correction exposed one stale golden, which was
updated before both final runs passed. Both single-worker builds passed;
fixtures have 30-second or shorter limits and probes have 10-second limits.
No Landin assembler, linker or generated executable ran. Logs are retained in
`.scratch/r491-nominal-wording/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J126 development evidence: the new three-error integer-argument fixture and
existing bool-condition golden pass 12 checks in each of macOS debug and
Linux release. Ten additional compile-only probes cover the three repaired
argument categories, unchanged pointer/slice/erased refusals and accepted
u32/u64/f32/bool values. A single 2^32 integer is a refused argument or u64
value, never an array extent; the sole fixed array has two u8 elements.
The new fixture preserves source order, one report per bad argument and the
actual required parameter origin, without a default-i32 overflow cascade.
Both single-worker builds passed; fixture tests have 30-second or shorter
limits and individual probes have 10-second limits. The diagnostic, token
and target inventories include the new fixture. No Landin assembler, linker
or generated executable ran. Logs are retained in
`.scratch/r491-literal-context/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J123 development evidence: diagnostics rendering plus 17 selected negative
fixtures pass 157 checks in each of macOS debug and Linux release. Five new
renderer assertions cover a shared snippet, retained structured labels and
label order, separate sources, and different span ends. Twenty duplicate
snippets are removed from 15 affected small golden reports; their labels,
messages, notes, codes and source order remain. Two further tiny C-layout
controls and four direct compile-only probes exercise zero-array fields,
variadic callback fields, slice parameters and an accepted scalar C signature.
The compiler reader guide describes the presentation rule. Both single-worker
builds passed; tests have 30-second or shorter limits and probes have
10-second limits. No Landin assembler, linker or generated executable ran.
Logs are retained in `.scratch/r491-c-report-spans/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J118 development evidence: nine selected negative fixtures pass 45 checks in
each of macOS debug and Linux release. Direct report comparisons justified
only the L0304-to-L0301 changes attached to the corrected zeroed fallback;
report counts/order and the two independent feature-limit reports remain.
Ten additional compile-only probes cover pointer, slice, atom, erased and
callback contexts, inference and arithmetic, plus accepted scalar, two-element
array and struct initialization. Invalid uses retain one report with a [0540]
note and no R2.20 promise. The diagnostic inventory records the seven moved
fixture witnesses. Both single-worker builds passed; tests have 30-second or
shorter limits and probes have 10-second limits. No Landin assembler, linker
or generated executable ran. Logs are retained in
`.scratch/r491-zeroed-context/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J114 development evidence: the selected import-scope seam and two existing
negative import goldens pass 43 checks in each of macOS debug and Linux
release. Four added seam controls cover a bare namespace, an alias, a
namespace used as a callee and a same-named parameter; existing controls
preserve same-named module values, qualified members, selected declarations
and file-local import scope. Type/concept fallback is unchanged. Both
single-worker builds passed; tests have 30-second or shorter limits. No
Landin assembler, linker or generated executable ran. Logs are retained in
`.scratch/r491-namespace-values/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J134 development evidence: three selected generic source-to-IR/checking
controls pass 12 checks in each of macOS debug and Linux release, preserving
instance-key reuse and declared/inferred error sets. Four compile-only
provider controls cover acceptance, actual-dependent type mismatch, definite
assignment refusal and a nested generic relay. The initial two cases also ran
before the repair and answered correctly; they establish no missed source
check. The correction makes the saved boundary equal to the initial loop's
actual range instead of a possibly larger count observed after that loop.
Both single-worker builds passed; selected tests have 30-second or shorter
limits and probes have 10-second limits. The sole fixed array has two i32
elements. No Landin assembler, linker or generated executable ran. Logs are
retained in `.scratch/r491-late-ready-instances/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J129 development evidence: the new four-error repetition fixture and two
existing inferred local/module shape controls pass 20 checks in each of
macOS debug and Linux release. Pointer, already-refused struct, no-value call
and bad arithmetic elements retain one root report each. Four compile-only
probes cover module pointer, atom and callback inference refusals plus an
accepted explicitly typed pointer repetition. All repetitions contain two
or three elements. Both single-worker builds passed; tests have 30-second or
shorter limits and probes have 10-second limits. The diagnostic, token and
target inventories include the new fixture. No Landin assembler, linker or
generated executable ran. Logs are retained in
`.scratch/r491-inferred-repetition/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J99 development evidence: six exact selectors pass 33 checks in each of
macOS debug and Linux release. Lexer controls preserve token counts, maximal
invalid-byte runs and spans; a rendered golden distinguishes uppercase-only
and mixed runs. Six compile-only probes cover both refusals and accepted
uppercase text, character, hexadecimal and comment contents. Both
single-worker builds passed; selected tests have 30-second or shorter limits
and probes have 10-second limits. No Landin assembler, linker or generated
executable ran. Logs are retained in `.scratch/r491-uppercase-diagnostics/`
and `.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J108 development evidence: five exact selectors pass 27 checks in each of
macOS debug and Linux release. Fake-driver controls cover exact repeats,
relative/absolute aliases, skipping a later alias before reading it, first
spelling in diagnostics, distinct equal-content files, trailing separators
and missing inputs. The bounded native identity seam uses two tiny files,
hard/symbolic links and missing/invalid names. Existing source diagnostics and
rooted-module controls also pass. Both single-worker builds passed; selected
tests have 30-second or shorter limits. No Landin assembler, linker or
generated executable ran. Logs are retained in `.scratch/r491-source-identity/`
and `.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J61/J68 development evidence: four exact selectors pass 26 checks in each of
macOS debug and Linux release. Scalar constants exercise zero, signed-imm32's
maximum, the first larger value, u32's maximum and the target byte-count
maximum without declaring large storage. Three small slice element types
preserve scaling and both bounds branches; existing three/four-element fills
and indexed local access preserve target widths, offsets and address order.
The wide register branches were inspected directly; no wide-type source,
giant prefix, assembler or generated executable was run. A tiny three-routine
assembly-text probe explained the test's extra descriptor traps, and its
assertion now names the actual slice-bound branches. Both single-worker
builds passed; selected tests have 30-second or shorter limits and the probe
has a 10-second limit. Logs are retained in
`.scratch/r491-arithmetic-immediates/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J112/A4/M11 development evidence: four exact selectors pass 34 checks in each
of macOS debug and Linux release. New ordinary-file controls retain missing,
unreadable and unwritable outcomes and successful later I/O. Existing controls
round-trip all 256 byte values, capture a tiny native tool result and preserve
the driver's distinct compiler, host-resource and external-tool outcomes.
Both single-worker builds passed; every selected test has a 30-second or
shorter limit. Device_Error and capture-read failure branches were inspected;
no device exhaustion, active-capture deletion or induced close failure ran.
No Landin assembler, linker or generated executable ran. Logs are retained in
`.scratch/r491-native-io-outcomes/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

A6 documentation evidence: [1810] and tour [0600]/[1150] now agree with
D184/D199 and the existing lowering validation path. The retained
`runtime/cstring-traversal-invalid-traps` fixture pins malformed foreign text
inside unchecked; its source and metadata were inspected without executing it.
The four prototype interactions were reviewed: prototype 2 keeps its byte API,
prototype 3's utf8 fields retain their origins, and prototype 4 converts
foreign arguments through the recoverable `text.from_c` channel. No semantic,
fixture, generated-code or runtime change was made, and prior runtime coverage
was not replayed. The full document check passes; exact acceptance remains open.

J138 development evidence: four negative selectors pass 23 checks in each of
macOS debug and Linux release. The new two-name anonymous-signature golden
and existing unknown-width golden report L0201 without future-feature notes;
real deferred widths and value-capture refusal retain their existing codes.
Five bounded compile-only probes preserve valid scalar/module-alias anonymous
signatures, ordinary unknown names and the separate unused-template refusal.
Both single-worker builds passed; selected tests have 30-second or shorter
limits and probes have 10-second limits. The diagnostic inventory moves only
the unknown-width witness and adds the new fixture; its 73 lexical tokens and
target row are recorded. No Landin assembler, linker or generated executable
ran. Logs are retained in `.scratch/r491-anonymous-type-reports/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

R4.91-F1, found while validating J138, is implemented: generic instance
ownership follows the resolver's lexical scope tree instead of textual source
containment. No-capture anonymous parameters, results and locals therefore
retain their independent declaration facts instead of being withheld for the
enclosing generic instance. The original nine-line source reproduced exit 70
in macOS debug and the previous Linux build before J138; a bounded stage seam
identified Infer asking an anonymous parameter/result for a binding initializer.
Six selected cases now pass 29 checks in each of macOS debug and Linux
release. Three source-to-IR controls cover the original typed binding, two
instances sharing an inferred anonymous body and nested anonymous signatures.
Existing generic key/error-set and no-capture refusal controls also pass.
Both single-worker builds passed; selected tests have 30-second or shorter
limits and the prior-build probe had a 10-second limit. No Landin assembler,
linker, generated executable or debugger session ran. Evidence is retained in
`.scratch/r491-generic-anonymous/`, `.scratch/r491-anonymous-type-reports/`
and `.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J101/N11 development evidence: five selected cases pass 135 checks in each
of macOS debug and Linux release. Seven short signature controls cover refused
bytes before types and punctuation, sibling parameters, a nested function type,
a named return and an ordinary missing-colon control. The new three-line
negative golden retains exactly two L0012 reports without spurious missing
arrows. Existing head, list-anchor and struct-closer controls also pass; the
last confirms J14 was already covered by J5. Both single-worker builds passed,
selected tests have 30-second or shorter limits, and the direct golden probe
had a 10-second limit. Diagnostic, lexical and target inventories record the
new fixture. No Landin assembler, linker, generated executable, parser stress,
truncation or mutation campaign ran. Evidence is retained in
`.scratch/r491-lexical-recovery/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J75 development evidence: five selected checking cases pass 40 checks in
each of macOS debug and Linux release. Existing controls preserve assigned
aggregate descendants, missing siblings, branch joins, consumption, scalar
field/result initialization and multiple-result cleanup calls. The signature
control checks successive compilation contexts whose maximum widths differ
(two struct fields, then four results), exercising invocation-local sizing.
Source inspection establishes that all ten repeated queries now use the bound
already elaborated once by the local subtype; no timing improvement is claimed
from measurement. Both single-worker builds passed and selected cases have
30-second or shorter limits. No new stress case, timing sweep, Landin assembler,
linker or generated executable ran. Evidence is retained in
`.scratch/r491-flow-width/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J11 development evidence: the two tiny compile-only inputs reproduced exit 70
for a returned struct and a distinct conversion before repair. Five selected
lowering cases now pass 70 checks in each of macOS debug and Linux release.
Eight new source-to-IR controls cover module/local/nested destinations, returned
structs, conditional results, a two-element computed selection, distinct
conversions and literal/zero/rooted-storage controls; they verify complete IR
and count every written call without duplicated evaluation. Existing variant
selection, copy, clear and hidden-result controls also pass. Both single-worker
builds passed; selected cases have 30-second or shorter limits and the original
probes had 10-second limits. No Landin assembler, linker, generated executable
or debugger ran. The reader documentation describes the shared writer, and
evidence is retained in `.scratch/r491-variant-values/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

M10/J13 development evidence: the 15 diagnostic cases plus three source
line-ending cases and two small refusal fixtures pass 97 checks in each of
macOS debug and Linux release. A 248-byte source pins a clipped middle span,
a clipped CRLF endpoint, a wide underline and complete UTF-8 excerpt edges.
The 128-byte test budget pins exact fit, one-byte overflow, complete-report
ordering, large primary/related/note messages and UTF-8 truncation boundaries.
All structured diagnostics, labels and notes remain present. The 1 MiB default
uses the same tested path; it is not tested by generating a large report.
The line-span query reuses the source layer's existing CR/LF trimming, and
existing fixture goldens contain no over-window source lines. Both single-worker
builds passed, with selected tests limited to 30 seconds or less. The full
document check passes and the diagnostic inventory is unchanged. No old stress
measurement, Landin assembler, linker, generated executable or debugger ran.
Logs are retained in `.scratch/r491-rendering/` and
`.scratch/r491-final-values/`. J69's tab/Unicode display-column question remains
separate; excerpt boundaries preserve bytes without claiming display-width
alignment. Exact-revision acceptance remains open.

J133 development evidence: six selected cases pass 47 checks in each of
macOS debug and Linux release. The original two-instance range mismatch
reproduced two complete L0301 reports before repair; the new negative golden
retains one, including its original primary, related span and note. Six checking
controls cover one mistake, two source locations, differing actual-type messages,
an ordinary routine, independent templates and nested instance views. Existing
declared/inferred generic errors, instance keys and independent anonymous bodies
also pass. Each new diagnostic is attributed once at a view transition, including
early traversal discovery; exception unwinding retains partial reports without
allocating a key. The maps and attribution frontier live only for this checking
invocation. Both single-worker builds passed; selected cases have 30-second or
shorter limits and the three initial compile-only probes had 10-second limits.
The diagnostic and fixture inventories record the new refusal. No Landin
assembler, linker, generated executable or debugger ran. Evidence is retained
in `.scratch/r491-generic-reports/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J69 development evidence: the 16 diagnostic cases and five selected negative
fixtures pass 108 checks in each of macOS debug and Linux release. Eight small
exact-text controls cover a tab, a two-byte UTF-8 character, a span inside that
sequence, an end point, an invalid high byte, NUL/escape bytes and a related
label. Snippets render tabs as `\t` and other non-printable/non-ASCII bytes as
`\xNN`; both padding and underline length use those displayed cells. The new
one-line compiler golden keeps byte column 30 after a UTF-8 comment and a tab,
with its underline aligned to the escaped snippet. Existing ASCII goldens,
L0012 refusals and report-budget/excerpt controls also pass. Both single-worker
builds passed; selected cases have 30-second or shorter limits and the direct
probes have 10-second limits. The inventories record the new fixture. No Landin
assembler, linker, generated executable, debugger or large input ran. Evidence
is retained in `.scratch/r491-display-columns/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J66 development evidence: five selected cases pass 48 checks in each of macOS
debug and Linux release. Five small fake-driver programs cover an empty entry
source, private and wrong-shaped main declarations, an inactive main and a
local binding named main. Existing imported-entry and hosted-linkage controls
confirm that imported names are excluded and renamed main retains L0502. The
renamed-entry golden now points at the declaration's four-byte name. Its
unchanged missing-entry predicate refuses before any output or tool call;
the other driver controls use fake host tools. Both single-worker builds
passed, with individual test limits of 30 seconds or less. No Landin assembler,
linker, generated executable, debugger or large input ran. Evidence is retained
in `.scratch/r491-entry-source/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J137 development evidence: six selected cases pass 142 checks in each of
macOS debug and Linux release. The two callers of the removed scalar-only
`Field_Array_Element` query now use complete field shapes; the compiler's
module-image edge compares full element identity. Existing target-layout,
struct-image, recursive-source and pointer/erased-array copy controls pass,
as do two scalar element-mismatch refusals. All sources contain small arrays;
no giant foundation seam was rerun. This resolves a misleading API, not a
reproduced source miscompile: the retained review's mismatch was already
refused, and recursive images already take the complete-shape path. Both
single-worker builds passed, with individual test limits of 30 seconds or
less. No Landin assembler, linker, generated executable or debugger ran.
Evidence is retained in `.scratch/r491-array-query/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J136 development evidence: four selected cases pass 156 checks in each of
macOS debug and Linux release. A new 15-check table seam uses two small source
declarations, two routine instances and three small constraints to cover
unwritten fallback, idempotent writes, conflicting-write refusal, independent
nodes, nested restoration and reactivation. Existing generic-actual refusals,
control-result range lowering and generic diagnostic coalescing also pass.
Both single-worker builds passed; individual tests have 30-second or shorter
limits. No Landin assembler, linker, generated executable, debugger or large
input ran. Evidence is retained in `.scratch/r491-owed-checks/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

R4.91-F2, found while validating J136, is implemented: generic publication
copies a written scalar range constraint to its type position and declaration,
and the instance signature carries written parameter/result constraints.
Previously `Publish_Descriptor` published only the scalar kind, after which
`Type_At` returned before copying the constraint. The signature's `Part_For`
also omitted the constraint that ordinary signature construction retained.
This repair preserves the policy on constrained generic actuals.

F2 development evidence: six selected cases pass 177 checks in each of macOS
debug and Linux release. Five tiny IR programs each instantiate one generic
routine twice and verify dynamic checks for locals, parameters, results and
updates, including the absence of redundant checks when a written local
already carries a range proof. A new nine-line negative fixture now reports
one L0300 for a zero initializer outside 5 through 10 across two instances.
Existing owed-check, generic-actual, control-result and diagnostic-coalescing
controls pass. A ten-line source's assembly text now contains both bounds in
each instance (1,972 bytes); before repair it contained neither check (1,584
bytes). A separate literal argument probe hit the existing exact scalar type
pattern refusal and is not range-check evidence. Both single-worker builds
passed, individual tests were limited to 30 seconds or less, and direct probes
to ten seconds. The inventories record the new fixture. No Landin assembler,
linker, generated executable, debugger or large input ran. Evidence is retained
in `.scratch/r491-generic-ranges/`, `.scratch/r491-owed-checks/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J100 development evidence: seven selected cases pass 153 checks in each of
macOS debug and Linux release. A two-line negative fixture preserves all nine
L0103 reports byte-for-byte across delimiter-free names and unmatched nested
parentheses. Existing conformance, reference-signature, valid-head, list-anchor,
struct-closer and lexical-boundary controls pass. One lazy per-parse token scan
indexes parentheses and brackets independently; signature queries then read
the matching close, and conformance queries can refuse an unmatched opener
without scanning its tail. Conformance answers are cached only for suffixes
entered with both depth counters zero, retaining the old contextual-is and
mismatched-delimiter behavior. Cache and temporary vectors live on the heap
and hold at most one record/index per token. This addresses the reported
repeated scans, not every possible malformed-input complexity question.
Both single-worker builds passed, individual tests were limited to 30 seconds
or less, and the baseline golden probe to ten seconds. The inventories record
the fixture. No timing/scaling campaign, Landin assembler, linker, generated
executable or debugger ran. Evidence is retained in `.scratch/r491-lookahead/`
and `.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J62/J64/J67 development evidence: six selected cases pass 81 checks in each
of macOS debug and Linux release. Four exact DWARF register expressions cover
direct and indirect locations in RBX/R15. Four tiny source-to-IR metadata
controls accept whole one-element array aliases and reject whole scalar
slot/datum aliases with explicit compiler defects before invalid shape queries.
A fake-driver array copy emits address and debug text without host tools.
Existing frame-home, debug-mode and named-result/destructuring controls also
pass. The frame test confirms that offset zero alone cannot distinguish a
promoted slot from real zero-byte storage. Current allocation still pins
address slots and current lowering avoids the invalid whole scalar aliases;
these are boundary repairs, not new claims of source miscompilation. Both
single-worker builds passed; individual tests had 30-second or shorter limits.
No native assembly, generated executable, debugger or giant image ran. Evidence
is retained in `.scratch/r491-address-guards/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J63 development evidence: five selected cases pass 104 checks in each of
macOS debug and Linux release. The new case covers final assignments, explicit
and implicit returns, initialized and uninitialized failure results, and
parameter availability. Existing debug-mode, destructuring, scope and
success-edge controls pass. The original one-line `code = 42` program emitted
an empty location list; its 7,161-byte assembly text now contains the result's
frame location from return preparation to the new pre-restore label. Each
terminal flushes its own range before another laid-out block can extend it
across the epilogue. Single-worker builds and individually bounded tests pass.
No native assembly, generated executable, debugger or giant image ran. Evidence
is retained in `.scratch/r491-return-locations/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J76 development evidence: four selected negative fixtures pass 22 checks in
each of macOS debug and Linux release. The new 42-line fixture has only
one-element arrays and four L0314 reports: a value-parameter payload, a copied
array-element payload, a scalar value parameter, and an external payload
joined with a later temporary. The first three baseline reports incorrectly
pointed to the module `anchor`; the repaired notes select the frame sources,
and the fourth control excludes the earlier external payload. Existing copied
payload, escaping-argument and array-return refusals retain their reports.
Only related source selection changed; reference acceptance is unchanged.
Single-worker builds, exact fixture runs and the inventories pass. No native
assembly, generated executable, debugger or giant image ran. Evidence is in
`.scratch/r491-escape-source/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J65 development evidence: five selected cases pass 57 checks in each of
macOS debug and Linux release. Explicit 0–48-byte stack budgets exercise size,
per-home alignment and final padding limits without giant source or assembly.
The existing malformed-storage case now uses a 32-byte spill against a
16-byte budget for its size failure; its other seven invalid-home controls
still require compiler defects. Absent IR items preserve assertion/bounds
failures, and requesting the native C ABI on the synthetic target preserves
its compiler defect. Existing allocated-frame, mixed INTEGER/SSE classification
and narrow C-call text controls pass. Only the dedicated checked stack-limit
exception is a preflight capability answer; incoming C arguments reserve the
same 16-byte frame prefix as before. Single-worker builds pass. No native
assembly, generated executable, debugger or giant image ran. Evidence is in
`.scratch/r491-stack-limits/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J121 development evidence: six selected fixtures pass 27 checks in each of
macOS debug and Linux release. Eight formerly accepted unused templates now
produce exact L0301 reports for tagged variants, concrete and symbolic slices,
nested slice arrays, zero-length symbolic arrays (direct and aliased),
ordinary nominal instances and Landin callbacks. A valid fixture retains
unknown type fields, bounded array fields, pointers to symbolic slices, nested
C records and fixed C callbacks, and concretely instantiates the record with
two array elements. Existing empty/zero-array/variadic C refusals and recursive
C callback acceptance remain intact. Both single-worker builds, exact fixture
runs and inventories pass; positive fixtures emitted text only. No native
assembly, generated executable, debugger or giant image ran. Evidence is in
`.scratch/r491-symbolic-c-layout/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

R4.91-F3, found while validating J121, is implemented: pointer metadata
retains nominal identity through nested arrays without requiring a value body.
Value access materializes generic pointee layouts before field or stride
queries. Verification still refuses malformed identities, structural cycles,
contradictory explicit bodies and opaque by-value storage. Pointer equality
stops at nominal identities even beneath arrays. Full debug text describes an
unmaterialized pointee as a declaration without invented size or members;
materialized types retain their complete descriptions. The original five-line
record case, pointer-array case and field access all exited 70 before repair.
Tiny reproductions and logs are retained in `.scratch/r491-pointer-nominal/`
and `.scratch/r491-symbolic-c-layout/`. Seven exact selectors pass 73 checks in each of macOS debug and Linux
release; both single-worker builds and the fixture inventories pass.
No native assembly, generated executable, debugger or giant image ran.
Exact-revision acceptance remains open.
J18/J73 development evidence: eight exact selectors pass 49 checks in each
of macOS debug and Linux release. The new positive fixture retains nested
payload addresses through computed indexes, builtin traversal aliases,
captured slices after descriptor rebinding, inout arrays and module arrays.
Same-source element stores remain valid. Nine exact negative reports cover
frame-backed arrays and payloads, a nested live retag, local slice/array
storage, copied indexes and text scalars, returned-array temporaries, and a
frame reference stored through an external collection element. Generic
iterable copies retain their independent frame storage. Existing payload
lifetime, copied-subject, source-free iterable-contract and related-source
controls pass. The existing payload last-use and collection programs also
compile through verified IR in both modes, without running their executables.
All arrays contain at most five elements. Single-worker builds and inventories
pass; positive fixture execution means assembly text emission only. No native
assembly, generated executable, debugger or giant image ran. Evidence is in
`.scratch/r491-alias-backing/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

R4.91-F4, found while validating J73, is implemented: an early iterable
header obtains its exact entry signature from the declared concept and
interned conformance key when the provider table is not populated yet. The
shared contract query already supports erased-call staging. Ordinary provider
validation remains mandatory, and populated rows retain their provider-backed
checks. The baseline ordinary traversal over a named parameter exited 70
while only reading its element; `f17e4772` Linux release reproduced it too.
Nine exact selectors pass 43 checks in each of macOS debug and Linux
release; both single-worker builds and the inventories pass. Controls cover ordinary and generic copied element storage,
inferred locals and loop expressions, early generic calls, inferred errors,
erased labels, a bad provider and a bad declared iterable contract. Each bad
contract produces one exact L0301, and the original source-free Item refusal
is preserved. Tiny sources and transcripts are in
`.scratch/r491-iterable-contract/`, `.scratch/r491-alias-backing/` and
`.scratch/r491-final-values/`. No native assembly, generated executable,
debugger or giant image ran. Exact-revision acceptance remains open.

J6 development evidence: ten exact selectors pass 42 checks in each of
macOS debug and Linux release. Fake-filesystem controls cover exact, trailing,
dotted and relative directory spellings; uncertain equal-content directories
retain two independent modules. A proven alias is skipped before a second
read, and a diagnostic retains its first source spelling once. Existing root
precedence, visibility, missing-directory, entry-main, conformance-register,
library-order and shallow-listing checks pass. The fake listing adapter now
handles a trailing separator like the native adapter. A ten-line native
self-importing module emitted two state objects under relative or trailing
entry spellings before repair; all three exact/relative/trailing requests now
emit one object in both modes. The macOS assembly texts are each 5,270 bytes.
Single-worker builds pass. These are text-emission and fake-tool checks; no
native assembly, generated executable, debugger or giant image ran. Evidence
is in `.scratch/r491-module-identity/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J104's statement repair preserves ordinary contextual-name bindings and
assignments by recognizing their existing punctuation before control-word
dispatch. Match arms use the same distinction; labelled loops retain their
existing priority. Twelve explicit names have small immutable-binding,
indexed-assignment, compound-assignment, match-arm, loop-body and completion
controls. Seven exact selectors pass 107 checks in each of macOS debug and
Linux release, including existing control expressions and cleanup/transfer
boundaries. Both single-worker builds and the inventories pass. The positive
fixture emits assembly text only; no native assembly, generated executable,
debugger or giant image ran. Evidence is in
`.scratch/r491-contextual-names/` and `.scratch/r491-final-values/`.
At that batch boundary, an ordinary read of a parameter named `match` was
still intercepted as a control expression. J104/D225 subsequently repaired
that primary-expression facet without reserving words or introducing newline
semantics. Exact-revision acceptance remains the phase closure requirement.

M15/N17/J20 development evidence: five exact metadata/discovery selectors
pass 124 checks in each of macOS debug and Linux release. Fake fixtures
prove that ordinary and renamed cases retain six profiles, names formerly
recognized by substring cannot override an explicit four-profile policy,
and missing, empty, unknown, duplicate or misplaced policy is refused.
All 495 runtime/ABI metadata files are migrated: 114 retain their existing
six-profile matrix, 377 retain four profiles, and the four erased-dispatch
cases gain the two forced-specialization profiles. The same profile-count
query controls selected and complete runtime/ABI execution. Single-worker
builds and repository metadata discovery pass. `check.py` independently
requires the key and its two defined values in the appropriate classes.
This is metadata and policy evidence only; none of those runtime or ABI
fixtures was assembled or executed. No native assembly, generated executable,
debugger or giant image ran. Evidence is in `.scratch/r491-fixture-profiles/`
and `.scratch/r491-final-values/`. Expanded matrix execution and exact-revision
acceptance remain open under the existing resource limits. M14's separate
stream and inventory contracts remain active.

M14 stream development evidence: eight exact selectors pass 151 checks in
each of macOS debug and Linux release, counting the final 81-check stream
oracle with its profile-label controls. Recorded, runtime and ABI paths share
capture selection and expected-byte comparison. `stream: output` independently
requires empty stderr even when no output file is named; the default merged
stream keeps its existing byte oracle. Fake outcomes distinguish correct
stdout, expected bytes on stderr, extra stderr and wrong merged bytes. Tiny
native shell probes retain literal argument bytes, nonzero exit status,
separate stderr and a cleared stderr field on a subsequent merged capture.
Both captures use already-open descriptors and the same failure cleanup;
closed-standard-descriptor aliasing is guarded before stdout redirection.
Both single-worker builds pass. No runtime/ABI fixture, native assembly,
generated Landin executable, debugger or giant image ran. Evidence is in
`.scratch/r491-fixture-streams/` and `.scratch/r491-final-values/`. M14's suite
inventory and coarse floors remain open, as does exact-revision acceptance.

M14 suite-inventory development evidence: the expected names now include
`catalogue` and `lexer`. Startup compares both required-name presence and the
number of distinct registered suite names before any selected or complete
run. `check.py` compares every suite source package with the main program's
registration calls and expected names, including duplicate entries; removing
both a registration call and its expected name still leaves a source mismatch.
Six exact selectors pass in each of macOS debug and Linux release: 23 small
harness/lexer checks and 3,715 catalogue table invariants. The registry seam
covers empty and interleaved suites, repeated case names in different suites,
and a refused duplicate; filtering and ordering remain intact. Both
single-worker builds pass. No fixture corpus run, native assembly, generated
executable, debugger or giant image ran. Evidence is in
`.scratch/r491-suite-inventory/` and `.scratch/r491-final-values/`.
The separate M14/N5/N7/N8 fixture-discovery and selection accounting repair
is recorded below. Exact acceptance remains open.

M14/N5/N7/N8 fixture accounting replaces the parser and execution floors with
metadata-derived obligations. Ada discovery must match every fixture identity
and target list in the independent `check.py` inventory. Missing, extra,
duplicate, malformed and changed-target rows fail; comments and the four
prototype scope rows are handled separately. Runners reject metadata problems
before work, count all eligible programs and recorded expectations, and count
runtime/ABI attempts inside each selected profile loop. Positive, negative,
runtime, ABI and recorded-output categories retain explicit nonempty duties.
The counters describe attempts; existing verdict/output checks still decide
success. Intentional fixture removal plus inventory regeneration still needs
semantic coverage review. Both single-worker builds and five exact selectors
pass, with 150 checks in each of macOS debug and Linux release. Validation
is restricted to fake catalogues and real metadata; the changed broad parser, emission and runtime cases are not
executed under the resource limits. Evidence is in
`.scratch/r491-fixture-accounting/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J70 development evidence: [1810] and D156/D157 both explicitly exclude new
post-loop assignment facts established only in an iteration or completion.
Tiny baseline while/for completion and unconditional-break examples were
accepted despite that rule. The repair retains the existing iterative head
and actual exit joins, then limits positive assignment facts to entry and
condition facts using the existing sparse containment-aware merge. It adds no
fictional consumed edge: consumed places still come only from actual exits,
so a genuinely restored initialized reference remains live. Bounds evaluated
before a `for` and assignments in a while condition retain their effects.
Six exact selectors pass 54 checks in each of macOS debug and Linux release.
Controls cover scalar results, sparse/whole arrays, nested fields, array
fields, previously assigned values, condition/bound effects, loop values,
body/completion returns, consumed exits and restored references. The existing
`loop-control-flow`, `loop-values` and `for-range-traversal` runtime sources
also compile to verified IR in both modes; they were not executed. Fixture
arrays contain at most two elements; the existing controls at most three.
Both single-worker builds and the inventories pass. Positive fixture checking
emits text only. No native assembly, generated executable, debugger or giant
image ran. Evidence is in `.scratch/r491-loop-assignment/` and
`.scratch/r491-final-values/`. Exact-revision acceptance remains open.

A9/m18 current-tree attribution is reconciled. The root inventory no longer
claims there is only one third-party item or that project terms override every
file. It names Lucide's ISC and SourceHut's CC0 notices already in
`assets/icons.py`, the vendored Nunito Sans OFL, and the Tree-sitter header
notice now retained beside those files. The three support headers are
byte-identical to the pinned v0.26.9 upstream template/library files; the
upstream MIT license is copied unchanged and linked from the parser guide.
`check.py` requires the named notices and their attribution markers. No
project, font or upstream license terms changed, and no history was rewritten;
M5 now records the maintainer's decision to leave the historical font files for now.
Source URLs, byte comparisons and hashes are retained in
`.scratch/r491-third-party-inventory/tree-sitter-provenance.json`.
This is a source/notice audit; no compiler, assembler or generated program ran.

A5/M9's baseline source-location lookup failed both matching-build controls
under `PYTHONIOENCODING=utf-8:strict`: converting filesystem bytes to text
made success depend on stdout's encoding error policy. The decoder now keeps
`resolve`'s byte result through binary output and appends only ASCII
coordinates. The focused check exercises matching build-ID and assembly-hash
lookups under strict UTF-8 and strict ASCII, then retains absent/mismatched
build and unknown-file refusals. Every subprocess has a ten-second timeout;
the only assembly input is a tiny text hash witness and is never assembled.
No Ada build, native assembly, generated executable, debugger or giant image
is needed for this Python-only repair. Exact-revision acceptance remains open.

N13/m5 repairs trailing-directory separators in the fake filesystem without
claiming general native path normalization. Directory registration and lookup
share their trailing-separator spelling, preserve the root separator and retain
sorted shallow listings. Existing directory identity follows that same rule;
file reads still use exact spelling, missing directories gain no identity,
dot/relative/symlink equivalence stays explicit and unreadable-file injection
is unchanged. Four combinations of entry/root trailing separators compile a
two-module fake-host source without writes or tool calls. Existing source and
module identity, listing and read-status controls bring this group to 52 checks.

N15 adds a separate determinism oracle: three fixed sources cover accepted C
call/array syntax, multiple parser reports and lexical/parser recovery. Each
is parsed with a fresh then reused name table, and with an independently seeded
name table. Twenty-four checks compare canonical node/slot text, full rendered
reports, soundness and counts while independently requiring the two source
declarations and the expected diagnostic presence. No corpus is read or mutated,
and no generated input, truncation or depth campaign is involved. The syntax
dump's stale 42/23 corpus-count comment now describes the current stage-aware
grammar contract without freezing another historical count.

All seven exact cases pass 76 checks in each macOS debug and Linux release
single-worker build. The compiler's production behavior is unchanged by this
harness repair. Every selected test is bounded to at most 30 seconds; no
assembler, linker, generated program or debugger ran. Logs remain in
`.scratch/r491-harness-controls/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J48/D221 removes parent-order precedence from static concept entry selection.
A per-selection visited set examines each declaring concept once, including the
represented formal's constraint, and stops after a second distinct declaration.
It preserves diamond inheritance and the existing evidence-table identity and
order. A refused selection is no longer passed to runtime-value classification,
which would otherwise add an unrelated type-name diagnostic. The positive-index
set implementation is shared with diagnostic coalescing; their set instances
remain independently owned.

Seven small checker sources cover both parent orders, a represented constraint,
a direct/inherited collision, distinct entry names, an unused colliding closure
and a shared ancestor. They pass 28 checks across both target widths. The paired
negative/positive fixtures, erased-label control, generic report-coalescing case
and object-safety refusal bring the six selected cases to 70 checks in each of
macOS debug and Linux release. Both single-worker builds pass. The first checker
run exposed the secondary runtime-type diagnostic; the corrected continuation
passes the original one-report oracle without weakening it. Four generated
inventories were refreshed, and prototype 3's historical finding tail is unchanged.
All positive evidence stops at assembly text: no assembler, linker, generated
program, debugger, giant source or broad suite ran. Logs remain in
`.scratch/r491-static-entry/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

M6's local object audit reconciles historical source identity without changing
any gate's original input. All rewritten commits below are ancestors of the
reviewed `66927e93`. For each pair, the complete tree diff consists only of
removing the three historical agent-guidance documents about domain policy,
issue tracking and triage labels; compiler, fixture, build and roadmap contents
are identical within the pair. This is source correspondence, not a transfer
of an exact-revision acceptance tag from one commit to another.

| Historical source | Pre-rewrite commit | Rewritten source commit |
| --- | --- | --- |
| R1.90 closure | `7f6d8f6a` | `c3facac5` |
| R2.90 closure | `ca3a3e62` | `f0967732` |
| R3.70 parser closure | `9aea049a` | `58bef7c8` |
| R3.80 editor support | `981ca477` | `dcf6aec6` |
| R4.20 integrated closure | `22c18b82` | `e1544d2e` |
| R4.21 last tested increment | `7814476a` | `e64b79f8` |
| R4.21 closing prose | `a9c44eba` | `d06cf91a` |
| R4.30 committed successor | `711c4ccd` | `54bb61ef` |
| R4.40 implementation | `c1efeb1d` | `22d30e4d` |

The R4.30 tested tree `22f74589f212f64f6c08da810e35daf208826bb6` remains
locally readable as a tree object. Its diff against pre-rewrite `711c4ccd`
contains only closure edits in `README.md`, `ROADMAP.md` and `handoff.md`.
It is neither the committed successor's exact tree nor a commit claimed as an
ancestor. The original SourceHut job references above remain attached to their
historical inputs; this audit does not revalidate their remote job contents.

R1/R2/R3's phase gates now identify concrete retained source witnesses and the
R2/R3 counts recorded at their closure revisions. Their original native run
bundles are not supplied by those source records and have not been recovered
in this audit. The maintainer closes M6 by accepting this explicit historical
evidence gap: those original runs remain unverifiable, the retained source
references remain available, and new acceptance establishes only its current
revision. Current filtered checks and R4.91 acceptance cannot retrospectively
establish an earlier exact run. No old
suite, assembler, debugger, publication or history rewrite ran for this audit.
Full object IDs, ancestry verdicts and exact path differences are retained in
`.scratch/r491-history-evidence/anchors.json` and `pairs.json`.

A7/M19's remaining special-name check found a whole-name dot reached assembly
unquoted. The pinned GNU assembler accepted a 695-byte definition, but its
`.size` expression resolved both dots as location counters and recorded size
zero. A 2,403-byte quoted control established that the same tool preserves the
requested symbol: its definition has the proper size, and direct calls, runtime
addresses and static data relocations name that exact symbol. The shared renderer
now quotes a whole-name dot alongside its existing leading-dollar rule. The
unquoted dot in a size expression remains the actual location counter; semantic
namespace allocation and the admitted link-name grammar are unchanged.

Three exact backend cases pass 14 checks in each macOS debug and Linux release
build, including existing dollar and namespace-reservation controls. A final
4,518-byte source-generated assembly file passes one pinned-GNU object check:
`readelf` confirms the exact `.`, `$export` and `$foreign` names, nonzero defined
function sizes and the expected call, address/GOT and static-data relocations.
Each of these three assembly invocations named one separately inspected file,
ran alone in the foreground with a 20-second process-group timeout and followed
an idle compiler/assembler process check. None contains expansion directives;
the first two expand below 4 KiB and the last below 8 KiB. No link, generated
program, debugger, clang or fixture sweep ran. Logs, exact files and SHA256
identities remain in `.scratch/r491-symbol-identity/`; development test logs are
also in `.scratch/r491-final-values/`. Exact-revision acceptance remains open.

J53/D220 makes the existing no-dereference sink boundary explicit for slices.
A literal slice index follows backing storage and is refused; literal fixed-array
indexes and whole descriptors still name contained places. Ten small checker
sources cover slice parameters, local views, restored fields, instantiated
generics, explicit pointer dereferences, computed indexes and paired descriptor/
fixed-array restoration. They pass 40 checks across both target widths. Five
exact fixture selectors add 23 checks, including the two new paired fixtures.
All 63 checks pass in macOS debug and Linux release after single-worker builds.

The initial generic refusal control did not instantiate its generic body and
therefore did not exercise the sink check. Both generic controls now include
concrete callers; this is evidence for instantiated bodies, not unused-template
checking. The four fixture inventories were regenerated, and prototype 3/4's
historical finding tails remain byte-identical. Positive fixtures emit assembly
text only; no Landin assembler, linker, generated executable or giant image ran.
Logs remain in `.scratch/r491-sink-storage/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

K35 records the C compiler selected by the native GPR configuration rather
than assuming the bare `gcc` banner identifies it. A bounded helper creates
one configuration snapshot for both project builds, fingerprints its declarations
and records the selected driver's absolute path, binary hash and full version
response. The snapshot lives beside the per-mode lock and is regenerated before
manifest comparison. Both ordinary and checksum builds clean on an identity
change; unchanged content keeps its timestamp. Wrapper `--config`/`--autoconf`
overrides are refused so both projects consume the recorded configuration.
Failed configuration or compiler-version probes leave the previous successful
build and snapshot alone. Each probe has a ten-second process-group limit.

Thirteen build-inventory tests pass on each host, including the real wrapper
and helper running against disposable fake toolchains. They distinguish a
configured C driver from an unrelated `gcc` on PATH, check path/version/binary/
configuration changes in both invalidation modes, verify both project commands,
exercise spaces in paths, preserve failed-probe results and cover configuration
override refusal. No machine compiler installation is changed by these controls.
The actual single-worker macOS debug and Linux release builds pass, followed by
13 checks across the native file-identity and argument/capture adapter cases.
On each host, an unchanged developer run preserves the manifest, configuration
and both executable timestamps and takes the existing fast path. The recorded
C driver is the pinned Darwin triplet driver on macOS and pinned gcc on Linux.
The fake-toolchain suite has a 30-second limit and selected native cases have
limits of at most 30 seconds. Logs remain in `.scratch/r491-c-identity/` and
`.scratch/r491-final-values/`. No Landin assembler, linker or generated program
ran. Exact-revision acceptance remains open.

K31's focused source audit distinguishes the existing C stack guard from a
missing internal-call bound. Internal entry, direct-call and indirect-call
areas now use checked physical-count arithmetic, shared with text emission.
Multiplication and final stack alignment obey the signed displacement limit;
incoming areas additionally leave room for the saved frame and return address.
This is a source/seam repair, not a claim that a giant source was reproduced.

Four exact cases pass 52 checks in each of macOS debug and Linux release.
Thirteen arithmetic checks cover register-only calls, small aligned areas,
insufficient limits and exact signed-encoding boundaries, including the
incoming prefix. Those boundary values are scalar counts only: no corresponding
argument arrays, IR lists, source lists, images or stacks are allocated.
An eight-argument source retains direct and indirect text emission and entry/call
preflight; existing stack-exhaustion/defect and C classification controls pass.
An Ada default-expression visibility error required a corrected clean macOS
build. The boundary test then needed its expected exception caught inside the
executable block; that test-only correction passed after checksum recompilation.
Linux's single-worker build and all four selectors pass. Tests have limits of
at most 30 seconds. Logs remain in `.scratch/r491-native-stack/` and
`.scratch/r491-final-values/`. No Landin assembler, linker or executable ran.
Exact-revision acceptance remains open.

K32 does not establish a current ABI defect. [1975]'s admitted scalar leaves
have at most eight-byte alignment; C records retain their widest field
alignment and arrays inherit the element alignment. The questioned
max(8, alignment) therefore yields eight throughout this subset. Extended
scalars, vectors and over-aligned records are outside it. Source inspection of
`abi/r440-native-banks` retains the existing differential coverage for multiple
spills, mixed banks and partial records; its native execution was not replayed.
The existing C classification case separately passes 19 checks on each host,
with logs in `.scratch/r491-c-abi-review/` and `.scratch/r491-final-values/`,
and is included in the K31 controls above. This disposition adds no ABI rule
or claim of new exact-revision runtime acceptance.

K23 memoizes completed scalar module-binding values within one shared-folder
query. Recursive references reuse known, non-overflowing values, while unknown
and overflowing results retain the existing cycle and diagnostic paths. A new
public request starts with an empty map, preserving current semantic-table and
instance facts. The historical long timing chain is not repeated.

Four exact cases pass 89 checks in each of macOS debug and Linux release.
An eight-element image covers a small shared dependency graph, reordered
bindings, both target widths, wrapping arithmetic and omitted zero values.
Cycle, overflow, runtime-initializer and zero-divisor refusals retain their
ordered diagnostic categories and counts; four separate compile-only probes
also retain their complete before/after transcripts and status on both hosts.
An initial test assumed arithmetic datums had already become single literal
instructions; the corrected image test checks the actual folding boundary.
A test index-type error required clean single-worker builds on both hosts,
which passed. The Linux transcript helper then needed its scratch parent
created; only the missing comparisons were rerun. Selected cases have limits
of at most 30 seconds and direct probes ten seconds. Logs remain under
`.scratch/r491-fold-memo/` and `.scratch/r491-final-values/`.
No Landin assembler, linker, executable or giant image ran in this batch.
Exact-revision acceptance remains open.

K24 memoizes completed compound-shape extents within each public measurement
request. Recursive fields, arrays, aggregates and variant payloads share that
memo; complete shapes key the result, while unit, target and maximum remain
fixed for the request. Return or failure discards it, so later measurements
cannot reuse another target, limit, unit or incomplete result. An in-progress
entry refuses a represented cycle. Scalar measurements avoid memo allocation
because they have no descendant layout to reuse.

Four exact cases pass 111 checks in each of macOS debug and Linux release.
The shared graph has four levels and at most 512 represented bytes; its array
control reaches at most 1.5 KiB. Controls vary all layout policies, target width,
independent units with matching nominal positions, exact and insufficient limits,
arrays, empty alignment and variant placement. One malformed self edge pins the
cycle guard; the existing cost and template-selection cases stay green. Both
single-worker builds and the full document check pass. No large existing
measurement case or timing sample was replayed, and no assembler or generated
program runs. Logs are retained under `.scratch/r491-shape-cache/` and
`.scratch/r491-final-values/`. The earlier successful Linux transcript is kept
as `native-before-scalar.log`; the final one includes the scalar-allocation
adjustment. Exact-revision acceptance remains open.

K26 replaces per-routine retained-reference scans with one shared traversal.
Specialization marks its existing exposure array once before the incoming-proof
analysis, and final-body sharing excludes exposed routines with one traversal
of the immutable emission unit. The single-routine query delegates to the same
policy. Explicit/imported roots, scalar and aggregate function images, evidence
entries and runtime function addresses all remain observable; duplicate retained
references may visit the same routine repeatedly. Consumers own their marks and
refresh them after IR changes, so no persistent cache needs invalidation.

Seven exact cases pass 134 checks in each of macOS debug and Linux release.
The new small callback-count case covers both target widths and a later explicit
marker; existing evidence, all-mode costs and seven final-body exposure channels
preserve their decisions and code identities. Its first Mac run revealed two
test assumptions, corrected before the final run: C signatures require the
supported Linux target, and scalar function images retain two references to the
same routine. Both single-worker builds and the full document check pass.
Logs are under `.scratch/r491-exposure-traversal/` and
`.scratch/r491-final-values/`. No timing sweep, assembler, generated executable
or giant image is used. These are filtered development checks, not exact-revision
acceptance.

K27 replaces the per-instance nested eligibility recount with a pass-local
ordered map keyed by normalized template identity. One traversal accumulates
the same proven, non-exposed, static-entry predicate before any profitability
choice. Later decisions use those counts without scanning the unit again;
report order, forced/off modes and the existing cost/evidence rules are retained.

Three exact cases pass 70 checks on each of macOS debug and Linux release.
The new bounded case has three instances across two templates and checks both
target widths, with and without an exposed instance. It distinguishes independent
single-instance selection from cost refusal and retains indirect fallbacks.
Existing all-mode cost and recursive/unknown/wrong incoming-evidence controls
stay green. Both single-worker builds and full document checking pass. Logs are
under `.scratch/r491-template-counts/` and `.scratch/r491-final-values/`.
No timing sweep, large generated case, native assembler or generated executable
is used; exact-revision acceptance remains open. K20's duplicate row is also
aligned with the already implemented J95 disposition and its retained evidence.

K19 is disposed as an IR/source-contract distinction. The IR already exposes
metadata-free usize address operations: a plain slot or parameter transports
bits without promising a reached type, and integer comparison does not claim
source-pointer compatibility. Nine small IR constructions distinguish those
accepted operations from forged raw-load annotations, typed store/call
restoration, wrong-pointee arguments and raw Pointer_Address construction.
The latter all remain refused by the existing verifier. The API comment and
compiler reader document now state that boundary explicitly; no verifier policy
or source-language rule was changed.

Three exact cases pass 81 checks on each of macOS debug and Linux release.
The new case checks all nine constructions without target facts and with both
32/64-bit targets; existing pointer-origin controls and the source-level
pointer-comparison referent mismatch remain green. The first Mac build caught
an incorrect opcode name in the new test; after correction a required clean
single-worker build passed, as did the Linux developer build. Full document
checking passes. Logs are under `.scratch/r491-raw-pointees/` and
`.scratch/r491-final-values/`. No native assembler or generated program runs;
these bounded results do not replace exact-revision acceptance.

K34 moves informational responses after complete command-line validation.
Four retained direct CLI probes originally returned zero for invalid target,
build mode, override shape and empty root combined with help. Both help and
identity now retain those diagnostics, including the established target status
1 versus option-misuse status 2. Valid informational requests return before
source discovery, reads or compiler stages; source-dependent option typing is
still performed only for compilation, and J45's stage boundary is unchanged.

Five exact fake-host cases pass 301 checks in each of macOS debug and Linux
release. The new 48-request case covers both informational actions and argument
orders, invalid and duplicate deferred options, root/emit arity and valid
counterparts. Read and tool sentinels guard the early informational boundary;
all requests make zero artifact writes and zero tool calls. Both single-worker
builds and the full document check pass. The baseline and Linux logs are under
`.scratch/r491-informational-options/`, with Mac logs in
`.scratch/r491-final-values/`. No assembler or generated program is run for
this repair, and the filtered checks are not exact-revision acceptance.

K33 repairs a false build-report collision with an unused source-map path.
The report and artifact/source guards now share the actual destination list.
Both full debug information and caller coordinates reserve their emitted maps;
without either, that path may hold a build report. The reported inactive-product
case is not independent: non-executable Product_Path already equals the assembly
path. Existing map-refusal cases now explicitly request full debug information.

Four exact fake-host cases pass 194 checks in each of macOS debug and Linux
release, including 12 small combinations of emission mode, map producer and
path alias. Active map/source/assembly/executable collisions still precede every
write and tool request. Both single-worker builds and the full document check
pass. Logs are retained in `.scratch/r491-active-reports/` and
`.scratch/r491-final-values/`; no native assembler, generated executable or
filesystem overwrite experiment is part of this repair. These filtered checks
do not replace exact-revision acceptance.

K30 is now a confirmed and repaired GNU-toolchain finding. The retained minimal
C-callback source emitted 1,275 bytes of assembly before the change, with no
`.rept`, `.zero`, `.space`, `.fill` or `.comm`, one-byte alignment and five data
bytes. One foreground, 20-second-capped call to the pinned triplet-selected
GNU driver with `-pie` refused its PC32 `puts` address relocation. Imported
runtime function addresses now use `movq symbol@GOTPCREL(%rip)`; defined
routines retain `leaq`, and the existing quoted dollar-symbol and static
relocation rules stay intact. Two exact text cases pass eight checks on each
of macOS debug and Linux release, with both single-worker builds passing.

The 1,284-byte replacement was independently inspected and hash-checked before
its one foreground GNU assemble/link command, also capped at 20 seconds. It
links successfully; readelf identifies a PIE and the `puts` GLOB_DAT relocation.
Both exact files expand to less than 4 KiB. Existing compiler/assembler processes
were checked before each native run; no competing assembler, clang invocation,
fixture sweep, giant image, debugger or generated-program execution occurred.
The source, exact files, hashes and transcripts are retained under
`.scratch/r491-link-address/`, with text-test logs in
`.scratch/r491-final-values/`. These two bounded link commands are targeted
repair evidence, not all-profile or exact-revision acceptance.

K18 extends the existing shaped-carrier verifier to every call. Hidden results
and aggregate/array parameters of ordinary direct or function-value calls now
use the same storage-shape proof as erased dispatch. A plain usize, wrong array
extent or element, or unrelated nominal record does not satisfy that proof.
Nested fields and indexed aggregate elements remain valid address sources.
The C nominal rules and erased-self signature/adjacency rules remain separate.
The bounded hand-built IR controls exercise direct and indirect calls on both
target widths; existing erased and C controls and the core allocator fixture
also pass. Four exact selectors total 107 checks on each of macOS debug and
Linux release, with both single-worker builds passing. The fixture emits
assembly text only; the IR cases invoke no backend tool. No native Landin
assembler, executable, debugger, giant image or stress case ran. Evidence is
in `.scratch/r491-call-carriers/` and `.scratch/r491-final-values/`. This closes
the malformed-IR gap without claiming a demonstrated accepted-source overwrite;
exact-revision acceptance remains open.

J40's live example drift is reconciled with the existing grammar rather than
expanding it. The tour and prototype 1's critical-section sketch use unlabelled
`begin ... end`, retaining the same scope and defer boundary. The [1090] parity
row now names that exact supported form; labelled bare blocks remain outside
[1810]. A small positive fixture compiles the tour body and an ordinary binding
whose declared type was named `begin`; D225 subsequently reserves that word
and renames the fixture's type to `block_value`. It passes three checks on each of macOS
debug and Linux release with text-only emission. No compiler source changed,
so no rebuild or native Landin tool was needed. Both affected historical tails
remain byte-identical. Evidence is in `.scratch/r491-bare-block-examples/` and
`.scratch/r491-final-values/`; exact acceptance remains open.

J117 now follows D219's explicit endpoint-context decision. The review had not
established a contradiction in the former [1880] context list; that omission is
settled in the specification and tour rather than attributed to old wording.
A typed integer upper endpoint can now supply an untyped lower endpoint just
as the lower already supplied an upper literal. Two untyped bounds still use
i32, and two different typed bounds still disagree. The counted-prefix shape
from all four prototypes and the tour's sort header now compile, including
untyped arithmetic and conditional lower expressions. The original five-function
witness produced three endpoint reports plus three consequent body reports;
the final expanded positive fixture produces none. Separate overflow controls
retain L0300 for 256 and -1 against a u8 upper endpoint. Existing typed and
noninteger endpoint reports retain their exact transcripts. Four selectors
pass 20 checks on each of macOS debug and Linux release, and both single-worker
builds pass. D159's evaluation/loop lowering is unchanged. Positive evidence is
assembly text only; no native Landin assembler, runtime, debugger or stress
case ran. Evidence is in `.scratch/r491-range-context/` and
`.scratch/r491-final-values/`; exact acceptance remains open.

K16's API-seam ownership check now fulfills its documented identity promise.
Resolution and checking retain one immutable tree address per source, separate
from the dense node runs and reusable nominal-actual runs. `Covers` first checks
source membership, then exact object identity and node count. No address enters
source numbering, iteration order, target layout or emitted output. A tiny
three-compilation control rejects both different and identical source text
parsed into an alien tree, plus an absent source number, while accepting the
owned object. Existing scope and collected-formal controls stay green.
Three exact cases pass 29 checks on each of macOS debug and Linux release.
The first macOS build stopped on a duplicate `use type System.Address` warning;
removing the redundant clause and running the required clean single-worker
build succeeded. The Linux single-worker build also passes. No native Landin
assembler, generated executable, debugger or stress case ran. Evidence is in
`.scratch/r491-tree-identity/` and `.scratch/r491-final-values/`. This repairs a
contract check rather than claiming a previously demonstrated CLI failure;
exact acceptance remains open.

K25's unused specialization projection is now eligible for ordinary backward
removal. `Function_Address` is already classified as having no read, write,
call, trap, control or adjacency effect; its signature is type metadata, not
an observable operation. Only dead instructions are dropped. Live function
values keep their signatures, and the numeric folder's plain-value restriction
is unchanged. A bounded IR case checks the direct-call projection, none-mode
retention and a callback still passed to an indirect caller on both target
widths. Together with existing effect and mixed-dispatch controls, three exact
cases pass 39 checks on each of macOS debug and Linux release. Both builds use
one worker. No assembly emission, native Landin tool, executable, debugger or
stress case ran. Evidence is in `.scratch/r491-dead-function-address/` and
`.scratch/r491-final-values/`; exact-revision acceptance remains open.

J113 is repaired under the explicit new D218 scope decision. Ordinary local
written types now resolve before declaration, matching the incoming scope
already used by initializers and D185 condition types. Names nested in pointer,
fixed-array and generic element types retain the enclosing identities; the
new local still shadows those identities in following statements. Collected
module/signature scopes are unchanged. The prototype-3-derived list-element
fixture checks generic substitution as well as the source lookup rule.
Seven exact selectors pass 29 checks on each of macOS debug and Linux release,
including both unknown-type and self-initializer refusals, a later shadowed-type
refusal, and existing condition/duplicate/parameter controls. These two unknown
uses are separate fixtures because a value-name resolution error stops the
pipeline before the checker's unknown-type report; their final expected codes
are each L0201. Fixture preparation also corrected the non-language module
`fixed` declaration spelling to a genuine fixed signature formal. All source
cases are tiny; the sole array has two elements. Both single-worker builds
pass. Positive checks emit text only, and no native Landin assembler, runtime,
debugger, stress or giant-image check ran. Evidence is retained in
`.scratch/r491-local-type-scope/` and `.scratch/r491-final-values/`.
Exact acceptance remains open.

M4/M16 live-example reconciliation preserves all four prototypes' historical
finding sections and the tour's dropped-design section byte for byte. Live
formal names and associated type labels now obey [1760]; provider/log/world
names remain distinct from their runtime parameters. The tour's sort and paint
clients request the mutable views their callees require. Initialized values
precede object publication, and the three-acquisition undo example returns
three byte-buffer owners instead of forging generic capacity slices. Its
`make_widget` companion returns one explicitly constructed erased value.
Prototype 2 supplies a complete initial node before allocation. Prototype 4's
reader keeps one `io.file` because `shut` consumes the whole reader; W3's old
atom/integer-union discussion remains untouched. Prototype 3's explicitly
historical raw/slice sketches remain comparison evidence, with saturated
static argument lists. Active affine-value references point to this roadmap.
The reported partial `pair` example is absent from the current tour; [1290]
still explicitly requires a saturated static list.

`check.py` now lexes live Landin fences while excluding the three historical
section boundaries. The previous documents fail at 62 live fences; the revised
text passes, and eight tiny controls cover names, comments, literals and those
exclusions. Exact copies of `new_buffers` and `make_widget` are held to one
positive fixture that instantiates both through an arena provider. The caller
uses [0190]'s explicit `usize(2)` for D138's independently typed generic actual;
plain `2` and a non-language `2usize` suffix were refused during fixture
preparation. The final exact fixture passes three checks on each of macOS
debug and Linux release and emits text only. No runtime, assembler, debugger,
giant array or stress test ran. Evidence is in
`.scratch/r491-document-examples/` and `.scratch/r491-final-values/`.
The prototypes retain documented omissions and future constructs; this is not
a claim that they are standalone compiler inputs. Exact acceptance remains open.

M8's named decision-register drift is reconciled against the current tour,
enabled grammar, parser/checker and recorded R4.40 closure. The measurement
production still admits a direct identifier and a parenthesized array literal;
[0370] already assigns slice length its runtime meaning, so D14/D31 no longer
call slices deferred. Variant layout cites [0680]/[0690], matching cites
[1210], and the selected-index example is attributed to [1820] in the
specification. D106 keeps the current `variant-return-unassigned` pin; it no
longer masquerades as D74's historical value-deferral witness. D203–D207
point to R4.40's recorded exact historical input and separately retain R4.91
acceptance. `check.py` compares active-owner claims in evidence paragraphs
with roadmap status. This is editorial reconciliation, with no compiler or
semantic change and no rerun of historical generator or ABI acceptance.

C5 error-inference storage is moved off the host stack. The finalizer owns
all three dense Boolean matrices and four linear flag/signature arrays
through one limited controlled object. Allocations occur after the empty-graph
exit; finalization releases every successful allocation when a later allocation
fails, an inference pass suspends or an exception leaves the procedure. The
existing atom propagation, recursive closure, deferred recovery and completion
algorithm is retained. The graph still stores two signature-by-declaration
matrices and one signature-by-signature matrix; this repair makes no sparse
storage or improved asymptotic complexity claim. Both single-worker builds and
six exact selectors pass, with 33 checks in each of macOS debug and Linux
release. Controls cover recovery-triggered deduction, concrete and inferred
generic error sets, erased recovery and public/unhandled-error refusals.
No large generated case, allocation-failure injection, stack-limit experiment,
assembler, generated executable or debugger ran. Evidence is retained in
`.scratch/r491-error-inference-storage/` and `.scratch/r491-final-values/`.
Exact-revision acceptance remains open.

J15's `noreturn` facet now follows [1830]'s named-refusal contract.
Function bodies, function types and foreign signatures receive one L0010
with [0890] and the existing R6.70 owner. Recovery retains the following
declaration, and `noreturn` remains usable as an ordinary type or binding
name. Four exact selectors pass 44 checks in each of macOS debug and Linux
release; both single-worker builds and the three fixture inventories pass.
The positive fixture emits assembly text only. No native assembly, generated
executable, debugger or giant image ran. Evidence is retained in
`.scratch/r491-noreturn/` and `.scratch/r491-final-values/`. This does not
enable nonreturning functions. The subsequent J15 work below completes its
volatile and shared-name refusal facets; exact-revision acceptance remains open.

J15's final batch recognizes only the type-position volatile ptr shape, leaving
ordinary volatile aliases and parameters legal. Fully read pointer types do
not trigger generic refusal resynchronization: fields, initializers and the
next declaration remain in hand. Shared bindings, fields, parameters and
returns consume their additional names once before parsing the remaining
annotation or initializer for recovery. Atom declaration lists stay enabled.
The applicability register and R7.20 now distinguish those two [0100] facets.

Ten shared-declaration and six volatile contexts pin one L0010, its primary
wording, construct/work notes and the following declaration. With existing
noreturn, atom-list and contextual-name controls plus both new negative fixtures
and the ordinary-volatile positive fixture, eight selectors pass 220 assertions
on each of macOS debug and pinned Linux release. Both single-worker builds
pass. Evidence is in `.scratch/r491-named-refusals/` and matching final-values
logs. The positive cases emit text only; no assembler, generated program,
debugger or broad parser campaign ran.

J45, J105 and J116 are disposed against the current source and retained
review evidence. The driver guarantees a reported failure for invalid
configuration, not a complete source diagnosis under it. J105's old cascade
is superseded by the recorded final-value-prefix refusal from 7250d298.
For J116, [1950] says a well-typed element index must be below the length;
D148's `slices.bounds-known` row cites index and permission witnesses, not
range-endpoint rejection. The slice path has no static endpoint evaluator,
but D187 explicitly names its removable runtime edge. This establishes no
violation of the current known-index rule and does not change acceptance,
runtime checks, or unchecked semantics. These are source-backed dispositions;
no new runtime, assembler or stress reproduction was needed.

J48's static-selection collision question was resolved by D221: distinct
declaring concepts make a selected name ambiguous, while a diamond visits its
shared ancestor once. The focused implementation and evidence are recorded above.
J2 and K12 were semantic questions at intake; D222 and D223 now record their
approved contracts and implementation. The verifier, optimization, build-identity
and ABI items above remain owned by the corresponding later repair groups.
The review's passing backend observations and inconclusive long-routine/stack
scaling notes are coverage limits, not additional confirmed defects or reasons
to replay stress tests. Intake is complete; implementation and exact acceptance
remain open.

Resource limits for further work are mandatory: check for existing `clang` or
`cc1as` processes before execution and stop to report their PIDs/full commands
if any exist before a new run. Do not run blanket assembler/linker coverage.
Parallel assembler work is authorized only inside the existing capped
acceptance jobs as specified below. Never assemble `positive/module-array-mixed-repetition`,
`positive/module-array-repetition`, billion-element sources or their generated
assembly. Before any explicit `clang -c`, inspect that exact file's `.rept`,
`.zero`, `.space`, `.fill` and `.comm` expansion; skip unbounded or over-64-MiB
images. For new explicit reproductions, at most one foreground clang process may run, with a timeout of at most
30 seconds and one explicitly named, inspected input. No broad clang loops,
unbounded stress/fuzz loops or giant generated cases are authorized. Reuse
completed coverage; use short explicit timeouts and low concurrency for new
bounded checks. Required exact acceptance is not waived by these limits.

Implementation proceeds in four reviewable batches: finish the initial
context/recovery regressions; repair origin/consume/output/build preservation;
repair remaining frontend/backend/host boundaries and bounded scaling; then
reconcile documentation, harness and CI coverage. Each batch keeps its focused
positive and refusal controls. Confirmed defects and unresolved dispositions
above remain owned here until repaired or explicitly transferred with reasons.

Retained acceptance of `66927e93` is historical evidence and does not approve
these repairs. Earlier review constraints excluded new mutation-based probing
and debugger sessions. The maintainer now explicitly authorizes the eight
existing acceptance jobs, including runtime/ABI and GDB checks, concurrently
on the capped Linux runner and stopping on failure. This adds no new fuzz or
assembler campaign and never authorizes assembling the giant-image fixtures.
Required debugger acceptance is not waived; it is included in that authorized
gate. If the 100 GiB cap is insufficient, report the affected job and memory
evidence before changing the limit.

At that batch boundary, closure still required live activation of the
SourceHut publisher and expanded runtime/profile and exact-revision acceptance
evidence, including required debugger coverage. The containing revision's
closure and delivery binding below supersedes that remaining-work account. M6 is closed by maintainer disposition with the
historical evidence gap explicitly retained. M5 is disposed: leave the font
files for now.
Broader mutation coverage remains absent under the user's constraint;
generator-only checks do not supply it. The
retained maintenance and cost observations (M12/K28, m14, m23, m28/m29) do not
establish additional wrong-code repairs and authorize no stress or giant-image
replay. Every review row keeps its individual disposition and evidence limits.

Delivery inspection after `ceb687c2` confirms canonical main remains
`3a3caca4` and canonical `r491` contains the integrated repair revision.
SourceHut jobs 1888097 (Pages) and 1888098 (GitHub mirror) both report success.
The Pages task is a non-main no-publication path, not live publisher evidence.
At inspection, the running-job query returned no jobs and the canonical lock
ref was absent. These are point-in-time observations, not proof of the Pages
secret's write permission or assurance that no older/manual publisher can run.
The native CI guide now also records partial-domain failure and retained-lock
recovery instead of promising that failure leaves the previous site intact.

The remaining delivery sequence is concrete:

| Step | Required result | Current boundary |
| --- | --- | --- |
| Reconcile acceptance execution | Preserve giant-image cases as source/seam evidence while running the eight existing jobs concurrently under aggregate memory containment. The changed policy cannot reuse an existing policy identity. | The maintainer activated the Docker cap, verified at the kernel boundary, and explicitly authorized the existing capped acceptance jobs. The positive-fixture path emits assembly text only; the native execution path selects runtime and ABI classes. No acceptance waiver is inferred. |
| Historical dispositions settled | M5 retains the font files for now. The maintainer closes M6 with the original R1/R2/R3 native runs explicitly unverifiable and their source witnesses preserved. | No history rewrite or retrospective acceptance claim is authorized. New acceptance proves only its current revision and cannot recover a historical run. |
| Accept and deliver the candidate | Complete the agreed exact-revision native gate, verify its export, and bind approval and canonical promotion to that revision. Verify the SourceHut identity's canonical lock-write permission and retire older publishers before live activation; inspect both domain outcomes. | Branch push and mirror success do not supply acceptance. The SourceHut identity passed live lock creation/release in job 1888216; the maintainer confirms no other publishers. Approval, promotion and publication remain unperformed. |

The maintainer clarified that the resource restrictions address the incident
in which session-launched work consumed over 60 GB and crashed the Mac, and
allows adjusting execution limits to prevent a recurrence. This is permission
to prepare contained validation; subsequent instructions explicitly authorize
the existing parallel gate under the 100 GiB Docker cap.
M5 is disposed by the separate instruction to leave the font files for now.
M6 is closed by maintainer disposition; its missing historical evidence remains
explicitly distinct from current acceptance.

The acceptance runner now runs eight isolated jobs concurrently, explicitly
builds with eight workers per job and holds one of eight host-wide slots
across each job. The policy requires an aggregate cgroup v2 memory cap of at
most 100 GiB with no swap,
following the maintainer's explicit choice of that cap for the Docker host.
Initialization refuses missing/unlimited/excessive limits before native tool
probes; verified limits are bound into environment provenance. Each command
has a two-hour outer process-group deadline; narrower assembler and harness
limits are still required where applicable. OOM kill accounting changes fail
the job even if a command reports success. No required job is removed, and
the changed policy identity cannot reuse acceptance of an older revision.

Initial read-only host inspection found no running clang/cc1as, but the runner's
cgroup had `memory.max=max`, `memory.swap.max=max` and was not writable
by its account. Administrator deployment supplied a dedicated capped runner
container before the new preflight passed. Do not lower an unrelated
shared workload's limit or substitute a per-process limit for aggregate
containment. Tiny Python controls exercise refusal, timeout, inherited-pipe
cleanup, concurrency bounds and OOM-accounting failure; no giant allocation,
compiler corpus, assembler sweep or debugger session validates these controls.
Source/IR-only treatment of the giant fixtures remains mandatory. The exact
native execution and remaining coverage decisions still precede acceptance.
The maintainer identified the existing Docker deployment notes at the main
worktree's `.scratch/ci-hosts/`. A tracked Compose override now supplies the
runner-only memory and memory-plus-swap settings, preserving the existing
services, image and named volumes. Its documented application recreates only
an idle runner and verifies the kernel values afterward. The maintainer set
up Docker manually and then redeployed with the requested 32 GiB limit. A
follow-up kernel read confirms `memory.max=34359738368`, `memory.swap.max=0`
and zero OOM events. The work volume and retained acceptance directory remain
present. Git installed in the earlier home-directory location disappeared on
recreation, so user-tool provisioning and provenance now select the persistent
`~/work/.ci-tools` directory. Debian Git 2.47.3 is restored there through the
bounded user-tool setup script; its package identity and hash are retained.
No retained acceptance evidence is moved or rewritten.

Containment development evidence: all 66 CI tooling cases pass on Linux;
the Mac controls pass with two Linux-only cases skipped. Focused
controls also cover a slow observational output sink, font-probe timeout
retention, compiler-style separate process-group cleanup, and approval refusal
for altered memory provenance. The controller
streams fixed-size output chunks instead of accumulating an unbounded line
on the Mac. `check.py` holds the Compose override to the policy's exact memory
and swap values. The real host preflight first refused its uncapped cgroup
before any compiler tool probe, then passed containment after the maintainer's
redeployment. Logs are retained in
`.scratch/r491-resource-containment/`. These checks establish runner behavior,
not kernel OOM experiments, compiler acceptance or live deployment.

Historical acceptance timing establishes the required outer deadline: in
retained run `20260911T171028Z-93919134a490`, debug suite execution took
4,817 seconds, debug quality 5,229 seconds and debug GDB 2,808 seconds.
The initial 30-minute command allowance was therefore insufficient for the
existing required checks and is corrected to two hours. This changes only
the wall-clock allowance without changing the required outcomes.

The maintainer subsequently selected 100 GiB with zero swap and requested
parallel execution. The image was rebuilt with Git and the idle runner
recreated. A fresh SSH inspection confirms `memory.max=107374182400`,
`memory.swap.max=0`, zero OOM events and no compiler/tool processes. The
previous serial run `20260914T133931Z-28587a11fed4` on `16897158` was
intentionally interrupted to change policy: its explicit debug build passed,
but its suite had not completed. It supplies neither a compiler failure nor
acceptance, and no OOM was observed. Its retained attempt remains intact.
The parallel policy uses eight jobs and eight workers per compiler build,
with host-wide slots and durable peer cancellation on failure. Giant-image
assembly remains forbidden. New exact acceptance must use the newly
committed policy; it cannot resume the superseded serial run.


The first parallel attempt, `20260914T140244Z-bd1a2e2785e4` on `59d4fea2`,
failed its existing binding keyword agreement test: thirteen newly reserved
words were missing from the generator's keyword table. The generator now
matches the normative production, and the ordinary document checker enforces
that agreement without Clang. Cancellation stopped all seven peer jobs;
post-run inspection found no surviving compiler/tool processes. Peak cgroup
memory was 10.25 GiB with zero limit hits or OOM events. The cancelled builds
also exposed a source-inventory defect: generated `compiler/ada/.build-locks`
files were counted as source changes. That exact generated directory is now
excluded from live source identity and refused in committed input archives;
a regression still detects edits to actual source. At the maintainer's request,
build concurrency rises from four to eight workers per job (at most 48 across
the six compiler jobs). The aggregate 100 GiB cap and failure cancellation stay
in force. This failed attempt is retained and cannot supply acceptance.


The next attempt, `20260914T140751Z-b887724f6583` on `5f203873`, reached
native debugging and failed optimized generic stepping: after the line-51
call, GDB stopped on declaration line 35. Retained assembly shows all four
fall-through break jumps correctly elided, followed by an implicit result
load and return incorrectly attributed to the function declaration. Lowering
now assigns that implicit block-body return to the closing source token. The
native oracle accepts the closing line alongside surviving break lines and
still refuses the declaration; machine optimization is preserved. A fake-host
assembly regression and transcript control pin the distinction. Cancellation
again stopped every peer; peak memory was 16.18 GiB with zero limit/OOM events.
This failed attempt remains retained and supplies no acceptance.


Attempt `20260914T141532Z-fb7466f7d5e5` on `e18f8175` passed bindings and
documents, then correctly rejected `core.region.new_region` under D222 when
release debugging reached the hosted workload. A call to `vec.new_list` has an
independent result under its written no-`from` signature, even when its body
creates an empty descriptor. The region constructor now carries an explicit
empty ledger variant; the first recorded payload materializes the list using
the same parent allocator. This preserves the public constructor and origin
rule without body inference or an untracked cast. Release handles both ledger
arms and resets the ledger to empty. The existing hosted-memory cases cover
first-allocation/ledger failure, nested finite regions and release accounting.
Peak cgroup memory was 17.62 GiB with zero limit/OOM events. Cancelled runtime
harnesses left `compiler/ada/GNAT-TEMP-001361.TMP`, explaining their source
inventory failures; no tracked source changed, and the archive rules are not
broadened to hide arbitrary temporary files. The failed attempt is retained.


Attempt `20260914T143510Z-0c8df5444802` on `2d30e1a3` passed bindings,
documents and the full release debugger job. The release suite completed
197,313 checks across 710 cases, with five failing cases. The failure batch
owns discarded/statement recovery blocks incorrectly requiring a value,
reference-transport fixtures missing the now-required retention contracts,
variadic-tail recovery producing phantom outer declarations, a frame escape
report pointing to a parameter instead of its frame witness, stale diagnostic
code counts, and the recorded IR corpus. Flow now carries whether a result is
consumed; used recovery expressions still require a value on fallthrough.
Reference facts retain a bounded declaration witness for frame diagnostics.
The invalid variadic tail is consumed as parameters of its own list. Unknown
type spellings keep their resolver-owned L0201; already-invalid range/array
uses do not require redundant downstream diagnostics. Transport helpers mark
retained replacements `escaping`; replacement backing is independent while
local descriptors and runtime value/dispatch assertions remain exercised.
No language-origin rule is relaxed. Three existing I/O assignments now return
their previous pointer from expected-failure recovery instead of supplying no
value. The regenerated corpus adds 17 R4.91 positive fixtures and preserves
all 233 previous entries. Its nine changed entries reflect control-block
ordering, explicit pointee metadata, the added exact-intermediate arithmetic
cases, and aggregate payload copies through their storage addresses. The
layout corpus is unchanged. Focused release checks pass for all previously
failing source verdicts, parser recovery and diagnostic codes, and the I/O,
generic carrier and erased argument runtime profiles. The failed attempt
remains retained; cancellation stopped its peers, with a 20.60 GiB peak and
no memory-limit or OOM events.

Attempt `20260914T152118Z-c6d82106db12` on `56dd8404` is superseded to include
the maintainer's M6 disposition in the exact committed acceptance candidate.
Its partial evidence is retained; this deliberate restart does not indicate
a compiler failure. The recovery/parser/frame-witness regressions and the
reviewed lowering corpus also pass focused Linux debug checks before restart.


Attempt `20260914T152616Z-f281722b7e6a` on `53b42203` passed bindings,
documents, release debugger validation (666.2 seconds) and release quality
validation (1,180.6 seconds). The release compiler suite completed 197,395
checks with 709 of 710 cases passing; all five previously failing cases pass.
The remaining bounded `large loop frames stay off the host stack` regression
raised `STORAGE_ERROR`: recursive reference-checker visits still retained
whole-program snapshots on the host stack. Scoped limited-controlled owners
now keep those snapshots on the heap and free them on normal or exceptional
scope exit. The fixture's 1,220 declarations and four nested loops are unchanged;
no larger source, assembler sweep or stack-limit increase is introduced.
All 108 checker cases pass in each Linux debug and release build (2,149 checks
per build), including the unchanged large-loop case and reference recovery,
cleanup, alias and sink controls. The exact frame-witness diagnostic also
passes in both modes. Peer jobs stopped on the failure. Peak cgroup memory was 26.72 GiB, with no
memory-limit or OOM events; the failed evidence remains retained.

SourceHut permission preflight job 1888216 passed on `53b42203` using the
existing Pages SSH identity. It created canonical `ci/publication-lock` owner
`02744221abf722e35729c0581ead11f60bfe3f13` and released it with the exact lease;
a following canonical-ref read confirmed the lock absent. It uploaded no site.
The maintainer confirms that only the repository's SourceHut Pages job
publishes, and the running-job query was empty before preflight. This resolves
the identity-permission and other-publisher prerequisites. Approval, canonical
promotion and the resulting two-domain publication still require successful
exact-revision acceptance and normal delivery.

R5-readiness intake (review base `bd69b2a1`, reproduction base `258d734b`):
the inherited review used older macOS binaries for its resource probes.
Fresh pinned Linux debug builds reproduce the named-argument order bug,
callee-expression internal defects and binary-chain resource exhaustion.
This intake is the durable disposition of that review, including merged and
refuted observations; the scratch report is supporting material only.

| Finding | Disposition and owner |
| --- | --- |
| CHK-A-1 | R4.91-F5 repairs concept-facing labels, including the explicitly supplied receiver, and stores runtime match/position facts per routine instance. Checking, flow, references and lowering read the active view. Both instantiation orders have six-profile runtime fixtures; a table seam checks nested view restoration and conflicting writes. |
| CHK-15600-1 | R4.91-F6 scans the callee before arguments in ordinary and tried calls. Two negative fixtures and a six-profile runtime fixture cover undeclared/unhandled errors, inferred and declared propagation, local recovery and generic calls inside a callee. Discover_Generic_Calls already walks the callee through child slots. Include_Expression computes the atom value being failed, not evaluation effects; recursively unioning a callee's atoms there would be incorrect. Driver controls require ordinary diagnostics and no writes/tools. |
| CHK-FE-1, LOW-2 | R4.91-F7 bounds binary spines at the existing 128-operator implementation limit, continues reading the tail and preserves following declarations. Parser controls cover the last accepted sum, first refused sum and a longer logical chain; driver controls pin L0111 before any emission effect. |
| CHK-R491-2, CHK-REF-2, CHK-A-2, LOW-4 | R4.91-F8 heap-owns the references checker's base origin and alias tables, removes Type_At's declaration-sized stack bitmap, settles ordinary alias runs iteratively, and heap-owns the IR pointer-provenance input/output tables. The existing 1,220-declaration/four-loop control remains unchanged. A 4,000-link alias regression and a 12-guarded-cleanup runtime regression cover the new failures. These repairs do not claim every compiler scratch table is heap-owned. |
| LOW-1 | Confirmed expansion cost; the bounded verifier failure it exposed is repaired by F8. Assembly-only probes with 4, 8 and 12 guarded cleanups produced 5,192, 83,232 and 1,383,035 bytes after repair. R5.20 owns sharing equivalent cleanup continuations without changing pop-before-run semantics. This optimization is deferred; no arbitrary small cleanup-count refusal is introduced. |
| CHK-FLOW-1, CHK-FE-2, CHK-FE-3 | Retain as resource limitations, not a claim of unlimited input or reliably recoverable host-stack overflow. Syntax bounds do not bound declaration dependencies. The reviewed macOS raw traceback/exit thresholds are not current Linux evidence. R5.10 owns native-host exhaustion characterization; R5.20 owns remaining flow snapshots, folding dependency walks and IR scratch storage. No host stack limit is raised to supply R4 evidence. |
| CHK-REF-3 | Retain exceptional-exit leakage of raw loop-transfer states as a known limitation. Normal-path release and controlled snapshot/base-table ownership remain covered. R5.20 owns controlled transfer-state cleanup; the R4 closure claim is limited to the repaired owners, not every allocation in the checker. |
| CHK-H-1 | Add exact output expectations to hosted-io-reads-parser-input (merged OK newline) and derived-containers (empty stdout and stderr). Status-only fixtures remain legitimate where status is their stated oracle. |
| CHK-H-2 | BUSY (75) leaves peers running and prevents finalization/export without creating cancellation. A controller test resumes the same initialized request; real failed jobs still cancel peers. |
| CHK-H-3 | Add negative/r440-native-renamed-entry to the normative entry.point evidence row and regenerate its reading copy. |
| CHK-R491-3 | Reconcile superseded parser, primary-expression and publication-permission sentences with their later evidence. |
| R520-1, R520-4, R520-6, R520-7, BE-2 | Explicit R5.20 inputs: ABI capability contracts, a second 64-bit target description, driver backend dispatch and shared hosted helper identities. Current SysV guards are retained until another ABI is actually implemented. |
| R520-2, R520-3 | R5.20 owns the target-fact/specification boundary; R5.30 owns Darwin core/c, binding-generator ABI support and native linker arguments. R5.40 owns the Mach-O debug identity counterpart. The current Linux-only guard is intentional. |
| CHK-R491-4, R520-5, CHK-15600-2 | One duplicated wording finding: R5.20 owns replacing ELF-specific link-name prose and settling Darwin symbol-prefix mapping with fixtures. |
| BE-1 | Retain the inferred large-data/RIP-relative placement limitation under R5.20's backend preflight audit. No multi-GiB object was assembled or linked to validate it. Large-image acceptance is not claimed by this closure. |
| LOW-3, BE-3 | Retain unmeasured simplification, atom-code and symbol-allocation scaling observations under R5.20. Correct baseline code generation remains the R4 gate; competitive optimization is outside it. |
| CHK-A-3 | Refuted by the original adversarial verification; no implementation change. |
| CHK-R491-1 | Duplicate of the existing exact-revision acceptance gate below. Neither the review nor filtered development tests close it. |

F5-F8 Linux debug development checks pass: all 110 checking cases (2,158
checks), all 52 driver cases (1,822 checks), both named-argument orders and
the separate receiver-label control in six profiles, the two callee refusals,
and six-profile callee propagation/recovery. The 12-cleanup runtime passes
all four standard profiles. The parser suite passes 42 cases and 6,387 checks;
its focused call/binary-depth control passes 18 checks. Fresh assembly-only
resource probes accept both 1,000- and 4,000-link alias chains and the 4/8/12
cleanup sources; no probe assembly was assembled. Full document checks pass,
and the 73 CI Python tests complete with two explicit host-specific skips.
Linux release passes the same 110 checking and 52 driver cases, the 18-check
parser boundary control, the two six-profile named-argument order fixtures,
the callee refusal and six-profile runtime controls, and the four-profile
cleanup regression. Hosted I/O passes its exact output oracle in four profiles;
the complete container derivative passes its empty-output oracle in all six.
The independent receiver-label fixture is also checked in both modes.
Verified local site rendering preserves every source word. This is development
evidence; the unchanged acceptance policy must pass on the committed repair
candidate before approval or promotion.
The original coverage gaps are not represented as completed review: fixes
trace their semantic consumers, while the complete suites, IR verifier,
quality and native debugger jobs supply the existing mechanical backstops.

Attempt `20260914T203309Z-d391071bcd34` on `5dba96b3` failed debug
quality validation before the complete derived-parser workload emitted IR.
The new iterative settlement path queried type-declaration syntax while
settling a forward atom. Debug's existing syntax precondition caught that
invalid query; the repair restricts it to actual type declarations. The
4,000-alias checker control now includes a generic field reaching a forward
atom alias, preserving that distinction in both modes. Peer jobs were
cancelled, and the failed attempt remains retained. It supplies no acceptance.

Closure candidate and delivery binding: all readiness findings above have
an explicit repair, retained limitation, refutation or R5 owner. The forward
atom follow-up passes its expanded checker control and the complete derived
parser's six runtime profiles in both debug and release compiler builds.
Earlier statements that exact acceptance was open describe their individual
development batches and are superseded only by this containing revision's
completed acceptance record, never by a filtered transcript.

As for R4.90, the completion status is prepared in the candidate so the gate
validates the final documents with the compiler. At candidate preparation,
canonical eight-job native acceptance, verified durable export, administrative
approval, canonical promotion and guarded publication verification are pending
delivery steps. The exact containing revision's annotated
`ci/accepted/FULL_COMMIT` tag and native bundle bind its source/tree/policy,
all eight successful jobs and retained artifacts. Canonical Git and guarded
Pages job records establish delivery. No later bookkeeping commit substitutes
for that evidence. R5 remains planned until this closure is delivered.

Exit evidence: focused regressions pass in both compiler build modes, including
no output/tool invocation for rejected source; full document checks and compiler
suites pass; every older finding above has a recorded disposition; and the
committed repair revision completes canonical eight-job native acceptance,
verified export and normal delivery binding. Filtered runs do not close it.

### R4 gate

Status: complete

R4.90's accepted closure remains recorded above. R4.91 completes the reviewed
repairs with the containing revision's exact native acceptance and delivery
binding. The completion status in this candidate becomes authoritative only
with that revision's annotated approval and canonical promotion; development
runs cannot close the phase. R5.10 and R5.20 became dependency-ready at this
closure; their current status is recorded below. Retained resource limits and
explicitly transferred R5 work are recorded in the readiness intake, not
claimed repaired by this gate.

- Every applicable hosted construct under the current normative specification
  is implemented on Linux x86-64.
- Complete derived prototypes 2, 3 and 4 run with useful debugging.
- Correct baseline code generation is measured; competitive optimization is
  not a gate.

## R5 — Native macOS arm64 parity

R5 proves target isolation on the actual development platform before the
freestanding backend begins.

### R5.10 — Establish the native macOS compiler environment

Status: complete
Depends on: R0.70, R4.91

Pin or bound the macOS arm64 GNAT/GPRbuild, Apple SDK, assembler, linker and
debugger environment. Build and run `refine` natively; the Linux container is
not accepted as Darwin evidence.

Exit evidence: provider-neutral commands build `refine` and run its harness on
native macOS arm64 with captured tool versions.

`scripts/macos.sh --output DIRECTORY` establishes the native host through
`environments/macos-arm64/policy.json`: the existing Ada pins, a bounded macOS
major, and exact Apple SDK, Clang/assembler, linker and LLDB identities.
It assembles, links and executes a native arm64 smoke program, stops and
resumes it with LLDB, and builds `refine` and runs the unfiltered harness in
both compiler modes. The absent Linux driver remains the harness's explicit
runtime-case failure; every other case must pass and every runtime failure
must identify that missing driver. This does not close Darwin code generation
or source debugging. Commands, versions, source/tool/artifact hashes, build
configuration, probe inputs and both output streams are retained per run.

The readiness intake's CHK-FLOW-1, CHK-FE-2 and CHK-FE-3 are characterized by
bounded native probes for type aliases, module-value dependencies and nested
flow states at chain lengths or local counts of 8, 256, 1024 and 4096. Flow
has a scalar control and a 64-field record variant to exercise both dimensions
of its declaration-by-field matrix. The inherited host stack
limit is recorded and never raised; CPU and wall limits distinguish stopped
work from reported exhaustion, raw exceptions and language diagnostics.
The small controls must pass. Larger results describe only those samples;
remaining storage and dependency-walk repairs remain R5.20 work.

The first native debug harness run exposed a host-dependent IR ordering in
concrete evidence traversal capture: two `Addressed_Storage` calls in one Ada
argument list emitted address instructions in different orders on Darwin and
Linux. Both native compiler modes reproduced the four golden differences.
The calls now elaborate separately in the existing recorded destination/source
address order; source-place evaluation and the copy's operands are unchanged.
The existing complete IR corpus comparison pins this repair without changing
the golden. The wider target-contract audit remains R5.20.

Exit evidence: clean native debug and release builds pass the environment
command, including Apple assembly/link/execution and LLDB stop/resume. Each
unfiltered harness run reports 712 cases, 711 passed and 195410 checks, with
only the expected Linux runtime-driver refusal. Every message in that failed
case is checked; the complete IR golden now matches on both hosts and in both
compiler modes. Supplemental Linux IR checks and all four profiles of
`runtime/for-iterable-evidence-traversal` pass in both modes, with executable
outputs on the guest filesystem under the existing virtiofs identity limit.
The eight environment-oracle tests and full document checks pass.

The final native probes accept the alias chains, module-value chains and
scalar flow cases through 4096 in both modes. The 64-field flow variant accepts
8, 256 and 1024 locals, then reports host exhaustion with exit 71 at 4096 in
both modes. The inherited stack limits are 8372224 bytes soft and 67092480
bytes hard; neither was raised. These are bounded observations, not maximum
input sizes or a general promise of recoverable exhaustion. R5.20 retains the
storage and dependency-walk work. `environments/macos-arm64/validation.json`
records the native tool identities, verified evidence hashes, matching tested
input inventory and per-mode results; its evidence paths retain the full logs
and probe sources. This closes the compiler environment item, not R5 parity
or a new exact-revision Linux approval.

### R5.20 — Isolate target contracts

Status: complete
Depends on: R4.91, R0.60

Refine target descriptions, ABI queries, assembly emission and debug emission
so Darwin support does not enter parsing, checking or target-neutral IR
semantics. The R4.91 readiness intake above owns the explicit handoff: backend
dispatch, C ABI capability distinctions and a second 64-bit description,
shared hosted helper identities, link-symbol spelling, and the core/c and
binding-generator fact boundary. Its retained resource and scaling findings
are assessed here with bounded controls; any deferred repair keeps an explicit
disposition rather than turning into an unstated cross-target guarantee.

Exit evidence: target-independent stage fixtures are byte-for-byte or
canonically equal across hosts where specified; target differences are
localized and reviewed.

Validation/process agreement for R5/R6: use native Mac compiler-host checks
and focused native Linux development slots. Routine promotion uses the
committed five-job policy: debug host checks, the complete release suite and
native identity, release quality, bindings, and documents/tooling. Add release
GDB only for substantial debugging regression risk. Full matrices in both
compiler modes are reserved for major milestones, including R5.50 and R6.100;
select and commit milestone scope before their closure candidates. Policy and
approval schemas bind the scope and every required job; historical full
approvals retain their meaning. No Linux containers or Linux workload matrices
belong in the Mac development loop. Do not repeat broad local gates before a
final promotion candidate when focused evidence already resolves the change.

The host selector omits native target workload emission/execution, retaining
compiler units, diagnostics and the complete IR golden. The Python lexical
check reuses spelling membership within one file, with no persistent answers
across grammar edits and no removed corpus coverage. `docs/process.md` records
the measured costs and operating workflow. This item also owns evaluation of
bounded per-workload parallelism and a dependency graph for immutable compiler
and workload artifacts, preserving failure, identity and resource controls.
Nix CI is deferred by the maintainer; the existing shell remains supplemental.

Implementation and reviewed boundaries:

- `Landin.Targets.Darwin_Arm64` describes little-endian 64-bit pointers,
  pointer alignment 8, stack/scalar maximum alignment 16, `arm64` architecture
  and a distinct Darwin AAPCS64 LP64 identity. The synthetic 32-bit description
  remains unchanged. Native Apple Clang static assertions corroborate these
  layout facts; its assembly spells `external_name` as `_external_name` and
  `_entry` as `__entry`. This is a bounded target-fact probe, not Darwin lowering.
- `Targets.Capabilities` separates C signatures, records and variadic calls
  from ABI identity, and states object format, implemented debug format,
  backend and triplet independently of pointer width. Darwin has no implemented
  C, assembly, debugger or toolchain capability. Checking and target-aware IR
  verification ask the relevant queries. C record eligibility is source-checked;
  nominal C-layout metadata also describes distinct scalar storage, independently
  of an implemented C boundary. The structural IR has no new target branch,
  opcode or serialized field. The SysV physical classifier remains guarded.
- `Backend.Dispatch` owns frame preflight, its encoding-limit description and
  concrete assembly/debug selection. The driver no longer calls x86 emission
  or names its frame encoding. The linker argument seam now requires explicit
  target facts and refuses GNU arguments for Darwin, including with named tools.
  The concrete x86 renderer retains the established synthetic-width text-test
  seam; this does not give synthetic-32 a driver backend. Other real target
  facts are refused there.
- `Landin.Hosted` owns exact logical helper identities shared by checking and
  emission. Linux libc dependencies and physical signature checks remain in
  their respective consumers. An unknown `_landin_host_` prefix is an ordinary
  import and no longer activates runtime bridge emission. All actual helper
  symbols still use the unchanged ELF spelling.
- [1975], D203 and tour [1610] now distinguish logical external names from
  target-prefixed object symbols and assembly quoting. Darwin prepends exactly
  one underscore, including before an existing underscore; native and C names
  share that rule. The invalid-name diagnostic no longer says ELF. Prototype
  1's section-placement sketch and prototype 4's C callback finding require no
  syntax change. The sole changed golden is `end-to-end/refine-identity`, adding
  `darwin-arm64`; IR, layout, token and diagnostic records remain unchanged.
- `core/c` continues to assert the specific `compiler.c_sysv_lp64` identity.
  The generator independently verifies the explicit Clang triple, macros,
  widths, byte order and signed-char policy before producing bindings. A new
  isolated generator control rejects a Darwin LP64 triple before macro/header
  work. No inferred LP64 compatibility, new scalar or new configuration fact
  is introduced. `docs/targets.md`, `docs/ir.md` and the package guide describe
  these boundaries. `check.py` rejects duplicated literal hosted identities.

Readiness intake disposition (all R5.20 inputs):

| Finding | Evidence and final disposition |
|---|---|
| R520-1, R520-4, R520-6, R520-7, BE-2 | Implemented by explicit ABI capabilities, second 64-bit facts, backend dispatch and shared helpers above. Target tests distinguish described facts from implemented facilities; Darwin source checking, emission/debug refusal and no-write/no-tool controls pass. |
| R520-2, R520-3 | Fact/specification boundary settled above. Darwin core/c aliases, binding-generator ABI support and native linker arguments remain explicitly with R5.30; Mach-O debug identity remains R5.40. These are not enabled by this item. |
| CHK-R491-4, R520-5, CHK-15600-2 | One merged repair: logical link names, explicit prefix mapping and neutral diagnostic wording. Tests cover punctuation, a leading underscore, helper symbols and canonical IR equality. Native Apple assembly corroborates the prefix. |
| CHK-FLOW-1, CHK-FE-2, CHK-FE-3 | Assessed with current native Mac debug probes at 8, 1024 and 4096. Alias and module-value chains and scalar flow accept all samples; 64-field flow accepts 8/1024 and reports exhaustion at 4096 (exit 71). The inherited 8372224-byte soft stack limit is unchanged. Declaration-by-field flow snapshots, folding dependency walks and remaining IR scratch arrays are retained resource limits, explicitly deferred to the scale and self-hosting successor. Syntax-depth bounds do not bound these tables; no universal recoverable-exhaustion or cross-host threshold claim is made. |
| CHK-REF-3 | Inspection confirms raw loop-transfer states still have normal-path release but no owner covering every exceptional exit. Existing loop/reference cases remain valid; no allocation-failure injection ran. Controlled transfer-state ownership is explicitly deferred to the scale and self-hosting successor, retaining the exceptional-exit leak limitation of this short-lived compiler. This item does not claim that all checker allocations are controlled. |
| LOW-1 | Fresh native Linux release none/off probes of the existing cleanup regression, retaining 4/8/12 guarded defers, emit 13694/116177/1839142 bytes in 0.008/0.064/1.217 seconds. These are different complete probe programs from the intake's original snippets. The unchanged 12-cleanup runtime passes four profiles. Equivalent-continuation sharing is explicitly deferred to competitive optimization: it requires preserving pop-before-run, return/failure selectors and cleanup side effects. No arbitrary cleanup-count refusal or changed evaluation order is introduced. |
| BE-1 | Preflight audit retains signed-displacement checks for frames/outgoing arguments, but cannot infer final RIP-relative reach across linker-placed text/data from one object extent. No multi-GiB object was assembled or linked. Large-image placement/preflight remains an explicit scale and self-hosting successor limitation; this item supplies no large-image acceptance. |
| LOW-3, BE-3 | The simplifier still has instruction/slot-sized scratch arrays; atom-code lookup and symbol collision allocation retain repeated identity scans. Bounded parser/container compilation controls below accept with stable assembly hashes, but do not establish asymptotic bounds. Scratch ownership/scaling is retained with the scale and self-hosting successor; faster atom/symbol algorithms and simplification are retained with competitive optimization. Correct baseline emission, not competitive scaling, remains the gate. |

Process evaluation is complete. The first routine acceptance measurements are
recorded in `docs/process.md`: the slowest job took 1208.5 seconds, with
111.6/113.8-second release builds already overlapping. On native Linux, four
fresh parser/container compilations (none/off and size/auto) using one unchanged
release compiler took 111.15 seconds with one worker and 55.55 with two. All
assembly hashes match; individual peak RSS is at most 50372 KiB. These samples
support bounded two-worker experimentation, not unrestricted nesting or a
whole-matrix memory bound. The compiler hash for this development measurement
is `aafc51578e47511101721ec52704165da0630e6d8d9b56af0cca9d68e12efc7b`.

The evaluated artifact graph is compiler inputs/tools/mode/path mapping ->
immutable compiler -> reached workload inputs/configuration/profile/target
and adapter tools -> immutable program -> independent execution, quality and
debugger consumers. The existing release-job compiler binaries have different
hashes/sizes in their different build contexts; blind cross-job reuse would
misstate provenance. Production scheduling and cache integration are explicitly
deferred to the scale and self-hosting successor, requiring shared cancellation,
timeout ownership, aggregate resource tests and producer-identity evidence.
The deliberate second quality compilation stays fresh to test determinism.
No acceptance schema, concurrency limit, failure oracle or Nix policy changes.

Development evidence is retained under `.scratch/r520/`: native host scope,
focused target/driver/backend/verifier/lowering/toolchain and identity checks,
Linux release fixture and parallelism transcripts, Apple C/assembly facts and
bounded resource inputs/results. The Mac resource result digest is
`eba2102c9bebe5f77f18c6b984046d03341e628efe8cd9939bc95ab33c94230d`.
The first Mac host run found the synthetic-emitter guard and identity-record
mismatches; focused corrected backend and identity checks resolve those failures.
The unchanged complete IR golden passed on that host; native Linux acceptance
checks it independently. The new equal-width lowering case compares the entire
canonical IR of generic, aggregate, control and explicit-link source.

The first routine candidate, `3ed7eb5e5e66c1fafe5de9a4bcbebd5be128a683`,
failed in retained run `20260915T091332Z-fd37b9bda06b`: the debug host suite
passed 713 of 715 cases, while two existing lowering cases exposed an overly
broad C-record capability guard on distinct scalar metadata for synthetic-32.
Removing that guard preserves structural validation and keeps capability
checks at actual C boundaries. The corrected native Mac lowering suite passes
all 134 cases and 2991 checks, including both failures; no golden changes.
Bindings and documents had passed; peer compiler jobs were cancelled. The
cancelled release suite also left an empty `compiler/ada/GNAT-TEMP-001384.TMP`,
which its source-inventory guard correctly refused. No source fixture changed,
and the inventory guard remains unchanged. This failed run supplies no approval;
the corrected committed archive must complete a fresh routine acceptance.

Closure candidate and acceptance binding: the completion status and next-item
pointers are prepared together so acceptance tests the final documents with
the implementation. They become authoritative only when this containing
revision completes the committed five-job routine native policy, verified
export and annotated `ci/accepted/FULL_COMMIT` approval. Canonical promotion
binds delivery; no later bookkeeping revision substitutes for the accepted
source. Development transcripts alone cannot close this item. Routine scope
has no GDB job: debug encoding, source/variable locations, unwind/frame
conventions and debugger transport are unchanged, and shared ELF helper/symbol
spelling preserves existing emitted identities. Darwin lowering and source
debugging remain R5.30/R5.40; R5 parity remains open.

### R5.30 — Implement Darwin arm64 lowering

Status: planned
Depends on: R5.10, R5.20, R2.30

Implement the arm64 data layout, Darwin calling conventions, native assembly,
object/link integration, hosted entry and minimal platform runtime. Revise
core/c and bindings/generate.py alongside the declared Darwin C ABI, and
select Darwin linker arguments instead of GNU-only library/build-id flags.

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
Own the Mach-O debug identity corresponding to the Linux build-id contract.

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
tour amendment. D188 leaves `[0660]`'s composition here: a range subtype in a
struct field, array element, pointer or slice target or generic type argument,
and the address of a constrained place, are refused by name until this item
decides how the check composes. D189 leaves `[0480]`'s multi-atom form here: a
union of two or more atoms and a pointer needs the tag-plus-pointer carrier
[1870] describes, which is an IR pair, storage, an ABI position and a backend
of its own, and is refused by name until this item supplies them.

[0100]'s atom declaration lists already work. This item owns the remaining
shared-name binding, field, parameter and return forms, including any
initializer-evaluation and parameter-convention decisions their implementation
needs. R4.91 gives those omitted grammar shapes a named refusal; parsing their
remaining type or initializer for recovery does not enable their semantics.

D190 leaves `[0150]`'s u128 and i128 and `[0170]`'s f16 here, refused by name
with the enumerated cost this item inherits. `Landin.Types.Magnitude` and
`Folded` use Ada ranges for the enabled 64-bit integer domain and neither
is an Ada range type at 128 bits on any host, so both become software
carriers along with the single `Pattern is mod 2 ** 64` the checker, the
lowering stage and the x86-64 backend each fold with. A 128-bit scalar is the
first the backend's one-accumulator model cannot hold in a register — its
`Held_Size` is `Byte_1 .. Byte_8` — and needs two INTEGER eightbytes at
16-byte alignment, add/adc and sub/sbb, a three-multiply `mul`, and a
division x86-64 has no instruction for. f16 re-runs the D162--D176 float
programme at binary16, whose arithmetic baseline x86-64 cannot do at all, and
reopens D170's recorded invariant that the enabled integer range cannot
overflow either float width: binary16 tops out at 65504, so
`conversion.integer-to-float` would move from `static` to `trap`. D190
records f32 promotion with a single rounding as the arithmetic model to
inherit.

Sources: `[0480]`'s multi-atom pointer union; [0660]'s composite and reference
positions, refused by name in R4.10; `[0150]`'s u128 and i128 and `[0170]`'s
f16, refused by name and re-owned here by D190.

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

The R4.30 review leaves one diagnostic-recovery refinement here: a private or
missing selected import is correctly refused at its import, but later uses
can repeat unresolved-name errors because the refused binding has no
continuation identity. Suppress those follow-on reports while retaining the
original visibility verdict and exact source report; this changes diagnostic
recovery, not which programs are accepted.

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

The D1–D6 labels in this appendix name inherited review positions, not the
specification's D1–D6 decisions. Elsewhere a D-number cites the specification
unless the surrounding text explicitly identifies a review's own labels.
F2 is a roadmap-wide process obligation, not deferred successor work.

These six inherited positions were each challenged by an outside reader and
deliberately retained. Reopen one only with new evidence that answers its preserved rationale,
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
| C6 — `unchecked` | Already normative but not first; optimizer assumptions wait for a measurable compiler. Sources: `[1120]`, `[1720]`, `H§5`. | Linux semantics implemented in R4.10 by D187; macOS hosted parity is R5.50; applicable freestanding conformance evidence is R6.100. What an optimizer may assume stays with R4.50. |
| D1 — Integer indexing of UTF-8 | Keep linear codepoint-ordinal indexing for ergonomics despite three independent objections. Source: `[0610]`. | Implemented in R4.10 by D182; reopen only with new program/measurement evidence. |
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

D225 follows the user's explicit J104 decision to reserve control words.
The thirteen additional keywords join the scanner's reserved vocabulary;
statement/expression dispatch and loop closers use token kinds, and transfer
labels no longer need an exception for a variable named complete. Existing
scope and assignment controls use legal longer names, while new negative
controls cover the retired names. Historical evidence for the contextual
spelling remains evidence for its original revision, not this changed rule.
Development validation: sixteen exact selectors pass 1,482 checks on each of
macOS debug and Linux release. The new reservation seam contributes 119 checks;
existing control, cleanup, recovery, anonymous-loop and completion-scope cases
retain their verdicts, and the two migrated positives emit only assembly text.
The additional driver check found four stale L0304 expectations from before
J138, each exercised for both output modes; they now require J138's L0201
without changing their one-diagnostic, no-write and no-tool contracts.
Both single-worker builds pass. The full document/grammar check passes, and
the pinned tree-sitter 0.26.9 generator updates the editor's 49-word reserved
set and generated parser. Its C parser was not compiled or executed. No
assembler, linker, generated Landin executable, debugger or mutation campaign
ran. Logs are retained in `.scratch/r491-control-keywords/` and
`.scratch/r491-final-values/`; exact-revision acceptance remains open.
