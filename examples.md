# Running examples

These are complete Landin programs that the bootstrap compiler accepts,
lowers, emits, links and runs today on Linux x86-64 and Darwin arm64. They are the same sources
the runtime suite executes. Each returns 42 only after checking its result,
except the word count and the line numberer, tools that read their standard
input and return 0.

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

FizzBuzz writes its conventional one hundred lines, and the three Benchmark
Game programs write their official correctness output; the next seven programs
print nothing. Status 42 means the checks in `main` passed, and any other
returned status makes the runtime fixture fail. The word count prints the
totals for whatever its standard input holds and returns 0, and its fixture
gives it an input of its own and holds the line it prints; the line numberer
does the same with the lines it numbers. The directory
listing builds a directory where it runs, prints its listing, removes it
and returns 42, and the shell runner prints its report of a shell it ran
and returns 42. The gate checks all eight output oracles and all fifteen
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

FizzBuzz is the familiar remainder-and-branching exercise from [Rosetta Code](https://rosettacode.org/wiki/FizzBuzz). The classifier remains a small pure function. A separate hosted presentation layer traverses one through 100, writes contextual text literals through `core/io`, and formats the ordinary numbers with `core/text`; the fixture checks both its exact output and its aggregate tally.

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

write_number: (host: hosted.system, stream: io.file, value: u32)
              -> none ! io.io_failed | text.no_space =
    mut line: [4]u8 = zeroed
    mut used: usize = try text.write_u32(line[0..<4], 0, value)
    used = try text.write_byte(line[0..<4], used, 10)
    try io.write(host, stream, line[0..<used])
end write_number

write_line: (host: hosted.system, stream: io.file,
             kind: fizzbuzz_kind, value: u32)
            -> none ! io.io_failed | text.no_space =
    match kind
        fizz: try io.write(host, stream, "Fizz\n")
        buzz: try io.write(host, stream, "Buzz\n")
        fizz_buzz: try io.write(host, stream, "FizzBuzz\n")
        number: try write_number(host, stream, value)
    end match
end write_line

run: (host: hosted.system)
     -> (result: counts) ! io.io_failed | text.no_space =
    result = zeroed
    stream: io.file = io.out(host)
    first: u32 = 1
    last: u32 = 100
    for value in first..last do
        kind: fizzbuzz_kind = classify(value)
        tally(result, kind)
        try write_line(host, stream, kind, value)
    end for
end run

public main: () -> (code: i32) =
    host := hosted.host()
    result := run(host) else (problem)
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
algorithm. It uses the official correctness input, seven, and enumerates every
permutation through fixed caller-owned arrays. The output oracle pins both the
signed checksum, 228, and the maximum flip count, 16. The performance input,
twelve, is deliberately not part of the test gate.

Fixture source: `compiler/tests/fixtures/runtime/benchmark-game-fannkuch-redux/main.ldn`.

```landin
--  A direct single-threaded implementation of the Benchmark Game workload.
--  Its correctness input is seven; the larger performance input is not a gate.
import core/io
import core/text
import hosted/io as hosted

score: type = struct
    checksum: i32
    maximum: u32
end score

reverse_prefix: (inout values: [7]u8) -> none =
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

fannkuch: () -> (result: score) =
    mut order: [7]u8 = [0, 1, 2, 3, 4, 5, 6]
    mut rotations: [7]usize = zeroed
    mut depth: usize = lenof order
    mut permutation_index: u32 = 0
    result = zeroed

    loop do
        while depth > 1 do
            rotations[depth - 1] = depth
            dec depth
        end while

        if order[0] <> 0 then
            mut permutation: [7]u8 = order
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
            if depth == lenof order then
                return
            end if

            first: u8 = order[0]
            mut at: usize = 0
            while at < depth do
                order[at] = order[at + 1]
                inc at
            end while
            order[depth] = first
            dec rotations[depth]
            break when rotations[depth] > 0
            inc depth
        end loop
        inc permutation_index
    end loop
end fannkuch

write_u32: (host: hosted.system, stream: io.file, value: u32)
           -> none ! io.io_failed | text.no_space =
    mut digits: [10]u8 = zeroed
    used: usize = try text.write_u32(digits[0..<10], 0, value)
    try io.write(host, stream, digits[0..<used])
end write_u32

write_score: (host: hosted.system, value: score)
             -> none ! io.io_failed | text.no_space =
    stream: io.file = io.out(host)
    try write_u32(host, stream, u32(value.checksum))
    try io.write(host, stream, "\nPfannkuchen(7) = ")
    try write_u32(host, stream, value.maximum)
    try io.write(host, stream, "\n")
end write_score

public main: () -> (code: i32) =
    value: score = fannkuch()
    host := hosted.host()
    write_score(host, value) else (problem)
        _ = problem
        code = 1
        return
    end

    if value.checksum == 228 and value.maximum == 16 then
        code = 42
    else
        code = 1
    end if
end main
```

## Benchmark Game Mandelbrot

The Benchmark Game's
[Mandelbrot](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/mandelbrot.html)
workload plots the complex rectangle from `-1.5-i` through `0.5+i`. This port
uses the official 200-by-200 correctness input, performs the scalar `f64`
iteration in its specified order, packs membership bits most-significant
first, and writes the exact 5,011-byte binary PBM result. Its internal count of
15,899 set pixels gives failures a useful scalar symptom as well.

Fixture source: `compiler/tests/fixtures/runtime/benchmark-game-mandelbrot/main.ldn`.

```landin
--  The Benchmark Game correctness image is 200 by 200.  Each membership bit
--  is packed most-significant first and written in binary PBM format.
import core/io
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

render: (host: hosted.system) -> (members: u32) ! io.io_failed =
    size: usize = 200
    coordinate_size: f64 = f64(size)
    bytes_per_row: usize = size / 8
    bits_per_byte: usize = 8
    first: usize = 0
    mut real_coordinates: [200]f64 = zeroed
    stream: io.file = io.out(host)
    mut row_bytes: [25]u8 = zeroed
    members = 0
    for pixel_x in first..<size do
        real_coordinates[pixel_x] = 2.0 * f64(pixel_x) / coordinate_size - 1.5
    end for

    try io.write(host, stream, "P4\n200 200\n")
    for row in first..<size do
        imaginary_coordinate: f64 = 2.0 * f64(row) / coordinate_size - 1.0
        for byte_column in first..<bytes_per_row do
            mut packed: u8 = 0
            for offset in first..<bits_per_byte do
                packed <<= 1
                pixel_x: usize = byte_column * bits_per_byte + offset
                if in_set(real_coordinates[pixel_x], imaginary_coordinate) then
                    packed |= 1
                    inc members
                end if
            end for
            row_bytes[byte_column] = packed
        end for
        output: []u8 = row_bytes[0..<lenof row_bytes]
        try io.write(host, stream, output)
    end for
end render

public main: () -> (code: i32) =
    host := hosted.host()
    members := render(host) else (problem)
        _ = problem
        code = 1
        return
    end

    if members == 15899 then
        code = 42
    else
        code = 1
    end if
end main
```

## Benchmark Game FASTA

The Benchmark Game's
[FASTA](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/fasta.html)
workload combines cyclic copying with weighted random selection. This port
uses the official correctness input, 1,000: it writes 2,000 ALU nucleotides,
3,000 IUB symbols, and 5,000 human-frequency symbols in 60-byte lines. It
builds both cumulative-probability tables at runtime, uses the specified naïve
LCG once per random nucleotide, and checks its final seed as well as the exact
10,245-byte output.

Fixture source: `compiler/tests/fixtures/runtime/benchmark-game-fasta/main.ldn`.

```landin
--  The official correctness input is 1000.  The probability search remains
--  linear and the naïve LCG advances once for every random nucleotide.
import core/io
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

write_repeated: (host: hosted.system, stream: io.file,
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
        output: []u8 = line[0..<width + 1]
        try io.write(host, stream, output)
        emitted += width
    end while
end write_repeated

write_random: (host: hosted.system, stream: io.file, symbols: []u8,
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
        output: []u8 = line[0..<width + 1]
        try io.write(host, stream, output)
        emitted += width
    end while
end write_random

run: (host: hosted.system) -> (final_seed: u32) ! io.io_failed =
    sample_size: usize = 1000
    stream: io.file = io.out(host)
    mut seed: u32 = 42
    mut iub: [15]f64 = iub_probabilities
    mut human: [4]f64 = human_probabilities
    iub_write: []mut f64 = iub[0..<lenof iub]
    human_write: []mut f64 = human[0..<lenof human]
    make_cumulative(iub_write)
    make_cumulative(human_write)
    iub_read: []f64 = iub[0..<lenof iub]
    human_read: []f64 = human[0..<lenof human]

    try io.write(host, stream, ">ONE Homo sapiens alu\n")
    try write_repeated(host, stream, alu, sample_size * 2)
    try io.write(host, stream, ">TWO IUB ambiguity codes\n")
    try write_random(host, stream, iub_symbols, iub_read,
                     seed, sample_size * 3)
    try io.write(host, stream, ">THREE Homo sapiens frequency\n")
    try write_random(host, stream, human_symbols, human_read,
                     seed, sample_size * 5)
    final_seed = seed
end run

public main: () -> (code: i32) =
    host := hosted.host()
    final_seed := run(host) else (problem)
        _ = problem
        code = 1
        return
    end

    if final_seed == 111466 then
        code = 42
    else
        code = 1
    end if
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
shell's third line shows. An argument, a name and a value are host strings
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

The report goes to standard output through a buffered writer, flushed at
the end and by a `defer` on every other way out [1100], and the program
returns 42 when the shell exited with the 3 its script ends with.

Fixture source: `compiler/tests/fixtures/runtime/run-shell/main.ldn`.

```landin
--  Run a shell with an environment built for it, read what it writes to
--  its output and its errors while it runs, and report what it said, what
--  it complained of and how it ended.  The report goes through a buffered
--  writer, flushed on every way out.
import core/io
import core/text
import hosted/io as hosted

--  What the shell runs: it says what its environment holds, complains
--  once and ends with code 3.  Its environment is only what the program
--  gives it, so the HOME the program itself has is not among it.
script: []u8 = """
    printf 'NAME=%s\n' "$NAME"
    printf 'GREETING=%s\n' "$GREETING"
    printf 'HOME is %s\n' "${HOME-not set}"
    echo 'something went wrong' >&2
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

--  Report what the child wrote and how it ended.
report: (provider: type is io.writer, inout out: io.buffered_writer(provider),
         output: []u8, errors: []u8, ended: io.ending) -> none ! ... =
    try io.put(out, "the shell said:\n")
    try quoted(out, output)
    try io.put(out, "and complained:\n")
    try quoted(out, errors)
    mut room: [48]u8 = zeroed
    mut line := text.over(room[0..<48])
    match ended.how
        io.exited(code): try text.format(line, "and exited with code {}\n",
                                         [any(addr code)])
        io.signalled: try text.append(line, "and was ended by a signal\n")
    end match
    try io.put(out, text.used(line))
end report

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
    variables: [2]io.variable =
        [(name: text.host_over("NAME"), value: text.host_over("landin")),
         (name: text.host_over("GREETING"),
          value: text.host_over("hello, world"))]
    started := io.spawn(host, text.host_over("/bin/sh"),
                        arguments[0..<2], variables[0..<2],
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
    report(out, text.used(output), text.used(errors), ended) else (problem)
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
```

The same `capture` and `report` run over `core/io`'s scripted programs,
beside a memory world, in `runtime/run-shell-memory`, which writes the same report
byte for byte and injects the fake's failures. A program that is not there
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
