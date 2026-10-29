# Landin

> Ada, but small. Zig, but sweeter. One systems language from 32 KB to
> 32 TB*. Move fast, keep the pointers, and let the compiler tell you
> when you are being an idiot.

**Status: specification 0.2.8. Landin programs build and run on Linux,
macOS and FreeBSD, and firmware builds for Cortex-M0.**

`refine`, Landin's compiler, builds and runs programs on Linux (x86-64,
arm64 and RV64), FreeBSD (x86-64 and arm64) and macOS (arm64), and builds
firmware for Cortex-M0. The language is pre-v1 and still growing, and
[Current compiler capabilities](#current-compiler-capabilities) lists what
works today.

## What Landin is

A systems programming language, its compiler and a small standard
library, designed and built from scratch. Named after Peter Landin, who
coined the term *syntactic sugar* and wrote *The Next 700 Programming
Languages* in 1966 — this one is the 701st.

One target range, and the same way of writing code across all of it: a
Cortex-M0 with 32 KB of flash at one end, a hosted desktop application
at the other. What it is like to write:

- **Manual memory.** Arenas are the idiom, and allocators are passed in as
  arguments. There is no garbage collector, no reference counting and no
  destructors.
- **Failures in the signature.** A routine declares what can go wrong as a
  set of atoms; a caller handles them with `else` or passes them on with
  `try`.
- **Useful local checks, not a borrow checker.** Pointers and slices get
  origin and escape checks within a routine. The language does not claim
  memory safety: it is deliberately unsafe, with useful local checks.
- **Generic code through concepts,** dispatched statically or at run time
  through `any`.
- **No macros and no compile-time execution.**
- **Native code from its own backends,** handed to the platform's assembler
  and linker.

## Installing

`refine` is one executable, with its standard library in a directory
beside it. There are three ways to get both.

**From a release.** The archive for your platform on
[the releases page](https://github.com/JanHaan/Landin/releases) holds
`bin/refine` and the library under `lib/landin`, with no top-level
directory. Unpack it into a directory of its own and put its `bin` on your
`PATH`. The archives of 0.2.7 and earlier hold `refine` alone, without its
library, and cannot build the first program below.

**With nix.** This builds `refine` from source and puts it on your `PATH`;
the first build also fetches the pinned toolchain, which takes a few
minutes:

```sh
nix --extra-experimental-features 'nix-command flakes' \
    profile install github:JanHaan/Landin
```

The `--extra-experimental-features` option is not needed once
`experimental-features = nix-command flakes` is in `~/.config/nix/nix.conf`.
In a clone, `nix build .#refine` builds the same into `result/`.

**From source.** On Linux x86-64, Linux arm64 or a Mac, fetch the pinned
GNAT and GPRbuild and build from a clone. `environments/pins.sh` holds
their versions, URLs and SHA-256 sums, and its `landin_install_toolchain`
downloads both archives and checks each against its sum. It needs `curl`, `sha256sum` and `tar`, and the build needs `python3`
and `git`:

```sh
git clone https://github.com/JanHaan/Landin
cd Landin
. environments/pins.sh
landin_install_toolchain "$HOME/landin-toolchain" x86_64-linux
export LANDIN_GNAT_HOME="$HOME/landin-toolchain/gnat-$LANDIN_GNAT_VERSION"
export LANDIN_GPRBUILD_HOME="$HOME/landin-toolchain/gprbuild-$LANDIN_GPRBUILD_VERSION"
./scripts/build.sh --compiler-only
```

Name `aarch64-linux` on Linux arm64, and `aarch64-darwin` on a Mac, which
also needs Xcode's command-line tools; any other host needs nix. The
archives are about 500 MB together. The build prints where it put `refine`,
`compiler/ada/build/linux-amd64/debug/bin/refine`: the debug build, which
keeps the compiler's own internal checks on.
`LANDIN_BUILD_MODE=release` builds the faster release one beside it. That
`refine` uses the clone's own library, so leave it where it is and put its
directory on your `PATH`.

**Linking on Linux** needs a C compiler driver: the GCC your distribution
installs, `x86_64-linux-gnu-gcc` on Debian and Ubuntu,
`x86_64-redhat-linux-gcc` on Fedora, or `gcc`, which `nix-shell -p gcc`
provides on NixOS. Without one, `refine` says what to install; checking,
formatting, the language server and emitting assembly or IR need none.
macOS links through the Xcode command-line tools.

**To check the install,** run `refine version`. It names the compiler, a
release or `refine dev (01234567)` for a build from a clone, and its
`library: ` line names the directory the standard library is read from:
the archive's `lib/landin`, or the clone.

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

Compile and run it:

```sh
refine compile main.ldn -o hello
./hello
```

It prints

```text
Hello, world!
```

`blocking.new()` is the program's handle on the operating system, and
`io.write` writes through it. Writing can fail; `else none` says that here
it does not matter. [The tour](tour.md) starts from this program and
explains each line.

A failed check stops the program with its place: an index past the end of
an array, for example, prints `main.ldn:4:12: trap: out_of_range`. The
shell then reports an illegal instruction, or on some systems a trace
trap, with a status above 128. That is the check stopping the program, not
the compiler crashing.

## Next steps

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
| `refine compile main.ldn -o prog` | compile and link an executable |
| `refine compile --debug=full ...` | include source debugging for GDB or LLDB |
| `refine compile --target=linux-arm64 ...` | compile for another target; `refine targets` lists them |
| `refine fmt main.ldn` | rewrite a source in the one layout; `--check` only reports |
| `refine explain L0301` | explain a diagnostic code and what to change |
| `refine lsp` | the language server an editor starts |
| `refine version` | name the compiler and the library it uses |
| `refine --help`, `refine compile --help` | every command, and one command's options |

`refine help reference` prints the complete interface, and
[the command line](docs/capabilities.md#the-command-line) describes it.

## Current compiler capabilities

[What refine does today](docs/capabilities.md) is the full inventory. In
short:

| target | builds | runs in the gate |
| --- | --- | --- |
| Linux x86-64, Linux arm64 | hosted executables | natively, with GDB |
| Linux RV64 | hosted executables | under QEMU's user emulation, with GDB |
| macOS arm64 | hosted executables | natively, with LLDB |
| FreeBSD x86-64 and arm64 | hosted executables, emitted on Linux | in FreeBSD VMs, with LLDB |
| Cortex-M0 | firmware within 32 KiB flash and 16 KiB RAM | under the pinned QEMU, with GDB |

- **The language kernel:** functions, aggregates and variants, declared
  failures with `else` and `try`, `defer` and `undo`, generics and concepts
  with static or `any` dispatch, local origin and escape checks, directory
  modules, atomics, volatile access and packed register images, and
  stackful fibres on every native target.
- **The library:** nineteen `core` modules of allocators, containers, text,
  I/O, time, networking and random numbers, each service with a fake for
  testing; `hosted` services over POSIX; and Linux executables with no C
  library by default.
- **The C boundary:** each hosted target's C ABI, packed and flexible
  records, callbacks and variadic calls, and a binding generator over Clang.
- **Code generation:** byte-identical output on every target whatever the
  build environment; register allocation, inlining and simplification at
  speed; and only the routines a program reaches are emitted.
  [The Benchmark Game, measured](docs/benchmarks.md) compares five ports
  with seven other languages.
- **Tooling:** source debugging on every target, a formatter, a language
  server, explained diagnostics with fixes, and stack-depth reports.

## What comes next

The first roadmap built the language kernel, hosted Linux, native macOS
and Cortex-M firmware, and closed with the slice feature-complete pre-v1,
which is a claim about coverage and nothing else. The current roadmap
takes the compiler to an editor, more targets, the microcontrollers people
buy, concurrency and optimization; a build tool, package acquisition,
release versioning and self-hosting stay outside it.
[`ROADMAP.md`](ROADMAP.md) is the sole authority for open work.

**Current roadmap work: R14.40 — Threads and the atomic wrapper.**

## Questions, bugs and ideas

Ask questions, report bugs and friction, and propose ideas or changes to the
language in [Discussions](https://github.com/JanHaan/Landin/discussions);
each category's form says what a report needs. The repository has no issue
tracker: a discussion that leads to work becomes an item or a register
record in `ROADMAP.md`. Report a security vulnerability privately, through
[GitHub's private reporting](https://github.com/JanHaan/Landin/security/advisories/new),
and never in a discussion. Everyone taking part follows the
[code of conduct](CODE_OF_CONDUCT.md).

## Working on Landin

[`AGENTS.md`](AGENTS.md) is the guide to working in this repository, for
people and agents alike: the order of authority among the documents, every
command, the CI gate and the rules the compiler keeps.
[The validation workflow](docs/process.md) explains the edit, test and push
loop.

### What is here

| path | what it is |
| --- | --- |
| `tour.md` | the language explained, as a numbered "learn X in Y minutes". Teaches; does not decide. |
| `spec.md` | the normative specification: the grammar of the enabled kernel, the rules the tour left unsaid, and the register of decisions. |
| `handoff.md` | the design in one page, and which decisions must not be quietly reversed. |
| `ROADMAP.md` | the sole authority for open work: phases, dependencies, gates, and the register of work waiting for a trigger. |
| `examples.md` | complete programs, each printing what it computes; the gate runs every one. |
| `prototype-*.md` | the five design stress tests; see below. |
| `compiler/ada/` | [the Ada 2022 bootstrap compiler](compiler/ada/README.md): `refine`, its frontend, verified IR, native backends and test harness. |
| `compiler/tests/` | [the fixtures](compiler/tests/README.md), in a format that outlives the implementation checking them. |
| `core/`, `hosted/`, `platform/` | the standard library. |
| `docs/` | derived guides, never authorities: [the documents' arrangement](docs/documents.md), [diagnostics](docs/diagnostics.md), [formatting](docs/format.md), [the language server](docs/server.md), [the IR](docs/ir.md), [target contracts](docs/targets.md), [environments](docs/environments.md), and non-normative [design notes](docs/notes/printf-alternative.md). |
| `examples/` | the programs derived from prototypes 2, 3, 4 and 5: [`config_parser/`](examples/config_parser/), [`derived_containers/`](examples/derived_containers/), [`derived_hosted/`](examples/derived_hosted/) and [`derived_server/`](examples/derived_server/). |
| [`bindings/`](bindings/README.md) | the C binding generator, which asks an external Clang for a header's AST so `refine` never parses C. |
| [`highlight/`](highlight/README.md) | highlighting and editor packages, from VS Code and JetBrains IDEs through Vim, Emacs and Notepad++. |
| `environments/` | `pins.sh`, the one place a toolchain version or checksum is written, and the environments that produce evidence. |
| `scripts/`, `check.py`, `flake.nix` | build, test and check commands, and `nix develop`. |

### The prototypes

The five `prototype-*.md` files are not tutorials and not example programs.
Each was written before the compiler could do what it asks, to make the
specification fail, and ends with its findings, keeping the wording that
turned out wrong beside its resolution. They are sketches that leave bodies
out with `...`; what runs is derived from them.

| prototype | what it presses on | what runs |
| --- | --- | --- |
| `prototype-1-driver.md` | a Cortex-M driver from a vendor SVD: registers, DMA, interrupts, a vector table | [the derived driver](compiler/tests/driver/DERIVATION.md) |
| `prototype-2-parser.md` | a parser that recovers from errors rather than stopping at the first | `examples/config_parser/` |
| `prototype-3-containers.md` | generic containers, allocators, escape rules | the `core` containers and `examples/derived_containers/` |
| `prototype-4-app.md` | a hosted application chosen by its command line: runtime dispatch | `examples/derived_hosted/` |
| `prototype-5-server.md` | a server with two requests in flight, and a Cortex-M0 counterpart answering them on one core: fibres, started as a group | `examples/derived_server/`; the firmware counterpart is not derived yet |

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
belongs in it. Every push runs [the gate](AGENTS.md#the-mechanical-gate),
which tests every target in separate jobs; it is a safety net, not a
verdict on a revision. The exact-revision acceptance that approved every
revision through 0.2.0 [is retired](environments/native-ci/README.md).

[The site](https://www.701.dev) is rendered from these files by
`./scripts/site.sh` and published only from `main`; see
[the site guide](docs/site/README.md). GitHub is canonical, and
git.sr.ht is a mirror.

### Where the history is

The design was argued out over a long sequence of numbered revisions, the
prototypes and two outside reviews, and that archive is kept separately;
nothing here depends on it. What was worth carrying came along: the tour's
closing section, WHAT WAS TRIED AND DROPPED, keeps the things that were
designed and then taken out again, because a reader who does not know them
will propose them back.

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
