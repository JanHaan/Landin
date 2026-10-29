# Library reference

Landin's library is ordinary Landin source, shipped with the compiler, in
three namespaces:

| Namespace | Available on |
|---|---|
| `core` | Every enabled target, firmware included. |
| `hosted` | A hosted system only. |
| `platform` | The narrower target scope each module declares. |

`platform/posix`, and beneath it each system's own interface,
`platform/linux` and `platform/libc`, serve the hosted POSIX systems:
Linux, Darwin and FreeBSD, as does `platform/kqueue`, the event interface
of Darwin and FreeBSD. They are refused on firmware.

Availability does not promise that every composition fits a particular
firmware image. All memory and handle lifetimes remain explicit caller
obligations.

## Common tasks

This program does the common tasks of a small tool in one place. It
numbers the lines of the file named on the command line, as `cat -n`
does, and when the file cannot be read it says why on standard error:

```landin
--  Number the lines of the file named on the command line, as `cat -n`
--  does, and say in words why when it cannot be read.
import core/failure
import core/io
import core/text
import hosted/blocking

--- Write each line of the file at `path` to `out` after its number.
numbered: (inout out: io.buffered_writer(blocking.host), host: blocking.host,
           path: text.host_string) -> none ! ... =
    file := try io.open_read(host, path)
    defer io.close(host, file) else none
    mut buffer: [4096]u8 = zeroed
    mut lines := io.lines_over(host, file, buffer)
    mut number: u64 = 0
    loop do
        item := try io.read_line(lines)
        break when item.finished
        inc number
        try io.format(out, "{}: {}\n", [any(addr number), any(addr item.bytes)])
    end loop
end numbered

public main: () -> (code: i32) =
    host := blocking.new()
    mut storage: [256]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none
    code = 1
    path := io.argument_at(host, 0) else (problem)
        io.write(host, io.err(host), "usage: number FILE\n") else none
        return
    end
    numbered(out, host, path) else (problem)
        io.write(host, io.err(host), text.host_bytes(path)) else none
        io.write(host, io.err(host), ": ") else none
        io.write(host, io.err(host), failure.words(problem)) else none
        io.write(host, io.err(host), "\n") else none
        return
    end
    code = 0
end main
```

- `numbered` can fail, so its signature ends in `!`. `! ...` asks the
  compiler to work out the set from the body's `try`s, which a routine
  that is not `public` may do [0960].
- `main` cannot fail, so it handles each failure with `else` [1030].
  `else (problem)` names the atom, and `failure.words(problem)` turns it
  into words for a person, such as `not found`.
- The output goes through a buffered writer over a buffer `main`
  declares. The deferred `io.flush` writes what waits on every way out,
  and the deferred `io.close` closes the file however `numbered` ends.

Compiled and run over a four-line file:

```sh
refine compile main.ldn -o number && ./number input.txt
```

```text
1: first line
2: second line
3: 
4: last, without a newline
```

Named a file that is not there, it says why on standard error and exits
with 1:

```sh
./number missing.conf
```

```text
missing.conf: not found
```

Both runs are the compiler's own tests:
[the program](../compiler/tests/fixtures/runtime/library-common-tasks/main.ldn)
and [its failing run](../compiler/tests/fixtures/runtime/library-common-tasks-missing/fixture.meta).

Which module does what:

| Task | Calls | Module |
|---|---|---|
| Get the handle every hosted call takes | `host := blocking.new()` | [hosted/blocking](../hosted/blocking) |
| Print a formatted line | `io.buffered_over(host, io.out(host), storage)`, then `io.format(out, "{} lines\n", [any(addr count)])` and `io.flush(out)` | [core/io](../core/io) |
| Get a command-line argument | `io.argument_at(host, 0)`, and `io.argument_count(host)` | [core/io](../core/io) |
| Read a file line by line | `io.open_read(host, path)`, `io.lines_over(host, file, buffer)`, then `io.read_line(lines)` until `item.finished`, and `io.close(host, file)` | [core/io](../core/io) |
| Write straight to standard error | `io.write(host, io.err(host), bytes)` | [core/io](../core/io) |
| Turn a failure into words for a person | `failure.words(problem)` | [core/failure](../core/failure) |
| Right-align a number in a column | `text.over(buffer)` makes a builder, `text.append_u64(line, value)` writes the number, `text.align_right(line, start, width, u8(' '))` pads it from `start`, and `io.put(out, text.used(line))` prints it | [core/text](../core/text) |
| Print a float with two decimals | scale it to whole hundredths and print the integer parts, as [core/text](../core/text)'s program shows; floats are not formattable | [core/text](../core/text) |

## Reading a signature

Each module's page shows every call's full signature, such as
`io.argument_at`'s
`(provider: type is process, host: provider, index: usize) -> (value: text.host_string from host) ! no_argument`.
A call writes far less: `io.argument_at(host, 0)`.

| In a signature | What it means |
|---|---|
| `provider: type is process`, first | A type parameter. The compiler deduces it from the arguments, so a call usually leaves it out [1300]. A call may name it instead, and then names every type parameter, as `vec.new(item: i32)` must, since no argument has that type. |
| `provider: type` | A type parameter with no requirement: any type will do. |
| `is process` | The type must conform to the concept `process`: a named set of operations [1230] [1240]. |
| `host: provider` | The provider: the handle a call works through, here the one `blocking.new()` made. An allocator is passed the same way, usually as `memory: provider` beside its own `provider: type is mem.allocator`. |
| evidence | The table that tells generic code how a type does a concept's operations [1240] [1310]. A conformance such as `u32 is formattable (...)` supplies it. |
| `world` | `core/io`'s concept for an ordinary program's provider: a `reader`, `writer`, `files` and `process` in one. `blocking.new()`'s `host` is one. In `core/io`, `memory` is the memory world, a provider over the caller's storage. |
| `buffered_writer(provider)` | A generic type applied to a type: a buffered writer over whichever provider the call deduces [1250]. |
| `public builder: type = builder_value` | A public name for a type whose fields are the module's own. You hold one and pass it to the module's calls; reading a field is refused. |
| `[]mut u8` | A slice the call may write through [0570]. A plain `[]u8` it only reads. |
| `[]any text.formattable` | A slice of values of any type that conforms to `formattable` [1370]. A call writes it as an array literal, `[any(addr count), any(addr name)]`. |
| `-> none` | The call returns nothing. |
| `-> (lines: line_reader(provider) from buffer, host)` | A named result. `from buffer, host` says it borrows from both and must not outlive either [0790]. |
| `-> (name: []u8, value: []u8)` | Several named results, read as fields of the call's result or taken apart by name [0990]. |
| `! no_argument` | What the call can fail with [0940]: pass it on with `try`, or handle it with `else`. |
| `! ...` | A routine that is not `public` may let the compiler work its set out from its body [0960]. The library's public calls always write theirs. |
| `inout` | The call may change the argument in place [0900]. |
| `sink` | The call consumes the argument [0910]. |

## About this reference

This reference is generated from the public declarations and their `---`
doc comments in `core`, `hosted` and `platform`. Each module's page has
the exact signatures, source links, module browsing and local search, and
the same comments appear in editor hover. The
[library guide](../core/README.md) explains the shared conventions and
evidence; the [tour](../tour.md) teaches the language.

Each module below opens with what it is for, then its main calls, then how
it behaves. Its page lists the items, and ends with a complete program
that uses the module, which the compiler's own tests run; where the
program prints, the page gives the command and its output too.

## What the library does not cover yet

The library covers:

- memory, containers and text;
- files, directories, standard input and output, process arguments and
  the environment;
- running programs, clocks, sleeping, the system's entropy and a
  deterministic generator;
- blocking TCP and UDP sockets over IPv4 and IPv6;
- the rest of the file system: opening with options, renaming, a file's
  status, read-only files, synchronizing, truncation, reading and writing
  at an offset, temporary files, the working directory's path and
  terminals.

`platform/posix` gives POSIX's own facilities in Landin types, on Linux,
Darwin and FreeBSD alike: files, directories, memory mappings, `poll`,
pipes, children, waiting, clocks, random bytes, sockets (Unix-domain ones
among them), links, permission bits, owners, file times, locks, terminals
and their raw mode, pseudo-terminals and the user and group databases.

It also loads shared objects with the system's own loader wherever a C
runtime started the program: on Darwin and FreeBSD, and on Linux under
`--link=libc`.

A program that needs something neither covers yet reaches the operating
system itself, and the route differs between Linux and the C library's
systems:

| Need | Planned | Route until then |
|---|---|---|
| Calendars, time zones and formatting a date | the locale record in the register | The wall clock's seconds since 1970 are `time.wall_now`'s; turning them into a date is the program's. |
| Resolving a host name to an address | the resolver record in the register | Under the C library, on Darwin, FreeBSD and Linux under `--link=libc`, `getaddrinfo` declared `extern(c)`; a static Linux program has none. `net.parse_address` reads an address that is already written as one. |
| Threads | the threads item | Nothing safe yet: the hosted providers keep process-wide state, and there is no thread-local storage. |
| Changing the working directory | not offered: it is the whole process's, and beside threads it would move every relative path at once | A path built from `io.current_directory`, or a call relative to a directory open as `at` in `platform/posix`; `chdir` by its number through `linux.system_call` on Linux, or declared `extern(c)` on Darwin and FreeBSD, where a program must. |
| Extended attributes, access control lists, file flags | not yet planned | On Linux, the call's number from `platform/linux/numbers` through `linux.system_call`; on Darwin and FreeBSD, the C function declared `extern(c)`. |
| Accounts kept outside /etc/passwd and /etc/group on Linux, a directory service's or NSS's | `--link=libc` | A static Linux program reads the two files itself; linked with `--link=libc`, `platform/posix` asks the C library, which asks NSS. |

Every Linux system call is reachable this way:

- `platform/linux/numbers` names each call's number, generated from a
  pinned kernel release;
- `linux.system_call` makes the call with six integer arguments and
  returns the kernel's result, minus the errno on a failure.

Nothing checks those arguments: a pointer goes as `i64(usize(p))`, and a
flag or a record is the program's to get right for each architecture.
Prefer a typed wrapper where `platform/linux` has one, and
`platform/posix` where it gives the call.

## core/mem

Memory providers and typed storage: the foundation for allocation, initialized prefixes and caller-owned backing.

| Call | What it does |
|---|---|
| `mem.allocate`, `mem.free` | Take a block from a provider, and give it back through the same provider with the same extent. |
| `mem.resize` | Give a block a new extent, larger or smaller, in place or by moving it. |
| `mem.storage_over` | Typed storage over the caller's bytes. |
| `mem.copy`, `mem.fill`, `mem.find` | Copy, set and search byte blocks. |

Use `allocator` evidence to supply storage explicitly. A provider is a
handle passed by value, `memory` in every signature, so several containers
share one without locking it. The arena is `core/arena`'s, and
deterministic failure injection over any provider is `core/fault`.

`resize` keeps the bytes the two extents share, and a refusal leaves the
block as it was. A provider that cannot resize in place answers with
`relocate`, which allocates, copies and frees. `aligned_offset` is the
arithmetic a bump provider of your own needs.

`storage_over` does not establish ownership or prove alias lifetimes.

Byte blocks are slices with their lengths checked:

- `copy` puts every byte of a source at the start of a destination with
  `memmove`'s rule, so the two may overlap in either direction. It reports
  `out_of_bounds` before writing anything when the destination is shorter.
- `fill` sets every byte.
- `find` gives the index of a byte's first occurrence, or the slice's
  length when there is none, so `source[0..<find(source, v)]` is always
  the part before it.
- Comparing two byte strings is `cmp.compare`'s.

On hosted targets `copy`, `fill` and `find` move a `usize` word at a time:

| Where | How the words move |
|---|---|
| x86-64 and arm64 | Copying up and searching load and store words at any address, from the first byte, and move bytes only in the tail. |
| Other hosted targets, and copying down or filling anywhere | Only at a multiple of the word, between a head and a tail moved a byte at a time. |
| Firmware | Plain byte loops, whose code is smaller. |

[Executable example](../compiler/tests/fixtures/runtime/library-shared-mem/main.ldn)

## core/vec

A growable contiguous list with explicit allocation and rollback on failed growth.

| Call | What it does |
|---|---|
| `vec.new` | Start an empty list; nothing is allocated. |
| `vec.reserve`, `vec.push` | Grow it, through the provider's handle. |
| `vec.get` | Copy an item out. |
| `vec.at` | Lend a writable pointer to an item. |
| `vec.used` | Lend the initialized slice. |

End views before relocation or release. Clearing or releasing a container
never frees resources referenced by its items.

A list of bytes is the growable byte container:

- `append_bytes` copies a slice after its bytes;
- `spare_bytes` lends the spare capacity a read fills, and `extend_bytes`
  counts what was written there.

They move a word at a time where `mem.copy` moves words, as a list's items
are when it grows into a new block.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-vec/main.ldn)

## core/spill

A list that keeps an inline prefix and spills into allocated storage when it fills.

Queries use a pointer to avoid copying the inline array.

Popping from spilled storage retains that allocation; `release` returns
to an empty inline representation.

Items need no zero image: pointers and atom-bearing records are stored
like any other.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-spill/main.ldn)

## core/cmp

Equality, hashing and ordering evidence, apart from the containers and algorithms that consume it.

The three concepts ship for these types:

| Type | `equatable` | `hashable` | `ordered` |
|---|---|---|---|
| the ten integer scalars | yes | yes | yes |
| `bool` | yes | yes | no |
| `[]u8` | yes | yes | yes, by `compare` |
| `utf8`, from `core/text` | yes | yes | yes |
| floating-point types | no | no | no |

`compare` orders two byte strings as `less`, `equal` or `greater`. The
first differing byte decides, and a proper prefix comes first: C's
`memcmp` with the lengths taken into account, and the order `ls` gives
names in the C locale. `[]u8`'s `ordered` evidence is its `less`.

There is one register and no override: another reading of a shipped type
goes on a `distinct` wrapper with its own evidence. A `hashable` key
declares its `equatable` conformance as well.

The compiler does not prove the laws. Equality must be an equivalence,
equal keys must hash alike, and `less` must be a strict weak ordering.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-cmp/main.ldn)

## core/map

An insertion-ordered hash map with explicit entry walks.

| Call | What it does |
|---|---|
| `map.new` | Start an empty map. |
| `map.insert` | Add a key and its item, through the provider's handle. |
| `map.get`, `map.at`, `map.contains` | Copy an item, lend a pointer to it, or ask whether a key is there. |
| `map.remove` | Remove a key. |
| `map.entries`, `map.next_entry` | Walk the entries in insertion order. |

Keys are constrained on `core/cmp`'s `hashable`, which ships for ten
integer scalars, `bool` and `[]u8`; `core/text` adds UTF-8 evidence.
Alternative policies use a `distinct` wrapper. Floating-point keys need an
explicit equality and hashing policy.

Hashes are spread before they choose a slot, so keys sharing a stride do
not share a probe chain.

`capacity` is how many entries fit before the next new key rebuilds the
table, and `slots` is its size. Removed entries count against the
capacity until a rebuild; `removed` counts the dead entries that hold
their slots until then. The representation is the module's own.

Keep keys and their backing stable while stored, and restart cursors after
any mutation.

Complete map workloads can exceed the Cortex-M0 test profile of 32 KiB
flash. The bounded example below checks the empty-map surface; it does
not demonstrate that a populated map fits that profile.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-map/main.ldn)

## core/sort

Allocation-free in-place heapsort and selection sort using ordering evidence, and heapsort by a comparison given a context.

| Call | What it does |
|---|---|
| `sort.sort` | Heapsort by the items' `ordered` evidence. |
| `sort.sort_selection` | Selection sort by the same evidence. |
| `sort.sort_by` | Heapsort by a comparison you pass, with a context. |

None of the three allocates or promises stability.

Items are constrained on `core/cmp`'s `ordered`, which ships for the ten
integer scalars; `core/text` supplies UTF-8 byte ordering. Custom
`ordered` evidence must obey a strict weak ordering.

`sort_by` takes the order as a comparison, `less(by, left, right)`, and
passes it the context `by` the caller gives, unchanged, on every call.
So records that refer into shared storage, such as offsets into one pool
of names, are ordered by what they refer to, and the context may be a
pointer the comparison counts through.
The comparison must be a strict weak ordering while it runs.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-sort/main.ldn)

## core/text

Byte cursors, validated UTF-8 views, byte search, a text builder, formatting and parsing numbers.

| Call | What it does |
|---|---|
| `text.from_bytes`, `text.valid` | Check bytes are UTF-8, as a view or as a yes or no. |
| `text.over`, `text.growing` | Make a builder over your buffer, or one that grows from an allocator. |
| `text.append_text`, `text.append_u32` and the rest | Append a piece to a builder. |
| `text.format` | Append a template with each `{}` filled in. |
| `text.parse_u32` and the rest | Read a number from bytes. |
| `text.host_over`, `text.from_host` | Make a host string, and check one is UTF-8. |

### Views and cursors

Cursors advance by bytes. Views borrow their input.

`from_bytes` validates bytes as UTF-8 and reports `invalid_text` when they
are not, and `valid` answers the same question without a view. The
`utf8(bytes)` conversion validates too, but traps on malformed input.

A `text.position` indexes `utf8` by byte offset, while a `usize` index
into `utf8` counts scalars, so do not index with `offset(position)`. This
module does not turn byte offsets into validated character boundaries.

UTF-8 equality, hashing and ordering use encoded bytes, with no
normalization or locale collation.

### Host strings

A host string, `host_string`, is a path, a process argument or a
directory entry's name in the representation its system gives and takes:
bytes on Linux, Darwin and FreeBSD, which need not be UTF-8. It is never
converted on the way through, so an argument passed on as a path reaches
the system as it was given.

| Call | What it does |
|---|---|
| `from_host` | The checked conversion to `utf8`, reporting `invalid_text` as `from_bytes` does. |
| `host_bytes` | Lend its bytes. |
| `host_equal` | Compare it with a literal. |
| `host_over` | Make one over the caller's bytes: `text.host_over("input.txt")` for a literal path. |

A host string lends what it was made from. The NUL a C call needs is
never the caller's: `platform/posix` adds it beneath the provider and
refuses a path that holds one.

### The builder

A `builder` writes text into bytes a piece at a time. It is a value the
caller passes `inout`.

- `over` makes one over the caller's buffer, which never grows.
- `growing` makes one that takes its storage from an erased allocator,
  `text.growing(any(addr heap))`, doubling what it holds and giving it
  back with `release`.
- `used` lends what it holds until it next changes, and `length` is the
  offset the next piece begins at.
- `clear` empties it and `truncate` cuts it back.

Each append writes its whole piece, or reports `no_space` and leaves the
builder as it was:

| Append | Writes |
|---|---|
| `append` | bytes as they are |
| `append_byte` | one byte |
| `append_text` | a `utf8` |
| `append_host` | a host string's bytes |
| `append_u32`, `append_u64`, `append_usize` | decimal |
| `append_i32`, `append_i64`, `append_isize` | decimal, with a `-` before a negative value |
| `append_hex_u32`, `append_hex_u64`, `append_hex_usize` | lower-case hexadecimal with no `0x` |

Each append takes exactly its own type, and nothing widens at the call:
passing a `u8` to `append_u32` is refused. Convert a narrower integer
explicitly, `text.append_u32(line, u32(byte))`.

Width and padding apply to whatever was written since an earlier
`length`. `align_right` puts a fill byte before the piece until it is as
wide as the field, and `align_left` after it. The fill goes before a sign
too, so a zero fill suits an unsigned value.

To right-align a number in a column, note where it starts, append it and
align what was appended. The fill is a byte, so a space is `u8(' ')`:

```landin
--- Append `value` to `line` in decimal, right-aligned in a field `width`
--- bytes wide.
append_right: (inout line: text.builder, value: u64, width: usize)
              -> none ! text.no_space =
    start: usize = text.length(line)
    try text.append_u64(line, value)
    try text.align_right(line, start, width, u8(' '))
end append_right
```

A builder over `mut buffer: [64]u8 = zeroed` is `text.over(buffer)`, and
`io.put(out, text.used(line))` prints what it holds.

### Formatting

`format` appends a template with each `{}` replaced by the next of an
array of `any formattable` values, and `{{` and `}}` written as braces. A
placeholder takes nothing else; width, padding and hexadecimal are the
typed calls.

The values are an array literal written at the call, which lends it as a
slice: `text.format(line, "{} {}\n", [any(addr count), any(addr name)])`.

Nothing runs at compile time, so the template is checked against the
values when it runs. A different number of placeholders, or a brace that
is neither part of `{}` nor doubled, is `invalid_format`, and nothing is
written. A builder that fills partway is put back before `no_space` is
reported.

`formattable` has one entry, `append`, which writes a value into a
builder through a pointer to it. The library supplies it for the ten
integer types in decimal, `bool` as `true` or `false`, `utf8`, `[]u8` and
host strings, and a program declares it for a type of its own. Floats,
`f32` and `f64`, are not formattable yet.

To print a float, scale it to an integer and print the parts. Converting
a float to an integer truncates toward zero and traps when the value does
not fit, so this adds a half to round, and takes the sign off first so
that a negative value rounds the same way:

```landin
--- Append `value` with two decimals, rounded half away from zero.  Floats
--- are not formattable, so this scales the value to whole hundredths and
--- writes the integer part, a point and the two digits after it.
append_hundredths: (inout line: text.builder, value: f64)
                   -> none ! text.no_space =
    mut magnitude: f64 = value
    if value < 0.0 then
        magnitude = -value
    end if
    --  The conversion truncates toward zero, so adding a half rounds.
    hundredths: u64 = u64(magnitude * 100.0 + 0.5)
    if value < 0.0 and hundredths > 0 then
        try text.append_byte(line, u8('-'))
    end if
    try text.append_u64(line, hundredths / 100)
    try text.append_byte(line, u8('.'))
    start: usize = text.length(line)
    try text.append_u64(line, hundredths % 100)
    try text.align_right(line, start, 2, u8('0'))
end append_hundredths
```

The `0` fill writes five hundredths as `05`, so 2.05 never prints as
`2.5`, and a value that rounds to zero prints without a sign, `0.00`. A
value too large for a `u64` once scaled, a NaN or an infinity traps at
the conversion.

No locale is consulted anywhere: the same values give the same bytes
everywhere, on Cortex-M0 as on a hosted system.

### Parsing numbers

Parsing is the mirror of the appends, over a byte slice that need not be
UTF-8:

| Parse | Reads |
|---|---|
| `parse_u8` to `parse_u64`, `parse_usize` | nonempty ASCII digits |
| `parse_i8` to `parse_i64`, `parse_isize` | an optional `-` before them, never a `+`, since no append writes one |
| `parse_hex_u32`, `parse_hex_u64`, `parse_hex_usize` | hexadecimal digits of either case, with no `0x` |
| `to_u32` | `parse_u32` over a `utf8` view |

Anything else, a space included, is `invalid_number`. A value outside the
type, above its maximum or below a signed minimum, is `number_overflow`.
The scan goes from the left and reports whichever it meets first.

`usize` and `isize` are the target's, 32 bits on Cortex-M.

The builder's appends are the library's one decimal writer, and these
parses its one parser: `core/net` reads its addresses' numbers through
them.

[Executable example](../compiler/tests/fixtures/runtime/library-text-columns/main.ldn)

The program prints a price list: each item's name aligned left, its
count right-aligned under its heading, and its price, an `f64`, with two
decimals.

## core/io

Reader, writer, file and process capabilities, their world composition, directories, running programs, entropy, the rest of the file system and terminals beside them, the memory world, a buffered writer and a line reader. Time is `core/time`, the network `core/net` and the fakes of a system `core/io/fake`.

The capabilities are concepts, and a program names only the ones it uses:

| Concept | What it gives | Part of `world` |
|---|---|---|
| `reader`, `writer` | `read`, `write`, `write_some` | yes |
| `files` | `open_read`, `open_write`, `same_file`, `close` | yes |
| `process` | the standard streams `input`, `out` and `err`, and the arguments | yes |
| `directories` | listing, making and removing directories | no |
| `environment` | the process's variables | no |
| `programs` | running other programs | no |
| `file_system` | opening with options, renaming, status, temporary files and the rest | no |
| `terminals` | asking whether a stream is a terminal, and its size | no |
| `entropy` | `fill_random` | no |

Typical use, as in the tour's first program. Every call takes `host`,
the handle `blocking.new()` makes in [hosted/blocking](../hosted/blocking),
which a hosted program imports beside `core/io`. A call written with
`try` is in a routine that can fail; `main` cannot, and handles each
failure with `else` instead, as the program at the end of the page does:

| Task | Calls |
|---|---|
| Print a formatted line | `mut out := io.buffered_over(host, io.out(host), storage)` makes a buffered writer over your buffer, an array such as `mut storage: [256]u8 = zeroed`, `defer io.flush(out) else none` writes what waits on the way out, and `try io.format(out, "{} of {}\n", [any(addr done), any(addr total)])` fills each `{}` with a value. |
| Print bytes as they are | `try io.put(out, "done\n")`, through the same writer. |
| Write straight to a stream | `io.write(host, io.err(host), bytes)` writes all the bytes, or fails with `io_failed`. |
| Get an argument | `path := try io.argument_at(host, 0)` lends the first argument after the program's name as a host string, or fails with `no_argument`; `io.argument_count(host)` counts them. |
| Read a file line by line | `file := try io.open_read(host, path)` opens it, `mut lines := io.lines_over(host, file, buffer)` makes a line reader over your buffer, and `item := try io.read_line(lines)` gives each line in `item.bytes` until `item.finished`; `try io.close(host, file)` closes it. |

### Providers

Use the smallest concept a consumer needs. A provider is a handle passed
by value, `host` in every signature. An erased capability is built from
the address of a handle binding, `any(addr host)`. Using a handle locks
nothing, so a program and its logger write through one, and two lent
arguments and a query are live at once. An erased capability is itself a
provider of its concept and of every concept that one builds on (D492), so
an `any io.world` or an `any net.network` goes to `io.buffered_over`,
`io.lines_over` or any routine generic over a writer or a reader as it is,
with no adapter. It does not convert to an `any` of another concept: where
an `any io.writer` is wanted, an erased world lends a writer to erase with
`writer_of`.

Providers retain authority over files and arguments.

`process` lends the three standard streams, `input`, `out` and `err`, and
the argument table: `io.out(host)`. Standard input is read through
`reader` like any file, and a read of zero bytes into a nonempty buffer is
its end.

A path and an argument are host strings, `text.host_string`, so an
argument passed on as a path is never converted.

### The memory world

`memory_over` makes the memory world, firmware's own:

- it takes the arguments as their bytes, lent back as host strings, so a
  table can be static data;
- it fills the caller's `memory_space`, whose limits and counters stay
  readable and settable;
- it keeps all storage with the caller, the bytes its standard input
  reads among them.

Its directories are its slots' names before a `/`, so it lists them and
reports their sizes but changes nothing.

How it behaves, so that a test gets the same answer every run:

- Files must already be in its table. Opening one for writing truncates
  it, and reads stop at a file's initialized length.
- `write` and `write_some` keep the blocking provider's contract below, in
  [hosted/blocking](../hosted/blocking).
- The read and write limits cut each transfer into chunks, and
  `fail_read_at`, `fail_write_at` and `fail_close_at` fail the call with
  that one-based count: 1 is the first read, and 0 never fails. So short
  reads, partial writes and failed cleanup are reproducible.
- A zero read limit with data still unread is an error, not the end of
  the input.
- `written` and `written_errors` lend what was written to standard output
  and standard error.
- Its arguments, like the system provider's, never include the program's
  own name, `argv[0]`.

### Directories

`directories` is a fifth concept beside the four, and not part of
`world`: a program that lists, makes or removes directories names it as
well.

`open_directory` takes a buffer from the caller and returns an open
`directory`, a value the caller passes `inout` to `read_entry`, which
refills the buffer as entries are read.

- Each entry's name is a host string that need not be UTF-8, lent from
  the directory until the next read. A name kept past it is refused
  [0800], so a program copies the names it keeps.
- An empty name is the end.
- `.` and `..` are never listed, and the order is the system's.
- `entry_size` asks the open directory for an entry's size by name, as a
  `u64`, not following a symbolic link.

`make_directory`, `remove_file` and `remove_directory` change the tree. A
missing path, and a path through or to something that is not a
directory, are `not_found`; a name already taken is `already_exists`.

Close a directory through the provider that opened it. One dropped
unclosed keeps what its provider holds for it until the process ends.

### The environment

The environment is a concept of its own, `environment`, outside `world`,
so a provider without one, and a firmware image that never asks for one,
carry none of it.

- `variable_count` counts its variables.
- `variable_at` lends the one at an index, an `io.variable` of a name and
  a value.
- `variable_named` lends the value of the first variable with a name,
  compared as bytes, or reports `no_variable`.

Names and values are host strings that need not be UTF-8, lent from the
provider for as long as the process lives.

The environment is read-only. A process does not change its own, which is
not safe beside threads, and gives a child the environment it builds
instead.

`variables_over` makes a `memory_variables`, an environment provider over
a table of `NAME=value` byte strings, which firmware can declare as data.

### Running programs

`programs` is a seventh concept, outside `world`, for running other
programs.

`spawn` starts the program at a path, a host string. The path is never
looked up on a search path or handed to a shell. The program gets the
arguments it sees after its own name and exactly the variables the caller
builds. Each of its three standard streams is connected as
`child_streams` says:

| Choice | The child's stream is |
|---|---|
| `inherited` | the parent's own |
| `discarded` | connected to nothing |
| `piped` | a pipe whose other end the parent holds |

`inheriting`, `capturing` and `discarding` are the common three
combinations.

A missing program is `not_found`, one the caller may not run `no_access`,
and on any failure no child exists.

The `child` it returns is a value the caller keeps, whose fields are the
provider's:

- `write_child` writes to its piped input, and `close_input` closes it,
  so that the child reads to its end.
- `read_child` reads its piped output and errors together. It waits until
  either has something and says which it read, so a child that writes
  more than a pipe holds to both never waits on a full one.
- `wait` closes every pipe the child still has, waits for it, and reports
  how it ended. The `ending`'s variant part is `exited` with a code, or
  `signalled`, ended from outside, whose detail is the provider's. It
  consumes the child.

A child never waited for keeps what its provider holds for it until the
process ends. Close a child's pipes only through `close_input` and
`wait`, never through `files`.

`write_child`, `read_child` and `wait` wait, and `spawn` and
`close_input` do not, so `programs` is supplied by a provider that waits,
as reading and writing are: `hosted/blocking`'s, not `hosted/system`'s.
Its pipes are its own files, which its `reader` and `writer` also take, a
line reader over a child's output among them. The memory world's are not.

`scripted_over` makes `scripted_programs`, a programs provider beside a
memory world, over the caller's `scripted_program` records. It is a
provider of its own, so a world that runs no program carries none of its
code. A scripted program at a given path:

- writes the given output and errors when it starts, as each stream
  says, an inherited one into the world's own standard output or error;
- keeps what its parent writes to its piped input with `write_child`;
- records how many arguments and variables it was given and how often it
  started;
- ends as it is told.

### The rest of the file system

The rest of the file system is `file_system`, a concept of its own beside
`files` and `directories` and outside `world`, so an image that never
renames or truncates carries none of it.

`open_file` opens a path as an `open_options` record says:

| Option | Meaning |
|---|---|
| `read`, `write` | open to read, to write, or both |
| `append` | every write goes at the end |
| `create` | create the file when it is missing |
| `exclusive` | with `create`, refuse a name that is taken, with `already_exists` |
| `truncate` | cut the file to nothing |

`updating`, `appending` and `creating` are the common three.
`valid_options` says whether an open can have the options at all, and
`io_failed` answers one that cannot.

| Call | What it does |
|---|---|
| `rename` | Give a file a new name in one step, replacing a file already called that. |
| `status_of`, `status_of_file` | A path's or an open file's `status`. |
| `set_read_only` | Make a file read-only, or writable by its owner again. |
| `synchronize` | Have what the provider holds of a file written where it lasts, its data alone when asked. |
| `truncate` | Give a file a size, cutting it or extending it with zeros. |
| `read_at`, `write_at` | Read and write at an offset. |
| `make_temporary` | Make and open a new file under a fresh name. |
| `current_directory` | Put the working directory's path in the caller's buffer. |

`rename` is how a whole file is replaced: write a `make_temporary` file
beside it, `synchronize` it, close it and rename it onto the old one. A
missing name is `not_found`. A rename across file systems, or of a
directory onto a file or a file onto a directory, is `io_failed`.

A `status` holds the size, its `entry_kind`, the last modification as a
`wall_time` and whether it is `read_only`. `status_of` follows a final
symbolic link or not, as asked.

A read-only file refuses an open for writing with `no_access`, except to
a process the system lets past every permission, as POSIX's root.

`read_at` and `write_at` do not move the position `read` and `write` use.
A read at or past the end reads nothing. A write past it leaves zeros
between, a hole a file system may keep without storing it. Never write at
an offset to a file opened to append.

`make_temporary` creates the file in a directory under a name no other
file has: `.tmp-` and sixteen hexadecimal digits, drawn from an `entropy`
the caller passes. In an ordinary program that is the hosted provider
itself: `io.make_temporary(host, host, directory, buffer)`.

- The file is created exclusively, readable and writable by its owner
  alone.
- A name already taken is tried again with fresh bytes, up to
  `temporary_tries` times.
- Nothing removes it: rename it into place or remove it.
- `temporary_path` is the name it tries, for a provider in another
  module.

Nothing here changes the working directory, since it is the whole
process's.

### Terminals

Terminals are `terminals`, one more concept outside `world`.
`is_terminal` says whether a stream is one, and `window_size` gives its
`window`, rows and columns, or `not_a_terminal`.

### The buffered writer

A `buffered_writer` gathers writes to one file in a buffer the caller
supplies, and hands them to a writer when the buffer fills or the program
flushes it.

| Call | What it does |
|---|---|
| `buffered_over` | Make one from a writer's handle, the file and the buffer. |
| `put` | Write bytes through it, flushing first when they do not fit. Bytes as large as the buffer go straight to the writer. |
| `format` | Format a template straight into its buffer, flushing first when the text does not fit after what waits. |
| `flush` | Write what waits. |
| `pending` | Say how many bytes wait. |

A failed flush reports the writer's `io_failed` and keeps every byte the
writer did not take, so the next flush writes each byte once. `format`
refuses a text larger than the whole buffer with `text.no_space`. Its
values are `text.formattable`'s types, as `text.format`'s are: integers,
`bool`, `utf8`, `[]u8` and host strings. Floats are not formattable yet:
to print one, scale it to an integer and print the parts, as
`append_hundredths` in [core/text](../core/text) does for two decimals.

There are no destructors: bytes still waiting when the program ends are
never written. Flush before every way out, `defer io.flush(out) else ...`
being the idiom, and flush where the bytes must be out before something
else happens.

### The line reader

A `line_reader` reads a file through a buffer the caller supplies and
lends it back a line at a time, as a directory lends its names.
`lines_over` makes one from a reader's handle, the file and the buffer,
and `read_line` gives the next `line`, its bytes lent from the reader
until the next read.

- A line ends at `\n`, and a `\r` just before it is part of the ending,
  so text written with `\r\n` reads as text written with `\n`.
- A lone `\r` is an ordinary byte, and the last line need not end.
- The end of input is a line that has `finished`, every time it is asked
  again; an empty line has not.
- A line that does not fit the buffer with its ending is
  `line_too_long`, and the rest of it is skipped, so the next read gives
  the line after it.

[Executable example](../compiler/tests/fixtures/runtime/library-common-tasks/main.ldn)

The program numbers the lines of the file named on the command line,
reading it through a line reader and printing through a buffered writer.
When the file cannot be read it says why on standard error, in
`failure.words`' phrase, and exits with 1.

## core/io/fake

Fakes of a system's providers for tests that must give the same answer every run and on every target: a file system, a network, a clock, entropy, terminals and signals, each over the caller's records.

Each fake is named one way:

| Part | Name | Example |
|---|---|---|
| its provider type, for what it fakes | the name | `fake.volume` |
| its caller-owned state, declared `zeroed` | the name with `_space` | `fake.volume_space` |
| its constructor, which fills the state and returns the handle | the name with `_over` | `fake.volume_over` |

The fakes are `fake.volume`, `fake.network`, `fake.clock`, `fake.entropy`,
`fake.terminals` and `fake.signals`. The clock and entropy are described
with `core/time`, the network with `core/net` and the signals with
`core/io/signal`. The memory world, which is firmware's own world rather
than a fake of a system's, stays in `core/io` as `io.memory`.

### The volume

`volume_over` makes a `fake.volume`: the fake of `file_system`, and of
`reader`, `writer`, `files` and `directories` over the same files. It is a
file system in memory over the caller's `volume_node` records, each a
path, a kind and room for a file's bytes or a link's target, and a
`volume_space` the caller declares `zeroed`.

- The space time-stamps each change.
- Its `fail_at` fails a chosen call, counting every call of the volume,
  each `read_entry`, `entry_size` and `same_file` among them.
- A node with no path is free for a new file.
- A file grows only into its node's room, and a write that finds none is
  `io_failed`, as a full device is.
- A symbolic link is a node the caller makes, followed where a path is
  followed.
- A node a file is open on cannot be removed or renamed over, where POSIX
  would keep the open file without its name.

The whole volume, which links every entry of its conformances, does not
fit a Cortex-M0 image; its temporary names and the memory terminals run
there.

### Terminals

`terminals_over` makes `fake.terminals` over the caller's `screen`
records, each a file of a size, and every other file is no terminal.

[Executable example](../compiler/tests/fixtures/runtime/volume-memory/main.ldn)

## core/io/signal

Signals as events: the concept a provider that takes turns supplies when it delivers the system's signals to a fibre that waits for them.

| Call | What it does |
|---|---|
| `signal.watch(host, which)` | Take a signal from the system's default disposition and deliver it as an event from then on. |
| `signal.next_signal(host)` | Wait, taking turns, for the next arrival of a watched signal: a `signal.event`. |
| `signal.stop_watching(host)` | Give every watched signal back to its default disposition, and wake every waiting fibre, whose wait fails `io_failed`. |

A signal is named portably by a `signal.kind`, and an arrival says which
one came and the number the system gave it:

| Kind | Signal |
|---|---|
| `signal.interrupt` | SIGINT, the terminal's Ctrl-C |
| `signal.terminate` | SIGTERM, a request to end |
| `signal.hangup` | SIGHUP, the terminal gone, or a daemon's cue to reload |
| `signal.child` | SIGCHLD, a child ended, stopped or went on |
| `signal.user1`, `signal.user2` | SIGUSR1 and SIGUSR2 |

- A signal never runs a handler of Landin code. The provider reads it as
  it reads any other event, through signalfd on Linux and kqueue's
  signal filter on Darwin and FreeBSD, and wakes the fibre that waits.
- `signals` refines `fibre.turns`: only a provider whose fibres take
  turns supplies it, so a fibre waiting for a signal lets the others run.
  Over the blocking host a program cannot ask for it, and a signal there
  keeps the system's default disposition: SIGTERM ends the process.
- Each arrival is read once, by one waiter. Two arrivals of one signal
  before it is read may be one event, as the systems keep them.
- A fibre waiting for a signal is stopped as any waiting fibre is, by
  failing its wait: `stop_watching` does that.

### The fake

`signals_over` makes a `fake.signals` over the caller's `signals_space`
and a `fibre.turns` it waits on, whose `start`, `finished`, `wait` and
`yield` it passes on, so it is a provider of turns as the concept asks.
A test raises a signal into it with `fake.raise(host, which)`, and the
fibre waiting in `next_signal` receives it after its next turn.

- A raised signal nobody watches is counted in `ignored` and dropped,
  where a system would act on it.
- A signal raised again while it waits to be read is one event.
- The fake numbers each signal as Linux does on x86-64 and arm64.
- `raised`, `delivered` and `turns`, the turns its waits took, count the
  rest.

The fake runs on Cortex-M0, over a round of turns.

[Executable example](../compiler/tests/fixtures/runtime/signals-fake-firmware/main.ldn)

## core/time

Spans and instants of time counted in nanoseconds, the wall clock's time, and the monotonic and wall clock concepts.

| Call | What it does |
|---|---|
| `time.now(host)` | Read the monotonic clock: an `instant`. |
| `time.elapsed(earlier, later)` | The span between two readings taken in order. |
| `time.sleep(host, span)` | Sleep for at least a span. |
| `time.milliseconds(n)` | Make a span; `nanoseconds`, `microseconds` and `seconds` too. |
| `time.wall_now(host)` | Read the wall clock: a `wall_time`. |

### Clocks

Time is two concepts outside `world`, so an image that never asks the time
carries neither.

| Concept | Call | Reads |
|---|---|---|
| `clock` | `now`, `sleep` | a monotonic clock, which never goes back |
| `wall_clock` | `wall_now` | the system's UTC time, a `wall_time` of seconds since 1970 and the nanoseconds after them |

`sleep` returns once at least the span asked has passed on that clock,
never sooner. The system may set the wall clock, so it may go back; time
a task with `clock`.

### Spans and instants

A reading is an `instant` and a span a `duration`, each a distinct `u64`
of nanoseconds, which holds 584 years.

- `u64(at)` is the count.
- Two of a kind compare with `==`, `<>`, `<`, `<=`, `>` and `>=`, as
  their counts do.
- Neither has arithmetic of its own: `elapsed` is the span between two
  readings taken in order, trapping if the second is the earlier, and
  `later` gives a deadline.
- `nanoseconds`, `microseconds`, `milliseconds` and `seconds` make a span,
  trapping past 584 years, and `in_milliseconds` rounds one down.

There is no floating point, and the arithmetic is the same on every
target. Calendars, time zones and formatting a date are not here.

### Entropy

`entropy` is a third concept, `fill_random`, which fills all of a buffer
with unpredictable bytes or fails `io_failed`.

### Fakes

| Fake | Made by | Behaviour |
|---|---|---|
| `fake.clock` | `clock_over`, over the caller's `clock_space`, or `clock_beside` a fake network | Moves only when a test says: `advance` moves both its clocks, and a `sleep` advances them by exactly what it asks and returns at once. Made `clock_beside` a network that takes turns, a `sleep` takes turns instead and the clock moves only while every other fibre waits. The test may set either reading through the state, and the state counts readings, sleeps and the time slept. |
| `fake.entropy` | `entropy_over`, over the caller's bytes | Gives the bytes in order; a request for more than is left fails. So a program that seeds itself from entropy runs the same in every test. |

Both fakes run on Cortex-M0.

[Executable example](../compiler/tests/fixtures/runtime/clock-manual/main.ldn)

## core/net

The network concept, whose connections are readers and writers, and internet addresses with their text.

| Call | What it does |
|---|---|
| `net.connect` | Connect to an address. |
| `net.listen`, `net.accept` | Listen at an address and take the next connection. |
| `net.send`, `net.receive` | Send and receive on a connection. |
| `net.open_datagram`, `net.send_to`, `net.receive_from` | A UDP socket and its datagrams. |
| `net.parse_address`, `net.append_address` | Read and write `192.0.2.1:80` and `[2001:db8::1]:80`. |
| `net.close_socket` | Close a socket. |

### Sockets

The network is one more concept outside `world`, `network`, so an image
that never connects carries none of it.

It is a reader and a writer of its own sockets as well. A connection is
read and written through `read` and `write`, a line reader and a buffered
writer among them, whose failures are `io_failed`. `send` and `receive`
say more: `timed_out` when a limit has passed and `disconnected` when the
peer has gone. A `receive` or `read` of zero is the end of what the peer
sends.

| Call | Behaviour |
|---|---|
| `listen` | Takes an address and returns a listener. Port 0 asks for a free port, which `local_address` then gives. It may take an address its own closed connections still hold, never one another socket listens at, which is `address_in_use`. |
| `accept` | Takes the next connection. |
| `connect` | Makes one: `refused` where nothing listens and `unreachable` where no route leads. |
| `open_datagram` | Binds a UDP socket. |
| `send_to` | Sends a datagram whole. |
| `receive_from` | Gives the next datagram with its `sender`, cutting one longer than the buffer. |
| `shutdown` | Stops `receiving`, `sending` or `both_directions`. |
| `peer_address` | Names a connection's other end. |
| `set_timeouts` | Limits how long a receive, an accept and a send wait; zero for no limit. |
| `set_no_delay` | Turns Nagle's algorithm off. |
| `close_socket` | Closes a socket. |

An address the system does not have, or a family it lacks, is
`address_unavailable`.

Every call waits as a blocking socket does. One thread can connect to its
own listener and send before it accepts, since the system completes the
handshake, but a receive waits for its peer.

### Addresses

An `address` is a family, `ipv4` or `ipv6`, sixteen bytes and a port.

- `loopback`, `unspecified`, `ipv4_address`, `ipv6_address` and
  `with_port` make one.
- `same_address` and `is_unspecified` compare.
- `parse_ip` reads `192.0.2.1` or `2001:db8::1`, and `parse_address`
  reads `192.0.2.1:80` or `[2001:db8::1]:80`. Both refuse a leading zero,
  a zone and anything else with `invalid_address`.
- `append_ip` and `append_address` write them back as RFC 5952 does: lower
  case, the longest run of zero groups shortened, and an IPv4-mapped
  address in dotted decimal.
- An address is `text.formattable`.

Nothing here resolves a name.

### The fake network

`network_over` makes a `fake.network` over the caller's `network_socket`
records, each made by `socket_over` from a buffer that is its receive
buffer, and a `network_space` whose counters a test reads. It is a
machine of loopback addresses:

- a connection and a datagram arrive at once, whole and in order;
- a datagram no socket takes is lost and counted;
- a call that would wait answers `timed_out` at once, since in one thread
  with no scheduler nothing else runs that could end the wait.

`network_over_turns` makes the same network over a `fibre.turns` the
caller gives it, for a test whose client and server are fibres:

- a call that would wait takes a turn instead, so the other fibres run,
  and looks again;
- it answers `timed_out` only after a whole round in which nothing moved
  anywhere in the network, so nothing it waits for arrived, and never
  while a fibre sleeps on a clock made `clock_beside` it;
- a call whose socket another fibre closed, or shut for what it waits
  for, while it waited fails `io_failed` when it wakes.

`accept`, `send`, `receive`, `receive_from`, `read`, `write` and
`write_some` are its calls that may wait, and so switch; the others never
do. `moves` counts what changed something a call may wait for, `turns`
the turns its calls took and `sleepers` the fibres sleeping beside it.

`clock_beside` makes a `fake.clock` whose `sleep`, beside a network that
takes turns, takes the network's turns: the clock moves only after a whole
round in which nothing in the network moved, a millisecond at a time, so
sleepers wake in the order of their deadlines while the other fibres run
first (D493).

A test may take IPv6 away with `without_ipv6` and fail a call with
`fail_at`.

[Executable example](../compiler/tests/fixtures/runtime/network-fake-turns-exchange/main.ldn)

Addresses are read and written on Cortex-M0 as on a hosted system.

[Executable example](../compiler/tests/fixtures/runtime/network-addresses/main.ldn)

## core/diag

Bounded diagnostic storage and streaming diagnostics through a writer capability.

Severity is the atom set `warning | error`, so a `match` over it is
checked for both.

| Log | Made by | Behaviour |
|---|---|---|
| bounded | `diag.new` | Stores at most its fixed number of entries, and drops messages exceeding 256 bytes. It counts dropped entries and remembers error diagnostics even when they are dropped. |
| streaming | `diag.stream` | Holds a copy of an erased writer and a file. Writes each note as `W:` or `E:`, the decimal byte offset, `:` and the message, and propagates I/O failure. |

[Executable example](../compiler/tests/fixtures/runtime/library-shared-diag/main.ldn)

## core/failure

Error messages: words for a person for each library failure, a short English phrase for every failure atom the core library raises.

`failure.words(problem)` gives the phrase for any of the 32 atoms in
`failure.reason`, every atom a `core` module fails with. So a call's
`else (problem)` passes its failure straight on, whatever subset it
declares.

A phrase is lower case with no final stop, and reads after a subject and
a colon: `settings: not found`. It is static text, borrows nothing and
never changes with a locale.

A set that also holds an atom of the program's own does not widen to
`failure.reason`, and a `match` arm of `_` does not narrow it, so such a
program names each library atom it passes on. `platform/posix`'s errno
detail stays with its provider.

Nothing is linked into a program that never calls `words`. One that does
carries every phrase, about 6 KB of code and text on Cortex-M0.

[Executable example](../compiler/tests/fixtures/runtime/failure-words-report/main.ldn)

## core/tree

An append-only store of named leaves and branches addressed by node identifiers.

A branch names a contiguous range of previously published nodes.

Leaf totals are precomputed, so queries use constant stack and time.
Shared children count once for each incoming path.

Names borrow their UTF-8 backing; releasing the tree frees node storage,
not names.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-tree/main.ldn)

## core/arena

A monotonic allocator over caller-supplied bytes.

| Call | What it does |
|---|---|
| `arena.over` | Fill the caller's `arena.space`, declared `zeroed` beside the backing, and return the handle, an `arena.arena`, `from` it. |
| `arena.over_unchecked` | The same over local backing, with an explicit lifetime opt-out. |
| `arena.reset` | Give every allocation back at once. |
| `arena.used` | Count the bytes handed out, padding included. |

With `over_unchecked`, the caller ends every allocation before that
backing ends.

An individual free reclaims nothing. The arena resizes its latest block
in place and moves any other. It allocates no backing of its own.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-arena/main.ldn)

## core/pool

A reclaiming allocator over fixed-size slots and caller-supplied bookkeeping.

`over` fills the caller's `pool.space` and returns the pool's handle. The
pool allocates no backing storage of its own. Keep both payload backing
and metadata alive while allocations exist.

- It reuses the lowest free slot.
- It rejects malformed frees without reclaiming a slot.
- A zero-byte allocation still occupies one slot.
- A growth and a resize keep the block in its slot, to any extent the
  slot holds, and refuse a larger one, since no slot is larger. So a list
  over a pool grows in place until its slot is full.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-pool/main.ldn)

## core/region

An allocator scope that records allocations through a parent and releases them together.

`over` makes a region's handle over the caller's ledger,
`space(capacity)`, and a copy of the parent's handle:

| Capacity | Ledger |
|---|---|
| zero | grows through the parent; `growing_space` names it |
| positive | a fixed caller ledger |

Individual frees do nothing. Every allocation consumes a ledger entry
until release, whether or not its payload is still live.

A resize of the newest allocation goes to the parent, and its entry
follows the block. Any other block is moved into a new entry, the old one
freed at release.

`release` takes the ledger and the same parent and frees payloads in
reverse order. It is refused while the region's handle is still used.
End all payload uses before releasing the region.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-region/main.ldn)

## core/fault

Deterministic allocation-failure injection over any allocator, with cumulative counters.

`over` wraps a copy of a provider's handle in an `injector` over the
caller's `space`. `permit` replaces the budget without resetting
evidence.

The budget counts delegated attempts, including attempts the inner
provider refuses, so wrapping an arena counts both injected failures and
the arena's own.

- Free calls delegate to the parent.
- In-place growth is refused, so allocation-failure tests remain
  predictable.
- A resize is an attempt like an allocation: it spends the budget and is
  delegated or refused.
- A growth in place is delegated too, spending a permit, and counted by
  `growths` rather than `successes`, which counts the blocks the injector
  gave.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-fault/main.ldn)

## core/panic

The four compiler panic atoms and their shared panic-kind domain.

Checked range, arithmetic and conversion faults, and an unreachable path,
use these atoms.

An entry-module panic handler has the language-specified nonreturning
signature. A panic is distinct from a recoverable allocator or I/O error.

[Executable example](../compiler/tests/fixtures/runtime/library-shared-panic/main.ldn)

## core/random

A deterministic generator of pseudorandom numbers, the same sequence for a seed on every target.

| Call | What it does |
|---|---|
| `random.new` | Seed a generator from a `u64`, through splitmix64, as its authors suggest. |
| `random.from_entropy` | Seed one from 32 bytes of any `io.entropy` provider, the hosted system's or a test's scripted bytes. |
| `random.next` | Draw 64 bits. |
| `random.next_u32` | Draw the upper 32. |
| `random.below` | Draw a value under a bound, each equally likely. |
| `random.shuffle` | Put a slice in a uniformly drawn order. |

`generator` is xoshiro256** 1.0, Blackman and Vigna's: 256 bits of state
that each draw advances, a value the caller keeps and passes `inout`.

`below` masks to the bound's width and draws again when the value is too
large, so no division is made and no value is favoured. It traps for a
bound of zero.

The generator uses shifts, exclusive ors and additions on `u64`, so a
Cortex-M0 draws what a 64-bit host draws. Its sequences are the reference
implementation's on every target.

It is not cryptographic: its outputs reveal its state. A key, a token or
a password comes from `io.fill_random` directly.

[Executable example](../compiler/tests/fixtures/runtime/random-sequence/main.ldn)

## core/fibre

Fibres: tasks a routine starts as a group and waits for before it goes on.

| Call | What it does |
|---|---|
| `fibre.group_over` | Cut a backing the caller lends into equal stacks, run by any `fibre.scheduler`, and return the group `from` both. |
| `fibre.turns_over` | The same over a `fibre.turns`, for tasks that must take turns. |
| `fibre.admit` | Wait for a free stack, copy a state onto it and start a task that calls a routine with the copy. |
| `fibre.join` | Wait until every task has ended, and fail with the first failure any had. |
| `fibre.yield` | Let the provider's other fibres run, through `turns` evidence. |

A task is an ordinary routine, `(inout state: T) -> none !
failure.reason`, and its state a value copied onto its own stack, so one
group holds tasks of different state types. The state is kept until the
task ends, `escaping into` the group: what it refers to must outlive the
group, as the routine's own parameters and the locals declared before
the group do.

Two concepts say what runs the tasks:

| Concept | What it promises | Providers |
|---|---|---|
| `scheduler` | `start`, `finished` and `wait`; it may run each task to its end as it is admitted | `fibre.whole`, the blocking host, and every provider of `turns` |
| `turns` | a `scheduler` with `yield`: a task that yields lets every other unfinished one run first | `stacks.round`, `events.host` |

- A program written against `scheduler` must be right when every task
  runs to its end. One that needs turns asks `turns_over`, and is
  refused there for a provider of `scheduler` alone.
- Fibres are cooperative: a fibre gives the core away only inside a call
  to its provider, and the fibres of one provider are one execution
  context.
- The first failure is kept and the rest are dropped; nothing cancels a
  fibre, so `join` returns only once every task has ended.
- A group must be joined before its backing goes. Nothing but the
  program's `defer fibre.join(group) else none` makes sure it is.
- Each stack is at least 512 bytes after its record; a smaller backing
  fails `mem.out_of_memory`.

### Which calls may switch

A fibre loses the core only inside a call to an entry of the provider
that runs it, and a provider says which of its entries may switch. A
provider of `turns`, the event-driven host among them, may switch in the
entries that wait, and only in those:

| Concept | May switch | Never switch |
|---|---|---|
| `fibre.scheduler`, `fibre.turns` | `wait`, `yield`, and `start` where the provider runs a new fibre at once | `finished` |
| `io.reader`, `io.writer` | `read`, `write`, `write_some`, which wait for input or for room | none |
| `io.programs` | `wait`, for a child to end, and the child's `read_child` and `write_child` | `spawn`, `close_input` |
| `time.clock` | `sleep` | `now` |
| `net.network` | `connect`, `accept`, `send`, `receive`, `send_to`, `receive_from` | `listen`, `open_datagram`, `shutdown`, `local_address`, `peer_address`, `set_timeouts`, `set_no_delay`, `close_socket` |
| `signal.signals` | `next_signal` | `watch`, `stop_watching` |

Every other entry of `core/io`, `core/time` and `core/net` never
switches: `files`, `process`, `environment`, `directories`,
`file_system`, `terminals`, `entropy` and `wall_clock`, whose calls do
not wait for another fibre, and a provider's own queries, its last errno
among them. Shutting or closing a socket wakes the fibres waiting on it,
whose calls fail `io_failed`, and does not itself switch. A program reads
this table to know where another fibre may have run; between two such
calls nothing else of the provider's has.

The library's own providers of turns switch in fewer:

| Provider | Switches in |
|---|---|
| `stacks.round` | `yield` and `wait`; its `start` prepares the fibre and returns |
| `fake.network` over turns | `accept`, `send`, `receive`, `receive_from`, `read`, `write` and `write_some`, and only where the call would wait |
| `fake.signals` | `next_signal` when nothing waits to be read, and its round's `yield` and `wait` |
| `events.host` | `yield` and `wait`; `read`, `write` and `write_some` when the file is not ready; `read_child` and `write_child` when the pipe is not; the programs' `wait`, for the child's end; `sleep` until its deadline; `accept`, `connect`, `send`, `receive`, `send_to` and `receive_from` where the socket would wait; and `next_signal` when no arrival waits to be read. Its `start` prepares the fibre and returns, and `close`, `close_socket`, `shutdown`, `close_input` and `stop_watching` wake the fibres waiting on what they end without switching |

`fake.clock`'s `sleep` advances the clock and returns, and switches
nowhere; a test whose sleeps must take turns gives its fibres a clock
that yields, as the example below does.

[Executable example](../compiler/tests/fixtures/runtime/fibre-same-source-any-provider/main.ldn)

## core/fibre/stacks

The switch between stacks, and a round of fixed turns built on it.

| Call | What it does |
|---|---|
| `stacks.round_over` | Fill the caller's `stacks.round_space` and return a `stacks.round`, a provider of `fibre.turns` over the caller's table of records. |
| `stacks.prepare` | Lay out a fibre's first frame on a stack, for a provider of its own. |
| `stacks.switch` | Save the leaving fibre's registers and resume another's. |

A round's entry 0 is the stack it was made on; its other entries are the
fibres it started, in the order they were started. `start` prepares and
returns, and the fibre runs at its first turn. The table holds one entry
more than the fibres that may be unfinished at once.

When every unfinished fibre has yielded since anything last started or
ended, the round calls its `stacks.idler` before it goes on: a device
waits for an interrupt there, and `stacks.spin` returns at once.

In a program that prepares a stack, every routine checks its frame
against the stack it runs on before it reserves the frame, and traps
`stack_exhausted` at its own site when the frame would go below the
stack's limit, so a task that goes too deep stops at the call that would
have overflowed, between switches as at them. The limit stands a margin
above the stack's lowest byte, room for a failed check's handler: 640
bytes on x86-64 and arm64, 768 on RV64 and 384 on Cortex-M0, which
`--stack-report` gives as `margin_bytes`. A switch carries each stack's
limit with the registers it saves. A prepared stack is at least 128
words, beside the few words its first frame keeps at its top; size it
from the report's depth of the task's routine and the margin.

Every target with a native backend admits this module, and
synthetic-32 does not; a program over `fibre.whole` or the blocking host
does not import it, and runs on every target.

[Executable example](../compiler/tests/fixtures/runtime/fibre-turns-interleave/main.ldn)

## hosted/heap

An explicit allocator over the host runtime heap.

`new` returns a `heap`, a handle that borrows nothing: the heap belongs to
the process. Allocations remain manual obligations. No ambient allocator
is installed, and containers still receive the provider explicitly.

The provider keeps eight size classes, of 32 to 4096 bytes, over chunks
it maps through `platform/posix`, written once for every hosted system:

- a freed slot goes back on its class's list and is the next one handed
  out;
- a larger request is a mapping of its own, rounded to the system's page
  and unmapped when it is freed.

A block grows or shrinks in place while its slot or mapping holds it, and
a mapping grows where the pages after it are free. Otherwise a resize on
Linux moves a mapping's pages with `mremap`, and anything else is copied.

Every `usize` alignment is honoured by over-allocating and keeping a
header before the block.

It is single-threaded. A refusal comes before any state changes.

[Executable example](../compiler/tests/fixtures/runtime/hosted-heap-provider/main.ldn)

## hosted/blocking

The hosted provider whose waiting operations block the thread, written
once over `platform/posix`: the provider `host`, made by `new`, imported
as `blocking` with no alias. It is what an ordinary hosted program
imports.

| Call | What it does |
|---|---|
| `blocking.new()` | The process's provider: a `host` handle that borrows nothing. |
| `blocking.over(space)` | A provider that keeps its last errno in a `space` the caller declares. |
| `blocking.last_errno(host)` | The errno number of the last failing call. |
| `blocking.last_signal(host)` | The signal that ended the last child waited for. |

`host` supplies every concept of `core/io`, `core/time` and `core/net`:
the shared I/O concepts and so `world`, `directories`, `environment`,
`programs`, `network`, `file_system`, `terminals`, `clock`, `wall_clock`
and `entropy`. It is also a `fibre.scheduler` that runs each task to its
end before `admit` returns, as `fibre.whole` does, and so is no provider
of `fibre.turns`: its calls block the thread.

It is built over a `hosted/system` handle, which `new` makes, and hands
that handle everything that does not wait: opening and closing files, the
standard streams' descriptors and the arguments, the environment,
directories, the rest of the file system, terminals, entropy and the wall
clock. What waits is its own: `read`, `write` and `write_some`, running
programs, the network, and the monotonic clock with its `sleep`. A child
is started by the system handle's `start`, which does not wait; reading
and writing its pipes and waiting for it are this provider's. Both
report through the system handle's one last-error cell, so `last_errno`
says the same whichever of them failed. Its files are the system's:
`hosted/system`'s `descriptor_of`, `file_of` and `socket_of` convert them.

### What the provider promises

| Call | Promise |
|---|---|
| `write` | Writes the whole slice, or fails. Bytes written before a failure stay written. |
| `write_some` | Makes one attempt and returns a positive count, which may be short. A failed attempt writes nothing. |
| either, on an empty slice | Succeeds without asking the system; `write_some` returns zero. |
| open, `read`, `write` | Retried after a signal interrupts them only when the system guarantees the attempt made no progress: completed progress is never repeated. |
| `close` | Consumes the file once, even when it fails, and is never retried blindly. |
| `same_file(left, right)` | Follows symbolic links and recognises hard links. The left path must exist; a missing right path gives false, and any other failure is an error. The check is not atomic: the names must stay put until the open that follows. |
| the arguments | Begin after the program's name: neither this provider nor the memory world includes `argv[0]`. |

### The network

`network` runs over `platform/posix`'s sockets. A socket is a descriptor
and a file of the provider like any other, so `read` and `write` take a
connection.

- A write to a socket the provider made is a send, which raises no
  SIGPIPE beside a C handler on any system.
- A listener reuses its address.
- An IPv6 socket takes IPv6 alone on every system, which BSD does from
  the start and Linux does not.
- Up to 128 connections wait to be accepted.

Interruptions and partial results are handled for you:

- an interrupted call is made again;
- a connection a signal interrupted is waited out with `poll`, and its
  outcome read from the socket;
- an accept refused because its connection was reset before it was taken
  accepts the next;
- a send goes on after a short one until every byte is sent.

A send to a peer that has gone is `disconnected`, EPIPE or ECONNRESET kept
as the last errno, and a `write` to it is `io_failed` with EPIPE. The
process ignores SIGPIPE, so neither ends it.

### The clock

| Call | On the hosted provider |
|---|---|
| `now` | `platform/posix`'s monotonic clock, in nanoseconds since the system started. |
| `sleep` | Takes its deadline from the monotonic clock, and asks the system to sleep for what is left until that clock has reached it. |

A clock the system cannot read ends the program, since no hosted system
fails to.

A sleep a signal interrupts, or the system ends early, sleeps on: it
never returns before the deadline as `now` reads it.

[Executable example](../compiler/tests/fixtures/runtime/library-system-arguments/main.ldn)

The program prints the arguments `blocking.new()`'s provider lends, one to
a line after its index. It then looks for a settings file that is not
there and prints why it could not be opened, in `failure.words`' phrase
and by `blocking.last_errno`'s number, before going on with its defaults.

## hosted/events

The hosted provider whose waiting operations switch fibres, written once
over `platform/posix`, `platform/linux`'s epoll and signalfd and
`platform/kqueue`: the provider `host`, made by `new`, imported as
`events` with no alias. A program that serves several things at once,
or waits for a signal, mints it instead of `blocking.new()`.

| Call | What it does |
|---|---|
| `events.new(space, entries)` | Fill an `events.space` the caller declares `zeroed` and return a `host` over it and over `entries`, the table of fibres that may be unfinished at once, one more than a group's count. |
| `events.last_errno(host)` | The errno number of the last failing call, in the process's cell. |
| `events.last_signal(host)` | The signal that ended the last child waited for. |

`host` supplies every concept `hosted/blocking` does, `world`,
`programs`, `network`, `clock` and the system's, and is a
`fibre.turns` and a `signal.signals` beside them. Its fibres take turns
on a `stacks.round` over the caller's table; when every fibre has taken
a turn since anything last started or ended, the round waits for events:
epoll on Linux and kqueue on Darwin and FreeBSD, limited by the earliest
deadline any fibre waits for, and not at all when a fibre yielded of its
own accord. With nothing waiting it returns at once.

- A call that would wait submits a record on its fibre's own stack and
  takes turns until the loop answers it: the descriptor is ready, the
  deadline passed, or what it waited on was closed. A completion
  interface could answer the same records with the call's result.
- The provider's sockets and a child's pipes are non-blocking. A file it
  did not make is polled first and read or written once it is ready, so
  a regular file is read at once, and a terminal or a pipe a fibre waits
  for lets the others run.
- Closing a file or a socket, or shutting a socket's side, through the
  provider wakes every fibre waiting on it, whose call fails `io_failed`.
- A socket's limits from `set_timeouts` bound each wait, and their
  passing is `timed_out`. A connect has no limit.
- `sleep` waits for its deadline in the loop, never early: no timer or
  descriptor is made for it.
- A child's end is waited for on a pidfd on Linux and with kqueue's
  process filter on Darwin and FreeBSD, then reaped.
- `watch` blocks the signal and reads it through a signalfd on Linux,
  and ignores it and reports it through kqueue on Darwin and FreeBSD,
  SIGCHLD keeping its default there; every child started afterwards gets
  the signal's default back. `stop_watching` reads what arrived, gives
  each signal its default back and wakes every fibre in `next_signal`.
- The event queue is closed on exec and stays open until the process
  ends.

The entries that may switch are the table's above, under "Which calls
may switch".

[Executable example](../compiler/tests/fixtures/runtime/events-tcp-exchange/main.ldn)

The program runs a server fibre and a client fibre over one loopback
connection; each waits in `receive` while the other runs, so their lines
interleave.

## hosted/system

The hosted services that do not wait and are the same whoever waits,
written once over `platform/posix`: the provider `host`, made by `new`,
imported as `system` with no alias. It reads and writes no stream, so it
is not a `world`; `hosted/blocking` is built over it and supplies what
waits. A program that never reads, writes or sleeps may use it alone.

| Call | What it does |
|---|---|
| `system.new()` | The process's services: a `host` handle that borrows nothing. |
| `system.over(space)` | A handle that keeps its last errno in a `space` the caller declares. |
| `system.last_errno(host)` | The errno number of the last failing call. |
| `system.last_signal(host)` | The signal that ended the last child waited for. |
| `system.descriptor_of(file)`, `system.file_of(descriptor)` | Convert between a provider's file and a `platform/posix` descriptor. |
| `system.socket_of(descriptor)`, `system.is_socket(file)` | A provider's socket from a socket of `platform/posix`'s, and whether a file is one. |
| `system.clear_errno(host)`, `system.record_errno(host, errno)` | Clear the last-error cell, or keep an errno in it, for a provider built over this one. |
| `system.start(host, path, arguments, environment, streams)` | Start a child as `io.spawn` does, for a provider built over this one that supplies `io.programs`. |
| `system.process_of(child)`, `system.ended(host, status)` | The child's `platform/posix` process ID, and the `io.ending` of the status a provider waited for, keeping its signal for `last_signal`. |

`host` supplies `files`, `process`, `environment`, `directories`,
`file_system`, `terminals`, `entropy` and `wall_clock`. It is no provider
of `programs`: reading a child's pipes and waiting for it wait, so a
provider built over it supplies `programs` over its `start`.

### The provider

`new` makes a handle exposing process arguments, lent as host strings,
and standard streams. They come from the root the hosted entry
establishes through `platform/posix`'s `_landin_host_initialize_arguments`;
a C `main` that drives Landin exports calls that initializer itself, as
below.

The handle borrows nothing, since the root, the descriptors and its
last-error cell belong to the process. `over` makes a handle that keeps
its last errno in a `space` the caller declares, for a C thread or a
library that must not share the process's.

`last_errno` captures the terminal failing call as provider-specific
detail: the number of the errno `platform/posix` failed with. It is not a
portable error type. A call that succeeds clears it, and a refusal the
provider makes itself, without asking the system, sets none. `last_signal` is the number of the signal that ended
the child last waited for, beside `io.ending`'s `signalled`, and zero
after a child that exited.

### A C `main` that calls Landin

A Landin entry point sets up the arguments before its body runs. A program
whose `main` is C's, calling public Landin routines, does it itself, by
calling `_landin_host_initialize_arguments(argc, argv, envp)` from
`platform/posix`:

- Call it before the first `system.new()` or `blocking.new()`, and before
  starting any thread that may make one; both trap before it. Importing `core/io`
  does not initialize anything, and files, streams and the heap work
  without it.
- The first call needs a nonnegative `argc` and a non-null `argv`, and
  keeps that exact `argc`, `argv` and `envp` as the process's root. A null
  `envp` is an empty environment.
- A later call with the identical three values is harmless. A negative
  count, a null table, or a call that would replace any of the three,
  traps.
- Nothing is copied: C keeps the tables and every string they name
  readable for as long as anything Landin made from them is used.
- The arguments a program sees begin at `argv[1]`, and there are
  `argc - 1` of them, or none. Looking up a null entry within that count
  traps.

### Files and directories

- Standard input, output and error are descriptors 0, 1 and 2.
- Open-write creates or truncates regular files.
- A path that names nothing is `not_found`, whether a component is
  missing or one before the last is not a directory, ENOENT or ENOTDIR.
  `same_file` answers false for such an output path.
- A path that holds a NUL is `io_failed` with EINVAL, and one longer than
  the system's PATH_MAX is `io_failed` with ENAMETOOLONG, as
  `platform/posix` refuses them.

A directory's buffer must hold at least `io.directory_buffer`, 1024
bytes, so that every entry a hosted system gives fits; otherwise opening
it fails with `io_failed` before anything is opened. It is read through
`platform/posix`'s directory streams, `.` and `..` left out. An entry
whose type the file system does not record is asked with a status call
relative to the directory.

`make_directory` gives a new directory 0777, which the process umask
filters. It is not retried when interrupted, because a directory made
before the interruption would then report `already_exists`.

### The environment and starting programs

The environment is the one the process's entry was given, read where the
entry left it, never copied and never changed.

`start` runs over `platform/posix`'s `spawn`:

- a discarded stream is the system's `/dev/null`;
- a piped one is a pipe whose child end is closed in the parent once the
  child has it;
- a child receives only its three streams, since every descriptor the
  provider makes is closed on exec and the spawn closes any other, and
  starts with no signal blocked;
- an interrupted spawn is made again.

The pipes it answers are files of this provider, which the provider built
over it reads, writes and closes as its own. `hosted/blocking`'s
`read_child` polls both pipes when both are open, and reads the output
first when both have something, and its `wait` closes the child's pipes
before it waits, so a child still writing to one meets a closed pipe
rather than a parent that never reads. An interrupted poll, read or wait
is made again.

### The rest of the file system and terminals

`file_system` and `terminals` run over `platform/posix`:

| Call | On the hosted provider |
|---|---|
| `open_file` | Creates a file 0666, which the process umask filters. Refuses options no open can have with `io_failed`, keeping EINVAL, before it asks the system. A taken name `exclusive` meets is `already_exists`. |
| `rename` | `renameat`: ENOENT is `not_found` and the rest `io_failed` with the errno kept. Not retried when interrupted. |
| `read_only` status | A file is read-only when no permission bit lets anyone write it. |
| `set_read_only` | Clears every write bit, or sets the owner's again, reading the bits and setting them in two calls. |
| `synchronize` | `fsync`, or `fdatasync` for the data alone; on Darwin `F_FULLFSYNC` either way. |
| `make_temporary` | Created exclusively with 0600; when every try finds its name taken, the last errno is EEXIST. |
| `window_size` | Of anything but a terminal is `not_a_terminal`, keeping ENOTTY. |

`descriptor_of` gives the `platform/posix` descriptor a file of this
provider is, for a call the portable concepts do not make: a permission
bit, a lock or a terminal's raw mode. `file_of` gives the file a
descriptor is.

### The wall clock and entropy

| Call | On the hosted provider |
|---|---|
| `wall_now` | `platform/posix`'s realtime clock. |
| `fill_random` | `platform/posix`'s `random_bytes` until the buffer is full, asked again after an interruption: `getrandom` on Linux, which waits at boot until the kernel's pool is ready, and `arc4random_buf` on Darwin and FreeBSD. |

A clock the system cannot read ends the program, since no hosted system
fails to.

[Executable example](../compiler/tests/fixtures/runtime/hosted-system-alone/main.ldn)

The program uses `hosted/system` alone: it counts its arguments, finds a
variable of its environment, makes and removes a directory, and asks for
random bytes and the time, answering with its exit status since it has
nothing to write with.

## platform/posix

POSIX's facilities in Landin types, on Linux, Darwin and FreeBSD alike.

The calls are POSIX's own, not policy. This module is what `hosted/system`
and `hosted/blocking` are written over, and what a program uses when it needs a call the
portable concepts do not make.

It is written twice beneath its interface: over `platform/linux`'s system
calls, and over `platform/libc`. A system that is not POSIX, as Windows
is not, has none.

### Descriptors, failures and paths

A `descriptor` is a handle type, not a number to count with, so
descriptors compare with `==` and nothing else.

| Value | Is |
|---|---|
| `standard_input`, `standard_output`, `standard_error` | 0, 1 and 2 |
| `working_directory` | the directory an `*_at` call's relative path starts from |

A failure is the errno as an atom of `errno`: one atom for each errno the
three systems define, named after its C macro in lower case, `enoent` and
`eintr` among them.

- `number` gives the number this system uses for an atom, and `errno_of`
  the atom for a number.
- `unlisted` is a failure with no errno this module names.
- An interrupted call fails with `eintr` and is not retried here.
- A short transfer is returned as it came.

A path or an argument is a host string. The module copies it into a
buffer of the system's PATH_MAX with the NUL a C call needs, refusing one
that holds a NUL with `einval` and one too long with `enametoolong`.

Every descriptor the module makes is closed when the process executes a
program. `closed_on_exec` says whether a descriptor is. No open makes a
terminal the process's controlling terminal, `O_NOCTTY`.

### Files and directories

| Call | What it does |
|---|---|
| `open_at` | Open with `open_options`; `reading` and `writing` are the two the hosted provider uses. |
| `read`, `write`, `close` | As POSIX's. |
| `read_at`, `write_at` | `pread` and `pwrite`, refusing an offset C's `off_t` cannot hold with `einval`. |
| `truncate` | `ftruncate`. |
| `synchronize` | `fsync`, or `fdatasync` with `data_only`. |
| `status_at`, `status_of` | A structured `status` of a path, or of an open file. |
| `open_directory`, `read_directory`, `close_directory` | Read a directory over a caller's buffer, listing `.` and `..` as POSIX does. |
| `make_directory_at`, `unlink_at`, `remove_directory_at` | Change the tree. |
| `rename_at` | Rename in one step, replacing a file already at the new name. |
| `link_at` | Give a file a second name, without following a final link of the old one. |
| `symbolic_link_at`, `read_link_at` | Make a link, and read its target into the caller's buffer, `erange` when the target fills it. |
| `change_mode_at`, `change_mode` | Set permission bits; `einval` beyond `0o7777`. |
| `change_owner_at`, `change_owner` | Set an owner and group; `unchanged_user` and `unchanged_group` keep either, and a link's own with `follow` false. |
| `set_times_at`, `set_times` | Set when a file was last read and written, to the nanosecond; a link's own with `follow` false. |
| `current_directory` | `getcwd`; nothing here changes the working directory. |

A `status` gives device, inode, kind and size. It also gives a file's
permission bits, its links, its owner and group as a `user_id` and a
`group_id`, and when it was last read, written and changed.

### Locks

Two kinds of advisory lock are given, as every one of the systems has
both:

| | `lock`, `unlock` | `lock_range`, `unlock_range` |
|---|---|---|
| Is | BSD's `flock`, a whole-file lock | POSIX's record locks, `fcntl`'s `F_SETLK` and `F_SETLKW` |
| Kind | a `lock_kind`, `shared_lock` or `exclusive_lock` | the same |
| Belongs to | the open file, so a second open of the file in the same process stands in its way | the process, so the process never stands in its own way, and a child does not inherit them |
| Lasts until | every descriptor of that open file is closed | any descriptor of the file is closed, even one opened elsewhere for a moment, which gives every one of them up |
| A refused attempt | `eagain` | `eagain`, or `eacces` where the system says so |

Use one kind on a file, since the systems differ in how the two see each
other.

### Memory and polling

`map` and `unmap` handle anonymous memory, and `page_size` gives the
page. `extend` grows a mapping where it is, and `remap` grows it where it
is or moves its pages.

`poll` runs over entries made by `watch` and read by `happened`. Its
`poll_events` is a distinct flag set, combined with `|` and tested with
`&` against `poll_no_events`:

| Flags | Use |
|---|---|
| `poll_input`, `poll_output`, `poll_urgent` | asked about |
| `poll_error`, `poll_hung_up`, `poll_invalid` | only reported |

`set_non_blocking` makes calls on a descriptor that would wait fail
`eagain` instead, `O_NONBLOCK`, and `non_blocking` reads the mode back. The
mode belongs to the open file, so every duplicate of the descriptor shares
it. A program that waits for readiness sets it and then waits with `poll`,
or with epoll or kqueue for many descriptors.

### Processes

| Call | What it does |
|---|---|
| `pipe` | Make a pipe's two ends. |
| `spawn` | Start a program by its path. |
| `default_in_children` | Give every child a signal's default disposition. |
| `wait` | `waitpid`, reporting a `child_status`. |
| `exit` | End the process. |
| `arguments`, `argument` | The process's arguments. |
| `environment`, `variable` | The process's environment. |
| `program_name` | `argv[0]`. |

`spawn` gives the program its arguments after `argv[0]`, which is the
path, and an environment of `core/io`'s `variable` records. Its standard
streams are duplicated from three descriptors, `standard_streams`, of
which `inherited_streams` are the parent's own. Every other descriptor is
closed in the child. A failure starts nothing: `enoent` for a missing
program, and `einval` for a NUL in an argument or a bad name.

A `child_status`'s variant part is `exited` with a code, or `signalled`
with the signal's number, which each system numbers its own way.

The process's arguments and environment are its root, established by
`_landin_host_initialize_arguments` from C's `argc`, `argv` and `envp`.

The argument initializer ignores SIGPIPE when it finds the default, so a
write to a pipe or a socket nobody reads is `epipe` and not the end of
the process. A handler a C `main` installed first is kept.
`broken_pipe_ignored` says whether it is ignored, and `spawn` gives every
child SIGPIPE's default back. A program that imports no part of the POSIX
layer keeps the system's default.

A child starts with no signal blocked, whatever the parent's mask, so a
provider that blocks a signal to read it through a signalfd starts no
child with it blocked. `default_in_children` names a signal a provider
took from its disposition, ignoring it to read it through kqueue, and
every child `spawn` starts from then on gets that signal's default back
too. A signal nobody named keeps the parent's disposition in the child,
an ignore included, as a shell's background job and `nohup` expect. It
refuses a number that is no signal, one past 64, or past 31 on Darwin,
and SIGKILL and SIGSTOP, with `einval`.

### Clocks and random bytes

`clock_time` reads the `monotonic_clock` or the `realtime_clock` as a
`time_value` of seconds and nanoseconds, POSIX's `clock_gettime`.

`sleep` is `nanosleep`, failing `eintr` with part of the span unslept.

`random_bytes` fills a buffer with the system's random bytes.

### Sockets

The sockets are POSIX's too.

| Call | What it does |
|---|---|
| `socket` | Make a socket of a `socket_family`, `internet`, `internet6` or `local` for Unix-domain sockets, and a `socket_kind`, `stream` or `datagram`. |
| `socket_pair` | Two connected Unix-domain sockets. |
| `bind`, `listen`, `accept`, `connect` | As POSIX's. A non-blocking `connect` fails `einprogress` and goes on: `poll` for `poll_output`, then `pending_error`, says how it ended. |
| `accept_non_blocking` | `accept` for a program that waits for readiness: the new socket is non-blocking whatever the listener's mode, and no receive limit bounds it, so a non-blocking listener with no connection waiting fails `eagain` at once. |
| `send`, `receive`, `send_to`, `receive_from` | As POSIX's. |
| `shutdown` | With a `shutdown_side`. |
| `socket_name`, `peer_name` | The two ends' addresses. |
| `set_reuse_address`, `set_no_delay`, `set_ipv6_only` | Options. |
| `set_receive_timeout`, `set_send_timeout`, `receive_timeout` | Time limits. |
| `pending_error` | Fails with the error pending on a socket. |

The receive limit bounds an `accept` on every system, `eagain` when it
passes.

A `socket_address` is the system's own record, laid out here for each
system, Darwin's and FreeBSD's length byte included.

- `internet_address` makes one from a `net.address`.
- `unix_address` makes one from a path, refusing one too long for the
  system.
- `family_of`, `address_of` and `unix_path` read one back.

A send to a peer that has gone fails `epipe` without raising SIGPIPE.

### Terminals

| Call | What it does |
|---|---|
| `is_terminal` | Say whether a descriptor is a terminal. |
| `window_size_of`, `set_window_size` | A `window_size` of rows, columns and pixels. |
| `terminal_mode_of`, `set_terminal_mode` | Read and set a `terminal_mode`, the system's own record; a change applies `immediately`, `after_output` or `discarding_input`. |
| `raw_mode` | Make a mode raw, as `cfmakeraw` does. |
| `reads_lines` | Say whether a mode reads a line at a time, with echo. |
| `same_terminal_mode` | Say whether two modes are the same. |
| `open_pseudo_terminal` | Open a `pseudo_terminal`: a `controller` and its `terminal`, both closed on exec. |

There are no destructors, so a program that changes a terminal gives it
back the settings it found with a `defer`.

### Users and groups

| Call | What it does |
|---|---|
| `real_user`, `effective_user`, `real_group`, `effective_group` | The process's IDs. |
| `account_with_id`, `account_named` | Read an `account` into the caller's buffer. |
| `group_with_id`, `group_named` | Read a `group_entry` into the caller's buffer. |
| `parse_account`, `parse_group` | Read one line of /etc/passwd's or /etc/group's form. |
| `member_count`, `member` | Read a group's members. |

A lookup reports `no_account` when there is none, and `erange` when the
buffer is too small. Where it looks is told apart by `compiler.c_runtime`
when the program is compiled; the table below says which.

On a static Linux program, /etc/passwd and /etc/group are read a line at
a time. The first entry that matches is taken, every line that is not one
is skipped, and `erange` is reported when a line too long for the buffer
might have been the one.

`parse_account` and `parse_group` refuse with `malformed_entry`: a
comment, an NIS line, a field missing or too many, an empty name, and an
ID that is not a decimal below `0xFFFFFFFF`. `member` skips an empty name
between commas.

### Shared objects

| Call | What it does |
|---|---|
| `open_library` | Load a shared object by its path, or by the system's search for a name with no slash. |
| `find_symbol` | A symbol's address, never zero, as a `usize`. |
| `close_library` | Give one use back. |
| `library_failure` | Copy the loader's own words for the last failure on this thread into the caller's buffer. |

`open_library` binds every symbol the object needs at once, POSIX's
`RTLD_NOW`. Its symbols are `local_symbols`, resolving no other object's
references, or `global_symbols`, resolving those of every object loaded
after it. The scope is always said, because Darwin's default is not the
other systems'.

A `library` is a handle that counts one use of the object. Loading it
again gives the same object and counts another.

A C function type applied to an address, `adder(address)`, makes the
function a value. Nothing can check that type, as nothing checks a C
cast. A function found in a library is the program's to call only while a
use of it is open, which no check of the language follows.

A failure is `no_library` or `no_symbol`. Call `library_failure` at once,
since asking clears the words and the next call may replace them.

It is the C library's `dlopen`, `dlsym`, `dlclose` and `dlerror` on every
system, so a static Linux program that loads a library is refused before
it links, naming the routine and `--link=libc`. What is loaded is C, or
another language's code reached through its C entry points.

### How each system does it

| Call or fact | Linux | Darwin | FreeBSD |
|---|---|---|---|
| beneath the interface | `platform/linux`'s system calls | `platform/libc` | `platform/libc` |
| `pipe` | `pipe2` | `pipe` and `fcntl` | `pipe2` |
| `spawn` | copies the process with `clone`, as `fork` does; the child moves its streams into place and executes the program, reporting a failure through a pipe closed on exec | the C library's `posix_spawn` | the C library's `posix_spawn` |
| SIGPIPE's default in a child, and each signal's `default_in_children` named | restored in the child before it executes the program | `posix_spawnattr_setsigdefault` | `posix_spawnattr_setsigdefault` |
| a child's empty signal mask | `rt_sigprocmask` in the child before it executes the program | `posix_spawnattr_setsigmask` | `posix_spawnattr_setsigmask` |
| `clock_time` | the vDSO's `clock_gettime` when the auxiliary vector names a vDSO that has one, found once and kept, under `--link=libc` as under a static link; the system call otherwise | the C library | the C library |
| `sleep` | `clock_nanosleep` on the monotonic clock | `nanosleep` | `nanosleep` |
| `random_bytes` | `getrandom` without `GRND_NONBLOCK`, which may fill a request over 256 bytes short and fail `eintr` | `arc4random_buf`, which fills it all and never fails | `arc4random_buf`, likewise |
| `synchronize` | `fsync`, or `fdatasync` | `F_FULLFSYNC`, falling back to `fsync` | `fsync`, or `fdatasync` |
| `extend` | `mremap` without `MREMAP_MAYMOVE` | asks for the pages after the mapping, kept only when the system puts them there | as Darwin |
| `remap` | `mremap` with `MREMAP_MAYMOVE`, moving pages rather than copying bytes | cannot move a mapping: `extend` | as Darwin |
| a socket closed on exec | SOCK_CLOEXEC | `fcntl` just after | SOCK_CLOEXEC |
| a send without SIGPIPE | MSG_NOSIGNAL | SO_NOSIGPIPE set on each socket | SO_NOSIGPIPE set on each socket |
| `accept`'s time limit | the kernel limits it | `accept` polls for a connection for as long as the limit first | as Darwin |
| `accept_non_blocking` | `accept4` with SOCK_NONBLOCK | `accept`, then `fcntl` | `accept4` with SOCK_NONBLOCK |
| a socket `accept` takes from a non-blocking listener | blocking | non-blocking, as the listener is | blocking |
| `unix_address`'s longest path | 108 bytes | 104 bytes | 104 bytes |
| `open_pseudo_terminal` | /dev/ptmx and `TIOCGPTPEER`, or the terminal's /dev/pts path where a kernel or an emulator lacks it | `posix_openpt` | `posix_openpt` |
| accounts and groups | from /etc/passwd and /etc/group in a static program; through the C library under `--link=libc` | the C library, which asks every database the system is set to | as Darwin |
| shared objects | under `--link=libc` only | the C library | the C library |

On Linux `_landin_host_initialize_arguments` hands `platform/linux` the
tables it is given, so a program the C runtime started finds the
auxiliary vector after the initial stack's `envp` too.

[Executable example](../compiler/tests/fixtures/runtime/posix-files/main.ldn)

## platform/libc

The C library's declarations, as ordinary `extern(c)` imports, raw.

Its scope is the systems with a C library: Linux, Darwin and FreeBSD.

| System | Who uses this module |
|---|---|
| Darwin, FreeBSD | `platform/posix` reaches the operating system only through it, since their C library is their system interface. |
| Linux | `platform/posix` makes `platform/linux`'s system calls; this module serves a program linked with `--link=libc`. |

Every declaration is bodyless, so a program that names none of them needs
no C library, and a static Linux program that names one is refused before
it links.

A program that declares one of these C functions itself must declare it
with the same types, or the two declarations of one C symbol are refused
with L0347.

### Conventions

- `open` and `openat` are declared variadic, as C declares them, and take
  the mode as the one unnamed argument.
- Facts that differ between systems are chosen by `compiler.os`; the
  table below lists them. `stat`'s record follows the system and the C
  ABI.
- Read the errno cell immediately after a failing call.
- `mmap`'s failure is `map_failed`.
- `posix_spawn` reports its failure as its result, not in errno.
- `readdir`'s and `fdopendir`'s null pointer is `no_directory`;
  `dlopen`'s is `not_loaded` and the other loader calls' `no_address`. An
  optional pointer is the `no_address` union.

### What it declares

| Area | Declarations |
|---|---|
| processes | `pipe`, `pipe2` where it exists, the variadic `fcntl`, `waitpid` and `posix_spawn` with its file actions and attributes, each a C-library pointer in a `spawn_object` cell |
| directories | `fdopendir`, `readdir`, `closedir`, `fstatat`, `mkdirat` and `unlinkat`, with each system's `struct dirent` as `directory_record`, its `at_fdcwd`, `o_directory`, `at_symlink_nofollow` and `at_removedir`, and the `d_type` and mode bits |
| clocks and randomness | `clock_gettime` with a `clock_realtime` or a `clock_monotonic`, `nanosleep` with a `timespec`, and `arc4random_buf` |
| sockets | `socket`, `socketpair`, `bind`, `listen`, `accept`, `accept4`, `connect`, `send`, `recv`, `sendto`, `recvfrom`, `shutdown`, `setsockopt`, `getsockopt`, `getsockname` and `getpeername`, with each system's `af_inet6`, `sol_socket` and option numbers, `sock_cloexec` and `msg_nosignal` where they exist, `so_nosigpipe`, the address records' sizes and its `time_limit`, C's `struct timeval` |
| signals | `sigaction` with each system's `signal_action` and `signal_set`, `sigprocmask` with each system's `sig_block`, `sig_unblock` and `sig_setmask`, `getpid` and `kill`, the signals `sighup`, `sigint` and `sigterm` and each system's `sigusr1` and `sigusr2`, `posix_spawnattr_setsigdefault` with `posix_spawn_setsigdef`, and `posix_spawnattr_setsigmask` with `posix_spawn_setsigmask` |
| descriptors that do not block | `fcntl`'s `f_getfl` and `f_setfl`, each system's `o_nonblock`, and `sock_nonblock` where it exists |
| the rest of the file system | `pread`, `pwrite`, `ftruncate`, `fsync`, `fdatasync`, `getcwd`, `renameat`, `linkat`, `symlinkat`, `readlinkat`, `fchmodat`, `fchmod`, `fchownat`, `fchown`, `utimensat`, `futimens`, `fstat`, `flock` with its `lock_sh`, `lock_ex`, `lock_nb` and `lock_un`, and `fcntl`'s record locks with each system's `f_getlk`, `f_setlk`, `f_setlkw`, lock types and `lock_record`, C's `struct flock` |
| users and groups | `getuid`, `geteuid`, `getgid` and `getegid` for the process's IDs, and `getpwuid_r`, `getpwnam_r`, `getgrgid_r` and `getgrnam_r` over each system's `account_record`, C's `struct passwd`, and the shared `group_record` |
| shared objects | `dlopen`, `dlsym`, `dlclose` and `dlerror`, with `rtld_now` and each system's `rtld_local` and `rtld_global`; glibc keeps them in its libc since 2.34 |
| terminals, as Darwin and FreeBSD use them | `isatty`, the variadic `ioctl` with `tiocgwinsz` and `tiocswinsz` over a `window_record`, `tcgetattr` and `tcsetattr` with `tcsanow`, `tcsadrain` and `tcsaflush` over each system's `terminal_record`, its mode bits and `vmin` and `vtime`, and `posix_openpt`, `grantpt`, `unlockpt` and `ptsname_r`; `o_noctty` and `at_symlink_follow` are each system's |

### How each system differs

| Fact | Linux | Darwin | FreeBSD |
|---|---|---|---|
| the errno accessor `errno_cell` | `__errno_location` | `__error` | `__error` |
| `open` and `mmap` flags, `poll`'s count type | Linux's | Darwin's | FreeBSD's |
| `mkdirat`'s mode, as `mode_t` | 32 bits | 16 bits | 16 bits |
| `fchmodat`'s and `fchmod`'s mode | as `mode_t` | a `u16` | a `u16` |
| `clock_monotonic` | 1 | 6 | 4 |
| `arc4random_buf` | not declared | declared | declared |
| `accept4` | declared | not declared | declared |
| `sig_block`, `sig_unblock`, `sig_setmask` | 0, 1, 2 | 1, 2, 3 | 1, 2, 3 |
| `sigusr1`, `sigusr2` | 10, 12 | 30, 31 | 30, 31 |
| `o_nonblock` | 2048 | 4 | 4 |
| `sock_nonblock` | 2048 | none | its own |
| `fdatasync` | declared | not declared; `f_fullfsync` instead | declared |
| `so_nosigpipe` | none | yes | yes |
| `time_limit`'s microseconds | an `i64` | an `int` | an `i64` |
| `posix_spawnattr_setsigdefault`, `posix_spawnattr_setsigmask` | not declared | declared | declared |
| `posix_spawn` extras | none | `posix_spawn_cloexec_default` and `addinherit_np` | `addclosefrom_np` |
| `rtld_local`, `rtld_global` | as FreeBSD's | numbered its own way | as Linux's |

[Executable example](../compiler/tests/fixtures/abi/r440-native-hosted/program.ldn)

## platform/linux

Linux's system calls with no C library beneath them, and the process entry of a static Linux executable, raw.

Every declaration is Linux-only. Landin has no conditional import, so
`platform/posix` imports this module on every system it serves, and the
module's scope is theirs: Linux, Darwin and FreeBSD. On Darwin and
FreeBSD it declares nothing.

| Call | What it does |
|---|---|
| `linux.system_call` | The raw route to every Linux call: six `i64` arguments, unused ones zero, and the kernel's result. |
| the typed wrappers | The calls the library makes, listed below. |
| `_landin_start` | Where a static executable starts. |
| `adopt_start` | Take the tables from a C runtime's `main`, under `--link=libc`. |
| `environment`, `auxiliary` | What the entry found. |
| `level`, `read_cpu_words`, `missing_feature` | The CPU feature check. |

### Calls

- Each call is one assembly block on x86-64, arm64 and RV64.
- A failure comes back in its result as minus the errno; there is no
  errno cell.
- `platform/linux/numbers` names each call's number for `system_call`,
  and the wrappers' numbers come from the same generated tables.
- The `*at` calls take `at_fdcwd` for a path relative to the working
  directory.
- `statx`'s `file_status` is the kernel's one record on every
  architecture, and `statx_basic_stats` and `at_empty_path` ask `statx`
  for every field of an open file.
- `ppoll` is the poll call every architecture has.

The typed wrappers are the calls the library makes:

| Area | Wrappers |
|---|---|
| files and directories | `getdents64`, `mkdirat`, `unlinkat`, `pread64`, `pwrite64`, `ftruncate`, `fsync`, `fdatasync`, `getcwd`, `renameat2` (every architecture's rename), `linkat`, `symlinkat`, `readlinkat`, `fchmodat`, `fchmod`, `fchownat`, `fchown`, `utimensat` (whose path may be `no_path`), `flock` |
| descriptors | `ppoll`, `pipe2`, `dup3`, `fcntl`, `close_range`, `ioctl` |
| events | `epoll_create1`, `epoll_ctl`, `epoll_pwait` (every architecture's epoll wait), `signalfd4` and `rt_sigprocmask` |
| processes | `fork` (a `clone` with SIGCHLD and nothing shared), `execve`, `wait4`, `rt_sigaction` and the four ID calls |
| time and randomness | `clock_gettime`, `clock_nanosleep`, `getrandom` |
| sockets | the socket calls from `socket` to `getpeername`, with `accept4`, `sendto` and `recvfrom` standing for the calls arm64 and x86-64 lack |

`rt_sigaction` takes the kernel's `signal_action`, which RV64 lays out
without a restorer.

### Events

epoll waits until any of many descriptors is ready, and a signalfd reads
signals as records from a descriptor epoll can watch:

| Name | What it is |
|---|---|
| `epoll_record` | `struct epoll_event`: the events and a 64-bit word handed back with each report. Twelve bytes and packed on x86-64, as the kernel packs it there alone; sixteen on arm64 and RV64. |
| `epollin`, `epollout`, `epollpri`, `epollrdhup`, `epollerr`, `epollhup` | Events; the last two are reported whether asked or not. |
| `epolloneshot`, `epollet` | One report until asked again; a change of readiness rather than readiness. |
| `epoll_ctl_add`, `epoll_ctl_mod`, `epoll_ctl_del` | `epoll_ctl`'s operations. |
| `signalfd_record` | `struct signalfd_siginfo`, 128 bytes on every architecture: the signal, its sender and its code. |
| `signal_bit`, `sig_block`, `sig_unblock`, `sig_setmask` | A signal's bit in the kernel's eight-byte mask, and `rt_sigprocmask`'s operations. |
| `sighup`, `sigint`, `sigusr1`, `sigusr2`, `sigterm` | The signals, numbered alike on all three architectures. |
| `epoll_cloexec`, `sfd_cloexec`, `sfd_nonblock`, `o_nonblock`, `sock_nonblock`, `f_getfl`, `f_setfl` | The flags. |

A signalfd reads only pending signals, so the signals it reads are blocked
with `rt_sigprocmask` first. The mask is the thread's, and a child and a
program it executes keep it. There is no eventfd or timerfd: a loop sleeps
in its wait's time limit and nothing else wakes it (D480).

A terminal is the kernel's own `terminal_record`, `struct termios`,
smaller than the C library's. `ioctl` reads and sets it with `tcgets`,
`tcsets`, `tcsetsw` and `tcsetsf`. Its mode bits, `vmin` and `vtime`,
`window_record`, `tiocgwinsz`, `tiocswinsz` and the pseudo-terminal
requests `tiocsptlck`, `tiocgptpeer` and `tiocgptn` are the generic
architecture's, which x86-64, arm64 and RV64 share.

`lock_record` is the kernel's `struct flock` on a 64-bit architecture.

No routine but `_landin_start` and `_landin_start_main` is a global symbol,
so none of them replaces the C library's function of the same
name under `--link=libc`.

### The static entry

`_landin_start` reads `argc`, `argv`, the environment and the auxiliary
vector from the initial stack, and calls `main` as C's runtime would. No
C library initialisation runs and there is no thread-local storage.
`environment` and `auxiliary` report what that entry found.

Before `main` it holds the processor to the executable's CPU feature
level, as a loader holds an x86-64 executable to its ISA note:

| Architecture | Checked with |
|---|---|
| x86-64 | `cpuid` and the operating system's enabled state |
| arm64 | AT_HWCAP |
| RV64 | `riscv_hwprobe` |

A processor without a feature of the level ends the process with status
127 and one line on standard error naming the level and the missing
feature. The baseline checks nothing. `level`, `read_cpu_words` and
`missing_feature` expose the check.

### Started by the C runtime

When the C runtime started the program instead, under `--link=libc`,
`adopt_start` takes the environment and the auxiliary vector from the
`argc`, `argv` and `envp` C's `main` was given, which `platform/posix`'s
argument initializer passes it.

It takes them only when they are laid out as the kernel lays out the
initial stack:

- `argv` above the calling frame;
- `envp` right after `argv`'s null;
- every string above the tables;
- a vector ending in AT_NULL within 64 entries and before the lowest
  string;
- AT_PAGESZ a power of two of at least 4096;
- AT_RANDOM's bytes between the vector and the strings.

Nothing above the lowest string is read. Tables a C `main` built itself,
or C's `environ` after it changed, are not taken. Then `environment` and
`auxiliary` find nothing, and `page_size` is 4096, as before.

[Executable example](../compiler/tests/fixtures/runtime/linux-system-calls/main.ldn)

## platform/linux/numbers

Every Linux system call's number on x86-64, arm64 and RV64, generated from a pinned kernel release.

Each number is its call's name in the kernel's table followed by
`_number`, `numbers.getpid_number` for one, so no number can take a
reserved word's spelling. Give it to `linux.system_call`. A call the
running kernel lacks returns minus ENOSYS.

The numbers are the kernel's own. `scripts/linux_syscalls.py` reads them
from each architecture's table, with the ABIs that architecture's 64-bit
build selects, x32's excluded. The file's header names the release and
its SHA-256, and nothing in it is written by hand.

A new typed wrapper in `platform/linux` needs no download:

- `scripts/linux_syscalls.py` with no release named holds this file to
  being its own rendering, and writes the wrappers' numbers from it;
- `--check` says whether they are current;
- the release is needed only to change the pin.

It is a module of its own, apart from `platform/linux`, so that a program
making no raw call does not compile a thousand declarations. Its scope is
`platform/linux`'s, and on Darwin and FreeBSD it declares nothing.

[Executable example](../compiler/tests/fixtures/runtime/linux-system-calls/main.ldn)

## platform/linux/vdso

The vDSO, the small shared object Linux maps into every process, and the functions found in it, raw.

It is a submodule of `platform/linux`, so a program that never reads a
clock this way does not carry it. It declares nothing on Darwin and
FreeBSD.

The kernel's vDSO is found through the auxiliary vector's
AT_SYSINFO_EHDR.

| Call | What it does |
|---|---|
| `vdso.kernel_image` | The vDSO's bytes as far as its first load segment reaches: the image the kernel mapped. |
| `vdso.find` | Find a global or weak function by name and version in any image of a 64-bit little-endian ELF object, through its program headers, dynamic table, DT_HASH or DT_GNU_HASH, symbols and version definitions. |
| `vdso.symbol` | The function's address. |
| `vdso.clock_symbol`, `vdso.clock_version` | The name and version of its `clock_gettime`. |
| `vdso.clock_gettime` | That function's C type. |

| Architecture | `clock_gettime` in the vDSO |
|---|---|
| x86-64 | `__vdso_clock_gettime` of `LINUX_2.6` |
| arm64 | `__kernel_clock_gettime` of `LINUX_2.6.39` |
| RV64 | `__vdso_clock_gettime` of `LINUX_4.15` |

Every offset is held to lie within the image before a byte is read, so a
malformed, truncated or foreign image finds nothing and never traps.
A copy of the real one, damaged byte by byte, shows it.

The parser has a size. On Linux x86-64 its routines are 9.5 KB of a
static program at `--optimize size` and 12.1 KB at `speed`. Reading a
clock through `platform/posix` brings them with the clock path, the errno
table and the auxiliary-vector lookup, and grows the program's text by
16.7 KB and 19.9 KB, against 5.9 KB for a program that reads none.

A size-bound Linux program
that needs a clock and not that speed can call `linux.clock_gettime`, the
system call, itself, and carry none of it.

[Executable example](../compiler/tests/fixtures/runtime/linux-vdso/main.ldn)

## platform/kqueue

kqueue, the event interface Darwin and FreeBSD share, through their C
libraries, raw: a failure is -1 with the reason in `libc.errno_cell`.

Every declaration is Darwin's and FreeBSD's. The module's scope is the
hosted POSIX systems, as `platform/linux`'s is, so a provider written once
imports both, and on Linux it declares nothing (D481).

| Name | What it is |
|---|---|
| `kqueue` | Make a queue. It is not inherited by a child `fork` makes; set `libc.fd_cloexec` with `libc.fcntl` so a program executed does not keep it. |
| `kevent` | Make the changes given, then wait for events or a `libc.timespec` limit; `none_given` for no changes, no room or no limit. A change that fails comes back as an event with `ev_error` and the errno in its datum. |
| `change` | A change record: an identifier, a filter, flags, filter flags and a datum. |
| `event_record` | `struct kevent`: what is watched, the filter, the flags, the filter's flags, its datum and a word handed back with each event. |
| `evfilt_read`, `evfilt_write`, `evfilt_signal`, `evfilt_proc`, `evfilt_timer` | Filters: readiness, a signal, a process's end with `note_exit`, a timer. |
| `ev_add`, `ev_delete`, `ev_enable`, `ev_disable`, `ev_oneshot`, `ev_clear` | Change flags. |
| `ev_eof`, `ev_error` | Reported flags. |
| `note_seconds`, `note_useconds`, `note_nseconds`, and FreeBSD's `note_mseconds` | A timer's unit; with none it is milliseconds. |

A signal the queue watches is recorded even when it is ignored or blocked,
and is still delivered as its disposition says, so a program ignores or
blocks it.

| Fact | Darwin | FreeBSD |
|---|---|---|
| `event_record` | 32 bytes | 64 bytes, with four extension words |
| `note_useconds`, `note_nseconds` | 2, 4 | 4, 8 |

[Executable example](../compiler/tests/fixtures/runtime/kqueue-events/main.ldn)

## platform/c

C scalar spellings for the target's C ABI, on every target whose C data model is LP64.

LP64 is a data model, not an architecture: C `int` is 32 bits while
`long` and pointers are 64, as on every 64-bit Unix. Windows' LLP64 keeps
`long` at 32 bits, and Cortex-M's ILP32 makes all three 32 bits; neither
is admitted here.

Within LP64 the C ABI depends on the operating system as well as the
architecture, so the compiler names it with one fact per ABI rather than
reading it from `compiler.arch` or the pointer width:

| Target | ABI fact | Plain `char` |
|---|---|---|
| `linux-x86-64`, `freebsd-x86-64` | `compiler.c_sysv_lp64`: the System V AMD64 ABI | `i8` |
| `darwin-arm64` | `compiler.c_darwin_lp64`: Apple's arm64 variant of AAPCS64 | `i8` |
| `linux-arm64`, `freebsd-arm64` | `compiler.c_aapcs64_lp64`: the standard AAPCS64 | `u8` |
| `linux-rv64` | `compiler.c_riscv_lp64d`: RISC-V LP64D, LP64 with double-precision float registers | `u8` |

Darwin and Linux share `compiler.arch == arm64` and still disagree on
`char`, which is why the fact names the ABI.

Every other alias is the same on all four:

| Alias | Is |
|---|---|
| `c_int` | `i32` |
| `c_long`, `c_longlong` | `i64` |
| `c_size` | `usize` |

The aliases keep ordinary Landin scalar identity; `c_char` is a numeric
byte and never a Unicode scalar. Cortex-M C signatures are not admitted
by this module.

[Executable example](../compiler/tests/fixtures/runtime/r440-c-aliases/main.ldn)

## platform/cortex_m

M-profile interrupt masking, waiting and memory barriers.

Save the mask from `disable_interrupts` and restore it, including on
early returns. NMI and HardFault are not masked.

Waiting can wake spuriously. Barriers do not prove completion of a device
protocol or supply a DMA lifetime discipline.

[Executable example](../environments/cortex-m/probes/core-cpu.ldn)
