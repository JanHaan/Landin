# Exploratory formatting API

> **Status:** Exploratory design note, recorded 2026-08-24. This document is
> non-normative. It is not a decision, roadmap commitment, or accepted
> standard-library surface. `spec.md`, `tour.md`, and `ROADMAP.md` remain the
> relevant authorities; this note is evidence to revisit if executable work
> later needs formatted output.

# A printf-alternative in Landin

Constraints that decide the shape: no varargs, no macros, no compile-time
execution ([1540]), no capture ([1010]), no overloading, no default arguments
([0980]), no implicit conversion ([0310]). Concepts and `any` supply what
varargs would have ([1370]).

The whole API is four names.

```landin
import core/text/fmt (print, say, arg, s)

say(o, "hello, {}", [arg(name)])
say(o, "{} of {} kept ({:.1}%)", [arg(k), arg(n), arg(pct)])
say(o, "{:08x}  {:>24}  {:+}", [arg(word), arg(name), arg(delta)])
```

Against `printf("%s of %s\n", ...)` the tax is `arg(` per argument and one pair
of brackets. That is the irreducible cost of not having varargs, and it buys a
call the type checker fully understands.

## The four names

```landin
public writer: type = concept (T: type)
    put:    (self: ptr mut T, bytes: []u8) -> none
    failed: (self: ptr T) -> (yes: bool)
end writer

public arg:  (T: type is showable, v: T) -> (a: item) = ... end
public s:    (v: utf8) -> (a: item) = ... end      -- for literals; see below
public print: (w: any writer, form: utf8, args: []item) -> none = ... end
public say:   (w: any writer, form: utf8, args: []item) -> none = ... end
```

`say` is `print` plus a newline. Neither can fail: the writer holds the error
and you ask it once, at the place that can actually do something about it.

```landin
mut out := fmt.to_file(f: w.out(), h: w)
o := any(addr out)

say(o, "{} lines", [arg(kept)])
say(o, "{} errors", [arg(bad)])
try fmt.check(out)              -- one try for a whole report, not one per line
```

That is what removed the `try` from every second line of the previous draft.
It is the `ferror` discipline, and it is right here for the same reason [0950]
gives: a failing stdout is not something the caller of a log line can act on.

## Why `arg(x)` and not `x`

`arg` is generic over a concept, so one name covers every printable type
including your own:

```landin
public showable: type = concept (T: type)
    show: (self: ptr T, w: any writer, sp: spec) -> none
end showable
```

`i64`, `u64`, `f64`, `bool`, `u32` as a codepoint, `utf8`, `[]u8` and pointers
conform in core. A text *literal* still needs `s("...")`, because an untyped
literal ([0260]) cannot pin the `T` of a generic parameter — that is the one
wart, and it is one character wide.

Two other spellings were considered and dropped. `[]any showable` costs an
`addr` and an arena per argument, for nothing the concept did not already give.
A closed variant of the eight built-in cases is faster but shuts out user types
unless one case holds an `any` anyway, at which point it is two mechanisms
where one will do — so `showable` alone, and the compiler specialises the eight
common instantiations by [1310] without anyone writing them down.

## The braces carry the spec

Everything `printf` spelled after `%` is spelled inside `{}`, in the order
`{[index]:[fill][align][sign][#][0][width][.precision][kind]}`.

| printf | here | |
|---|---|---|
| `%s` `%d` `%f` | `{}` | the value knows what it is |
| `%-20s` | `{:<20}` | `<` `^` `>` are the three alignments |
| `%08d` | `{:08}` | or `{:0>8}` |
| `%+d` | `{:+}` | `%` -space- `d` is `{: }` |
| `%.3f` | `{:.3f}` | on text, a truncation |
| `%x` `%X` `%#x` | `{:x}` `{:X}` `{:#x}` | `#` adds `0x`/`0o`/`0b` |
| `%o` `%e` | `{:o}` `{:e}` | and `{:b}`, which C never had |
| `%c` `%p` | `{}` | the type already decided |
| `%%` | `{{` | |
| `%2$s` | `{2}` | positional, so a message can be translated |
| `%*d` | `{:{}}` | width taken from the next argument |
| `%hhu` `%lld` | — | gone; there is nothing to promote |

This is the correction to the earlier draft. Putting the spec in the value made
it verbose *and* untypeable in a message catalogue, since a translator cannot
edit an argument list. Where a spec really is computed, `{:{}}` takes it from
an argument and `fmt.as(item, spec)` still exists for the rest.

## Coverage, compactly

```landin
show_off: (o: any writer, r: run) -> none =
    say(o, "{:<24}{:>10}{:>8.1}", [arg(r.name), arg(r.bytes), arg(r.share)])
    say(o, "{} {:+} {:08} {:_}",  [arg(r.n), arg(r.n), arg(r.n), arg(r.n)])
    say(o, "{:x} {:#X} {:o} {:#b}", [arg(r.bits), arg(r.bits), arg(r.bits), arg(r.bits)])
    say(o, "{} {:.3f} {:.6e}",    [arg(r.ms), arg(r.ms), arg(r.ms)])
    say(o, "{} {} 100{{}}",       [arg('x'), arg(r.base), arg(r.ok)])
    say(o, "{2} before {1}",      [s("egg"), s("chicken")])
    say(o, "{:{}}",               [arg(r.n), arg(columns)])
end show_off
```

## Usage

### Hosted entry, and the only `try` in it

```landin
public main: () -> (code: i32) =
    mut h := io.host()
    w := any(addr h)

    arena program do
        mut out := fmt.to_file(f: w.out(), h: w)
        o := any(addr out)

        kept := run(w, program, o) else (e) report(o, e) 0 end
        say(o, "{} lines kept", [arg(kept)])

        code = if fmt.check(out) else 1 then 0 end if
    end program
end main
```

### A diagnostic, with the arguments forwarded

```landin
note(d, at, "L0210", "expected {}, found {}", [s("';'"), arg(spelling(tok))])
```

The format and its arguments travel as two values, so the sink renders to a
terminal or to JSON without a second entry point. That is `vprintf`, for free,
because the argument list was always an ordinary value.

```landin
render: (o: any writer, n: note) -> none =
    print(o, "{}:{}:{}: {}: ", [arg(n.file), arg(n.line), arg(n.col), arg(n.sev)])
    print(o, n.form, n.args)
    say(o, " [{}]", [arg(n.code)])
end render
```

### sprintf, without the buffer question

`counting` and `to_slice` satisfy the same concept, so measuring and rendering
are the same call twice.

```landin
public message: (A: type is allocator, inout a: A, form: utf8, args: []item)
                -> (out: utf8) ! out_of_memory =
    mut size := fmt.counting(needed: 0)
    print(any(addr size), form, args)

    buf := try mem.new_slice(T: u8, a: a, n: size.needed)
    mut into := fmt.to_slice(buf: buf, used: 0, needed: 0)
    print(any(addr into), form, args)

    out = utf8(buf[0 ..< into.used])
end message
```

### The 32 KB end: a fixed buffer, no allocator, no failure path

```landin
status: (inout u: uart, milli: i32, rpm: u32) -> none =
    mut scratch: [64]u8 = zeroed
    mut into := fmt.to_slice(buf: scratch[0..], used: 0, needed: 0)

    print(any(addr into), "t={}.{:03} rpm={:>5}\r\n",
          [arg(milli / 1000), arg(abs(milli) % 1000), arg(rpm)])

    uart_send(u, scratch[0 ..< into.used])
end status
```

Truncation is `into.needed > lenof into.buf`, sitting in the struct rather than
hidden in a return code.

### A hex dump

```landin
dump: (o: any writer, base: usize, bytes: []u8) -> none =
    mut off: usize = 0
    while off < lenof bytes do
        print(o, "{:08x}  ", [arg(base + off)])
        last := min(off + 16, lenof bytes)
        for k in off ..< last do print(o, "{:02x} ", [arg(bytes[k])]) end for
        say(o, "", [])
        off = last
    end while
end dump
```

### Your own types, and containers of them

```landin
meter_show: (self: ptr meter, o: any writer, sp: spec) -> none =
    print(o, "{}m", [fmt.as(arg(f32(self.val)), sp)])
end meter_show

meter is showable (show: meter_show)

(T: type is showable) vec.list(T) is showable (show: list_show)
```

`say(o, "{}", [arg(distances)])` then prints a `list(meter)` — the conformance
binds `T` in front [1250] and reaches the element's own `show` through it, so
nobody writes a case for `list(list(meter))`.

### Testing what was printed

The reason `writer` is a concept: no filesystem, no capture, no golden file.

```landin
test_render: () -> (ok: bool) =
    mut sink := fmt.to_slice(buf: buffer[0..], used: 0, needed: 0)
    render(any(addr sink), a_note())
    ok = text.eq(utf8(sink.buf[0 ..< sink.used]),
                 "main.ldn:12:5: error: expected ';', found 'end' [L0210]\n")
end test_render
```

## Two honest costs

**Arity is a run-time question.** No macros means `"{} {}"` with one argument
cannot be a compile error. Type confusion is gone — each argument is a value
whose own `show` runs — but a miscount has to be handled at run time. Write a
visible `{missing}` into the output rather than failing, and take a
`caller where: site` ([1040]) so a debug build names the call site, with no
macro anywhere. A checked-literal form can be added later without changing any
of this; it would be a compiler feature, not an API change.

**Array literal to slice.** `[arg(a), arg(b)]` is an array ([0530]) where the
parameter is `[]item`, and only `[]mut T -> []T` is a written relaxation
([0440]). Either that rule goes into `spec.md`, or every call site ends in
`[0..]` — a tax on the most-called function in the language. It is a roadmap
item of its own, not a formatting question.

## The small-target subset

If the brace parser is not worth its bytes, drop it and keep `emit`, which
takes the same items and no format string:

```landin
emit(o, [s("adc="), arg(sample), s(" at "), arg(ticks), s("\n")])
```

No placeholder can disagree with its argument, and `print` becomes sugar over
`emit` — which, given who the language is named after, is the right way round.
