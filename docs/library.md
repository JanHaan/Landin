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

Use `allocator` evidence to supply storage explicitly. `arena` is monotonic; `failing` adds a deterministic allocation budget. Raw descriptors do not establish ownership or prove alias lifetimes. Use the same provider and extent when freeing a block.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-mem/main.ldn)

## core/vec

A growable contiguous list with explicit allocation and rollback on failed growth.

`new` starts without allocating; `reserve` and `push` receive the provider. `get` copies, `at` lends a writable pointer, and `used` lends the initialized slice. End views before relocation or release. Clearing or releasing a container never frees resources referenced by its items.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-vec/main.ldn)

## core/small

A vector that keeps an inline prefix and spills into allocated storage when it fills.

Queries use a pointer to avoid copying the inline array. Popping from spilled storage retains that allocation; `release` returns to an empty inline representation. The element type must supply `zeroable` evidence.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-small/main.ldn)

## core/map

An insertion-ordered hash map, key equality and hash evidence, and explicit entry walks.

The module supplies equality and hashing for ten integer scalars, `bool` and `[]u8`. `core/text` adds UTF-8 evidence. Alternative policies use a `distinct` wrapper. Keep keys and their backing stable while stored, and restart cursors after any mutation. Floating-point keys need an explicit equality and hashing policy.

Complete map workloads can exceed the Cortex-M0 test profile of 32 KiB flash. The bounded example below checks the empty-map surface; it does not demonstrate that a populated map fits that profile.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-map/main.ldn)

## core/sort

Allocation-free in-place heapsort and selection sort using ordering evidence.

The module supplies ordering for the ten integer scalars; `core/text` supplies UTF-8 byte ordering. Custom `ordered` evidence must obey a strict weak ordering. Neither algorithm promises stability.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-sort/main.ldn)

## core/text

Byte cursors, validated UTF-8 views, byte search and bounded decimal conversion.

Cursors advance by bytes. The language provides separate UTF-8 indexing and traversal rules; this module does not turn byte offsets into validated character boundaries. UTF-8 equality, hashing and ordering use encoded bytes, with no normalization or locale collation. Views borrow their input.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-text/main.ldn)

## core/io

Reader, writer, file and process capabilities, their world composition, and an in-memory provider.

Use the smallest concept a consumer needs. An erased world can lend `writer_of` to a writer-only consumer. Providers retain authority over handles and arguments. Byte-path helpers terminate paths in caller scratch before invoking file operations; `memory` keeps all storage with the caller.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-io/main.ldn)

## core/diag

Bounded diagnostic storage and streaming diagnostics through a writer capability.

A bounded log stores at most its fixed number of entries and drops messages exceeding 256 bytes. It counts dropped entries and remembers error diagnostics even when they are dropped. A streaming log borrows a writer and file binding, emits severity and position prefixes, and propagates I/O failure.

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

Choose a dynamically grown ledger with `new` or a fixed caller ledger with `over`. Individual frees do nothing; every allocation consumes a ledger entry until region release. Release frees payloads in reverse order. End all payload uses before releasing the region.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-region/main.ldn)

## core/failing

Deterministic allocation-failure injection over any allocator, with cumulative counters.

The budget counts delegated attempts, including attempts the inner provider refuses. `permit` replaces that budget without resetting evidence. Free calls delegate to the parent; in-place growth is refused so allocation-failure tests remain predictable.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-failing/main.ldn)

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

C scalar aliases selected by the supported LP64 ABI.

The aliases preserve ordinary Landin scalar identity. Plain C `char` follows the selected ABI, rather than assuming signedness from pointer width. The source assertion and conditional signatures show the exact supported scope; Cortex-M C signatures are not admitted by this module.

[Executable example](../compiler/tests/fixtures/runtime/r440-c-aliases/main.ldn)

## platform/cpu

M-profile interrupt masking, waiting and memory barriers.

Save the mask from `disable_interrupts` and restore it, including on early returns. NMI and HardFault are not masked. Waiting can wake spuriously; barriers do not prove completion of a device protocol or supply a DMA lifetime discipline.

[Executable example](../environments/cortex-m/probes/core-cpu.ldn)

