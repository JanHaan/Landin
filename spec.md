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
reserves twenty-one words; the reserved set of the whole language is
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
              | "sizeof" | "alignof" | "type" | "struct"

```

### [1770] The kernel's literals are integers and the two booleans

The kernel's literals are integers and the two booleans.
Integer literals are untyped and take the type of their context
[0190], defaulting to i32 with none [0200]; the bases and the
separator are [0220]'s. Floats [0210], characters [0250], text
[0260] and raw literals [0280] are described in this tour and are
not enabled yet.
```landin-grammar
literal     ::= integer | "true" | "false"
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
place       ::= selection

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
Evaluation order is left to right and fixed [0410], so the table
decides what binds, never what runs first.
```landin-grammar
primary     ::= literal | selection | call | measurement
              | "(" expression ")"
selection   ::= identifier ("." identifier)*
call        ::= identifier "(" arguments? ")"
measurement ::= ("sizeof" | "alignof") type
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
where a width is wanted. `lenof` is not enabled with them: it measures an
array or a slice and [1790]'s type rule has neither, so it is refused by
name and cites [0370].

**Where the answer comes from** is the other half of this decision and the
half with teeth. The value is not folded by the checker or the lowering:
`Landin.IR` carries `Measure_Size` and `Measure_Align` with the type asked
about, and the backend answers, because a size needs a width and a width
needs a target. That is the seam [0320]'s zero-fill already sits on, and it
keeps the IR target-neutral — the same source emits 8 for `sizeof usize`
against the Linux x86-64 description and 4 against the synthetic 32-bit one.

**The alternative:** `i32`, which is what an untyped literal would default
to and so the least surprising answer for a reader who has only read [0200];
declined because it makes the common use — comparing against or multiplying
by a width — start with a conversion. Or folding in the checker, which
would put a target fact in a stage this repository has kept target-neutral
on purpose, and which `Landin.IR`'s own header already argues against for
the shifts.

**Pinned by** `positive/measurement-of-a-type`,
`runtime/measurements-answer-for-the-target`, and the backend case that
emits one source against two target descriptions.

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
`positive/array-types-alias-and-agree`.
