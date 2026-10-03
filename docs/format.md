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
two things on one line, which blank lines survive and how every line ends.
There is no option that changes any of that. `refine fmt --check` reports a
file that is not in the layout instead of rewriting it.

A file that does not scan or parse is refused with the report a compilation
would give it, and nothing is written. Formatting reads nothing later than the
parse, so a file whose names or types are wrong is formatted all the same.

What `refine fmt` does to bytes no example can show:

| written | formatted |
|---|---|
| a CR LF or a lone CR ending a line | LF |
| blanks or tabs at the end of a line | removed |
| a tab in a line's indentation or between two tokens | spaces, as the rules below place them |
| no line end after the last line | one LF |
| blank lines before the first line or after the last | removed |
| a file of nothing but space | an empty file |

The bytes inside a raw literal [0280] and inside a block comment [1780] are
the literal's and the comment's, their line ends included, and never change.

Replacement writes a sibling temporary file and renames it only after all
bytes and mode bits have been written successfully. Failures leave the
original bytes intact. The formatter follows symlinks, refuses hard-linked,
read-only or differently owned targets, and needs write permission in the
target directory.
Owner, group and all mode bits are preserved. Files carrying ACLs or extended
attributes are refused without replacement; an inability to establish their
absence is also a refusal. Linux may hide privileged `trusted.*` attributes
from an ordinary caller: when the formatter cannot establish visibility of
that namespace, even a seemingly metadata-free file is refused. This can
prevent native replacement under ordinary user privileges; editor formatting
still returns edits without replacing files. The formatter does not request
elevated privileges. This conservative policy avoids dropping metadata.
Timestamps may change. The file is synced, but the directory is not, so
power-loss durability of the renamed directory entry is not promised.
Concurrent changes to source contents or filesystem metadata are unsupported.

## Rules

### Blocks

A block is indented four spaces from the line its construct begins on, and
the `end` that closes it, and any `else`, `elsif` or `complete` that divides
it, stands on that line's indentation.

```landin
f: (n: i32) -> (r: i32) =
  if n > 0 then
        r = 1
   else
      r = 0
      end if
end f
```

```landin
f: (n: i32) -> (r: i32) =
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
| before a call's, an application's or a pattern's `(` | `f(a)`, `vec.list(u8)`, `some(value):` |
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

```landin
f:(a:i32,b :i32)->(r :i32)=
    r=a*( b+ -1 )-  -a
    x :=values [0 ..< 2]
    y := g (a)
end f
```

```landin
f: (a: i32, b: i32) -> (r: i32) =
    r = a * (b + -1) - -a
    x := values[0..<2]
    y := g(a)
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

### Recovery

A recovery clause's body is indented from the line its call begins on, and
its `end` stands on that line's indentation, however the `else` that opens
it is placed. An `else` that begins a line continues the call.

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

### Tables

An `if` that begins inside a line and gives its first arm's value on that
line is a table: each `elsif`, `else` and its `end if` stand under the `if`.

```landin
f: (byte: u8) -> (digit: u32) =
    digit = if byte == 48 then 0
        elsif byte == 49 then 1
      else 9
    end if
end f
```

```landin
f: (byte: u8) -> (digit: u32) =
    digit = if byte == 48 then 0
            elsif byte == 49 then 1
            else 9
            end if
end f
```

### Other continuations

Any other line that continues a declaration or a statement stands four
spaces in from the line it began on.

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
