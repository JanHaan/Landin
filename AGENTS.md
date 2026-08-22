# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

Landin is a language specification whose bootstrap implementation has a complete frontend and nothing behind it. `refine` scans and parses every `.ldn` file it is given, resolves every name in them as one module, checks every type and every definite assignment, reports what none of the four could read, and produces nothing when a file is a program; there is no IR, backend, or standard library yet. Under `compiler/ada/` are the R0 chassis — an Ada 2022 GPRbuild project, the `refine` executable, source and diagnostic foundations, host adapters, target facts, stage seams, and a repository-owned test harness — the scanner, the parser, the syntax table, the name resolver, the type checker, and the diagnostic catalogue, plus shared fixtures under `compiler/tests/`. The four prototype files remain specification stress tests written as code sketches; they contain omissions such as `...` and are not standalone programs.

## Commands

```sh
# Run every available mechanical check over the specification, roadmap, and prototypes
python3 check.py

# Check one specification/prototype file (the narrowest supported test scope)
python3 check.py prototype-2-parser.txt

# Build the bootstrap compiler and run its own test program.  Both need the
# pinned toolchain reachable; see compiler/ada/TOOLCHAIN.md.
./scripts/build.sh
./scripts/test.sh

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

Pushing runs `.build.yml` on x86-64 hardware at builds.sr.ht: that job is the authoritative Linux gate, and it builds from clean in debug and release. A local pass is not a substitute for it, and from R1.80 onwards — when `refine` starts emitting instructions — it is the only environment that runs them on the hardware they were emitted for. Its last task renders and publishes the reading copies, from `main` only: a documentation change reaches https://sinnfrei.srht.site by being pushed, not by anyone running `scripts/site.sh --publish`.

`check.py` uses only the Python standard library and changes to its own directory, so it can also be invoked by absolute path from elsewhere. It is a heuristic invariant checker, not a parser, compiler, formatter, or semantic test suite. Run the full command after documentation changes; targeted checking of an absolute `tour.txt` path does not run all citation checks.

`scripts/test.sh` builds and then runs `compiler/ada`'s test program; `scripts/linux-loop.sh` runs the same thing in the pinned Linux image. Those are the two runnable test commands. There is no separate lint or typecheck step: the pinned build treats every warning as an error and enforces GNAT style checks. Warnings are policy, not preference — do not silence one without a recorded reason.

Staleness is decided by source checksums, not timestamps: `build.sh` rebuilds from clean when the manifest disagrees, because an edited-and-reverted file keeps a newer mtime than the object built from it and gprbuild would serve the stale object.

## Sources of truth

Use the repository documents in this order:

1. `tour.txt` is the normative language specification. Its four-digit construct IDs (`[NNNN]`) are stable citation anchors, spaced in increments of ten so new constructs can be inserted without renumbering existing decisions.
2. `ROADMAP.md` is the sole durable work authority. It owns every open item, implementation dependency, phase, disposition, and completion gate. Do not create a parallel TODO list in the tour, prototypes, or issue files.
3. `prototype-{1..4}-*.txt` are specification tests, not illustrative samples. Each deliberately stressed the design, and its ending findings record both obsolete wording and the resulting resolution.
4. `handoff.md` summarizes the inherited design principles and decisions that should not be reversed without new evidence.
5. `check.py` enforces cheap textual invariants across the specification, roadmap, prototypes, and the documents the R0 gate cites — including that the container recipe, `compiler/ada/TOOLCHAIN.md` and `flake.nix` pin the same toolchain, the flake by reading `environments/pins.sh` rather than naming a version of its own. Extend it when a new mechanically checkable invariant is introduced or when it misses a textual defect.

`check.py` also checks the grammar in `tour.txt`: it reads the productions, holds every rule to being defined and reachable, and derives every `.ldn` under `compiler/tests/fixtures/positive`. A negative fixture is held to being *underivable* only when the frontend is what refuses it: one a later stage refuses is legal source and must derive, which its `codes:` is what says (see below). A grammar change that breaks a fixture, or a fixture the grammar cannot derive, fails there. Do not weaken a fixture to make a grammar change pass — the corpus is the agreement the parser has to meet, and the parser suite requires the same verdict from the other side.

A negative fixture's `codes:` is an ordered list, and it also says which stage refused the fixture: `check.py` reads which codes the frontend raises out of the two packages that raise them and requires the grammar to derive a program that only a later stage refused. Do not read a stage off a code's number — the catalogue's header forbids it, and `L0010` is raised by both the scanner and the parser.

Four tables in the compiler are transcriptions of the grammar rather than paraphrases of it, and `check.py` compares each with its source. `Landin.Tokens`' reserved words must be the tour's own `keyword` production. `Landin.Syntax.Precedence` must have [1820]'s levels in [1820]'s order, with the same operators at each, the same fold, the same prefix set and first sets that agree with the grammar's own. And the parser's refusal tables — the words [1760] does not reserve, so only the parser can meet them, and the eleven scalar type names — must spell words the tour writes, cite paragraphs that exist, and name roadmap items that exist. And `Landin.Types` spells the eleven scalar names a second time, because it is the package that maps each onto a machine width; both it and the parser are held to the tour's own `type` rule and to each other. Add a level, an operator, a refused construct or a type in one place and the check says which other place disagrees.

`R§n` and `H§n` citations preserved in the roadmap refer to an external design archive; the tracked repository does not depend on that archive.

Every document above is also published as a reading copy at https://sinnfrei.srht.site, rendered by `docs/site/render_html.py`. The text files are the sources; the pages are generated and never edited by hand.

Syntax highlighting lives in `highlight/`, not in the site renderer. `highlight/landin_highlight.py` is the one token scanner every Landin highlighter renders — the pages as HTML spans, `highlight/landin_pygments.py` as Pygments tokens, and a TextMate and a tree-sitter grammar later. Add a keyword there rather than in a consumer, and keep it standard-library-only so the site keeps its no-dependency build. `check.py`'s own list of reserved words is deliberately separate: that one is about legality, this one about colour. See `highlight/README.md`.

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

Implementation begins immediately rather than waiting for every unresolved foundation. `ROADMAP.md` assigns each question to the first vertical slice that needs it. R0 establishes the bootstrap chassis, R1 builds the executable language kernel and first Linux x86-64 path, and R2 settles the semantic and representation core from executable cases. R3, a complete derived parser program with useful diagnostics, evidence-table dispatch, and `any` but without specialization, is the first major compiler milestone.

The roadmap ends at a feature-complete pre-v1 compiler/toolchain slice. Production claims, release versioning, package acquisition, competitive optimization, and self-hosting remain outside it. Do not change any version or release designation without explicit user approval, and do not assume SemVer.

## Design constraints

Changes must preserve the range from a 32 KB microcontroller to a hosted application. The central design choices are:

- Manual memory with arenas as the idiom; no GC, reference counting, or destructors. Allocators are threaded as capabilities rather than stored in containers.
- Reference permission and binding mutability are separate. Lifetime checks use local origin/escape analysis, not ownership or a borrow checker. The language is deliberately unsafe with useful local checks rather than claiming memory or resource safety.
- Declared atom-set errors use `fail`/`try` and call-site `else`; foreseeable conditions should generally be represented and recovered from directly.
- Concepts and evidence tables support both static generics and `any` runtime dispatch; specialization is an optimization rather than the semantic basis.
- There is no compile-time execution or macro system. Source generators belong in the future build design.

Before reviving a previously rejected idea, read `ROADMAP.md`'s inherited review register and `tour.txt`'s `WHAT WAS TRIED AND DROPPED` section.

## Editing the specification

When implementation requires a semantic change, update `tour.txt`, the affected prototype-derived tests, and `ROADMAP.md` together. Trace the construct's citations, reread all affected prototypes including cross-prototype interactions, and then run `python3 check.py`. Per-file reasoning has previously missed contradictions found only by comparing prototypes.

Do not modernize obsolete syntax inside prototype finding sections (`Xn`, `Yn`, `Zn`, `Wn`) or the tour's `WHAT WAS TRIED AND DROPPED` section. Those passages intentionally preserve rejected wording next to its resolution, and `check.py` deliberately excludes them from some retired-spelling checks.

## Agent skills

### Issue tracker

Disposable execution detail is tracked in local Markdown files under `.scratch/`; durable discoveries, dependencies, and dispositions must be returned to `ROADMAP.md`. See `docs/agents/issue-tracker.md`.

### Triage labels

Triage uses the five default canonical role names. See `docs/agents/triage-labels.md`.

### Domain docs

This repository uses a single-context domain-doc layout. See `docs/agents/domain.md`.
