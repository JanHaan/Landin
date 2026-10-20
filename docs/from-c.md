# Landin for C programmers

This page has two halves: first what to write instead of C's habits, then
a lookup of the Landin form of each C habit.

A C programmer reaches for the same few things first: a header, a `#define`,
`malloc`, `printf`, `errno`, an `exit`. This page gives the Landin form of
each, and says plainly where Landin has no answer yet and what to write
until it does. It assumes you write C and have read
[the first program](../README.md#your-first-program); [the tour](../tour.md)
teaches the language itself.

Every Landin block on this page is a file of one module that the test
program compiles, so a block may use names another block declares.

In the lookup, each entry gives the C form, the Landin form and, where
Landin differs on purpose, the reason. Where Landin has no form yet, the
entry says what to write today, and
[What has no answer yet](#what-has-no-answer-yet) lists those gaps
together.

## Write Landin, not C in Landin

C makes you encode things the compiler cannot see: an out pointer for a
second result, `-1` for "not found", a `typedef` that mixes freely with its
base, a flag variable to escape two loops. Landin has a direct form for
each. The compiler checks the first five; the last, passing capabilities,
is a convention it does not check. Each entry points to the tour entry that
explains it, and [the tour](../tour.md) is where the rest of them are.

### Several results, not out parameters

```c
void split_seconds(unsigned total, unsigned *minutes, unsigned *seconds);
```

```landin
--- A duration split into minutes and the seconds left over.
split_seconds: (total: u32) -> (minutes: u32, seconds: u32) =
    minutes = total / 60
    seconds = total % 60
end split_seconds

minutes_only: (total: u32) -> (whole_minutes: u32) =
    (minutes, _) := split_seconds(total)
    whole_minutes = minutes
end minutes_only
```

A routine returns as many named results as it needs, and the compiler checks
that each is set on every path [0920] [0930]. The caller takes them apart by
name and ignores the rest with `_` [0990]. Nothing is passed by address, so
nothing can be left unwritten.

### Failures, not sentinel values

```c
int index_of(const unsigned *items, size_t n, unsigned wanted); /* -1: absent */
```

```landin
not_present: atom

--- Where `wanted` first appears in `items`.
index_of: (items: []u32, wanted: u32) -> (index: usize) ! not_present =
    for item, position in items do
        if item == wanted then
            index = position
            return
        end if
    complete
        fail not_present
    end for
end index_of
```

"Not found" is a failure the signature declares, `! not_present`, not a
value of the result's own type that a caller can forget to test [0940]. A
`for` loop's `complete` block runs only when the loop ran out without a
`break` or `return` [1170]. The caller writes `try`, a fallback such as
`else 0`, or a handler; ignoring it is an error.

### Slices, not a pointer and a length

```c
uint8_t byte_sum(const uint8_t *bytes, size_t n);
```

```landin
--- The byte sum of a block, wrapping on purpose.
byte_sum: (bytes: []u8) -> (sum: u8) =
    sum = 0
    for byte in bytes do
        sum +%= byte
    end for
end byte_sum

header_sum: (packet: []u8) -> (sum: u8) =
    sum = byte_sum(packet[0..<4]) -- traps if the packet is shorter
end header_sum
```

A slice is a pointer and its length in one value, and every index is
checked against it [0570]. `packet[0..<4]` is a view of the first four bytes,
not a copy. Overflow traps unless you ask for wrapping with `+%` [0300], so
a checksum says that it wraps and a counter that overflows is caught.

### Types that mean something, not `typedef`

```c
typedef int32_t celsius;      /* any int32_t fits, any int32_t mixes */
typedef uint8_t fill_level;   /* 0 to 100, by convention */
```

```landin
celsius: type = distinct i32
fahrenheit: type = distinct i32
fill_level: type = u8 range 0..100

to_fahrenheit: (c: celsius) -> (f: fahrenheit) =
    f = fahrenheit(i32(c) * 9 / 5 + 32)
end to_fahrenheit

--- How full a tank is, refused or trapped outside 0 to 100.
tank_level: (litres: u32, capacity: u32) -> (level: fill_level) =
    level = u8(litres * 100 / capacity)
end tank_level
```

A `distinct` type has its base's representation but not its arithmetic,
so a `celsius` never meets a `fahrenheit` or a bare `i32` without a
conversion you can see [0650]. Equality, ordering and, for an unsigned
base, the bit operations do carry over. A range subtype checks its values
where they enter: a value outside 0 to 100 is refused when the compiler
knows it and traps when it does not [0660]. Neither costs anything at run
time beyond that check.

### Labelled loops, not flags and `goto`

```c
int found = 0;
for (int r = 0; r < 4 && !found; r++)
    for (int c = 0; c < 4; c++)
        if (grid[r][c] == 0) { found = 1; break; }
```

```landin
--- Whether any row of the grid holds a zero.
has_zero: (grid: [4][4]u8) -> (found: bool) =
    found = false
    rows: for row in grid do
        for cell in row do
            if cell == 0 then
                found = true
                break rows
            end if
        end for
    end rows
end has_zero
```

A loop can carry a label, and `break` and `continue` name the loop they
leave [1180]. A `for` walks an array, a slice or a range directly, and
gives the position as well when you ask, `for item, position in items`
[1150].

### Passed capabilities, not global I/O

```c
size_t count_lines(FILE *source);   /* and anything else can call fopen */
```

```landin
import core/io

--- Count the lines a reader gives: a file, a pipe or a test's fake.
count_lines: (provider: type is io.reader, host: provider, source: io.file)
             -> (lines: usize) ! io.io_failed =
    lines = 0
    mut block: [512]u8 = zeroed
    loop do
        count := try io.read(host, source, block)
        break when count == 0
        for byte in block[0..<count] do
            if byte == u8('\n') then lines += 1 end if
        end for
    end loop
end count_lines
```

Pass the provider in rather than making one where you need it. Then the
signature says what a routine touches, and a test can hand it a fake. This
is a convention, not a rule: any hosted routine may call `system.new()`
itself, and the compiler does not stop it [1680]. Create the provider in
`main` and pass it down [1660].

The same `count_lines` reads a file, standard input, a pipe, or a fake in
a test, with no mocking framework. To test a routine over files, use
`fake.volume` from `core/io/fake`; `io.memory_over` makes the memory
world, firmware's own world rather than a fake, for running a whole
program over memory.

## Files and the preprocessor

### `#include` and headers

```c
#include "paths.h"
```

```landin
import core/text (host_over, host_string)

--- Where the tool reads its settings.
public config_path: () -> (path: host_string) =
    path = host_over("/etc/tool.conf")
end config_path
```

There are no header files. A module is a directory, every file in it sees
the others, and `public` is what another module may name [1410]. A plain
`import core/io` binds `io`, `as` renames it [1430], and a list in
parentheses, `(get, post)`, selects names [1440]. `refine` never reads a C header:
`bindings/generate.py` asks Clang for one and writes Landin declarations
from it [1580].

### `#define` for a constant

```c
#define BUFFER_SIZE 4096
```

```landin
--- The size of every read buffer.
buffer_size: usize = 4096
```

A module value known when compiling is the constant. It has a type, and
nothing runs before `main` to compute it [1460]. A macro that computes is a
function: Landin has no macros and no compile-time execution [1540].

### `#ifdef` and `-D`

```c
#ifdef __APPLE__
#define LIBRARY_SUFFIX ".dylib"
#else
#define LIBRARY_SUFFIX ".so"
#endif
```

```landin
-- The suffix this system gives a shared library.
fixed if compiler.os == darwin then
    library_suffix: utf8 = ".dylib"
else
    library_suffix: utf8 = ".so"
end if

--- Whether the tool says what it does: `--option=verbose=true`.
option verbose: bool = false

fixed if verbose then
    log_capacity: usize = 256
else
    log_capacity: usize = 0
end if
```

`fixed if` chooses declarations, never statements, and reads only the
compiler's facts and the program's declared options [1500]. An option is
declared once with a type and a default, and `refine compile
--option=verbose=true` sets it; a misspelt one is an error rather than a
silent false [1530].

### `_Static_assert`

```c
_Static_assert(sizeof(size_t) == 8, "64-bit only");
_Static_assert(sizeof(struct header) == 8 && offsetof(struct header, id) == 4,
               "C's layout");
```

```landin
-- This module is written for a 64-bit target.
compiler.assert(sizeof usize == 8)

-- The record C reads has C's size and the offset C gives its id.
compiler.assert(sizeof header == 8 and offsetof header.id == 4)
```

The condition is a closed fold over literals, the compiler's facts and the
sizes, alignments and field offsets of types [1510]. An assertion that
measures a declared type is checked once the type is laid out for the
selected target; it runs no code. A `fixed if` condition measures
scalar types only, because the arms it selects may declare the type.

## Types and memory

### `struct` layout

```c
struct header { uint8_t kind; uint16_t length; uint32_t id; };
```

```landin
--- A record C reads and writes, field for field.
header: type = layout(c) struct
    kind: u8
    length: u16
    id: u32
end header

header_size: usize = sizeof header -- 8: one byte of padding after kind
```

Every struct keeps its fields in the order they are written, with natural
alignment, so a hexdump matches the source [0750]. `layout(c)` applies the
selected target's C rules and is what may cross to C; `layout(optimal)`
lets the compiler reorder for a smaller size [0750]. A field holds the
target's byte order, and data in another order is converted with shifts
where it crosses [0750].

### `__attribute__((packed))`

```c
struct __attribute__((packed)) wire { uint8_t kind; uint32_t id; };
```

```landin
--- A record packed to the byte: `id` begins at 1, and the record is 5 bytes.
wire: type = layout(c, packed) struct
    kind: u8
    id: u32
end wire

--- A field is read by copy, wherever the record lies.
wire_id: (packet: ptr wire) -> (id: u32) =
    id = packet.val.id
end wire_id
```

`layout(c, packed)` places every field at alignment one with no padding,
as the attribute does [0750]. A field may therefore sit at any address, so
it has no address of its own: `addr packet.val.id`, an `inout` argument and
a slice of a field are refused, and a field is read and written by copy.
Where a target needs aligned loads, the compiler moves such a field a byte at
a time. C takes a packed record through a pointer and never by value
[1580]. `layout(packed)` is a different thing, a hardware register's bits at
stated positions [0730]. `bindings/generate.py` writes this form for a
header's packed struct, and a typed pointer wherever the header passes one.

### `offsetof`

```c
size_t at = offsetof(struct linux_dirent64, d_name);
```

```landin
--- Linux's `struct linux_dirent64`; its name is a flexible array member.
directory_record: type = layout(c) struct
    inode: u64
    offset: i64
    length: u16
    kind: u8
    name: [0]u8
end directory_record

--- Where the name begins: 19, the byte after `kind`.
name_offset: usize = offsetof directory_record.name
```

`offsetof t.field` is a `usize`, measured for the selected target, and the
selection may continue through nested structs, as in `offsetof frame.head.id`
[0370]. Like `lenof`, the word is a name everywhere else. Do not compute an
offset by hand or from `sizeof`, which counts the padding after the last
field: `sizeof directory_record` is 24, and the name begins at 19.

### Flexible array members

```c
struct linux_dirent64 { ino64_t d_ino; off64_t d_off;
                        unsigned short d_reclen; unsigned char d_type;
                        char d_name[]; };
```

```landin
import core/mem

--- The name in the record at `at` of what `getdents64` read: the bytes from
--- the name's offset up to the NUL that ends them. Every hosted target is
--- little-endian, so the length's low byte comes first.
record_name: (buffer: []u8, at: usize) -> (name: []u8 from buffer) =
    length_at := at + offsetof directory_record.length
    length := usize(buffer[length_at]) | usize(buffer[length_at + 1]) << 8
    rest := buffer[at + name_offset..<at + length]
    name = rest[0..<mem.find(rest, 0)]
end record_name
```

A C record's last field may be `[0]T`, C's flexible array member: it takes
its element's alignment, so the record's size and the member's offset are
C's [0750]. Its elements are not the record's own storage. Take them as a
slice of the bytes the call filled, from `offsetof` to the record's length,
which keeps their length and their origin. Because the elements would
overlap whatever follows, such a record is no array element and no field of
another C record, and C takes it through a pointer [1580].
`bindings/generate.py` writes a header's flexible member as this last
`[0]T` field.

### `union`

```c
struct token { uint32_t offset; enum { NUMBER, WORD, END } tag;
               union { int64_t value; uint32_t letters; } as; };
```

```landin
--- A token and what it holds; the variant part is the tag and the union.
token: type = struct
    offset: u32
    kind: variant
        number: (value: i64) |
        word: (letters: u32) |
        end_of_input
    end kind
end token

token_width: (t: token) -> (width: u32) =
    match t.kind
        number(value): width = if value < 0 then 2 else 1 end if
        word(letters): width = letters
        end_of_input: width = 0
    end match
end token_width
```

A union whose tag says which member holds is a struct with a variant part
[0680], and a `match` on it names every case [1210]. Landin has no untagged
union. Reading one type's bits as another's goes through an address:

```landin
--- The bits of a float, which C reads through a union or `memcpy`.
float_bits: (value: f32) -> (bits: u32) =
    view: ptr u32 = ptr(usize(addr value))
    bits = view.val
end float_bits
```

A pointer made from an integer borrows nothing, and no lifetime check
follows it [0470].

### `NULL`

```c
uint32_t *first_entry(uint32_t *table, size_t n);  /* NULL when n is 0 */
```

```landin
no_entry: atom

--- A pointer that may be absent.
maybe_entry: type = no_entry | ptr mut u32

first_entry: (table: []mut u32) -> (found: maybe_entry from table) =
    found = no_entry
    if lenof table > 0 then found = addr table[0] end if
end first_entry

bump_first: (table: []mut u32) -> none =
    match first_entry(table)
        no_entry: return
        ptr (entry): entry.val += 1
    end match
end bump_first
```

There is no null pointer. A pointer that may be absent is a union of an
atom and the pointer, which the compiler stores as a plain pointer with
zero for the atom [0480]. Using it is a `match` that names both cases, so a
missing check is a compile error rather than a crash. `ptr(0)` is refused,
and a zero converted to a pointer at run time traps.

### `void *`

```c
void *largest(void *items, size_t n, size_t size,
              int (*less)(const void *, const void *));
```

```landin
import core/cmp

--- The largest of the items, for any type with an ordering.
largest: (t: type is cmp.ordered, items: []t) -> (best: t) =
    best = items[0]
    for item in items do
        if t.less(best, item) then best = item end if
    end for
end largest

highest_reading: (readings: []u32) -> (high: u32) =
    high = largest(readings)
end highest_reading
```

A routine that works for any type takes the type as a parameter and its
operations as a concept, and the compiler checks every call [1290]. Values
of different types behind one interface are `any C`, dispatched through a
table at run time [1370]. Raw memory is `ptr mut u8`, which is what an
allocator returns and what stands for `void *` at the C boundary.

### Pointer arithmetic

```c
uint32_t value = table[index];  /* table came from C */
```

```landin
--- The entry at `index` of a table C handed over as a bare pointer.
entry_at: (table: ptr u32, index: usize) -> (value: u32) =
    entry: ptr u32 = ptr(usize(table) + index * sizeof u32)
    value = entry.val
end entry_at
```

Everyday Landin indexes a slice, which carries its length and is checked
[0570]. A pointer has no arithmetic: compute the address as an integer and
convert it back [0470]. The result borrows nothing, so no lifetime check
follows it. The register in `ROADMAP.md` holds a pointer offset that keeps
its base's origin as open work.

### Casts

```c
uint8_t low = (uint8_t)measured;
double ratio = (double)total / 1000.0;
uintptr_t address = (uintptr_t)cell;
```

```landin
narrowing: (measured: u32, total: i64) -> (low: u8, ratio: f64) =
    low = u8(measured & 0xFF) -- the low byte, which the mask says is wanted
    ratio = f64(total) / 1000.0
end narrowing

checked: (measured: u32) -> (small: u8) =
    small = u8(measured) -- traps when measured is above 255
end checked

as_address: (cell: ptr mut u32) -> (address: usize) =
    address = usize(cell) -- the integer has no origin from here on
end as_address
```

A conversion is the type applied to the value, and it converts the value,
never the bits: a value that does not fit traps, and one known when
compiling is a compile error [0310]. To keep the low byte, a mask says
so. A pointer becomes an integer and back the same way, and the integer
carries no origin [0470]. Nothing converts implicitly.

### `char *` strings

```c
const char *greeting = "héllo";
```

```landin
greeting: utf8 = "héllo"
greeting_bytes: []u8 = "héllo" -- six bytes; the NUL is not counted

spaces_in: (line: utf8) -> (count: u32) =
    count = 0
    for character in line do
        if character == ' ' then inc count end if
    end for
end spaces_in
```

Text is a view with its length, never a pointer to a NUL: `utf8` for
validated text, `[]u8` for bytes, and `cstring` only for C [0260], [0600].
A literal still ends in a NUL nobody counts, so it passes to C for nothing.
Traversing `utf8` gives each character as a `u32`, which is what `' '` is
[0250].

### `volatile`

```c
*(volatile uint32_t *)0x40021018 |= 1;
```

```landin
--- Turn on a port's clock: one read and one write of the device register.
enable_port_clock: () -> none =
    enable: ptr mut u32 = ptr(0x4002_1018)
    value: u32 = compiler.volatile_load(enable)
    compiler.volatile_store(enable, value | 1)
end enable_port_clock
```

Volatility belongs to the access, not to the pointer's type: each
`compiler.volatile_load` and `compiler.volatile_store` is exactly one access
[0850]. A device register with fields is a register type [0730].

### `malloc` and `free`

```c
struct point *cell = malloc(sizeof *cell);
if (cell == NULL) return -1;
free(cell);
```

```landin
import core/arena
import core/mem
import hosted/heap

point: type = struct
    x: i32
    y: i32
end point

--- Allocate a point, move it and free it, through the caller's allocator.
moved_point: (provider: type is mem.allocator, memory: provider, start: point)
             -> (x: i32) ! mem.out_of_memory =
    cell := try mem.new(memory, start)
    defer mem.delete(memory, cell)
    cell.val.x += 1
    x = cell.val.x
end moved_point

from_heap_or_arena: () -> (sum: i32) ! mem.out_of_memory =
    origin: point = (x: 0, y: 0)
    sum = try moved_point(heap.new(), origin)
    mut backing: [64]u8 = zeroed
    mut state: arena.space = zeroed
    scratch := arena.over_unchecked(state, addr backing[0], 64)
    sum += try moved_point(scratch, origin)
end from_heap_or_arena
```

There is no ambient heap. An allocator is a capability passed to whatever
allocates, so the same code runs on the heap, in an arena over a buffer, or
under a failure injector in a test [1360]. A failed allocation is
`out_of_memory`, which the caller must handle. Nothing is freed for you:
there is no garbage collector and no destructor, and `defer` is where a
free goes [1100]. An arena gives everything back at once [0820].

## Control and errors

### Operators

```c
while (i < n && line[i] != ' ') i++;
h = h * 31 + c;
```

```landin
--- Where the word that starts at `start` ends.
word_end: (line: []u8, start: usize) -> (i: usize) =
    i = start
    while i < lenof line and line[i] <> u8(' ') do
        inc i
    end while
end word_end

--- A hash that wraps on purpose, which the operators say.
hash_bytes: (bytes: []u8) -> (h: u32) =
    h = 0
    for byte in bytes do
        h = h *% 31 +% u32(byte)
    end for
end hash_bytes
```

Inequality is `<>` and the logical operators are `and`, `or` and `not`
[0340], [0350]. There is `inc` and no `++` [0400]. Overflow traps rather
than wrapping or being undefined; `+%`, `-%` and `*%` wrap, and say so
[0300]. The bitwise operators bind tighter than comparison, unlike C, so
`flags & mask == 0` means what it looks like [0330].

### `switch`

```c
switch (light) { case RED: return 30; case AMBER: return 3; default: return 0; }
```

```landin
red, amber, green: atom

signal: type = red | amber | green

wait_seconds: (light: signal) -> (seconds: u32) =
    match light
        red: seconds = 30
        amber: seconds = 3
        green: seconds = 0
    end match
end wait_seconds

digit_name: (digit: u32) -> (name: utf8) =
    if digit == 0 then
        name = "zero"
    elsif digit == 1 then
        name = "one"
    else
        name = "many"
    end if
end digit_name
```

A `match` names atoms or variant cases, has no fallthrough and no `break`,
and a case left out is a compile error [1210]. A number has no case to name,
so a `switch` over an integer is an `if` chain. Several labels may
share one arm, `north, south:`, which is what C's stacked `case` labels
are, and `_` covers the rest.

### `goto` cleanup

```c
    if ((in = open(src, O_RDONLY)) < 0) goto out;
    if ((to = creat(dst, 0644)) < 0) goto close_in;
    ...
    close(to);
close_in:
    close(in);
out:
    return result;
```

```landin
import core/io
import core/text
import hosted/system

--- Copy the first block of one file into another, closing both on every way
--- out.
copy_first_block: (host: system.host, source_path: text.host_string,
                   target_path: text.host_string)
                  -> none ! io.not_found | io.no_access | io.io_failed =
    source := try io.open_read(host, source_path)
    defer io.close(host, source) else none
    target := try io.open_write(host, target_path)
    defer io.close(host, target) else none
    mut block: [512]u8 = zeroed
    count := try io.read(host, source, block)
    try io.write(host, target, block[0..<count])
end copy_first_block
```

`defer` runs when its block is left, by falling through, returning or
failing, in reverse order, and only once control has reached it [1100].
The ladder of labels falls out of that order: the first failure closes
nothing and the second closes one [1200]. `undo` runs only when the block
fails [1110]. A trap is a stop and runs neither.

### `errno`

```c
int fd = open("settings.conf", O_RDONLY);
if (fd < 0) { if (errno == ENOENT) return 0; return -1; }
```

```landin
import core/io
import core/text
import hosted/system

--- Whether the settings file is there; any other failure is the caller's.
settings_present: (host: system.host)
                  -> (present: bool) ! io.no_access | io.io_failed =
    present = false
    path := text.host_over("settings.conf")
    opened := io.open_read(host, path) else (problem)
        match problem
            io.not_found: return
            io.no_access: fail io.no_access
            io.io_failed: fail io.io_failed
        end match
    end
    io.close(host, opened) else none
    present = true
end settings_present
```

A routine that can fail declares its failures as a set of atoms after `!`,
and a caller handles them with `else` or passes them on with `try` [0940],
[1030]. Nothing is set behind your back and nothing can be forgotten: a
call that can fail and is neither handled nor passed on is a compile error.
Only what cannot be foreseen is a failure; what can be checked is checked
first [0950]. The number is still there when a log wants it:
`system.last_errno(host)` gives the errno of the call that failed, and
`platform/posix` names every errno as an atom. For a person,
`failure.words(problem)` from `core/failure` turns a library failure into
a short phrase: it is Landin's `strerror`.

## The program and the system

### `main` and `exit`

```c
int main(int argc, char **argv) {
    if (argc < 2) { fputs("usage: tool FILE...\n", stderr); exit(2); }
    ...
    return 0;
}
```

```landin
import core/io
import hosted/system

public main: () -> (code: i32) =
    host := system.new()
    code = 2
    if io.argument_count(host) == 0 then
        io.write(host, io.err(host), "usage: tool FILE...\n") else none
        return
    end if
    print_arguments(host) else (problem)
        code = 1
        return
    end
    code = 0
end main
```

`main` returns the exit status, and an early `return` is how a program
leaves [1650]. Leaving through `main` runs every `defer` on the way out.
There are no destructors and no `atexit`, so a buffered writer's bytes are
written only by its flush. `posix.exit` ends the process at once, as C's
`_exit` does:

```landin
import platform/posix

--- Stop the program from wherever it is, with status 2.
give_up: () -> noreturn =
    posix.exit(2)
end give_up
```

Nothing after it runs, neither a `defer` nor a flush, so it suits only a
program with nothing left to clean up.

### `argc` and `argv`

```c
for (int i = 1; i < argc; i++) puts(argv[i]);
```

```landin
import core/io
import core/text
import hosted/system

--- Write each argument on a line of its own.
print_arguments: (host: system.host) -> none ! io.io_failed =
    for index in usize(0)..<io.argument_count(host) do
        argument := io.argument_at(host, index) else (problem)
            return
        end
        try io.write(host, io.out(host), text.host_bytes(argument))
        try io.write(host, io.out(host), "\n")
    end for
end print_arguments
```

The arguments belong to the hosted provider, which lends each as a host
string: the bytes the system gave, unconverted and not necessarily UTF-8
[1660]. The sequence starts after the program's name, at C's `argv[1]`.
`text.from_host` is the checked conversion to `utf8`.

### `getenv`

```c
const char *home = getenv("HOME");
if (home == NULL) home = "/";
```

```landin
import core/io
import core/text
import hosted/system

--- The home directory, or `/` when the environment names none.
home_directory: (host: system.host) -> (home: text.host_string from host) =
    home = io.variable_named(host, text.host_over("HOME")) else (problem)
        text.host_over("/")
    end
end home_directory
```

A missing variable is the failure `no_variable`, not a null pointer. The
environment is read-only: a program gives a child the environment it builds
rather than changing its own.

### `printf`

```c
printf("%s: %5u items\n", name, count);
```

```landin
import core/io
import core/text
import hosted/system

--- Write a name and a count, the count right-aligned in five columns.
report: (host: system.host, name: utf8, count: u32)
        -> none ! io.io_failed | text.no_space | text.invalid_format =
    mut storage: [128]u8 = zeroed
    mut line := text.over(storage)
    try text.format(line, "{}: ", [any(addr name)])
    start := text.length(line)
    try text.append_u32(line, count)
    try text.align_right(line, start, 5, u8(' '))
    try text.append(line, " items\n")
    try io.write(host, io.out(host), text.used(line))
end report
```

`text.format` fills each `{}` with the next value, into a buffer you
supply, and `io.write` writes it. Nothing runs at compile time, so the
template is checked against the values when it runs, and a mismatch is
`invalid_format` rather than undefined behaviour [1540]. Width, padding and
hexadecimal are the builder's typed calls, `align_right` and
`append_hex_u32` among them, rather than letters in the template;
[the library reference](library.md) lists them.

### Calling C, and linking it

```c
int port = atoi("8080");
```

```landin
import platform/c

--- C's `atoi`, from the C library.
extern(c) atoi: (s: cstring) -> (value: c.c_int)

default_port: () -> (port: i32) =
    port = atoi("8080") -- the literal carries its NUL
end default_port
```

`extern(c)` declares a C function, and `platform/c` names C's integer types
for the target [1580]. A Linux program is linked statically with no C
library unless it asks, so a program that calls one is compiled with
`refine compile --link=libc`, which links C's runtime and library; Darwin
and FreeBSD always have it. `linker.library("m")` names another library
beside the code that needs it [1590]. A C function `platform/libc` already
declares, `strlen` among them, is called as `libc.strlen` or declared with
exactly the same types. A pointer C may return as null is a pointer union,
and a function exported to C returns a status, since no Landin failure
crosses the boundary [1600].

## Where to go next

Read [the tour](../tour.md) from the top: it starts with a hello world and
takes an hour or two. These parts have the least in common with C:

| tour section | what it gives you |
| --- | --- |
| [Control flow](../tour.md#control-flow) | errors with `fail`, `try` and `else`, `defer` and `undo`, `match` |
| [Types you declare](../tour.md#types-you-declare) | atoms, variants, distinct and range types, register layouts |
| [Lifetime and escape](../tour.md#lifetime-and-escape) | how the compiler catches a pointer to a dead frame, without a borrow checker |
| [Concepts and generic code](../tour.md#concepts-and-generic-code) | one routine for every type, without `void *` or macros |
| [The toolchain, C, and the machine](../tour.md#the-toolchain-c-and-the-machine) | linking, C calls both ways, assembly and placement |

## What has no answer yet

| C habit | what to write today |
| --- | --- |
| pointer arithmetic that keeps the base's origin | the address as an integer; the result borrows nothing |

Open work belongs to `ROADMAP.md`, whose register says for each gap what
would close it and when it will be taken up.

## About this page

This page is derived and decides nothing. The tour explains the language
and `spec.md` decides it; a paragraph number in brackets, such as [0480],
says where. Every Landin block on the page is a file of
`compiler/tests/fixtures/positive/from-c`, and the files are one module:
the test program checks it, emits it and holds it to the layout
`refine fmt` gives, and `check.py` holds each block to its file byte for
byte.
