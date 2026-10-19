# How `refine fmt` lays out a source

`refine fmt` gives every Landin source one layout, and this page shows each of
its rules with a program as written and the same program formatted. It is
derived: D252 in `spec.md` records the decision and what it was chosen over,
and `Landin.Formatting` is the implementation. The test program formats every
example on this page, requires the result shown beneath it, and requires the
result to be formatted already. `check.py` holds each section to one pair of
examples and both to the grammar.

A layout is a decision about space. The formatter never adds, removes or
changes a token, never changes a comment's bytes, never breaks a long line and
never joins two lines. It decides where each line starts, the space between
two things on one line, which blank lines survive and how line ends outside
raw literals and block comments are normalized.
There is no option that changes any of that. `refine fmt --check` writes
nothing and reports every line that is not in the layout, each with the line
as the layout writes it and marked from the column where it differs, a blank
line it removes or a line end it changes; `refine fmt --stdout` writes one
source to standard output in the layout and leaves its file as it is (D359,
D385). A directory given to any of them is the `.ldn` files under it, a
dot-named directory left out.

A file that does not scan or parse is refused with the report a compilation
would give it, and nothing is written. Formatting reads nothing later than the
parse, so a file whose names or types are wrong is formatted all the same.

What `refine fmt` does to bytes no example can show:

| written | formatted |
|---|---|
| a CR LF or a lone CR ending a line outside a raw literal or block comment | LF |
| blanks or tabs at the end of a line | removed |
| a tab in a line's indentation or between two tokens | spaces, as the rules below place them |
| no line end after the last line | one LF |
| blank lines before the first line or after the last | removed |
| a file of nothing but space | an empty file |

The bytes inside a raw literal [0280] and inside a block comment [1780] are
the literal's and the comment's, their line ends included, and never change.
Formatted source can therefore retain CR LF or lone CR line ends inside them.

`refine fmt` writes the formatted bytes into the file it read, the same
file, so that everything the file carries stays with it: its owner and group,
its extended attributes and ACLs, those the caller cannot even list among
them, and every other name a hard link gives it, which sees the formatted
bytes too (D358). It needs no privilege. It follows a symlink to its target,
and needs a writable ordinary file and write permission in that file's
directory, because before the first byte changes it copies the original bytes
into a file beside it, `NAME.fmt-original-` and six characters, and syncs
that copy and the directory. When the new bytes are synced the copy is
removed. A write that fails puts the original bytes back and removes the
copy; one that cannot even do that keeps the copy and says where it is, as a
crash during the write leaves it. Writing clears a set-user-ID or
set-group-ID bit, so the formatter sets it again and reads the mode back; a
file whose bit the caller could not set again, because it is not the owner
or for set-group-ID not in the file's group, is refused before it is
written, as is a Linux file with capabilities, which a write removes. A
read-only file is refused. Each refusal says which of these it met, and
leaves the original bytes as they were. The modification time changes, as
for any write. Concurrent changes to the file while it is formatted are
unsupported, except that one replaced by a rename is refused.

## Rules

### Blocks

A block is indented four spaces from the line its construct begins on, and
the `end` that closes it, and any `else`, `elsif` or `complete` that divides
it, stands on that line's indentation. A construct that opens and closes on
one line stays on it, which is how a guarded trap is written (D436).

```landin
f: (n: i32) -> (r: i32) =
      if n > 99 then compiler.unreachable() end if
  if n > 0 then
        r = 1
   else
      r = 0
      end if
end f
```

```landin
f: (n: i32) -> (r: i32) =
    if n > 99 then compiler.unreachable() end if
    if n > 0 then
        r = 1
    else
        r = 0
    end if
end f
```

### Declarations

A declaration of a module begins at the margin, and one written below its
`link` or `extern` attributes begins where they do.

```landin
    counter: u32 = 0
  link(section: ".data")
    mirror: u32 = 0
```

```landin
counter: u32 = 0
link(section: ".data")
mirror: u32 = 0
```

### Blank lines

A run of blank lines becomes one, and a file neither begins nor ends with
one.

```landin


first: u32 = 1



second: u32 = 2

```

```landin
first: u32 = 1

second: u32 = 2
```

### Space between two tokens

Two tokens on one line are separated by one space, except where the table
below says none. A comma or a colon takes one space after it and none before.

| no space | example |
|---|---|
| inside `(`, `)`, `[` and `]` | `f(a, b)`, `[1, 2]` |
| before a call's, an application's or a pattern's `(` | `f(a)`, `vec.list(u8)`, `[]u8(text)`, `ptr u8(value)`, `some(value):` |
| before an index's or a slice's `[` | `values[0]`, `values[0..<2]` |
| either side of `.`, `..` and `..<` | `a.b`, `0..<n` |
| after a prefix `-` or `~` | `-1`, `~mask` |
| after the `]` of an array or slice type | `[4]u8`, `[]mut u8` |
| either side of an import path's `/` | `import core/mem` |
| before the `(` of `ptr(...)`, `any(...)`, `extern(...)`, `link(...)` and `layout(...)` | `ptr(address)`, `extern(c)` |

Every binary operator, `=`, `:=`, `->`, `!` and `|` has one space on each
side. A type's or concept's formals, a conformance's entries, a recovery's
name and a pointer arm's binding stand one space from what precedes them:
`type (item: type)`, `is log (note: n)`, `else (problem)`, `ptr (p):`. A
prefix `-` keeps a space before another `-`, because `--` begins a comment.
An applied written type keeps its ordinary type spacing and puts no space
before the value argument's `(`: `[]mut u8(value)`, `[4]u8(value)` and
`ptr mut u8(value)`. A function type retains spaces around `->` and joins
the value list to its final return list, as in
`(x: i32) -> (y: i32)(value)`. A parameterized head joins both argument
lists: `tag(u32, 7)(value)`.

```landin
f:(a:i32,b :i32)->(r :i32)=
    r=a*( b+ -1 )-  -a
    x :=values [0 ..< 2]
    y := g (a)
    bytes := [ ] u8 ( text )
    pointer := ptr  u8 (hidden)
    callback := (x:i32)->(y:i32) (wrapped)
    tagged := tag (u32,7) (value)
end f
```

```landin
f: (a: i32, b: i32) -> (r: i32) =
    r = a * (b + -1) - -a
    x := values[0..<2]
    y := g(a)
    bytes := []u8(text)
    pointer := ptr u8(hidden)
    callback := (x: i32) -> (y: i32)(wrapped)
    tagged := tag(u32, 7)(value)
end f
```

### Signatures

A signature continued on another line puts its `->` and its `!` under the
`(` that opens its parameters, and each further `|` of its error set under
the `!`.

```landin
reserve: (item: type, inout value: list(item),
    want: usize)
        -> none
  ! out_of_memory
      | too_large =
end reserve
```

```landin
reserve: (item: type, inout value: list(item),
          want: usize)
         -> none
         ! out_of_memory
         | too_large =
end reserve
```

### Lists

A list continued on another line stands under its first entry when that
entry shares the opening bracket's line, and four spaces in from that line
when the bracket ends it. A closing bracket that begins a line stands where
the opening bracket's line began.

```landin
f: () -> none =
    state = (inner: inner,
        remaining: 3)
    table := [
            1, 2,
          3
      ]
end f
```

```landin
f: () -> none =
    state = (inner: inner,
             remaining: 3)
    table := [
        1, 2,
        3
    ]
end f
```

### Operations

A line that continues an operation, with its operator or with the operand
after one, stands under the operation's left operand. In a condition, after
`if`, `elsif`, `while` or `when`, it stands two spaces in from the line the
condition begins on, so that it is never taken for the block the condition
opens.

```landin
f: () -> none =
    ok = first and second
      and third
    if first
            and second then
        g()
    end if
end f
```

```landin
f: () -> none =
    ok = first and second
         and third
    if first
      and second then
        g()
    end if
end f
```

### Parentheses

Inside parentheses an operation continues under its first operand, one column
past the `(`, because that is where its left operand begins. Outside them a
parenthesized left operand begins at its `(`, so a line that continues the
operation stands under the `(`, or in a condition two spaces in as any other.

```landin
f: () -> none =
    ok = (first
        and second)
    both = (first or second)
        and third
    if (first or second)
            and third then
        g()
    end if
end f
```

```landin
f: () -> none =
    ok = (first
          and second)
    both = (first or second)
           and third
    if (first or second)
      and third then
        g()
    end if
end f
```

### Recovery

A recovery clause's body is indented from the line its call begins on, and
its `end` stands on that line's indentation, however the `else` that opens
it is placed. An `else` that begins a line continues the call, and a bound
recovery in an `if` arm is laid out as it is anywhere else. `else none` has
no body, so it is laid out as the one-value form is.

```landin
f: () -> none =
    block := allocate(state, size)
            else (problem)
            _ = problem
            return
        end
end f
```

```landin
f: () -> none =
    block := allocate(state, size)
        else (problem)
        _ = problem
        return
    end
end f
```

### An `if` inside a line

An `if` that begins inside a line is an expression, and it is laid out from
its `if` rather than from its line: a `then` that begins a line, each `elsif`
and `else` and its `end if` stand under the `if`, and each arm's body four
columns in from it, wherever the `if` stands, an argument's place among them.
One whose first arm's value shares the `if`'s line is a table, each arm on a
line of its own.

```landin
f: (byte: u8, wide: bool) -> (digit: u32) =
    digit = if byte == 48 then 0
        elsif byte == 49 then 1
      else 9
    end if
    digit = if wide and byte > 57
        then 10
        else digit
        end if
    digit = add(digit, if wide then
        16
    else
        0
    end if)
end f
```

```landin
f: (byte: u8, wide: bool) -> (digit: u32) =
    digit = if byte == 48 then 0
            elsif byte == 49 then 1
            else 9
            end if
    digit = if wide and byte > 57
            then 10
            else digit
            end if
    digit = add(digit, if wide then
                           16
                       else
                           0
                       end if)
end f
```

### Other continuations

Any other line that continues a declaration or a statement stands four
spaces in from the line it began on. A line that begins with a `(` whose `)`
is followed by `:=` continues nothing: it is a destructuring binding of its
own [1750], and stands where its block's statements do.

```landin
f: () -> none =
    selected: map.entry(key, item) =
  try map.next_entry(value, position)
end f
```

```landin
f: () -> none =
    selected: map.entry(key, item) =
        try map.next_entry(value, position)
end f
```

### Comments

A comment on a line of its own takes the indentation of the next line of
code, or of the block's body when that line closes the block. A comment
after code on the same line stands one space after it. Nothing inside a
comment changes, and it stays between the same two tokens.

```landin
f: () -> none =
-- first
    g()
      -- still in the block
end f
        -- at the end
h: u32 = 1   -- one
```

```landin
f: () -> none =
    -- first
    g()
    -- still in the block
end f
-- at the end
h: u32 = 1 -- one
```
