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

## core/mem

Memory providers and typed storage: the foundation for allocation, initialized prefixes and caller-owned backing.

Use `allocator` evidence to supply storage explicitly. `arena` is monotonic and has no reset: its allocations end with its backing. `aligned_offset` is the arithmetic a bump provider of your own needs. Typed storage over caller bytes comes from `storage_over`; it does not establish ownership or prove alias lifetimes. Use the same provider and extent when freeing a block. Deterministic failure injection over any provider is `core/fault`.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-mem/main.ldn)

## core/vec

A growable contiguous list with explicit allocation and rollback on failed growth.

`new` starts without allocating; `reserve` and `push` receive the provider. `get` copies, `at` lends a writable pointer, and `used` lends the initialized slice. End views before relocation or release. Clearing or releasing a container never frees resources referenced by its items.

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

[Executable example](../compiler/tests/fixtures/runtime/library-shared-text/main.ldn)

## core/io

Reader, writer, file and process capabilities, their world composition, and an in-memory provider.

Use the smallest concept a consumer needs. An erased world can lend `writer_of` to a writer-only consumer. Providers retain authority over handles and arguments. Byte-path helpers terminate paths in caller scratch before invoking file operations; `memory` keeps all storage with the caller.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-io/main.ldn)

## core/diag

Bounded diagnostic storage and streaming diagnostics through a writer capability.

Severity is the atom set `warning | error`, so a `match` over it is checked for both. A bounded log stores at most its fixed number of entries and drops messages exceeding 256 bytes. It counts dropped entries and remembers error diagnostics even when they are dropped. A streaming log from `stream` borrows a writer and file binding, writes each note as `W:` or `E:`, the decimal byte offset, `:` and the message, and propagates I/O failure.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-diag/main.ldn)

## core/tree

An append-only store of named leaves and branches addressed by node identifiers.

A branch names a contiguous range of previously published nodes. Leaf totals are precomputed, so queries use constant stack and time. Shared children count once for each incoming path. Names borrow their UTF-8 backing; releasing the tree frees node storage, not names.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-tree/main.ldn)

## core/pool

A reclaiming allocator over fixed-size slots and caller-supplied bookkeeping.

The pool allocates no backing storage of its own. It reuses the lowest free slot and rejects malformed frees without reclaiming a slot. A zero-byte allocation still occupies one slot. Keep both payload backing and metadata alive while allocations exist.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-pool/main.ldn)

## core/region

An allocator scope that records allocations through a borrowed parent and releases them together.

Choose a dynamically grown ledger with `new` or a fixed caller ledger with `over`. Individual frees do nothing; every allocation consumes a ledger entry until region release, whether or not its payload is still live. Release frees payloads in reverse order. End all payload uses before releasing the region.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-region/main.ldn)

## core/fault

Deterministic allocation-failure injection over any allocator, with cumulative counters.

`new` wraps a provider in an `injector`. The budget counts delegated attempts, including attempts the inner provider refuses, so wrapping an arena counts both injected failures and the arena's own. `permit` replaces that budget without resetting evidence. Free calls delegate to the parent; in-place growth is refused so allocation-failure tests remain predictable.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-fault/main.ldn)

## core/panic

The four compiler panic atoms and their shared panic-kind domain.

Checked range, arithmetic and conversion faults, and an unreachable path, use these atoms. An entry-module panic handler has the language-specified nonreturning signature. A panic is distinct from a recoverable allocator or I/O error.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-panic/main.ldn)

## hosted/heap

An explicit allocator over the host runtime heap.

`host` creates a provider state. Allocations remain manual obligations; no ambient allocator is installed, and containers still receive the provider explicitly. Blocks are not grown in place.

[Executable example](../compiler/tests/fixtures/runtime/hosted-heap-provider/main.ldn)

## hosted/io

Hosted file, stream and process operations through libc.

`system` supplies the shared I/O concepts. `host` exposes process arguments and standard streams. Open-write creates or truncates regular files. `last_errno` captures the terminal failing call as provider-specific detail; it is not a portable error type.

[Executable example](../compiler/tests/fixtures/runtime/core-io-erased-system/main.ldn)

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

