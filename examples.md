# Running examples

These are complete Landin programs that the bootstrap compiler accepts,
lowers, emits, links and runs today on Linux x86-64. They are the same sources
the runtime suite executes, and each returns 42 only after checking its result.

The implemented hosted language includes aggregate parameters and results,
fixed arrays [0520], slices [0570], variants [0680], pattern matching [1210],
`inout` parameters [0900], loops and traversal [1130] [1140] [1150],
value-producing loop exits [1190], contextual text literals [0260], and
floating-point arithmetic [0170] [0210]. These examples use iteration where
the algorithm calls for it; merge sort keeps only its natural
divide-and-conquer recursion.

## Compile and run

After building `refine` and putting it on `PATH`, compile any source shown
below. For example:

```sh
refine --root=. --target=linux-x86-64 --emit=exe \
  -o /tmp/landin-fizzbuzz \
  compiler/tests/fixtures/runtime/fizzbuzz
/tmp/landin-fizzbuzz
test $? -eq 42
```

FizzBuzz writes its conventional one hundred lines, and the three Benchmark
Game programs write their official correctness output; the other six programs
print nothing. Status 42 means the checks in `main` passed, and any other
returned status makes the runtime fixture fail. The authoritative Linux gate
checks all four output oracles and builds and runs all ten on every push.

## FizzBuzz

FizzBuzz is the familiar remainder-and-branching exercise from [Rosetta Code](https://rosettacode.org/wiki/FizzBuzz). The classifier remains a small pure function. A separate hosted presentation layer traverses one through 100, writes contextual text literals through `core/io`, and formats the ordinary numbers; the fixture checks both its exact output and its aggregate tally.

Fixture source: `compiler/tests/fixtures/runtime/fizzbuzz/main.ldn`.

```landin
--  The classifier stays independent of presentation; the hosted entry prints
--  the traditional lines and checks the complete tally for one through 100.
import core/io

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

write_number: (inout host: io.system, stream: io.file, value: u32)
              -> none ! io.io_failed =
    mut digits: [3]u8 = zeroed
    mut start: usize = lenof digits
    mut remaining: u32 = value
    loop do
        dec start
        digits[start] = u8(remaining % 10) + 48
        remaining = remaining / 10
        break when remaining == 0
    end loop
    output: []u8 = digits[start..<lenof digits]
    try io.write(host, stream, output)
    try io.write(host, stream, "\n")
end write_number

write_line: (inout host: io.system, stream: io.file,
             kind: fizzbuzz_kind, value: u32) -> none ! io.io_failed =
    match kind
        fizz: try io.write(host, stream, "Fizz\n")
        buzz: try io.write(host, stream, "Buzz\n")
        fizz_buzz: try io.write(host, stream, "FizzBuzz\n")
        number: try write_number(host, stream, value)
    end match
end write_line

run: (inout host: io.system) -> (result: counts) ! io.io_failed =
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
    mut host := io.host()
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
insertion_sort: (inout values: [8]i32) -> none =
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

The sieve exercises caller-owned fixed storage, writable and read-only slices, computed indexing, zeroed initialization, and nested traversal. It marks composites through 100 and verifies both the prime count and boundary values. This is the bounded-array form of the [Rosetta Code task](https://rosettacode.org/wiki/Sieve_of_Eratosthenes).

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
        if not view[candidate] then
            mut multiple: usize = candidate + candidate
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

write_u32: (inout host: io.system, stream: io.file, value: u32)
           -> none ! io.io_failed =
    mut digits: [10]u8 = zeroed
    mut start: usize = lenof digits
    mut remaining: u32 = value
    loop do
        dec start
        digits[start] = u8(remaining % 10) + 48
        remaining = remaining / 10
        break when remaining == 0
    end loop
    output: []u8 = digits[start..<lenof digits]
    try io.write(host, stream, output)
end write_u32

write_score: (inout host: io.system, value: score)
             -> none ! io.io_failed =
    stream: io.file = io.out(host)
    try write_u32(host, stream, u32(value.checksum))
    try io.write(host, stream, "\nPfannkuchen(7) = ")
    try write_u32(host, stream, value.maximum)
    try io.write(host, stream, "\n")
end write_score

public main: () -> (code: i32) =
    value: score = fannkuch()
    mut host := io.host()
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

in_set: (pixel_x: usize, pixel_y: usize, size: usize)
        -> (member: bool) =
    real_coordinate: f64 = 2.0 * f64(pixel_x) / f64(size) - 1.5
    imaginary_coordinate: f64 = 2.0 * f64(pixel_y) / f64(size) - 1.0
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

render: (inout host: io.system) -> (members: u32) ! io.io_failed =
    size: usize = 200
    bytes_per_row: usize = size / 8
    bits_per_byte: usize = 8
    first: usize = 0
    stream: io.file = io.out(host)
    mut byte: [1]u8 = zeroed
    members = 0

    try io.write(host, stream, "P4\n200 200\n")
    for row in first..<size do
        for byte_column in first..<bytes_per_row do
            mut packed: u8 = 0
            for offset in first..<bits_per_byte do
                packed <<= 1
                pixel_x: usize = byte_column * bits_per_byte + offset
                if in_set(pixel_x, row, size) then
                    packed |= 1
                    inc members
                end if
            end for
            byte[0] = packed
            output: []u8 = byte[0..<lenof byte]
            try io.write(host, stream, output)
        end for
    end for
end render

public main: () -> (code: i32) =
    mut host := io.host()
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

write_repeated: (inout host: io.system, stream: io.file,
                 source: []u8, count: usize) -> none ! io.io_failed =
    mut line: [60]u8 = zeroed
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
        output: []u8 = line[0..<width]
        try io.write(host, stream, output)
        try io.write(host, stream, "\n")
        emitted += width
    end while
end write_repeated

write_random: (inout host: io.system, stream: io.file, symbols: []u8,
               cumulative: []f64, inout seed: u32, count: usize)
              -> none ! io.io_failed =
    mut line: [60]u8 = zeroed
    mut emitted: usize = 0
    first: usize = 0

    while emitted < count do
        width: usize = width_for(count - emitted)
        for at in first..<width do
            random: f64 = next_random(seed)
            line[at] = select_symbol(symbols, cumulative, random)
        end for
        output: []u8 = line[0..<width]
        try io.write(host, stream, output)
        try io.write(host, stream, "\n")
        emitted += width
    end while
end write_random

run: (inout host: io.system) -> (final_seed: u32) ! io.io_failed =
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
    mut host := io.host()
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
