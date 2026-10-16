# Library reference

The API reference is generated from public declarations and their `---` doc
comments in `core`, `hosted` and `platform`. It includes exact signatures,
source links, module browsing and local search. The comments also appear in
editor hover. The [library guide](../core/README.md) explains the shared
conventions and evidence; the [tour](../tour.md) teaches the language.

`core` is available on every enabled target. `hosted` requires a hosted
system. Each `platform` module declares a narrower target scope:
`platform/posix`, and beneath it each system's own interface,
`platform/linux` and `platform/libc`, serve the hosted POSIX systems,
Linux, Darwin and FreeBSD, and are refused on firmware. Availability does
not promise that every composition fits a particular firmware image. All
memory and handle lifetimes remain explicit caller obligations.

The examples below are existing compiler fixtures, included directly in the
rendered reference so the documentation does not maintain a second copy.
Their fixture metadata and target lanes determine where they execute.

## What the library does not cover yet

The library covers memory, containers, text, files, directories, standard
input and output, process arguments, the environment, running programs,
clocks, sleeping, the system's entropy, a deterministic generator and
blocking TCP and UDP sockets over IPv4 and IPv6, and `platform/posix` gives
POSIX's own files, directories, memory mappings, `poll`, pipes, children,
waiting, clocks, random bytes and sockets, Unix-domain ones among them, in
Landin types on Linux, Darwin and FreeBSD alike. A program that needs something neither
covers yet reaches the operating system itself, and the route differs
between Linux and the C library's systems:

| Need | Planned | Route until then |
|---|---|---|
| Calendars, time zones and formatting a date | the locale record in the register | The wall clock's seconds since 1970 are `io.wall_now`'s; turning them into a date is the program's. |
| Resolving a host name to an address | the resolver record in the register | Under the C library, on Darwin, FreeBSD and Linux under `--link=libc`, `getaddrinfo` declared `extern(c)`; a static Linux program has none. `io.parse_address` reads an address that is already written as one. |
| Sockets that do not block, many connections in one thread | an event-driven Io | `platform/posix`'s `poll` over the sockets' descriptors, `posix.descriptor(i32(usize(socket)))` for a hosted `io.file`, before a call that would otherwise wait; a socket's time limits bound each wait. |
| Threads | the threads item | Nothing safe yet: the hosted providers keep process-wide state, and there is no thread-local storage. |
| Renaming, links, permissions, file times, seeking, appending | not yet planned | On Linux, the call's number from `platform/linux/numbers` through `linux.system_call`; on Darwin and FreeBSD, the C function declared `extern(c)`. |

Every Linux system call is reachable this way. `platform/linux/numbers`
names each call's number, generated from a pinned kernel release, and
`linux.system_call` makes the call with six integer arguments and returns
the kernel's result, minus the errno on a failure. Nothing checks those
arguments: a pointer goes as `i64(usize(p))`, and a flag or a record is the
program's to get right for each architecture. Prefer a typed wrapper where
`platform/linux` has one, and `platform/posix` where it gives the call.

## core/mem

Memory providers and typed storage: the foundation for allocation, initialized prefixes and caller-owned backing.

Use `allocator` evidence to supply storage explicitly. A provider is a handle passed by value, `memory` in every signature, so several containers share one without locking it. `arena` is monotonic and has no reset: its allocations end with its backing. `arena_over` fills the caller's `arena_space`, declared `zeroed` beside the backing, and returns the handle from it. `aligned_offset` is the arithmetic a bump provider of your own needs. Typed storage over caller bytes comes from `storage_over`; it does not establish ownership or prove alias lifetimes. Use the same provider and extent when freeing a block. Deterministic failure injection over any provider is `core/fault`.

Byte blocks are slices with their lengths checked. `copy` puts every byte of a source at the start of a destination with `memmove`'s rule, so the two may overlap in either direction, and reports `out_of_bounds` before writing anything when the destination is shorter; `fill` sets every byte; `compare` orders two byte strings as `less`, `equal` or `greater`, the first differing byte deciding and a proper prefix first, which is C's `memcmp` with the lengths taken into account and the order `ls` gives names in the C locale; and `find` gives the index of a byte's first occurrence, or the slice's length when there is none, so `source[0..<find(source, v)]` is always the part before it. They are plain loops; a faster copy keeps these contracts. `runtime/core-mem-blocks` copies both ways within one array.

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

Byte cursors, validated UTF-8 views, byte search, a text builder, formatting and parsing numbers.

Cursors advance by bytes. `from_bytes` validates bytes as UTF-8 and reports `invalid_text` when they are not, and `valid` answers the same question without a view; the `utf8(bytes)` conversion validates too but traps on malformed input. A `text.position` indexes `utf8` by byte offset, while a `usize` index into `utf8` counts scalars, so do not index with `offset(position)`. This module does not turn byte offsets into validated character boundaries. UTF-8 equality, hashing and ordering use encoded bytes, with no normalization or locale collation. Views borrow their input.

A host string, `host_string`, is a path, a process argument or a directory entry's name in the representation its system gives and takes: bytes on Linux, Darwin and FreeBSD, which need not be UTF-8. It is never converted on the way through, so an argument passed on as a path reaches the system as it was given. `from_host` is its checked conversion to `utf8`, reporting `invalid_text` as `from_bytes` does; `host_bytes` lends its bytes; `host_equal` compares it with a literal; and `host_over` makes one over the caller's bytes, `text.host_over("input.txt")` for a literal path. A host string lends what it was made from. The NUL a C call needs is never the caller's: `platform/posix` adds it beneath the provider and refuses a path that holds one.

A `builder` writes text into bytes a piece at a time. `over` makes one over the caller's buffer, which never grows, and `growing` one that takes its storage from an erased allocator, `text.growing(any(addr heap))`, doubling what it holds and giving it back with `release`. It is a value the caller passes `inout`; `used` lends what it holds until it next changes, `length` is the offset the next piece begins at, `clear` empties it and `truncate` cuts it back. Each append writes its whole piece or reports `no_space` and leaves the builder as it was: `append` for bytes as they are, the byte string a listing used to append by hand, `append_byte`, `append_text` for `utf8`, `append_host` for a host string's bytes, `append_u32`, `append_u64` and `append_usize` in decimal, `append_i32`, `append_i64` and `append_isize` with a `-` before a negative value, and `append_hex_u32`, `append_hex_u64` and `append_hex_usize` in lower-case hexadecimal with no `0x`. A narrower integer widens at the call. Width and padding apply to whatever was written since an earlier `length`: `align_right` puts a fill byte before the piece until it is as wide as the field, and `align_left` after it; the fill goes before a sign too, so a zero fill suits an unsigned value.

`format` appends a template with each `{}` replaced by the next of an array of `any formattable` values, and `{{` and `}}` written as braces. A placeholder takes nothing else; width, padding and hexadecimal are the typed calls. Nothing runs at compile time, so the template is checked against the values when it runs: a different number of placeholders, or a brace that is neither part of `{}` nor doubled, is `invalid_format`, and nothing is written, and a builder that fills partway is put back before `no_space` is reported. `formattable` has one entry, `append`, which writes a value into a builder through a pointer to it; the library supplies it for the ten integer types in decimal, `bool` as `true` or `false`, `utf8`, `[]u8` and host strings, and a program declares it for a type of its own. The values are an array literal written at the call, which lends it as a slice: `text.format(line, "{} {}\n", [any(addr count), any(addr name)])`. No locale is consulted anywhere: the same values give the same bytes everywhere. `runtime/core-text-format-firmware` builds and formats a line within a Cortex-M0 image.

Parsing is the mirror of the appends, over a byte slice that need not be UTF-8. `parse_u8` to `parse_u64` and `parse_usize` read nonempty ASCII digits; `parse_i8` to `parse_i64` and `parse_isize` read an optional `-` before them, never a `+`, since no append writes one; `parse_hex_u32`, `parse_hex_u64` and `parse_hex_usize` read hexadecimal digits of either case with no `0x`. Anything else, a space included, is `invalid_number`, and a value outside the type, above its maximum or below a signed minimum, is `number_overflow`, whichever the scan from the left meets first. `usize` and `isize` are the target's, 32 bits on Cortex-M. `to_u32` is `parse_u32` over a `utf8` view, and the older `write_u32`, `write_u64` and `write_usize` still append a decimal to a slice at a `used` count, which the builder's appends are written over.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-text/main.ldn)

## core/io

Reader, writer, file and process capabilities, their world composition, directories, running programs, clocks, entropy and the network beside them, internet addresses, an in-memory provider and fakes, a buffered writer and a line reader.

Use the smallest concept a consumer needs. A provider is a handle passed by value, `host` in every signature, and an erased capability is built from the address of a handle binding, `any(addr host)`; using a handle locks nothing, so a program and its logger write through one, and two lent arguments and a query are live at once. An erased world can lend `writer_of` to a writer-only consumer. Providers retain authority over files and arguments. `process` lends the three standard streams, `input`, `out` and `err`, and the argument table, `io.out(host)`; standard input is read through `reader` like any file, and a read of zero bytes into a nonempty buffer is its end. A path and an argument are host strings, `text.host_string`, so an argument passed on as a path is never converted; `memory_over` takes the arguments as their bytes, lent back as host strings, so a table can be static data; it fills the caller's `memory_space`, whose limits and counters stay readable and settable, and keeps all storage with the caller, the bytes its standard input reads among them. `directories` is a fifth concept beside the four, and not part of `world`: a program that lists, makes or removes directories names it as well. `open_directory` takes a buffer from the caller and returns an open `directory`, a value the caller passes `inout` to `read_entry`, which refills the buffer as entries are read. Each entry's name is a host string that need not be UTF-8, lent from the directory until the next read, so a name kept past it is refused [0800] and a program copies the names it keeps; an empty name is the end. `.` and `..` are never listed, and the order is the system's. `entry_size` asks the open directory for an entry's size by name as a `u64`, not following a symbolic link. `make_directory`, `remove_file` and `remove_directory` change the tree. A missing path, and a path through or to something that is not a directory, are `not_found`; a name already taken is `already_exists`. Close a directory through the provider that opened it; one dropped unclosed keeps what its provider holds for it until the process ends. The memory world's directories are its slots' names before a `/`, so it lists them and reports their sizes but changes nothing.

The environment is a concept of its own, `environment`, outside `world`, so a provider without one and a firmware image that never asks for one carry none of it: `variable_count` counts its variables, `variable_at` lends the one at an index, an `io.variable` of a name and a value, and `variable_named` lends the value of the first variable with a name, compared as bytes, or reports `no_variable`. Names and values are host strings that need not be UTF-8, lent from the provider for as long as the process lives. The environment is read-only: a process does not change its own, which is not safe beside threads, and gives a child the environment it builds instead. `variables_over` makes a `memory_variables`, an environment provider over a table of `NAME=value` byte strings, which firmware can declare as data.

`programs` is a seventh concept, outside `world`, for running other programs. `spawn` starts the program at a path, a host string, never looked up on a search path or handed to a shell, with the arguments it sees after its own name and exactly the variables the caller builds, and connects each of its three standard streams as `child_streams` says: `inherited`, the parent's own; `discarded`, connected to nothing; or `piped`, the parent holding the other end. `inheriting`, `capturing` and `discarding` are the common three. A missing program is `not_found`, one the caller may not run `no_access`, and on any failure no child exists. The `child` it returns is a value the caller keeps, whose fields are the provider's: `write_child` writes to its piped input and `close_input` closes it, so that the child reads to its end, and `read_child` reads its piped output and errors together, waiting until either has something and saying which it read, so that a child writing more than a pipe holds to both never waits on a full one. The hosted provider's pipes are its own files, which `reader` and `writer` also take, a line reader over a child's output among them; the memory world's are not. `wait` closes every pipe the child still has, waits for it, and reports how it ended, an `ending` whose variant part is `exited` with a code or `signalled`, ended from outside, whose detail is the provider's; it consumes the child. A child never waited for keeps what its provider holds for it until the process ends. Close a child's pipes only through `close_input` and `wait`, never through `files`. `scripted_over` makes `scripted_programs`, a programs provider beside a memory world over the caller's `scripted_program` records, a provider of its own so that a world that runs no program carries none of its code: one at a given path writes the given output and errors when it starts, as each stream says, an inherited one into the world's own standard output or error, keeps what its parent writes to its piped input with `write_child`, records how many arguments and variables it was given and how often it started, and ends as it is told. `runtime/run-shell-memory` runs the published shell runner over it.

Time is two concepts outside `world`, so an image that never asks the time carries neither. `clock` is a monotonic clock, `now`, which never goes back, and sleeping on it, `sleep`, which returns once at least the span asked has passed on that clock and never sooner; `wall_clock` is the system's UTC time, `wall_now`, a `wall_time` of seconds since 1970 and the nanoseconds after them, which the system may set and so may go back, so a task is timed with `clock`. A reading is an `instant` and a span a `duration`, each a distinct `u64` of nanoseconds, which holds 584 years: `u64(at)` is the count, two of a kind compare with `==`, `<>`, `<`, `<=`, `>` and `>=` as their counts do, and neither has arithmetic of its own, so `elapsed` is the span between two readings taken in order, trapping if the second is the earlier, `later` a deadline, `nanoseconds`, `microseconds`, `milliseconds` and `seconds` make a span, trapping past 584 years, and `in_milliseconds` rounds one down. There is no floating point, and the arithmetic is the same on every target. Calendars, time zones and formatting a date are not here. `clock_over` makes a `manual_clock` over the caller's `clock_space`, which moves only when a test says: `advance` moves both its clocks, a `sleep` advances them by exactly what it asks and returns at once, the test may set either reading through the state, and the state counts readings, sleeps and the time slept. `entropy` is a third, `fill_random`, which fills all of a buffer with unpredictable bytes or fails `io_failed`; `entropy_over` makes `scripted_entropy` over the caller's bytes, given in order, a request for more than is left failing, so a program that seeds itself from entropy runs the same in every test. `runtime/clock-manual` and `runtime/random-sequence` run both fakes on Cortex-M0.

The network is one more concept outside `world`, `network`, so an image that never connects carries none of it. It is a reader and a writer of its own sockets as well, so a connection is read and written through `read` and `write`, a line reader and a buffered writer among them, whose failures are `io_failed`; `send` and `receive` say more, `timed_out` when a limit has passed and `disconnected` when the peer has gone, and a `receive` or `read` of zero is the end of what the peer sends. `listen` takes an address and returns a listener, port 0 for a free port that `local_address` then gives, and may take an address its own closed connections still hold, never one another socket listens at, which is `address_in_use`; `accept` takes the next connection; `connect` makes one, `refused` where nothing listens and `unreachable` where no route leads; `open_datagram` binds a UDP socket, `send_to` sends a datagram whole and `receive_from` gives the next with its `sender`, cutting one longer than the buffer; `shutdown` stops `receiving`, `sending` or `both_directions`; `peer_address` names a connection's other end; `set_timeouts` limits how long a receive, an accept and a send wait, zero for no limit; `set_no_delay` turns Nagle's algorithm off; and `close_socket` closes a socket. An address the system does not have, or a family it lacks, is `address_unavailable`. Every call waits as a blocking socket does, so one thread can connect to its own listener and send before it accepts, since the system completes the handshake, but a receive waits for its peer. An `address` is a family, `ipv4` or `ipv6`, sixteen bytes and a port: `loopback`, `unspecified`, `ipv4_address`, `ipv6_address` and `with_port` make one, `same_address` and `is_unspecified` compare, `parse_ip` reads `192.0.2.1` or `2001:db8::1` and `parse_address` `192.0.2.1:80` or `[2001:db8::1]:80`, refusing a leading zero, a zone and anything else with `invalid_address`, and `append_ip` and `append_address` write them back as RFC 5952 does, lower case, the longest run of zero groups shortened and an IPv4-mapped address in dotted decimal; an address is `text.formattable`. Nothing here resolves a name. `network_over` makes a `memory_network` over the caller's `network_socket` records, each made by `socket_over` from a buffer that is its receive buffer, and a `network_space` whose counters a test reads: a machine of loopback addresses on which a connection and a datagram arrive at once, whole and in order, a datagram no socket takes is lost and counted, and a call that would wait answers `timed_out` at once, since nothing in one thread could ever end the wait. A test may take IPv6 away with `without_ipv6` and fail a call with `fail_at`. `runtime/network-echo-memory` runs the published echo over it, and `runtime/network-addresses-firmware` reads and writes addresses on Cortex-M0.

A `buffered_writer` gathers writes to one file in a buffer the caller supplies and hands them to a writer when the buffer fills or the program flushes it. `buffered_over` makes one from a writer's handle, the file and the buffer; `put` writes bytes through it, flushing first when they do not fit and sending bytes as large as the buffer straight to the writer; `flush` writes what waits; and `pending` says how many bytes do. A failed flush reports the writer's `io_failed` and keeps every byte the writer did not take, so the next flush writes each byte once. There are no destructors: bytes still waiting when the program ends are never written, so flush before every way out, `defer io.flush(out) else ...` being the idiom, and flush where the bytes must be out before something else happens.

A `line_reader` reads a file through a buffer the caller supplies and lends it back a line at a time, as a directory lends its names: `lines_over` makes one from a reader's handle, the file and the buffer, and `read_line` gives the next `line`, its bytes lent from the reader until the next read. A line ends at `\n`, and a `\r` just before it is part of the ending, so text written with `\r\n` reads as text written with `\n`; a lone `\r` is an ordinary byte, and the last line need not end. The end of input is a line that has `finished`, every time it is asked again; an empty line has not. A line that does not fit the buffer with its ending is `line_too_long`, and the rest of it is skipped, so the next read gives the line after it. `runtime/core-io-buffered-writer` and `runtime/core-io-line-reader` run both over the in-memory provider, failures included.

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

## core/random

A deterministic generator of pseudorandom numbers, the same sequence for a seed on every target.

`generator` is xoshiro256** 1.0, Blackman and Vigna's, 256 bits of state that each draw advances, a value the caller keeps and passes `inout`. `new` seeds it from a `u64` through splitmix64, as its authors suggest, and `from_entropy` from 32 bytes of any `io.entropy` provider, the hosted system's or a test's scripted bytes. `next` draws 64 bits and `next_u32` the upper 32; `below` draws a value under a bound with each equally likely, by masking to the bound's width and drawing again when the value is too large, so no division is made and no value is favoured, and traps for a bound of zero; `shuffle` puts a slice in a uniformly drawn order. It uses shifts, exclusive ors and additions on `u64`, so a Cortex-M0 draws what a 64-bit host draws, and its sequences are the reference implementation's, which `runtime/random-sequence` holds on every target. It is not cryptographic: its outputs reveal its state, so a key, a token or a password comes from `io.fill_random` directly.

[Executable example](../compiler/tests/fixtures/runtime/random-sequence/main.ldn)

## hosted/heap

An explicit allocator over the host runtime heap.

`host` returns a handle that borrows nothing: the heap belongs to the process. Allocations remain manual obligations; no ambient allocator is installed, and containers still receive the provider explicitly. Blocks are not grown in place. Every `usize` alignment is honoured by over-allocating and keeping a header before the block. The provider keeps eight size classes, of 32 to 4096 bytes, over chunks it maps through `platform/posix`, written once for every hosted system: a freed slot goes back on its class's list and is the next one handed out, and a larger request is a mapping of its own, rounded to the system's page and unmapped when it is freed. It is single-threaded. A refusal comes before any state changes.

[Executable example](../compiler/tests/fixtures/runtime/hosted-heap-provider/main.ldn)

## hosted/io

Hosted file, stream and process operations, written once over `platform/posix`.

`system` supplies the shared I/O concepts. `host` exposes process arguments, lent as host strings, and standard streams, from the root the hosted entry establishes through `platform/posix`'s `_landin_host_initialize_arguments`; a C `main` that drives Landin exports calls that initializer itself. Standard input, output and error are descriptors 0, 1 and 2. Open-write creates or truncates regular files. A path that names nothing is `not_found`, whether a component is missing or one before the last is not a directory, ENOENT or ENOTDIR; `same_file` answers false for such an output path. `host` returns a handle that borrows nothing, since the root, the descriptors and its last-error cell belong to the process; `over` makes a handle that keeps its last errno in a `space` the caller declares, for a C thread or a library that must not share the process's. `last_errno` captures the terminal failing call as provider-specific detail, the number of the errno `platform/posix` failed with; it is not a portable error type. `last_signal` is the number of the signal that ended the child last waited for, beside `io.ending`'s `signalled`, and zero after a child that exited. A path that holds a NUL is `io_failed` with EINVAL, and one longer than the system's PATH_MAX with ENAMETOOLONG, as `platform/posix` refuses them. `system` also supplies `directories`. A directory's buffer must hold at least `io.directory_buffer`, 1024 bytes, or opening it fails with `io_failed` before anything is opened, so that every entry a hosted system gives fits. It is read through `platform/posix`'s directory streams, `.` and `..` left out. An entry whose type the file system does not record is asked with a status call relative to the directory. `make_directory` gives a new directory 0777, which the process umask filters, and is not retried when interrupted, because a directory made before the interruption would then report `already_exists`.

The environment is the one the process's entry was given, read where the entry left it, never copied and never changed. `system` also supplies `programs`, over `platform/posix`'s `spawn`: a discarded stream is the system's `/dev/null`, and a piped one a pipe whose child end is closed in the parent once the child has it. A child receives only its three streams, since every descriptor the provider makes is closed on exec and the spawn closes any other. `read_child` polls both pipes when both are open and reads the output first when both have something. `wait` closes the child's pipes before it waits, so a child still writing to one meets a closed pipe rather than a parent that never reads. An interrupted spawn, poll, read or wait is made again.

`system` supplies `network` too, over `platform/posix`'s sockets: a socket is a descriptor and a file of the provider like any other, so `read` and `write` take a connection. A listener reuses its address and an IPv6 socket takes IPv6 alone on every system, which BSD does from the start and Linux does not; up to 128 connections wait to be accepted. An interrupted call is made again, a connection a signal interrupted is waited out with `poll` and its outcome read from the socket, an accept refused because its connection was reset before it was taken accepts the next, and a send goes on after a short one until every byte is sent. A send to a peer that has gone is `disconnected`, EPIPE or ECONNRESET kept as the last errno, and a `write` to it `io_failed` with EPIPE: the process ignores SIGPIPE, so neither ends it.

`system` supplies `clock`, `wall_clock` and `entropy` too. `now` is `platform/posix`'s monotonic clock, in nanoseconds since the system started, and `wall_now` its realtime clock; a clock the system cannot read ends the program, since no hosted system fails to. `sleep` takes its deadline from the monotonic clock and asks the system to sleep for what is left until that clock has reached it, so a sleep a signal interrupts, or the system ends early, sleeps on, and it never returns before the deadline as `now` reads it. `fill_random` is `platform/posix`'s `random_bytes` until the buffer is full, asked again after an interruption: `getrandom` on Linux, which waits at boot until the kernel's pool is ready, and `arc4random_buf` on Darwin and FreeBSD. `runtime/clock-system` holds all three to their oracles, and the published shell runner times its child.

[Executable example](../compiler/tests/fixtures/runtime/core-io-erased-system/main.ldn)

## platform/posix

POSIX's facilities in Landin types, on Linux, Darwin and FreeBSD alike.

A `descriptor` is a handle type, not a number to count with, so descriptors compare with `==` and nothing else; `standard_input`, `standard_output` and `standard_error` are 0, 1 and 2, and `working_directory` is the directory an `*_at` call's relative path starts from. A failure is the errno as an atom of `errno`, one atom for each errno the three systems define, named after its C macro in lower case, `enoent` and `eintr` among them; `number` gives the number this system uses for an atom and `errno_of` the atom for a number, and `unlisted` is a failure with no errno this module names. A path or an argument is a host string, which the module copies into a buffer of the system's PATH_MAX with the NUL a C call needs, refusing one that holds a NUL with `einval` and one too long with `enametoolong`. The calls are POSIX's own, not policy: `open_at` with `open_options` (`reading` and `writing` are the two the hosted provider uses), `read`, `write`, `close`, `status_at` for a structured `status` of device, inode, kind and size, `open_directory`, `read_directory` and `close_directory` over a caller's buffer, listing `.` and `..` as POSIX does, `make_directory_at`, `unlink_at` and `remove_directory_at`, `map` and `unmap` for anonymous memory and `page_size`, `exit`, and `poll` over entries made by `watch` and read by `happened`, whose `poll_events` is a distinct flag set: `poll_input`, `poll_output` and `poll_urgent` are asked about, `poll_error`, `poll_hung_up` and `poll_invalid` only reported, combined with `|` and tested with `&` against `poll_no_events`. An interrupted call fails with `eintr` and is not retried here, and a short transfer is returned as it came. Every descriptor the module makes is closed when the process executes a program. `pipe` makes a pipe's two ends, with `pipe2` on Linux and FreeBSD and `pipe` and `fcntl` on Darwin. `spawn` starts a program by its path with its arguments after `argv[0]`, which is the path, and an environment of `core/io`'s `variable` records, its standard streams duplicated from three descriptors, `standard_streams`, of which `inherited_streams` are the parent's own; every other descriptor is closed in the child, and a failure, `enoent` for a missing program and `einval` for a NUL in an argument or a bad name, starts nothing. On Linux it copies the process with `clone`, as `fork` does, and the child moves its streams into place and executes the program, reporting a failure through a pipe closed on exec; on Darwin and FreeBSD it is the C library's `posix_spawn`. `wait` is `waitpid`, reporting a `child_status` whose variant part is `exited` with a code or `signalled` with the signal's number, which each system numbers its own way. `clock_time` reads the `monotonic_clock` or the `realtime_clock` as a `time_value` of seconds and nanoseconds, POSIX's `clock_gettime`: on Linux through the vDSO's `clock_gettime` when the auxiliary vector names a vDSO that has one, found once and kept, under `--link=libc` as under a static link, and the system call otherwise; on Darwin and FreeBSD through the C library. On Linux `_landin_host_initialize_arguments` hands `platform/linux` the tables it is given, so that a program the C runtime started finds the auxiliary vector after the initial stack's `envp` too. `sleep` is `nanosleep`, failing `eintr` with part of the span unslept, on Linux `clock_nanosleep` on the monotonic clock. `random_bytes` fills a buffer with the system's random bytes, `getrandom` without `GRND_NONBLOCK` on Linux, which may fill a request over 256 bytes short and fail `eintr`, and `arc4random_buf` on Darwin and FreeBSD, which fills it all and never fails. The process's arguments and environment are its root, established by `_landin_host_initialize_arguments` from C's `argc`, `argv` and `envp`, and read through `arguments` and `argument`, `environment` and `variable`; `program_name` is `argv[0]`. The sockets are POSIX's too: `socket` of a `socket_family`, `internet`, `internet6` or `local` for Unix-domain sockets, and a `socket_kind`, `stream` or `datagram`; `socket_pair` for two connected Unix-domain sockets; `bind`, `listen`, `accept`, `connect`, `send`, `receive`, `send_to`, `receive_from`, `shutdown` with a `shutdown_side`, `socket_name` and `peer_name`; and the options `set_reuse_address`, `set_no_delay`, `set_ipv6_only`, `set_receive_timeout`, `set_send_timeout`, `receive_timeout` and `pending_error`, which fails with the error pending on a socket. The receive limit bounds an `accept` on every system, `eagain` when it passes: Linux's kernel limits it, and on Darwin and FreeBSD, which do not, `accept` polls for a connection for as long as the limit first. A `socket_address` is the system's own record, laid out here for each system, Darwin's and FreeBSD's length byte included: `internet_address` makes one from an `io.address`, `unix_address` from a path, refusing one too long for the system's 108 or 104 bytes, and `family_of`, `address_of` and `unix_path` read one back. Every socket is closed on exec, with SOCK_CLOEXEC on Linux and FreeBSD and `fcntl` just after on Darwin, and a send to a peer that has gone fails `epipe` without raising SIGPIPE: Linux sends with MSG_NOSIGNAL, and Darwin and FreeBSD set SO_NOSIGPIPE on each socket. `closed_on_exec` says whether a descriptor is. The argument initializer ignores SIGPIPE when it finds the default, so that a write to a pipe or a socket nobody reads is `epipe` and not the end of the process, while a handler a C `main` installed first is kept; `broken_pipe_ignored` says whether it is ignored, and `spawn` gives every child SIGPIPE's default back, in Linux's child before it executes the program and through `posix_spawnattr_setsigdefault` on Darwin and FreeBSD. A program that imports no part of the POSIX layer keeps the system's default. It is written twice beneath its interface, over `platform/linux`'s system calls and over `platform/libc`, and a system that is not POSIX, as Windows is not, has none.

[Executable example](../compiler/tests/fixtures/runtime/posix-files/main.ldn)

## platform/libc

The C library's declarations, as ordinary `extern(c)` imports, raw.

On Darwin and FreeBSD, whose C library is their system interface, `platform/posix` reaches the operating system only through this module; on Linux it makes `platform/linux`'s system calls, and this module serves a program linked with `--link=libc`. Its scope is the systems with a C library, Linux, Darwin and FreeBSD. Every declaration is bodyless, so a program that names none of them needs no C library, and a static Linux program that names one is refused before it links. `open` and `openat` are declared variadic, as C declares them, and take the mode as the one unnamed argument. Facts that differ between systems are chosen by `compiler.os`: the errno accessor `errno_cell`, `__errno_location` on Linux and `__error` on Darwin and FreeBSD, the `open` and `mmap` flags and `poll`'s count type; `stat`'s record follows the system and the C ABI. Read the errno cell immediately after a failing call. A `malloc` result is the `allocation` union, so the null pointer is `no_allocation` rather than a pointer, and `mmap`'s failure is `map_failed`. The process calls are `pipe`, `pipe2` where it exists, the variadic `fcntl`, `waitpid` and `posix_spawn` with its file actions and attributes, each a C-library pointer in a `spawn_object` cell, with Darwin's `posix_spawn_cloexec_default` and `addinherit_np` and FreeBSD's `addclosefrom_np`; `posix_spawn` reports its failure as its result, not in errno. The directory calls are `fdopendir`, `readdir`, `closedir`, `fstatat`, `mkdirat` and `unlinkat`, with each system's `struct dirent` as `directory_record`, its `at_fdcwd`, `o_directory`, `at_symlink_nofollow` and `at_removedir`, and the `d_type` and mode bits; `readdir`'s and `fdopendir`'s null pointer is `no_directory`. `mkdirat`'s mode is 16 bits on Darwin and FreeBSD and 32 on Linux, as each system's `mode_t` is. `clock_gettime` takes a `clock_realtime` or a `clock_monotonic`, which is 1 on Linux, 6 on Darwin and 4 on FreeBSD, and `nanosleep` a `timespec`; `arc4random_buf` is Darwin's and FreeBSD's. The socket calls are `socket`, `socketpair`, `bind`, `listen`, `accept`, `accept4` on Linux and FreeBSD, `connect`, `send`, `recv`, `sendto`, `recvfrom`, `shutdown`, `setsockopt`, `getsockopt`, `getsockname` and `getpeername`, with each system's `af_inet6`, `sol_socket` and option numbers, `sock_cloexec` and `msg_nosignal` where they exist and `so_nosigpipe` on Darwin and FreeBSD, the address records' sizes and its `time_limit`, C's `struct timeval`, whose microseconds are an `int` on Darwin; an optional pointer is the `no_address` union. `sigaction` takes each system's `signal_action` and `signal_set`, and `posix_spawnattr_setsigdefault` with `posix_spawn_setsigdef` is Darwin's and FreeBSD's. A program that declares one of these C functions itself must declare it with the same types, or the two declarations of one C symbol are refused with L0347.

[Executable example](../compiler/tests/fixtures/abi/r440-native-hosted/program.ldn)

## platform/linux

Linux's system calls with no C library beneath them, and the process entry of a static Linux executable, raw.

Every declaration is Linux-only. Landin has no conditional import, so `platform/posix` imports this module on every system it serves, and the module's scope is theirs, Linux, Darwin and FreeBSD; on Darwin and FreeBSD it declares nothing. Each call is one assembly block on x86-64, arm64 and RV64, and a failure comes back in its result as minus the errno; there is no errno cell. The `*at` calls take `at_fdcwd` for a path relative to the working directory, and `statx`'s `file_status` is the kernel's one record on every architecture; `ppoll` is the poll call every architecture has. Every public routine has a link name of its own, `_landin_linux_` and the routine's name, so none of them replaces the C library's function of the same name under `--link=libc`. `_landin_start` is where a static executable starts: it reads `argc`, `argv`, the environment and the auxiliary vector from the initial stack and calls `main` as C's runtime would. Before `main` it holds the processor to the executable's CPU feature level, as a loader holds an x86-64 executable to its ISA note: `cpuid` and the operating system's enabled state on x86-64, AT_HWCAP on arm64 and `riscv_hwprobe` on RV64. A processor without a feature of the level ends the process with status 127 and one line on standard error naming the level and the missing feature; the baseline checks nothing. `level`, `read_cpu_words` and `missing_feature` expose the check. No C library initialisation runs and there is no thread-local storage. `environment` and `auxiliary` report what that entry found. When the C runtime started the program instead, under `--link=libc`, `adopt_start` takes the environment and the auxiliary vector from the `argc`, `argv` and `envp` C's `main` was given, which `platform/posix`'s argument initializer passes it, but only when they are laid out as the kernel lays out the initial stack: `argv` above the calling frame, `envp` right after `argv`'s null, every string above the tables, a vector ending in AT_NULL within 64 entries and before the lowest string, with AT_PAGESZ a power of two of at least 4096 and AT_RANDOM's bytes between the vector and the strings. Nothing above the lowest string is read. Tables a C `main` built itself, or C's `environ` after it changed, are not taken, and then `environment` and `auxiliary` find nothing and `page_size` is 4096, as before. `system_call` is the raw route to every Linux call: six `i64` arguments, unused ones zero, and the kernel's result; `platform/linux/numbers` names each call's number. The typed wrappers are the calls the library makes, `getdents64`, `mkdirat`, `unlinkat`, `ppoll`, `pipe2`, `dup3`, `fcntl`, `fork` (a `clone` with SIGCHLD and nothing shared), `execve`, `wait4`, `close_range`, `clock_gettime`, `clock_nanosleep`, `getrandom`, the socket calls from `socket` to `getpeername`, with `accept4`, `sendto` and `recvfrom` standing for the calls arm64 and x86-64 lack, and `rt_sigaction` with the kernel's `signal_action`, which RV64 lays out without a restorer, among them, and their numbers come from the same generated tables. The vDSO the kernel maps into every process is found through the auxiliary vector's AT_SYSINFO_EHDR: `vdso_image` is its bytes as far as its first load segment reaches, `vdso_find` finds a global or weak function by name and version in any image of a 64-bit little-endian ELF object, through its program headers, dynamic table, DT_HASH or DT_GNU_HASH, symbols and version definitions, and `vdso_symbol` gives the function's address. `vdso_clock_name` and `vdso_version` name its `clock_gettime`, `__vdso_clock_gettime` of `LINUX_2.6` on x86-64, `__kernel_clock_gettime` of `LINUX_2.6.39` on arm64 and `__vdso_clock_gettime` of `LINUX_4.15` on RV64, and `vdso_clock_gettime` is its C type. Every offset is held to lie within the image before a byte is read, so a malformed, truncated or foreign image finds nothing and never traps; `runtime/linux-vdso` damages a copy of the real one byte by byte to show it.

[Executable example](../compiler/tests/fixtures/runtime/linux-system-calls/main.ldn)

## platform/linux/numbers

Every Linux system call's number on x86-64, arm64 and RV64, generated from a pinned kernel release.

Each number is its call's name in the kernel's table followed by `_number`, `numbers.getpid_number` for one, so no number can take a reserved word's spelling. Give it to `linux.system_call`. The numbers are the kernel's own, read by `scripts/linux_syscalls.py` from each architecture's table with the ABIs that architecture's 64-bit build selects, x32's excluded; the file's header names the release and its SHA-256, and nothing in it is written by hand. A new typed wrapper in `platform/linux` needs no download: `scripts/linux_syscalls.py` with no release named holds this file to being its own rendering and writes the wrappers' numbers from it, and `--check` says whether they are current. The release is needed only to change the pin. A call the running kernel lacks returns minus ENOSYS. It is a module of its own, apart from `platform/linux`, so that a program making no raw call does not compile a thousand declarations; its scope is `platform/linux`'s, and on Darwin and FreeBSD it declares nothing.

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

