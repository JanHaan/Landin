# Repository-owned library modules

These ordinary Landin modules use explicit roots and imports, with no user-code
module initialization. `spec.md` owns their language contracts, and the
[freestanding library lane](../environments/cortex-m/README.md#freestanding-library-consumers)
executes them on Cortex-M0.

The [library reference](../docs/library.md) is generated from public signatures
and attached `---` comments. Build it with `scripts/site.sh` and open
`docs/site/site/library.html`; [the site guide](../docs/site/README.md) describes
the documentation convention.

## Availability inventory

The shared freestanding modules are `core/cmp`, `core/diag`, `core/fault`,
`core/io`, `core/map`, `core/mem`, `core/panic`, `core/pool`, `core/region`,
`core/sort`, `core/spill`, `core/text`, `core/tree` and `core/vec`. Every public interface is
available on every target. Their providers retain caller-supplied authority.

`hosted/heap`, `hosted/io` and `hosted/libc` require a hosted system. Import
the I/O provider `as hosted` alongside the shared `core/io` protocol.
`hosted/libc` declares the C library both providers call, with the facts that
differ between systems selected by `compiler.os`; the compiler names none of
it. `platform/c` holds the
currently enabled LP64 C ABI aliases; it does not admit Cortex AAPCS32 or
synthetic-32. `platform/cpu` holds M-profile CPU operations and admits the
armv6-m, armv7-m and armv7e-m feature levels. Namespace availability is checked
by import name independently of project-first root selection (D267).

The `runtime/library-shared-*` consumers are separate small programs, one per
shared module, with success and applicable failure oracles. The constrained
firmware lane compiles, links and executes them separately and records every
reached source and linker input. No consumer relies on an image-size refusal
as positive evidence.

The larger `library-at-references`, `library-builtin-keys` and
`library-map-reserve-rollback` regressions exercise complete map operations.
They exceed Cortex-M0's 32 KiB flash profile, as the earlier map workloads do;
their measured image limits are not successful firmware executions. The
shared vector and spill-list consumers exercise writable slots, the shared
map consumer checks missing-key access, and `library-builtin-evidence`
exercises the supplied hashes, equality and ordering without map allocation.
These smaller programs and the writer-only and writer-adapter probes must
execute within the constrained profile.

## Interface conventions

Every module spells the same operations the same way (D269):

| Operation | Spelling | Examples |
|---|---|---|
| Construct a module's principal type | `new` | `vec.new(item: i32)`, `map.new(key: u32, item: i32)`, `diag.new(capacity: 4)` |
| View over caller-supplied bytes or records, or a provider's handle over its caller-owned state | `over` | `mem.arena_over(space, base, size)`, `mem.storage_over`, `pool.over`, `region.over(ledger, heap)`, `fault.over(space, inner, 3)`, `io.memory_over` |
| A provider's caller-owned state | `space`, declared `zeroed` | `mem.arena_space`, `pool.space`, `region.space(capacity)`, `fault.space`, `io.memory_space` |
| Give a container's storage back | `release` | `vec.release`, `map.release`, `tree.release`, `spill.release`, `region.release` |
| Read one item as a copy | `get` | `vec.get`, `spill.get`, `map.get`, `tree.get`, `diag.get` |
| A writable slot for in-place update | `at` | `vec.at`, `spill.at`, `map.at`; the binding is locked while the slot lives [0800] |
| Count and room | `length`, `capacity` | `mem`, `vec`, `spill`, `map`, `diag`'s `length`; a map's `capacity` is the entries that fit before the next new key rebuilds it |
| Initialized view | `used` | `mem.used`, `vec.used`, `spill.used` |

A value that is edited, a list, a map, a buffer or raw storage, is passed
`inout`. A service, an allocator or an I/O provider, is a handle: a small
copyable value passed `in` that refers to its state, so a program, its logger
and several containers share one without locking it. Its lifetime is checked
once, where `over` makes it `from` the state; the state's type is the
module's `space`, which the caller declares `zeroed` beside its backing bytes
and keeps alive while any handle is used. Giving the state back, as
`region.release` does, takes it `inout` and is refused while a handle made
from it is still in use. Process-wide state, the argument root, the last
errno and the Linux heap's classes, belongs to the process, so
`hosted.host()` and `heap.host()` make handles that borrow nothing. Code
that must keep its own last errno, a C thread calling into Landin among
them, declares a `hosted.space` and takes its handle with `hosted.over`. A
provider stacked on another, a region, an injector, the lent writer or a
streaming log, holds a copy of its parent's handle. One parameter name serves
each role: `memory` is an allocator handle, `host` an I/O handle, `state` a
provider's caller-owned state and `self` a concept entry's receiver.

`core/mem` keeps `new`/`delete` for one allocated item and `new_bytes`/
`delete_bytes` for a byte buffer; its raw-storage pop is `withdraw`, so that
`release` never means anything but giving storage back. Accessors are
prefixed only where one module holds several types (`arena_used`). A
provider's counters are plural nouns: `pool.allocations`, `pool.frees`,
`fault.frees`. A module is named by a short noun or a conventional
abbreviation: `mem`, `vec`, `cmp`, `io`, `diag`, `map`, `sort`, `pool`,
`spill`, `fault` (D274).

Two atoms serve every core container: `mem.out_of_bounds` for an index past
the initialized prefix and `mem.empty` for taking from nothing. Key lookups
keep their own, `map.missing` and `tree.no_such_node`, because a missing key
is not a bad index.

`core/io` is four narrow concepts over one provider type, `reader`, `writer`,
`files` and `process`, with `world` their composition and `writer_of` lending
a world's writer; a sink implements `writer`'s two entries and `core/diag`
streams through `any io.writer` (D268). Every entry takes the provider's
handle by value, and an erased capability is built from the address of a
handle binding, `any(addr host)`; dispatch copies the handle from there.
`process` lends the standard streams `input`, `out` and `err` and the argument
table, and its free functions take the handle `in`, as `read` and `write` do,
so two lent arguments, the count and a write through an erased world made
from the same handle are live at once. `in` is reserved [1760], so the
standard-input entry is the noun `input`, which reads beside `out` and `err`
without C's `std` prefix.
`core/text` writes `u32`, `u64` and `usize` decimals and parses them from
`[]u8`; a program does not write its own digit loop. The comparison concepts
`equatable`, `hashable` and `ordered` live in `core/cmp`, apart from the map
and the sort that consume them (D273). It ships `equatable` and `hashable` for the integer
scalars, `bool` and `[]u8` and `ordered` for the integer scalars, and
`core/text` all three for `utf8` (D270); another reading goes on a `distinct`
wrapper with its own evidence [1280]. A closed set of named values, such as
`core/diag`'s severity, is an atom set rather than an integer (D272).

## Constrained Cortex-M0 consumers

The consumers use the existing memory and collection implementations. No
allocator is hidden in a container or selected implicitly by the target.

| Module | Interface and boundary |
|---|---|
| `core/mem` | `allocator` with `alloc`/`grow`/`free` taking the handle by value, `allocate`/`free`, the caller-backed `arena` over an `arena_space` and the `aligned_offset` it bumps with, typed `storage`, `new`/`delete` and byte buffers. Byte storage can release its initialized prefix in one typed transition before disposal. Requests and capacities use target `usize`. Raw backing, the arena's state and their lifetime belong to the caller. |
| `core/vec` | `list`, `new`, `reserve`, `push`/`pop`, initialized views, length/capacity and `release`. Operations receive an allocator explicitly. Growth extends supported positive-byte blocks in place; otherwise it copies privately, rolls back on failure and publishes a complete replacement last. |
| `core/pool` | A provider handle over a caller's `pool.space`, its bytes and initialized slot metadata. A free-index heap gives lowest-index reuse in logarithmic time; exact frees find their slot by address. No backing allocation or fallback heap. |
| `core/panic` | The canonical four-atom `panic_kind` domain. An entry-module public ordinary `(kind: panic.panic_kind, site: u32) -> noreturn` handler replaces the terminal default; no reporting or allocation dependency is imported. |
| `platform/cpu` | M-profile PRIMASK save/disable/restore, mask observation, WFI and compiler/data/completion barriers. A target assertion refuses import on other targets. |

The arena aligns the absolute address, not its offset. Alignment zero and one
mean byte alignment; other `usize` alignments are honored when representable.
Overflow and exhaustion report `out_of_memory` before changing the cursor. A
zero-byte request still checks alignment/address arithmetic and may consume
padding; it need not have a distinct address. Arena free does not reclaim
individual allocations. A pool zero-byte request consumes a slot and must be
freed with its original size. `new_bytes(0)` instead returns an empty descriptor
without asking the provider. These are deliberately distinct contracts.
An arena can extend its current top allocation if the larger extent fits;
other allocations between vector growths force the normal replacement path.

Zero-sized vector elements retain logical capacity in `usize`; it is not
silently truncated to a physical byte count. Nonzero byte-count overflow is
checked before allocation. Failed reserve preserves the old length, capacity
and values. Raw storage publishes an initialized prefix only after complete
stores. It is not an ownership token: aliases, backing extent, provider identity,
free order and lifetime remain manual obligations under D148/D193.

`disable_interrupts()` returns the prior PRIMASK. Restore that saved value,
including on early returns; an ordinary `defer` can do this. Each nested section
retains its own value. Thread and handler mode are supported. Only PRIMASK bit
zero is implemented; the rest of the carrier is reserved. Restoring a saved
value is the supported use. Ordinary calls can clobber flags; exception return
restores interrupted flags from the hardware frame. NMI, HardFault and DMA are
not excluded by PRIMASK.

`wait_for_interrupt()` executes DSB SY then WFI. An enabled pending interrupt
can wake the core while PRIMASK delays handler entry, and wakeups can be
spurious. Recheck the condition. `compiler_barrier()` invalidates compiler
memory knowledge, `device_barrier()` adds DMB SY ordering, and
`completion_barrier()` adds DSB SY completion. None proves device completion
or supplies missing cache coherence. The selected core has no cache, FPU,
exclusive-access primitives or VTOR. Ordinary DMA buffers remain slices.

## Other modules and closure

`core/cmp`, `core/fault`, `core/region`, `core/spill`, `core/map`, `core/tree`,
`core/sort` and `core/text` contain reusable target-neutral code. Existing tests and the
Cortex-M0 corpus's image-limit dispositions remain authoritative; absence
of hosted imports does not promise that every composition fits 32 KiB.
`core/io` and `core/diag` are target-neutral. `core/io/memory.ldn` uses only
caller backing, and every `core/io` concept can be selected on Cortex-M0. The
`hosted/io` provider, `hosted/heap`, `hosted/libc` and the hosted C aliases in
`platform/c` remain outside this consumer closure. Even unused hosted declarations in a
selected module must meet target checks.

`core/sort.sort` sorts a mutable initialized view in place with heapsort:
worst-case O(n log n) comparisons, constant auxiliary storage, bounded call
depth and no allocation. `core/sort.sort_selection` keeps selection sort as an
explicit choice for tiny or swap-expensive views: exactly n(n-1)/2 comparisons
and at most n-1 swaps. Both take the caller's strict ordering and neither
promises stability.

`core/region.over(ledger, parent)` makes a region's handle over the caller's
`region.space(capacity)` and a copy of the parent's handle. A ledger of
capacity zero grows its records through the parent; a positive capacity holds
that many `region.allocation` records in the caller's state and no more.
Every allocation takes one record until release, because an individual free
returns nothing to the ledger; a full ledger reports `out_of_memory` and
returns the just-allocated payload to the parent. `region.release(ledger,
parent)` takes the ledger `inout` and the same parent, frees payloads in
reverse order, gives a growing ledger's block back, and leaves the ledger
available to `over` again. It is refused while the region's handle is still
used. The caller keeps the ledger alive through the region's last use.

The [probe runner](../environments/cortex-m/freestanding.py) copies only its
declared import closure and records every source hash. Each link accepts the
compiler-generated object, pinned `thumb/v6-m/nofp/libgcc.a` and GNU-generated
linker stubs. The map records selected private helper members. There is no libc,
hosted startup, heap provider or scheduler. ELF/map/assembly/linker inputs and
fresh-directory comparisons are retained. The profile remains 32 KiB flash,
16 KiB RAM and a 4 KiB stack reservation. Observed watermarks describe those
runs, not a complete maximum-depth proof. D231 enables infallible `noreturn`
without changing allocator errors into traps. A direct nonreturning call does
not run a pending deferred mask restoration; a nonreturning cleanup stops
later cleanups. D232 specifies panic dispatch and its optional source map.

The [generated device fixtures](../devices/README.md) import no core module.
Their consumers explicitly import `platform/cpu` and optionally `core/panic`;
ordinary DMA slices retain the completion/boundary/lifetime obligations above.
No allocator, heap, scheduler or hosted initialization enters that closure.

The [derived driver](../compiler/tests/driver/DERIVATION.md) uses caller-owned
initialized static byte storage and the ordinary `platform/cpu` interface. It
requires no allocator, hosted initialization or reporting storage. Successful
device drain precedes ordinary reads and storage reuse; failed stop retains
the caller's manual lifetime obligation. The allocator, initialized-prefix,
origin, rollback and broader-library contracts above are unchanged.

The separate Cortex line/function debugger controls execute the real pool
and vector consumers, generic/specialized allocation calls and noreturn/panic
paths. The complete driver's resource lane continues to use its static,
caller-owned storage. Debugger snapshots and stack instrumentation are host
artifacts, never an allocator capability or hidden target storage. These
controls do not broaden the library or manual lifetime guarantees.

## Container and diagnostic migration

`mem.clear(storage)` and `vec.clear(values)` discard the initialized prefix
without reading its values or freeing backing storage. Capacity and allocation
identity remain unchanged. Dispose or release the allocation separately, and
release any resources referenced by discarded values yourself. Byte-buffer
disposal uses the same generic operation; there is no separate byte clear API.
Zero-byte allocation, failure, matching-free and lifetime contracts are unchanged.

`uninit` is now reserved. Rename identifiers with that spelling. Its only
accepted use is an explicitly named inline array field in a compact private
struct literal within the defining module. That module must initialize each
element before a typed read. Whole-value transport remains a complete copy.
Spill-list storage is private: use `spill.new`, `push`, `pop`, `used` and
`release` instead of constructing or inspecting its representation. Wrappers
that forward a container to `spill.push` must declare that parameter
`escaping inout`; this makes the existing backing-lifetime responsibility
explicit when inline aggregates move into spill storage.

Pass `addr container` to `spill.length`, `spill.capacity`, `diag.length`,
`diag.dropped` and `diag.get`. These queries take read-only pointers and
accept mutable or immutable containers without copying their inline capacity.
Generic deduction permits mutable-to-read-only relaxation only for an outer
runtime pointer or slice pattern; nested permissions still match exactly.

Diagnostic `note` messages are call-scoped. Bounded logs copy messages of at
most `diag.message_capacity` (256) bytes into owned entries. Longer messages
are dropped whole, never truncated; they increment `dropped`, and errors still
make `failed` true. Callers may reuse their message bytes after `note` returns.
Each bounded entry reserves its full inline message capacity, even when the
message is short; empty log construction leaves the private entry array
uninitialized and initializes its counters only.

## Migrating to the reviewed library

The library was read whole after its first outside reading (D272 to D274).
Rename as follows; behaviour is unchanged except where noted.

| Was | Now |
|---|---|
| `core/small`, `small.small(item, n)` | `core/spill`, `spill.list(item, n)`; `inline_slots` is `usize` and items need no `zeroable` evidence |
| `core/failing`, `failing.counted(provider)` | `core/fault`, `fault.injector(provider)` |
| `mem.failing_over(base, size, n)`, `mem.failing_over_unchecked` | `fault.new(addr arena, n)` over `mem.arena_over(base, size)` or `mem.arena_over_unchecked`; its budget also spends a permit when the arena refuses |
| `mem.failing_used`, `failing_allocations`, `failing_frees`, `failing_remaining` | `mem.arena_used(arena)`, `fault.successes`, `fault.frees`, `fault.remaining` |
| `mem.reserve`, `mem.initialized` | `mem.storage_over`, `mem.length` |
| `mem.raw_full`, `mem.raw_not_empty` | `mem.full`, `mem.not_empty` |
| `mem.transfer_zero_prefix`, `mem.drain_zero_prefix` | `mem.transfer_prefix` for any item size, `mem.clear` |
| `map.equatable`, `map.hashable`, `sort.ordered` | `cmp.equatable`, `cmp.hashable`, `cmp.ordered`; import `core/cmp` |
| the equality entry `eq`, `text.eq` | `equal`, `text.equal` |
| `text.ordinal`, `text.at`, `text.written` | `text.offset`, `text.cursor`, `text.prefix` (which reports `past_end`) |
| `diag.severity` as a `u8`, `warning` 0 and `error` 1 | the atom set `warning \| error`; compare or `match` it, there is no number |
| `diag.note_at`, `diag.to`, `diag.stored` | `diag.get`, `diag.stream`, `diag.length` |
| `pool.allocation_count`, `free_count`, `rejected_free_count` | `pool.allocations`, `frees`, `rejected_frees` |
| `map.capacity` as the bucket count | `map.slots`; `map.capacity` is now the entries that fit before a rebuild |
| the labels `map.insert(added_value:)`, `vec.get(at:)` | `added_item:`, `index:` |
| `text.write_byte` and `text.write_u32` taking `inout into` | `into` by value; the slice is written through, not replaced |
| a `heap.system` struct literal | `heap.host()`; the state is opaque |

`text.valid` reports whether bytes are UTF-8 without making a view, and
`mem.aligned_offset` is the bump arithmetic a provider of your own needs.

## Migrating to standard input

Standard input joined the process concept. Behaviour is unchanged except
where noted.

| Was | Now |
|---|---|
| `io.argument_at(addr host, index)` | `io.argument_at(host, index)`; the argument is lent `from` the handle, see services as handles below |
| a `process` conformance of `out`, `err`, `argument_count` and `argument` | the same with `input`, the standard-input handle |
| `io.memory_over(files, arguments, output, errors)` | `io.memory_over(state, files, arguments, input, output, errors)`; `""` is an empty standard input, and `fail_read_at` and `read_limit` count its reads |
| a digit loop of your own | `text.write_u64`, `text.write_usize`, and `text.parse_u32`, `parse_u64`, `parse_usize` over `[]u8` |
| `text.number_overflow` as a value above `u32` | a value above the type parsed into |
| `hosted/io` reporting ENOTDIR, a path through a file, as `io_failed` | `not_found`, as ENOENT is; `last_errno` still tells them apart |

## Migrating to services as handles

An allocator and an I/O provider are handles passed by value; a provider's
mutable state is the caller's `space`, which `over` fills. Behaviour is
unchanged except where noted.

| Was | Now |
|---|---|
| `alloc: (inout state: provider, ...)`, `grow`, `free` | `alloc: (self: provider, ...)`, `grow`, `free`; a conformance's functions take the handle by value and change its state through it |
| `write: (self: ptr mut provider, ...)` and every `reader`, `files` and `process` entry by pointer | the same entries with `self: provider`; a by-value `self` is a record, which `any` dispatch copies from the erased pointer |
| `inout state: provider` in `mem.allocate`, `mem.new`, `vec.push`, `map.insert`, `tree.add_leaf`, `spill.push` and every other container operation | `memory: provider`, passed `in`; a call is spelled as before |
| `inout state: provider` in `io.read`, `io.write`, the `files` functions, `io.out`, `io.argument_at` and the other `process` functions | `host: provider`, passed `in`; `io.write(host, io.out(host), bytes)` holds no lock |
| `mut state := mem.arena_over(addr backing[0], 256)`, `arena_over_unchecked` | `mut space: mem.arena_space = zeroed` and `arena := mem.arena_over(space, addr backing[0], 256)`; `mem.arena_used(arena)` |
| `mut parent := pool.over(base, extent, ...)` | `mut space: pool.space = zeroed` and `parent := pool.over(space, base, extent, ...)`; the counters take the handle |
| `fault.new(addr inner, 3)` | `mut space: fault.space = zeroed` and `fault.over(space, inner, 3)`, the inner handle by value; `fault.permit` and the counters take the handle |
| `region.new(addr heap)` and `defer region.release(program)` | `mut ledger: region.space(0) = zeroed`, `program := region.over(ledger, heap)` and `defer region.release(ledger, heap)` |
| `region.over(addr parent, records[0..<2])` over caller `region.allocation` records | `mut ledger: region.space(2) = zeroed` and `region.over(ledger, parent)`; release as above, then `over` again to reuse it |
| `mut memory := io.memory_over(...)` with `memory.write_limit = 2` and `memory.write_calls` | `mut state: io.memory_space = zeroed`, `memory := io.memory_over(state, ...)`, `state.write_limit = 2`, `state.write_calls`; `io.written(memory)` takes the handle |
| `mut host := hosted.host()`, `mut heap := heap.host()` | the same calls bound without `mut`; the handles borrow nothing |
| `hosted.last_errno(host)` reading the provider value | the same call, reading the cell the handle was made with: the process's from `host`, or a declared `hosted.space` from `hosted.over` |
| `diag.stream(addr writer, addr stream)` | `diag.stream(writer, stream)`; the logger holds copies |
| `io.writer_of(addr world)` | `io.writer_of(world)`; the adapter holds a copy of the erased world |
| a provider of your own holding its state by value | a handle holding `ptr mut` to the caller's state, with by-value `self` entries |

An allocation still borrows nothing from its allocator: a container keeps the
block in its own storage, which a block borrowed from a handle could not
reach without every container operation retaining the handle.

## Migrating container providers and indices

Allocator conformances now provide `grow(self, block, old_size, new_size,
alignment) -> bool`. A provider may always return false; refusal must change
neither storage nor provider state. Success retains the address and existing
bytes and transfers ownership of the enlarged extent to the caller, which
later frees that exact extent. Zero-byte vectors retain allocation and free
calls rather than using this extension path.

`pool.slot` no longer has `occupied`. Its `size` is the maximum `usize` for a
vacant slot, including after a successful free; zero denotes an occupied
zero-byte request. Direct constructors must also retain `free_index`, which
belongs to the pool's lowest-index free heap. Prefer `pool.over` to initialize
the caller's metadata and use the public allocation/count operations.

Tree IDs, ordinal arguments and leaf counts now use `usize`; migrate explicitly
typed `u32` callers. Names remain borrowed. Node records retain constant-time
branch range sums in two target-sized cumulative words. Map iteration is now
insertion order: updating a value retains position, while removing and
reinserting appends. Public map compositions must preserve both live links per
bucket, the head/tail pair, and the capacity-valued end markers. Increased
record sizes can reduce capacity within the same backing extent.
