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

The kernel's literals are integers, the two booleans, and contextual `zeroed`.
Integer literals are untyped and take
the type of their context [0190], defaulting to i32 with none [0200]; the bases
and the separator are [0220]'s. `zeroed` has no type of its own: [0540] gives it
the all-bits-zero image of a directly supplied initializer, assignment or
field-label context. D27--D30 establish fixed-array contexts, D39--D43 scalar
contexts, D49 and D57--D59 whole array-field and ordinary-struct contexts,
D62 the depth-one indexed field place, and D64--D67 labelled struct fields and
static images. It remains refused where no enabled construct supplies that
context. Floats
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
it is read [0080]. The kernel's types are the eleven scalar names, fixed arrays,
and what [1795] declares from them: aliases and named ordinary structs with
enabled scalar or fixed-array fields. Variants and the other TYPES YOU DECLARE
remain deferred. A type position holds a declared name either way, since
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
A place is [1820]'s indexed selection, so a binding, a field of a struct, or
an enabled array element is written
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
An ordinary-struct literal is [0710]'s nonempty run of labelled field values,
optionally followed by [0720]'s contextual fill. D64--D71 state the contexts
that admit it. D72's construction prefixes the same run with the ordinary
struct type it builds; the all-fill spelling remains refused by name.
Evaluation order is left to right and fixed [0410], so the table
decides what binds, never what runs first.
```landin-grammar
primary     ::= literal | array_literal | array_repetition | struct_literal
              | construction | indexed | call | measurement
              | "(" expression ")"
array_literal ::= "[" expression ("," expression)* "]"
array_repetition ::= "[" integer "of" expression "]"
                   | "[" "of" expression "]"
                   | "[" expression ("," expression)* "," "of" expression "]"
struct_literal ::= "(" field_value ("," field_value)*
                   ("," "of" expression)? ")"
field_value ::= identifier ":" expression
construction ::= identifier "(" field_value ("," field_value)*
                 ("," "of" expression)? ")"
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
- the element type of a contextual array literal or repetition
- the field type of a contextual labelled struct literal
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
proceed without one. The decisions are listed here with what
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

D54 later applies the same field boundary when an array-bearing struct is
copied whole. Scalar fields keep these individual bits; a fixed-array field is
complete only through its own D48 sparse facts or D49/D50/D52/D53 whole-field
fact.
Normal completion assigns every destination scalar bit and every destination
array-field whole fact without conflating the two representations.
A binding or assignment the checker has already refused reads nothing for
definite assignment: the statement cannot execute, so its owning report is not
followed by an L0302 from an otherwise unassigned source inside it. A named
return the checker has refused is likewise not a destination [1910] can require
at `return` or at the body's end; its owning ABI report stands alone.

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

A direct storage name resolves to a module or local binding. The name of a type
declaration, even one whose declared type is the required fixed array, owns no
runtime storage and is refused by the existing whole-value L0304 rather than
being lowered as a copy source.

A branch merge intersects what the facts *mean*, not merely how they happen to
be represented. Whole on both paths remains whole; whole on one path and
sparse facts on the other keeps those sparse facts; sparse on both keeps their
intersection. Completeness is decided by counting the sparse facts already
present, never by walking an array extent that D18 permits to fill the target.

This kernel admits an array name as a whole value only in this copy context;
D50 later lets either endpoint be a directly selected fixed-array field. D21
reuses only the direct-name storage read for initializers; D51 later admits a
directly selected fixed-array field as the source of a local initializer only.
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
`negative/local-array-copy-not-assigned-on-every-path`,
`negative/array-type-name-is-not-storage`, and
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

The source must be a storage binding rather than a type declaration. A type
name that happens to declare the contextual array type is refused with L0304;
it cannot supply an initial image or a local copy address.

At module scope `source` is exactly one resolved module storage name. Its
initial-image chain follows declaration identities, across forward references
and type-alias chains, and must terminate either at a module array whose
initializer is omitted or at a module array whose initializer is D24's
explicit literal. A chain that returns to a declaration is [1940]'s value
worked out from itself. Each destination on the chain nevertheless owns
distinct storage initialized with the terminal image rather than aliasing
its source. Nothing runs before the entry point [1460], so no module-level
copy instruction exists.

D70 later permits the same module image chain to pass through one directly
selected fixed-array field.  The selection remains a contextual initializer
link rather than a general array value.

D60/D61 later apply the same declaration-identity chain to explicitly typed
and inferred module ordinary structs. Their presently enabled terminal images
are all zero, so no finite aggregate image is needed yet.

Every other array initializer value remains refused: D51 later admits a
directly selected fixed-array field for a local binding and D70 its module
counterpart, D23 admits one
contextual local array literal [0520], D24 admits its module counterpart,
while an inferred literal, `zeroed` [0540], repetition [0560], a slice
[0570], a call, and every other indexed or selected subexpression are each
their own later slice. This decision does not
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
`negative/array-type-name-is-not-storage`,
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
`lenof`, a general whole value of D46/D47's array-field struct outside D54's
contextual copy and D55/D56's local initializers, or its array field as a
whole value or place — stays refused.
D48 separately admits one element
selected through that field.

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

This is one contextual initializer and not a general array value. D24 later
admits the explicitly typed module form, D25 the inferred local form and D29
assignment to an existing array. A parameter, return, argument or discard
still refuses the literal. An empty literal, repetition [0560], `zeroed`
[0540], slices [0570], nested array values and non-scalar elements remain
outside this slice. In particular, requiring one expression in the literal
grammar does not decide whether a programmer may write the zero-length type
`[0]T`.

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
`negative/local-array-literal-element-mismatch`, and
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
admits a typed local array initializer, D30 an array assignment, D39 a typed
module scalar initializer and D40 a typed local scalar initializer. Every
inferred form remains refused. D27 introduces no IR opcode, temporary, startup
copy, or source-order element evaluation. Repetition [0560],
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
`negative/inferred-zeroed-not-enabled`, and
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
and no result. D57 later gives field zero of that destination-only operation a
whole aggregate's padded extent as well; its array meaning is unchanged. The
Linux x86-64 backend forms the slot address, takes the target
byte extent, and emits one forward `rep stosb` clear. Compiler work and IR size
therefore remain independent of the target-sized length D18 admits, and no
array-valued temporary or hidden zero datum exists.

This remains one contextual initializer. D28 does not infer a shape for
`name := zeroed`; D30 separately admits array assignment, D39/D40 typed module
and local scalar initializers, and D41 scalar assignment. `zeroed` as an
argument, return, discard, nested or general expression remains refused.
Module arrays continue to use D27's absent static image rather than this
runtime instruction.
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
`negative/inferred-zeroed-not-enabled`, and
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
elements and each expression must have that element type. At this boundary the
fixed-array places are direct local or module storage names. D52 later admits a
directly selected fixed-array field under the same literal rule. [1900] still
decides whether either may be written.

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

D49 extends this contextual assignment to one fixed-array field selected
immediately from enabled struct storage without making the field a general
array place or value.

The destination is reached first; `zeroed` evaluates no source expressions and
names no source storage. Lowering emits one `Clear_Array` carrying that local
frame slot or module datum; D49 additionally carries the declaration-order field
identity, never a target byte offset. The verifier resolves its complete array shape, and
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

At this boundary an assignment destination is a direct local or module array
storage name. D53 later admits a directly selected fixed-array field under the
same full-repetition rule.

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
initializer or an existing mutable array place. D33/D35 later admit counted
local and module inference, D34 the typed module static image, and D36--D38 the
mixed-prefix forms. Argument, return, discard, nested repetition and general
array values remain refused. Since `of` remains [1760]'s contextual spelling
rather than a reserved word, `[of, other, of]` remains an ordinary literal
whose elements may name a binding called `of`; repetition is recognized only
where the token after `of` can begin its scalar expression. Thus `[of + 1]`
also remains an ordinary one-element literal.

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
`negative/array-repetition-reads-incoming-state`, and
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
count-less inferred repetition and every general array value position remain
refused. D36 later admits the explicitly typed local mixed form, D37 its
assignment and D38 the explicitly typed module image.

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

At this boundary the place is a direct local or module array storage name. D53
later admits a directly selected fixed-array field under the same mixed rule.

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
the complete initializer in that declaration. D40 separately admits the local
initializer and D41 the scalar assignment; an inferred binding, a nested
occurrence and every other expression position remain refused.

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
`negative/nested-scalar-zeroed-not-enabled`; and
`runtime/module-scalar-zeroed-reads-zero` on Linux x86-64.

### D40 — A written local scalar gives `zeroed` its context

**The tour said** that `zeroed` denotes the all-bits-zero image of the type its
context supplies [0540], and that an initialized local has its value before a
later statement reads it [0110]. It did not say whether a local scalar
initializer supplied that context, whether an alias changed the answer, or how
the value reached local storage.

**Chosen:** `zeroed` may directly initialize an explicitly typed local scalar
binding: `[mut] name: T = zeroed`. The written type must resolve, through any
chain of aliases, to an enabled scalar type and supplies the literal's context.
The value is `false` for `bool` and integer zero for every enabled integer type.
The complete initializer establishes the binding as definitely assigned. D39
separately governs module initialization and D41 assignment; inferred
initialization, nested occurrences and every other expression position remain
refused.

Lowering emits D10's existing false `Truth` or typed zero `Number`, followed by
the ordinary frame-slot `Store`. It introduces no new IR value, operation or
local initialization path.

**Why this boundary:** an explicitly typed local already supplies the same
complete scalar context as D39's module declaration, and the existing
constant/store path represents the result without making `zeroed` a general
expression.

**The alternative:** admit every expected-scalar expression context together.
That would silently include assignment, arguments, returns and operands instead
of preserving each contextual boundary for executable evidence. It was
declined.

**Pinned by** the checker and lowering public-seam cases;
`positive/local-scalar-zeroed-initializer`;
`negative/inferred-zeroed-not-enabled`,
`negative/nested-scalar-zeroed-not-enabled`; and
`runtime/local-scalar-zeroed-reads-zero` on Linux x86-64.

### D41 — A mutable scalar assignment destination gives `zeroed` its context

**The tour said** that assignment reaches its destination before evaluating its
right-hand side [0410], that only a mutable binding may be assigned [1900], and
that `zeroed` takes the all-bits-zero image of its context [0540]. It did not say
whether a scalar destination supplied that context, whether aliases changed the
answer, or when the assignment established local definite assignment.

**Chosen:** `zeroed` may be the complete right-hand side of assignment to a
mutable scalar local slot or module datum. The destination type must resolve,
through any chain of aliases, to an enabled scalar type and supplies the
literal's context. The value is `false` for `bool` and integer zero for every
enabled integer type. The ordinary destination check runs first, retaining
mutability and every invalid-place or invalid-type refusal. Only successful
completion establishes the destination as definitely assigned.

The destination is reached and evaluated before the right-hand side, as for
every assignment. Lowering emits D10's existing false `Truth` or typed zero
`Number`, then uses the ordinary scalar `Store` for a local slot or `Store_Datum`
for a module datum. No new IR value, operation, temporary or backend path is
introduced.

Inferred initialization remains governed by D39/D40 and is refused without a
written type. Assignment to a scalar struct field or fixed-array element is governed separately
by D42, and assignment to a named return is not this direct-storage slice. A
nested occurrence, argument, return, operand, discard and every other general
`zeroed` expression remain refused; this rule admits only the complete contextual
right-hand side of a direct binding assignment.

**Why assignment:** the mutable destination already owns the scalar type and
storage the literal needs. Reusing ordinary assignment preserves destination
order, mutability, definite assignment and lowering rather than inventing a
carried scalar `zeroed` value.

**The alternative:** synthesize an independently typed zero value before
reaching the destination. That would reverse [0410]'s assignment order and make
a contextual form appear to be a general expression. It was declined.

**Pinned by** the checker and lowering public-seam cases;
`positive/scalar-zeroed-assignment`;
`negative/immutable-scalar-zeroed-assignment`,
`negative/inferred-zeroed-not-enabled`,
`negative/nested-scalar-zeroed-not-enabled`; and
`runtime/scalar-zeroed-assignment-clears-values` on Linux x86-64.

### D42 — A scalar subobject assignment destination gives `zeroed` its context

**The tour said** that assignment reaches its destination before evaluating its
right-hand side [0410], that selection reaches a struct field or fixed-array
element [0520], that only writable places may be assigned [1900], and that
`zeroed` takes the all-bits-zero image of its context [0540]. D41 supplied that
context only for a direct mutable scalar binding.

**Chosen:** `zeroed` may be the complete right-hand side of assignment to an
ordinary scalar struct field or fixed-array element selected immediately from a
mutable local slot or module datum. The selected field or element type must
resolve, through every representable alias, to an enabled scalar type and supplies
the literal's context. The value is `false` for `bool` and integer zero for every
enabled integer type. D62 later applies this same scalar rule when D48's element
is reached through a fixed-array field of that directly named storage.

The ordinary place check runs first, retaining mutability and every invalid-place,
invalid-selection and invalid-type refusal. The destination and a computed index
are evaluated exactly once and before the right-hand side. A compiler-known index
continues to use the existing `Store_Field`; a computed index continues to carry
its ordinary bounds check into the existing `Store_Element`. The same slot-reaching
forms serve local storage. No new IR value, operation, temporary or backend path
is introduced.

Successful completion has the ordinary definite-assignment effect of writing that
one field or compiler-known element. It neither assigns any sibling field nor the
array as a whole; a computed element retains the existing per-element facts and
bounds behavior. A failed or refused assignment establishes nothing.

D41's direct binding assignment remains unchanged. An immutable subobject, a
selection from an invalid place, a nested subobject destination in this slice,
and assignment to a named return remain outside it; D43 treats the last as its
own contextual position and D62 later admits the one nested shape D48 already
makes an ordinary scalar place. D49 separately treats one fixed-array field as a contextual `zeroed`
destination without changing this scalar rule. D65 later applies the same
typed scalar image to a field label inside D64's contextual struct literal.
Inferred initialization and every nested, argument, return, operand,
discard or other general `zeroed` expression remain refused.

**Why the selected type:** a scalar subobject already owns both the type and the
storage that the contextual literal needs. Reusing the ordinary place and store
paths preserves source order, definite assignment and bounds checks without
turning `zeroed` into a general value.

**The alternative:** infer an independent scalar zero before selecting the field
or evaluating the index. That would reverse [0410]'s order and bypass the place
semantics this assignment must preserve. It was declined.

**Pinned by** the checker and lowering public-seam cases;
`positive/scalar-subobject-zeroed-assignment`;
`negative/immutable-scalar-zeroed-assignment`,
`negative/inferred-zeroed-not-enabled`, and
`negative/nested-scalar-zeroed-not-enabled`;
`positive/struct-array-field-element-zeroed`;
`positive/struct-literal-array-field-forms`;
`negative/struct-array-field-element-zeroed-immutable`;
`negative/struct-array-field-element-zeroed-nested`;
`runtime/scalar-subobject-zeroed-assignment-clears-values`; and
`runtime/scalar-subobject-zeroed-computed-index-traps` on Linux x86-64.

### D43 — A scalar named return gives complete `zeroed` assignment its context

**The tour said** that a named return is a writable place [1800], that `return`
carries the value previously assigned there [1810], that every return path must
assign it [0930], and that `zeroed` takes the all-bits-zero image of its context
[0540]. D41 supplied assignment context only from mutable local and module
bindings, while D42 treated their immediate scalar subobjects separately.

**Chosen:** `zeroed` may be the complete right-hand side of assignment to a scalar
named return. The return's declared type must resolve, through every representable
alias, to an enabled scalar and supplies `false` for `bool` or typed zero for every
enabled integer. The ordinary place check still runs before the right-hand side,
and successful ordinary assignment establishes the named return for [0930]'s
definite-assignment check.

Lowering reuses the named return's existing frame-slot `Store` path with D10's
existing false `Truth` or typed zero `Number`. The explicit or implicit `return`
then uses its ordinary load and `Leave`. No new scalar value form, temporary, IR
operation, verifier rule or backend path is introduced.

D39--D42's initializer, binding and immediate-subobject contexts remain unchanged.
Immutable and invalid destinations retain the ordinary place refusals. A named-
return subobject is not admitted by this rule; aggregate named returns are not an
enabled value context and remain a separate future question. Inferred
initialization and every nested, argument, return-expression, operand, discard or
other general `zeroed` expression remain refused.

**Why the named-return type:** the return place already owns the type and storage
that the contextual literal needs. Its ordinary assignment is also exactly the
flow event [0930] requires, so a special return initialization rule would duplicate
both storage and definite-assignment semantics.

**The alternative:** make `zeroed` an independently inferred scalar value usable by
any return-related expression. That would erase the complete-right-hand-side
boundary and broaden general scalar values well beyond the evidence. It was
declined.

**Pinned by** the checker and lowering public-seam cases;
`positive/named-return-zeroed-assignment`; and
`runtime/named-return-zeroed-reads-zero` on Linux x86-64.

### D44 — A named ordinary scalar-field struct has byte measurements

**The tour said** that `sizeof T` and `alignof T` ask the target for byte
measurements and produce `usize` [0370], that a struct's fields are laid out in
declaration order with target padding [0750], and that aliases denote the same
type [0710]. D14 enabled scalar measurement and D17 enabled fixed arrays, but the
implemented checker still refused every aggregate measurement.

**Chosen:** `sizeof T` and `alignof T` are admitted when `T` resolves directly or
through any representable alias chain to a named ordinary struct whose fields are
all enabled scalars. `sizeof` is the target's padded size of that field run and
`alignof` is its required alignment. Both results remain `usize`. A malformed or
unresolved measured type retains its one owning diagnostic rather than acquiring
a second measurement refusal.

Lowering carries the struct compactly in target-neutral IR as its declaration-
order run of scalar field types. It carries neither checker-computed offsets nor
size or alignment constants. A backend with target facts replays that run through
`Landin.Targets.Place` and reads `Landin.Targets.Size_Of` or
`Landin.Targets.Alignment_Of`; module-scalar folds use the same backend seam. The
checker also evaluates the leaf during [1940]'s target-aware validation, and
lowering reads that same checked layout when a static module array image must
contain the concrete answer. This preserves D24's fold agreement without putting
a target answer into ordinary measurement IR. The verifier requires a measurement
result to be `usize`, and the dump exposes the field run.

This decision does not enable array or struct fields, nested aggregate
composition, inline anonymous struct measurement, `lenof` on a struct, aggregate
values, aggregate parameters or returns, or a struct in any other expression or
storage context. Scalar and fixed-array measurements are unchanged.

**Why the field run:** field types and declaration order are the complete
representation-independent input to [0750]'s placement arithmetic. Carrying that
small input lets every target derive one authoritative answer without putting a
target choice or a checker cache into IR.

**The alternative:** lower the checker-prepared size and alignment as integer
constants. That would make target-dependent checker results part of otherwise
target-neutral IR and give downstream consumers no way to establish that the
answer came from their own target description. It was declined.

**Pinned by** the lowering and backend public-seam cases;
`positive/measurement-of-structs`; the one-report
`negative/measuring-refused-types`;
`negative/struct-measurement-fold-overflow`; the recorded IR dump; and
`runtime/measurements-answer-for-the-target` on Linux x86-64.

### D45 — A named ordinary struct may hold a fixed scalar array for measurement

**The tour said** that a struct field has a type [0670], that fields are laid
out in declaration order with target padding [0750], that a fixed array is a
value with a compile-time length [0520], and that `sizeof T` and `alignof T`
ask the target for byte measurements [0370]. D44 admitted only scalar fields,
so the first aggregate field still had no representation the checker and
backend shared.

**Chosen:** a field of a named ordinary struct may be a fixed array of an
enabled scalar, written directly or through an alias. Layout places that array
once in declaration order, as one extent of length times target element size
at the array's target alignment. D17's internal zero-element shape contributes
size zero and alignment one here as everywhere else; this does not decide
whether source may spell `[0]T`.

The complete padded struct must fit the selected target's `usize`. If it does
not, the checker reports L0300 at the struct body, records no layout, and a
later measurement adds no second report. L0300 therefore owns compile-time
magnitudes that a context or target cannot hold, including D18's array extent
and this enclosing aggregate extent; it is not limited to a literal token.

`sizeof T` and `alignof T` admit the resulting struct directly or through any
representable alias chain and still produce `usize`. Lowering carries its
declaration-order run in target-neutral IR: a scalar field is one scalar leaf,
and an array field is one element-and-count leaf no matter how large its
length. It carries no checker-computed offset, byte size or alignment. Each
backend derives the padded answer from its own target facts. Module-scalar
folds and static module array images use the same checked layout as D44. The
verifier requires a scalar measurement leaf to have its canonical length one;
the dump exposes an array leaf as `[N]element`.

At this decision a struct with an aggregate field still had no runtime storage
or value context. D46--D65 later add its module and frame storage, indexed and
whole-field places, contextual initializers, whole copies, zero images and
labelled literals. Parameters, returns, a struct field of struct type, deeper
nested aggregate composition, inline anonymous measurement and `lenof` on a
struct remain deferred. Scalar-field struct measurement is unchanged.

**Why the compact leaf:** D18 permits an array length no host or IR vector can
enumerate, while its element and count are the complete representation-
independent input to D17's extent rule. Replaying that leaf through target
placement preserves D44's one authority for layout.

**The alternatives:** expand one IR field per array element, or carry the
checker-computed size and alignment. The first cannot represent enabled
extents and the second puts a target answer into target-neutral IR, so both
were declined. Refusing a zero-length field specially was also declined:
D17 already defines the internal shape, and source legality remains one
future decision for every `[0]T` context rather than one D45 exception.

**Pinned by** the checker, target, lowering, verifier and backend public-seam
cases; `positive/measurement-of-struct-array-fields`;
`negative/struct-array-field-layout-overflow`; the reworked one-report
`negative/struct-with-an-array-field`; the recorded IR dump; and
`runtime/measurements-answer-for-the-target` on Linux x86-64.

### D46 — An array-field struct may be zeroed module state

**The tour said** that an array is a value whose size is part of its type
[0520], that all-zero is a valid image for an aggregate of zero-image parts
[0540], that a struct has its declared fields [0670], that those fields keep
their order and target padding [0750], and that a module is a set of
declarations [1740]. D45 gave the checker a complete layout for a named ordinary
struct with fixed-scalar-array fields, but deliberately left every runtime
storage and value context refused.

**Chosen:** a declaration-only module binding may have a type that resolves,
directly or through aliases, to a named ordinary laid-out struct whose fields
are enabled scalars or fixed arrays of enabled scalars. D10 supplies the whole
object's all-zero image, so neither the array length nor the number of fields is
expanded into initializer work. Module state has no local definite-assignment
fact to establish: its scalar fields read as zero from declaration and ordinary
mutable scalar fields may be assigned, including a scalar sibling after an
array field.

This admits the containing storage, not the array field as a value or whole
place. Selecting that field reported L0304 once at the selection in this
slice; D48 supersedes that result only where the selection is immediately the
base of an index. A
local declaration of the same struct also reported L0304 in this slice because
the frame's aggregate-slot representation remained scalar-field-only; D47
supersedes that storage boundary. An initializer, whole
read or copy, parameter, return and every other whole-value context remain
refused in this slice; D54 later supersedes the whole-copy boundary and
D55/D56, after D47 supplies the frame representation, the explicitly typed or
inferred local direct-storage-name initializer boundary.
Struct fields of struct type and other nested aggregate composition remain
outside D45 and therefore outside this decision. D17's internal
zero-length field rule is unchanged, and source `[0]T` legality remains
undecided.

Lowering records the module datum as one declaration-order run of neutral field
shapes. A scalar shape has canonical length one; a fixed-array shape carries one
scalar element and one count. This is the same representation-independent
shape D45 measurement IR uses, but item and measurement runs remain distinct so
one cannot be mistaken for the other. The verifier rejects a noncanonical
scalar shape and rejects a scalar `Load_Field` or `Store_Field` aimed at an
array shape. No target offset, byte size, alignment or expanded element run is
put into IR.

The backend replays those shapes through the same target placement used for
measurement and reserves the complete padded object in zeroed storage. Scalar
field operations use the resulting target offset. On x86-64, a nonzero offset
in any aggregate containing an array field is formed from the symbol address
and a full-width register constant, so D18-sized fields cannot create an
unencodable symbol-plus-displacement relocation.

**Why module state first:** it already has D10's complete image and needs only
one compact datum description. Enabling the same type in a frame would require
the slot representation and nested-place operations to describe the array;
enabling a whole value would additionally settle copies, initialization,
parameters and returns. Keeping those separate makes this slice executable
without implying any of them.

**The alternatives:** flatten the array into one scalar item field per element,
or admit array shapes in every aggregate slot and field operation at once. The
first cannot represent D18's enabled lengths, and the second couples storage,
nested-place and whole-value decisions that have different invariants, so both
were declined.

**Pinned by** the checker, lowering, verifier and backend public-seam cases;
`positive/struct-array-field-module-state`;
`negative/struct-array-field-selection-not-enabled`;
the recorded IR dump; and
`runtime/struct-array-field-state-scalar-siblings` on Linux x86-64.

### D47 — An array-field struct may be declaration-only local storage

**The tour said** that a declaration-only binding must be assigned before it
is used [0080], that an array is a value whose length is part of its type
[0520], that a struct has its declared fields [0670], and that those fields
keep declaration order and target padding [0750]. D16 made each field of a
struct local its own definite-assignment fact. D45 supplied the complete
layout for scalar and fixed-scalar-array fields, while D46 deliberately stopped
after module storage because the frame IR could describe only scalar fields.

**Chosen:** a declaration-only local binding may have a type that resolves,
directly or through aliases, to a named ordinary laid-out struct whose fields
are enabled scalars or fixed arrays of enabled scalars. The complete object is
one frame cell with the padded extent and alignment derived from the selected
target. Unlike D46's module state, this local is not implicitly zeroed and no
stores are invented at its declaration.

D16 continues to track each accessible scalar field independently. A scalar
sibling before or after the array must be assigned on every arriving path
before it is read, and assigning one sibling assigns no other. The array field
had no D16 fact in this slice because it was not selectable as a value or
nested place: selection reported L0304 once and the definite-assignment
recovery walk added no whole-struct report. D48 supersedes that boundary for an
indexed element and gives it a field-qualified fact. A local
initializer, whole read or copy, parameter, return and every other whole-value
context remain refused in this slice; D54 later supersedes the whole-copy
boundary and D55/D56 the explicitly typed or inferred direct-storage-name
local initializer boundary.
Struct fields of struct type and broader nested aggregate
composition also remain outside the laid-out kernel.

Lowering records the cell as one aggregate slot whose declaration-order field
run uses D45's neutral shape: a scalar leaf has canonical length one and a
fixed-array leaf carries one scalar element and one count. Slot, item and
measurement runs remain distinct. The dump exposes the slot run, the verifier
rejects a noncanonical scalar slot leaf, and `Load_Field` or `Store_Field` may
name only a scalar part. Thus the inaccessible array field cannot cross the
verified scalar operation boundary even if lowering is damaged.

The backend replays every slot shape through the same target placement as D45
measurement and D46 module storage. D17's internal zero-element shape therefore
contributes size zero and alignment one here too without deciding whether
source may spell `[0]T`. Scalar field operations use the resulting offset.
On x86-64 the existing signed frame-displacement limit applies to the complete
cell: a routine whose padded frame is not addressable reports L0504 before
assembly is emitted, including when an array field is what makes it too wide.

**Why storage without a value:** the frame needs only a compact description and
D16 already supplies the scalar-field initialization rule. Enabling the array
field as a place requires an aggregate-aware nested-place representation and
computed element addressing; enabling a whole value additionally settles
initializers, copies, parameters and returns. None is required to allocate the
cell and use its scalar siblings.

**The alternatives:** keep local storage refused until nested indexing, or
enable array-field selection and whole values in the same slice. The first
would preserve a storage-class distinction after item and slot IR can express
the same neutral shape; the second combines independent representation,
definite-assignment and calling-convention questions. Both were declined.

**Pinned by** the checker, lowering, verifier, driver and backend public-seam
cases; `positive/struct-array-field-local-storage`;
`negative/struct-with-an-array-field`;
`negative/struct-array-field-local-selection-not-enabled`;
`negative/struct-array-field-local-unassigned-scalar`; the recorded IR dump;
and `runtime/struct-array-field-local-scalar-siblings` on Linux x86-64.

### D48 — An element of a fixed-array field is a place

**The tour said** that an array element is a place [0520], that a computed
index traps before an address is formed [0580], that a struct has its declared
fields [0670], and that assignment uses the root binding's mutability [1900].
D46 and D47 admitted the containing module datum and local frame cell, but
stopped before an array field could be reached.

**Chosen:** where `s` directly names D46 module state or a D47 local and `f` is
a fixed array of enabled scalars, `s.f[i]` is admitted as a read, assignment
destination, or `inc`/`dec` target. The index is exactly `usize` under D18. A
compiler-known index outside the field length is refused under [1950]; every
other index is checked at runtime and traps before any address is formed under
[0580]. Writability is the root binding's. The selection `s.f` is typed as an
array only in this index-base context: as a whole value, copy endpoint, or
non-`zeroed` assignment destination it remains refused with L0304. D49 later
supersedes the complete `s.f = zeroed` statement, D50 later supersedes the
copy-endpoint boundary, and D52/D53 later supersede literal and repetition
destinations.

D10 makes module state complete from declaration, so an indexed module-field
read has no assignment requirement. A declaration-only local instead follows
D19 and D22 per field. Its compiler-known element facts are keyed by binding,
field, and position; assigning one position establishes only that fact. A
computed read requires the whole-field fact, which holds once every declared
position in that field has a fact on every arriving path. A computed write
establishes no fact and clears none, and `inc`/`dec` first requires the read.
An internal zero-length field is vacuously complete, preserving D17 without
deciding whether source may spell `[0]T`.

Lowering carries the root storage identity, the declaration-order field
position, and the index through the existing `Load_Element` and
`Store_Element` operations. Field zero continues to mean that the storage is
itself an array; a positive field selects an array shape inside an aggregate.
No checker-computed byte offset enters IR. Even a compiler-known index through
a field uses the element operation: adding a two-level static-part encoding for
that optimization was declined. Array copy, clear, and fill operations still
name whole storage only and therefore require field zero in this slice; D49
later adds a destination field identity to `Clear_Array`, and D50 adds source
and destination identities to `Copy_Array`.

The verifier checks a positive element field against the aggregate field run
before it reads the shape, and rejects an absent field or a scalar field. It
then applies the existing `usize`, result, and stored-value rules to the array
shape's element. The dump exposes the field identity. Each backend derives the
field offset, length, and element width from its selected target. On x86-64 a
module field base is formed in registers so a D18-wide preceding field remains
addressable; a local uses the field displacement inside the L0504-bounded frame.
In both cases the bounds trap precedes field and element address arithmetic.

**Why the scoped selection:** admitting `s.f` generally would also imply whole
field copies and `zeroed`, which have separate initialization and lowering
rules. D49 later settles only the contextual clear. Index-base typing enables the scalar subobject without pretending the
array field is an ordinary value. Field-qualified local facts preserve D19's
independent-element rule when one struct contains more than one array field.

**The alternatives:** enable module indexing first and defer locals, introduce
new field-element opcodes, or lower an address-of-field value. The first leaves
D47 storage unusable despite the same compact shape; the second duplicates the
existing element trap and operand rules; the third introduces addresses into a
target-neutral IR that has none. All were declined.

**Pinned by** the IR, verifier, lowering, and backend public-seam cases;
`positive/struct-array-field-module-state` and
`positive/struct-array-field-local-storage`;
`negative/struct-array-field-selection-not-enabled`;
`negative/struct-array-field-local-selection-not-enabled`;
`negative/struct-array-field-immutable-element`;
`negative/struct-array-field-index-not-usize`;
`negative/struct-array-field-index-outside`;
`negative/struct-array-field-local-computed-unassigned`;
`negative/struct-array-fields-keep-assignment-separate`;
`negative/struct-array-field-element-not-assigned-on-every-path`;
`negative/scalar-struct-field-is-not-indexable`;
`negative/struct-array-field-zeroed-not-enabled`; the recorded IR dump;
`runtime/struct-array-field-state-scalar-siblings`;
`runtime/struct-array-field-local-scalar-siblings`;
`runtime/struct-array-field-computed-index-traps`; and
`runtime/struct-array-field-local-computed-index-traps` on Linux x86-64.

### D49 — `zeroed` clears one fixed-array field

**The tour said** that assignment reaches its destination before its value
[0410], that an array's complete value may be all-bits-zero [0520], that
`zeroed` takes its type from context [0540], that a struct has its declared
fields [0670], and that writability belongs to the root binding [1900]. D48
admitted an element of a fixed-array field while deliberately leaving the
field itself outside every whole-place context.

**Chosen:** where `s` directly names D46 module state or a D47 local and `f` is
a fixed array of enabled scalars, `s.f = zeroed` is admitted as a statement.
The selection is typed as an array only as the destination of that complete
assignment. At this boundary, as a value, copy source or destination,
non-`zeroed` destination, `inc`/`dec` target, operand, or nested `zeroed`
expression it remains refused with L0304; D50 later supersedes the copy
endpoints, D52 the literal destination and D53 repetition destinations. An
immutable root reports L0303 first and alone under [1900].
The destination is reached first and `zeroed` evaluates nothing [0410]. Every
enabled scalar has a zero image, so the complete field has one [0540].

D10 already makes a module field complete, so clearing it changes no assignment
fact. Normal completion for a local records the whole-field fact keyed by the
binding and field. Every compiler-known or computed element of that field may
then be read; a later computed write keeps the fact under D22, and no scalar
sibling or other array field is affected. A merge keeps the fact only when every
arriving path has it. An internal zero-length field is vacuously complete and
clears zero bytes, preserving D17 without deciding whether source may spell
`[0]T`.

Lowering emits the existing compact `Clear_Array` with the root storage and the
field's declaration-order identity. Field zero continues to mean that the
storage is itself an array. At this boundary `Copy_Array` and `Fill_Array`
remain field-zero-only, so this does not admit a whole field copy or fill; D50
later adds both copy endpoint identities. No checker-computed offset, source
operand, temporary, or per-element instruction enters IR. The dump exposes a
positive clear field.

The verifier checks a positive field against the aggregate run before it reads
the shape, rejecting an absent field or a scalar field with the same faults D48
uses. Each backend derives the field offset, element width, and byte extent from
its selected target. Linux x86-64 forms a module field base in registers so a
D18-wide preceding field remains addressable, uses the L0504-bounded displacement
for a frame field, and emits one forward byte clear. A zero extent gives
`rep stosb` a zero count.

**Why only the contextual clear:** a field supplies exactly the shape and
storage `zeroed` needs, while a general selection would also admit source reads,
copies, literals, repetitions, arguments, returns, and hidden array-sized
temporaries. Those operations have distinct source-order and definite-assignment
rules. Keeping the selection scoped preserves their refusal.

**The alternatives:** admit general whole field places and copies together,
emit one scalar store per element, put a field into every array-storage endpoint,
or admit aggregate `zeroed` initialization in the same slice. The first and last
broaden the value boundary, the second makes compiler work proportional to a
D18 extent, and the third representation widens copy and fill before either can
use it. All were declined.

**Pinned by** the checker, IR, verifier, lowering, and backend public-seam cases;
`positive/struct-array-field-zeroed-assignment`;
`negative/struct-array-field-zeroed-not-enabled`;
`negative/immutable-struct-array-field-zeroed`;
`negative/struct-array-field-clear-keeps-fields-separate`;
`negative/struct-array-field-clear-not-on-every-path`; the recorded IR dump;
`runtime/struct-array-field-state-scalar-siblings`; and
`runtime/struct-array-field-local-scalar-siblings` on Linux x86-64.

### D50 — A fixed-array field is a whole-copy endpoint

**The tour said** that assignment reaches its destination before its value
[0410], that assigning an array copies its complete value [0520], that a struct
has its declared fields [0670], and that writability belongs to the root binding
[1900]. D20 admitted one compact copy between direct array storage names. D48
made an indexed element of a fixed-array field reachable, and D49 made the
complete field a contextual `zeroed` destination, while both kept a field out
of copy syntax.

**Chosen:** where `s` directly names D46 module state or a D47 local and `f` is
a fixed array of enabled scalars, `s.f` may be either endpoint of D20's copy:
`s.f = t.g`, `s.f = name`, `name = s.f`, and `s.f = s.f`. A direct name has
field identity zero; a selection has its declaration-order field identity.
Both endpoints must have the same D17 length and scalar element type. A
disagreement is refused with D20's L0301 at the source, related to the
destination. The destination root must be mutable under [1900]; L0303 owns an
immutable destination first and alone. The destination is reached before the
source under [0410], and neither endpoint evaluates an element.

The source is read as a whole. D10 makes a module field complete. A local
source field must be complete on every arriving path: D49's clear or an earlier
D50 copy supplies its binding-and-field whole fact, while D19/D48's sparse
facts also suffice when they cover the declared length. An internal zero-length
field is vacuously complete. Self-copy follows the same rule and therefore
cannot make an unassigned field assigned. Normal completion records only the
destination's whole fact; a scalar sibling and every other array field remain
independent, and a branch merge keeps that fact only when every arriving path
has it.

This is a copy context, not a general array value. A fixed-array field remains
refused as a module initializer source, argument, return, discard, operand, or
bare read, and as a literal, repetition, or other non-`zeroed`, non-copy
assignment destination. D51 later admits it as a local initializer source
without changing those positions, and D52/D53 later admit literal and
repetition destinations. Whole copies of the containing struct keep D46's
refusal in this slice;
D54 later gives the field-wise lowering path an explicit array branch.

Lowering emits one compact `Copy_Array` carrying both root storage identities
and both field identities, never target offsets, temporaries, or one operation
per element. The verifier first checks that each positive field exists in an
aggregate and has an array shape, then compares the two shapes; those explicit
checks precede every shaped accessor in assertion-free builds. `Fill_Array`
remains field-zero-only.

Each backend derives both field offsets, the source element width, and the byte
extent from its selected target. Linux x86-64 register-forms a module field on
either side when a D18-wide preceding field puts its offset outside a signed
displacement, uses L0504-bounded frame displacements for local fields, and emits
one forward `rep movsb`. Distinct fields and distinct storage do not overlap;
an exact self-copy names the same range, which the forward copy preserves. A
zero extent gives the operation a zero count.

**Why the contextual endpoints:** the compact D20 operation already expresses
the complete source read and destination write without enumerating D18's
extent. Typing the selections only in this syntax reuses that rule without
creating an array value that another expression, call, return, or initializer
would have to carry.

**The alternatives:** admit a fixed-array field as a general value, enable
field-wise copies of the containing struct, initialize storage from a selected
field in this assignment slice, emit one scalar copy per element, put a field
component into every
`Storage`, or introduce a second copy opcode. The first three broaden distinct
value and static-image rules, the fourth cannot represent every D18 extent, the
fifth widens unrelated fill endpoints, and the sixth duplicates D20 for two
identities. All were declined here; D51 later settles the local-initializer
rule independently.

**Pinned by** the checker, IR, verifier, lowering, and backend public-seam cases;
`positive/struct-array-field-copy`;
`negative/struct-array-field-copy-source-unassigned`;
`negative/struct-array-field-copy-not-on-every-path`;
`negative/struct-array-field-copy-shape-mismatch`;
`negative/immutable-struct-array-field-copy`;
`negative/struct-array-field-copy-keeps-fields-separate`; the recorded IR dump; and
`runtime/struct-array-field-copy-endpoints` on Linux x86-64.

### D51 — A fixed-array field initializes a local array

**The tour said** that a binding may carry a value [0040], an inferred binding
takes that value's type [0050], the value is read before the new name exists
[0110], and assigning an array copies its complete value [0520]. D21 admitted
both typed and inferred local initializers from a direct array storage name.
D50 made a directly selected fixed-array field a complete copy source, but kept
it outside initializer syntax.

**Chosen:** where `s` directly names D46 module state or a D47 local visible at
the binding and `f` is a fixed array of enabled scalars, a local array binding
may be initialized from `s.f` in either D21 form. In
`[mut] name: [N]T = s.f`, the written type must have the field's D17 identity;
a disagreement is D20's L0301 at the source, related to the binding. In
`[mut] name := s.f`, the destination takes that length and scalar element type
exactly. A declaration is not an assignment [0080], so either mutable or
immutable binding accepts the initializer and the source root need not be
mutable.

The source is read before the new name enters scope [0110] and as a whole. D10
makes a module field complete. A local field must be complete on every arriving
path: D49's clear or a D50 copy supplies its binding-and-field whole fact, while
D19/D48's sparse facts also suffice when they cover the declared length. An
internal zero-length field is vacuously complete. The fresh local is completely
initialized by the copy and, like every local declared with a value, needs no
later definite-assignment tracking. A refused contextual value owns its report;
[1940] does not add a static-module-value report after that node is ill typed.

This remains an initializer context rather than a general array value. D70
later admits the same selected field as a typed or inferred module initializer;
it remains refused as an argument, return, discard, operand or bare read. It is not a
literal or repetition destination at this boundary; D52 later admits the
literal destination alone. Whole copies of the containing struct keep D46's
refusal here and are admitted later by D54; fields of elements,
struct-of-struct fields and nested arrays remain outside the laid-out kernel.

Lowering emits D21's one compact `Copy_Array` from the containing root storage,
carrying the field's declaration-order identity as D50's source field, into the
fresh frame slot at field zero. It emits no target offset, temporary or
per-element operation. The verifier and backend therefore reuse D50's rules:
the verifier checks the source field before reading its shape, and x86-64
register-forms a D18-wide module offset while ordinary frame addresses remain
bounded by L0504. A zero extent gives the copy a zero byte count.

**Why:** D21's initializer already is D20's copy into fresh local storage, and
D50 already represents and checks a selected field as that copy's complete
source. Reusing both preserves D21's typed/inferred symmetry without adding a
general value position or a new IR operation.

**The alternatives:** admit only the explicitly typed form, admit a module
initializer from a field, make the field a general value, add a separate
initializer opcode, or emit one store per element. The first makes D21's two
spellings needlessly asymmetric; the second needed a static-image rule for
subobjects and was later chosen by D70; the third broadens unrelated expression
positions; the last two duplicate or cannot represent the compact D18
operation. The remaining alternatives were declined.

**Pinned by** the checker, lowering and backend public-seam cases;
`positive/local-array-initialized-from-field`;
`negative/struct-array-field-initializer-source-unassigned`;
`negative/struct-array-field-initializer-not-on-every-path`;
`negative/struct-array-field-initializer-shape-mismatch`;
`positive/module-array-from-struct-field`; the recorded IR
dump; and `runtime/local-array-initializers-from-fields` on Linux x86-64.

### D52 — An array literal may be assigned to a fixed-array field

**The tour said** that assignment reaches its destination before its value
[0410], that an array has its complete value [0520], that aggregate parts are
initialized in written order, that a struct has its declared fields [0670], and
that writability belongs to the root binding [1900]. D29 admitted a nonempty
literal only when the complete destination was a direct array storage name.
D48 made each element of a fixed-array field reachable without making the
field a general place.

**Chosen:** where `s` directly names D46 module state or a D47 local and `f` is
a fixed array of enabled scalars, D29's contextual assignment also admits
`s.f = [first, ..., last]`. Direct and aliased root, field and scalar element
types have the same meaning. The selected field's D17 length and element type
are the context: the nonempty literal must contain exactly that many elements,
and every expression must have the element type. A length or element mismatch
uses D29's L0301 and relates the source to its destination. The root must be
mutable under [1900]; L0303 owns an immutable root first and alone.

The destination is reached first. Each expression is then evaluated from left
to right and written immediately to its corresponding element before the next
expression begins, exactly as D29 specifies for direct storage. Thus a
later expression can observe an earlier write to the same field, and a runtime
failure can leave a completed prefix changed. Reads in every source expression
are nevertheless checked against the definite-assignment state arriving at the
statement; only normal completion records the binding-and-field whole fact.
That fact makes known and computed reads complete without affecting any scalar
sibling or other array field, and a merge retains it only on every arriving
path. Module state remains complete under D10.

Lowering evaluates each element, emits a constant `usize` index, and uses
D48's existing `Store_Element` operation with the root storage and the field's
declaration-order identity. It creates no hidden array temporary and carries no
target byte offset. D29's direct-array literal keeps its existing
`Store_Field` run byte-for-byte. A constant field index deliberately retains
the ordinary bounds check: introducing the two-level static-part encoding D48
declined is not part of this rule.

The verifier and backend reuse D48 without a new operation or invariant: the
verifier checks the positive field exists and has an array shape before reading
it, then checks the `usize` index and stored element type. Each backend derives
the field offset, length and element width from its target. Linux x86-64 forms
a D18-wide module field in registers and uses the L0504-bounded target
displacement for a local; every bounds trap precedes address arithmetic.

This is D29's literal context, not a general field value or place. Full and
mixed repetition are a separate decision admitted later by D53; `zeroed` other
than D49, copies other than D50, module
initializers, arguments, returns, discards, operands, bare reads, fields of
elements, struct-of-struct fields and nested arrays keep their existing
boundaries. Whole copies of the containing struct remain refused here and are
admitted later by D54. In particular, D52 itself does not widen `Fill_Array`.

**Why reuse element stores:** a literal already names one expression per
position, and D48 already represents the containing field plus an element
index. Reusing that operation preserves D29's observable order and avoids both
a hidden complete temporary and a second two-level part representation.

**The alternatives:** keep literals restricted to direct arrays, form a hidden
array value and copy it, extend `Store_Field` with a nested part, or admit full
and mixed repetition in the same slice. The first leaves otherwise usable
field storage needlessly asymmetric; the second changes D29's order and frame
cost; the third duplicates D48's identity; and the fourth requires a compact
field-qualified fill rule that a literal does not need. All were declined.

**Pinned by** the checker, lowering and backend public-seam cases;
`positive/struct-array-field-literal-assignment`;
`negative/struct-array-field-literal-length-mismatch`;
`negative/struct-array-field-literal-element-mismatch`;
`negative/immutable-struct-array-field-literal`;
`negative/struct-array-field-literal-reads-incoming-state`;
`negative/struct-array-field-literal-not-on-every-path`;
the recorded IR dump; and
`runtime/struct-array-field-literal-assignment-order` on Linux x86-64.

### D53 — Repetition may assign a fixed-array field compactly

**The tour said** that full repetition evaluates one scalar pattern [0560],
that mixed repetition evaluates and stores its prefix before evaluating the
repeated suffix, that assignment reaches its destination before its value
[0410], and that writability belongs to the root binding [1900]. D32 and D37
admitted those forms only for direct array storage. D48 made the elements of a
fixed-array field reachable, while D52 supplied the ordered prefix-store
representation a mixed field destination needs.

**Chosen:** where `s` directly names D46 module state or a D47 local and `f` is
a fixed array of enabled scalars, D32's full `[N of expression]` and
`[of expression]` assignment and D37's mixed
`[e1, ..., ek, of repeated]` assignment also admit `s.f` as their contextual
destination. Direct and aliased root, field and scalar element types have the
same meaning. The field supplies D17's length `N` and element type `T`: a
written full count must equal `N`, every expression must have type `T`, and a
mixed prefix must satisfy `1 <= k < N`. Consequently neither form admits an
internal zero-length field under D32/D37's construct-specific nonzero
contextual rules. The root must be mutable; L0303 owns an immutable root first
and alone.

The destination is reached first. A full repetition evaluates its scalar once
and fills the field. A mixed repetition evaluates and immediately stores each
prefix expression from left to right, then evaluates the repeated expression
once and fills positions `k + 1` through `N`. A later prefix or repeated
expression can therefore observe an earlier prefix write. Reads in all source
expressions are checked against the definite-assignment state arriving at the
statement; only normal completion records the binding-and-field whole fact.
That fact is independent of scalar siblings and other array fields and survives
a merge only when established on every arriving path. Module state remains
complete under D10.

Lowering represents a full field repetition with one `Fill_Array`, carrying
the root storage, the field's declaration-order identity and `First = 1`.
For a mixed field repetition it uses D52's constant-index `Store_Element`
sequence for the prefix and one field-qualified `Fill_Array` with
`First = k + 1` for the suffix. The repeated value is one ordinary scalar IR
operand; no hidden array temporary, target byte offset or operation per suffix
element is formed. D32 and D37's direct-array instruction sequences remain
unchanged with field identity zero.

The verifier first requires a positive field identity to name an array shape
inside the destination aggregate, then applies D32/D37's existing start and
element-type checks to that field's shape. These are explicit checks in
assertion-free builds. Each backend derives the containing field address,
suffix offset, count and element width from target facts. Linux x86-64
register-forms a D18-wide module field offset, composes the written prefix
offset with it, and uses an L0504-bounded field displacement for a local on
both 64- and 32-bit target descriptions.

This is one contextual assignment rule, not a general field value or place.
Repetition in local or module initializers from a field, arguments, returns,
discards, operands, bare reads, fields of elements, struct-of-struct fields and
nested arrays remains refused. A whole copy of the containing struct remains
refused in this slice and is admitted later by D54. D53 does not change module
static images or admit a field as an independently carried repetition value.

**Why reuse the compact fill:** D32/D37 already evaluate one repeated scalar
and keep IR size independent of the target-sized extent, while D48/D52 already
carry the containing field and ordered prefix writes. Combining those existing
identities preserves source order without inventing another array
representation.

**The alternatives:** keep repetition restricted to direct arrays, expand the
suffix into one element store per target position, form a hidden complete
array and copy it, or make the selected field a general array place. The first
leaves D32/D37 unnecessarily asymmetric with D52; the second makes compiler
work proportional to D18's extent; the third changes observable prefix-store
order and frame cost; and the fourth broadens unrelated value contexts. All
were declined.

**Pinned by** the checker, IR, verifier, lowering and backend public-seam cases;
`positive/struct-array-field-repetition-assignment`;
`negative/struct-array-field-repetition-count-mismatch`;
`negative/struct-array-field-mixed-prefix-too-long`;
`negative/struct-array-field-repetition-element-mismatch`;
`negative/immutable-struct-array-field-repetition`;
`negative/struct-array-field-repetition-reads-incoming-state`;
`negative/struct-array-field-repetition-not-on-every-path`; the recorded IR
dump; and `runtime/struct-array-field-repetition-assignment-order` on Linux
x86-64.

### D54 — An array-bearing struct is copied field by field

**The tour said** that assignment reaches its destination before its value
[0410], that assigning an array copies its complete value [0520], that a struct
has its declared fields [0670], that named structs have nominal identity
[0710], and that a declaration-only local must be assigned before it is read
[1910]. D16 made each scalar field of a struct local an independent assignment
fact. D46 and D47 admitted module and local storage with fixed-scalar-array
fields, while their whole-copy boundary remained refused.

**Chosen:** `destination = source` is admitted when both directly name D46
module state or D47 declaration-only local storage of the same nominal ordinary
struct, directly or through aliases, and every field is an enabled scalar or a
fixed array of enabled scalars. [0710] still refuses two distinct, same-shaped
struct declarations with L0301. The destination root must be mutable; L0303
owns an immutable destination first and alone. This is the existing contextual
struct assignment, not a general aggregate value.

A module source is complete under D10. Before a tracked local source is copied,
every scalar field must have D16's field fact and every fixed-array field must
be complete under D48--D53: either its D49/D50/D52/D53 binding-and-field whole
fact exists or its D48 sparse element facts cover the declared length. An
internal zero-length
field is vacuously complete. The first incomplete field owns D16's L0302 and is
named in the report. Self-copy follows the same read rule, so it cannot turn an
unassigned object into an assigned one. A merge retains only the contributing
facts present on every arriving path.

Normal completion assigns every destination field independently. A scalar
field receives its D16 bit; a fixed-array field receives its binding-and-field
whole fact, without assigning a scalar sibling or conflating two array fields.
Lowering visits fields in declaration order. A scalar field keeps the existing
`Load_Field` and `Store_Field` pair. A fixed-array field emits one D50
`Copy_Array` whose source and destination carry that field's declaration-order
identity. No target offset, hidden aggregate temporary, whole-aggregate opcode,
or operation per array element is introduced. Exact self-copy names identical
ranges and the existing forward byte copy preserves them.

The verifier and backends need no new boundary: D50 already checks both
positive field identities before reading their equal array shapes, and D53's
storage-address path derives datum and frame field addresses from target facts.
Linux x86-64 therefore register-forms a D18-wide module field and uses
L0504-bounded frame displacements on both 64- and 32-bit target descriptions.

Initializers, arguments, returns, discards, operands, bare whole reads and every
other general value of the struct remain refused in this slice, as do struct
fields of struct type, fields of elements and nested arrays. In particular, an
explicitly typed or inferred initializer from an array-bearing struct name
reports the existing L0304 once in this slice. D55/D56 later admit the typed
and inferred local direct-storage-name forms, and D60/D61 their module static
image counterparts. None admits the name of a struct type declaration as
storage.
Before D54, the inferred spelling could silently settle an aggregate binding
with no nominal body or value representation; D54 first routed it through the
ordinary whole-value refusal, and D56 later carries that missing identity at
the one admitted boundary without changing forward-name or cycle ownership.
Parameters and returns still need their own calling-convention decision.

**Why field-wise copy:** the enabled aggregate representation already names
each scalar or compact array field, and D16 plus D48--D53 already state exactly
what makes each one initialized. Reusing those identities keeps compiler work
and IR size independent of D18's array extent while preserving the nominal
struct rule and target-neutral layout.

**The alternatives:** keep whole copy scalar-only, flatten each array into a
scalar operation per element, add one opaque aggregate-copy instruction, or
make the struct a general value. The first leaves two equally laid-out storage
classes needlessly asymmetric; the second cannot represent every enabled
extent; the third hides the field-shaped verification and assignment facts;
and the fourth settles unrelated initializer, call and return rules. All were
declined.

**Pinned by** the checker, lowering and backend public-seam cases;
`positive/struct-array-field-whole-copy`;
`negative/struct-array-field-whole-copy-source-unassigned`;
`negative/struct-array-field-whole-copy-not-on-every-path`;
`negative/struct-array-field-whole-self-copy-unassigned`;
`negative/immutable-struct-array-field-whole-copy`;
`negative/struct-type-name-is-not-storage`;
`negative/struct-copy-across-types`; the recorded IR dump; and
`runtime/struct-array-field-whole-copy` on Linux x86-64.

### D55 — A typed local struct may snapshot directly named storage

**The tour said** that a local binding may carry an initializer [1810], that
assignment reaches its destination before its value [0410], that assigning an
array copies its complete value [0520], that named structs have nominal
identity [0710], and that fields keep declaration order [0750]. D54 admitted
the same field-wise copy only as an assignment between existing storage.

**Chosen:** an explicitly typed local binding, mutable or immutable, may be
initialized from a direct name of existing module or earlier local storage when
both have the same nominal ordinary struct type, directly or through aliases,
and that struct has an enabled D44/D45 layout. A struct refused at one of its
fields already owns that report, so this context does not ask for its missing
layout. The value is contextual: it is accepted only in this binding form and
does not make a struct name a general aggregate value. Per [0110], the new name
is not in scope in its own initializer, so a same-spelled source denotes an
outer binding.

A module source is complete under D10. A tracked local source must satisfy
D54's whole-read rule before the initializer executes: every scalar field has
its D16 fact and every fixed-array field has either its binding-and-field whole
fact or complete D48 sparse facts. An internal zero-length field is vacuously
complete. The first incomplete field reports D16's L0302. Two distinct,
same-shaped struct declarations remain nominally different and report L0301 at
the source, related to the binding. An unresolved source keeps resolution's
own report.

Lowering allocates the destination's complete aggregate frame slot, then
visits fields in declaration order. A scalar field uses D54's `Load_Field` or
`Load_Slot_Field` followed by `Store_Slot_Field`; a fixed-array field uses one
D50 `Copy_Array` from the source field into the same field of the fresh slot.
The initialized binding therefore owns storage independent of its source. No
aggregate value, hidden temporary, target offset, new IR operation, verifier
rule, or backend invariant is introduced. D50/D53 already verify the compact
field shapes and derive the module and frame addresses from target facts on
both 64- and 32-bit descriptions.

An inferred local binding remains refused in this slice and is admitted by
D56 only when its value is a direct struct storage name. A module initializer
remains refused in this slice; D60/D61 later admit its typed and inferred
direct-name forms. At D55, a non-name initializer, `zeroed`, a struct literal,
an argument, return, discard, operand or bare whole read remained refused;
D57 later admits typed local `zeroed` and D64/D65 the typed local labelled
literal. The checker reports the existing L0304 once for an
unsupported binding form; a binding it has already refused reads nothing for
definite assignment under D16. Parameters and returns still need their own
calling-convention decision, and struct-of-struct fields, fields of elements
and nested arrays keep their existing boundaries.

**Why the typed local form first:** its written type supplies the nominal
destination identity and its fresh slot reuses D54 without changing expression
typing or static images. It is the smallest executable initializer slice and
gives both scalar-only and array-bearing ordinary structs the same contextual
copy rule.

**The alternatives:** also infer the destination type from the source, admit a
module static image, admit aggregate `zeroed`, or make a struct name a general
value. Inference needs a separate rule for carrying nominal identity; a module
initializer needs a static struct-image chain; `zeroed` needs its own
per-field initialization rule; and a general value settles calls, returns and
temporary representation. All were declined here; D56 later supplies the
separate nominal-identity rule for local inference only, D57 later supplies
the typed local `zeroed` context, and D60/D61 later supply the typed and
inferred module static image chains.

**Pinned by** the checker, lowering and backend public-seam cases;
`positive/local-struct-initialized-from-name`;
`negative/local-struct-initializer-source-unassigned`;
`negative/local-struct-initializer-not-on-every-path`;
`negative/local-struct-initializer-nominal-mismatch`;
`negative/local-struct-initializer-non-name-not-enabled`;
`negative/local-struct-initializer-source-not-declared`;
`negative/local-struct-initializer-source-type-mismatch`;
`negative/struct-type-name-is-not-storage`; the recorded IR dump; and
`runtime/local-struct-initializer-copies-storage` on Linux x86-64.

### D56 — A local struct is inferred from directly named storage

**The tour said** that an inferred local binding takes its value's type [0050],
that the new name is not in scope in its own initializer [0110], that named
structs have nominal identity [0710], and that fields keep declaration order
[0750]. D55 admitted only the explicitly typed spelling because its written
type supplied the destination's nominal body.

**Chosen:** a mutable or immutable local binding whose type is omitted may be
initialized from a direct name of existing module or earlier local storage of
an enabled ordinary struct type. The destination is inferred to have exactly
the source's nominal body, including through a type alias. The source must
resolve to a module or local binding: a struct type declaration is a name but
is not storage and reports the existing L0304. Per [0110], a same-spelled
source denotes an outer binding rather than the declaration being introduced.

Inference carries the source body's declaration onto the new local before the
declaration settles as an aggregate. That identity is the one later field
selection, contextual whole copy and slot layout use; inference does not
construct a structural type or a bodyless aggregate value. A scalar-field and
a fixed-array-field struct follow the same rule. An unresolved source keeps
resolution's own report, and the existing underway guard preserves the single
report for a value worked out from itself [1940].

The source read is exactly D54/D55's whole read. Module storage is complete by
D10; a tracked local must have every scalar D16 fact and every fixed-array
field whole or complete sparse fact on every arriving path. An internal
zero-length field is vacuously complete. The initialized destination is a
fresh, untracked local whose later reads are complete.

Lowering needs no new path after inference: D55 allocates the aggregate frame
slot and visits the inferred body's fields in declaration order, using scalar
load/store pairs and one compact D50 `Copy_Array` for each fixed-array field.
D50/D53's verifier and target-derived address rules are unchanged. No general
aggregate value, hidden temporary, new IR operation, target offset or backend
invariant is introduced.

Module inference from a struct name in this slice, any non-name initializer,
aggregate `zeroed`, a struct literal, call result, selected field, argument,
return, discard, operand and bare whole read remain refused. Explicitly typed
local initialization remains D55, contextual whole assignment remains D54,
and typed and inferred module initialization remain refused in this slice
until D60/D61's static-image rules. Fields of struct type, fields of elements
and nested arrays keep their existing boundaries.

**Why:** the inferred form differs from D55 only in where its nominal identity
comes from. Copying the source's already resolved body declaration before
settling the local makes that identity explicit and lets every later stage
reuse D55 unchanged. Treating every name whose type is aggregate as a source
would instead confuse type declarations with storage and recreate the bodyless
aggregate defect D54 exposed.

**The alternatives:** infer structurally from the field shapes, admit any
aggregate-typed expression, infer module initial images, or defer all inference
until general aggregate values exist. Structural inference violates [0710];
general expressions need a temporary representation; module inference needs a
static image; and deferral leaves the direct-storage case artificially
asymmetric with D21. All were declined here; D61 later reuses D60's image chain
at the direct-storage boundary.

**Pinned by** the checker, lowering and backend public-seam cases;
`positive/local-struct-inferred-from-name`;
`negative/local-struct-inferred-source-unassigned`;
`negative/local-struct-inferred-not-on-every-path`;
`negative/struct-type-name-is-not-storage`;
the recorded IR dump; and `runtime/local-struct-inference-copies-storage` on
Linux x86-64.

### D57 — A typed local struct is initialized to its zero image

**The tour said** that `zeroed` is the all-bits-zero image of its contextual
type and writes that complete image as one value [0540], that a local binding
may carry an initializer [1810], and that struct fields retain declaration
order and target padding [0750]. D55 supplied only a directly named storage
source for an explicitly typed local struct.

**Chosen:** `[mut] name: T = zeroed` is admitted inside a body when `T`
resolves through aliases to a named ordinary struct with an enabled D44/D45
layout. Every enabled scalar and fixed-scalar-array field has a zero image, so
the complete padded object extent has one. The written type supplies the
literal's aggregate kind and nominal [0710] body. Both mutable and immutable
bindings accept it, and the initialized local is untracked by D16.

Lowering allocates the fresh aggregate slot and emits one operand-free
`Clear_Array` naming field zero. At that identity the operation clears either
whole fixed-array storage, as before, or D57's whole aggregate storage; a
positive field remains an array field. The verifier explicitly admits only an
array or aggregate at field zero before any shaped accessor. Each backend
derives an aggregate's complete padded extent from target facts and clears
every byte, including padding, in one forward operation. No field enumeration,
hidden zero object, target offset or new opcode is introduced.

An invalid struct body already owns its field/layout report and never reaches
lowering. An explicit module struct zero image in this slice, inferred `name := zeroed`,
whole assignment `name = zeroed` in this slice, arguments, returns, discards,
operands, nested expressions and general aggregate values remain refused.
D58 later supplies the whole-assignment context and D59 the explicit module
zero image. Struct fields of struct type, fields of elements and nested arrays
keep their boundaries.

**Why the padded whole:** field-wise scalar stores and array clears would leave
padding unspecified, contradicting [0540]'s all-bits-zero image. Reusing the
destination-only clear keeps compiler work independent of D18-sized fields and
keeps target layout in the backend.

**The alternatives:** clear fields separately, add a second aggregate-clear
opcode, synthesize a zero object, or admit module, inferred and assignment
contexts together. The first misses padding; the next two duplicate an
existing storage operation or invent storage; the last settles distinct static
image and place rules. All were declined.

**Pinned by** the checker, lowering, verifier and backend public-seam cases;
`positive/local-struct-zeroed-initializer`;
`negative/inferred-zeroed-not-enabled`;
`negative/local-struct-initializer-non-name-not-enabled`; the recorded IR dump;
and `runtime/local-struct-zeroed-reads-zero` on Linux x86-64.

### D58 — A struct place is assigned its zero image

**The tour said** that assignment reaches its destination before evaluating
its value [0410], that `zeroed` is the complete all-bits-zero image of its
contextual type [0540], and that assignment requires a mutable place [1900].
D30 supplied this context for whole arrays, D49 for an array field, and D57
gave field zero of the compact clear operation a padded aggregate extent.

**Chosen:** `place = zeroed` is admitted when `place` directly names mutable
D46 module state or a mutable D47 local of a named ordinary struct with an
enabled D44/D45 layout. The destination supplies the literal's aggregate kind
and nominal [0710] body. Root mutability is checked first; an immutable root
reports the existing L0303 alone. Type aliases preserve the same body.

The destination is reached first and the literal evaluates nothing. On normal
completion every scalar field, every fixed-array field and every padding byte
in the complete target object extent is all bits zero. For a tracked local,
D16 marks each scalar field assigned and D48--D54 mark each array field wholly
assigned; branch merges intersect those facts as before. Module state remains
untracked and complete under D10.

Lowering emits D57's one operand-free field-zero `Clear_Array` naming the
module datum or frame slot. The verifier admits the whole aggregate storage
explicitly, while `Copy_Array` and `Fill_Array` remain array-only. Each backend
derives the padded extent and base address from target facts; no source
storage, field enumeration, aggregate temporary, target offset or new opcode
is introduced.

An inferred initializer `name := zeroed`, an explicit module initializer in
this slice, arguments, returns, discards, operands, nested expressions and
general aggregate values remain refused. D59 later admits the explicitly typed
module zero image. A struct selection cannot currently name a struct-typed
field, and fields of struct type, fields of elements and nested arrays keep
their boundaries.

**Why both storage classes:** D30 and D49 already clear module and local
storage with identical runtime semantics, D54 copies whole structs into both,
and D10 makes module definite assignment simpler rather than different.
Restricting this rule to locals would create a new storage-class asymmetry with
no representation or semantic cause.

**The alternatives:** admit only locals, clear fields separately, add a new
aggregate-clear opcode, or admit every aggregate-valued `zeroed` context at
once. The first is asymmetric; the second misses padding; the third duplicates
D57's operation; and the last settles static images and general aggregate
values this place rule does not need. All were declined.

**Pinned by** the checker, lowering, verifier and backend public-seam cases;
`positive/struct-zeroed-assignment`;
`negative/immutable-struct-zeroed-assignment`;
`negative/struct-zeroed-assignment-not-on-every-path`;
`negative/struct-zeroed-assignment-nested-not-enabled`;
`negative/inferred-zeroed-not-enabled`; the recorded IR dump;
and `runtime/struct-zeroed-assignment-clears-storage` on Linux x86-64.

### D59 — A typed module struct has an explicit static zero image

**The tour said** that `zeroed` is the complete all-bits-zero image of its
contextual type [0540], that module declarations may carry values [1740], and
that nothing runs before the entry point [1460]. D10 already gives a
declaration-only module struct that same zero image, while D57 admitted the
explicit spelling only for a local binding.

**Chosen:** `[mut] name: T = zeroed` is admitted at module scope when `T`
resolves through aliases to a named ordinary struct with an enabled D44/D45
layout. The written type supplies the literal's aggregate kind and nominal
[0710] body. Mutability does not affect initialization, so mutable and
immutable declarations both accept it. Each declaration still owns distinct
module storage.

This is a static image, not executable initialization. Lowering records the
same aggregate datum, field-shape run and operandless `Leave` as D10's omitted
initializer. It records no finite per-byte or per-field image and emits no
`Clear_Array`: such an instruction inside a datum would wrongly imply runtime
execution and remains verifier-refused. The backend therefore reserves the
datum's complete target-derived padded extent in zero-initialized storage,
including every field and padding byte.

Module state is complete under D10, so D16 gains no fact or flow rule. An
inferred module `name := zeroed`, initialization from another struct name in
this slice, a struct literal, call, argument, return, discard, operand, nested
expression and general aggregate value remain refused. D60 later admits the
typed direct-name static image chain and D66--D71 the typed module labelled
literal. Fields of struct type, fields of elements and nested arrays keep their
boundaries.

**Why no new image:** the explicit spelling denotes exactly the image D10
already requires. A runtime clear cannot run before [1460]; a finite byte image
would make compiler work proportional to a D18-sized field; and field-wise
images would either omit padding or duplicate target layout outside the
backend. Leaving the image absent preserves the established `.bss` contract.

**The alternatives:** emit a clear in the datum, record every zero byte, record
one zero per field, or admit direct-name and inferred module struct images at
the same time. The first is not static, the next two duplicate or misplace
layout, and the last needs a separate static struct-image chain. All were
declined.

**Pinned by** the checker, lowering and backend public-seam cases;
`positive/module-struct-zeroed-initializer`;
`negative/module-struct-zeroed-initializer-nested-not-enabled`;
`negative/inferred-zeroed-not-enabled`;
the recorded IR dump; and `runtime/module-struct-zeroed-image-is-static` on
Linux x86-64.

### D60 — A typed module struct copies a static image from a storage name

**The tour said** that a binding may write its type and initializer together
[0040], that module declarations form one order-independent scope [1740], that
ordinary structs have nominal identity [0710], and that nothing runs before
the entry point [1460]. D21 gave a direct-name module array initializer a
static image chain, while D55 supplied the corresponding runtime copy only for
a local ordinary struct.

**Chosen:** `[mut] name: T = source` is admitted at module scope when `T`
resolves through aliases to a named ordinary struct with an enabled D44/D45
layout and `source` directly names module storage of that same nominal type.
The source must be a storage binding rather than a type declaration. An
unresolved name keeps resolution's report, a type declaration keeps the
existing L0304, and a different nominal body reports L0301 at the source,
related to the binding. Mutability affects later writes rather than
initialization [0080].

The initializer is D21's declaration-identity static image chain applied to
ordinary structs. It follows forward references and type aliases and must
terminate at a module struct whose initializer is omitted under D10, is D59's
explicit `zeroed`, or later carries D66's written labelled image. A chain that
returns to a declaration is [1940]'s value worked out from itself and reports
L0305 once. Every declaration in a valid chain owns distinct storage
initialized with the terminal image rather than aliasing its source.

At this decision every constructible terminal image was all bits zero, so the
first implementation recorded no finite aggregate image and reserved each
target-derived padded extent separately in zero-initialized storage. D66 later
adds the target-neutral declaration-order field run this rule required for a
nonzero terminal and copies it along the same chain. Omitted and whole
`zeroed` terminals retain the absent-image representation.

Module state remains complete under D10, so definite assignment gains no fact.
An initializer boundary that has already refused the written type or value is
not read again for [1940], preserving its owning report without a cascade. An
inferred module binding in this slice, a non-name initializer, struct literal,
call, field selection, argument, return, discard, operand, nested expression
and general aggregate value remain refused. D61 later admits the inferred
direct-name form and D66--D71 the typed module labelled literal. D55/D56's
local initializers and D57--D59's zero-image contexts are unchanged. Struct
fields of struct type, fields of elements and nested arrays keep their
boundaries.

**Why a static copy:** aliasing would make a later write through one declaration
change the other, contrary to D21 and D54's value semantics. A startup copy
cannot run before [1460]. Following identities keeps each symbol and target
layout distinct; D66 later supplies the first nonzero producer and carrier.

**The alternatives:** alias the source, emit runtime initialization, add a
field or byte image now, admit inferred module initialization at the same time,
or defer the direct-name form until struct literals. The first two contradict
value and startup semantics; the third would have invented unused
representation at this slice; the
fourth needs its own nominal inference rule; and the last leaves arrays and
structs asymmetric without implementation evidence. All were declined here;
D61 later supplies that inference rule without widening the other forms.

**Pinned by** the checker, lowering and backend public-seam cases;
`positive/module-struct-initialized-from-name`;
`negative/module-struct-initial-image-cycle`;
`negative/module-struct-initializer-nominal-mismatch`;
`negative/struct-type-name-is-not-storage`;
the recorded IR dump; and
`runtime/module-struct-initializers-copy-images` on Linux x86-64.

### D61 — A module struct is inferred from directly named storage

**The tour said** that an inferred binding takes the type of its value [0050],
that module declarations form one order-independent scope [1740], and that
ordinary structs have nominal identity [0710]. D21 already inferred module
array storage from a direct name, D56 carried a struct's nominal body into an
inferred local, and D60 supplied the typed module static image chain.

**Chosen:** `[mut] name := source` is admitted at module scope when `source`
directly names module storage whose settled type is a named ordinary struct
with an enabled D44/D45 layout. The destination takes exactly the source's
nominal body through any type alias. The source must resolve to a storage
binding rather than a type declaration; an unresolved name keeps resolution's
report and a type name keeps the existing L0304. Mutability does not affect
initialization [0080]. Scalar and fixed-array sources retain their existing
inference rules.

Inference settles an untouched forward source on demand, then records its body
on the destination before settling that destination as an aggregate. The
inferred binding therefore has the identity later layout, selection and
lowering require; it is not D54's old bodyless aggregate. It joins D60's static
image chain, which follows forward references and aliases to D10's omitted or
D59's explicit zero terminal and gives every declaration distinct storage.

A chain made entirely of inferred bindings that returns to itself is detected
while its type is being settled and reports [1940]'s L0305 once. A mixed typed
and inferred chain settles each member's nominal body, then D60's image
validator reports that same cycle once. The mechanisms are disjoint: a failed
inference is `Ill_Typed` and is not visited as an image, while the validator
only visits successfully settled arrays and aggregates.

At this decision every constructible terminal image was zero. Lowering reused
the inferred body to record one ordinary aggregate datum, compact field shapes
and an operandless `Leave`; no finite image, runtime copy, clear, new
instruction or target offset was introduced. D66--D71 later added
target-neutral labelled scalar, finite, repeated and hybrid field images and
copy those terminal images through the same D60/D61 declaration chain into
distinct padded objects on 64- and 32-bit descriptions.

A non-name initializer or `zeroed` without a written type, call,
field selection, argument, return, discard, operand, nested expression and
general aggregate value remain refused. D64--D71 admit a struct literal only
in their explicitly typed contextual local, assignment and module-image forms;
inferred literals and call-shaped construction remain refused in this decision;
D72 later supplies nominal construction. D55/D56's local
forms and D57--D60's contextual zero and typed module forms are unchanged.
Struct fields of struct type, fields of elements and nested arrays keep their
boundaries.

**Why now:** D56 already provides the only missing nominal-identity step and
D60 already proves and represents the module image. Reusing both closes the
last typed/inferred and local/module asymmetry without making a struct name a
general value or inventing startup execution.

**The alternatives:** infer structurally, alias the source, emit a startup
copy, admit non-name expressions too, or keep module inference refused.
Structural inference violates [0710]; aliasing is observable through writes;
startup execution contradicts [1460]; general expressions need aggregate
temporaries; and continued refusal has no remaining semantic or representation
cause. All were declined.

**Pinned by** the checker, lowering and backend public-seam cases;
`positive/module-struct-inferred-from-name`;
`negative/module-struct-mixed-image-cycle`;
`negative/module-value-from-itself`;
`negative/module-struct-inferred-non-name-not-enabled`;
`negative/struct-type-name-is-not-storage`; the recorded IR dump; and
`runtime/module-struct-initializers-copy-images` on Linux x86-64.

### D62 — `zeroed` reaches a fixed-array field element

**The tour said** that assignment reaches its destination before its value
[0410], that selection and indexing reach a scalar subobject [0520], that only
writable places may be assigned [1900], and that `zeroed` takes the all-bits-zero
image of its context [0540]. D42 applied that context to an immediate scalar
field or fixed-array element, while D48 later made `s.f[i]` an ordinary scalar
place without revisiting D42's structural destination list.

**Chosen:** `zeroed` may be the complete right-hand side of assignment to an
`Element_Index` whose target is a fixed-array `Member_Selection` from a directly
named mutable local or module binding. The element type must resolve to an
enabled scalar and supplies `false` for `bool` or typed integer zero. This is
D42's scalar image at D48's place: it does not make the selected array field a
whole value or make `zeroed` a general expression.

The ordinary place check remains first. It resolves the containing struct and
field, checks the index type and compiler-known bound, and retains root
mutability and every invalid-place refusal before the value is considered. A
computed index is evaluated exactly once and keeps D48's runtime bounds trap.
A nested occurrence such as `s.f[i] = zeroed + 1` remains refused with the
existing L0304, and a refused destination produces no additional flow report.

Successful completion has D48's ordinary definite-assignment effect: a
compiler-known index records only `(binding, field, position)`, a computed index
records no sparse fact, and neither assigns a sibling position or the array
field as a whole. Lowering reuses D42's typed `Truth` or `Number` and D48's
field-qualified `Store_Element`; the verifier and backend therefore gain no new
operation, shape, ordering rule, address calculation or target invariant. A
module root is runtime storage reached from a function body, not a module
initial image, so D60's static-image boundary is unchanged; D66 later adding a
written image does not turn this runtime store into initialization.

**Why this place:** D48 already types and represents its element as an ordinary
scalar place. Keeping `zeroed` refused there would make the literal depend on
the number of selectors rather than on the destination semantics it uses.

**The alternatives:** admit every scalar place accepted by `Check_Place`, or
wait for general aggregate values. The first would silently choose the rule for
future struct-of-struct and element-field chains whose representation is not
settled; the second leaves a currently representable scalar place asymmetric
for no semantic reason. Both were declined. The structural destination list is
extended by exactly this D48 shape and may become a type-based test when deeper
places are designed.

**Pinned by** the checker and lowering public-seam cases;
`positive/struct-array-field-element-zeroed`;
`negative/struct-array-field-element-zeroed-immutable`;
`negative/struct-array-field-element-zeroed-nested`;
`negative/struct-array-field-element-zeroed-keeps-facts-separate`; the recorded
IR dump; and
`runtime/struct-array-field-element-zeroed-computed-index-traps` on Linux
x86-64.

### D63 — Ordinary-struct literal spellings are refused by name

**The tour said** that an ordinary struct may be written as a parenthesized
field image [0710] and showed call-shaped construction with named fields
[0700]. The enabled expression grammar [1810] has neither form. Before this
decision, `(x: 1, y: 2)` entered the parenthesized-expression parser and the
first `:` produced an unnamed syntax cascade, while `point(x: 1, y: 2)` entered
the ordinary-call parser and failed for the same reason.

**Chosen:** while ordinary-struct literals remain outside [1810], the parser
recognizes their unambiguous opening shapes and refuses each complete or
truncated construct once with L0010. A value-position `(` followed by
`identifier :` names [0710]'s struct literal. The contextual all-field form
`(of expression)` names the same construct when `of` is followed by an
unambiguous expression start: one that is not also a binary operator. Thus
`(of)`, `(of + 1)`, `(of - 1)` and other ordinary uses of a binding named `of`
remain parenthesized expressions, while `(of zeroed)`, `(of not ready)` and
`(of ~mask)` name [0720]'s contextual fill. An identifier call whose
opening parenthesis is followed by `identifier :` names [0700]'s call-shaped
construction. Ordinary `(expression)` and positional `callee(arguments)` keep
their existing grammar and parse.

The refusal consumes balanced parentheses, including nested parentheses, or
stops at end of input. It returns one error expression and does not create a
dormant struct-literal node, field-name references or aggregate value. Any
immediately following bracketed index is skipped as recovery rather than
reported as a second refused construct. The automatic truncation suite holds
every prefix to producing a finite, well-formed tree.

At D63 the normative grammar was deliberately unchanged. A negative fixture whose
first report is the frontend's L0010 must remain underivable; adding a
`struct_literal` production would claim the source is enabled while the parser
still refuses it. The later literal slice must replace this lookahead with a
real syntax node and grammar production, teach resolution that field labels are
not ordinary name references, and migrate these fixtures to positive or
later-stage evidence. D64 performs that migration and lowers local and
assignment contexts field by field; D66--D71 add the target-neutral module
static-image representation D60 deferred.

**Why pin the refusal first:** the named before-state separates migration from
recovery. It lets the enabling slice prove exactly which L0010 refusals it
removes without inheriting an accidental cascade as specification.

**The alternatives:** add the grammar and a dormant node now, let the checker
refuse every use of that node, or leave the accidental syntax reports in
place. The first two perform half of the enabling slice and require name
resolution and whole-value policy before any value is admitted; the last has
no stable construct owner or migration evidence. All were declined.

**Pinned by** the parser public-seam case;
`negative/struct-literal-not-enabled`; the generated construct matrix and
token dump; and the automatic parser truncation suite. D72 later migrates the
construction fixture to the checker-owned contextual boundary.

D64 later supersedes this refusal for the nonempty labelled form by adding its
grammar and contextual syntax node. D72 later supersedes the call-shaped
construction refusal by attaching a nominal type to that same node. The
all-`of` form alone retains D63's parser-owned refusal and recovery rule and is
cited to [0720], its surviving construct, rather than [0710]'s enabled labelled
form.

### D64 — A labelled struct literal writes contextual local storage

**The tour said** that an ordinary struct image names fields in parentheses
[0710], that their written order determines evaluation [0410], and that a
trailing `of` supplies fields not written individually [0720]. D63 first gave
the unambiguous spelling one parser-owned refusal. D23 and D29 separately
settled the initializer and immediate-write assignment contexts for arrays,
while D57/D58 supplied the corresponding whole-struct storage contexts.

**Chosen:** `struct_literal` and `field_value` are enabled by [1810]'s grammar.
A labelled literal is admitted only as (a) the initializer of an explicitly
typed local binding whose written type resolves to an enabled named ordinary
struct, or (b) the complete right-hand side of assignment to a directly named
mutable module or local binding of such a type. The context supplies [0710]'s
nominal body. Inferred bindings, discards, operands, arguments, returns and
every general aggregate-value position remain L0304. Module initializers remain
L0304 in this slice; D66 later admits their scalar-labelled static-image subset.
The call-shaped construction `T(field: value)` remains a parser-owned L0010
refusal until D72 supplies its nominal type. The all-fill spelling
`(of zeroed)` remains refused by name.

Labels may appear in any order. Each must name a field of the contextual body;
an unknown label keeps L0308. A field may be named at most once: the second
label reports L0309, related to the first. Without a trailing fill every field
must be named; one L0310 at the literal lists the missing fields in declaration
order. Named fields in this slice must be scalar, and each value is checked in
that field's resolved scalar context. D65 later supplies the same contextual
destination to scalar `zeroed` and to D49--D53's fixed-array field forms.

The only trailing fill admitted is `of zeroed`. It writes every unnamed scalar
field as typed integer zero or `false` and clears every unnamed fixed-array
field with D49's compact whole-field operation. General `of expression` is
L0304: one expression node cannot simultaneously commit to heterogeneous field
types, and choosing an implicit conversion or duplication rule is deferred.
The all-fill form remains refused because D57/D58 already spell the complete
zero image directly as `zeroed`.

Named expressions are evaluated and committed immediately in source order,
regardless of declaration or layout order. The fill follows them and visits
unnamed fields in declaration order. Thus a later field expression observes an
earlier field write to the same destination, exactly as D29 exposes array
literal writes; no hidden aggregate temporary or atomic commit exists. Reads
inside all named expressions are checked against the definite-assignment state
arriving at the statement. On successful completion the destination receives
D54/D58's whole-aggregate assignment facts: every scalar field and every
fixed-array field is complete. A typed local initialized by the literal has a
value and is consequently untracked, as other initialized locals are.

The tree carries one `Struct_Literal` with an optional fill slot and a written
run of `Field_Value` nodes. A field label belongs to its `Field_Value`; it is not
a `Name_Reference` and resolution never binds it. The checker records the
nominal body on the literal and the declaration-order field identity on every
valid label. Lowering emits an ordinary scalar field store immediately after
each named expression, then typed scalar-zero stores and field-qualified array
clears for the fill. It introduces no aggregate value, new IR operation,
verifier rule, backend address form, target layout or static image. A module
initializer remains refused in this slice; D66 later supplies the
target-neutral nonzero terminal image for the scalar-labelled subset.
A body whose earlier field or extent refusal prevented layout silently refuses
the contextual literal as well: the owning field or L0300 report is not
followed by a layout query or a second diagnostic.

**Why this boundary:** the two contexts already own aggregate storage, nominal
identity, definite assignment and field-shaped lowering. Enabling them proves
the literal's evaluation rule without opening aggregate temporaries or a
nonzero module image. Including `of zeroed` also reaches array-bearing structs
without making a nested array literal a field value.

**The alternatives:** admit only the local initializer, admit arbitrary named
array fields, admit a general heterogeneous `of` expression, make the literal
a general aggregate value, or add a nonzero module image at the same time. The
first leaves D29's exposed-write question open; the next two need nested-array
and per-field commitment rules; the fourth needs aggregate temporaries; and the
last needs the representation D60 explicitly deferred. All were declined.

**Pinned by** the parser, checker and lowering public-seam cases;
`positive/struct-literal-contexts`;
`negative/struct-literal-field-named-twice`;
`negative/struct-literal-field-not-given`;
`negative/struct-literal-unknown-field`;
`negative/struct-literal-of-expression-not-enabled`;
`negative/struct-literal-field-type-mismatch`;
`negative/struct-literal-reads-incoming-state`;
`negative/struct-literal-without-layout`;
`negative/immutable-struct-literal-assignment`;
`negative/module-struct-literal-inferred-not-enabled`;
`negative/struct-array-field-layout-overflow`;
`negative/struct-literal-not-enabled`; the generated catalogue, construct,
token and IR records; and `runtime/struct-literal-order-and-fill` on Linux
x86-64.

### D65 — A label is its field's contextual destination

**The tour said** that a struct literal takes its type from context [0710],
that each written label supplies one field value and a trailing `of` supplies
the rest [0720], and that evaluation follows written order [0410]. D64 admitted
the literal but limited written values to ordinary scalar expressions. D42 and
D49--D53 had already settled the corresponding contextual scalar-zero and
fixed-array-field assignment forms.

**Chosen:** in D64's explicitly typed local initializer and whole-assignment
contexts, each label is the same contextual destination as selecting that
field for assignment. A labelled scalar field additionally accepts `zeroed`,
which takes D42's resolved scalar type and all-bits-zero image. A labelled
fixed-array field accepts exactly D49--D53's complete contextual forms: an
array literal, full or mixed-prefix repetition, `zeroed`, a direct array
storage name, or a selected fixed-array field of the same D17 shape. The array
value node records the labelled field's element type and length; the label
continues to record the declaration-order field identity.

Labels are still evaluated and committed in source order. An array literal
writes its elements immediately in their own source order; a repetition writes
its prefix then evaluates its repeated expression once and performs one compact
fill; a copy is one compact field-qualified copy; and `zeroed` is one compact
field-qualified clear. A later label therefore observes every earlier labelled
write. D64's trailing `of zeroed` runs only after all of them and retains its
declaration-order fill. Reads in every field expression are checked against the
state arriving at the statement, while successful completion retains D64's
whole-aggregate definite-assignment facts.

The checker delegates each array form to its existing contextual shape, count,
element and source-read rule with `Static_Image => False`. Lowering uses one
field-qualified writer over the existing `Store_Element`, `Fill_Array`,
`Copy_Array` and `Clear_Array` operations; scalar `zeroed` uses the existing
typed `Truth` or `Number` followed by a scalar field store. No grammar, syntax
node, IR operation, verifier rule, backend address form, target fact, layout or
static image changes.

A nested array literal remains refused as a scalar element, and no other
general array value is introduced. A general trailing `of expression` remains
refused: the one expression node has one committed type, while omitted fields
may be heterogeneous; converting it per field is not enabled, and evaluating
it again per field would violate the once-only rule. Inferred literals still
have no nominal body and wait for [0700]'s construction decision, which D72
later supplies. Module
literals remain outside this slice; D66 later supplies D60's nonzero aggregate
image carrier for scalar labels, D67 adds its finite-or-zero array-field form,
D68 its repeated and hybrid forms, D69 a direct module-array image source, and
D71 a selected module-array-field source.
The all-`of`
spelling remains D63's redundant parser refusal, and general aggregate values
remain outside this slice.

**Why the field destination:** the selected field already owns exactly the
shape, storage, diagnostics, ordering and target-derived operation the written
value needs. Reusing those decisions closes D64's artificial label boundary
without opening a second array representation or aggregate temporary.

**The alternatives:** admit scalar `zeroed` alone, restrict a general `of`
expression to accidentally homogeneous fields, convert or re-evaluate that
expression per field, infer a nominal body from labels, add nonzero module
images, or admit the all-`of` synonym. The first is too small to justify a
separate semantic principle; the next three contradict single-node typing,
once-only evaluation or nominal identity; the fifth needs D60's deferred
representation; and the last duplicates whole `zeroed`. All were declined.

**Pinned by** the checker and lowering public-seam cases;
`positive/struct-literal-array-field-forms`;
`negative/struct-literal-array-field-shape-mismatch`;
`negative/struct-literal-array-field-element-mismatch`;
`negative/struct-literal-array-field-repetition-mismatch`;
`negative/struct-literal-array-field-source-unassigned`;
`negative/struct-literal-nested-array-value-not-enabled`;
`negative/immutable-struct-literal-assignment`;
`negative/struct-literal-of-expression-not-enabled`; the generated token and
IR records; and `runtime/struct-literal-array-field-order` on Linux x86-64.

### D66 — A typed module struct literal is a static field image

**The tour said** that a module binding may carry a value [0040], that an
ordinary struct image names its fields [0710], that the remaining fields may be
supplied by `of` [0720], and that nothing runs before the entry point [1460].
D24 established target-neutral folded static images for arrays, D60/D61
established declaration-identity module struct image chains, and D64/D65
established the contextual labelled literal and its field rules at runtime.

**Chosen:** `[mut] name: T = (field: value, ..., of zeroed)` is admitted at
module scope when `T` resolves to an enabled named ordinary struct with a
layout. The written type supplies the literal's nominal body. D64's freely
ordered, unique labels, L0308 unknown-field owner, L0309 duplicate owner and
L0310 missing-field owner apply unchanged. Each explicitly named field in this
first static carrier must be scalar. D67 later supersedes that boundary for a
finite or `zeroed` fixed-array label, and D68 adds full and mixed repetition.
A trailing `of zeroed` supplies zero or
`false` to every unnamed scalar field and the absent zero image to every
unnamed fixed-array field. A fixed-array field named explicitly is L0304 in
this slice; D67 later admits its finite literal and `zeroed` forms through a
compact per-field image, D68 admits repetition, and image copy remains a later
decision until D69 admits the direct module-array-name form. Selected-field
image copy remains outside that rule.

Each scalar field expression must be known without execution under [1940]: a
literal, contextual scalar `zeroed`, an enabled operator over known operands,
or a module scalar name whose value is known. A call reports L0305. A selected
field, index or nested array image reports its existing L0304 static-image
refusal, including beneath an otherwise foldable operator. Integer folding
keeps D24's overflow owners: a fold beyond the compiler's widest magnitude or
beyond the field's selected-target type reports L0300. An inferred module
binding still has no nominal body and keeps L0304; a general `of expression`,
the all-`of` spelling, call-shaped construction and general aggregate value
remain refused in this decision; D72 later supplies contextual nominal
construction.

The target-neutral aggregate image is one `Folded` entry per field in [0750]'s
declaration order. A scalar entry is its folded value. An unnamed scalar entry
is zero, and a fixed-array entry is the zero placeholder for its absent image.
The representation contains no target byte, offset or padding. The verifier
requires the image length to equal the field count, requires an array-field
placeholder to be zero, and checks each scalar fold against the selected
target before any backend accessor can consume it, including in builds without
contract checks.

The backend lays out the field-shape run with the same target placement used by
D45. It writes scalar entries with that target's width, emits zero for every
array field, gap and tail-padding byte, and gives the complete padded object a
`.data` image. A labelled literal whose folds are all zero remains a written
image, as D24 decided for arrays; only an omitted initializer or whole
`zeroed` retains D10/D59's absent image and `.bss` storage. Nothing is copied or
cleared at startup. D60/D61 chains that terminate at the literal copy its
field-image run into each declaration's distinct datum, preserving forward
references, aliases and cycle ownership. The literal is a terminal image, so a
cycle can arise only in the declaration-name chain that precedes a terminal;
D60/D61's single L0305 owner remains unchanged.

Module state remains complete under D10 and no definite-assignment fact is
added. The literal has no runtime evaluation order because its expressions are
folded rather than executed. D64/D65's local initializer and whole-assignment
rules remain immediate runtime writes and do not acquire this static-image
semantics.

**Why fields rather than bytes:** folds preserve the same source image across
32- and 64-bit targets while target placement remains the only authority on
widths, offsets and padding. A target-byte blob would make the neutral IR
target-specific, and a startup routine would contradict [1460]. Restricting
the first carrier to scalar labels proves the representation without expanding
D24/D34/D38's finite, repeated and hybrid array forms inside every aggregate
field.

**The alternatives:** emit a target-byte blob, synthesize a startup clear or
copy, store fields at runtime, keep module literals refused, or admit every
D65 array-field form at once. The first three violate target neutrality or
static initialization; the fourth leaves D60's deliberate carrier seam unused;
and the last needs a compact nested image representation before its verifier
and backend invariants can be stated. All were declined here.

**Pinned by** the IR, verifier, checker, lowering and backend public-seam cases;
`positive/module-struct-literal-initializer`;
`negative/module-struct-literal-inferred-not-enabled`;
`negative/module-struct-literal-selection-not-enabled`;
`negative/module-struct-literal-value-not-known`;
`negative/module-struct-literal-field-out-of-range`;
`negative/module-struct-literal-field-fold-overflow`; the generated token and
IR records; and `runtime/module-struct-literal-image-is-loaded` on Linux x86-64.

### D67 — A labelled fixed-array module field has a finite or zero image

**The tour said** that an ordinary struct image names its fields [0710], that
an array literal names its elements [0410], and that nothing runs before the
entry point [1460]. D24 established finite target-neutral module array images,
D60/D61 established declaration-identity struct image chains, and D66 left one
zero placeholder for every fixed-array field until a compact field image could
own its elements.

**Chosen:** a fixed-array label in D66's explicitly typed module struct literal
accepts a nonempty array literal of exactly the field's D17 length and element
type, or contextual `zeroed`. Each literal element must be known without
execution under [1940] and follows D24's static exclusions and folding owners:
a call reports L0305, a selected field, index or nested image reports L0304,
and a fold beyond the compiler's widest magnitude or the selected target type
reports L0300. A length or element disagreement keeps the existing L0301
owner. `zeroed` denotes the absent all-zero field image, including for D17's
internal zero-length shape; a written finite literal remains nonempty, so it
cannot initialize that shape.

D66's flat aggregate image remains one `Folded` placeholder per field in
declaration order, and every array placeholder remains zero. A parallel
per-field descriptor says `Absent` or `Finite`; a finite descriptor names an
offset and count in one concatenated run of source folds stored after the flat
field run. `Repeated` and `Hybrid` descriptor forms are reserved so the next
slice can extend the carrier without replacing it; the verifier refuses either
form in D67, and D68 later supplies their canonical meanings. The carrier
contains no target width, offset, padding byte or machine identity.

The IR setter records the flat folds, descriptors and finite elements as one
item image operation. The verifier first proves the flat and descriptor counts,
canonical finite offsets, scalar-field absence, zero array placeholders and
the total element extent; only then does it read each finite element and check
that fold against the field's selected-target element type. These are explicit
checks in builds without contract assertions. A malformed finite length,
out-of-target fold, descriptor on a scalar field or reserved form is a verifier
fault before a backend accessor can consume it.

The backend replays D45's target placement. An absent array field emits zero
for its complete target extent; a finite field emits one directive of the
target element width for each fold, while every inter-field gap and tail byte
remains zero. A finite literal whose elements are all zero is still a written
`.data` image, as D24 and D66 require; `zeroed` and an unnamed field supplied by
`of zeroed` remain absent within that written aggregate image. D60/D61 chains
copy every descriptor and finite fold into each distinct destination datum, so
forward references, aliases, inferred links and independence after mutation
remain unchanged.

Full and mixed repetition, a direct array storage name and a selected
fixed-array field remain L0304 as labelled module images. Repetition needs the
reserved compact suffix forms and is admitted by D68; copy needs image
resolution through another datum and retains the existing refusal of a
selected field as a module array initializer. Inferred struct literals, a
general `of expression`, the all-`of` spelling, construction and general
aggregate values remain outside this slice; D72 later supplies construction
only. No grammar, syntax node,
diagnostic code, runtime instruction, target fact or layout rule changes.

**Why a descriptor beside the flat run:** D66's scalar image and its verifier
contract remain stable, while a field can own a finite source image without
embedding target bytes or flattening element positions into aggregate fields.
Keeping every segment in the item's existing image run preserves the IR's
single-owner partition invariant and makes declaration-chain copying atomic at
the representation seam.

**The alternatives:** admit every D65 form at once, admit only the finite form,
add name-chain copy before a general carrier, flatten target bytes, or emit a
startup routine. The first and third add recursive image and cycle questions;
the second leaves a needless asymmetry with `of zeroed`; and the last two
violate target neutrality or [1460]. The complete compact carrier with only
finite and absent producers was chosen. D68 later supplies repetition, and
D69 follows a direct module-array image. D70 then permits an ordinary module
array image to take a selected field, and D71 permits a labelled field to take
another selected field's image.

**Pinned by** the IR, verifier, checker, lowering and backend public-seam cases;
`positive/module-struct-literal-array-image`;
`negative/module-struct-literal-array-image-length-mismatch`;
`negative/module-struct-literal-array-image-element-mismatch`;
`negative/module-struct-literal-array-image-value-not-known`;
`negative/module-struct-literal-array-image-storage-read`;
`negative/module-struct-literal-array-image-out-of-range`;
`negative/module-struct-literal-array-image-fold-overflow`;
`negative/module-struct-literal-empty-array-field-image`; the generated token
and IR records; and `runtime/module-struct-literal-array-image-is-loaded` on
Linux x86-64.

### D68 — A repeated module struct field image stays compact

**The tour said** that a full repetition writes one value into every array
position [0560], that a mixed repetition writes its prefix before repeating
one final value [0410], and that nothing runs before the entry point [1460].
D34 and D38 established compact repeated and hybrid images for module arrays;
D67 reserved the same two descriptor forms beside each fixed-array field.

**Chosen:** a fixed-array label in D66's explicitly typed module struct literal
also accepts D34's full repetition and D38's mixed-prefix repetition. The
written or inferred count and the field's D17 length must agree; a mixed prefix
must leave a nonempty suffix. Every prefix and repeated expression has the
field's scalar element type, must be known without execution under [1940], and
keeps D24/D34/D38's static-subtree, widest-fold and selected-target range
owners. Thus a count or element disagreement reports L0301, a zero contextual
length or excluded storage read reports L0304, an unknown call reports L0305,
and an overflowing or out-of-target fold reports L0300.

A `Repeated` descriptor has count zero, a nonzero folded pattern and no element
segment. A full zero repetition is canonicalized to D34's `Absent` image rather
than carrying a redundant zero pattern. A `Hybrid` descriptor has a prefix
count `k` with `1 <= k < length`, stores exactly those `k` source-order folds
in D67's concatenated element run, and carries one folded suffix pattern. A
hybrid remains a written image even when its prefix and suffix are all zero, as
D38 decided. The flat aggregate field placeholder remains zero in every case;
the representation still carries no target width, field offset or padding.

The IR setter records all flat folds, descriptors and finite or hybrid-prefix
elements in one item-owned run. The verifier first proves the aggregate-image
and descriptor partitions, field count, canonical offsets, field kinds and
form-specific count rules. Only then may it read a prefix or pattern and check
each fold against the selected target. A repeated zero pattern and a hybrid
whose prefix consumes the field are noncanonical verifier faults. These checks
are ordinary release-build code rather than contracts.

The backend replays D45's placement, emits a finite or hybrid prefix with the
field element's target directive, and emits a compact `.rept` suffix for a
repeated or hybrid field. Absent zero repetitions, inter-field gaps and tail
padding remain `.zero`. The same target-neutral descriptor therefore selects
`.long` for `usize` on a 32-bit target and `.quad` on a 64-bit target without
changing the IR. D60/D61 chains already copy each descriptor, its suffix value
and its compact prefix into distinct destination datums, so no new image
recursion or cycle rule is introduced.

A direct module array storage name or selected array field remains L0304 as a
labelled module image in this slice. D69 later follows the former through
another datum's finite, repeated, hybrid or absent image; D70 supplies the
ordinary module-array initializer rule for the latter, and D71 then admits it
as a labelled module image too.
Inferred literals, heterogeneous `of expression`, all-`of`, construction and
general aggregate values remain refused here; D72 later supplies construction.
No grammar, syntax node, diagnostic
code, runtime instruction, target fact or layout rule changes.

**Why finish the reserved carrier first:** repetition adds no image dependency:
all its folds are children of the terminal literal. Name-copy labels would add
a second datum to image resolution, while selected-field copy would cross an
existing module-array boundary. Completing the local descriptor meanings keeps
this slice acyclic and gives the verifier and backend one invariant at a time.

**The alternatives:** admit repetition together with direct and selected image
copy, admit only full repetition, flatten the expanded field into target bytes,
or synthesize startup stores. The first combines a compact producer with image
recursion, the second leaves D38's already represented hybrid form unused, and
the last two violate target neutrality or [1460]. All were declined.

**Pinned by** the IR, verifier, checker, lowering and backend public-seam cases;
`positive/module-struct-literal-array-image`;
`negative/module-struct-literal-array-image-length-mismatch`;
`negative/module-struct-literal-array-image-element-mismatch`;
`negative/module-struct-literal-array-image-value-not-known`;
`negative/module-struct-literal-array-image-storage-read`;
`negative/module-struct-literal-array-image-out-of-range`;
`negative/module-struct-literal-array-image-fold-overflow`;
`negative/module-struct-literal-array-repetition-zero-length`;
the generated token and IR records; and
`runtime/module-struct-literal-array-image-is-loaded` on Linux x86-64.

### D69 — A module array image may fill a labelled fixed-array field

**The tour said** that a module initializer is an image present before the
entry point [1460], that a fixed array's value is its element sequence [0520],
and that struct fields have declaration-order layout while labelled values may
name them in another order [0710], [0750]. D21 already follows a direct module
array name to its terminal static image. D67/D68 already carry every canonical
array image form beside a struct field.

**Chosen:** a fixed-array label in D66's explicitly typed module struct literal
also accepts a direct name bound to a module fixed-array datum with the exact
D17 length and element type. The field receives a copy of that datum's resolved
static image: D24's finite folds, D34's nonzero repeated pattern, D38's hybrid
prefix and suffix, or the absent zero image of an omitted, explicit `zeroed` or
zero-pattern source. The source may be declared later and may itself be a D21
direct-name chain. Each struct declaration still owns distinct storage; a
later write to the source array, the struct field or a D60/D61 struct-image
copy changes none of the others.

A length, element-type or non-array storage mismatch reports L0301 at the
source name and relates it to the field label. An unresolved or already refused
source keeps its existing owner without a second report; a source array-image
cycle keeps D21's single L0305. A type declaration, selected field or other
value remains L0304 in this slice. D70 moves that boundary for ordinary module
arrays, and D71 then lets a struct label reuse that contextual source.

Image resolution visits the named array before gathering the struct image, so
a forward finite, repeated or hybrid source cannot be mistaken for absent.
The lowering copies the source's canonical form into D67's existing descriptor,
re-bases a finite or hybrid prefix at the field's running element offset, and
calls the existing aggregate-image setter once. An all-zero finite image and
an all-zero hybrid remain written; an omitted or zero-repetition source remains
absent. The existing verifier rechecks descriptor form, count, offset and
selected-target fit before reading it, and the backend consumes the same
descriptor at D45's target-derived field offset. No IR, verifier, backend,
target, grammar, syntax or diagnostic representation changes.

**Why direct storage only:** it completes D21 parity without making an array
field a general value. Selected-field copy would read another aggregate's
descriptor and contradict the ordinary module-array initializer boundary;
construction or inferred literals need nominal-body and grammar decisions,
which D72 later supplies together.
Restricting the source to finite images would save no representation and would
arbitrarily discard D34/D38 forms the carrier already represents. All were
declined.

**Pinned by** the checker and lowering public-seam cases;
`positive/module-struct-literal-array-image-copy`;
`negative/module-struct-literal-array-image-copy-shape-mismatch`;
`negative/module-struct-literal-array-image-copy-source-cycle`;
`negative/module-struct-literal-array-image-copy-source-refused`;
`negative/array-type-name-is-not-storage`; the generated token and IR records;
and `runtime/module-struct-literal-array-image-copy-is-independent` on Linux
x86-64.

### D70 — A module array takes a selected field's static image

**The tour said** that a binding may name or infer its type [0040], [0050],
that a fixed array's value is its element sequence [0520], and that nothing
runs before the entry point [1460]. D21 follows module array images through
direct storage names, D51 copies a selected fixed-array field into a fresh
local array, and D67/D68 carry every canonical array image beside a struct
field. None decided whether the same field could supply a module array image.

**Chosen:** `[mut] name: [N]T = s.f` and `[mut] name := s.f` are admitted at
module scope when `s` directly names a module binding of an ordinary struct
with a layout and `f` is one of its fixed-array fields. The explicit form
requires `[N]T` to have the field's exact D17 length and element type; a
disagreement reports L0301 at the selection and relates it to the binding. The
inferred form takes that identity exactly. This is D51's contextual source at
module scope, not a general value: the root need not be mutable, and the
selection remains refused as an argument, return, discard, operand or bare
read.

The destination receives a copy of the field's resolved static image in
distinct storage. A D67 finite field becomes D24's finite array run, a D68
nonzero repetition stays compact, a hybrid keeps its finite prefix and suffix
pattern, and an absent field leaves the destination's image absent. Thus an
all-zero finite or zero-suffix hybrid remains written while an omitted,
`zeroed` or zero-repetition field remains loader-zeroed. A later write to the
struct field or destination array changes only that storage.

Image validation and lowering resolve the containing struct before reading its
field descriptor. The struct may be declared later, may itself follow a
D60/D61 aggregate image chain, and may have received the field through D69.
D69's struct-to-array edge and this array-to-struct edge may form a real image
cycle: `a: [N]T = s.f; s: S = (f: a)`. The existing per-declaration
`Visiting` state reports [1940]'s L0305 once at whichever declaration is first
found revisited and marks the rest invalid silently. An already refused
containing image likewise keeps its existing owner without a second report.

Lowering maps D67's existing `Absent`, `Finite`, `Repeated` and `Hybrid`
descriptor forms to the existing array-image setters. It reads a descriptor
only after the containing aggregate has a written image, reads prefix elements
only for the finite and hybrid forms, and lets every downstream D21 array link
copy the resulting ordinary array item. The existing verifier rechecks the
array image on the selected target, and the backend emits it with the array
element's target width. No IR, verifier, backend, target, grammar, syntax or
diagnostic representation changes.

**Why typed and inferred together:** D21 and D51 already give those spellings
one rule, and inference can carry the selected field's complete D17 identity
without inventing a nominal or general value. Admitting only the typed form
would add no safety or representation boundary. Delaying the whole rule would
leave D69's reverse dependency artificially one-way. Admitting `other.row` as
a label inside a struct literal is a second producer and validator edge; D71
adds that edge with separate cycle and descriptor evidence. All other
widenings were declined.

**Pinned by** the checker and lowering public-seam cases;
`positive/module-array-from-struct-field`;
`negative/module-array-from-struct-field-shape-mismatch`;
`negative/module-array-from-struct-field-cycle-array-first`;
`negative/module-array-from-struct-field-cycle-struct-first`;
`negative/module-array-from-struct-field-source-refused`; the generated token
and IR records; and
`runtime/module-array-from-struct-field-is-independent` on Linux x86-64.

### D71 — A labelled fixed-array field takes a selected field's static image

**The tour said** that a module initializer is an image present before the
entry point [1460], that a fixed array's value is its element sequence [0520],
and that a struct literal supplies labelled field images [0710]. D65 already
accepts a selected fixed-array field as the contextual source of a runtime
label. D69 admits a direct module array as the corresponding static source,
and D70 lets an ordinary module array take a selected field's static image.

**Chosen:** a fixed-array label in D66's explicitly typed module struct literal
also accepts `s.f` when `s` directly names a module binding of an ordinary
struct with a layout and `f` is one of its fixed-array fields with the label's
exact D17 length and element type. A disagreement reports L0301 at the
selection and relates it to the label. An unresolved or already refused root
keeps its existing owner without a second report. A scalar selection, an
element or nested selection, and a selection rooted at a type declaration
remain refused. This remains a contextual image source rather than a general
array or aggregate value.

The destination field receives a copy of the selected field's resolved image:
D67's finite run, D68's repeated or hybrid form, or the absent zero image. The
root may be declared later, may itself follow a D60/D61 aggregate image chain,
and may have received the selected field through D69, D70 or this rule. Each
declaration owns distinct storage; a later write to the source, destination or
another image-chain member changes only that storage. All-zero finite and
hybrid images remain written, while an omitted, `zeroed` or zero-repetition
field remains absent.

Image validation follows the containing struct before accepting the label.
The existing per-declaration `Visiting` state therefore also owns a pure
struct-to-struct selected-field cycle and a cycle mixing D21, D69, D70 and
D71: [1940]'s L0305 is reported once at the declaration first found revisited,
and the remaining path becomes invalid silently. A refused source likewise
does not acquire a second contextual report.

Lowering resolves the source aggregate before reading its field descriptor,
copies only the finite or hybrid prefix elements carried by that descriptor,
and re-bases their offset at the destination aggregate's compact element run.
The same helper copies an aggregate image through D60/D61, so both paths retain
one canonical offset rule. The aggregate-image setter is still called once;
the existing verifier rechecks descriptor form, count, offset and target fit,
and the backend consumes it at D45's placed field offset. No IR, verifier,
backend, target, grammar, syntax or diagnostic representation changes.

**Why the direct selected field:** D65 already gives the runtime spelling this
shape and D70 supplies the missing module-array image boundary. Reusing the
same direct-root, whole-field rule closes the remaining edge between array and
aggregate datums without making selection a general value.

**The alternatives:** also admit a selected scalar field, an indexed element,
a nested selection, an inferred struct literal or a general aggregate value;
or delay the rule. The first three cross D24's static-expression and the
depth-one storage boundaries, the next two require nominal construction or
aggregate temporaries (D72 later supplies only the former), and delay would
leave D69/D70's contextual image graph
artificially incomplete. All were declined.

**Pinned by** the checker and lowering public-seam cases;
`positive/module-struct-literal-selected-field-image`;
`negative/module-struct-literal-selected-field-boundary`;
`negative/module-struct-literal-selected-field-shape-mismatch`;
`negative/module-struct-literal-selected-field-cycle-first`;
`negative/module-struct-literal-selected-field-cycle-second`;
`negative/module-struct-literal-selected-field-mixed-cycle`;
`negative/module-struct-literal-selected-field-source-refused`; the generated
token and IR records; and
`runtime/module-struct-literal-selected-field-image-is-independent` on Linux
x86-64.

### D72 — Construction names the ordinary struct a labelled literal builds

**The tour said** that construction applies a type to labelled fields [0700],
that two ordinary structs have one type only when one declaration wrote both
[0710], and that field expressions run in source order [0410]. D64--D71 had
already implemented the same labelled run wherever a destination supplied its
nominal body, but a bare inferred literal deliberately had no such source.

**Chosen:** `T(field: value, ...[, of zeroed])` is a labelled `Struct_Literal`
whose optional nominal slot names `T`. It is admitted in exactly the storage
contexts already owned by D64--D71: as the initializer of a typed or inferred
local or module binding, and as the complete right-hand side of assignment to a
directly named mutable local or module ordinary struct. A typed binding or
assignment place must have `T`'s [0710] body; disagreement reports L0301 at
`T`, related to the destination. An inferred binding records `T`'s body before
settling the declaration. Through a type alias, the body remains the aliased
declaration rather than the spelling used here.

`T` must denote an enabled ordinary struct. A scalar type or a name denoting a
function or binding is a permanent L0301 error; an unresolved or already
refused type keeps its type-position owner. A body whose field or target-extent
refusal prevented layout silently refuses the construction after that owning
report. Positional `T(value)` remains the existing call/conversion-shaped
refusal, and `T(of zeroed)` remains a parser-owned L0010 refusal. A bare
inferred literal still has no nominal identity and remains L0304.

Every field rule is the one the literal already has. Labels remain freely
ordered but unique; missing and unknown labels keep L0310 and L0308; scalar,
array, repetition, `zeroed`, direct-name and selected-field values keep
D64--D71's contextual checks. Runtime labels are evaluated and committed
immediately in source order, followed by declaration-order fill, and a
successful whole assignment records the existing complete aggregate facts.
Module construction is a static image: known-value, folding, compact
array-field descriptors, image chains, cycle ownership and target emission are
unchanged. Construction is terminal as a literal and adds no image-graph edge.

The syntax tree uses no new node kind. `Struct_Literal` now has two fixed
slots: [0720]'s optional fill and D72's optional nominal type, followed by the
existing `Field_Value` run. Bare literals put `No_Node` in the nominal slot.
Resolution treats the nominal as a type position; the checker records its body
on the literal or inferred declaration. Lowering continues to write directly
into the binding, assignment place or module image. There is no aggregate
temporary, IR operation, verifier rule, backend address form, target fact or
layout change.

Construction in an argument, return, discard, operand, nested expression or any
other general expression position remains L0304. Struct parameters and returns
still require R2.30's aggregate ABI. Construction does not enable [0700]'s
scalar conversion form, anonymous struct types, struct-of-struct fields,
heterogeneous `of expression` or the all-field synonym.

**Why this boundary:** the nominal prefix supplies exactly the identity that
prevented D64's bare literal from supporting inference. All three destination
contexts already have storage, definite-assignment and static-image rules, so
admitting them together removes a syntactic asymmetry without pretending an
ordinary struct is a first-class expression value.

**The alternatives:** parse a dormant construction refused everywhere, admit
only inferred or local construction, add general aggregate temporaries, or
include positional conversion and the aggregate ABI. The first repeats D63's
declined half-migration; the next two arbitrarily split identical contextual
destinations; and the last two require representation and calling-convention
work this slice deliberately does not have. All were declined.

**Pinned by** the parser, checker and lowering public-seam cases;
`positive/struct-construction-contexts`;
`negative/construction-not-enabled`;
`negative/struct-construction-nominal-mismatch`;
`negative/struct-construction-callee-not-struct`;
`negative/struct-construction-type-not-declared`;
`negative/immutable-struct-construction-assignment`;
`negative/struct-construction-all-of-not-enabled`;
`negative/struct-literal-without-layout`;
the generated construct, token and IR records; and
`runtime/struct-construction-order` on Linux x86-64.
