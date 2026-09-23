# AGENTS.md

Guidance for coding agents working in this repository. `CLAUDE.md` is a
symlink to this file, so Claude Code and any harness that reads `AGENTS.md`
see the same text; edit this one.

## Repository state

Landin is a language specification with a working Ada bootstrap compiler.
`refine` scans and parses every `.ldn` file it is given, resolves the files as
one module, checks every type and definite assignment, lowers accepted
functions into verified target-neutral IR, emits Linux x86-64, Darwin arm64 or
Cortex-M0 assembly, and can invoke a target-selected native toolchain to
assemble and link.

All three targets are implemented. The two hosted ones build and run complete
programs with native source-debugging coverage — GDB on Linux, LLDB on
Darwin — and Cortex-M0 builds firmware with compiler-owned reset, vectors,
linker script and initialized-data copying, with line and function debugging.
A small repository-owned `core` library and the complete derived prototypes 2,
3 and 4 execute through that path. Runtime fixtures execute those binaries,
and the gate runs all of them on Linux on every push; the other two targets
have no automated coverage.

Under `compiler/ada/` are the Ada 2022 GPRbuild projects, the `refine`
executable, source and diagnostic foundations, host adapters, target facts,
stage seams, the scanner, parser, syntax table, name resolver, type checker,
verified IR, the three backends, the toolchain adapter and the
repository-owned test harness; shared fixtures live under `compiler/tests/`.
The four prototype files remain specification stress tests written as code
sketches; they contain omissions such as `...` and are not standalone
programs.

## Commands

```sh
# Run every available mechanical check over the live documents and fixtures
python3 check.py

# Check one specification/prototype file (the narrowest supported test scope)
python3 check.py prototype-2-parser.md

# Build the bootstrap compiler and run its own test program.  Both need the
# pinned toolchain reachable; see compiler/ada/TOOLCHAIN.md.
./scripts/build.sh
./scripts/test.sh

# Fast checksum-safe developer feedback.  The selectors are exact names;
# these runs are visibly FILTERED and do not replace the complete suite.
./scripts/dev-test.sh --suite='fixture execution'
./scripts/dev-test.sh --case='harness/filters select exact cases'
./scripts/dev-test.sh --fixture=negative/variant-match-duplicate

# Remove this host's build artefacts (--all removes every host's).
./scripts/clean.sh

# Mac compiler-host feedback.  The unfiltered suite needs Linux.
./scripts/dev-test.sh --host --suite=checking

# Render every document as HTML, verify nothing was dropped, and package
# it.  It does not publish: .github/workflows/pages.yml is the only
# publisher; see docs/site/README.md.
./scripts/site.sh

# On a nix machine, a shell holding the pinned toolchain and python3.  It
# reads environments/pins.sh and tags its objects `nix`, so it does not
# collide with the other environments; see docs/environments.md.
nix develop

# Build the compiler through the flake.  .#refine is the default and builds
# this checkout from source -- about 140s on a fast Linux host, and the same
# cold, because the 478MB of pinned toolchain fetches alongside the compile.
# .#refine-bin fetches the published release asset instead, in about 5s, and
# ignores the working tree: it answers "give me the compiler", not "build
# what I have".
nix build .#refine
nix build .#refine-bin
```

`.github/workflows/gate.yml` is the mechanical gate, and it runs on every
push and pull request. Two jobs that share nothing: `documents` runs
`check.py` in about ninety seconds, needing neither the toolchain nor a built
compiler, and `compiler` builds `refine` with the pinned toolchain and runs
all 743 cases at `LANDIN_TEST_JOBS=2`, in about thirty-seven minutes. Splitting them
means a typo gets its verdict without waiting for the corpus, and a compile
error still surfaces about two minutes into `compiler`.

The gate is deliberately small and is **not** the retired acceptance. It is
Linux only and debug only: no Darwin, no Cortex-M execution, no debugger, no
bindings, no release mode, and no retained evidence. Green means the compiler
builds and the corpus passes on one host in one mode — nothing about the
other two targets. `ROADMAP.md` schedules the fuller gate.

Three more workflows run on a push. `determinism.yml` requires every host in
its matrix to emit the same bytes; it emits and hashes but never assembles,
links or runs. `pages.yml` publishes <https://www.701.dev>. `links.yml`
checks every link in every document, weekly and whenever a document changes.
`release.yml` is tag-driven: a `v*` tag builds and publishes the `refine`
assets that `nix build .#refine-bin` consumes.

The exact-revision native acceptance in `scripts/ci/` approved every revision
through 0.2.0 and was removed when the project left SourceHut. Do not cite it
as current and do not claim a change is accepted: nothing accepts revisions
now, and the gate above is a safety net rather than a verdict on a revision.
`environments/native-ci/README.md` and `environments/macos-arm64/README.md`
describe the retired arrangement.

The repository submits no build manifests. GitHub is canonical and takes
pushes directly; git.sr.ht is a mirror, kept in step by a second push URL on
the same remote rather than by a job. `pages.yml` fetches the licensed code
face from object storage because it is not in this repository; it renders and
verifies, and runs no compiler test. `scripts/site.sh` renders and packages
and does not publish. Nix CI is deferred: the flake is built by hand, and the
former automatic Nix manifest is retired. Historical SourceHut gate links
remain evidence for their original revisions.

`check.py` uses only the Python standard library and changes to its own directory, so it can also be invoked by absolute path from elsewhere. It is a heuristic invariant checker, not a parser, compiler, formatter, or semantic test suite. Run the full command after documentation changes; targeted checking of an absolute `tour.md` path does not run all citation checks.

Use `scripts/dev-test.sh --host` on the Mac for compiler-host feedback, and
expect every selected case to pass. The unfiltered harness includes Linux
execution and fails without its target toolchain, so do not run Linux
containers, Linux workload emission or repeated complete suites on the Mac as
routine feedback. Run changed-component tests while editing and the complete
suite before pushing; `LANDIN_TEST_JOBS` splits the corpus fixtures across
workers, which is most of what the suite costs. One worker is still the
default, and `scripts/parallel-equivalence.sh` is what holds a wider run to
the same verdicts.

Linux runtime and GDB evidence comes from the gate, or from a Linux host you
run yourself; the dedicated native runner is gone. Darwin runtime and LLDB
evidence runs natively on the Mac and nothing automates it, so a Darwin claim
needs a Mac run behind it. R5.10's retained expected-refusal transcript is
historical bootstrap evidence, never a current success rule.
`docs/process.md` explains the workflow.

`scripts/test.sh` builds and runs the complete Linux test program on native
Linux. Its `--host` selector retains compiler checks on the Mac. `scripts/dev-build.sh` and
`scripts/dev-test.sh` use GPRbuild's checksum mode for fast feedback, and the
latter accepts one exact `--suite`, `--case`, or `--fixture` selector. A
filtered run says `FILTERED` in its transcript and is not gate evidence. There
is no separate lint or typecheck step: the pinned build treats every warning
as an error and enforces GNAT style checks. Warnings are policy, not preference
— do not silence one without a recorded reason.

Staleness is decided by source checksums, not timestamps: `build.sh` rebuilds
from clean when the manifest disagrees, because an edited-and-reverted file
keeps a newer mtime than the object built from it and gprbuild would serve the
stale object. The developer wrappers instead pass the pinned GPRbuild's `-m2`
checksum mode; source inventory or project-file changes still force a clean
tree.

## Sources of truth

Use the repository documents in this order:

1. `spec.md` is the normative specification. It holds the grammar of the enabled kernel, [1740]-[1830], which covers what the compiler accepts today and shrinks as the language grows; the rules the tour left unsaid, [1840] onward, which are permanent; and a register naming every rule that was a decision rather than a transcription, with the alternative and the fixture that pins it, in fourteen subject sections. Where `spec.md` and `tour.md` could be read differently, `spec.md` decides.
2. `tour.md` explains the language, [0010]-[1730]. It teaches by example, which is why it omits what a reader supplies for themselves — every implementation item so far has found more of what it left unsaid, and the answer is to write the rule into `spec.md` rather than to attribute one to a paragraph that does not state it. Its four-digit construct IDs (`[NNNN]`) are stable citation anchors, spaced in increments of ten so new constructs can be inserted without renumbering existing decisions, and no ID is defined in both documents. Both documents are arranged by subject and their numbers therefore do not ascend down the page; that is the numbering working, not drift to be tidied up. `docs/documents.md` says where a new rule goes.
3. `ROADMAP.md` is the sole authority for open work: phases R8 onward with their items, dependencies and gates, the register of work that waits for a trigger, and the positions an outside review challenged and the project kept. The first roadmap, R0 to R7, is closed; its text is in the history and only an index of its items remains, until the citations it left in the tree are removed. Do not create a parallel TODO list in the specification, the tour, the prototypes, or issue files. The evidence registers, what the compiler's evidence is rather than what is left to do, are in `compiler/tests/registers.md`.
4. `prototype-{1..4}-*.md` are specification tests, not illustrative samples. Each deliberately stressed the design, and its ending findings record both obsolete wording and the resulting resolution.
5. `handoff.md` summarizes the inherited design principles and decisions that should not be reversed without new evidence.
6. `check.py` enforces cheap textual invariants across the specification, roadmap, prototypes, and the other live documents — including that the container recipe, `compiler/ada/TOOLCHAIN.md` and `flake.nix` pin the same toolchain, the flake by reading `environments/pins.sh` rather than naming a version of its own. Extend it when a new mechanically checkable invariant is introduced or when it misses a textual defect.

`check.py` also checks the grammar in `spec.md`: it reads the productions, holds every rule to being defined and reachable, and derives every `.ldn` under `compiler/tests/fixtures/positive`. A negative fixture is held to being *underivable* only when the frontend is what refuses it: one a later stage refuses is legal source and must derive, which its `codes:` is what says (see below). A grammar change that breaks a fixture, or a fixture the grammar cannot derive, fails there. Do not weaken a fixture to make a grammar change pass — the corpus is the agreement the parser has to meet, and the parser suite requires the same verdict from the other side.

A negative fixture's `codes:` is an ordered list, and it also says which stage refused the fixture: `check.py` reads which codes the frontend raises out of the two packages that raise them and requires the grammar to derive a program that only a later stage refused. Do not read a stage off a code's number — the catalogue's header forbids it, and `L0010` began in lexical refusal and is now raised only by the parser.

Four tables in the compiler are transcriptions of the grammar rather than paraphrases of it, and `check.py` compares each with its source. `Landin.Tokens`' reserved words must be `spec.md`'s own `keyword` production. `Landin.Syntax.Precedence` must have [1820]'s levels in [1820]'s order, with the same operators at each, the same fold, the same prefix set and first sets that agree with the grammar's own. The parser's refusal tables cover the words [1760] does not reserve, so only the parser can meet them; the checker's refused-type table covers scalar type names the grammar admits but the kernel has deferred. Both tables must spell words the tour writes, cite paragraphs that exist, and name roadmap items that exist. `Landin.Types` spells the thirteen enabled scalar names separately because it maps each onto a machine width. Add a level, an operator, a refused construct or a type in one place and the check says which other place disagrees.

The five documents are Markdown, and the form carries invariants rather than
being a style. A construct is `### [NNNN] Title` at column 0 and nothing else
is; a citation is inline and can never be mistaken for a definition, which in
the `.txt` form it could — 33 lines looked like definitions and were
citations, and 16 real definitions sat indented inside one example, which is
how [1050] was missed twice. A Landin example is a fenced block tagged
`landin`, a production is tagged `landin-grammar`, and an untagged fence is a
fault: what a block *is* is stated rather than guessed, and the heuristic it
replaced accepted 114 lines of English as code. Prose is never indented four
spaces, because Markdown reads that as a code block — an aligned list belongs
in a table.

`R§n` and `H§n` citations preserved in the roadmap refer to an external design archive; the tracked repository does not depend on that archive.

Every document above is also published as a reading copy at <https://www.701.dev>, rendered by `docs/site/render_html.py`. The text files are the sources; the pages are generated and never edited by hand.

The mark lives in `assets/`, not in the site renderer. `assets/icon.svg` is
the drawing — `701` as a path, so no renderer needs Futura — and
`assets/landin_icon.py` is every rendering of it: the light, dark, contrast,
`currentColor`, monochrome and `prefers-color-scheme` variants, the inline
fragment, and the `data:` URL a page carries. Its four colours are the
site's own, and `check.py` holds them to the stylesheet in
`docs/site/render_html.py` and to the drawing's own attributes. Add a
variant there rather than in a consumer, and keep it standard-library-only
so the site keeps its no-dependency build. See `assets/README.md`.

The two faces the pages are set in are declared in `assets/fonts.py`, not
in the site renderer. Each family is the subset webfont package its source
delivers, and `assets/fonts.py` is every rendering of them: the
`@font-face` block a page carries, the `--ui` and `--mono` stacks, and the
list of files copied beside the pages. `Nunito Sans` is under the OFL and
vendored in `assets/fonts/`; `MonoLisaCode` is under a foundry EULA that
forbids passing the files on, so it lives in the private `landin-fonts`
repository, found through `LANDIN_FONTS` or beside this one, and a host
without it renders in the fallback stack while the publishing workflow
refuses. The module reads each family's own stylesheet rather than
transcribing thirty `unicode-range` lists, and `check.py` holds every
character of every rendered document to falling inside a subset of both
families, because a range nobody covers is a paragraph in a fallback face
that no word count can see. Add a family there rather than in a consumer,
keep it standard-library-only, and do not trim the subsets to today's
documents. See `assets/fonts/README.md`.

Syntax highlighting lives in `highlight/`, not in the site renderer. `highlight/landin_highlight.py` owns the lexical vocabulary rendered by the pages, Pygments, TextMate, Vim, Notepad++, Nano and Kate; `highlight/tree-sitter/` is the checked structural grammar whose queries feed Neovim, Helix and Zed. Emacs provides both native and tree-sitter modes. Generate copied artifacts with `highlight/generate.py`, add a keyword at the shared source rather than in a consumer, and keep the mandatory generator path standard-library-only so the site keeps its no-dependency build. `check.py`'s own list of reserved words is deliberately separate: that one is about legality, this one about colour. See `highlight/README.md`.

## Prototype coverage

The prototypes jointly define the implementation pressure on the specification:

- Prototype 1 covers freestanding hardware: generated SVD modules, packed registers, volatile access, DMA, interrupts, and vector placement.
- Prototype 2 covers a recovering parser and distinguishes foreseeable syntax diagnostics from failures such as allocation failure.
- Prototype 3 develops the conceptual `core/mem`, `core/vec`, `core/small`, `core/map`, `core/tree` and `core/sort` layers and stresses generics, allocators, evidence tables, origins, and raw storage.
- Prototype 4 builds on prototypes 2 and 3, adds hosted I/O, and exercises heterogeneous runtime dispatch through `any C`.

Repeated module names describe shared future subsystems, not separately checked source dependencies. Prototypes 1 and 4 cover the freestanding and hosted authority roots respectively; capabilities below those roots are passed as ordinary arguments.

## Implementation architecture

The bootstrap compiler is a production-quality Ada 2022 implementation built with pinned GNAT/GPRbuild, minimal dependencies, no SPARK, and a custom compiler test harness. Its direct executable is `refine`, and Landin source files use the `.ldn` suffix. `compiler/ada/README.md` records the current package layout and what each package may and may not own; `compiler/ada/TOOLCHAIN.md` records the pinned versions and the warning policy; `compiler/tests/README.md` records the fixture format.

Two rules already hold in the chassis and must keep holding. Every host effect the compiler needs goes through a `Landin.Platform` interface, so every driver and stage case runs against a fake filesystem; the cases that exercise the native adapter, run the recorded fixtures, or read the real fixture tree are the deliberate exceptions, and each one names the real host in its own comment. Nothing outside `Landin.Targets` may ask the host how wide a pointer is: a 32-bit target description stays 32-bit on a 64-bit host, and layout arithmetic counts target bytes in `Landin.Targets.Byte_Count` rather than in the host compiler's `Natural`.

The compiler checks whole programs and may use private caches. Its verified target-neutral IR is allowed to evolve from implementation evidence rather than being frozen as one flat or serialized form. Landin retains its own native backends, which emit assembly for platform assembler/linker tooling. Target order is Linux x86-64, native macOS arm64, then emulator-first Cortex-M; C and LLVM remain rejected backend alternatives.

[`docs/ir.md`](docs/ir.md) explains the IR and its rationale for readers new to
the project. Keep it current when the representation, verification boundary
or optimization pipeline changes. It is derived from implementation and
tests, never an authority for semantics, implementation decisions or work.
`docs/targets.md` does the same for the C and link-name package boundaries,
and `examples.md` holds the complete programs the runtime suite executes.
All three are derived documents and none of them decides anything.

Compiler stages are Ada packages behind tested seams so a future self-hosting roadmap may replace them incrementally. The current roadmap neither schedules self-hosting nor freezes a serialized cross-language stage protocol.

`core/*` is reserved for the future standard library. `landin/compiler`, `landin/assembler`, and `landin/linker` are reserved toolchain modules. Package acquisition and arrangement of package roots belong to a separate companion tool rather than the compiler, and a program may contain only one version of a package name.

Implementation proceeds without waiting for every unresolved foundation.
`ROADMAP.md` assigns each question to the first vertical slice that needs it.
The first roadmap is complete and declared so at R7.70: no work item remains.
R0 established the bootstrap chassis, R1 the executable language kernel and the
first Linux x86-64 path, R2 the semantic and representation core, R3 the first
complete derived program, R4 the hosted Linux path, R5 the native macOS target
and its debugging, R6 Cortex-M0 and compiler-owned firmware, and R7 audited
every construct and gave every inherited row a terminal disposition.

What each item contributed is not re-narrated here, and the current roadmap
does not narrate either: the first one grew to thirteen thousand lines doing
it. A completed item gets a short `Done:` paragraph, and the reasoning goes in
the commit and in `spec.md`'s register of decisions. What the compiler does
today is under **Repository state** above.

The current roadmap runs from R8: a frontend that scales, assembly with
operands, a frontend for an editor, more hosted targets, microcontrollers,
the library split, concurrency, Windows and optimization. A build tool,
package acquisition, release versioning and self-hosting stay outside it, with
the successor families in `ROADMAP.md` owning each. Do not change any version
or release designation without explicit user approval, and do not assume
SemVer. Cite a roadmap item or register record in `ROADMAP.md` and nowhere
else: `check.py` refuses one of the current roadmap's identities anywhere
else, and the first roadmap's are being removed.

## Design constraints

Changes must preserve the range from a 32 KB microcontroller to a hosted application. The central design choices are:

- Manual memory with arenas as the idiom; no GC, reference counting, or destructors. Allocators are threaded as capabilities rather than stored in containers.
- Reference permission and binding mutability are separate. Lifetime checks use local origin/escape analysis, not ownership or a borrow checker. The language is deliberately unsafe with useful local checks rather than claiming memory or resource safety.
- Declared atom-set errors use `fail`/`try` and call-site `else`; foreseeable conditions should generally be represented and recovered from directly.
- Concepts and evidence tables support both static generics and `any` runtime dispatch; specialization is an optimization rather than the semantic basis.
- There is no compile-time execution or macro system. Source generators belong in the future build design.

Before reviving a previously rejected idea, read `ROADMAP.md`'s retained positions and register, and `tour.md`'s `WHAT WAS TRIED AND DROPPED` section.

## Editing the specification

When implementation requires a semantic change, update `tour.md`, the affected prototype-derived tests, and `ROADMAP.md` together. Trace the construct's citations, reread all affected prototypes including cross-prototype interactions, and then run `python3 check.py`. Per-file reasoning has previously missed contradictions found only by comparing prototypes.

Do not modernize obsolete syntax inside prototype finding sections (`Xn`, `Yn`, `Zn`, `Wn`) or the tour's `WHAT WAS TRIED AND DROPPED` section. Those passages intentionally preserve rejected wording next to its resolution, and `check.py` deliberately excludes them from some retired-spelling checks.
