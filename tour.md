# Learn Landin in Y minutes

Ada, but small. Zig, but sweeter. One systems language from 32 KB to
32 TB*. Move fast, keep the pointers, and let the compiler tell you when
you are being an idiot.

Named after Peter Landin, who coined the term "syntactic sugar" and
wrote "The Next 700 Programming Languages". This one is the 701st.

Version 0.2.7 — what each version changed is in
[the handoff](handoff.md#versions).

## Hello, world

Make a directory, `mkdir hello && cd hello`, and save this in it as
`main.ldn`:

```landin
import core/io
import hosted/system

public main: () -> (code: i32) =
    host := system.new()
    io.write(host, io.out(host), "Hello, world!\n") else none
    code = 0
end main
```

Compile it and run it:

```sh
refine compile main.ldn -o hello
./hello
```

Line by line:

- `import core/io` brings in the reader and writer interfaces, and
  `hosted/system` the operating system that provides them.
- `main` takes nothing and returns one named result, `code`, which becomes
  the exit status. A routine sets its results by assigning them.
- `system.new()` is the program's handle on the operating system. Files,
  the terminal and the network are all reached through it. Pass it to the
  routines that need it rather than making one in each, and a routine's
  parameters say what it touches ([1660]). That is a convention: the
  compiler does not stop a routine from calling `system.new()` itself
  ([1680]).
- `io.write` can fail, and Landin will not let a failure pass unnoticed.
  `else none` says that here it does not matter ([1030]). It is the
  handler to reach for last: [1030] also shows passing a failure on and
  reporting it, as the next program does.

To print values, use `format` through a buffered writer. Each `{}` takes
the next value from the list:

```landin
print_born: (inout out: io.buffered_writer(system.host), name: utf8,
             year: u32) -> none =
    io.format(out, "{} was born in {}.\n", [any(addr name), any(addr year)]) else none
end print_born
```

`main` makes the writer once and hands it to whatever prints:

```landin
    mut storage: [256]u8 = zeroed
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none
    print_born(out, "Ada", 1815) -- Ada was born in 1815.
```

- `buffered_over` collects output in a buffer you supply, here on the
  stack, so printing allocates nothing. One `format` call's whole output
  must fit in the buffer, or that call fails with `text.no_space`. A line
  made by several calls may be longer, and `io.put` writes bytes larger
  than the buffer straight through.
- `defer` runs `flush` when the routine ends, by returning or by a
  failure, but not on a trap, which runs no cleanup ([1100]). There are no
  destructors, so nothing flushes for you.
- `any(addr name)` hands `format` the address of a value it can turn into
  text ([1370]). Integers, `bool`, `utf8` and byte strings are formattable;
  floats are not yet. A type of your own becomes formattable by declaring
  a conformance ([1240]).

## Reading a file

This program counts the lines of the file named by its first argument.
Give it a directory of its own beside `hello`, `mkdir lines && cd lines`,
and save it there as `main.ldn`:

```landin
import core/failure
import core/io
import hosted/system

--- How many lines the file named by the first argument has.
count_file_lines: (host: system.host) -> (lines: usize)
                  ! io.no_argument | io.not_found | io.no_access | io.io_failed
                  | io.line_too_long =
    path := try io.argument_at(host, 0)
    source := try io.open_read(host, path)
    defer io.close(host, source) else none
    mut buffer: [4096]u8 = zeroed
    mut reader := io.lines_over(host, source, buffer)
    lines = 0
    loop do
        line := try io.read_line(reader)
        break when line.finished
        inc lines
    end loop
end count_file_lines

public main: () -> (code: i32) =
    host := system.new()
    mut storage: [256]u8 = zeroed
    lines := count_file_lines(host) else (problem)
        mut err := io.buffered_over(host, io.err(host), storage)
        defer io.flush(err) else none
        words: []u8 = failure.words(problem)
        io.format(err, "error: {}\n", [any(addr words)]) else none
        code = 1
        return
    end
    mut out := io.buffered_over(host, io.out(host), storage)
    defer io.flush(out) else none
    io.format(out, "{} lines\n", [any(addr lines)]) else none
    code = 0
end main
```

- The `!` list after the result of `count_file_lines` says every way it
  can fail. `try` passes a failure straight on to the caller ([0960]).
- `io.argument_at(host, 0)` is the first argument after the program's own
  name.
- `io.lines_over` reads through a buffer you supply and hands out one line
  at a time ([1130] for `loop`, [0400] for `inc`).
- `main` decides what a failure means. `else (problem)` handles it in
  place ([1030]): `failure.words`, from `core/failure`, has words for
  every library failure, `io.err(host)` is standard error, and `code = 1`
  is the exit status. The handler returns before `out` is made, so the two
  writers can share one buffer.

Make a small file, then run the program on it and on a file that is not
there:

```sh
refine compile main.ldn -o lines
printf 'one\ntwo\nthree\n' > notes
./lines notes
./lines missing
echo $?
```

```text
3 lines
error: not found
1
```

The tour explains each piece in order, starting below.
[`examples.md`](examples.md) has complete programs that list directories,
run commands and talk over sockets.

## How to read this tour

Read it from the top. Each entry is one idea, with an example, and the
sections build on each other. The first part, up to the end of MODULES, is
the path: read it in order and you can write ordinary programs. The rest
is reference, to read when you need it.

The numbers in brackets, such as [0430], never change, so other documents
and the compiler's own messages can point here: a refusal ends with a note
such as "the tour describes it at [0520]". The numbers are not in reading
order, and do not need to be.

This tour teaches; it leaves out rules a reader would guess anyway.
[`spec.md`](spec.md) is the specification, and where the two could be read
differently, it decides. If you write C,
[Landin for C programmers](docs/from-c.md) maps each habit you bring to its
Landin form.

*32 TB is an unverified goal. What it measures at the hosted end, and what
evidence would prove it, are still open, and nothing hosted today
establishes it. Terabytes may vary.

---

## COMMENTS

Each example below is a comment exactly as it appears in a program: the
marker is the comment.

### [0010] Line comments

`--` starts a comment that runs to the end of the line.

```landin
-- [0010] Line comment, to end of line.
```

### [0020] Block comments, which nest

`--(` opens a block comment and `)--` closes it. It may sit between two
tokens on one line.

```landin
--( [0020] Block comment. Nests properly.
    --( so this inner one is fine )--
)--
```

Because block comments nest, you can comment out a region that already
contains one. A block comment that is never closed runs to the end of the
file, and the compiler reports it there.

### [0030] Doc comments

`---` starts a doc comment, which documents the declaration on the next
line.

```landin
--- [0030] Doc comment. Attaches to the declaration that follows.
```

A doc comment changes nothing about what the program means. Which lines
count as a declaration's doc comment is in spec [2000].

## DECLARATIONS

### [0040] Declaring a name

A declaration gives a name, a type and a value, in that order. It is
immutable unless you say otherwise.

```landin
greeting: utf8 = "hello"
```

### [0050] Letting the type come from the value

Leave out the type and write `:=`, and the name takes the type of its
value.

```landin
count := 7
```

### [0060] Mutable variables

`mut` makes a binding you can assign again.

```landin
mut total: u32 = 0
```

### [0070] Two separate questions about a reference

A reference raises two independent questions. May the name be pointed
somewhere else? `mut` on the binding answers that. May the thing it points
at be written? `mut` inside the type answers that. Nothing else answers
either.

```landin
two_questions: () -> (seen: u32) =
    mut first_reading: u32 = 1
    mut dial_setting: u32 = 2
    mut cursor: ptr u32 = addr first_reading -- re-pointable, reads only
    knob: ptr mut u32 = addr dial_setting -- fixed, writes
    cursor = addr dial_setting -- allowed: the binding is mut
    knob.val = 3 -- allowed: the type is ptr mut
    seen = cursor.val -- 3
end two_questions
```

`addr` takes an address and `.val` is the thing pointed at; [0430]
explains pointers properly, and [0460] points one at a fixed hardware
address.

### [0080] Declaring now, assigning later

A declaration may leave out the value. The name must then be assigned
before anything reads it.

```landin
mut result: u32
```

### [0090] Making a name public

`public` exports a name to other modules. Without it, the name is private
to its module.

```landin
public version: u32 = 3
```

`public` is about modules, not the linker. A public routine or datum is
still a local symbol inside the program's image, so no C library or linked
object can collide with it. To give C or the linker a name, see [1600] and
[1610]. Exact rules: spec [1975].

### [0100] Several names in one declaration

Several names may share one declaration, as fields in a struct already do.

```landin
public red, green, blue: u8
north, south, east, west: atom
```

It means the same declarations written one per name, in order. Each name
gets its own storage and everything written around the list: `mut`,
`public`, a parameter convention, `at` or `from`. So in a parameter list,
`inout low, high: i32` makes both parameters `inout`.

```landin
mut low_mark, high_mark: u32 = 10 -- two variables, both start at 10
```

The fine print:

- A shared value is computed once, for the first name, and the other names
  start as copies of it: `mut low, high: u32 = next_seed()` calls
  `next_seed` once.
- The shared form needs a written type, because `low, high := bounds()`
  reads as taking apart a multiple result ([0990]).
- Type declarations, functions, type and fixed formals, variant parts and
  condition bindings take one name each.

### [0110] The name is always on the left

Left of `:` is always the name being introduced. Right of `:` is what
fills it: a type, or, with `=`, a value.

In a local declaration, the written type and the value both see only the
names visible before the declaration. If an outer `t` names a type,
`mut t: t = value` uses that type and then introduces the local `t`; the
statements after it see the local. A binding in a condition follows the
same rule ([1070]). Module declarations and routine signatures see all
their names at once ([0130], [1290]).

Control words are reserved everywhere a name could go (spec [1760]).
`begin`, `match`, `loop`, `break` and `unchecked` cannot be variables,
parameters, fields or labels, so `begin = 10` is an error; call it
`begin_value` instead. There is no escape for using a keyword as a name:
writing `(begin)` does not make one.

### [0120] Declaring a type

A type is declared like any other name, with `type` as its type.

```landin
point: type = struct
    x: f32
    y: f32
end point
```

### [0130] Order does not matter in a module

Inside a module, you may use a name above the line that declares it. The
compiler collects every name before resolving any.

```landin
twice_answer: () -> (n: i32) =
    n = 2 * answer_value -- answer_value is declared below
end twice_answer

answer_value: i32 = 21
```

The one exception is `linker.library` directives, which keep their source
order for linking ([1590]).

### [0140] Shadowing

A name in an inner scope may hide the same name from an outer one.

```landin
step_limit: u32 = 100

shadow_demo: (extra: u32) -> (result: u32) =
    result = step_limit
    begin
        step_limit := extra -- a new local; the module's step_limit is untouched
        result += step_limit
    end
end shadow_demo
```

Two declarations of one name in the same scope are an error (spec [1850]).

## NUMBERS AND LITERALS

### [0150] Integer types

The integer types are `u8`, `u16`, `u32` and `u64`, and the signed `i8`,
`i16`, `i32` and `i64`.

128-bit integers are not in Landin yet; they are planned, for when a
program needs them (Language evolution, in [the roadmap](ROADMAP.md)).

Odd widths such as `u4` or `u12` exist only as fields of packed register
images ([0730]). Reading one gives you the next ordinary width up, so a
`u1` field reads as a `u8` holding 0 or 1. A one-bit flag is spelt `bool`,
and a `u1` does not convert to or from `bool` on its own.

### [0160] Pointer-sized integers

`usize` and `isize` are as wide as a pointer on the target.

### [0170] Floating point

The float types are `f32` and `f64`. There is no `f80`.

There is no `f16` yet either: neither baseline x86-64 nor Cortex-M0 has a
half-precision instruction. It is planned (Language evolution, in
[the roadmap](ROADMAP.md)).

### [0180] Booleans

`bool` holds `true` or `false`.

### [0190] Integer literals take their type from where they are used

An integer literal has no type of its own. It takes the type its context
expects, and the compiler checks that it fits.

```landin
tiny: u8 = 5
large: u64 = 5
-- bad: u8 = 300      is a compile error
```

Spec [1880] says exactly what counts as a context.

### [0200] With no context, an integer is an `i32`

When nothing says what type an integer literal should be, it is an `i32`.

```landin
plain := 5
```

### [0210] Float literals always have a point

A float literal always looks like one, so an integer never quietly becomes
a float or the other way round.

```landin
ratio: f32 = 5.0
-- bad: f32 = 5     is a compile error
half := 1.0 / 2.0 -- 0.5
zero := 1 / 2 -- 0, integer division
```

### [0220] Bases, separators and exponents

Integers may be written in hex, binary or octal, and long numbers may use
`_` to group digits.

```landin
hex_value: u32 = 0xDEAD_BEEF -- too big for the default i32
bin_value := 0b1010_0101
oct_value := 0o755
big_value := 1_000_000
sci_value := 1.5e10
neg_exp := 1.0e-6
```

The fine print:

- A digit run starts and ends with a digit of its base. Underscores go only
  between digits, and may repeat, as in `1__000`.
- A base prefix alone, such as `0x`, and a trailing underscore are errors.
- In a float, both sides of the point and a written exponent need digits,
  with the same underscore rule.
- A number has no suffix. A letter directly after one is part of it, so
  `1u64` is an error: put the type on the binding, as in `mask: u64 = 1`.

### [0230] Hex floats, for exact values

A hex float literal states a float's bits exactly, subnormals included.

```landin
pi_exact: f64 = 0x1.921fb54442d18p+1
smallest_subnormal: f32 = 0x1.0p-149
smallest_normal: f32 = 0x1.0p-126
```

### [0240] Infinity, NaN and negative zero

The IEEE special values are named values of the float types, and unary
minus gives their negative forms.

```landin
neg_zero: f64 = -0.0
pos_inf: f64 = f64.infinity
neg_inf: f64 = -f64.infinity
quiet_nan: f64 = f64.nan
neg_nan: f64 = -f64.nan
```

Constant folding keeps a literal's sign. The sign of a NaN that arithmetic
produces is not specified.

### [0250] Character literals

A character literal is one Unicode code point, and its type is `u32`.

```landin
letter_a := 'a'
```

A byte is a `u8`, so comparing one with a character takes a conversion:

```landin
is_newline: (byte: u8) -> (yes: bool) =
    yes = byte == u8('\n')
end is_newline
```

### [0260] Text literals take their type from where they are used

Like integers, a text literal takes its type from its context: `utf8`,
`[]u8`, `utf16` or `cstring`. With no context, it is `utf8`.

```landin
name: utf8 = "hello"
cname: cstring = "hello"
```

Every text literal ends with a NUL byte that its length does not count, so
passing one to C costs nothing.

A literal lives in read-only storage, so you can never write through a
reference to one, however the binding is declared ([0070]). For writable
text, copy it into storage you asked for.

```landin
-- greeting: []u8 = "abc"
-- greeting[0] = 0x78          -- error, the literal is static
```

### [0270] Escapes

A backslash starts an escape. The set is small and closed:

| escape | means |
|---|---|
| `\n` `\r` `\t` `\e` | newline, carriage return, tab, escape |
| `\\` `\"` `\'` | the character itself |
| `\xNN` | one byte, exactly two hex digits |
| `\u{...}` | one code point, any number of hex digits |

```landin
line := "col\tsep\n"
smile := "\u{1F600}"
byte: []u8 = "\xFF" -- byte escapes require []u8 context
```

There is no octal escape and no `\0`; write `\x00`. An unknown escape is a
compile error, never silently the character. `\xNN` is allowed only where
bytes are meant, in a `[]u8`, and `\u{...}` only where text is meant, so a
text literal can never hold invalid UTF-8.

### [0280] Raw text literals

A raw literal sits between runs of at least three quotes, and nothing in
it is escaped. If the text itself contains three quotes in a row, use four.

```landin
help := """
        usage: tool [options]
          -v    verbose
        """
```

The closing quotes' indentation is stripped from every line, so the block
can sit indented in your code and still start at the left margin.

Every line end between the quotes is part of the text, including the one
just after the opening quotes and the one before a closer on its own line.
So `help` begins and ends with a line end:
`"\nusage: tool [options]\n  -v    verbose\n"`. For text that should start
with its first line, as expected output usually should, start it on the
opener's line. Nothing is stripped from that line, and the closer's
indentation is still stripped from the lines after it.

```landin
expected := """usage: tool [options]
            -v verbose
            """
```

The fine print:

- The whole opening run of quotes sets the count. Six quotes in a row are
  one opener of six, not an empty literal, and a matching closer must
  follow later.
- For empty text, write `""`.

## OPERATORS

### [0290] Arithmetic

The arithmetic operators are `+`, `-`, `*`, `/` and `%`. Integer division
truncates toward zero, and the remainder takes the sign of the dividend, as
in C.

```landin
q := -7 / 2 -- -3
r := -7 % 2 -- -1
```

### [0300] Overflow traps; wrapping is a separate operator

Integer overflow traps. When you want wrap-around, say so with `+%`, `-%`
or `*%`. Each has an assignment form, such as `+%=` ([0390]).

```landin
wrap_demo: () -> (ticks: u8) =
    ticks = 255
    ticks +%= 1 -- wraps to 0
end wrap_demo
```

### [0310] Conversions are written out

Nothing converts implicitly, except that a writable reference passes
where a read-only one is expected ([0440]). To convert, apply the type to
the value, like a call. If the value is known at compile time, an
impossible conversion is a compile error; otherwise it traps at run time.
A float converts to an integer by truncating toward zero. An integer
converts to a float by rounding, and that never traps.

```landin
-- bad: u8 = u8(300)        compile error
narrow_reading: (reading: u32) -> (small: u8) =
    small = u8(reading) -- traps if reading is above 255
end narrow_reading

greeting_bytes: []u8 = []u8(greeting) -- the same bytes, not a copy
whole_part := i64(45.7) -- 45: truncates toward zero
```

You can write the type directly, as `[]u8(greeting)` does here, rather than
declaring an alias for it first. Either spelling means the same conversion.

The fine print:

- Type prefixes nest as they do in declarations: `[][2]u8(value)` converts
  to a slice of two-byte arrays, and `tag(u32, 7)(value)` to a
  parameterized type with every parameter given. The last parentheses hold
  the one value.
- As with a call result, bind the result before you index it, select a
  field or call it.
- A converted reference keeps its storage and origin ([0770]).
- `ptr u8(value)` applies the type `ptr u8`: it can take the pointer out of
  a distinct type ([0650]), but it never turns an integer into a pointer.
  `ptr(address)` does that, taking its pointer type from the declaration
  ([0460]).

### [0320] Shifts

`<<` and `>>` shift. Bits shifted out are gone and zeros come in, and a
signed `>>` keeps the sign. There is one form of each.

```landin
z: u32 = 1 << 40 -- 0 in a u32 context
```

The fine print:

- The amount has the same type as the value being shifted.
- An amount at or past the width gives zero on every shift, signed `>>`
  included; the amount never wraps around.
- A negative amount is refused when the compiler knows it and traps when it
  does not.

Exact rules: spec [1950].

### [0330] Bitwise operators

The bitwise operators are `&`, `|`, `^`, `~`, `<<` and `>>`. Unlike in C,
they bind tighter than comparisons, so the usual mask test needs no
parentheses.

```landin
count_is_even := count & 1 == 0 -- means (count & 1) == 0
```

### [0340] Logical operators

The logical operators are words: `and`, `or` and `not`. That leaves `!`
free for errors.

```landin
finished: bool = false
keep_going := count < 10 and not finished
```

### [0350] Comparison

The comparisons are `==`, `<>`, `<`, `<=`, `>` and `>=`. Inequality is
`<>`, not `!=`. Comparisons do not chain (spec [1820]).

### [0360] Ranges

A range is written in a `for` header or a slice: `0..9` includes 9, and
`0..<10` stops before 10.

```landin
digit_sum: () -> (total: i32) =
    total = 0
    for i in 0..9 do
        total += i
    end for
end digit_sum
```

The same bounds select part of a slice, as in `items[0..<10]`. A range is
not a value: you cannot store, pass or return `0..<10` on its own. There is
no form that excludes the left end. For custom stepping, a library supplies
an iterable value ([1330]).

### [0370] `sizeof`, `alignof`, `lenof` and `offsetof`

These four measure things: the size of a type, its alignment, a length,
and where a struct field begins.

```landin
w1 := sizeof u32 -- 4
a1 := alignof u64 -- 8
o1 := offsetof reading_head.value -- 2: one byte of padding after sensor

reading_head: type = struct
    sensor: u8
    value: u16
end reading_head

roll_die: () -> (face: u8) =
    face = 4
end roll_die

measure_demo: (words: []u32) -> (total: usize) =
    samples: [8]u16 = zeroed
    total = lenof samples -- 8, known at compile time
    total += lenof words -- the slice's length, at run time
    total += lenof ([roll_die(), roll_die()]) -- 2; roll_die is not called
end measure_demo
```

The fine print:

- `lenof` measures a name, a field or element reached through it, or what
  a call returns. A call whose result is measured runs; the elements of a
  measured literal, like the `roll_die()` calls above, are checked to have
  one scalar type but not evaluated. An array that a name or path reaches
  is not read, because its type holds its length.
- `offsetof` gives a field's offset in bytes from the start of its struct
  type, through nested structs.
- `lenof` and `offsetof` are not reserved: everywhere else, they are
  ordinary names.

### [0380] `addr` and `.val`

`addr` takes an address, and `.val` is the thing a pointer points at:
read on the right of an assignment, written on the left. [0430] shows
both.

### [0390] Assignment is a statement

Assignment is a statement, never an expression, so it cannot hide inside a
condition. The assignment operators are `=`, `+=`, `-=`, `*=`, `/=`, `%=`,
`&=`, `|=`, `^=`, `<<=` and `>>=`, plus the wrapping `+%=`, `-%=` and
`*%=`.

### [0400] No `++` and no `--`

There is no `++` or `--`. The statements `inc` and `dec` do the job,
though `x += 1` says the same thing.

```landin
inc total
dec total
```

### [0410] Evaluation order is fixed

Landin fixes the order in which things are evaluated, so you can see where
costs happen:

- operands and call arguments, left to right;
- a struct's fields, in the order you write them, whatever order the layout
  puts them in;
- `and` and `or`, left to right, stopping as soon as the answer is known;
- an assignment, its destination first, then the value.

A deferred call is the one thing not evaluated where it is written; [1100]
says when it runs.

### [0420] What the dot means

The dot always selects a member of something:

| example | selects |
|---|---|
| `p.val` | what a pointer points at |
| `t.less` | an entry of a concept |
| `http.get` | a member of a module |
| `f64.nan` | a named value of a type |

The tokens `..` (a range), `...` (an inferred error set) and the decimal
point are separate things.

## FUNCTIONS

### [0870] Declaring a function

A function is a name bound to a value of a function type. There is no `fn`
keyword: `=` opens the body and `end` closes it, always.

```landin
double: (x: i32) -> (r: i32) =
    r = x * 2
end double
```

Results have names, like parameters. The body sets `r` by assigning it, and
whatever `r` holds when the body ends is what the caller gets.

### [0880] One-line functions

When the body is a single expression, write it after `=`. It still takes an
`end`, and the expression fills the named result.

```landin
triple_it: (x: i32) -> (r: i32) = x * 3 end
```

### [0980] Calling: positional, then named

Arguments are positional first, then named. There are no default values:
every parameter gets exactly one argument.

```landin
volume_of: (width: u32, height: u32, depth: u32) -> (v: u32) =
    v = width * height * depth
end volume_of

volumes: () -> (total: u32) =
    a := volume_of(2, 3, 4)
    b := volume_of(2, depth: 4, height: 3)
    c := volume_of(width: 2, height: 3, depth: 4)
    total = a + b + c
end volumes
```

The positional arguments fill parameters in order; the named ones may come
in any order after them. An unknown or repeated name is an error. Arguments
run in the order you wrote them. Named arguments work in a call statement as
well as in a call expression.

- Calling through a stored function uses the parameter names of that
  value's type. Those names are not part of function-type identity
  ([1000]).
- A generic call may name its compile-time arguments in the same list:
  `copy(t: u8, n: 4, source: bytes)`. Name one and you name them all
  ([1290]).
- A C variadic call adds an unnamed tail ([1580]); it does not add optional
  parameters.

### [0890] Returning nothing, and never returning

`none` means the function returns normally with no value. `noreturn` means
it never returns at all.

```landin
log_it: (m: utf8) -> none = end log_it
halt_it: () -> noreturn = loop do end loop end halt_it
```

A `noreturn` body has to diverge on every reachable path: an unconditional
`loop` with no exit, or a call to another `noreturn` function. A conditional
loop does not count, even if you expect it to run forever. Because the call
ends the path, a branch that calls `halt_it()` needs no value of its own.

- `noreturn` is part of the function's type: a `() -> none` function cannot
  stand in for a `() -> noreturn` one, or the other way round.
- A `noreturn` function declares no errors ([0940]): failing would return
  to the caller.
- The call does not unwind `defer` ([1100]). A deferred `noreturn` call
  stops the cleanup that would follow it, and the original exit.
- C declarations may use it. Interrupt and naked handlers stay
  `() -> none`.

### [0920] Several results

A function can hand back several named results.

```landin
divide: (a: i32, b: i32) -> (quot: i32, rem: i32) =
    quot = a / b
    rem = a % b
end divide
```

Two or more results travel together as one anonymous struct, laid out in the
order you wrote them. A single result is just its own type, not wrapped.

### [0930] Every result is assigned before returning

Each named result must be assigned on every path that returns. The compiler
checks this, so there is no "uninitialised return value". A path that fails
([0940]) need not assign them, and the caller cannot read them then.

### [0990] Using a multiple result

The results of a call form an anonymous struct. Bind it whole and read its
fields, or take it apart by name, never by position.

```landin
whole := divide(10, 3)
sum := whole.quot + whole.rem
(quot, rem) := divide(10, 3)
(quot: q2) := divide(20, 3)
(quot, _) := divide(30, 3)
```

The call runs once. You can pick names in any order, leave some out, or
rename one after `:`; `_` says the rest is ignored on purpose. A whole
result can also be the value of an `if`, `match` or block when every branch
gives the same names and types.

The names belong to the call, not to the function's type: two function types
with the same result types in the same order agree whatever the results are
called ([1000]).

### [1020] Throwing a result away

Ignoring a result is never silent. Say so with `_ =`.

```landin
_ = double(5)
```

A call to a function that returns `none` has nothing to discard, so it is
written on its own, and `_ =` in front of it is an error (spec [1930]).

### [0900] Three parameter conventions

A convention says what the function may do with the value you hand it. It is
about the argument itself, never about what the argument points at: that is
the pointer type's job ([0450]).

| convention | what it promises |
| --- | --- |
| `in` | I will not change the value. The default, unmarked. |
| `inout` | I may replace it, and the change comes back to the caller. The argument must be mutable. |
| `sink` | I consume it. The place the caller named is dead afterwards ([0910]). |

`[]u8` is a slice of bytes, a view of someone else's bytes ([0570]):

```landin
process: (source: []u8, inout target: []u8, sink owned: []u8)
         -> (written: u32) =
    written = 0
end process
```

So a function that writes device registers through a pointer, but never
re-points it, takes the pointer as `in`, and the `mut` lives in the pointer
type ([0430]). There is no `out` convention: outputs are named results.

`escaping` is a separate word that can go with any of the three. It says the
function may keep what a pointer, slice or `any` refers to after the call
returns, so the caller has to show it lives long enough ([0780]). `sink`
makes the caller's place unusable afterwards; `escaping` lets the callee
keep a reference. The two can go together. On a type parameter, `escaping`
asks nothing when the type holds no references ([0840]).

An `inout` argument need not be a binding: a pointer target such as
`c.inner.val` is fine. One call may not pass the same binding-rooted place to
two `inout` parameters. Two different pointer or computed-index paths may
still alias; the compiler cannot see that, and does not promise to ([1720]).

### [0910] `sink` consumes a place

A `sink` argument is a place, and after the call that place is dead until you
assign it again. A field of a binding is a place, so consuming a struct's
field needs no temporary.

```landin
message: type = struct
    body: []u8
    size: u32
end message

release: (sink bytes: []u8) -> none = end release

clear_message: (inout m: message) -> none =
    release(m.body) -- m.body is dead from here
    m.body = [] -- and live again from here
    m.size = 0
end clear_message
```

Reading `m.body` between those two lines is an error. That closes the window
between releasing storage and repointing the field, which a temporary binding
would have left open.

This is a use-after-consume check on one place, not ownership. The value is
still copyable: a copy made before the sink stays live, and consuming through
both is not caught.

- The place is a path from a binding through fields and literal fixed-array
  indexes. A path through a pointer (`p.val.items`), a computed index
  (`xs[i].items`) or a slice index is refused; a whole slice may be sunk.
- A field sunk out of an `inout` parameter must be assigned again before
  every return, failure included. A `defer` or `undo` may do it.
- Arguments are evaluated left to right first, and the places are consumed
  as the call begins: `use(value, value.count)` is fine when `use` sinks
  its first parameter.
- Sinking one place twice in a call, or a place also passed `inout`, is
  refused.

Exact rules: spec [1910].

### [1040] Passing the call site: `caller`

A `caller` parameter is filled in by the compiler with where the call was
written, so assertions and logging need no macros. Its type is a struct you
declare, with exactly these three `u32` fields, in this order:

```landin
site: type = struct
    file_id: u32
    line: u32
    column: u32
end site

report_failure: (where: site) -> none = end report_failure

assert: (cond: bool, caller where: site) -> none =
    if not cond then
        report_failure(where)
    end if
end assert
```

Used as: `assert(count > 0)`.

The caller leaves the parameter out, and inside the function it is an
ordinary immutable struct you can read, copy and store. It is 12 bytes on
every target. Line and column count from one. The file number is only a
number: the table mapping it to a filename is written beside the program
and need not ship with it, which keeps names out of firmware ([1670]).

A wrapper that wants to report its own caller's position passes its
`caller` parameter on by name:

```landin
checked: (cond: bool, caller where: site) -> none =
    assert(cond, where: where)
end checked
```

Leave out `where:` there and the report points at the wrapper's own call
instead. Only a `caller` parameter can fill a `caller` position: a copied or
constructed `site` cannot.

This `site` is not the `site` a panic handler receives at [1670]: that one
is a single `u32` number the compiler gives a failing check. Exact rules:
spec [1920].

### [1000] Functions are values

A function type is an ordinary type, written the way a signature is, and a
function is a value of it: a code address. There is no separate
function-pointer type, and you never write `addr` on a function.

```landin
default_handler: () -> none = end default_handler
handler: type = () -> none
mut current: handler = default_handler
```

Two function types agree by their parameter and result types, in order. The
names inside them only describe the positions. The comparison is recursive
when a parameter or result is itself a function. Calling convention and
variadicness count too: a C callback type is written
`extern(c) (parameters) -> returns`, and a Landin function never matches it.

A module binding set to a named or anonymous function is a fixed code
address. A mutable binding may later take any function with the same
complete signature. A `ptr` to a function type points at a cell holding the
address, not at the code.

Nothing is captured ([1010]), so a callback is a function and an explicit
state pointer:

```landin
on_byte: type = struct
    call: (state: ptr u8, b: u8) -> none
    state: ptr u8
end on_byte
```

Call it through the field: `callback.call(callback.state, byte)`. The field
keeps its full signature through every copy, assignment, variant payload and
array. Whether it may be replaced depends on the binding that holds the
struct. The callee is evaluated before the arguments.

### [1010] Anonymous functions

An anonymous function is a signature and body without a name. It captures
nothing: inside, it sees module declarations and its own parameters, results
and locals, but none of the enclosing function's.

```landin
less_i32 := (a: i32, b: i32) -> (yes: bool) = a < b end
```

Writing one makes a fixed code address; it does not run the body. State
travels as an explicit parameter, as in [1000]'s callback.

A bound anonymous function is a value: `less_i32(1, 2)` calls it, and it
can be passed wherever its function type is expected, but it cannot supply
a concept's entry ([1240]).

## TYPES YOU DECLARE

Atoms, structs, variants, and types made from other types. Device register
images, which are also types you declare, are with the machine-level
material at [0730] and [0740].

### [0630] Atoms

An atom is a name that is its own value and its own type. Declaring one
gives you both at once, because for an atom they are the same thing.

```landin
not_found: atom
no_access: atom
```

Atoms compare with `==` and `<>`, and nothing else. Two atoms are equal
when they are the same declaration, even when the values come from two
different atom sets:

```landin
is_missing: (outcome: not_found | no_access) -> (missing: bool) =
    missing = outcome == not_found
end is_missing
```

An atom has no number behind it as far as your program can tell: it is not
ordered and does not convert to or from an integer.

### [0640] Enumerations are unions of atoms

An enumeration is a union of atoms. `north`, `south`, `east` and `west`
were declared at [0100].

```landin
compass: type = north | south | east | west
```

The union may be written in place as the type of a binding, a parameter,
a return or a field, and it is the same type as the declared name:
`facing: (way: north | south) -> (ahead: bool)` takes a `compass` value
that is north or south. As the element of an array, a slice or a pointer
the union needs its name.

An atom set can be an array element, a struct field or a variant payload,
and it stays that set there: a write needs one of its members, and reading
it back gives you an atom, not an integer.

### [0650] Distinct types

`distinct` makes a new type with its base's representation that never
mixes with its base or any other type. Arithmetic does not come along;
comparison, and the bit operations of an unsigned base, do.

```landin
meter: type = distinct f32
second: type = distinct f32
```

You cannot add a `meter` to a `second`, and you cannot even add two
`meter` values: `f32`'s arithmetic does not come along. To get a value in
or out, apply the type, as for any conversion ([0700]):

```landin
length: meter = meter(2.5)
raw: f32 = f32(length)
```

That is the whole point: a type the compiler keeps apart from its base and
from every other distinct type, at no runtime cost. Generic deduction and
conformances tell it apart too, and an alias of it keeps its identity.

A few things do carry over, because they ask nothing of what the value
means:

- Equality. `==` and `<>` work when the base has them: a scalar, an atom
  set, a pointer or a function value. A descriptor compares without taking
  its number out.
- Ordering, when the base is a scalar: `<`, `<=`, `>` and `>=` order as
  the base does.
- Flags, when the base is an unsigned integer: `&`, `^`, `|` and `~` give
  the same distinct type, and `&=`, `^=` and `|=` update in place, so a set
  of flags stays one.
- The zero image. A record holding a distinct value may be `zeroed`
  ([0540]), though `zeroed` written for the distinct type itself does not
  construct it.

```landin
farther: (a: meter, b: meter) -> (yes: bool) =
    yes = a > b
end farther
```

Arithmetic and shifts stay with the base. A distinct value meets its base or
any other type only through a conversion, and that includes comparing with
it. A wrapped reference keeps its origin. Exact rules: spec [1890].

### [0660] Range subtypes

A range subtype is an integer type limited to a run of its values. It is
checked when a value goes in.

```landin
percent: type = u8 range 0..100
```

The check happens at a binding, a parameter, a named return and a
conversion. A value outside the range is refused when the compiler knows
it, and traps otherwise. Arithmetic on a `percent` gives a plain `u8`; the
range is not part of the result.

A range subtype is not allowed as a struct field, an array element, a
pointer or slice target, a generic argument, or something `addr` can point
at. In each of those, a write through the base type could reach the storage
unchecked. To keep a checked value in storage, wrap it: a `distinct` type
that only a checking function constructs carries the proof ([1730]).

A guard on an ordinary integer does not make it a `percent`. If you reject
bad input with a `fail` guard and then store the integer as `percent`, that
store still has its trapping check. Once the value is in a `percent` place,
passing it to another `percent` place needs no second check.

### [0670] Structs

A struct is written either as a block or inline in parentheses. The two
mean the same thing, and the inline form is also how parameter lists,
return lists and payloads are written.

```landin
size2: type = (w: u32, h: u32)
```

A struct is nominal in either form: two separately declared structs with
the same fields are different types. An alias keeps the original identity.

- Either form may take type and fixed parameters, and `layout` ([0750])
  applies to either. The parameters are compile-time names: they add no
  field and no hidden runtime argument.
- Each fully applied instance of a parameterized struct is its own type,
  identified by the declaration and all its arguments, even an argument the
  fields do not use. Aliases of the arguments make no new type; a
  different argument does, even when the fields and layout come out equal.
- A struct may mention itself, or another struct that mentions it back, in
  a function parameter or result: a function field is one code address, so
  the layout stays finite.

### [0680] Structs with a variant part

A struct may end in a variant part: one of several cases, each with its
own fields. The fields every case shares need no ceremony.

```landin
figure: type = struct
    label: utf8
    area: f32
    kind: variant
        circle: (radius: f32) |
        rectangle: (width: f32, height: f32)
    end kind
end figure
```

### [0690] Cases with no payload

A case with no fields is written bare. A bare case is an atom, like any
other ([1700]), so a variant part reads as a union of its cases.

```landin
node_kind: type = struct
    kind: variant
        leaf |
        branch: (first: u32, count: u32)
    end kind
end node_kind
```

You write a case where its variant part is the context: when you construct
into that part, and when you name an arm of a match on it. A case is not a
value apart from its part, and the part is not a value apart from its
struct: copy the struct, or match it.

Selecting a bare case writes only its tag. Selecting a case with fields
zeros that case's fields first, then writes the ones you gave. The bytes of
the inactive cases and the padding are unspecified afterwards, though
`zeroed` still writes the whole struct as zeros. Selecting a case therefore
costs the size of that case, not the size of the largest one.

### [0700] Constructing values and converting them

Construction and conversion look the same: a type applied to arguments.

```landin
origin := point(x: 0.0, y: 0.0)
metres := meter(1.5)
```

A variant case is built the same way, with the case name applied to its
fields. You read one back with `match` ([1210]).

```landin
mut f: figure = (label: "disc", area: 0.0, kind: circle(radius: 2.0))
f.kind = rectangle(width: 3.0, height: 4.0)
```

### [0710] Struct literals take their type from context

A struct literal has no type of its own, like a number literal. It takes
the named struct type its context wants. A struct type written inline is
not yet such a context: declare the type and use its name (spec [1830]).

```landin
here: point = (x: 1.0, y: 2.0)
```

What does not convert is a value that already has an anonymous struct type,
such as a call's results. `divide(10, 3)` gives `(quot: i32, rem: i32)`,
and that value never becomes a named struct with the same fields. Two
anonymous types match when their field names, types and order all match.

At module scope, a struct literal is a static image the compiler builds,
not code run before the entry point ([1460]). Exact rules: spec [1940].

### [0720] Filling the remaining fields with `of`

`of` at the end of a struct literal fills every field the literal did not
name. It is the same word in the same place as in array literals ([0560]).

```landin
window: type = struct
    width: u32
    height: u32
    visible: bool
    resizable: bool
end window

main_window: window = (width: 640, height: 480, of false)
tiny_window: window = (width: 1, of zeroed)
```

The fill has to typecheck for each field it fills: `of false` works where
the rest are `bool`, and `of zeroed` ([0540]) wherever the rest have a zero
image. A fill other than `zeroed` needs at least one omitted field, and all
of the omitted fields must have exactly the same type, array length and
reference permission included. It is evaluated once, after the named
values, and copied into each remaining field in declaration order.

This is not a default value: declarations have none ([0980]), because a new
parameter would then fit every existing call silently. Here whoever writes
the literal makes the choice. The trade is theirs too: a literal with `of`
picks up a field added later without a word, and one without it breaks
loudly.

### [0750] Field order and layout

Fields stay in the order you wrote them, with natural alignment and padding
in between. A hexdump matches the source, and the layout does not shift
under a new compiler or an optimization flag.

```landin
packet: type = layout(c) struct
    kind: u8
    length: u16 -- big-endian as the wire sent it
    id: u32
end packet

from_big_u16: (wire: u16) -> (value: u16) =
    value = (wire << 8) | (wire >> 8) -- on a little-endian target
end from_big_u16
```

Other layouts are asked for by name:

| layout | what it does |
|---|---|
| no `layout` | source order, natural alignment |
| `layout(optimal)` | sorts fields by descending alignment, but only if that makes the struct strictly smaller |
| `layout(c)` | the selected target's C rules (spec [1975]) |
| `layout(c, packed)` | C's byte-packed record: every field at alignment one, no padding |
| `layout(packed)` | a register image of bits ([0730]) |

Byte order is not a property of a field. A field holds the target's own
order, which `compiler.byte_order` names ([1560]). When your program reads
or writes another order, it converts where the bytes cross, with shifts
([0320]) or an ordinary function, so the cost is visible where it is paid,
as in `from_big_u16` above.

- `layout(optimal)` keeps source order when sorting saves nothing, moves
  nested structs, arrays and variant parts whole, and never makes a struct
  fit for C.
- `layout(c)` does not choose a function's calling convention. A C record
  holds native-endian scalars, fixed arrays, nested nonempty C structs and
  callback fields declared with C's convention.
- A `layout(c, packed)` record's fields are read and written by copy and
  have no address of their own. C takes such a record through a pointer.
- A C record's last field may be `[0]T`, C's flexible array member, whose
  elements follow the record in memory.
- Every byte count comes from the selected target, 32-bit targets
  included. Initializers still run in the order you wrote them ([0410]).

### [0760] Attributes

Attributes are prefix words from a closed set. Their arguments are always in
parentheses. Where an argument is one of a fixed set of values it is an
atom; a linker name is a string. These are the words, with the arguments
each takes:

| word | arguments | where it is described |
|---|---|---|
| `mut` | none | [0060] |
| `public` | none | [0090] |
| `layout` | `c`, `optimal`, `packed`, or `c, packed` | [0730], [0750] |
| `escaping` | none | [0780] |
| `caller` | none | [1040] |
| `fixed` | none | [1490] |
| `option` | none; it implies `fixed` | [1530] |
| `link` | `section: "..."`, `symbol: "..."`, `align: 16`, `vector: 16`, `keep` | [1640] |
| `extern` | `c`, `interrupt`, `naked`, and others | [1570] |

`at` gives a field its bit position ([0730]). `at`, `of` and `align` are
contextual: a field or an entry may still be called one of them, because
nothing reads the word as an attribute there. Placement alignment is
`link`'s `align` label ([1640]), not a word of its own. `from` and `with`
are reserved and cannot name anything.

There is no `volatile`: a device access is an operation ([0740]). There is
no `big` or `little`: byte order is converted where bytes cross ([0750]).
There is no `inline` or `noinline`: inlining is the optimizer's decision
([1310]). And there is no `weak`: a whole program links one definition per
name, and the compiler-owned vector image does what weak default handlers
do in C ([1640]).

## CONTROL FLOW

Every construct opens with its own word and closes with `end`, so you never
count braces. The short snippets in this section are statements inside a
routine with a parameter `x: i32`, a writable slice `items: []mut i32`, a
path `path: utf8` and a result `out: i32`. Helpers such as `is_ready()`,
`expensive()` or `cleanup()` stand for routines that do what their names
say.

### [1050] Branching with `if`

`if` takes a condition of type `bool`, and `then` begins the body. No
integer or pointer stands in for a `bool`. `elsif` and `else` are
optional, and `end if` closes the whole thing.

```landin
    if x > 0 then
        out = 1
    elsif x < 0 then
        out = -1
    else
        out = 0
    end if
```

### [1060] Every construct fits on one line

No construct needs a newline: `end` is what closes it, so any of them can be
written on one line.

```landin
    if x > 0 then out = 1 end if
```

`refine fmt` leaves a one-line form on one line; it never joins or breaks
lines.

### [1070] Declaring a name in a condition

An `if`, `elsif` or `while` condition may declare a binding, inferred or
with a written type. The binding's value is the condition, so it must be a
`bool`; anything else is an ordinary type error.

```landin
    if ok := is_ready() then
        out = 1
    end if

    while mut more: bool = has_more() do
        consume_next()
        more = false
    end while
```

The name exists only in the body that condition guards: not in a later
`elsif`, the `else`, a loop's `complete`, or after the construct. Its
initializer runs before the name exists, so it cannot refer to itself, and
a `while` runs the initializer again before every iteration.

Exact rules: spec [1840].

### [1080] Blocks have values

`if`, `match`, bare blocks and loops are expressions as well as statements.
The value is the last expression of the block that ran.

```landin
    sign := if x > 0 then 1 else -1 end if

    doubled := begin
        a := expensive()
        a * 2
    end
```

Rust needs a semicolon to tell a block's value from a statement. Landin
does not: throwing a value away is always written `_ =` ([1020]), so a bare
expression at the end of a block can only be its value.

- Every arm that falls through must end with a value of one complete type
  and shape. An `if` used as a value therefore needs its `else`.
- An arm that leaves by `return`, `fail`, `break` or `continue` supplies no
  value and needs no placeholder.
- Only arms that fall through count when the compiler decides whether a
  name is assigned after the construct. An arm that has left proves
  nothing for the others.
- Statements and the final expression run in source order, after the `if`
  condition or `match` subject, and only in the selected arm.
- Used as a statement, an arm may not end with a value: nothing would take
  it.

Exact rules: spec [1910].

### [1090] Bare blocks: `begin ... end`

`begin ... end` opens a scope: names declared inside are gone after its
`end`.

```landin
    begin
        tmp := x * 2
        out = out + tmp
    end
```

With a label, `name: begin ... end name`, a `break name` can leave the block
early, and its cleanups run as a loop's do ([1180]).

### [0940] Errors: what can fail is in the signature

A routine that can fail lists, after `!`, the atoms it can fail with, and
`fail` leaves with one of them. An atom is a declared name that is its own
value, such as `port_zero: atom` ([0630]). A caller cannot ignore a failure:
every call to a failing routine is either passed on or handled.

Here is all of it at once. `port_from` reads a port number with the
library's `text.to_u32`, which fails on bad digits, and adds a failure of
its own. Its callers then deal with the result in two different ways:

```landin
import core/text

port_zero: atom

port_from: (digits: utf8)
           -> (port: u32)
           ! text.invalid_number | text.number_overflow | port_zero =
    port = try text.to_u32(digits)
    fail port_zero when port == 0
end port_from

listen_port: (setting: utf8) -> (port: u32) =
    port = port_from(setting) else 8080
end listen_port

port_or_complaint: (setting: utf8) -> (port: u32, complaint: utf8) =
    complaint = ""
    port = port_from(setting) else (problem)
        match problem
            port_zero: complaint = "port 0 is reserved"
            _: complaint = "not a port number"
        end match
        8080
    end
end port_or_complaint
```

- `try` passes a failure on: if `text.to_u32` fails, `port_from` fails
  with the same atom, which is why its `!` lists them ([0960]).
- `listen_port` cannot fail. Whatever went wrong, 8080 stands in for the
  result.
- `port_or_complaint` binds the atom to `problem`, looks at it, and ends
  the block with the value that stands in ([1030]).

Those are the four ways to call something that can fail:

| you write | when the call fails |
|---|---|
| `try f()` | your routine fails with the same atom |
| `f() else value` | `value` stands in for the result |
| `f() else (e) ... end` | the block runs with the atom bound to `e` |
| `f() else none` | nothing; the next statement runs |

A shorter declaration, which the next entries use. `not_found` and
`no_access` are the atoms declared at [0630]:

```landin
open_file: (path: utf8) -> (handle: u32) ! not_found | no_access =
    fail no_access when lenof path == 0
    handle = 1
end open_file
```

An error set is a set: aliases flatten, order does not matter, and a
routine that fails with `a` passes where `a | b` is expected. The atoms
carry no payload. They travel in a register of their own, so failing costs
about what returning does.

Exact rules: spec [1980].

### [0960] Passing a failure on: `try`

`try f()` calls `f`, and if it fails, your routine fails with the same
atom after running its cleanups ([1100]). Every atom you might pass on must
be in your own `!` set. The `try` sits at the call, so you can see in the
source every place a routine may leave early.

```landin
read_config: (path: utf8) -> (data: []u8) ! ... =
    h := try open_file(path)
    data = []
end read_config
```

`! ...` means "whatever my callees can fail with": the compiler works the
set out from every `fail` and `try` in the body. Use it inside a module,
where the compiler sees every caller anyway. Anything public must write
its set out, because a public signature is a promise, and a change three
modules down must not rewrite it silently. So must function types,
anonymous functions, concept entries ([1260]) and anything exported to C,
because their complete signature is their type. An inferred set that comes
out empty means the routine cannot fail.

`try for item in source do ... end for` passes on a failure from any
traversal step ([1150]). The enclosing routine must declare or infer the
atoms, and its caller handles them with the ordinary `else` on that call.

Exact rules: spec [1980].

### [1030] Handling a failure: `else`

An `else` after a call handles its failure on the spot. The handler either
supplies a value in place of the result, or leaves: `return`, `fail`,
`break` or `continue`.

```landin
h1 := open_file(path) else 0
h2 := open_file(path) else (e) fail e end
h3 := open_file(path) else (e)
    match e
        not_found: 0
        _: fail e
    end match
end
```

`try f()` is short for the second line. A handler that leaves needs no
value, the same rule an arm of an `if` follows ([1080]), so nobody invents
a placeholder to satisfy the type. The handler supplies the value; it does
not assign the binding being initialized.

- `else (e)` binds the atom. `e` has the call's whole error set and exists
  only inside the block. A `match` on it must cover every atom, or end
  with one `_` arm for the rest ([1210]).
- The name may go unused. To run statements without naming the atom at
  all, give `else` a bare block as its value: `else begin ... end`.
  `else (_)` is refused; leave the parentheses out instead.
- On a call that returns nothing, there is no value to supply: the block
  only handles the error, and the statement after the call runs next.
- The result may have any shape, from a scalar to a struct or several
  named results.

Inside an `if` arm, `else value` after a call is the `if`'s own `else`,
which is how `if c then a() else b() end if` reads. To handle the call's
failure there, parenthesize it, `(open_file(path) else 0)`, or bind the
error: `else (e)` always belongs to the call, wherever it is written.

Being an expression, a handled call also works inside a larger one, as an
operand or an argument:

```landin
next_handle := (open_file(path) else 0) + 1
```

A failing call needs `try` or `else` even when you throw its result away.
`else` handles only declared failure: a result that is a union, such as
[0480]'s maybe-pointer, is taken apart with `match`.

A call that returns nothing, and whose failure does not matter where it is
made, says so in one word. Here `flush` writes out a buffer and returns
nothing:

```landin
flush(out) else none
```

`else none` is the bound block with nothing in it, minus the name nobody
would read: what the call did before it failed stays done, and the next
statement runs. On a call that returns a value, `else none` is allowed
only when the whole call is discarded with `_ =`; anywhere else a failure
would leave a result unset that something reads. Here `parse_header`
returns a value:

```landin
_ = parse_header(input) else none
```

Used any other way, that call needs `else value`, a block, or `try`.

### [0970] Leaving early: `return` and `fail`

`return` leaves the routine with its named results as they stand, and
`fail` leaves with an error. Each takes an optional `when condition`.

```landin
clamp_low: (x: i32, floor: i32) -> (r: i32) =
    r = floor
    return when x < floor
    r = x
end clamp_low
```

Only exits take `when`: `return`, `fail`, `break` and `continue`.

### [0950] What deserves an error, and what does not

A failure ends the operation without a result, and the caller handles it.
A diagnostic is reported while the work goes on. Choose by what the caller
needs: no result at all, or a result with notes about what was wrong. Where
you can see a problem in what you already hold, prefer checking for it and
working around it to failing.

`sum_digits` notes a problem instead of failing on it. It adds the digits
in a line and counts what it had to skip, so every line still gets a sum:

```landin
--- Adds up the digits in a line and counts what is not a digit.
sum_digits: (line: []u8) -> (sum: u32, skipped: u32) =
    sum = 0
    skipped = 0
    for b in line do
        if b >= u8('0') and b <= u8('9') then
            sum += u32(b - u8('0'))
        else
            inc skipped -- noted, and the work goes on
        end if
    end for
end sum_digits
```

- A parser is the usual case: a syntax mistake is entirely in the bytes it
  is reading, so it records a diagnostic and carries on. One that stops at
  the first mistake hides the other twelve.
- Input with no usable answer may well be a failure: [0940]'s `port_from`
  fails on text that is not a port, because its caller has no port to use.
- Out of memory, a missing file, an unplugged device: these depend on the
  world, not on your data, and checking first would only be a race. They
  are failures.

Collecting diagnostics needs somewhere to put them, and that is an
ordinary parameter. The library's sink is the concept `core/diag.log`,
which a routine takes as `inout log: any diag.log`, meaning any kind of
log at all ([1370]). Its `note` entry takes a position in the text, a
severity and the message bytes. Recording a note is a diagnostic; failing
to record it is an operation failure, so `note` declares `io.io_failed`,
and a routine that records notes lists it too.

- A bounded logger never fails. When it is full it stops keeping entries,
  counts them in `dropped`, and still records whether an error was
  reported.
- A streaming logger writes as it goes, and fails with `io_failed` when a
  write does.
- Both pass as `any diag.log`, so the producer does not know which policy
  its caller chose. The sink is a capability ([1680]): passing one makes
  the destination explicit, though the parameter list alone does not
  prove that the routine cannot make another sink or reach the host.

### [1100] Cleanup on the way out: `defer`

`defer call` runs the call when its block is left: by falling off the end,
`return`, `break`, `continue` or a failure. Entries run in reverse order,
inner blocks before outer ones.

```landin
    defer cleanup()
```

There are no destructors, so this is how anything gets closed, flushed or
freed.

The call's arguments are read when it runs, not when the `defer` is
written. Here `walk_steps` leaves `trail` at 2, not 1:

```landin
record_step: (inout trail: i32, step: i32) -> none =
    trail = step
end record_step

walk_steps: (inout trail: i32) -> none =
    mut step: i32 = 1
    defer record_step(trail, step)
    step = 2
end walk_steps
```

- A trap stops the program and runs no cleanup.
- An entry counts only once control has reached it. A `return` above the
  `defer` does not run it.
- At exit, the callee is evaluated first, including a function field, then
  the arguments, reading the places they name at that moment. So a `defer`
  that sinks something sinks it at the end, and the thing stays usable in
  between. If a place was re-pointed meanwhile, the `defer` sees what is
  there now.
- The block's value, or its failure atom, is settled before the deferred
  calls run.
- Registering an entry evaluates nothing, costs nothing and reserves
  nothing.

### [1110] Cleanup only on failure: `undo`

`undo call` is a `defer` that runs only when a declared failure leaves its
block: a `fail`, a `try` that passes a failure on, or a failure arriving
from a deeper call.

```landin
    undo release(handle)
```

- Falling off the end, a successful `return` and `break` skip it. So does a
  trap: it stops the program and unwinds nothing.
- A caller's `else` that handles the failure does not leave the caller's
  block, so the caller's `undo` entries do not run. The failing callee's
  own entries have already run on the way out.
- In one block, `defer` and `undo` entries share one order: on failure they
  run interleaved, in reverse order of writing, inner blocks first.
- Like `defer`, an `undo` evaluates its callee and arguments only when it
  runs, and sees their values then.

It is its own word, not a flavour of `defer`: to defer is to do it later,
and this may never be done at all. It is a compensating action.

### [1200] Cleaning up several acquisitions

Because an entry exists only once control reaches it, a run of fallible
acquisitions cleans up exactly what it got. If the first fails, nothing is
released; if the second fails, one is; if the third fails, two are.

```landin
close_file: (handle: u32) -> none =
    -- hand the handle back to the system
end close_file

open_three: (a: utf8, b: utf8, c: utf8)
            -> (first: u32, second: u32, third: u32) ! not_found | no_access =
    first = try open_file(a)
    undo close_file(first)
    second = try open_file(b)
    undo close_file(second)
    third = try open_file(c)
end open_three
```

The same shape holds for memory. This version is generic over the
allocator, which [1290] and [1360] explain:

```landin
new_buffers: (provider: type is mem.allocator,
              memory: provider, count: usize)
             -> (first: mem.byte_buffer, second: mem.byte_buffer,
                 third: mem.byte_buffer) ! mem.out_of_memory =
    first = try mem.new_bytes(memory: memory, count: count)
    undo mem.delete_bytes(memory, first)

    second = try mem.new_bytes(memory: memory, count: count)
    undo mem.delete_bytes(memory, second)

    third = try mem.new_bytes(memory: memory, count: count)
    -- All three owners are published by the successful return.
end new_buffers
```

`undo` cleans up what is still yours. Once you hand a resource on, its
cleanup is somebody else's, but your entry is still registered, and there
is deliberately no way to call one off. So acquire everything fallible
first, commit afterwards, and let nothing fallible stand between the commit
and the end of the block.

The usual alternative is a flag and a conditional `defer`. Forget to set
the flag and you free storage that is still in use, and under an arena,
where freeing does nothing, the mistake stays silent until the same code
runs on a real allocator.

### [1130] Repeating: `loop`

`loop do ... end loop` repeats until something leaves it: `break`,
`return` or `fail`. A labelled loop closes with its label.

```landin
    counter: loop do
        break when x == 0
    end counter
```

### [1140] Repeating while a condition holds: `while`

`while` tests its condition before every iteration. `continue` goes
straight to the next test.

```landin
    mut i: u32 = 0
    while i < 10 do
        inc i
        continue when i == 3
    end while
```

### [1150] Walking a range or a collection: `for`

`for` binds each item of its source in turn. An optional second name is a
`usize` index counting from zero.

```landin
    for item in items do
        out += item
    end for

    for item, idx in items do
        item = item + i32(idx) -- items is writable, so this writes
    end for

    for k in 0..<10 do
        out += k
    end for
```

| source | each item is |
|---|---|
| `a..<b`, `a..b` | an integer, ascending; `..<` leaves out `b`, `..` includes it |
| a slice or fixed array | the element, in place ([1160]) |
| `utf8`, `utf16`, `cstring` | a Unicode scalar, as a `u32` |
| a struct or `any C` | what its conformance to `iterable` hands out ([1320]) |

- A range's bounds are evaluated once, left to right. A typed bound gives
  its type to an untyped one, and two untyped bounds are `i32`, so
  `0..<lenof items` counts in `usize` with no conversion. A lower bound
  above the upper one runs no iteration.
- An element may itself be a fixed array, a slice or an `any C`; the
  binding keeps its complete type.
- A struct or `any C` source is evaluated once, and walked through its
  `first`, `at_end`, `item` and `next` ([1320]). The index advances with
  `next`.
- Text yields decoded scalars, not encoded slices. A `cstring` ends at its
  first NUL, which is not an item. Text from C is validated as [0600]
  says.

`try for` walks a source whose steps can fail ([1320]'s
`fallible_iterable`, or a plain `iterable`). A failure leaves the loop
through the routine's error set ([0960]), running `defer` and `undo` on the
way and skipping `complete`. `break` and `continue` work as usual.

### [1160] Writing through a loop binding

A loop binding carries no marker, because the source's type already
decides. Over a `[]mut t` the element is a writable place, and over a `[]t`
it is not.

```landin
double_all: (xs: []mut i32) -> none =
    for x in xs do
        x = x * 2
    end for
end double_all
```

Over anything else that satisfies `iterable`, the binding is a copy, since
`item` ([1320]) hands out a value. Assigning to it is an error rather than
a silent write to nothing. Text likewise yields a copied `u32` that cannot
be written.

- The cursor and item keep their exact declared types. An `any C` item
  keeps C and its evidence, and an `any C` source stays an erased value
  passed to the providers; neither is treated as a slice.
- When the element is a fixed array, slice or `any C`, replacing the whole
  element follows the same rule. Writing through an inner slice follows
  that slice's own `mut`.

### [1170] When a loop runs out: `complete`

A `complete` block runs when the loop ends because its source or condition
ran out, and not when a `break` left it.

```landin
    for item in items do
        break when item == 42
    complete
        out = -1
    end for
```

`loop do` has no natural end, so it takes no `complete`.

### [1180] Labels

A loop or a bare block may carry a label, written like any other name.
`break` and `continue` may name one.

```landin
    outer: for a in items do
        for b in items do
            break outer when a == b
        end for
    end outer
```

A `break` naming a bare block leaves it, and whatever loops it crosses,
running their cleanups on the way out. A bare block has no next iteration
and yields no value: `continue` can target only a loop, and only a loop can
produce a value through `break with`. An unlabelled `break` or `continue`
means the innermost loop.

```landin
    search: begin
        for item in items do
            break search when item == 0
        end for
        out = 1 -- no item was zero
    end search
```

### [1190] A loop with a value: `break with`

`break with value` leaves the loop and makes the value the loop's result.
A search becomes an expression instead of a mutable variable and a flag.

```landin
    found := for item in items do
        break with item when item > 40
    complete
        break with 0
    end for
    out += found
```

- Every `break` of a loop used as a value carries `with`, and all of them
  yield the same type.
- A loop that can run out needs a `complete` that supplies the value.
  `loop do` needs none, having no other way out.
- A loop whose value is unwanted is discarded explicitly ([1020]):
  `_ = loop do break with 1 end loop`. A statement loop uses plain `break`
  and cannot silently drop a `with` value.

`with` is required because a bare name after `break` could be either a
label or a value.

### [1210] Pattern matching: `match`

`match` picks the arm whose case or atom the subject holds. There is no
fallthrough, and a missing case is a compile error. This uses `figure`
from [0680]:

```landin
area: (f: figure) -> (a: f32) =
    a = 0.0
    match f.kind
        circle(radius):
            a = 3.14159 * radius * radius
        rectangle(width, height):
            a = width * height
    end match
end area
```

An arm runs one statement or one expression. For several, make the arm a
bare block:

```landin
area_and_corners: (f: figure) -> (a: f32, corners: u32) =
    corners = 0
    match f.kind
        circle(radius): a = 3.14159 * radius * radius
        rectangle(width, height): begin
            a = width * height
            corners = 4
        end
    end match
end area_and_corners
```

- The subject is an atom set ([0640]), a variant part ([0680]) or a
  pointer union ([0480]). An arm names an identity, and a case arm may
  bind the payload, as `circle(radius)` does.
- Several labels share one arm, `north, south:`, and each counts toward
  covering every case. An arm that binds a payload names one case.
- `_` is an arm of its own and covers whatever is left. On an atom set,
  `_ (rest):` binds the remaining atoms as a set of their own, so they can
  be passed on where only those are wanted.
- A number has no identity to name, so it is compared with `if` and
  `elsif`, not matched.

### [1220] Writing into a matched payload

A pattern binding takes a parameter convention ([0900]). It is `in` by
default; `inout` writes into the payload that was matched. On a pointer
union's `ptr` arm, `ptr (sink p):` passes the pointer on to a `sink`
parameter ([0910]), which consumes the matched place.

```landin
store: type = struct
    kind: variant
        inline: (buf: [4]i32) |
        spilled: (heap: []mut i32)
    end kind
end store

spill: (inout s: store, v: i32) -> none =
    match s.kind
        inline(inout buf): buf[0] = v
        spilled(heap): heap[0] = v
    end match
end spill
```

`spilled(heap)` needs no `inout`: it writes through the slice, whose own
`mut` allows it, and never replaces the slice. `describe` matches the
`compass` of [0640], two directions in one arm:

```landin
describe: (c: compass) -> (name: utf8) =
    match c
        north, south: name = "along"
        _: name = "across"
    end match
end describe
```

A plain binding reads the payload in place, without copying it; `inout`
adds permission to write it.

- Both plain and `inout` bindings alias the matched storage, scalars
  included. So an arm may replace the variant, or an object containing it,
  only after the aliases' last use ([0830]). Writing through an `inout`
  alias is a use, as is reading an address derived from it or evaluating a
  pending cleanup argument.
- A scalar copied out of a binding keeps no borrow of the payload.
- Matching a computed value matches a temporary copy, so replacing the
  original does not change what the arm sees.
- Assigning a new case selects its tag before evaluating the new payload,
  so the payload's initializer cannot use an alias of the old one. When
  constructing a whole containing value, save the scalars you need first.

Exact rules: spec [1910].

### [1120] Switching checks off for a region: `unchecked`

An `unchecked` region drops the run-time checks the compiler would emit
inside it, and says so where you read it.

```landin
    unchecked begin
        out = out + items[0]
    end unchecked
```

The region is an ordinary block: it has its own scope, `defer` still runs
on the way out, and nesting one inside another changes nothing.

These checks go:

- integer overflow;
- an element index or a slice range;
- the destination range of an integer conversion.

What stays is everything the compiler decides at compile time (types,
definite assignment, permissions, origins), and the checks whose absence
would not mean the same thing on every machine: a zero divisor, a negative
shift count, a conversion to `bool` or from a float, a text boundary, and
converting an integer that is zero at the target's width into a pointer.

A region reaches only the code written inside it: a routine called from it
is checked as that routine is written, and a deferred call is checked where
you wrote it, not where the exit that runs it stands.

## ARRAYS, SLICES AND TEXT

An array holds its elements inline and is copied like any other value. A
slice is a view of someone else's elements: a pointer and a length. Text is
a view with a promise about its encoding. Between them they do most of
what other languages use pointers for. Storage that has to outlive a
function comes from an allocator you pass in; [1360] shows how.

### [0520] Arrays are values

`[n]t` is `n` elements of type `t`, stored inline. Assignment copies the
whole array, and the length is part of the type, so `[4]f32` and `[8]f32`
are different types.

```landin
grid: [4]f32 = [1.0, 2.0, 3.0, 4.0]
mut next: [4]f32
next = [grid[0], grid[1], grid[2], grid[3]]
```

Assigning a literal to an existing array, as `next = [...]` does, fills it
in place, in written order: each element is evaluated and stored before the
next one starts, and no hidden temporary copy is made. So a later element
sees an earlier write, and a failure part-way leaves the written prefix
changed. The repeated forms of [0560] fill in the same order.

The length must be a constant the compiler works out without running
anything. You may write integer literals, fixed parameters ([1520]) and
immutable module integers, combined with parentheses, unary `-` and plain
`+`, `-`, `*`, `/` and `%`. Calls, wrapping operators, bitwise operators
and shifts are not allowed. With `path_max: usize = 4096`, `[path_max]u8`
is the same type as `[4096]u8`. A module integer counts only when its own
value is such a constant, which may read a compiler fact [1500]; a `mut`
one never counts, because the program may write it.

Fine print:

- A negative length is refused. A length of zero is fine and gives a
  zero-length array, but there is no empty array literal, and the repeated
  forms of [0560] cannot fill one.
- An index is a `usize`, and the array's size in bytes must fit the
  target's `usize`.
- A computed index is evaluated and bounds-checked once, before the element
  is used. Indexing exposes no pointer and does not change how arrays are
  copied.
- An array keeps its complete element type, permissions included, through
  a pointer, a slice, a generic call or a stored field. An `any C` element
  keeps its own data and its evidence for `C`.

### [0530] Letting the literal set the length

With `:=`, the literal supplies both the length and the element type.

```landin
triple := [1.0, 2.0, 3.0] -- [3]f32
```

The first element decides the element type, whether it is a number, a
slice, a pointer or a struct, and every later element must have that type.

### [0560] Filling an array with one value

`[n of v]` is an array of `n` copies of `v`. It suits fixed patterns, which
an immutable module binding can keep in flash.

```landin
pattern: [256]u8 = [256 of 0xFF]
filled: [256]u8 = [of 0xFF] -- length from the type

read_header: () -> none =
    header: [8]u8 = [0x7F, 0x45, of 0]
end read_header
```

| form | where the length comes from |
|---|---|
| `[n of v]` | the count `n`; it can also infer a local or module binding's type |
| `[of v]` | the destination's written type |
| `[e1, ..., ek, of v]` | the destination's written type, with `1 <= k < N` |

`v` is evaluated once, not once per element. The mixed form writes the
prefix left to right, then evaluates `v` once and fills the rest. An
assignment to an existing array may use any of the three forms:

```landin
header_image: [8]u8 = [0x7F, 0x45, of 0]

refill: (seed: u32) -> (row: [4]u32) =
    row = [of seed] -- the length comes from row
    row = [seed, seed + 1, of 0] -- the prefix first, then the fill
    copies := [4 of seed] -- [4]u32
    row = copies
end refill
```

Fine print:

- The mixed form needs an explicitly typed local or module binding, or an
  assignment to a mutable fixed array. It cannot be inferred, nested, or
  passed or returned as a value. At module level every element must be a
  compile-time known scalar [1460].
- An inferred `[n of v]` takes `v`'s scalar type, and an untyped integer
  becomes `i32`. Its size must fit the target's `usize`.
- Refused: `row := [of 0]`, which has no length to give, and a zero count
  or a zero-length destination.
- `of` is a contextual word: if `of` names a binding, `[of, other, of]` and
  `[of + 1]` are ordinary literals.

### [0540] `zeroed`: the all-zero value

`zeroed` is the value of a type whose bits are all zero. Two separate
questions decide where you may write it.

`point` is [0120]'s struct and `compass` [0640]'s enumeration:

```landin
mut buffer: [256]u8 = zeroed
buffer = zeroed -- clear the existing array as a whole
corner: point = zeroed -- fine: both fields are floats
-- facing_now: compass = zeroed -- error, write 'north'
-- p: ptr u32 = zeroed -- error, no zero image
```

- **Does the type have a zero image?** It does when all-zero bits are a
  valid value of it, which is what lets a surrounding struct or array be
  zeroed. Pointers and `any` have none, because there is no null, and
  neither does a function address. A struct or an active variant payload
  that contains a function address must spell that field out instead of
  using whole or trailing `zeroed`.
- **Does the type accept the word?** Only when its zero has one obvious
  reading. Numbers, `bool`, ranges that contain zero, and aggregates of
  those accept it. Named value sets do not: write the name. A distinct type
  [0650] has its base's zero image, so a record holding one zeroes fine,
  but an identity such as a user id has no obvious zero, so write
  `user_id(0)` rather than `zeroed` for it.

Where the destination gives the context, `zeroed` writes the complete zero
image as one value, as the assignment to `buffer` does.

A packed struct ([0730]) is a raw image: `zeroed` is allowed even when an
encoded field's zero pattern has no name. Reading that field then traps;
copying the image keeps its bits.

Library code has a narrow cousin, `uninit`, which leaves a private array
field unwritten. It is not another spelling of `zeroed` and cannot
initialize a stand-alone array.

### [0550] Asking for a zero image: `zeroable`

`zeroable` is the first of those two properties as a concept, so generic
code can require it. Concepts come in [1240]; for now read one as a named
property a type can have.

```landin
-- compiler-owned; a program does not repeat this declaration
zeroable: type = concept (t: type)
end zeroable
```

Only the compiler knows a type's bit patterns, so only the compiler
supplies its conformances; it is the one concept like that, and a program
cannot declare a conformance to it. The family holds:

- the enabled scalars;
- a fixed array exactly when its element is zeroable, even at length zero;
- a struct exactly when its all-zero shape, recursively, has a zero image;
- a distinct type exactly when its base is zeroable.

Atoms, functions, pointers and slices are not in it. It is a closed list,
not reflection over arbitrary types.

This is how a container that needs a filler value for storage it has not
used yet says so, instead of pretending: see `cleared` at [1350] and the
reason at [0510].

### [0570] Slices are views

A slice `[]t` is a pointer and a length. It copies nothing. `mut` inside
the type says its elements may be written.

```landin
mut cells: [4]f32 = [1.0, 2.0, 3.0, 4.0]
view: []f32 = cells[0..<2] -- read-only elements
edit: []mut f32 = cells[0..<2] -- writable, since cells is mut
```

You can pass an array straight to a slice parameter; it lends a slice of
the whole array. A named array lends its own storage. An array literal is
built in the caller's frame for the duration of the call, so a list of
values needs no binding of its own.

```landin
added: (values: []f32) -> (sum: f32) =
    sum = 0.0
    for value in values do
        sum += value
    end for
end added

both_sums: () -> (both: f32) =
    both = added(grid) + added([1.0, 2.0])
end both_sums
```

A literal lends read-only elements only, so it cannot go to a `[]mut t`
parameter.

### [0580] The empty slice

`[]` is the empty slice: length zero, and a `for` over it runs no
iteration. It is never null. Its base is the lowest positive address
aligned for the element type, 1 for bytes and 4 for a `u32`, and since
indexing checks the length first, that base is never dereferenced.

### [0590] Arithmetic on whole arrays

Fixed arrays are also Landin's vector type: arithmetic on numeric arrays
works element by element. There is no second type with the same shape and
different rules.

```landin
sum_four: (values: [4]f32) -> (sum: f32) =
    sum = 0.0
    for value in values do
        sum += value
    end for
end sum_four

array_example: () -> (sc: [4]f32, s: f32) =
    va: [4]f32 = [1.0, 1.0, 1.0, 1.0]
    vb := va * va
    sc = va * 2.0 -- a scalar on either side is fine
    s = sum_four(vb) -- ordinary function, not a reduction builtin
end array_example
```

- `+`, `-`, `*`, `/` and unary `-` work on numeric arrays; `%`, `+%`, `-%`
  and `*%` on integer arrays.
- Two arrays must have the same element type and length. A scalar of the
  element type is applied to every element; an array of another length is
  not.
- Each operand is evaluated once, left to right, as a complete value
  before any element is computed. So `a += a` and other overlapping
  assignments see the old values, not their own earlier writes.
- Elements go in ascending index order under the ordinary scalar rules for
  traps, wrapping and floating point. Nothing is reassociated, so
  `sum_four` adds in order starting from positive zero.

Arrays do not compare, not even with `==` or `<>`: whole-array equality
and per-element masks are both plausible, so write the function you mean.

The cost is visible in the type: `[4096]f32 + [4096]f32` needs a 16 KB
result and may keep copies of its operands as well. Vector instructions
are an optimisation, never needed for a correct result.

### [0600] Text: `utf8`, `utf16` and `cstring`

Landin has no single string type. It has three distinct views over plain
storage:

| type | view over | holds |
|---|---|---|
| `utf8` | `[]u8` | validated shortest-form UTF-8 |
| `utf16` | `[]u16` | UTF-16 code units |
| `cstring` | `ptr u8` | bytes up to a NUL; no length |

A quoted or raw literal can be any of the three, and is `utf8` when nothing
says otherwise. `lenof` on `utf8` and `utf16` counts code units, not
characters. The three types stay distinct from each other and from their
backing types through calls, structs and generics.

Every literal has one trailing zero code unit, which slice lengths leave
out, and equal literals of the same width may share one read-only copy. A
`cstring` literal is valid UTF-8; a `cstring` that comes from C promises
only readable bytes up to its first NUL, with its encoding unchecked.

**Converting.** Conversion between text and bytes is the ordinary explicit
conversion, and these are all there are:

| from | to | what it does |
|---|---|---|
| `[]u8` (read-only) | `utf8` | validates, and traps on invalid UTF-8 |
| `utf8` | `[]u8` (read-only) | nothing: same base, same length |
| `cstring` | `[]u8` (read-only) | scans to the first NUL |
| `cstring` | `utf8` | scans to the first NUL and validates |

There is no conversion from a pointer to `cstring`, none with a writable
result, and none for `utf16`. An empty result keeps its source's base and
origin.

**Slicing.** `utf8` and `utf16` slice by range, as `word[3..3]` in [0610]
does. The result is the same text type, read-only, over the same storage.

- The `usize` bounds count bytes or UTF-16 code units, not characters.
- Both bounds must fall where a Unicode scalar starts; a bound out of
  range or inside an encoding traps.
- A half-open range may end at the length; an inclusive range takes the
  whole scalar that starts at its upper bound.
- A `cstring` has no length and cannot be sliced.

**Traversal.** `for c in text` yields each Unicode scalar as a `u32`
[1320]; on a `cstring` it stops before the first NUL. Traversal declares no
error, so text from C is validated as it is decoded and malformed encoding
traps, even inside `unchecked`.

**`core/text`.** When invalid text is input to handle rather than a bug,
`text.from_bytes` and `text.from_c` validate the same way but fail with
`invalid_text` instead of trapping; call them before traversing. The module
also has exact byte equality, substring search, decimal parsing and bounded
writing into a buffer you supply. It never normalizes, allocates or
silently truncates.

On plain `[]u8`, `core/text` counts positions as byte offsets of the
opaque type `text.position`, with `first`, `at_end`, `next`, `advance`,
`offset`, `byte` and `slice`. Reading a byte at the end fails with
`past_end`, and a slice keeps its source's origin.

### [0610] Indexing text by codepoint or by position

Indexing a `utf8` gives the codepoint there as a `u32`, the type a
character literal [0250] and a traversal [1320] already give it. The index
type picks the operation:

- a `usize` counts codepoints from the start, so `word[2]` is the third
  one; the compiler finds it by scanning;
- a `core/text.position` is a byte offset, decoded directly in O(1).

```landin
word: utf8 = "\u{e9}t\u{e9}"
last := word[2] -- 233, the u32 of é, found by scanning
same := last == '\u{e9}' -- true
bytes: utf8 = word[3..3] -- é again, at byte 3: two bytes, no copy
```

A count past the end traps, and so does a position at the end or on a
continuation byte. Neither index type converts implicitly to the other.

The codepoint is decoded, so it is a value, not a place: `addr word[2]` and
`word[2] = 'e'` are errors. To get its bytes, take a one-codepoint range
as [0600] describes: its bounds count bytes, and the result is still
`utf8`. A `utf8` converted to `[]u8` loses codepoint indexing and has the
ordinary slice operations instead.

## MODULES

### [1410] A module is a directory

Every `.ldn` file directly inside one directory belongs to one module, and
those files see each other's declarations without importing anything.
Everything is private to its module unless it is marked `public`. There is
no separate interface file.

```text
geometry/area.ldn
geometry/shapes.ldn
geometry/solid/volume.ldn
```

Here `geometry` is one module of two files, and `geometry/solid` is a
second module.

Fine print:

- The compiler reads a module's files in bytewise filename order. Other
  files are ignored, and an empty directory is a legal empty module.
- Declaration order never affects what is visible. File order does fix
  identities, the order of diagnostics and the order of active
  `linker.library` directives [1590].
- An importer can name public functions, bindings, atoms, types and
  concepts. A variant case is public when its type is.
- A public declaration may mention a private one. The private identity
  flows through the public surface, but an importer cannot name it.

### [1420] Importing a module by its path

`import net/http` finds a directory `net` holding a directory `http`, under
the import roots the compiler was given, and binds the last segment, `http`,
as a namespace in this file.

```landin
import net/http
```

The roots are searched in order, and the first that has the directory wins;
a later root is not merged in. From that directory the compiler takes every
source file, not recursively, and follows their imports. A subdirectory is
a module of its own, reached by its own path. Each module is loaded once, so
import cycles are legal.

After the import, `http.get`, `http.response` and `http.drawable` name that
module's public declarations. Qualification works wherever a value, type,
type application, concept, conformance, error atom or match case is named.
The first dot after the namespace selects a public declaration; later dots
are ordinary value selections. The namespace itself is not a value, type or
place.

A path segment is a plain identifier: lowercase letters, digits and
underscore, not starting with a digit. Lowercase, because a case-sensitive
and a case-insensitive filesystem must agree on what a name is, and the
directory entry must have exactly that spelling even on a case-insensitive
host. An identifier, because the last segment becomes a name in your file,
so a hyphen would need an alias every time. The separator is always `/` in
source, on every host.

### [1430] Renaming an import

`as` gives the namespace another name, for when two imports collide.

```landin
import net/http as h
```

This binds `h` only, not `http`. `as` is a contextual word, so outside an
import it is an ordinary identifier.

### [1440] Importing selected names

A parenthesized list brings named declarations into scope directly. There
is no wildcard.

```landin
import net/http (get, post)
```

This binds `get` and `post` and not the `http` namespace. Every selected
name must exist and be public, even if the file never uses it. Each keeps
its original declaration's identity, type and mutability. The list is not
empty and has no trailing comma or renaming, and a selection cannot be
combined with an alias.

### [1450] Imports belong to one file

Each file has its own imports, so every file reads on its own.

Imports come first, before every declaration. One file's imports are not
visible in its siblings and are never re-exported. Binding one name twice
in a file's imports is an error, whether it is the same import twice or a
selection colliding with an alias.

Shadowing goes like this:

- A parameter or local may shadow an import.
- A namespace import shadows a same-named module declaration only for
  qualified lookup; the module's unqualified value stays visible.
- A selected name shadows the module declaration in both.

Selecting a private member is reported differently from selecting one that
does not exist, and the report points at the private declaration.

### [1460] Module-level values are known at compile time

A value at module level must be known when the compiler reads it, because
nothing runs before the entry point. So it cannot call a function.
Immutable values can stay in flash; mutable ones cost RAM, and the `mut`
makes them conspicuous.

```landin
table: [4]u32 = [1, 2, 4, 8]
mut call_count: u32 = 0
```

Integer arithmetic here is worked out in a wide range first, and only the
final value is checked against its type. So a module `value: u8 = 200 +
100 - 100` holds 200, while the same `u8` addition inside a function
overflows and traps before the subtraction.

A value another module exports is known in the same way, named through that
module: `limit: u32 = sizes.page * 4`, `ready: flags.state = flags.idle`.
Qualifying a name changes where it is found, not whether it is known.

A module struct may hold a function. The field names a declared function,
or an anonymous one that captures nothing, and what is stored is the
routine's address; nothing is called. There is no all-zero function
address [0540], so such a struct must be written out in full.

Exact rules: spec [1940].

### [1470] Packages and versions

A package is a named collection of modules with a version and an origin.
Its name has two levels, owner and package, and a directory under a search
root is the package it names.

A program holds one version of each package name. Two copies of a package
would cost space a 32 KB part does not have, and they would be different
types, since types are nominal. The whole program also keeps a single list
of which types conform to which concepts ([1240]), and two copies would
put conflicting entries in it. The companion tool, once it exists, will
solve versions and report a conflict as a hard error that asks for an
upgrade.

The current compiler reads no versions or origins. It takes the first
matching module directory from the ordered roots [1420], even when a later
root holds another version.

### [1480] Where modules come from: the roots

You tell the compiler where modules are. `refine` takes repeated
`--root=DIR` options and then the entry module's directory, or its source
files, which then form one module. With no `--root`, the named files form
one synthetic module. The roots are searched in the order you give
([1420]), and that order alone decides: the compiler consults no home
directory and adds no system root of its own choosing.

It does add one root: the library it ships with, found beside its
executable. `core`, `hosted` and `platform` always come from there, after
every root you name. Because the search is otherwise project-first, a
project can override an ordinary module by putting its own copy in its
first root, and vendoring a package is just that.

Fetching packages, solving versions, lock files and naming authority
belong to a companion tool that will ship alongside the compiler but stay
separate from it: a compiler you can read is worth more than one that can
download things. Arranging the roots so that only one version of each
package is reachable is that tool's job, so until it exists the compiler
does not enforce [1470]'s one-version rule. The intended root order is the
project, then the user's Landin home, then a system-wide one; whether a
path's leading segments name an owner and a package is a convention for
people and that tool, while the compiler only sees directories.

Four source namespaces belong to the repository:

| namespace | holds | available |
|---|---|---|
| `core` | the shared freestanding library: `core/mem`, `core/text`, `core/vec` | every module and interface on every target |
| `hosted` | hosted providers such as `hosted/heap` and `hosted/system` | on hosted systems |
| `platform` | scoped freestanding interfaces | `platform/c` with an enabled LP64 C ABI; `platform/cortex_m` on M-profile targets, higher feature levels included |
| `landin` | the toolchain modules of [1560]: `landin/compiler`, `landin/assembler`, `landin/linker` | everywhere, without an import |

Fine print:

- An import outside its target's scope is refused by name when the target
  is checked, for example `hosted/heap` in firmware.
- The toolchain modules are always there, so the bare names `compiler`,
  `assembler` and `linker` cannot be declared or bound by an import, and
  an explicit `import landin/compiler` (or `assembler`, or `linker`) is
  refused by name before any root is searched.
- Otherwise the namespace names are ordinary identifiers.

## What you can write now

That is the path. You can now write ordinary programs: routines with
failures, your own types, loops and matches, arrays and text, modules, and
the host's files and streams through `hosted/system` and `core/io`.
[`examples.md`](examples.md) has complete programs to read and copy.

The sections after this one are reference, to read when you need them:
POINTERS; LIFETIME AND ESCAPE; CONCEPTS AND GENERIC CODE; RUNTIME
DISPATCH; COMPILE TIME; THE TOOLCHAIN, C, AND THE MACHINE; and the
principles, the omissions and the open questions at the end.

## POINTERS

Most code never needs a pointer: slices, handles and indices do the
everyday work ([0490]). Pointers are for hardware, the C boundary and the
inside of libraries. When you do need one, it is spelled in words.

### [0430] `ptr`, `addr` and `.val`

`ptr u32` is a pointer to a `u32`. `addr` takes an address, and `.val` is
the thing pointed at, on either side of an assignment.

```landin
mut value: u32 = 42
p: ptr mut u32 = addr value
v := p.val -- read through p
p.val = 43 -- write through p
ro: ptr u32 = addr value -- same address, read-only
-- ro.val = 1 -- error: ro cannot write
```

`mut` inside the type is what lets you write through the pointer. `addr` of
a mutable variable gives a `ptr mut`, and `addr` of an immutable one a plain
`ptr`.

`addr p.val` is the address of the thing `p` points at, and `addr items[i]`
the address of a slice's element. `addr p` is something else: the address
of the variable `p` itself, which may live on the stack.

### [0440] A writable pointer passes where a read-only one is expected

```landin
add_up: (xs: []i32) -> (total: i32) =
    total = 0
    for x in xs do
        total += x
    end for
end add_up

add_written: (writable_slice: []mut i32) -> (total: i32) =
    total = add_up(writable_slice) -- fine: []mut i32 relaxes to []i32
end add_written
```

No bit changes; the callee simply forgets that it could write. This is the
only implicit relaxation in the language, and it only goes this way: a
read-only reference never becomes a writable one.

### [0450] Permission is shallow

Read-only applies to one level only. An immutable binding, or an `in`
parameter, protects the value it holds, not what that value points at. A
list handed over as `in` still has writable elements if its storage is
writable.

Protecting deeper would mean knowing which references a value owns and
which it borrows, and Landin does not track ownership ([0910]). When you
want to hand out a read-only view, hand out a read-only reference; an
accessor is how.

### [0460] A pointer to a fixed address

`ptr(...)` turns an address into a pointer. The pointer type comes from the
declaration.

```landin
gpio: ptr mut u32 = ptr(0x4001_0000)
```

This binding is immutable, but the register behind it is written: the two
questions of [0070] really are separate. Nothing in the pointer's type
makes access to it a device transaction. The operation that reads or writes
does that ([0850]).

### [0470] Converting between pointers and integers

A pointer and an integer convert both ways like any other conversion
([0700]): apply the type. Here `gpio` is the pointer from [0460].

```landin
gpio_round_trip: () -> (back: ptr mut u32) =
    address := usize(gpio) -- pointer to integer
    back = ptr(address) -- integer to pointer: no origin
end gpio_round_trip
```

The cost is on the way back. An integer has no origin, so a pointer made
from one borrows nothing as far as the compiler knows, and it will say
nothing more about that pointer's lifetime. This is the one place inside the
language where lifetime checking is left behind, much as at the C boundary.

### [0480] There is no null

"Maybe a pointer" is a union of an atom and a pointer type. With a single
atom, the compiler stores it as a plain pointer, with 0 meaning the atom.

```landin
none_found: atom
maybe_ptr: type = none_found | ptr mut u32

lookup: (key: u32, cell: ptr mut u32) -> (found: maybe_ptr from cell) =
    if key == 0 then
        found = none_found
    else
        found = cell
    end if
end lookup

read: (m: maybe_ptr, fallback: u32) -> (value: u32) =
    match m
        none_found: value = fallback
        ptr (p): value = p.val
    end match
end read
```

A pointer goes into the union with no ceremony. Getting it out takes a
`match`, and the `match` has to name both cases: `ptr (p)` is the present
case, with the pointer bound to `p`.

To ask only which case it holds, compare with the atom: `m == none_found`
or `m <> none_found`. That reads no address, so it needs no `match`. Two
such unions do not compare with each other.

A union may also hold several atoms beside the pointer; it then takes two
cells instead of one.

Exact rules: spec [1870].

### [0490] What to use instead of a pointer

Before you reach for a pointer, see whether one of these does the job:

| you want | use |
|---|---|
| a run of elements, to read or to write | a slice ([0570]) |
| one element of an array you already have | its index |
| a service such as an allocator | a handle: a small value that refers to state kept elsewhere ([1360]) |

Each says more than a pointer would: a slice carries its length, an index
is checked against that length, and a handle's type says what it is for.

### [0500] No pointer arithmetic outside the library

There is no `p + n` on pointers, and no built-in operation that turns a
pointer into a slice. Code that really needs to compute an address converts
to an integer and back ([0470]), and gives up lifetime checking when it does.
Inside the standard library, `core/mem` does this for you, behind its
private storage operations. If you need an element's address, take it from
a slice that you know is not empty: `addr items[0]`.

### [0510] Storage that is not filled yet: `mem.storage(t)`

A growing array has room for more items than it holds. The empty slots
contain no `t` yet, so no slice may cover them: a `[]mut t` over them would
claim values that do not exist. Neither may they be zero-filled, because many
types, pointers among them, have no zero value ([0540]).

`core/mem`'s `storage(t)` is the answer. It holds a block of storage,
counts how many slots at its start are initialized, and only ever shows you
that initialized prefix. Its representation is the private type `raw(t)`:
you can hold one but not look inside.

| operation | what it does |
|---|---|
| `capacity`, `length` | how many slots there are, and how many are initialized |
| `admit` | initialize the next slot |
| `get`, `replace` | read or overwrite an initialized slot |
| `used` | the initialized prefix as a `[]mut t` |
| `withdraw`, `clear` | drop the last item, or every item |
| `transfer` | copy one item onto the end of another `storage`, for growing |
| `dispose` | hand the block back once it is empty |

The four ways of asking for something impossible are ordinary failures:
`full`, `out_of_bounds`, `empty` and `not_empty`.

To grow, reserve a bigger block and `transfer` every item into it. A
`transfer` copies and leaves its source as it was, so the old block is
unchanged until you are done: if a step fails, release the new block and
carry on with the old one. Only after every item is copied do you empty
and dispose of the old block and publish the new one.

This keeps the empty slots out of reach. It does not make raw storage safe:
the allocation you supply must be live, aligned and as large as you say
([1720]).

## LIFETIME AND ESCAPE

Landin has local borrow and escape checks, without Rust-style ownership or
lifetime parameters. Inside each routine, the compiler knows where every
pointer, slice and `any` points. That is the reference's *origin*, and
there are three:

| origin | what it is | how long it lives |
|---|---|---|
| static | module storage and literals | the whole program |
| allocated | what an allocator handed out | until you give it back |
| frame | a routine's locals | until the routine returns |

Everything in this section follows from a few rules:

- A frame reference never leaves its routine ([0770]).
- A routine does not keep a pointer it was given unless its signature says
  `escaping` ([0780]).
- While a view into a local is in use, the local cannot be grown or moved
  ([0830]).
- A returned reference says what it came from, with `from` ([0790]).

Each rule is checked one routine at a time, against signatures, so a
change in one body never changes what another may do. The price is that
some mistakes go uncaught; [0860] lists them.

### [0770] A frame reference cannot leave its routine

A pointer to a local dies with the routine. Returning one, or storing it
anywhere that outlives the routine, is an error.

```landin
bad: () -> (p: ptr u32) =
    x: u32 = 42
    p = addr x -- error: a frame origin escapes
end bad
```

A pointer to module storage is static, so the same shape is fine:

```landin
mut tally: u32 = 0

tally_cell: () -> (p: ptr mut u32) =
    p = addr tally -- fine: module storage is static
end tally_cell
```

The origin travels with the value: a slice of a local array, or an `any`
built over a local ([1370]), is frame too.

### [0780] Keeping a pointer you were given: `escaping`

A parameter is non-escaping by default. The callee may read and write
through a pointer it was handed, but it may not keep it once it returns.

```landin
increment_cell: (cell: ptr mut u32) -> none =
    cell.val += 1 -- using the pointer is fine; keeping it would not be
end increment_cell

caller_of_increment: () -> (n: u32) =
    mut local: u32 = 1
    increment_cell(addr local) -- fine: the callee does not keep it
    n = local
end caller_of_increment
```

So a pointer to a local can go into any call whose parameter does not say
`escaping`. When a routine does keep a reference, it marks the parameter
`escaping`, and then the caller may only pass something that lives long
enough: allocated or static, never frame.

Assume a struct `node` with a field `next: ptr mut node`. `mem.new`
allocates one value through the allocator it is given and returns a
pointer to it ([1360]; `core/mem` in the [library guide](docs/library.md)).

```landin
push_front: (escaping inout head: ptr mut node, escaping item: ptr mut node)
            -> none =
    item.val.next = head
    head = item
end push_front

build: (provider: type is mem.allocator, memory: provider,
        escaping seed: ptr mut node)
       -> (head: ptr mut node) ! mem.out_of_memory =
    head = seed
    n := try mem.new(memory: memory, value: seed.val)
    push_front(head, n) -- allocated, fine

    mut local: node = seed.val
    push_front(head, addr local) -- error: a frame origin escapes
end build
```

`push_front` stores each argument where the other can reach it, so both are
`escaping`.

"Keeping" means any store that outlives the call: into a module binding,
or through a pointer, slice or `inout` field the caller owns. Storing a
reference back into storage of the same origin is an update, not keeping,
and needs no marker. Storing one parameter's reference into another
parameter's storage needs `escaping`.

Exact rules: spec [1910].

### [0830] A view into a local holds the local still

A view taken from a local borrows it. While the view is still in use, the
local cannot be passed as `inout` or `sink`, because that call could grow,
move or replace the storage under the view.

```landin
reset_cells: (inout buffer: [4]i32) -> none =
    buffer = [9, 9, 9, 9]
end reset_cells

view_then_reset: () -> (n: i32) =
    mut buffer: [4]i32 = [1, 2, 3, 4]
    xs := buffer[0..<2]
    reset_cells(buffer) -- error: buffer is borrowed by xs
    n = xs[0]
end view_then_reset
```

The fix is always nearby: finish with the view before the call, or take
it again after. The check looks at one routine body, so there is nothing
to annotate.

Only `inout` and `sink` trigger it, since they are the two ways a call can
change the storage itself. Reading the local, or passing it `in` or by
pointer, is fine while the view lives. An unchecked region ([1120]) does
not turn the check off: origins and escape are among the checks that stay.

### [0790] A returned reference says where it came from: `from`

When a routine returns a reference derived from a parameter, its signature
says so with `from`. The caller then knows that the thing it passed in has
to hold still while it uses the result.

Here a `batch` holds a writable slice of readings and how many of them
are filled in:

```landin
batch: type = struct
    items: []mut u32
    count: usize
end batch

filled_part: (b: batch) -> (s: []mut u32 from b) = b.items[0..<b.count] end
```

- `from` names where the reference came from; it says nothing about
  writing. Write permission is the return type's business ([0430]).
- `from a, b` borrows from both.
- No `from` at all means the result is independent: it borrows nothing.
  That is what an allocator returns, which is why two live allocations
  from one allocator are unremarkable.

One accessor is enough. `filled_part` hands out the widest permission the
storage has, and a caller who wants less relaxes it ([0440]):
`xs: []u32 = filled_part(b)`. There is no const and non-const pair.

The clause is checked against the body in both directions. Returning
something derived from a parameter without naming it is an error, and so
is naming a parameter the result did not come from.

`from` is the mirror of `escaping`. `escaping` says the callee keeps what
the caller handed in; `from` says the caller keeps something of what the
callee handed back. Both are written, not inferred, so a distant body can
never change a signature, and function pointers, concept entries and the C
boundary need no special rule.

Two refinements: a read-only result that points into static storage may
name a parameter it does not come from, since static storage outlives
every parameter; and a writable result must name every place it could
point to, so a helper that might return module storage takes it as a
parameter and names that too.

Exact rules: spec [1910].

### [0800] A borrow through `from` lasts across the call

A result with `from` borrows its source just as a view does in [0830].
The signature supplies the derivation instead of one expression showing
it, and the fix is the same: take the view again afterwards.

`core/vec`'s `vec.used` is declared with `from`, like [0790]'s
`filled_part`:

```landin
import core/mem
import core/vec
import hosted/heap

grow_under_view: (inout numbers: vec.list(i32)) -> (n: i32) ! mem.out_of_memory =
    memory := heap.new()
    xs := vec.used(numbers)
    try vec.push(numbers, memory, 5) -- error: numbers is borrowed by xs
    n = xs[0]
end grow_under_view
```

Nothing is written at the call. The convention lives in the declaration,
and a caller that misuses the result is told at its next use, just as
with `escaping`.

### [0840] Mixed origins count as the shortest-lived

When a value combines origins, it takes the most restrictive one. A struct
holding one frame pointer is frame as a whole, and a value chosen between
two branches takes the shorter-lived of the two.

A value that holds no references has no origin and goes anywhere, which is
one more reason the idiom is handles and indices. A number computed from a
view keeps no borrow: saving `lenof xs` saves a number, usable after `xs`
or its container changes.

Taking an address or a range is different: that reference keeps the
selected storage's origin ([0430], [0790]). Writing through a known
address of a local updates the local's origins too. Mixing in a pointer
made from an integer ([0810]) does not hide a tracked origin.

Exact rules: spec [1910].

### [0810] A pointer made from an integer is not tracked

Converting an integer to a pointer ([0470]) ends tracking. The integer has
no origin, so the pointer borrows nothing, and the compiler says nothing
more about its lifetime. It also does not check that the storage is live
or large enough: that stays the library's unsafe obligation ([1720]).

```landin
block_at: (base: ptr mut u8, offset: usize) -> (block: ptr mut u8) =
    address: usize = usize(base) + offset
    block = ptr(address) -- no tracked derivation survives
end block_at
```

This is how `core/arena` returns a block without borrowing the arena,
after checking its arithmetic; `core` gets no special privilege for it.
[0500] says why there is no `offset` or `slice_from` to do this for you,
and [0510] keeps uninitialized storage out of reach.

Tracking comes back through a signature. A routine that indexes a table C
gave it writes `from table` on its result, and callers are checked against
that like any other signature. Its own body is not checked, since an
integer-made pointer satisfies any `from`, so the contract is its author's
claim: keep such routines small.

### [0820] Arenas are ordinary allocators you give storage to

An arena is a library value from `core/arena`: you hand it a block of
bytes, it hands out pieces of it, and individual frees do nothing. It is
not a builtin type or block. Code that takes any allocator accepts it as a
`mem.allocator` provider.

```landin
import core/arena
import core/mem

mut backing: [1024]u8 = zeroed
report: () -> (code: i32) =
    mut space: arena.space = zeroed
    scratch := arena.over(space, addr backing[0], 1024)
    code = 1
    first := mem.new(scratch, u8(7)) else (problem)
        _ = problem
        return
    end
    second := mem.new(scratch, u8(9)) else (problem)
        _ = problem
        return
    end
    code = i32(first.val) + i32(second.val)
end report
```

- `arena.over(state, base, size)` takes the backing address, its size in
  bytes, and an `arena.space` you declare `zeroed` beside it. It returns
  the arena's handle `from` the space and the backing; copies of the
  handle share one arena.
- Allocation aligns the address and advances an offset. A request that
  does not fit fails with `mem.out_of_memory` before changing anything.
- `arena.reset` gives everything back at once, and `arena.used` reports
  the bytes consumed.

`over` takes its backing as `escaping base`, so it accepts module storage
or storage from another allocator and refuses a frame array. Allocations
borrow nothing ([0790]), so a helper could store one in module storage,
and an arena over frame storage would let that pointer outlive the frame.
For a local buffer whose every use stays inside the frame,
`arena.over_unchecked` takes frame backing; you must stop using its
results before the buffer ends.

Other providers build on the same idea:

| provider | what it does | what you must do |
|---|---|---|
| `core/region.over(ledger, provider)` | records every extent it takes from `provider` in a `region.space` ledger you declare `zeroed` | release all at once with `defer region.release(ledger, provider)`, and stop using its allocations before then |
| `core/pool.over` | hands out pieces of backing whose origin its handle keeps | keep the backing live until every result is done with |

A region's handle holds a copy of its provider's handle. Its allocations
borrow nothing, its bookkeeping also uses the provider's capacity, and a finite provider stays finite:
there is no hidden heap fallback.

What the compiler does not do for you: arrange the backing's lifetime and
release (`defer`, [1100], runs on every exit), keep overlapping backing
apart, or stop you using a result after its backing ends or is reused.
Results obey the ordinary origin rules and nothing more. `arena` itself
is not a keyword: it is an ordinary name you may declare.

### [0850] Volatile access sits outside the borrow rules

A volatile access is exempt from the borrow rule and from every aliasing
assumption. It is an operation, not a pointer type:

| operation | for |
|---|---|
| `compiler.volatile_load`, `compiler.volatile_store` | one scalar |
| `compiler.register_read`, `compiler.register_write` | a register image ([0740]) |

Each performs exactly one access of its width through an ordinary pointer,
usually one built from an address ([0460]) and so already outside the
lifetime checks ([0470]). Hardware often needs several typed windows on one
address, a byte view and a word view of the same register, and that is
legal on purpose. There is no `volatile ptr`: a second permission on every
reference would buy nothing the operations do not.

DMA uses ordinary slices. Landin makes no lifetime promise about storage a
device is still writing: neither an interrupt nor masking one makes it
reusable, and waiting for the device is the driver's own protocol.

Exact rules: spec [1990].

### [0860] What this does not catch

The checks know which kind of storage a reference points into, not which
allocation or whether it still exists. So these go through:

- Use after free or reset. The compiler does not know which arena or
  allocator a pointer came from, or that it has been given back.
- A pointer that went through longer-lived storage. Inside one routine a
  struct carries its fields' origins ([0840]). Store a pointer into a heap
  node, though, and read it back later through the node: it now has the
  node's origin, and whatever it pointed to may be gone.
- Anything across the C boundary.

Catching these would need regions or generation counters, and Landin
deliberately has neither.

## CONCEPTS AND GENERIC CODE

Generic code has three parts. A concept lists the operations a type must
have. A conformance says which functions supply them for one type. A
generic function takes the type as a parameter and calls the operations
through it. There are no classes, no traits with default bodies and no
structural matching: a type satisfies a concept because somebody said so.

### [1230] Declaring a concept

A concept names a bundle of operations, each a complete function
signature written in terms of the concept's type parameter.

```landin
ordered: type = concept (t: type)
    less: (a: t, b: t) -> (yes: bool)
end ordered
```

A concept is an ordinary type declaration, so it lives in a module like
any other name. It has no default bodies: every entry is supplied by
each conformance.

### [1240] Making a type conform

A conformance registers one type against one concept, naming the
function that supplies each entry.

```landin
less_than_i32: (a: i32, b: i32) -> (yes: bool) = a < b end less_than_i32

i32 is ordered (less: less_than_i32)
```

Each label is an entry of the concept, and each supplying function must
have exactly the entry's signature with `t` replaced by `i32`. It must be
a declared function: [1010]'s `less_i32`, a binding that holds an
anonymous function, cannot supply an entry. There is no implicit
conformance: a type with a matching `less` is still not `ordered` until
a line like this one says so.

### [1290] Writing a generic function

A generic function takes the type as an ordinary parameter, constrained
with `is`, and calls the concept's entries through that parameter.

```landin
sort: (t: type is ordered, data: []mut t) -> none =
    for k in 1..<lenof data do
        mut j := k
        while j > 0 and t.less(data[j], data[j - 1]) do
            tmp := data[j]
            data[j] = data[j - 1]
            data[j - 1] = tmp
            dec j
        end while
    end for
end sort
```

`t.less` is the `less` of whatever type `t` turns out to be. Because
entries are reached through the type parameter, two constrained
parameters never collide: `left_type.less` and `right_type.less` are
different functions.

Type and `fixed` parameters exist only at compile time; they add no
runtime argument. A `fixed` parameter is an integer known at compile
time, and inside the body it may also be used as an ordinary value. The
order of parameters does not matter, so
`fill: (inout data: [capacity]u8, fixed capacity: u32)` is as good as
putting `capacity` first.

A type parameter may also be unconstrained, for code that only moves
values around. Fine print:

- Every type parameter is written in the list. A name that is not in
  scope is a misspelling and an error, never a new type variable, just as
  a misspelt build option is an error ([1530]).
- A generic function is not a function value. Only a call picks a
  concrete instance, so you cannot take `sort` itself and store it.
- A private `! ...` error set is inferred separately for each concrete
  instance.

### [1300] Calling a generic function

The type is normally deduced from the arguments. You may also name it,
in the same named-argument list as the runtime arguments.

```landin
sort_demo: (values: []mut i32) -> none =
    sort(values)
    sort(t: i32, data: values)
end sort_demo
```

It is all or nothing: either every type and `fixed` parameter is
deduced, or the call names every one of them. Runtime arguments keep
[0980]'s rule, positional first and then named.

Deduction matches each written parameter type against the argument's
type, exactly. It never uses the return type, a conversion or a search
of the conformances, and it runs no code. Two consequences:

- A writable `[]mut i32` argument still passes where `[]t` is written
  ([0440]), but deeper inside a type, permission must match exactly.
- A fixed bound written `capacity * 2` is never solved for `capacity`;
  it is only checked once another argument has fixed `capacity`.

Exact rules: spec [1920].

### [1310] How generic code runs: tables, and specialization as an option

A call to a generic function passes, invisibly, a table for each
conformance the body uses: the type's size and alignment, then the
concept's functions in the order the concept declares them. `t.less(...)`
loads `less` from that table and calls it. The same tables carry
`any C` values ([1370]), so static generics and runtime dispatch are one
mechanism ([1690]).

The tables are the meaning of generic code. Specialization, replacing an
indirect call with a direct one where the compiler can prove which table
arrives, is an optimization that never changes what a program does.
Two independent switches control code generation:

| option | values | default |
|---|---|---|
| `--optimize` | `none`, `size`, `speed` | `size` |
| `--specialize` | `off`, `auto`, `all` | `auto` |

Neither depends on `--build-mode`. A call is never specialized merely
because its source type is known: the compiler needs proof of the table
that actually arrives. Calls through `any`, through a table it cannot
trace, or in an instance whose address is taken stay indirect.
`--build-report=PATH` writes a report of what was specialized and what
stayed indirect, and why.

### [1340] Combining concepts

A concept may build on others by naming them after `is`. A type that
satisfies the combined concept still conforms to each part separately.

Assume a struct `button` with a `text` field, a type `canvas`, and
functions `button_draw`, `button_click` and `button_focus` with the
entries' signatures.

```landin
drawable: type = concept (t: type)
    draw: (self: ptr t, target: ptr mut canvas) -> none
end drawable

clickable: type = concept (t: type)
    click: (self: ptr mut t, x: u32, y: u32) -> none
end clickable

widget: type = concept (t: type) is drawable, clickable
    focus: (self: ptr mut t) -> none
end widget

button is drawable (draw: button_draw)
button is clickable (click: button_click)
button is widget (focus: button_focus)
```

All three conformances are needed, because `widget`'s supplies only what
`widget` adds. Having the parts does not make a type a `widget`, and
being a `widget` does not make it `drawable`; conformance is always
declared, even when its list is empty.

The combined concept has a name of its own, so an `any widget` value
still carries one table and stays two words.

In generic code, `t.entry` must name exactly one declaration across the
concept and all its parents. A parent reached twice, through two paths,
is still one concept, but two different concepts that both declare
`entry` make `t.entry` ambiguous. Parent order never decides, and a
child's own entry does not override an inherited one. A clash nobody
uses is not an error.

Exact rules: spec [1920].

### [1350] Generic types

A type takes parameters through its own declaration form. It is not a
function that returns a type: that would be compile-time execution,
which Landin does not have. Substitution, not execution.

```landin
pair: type (t: type) = struct
    first: t
    second: t
end pair
```

`pair(i32)` and `pair(u8)` are different types, and every use of
`pair(i32)` is the same type. A growable container is generic the same
way: `core/vec`'s `list(t)` is one, and [0510] explains how it keeps its
empty slots out of sight. A type parameter may carry one concept
constraint, and a `fixed` parameter is an integer known at compile time.
Here `cmp.hashable` is a concept `core/cmp` provides, and `zeroable` is
[0550]'s:

```landin
import core/cmp

key_value: type (key_type: type is cmp.hashable, value_type: type) = struct
    key: key_type
    value: value_type
end key_value

cleared: type (t: type is zeroable, fixed capacity: u32) = struct
    items: [capacity]t
    len: u32
end cleared
```

Applications are positional and complete: `key_value(u32, utf8)`,
never `key_value(u32)`. A `fixed` argument is an integer literal, or a `fixed`
parameter passed on by another generic declaration, and it must fit its
declared type. Whether an argument type may go where the body puts it,
as a field or an array element, is checked after substitution.

An alias may be generic too, including a union of atom sets, and an
alias never makes a new type: `missing | ptr t` keeps the one-word
optional pointer of [0480]. Fine print:

- The template is checked even if nothing applies it, and an error that
  depends on the argument is reported at each application.
- An unused or phantom parameter still distinguishes instances.
- A struct may not contain itself by value, even through another
  template.

### [1250] A conformance for a generic type

A conformance for a generic type declares its type variables in front,
because it holds for every one of them.

The examples use two concepts met later: `iterable`, which `for` loops
use ([1320]), and `mem.allocator` ([1360]). `counted(provider)` is an
allocator that wraps another, and the `pair_...` and `counted_...` names
are the functions that supply each entry.

```landin
(t: type) pair(t) is iterable (cur: u8, item_type: t,
                               first: pair_first, at_end: pair_at_end,
                               item: pair_item, next: pair_next)

(provider: type is mem.allocator) counted(provider) is mem.allocator
    (alloc: counted_alloc, grow: counted_grow, resize: counted_resize,
     free: counted_free)
```

The binder is an ordinary parameter list, the same form functions and
generic types take, so a variable may carry a constraint and a `fixed`
parameter may appear among them. The supplying functions are generic
themselves; instantiating the conformance gives them their type argument
and leaves functions of exactly the concept's shape.

The target must be the whole generic type applied to the binder in
order, each variable used once: one conformance covers the whole family
`pair(t)`. Another family for the same template and concept, or a
concrete exception such as `pair(u8) is iterable`, is a collision
([1280]). Without this form no generic container could be traversed,
sorted or handed to other generic code.

### [1270] One type, several conformances

A conformance is keyed by the type, the concept and the concept's other
input types, so one type may satisfy the same concept more than once.

Assume `position` is a byte-offset type, and `utf8_nth` and `utf8_at_pos`
look up a character by count and by position.

```landin
indexable: type = concept (t: type, idx: type, item_type: type)
    get: (s: t, i: idx) -> (item: item_type)
end indexable

utf8 is indexable (idx: usize, item_type: u32, get: utf8_nth)
utf8 is indexable (idx: position, item_type: u32, get: utf8_at_pos)
```

The labels for the extra inputs, `idx` and `item_type`, are part of the
key; the function labels are not.

Which concepts exist, and how finely they distinguish what an operation
costs, is the standard library's business. The language checks nothing
about cost: a guarantee should not depend on how clever the compiler
happens to be.

### [1280] Where conformances live, and what collides

A conformance may be declared in any module, and two for the same key
are an error. There is no precedence, no orphan rule and no override:
the compiler reports the collision and somebody sorts it out.

When two libraries collide, you do not have to change either. Wrap the
type in a `distinct` type of your own and conform that, or pass the
functions explicitly instead of through a concept.

Every conformance in every module the program reaches is collected
before any generic call is checked, whether or not anything uses it. A
conformance is a registration, not a name, so it needs no `public` and
refuses one. Modules the program does not reach contribute nothing.

### [1260] A concept fixes its error sets

A concept entry's error set is written out or absent, never inferred
with `! ...`. An entry is reached through a table, [0960] forbids an
inferred set there, and so the concept fixes the error set once for
every type that will ever satisfy it.

That is right for allocation, where out of memory is out of memory, but
it shapes how you design a concept. The same goes for what an
implementation is handed: by convention, a concept with no allocator
among its parameters says its implementations do not allocate. The
compiler does not check that, since any hosted routine can make a heap
of its own ([1680]).

Resist widening a concept until it fits its hungriest implementation;
that hands every implementation the sum of everyone's needs. Either the
hungry one picks a shape that does not need it, or there are two
concepts.

### [1320] Traversal is a concept

`for x in s` over your own type uses the `iterable` concept. Conform to
it and your type works in a `for` loop.

```landin
iterable: type = concept (t: type, cur: type, item_type: type)
    first: (s: ptr t) -> (c: cur)
    at_end: (s: ptr t, c: cur) -> (yes: bool)
    item: (s: ptr t, c: cur) -> (v: item_type)
    next: (s: ptr t, c: cur) -> (c2: cur)
end iterable
```

The conformance supplies the cursor type `cur` and the `item_type`, as
[1250]'s `pair` does. The loop evaluates `s` once and keeps a private
copy; each provider gets a read-only pointer to that copy, so a large
struct is copied once, not on every call. The labels may come in any
order. The four signatures are exact: no permission, error set or `from`
clause is inferred or converted, so a provider whose result is declared
`from s` does not match.

`item` returns a fresh value for the loop binding, never an alias into
the source. A container that wants to hand out references into its
storage returns a slice view instead and uses the built-in slice
traversal, as `for value in vec.used(numbers)` does.

A source that can fail while streaming conforms to `fallible_iterable`,
which adds an error set as a fourth input:

```landin
fallible_iterable: type = concept
    (t: type, cur: type, item_type: type, errors: type)
    first: (s: ptr t) -> (c: cur) ! errors
    at_end: (s: ptr t, c: cur) -> (yes: bool) ! errors
    item: (s: ptr t, c: cur) -> (v: item_type) ! errors
    next: (s: ptr t, c: cur) -> (c2: cur) ! errors
end fallible_iterable
```

`errors` is an atom set, and all four entries declare exactly that set;
a provider may declare an error it never raises. Such a source is walked
with `try for` ([0960]). `try for` needs one unambiguous conformance and
prefers `fallible_iterable` when both exist; plain `for` only ever uses
`iterable`.

### [1330] Integer ranges are not values

In `for i in 0..<10 do`, the loop evaluates the two bounds once and
counts between them directly ([1150]). `0..<10` and `0..9` are loop and
slice syntax ([0360]), not expressions, and the header does not go
through `iterable`.

For other stepping, write a struct with its own `iterable` conformance.
A library could then offer `for i in step(0, 10, 2) do ... end for`;
`core` has no such `step` or `step_range` today.

### [1360] Allocation is a concept

An allocator is anything that conforms to `allocator`. The same
container runs on the heap, in an arena or on a fixed buffer, and a
deliberately failing allocator makes the out-of-memory paths testable,
which almost nobody bothers with in C.

This is `core/mem`'s concept:

```landin
allocator: type = concept (provider: type)
    alloc: (self: provider, size: usize, alignment: usize)
           -> (p: ptr mut u8) ! out_of_memory
    grow: (self: provider, p: ptr mut u8, old_size: usize,
           new_size: usize, alignment: usize) -> (grown: bool)
    resize: (self: provider, p: ptr mut u8, old_size: usize,
             new_size: usize, alignment: usize)
            -> (moved: ptr mut u8) ! out_of_memory
    free: (self: provider, p: ptr mut u8, size: usize) -> none
end allocator
```

A routine that adds to a list takes the list `inout` and the allocator as
an ordinary argument:

```landin
record_reading: (provider: type is mem.allocator, inout readings: vec.list(u32),
                 memory: provider, value: u32) -> none ! mem.out_of_memory =
    try vec.push(readings, memory, value)
end record_reading
```

The same `record_reading` runs with `heap.new()` as `memory`, or with an
arena over a buffer on the stack ([0820]).

The list is changed, so it is passed `inout`. The allocator is a
service, so it is a handle: a small copyable value, passed `in`, that
refers to its provider's state. Its lifetime is checked once, where it
is made from that state, and using it locks nothing, so several
containers can allocate from one handle, and a region from its parent
while both are live.

The allocator is passed to each call, not stored in the container. A
stored allocator would make the type `vec.list(t, provider)`, so a list
in an arena and a list on the heap would be different types and no
function could take both. Passing it keeps the type `vec.list(t)` and
costs one argument at every call that can allocate.

The four entries:

| entry | what it does |
|---|---|
| `alloc` | a new block, or `out_of_memory` |
| `grow` | extend the block where it is; `false`, with nothing changed, if it cannot |
| `resize` | a new extent, larger or smaller, moving the block if it must |
| `free` | give the block back, with the size it was allocated with |

`resize` keeps the bytes the old and new extents share, and a refusal
reports `out_of_memory` with the block as it was. A concept entry has no
default, so a provider that can only move a block calls `mem.relocate`,
which allocates, copies and frees through it.

The standard library's providers and containers:

| module | what it gives |
|---|---|
| `core/arena` | a bump allocator over storage you supply |
| `core/pool` | uniform slots over storage you supply, freed slots reused |
| `core/fault` | wraps any allocator and fails once a budget of attempts is spent |
| `hosted/heap` | the operating system's memory, really freed, on every hosted system |
| `core/vec` | a growable list |
| `core/spill` | a list that keeps its first items inline and spills to an allocator |
| `core/map` | an open-addressed hash map |

None of them has a hidden heap or a fallback. Every failure is
`out_of_memory`, reported before anything changes: a container that
cannot grow keeps its old storage and contents. The
[library guide](docs/library.md) lists each module's calls.

When you use the containers directly:

- A map's key needs both an `equatable` and a `hashable` conformance;
  the combined one does not supply its parent ([1340]). Equality must be
  an equivalence, equal keys must hash alike, and neither may change
  while the key is stored, including through a pointer inside the key.
  The compiler does not check any of this.
- A map's entry cursor is just a position. Start a new walk after any
  change to the map, and never resume one on a different map.
- A map's fields are public. Code that works below its operations must
  keep the map's invariants itself.
- A spill list's `spill.used` lends its items `from` the list, so the
  list cannot spill or be released while that view is still used
  ([0830]). Its first spill doubles the inline capacity, checking that
  the result fits `usize`, or takes eight if the inline capacity is zero.
  If a spill or later growth fails, the list is unchanged.

These are the providers' contracts. They do not make raw storage safe:
storage you hand an arena or a pool must be live, aligned and as large
as you say ([1720]).

## RUNTIME DISPATCH

Generics ([1290]) pick the type at compile time. When the type is only
known at run time, such as a list of widgets of different kinds, use
`any C`.

### [1370] `any C`: a value of some type that satisfies C

`any C` holds a value of some type that satisfies concept C, decided at
run time. It is two words: a pointer to the data and a pointer to C's
table of entries for that type.

The pair is an ordinary copyable value. It can sit in a variable, a field
or a slice. What it points at is never copied, because its size is
unknown, so the pointee must stay alive as long as any copy of the pair
can use it. An arena ([0820]) is the usual place for it.

The pair needs no permission of its own: the concept's entries carry it.
An entry declared with `self: ptr mut t` can only be satisfied by a
pointer that may write, so a stateful implementation behind `any` just
works.

The pair does carry its pointee's origin ([0770]), so an `any` over a
local cannot go into a list that outlives the frame.

### [1380] Building one with `any(...)`

You build an `any` explicitly from a pointer. The concept comes from
context where it can; otherwise name it.

```landin
make_widget: (provider: type is mem.allocator, memory: provider)
             -> (item: any widget) ! mem.out_of_memory =
    initial: button = (text: "OK")
    b := try mem.new(memory: memory, value: initial)
    item = any(b)
end make_widget
```

Here the result type supplies `widget`. Without a context, `any(pointer)`
needs exactly one concept the pointee's type conforms to.

A read-only pointer cannot build an `any` whose concept has an entry
taking `self: ptr mut t`. Once built, binding mutability controls only
replacing the pair, not the write authority its pointer already carries.

### [1390] Calls go through the table

A call on an `any` looks up the entry in the table and passes the data
pointer as the first argument. This is the only place in Landin that reads
like a method call.

```landin
paint: (items: []any widget, target: ptr mut canvas) -> none =
    for w in items do
        w.draw(target)
    end for
end paint
```

For an entry to be callable this way, its first parameter is `self` as
`ptr t` or `ptr mut t`, or `self: t` taken by value when `t` is a record,
and the hidden type `t` appears nowhere else in it. A by-value `self` is
copied out of the data pointer when the call is made. So to put a small
handle, such as an allocator handle `memory`, behind `any`, take the
address of the variable that holds it: `any(addr memory)`.

`any C` is exactly C: a concept's parent gives no conversion, and two
`any` types never convert to each other. The implicit `self` takes part in
the same `from`, `escaping` and origin checks as a written pointer
argument.

A call through `any C` is checked even if the program has no conformance
of C. Then no `any C` can be made and no value reaches the call, so it
compiles to a trap that never runs. A library that takes an erased
capability therefore builds in a program that supplies none.

### [1400] What `any` can do that generics cannot

One slice can hold values of different types. A `[]t` is always one `t`;
a `[]any widget` holds buttons, labels and anything else that is a
widget.

## COMPILE TIME

Landin has a little compile time and keeps it little. You can ask which
target you are building for, choose declarations by the answer, check a
layout, and declare build switches. You cannot run your own code while the
program builds.

### [1490] The word `fixed`

`fixed` marks something the compiler knows before the program runs. You
meet it in three places: `fixed if`, which chooses declarations ([1500]);
fixed parameters, which are compile-time values ([1520]); and the fixed
expressions that conditions, assertions and option defaults are written in.

### [1520] A compile-time value parameter

A `fixed` parameter is a value the caller supplies at compile time, so it
can size an array in the signature.

```landin
make_buffer: (fixed capacity: u32, t: type is zeroable)
             -> (b: [capacity]t) = zeroed end
```

Fixed parameters sit beside type parameters and work the same way: the
call supplies or deduces them, and they have no storage at run time
([1290]).

### [1500] Choosing declarations by target

`fixed if` picks which module-level declarations exist in this build. It
works on declarations only, not on statements.

```landin
fixed if compiler.arch == arm64 then
    word_bits: u32 = 64
elsif compiler.arch == cortex_m0 then
    word_bits: u32 = 32
end if
```

Every arm is parsed, so a syntax error in an arm you are not building is
still an error. Only the selected arm's declarations join the module; the
others have no names, no types and no effect. Arms may nest and may be
empty, and an arm opens no scope.

The compiler supplies these facts:

| fact | what it says |
|---|---|
| `compiler.arch` | `x86_64`, `arm64`, `rv64`, `cortex_m0` or `synthetic_32` |
| `compiler.os` | `linux`, `darwin`, `freebsd` or `freestanding` |
| `compiler.word_size` | the width of `usize`, in bits |
| `compiler.byte_order` | `little` or `big` |
| `compiler.build_mode` | `debug`, the default, or `release` |
| `compiler.c_sysv_lp64`, `compiler.c_darwin_lp64`, `compiler.c_aapcs64_lp64`, `compiler.c_riscv_lp64d` | which C ABI the target uses, each true for its own ABI alone |
| `compiler.c_runtime` | whether C's runtime starts the program and its library is linked |
| `compiler.feature.NAME` | whether the selected CPU level has feature NAME |

Ask the C ABI question directly rather than guessing it from the
architecture: Linux and Apple arm64 share `compiler.arch == arm64` and
answer differently here. `compiler.os` is separate from the C ABI because
Linux and FreeBSD share a calling convention on each architecture but not
every libc record layout.

`compiler.c_runtime` is always true on Darwin and FreeBSD, true on Linux
only when the build asks with `--link=libc`, and never true on firmware. A
library calls the C library only where this says it is there.

A build assumes a CPU feature level, chosen with `--level=` and defaulting
to the oldest processor of the architecture. `compiler.feature.NAME` asks
about one feature, such as `bmi2` on x86-64, `lse` on arm64, `idiv` on the
M profile or `xtheadba` on RV64. A feature of another architecture is
simply false, so you need no `compiler.arch` test first:

```landin
fixed if compiler.feature.idiv then
    divide_cycles: u32 = 12
else
    divide_cycles: u32 = 40
end if
```

A level changes which instructions the build may use, never a layout or a
calling convention, so code built at two levels links together. `spec.md`
lists the levels and their features.

When only a value differs, you need no `fixed if` at all. A module value
may read a fact, and a routine branches on that value with an ordinary
`if`:

```landin
fast_count: bool = compiler.feature.popcnt
on_linux: bool = compiler.os == linux
word_bytes: usize = compiler.word_size / 8
```

An integer fact takes its type from context. The atom facts,
`compiler.arch`, `compiler.os`, `compiler.byte_order` and
`compiler.build_mode`, are read by comparing them with one of their atoms.

A routine body reads no fact directly, and `fixed if` cannot begin a
statement. What differs by value branches on a module value like those
above; what needs a call that one system lacks is a routine declared in
each arm of a module-level `fixed if`.

Fine print:

- Build mode is a value you ask for. It does not change runtime checks or
  optimization.
- Conditions may also read your own options [1530].
- A condition is a closed fold: literals, parentheses, unary `-`, integer
  `+ - * / %` without overflow, integer comparisons, equality, `not`,
  `and`, `or`, and `sizeof` and `alignof` of the built-in scalar types.
  Sizes count target bytes, so `compiler.word_size == 8 * sizeof usize`
  holds on 32-bit and 64-bit targets alike.
- Calls, runtime names, measurements of your own types and aggregate
  operations are refused, even in an operand that short-circuiting would
  skip.
- There is no `public fixed if`, no trailing name after `end if`, and no
  `fixed if` inside a block, struct, signature or template.

Exact rules: spec [1940].

### [1510] Checking a layout at compile time

`compiler.assert` stops the build when a fixed condition is false.

```landin
compiler.assert(sizeof usize == 8)
```

It is a module-level directive, allowed in a selected `fixed if` arm too,
and an assertion in an inactive arm does nothing. The condition is the
same closed fold as [1500] and must be a bool; a false one is reported at
its own source. An assertion may also measure your own types, as in
`compiler.assert(sizeof header == 8)`, and is then checked once the type is
laid out.

It is a builtin call rather than a keyword, like the rest of [1560]. That
leaves the word `assert` free for an ordinary routine of your own, such as
the `assert` of [1040].

### [1530] Your own build switches

An `option` declares a typed build switch with a default, which the build
can override. A misspelt switch is a compile error, never a silent false.

```landin
option log_level: u32 = 0
```

Read it in a fixed condition, and set it on the command line with
`--option=log_level=2`:

```landin
fixed if log_level > 1 then
    trace_enabled: bool = true
else
    trace_enabled: bool = false
end if
```

What to know:

- An option's type is `bool` or a built-in integer type; `usize` and
  `isize` take the selected target's bounds. It has no storage at run
  time, and its name is visible only in fixed conditions, option defaults
  and compiler assertions.
- Option names are global across the whole program, so each is declared
  exactly once, unconditionally at module level and never inside a `fixed
  if` arm: the compiler collects every option before it chooses arms. An
  option may not share a name with an active module declaration, an import
  or a compiler-owned atom such as `arm64` or `release`.
- A default may refer to another option, even one declared later, and sees
  that option's overridden value. Cycles are refused, and every default
  must be valid even when overridden.
- `--option=NAME=VALUE` takes `true` or `false`, or signed decimal integer
  text. Unknown or repeated names, malformed values and values out of range
  are errors.
- `--build-mode=debug` or `--build-mode=release` sets the separate
  built-in build mode.

### [1540] No compile-time execution

There are no compile-time loops and no compile-time function calls.
Nothing of yours runs while the program is being built.

The builtin modules of [1560] look like an exception and are not one: their
members are operations the compiler recognizes, not your functions run
during the build, and nobody can add another. Some of their inputs must be
fixed, such as assertion conditions, library names and assembly text;
others, such as atomic data and assembly input operands, can be runtime
values.

When you need a generated table or a structure-of-arrays layout, write a
program that writes the source, and have the build run it.

## THE TOOLCHAIN, C, AND THE MACHINE

This section is about the edges of a program: what the compiler produces,
how Landin calls C and C calls Landin, how a program links, and how it
reaches the processor with atomics, assembly, placement and device
registers. It ends where a program begins: the entry point, the
capabilities it hands out, and what happens when a check fails.

### [1550] What the compiler produces

`refine` compiles the whole program at once into assembly text, and the
platform's own assembler and linker turn that into an executable. There is
no LLVM and no C in between.

- The emitted assembly is deterministic: the same program and options
  give the same bytes, whatever the build directory, environment or order.
  The linked executable is not covered by that promise.
- Every ordinary routine and every interrupt handler sets up the frame
  pointer, so a debugger or a backtrace can always walk the stack. On
  Cortex-M0 a routine with no calls, no assembly and no stack changes may
  leave it alone (spec [1990]). A naked routine ([1570]) owns its frame
  instead.
- The whole program is compiled together ([1480]). The compiler may keep
  private caches, but there is no stable separate-compilation interface.

Going through C would lose the calling convention, the traps and the debug
information Landin is precise about, so every target's backend is
Landin's own. The README lists the targets.

On Cortex-M the `cortex_m0` backend emits ARMv6-M Thumb, the default
`armv6-m` level. `--level=armv7-m` or `--level=armv7e-m` lets it use that
level's instructions too, which the processor must then support. All three
levels are little-endian and soft-float. A firmware request emits its own
reset code, vector table and linker script: reset copies initialized data
and RAM code out of flash and clears BSS before your code runs.

Exact rules: spec [1990].

### [1560] The `compiler`, `assembler` and `linker` modules

Three builtin modules reach the toolchain. They belong to the reserved
`landin` package (`landin/compiler` and its siblings) and are in scope
without an import, which is why nobody else can use their bare names.

| module | what it reaches |
| --- | --- |
| `compiler` | target, word size, byte order, build mode, CPU features, the atomic, volatile and register intrinsics, and `compiler.unreachable()`, a call that never returns and stops the program as a failed check does |
| `assembler` | inline assembly |
| `linker` | libraries, sections, entry |

Their members are built into the compiler; you cannot write one yourself.
Some arguments must be fixed when the program is compiled:
`compiler.assert` takes a fixed condition, `linker.library` a fixed name
and `assembler.block` fixed instruction text. Atomic and volatile pointer
and value operands, and assembly inputs, can be runtime values; an atomic's
ordering is always a fixed `compiler` atom.

What works today:

- Every hosted target has the compiler facts, `compiler.assert`,
  `linker.library` ([1590]) and the scalar atomics and barriers ([1620]).
- Cortex-M0 also has placement annotations ([1640]) and the firmware entry
  request ([1650]), which hosted targets refuse.
- `assembler.block` is checked on every target ([1630]).
- Any other tool operation is refused by name.

Something is builtin when the compiler has to understand it. Atomics are,
because opaque assembly in a hot loop wrecks the register allocation
around it. Masking interrupts is not: a critical section wants nothing
moved across it, which is exactly what opaque assembly gives. So
`cortex_m.disable_interrupts` and its kin are an ordinary module per
target, written with `assembler.block` ([1630]). An operation that comes to
mean the same thing on every target, as the atomics do, can move into
`compiler`. There are no vector intrinsics: fixed arrays are the vector
type and take element-wise operators ([0590]).

### [1580] Importing from C

A bodyless `extern(c)` declaration imports a C function. `refine` reads
Landin, never C headers: a separate, deterministic binding generator reads
headers and writes these declarations for you.

```landin
none_returned: atom
allocation: type = none_returned | ptr mut u8
extern(c) malloc: (n: usize) -> (p: allocation)
extern(c) free: (p: ptr mut u8) -> none
```

A C pointer may be null and a Landin pointer may not. So a C result or
parameter that may be null is [0480]'s one-atom pointer union, which costs
no extra bits, and you `match` the result before using the pointer.
`ptr(0)` is refused, and so is any fixed expression that folds to zero at
the target's `usize` width. A pointer built from an integer at run time is
checked, and zero traps, even in `unchecked`: losing the origin is not
permission to make null. Absent allocator backing is a named union too,
never a fake `ptr(1)`.

A header does not say everything Landin wants to know: whether a pointer
may be null, who owns it, what it is `from`, whether C retains it, how to
read incoming varargs. The generator takes that from a written policy, not
from a handwritten replacement signature.

A function found while the program runs, such as a symbol of a loaded
library, is just an address. Apply a C function type to it and you have a
function value:

```landin
c_adder: type = extern(c) (a: i32, b: i32) -> (r: i32)

add_at: (address: usize) -> (sum: i32) =
    add := c_adder(address)
    sum = add(2, 3)
end add_at
```

Nothing can check that code of that type is there, as nothing checks a C
cast, and the value is yours to call only while the library stays loaded.

Four C ABIs are supported: SysV AMD64 LP64 on Linux and FreeBSD x86-64,
Apple's arm64 variant of AAPCS64 on macOS, the standard AAPCS64 on Linux
and FreeBSD arm64, and RV64 LP64D on Linux RV64.

`platform/c` names C's types: the signed and unsigned integer widths,
`c_size`, `c_ptrdiff`, `c_float`, `c_double` and `c_bool`. It asserts
`compiler.c_sysv_lp64 or compiler.c_darwin_lp64 or compiler.c_aapcs64_lp64
or compiler.c_riscv_lp64d`, so it admits exactly those four ABIs; another
target with the same pointer width is not admitted. Plain `c_char` is the
ABI's plain `char`, a number and not a Unicode scalar: `i8` under SysV and
Apple's ABI, `u8` under the standard AAPCS64 and RV64.

What crosses the boundary:

| kind | how it crosses |
| --- | --- |
| integers, `bool`, pointers, `f32`, `f64`, C function values | by value |
| nonempty `layout(c)` structs, with nested structs, nonempty fixed arrays and fixed C callbacks as fields | by value |
| packed records and records with a flexible array member | by pointer only |
| fixed arrays | as fields or pointees, never as a by-value argument or result |
| C enums | as their integer values |
| unions, bitfields, globals, thread-locals, nullable callbacks | through the generator's representations and adapters |

Anything else a header can say, such as `long double`, 128-bit integers,
complex or vector types, or forwarding a `va_list`, is refused by name
rather than guessed.

A variadic C function writes `, ...` after at least one fixed parameter.
This `...` is C's variadic tail, unrelated to [0960]'s `! ...`.

```landin
extern(c) printf: (format: ptr u8, ...) -> (written: i32)

say_count: (format: ptr u8, count: i32) -> none =
    _ = printf(format, count, 1.5)
end say_count
```

- Calls, direct or through a function value, are positional only,
  including the fixed parameters.
- The variadic tail takes scalars, pointers and fixed C callbacks, not
  structs, arrays, slices, atoms or `any`.
- C's promotions apply: `f32` becomes `f64`, and `bool` and narrow integers
  become C `int`. An untyped literal is `i32` or `f64`.
- A variadic function value may be stored and called in Landin, but it
  cannot fill a C callback field or parameter.
- A Landin definition cannot receive varargs; the generator writes a C
  adapter from an explicit extraction schema instead.

Exact rules: spec [1975].

### [1600] Exporting to C

Give an `extern(c)` declaration a body and you have defined a C function
in Landin. Make it `public` and C code can call it by its name.

```landin
public extern(c) my_add: (a: i32, b: i32) -> (r: i32) =
    r = a + b
end my_add
```

`extern(c)` chooses the calling convention and nothing else. Without a body
it imports; with a body it defines; `public` is what exports, making the
declared name a global symbol. A private C definition is still useful: its
address can be handed to C as a callback.

- A C signature is not generic, takes only `in` parameters and returns at
  most one value.
- Landin's declared failures do not cross. Recover inside the body and
  return the status or value the C interface promises.
- Nothing is promised if a foreign exception or a `longjmp` crosses
  Landin frames.
- Cortex-M has no C signatures yet. Its link names and placement are
  enabled separately ([1610], [1640]).

### [1610] Choosing a symbol's linker name

`link(symbol: "...")` gives a declaration a linker name its Landin name
cannot spell, or does not want. It follows `extern(c)` for a C import or
definition, or stands alone before a native Landin function or a module
datum.

```landin
link(symbol: "native_identity") identity: (value: i32) -> (result: i32) =
    result = value
end identity

extern(c) link(symbol: "foreign_add") add: (a: i32, b: i32) -> (r: i32)
```

Landin code still calls these `identity` and `add`: `link` changes neither
lookup nor signature nor Landin visibility. The standalone form keeps the
native Landin convention and still needs `= body end`; `link` never means
C and never means bodyless.

It does export. A link name is a global symbol whether or not the
declaration is `public`, and that is how you export a module datum
deliberately. Without `link`, C imports and public C definitions use their
declared name. Every other routine and datum, public or private, is a
local symbol under its own name, so no C library can collide with it. It
is renamed, with its module path, only when the program holds that name
twice.

- A link name matches `[A-Za-z_.$][A-Za-z0-9_.$]*`: no whitespace, no `@`
  suffix, no assembler expression.
- It is the name before the platform's prefix. ELF uses it unchanged;
  Darwin adds one underscore, so `foreign_add` becomes `_foreign_add` and
  `_entry` becomes `__entry`. The backend quotes it where the assembler
  needs that. Native and C link names follow the same rule.
- Bodyless C declarations may share a symbol with each other and with one
  definition if their signatures agree. Disagreeing signatures and a
  second definition are refused. `escaping` counts, although C has no such
  word: an import of a C function that keeps its pointer must say so, as
  the definition does.

Exact rules: spec [1975].

### [1590] Linking a static library

`linker.library` asks the linker for a static archive. Write it next to the
declarations that need it, not in a separate build file.

```landin
linker.library("m")
```

This links `libm.a`.

- The name is a fixed text literal of ASCII letters, digits, `_`, `-` and
  `.`. It is nonempty, does not begin with `-` and is not only dots.
- Active directives reach the linker after the program, in source order,
  repeats included. So moving one among the module's declarations can
  change how archives resolve. This is the one place where declaration
  order matters. A directive in an inactive arm of a `fixed if` ([1500])
  adds nothing.
- On Linux an archive links beside the C library, so a build that asks for
  one needs `--link=libc`; the default static link ([1650]) refuses it.
- On Darwin the driver resolves `libNAME.a` and passes that file. A missing
  archive fails even when a dylib of the name exists. With Apple's default
  driver, a bare filename it returns must exist in the directory the build
  runs in.
- Cortex-M firmware refuses `linker.library`.

### [1570] Calling conventions

A function's calling convention is written `extern(...)` before its name.
Without one, a function uses Landin's own convention.

| convention | for |
| --- | --- |
| `extern(c)` | the target's C ABI ([1580], [1600]) |
| `extern(interrupt)` | an interrupt handler, whose entry, exit and vector placement differ from a call ([1640]) |
| `extern(naked)` | no prologue at all: the body is one assembly block ([1630]) |

The convention is an atom, not a keyword, so the set can grow, for
example to `extern(aapcs)`, `extern(sysv)` or `extern(win64)`. No other
convention is in Landin yet.

The two machine conventions are their own function types:

- A definition is nongeneric, exactly `() -> none`, and declares no
  failures. Its function value can be stored or named by a vector, but not
  called or converted to an ordinary or C function.
- An interrupt handler runs an ordinary Landin frame on top of the
  hardware's exception frame and returns through EXC_RETURN.
- A naked body is one assembly block with no compiler prologue. The stack,
  registers, calls and return instruction are yours, and falling off the
  end traps.
- Neither convention keeps a routine from section garbage collection
  ([1640]).
- Naked routines also work on hosted x86-64, arm64 and RV64;
  `platform/linux`'s process entry is one.

### [1620] Atomics

Atomic operations are `compiler` builtins, not assembly, so the compiler
knows which memory they touch and can still allocate registers around them.
The ordering is a fixed atom.

```landin
bump: (p: ptr mut u32) -> none =
    _ = compiler.atomic_add(p, 1, compiler.acq_rel)
end bump
```

There is no atomic wrapper type in `core`. Cortex-M0 has no
read-modify-write atomics at all, so what a portable wrapper should offer
is a library question. It is planned (Broader standard library, in
[the roadmap](ROADMAP.md)).

Each tool for shared memory does one thing:

| tool | what it gives |
| --- | --- |
| atomics | synchronization of coherent CPU memory between threads |
| volatile accesses ([0850]) | every access happens, as written; no synchronization between threads |
| compiler barrier | the compiler forgets what it knew about memory; no hardware ordering |
| the target's device and completion barriers | hardware ordering and completion of the accesses before them |

A DMA buffer stays an ordinary slice. When the device has finished, by its
own protocol and not merely because an interrupt arrived, make its writes
visible with the target's barriers or cache maintenance and a compiler
barrier, then read the buffer. Masking interrupts does not stop DMA.

`spec.md` defines the supported operations, the exact orderings, alignment
traps, happens-before and what a race may do. Exact rules: spec [1990].

### [1630] Inline assembly, for what has no builtin

`assembler.block` takes fixed quoted or raw text in a routine body, and
after it the operands that carry values in and out. An operand names its
direction, its name, its type and the register it is placed `at`:

```landin
disable_interrupts: () -> (previous: u32) =
    previous = assembler.block("mrs {mask}, primask\ncpsid i",
                               out mask: u32 at general)
end disable_interrupts

restore_interrupts: (previous: u32) -> none =
    assembler.block("msr primask, {mask}\nisb sy",
                    in mask: u32 at general = previous)
end restore_interrupts
```

A register is a name the target answers for, never text. `general` asks the
compiler to choose one, and `{mask}` in the text is where the chosen
register goes, spelled at the width the operand's type selects. A fixed
register is the architecture's own full-width name, and the text may use it
directly. `in` carries a value in, `out` carries one out, and `inout` does
both through one register. The outputs are the block's value, as a
function's named returns are its: one is a scalar, several are an anonymous
result you destructure.

```landin
(low, high) := assembler.block("rdtsc", out low: u32 at rax,
                               out high: u32 at rdx)
```

What an operand can be:

- An integer scalar that fits one register. A float operand is refused by
  name. Float operands are not in Landin yet; they are planned
  (Language evolution, in [the roadmap](ROADMAP.md)).
- A pointer crosses as `usize(p)` and comes back through `ptr(u)`, whose
  zero check then happens there. A flag comes back as `x <> 0`.
- Inputs are evaluated once, left to right, before the block runs.
- The integer keeps no permission. So a routine around a block that writes
  storage takes it as `ptr mut u8` or `[]mut u8`: its callers are checked
  against that parameter, and an immutable buffer is refused there rather
  than handed to the system.

What a block may touch: every block may overwrite the registers a call may,
and the flags. A register a call must preserve is declared, as an operand
or as a discarded output `out _ at rbx`, and that is what makes the routine
save it. The frame, stack and link registers are never named, so a block
cannot break a backtrace. The language reserves no register of its own.

Every block is opaque to the compiler: memory knowledge is invalidated and
memory accesses cannot be moved across it, which is exactly what a critical
section wants. It is not itself a hardware barrier. An ordinary block is
straight-line code, with no labels or calls; a system call returns to the
next instruction, so it is straight-line too. The older Cortex-M0 form
stays as a shorthand: `assembler.block(text, value)` passes one `u32` in
and out of r0, and the text names r0 itself.

`platform/cortex_m` wraps the common blocks:

- `disable_interrupts()` returns the prior PRIMASK, and
  `restore_interrupts(previous)` puts it back, so nested critical sections
  do not enable interrupts too early. Both work in thread and handler mode.
  They do not stop DMA or mask NMI or HardFault.
- `wait_for_interrupt()` issues DSB, then WFI. Waking up is a reason to
  check the device again, not proof that it finished.
- `compiler_barrier`, `device_barrier` and `completion_barrier` are the
  three distinct boundaries of [1620]. There is no cache or scheduler API.

A naked body ([1570]) owns its control flow, so its block may use labels
and branches. This entry runs after the compiler's reset has initialized
data and stacks:

```landin
extern(naked) start: () -> none =
    assembler.block("""
        1:
        wfi
        b 1b
        """)
end start
```

```sh
refine compile main.ldn --target=cortex-m0 --firmware-entry=start --emit=exe
```

The request names the source entry. A naked entry may set up PSP or call
explicitly linked ordinary code, but it must then meet that code's
eight-byte stack alignment, r9 and frame obligations. `none` is not a
promise never to return: the compiler traps if the entry returns or the
naked block falls through. There is no hosted caller to return to.

Exact rules, with each target's registers, the text rules and your
obligations: spec [1990].

### [1640] Placing code and data on a microcontroller

On Cortex-M, a `link(...)` annotation also places a declaration: in a
section, at an alignment, in an interrupt vector slot, and kept against the
linker's section garbage collection.

```landin
link(vector: 16)
extern(interrupt) device_handler: () -> none =
    assembler.block("nop")
end device_handler

link(section: ".rodata.firmware_mark", align: 16, keep)
firmware_mark: [4]u8 = [55, 48, 49, 0]
```

Slot 16 is IRQ0 in the selected profile: a vector number is the absolute
slot in the table, not an IRQ number or a peripheral's name.

The compiler owns the vector table. Its first word is the initial stack
pointer, its second the compiler's reset, reserved slots are zero, and
`vector` annotations fill in handlers with their types checked. So a stack
address, a reserved word and a handler can never be mixed up. A vector
annotation needs a firmware-entry request ([1650]).

What survives the link:

- The table is kept and refers to each handler in it, so those handlers
  survive.
- An interrupt routine nothing refers to and nothing keeps can disappear.
- `keep` retains the section that holds the declaration. Several objects
  placed in one section share that retention.
- A link name alone retains nothing.

Where things go:

| what | sections |
| --- | --- |
| functions | `.text.*` in flash, or `.ramtext.*`, copied to RAM at reset |
| immutable data | `.rodata.*` |
| mutable data | `.data.*`, or `.bss.*` when zeroed |

- `align` is a power of two up to 256. It places the object and does not
  change its type's layout.
- `align` and `vector` take decimal literals; digit separators are fine,
  hex and expressions are refused.
- The image is 32 KiB of flash and 16 KiB of RAM, whose top 4 KiB is
  reserved for stacks. The linker checks bounds and overlap.
- The compiler refuses reserved vectors, a section that does not match the
  declaration, duplicate attributes and symbol collisions.
- There is no module initialization in user code ([1460]).

Calling convention, symbol name, placement and retention are four
independent choices; none implies another.

### [0730] Register images: flags, selections and sets

A hardware register mixes kinds of field, and confusing them is the classic
driver bug. Landin describes a register as a packed struct whose fields sit
at bit positions you write down.

| kind | what it is | how you write it |
|---|---|---|
| flag | one bit | `bool` |
| selection | one of several named values, encoded as the datasheet says | a union of atoms with encodings |
| set | several independent flags at once | a packed struct of `bool` |
| number | a plain number | an unsigned field such as `u12` |

The examples below use these atoms:

```landin
irq_rx: atom
irq_tx: atom
irq_err: atom

internal: atom
external: atom
pll: atom

active_low, active_high: atom
by_1, by_2: atom
```

A selection is a union that gives each atom its encoding. The encoding
belongs to the union, not to the atom, so the same atom may be encoded
differently in another register. The width is the smallest that holds the
largest encoding; write a base type only when the datasheet gives the
field more room than it needs.

```landin
polarity: type = (active_low = 0 | active_high = 1) -- one bit
clock_mode: type = (internal = 0 | external = 1 | pll = 4)
divider_sel: type = u4 (by_1 = 0 | by_2 = 1) -- four bits, as given
```

A set is a packed struct of `bool`, one field per member, each at the bit
its member's encoding names. Membership is a field read, adding or
removing a member is a field write, and building one is an ordinary
struct literal with `of` ([0720]). There is no set literal or set
operator, because a struct needs none. Inside a larger image the same
fields sit at the image's bits, offset by where the set begins.

```landin
irq: type = (irq_rx = 0 | irq_tx = 1 | irq_err = 2)

irq_set: type = layout(packed, u32) struct
    irq_rx: bool at 0
    irq_tx: bool at 1
    irq_err: bool at 2
end irq_set

control: type = layout(packed) struct
    enable: bool at 0
    mode: clock_mode at 4..6
    irq_rx: bool at 8 -- irq's encodings, from bit 8
    irq_tx: bool at 9
    irq_err: bool at 10
    divider: u12 at 16..27
end control
```

A set earns its place when its members mean something. A numbered bank of
lines does not: sixteen output pins are `[16]bool` at `0..15`, not sixteen
invented atoms.

Bit positions are written, never implied by field order, so reordering
the fields of a published register is not a hidden breaking change. In a
packed struct every field carries a position, or none does. Any bit no
field claims is reserved: you cannot name it, no completion list offers
it, and a read-modify-write leaves it untouched.

You rarely write these by hand. A generator reading a vendor's SVD file
writes the fields, and the helpers [0740] uses, for every register. SVD
generation belongs to the companion tool; the language has no `set(X)`
type former to do it instead.

A field may be an array, which is how a real peripheral packs sixteen
two-bit pin settings into one word. The element width times the count must
equal the range, and element zero takes the low bits.

```landin
pin_input, pin_output, pin_alternate, pin_analog: atom

pin_mode: type = (pin_input = 0 | pin_output = 1 | pin_alternate = 2 | pin_analog = 3)

moder: type = layout(packed) struct
    pins: [16]pin_mode at 0..31
end moder

set_pin: (inout m: moder, n: usize, mode: pin_mode) -> none =
    m.pins[n] = mode
end set_pin
```

Indexing such a field with a run-time value is a shift by a computed
amount, with a bounds check that stays even in `unchecked`. Do it on an
image in memory, never straight on the device ([0740]).

Fine print:

- A packed struct is a raw image, and every bit pattern is a valid image.
  Copying, passing and returning it keep all its bits.
- Reading an encoded field checks that the bits name a member and traps if
  they do not, so a `match` on the result can be exhaustive.
- Writing a field leaves every other bit alone, and a fresh literal starts
  from zero. A packed field has no address of its own: to update one, pass
  the whole image.
- `layout(packed, u32)` keeps a 32-bit carrier even when the highest
  position would fit a smaller one.
- Field widths run from `u1` to `u64` inside packed structs only; they add
  no arbitrary-width arithmetic or calling convention.

Exact rules: spec [1870].

### [0740] Reading and writing a device register

A device register is read and written by two operations, and how the
register behaves is data you pass them, not a keyword:

- `compiler.register_read(pointer, read_mode)`
- `compiler.register_write(pointer, image, write_mode, reserved_policy,
  named_mask)`

The pointer is an ordinary one to `u8`, `u16`, `u32` or `u64`, and its
width is the one transaction the device sees. Modes and policies are atoms,
so a generator can describe write-one-to-clear, clear-on-read and whatever
the next vendor invents without the language growing a word for each.

```landin
status_raw: (base: usize) -> (raw: u32) =
    port: ptr u32 = ptr(base + 0x04)
    raw = compiler.register_read(port, compiler.normal_read)
end status_raw

clear_events: (base: usize, events: u32) -> none =
    port: ptr mut u32 = ptr(base + 0x08)
    compiler.register_write(port, events, compiler.one_clears,
                            compiler.write_zero, 0x0000_0007)
end clear_events
```

| argument | values |
|---|---|
| read mode | `compiler.normal_read`, `compiler.clear_on_read` |
| write mode | `compiler.normal_write`, `compiler.one_clears` |
| reserved policy | `compiler.preserve`, `compiler.write_zero`, `compiler.write_one` |
| named mask | a fixed number of the register's width, with a one at every bit a field names |

A register that cannot be read has no read to perform, so
`compiler.no_read` is an error rather than a mode, and so is
`compiler.no_write`.

You cannot write a single field of a device register. For an ordinary
read/write register, read the whole image, change it locally and write it
back whole. The generator of [0730] writes, beside `control`,
`control_decode` from the raw `u32` to the image, `control_encode` back,
and the constant `control_named_mask`:

```landin
reset_flags: (base: usize) -> none =
    port: ptr mut u32 = ptr(base)
    image: control = (enable: true, mode: external, irq_rx: true, of zeroed)
    compiler.register_write(port, control_encode(image),
                            compiler.normal_write, compiler.write_zero,
                            control_named_mask)
end reset_flags

read_modify_write: (base: usize, n: u16) -> none =
    port: ptr mut u32 = ptr(base)
    mut image := control_decode(compiler.register_read(port,
                                                       compiler.normal_read))
    image.divider = n
    compiler.register_write(port, control_encode(image),
                            compiler.normal_write, compiler.preserve,
                            control_named_mask)
end read_modify_write
```

A fresh local literal knows nothing of what the hardware holds. To keep
reserved bits as the device has them, read the image first, as
`read_modify_write` does; `compiler.preserve` never reads behind your back.
That read, change and write is not atomic, and it does not carry over to
clear-on-read or one-clears registers: a destructive read consumes state,
and a one-clears readback is not a command.

A register's reset value initializes nothing. It is what the datasheet says
the register holds after a reset, generated as a constant so that tools and
readers know where they start. The hardware puts it there, not the program.

The operation, not the pointer's type, makes an access a device
transaction: there is no `volatile ptr` and no `register(t, ...)` wrapper
type.

Exact rules: spec [1870].

### [1650] Where a program starts

A hosted program starts at `public main: () -> (code: i32)` in the entry
module, and `code` is the exit status, passed through the system's C ABI.

The arguments are not parameters. You ask the host for them, as
`io.argument_at(host, 0)` does in "Reading a file" at the top: the host
keeps the argument table and lends each argument as a host string
([1660]). The first argument is the one after the program's own name. C's
`argc` and `argv` shape could not be indexed in Landin without turning a
pointer into a slice, which Landin does not do ([0500]).

A Linux executable needs no C library. It starts at `platform/linux`'s
`_landin_start`, which calls `main` with the process's arguments;
`--link=libc` links the C runtime instead. Darwin and FreeBSD always link
their C library.

When the program imports `hosted/system`, and so `platform/posix`, the
entry first calls this C-callable routine with the real values, before the
body of `main` begins, so the environment is kept beside the arguments and
lent the same way:

```text
void _landin_host_initialize_arguments(int argc, char **argv, char **envp);
```

When C owns `main` and calls exported Landin routines, it calls that
routine itself, with its own `envp` or C's `environ`:

- Call it before `system.new()` acquires an argument capability, and
  before starting any thread that may acquire one. File, stream and heap
  work needs no argument root, so linking `core/io` alone does not require
  the call.
- The first call with a nonnegative count and a non-null table sets the
  one root; a null environment is an empty one. Repeating exactly the same
  three values is harmless. Using the argument services before the call,
  or calling with different values, traps. No ordinary export or callback
  initializes or resets the root.
- Nothing is copied. The C owner keeps the tables and the strings they
  name readable as long as any world, view or callback derived from them
  can use them.
- The arguments start at `argv[1]`, so a C program run with only its own
  name gives Landin no arguments.

Freestanding, there is no `main`. The compiler request names the entry: an
infallible ordinary `() -> none` or `() -> noreturn` routine, or a naked
`() -> none` one, in the entry module ([1630] shows the request). The
compiler's reset initializes RAM before calling it. Returning from it, or a
failed check, traps, since there is no hosted exit to go to. General build
and package orchestration are outside the firmware path.

Exact rules: spec [1975] for hosted programs, spec [1990] for firmware.

### [1660] Where capabilities come from

The entry point is the usual place to make the program's roots — the host,
an allocator, a diagnostics log — and pass them down as ordinary arguments.
The language does not reserve that to the entry point: any routine can call
the constructors ([1680]). A hosted root imports `hosted/system`; a
caller-backed one needs only `core/io`.

This is the essential flow of `examples/derived_hosted`, a complete log
filter. Its `main` is one line, `code = app.entry()`, and the work starts
in `entry`, a public routine of the program's own `app` module. That
module imports `hosted/system`, `hosted/heap`, `core/region`, `core/diag`
and `core/io`, and `run_logged` is the application's routine that does
the work:

```landin
public entry: () -> (code: i32) =
    host := system.new()
    world: any io.world = any(addr host)
    heap := heap.new()
    mut ledger: region.growing_space = zeroed
    program := region.over(ledger, heap)
    defer region.release(ledger, heap)
    writer: any io.writer = any(addr host)
    mut logger := diag.stream(writer, world.err())
    log: any diag.log = any(addr logger)
    kept: usize = run_logged(program, world, usize(4096), log) else (problem)
        _ = problem
        code = 1
        return
    end
    _ = kept
    code = if log.failed() then 1 else 0 end if
end entry
```

Each root is a handle: a small value, copied and passed by value, that
refers to its state.

- `system.new()` and `heap.new()` borrow nothing, because what they refer
  to belongs to the process: the argument root, the descriptors, the last
  errno and the heap. `system.new()` acquires the real argument table; it
  does not create or copy it ([1650]).
- A caller-owned provider is made from state the caller declares, as the
  region is made from `ledger`. The handle cannot outlive that state, and
  the state cannot be released while the handle is still used.
- An erased capability is built from the address of a handle binding, and
  its dispatch copies the handle from there. So `world`, `writer` and
  `host` itself can be used side by side, and nothing is locked.

Because the code below the root only sees what it is handed, you can hand
it something else. A test gives the same `run_logged` an in-memory world
from `core/io`'s `io.memory_over`, which takes caller-owned files,
arguments and output storage and makes no host call, and the run cannot
tell.

For that to work, I/O is a concept, not a type, so another provider can
satisfy it. It travels as `any`, not as a type parameter: an indirect call
in front of a system call costs nothing, whereas an allocator sits in hot
loops and is threaded generically. Same machinery, chosen per case
([1690]).

It is four concepts, because a provider should supply only what it has
([1260]):

| concept | entries |
| --- | --- |
| `io.writer` | `write`, `write_some` |
| `io.reader` | `read` |
| `io.files` | open, close, `same_file` |
| `io.process` | the three standard streams, the argument table |

`core/io` has more concepts beside these four, each separate and not part
of the world: `directories`, `environment`, `programs`, `file_system`,
`terminals` and `entropy`.

`io.world` composes the four for a root that has everything, and
`world.write` on an erased world reaches the writer's entry. A UART
implements `writer` and nothing else. A diagnostics log asks for
`any io.writer`, which is why `entry` builds one from the same `host`: an
erased world is not an erased writer, and the two do not convert. A routine
holding only the world lends its writer with `io.writer_of(world)`.

Both providers lend each argument and path as a `text.host_string`: the
bytes the system gave, unconverted and uncopied, so an argument passed on
as a path reaches the system unchanged, whether or not it is UTF-8.
Neither provider's arguments include `argv[0]`. The library reference
describes the system provider (`hosted/system`), the memory provider and
host strings (`core/io`, `core/text`); the exact provider contracts —
errno capture, whole and partial writes, retries, `same_file` — are in
spec [1975].

### [1670] When a check fails

When a check fails — an index out of range, an overflow, a bad conversion,
an `unreachable` — the program calls a fixed handler that never returns.
With none of your own, a hosted program writes one line,
`FILE:LINE:COLUMN: trap: KIND`, to standard error and stops; firmware just
stops.

To replace the default, declare a public `panic_handler` of exactly this
shape in the entry module:

```landin
import core/panic

public panic_handler: (kind: panic.panic_kind, site: u32) -> noreturn =
    loop do
    end loop
end panic_handler
```

It gets two scalars and no strings. `kind` is one of `core/panic`'s
`out_of_range`, `overflow`, `bad_conversion` and `unreachable`. `site` is
a plain `u32`, not [1040]'s `site` struct: a number the compiler gives the
failing operation and its check family. File and line live in an optional
table outside the target, so a small firmware image carries no file names.
`refine --panic-map` writes that table, and `scripts/source-location.py
--panic-site`, a script in Landin's source repository rather than part of
`refine`, resolves a site against the build that made it, and only that
build.

- The handler must have exactly this infallible form and atom domain. A
  linker symbol of the same spelling does not replace it.
- A failed check does not unwind: the failed computation's `defer` and
  cleanup do not run.
- Entering the handler a second time traps, including a check that fails
  inside it.
- Caller coordinates are a separate value ([1040]).
- Hardware faults and naked assembly keep their machine obligations.

Exact rules: spec [1960].

## THE PRINCIPLES BEHIND THE DECISIONS

A few rules explain most of Landin's choices. When something in the tour
surprises you, one of these is usually why.

### [1680] Pass the capability, don't track the effect

Landin has no effect system. A routine that does I/O, allocates or reads
the clock takes the thing that does it as a parameter: an allocator, an
`io` writer, a peripheral handle, a random source. A caller can then hand
it an in-memory world or a bounded allocator.

The parameter list says what a caller supplies, not everything the call
can reach. Any hosted routine may call the public host and heap
constructors itself, and a driver may make a pointer from an address
[0460]. Creating the roots in `main` [1660] is a convention the compiler
does not check. If you need to know that a call tree does no host I/O, read
its calls and imports. Exact rules: spec [1975].

### [1690] One mechanism, read two ways

Generic code and `any` share one foundation: evidence that a type satisfies
a concept. When the compiler knows the concrete evidence it may specialize
the call; otherwise the call goes through a table, and an `any C` value
carries that table with it. Static generics and runtime dispatch are two
readings of one feature, not two features ([1310], [1370]).

### [1700] Atoms are the same idea wherever they appear

An atom is identity without payload. Enumerations, error sets, variant
tags, register encodings and panic kinds are all uses of atoms, not
separate categories. There is no `enum` in the language because there is
nothing left for it to be.

### [1710] How a new feature earns its place

When a program cannot be written cleanly, ask in this order:

| ask, in order | then |
| --- | --- |
| can an existing mechanism express it? | a library |
| can the compiler work it out itself? | no syntax |
| must the programmer say it, and does saying it generalise or remove another mechanism? | a candidate |
| does it only solve this one case? | not yet |

A new mechanism should let two old ones leave the building.

### [1720] What Landin promises, plainly

Landin makes local checks: origins and escape, consumption [0910],
reference permission [0430], bounds, conversions and arithmetic. It is not
a memory-safe language and not a resource-safe one.

What the checks do not cover:

- Pointer-to-integer conversion and the C boundary leave the checked model
  altogether [0470].
- A copy taken before a `sink` is not refused [0910].
- Distinct pointer or computed-index paths may alias across `inout`
  [0900].
- Two arenas look the same to the compiler [0860].

That is a smaller claim than "safe" and a larger one than C's: deliberately
unsafe, with static help worth having. `spec.md`'s guarantee register
classifies every observable failure boundary the compiler implements, and
each new operation joins it.

Checks are on by default. `unchecked` [1120] removes only the checks that
entry lists, only in the region where it is written, and tells the
optimizer nothing: it emits fewer checks and gives no later pass a fact to
assume. Optimization adds no undefined behavior, no-alias, overflow or
floating-point assumption because of it, and keeps scalar results and the
order of side effects and traps.

### [1730] Check once, then carry the proof

A successful check can produce a value that stands for what was checked. A
buffer that passed the alignment test becomes a `dma_buffer`, and the DMA
interface asks for nothing else. Distinct types, range subtypes and error
sets are enough for this; it needs no feature of its own, only the habit.

For a range subtype, the proof starts with a checked subtype value, not
with a guard on an ordinary integer.

## WHAT LANDIN DELIBERATELY DOES NOT HAVE

- no classes, inheritance, methods or runtime type information
- no exceptions, no stack unwinding, no catchable panics
- no garbage collection and no reference counting
- no destructors
- no closures that capture
- no implicit conversions
- no null
- no positional tuples: anonymous records with named fields exist
- no function name overloading and no multiple dispatch
- no user-defined operators and no macros
- no compile-time execution
- no separate interface files
- no header parsing inside `refine` (the separate binding generator reads
  headers)

## WHAT IS STILL OPEN

Open work is listed in [ROADMAP.md](ROADMAP.md), not here. That includes
what this tour leaves parked: structure-of-arrays [0620], affine values
[0910] and restricting where capability roots are created [1680].

`refine` implements the whole of this pre-v1 language, and [the
README](README.md#current-compiler-capabilities) says what it does today.
Production status, release versioning, package acquisition and
self-hosting are not part of the current plan.

Warnings are the compiler's observations about legal source, never extra
language rules: you can select, suppress or deny them by code, and a denied
warning fails that compilation while the program stays legal Landin.
Shadowing is never warned about.

### [0620] Storing a collection field by field (deferred)

DEFERRED: not in Landin yet; it is planned (Language evolution, in
[the roadmap](ROADMAP.md)). A
collection could be stored transposed, one array per field instead of one
array of structs, written `soa [4096]entity`, so that one field of every
element is a contiguous slice. It touches aliasing, generics, slicing,
`addr`, layout, debug information and the optimiser all at once, and no
program has needed it yet. Until one does, generate the arrays with a
program that writes the source ([1540]).

## WHAT WAS TRIED AND DROPPED

This appendix is design history. You do not need it to learn or use
Landin; it is here for anyone about to propose one of these ideas again.
Its examples keep the spelling of their time, so some of them are not
Landin as it is now.

The revision log this replaces recorded every change across a long
sequence of versions. Most of it was arrival. What is worth carrying
is the other kind of entry: the thing that was designed, sometimes
built, and then taken out again — because a reader who does not know
that will propose it back, and because a design is partly defined by
what it refused.

- an ambient environment, carried in a register, holding the allocator
  and the diagnostics and the Io — Odin's context. Designed in
  full, then removed. Once the argument was that every property it
  needed made it visible anyway, the only thing left was its
  implicit flow, and that was the thing worth losing. It became an
  ordinary parameter and the ABI lost a reserved register [1680].
- compile-time execution, refused twice. It would have given generics,
  macros and configuration from one mechanism, and it costs an
  interpreter inside the compiler. The accepted price is that
  generated tables and vendor bindings come from generator
  programs [1540].
- witness tables as the only story, then monomorphisation as the only
  story: both refused. The table is the foundation and specialising
  is an optimisation weighed per instantiation [1310].
- cost annotations on a conformance, and the concepts that went with
  them. Removed entirely: how finely a concept distinguishes what
  an operation costs is a library's business, and no language
  guarantee should rest on how clever an optimiser happens to be
  [1270].
- a concept for ranges. Integer range traversal now uses bounds in a
  `for` header, and left-exclusive forms went with the concept [0360].
- a second type with the shape of a fixed array and different
  operator rules. Fixed arrays are the vector type [0590].
- transposed collections, designed and deferred: they touch aliasing,
  generics, slicing, addr, layout, debug information and the
  optimiser at once, and no program has yet needed one [0620].
- weak conformances, built and removed. Libraries would declare
  weakly and applications override strongly, which worked — and
  meant an application could quietly change the behaviour of
  generic code inside a library. A collision is simply an error
  [1280].
- labels on if and match, removed; they earn their place on loops and
  bare blocks only [1180].
- errdefer, refused, and then arrived at from the other side. A
  cancellable defer was tried first and dropped, because the
  cancel always sits where the block succeeds and is hand-made
  bookkeeping for a question the exit already answers. defer with
  an argument was dropped because it reads as a call. What went in
  is undo, its own word, because to defer is to do it later and
  this may never be done at all [1110].
- read-only reference types spelled as a second form of every
  reference — considered twice and refused both times, then
  arrived at anyway from the other end. What was refused was deep
  const with an implicit widening; what went in is permission in
  the type with one stated relaxation, and it removed two
  mechanisms rather than adding one [0430].
- permission derived from where a reference came from, which lasted
  one version. It rescued the register case and could not express
  the commonest signature in a driver, so it was replaced by
  permission in the type [0430].
- inferred derivation for the from clause, refused with a
  counterexample rather than an argument: mechanically an
  allocator's result does come out of the allocator, so inference
  forbids a second live allocation [0790].
- braces, which were never a decision. They crept into two register
  examples and a set literal and were taken out again; the
  language has none [0730].
- a keyword for the compile-time assertion. The collision with the
  ordinary assertion was resolved by subtraction: it is
  compiler.assert now, a builtin call like the rest, and the
  language has one keyword fewer [1510].
- sets as a kind of their own, with a literal, three operators and a
  membership operator, all of which were designed and then not
  needed: set(X) generates a packed struct of bool, so membership
  is a field read [0730].
- affine values, which cannot be copied. Not refused — parked, with
  the condition that would bring them in, and with sink honestly
  described in the meantime as a use-after-consume check on one
  place rather than as ownership [0910].
- async and await, and the stackless coroutines under them, refused
  before either was built. Concurrency is not a property of a
  function here; it is a capability the caller hands down, so the
  same code blocks or does not depending on the Io it was given
  [1660]. One implementation of that Io ships first and it blocks,
  which is a scheduler not yet written rather than a limit in the
  language. Stackless is the refusal proper: cutting a function
  into a state machine is a compiler project of its own, and it
  colours every function type that reaches one — the same
  objection that removed the ambient environment above [1680].
  Stackful fibres are the route to take instead, and the design
  already pays for them: the frame pointer is always present, the
  callee-saved discipline is explicit, and nothing rides in a
  reserved register.
- a volatile pointer type, a generated register wrapper carrying read,
  write and reset modes, and a `set(X)` type former, all sketched before
  any driver ran. The complete driver needed none of them: an operation
  says a device access happens, the modes are its arguments, and the
  generator writes the per-register functions and the named bool fields.
  A qualifier would have been a second permission on every reference
  [0740] [0850].
- per-field byte order and the weak, inline and noinline attributes,
  listed and never used. A big-endian field makes every access a
  conversion and its address unreadable through an ordinary pointer;
  inlining is the optimizer's business; one definition per name leaves
  weak nothing to do [0750] [0760].
- vector intrinsics beside element-wise array operators. The table
  listed both and only one was ever needed: fixed arrays are the
  vector type [0590] [1560].
