# Landin

> Ada, but small. Zig, but sweeter. One systems language from 32 KB to
> 32 TB. Move fast, keep the pointers, and let the compiler tell you
> when you are being an idiot.

A systems programming language, its compiler and a small standard
library, designed and built from scratch. Named after Peter Landin, who
coined the term *syntactic sugar* and wrote *The Next 700 Programming
Languages* in 1966 — this one is the 701st.

One target range, and the same way of writing code across all of it: a
Cortex-M0 with 32 KB of flash at one end, a hosted desktop application
at the other.

**Status: specification 0.2.1. The compiler can build and run Landin programs
for Linux x86-64 and native macOS arm64, and builds firmware for Cortex-M0. It handles functions, user-defined data types, generic
routines, pointers, errors, control flow, modules, evidence-table dispatch and
`any`. Hosted containers, allocators, text and I/O in `core`, a complete
recovering configuration parser and a hosted log filter now run alongside the
automatically tested sensor-polling, FizzBuzz, number-theory, searching
and sorting programs, plus correctness-scale fannkuch-redux, Mandelbrot and
FASTA workloads. A complete derived driver and application run on the pinned
Cortex-M0 emulators with compiler-owned startup, within the recorded 32 KiB
capacity and source-debugging limits. The roadmap that built this closed with
the slice feature-complete pre-v1; the next one takes it to an editor, more
targets and the microcontrollers people buy.**

## What is here

| file | what it is |
| --- | --- |
| `handoff.md` | start here. The design in one page, the principles behind it, how the work is done, and which decisions must not be quietly reversed. |
| `spec.md` | the normative specification: the grammar of the enabled kernel, the rules the tour left unsaid, and the register of decisions taken while implementing them. |
| `tour.md` | the language explained, as a numbered "learn X in Y minutes". Teaches; does not decide. |
| `examples.md` | eleven complete programs the compiler emits and the Linux gate runs today: a sensor poll that puts concepts, runtime dispatch, a lent arena and declared failures together, seven small algorithms, and correctness-scale fannkuch-redux, Mandelbrot and FASTA workloads. |
| `ROADMAP.md` | the sole authority for open work: phases, dependencies, gates, and the register of work waiting for a trigger. Read it before proposing or scheduling work. |
| `AGENTS.md` | how to work in this repository: the authority order, the commands, and the rules the chassis already keeps. |
| `check.py` | mechanical checks over the live documents, grammar and fixture corpus. Run it after touching any of them. |
| `compiler/ada/` | the Ada 2022 bootstrap compiler: `refine`, its frontend and verified IR, the Linux x86-64 and Darwin arm64 backends and native toolchain paths, and its own test harness. |
| `docs/documents.md` | how `spec.md` and `tour.md` are arranged, where a new rule goes, and what the arrangement is and is not evidence of. Derived; never an authority. |
| `docs/ir.md` | the intermediate representation explained: its structure and rationale, maintained as a derived account of the implementation, never an authority. |
| `docs/notes/` | exploratory design notes, explicitly non-normative and not roadmap commitments; [the formatting API note](docs/notes/printf-alternative.md) is the one so far. |
| `compiler/tests/` | fixtures, in a format that outlives the implementation checking them. |
| `examples/config_parser/` | the complete lexer and recovering parser derived from prototype 2; its executable host and exact input/output oracle live in `compiler/tests/fixtures/runtime/derived-parser`. |
| `examples/derived_containers/` | the complete prototype-3-derived client of the ordinary `core` containers and allocator capabilities; `compiler/tests/fixtures/runtime/derived-containers` supplies its host, status oracle and derivation manifest. |
| `examples/derived_hosted/` | the complete prototype-4-derived log filter, with runtime-selected filters and destinations, complete line reading, retained arguments and explicit delivery retry; its derivation and memory-world oracle live in `compiler/tests/fixtures/runtime/derived-hosted-memory`. |
| `scripts/` | build, test, clean and toolchain commands. Provider-neutral, except `linux-loop.sh`, which drives Apple Container by name. |
| `environments/` | the pinned `linux/amd64` image the local Linux loop builds, and `pins.sh`, the one place a toolchain version or checksum is written. |
| `flake.nix` | `nix develop`, for people who work that way: a shell holding the same pinned toolchain, read from `environments/pins.sh` rather than from nixpkgs. |
| `docs/` | the environments that produce evidence, the agent-facing notes, and the site generator. |
| [`bindings/`](bindings/README.md) | the C binding generator: asks an external Clang for a header's AST and writes Landin bindings, so `refine` never parses C. |
| `highlight/` | the shared lexical scanner and installable Pygments, TextMate, tree-sitter and packages for the major editor families, from VS Code and JetBrains IDEs through Vim, Emacs and Notepad++. |
| `prototype-1-driver.md` | a driver written from an ugly vendor SVD: GPIO, an interrupt-driven DMA UART, a vector table, and not one hand-written bitmask. |
| `prototype-2-parser.md` | a parser that recovers, because a real one must not stop at the first mistake. |
| `prototype-3-containers.md` | a generic container library: growing array, small vector, hash map, arena-backed tree. |
| `prototype-4-app.md` | a hosted application whose shape is decided by its command line, so it cannot be written without runtime dispatch. |

The prototypes are not illustrations. They are the test suite: each was
written to make the specification fail, each ends with the list of
places where it did, and each keeps the wording that turned out wrong
beside its resolution. Between them they have recorded forty-two
findings, including several that reversed a decision.

## Reading it online

Every document here is published as a syntax-highlighted reading copy at
**<https://www.701.dev>** — the tour, the specification, the running examples,
the four prototypes, the roadmap, and the implementation notes. Every
`[NNNN]` citation links to the construct it names, and hovering one shows what
it says.

The site also has an [editor and IDE support guide](https://www.701.dev/editors.html)
with installation paths for the Landin extensions and plugins for Zed, VS
Code and its relatives, Neovim, Vim, Emacs, Helix, Sublime Text, Visual
Studio, JetBrains IDEs, Eclipse, Notepad++, Kate and Nano, plus the Pygments
lexer.

```sh
git clone https://github.com/JanHaan/Landin
```

Canonical hosting is **<https://github.com/JanHaan/Landin>**. git.sr.ht is a
mirror, kept in step by a second push URL on the same remote rather than by a
job.

The exact-revision native acceptance that approved every revision through
0.2.0 was retired with SourceHut. `.github/workflows/gate.yml` replaced it with
a smaller gate, the document checks and the complete corpus on Linux x86-64 in
debug mode, and [`ROADMAP.md`](ROADMAP.md) schedules the targets it does not
run yet. `.github/workflows/determinism.yml` checks that every host emits the
same bytes and `.github/workflows/pages.yml` publishes <https://www.701.dev>;
neither runs a compiler test.
`environments/native-ci/README.md` describes the retired arrangement. To
render:

```sh
./scripts/site.sh              # render, verify, package
```

## Checking

```sh
python3 check.py
```

Keywords standing where names belong, spellings a decision retired,
`when` outside an exit statement, convention markers at call sites,
two declarations of one name in one module, `end` closing nothing,
citations pointing at constructs that do not exist. It resolves the
files next to itself, so it runs from anywhere.

It is not a parser and does not pretend to be one. It is the set of
invariants that are cheap to check and tedious to re-check by hand,
and it found most of what the last several revisions fixed. Every rule
that can be checked cheaply belongs in it, and so does every defect it
missed once.

## Where the history is

The design was argued out over a long sequence of numbered revisions,
four prototypes and two outside reviews, and that archive is kept
separately — the conversation, the review, the implementation handoff
and the full revision log. Nothing here depends on it.

What was worth carrying came along: the tour's closing
section, WHAT WAS TRIED AND DROPPED, keeps
the reversals, the things that were designed and then taken out again,
because a reader who does not know them will propose them back.

## Building

```sh
export LANDIN_GNAT_HOME=...      # the pinned GNAT, see compiler/ada/TOOLCHAIN.md
export LANDIN_GPRBUILD_HOME=...  # the pinned GPRbuild

./scripts/build.sh
./scripts/test.sh
```

On macOS, use `./scripts/dev-test.sh --host` for compiler checks and add an
exact `--suite` or `--case` selector while editing. Every selected case must
pass. Run Linux workloads and GDB in native Linux development slots; run Darwin
workloads and LLDB natively on the Mac. The unfiltered harness includes Linux
execution and cannot supply a successful Mac compiler-host result.
See [the development and validation workflow](docs/process.md).

For checksum-safe focused feedback during an edit, use
`./scripts/dev-test.sh --suite=NAME`, `--case=SUITE/NAME`, or
`--fixture=CLASS/NAME`. These runs say `FILTERED`; the no-argument command
above remains the complete suite.

On a nix machine, `nix develop` puts the pinned toolchain on `PATH` for you.

`refine --identify` will tell you what it is. Giving it one or more `.ldn`
files runs the frontend, lowering and verification over them as one module.
Without `--emit` an accepted program deliberately writes no output file;
`--emit=asm -o program.s` writes assembly for the selected target (Linux by
default; `--target=darwin-arm64` selects native Mac output), and `--emit=exe -o
program` assembles and links a hosted executable when the target toolchain and
[1970]'s entry point are present. A program it refuses gets a report with a
span, a caret and a note. If what you wrote is a construct the tour describes
and the kernel omits, the note names the paragraph that describes it and says
whether the form is a recorded boundary, withdrawn or transferred to a
successor.

## What comes next

Implementation proceeds in executable vertical slices rather than waiting for
every design foundation to be settled in advance. The compiler builds on Linux
x86-64 and macOS arm64, and the pinned container remains available for
explicit environment troubleshooting. What it does today, by capability:

- **The language.** Functions, aggregates and variants, block-valued control
  flow, lexical `defer` and failure-only `undo`, declared errors, every loop
  and literal family, the enabled scalar conversions, range subtypes and
  `unchecked` regions. Generics take fixed parameters by compile-time
  substitution; concepts carry a whole-program conformance register; one
  evidence table serves both static calls and `any C`. Pointers and slices
  get local origin, borrow, `escaping`, `from` and consume checks. Directory
  modules have file-local imports, aliases, selected imports, typed global
  options and ordered roots. D227's memory model supplies scalar atomics,
  volatile accesses and barriers, and D228 packed register images with
  checked encoded fields. `compiler/tests/constructs.matrix` records every
  normative construct's state, targets and evidence, and `check.py` refuses a
  stale or unexplained row.
- **The library.** `core` threads heap, arena, pool and failing allocators as
  capabilities and builds on them `core/mem`, vectors, small vectors, maps,
  trees, sorting, byte-oriented and validated text, interchangeable system and
  memory I/O worlds, `core/region` for bulk cleanup and the `any`-dispatched
  `core/diag.log`. D212 withdraws the former builtin arena syntax in favour of
  those allocators. A freestanding slice adds CPU support, nonreturning
  signatures and panic dispatch for firmware.
- **The C boundary.** The C ABI of each hosted target, `layout(c)`, callbacks
  and variadic calls, with [`bindings/`](bindings/README.md) generating
  bindings from an external Clang's view of a header. Unsupported C forms are
  refused by name.
- **Targets.** Linux x86-64 and Darwin arm64 build and run hosted executables;
  Darwin keeps an explicit large-image loader limitation. Cortex-M0 builds
  ARMv6-M firmware with compiler-owned reset, data and RAM-code copying, BSS
  clearing, typed interrupt and naked functions, vector references, placement
  and fixed assembly, within a 32 KiB flash, 16 KiB RAM and 4 KiB stack
  profile, and runs it on the pinned QEMU and Renode
  [emulators](environments/cortex-m/README.md). Thirty RP2040 registers are
  checked in as [generated device fixtures](devices/README.md).
- **Code generation.** Target code and the build report are byte-identical
  whatever the build directory, environment or order, on all three targets;
  the hosted linked image is not claimed. Compact numeric-array loops,
  explicit `layout(optimal)` placement and optional evidence-proved
  specialization are independent switches.
- **Debugging.** DWARF and GDB on Linux, LLDB with dSYM and exact Mach-O
  identity on Darwin, and line and function debugging on Cortex-M0. Debug
  provenance stays independent of DWARF for a possible future PDB emitter; PDB
  is not implemented.
- **Derived programs.** Prototypes 2, 3 and 4 run as the recovering
  configuration parser, the container client and the log filter on Linux and
  macOS, with native debugging coverage, and prototype 1 runs as the
  [derived driver](compiler/tests/driver/DERIVATION.md) on the Cortex-M0
  emulators, each against a generated oracle.

Exact-revision runtime acceptance ran natively on Linux x86-64 and Darwin
arm64 through 0.2.0; the Linux gate runs the corpus today, and Darwin and
Cortex-M results come from native runs nothing automates. The recorded
boundaries stand as measured: the 32 KiB capacity verdicts, the
lines-and-functions Cortex-M debugging contract, the end-to-end
evidence-provenance gap and the Darwin shared-region placement limit.

`refine --debug=full --emit=exe program.ldn -o program` requests Linux source
debugging. The default is `--debug=none`; debugging metadata is independent of
the program's optimization and source build-mode settings. Add
`--target=darwin-arm64` for native macOS output, then open `lldb ./program`.
See [source debugging and identity](docs/targets.md#native-source-debugging).

D209--D211 specify compact numeric-array arithmetic, explicit optimal field
placement and optional evidence-proved specialization. The driver selects
size/auto by default; `--optimize=none --specialize=off` selects the reference,
and `--build-report=PATH` requests deterministic off-target JSON. Build mode
remains independent. `./scripts/quality.sh` measures the objects a built
compiler produces.

Language and architecture questions are resolved when the first vertical
slice needs them.

The first compiler milestone was a complete derived version of the parser
prototype with useful diagnostics, evidence-table dispatch, and `any`;
specialization was explicitly not part of it. Target work then proceeded
through the complete hosted Linux x86-64 path, native macOS arm64, and
emulator-first Cortex-M.

The first roadmap closed there, with the slice feature-complete pre-v1.
Feature-complete pre-v1 is a claim about coverage and nothing else. The
current roadmap starts where it stopped; a build tool, package acquisition,
release versioning and self-hosting stay outside it. No version or release
designation changes automatically.

**Next roadmap item: R8.30 — Run every existing target in the gate (planned).**

## License

Copyright (c) 2026 Jan Haan. `MIT OR Apache-2.0`: use this under either
[the MIT license](LICENSE-MIT) or [the Apache License, Version
2.0](LICENSE-APACHE), at your option. [`LICENSE`](LICENSE) says which file
governs what.

What `refine` produces is not a derivative work of `refine`. Compiling a
program places no licensing condition on that program, and neither does
linking `core/*` into it — which is the point of a language that has to fit
in 32 KB of somebody else's flash.
