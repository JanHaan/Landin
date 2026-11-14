# Landin

> Ada, but small. Zig, but sweeter. One systems language from 32 KB to
> 32 TB*. Move fast, keep the pointers, and let the compiler tell you
> when you are being an idiot.

**Status: specification 0.2.9. Landin programs build and run on Linux,
macOS and FreeBSD, and firmware builds for Cortex-M, RV32 and windowed Xtensa.**

The language is pre-v1 and still growing. Its compiler, `refine`, runs
programs on Linux (x86-64, arm64 and RV64), FreeBSD (x86-64 and arm64) and
macOS (arm64), and builds firmware for Cortex-M, 32-bit RISC-V and windowed
Xtensa.
[Current compiler capabilities](#current-compiler-capabilities) lists what
works today.

## What Landin is

Landin is a systems programming language with its compiler and a small
standard library, all designed and built from scratch. It is named after
Peter Landin, who coined the term *syntactic sugar* and wrote *The Next 700
Programming Languages* in 1966 — this one is the 701st.

Landin has one target range and the same way of writing code across all of
it. A Cortex-M0 with 32 KB of flash is at one end, and a hosted desktop
application is at the other. This is what it is like to write:

- **Manual memory.** Arenas are the idiom, and you pass allocators in as
  arguments. There is no garbage collector, no reference counting and no
  destructors.
- **Failures in the signature.** A function declares what can go wrong as a
  set of atoms. A caller handles them with `else` or passes them on with
  `try`.
- **Useful local checks, not a borrow checker.** Pointers and slices get
  origin and escape checks within a function. The language does not claim
  memory safety: it is deliberately unsafe, with useful local checks.
- **Generic code through concepts,** dispatched statically or at run time
  through `any`.
- **No macros and no compile-time execution.**
- **Native code from its own backends,** handed to the platform's assembler
  and linker.

## Installing

`refine` is one executable, with its standard library in a directory
beside it. There are three ways to get both: from a release, with nix, or
from source.

Use 0.2.9 or later: [the first program](#your-first-program) needs
`refine run` and `hosted/blocking`, both newer than 0.2.8.

### From a release

The archive for your platform on
[the releases page](https://github.com/JanHaan/Landin/releases) holds
`bin/refine` and the library under `lib/landin`, with no top-level
directory. Unpack it into a directory of its own and put its `bin` on your
`PATH`.

A Linux archive's `refine` is linked against glibc and asks for the
system's standard loader, `/lib64/ld-linux-x86-64.so.2` on x86-64. On
NixOS or a musl distribution, install with nix or build from source.

The archive leaves the compiler's debug information out and publishes it
beside it as `landin-VERSION-PLATFORM-debug.tar.gz`. You need that file
only to read a crash of the compiler itself.

### With nix

This command builds `refine` from source and puts it on your `PATH`. The
first build also fetches the pinned toolchain, which takes a few minutes:

```sh
nix --extra-experimental-features 'nix-command flakes' \
    profile install github:JanHaan/Landin
```

You can leave the `--extra-experimental-features` option out once
`experimental-features = nix-command flakes` is in `~/.config/nix/nix.conf`.
In a clone, `nix build .#refine` builds the same into `result/`.

### From source

On Linux x86-64, Linux arm64 or a Mac, you can fetch the pinned GNAT and
GPRbuild and build from a clone. Any other host needs nix.

`environments/pins.sh` holds the versions, URLs and SHA-256 sums of GNAT
and GPRbuild. Its `landin_install_toolchain` downloads both archives and
checks each against its sum. The archives are about 500 MB together.

You need these tools first:

- `curl`, `sha256sum` and `tar` for `landin_install_toolchain`;
- `python3` and `git` for the build;
- on a Mac, Xcode's command-line tools as well.

```sh
git clone https://github.com/JanHaan/Landin
cd Landin
. environments/pins.sh
landin_install_toolchain "$HOME/landin-toolchain" x86_64-linux
export LANDIN_GNAT_HOME="$HOME/landin-toolchain/gnat-$LANDIN_GNAT_VERSION"
export LANDIN_GPRBUILD_HOME="$HOME/landin-toolchain/gprbuild-$LANDIN_GPRBUILD_VERSION"
./scripts/build.sh --compiler-only
```

These commands name `x86_64-linux`. Name `aarch64-linux` on Linux arm64
instead, and `aarch64-darwin` on a Mac.

The build prints where it put `refine`. On Linux x86-64 that is
`compiler/ada/build/linux-amd64/debug/bin/refine`, where `linux-amd64` is
the build tag that keeps each host's objects apart.

That is the debug build, which keeps the compiler's own internal checks
on. `LANDIN_BUILD_MODE=release` builds the faster release one beside it.

This `refine` reads the clone's library, so put its directory on your
`PATH` rather than copying it elsewhere.

### The linker on Linux and macOS

Linking on Linux uses GCC as the linker driver, even when the program
links no C library. `refine run` links, so it needs GCC too. The GCC is
the one your distribution installs. `refine` looks for it under these
names, in this order, and runs the first one it can start, so any one of
them is enough:

- `x86_64-pc-linux-gnu-gcc`, the name a GCC built from its own sources
  takes;
- `x86_64-linux-gnu-gcc`, on Debian and Ubuntu;
- `x86_64-redhat-linux-gcc`, on Fedora;
- `gcc`, which `nix-shell -p gcc` provides on NixOS.

On an arm64 machine the names are `aarch64-linux-gnu-gcc`,
`aarch64-redhat-linux-gcc`, `aarch64-unknown-linux-gnu-gcc` and `gcc`, in
that order. `--toolchain=NAME` names a driver yourself, and then `refine`
tries that one alone.

Without one, `refine` names each driver it looked for, in the same order,
and says what to install. Checking, formatting, the
language server and emitting assembly or the intermediate representation
(IR) need none.

macOS links through the Xcode command-line tools.

### Checking the install

Run `refine version`. It names the compiler: a release, or
`refine dev (01234567)` for a build from a clone. Its `library: ` line
names the directory the standard library is read from: the archive's
`lib/landin`, or the clone.

## Your first program

With `refine` installed, make a directory for the program and go into it:

```sh
mkdir hello
cd hello
```

Save this there as `main.ldn`:

```landin
import core/io
import hosted/blocking

public main: () -> (code: i32) =
    host := blocking.new()
    io.write(host, io.out(host), "Hello, world!\n") else none
    code = 0
end main
```

Run it:

```sh
refine run main.ldn
```

It prints

```text
Hello, world!
```

`refine run` compiles the program into a private temporary directory, runs
it, exits with its status and removes the directory. To keep the
executable, compile it instead; the executable prints the same line:

```sh
refine compile main.ldn -o hello
./hello
```

`blocking.new()` is the program's handle on the operating system, and
`io.write` writes through it. Writing can fail; `else none` says that here
it does not matter. [The tour](tour.md) starts from this program and
explains each line.

### When a check stops your program

A failed check stops the program and prints its place. An index past the
end of an array, for example, prints `main.ldn:4:12: trap: out_of_range`.
The shell then reports an illegal instruction, or on some systems a trace
trap, with a status above 128. That is the check stopping the program, not
the compiler crashing.

## What to read next

| read | for |
| --- | --- |
| [The tour](tour.md) | the language, from this program up, one numbered entry at a time |
| [`examples.md`](examples.md) | complete programs to copy, compile and run |
| [Landin for C programmers](docs/from-c.md) | the Landin form of each C habit you bring |
| [The library reference](docs/library.md) | every public module of `core`, `hosted` and `platform`, with examples |
| [Editor support](highlight/README.md) | highlighting and the language server for Zed, VS Code, Neovim, Emacs, JetBrains IDEs and more |

All of them are also published as reading copies at
<https://www.701.dev>, where every `[NNNN]` citation links to the construct
it names.

## refine in brief

| command | what it does |
| --- | --- |
| `refine check main.ldn` | check a whole program, writing nothing |
| `refine run main.ldn -- ARGS` | compile, run and remove a program, exiting with its status |
| `refine compile main.ldn -o prog` | compile and link an executable |
| `refine compile --debug=full ...` | include source debugging for GDB or LLDB |
| `refine compile --target=linux-arm64 ...` | compile for another target; `refine targets` lists them |
| `refine fmt main.ldn` | rewrite a source in the one layout; `--check` only reports |
| `refine explain L0301` | explain a diagnostic code and what to change. It also explains a numbered paragraph of the tour or `spec.md`, `[1760]`, or a decision recorded in `spec.md`, `D275`, which it reads from the `citations.txt` installed with the library |
| `refine site prog SITE` | name the source line and the failed check of the panic site a program's handler received, from the table `--panic-map` writes beside it |
| `refine lsp` | the language server an editor starts |
| `refine svd --policy=P.json --out-dir=DIR CHIP.svd` | generate a chip's register modules and interrupts from its SVD (System View Description); see [devices](devices/README.md) |
| `refine bindings --clang=clang-19 ... api.h` | generate Landin bindings and C adapters for C headers; see [bindings](bindings/README.md) |
| `refine version` | name the compiler and the library it uses |
| `refine --help`, `refine compile --help` | every command, and one command's options |

`refine help reference` prints the complete interface, and
[the command line](docs/capabilities.md#the-command-line) describes it.

## Current compiler capabilities

This section is a summary. [What refine does today](docs/capabilities.md)
is the full inventory.

### Targets

The tables say what `refine` builds for each target and how the gate runs
it. Every push runs the gate; see
[Building and checking](#building-and-checking).

Hosted targets:

| target | builds | runs in the gate |
| --- | --- | --- |
| Linux x86-64, Linux arm64 | hosted executables | natively, with GDB |
| Linux RV64 | hosted executables | under QEMU's user emulation, with GDB |
| macOS arm64 | hosted executables | natively, with LLDB |
| FreeBSD x86-64 and arm64 | hosted executables, emitted on Linux | in FreeBSD VMs, with LLDB |

Firmware targets:

| target | builds | on boards | runs in the gate |
| --- | --- | --- | --- |
| Cortex-M | boot or RAM firmware for the device description it imports, or for the reference firmware profile of 32 KiB flash and 16 KiB RAM | RP2040, RP2350 and STM32H753, whose Cortex-M7 uses its float unit and caches | under the pinned QEMU, with GDB |
| Xtensa | firmware at `xtensa-esp32` (LX6, default) or `xtensa-esp32s3` (LX7) | ESP32 and ESP32-S3 | under Espressif's QEMU |
| RV32 | firmware at `rv32imc` or `rv32imac` for the device description it imports, or within the same reference's capacities | ESP32-C3, ESP32-C5 and RP2350 Hazard3 | under Espressif's QEMU |

[What refine does today](docs/capabilities.md#targets) says what each board
run records and what the gate checks for each target.

### Language, library and tooling

- **The enabled language:** functions, aggregates and variants, declared
  failures with `else` and `try`, `defer` and `undo`, generics and concepts
  with static or `any` dispatch, local origin and escape checks, directory
  modules, atomics, volatile access and packed register images, and
  stackful fibres on every native target.
- **The library:** `core` modules of allocators, containers, text, I/O,
  time, networking, random numbers and atomic cells, each provider with a
  fake for testing, and `hosted` providers over POSIX, among them threads
  started as a group a function joins. A Linux executable links no C
  library unless `--link=libc` asks for one.
- **The C boundary:** each hosted target's C ABI, packed and flexible
  records, callbacks and variadic calls, Cortex-M's AAPCS32 with its float
  unit's variant, without variadic calls, and `refine bindings`, a binding
  generator over Clang.
- **Code generation:** byte-identical output on every target whatever the
  build environment; register allocation, inlining and simplification at
  speed; and only the functions a program reaches are emitted.
  [The Benchmark Game, measured](docs/benchmarks.md) compares five ports
  with seven other languages.
- **Tooling:** source debugging on every target, a formatter, a language
  server, explained diagnostics with fixes, stack-depth reports, and
  `refine site`, which turns a panic site into its source line.

## The roadmap

[`ROADMAP.md`](ROADMAP.md) is the sole authority for open work. In short:

- **The first roadmap** built the enabled language, hosted Linux, native
  macOS and Cortex-M firmware. It closed with the pre-v1 language
  feature-complete, a claim about coverage and nothing else.
- **The current roadmap** takes the compiler to an editor, more targets,
  the microcontrollers people buy, concurrency and optimization. A build
  tool, package acquisition, release versioning and self-hosting stay
  outside it.

**Next roadmap item: R13.90 — Supply a concept through a field (planned).**

## Questions, bugs and ideas

Ask questions, report bugs and friction, and propose ideas or changes to
the language in
[Discussions](https://github.com/JanHaan/Landin/discussions). Each
category's form says what a report needs.

- A typo, a mistake in the documentation, a refusal that did not help or
  an idea each get a thread of their own.
- Put suggestions for the next roadmap in
  [its standing thread](https://github.com/JanHaan/Landin/discussions/2).
- Report a security vulnerability privately, through
  [GitHub's private reporting](https://github.com/JanHaan/Landin/security/advisories/new),
  and never in a discussion.

The repository has no issue tracker: a discussion that leads to work
becomes an item or a register record in `ROADMAP.md`. Everyone taking part
follows the [code of conduct](CODE_OF_CONDUCT.md).

## Working on Landin

[`AGENTS.md`](AGENTS.md) is the guide to working in this repository, for
people and agents alike. It holds the order of authority among the
documents, every command, the continuous-integration (CI) gate and the
rules the compiler keeps.

[The validation workflow](docs/process.md) explains the edit, test and push
loop.

Feedback goes to GitHub Discussions, as
[Questions, bugs and ideas](#questions-bugs-and-ideas) describes. If you
propose a change there, say which checks cover it: `python3 check.py` for
documentation, or the focused tests the workflow describes for code.

### What is in the repository

| path | what it is |
| --- | --- |
| `tour.md` | the language explained, as a numbered "learn X in Y minutes". Teaches; does not decide. |
| `spec.md` | the normative specification: the grammar of the enabled language, the rules the tour left unsaid, and the register of decisions. |
| `handoff.md` | the design in one page, and which decisions must not be quietly reversed. |
| `ROADMAP.md` | the sole authority for open work: phases, dependencies, gates, and the register of work waiting for a trigger. |
| `examples.md` | complete programs, each printing what it computes; the gate runs every one. |
| `prototype-*.md` | the five design stress tests; see [The prototypes](#the-prototypes). |
| `compiler/ada/` | [the Ada 2022 bootstrap compiler](compiler/ada/README.md): `refine`, its frontend, verified IR, native backends and test harness. |
| `compiler/tests/` | [the fixtures](compiler/tests/README.md), in a format that outlives the implementation checking them. |
| `core/`, `hosted/`, `platform/` | the standard library. |
| `docs/` | derived guides, never authorities: [the documents' arrangement](docs/documents.md), [diagnostics](docs/diagnostics.md), [formatting](docs/format.md), [the language server](docs/server.md), [the IR](docs/ir.md), [target contracts](docs/targets.md), [environments](docs/environments.md), and non-normative [design notes](docs/notes/printf-alternative.md). |
| `examples/` | the programs derived from prototypes 2, 3, 4 and 5: [`config_parser/`](examples/config_parser/), [`derived_containers/`](examples/derived_containers/), [`derived_hosted/`](examples/derived_hosted/) and [`derived_server/`](examples/derived_server/). |
| [`bindings/`](bindings/README.md) | `refine bindings`' policy, its tests and its documentation. The C binding generator asks an external Clang for a header's AST (abstract syntax tree), so the compiler never parses C. |
| [`highlight/`](highlight/README.md) | highlighting and editor packages, from VS Code and JetBrains IDEs through Vim, Emacs and Notepad++. |
| `environments/` | `pins.sh`, the one place a toolchain version or checksum is written, and the environments that produce evidence. |
| `scripts/`, `check.py`, `flake.nix` | build, test and check commands, and `nix develop`. |

### The prototypes

The five `prototype-*.md` files are not tutorials and not example programs.
Each was written before the compiler could do what it asks, in order to
make the specification fail. Each ends with its findings, and keeps the
wording that turned out wrong beside its resolution. The prototypes are
sketches that leave bodies out with `...`; what runs is derived from them.

| prototype | what it presses on | what runs |
| --- | --- | --- |
| `prototype-1-driver.md` | a Cortex-M driver from a vendor SVD: registers, DMA (direct memory access), interrupts, a vector table | [the derived driver](compiler/tests/driver/DERIVATION.md) |
| `prototype-2-parser.md` | a parser that recovers from errors rather than stopping at the first | `examples/config_parser/` |
| `prototype-3-containers.md` | generic containers, allocators, escape rules | the `core` containers and `examples/derived_containers/` |
| `prototype-4-app.md` | a hosted application chosen by its command line: runtime dispatch | `examples/derived_hosted/` |
| `prototype-5-server.md` | a server with two requests in flight, and a Cortex-M0 counterpart answering them on one core: fibres, started as a group | `examples/derived_server/` and [the firmware counterpart](compiler/tests/counterpart/DERIVATION.md) |

### Building and checking

```sh
nix develop                  # or set LANDIN_GNAT_HOME and LANDIN_GPRBUILD_HOME
./scripts/build.sh           # the compiler and its test program
./scripts/test.sh            # the complete suite, on Linux
./scripts/dev-test.sh --suite='fixture execution'   # a FILTERED run while editing
python3 check.py             # the mechanical checks over documents and fixtures
```

`check.py` is not a parser. It is the set of invariants that are cheap to
check and tedious to re-check by hand, and every defect it missed once
belongs in it.

Every push runs [the gate](AGENTS.md#the-mechanical-gate), which tests
every target in separate jobs. The gate is a safety net, not a verdict on a
revision.

[The site](https://www.701.dev) is rendered from these files by
`./scripts/site.sh` and published only from `main`; see
[the site guide](docs/site/README.md). GitHub is canonical, and
git.sr.ht is a mirror.

### Where the history is

The design was argued out over a long sequence of numbered revisions, the
prototypes and two outside reviews. That archive is kept separately, and
nothing here depends on it.

What was worth carrying came along. The tour's closing section, WHAT WAS
TRIED AND DROPPED, keeps the things that were designed and then taken out
again, because a reader who does not know them will propose them back.

The exact-revision acceptance that approved every revision through 0.2.0
[is retired](environments/native-ci/README.md).

## License

Copyright (c) 2026 Jan Haan. `MIT OR Apache-2.0`: use this under either
[the MIT license](LICENSE-MIT) or [the Apache License, Version
2.0](LICENSE-APACHE), at your option. [`LICENSE`](LICENSE) says which file
governs what.

What `refine` produces is not a derivative work of `refine`. Compiling a
program places no licensing condition on that program, and neither does
linking `core/*` into it — which is the point of a language that has to fit
in 32 KB of somebody else's flash.

*32 TB is an unverified goal. What it measures at the hosted end, and what
evidence would prove it, are still open, and nothing hosted today
establishes it. Terabytes may vary.
