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
`core/io`, `core/map`, `core/mem`, `core/panic`, `core/pool`, `core/random`,
`core/region`, `core/sort`, `core/spill`, `core/text`, `core/tree` and
`core/vec`. Every public interface is
available on every target. Their providers retain caller-supplied authority.

`hosted/heap` and `hosted/io` require a hosted system. Import the I/O
provider `as hosted` alongside the shared `core/io` protocol. Both are
written once, over `platform/posix`, which gives POSIX's facilities in
Landin types on Linux, Darwin and FreeBSD and would not exist on a system
that is not POSIX. Beneath it each system's own interface stays raw:
`platform/linux` declares Linux's system calls, which `platform/posix`
makes on Linux, and the raw `system_call` that makes any of them, and
`platform/linux/numbers` names every call's number, generated from a pinned
kernel release; both declare nothing on Darwin and FreeBSD. `platform/libc`
declares the C library `platform/posix` calls on Darwin and FreeBSD, and
which a Linux program linked with `--link=libc` may call, its loader among
it, which `platform/posix` loads shared objects through on every system, with the facts
that differ between systems selected by `compiler.os`; the compiler names
none of it. The three `platform` modules' scope is the hosted POSIX
systems, and firmware refuses each by name. `platform/c` holds the
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
| View over caller-supplied bytes or records, or a provider's handle over its caller-owned state | `over` | `mem.arena_over(space, base, size)`, `mem.storage_over`, `pool.over`, `region.over(ledger, heap)`, `fault.over(space, inner, 3)`, `io.memory_over`, `io.variables_over`, `io.scripted_over`, `text.over(buffer)`, `io.buffered_over`, `io.lines_over` |
| A provider's caller-owned state | `space`, declared `zeroed` | `mem.arena_space`, `pool.space`, `region.space(capacity)`, `fault.space`, `io.memory_space` |
| Give a container's storage back | `release` | `vec.release`, `map.release`, `tree.release`, `spill.release`, `region.release` |
| Read one item as a copy | `get` | `vec.get`, `spill.get`, `map.get`, `tree.get`, `diag.get` |
| A writable slot for in-place update | `at` | `vec.at`, `spill.at`, `map.at`; the binding is locked while the slot lives [0800] |
| Count and room | `length`, `capacity` | `mem`, `vec`, `spill`, `map`, `diag`'s `length`; a map's `capacity` is the entries that fit before the next new key rebuilds it |
| Initialized view | `used` | `mem.used`, `vec.used`, `spill.used`, `text.used` |

A value that is edited, a list, a map, a buffer or raw storage, is passed
`inout`. A service, an allocator or an I/O provider, is a handle: a small
copyable value passed `in` that refers to its state, so a program, its logger
and several containers share one without locking it. Its lifetime is checked
once, where `over` makes it `from` the state; the state's type is the
module's `space`, which the caller declares `zeroed` beside its backing bytes
and keeps alive while any handle is used. So a state holds only scalars,
counters, limits and cursors: `zeroed` has no image for a pointer, a slice,
a pointer union, a function or an atom set, and refuses one with L0328.
Everything a service refers to, the backing it was given and the provider it
stacks on, is held by the handle `over` returns, which is why the handle is
`from` the state and may also be `from` that backing: `mem.arena_space`
counts, and the arena's handle holds the base. Giving the state back, as
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
table, each argument a host string, and its free functions take the handle `in`, as `read` and `write` do,
so two lent arguments, the count and a write through an erased world made
from the same handle are live at once. `in` is reserved [1760], so the
standard-input entry is the noun `input`, which reads beside `out` and `err`
without C's `std` prefix.

`directories` is a fifth concept beside the four and outside `world`, so a
sink, an image or a firmware world that has no tree is not made to carry
one. It opens a directory, reads its entries, asks an entry's size, and
makes and removes directories and files. An open directory is a value, not
a service: the caller declares the `directory` that `open_directory`
returns, supplies its read buffer, and passes it `inout` to `read_entry`.
Each entry's name is lent `from` the directory, because the next read
refills the buffer the name lies in, so a program that keeps a name copies
it, and keeping one across a read is refused [0800]. Names, paths and
arguments are host strings, `text.host_string`, as the system stores and
takes them, never converted on the way through; `text.from_host` validates
one that should be text, and `text.host_over` makes one over the caller's
bytes. An
empty name is the end of the directory, as a zero-byte read is the end of a
file, and `.` and `..` are never entries. The size is a separate
`entry_size` call relative to the open directory, the `*at` form, so a
listing that wants only names makes no status call per entry. A directory
dropped without `close_directory` keeps what its provider holds for it
until the process ends; a `defer` closes it on every way out. `core/io.memory`'s directories
are the parts of its slots' names before a `/`, a slot ending in `/` an
empty directory, read through the caller's buffer as the hosted provider's
are; its tree is the caller's slots, so it makes and removes nothing.
`environment` is a sixth concept, outside `world` as `directories` is, so
that widening `process` does not put an environment into every firmware
image that streams through a world: it lends each variable, a name and a
value that are host strings, by index or the first by name, read-only
because changing a process's own environment is not safe beside threads.
`programs` is a seventh, also outside `world`, for running another
program, D293's shape again: the provider is a handle, and a
started `child` is a value the caller keeps, edits `inout` and consumes
with `wait`. A program is named by its path and given exactly the arguments
and the environment its parent builds; nothing searches a path, no shell
reads a command line the parent did not write, and a child receives no
open file of its parent's but its three streams, each inherited, discarded
or piped. Its input is written with `write_child` and closed with
`close_input`. A child that writes more than a pipe holds waits for its parent
to read, so `read_child` reads whichever of its piped output and errors has
something, and `wait` reports a portable `ending`, exited with a code or
signalled, keeping what ended it as the provider's detail as `last_errno`
keeps an errno. Both have caller-backed fakes beside the memory world,
providers of their own so that a world that runs no program carries none
of them: `variables_over` an environment of `NAME=value` byte strings, and
`scripted_over` scripted programs that write what they are given and end
as they are told, writing an inherited stream into the world's own.
Time is two more concepts outside `world`: `clock`, a monotonic clock
that never goes back and sleeping on it, and `wall_clock`, the system's UTC
time, which may be set back and so never times anything. A reading is an
`instant` and a span a `duration`, each a distinct `u64` of nanoseconds,
584 years of them, with no floating point and the same arithmetic on every
target; two of a kind compare and are ordered directly, as every
distinct scalar type is, and `elapsed` traps rather than answer a negative
span. A sleep never returns early by its own clock. The
system's random bytes are a third, `entropy`. The fakes are a
`manual_clock`, which moves only when the test advances it or something
sleeps on it, by exactly what was asked, and `scripted_entropy`, the
caller's bytes in order, so a program that times itself, sleeps or seeds
itself gives the same answer in every test. `core/random` is the
deterministic generator: xoshiro256**, seeded from a `u64` or from any
`entropy`, drawing the same sequence for a seed on every target, Cortex-M0
included, uniform values below a bound without modulo bias and shuffles;
it is not cryptographic.
The network is one more concept outside `world`, `network`, so an image
that never connects carries none of it. It is a reader and a writer of its
sockets as well, so a TCP connection is read and written through `read`
and `write`, a line reader and a buffered writer among them, and its own
`send` and `receive` say more of a failure than `io_failed`: `timed_out`
when a limit `set_timeouts` gave has passed and `disconnected` when the
peer has gone. It listens, accepts, connects, opens UDP sockets, sends a
datagram to an address and receives one with its sender, shuts one
direction of a connection, names a socket's own address and its peer's,
and closes a socket. Every call waits as a blocking socket does, unless a
limit was set. An `address` is a value: a family, `ipv4` or `ipv6`,
sixteen bytes and a port, made with `loopback`, `unspecified`,
`ipv4_address` and `ipv6_address`, read from its text with `parse_ip` and
`parse_address` and written back with `append_ip` and `append_address`, as
RFC 5952 writes IPv6, and `text.formattable` too. It has no zone, and
nothing here resolves a name. A refused connection, an address in use and
an address this system does not have are atoms of their own. The fake is a
`memory_network`, a machine of loopback addresses over the caller's socket
records and their buffers: a connection and a datagram arrive at once and
in order, a datagram no socket takes is lost, and since nothing in one
thread could ever end a wait, a call that would wait answers `timed_out`
at once. A test can take IPv6 away from it and inject a failure.
The rest of the file system is one more concept outside `world`,
`file_system`, beside `files` and `directories` rather than widening
either, so a sink or a firmware world that only lists or only reads
carries none of it. It opens a path with `open_options`, appending and
exclusive creation among them; renames in one step, replacing a file
already at the new name, which with `make_temporary` and `synchronize` is
how a file is replaced whole; gives a `status` of size, kind,
modification time and a read-only flag, which `set_read_only` sets;
truncates; reads and writes at an offset without moving a file's position,
a write past the end leaving zeros; makes temporary files exclusively
under names drawn from an `entropy` the caller passes; and gives the
working directory's path, never changing it, since the working directory
is the whole process's. `terminals` is another: whether a stream is a
terminal and its size. Mode bits, owners, links, file times, locks, a
terminal's raw mode and accounts are POSIX's and stay in `platform/posix`.
The fakes are a `memory_volume`, a file system in memory over the
caller's nodes, with their paths, kinds and the room each file may grow
into, that conforms to `reader`, `writer`, `files`, `directories` and
`file_system` alike, and `memory_terminals` over the caller's screens.
`core/text` builds text: a `builder` over the caller's buffer, or one
growing through an allocator the caller erases, takes typed pieces, bytes,
text, host strings, decimals of every width and hexadecimal, each whole or
not at all, and aligns a piece in a field; `format` fills a template's `{}`
with values of any type that has `text.formattable` evidence, checked
against them when it runs, since nothing runs at compile time. Parsing is
its mirror for every integer width, and no locale is consulted anywhere. A
program does not write its own digit loop. `core/mem` copies, fills,
compares and searches byte slices with their lengths checked, its copy
allowing overlap in either direction as `memmove` does. `core/io` adds two
values a caller edits over a buffer of its own: a buffered writer, flushed
explicitly because there are no destructors to flush it, and a line reader
that lends each line until the next read, as a directory lends its
names. The comparison concepts
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
| `core/mem` | `allocator` with `alloc`/`grow`/`resize`/`free` taking the handle by value, `allocate`/`resize`/`free`, `relocate` for a provider that resizes by moving, the caller-backed `arena` over an `arena_space` and the `aligned_offset` it bumps with, typed `storage`, `new`/`delete` and byte buffers. Byte storage can release its initialized prefix in one typed transition before disposal. Requests and capacities use target `usize`. Raw backing, the arena's state and their lifetime belong to the caller. |
| `core/vec` | `list`, `new`, `reserve`, `push`/`pop`, initialized views, length/capacity and `release`. Operations receive an allocator explicitly. Growth extends supported positive-byte blocks in place; otherwise it copies privately, rolls back on failure and publishes a complete replacement last. |
| `core/pool` | A provider handle over a caller's `pool.space`, its bytes and initialized slot metadata. A free-index heap gives lowest-index reuse in logarithmic time; exact frees find their slot by address. No backing allocation or fallback heap. |
| `core/panic` | The canonical four-atom `panic_kind` domain. An entry-module public ordinary `(kind: panic.panic_kind, site: u32) -> noreturn` handler replaces the terminal default; no reporting or allocation dependency is imported. |
| `core/text` | A builder over a caller's buffer with byte, text, decimal, hexadecimal and aligned appends, and `format` over `any text.formattable`. At size/auto the bounded builder's core, `over`, `used`, `append`, `append_byte` and the room check with the growth path every builder carries, is about 6.4 KB with `mem.copy`; a `u32` decimal adds about 2.2 KB, a signed one 0.9 KB more, an aligned hexadecimal about 2.9 KB, and `format` with two conformances about 4.6 KB (`runtime/core-text-format-firmware`, 21.5 KB in all). No allocator is used unless the program builds a growing builder over its own. |
| `core/io` | Besides the concepts and the memory world, a buffered writer over the caller's buffer, about 5 KB at size/auto with `mem.copy`, and a line reader, about 7 KB with `mem.copy` and `mem.find` (`runtime/core-io-buffered-writer`, `runtime/core-io-line-reader`). |
| `core/random` | A generator of four `u64` words and its draws, written with shifts, exclusive ors and additions so the 32-bit core needs only `__aeabi_lmul` for seeding: `new`, splitmix64 and `next` are about 2.8 KB at size/auto, `below` 1.1 KB more and a shuffle of bytes about 1.6 KB, in `runtime/random-sequence`'s 16.3 KB image, which seeds from `core/io`'s scripted entropy too. |
| `core/io` time | The manual clock, its concepts and the span conversions run in `runtime/clock-manual`'s 11.3 KB image; nothing of them is in an image that does not use them. |
| `core/io` network | Reading and writing addresses run in `runtime/network-addresses-firmware`'s 29.8 KB image at size/auto, 31.9 KB at none/off, of which the address code is about 17 KB, `ipv6_octets` alone 4.6 KB. The memory network does not fit the profile: a provider's conformance table links every entry, about 40 KB of code, so its echo, `runtime/network-echo-memory`, needs about 135 KB and is a recorded image limit, as every form of address text, `runtime/network-addresses`, at about 45 KB, is. |
| `core/io` file system | The names `make_temporary` tries and the memory terminals run in `runtime/file-system-firmware`'s 18.7 KB image at size/auto, 22.2 KB at none/off. The memory volume does not fit the profile: its conformances link every entry of `reader`, `writer`, `files`, `directories` and `file_system`, so `runtime/volume-memory` needs about 106 KB at size/auto and is a recorded image limit, and a program over the volume alone that makes, writes, renames and reads one file still needed about 61 KB. |
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
An arena resize keeps a smaller block where it is, giving the top
allocation's tail back, and moves a block it cannot grow in place to the top.

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
`hosted/io` provider, `hosted/heap`, `platform/posix`, `platform/linux`,
`platform/libc` and the hosted C aliases in `platform/c` remain outside this
consumer closure. Even unused hosted declarations in a
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

## Migrating to host strings and the POSIX layer

A path, a process argument and a directory entry's name are host strings,
and the hosted providers are written once over `platform/posix`. Behaviour
is unchanged except where noted.

| Was | Now |
|---|---|
| `import hosted/linux`, `hosted/linux/numbers`, `hosted/libc` | `import platform/linux`, `platform/linux/numbers`, `platform/libc`; the modules are unchanged |
| a `ptr u8` path, NUL-terminated, to `open_read`, `open_write`, `same_file`, `open_directory`, `make_directory`, `remove_file` and `remove_directory` | a `text.host_string`; a literal one is `text.host_over("name")`, and the provider adds the NUL |
| `io.terminate_path(bytes, scratch)` | `text.host_over(bytes)`, which copies nothing |
| `io.open_read_bytes`, `open_write_bytes`, `open_read_text`, `open_write_text` | `io.open_read` and `io.open_write` of `text.host_over(bytes)` or `text.host_over(text.bytes(path))` |
| `io.empty_path`, `io.path_contains_nul`, `io.path_too_long` refused before the provider was called | the system's answer: an empty path is `not_found` with ENOENT, a path with a NUL `io_failed` with EINVAL, one longer than PATH_MAX `io_failed` with ENAMETOOLONG |
| `io.argument`, a pointer and a length | `text.host_string`, from `io.argument_at`; `io.memory_over`'s argument table is the arguments' bytes, `[][]u8`, which it lends as host strings, so a firmware test declares it as data |
| `io.copy_argument(argument, scratch)` and `io.argument_too_long` | `text.host_bytes(argument)`, which lends the argument's own bytes, and `text.from_host(argument)` for text |
| `io.entry`'s `name: []u8`, and `io.entry_size` taking `[]u8` | `name: text.host_string`, passed back to `io.entry_size` as it came |
| `io.directory`'s `descriptor: i32` | `handle: usize`, the provider's own |
| `io.file` as a `distinct i32` | a `distinct usize`, wide enough for any provider's identifier |
| Darwin and FreeBSD's heap over `malloc` | size classes over `platform/posix`'s mappings, as Linux's were; single-threaded on every system |

## Migrating to formatting and byte blocks

Text is built in a builder, written out through a buffered writer and read
back a line at a time. Behaviour is unchanged except where noted.

| Was | Now |
|---|---|
| a loop appending a byte string with `text.write_byte` | `text.append(builder, bytes)` |
| `used = try text.write_u64(into, used, value)` chains over a slice | `mut line := text.over(buffer)`, then `text.append_u64(line, value)` or `text.format(line, "{} {}\n", [any(addr a), any(addr b)])`, and `text.used(line)` |
| a decimal with a hand-written sign, or hexadecimal from a table of digits | `text.append_i64`, `text.append_hex_u32` and the others; `text.align_right(line, start, 2, 48)` zero-fills to a width |
| a parse of a signed number or of hexadecimal by hand | `text.parse_i32`, `text.parse_hex_u64` and the others; `number_overflow` now also means below a signed type's minimum |
| a byte-by-byte copy, fill or comparison loop | `mem.copy`, which allows overlap, `mem.fill`, `mem.compare` and `mem.find` |
| `io.write` for each small piece of output | `io.buffered_over(host, io.out(host), buffer)`, `io.put` and `io.flush`, with a `defer` flush on every way out |
| splitting what `io.read` returns into lines by hand | `io.lines_over(host, io.input(host), buffer)` and `io.read_line`, whose line is lent until the next read |

## Migrating to the environment and processes

A sixth concept reads the environment and a seventh runs programs.
Behaviour is unchanged except where noted.

| Was | Now |
|---|---|
| `_landin_host_initialize_arguments(argc, argv)` called by a C `main` | `_landin_host_initialize_arguments(argc, argv, envp)`, with `main`'s own `envp` or C's `environ`; a null table is an empty environment, and a declaration of two parameters beside a hosted `main` is L0347 |
| `platform/linux`'s `environment()`, or `getenv` declared `extern(c)` | `io.variable_named(host, name)` and `io.variable_at(host, index)` through the `io.environment` concept, on every hosted system and under `--link=libc` too; `environment()` still gives the raw table a static Linux entry found |
| `clone3`, `execve` and `wait4` by number, or `posix_spawn` declared `extern(c)` | `io.spawn`, `io.write_child`, `io.close_input`, `io.read_child` and `io.wait`, or `platform/posix`'s `pipe`, `spawn` and `wait` |
| a descriptor `platform/posix` opened, inherited by any program the process executed | closed on exec, `O_CLOEXEC`, as every descriptor the module makes is |
| `hosted.space` holding `failure` | `failure` and `signal`, the cell `hosted.last_signal` reads |

## Migrating to clocks and randomness

Three concepts beside the others give the time, sleeping and the system's
random bytes, and `core/random` a generator. Behaviour is unchanged except
where noted.

| Was | Now |
|---|---|
| `linux.system_call` with `numbers.clock_gettime_number`, or `clock_gettime` declared `extern(c)` | `io.now(host)` for the monotonic clock and `io.wall_now(host)` for the wall clock, or `platform/posix`'s `clock_time`; on Linux it reads the vDSO, and `linux.clock_gettime` is the system call |
| `numbers.clock_nanosleep_number`, or `nanosleep` declared `extern(c)`, retried by hand | `io.sleep(host, io.milliseconds(20))`, which sleeps on for what a signal left; `posix.sleep` is the one call |
| `numbers.getrandom_number`, or `arc4random_buf` declared `extern(c)` | `io.fill_random(host, buffer)`, or `posix.random_bytes` for one call |
| `linux.auxiliary(25)`'s sixteen bytes as a seed | `random.from_entropy(host)`, or `random.new(seed)` for a fixed sequence |
| a generator of your own | `core/random`'s `new`, `next`, `below` and `shuffle` |
| `hosted.system` as `world`, `directories`, `environment` and `programs` | the same, and `clock`, `wall_clock` and `entropy` too |

## Migrating to sockets

A network concept beside the others connects, listens and sends over TCP
and UDP. Behaviour is unchanged except where noted.

| Was | Now |
|---|---|
| `numbers.socket_number`, `bind_number`, `connect_number` and the rest through `linux.system_call`, or the BSD socket calls declared `extern(c)` | `io.listen`, `io.accept`, `io.connect`, `io.open_datagram`, `io.send`, `io.receive`, `io.send_to`, `io.receive_from`, `io.shutdown` and `io.close_socket` through the `io.network` concept, or `platform/posix`'s `socket`, `bind`, `listen`, `accept`, `connect`, `send` and the rest, Unix-domain sockets among them |
| a `sockaddr_in` built by hand, `sin_len` on Darwin and FreeBSD | `io.address`, from `io.loopback`, `io.ipv4_address`, `io.ipv6_address` or `io.parse_address`; `posix.internet_address` lays out each system's record |
| a write to a pipe or a socket nobody reads ending the process with SIGPIPE | the write failing: `posix.epipe`, `io.disconnected` from `io.send`, `io_failed` with EPIPE from `io.write`; the argument initializer ignores SIGPIPE when it finds the default, and `posix.spawn` gives each child the default back |
| `hosted.system` as `world`, `directories`, `environment`, `programs`, `clock`, `wall_clock` and `entropy` | the same, and `network` too |
| `scripts/linux_syscalls.py --tarball` to give a new wrapper its number | `scripts/linux_syscalls.py`, which writes `platform/linux/wrapped.ldn` from the committed numbers; the release is needed only to change the pin |

## Migrating to the rest of the file system

Two concepts beside the others give the rest of the file system and
terminals, and `platform/posix` the rest of POSIX's. Behaviour is unchanged
except where noted.

| Was | Now |
|---|---|
| `renameat2`, `pread64`, `pwrite64`, `ftruncate`, `fsync` and the rest by number through `linux.system_call`, or declared `extern(c)` on Darwin and FreeBSD | `io.rename`, `io.read_at`, `io.write_at`, `io.truncate`, `io.synchronize`, `io.status_of` and `io.current_directory` through `io.file_system`, or `platform/posix`'s `rename_at`, `read_at`, `write_at`, `truncate`, `synchronize`, `status_of` and `current_directory` |
| `io.open_write` and a file read back to append to it | `io.open_file(host, path, io.appending)`, and `io.creating` for a name no other file may have |
| a temporary name made up by the program and checked before it is opened | `io.make_temporary(host, host, directory, buffer)`, created exclusively under a name drawn from entropy |
| `posix.descriptor(i32(usize(file)))` for a hosted `io.file` | `hosted.descriptor_of(file)`, and `hosted.file_of(descriptor)` the other way |
| `posix.status` of device, inode, kind and size | the same and the permission bits, links, owner, group and three times |
| links, permission bits, owners, file times, locks and terminals by number or `extern(c)` | `posix.link_at`, `symbolic_link_at`, `read_link_at`, `change_mode_at`, `change_owner_at`, `set_times_at`, `lock`, `lock_range`, `terminal_mode_of`, `set_terminal_mode`, `raw_mode` and `open_pseudo_terminal` |
| /etc/passwd read by hand, or `getpwuid_r` declared `extern(c)` | `posix.account_with_id`, `account_named`, `group_with_id` and `group_named`, through the C library wherever there is one and from the files on a static Linux program |
| an open of a terminal that could make it the process's controlling terminal | every `platform/posix` open is `O_NOCTTY` |
| `hosted.system` as `world`, `directories`, `environment`, `programs`, `clock`, `wall_clock`, `entropy` and `network` | the same, and `file_system` and `terminals` too |

## Migrating container providers and indices

Allocator conformances now provide `grow(self, block, old_size, new_size,
alignment) -> bool`. A provider may always return false; refusal must change
neither storage nor provider state. Success retains the address and existing
bytes and transfers ownership of the enlarged extent to the caller, which
later frees that exact extent. Zero-byte vectors retain allocation and free
calls rather than using this extension path.

Allocator conformances now also provide `resize(self, block, old_size,
new_size, alignment) -> (moved: ptr mut u8) ! out_of_memory`, which may move
the block and keeps the bytes the two extents share. A provider that cannot
resize in place calls `mem.relocate(self, block, old_size, new_size,
alignment)` from it, which allocates, copies and frees through the provider.
`text.growing` now resizes through it rather than allocating and copying.

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
