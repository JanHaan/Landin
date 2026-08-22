## THE GRAMMAR OF THE ENABLED KERNEL

This section is the normative grammar, and it is deliberately partial. It
covers the constructs the compiler enables today and nothing else, so that
what a program may say and what the compiler will accept are the same
sentence. It grows one slice at a time, and a construct described elsewhere
in this tour but absent here is not enabled yet: the compiler says so by
[1830] rather than guessing.

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
declaration ::= "public"? (binding | function)

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
reserves seventeen words; the reserved set of the whole language is
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
it is read [0080]. The kernel's types are the scalar names only:
several names sharing one declaration [0100], types the program
declares [0120], structs, variants and the rest of TYPES YOU
DECLARE are not enabled yet.
```landin-grammar
binding     ::= "mut"? identifier ":" type ("=" expression)?
              | "mut"? identifier ":=" expression
type        ::= "u8" | "u16" | "u32" | "u64"
              | "i8" | "i16" | "i32" | "i64"
              | "usize" | "isize" | "bool"

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
place       ::= identifier

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
Evaluation order is left to right and fixed [0410], so the table
decides what binds, never what runs first.
```landin-grammar
primary     ::= literal | identifier | call | "(" expression ")"
call        ::= identifier "(" arguments? ")"
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
  module     every file compiled together. There is one, until
             [1410]'s directories arrive.
  signature  a function's parameters and its named return
             [1800]. The named return is a place the body
             assigns [0930], so it is declared here and not in
             the body, and a parameter and a return may not
             share a name.
  body       what a function runs, and one for each arm of an
             `if` and for its `else` [1810]. A statement run is
             a block and a block is what scopes [1090], so a
             name declared in one arm is not visible in another
             and not after the branch closes.
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
  u8 u16 u32 u64      every unsigned value of that many bits
  i8 i16 i32 i64      every signed one, two's complement
  usize isize         the same pair, at the target's pointer
                      width [0160]
  bool                false and true [0180]
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
  a binding's declared type [1790]
  the type of the place an assignment writes [1810]
  the type of the parameter an argument fills [1800]
  the named return's type, for an expression body [0880]
  the other operand's type, for a binary operator
  a unary operator's own context, handed on [1820]
  a branch's condition and an exit's 'when', both of which
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
  + - * / %, and [0300]'s +% -% *%
             one integer type, and that type back [0290]
  & ^ |, and the unary ~
             one integer type, and that type back [0330]
  << >>      an integer shifted by an integer of that same
             type, and that type back [0320]. The amount is
             not bounded by the width: [0320] fills with
             zeros beyond it for any amount.
  == <> < <= > >=
             one type on both sides, and a bool back [0350]
  and or not bool, and a bool back [0340]
  unary -    one integer type, and that type back
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
  a mutable binding [0060]     may be
  a named return               may be: [0930] says it must
                               be, and [1840] declares it
                               as a place for that reason
  an immutable binding         may not: [0040] makes it
                               immutable and [0450] says it
                               protects the value it holds
  a parameter                  may not: the unmarked
                               convention is [0900]'s 'in',
                               which is the promise not to
                               change the value
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
