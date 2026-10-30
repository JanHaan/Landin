# What refine does today

This is the maintained inventory of what Landin's compiler, its library and
its tooling do today. The [README](../README.md#current-compiler-capabilities)
summarises it; `ROADMAP.md` owns what comes next, and `spec.md` decides what
is legal. Derived; never an authority.

Keep it an inventory rather than a log: when a capability changes, edit the
entry that describes it, and put a new one where a reader would look for it.

## Targets

| target | builds | where the gate runs it | debugger |
| --- | --- | --- | --- |
| `linux-x86-64` | hosted executables | natively | GDB |
| `linux-arm64` | hosted executables | natively | GDB |
| `linux-rv64` | hosted executables, LP64D | QEMU's user emulation | GDB, through QEMU's stub |
| `darwin-arm64` | hosted executables | natively | LLDB with dSYM |
| `freebsd-x86-64` | hosted executables, emitted on Linux | a FreeBSD VM under KVM | LLDB in the VM |
| `freebsd-arm64` | hosted executables, emitted on Linux | an emulated FreeBSD VM | LLDB in the VM |
| `cortex-m0` | ARMv6-M firmware | the pinned QEMU | GDB, lines and functions |

- **FreeBSD** runs in [architecture-specific VMs](../environments/freebsd/README.md)
  with separate runtime, C ABI and debugger verdicts in the gate.
- **RV64** runs its whole test program and its GDB sessions under QEMU's
  user emulation, which is evidence about its emitted code and none about
  RV64 hardware. Its [physical RISE lanes](../compiler/tests/rv64/README.md),
  with separate runtime, native GDB, C ABI and ISA-level verdicts, are
  suspended from the gate until they are dependable.
- **Darwin** checks a host-dependent large-image loader limitation against a
  native Clang control: the shared-region placement limit observed on some
  hosts.
- **Cortex-M0** builds firmware with compiler-owned reset, data and RAM-code
  copying, BSS clearing, typed interrupt and naked functions, vector
  references, placement and fixed assembly, within a 32 KiB flash, 16 KiB
  RAM and 4 KiB stack profile. It runs on the pinned QEMU
  [emulator](../environments/cortex-m/README.md), with synthetic devices
  served through its debugger stub. Thirty RP2040 registers are checked in
  as [generated device fixtures](../devices/README.md).
- **Synthetic-32** is a checking-only target, which no backend emits.

### CPU feature levels

A build assumes a level of its target's family, selected with `--level=`,
each defaulting to what the backend always emitted. `refine targets` lists
them, and [the target contracts](targets.md) say what each selects.

| family | levels |
| --- | --- |
| x86-64 | `x86-64-v1` to `x86-64-v4` |
| arm64 | `armv8-a`, `armv8.1-a` |
| M profile | `armv6-m`, `armv7-m`, `armv7e-m` |
| RV64 | `rv64gc` baseline; `rv64gc_zba` and `rv64gc_xtheadba` add independent address-generation extensions, and `rv64gc_zba_xtheadba` selects both |

- A level changes instructions and never layout or ABI: BMI2 shifts at
  `x86-64-v3`, LSE atomics at `armv8.1-a` on Linux, macOS and FreeBSD, and
  hardware division at `armv7-m`. Each is executed at both levels, the last
  on QEMU's Cortex-M3.
- A program reads a level as `compiler.feature.NAME` in `fixed if` or in a
  module value, which a routine body then branches on, and every compiler
  fact reads the same way (D437).
- The assembler holds an assembly block to the level, and a level runs only
  on a processor that confirms it; an unconfirmed level fails as unverified.

## The command line

The README has [the commands in brief](../README.md#refine-in-brief);
`refine help reference` prints the complete interface.

### Commands

- `refine check program.ldn ...` runs the frontend, lowering and
  verification on the named sources as one whole program, without writing
  an artifact. It takes every option that says which program is compiled,
  `--link`, `--firmware-entry` and `--build-report` among them, and with
  `--root` the operand is the entry module's directory or its source files.
  It stays silent when the program is accepted.
- `refine compile program.ldn -o program` assembles and links an executable.
  `--emit asm` writes assembly, `--emit ir` writes the IR the backend would
  receive, and `refine compile program.s -o program` links an assembly file
  as a compiled program is linked. The compile leaves only the executable;
  `--keep-asm` keeps the assembly beside it.
- `refine run program.ldn -- ARGUMENT ...` compiles into a new private
  directory under `TMPDIR` or `/tmp`, runs the program on this terminal with
  the arguments after `--` exactly, exits with its status, or with 128 and
  the number of the signal that ended it and a line naming it, and removes
  the directory on every way out. It takes `compile`'s options except those
  that say what is written, and runs only the compiler's own host. A bare
  `refine program.ldn` checks and says that it wrote nothing, naming both
  commands; `-q` silences that line.
- The default target is the compiler's own host; cross-compilation names a
  `--target`. Bare source requests and `--emit=asm|exe` remain
  compatibility spellings, and `build` is reserved for future project
  orchestration.
- `refine fmt source.ldn ...` rewrites each named source, or every `.ldn`
  file under a named directory, in the one layout
  [`docs/format.md`](format.md) shows, changing its space and nothing else.
  `--check` writes nothing and reports every line that is not in it, showing
  the line as the layout writes it and marking where it differs; `--stdout`
  prints one source in the layout. The library roots, the examples and the
  tour's examples are kept in that layout.
- `refine lsp` is a language server over standard input and output: an
  editor started with it gets diagnostics, definitions, hover types,
  formatting and quick fixes from the compiler's own stages, as
  [`docs/server.md`](server.md) describes. The packages under `highlight/`
  start it.
- `refine explain CODE` prints [what a diagnostic code means](diagnostics.md)
  and what to change.

### Help, options and completion

- `refine --help` lists commands. `refine compile --help`,
  `refine --help compile` and `refine help compile` give the same command
  help. `refine completion bash|zsh|fish` prints shell completion
  definitions from the same option catalogue.
- Shared options work before or after the command. Command-specific options
  follow it, and one written before it is refused naming the command it
  belongs to and where it goes.
- Values accept a space or `=`, repeatable options retain their order, and
  duplicate single-valued options are refused. Use `--` before literal
  operands. `@FILE` expands a bounded response file with single and double
  quotes and backslash escapes, without shell expansion.

### Version and targets

- `refine version` (also `--version`) prints `refine 0.2.8` for an exact
  release checkout, or `refine dev (01234567)` for a development commit. A
  modified checkout adds `dirty`; a modified release also includes its
  commit. The release name comes from an exact numeric `v` tag,
  independently of debug or release optimization. Tracked edits anywhere in
  the checkout and untracked compiler inputs count as dirty; generated build
  outputs do not. Without Git metadata, the banner identifies the source
  digest instead.
- `refine version --json` retains the full revision, compiler-input digest,
  dirty state, build mode and host triplet, with `version` set to the
  release name or `null` for development. The input digest covers compiler
  sources and build policy, so a prose edit changes dirty state without
  changing that digest.
- `refine targets` lists described targets and their CPU feature levels;
  `--json` gives structured output, and `--identify` retains the older
  capability summary.

### Reports and diagnostics

- `--verbose` (or `-v`) describes the compilation request; repeating it
  also traces the actual native tool argument vectors. `--quiet` retains
  warnings and errors.
- `--color auto|always|never` controls human diagnostic colour; `auto`
  checks standard error's terminal, `NO_COLOR` and `TERM`.
- `--diagnostics human|short|json` selects the source report. JSON
  diagnostics are schema-versioned newline-delimited objects carrying
  labels, notes and fixes; line and byte-column coordinates are one-based,
  spans retain the compiler's byte offsets, and paths also carry a
  hexadecimal encoding of their original bytes.
- A refused program gets a report with a span, a caret and a note, one per
  mistake and on the token it is about. What a mistake leaves behind is not
  reported again, and where one change of a token mends a line the report
  says which change and offers it as a fix.
- A spelling from another language, such as `elif`, `fn`, `x as i32`,
  `x++`, `*u8`, `&&` or `!=`, is refused naming what Landin writes instead.
  A construct the tour describes and the kernel omits is refused with a note
  naming the paragraph that describes it and whether the form is a recorded
  boundary, withdrawn or transferred to a successor.

### Warnings

- `check` and `compile` accept `--warnings default|all|none` and repeated
  `--warn CODE|all`, `--allow CODE|all` and `--deny CODE|all`. The baseline
  is applied first; the repeated controls then apply in their written
  order, with the last matching control winning. Only live warning codes are
  accepted. `--deny all --allow L0326` denies every warning except the
  unnecessary-`mut` warning, which it suppresses.
- Denial returns status 1 before producing artifacts; ordinary warnings
  retain status 0 and the same generated bytes. Quiet mode retains selected
  diagnostics.
- Both current warning families are recommended, so `default` and `all`
  currently agree; so is L0016, which says a `--root` holds a module the
  library supplies instead.
- Unnecessary local declarations produce advisories even when comments or
  layout prevent a safe automatic repair; unused signed numeric literals are
  also covered. A warning can report an observation without an edit; exact
  fixes remain available where their edits preserve meaning and comments.

### Build integration

- `refine compile --dry-run` checks and emits in memory, prints planned
  writes and tool arguments, and performs no writes or tool executions.
- `--depfile PATH` writes Make-format source dependencies after successful
  emission, including observed module-search directories so import
  membership changes can cause a rebuild. Keep artifacts and reports outside
  those watched directories: creating them there changes directory
  timestamps and can cause redundant rebuilds. Paths containing line breaks
  are refused when a depfile is requested. A consuming build rule must also
  track its compiler and native tool configuration.
- Build mode, optimization, specialization and debug information remain
  independent controls.

## The language

- **Forms.** Functions, aggregates and variants, block-valued control flow,
  lexical `defer` and failure-only `undo`, declared errors, every loop and
  literal family, and `unchecked` regions.
- **Types and conversions.** Explicit conversion to a written type such as
  `[]u8(text)`, the enabled scalar conversions and range subtypes. An atom
  union may be written in place as a binding's, parameter's, return's or
  field's type. A distinct type compares wherever its base does, updates
  flags in place with `|=`, `&=` and `^=`, and has its base's zero image; a
  pointer union compares with one of its own atoms.
- **Measuring.** `lenof` measures a field or element path or a call's
  result, `offsetof t.field` measures where a field begins, and
  `compiler.assert` measures a declared type's size, alignment and field
  offsets.
- **Failures.** `else (problem)` recovers a call in an `if` arm as anywhere
  else, and `else none` ignores the failure of a call that returns none.
- **Matching and places.** A match's `_ (rest):` arm binds the atoms no
  other arm named, and `ptr (sink p):` consumes the matched place.
  Destructured results are local places, and an assignment on every edge
  leaving a loop holds after it.
- **Module values.** Module arrays hold variant-bearing struct images. A
  module binding of function type may be written on one line,
  `chosen: () -> (v: i32) = seven`, and an immutable module integer sizes an
  array, `[path_max]u8` (D438).
- **Generics and dispatch.** Generics take fixed parameters by compile-time
  substitution, an untyped literal argument takes its parameter's type, and
  a fixed array is lent to a generic slice parameter. Concepts carry a
  whole-program conformance register. Generic calls pass only the evidence
  their checked bodies use; direct and `any C` dispatch share table storage
  only when their layouts and entries match, and an `any C` call no
  conformance of C answers builds as a trap no value reaches. An `any C` is
  a provider of C and of the concepts C refines, so a generic routine takes
  it and calls each entry through its own table (D492).
- **Pointers and slices** get local origin, borrow, `escaping`,
  `escaping into` (D445), `from` and consume checks.
- **Modules.** Directory modules have file-local imports, aliases, selected
  imports, typed global options and ordered roots. Your own modules are
  found under the roots given with `--root` [1480].
- **Hardware.** D227's memory model supplies scalar atomics, volatile
  accesses and barriers, each atomic fenced only as its ordering asks on
  every backend (D499), and D228 packed register images with checked
  encoded fields.
- **Stacks.** D450's stack builtins, `compiler.stack_prepare` and
  `compiler.stack_switch`, run on every target with a native backend. On
  Cortex-M0 a prepared stack runs on the process stack pointer, and an
  interrupt in a fibre runs its handler on the main one (D460, D461).
  Synthetic-32 refuses both builtins.
- **Stack limits.** In a program that prepares a stack, every routine checks
  its frame against the current stack's limit in its prologue and traps
  D451's fifth panic kind, `stack_exhausted`, at its own site before it
  writes below the stack, at any depth. A switch carries each stack's limit,
  which stands a margin above its base for the handler (D471, D472). A
  selected handler that does not fit that margin, or whose calls the
  compiler cannot measure, is refused when the program is compiled (D474).
  A program that prepares no stack has no check. The limit is the running
  thread's own: ELF thread storage on Linux and FreeBSD, a pthread key's
  slot read directly on Darwin (D497, D506). Off Linux the default report
  claims a latch before it uses the one report stack, so two threads
  failing at once write one line (D498, D507).
- **Thread storage.** `link(thread) mut cell: T` gives every thread its own
  zeroed instance of a module binding: ELF local-exec thread storage on
  Linux and FreeBSD, which a static Linux program's start lays itself and
  `--link=libc` leaves to the C library, Darwin's thread-local variables,
  and ordinary module storage on Cortex-M0 (D496, D504). `hosted/system`
  keeps each thread's last errno and last signal so, and a handle from
  `system.new()` records into the calling thread's (D503, D509).
  platform/linux lays the block a new thread's `clone` takes (D504).
- **Fibres on Cortex-M0.** On the retained Cortex-M0 profile a consumer of
  `core/fibre`'s round of turns, two fibres on 1,472-byte stacks cut from
  fixed module storage, fits with its painted peaks and D461's exception
  frame, and the Cortex-M lane reports its flash, static RAM, backing and
  verdict at every profile (D470).
- **Stack reports.** `--stack-report=PATH` writes, for every emitted routine
  on each of those targets, its frame and the deepest stack of the call
  graph it can close, and names each `any`, generic, function-value or
  foreign call, recursion, runtime helper and stack-moving assembly that
  opens it (D447, D467, D468).

`compiler/tests/constructs.matrix` records every normative construct's
state, targets and evidence, and `check.py` refuses a stale or unexplained
row.

## The library

The standard library comes with `refine`: `core`, `hosted` and `platform`
are found beside the executable. [The library reference](library.md) is
generated from public signatures and doc comments, with module browsing,
search, source links and examples taken directly from runtime fixtures.

### `core`

The twenty shared `core/*` modules thread arena and pool allocators and a
failure injector as capabilities.

- **Memory and containers.** Raw memory, vectors, inline-prefix spill lists,
  maps, trees, and sorting by ordering evidence or by a comparison given a
  context. A pool grows a block within its slot. Containers share
  construction and release names, and vectors, spill lists and maps lend
  writable slots with `at` alongside copying `get`. D212 withdraws the
  former builtin arena syntax in favour of ordinary allocator capabilities.
- **Comparison.** The comparison concepts are a module of their own,
  `core/cmp`, with library-supplied evidence for integer keys and ordering,
  Boolean and byte slice keys, and UTF-8 keys and ordering.
- **Text.** Byte-oriented and validated text. A builder over a caller's
  buffer, or one an allocator grows, takes bytes, text, host strings,
  decimals of every integer width and hexadecimal, aligned in a field.
  `text.format` fills a template's `{}` with any value that has
  `formattable` evidence, checked against its values when it runs. Every
  width parses back from bytes, and no locale is consulted.
- **Bytes.** Byte slices copy, with overlap allowed either way, fill,
  compare and search with their lengths checked.
- **Failures and panics.** Bulk cleanup, panic dispatch, the
  `any`-dispatched `core/diag.log` and, in `core/failure`, a phrase for a
  person for every library failure atom. A closed set of named values, such
  as a diagnostic's severity, is an atom set.
- **Random numbers.** `core/random` is a deterministic generator,
  xoshiro256**, seeded from a fixed seed or from entropy, which draws the
  same sequence on every target, Cortex-M0 included, with unbiased bounded
  draws and shuffles.
- **Atomic cells.** `core/atomic` holds a `u8`, `u16`, `u32` or `u64` in a
  cell whose operations carry their orderings in their names, with a
  relaxed family and the single writer's `sole_add`, a load and a store,
  on every target. Cortex-M0 refuses a `u64` cell and a read-modify-write
  where the program uses it, naming `sole_add` and the critical section
  (D500, D510, D511).

### Services

A service, an allocator or an I/O provider, is a handle passed by value over
state its caller declares, so a program and its logger write through one and
a region allocates beside its parent without either locking it. Each one has
a caller-backed fake; the fakes of a system's providers are
`core/io/fake`'s, each named for what it fakes.

| service | what it does | its fake |
| --- | --- | --- |
| reader, writer, file | caller-backed I/O; a streaming log needs only a writer; a buffered writer gathers output in a caller's buffer until it is flushed, and a line reader lends each line until the next read | the memory world |
| process | lends standard input beside standard output and error | the memory world |
| directories | lists a directory through a buffer its caller supplies, lending each name until the next read, and makes and removes directories and files | the memory world |
| environment | lends the read-only environment | an environment over data |
| programs | starts a program by its path with the arguments and environment its parent builds, each standard stream inherited, discarded or piped; reads its output and errors together while it runs, and waits for it to exit with a code or be ended by a signal | scripted programs |
| clocks, in `core/time` | a monotonic clock with sleeping and a wall clock, with time in nanoseconds in a `u64` and no floating point; on Linux the clock is read through the vDSO the auxiliary vector names, falling back to the system call | `fake.clock`, a manual clock |
| entropy | the system's entropy | `fake.entropy`, scripted entropy |
| network, in `core/net` | TCP and UDP over IPv4 and IPv6 that listen, accept, connect, send and receive, blocking the thread over `hosted/blocking` and letting other fibres run over `hosted/events`; address values read from and written to their text; time limits whose passing is an atom; a connection read and written as a file, a line reader and a buffered writer among them | `fake.network`, loopback addresses in the caller's buffers, whose calls take turns where they would wait when it is given a `fibre.turns`, beside a `fake.clock` whose sleepers it waits for (D483, D493) |
| file system | opening with options, appending and exclusive creation among them; renaming that replaces a taken name in one step; a status of size, kind, modification time and a read-only flag; read-only files, synchronizing, truncation, reading and writing at an offset; temporary files created exclusively under names drawn from entropy; the working directory's path | `fake.volume`, over the caller's nodes |
| terminals | whether a stream is one, and its size | `fake.terminals` |
| signals, in `core/io/signal` | the signals a server cares about, delivered as events: `signals` refines `fibre.turns`, so only a provider whose fibres take turns delivers them, and a fibre waits for the next one as for a receive (D477, D482) | `fake.signals`, those a test raises, on Cortex-M0 too |

The clocks, entropy, network, file system and terminals sit outside
`world`. A write to a peer that has gone is an error atom, since a hosted
process ignores SIGPIPE and gives its children the default back.

### `hosted` and `platform`

- `hosted/thread/lock` is a lock that waits through the system's wait on
  an address, beside the flag that a thread has started, and `hosted/heap`
  keeps its size classes behind it once one has (D501, D502, D513).
- `hosted/heap`, `hosted/system`, `hosted/blocking` and `hosted/events`
  supply the hosted heap, the system's services that do not wait, the I/O
  provider that blocks the thread while it waits and the one that switches
  fibres, written once over `platform/posix` (D476, D478, D479).
  `hosted/events` is one handle over state its caller declares; it supplies
  every concept the blocking provider does, and `fibre.turns` and
  `signal.signals` beside them, on Linux over epoll and a signalfd and on
  Darwin and FreeBSD over kqueue. Its fibres take turns on a round whose
  wait, when every fibre waits, is the loop's wait for events, limited by
  the earliest deadline. A read, a write, a socket's accept, connect, send
  and receive, a child's pipes and end, a sleep and a signal each submit a
  record on the waiting fibre's own stack and are answered by the loop;
  closing or shutting a socket wakes its waiters with `io_failed`, and a
  child's end is a pidfd or kqueue's process filter (D485--D488).
- `hosted/thread` starts threads as a group a routine joins, made over a
  `hosted/system` handle, a backing the caller lends and a count, as
  `core/fibre` starts fibres: each task's stack is prepared and checked,
  the group keeps the first failure, a thread begins with every asynchronous
  signal blocked, and creation and join are the only edges it supplies (D494,
  D495). A static Linux program starts a thread with `clone` and waits on
  the word the kernel clears; under `--link=libc`, on Darwin and on
  FreeBSD the C library starts it on the caller's stack area and joins it
  (D517--D520). Each thread checks its frames against its own stack's
  limit, kept in its thread-local storage (D497).
- `platform/posix` gives POSIX in Landin types: files, directories, memory
  mappings, `poll`, non-blocking descriptors, pipes, spawning, waiting and
  sockets, Unix-domain ones
  among them; reading and writing at an offset, renaming, hard and symbolic
  links, permission bits, owners and file times; whole-file and record
  locks; terminals, their raw mode and pseudo-terminals; the user and group
  databases, read from /etc/passwd and /etc/group by a static Linux program
  and through the C library elsewhere; and shared objects loaded with the
  system's own loader, on Darwin, FreeBSD and Linux under `--link=libc`.
  It waits on and wakes an address, through the futex, `_umtx_op` and
  `os_sync_wait_on_address` (D512).
  Every descriptor is closed on exec, with a descriptor handle type and
  errno atoms that keep their numbers. It sits over `platform/libc` on
  Darwin and FreeBSD and `platform/linux` on Linux.
- A path, a process argument and a directory entry's name are host strings,
  never converted on the way through, with a checked conversion to UTF-8.
- `platform/linux` supplies Linux's system calls, epoll and signalfd among
  them, and the static process entry, with a raw `system_call` that reaches any call by the number
  `platform/linux/numbers` names, generated from a pinned kernel release.
  `platform/kqueue` supplies kqueue on Darwin and FreeBSD (D481).
  Linux executables link with no C library by default (`--link=libc` keeps
  it), through the first GCC a distribution installs that the host can
  start.
- `linker.library("NAME")` links a C library under `--link=libc` as the C
  driver's `-lNAME`, shared or archive, on every hosted target.
  `linker.directory("DIR")`, relative to its file, and a repeatable `-L DIR`
  on `check`, `compile` and `run` say where, `-L`'s first, and each is also
  the executable's runtime search path. A missing directory is refused
  before any tool runs, and a library a failed link cannot find is L0509,
  naming every directory searched. The static Linux link and firmware
  refuse all three.
- `platform/c` supplies aliases for the supported LP64 C ABIs, and
  `platform/cortex_m` supplies M-profile CPU operations.
- An import outside a module's target scope is refused by name, including
  through a project-root override.
- A failed check in a hosted program with no `panic_handler` writes its kind
  and source site to standard error before its terminal instruction;
  firmware keeps the bare instruction.

## The C boundary

- The C ABI of each hosted target, and `layout(c)`.
- C's byte-packed records as `layout(c, packed)` on every target, whose
  unaligned fields RV64 and Cortex-M0 move a byte at a time, and a
  last-field flexible array member, both passed to C by pointer.
- Callbacks and variadic calls, and a C function value made from an address
  a loader found.
- [`bindings/`](../bindings/README.md) generates bindings, packed and
  flexible-member records among them, from an external Clang's view of a
  header. Unsupported C forms are refused by name.
- Only the entry, C imports, public C definitions, link names and Cortex-M
  placements are global symbols. Every other routine and datum, public or
  not, is local to the image, so none meets the C library's names.

## Code generation

- **Determinism.** Target code and the build report are byte-identical
  whatever the build directory, environment or order, on all seven targets;
  the hosted linked image is not claimed.
- **Switches.** D209 to D211 specify compact numeric-array arithmetic,
  explicit `layout(optimal)` field placement and optional evidence-proved
  specialization, which are independent switches. The driver selects
  size/auto by default; `--optimize=none --specialize=off` selects the
  reference, and `--build-report=PATH` requests deterministic off-target
  JSON. Build mode remains independent.
- **The simplifier.** At size and speed it forwards a slot's value across
  writes that cannot reach it and computes identical operations and checks
  within a block once. Immutable module values fold, a check a dominating
  comparison proves is removed, and a callee reads an aggregate argument
  where its caller keeps it when nothing can change it.
- **Register allocation.** The x86-64 and arm64 allocators give slots
  registers over their live intervals, small routines' among them in
  caller-saved registers, floating-point values included. Both keep each
  routine's traps after its body, compute into a result's own register with
  immediate operands, fuse comparisons with their branches and fold indexed
  accesses into scaled operands.
- **At speed** a direct call to a small routine becomes a copy of its body,
  which the debuggers show as an inlined frame of that routine (D339);
  slices and small structs split into scalars; and a branch whose arms only
  compute becomes a choice (D338).
- **Reachability.** A program lowers, emits and assembles only the routines
  it can reach, so it pays for the library it calls rather than everything
  it imports.
- `./scripts/quality.sh` measures the objects a built compiler produces, and
  [the Benchmark Game, measured](benchmarks.md) compares five ports, their
  running and their compile times, with seven other languages.

## Debugging

`refine compile --debug=full program.ldn -o program` requests source
debugging; the default is `--debug=none`, and debugging metadata is
independent of the program's optimization and source build-mode settings.
Add `--target=darwin-arm64` for native macOS output, then open
`lldb ./program`. See
[source debugging and identity](targets.md#native-source-debugging).

- **Per target.** DWARF and GDB on Linux; native LLDB in both FreeBSD VMs
  for source-line stops, frames, local values and unwinding; LLDB with dSYM
  and exact Mach-O identity on Darwin; and line and function debugging on
  Cortex-M0.
- **Optimized code.** At speed a local held in a register is described past
  its last use until the register is written over, and the GDB and LLDB
  sessions read such locals there.
- **Stack switches.** A backtrace through a stack switch names the switch
  and start routines, `landin.stack_switch` and `landin.stack_start` (D469),
  and a scripted session on every target with a native backend steps two
  switches and holds the leaving and resumed fibres' frames at every
  instruction.
- **Names.** An atom set is described as an enumeration, so a debugger
  prints an atom's name, and a generic instance is a symbol named after its
  routine.
- **Library paths.** A library file is recorded as `/landin-library/` and its
  module path, never where the library was installed, which a session maps
  to the directory `refine version` names.
- Debug provenance stays independent of DWARF for a possible future PDB
  emitter; PDB is not implemented.

## Programs that run

- **Derived programs.** Programs derived from prototypes 2, 3 and 4 run as
  the recovering configuration parser, the container client and the log
  filter on Linux and macOS, with native debugging coverage. The one derived
  from prototype 1 runs as the
  [derived driver](../compiler/tests/driver/DERIVATION.md) on the Cortex-M0
  emulators. Each runs against a generated oracle. The driver and its
  application run with compiler-owned startup within the recorded 32 KiB
  capacity and source-debugging limits. The server derived from prototype
  5's hosted half runs on every hosted target from one source over both
  Ios, in a process of its own that a client in another asks: over
  `hosted/blocking` it answers one request at a time and SIGTERM ends it,
  and over `hosted/events` two requests are in flight and its signal
  waiter stops it cleanly (D490). It also runs in one process over the
  fake network on a round of turns. The firmware counterpart is not derived
  yet.
- **Example programs.** Every program in [`examples.md`](../examples.md)
  runs on every hosted target against its recorded output: everyday tools,
  the printing and failure lessons, the classic exercises from FizzBuzz to
  merge sort, the sensor-polling program, and five Benchmark Game ports at
  correctness scale.

## Where the evidence comes from

The recurring gate runs Linux and Darwin programs natively, FreeBSD programs
in accelerated VMs and Cortex-M firmware under QEMU, with separate runtime,
C ABI and debugger verdicts; RV64 Linux runs under QEMU's user emulation, as
above. [`AGENTS.md`](../AGENTS.md#the-mechanical-gate) describes every job.
Exact-revision runtime acceptance ran natively on Linux x86-64 and Darwin
arm64 through 0.2.0, and is retired. The recorded boundaries stand as
measured: the 32 KiB capacity verdicts, the lines-and-functions Cortex-M
debugging contract and the Darwin shared-region placement limit observed on
some hosts.
