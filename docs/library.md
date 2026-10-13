# Library reference

The API reference is generated from public declarations and their `---` doc
comments in `core`, `hosted` and `platform`. It includes exact signatures,
source links, module browsing and local search. The comments also appear in
editor hover. The [library guide](../core/README.md) explains the shared
conventions and evidence; the [tour](../tour.md) teaches the language.

`core` is available on every enabled target. `hosted` requires a hosted
system. Each `platform` module declares a narrower target scope. Availability
does not promise that every composition fits a particular firmware image.
All memory and handle lifetimes remain explicit caller obligations.

The examples below are existing compiler fixtures, included directly in the
rendered reference so the documentation does not maintain a second copy.
Their fixture metadata and target lanes determine where they execute.

## What the library does not cover yet

The library covers memory, containers, text, files, directories, standard
input and output and process arguments. A program that needs something it
does not cover yet reaches the operating system itself, and the route
differs between Linux and the C library's systems:

| Need | Planned | Route until then |
|---|---|---|
| The environment | the environment and processes item | On Linux, `hosted/linux`'s `environment()` gives the table the process started with, when `_landin_start` started it. On Darwin and FreeBSD, declare `getenv` as an `extern(c)` import in your own module, as `hosted/libc` declares its functions. |
| Running a program and waiting for it | the environment and processes item | On Linux, `linux.system_call` with `numbers.clone3_number`, `numbers.execve_number` and `numbers.wait4_number`. On Darwin and FreeBSD, `posix_spawn` and `waitpid` declared `extern(c)`. |
| Clocks and sleeping | the time item | On Linux, `linux.system_call` with `numbers.clock_gettime_number` or `numbers.clock_nanosleep_number` and a record of the kernel's `timespec`. On Darwin and FreeBSD, `clock_gettime` and `nanosleep` declared `extern(c)` with `libc.timespec`. |
| Sockets | the blocking sockets item, and an event-driven Io after it | On Linux, `numbers.socket_number`, `numbers.bind_number`, `numbers.listen_number`, `numbers.accept4_number` and `numbers.connect_number` through `linux.system_call`. On Darwin and FreeBSD, the BSD socket calls declared `extern(c)`, with each system's address records. |
| Threads | the threads item | Nothing safe yet: the hosted providers keep process-wide state, and there is no thread-local storage. |
| Renaming, links, permissions, file times, seeking, appending | not yet planned | On Linux, the call's number from `hosted/linux/numbers` through `linux.system_call`; on Darwin and FreeBSD, the C function declared `extern(c)`. |

Every Linux system call is reachable this way. `hosted/linux/numbers`
names each call's number, generated from a pinned kernel release, and
`linux.system_call` makes the call with six integer arguments and returns
the kernel's result, minus the errno on a failure. Nothing checks those
arguments: a pointer goes as `i64(usize(p))`, and a flag or a record is the
program's to get right for each architecture. Prefer a typed wrapper where
`hosted/linux` has one.

## core/mem

Memory providers and typed storage: the foundation for allocation, initialized prefixes and caller-owned backing.

Use `allocator` evidence to supply storage explicitly. A provider is a handle passed by value, `memory` in every signature, so several containers share one without locking it. `arena` is monotonic and has no reset: its allocations end with its backing. `arena_over` fills the caller's `arena_space`, declared `zeroed` beside the backing, and returns the handle from it. `aligned_offset` is the arithmetic a bump provider of your own needs. Typed storage over caller bytes comes from `storage_over`; it does not establish ownership or prove alias lifetimes. Use the same provider and extent when freeing a block. Deterministic failure injection over any provider is `core/fault`.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-mem/main.ldn)

## core/vec

A growable contiguous list with explicit allocation and rollback on failed growth.

`new` starts without allocating; `reserve` and `push` receive the provider's handle. `get` copies, `at` lends a writable pointer, and `used` lends the initialized slice. End views before relocation or release. Clearing or releasing a container never frees resources referenced by its items.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-vec/main.ldn)

## core/spill

A list that keeps an inline prefix and spills into allocated storage when it fills.

Queries use a pointer to avoid copying the inline array. Popping from spilled storage retains that allocation; `release` returns to an empty inline representation. Items need no zero image: pointers and atom-bearing records are stored like any other.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-spill/main.ldn)

## core/cmp

Equality, hashing and ordering evidence, apart from the containers and algorithms that consume it.

`equatable`, `hashable` and `ordered` ship for the ten integer scalars, `bool` (equality and hashing) and `[]u8` (equality and hashing); `core/text` adds all three for `utf8`. There is one register and no override: another reading of a shipped type goes on a `distinct` wrapper with its own evidence. A `hashable` key declares its `equatable` conformance as well. The compiler does not prove the laws: equality must be an equivalence, equal keys must hash alike, and `less` must be a strict weak ordering. Floating-point types have no shipped evidence.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-cmp/main.ldn)

## core/map

An insertion-ordered hash map with explicit entry walks.

Keys are constrained on `core/cmp`'s `hashable`, which ships for ten integer scalars, `bool` and `[]u8`; `core/text` adds UTF-8 evidence. Alternative policies use a `distinct` wrapper. Hashes are spread before they choose a slot, so keys sharing a stride do not share a probe chain. `capacity` is how many entries fit before the next new key rebuilds the table, and `slots` its size; removed entries count against the capacity until a rebuild. Keep keys and their backing stable while stored, and restart cursors after any mutation. Floating-point keys need an explicit equality and hashing policy.

Complete map workloads can exceed the Cortex-M0 test profile of 32 KiB flash. The bounded example below checks the empty-map surface; it does not demonstrate that a populated map fits that profile.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-map/main.ldn)

## core/sort

Allocation-free in-place heapsort and selection sort using ordering evidence.

Items are constrained on `core/cmp`'s `ordered`, which ships for the ten integer scalars; `core/text` supplies UTF-8 byte ordering. Custom `ordered` evidence must obey a strict weak ordering. Neither algorithm promises stability.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-sort/main.ldn)

## core/text

Byte cursors, validated UTF-8 views, byte search and bounded decimal conversion.

Cursors advance by bytes. `from_bytes` validates bytes as UTF-8 and reports `invalid_text` when they are not, and `valid` answers the same question without a view; the `utf8(bytes)` conversion validates too but traps on malformed input. A `text.position` indexes `utf8` by byte offset, while a `usize` index into `utf8` counts scalars, so do not index with `offset(position)`. This module does not turn byte offsets into validated character boundaries. UTF-8 equality, hashing and ordering use encoded bytes, with no normalization or locale collation. Views borrow their input.

Decimals are unsigned. `write_u32`, `write_u64` and `write_usize` append one to caller bytes at a `used` count and return the next, checking room for the whole number before the first byte, so `no_space` leaves the buffer as it was; twenty bytes hold any `u64`. `parse_u32`, `parse_u64` and `parse_usize` read nonempty ASCII digits from a byte slice, which need not be UTF-8, refusing anything else, a sign or a space included, with `invalid_number` and a value above the type's maximum with `number_overflow`, whichever comes first. `usize` is the target's, 32 bits on Cortex-M. `to_u32` is `parse_u32` over a `utf8` view.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-text/main.ldn)

## core/io

Reader, writer, file and process capabilities, their world composition, and an in-memory provider.

Use the smallest concept a consumer needs. A provider is a handle passed by value, `host` in every signature, and an erased capability is built from the address of a handle binding, `any(addr host)`; using a handle locks nothing, so a program and its logger write through one, and two lent arguments and a query are live at once. An erased world can lend `writer_of` to a writer-only consumer. Providers retain authority over files and arguments. `process` lends the three standard streams, `input`, `out` and `err`, and the argument table, `io.out(host)`; standard input is read through `reader` like any file, and a read of zero bytes into a nonempty buffer is its end. Byte-path helpers terminate paths in caller scratch before invoking file operations; `memory_over` fills the caller's `memory_space`, whose limits and counters stay readable and settable, and keeps all storage with the caller, the bytes its standard input reads among them. `directories` is a fifth concept beside the four, and not part of `world`: a program that lists, makes or removes directories names it as well. `open_directory` takes a buffer from the caller and returns an open `directory`, a value the caller passes `inout` to `read_entry`, which refills the buffer as entries are read. Each entry's name is bytes that need not be UTF-8, lent from the directory until the next read, so a name kept past it is refused [0800] and a program copies the names it keeps; an empty name is the end. `.` and `..` are never listed, and the order is the system's. `entry_size` asks the open directory for an entry's size by name as a `u64`, not following a symbolic link. `make_directory`, `remove_file` and `remove_directory` change the tree. A missing path, and a path through or to something that is not a directory, are `not_found`; a name already taken is `already_exists`. Close a directory through the provider that opened it; one dropped unclosed keeps its descriptor until the process ends. The memory world's directories are its slots' names before a `/`, so it lists them and reports their sizes but changes nothing.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-io/main.ldn)

## core/diag

Bounded diagnostic storage and streaming diagnostics through a writer capability.

Severity is the atom set `warning | error`, so a `match` over it is checked for both. A bounded log stores at most its fixed number of entries and drops messages exceeding 256 bytes. It counts dropped entries and remembers error diagnostics even when they are dropped. A streaming log from `stream` holds a copy of an erased writer and a file, writes each note as `W:` or `E:`, the decimal byte offset, `:` and the message, and propagates I/O failure.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-diag/main.ldn)

## core/tree

An append-only store of named leaves and branches addressed by node identifiers.

A branch names a contiguous range of previously published nodes. Leaf totals are precomputed, so queries use constant stack and time. Shared children count once for each incoming path. Names borrow their UTF-8 backing; releasing the tree frees node storage, not names.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-tree/main.ldn)

## core/pool

A reclaiming allocator over fixed-size slots and caller-supplied bookkeeping.

`over` fills the caller's `pool.space` and returns the pool's handle; the pool allocates no backing storage of its own. It reuses the lowest free slot and rejects malformed frees without reclaiming a slot. A zero-byte allocation still occupies one slot. Keep both payload backing and metadata alive while allocations exist.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-pool/main.ldn)

## core/region

An allocator scope that records allocations through a parent and releases them together.

`over` makes a region's handle over the caller's ledger, `space(capacity)`, and a copy of the parent's handle; a capacity of zero grows the ledger through the parent, and a positive one is a fixed caller ledger. Individual frees do nothing; every allocation consumes a ledger entry until release, whether or not its payload is still live. `release` takes the ledger and the same parent, frees payloads in reverse order and is refused while the region's handle is still used. End all payload uses before releasing the region.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-region/main.ldn)

## core/fault

Deterministic allocation-failure injection over any allocator, with cumulative counters.

`over` wraps a copy of a provider's handle in an `injector` over the caller's `space`. The budget counts delegated attempts, including attempts the inner provider refuses, so wrapping an arena counts both injected failures and the arena's own. `permit` replaces that budget without resetting evidence. Free calls delegate to the parent; in-place growth is refused so allocation-failure tests remain predictable.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-fault/main.ldn)

## core/panic

The four compiler panic atoms and their shared panic-kind domain.

Checked range, arithmetic and conversion faults, and an unreachable path, use these atoms. An entry-module panic handler has the language-specified nonreturning signature. A panic is distinct from a recoverable allocator or I/O error.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-panic/main.ldn)

## hosted/heap

An explicit allocator over the host runtime heap.

`host` returns a handle that borrows nothing: the heap belongs to the process. Allocations remain manual obligations; no ambient allocator is installed, and containers still receive the provider explicitly. Blocks are not grown in place. Every `usize` alignment is honoured by over-allocating and keeping a header before the block. On Linux the provider keeps eight size classes, of 32 to 4096 bytes, over chunks it maps through `hosted/linux`: a freed slot goes back on its class's list and is the next one handed out, and a larger request is a mapping of its own, unmapped when it is freed. That provider is single-threaded. On Darwin and FreeBSD it allocates through `hosted/libc`'s `malloc` and `free`. Either way a refusal comes before any state changes.

[Executable example](../compiler/tests/fixtures/runtime/hosted-heap-provider/main.ldn)

## hosted/io

Hosted file, stream and process operations, through `hosted/linux`'s system calls on Linux and through `hosted/libc` on Darwin and FreeBSD.

`system` supplies the shared I/O concepts. `host` exposes process arguments and standard streams, from the root the hosted entry establishes through `_landin_host_initialize_arguments`; a C `main` that drives Landin exports calls that initializer itself. Standard input, output and error are descriptors 0, 1 and 2. Open-write creates or truncates regular files. A path that names nothing is `not_found`, whether a component is missing or one before the last is not a directory, ENOENT or ENOTDIR; `same_file` answers false for such an output path. `host` returns a handle that borrows nothing, since the root, the descriptors and its last-error cell belong to the process; `over` makes a handle that keeps its last errno in a `space` the caller declares, for a C thread or a library that must not share the process's. `last_errno` captures the terminal failing call as provider-specific detail, minus a system call's negative result on Linux and C's errno elsewhere; it is not a portable error type. `system` also supplies `directories`. A directory's buffer must hold at least `io.directory_buffer`, 1024 bytes, or opening it fails with `io_failed` before anything is opened, so that every entry a hosted system gives fits. On Linux it is read with `getdents64` straight into that buffer, record by record, each record checked to lie within what the kernel filled; on Darwin and FreeBSD with `fdopendir` and `readdir`, the C library's interface to directories, each name copied into the buffer. An entry whose type the file system does not record is asked with a status call relative to the directory. `make_directory` gives a new directory 0777, which the process umask filters, and is not retried when interrupted, because a directory made before the interruption would then report `already_exists`.

[Executable example](../compiler/tests/fixtures/runtime/core-io-erased-system/main.ldn)

## hosted/libc

The C library's declarations, as ordinary `extern(c)` imports.

On Darwin and FreeBSD, whose C library is their system interface, `hosted/io` and `hosted/heap` reach the operating system only through this module; on Linux they use `hosted/linux`, and this module serves a program linked with `--link=libc`. Every declaration is bodyless, so a program that names none of them needs no C library. `open` is declared variadic, as C declares it, and takes its mode as the one unnamed argument. Facts that differ between systems are chosen by `compiler.os`: the errno accessor `errno_cell`, `__errno_location` on Linux and `__error` on Darwin and FreeBSD, and the `open` flags; `stat`'s record follows the system and the C ABI. Read the errno cell immediately after a failing call. A `malloc` result is the `allocation` union, so the null pointer is `no_allocation` rather than a pointer. The directory calls are `fdopendir`, `readdir`, `closedir`, `fstatat`, `mkdirat` and `unlinkat`, with each system's `struct dirent` as `directory_record`, its `at_fdcwd`, `o_directory`, `at_symlink_nofollow` and `at_removedir`, and the `d_type` and mode bits; `readdir`'s and `fdopendir`'s null pointer is `no_directory`. `mkdirat`'s mode is 16 bits on Darwin and FreeBSD and 32 on Linux, as each system's `mode_t` is. A program that declares one of these C functions itself must declare it with the same types, or the two declarations of one C symbol are refused with L0347.

[Executable example](../compiler/tests/fixtures/abi/r440-native-hosted/program.ldn)

## hosted/linux

Linux's system calls with no C library beneath them, and the process entry of a static Linux executable.

Every declaration is Linux-only; on Darwin and FreeBSD the module declares nothing, which lets `hosted/io` and `hosted/heap` import it on every hosted system. Each call is one assembly block on x86-64, arm64 and RV64, and a failure comes back in its result as minus the errno; there is no errno cell. The `*at` calls take `at_fdcwd` for a path relative to the working directory, and `statx`'s `file_status` is the kernel's one record on every architecture. Every public routine has a link name of its own, `_landin_linux_` and the routine's name, so none of them replaces the C library's function of the same name under `--link=libc`. `_landin_start` is where a static executable starts: it reads `argc`, `argv`, the environment and the auxiliary vector from the initial stack and calls `main` as C's runtime would. Before `main` it holds the processor to the executable's CPU feature level, as a loader holds an x86-64 executable to its ISA note: `cpuid` and the operating system's enabled state on x86-64, AT_HWCAP on arm64 and `riscv_hwprobe` on RV64. A processor without a feature of the level ends the process with status 127 and one line on standard error naming the level and the missing feature; the baseline checks nothing. `level`, `read_cpu_words` and `missing_feature` expose the check. No C library initialisation runs and there is no thread-local storage. `environment` and `auxiliary` report what that entry found, and nothing when the C runtime started the program instead. `system_call` is the raw route to every Linux call: six `i64` arguments, unused ones zero, and the kernel's result; `hosted/linux/numbers` names each call's number. The typed wrappers are the calls the library makes, `getdents64`, `mkdirat` and `unlinkat` among them, and their numbers come from the same generated tables.

[Executable example](../compiler/tests/fixtures/runtime/linux-system-calls/main.ldn)

## hosted/linux/numbers

Every Linux system call's number on x86-64, arm64 and RV64, generated from a pinned kernel release.

Each number is its call's name in the kernel's table followed by `_number`, `numbers.getpid_number` for one, so no number can take a reserved word's spelling. Give it to `linux.system_call`. The numbers are the kernel's own, read by `scripts/linux_syscalls.py` from each architecture's table with the ABIs that architecture's 64-bit build selects, x32's excluded; the file's header names the release and its SHA-256, and nothing in it is written by hand. A call the running kernel lacks returns minus ENOSYS. It is a module of its own, apart from `hosted/linux`, so that a program making no raw call does not compile a thousand declarations; on Darwin and FreeBSD it declares nothing.

[Executable example](../compiler/tests/fixtures/runtime/linux-system-calls/main.ldn)

## platform/c

C scalar spellings for the target's C ABI, on every target whose C data model is LP64.

LP64 is a data model, not an architecture: C `int` is 32 bits while `long` and pointers are 64, as on every 64-bit Unix. Windows' LLP64 keeps `long` at 32 bits and Cortex-M's ILP32 makes all three 32 bits; neither is admitted here. Within LP64 the C ABI depends on the operating system as well as the architecture, so the compiler names it with one fact per ABI rather than reading it from `compiler.arch` or the pointer width:

| Target | ABI fact | Plain `char` |
|---|---|---|
| `linux-x86-64`, `freebsd-x86-64` | `compiler.c_sysv_lp64`: the System V AMD64 ABI | `i8` |
| `darwin-arm64` | `compiler.c_darwin_lp64`: Apple's arm64 variant of AAPCS64 | `i8` |
| `linux-arm64`, `freebsd-arm64` | `compiler.c_aapcs64_lp64`: the standard AAPCS64 | `u8` |
| `linux-rv64` | `compiler.c_riscv_lp64d`: RISC-V LP64D, LP64 with double-precision float registers | `u8` |

Darwin and Linux share `compiler.arch == arm64` and still disagree on `char`, which is why the fact names the ABI. Every other alias is the same on all four: `c_int` is `i32`, `c_long` and `c_longlong` are `i64`, `c_size` is `usize`. The aliases keep ordinary Landin scalar identity; `c_char` is a numeric byte and never a Unicode scalar. Cortex-M C signatures are not admitted by this module.

[Executable example](../compiler/tests/fixtures/runtime/r440-c-aliases/main.ldn)

## platform/cpu

M-profile interrupt masking, waiting and memory barriers.

Save the mask from `disable_interrupts` and restore it, including on early returns. NMI and HardFault are not masked. Waiting can wake spuriously; barriers do not prove completion of a device protocol or supply a DMA lifetime discipline.

[Executable example](../environments/cortex-m/probes/core-cpu.ldn)

