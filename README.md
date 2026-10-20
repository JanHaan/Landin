# Landin

> Ada, but small. Zig, but sweeter. One systems language from 32 KB to
> 32 TB*. Move fast, keep the pointers, and let the compiler tell you
> when you are being an idiot.

A systems programming language, its compiler and a small standard
library, designed and built from scratch. Named after Peter Landin, who
coined the term *syntactic sugar* and wrote *The Next 700 Programming
Languages* in 1966 — this one is the 701st.

One target range, and the same way of writing code across all of it: a
Cortex-M0 with 32 KB of flash at one end, a hosted desktop application
at the other.

**Status: specification 0.2.7. The compiler can build and run Landin programs
for Linux x86-64, Linux arm64, Linux RV64, FreeBSD x86-64 and arm64, and
native macOS arm64, and builds firmware for
Cortex-M0. It handles functions, user-defined data types, generic
routines, pointers, errors, control flow, modules, evidence-table dispatch and
`any`. Containers, allocators, text and I/O capabilities, a complete
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
| `examples.md` | complete programs to copy, compile and run, each printing what it computes: everyday tools such as a word count, a directory listing and a shell runner, printing values and reporting failures, the classic exercises, and the five Benchmark Game ports. The gate runs every one. |
| `ROADMAP.md` | the sole authority for open work: phases, dependencies, gates, and the register of work waiting for a trigger. Read it before proposing or scheduling work. |
| `AGENTS.md` | how to work in this repository: the authority order, the commands, and the rules the chassis already keeps. |
| `check.py` | mechanical checks over the live documents, grammar and fixture corpus. Run it after touching any of them. |
| `compiler/ada/` | the Ada 2022 bootstrap compiler: `refine`, its frontend and verified IR, the x86-64, arm64 and Cortex-M backends and their toolchain paths, and its own test harness. |
| `docs/from-c.md` | [Landin for C programmers](docs/from-c.md): the Landin form of each C habit, from `#include` to `exit`, and the habits with no answer yet. Its examples are a fixture the test program compiles. Derived; never an authority. |
| `docs/documents.md` | how `spec.md` and `tour.md` are arranged, where a new rule goes, and what the arrangement is and is not evidence of. Derived; never an authority. |
| `docs/diagnostics.md` | [what each diagnostic code means](docs/diagnostics.md) and what to change, the text `refine explain` prints. Derived from the catalogue and the specification; never an authority. |
| `docs/format.md` | [how a source is laid out](docs/format.md): the one layout `refine fmt` gives every source, each rule with a program as written and as formatted. Derived from D252 and the implementation; never an authority. |
| `docs/server.md` | [what the language server answers](docs/server.md): where `refine lsp` places a file, what each request is answered with, and how far it reads past a syntax error. Derived from D253 and the implementation; never an authority. |
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
| `prototype-*.md` | the four design stress tests; see below. Not learning material. |

### The prototypes: design stress tests

The four `prototype-*.md` files are not tutorials and not example
programs. Each was written before the compiler existed, to make the
specification fail: a program that needs a feature presses on the rules
for it until they turn out silent, ambiguous or wrong. Each ends with its
findings, and keeps the wording that turned out wrong beside its
resolution. Between them they recorded forty-two findings, several of
which reversed a decision.

They are sketches: they leave bodies out with `...` and are not programs
you can compile. They are kept in step with the specification so their
findings stay true. What runs is derived from them:

| prototype | what it presses on | what runs |
| --- | --- | --- |
| `prototype-1-driver.md` | a Cortex-M driver from a vendor SVD: registers, DMA, interrupts, a vector table | [the derived driver](compiler/tests/driver/DERIVATION.md) |
| `prototype-2-parser.md` | a parser that recovers from errors rather than stopping at the first | `examples/config_parser/` |
| `prototype-3-containers.md` | generic containers, allocators, escape rules | the `core` containers and `examples/derived_containers/` |
| `prototype-4-app.md` | a hosted application chosen by its command line: runtime dispatch | `examples/derived_hosted/` |

To learn the language, read [the tour](tour.md) and
[the examples](examples.md) instead.

## Reading it online

Selected language documents and guides are published as syntax-highlighted
reading copies at **<https://www.701.dev>** — including the tour, the
specification, the running examples, the four prototypes, the roadmap, and
the implementation notes. The renderer's `DOCS` and `GUIDES` lists define
the selection; see [the site guide](docs/site/README.md). Every
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
0.2.0 was retired with SourceHut. `.github/workflows/gate.yml` replaced it: on
every push it runs every target unless the verified explanatory-only reuse
exception below applies. Full runs cover Linux x86-64, Linux arm64 and macOS
arm64 natively with GDB
and LLDB, FreeBSD x86-64 and arm64 in accelerated VMs, and Cortex-M under
QEMU, both compiler modes, and the
document, binding and editor-grammar checks. Same-run release build artifacts
avoid repeated compilation within each host platform. On a failed Cortex-M job, it is
configured to upload diagnostic output if present and retain it for 14 days;
it retains no successful exact-revision acceptance record and accepts no
revision. The gate calls `.github/workflows/determinism.yml`, which builds the compiler on Linux
x86-64, Linux arm64 and macOS arm64, compiles every positive fixture for every
target in both build modes, and compares emitted assembly digests
across hosts; disagreement fails the aggregate gate. Those manifests come
from debug compilers, so the gate's `build-modes` jobs also require the debug
and release compilers of one tree to emit the same bytes for the positive and
runtime corpora on Linux x86-64, Linux arm64 and Cortex-M. It does not
assemble, link or run those programs. RV64's corpus runs under QEMU's user
emulation in the gate's `rv64-qemu` jobs, while its jobs on physical RISE
runners stay skipped until they are dependable.
`.github/workflows/pages.yml` publishes <https://www.701.dev> when a site
input changes on `main` or when dispatched manually, without running a
compiler test.
The verified explanatory-only remote reuse policy in `AGENTS.md` permits
qualifying edits to reuse a full successful main gate from the preceding
seven days. Document and script checks always run.

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

## Installing

`refine` is one executable, with its standard library in a directory beside
it. With nix, either of these puts `refine` on your `PATH`, the first
building it from source and the second fetching the published executable:

```sh
nix profile install github:JanHaan/Landin
nix profile install github:JanHaan/Landin#refine-bin
```

Without nix, take the archive for your platform from
[the releases page](https://github.com/JanHaan/Landin/releases). Each is
named `landin-VERSION-PLATFORM.tar.gz`, for `x86_64-linux`, `aarch64-linux`
or `aarch64-darwin`, with its SHA-256 sum beside it in a `.sha256` file. An
archive has no top-level directory: it holds `bin/refine`, the library under
`lib/landin` and the three licence files, and puts them in whichever
directory you unpack it into, so make one for it and put its `bin` on your
`PATH`:

```sh
mkdir -p ~/landin
tar -xzf landin-VERSION-PLATFORM.tar.gz -C ~/landin
export PATH="$HOME/landin/bin:$PATH"
refine version
```

For a release, `refine version` prints the release's own version and the
library it found beside itself:

```text
refine VERSION
library: /home/you/landin/lib/landin
```

A compiler built from a checkout says `refine dev (01234567)` instead, the
commit it was built from, with `, dirty` after it when the checkout was
modified; [Building](#building) says how that line is decided.

On Linux, linking an executable also needs a C compiler driver: the `gcc`
your distribution installs, or on NixOS `nix-shell -p gcc`. `refine check`,
`refine fmt`, `refine lsp` and `refine compile --emit=asm` run without one,
and a link that finds none says what to install. macOS links through the
Xcode command-line tools.

Every archive after 0.2.7 is laid out as above. The archives of 0.2.7 and
earlier releases came before the library was shipped: they hold `refine`
alone, and their `refine version` prints only the first line. To build from
source instead, see [Building](#building).

## Your first program

With `refine` installed, save this anywhere as `hello/main.ldn`:

```landin
import core/io
import hosted/system

public main: () -> (code: i32) =
    host := system.new()
    io.write(host, io.out(host), "Hello, world!\n") else none
    code = 0
end main
```

Compile and run it from that directory:

```sh
refine compile main.ldn -o hello
./hello
```

It prints

```text
Hello, world!
```

`system.new()` is the program's handle on the operating system, and
`io.write` writes through it. Writing can fail; `else none` says that here
it does not matter. [The tour](tour.md) starts from this program and
explains each line.

What else to know:

- **The compile leaves only `hello`.** The assembly it links is removed;
  `--keep-asm` keeps it as `hello.s`.
- **Linking needs a C driver.** On Linux that is the GCC your distribution
  installs: `x86_64-linux-gnu-gcc` on Debian and Ubuntu,
  `x86_64-redhat-linux-gcc` on Fedora, or `gcc`, which `nix-shell -p gcc`
  provides on NixOS. Without one, `refine` says what to install.
  `refine check`, `refine fmt`, `refine lsp` and
  `refine compile --emit=asm` or `--emit=ir` need no driver.
- **A failed check stops the program with its place.** An index past the
  end of an array, for example, prints
  `main.ldn:4:12: trap: out_of_range` before the system reports the trap.
- **The standard library comes with `refine`.** `core`, `hosted` and
  `platform` are found beside the executable, so importing them needs no
  option. `refine version` names the directory it uses; a copied `refine`
  that finds none says where it looked and names `--library=DIR`. Your own
  modules are found under the roots you give with `--root` [1480].

Next, read [the tour](tour.md). [`examples.md`](examples.md) has complete
programs to copy. If you write C,
[Landin for C programmers](docs/from-c.md) maps each habit you bring to
its Landin form.

## Building

```sh
export LANDIN_GNAT_HOME=...      # the pinned GNAT, see compiler/ada/TOOLCHAIN.md
export LANDIN_GPRBUILD_HOME=...  # the pinned GPRbuild

./scripts/build.sh
./scripts/test.sh
```

Use `./scripts/build.sh --compiler-only` when only `refine` is needed. The
default build still produces the Ada test program for `scripts/test.sh`.

On macOS, use `./scripts/dev-test.sh --host --target=linux-x86-64` for compiler checks and add an
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

`refine check program.ldn ...` runs the frontend, lowering and verification
on the named sources as one whole program, without writing an artifact.
`refine compile program.ldn -o program` assembles and links an executable;
`refine compile --emit asm program.ldn -o program.s` writes assembly, and
`refine compile program.s -o program` links an assembly file as a compiled
program is linked. `refine compile --emit ir program.ldn -o program.ir`
writes the IR the backend would receive.
The default target is the compiler's own host; cross-compilation names a
`--target`. `build` is reserved for future project orchestration.
Bare source requests and `--emit=asm|exe` remain compatibility spellings.

`refine --help` lists commands. `refine compile --help`, `refine --help
compile` and `refine help compile` give the same command help.
`refine help reference` prints the complete interface, and
`refine completion bash|zsh|fish` prints shell completion definitions from
the same option catalogue. Shared options work before or after the command;
command-specific options follow it, and one written before it is refused
naming the command it belongs to and where it goes. `check` takes every
option that says which program is compiled, `--link`, `--firmware-entry`
and `--build-report` among them, and with `--root` the operand is the entry
module's directory or its source files. Values accept a space or `=`, repeatable
options retain their order, and duplicate single-valued options are refused.
Use `--` before literal operands. `@FILE` expands a bounded response file with
single/double quotes and backslash escapes, without shell expansion.

`refine version` (also `--version`) prints `refine 0.2.7` for an exact release
checkout, or `refine dev (01234567)` for a development commit. A modified
checkout adds `dirty`; a modified release also includes its commit. The
release name comes from an exact numeric `v` tag, independently of debug or
release optimization. Tracked edits anywhere in the checkout and untracked
compiler inputs count as dirty; generated build outputs do not.
`refine version --json` retains the full revision, compiler-input digest,
dirty state, build mode and host triplet, with `version` set to the release
name or `null` for development. The input digest covers compiler sources and
build policy, so a prose edit changes dirty state without changing that digest.
Without Git metadata, the banner identifies the source digest instead.
`refine targets` lists described targets and their CPU feature levels;
`--json` gives structured output. `--identify` retains the older capability
summary.

Shared `--verbose` (or `-v`) describes the compilation request; repeating it
also traces the actual native tool argument vectors. `--quiet` retains
warnings and errors. `--color auto|always|never` controls human diagnostic
color; auto checks standard error's terminal, `NO_COLOR` and `TERM`.
`--diagnostics human|short|json` selects the source report. JSON diagnostics
are schema-versioned newline-delimited objects carrying labels, notes and
fixes; line and byte-column coordinates are one-based, and spans retain the
compiler's byte offsets. Paths also carry a hexadecimal encoding of their
original bytes.

`check` and `compile` accept `--warnings default|all|none` and repeated
`--warn CODE|all`, `--allow CODE|all` and `--deny CODE|all`. The baseline is
applied first; the repeated controls then apply in their written order, with
the last matching control winning. Only live warning codes are accepted.
`--deny all --allow L0326` denies every warning except the unnecessary-`mut`
warning, which it suppresses. Denial returns status 1 before producing
artifacts; ordinary warnings retain status 0 and the same generated bytes.
Quiet mode retains selected diagnostics. Both current warning families are
recommended, so `default` and `all` currently agree; so is L0016, which says
a `--root` holds a module the library supplies instead. A warning can report an
observation without an edit; exact fixes remain available where their edits
preserve meaning and comments.

`refine compile --dry-run` checks and emits in memory, prints planned writes
and tool arguments, and performs no writes or tool executions. Darwin archive
lookup is identified as a deferred step when it requires running a tool.
`--depfile PATH` writes Make-format source dependencies after successful
emission, including observed module-search directories so import membership
changes can cause a rebuild. Keep artifacts and reports outside those
watched directories: creating them there changes directory timestamps and
can cause redundant rebuilds. Paths containing line breaks are refused when
a depfile is requested. A consuming build rule must also track its
compiler and native tool configuration. Build mode, optimization,
specialization and debug information remain independent controls.

A program it refuses gets a report with a
span, a caret and a note, one per mistake and on the token it is about: what
a mistake leaves behind is not reported again, and where one change of a
token mends a line the report says which change and offers it as a fix. A
spelling from another language, such as `elif`, `fn`, `x as i32`, `x++`,
`*u8`, `&&` or `!=`, is refused naming what Landin writes instead. If
what you wrote is a construct the tour describes and the kernel omits, the
note names the paragraph that describes it and says whether the form is a
recorded boundary, withdrawn or transferred to a successor.

`refine fmt source.ldn ...` rewrites each named source, or every `.ldn` file
under a named directory, in the one layout
[`docs/format.md`](docs/format.md) shows, changing its space and nothing
else; `refine fmt --check` writes nothing and reports every line that is not
in it, showing the line as the layout writes it and marking where it differs,
and `refine fmt --stdout` prints one source in the layout. The library
roots, the examples and the tour's examples are kept in that layout.

`refine lsp` is a language server over standard input and output: an editor
started with it gets diagnostics, definitions, hover types, formatting and
quick fixes from the compiler's own stages, as
[`docs/server.md`](docs/server.md) describes, and the packages under
`highlight/` start it.

## Current compiler capabilities

This is the maintained inventory of what the compiler does today:

- **Command interface.** Explicit `check` and `compile` commands share a
  catalogue for help and scoped shell completion, and `check` takes what
  `compile` takes about the program. `refine fmt` formats files or the
  `.ldn` files under a directory, and `--check` marks where a line differs. Build identity and target
  queries, human/short/JSON diagnostics, response files, Make depfiles,
  dry-run plans and tool traces support command-line consumers. Quiet mode
  preserves selected warnings and errors. Compilation requests select,
  suppress or deny warnings by code before emission. Unnecessary local
  declarations produce advisories even when comments or layout prevent a
  safe automatic repair; unused signed numeric literals are also covered.
- **The language.** Functions, aggregates and variants, block-valued control
  flow, lexical `defer` and failure-only `undo`, declared errors, every loop
  and literal family, explicit conversion to a written type such as
  `[]u8(text)`, the enabled scalar conversions, range subtypes and
  `unchecked` regions. An atom union may be written in place as a
  binding's, parameter's, return's or field's type, `lenof` measures a field
  or element path or a call's result, `offsetof t.field` measures where a
  field begins, `compiler.assert` measures a declared type's size, alignment
  and field offsets, and `else (problem)` recovers a call in
  an `if` arm as anywhere else; `else none` ignores the failure of a call
  that returns none. A distinct type compares wherever its base does,
  updates flags in place with `|=`, `&=` and `^=`, and has its base's zero
  image; a pointer union compares with one of its own atoms; a match's
  `_ (rest):` arm binds the atoms no other arm named, and `ptr (sink p):`
  consumes the matched place; destructured results are local places; an
  assignment on every edge leaving a loop holds after it; and module arrays
  hold variant-bearing struct images. A module binding of function type may be
  written on one line, `chosen: () -> (v: i32) = seven`, and an immutable
  module integer sizes an array, `[path_max]u8` (D438). Generics take fixed
  parameters by compile-time substitution, an untyped literal argument takes
  its parameter's type, and a fixed array is lent to a generic slice
  parameter; concepts carry a whole-program conformance register. Generic
  calls pass only the evidence their checked bodies use; direct and `any C`
  dispatch share table storage only when their layouts and entries match,
  and an `any C` call no conformance of C answers builds as a trap no value
  reaches.
  Pointers and slices
  get local origin, borrow, `escaping`, `from` and consume checks. Directory
  modules have file-local imports, aliases, selected imports, typed global
  options and ordered roots. D227's memory model supplies scalar atomics,
  volatile accesses and barriers, and D228 packed register images with
  checked encoded fields. `compiler/tests/constructs.matrix` records every
  normative construct's state, targets and evidence, and `check.py` refuses a
  stale or unexplained row.
- **The library.** The nineteen shared `core/*` modules thread arena and pool
  allocators and a failure injector as capabilities and supply raw memory,
  vectors, inline-prefix spill lists, maps, trees, sorting by ordering
  evidence or by a comparison given a context, byte-oriented and validated
  text, caller-backed I/O, bulk cleanup, panic dispatch, the
  `any`-dispatched `core/diag.log` and, in `core/failure`, a phrase for a
  person for every library failure atom. A pool grows a block within its
  slot. A service, an allocator or an I/O
  provider, is a handle passed by value over state its caller declares, so a
  program and its logger write through one and a region allocates beside its
  parent without either locking it. I/O separates reader, writer, file and
  process capabilities; a streaming log needs only a writer, and the process
  capability lends standard input beside standard output and error. A fifth,
  directories, lists a directory through a buffer its caller supplies,
  lending each name until the next read, and makes and removes directories
  and files; a sixth lends the read-only environment; a seventh, programs,
  starts a program by its path with the
  arguments and environment its parent builds, each standard stream
  inherited, discarded or piped, reads its output and errors together while
  it runs and waits for it to exit with a code or be ended by a signal, and
  caller-backed fakes beside the memory world give both, an environment over
  data and scripted programs. A monotonic clock with sleeping, a wall clock
  and the system's entropy are three more, outside `world`, with time in
  nanoseconds in a `u64` and no floating point; on Linux the clock is read
  through the vDSO the auxiliary vector names, falling back to the system
  call, and a manual clock and scripted entropy are their fakes. The
  network is one more: blocking TCP and UDP over IPv4 and IPv6 that
  listen, accept, connect, send and receive, with address values read
  from and written to their text, time limits whose passing is an atom,
  and a connection read and written as a file, a line reader and a
  buffered writer among them; a memory network of loopback addresses in
  the caller's buffers is its fake. A write to a peer that has gone is an
  error atom, since a hosted process ignores SIGPIPE and gives its children
  the default back. The rest of the file system is another: opening with
  options, appending and exclusive creation among them, renaming that
  replaces a taken name in one step, a status of size, kind, modification
  time and a read-only flag, read-only files, synchronizing, truncation,
  reading and writing at an offset, temporary files created exclusively
  under names drawn from entropy, and the working directory's path; and
  terminals, whether a stream is one and its size, one more. A memory
  volume over the caller's nodes fakes the file system, and memory
  terminals the terminals. Time is the module `core/time`, the network
  `core/net`, and the fakes of a system's providers are `core/io/fake`'s,
  each named for what it fakes: `fake.volume`, `fake.network`,
  `fake.clock`, `fake.entropy` and `fake.terminals`.
  `core/random` is a deterministic generator, xoshiro256**, seeded from a
  fixed seed or from entropy, which draws the same sequence on every target,
  Cortex-M0 included, with unbiased bounded draws and shuffles; a buffered
  writer gathers output in a caller's buffer until it
  is flushed, and a line reader lends each line until the next read. Text is
  built in a builder over a caller's buffer, or one an allocator grows, from
  bytes, text, host strings, decimals of every integer width and
  hexadecimal, aligned in a field, and `text.format` fills a template's `{}`
  with any value that has `formattable` evidence, checked against its
  values when it runs; every width parses back from bytes, and no locale is
  consulted. Byte slices copy, with overlap allowed either way, fill,
  compare and search with their lengths checked.
  Containers share construction and release names, and vectors, spill lists
  and maps lend writable slots with `at` alongside copying `get`. The
  comparison concepts
  are a module of their own, `core/cmp`, with library-supplied evidence for
  integer keys and ordering, Boolean and byte slice keys, and UTF-8 keys and
  ordering. A closed set of named values, such as a diagnostic's severity, is
  an atom set.
  `hosted/heap` and `hosted/system` supply the hosted heap and
  system I/O capabilities, written once over `platform/posix`, which gives
  POSIX's files, directories, memory mappings, `poll`, pipes, spawning,
  waiting and sockets, Unix-domain ones among them, reading and writing at
  an offset, renaming, hard and symbolic links, permission bits, owners and
  file times, whole-file and record locks, terminals, their raw mode and
  pseudo-terminals, the user and group databases, read from
  /etc/passwd and /etc/group by a static Linux program and through the C
  library elsewhere, and shared objects loaded with the system's own loader,
  on Darwin, FreeBSD and Linux under `--link=libc`, in Landin types, every
  descriptor closed on exec,
  with a descriptor handle type and errno atoms that keep their numbers,
  over `platform/libc` on Darwin and FreeBSD and `platform/linux` on Linux.
  A path, a process argument and a directory entry's name are host
  strings, never converted on the way through, with a checked conversion to
  UTF-8. `platform/linux` supplies Linux's system calls and
  the static process entry, with a raw `system_call` that reaches any call
  by the number `platform/linux/numbers` names, generated from a pinned kernel
  release; Linux executables link with no C library by
  default (`--link=libc` keeps it), through the first GCC a distribution
  installs that the host can start. A failed check in a hosted program with
  no `panic_handler` writes its kind and source site to standard error before
  its terminal instruction; firmware keeps the bare instruction. `platform/c` supplies aliases for the supported
  LP64 C ABIs, and `platform/cortex_m` supplies M-profile CPU operations. An import
  outside a module's target scope is refused by name, including through a
  project-root override. D212 withdraws the former builtin arena syntax in
  favour of ordinary allocator capabilities. The [library reference](docs/library.md)
  is generated from public signatures and doc comments, with module browsing,
  search, source links and examples taken directly from runtime fixtures.
- **The C boundary.** The C ABI of each hosted target, `layout(c)`, C's
  byte-packed records as `layout(c, packed)` on every target, whose unaligned
  fields RV64 and Cortex-M0 move a byte at a time, and a
  last-field flexible array member, both passed to C by pointer, callbacks
  and variadic calls, a C function value made from an address a loader
  found, with [`bindings/`](bindings/README.md) generating
  bindings, packed and flexible-member records among them, from an
  external Clang's view of a header. Unsupported C forms are
  refused by name. Only the entry, C imports, public C definitions, link names and
  Cortex-M placements are global symbols; every other routine and datum,
  public or not, is local to the image, so none meets the C library's names.
- **Targets.** Linux x86-64, Linux arm64, Linux RV64, Darwin arm64 and
  FreeBSD x86-64 and arm64 build hosted executables; FreeBSD is emitted on Linux and runs
  in [architecture-specific VMs](environments/freebsd/README.md) with separate
  runtime, C ABI and debugger gate verdicts. RV64 uses LP64D; the gate runs
  its whole test program under QEMU's user emulation, and its
  [physical RISE lanes](compiler/tests/rv64/README.md), with separate
  runtime, native GDB, C ABI and ISA-level verdicts, are suspended from the
  gate until they are dependable.
  Darwin checks a host-dependent large-image loader limitation against a native
  Clang control. Cortex-M0 builds
  ARMv6-M firmware with compiler-owned reset, data and RAM-code copying, BSS
  clearing, typed interrupt and naked functions, vector references, placement
  and fixed assembly, within a 32 KiB flash, 16 KiB RAM and 4 KiB stack
  profile, and runs it on the pinned QEMU
  [emulator](environments/cortex-m/README.md), with synthetic devices served
  through its debugger stub. Thirty RP2040 registers are
  checked in as [generated device fixtures](devices/README.md).
- **CPU feature levels.** A build assumes a level of its target's family,
  selected with `--level=`: x86-64 v1 to v4, arm64's `armv8-a` and
  `armv8.1-a`, and the M profile's `armv6-m`, `armv7-m` and `armv7e-m`, each
  defaulting to what the backend always emitted. RV64 selects ISA extension
  sets: `rv64gc` is the baseline, `rv64gc_zba` and `rv64gc_xtheadba` add
  independent address-generation extensions, and `rv64gc_zba_xtheadba`
  selects both. A program reads a level as
  `compiler.feature.NAME` in `fixed if` or in a module value, which a
  routine body then branches on, and every compiler fact reads the same way
  (D437). A level changes instructions and
  never layout or ABI: BMI2 shifts at `x86-64-v3`, LSE atomics at
  `armv8.1-a` on Linux, macOS and FreeBSD, and hardware division at `armv7-m`, each
  executed at both levels, the last on QEMU's Cortex-M3. The assembler holds
  an assembly block to the level, and a level runs only on a processor that
  confirms it; an unconfirmed level fails as unverified.
- **Code generation.** Target code and the build report are byte-identical
  whatever the build directory, environment or order, on all seven targets;
  the hosted linked image is not claimed. Compact numeric-array loops,
  explicit `layout(optimal)` placement and optional evidence-proved
  specialization are independent switches.
- **Debugging.** DWARF and GDB on Linux, native LLDB in both FreeBSD VMs
  for source-line stops, frames, local values and unwinding, LLDB with dSYM and exact Mach-O
  identity on Darwin, and line and function debugging on Cortex-M0. At speed
  a local held in a register is described past its last use until the
  register is written over, and the GDB and LLDB sessions read such locals
  there. An atom set is described as an enumeration, so a debugger prints
  an atom's name; a generic instance is a symbol named after its routine;
  and a library file is recorded as `/landin-library/` and its module path,
  never where the library was installed, which a session maps to the
  directory `refine version` names. Debug
  provenance stays independent of DWARF for a possible future PDB emitter; PDB
  is not implemented.
- **Derived programs.** Prototypes 2, 3 and 4 run as the recovering
  configuration parser, the container client and the log filter on Linux and
  macOS, with native debugging coverage, and prototype 1 runs as the
  [derived driver](compiler/tests/driver/DERIVATION.md) on the Cortex-M0
  emulators, each against a generated oracle.

Exact-revision runtime acceptance ran natively on Linux x86-64 and Darwin
arm64 through 0.2.0. The recurring gate runs Linux and Darwin programs
natively, FreeBSD programs in accelerated VMs and Cortex-M firmware under
QEMU, with separate runtime, C ABI and debugger verdicts. RV64 Linux runs
under QEMU's user emulation, which is evidence about its emitted code and
none about RV64 hardware; its execution on physical RISE runners is
suspended from the gate until further notice. The recorded boundaries stand as measured: the 32 KiB capacity
verdicts, the lines-and-functions Cortex-M debugging contract and the Darwin
shared-region placement limit observed on some hosts.

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
compiler produces. At size and speed the simplifier forwards a slot's value
across writes that cannot reach it and computes identical operations and
checks within a block once, and the x86-64 and arm64 allocators give slots
registers over their live intervals, small routines' among them in
caller-saved registers, floating-point values included; both keep each
routine's traps after its body, compute into a result's own register with
immediate operands, fuse comparisons with their branches and fold indexed
accesses into scaled operands. Immutable module values fold, a check a
dominating comparison proves is removed, and a callee reads an aggregate
argument where its caller keeps it when nothing can change it. At speed a
direct call to a small routine becomes a copy of its body, which the
debuggers show as an inlined frame of that routine (D339); slices and small
structs split into scalars; and a branch whose arms only compute becomes a
choice (D338). A program
lowers, emits and assembles only the routines it can reach, so it pays for
the library it calls rather than everything it imports.
[The Benchmark Game, measured](docs/benchmarks.md) compares five ports, their
running and their compile times, with seven other languages.

## What comes next

Implementation proceeds in executable vertical slices rather than waiting for
every design foundation to be settled in advance. The pinned container remains
available for explicit environment troubleshooting.

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

**Current roadmap work: R13.73 — Documentation that teaches.**

## Questions, bugs and ideas

Ask questions, report bugs and friction, and propose ideas or changes to the
language in [Discussions](https://github.com/JanHaan/Landin/discussions);
each category's form says what a report needs. The repository has no issue
tracker. Open work lives in `ROADMAP.md`, and a discussion that leads to
some becomes an item or a register record there. Report a security
vulnerability privately, through
[GitHub's private reporting](https://github.com/JanHaan/Landin/security/advisories/new),
and never in a discussion. Everyone taking part follows the
[code of conduct](CODE_OF_CONDUCT.md).

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
