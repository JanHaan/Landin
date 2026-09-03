# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

Landin is a language specification with a working Ada bootstrap compiler. R0,
R1, R2.20 and R2.30 are complete. `refine` scans and parses every
`.ldn` file it is given, resolves the files as one module, checks every type
and definite assignment, lowers accepted functions into verified
target-neutral IR, emits Linux x86-64 assembly, and can invoke a
triplet-selected toolchain to assemble and link a hosted executable. Runtime
fixtures execute those binaries on the native Linux x86-64 gate. There is no
native macOS arm64 or Cortex-M backend and no standard library yet. Under
`compiler/ada/` are the Ada 2022 GPRbuild projects, the `refine` executable,
source and diagnostic foundations, host adapters, target facts, stage seams,
the scanner, parser, syntax table, name resolver, type checker, verified IR,
Linux x86-64 backend, toolchain adapter and repository-owned test harness;
shared fixtures live under `compiler/tests/`. The four prototype files remain
specification stress tests written as code sketches; they contain omissions
such as `...` and are not standalone programs.

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

# Run the same build and suite inside the pinned linux/amd64 image.
# Needs Apple Container; see docs/environments.md.
./scripts/linux-loop.sh

# Render every document as HTML, verify nothing was dropped, and package
# it for pages.sr.ht.  --publish uploads it, which the CI gate also does on
# every push to main; see docs/site/README.md.
./scripts/site.sh

# On a nix machine, a shell holding the pinned toolchain, python3 and hut.
# It reads environments/pins.sh and tags its objects `nix`, so it does not
# collide with the other environments; see docs/environments.md.
nix develop
```

Pushing runs `.build.yml` on x86-64 hardware at builds.sr.ht: that job is the authoritative Linux gate, and it builds from clean in debug and release. A local pass is not a substitute for it, and since R1.80 — when `refine` began emitting executable instructions — it has been the only environment that runs them on the hardware they were emitted for. Its last task renders and publishes the reading copies, from `main` only: a documentation change reaches <https://www.701.dev> by being pushed, not by anyone running `scripts/site.sh --publish`.

A push also submits two non-gates. `.builds/nix.yml` checks the `nix develop` shell and skips itself unless the push touched a file that shell is made of. `.builds/github-mirror.yml` copies the canonical git.sr.ht branches and tags to <https://github.com/JanHaan/Landin> with the existing repository SSH secret. Neither carries authority. All three manifests are submitted because builds.sr.ht looks for `.build.yml` and `.builds/*.yml` alike. Adding a fourth would need a reason — four manifests per push is the limit, beyond which builds.sr.ht chooses at random.

`check.py` uses only the Python standard library and changes to its own directory, so it can also be invoked by absolute path from elsewhere. It is a heuristic invariant checker, not a parser, compiler, formatter, or semantic test suite. Run the full command after documentation changes; targeted checking of an absolute `tour.md` path does not run all citation checks.

`scripts/test.sh` builds and then runs `compiler/ada`'s complete test program;
`scripts/linux-loop.sh` runs the same thing in the pinned Linux image. Those
are the two runnable test gates. `scripts/dev-build.sh` and
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

1. `spec.md` is the normative specification. It holds the grammar of the enabled kernel, [1740]-[1830], which covers what the compiler accepts today and shrinks as the language grows; the rules the tour left unsaid, [1840] onward, which are permanent; and a register naming every rule that was a decision rather than a transcription, with the alternative and the fixture that pins it. Where `spec.md` and `tour.md` could be read differently, `spec.md` decides.
2. `tour.md` explains the language, [0010]-[1730]. It teaches by example, which is why it omits what a reader supplies for themselves — every implementation item so far has found more of what it left unsaid, and the answer is to write the rule into `spec.md` rather than to attribute one to a paragraph that does not state it. Its four-digit construct IDs (`[NNNN]`) are stable citation anchors, spaced in increments of ten so new constructs can be inserted without renumbering existing decisions, and no ID is defined in both documents.
3. `ROADMAP.md` is the sole durable work authority. It owns every open item, implementation dependency, phase, disposition, and completion gate. Do not create a parallel TODO list in the specification, the tour, the prototypes, or issue files.
4. `prototype-{1..4}-*.md` are specification tests, not illustrative samples. Each deliberately stressed the design, and its ending findings record both obsolete wording and the resulting resolution.
5. `handoff.md` summarizes the inherited design principles and decisions that should not be reversed without new evidence.
6. `check.py` enforces cheap textual invariants across the specification, roadmap, prototypes, and the documents the R0 gate cites — including that the container recipe, `compiler/ada/TOOLCHAIN.md` and `flake.nix` pin the same toolchain, the flake by reading `environments/pins.sh` rather than naming a version of its own. Extend it when a new mechanically checkable invariant is introduced or when it misses a textual defect.

`check.py` also checks the grammar in `spec.md`: it reads the productions, holds every rule to being defined and reachable, and derives every `.ldn` under `compiler/tests/fixtures/positive`. A negative fixture is held to being *underivable* only when the frontend is what refuses it: one a later stage refuses is legal source and must derive, which its `codes:` is what says (see below). A grammar change that breaks a fixture, or a fixture the grammar cannot derive, fails there. Do not weaken a fixture to make a grammar change pass — the corpus is the agreement the parser has to meet, and the parser suite requires the same verdict from the other side.

A negative fixture's `codes:` is an ordered list, and it also says which stage refused the fixture: `check.py` reads which codes the frontend raises out of the two packages that raise them and requires the grammar to derive a program that only a later stage refused. Do not read a stage off a code's number — the catalogue's header forbids it, and `L0010` is raised by both the scanner and the parser.

Four tables in the compiler are transcriptions of the grammar rather than paraphrases of it, and `check.py` compares each with its source. `Landin.Tokens`' reserved words must be `spec.md`'s own `keyword` production. `Landin.Syntax.Precedence` must have [1820]'s levels in [1820]'s order, with the same operators at each, the same fold, the same prefix set and first sets that agree with the grammar's own. The parser's refusal tables cover the words [1760] does not reserve, so only the parser can meet them; the checker's refused-type table covers scalar type names the grammar admits but the kernel has deferred. Both tables must spell words the tour writes, cite paragraphs that exist, and name roadmap items that exist. `Landin.Types` spells the eleven enabled scalar names separately because it maps each onto a machine width. Add a level, an operator, a refused construct or a type in one place and the check says which other place disagrees.

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
without it renders in the fallback stack while `scripts/site.sh --publish`
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
- Prototype 3 develops the conceptual `core/mem`, `core/vec`, `core/map`, and `core/tree` layers and stresses generics, allocators, evidence tables, origins, and raw storage.
- Prototype 4 builds on prototypes 2 and 3, adds hosted I/O, and exercises heterogeneous runtime dispatch through `any C`.

Repeated module names describe shared future subsystems, not separately checked source dependencies. Prototypes 1 and 4 cover the freestanding and hosted authority roots respectively; capabilities below those roots are passed as ordinary arguments.

## Implementation architecture

The bootstrap compiler is a production-quality Ada 2022 implementation built with pinned GNAT/GPRbuild, minimal dependencies, no SPARK, and a custom compiler test harness. Its direct executable is `refine`, and Landin source files use the `.ldn` suffix. `compiler/ada/README.md` records the current package layout and what each package may and may not own; `compiler/ada/TOOLCHAIN.md` records the pinned versions and the warning policy; `compiler/tests/README.md` records the fixture format.

Two rules already hold in the chassis and must keep holding. Every host effect the compiler needs goes through a `Landin.Platform` interface, so every driver and stage case runs against a fake filesystem; the cases that exercise the native adapter, run the recorded fixtures, or read the real fixture tree are the deliberate exceptions, and each one names the real host in its own comment. Nothing outside `Landin.Targets` may ask the host how wide a pointer is: a 32-bit target description stays 32-bit on a 64-bit host, and layout arithmetic counts target bytes in `Landin.Targets.Byte_Count` rather than in the host compiler's `Natural`.

The compiler checks whole programs and may use private caches. Its verified target-neutral IR is allowed to evolve from implementation evidence rather than being frozen as one flat or serialized form. Landin retains its own native backends, which emit assembly for platform assembler/linker tooling. Target order is Linux x86-64, native macOS arm64, then emulator-first Cortex-M; C and LLVM remain rejected backend alternatives.

Compiler stages are Ada packages behind tested seams so a future self-hosting roadmap may replace them incrementally. The current roadmap neither schedules self-hosting nor freezes a serialized cross-language stage protocol.

`core/*` is reserved for the future standard library. `landin/compiler`, `landin/assembler`, and `landin/linker` are reserved toolchain modules. Package acquisition and arrangement of package roots belong to a separate companion tool rather than the compiler, and a program may contain only one version of a package name.

Implementation proceeds without waiting for every unresolved foundation.
`ROADMAP.md` assigns each question to the first vertical slice that needs it.
R0 established the bootstrap chassis, R1 built the executable language kernel
and first Linux x86-64 path, and R2 is settling the semantic and representation
core from executable cases. R3, a complete derived parser program with useful
diagnostics, evidence-table dispatch, and `any` but without specialization, is
the first major compiler milestone.

The roadmap ends at a feature-complete pre-v1 compiler/toolchain slice. Production claims, release versioning, package acquisition, competitive optimization, and self-hosting remain outside it. Do not change any version or release designation without explicit user approval, and do not assume SemVer.

## Design constraints

Changes must preserve the range from a 32 KB microcontroller to a hosted application. The central design choices are:

- Manual memory with arenas as the idiom; no GC, reference counting, or destructors. Allocators are threaded as capabilities rather than stored in containers.
- Reference permission and binding mutability are separate. Lifetime checks use local origin/escape analysis, not ownership or a borrow checker. The language is deliberately unsafe with useful local checks rather than claiming memory or resource safety.
- Declared atom-set errors use `fail`/`try` and call-site `else`; foreseeable conditions should generally be represented and recovered from directly.
- Concepts and evidence tables support both static generics and `any` runtime dispatch; specialization is an optimization rather than the semantic basis.
- There is no compile-time execution or macro system. Source generators belong in the future build design.

Before reviving a previously rejected idea, read `ROADMAP.md`'s inherited review register and `tour.md`'s `WHAT WAS TRIED AND DROPPED` section.

## Editing the specification

When implementation requires a semantic change, update `tour.md`, the affected prototype-derived tests, and `ROADMAP.md` together. Trace the construct's citations, reread all affected prototypes including cross-prototype interactions, and then run `python3 check.py`. Per-file reasoning has previously missed contradictions found only by comparing prototypes.

Do not modernize obsolete syntax inside prototype finding sections (`Xn`, `Yn`, `Zn`, `Wn`) or the tour's `WHAT WAS TRIED AND DROPPED` section. Those passages intentionally preserve rejected wording next to its resolution, and `check.py` deliberately excludes them from some retired-spelling checks.

## Agent skills

### Issue tracker

Disposable execution detail is tracked in local Markdown files under `.scratch/`; durable discoveries, dependencies, and dispositions must be returned to `ROADMAP.md`. See `docs/agents/issue-tracker.md`.

### Triage labels

Triage uses the five default canonical role names. See `docs/agents/triage-labels.md`.

### Domain docs

This repository uses a single-context domain-doc layout. See `docs/agents/domain.md`.
