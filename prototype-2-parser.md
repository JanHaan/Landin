## LANDIN PROTOTYPE 2 — A PARSER FULL OF RECOVERABLE ERRORS

```landin
Current with specification 0.1.0. Its own findings Y1-Y7 are all
resolved below.

The point of this one is the word recoverable. A parser must not stop
at the first mistake: it reports it, skips to somewhere it trusts, and
carries on, so that one missing brace does not hide the other twelve
errors in the file. Landin has fail and try, and both of those leave.
So the interesting question is what the other kind of error looks like
in a language with no exceptions.

The answer this prototype argues for: a diagnostics log is a
capability. A function that was given one can report; a function that
was not, cannot. No effect system, no global error list, just an
argument — which is principle [1680] doing real work.
```

---

## core/text  —  the parts this file leans on

utf8       distinct []u8
position   an opaque byte offset into a utf8
utf8 is indexable (Idx: position, Item: []u8, get: ...)
utf8 is iterable  (Cur: position, Item: u32, ...)

## config/diag  —  the diagnostics log

```landin
import core/io
import core/text

public severity: type = (warning = 0 | error = 1)

public entry: type = struct
    where: text.position
    kind:  severity
    what:  utf8
end entry

```
A concept and not a type, for the reason prototype 4 later found
out the hard way about Io: a concrete type means nothing else can
be put in its place, and then a test cannot collect what a run
reported. It also took a type parameter out of every function that
reports, since none of them has to name the log's capacity any
more.
```landin
public log: type = concept (D: type)
    note:   (inout d: D, where: text.position, kind: severity,
             what: utf8) -> none
    failed: (d: D) -> (yes: bool)
end log

```
One implementation: a fixed-capacity list, because this runs in a
place where an unbounded one would be the wrong shape. Overflow is
not an error: past the limit it counts and stops storing, since
the twentieth message helps nobody.
```landin
public bounded: type (N: fixed u32) = struct
    notes:   [N]entry
    stored:  usize
    dropped: usize
end bounded

bounded_note: (inout d: bounded(N), N: fixed u32,
               where: text.position, kind: severity, what: utf8)
               -> none =
    if d.stored < N then
        d.notes[d.stored] = entry(where: where, kind: kind, what: what)
        inc d.stored
    else
        inc d.dropped
    end if
end bounded_note

bounded_failed: (d: bounded(N), N: fixed u32) -> (yes: bool) =
    yes = false
    for i in 0..<d.stored do
        if d.notes[i].kind == error then
            yes = true
        end if
    end for
end bounded_failed

```
A constructor and not zeroed: severity is a named value set, and

### [0540] does not let one of those be written as zeroed

does not let one of those be written as zeroed, nor an
aggregate holding one. So the empty note has to be spelt.
```landin
blank: entry = (where: text.nowhere, kind: warning, what: "")

public new_log: (fixed N: u32) -> (d: bounded(N)) =
    d = (notes: [of blank], stored: 0, dropped: 0)
end new_log

(N: fixed u32) bounded(N) is log (note: bounded_note,
                                  failed: bounded_failed)

```
And a second one, so the concept is doing work rather than
posturing: print them as they arrive, for a tool that has
somewhere to print to.
```landin
public streaming: type = struct
    where_to: io.file
    count:    u32
end streaming

public to: (f: io.file) -> (d: streaming) = ... end

stream_note: (inout d: streaming, where: text.position,
              kind: severity, what: utf8) -> none = ... end
stream_failed: (d: streaming) -> (yes: bool) = d.count > 0 end

streaming is log (note: stream_note, failed: stream_failed)

```

## config/lex

```landin
import core/text

public ident:    atom
public number:   atom
public string:   atom
public lbrace:   atom
public rbrace:   atom
public equals:   atom
public newline:  atom
public end_of_input: atom
public bad_char: atom

public kind: type = ident | number | string | lbrace | rbrace
                  | equals | newline | end_of_input | bad_char

public token: type = struct
    what:   kind
    begins: text.position
    ends:   text.position
end token

public lexer: type = struct
    src: utf8
    pos: text.position
end lexer

public open: (src: utf8) -> (l: lexer) =
    lexer(src: src, pos: text.first(src))
end open

```
No error channel here at all. A character the lexer does not know
becomes a bad_char token and the file goes on. Lexing is one of
the places where failing is simply the wrong answer.
```landin
public next: (inout l: lexer) -> (t: token) =
    skip_blanks(l)
    start := l.pos

    if text.at_end(l.src, l.pos) then
        t = token(what: end_of_input, begins: start, ends: start)
        return
    end if

    (cp) := text.decode(l.src, l.pos)

    t = match classify(cp)
        letter: begin
            take_while(l, is_ident_char)
            token(what: ident, begins: start, ends: l.pos)
        end
        digit: begin
            take_while(l, is_digit)
            token(what: number, begins: start, ends: l.pos)
        end
        quote:      lex_string(l, start)
        open_brace: single(l, lbrace, start)
        close_brace:single(l, rbrace, start)
        assign:     single(l, equals, start)
        eol:        single(l, newline, start)
        _:          single(l, bad_char, start)
    end match
end next

```

## config/parse

```landin
import core/text
import core/arena
import config/lex
import config/diag

```
These are the failures that end the parse. There are exactly two,
and neither is a syntax mistake: syntax mistakes are reported and
recovered from. That distinction is the whole design.
```landin
public out_of_memory: atom
public too_deep:      atom

public value_kind: type = struct
    name: utf8
    body: variant
        text_value:  (s: utf8) |
        int_value:   (n: i64) |
        group_value: (items: []mut ptr mut value_kind)
    end body
end value_kind

public parser: type = struct
    lx:    lex.lexer
    look:  lex.token
    depth: u32
end parser

max_depth: u32 = 32

```

---

Recovery. When a statement is broken, throw tokens away until the
next thing that is certainly a boundary, and carry on from there.
This is why the log exists: the mistake is recorded, the parse
keeps its place.

---

```landin
recover_to_boundary: (inout p: parser) -> none =
    loop do
        break when p.look.what == lex.newline
        break when p.look.what == lex.rbrace
        break when p.look.what == lex.end_of_input
        advance(p)
    end loop
end recover_to_boundary

expect: (inout p: parser, inout d: any diag.log,
         want: lex.kind, what: utf8) -> (ok: bool) =
    if p.look.what == want then
        advance(p)
        ok = true
    else
        d.note(p.look.begins, diag.error, what)
        ok = false
    end if
end expect

```

---

One entry. It returns whether it produced something, rather than
failing, because a broken entry must not end the file.

---

```landin
parse_entry: (inout p: parser, inout d: any diag.log,
              inout a: arena)
              -> (v: ptr mut value_kind, got: bool)
              ! out_of_memory | too_deep =

    got = false
    v = try mem.new(T: value_kind, a: a)

    if p.look.what <> lex.ident then
        d.note(p.look.begins, diag.error, "expected a name")
        recover_to_boundary(p)
        return
    end if

    v.val.name = text.slice(p.lx.src, p.look.begins, p.look.ends)
    advance(p)

    if not expect(p, d, lex.equals, "expected '='") then
        recover_to_boundary(p)
        return
    end if

    match p.look.what
        lex.string: begin
            v.val.body = text_value(s: literal_text(p))
            advance(p)
            got = true
        end
        lex.number: begin
            n := parse_int(p) else (e)
                d.note(p.look.begins, diag.error,
                            "number out of range")
                recover_to_boundary(p)
                return
            end parse_int
            v.val.body = int_value(n: n)
            advance(p)
            got = true
        end
        lex.lbrace: begin
            fail too_deep when p.depth >= max_depth
            inc p.depth
```
defer and not a plain dec: the try below can leave,
and the caller recovers from too_deep and carries on,
so a depth that was not put back would leak upward
and every later group would look too deep.
```landin
            defer dec p.depth
            items := try parse_group(p, d, a)
            v.val.body = group_value(items: items)
            got = true
        end
        _: begin
            d.note(p.look.begins, diag.error,
                        "expected a value")
            recover_to_boundary(p)
        end
    end match
end parse_entry

```

---

The whole file. Note that it does not fail on a syntax mistake:
it returns whatever it managed to build, and the caller asks the
log whether the result is trustworthy.

---

```landin
public parse_file: (src: utf8, inout d: any diag.log, inout a: arena)
                    -> (items: []mut ptr mut value_kind)
                    ! out_of_memory | too_deep =

    mut p := parser(lx: lex.open(src), look: first_token(src), depth: 0)
    mut list := vec.new_list(T: ptr mut value_kind)

    loop do
        break when p.look.what == lex.end_of_input

        if p.look.what == lex.newline then
            advance(p)
            continue
        end if

        (v, got) := parse_entry(p, d, a) else (e)
            fail e when e == out_of_memory
            d.note(p.look.begins, diag.error,
                        "nested too deep, skipping")
            recover_to_boundary(p)
            continue
        end parse_entry
        if got then
            try vec.push(list, a, v)
        end if
    end loop

    items = vec.used(list)
end parse_file

```

## app  —  hosted, and the shape of a whole run

```landin
import core/io
import config/parse
import config/diag

```
The world is a parameter, not a module member: naming it 'io'
here would shadow the module of the same name and every call in
the body would read a field of the parameter instead. arena is
built in, so there is nothing to import for it.
```landin
run: (inout w: any io.world, path: utf8) -> (code: i32) =
    code = 0

    arena scratch do
        src := io.read_file(w, scratch, path) else (e)
            io.write_line(w, "cannot read that file")
            code = 2
            return
        end read_file

        mut notes := diag.new_log(N: 64)
        d := any(addr notes)

        items := parse.parse_file(src, d, scratch) else (e)
            match e
                parse.out_of_memory: io.write_line(w, "out of memory")
                parse.too_deep:      io.write_line(w, "nested too deep")
            end match
            code = 3
            return
        end parse_file

```
Both views of one value: the concept for reporting, the
concrete type for reading back what was stored.
```landin
        for i in 0..<notes.stored do
            n := notes.notes[i]
            io.write_line(w, format_note(scratch, src, n))
        end for

        if notes.dropped > 0 then
            io.write_line(w, "and more, not shown")
        end if

        if d.failed() then
            code = 1
            return
        end if

        apply(items)
    end scratch
end run

```
What the scratch arena does here is worth spelling out. Every
string the parser cut out of the source, every node it built and
every formatted message live in it, and not one of them is freed
by name. The block ends and all of it is gone at once. Because
the arena is a block, the compiler knows its extent exactly, so
items and src cannot leave: they have frame origin, and returning
them would be refused.

---

## WHAT THIS ONE FOUND

The resolutions below cite the pre-release revisions this
specification passed through, 0.0.1 to 0.0.17, on the way to 0.1.0.
They are kept because when one thing was settled relative to another
still carries information.

---

Y1  RESOLVED at 0.0.12, written into the tour at [0950] with a
    sharper test than this file had. The question is whether the
    thing can be determined from what you already hold: a syntax
    mistake is entirely in the bytes the parser is looking at, so
    check it, report it, recover. Out of memory or a missing file
    hangs on the world instead of on your data, and checking first
    would only be a race. Check what you can foresee, and prefer
    working around it to reporting it; fail is for what cannot be
    foreseen or cannot be dealt with where it happens.

    The original finding, for the record.

    Two kinds of error, and only one of them is the error channel.
    fail is for what ends the work: out of memory, nesting past the
    limit. A syntax mistake is not that, and threading it through
    error sets would make every function fallible and every call a
    try. The sink handles it, and the split reads cleanly.
    This is worth writing into the tour as an idiom, because a
    newcomer will otherwise reach for the error channel and end up
    with a parser that stops at the first mistake.

Y2  RESOLVED, by removing a rule rather than adding one. Parameter
    order does not matter for what may refer to what, the same way
    it does not matter inside a module. The compiler collects the
    names, then resolves the types. One less rule, and it agrees
    with a decision already made elsewhere.

Y3  RESOLVED with it. A fixed parameter is deduced at the call site
    from whatever argument pins it down, exactly as a type parameter
    is; deduction never cared about order.

Y4  Nothing in this file needs a loop label, a break with a value,
    or a complete clause. They were the right features for a search;
    a parser is a different shape. Worth remembering when the fourth
    prototype argues about which control flow earns its place.

Y5  The variant arms are constructed as text_value(s: ...) — a
    variant case used as a constructor, like a type applied to
    arguments. The tour shows variants being matched but never being
    built. It needs an example.

Y6  RESOLVED. An else arm either yields a value or leaves, and the
    ways of leaving now include break and continue, not only return
    and fail. That is the same rule an if-expression arm follows, so
    it removes a special case rather than adding one. The loop in
    parse_file now reports a too-deep group and continues, which is
    what a parser wants and what the placeholder zero was standing
    in for.

Y7  RESOLVED at 0.0.7: writing through a pointer is p.val = x, and
    the tour shows it at [0430]. Allocation is spelt mem.new
    everywhere since 0.0.14.

    The original finding, for the record.

    arena.new returns a pointer whose origin is the arena. Assigning
    into it through v.val.name works, but the tour never shows a
    pointer being written through, only read. The spelling p.val = x
    should appear somewhere.

---
