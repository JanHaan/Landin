# Repository-owned library modules

This guide is for programmers who use Landin's library: what each
namespace is available on, the conventions every module shares, and how
the library fits a small microcontroller. The
[library reference](../docs/library.md) has each call. The last part,
[for library contributors](#for-library-contributors), is for people who
change the library, and for programs written against an earlier version
of it: how to add a module, and what each change renamed.

These ordinary Landin modules use explicit roots and imports, with no user-code
module initialization. `spec.md` owns their language contracts, and the
[freestanding library lane](../environments/cortex-m/README.md#freestanding-library-consumers)
executes them on Cortex-M0.

## Availability inventory

The shared freestanding modules are `core/arena`, `core/atomic`, `core/cmp`,
`core/diag`,
`core/failure`, `core/fault`, `core/fibre` with its submodule
`core/fibre/stacks`, `core/io` with its submodules `core/io/fake` and
`core/io/signal`,
`core/map`, `core/mem`,
`core/net`, `core/panic`, `core/pool`, `core/random`, `core/region`,
`core/sort`, `core/spill`, `core/text`, `core/time`, `core/tree` and
`core/vec`. Every public interface is
available on every target, but for `core/fibre/stacks`, which switches
stacks through the compiler's stack builtins and is admitted only where the
target's backend emits them (D453); `core/fibre` itself, its groups over
`fibre.whole` and over the blocking host, needs no switch and serves every
target. `core/atomic`'s cells serve every target too, but for a `u64`
cell and the read-modify-writes, which Cortex-M0 has not and refuses where
a program uses them (D510). Their providers retain caller-supplied
authority.

`hosted/heap`, `hosted/system`, `hosted/blocking`, `hosted/events` and
`hosted/thread/lock`, the lock threads share state behind, require a hosted
system. Import the I/O provider, `blocking`, or `events`
for one whose fibres take turns over the system's event mechanism,
beside the shared `core/io` protocol it implements, with no alias; each
is built over `system`, which keeps the services that do not wait (D476,
D485). They are
written once, over `platform/posix`, which gives POSIX's facilities in
Landin types on Linux, Darwin and FreeBSD and would not exist on a system
that is not POSIX. Beneath it each system's own interface stays raw:
`platform/linux` declares Linux's system calls, which `platform/posix`
makes on Linux, and the raw `system_call` that makes any of them, and
`platform/linux/numbers` names every call's number, generated from a pinned
kernel release, and `platform/linux/vdso` finds functions in the vDSO; all
three declare nothing on Darwin and FreeBSD. `platform/libc` declares the C
library `platform/posix` calls on Darwin and FreeBSD, and which a Linux
program linked with `--link=libc` may call, its loader among it, which
`platform/posix` loads shared objects through on Darwin and FreeBSD and on
Linux under `--link=libc`, since a static Linux program has no loader
(D336); what every system declares alike is in `libc.ldn`, and each
system's own in a file of its own (D346). `platform/kqueue` declares
kqueue, the event interface Darwin and FreeBSD share, and nothing on Linux
(D481), as `platform/linux` declares epoll and signalfd and nothing on
Darwin and FreeBSD. The compiler names none of it. These `platform`
modules' scope is the hosted POSIX systems, and firmware refuses each by
name. `platform/c` holds the
currently enabled LP64 C ABI aliases; it does not admit Cortex AAPCS32 or
synthetic-32. `platform/cortex_m` holds M-profile CPU operations and admits the
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
| View over caller-supplied bytes or records, or a provider's handle over its caller-owned state | `over` | `arena.over(space, base, size)`, `mem.storage_over`, `pool.over`, `region.over(ledger, heap)`, `fault.over(space, inner, 3)`, `io.memory_over`, `io.variables_over`, `io.scripted_over`, `text.over(buffer)`, `io.buffered_over`, `io.lines_over` |
| A provider's caller-owned state | `space`, declared `zeroed` | `arena.space`, `pool.space`, `region.space(capacity)`, `fault.space`, `io.memory_space` |
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
`from` the state and may also be `from` that backing: `arena.space`
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
`release` never means anything but giving storage back. Names are
prefixed only where one module holds several types (`io.memory_over`). A
provider's counters are plural nouns: `pool.allocations`, `pool.frees`,
`fault.frees`. A module is named by a short noun or a conventional
abbreviation: `mem`, `vec`, `cmp`, `io`, `diag`, `map`, `sort`, `arena`, `pool`,
`spill`, `fault`, `failure` (D274).

Two atoms serve every core container: `mem.out_of_bounds` for an index past
the initialized prefix and `mem.empty` for taking from nothing. Key lookups
keep their own, `map.missing` and `tree.no_such_node`, because a missing key
is not a bad index. Every atom a `core` module fails with is in
`failure.reason` and has a phrase for a person in `failure.words`, lower case
with no final stop, so a program reports `settings: not found` without a
table of its own; a new failure atom adds its phrase there (D388).

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
Time is `core/time`'s two concepts, outside `world`: `clock`, a monotonic clock
that never goes back and sleeping on it, and `wall_clock`, the system's UTC
time, which may be set back and so never times anything. A reading is an
`instant` and a span a `duration`, each a distinct `u64` of nanoseconds,
584 years of them, with no floating point and the same arithmetic on every
target; two of a kind compare and are ordered directly, as every
distinct scalar type is, and `elapsed` traps rather than answer a negative
span. A sleep never returns early by its own clock. The
system's random bytes are a third, `entropy`. The fakes, in `core/io/fake`, are a
`fake.clock`, which moves only when the test advances it or something
sleeps on it, by exactly what was asked, and `fake.entropy`, the
caller's bytes in order, so a program that times itself, sleeps or seeds
itself gives the same answer in every test. `core/random` is the
deterministic generator: xoshiro256**, seeded from a `u64` or from any
`entropy`, drawing the same sequence for a seed on every target, Cortex-M0
included, uniform values below a bound without modulo bias and shuffles;
it is not cryptographic.
The network is `core/net`'s concept, outside `world`, `network`, so an image
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
`fake.network`, a machine of loopback addresses over the caller's socket
records and their buffers: a connection and a datagram arrive at once and
in order, a datagram no socket takes is lost, and, made with no scheduler,
a call that would wait answers `timed_out` at once, since nothing else in
one thread could end the wait. Made over a `fibre.turns`, a call that
would wait takes turns instead and times out only after a whole round in
which nothing in the network moved, so a client fibre and a server fibre
talk over it as over a real one (D449). A test can take IPv6 away from it
and inject a failure.
Signals reach a program as events, never as handlers: `core/io/signal`'s
`signals` concept refines `fibre.turns`, so only a provider whose fibres
take turns delivers them (D477), and a fibre waits for the next watched
signal as it waits for a receive. Its fake, `fake.signals`, takes the
signals a test raises, over the turns it is given.
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
The fakes are a `fake.volume`, a file system in memory over the
caller's nodes, with their paths, kinds and the room each file may grow
into, that conforms to `reader`, `writer`, `files`, `directories` and
`file_system` alike, and `fake.terminals` over the caller's screens.
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
| `core/mem` | `allocator` with `alloc`/`grow`/`resize`/`free` taking the handle by value, `allocate`/`resize`/`free`, `relocate` for a provider that resizes by moving, the `aligned_offset` a bump provider advances with, typed `storage`, `new`/`delete` and byte buffers. Byte storage can release its initialized prefix in one typed transition before disposal. Requests and capacities use target `usize`. Raw backing and its lifetime belong to the caller. |
| `core/arena` | The caller-backed monotonic `arena` over an `arena.space`, made by `over` or `over_unchecked`, with `used` and `reset`. Its state, its backing and their lifetime belong to the caller. A program that imports no provider, `core/arena`'s or another, still builds: an erased allocator call no conformance answers is a trap no value reaches (D377). |
| `core/vec` | `list`, `new`, `reserve`, `push`/`pop`, initialized views, length/capacity and `release`. Operations receive an allocator explicitly. Growth extends supported positive-byte blocks in place; otherwise it copies privately, rolls back on failure and publishes a complete replacement last. |
| `core/pool` | A provider handle over a caller's `pool.space`, its bytes and initialized slot metadata. A free-index heap gives lowest-index reuse in logarithmic time; exact frees find their slot by address. A growth or a resize keeps a block in its slot to any extent the slot holds, so a list over a pool grows in place until its slot is full (`runtime/core-pool-grow`, 16.5 KB at size/auto, and `runtime/core-pool-list-grows`, 23.3 KB) (D386). No backing allocation or fallback heap. |
| `core/sort` | Heapsort and selection sort by `cmp.ordered` evidence, and `sort_by`, heapsort by a comparison given a context, with no allocation; `runtime/core-sort-context`, which sorts records into a shared pool of names with `cmp.compare`, is 10.7 KB at size/auto (D387). |
| `core/failure` | `failure.words`, a phrase for each of the 32 library failure atoms: about 6 KB of code and text, linked only into a program that calls it (`runtime/failure-words`, 10.4 KB at size/auto) (D388). |
| `core/panic` | The canonical four-atom `panic_kind` domain. An entry-module public ordinary `(kind: panic.panic_kind, site: u32) -> noreturn` handler replaces the terminal default; no reporting or allocation dependency is imported. |
| `core/text` | A builder over a caller's buffer with byte, text, decimal, hexadecimal and aligned appends, and `format` over `any text.formattable`. At size/auto the bounded builder's core, `over`, `used`, `append`, `append_byte` and the room check, is about 4.9 KB with `mem.copy`; a `u32` decimal adds about 2.2 KB, a signed one 0.9 KB more, an aligned hexadecimal about 2.9 KB, and `format` with two conformances about 4.6 KB (`runtime/core-text-format-firmware`, 17.6 KB in all). A growing builder's doubling is reached only through the table `text.growing` builds, so it is linked, about 1.5 KB at size/auto and 1.9 KB at none/off, only into a program that calls `growing`, and no allocator is used unless the program builds a growing builder over its own. |
| `core/io` | Besides the concepts and the memory world, a buffered writer over the caller's buffer, about 5 KB at size/auto with `mem.copy`, and a line reader, about 7 KB with `mem.copy` and `mem.find` (`runtime/core-io-buffered-writer`, `runtime/core-io-line-reader`). |
| `core/random` | A generator of four `u64` words and its draws, written with shifts, exclusive ors and additions so the 32-bit core needs only `__aeabi_lmul` for seeding: `new`, splitmix64 and `next` are about 2.8 KB at size/auto, `below` 1.1 KB more and a shuffle of bytes about 1.6 KB, in `runtime/random-sequence`'s 16.3 KB image, which seeds from `core/io`'s scripted entropy too. |
| `core/io` time | The manual clock, its concepts and the span conversions run in `runtime/clock-manual`'s 11.3 KB image; nothing of them is in an image that does not use them. |
| `core/io` network | Reading and writing addresses run in `runtime/network-addresses-firmware`'s 29.8 KB image at size/auto, 31.9 KB at none/off, of which the address code is about 17 KB, `ipv6_octets` alone 4.6 KB. The memory network does not fit the profile: a provider's conformance table links every entry, about 40 KB of code, so its echo, `runtime/network-echo-memory`, needs about 135 KB and is a recorded image limit, as every form of address text, `runtime/network-addresses`, at about 45 KB, is. |
| `core/io` file system | The names `make_temporary` tries and the memory terminals run in `runtime/file-system-firmware`'s 18.7 KB image at size/auto, 22.2 KB at none/off. The memory volume does not fit the profile: its conformances link every entry of `reader`, `writer`, `files`, `directories` and `file_system`, so `runtime/volume-memory` needs about 106 KB at size/auto and is a recorded image limit, and a program over the volume alone that makes, writes, renames and reads one file still needed about 61 KB. |
| `platform/cortex_m` | M-profile PRIMASK save/disable/restore, mask observation, WFI and compiler/data/completion barriers. A target assertion refuses import on other targets. |

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
Their consumers explicitly import `platform/cortex_m` and optionally `core/panic`;
ordinary DMA slices retain the completion/boundary/lifetime obligations above.
No allocator, heap, scheduler or hosted initialization enters that closure.

The [derived driver](../compiler/tests/driver/DERIVATION.md) uses caller-owned
initialized static byte storage and the ordinary `platform/cortex_m` interface. It
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

## For library contributors

This part is for people who change the library, and for a program written
against an earlier version of it. Adding a module comes first; each
migration note after it says what one change renamed or reshaped.

The [library reference](../docs/library.md) is generated from public signatures
and attached `---` comments. Build it with `scripts/site.sh` and open
`docs/site/site/library.html`; [the site guide](../docs/site/README.md) describes
the documentation convention.

### Adding a module

A new `core/NAME` directory is known in four other places, and a full
`python3 check.py` names every one it is still missing from:

1. `'NAME'` in `MODULES` in `environments/cortex-m/freestanding.py`, the
   freestanding probe's inventory, which `environments/cortex-m/test.py`
   holds to the directories here;
2. the probe fixture `compiler/tests/fixtures/runtime/library-shared-NAME`,
   a `main.ldn` and `fixture.meta` as the others are;
3. that fixture's row in `compiler/tests/cortex-m/corpus.json`, which
   `python3 scripts/add_fixture.py runtime/library-shared-NAME` adds while it
   regenerates the corpus's generated files;
4. a `## core/NAME` section in `docs/library.md`, the module's overview in the
   library reference.

The availability inventory below then says which targets it serves.

### Container and diagnostic migration

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

### Migrating to the reviewed library

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

### Migrating to standard input

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

### Migrating to services as handles

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
| `region.new(addr heap)` and `defer region.release(program)` | `mut ledger: region.growing_space = zeroed`, `program := region.over(ledger, heap)` and `defer region.release(ledger, heap)` |
| `region.over(addr parent, records[0..<2])` over caller `region.allocation` records | `mut ledger: region.space(2) = zeroed` and `region.over(ledger, parent)`; release as above, then `over` again to reuse it |
| `mut memory := io.memory_over(...)` with `memory.write_limit = 2` and `memory.write_calls` | `mut state: io.memory_space = zeroed`, `memory := io.memory_over(state, ...)`, `state.write_limit = 2`, `state.writes`; `io.written(memory)` takes the handle |
| `mut host := hosted.host()`, `mut heap := heap.host()` | the same calls bound without `mut`; the handles borrow nothing |
| `hosted.last_errno(host)` reading the provider value | the same call, reading the cell the handle was made with: the process's from `host`, or a declared `hosted.space` from `hosted.over` |
| `diag.stream(addr writer, addr stream)` | `diag.stream(writer, stream)`; the logger holds copies |
| `io.writer_of(addr world)` | `io.writer_of(world)`; the adapter holds a copy of the erased world |
| a provider of your own holding its state by value | a handle holding `ptr mut` to the caller's state, with by-value `self` entries |

An allocation still borrows nothing from its allocator: a container keeps the
block in its own storage, which a block borrowed from a handle could not
reach without every container operation retaining the handle.

### Migrating to host strings and the POSIX layer

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

### Migrating to formatting and byte blocks

Text is built in a builder, written out through a buffered writer and read
back a line at a time. Behaviour is unchanged except where noted.

| Was | Now |
|---|---|
| a loop appending a byte string with `text.write_byte` | `text.append(builder, bytes)` |
| `used = try text.write_u64(into, used, value)` chains over a slice | `mut line := text.over(buffer)`, then `text.append_u64(line, value)` or `text.format(line, "{} {}\n", [any(addr a), any(addr b)])`, and `text.used(line)` |
| a decimal with a hand-written sign, or hexadecimal from a table of digits | `text.append_i64`, `text.append_hex_u32` and the others; `text.align_right(line, start, 2, u8('0'))` zero-fills to a width |
| a parse of a signed number or of hexadecimal by hand | `text.parse_i32`, `text.parse_hex_u64` and the others; `number_overflow` now also means below a signed type's minimum |
| a byte-by-byte copy, fill or comparison loop | `mem.copy`, which allows overlap, `mem.fill`, `cmp.compare` and `mem.find` |
| `io.write` for each small piece of output | `io.buffered_over(host, io.out(host), buffer)`, `io.put` and `io.flush`, with a `defer` flush on every way out |
| splitting what `io.read` returns into lines by hand | `io.lines_over(host, io.input(host), buffer)` and `io.read_line`, whose line is lent until the next read |

### Migrating to the environment and processes

A sixth concept reads the environment and a seventh runs programs.
Behaviour is unchanged except where noted.

| Was | Now |
|---|---|
| `_landin_host_initialize_arguments(argc, argv)` called by a C `main` | `_landin_host_initialize_arguments(argc, argv, envp)`, with `main`'s own `envp` or C's `environ`; a null table is an empty environment, and a declaration of two parameters beside a hosted `main` is L0347 |
| `platform/linux`'s `environment()`, or `getenv` declared `extern(c)` | `io.variable_named(host, name)` and `io.variable_at(host, index)` through the `io.environment` concept, on every hosted system and under `--link=libc` too; `environment()` still gives the raw table a static Linux entry found |
| `clone3`, `execve` and `wait4` by number, or `posix_spawn` declared `extern(c)` | `io.spawn`, `io.write_child`, `io.close_input`, `io.read_child` and `io.wait`, or `platform/posix`'s `pipe`, `spawn` and `wait` |
| a descriptor `platform/posix` opened, inherited by any program the process executed | closed on exec, `O_CLOEXEC`, as every descriptor the module makes is |
| `hosted.space` holding `failure` | `failure` and `signal`, the cell `hosted.last_signal` reads |

### Migrating to clocks and randomness

Three concepts beside the others give the time, sleeping and the system's
random bytes, and `core/random` a generator. Behaviour is unchanged except
where noted.

| Was | Now |
|---|---|
| `linux.system_call` with `numbers.clock_gettime_number`, or `clock_gettime` declared `extern(c)` | `time.now(host)` for the monotonic clock and `time.wall_now(host)` for the wall clock, or `platform/posix`'s `clock_time`; on Linux it reads the vDSO, and `linux.clock_gettime` is the system call |
| `numbers.clock_nanosleep_number`, or `nanosleep` declared `extern(c)`, retried by hand | `time.sleep(host, time.milliseconds(20))`, which sleeps on for what a signal left; `posix.sleep` is the one call |
| `numbers.getrandom_number`, or `arc4random_buf` declared `extern(c)` | `io.fill_random(host, buffer)`, or `posix.random_bytes` for one call |
| `linux.auxiliary(25)`'s sixteen bytes as a seed | `random.from_entropy(host)`, or `random.new(seed)` for a fixed sequence |
| a generator of your own | `core/random`'s `new`, `next`, `below` and `shuffle` |
| `hosted.system` as `world`, `directories`, `environment` and `programs` | the same, and `clock`, `wall_clock` and `entropy` too |

### Migrating to sockets

A network concept beside the others connects, listens and sends over TCP
and UDP. Behaviour is unchanged except where noted.

| Was | Now |
|---|---|
| `numbers.socket_number`, `bind_number`, `connect_number` and the rest through `linux.system_call`, or the BSD socket calls declared `extern(c)` | `net.listen`, `net.accept`, `net.connect`, `net.open_datagram`, `net.send`, `net.receive`, `net.send_to`, `net.receive_from`, `net.shutdown` and `net.close_socket` through the `net.network` concept, or `platform/posix`'s `socket`, `bind`, `listen`, `accept`, `connect`, `send` and the rest, Unix-domain sockets among them |
| a `sockaddr_in` built by hand, `sin_len` on Darwin and FreeBSD | `net.address`, from `net.loopback`, `net.ipv4_address`, `net.ipv6_address` or `net.parse_address`; `posix.internet_address` lays out each system's record |
| a write to a pipe or a socket nobody reads ending the process with SIGPIPE | the write failing: `posix.epipe`, `net.disconnected` from `net.send`, `io_failed` with EPIPE from `io.write`; the argument initializer ignores SIGPIPE when it finds the default, and `posix.spawn` gives each child the default back |
| `hosted.system` as `world`, `directories`, `environment`, `programs`, `clock`, `wall_clock` and `entropy` | the same, and `network` too |
| `scripts/linux_syscalls.py --tarball` to give a new wrapper its number | `scripts/linux_syscalls.py`, which writes `platform/linux/wrapped.ldn` from the committed numbers; the release is needed only to change the pin |

### Migrating to the rest of the file system

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

### Migrating container providers and indices

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

### Migrating to the second reading of the library

The library was read whole a second time after the hosted items (D340 to
D357). Rename as follows; behaviour is unchanged except where noted.

| Was | Now |
|---|---|
| `import hosted/io as hosted`, `hosted.host()`, `hosted.system` | `import hosted/system`, `system.new()`, `system.host`; `system.space`, `system.over`, `system.last_errno`, `last_signal`, `descriptor_of` and `file_of` keep their names |
| `heap.host()`, `heap.system` | `heap.new()`, `heap.heap` |
| `time.duration`, `time.instant`, `time.wall_time`, `time.clock`, `time.wall_clock`, `time.now`, `time.sleep`, `time.seconds` and the rest of time | `time.duration` and the rest, from `import core/time` |
| `net.network`, `net.address`, `net.connect`, `net.listen`, `net.send`, `net.parse_address` and the rest of the network | `net.network` and the rest, from `import core/net` |
| `fake.volume`, `fake.clock`, `fake.entropy`, `fake.network`, `fake.terminals` | `fake.volume`, `fake.clock`, `fake.entropy`, `fake.network`, `fake.terminals`, from `import core/io/fake`; each fake's `_space` and `_over` keep their names under `fake.` |
| `fake.volume_node`, `fake.network_socket`, `fake.screen` | `fake.volume_node`, `fake.network_socket`, `fake.screen` |
| `io.memory`, `io.memory_over` and the memory world's environment and scripted programs | unchanged, in `core/io` |
| a memory file's `opened: false, writing: false` | `state: io.closed_slot`; the provider sets `io.reading_slot` or `io.writing_slot` |
| a scripted program's `code` and `signalled` | `ending`, an `io.ending`: `(how: io.exited(code: 3))` or `(how: io.signalled)` |
| `child_read.errors` | `child_read.stream`, `io.child_output` or `io.child_errors` |
| `io.status_of(host, path, true)`, `false` | `io.status_of(host, path, io.following)`, `io.not_following` |
| `io.synchronize(host, file, false)`, `true` | `io.synchronize(host, file, io.data_and_status)`, `io.data_only` |
| the memory world's `read_calls`, `write_calls`, `open_calls`, `close_calls`; the memory network's `lost` | `reads`, `writes`, `opens`, `closes`; `losses` |
| `mem.compare`, `mem.less`, `mem.equal`, `mem.greater`, `mem.order` | `cmp.compare` and the rest, from `import core/cmp`; `[]u8` is now `cmp.ordered` too |
| `import platform/cpu`, `cpu.disable_interrupts()` and the rest | `import platform/cortex_m`, `cortex_m.disable_interrupts()` and the rest |
| `linux.vdso_symbol`, `vdso_find`, `vdso_image`, `vdso_clock_name`, `vdso_version`, `vdso_clock_gettime`, `vdso_largest` | `import platform/linux/vdso`: `vdso.symbol`, `find`, `kernel_image`, `clock_symbol`, `clock_version`, `clock_gettime`, `largest` |
| `libc.malloc`, `libc.free`, `libc.allocation` | removed; declare them `extern(c)` where a program wants C's heap |
| `vec.list`'s `values`, `spill.list`'s `storage`, `map.map`'s fields and `map.cursor`'s slot | private; use the modules' operations, `map.removed(value)` for the dead entries a map's `tombstones` counted |
| `text.write_byte`, `write_u32`, `write_u64`, `write_usize` and `prefix` over a slice and a `used` count | a builder: `mut line := text.over(buffer)`, `text.append_byte`, `append_u32`, `append_u64`, `append_usize` and `text.used(line)`; parsing is all in `core/text`'s `parse_*` |
| `append_byte(line, 32)`, `path[at] == 47` | `append_byte(line, u8(' '))`, `path[at] == u8('/')` |
| `hosted.file_of(socket)` for a socket written with `io.write` | `system.socket_of(socket)`, whose writes send without SIGPIPE; `net.connect`, `listen`, `accept` and `open_datagram` give such files, and a socket's `io.file` is no longer its descriptor's number: use `system.descriptor_of` |
| `random.below(source, 0)` trapping `unreachable` | trapping `overflow`, as a remainder by zero does |
| `posix.open_library` of an empty path giving the program itself | `enoent` |
| `linux.poll_limit` of `ptr timespec` | `ptr mut timespec`, which the kernel writes |
| a fake volume opening a dangling link, or a path through a link | the link's target made, and every link followed as a system follows it |
| `mem.arena`, `mem.arena_space`, `mem.arena_over`, `mem.arena_over_unchecked`, `mem.arena_used`, `mem.arena_reset` | `import core/arena`: `arena.arena`, `arena.space`, `arena.over`, `arena.over_unchecked`, `arena.used`, `arena.reset`; `mem.aligned_offset` stays in `core/mem` (D377) |
| `mem.grow_storage` with its three extents, and each container's own extent check and release | `mem.reserve_storage`, `mem.storage_extent` and `mem.release_storage`; `grow_storage` is private |
| a fault injector that refused every growth in place | an injector that spends a permit on each growth and delegates it, counted by `fault.growths`; `fault.successes` is the blocks it gave |
| `region.space(0)` for a growing ledger | `region.growing_space` |
| a builder over a copy of a formatted line for a buffered writer | `io.format(out, template, values)` into the writer's buffer |
| a routine asking for `io.file_system` and `io.files` to open and close | `io.file_system` alone, which refines `files` |

New since: `tree.kind`, `tree.leaves` and `tree.children`; `spill.clear`,
`spill.last` and `spill.reserve`; `diag.message`; `mem.arena_reset`;
`mem.grow`; `map.removed`; `io.format`; and `platform/posix` and `platform/libc` laid out one file per
facility and per system (D346).

### Migrating to what the newcomer's path met

Three things an outside program met in the library are answered (D386 to
D388).

| Was | Now |
|---|---|
| a pool that refused every growth in place, so a container over it grew into a second slot and a one-slot pool refused the growth | `mem.grow` through a pool keeps the block in its slot to any extent the slot holds; a container grows in place, its counters show one allocation and no free for the growth, and a growth past the slot is still refused |
| a sort written by hand for records that refer into shared storage | `sort.sort_by(values, by, less)`, the comparison given the context on every call |
| a program's own table from failure atoms to messages | `failure.words(problem)`, from `import core/failure` |
