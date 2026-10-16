# Running examples

These are complete Landin programs that the bootstrap compiler accepts,
lowers, emits, links and runs today on Linux x86-64 and Darwin arm64. They are the same sources
the runtime suite executes. Each returns 42 only after checking its result,
except the Benchmark Game ports, which take their input as an argument or
on standard input as the Benchmark Game's own programs do, and the word
count and the line numberer, tools that read their standard input; those
return 0, and their fixtures hold the output they write.

The implemented hosted language includes aggregate parameters and results,
fixed arrays [0520], slices [0570], variants [0680], pattern matching [1210],
`inout` parameters [0900], loops and traversal [1130] [1140] [1150],
value-producing loop exits [1190], contextual text literals [0260],
floating-point arithmetic [0170] [0210], concepts with runtime dispatch
[1230] [1370], and allocators passed as capabilities [1360]. These examples
use iteration where the algorithm calls for it; merge sort keeps only its
natural divide-and-conquer recursion.

## Compile and run

With `refine` installed, as [the README](README.md#your-first-program)
describes, copy any program below into a `main.ldn` of its own and compile
it where it is. For FizzBuzz:

```sh
refine compile main.ldn -o fizzbuzz
./fizzbuzz
test $? -eq 42
```

FizzBuzz writes its conventional one hundred lines, and the next seven
programs print nothing. Status 42 means the checks in `main` passed, and any
other returned status makes the runtime fixture fail. The five Benchmark
Game programs write their official correctness output and return 0: the
fixture names the argument, or the standard input, the Benchmark Game
specifies for its correctness check, and holds the exact output. A
Benchmark Game program needs its argument, so FASTA's run is

```sh
refine compile main.ldn -o fasta
./fasta 1000
```

The word count prints the totals for whatever its standard input holds and
returns 0, and its fixture gives it an input of its own and holds the line it
prints; the line numberer does the same with the lines it numbers. The
directory listing builds a directory where it runs, prints its listing,
removes it and returns 42, the shell runner prints its report of a shell it
ran and returns 42, the echo prints what came back over loopback and
returns 42, and the tree copy prints a listing of what it copied and
returns 42. The gate checks all twelve output oracles and all nineteen
programs on each full gate run, on Linux x86-64 and on macOS arm64. `AGENTS.md` describes the verified explanatory-only reuse
exception. `refine` compiles for the host it runs on unless `--target` says otherwise.

## Sensors

This one is not a classic exercise; it shows the language's main ideas
working together in one short program. Two kinds of sensor conform to one
concept [1230] [1240] and share one slice as `any sensor` values [1370], so
each read is dispatched at runtime. `poll` is generic over its allocator
[1290] [1360]: `main` lends it an arena over a 256-byte stack buffer [0820],
and the list of readings grows there and nowhere else. A read can fail with a
declared atom [0940]; the poll skips the unplugged door, would stop at a
jammed sensor, and passes running out of memory on with `try` [0960]. The
three readings, 21, 2 and 19, sum to 42.

Fixture source: `compiler/tests/fixtures/runtime/sensors/main.ldn`.

```landin
--  Sensors of different kinds behind one concept, polled through `any`,
--  their readings kept in a list whose memory the caller lends.
import core/mem
import core/vec

offline, jammed: atom

sensor: type = concept (t: type)
    read: (self: ptr mut t) -> (value: i32) ! offline | jammed
end sensor

thermometer: type = struct
    celsius: i32
end thermometer

door: type = struct
    openings: i32
    wired: bool
end door

read_thermometer: (self: ptr mut thermometer)
                  -> (value: i32) ! offline | jammed =
    fail jammed when self.val.celsius < -40
    value = self.val.celsius
end read_thermometer

read_door: (self: ptr mut door) -> (value: i32) ! offline | jammed =
    fail offline when not self.val.wired
    inc self.val.openings
    value = self.val.openings
end read_door

thermometer is sensor (read: read_thermometer)
door is sensor (read: read_door)

--  Generic over where the memory comes from; the caller decides.
poll: (provider: type is mem.allocator, memory: provider,
       sensors: []mut any sensor)
      -> (readings: vec.list(i32)) ! mem.out_of_memory | jammed =
    readings = vec.new(item: i32)
    for device in sensors do
        --  An unplugged sensor is skipped; a jammed one stops the poll.
        value := device.read() else (why)
            fail jammed when why == jammed
            continue
        end
        try vec.push(readings, memory, value)
    end for
end poll

public main: () -> (code: i32) =
    mut bytes: [256]u8 = zeroed
    --  This local backing requires manual lifetime discipline for results.
    mut space: mem.arena_space = zeroed
    arena := mem.arena_over_unchecked(space, addr bytes[0], lenof bytes)

    mut kitchen: thermometer = (celsius: 21)
    mut hall: thermometer = (celsius: 19)
    mut front: door = (openings: 1, wired: true)
    mut cellar: door = (openings: 0, wired: false)
    mut sensors: [4]any sensor
    sensors[0] = any(addr kitchen)
    sensors[1] = any(addr front)
    sensors[2] = any(addr cellar)
    sensors[3] = any(addr hall)

    mut readings := poll(arena, sensors[0..<4]) else (problem)
        code = if problem == jammed then 2 else 1 end if
        return
    end
    defer vec.release(readings, arena)

    code = 0
    for value in vec.used(readings) do
        code += value
    end for
end main
```

## FizzBuzz

FizzBuzz is the familiar remainder-and-branching exercise from [Rosetta Code](https://rosettacode.org/wiki/FizzBuzz). The classifier remains a small pure function. A separate hosted presentation layer traverses one through 100, puts contextual text literals into a buffered writer from `core/io`, and appends the ordinary numbers to a `core/text` builder; the hundred lines leave in two writes rather than a hundred. The fixture checks both its exact output and its aggregate tally.

Fixture source: `compiler/tests/fixtures/runtime/fizzbuzz/main.ldn`.

```landin
--  The classifier stays independent of presentation; the hosted entry prints
--  the traditional lines and checks the complete tally for one through 100.
import core/io
import core/text
import hosted/io as hosted

fizz, buzz, fizz_buzz, number: atom
fizzbuzz_kind: type = fizz | buzz | fizz_buzz | number

counts: type = struct
    fizz_only: u32
    buzz_only: u32
    both: u32
    ordinary: u32
end counts

classify: (n: u32) -> (kind: fizzbuzz_kind) =
    if n % 15 == 0 then
        kind = fizz_buzz
    elsif n % 3 == 0 then
        kind = fizz
    elsif n % 5 == 0 then
        kind = buzz
    else
        kind = number
    end if
end classify

tally: (inout result: counts, kind: fizzbuzz_kind) -> none =
    match kind
        fizz: result.fizz_only += 1
        buzz: result.buzz_only += 1
        fizz_buzz: result.both += 1
        number: result.ordinary += 1
    end match
end tally

--  A number's line: its decimal digits and a newline, through a builder
--  over a few bytes of the caller's frame.
write_number: (inout out: io.buffered_writer(hosted.system), value: u32)
              -> none ! io.io_failed | text.no_space =
    mut room: [16]u8 = zeroed
    mut line := text.over(room)
    try text.append_u32(line, value)
    try text.append_byte(line, 10)
    try io.put(out, text.used(line))
end write_number

write_line: (inout out: io.buffered_writer(hosted.system),
             kind: fizzbuzz_kind, value: u32)
            -> none ! io.io_failed | text.no_space =
    match kind
        fizz: try io.put(out, "Fizz\n")
        buzz: try io.put(out, "Buzz\n")
        fizz_buzz: try io.put(out, "FizzBuzz\n")
        number: try write_number(out, value)
    end match
end write_line

run: (inout out: io.buffered_writer(hosted.system))
     -> (result: counts) ! io.io_failed | text.no_space =
    result = zeroed
    first: u32 = 1
    last: u32 = 100
    for value in first..last do
        kind: fizzbuzz_kind = classify(value)
        tally(result, kind)
        try write_line(out, kind, value)
    end for
    try io.flush(out)
end run

--  The lines gather in a buffer and are written when it fills and at the
--  end; a `defer` still flushes what is waiting on any other way out.
public main: () -> (code: i32) =
    host := hosted.host()
    mut storage: [256]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage[0..<256])
    defer io.flush(out) else (problem)
        _ = problem
    end
    result := run(out) else (problem)
        _ = problem
        code = 1
        return
    end

    if classify(1) == number
      and classify(3) == fizz
      and classify(5) == buzz
      and classify(15) == fizz_buzz
      and classify(30) == fizz_buzz
      and result.fizz_only == 27
      and result.buzz_only == 14
      and result.both == 6
      and result.ordinary == 53
    then
        code = 42
    else
        code = 1
    end if
end main
```

## Greatest common divisor

Euclid's algorithm is a compact conditional-loop example. Each iteration carries the useful state forward as the former divisor and its remainder. The checks include either zero position, a coprime pair, and the classic 1071/462 example from the [Rosetta Code task](https://rosettacode.org/wiki/Greatest_common_divisor).

Fixture source: `compiler/tests/fixtures/runtime/greatest-common-divisor/main.ldn`.

```landin
--  Euclid's algorithm repeatedly replaces a pair by the divisor and remainder
--  until that remainder reaches zero.
gcd: (a: u32, b: u32) -> (result: u32) =
    mut dividend: u32 = a
    mut divisor: u32 = b
    while divisor <> 0 do
        remainder: u32 = dividend % divisor
        dividend = divisor
        divisor = remainder
    end while
    result = dividend
end gcd

public main: () -> (code: i32) =
    if gcd(1071, 462) == 21
      and gcd(54, 24) == 6
      and gcd(42, 0) == 42
      and gcd(0, 42) == 42
      and gcd(37, 600) == 1
    then
        code = 42
    else
        code = 1
    end if
end main
```

## Insertion sort

Insertion sort grows a sorted prefix and moves an out-of-order value left through adjacent swaps. The public operation accepts caller-owned aggregate storage through `inout`; a range traversal and an inner unconditional loop work through its writable slice without hiding the input in module state.

Fixture source: `compiler/tests/fixtures/runtime/insertion-sort/main.ldn`.

```landin
--  The public operation accepts caller-owned storage through inout; its
--  writable slice lets the nested loops exchange adjacent values in place.
public insertion_sort: (inout values: [8]i32) -> none =
    view: []mut i32 = values[0..<lenof values]
    first_unsorted: usize = 1
    for index in first_unsorted..<lenof view do
        mut current: usize = index
        loop do
            break when current == 0
            previous: usize = current - 1
            break when view[previous] <= view[current]

            saved: i32 = view[previous]
            view[previous] = view[current]
            view[current] = saved
            dec current
        end loop
    end for
end insertion_sort

public main: () -> (code: i32) =
    mut values: [8]i32 = [9, -4, 7, 7, 0, -9, 42, 1]
    insertion_sort(values)

    if values[0] == -9
      and values[1] == -4
      and values[2] == 0
      and values[3] == 1
      and values[4] == 7
      and values[5] == 7
      and values[6] == 9
      and values[7] == 42
    then
        code = 42
    else
        code = 1
    end if
end main
```

## Binary search

Binary search narrows a half-open range over a read-only slice. The conditional loop is itself the result: it breaks with `found(index)` when a candidate matches, while natural completion breaks with `missing`. The fixture checks the first, an interior and the last element, plus absent values in nonempty and empty inputs. See the corresponding [Rosetta Code task](https://rosettacode.org/wiki/Binary_search).

Fixture source: `compiler/tests/fixtures/runtime/binary-search/main.ldn`.

```landin
--  Binary search narrows a read-only slice to a half-open candidate range.
--  Its result is explicit: either a found index or the missing case.
search_result: type = struct
    kind: variant
        found: (index: usize) |
        missing
    end kind
end search_result

search: (values: []i32, needle: i32) -> (result: search_result) =
    mut left: usize = 0
    mut right: usize = lenof values
    result = while left < right do
        middle: usize = left + (right - left) / 2
        candidate: i32 = values[middle]
        break with search_result(kind: found(index: middle))
            when candidate == needle
        if candidate < needle then
            left = middle + 1
        else
            right = middle
        end if
    complete
        break with search_result(kind: missing)
    end while
end search

found_at: (candidate: search_result,
           expected: usize) -> (matches: bool) =
    match candidate.kind
        found(index): matches = index == expected
        missing: matches = false
    end match
end found_at

is_missing: (candidate: search_result) -> (missing_result: bool) =
    match candidate.kind
        found(index): missing_result = false
        missing: missing_result = true
    end match
end is_missing

public main: () -> (code: i32) =
    values: [10]i32 = [-20, -5, 0, 3, 8, 11, 18, 21, 34, 55]
    view: []i32 = values[0..<lenof values]
    empty: []i32 = []

    if found_at(search(view, -20), 0)
      and found_at(search(view, 3), 3)
      and found_at(search(view, 55), 9)
      and is_missing(search(view, 4))
      and is_missing(search(empty, 4))
    then
        code = 42
    else
        code = 1
    end if
end main
```

## Sieve of Eratosthenes

The sieve exercises caller-owned fixed storage, writable and read-only slices, computed indexing, zeroed initialization, and nested traversal. It marks composites through 100 and verifies both the prime count and boundary values. Each prime starts marking at its square because smaller multiples already have a smaller prime factor; the division guard keeps that square within the array. This is the bounded-array form of the [Rosetta Code task](https://rosettacode.org/wiki/Sieve_of_Eratosthenes).

Fixture source: `compiler/tests/fixtures/runtime/sieve-of-eratosthenes/main.ldn`.

```landin
--  The sieve mutates caller-owned storage through a writable slice.  Its
--  nested traversals visit candidates and mark their composite multiples.

count_primes: (values: []bool) -> (result: u32) =
    result = 0
    for composite in values do
        if not composite then
            result += 1
        end if
    end for
end count_primes

sieve: (inout composite: [101]bool) -> none =
    view: []mut bool = composite[0..<lenof composite]
    view[0] = true
    view[1] = true
    first_candidate: usize = 2
    for candidate in first_candidate..<lenof view do
        if not view[candidate] and candidate <= (lenof view - 1) / candidate then
            mut multiple: usize = candidate * candidate
            while multiple < lenof view do
                view[multiple] = true
                multiple += candidate
            end while
        end if
    end for
end sieve

public main: () -> (code: i32) =
    mut composite: [101]bool = zeroed
    sieve(composite)
    view: []bool = composite[0..<lenof composite]

    if count_primes(view) == 25
      and not composite[2]
      and not composite[3]
      and composite[4]
      and not composite[97]
      and composite[99]
      and composite[100]
    then
        code = 42
    else
        code = 1
    end if
end main
```

## Run-length encoding

Run-length encoding transforms a read-only input slice into caller-owned
structured output. Adjacent equal values become a `run` containing the value
and count. Because the supplied output has one slot per input element, this
bounded version cannot run out of capacity; a future library API can add the
appropriate declared error. See the [Rosetta Code task](https://rosettacode.org/wiki/Run-length_encoding).

Fixture source: `compiler/tests/fixtures/runtime/run-length-encoding/main.ldn`.

```landin
--  A run is the value together with the number of adjacent copies.  The
--  caller supplies output storage as large as the input, so it always fits.
run: type = struct
    value: i32
    count: usize
end run

encode: (input: []i32, output: []mut run) -> (used: usize) =
    used = 0
    first: usize = 0
    for read_at in first..<lenof input do
        if used > 0 and output[used - 1].value == input[read_at] then
            output[used - 1].count += 1
        else
            output[used] = run(value: input[read_at], count: 1)
            used += 1
        end if
    end for
end encode

public main: () -> (code: i32) =
    input: [10]i32 = [1, 1, 1, 2, 2, -5, 4, 4, 4, 4]
    mut output: [10]run = zeroed
    input_view: []i32 = input[0..<lenof input]
    output_view: []mut run = output[0..<lenof output]
    used: usize = encode(input_view, output_view)

    empty_input: []i32 = []
    mut empty_output: [0]run = zeroed
    empty_output_view: []mut run = empty_output[0..<lenof empty_output]

    if used == 4
      and output[0].value == 1 and output[0].count == 3
      and output[1].value == 2 and output[1].count == 2
      and output[2].value == -5 and output[2].count == 1
      and output[3].value == 4 and output[3].count == 4
      and encode(empty_input, empty_output_view) == 0
    then
        code = 42
    else
        code = 1
    end if
end main
```

## Merge sort

Merge sort remains the larger divide-and-conquer example. It recursively sorts two half-open ranges, then uses loops to copy each range into a work array and merge the sorted runs back into the input. Both arrays are caller-owned or local storage passed through writable slices; no module state is needed.

Fixture source: `compiler/tests/fixtures/runtime/merge-sort/main.ldn`.

```landin
--  Merge sort keeps its recursive divide-and-conquer shape, but its linear
--  copy and merge passes are loops over caller-owned storage.
copy_to_work: (values: []mut i32, work: []mut i32,
               left: usize, right: usize) -> none =
    for index in left..<right do
        work[index] = values[index]
    end for
end copy_to_work

merge_from: (values: []mut i32, work: []mut i32,
             left: usize, middle: usize, right: usize) -> none =
    mut destination: usize = left
    mut left_at: usize = left
    mut right_at: usize = middle
    while destination < right do
        if left_at < middle
          and (right_at >= right or work[left_at] <= work[right_at])
        then
            values[destination] = work[left_at]
            inc left_at
        else
            values[destination] = work[right_at]
            inc right_at
        end if
        inc destination
    end while
end merge_from

merge_sort_range: (values: []mut i32, work: []mut i32,
                   left: usize, right: usize) -> none =
    if right - left > 1 then
        middle: usize = left + (right - left) / 2
        merge_sort_range(values, work, left, middle)
        merge_sort_range(values, work, middle, right)
        copy_to_work(values, work, left, right)
        merge_from(values, work, left, middle, right)
    end if
end merge_sort_range

merge_sort: (inout values: [8]i32) -> none =
    mut work: [8]i32 = zeroed
    items: []mut i32 = values[0..<lenof values]
    workspace: []mut i32 = work[0..<lenof work]
    merge_sort_range(items, workspace, 0, lenof items)
end merge_sort

public main: () -> (code: i32) =
    mut values: [8]i32 = [-12, 5, 0, 99, 5, 2, -3, 18]
    merge_sort(values)

    if values[0] == -12
      and values[1] == -3
      and values[2] == 0
      and values[3] == 2
      and values[4] == 5
      and values[5] == 5
      and values[6] == 18
      and values[7] == 99
    then
        code = 42
    else
        code = 1
    end if
end main
```

## Benchmark Game fannkuch-redux

This is a direct single-threaded port of the Benchmark Game's
[fannkuch-redux](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/fannkuchredux.html)
algorithm. Like the Benchmark Game's own programs it takes its input, the
order, as its argument, and enumerates every permutation through fixed
caller-owned arrays of sixteen, the largest order it accepts. `text.format`
writes the signed checksum and the maximum flip count. The fixture runs the
official correctness input, seven, and its output oracle pins both the
checksum, 228, and the count, 16. The performance input, twelve, is
deliberately not part of the test gate:

```sh
refine compile --optimize speed main.ldn -o fannkuch-redux
./fannkuch-redux 12
```

Fixture source: `compiler/tests/fixtures/runtime/benchmark-game-fannkuch-redux/main.ldn`.

```landin
--  A direct single-threaded implementation of the Benchmark Game workload.
--  The order is the program's argument: seven for the correctness output,
--  twelve for the performance run, and never more than sixteen.
import core/io
import core/text
import hosted/io as hosted

bad_size: atom

score: type = struct
    checksum: i32
    maximum: u32
end score

reverse_prefix: (inout values: [16]u8) -> none =
    mut left: usize = 0
    mut right: usize = usize(values[0])
    while left < right do
        saved: u8 = values[left]
        values[left] = values[right]
        values[right] = saved
        inc left
        dec right
    end while
end reverse_prefix

fannkuch: (n: usize) -> (result: score) =
    mut order: [16]u8 = zeroed
    mut rotations: [16]usize = zeroed
    mut depth: usize = n
    mut permutation_index: u32 = 0
    first: usize = 0
    for at in first..<n do
        order[at] = u8(at)
    end for
    result = zeroed

    loop do
        while depth > 1 do
            rotations[depth - 1] = depth
            dec depth
        end while

        if order[0] <> 0 then
            mut permutation: [16]u8 = order
            mut flips: u32 = 0
            loop do
                break when permutation[0] == 0
                reverse_prefix(permutation)
                inc flips
            end loop

            if flips > result.maximum then
                result.maximum = flips
            end if
            if permutation_index % 2 == 0 then
                result.checksum += i32(flips)
            else
                result.checksum -= i32(flips)
            end if
        end if

        loop do
            if depth == n then
                return
            end if

            moved: u8 = order[0]
            mut at: usize = 0
            while at < depth do
                order[at] = order[at + 1]
                inc at
            end while
            order[depth] = moved
            dec rotations[depth]
            break when rotations[depth] > 0
            inc depth
        end loop
        inc permutation_index
    end loop
end fannkuch

--  The order named by the first argument, one to sixteen.
order_size: (host: hosted.system)
            -> (n: usize)
            ! io.no_argument | text.invalid_number | text.number_overflow
            | bad_size =
    first: usize = 0
    argument := try io.argument_at(host, first)
    n = try text.parse_usize(text.host_bytes(argument))
    fail bad_size when n < 1 or n > 16
end order_size

report: (host: hosted.system, n: usize, value: score)
        -> none ! io.io_failed | text.no_space | text.invalid_format =
    mut storage: [64]u8 = zeroed
    mut line := text.over(storage)
    try text.format(line, "{}\nPfannkuchen({}) = {}\n",
                    [any(addr value.checksum), any(addr n),
                     any(addr value.maximum)])
    try io.write(host, io.out(host), text.used(line))
end report

public main: () -> (code: i32) =
    host := hosted.host()
    code = 1
    n := order_size(host) else (problem)
        _ = problem
        io.write(host, io.err(host),
                 "usage: fannkuch-redux N, where N is 1 to 16\n")
            else (ignored)
            _ = ignored
        end
        return
    end

    value: score = fannkuch(n)
    report(host, n, value) else (problem)
        _ = problem
        return
    end
    code = 0
end main
```

## Benchmark Game Mandelbrot

The Benchmark Game's
[Mandelbrot](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/mandelbrot.html)
workload plots the complex rectangle from `-1.5-i` through `0.5+i`. This port
takes the image's size as its argument, performs the scalar `f64` iteration in
its specified order, packs membership bits most-significant first into a row
allocated from the hosted heap, and writes each row through a buffered writer.
A width that is not a multiple of eight pads each row's last byte with zero
bits, as PBM requires. The fixture runs the official 200-by-200 correctness
input and holds the exact 5,011-byte binary PBM result; the performance input
is 16,000.

Fixture source: `compiler/tests/fixtures/runtime/benchmark-game-mandelbrot/main.ldn`.

```landin
--  The image's size is the program's argument: 200 for the correctness
--  output, 16000 for the performance run.  Each membership bit is packed
--  most-significant first and written in binary PBM format; a row whose
--  width is not a multiple of eight pads its last byte with zero bits.
import core/io
import core/mem
import core/text
import hosted/heap
import hosted/io as hosted

in_set: (real_coordinate: f64, imaginary_coordinate: f64)
        -> (member: bool) =
    mut real: f64 = 0.0
    mut imaginary: f64 = 0.0
    mut real_squared: f64 = 0.0
    mut imaginary_squared: f64 = 0.0
    mut iteration: u32 = 0

    while iteration < 50
      and real_squared + imaginary_squared <= 4.0
    do
        imaginary = 2.0 * real * imaginary + imaginary_coordinate
        real = real_squared - imaginary_squared + real_coordinate
        real_squared = real * real
        imaginary_squared = imaginary * imaginary
        inc iteration
    end while
    member = real_squared + imaginary_squared <= 4.0
end in_set

--  Pack one row of the N by N image into ROW, eight pixels to a byte.
pack_row: (n: usize, imaginary_coordinate: f64, row: []mut u8) -> none =
    coordinate_size: f64 = f64(n)
    first: usize = 0
    for byte_column in first..<lenof row do
        start: usize = byte_column * 8
        mut bits: usize = n - start
        if bits > 8 then
            bits = 8
        end if
        mut packed: u8 = 0
        for offset in first..<bits do
            packed <<= 1
            pixel_x: usize = start + offset
            real_coordinate: f64 = 2.0 * f64(pixel_x) / coordinate_size - 1.5
            if in_set(real_coordinate, imaginary_coordinate) then
                packed |= 1
            end if
        end for
        row[byte_column] = packed << u8(8 - bits)
    end for
end pack_row

render: (inout out: io.buffered_writer(hosted.system), n: usize, row: []mut u8)
        -> none ! io.io_failed | text.no_space | text.invalid_format =
    mut room: [48]u8 = zeroed
    mut header := text.over(room)
    try text.format(header, "P4\n{} {}\n", [any(addr n), any(addr n)])
    try io.put(out, text.used(header))

    coordinate_size: f64 = f64(n)
    first: usize = 0
    for y in first..<n do
        pack_row(n, 2.0 * f64(y) / coordinate_size - 1.0, row)
        try io.put(out, row)
    end for
end render

--  The image size named by the first argument.
image_size: (host: hosted.system)
            -> (n: usize)
            ! io.no_argument | text.invalid_number | text.number_overflow =
    first: usize = 0
    argument := try io.argument_at(host, first)
    n = try text.parse_usize(text.host_bytes(argument))
end image_size

public main: () -> (code: i32) =
    host := hosted.host()
    memory := heap.host()
    code = 1
    n := image_size(host) else (problem)
        _ = problem
        io.write(host, io.err(host), "usage: mandelbrot N\n") else (ignored)
            _ = ignored
        end
        return
    end

    mut row := mem.new_bytes(memory, (n + 7) / 8) else (problem)
        _ = problem
        io.write(host, io.err(host), "mandelbrot: out of memory\n")
            else (ignored)
            _ = ignored
        end
        return
    end
    defer mem.delete_bytes(memory, row)

    mut storage: [16384]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage[0..<16384])
    defer io.flush(out) else (problem)
        _ = problem
    end
    render(out, n, mem.bytes(row)) else (problem)
        _ = problem
        return
    end
    io.flush(out) else (problem)
        _ = problem
        return
    end
    code = 0
end main
```

## Benchmark Game FASTA

The Benchmark Game's
[FASTA](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/fasta.html)
workload combines cyclic copying with weighted random selection. This port
takes the sequence length as its argument; for the official correctness input,
1,000, it writes 2,000 ALU nucleotides, 3,000 IUB symbols, and 5,000
human-frequency symbols in 60-byte lines, and the fixture holds the exact
10,245-byte output. It builds both cumulative-probability tables at runtime,
lending the arrays whole to slice parameters [0570], and uses the specified
naïve LCG once per random nucleotide. The lines gather in a 16 KiB buffered
writer, so the performance input, 25,000,000, writes its 254 MB in large
pieces rather than four million lines.

Fixture source: `compiler/tests/fixtures/runtime/benchmark-game-fasta/main.ldn`.

```landin
--  The sequence length is the program's argument: 1000 for the correctness
--  output, 25000000 for the performance run.  The probability search remains
--  linear and the naïve LCG advances once for every random nucleotide.
import core/io
import core/text
import hosted/io as hosted

alu: []u8 = "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA"
iub_symbols: []u8 = "acgtBDHKMNRSVWY"
iub_probabilities: [15]f64 = [
    0.27, 0.12, 0.12, 0.27, 0.02,
    0.02, 0.02, 0.02, 0.02, 0.02,
    0.02, 0.02, 0.02, 0.02, 0.02
]
human_symbols: []u8 = "acgt"
human_probabilities: [4]f64 = [
    0.3029549426680, 0.1979883004921,
    0.1975473066391, 0.3015094502008
]

width_for: (remaining: usize) -> (width: usize) =
    if remaining < 60 then
        width = remaining
    else
        width = 60
    end if
end width_for

make_cumulative: (probabilities: []mut f64) -> none =
    mut total: f64 = 0.0
    first: usize = 0
    for index in first..<lenof probabilities do
        total += probabilities[index]
        probabilities[index] = total
    end for
end make_cumulative

next_random: (inout seed: u32) -> (value: f64) =
    seed = (seed * 3877 + 29573) % 139968
    value = f64(seed) / 139968.0
end next_random

select_symbol: (symbols: []u8, cumulative: []f64, random: f64)
               -> (selected: u8) =
    selected = symbols[lenof symbols - 1]
    first: usize = 0
    for index in first..<lenof cumulative do
        if random < cumulative[index] then
            selected = symbols[index]
            return
        end if
    end for
end select_symbol

write_repeated: (inout out: io.buffered_writer(hosted.system),
                 source: []u8, count: usize) -> none ! io.io_failed =
    mut line: [61]u8 = zeroed
    mut emitted: usize = 0
    mut source_at: usize = 0
    first: usize = 0

    while emitted < count do
        width: usize = width_for(count - emitted)
        for at in first..<width do
            line[at] = source[source_at]
            inc source_at
            if source_at == lenof source then
                source_at = 0
            end if
        end for
        line[width] = 10
        try io.put(out, line[0..<width + 1])
        emitted += width
    end while
end write_repeated

write_random: (inout out: io.buffered_writer(hosted.system), symbols: []u8,
               cumulative: []f64, inout seed: u32, count: usize)
              -> none ! io.io_failed =
    mut line: [61]u8 = zeroed
    mut emitted: usize = 0
    first: usize = 0

    while emitted < count do
        width: usize = width_for(count - emitted)
        for at in first..<width do
            random: f64 = next_random(seed)
            line[at] = select_symbol(symbols, cumulative, random)
        end for
        line[width] = 10
        try io.put(out, line[0..<width + 1])
        emitted += width
    end while
end write_random

--  The three sequences for N, written through OUT.
fasta: (inout out: io.buffered_writer(hosted.system), n: usize)
       -> none ! io.io_failed =
    mut seed: u32 = 42
    mut iub: [15]f64 = iub_probabilities
    mut human: [4]f64 = human_probabilities
    make_cumulative(iub)
    make_cumulative(human)

    try io.put(out, ">ONE Homo sapiens alu\n")
    try write_repeated(out, alu, n * 2)
    try io.put(out, ">TWO IUB ambiguity codes\n")
    try write_random(out, iub_symbols, iub, seed, n * 3)
    try io.put(out, ">THREE Homo sapiens frequency\n")
    try write_random(out, human_symbols, human, seed, n * 5)
end fasta

--  The sequence length named by the first argument.
sequence_size: (host: hosted.system)
               -> (n: usize)
               ! io.no_argument | text.invalid_number | text.number_overflow =
    first: usize = 0
    argument := try io.argument_at(host, first)
    n = try text.parse_usize(text.host_bytes(argument))
end sequence_size

public main: () -> (code: i32) =
    host := hosted.host()
    code = 1
    n := sequence_size(host) else (problem)
        _ = problem
        io.write(host, io.err(host), "usage: fasta N\n") else (ignored)
            _ = ignored
        end
        return
    end

    mut storage: [16384]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage[0..<16384])
    defer io.flush(out) else (problem)
        _ = problem
    end
    fasta(out, n) else (problem)
        _ = problem
        return
    end
    io.flush(out) else (problem)
        _ = problem
        return
    end
    code = 0
end main
```

## Benchmark Game reverse-complement

The Benchmark Game's
[reverse-complement](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/revcomp.html)
workload reads FASTA on its standard input and writes each record's header
unchanged and its sequence reversed, every base replaced by its IUB
complement, in lines of sixty. Its official input is FASTA's own output for
1,000, so the fixture's standard input is byte for byte the previous
program's oracle. A sequence may be as long as the input, so the program
gathers all of it in a `core/text` builder that grows on the hosted heap
[1360], and reads each sequence from its last byte back to its first through a
256-entry complement table, writing through a buffered writer. Like the word
count, it reads its standard input and returns 0. The performance input is
FASTA's output for 25,000,000, about 250 MB:

```sh
refine compile --optimize speed main.ldn -o reverse-complement
./fasta 25000000 | ./reverse-complement > /dev/null
```

Fixture source: `compiler/tests/fixtures/runtime/benchmark-game-reverse-complement/main.ldn`.

```landin
--  The Benchmark Game's reverse-complement workload: read a FASTA file on
--  standard input and write each record's header line as it is, then its
--  sequence reversed, every base replaced by its IUB complement, in lines
--  of sixty.  A sequence may be as long as the input, so the whole input is
--  gathered in a builder that grows on the heap, and each sequence is then
--  read from its last byte back to its first.
import core/io
import core/mem
import core/text
import hosted/heap
import hosted/io as hosted

--  Each IUB code and the code it pairs with.  A lowercase code pairs with
--  the same uppercase complement as its uppercase form.
codes: []u8 = "ACGTUMRWSYKVHDBN"
pairs: []u8 = "TGCAAKYWSRMBDHVN"

--  Every byte's complement, at the byte's own index.  A byte that is no
--  IUB code is its own complement.
complements: () -> (table: [256]u8) =
    table = zeroed
    for at in usize(0)..<256 do
        table[at] = u8(at)
    end for
    for at in usize(0)..<lenof codes do
        table[usize(codes[at])] = pairs[at]
        table[usize(codes[at]) + 32] = pairs[at]
    end for
end complements

--  Append all of standard input to WHOLE, a read at a time.
read_all: (host: hosted.system, inout whole: text.builder)
          -> none ! io.io_failed | text.no_space =
    input: io.file = io.input(host)
    mut chunk: [65536]u8 = zeroed
    loop do
        got: usize = try io.read(host, input, chunk[0..<65536])
        break when got == 0
        try text.append(whole, chunk[0..<got])
    end loop
end read_all

--  Write SEQUENCE to OUT from its last base to its first, each replaced by
--  its complement, leaving out its line breaks and breaking it again into
--  lines of sixty.
write_reversed: (inout out: io.buffered_writer(hosted.system),
                 sequence: []u8, table: [256]u8) -> none ! io.io_failed =
    mut line: [61]u8 = zeroed
    mut width: usize = 0
    mut at: usize = lenof sequence
    while at > 0 do
        dec at
        base: u8 = sequence[at]
        continue when base == 10
        line[width] = table[usize(base)]
        inc width
        if width == 60 then
            line[60] = 10
            try io.put(out, line[0..<61])
            width = 0
        end if
    end while
    if width > 0 then
        line[width] = 10
        try io.put(out, line[0..<width + 1])
    end if
end write_reversed

--  Write every record of INPUT to OUT: its header line, which begins with
--  `>`, as it is, and then its sequence, every line up to the next header,
--  turned around.
records: (inout out: io.buffered_writer(hosted.system), input: []u8)
         -> none ! io.io_failed =
    table: [256]u8 = complements()
    mut at: usize = 0
    while at < lenof input do
        if input[at] == 62 then
            ends: usize = at + mem.find(input[at..<lenof input], 10)
            try io.put(out, input[at..<ends])
            try io.put(out, "\n")
            at = ends
            if at < lenof input then inc at end if
        end if
        ends: usize = at + mem.find(input[at..<lenof input], 62)
        try write_reversed(out, input[at..<ends], table)
        at = ends
    end while
end records

--  Say on standard error why the program stopped.
complain: (host: hosted.system, message: []u8) -> none =
    io.write(host, io.err(host), message) else (ignored)
        _ = ignored
    end
end complain

public main: () -> (code: i32) =
    host := hosted.host()
    memory := heap.host()
    mut storage: [65536]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage[0..<65536])
    defer io.flush(out) else (problem)
        _ = problem
    end
    mut whole := text.growing(any(addr memory))
    defer text.release(whole)
    code = 1

    read_all(host, whole) else (problem)
        if problem == text.no_space then
            complain(host, "revcomp: out of memory\n")
        else
            complain(host, "revcomp: standard input could not be read\n")
        end if
        return
    end
    records(out, text.used(whole)) else (problem)
        _ = problem
        complain(host, "revcomp: standard output could not be written\n")
        return
    end
    io.flush(out) else (problem)
        _ = problem
        complain(host, "revcomp: standard output could not be written\n")
        return
    end
    code = 0
end main
```

## Benchmark Game binary-trees

The Benchmark Game's
[binary-trees](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/binarytrees.html)
workload builds, walks and frees many perfect binary trees beside one that
lives throughout. Every node is its own allocation, and its children are a
pointer union [0480], `leaf | ptr mut node`, so a missing child is an atom
rather than a null pointer. Each tree's nodes are allocated through a
`core/region` over the hosted heap, and the tree is given back by releasing
its region, which frees every node at once [1360]: the allocator is a handle
the caller chooses, and no tree carries one. The program takes the maximum
depth as its argument; the fixture runs the correctness input, ten, and holds
the official output, and the performance input is twenty-one.

Fixture source: `compiler/tests/fixtures/runtime/benchmark-game-binary-trees/main.ldn`.

```landin
--  A direct single-threaded implementation of the Benchmark Game workload.
--  The maximum depth is the program's argument: ten for the correctness
--  output and twenty-one for the performance run.  Every node is its own
--  allocation, made through a region over the host heap; a tree is given
--  back by releasing its region, which frees each node through the heap.
import core/io
import core/mem
import core/region
import core/text
import hosted/heap
import hosted/io as hosted

bad_depth: atom

--  A missing child, which only a leaf has.
leaf: atom

child: type = leaf | ptr mut node

node: type = struct
    left: child
    right: child
end node

nodes_region: type = region.region(heap.system)

min_depth: usize = 4

--  A perfect tree with DEPTH levels below its root.
build: (memory: nodes_region, depth: usize)
       -> (root: ptr mut node) ! mem.out_of_memory =
    mut left: child = leaf
    mut right: child = leaf
    if depth > 0 then
        left = try build(memory, depth - 1)
        right = try build(memory, depth - 1)
    end if
    shape: node = (left: left, right: right)
    root = try mem.new(memory, shape)
end build

--  The nodes of TREE, counted by walking all of it.
check: (tree: ptr mut node) -> (count: usize) =
    count = 1 + check_child(tree.val.left) + check_child(tree.val.right)
end check

check_child: (branch: child) -> (count: usize) =
    match branch
        leaf: count = 0
        ptr (subtree): count = check(subtree)
    end match
end check_child

--  Build a tree of DEPTH in a region of its own, check it and free it.
checked_tree: (memory: heap.system, depth: usize)
              -> (count: usize) ! mem.out_of_memory =
    mut ledger: region.space(0) = zeroed
    nodes := region.over(ledger, memory)
    defer region.release(ledger, memory)
    tree: ptr mut node = try build(nodes, depth)
    count = check(tree)
end checked_tree

--  Write one line of the report.
say: (host: hosted.system, template: utf8, values: []any text.formattable)
     -> none ! io.io_failed | text.no_space | text.invalid_format =
    mut storage: [96]u8 = zeroed
    mut line := text.over(storage)
    try text.format(line, template, values)
    try io.write(host, io.out(host), text.used(line))
end say

binary_trees: (host: hosted.system, n: usize)
              -> none ! mem.out_of_memory | io.io_failed | text.no_space
                      | text.invalid_format =
    memory := heap.host()
    max_depth: usize = if n > min_depth + 2 then n else min_depth + 2 end if

    stretch_depth: usize = max_depth + 1
    stretch_check: usize = try checked_tree(memory, stretch_depth)
    try say(host, "stretch tree of depth {}\t check: {}\n",
            [any(addr stretch_depth), any(addr stretch_check)])

    mut long_ledger: region.space(0) = zeroed
    long_lived := region.over(long_ledger, memory)
    defer region.release(long_ledger, memory)
    long_tree: ptr mut node = try build(long_lived, max_depth)

    mut depth: usize = min_depth
    while depth <= max_depth do
        iterations: usize = usize(1) << (max_depth - depth + min_depth)
        mut total: usize = 0
        mut made: usize = 0
        while made < iterations do
            total += try checked_tree(memory, depth)
            inc made
        end while
        try say(host, "{}\t trees of depth {}\t check: {}\n",
                [any(addr iterations), any(addr depth), any(addr total)])
        depth += 2
    end while

    long_check: usize = check(long_tree)
    try say(host, "long lived tree of depth {}\t check: {}\n",
            [any(addr max_depth), any(addr long_check)])
end binary_trees

--  The depth named by the first argument; above fifty-nine the nodes counted
--  at depth four would not fit in a usize.
tree_depth: (host: hosted.system)
            -> (n: usize) ! io.no_argument | text.invalid_number
                          | text.number_overflow | bad_depth =
    first: usize = 0
    argument := try io.argument_at(host, first)
    n = try text.parse_usize(text.host_bytes(argument))
    fail bad_depth when n > 59
end tree_depth

public main: () -> (code: i32) =
    host := hosted.host()
    code = 1
    n := tree_depth(host) else (problem)
        _ = problem
        io.write(host, io.err(host),
                 "usage: binary-trees N, where N is 0 to 59\n")
            else (ignored)
            _ = ignored
        end
        return
    end

    binary_trees(host, n) else (problem)
        return when problem <> mem.out_of_memory
        message: []u8 = "binary-trees: out of memory\n"
        io.write(host, io.err(host), message) else (ignored)
            _ = ignored
        end
        return
    end
    code = 0
end main
```

## Word count

`wc` with no file named: the program reads its standard input to the end
and prints how many lines, words and bytes it held. The counting routine
asks only for an `io.reader` [1290] [1230], the narrowest capability it
uses, so it does not know whether the bytes come from a pipe, a file or a
test's memory; `main` hands it the hosted provider and `io.input`, the
standard-input handle of the process concept beside `io.out` and `io.err`.
It reads a buffer at a time until a read returns zero, which is end of
input, carrying whether a word is open from one buffer to the next. The
totals are `u64`, and `text.format` writes them into a line the program
writes once: a builder over a 64-byte buffer, `text.over`, takes the
template `"{} {} {}\n"` and the three totals, each erased to
`any text.formattable` from the address of its field [1370] [1380] and
written as an array literal the call lends as a slice [0570], and fills
each `{}` with the next in decimal. The template is checked against
the values when it runs, since nothing runs at compile time, so `render`
names `text.invalid_format` beside `text.no_space`. A failed read is
reported on standard error with status 1.

Fixture source: `compiler/tests/fixtures/runtime/word-count/main.ldn`.

```landin
--  Count the lines, words and bytes on standard input, as `wc` does when it
--  is named no file.  The counting asks only for a reader, the narrowest
--  capability it uses, so the same routine counts a pipe, a file or bytes in
--  memory.  The totals are u64, and core/text formats them into a line.
import core/io
import core/text
import hosted/io as hosted

counts: type = struct
    lines: u64
    words: u64
    bytes: u64
end counts

--  White space as C's isspace has it: space, tab, newline, vertical tab,
--  form feed and carriage return.  Every other byte belongs to a word.
blank: (byte: u8) -> (yes: bool) =
    yes = byte == 32 or (byte >= 9 and byte <= 13)
end blank

--  Read to end of input a buffer at a time.  A line is counted at its
--  newline, so a last line without one adds no line; a word is counted at
--  its first byte, and may run on from one buffer into the next.
count: (provider: type is io.reader, source: provider,
        opened: io.file, buffer: []mut u8)
       -> (totals: counts) ! io.io_failed =
    totals = (lines: 0, words: 0, bytes: 0)
    mut inside: bool = false
    loop do
        got: usize = try io.read(source, opened, buffer)
        break when got == 0
        totals.bytes += u64(got)
        for byte in buffer[0..<got] do
            if byte == 10 then inc totals.lines end if
            if blank(byte) then
                inside = false
            elsif not inside then
                inside = true
                inc totals.words
            end if
        end for
    end loop
end count

--  The three totals in decimal, separated by spaces and ended by a newline,
--  formatted into LINE.
render: (totals: counts, inout line: text.builder)
        -> none ! text.no_space | text.invalid_format =
    try text.format(line, "{} {} {}\n",
                    [any(addr totals.lines), any(addr totals.words),
                     any(addr totals.bytes)])
end render

public main: () -> (code: i32) =
    host := hosted.host()
    input: io.file = io.input(host)
    mut buffer: [4096]u8 = zeroed
    totals := count(host, input, buffer[0..<4096]) else (problem)
        _ = problem
        message: []u8 = "wc: standard input could not be read\n"
        io.write(host, io.err(host), message) else (ignored)
            _ = ignored
        end
        code = 1
        return
    end

    --  Three twenty-digit totals, two spaces and a newline fit in 64 bytes.
    mut storage: [64]u8 = zeroed
    mut line := text.over(storage[0..<64])
    render(totals, line) else (problem)
        _ = problem
        code = 1
        return
    end
    io.write(host, io.out(host), text.used(line)) else (problem)
        _ = problem
        code = 1
        return
    end
    code = 0
end main
```

Pipe anything into it:

```sh
refine compile main.ldn -o wc
printf 'one two\nthree\n' | ./wc
```

which prints `2 3 14`. The fixture feeds it a six-kilobyte text, larger
than the 4096-byte buffer and ending without a newline, and two more feed it
an empty input and none at all. The same routine counts `core/io.memory`'s
standard input on every target, Cortex-M included, in
`runtime/word-count-memory`, which also injects a read failure, and
`runtime/word-count-closed-input` reads a standard input the program has
closed, which every hosted system refuses.

## Directory listing

`ls -l` cut down to what every hosted system agrees on: each entry of a
directory with its kind, a file's size in bytes, and its name, in byte
order. So that it has something known to list, the program first builds a
small directory where it runs, four files and a subdirectory, and removes
it again at the end; it returns 42 when it read back what it built.

A directory is opened with a buffer the caller supplies, and `io.read_entry`
refills that buffer as the entries are read, so each entry's name is lent
from the directory [0790] until the next read reuses the buffer [0800]: a
program that keeps a name past that read is refused, and this one copies
each name into a `kept` record with `mem.copy`. An entry with an empty name
is the end of the directory. A name is a host string, as the system stores
it, and need not be UTF-8: the listing keeps its bytes, `text.host_bytes`,
and a name that `text.valid` refuses prints with its other bytes escaped as
`\xHH`, a hexadecimal append right-aligned in two columns with a `0` fill.
A path is a host string too, which the listing builds with a builder over
a buffer of its own and makes with `text.host_over`. A file's size is
`io.entry_size`, asked of the open directory by the name it read, a `u64`;
a directory's own size differs between file systems, so it prints as `-`.
The entries come in whatever order the system keeps them, so the program
sorts its copies with `core/sort`, ordered by the `cmp.ordered` evidence
it declares for `kept` [1280], which `mem.compare` gives as byte order. A
`defer` closes the directory on every way out of `list` [1100].

Each line is one `text.format` of three values of different types: the
kind's word, the size as a `u64` or the dash as bytes, chosen by an `if`,
and the name as a `shown` record, whose own `text.formattable` conformance
[1240] writes it as it is or escaped. The lines go to standard output
through a buffered writer, `io.buffered_over`, which gathers them in a
512-byte buffer and writes them when it fills. There are no destructors, so
bytes still waiting when the program ends are never written: `show`
flushes at the end, which reports a failure, and a `defer` flushes on
every other way out.

Fixture source: `compiler/tests/fixtures/runtime/directory-listing/main.ldn`.

```landin
--  List a directory: each entry's kind, a file's size in bytes and the
--  entry's name, in byte order.  The program first builds the directory it
--  lists, so it can check what it reads back, and removes it again at the
--  end.  A name is bytes, which need not be UTF-8: core/text validates each
--  one, and a name that is not prints with its other bytes escaped.
import core/cmp
import core/io
import core/mem
import core/sort
import core/text
import hosted/io as hosted

--  The directory the program builds, lists and removes, in the directory
--  it runs in.
top: []u8 = "listing-scratch"

--  More entries than the listing keeps, or a name longer than it keeps.
too_many: atom
too_long: atom

--  An entry kept past the read that gave it.  The directory lends a name
--  only until its next read, which reuses the buffer the name is in, so
--  the listing keeps a copy.
kept: type = struct
    name: [255]u8
    length: usize
    kind: io.entry_kind
    size: u64
end kept

--  Byte order, the order `ls` gives in the C locale.
before: (left: kept, right: kept) -> (yes: bool) =
    yes = mem.compare(left.name[0..<left.length],
                      right.name[0..<right.length]) == mem.less
end before

kept is cmp.ordered (less: before)

--  A name as the listing shows it: as it is when it is UTF-8, and
--  otherwise with each byte outside printable ASCII written as `\xHH`, so
--  the line stays text.  Its conformance lets `format` write it.
shown: type = struct
    name: []u8
end shown

append_shown: (self: ptr shown, inout into: text.builder)
              -> none ! text.no_space =
    start: usize = text.length(into)
    escaped(self.val.name, into) else (problem)
        text.truncate(into, start)
        fail problem
    end
end append_shown

shown is text.formattable (append: append_shown)

escaped: (name: []u8, inout into: text.builder) -> none ! text.no_space =
    if text.valid(name) then
        try text.append(into, name)
        return
    end if
    for byte in name do
        if byte >= 32 and byte < 127 and byte <> 92 then
            try text.append_byte(into, byte)
        else
            try text.append(into, "\\x")
            digits: usize = text.length(into)
            try text.append_hex_u32(into, u32(byte))
            try text.align_right(into, digits, 2, 48)
        end if
    end for
end escaped

--  The path of NAME in the top directory, or of the top directory itself
--  when NAME is empty, built in PATH.
joined: (name: []u8, inout path: text.builder) -> none ! text.no_space =
    text.clear(path)
    try text.append(path, top)
    if lenof name > 0 then
        try text.append_byte(path, 47)
        try text.append(path, name)
    end if
end joined

--  Make the file NAME in the top directory, holding CONTENTS.
make_file: (host: hosted.system, name: []u8, contents: []u8) -> none ! ... =
    mut scratch: [64]u8 = zeroed
    mut path := text.over(scratch[0..<64])
    try joined(name, path)
    opened: io.file = try io.open_write(host, text.host_over(text.used(path)))
    io.write(host, opened, contents) else (problem)
        io.close(host, opened) else (ignored)
            _ = ignored
        end
        fail problem
    end
    try io.close(host, opened)
end make_file

--  Remove the file PATH names, or with DIRECTORY the empty directory.
remove: (host: hosted.system, path: text.host_string, directory: bool)
        -> none ! ... =
    if directory then
        try io.remove_directory(host, path)
    else
        try io.remove_file(host, path)
    end if
end remove

--  Remove NAME from the top directory, or the top directory itself when
--  NAME is empty, if it is there.
forget: (host: hosted.system, name: []u8, directory: bool) -> none ! ... =
    mut scratch: [64]u8 = zeroed
    mut path := text.over(scratch[0..<64])
    try joined(name, path)
    remove(host, text.host_over(text.used(path)), directory) else (problem)
        fail problem when problem <> io.not_found
    end
end forget

--  Remove everything the program makes, whatever an earlier run left.
clear: (host: hosted.system) -> none ! ... =
    try forget(host, "nested/gamma.log", false)
    try forget(host, "nested", true)
    try forget(host, "alpha.log", false)
    try forget(host, "beta.log", false)
    try forget(host, "café.log", false)
    try forget(host, "empty", false)
    try forget(host, "", true)
end clear

--  Make the directory NAME in the top directory, or the top directory
--  itself when NAME is empty.
make_directory: (host: hosted.system, name: []u8) -> none ! ... =
    mut scratch: [64]u8 = zeroed
    mut path := text.over(scratch[0..<64])
    try joined(name, path)
    try io.make_directory(host, text.host_over(text.used(path)))
end make_directory

--  Four files, one of them empty and one with a name beyond ASCII, and a
--  subdirectory holding a fifth.
build: (host: hosted.system) -> none ! ... =
    try clear(host)
    try make_directory(host, "")
    try make_file(host, "alpha.log", "alpha\n")
    line_of_beta: []u8 = "beta\n"
    mut lines: [1000]u8 = zeroed
    for at in usize(0)..<usize(1000) do
        lines[at] = line_of_beta[at % 5]
    end for
    try make_file(host, "beta.log", lines[0..<1000])
    try make_file(host, "café.log", "café\n")
    try make_file(host, "empty", "")
    try make_directory(host, "nested")
    try make_file(host, "nested/gamma.log", "gamma\n")
end build

--  Read every entry of the top directory into INTO, with each file's size,
--  and return how many there are.
list: (host: hosted.system, into: []mut kept) -> (count: usize) ! ... =
    count = 0
    mut buffer: [1024]u8 = zeroed
    mut listing: io.directory =
        try io.open_directory(host, text.host_over(top), buffer[0..<1024])
    defer io.close_directory(host, listing) else (problem)
        _ = problem
    end
    loop do
        item: io.entry = try io.read_entry(host, listing)
        name: []u8 = text.host_bytes(item.name)
        break when lenof name == 0
        fail too_many when count == lenof into
        fail too_long when lenof name > 255
        try mem.copy(into[count].name[0..<255], name)
        into[count].length = lenof name
        into[count].kind = item.kind
        into[count].size = 0
        if item.kind == io.regular then
            into[count].size = try io.entry_size(host, listing, item.name)
        end if
        inc count
    end loop
end list

--  One line per entry into LINE: its kind, a file's size or `-`, and its
--  name as it is shown.
line: (entry: kept, inout into: text.builder) -> none ! ... =
    word: []u8 = match entry.kind
        io.regular: "file"
        io.subdirectory: "directory"
        io.symbolic_link: "link"
        io.special: "special"
    end match
    dash: []u8 = "-"
    size: u64 = entry.size
    amount: any text.formattable =
        if entry.kind == io.regular then any(addr size) else any(addr dash) end if
    name: shown = (name: entry.name[0..<entry.length])
    text.clear(into)
    try text.format(into, "{} {} {}\n", [any(addr word), amount, any(addr name)])
end line

--  Write the sorted listing and a total of the files' bytes through a
--  buffered writer, and say whether it holds what `build` made.
show: (host: hosted.system, entries: []mut kept) -> (ok: bool) ! ... =
    sort.sort(entries)
    mut storage: [512]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage[0..<512])
    --  Whatever waits is written on every way out; the flush at the end
    --  is the one whose failure is reported.
    defer io.flush(out) else (problem)
        _ = problem
    end
    mut room: [300]u8 = zeroed
    mut text_line := text.over(room[0..<300])
    mut total: u64 = 0
    for entry in entries do
        try line(entry, text_line)
        try io.put(out, text.used(text_line))
        total += entry.size
    end for
    count: usize = lenof entries
    text.clear(text_line)
    try text.format(text_line, "{} entries, {} bytes in files\n",
                    [any(addr count), any(addr total)])
    try io.put(out, text.used(text_line))
    try io.flush(out)
    ok = count == 5 and total == 1012
end show

public main: () -> (code: i32) =
    host := hosted.host()
    code = 1
    build(host) else (problem)
        _ = problem
        return
    end
    blank: kept = (name: [255 of 0], length: 0, kind: io.special, size: 0)
    mut entries: [8]kept = [8 of blank]
    code = 2
    count: usize = list(host, entries[0..<8]) else (problem)
        _ = problem
        return
    end
    code = 3
    ok: bool = show(host, entries[0..<count]) else (problem)
        _ = problem
        return
    end
    code = 4
    clear(host) else (problem)
        _ = problem
        return
    end
    code = if ok then 42 else 5 end if
end main
```

Compiled and run in an empty directory:

```sh
refine compile main.ldn -o listing
./listing
```

it prints

```text
file 6 alpha.log
file 1000 beta.log
file 6 café.log
file 0 empty
directory - nested
5 entries, 1012 bytes in files
```

and leaves the directory as it found it. Its failures are fixtures of their
own on every hosted target: a missing path and a file used as a directory
are `not_found`, with ENOENT or ENOTDIR kept as the last errno, in
`runtime/directory-missing-path` and `runtime/directory-through-file`; a
name that is not UTF-8 is made and listed as its bytes on Linux and
FreeBSD and refused with EILSEQ on Darwin, in
`runtime/directory-name-not-utf8`; and `runtime/directory-larger-than-buffer`
reads four hundred names through a buffer of 1024 bytes, each exactly
once. `runtime/directory-memory` lists `core/io.memory`'s directories with
every oracle on every hosted target, and
`runtime/directory-memory-firmware` lists one within a Cortex-M image.

## Line numbers

`cat -n`: the program reads its standard input a line at a time and writes
each line after its number, right-aligned in six columns, and a tab. It
reads through `io.lines_over`, a line reader over a 32-byte buffer of its
own, and `io.read_line` lends each line from that buffer until the next read
[0790] [0800], without its line ending: a `\n`, or a `\r\n` as Windows
writes it. The last line need not end, and a line that has `finished` is the
end of input. A line too long for the buffer is `io.line_too_long`; the
reader skips the rest of it, and the program numbers it with a note in its
place and goes on with the next. The number is a `u64` appended to a builder
and right-aligned with `text.align_right`.

The output goes through a buffered writer, `io.buffered_over`, which
gathers it in a 256-byte buffer and writes it when the buffer fills. There
are no destructors, so bytes still waiting when the program ends are never
written: `main` flushes at the end, which reports a failure as status 1, and
a `defer` flushes on every other way out [1100].

Fixture source: `compiler/tests/fixtures/runtime/line-numbers/main.ldn`.

```landin
--  Number the lines of standard input, as `cat -n` does: each line after
--  its number, right-aligned in six columns, and a tab.  A line is read
--  through a buffer of 32 bytes; one too long for it is numbered with a
--  note in its place, and the lines after it are numbered as usual.  The
--  output goes through a buffered writer, flushed on every way out.
import core/io
import core/text
import hosted/io as hosted

--  Write every line of INPUT to OUT, numbered.
numbered: (provider: type is io.world, host: provider,
           inout out: io.buffered_writer(provider))
          -> none ! ... =
    mut buffer: [32]u8 = zeroed
    mut lines := io.lines_over(host, io.input(host), buffer[0..<32])
    mut room: [16]u8 = zeroed
    mut prefix := text.over(room[0..<16])
    mut number: u64 = 0
    loop do
        inc number
        text.clear(prefix)
        try text.append_u64(prefix, number)
        try text.align_right(prefix, 0, 6, 32)
        try text.append_byte(prefix, 9)
        item: io.line = io.read_line(lines) else (problem)
            fail problem when problem <> io.line_too_long
            try io.put(out, text.used(prefix))
            try io.put(out, "(a line too long to show)\n")
            continue
        end
        break when item.finished
        try io.put(out, text.used(prefix))
        try io.put(out, item.bytes)
        try io.put(out, "\n")
    end loop
end numbered

public main: () -> (code: i32) =
    host := hosted.host()
    mut storage: [256]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage[0..<256])
    defer io.flush(out) else (problem)
        _ = problem
    end
    code = 1
    numbered(host, out) else (problem)
        _ = problem
        return
    end
    io.flush(out) else (problem)
        _ = problem
        return
    end
    code = 0
end main
```

Pipe text into it:

```sh
refine compile main.ldn -o numbers
printf 'one\r\ntwo\n\nlast' | ./numbers
```

which prints

```text
     1	one
     2	two
     3	
     4	last
```

The fixture's input has a line ending in `\r\n`, an empty line, a line
longer than the buffer and a last line without a newline. The reader's
other failures run on every target over `core/io.memory`'s standard input
in `runtime/core-io-line-reader`, a read failing partway and reads three
bytes long among them, and the buffered writer's in
`runtime/core-io-buffered-writer` and `runtime/buffered-writer-closed-output`.

## Running a shell

The program runs `/bin/sh` and tells it what to do with `-c`, gives it an
environment of its own, reads what the shell writes while it runs, and
reports it. A program is started by its path, `io.spawn`, with the
arguments it sees after its own name and exactly the variables the parent
builds, each a name and a value, `io.variable`: nothing is looked up on a
search path, no shell reads anything the parent did not ask for, and the
parent's own environment, its `HOME` among it, is not passed on, which the
shell's third line shows. Its `PATH` is the one variable the parent passes
on, read from its own environment with `io.variable_named`, so that the
shell finds `sleep`. An argument, a name and a value are host strings
[0790], here made over text with `text.host_over`; the system takes any
bytes, UTF-8 or not. `io.spawn` is generic over its provider, and a
generic routine is not lent an array literal or a whole array, so the
arguments and variables are named arrays given as slices with their
counts [0570].

Each of a child's three standard streams is inherited, discarded or piped;
`io.capturing` pipes its output and errors to the parent and discards its
input. A pipe holds only so much, 64 KiB on Linux, and a child that writes
more waits until its parent reads, so the parent reads while the child
runs, and reads both pipes together: `io.read_child` gives whatever either
has next and says which it came from, so neither pipe stays full while the
other is read to its end. Here the bytes go into two builders over buffers
of the program's own, and `io.wait` reports how the child ended, `io.ending`,
whose variant part [0680] is either `exited` with a code or `signalled`,
ended from outside; what ended it is the system's detail, which the hosted
provider keeps as `hosted.last_signal`. `wait` consumes the child [0910],
with any pipe it still has.

The parent times the child on the monotonic clock, `io.now`, before it
starts it and after it has ended, and `io.elapsed` is the span between the
two readings, an `io.duration` of nanoseconds; it would trap were the second
reading the earlier, which a monotonic clock never gives. The shell sleeps
for a second, so the span is a second or more however the system schedules
it, and that bound is what the report says, rather than the time itself,
which no two runs share.

The report goes to standard output through a buffered writer, flushed at
the end and by a `defer` on every other way out [1100], and the program
returns 42 when the shell exited with the 3 its script ends with.

Fixture source: `compiler/tests/fixtures/runtime/run-shell/main.ldn`.

```landin
--  Run a shell with an environment built for it, read what it writes to
--  its output and its errors while it runs, time it, and report what it
--  said, what it complained of, how it ended and how long it took.  The
--  report goes through a buffered writer, flushed on every way out.
import core/io
import core/text
import hosted/io as hosted

--  What the shell runs: it says what its environment holds, complains
--  once, sleeps for a second and ends with code 3.  Its environment is
--  only what the program gives it, so the HOME the program itself has is
--  not among it; its PATH is, which is how the shell finds `sleep`.
script: []u8 = """
    printf 'NAME=%s\n' "$NAME"
    printf 'GREETING=%s\n' "$GREETING"
    printf 'HOME is %s\n' "${HOME-not set}"
    echo 'something went wrong' >&2
    sleep 1
    exit 3
    """

--  Read what the child writes to its output and its errors into the two
--  builders, from whichever has something, until both have ended, and
--  wait for it.  Reading both while it runs is what lets a child write
--  more than a pipe holds to either.
capture: (provider: type is io.programs, host: provider,
          sink started: io.child, inout output: text.builder,
          inout errors: text.builder)
         -> (ended: io.ending) ! ... =
    mut running: io.child = started
    mut buffer: [256]u8 = zeroed
    loop do
        part: io.child_read = try io.read_child(host, running, buffer[0..<256])
        break when part.finished
        if part.errors then
            try text.append(errors, buffer[0..<part.count])
        else
            try text.append(output, buffer[0..<part.count])
        end if
    end loop
    ended = try io.wait(host, running)
end capture

--  Write each line of BYTES to OUT after a bar.
quoted: (provider: type is io.writer, inout out: io.buffered_writer(provider),
         bytes: []u8) -> none ! ... =
    mut start: usize = 0
    for at in usize(0)..<lenof bytes do
        if bytes[at] == 10 then
            try io.put(out, "| ")
            try io.put(out, bytes[start..<at + 1])
            start = at + 1
        end if
    end for
    if start < lenof bytes then
        try io.put(out, "| ")
        try io.put(out, bytes[start..<lenof bytes])
        try io.put(out, "\n")
    end if
end quoted

--  Report what the child wrote, how it ended and how long it took, which
--  is never less than the second it slept.
report: (provider: type is io.writer, inout out: io.buffered_writer(provider),
         output: []u8, errors: []u8, ended: io.ending, took: io.duration)
        -> none ! ... =
    try io.put(out, "the shell said:\n")
    try quoted(out, output)
    try io.put(out, "and complained:\n")
    try quoted(out, errors)
    mut room: [64]u8 = zeroed
    mut line := text.over(room[0..<64])
    match ended.how
        io.exited(code): try text.format(line, "and exited with code {}\n",
                                         [any(addr code)])
        io.signalled: try text.append(line, "and was ended by a signal\n")
    end match
    if took >= io.seconds(1) then
        try text.append(line, "after a second or more\n")
    else
        whole: u64 = io.in_milliseconds(took)
        try text.format(line, "after only {} ms\n", [any(addr whole)])
    end if
    try io.put(out, text.used(line))
end report

--  The parent's own PATH, the one variable of its environment it passes
--  on, or the directories every hosted system keeps `sleep` in when it
--  has none.
search_path: (host: hosted.system) -> (path: text.host_string from host) =
    path = text.host_over("/bin:/usr/bin")
    path = io.variable_named(host, text.host_over("PATH")) else (problem)
        _ = problem
        return
    end
end search_path

public main: () -> (code: i32) =
    host := hosted.host()
    mut storage: [256]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage[0..<256])
    defer io.flush(out) else (problem)
        _ = problem
    end
    code = 1
    arguments: [2]text.host_string = [text.host_over("-c"),
                                      text.host_over(script)]
    variables: [3]io.variable =
        [(name: text.host_over("NAME"), value: text.host_over("landin")),
         (name: text.host_over("GREETING"),
          value: text.host_over("hello, world")),
         (name: text.host_over("PATH"), value: search_path(host))]
    began: io.instant = io.now(host)
    started := io.spawn(host, text.host_over("/bin/sh"),
                        arguments[0..<2], variables[0..<3],
                        io.capturing) else (problem)
        _ = problem
        return
    end
    mut said: [512]u8 = zeroed
    mut complained: [512]u8 = zeroed
    mut output := text.over(said[0..<512])
    mut errors := text.over(complained[0..<512])
    ended: io.ending = capture(host, started, output, errors) else (problem)
        _ = problem
        return
    end
    took: io.duration = io.elapsed(began, io.now(host))
    report(out, text.used(output), text.used(errors), ended,
           took) else (problem)
        _ = problem
        return
    end
    io.flush(out) else (problem)
        _ = problem
        return
    end
    match ended.how
        io.exited(status): if status == 3 then code = 42 end if
        io.signalled: code = 2
    end match
end main
```

which prints

```text
the shell said:
| NAME=landin
| GREETING=hello, world
| HOME is not set
and complained:
| something went wrong
and exited with code 3
after a second or more
```

The same `capture` and `report` run over `core/io`'s scripted programs,
beside a memory world, in `runtime/run-shell-memory`, which writes the same report
byte for byte, timed on `core/io`'s manual clock, which a sleep moves on by
exactly what it asks and no time passes otherwise, and injects the fake's
failures. A program that is not there
is `io.not_found` in `runtime/run-missing-program`; a shell that kills
itself is `signalled` in `runtime/run-signalled`, with its signal's number
kept; and in `runtime/run-large-output` a shell writes a mebibyte to each
of its output and its errors, a line to each in turn, which only reading
both together lets it finish. `runtime/run-streams` inherits, discards and
pipes each stream, `runtime/run-environment` passes a value that is not
UTF-8 through to the shell byte for byte, and
`runtime/run-no-descriptor-leak` shows a child receives no file of its
parent's but its three streams. A program reads its own environment through
the `io.environment` concept, with `io.variable_count`, `io.variable_at` and
`io.variable_named`, which
`runtime/environment-variables` shows by starting itself again with an
environment it builds.

## Echo over loopback

A server and its client in one program: the program listens, connects to
itself, sends, accepts, echoes and reads the echo back, first over TCP and
then over UDP, on IPv4's loopback address `127.0.0.1` and then on IPv6's
`::1`. An address is a value, `io.address`, a family, its bytes and a port,
made here with `io.loopback`; `io.parse_address` reads one from its text,
`127.0.0.1:8080` or `[::1]:8080`, and `io.append_ip` writes one back
without its port, as the report does. Nothing resolves a name to an
address yet.

The listener asks for port 0, which means any free one, and
`io.local_address` says which port it got, so the program never collides
with another that runs beside it. Every call waits until it can do what it
was asked, as a blocking socket does, so the order matters in one thread:
the system completes a connection to a listener on its own, so the client
can connect and send all its lines before the server accepts it, and
`io.shutdown` with `io.sending` tells the server the client has finished
sending. A connection is a file of its provider, so the server reads it
through a line reader [0790] [0800] and writes back through a buffered
writer, and the client reads the echo through a line reader of its own.
`io.set_timeouts` limits how long a receive waits: past the limit it is
`io.timed_out`, rather than waiting for ever on a peer that never sends.
Over UDP, `io.receive_from` gives each datagram's sender, which the server
sends it back to with `io.send_to`. A socket is closed with
`io.close_socket`; a `defer` closes each on every way out [1100].

A failure is an atom of the concept's [0940]: a port nothing listens on
is `io.refused`, a port another socket holds `io.address_in_use`, and a
send to a peer that has gone `io.disconnected`. A write to a socket or a
pipe nobody reads would raise SIGPIPE, which ends a process that has not
ignored it; a hosted program ignores it from the start, so the write is an
error the program answers. A system without IPv6's loopback address
cannot run the second half: the program says so and returns 2, rather than
passing over it.

Fixture source: `compiler/tests/fixtures/runtime/network-echo/main.ldn`.

```landin
--  Echo over loopback: a server and its client in one program, over TCP
--  and over UDP, on IPv4's loopback address and on IPv6's.  The server
--  reads the client's lines through a line reader and writes them back
--  through a buffered writer, the client reads them back through a line
--  reader of its own, and the report goes to standard output through a
--  buffered writer, flushed on every way out.
import core/io
import core/text
import hosted/io as hosted

--  What the client sends over TCP: three lines.
request: []u8 = "one\ntwo\nhello, world\n"

--  What the client sends over UDP: two datagrams.
messages: [2][]u8 = ["ping", "hello, datagram"]

--  A reply came from somewhere other than the server it was sent to.
wrong_sender: atom

--  Serve one connection: read each line through a line reader and write it
--  back through a buffered writer, until the client has finished sending,
--  and then finish sending too.  How many lines it echoed.
serve: (provider: type is io.network, host: provider, connection: io.file)
       -> (lines: usize) ! ... =
    mut incoming: [64]u8 = zeroed
    mut reader := io.lines_over(host, connection, incoming[0..<64])
    mut outgoing: [64]u8 = zeroed
    mut writer := io.buffered_over(host, connection, outgoing[0..<64])
    lines = 0
    loop do
        item: io.line = try io.read_line(reader)
        break when item.finished
        try io.put(writer, item.bytes)
        try io.put(writer, "\n")
        inc lines
    end loop
    try io.flush(writer)
    try io.shutdown(host, connection, io.sending)
end serve

--  Echo `request` over TCP between a server and a client on FAMILY's
--  loopback address, and put what the client read back in `echoed`, a line
--  at a time: how many lines the server echoed.  The listener asks for
--  port 0, any free one, and says which it got; the client sends all of
--  its lines and finishes sending before the server accepts, which the
--  system's buffers allow in one thread.
tcp_echo: (provider: type is io.network, host: provider,
           family: io.address_family, inout echoed: text.builder)
          -> (lines: usize) ! ... =
    listener: io.file = try io.listen(host, io.loopback(family, 0))
    defer io.close_socket(host, listener) else (problem)
        _ = problem
    end
    at: io.address = try io.local_address(host, listener)
    client: io.file = try io.connect(host, at)
    defer io.close_socket(host, client) else (problem)
        _ = problem
    end
    try io.set_timeouts(host, client, io.seconds(5), io.seconds(5))
    try io.send(host, client, request)
    try io.shutdown(host, client, io.sending)
    server: io.file = try io.accept(host, listener)
    defer io.close_socket(host, server) else (problem)
        _ = problem
    end
    try io.set_timeouts(host, server, io.seconds(5), io.seconds(5))
    lines = try serve(host, server)
    mut incoming: [64]u8 = zeroed
    mut replies := io.lines_over(host, client, incoming[0..<64])
    loop do
        item: io.line = try io.read_line(replies)
        break when item.finished
        try text.append(echoed, item.bytes)
        try text.append_byte(echoed, 10)
    end loop
end tcp_echo

--  Echo `messages` over UDP between two sockets on FAMILY's loopback
--  address: the server sends each datagram back to whoever sent it, and
--  the client puts each reply in `echoed`, a line each.
udp_echo: (provider: type is io.network, host: provider,
           family: io.address_family, inout echoed: text.builder)
          -> none ! ... =
    server: io.file = try io.open_datagram(host, io.loopback(family, 0))
    defer io.close_socket(host, server) else (problem)
        _ = problem
    end
    client: io.file = try io.open_datagram(host, io.loopback(family, 0))
    defer io.close_socket(host, client) else (problem)
        _ = problem
    end
    try io.set_timeouts(host, server, io.seconds(5), io.seconds(5))
    try io.set_timeouts(host, client, io.seconds(5), io.seconds(5))
    at: io.address = try io.local_address(host, server)
    mut buffer: [64]u8 = zeroed
    for message in messages do
        try io.send_to(host, client, message, at)
        got: io.datagram = try io.receive_from(host, server, buffer[0..<64])
        try io.send_to(host, server, buffer[0..<got.count], got.sender)
        back: io.datagram = try io.receive_from(host, client,
                                                buffer[0..<64])
        fail wrong_sender when not io.same_address(back.sender, at)
        try text.append(echoed, buffer[0..<back.count])
        try text.append_byte(echoed, 10)
    end for
end udp_echo

--  Write each line of BYTES to OUT after a bar.
quoted: (provider: type is io.writer, inout out: io.buffered_writer(provider),
         bytes: []u8) -> none ! ... =
    mut start: usize = 0
    for at in usize(0)..<lenof bytes do
        if bytes[at] == 10 then
            try io.put(out, "| ")
            try io.put(out, bytes[start..<at + 1])
            start = at + 1
        end if
    end for
end quoted

--  Report what came back over PROTOCOL on FAMILY's loopback address: how
--  many of what the server echoed, and each of them.
report: (provider: type is io.writer, inout out: io.buffered_writer(provider),
         protocol: []u8, family: io.address_family, count: usize,
         what: []u8, echoed: []u8) -> none ! ... =
    mut room: [64]u8 = zeroed
    mut line := text.over(room[0..<64])
    at: io.address = io.loopback(family, 0)
    try text.append(line, protocol)
    try text.append(line, " over ")
    try io.append_ip(line, at)
    try text.format(line, ": the server echoed {} {}\n",
                    [any(addr count), any(addr what)])
    try io.put(out, text.used(line))
    try quoted(out, echoed)
end report

--  Echo over TCP and then UDP on FAMILY's loopback address, and report it.
exchange: (host: hosted.system,
           inout out: io.buffered_writer(hosted.system),
           family: io.address_family) -> none ! ... =
    mut room: [256]u8 = zeroed
    mut echoed := text.over(room[0..<256])
    lines: usize = try tcp_echo(host, family, echoed)
    try report(out, "TCP", family, lines, "lines", text.used(echoed))
    text.clear(echoed)
    try udp_echo(host, family, echoed)
    try report(out, "UDP", family, lenof messages, "datagrams",
               text.used(echoed))
end exchange

--  Say that the loopback address the program was to use is not on this
--  system.
unavailable: (inout out: io.buffered_writer(hosted.system)) -> none =
    io.put(out, "this system has no such loopback address\n") else (problem)
        _ = problem
    end
end unavailable

public main: () -> (code: i32) =
    host := hosted.host()
    mut storage: [512]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage[0..<512])
    defer io.flush(out) else (problem)
        _ = problem
    end
    code = 1
    families: [2]io.address_family = [io.ipv4, io.ipv6]
    for family in families do
        exchange(host, out, family) else (problem)
            --  A system without IPv6 cannot run the second half, which
            --  says so rather than passing over it.
            if problem == io.address_unavailable then unavailable(out) end if
            code = 2
            return
        end
    end for
    io.flush(out) else (problem)
        _ = problem
        return
    end
    code = 42
end main
```

which prints

```text
TCP over 127.0.0.1: the server echoed 3 lines
| one
| two
| hello, world
UDP over 127.0.0.1: the server echoed 2 datagrams
| ping
| hello, datagram
TCP over ::1: the server echoed 3 lines
| one
| two
| hello, world
UDP over ::1: the server echoed 2 datagrams
| ping
| hello, datagram
```

The same `serve`, `tcp_echo`, `udp_echo`, `quoted` and `report` run over
`core/io`'s memory network, beside a memory world, in
`runtime/network-echo-memory`, which writes the same report byte for byte.
The memory network is a machine of loopback addresses in the caller's
buffers: nothing in it waits, so where a real socket would wait it answers
`io.timed_out` at once. The hosted failures each have a fixture of their
own: `runtime/network-refused`, `runtime/network-address-in-use`,
`runtime/network-closed-peer`, in which the client sends until it hears
that its peer has gone and the process lives on, and
`runtime/network-receive-timeout`, in which a receive and an accept each
wait out a 50 ms limit. `platform/posix` gives the same sockets in its own
terms, Unix-domain sockets among them, in `runtime/posix-sockets`.

## Copying a tree

`cp -a` cut down to what Linux, macOS and FreeBSD all keep: a directory
tree copied with each file's bytes, its permission bits and its times,
each directory's, and each symbolic link as a link to the same target,
never followed. The program builds a small tree where it runs, copies it
twice, checks the copy against it, prints a listing of the copy and
removes both; it returns 42 when every check passed.

The walk is the directory listing's: `io.read_entry` lends each name until
the next read, so `entries_of` keeps a copy of each and sorts them. An
entry's kind comes from the listing itself, and a symbolic link is
`io.symbolic_link` there whatever it points to, so the copy never descends
through one. A file is copied into a temporary file beside its
destination, `io.make_temporary`, whose name no other file has: the
hosted provider is its own source of random names, `io.make_temporary(host,
host, directory, buffer)`, and the file is created exclusively, so nothing
already at that name, a symbolic link planted there included, is ever
opened in its place. The bytes go across at their own offsets with
`io.read_at` and `io.write_at`, a block that is all zeros is not written,
and `io.truncate` gives the copy the source's size, so a hole in the source
stays a hole. `io.synchronize` has the system write the data before the
temporary file is closed and `io.rename`d onto the destination, which
replaces a file already there in one step: a program reading the copy
while it is made sees the old file or the new one, never half of either.
A symbolic link is made under a fresh name the same way and renamed onto
its destination.

What the portable concepts do not say is `platform/posix`'s, which the
program imports beside them: `posix.status_at` gives the permission bits,
owner and times the copy keeps, `posix.read_link_at` and
`posix.symbolic_link_at` read and make a link, and `posix.change_mode`,
`posix.change_owner` and `posix.set_times` give them to the temporary
file through its descriptor, `hosted.descriptor_of`. A directory gets its
bits and times after everything in it is copied, since adding an entry
changes a directory's time. What the copy does not keep: the owner, unless
the process is root, since only root may give a file away; the time a file
last changed, which no call sets; extended attributes and access control
lists; that two names are one file, so a file with two names in the source
is two files in the copy; and anything that is neither a file, a directory
nor a link, a socket here, which the copy skips and counts.

Fixture source: `compiler/tests/fixtures/runtime/tree-copy/main.ldn`.

```landin
--  Copy a directory tree as `cp -a` does, keeping what every hosted
--  system keeps: each file's contents, holes and all, its permission bits
--  and its times, each directory's, and each symbolic link as a link to
--  the same target.  Every file and link is made under a temporary name
--  and renamed into place, so a copy over an earlier one replaces each
--  entry in one step.  The program builds the tree it copies where it
--  runs, copies it twice, checks the copy against it and removes both.
import core/cmp
import core/io
import core/mem
import core/sort
import core/text
import hosted/io as hosted
import platform/posix

--  Where the program works, what it copies and where the copy goes.
top: []u8 = "tree-copy-scratch"
source: []u8 = "tree-copy-scratch/source"
copy: []u8 = "tree-copy-scratch/copy"

--  The source's times: midnight UTC on 2000-01-01, and a second later for
--  each entry after the first.
epoch: i64 = 946684800

--  A directory holding more entries than the copy keeps, a name longer
--  than it keeps, and a copy that differs from what it was copied from.
too_many: atom
too_long: atom
differs: atom

--  An entry kept past the read that gave it: a directory lends a name only
--  until its next read.
kept: type = struct
    name: [64]u8
    length: usize
    kind: io.entry_kind
end kept

--  Byte order, as `ls` sorts in the C locale.
before: (left: kept, right: kept) -> (yes: bool) =
    yes = mem.compare(left.name[0..<left.length],
                      right.name[0..<right.length]) == mem.less
end before

kept is cmp.ordered (less: before)

blank: kept = (name: [64 of 0], length: 0, kind: io.special)

--  What a copy did.
tally: type = struct
    files: usize
    links: usize
    directories: usize
    skipped: usize
    replaced: usize
end tally

--  The path NAME in PARENT, or PARENT when NAME is empty, built in INTO.
joined: (parent: []u8, name: []u8, inout into: text.builder)
        -> none ! text.no_space =
    text.clear(into)
    try text.append(into, parent)
    separator: []u8 = if lenof name > 0 then "/" else "" end if
    try text.append(into, separator)
    try text.append(into, name)
end joined

--  The directory PATH lies in.
parent_of: (path: []u8) -> (parent: []u8 from path) =
    mut at: usize = lenof path
    while at > 0 and path[at - 1] <> 47 do
        dec at
    end while
    parent = if at == 0 then "." else path[0..<at - 1] end if
end parent_of

--  Whether the process may read and write any file whatever its
--  permission bits say, as root may: what it can keep and what a
--  read-only file refuses it both differ.
privileged: () -> (yes: bool) =
    yes = posix.effective_user() == posix.user_id(0)
end privileged

--  The entries of the directory PATH, sorted by name, into INTO.
entries_of: (host: hosted.system, path: []u8, into: []mut kept)
            -> (count: usize) ! ... =
    count = 0
    mut buffer: [1024]u8 = zeroed
    mut listing: io.directory =
        try io.open_directory(host, text.host_over(path), buffer[0..<1024])
    defer io.close_directory(host, listing) else (problem)
        _ = problem
    end
    loop do
        item: io.entry = try io.read_entry(host, listing)
        name: []u8 = text.host_bytes(item.name)
        break when lenof name == 0
        fail too_many when count == lenof into
        fail too_long when lenof name > 64
        into[count] = blank
        try mem.copy(into[count].name[0..<64], name)
        into[count].length = lenof name
        into[count].kind = item.kind
        inc count
    end loop
    sort.sort(into[0..<count])
end entries_of

--  Whether every byte of BYTES is zero: a block the copy need not write.
zeros: (bytes: []u8) -> (yes: bool) =
    yes = true
    for byte in bytes do
        if byte <> 0 then yes = false end if
    end for
end zeros

--  Whether anything is at PATH, a link not followed.
present: (host: hosted.system, path: text.host_string) -> (yes: bool) ! ... =
    yes = true
    _ = io.status_of(host, path, false) else (problem)
        fail problem when problem <> io.not_found
        yes = false
        return
    end
end present

--  Copy SOURCE's bytes into TARGET at the same offsets, writing no block
--  that is all zeros, so a hole stays a hole, and give TARGET SOURCE's size
--  and then its owner, when the process may give a file away, its
--  permission bits, which a change of owner may clear, and its times.
filled: (host: hosted.system, input: io.file, target: io.file,
         found: posix.status) -> none ! ... =
    mut block: [4096]u8 = zeroed
    mut offset: u64 = 0
    loop do
        count: usize = try io.read_at(host, input, offset, block[0..<4096])
        break when count == 0
        if not zeros(block[0..<count]) then
            try io.write_at(host, target, offset, block[0..<count])
        end if
        offset += u64(count)
    end loop
    --  A file ending in a hole was never written there: its size makes it.
    try io.truncate(host, target, found.size)
    made: posix.descriptor = hosted.descriptor_of(target)
    if privileged() then
        try posix.change_owner(made, found.user, found.group)
    end if
    try posix.change_mode(made, found.permissions)
    try posix.set_times(made, found.accessed, found.modified)
    try io.synchronize(host, target, true)
end filled

--  Forget a temporary file that will not be renamed into place.
dropped: (host: hosted.system, path: text.host_string) -> none =
    io.remove_file(host, path) else (problem)
        _ = problem
    end
end dropped

--  Copy the file FROM to TO: into a temporary file beside TO, renamed onto
--  TO once it is whole, replacing a file already there in one step.
copy_file: (host: hosted.system, from_path: []u8, to_path: []u8,
            inout done: tally) -> none ! ... =
    found: posix.status = try posix.status_at(posix.working_directory,
                                              text.host_over(from_path),
                                              false)
    input: io.file = try io.open_read(host, text.host_over(from_path))
    defer io.close(host, input) else (problem)
        _ = problem
    end
    mut room: [256]u8 = zeroed
    made: io.temporary =
        try io.make_temporary(host, host, text.host_over(parent_of(to_path)),
                              room[0..<256])
    filled(host, input, made.opened, found) else (problem)
        io.close(host, made.opened) else (ignored)
            _ = ignored
        end
        dropped(host, made.path)
        fail problem
    end
    io.close(host, made.opened) else (problem)
        dropped(host, made.path)
        fail problem
    end
    target: text.host_string = text.host_over(to_path)
    replacing: bool = try present(host, target)
    io.rename(host, made.path, target) else (problem)
        dropped(host, made.path)
        fail problem
    end
    if replacing then inc done.replaced end if
    inc done.files
end copy_file

--  Copy the symbolic link FROM to TO as a link to the same target, made
--  under a fresh name beside TO and renamed onto it.
copy_link: (host: hosted.system, from_path: []u8, to_path: []u8,
            inout done: tally) -> none ! ... =
    found: posix.status = try posix.status_at(posix.working_directory,
                                              text.host_over(from_path),
                                              false)
    mut target_room: [256]u8 = zeroed
    target: text.host_string =
        try posix.read_link_at(posix.working_directory,
                               text.host_over(from_path),
                               target_room[0..<256])
    mut room: [256]u8 = zeroed
    mut name: text.host_string = text.host_over(room[0..<0])
    mut made: bool = false
    for attempt in usize(0)..<io.temporary_tries do
        _ = attempt
        mut bytes: [8]u8 = zeroed
        try io.fill_random(host, bytes[0..<8])
        name = try io.temporary_path(text.host_over(parent_of(to_path)), bytes,
                                     room[0..<256])
        posix.symbolic_link_at(target, posix.working_directory, name)
            else (problem)
            continue when problem == posix.eexist
            fail problem
        end
        made = true
        break
    end for
    fail io.io_failed when not made
    undo dropped(host, name)
    if privileged() then
        try posix.change_owner_at(posix.working_directory, name, found.user,
                                  found.group, false)
    end if
    try posix.set_times_at(posix.working_directory, name, found.accessed,
                           found.modified, false)
    destination: text.host_string = text.host_over(to_path)
    replacing: bool = try present(host, destination)
    try io.rename(host, name, destination)
    if replacing then inc done.replaced end if
    inc done.links
end copy_link

--  Copy the directory FROM to TO, every entry in it and below it, and then
--  its owner when the process may, its permission bits and its times,
--  which adding its entries changed.  A directory already there from an
--  earlier copy is copied into.
copy_directory: (host: hosted.system, from_path: []u8, to_path: []u8,
                 inout done: tally) -> none ! ... =
    found: posix.status = try posix.status_at(posix.working_directory,
                                              text.host_over(from_path),
                                              false)
    io.make_directory(host, text.host_over(to_path)) else (problem)
        fail problem when problem <> io.already_exists
    end
    mut entries: [16]kept = [16 of blank]
    count: usize = try entries_of(host, from_path, entries[0..<16])
    mut from_room: [256]u8 = zeroed
    mut from_child := text.over(from_room[0..<256])
    mut to_room: [256]u8 = zeroed
    mut to_child := text.over(to_room[0..<256])
    for item in entries[0..<count] do
        name: []u8 = item.name[0..<item.length]
        try joined(from_path, name, from_child)
        try joined(to_path, name, to_child)
        match item.kind
            io.regular: try copy_file(host, text.used(from_child),
                                      text.used(to_child), done)
            io.symbolic_link: try copy_link(host, text.used(from_child),
                                            text.used(to_child), done)
            io.subdirectory: try copy_directory(host, text.used(from_child),
                                                text.used(to_child), done)
            io.special: inc done.skipped
        end match
    end for
    target: text.host_string = text.host_over(to_path)
    if privileged() then
        try posix.change_owner_at(posix.working_directory, target, found.user,
                                  found.group, true)
    end if
    try posix.change_mode_at(posix.working_directory, target,
                             found.permissions)
    try posix.set_times_at(posix.working_directory, target, found.accessed,
                           found.modified, true)
    inc done.directories
end copy_directory

--  Remove the tree at PATH, whatever is in it, if it is there.
remove_tree: (host: hosted.system, path: []u8) -> none ! ... =
    found: io.status = io.status_of(host, text.host_over(path), false)
        else (problem)
        fail problem when problem <> io.not_found
        return
    end
    if found.kind <> io.subdirectory then
        try io.remove_file(host, text.host_over(path))
        return
    end if
    mut entries: [16]kept = [16 of blank]
    count: usize = try entries_of(host, path, entries[0..<16])
    mut room: [256]u8 = zeroed
    mut child := text.over(room[0..<256])
    for item in entries[0..<count] do
        try joined(path, item.name[0..<item.length], child)
        try remove_tree(host, text.used(child))
    end for
    try io.remove_directory(host, text.host_over(path))
end remove_tree

--  Make the file NAME in the source holding CONTENTS, with PERMISSIONS.
make_file: (host: hosted.system, name: []u8, contents: []u8,
            permissions: u32) -> none ! ... =
    mut room: [256]u8 = zeroed
    mut path := text.over(room[0..<256])
    try joined(source, name, path)
    opened: io.file = try io.open_write(host, text.host_over(text.used(path)))
    io.write(host, opened, contents) else (problem)
        io.close(host, opened) else (ignored)
            _ = ignored
        end
        fail problem
    end
    try io.close(host, opened)
    try posix.change_mode_at(posix.working_directory,
                             text.host_over(text.used(path)), permissions)
end make_file

--  Make the directory NAME in the source, or the source when it is empty.
make_folder: (host: hosted.system, name: []u8) -> none ! ... =
    mut room: [256]u8 = zeroed
    mut path := text.over(room[0..<256])
    try joined(source, name, path)
    try io.make_directory(host, text.host_over(text.used(path)))
    try posix.change_mode_at(posix.working_directory,
                             text.host_over(text.used(path)), 0o755)
end make_folder

--  Give the source entry NAME the times `epoch` and SECOND seconds, its
--  own when it is a link.
stamp: (name: []u8, second: i64) -> none ! ... =
    mut room: [256]u8 = zeroed
    mut path := text.over(room[0..<256])
    try joined(source, name, path)
    at: posix.time_value = (seconds: epoch + second, nanoseconds: 0)
    try posix.set_times_at(posix.working_directory,
                           text.host_over(text.used(path)), at, at, false)
end stamp

--  The names the source holds, in the order their times are given:
--  everything inside a directory before the directory itself.
stamped: [12][]u8 = ["dangling", "link-to-notes", "link-to-readme",
                     "locked", "notes/todo", "notes", "readme-again",
                     "readme", "run", "sparse.bin", "socket", ""]

--  One mebibyte: how far into sparse.bin its second part lies.
mebibyte: u64 = 1048576

--  Write a sparse file, NAME in the source: four bytes at its start, four
--  more a mebibyte in, and a hole between them that reads as zeros.
make_sparse: (host: hosted.system, name: []u8) -> none ! ... =
    mut room: [256]u8 = zeroed
    mut path := text.over(room[0..<256])
    try joined(source, name, path)
    sparse: text.host_string = text.host_over(text.used(path))
    opened: io.file = try io.open_file(host, sparse, io.creating)
    defer io.close(host, opened) else (problem)
        _ = problem
    end
    try io.write_at(host, opened, u64(0), "head")
    try io.write_at(host, opened, mebibyte, "tail")
    try posix.change_mode(hosted.descriptor_of(opened), 0o644)
end make_sparse

--  Make NAME in the source a symbolic link to TARGET, or with HARD a second
--  name of the source file TARGET.
make_link: (target: []u8, name: []u8, hard: bool) -> none ! ... =
    mut room: [256]u8 = zeroed
    mut path := text.over(room[0..<256])
    try joined(source, name, path)
    made: text.host_string = text.host_over(text.used(path))
    if not hard then
        try posix.symbolic_link_at(text.host_over(target),
                                   posix.working_directory, made)
        return
    end if
    mut other: [256]u8 = zeroed
    mut existing := text.over(other[0..<256])
    try joined(source, target, existing)
    try posix.link_at(posix.working_directory,
                      text.host_over(text.used(existing)),
                      posix.working_directory, made)
end make_link

--  Make NAME in the source a Unix-domain socket's name, which stays when
--  the socket is closed.
make_socket: (name: []u8) -> none ! ... =
    mut room: [256]u8 = zeroed
    mut path := text.over(room[0..<256])
    try joined(source, name, path)
    socket: posix.descriptor = try posix.socket(posix.local, posix.stream)
    defer posix.close(socket) else (problem)
        _ = problem
    end
    at: posix.socket_address =
        try posix.unix_address(text.host_over(text.used(path)))
    try posix.bind(socket, at)
end make_socket

--  Build the tree the program copies: files of each kind of permission, a
--  read-only one, one with two names, a sparse one, symbolic links to a
--  directory, to a file and to nothing, and a socket, which no copy makes.
build: (host: hosted.system) -> none ! ... =
    try remove_tree(host, top)
    try io.make_directory(host, text.host_over(top))
    try make_folder(host, "")
    try make_folder(host, "notes")
    try make_file(host, "readme", "a tree to copy\n", 0o644)
    try make_file(host, "run", "#!/bin/sh\necho copied\n", 0o755)
    try make_file(host, "notes/todo", "keep the times\n", 0o600)
    try make_file(host, "locked", "nobody writes this\n", 0o644)
    mut room: [256]u8 = zeroed
    mut locked := text.over(room[0..<256])
    try joined(source, "locked", locked)
    try io.set_read_only(host, text.host_over(text.used(locked)), true)
    try make_sparse(host, "sparse.bin")
    try make_link("readme", "readme-again", true)
    try make_link("notes", "link-to-notes", false)
    try make_link("readme", "link-to-readme", false)
    try make_link("missing", "dangling", false)
    try make_socket("socket")
    for index in usize(0)..<lenof stamped do
        try stamp(stamped[index], i64(index))
    end for
end build

--  Write PERMISSIONS as four octal digits.
append_mode: (inout into: text.builder, permissions: u32)
             -> none ! text.no_space =
    shifts: [4]u32 = [9, 6, 3, 0]
    for shift in shifts do
        try text.append_byte(into, u8(48 + ((permissions >> shift) & 7)))
    end for
end append_mode

--  One line of the listing for the copied entry at PATH, NAME relative to
--  the copy: its kind, its permission bits, a file's size, its time, and a
--  link's target.
line: (path: []u8, name: []u8, kind: io.entry_kind,
       inout into: text.builder) -> none ! ... =
    found: posix.status = try posix.status_at(posix.working_directory,
                                              text.host_over(path), false)
    text.clear(into)
    if kind == io.symbolic_link then
        mut room: [256]u8 = zeroed
        target: text.host_string =
            try posix.read_link_at(posix.working_directory,
                                   text.host_over(path), room[0..<256])
        seconds: i64 = found.modified.seconds - epoch
        try text.format(into, "link +{} {} -> {}\n",
                        [any(addr seconds), any(addr name), any(addr target)])
        return
    end if
    word: []u8 = if kind == io.subdirectory then "directory" else "file" end if
    try text.append(into, word)
    try text.append(into, " ")
    try append_mode(into, found.permissions)
    if kind == io.regular then
        size: u64 = found.size
        try text.format(into, " {}", [any(addr size)])
    end if
    seconds: i64 = found.modified.seconds - epoch
    try text.format(into, " +{} {}\n", [any(addr seconds), any(addr name)])
end line

--  Write the copy's listing, depth first in byte order: what is at PATH,
--  NAME relative to the copy, and below it.
show: (host: hosted.system, inout out: io.buffered_writer(hosted.system),
       path: []u8, name: []u8, kind: io.entry_kind) -> none ! ... =
    mut room: [300]u8 = zeroed
    mut text_line := text.over(room[0..<300])
    shown: []u8 = if lenof name == 0 then "." else name end if
    try line(path, shown, kind, text_line)
    try io.put(out, text.used(text_line))
    return when kind <> io.subdirectory
    mut entries: [16]kept = [16 of blank]
    count: usize = try entries_of(host, path, entries[0..<16])
    mut path_room: [256]u8 = zeroed
    mut child := text.over(path_room[0..<256])
    mut name_room: [256]u8 = zeroed
    mut child_name := text.over(name_room[0..<256])
    for item in entries[0..<count] do
        entry_name: []u8 = item.name[0..<item.length]
        try joined(path, entry_name, child)
        text.clear(child_name)
        if lenof name > 0 then
            try joined(name, entry_name, child_name)
        else
            try text.append(child_name, entry_name)
        end if
        try show(host, out, text.used(child), text.used(child_name),
                 item.kind)
    end for
end show

--  Whether the copied entry at TO is what was copied from FROM: the same
--  kind, permission bits and time, the same bytes in a file, and the same
--  target in a link.  No name of the copy is a temporary one.
same_entry: (host: hosted.system, from_path: []u8, to_path: []u8,
             kind: io.entry_kind) -> none ! ... =
    original: posix.status = try posix.status_at(posix.working_directory,
                                                 text.host_over(from_path),
                                                 false)
    copied: posix.status = try posix.status_at(posix.working_directory,
                                               text.host_over(to_path), false)
    fail differs when original.kind <> copied.kind
      or original.modified.seconds <> copied.modified.seconds
      or original.modified.nanoseconds <> copied.modified.nanoseconds
    if kind == io.symbolic_link then
        mut first_room: [256]u8 = zeroed
        first: text.host_string =
            try posix.read_link_at(posix.working_directory,
                                   text.host_over(from_path),
                                   first_room[0..<256])
        mut second_room: [256]u8 = zeroed
        second: text.host_string =
            try posix.read_link_at(posix.working_directory,
                                   text.host_over(to_path),
                                   second_room[0..<256])
        fail differs when mem.compare(text.host_bytes(first),
                                      text.host_bytes(second)) <> mem.equal
        return
    end if
    fail differs when original.permissions <> copied.permissions
    return when kind <> io.regular
    fail differs when original.size <> copied.size
    left: io.file = try io.open_read(host, text.host_over(from_path))
    defer io.close(host, left) else (problem)
        _ = problem
    end
    right: io.file = try io.open_read(host, text.host_over(to_path))
    defer io.close(host, right) else (problem)
        _ = problem
    end
    mut first_block: [4096]u8 = zeroed
    mut second_block: [4096]u8 = zeroed
    mut offset: u64 = 0
    loop do
        count: usize = try io.read_at(host, left, offset, first_block[0..<4096])
        other: usize = try io.read_at(host, right, offset,
                                      second_block[0..<4096])
        fail differs when count <> other
          or mem.compare(first_block[0..<count], second_block[0..<count])
             <> mem.equal
        break when count == 0
        offset += u64(count)
    end loop
end same_entry

--  Check the copy at TO against the tree at FROM, entry by entry.
same_tree: (host: hosted.system, from_path: []u8, to_path: []u8)
           -> none ! ... =
    try same_entry(host, from_path, to_path, io.subdirectory)
    mut entries: [16]kept = [16 of blank]
    count: usize = try entries_of(host, to_path, entries[0..<16])
    mut from_room: [256]u8 = zeroed
    mut from_child := text.over(from_room[0..<256])
    mut to_room: [256]u8 = zeroed
    mut to_child := text.over(to_room[0..<256])
    for item in entries[0..<count] do
        name: []u8 = item.name[0..<item.length]
        fail differs when lenof name >= 5
          and mem.compare(name[0..<5], ".tmp-") == mem.equal
        try joined(from_path, name, from_child)
        try joined(to_path, name, to_child)
        if item.kind == io.subdirectory then
            try same_tree(host, text.used(from_child), text.used(to_child))
        else
            try same_entry(host, text.used(from_child), text.used(to_child),
                           item.kind)
        end if
    end for
end same_tree

--  The failure oracles: a read-only file refuses a write, a read past the
--  end of a sparse file gives nothing, and a file with two names in the
--  source is two files in the copy.
oracles: (host: hosted.system) -> none ! ... =
    mut room: [256]u8 = zeroed
    mut path := text.over(room[0..<256])
    try joined(copy, "locked", path)
    locked: text.host_string = text.host_over(text.used(path))
    found: io.status = try io.status_of(host, locked, true)
    fail differs when not found.read_only
    --  A file open only for reading refuses a write whoever writes, root
    --  as well, and the system says why, EBADF.
    reading: io.file = try io.open_read(host, locked)
    mut refused: bool = false
    io.write(host, reading, "overwritten\n") else (problem)
        _ = problem
        refused = hosted.last_errno(host) == posix.number(posix.ebadf)
    end
    try io.close(host, reading)
    fail differs when not refused
    --  Opening it to write is refused by its permission bits, unless the
    --  process is root, whom no permission bit refuses.
    writing: io.open_options = (read: false, write: true, append: false,
                                create: false, exclusive: false,
                                truncate: false)
    if privileged() then
        opened: io.file = try io.open_file(host, locked, writing)
        try io.close(host, opened)
    else
        opened: io.file = io.open_file(host, locked, writing) else (problem)
            fail differs when problem <> io.no_access
            return
        end
        try io.close(host, opened)
        fail differs
    end if
    --  The copy of the sparse file reads zeros in its hole and nothing past
    --  its end.
    mut sparse_room: [256]u8 = zeroed
    mut sparse_path := text.over(sparse_room[0..<256])
    try joined(copy, "sparse.bin", sparse_path)
    sparse: io.file =
        try io.open_read(host, text.host_over(text.used(sparse_path)))
    defer io.close(host, sparse) else (problem)
        _ = problem
    end
    size: io.status = try io.status_of_file(host, sparse)
    mut probe: [16]u8 = zeroed
    past: usize = try io.read_at(host, sparse, size.size + 10, probe[0..<16])
    hole: usize = try io.read_at(host, sparse, u64(500000), probe[0..<16])
    fail differs when size.size <> mebibyte + 4 or past <> 0 or hole <> 16
      or not zeros(probe[0..<16])
    --  Two names of one file in the source, and two files in the copy.
    mut first_room: [256]u8 = zeroed
    mut first_path := text.over(first_room[0..<256])
    try joined(source, "readme", first_path)
    first: posix.status =
        try posix.status_at(posix.working_directory,
                            text.host_over(text.used(first_path)), false)
    mut second_room: [256]u8 = zeroed
    mut second_path := text.over(second_room[0..<256])
    try joined(copy, "readme", second_path)
    second: posix.status =
        try posix.status_at(posix.working_directory,
                            text.host_over(text.used(second_path)), false)
    fail differs when first.links <> 2 or second.links <> 1
end oracles

--  The report's lines: what the copies did, and what the program checked.
counts: utf8 = "{} entries copied twice, {} socket skipped each time\n"
replaced: utf8 = "the second copy replaced {} files and {} links in place\n"
checked: []u8 = """readme has two names in the source and one in the copy
    locked is read-only and refuses a write
    sparse.bin reads as zeros in its hole and as nothing past its end
    """

--  What the two copies did, and what the program checked.
report: (inout out: io.buffered_writer(hosted.system), first: tally,
         second: tally) -> none ! ... =
    mut room: [100]u8 = zeroed
    mut line := text.over(room[0..<100])
    copied: usize = first.files + first.links + first.directories
    try text.format(line, counts,
                    [any(addr copied), any(addr second.skipped)])
    try io.put(out, text.used(line))
    text.clear(line)
    try text.format(line, replaced,
                    [any(addr second.files), any(addr second.links)])
    try io.put(out, text.used(line))
    try io.put(out, checked)
end report

public main: () -> (code: i32) =
    host := hosted.host()
    code = 1
    build(host) else (problem)
        _ = problem
        return
    end
    code = 2
    mut first: tally = (files: 0, links: 0, directories: 0, skipped: 0,
                        replaced: 0)
    copy_directory(host, source, copy, first) else (problem)
        _ = problem
        return
    end
    --  The source changes, and the second copy goes over the first.
    code = 3
    mut second: tally = (files: 0, links: 0, directories: 0, skipped: 0,
                         replaced: 0)
    make_file(host, "readme", "a tree copied twice\n", 0o644) else (problem)
        _ = problem
        return
    end
    stamp("readme", 7) else (problem)
        _ = problem
        return
    end
    copy_directory(host, source, copy, second) else (problem)
        _ = problem
        return
    end
    code = 4
    same_tree(host, source, copy) else (problem)
        _ = problem
        return
    end
    code = 5
    oracles(host) else (problem)
        _ = problem
        return
    end
    code = 6
    mut storage: [512]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage[0..<512])
    defer io.flush(out) else (problem)
        _ = problem
    end
    show(host, out, copy, "", io.subdirectory) else (problem)
        _ = problem
        return
    end
    report(out, first, second) else (problem)
        _ = problem
        return
    end
    io.flush(out) else (problem)
        _ = problem
        return
    end
    code = 7
    remove_tree(host, top) else (problem)
        _ = problem
        return
    end
    code = if first.replaced == 0 and second.replaced == 9
      and first.skipped == 1 then 42 else 8 end if
end main
```

Compiled and run in an empty directory:

```sh
refine compile main.ldn -o tree-copy
./tree-copy
```

it prints

```text
directory 0755 +11 .
link +0 dangling -> missing
link +1 link-to-notes -> notes
link +2 link-to-readme -> readme
file 0444 19 +3 locked
directory 0755 +5 notes
file 0600 15 +4 notes/todo
file 0644 20 +7 readme
file 0644 20 +7 readme-again
file 0755 22 +8 run
file 0644 1048580 +9 sparse.bin
11 entries copied twice, 1 socket skipped each time
the second copy replaced 6 files and 3 links in place
readme has two names in the source and one in the copy
locked is read-only and refuses a write
sparse.bin reads as zeros in its hole and as nothing past its end
```

and leaves the directory as it found it. The source's times are set to
the first seconds of 2000, which each line gives after a `+`; `readme` and
`readme-again` are two names of one file in the source, which the program
rewrites before the second copy, so both copies hold its new text.

The program checks what a copy could get wrong. The second copy renames
onto every name the first made, and each renamed entry holds what the
source does. The listing gives `link-to-notes` as a link, not followed,
and the copy makes it a link to the same target. `locked`, read-only in
the source and so in the copy, refuses a write through a descriptor opened
only to read, EBADF, whoever the process is, and refuses to be opened for
writing unless the process is root, whom no permission bit refuses; the
program checks whichever the process is. A read of `sparse.bin` past its
end gives nothing, and one in its hole gives zeros.
`runtime/core-io-file-system` holds every entry of `io.file_system` and
`io.terminals` to its own failures, `runtime/posix-file-system`,
`runtime/posix-locks`, `runtime/posix-terminals` and
`runtime/posix-accounts` do the same for `platform/posix`, and
`runtime/volume-memory` runs `core/io`'s memory volume, the fake of the
whole concept.
