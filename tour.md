# Learn Landin in Y minutes

Ada, but small. Zig, but sweeter. One systems language from 32 KB to
32 TB*. Move fast, keep the pointers, and let the compiler tell you when
you are being an idiot.

Named after Peter Landin, who coined the term "syntactic sugar" and
wrote "The Next 700 Programming Languages". This one is the 701st.

Coming from C? [Landin for C programmers](docs/from-c.md) maps each habit
you bring to its Landin form.

## Hello, world

Make a directory, `mkdir hello && cd hello`, and save this in it as
`main.ldn`:

```landin
import core/io
import hosted/blocking

public main: () -> (code: i32) =
    host := blocking.new()
    io.write(host, io.out(host), "Hello, world!\n") else none
    code = 0
end main
```

Run it with `refine run main.ldn`, or keep an executable with
`refine compile main.ldn -o hello`.

- `core/io` is the interface for reading and writing; `hosted/blocking`
  provides it over the operating system.
- `main` is a function; the compiler's messages also say routine for one.
  It returns one named result, `code`, the exit status, and sets it by
  assigning it.
- `host` is your handle on the operating system: pass it to whatever needs
  to read or write.
- `io.write` can fail, and a failure cannot pass unnoticed; `else none`
  says it does not matter here ([1030]).

## Reading a file

This program counts the lines of the file named by its first argument.
Save it as `main.ldn` in a directory of its own:

```landin
import core/failure
import core/io
import hosted/blocking

--- How many lines the file named by the first argument has.
count_file_lines: (host: blocking.host) -> (lines: usize)
                  ! io.no_argument | io.not_found | io.no_access
                  | io.is_a_directory | io.io_failed
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
    host := blocking.new()
    lines := count_file_lines(host) else (problem)
        words: []u8 = failure.words(problem)
        io.write_format(host, io.err(host), "error: {}\n", [any(addr words)])
            else none
        code = 1
        return
    end
    io.write_format(host, io.out(host), "{} lines\n", [any(addr lines)])
        else none
    code = 0
end main
```

- The `!` list says every way `count_file_lines` can fail, and `try`
  passes a failure on to the caller ([0960]).
- `defer` closes the file however the function ends ([1100]).
- `main` decides what a failure means: `else (problem)` handles it in
  place.
- `io.write_format` fills each `{}` with the next value.

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

A program that writes many lines gathers them in a
[buffered writer](docs/library.md#the-buffered-writer).
[`examples.md`](examples.md) has complete programs that list directories,
run commands and talk over sockets.

## How to read this tour

- Read it in order up to the end of MODULES and you can write ordinary
  programs; the rest is reference.
- The bracketed numbers, such as [0430], never change: when the compiler
  refuses a program, its error ends with the entry that explains the rule.
- Everything is implemented unless marked DEFERRED or *not yet*.
- [`spec.md`](spec.md) is the specification and decides wherever the two
  could be read differently.

*32 TB is an unverified goal. What it measures at the hosted end, and what
evidence would prove it, are still open, and nothing hosted today
establishes it. Terabytes may vary.

---

## COMMENTS

Each example in this section is itself a comment, exactly as it appears
in a program: the marker at its start is what makes it one.

### [0010] Line comments

`--` starts a comment that runs to the end of the line.

```landin
-- [0010] Line comment, to end of line.
```

### [0020] Block comments, which nest

`--(` opens a block comment and `)--` closes it. A block comment may sit
between two tokens on one line.

```landin
--( [0020] Block comment. Nests properly.
    --( so this inner one is fine )--
)--
```

Because block comments nest, you can comment out a region that already
contains one.

A block comment that is never closed runs to the end of the file, and the
compiler reports it there.

### [0030] Doc comments

`---` starts a doc comment, which documents the declaration on the next
line.

```landin
--- [0030] Doc comment. Attaches to the declaration that follows.
```

A doc comment changes nothing about what the program means. Spec [2000]
says which lines count as a declaration's doc comment.

## DECLARATIONS

### [0040] Declaring a name

A declaration gives a name, a type and a value, in that order. The name
is immutable unless you say otherwise ([0060]).

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

`addr` takes an address and `.val` is the thing pointed at. [0430]
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

`public` is about modules, not the linker. A public function or datum is
still a local symbol inside the program's image, so no C library or linked
object can collide with it. To give C or the linker a name, see [1600] and
[1610].

Exact rules: spec [1975].

### [0100] Several names in one declaration

Several names may share one declaration, as fields in a struct already do.

```landin
public red, green, blue: u8
north, south, east, west: atom
```

The shared form means the same as one declaration per name, written in
the same order. Each name gets its own storage, and each gets everything
written around the list: `mut`, `public`, a parameter convention, `at` or
`from`. So in a parameter list, `inout low, high: i32` makes both
parameters `inout`.

```landin
mut low_mark, high_mark: u32 = 10 -- two variables, both start at 10
```

The fine print:

- A shared value is computed once, for the first name, and the other names
  start as copies of it: `mut low, high: u32 = next_seed()` calls
  `next_seed` once.
- The shared form needs a written type, because `low, high := bounds()`
  reads as taking apart a multiple result ([0990]).
- These take one name each: type declarations, functions, type and fixed
  formals, variant parts and condition bindings.

### [0110] The name is always on the left

Left of `:` is always the name being introduced. Right of `:` is what
fills it: a type, or, with `=`, a value.

In a local declaration, the written type and the value both see only the
names visible before the declaration. If an outer `t` names a type,
`mut t: t = value` uses that type and then introduces the local `t`, and
the statements after it see the local. A binding in a condition follows
the same rule ([1070]).

Module declarations and function signatures see all their names at once
([0130], [1290]).

Control words are reserved everywhere a name could go (spec [1760]).
`begin`, `match`, `loop`, `break` and `unchecked` cannot be variables,
parameters, fields or labels, so `begin = 10` is an error. Call it
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

128-bit integers are not in Landin yet. They are planned, for when a
program needs them (Language evolution, in [the roadmap](ROADMAP.md)).

Odd widths such as `u4` or `u12` exist only as fields of packed register
images ([0730]):

- Reading one gives you the next ordinary width up, so a `u1` field reads
  as a `u8` holding 0 or 1.
- A one-bit flag is spelt `bool`, and a `u1` does not convert to or from
  `bool` on its own.

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
a float, nor a float an integer.

```landin
ratio: f32 = 5.0
-- bad: f32 = 5     is a compile error
half := 1.0 / 2.0 -- 0.5
zero := 1 / 2 -- 0, integer division
```

When nothing says what type a float literal should be, it is an `f32`.

### [0220] Bases, separators and exponents

Integers may be written in hex, binary or octal, and long numbers may use
`_` to group digits. A float may carry an exponent.

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

A character literal is one Unicode scalar, and its type is `u32`.

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
| `\u{...}` | one Unicode scalar, any number of hex digits |

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

Every line end between the quotes is part of the text. That includes the
one just after the opening quotes and the one before a closer on its own
line, so `help` begins and ends with a line end:
`"\nusage: tool [options]\n  -v    verbose\n"`.

For text that should start with its first line, as expected output usually
should, start it on the opener's line. Nothing is stripped from that line,
and the closer's indentation is still stripped from the lines after it.

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
the value, like a call.

- If the value is known at compile time, an impossible conversion is a
  compile error; otherwise it traps at run time.
- A float converts to an integer by truncating toward zero.
- An integer converts to a float by rounding, and that never traps.

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
- A converted reference still refers to the same storage, and keeps its
  origin: where that storage lives, and so how long ([0770]).
- `ptr u8(value)` applies the type `ptr u8`: it can take the pointer out of
  a distinct type ([0650]), but it never turns an integer into a pointer.
  `ptr(address)` does that, taking its pointer type from the declaration
  ([0460]).
- A conversion does not say what type a float literal is, so the literal
  is an `f32` ([0210]). `u64(1.0e18)` would truncate the `f32` nearest
  10^18, which is 999,999,984,306,749,440, so the compiler refuses it;
  write `u64(f64(1.0e18))` for the number written. `i64(45.7)` gives 45 at
  either width and is converted as it stands.

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
  a call returns.
- A call whose result is measured runs. The elements of a measured literal,
  like the `roll_die()` calls above, are checked to have one scalar type
  but not evaluated.
- An array that a name or path reaches is not read, because its type holds
  its length.
- `offsetof` gives a field's offset in bytes from the start of its struct
  type, through nested structs.
- `lenof` and `offsetof` are not reserved: everywhere else, they are
  ordinary names.

### [0380] `addr` and `.val`

`addr` takes an address, and `.val` is the thing a pointer points at. On
the right of an assignment `.val` reads it, and on the left `.val` writes
it. [0430] shows both.

### [0390] Assignment is a statement

Assignment is a statement, never an expression, so it cannot hide inside a
condition.

The assignment operators are `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`,
`^=`, `<<=` and `>>=`, plus the wrapping `+%=`, `-%=` and `*%=` ([0300]).

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
keyword. In every function, `=` opens the body and `end` closes it.

```landin
double: (x: i32) -> (r: i32) =
    r = x * 2
end double
```

Results have names, as parameters do. The body sets `r` by assigning it, and
the caller gets whatever `r` holds when the body ends.

### [0880] One-line functions

When the body is a single expression, write that expression after `=`. Its
value fills the named result. The function still takes an `end`.

```landin
triple_it: (x: i32) -> (r: i32) = x * 3 end
```

### [0980] Calling: positional, then named

A call gives its positional arguments first and its named arguments after
them. Every parameter gets exactly one argument: there are no default
values.

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

The positional arguments fill parameters in order. The named ones may come
in any order after them. An unknown or repeated name is an error.

Arguments are evaluated in the order you wrote them. Named arguments work in
a call statement as well as in a call expression.

The fine print:

- A call through a stored function uses the parameter names of that value's
  type. Those names are not part of function-type identity ([1000]).
- A generic call may name its compile-time arguments in the same list:
  `copy(t: u8, n: 4, source: bytes)`. Name one and you name them all
  ([1290]).
- A C variadic call adds an unnamed tail ([1580]). It does not add optional
  parameters.

### [0890] Returning nothing, and never returning

`none` means the function returns normally with no value. `noreturn` means
it never returns at all.

```landin
log_it: (m: utf8) -> none = end log_it
halt_it: () -> noreturn = loop do end loop end halt_it
```

The body of a `noreturn` function has to diverge on every reachable path:
an unconditional `loop` with no exit, or a call to another `noreturn`
function. A conditional loop does not count, even if you expect it to run
forever.

A call to a `noreturn` function ends the path it is on, so a branch that
calls `halt_it()` needs no value of its own.

The fine print:

- `noreturn` is part of the function's type. A `() -> none` function cannot
  stand in for a `() -> noreturn` one, and a `() -> noreturn` function
  cannot stand in for a `() -> none` one.
- A `noreturn` function declares no errors ([0940]), because failing would
  return to the caller.
- Calling a `noreturn` function does not unwind `defer` ([1100]). A deferred
  `noreturn` call stops the cleanup that would follow it, and the original
  exit.
- C declarations may use `noreturn`. Interrupt and naked handlers stay
  `() -> none`.

### [0920] Several results

A function can return several named results.

```landin
divide: (a: i32, b: i32) -> (quot: i32, rem: i32) =
    quot = a / b
    rem = a % b
end divide
```

Two or more results travel together as one anonymous struct, laid out in the
order you wrote them. A single result is its own type, with no struct around
it.

### [0930] Every result is assigned before returning

A function must assign each named result on every path that returns. The
compiler checks this, so there is no "uninitialised return value".

A path that fails ([0940]) need not assign the results, and the caller
cannot read them on that path.

### [0990] Using a multiple result

The results of a call form an anonymous struct ([0920]). Bind it whole and
read its fields, or take it apart by name. You never take it apart by
position.

```landin
whole := divide(10, 3)
sum := whole.quot + whole.rem
(quot, rem) := divide(10, 3)
(quot: q2) := divide(20, 3)
(quot, _) := divide(30, 3)
```

The call runs once. When you take the result apart, you can pick names in
any order, leave some out, or rename one after `:`. `_` says that you ignore
the rest on purpose.

A whole result can also be the value of an `if`, `match` or block when every
branch gives the same names and types.

The names belong to the call, not to the function's type. Two function types
with the same result types in the same order agree, whatever the results are
called ([1000]).

### [1020] Throwing a result away

You cannot ignore a result silently. To throw one away, say so with `_ =`.

```landin
_ = double(5)
```

A function that returns `none` gives the caller nothing to discard. Write
its call on its own: `_ =` in front of it is an error (spec [1930]).

### [0900] Three parameter conventions

A convention says what the function may do with the value you hand it. It is
about the argument itself, never about what the argument points at: the
pointer type says that ([0450]).

| convention | what it promises |
| --- | --- |
| `in` | I will not change the value. The default, unmarked. |
| `inout` | I may replace it, and the change comes back to the caller. The argument must be mutable. |
| `sink` | I consume it. The place the caller named is dead afterwards ([0910]). |

There is no `out` convention: outputs are named results.

In this example, `[]u8` is a slice of bytes, a view of someone else's bytes
([0570]):

```landin
process: (source: []u8, inout target: []u8, sink owned: []u8)
         -> (written: u32) =
    written = 0
end process
```

Because a convention is about the argument itself, a function that writes
device registers through a pointer, but never re-points it, takes the
pointer as `in`. The `mut` lives in the pointer type ([0430]).

`escaping` is a separate word that can go with any of the three conventions.
It says that the function may keep what a pointer, slice or `any` refers to
after the call returns, so the caller has to show that it lives long enough
([0780]).

`sink` and `escaping` do different jobs: `sink` makes the caller's place
unusable afterwards, and `escaping` lets the callee keep a reference. The
two can go together. On a type parameter, `escaping` asks nothing when the
type holds no references ([0840]).

The fine print:

- An `inout` argument need not be a binding: a pointer target such as
  `c.inner.val` is fine.
- One call may not pass the same variable, or a field of it, to two `inout`
  parameters.
- Two different pointer or computed-index paths may still alias. The
  compiler cannot see that, and does not promise to ([1720]).

### [0910] `sink` consumes a place

A `sink` argument is a place. After the call, that place is dead until you
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

Reading `m.body` between those two lines is an error. The check closes the
window between releasing storage and repointing the field, which a temporary
binding would have left open.

This is a use-after-consume check on one place, not ownership. The value is
still copyable: a copy made before the sink stays live, and the compiler
does not catch consuming through both.

The fine print:

- The place is a path from a binding through fields and literal fixed-array
  indexes. The compiler refuses a path through a pointer (`p.val.items`), a
  computed index (`xs[i].items`) or a slice index. A whole slice may be
  sunk.
- A field sunk out of an `inout` parameter must be assigned again before
  every return, failure included. A `defer` or `undo` may do it.
- Arguments are evaluated left to right first, and the places are consumed
  as the call begins. So `use(value, value.count)` is fine when `use` sinks
  its first parameter.
- The compiler refuses a call that sinks one place twice, or that sinks a
  place it also passes `inout`.

Exact rules: spec [1910].

### [1040] Passing the call site: `caller`

The compiler fills in a `caller` parameter with where the call was written,
so assertions and logging need no macros. The parameter's type is a struct
you declare, with exactly these three `u32` fields, in this order:

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

A call looks like this: `assert(count > 0)`. The caller leaves the parameter
out.

Inside the function, the parameter is an ordinary immutable struct that you
can read, copy and store. It is 12 bytes on every target. Line and column
count from one.

The file number is only a number. The table that maps it to a filename is
written beside the program and need not ship with it, which keeps names out
of firmware ([1670]).

A wrapper that wants to report its own caller's position passes its `caller`
parameter on by name:

```landin
checked: (cond: bool, caller where: site) -> none =
    assert(cond, where: where)
end checked
```

Leave out `where:` there and the report points at the wrapper's own call
instead. Only a `caller` parameter can fill a `caller` position: a copied or
constructed `site` cannot.

A check that stops the program gives its `caller` parameter to
`compiler.unreachable` ([1560]). The stop is then reported at the call,
through any wrappers that passed the parameter on, and not at the check:

```landin
require: (cond: bool, caller where: site) -> none =
    if not cond then compiler.unreachable(where) end if
end require
```

This `site` is not the `site` that a panic handler receives at [1670]. That
one is a single `u32` number, which the compiler gives a failing check.

Exact rules: spec [1920].

### [1000] Functions are values

A function type is an ordinary type, written the way a signature is. A
function is a value of that type: a code address. There is no separate
function-pointer type, and you never write `addr` on a function.

```landin
default_handler: () -> none = end default_handler
handler: type = () -> none
mut current: handler = default_handler
```

Two function types agree by their parameter and result types, in order:

- The names inside them only describe the positions.
- The comparison is recursive when a parameter or result is itself a
  function.
- Calling convention and variadicness count too. A C callback type is
  written `extern(c) (parameters) -> returns`, and a Landin function never
  matches it.

A module binding set to a named or anonymous function is a fixed code
address. A mutable binding may later take any function with the same
complete signature. A `ptr` to a function type points at a cell that holds
the address, not at the code.

A function captures nothing ([1010]), so a callback is a function and an
explicit state pointer:

```landin
on_byte: type = struct
    call: (state: ptr u8, b: u8) -> none
    state: ptr u8
end on_byte
```

Call it through the field: `callback.call(callback.state, byte)`. The field
keeps its full signature through every copy, assignment, variant payload and
array. Whether the field may be replaced depends on the binding that holds
the struct. The callee is evaluated before the arguments.

### [1010] Anonymous functions

An anonymous function is a signature and body without a name. It captures
nothing: inside, it sees module declarations and its own parameters, results
and locals, but none of the enclosing function's.

```landin
less_i32 := (a: i32, b: i32) -> (yes: bool) = a < b end
```

Writing an anonymous function makes a fixed code address; it does not run
the body. State travels as an explicit parameter, as in the callback at
[1000].

A bound anonymous function is a value. `less_i32(1, 2)` calls it, and you
can pass it wherever its function type is expected. It cannot supply a
concept's entry ([1240]).

## TYPES YOU DECLARE

This section covers atoms, structs, variants, and types made from other
types. Device register images are also types you declare; they are with the
machine-level material at [0730] and [0740].

### [0630] Atoms

An atom is a name that is its own value and its own type. Declaring one
gives you both at once, because for an atom the value and the type are the
same thing.

```landin
not_found: atom
no_access: atom
```

Atoms compare with `==` and `<>`, and nothing else. Two atoms are equal when
they are the same declaration, even when the values come from two different
atom sets:

```landin
is_missing: (outcome: not_found | no_access) -> (missing: bool) =
    missing = outcome == not_found
end is_missing
```

As far as your program can tell, an atom has no number behind it: it is not
ordered, and it does not convert to or from an integer.

### [0640] Enumerations are unions of atoms

An enumeration is a union of atoms. The atoms `north`, `south`, `east` and
`west` were declared at [0100].

```landin
compass: type = north | south | east | west
```

You may also write the union in place, as the type of a binding, a
parameter, a return or a field. It is then the same type as the declared
name: `facing: (way: north | south) -> (ahead: bool)` takes a `compass`
value that is north or south. As the element of an array, a slice or a
pointer, the union needs its name.

An atom set can be an array element, a struct field or a variant payload,
and it stays that set there. A write needs one of its members, and reading
it back gives you an atom, not an integer.

### [0650] Distinct types

`distinct` makes a new type that has its base's representation and never
mixes with its base or any other type. Comparison comes along, and so do the
bit operations of an unsigned base. Arithmetic does not.

```landin
meter: type = distinct f32
second: type = distinct f32
```

You cannot add a `meter` to a `second`. You cannot even add two `meter`
values, because `f32`'s arithmetic stays with `f32`. To get a value in or
out, apply the type, as for any conversion ([0700]):

```landin
length: meter = meter(2.5)
raw: f32 = f32(length)
```

That separation is the whole point: the compiler keeps the type apart from
its base and from every other distinct type, at no runtime cost. Generic
deduction and conformances tell it apart too, and an alias of it keeps its
identity.

A few things do carry over, because they ask nothing of what the value
means:

- Equality. `==` and `<>` work when the base has them: a scalar, an atom
  set, a pointer or a function value. A descriptor compares without taking
  its number out.
- Ordering, when the base is a scalar. `<`, `<=`, `>` and `>=` order as the
  base does.
- Flags, when the base is an unsigned integer. `&`, `^`, `|` and `~` give
  the same distinct type, and `&=`, `^=` and `|=` update in place, so a set
  of flags stays one.
- The zero image. A record that holds a distinct value may be `zeroed`
  ([0540]), though `zeroed` written for the distinct type itself does not
  construct it.

```landin
farther: (a: meter, b: meter) -> (yes: bool) =
    yes = a > b
end farther
```

The fine print:

- Shifts stay with the base, as arithmetic does.
- A distinct value meets its base or any other type only through a
  conversion, and that includes comparing with it.
- A wrapped reference keeps its origin.

Exact rules: spec [1890].

### [0660] Range subtypes

A range subtype is an integer type limited to a run of its values. The range
is checked when a value goes in.

```landin
percent: type = u8 range 0..100
```

The check happens at a binding, a parameter, a named return and a
conversion. When a value is outside the range, the compiler refuses it if it
knows, and the program traps if it does not. Arithmetic on a `percent` gives
a plain `u8`: the range is not part of the result.

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
forms mean the same thing. The inline form is also how parameter lists,
return lists and payloads are written.

```landin
size2: type = (w: u32, h: u32)
```

A struct is nominal in either form: two separately declared structs with the
same fields are different types. An alias keeps the original identity.

The fine print:

- Either form may take type and fixed parameters, and `layout` ([0750])
  applies to either. The parameters are compile-time names: they add no
  field and no hidden runtime argument.
- Each fully applied instance of a parameterized struct is its own type. The
  declaration and all its arguments identify it, even an argument the fields
  do not use. Aliases of the arguments make no new type. A different
  argument does, even when the fields and layout come out equal.
- A struct may mention itself, or another struct that mentions it back, in a
  function parameter or result. A function field is one code address, so the
  layout stays finite.

### [0680] Structs with a variant part

A struct may end in a variant part: one of several cases, each with its own
fields. The fields that every case shares are ordinary fields of the struct.

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

Selecting a case costs the size of that case, not the size of the largest
one, because of what it writes:

- Selecting a bare case writes only its tag.
- Selecting a case with fields zeros that case's fields first, then writes
  the ones you gave.
- The bytes of the inactive cases and the padding are unspecified
  afterwards, though `zeroed` still writes the whole struct as zeros.

### [0700] Constructing values and converting them

Construction and conversion look the same: a type applied to arguments.

```landin
origin := point(x: 0.0, y: 0.0)
metres := meter(1.5)
```

A variant case is built the same way, with the case name applied to its
fields. To read a case back, use `match` ([1210]).

```landin
mut f: figure = (label: "disc", area: 0.0, kind: circle(radius: 2.0))
f.kind = rectangle(width: 3.0, height: 4.0)
```

### [0710] Struct literals take their type from context

A struct literal has no type of its own, like a number literal. It takes the
named struct type that its context wants. A struct type written inline is
not yet such a context: declare the type and use its name (spec [1830]).

```landin
here: point = (x: 1.0, y: 2.0)
```

What does not convert is a value that already has an anonymous struct type,
such as a call's results. `divide(10, 3)` gives `(quot: i32, rem: i32)`, and
that value never becomes a named struct with the same fields. Two anonymous
types match when their field names, types and order all match.

At module scope, a struct literal is a static image that the compiler
builds, not code run before the entry point ([1460]).

Exact rules: spec [1940].

### [0720] Filling the remaining fields with `of`

`of` at the end of a struct literal fills every field that the literal did
not name. It is the same word in the same place as in array literals
([0560]).

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
image.

This is not a default value. Declarations have none ([0980]), because a new
parameter would then fit every existing call silently. Here whoever writes
the literal makes the choice. The trade is theirs too: a literal with `of`
picks up a field added later without a word, and one without it breaks
loudly.

The fine print:

- A fill other than `zeroed` needs at least one omitted field, and all of
  the omitted fields must then have exactly the same type, array length and
  reference permission included.
- The fill is evaluated once, after the named values, and copied into each
  remaining field in declaration order.

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

You ask for another layout by name:

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
([0320]) or an ordinary function, as `from_big_u16` does above. That way the
cost is visible where it is paid.

The fine print:

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
- Every byte count comes from the selected target, 32-bit targets included.
  Initializers still run in the order you wrote them ([0410]).

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
| `link` | `symbol: "..."`, `thread`, `section: "..."`, `region: "..."`, `align: 16`, `vector: 16`, `keep`, `boot_stage` | [1610], [1615], [1640] |
| `extern` | `c`, `interrupt`, `naked`, and others | [1570] |

`at` gives a field its bit position ([0730]). `at`, `of` and `align` are
contextual: a field or an entry may still be called one of them, because
nothing reads the word as an attribute there. Placement alignment is
`link`'s `align` label ([1640]), not a word of its own. `from` and `with`
are reserved and cannot name anything.

Landin has none of these attributes:

- `volatile`: a device access is an operation ([0740]).
- `big` or `little`: byte order is converted where bytes cross ([0750]).
- `inline` or `noinline`: inlining is the optimizer's decision ([1310]).
- `weak`: a whole program links one definition per name, and the
  compiler-owned vector image does what weak default handlers do in C
  ([1640]).

## CONTROL FLOW

Every construct opens with its own word and closes with `end`, so you never
count braces.

The short snippets in this section are statements. Read them as standing
inside a function that has a parameter `x: i32`, a writable slice
`items: []mut i32`, a path `path: utf8` and a result `out: i32`. Helpers
such as `is_ready()`, `expensive()` or `cleanup()` stand for functions that
do what their names say.

### [1050] Branching with `if`

`if` takes a condition, and `then` begins the body. `elsif` and `else` are
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

The condition has type `bool`. No integer or pointer stands in for a
`bool`.

### [1060] Every construct fits on one line

No construct needs a newline. `end` is what closes a construct, so you can
write any of them on one line.

```landin
    if x > 0 then out = 1 end if
```

`refine fmt` leaves a one-line form on one line. It never joins lines and
never breaks them.

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

- The name exists only in the body that its condition guards. It does not
  exist in a later `elsif`, in the `else`, in a loop's `complete`, or after
  the construct.
- The initializer runs before the name exists, so it cannot refer to the
  name it initializes.
- A `while` runs the initializer again before every iteration.

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
does not: you always write `_ =` to throw a value away ([1020]), so a bare
expression at the end of a block can only be its value.

The details, arm by arm:

- Every arm that falls through must end with a value of one complete type
  and shape. An `if` used as a value therefore needs its `else`.
- An arm that leaves by `return`, `fail`, `break` or `continue` supplies no
  value and needs no placeholder.
- When the compiler decides whether a name is assigned after the
  construct, only the arms that fall through count. An arm that has left
  proves nothing for the others.
- Statements and the final expression run in source order. They run after
  the `if` condition or the `match` subject, and only in the selected arm.
- In a construct used as a statement, an arm may not end with a value:
  nothing would take it.

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

Give the block a label, `name: begin ... end name`, and a `break name` can
leave it early. Its cleanups then run as a loop's do ([1180]).

### [0940] Errors: what can fail is in the signature

A function that can fail lists, after `!`, the atoms it can fail with, and
`fail` leaves with one of them. An atom is a declared name that is its own
value, such as `port_zero: atom` ([0630]). A caller cannot ignore a failure:
at every call to a failing function, it either passes the failure on or
handles it.

Here is all of it at once. `port_from` reads a port number with the
library's `text.to_u32`, which fails on bad digits, and adds a failure of
its own. Its two callers then deal with the result in different ways:

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

A call to something that can fail takes one of four forms:

| you write | when the call fails |
|---|---|
| `try f()` | your function fails with the same atom |
| `f() else value` | `value` stands in for the result |
| `f() else (e) ... end` | the block runs with the atom bound to `e` |
| `f() else none` | nothing; the next statement runs |

The next entries use a shorter declaration. Its atoms, `not_found` and
`no_access`, are the ones declared at [0630]:

```landin
open_file: (path: utf8) -> (handle: u32) ! not_found | no_access =
    fail no_access when lenof path == 0
    handle = 1
end open_file
```

Three facts about error sets and their atoms:

- An error set is a set. Aliases flatten, order does not matter, and a
  function that fails with `a` passes where `a | b` is expected.
- The atoms carry no payload.
- The atoms travel in a register of their own, so failing costs about what
  returning does.

Exact rules: spec [1980].

### [0960] Passing a failure on: `try`

`try f()` calls `f`. If `f` fails, your function runs its cleanups ([1100])
and then fails with the same atom. Every atom you might pass on must be in
your own `!` set.

```landin
read_config: (path: utf8) -> (data: []u8) ! ... =
    h := try open_file(path)
    data = []
end read_config
```

The `try` sits at the call, so you can see in the source every place a
function may leave early.

`! ...` means "whatever my callees can fail with": the compiler works the
set out from every `fail` and `try` in the body. An inferred set that comes
out empty means the function cannot fail.

Use `! ...` inside a module, where the compiler sees every caller anyway.
These must write their set out:

- Anything public, because a public signature is a promise, and a change
  three modules down must not rewrite it silently.
- Function types, anonymous functions, concept entries ([1260]) and
  anything exported to C, because their complete signature is their type.

`try for item in source do ... end for` passes on a failure from any
traversal step ([1150]). The enclosing function must declare or infer the
atoms, and its caller handles them with the ordinary `else` on that call.

Exact rules: spec [1980].

### [1030] Handling a failure: `else`

An `else` after a call handles its failure on the spot. The handler either
supplies a value in place of the result, or leaves. Leaving is `return`,
`fail`, `break` or `continue`, written in a block, as
`else begin return end`.

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

`try f()` is short for the second line's form. A handler that leaves needs
no value, the same rule an arm of an `if` follows ([1080]), so nobody
invents a placeholder to satisfy the type. The handler supplies the value;
it does not assign the binding being initialized.

- `else (e)` binds the atom. `e` has the call's whole error set and exists
  only inside the block. A `match` on it must cover every atom, or end
  with one `_` arm for the rest ([1210]).
- A name the block never reads draws a warning. To run statements
  without naming the atom at all, give `else` a bare block as its value:
  `else begin ... end`.
  The compiler refuses `else (_)`; leave the parentheses out instead.
- A call that returns nothing has no value to supply. Its block only
  handles the error, and the statement after the call runs next.
- The result may have any shape, from a scalar to a struct or several
  named results.

A failing call needs `try` or `else` even when you throw its result away.
`else` handles only declared failure: a result that is a union, such as
[0480]'s maybe-pointer, is taken apart with `match`.

Inside an `if` arm, `else value` after a call is the `if`'s own `else`,
which is how `if c then a() else b() end if` reads. To handle the call's
failure there, parenthesize it, `(open_file(path) else 0)`, or bind the
error: `else (e)` always belongs to the call, wherever it is written.

A handled call is an expression, so it also works inside a larger one, as
an operand or an argument:

```landin
next_handle := (open_file(path) else 0) + 1
```

When a call returns nothing and its failure does not matter where the call
is made, one word says so. Here `flush` writes out a buffer and returns
nothing:

```landin
flush(out) else none
```

`else none` is the bound block with nothing in it, minus the name nobody
would read: what the call did before it failed stays done, and the next
statement runs.

On a call that returns a value, `else none` is allowed only when the whole
call is discarded with `_ =`. Anywhere else, a failure would leave a result
unset that something reads. Here `parse_header` returns a value:

```landin
_ = parse_header(input) else none
```

Used any other way, that call needs `else value`, a block, or `try`.

### [0970] Leaving early: `return` and `fail`

`return` leaves the function with its named results as they stand, and
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
ordinary parameter. The library's destination for diagnostics is the
concept `core/diag.log`. A function takes it as `inout log: any diag.log`,
meaning any kind of log at all ([1370]). Its `note` entry takes a position
in the text, a severity and the message bytes.

Recording a note is a diagnostic; failing to record it is an operation
failure. So `note` declares `io.io_failed`, and a function that records
notes lists it too.

- A bounded logger never fails. When it is full it stops keeping entries,
  counts them in `dropped`, and still records whether an error was
  reported.
- A streaming logger writes as it goes, and fails with `io_failed` when a
  write does.
- Both pass as `any diag.log`, so the producer does not know which policy
  its caller chose. The sink is a capability ([1680]): passing one makes
  the destination explicit, though the parameter list alone does not
  prove that the function cannot make another sink or reach the host.

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

- At exit, the callee is evaluated first, including a function field, then
  the arguments, reading the places they name at that moment. So a `defer`
  that sinks something sinks it at the end, and the thing stays usable in
  between. If a place was re-pointed meanwhile, the `defer` sees what is
  there now.
- Registering an entry evaluates nothing, costs nothing and reserves
  nothing.
- An entry counts only once control has reached it. A `return` above the
  `defer` does not run it.
- The block's value, or its failure atom, is settled before the deferred
  calls run.
- A trap stops the program and runs no cleanup.

### [1110] Cleanup only on failure: `undo`

`undo call` is a `defer` that runs only when a declared failure leaves its
block: a `fail`, a `try` that passes a failure on, or a failure arriving
from a deeper call.

```landin
    undo release(handle)
```

It is its own word, not a flavour of `defer`: to defer is to do it later,
and this may never be done at all. It is a compensating action.

- Falling off the end, a successful `return` and `break` skip it. So does a
  trap: it stops the program and unwinds nothing.
- A caller's `else` that handles the failure does not leave the caller's
  block, so the caller's `undo` entries do not run. The failing callee's
  own entries have already run on the way out.
- In one block, `defer` and `undo` entries share one order: on failure they
  run interleaved, in reverse order of writing, inner blocks first.
- Like `defer`, an `undo` evaluates its callee and arguments only when it
  runs, and sees their values then.

### [1200] Cleaning up several acquisitions

An entry exists only once control reaches it. A run of fallible
acquisitions therefore cleans up exactly what it got: if the first fails,
nothing is released; if the second fails, one is; if the third fails, two
are.

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
the flag and you free storage that is still in use. Under an arena, where
freeing does nothing, that mistake stays silent until the same code runs on
a real allocator.

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

- A range's bounds are evaluated once, left to right. A lower bound above
  the upper one runs no iteration.
- A typed bound gives its type to an untyped one, and two untyped bounds
  are `i32`. So `0..<lenof items` counts in `usize` with no conversion.
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
through the function's error set ([0960]). It runs `defer` and `undo` on the
way and skips `complete`. `break` and `continue` work as usual.

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

- The cursor and item keep their exact declared types. An `any C` item is
  still an `any C`: it carries its evidence ([1690]), which is its type's
  table of C's entries. An `any C` source is handed as it is to its
  `iterable` entries. Neither is treated as a slice.
- When the element is a fixed array, slice or `any C`, replacing the whole
  element follows the same rule. Writing through an inner slice follows
  that slice's own `mut`.

### [1170] When a loop runs out: `complete`

A `complete` block runs when the loop ends because its source or condition
ran out. It does not run when a `break` left the loop.

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
`break` and `continue` may name one. An unlabelled `break` or `continue`
means the innermost loop.

```landin
    outer: for a in items do
        for b in items do
            break outer when a == b
        end for
    end outer
```

A `break` naming a bare block leaves it, and whatever loops it crosses,
running their cleanups on the way out.

```landin
    search: begin
        for item in items do
            break search when item == 0
        end for
        out = 1 -- no item was zero
    end search
```

A bare block has no next iteration and yields no value. So `continue` can
target only a loop, and only a loop can produce a value through
`break with`.

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

`with` is required because a bare name after `break` could be either a
label or a value.

- Every `break` of a loop used as a value carries `with`, and all of them
  yield the same type.
- A loop that can run out needs a `complete` that supplies the value.
  `loop do` needs none, having no other way out.
- A loop whose value is unwanted is discarded explicitly ([1020]):
  `_ = loop do break with 1 end loop`. A statement loop uses plain `break`
  and cannot silently drop a `with` value.

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
- `_` is an arm of its own and covers whatever is left of an atom set or a
  pointer union. On an atom set, `_ (rest):` binds the remaining atoms as a
  set of their own, so they can be passed on where only those are wanted.
- A variant part takes no `_`: its match names every case, and the cases
  that share what an arm runs are listed on that arm.
- A number has no identity to name, so you compare it with `if` and
  `elsif` instead of matching it.

### [1220] Writing into a matched payload

A pattern binding takes a parameter convention ([0900]). It is `in` by
default; `inout` writes into the payload that was matched.

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
`mut` allows it, and never replaces the slice.

A plain binding reads the payload in place, without copying it; `inout`
adds permission to write it, where the matched value may itself be
written: `s` above is an `inout` parameter. On a pointer union's `ptr` arm,
`ptr (sink p):` passes the pointer on to a `sink` parameter ([0910]), which
consumes the matched place.

`describe` matches the `compass` of [0640], two directions in one arm:

```landin
describe: (c: compass) -> (name: utf8) =
    match c
        north, south: name = "along"
        _: name = "across"
    end match
end describe
```

The rules for the bindings:

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

Two things stay:

- Everything the compiler decides at compile time: types, definite
  assignment, permissions, origins.
- The checks whose absence would not mean the same thing on every machine:
  a zero divisor, a negative shift count, a conversion to `bool` or from a
  float, a text boundary, and converting an integer that is zero at the
  target's width into a pointer.

A region reaches only the code written inside it. A function called from it
is checked as that function is written. A deferred call is checked where you
wrote it, not where the exit that runs it stands.

## ARRAYS, SLICES AND TEXT

Three kinds of value do most of what other languages use pointers for:

- An array holds its elements inline and is copied like any other value.
- A slice is a view of someone else's elements: a pointer and a length.
- Text is a view with a promise about its encoding.

Storage that has to outlive a function comes from an allocator you pass in;
[1360] shows how.

### [0520] Arrays are values

`[n]t` is `n` elements of type `t`, stored inline. Assignment copies the
whole array. The length is part of the type, so `[4]f32` and `[8]f32` are
different types.

```landin
grid: [4]f32 = [1.0, 2.0, 3.0, 4.0]
mut next: [4]f32
next = [grid[0], grid[1], grid[2], grid[3]]
```

**Assigning a literal.** Assigning a literal to an existing array, as
`next = [...]` does, fills the array in place, in written order. Each
element is evaluated and stored before the next one starts, and no hidden
temporary copy is made. Two things follow: a later element sees an earlier
write, and a failure part-way leaves the written prefix changed. The
repeated forms of [0560] fill in the same order.

**The length.** The length must be a constant the compiler works out without
running anything. You may write:

- integer literals;
- fixed parameters ([1520]);
- compiler facts such as `compiler.word_size` [1500];
- `sizeof` or `alignof` of a built-in scalar type, such as `sizeof usize`;
- immutable module integers;
- parentheses, unary `-` and plain `+`, `-`, `*`, `/` and `%` to combine
  them.

Calls, wrapping operators, bitwise operators, shifts and measurements of
your own types are not allowed.

A fact and a scalar's size and alignment are the selected target's, so
`[sizeof usize]u8` is `[8]u8` on a 64-bit target and `[4]u8` on Cortex-M0.
A module integer
counts only when its own value is such a constant. A `mut` one never counts,
because the program may write it. With `path_max: usize = 4096`,
`[path_max]u8` is the same type as `[4096]u8`.

Fine print:

- The compiler refuses a negative length. A length of zero is fine and gives
  a zero-length array, but there is no empty array literal, and the repeated
  forms of [0560] cannot fill a zero-length array.
- An index is a `usize`, and the array's size in bytes must fit the target's
  `usize`.
- A computed index is evaluated and bounds-checked once, before the element
  is used. Indexing exposes no pointer and does not change how arrays are
  copied.
- An array keeps its complete element type, permissions included, through a
  pointer, a slice, a generic call or a stored field. An `any C` element
  keeps its own data and its evidence for `C`.

### [0530] Letting the literal set the length

With `:=`, the literal supplies both the length and the element type.

```landin
triple := [1.0, 2.0, 3.0] -- [3]f32
```

The first element decides the element type, whether it is a number, a slice,
a pointer or a struct. Every later element must have that type.

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

There are three forms. They differ in where the length comes from:

| form | where the length comes from |
|---|---|
| `[n of v]` | the count `n`; it can also infer a local or module binding's type |
| `[of v]` | the destination's written type |
| `[e1, ..., ek, of v]` | the destination's written type, with `1 <= k < N` |

`v` is evaluated once, not once per element. The last form is the mixed
form: it writes the prefix left to right, then evaluates `v` once and fills
the rest.

An assignment to an existing array may use any of the three forms:

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

- The mixed form needs one of three destinations: an explicitly typed local
  or module binding, an assignment to a mutable fixed array, or a
  fixed-array argument of the same length, which it fills. It cannot be
  inferred, nested or returned. At module level every element must be a
  compile-time known scalar [1460].
- An inferred `[n of v]` takes `v`'s scalar type, and an untyped integer
  becomes `i32`. Its size must fit the target's `usize`.
- Refused: `row := [of 0]`, which has no length to give, and a zero count or
  a zero-length destination.
- `of` is a contextual word: if `of` names a binding, `[of, other, of]` and
  `[of + 1]` are ordinary literals.

### [0540] `zeroed`: the all-zero value

`zeroed` is the value of a type whose bits are all zero.

In this example `point` is [0120]'s struct and `compass` [0640]'s
enumeration:

```landin
mut buffer: [256]u8 = zeroed
buffer = zeroed -- clear the existing array as a whole
corner: point = zeroed -- fine: both fields are floats
-- facing_now: compass = zeroed -- error, write 'north'
-- p: ptr u32 = zeroed -- error, no zero image
```

Two separate questions decide where you may write `zeroed`.

**Does the type have a zero image?** It does when all-zero bits are a valid
value of it. That is what lets a surrounding struct or array be zeroed.
Pointers and `any` have none, because there is no null ([0480]), and neither
does a function address. A struct or an active variant payload that contains
a function address must spell that field out instead of using whole or
trailing `zeroed`.

**Does the type accept the word?** Only when its zero has one obvious
reading:

- Numbers, `bool`, ranges that contain zero, and aggregates of those accept
  it.
- Named value sets do not: write the name.
- A distinct type [0650] has its base's zero image, so a record holding one
  zeroes fine. But an identity such as a user id has no obvious zero, so
  write `user_id(0)` rather than `zeroed` for it.

Where the destination gives the context, `zeroed` writes the complete zero
image as one value, as the assignment to `buffer` does.

A packed struct ([0730]) is a raw image, so `zeroed` is allowed even when an
encoded field's zero pattern has no name. Reading that field then traps;
copying the image keeps its bits.

Library code has a narrow cousin, `uninit`, which leaves a private array
field unwritten. It is not another spelling of `zeroed` and cannot
initialize a stand-alone array.

### [0550] Asking for a zero image: `zeroable`

`zeroable` is the concept that says a type has a zero image, the first of
[0540]'s two questions. Generic code can therefore require it. Concepts come
in [1240]; for now read one as a named property a type can have.

```landin
-- compiler-owned; a program does not repeat this declaration
zeroable: type = concept (t: type)
end zeroable
```

Only the compiler knows a type's bit patterns, so only the compiler supplies
conformances to `zeroable`, and a program cannot declare one. It is the one
concept like that. These types conform:

- the enabled scalars;
- a fixed array exactly when its element is zeroable, even at length zero;
- a struct exactly when its all-zero shape, recursively, has a zero image;
- a distinct type exactly when its base is zeroable.

Atoms, functions, pointers and slices do not. It is a closed list, not
reflection over arbitrary types.

Requiring `zeroable` is how a container that needs a filler value for
storage it has not used yet says so, instead of pretending: see `cleared` at
[1350] and the reason at [0510].

### [0570] Slices are views

A slice `[]t` is a pointer and a length. It copies nothing. `mut` inside the
type says its elements may be written.

```landin
mut cells: [4]f32 = [1.0, 2.0, 3.0, 4.0]
view: []f32 = cells[0..<2] -- read-only elements
edit: []mut f32 = cells[0..<2] -- writable, since cells is mut
```

You can pass an array straight to a slice parameter. The array lends a slice
of all its elements:

- A named array lends its own storage.
- An array literal is built in the caller's frame for the duration of the
  call, so a list of values needs no binding of its own. A literal lends
  read-only elements only, so it cannot go to a `[]mut t` parameter.

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

### [0580] The empty slice

`[]` is the empty slice. Its length is zero, and a `for` over it runs no
iteration.

It is never null. Its base is the lowest positive address aligned for the
element type: 1 for bytes and 4 for a `u32`. Indexing checks the length
first, so that base is never dereferenced.

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

The rules:

- `+`, `-`, `*`, `/` and unary `-` work on numeric arrays; `%`, `+%`, `-%`
  and `*%` on integer arrays.
- Two arrays must have the same element type and length. A scalar of the
  element type is applied to every element; an array of another length is
  not.
- Each operand is evaluated once, left to right, as a complete value before
  any element is computed. So `a += a` and other overlapping assignments see
  the old values, not their own earlier writes.
- Elements go in ascending index order under the ordinary scalar rules for
  traps, wrapping and floating point. Nothing is reassociated, so `sum_four`
  adds in order starting from positive zero.

Arrays do not compare, not even with `==` or `<>`. Whole-array equality and
per-element masks are both plausible meanings, so write the function you
mean.

The cost is visible in the type: `[4096]f32 + [4096]f32` needs a 16 KB
result and may keep copies of its operands as well. Vector instructions are
an optimisation, never needed for a correct result.

### [0600] Text: `utf8`, `utf16` and `cstring`

Landin has no single string type. It has three distinct views over plain
storage:

| type | view over | holds |
|---|---|---|
| `utf8` | `[]u8` | validated shortest-form UTF-8 |
| `utf16` | `[]u16` | UTF-16 code units |
| `cstring` | `ptr u8` | bytes up to a NUL; no length |

The three types stay distinct from each other and from their backing types
through calls, structs and generics. `lenof` on `utf8` and `utf16` counts
code units, not characters.

**Literals.** A quoted or raw literal can be any of the three, and is `utf8`
when nothing says otherwise. Every literal has one trailing zero code unit,
which slice lengths leave out. Equal literals of the same width may share
one read-only copy. A `cstring` literal is valid UTF-8; a `cstring` that
comes from C promises only readable bytes up to its first NUL, with its
encoding unchecked.

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

`compiler.utf8_unvalidated(bytes)` [1560] is for bytes a program knows are
UTF-8, because it has just checked them or wrote only whole characters. They
become `utf8` without being read again, with the same base, length and
origin. The call is allowed only inside `unchecked` [1120], and bytes that
are not UTF-8 then go unnoticed.

**Slicing.** `utf8` and `utf16` slice by range, as `word[3..3]` in [0610]
does. The result is the same text type, read-only, over the same storage.

- The `usize` bounds count bytes or UTF-16 code units, not characters.
- Both bounds must fall where a Unicode scalar starts; a bound out of range
  or inside an encoding traps.
- A half-open range may end at the length; an inclusive range takes the
  whole scalar that starts at its upper bound.
- A `cstring` has no length and cannot be sliced.

**Traversal.** `for c in text` yields each Unicode scalar as a `u32` [1320];
on a `cstring` it stops before the first NUL. Traversal declares no error,
so text from C is validated as it is decoded and malformed encoding traps,
even inside `unchecked`.

**`core/text`.** When invalid text is input to handle rather than a bug,
`text.from_bytes` and `text.from_c` validate the same way but fail with
`invalid_text` instead of trapping; call them before traversing. The module
also has exact byte equality, substring search, decimal parsing and bounded
writing into a buffer you supply. It never normalizes or silently truncates.
It allocates only in a builder made by `text.growing`, which takes an
allocator.

`core/text` counts positions as byte offsets of the opaque type
`text.position`:

- On plain `[]u8`, the functions are `first`, `at_end`, `next`, `advance`,
  `offset`, `byte` and `slice`. Reading a byte at the end fails with
  `past_end`, and a slice keeps its source's origin.
- On `utf8`, the same positions step a whole scalar with `start`, `step`,
  `done` and `width`. `find` returns where a match begins, so the text
  around it slices out by range with nothing copied.

### [0610] Indexing text by scalar or by position

Indexing a `utf8` gives the Unicode scalar there as a `u32`, the type a
character literal [0250] and a traversal [1320] already give it. The index
type picks the operation:

- a `usize` counts scalars from the start, so `word[2]` is the third one;
  the compiler finds it by scanning;
- a `core/text.position` is a byte offset, decoded directly in O(1).

```landin
word: utf8 = "\u{e9}t\u{e9}"
last := word[2] -- 233, the u32 of é, found by scanning
same := last == '\u{e9}' -- true
bytes: utf8 = word[3..3] -- é again, at byte 3: two bytes, no copy
```

A count past the end traps, and so does a position at the end or on a
continuation byte. Neither index type converts implicitly to the other.

The scalar is decoded, so it is a value, not a place: `addr word[2]` and
`word[2] = 'e'` are errors. To get its bytes, take a one-scalar range as
[0600] describes: its bounds count bytes, and the result is still `utf8`.

A `utf8` converted to `[]u8` loses scalar indexing and has the ordinary
slice operations instead.

## MODULES

### [1410] A module is a directory

Every `.ldn` file directly inside one directory belongs to one module. Those
files see each other's declarations without importing anything. Everything
is private to its module unless it is marked `public`. There is no separate
interface file.

```text
geometry/area.ldn
geometry/shapes.ldn
geometry/solid/volume.ldn
```

Here `geometry` is one module of two files, and `geometry/solid` is a second
module.

Fine print:

- The compiler reads a module's files in bytewise filename order. It ignores
  other files, and an empty directory is a legal empty module.
- Declaration order never affects what is visible. File order does fix
  identities, the order of diagnostics and the order of active
  `linker.library` directives [1590].
- An importer can name public functions, bindings, atoms, types and
  concepts. A variant case is public when its type is.
- A public declaration may mention a private one. The private identity flows
  through the public surface, but an importer cannot name it.

### [1420] Importing a module by its path

`import net/http` finds a directory `net` holding a directory `http`, under
the import roots the compiler was given. It binds the last segment, `http`,
as a namespace in this file.

```landin
import net/http
```

**Finding the module.** The compiler searches the roots in order, and the
first that has the directory wins; a later root is not merged in. From that
directory the compiler takes every source file, not recursively, and follows
their imports. A subdirectory is a module of its own, reached by its own
path. Each module is loaded once, so import cycles are legal.

**Using the namespace.** After the import, `http.get`, `http.response` and
`http.drawable` name that module's public declarations. Qualification works
wherever a value, type, type application, concept, conformance, error atom
or match case is named. The first dot after the namespace selects a public
declaration; later dots are ordinary value selections. The namespace itself
is not a value, type or place.

**Spelling the path.** A path segment is a plain identifier: lowercase
letters, digits and underscore, not starting with a digit.

- It is lowercase because a case-sensitive and a case-insensitive filesystem
  must agree on what a name is. The directory entry must have exactly that
  spelling even on a case-insensitive host.
- It is an identifier because the last segment becomes a name in your file,
  so a hyphen would need an alias every time.

The separator is always `/` in source, on every host.

### [1430] Renaming an import

`as` gives the namespace another name, for when two imports collide.

```landin
import net/http as h
```

This binds `h` only, not `http`. `as` is a contextual word, so outside an
import it is an ordinary identifier.

### [1440] Importing selected names

A parenthesized list brings named declarations into scope directly. There is
no wildcard.

```landin
import net/http (get, post)
```

This binds `get` and `post` and not the `http` namespace. The rules for the
list:

- Every selected name must exist and be public, even if the file never uses
  it.
- Each name keeps its original declaration's identity, type and mutability.
- The list is not empty and has no trailing comma or renaming.
- A selection cannot be combined with an alias.

### [1450] Imports belong to one file

Each file has its own imports, so every file reads on its own.

- Imports come first, before every declaration.
- One file's imports are not visible in its siblings and are never
  re-exported.
- Binding one name twice in a file's imports is an error, whether it is the
  same import twice or a selection colliding with an alias.

Shadowing goes like this:

- A parameter or local may shadow an import.
- A namespace import shadows a same-named module declaration only for
  qualified lookup; the module's unqualified value stays visible.
- A selected name shadows the module declaration in both.

The compiler reports selecting a private member differently from selecting
one that does not exist, and the report points at the private declaration.

### [1460] Module-level values are known at compile time

A value at module level must be known when the compiler reads it, because
nothing runs before the entry point. So it cannot call a function. Immutable
values can stay in flash; mutable ones cost RAM, and the `mut` makes them
conspicuous.

```landin
table: [4]u32 = [1, 2, 4, 8]
mut call_count: u32 = 0
```

**Arithmetic.** Integer arithmetic here is worked out in a wide range first,
and only the final value is checked against its type. So a module
`value: u8 = 200 + 100 - 100` holds 200, while the same `u8` addition inside
a function overflows and traps before the subtraction.

**Values from other modules.** A value another module exports is known in
the same way, named through that module: `limit: u32 = sizes.page * 4`,
`ready: flags.state = flags.idle`. Qualifying a name changes where it is
found, not whether it is known.

**Functions in a struct.** A module struct may hold a function. The field
names a declared function, or an anonymous one that captures nothing. What
is stored is the function's address; nothing is called. There is no all-zero
function address [0540], so such a struct must be written out in full.

Exact rules: spec [1940].

### [1470] Packages and versions

A package is a named collection of modules with a version and an origin. Its
name has two levels, owner and package, and a directory under a search root
is the package it names.

A program holds one version of each package name. Two copies of a package
would do three things:

- cost space a 32 KB part does not have;
- be different types, since types are nominal;
- put conflicting entries in the single list the whole program keeps of
  which types conform to which concepts ([1240]).

The companion tool ([1480]), once it exists, will solve versions and report
a conflict as a hard error that asks for an upgrade.

The current compiler reads no versions or origins. It takes the first
matching module directory from the ordered roots [1420], even when a later
root holds another version.

### [1480] Where modules come from: the roots

You tell the compiler where modules are. `refine` takes repeated
`--root=DIR` options and then the entry module: its directory, or its
source files, which together form one module. With no `--root` you name the
source files, and they form one module in the same way.

The roots are searched in the order you give ([1420]), and that order alone
decides: the compiler consults no home directory and adds no system root of
its own choosing.

**The library root.** The compiler does add one root: the library it ships
with, found beside its executable. `core`, `hosted` and `platform` always
come from there and from nowhere else, so a root you name cannot replace
them. Every other module is searched for in your roots, project first, so a
project can override an ordinary module by putting its own copy in its
first root. Vendoring a package is just that.

**The companion tool.** Fetching packages, solving versions, lock files and
naming authority belong to a companion tool. It will ship alongside the
compiler but stay separate from it: a compiler you can read is worth more
than one that can download things.

- Arranging the roots so that only one version of each package is reachable
  is that tool's job. So until it exists, the compiler does not enforce
  [1470]'s one-version rule.
- The intended root order is the project, then the user's Landin home, then
  a system-wide one.
- Whether a path's leading segments name an owner and a package is a
  convention for people and that tool. The compiler only sees directories.

**The compiler's namespaces.** Four source namespaces come with the
compiler:

| namespace | holds | available |
|---|---|---|
| `core` | the shared freestanding library: `core/mem`, `core/text`, `core/vec` | every module and interface on every target |
| `hosted` | hosted providers such as `hosted/heap`, `hosted/system` and `hosted/blocking` | on hosted systems |
| `platform` | interfaces scoped to a target or a system: `platform/c`, the CPU modules and the POSIX layer | each as the next table says |
| `landin` | the toolchain modules of [1560]: `landin/compiler`, `landin/assembler`, `landin/linker` | everywhere, without an import |

Within `platform`, availability goes by module:

| `platform` module | available |
|---|---|
| `platform/c` | wherever a C ABI (application binary interface) is enabled: the hosted LP64 targets and Cortex-M's AAPCS32 |
| a CPU module: `platform/cortex_m`, `platform/riscv` or `platform/xtensa` | everywhere, with its operations, submodules and reference descriptions only on its own targets: Cortex-M at any level, `rv32`, `xtensa` |
| the POSIX layer: `platform/posix` over `platform/linux`, `platform/libc` and `platform/kqueue` | on Linux, macOS and FreeBSD |
| a `platform` module the compiler gives no scope | nowhere |

Fine print:

- An import outside its target's scope is refused by name when the target is
  checked, for example `hosted/heap` in firmware.
- The POSIX layer is hosted-only and still under `platform`, not `hosted`:
  it is the system's own interface, which the `hosted` providers are written
  over, rather than a provider of its own.
- A module that declares nothing on some targets can be imported on all of
  them: a program for every target imports `platform/cortex_m` and calls it
  from a `fixed if compiler.arch == cortex_m0` arm ([1500]).
- The toolchain modules are always there, so the bare names `compiler`,
  `assembler` and `linker` cannot be declared or bound by an import, and an
  explicit `import landin/compiler` (or `assembler`, or `linker`) is refused
  by name before any root is searched.
- Otherwise the namespace names are ordinary identifiers.

## What you can write now

That is the end of the part to read in order. You can now write ordinary
programs: functions with failures, your own types, loops and matches, arrays
and text, modules, and the host's files and streams through
`hosted/blocking` and `core/io`. [`examples.md`](examples.md) has complete
programs to read and copy.

For storage whose size is known only at runtime, continue with arenas over
caller-supplied storage ([0820]) and allocation as a concept ([1360]), then
the [growable-vector example](docs/library.md#corevec). Together they show
how a collection is handed its allocator and where its storage is released.

The sections after this one are reference, to read when you need them:
[Pointers](#pointers); [Lifetime and escape](#lifetime-and-escape);
[Concepts and generic code](#concepts-and-generic-code); [Runtime
dispatch](#runtime-dispatch); [Compile time](#compile-time); [The toolchain,
C, and the machine](#the-toolchain-c-and-the-machine); and the principles,
the omissions and the open questions at the end.

## POINTERS

Most code never needs a pointer: slices, handles and indices do the everyday
work ([0490]). Pointers are for hardware, the C boundary and the inside of
libraries. When you do need one, it is spelled in words.

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

What `addr` is applied to decides which address you get:

- `addr p.val` is the address of the thing `p` points at.
- `addr items[i]` is the address of a slice's element.
- `addr p` is something else: the address of the variable `p` itself, which
  may live on the stack.

### [0440] A writable pointer passes where a read-only one is expected

A writable reference is accepted where a read-only one is expected, and the
call needs no conversion spelled out.

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

Protecting deeper would mean knowing which references a value owns and which
it borrows, and Landin does not track ownership ([0910]). When you want to
hand out a read-only view, hand out a read-only reference; an accessor is
how.

### [0460] A pointer to a fixed address

`ptr(...)` turns an address into a pointer. The pointer type comes from the
declaration.

```landin
gpio: ptr mut u32 = ptr(0x4001_0000)
```

This binding is immutable, but the register behind it is written: the two
questions of [0070] really are separate.

Nothing in the pointer's type makes access to it a device transaction. The
operation that reads or writes does that ([0850]).

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
from one borrows nothing as far as the compiler knows, and the compiler will
say nothing more about that pointer's lifetime. This is the one place inside
the language where lifetime checking is left behind, much as at the C
boundary.

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

A pointer goes into the union with nothing extra to write. Getting it out
takes a `match`, and the `match` has to name both cases: `ptr (p)` is the
present case, with the pointer bound to `p`.

To ask only which case the union holds, compare with the atom:
`m == none_found` or `m <> none_found`. That reads no address, so it needs
no `match`. Two such unions do not compare with each other.

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

Each says more than a pointer would: a slice carries its length, an index is
checked against that length, and a handle's type says what it is for.

### [0500] No pointer arithmetic outside the library

There is no `p + n` on pointers, and no built-in operation that turns a
pointer into a slice.

Code that really needs to compute an address converts to an integer and back
([0470]), and gives up lifetime checking when it does. Inside the standard
library, `core/mem` does this for you, behind its private storage
operations.

If you need an element's address, take it from a slice that you know is not
empty: `addr items[0]`.

### [0510] Storage that is not filled yet: `mem.storage(t)`

A growing array has room for more items than it holds. The empty slots
contain no `t` yet, so no slice may cover them: a `[]mut t` over them would
claim values that do not exist. Neither may they be zero-filled, because
many types, pointers among them, have no zero value ([0540]).

`core/mem`'s `storage(t)` is the answer. It holds a block of storage, counts
how many slots at its start are initialized, and only ever shows you that
initialized prefix. Its representation is the private type `raw(t)`: you can
hold one but not look inside.

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

**Growing.** To grow, reserve a bigger block and `transfer` every item into
it. A `transfer` copies and leaves its source as it was, so the old block is
unchanged until you are done: if a step fails, release the new block and
carry on with the old one. Only after every item is copied do you empty and
dispose of the old block and publish the new one.

This keeps the empty slots out of reach. It does not make raw storage safe:
the allocation you supply must be live, aligned and as large as you say
([1720]).

## LIFETIME AND ESCAPE

Landin checks borrows and escapes locally. It has no Rust-style ownership
and no lifetime parameters. Inside each function, the compiler knows where
every pointer, slice and `any` points. That place is the reference's
*origin*, and there are three:

| origin | what it is | how long it lives |
|---|---|---|
| static | module storage and literals | the whole program |
| allocated | what an allocator handed out | until you give it back |
| frame | a function's locals | until the function returns |

Everything in this section follows from a few rules:

- A frame reference never leaves its function ([0770]).
- A function does not keep a pointer it was given unless its signature says
  `escaping` ([0780]).
- While a view into a local is in use, the local cannot be grown or moved
  ([0830]).
- A returned reference says what it came from, with `from` ([0790]).

The compiler checks each rule one function at a time, against signatures.
A change in one body therefore never changes what another function may do.
The price is that some mistakes go uncaught; [0860] lists them.

### [0770] A frame reference cannot leave its function

A pointer to a local dies with the function. Returning one is an error, and
so is storing it anywhere that outlives the function.

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

The origin travels with the value. A slice of a local array is frame too,
and so is an `any` built over a local ([1370]).

### [0780] Keeping a pointer you were given: `escaping`

A parameter is non-escaping by default. The callee may read and write
through a pointer it was handed, but it may not keep the pointer once it
returns.

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
`escaping`.

A function that does keep a reference marks the parameter `escaping`. The
caller may then pass only something that lives long enough: allocated or
static, never frame.

The next example assumes a struct `node` with a field
`next: ptr mut node`. `mem.new` allocates one value through the allocator
it is given and returns a pointer to it ([1360]; `core/mem` in the
[library guide](docs/library.md)).

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

What counts as keeping:

- "Keeping" means any store that outlives the call: into a module binding,
  or through a pointer, slice or `inout` field the caller owns.
- Storing a reference back into storage of the same origin is an update,
  not keeping, and needs no marker.
- Storing one parameter's reference into another parameter's storage needs
  `escaping`, or else `escaping into`.

`escaping into` names the one parameter whose storage keeps the reference.
With it, a node on the caller's frame can go onto a list on the caller's
frame, provided the node lives as long as the list. The node does so when
it is the caller's parameter, static, allocated, or a local declared
before the list.

In the next example each parameter is kept in the other's storage, so each
names the other.

```landin
push_kept: (escaping into item inout head: ptr mut node,
            escaping into head item: ptr mut node) -> none =
    item.val.next = head
    head = item
end push_kept

on_the_frame: (escaping seed: ptr mut node) -> none =
    mut first: node = seed.val
    mut head: ptr mut node = seed
    push_kept(head, addr first) -- fine: first is declared before head

    mut late: node = seed.val
    push_kept(head, addr late) -- error: late is declared after head
end on_the_frame
```

The function may keep `item` in `head` and nowhere else. A frame reference
never goes into a parameter's storage, and a reference from the caller's
parameter goes into anything its frame holds.

Exact rules: spec [1910].

### [0830] A view into a local holds the local still

A view taken from a local borrows it. While the view is still in use, the
compiler refuses to pass the local as `inout` or `sink`, because that call
could grow, move or replace the storage under the view.

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
it again after. The check looks at one function body, so there is nothing
to annotate.

Only `inout` and `sink` trigger the check, since they are the two ways a
call can change the storage itself. While the view lives, you may still
read the local, pass it `in` or pass it by pointer.

A view needs no name to be in use. The slice a `for` walks is in use until
the loop is done, so the loop's body does not pass what it walks `inout`
unless it leaves the loop straight after; and a view given to a call is in
use until the call returns, so its source is not passed `inout` beside it.

An unchecked region ([1120]) does not turn the check off: origins and
escape are among the checks that stay.

### [0790] A returned reference says where it came from: `from`

When a function returns a reference derived from a parameter, its signature
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

The compiler checks the clause against the body in both directions.
Returning something derived from a parameter without naming it is an
error, and so is naming a parameter the result did not come from.

`from` is the mirror of `escaping`. `escaping` says the callee keeps what
the caller handed in; `from` says the caller keeps something of what the
callee handed back. You write both, and the compiler infers neither. So a
distant body can never change a signature, and function pointers, concept
entries and the C boundary need no special rule.

Two refinements:

- A read-only result that points into static storage may name a parameter
  it does not come from, since static storage outlives every parameter.
- A writable result must name every place it could point to. So a helper
  that might return module storage takes that storage as a parameter and
  names it too.

Exact rules: spec [1910].

### [0800] A borrow through `from` lasts across the call

A result with `from` borrows its source just as a view does in [0830].
The difference is how the compiler learns of the derivation: the
signature supplies it, where in [0830] one expression showed it. The fix
is the same: take the view again afterwards.

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
view keeps no borrow: saving `lenof xs` saves a number, and you may use it
after `xs` or its container changes.

Taking an address or a range is different: that reference keeps the
selected storage's origin ([0430], [0790]). Writing through a known
address of a local updates the local's origins too. Mixing in a pointer
made from an integer ([0810]) does not hide a tracked origin.

Exact rules: spec [1910].

### [0810] A pointer made from an integer is not tracked

Converting an integer to a pointer ([0470]) ends tracking. The integer has
no origin, so the pointer borrows nothing, and the compiler says nothing
more about its lifetime. Nor does the compiler check that the storage is
live or large enough: that stays the library's unsafe obligation ([1720]).

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

A signature brings tracking back. A function that indexes a table C gave
it writes `from table` on its result, and the compiler checks its callers
against that as against any signature. The compiler does not check the
function's body against it, since a pointer made from an integer satisfies
any `from`. The contract is its author's claim, so keep such functions
small.

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
or storage from another allocator and refuses a frame array. The reason is
that allocations borrow nothing ([0790]): a helper could store one in
module storage, and an arena over frame storage would let that pointer
outlive the frame.

For a local buffer whose every use stays inside the frame,
`arena.over_unchecked` takes frame backing. You must stop using its
results before the buffer ends.

Other providers build on the same idea:

| provider | what it does | what you must do |
|---|---|---|
| `core/region.over(ledger, provider)` | records every extent it takes from `provider` in a `region.space` ledger you declare `zeroed` | release all at once with `defer region.release(ledger, provider)`, and stop using its allocations before then |
| `core/pool.over` | hands out pieces of backing whose origin its handle keeps | keep the backing live until every result is done with |

A region's handle holds a copy of its provider's handle. Its allocations
borrow nothing, and its bookkeeping also uses the provider's capacity. A
finite provider stays finite: there is no hidden heap fallback.

The compiler does not do these for you:

- arrange the backing's lifetime and release (`defer`, [1100], runs on
  every exit);
- keep overlapping backing apart;
- stop you using a result after its backing ends or is reused.

Results obey the ordinary origin rules and nothing more. `arena` itself
is not a keyword: it is an ordinary name you may declare.

### [0850] Volatile access sits outside the borrow rules

A volatile access is exempt from the borrow rule and from every aliasing
assumption. It is an operation, not a pointer type:

| operation | for |
|---|---|
| `compiler.volatile_load`, `compiler.volatile_store` | one scalar |
| `compiler.register_read`, `compiler.register_write` | a register image ([0740]) |

Each performs exactly one access of its width through an ordinary pointer.
That pointer is usually one built from an address ([0460]), and so already
outside the lifetime checks ([0470]).

Hardware often needs several typed windows on one address, such as a byte
view and a word view of the same register, and that is legal on purpose.
There is no `volatile ptr`: a second permission on every reference would
buy nothing the operations do not.

Direct memory access (DMA) uses ordinary slices. Landin makes no lifetime
promise about storage a device is still writing: neither an interrupt nor
masking one makes it reusable, and waiting for the device is the driver's
own protocol.

Exact rules: spec [1990].

### [0860] What the lifetime checks do not catch

The checks know which kind of storage a reference points into. They do
not know which allocation it points into, or whether that allocation
still exists. So these go through:

- Use after free or reset. The compiler does not know which arena or
  allocator a pointer came from, or that it has been given back.
- A pointer that went through longer-lived storage. Inside one function a
  struct carries its fields' origins ([0840]). Store a pointer into a heap
  node, though, and read it back later through the node: it now has the
  node's origin, and whatever it pointed to may be gone.
- Anything across the C boundary.

Catching these would need region-based checking or generation counters,
and Landin deliberately has neither.

## CONCEPTS AND GENERIC CODE

Generic code has three parts:

- A concept lists the operations a type must have.
- A conformance says which functions supply them for one type.
- A generic function takes the type as a parameter and calls the
  operations through it.

There are no classes, no traits with default bodies and no structural
matching: a type satisfies a concept because somebody said so.

### [1230] Declaring a concept

A concept names a bundle of operations, each a complete function
signature written in terms of the concept's type parameter.

```landin
ordered: type = concept (t: type)
    less: (a: t, b: t) -> (yes: bool)
end ordered
```

A concept is an ordinary type declaration, so it lives in a module like
any other name. It has no default bodies: each conformance supplies every
entry.

### [1240] Making a type conform

A conformance registers one type against one concept, naming the
function that supplies each entry.

```landin
less_than_i32: (a: i32, b: i32) -> (yes: bool) = a < b end less_than_i32

i32 is ordered (less: less_than_i32)
```

Each label is an entry of the concept. Each supplying function must have
exactly the entry's signature with `t` replaced by `i32`, and it must be
a declared function: [1010]'s `less_i32`, a binding that holds an
anonymous function, cannot supply an entry.

There is no implicit conformance. A type with a matching `less` is still
not `ordered` until a line like this one says so.

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
values around.

The fine print:

- Every type parameter is written in the list. A name that is not in
  scope is a misspelling and an error, never a new type variable, just as
  a misspelt build option is an error ([1530]).
- A generic function is not a function value. Only a call picks a
  concrete instance, so you cannot take `sort` itself and store it.
- A private `! ...` error set is inferred separately for each concrete
  instance.
- The compiler checks the body for each instance a call makes. A generic
  function nothing calls is checked only for its names and for operands
  no type could make valid. An error that depends on what `t` turns out
  to be, such as a view held across a call that may move its source, is
  reported once a call picks `t`.
- In the body, `t(value)` converts one value to whatever type `t` turns
  out to be, by that type's own conversion ([0310]): `t(0)` starts a sum
  in any numeric type. An instance whose type has no conversion from the
  value is an error once a call picks it. A type parameter converts and
  does not construct: `t(a: 1)` is an error.

### [1300] Calling a generic function

The compiler normally deduces the type from the arguments. You may also
name it, in the same named-argument list as the runtime arguments.

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
conformance the body uses. The table holds the type's size and alignment,
then the concept's functions in the order the concept declares them.
`t.less(...)` loads `less` from that table and calls it. The same tables
carry `any C` values ([1370]), so static generics and runtime dispatch are
one mechanism ([1690]).

The tables are the meaning of generic code. Specialization replaces an
indirect call with a direct one where the compiler can prove which table
arrives. It is an optimization that never changes what a program does.

Two independent switches control code generation:

| option | values | default |
|---|---|---|
| `--optimize` | `none`, `size`, `speed` | `size` |
| `--specialize` | `off`, `auto`, `all` | `auto` |

Neither depends on `--build-mode`.

A call is never specialized merely because its source type is known: the
compiler needs proof of the table that actually arrives. A call stays
indirect when it goes through `any`, through a table the compiler cannot
trace, or in an instance whose address is taken. `--build-report=PATH`
writes a report of what was specialized and what stayed indirect, and
why.

### [1340] Combining concepts

A concept may build on others by naming them after `is`. A type that
satisfies the combined concept still conforms to each part separately.

The example assumes a struct `button` with a `text` field, a type
`canvas`, and functions `button_draw`, `button_click` and `button_focus`
with the entries' signatures.

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
being a `widget` does not make it `drawable`. Conformance is always
declared, even when its list is empty.

The combined concept has a name of its own, so an `any widget` value
still carries one table and stays two words.

In generic code, `t.entry` must name exactly one declaration across the
concept and all its parents:

- A parent reached twice, through two paths, is still one concept.
- Two different concepts that both declare `entry` make `t.entry`
  ambiguous.
- Parent order never decides, and a child's own entry does not override
  an inherited one.
- A clash nobody uses is not an error.

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
empty slots out of sight.

A type parameter may carry one concept constraint, and a `fixed`
parameter is an integer known at compile time. Here `cmp.hashable` is a
concept `core/cmp` provides, and `zeroable` is [0550]'s:

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

Applications are positional and complete: `key_value(u32, utf8)`, never
`key_value(u32)`. A `fixed` argument is an integer literal, or a `fixed`
parameter passed on by another generic declaration, and it must fit its
declared type. Whether an argument type may go where the body puts it,
as a field or an array element, is checked after substitution.

An alias may be generic too, including a union of atom sets. An alias
never makes a new type: `missing | ptr t` keeps the one-word optional
pointer of [0480].

The fine print:

- The compiler checks a generic type's template even if nothing applies
  it, and reports an error that depends on the argument at each
  application. A generic function's body is checked per instance instead
  ([1290]).
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
generic types take. So a variable may carry a constraint, and a `fixed`
parameter may appear among them.

The supplying functions are generic themselves. Instantiating the
conformance gives them their type argument and leaves functions of
exactly the concept's shape.

The target must be the whole generic type applied to the binder in
order, each variable used once: one conformance covers the whole family
`pair(t)`. Another family for the same template and concept is a
collision ([1280]), and so is a concrete exception such as
`pair(u8) is iterable`.

Without this form no generic container could be traversed, sorted or
handed to other generic code.

### [1270] One type, several conformances

A conformance is keyed by the type, the concept and the concept's other
input types, so one type may satisfy the same concept more than once.

The example assumes `position` is a byte-offset type, and `utf8_nth` and
`utf8_at_pos` look up a character by count and by position.

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

The compiler collects every conformance in every module the program
reaches before it checks any generic call, whether or not anything uses
the conformance. Modules the program does not reach contribute nothing.

A conformance is a registration, not a name, so it needs no `public` and
refuses one.

### [1260] A concept fixes its error sets

A concept entry's error set is written out or absent, never inferred
with `! ...`. An entry is reached through a table, and [0960] forbids an
inferred set there. So the concept fixes the error set once, for every
type that will ever satisfy it.

That is right for allocation, where out of memory is out of memory, but
it shapes how you design a concept.

The same goes for what an implementation is handed: by convention, a
concept with no allocator among its parameters says its implementations
do not allocate. The compiler does not check that, since any hosted
function can make a heap of its own ([1680]).

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
[1250]'s `pair` does. The labels may come in any order.

The loop evaluates `s` once and keeps a private copy. Each provider gets
a read-only pointer to that copy, so a large struct is copied once, not
on every call.

The four signatures are exact: no permission, error set or `from` clause
is inferred or converted. So a provider whose result is declared `from s`
does not match.

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

A function that adds to a list takes the list `inout` and the allocator as
an ordinary argument:

```landin
record_reading: (provider: type is mem.allocator, inout readings: vec.list(u32),
                 memory: provider, value: u32) -> none ! mem.out_of_memory =
    try vec.push(readings, memory, value)
end record_reading
```

The same `record_reading` runs with `heap.new()` as `memory`, or with an
arena over a buffer on the stack ([0820]).

The list is changed, so it is passed `inout`. The allocator is passed as
a handle: a small copyable value, passed `in`, that refers to its
provider's state. The handle's lifetime is checked once, where the handle
is made from that state, and using it does not borrow that state. So
several containers can allocate through one handle, and a region can
allocate from its parent while both are live.

The allocator is passed to each call rather than stored in the container.
A stored one would be part of the type, `vec.list(t, provider)`, so a list
in an arena and a list on the heap would be different types and no
function could take both. Passing it keeps the type `vec.list(t)`, at the
cost of one argument to every call that can allocate.

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
  an equivalence, equal keys must hash alike under the seed the map is
  given, and neither may change while the key is stored, including
  through a pointer inside the key.
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

What the pair is, as a value:

- It is an ordinary copyable value, and can sit in a variable, a field or
  a slice.
- What it points at is never copied, because its size is unknown. So the
  pointee must stay alive as long as any copy of the pair can use it. An
  arena ([0820]) is the usual place for it.
- It needs no permission of its own: the concept's entries carry it. An
  entry declared with `self: ptr mut t` can only be satisfied by a
  pointer that may write, so a stateful implementation behind `any` just
  works.
- It does carry its pointee's origin ([0770]), so an `any` over a local
  cannot go into a list that outlives the frame.

An `any C` is itself a provider of C and of every concept C builds on
([1340]). So a generic function ([1290]) takes one, and each entry the
function calls goes through the value's own table. Here an `any widget`
is handed to a function that wants a `drawable`:

```landin
draw_on: (provider: type is drawable, item: ptr provider,
          target: ptr mut canvas) -> none =
    provider.draw(item, target)
end draw_on

paint_one: (item: any widget, target: ptr mut canvas) -> none =
    draw_on(addr item, target)
end paint_one
```

An `any C` provides no other concept, and the compiler, not the program,
declares these conformances. An `any` is not erased again: where an
`any C` is wanted, pass the one you have rather than its address.

Printing is where most programs first meet `any`. `io.write_format` takes
its values as a `[]any text.formattable`, each built from a value's
address:

```landin
print_born: (host: blocking.host, name: utf8, year: u32) -> none =
    io.write_format(host, io.out(host), "{} was born in {}.\n",
                    [any(addr name), any(addr year)]) else none
end print_born
```

```landin
    print_born(host, "Ada", 1815) -- Ada was born in 1815.
```

Integers, `bool`, `utf8` and byte strings are formattable, floats not yet,
and a type of your own becomes formattable by conforming ([1240]).

The text is made in a small buffer on the stack and written as it fills,
so printing allocates nothing. A template whose `{}` and values differ in
number fails with `text.invalid_format` and writes nothing.

### [1380] Building an `any` with `any(...)`

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
taking `self: ptr mut t`. Once the `any` is built, binding mutability
controls only replacing the pair, not the write authority its pointer
already carries.

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

An entry is callable this way when it meets two conditions:

- Its first parameter is `self` as `ptr t` or `ptr mut t`, or `self: t`
  taken by value when `t` is a record.
- The hidden type `t` appears nowhere else in it.

A by-value `self` is copied out of the data pointer when the call is
made. So to put a small handle, such as an allocator handle `memory`,
behind `any`, take the address of the variable that holds it:
`any(addr memory)`.

`any C` is exactly C: a concept's parent gives no conversion, and two
`any` types never convert to each other. The implicit `self` takes part in
the same `from`, `escaping` and origin checks as a written pointer
argument.

The compiler checks a call through `any C` even if the program has no
conformance of C. Then no `any C` can be made and no value reaches the
call, so it compiles to a trap that never runs. A library that takes an
erased capability therefore builds in a program that supplies none.

### [1400] What `any` can do that generics cannot

One slice can hold values of different types. A `[]t` is always one `t`;
a `[]any widget` holds buttons, labels and anything else that is a
widget.

## COMPILE TIME

Landin has a little compile time and keeps it little. You can ask which
target you are building for and choose declarations by the answer
([1500]), check a layout ([1510]), and declare build switches ([1530]).
You cannot run your own code while the program builds ([1540]).

### [1490] The word `fixed`

`fixed` marks something the compiler knows before the program runs. You
meet it in three places:

- `fixed if` chooses declarations ([1500]).
- A fixed parameter is a compile-time value ([1520]).
- A fixed expression is what a condition, an assertion or an option
  default is written in ([1500], [1510], [1530]).

### [1520] A compile-time value parameter

A `fixed` parameter is a value the caller supplies at compile time, so it
can size an array in the signature.

```landin
make_buffer: (fixed capacity: u32, t: type is zeroable)
             -> (b: [capacity]t) = zeroed end
```

A fixed parameter sits beside the type parameters and works the way they
do ([1290]): the call supplies it or deduces it, and it has no storage at
run time.

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

The compiler parses every arm, so a syntax error in an arm you are not
building is still an error. Only the selected arm's declarations join the
module; the declarations of the other arms have no names, no types and no
effect. Arms may nest, an arm may be empty, and an arm opens no scope.

**The facts.** The compiler supplies these facts:

| fact | what it says |
|---|---|
| `compiler.arch` | `x86_64`, `arm64`, `rv64`, `cortex_m0`, `rv32`, `xtensa` or `synthetic_32` |
| `compiler.os` | `linux`, `darwin`, `freebsd` or `freestanding` |
| `compiler.word_size` | the width of `usize`, in bits |
| `compiler.byte_order` | `little` or `big` |
| `compiler.build_mode` | `debug`, the default, or `release` |
| `compiler.c_sysv_lp64`, `compiler.c_darwin_lp64`, `compiler.c_aapcs64_lp64`, `compiler.c_riscv_lp64d`, `compiler.c_aapcs32`, `compiler.c_riscv_ilp32`, `compiler.c_xtensa_windowed_ilp32` | which C ABI the target uses, each true for its own ABI alone |
| `compiler.c_runtime` | whether C's runtime starts the program and its library is linked |
| `compiler.feature.NAME` | whether the selected CPU level has feature NAME |
| `compiler.cache_line` | the line of the device description's cache, in bytes, or 0 without one |

Build mode is a value you ask for. It does not change runtime checks or
optimization.

**The C ABI and the C runtime.** Ask the C ABI question directly rather
than guessing the answer from the architecture: Linux and Apple arm64
share `compiler.arch == arm64` and answer the C ABI question differently.
`compiler.os` is separate from the C ABI because Linux and FreeBSD share a
calling convention on each architecture but not every libc record layout.

`compiler.c_runtime` is always true on Darwin and FreeBSD, true on Linux
only when the build asks with `--link=libc`, and never true on firmware. A
library calls the C library only where this fact says it is there.

**CPU features.** A build assumes a CPU feature level. You choose it with
`--level=`, and it defaults to the oldest processor of the architecture.
`compiler.feature.NAME` asks about one feature, such as `bmi2` on x86-64,
`lse` on arm64, `idiv` on the M profile or `xtheadba` on RV64. A feature
of another architecture is simply false, so you need no `compiler.arch`
test first:

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

**Values that differ by target.** When only a value differs, you need no
`fixed if` at all. A module value may read a fact, and a function branches
on that value with an ordinary `if`:

```landin
fast_count: bool = compiler.feature.popcnt
on_linux: bool = compiler.os == linux
word_bytes: usize = compiler.word_size / 8
```

An integer fact takes its type from context. You read an atom fact, which
is one of `compiler.arch`, `compiler.os`, `compiler.byte_order` and
`compiler.build_mode`, by comparing it with one of its atoms.

**Inside a function.** A function body reads no fact directly, except in
an array length, which is part of a type [0520], and `fixed if` cannot
begin a statement. Instead:

- What differs by value branches on a module value like those above.
- What needs a call that one system lacks is a function declared in each
  arm of a module-level `fixed if`.

**Conditions.** A condition is a closed fold: literals, parentheses, unary
`-`, integer `+ - * / %` without overflow, integer comparisons, equality,
`not`, `and`, `or`, and `sizeof` and `alignof` of the built-in scalar
types.

- Sizes count target bytes, so `compiler.word_size == 8 * sizeof usize`
  holds on 32-bit and 64-bit targets alike.
- A condition may also read your own options ([1530]).
- The compiler refuses calls, runtime names, measurements of your own
  types and aggregate operations, even in an operand that short-circuiting
  would skip.

**Forms that do not exist.** There is no `public fixed if`, no trailing
name after `end if`, and no `fixed if` inside a block, struct, signature
or template.

Exact rules: spec [1940].

### [1510] Checking a layout at compile time

`compiler.assert` stops the build when a fixed condition is false.

```landin
compiler.assert(sizeof usize == 8)
```

`compiler.assert` is a module-level directive, and a selected `fixed if`
arm may hold one too. An assertion in an inactive arm does nothing.

The condition is the same closed fold as in [1500] and must be a bool. A
false condition is reported at its own source.

An assertion may also measure your own types, as in
`compiler.assert(sizeof header == 8)`. The compiler then checks it once
the type is laid out.

`compiler.assert` is a builtin call rather than a keyword, like the rest
of [1560]. That leaves the word `assert` free for an ordinary function of
your own, such as the `assert` of [1040].

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

**Type.** An option's type is `bool` or a built-in integer type; `usize`
and `isize` take the selected target's bounds. An option has no storage at
run time, and its name is visible only in fixed conditions, option
defaults and compiler assertions.

**Declaration.** Option names are global across the whole program, so each
is declared exactly once, unconditionally at module level and never inside
a `fixed if` arm: the compiler collects every option before it chooses
arms.

**Names.** An option may not share a name with either of these:

- an active declaration or import in its declaring module, including
  another file of that module;
- a compiler-owned atom such as `arm64` or `release`.

Ordinary bindings in unrelated modules may use the same spelling. Fixed
configuration still reads the global option, while runtime uses ordinary
module/import lookup.

**Defaults.** A default may refer to another option, even one declared
later, and sees that option's overridden value. The compiler refuses
cycles, and every default must be valid even when overridden.

**On the command line.** `--option=NAME=VALUE` takes `true` or `false`, or
signed decimal integer text. Unknown or repeated names, malformed values
and values out of range are errors. `--build-mode=debug` or
`--build-mode=release` sets the separate built-in build mode.

### [1540] No compile-time execution

There are no compile-time loops and no compile-time function calls.
Nothing of yours runs while the program is being built.

The builtin modules of [1560] look like an exception and are not one.
Their members are operations the compiler recognizes, not your functions
run during the build, and nobody can add another. Their inputs differ:

- Some must be fixed, such as assertion conditions, library names and
  assembly text.
- Others can be runtime values, such as atomic data and assembly input
  operands.

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
no LLVM and no C in between. Going through C would lose the calling
convention, the traps and the debug information Landin is precise about,
so every target's backend is Landin's own. The
[README](README.md#current-compiler-capabilities) lists the targets.

- The emitted assembly is deterministic: the same program and options
  give the same bytes, whatever the build directory, environment or order.
  The linked executable is not covered by that promise.
- Every ordinary function and every interrupt handler sets up the frame
  pointer, so a debugger or a backtrace can always walk the stack. On
  Cortex-M0 a function with no calls, no assembly and no stack changes may
  leave it alone (spec [1990]). A naked function ([1570]) owns its frame
  instead.
- The whole program is compiled together ([1480]). The compiler may keep
  private caches, but there is no stable separate-compilation interface.

On Cortex-M the `cortex_m0` backend emits ARMv6-M Thumb, the default
`armv6-m` level.

- **Levels.** `--level=armv7-m`, `--level=armv7e-m` or
  `--level=armv8-m.main` lets the backend use that level's instructions
  too, which the processor must then support. All four levels are
  little-endian.
- **Floats.** Floats are computed in software unless the device
  description names a float unit. A Cortex-M7's
  `compiler.float_unit("fpv5-d16")` makes the build hard-float at
  `armv7e-m`: its f32 and f64 arithmetic becomes VFP instructions, its
  floats are passed in s and d registers, and `compiler.feature.fp` and
  `compiler.feature.fp_dp` say so.
- **Firmware.** A firmware request emits its own reset code, vector table
  and linker script. Reset copies initialized data and RAM code out of
  flash and clears BSS before your code runs.
- **Caches.** A Cortex-M7's description may also declare its caches,
  `compiler.cache("armv7-m-l1", 32)`. Reset then turns them on after those
  copies and off again if the entry returns, and `compiler.feature.cache`
  and `compiler.cache_line` say so. A direct memory access (DMA) buffer is
  kept in step with the caches through `core/cache`.

Exact rules: spec [1990].

### [1560] The `compiler`, `assembler` and `linker` modules

Three builtin modules reach the toolchain. They belong to the reserved
`landin` package (`landin/compiler` and its siblings) and are in scope
without an import, which is why nobody else can use their bare names.

| module | what it reaches |
| --- | --- |
| `compiler` | target, word size, byte order, build mode, CPU features; the atomic, volatile and register intrinsics; the two stack builtins under fibres ([1675]); `compiler.unreachable()`; `compiler.utf8_unvalidated(bytes)` |
| `assembler` | inline assembly |
| `linker` | libraries, sections, entry |

Two of those calls:

- `compiler.unreachable()` is a call that never returns. It stops the
  program as a failed check does ([1670]). Given a `caller` parameter of
  the function it is written in, `compiler.unreachable(where)`, it
  reports the stop at the call that filled the parameter ([1040]).
- `compiler.utf8_unvalidated(bytes)` is text of bytes known to be UTF-8,
  made without reading them and only inside `unchecked` ([0600]).

The members of all three modules are built into the compiler; you cannot
write one yourself.

Some arguments must be fixed when the program is compiled:

- `compiler.assert` takes a fixed condition.
- `linker.library` takes a fixed name.
- `assembler.block` takes fixed instruction text.
- An atomic's ordering is always a fixed `compiler` atom.

Atomic and volatile pointer and value operands, and assembly inputs, can
be runtime values.

What works today:

- Every hosted target has the compiler facts, `compiler.assert`,
  `linker.library` ([1590]) and the scalar atomics and barriers ([1620]).
- Firmware targets also have placement annotations ([1640]) and the firmware
  entry request ([1650]), which hosted targets refuse, and Cortex-M firmware
  links C archives through `linker.library` ([1590]). The
  [capability inventory](docs/capabilities.md) names the supported firmware
  targets and their limits.
- `assembler.block` is checked on every target ([1630]).
- Any other tool operation is refused by name.

Why some things are builtin and others are not: something is builtin when
the compiler has to understand it.

- Atomics are builtin, because opaque assembly in a hot loop wrecks the
  register allocation around it.
- Masking interrupts is not. A critical section wants nothing moved across
  it, which is exactly what opaque assembly gives. So
  `cortex_m.disable_interrupts` and its kin are an ordinary module per
  target, written with `assembler.block` ([1630]).
- An operation that comes to mean the same thing on every target, as the
  atomics do, can move into `compiler`.
- There are no vector intrinsics: fixed arrays are the vector type and
  take element-wise operators ([0590]).

### [1580] Importing from C

A bodyless `extern(c)` declaration imports a C function. A compilation
reads Landin, never C headers: `refine bindings`, a deterministic binding
generator, asks Clang what a header declares and writes these declarations
for you.

```landin
none_returned: atom
allocation: type = none_returned | ptr mut u8
extern(c) malloc: (n: usize) -> (p: allocation)
extern(c) free: (p: ptr mut u8) -> none
```

**Null.** A C pointer may be null and a Landin pointer may not. So a C
result or parameter that may be null is [0480]'s one-atom pointer union,
which costs no extra bits, and you `match` the result before using the
pointer.

- `ptr(0)` is refused, and so is any fixed expression that folds to zero
  at the target's `usize` width.
- A pointer built from an integer at run time is checked, and zero traps,
  even in `unchecked`: losing the origin is not permission to make null.
- Absent allocator backing is a named union too, never a fake `ptr(1)`.

**What a header leaves out.** A header does not say everything Landin
wants to know: whether a pointer may be null, who owns it, what it is
`from`, whether C retains it, how to read incoming varargs. The generator
takes that from a written policy, not from a handwritten replacement
signature.

**A function found while the program runs.** Such a function, a symbol of
a loaded library for example, is just an address. Apply a C function type
to it and you have a function value:

```landin
c_adder: type = extern(c) (a: i32, b: i32) -> (r: i32)

add_at: (address: usize) -> (sum: i32) =
    add := c_adder(address)
    sum = add(2, 3)
end add_at
```

Nothing can check that code of that type is there, as nothing checks a C
cast, and the value is yours to call only while the library stays loaded.

**The supported ABIs.** Landin supports five C application binary
interfaces (ABIs):

| C ABI | where |
| --- | --- |
| SysV AMD64 LP64 | Linux and FreeBSD x86-64 |
| Apple's arm64 variant of AAPCS64 | macOS |
| the standard AAPCS64 | Linux and FreeBSD arm64 |
| RV64 LP64D | Linux RV64 |
| AAPCS32 | Cortex-M |

Under Cortex-M's AAPCS32, floats travel in the float unit's registers when
the device description has one and in core registers when it has none.

**C's types.** `platform/c` names them: the signed and unsigned integer
widths, `c_size`, `c_ptrdiff`, `c_float`, `c_double` and `c_bool`. It asserts
`compiler.c_sysv_lp64 or compiler.c_darwin_lp64 or compiler.c_aapcs64_lp64
or compiler.c_riscv_lp64d or compiler.c_aapcs32`, so it admits exactly
those five ABIs; another target with the same pointer width, RV32's or
Xtensa's, is not admitted.

- The first four are LP64, with a 64-bit `long`. AAPCS32 is ILP32, so
  there `c_long` is an `i32` and `c_size` a 32-bit `usize`.
- Plain `c_char` is the ABI's plain `char`, a number and not a Unicode
  scalar: `i8` under SysV and Apple's ABI, `u8` under the standard
  AAPCS64, RV64 and AAPCS32.

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

**Variadic functions.** A variadic C function writes `, ...` after at
least one fixed parameter. This `...` is C's variadic tail, unrelated to
[0960]'s `! ...`.

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
- Cortex-M declares no variadic C function yet. Write a C function of
  fixed arity that makes the variadic call, and import that one.

Exact rules: spec [1975].

### [1600] Exporting to C

Give an `extern(c)` declaration a body and you have defined a C function
in Landin. Make it `public` and C code can call it by its name.

```landin
public extern(c) my_add: (a: i32, b: i32) -> (r: i32) =
    r = a + b
end my_add
```

`extern(c)` chooses the calling convention and nothing else:

- Without a body it imports.
- With a body it defines.
- `public` is what exports, making the declared name a global symbol.

A private C definition is still useful: its address can be handed to C as
a callback.

Limits:

- A C signature is not generic, takes only `in` parameters and returns at
  most one value.
- Landin's declared failures do not cross. Recover inside the body and
  return the status or value the C interface promises.
- Nothing is promised if a foreign exception or a `longjmp` crosses
  Landin frames.
- On Cortex-M a C signature cannot be variadic: import a fixed-arity C
  function that makes the variadic call instead.

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

It does export. Which symbols the linker sees:

- A link name is a global symbol whether or not the declaration is
  `public`. That is how you export a module datum deliberately.
- Without `link`, C imports and public C definitions use their declared
  name.
- The program's entry is global, and so are a public definition in a
  machine convention and a Cortex-M definition with [1640]'s section,
  alignment, vector or `keep` (spec [1975]).
- Every other function and datum, public or private, is a local symbol
  under its own name, so no C library can collide with it. It is renamed,
  with its module path, only when the program holds that name twice.

The rules for a link name:

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

### [1615] Storage local to each thread

`link(thread)` before a module `mut` binding gives every thread its own
instance of it. A thread reads and writes only its own, and each one
starts at zero when its thread starts.

```landin
link(thread) mut last_failure: i32

note_failure: (number: i32) -> none =
    last_failure = number
end note_failure
```

Two threads calling `note_failure` at once each keep their own number, so
this needs no lock. `hosted/system` keeps each thread's last errno this way.

- There is no initial value: write none, and use a type that has a zero,
  so not a pointer or a slice.
- It takes no `symbol` or `section`, so a C thread-local is not named this
  way; use the binding generator ([1580]).
- On a microcontroller, which runs one thread, it is ordinary module
  storage.
- Its address is good while its thread runs. Do not hand it to a thread
  that may outlive the one it belongs to.

Exact rules: spec [1996].

### [1590] Linking a library

`linker.library` asks the C driver for a library, as `-lNAME` asks it in C.
Write it next to the declarations that need it, not in a separate build file.
`linker.directory` says where to look, relative to the file it is in.

```landin
linker.library("raylib")
linker.library("m")
linker.directory("vendor/lib")
```

This links `libraylib` from `vendor/lib` beside the source, and `libm`
from wherever the C driver keeps it.

- **The name** is a fixed text literal of ASCII letters, digits, `_`, `-`
  and `.`. It is nonempty, does not begin with `-` and is not only dots.
  The driver takes a shared library or an archive of that name, as it
  would for a C program.
- **Order.** Active directives reach the linker after the program, in
  source order, repeats included. So moving one among the module's
  declarations can change how archives resolve. This is the one place
  where declaration order matters. A directive in an inactive arm of a
  `fixed if` ([1500]) adds nothing.
- **A directory** is a fixed, nonempty text literal: relative to the
  directory of the file that names it, or absolute. One that does not
  exist is refused before anything is linked.
- **`-L DIR`** on `refine compile`, `run` or `check` names another
  directory, relative to where the build runs. It is searched first, so a
  build can put its own copy of a library ahead.
- **At startup.** Each directory is also where the program looks for a
  shared library when it starts.
- **A missing library.** A library the link cannot find is named with
  every directory searched.
- **On Linux** a library links beside the C library, so a build that asks
  for one needs `--link=libc`. The default static link ([1650]) refuses a
  library, and refuses a directory too.
- **Cortex-M firmware** links each library as a static archive built for
  its core, after the program and before the compiler's runtime. It
  refuses one that brings C constructors, thread-local storage or a
  dynamic linkage, none of which its startup can honour.

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

The two machine conventions, `interrupt` and `naked`, are their own
function types:

- A definition is nongeneric, exactly `() -> none`, and declares no
  failures. Its function value can be stored or named by a vector, but not
  called or converted to an ordinary or C function.
- An interrupt handler runs an ordinary Landin frame on top of the
  hardware's exception frame and returns through EXC_RETURN.
- A naked body is one assembly block with no compiler prologue. The stack,
  registers, calls and return instruction are yours, and falling off the
  end traps.
- Neither convention keeps a function from section garbage collection
  ([1640]).
- Naked functions also work on hosted x86-64, arm64 and RV64;
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

`core/atomic` wraps one `u8`, `u16`, `u32` or `u64` in a cell whose
operations carry their orderings in their names:

| operations | ordering |
| --- | --- |
| `load` | acquires |
| `store` | releases |
| `exchange`, `add`, `compare_exchange` | acquire and release |
| `load_relaxed`, `store_relaxed`, `add_relaxed` | order nothing else |

Cortex-M0 has no read-modify-write atomics, so there a cell has no
`exchange`, `add` or `compare_exchange`, there is no `u64` cell, and the
compiler reports a call to one. What it has is `sole_add`, the single
writer's add: a load and a store, correct while only one context, say an
interrupt handler, writes the cell. State that several contexts write
needs `platform/cortex_m`'s critical section instead.

A cell, and the single writer's add on it:

```landin
import core/atomic

mut ticks: atomic.cell(u32) = zeroed

count_tick: () -> none =
    _ = atomic.sole_add(addr ticks, 1)
end count_tick
```

Each tool for shared memory does one thing:

| tool | what it gives |
| --- | --- |
| atomics | synchronization of coherent CPU memory between threads |
| volatile accesses ([0850]) | every access happens, as written; no synchronization between threads |
| compiler barrier | the compiler forgets what it knew about memory; no hardware ordering |
| the target's device and completion barriers | hardware ordering and completion of the accesses before them |

A direct memory access (DMA) buffer stays an ordinary slice. When the
device has finished, by its own protocol and not merely because an
interrupt arrived, make its writes visible with the target's barriers or
cache maintenance and a compiler barrier. Then read the buffer. Masking
interrupts does not stop DMA.

`spec.md` defines the supported operations, the exact orderings, alignment
traps, happens-before and what a race may do.

Exact rules: spec [1990].

### [1630] Inline assembly, for what has no builtin

`assembler.block` takes fixed quoted or raw text in a function body, and
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

- **The register** is a name the target answers for, never text. `general`
  asks the compiler to choose one, and `{mask}` in the text is where the
  chosen register goes, spelled at the width the operand's type selects. A
  fixed register is the architecture's own full-width name, and the text
  may use it directly.
- **The direction:** `in` carries a value in, `out` carries one out, and
  `inout` does both through one register.
- **The value.** The outputs are the block's value, as a function's named
  returns are its: one is a scalar, several are an anonymous result you
  destructure.

```landin
(low, high) := assembler.block("rdtsc", out low: u32 at rax,
                               out high: u32 at rdx)
```

**What an operand can be.**

- An integer scalar that fits one register, placed `at general` or at an
  integer register.
- An `f32` or `f64`, placed `at float` or at a float register: `xmm3`,
  `v3`, `f3`, or `d3` on a Cortex-M7 whose description has its float unit.
  A target without float registers, such as a Cortex-M with no float unit,
  refuses a float operand.
- A pointer crosses as `usize(p)` and comes back through `ptr(u)`, whose
  zero check then happens there. The integer keeps no permission. So a
  function around a block that writes storage takes it as `ptr mut u8` or
  `[]mut u8`: its callers are checked against that parameter, and an
  immutable buffer is refused there rather than handed to the system.
- A flag comes back as `x <> 0`.

Inputs are evaluated once, left to right, before the block runs.

Landin has no square-root builtin, so a block is how you reach the
instruction. `float` chooses a float register, as `general` chooses an
integer one, and the text spells it at the operand's width: `%xmm1` for
either on x86-64, `d1` or `s1` on arm64.

```landin
root: (x: f64) -> (r: f64) =
    r = assembler.block("sqrtsd {x}, {r}", in x: f64 at float = x,
                        out r: f64 at float)
end root
```

**What a block may touch.**

- Every block may overwrite the registers a call may, and the flags.
- A register a call must preserve is declared, as an operand or as a
  discarded output `out _ at rbx`, or `out _ at v8` for a float one. That
  declaration is what makes the function save it.
- The frame, stack and link registers are never named, so a block cannot
  break a backtrace.
- The language reserves no register of its own.
- A block that changes x86-64's direction flag, or a float unit's rounding
  mode or exception flags, puts them back before it ends.

**Every block is opaque to the compiler.** Memory knowledge is invalidated
and memory accesses cannot be moved across it, which is exactly what a
critical section wants. It is not itself a hardware barrier.

An ordinary block is straight-line code, with no labels or calls; a system
call returns to the next instruction, so it is straight-line too.

The older Cortex-M0 form stays as a shorthand:
`assembler.block(text, value)` passes one `u32` in and out of r0, and the
text names r0 itself.

**The common blocks, already written.** `platform/cortex_m` wraps them:

- `disable_interrupts()` returns the prior PRIMASK, and
  `restore_interrupts(previous)` puts it back, so nested critical sections
  do not enable interrupts too early. Both work in thread and handler mode.
  They do not stop DMA or mask NMI or HardFault.
- `wait_for_interrupt()` issues DSB, then WFI. Waking up is a reason to
  check the device again, not proof that it finished.
- `compiler_barrier`, `device_barrier` and `completion_barrier` are the
  three distinct boundaries of [1620]. There is no cache or scheduler API.

**A naked body.** A naked body ([1570]) owns its control flow, so its
block may use labels and branches. This entry runs after the compiler's
reset has initialized data and stacks:

```landin
extern(naked) start: () -> none =
    assembler.block("""
        1:
        wfi             @ sleep until an interrupt
        b 1b            @ then sleep again
        """)
end start
```

The compiler request names the source entry:

```sh
refine compile main.ldn --target=cortex-m0 --firmware-entry=start --emit=exe
```

A naked entry may set up PSP or call explicitly linked ordinary code, but
it must then meet that code's eight-byte stack alignment, r9 and frame
obligations. `none` is not a promise never to return: the compiler traps
if the entry returns or the naked block falls through. There is no hosted
caller to return to.

**Comments in the text.** A line of the text may end in a comment, written
as the target's own assembler writes one: `@` on Cortex-M, `//` on arm64,
`#` on x86-64 and RV64. The compiler removes it before it reads the text,
so a register or a `{name}` in a comment means nothing, and it never
reaches the assembly the compiler writes. Any other form, `/* */` or
another target's, is refused, and so is a number with a `_` in it: the
text is the assembler's, and its numbers take no separator.

Exact rules, with each target's registers, the text rules and your
obligations: spec [1990].

### [1640] Placing code and data on a microcontroller

On a firmware target, a `link(...)` annotation also places a declaration:
in a section, at an alignment, in an interrupt vector slot, and kept
against the linker's section garbage collection. Cortex-M, RV32 and Xtensa
all place declarations this way. The example and the vector table below
are Cortex-M's; RV32 and Xtensa have tables of their own, and the compiler
checks a slot against the one selected.

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

Calling convention, symbol name, placement and retention are four
independent choices; none implies another.

**The vector table.** The compiler owns it. Its first word is the initial
stack pointer, its second the compiler's reset, reserved slots are zero,
and `vector` annotations fill in handlers with their types checked. So a
stack address, a reserved word and a handler can never be mixed up. A
vector annotation needs a firmware-entry request ([1650]).

**What survives the link.**

- The table is kept and refers to each handler in it, so those handlers
  survive.
- An interrupt function nothing refers to and nothing keeps can disappear.
- `keep` retains the section that holds the declaration. Several objects
  placed in one section share that retention.
- A link name alone retains nothing.

**Where things go.**

| what | sections |
| --- | --- |
| functions | `.text.*` in flash, or `.ramtext.*`, copied to RAM at reset |
| immutable data | `.rodata.*` |
| mutable data | `.data.*`, or `.bss.*` when zeroed |

- `align` is a power of two up to 256. It places the object and does not
  change its type's layout.
- `align` and `vector` take decimal literals; digit separators are fine,
  hex and expressions are refused.
- `region: "NAME"` places a function or module datum in a region of the
  device description, by name rather than by section. Code needs a region
  that may execute and mutable data one that may be written, and reset
  copies or clears it there.
- Without a device description, the image has the reference firmware
  profile's 32 KiB of flash and 16 KiB of RAM, whose top 4 KiB is
  reserved for stacks; a description gives its own. The linker checks
  bounds and overlap.
- A generic function is a function for each instance, and every instance
  goes to the section, alignment or region it is placed in. A vector slot,
  the boot stage and `keep` each name one function, so a generic one takes
  none of them.
- The compiler refuses reserved vectors, a section that does not match the
  declaration, duplicate attributes and symbol collisions.
- There is no module initialization in user code ([1460]).

**A second boot stage.** Some boot ROMs run a second stage before the
image: RP2040's reads its flash through one. On such a chip that stage
lives in the device description, as a naked function marked
`link(boot_stage)`. The description's boot kind places it at the start of
the image, and the compiler seals it with the checksum the ROM checks.
Nothing else is marked that way, and nothing else in a description is
code.

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

**A selection** is a union that gives each atom its encoding. The encoding
belongs to the union, not to the atom, so the same atom may be encoded
differently in another register. The width is the smallest that holds the
largest encoding; write a base type only when the datasheet gives the
field more room than it needs.

```landin
polarity: type = (active_low = 0 | active_high = 1) -- one bit
clock_mode: type = (internal = 0 | external = 1 | pll = 4)
divider_sel: type = u4 (by_1 = 0 | by_2 = 1) -- four bits, as given
```

**A set** is a packed struct of `bool`, one field per member, each at the
bit its member's encoding names.

- Membership is a field read.
- Adding or removing a member is a field write.
- Building one is an ordinary struct literal with `of` ([0720]).

There is no set literal or set operator, because a struct needs none.
Inside a larger image the same fields sit at the image's bits, offset by
where the set begins.

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

**Positions are written.** Bit positions are never implied by field
order, so reordering the fields of a published register is not a hidden
breaking change. In a packed struct every field carries a position, or
none does. Any bit no field claims is reserved: you cannot name it, no
completion list offers it, and a read-modify-write leaves it untouched.

**You rarely write these by hand.** A generator reading a vendor's System
View Description (SVD) file writes the fields, and the helpers [0740]
uses, for every register: `refine svd` generates them
([devices](devices/README.md)), and running a generator as a step of a
build belongs to the companion tool. The language has no `set(X)` type
former to do it instead.

**A field may be an array**, which is how a real peripheral packs sixteen
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

The operation, not the pointer's type, makes an access a device
transaction: there is no `volatile ptr` and no `register(t, ...)` wrapper
type.

**Changing one field.** You cannot write a single field of a device
register. For an ordinary read/write register, read the whole image,
change it locally and write it back whole. The generator of [0730] writes,
beside `control`, `control_decode` from the raw `u32` to the image,
`control_encode` back, and the constant `control_named_mask`:

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

- A fresh local literal knows nothing of what the hardware holds. To keep
  reserved bits as the device has them, read the image first, as
  `read_modify_write` does; `compiler.preserve` never reads behind your
  back.
- That read, change and write is not atomic.
- The read, change and write does not carry over to clear-on-read or
  one-clears registers: a destructive read consumes state, and a
  one-clears readback is not a command.

**Reset values.** A register's reset value initializes nothing. It is what
the datasheet says the register holds after a reset, generated as a
constant so that tools and readers know where they start. The hardware
puts it there, not the program.

Exact rules: spec [1870].

### [1650] Where a program starts

A hosted program starts at `public main: () -> (code: i32)` in the entry
module, and `code` is the exit status, passed through the system's C ABI.

**Arguments.** The arguments are not parameters. You ask the host for
them, as `io.argument_at(host, 0)` does in "Reading a file" at the top:
the host keeps the argument table and lends each argument as a host string
([1660]). The first argument is the one after the program's own name. C's
`argc` and `argv` shape could not be indexed in Landin without turning a
pointer into a slice, which Landin does not do ([0500]).

**The C library.** A Linux executable needs no C library. It starts at
`platform/linux`'s `_landin_start`, which calls `main` with the process's
arguments; `--link=libc` links the C runtime instead. Darwin and FreeBSD
always link their C library.

**The argument root.** A program that imports `hosted/system`, directly or
through `hosted/blocking`, imports `platform/posix` with it. Its entry
then first calls this C-callable function with the real values, before the
body of `main` begins, so the environment is kept beside the arguments and
lent the same way:

```text
void _landin_host_initialize_arguments(int argc, char **argv, char **envp);
```

When C owns `main` and calls exported Landin functions, it calls that
function itself, with its own `envp` or C's `environ`:

- Call it before `blocking.new()` acquires an argument capability, and
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

**Freestanding.** There is no `main`. The compiler request names the
entry: an infallible ordinary `() -> none` or `() -> noreturn` function, or
a naked `() -> none` one, in the entry module ([1630] shows the request).
The compiler's reset initializes RAM before calling it. Returning from it,
or a failed check, traps, since there is no hosted exit to go to. General
build and package orchestration are outside the firmware path.

**An image loaded into RAM.** For a debugger-loaded SRAM image, select
`--firmware-layout=ram`. The compiler derives RAM placement from the same
device description, retains BSS clearing and skips copies of data already
in place. The board tool establishes the device state before entry. The
default `boot` layout keeps the image its boot ROM needs; a RAM run does
not test that boot path.

Exact rules: spec [1975] for hosted programs, spec [1990] for firmware.

### [1660] Where capabilities come from

The entry point is the usual place to make the program's roots — the host,
an allocator, a diagnostics log — and pass them down as ordinary arguments.
The language does not reserve that to the entry point: any function can call
the constructors ([1680]).

What a root imports:

- A hosted root imports `hosted/blocking`, whose reads, writes, network
  calls and sleeps block the thread until they are done.
- A program that serves several things at once imports `hosted/events`
  instead, whose waits let other fibres run ([1675]).
- A program that never reads, writes or sleeps may use `system.new()`
  alone; it is not a world, since it cannot read or write.
- A caller-backed root needs only `core/io`.

`hosted/blocking` and `hosted/events` are both built over `hosted/system`,
which keeps everything that does not wait: the arguments and environment,
opening and closing files, directories, running programs, entropy and the
wall clock.

This is the essential flow of `examples/derived_hosted`, a complete log
filter. Its `main` is one line, `code = app.entry()`, and the work starts
in `entry`, a public function of the program's own `app` module. That
module imports `hosted/blocking`, `hosted/heap`, `core/region`, `core/diag`
and `core/io`, and `run_logged` is the application's function that does
the work:

```landin
public entry: () -> (code: i32) =
    host := blocking.new()
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

**Roots are handles.** Each root is a small value, copied and passed by
value, that refers to its state.

- `blocking.new()` and `heap.new()` borrow nothing, because what they refer
  to belongs to the process: the argument root, the descriptors, the last
  errno and the heap. `blocking.new()` acquires the real argument table; it
  does not create or copy it ([1650]).
- A caller-owned provider is made from state the caller declares, as the
  region is made from `ledger`. The handle cannot outlive that state, and
  the state cannot be released while the handle is still used.
- An erased capability is built from the address of a handle binding, and
  its dispatch copies the handle from there. So `world`, `writer` and
  `host` itself can be used side by side, and nothing is locked.

**Handing it something else.** Because the code below the root only sees
what it is handed, you can hand it something else. A test gives the same
`run_logged` an in-memory world from `core/io`'s `io.memory_over`, which
takes caller-owned files, arguments and output storage and makes no host
call, and the run cannot tell.

That works because I/O is a concept, not a type, so another provider can
satisfy it. It travels as `any` rather than as a type parameter: an
indirect call costs next to nothing beside the system call behind it. An
allocator sits in hot loops, so it is passed as a type parameter instead.
The machinery is the same, chosen case by case ([1690]).

**Four concepts.** I/O is four concepts, because a provider
should supply only what it has ([1260]):

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
implements `writer` and nothing else.

A diagnostics log asks for `any io.writer`, which is why `entry` builds
one from the same `host`: an `any io.world` is not an `any io.writer`, and
neither converts to the other. A function holding only an erased world can
go on in either of these ways:

- pass it as it is to a function generic over a writer, or
- make an `any io.writer` from the adapter `io.writer_of(world)` lends it.

**Arguments and paths.** Both providers lend each argument and path as a
`text.host_string`: the bytes the system gave, unconverted and uncopied,
so an argument passed on as a path reaches the system unchanged, whether
or not it is UTF-8. Neither provider's arguments include `argv[0]`.

The library reference describes the system providers (`hosted/system`,
`hosted/blocking` and `hosted/events`), the memory provider and host
strings (`core/io`, `core/text`). The exact provider contracts — errno
capture, whole and partial writes, retries, `same_file` — are in
spec [1975].

### [1670] When a check fails

When a check fails — an index out of range, an overflow, a bad conversion,
an `unreachable`, a fibre's stack run out ([1675]) — the program calls a
fixed handler that never returns. With none of your own, a hosted program
writes one line, `FILE:LINE:COLUMN: trap: KIND`, to standard error and
stops; firmware just stops.

To replace the default, declare a public `panic_handler` of exactly this
shape in the entry module:

```landin
import core/panic

public panic_handler: (kind: panic.panic_kind, site: u32) -> noreturn =
    loop do
    end loop
end panic_handler
```

It gets two scalars and no strings:

- `kind` is one of `core/panic`'s `out_of_range`, `overflow`,
  `bad_conversion`, `unreachable` and `stack_exhausted`.
- `site` is a plain `u32`, not [1040]'s `site` struct: a number the
  compiler gives the failing operation and its check family.

File and line live in an optional table outside the target, so a small
firmware image carries no file names. `refine --panic-map` writes that
table. `refine site PROGRAM SITE` resolves a site against the build that
made it, and only that build.

Fine print:

- The handler must have exactly this infallible form and atom domain. A
  linker symbol of the same spelling does not replace it.
- A failed check does not unwind: the failed computation's `defer` and
  cleanup do not run.
- Entering the handler a second time traps, including a check that fails
  inside it.
- Caller coordinates are a separate value ([1040]).
- Hardware faults and naked assembly keep their machine obligations.

Exact rules: spec [1960].

### [1675] Two things in flight: fibres

Concurrency is a capability, like an allocator or the host ([1660],
[1680]). There is no `async`, no second calling convention and no
coloured function type. A function that wants two things in flight asks
for something that runs them, and whether they really overlap is that
provider's answer, not the function's. Each one runs on a stack of its own,
a fibre.

**A task** is an ordinary function. It takes its state `inout` and fails
with `core/failure`'s set, and nothing in it knows it runs on a fibre:

```landin
answers: type = struct
    order: [2]u8
    count: usize
end answers

asking: type = struct
    clock: any time.clock
    wait: u64
    tag: u8
    heard: ptr mut answers
end asking

ask: (inout self: asking) -> none ! failure.reason =
    if self.wait > 0 then
        self.clock.sleep(time.milliseconds(self.wait))
    end if
    self.heard.val.order[self.heard.val.count] = self.tag
    self.heard.val.count += 1
end ask
```

**A group.** A function starts tasks as a group, over storage it lends, and
waits for them before it goes on, so whatever they borrow from it outlives
them:

```landin
ask_both: (runs: any fibre.scheduler, clock: any time.clock,
           inout heard: answers) -> none ! failure.reason =
    mut stacks: [2 * 8192]u8 = zeroed
    mut asks := try fibre.group_over(runs, stacks, 2)
    defer fibre.join(asks) else none
    a: asking = (clock: clock, wait: 20, tag: u8('a'), heard: addr heard)
    try fibre.admit(asks, ask, a)
    b: asking = (clock: clock, wait: 0, tag: u8('b'), heard: addr heard)
    try fibre.admit(asks, ask, b)
    try fibre.join(asks)
end ask_both
```

- `group_over` cuts the backing into two equal stacks. Nothing is
  allocated: the stacks are the caller's bytes, and the group comes `from`
  the provider and the backing ([0790]).
- `admit` waits for a free stack, copies the state onto it as a call
  passes an argument, and starts a fibre that calls `ask` with the copy.
  One group can hold tasks with different state types.
- `join` waits until every task has ended, then fails with the first
  failure any of them had. Nothing cancels a fibre, so the others run to
  their own ends first.
- A group must be joined before its backing goes. The `defer` does that
  on every way out, as it releases a region ([1660]); the compiler does
  not check that you wrote it.
- The state is kept in the group until its task ends, so `admit` takes it
  `escaping into` the group ([0780]). `a` may point at `heard`, a
  parameter of the function that made the group; a local declared after
  the group is refused.

**Providers.** Two concepts say what a provider is:

- A `fibre.scheduler` may run each task to its end inside `admit`, before
  returning.
- A `fibre.turns` is a scheduler with `yield`, and promises more: a fibre
  that yields lets every other unfinished fibre of its provider run before
  it goes on.

The blocking host and `fibre.whole` are schedulers. Over either of them,
`a` sleeps its 20 milliseconds and is answered first. `stacks.round`, a
round of fixed turns from `core/fibre/stacks`, provides `turns`. Give it
a clock whose sleep takes a turn for each millisecond, and `b` is answered
while `a` waits:

```landin
turning_sleep: (self: turning, span: time.duration) -> none =
    deadline: u64 = self.reading.val + u64(span)
    while self.reading.val < deadline do
        self.runs.yield()
        self.reading.val += u64(time.milliseconds(1))
    end while
end turning_sleep
```

One `ask_both`, three providers, and the answers are `ab`, `ab` and `ba`.
So a program written against `scheduler` must be right when every task
runs to its end as it is admitted. A program that needs turns says so:
`fibre.turns_over` takes an `any fibre.turns`, and handing it the host or
`whole` is refused where the group is made, not when a task waits for
ever.

**Choosing a provider on a hosted system.** The choice is made where the
roots are minted ([1660]), and the functions below never learn it:

| provider | a call that waits | groups | signals |
| --- | --- | --- | --- |
| `hosted/blocking`, `blocking.new()` | blocks the thread | `scheduler`: each task to its end | none: SIGTERM ends the process |
| `hosted/events`, `events.over(state, entries)` | lets the other fibres run while epoll or kqueue waits | `turns` | `core/io/signal`'s `signals` |

`events.over` takes a space the caller declares and a round's table, one
entry more than the fibres unfinished at once. A signal is an event a
fibre waits for with `next_signal`, so only a provider of turns gives
one: over the blocking host a fibre waiting for SIGTERM would hold the
program before it served anything.

**Fibres are cooperative.** A fibre gives the core away only inside a call
to its provider, a `yield` or a call that waits, and nothing preempts it.
The fibres of one provider are one execution context: between two such
calls no other fibre of it runs, so a module counter or the last error a
call left is not raced for. A switch is a full compiler memory boundary,
and a fibre never moves to another thread.

**A fibre's stack does not grow.** In a program that prepares a stack, a
function compares its frame with the current stack's limit before it
reserves the frame; the few that skip the check, small ones that call
nothing, fit in a margin kept for them. Past the limit, the function traps
`stack_exhausted` at its own declaration, before it has written below the
stack ([1670]):

```text
main.ldn:15:1: trap: stack_exhausted
```

- The limit stands a margin above the stack's lowest byte, room for the
  handler to run in: 640 bytes on x86-64 and arm64, 768 on RV64, 384 on
  Cortex-M0.
- A program that prepares no stack has no check, and its code is what it
  would be without fibres.
- How deep a task goes depends on the target: `ask` takes up to 4.4 KiB of
  its stack on RV64 and less on the others, which is why its stacks are
  8 KiB.
- `refine compile --stack-report=PATH` writes each function's frame and the
  deepest stack its calls can reach, and names the `any` calls, recursion
  and foreign calls that leave that open. Size a stack from its task's row
  and the margin.
- A backing too small for its stacks fails `mem.out_of_memory`, where the
  group is made or when a task is admitted.

**On one core** nothing runs at once, so there fibres are for structure:
one takes the next request while another answers this one. A single-core
device answers requests one at a time, in the order they arrived, and says
`busy` when its queue is full; two answers are never in flight together.

On Cortex-M0 a fibre runs on the process stack and interrupt handlers on
the main one, so a fibre's backing pays for one exception frame, 36 bytes,
and the handlers' own frames are the main stack's. A handler never
switches: it records what happened, and the provider looks before it
waits.

**Writing a provider.** An application makes a group, and at most a
provider, as the round above. `core/fibre/stacks` also holds the switch,
`prepare` and `switch` over records a provider keeps, for whoever writes a
provider of their own, built on two `compiler` builtins.

- A program over `whole` or the blocking host imports no switch and runs
  on every target.
- The switch runs on every target with a native backend.
- A debugger's backtrace through a switch shows `landin.stack_switch`, and
  a fibre's frames end at `landin.stack_start`.

The library reference describes `core/fibre` and `core/fibre/stacks`.

Exact rules: spec [1995].

## THE PRINCIPLES BEHIND THE DECISIONS

A few rules explain most of Landin's choices. When something in the tour
surprises you, one of these is usually why.

### [1680] Pass the capability, don't track the effect

Landin has no effect system. A function that does I/O, allocates or reads
the clock takes the thing that does it as a parameter: an allocator, an
`io` writer, a peripheral handle, a random source. A caller can then hand
it an in-memory world or a bounded allocator.

The parameter list says what a caller supplies, not everything the call
can reach:

- Any hosted function may call the public host and heap constructors
  itself.
- A driver may make a pointer from an address [0460].

Creating the roots in `main` [1660] is a convention the compiler does not
check.

If you need to know that a call tree does no host I/O, read its calls and
imports.

Exact rules: spec [1975].

### [1690] One mechanism, read two ways

Generic code and `any` share one foundation: evidence that a type satisfies
a concept. Static generics and runtime dispatch are two readings of one
feature, not two features ([1310], [1370]):

- When the compiler knows the concrete evidence, it may specialize the
  call.
- Otherwise the call goes through a table, and an `any C` value carries
  that table with it.

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
entry lists, and only in the region where it is written. It tells the
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
- no header parsing inside the compiler (`refine bindings` asks Clang what a
  header declares)

## WHAT IS STILL OPEN

Open work is listed in [ROADMAP.md](ROADMAP.md), not here. That includes
what this tour leaves parked: structure-of-arrays [0620], affine values
[0910] and restricting where capability roots are created [1680].

`refine` implements the whole of this pre-v1 language, and [the
README](README.md#current-compiler-capabilities) says what it does today.
Production status, release versioning, package acquisition and
self-hosting are not part of the current plan.

Version 0.2.9 — what each version changed is in
[the handoff](handoff.md#versions).

Warnings are the compiler's observations about legal source, never extra
language rules. You can select, suppress or deny them by code. A denied
warning fails that compilation, and the program stays legal Landin all the
same. The compiler never warns about shadowing; it does warn about a
declaration that takes a predeclared type's name, such as a local named
`u8`, because no type written where that name reaches can then mean the
type.

### [0620] Storing a collection field by field (deferred)

DEFERRED: not in Landin yet; it is planned (Language evolution, in
[the roadmap](ROADMAP.md)).

A collection could be stored transposed: one array per field instead of
one array of structs, so that one field of every element is a contiguous
slice. It would be written `soa [4096]entity`.

The feature touches aliasing, generics, slicing, `addr`, layout, debug
information and the optimiser all at once, and no program has needed it
yet. Until one does, generate the arrays with a program that writes the
source ([1540]).

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
  Stackful fibres are the route to take instead, since taken [1675],
  and the design
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
