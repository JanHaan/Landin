# Running examples

These are complete Landin programs that the bootstrap compiler accepts,
lowers, emits, links and runs today on Linux x86-64. They are the same sources
the runtime suite executes, and each returns 42 only after checking its result.

The implemented kernel now includes recursive functions [1800], aggregate
parameters and results, fixed arrays [0520], slices [0570], variants [0680],
pattern matching [1210], and `inout` parameters [0900]. It does not yet include
loops, text or hosted output. These examples therefore recurse where an
ordinary implementation would loop and report success through their process
status. That is an honest picture of the language the compiler runs today.

## Compile and run

After building `refine` and putting it on `PATH`, compile any source shown
below. For example:

```sh
refine --target=linux-x86-64 --emit=exe \
  -o /tmp/landin-fizzbuzz \
  compiler/tests/fixtures/runtime/fizzbuzz/main.ldn
/tmp/landin-fizzbuzz
test $? -eq 42
```

The programs print nothing. Status 42 means the checks in `main` passed; any
other returned status makes the runtime fixture fail. The authoritative Linux
gate builds and runs all seven on every push.

## FizzBuzz

FizzBuzz is the familiar remainder-and-branching exercise from [Rosetta Code](https://rosettacode.org/wiki/FizzBuzz). The current kernel has neither text nor hosted output, so this version computes the canonical classification for one through 100, tallies each atom, and checks representative values. Once text and I/O arrive, the classifier can remain unchanged and a presentation layer can print the traditional lines.

Fixture source: `compiler/tests/fixtures/runtime/fizzbuzz/main.ldn`.

```landin
--  The current hosted kernel cannot print the traditional words yet, so this
--  program computes and checks the same classification for one through 100.
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

tally: (inout result: counts, n: u32) -> none =
    return when n > 100

    match classify(n)
        fizz: result.fizz_only = result.fizz_only + 1
        buzz: result.buzz_only = result.buzz_only + 1
        fizz_buzz: result.both = result.both + 1
        number: result.ordinary = result.ordinary + 1
    end match
    tally(result, n + 1)
end tally

public main: () -> (code: i32) =
    mut result: counts = zeroed
    tally(result, 1)

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

Euclid's algorithm is a compact second example of recursion. Unlike Fibonacci, every call carries the useful state forward: the former divisor and its remainder. The checks include either zero position, a coprime pair, and the classic 1071/462 example from the [Rosetta Code task](https://rosettacode.org/wiki/Greatest_common_divisor).

Fixture source: `compiler/tests/fixtures/runtime/greatest-common-divisor/main.ldn`.

```landin
--  Euclid's algorithm repeatedly replaces a pair by the divisor and remainder.
--  The recursion terminates when that remainder reaches zero.
gcd: (a: u32, b: u32) -> (result: u32) =
    if b == 0 then
        result = a
    else
        result = gcd(b, a % b)
    end if
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

Insertion sort grows a sorted prefix and moves an out-of-order value left through adjacent swaps. The public operation now accepts caller-owned aggregate storage through `inout`; its recursive helpers use a writable slice instead of hiding the input in module state.

Fixture source: `compiler/tests/fixtures/runtime/insertion-sort/main.ldn`.

```landin
--  The public operation accepts caller-owned storage through inout; recursive
--  helpers work through a writable slice because loops are not implemented yet.
insert_at: (values: []mut i32, index: usize) -> none =
    return when index == 0

    previous: usize = index - 1
    if values[previous] > values[index] then
        saved: i32 = values[previous]
        values[previous] = values[index]
        values[index] = saved
        insert_at(values, previous)
    end if
end insert_at

insertion_sort_from: (values: []mut i32, index: usize) -> none =
    return when index >= lenof values
    insert_at(values, index)
    insertion_sort_from(values, index + 1)
end insertion_sort_from

insertion_sort: (inout values: [8]i32) -> none =
    view: []mut i32 = values[0..<lenof values]
    insertion_sort_from(view, 1)
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

Binary search narrows a half-open range over a read-only slice. Its answer is a variant rather than a sentinel: either `found(index)` or `missing`. The fixture checks the first, an interior and the last element, plus absent values in nonempty and empty inputs. See the corresponding [Rosetta Code task](https://rosettacode.org/wiki/Binary_search).

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

search_range: (values: []i32, needle: i32,
               left: usize, right: usize) -> (result: search_result) =
    if left >= right then
        result = (kind: missing)
    else
        middle: usize = left + (right - left) / 2
        if values[middle] == needle then
            result = (kind: found(index: middle))
        elsif values[middle] < needle then
            result = search_range(values, needle, middle + 1, right)
        else
            result = search_range(values, needle, left, middle)
        end if
    end if
end search_range

search: (values: []i32, needle: i32) -> (result: search_result) =
    result = search_range(values, needle, 0, lenof values)
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

The sieve exercises caller-owned fixed storage, writable and read-only slices, computed indexing, zeroed initialization, and nested recursive traversals. It marks composites through 100 and verifies both the prime count and boundary values. This is the bounded-array form of the [Rosetta Code task](https://rosettacode.org/wiki/Sieve_of_Eratosthenes).

Fixture source: `compiler/tests/fixtures/runtime/sieve-of-eratosthenes/main.ldn`.

```landin
--  The sieve mutates caller-owned storage through a writable slice.  Computed
--  indexing marks composites, while recursion supplies the two traversals.
mark_multiples: (composite: []mut bool,
                 multiple: usize, step: usize) -> none =
    return when multiple >= lenof composite
    composite[multiple] = true
    mark_multiples(composite, multiple + step, step)
end mark_multiples

sieve_from: (composite: []mut bool, candidate: usize) -> none =
    return when candidate >= lenof composite

    if not composite[candidate] then
        mark_multiples(composite, candidate + candidate, candidate)
    end if
    sieve_from(composite, candidate + 1)
end sieve_from

count_primes: (values: []bool, index: usize) -> (result: u32) =
    if index >= lenof values then
        result = 0
    elsif values[index] then
        result = count_primes(values, index + 1)
    else
        result = 1 + count_primes(values, index + 1)
    end if
end count_primes

sieve: (inout composite: [101]bool) -> none =
    view: []mut bool = composite[0..<lenof composite]
    view[0] = true
    view[1] = true
    sieve_from(view, 2)
end sieve

public main: () -> (code: i32) =
    mut composite: [101]bool = zeroed
    sieve(composite)
    view: []bool = composite[0..<lenof composite]

    if count_primes(view, 0) == 25
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

encode_from: (input: []i32, output: []mut run,
              read_at: usize, write_at: usize) -> (used: usize) =
    if read_at >= lenof input then
        used = write_at
    elsif write_at > 0
      and output[write_at - 1].value == input[read_at]
    then
        output[write_at - 1].count = output[write_at - 1].count + 1
        used = encode_from(input, output, read_at + 1, write_at)
    else
        output[write_at] = run(value: input[read_at], count: 1)
        used = encode_from(input, output, read_at + 1, write_at + 1)
    end if
end encode_from

encode: (input: []i32, output: []mut run) -> (used: usize) =
    used = encode_from(input, output, 0, 0)
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

Merge sort remains the larger divide-and-conquer example. It recursively sorts two half-open ranges, copies each range into a work array, then merges the sorted runs back into the input. It intentionally retains module storage: contrasting it with the newer insertion-sort interface makes the kernel's progression visible.

Fixture source: `compiler/tests/fixtures/runtime/merge-sort/main.ldn`.

```landin
--  Merge sort gives the recursive kernel a divide-and-conquer example.  Until
--  aggregate parameters arrive, the input and work area are module storage.
mut values: [8]i32 = [-12, 5, 0, 99, 5, 2, -3, 18]
mut work: [8]i32

copy_to_work: (index: usize, right: usize) -> none =
    if index < right then
        work[index] = values[index]
        copy_to_work(index + 1, right)
    end if
end copy_to_work

merge_from: (destination: usize, left_at: usize, middle: usize,
             right_at: usize, right: usize) -> none =
    return when destination >= right

    if left_at < middle then
        if right_at >= right then
            values[destination] = work[left_at]
            merge_from(destination + 1, left_at + 1, middle,
                       right_at, right)
        elsif work[left_at] <= work[right_at] then
            values[destination] = work[left_at]
            merge_from(destination + 1, left_at + 1, middle,
                       right_at, right)
        else
            values[destination] = work[right_at]
            merge_from(destination + 1, left_at, middle,
                       right_at + 1, right)
        end if
    else
        values[destination] = work[right_at]
        merge_from(destination + 1, left_at, middle,
                   right_at + 1, right)
    end if
end merge_from

merge_sort_range: (left: usize, right: usize) -> none =
    if right - left > 1 then
        middle: usize = left + (right - left) / 2
        merge_sort_range(left, middle)
        merge_sort_range(middle, right)
        copy_to_work(left, right)
        merge_from(left, left, middle, middle, right)
    end if
end merge_sort_range

public main: () -> (code: i32) =
    merge_sort_range(0, lenof values)

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
