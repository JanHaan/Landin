# Running examples

Complete Landin programs you can copy, compile and run. Two short lessons
on printing and on failures come first, with a small tool that counts the
lines of the file you name. Then come the classic exercises and a program
that puts the language's main ideas together, then two small tools that
read their input, then larger tools that use processes, the network and
the file system, shortest first. Last come the Benchmark Game ports used
to compare Landin with other languages. Each section names the tour
entries it leans on, such as [0570], so you can read up on anything new.

## Compile and run

Install `refine` as [the README](README.md#installing) describes. Copy a
program into a file called `main.ldn` in a directory of its own, then
compile and run it there:

```sh
refine compile main.ldn -o fizzbuzz
./fizzbuzz
```

Every program prints what it computes and returns 0. What it prints is
shown under its listing. A program that reads its standard input or takes
an argument says so in its section. `refine` compiles for the computer it
runs on unless `--target` names another.

Every program here is compiled and run, and what it prints is checked, on
Linux, macOS and FreeBSD. The `Fixture source:` line above each listing
says where the program lives in the repository.

## Printing formatted values

The everyday way to print: gather the output in a buffered writer and fill
the `{}` placeholders of a template with values of any type.

- `io.buffered_over` makes the writer over a buffer in `main`'s frame.
- `io.format` takes the template and an inline list of the values, each
  written `any(addr value)` [1370] [1380].
- `defer io.flush(out) else none` writes what is left on the way out of
  `main` [1100] [1030]. Without it, the waiting bytes are never written.

Integers, `bool`, `utf8`, `[]u8` and host strings format themselves. Write
`{{` or `}}` for a brace. The template is checked against its values when
it runs, and a mismatch is the failure `text.invalid_format`.

A float has no `{}` of its own yet. The last lines show what to write
today: scale the value to a whole number of tenths and print the whole
part and the tenth as two integers. A conversion to an integer truncates
toward zero [0310], so adding 0.5 first rounds.

`io.format` formats each line straight into the buffer, so a line larger
than the whole buffer fails with `text.no_space`. The deferred flush
drops a failure without a word. A program that must know its output
arrived flushes once more at the end and handles that call's failure,
`io.flush(out) else (problem) ... end`, as Word count below does.

Fixture source: `compiler/tests/fixtures/runtime/example-formatted-output/main.ldn`.

```landin
--  Values of different types printed into one line each, through a
--  buffered writer that gathers the lines and writes them together.
import core/io
import hosted/system

person: type = struct
    name: utf8
    born: u32
    died: u32
end person

public main: () -> (code: i32) =
    host := system.new()
    --  The lines wait in this buffer and are written when it fills, and
    --  the deferred flush writes what is left on the way out of main.
    mut storage: [256]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none

    people: [3]person = [(name: "Ada Lovelace", born: 1815, died: 1852),
                         (name: "Grace Hopper", born: 1906, died: 1992),
                         (name: "Peter Landin", born: 1930, died: 2009)]
    mut lived: u32 = 0
    for someone in people do
        io.format(out, "{} was born in {} and died in {}.\n",
                  [any(addr someone.name), any(addr someone.born),
                   any(addr someone.died)]) else none
        lived += someone.died - someone.born
    end for

    count: usize = lenof people
    io.format(out, "{} people in all.\n", [any(addr count)]) else none

    --  A float has no `{}` of its own: scale it to a whole number of
    --  tenths, rounding, and print the whole part and the tenth apart.
    average: f64 = f64(lived) / f64(count)
    tenths: u64 = u64(average * 10.0 + 0.5)
    whole: u64 = tenths / 10
    tenth: u64 = tenths % 10
    io.format(out, "They lived {}.{} years on average.\n",
              [any(addr whole), any(addr tenth)]) else none
    code = 0
end main
```

It prints

```text
Ada Lovelace was born in 1815 and died in 1852.
Grace Hopper was born in 1906 and died in 1992.
Peter Landin was born in 1930 and died in 2009.
3 people in all.
They lived 67.3 years on average.
```

## Reporting a failure in words

A failure is an atom [0630] [0940]. To tell a person what went wrong,
`failure.words` from `core/failure` gives a short phrase for every atom
the library fails with.

- `percent` passes a parse failure on with `try` [0960], and reports a
  value over 100 as the library's `text.number_overflow` with `fail`
  [0970].
- `main` handles each failure with `else (problem)` [1030] and hands
  `problem` to `report`, whose parameter `failure.reason` takes any of the
  library's atoms.
- A program's own atoms have no phrase in `core/failure`. To word one,
  `match` the failure: an arm for each of your own atoms gives its phrase,
  and a last arm `_ (rest)` hands the library's atoms that remain to
  `failure.words(rest)` [1210].

A real tool writes these lines to standard error, `io.err(host)`, and
returns 1, as the next program does.

Fixture source: `compiler/tests/fixtures/runtime/example-failure-words/main.ldn`.

```landin
--  Turn a failure into words for a person: core/failure has a short phrase
--  for every atom the library fails with.
import core/failure
import core/io
import core/text
import hosted/system

--- The percentage written in `given`, a whole number from 0 to 100.
percent: (given: utf8) -> (value: u8)
         ! text.invalid_number | text.number_overflow =
    value = try text.parse_u8(text.bytes(given))
    fail text.number_overflow when value > 100
end percent

--- One line for a person: what was being done, a colon, and why it failed.
report: (inout out: io.buffered_writer(system.host), subject: []u8,
         problem: failure.reason) -> none =
    reason: []u8 = failure.words(problem)
    io.format(out, "{}: {}\n", [any(addr subject), any(addr reason)])
        else none
end report

public main: () -> (code: i32) =
    host := system.new()
    mut storage: [256]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none
    code = 0

    inputs: [3]utf8 = ["75", "250", "half"]
    for given in inputs do
        value := percent(given) else (problem)
            report(out, text.bytes(given), problem)
            continue
        end
        io.format(out, "{}: {} per cent\n", [any(addr given), any(addr value)])
            else none
    end for

    path: []u8 = "missing-settings.conf"
    file := io.open_read(host, text.host_over(path)) else (problem)
        report(out, path, problem)
        return
    end
    defer io.close(host, file) else none
    io.format(out, "{}: opened\n", [any(addr path)]) else none
end main
```

It prints

```text
75: 75 per cent
250: number out of range
half: not a number
missing-settings.conf: not found
```

## Counting lines in a named file

`wc -l` for one file: the program opens the file its first argument names,
counts its lines and prints the count. When something fails, it says what
in words on standard error and returns 1.

- `io.argument_at(host, 0)` lends the first argument as a host string, the
  bytes the system gave [1660]. With no argument it fails, and the program
  prints how to use it.
- `count_lines` declares its failures as `! ...`, which lets the compiler
  infer the set from every `fail` and `try` in the body. Only a routine
  that is not `public` may leave its set to the compiler [0960].
- `io.lines_over` makes a line reader over a buffer in the routine's frame,
  and `io.read_line` lends each line [0790] [0800]. A line too long for the
  buffer is the failure `io.line_too_long`, which the count takes as one
  more line.
- A `defer` closes the file on every way out of `count_lines` [1100].
- `complain` writes the program's name, what it was working on and
  `failure.words` of the failure to `io.err(host)`.

Fixture source: `compiler/tests/fixtures/runtime/line-count/main.ldn`.

```landin
--  Count the lines of the file named by the first argument, as `wc -l`
--  does.  A failure is said in words on standard error, and the program
--  then returns 1.
import core/failure
import core/io
import core/text
import hosted/system

--- How many lines the file at `path` holds.  A last line without its
--- newline counts, and so does a line too long for the buffer.
count_lines: (host: system.host, path: text.host_string)
             -> (lines: u64) ! ... =
    lines = 0
    opened: io.file = try io.open_read(host, path)
    defer io.close(host, opened) else none
    mut buffer: [4096]u8 = zeroed
    mut reader := io.lines_over(host, opened, buffer)
    loop do
        item: io.line = io.read_line(reader) else (problem)
            fail problem when problem <> io.line_too_long
            inc lines
            continue
        end
        break when item.finished
        inc lines
    end loop
end count_lines

--- Say on standard error what failed and why: `count: notes.log: not
--- found`.
complain: (host: system.host, subject: []u8, problem: failure.reason)
          -> none =
    mut room: [256]u8 = zeroed
    mut err := io.buffered_over(host, io.err(host), room)
    io.put(err, "count: ") else none
    io.put(err, subject) else none
    io.put(err, ": ") else none
    io.put(err, failure.words(problem)) else none
    io.put(err, "\n") else none
    io.flush(err) else none
end complain

public main: () -> (code: i32) =
    host := system.new()
    code = 1
    path := io.argument_at(host, 0) else (problem)
        io.write(host, io.err(host), "usage: count FILE\n") else none
        return
    end
    lines := count_lines(host, path) else (problem)
        complain(host, text.host_bytes(path), problem)
        return
    end
    mut storage: [64]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    io.format(out, "{} lines\n", [any(addr lines)]) else none
    io.flush(out) else (problem)
        complain(host, "standard output", problem)
        return
    end
    code = 0
end main
```

Named a file of four lines:

```sh
refine compile main.ldn -o count
./count notes.log
```

it prints `4 lines`. Named a file that is not there, it prints
`count: missing.log: not found` on standard error and returns 1.

## FizzBuzz

The familiar exercise from
[Rosetta Code](https://rosettacode.org/wiki/FizzBuzz): a `for` over a range
[1150] [0360] and an `if` on remainders [1050] [0290]. Fixed words go out
with `io.put` and numbers with `io.format`.

Fixture source: `compiler/tests/fixtures/runtime/example-fizzbuzz/main.ldn`.

```landin
--  One to a hundred, with Fizz for a multiple of three, Buzz for a
--  multiple of five and FizzBuzz for a multiple of both.
import core/io
import hosted/system

public main: () -> (code: i32) =
    host := system.new()
    mut storage: [512]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none

    for n in 1..100 do
        if n % 15 == 0 then
            io.put(out, "FizzBuzz\n") else none
        elsif n % 3 == 0 then
            io.put(out, "Fizz\n") else none
        elsif n % 5 == 0 then
            io.put(out, "Buzz\n") else none
        else
            io.format(out, "{}\n", [any(addr n)]) else none
        end if
    end for
    code = 0
end main
```

It prints a hundred lines, beginning

```text
1
2
Fizz
4
Buzz
Fizz
7
```

## Greatest common divisor

Euclid's algorithm from
[Rosetta Code](https://rosettacode.org/wiki/Greatest_common_divisor), as a
`while` loop [1140] over two mutable variables [0060]. The pairs are an
array of struct literals [0670] [0710].

Fixture source: `compiler/tests/fixtures/runtime/example-greatest-common-divisor/main.ldn`.

```landin
--  Euclid's algorithm: replace the pair by the divisor and the remainder
--  until the remainder is zero.
import core/io
import hosted/system

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

pair: type = struct
    a: u32
    b: u32
end pair

public main: () -> (code: i32) =
    host := system.new()
    mut storage: [256]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none

    pairs: [4]pair = [(a: 1071, b: 462), (a: 54, b: 24), (a: 42, b: 0),
                      (a: 37, b: 600)]
    for each in pairs do
        divisor: u32 = gcd(each.a, each.b)
        io.format(out, "gcd({}, {}) = {}\n",
                  [any(addr each.a), any(addr each.b), any(addr divisor)])
            else none
    end for
    code = 0
end main
```

It prints

```text
gcd(1071, 462) = 21
gcd(54, 24) = 6
gcd(42, 0) = 42
gcd(37, 600) = 1
```

## Insertion sort

Insertion sort grows a sorted prefix, moving each new value left past the
larger ones. It sorts a writable slice in place [0570]. The `show` helper
declares what can fail and passes each failure on with `try` [0940]
[0960]; `main` does not mind a failed print, so it calls `show` with
`else none` [1030].

Fixture source: `compiler/tests/fixtures/runtime/example-insertion-sort/main.ldn`.

```landin
--  Insertion sort grows a sorted prefix, moving each new value left past
--  the larger ones before it.
import core/io
import core/text
import hosted/system

insertion_sort: (values: []mut i32) -> none =
    for index in 1..<lenof values do
        mut current: usize = index
        while current > 0 and values[current - 1] > values[current] do
            saved: i32 = values[current - 1]
            values[current - 1] = values[current]
            values[current] = saved
            dec current
        end while
    end for
end insertion_sort

--- `label`, then each of `values` after a space, then a newline.
show: (inout out: io.buffered_writer(system.host), label: utf8,
       values: []i32)
      -> none ! io.io_failed | text.no_space | text.invalid_format =
    try io.format(out, "{}:", [any(addr label)])
    for value in values do
        try io.format(out, " {}", [any(addr value)])
    end for
    try io.put(out, "\n")
end show

public main: () -> (code: i32) =
    host := system.new()
    mut storage: [256]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none

    mut values: [8]i32 = [9, -4, 7, 7, 0, -9, 42, 1]
    show(out, "before", values) else none
    insertion_sort(values)
    show(out, "after", values) else none
    code = 0
end main
```

It prints

```text
before: 9 -4 7 7 0 -9 42 1
after: -9 -4 0 1 7 7 9 42
```

## Binary search

Binary search from [Rosetta Code](https://rosettacode.org/wiki/Binary_search)
returns a variant [0680]: `found` with an index, or `missing`. The loop
itself is the result: `break with` leaves it with a value [1190], and
`complete` gives the value when it runs out [1170]. `main` takes the
answer apart with `match` [1210].

Fixture source: `compiler/tests/fixtures/runtime/example-binary-search/main.ldn`.

```landin
--  Binary search halves a sorted slice until it finds the value or runs
--  out of places to look.  The answer is a variant: found, with an index,
--  or missing.
import core/io
import hosted/system

answer: type = struct
    kind: variant
        found: (index: usize) |
        missing
    end kind
end answer

search: (values: []i32, needle: i32) -> (result: answer) =
    mut left: usize = 0
    mut right: usize = lenof values
    result = while left < right do
        middle: usize = left + (right - left) / 2
        break with answer(kind: found(index: middle))
            when values[middle] == needle
        if values[middle] < needle then
            left = middle + 1
        else
            right = middle
        end if
    complete
        break with answer(kind: missing)
    end while
end search

public main: () -> (code: i32) =
    host := system.new()
    mut storage: [256]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none

    values: [10]i32 = [-20, -5, 0, 3, 8, 11, 18, 21, 34, 55]
    needles: [4]i32 = [-20, 3, 4, 55]
    for needle in needles do
        result: answer = search(values, needle)
        match result.kind
            found(index):
                io.format(out, "{} is at index {}\n",
                          [any(addr needle), any(addr index)]) else none
            missing: io.format(out, "{} is missing\n", [any(addr needle)])
                else none
        end match
    end for
    code = 0
end main
```

It prints

```text
-20 is at index 0
3 is at index 3
4 is missing
55 is at index 9
```

## Sieve of Eratosthenes

The [Rosetta Code](https://rosettacode.org/wiki/Sieve_of_Eratosthenes)
classic: a `zeroed` array of flags [0540], marked through a writable slice
[0570], and the numbers left unmarked are the primes.

Fixture source: `compiler/tests/fixtures/runtime/example-sieve-of-eratosthenes/main.ldn`.

```landin
--  The sieve of Eratosthenes: cross out the multiples of each prime, and
--  the numbers left are the primes.
import core/io
import hosted/system

--- Mark every number below `lenof composite` that is not prime.
sieve: (composite: []mut bool) -> none =
    composite[0] = true
    composite[1] = true
    for candidate in 2..<lenof composite do
        --  A smaller multiple has a smaller prime factor, which has already
        --  marked it, so the marking starts at the square.
        if not composite[candidate]
          and candidate <= (lenof composite - 1) / candidate
        then
            mut multiple: usize = candidate * candidate
            while multiple < lenof composite do
                composite[multiple] = true
                multiple += candidate
            end while
        end if
    end for
end sieve

public main: () -> (code: i32) =
    host := system.new()
    mut storage: [512]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none

    mut composite: [100]bool = zeroed
    sieve(composite)
    io.put(out, "primes below 100:") else none
    mut count: u32 = 0
    for number in 0..<lenof composite do
        if not composite[number] then
            io.format(out, " {}", [any(addr number)]) else none
            inc count
        end if
    end for
    io.format(out, "\n{} primes\n", [any(addr count)]) else none
    code = 0
end main
```

It prints

```text
primes below 100: 2 3 5 7 11 13 17 19 23 29 31 37 41 43 47 53 59 61 67 71 73 79 83 89 97
25 primes
```

## Run-length encoding

[Run-length encoding](https://rosettacode.org/wiki/Run-length_encoding)
writes each run of one repeated byte as its length and the byte. `encode`
fills storage its caller provides with `run` structs [0670] [0700], one
slot per input byte so that every run fits. The text literal is a `[]u8`
because its declaration says so [0260].

Fixture source: `compiler/tests/fixtures/runtime/example-run-length-encoding/main.ldn`.

```landin
--  Run-length encoding: each run of one repeated byte becomes its length
--  and the byte, so AAAB is 3A1B.
import core/io
import hosted/system

--- A run: where in the input it starts, and how many bytes long it is.
run: type = struct
    start: usize
    length: usize
end run

--- The runs of `input`, written into `runs`, which the caller makes as
--- long as the input so that every run fits.
encode: (input: []u8, runs: []mut run) -> (used: usize) =
    used = 0
    for at in 0..<lenof input do
        if used > 0 and input[runs[used - 1].start] == input[at] then
            inc runs[used - 1].length
        else
            runs[used] = run(start: at, length: 1)
            inc used
        end if
    end for
end encode

public main: () -> (code: i32) =
    host := system.new()
    mut storage: [256]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none

    input: []u8 = "AAAABBBCCDAA"
    mut runs: [12]run = zeroed
    used: usize = encode(input, runs)

    io.format(out, "input:   {}\nencoded: ", [any(addr input)]) else none
    for each in runs[0..<used] do
        byte: []u8 = input[each.start..<each.start + 1]
        io.format(out, "{}{}", [any(addr each.length), any(addr byte)])
            else none
    end for
    io.put(out, "\n") else none
    code = 0
end main
```

It prints

```text
input:   AAAABBBCCDAA
encoded: 4A3B2C1D2A
```

## Merge sort

Merge sort halves the range, sorts each half by calling itself, and merges
the two halves through a work array the caller lends. `return when` ends
the recursion at a range of one [0970].

Fixture source: `compiler/tests/fixtures/runtime/example-merge-sort/main.ldn`.

```landin
--  Merge sort halves the range, sorts each half, and merges the two sorted
--  halves back through a work array the caller lends.
import core/io
import core/text
import hosted/system

merge_sort: (values: []mut i32, work: []mut i32, left: usize, right: usize)
            -> none =
    return when right - left < 2
    middle: usize = left + (right - left) / 2
    merge_sort(values, work, left, middle)
    merge_sort(values, work, middle, right)

    for index in left..<right do
        work[index] = values[index]
    end for
    mut from_left: usize = left
    mut from_right: usize = middle
    for destination in left..<right do
        if from_right >= right
          or (from_left < middle and work[from_left] <= work[from_right])
        then
            values[destination] = work[from_left]
            inc from_left
        else
            values[destination] = work[from_right]
            inc from_right
        end if
    end for
end merge_sort

--- `label`, then each of `values` after a space, then a newline.
show: (inout out: io.buffered_writer(system.host), label: utf8,
       values: []i32)
      -> none ! io.io_failed | text.no_space | text.invalid_format =
    try io.format(out, "{}:", [any(addr label)])
    for value in values do
        try io.format(out, " {}", [any(addr value)])
    end for
    try io.put(out, "\n")
end show

public main: () -> (code: i32) =
    host := system.new()
    mut storage: [256]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none

    mut values: [8]i32 = [-12, 5, 0, 99, 5, 2, -3, 18]
    mut work: [8]i32 = zeroed
    show(out, "before", values) else none
    merge_sort(values, work, 0, 8)
    show(out, "after", values) else none
    code = 0
end main
```

It prints

```text
before: -12 5 0 99 5 2 -3 18
after: -12 -3 0 2 5 5 18 99
```

## Sensors

The language's main ideas working together in one program. Two kinds of
sensor conform to one concept [1230] [1240] and share one array as
`any sensor` values [1370], so each read is dispatched at runtime.

- `poll` is generic over its allocator [1290] [1360]; `main` lends it an
  arena over 256 bytes of its own frame [0820], and the list of readings
  grows there and nowhere else.
- A read can fail with a declared atom [0940]: the poll skips the unplugged
  door, would stop at a jammed sensor, and passes running out of memory on
  with `try` [0960].

Fixture source: `compiler/tests/fixtures/runtime/example-sensors/main.ldn`.

```landin
--  Sensors of different kinds behind one concept, polled through `any`,
--  their readings kept in a list whose memory the caller lends.
import core/arena
import core/io
import core/mem
import core/vec
import hosted/system

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

--- Generic over where the memory comes from; the caller decides.
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
    host := system.new()
    mut storage: [256]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none

    --  The readings live in an arena over 256 bytes of this frame.
    mut bytes: [256]u8 = zeroed
    mut space: arena.space = zeroed
    bump := arena.over_unchecked(space, addr bytes[0], lenof bytes)

    mut kitchen: thermometer = (celsius: 21)
    mut hall: thermometer = (celsius: 19)
    mut front: door = (openings: 1, wired: true)
    mut cellar: door = (openings: 0, wired: false)
    mut sensors: [4]any sensor
    sensors[0] = any(addr kitchen)
    sensors[1] = any(addr front)
    sensors[2] = any(addr cellar)
    sensors[3] = any(addr hall)

    mut readings := poll(bump, sensors[0..<4]) else (problem)
        if problem == jammed then
            io.put(out, "a sensor is jammed\n") else none
        else
            io.put(out, "out of memory\n") else none
        end if
        code = 1
        return
    end
    defer vec.release(readings, bump)

    for value in vec.used(readings) do
        io.format(out, "read {}\n", [any(addr value)]) else none
    end for
    count: usize = vec.length(readings)
    io.format(out, "{} of 4 sensors answered\n", [any(addr count)]) else none
    code = 0
end main
```

It prints

```text
read 21
read 2
read 19
3 of 4 sensors answered
```

## Word count

`wc` with no file named: the program reads its standard input to the end
and prints how many lines, words and bytes it held. The counting routine,
`count`, asks only for an `io.reader` [1290] [1230], the narrowest
capability it uses, so the same code counts a pipe, a file or bytes in
memory.

- It reads a buffer at a time until a read returns zero, which is the end
  of the input. `main` lends its whole array as the buffer [0570].
- The totals go out through a buffered writer and `io.format`, as in
  Printing formatted values.
- `main` checks the format and the final flush, so a total that could not
  be written makes the program say why on standard error and return 1
  rather than 0 [1030].

Fixture source: `compiler/tests/fixtures/runtime/word-count/main.ldn`.

```landin
--  Count the lines, words and bytes on standard input, as `wc` does when it
--  is named no file.  The counting asks only for a reader, the narrowest
--  capability it uses, so the same routine counts a pipe, a file or bytes in
--  memory.
import core/failure
import core/io
import hosted/system

counts: type = struct
    lines: u64
    words: u64
    bytes: u64
end counts

--- White space as C's isspace has it: space, tab, newline, vertical tab,
--- form feed and carriage return.  Every other byte belongs to a word.
blank: (byte: u8) -> (yes: bool) =
    yes = byte == 32 or (byte >= 9 and byte <= 13)
end blank

--- Read `opened` to its end through `buffer`, a buffer at a time.  A line
--- is counted at its newline, so a last line without one adds no line; a
--- word is counted at its first byte, and may run on from one buffer into
--- the next.
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

--- Say on standard error why the totals could not be written.
complain: (host: system.host, problem: failure.reason) -> none =
    io.write(host, io.err(host), "wc: ") else none
    io.write(host, io.err(host), failure.words(problem)) else none
    io.write(host, io.err(host), "\n") else none
end complain

public main: () -> (code: i32) =
    host := system.new()
    mut storage: [64]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none
    code = 1
    mut buffer: [4096]u8 = zeroed
    totals := count(host, io.input(host), buffer) else (problem)
        io.write(host, io.err(host), "wc: standard input could not be read\n")
            else none
        return
    end
    io.format(out, "{} {} {}\n",
              [any(addr totals.lines), any(addr totals.words),
               any(addr totals.bytes)]) else (problem)
        complain(host, problem)
        return
    end
    io.flush(out) else (problem)
        complain(host, problem)
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

which prints `2 3 14`. Because `count` names only a reader, the same
routine also counts bytes held in memory, on targets with no standard
input at all, Cortex-M included.

## Line numbers

`cat -n`: the program writes each line of its standard input after its
number, right-aligned in six columns, and a tab.

- `io.lines_over` makes a line reader over a 32-byte buffer, and
  `io.read_line` lends each line from that buffer until the next read
  [0790] [0800], without its `\n` or `\r\n`.
- A line too long for the buffer is the failure `io.line_too_long`; the
  program numbers it with a note in its place and goes on.
- A template placeholder has no width, so the number is right-aligned in a
  small `text.builder` with `text.align_right`, and each piece goes out
  with `io.put`.
- The output goes through a buffered writer. There are no destructors, so
  `main` flushes at the end and a `defer` flushes on every other way out
  [1100].
- When the numbering or the last flush fails, as writing to `/dev/full`
  does, `main` says why on standard error and returns 1.

Fixture source: `compiler/tests/fixtures/runtime/line-numbers/main.ldn`.

```landin
--  Number the lines of standard input, as `cat -n` does: each line after
--  its number, right-aligned in six columns, and a tab.  A line is read
--  through a buffer of 32 bytes; one too long for it is numbered with a
--  note in its place, and the lines after it are numbered as usual.  The
--  output goes through a buffered writer, flushed on every way out.
import core/failure
import core/io
import core/text
import hosted/system

--- Write every line of `host`'s standard input to `out`, numbered.
numbered: (provider: type is io.world, host: provider,
           inout out: io.buffered_writer(provider))
          -> none ! ... =
    mut buffer: [32]u8 = zeroed
    mut lines := io.lines_over(host, io.input(host), buffer)
    mut room: [16]u8 = zeroed
    mut prefix := text.over(room)
    mut number: u64 = 0
    loop do
        inc number
        text.clear(prefix)
        try text.append_u64(prefix, number)
        try text.align_right(prefix, 0, 6, u8(' '))
        try text.append_byte(prefix, u8('\t'))
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

--- Say on standard error why the lines could not be numbered.
complain: (host: system.host, problem: failure.reason) -> none =
    io.write(host, io.err(host), "numbers: ") else none
    io.write(host, io.err(host), failure.words(problem)) else none
    io.write(host, io.err(host), "\n") else none
end complain

public main: () -> (code: i32) =
    host := system.new()
    mut storage: [256]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none
    code = 1
    numbered(host, out) else (problem)
        complain(host, problem)
        return
    end
    io.flush(out) else (problem)
        complain(host, problem)
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

## Running a shell

The program runs `/bin/sh` with a script of its own, gives it an
environment the program builds, reads what the shell writes while it runs,
and reports it. Read `main`, which starts the shell, and then `capture`,
which reads from it.

- `io.spawn` starts a program by its path, never searching for it, with
  exactly the arguments and the variables, each an `io.variable`, that
  you pass. The parent's own `HOME` is not passed on, as the third line
  of the report shows.
- `io.capturing` pipes the child's output and errors to the parent, and
  `io.read_child` reads both pipes together, so neither fills up while the
  other is read.
- `io.wait` consumes the child [0910] and says how it ended, a variant
  [0680]: `exited` with a code, or `signalled`.
- `time.now` and `time.elapsed` time the child on the monotonic clock.
- `search_path` passes on the parent's `PATH`, and its `else` supplies a
  fallback value when there is none [1030].
- When the shell cannot be started, read or reported, `main` says why on
  standard error and returns 1.

Fixture source: `compiler/tests/fixtures/runtime/run-shell/main.ldn`.

```landin
--  Run a shell with an environment built for it, read what it writes to
--  its output and its errors while it runs, time it, and report what it
--  said, what it complained of, how it ended and how long it took.  The
--  report goes through a buffered writer, flushed on every way out.
import core/failure
import core/io
import core/text
import core/time
import hosted/system

--- What the shell runs: it says what its environment holds, complains
--- once, sleeps for a second and ends with code 3.  Its environment is
--- only what the program gives it, so the HOME the program itself has is
--- not among it; its PATH is, which is how the shell finds `sleep`.
script: []u8 = """
    printf 'NAME=%s\n' "$NAME"
    printf 'GREETING=%s\n' "$GREETING"
    printf 'HOME is %s\n' "${HOME-not set}"
    echo 'something went wrong' >&2
    sleep 1
    exit 3
    """

--- Read what the child `started` writes to its output and its errors into
--- `output` and `errors`, from whichever has something, until both have
--- ended, and wait for it.  Reading both while it runs is what lets a child
--- write more than a pipe holds to either.
capture: (provider: type is io.programs, host: provider,
          sink started: io.child, inout output: text.builder,
          inout errors: text.builder)
         -> (ended: io.ending) ! ... =
    mut running: io.child = started
    mut buffer: [256]u8 = zeroed
    loop do
        part: io.child_read = try io.read_child(host, running, buffer)
        break when part.finished
        if part.stream == io.child_errors then
            try text.append(errors, buffer[0..<part.count])
        else
            try text.append(output, buffer[0..<part.count])
        end if
    end loop
    ended = try io.wait(host, running)
end capture

--- Write each line of `bytes` to `out` after a bar.
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

--- Report to `out` what the child wrote, how it ended and how long it
--- took, which is never less than the second it slept.
report: (provider: type is io.writer, inout out: io.buffered_writer(provider),
         output: []u8, errors: []u8, ended: io.ending, took: time.duration)
        -> none ! ... =
    try io.put(out, "the shell said:\n")
    try quoted(out, output)
    try io.put(out, "and complained:\n")
    try quoted(out, errors)
    mut room: [64]u8 = zeroed
    mut line := text.over(room)
    match ended.how
        io.exited(code): try text.format(line, "and exited with code {}\n",
                                         [any(addr code)])
        io.signalled: try text.append(line, "and was ended by a signal\n")
    end match
    if took >= time.seconds(1) then
        try text.append(line, "after a second or more\n")
    else
        whole: u64 = time.in_milliseconds(took)
        try text.format(line, "after only {} ms\n", [any(addr whole)])
    end if
    try io.put(out, text.used(line))
end report

--- The parent's own PATH, the one variable of its environment it passes
--- on, or the directories every hosted system keeps `sleep` in when it
--- has none.
search_path: (host: system.host) -> (path: text.host_string from host) =
    path = io.variable_named(host, text.host_over("PATH"))
        else text.host_over("/bin:/usr/bin")
end search_path

--- Say on standard error why the shell could not be run or reported.
complain: (host: system.host, problem: failure.reason) -> none =
    io.write(host, io.err(host), "run-shell: ") else none
    io.write(host, io.err(host), failure.words(problem)) else none
    io.write(host, io.err(host), "\n") else none
end complain

public main: () -> (code: i32) =
    host := system.new()
    mut storage: [256]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none
    code = 1
    arguments: [2]text.host_string = [text.host_over("-c"),
                                      text.host_over(script)]
    variables: [3]io.variable =
        [(name: text.host_over("NAME"), value: text.host_over("landin")),
         (name: text.host_over("GREETING"),
          value: text.host_over("hello, world")),
         (name: text.host_over("PATH"), value: search_path(host))]
    began: time.instant = time.now(host)
    started := io.spawn(host, text.host_over("/bin/sh"),
                        arguments, variables,
                        io.capturing) else (problem)
        complain(host, problem)
        return
    end
    mut said: [512]u8 = zeroed
    mut complained: [512]u8 = zeroed
    mut output := text.over(said)
    mut errors := text.over(complained)
    ended: io.ending = capture(host, started, output, errors) else (problem)
        complain(host, problem)
        return
    end
    took: time.duration = time.elapsed(began, time.now(host))
    report(out, text.used(output), text.used(errors), ended,
           took) else (problem)
        complain(host, problem)
        return
    end
    io.flush(out) else (problem)
        complain(host, problem)
        return
    end
    match ended.how
        io.exited(status): if status == 3 then code = 0 end if
        io.signalled: code = 2
    end match
end main
```

It prints

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

## Echo over loopback

A server and its client in one program: it listens, connects to itself,
sends, accepts, echoes and reads the echo back, first over TCP and then
over UDP, on `127.0.0.1` and then on `::1`. Read `tcp_echo` first, then
`serve`, the server's side of it, and `udp_echo`.

- `net.loopback` makes an address. The listener asks for port 0, any free
  one, and `net.local_address` says which it got.
- Every call waits until it can do what it was asked, so the order matters
  in one thread: the client connects and sends before the server accepts,
  and `net.shutdown` tells the server it has finished sending.
- A connection is a file, so the server reads it with a line reader and
  answers through a buffered writer.
- `net.set_timeouts` makes a receive give up with `net.timed_out` rather
  than wait for ever. Every failure is an atom of its concept [0940].
- A system without IPv6's loopback address cannot run the second half: the
  program says so and returns 2. Any other failure it says in words on
  standard error, and returns 1.

Fixture source: `compiler/tests/fixtures/runtime/network-echo/main.ldn`.

```landin
--  Echo over loopback: a server and its client in one program, over TCP
--  and over UDP, on IPv4's loopback address and on IPv6's.  The server
--  reads the client's lines through a line reader and writes them back
--  through a buffered writer, the client reads them back through a line
--  reader of its own, and the report goes to standard output through a
--  buffered writer, flushed on every way out.
import core/failure
import core/io
import core/net
import core/text
import core/time
import hosted/system

--- What the client sends over TCP: three lines.
request: []u8 = "one\ntwo\nhello, world\n"

--- What the client sends over UDP: two datagrams.
messages: [2][]u8 = ["ping", "hello, datagram"]

--- A reply came from somewhere other than the server it was sent to.
wrong_sender: atom

--- Serve `connection`: read each line through a line reader and write it
--- back through a buffered writer, until the client has finished sending,
--- and then finish sending too.  `lines` is how many it echoed.
serve: (provider: type is net.network, host: provider, connection: io.file)
       -> (lines: usize) ! ... =
    mut incoming: [64]u8 = zeroed
    mut reader := io.lines_over(host, connection, incoming)
    mut outgoing: [64]u8 = zeroed
    mut writer := io.buffered_over(host, connection, outgoing)
    lines = 0
    loop do
        item: io.line = try io.read_line(reader)
        break when item.finished
        try io.put(writer, item.bytes)
        try io.put(writer, "\n")
        inc lines
    end loop
    try io.flush(writer)
    try net.shutdown(host, connection, net.sending)
end serve

--- Echo `request` over TCP between a server and a client on `family`'s
--- loopback address, and put what the client read back in `echoed`, a line
--- at a time; `lines` is how many the server echoed.  The listener asks for
--- port 0, any free one, and says which it got; the client sends all of
--- its lines and finishes sending before the server accepts, which the
--- system's buffers allow in one thread.
tcp_echo: (provider: type is net.network, host: provider,
           family: net.address_family, inout echoed: text.builder)
          -> (lines: usize) ! ... =
    listener: io.file = try net.listen(host, net.loopback(family, 0))
    defer net.close_socket(host, listener) else none
    at: net.address = try net.local_address(host, listener)
    client: io.file = try net.connect(host, at)
    defer net.close_socket(host, client) else none
    try net.set_timeouts(host, client, time.seconds(5), time.seconds(5))
    try net.send(host, client, request)
    try net.shutdown(host, client, net.sending)
    server: io.file = try net.accept(host, listener)
    defer net.close_socket(host, server) else none
    try net.set_timeouts(host, server, time.seconds(5), time.seconds(5))
    lines = try serve(host, server)
    mut incoming: [64]u8 = zeroed
    mut replies := io.lines_over(host, client, incoming)
    loop do
        item: io.line = try io.read_line(replies)
        break when item.finished
        try text.append(echoed, item.bytes)
        try text.append_byte(echoed, u8('\n'))
    end loop
end tcp_echo

--- Echo `messages` over UDP between two sockets on `family`'s loopback
--- address: the server sends each datagram back to whoever sent it, and
--- the client puts each reply in `echoed`, a line each.
udp_echo: (provider: type is net.network, host: provider,
           family: net.address_family, inout echoed: text.builder)
          -> none ! ... =
    server: io.file = try net.open_datagram(host, net.loopback(family, 0))
    defer net.close_socket(host, server) else none
    client: io.file = try net.open_datagram(host, net.loopback(family, 0))
    defer net.close_socket(host, client) else none
    try net.set_timeouts(host, server, time.seconds(5), time.seconds(5))
    try net.set_timeouts(host, client, time.seconds(5), time.seconds(5))
    at: net.address = try net.local_address(host, server)
    mut buffer: [64]u8 = zeroed
    for message in messages do
        try net.send_to(host, client, message, at)
        got: net.datagram = try net.receive_from(host, server, buffer)
        try net.send_to(host, server, buffer[0..<got.count], got.sender)
        back: net.datagram = try net.receive_from(host, client, buffer)
        fail wrong_sender when not net.same_address(back.sender, at)
        try text.append(echoed, buffer[0..<back.count])
        try text.append_byte(echoed, u8('\n'))
    end for
end udp_echo

--- Write each line of `bytes` to `out` after a bar.
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

--- Report what came back over `protocol` on `family`'s loopback address:
--- `count` of `what` the server echoed, and each of them.
report: (provider: type is io.writer, inout out: io.buffered_writer(provider),
         protocol: []u8, family: net.address_family, count: usize,
         what: []u8, echoed: []u8) -> none ! ... =
    mut room: [64]u8 = zeroed
    mut line := text.over(room)
    at: net.address = net.loopback(family, 0)
    try text.append(line, protocol)
    try text.append(line, " over ")
    try net.append_ip(line, at)
    try text.format(line, ": the server echoed {} {}\n",
                    [any(addr count), any(addr what)])
    try io.put(out, text.used(line))
    try quoted(out, echoed)
end report

--- Echo over TCP and then UDP on `family`'s loopback address, and report
--- what came back to `out`.
exchange: (host: system.host,
           inout out: io.buffered_writer(system.host),
           family: net.address_family) -> none ! ... =
    mut room: [256]u8 = zeroed
    mut echoed := text.over(room)
    lines: usize = try tcp_echo(host, family, echoed)
    try report(out, "TCP", family, lines, "lines", text.used(echoed))
    text.clear(echoed)
    try udp_echo(host, family, echoed)
    try report(out, "UDP", family, lenof messages, "datagrams",
               text.used(echoed))
end exchange

--- Say on standard error why the echo could not be run or reported.
complain: (host: system.host, problem: wrong_sender | failure.reason)
          -> none =
    reason: []u8 = match problem
        wrong_sender: "a datagram came from the wrong sender"
        _ (rest): failure.words(rest)
    end match
    io.write(host, io.err(host), "echo: ") else none
    io.write(host, io.err(host), reason) else none
    io.write(host, io.err(host), "\n") else none
end complain

public main: () -> (code: i32) =
    host := system.new()
    mut storage: [512]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none
    code = 1
    families: [2]net.address_family = [net.ipv4, net.ipv6]
    for family in families do
        exchange(host, out, family) else (problem)
            --  A system without IPv6 cannot run the second half, which
            --  says so rather than passing over it.
            if problem == net.address_unavailable then
                io.put(out, "this system has no such loopback address\n")
                    else none
                code = 2
            else
                complain(host, problem)
            end if
            return
        end
    end for
    io.flush(out) else (problem)
        complain(host, problem)
        return
    end
    code = 0
end main
```

It prints

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

## Directory listing

`ls -l` cut down to what every hosted system agrees on: each entry of a
directory with its kind, a file's size in bytes and its name, in byte order.
Read `list`, which reads the entries, and `show`, which prints them: they
are at the top of the file. Given a path, `./listing DIR` lists that
directory, up to 256 entries. With no argument, so that it has something
known to list, the program builds a small directory where it runs, lists it,
checks the listing and removes the directory again; that code comes after
the comment `Everything below`.

- `io.read_entry` lends each name from the directory's buffer until the
  next read [0790] [0800], so the program copies each name it keeps with
  `mem.copy`.
- A name is bytes as the system stores them and need not be UTF-8; one
  that `text.valid` refuses prints with its other bytes escaped as `\xHH`.
- `core/sort` sorts the copies by the `cmp.ordered` conformance the
  program declares for them [1280].
- A `defer` closes the directory on every way out of `list` [1100].
- `complain` words the program's own atoms with a `match` and hands the
  library's to `failure.words` with `_ (rest)` [1210], as Reporting a
  failure in words describes.

Fixture source: `compiler/tests/fixtures/runtime/directory-listing/main.ldn`.

```landin
--  List a directory: each entry's kind, a file's size in bytes and the
--  entry's name, in byte order.  `list` reads the entries and `show`
--  prints them.  A name is bytes, which need not be UTF-8: core/text
--  validates each one, and a name that is not prints with its other bytes
--  escaped.  The code after the comment `Everything below` only builds a
--  directory to list and checks the result.
import core/cmp
import core/failure
import core/io
import core/mem
import core/sort
import core/text
import hosted/system

--- Read every entry of the directory at `path` into `into`, with each
--- file's size; `count` is how many there are.
list: (host: system.host, path: []u8, into: []mut kept)
      -> (count: usize) ! ... =
    count = 0
    mut buffer: [1024]u8 = zeroed
    mut listing: io.directory =
        try io.open_directory(host, text.host_over(path), buffer)
    defer io.close_directory(host, listing) else none
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

--- Sort `entries` and write them to `out`, a line each, and then how many
--- there are and the files' bytes; `total` is those bytes.
show: (inout out: io.buffered_writer(system.host), entries: []mut kept)
      -> (total: u64) ! ... =
    sort.sort(entries)
    mut room: [300]u8 = zeroed
    mut text_line := text.over(room)
    total = 0
    for entry in entries do
        try line(entry, text_line)
        try io.put(out, text.used(text_line))
        total += entry.size
    end for
    count: usize = lenof entries
    try io.format(out, "{} entries, {} bytes in files\n",
                  [any(addr count), any(addr total)])
end show

--- An entry kept past the read that gave it.  The directory lends a name
--- only until its next read, which reuses the buffer the name is in, so
--- the listing keeps a copy.
kept: type = struct
    name: [255]u8
    length: usize
    kind: io.entry_kind
    size: u64
end kept

--- More entries than the listing keeps, or a name longer than it keeps.
too_many: atom
too_long: atom

--- Byte order, the order `ls` gives in the C locale.
before: (left: kept, right: kept) -> (yes: bool) =
    yes = cmp.compare(left.name[0..<left.length],
                      right.name[0..<right.length]) == cmp.less
end before

kept is cmp.ordered (less: before)

--- One line for `entry` into `into`: its kind, a file's size or `-`, and
--- its name as it is shown.
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

--- A name as the listing shows it: as it is when it is UTF-8, and
--- otherwise with each byte outside printable ASCII written as `\xHH`, so
--- the line stays text.  Its conformance lets `format` write it.
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
            try text.align_right(into, digits, 2, u8('0'))
        end if
    end for
end escaped

--- List the directory the first argument names, up to 256 entries.
list_named: (host: system.host, inout out: io.buffered_writer(system.host))
            -> none ! ... =
    path: []u8 = text.host_bytes(try io.argument_at(host, 0))
    blank: kept = (name: [255 of 0], length: 0, kind: io.special, size: 0)
    mut entries: [256]kept = [256 of blank]
    count: usize = try list(host, path, entries)
    _ = try show(out, entries[0..<count])
end list_named

--- Say on standard error why the listing stopped.
complain: (host: system.host,
           problem: too_many | too_long | differs | failure.reason) -> none =
    reason: []u8 = match problem
        too_many: "more entries than the listing keeps"
        too_long: "a name longer than the listing keeps"
        differs: "the listing does not hold what was built"
        _ (rest): failure.words(rest)
    end match
    io.write(host, io.err(host), "listing: ") else none
    io.write(host, io.err(host), reason) else none
    io.write(host, io.err(host), "\n") else none
end complain

--  Everything below only sets up the demonstration: it builds a small
--  directory where the program runs, lists it, checks that the listing
--  holds what it built, and removes the directory again.

--- The directory the program builds, lists and removes, in the directory
--- it runs in.
top: []u8 = "listing-scratch"

--- The listing does not hold what the program built.
differs: atom

--- The path of `name` in the top directory, or of the top directory itself
--- when `name` is empty, built in `path`.
joined: (name: []u8, inout path: text.builder) -> none ! text.no_space =
    text.clear(path)
    try text.append(path, top)
    if lenof name > 0 then
        try text.append_byte(path, u8('/'))
        try text.append(path, name)
    end if
end joined

--- Make the file `name` in the top directory, holding `contents`.
make_file: (host: system.host, name: []u8, contents: []u8) -> none ! ... =
    mut scratch: [64]u8 = zeroed
    mut path := text.over(scratch)
    try joined(name, path)
    opened: io.file = try io.open_write(host, text.host_over(text.used(path)))
    io.write(host, opened, contents) else (problem)
        io.close(host, opened) else none
        fail problem
    end
    try io.close(host, opened)
end make_file

--- Remove the file `path` names, or with `directory` the empty directory.
remove: (host: system.host, path: text.host_string, directory: bool)
        -> none ! ... =
    if directory then
        try io.remove_directory(host, path)
    else
        try io.remove_file(host, path)
    end if
end remove

--- Remove `name` from the top directory, or the top directory itself when
--- `name` is empty, if it is there.
forget: (host: system.host, name: []u8, directory: bool) -> none ! ... =
    mut scratch: [64]u8 = zeroed
    mut path := text.over(scratch)
    try joined(name, path)
    remove(host, text.host_over(text.used(path)), directory) else (problem)
        fail problem when problem <> io.not_found
    end
end forget

--- Remove everything the program makes, whatever an earlier run left.
clear: (host: system.host) -> none ! ... =
    try forget(host, "nested/gamma.log", false)
    try forget(host, "nested", true)
    try forget(host, "alpha.log", false)
    try forget(host, "beta.log", false)
    try forget(host, "café.log", false)
    try forget(host, "empty", false)
    try forget(host, "", true)
end clear

--- Make the directory `name` in the top directory, or the top directory
--- itself when `name` is empty.
make_directory: (host: system.host, name: []u8) -> none ! ... =
    mut scratch: [64]u8 = zeroed
    mut path := text.over(scratch)
    try joined(name, path)
    try io.make_directory(host, text.host_over(text.used(path)))
end make_directory

--- Four files, one of them empty and one with a name beyond ASCII, and a
--- subdirectory holding a fifth.
build: (host: system.host) -> none ! ... =
    try clear(host)
    try make_directory(host, "")
    try make_file(host, "alpha.log", "alpha\n")
    line_of_beta: []u8 = "beta\n"
    mut lines: [1000]u8 = zeroed
    for at in usize(0)..<usize(1000) do
        lines[at] = line_of_beta[at % 5]
    end for
    try make_file(host, "beta.log", lines)
    try make_file(host, "café.log", "café\n")
    try make_file(host, "empty", "")
    try make_directory(host, "nested")
    try make_file(host, "nested/gamma.log", "gamma\n")
end build

--- Build the directory, list it to `out`, check the listing and remove the
--- directory.
demonstrate: (host: system.host, inout out: io.buffered_writer(system.host))
             -> none ! ... =
    try build(host)
    blank: kept = (name: [255 of 0], length: 0, kind: io.special, size: 0)
    mut entries: [8]kept = [8 of blank]
    count: usize = try list(host, top, entries)
    total: u64 = try show(out, entries[0..<count])
    try clear(host)
    fail differs when count <> 5 or total <> 1012
end demonstrate

public main: () -> (code: i32) =
    host := system.new()
    mut storage: [512]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none
    code = 1
    if io.argument_count(host) > 0 then
        list_named(host, out) else (problem)
            complain(host, problem)
            return
        end
    else
        demonstrate(host, out) else (problem)
            complain(host, problem)
            return
        end
    end if
    io.flush(out) else (problem)
        complain(host, problem)
        return
    end
    code = 0
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

and leaves the directory as it found it.

## Copying a tree

`cp -a` cut down to what Linux, macOS and FreeBSD all keep: each file's
bytes, its permission bits and its times, and each symbolic link as a link
to the same target, never followed. Read `copy_directory` first, at the top
of the file, and then `copy_file`, `filled` and `copy_link`, which it calls.
Given two paths, `./tree-copy FROM TO` copies the directory FROM to TO and
says how many files, links and directories it copied. A directory may hold
up to 256 entries, a name up to 255 bytes and a path up to 256 bytes. With
no arguments, so that it has something known to copy, the program builds a
small tree where it runs, copies it twice, checks the copy, prints a listing
of it and removes both; that code comes after the comment `Everything
below`.

- Each file is written to a temporary file that `io.make_temporary` makes
  beside its destination. `io.synchronize` then puts its bytes on the disk
  and `io.rename` moves it into place, so a program reading the copy sees
  the old file or the new one, never half of either.
- `io.read_at`, `io.write_at` and `io.truncate` copy a file so that a hole
  in it stays a hole.
- `platform/posix` gives what the portable concepts do not: permission
  bits, owners, times and symbolic links.
- The copy does not keep the owner unless the process is root, the time a
  file last changed, extended attributes, or that two names are one file,
  and it skips anything that is not a file, a directory or a link.
- `core/failure` has no words for `platform/posix`'s errno atoms, so
  `complain` names a failure there only in general terms.

Fixture source: `compiler/tests/fixtures/runtime/tree-copy/main.ldn`.

```landin
--  Copy a directory tree as `cp -a` does, keeping what every hosted
--  system keeps: each file's contents, holes and all, its permission bits
--  and its times, each directory's, and each symbolic link as a link to
--  the same target.  Every file and link is made under a temporary name
--  and renamed into place, so a copy over an earlier one replaces each
--  entry in one step.  `copy_directory` is the copy; read it and the three
--  routines after it first.  The code after the comment `Everything below`
--  only builds a tree to copy, checks the copy and removes both.
import core/cmp
import core/failure
import core/io
import core/mem
import core/sort
import core/text
import hosted/system
import platform/posix

--- Copy the directory `from_path` to `to_path`, every entry in it and
--- below it, and then its owner when the process may, its permission bits
--- and its times, which adding its entries changed.  A directory already
--- there from an earlier copy is copied into.  `done` counts what it did.
copy_directory: (host: system.host, from_path: []u8, to_path: []u8,
                 inout done: tally) -> none ! ... =
    found: posix.status = try posix.status_at(posix.working_directory,
                                              text.host_over(from_path),
                                              false)
    io.make_directory(host, text.host_over(to_path)) else (problem)
        fail problem when problem <> io.already_exists
    end
    mut entries: [256]kept = [256 of blank]
    count: usize = try entries_of(host, from_path, entries)
    mut from_room: [256]u8 = zeroed
    mut from_child := text.over(from_room)
    mut to_room: [256]u8 = zeroed
    mut to_child := text.over(to_room)
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

--- Copy the file `from_path` to `to_path`: into a temporary file beside
--- `to_path`, renamed onto it once it is whole, replacing a file already
--- there in one step.
copy_file: (host: system.host, from_path: []u8, to_path: []u8,
            inout done: tally) -> none ! ... =
    found: posix.status = try posix.status_at(posix.working_directory,
                                              text.host_over(from_path),
                                              false)
    input: io.file = try io.open_read(host, text.host_over(from_path))
    defer io.close(host, input) else none
    mut room: [256]u8 = zeroed
    made: io.temporary =
        try io.make_temporary(host, host, text.host_over(parent_of(to_path)),
                              room)
    filled(host, input, made.opened, found) else (problem)
        io.close(host, made.opened) else none
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

--- Copy `input`'s bytes into `target` at the same offsets, writing no
--- block that is all zeros, so a hole stays a hole, and give `target` the
--- size `found` gives and then its owner, when the process may give a file
--- away, its permission bits, which a change of owner may clear, and its
--- times.
filled: (host: system.host, input: io.file, target: io.file,
         found: posix.status) -> none ! ... =
    mut block: [4096]u8 = zeroed
    mut offset: u64 = 0
    loop do
        count: usize = try io.read_at(host, input, offset, block)
        break when count == 0
        if not zeros(block[0..<count]) then
            try io.write_at(host, target, offset, block[0..<count])
        end if
        offset += u64(count)
    end loop
    --  A file ending in a hole was never written there: its size makes it.
    try io.truncate(host, target, found.size)
    made: posix.descriptor = system.descriptor_of(target)
    if privileged() then
        try posix.change_owner(made, found.user, found.group)
    end if
    try posix.change_mode(made, found.permissions)
    try posix.set_times(made, found.accessed, found.modified)
    try io.synchronize(host, target, io.data_only)
end filled

--- Copy the symbolic link `from_path` to `to_path` as a link to the same
--- target, made under a fresh name beside `to_path` and renamed onto it.
copy_link: (host: system.host, from_path: []u8, to_path: []u8,
            inout done: tally) -> none ! ... =
    found: posix.status = try posix.status_at(posix.working_directory,
                                              text.host_over(from_path),
                                              false)
    mut target_room: [256]u8 = zeroed
    target: text.host_string =
        try posix.read_link_at(posix.working_directory,
                               text.host_over(from_path), target_room)
    mut room: [256]u8 = zeroed
    mut name: text.host_string = text.host_over(room[0..<0])
    mut made: bool = false
    for attempt in usize(0)..<io.temporary_tries do
        _ = attempt
        mut bytes: [8]u8 = zeroed
        try io.fill_random(host, bytes)
        name = try io.temporary_path(text.host_over(parent_of(to_path)), bytes,
                                     room)
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

--- What a copy did.
tally: type = struct
    files: usize
    links: usize
    directories: usize
    skipped: usize
    replaced: usize
end tally

--- A directory holding more entries than the copy keeps, or a name longer
--- than it keeps.
too_many: atom
too_long: atom

--- An entry kept past the read that gave it: a directory lends a name only
--- until its next read.
kept: type = struct
    name: [255]u8
    length: usize
    kind: io.entry_kind
end kept

--- Byte order, as `ls` sorts in the C locale.
before: (left: kept, right: kept) -> (yes: bool) =
    yes = cmp.compare(left.name[0..<left.length],
                      right.name[0..<right.length]) == cmp.less
end before

kept is cmp.ordered (less: before)

blank: kept = (name: [255 of 0], length: 0, kind: io.special)

--- The entries of the directory `path`, sorted by name, into `into`;
--- `count` is how many there are.
entries_of: (host: system.host, path: []u8, into: []mut kept)
            -> (count: usize) ! ... =
    count = 0
    mut buffer: [1024]u8 = zeroed
    mut listing: io.directory =
        try io.open_directory(host, text.host_over(path), buffer)
    defer io.close_directory(host, listing) else none
    loop do
        item: io.entry = try io.read_entry(host, listing)
        name: []u8 = text.host_bytes(item.name)
        break when lenof name == 0
        fail too_many when count == lenof into
        fail too_long when lenof name > 255
        into[count] = blank
        try mem.copy(into[count].name[0..<255], name)
        into[count].length = lenof name
        into[count].kind = item.kind
        inc count
    end loop
    sort.sort(into[0..<count])
end entries_of

--- The path `name` in `parent`, or `parent` when `name` is empty, built in
--- `into`.
joined: (parent: []u8, name: []u8, inout into: text.builder)
        -> none ! text.no_space =
    text.clear(into)
    try text.append(into, parent)
    separator: []u8 = if lenof name > 0 then "/" else "" end if
    try text.append(into, separator)
    try text.append(into, name)
end joined

--- The directory `path` lies in.
parent_of: (path: []u8) -> (parent: []u8 from path) =
    mut at: usize = lenof path
    while at > 0 and path[at - 1] <> 47 do
        dec at
    end while
    parent = if at == 0 then "." else path[0..<at - 1] end if
end parent_of

--- Whether the process may read and write any file whatever its
--- permission bits say, as root may: what it can keep and what a
--- read-only file refuses it both differ.
privileged: () -> (yes: bool) =
    yes = posix.effective_user() == posix.user_id(0)
end privileged

--- Whether every byte of `bytes` is zero: a block the copy need not write.
zeros: (bytes: []u8) -> (yes: bool) =
    yes = true
    for byte in bytes do
        if byte <> 0 then yes = false end if
    end for
end zeros

--- Whether anything is at `path`, a link not followed.
present: (host: system.host, path: text.host_string) -> (yes: bool) ! ... =
    yes = true
    _ = io.status_of(host, path, io.not_following) else (problem)
        fail problem when problem <> io.not_found
        yes = false
        return
    end
end present

--- Forget a temporary file that will not be renamed into place.
dropped: (host: system.host, path: text.host_string) -> none =
    io.remove_file(host, path) else none
end dropped

--- Copy the directory the first argument names to the path the second
--- names, and say what the copy did.
copy_named: (host: system.host, inout out: io.buffered_writer(system.host))
            -> none ! ... =
    from_path: []u8 = text.host_bytes(try io.argument_at(host, 0))
    to_path: []u8 = text.host_bytes(try io.argument_at(host, 1))
    mut done: tally = (files: 0, links: 0, directories: 0, skipped: 0,
                       replaced: 0)
    try copy_directory(host, from_path, to_path, done)
    try io.format(out, "copied {} files, {} links, {} directories\n",
                  [any(addr done.files), any(addr done.links),
                   any(addr done.directories)])
    try io.format(out, "skipped {} entries of other kinds\n",
                  [any(addr done.skipped)])
end copy_named

--- Say on standard error why the copy stopped.  `core/failure` words the
--- library's failures; `platform/posix`'s are not among them.
complain: (host: system.host, problem: too_many | too_long | differs
           | failure.reason | posix.errno) -> none =
    reason: []u8 = match problem
        too_many: "a directory holds more entries than the copy keeps"
        too_long: "a name is longer than the copy keeps"
        differs: "the copy differs from what was copied"
        _: "a file or directory could not be read, made or changed"
    end match
    io.write(host, io.err(host), "tree-copy: ") else none
    io.write(host, io.err(host), reason) else none
    io.write(host, io.err(host), "\n") else none
end complain

--  Everything below only sets up the demonstration: it builds a small tree
--  where the program runs, copies it twice, checks the copy against it,
--  lists the copy and removes both.

--- Where the program works, what it copies and where the copy goes.
top: []u8 = "tree-copy-scratch"
source: []u8 = "tree-copy-scratch/source"
copy: []u8 = "tree-copy-scratch/copy"

--- The source's times: midnight UTC on 2000-01-01, and a second later for
--- each entry after the first.
epoch: i64 = 946684800

--- A copy that differs from what it was copied from.
differs: atom

--- Remove the tree at `path`, whatever is in it, if it is there.
remove_tree: (host: system.host, path: []u8) -> none ! ... =
    found: io.status = io.status_of(host, text.host_over(path), io.not_following)
        else (problem)
        fail problem when problem <> io.not_found
        return
    end
    if found.kind <> io.subdirectory then
        try io.remove_file(host, text.host_over(path))
        return
    end if
    mut entries: [16]kept = [16 of blank]
    count: usize = try entries_of(host, path, entries)
    mut room: [256]u8 = zeroed
    mut child := text.over(room)
    for item in entries[0..<count] do
        try joined(path, item.name[0..<item.length], child)
        try remove_tree(host, text.used(child))
    end for
    try io.remove_directory(host, text.host_over(path))
end remove_tree

--- Make the file `name` in the source holding `contents`, with
--- `permissions`.
make_file: (host: system.host, name: []u8, contents: []u8,
            permissions: u32) -> none ! ... =
    mut room: [256]u8 = zeroed
    mut path := text.over(room)
    try joined(source, name, path)
    opened: io.file = try io.open_write(host, text.host_over(text.used(path)))
    io.write(host, opened, contents) else (problem)
        io.close(host, opened) else none
        fail problem
    end
    try io.close(host, opened)
    try posix.change_mode_at(posix.working_directory,
                             text.host_over(text.used(path)), permissions)
end make_file

--- Make the directory `name` in the source, or the source when it is
--- empty.
make_folder: (host: system.host, name: []u8) -> none ! ... =
    mut room: [256]u8 = zeroed
    mut path := text.over(room)
    try joined(source, name, path)
    try io.make_directory(host, text.host_over(text.used(path)))
    try posix.change_mode_at(posix.working_directory,
                             text.host_over(text.used(path)), 0o755)
end make_folder

--- Give the source entry `name` the times `epoch` and `second` seconds,
--- its own when it is a link.
stamp: (name: []u8, second: i64) -> none ! ... =
    mut room: [256]u8 = zeroed
    mut path := text.over(room)
    try joined(source, name, path)
    at: posix.time_value = (seconds: epoch + second, nanoseconds: 0)
    try posix.set_times_at(posix.working_directory,
                           text.host_over(text.used(path)), at, at, false)
end stamp

--- The names the source holds, in the order their times are given:
--- everything inside a directory before the directory itself.
stamped: [12][]u8 = ["dangling", "link-to-notes", "link-to-readme",
                     "locked", "notes/todo", "notes", "readme-again",
                     "readme", "run", "sparse.bin", "socket", ""]

--- One mebibyte: how far into sparse.bin its second part lies.
mebibyte: u64 = 1048576

--- Write a sparse file, `name` in the source: four bytes at its start,
--- four more a mebibyte in, and a hole between them that reads as zeros.
make_sparse: (host: system.host, name: []u8) -> none ! ... =
    mut room: [256]u8 = zeroed
    mut path := text.over(room)
    try joined(source, name, path)
    sparse: text.host_string = text.host_over(text.used(path))
    opened: io.file = try io.open_file(host, sparse, io.creating)
    defer io.close(host, opened) else none
    try io.write_at(host, opened, u64(0), "head")
    try io.write_at(host, opened, mebibyte, "tail")
    try posix.change_mode(system.descriptor_of(opened), 0o644)
end make_sparse

--- Make `name` in the source a symbolic link to `target`, or with `hard`
--- a second name of the source file `target`.
make_link: (target: []u8, name: []u8, hard: bool) -> none ! ... =
    mut room: [256]u8 = zeroed
    mut path := text.over(room)
    try joined(source, name, path)
    made: text.host_string = text.host_over(text.used(path))
    if not hard then
        try posix.symbolic_link_at(text.host_over(target),
                                   posix.working_directory, made)
        return
    end if
    mut other: [256]u8 = zeroed
    mut existing := text.over(other)
    try joined(source, target, existing)
    try posix.link_at(posix.working_directory,
                      text.host_over(text.used(existing)),
                      posix.working_directory, made)
end make_link

--- Make `name` in the source a Unix-domain socket's name, which stays
--- when the socket is closed.
make_socket: (name: []u8) -> none ! ... =
    mut room: [256]u8 = zeroed
    mut path := text.over(room)
    try joined(source, name, path)
    socket: posix.descriptor = try posix.socket(posix.local, posix.stream)
    defer posix.close(socket) else none
    at: posix.socket_address =
        try posix.unix_address(text.host_over(text.used(path)))
    try posix.bind(socket, at)
end make_socket

--- Build the tree the program copies: files of each kind of permission, a
--- read-only one, one with two names, a sparse one, symbolic links to a
--- directory, to a file and to nothing, and a socket, which no copy makes.
build: (host: system.host) -> none ! ... =
    try remove_tree(host, top)
    try io.make_directory(host, text.host_over(top))
    try make_folder(host, "")
    try make_folder(host, "notes")
    try make_file(host, "readme", "a tree to copy\n", 0o644)
    try make_file(host, "run", "#!/bin/sh\necho copied\n", 0o755)
    try make_file(host, "notes/todo", "keep the times\n", 0o600)
    try make_file(host, "locked", "nobody writes this\n", 0o644)
    mut room: [256]u8 = zeroed
    mut locked := text.over(room)
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

--- Write `permissions` as four octal digits.
append_mode: (inout into: text.builder, permissions: u32)
             -> none ! text.no_space =
    shifts: [4]u32 = [9, 6, 3, 0]
    for shift in shifts do
        try text.append_byte(into, u8(48 + ((permissions >> shift) & 7)))
    end for
end append_mode

--- One line of the listing for the copied entry at `path`, `name`
--- relative to the copy: its kind, its permission bits, a file's size, its
--- time, and a link's target.
line: (path: []u8, name: []u8, kind: io.entry_kind,
       inout into: text.builder) -> none ! ... =
    found: posix.status = try posix.status_at(posix.working_directory,
                                              text.host_over(path), false)
    text.clear(into)
    if kind == io.symbolic_link then
        mut room: [256]u8 = zeroed
        target: text.host_string =
            try posix.read_link_at(posix.working_directory,
                                   text.host_over(path), room)
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

--- Write the copy's listing to `out`, depth first in byte order: what is
--- at `path`, `name` relative to the copy, and below it.
show: (host: system.host, inout out: io.buffered_writer(system.host),
       path: []u8, name: []u8, kind: io.entry_kind) -> none ! ... =
    mut room: [300]u8 = zeroed
    mut text_line := text.over(room)
    shown: []u8 = if lenof name == 0 then "." else name end if
    try line(path, shown, kind, text_line)
    try io.put(out, text.used(text_line))
    return when kind <> io.subdirectory
    mut entries: [16]kept = [16 of blank]
    count: usize = try entries_of(host, path, entries)
    mut path_room: [256]u8 = zeroed
    mut child := text.over(path_room)
    mut name_room: [256]u8 = zeroed
    mut child_name := text.over(name_room)
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

--- Whether the copied entry at `to_path` is what was copied from
--- `from_path`: the same kind, permission bits and time, the same bytes in
--- a file, and the same target in a link.  No name of the copy is a
--- temporary one.
same_entry: (host: system.host, from_path: []u8, to_path: []u8,
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
                                   text.host_over(from_path), first_room)
        mut second_room: [256]u8 = zeroed
        second: text.host_string =
            try posix.read_link_at(posix.working_directory,
                                   text.host_over(to_path), second_room)
        fail differs when cmp.compare(text.host_bytes(first),
                                      text.host_bytes(second)) <> cmp.equal
        return
    end if
    fail differs when original.permissions <> copied.permissions
    return when kind <> io.regular
    fail differs when original.size <> copied.size
    left: io.file = try io.open_read(host, text.host_over(from_path))
    defer io.close(host, left) else none
    right: io.file = try io.open_read(host, text.host_over(to_path))
    defer io.close(host, right) else none
    mut first_block: [4096]u8 = zeroed
    mut second_block: [4096]u8 = zeroed
    mut offset: u64 = 0
    loop do
        count: usize = try io.read_at(host, left, offset, first_block)
        other: usize = try io.read_at(host, right, offset, second_block)
        fail differs when count <> other
          or cmp.compare(first_block[0..<count], second_block[0..<count])
             <> cmp.equal
        break when count == 0
        offset += u64(count)
    end loop
end same_entry

--- Check the copy at `to_path` against the tree at `from_path`, entry by
--- entry.
same_tree: (host: system.host, from_path: []u8, to_path: []u8)
           -> none ! ... =
    try same_entry(host, from_path, to_path, io.subdirectory)
    mut entries: [16]kept = [16 of blank]
    count: usize = try entries_of(host, to_path, entries)
    mut from_room: [256]u8 = zeroed
    mut from_child := text.over(from_room)
    mut to_room: [256]u8 = zeroed
    mut to_child := text.over(to_room)
    for item in entries[0..<count] do
        name: []u8 = item.name[0..<item.length]
        fail differs when lenof name >= 5
          and cmp.compare(name[0..<5], ".tmp-") == cmp.equal
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

--- The edge cases the copy must get right: a read-only file refuses a
--- write, a read past the end of a sparse file gives nothing, and a file
--- with two names in the source is two files in the copy.
edge_cases: (host: system.host) -> none ! ... =
    mut room: [256]u8 = zeroed
    mut path := text.over(room)
    try joined(copy, "locked", path)
    locked: text.host_string = text.host_over(text.used(path))
    found: io.status = try io.status_of(host, locked, io.following)
    fail differs when not found.read_only
    --  A file open only for reading refuses a write whoever writes, root
    --  as well, and the system says why, EBADF.
    reading: io.file = try io.open_read(host, locked)
    mut refused: bool = false
    io.write(host, reading, "overwritten\n") else (problem)
        refused = system.last_errno(host) == posix.number(posix.ebadf)
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
    mut sparse_path := text.over(sparse_room)
    try joined(copy, "sparse.bin", sparse_path)
    sparse: io.file =
        try io.open_read(host, text.host_over(text.used(sparse_path)))
    defer io.close(host, sparse) else none
    size: io.status = try io.status_of_file(host, sparse)
    mut probe: [16]u8 = zeroed
    past: usize = try io.read_at(host, sparse, size.size + 10, probe)
    hole: usize = try io.read_at(host, sparse, u64(500000), probe)
    fail differs when size.size <> mebibyte + 4 or past <> 0 or hole <> 16
      or not zeros(probe)
    --  Two names of one file in the source, and two files in the copy.
    mut first_room: [256]u8 = zeroed
    mut first_path := text.over(first_room)
    try joined(source, "readme", first_path)
    first: posix.status =
        try posix.status_at(posix.working_directory,
                            text.host_over(text.used(first_path)), false)
    mut second_room: [256]u8 = zeroed
    mut second_path := text.over(second_room)
    try joined(copy, "readme", second_path)
    second: posix.status =
        try posix.status_at(posix.working_directory,
                            text.host_over(text.used(second_path)), false)
    fail differs when first.links <> 2 or second.links <> 1
end edge_cases

--- What the program checked, which `report` prints after the listing.
checked: []u8 = """readme has two names in the source and one in the copy
    locked is read-only and refuses a write
    sparse.bin reads as zeros in its hole and as nothing past its end
    """

--- Write to `out` what the two copies did, `first` and `second`, and what
--- the program checked.
report: (inout out: io.buffered_writer(system.host), first: tally,
         second: tally) -> none ! ... =
    copied: usize = first.files + first.links + first.directories
    try io.format(out,
                  "{} entries copied twice, {} socket skipped each time\n",
                  [any(addr copied), any(addr second.skipped)])
    try io.format(out,
                  "the second copy replaced {} files and {} links in place\n",
                  [any(addr second.files), any(addr second.links)])
    try io.put(out, checked)
end report

--- Build the tree, copy it, change it and copy it again over the first
--- copy, check the copy, list it to `out` and remove both trees.
demonstrate: (host: system.host, inout out: io.buffered_writer(system.host))
             -> none ! ... =
    try build(host)
    mut first: tally = (files: 0, links: 0, directories: 0, skipped: 0,
                        replaced: 0)
    try copy_directory(host, source, copy, first)
    --  The source changes, and the second copy goes over the first.
    mut second: tally = (files: 0, links: 0, directories: 0, skipped: 0,
                         replaced: 0)
    try make_file(host, "readme", "a tree copied twice\n", 0o644)
    try stamp("readme", 7)
    try copy_directory(host, source, copy, second)
    try same_tree(host, source, copy)
    try edge_cases(host)
    try show(host, out, copy, "", io.subdirectory)
    try report(out, first, second)
    try remove_tree(host, top)
    fail differs when first.replaced <> 0 or second.replaced <> 9
      or first.skipped <> 1
end demonstrate

public main: () -> (code: i32) =
    host := system.new()
    mut storage: [512]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none
    code = 1
    if io.argument_count(host) == 2 then
        copy_named(host, out) else (problem)
            complain(host, problem)
            return
        end
    else
        demonstrate(host, out) else (problem)
            complain(host, problem)
            return
        end
    end if
    io.flush(out) else (problem)
        complain(host, problem)
        return
    end
    code = 0
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

The number after each `+` is the entry's time in seconds after the start
of 2000, which the program gave the source.

## Benchmark Game programs

The last five programs are direct ports of
[the Benchmark Game](https://benchmarksgame-team.pages.debian.net/benchmarksgame/)'s
workloads, there to compare Landin with other languages:
[docs/benchmarks.md](docs/benchmarks.md) has the measurements. They are
longer and tuned for speed rather than for teaching.

Like the game's own programs, each takes its size as an argument or reads
its standard input. What each prints for the game's small correctness
input is the game's official output, byte for byte. To measure one,
compile it with `--optimize speed` and give it the performance input:

```sh
refine compile --optimize speed main.ldn -o fannkuch-redux
./fannkuch-redux 12
```

## Benchmark Game fannkuch-redux

[fannkuch-redux](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/fannkuchredux.html)
flips every permutation of the order its argument names, from one to
sixteen, through fixed arrays, and prints a checksum and the largest number
of flips. The correctness input is 7 and the performance input 12.

Fixture source: `compiler/tests/fixtures/runtime/benchmark-game-fannkuch-redux/main.ldn`.

```landin
--  A direct single-threaded implementation of the Benchmark Game workload.
--  The order is the program's argument: seven for the correctness output,
--  twelve for the performance run, and never more than sixteen.
import core/io
import core/text
import hosted/system

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

--- The order named by the first argument, one to sixteen.
order_size: (host: system.host)
            -> (n: usize)
            ! io.no_argument | text.invalid_number | text.number_overflow
            | bad_size =
    first: usize = 0
    argument := try io.argument_at(host, first)
    n = try text.parse_usize(text.host_bytes(argument))
    fail bad_size when n < 1 or n > 16
end order_size

report: (host: system.host, n: usize, value: score)
        -> none ! io.io_failed | text.no_space | text.invalid_format =
    mut storage: [64]u8 = zeroed
    mut line := text.over(storage)
    try text.format(line, "{}\nPfannkuchen({}) = {}\n",
                    [any(addr value.checksum), any(addr n),
                     any(addr value.maximum)])
    try io.write(host, io.out(host), text.used(line))
end report

public main: () -> (code: i32) =
    host := system.new()
    code = 1
    n := order_size(host) else (problem)
        io.write(host, io.err(host),
                 "usage: fannkuch-redux N, where N is 1 to 16\n") else none
        return
    end

    value: score = fannkuch(n)
    report(host, n, value) else (problem)
        return
    end
    code = 0
end main
```

`./fannkuch-redux 7` prints

```text
228
Pfannkuchen(7) = 16
```

## Benchmark Game Mandelbrot

[Mandelbrot](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/mandelbrot.html)
plots the Mandelbrot set as a binary PBM image whose width and height its
argument names. It packs eight pixels to a byte into a row allocated from
the hosted heap [1360] and writes each row through a buffered writer. The
correctness input is 200 and the performance input 16000.

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
import hosted/system

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

--- Pack one row of the `n` by `n` image into `row`, eight pixels to a
--- byte.
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

render: (inout out: io.buffered_writer(system.host), n: usize, row: []mut u8)
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

--- The image size named by the first argument.
image_size: (host: system.host)
            -> (n: usize)
            ! io.no_argument | text.invalid_number | text.number_overflow =
    first: usize = 0
    argument := try io.argument_at(host, first)
    n = try text.parse_usize(text.host_bytes(argument))
end image_size

public main: () -> (code: i32) =
    host := system.new()
    memory := heap.new()
    code = 1
    n := image_size(host) else (problem)
        io.write(host, io.err(host), "usage: mandelbrot N\n") else none
        return
    end

    mut row := mem.new_bytes(memory, (n + 7) / 8) else (problem)
        io.write(host, io.err(host), "mandelbrot: out of memory\n") else none
        return
    end
    defer mem.delete_bytes(memory, row)

    mut storage: [16384]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none
    render(out, n, mem.bytes(row)) else (problem)
        return
    end
    io.flush(out) else (problem)
        return
    end
    code = 0
end main
```

`./mandelbrot 200 > mandelbrot.pbm` writes a 200 by 200 black-and-white
image of the set, 5011 bytes, which most image viewers open: the header
`P4`, the width and the height, and then one bit for each pixel.

## Benchmark Game FASTA

[FASTA](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/fasta.html)
writes DNA sequences of the length its argument names, by copying one
sequence cyclically and by choosing symbols at random by weight. It lends
whole arrays to slice parameters [0570] and gathers its lines in a 16 KiB
buffered writer. The correctness input is 1000 and the performance input
25000000.

Fixture source: `compiler/tests/fixtures/runtime/benchmark-game-fasta/main.ldn`.

```landin
--  The sequence length is the program's argument: 1000 for the correctness
--  output, 25000000 for the performance run.  A symbol is chosen as the
--  Benchmark Game's C program chooses it, by counting the cumulative
--  probabilities the random number reaches rather than stopping at the
--  first it does not, and the naïve LCG advances once for every random
--  nucleotide.
import core/io
import core/text
import hosted/system

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

--- The first of `symbols` whose cumulative probability exceeds `random`,
--- or the last.  Every comparison is made, so the loop has no exit that
--- depends on the random number.
select_symbol: (symbols: []u8, cumulative: []f64, random: f64)
               -> (selected: u8) =
    mut index: usize = 0
    first: usize = 0
    for at in first..<lenof cumulative - 1 do
        if random >= cumulative[at] then
            inc index
        end if
    end for
    selected = symbols[index]
end select_symbol

write_repeated: (inout out: io.buffered_writer(system.host),
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

write_random: (inout out: io.buffered_writer(system.host), symbols: []u8,
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

--- The three sequences for `n`, written through `out`.
fasta: (inout out: io.buffered_writer(system.host), n: usize)
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

--- The sequence length named by the first argument.
sequence_size: (host: system.host)
               -> (n: usize)
               ! io.no_argument | text.invalid_number | text.number_overflow =
    first: usize = 0
    argument := try io.argument_at(host, first)
    n = try text.parse_usize(text.host_bytes(argument))
end sequence_size

public main: () -> (code: i32) =
    host := system.new()
    code = 1
    n := sequence_size(host) else (problem)
        io.write(host, io.err(host), "usage: fasta N\n") else none
        return
    end

    mut storage: [16384]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none
    fasta(out, n) else (problem)
        return
    end
    io.flush(out) else (problem)
        return
    end
    code = 0
end main
```

`./fasta 1000 | head -5` prints

```text
>ONE Homo sapiens alu
GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGA
TCACCTGAGGTCAGGAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACT
AAAAATACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAG
GCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTGCAGTGAGCCGAGATCGCG
```

## Benchmark Game reverse-complement

[reverse-complement](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/revcomp.html)
reads FASTA's output on its standard input and writes each sequence
reversed, every base replaced by its complement. A sequence may be as long
as the input, so the program gathers it in a `core/text` builder that grows
on the hosted heap [1360]. The performance input is FASTA's output for
25000000:

```sh
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
import hosted/system

--- Each IUB code and the code it pairs with.  A lowercase code pairs
--- with the same uppercase complement as its uppercase form.
codes: []u8 = "ACGTUMRWSYKVHDBN"
pairs: []u8 = "TGCAAKYWSRMBDHVN"

--- Every byte's complement, at the byte's own index.  A byte that is no
--- IUB code is its own complement.
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

--- Append all of standard input to `whole`, a read at a time.
read_all: (host: system.host, inout whole: text.builder)
          -> none ! io.io_failed | text.no_space =
    input: io.file = io.input(host)
    mut chunk: [65536]u8 = zeroed
    loop do
        got: usize = try io.read(host, input, chunk)
        break when got == 0
        try text.append(whole, chunk[0..<got])
    end loop
end read_all

--- Write `sequence` to `out` from its last base to its first, each
--- replaced by its complement, leaving out its line breaks and breaking it
--- again into lines of sixty.
write_reversed: (inout out: io.buffered_writer(system.host),
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
            try io.put(out, line)
            width = 0
        end if
    end while
    if width > 0 then
        line[width] = 10
        try io.put(out, line[0..<width + 1])
    end if
end write_reversed

--- Write every record of `input` to `out`: its header line, which begins
--- with `>`, as it is, and then its sequence, every line up to the next
--- header, turned around.
records: (inout out: io.buffered_writer(system.host), input: []u8)
         -> none ! io.io_failed =
    table: [256]u8 = complements()
    mut at: usize = 0
    while at < lenof input do
        if input[at] == 62 then
            ends: usize = at + mem.find(input[at..<lenof input], u8('\n'))
            try io.put(out, input[at..<ends])
            try io.put(out, "\n")
            at = ends
            if at < lenof input then inc at end if
        end if
        ends: usize = at + mem.find(input[at..<lenof input], u8('>'))
        try write_reversed(out, input[at..<ends], table)
        at = ends
    end while
end records

public main: () -> (code: i32) =
    host := system.new()
    memory := heap.new()
    mut storage: [65536]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none
    mut whole := text.growing(any(addr memory))
    defer text.release(whole)
    code = 1

    read_all(host, whole) else (problem)
        if problem == text.no_space then
            io.write(host, io.err(host), "revcomp: out of memory\n") else none
        else
            io.write(host, io.err(host), "revcomp: standard input could not be read\n")
                else none
        end if
        return
    end
    records(out, text.used(whole)) else (problem)
        io.write(host, io.err(host), "revcomp: standard output could not be written\n")
            else none
        return
    end
    io.flush(out) else (problem)
        io.write(host, io.err(host), "revcomp: standard output could not be written\n")
            else none
        return
    end
    code = 0
end main
```

`./fasta 1000 | ./reverse-complement | head -5` prints

```text
>ONE Homo sapiens alu
CGGAGTCTCGCTCTGTCGCCCAGGCTGGAGTGCAGTGGCGCGATCTCGGCTCACTGCAAC
CTCCGCCTCCCGGGTTCAAGCGATTCTCCTGCCTCAGCCTCCCGAGTAGCTGGGATTACA
GGCGCGCGCCACCACGCCCGGCTAATTTTTGTATTTTTAGTAGAGACGGGGTTTCACCAT
GTTGGCCAGGCTGGTCTCGAACTCCTGACCTCAGGTGATCCGCCCGCCTCGGCCTCCCAA
```

## Benchmark Game binary-trees

[binary-trees](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/binarytrees.html)
builds, walks and frees many perfect binary trees. A missing child is an
atom rather than a null pointer [0480], and each tree's nodes come from a
`core/region` over the hosted heap, so releasing the region frees the tree
at once [1360]. The correctness input is 10 and the performance input 21.

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
import hosted/system

bad_depth: atom

--- A missing child, which only a leaf has.
leaf: atom

child: type = leaf | ptr mut node

node: type = struct
    left: child
    right: child
end node

nodes_region: type = region.region(heap.heap)

min_depth: usize = 4

--- A perfect tree with `depth` levels below its root.
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

--- The nodes of `tree`, counted by walking all of it.
check: (tree: ptr mut node) -> (count: usize) =
    count = 1 + check_child(tree.val.left) + check_child(tree.val.right)
end check

check_child: (branch: child) -> (count: usize) =
    match branch
        leaf: count = 0
        ptr (subtree): count = check(subtree)
    end match
end check_child

--- Build a tree of `depth` in a region of its own, check it and free it.
checked_tree: (memory: heap.heap, depth: usize)
              -> (count: usize) ! mem.out_of_memory =
    mut ledger: region.growing_space = zeroed
    nodes := region.over(ledger, memory)
    defer region.release(ledger, memory)
    tree: ptr mut node = try build(nodes, depth)
    count = check(tree)
end checked_tree

--- Write one line of the report.
say: (host: system.host, template: utf8, values: []any text.formattable)
     -> none ! io.io_failed | text.no_space | text.invalid_format =
    mut storage: [96]u8 = zeroed
    mut line := text.over(storage)
    try text.format(line, template, values)
    try io.write(host, io.out(host), text.used(line))
end say

binary_trees: (host: system.host, n: usize)
              -> none ! mem.out_of_memory | io.io_failed | text.no_space
                      | text.invalid_format =
    memory := heap.new()
    max_depth: usize = if n > min_depth + 2 then n else min_depth + 2 end if

    stretch_depth: usize = max_depth + 1
    stretch_check: usize = try checked_tree(memory, stretch_depth)
    try say(host, "stretch tree of depth {}\t check: {}\n",
            [any(addr stretch_depth), any(addr stretch_check)])

    mut long_ledger: region.growing_space = zeroed
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

--- The depth named by the first argument; above fifty-nine the nodes
--- counted at depth four would not fit in a usize.
tree_depth: (host: system.host)
            -> (n: usize) ! io.no_argument | text.invalid_number
                          | text.number_overflow | bad_depth =
    first: usize = 0
    argument := try io.argument_at(host, first)
    n = try text.parse_usize(text.host_bytes(argument))
    fail bad_depth when n > 59
end tree_depth

public main: () -> (code: i32) =
    host := system.new()
    code = 1
    n := tree_depth(host) else (problem)
        io.write(host, io.err(host),
                 "usage: binary-trees N, where N is 0 to 59\n") else none
        return
    end

    binary_trees(host, n) else (problem)
        return when problem <> mem.out_of_memory
        message: []u8 = "binary-trees: out of memory\n"
        io.write(host, io.err(host), message) else none
        return
    end
    code = 0
end main
```

`./binary-trees 10` prints

```text
stretch tree of depth 11	 check: 4095
1024	 trees of depth 4	 check: 31744
256	 trees of depth 6	 check: 32512
64	 trees of depth 8	 check: 32704
16	 trees of depth 10	 check: 32752
long lived tree of depth 10	 check: 2047
```
