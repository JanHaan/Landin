# The Landin specification

This is the normative document. `tour.md` explains the language and this
says what it is; where the two could be read differently, this one decides.
It is deliberately partial and it grows one slice at a time, so it says what
is true today rather than what is intended.

Two things are in here and the difference matters.

**The grammar of the enabled kernel** covers the constructs the compiler
enables today and nothing else, so that what a program may say and what the
compiler will accept are the same sentence. A construct `tour.md` describes
and this grammar omits is not enabled yet, and the compiler says so by
[1830] rather than guessing.

**The rules the tour left unsaid** are everything from [1840] on. They are
not about the kernel and they will not be deleted as it grows: that a
comparison yields a bool, that an immutable binding may not be written, that
a name must be assigned before it is read. The tour teaches by example and a
tutorial omits what a reader supplies for themselves, so each of these was
found by an implementation needing a rule and finding none. Each cites the
sentence it derives from, and the ones that were a decision rather than a
transcription are named as decisions in the register at the end.

## THE GRAMMAR OF THE ENABLED KERNEL

The notation is ordinary: a name in lower case is a rule, a quoted word is
itself, '?' is optional, '*' is none or more, '+' is one or more, '...'
between two quoted bytes is every byte from one to the other, 'any byte' is
exactly that, and parentheses group. Nothing here is a parser generator's
input. The parser is hand written, and this is the agreement it is written
against.

The rules come in two layers, and the difference matters. The lexical layer
reads bytes. identifier, keyword and literal each produce one token; space,
line_end and comment produce no token at all and are discarded where they
are found; the rest of that layer spells out part of one of those and
produces nothing of its own. Every other rule reads the tokens that remain,
and a quoted word or sign in one of them stands for the single token
spelled that way. A token is as long as it can be, comments excepted, whose
opener decides [1780]: 'inc' followed by 'x' with nothing between them is
the one name 'incx', which is why [1750] says what separates two tokens.

### [1740] A program is declarations, in any order

A program is declarations, in any order.
Order inside a module does not matter [0130], so a file is a set of
declarations rather than a sequence of them, and a name may be used
above the line that introduces it. 'public' rides on a declaration
and not on a statement [0090]: what a module exports is decided
where the module is written, never inside a body.
```landin-grammar
program     ::= declaration*
declaration ::= "public"? (binding | function | type_declaration)

```

### [1750] A source file is bytes

A source file is bytes, a line ends three ways, and space
separates tokens.
A span in a diagnostic names a byte, and every later stage must be
able to point at the same one, so the lexical rules are written
over bytes. A line ends at LF, at CR followed by LF, or at a CR
that is not followed by LF, and a file need not end with one at
all. Text inside a literal or a comment may be any UTF-8 [0260];
nothing outside them may be.
Space is a space byte, a tab, a line end or a comment [1780], and
any run of them may sit between two tokens. Two tokens whose
spellings would run together into one longer token need at least
one, which is the whole of the rule: 'mut x' is two tokens and
'mutx' is one name. Otherwise space carries no meaning, and no
rule below this layer mentions it.
```landin-grammar
space       ::= " " | "\t" | line_end | comment
line_end    ::= "\n" | "\r\n" | "\r"

```

### [1760] Identifiers are lower case, and no identifier is a keyword

Identifiers are lower case, and no identifier is a keyword.
Every name in the language has this one shape: types, functions,
bindings and fields alike, which is why the tour never needs to say
which case a thing is written in.
Two rules narrow it. A word the keyword rule spells is that
keyword and never a name, so 'if' is not available as a binding;
that one is the tokeniser's. The other is in the rule itself: a
name that starts with '_' needs something after it, so the lone
'_' is the discard of [1020] and nothing may be called it. The
kernel
reserves twenty-two words; the reserved set of the whole language is
larger, and each word joins it with the construct that introduces
it, so a program that avoids a construct never trips over its
keyword. Type names are not among them: u32 and bool are ordinary
declared names [0120] that the kernel happens to predeclare.
```landin-grammar
identifier  ::= lower (lower | digit | "_")*
              | "_" (lower | digit | "_")+
lower       ::= "a" ... "z"
digit       ::= "0" ... "9"
keyword     ::= "mut" | "public" | "if" | "then" | "elsif" | "else"
              | "end" | "return" | "when" | "inc" | "dec" | "none"
              | "true" | "false" | "and" | "or" | "not"
              | "sizeof" | "alignof" | "type" | "struct" | "zeroed"

```

### [1770] The kernel's literals are integers, booleans, and contextual zero

The kernel's literals are integers, the two booleans, and `zeroed` in the
contexts D27, D28, D30, D39 and D40 admit. Integer literals are untyped and take
the type of their context [0190], defaulting to i32 with none [0200]; the bases
and the separator are [0220]'s. `zeroed` has no type of its own: [0540] gives it
the all-bits-zero image of its context. D27/D28 supply an explicitly typed module
or local fixed-array initializer, D30 supplies a fixed-array assignment
destination, and D39/D40 supply an explicitly typed module or local scalar
initializer respectively. Floats
[0210], characters
[0250], text [0260] and raw literals [0280] are described in this tour and are
not enabled yet.
```landin-grammar
literal     ::= integer | "true" | "false" | "zeroed"
integer     ::= decimal | hex | octal | binary
decimal     ::= digit (digit | "_")*
hex         ::= "0x" hex_digit (hex_digit | "_")*
octal       ::= "0o" octal_digit (octal_digit | "_")*
binary      ::= "0b" binary_digit (binary_digit | "_")*
hex_digit   ::= digit | "a" ... "f" | "A" ... "F"
octal_digit ::= "0" ... "7"
binary_digit ::= "0" | "1"

```

### [1780] A comment ends a token, and its opener says which kind it is

A comment ends a token, and its opener says which kind it is.
The three forms are [0010], [0020] and [0030], and their openers
share a prefix, so length cannot tell them apart: the longest
opener decides. '--(' opens a block comment, '---' a doc comment
and '--' a line comment, and the form so chosen decides where the
comment ends rather than the rule that a token is as long as it
can be. A line or doc comment ends at the line end. A block
comment ends at its own ')--', so it may sit between two tokens on
one line, and it nests: a ')--' closing an inner one does not
close it, which is why commenting out a region that already
contains one is not a trap. One never closed runs to the end of
the file and is reported there. A comment is space [1750], so it
may appear wherever a space may.
```landin-grammar
comment       ::= block_comment | doc_comment | line_comment
block_comment ::= "--(" block_item* ")--"
block_item    ::= block_comment
                | any byte that begins neither "--(" nor ")--"
doc_comment   ::= "---" (any byte except line_end)*
line_comment  ::= "--" (any byte except line_end)*

```

### [1790] A binding names one thing, and says how much it may change

A binding names one thing, and says how much it may change.
The full form, the inferred form and the mutable form are [0040],
[0050] and [0060]; a binding with no value must be assigned before
it is read [0080]. The kernel's types are the eleven scalar names and what
[1795] declares from them: several names sharing one declaration
[0100], structs, variants and the rest of TYPES YOU DECLARE are
not enabled yet. A type position holds a name either way, since
[1760] makes the eleven ordinary declared names the kernel
predeclares; the grammar spells them out because they are the
only ones a program does not have to declare for itself.
An array [0520] is a type position too, and its length is part
of it: the bound is [1770]'s integer, written in whatever base,
and the element is a type like any other.
```landin-grammar
binding     ::= "mut"? identifier ":" type ("=" expression)?
              | "mut"? identifier ":=" expression
type        ::= array_type | scalar_name | identifier
array_type  ::= "[" integer "]" type
scalar_name ::= "u8" | "u16" | "u32" | "u64"
              | "i8" | "i16" | "i32" | "i64"
              | "usize" | "isize" | "bool"

```

### [1795] A type declaration names a type, and names nothing new

A type declaration names a type, and names nothing new.
[0120] declares a type like any other value and [0650] writes
'distinct' to make one that is not the type it was written from.
D15 reads the second as deciding the first: without that word a
declaration gives an existing type another name and the two are
one type everywhere. A struct body [0670] has no existing type
to alias and introduces the nominal type [0710] whose identity
is this declaration; an alias of that name keeps the same
identity. Every alias chain has to reach a scalar type or a
struct body. A chain that comes back to an alias in the chain
reaches no type and is refused at that declaration.
A type name is an ordinary declared name [1760], so one
declaration per name per scope [1850] and a name that names
nothing is refused [1860] both hold for it unchanged.
```landin-grammar
type_declaration ::= identifier ":" "type" "=" (type | struct_body)
struct_body      ::= "struct" field+ "end" identifier?
field            ::= identifier ":" type

```

### [1800] A function is a value with a body, and its returns are named

A function is a value with a body, and its returns are named.
'=' opens the body and 'end' closes it [0870]; a body that is one
expression still takes an end, and the expression fills the named
return [0880]; every named return must be assigned before the
function returns [0930]. The error channel [0940], the parameter
conventions [0900], multiple returns [0920], 'escaping' [0780],
generic parameters [1290] and anonymous functions [1010] are all
described in this tour and are not enabled yet: the kernel takes
values in and hands one value or none back.
A body is statements, or it is the one expression that fills the
return. One token past a leading name decides between them: ':'
opens a binding and '=' an assignment, and anything else means the
body is that expression. A function returning none has no
expression form, because there is no return for one to fill.
```landin-grammar
function    ::= identifier ":" signature "=" body "end" identifier?
signature   ::= "(" parameters? ")" "->" returns
parameters  ::= parameter ("," parameter)*
parameter   ::= identifier ":" type
returns     ::= "(" identifier ":" type ")" | "none"
body        ::= statement* | expression

```

### [1810] Statements do one thing each, and only exits carry 'when'

Statements do one thing each, and only exits carry 'when'.
Assignment is a statement and never an expression [0390]; there is
no '++', and 'inc' and 'dec' are statements too [0400]; discarding
a result is written out [1020]; the one-line form of every
construct is [1060]. 'when' rides on an exit and on nothing else,
which is what keeps a conditional statement from having two
spellings.
'return' carries no value. A named return is assigned like any
other place and 'return' leaves [0930], which is why the kernel
needs no second way to say what a function hands back.
A call is a statement as well as an expression, because a function
returning none has nothing to bind and [1020] wants a result
discarded on purpose rather than by omission. A call whose result
is dropped that way is the one place the kernel accepts an
expression standing alone.
A place is [1820]'s selection, so a field of a struct is written
and stepped exactly as the binding holding it is. What may be
written is [1900]'s and not this rule's: a field is writable when
the binding it belongs to is.
```landin-grammar
statement   ::= binding | assignment | increment | discard | call
              | return | if
assignment  ::= place "=" expression
increment   ::= ("inc" | "dec") place
discard     ::= "_" "=" expression
return      ::= "return" ("when" expression)?
if          ::= "if" expression "then" statement*
                ("elsif" expression "then" statement*)*
                ("else" statement*)?
                "end" "if"
place       ::= indexed

```

### [1820] Precedence, tightest first, and comparison does not chain

Precedence, tightest first, and comparison does not chain.
The operators are the ones OPERATORS already decided: [0290] for
arithmetic, [0300] for the wrapping forms,
[0330] for the bitwise set, [0320] for shifts, [0350] for
comparison and [0340] for the logical words. Every binary level
below is left associative, which the repetition in each rule is
what says.
Comparison takes at most one operator, so 'a < b < c' is not a
sentence in this grammar rather than a fold: a chain that read
left to right would compare a bool with a number, and [0310]
refuses that anyway.
A selection is [0420]'s member selection, which the kernel enables
for one member: a field of a struct [0670]. It binds tighter than
every operator because it is part of naming a thing rather than an
operation on one, and it is left to right, so 'a.b.c' selects from
what 'a.b' named.
An index [0570] binds the same way and for the same reason, and it
takes what a selection named: 'a[i]' and 'a.b[i]' are both written
and neither derives from a call, because nothing selects from one
[1820] and nothing indexes one either.
Evaluation order is left to right and fixed [0410], so the table
decides what binds, never what runs first.
```landin-grammar
primary     ::= literal | array_literal | array_repetition | indexed | call
              | measurement | "(" expression ")"
array_literal ::= "[" expression ("," expression)* "]"
array_repetition ::= "[" integer "of" expression "]"
                   | "[" "of" expression "]"
                   | "[" expression ("," expression)* "," "of" expression "]"
indexed     ::= selection ("[" expression "]")*
selection   ::= identifier ("." identifier)*
call        ::= identifier "(" arguments? ")"
measurement ::= ("sizeof" | "alignof") type | "lenof" identifier
              | "lenof" "(" array_literal ")"
arguments   ::= expression ("," expression)*
unary       ::= ("-" | "~" | "not")* primary
product     ::= unary (("*" | "/" | "%" | "*%") unary)*
sum         ::= product (("+" | "-" | "+%" | "-%") product)*
shift       ::= sum (("<<" | ">>") sum)*
conjunction ::= shift ("&" shift)*
exclusion   ::= conjunction ("^" conjunction)*
alternation ::= exclusion ("|" exclusion)*
comparison  ::= alternation (("==" | "<>" | "<" | "<=" | ">" | ">=")
                             alternation)?
logical_and ::= comparison ("and" comparison)*
expression  ::= logical_and ("or" logical_and)*

```

### [1830] What is not enabled is refused, and named

What is not enabled is refused, and named.
A construct this tour describes and this grammar omits is not a
guess the compiler gets to make. Meeting one is a diagnostic that
names the construct and says which work enables it, so a program
written against the whole tour fails with a list rather than with a
parse error. The roadmap owns that list; this grammar owns what is
already true.

### [1840] The kernel's scopes, outermost first

The kernel's scopes, outermost first.
[0130] and [0140] are two sentences about scopes and this
grammar has to say which scopes it has, because a rule about
an inner scope means nothing until the inner ones are named.
| scope | what it holds |
|---|---|
| module | every file compiled together. There is one, until [1410]'s directories arrive. |
| signature | a function's parameters and its named return [1800]. The named return is a place the body assigns [0930], so it is declared here and not in the body, and a parameter and a return may not share a name. |
| body | what a function runs, and one for each arm of an `if` and for its `else` [1810]. A statement run is a block and a block is what scopes [1090], so a name declared in one arm is not visible in another and not after the branch closes. |

[1800]'s expression body opens no scope, because an expression
declares nothing.
Order matters in a body and does not in a module. [0130]'s set
is a set of declarations, so a module name may be used above
the line that introduces it; [1810]'s statement* is a sequence,
so a local is visible to the statements after it and its own
value is read before its name exists [0110].

### [1850] One scope gives one name to one thing

One scope gives one name to one thing.
Two declarations of one name in one scope leave nothing to
choose between them: [0130] says order inside a module does not
matter, so neither is first, and [0140] licenses shadowing
between an inner scope and an outer one and not within one. So
it is refused, and the report names both places.
Shadowing is not this. An inner scope may shadow an outer name
[0140] and nothing is said about it, because a rule that
permits something does not also warn about it.

### [1860] A name that names nothing is refused

A name that names nothing is refused.
There is no implicit declaration in this language: a name that
is not in scope is a misspelling and not a new binding [1250].
The report names the use, because the use is where the mistake
is and the declaration that was meant is not there to point at.

### [1870] The kernel's types, and what each of them holds

The kernel's types, and what each of them holds.
[1790] gives the kernel eleven spellings and nothing that
says what one of them holds, so nothing yet says whether a
u8 may be given 300. [0150] puts the width in the name,
[0160] takes usize and isize from the machine and [0180]
gives bool its two values; written out, that is:
| type | what it holds |
|---|---|
| `u8` `u16` `u32` `u64` | every unsigned value of that many bits |
| `i8` `i16` `i32` `i64` | every signed one, two's complement |
| `usize` `isize` | the same pair, at the target's pointer width [0160] |
| `bool` | false and true [0180] |

Two's complement is not a new decision. [0300]'s wrapping
forms have to wrap somewhere and [0320]'s '>>' keeps a sign,
and neither means anything without it.
Each of the eleven is its own type. usize is not u64 on a
machine whose pointer is eight bytes wide, because if it
were, [0310] would refuse a program on one target and accept
it on another for a reason no paragraph here could state.
[1510]'s 'sizeof usize == 8' asks what a machine does; it
does not say two names are one type.
u128 and i128 [0150], the packed widths [0730] and the
floats [0170] are described in this tour and are not enabled
yet.

### [1880] Where a literal's type comes from, and what a context is

Where a literal's type comes from, and what a context is.
[0190] says an integer literal is untyped, takes the type of
its context and is checked at that point, and [0200] says it
is i32 with none. Neither says what a context is, and a
checker cannot ask for one until they are listed. In the
kernel these positions give a literal a type:
- a binding's declared type [1790]
- the type of the place an assignment writes [1810]
- the type of the parameter an argument fills [1800]
- the named return's type, for an expression body [0880]
- the other operand's type, for a binary operator
- a unary operator's own context, handed on [1820]
- a branch's condition and an exit's 'when', both of which
  want a bool [1050] [0970] and so give an integer literal
  a context it cannot take

and two give none: the inferred form [0050] and a discard
[1020], where [0200]'s i32 is what is left.
A context reaches inward through [1820]'s arithmetic,
bitwise, shift and unary levels and stops at a comparison
and at the logical words. What those give back is a bool
[1890] and a bool says nothing about what was compared, so
'r: bool = 1 | 2 == 3' compares two i32 by [0200] and not
two bools.
A literal whose value the type does not hold is refused
[0190], and the report names the literal.
A unary minus over a literal is part of the value that check
reads, which is what makes 'i8 = -128' the smallest i8
rather than 128 refused and then negated. Nothing else is
folded: 'u8 = 200 + 100' is two literals a u8 holds and a
sum it does not, and [0300] says that traps rather than that
it is refused here.

### [1890] What each operator takes and what it gives

What each operator takes and what it gives.
[1820] settled what binds; this settles what agrees. Every
binary operator takes two operands of one type, because
[0310] converts nothing and there is nowhere else for a
second type to go.
| operator | takes, and gives back |
|---|---|
| `+` `-` `*` `/` `%`, and [0300]'s `+%` `-%` `*%` | one integer type, and that type back [0290] |
| `&` `^` `\|`, and the unary `~` | one integer type, and that type back [0330] |
| `<<` `>>` | an integer shifted by an integer of that same type, and that type back [0320]. The amount is not bounded by the width: [0320] fills with zeros beyond it for any amount. |
| `==` `<>` `<` `<=` `>` `>=` | one type on both sides, and a bool back [0350] |
| `and` `or` `not` | bool, and a bool back [0340] |
| unary `-` | one integer type, and that type back |

So an integer has no logical words and a bool has no
arithmetic and no bitwise set: 'and' is what [0340] gave a
bool and '&' is what [0330] gave an integer, and neither
reaches across. [1820] already read the comparison rule this
way when it said a chain would compare a bool with a number
and that [0310] refuses it.
Two positions want a bool and are not operators: a branch's
condition, which [1050] already says must be one, and an
exit's 'when' [0970], which is the same question asked where
the exit is.

### [1900] What may be written, and what may not

What may be written, and what may not.
[1810]'s place is a name, and of the four kinds of name the
kernel has, two may be written and two may not.
| name | written? |
|---|---|
| a mutable binding [0060] | may be |
| a named return | may be: [0930] says it must be, and [1840] declares it as a place for that reason |
| an immutable binding | may not: [0040] makes it immutable and [0450] says it protects the value it holds |
| a parameter | may not: the unmarked convention is [0900]'s 'in', which is the promise not to change the value |

A function is not a place at all.
The value's type is the place's type [0310], and the report
names the place as well as the value, because which of the
two is wrong is the reader's to decide.
'inc' and 'dec' say what 'x += 1' says [0400], so each wants
a place that may be written and an integer type.

### [1910] Assigned before it is read

Assigned before it is read.
[0080] says a binding declared with no value must be
assigned before use and [0930] says every named return must
be assigned before the function returns. In a body those are
one question and this is its shape: at every read of a name,
at every 'return', and where a body ends, the name has to
have been assigned by every path that arrives there.
No condition is believed. A name assigned in one arm of an
'if' and not in another is not assigned after it, and 'if
true then r = 1 end if' leaves r unassigned, because a
checker that read the condition to decide this would be
running the program in order to check it.
'return when' is a return [1810], so what the function hands
back is assigned above it and not below.
A module binding is not this. [1460] says a value at module
level is known when the compiler reads it, so one written
with no value has no such value, and it is the read that is
refused rather than the declaration.

### [1920] What a call means

What a call means.
[0980] gives no parameter a default value, so a call names
every parameter exactly once and in order, and [1820]'s
argument list is positional only. Each argument has its
parameter's type [0310], and the call has the type of the
named return.
A call of a function returning none has no type. It is a
statement [1810] and nothing else: nothing binds it, no
argument is one, and [1930] cannot discard it, because there
is no result there to discard.
A callee is a function. A name bound to a binding is not
one, and a function's own name anywhere but in front of the
'(' is a value of a function type [1000], which [1790]'s
'type' rule does not spell: [1830] refuses it and names it.
A scalar type name in front of the '(' is [0700]'s
conversion, which [0310] describes and this grammar omits,
so [1830] refuses that by name too. It is not a misspelling
and must not be reported as one.

### [1930] What may be discarded

What may be discarded.
[1020] says a result is discarded on purpose or not at all,
and [1810] writes that '_' '=' expression. Anything with a
type may be thrown away, including a value nobody computed
for the purpose: '_ = 1 + 2' is a discard of an i32 by
[0200], because a rule about wasted work is a rule about
people and this one is about types.
What may not is a call of a function returning none [1920].
Discarding is for a result, and that call has none.

### [1940] A module value is known when the compiler reads it

A module value is known when the compiler reads it.
[1460] says values at module level must be known at compile
time and that nothing runs before the entry point, and the
kernel's version of known is short: a literal, 'true',
'false', an operator of [1820] applied to those, and a name
bound to a module binding whose value is known. Not a call.
There is no compile-time execution in this language, so a
call is not a value the compiler holds, and [1830] refuses
it as the construct it is rather than as a type error.
An operator in a module value is folded, and a fold no type
holds is refused. [0300]'s trap has nowhere to happen here:
[1460] says nothing runs before the entry point, so a module
value that overflows has no moment in which to trap and no
value to stand for it. Inside a body the same expression
traps [0300] and is not this, which is the one place the two
readings of one sum come apart.
[0130] makes a module a set, so one module value may name
another written below it. A chain of them that comes back to
where it began names nothing at all: no member of it is
first, exactly as [1850] found with two declarations of one
name. So it is refused, and the report names the declaration
the chain came back to, because that is the one place in it
the reader is standing.
A binding with no value is known too, and what it holds is
zero — false, for a bool. [0080] lets a binding carry no
value and says it must be assigned before use, and that
sentence has nothing to bite on here: [1460] says nothing
runs before the entry point, so there is no moment at
module level in which to assign one, and [1910]'s walk is
over the paths through a body and there is no body. Zero is
a value the compiler knows, which is the whole of what
[1460] asks. So 'mut counter: u32' is module state a
function updates without an initialiser that says nothing,
and reading one before anything writes it reads zero rather
than being refused, because there is nothing left to
refuse.

### [1950] An operand an operation cannot take

An operand an operation cannot take.
[1890] says every binary operator takes two operands of one
type and gives that type back, and for three of them a
value of the right type is still not one the operation can
use. No paragraph of the tour says what any of the three
does.
| the operation | the operand it cannot take |
|---|---|
| `/` `%` | a divisor of zero [0290] |
| `<<` `>>` | a negative amount [0320] |
| `[ ]` | an index outside the length [0520] |

The third is not a binary operator and belongs here anyway,
because it is the same question with the same answer. [1720]
says this language checks bounds and [0580] says indexing
checks the length before it computes an address, so what was
left unsaid is only which of refusing and trapping applies
where — and that is what the rest of this paragraph already
decides for the other two.
D18 makes an array index `usize`, so a negative expression is refused by
its type before this row applies. The row asks only whether a well-typed
index is below the array's length.

This is not [0300]'s question, and the difference decides
both answers. An overflow is a good operation whose result
the type does not hold, which is why [1880] leaves it to
the trap inside a body. Here the operand is what is wrong
and there is no operation to perform at all, which is the
case [0310] already answered for 'u8(300)': known when the
compiler reads it, it is refused; otherwise it traps.
Known is [1880]'s and [1940]'s and nothing besides — inside
a body a literal, or a unary minus over one; at module
level the whole of [1940]'s fold. So 'x / 0' is refused and
'x / y' traps, and which of the two a program gets does not
move when an implementation gets better at folding, which
is the objection D7 raised against believing a condition.
'a[4]' on a '[4]u8' is refused for the same reason 'x / 0'
is, and 'a[i]' checks its length at run time.
A negative amount is writable only where the left operand
is signed, because [1890] gives the amount that type. No
unsigned shift carries this check, on any target.
At module level a trap is not available at all. [1460] says
nothing runs before the entry point, so a module value
whose divisor is zero has no moment in which to trap and no
value to stand for it, exactly as [1940] found for a sum no
type holds. Both are refused there.
The lowest value of a signed type over -1 is not in the
table, and is not a third rule. Its quotient is the case
[0300] already covers: that type does not hold it, and
[1890] gives '/' no wrapping form to opt out with. Its
remainder is 0, which the type does hold, so nothing traps
and the machines that fault on it anyway are R1.80's and
R5.30's to know about.
The report names the operand and not the operator, because
the zero and the negative amount are what a reader changes.

### [1960] A trap stops at the operation

A trap is synchronous with the operation that causes it and
happens at that operation's point in [0410]'s order. It does
not return. The operation produces no value, and no later
Landin action occurs; actions before it are not undone.
How the surrounding system reports the trap is not Landin
program behaviour. An operating system's signal, exception,
status or other encoding is not stable across targets or
compiler releases and a program may not depend on it.
The Linux x86-64 backend deliberately emits `ud2` when it
must trap. It does not inherit the accidental fault or value
of the machine instruction used for the operation.

### [1970] The first hosted path has one entry shape

The minimal Linux x86-64 path implemented by R1.80 accepts one
hosted entry shape: a public function named `main`, with no
arguments and the one named return `code` of type `i32`. Its
declaration therefore starts
`public main: () -> (code: i32) =`. The returned code is passed
to the host as the program's status through the system C ABI
[1650]. This is the first native slice's boundary, not a
restriction on every hosted executable: [1650]'s C `argc` and
`argv` form stays available. A freestanding program does not
use this rule; its build description names the entry [1650].

## THE DECISIONS THIS DOCUMENT TOOK

A rule above is one of two things, and a reader cannot tell them apart by
reading it: a transcription of something `tour.md` already decided, or a
decision taken because the tour said nothing and an implementation could not
proceed without one. Twelve were decisions. They are listed here with what
the tour said before, what was chosen, and what a competent reader could
have chosen instead — because a decision written in the same voice as a
transcription looks like it was always there, and [1050] was missed twice by
a reader who assumed exactly that.

A decision leaves this register when something closes it: a program that
cannot be written, a target that cannot be reached, or a paragraph of the
tour that turns out to have settled it after all. None has yet.

### D1 — A named return lives in the signature scope

**The tour said** that a named return is assigned like any other place and
that `return` leaves [1810], and that every named return must be assigned
before the function returns [0930]. Neither says which scope declares it.

**Chosen:** the signature's, beside the parameters [1840]. So
`f: (r: u32) -> (r: u32)` is one name declared twice in one scope, and the
body can assign the return from inside any arm.

**The alternative:** the body's scope. Then a parameter and a return could
share a name, and the body would shadow the return rather than assign it.

**Pinned by** `negative/return-shares-a-parameter-name`.

### D2 — Each arm of an `if` is its own scope

**The tour said** nothing. [0140] permits an inner scope to shadow an outer
name and [1090] says a bare block is for scoping, but a bare block is not in
the kernel and no paragraph says an arm opens a scope. The sentence that now
says so is in [1840] and was written here.

**Chosen:** every arm and the `else` is a scope, and they are siblings. A
name declared in one arm is not visible in another, nor after the branch
closes.

**The alternative:** one scope for the whole body, so a binding in an arm
outlives it. Defensible, and it is what a language without block scoping
would do — but then two arms could not use the same local name, which is the
commonest thing a branch does.

**Pinned by** `positive/arm-scopes-are-siblings`,
`negative/name-from-another-arm`, `negative/name-after-the-branch-closes`.

### D3 — Signed integers are two's complement

**The tour said** nothing: the word complement appears nowhere in it. [0300]
gives wrapping operators and [0320] gives a sign-keeping `>>`, and neither
means anything without a representation.

**Chosen:** two's complement, stated in [1870]. So `i8` holds -128 and not
-127, and `-128` is writable.

**The alternative:** leaving it to the target. Then `i8 = -128` would be a
program whose legality depended on the machine, which [0310]'s refusal of
implicit conversion exists to prevent.

**Pinned by** `positive/literal-at-the-widest-value`,
`negative/literal-below-its-type`.

### D4 — `usize` is a distinct type from `u64`

**The tour said** only that `usize` and `isize` are pointer-width integers
[0160]. It does not say whether that makes `usize` a name for `u64` on a
machine whose pointer is eight bytes wide.

**Chosen:** distinct, on every target [1870]. Adding a `usize` to a `u64` is
refused everywhere.

**The alternative:** the same type where the widths agree. That is what a C
programmer expects, and it costs this: a program would compile on
`linux-x86-64` and be refused on a 32-bit target for a reason no paragraph
of the specification could state.

**Pinned by** `negative/usize-is-not-u64`.

### D5 — A typed sibling gives an untyped literal its type

**The tour said** that an integer literal takes the type of its context and
is checked at that point [0190], and that with no context it is `i32`
[0200]. It never says what a context is. That list is in [1880] and was
written here.

**Chosen:** eight positions give a literal a type, and one of them is the
other operand of a binary operator. So in `x + 1` with `x: u8`, the `1` is a
`u8`.

**The alternative:** only a declared type is a context. Then `x + 1` would
make the `1` an `i32` by [0200] and immediately refuse it against `x`, so
every literal in an expression would need a conversion the kernel does not
have. This is the decision with the least room in it, and it is still a
decision.

**Pinned by** `positive/literal-takes-a-sibling-type`.

### D6 — A shift's right operand takes the left operand's type

**The tour said** that shifts fill with zeros beyond the width for any
amount, and that a signed `>>` keeps its sign [0320]. It says nothing about
the amount's type.

**Chosen:** the same type as the value being shifted [1890]. So shifting a
`u8` by 300 is refused, because 300 is not a `u8`, while shifting it by 40
is accepted and yields zero.

**The alternative:** any integer type for the amount, or one fixed type such
as `usize` for every shift. Either would accept `x << 300` and produce zero,
which is what [0320] says an over-wide amount does — so this decision makes
the specification's own example the boundary case rather than the rule.

**Pinned by** `negative/shift-amount-takes-the-left-type`.

### D7 — No condition is believed

**The tour said** that a binding declared with no value must be assigned
before use [0080] and that every named return must be assigned before the
function returns [0930]. Neither says what a checker may conclude from a
condition.

**Chosen:** nothing [1910]. `if true then r = 1 end if` leaves `r`
unassigned, and a branch with no `else` contributes a path that changes
nothing.

**The alternative:** fold constant conditions and believe them. It accepts
more real programs, and it makes a program's legality depend on how clever
the compiler's folding is — so adding an optimisation would change what
compiles.

**Pinned by** `positive/assigned-on-every-path`,
`negative/assigned-on-one-path-only`, `negative/condition-is-not-believed`.

### D8 — A zero divisor is refused when it is known, and traps when it is not

**The tour said** that integer division truncates toward zero and that the
remainder takes the sign of the dividend [0290], and nothing else. It does
not say what a zero divisor does, and [0300] does not reach it: a quotient
that does not exist is not a result that overflowed.

**Chosen:** [0310]'s shape, in [1950]. Refused where the compiler knows the
divisor, trapped where it does not, and refused at module level always.
`%` goes with `/`, because the divisor is the same operand.

**The alternative:** a defined value, which is the only other thing on
offer. AArch64's `SDIV` answers 0 and x86-64's `IDIV` raises a hardware
fault, both measured — so R1.80's target and R5.30's already disagree, and
adopting either would make one program mean two things or make the other
target pay for a value nobody asked for. Leaving it to the machine is the
same alternative D4 refused, in the same words.

**Pinned by** `negative/divisor-is-zero`, `negative/remainder-by-zero`,
`negative/divisor-is-zero-in-a-body`, `positive/divisor-is-not-known`.

### D9 — A negative shift amount is refused when it is known, and traps when it is not

**The tour said** that shifts fill with zeros beyond the width for any
amount and that a signed `>>` keeps its sign, and that there is one form
only [0320]. It says nothing about a negative amount, and D6 is what makes
one writable: the amount takes the left operand's type, so a signed left
operand admits a negative one.

**Chosen:** the same shape as D8, in [1950], so that the two operands no
operation can take are one rule and not two.

**The alternative:** three, and each is some language's answer. Read the
amount as unsigned, so -1 is beyond the width and [0320] already says the
answer is zero — which is exactly what Cortex-M0 does, measured, and it
turns a likely bug into a silent zero. Reverse the direction, which is
Swift's answer, and which [0320]'s "One form only" is the sentence against.
Or mask the amount to the width, which is what x86-64, AArch64, Java and C#
all do, measured on the first two — but [0320] has already declined masking
for over-wide amounts, since it says they fill with zeros rather than wrap
around, so masking here would make one operator answer two ways.

**Pinned by** `negative/shift-amount-is-negative`,
`negative/shift-amount-is-negative-in-a-body`,
`positive/shift-amount-is-not-known`.

### D10 — A module binding with no value holds zero

**The tour said** that a binding may carry no value and must be assigned
before use [0080], and that values at module level must be known at compile
time [1460]. Neither says what one with no value holds, and the two do not
combine: [0080]'s "before use" is a rule about paths through a body, and
[1460] says nothing runs before the entry point, so at module level there is
no path and no moment in which an assignment could happen.

**Chosen:** zero, and false for a bool [1940]. Reading one before anything
writes it reads zero. `positive/binding-declared-only` stays a positive
fixture, and `mut counter: u32` is module state a function updates.

**The alternative:** two, and both were defensible. Refuse a module binding
with no value, on the strict reading that no value is not a known value —
which is tidy, and costs `mut counter: u32 = 0` at every declaration of
module state, where the `= 0` says nothing a reader did not know. Or keep
the declaration and refuse the read, which is [0080] taken literally — but
at module level "before use" is a question about which function runs first,
and that is a whole-program analysis this specification does not have and R1
is not equipped to answer.

**Pinned by** `positive/binding-declared-only`,
`positive/module-binding-with-no-value-reads-zero`.

### D11 — A trap is a deliberate synchronous stop

**The tour said** that overflow traps [0300] and a runtime conversion whose
value does not fit traps [0310]; [1950] adds two operands that trap when their
value is not known. None says where a trap happens, whether it returns, what
follows it, or whether the host's report is program behaviour.

**Chosen:** [1960]. A trap happens at the operation's point in evaluation
order, never returns, and permits no later Landin action. Its operating-system
encoding is not stable. The Linux x86-64 backend uses a deliberate `ud2`, so
the language does not inherit whichever fault or value an arithmetic
instruction happens to provide.

**The alternative:** leave each operation to its machine instruction, or call
a runtime routine. The first has already been ruled out by D8's measured
x86-64 and AArch64 disagreement, and would wrongly trap the defined remainder
of the lowest signed value by -1 on x86-64. The second can give a stable report,
but makes that report an interface the language must preserve and a runtime
every freestanding target must supply.

**What the tour also said, and this does not yet do:** [1670] states the
mechanism a failed check eventually uses — a call to a fixed never-returning
`panic_handler`, taking an atom for the kind and a compiler-assigned `site`
number, with file and line in a side table a constrained build omits. That is
not an alternative this decision declined; it is a paragraph the kernel cannot
reach. `panic_kind` is a `type` over atoms and `noreturn` is a return form,
and [1790]'s type rule enables none of the three, so there is nothing to call
and no way to spell it. `ud2` is what a compiler that cannot write [1670] can
do, and R6.70 is where panic behaviour is implemented; the alternative
declined above is calling a runtime routine *instead of* [1670]'s, not
[1670] itself.

**Evidence:** `runtime/checked-overflow-traps` and
`runtime/a-zero-divisor-traps` run on Linux x86-64 and are held to having
ended without returning a status, which is the whole of what this decision
makes observable. The first is the one that tells a trap edge from no edge:
without it the addition keeps its low byte and the program returns normally.
Neither says which signal ended it, because this decision is what says that
question has no stable answer.

**Future evidence required:** the first slice that enables [0310]'s runtime
conversions must exercise its out-of-range trap through the same contract.

### D12 — The first hosted path accepts one `main` shape

**The tour said** that hosted `main` follows the system C ABI, calls the
no-argument form ordinary and keeps the C `argc` and `argv` form available
[1650]. Its capability-root example has exactly
`public main: () -> (code: i32)` [1660], but an example does not say which
shape the first native slice must implement.

**Chosen:** [1970]. R1.80's minimal Linux x86-64 path accepts one public
no-argument `main` and returns its host status through the one named `i32`
return `code`. This is an implementation boundary for that slice; it does not
remove [1650]'s C form from the language.

**The alternative:** implement the C `argc` and `argv` shape in the first
slice too, permit a different public function to be selected by the build, or
treat the return's name as immaterial. Each is workable, but makes the first
executable slice carry an entry-selection or argument representation rule it
does not need; freestanding builds already have the explicit-entry rule
[1650].

**Future evidence required:** R1.80's hosted entry and exit-status cases.

### D13 — An amount at or past the width gives zero on every shift

**The tour said** two things about a shift that do not agree at the boundary:
that shifts "fill with zeros beyond the width, for any amount", and that
"Signed >> keeps the sign" [0320]. Its example is a `<<`, so it settles
nothing for the one operator where the two sentences meet. D6 makes the
question reachable, since the amount takes the left operand's type and a
signed left operand admits an amount of any size.

**Chosen:** the zeros sentence governs every shift, so an amount at or past
the width gives zero and a signed `>>` is not an exception. `-1i32 >> 31` is
-1 and `-1i32 >> 32` is 0. A backend therefore tests the amount against the
type's own width rather than letting the processor mask the count — x86-64
masks to five bits at 32-bit and six at 64, which is the masking [0320]
already declined for over-wide amounts.

**The alternative:** let "keeps the sign" govern at every amount, so a signed
`>>` saturates to all sign bits and `-1i32 >> 32` is -1. It is continuous
where this rule has a step, and it is what x86-64's `sar` gives for free once
the count is clamped. It was declined because it makes one operator answer
two ways — zeros for `<<` and for unsigned `>>`, sign bits for signed `>>` —
where the tour states the zero-fill rule for shifts as a class and states the
sign rule about which bits `>>` brings in, not about what an exhausted shift
leaves behind.

**Pinned by** `runtime/shifts-fill-with-zeros-beyond-the-width`, whose
`-1i32 >> 32`, `-1i8 >> 8` and `1u64 << 64` are each zero on the hardware.

### D14 — A measurement is a `usize`, and only the target knows it

**The tour said** that `sizeof`, `alignof` and `lenof` measure, and that on
an array or a literal the length is a compile-time value [0370]. It writes
`w1 := sizeof u32` with the inferred form, so nothing in it says what type a
measurement has, and [0200]'s default is about an integer *literal* rather
than about this.

**Chosen:** `usize`. A size and an alignment are counts of bytes on the
machine being compiled for, which is what [0160] says `usize` is for, and a
measurement that defaulted to `i32` would need a conversion at every use
where a width is wanted. `lenof` has the same result type. It takes a direct
identifier naming a fixed array; D31 also admits a nonempty array literal.
Slices and every other general expression operand remain deferred. The
spelling stays contextual rather than joining [1760]'s reserved words.

**Where the answer comes from** is the other half of this decision and the
half with teeth. A scalar `sizeof` or `alignof` is not folded by the checker or
the lowering: `Landin.IR` carries `Measure_Size` or `Measure_Align` with the
type asked about, and the backend answers, because a byte size needs a target.
That is the seam [0320]'s zero-fill already sits on, and it keeps the IR
target-neutral — the same source emits 8 for `sizeof usize` against the Linux
x86-64 description and 4 against the synthetic 32-bit one.

A fixed array is measured from its resolved structural type, whether [1790]
writes it inline or D15 reaches it through aliases. Its size is its element
count multiplied by the target's size for the scalar element, and a nonempty
array's alignment is that element's target alignment. Lowering preserves those
questions as the existing scalar measurement, `usize` Number and Multiply IR;
it adds no array-measurement opcode and asks no host question. The internal
zero-element shape keeps size zero and alignment one; this says what a shape
already representable inside the checker means and does not decide whether
source may spell one.

A fixed array's element count is already part of its type (D17), so `lenof
name` lowers to the existing `usize` Number IR with that count. It does not read
the named storage and does not require the binding to be definitely assigned.

**The alternative:** `i32`, which is what an untyped literal would default
to and so the least surprising answer for a reader who has only read [0200];
declined because it makes the common use — comparing against or multiplying
by a width — start with a conversion. Or folding in the checker, which
would put a target fact in a stage this repository has kept target-neutral
on purpose, and which `Landin.IR`'s own header already argues against for
the shifts.

**Pinned by** `positive/measurement-of-a-type`,
`positive/measurement-of-fixed-arrays`,
`positive/lenof-uninitialized-fixed-array`,
`negative/measuring-refused-types`, `negative/lenof-scalar`,
`negative/lenof-unresolved-name`, `runtime/lenof-named-fixed-arrays`,
`runtime/measurements-answer-for-the-target`, and the backend case that emits
one source against two target descriptions.

### D15 — A type declaration without `distinct` is an alias

**The tour said** that types are declared like any other value with `type`
[0120], and that `distinct` makes a type with the same representation, a
different type and no operations inherited [0650]. It does not say what a
declaration without that word gives.

**Chosen:** another name for the same type. `meter: type = distinct f32` is
the only form that makes a new one, and `count: type = u32` leaves `count`
and `u32` one type: a value of either is a value of the other, everywhere,
with no conversion. The evidence is the word itself: [0650] spells
`distinct` explicitly, and a modifier that changed nothing would not be
written. The tour reaches for it exactly where it wants two types that share
a representation to stop being interchangeable.

**What this does not decide:** a `struct` or `variant` body introduces a
type that is nominal, because there is no existing type for it to be another
name for, and [0710] says a value typed as an anonymous struct "never
becomes a same-shaped named type". That is a different sentence from this
one and R2.20's later slices are where it is implemented.

**The alternative:** every `type` declaration introduces a distinct type,
reading [0120]'s "like any other value" as a definition and treating
`distinct` as emphasis. It is one rule instead of two, and it was declined
because it makes `distinct` a word that does nothing. An alias that needs a
conversion at every use is not an alias, so the language would have no way to
give a type a second name at all.

**Pinned by** `positive/type-declaration-aliases-a-scalar`,
`negative/distinct-not-enabled`.

### D16 — A field of a struct local is assigned on its own

**The tour said** that a binding declared with no value must be assigned
before use [0080], and [1910] made that a rule about a name: at every read,
the name has to have been assigned by every path that arrives there. It does
not say what the thing tracked is when the binding has fields, because until
a struct could be a local nothing written in a body had any.

**Chosen:** the field. `p.x = 1` assigns `p.x` and nothing else, a read of
`p.x` asks whether `p.x` was assigned, and a read of `p.y` after only `p.x`
was written is refused and names `p.y`. `inc p.x` reads and writes the same
field, so it wants that field assigned above it, exactly as `inc n` wants
`n`. Every arm of an `if` merges its fields the way [1910] already merges
its names, and no condition is believed there either.

**Why the field and not the binding:** [1910] tracks the thing an assignment
writes, and an assignment to a place writes a field. It is also the answer
that survives: a parameter of struct type arrives assigned in every field, a
named return of one has to be filled in every field before [0930]'s return,
and a construction assigns them all at once — each of those is a statement
about fields, and a rule about the binding would have to be replaced to say
any of them.

**What this does not decide:** a module binding of a struct type. D10 already
says a binding with no value holds zero and [1460] leaves no moment in which
anything could assign one, so its fields read zero and there is nothing here
to check. This rule is about a body.

**The alternative:** two. Treat the binding as assigned once every field has
been, which is one bit instead of one per field and never reads a field
nobody wrote — declined because it refuses a function that fills two fields
of three and reads only those two, which is ordinary code whose workaround is
assigning a field the program does not use. Or zero a struct local where it
is declared, extending D10 into a body, which removes the question entirely —
declined because it is a store per field at a place the source does not
mention, and this language does not do work a reader cannot see.

**Pinned by** `negative/struct-field-not-assigned`,
`negative/struct-field-not-assigned-on-every-path`,
`runtime/struct-locals-hold-their-fields`.

### D17 — An array's identity is its length and its element

**The tour said** that an array is a value, that assignment copies it and
that its size is part of its type [0520]. It says what an array *is* and
never says when two of them are the same type, which for a struct [0710]
answers by naming the declaration that wrote it.

**Chosen:** structural. `[4]u8` and `[4]u8` are one type wherever they are
written, and `[4]u8` and `[8]u8` are two, and so are `[4]u8` and `[4]i8`.
D15's alias keeps that identity like any other, so `row: type = [4]u8`
gives the same type a second name. The evidence is [0520]'s own sentence:
size is part of the type, which is a description of a shape and not of a
declaration — and [0370]'s `sizeof` and `lenof` ask a type what it measures
without asking where it was written.

**Why not [0710]'s rule:** that paragraph is about a struct, and it gives
its reason in the same breath — a value typed as an anonymous struct "never
becomes a same-shaped named type", because a struct body introduces a type
where no existing type was. `[4]u8` introduces nothing: it describes a
shape that the length and the element already determine. D15 makes a
declaration without `distinct` name an existing type, and this is one.

**The alternative:** nominal, one type per declaration, which would make
two `[4]u8` declarations different types and put arrays under [0710] with
structs. It was declined because nothing in the tour reaches for it and
because it would leave a program no way to write the type of something it
did not declare: `sizeof [4]u8` and a parameter of `[16]u8` both name a
shape rather than a declaration, and under a nominal rule neither would
mean anything.

**An array of a struct** follows from this rather than needing its own
answer, and is stated here so nobody reads the gap as a question. The array
is structural and the element is whatever it is: two `[4]point` are one type
exactly when the two `point`s are, which is [0710] doing its own work inside
this rule and not an exception to it. No implementation carries it yet —
this kernel lays out an array of a scalar and refuses any other element by
name — so the rule is written and the fixture that pins it arrives with the
element.

**Pinned by** `positive/array-type-is-declared`,
`positive/array-types-alias-and-agree`,
`positive/measurement-of-fixed-arrays`.

### D18 — An array index is `usize`, and an array fits the target's `usize`

**The tour said** that `usize` is the unsigned integer for byte counts and
indices [0160], that an array's size is part of its type [0520], and that an
index is checked before its address is computed [0580]. It did not say
whether every integer type could index an array or how large an array type
could be. Its packed-register example used `u32`, which answered differently
on targets of different widths without stating that it meant to.

**Chosen:** an array index is exactly `usize`. An untyped literal in the index
position receives `usize` as its context; a value already typed `u32`, `u64`,
`isize`, or any other integer is refused rather than converted. The byte
extent of an array must be no greater than the largest value the target's
`usize` can hold. Thus `[4294967296]u8` is a type on a 64-bit target and is
refused on a 32-bit one, while `[4294967295]u8` fits both.

**Why the two answers are one rule:** [0580]'s address computation consumes a
byte offset. Its index and its greatest object extent therefore share the
one target width [0160] gives for addressing; neither inherits a fixed width
from the compiler host. The count is not itself bytes — an element may occupy
more than one — so legality is decided from `length * sizeof element`, without
performing that multiplication after it has already overflowed.

**The alternative:** accept any integer and compare it with the length. That
looks permissive, but using a `u32` where the operation consumes `usize` is an
implicit conversion, which [0190] does not provide, and using `i32` gives a
negative case that the type of an index need not have. A fixed `u32` limit was
also declined: it needlessly truncates a 64-bit address space and cannot
follow a target narrower than 32 bits.

**Pinned by** `negative/index-is-not-usize`,
`negative/index-past-the-default-type`, the target-parametric checker case
`array extent follows usize`, and
`runtime/large-array-offset-is-addressed` on Linux x86-64.

### D19 — A known element of a local array is assigned independently

**The tour said** that a local declared without a value has to be assigned on
all paths before it is read [1910], that an array's elements are indexed from
zero [0520], and that a compiler-known index is a literal or unary minus over
one [1880]. It did not say whether assigning one element assigned the local or
what fact a later element read required.

**Chosen:** a declaration-only fixed-array local has one definite-assignment
fact for each compiler-known element that the function reaches. Writing
`items[2]` establishes only element two; reading or stepping `items[2]`
requires that same fact on every arriving path, and says nothing about any
other element. Branches intersect these facts exactly as they intersect a
scalar local's fact. The compiler keeps only facts the function actually
reaches, rather than allocating bookkeeping proportional to the array length.

This decision does not define what a write through a computed local index
establishes. Computed local indexing remains refused in this R2.20 slice;
computed indexing of module arrays remains enabled because D10 gives module
state every element from the start. Whole-array local values and initializers
remain refused as well; D20 admits the one direct storage-to-storage copy.

**Why:** treating one element write as assignment of the whole local would
permit an uninitialized read from every other element. Requiring every element
to be written before any one can be read would make large arrays unusable and
would contradict [1910]'s local, path-sensitive question. Sparse facts preserve
both the element boundary and D18's target-sized array lengths.

**The alternative:** one fact for the whole array, or a dense bit for every
position. The first loses the safety check at the first partial write; the
second makes compiler memory consumption depend on a target object that may be
far larger than the host can enumerate. Both were declined.

**Pinned by** `negative/local-array-element-not-assigned`,
`negative/local-array-element-not-assigned-on-every-path`,
`negative/increment-unassigned-local-array-element`, and
`runtime/local-array-elements-are-independent` on Linux x86-64.

### D20 — A whole-array copy reads and assigns every element

**The tour said** that an array is a value and assignment copies it [0520],
that two arrays are one type when their length and element type agree (D17),
and that a local declared without a value is assigned before it is read
[1910]. It did not say how a whole copy interacts with the independent sparse
element facts D19 later introduced.

**Chosen:** `destination = source`, where both sides name fixed-array storage,
reads every element of the source and assigns every element of the destination.
The two array types must have the same D17 identity. A source local is wholly
assigned when an earlier whole copy assigned it or when its sparse D19 facts
cover its length; a zero-length source is therefore assigned vacuously. Module
state is wholly assigned by D10. Self-copy follows the same rule, so it cannot
turn unassigned storage into an assigned value.

A branch merge intersects what the facts *mean*, not merely how they happen to
be represented. Whole on both paths remains whole; whole on one path and
sparse facts on the other keeps those sparse facts; sparse on both keeps their
intersection. Completeness is decided by counting the sparse facts already
present, never by walking an array extent that D18 permits to fill the target.

This kernel admits an array name as a whole value only in this direct copy;
D21 reuses the same storage read for its direct-name local initializers.
Parameters, returns, discards, and other general value positions remain refused
until their own R2.20 or R2.30 slices. No array literal is enabled by this
decision; D23 later admits one contextual initializer.

**Why:** expanding a copy into one operation per element would make compiler
work and IR size proportional to a target object that the host may not be able
to enumerate. Treating a copy as one compact storage operation preserves
[0520]'s value semantics while the sparse whole fact preserves [1910] without
pretending that a partial local was initialized.

**The alternative:** enumerate every copied element in definite-assignment
state and IR, or let any one element write establish the whole. The first is
not representable for every D18 array and the second permits reads of bytes the
program never assigned. Both were declined.

**Pinned by** `positive/local-array-copy`,
`negative/local-array-copy-from-unassigned`,
`negative/local-array-copy-not-assigned-on-every-path`, and
`runtime/whole-arrays-copy-between-storage` on Linux x86-64.

### D21 — An array is initialized from a whole-array storage name

**The tour said** that a binding may name its type and give it a value in one
form [0040], that an inferred form takes the value's type [0050], and that a
local declared without a value is assigned before it is read [1910]. It said
nothing about what value an array binding could receive at its declaration.

**Chosen:** a local or module array binding is initialized from a direct
storage name in either its explicitly typed form —
`[mut] name: [N]T = source` — or its inferred form —
`[mut] name := source`. For a local, both copy every element exactly as D20's
assignment does between two storage places. `source` names a whole array: a
module binding, a prior local wholly assigned by D19's sparse facts or by a
D20 copy, or a prior local likewise initialized from a name. The explicit
form requires the source's D17 identity to agree with its written type; the
inferred form gives the destination the source's exact D17 length and element
type. The destination is wholly assigned by the copy alone, and both mutable
and immutable binding forms accept it because a declaration is not an
assignment [0080].

At module scope `source` is exactly one resolved module storage name. Its
initial-image chain follows declaration identities, across forward references
and type-alias chains, and must terminate either at a module array whose
initializer is omitted or at a module array whose initializer is D24's
explicit literal. A chain that returns to a declaration is [1940]'s value
worked out from itself. Each destination on the chain nevertheless owns
distinct storage initialized with the terminal image rather than aliasing
its source. Nothing runs before the entry point [1460], so no module-level
copy instruction exists.

Every other array initializer value remains refused: D23 admits one
contextual local array literal [0520], D24 admits its module counterpart,
while an inferred literal, `zeroed` [0540], repetition [0560], a slice
[0570], a call, and an indexed or selected subexpression are each their
own later slice. This decision does not
enable a general array value or an array as a parameter, return, discard, or
struct field. A local source is read before the binding's scope begins [0110],
so a local cannot initialize itself and an outer storage name may be shadowed.

**Why:** D20 already lowered a local whole-array copy to one `Copy_Array`
instruction, D18's storage semantics already reached every ordinary local,
and D19's flow state already gave a fully-copied array the single whole-array
fact it needs. At module scope, following declaration identities proves the
initial bytes without inventing initialization code or collapsing two storage
symbols into one. In both scopes the restriction to a direct source name keeps
compiler work and IR size independent of the target-sized D18 extent and
defers every value form whose own semantic rule is a later slice.

**The alternative:** widen the initializer to any array-typed expression, or
make the inferred spelling synthesize a general array value. Either admits
constructs this decision does not recognise — D23's local array literal,
`zeroed`, a slice, a call result, a selection or an index result — and each is
its own decision. Reading D17's shape directly from named storage instead keeps the
same narrow source rule as the explicit form without synthesizing an array
`Name_Reference` anywhere else.

**Pinned by** `positive/local-array-initialized-from-source-name`,
`positive/module-array-initialized-from-source-name`,
`negative/local-array-initializer-from-unassigned`,
`negative/array-initializer-length-mismatch`,
`negative/array-initializer-element-mismatch`,
`negative/module-array-initializer-shape-mismatch`,
`negative/module-array-initializer-non-name-refused`,
`negative/module-array-initial-image-cycle`,
`runtime/local-array-initializer-copies-storage`, and
`runtime/module-array-initializers-copy-images` on Linux x86-64.

### D22 — Computed local array indexes use the whole-array fact

**The tour said** that indexing an array checks the bound at runtime [1950],
that an index is `usize` [0160], that a local declared without a value is
assigned before it is read [1910], that an array is a value and assignment
copies it [0520], and that its elements are indexed from zero [0520]. D19
introduced one definite-assignment fact per compiler-known element and D20
introduced the whole-array fact a copy assigns, and neither answered what
a computed local read must require or a computed local write must
establish.

**Chosen:** a computed local array index is admitted where a compiler-known
one is. Reading `local[i]` for a runtime `usize` requires the whole-array
fact to hold on every arriving path — the same fact D20's copy and D21's
initializer record, and the fact D19's element facts add up to once every
declared position has been assigned. Writing `local[i] = v` for a runtime
`usize` establishes no element fact of its own, and does not clear an
existing whole-array fact: a copy followed by a computed write followed by
a computed read is legal, and a computed write into an uninitialized local
followed by a whole-array read is still refused. `inc local[i]` requires
the whole-array fact because it reads and writes.

Module arrays are unchanged: D10 gives their state every element from
declaration, so their computed reads meet no assignment requirement and
their computed writes still assign nothing tracked. Every other refused
value form — an inferred initializer not sourced by a direct storage name, a
slice, `zeroed`, repetition, an array literal outside D23's one context,
`lenof`, an array as a struct field — stays refused.

**Why:** treating one computed write as a whole assignment would admit
uninitialized reads from every other position, exactly the failure D19
declined to introduce for known indexes. Requiring the whole-array fact
before any computed read is the minimum rule that keeps [1910] path-
sensitive without inventing element-range tracking the compiler would then
have to compute for expressions no target can enumerate. Preserving an
existing whole fact through a computed write is what makes D20 and D21
usable: without it, a copy followed by any computed update would need to be
re-established a position at a time, and no sparse column of D19's fits an
extent D18 permits.

**The alternative:** admit a computed read without a prior whole assignment
(and leave every out-of-order write undiagnosed until R6.70's runtime), or
have a computed write clear the whole-array fact. Both were declined for
the same reason D19 refused to widen one element write to the whole local:
they trade a compile-time refusal for a runtime that this compiler has no
way to observe.

**Pinned by** `positive/local-array-computed-element-after-whole-copy`,
`negative/local-array-computed-read-not-whole-assigned`,
`negative/local-array-computed-write-establishes-no-fact`,
`runtime/local-array-computed-index-reads-and-writes`,
`runtime/local-array-computed-index-traps`, and
`runtime/local-array-computed-store-traps` on Linux x86-64.

### D23 — A written local array type gives a literal its shape

**The tour said** that an array is a value whose size is part of its type
[0520], that a binding may write its type and value together [0040], that an
integer literal takes the type of its context [0190], and that expressions are
evaluated left to right [0410]. It did not say which of those supplies the
shape and element context while array values are being introduced a slice at a
time.

**Chosen:** a nonempty array literal initializes an explicitly typed local
fixed-array binding: `[mut] name: [N]T = [first, ...]`. The literal contains
exactly `N` elements, and the scalar `T` is the context for every element
expression. Each element is evaluated and stored in source order. The fresh
local is thereby initialized as a whole, so a later computed index meets D22's
whole-array requirement without a preceding copy.

This is one contextual initializer and not a general array value. An inferred
binding [0530], a module binding, assignment to an existing array, a parameter,
return, argument or discard still refuses the literal. An empty literal,
repetition [0560], `zeroed` [0540], slices [0570], nested array values and
non-scalar elements remain outside this slice. In particular, requiring one
expression in the literal grammar does not decide whether a programmer may
write the zero-length type `[0]T`.

**Why the written type:** it gives both facts the checker needs without an
array-value inference rule: D17's exact length and the scalar context [0190]
applies to each expression. The literal's finite source run is also the one
array extent it is sound for the compiler to enumerate. Lowering allocates the
same compact frame slot as any local array and stores each source element into
its position; it does not introduce an array-valued IR result or work
proportional to a target extent that was not written in the literal.

**The alternative:** first infer the literal's length and element type, then
allow that value in every compatible position. That is [0530] plus general
array values rather than [0520]'s smallest executable case. It was deferred to
D25 so module initial images, copying temporaries, parameters and returns did
not become unstated consequences of accepting one local initializer.

**Pinned by** `positive/local-array-literal-initializer`,
`negative/local-array-literal-length-mismatch`,
`negative/local-array-literal-element-mismatch`,
`negative/array-literal-assignment-not-enabled`, and
`runtime/local-array-literal-initializes-elements` on Linux x86-64.

### D24 — A written module array type gives a literal its static image

**The tour said** that an array is a value whose size is part of its type
[0520], that a binding may name its type and give it a value in one form
[0040], that an integer literal takes the type of its context [0190], that
expressions are evaluated left to right [0410], that a module value is
known when the compiler reads it [1940], and that nothing runs before the
entry point [1460]. It did not say what shape the compiler admits as a
module array's static initial image.

**Chosen:** a nonempty array literal initializes an explicitly typed
module fixed-array binding: `[mut] name: [N]T = [first, ...]`. The
literal contains exactly `N` elements, and the scalar `T` is the
context for every element expression. Each element is evaluated in
source order and its folded value becomes that array position's byte
image at compile time. Every element must be `[1940]`-known and its
fold must fit `T` — a literal or a bool spelling, an operator of [1820]
[1940] enumerates over those, or a name bound to another module scalar
binding whose own value is known. A forward reference is admitted for
the same reason [1740] admits one for a scalar module value: a module
is a set and the order between declarations is decided by identity
rather than by their placement in the source.

D21's direct-name form remains admitted at module scope as well.
Following declaration identity through a chain of `[mut] name := source`
or `[mut] name: [N]T = source` bindings now terminates either at D10's
omitted-initializer array (whose image is zero) or at a D24 literal
(whose image is that literal's fold). Every destination on the chain
still owns distinct storage, and each is initialized with the terminal
image byte for byte — a chain does not alias its source.

This is D24's sole new module array initializer form. D26 later admits
`[mut] name := [first, ...]` after D25 settles [0530]'s inferred shape. An
empty literal, `zeroed` [0540], repetition [0560], slices [0570], nested
array values, non-scalar elements, calls, selections and index results all
remain outside these slices. Requiring one expression in the literal grammar
does not settle whether a programmer may write the zero-length type `[0]T`.

The [1820] operators [1940] admits over literals are folded during
checking and again when lowering records the verified image: [0290]'s
arithmetic, [0300]'s wrapping forms at the operand type's own width so
`u8 = 255 +% 1` is zero and every unsigned or signed size wraps the same
way, [0320]'s shifts, [0330]'s bitwise set, [0340]'s logical words with
short-circuiting, [0350]'s comparisons and [0370]'s measurements. Both
walks take their widths from Landin.Types.Width against the compilation's
target facts; the backend separately folds verified scalar IR, whose
representation is no longer syntax. Thus a shift past the width gives zero
at exactly the width [0320] promises and a bitwise `not` occupies the same
bytes the backend emits. The positive operator corpus and the negative fold
agreement fixtures pin that checking settles every value or invalid operand
before lowering is allowed to record an image. A member selection [0420], an array element
index [0570] and a nested array literal are refused as D24-excluded
constructs; [1940] admits an operator of [1820] applied to leaves, and
these three would need the source aggregate or array to have its own
image resolved before this one — a stage each has to arrive with its own
slice. The refusal walks each element's whole subtree, so
`source[0] + 1` and `state.x == 3` are refused for the same reason a
bare `source[0]` or a bare `state.x` is: the operator at the root is
admitted but the leaf it stands on is not. The same [1940] boundary applies
to a scalar module initializer: selecting `state.x` or `source[0]` needs a
static aggregate or array image that the corresponding later slice has not
yet supplied, so checking refuses it rather than leaving the backend to meet
an unreadable value.

A fold whose result walks past the compiler's widest kernel value is
also refused with the same [1940] rule: an `18446744073709551615 + 1`
and a `4294967296 * 4294967296` have no moment in which to trap and no
folded value the compiler can hold, so each is refused at the element
that produced the overflow rather than left to defect during image
resolution. The same refusal applies to a scalar module binding whose
value's fold overflows: `k: u64 = a + 1` where `a` is already
`u64`'s maximum reports the overflow rather than silently deferring
it to the backend and Constraint_Error at emit time.

**Why the written type:** it gives the checker D17's exact length and
one scalar context [0190] for every element, without introducing an
array-value inference rule at module scope. The written literal is the
one array extent it is sound to enumerate at compile time; every other
D18 length reaches four billion positions and no reader will type them
out. Requiring each element to be `[1940]`-known keeps [1460]'s
"nothing runs before the entry point" as the rule that decides what a
module value is, and the finite element run makes the module fold a
per-position walk that a target loader can consume by writing one
directive per element into the object.

**The alternative:** admit a call or a general expression, or infer the
length from the literal before settling the local rule. The first two turn
`[1460]` into a promise this compiler cannot keep; the third would have coupled
[0530] to static-image folding rather than first giving local and module
bindings D25's one shape. D26 admits inference only after that shared rule;
the first two alternatives remain declined.

**Pinned by** `positive/module-array-literal-initializer`,
`positive/module-array-literal-forward-scalar-reference`,
`positive/module-array-literal-1820-operators`,
`negative/module-array-literal-length-mismatch`,
`negative/module-array-literal-element-mismatch`,
`negative/module-array-literal-element-not-known`,
`negative/module-array-literal-element-out-of-range`,
`negative/module-array-literal-index-element`,
`negative/module-array-literal-selection-element`,
`negative/module-array-literal-nested-index`,
`negative/module-array-literal-nested-selection`,
`negative/module-array-literal-fold-overflow`,
`negative/module-scalar-fold-overflow`,
`negative/module-array-fold-agreement`,
`negative/module-scalar-fold-agreement`,
`negative/module-scalar-storage-selection`,
`positive/module-scalar-wrapping-arithmetic`,
`positive/module-array-literal-wrapping-arithmetic`, and
`runtime/module-array-literal-holds-its-image` on Linux x86-64.

### D25 — A nonempty local literal infers one fixed-array shape

**The tour said** that a binding written with `:=` takes the type of its value
[0050], that an integer literal takes the type of its context [0190] and uses
the default integer when there is none [0200], that an array's size is part of
its type [0520], and that the length may be inferred from a literal [0530]. It
did not say which element supplies the scalar type or which value positions
that inference enables.

**Chosen:** a nonempty array literal directly initializing an inferred local
binding has fixed-array type `[N]T`, where `N` is the number of source elements
and `T` is the scalar type synthesized by the first element. When that first
expression is an untyped integer, [0200]'s `i32` is its context and therefore
`T`; every later element is checked in that same `T` context. D18's complete
`N * sizeof T` extent must fit the target's `usize` before the shape is
recorded. D23's existing lowering evaluates and stores the finite source run
left to right, and the resulting local is wholly assigned.

D25 admits only the initializer in a local inferred binding. Its module
counterpart remained refused until D26 connected the inferred shape to D24's
separate [1940] static-image fold. A literal in general assignment,
a parameter or return, an empty literal, a nested literal, repetition [0560]
and every non-scalar element also remain outside this slice. In particular,
inference does not create a general array-valued temporary.

**Why the first element:** [0530]'s literal has no surrounding element type,
while [0050] requires the value to answer with one type. Letting the first
source expression answer and checking the rest against it gives [0410]'s source
order a single deterministic context, applies [0200] without an invented
numeric join, and needs no conversions [0310].

**The alternative:** search all elements for a common type, defer every integer
until a later element supplies one, or infer module static images at the same
time. A common-type search would introduce conversion or least-upper-bound
rules the language has neither stated nor wanted; deferral would make element
order affect when errors appear without changing their source order; module
inference would merge [0530] with [1940]'s independently constrained image
fold. All three were declined.

**Pinned by** `positive/local-array-literal-inferred-length`,
`negative/local-array-literal-inferred-element-mismatch`, and
`runtime/local-array-literal-infers-and-initializes` on Linux x86-64.

### D26 — An inferred module literal has the same static image boundary

**The tour said** that `:=` takes the type of its value [0050], that the length
may be inferred from an array literal [0530], and that every module value is
known when the compiler reads it [1940]. D24 supplied static images only after
a written array type, and D25 first settled how a nonempty literal infers one
shape.

**Chosen:** a nonempty array literal directly initializing an inferred module
binding has D25's `[N]T` shape: its source count is `N`, its first element
supplies scalar `T`, an otherwise untyped integer first element defaults to
`i32` [0200], and every later element is checked in that same context. Once the
shape is settled, every element must meet D24's module-image boundary: it is
[1940]-known, target-aware folding produces a value held by `T`, and the values
form one source-order static image. D21's direct-name chain may copy that image
into typed or inferred module array storage, with a distinct datum for every
binding.

All D24 exclusions remain exclusions: no call, member selection, element index
or nested array can supply an image element, and checked overflow or an
out-of-range folded value is refused before lowering. D18 limits the inferred
complete byte extent before the shape is recorded. A local inferred literal
continues to use D25's runtime evaluation instead; only module scope folds an
image.

This does not admit a literal in general assignment, as a parameter or return,
or as a general array-valued expression. It also does not admit an empty
literal, repetition [0560], `zeroed` [0540], slices [0570], or a non-scalar
element. No general array temporary is introduced.

**Why reuse D25's shape before D24's fold:** inference answers only which fixed
array the binding holds; [1940] independently answers whether module storage
can have that value before anything runs [1460]. Keeping those checks
sequential makes local and module `:=` mean the same type while preserving the
module-only static-image restriction.

**The alternative:** infer a different element type from the complete folded
image, or make module inference choose a written-width type from each value.
Either would make the same literal have a different type at local and module
scope and would invent a numeric join or narrowing conversion [0310]. Both were
declined.

**Pinned by** `positive/module-array-literal-inferred-length`,
`negative/module-array-literal-inferred-boundaries`,
`negative/module-array-literal-inferred-fold`, and
`runtime/module-array-literal-infers-static-image` on Linux x86-64.

### D27 — An explicitly typed module array may spell its zero image

**The tour said** that `zeroed` denotes all-bits-zero when that image is valid
for its context [0540], that a fixed array is zeroable exactly when its element
is [0520], and that every module value is known when the compiler reads it
[1940]. D10 already gives an omitted module initializer that image, but did not
say where a program may request it explicitly while array values are enabled a
slice at a time.

**Chosen:** `zeroed` directly initializes an explicitly typed module fixed-array
binding: `[mut] name: [N]T = zeroed`. The written D17 shape is its context. Every
scalar element type the kernel currently admits has an all-bits-zero image, so
the complete array has one without enumerating its `N` positions. Lowering
records no finite datum image, exactly as for D10's omitted initializer; the
backend therefore reserves the distinct module storage in `.bss`. A D21 direct
name chain may copy this terminal zero image while retaining one storage object
per declaration.

This is a contextual initializer, not an array-valued expression or a runtime
operation. D27 itself does not infer a type for `name := zeroed`; D28 separately
admits a typed local array initializer, D30 an array assignment, and D39 a typed
module scalar initializer. Local scalar initialization and every inferred form
remain refused. D27 introduces no IR opcode, temporary, startup copy, or
source-order element evaluation. Repetition [0560],
slices [0570], empty literals, non-scalar array elements, parameters, returns,
arguments, and general whole-array value positions remain outside this slice.

**Why preserve the absent image:** materializing `N` zero values would make host
work and IR size depend on D18's target-sized extent and would emit bytes for a
value the object format can reserve without storing. The absence already means
exactly this image for D10, keeps zero storage in `.bss`, and remains distinct
from D24/D26's finite literal image.

**The alternative:** treat `zeroed` as a generally typed value, or infer an
array shape from it. The first would silently admit local initialization,
assignment, parameters, and other value positions that need their own runtime
rules; the second has no source fact from which to derive either `N` or `T`.
Both were declined.

**Pinned by** `positive/module-array-zeroed-initializer`,
`negative/inferred-zeroed-not-enabled`,
`negative/local-scalar-zeroed-not-enabled`, and
`runtime/module-array-zeroed-reads-zero` on Linux x86-64.

### D28 — A local zero image is one runtime storage operation

**The tour said** that `zeroed` denotes all-bits-zero when that image is valid
for its context [0540], that a fixed array is zeroable exactly when its element
is [0520], and that a local binding may carry an initializer [1810]. D27 supplied
one static module context but deliberately introduced no runtime operation, so
it did not say how a local array obtains the same image.

**Chosen:** `zeroed` directly initializes an explicitly typed local fixed-array
binding: `[mut] name: [N]T = zeroed`. The written D17 shape is its context. Every
scalar element the kernel currently admits has an all-bits-zero image, so one
runtime storage operation clears the complete compact frame slot. The operation
carries the destination identity, never one entry per element; its byte extent
is derived from the target's width for `T`. The initialized local is assigned as
a whole, so D22 permits a later compiler-known or computed index read.

Lowering records one target-neutral `Clear_Array` instruction with no operands
and no result. The Linux x86-64 backend forms the slot address, takes the target
byte extent, and emits one forward `rep stosb` clear. Compiler work and IR size
therefore remain independent of the target-sized length D18 admits, and no
array-valued temporary or hidden zero datum exists.

This remains one contextual initializer. D28 does not infer a shape for
`name := zeroed`; D30 separately admits array assignment and D39 a typed module
scalar initializer. Local scalar initialization, scalar assignment, and
`zeroed` as an argument, return, discard, nested or general expression remain
refused. Module arrays continue to use D27's absent static image rather than this runtime instruction.
Repetition [0560], slices [0570], empty literals, non-scalar array elements,
parameters, and returns remain outside this slice.

**Why one storage operation:** lowering one store per element would make compiler
work and IR size proportional to an extent deliberately permitted to approach
the target address space. Copying a synthesized zero array would instead invent
storage and a source the program never declared. A destination-only clear says
exactly what [0540] requires and leaves representation to the target backend.

**The alternative:** treat `zeroed` as a scalar expression repeated `N` times,
or enable it in assignment at the same time. The first imposes host enumeration
and invents source-order evaluation where there is none; the second broadens the
place/value boundary beyond fresh initialization and needs its own definite-
assignment and evaluation decision. Both were declined.

**Pinned by** `positive/local-array-zeroed-initializer`,
`negative/inferred-zeroed-not-enabled`,
`negative/local-scalar-zeroed-not-enabled`, and
`runtime/local-array-zeroed-reads-zero` on Linux x86-64.

### D29 — Array literal assignment forms the value in its destination

**The tour said** that assignment copies an array [0520], that an assignment
evaluates its destination place before its value [0410], and that aggregate
parts initialize in written order. D20 admitted only a direct storage name as
the value, while D23 admitted a literal only for a fresh local binding. Neither
said whether assignment of a literal needs a hidden complete value or exposes
its element order in existing storage.

**Chosen:** a nonempty array literal may be assigned contextually to a mutable
fixed-array place: `place = [first, ..., last]`. The destination's D17 length and
scalar element type are the context; the literal must contain exactly that many
elements and each expression must have that element type. The kernel's present
fixed-array places are direct local or module storage names. [1900] still decides
whether one may be written.

The destination place is reached first. Then each literal element is evaluated
left to right and written immediately to its one-based destination position
before the next expression begins. A later expression can observe an earlier
write to the same array, and a runtime failure can leave the completed prefix
changed. Lowering emits the existing scalar expression and field-store sequence
for each source element; it creates no hidden array-sized temporary and no new
array IR operation. The compiler work and instruction run are proportional to
the literal text the program wrote, not to an implicit target-sized extent.

Definite assignment checks every right-hand-side read against the state arriving
at the statement, then marks the destination array assigned as a whole only when
the assignment completes normally. Thus assigning a complete literal makes a
previously uninitialized array readable through a compiler-known or computed
index, but an element written earlier in the same statement does not justify a
source read that was unassigned on entry.

This is one assignment context, not a general array value. Array literals remain
refused as arguments, returns, discards, scalar operands, nested elements, and
other expression positions. Empty literals, repetition [0560], slices [0570],
non-scalar element arrays, and `zeroed` assignment remain separate slices. A
direct storage-name assignment continues to use D20's one compact `Copy_Array`.

**Why expose the writes:** evaluating every element before changing the
destination would require a hidden second array as large as the value, obscuring
a cost the language promises to keep visible. Writing each completed scalar
uses only storage the program named and gives [0410]'s aggregate order an
observable, deterministic meaning. Source text already contains one expression
per store, so this does not introduce D18's host-enumeration problem.

**The alternative:** synthesize a temporary array and copy it only after every
element succeeds. That gives transactional-looking assignment and prevents
later elements from observing earlier writes, at the price of an implicit full
array in every frame and a second full traversal. It was declined.

**Pinned by** `positive/array-literal-assignment`,
`positive/module-array-literal-assignment-runtime-elements`,
`negative/array-literal-assignment-length-mismatch`,
`negative/array-literal-assignment-element-mismatch`,
`negative/array-literal-assignment-reads-incoming-state`, and
`runtime/array-literal-assignment-is-source-ordered` on Linux x86-64.

### D30 — Zeroed assignment clears one complete array place

**The tour said** that `zeroed` is the all-bits-zero image supplied by a context
[0540], that assignment evaluates its destination before its value [0410], and
that array assignment copies a complete value [0520]. D27 and D28 admitted that
image only while creating module and local storage. They deliberately left an
existing destination to a later definite-assignment and runtime decision.

**Chosen:** `zeroed` may be assigned contextually to a mutable fixed-array place:
`place = zeroed`. The destination's D17 length and scalar element type supply the
context, and [1900] decides whether its direct local or module storage name may be
written. Every scalar element the kernel currently admits has an all-bits-zero
image, so the complete array has one [0540].

The destination is reached first; `zeroed` evaluates no source expressions and
names no source storage. Lowering emits one `Clear_Array` carrying that local
frame slot or module datum. The verifier resolves its complete array shape, and
the backend derives the byte extent from target facts before emitting one
forward byte clear. There is no hidden zero datum, array temporary, source
operand, or compiler enumeration of D18's target-sized length.

A normally completed assignment marks a local destination assigned as a whole,
so every compiler-known and computed element may then be read. There is no
source-order prefix like D29's literal has: the source contains no elements and
specifies no per-element evaluation. This does not promise an atomic machine
operation; concurrency and interruption remain outside the current kernel.

This is one contextual array assignment. It does not infer a type for
`name := zeroed` or assign a scalar; D39 separately admits a typed module scalar
initializer, while local scalar initialization remains refused. Nor does D30
admit `zeroed` as an argument, return, discard, nested value, or general
expression. Module and local array initializers keep D27/D28's distinct static
and runtime paths. Repetition [0560],
slices [0570], non-scalar array elements, and other zero-accepting types remain
separate slices.

**Why reuse the clear:** lowering one scalar zero store per element would make
compiler work and IR size depend on an extent whose source writes no finite run.
Copying a synthesized zero array would invent both storage and a read. D28's
compact destination-only operation already says the complete runtime effect and
already follows target width for either storage kind.

**The alternative:** make `zeroed` a general array value and feed it through
D20's copy. That would silently admit arguments, returns and other value
positions while requiring source storage for an image that has none. It was
declined.

**Pinned by** `positive/array-zeroed-assignment` and
`runtime/array-zeroed-assignment-clears-storage` on Linux x86-64, together with
the focused lowering and target-width backend cases for both storage kinds.

### D31 — `lenof` counts a literal without forming it

**The tour said** that a literal's `lenof` is compile-time [0370]. D14 first
implemented only a direct name, because a general expression operand would have
made array values, calls, selections and slices one undivided decision. D25 later
settled how a nonempty literal supplies a scalar element shape.

**Chosen:** `lenof ([first, ...])` is a `usize` whose value is the number of
expressions in the literal's source run. The literal must remain nonempty under
[0520]. Its first element supplies D25's scalar type, including [0200]'s default
for an otherwise untyped integer, and every later element must have that same
type. This checks that the syntax denotes one array shape; it does not create an
array value.

None of the element expressions is evaluated, read, folded, lowered or stored.
The count therefore remains valid when an element is an unassigned local, a call,
a selection or any other well-typed scalar expression. At module scope those
expressions do not become module initializer inputs: the complete measurement is
known from syntax alone. Definite assignment likewise reads no names beneath the
measurement.

Lowering emits one existing `usize` Number holding the source element count. A
static module binding records the same number directly. No array storage,
temporary, element instruction, target query or backend operation is introduced.
D18's maximum object extent does not apply because no object of the literal's
shape exists.

This admits only a parenthesized nonempty array literal beside D14's direct
identifier. The parentheses are part of the measurement syntax, not a general
expression operand: without them, `lenof[index]` continues to index an ordinary
binding named `lenof`, as [1760]'s contextual spelling requires. A slice,
selection, index, call and every other general `lenof` expression remain
deferred. Empty literal syntax and `[0]T` source legality remain undecided with
[0520].

**Why type-check expressions that do not run:** the brackets still claim one
array literal, and D25 already gives that claim a deterministic scalar shape.
Counting arbitrary comma-separated expressions regardless of their types would
make malformed aggregate syntax valid only when placed beneath `lenof`.

**The alternative:** evaluate the literal and then ask the resulting array value
for its length. That would make calls and reads observable despite the count being
fixed by syntax, require hidden array storage, and prematurely admit a general
array value. It was declined.

**Pinned by** `positive/lenof-array-literal-does-not-read-elements`,
`negative/lenof-array-literal-element-mismatch`,
`negative/lenof-array-literal-needs-scalar-elements`, and
`runtime/lenof-array-literal-is-compile-time` on Linux x86-64; the runtime case
also keeps an ordinary array named `lenof` indexable.

### D32 — Full-array repetition evaluates one scalar once

**The tour said** that repetition writes `[N of value]`, or `[of value]` when a
context supplies the length [0560], that expressions run left to right [0410],
and that assigning an array copies its complete value [0520]. It did not say
whether `value` runs once or once per element, nor how a contextual repetition
is represented without materializing a target-sized temporary.

**Chosen:** an explicitly typed local fixed-array binding may be initialized by
`[N of expression]`, and a mutable fixed-array place may be assigned either
`[N of expression]` or `[of expression]`. The written local type or destination
supplies D17's exact length and scalar element type. When `N` is written, it must
equal that length exactly. The scalar expression must have the element type,
including [0190]'s contextual commitment of an untyped integer.

The destination is reached first for assignment. The repeated scalar expression
is then evaluated exactly once, and its target-width bit pattern is stored in
every element. Normal completion initializes or assigns the destination as a
whole for [1910], so a later computed index meets D22's whole-array requirement.
The operation is not promised atomic with respect to interruption or concurrency.

Lowering evaluates the scalar into one ordinary value and emits one
`Fill_Array` carrying that operand and the destination's compact frame-slot or
module-datum identity. The verifier requires one scalar operand matching the
destination element type and rejects a fill in a static datum initializer. The
Linux x86-64 backend derives the element count and width from the destination
shape and target facts, then uses the width-matched forward repeated store.
Neither IR nor compiler work enumerates D18's extent, and no hidden array
storage or temporary is formed.

This first repetition slice deliberately requires an explicitly typed local
initializer or an existing mutable array place. It does not admit an inferred
binding, module initializer or static image, mixed-prefix form such as
`[0x7F, 0x45, of 0]`, argument, return, discard, nested repetition or general
array value. Since `of` remains [1760]'s contextual spelling rather than a
reserved word, `[of, other, of]` remains an ordinary literal whose elements may
name a binding called `of`; repetition is recognized only where the token after
`of` can begin its scalar expression. Thus `[of + 1]` also remains an ordinary
one-element literal.

**Why once:** the source writes one expression, and evaluating it once makes the
runtime work visible without multiplying side effects by a type-level count.
A scalar register or spill plus one compact fill is sufficient even when D18
permits an extent the compiler host cannot enumerate.

**The alternative:** lower repetition as if the source had written one copy of
the expression per element. That would make side effects and compiler work
proportional to a target-sized count and contradict the single expression the
program contains. It was declined.

**Pinned by** `positive/local-array-repetition`,
`negative/array-repetition-count-mismatch`,
`negative/array-repetition-element-mismatch`,
`negative/array-repetition-countless-inferred-initializer-not-enabled`,
`negative/array-repetition-reads-incoming-state`,
`negative/array-mixed-repetition-assignment-not-enabled`, and
`runtime/array-repetition-evaluates-once` on Linux x86-64.

### D33 — A counted local repetition supplies its inferred shape

**The tour said** that a literal may supply an omitted array length [0530] and
that repetition writes a count before `of` when no surrounding type supplies one
[0560]. It did not say whether the same count can supply the complete type of an
inferred binding, or which expression supplies the element type.

**Chosen:** a counted full-array repetition directly initializing an inferred
local binding supplies `[N]T`. `N` is the written nonzero integer count. The one
repeated expression supplies `T` by D25's deterministic first-element rule: an
untyped integer receives [0200]'s default `i32`, an already typed scalar retains
that type, and no common-type search or conversion is introduced. The resulting
byte extent must fit D18's target `usize` before the compact shape is recorded on
the repetition and binding.

The repeated expression is read from incoming definite-assignment state and
uses D32's lowering unchanged: it evaluates exactly once into one scalar IR
value, followed by one compact `Fill_Array` for the inferred local frame slot.
Successful initialization establishes the whole array. Neither checker nor IR
enumerates the inferred extent.

A written zero count remains refused in this inference position. The compiler's
internal layout can represent an empty array, but whether source may write one is
still [0580]'s open empty-array decision; this refusal deliberately does not
settle it. A count-less inferred initializer, module initializer, mixed-prefix
repetition, argument, return, discard, nested repetition and other general array
value remain outside this slice.

**Why the scalar expression:** unlike a literal source run, repetition has only
one value-producing expression. Taking its settled scalar type gives every
stored element the same type without inventing a second inference rule.

**The alternative:** require a written array type for every repetition. That
would leave the explicit count unable to do the same shape work as [0530]'s
literal count, despite already being checked against that shape by D32. It was
declined.

**Pinned by** `positive/local-array-repetition-inferred`,
`negative/inferred-array-repetition-extent-overflow`,
`negative/inferred-array-repetition-reads-incoming-state`,
`negative/inferred-array-repetition-zero-count`,
`negative/array-repetition-general-value-not-enabled`, and
`runtime/array-repetition-evaluates-once` on Linux x86-64.

### D34 — A written nonzero array shape admits either repetition spelling

**The tour said** that `[N of expression]` may omit `N` when the type supplies
its length [0560], and introduced repetition as a static pattern that lives in
flash. D32 admitted only a counted explicitly typed local initializer, while D33
admitted a counted inferred local; neither slice supplied the module static image
or explained what a zero folded pattern becomes.

**Chosen:** an explicitly typed fixed-array binding at module or local scope may
be initialized by `[N of expression]` or `[of expression]` when its written
contextual length is nonzero. The written type supplies D17's complete shape. A
written `N` remains an exact assertion of that same length, and the one expression
is checked against the scalar element type. This lifts D32's count requirement for
an explicitly typed local without changing assignment or D33's inferred rule.

For module state, the expression obeys the same [1940] compile-time-known and
D24 target-aware scalar-fold boundary as one element of a module array literal:
literals, [1820] operators and module scalar names may compose; calls, storage
selection, an element index and a nested array literal remain refused. The fold
produces one scalar pattern. A nonzero pattern is represented in IR by that one
`Folded` value plus D17's existing compact shape, including through any D21 direct
module-array name chain. A zero pattern records no image, just like D10, D27 and
D28, and therefore remains loader-zeroed storage rather than bytes in `.data`.
Neither image resolution, copying, verification nor dumping enumerates the
extent.

The Linux x86-64 backend emits a constant-size `.rept`/width-specific-directive/
`.endr` sequence for a nonzero repeated image. The scalar directive is `.byte`,
`.word`, `.long` or `.quad` according to the target element width. In particular,
the eight-byte form does not use GNU `.fill`, whose value operand contributes at
most four bytes and would discard the high half of a `u64` pattern. An absent zero
image stays `.bss`.

A repetition whose written contextual length is zero is refused at the
repetition. This is a construct-specific nonzero requirement, not an admission or
rejection of `[0]T` as source; [0580]'s empty-array legality remains undecided.
D33's zero-count inferred refusal remains for the same reason. An inferred module initializer remained outside this slice until D35. A
count-less inferred initializer, every mixed-prefix context other than D36's
typed local, argument, return, discard, nested repetition and every other
general array value position remain refused.

**Why one image value:** repetition writes one expression and every destination
position receives the same target-width pattern. Materializing one value per
position would lose the compact representation precisely for D18's target-sized
extents, and copying such a run through a module name would repeat the same fault.

**The alternative:** use GNU `.fill count,size,value` directly. Its compact count
is attractive, but GNU assemblers truncate `value` to four bytes, so it cannot
faithfully emit an arbitrary eight-byte element. The width-specific repeated
scalar directive keeps both compact source and all pattern bits.

**Pinned by** `positive/local-array-repetition`,
`positive/module-array-repetition`,
`negative/array-repetition-zero-context`,
`negative/module-array-repetition-element-not-static`,
`negative/module-array-repetition-index-element`,
`negative/array-repetition-countless-inferred-initializer-not-enabled`, and
`runtime/array-repetition-evaluates-once` on Linux x86-64.

### D35 — A counted module repetition may infer its nonzero array shape

**The tour said** that a counted repetition may supply an inferred local's
length and scalar element type [0560]. D33 implemented that local form, while
D34 supplied the compact static image only when module state wrote its array
type.

**Chosen:** `[N of expression]` may directly initialize an inferred module
binding when `N` is written and nonzero. The count supplies D17's length and
the one expression supplies its scalar element type; an untyped integer takes
[0200]'s `i32` default. The resulting byte extent must fit the selected target's
`usize` by D18, exactly as for D25/D26/D33 inferred arrays.

The repeated expression obeys [1940]'s known/static boundary and the same
D24 target-aware fold and range checks as D34's typed module repetition.
Literal and [1820] operator trees may reach through module scalar names; a call,
storage selection, index or nested array value is refused before lowering. The
checker folds the one pattern against the inferred scalar type, so no accepted
out-of-range or overflowing pattern can reach lowering as a compiler defect.

D34's representation and emission apply unchanged: a nonzero pattern is one
compact repeated image, direct module-array name chains preserve it, and a zero
pattern is the absent loader-zeroed image emitted in `.bss`. Zero count,
count-less inferred repetition, every mixed-prefix context later than D36's
explicitly typed local, and every general array value position remain refused.

**Why only counted:** without a written type or source run, `[of expression]`
has no source for its length. The scalar can determine an element type but not
an array extent, so accepting it would require a separate inference rule rather
than completing the symmetry D33 began.

**The alternative:** infer only locals and require every module repetition to
write its array type. That makes storage duration alter whether an explicit
count and scalar can determine the same D17 shape, while D34's static image
already represents the result. It was declined.

**Pinned by** `positive/module-array-repetition-inferred`,
`negative/inferred-module-array-repetition-element-not-static`,
`negative/module-array-repetition-index-element`,
`negative/inferred-module-array-repetition-extent-overflow`,
`negative/module-array-repetition-fold-range`,
`negative/inferred-array-repetition-zero-count`,
`negative/array-repetition-countless-inferred-initializer-not-enabled`,
`negative/module-array-mixed-repetition-not-enabled`,
`negative/array-repetition-general-value-not-enabled`, and
`runtime/array-repetition-evaluates-once` on Linux x86-64.

### D36 — A typed local may mix a literal prefix with one repeated suffix

**The tour said** that repetition may follow values already written between the
brackets [0560], that expressions run left to right [0410], and that a local
binding may write its fixed-array type [0040]. It did not state which contexts
first admit that mixed form, whether the repeated expression runs once, or how
the compact fill identifies only the suffix.

**Chosen:** `[e1, ..., ek, of repeated]` may initialize an explicitly typed
local fixed array of length `N` exactly when `1 <= k < N`. The written type
supplies D17's length and scalar element type. Each prefix expression and the
repeated expression must have that scalar type, including [0190]'s contextual
commitment of an untyped integer. A prefix that reaches or passes `N` is refused
because no nonempty repeated suffix remains.

Lowering evaluates each prefix expression and immediately stores it into parts
`1` through `k`, in source order. It then evaluates `repeated` exactly once and
emits one compact `Fill_Array` beginning at one-based part `k + 1`. No hidden
array temporary or array-valued IR result is formed. `Fill_Array` carries its
one-based `First` part; every pre-D36 full fill passes `First = 1`. The verifier
requires `First` to lie within the destination length as well as retaining the
existing destination-shape and scalar-operand checks. Linux x86-64 offsets the
destination by `(First - 1) * element_size` bytes and repeats exactly
`N - First + 1` width-matched stores.

The parser still does not reserve `of`. It recognizes the suffix marker only
after a nonempty comma-terminated prefix and only when the token after `of` can
begin an expression. Thus `[of, other, of]` remains an ordinary three-element
literal and `[of + 1]` remains an ordinary one-element literal whose expression
may name a binding called `of`.

This slice admits no mixed module initializer, inferred binding, argument,
return, discard, nested array or other general array value. D37 separately
admits assignment to an existing mutable fixed-array place, and D38 separately
admits the explicitly typed module static-image form. Full-array
repetition remains governed by D32--D35, so a prefix length of zero is not a
mixed form and does not narrow those existing contexts.

**Why local and explicit:** it is the smallest context that already owns a
runtime destination and supplies both `N` and the scalar type. Admitting module
state would require a mixed static-image representation; inference would need a
new length rule; assignment would expand D29/D32's contextual value boundary.
Each remains independently testable rather than becoming an unstated result of
this slice.

**The alternative:** materialize the prefix and repeated suffix as a complete
array temporary, then copy it to the local. That would hide the observable
prefix-store order, allocate storage proportional to D18's target-sized extent,
and discard the compact fill representation. It was declined.

**Pinned by** the parser, checker, IR, verifier, lowering and Linux x86-64
public-seam cases; `positive/local-array-mixed-repetition`;
`negative/array-mixed-repetition-prefix-too-long`,
`negative/inferred-array-mixed-repetition-not-enabled`,
`negative/array-mixed-repetition-general-value-not-enabled`,
`negative/nested-array-mixed-repetition-not-enabled`; and
`runtime/mixed-array-repetition-is-source-ordered` on Linux x86-64.

### D37 — A mixed prefix may assign a mutable fixed array

**The tour said** that assignment reaches its destination before evaluating its
right-hand side [0410], that a mutable binding may be assigned [1900], and that
mixed repetition evaluates and stores its prefix before evaluating one repeated
suffix [0560]. It did not say whether an existing array place could supply the
mixed form's context, whether partial stores changed definite-assignment state,
or whether both module and local storage used the compact suffix operation.

**Chosen:** `[e1, ..., ek, of repeated]` may be the right-hand side of assignment
to a mutable fixed-array place of type `[N]T` exactly when `1 <= k < N`. The
destination supplies the complete length and scalar element type. Every prefix
expression and `repeated` must have type `T`, including [0190]'s contextual
commitment of an untyped integer. The existing place check retains [1900]'s
mutability requirement, and a prefix that reaches or passes `N` is refused
because no repeated suffix remains.

The destination is reached and evaluated before any right-hand-side expression.
Lowering then evaluates each prefix expression left to right and immediately
stores it into destination parts `1` through `k`. It evaluates `repeated` exactly
once and emits the existing compact `Fill_Array` with `First = k + 1`. The same
IR operation names either a local frame slot or a module datum; no array-sized
temporary, array-valued result, verifier rule or backend operation is added.

Definite-assignment checks every prefix and repeated expression against the state
incoming to the assignment. Stores made while evaluating the mixed form do not
make an initially unassigned destination readable by a later expression in that
same right-hand side. Only successful completion establishes the complete
destination as assigned.

Inferred initialization, nested mixed forms and other general-value contexts
remain refused. D38 independently admits explicitly typed module initialization;
this assignment rule creates no static mixed image and no independently carried
mixed array value, and only forms the result directly in existing mutable
storage.

**Why assignment:** D29 and D32 already establish the destination-first,
contextual assignment boundary for finite literals and full repetition. D36's
ordered prefix stores and `Fill_Array.First`, plus their verifier and backend
paths, express the mixed case without another representation. Extending only
this boundary preserves the independently testable initializer and general-value
refusals.

**The alternative:** form a complete temporary and copy it after all expressions
finish. That would reverse the observable immediate-store semantics, consume
storage proportional to D18's target-sized extent, and make the compact suffix
fill transient rather than the destination operation. It was declined.

**Pinned by** the checker and lowering public-seam cases;
`positive/array-mixed-repetition-assignment`;
`negative/immutable-array-mixed-repetition-assignment`,
`negative/array-mixed-repetition-assignment-element-mismatch`,
`negative/array-mixed-repetition-assignment-prefix-too-long`,
`negative/array-mixed-repetition-assignment-reads-incoming-state`, the retained
initializer, inferred, nested and general-value refusal fixtures; and
`runtime/mixed-array-repetition-assignment-is-source-ordered` on Linux x86-64.

### D38 — A typed module mixed repetition has a compact hybrid image

**The tour said** that repetition is for static patterns in flash [0560], that a
module value must be known when the compiler reads it [1940], and that a mixed
prefix leaves one expression to fill its suffix. It did not say whether an
explicitly typed module array could use that mixed form, how its static image was
represented, whether a zero suffix selected `.data` or `.bss`, or whether a
through-name copy preserved the representation.

**Chosen:** `[e1, ..., ek, of repeated]` may initialize an explicitly typed module
fixed array `[N]T` exactly when `1 <= k < N`. The written type supplies `N` and
`T`; every prefix expression and `repeated` must have type `T`, and each must be
compile-time known under [1940]. Every fold uses the selected target facts and
must fit `T`, including each prefix independently and the one suffix value.
Inferred module initialization, nested mixed repetition and every general-value
mixed form remain refused.

Lowering folds the finite prefix in source order and the repeated expression once.
IR records a **hybrid image** consisting of those `k` folded prefix values, one
folded suffix value, the element type and the declared length. It never records
`N - k` copies. Image verification checks the finite prefix and one suffix value;
the dump renders the same finite run followed by `repeat`; direct-name image
resolution copies that compact representation through chains. None of lowering,
IR, verification, dumping or copying walks or allocates in proportion to `N`.

A hybrid remains a present image when its suffix value is zero, because its
nonempty written prefix makes it explicit `.data`; Linux x86-64 emits the prefix
with width-matched scalar directives and then a constant-size `.rept N - k`
around one zero directive. A full repetition of zero retains D34's absent image
and loader-zeroed `.bss`. For every nonzero suffix the backend uses the same
`.byte`, `.word`, `.long` or `.quad` directive, so a 64-bit pattern reaches the
assembler with all eight bytes rather than GNU `.fill`'s truncated value field.

**Why a hybrid image:** a finite prefix plus one suffix pattern is the source's
own information and is sufficient to emit every byte. Expanding the suffix would
make compile time, host memory, verifier work, dump size and assembly size depend
on D18's target-sized extent; treating a zero suffix as absent would discard the
nonzero prefix and misclassify initialized data as `.bss`.

**The alternative:** lower the initializer to a complete per-position static
image. That would reuse D24's literal run but erase the compactness guaranteed by
repetition and make a legal target-sized declaration an impractical host-sized
compiler computation. It was declined.

**Pinned by** the checker, IR, verifier, lowering and Linux x86-64 backend
public-seam cases; `positive/module-array-mixed-repetition`;
`negative/module-array-mixed-repetition-prefix-not-static`,
`negative/module-array-mixed-repetition-suffix-not-static`,
`negative/module-array-mixed-repetition-fold-range`; the retained inferred,
nested and general-value refusal fixtures; and
`runtime/module-mixed-array-repetition-holds-hybrid` on Linux x86-64.

### D39 — A written module scalar gives `zeroed` its context

**The tour said** that `zeroed` denotes the all-bits-zero image of the type its
context supplies [0540], and [1940] requires a module initializer to be known
when the compiler reads it. It did not say whether a scalar declaration could
supply that context, whether an alias changed the answer, or whether spelling the
zero image required initialized data.

**Chosen:** `zeroed` may directly initialize an explicitly typed module scalar
binding: `[mut] name: T = zeroed`. The written type must resolve, through any
chain of type aliases, to one of [0120]'s enabled scalar types. That resolved
scalar is the literal's context. Its compile-time-known value is `false` for
`bool` and integer zero for every enabled integer type. The rule applies only to
the complete initializer in that declaration. An inferred binding, an explicitly
typed local scalar initializer, scalar assignment, a nested occurrence and every
other expression position remain refused.

Lowering uses exactly D10's existing scalar-zero IR: a false `Truth` for `bool`
and a zero `Number` of the resolved integer type. No new IR operation, startup
code or static fold is introduced. Linux x86-64 therefore uses the existing
zero-data classification and reserves the datum in loader-zeroed `.bss`; it does
not write a zero directive into `.data`.

**Why this boundary:** the declaration already supplies every fact [0540] needs,
and its static zero is the same module image D10 already represents. Restricting
the rule to that direct contextual site admits no generally typed `zeroed` value
and leaves local execution and assignment as independently testable slices.

**The alternative:** make `zeroed` a general scalar expression wherever an
expected type is available. That would also admit locals, assignments, operands,
arguments and returns in one step, erasing the contextual boundaries retained by
D27, D28 and D30. It was declined.

**Pinned by** the checker, lowering and Linux x86-64 backend public-seam cases;
`positive/module-scalar-zeroed-initializer`;
`negative/inferred-zeroed-not-enabled`,
`negative/local-scalar-zeroed-not-enabled`,
`negative/scalar-zeroed-assignment-not-enabled`,
`negative/nested-scalar-zeroed-not-enabled`; and
`runtime/module-scalar-zeroed-reads-zero` on Linux x86-64.
