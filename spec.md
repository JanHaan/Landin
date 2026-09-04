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
spelled that way. A quoted word is not thereby reserved: when [1760]'s
keyword rule omits it, the token is an identifier whose spelling the
enclosing production recognises. Thus 'of', 'lenof', 'variant', 'begin',
'match', 'defer' and 'undo' remain
ordinary names everywhere their contextual productions do not meet them.
A token is as long as it can be, comments excepted, whose
opener decides [1780]: 'inc' followed by 'x' with nothing between them is
the one name 'incx', which is why [1750] says what separates two tokens.

### [1740] A source file is an import prelude and declarations in any order

A source file is a possibly empty import prelude followed by declarations in
any order. All reached source files together are the program.
Order inside a module does not matter [0130], so a file is a set of
declarations rather than a sequence of them, and a name may be used
above the line that introduces it. 'public' rides on a declaration
and not on a statement [0090]: what a module exports is decided
where the module is written, never inside a body.

```landin-grammar
program     ::= import_declaration* declaration*
import_declaration ::= "import" import_path
import_path ::= identifier ("/" identifier)*
declaration ::= "public"? (atom_declaration | binding | function
                            | external_function | type_declaration
                            | concept_declaration)
                | conformance_declaration
                | fixed_conditional
fixed_conditional ::= "fixed" "if" expression "then" declaration*
                      ("elsif" expression "then" declaration*)*
                      ("else" declaration*)? "end" "if"
atom_declaration ::= identifiers ":" "atom"
identifiers ::= identifier ("," identifier)*

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
rule below this layer mentions it. A line end therefore never
terminates a statement: when the token after it can continue the
expression or selection before it, it does. This is [1060]'s
one-line rule read from the other direction.

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
reserves thirty-six words; the reserved set of the whole language is
larger, and each word joins it with the construct that introduces
it, so a program that avoids a construct never trips over its
keyword. Type names are not among them: u32 and bool are ordinary
declared names [0120] that the kernel happens to predeclare.

```landin-grammar
identifier  ::= lower (lower | digit | "_")*
              | "_" (lower | digit | "_")+
lower       ::= "a" ... "z"
digit       ::= "0" ... "9"
keyword     ::= "addr" | "alignof" | "and" | "any" | "atom" | "dec" | "else"
              | "elsif" | "end" | "escaping" | "extern" | "fail" | "false"
              | "fixed" | "from" | "if" | "import" | "in" | "inc" | "inout"
              | "mut" | "none" | "not" | "or" | "ptr" | "public"
              | "return" | "sink" | "sizeof" | "struct" | "then"
              | "true" | "try" | "type" | "when" | "zeroed"

```

### [1770] The kernel's literals include characters, floats and text

The kernel's literals are integers, floats, characters, quoted text,
the two booleans, and contextual `zeroed`.
Integer literals are untyped and take
the type of their context [0190], defaulting to i32 with none [0200]; the bases
and the separator are [0220]'s. `zeroed` has no type of its own: [0540] gives it
the all-bits-zero image of a directly supplied initializer, assignment or
field-label context. D27--D30 establish fixed-array contexts, D39--D43 scalar
contexts, D49 and D57--D59 whole array-field and ordinary-struct contexts,
D62 the depth-one indexed field place, D64--D67 labelled struct fields and
static images, D75/D76 variant-bearing struct storage and case payloads, and
D87 depth-one nested ordinary storage. It remains refused
where no enabled construct supplies that context. D161 admits [0260]'s quoted
literal when its direct context is a read-only `[]u8`; the unescaped source
content is UTF-8 [1750], and [0270]'s byte escapes are decoded into that view.
Raw text [0280] takes the same direct byte-slice context by D164, but interprets
no escape and removes a line-leading closing delimiter's indentation. D181
adds `utf8`, `utf16` and `cstring` contexts and makes `utf8` the contextless
default. A scalar escape is encoded as UTF-8 or UTF-16 for those views; a byte
escape remains exclusive to `[]u8`. D162 admits
[0210]'s decimal float with [0220]'s optional exponent. D166 adds [0230]'s
hexadecimal fraction and required binary exponent. D167 admits [0240]'s
type-qualified `infinity` and `nan` values for f32 and f64. D163 admits
[0250]'s single-quoted character as exactly one Unicode scalar value of fixed
type `u32`. A raw scalar is shortest-form UTF-8; [0270]'s simple escapes and
`\u{...}` spell scalar values, while byte-only `\xNN` does not.

```landin-grammar
literal     ::= integer | float | character | text | raw
              | "true" | "false" | "zeroed"
character   ::= "'" (character_escape | unicode_scalar) "'"
character_escape ::= "\\" ("n" | "r" | "t" | "e" | "\\" | "\"" | "'"
                  | "u" "{" hex_digit+ "}")
text        ::= "\"" (text_escape | text_byte)* "\""
text_byte   ::= any byte except quote, backslash or line_end
text_escape ::= "\\" ("n" | "r" | "t" | "e" | "\\" | "\"" | "'"
                  | "x" hex_digit hex_digit
                  | "u" "{" hex_digit+ "}")
raw         ::= quote_run raw_content quote_run
quote_run   ::= "\"" "\"" "\"" "\""*
raw_content ::= any byte*
integer     ::= decimal | hex | octal | binary
float       ::= decimal_fraction decimal_exponent?
              | hex_fraction binary_exponent
decimal_fraction ::= decimal_digits "." decimal_digits
decimal_exponent ::= ("e" | "E") ("+" | "-")? decimal_digits
hex_fraction ::= "0x" hex_digits "." hex_digits
binary_exponent ::= ("p" | "P") ("+" | "-")? decimal_digits
decimal_digits ::= digit (digit | "_")*
hex_digits  ::= hex_digit (hex_digit | "_")*
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
it is read [0080]. The kernel's types are the thirteen scalar names, atom sets, fixed arrays,
pointers, slices, D145's `any C`, function types with their complete declared
error sets, and what [1795] declares from them: aliases, named ordinary structs and D74's named
variant-bearing structs. `mut` in a pointer or slice type records permission to
write the pointee or viewed elements [0430] [0570]; it is independent of a
binding's `mut` [0070].
Enabled runtime leaves are scalar, reference, function, fixed array or D147's
erased pair; ordinary and variant-bearing structs compose those leaves
recursively. A pointer is one
target pointer-width carrier and a slice is its non-null base plus a `usize`
length. Neither has an all-zero value [0540]. A function type is written with
[1800]'s signature syntax. Its parameter and return names describe positions and
declare nothing; only a function declaration opens [1840]'s signature scope.
The other TYPES YOU DECLARE
remain deferred. A type position holds a declared name either way, since
[1760] makes the thirteen ordinary declared names the kernel
predeclares; the grammar spells them out because they are the
only ones a program does not have to declare for itself.
An array [0520] is a type position too, and its length is part
of it. D136 folds the bound expression from integer literals, fixed formals,
unary `-`, and the target-independent binary arithmetic `+`, `-`, `*`, `/`
and `%`.
The element is a type like any other. A parameterized alias or nominal struct
is a type position through its fully applied positional application. D135
substitutes an alias during checking; D137 interns a struct application by its
template and normalized actual tuple, then checks the substituted field shape.

```landin-grammar
binding       ::= "mut"? identifier ":" type ("=" expression)?
                | "mut"? identifier ":=" expression
type          ::= function_type | array_type | pointer_type | slice_type
                | any_type | type_application | scalar_name | text_name
                | declaration_reference
function_type ::= signature
array_type    ::= "[" expression "]" type
pointer_type  ::= "ptr" "mut"? type
slice_type    ::= "[" "]" "mut"? type
any_type      ::= "any" concept_reference
type_application ::= declaration_reference "(" type_argument
                     ("," type_argument)* ")"
type_argument ::= type | integer
scalar_name   ::= "u8" | "u16" | "u32" | "u64"
                | "i8" | "i16" | "i32" | "i64"
                | "usize" | "isize" | "f32" | "f64" | "bool"
text_name     ::= "utf8" | "utf16" | "cstring"

```

### [1795] A type declaration names a type, and names nothing new

A type declaration names a type, and names nothing new.
[0120] declares a type like any other value and [0650] writes
'distinct' to make one that is not the type it was written from.
D15 reads the second as deciding the first: without that word a
declaration gives an existing type another name and the two are
one type everywhere. A struct body [0670] has no existing type
to alias and introduces the nominal type [0710]. Without formals its identity
is this declaration's empty-actual instance. With formals, D137 makes each
fully applied normalized actual tuple a distinct instance of this declaration;
an alias of either keeps that same identity. Every alias chain has to reach a scalar type, atom set, fixed array, function
type or struct body. A chain that comes back to an alias in the chain
reaches no type and is refused at that declaration.
A type name is an ordinary declared name [1760], so one
declaration per name per scope [1850] and a name that names
nothing is refused [1860] both hold for it unchanged.

```landin-grammar
type_declaration ::= identifier ":" "type"
                     ("=" (atom_union | type | struct_body)
                     | type_formals "=" (type | struct_body))
concept_declaration ::= identifier ":" "type" "=" concept_body
concept_body    ::= "concept" type_formals
                    ("is" concept_reference
                     ("," concept_reference)*)?
                    concept_entry* "end" identifier?
concept_entry   ::= identifier ":" signature
conformance_declaration ::= type_formals? conformance_target "is"
                            concept_reference "(" conformance_argument
                            ("," conformance_argument)* ")"
                          | type_formals? conformance_target "is"
                            concept_reference "(" ")"
conformance_target ::= array_type | pointer_type | slice_type | any_type
                     | type_application | declaration_reference
conformance_argument ::= identifier ":" argument_rhs
concept_reference ::= declaration_reference
declaration_reference ::= identifier | qualified_reference
qualified_reference ::= identifier ("." identifier)+
type_formals    ::= "(" type_formal ("," type_formal)* ")"
type_formal     ::= identifier ":" "type" constraint?
                  | "fixed" identifier ":" type
constraint      ::= "is" concept_reference
atom_union      ::= declaration_reference "|" declaration_reference
                    ("|" declaration_reference)*
struct_body      ::= "struct" member+ "end" identifier?
member           ::= field | variant_part
field            ::= identifier ":" type
variant_part     ::= identifier ":" "variant" variant_case
                   ("|" variant_case)* "end" identifier
variant_case     ::= identifier (":" "(" field ("," field)* ")")?

```

### [1800] A function is a value with a body, and its returns are named

A function is a value with a body, and its returns are named.
'=' opens the body and 'end' closes it [0870]; a body that is one
expression still takes an end, and the expression fills the named
return [0880]; every named return must be assigned before the
function returns [0930]. The parameter conventions [0900], `escaping` [0780], `from` [0790]
and generic parameters [1290] have their parser and resolution foundation on
a declared routine. Its complete signature scope collects type/fixed formals,
runtime parameters and named returns before resolving any type; runtime
formals alone make the runtime signature. `escaping` precedes an explicitly
written convention, and both precede the parameter name (D140). An omitted
convention and explicit `in` have the same language meaning but remain distinct
syntax facts. Each `from` name is retained in written order and associated with
the correspondingly labelled runtime parameter position. The reference-origin
pass checks every returning edge against exactly that ordered source set;
unknown, duplicate, missing and extra sources are rejected. A generic template has no standalone
function value or IR item. D138's first executable increment deduces a direct
type formal or exact `[n]t` shape from context-free runtime argument types,
interns the concrete routine instance, and emits that instance rather than the
template.
An enabled nongeneric signature takes values
including function values, hands one or more named values (or none) back, and
optionally declares [0940]'s payload-free atom error set. A function type
reuses the nongeneric `signature` production but has no body. Its labels are
type description only and do not declare parameters or named returns.

An anonymous function [1010] writes that same signature and body without a
module name. It captures no enclosing local, parameter or named return: its
signature and body are a separate routine whose outer scope is the module.
Forming it produces a static code address and does not execute its body.
A body is one block. Its statements run in source order and an optional final
expression fills the one named return or the complete anonymous aggregate of a
multiple return list. One token past a leading name decides
between a first statement and a direct expression: ':' opens a binding and an
assignment operator opens an assignment; anything else means the body begins
with its value. A
function returning none has no expression form, because there is no return for
one to fill.
An unguarded `return` has no fallthrough edge, so it can end a statement-only
block but cannot be read as the prefix of that block's final expression. This
also keeps `return 1` the refused payload spelling [1810]. A guarded return may
prefix a final expression because its untaken edge continues.

```landin-grammar
function           ::= identifier ":" declared_signature "=" body "end" identifier?
external_function  ::= "extern" "(" "c" ")" identifier ":" declared_signature
anonymous_function ::= signature "=" body "end"
signature          ::= "(" parameters? ")" "->" returns errors?
declared_signature ::= "(" routine_formals? ")" "->" returns errors?
routine_formals    ::= routine_formal ("," routine_formal)*
routine_formal     ::= parameter | type_formal
errors             ::= "!" (declaration_reference
                             ("|" declaration_reference)* | "...")
parameters         ::= parameter ("," parameter)*
parameter          ::= "escaping"? parameter_convention? identifier ":" type
parameter_convention ::= "in" | "inout" | "sink"
returns     ::= "(" named_return ("," named_return)* ")" | "none"
named_return ::= identifier ":" type
                 ("from" identifier ("," identifier)*)?
body        ::= block
block       ::= statement* | value_statement* expression
value_statement ::= binding | destructuring_binding | assignment
                  | increment | discard | call | defer | undo | try
                  | "return" "when" expression
                  | "fail" expression "when" expression
                  | break | continue | loop | while | for
                  | if | match | bare_block
destructuring_binding ::= "(" destructured_field
                          ("," destructured_field)* ")" ":=" expression
destructured_field ::= identifier (":" (identifier | "_"))? | "_"

```

### [1810] Statements do one thing each, and only exits carry 'when'

Statements do one thing each, and only exits carry 'when'.
Assignment is a statement and never an expression [0390]; there is
no '++', and 'inc' and 'dec' are statements too [0400]; discarding
a result is written out [1020]; the one-line form of every
construct is [1060]. 'when' rides on an exit and on nothing else,
which is what keeps a conditional statement from having two
spellings.
`return` carries no value. A named return is assigned like any other place and
`return` leaves [0930], which is why the kernel needs no second way to say what
a function hands back. `fail` is the other early exit [0970]: it carries one
payload-free atom on the declared channel and does not read the successful
named return.
A direct or selected call is a statement as well as an expression, because a
function returning none has nothing to bind and [1020] wants a result discarded
on purpose rather than by omission. A call whose result is dropped that way is
the one place the kernel accepts an ordinary expression standing
alone. A standalone `try call` explicitly propagates its failure and discards
any successful result. `defer` and `undo` each register one call when their
statement is reached and evaluate the callee and arguments only on applicable
exits from the lexical block [1100] [1110]. They are statements rather than
expressions and so cannot supply a block's final value. A match is D77's
exhaustive tag selection or
[0640]'s exhaustive atom-set selection. A variant subject is one directly
selected variant part and each case arm carries one statement or one
expression; a bare `begin` block makes a multi-statement arm. D78 extends the
arm with positional payload bindings. An `if`, a `match`, and a bare `begin`
block retain their statement forms and also occupy expression positions under
[1820].
A place is [1820]'s indexed selection, so a binding, a field of a struct, or
an enabled array element is written
and stepped exactly as the binding holding it is. What may be
written is [1900]'s and not this rule's: a field is writable when
the binding it belongs to is.

D165 enables [0390]'s compound forms. Each reads the selected place, applies
the corresponding [1820] binary operator to that value and the right-hand
expression, then writes the result back. The place is evaluated once before
the right-hand expression [0410], must already be assigned [1910], and needs
the same write permission as `=` [1900]. The operator keeps its ordinary
type, known-operand, trapping and wrapping rules.

R4.10 admits the statement forms of [1130], [1140], [1170], [1180], and
[1190]. An unconditional loop tests nothing; a `while` condition
is evaluated before every iteration and must be `bool`. `break` transfers to
the point after its target loop and `continue` transfers to that loop's next
condition test (or next unconditional iteration). Without a label they target
the nearest loop; with one they target the nearest enclosing loop carrying
that ordinary name. A labelled loop closes with its label. Their optional `when`
condition is evaluated once and must be `bool`; its false edge continues with
the following statement. Both transfers leave every lexical block between the
statement and the loop edge, so [1100]'s `defer` runs and [1110]'s `undo` does
not. A conditional loop's optional `complete` block runs only when its
condition becomes false; a `break` skips it. Facts established only in a loop
body or completion block do not establish definite assignment after the loop.
`break with` and value-producing loops are D158's extension. D159 enables the
integer-range form of `for`: both bounds are evaluated once, from left to
right, and have one integer type. `a..<b` visits the ascending values for
which the element is less than `b`; `a..b` also visits `b`. Either form is
empty when its first value is already beyond its last. The element binding is
an immutable copy with the range's type; an optional index is an immutable
`usize` beginning at zero. `continue` advances both before the next test, and
the inclusive form completes at its maximum integer endpoint without first
overflowing it. D160 enables collection traversal over a slice or a fixed
array: the source is evaluated once, the element binding is a place in that
storage rather than a copy, and the optional index is an immutable `usize`
beginning at zero. The element is writable over `[]mut T` and over a fixed
array held in a place the body could assign; over `[]T` and over any other
array it is read-only [1160]. A body that writes the storage by index observes
the write through the element, and the reverse. Elements that are themselves
fixed arrays or slices retain their complete shape under D178, including when
copied out through a loop value. An `any C` element retains its erased identity
and evidence under D179. A source that would need [1320]'s iterable evidence
is enabled by D180 when its type is a struct or `any C` and exactly one
conformance to the unambiguous concept named `iterable` supplies `Cur`, `Item`, and
[1320]'s four exact, infallible signatures. The source expression is evaluated
once and copied into private traversal state. `first` is called once. Each
test calls `at_end`; a false result calls `item` before entering the body.
Fallthrough and `continue` run applicable cleanup and then call `next`; a
`break` runs applicable cleanup and skips `next`. The optional immutable
`usize` index begins at zero and advances with each `next` call.

The cursor keeps its complete type identity between calls. The element is an
immutable copy of the exact `Item` result, not an alias into the source, and
therefore carries only the origin allowed by [1320]'s source-free result.
An `any C` source and an `any C` item each retain their own erased concept and
evidence identities; neither two-cell value is ever interpreted as a slice.
Missing or ambiguous concept identity, or missing, ambiguous, or non-exact
iterable evidence, is L0301. Integer ranges
and fixed-array or slice storage traversal retain D159--D160 and D178--D179
unchanged.

```landin-grammar
statement   ::= binding | destructuring_binding | assignment | increment
              | discard | call | defer | undo | try | return | fail
              | break | continue | loop | while | for | if | match
              | bare_block
assignment  ::= place assignment_operator expression
assignment_operator ::= "=" | "+=" | "-=" | "*=" | "/=" | "%="
                      | "&=" | "|=" | "^=" | "<<=" | ">>="
                      | "+%=" | "-%=" | "*%="
increment   ::= ("inc" | "dec") place
discard     ::= "_" "=" expression
defer       ::= "defer" call
undo        ::= "undo" call
return      ::= "return" ("when" expression)?
fail        ::= "fail" expression ("when" expression)?
break       ::= "break" identifier? ("with" expression)?
                ("when" expression)?
continue    ::= "continue" identifier? ("when" expression)?
loop        ::= "loop" "do" block "end" "loop"
              | identifier ":" "loop" "do" block "end" identifier
while       ::= "while" expression "do" block
                ("complete" block)? "end" "while"
              | identifier ":" "while" expression "do" block
                ("complete" block)? "end" identifier
for         ::= "for" identifier ("," identifier)? "in" expression
                ((".." | "..<") expression)? "do" block
                ("complete" block)? "end" "for"
              | identifier ":" "for" identifier ("," identifier)?
                "in" expression ((".." | "..<") expression)? "do" block
                ("complete" block)? "end" identifier
try         ::= "try" (call | labeled_application)
if          ::= "if" expression "then" block
                ("elsif" expression "then" block)*
                ("else" block)?
                "end" "if"
match       ::= "match" expression match_arm+ "end" "match"
match_arm   ::= (declaration_reference | "_")
                ("(" match_binding ("," match_binding)* ")")?
                ":" (statement | expression)
match_binding ::= "inout"? identifier
bare_block  ::= "begin" block "end"
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
A selection is [0420]'s ordinary member-selection syntax. The enabled
representation retains every selected name without deciding whether it denotes
a struct field or [0430]'s `val` pointee; that classification belongs to later
checking. It binds tighter than every operator because it is part of naming a
thing rather than an operation on one, and it is left to right, so 'a.b.c'
selects from what 'a.b' named.
R3.10 uses that same retained selection for a qualified declaration reference.
When its first name is this file's imported namespace, the first selected name
is public module lookup and the namespace produces no runtime value. Otherwise
the selection is the ordinary runtime form above. Later selections from a
module binding are ordinary fields of the selected value.
An index or slice selection [0570] binds the same way and for the same
reason, and takes what a selection named: `a[i]`, `a.b[i]` and
`a[lower..<upper]` are all written there. The two range spellings are
retained separately so inclusive and half-open upper bounds are checked before
an address is formed. Neither form derives from a call, because nothing
selects from one and nothing indexes one either. A call may consume that
complete selection as its callee, which is how a function-valued field is
called; the call itself still cannot be selected or indexed.
An ordinary-struct literal is [0710]'s nonempty run of labelled field values,
optionally followed by [0720]'s contextual fill. D64--D71 state the contexts
that admit it. D72's construction and [0980]'s direct named call have one
`labeled_application` syntax: the parser retains each argument's label and
neutral RHS, and resolution classifies the callee before selecting type or
expression projections. A construction may then use the optional trailing
fill; the all-fill spelling remains refused by name.
A call-site `else` binds to the call except where that same token directly
closes an enclosing `then` or `elsif` arm; parentheses around the recovered
call make the inner use explicit.
An `if`, exhaustive `match`, bare `begin` block, `loop`, `while`, or `for` is
also a primary. A loop is value-producing when its targeted `break` edges carry
`with` values. Every break edge then carries one value of the joined type; a
finite conditional loop also needs `complete` to leave through such an edge.
Scalar values use the join's ordinary slot. Fixed arrays, structs, slices and
`any` fill the caller-owned destination directly before cleanup runs.
For the other controls, their
conditions or subject run first, then exactly the selected block runs in source
order. In a value context the final expression of every edge that can fall
through supplies the answer; an edge that returns supplies none. D124 gives the
complete edge and type rule, and D125 gives its storage representation. D158
extends the same caller-owned representation to loop values.
Evaluation order is left to right and fixed [0410], so the table
decides what binds, never what runs first.

```landin-grammar
primary     ::= literal | array_literal | array_repetition | struct_literal
              | empty_slice | labeled_application | anonymous_function
              | indexed | call | address | pointer_conversion
              | any_construction | measurement | try
              | if | match | bare_block | loop | while | for
              | "(" expression ")"
array_literal ::= "[" expression ("," expression)* "]"
array_repetition ::= "[" integer "of" expression "]"
                   | "[" "of" expression "]"
                   | "[" expression ("," expression)* "," "of" expression "]"
struct_literal ::= "(" field_value ("," field_value)*
                   ("," "of" expression)? ")"
field_value ::= identifier ":" expression
labeled_application ::= indexed "(" labeled_arguments ")" recovery?
labeled_arguments ::= (expression ",")* labeled_argument
                      ("," labeled_argument)* ("," "of" expression)?
labeled_argument ::= identifier ":" argument_rhs
argument_rhs ::= expression | type
indexed     ::= selection (index | slice_selection | ("." identifier))*
index       ::= "[" expression "]"
slice_selection ::= "[" expression (".." | "..<") expression "]"
selection   ::= identifier ("." identifier)*
call        ::= indexed "(" arguments? ")" recovery?
recovery    ::= "else" expression
              | "else" "(" identifier ")" block "end"
address     ::= "addr" place
pointer_conversion ::= "ptr" "(" expression ")"
any_construction ::= "any" "(" expression ")"
empty_slice ::= "[" "]"
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
R3.10 recognizes [1430]'s import alias and [1440]'s selected import shapes and
refuses each by name; R4.30 owns enabling them.

### [1840] The kernel's scopes, outermost first

The kernel's scopes, outermost first.
[0130] and [0140] are two sentences about scopes and this
grammar has to say which scopes it has, because a rule about
an inner scope means nothing until the inner ones are named.

| scope | what it holds |
| --- | --- |
| program | every module reachable from the entry directory after [1420]'s ordered-root selection. This is the outer identity and the one whole-program conformance register; it is not a source namespace. |
| module | every direct `.ldn` file in one directory [1410]. Its unordered declarations are shared by those files, module-internal by default and public only when written so. |
| file imports | the final segment of each import in this file's prelude [1420] [1450]. Each binding is a module namespace, not a declaration or value; this scope encloses the module scope for lookups performed from that file. |
| type declaration | D135's complete ordered formal list. The scope encloses the declaring file's imports and is visible in every fixed formal's declared type, direct concept constraint and in the alias or struct body, regardless of formal order. It closes with that declaration: its names do not enter the module or another type declaration. A type declaration without formals opens no scope. |
| concept declaration | D142's complete ordered type-formal list. It encloses the declaring file's imports and is visible in every direct constraint, parent name and entry signature. Entry parameter and result labels describe signature positions and declare nothing in this scope. |
| conformance declaration | D142's optional complete type/fixed binder. It encloses the declaring file's imports and is visible in every binder constraint, the target type and every labelled input or function RHS. The conformance itself declares no module name. |
| signature | a declared routine's type/fixed formals, runtime parameters and named returns [1800]. Every binder is collected before any signature type or direct concept constraint is resolved, so its source order has no visibility meaning. Named returns are places the body assigns [0930]; all three binder kinds share one namespace, but type/fixed formals are compile-time-only and have no storage. A declared function's signature encloses its file-import scope; a no-capture anonymous signature does the same rather than enclosing the expression's local scope. A written function type opens no scope and its labels declare nothing. |
| body | what a function runs; one for each arm of an `if` and its `else`; one for each `match` arm; one for every bare `begin` block; and one for a call-site recovery [1810] [1030]. A statement run plus its optional final expression is a block and a block is what scopes [1090], so a name declared in one is not visible in a sibling or after the block closes. Match payload bindings and a recovery error name live only in their block. |

[1800]'s direct final expression opens no additional scope inside its function
body, because an expression declares nothing.
Order matters in a body and does not in a module. [0130]'s set
is a set of declarations, so a module name may be used above
the line that introduces it; [1800]'s block is a sequence, so a local is visible
to the statements and final expression after it and its own value is read
before its name exists [0110].
Lookup proceeds through body and signature scopes, then this source file's
imports, then its module. An import may therefore shadow a same-named module
declaration for qualified lookup, and a parameter or local may shadow the
import. Imports do not enter sibling files and are not re-exported.

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
The file-import scope follows the same rule: two imports with one final segment,
including a repeated identical import, are refused and both import sites are
reported.

### [1860] A name that names nothing is refused

A name that names nothing is refused.
There is no implicit declaration in this language: a name that
is not in scope is a misspelling and not a new binding [1250].
The report names the use, because the use is where the mistake
is and the declaration that was meant is not there to point at.
An imported namespace whose selected member exists but is not public is a
different error: the use is refused as inaccessible and the private declaration
is related evidence. A namespace used without selecting a member names no
runtime or type value and is likewise refused.

### [1870] The kernel's types, and what each of them holds

The kernel's types, and what each of them holds.
[1790] gives the kernel scalar and text spellings and nothing that
says what one of them holds, so nothing yet says whether a
u8 may be given 300. [0150] puts the width in the name,
[0160] takes usize and isize from the machine and [0180]
gives bool its two values; written out, that is:

| type | what it holds |
| --- | --- |
| `u8` `u16` `u32` `u64` | every unsigned value of that many bits |
| `i8` `i16` `i32` `i64` | every signed one, two's complement |
| `usize` `isize` | the same pair, at the target's pointer width [0160] |
| `f32` `f64` | IEEE 754 binary32 and binary64 values, including signed zero, infinities and NaNs [0170] [0240] |
| `bool` | false and true [0180] |
| `ptr T`, `ptr mut T` | one non-null target address, with tracked origin unless constructed from an integer [0430] [0470] |
| `[]T`, `[]mut T` | one non-null aligned base and a `usize` length [0570] [0580] |
| `utf8` | a distinct immutable `[]u8` view of validated shortest-form UTF-8; its length counts bytes [0600] |
| `utf16` | a distinct immutable `[]u16` view of valid UTF-16; its length counts code units [0600] |
| `cstring` | a distinct immutable `ptr u8` view of validated UTF-8 followed by NUL, with no length [0600] |
| an atom union | exactly the declaration identities in its flattened set [0630] [0640] |

Two's complement is not a new decision. [0300]'s wrapping
forms have to wrap somewhere and [0320]'s '>>' keeps a sign,
and neither means anything without it.
Each of the thirteen is its own type. usize is not u64 on a
machine whose pointer is eight bytes wide, because if it
were, [0310] would refuse a program on one target and accept
it on another for a reason no paragraph here could state.
[1510]'s 'sizeof usize == 8' asks what a machine does; it
does not say two names are one type.
u128 and i128 [0150], the packed widths [0730] and f16 [0170] are described in
this tour and are not enabled yet. D162 enables f32 and f64 without making
either an integer or one another.
An atom declaration introduces one value and its singleton type. An atom union
is structural: aliases are flattened, order and repeated members do not change
identity, and assignment or argument passing may widen a singleton or smaller
set into a set that contains it. No integer is an atom and no zero or default
atom exists.
With one atom, `atom | ptr T` uses zero for the atom and every nonzero pattern
for the pointer, occupying one target pointer carrier [0480]. With two or more
atoms it uses the ordinary target-parametric tag-plus-pointer payload placement;
the source spelling never assumes the one-word optimization.
Fixed arrays hold their declaration-order elements [0520], and ordinary or
variant-bearing structs hold the fields their nominal declaration gives them
[0710] [0750]. A function type holds a target code address with the complete
parameter and result signature [0870] [1000]. The signature, not the address,
decides which values may be stored together and how a call is checked.

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
- the named return's type, or the complete anonymous result aggregate for a
  multiple-return expression body [0880] [0990]
- the result expected from an `if`, `match`, bare `begin`, or call-site `else`
  expression; that same complete context reaches every fallthrough answer

- the element type of a contextual array literal or repetition
- the field type of a contextual labelled struct literal
- the complete pointer type of `ptr(integer)` and the complete slice type of
  `[]`; the address integer itself takes `usize`
- the other operand's type, for a binary operator
- a unary operator's own context, handed on [1820]
- a branch's condition and an exit's 'when', both of which
  want a bool [1050] [0970] and so give an integer literal
  a context it cannot take

A call with two or more results has [0990]'s anonymous structural aggregate:
its declaration-order field names and complete field types are its value shape.
That shape supplies an inferred whole binding and every arm of a control value.

And two give none: the inferred form [0050] and a discard [1020], where
[0200]'s i32 is what is left for an integer and D162's f32 for a float.
[0250]'s character literal is different: it already has type `u32`, so a
surrounding context must agree and an inferred binding keeps `u32`.
For [0260]'s text literal, those same direct positions may instead supply a
complete text view. D161 and D164 admit quoted and raw literals as `[]u8`;
D181 admits `utf8`, `utf16` and `cstring`, and with no supplied context either
literal defaults to `utf8`. These identities remain distinct in a generic
actual and in every reference-bearing signature or aggregate field.
For [0210]'s float literal, the same positions supply f32 or f64. There is no
implicit conversion from an integer literal or integer value; with no context
the float defaults to f32. The decimal spelling rounds once to the contextual
IEEE format. A finite spelling that would round to infinity is L0300 rather
than silently becoming [0240]'s named special value.
The named values `f32.infinity`, `f64.infinity`, `f32.nan` and `f64.nan` have
the type written before the dot rather than taking one from context. D167
chooses one canonical quiet NaN pattern for each width; unary minus changes
only its sign bit, as it does for infinity.
With no surrounding context, the first written answer of a control expression
supplies its scalar type, fixed-array element and extent, or nominal aggregate
body; every other answer must have that same complete shape. An edge that
returns without an answer is not a second answer and does not participate in
inference.
A context reaches inward through [1820]'s arithmetic,
bitwise, shift and unary levels and stops at a comparison
and at the logical words. What those give back is a bool
[1890] and a bool says nothing about what was compared, so
'r: bool = 1 | 2 == 3' compares two i32 by [0200] and not
two bools.
Reference agreement includes the complete referred type and shallow
permission. [0440] is the sole relaxation: `ptr mut T` satisfies `ptr T`, and
`[]mut T` satisfies `[]T`; neither direction changes bits, and the reverse is
refused. Function signature agreement also includes parameter conventions,
`escaping`, and each result's ordered `from` positions; omitted and explicit
`in` have the same semantic convention.
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
| --- | --- |
| `+` `-` `*` `/` | one integer or float type, and that type back [0290] |
| `%`, and [0300]'s `+%` `-%` `*%` | one integer type, and that type back [0290] |
| `&` `^` `\|`, and the unary `~` | one integer type, and that type back [0330] |
| `<<` `>>` | an integer shifted by an integer of that same type, and that type back [0320]. The amount is not bounded by the width: [0320] fills with zeros beyond it for any amount. |
| `==` `<>` `<` `<=` `>` `>=` | one type on both sides, and a bool back [0350]; atom sets have identity equality and inequality only |
| `and` `or` `not` | bool, and a bool back [0340] |
| unary `-` | one integer or float type, and that type back |

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
| --- | --- |
| a mutable binding [0060] | may be |
| a named return | may be: [0930] says it must be, and [1840] declares it as a place for that reason |
| an immutable binding | may not: [0040] makes it immutable and [0450] says it protects the value it holds |
| an `in` or `sink` parameter | may not be replaced |
| an `inout` parameter | may be replaced, through the caller-owned place |

An atom declaration and a recovery clause's error name are immutable values,
not places. A function declaration is not a place. A local or module binding holding a
function value is an ordinary place: an immutable one may be called but not
replaced, and a mutable one may be replaced only by a value with the same
complete signature. A named function-valued return is a writable place; an
unmarked function-valued parameter is not. A function-valued struct field is an
ordinary subobject place: the root binding decides mutability, and replacement
requires that field's complete recursive signature. A place reached through
`.val` or slice indexing instead takes writability from the shallow `mut` in
that reference type, independently of the binding that holds it [0430] [0450].
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
at every `return`, and where a body ends, each applicable name has to
have been assigned by every path that arrives there. For multiple results the
question is asked independently of every named return. Aggregate fields retain
independent facts, including a function field read as the callee of a call; the
callee expression is checked before any argument expression.
No condition is believed. A name assigned in one arm of an
'if' and not in another is not assigned after it, and 'if
true then r = 1 end if' leaves r unassigned, because a
checker that read the condition to decide this would be
running the program in order to check it.
'return when' is a return [1810], so what the function hands
back is assigned above it and not below.
A control-flow edge has independent fallthrough, successful-return, and
failure consequences. A `fail` edge never needs the successful named return;
its untaken guarded edge continues. A tried call may fail after its arguments
and before any later action; a recovered call joins its success edge only with
recovery edges that fall through.
A return-compatible control-flow edge has two facts: whether it can fall
through and whether it can return. Only fallthrough states meet at an `if` or `match` join;
a returned arm neither lends nor removes assignment facts on a surviving arm.
Every reachable fallthrough edge of a control expression must reach its block's
final expression, and every such expression has the one complete type and shape
from [1880]. An early-return edge needs no joined value, but it still requires
the named return to be assigned at that edge. A guarded return has both facts:
its taken edge returns and its untaken edge continues with the incoming
assignment state. The unevaluated side of `and` or `or` is likewise a
fallthrough edge: a return from the right operand cannot erase that skip edge,
and assignments made only on the right do not survive their join.
A place passed to `sink` becomes unassigned at that exact binding-rooted path.
Every read requires a later assignment on every arriving path, and a part sunk
out of an `inout` parameter must be assigned again on every return edge [0910].
This is definite assignment of one consumed place, not ownership; copies made
before the sink remain live.

The reference-origin walk is a second local flow fact. `addr` of local storage
and a slice of a by-value array parameter have frame origin. A returned value
with frame origin is refused. A retained `escaping` argument must be independent
or derive only from parameters themselves declared `escaping`. Integer-created
pointers are explicitly untracked [0470]. For a tracked returned reference, the
set of parameter origins on every return edge is exactly the signature's `from`
set. A live local view records the binding it derives from; an `inout` or `sink`
use of that binding is refused when the view is read before being replaced.
Volatile reference paths remain exempt [0850].

A module binding is not ordinary pre-use definite assignment. [1460] says its
value is known when the compiler reads it; reference-containing module images
must likewise supply a valid non-null static image.

### [1920] What a call means

What a call means.
[0980] gives no parameter a default value, so a call names every runtime
parameter exactly once. A positional prefix fills runtime parameters in order;
a named suffix may write the remaining parameters in any order, but may not
repeat one or name one the callable signature does not have. Matching uses the
labels of the static callable signature for a stored or selected function value.
Those labels are retained call-shape facts but remain excluded from [1000]'s
structural function-type identity. Each runtime argument is synthesized and
checked in written order, then its checked value is placed at the matched formal
position for the ABI. A static-role label is not a runtime argument of a
nongeneric or indirect callable. Each argument has its parameter's type [0310],
and the call has the type of the named return.
A call of a function returning none has no successful-result type. It is a
statement [1810] and nothing else: nothing binds it, no argument is one, and
[1930] cannot discard it, because there is no result there to discard. A call
with one named return has that return's type. A call with two or more has
[0990]'s anonymous structural aggregate; its fields are selected and
destructured by the return names. The orthogonal declared error outcome is
unchanged at every result count: a failing call is still tried or recovered.
A callee is a function. It may be a declared function; a local, module,
parameter or named-return binding; or a selected ordinary or variant-payload
struct field whose value has a function type. The complete callee expression is
evaluated before the arguments, and every stored form calls the runtime code
address. A function's own name and an anonymous
function away from a call are values of their function types [1000] [1010].
All positions retain one complete structural signature, recursively when a
parameter or result is itself a function. Labels are not part of function
signature agreement: parameter order and type, plus the ordered result types,
are. The labels do remain the field names of a multiple-result value at its
static call site. A binding of any other type is not a function.

A whole multiple result may initialize an inferred local, be selected by field,
be assigned to a mutable inferred local of the same named structural shape, or
cross a control-expression join. A destructuring binding evaluates its source
once and selects fields by return name in any written order. A bare name binds a
local of the same name; `field: local` renames it; `field: _` ignores that field;
and one bare `_` explicitly ignores every unbound field. Unmentioned fields are
also ignored, as [0990]'s one-field example requires. An unknown or repeated
field and two locals with one name are refused by the ordinary field and scope
rules. The anonymous shape is not a nominal struct type and has no type spelling
of its own.
A scalar type name in front of `(` remains [0700]'s explicit conversion.
The enabled reference slice admits the two directions [0470] requires: an
integer type applied to a pointer checks that the address fits, and
`ptr(integer)` takes its complete pointer type from context and produces an
untracked pointer. D168 also admits an enabled integer type applied to an
integer value. D169 admits f32 or f64 applied to a float value. Conversion
from an enabled integer to f32 or f64 is admitted by D170. D171 admits an
enabled integer type applied to a float value, and D172 admits an enabled
integer type applied to bool. D173 admits bool applied to an integer value.
D174 admits bool applied to a float value, and D176 admits f32 or f64 applied
to bool. The deferred integer widths remain refused by [1830].

### [1930] What may be discarded

What may be discarded.
[1020] says a result is discarded on purpose or not at all,
and [1810] writes that '_' '=' expression. Anything with a
type may be thrown away, including a value nobody computed
for the purpose: '_ = 1 + 2' is a discard of an i32 by
[0200], because a rule about wasted work is a rule about
people and this one is about types.
What may not is a call of a function returning none [1920]. Discarding is for
a result, and that call has none. A call with a declared error is also refused
when a discard would ignore that outcome; `try` propagates it and call-site
`else` handles it explicitly.

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
An integer operator in a module value is folded, and a fold no type
holds is refused. [0300]'s trap has nowhere to happen here:
[1460] says nothing runs before the entry point, so a module
value that overflows has no moment in which to trap and no
value to stand for it. Inside a body the same expression
traps [0300] and is not this, which is the one place the two
readings of one sum come apart.
D162's first float increment admitted a decimal float literal, its unary minus,
`zeroed`, or D167's named infinity and NaN as a module scalar or
aggregate-field image. D175 admits `+`, `-`, `*`, `/` and comparisons over
module-known f32 and f64 values, including scalar and aggregate images. The
target-neutral folder evaluates IEEE carrier bits with bounded integer work;
it does not use the compiler host's floating-point operations as language
semantics.
[0130] makes a module a set, so one module value may name
another written below it. A chain of them that comes back to
where it began names nothing at all: no member of it is
first, exactly as [1850] found with two declarations of one
name. So it is refused, and the report names the declaration
the chain came back to, because that is the one place in it
the reader is standing.
A declared or anonymous function is a compile-time-known code address. A module
function binding may name either directly, or another module function binding
whose static chain reaches one; a chain that returns to itself is refused like
any other module-value cycle. Function code addresses have no all-zero value,
so a function-valued module binding must write an initializer. A function field
in a static struct or selected variant image is a target-neutral relocation to
such a declared or anonymous routine, not an integer fold. Copying a complete
module struct image copies that relocation while retaining distinct storage.
A module aggregate whose active all-zero shape contains a function field must
therefore write an explicit static image too.

A contextual text literal is also known. A `[]u8`, `utf8` or `utf16` module
image is the base of its read-only datum and its decoded code-unit length; a
`cstring` image is the base relocation alone. Each datum has exactly one
trailing zero element excluded from a slice length. It is an address
relocation rather than an integer fold or code run before the entry point.

An atom-valued module binding must name an initializer. There is no zero atom,
and the zero carrier pattern reserved by [1980] is not a source value.

A scalar binding with no value is known too, and what it holds is
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
| --- | --- |
| integer `/` `%` | a divisor of zero [0290] |
| `<<` `>>` | a negative amount [0320] |
| `[ ]` | an index outside the length [0520] |

The third is not a binary operator and belongs here anyway,
because it is the same question with the same answer. [1720]
says this language checks bounds and [0580] says indexing
checks the length before it computes an address, so what was
left unsaid is only which of refusing and trapping applies
where — and that is what the rest of this paragraph already
decides for the other two.
Float division follows IEEE 754: division by signed zero produces an infinity
or NaN and does not use this refusal or trap rule.
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
The same no-continuation rule applies to a `return` nested in an expression.
For example, an index expression runs before the selected element is read and,
on the left of an assignment, before its right-hand expression [0410]. If that
index returns, neither later action occurs; facts from that edge do not reach a
join.
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
use this rule; its build description names the entry [1650]. The first hosted
entry is infallible: this boundary has no host mapping for a declared Landin
error.
In a rooted R3.10 program, only a declaration in the designated entry module
can satisfy this shape. A reachable imported module's `public main` is an
ordinary public function and is never selected as the executable entry.

### [1975] The first foreign boundary imports fixed scalar C routines

`extern(c) name: declared_signature` declares a C routine supplied by the
linked host and has no Landin body. R3.50 admits no generic form, no declared
error set, only `in` scalar or pointer parameters, and at most one scalar or
pointer result. Pointer permission remains part of the Landin signature. The
general C ABI matrix—aggregates, unions, bitfields, variadic calls, callbacks,
thread-local state, foreign ownership and generated bindings—belongs to R4.40.

On the first Linux x86-64 hosted path, the executable's selected no-argument
Landin entry captures the incoming C `argc` and `argv` before its body runs.
The repository-owned runtime bridge exposes user arguments (excluding
`argv[0]`) and fixed wrappers for `strlen`, read-only `open`, `read`, `write`,
`close`, and `errno`; those wrappers call libc. This is a compiler/runtime ABI
used by `core/io`, not a set of privileged language operations. `core/io`
turns descriptors and argument views into ordinary values, maps foreseeable
host failures onto declared atoms, and threads its `world(provider)` concept
as the authority for opening files and touching streams [1660] [1680]. Direct
Linux syscalls are not part of this route.

### [1980] Declared errors are an orthogonal payload-free atom outcome

A function is infallible when its signature has no `!`. A concrete `!` names a
nonempty atom set; that set is part of complete structural function-type
identity, recursively when a function value occurs in another signature. A
public declaration, anonymous function, and written function type must be
concrete. A private declared routine may write `! ...`; whole-module checking
then takes the least fixed point containing every atom it fails with and every
concrete or inferred set propagated by `try`. Mutually recursive private
routines are solved together. An inferred empty set makes the routine
infallible.

`fail atom` leaves by the error outcome and carries no successful result. The
atom's possible set must be a subset of the routine's finalized declared set.
A fail path need not assign the named successful returns. `when` evaluates its
condition first; only the taken edge evaluates the atom and fails. `try call`
evaluates the call once and propagates its error unchanged; its success value,
including a function, fixed array, nominal aggregate or anonymous
multiple-result aggregate, has the ordinary call shape. A failing call written
without `try` or call-site `else` is refused.

Call-site `else` handles only a nonempty declared error set. Its optional name
is an immutable atom value scoped to the recovery block and typed as that
complete set. The successful call edge and every recovery edge that falls
through must supply the same complete scalar, atom, function, array, nominal
aggregate or anonymous multiple-result aggregate shape. A recovery edge may
instead `return` or `fail`; it then
supplies no placeholder and does not participate in the value join. Atom
`match` is exhaustive over the subject's structural set; one final `_` arm may cover
all members not named explicitly, and atom arms bind no payload.

Neutral IR keeps successful results and errors separate. Atom constants carry
source declaration identity and atom-set metadata; slots, datums, signature
parts and values retain that structural set. A call with errors names a
separate error slot, `Failure_Test` branches on the abstract outcome, and
`Fail` is its own terminator. No inferred marker reaches IR. Verification
checks set runs, identity membership, widening stores and arguments, complete
signature equality, call failure slots, and failure subsets before a backend
sees the unit.

For the documented Linux x86-64 internal convention, ordinary atom values use
a 32-bit carrier. The backend assigns dense nonzero codes in declaration-
identity order. They use the ordinary integer argument positions and `%eax`
for a successful atom result. `%r10d` is the dedicated failure carrier for
both direct and indirect Landin calls: zero means success and a nonzero dense
atom code means failure. A successful callee clears `%r10d`; `fail` writes it.
The ordinary scalar or function result remains in `%rax`, and an aggregate
success still uses caller-owned storage, so the error carrier consumes no
source parameter, result position, or stack argument. No source atom has code
zero.

## THE DECISIONS THIS DOCUMENT TOOK

A rule above is one of two things, and a reader cannot tell them apart by
reading it: a transcription of something `tour.md` already decided, or a
decision taken because the tour said nothing and an implementation could not
proceed without one. The decisions are listed here with what
the tour said before, what was chosen, and what a competent reader could
have chosen instead — because a decision written in the same voice as a
transcription looks like it was always there, and [1050] was missed twice by
a reader who assumed exactly that.

A decision leaves this register only when new evidence closes it: a program
that cannot be written, a target that cannot be reached, or a paragraph of the
tour that turns out to have settled it after all. Completed implementation
does not remove a decision, because its alternative and fixture remain useful
review evidence. The completed roadmap item records the delivered vertical
slice; this register does not repeat its implementation diary.

The register is chronological, but its completed R2.20 decisions fall into
four reading groups: D15--D16 establish declared types and field assignment;
D17--D43 establish fixed arrays and contextual storage; D44--D72 plus
D86--D87 establish ordinary aggregates; and D73--D85 establish variants.
Individual headings remain stable citation targets.

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
declined above is calling a runtime routine _instead of_ [1670]'s, not
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
measurement has, and [0200]'s default is about an integer _literal_ rather
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
that its size is part of its type [0520]. It says what an array _is_ and
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
this rule and not an exception to it. D122 supplies the aggregate element
carrier, D127 its known whole-element contexts, and D134 the computed ones;
the earlier R2.20 layout evidence did not pretend its scalar-only array shape
represented them.

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

A branch merge intersects what the facts _mean_, not merely how they happen to
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
outside this slice. In particular, this literal rule still requires one
expression; D136 later accepts the zero-length type `[0]T` without adding empty
literal syntax.

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
still excludes an empty literal; D136 later accepts the zero-length type
`[0]T` independently.

The [1820] operators [1940] admits over literals are folded during
checking and again when lowering records the verified image: [0290]'s
arithmetic, [0300]'s wrapping forms at the operand type's own width so
`u8 = 255 +% 1` is zero and every unsigned or signed size wraps the same
way, [0320]'s shifts, [0330]'s bitwise set, [0340]'s logical words with
short-circuiting, [0350]'s comparisons and [0370]'s measurements. Both
walks take their widths from Landin.Types.Width against the compilation's
target facts; the backend separately folds verified numeric scalar IR, while
D177 records a bool datum directly from this same static-image walk so logical
CFG cannot reach datum emission. Thus a shift past the width gives zero at
exactly the width [0320] promises and a bitwise `not` occupies the same bytes
the backend emits. The positive operator corpus and the negative fold agreement
fixtures pin that checking settles every value or invalid operand before
lowering is allowed to record an image. A member selection [0420], an array element
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
deferred. Empty literal syntax remains deferred. D136 later accepts `[0]T`
source legality independently of that syntax.

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

A written zero count remains refused in this inference position because the
repetition supplies no element-bearing source run. D136 later accepts an
explicit zero-length fixed-array type; that does not make repetition an empty
array literal or give an inferred zero-count repetition an element type. A
count-less inferred initializer, module initializer, mixed-prefix repetition,
argument, return, discard, nested repetition and other general array value
remain outside this slice.

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
repetition. This is a construct-specific nonzero requirement. D136 later
accepts `[0]T` as source, while repetition over that zero contextual extent
remains refused. D33's zero-count inferred refusal remains for the same reason.
An inferred module initializer remained outside this slice until D35. A
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
at the array's target alignment. D17's zero-element shape contributes size zero
and alignment one here as everywhere else; D136 later accepts source spelling
`[0]T`.

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
were declined. Refusing a zero-length field specially was also declined: D17
already defines the shape, and D136 later accepts source `[0]T` uniformly rather
than making a D45 exception.

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
outside D45 and therefore outside this decision. D17's zero-length field rule
is unchanged; D136 later accepts source `[0]T` uniformly.

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
measurement and D46 module storage. D17's zero-element shape therefore
contributes size zero and alignment one here too; D136 later accepts source
`[0]T`. Scalar field operations use the resulting offset.
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
A zero-length field is vacuously complete, preserving D17; D136 later accepts
source `[0]T`.

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
arriving path has it. A zero-length field is vacuously complete and clears zero
bytes, preserving D17; D136 later accepts source `[0]T`.

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
facts also suffice when they cover the declared length. A zero-length field is
vacuously complete. Self-copy follows the same rule and therefore
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
D19/D48's sparse facts also suffice when they cover the declared length. A
zero-length field is vacuously complete. The fresh local is completely
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
mixed prefix must satisfy `1 <= k < N`. Consequently neither form admits a
zero-length field under D32/D37's construct-specific nonzero contextual rules.
The root must be mutable; L0303 owns an immutable root first and alone.

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
fact exists or its D48 sparse element facts cover the declared length. A
zero-length field is vacuously complete. The first incomplete field owns D16's
L0302 and is named in the report. Self-copy follows the same read rule, so it cannot turn an
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
fact or complete D48 sparse facts. A zero-length field is vacuously complete.
The first incomplete field reports D16's L0302. Two distinct, same-shaped struct
declarations remain nominally different and report L0301 at
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
zero-length shape; a written finite literal remains nonempty, so it cannot
initialize that shape.

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
other general expression position remained L0304 at this increment. D100--D105
later admit construction in the aggregate argument contexts, and D106--D116
close aggregate results. Construction does not enable [0700]'s
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

### D73 — A contextual variant part is refused once as a whole

**The tour said** that an ordinary struct may contain one contextual
`name: variant` part [0680], whose cases may be bare atoms or carry labelled
payload fields [0690]. The enabled grammar [1795] still describes only an
ordinary `field ::= identifier ":" type`, so the old parser read `variant` as
a user type and then reported unrelated errors on the first case and the two
closers.

**Chosen:** while reading an ordinary struct body, the parser recognizes the
shape of [0680]'s contextual part, reports one L0010 at the part name, and
skips through that part's own `end name` closer. Parsing then resumes in the
containing struct, so a common field following the refused part and the outer
`end struct-name` remain independently readable. Payload and bare cases, and
an empty part written directly as `end name`, have the same single owner. A
refused part counts as the field-like content that caused the declaration to
be refused, so the recovery does not add the ordinary empty-struct report.
If the part's closer is absent or misspelled, recovery falls back to the
containing struct's closer rather than discarding later declarations.

`variant` remains an ordinary identifier rather than a reserved word. In this
slice the
lookahead therefore requires the following tokens to have a case or the
part's matching closer shape; `kind: variant` followed by another ordinary
field continues to mean that `kind` has the user-declared type named
`variant`. D73 left the grammar unchanged and its parser-owned fixture
underivable, as every parser-owned refusal requires.

No variant node, name scope, case identity, layout, value, image, IR operation,
verifier rule or backend representation was introduced by D73. Later slices use
executable evidence to decide duplicate cases, payload type checking, empty
and single-case legality, tag width and position, payload-union alignment and
padding, the zero image, construction and matching, and whether any spare bit
may fold the tag. Until D74, the whole part was absent from the syntax tree and
the containing type was rejected by its one owning report.

**Why refuse before representing:** accepting a declaration without a layout
would create a legal but unusable type whose later consumers either fail
silently or invent a diagnostic at every use. Defining layout immediately
would instead decide tag and payload representation from measurement alone,
before any value can prove it. Naming the complete omitted construct gives
the parser stable recovery evidence without committing either mistake.

**The alternatives:** accept declaration-only variants, implement declaration
and layout together, reserve `variant`, or postpone all variant evidence. The
first has no owning report for the missing layout; the second crosses every
representation layer in one unmeasured step; the third breaks the tour's
contextual spelling and user types of that name; and the last leaves R2.20's
variant work with only accidental cascades. All were declined.

**Pinned by** the parser public-seam recovery cases and the corpus truncation
sweep. D74 migrates the parser refusal into enabled declaration syntax and
replaces its former negative fixture with layout and boundary evidence.

### D74 — A variant declaration has one unfolded measurable layout

**The tour said** that an ordinary struct may contain a contextual variant
part [0680], that each case is an atom and may carry a labelled payload
[0690], and that the tag and the fields of one selected payload occupy the
same value [0740]. It did not say where the tag sits, how wide it is, how
payloads share storage, how their padding contributes to the containing
struct, or whether a declaration may exist before values of it do.

**Chosen:** [1795]'s enabled grammar includes a `variant_part` as one member of
an ordinary struct body. The parser keeps one `Variant_Part` node containing
its source-order `Variant_Case` run; each case keeps a source-order run of the
same scalar or fixed-array `Field` nodes an ordinary struct already uses. A
part needs at least one case. A single case and an all-bare part are legal.
The contextual word `variant` remains an ordinary identifier everywhere the
case/closer lookahead does not prove this production, and the name after the
part's `end` must repeat the part name.

Case names are declarations in the module scope. They may be used before the
type that contains them, and resolution binds a use to their declaration
identity. Two cases with the same name, cases in different variant parts with
the same name, and a case colliding with an ordinary module declaration are
therefore [1850]'s L0200, with the declaration encountered by the module's
set-building pass as the deterministic owner. The part name and payload field
names remain labels rather than declarations.

The representation is target-neutral and unfolded. A part is one field of its
containing struct. Its tag is first and uses the smallest enabled unsigned
scalar that can enumerate every case: `u8` through 256 cases, `u16` through
65,536, and `u32` beyond. Cases are numbered in source order; D74 does not yet
expose those numbers as values. Each payload is laid out independently by
D44/D45's ordinary source-order, natural-alignment rule. The payload begins at
the tag extent rounded up to the greatest payload alignment; its reserved
extent is the greatest padded payload size. The part's alignment is the
greater of tag and payload alignment, and its padded size is the tag, the
alignment gap, the maximum payload extent and ordinary tail padding. An
all-bare part is therefore only its tag. The containing struct places that
complete part exactly as it places one scalar or fixed-array field.

The checking table carries this without offsets in the source-neutral shape:
a `Variant_Field` names the tag, case count and a contiguous run of per-case
payload slices; those slices contain only scalar or fixed-array shapes.
Offsets, widths and padding are derived from the selected target facts. The
top-level field-shape run and field-offset run have separate starts, because
payload shapes share the shape vector but have no top-level offsets. An
aggregate payload field remains the existing L0304 struct-of-struct boundary;
if any payload leaf is refused, the containing declaration has no layout and
later consumers add no cascade.

`sizeof` and `alignof` are executable evidence for this rule. Lowering copies
the same neutral tag, case runs and payload shapes into the IR's aggregate
measurement run. The verifier checks the tag, nonempty and in-range case runs,
and scalar/fixed-array-only payloads before any payload accessor. The backend
replays the layout rule against its target facts. D74 does not put that carrier
in a datum or slot; D75 reuses it there without changing the layout.

A binding, parameter, named return, initializer, assignment, `zeroed`, copy,
literal or construction that would create storage or a value of a
variant-bearing struct was one L0304 at this boundary. D102/D103 later admit
its aggregate argument contexts and D106--D116 its results; other sites used
D74's `Variant_Value` refusal at [0680]. A case name used as a general value or construction callee
has the same owner. D75 supplies storage and the zero image, D76 then
admits contextual case construction without creating a general variant
value, and D77 reads its tag through an exhaustive match.

**Why unfolded, tag-first layout now:** it gives both described targets one
deterministic hexdump-compatible answer, preserves [0540]'s later opportunity
for an all-zero image, and makes measurement evidence possible without
pretending a variant value already exists. Spare-bit folding, tag-last
placement, C-union layout and a target-sized tag were declined: each either
hides the source-order identity, changes the zero image, or lets host/ABI
policy choose a language layout. A future explicit layout policy may add a
different representation without changing this default.

**The alternatives:** keep the D73 refusal, accept declarations with no
layout, enable storage and construction together, or choose a target byte
blob. The first leaves the title feature without evidence; the second creates
a legal type every consumer must refuse afresh; the third crosses layout,
images and values in one slice; and the last violates the target-neutral IR
boundary. All were declined.

**Pinned by** the parser, resolution, lowering, verifier and target-layout
public seams; `positive/variant-part-measured`;
`negative/variant-part-empty`; `negative/variant-case-duplicate`;
`positive/variant-inside-an-element`;
`negative/variant-case-value-not-enabled`;
`negative/variant-return-unassigned`; the generated construct, token, IR and
target-layout records; the backend seam against both target descriptions; and
`runtime/variant-part-measurements-answer-for-the-target` on Linux x86-64.

### D75 — A variant-bearing struct has storage and one zero image

**The tour said** that [0540]'s `zeroed` writes the all-bits-zero image of a
type and that [0740]'s variant value contains one tag and one selected payload.
D74 fixed their unfolded layout but deliberately created no datum or frame
cell, and did not say which tag the zero image selects.

**Chosen:** a named ordinary struct with a D74 variant part may be declared as
module or local storage. A declaration-only module binding has D10's static
zero image; a declaration-only local binding is one uninitialized aggregate
frame cell. An explicitly typed module or local initializer may be `zeroed`,
and a directly named mutable module or local place may be assigned `zeroed`.
These are the only new value contexts. The tag value zero selects the first
case in source order. Every payload leaf D74 admits is a scalar or fixed array
of scalars and therefore has [0540]'s zero image, so zeroing the tag, maximum
payload extent, common fields and every padding byte is one valid complete
image. A future payload leaf without a zero image must make this contextual
form fail rather than change what zero means.

Common scalar and fixed-array fields retain their existing field rules. A
whole successful zero write establishes D16's scalar and D48's whole-array
facts for those common fields; D77 gives the established variant part one tag
fact, and D78 may expose the selected case's scalar payload through arm-local
aliases. A
selection of the part itself is one L0304 `Variant_Value` when read. D76
admits the directly selected mutable part as one contextual case destination;
D79 admits inferred local construction, and D80 admits a contextual whole
copy between runtime storage places. Static module copy chains, inferred
module construction, arguments, returns and every general aggregate value
remained refused at this increment. D102/D103 later admit parameters and
D106--D116 named results. D77 owns tag matching and D78 scalar payload
bindings.

The IR uses the same target-neutral `Variant_Field_Shape` for measurement,
datum and aggregate-slot field runs. One unit-wide case-run and payload-shape
carrier lets each top-level shape name its source-order cases without storing
an offset, width or padding byte. The verifier proves the tag kind, case-run
bounds and depth-one scalar/fixed-array payload leaves before any accessor for
all three storage classes. A variant-bearing aggregate may have no written
static image in this slice: omitted and explicit module zero images are the
same absent image, while a malformed written image is refused before the
backend can interpret it.

Lowering emits no variant instruction. Module storage is one ordinary
aggregate datum; local storage is one aggregate slot. Explicit local zero
initialization and whole zero assignment reuse D57/D58's operandless,
field-zero `Clear_Array`, which clears the complete padded aggregate extent.
The x86-64 backend derives that extent by replaying D74's tag-first maximum-
payload layout against the selected target. Module zero storage is reserved as
one distinct padded object in `.bss`; no startup instruction exists. The same
recursive extent routine serves measurement, datum placement, frame layout and
whole clear, so their answers cannot diverge between 32- and 64-bit target
facts.

**Why only storage and zero now:** the all-zero image needs no payload
expression, no tag operation and no aggregate temporary, so it exercises the
runtime carrier and target layout without prejudging how a case is formed or
examined. Field-wise stores were declined because they leave padding outside
[0540]'s complete image; a new clear opcode duplicates D57's whole-storage
operation; admitting copy or construction would cross D76's case-selection
rule; and keeping the variant as opaque target bytes would abandon D74's
target-neutral carrier. All were declined.

**Pinned by** the lowering, verifier and backend public seams;
`positive/variant-zeroed-storage`;
`negative/variant-part-selection-not-enabled`; the generated token and IR
records; and `runtime/variant-zeroed-storage-is-distinct` on Linux x86-64.

### D76 — A variant case is constructed into contextual storage

**The tour said** that [0690]'s bare case carries no payload and [0700]'s
labelled construction supplies a payload by name. D74 fixed the case order
and payload shapes, while D75 supplied storage and made tag zero select the
first case; neither said how a later case is written.

**Chosen:** a case is written only where a destination supplies one D74
variant part. A typed local labelled literal or nominal construction may name
a variant field with a bare payload-free case or with `case(field: value,
...)`; a complete labelled literal or nominal construction may be assigned to
a directly named mutable module or local struct in the same way. A directly
selected variant part of such a mutable root may also be assigned either
form. The case identity must belong to that exact part. A case from another
part is L0301 at the value; an immutable root keeps L0303 first and alone.
Module static struct images and inferred module construction remain outside
this slice until D81; every general value position remains an L0304
`Variant_Value` boundary. D80 later admits a whole variant-bearing copy whose
source and destination are direct runtime storage places.

A bare case is legal only when its payload is empty. A labelled case
construction gives each payload field at most once, using D64's L0308/L0309/
L0310 ownership for unknown, duplicate and missing labels. Scalar payload
fields accept their ordinary expression or contextual `zeroed`. A fixed-array
payload field accepts only `zeroed` in this slice; selecting the case already
clears that array's complete storage. A trailing `of zeroed` supplies every
omitted payload field, while any other fill is L0304. Aggregate payloads stay
D74's depth-one refusal.

The destination case is selected before any payload expression is evaluated.
Selection clears the variant part's complete padded target extent, writes the
case's zero-based source-order tag, and thereby gives omitted and fixed-array
payload fields their zero image. Labelled scalar expressions are then
evaluated exactly once in written order and stored immediately, so a later
expression observes every earlier program write. A refused destination reads
none of them. D16 records the complete selected part as assigned; D77 is the
first consumer of that tag and D78 reads or mutates scalar payload leaves.

The IR adds two destination-only operations. `Select_Variant` carries a
storage identity, top-level field identity and one-based case identity;
`Store_Variant_Field` additionally carries a one-based scalar payload-field
identity and one scalar operand. None carries a target offset. The verifier
checks storage, aggregate field, variant shape, case run, payload field kind
and operand type in that order with explicit release-build code, and refuses
either operation inside a datum initializer. The backend replays D74's layout:
selection clears the target-derived part extent and writes `case - 1` with the
shape's tag width; a payload store derives the part, payload and field offsets
for the selected target before storing at the scalar width.

**Why contextual construction first:** it exercises every case identity and
payload offset without an aggregate temporary, a static nonzero variant image
or an ABI rule. A field-wise clear was declined because it would leave union
padding outside the selected value's zero image. Whole copying waited until
D80 fixed the source and destination as storage identities and copied the
complete padded part. D84 later adds D52/D53's write sequence inside a
fixed-array payload without changing selection's clear-and-tag operation. D77
adds tag matching; D78 adds scalar payload binding while retaining that
fixed-array boundary. D79 also lets a call-shaped case construction infer a
fresh local binding; D81 later supplies the nonzero static variant image and
admits module inference.

**Pinned by** the IR, lowering, verifier and backend public seams;
`positive/variant-case-construction`;
`negative/immutable-variant-case-assignment`;
`negative/variant-case-does-not-belong`;
`negative/variant-case-payload-disagrees`; the generated token and IR records; and
`runtime/variant-case-construction-runs-in-source-order` on Linux x86-64.

### D77 — A match exhaustively selects one variant case by its tag

**The tour said** that [1210] distinguishes every case of a variant and that
missing cases are compile errors. D74 fixed the source-order case identity,
D75 supplied the unfolded tag, and D76 made that tag executable by selecting
cases; none supplied a way to examine it.

**Chosen:** `match place.field` directly selects a D74 variant part from a
named module or local ordinary-struct binding. Each arm is `case: statement`;
the case must belong to that exact part, every case is named exactly once, and
source order of arms is otherwise free. A duplicate is L0311, a missing case
is L0312, and a case from another part is D76's L0301 identity mismatch. This
first boundary gives each arm exactly one statement, with an `if` usable as
that statement when a nested run is needed. D78 adds [1220]'s parenthesized
payload bindings. Wildcards, scalar or nested subjects and general variant
values remain refused.

The subject is read once before any arm. Definite assignment therefore asks
for the selected part's established-case fact on entry; D75's whole zero image
and D76's contextual case write establish it. Each exhaustive arm receives
the same incoming state, and facts after the match are their intersection. An
uninitialized local part is L0302, and a fact written by only some arms is not
available after the match. Payload bytes are neither read nor bound here.

Lowering emits one `Load_Variant_Tag`, carrying source storage, top-level
field identity and the tag's scalar type but no target offset. The tag is
saved in one scalar frame slot, then compared with each source-order tag
except the final exhaustive arm; control flows through sibling arm blocks and
one merge. The verifier proves the storage and variant field before comparing
the result type with the shape's tag type, in explicit release-build code.
The backend replays D74's field placement, loads the tag at its described
width, and uses the existing scalar comparisons and branches. No payload
offset is computed.

**Why tag-only and exhaustive first:** it closes the first read of D76's
runtime state without yet introducing a payload reference, origin, lifetime,
or aggregate temporary. A wildcard was declined because [1210] already makes
missing cases a compile error; implicit source-order fallthrough was declined
because case identity is nominal; reloading the aggregate at each comparison
was declined because [0410] gives the subject one evaluation.

**Pinned by** the parser, IR, lowering, verifier and backend public seams;
`positive/variant-match-exhaustive`;
`negative/match-scalar-not-enabled`;
`negative/variant-match-duplicate`;
`negative/variant-match-not-exhaustive`;
`negative/variant-match-case-does-not-belong`;
`negative/variant-match-unassigned`;
`negative/variant-match-not-on-every-path`; the generated token,
diagnostic and IR records; and `runtime/variant-match-selects-tag` on Linux
x86-64.

### D78 — Match-arm names alias scalar payload fields

**The tour said** that [1220] binds a selected case's payload by position and
that `inout` is the spelling which permits a write. D77 selected the case and
entered an arm, but deliberately left its payload bytes inaccessible.

**Chosen:** an arm may write a parenthesized, comma-separated binding after
its case name. The names correspond positionally to every payload field in
declaration order; when parentheses are present their count must match exactly
(L0301), while omitting parentheses continues to ignore the complete payload.
A plain binding is an immutable `in` alias and `inout name` is mutable. Both
refer directly to the matched object: reading loads that payload field, and an
`inout` assignment updates it in place. Each binding is visible only in its
arm's sibling scope. Duplicate names retain L0200 and a use outside the arm
retains L0201.

This slice binds scalar payload fields. D85 later binds a fixed-array payload
as an indexed array alias without making it a whole contextual value. Omitting
bindings still permits a case with any payload, so D77's tag-only matching
remains unchanged. D102--D116 later close aggregate parameters and returns.

Lowering records no copied local. It maps each arm-local declaration identity
to the subject storage, top-level variant field, source-order case and
declaration-order payload field. `Load_Variant_Field` carries those identities
and its scalar result; an `inout` write reuses D76's
`Store_Variant_Field`. The verifier proves the aggregate, case and scalar leaf
before checking the result or operand type. The backend replays D74's payload
placement on the selected target. These are explicit release-build checks, and
no source or target byte offset enters the IR.

**Why aliases rather than copied locals:** [1220]'s `inout` makes an arm write
observable after the match. A copy-in/copy-out rule would add hidden completion
and early-return semantics, while a copied immutable binding would make the two
conventions denote different objects. One direct alias rule answers both.
Named rather than positional omission was declined because field identity is
already declaration order; D85 later gives array payloads the same direct
alias rule without silently copying a whole array.

**Pinned by** the parser, IR, lowering and verifier public seams; the resolution
and checking fixture paths; `positive/variant-match-payload-bindings`;
`negative/variant-match-binding-count-disagrees`;
`negative/variant-match-in-binding-is-immutable`;
`negative/variant-match-binding-named-twice`;
`negative/variant-match-binding-outside-arm`; the generated token, diagnostic
and IR records; and `runtime/variant-match-payload-bindings-update-storage` on
Linux x86-64.

### D79 — A case construction may infer its fresh local storage

**The tour said** that [0050] infers a binding from its initializer and that
[0700]'s construction names the nominal type being constructed. D72 applied
that rule to ordinary structs, while D76 kept a variant-bearing construction
contextual to a written destination even after local aggregate slots and case
selection existed.

**Chosen:** `name := T(..., part: case(...), ...)` is admitted inside a
function when `T` is a D74 variant-bearing ordinary struct. The construction's
type name supplies [0710]'s body before inference settles the binding, and the
fresh aggregate frame slot is its contextual destination. D76 then applies
unchanged: common and payload values are evaluated once in written order, the
selected part is cleared, its tag is written, and scalar payload fields are
stored directly. The inferred local is distinct storage and may immediately be
selected or matched under D77/D78.

An inferred module binding remains refused in this slice. Unlike a fresh local
slot, it has no runtime destination: [1460] requires a static image, and D75
currently carries only the absent all-zero variant image. D81 later adds that
representation and admits both the typed and inferred module forms.
Arguments, returns and general aggregate values remain outside this contextual
rule and retain their existing owners.

No syntax, IR, verifier or backend operation changes. Lowering already
allocates an aggregate slot from the inferred declaration's carried body and
D76 already writes a struct literal into that slot. The checker removes only
the local half of its inference refusal; the module half remains explicit.

**Why local inference before static images:** the nominal constructor already
answers which type is inferred, and a fresh slot makes evaluation executable
without an aggregate temporary. Treating the same spelling as a module image
would require a nonzero target-neutral variant image, while refusing both
scopes merely because one lacks that representation would preserve an
accidental asymmetry.

**Pinned by** the lowering public seam;
`positive/variant-case-construction`; the generated token and IR records; and
`runtime/variant-case-construction-runs-in-source-order` on Linux x86-64.

### D80 — A whole variant-bearing struct copies between runtime storage

**The tour said** that [0520] assigns values and [0710] makes an ordinary
struct nominal. D54 copied a scalar/array-bearing struct field by field, while
D75 supplied storage for the unfolded variant part and D76 supplied its first
nonzero values. Keeping D54's copy refusal after both sides had complete
storage was therefore a representation boundary rather than a language rule.

**Chosen:** a whole assignment between directly named mutable module or local
storage of the same variant-bearing struct is admitted. An explicitly typed or
inferred local initializer may likewise copy a direct module or local source
name. The source and destination must share [0710]'s declaration identity;
same-shaped declarations remain L0301. Module initializers remain static-image
rules and are not widened by this runtime slice. A tracked local source must be
complete on every arriving path, including its established variant part; the
destination receives the complete whole-struct fact. An exact self-copy is
legal and changes nothing.

Common scalar fields retain D54's scalar load/store pair and common fixed-array
fields retain its `Copy_Array`. Each unfolded variant part is one
`Copy_Variant` carrying source storage, destination storage and their shared
declaration-order field identity. It carries no tag, case, payload offset,
target extent or bytes. The verifier proves both endpoints are variant fields,
proves their complete case and payload shapes before reading them, and requires
the tag, case count, payload kinds, scalar types and array lengths to agree.
These are explicit release-build checks.

The backend replays D74's tag-first maximum-payload layout for the selected
target, forms both field addresses and copies the complete padded part with one
forward byte run. Distinct aggregate roots do not overlap; a self-copy names
the identical range, which the forward run preserves. Copying the padded part
rather than only the selected payload preserves [0540]'s complete image and
does not need to inspect the source tag. Scalar and fixed-array fields remain
separate operations in declaration order, exactly as D54 specified.

**Why a compact part copy:** selecting the active case and copying only its
payload would branch on runtime state, leave inactive bytes or padding behind,
and make the copy sequence depend on the tag. Copying the whole struct as one
opaque byte operation would duplicate D54's established scalar/array paths and
erase their verifier types. One compact operation for the only union-shaped
field keeps the IR target-neutral and the existing field semantics visible.
Static nonzero variant images and inferred module construction follow in D81.
General aggregate values, arguments and returns remained separate decisions;
D94--D116 later close the internal argument and result contexts.

**Pinned by** the IR, lowering, verifier and backend public seams;
`positive/variant-whole-copy`;
`negative/variant-whole-copy-source-unassigned`; the generated token and IR records; and
`runtime/variant-whole-copy-is-distinct` on Linux x86-64.

### D81 — A module variant construction is a static selected-case image

**The tour said** that a module binding may carry a value [0040], that nothing
runs before the entry point [1460], and that a variant value selects one case
and its payload [0680]--[0700]. D66--D71 gave ordinary structs a target-neutral
static image, while D75 kept a variant part absent and all-zero and D76/D79
constructed nonzero cases only into runtime storage.

**Chosen:** an explicitly typed module struct literal or nominal construction
may select D76's bare or labelled variant case. A call-shaped construction may
also infer the module binding's nominal body, as D79 already does for a local.
Every labelled scalar payload expression must be [1940]-known and must fit its
contextual scalar type on the selected target; excluded storage reads remain
L0304, an unknown fold remains L0305, and an overflowing or out-of-range fold
remains L0300. A fixed-array payload still accepts only `zeroed`. Omitted
payload fields covered by `of zeroed` retain their zero image.

The selected case is a static image, not startup code. The aggregate field's
flat fold stays zero. Its top-level image descriptor has form `Selected`, a
one-based case in `Value`, and an offset/count selecting one declaration-order
payload-descriptor run appended after the aggregate's top-level descriptors.
A scalar payload descriptor carries its folded value; a fixed-array payload
reuses D67/D68's absent/finite/repeated/hybrid shape and element run, although
only the absent zero form is produced in this slice. Offsets select descriptors
or folds, never target bytes. The old setter delegates with an empty payload
run, so every D66--D71 image keeps the same carrier.

The verifier first proves the top-level descriptor run, selected case and
payload run before any payload accessor. It then proves each scalar fold and
array descriptor against that case's D74 leaf shape and the selected target.
Malformed nesting, case identities, counts, offsets, patterns and values are
explicit release-build faults. The backend replays D74's tag-first placement,
writes `case - 1` at the tag width, inserts this target's gaps, writes scalar
payloads at their widths, emits array payload images, and zeroes the inactive
tail of the maximum payload extent. Selecting the first case explicitly is
still a written `.data` image even when every byte is zero; D75's omitted or
whole-`zeroed` value alone remains absent `.bss` storage.

D60/D61 module struct image chains copy the selected descriptor, payload
descriptors and element folds into distinct destination storage. Forward
references and cycles keep their existing declaration-identity validation;
a cycle reports L0305 once. Later runtime writes never alias a copied image.
General aggregate values, arguments and returns remained refused at this
increment. D94--D116 later close the internal argument and result contexts.
D82 adds finite and repeated fixed-array
payload images, D83 copies those images from module array storage, D84 adds
their contextual runtime write forms, and D85 adds indexed match aliases.

**Why one extended descriptor run:** target bytes would duplicate the image per
target and abandon the IR boundary; startup stores would contradict [1460]; a
second item-owned vector would introduce another partition invariant for data
the existing field-image run already orders. One selected descriptor plus a
contiguous payload run makes the case explicit, keeps every width and offset in
the backend, and lets D60's existing image-chain machinery copy the complete
value without inspecting target layout.

**Pinned by** the lowering, verifier and backend public seams;
`positive/variant-module-case-image`;
`negative/variant-module-case-image-value-not-known`;
`negative/variant-module-case-image-storage-read`;
`negative/variant-module-case-image-out-of-range`; the generated token and IR records; and
`runtime/variant-module-case-image-is-distinct` on Linux x86-64.

### D82 — A static selected case carries finite and repeated array payloads

**The tour said** that a case payload is labelled like a construction [0700]
and that array literals and repetitions describe complete fixed arrays
[0530], [0560]. D81 reserved the selected case's fixed-array payload descriptor
and made only its absent zero image constructible.

**Chosen:** in D81's typed or inferred module construction, a labelled
fixed-array payload accepts D67's finite nonempty literal, D68's full or mixed
repetition, or `zeroed`. Its contextual length and scalar element type come
from the selected D74 payload leaf. Length, count and element disagreements
keep D17/D29/D32's L0301 owners. Every element, prefix and repeated pattern
must be [1940]-known; an excluded storage read is L0304, an unknown fold is
L0305, and an overflowing or out-of-range fold is L0300. D83 adds direct
module array and selected array-field image sources without making the payload
a general value.

No carrier changes. A finite payload descriptor owns its complete fold run; a
full nonzero repetition carries one `Repeated` pattern; a mixed form carries
its finite prefix plus one `Hybrid` suffix pattern. D34's full zero repetition
is the absent image, while D38's mixed zero suffix remains written. The folds
are appended to D81's one item-owned image run, and the payload descriptor's
offset is rebased through that run. D60/D61 copies preserve every form in
distinct module storage.

The verifier already proves these four canonical payload forms, their lengths,
offsets and per-target scalar fit before reading any fold. The backend already
replays the selected case's payload placement: it emits finite directives or
compact `.rept` runs at the element width, inserts target padding and zeroes
the inactive tail. D82 therefore changes only contextual checking and image
production, while extending the public lowering, verifier and backend evidence
over the carrier D81 established.

**Why static forms first:** they exercise every reserved array payload image
without adding the two-level runtime address carried by later stores, fills and
copies. Limiting D82 to finite literals alone would make `zeroed` and compact
repetition needlessly asymmetric with D67/D68. D83 takes the separate static
source-resolution edge; D84 supplies runtime construction and D85 supplies
indexed match aliases.

**Pinned by** the lowering, verifier and backend public seams;
`positive/variant-module-array-payload-image`;
`negative/variant-module-array-payload-shape-disagrees`;
`negative/variant-module-array-payload-not-known`;
`negative/variant-module-array-payload-storage-read`;
`negative/variant-module-array-payload-out-of-range`; the generated token and
IR records; and
`runtime/variant-module-array-payload-image-selects-case` on Linux x86-64.

### D83 — A static array payload copies a module array image

**The tour said** that a module value is present before the entry point [1460]
and that an array assignment copies a complete array [0520]. D21, D69--D71
already follow direct and selected module array images through declaration
identity; D82 made the same four compact forms representable in a selected
variant payload.

**Chosen:** in D81's typed or inferred module case construction, a labelled
fixed-array payload also accepts a direct module fixed-array name or `s.f`,
where `s` directly names a module ordinary struct and `f` is one of its
fixed-array fields. The source must have the payload leaf's exact D17 length
and scalar element type; disagreement is L0301 at the source, related to the
payload label. A scalar, type name, local storage, deeper selection or any
other form keeps its existing owner. A source the checker has already refused
adds no second report.

The payload receives a copy of the source's resolved static image: absent for
an omitted, `zeroed` or zero-repetition source; finite for a written literal;
repeated for a nonzero full pattern; hybrid for a written prefix and suffix
pattern. All-zero finite and zero-suffix hybrid images remain written. The
source may be declared later and may itself follow D21 or D60/D61/D69--D71's
array and aggregate image chains. Validation follows the source declaration
before marking the containing image valid; an existing cycle retains [1940]'s
single L0305 owner. Each destination owns distinct storage.

No carrier, verifier or backend rule changes. Lowering resolves the source
before any image accessor, counts its finite prefix in the aggregate's one
item-owned run, then copies and rebases either the array item's compact image
or the selected field descriptor. The unchanged aggregate setter records the
selected case once; the unchanged verifier rechecks the descriptor against the
payload leaf and target; the unchanged backend emits that form at the payload's
target-derived offset. D60/D61 aggregate image copies preserve the rebased
descriptor and folds.

**Why both source forms:** admitting only a direct name would leave the static
payload behind D65's runtime source rule and behind the D69--D71 image graph,
despite both representations already existing. This remains a contextual
initializer edge: selected payload arrays are not general values. Runtime
fixed-array payload writes follow in D84, while indexed fixed-array match
aliases follow in D85.

**Pinned by** the lowering and backend public seams;
`positive/variant-module-array-payload-image-copy`;
`negative/variant-module-array-payload-image-copy-shape-mismatch`;
`negative/variant-module-array-payload-image-copy-source-refused`;
`negative/variant-module-array-payload-image-copy-source-cycle`; the generated
token and IR records; and
`runtime/variant-module-array-payload-image-copy-is-distinct` on Linux x86-64.

### D84 — A runtime case construction writes fixed-array payloads

**The tour said** that a labelled case construction writes its payload
[0690]--[0700], while array literals, repetitions and copies write a complete
fixed array [0520]--[0560]. D65 already admitted those contextual forms for an
ordinary struct field, but D76 kept a runtime variant payload at `zeroed` even
after D82/D83 supplied the same forms for a static selected-case image.

**Chosen:** a labelled fixed-array payload in D76/D79's runtime case
construction accepts the same contextual forms as D65's ordinary fixed-array
field: a finite literal, a full or mixed repetition, `zeroed`, a direct module
or local fixed-array name, or a directly selected ordinary fixed-array field.
The value must have the payload leaf's exact D17 length and scalar element
type. Length, count, element and copy-shape disagreements keep their existing
L0301 owners. A tracked local source is read as a whole before the case write;
payload expressions read the state arriving at the statement. A refused or
immutable destination is reported first and reads no payload.

Selection remains one destination-first operation: it clears the complete
padded variant part and writes the source-order tag before labelled payloads
are evaluated once in written order. Literal elements store immediately;
repetitions evaluate their repeated value once; copies move the complete
array. A nested `zeroed` payload emits no second clear because selection has
already cleared every byte of the part. Normal completion retains D76's whole
variant-field definite-assignment fact.

No new opcode is needed. `Store_Element`, `Fill_Array` and the destination of
`Copy_Array` gain D76's case and payload-field identities in addition to the
containing aggregate field. Those numbers are declaration identities, never
target offsets; direct and ordinary-field array operations keep zeroes and
their existing text. The verifier proves storage, containing variant field,
case, payload leaf, array shape, index and value type in that order before any
shape accessor, in release as well as debug builds. It retains the existing
array and variant fault kinds.

The backend first performs the bounds check for an element store, then derives
the containing field base and D74's target-dependent payload-field offset,
and finally adds the scaled element index. Fills and copies use that same base;
their width and byte extent come from the selected payload leaf on each target.
Static module constructions remain D82/D83 image rules, not startup writes.
D85 later reads and writes individual elements through a match alias; no
selected variant payload becomes a general array value.

**Why extend the existing array operations:** a payload array is still one
fixed array in known storage. A new opcode for each literal, repetition and
copy would duplicate their ordering and verifier rules; an aggregate temporary
would make the construction a general value. Carrying the two missing
declaration identities lets the established compact operations reach the leaf
without putting layout bytes into the IR, and is also the address carrier a
later fixed-array match alias needs.

**Pinned by** the lowering, verifier and backend public seams;
`positive/variant-runtime-array-payload`;
`negative/variant-runtime-array-payload-shape-disagrees`;
`negative/variant-runtime-array-payload-source-unassigned`;
`negative/immutable-variant-runtime-array-payload`; the generated token and IR
records; and
`runtime/variant-runtime-array-payload-writes-target-storage` on Linux x86-64.

### D85 — A match-arm name aliases a fixed-array payload by element

**The tour said** that [1220] binds the selected case's payload by position,
that `inout` permits mutation, and that indexing selects one array element
[0520], [0580]. D78 implemented that direct alias rule for scalar payloads;
D84 supplied the target-neutral address of a fixed-array payload but did not
let a match arm name it.

**Chosen:** a binding corresponding to a fixed-array payload has that payload's
D17 length and scalar element type. A plain binding is an immutable `in` alias;
`inout name` is mutable. Either may be indexed to read an element, while only
the `inout` form may assign, assign `zeroed`, increment or decrement an indexed
element. `lenof name` reads the contextual length without reading storage.
Constant indexes outside the payload length keep L0306; an unknown index keeps
D48's runtime bounds trap and is evaluated once before the value of a write.

The alias denotes the matched module datum or frame slot directly. It creates
no copied local and no separate definite-assignment fact: D77 already requires
the complete variant part before its tag may be matched, and the binding exists
only in the arm for the selected case. An `inout` write is observable through
the original object after the match. A bare use of the binding remains L0304,
as do whole-array assignment or initializer sources, arguments, returns,
discards and operands. This is an indexed contextual alias, not a general
fixed-array value.

No new opcode is needed. `Load_Element` gains D84's containing-field, case and
payload-field identities; `Store_Element` already carries them. Direct and
ordinary-field element operations keep zero identities and their previous IR
text. The verifier walks storage, containing variant field, case and array
payload before it reads the payload shape, then checks the `usize` index and
element result or operand type in explicit release-build code. The backend
replays D74's target-dependent payload placement and the payload element width
for both module and frame storage; no offset or width enters the IR.

**Why an indexed alias rather than a copied array:** copying would make `in`
and `inout` denote different objects or require hidden copy-out behavior on
every arm exit. Making the name a general whole-array value would widen D20,
D21 and every argument/return boundary at once. The direct alias already used
for D78's scalar leaves preserves [1220]'s one rule while indexing supplies the
only scalar value an expression needs.

**Pinned by** the IR and lowering public seams;
`positive/variant-match-array-payload-bindings`;
`negative/variant-match-array-binding-not-enabled`;
`negative/variant-match-array-binding-is-immutable`;
`negative/variant-match-array-binding-index-out-of-range`; the generated token
and IR records; and
`runtime/variant-match-array-payload-bindings-update-storage` on Linux x86-64.

### D86 — A named ordinary struct field has a measured layout

**The tour said** that fields stay in written order with their natural
alignment [0750], that a named struct introduces one nominal type [0710], and
that `sizeof` and `alignof` answer for a type [0370]. D44/D45 measured scalar
and fixed-array fields, but a field whose type was another named struct still
stopped the containing layout even though the child already had a complete
target-parametric size and alignment.

**Chosen:** a top-level field of an ordinary struct may name a laid-out child
ordinary struct whose own fields are scalar or fixed arrays. The child remains
one declaration-order field. Its size is the child's complete padded size and
its alignment is the child's alignment; the containing placement then applies
[0750] exactly as it does to any other field. Aliases carry the same child body
identity. This slice is deliberately depth one and excludes a child with a
variant part or another aggregate field; a struct inside a variant payload
keeps its existing L0304 boundary.

This is layout and measurement only in D86. D87 below admits declaration
storage and the complete zero image; every nonzero value form stays separate.
An inferred construction is refused from its nominal body before lowering, so
the measurement carrier cannot leak into a datum or frame slot before D87.

The checking table carries the child declaration identity, never its bytes.
Aggregate measurement IR carries an `Aggregate_Field_Shape` whose child is a
bounded declaration-order run of scalar or compact fixed-array shapes. The
verifier proves that run and its depth-one leaves before any accessor reads
them, and rejects the same shape in datum and slot runs. The backend recursively
replays those neutral leaves against the selected target. Thus a 32-bit target
may give the child and parent different extents from Linux x86-64 without any
target offset, padding or host representation entering the IR.

**Why measurement first:** variants followed this same D74/D75 split. It gives
layout a target-executed fact before storage must decide nested selection,
definite-assignment paths, images, clear and copy. Flattening the child into the
parent would lose nominal provenance and make later debugger information
reconstruct it; carrying a target byte extent would make the IR target-specific.

**Pinned by** the checking, lowering and verifier public seams;
`positive/measurement-of-nested-struct-field`;
`positive/module-struct-image-with-a-child`; the generated layout, token
and IR records; and
`runtime/nested-struct-measurements-answer-for-the-target` on Linux x86-64.

### D87 — A depth-one nested ordinary struct has storage and a zero image

**The tour said** that a binding may hold a named struct [0670], that every
field remains in written order at its natural alignment [0750], and that
`zeroed` supplies the complete all-bits-zero image of its contextual type
[0540]. D86 had already proved the child and parent extents on both target
descriptions, but deliberately kept that carrier out of runtime storage.

**Chosen:** a module or local binding may hold D86's depth-one nested ordinary
struct when the child itself has only scalar and fixed-array fields. An omitted
binding has the ordinary zero state. An explicitly typed binding may be
initialized with `zeroed`, and a directly named mutable binding may be assigned
`zeroed`. Each operation clears the complete padded parent extent, including
the child's internal and tail padding, as one whole-storage operation. Module
and local cells are distinct.

This slice does not make the child selection a value or place. `s.child`,
nonzero labelled literals, construction, inference, whole copy, static nonzero
images, deeper nesting and aggregate variant payloads stayed L0304 at this
increment; D88--D132 close those contextual and internal-ABI boundaries. D88
separately admits `s.child.field` for scalar leaves. Those are value-path decisions, not hidden
consequences of allocating a cell.

Runtime datum and slot shapes reuse D86's target-neutral
`Aggregate_Field_Shape`: the parent points at one bounded child run of scalar
and compact fixed-array leaves. The verifier proves that run before access and
still rejects a child containing another aggregate or variant. The backend
recursively replays the run against the selected target for datum reservation,
frame placement and whole clears. Thus the same source clears 40 bytes on
Linux x86-64 and 24 on the synthetic 32-bit description without carrying an
offset, width or padding byte in the IR.

**Why zero storage first:** the complete zero image needs no nested path and no
aggregate temporary, while a selected field or nonzero copy does. Flattening
the child into parent fields would lose D86's nominal provenance; storing its
target extent would make the IR target-specific. D88--D132 later close the
remaining nonzero contextual and internal-ABI boundary.

**Pinned by** the lowering, verifier and backend public seams;
`positive/nested-struct-zero-storage`;
`negative/struct-with-a-struct-field`;
`positive/module-struct-image-with-a-child`; the generated token and IR
records; and `runtime/nested-struct-zero-storage-keeps-neighbours` on Linux
x86-64.

### D88 — A scalar leaf may be selected through one ordinary child

**The tour said** that member selection is left to right and may chain as
`a.b.c` [0420] [1820], while D87 deliberately allocated a depth-one ordinary
child without making any path through it a value or place.

**Chosen:** when a parent binding has D86/D87's one named ordinary child, a
scalar field of that child is a value and a place as `parent.child.field`.
The binding at the root decides mutability exactly as for a direct field. The
intermediate `parent.child` remains neither a general aggregate value nor a
whole place in this slice. D91 separately admits contextual whole-child
assignment; discarding, passing and returning it remain L0304. D89 separately
admits indexed scalar elements of a fixed-array leaf.

Definite assignment retains the two declaration-order field identities. A
write establishes that nested scalar leaf and no sibling; a read requires
that leaf on every arriving path. Assigning the whole parent `zeroed`
establishes every child leaf, and branch merging treats that whole-child fact
and the corresponding nested facts as two representations of the same
assignment. Module state keeps D10's initialized rule unchanged.

Lowering carries the parent field and child field as two target-neutral
identities on the existing scalar field load or store. The verifier proves
that the first names an `Aggregate_Field_Shape`, that its bounded child run
contains the second, and that the selected child shape is scalar. Only the
backend replays the two nested placements against the target: the same `usize`
leaf may therefore have a different module or frame offset on the two target
descriptions without an offset or padding byte entering the IR.

**Why not flatten the child:** flattening would erase the nominal boundary D86
preserved and make debugger provenance reconstruct it. Treating the child as a
general aggregate value would silently decide whole copies and the ABI this
slice does not implement. Two field identities are the smallest carrier that
implements the chain the tour already writes while retaining those boundaries.

**Pinned by** the lowering, verifier and backend public seams;
`negative/nested-struct-scalar-field-unassigned`;
`negative/struct-with-a-struct-field`; the generated token and IR records; and
`runtime/nested-struct-scalar-fields` on Linux x86-64.

### D89 — A fixed-array element may be selected through one ordinary child

**The tour said** that indexing takes what a selection named, explicitly
including `a.b[i]` [0570] [1820], and D87 gives a depth-one child a neutral
fixed-array field shape. D88 established the two-identity path to a scalar
leaf but left that fixed-array leaf refused.

**Chosen:** `parent.child.array[index]` is a scalar value and place when
`array` is a fixed-array field in D86/D87's ordinary child. Its index has the
same `usize` context, compile-time refusal and runtime bounds trap as every
other fixed-array element [1880] [1950]. The root binding decides mutability.
Neither `parent.child` nor `parent.child.array` becomes a general value or
whole place in this slice. D90 separately admits the fixed-array leaf as a
contextual assignment destination or storage-copy source; passing, returning
and discarding it remain L0304.

Definite assignment retains the parent and child identities together with
D19's compiler-known element position. A write establishes only that element;
a known read requires its own fact, and a computed read requires every element
as D22 does. Assigning the whole parent `zeroed` establishes the nested array,
and a branch merge preserves equivalent whole-parent, whole-array and sparse
element representations rather than intersecting their encodings blindly.
Module state remains initialized by D10.

The existing element load and store carry the parent field as their containing
field identity and the child fixed-array field as a second neutral identity.
The verifier proves that the first is an `Aggregate_Field_Shape`, its bounded
child run contains the second, and the selected child shape is an
`Array_Field_Shape` with the instruction's scalar element type. After the
bounds check, the backend places the parent, then the child field, then the
scaled index against the selected target. Neither offset enters checked IR.

**Why not flatten or admit the whole array:** flattening has D88's nominal and
debug-provenance cost. Admitting the whole nested array would also decide
contextual literals, fills and copies, while element access needs none of
those operations. Two field identities reuse D48's compact element carrier
without pretending that broader aggregate-value work is complete.

**Pinned by** the lowering, verifier and backend public seams;
`negative/nested-struct-array-element-unassigned`; the generated token and IR
records; and `runtime/nested-struct-array-elements` on Linux x86-64.

### D90 — A nested fixed-array leaf has contextual assignment forms

**The tour said** that an array value may be copied, filled and initialized
[0520] [0540], while D49--D53 deliberately implement those forms directly in
existing storage. D89 reached scalar elements through one ordinary child but
did not give the fixed-array leaf a whole-value carrier.

**Chosen:** a mutable `parent.child.array` is a contextual assignment place.
It accepts an exact array literal, a full or mixed repetition, `zeroed`, or a
storage copy from another direct or depth-one fixed-array place with the same
length and scalar element type. The source is admitted only in that copy
context. A nested leaf is not thereby a general expression value, parameter,
return, discard or operand; those remain L0304. D92 separately admits an
explicitly typed local initializer from the nested storage path.
Root-binding mutability and [0410]'s source evaluation order are unchanged.

A successful assignment records the whole nested-array fact. A copy source
requires every element on every arriving path; whole-parent, whole nested
array and complete sparse-element facts retain the equivalence D89 established
at branch merges. Module state keeps D10's initialized rule.

Element stores for literals retain D89's parent and child field identities.
The compact fill and clear operations carry those same destination identities;
a copy carries an independent pair for each endpoint. The verifier walks each
bounded child run, checks an `Array_Field_Shape`, and requires source and
destination length and element type to agree. The backend derives both nested
offsets and only the leaf's scalar byte extent after target selection.

**Why contextual assignment only:** these forms already lower directly into
known storage and need no aggregate temporary. Extending the leaf to every
expression or initializer position would decide a first-class aggregate value
and ABI merely because a path can now name its bytes. Keeping independent
endpoint identities also avoids flattening either nominal child.

**Pinned by** the lowering, verifier and backend public seams;
`negative/nested-struct-array-copy-unassigned`; the generated token and IR
records; and `runtime/nested-struct-array-values` on Linux x86-64.

### D91 — One ordinary child has contextual aggregate assignment forms

**The tour said** that a whole ordinary struct may be zeroed, constructed and
copied [0540] [0710], while D87 gave a parent one recursively laid-out ordinary
child but intentionally left `parent.child` without value/place operations.
D88--D90 then proved every scalar and fixed-array leaf path independently.

**Chosen:** `parent.child` is a contextual aggregate assignment place. It
accepts `zeroed`, a matching labelled literal or nominal construction, and a
storage copy from either a direct value of the child's nominal type or the
same child path in another parent. The root binding decides mutability. The
child remains no general expression value, inferred or module initializer,
parameter, return, operand or discard; source selection is admitted only for
the matching storage-copy context. D92 separately admits an explicitly typed
local initializer.

A successful whole-child assignment establishes the parent-field fact, which
already denotes every D88/D89 leaf. A whole-child copy source requires that
fact on every arriving path; independently assigning some leaves does not
invent an aggregate value. Module state remains initialized by D10.

`zeroed` uses one whole-child clear carrying the parent field identity.
Construction lowers each scalar or fixed-array child leaf with that parent as
its first identity and the child field as its second. Copy lowering does the
same independently for source and destination, reusing scalar field and
compact array-copy operations rather than adding an aggregate temporary. The
verifier recognizes a whole `Aggregate_Field_Shape` clear and validates each
leaf operation; the backend derives the child's padded extent and both endpoint
offsets only after target selection.

**Why not a general child value:** every accepted form has known destination
storage and can commit directly in [0410]'s order. A first-class child value
would require temporary representation, ABI rules and expression lifetime
without helping these assignments. Keeping its nominal parent identity on
each operation also avoids flattening D86's boundary.

**Pinned by** the lowering, verifier and backend public seams;
`negative/nested-struct-child-copy-unassigned`; the generated token and IR
records; and `runtime/nested-struct-child-values` on Linux x86-64.

### D92 — A typed local may copy from a nested aggregate leaf

**The tour said** that a local initializer may copy an array or ordinary struct
from existing storage [0520] [0710]. D51/D55 implemented direct storage and a
direct array field, while D90/D91 made depth-one array and ordinary-child paths
contextual storage-copy sources.

**Chosen:** an explicitly typed local fixed array may initialize from
`parent.child.array`, and an explicitly typed local of the child's nominal
ordinary type may initialize from `parent.child`. The written local type must
match the source length/element or nominal body exactly. Both copies require
the complete source to be definitely assigned. Module initializers from either
nested path remain L0304 because they need static image-edge decisions this
runtime slice does not make. D93 separately admits inference for a local whose
source carries the complete nested shape or nominal identity.

Lowering allocates the ordinary destination slot, then reuses D90/D91's
independent source parent/child identities and a direct destination path. A
child initializer visits declaration-order scalar and fixed-array leaves; an
array initializer remains one compact copy. Verification and target replay are
therefore unchanged from the corresponding assignment operations.

**Why typed local only:** its declaration already supplies the identity and
fresh destination storage, so no aggregate temporary or inference carrier is
needed. Module image copying and inferred aggregate values have different
lifetime and cycle evidence and are not consequences of naming a runtime
source path.

**Pinned by** the lowering and verifier public seams;
`negative/nested-struct-child-initializer-unassigned`; the generated token and
IR records; and `runtime/nested-struct-child-values` on Linux x86-64.

### D93 — A local may infer its aggregate identity from nested storage

**The tour said** that `:=` gives a local the type of its initializer [0080].
D92 required an explicit local type even though a depth-one child already
carries D71's nominal body and its fixed-array leaf carries D17's complete
length and scalar element identity.

**Chosen:** a local may infer an ordinary child value from `parent.child`, or
a fixed-array value from `parent.child.array`. The source must be one of the
contextual storage paths D90/D91 admitted and must be definitely assigned as a
whole. The inferred child keeps its nominal body; the inferred array keeps its
length and scalar element. Module inference from these paths remains L0304
because static image edges and cycles are not runtime storage copies.

Lowering is D92's typed-local copy after the checker has recorded the inferred
identity: allocate a fresh aggregate or array slot, then visit child leaves or
emit one compact array copy with the source parent/child identities. No general
expression value or aggregate temporary is introduced.

**Why inference is sound here:** the source path supplies exactly one complete
identity before lowering, unlike a bare labelled literal. Restricting the rule
to locals keeps it in runtime storage and does not silently extend module image
graphs or the ABI.

**Pinned by** the checker, lowering and verifier public seams;
`negative/nested-struct-child-inference-unassigned`; the generated token and
IR records; and `runtime/nested-struct-child-values` on Linux x86-64.

### D94 — An ordinary struct argument is copied into callee storage

**The tour said** that an unmarked parameter is `in` [0900], calls evaluate
arguments left to right [0410], and an ordinary struct has nominal identity
[0710]. The scalar internal convention had no rule for carrying the complete
storage of one.

**Chosen:** a parameter may have an ordinary struct type whose fields are
scalar or fixed arrays, without an ordinary-child or variant field. A call may
supply a direct module or frame storage name of exactly that nominal type. The
source must be definitely assigned in full. Construction, nested-child paths,
struct-returning calls and other aggregate expressions remain refused in this
argument position.

One aggregate occupies one position in the existing internal argument run. The
caller forms a target-neutral `Storage_Address` carrier; the first six
positions use integer registers and later positions use D86's eight-byte stack
slots. The carrier is not a Landin pointer and cannot be named by source. The
callee preserves every incoming aggregate carrier before copying, derives the
complete padded extent from its selected target, and copies the bytes into a
fresh aggregate parameter slot before the body runs. Reads therefore use
ordinary field and array operations against independent by-value storage.

**Why an internal address and defensive copy:** flattening fields would make
one source parameter consume a target-dependent number of argument positions,
while aliasing caller storage would change `in` from a value convention into a
hidden reference convention. The neutral carrier keeps offsets, padding and
extent out of verified IR; the callee-side copy makes the observable value
independent and leaves R4.40 to classify C aggregates separately.

**Pinned by** the checker, lowering, malformed-IR verifier and backend public
seams; `negative/struct-argument-unassigned`; the generated token and IR
records; and `runtime/struct-arguments-cross-calls` on Linux x86-64.

### D95 — A fixed array argument uses the same by-value transport

**The tour said** that a fixed array's length is part of its type [0520] and an
unmarked parameter is `in` [0900]. D94's internal carrier and callee copy did
not depend on nominal fields, but the checker and IR parameter builder still
admitted only its ordinary-struct case.

**Chosen:** a parameter may have any enabled fixed-array type, and a call may
supply a direct module or frame storage name with exactly the same scalar
element and length. Every source element must be definitely assigned. An array
literal, repetition, nested array field, returning call or other array
expression remains refused as an argument.

The array occupies one existing internal ABI position. The caller emits D94's
unspellable target-neutral storage-address carrier. The callee preserves that
carrier with the struct carriers, derives `length * target element size`, and
copies those bytes into a fresh shaped array parameter slot before running.
Register and stack positions therefore have one convention for scalar,
ordinary-struct and fixed-array source parameters while their frame storage
retains the distinct neutral shape each operation needs.

**Why reuse the carrier:** passing every element separately would make D18's
largest arrays impossible to represent compactly and would make argument
position depend on the selected target. Passing an alias without copying would
not implement `in` as a value. D94's one-position transport plus defensive copy
avoids both changes without introducing a source pointer.

**Pinned by** the checker, lowering, verifier and backend public seams;
`negative/array-argument-unassigned`; the generated token and IR records; and
`runtime/array-arguments-cross-calls` on Linux x86-64.

### D96 — Contextual nested storage may be an aggregate argument

**The tour said** that calls evaluate argument expressions left to right
[0410]. D90/D91 made `parent.child.array` and `parent.child` complete
contextual storage sources, while D94/D95 initially accepted only a direct
storage name in an aggregate argument position.

**Chosen:** a flat ordinary-struct parameter may receive a depth-one ordinary
child `parent.child`, and a fixed-array parameter may receive either
`parent.array` or `parent.child.array`. Nominal identity or array shape must
match exactly, and the selected child or array must be definitely assigned in
full. Deeper paths, construction and other general aggregate expressions
remain refused.

`Storage_Address` carries the independent declaration-order parent and child
field identities in addition to its module-or-frame storage identity. It never
carries an offset. The backend recursively places those fields for the selected
target before transporting the resulting address through D94/D95's one ABI
position; the callee performs the same defensive copy into independent shaped
parameter storage.

**Why preserve the path:** flattening the child into a new datum would erase
D86's nominal boundary, while recording the selected target offset would make
checked IR target-specific. The existing contextual source already proves one
complete extent, so extending its neutral path carrier to the argument boundary
does not create an aggregate expression value.

**Pinned by** the checker, lowering, malformed-IR verifier and backend public
seams; `negative/nested-storage-argument-unassigned`; the generated token and
IR records; and `runtime/nested-storage-arguments` on Linux x86-64.

### D97 — `zeroed` may directly fill an aggregate argument temporary

**The tour said** that `zeroed` takes its type from context [0540]. D94/D95
provided shaped by-value parameter storage, but required the caller to name
existing storage even when the all-zero value needed no source object.

**Chosen:** `zeroed` may appear directly where a flat ordinary-struct or
fixed-array parameter supplies its complete type. The caller allocates a fresh
shaped temporary, clears its complete target-derived extent with the existing
compact clear operation, and passes its `Storage_Address` through the same
one-position internal convention. The callee still performs the ordinary
by-value copy before its body runs.

The temporary and clear are target-neutral in verified IR: an ordinary struct
carries its field shapes and an array carries length and scalar element. Only
the backend derives padding, widths and byte extent. `zeroed` does not become a
general aggregate expression, and nested or variant-bearing parameter types
remain outside this rule.

**Why retain both temporary and callee copy:** special-casing an all-zero ABI
argument would create a second convention and would make its behavior depend
on whether the caller wrote equivalent named zero storage. Materializing the
contextual value through existing storage keeps argument order, register/stack
placement and by-value independence identical.

**Pinned by** the checker, lowering, verifier and backend public seams; the
generated token and IR records; and `runtime/nested-storage-arguments` on
Linux x86-64.

### D98 — An array literal may directly fill an argument temporary

**The tour said** that an array literal evaluates its elements in source order
[0410] and a fixed-array parameter supplies a complete length and scalar
element type [0520]. D95 initially required named storage, and D97 admitted
only its all-zero contextual value.

**Chosen:** an array literal may appear directly in a fixed-array argument
position when it has exactly the parameter's length and every element matches
the parameter's scalar element type. The caller allocates a fresh shaped array
slot, evaluates and stores each element left to right, then passes the slot's
`Storage_Address` through D95's existing one-position convention. The callee
copies it into independent parameter storage as usual.

The literal remains contextual: its parameter supplies shape before any
element is checked, and no array-valued expression result or target-sized IR
run is introduced. One scalar store is emitted per written literal element;
D18's unbounded compactness requirement is unaffected because source text
already contains exactly that many elements.

**Why materialize in the caller:** flattening literal elements into ABI
positions would change the convention by source form and target, while a
callee-only construction would reverse [0410]'s caller-side argument order.
The temporary preserves both order and one-position transport.

**Pinned by** the checker, lowering, verifier and backend public seams;
`negative/array-literal-argument-shape-mismatch`; the generated token and IR
records; and `runtime/array-arguments-cross-calls` on Linux x86-64.

### D99 — Array repetition forms may fill an argument temporary

**The tour said** that repetition evaluates its repeated expression once
[0560], and mixed repetition evaluates its explicit prefix before that one
suffix expression [0410]. D98's shaped caller temporary provides the same
complete fixed-array context at an argument boundary.

**Chosen:** full and mixed array repetition may appear directly in a matching
fixed-array argument position. A written full-repetition count must equal the
parameter length; a mixed prefix must leave at least one destination position.
Lowering stores explicit prefix elements in source order, evaluates the repeated
expression once, emits one compact suffix fill, and transports the temporary
through D95's existing address convention.

The fill retains a one-based first destination identity and the temporary's
neutral length and scalar element. Neither lowering nor verified IR expands the
repeated suffix, including for D18's target-sized lengths; target byte width and
extent remain backend facts.

**Why both forms share one rule:** their only semantic difference is the
source-ordered explicit prefix. Giving arguments a separate repetition
representation would duplicate the contextual assignment and initializer
semantics without changing the ABI carrier or callee copy.

**Pinned by** the checker, lowering, verifier and backend public seams;
`negative/array-repetition-argument-shape-mismatch`; the generated token and IR
records; and `runtime/array-arguments-cross-calls` on Linux x86-64.

### D100 — A scalar-field struct literal may fill an argument temporary

**The tour said** that labelled struct construction evaluates fields in source
order [0410], omitted fields may use `of zeroed` [0700], and ordinary structs
are nominal [0710]. D97 supplied the shaped caller temporary for an entirely
zero aggregate but not for labelled construction.

**Chosen:** a bare or correctly nominal construction may appear directly where
a flat ordinary-struct parameter has scalar fields only. Labels are checked
against the parameter's nominal body, evaluated and stored in source order;
`of zeroed` writes zero or false to omitted fields in declaration order. The
caller then transports the complete temporary through D94's existing address
convention and the callee copies it by value.

Structs with fixed-array, ordinary-child or variant fields remain outside this
literal-argument slice; their labels require additional contextual leaf
materialization. The temporary itself retains declaration-order scalar shapes,
never target offsets or padding.

**Why scalar fields first:** it exercises nominal contextual construction and
caller-side evaluation order without duplicating D65/D76's array and variant
leaf machinery inside call lowering. Those shapes remain valid storage
arguments by D94/D96; only direct literal construction is narrower.

**Pinned by** the checker, lowering, verifier and backend public seams;
`negative/struct-literal-argument-nominal-mismatch`; the generated token and IR
records; and `runtime/struct-arguments-cross-calls` on Linux x86-64.

### D101 — Struct literal arguments may contain fixed-array fields

**The tour said** that a labelled array field receives the same contextual
array forms as standalone fixed-array storage [0520] [0700]. D100 restricted
argument construction to scalar fields even though its caller temporary already
carried compact fixed-array field shapes.

**Chosen:** a flat ordinary-struct literal argument may label fixed-array
fields with literals, full or mixed repetitions, `zeroed`, or matching direct
and D96 nested storage paths. Each label commits in source order. Explicit
array elements are stored in order, repetition uses one compact suffix fill,
`zeroed` clears the field extent, and storage sources use one compact copy.
`of zeroed` clears any omitted fixed-array field after all labels.

Every operation targets the aggregate temporary by declaration-order field
identity. Source copies retain independent parent and child identities. No
field offset, padding byte or expanded repeated suffix enters checked IR; the
complete temporary then follows D94's ordinary one-position transport and
callee copy.

**Why this closes only fixed-array leaves:** D65 already supplies their finite
contextual operation family and compact shape. Ordinary-child and variant
fields require recursive construction or case selection and remain separate
argument slices rather than being flattened here.

**Pinned by** the checker, lowering, verifier and backend public seams;
`negative/struct-literal-argument-array-shape-mismatch`; the generated token and
IR records; and `runtime/struct-arguments-cross-calls` on Linux x86-64.

### D102 — Variant-bearing struct storage may cross an argument boundary

**The tour said** that an unfolded variant is part of its enclosing struct's
storage [0680] and matching inspects the selected case [0770]. D74--D85 carry
that shape through local and module storage, while D94 initially refused it at
a parameter declaration.

**Chosen:** an ordinary struct parameter may contain unfolded variant fields,
provided it contains no ordinary-child field. Direct matching storage or
contextual `zeroed` may supply the argument. The complete variant field must be
definitely assigned: a declaration-only local cannot cross the call until a
case has been selected. Struct-literal argument construction with a variant
label remains a separate slice.

The aggregate parameter slot retains the variant tag type, source-order cases
and compact payload-field runs. D94 transports one storage address and copies
the complete target-derived padded struct extent before the body; tag matching
and payload aliases then operate on the independent callee slot exactly as on
any local aggregate.

**Why opaque transport is sufficient:** case classification affects storage
layout but not this internal convention's one-position carrier. Reclassifying
or flattening payload leaves at the call would duplicate the selected target's
layout in neutral IR. Keeping the existing shape and copying its extent avoids
that second authority.

**Pinned by** the checker, flow, lowering, verifier and backend public seams;
`negative/variant-struct-argument-unassigned`; the generated token and IR
records; and `runtime/variant-struct-arguments` on Linux x86-64.

### D103 — Struct literal arguments may select variant cases

**The tour said** that a variant label selects one case and evaluates its
payload labels in source order [0690] [0700]. D102 carried existing
variant-bearing storage through calls but left direct argument construction
refused.

**Chosen:** a flat variant-bearing struct literal may appear directly in a
matching parameter context. Its variant label selects a case in the fresh
caller temporary before payload labels are committed. Scalar payloads store in
source order; fixed-array payloads use the same literal, repetition, `zeroed`
and storage-copy forms D101 gives ordinary array fields. `of zeroed` selects
the first case for an omitted variant field.

Selection clears the complete padded unfolded part before payload writes, so
inactive bytes and omitted payload leaves have the all-zero image. The IR
retains field, case and payload-field identities; target tag placement, payload
offsets and padded extent remain backend-derived. The finished temporary then
uses D102's unchanged one-position by-value transport.

**Why construction stays in caller storage:** case and payload expressions are
arguments and therefore belong in [0410]'s caller-side evaluation order.
Flattening them into ABI operands would expose the selected target's unfolded
layout and make equivalent named storage use a different convention.

**Pinned by** the checker, lowering, verifier and backend public seams;
`negative/variant-literal-argument-payload-mismatch`; the generated token and
IR records; and `runtime/variant-struct-arguments` on Linux x86-64.

### D104 — A depth-one nested struct may cross an argument boundary

**The tour said** that an ordinary child retains its nominal boundary [0710]
and D86--D93 represent one such child by parent and child field identities.
D94 carried the child itself but still refused a parameter whose complete type
contained that field.

**Chosen:** an ordinary struct parameter may contain one depth-one ordinary
child whose fields are scalar or fixed arrays. Direct matching storage or
contextual `zeroed` may supply the complete outer argument. Definite assignment
requires every outer scalar/array field and the complete ordinary child; sparse
assignment of one nested leaf is not enough. Direct outer struct-literal
construction with an ordinary-child label remains separate.

The parameter slot retains an `Aggregate_Field_Shape` whose compact payload run
is the child's declaration-order scalar and array leaves. D94's caller carrier
still occupies one ABI position and the callee copies the complete recursively
placed padded extent before running. Child field and element reads then reuse
D88/D89's neutral parent/child identities.

**Why preserve one slot:** splitting the child into ABI operands would erase
its nominal boundary and make operand count depend on composition. The existing
recursive target placement already derives its extent from neutral shape, so
opaque one-position transport remains sufficient.

**Pinned by** the checker, flow, lowering, verifier and backend public seams;
`negative/nested-struct-argument-unassigned`; the generated token and IR
records; and `runtime/nested-storage-arguments` on Linux x86-64.

### D105 — Struct literal arguments may construct an ordinary child

**The tour said** that a labelled struct literal evaluates fields in source
order [0410] while an ordinary child's identity remains nominal [0710]. D104
carried complete nested storage but left a direct outer construction refused.

**Chosen:** a flat outer struct-literal argument may name its depth-one
ordinary-child field with a bare or matching nominal child literal, contextual
`zeroed`, or matching direct child storage. The child's scalar and fixed-array
labels use their existing contextual forms. An explicit child constructor with
a different nominal body is a type mismatch even when its fields coincide.
`of zeroed` clears an omitted child as one complete padded subobject.

Lowering first clears a constructed child's complete padded extent and then
commits its labels in source order. Scalar and array operations retain both
parent and child identities. A storage source instead copies declaration-order
leaves into the same destination child; target offsets and padding remain
absent from neutral IR. The finished outer temporary uses D104's ordinary
one-position transport.

**Why clear before labels:** this gives padding and an `of zeroed` omission one
canonical all-zero image without introducing a nested aggregate value. Every
explicit expression still runs exactly once and in source order before the
call.

**Pinned by** the checker, lowering, verifier and backend public seams;
`negative/nested-struct-literal-argument-nominal-mismatch`; the generated token
and IR records; and `runtime/nested-storage-arguments` on Linux x86-64.

### D106 — Aggregate results return into caller-owned storage

**The tour said** that a function's named return is an ordinary place [0930]
and every call evaluates arguments before entering the callee [1920]. D94
established one-position by-value aggregate arguments, but no result convention
made a returned struct's lifetime independent of the callee frame.

**Chosen:** a function with an ordinary, variant-bearing or depth-one nested
struct result receives one unspellable internal `usize` parameter naming
caller-owned result storage. It precedes all source parameters in the existing
register/stack run. The callee keeps its named result in an independently
shaped local slot and, at every successful leave, copies the complete
source-target-derived padded extent to that address. A typed local initializer
may supply a matching aggregate-returning call as its value.

The checked IR item retains `Aggregate` as the declared result and keeps the
complete neutral shape on its result slot. The call instruction itself has no
aggregate value: its first operand is an opaque `Storage_Address` for the
already-shaped destination, followed by source arguments. The verifier checks
that operand against the hidden scalar parameter. Target offsets, padding and
byte extent enter only when the backend emits the final copy.

**Why not return a pointer to callee storage:** that pointer would escape a dead
frame and would turn by-value semantics into an alias. Returning fields in
registers would instead require target ABI classification in neutral IR and
pre-empt R4.40. Caller storage preserves value lifetime and the established
one-position internal convention without either error.

**Pinned by** the checker, flow, lowering, verifier and backend public seams;
`negative/struct-return-unassigned` and `negative/variant-return-unassigned`;
the generated token and IR records; and `runtime/struct-returns-cross-calls`,
`runtime/variant-returns-cross-calls` and
`runtime/nested-struct-returns-cross-calls` on Linux x86-64.

### D107 — Fixed arrays use the same caller-owned result convention

**The tour said** that a fixed array's identity is its element type and length
[0520], and D17 keeps that shape independent of any target byte extent. D106's
hidden destination therefore has all the information an array result needs as
well as a struct result.

**Chosen:** a function may name a fixed-array return, assign it through the
existing whole-array contextual forms, and initialize a matching typed local
from its call. One leading unspellable `usize` parameter points at the caller's
shaped array slot. On leave the callee copies exactly `length * element-size`
bytes from its independent result slot. The call itself still returns no IR
value.

Definite assignment records a whole-array fact for the named return; assigning
known elements independently also suffices once every position is covered.
The neutral result slot carries element type and length, never the selected
target's byte count.

**Why share D106:** a second array-specific return channel would make source
aggregate category, rather than lifetime and target classification, decide the
ABI. Both are fixed-size by-value storage and need the same caller lifetime.

**Pinned by** the checker, flow, lowering, verifier and backend public seams;
`negative/array-return-unassigned`; the generated token and IR records; and
`runtime/array-returns-cross-calls` on Linux x86-64.

### D108 — An aggregate-returning call may fill aggregate storage directly

**The tour said** that an expression body fills its named return [0880], while
assignment evaluates its source before committing the destination [0410]. Once
D106/D107 give a call caller-owned storage, routing its result through another
aggregate value would add no semantics and would lose that direct destination.

**Chosen:** a matching struct- or fixed-array-returning call may initialize a
typed local, assign a direct whole aggregate place, fill a named return in a
block, or serve as that return's expression body. Lowering supplies the final
place itself as the hidden result destination. Forwarding therefore performs
callee-to-caller copies at each source call boundary but never materializes an
aggregate SSA value or aliases one frame's storage into another.

Child-field destinations remain separate: they require a field-qualified
hidden destination carrier before a returned call can fill them directly.

**Why retain each boundary copy:** the language says aggregate arguments and
results are values, not aliases. Tail-call storage forwarding could elide a
copy later, but it is an optimization only when it preserves the independently
observable named-return place and all source evaluation order.

**Pinned by** the checker, flow, lowering, verifier and backend public seams;
the generated token and IR records; and the forwarding paths in
`runtime/struct-returns-cross-calls` and `runtime/array-returns-cross-calls` on
Linux x86-64.

### D109 — Aggregate calls may return directly into field storage

**The tour said** that field and nested-element assignments are places [1900].
D88--D90 preserve their declaration-order identities, while D108 initially
required an aggregate call's destination to be a whole slot.

**Chosen:** a matching struct result may fill a depth-one ordinary-child field,
and a matching fixed-array result may fill a direct array field or one array
leaf inside that child. The hidden `Storage_Address` carries destination parent
and child identities exactly as aggregate arguments do. The backend derives
the selected target address before the call; the callee remains unaware that
its result storage is a subobject.

Definite assignment records the complete child or array fact after the call.
No target offset, byte extent or source-level pointer enters checked IR.

**Why destination qualification belongs on the address:** copying first into a
temporary and then into the field would be correct but would add an avoidable
whole aggregate copy. Passing a qualified opaque destination preserves the
same by-value result semantics because the callee writes only its independent
named result until the leave copy.

**Pinned by** the checker, flow, lowering, verifier and backend public seams;
the generated token and IR records; `runtime/struct-returns-cross-calls`,
`runtime/array-returns-cross-calls` and `runtime/nested-storage-arguments` on
Linux x86-64.

### D110 — A local may infer aggregate identity from a returned call

**The tour said** that `:=` infers the binding's type from its initializer
[0050]. D93 already preserves nominal child identity from storage; D106/D107
now give a call the same neutral struct body or array shape without making its
result an IR value.

**Chosen:** a local initialized directly by an aggregate-returning call may
infer the callee's nominal struct body or fixed-array element type and length.
The inferred binding receives its own shaped slot, which is supplied directly
as D106's hidden destination. Module inference from calls remains forbidden by
[1940], because module images run no call before entry.

**Why inference changes no ABI rule:** checking copies only source identity into
the declaration, before lowering. Runtime still has exactly the same
caller-owned destination and callee leave copy as an explicitly typed local.

**Pinned by** the checker, lowering, verifier and backend public seams; the
generated token and IR records; and the inferred locals in
`runtime/struct-returns-cross-calls` and `runtime/array-returns-cross-calls` on
Linux x86-64.

### D111 — A returned aggregate may immediately cross an argument boundary

**The tour said** that arguments evaluate left to right [0410] and each `in`
parameter receives a value [0900]. D106's result destination and D94's argument
carrier can therefore meet in one caller-owned temporary without exposing an
aggregate expression to neutral IR.

**Chosen:** a matching struct- or fixed-array-returning call may be supplied
directly to an aggregate parameter. The inner call first fills a fresh shaped
caller temporary through its hidden destination. Only after that call completes
does the outer call transport the temporary's opaque address and perform its
ordinary defensive callee copy. Nominal struct identity and array shape are
checked at the source boundary.

When later arguments change blocks, the temporary address uses the same saved
scalar carrier as any earlier aggregate argument, preserving block-local IR and
source evaluation order.

**Why two copies remain semantic:** the inner return establishes a value in the
caller and the outer `in` boundary establishes an independent callee value.
Optimization may combine storage only after proving neither identity can be
observed; the language and verifier do not depend on that optimization.

**Pinned by** the checker, lowering, verifier and backend public seams;
`negative/returned-struct-argument-nominal-mismatch`; the generated token and
IR records; and the nested calls in `runtime/struct-returns-cross-calls` and
`runtime/array-returns-cross-calls` on Linux x86-64.

### D112 — Discarding an aggregate call still gives its result a lifetime

**The tour said** that discarding a result is explicit [1020] [1930]. A scalar
call can simply leave its produced IR value unused, but D106 requires valid
storage through the aggregate callee's leave copy.

**Chosen:** `_ = call()` for a struct or fixed-array result allocates a fresh
shaped caller temporary, supplies it as the hidden destination, completes the
call and then drops the storage. No field is read and no aggregate IR value is
created. Calls returning `none` remain invalid discard sources because they
produce no result at all.

**Why not omit the hidden destination:** the callee's writes and argument
evaluation are observable even when the returned value is not. Running a
different result convention only for discard would change the call rather than
throw away its result.

**Pinned by** the checker, lowering, verifier and backend public seams; the
generated token and IR records; and the explicit discards in
`runtime/struct-returns-cross-calls` and `runtime/array-returns-cross-calls` on
Linux x86-64.

### D113 — An inferred function value is a code address

**The tour said** that a function is an ordinary value represented as a code
address [0870] [1000]. The first executable slice does not need written function
types to preserve that identity: a direct function name supplies its complete
signature when a local uses `:=`.

**Chosen:** a local may infer a function value from a direct function name,
store that value, replace a mutable binding with another function value, and
call the binding indirectly. The inferred binding retains a first-class
signature descriptor as its checking identity, independently of the concrete
routine that first supplied it. Neutral IR materializes a `Function_Address`
naming a routine item and carrying its descriptor; `Indirect_Call` carries a
structurally agreeing descriptor, names no callee item, and takes the runtime
code address as its first operand. The Linux backend emits RIP-relative address
formation and `call *address`.

Arguments, scalar or aggregate results, stack positions and hidden aggregate
result destinations otherwise use the existing internal convention unchanged.
D117 adds one written infallible function type. D118 carries that value through
parameters, results and static module storage and adds anonymous routines.

**Why the indirect instruction retains a signature:** a runtime address alone
cannot tell the verifier how many operands or what result convention the call
uses. Naming a semantic descriptor is target-neutral type evidence, not a
claim that the runtime target is statically known.

**Pinned by** the checker, lowering, verifier and backend public seams;
`negative/function-value-type-mismatch`; the generated token and IR records;
and `runtime/inferred-function-values` on Linux x86-64.

### D114 — Indirect calls share the complete internal convention

**The tour said** that a function value has its signature as its ordinary type
[1000]. Replacing an inferred function binding therefore requires equal
parameter and result shapes, not merely another code address.

**Chosen:** mutable function values may be replaced only by a function with the
same parameter count, declaration-order parameter types and result type.
Nominal struct bodies and fixed-array shapes participate in that equality;
parameter and result labels do not.
An indirect call uses the complete direct-call convention: hidden aggregate
result destination first, then source parameters across the six-register and
stack run. The runtime code-address operand is verifier metadata and is not a
source ABI parameter.

**Why signature equality is checked before runtime:** a code address carries no
machine-readable Landin signature. Delaying disagreement until the call would
turn a deterministic type error into register and storage corruption.

**Pinned by** the checker, lowering, verifier and backend public seams;
`negative/function-value-signature-mismatch`; the generated token and IR
records; and `runtime/indirect-function-abi` on Linux x86-64.

### D115 — Aggregate call completion is an ordinary assignment fact

**The tour said** that no condition is believed and a name assigned in one
branch but not another is not assigned after the branch [1910]. A call's hidden
result destination does not create an exception to that rule.

**Chosen:** when an aggregate-returning call completes into a local place, that
place gains exactly the same definite-assignment fact as a whole-place
assignment. Branch joins intersect that fact normally. A guarded return does
not erase a fact on its continuing edge, and it still requires every named
return to be complete on the edge that exits.

**Why this is not a call-specific flow rule:** the hidden destination is only a
transport convention. Giving it stronger flow semantics would let replacing a
literal assignment by an equivalent call change whether later reads are legal.

**Pinned by** `negative/aggregate-call-result-not-assigned-on-every-path` and
`runtime/aggregate-results-across-branches` on Linux x86-64.

### D116 — Every aggregate-result exit performs its own final copy

**The tour said** that every reachable `return` requires the named return to be
assigned [1890] [1910]. Aggregate caller-owned storage makes the consequence
observable at more than the function's lexical end.

**Chosen:** each accepted early or final exit from an aggregate-returning
function copies the complete independent named-result slot into that call's
hidden caller destination. An aggregate call may complete the named result
immediately before either exit. Flow checking refuses an exit reached without
the complete result; another arm having completed and exited does not lend its
fact to that path.

**Why every exit copies:** redirecting only lexical fallthrough would make an
early `return` expose an unfilled caller image, while returning the callee slot's
address would expose dead frame storage. Both violate the same by-value result
boundary.

**Pinned by** `negative/aggregate-call-result-missing-at-early-exit` and
`runtime/aggregate-results-across-early-exits` on Linux x86-64.

### D117 — A function value carries a signature, not a possible callee

**The tour said** that a function type is an ordinary type, written like its
signature, and that a function value is a code address [0870] [1000]. It did
not say whether the labels are declarations, how a stored address retains its
type, or which written storage context opens the implementation slice.

**Chosen:** [1800]'s infallible signature is one written function type. Its
parameter and result labels describe positions and declare nothing. It may be
named by a type declaration and used for explicitly typed local storage; the
local may be called indirectly and, when mutable, replaced by any function
whose complete signature agrees. D118 extends the same descriptor to module
storage, parameters, results and anonymous routines. Function-valued struct
fields and declared-error signatures remain later slices.

Every declared function, written function type and inferred function value
receives a first-class target-neutral signature descriptor. Agreement compares
parameter count and declaration-order types plus the result type; labels and
source sites do not participate. Scalar identity, nominal aggregate identity
and fixed-array length and scalar element identity do. The verified IR carries
the same semantic descriptor on routines, code-address values, function-value
slots and direct or indirect calls. An `Indirect_Call` names no concrete
routine: its address operand and descriptor must agree, and the descriptor
alone decides the carrier count and result convention.

**Why not keep the first function declaration as type evidence:** a written
type need not have one possible target, and a mutable local may successively
hold several. Treating the first callee item as the type makes an incidental
initializer an authority over later checking and prevents malformed IR from
expressing the actual disagreement. A code address alone has no type metadata;
target widths, registers and offsets would make the alternative descriptor an
ABI record rather than a language signature.

**Pinned by** the parser, checker, type, lowering, IR, verifier and x86-64
backend seams; malformed signature and indirect-call cases in the verifier
suite; `negative/written-function-signature-mismatch`; the generated lexical
and IR records through `positive/written-function-values`; and
`runtime/written-function-values` together with the existing
inferred-function-value runtime cases on Linux x86-64.

### D118 — A subobject path is a run of steps, not a pair

**The tour said** that member selection is left to right and may chain as
`a.b.c` [0420] [1820], and puts no depth on that chain. D88--D90 implemented
one step below a parent field and spelt it as a second scalar identity beside
the first, which is a pair and cannot say what a third selection reached.

**Chosen:** every target-neutral operation that names part of an aggregate
carries a _path_: a run of steps, each naming a declaration-order position
[0750] inside the run the step before it reached, and each carrying the
one-based source-order case when the run it indexes is a variant part's
payload rather than an ordinary field run. An empty path is the direct
operation. The base field stays where it was, so a path of one step is
exactly what D88--D90 already meant.

The verifier walks a path against the shapes alone: every step must name a
part the run it indexes actually has, and the part the last step reaches must
be the kind the operation needs. The backend derives one target offset per
step from the same placement the checker used, and adds them. No step, and no
sum of steps, is stored in the IR.

**Why a run and not more scalars:** a pair encodes a depth in its shape, so
each further depth would be another field on every instruction, another
parameter on every emitter and another branch in the verifier and the
backend. A run makes depth data. It is also what makes an aggregate variant
payload and an aggregate array element expressible without inventing a
second nesting mechanism beside this one.

**Pinned by** the lowering, verifier and backend public seams; the malformed
case `Path_Step_Below_A_Scalar_Leaf`; and the generated IR record, which now
names the base field and every step of every field operation.

### D119 — Ordinary nesting has no depth

**The tour said** that a struct's field may have any type a binding may have
[0670] [0750], and that member selection chains as `a.b.c` [0420] [1820]. D86
admitted exactly one named ordinary child and refused a child that had one of
its own, because the pair of identities D88--D90 carried could not say what a
third selection reached.

**Chosen:** an ordinary struct field may be an ordinary struct however deeply
that composes. Layout is unchanged: a field's extent is its own body's
already-computed layout, so the recursion is the one the checker already does
over declarations. A scalar leaf and a fixed-array leaf are a value and a
place at any depth, and a fixed-array leaf keeps every contextual assignment
form it has at depth one.

Definite assignment keeps one fact per part, named by D118's run rather than
by a parent and a child. A fact about a part follows from a fact about
anything containing it, which is now "a fact named by a shorter run with the
same steps"; branch joins intersect the runs and apply that same containment
rule from either side. A whole child at depth two or more is D120's, and a
variant part inside a child is D121's; both remain refused here.

Lowering resolves a selection chain once, into the name it started from, the
first selection's field and D118's run of the rest. The verifier walks a
nested field run recursively, under a budget the vector's own length gives, so
a run that named itself is refused rather than followed.

**Why no depth limit:** every limit here would be an implementation's, not the
language's — the tour writes `a.b.c` and stops. The one thing a depth costs is
that the flow stage can no longer pack a path into an integer, which it did
with a stride that would have overflowed silently at a field count and depth
no rule forbids.

**Pinned by** `positive/deep-nested-struct-leaves`,
`negative/deep-nested-leaf-unassigned`, the generated IR record, and
`runtime/deep-nested-struct-leaves` on Linux x86-64.

### D120 — A whole ordinary child is a place at any depth

**The tour said** that a whole ordinary struct may be zeroed, constructed and
copied [0540] [0700] [0710]. D91 gave those forms to one named child of a
parent; D119 then let a child hold a child, which left the deeper one with
leaves but no whole.

**Chosen:** `a.b.c…` naming an ordinary child is a contextual aggregate
assignment place at any depth, with exactly D91's forms: `zeroed`, a matching
labelled literal or nominal construction, and a storage copy from the same
nominal type reached by any chain. An explicitly typed local may be
initialized from one, and a local may infer its nominal body from one. A
nominal construction whose body has an ordinary child is admitted, because the
labelled child value is already checked against that child's own body.

The root binding decides mutability, and the child remains no general
expression value: no operand and no discard. D132 later gives a module
initializer the same contextual child forms by recursively folding their
static image rather than turning the child into a general value.

Lowering keeps one notion of place — a base field and D118's run below it —
and descends into it. A literal fills a place; a copy visits the same fields
in [0750]'s order one place deeper on each side; `zeroed` is one whole-part
clear whose extent the backend derives from the shape the run reaches. The
verifier recognises a whole child at the end of a run, not only at the base
field.

**Why not a general child value:** D91's argument is unchanged by depth. Every
accepted form still has known destination storage and commits in [0410]'s
order, and a first-class child value would need a representation, an ABI rule
and an expression lifetime that none of these assignments wants.

**Pinned by** `positive/deep-nested-struct-children`,
`negative/deep-nested-child-copy-unassigned`,
`positive/module-struct-image-with-a-child`, the generated IR record, and
`runtime/deep-nested-struct-children` on Linux x86-64.

### D121 — A variant case payload may be an ordinary struct

**The tour said** that a variant part's cases carry payload fields [0680] and
that a struct's field may have any type a binding may have [0670] [0750]. D74
laid a payload out from scalar and fixed-array leaves alone, because the pair
of identities every payload operation carried had no room for a third.

**Chosen:** a case payload field may be an ordinary struct. It takes the same
contextual values a labelled ordinary child takes — `zeroed`, a matching
labelled literal or nominal construction, and a copy from storage of the same
nominal type — and a match arm's positional alias for it names the whole
struct, so its fields are read and written the way any struct's are.

The payload is reached by D118's run: the case a step names is what says the
run it indexes is a payload run rather than an ordinary field run. No opcode
is added, and the two payload operations D76/D78 introduced keep their exact
meaning for a scalar leaf. A payload struct that has a variant part of its own
is refused. D132 later admits an ordinary-struct payload in a module image by
recursively folding that payload's own image.

**Why the alias is a struct and not a second kind of binding:** D78's alias
already denotes storage; making it denote a struct's storage rather than a
scalar's changes what it names and nothing about what a name is. Every
selection below it is then an ordinary step of the same run.

**Pinned by** `positive/variant-struct-payload`,
`negative/variant-struct-payload-mismatch`,
`positive/variant-inside-an-element`, the generated IR
record, and `runtime/variant-struct-payloads` on Linux x86-64.

### D122 — A fixed array's element may be an ordinary struct

**The tour said** that a fixed array is its element repeated [0520], that a
struct's field may have any type a binding may have [0670] [0750], and it
writes `w.items[i].x` and `xs[i].items` outright. D17 made an array's identity
its length and its element, and every stage carried that element as one of
[1790]'s scalar types.

**Chosen:** [0520]'s element may be an ordinary struct. Its extent is that
struct's own padded layout repeated, so an array adds nothing but the
repetition, and an array of one is storage anywhere an array of a scalar is: a
struct field, a local, and a module binding. `zeroed` clears the whole extent,
and two arrays of the same length and the same element copy whole.

`a[i].f` selects a leaf of an element and is a value and a place. [1820]'s
`indexed` accordingly derives a selection after an index, which is what the
tour already writes; the parser's by-name refusal of that spelling is retired.
Definite assignment keeps a fact per known position _and_ per run inside the
element, so writing `a[0].x` establishes exactly that leaf and reading it asks
for exactly that fact — with a fact about the whole element, or about anything
containing the array, covering it.

The neutral shape carries the element as a run of exactly one, built by
D118/D119's own machinery; a scalar element stays where it was, so no array
that existed before D122 changes. An indexed operation carries a second run,
applied after the scaled index, which is the only new thing an instruction
holds: an index is a value and cannot be a step. Two shapes are the same shape
when they hold the same thing, not when their runs start in the same place.

Two forms stayed refused and named this item: a whole element as a value or a
place, and an array whose element is a struct with a variant part. D127 admits
both, by making a known index one step of the run rather than a value.

**Pinned by** `positive/array-of-structs`,
`positive/computed-whole-array-elements`,
`negative/selection-from-a-scalar-element`, the malformed case
`Element_Path_Below_A_Scalar_Element`, the generated IR record, and
`runtime/array-of-structs` on Linux x86-64.

### D123 — Infallible function values use one recursive carrier rule

**The tour said** that a function is an ordinary code-address value [0870]
[1000], that callbacks carry state explicitly because anonymous functions do
not capture [1010], and that parameters and named results carry ordinary values
[0900] [0930]. It did not say how a function type nested in another signature
keeps its identity, which module images can hold one, or which scope a
no-capture body can see.

**Chosen:** a function may be an infallible parameter or named result. A nested
function position contains another structural signature descriptor; agreement
recurses through it, still ignoring labels and source sites. At the internal
ABI boundary every function value occupies one `usize`-sized code-address
carrier. It therefore uses the existing register/stack position, scalar return
register and named-result slot without adding an ABI parameter or flattening
its own parameters. Aggregate results called through such a carrier retain
D106's hidden destination unchanged.

A typed or inferred module binding may have a static function value. Its image
must resolve through module function bindings to one declared or anonymous
routine; there is no implicit zero code address, and a static chain that returns
to itself is refused. Mutable module and local bindings use the same verified
load, store and indirect-call operations.

An anonymous function is a separate no-capture routine. Its signature scope
encloses the module rather than the lexical expression scope, so it can use
module declarations, its own parameters, named result and body locals, but no
parameter, return or local of an enclosing routine. Lowering allocates every
anonymous routine item before filling any routine, after declaration items and
in source then syntax post-order. Its code address names that deterministic
item; the x86-64 backend gives an undeclared item a deterministic assembler-local
symbol.

Declared error sets remain absent from this increment and arrive at D130.
Function-valued struct fields are not enabled by this decision alone; D131
composes this carrier with the aggregate storage family.

**Why one recursive descriptor and one carrier:** flattening a callback's own
signature into its caller would make source parameter count depend on nesting
and would break the existing stack and hidden-result convention. Treating a
module relocation or anonymous item as its type would again make one possible
target the authority D117 rejected. A recursive language descriptor preserves
structural checking while one code address preserves the established ABI.

**Pinned by** the syntax, no-capture resolution, checking and flow walks;
recursive checking and IR descriptors; function parameter/result slots, static
function datum targets, calls and verifier malformed cases; deterministic
anonymous routine items and x86-64 local symbols; the generated lexical and IR
records through `positive/infallible-function-values`; the negative fixtures
`anonymous-function-captures-local`, `function-parameter-signature-mismatch`,
`function-result-signature-mismatch`, `function-result-unassigned`,
`module-function-replacement-signature-mismatch`,
`module-function-without-image` and `module-function-image-cycle`; and
`runtime/infallible-function-values` on
Linux x86-64.

### D124 — Control values distinguish fallthrough from return-compatible edges

**The tour said** that a block has the value of its last expression [1080],
that an arm which leaves needs no placeholder [1030], and that every named
return is assigned before return [0930]. It did not say which flow facts survive
when value-producing and returning arms meet, nor how one rule covers an `if`,
an exhaustive `match`, and a bare block without believing a condition [1910].

**Chosen:** `if`, exhaustive `match`, and bare `begin` blocks are expressions as
well as their existing statement forms. A block is its source-ordered statement
run followed by an optional final expression. In a value context, every
reachable edge that falls through must produce that final value. An edge that
returns is compatible without producing one, but [0930] still requires the
function's named result on that edge. A reached `if` with no `else` has an
untaken fallthrough edge and therefore cannot produce a value there.

Every control edge carries the independent facts `Falls_Through` and `Returns`.
Only states on fallthrough edges participate in a definite-assignment join; a
returned edge cannot lend its assignments to a surviving sibling. A guarded
return carries both facts because its untaken edge continues. Short-circuit
`and` and `or` retain the left-hand skip edge when the right returns. The same
walk applies when control appears inside a condition, index, operand, argument,
assignment value, direct function result, or another control block, preserving
[0410]'s source order and stopping later actions after an unconditional return.

One surrounding context reaches every fallthrough answer. It includes the
complete fixed-array element body and extent, nominal aggregate body or D123
recursive function signature, not merely the broad `Fixed_Array`, `Aggregate`
or function-value kind. Without a surrounding context the first written answer
supplies that complete shape and every other answer must agree. Each arm and
bare block retains [1840]'s own lexical scope. This decision introduces no loop
syntax or loop edge: R4.10 still owns `loop`, `while`, `for`, `break`, and
`continue`.

**Why two facts rather than one exited Boolean:** one Boolean cannot distinguish
"no path reaches the join" from "this construct may return but also has a
continuing edge". Treating either as the other loses guarded-return assignment
facts or admits a value-less fallthrough. Explicit facts make both the value
obligation and the definite-assignment merge consequences of the same edge.

**The alternative:** give every syntactic arm a value regardless of whether it
returns, or merge assignment states before removing returned edges. The first
invents unreachable placeholders and contradicts [1030]; the second lets one
path prove a read on another. Both were declined.

**Pinned by** `positive/control-expression-values`,
`negative/if-expression-missing-else`,
`negative/control-expression-fallthrough-without-value`,
`negative/control-expression-branch-type-mismatch`,
`negative/control-expression-function-signature-mismatch`,
`negative/control-expression-early-return-needs-result`,
`negative/control-expression-fallthrough-does-not-borrow-returned-facts`,
`negative/bare-block-unclosed`, `negative/bare-block-scope-does-not-leak`,
`runtime/match-expressions-produce-values`,
`runtime/control-expression-function-values`, and
`runtime/control-expression-edges-keep-source-order` on Linux x86-64, together
with the parser, checker, flow and IR public-seam cases.

### D125 — A control join writes storage owned by its consumer

**The tour said** that a branch-chosen value has one joined origin [0840], while
R2.20's aggregate decisions keep layout out of checked shapes and D106 returns
aggregates through caller-owned storage. It did not supply a target-neutral
value carrier for a join, especially when an array or struct is not one scalar
IR value.

**Chosen:** the operation consuming a control expression owns its join storage.
A scalar control uses one unnamed scalar slot and loads it after all fallthrough
edges meet. A function value uses the same code-address carrier in a slot that
retains D123's signature. A fixed array or enabled aggregate uses a caller-owned
slot carrying its complete neutral shape; each selected fallthrough block fills
that same destination. A typed binding, assignment, named result, or aggregate
call result can be the destination directly. An argument, explicit discard, or
other context with no named destination receives one fresh shaped temporary for
the duration of that operation.

No branch-local pseudo-value, aggregate SSA value, target offset, byte extent,
or implicit full-size copy crosses the join. An early return writes no joined
answer and follows D116's active named-result exit. The verifier sees ordinary
stores, copies, addresses, branches and terminators over declared slot shapes;
the backend alone lays out a selected target's cell. Linux x86-64 consequently
passes the one joined aggregate address after the join and derives every copy
extent from target facts.

**Why the consumer owns it:** choosing storage before branching makes the
hidden lifetime and cost belong to the source operation that needs the value,
allows contextual literals and aggregate-returning calls to construct in
place, and reuses ordinary scalar, function and stored-shape representations
without making target layout a checker concern.

**The alternative:** introduce phi values for scalars and a separate aggregate
value graph, or construct one full temporary per arm and copy again at the
join. The first freezes two representations and needs target-sized aggregate
values; the second hides branch-count-dependent storage and copies. Both were
declined.

**Pinned by** `positive/control-expression-values`,
`runtime/control-expression-aggregate-joins` and
`runtime/control-expression-function-values` on Linux x86-64, together with
the IR, lowering, verifier and backend public-seam cases and the generated IR
record.

### D126 — A variant part is reached by a run like any other part

**The tour said** that a struct's field may have any type a binding may have
[0670] [0750], and that a variant part is one of the things a struct declares
[0680]. D86--D122 admitted an ordinary struct as a field, a variant payload
and an array element, but only when it had no variant part of its own: every
variant operation named its part by one base field, and a part below that
field had no way to be said.

**Chosen:** the five variant operations — select, tag load, payload load,
payload store and whole-part copy — carry D118's run down to the part, exactly
as every other operation already does. An empty run is D74's variant part of
the storage itself, which is where all five started. A copy names each
endpoint separately, for the reason an array copy does: the two parts have one
shape but need not sit in the same place.

So a struct with a variant part may be an ordinary child, and may be a variant
payload; a match subject may be any chain that reaches a variant part,
including one rooted at D121's payload alias; and the arm's own aliases carry
that run with them.

Composing a run and a selected case fixes their order. The run reaches the
part, and the case is then selected _inside_ the part, so the payload offset
is the reached part's own and not the base field's. A run _below_ a selected
payload is a `Case_Index` step of the same run, so nothing is ever added after
the payload and one order suffices.

An array element was still refused here: a run reaches a part by identities,
and an index is a value. D127 makes a known index one of those identities and
admits it there.

**Pinned by** `positive/nested-variant-parts`,
`positive/variant-inside-an-element`, the malformed case
`Variant_Path_Reaches_A_Scalar`, the generated IR record, and
`runtime/nested-variant-parts` on Linux x86-64.

### D127 — A known index is an identity, so an element is a place

**The tour said** that a fixed array is its element repeated [0520], that a
whole struct may be zeroed, constructed and copied [0540] [0700] [0710], and
it writes `w.items[i].x` outright. D122 gave an array an ordinary struct
element and made a leaf of one a value and a place, but left the whole element
neither, and refused an element with a variant part: every whole-part and
variant operation reaches its part by identities, and an index is a value.

**Chosen:** an index the compiler knows is one of those identities, so it is
one step of D118's run. A whole array element at a known position is a value
and a place wherever a whole ordinary child is one: `zeroed`, a labelled
literal or nominal construction, a copy from storage of the same nominal type,
a call's destination, and a call argument. An array whose element is a struct
with a variant part follows, because the run now reaches the part.

Where a run may start is one question, asked once. Base zero with no run is
the storage itself; base zero with a run is whole array storage the run starts
at; a positive base is [0750]'s field of a struct, or [0520]'s element
position of an array. A field operation names one part and then a run below
it, so a run that starts at whole array storage gives its first step to the
part — which is what a known index of a scalar array has always meant. That
one promotion is the only place the two conventions meet.

This decision initially left a computed index refused because reaching a whole
element needed an address the contextual forms did not form. D134 closes that
boundary with a checked, unspellable storage address while leaving known
positions as the identity steps chosen here.

**Why not a new opcode or operand:** an indexed operation already carries a
scaled index and a run; a known position needs neither, because it is a
position. Adding a second element operand would make every consumer ask which
of two ways an element was named, and the neutral IR would hold a number that
is a value in one form and an identity in the other.

**The alternatives:** admit a computed index by forming an address, keep the
whole element refused and enable only the variant element, or give an element
its own opcode. The first crosses the boundary that keeps every contextual
form addressable by identity; the second leaves the array's own whole form the
last one missing; the third duplicates D118's run at one depth.

**Pinned by** `positive/whole-array-elements`,
`positive/variant-inside-an-element`,
`positive/computed-whole-array-elements`,
`positive/variant-part-at-a-computed-index`, the malformed case
`Whole_Element_Beyond_The_Array`, the generated IR record, and
`runtime/whole-array-elements` and `runtime/variant-inside-an-element` on
Linux x86-64.

### D128 — Multiple named returns form one anonymous structural aggregate

**The tour said** that a function may have multiple named returns [0920], that
the return list is an anonymous struct bound whole or destructured by name
[0990], and that every named return is assigned before an exit [0930]. It did
not say whether result labels participate in function-value agreement, how the
anonymous shape is laid out and transported, or how partial destructuring and
control-expression joins retain it.

**Chosen:** a non-`none` return list contains one or more named positions. One
position keeps the existing result type and carrier. Two or more positions form
one anonymous structural aggregate whose fields are those positions in source
order. Its value shape includes each field name and complete type, recursively
including nominal aggregates, fixed arrays and D123 function signatures. The
padded aggregate must fit the selected target. It has no source type spelling
and no nominal declaration identity.

Function signature agreement compares the ordered result _types_ and ignores
result labels, as [1000] requires. A call through a stored function therefore
uses the labels written by that value's static function type while the runtime
positions remain compatible. Outside function-signature agreement, two whole
anonymous result values agree only when their ordered names and complete field
types agree.

The internal ABI transports every multiple result as one aggregate. The caller
supplies D106's one hidden destination, the callee owns one independently shaped
result slot, and each source named return writes its declaration-order field.
Every early or final leave performs the existing complete aggregate copy to the
caller. Direct and indirect calls, stack arguments and aggregate fields within
the result add no second convention. A function-valued field is a `usize`
carrier that retains its nested signature; aggregate-shaped field copies reuse
the compact verified storage-copy operation.

A whole result can initialize or update an inferred local, cross D125's one
consumer-owned control join, be read by field, or be destructured. Destructuring
evaluates the source once and binds fields by name in any order. `field` keeps
the field name as the local, `field: local` renames it, `field: _` ignores that
field, and one bare `_` explicitly ignores every unbound field. Omission is
also legal. Unknown and repeated fields use the ordinary field diagnostics;
new locals enter scope only after the source is resolved and obey [1850].

Definite assignment tracks the named return declarations independently. Every
reachable early return and final fallthrough requires every one; a direct
expression body fills the complete anonymous aggregate on its fallthrough edge.
A returning control edge supplies no joined aggregate but still proves all
named returns, exactly as D124 requires.

**Why one aggregate rather than one hidden pointer or register per return:** the
latter makes source arity rewrite the ABI and duplicates D106's caller-storage
rule. One structural image gives whole binding, field selection, destructuring
and control joins the same value while leaving target classification to R4.40.
Making the result nominal would invent a declaration the source never wrote and
would contradict [0990].

**Pinned by** the return-list and destructuring parser/resolver/checker/flow
walks; ordered checking and IR signature result runs; caller-owned result slots,
direct and indirect lowering, function-valued result fields, verifier malformed
result-slot cases and x86-64 aggregate copies; `positive/multiple-named-returns`;
`negative/function-type-return-name-duplicate`,
`multiple-return-name-duplicate`, `multiple-return-unassigned`,
`multiple-result-function-signature-mismatch`,
`result-aggregate-assignment-name-mismatch`,
`result-destructure-duplicate-field`, `result-destructure-local-name-duplicate`,
`result-destructure-needs-multiple`, `result-destructure-unknown-field` and
`control-result-field-name-mismatch`;
the generated lexical and IR records; and `runtime/multiple-named-returns` on
Linux x86-64.

### D129 — A cleanup is selected by the edge that leaves its lexical block

**The tour said** that `defer` runs at the end of its block in reverse order,
that its call is evaluated where it runs rather than where it was written, and
that `undo` is the same machinery selected only by failure [1100] [1110]. It
did not say whether a final block value precedes cleanup, how an early return
crosses nested blocks, which definite-assignment state the delayed reads use,
or what neutral control fact distinguishes a future failure from a trap.

**Chosen:** reaching `defer call(...)` registers that call in the current
lexical block and performs no part of it. The callee and every argument are
evaluated in [0410]'s source order only when the entry runs, so an indirect
callee and a named place observe their values at that later point. Resolution
is not delayed: the call's names bind in [1840]'s source-ordered scope where
the statement is written, and a later declaration is not visible backwards.

Each active block owns a cleanup frame. On ordinary fallthrough its optional
final expression first fills D125's consumer-owned value storage, then that
frame's reached entries run in reverse registration order, and only then does
the edge reach its surrounding join. A successful `return` runs every reached
entry from the innermost active frame outward, reverse within each frame,
before D116's final result copy or scalar leave. Thus a defer written after a
guarded return is absent from the guard's taken edge, while an inner arm or
bare-block defer runs before an outer one. An entry is removed before its call
runs: if a control expression in that call returns, the still-pending entries
run exactly once and the entry already in progress is not entered again.

Definite assignment is checked at those execution points, not at registration.
A value may therefore be assigned after the defer and before every applicable
exit, and a cleanup argument may itself assign one or more named results before
the successful return completes. Conversely, one earlier return edge on which
a delayed read is unassigned is refused even when the normal end assigns it.

The neutral selector has five edge kinds: ordinary fallthrough, successful
return, failure propagation, structured transfer, and trap stop. A deferred
call applies to every language edge that unwinds a block and never to a trap;
a failure cleanup applies only to failure propagation. D133 enables that
failure-only policy as [1110]'s `undo`, while R4.10 still owns every loop
transfer. No trap unwinds, whether it occurs in the body, in a final expression,
or while a cleanup call is running.

Cleanup has no target-specific IR form. Once selected, a call lowers through
the existing direct or indirect convention, including register and stack
arguments. Fixed-array and enabled aggregate arguments retain their ordinary
by-value transport, and a discarded aggregate result receives one caller-owned
shaped temporary through completion. The verifier consequently sees only
ordinary calls, storage and terminators; the backend owns neither a cleanup
stack nor unwind policy.

**The alternative:** capture the callee and arguments when the statement is
reached, which is Go's useful rule but contradicts [1100]'s explicit late read;
or introduce a runtime cleanup stack and target-aware unwind instruction.
Capturing changes which value a mutable place denotes and can consume it too
early. A runtime stack makes registration observable work, duplicates the
lexical control graph already known to lowering, and would force freestanding
targets to carry unwind machinery for traps the language says do not unwind.
Both were declined.

**Pinned by** `positive/defer-evaluates-at-exit`,
`negative/defer-cannot-see-later-local`,
`negative/defer-read-not-assigned-on-return`,
`negative/defer-needs-call`,
`runtime/defer-cleanups-follow-control-edges`,
`runtime/defer-call-shapes`, and `runtime/defer-does-not-unwind-traps` on Linux
x86-64, together with the parser, checker/flow, IR policy, lowering/verifier and
x86 backend public-seam cases and the generated IR record.

### D130 — Errors are an orthogonal atom outcome, not a second result

**The tour said** that errors are payload-free atoms in one dedicated register,
that `try` propagates them, and that call-site `else` handles them [0940]
[0960] [1030]. It did not fix atom-set identity, recursive private inference,
the success sentinel, the neutral IR carrier, or how scalar and aggregate
results coexist with that register.

**Chosen:** [1980]. Atom and error sets are structural sets of declaration
identities. A failing signature adds one orthogonal outcome to its existing
successful result rather than wrapping, replacing, or adding a named return.
Concrete sets are part of recursive function-type agreement; private `! ...`
is the least fixed point of local failures and tried callees, including
mutually recursive routines. Every first-class or public signature stays
concrete.

Neutral IR carries source atom identities and set metadata, one call failure
slot, a semantic `Failure_Test`, and a distinct `Fail` terminator. A recovery
joins only its fallthrough value with the success value; `return` and `fail`
edges need no placeholder. The malformed-IR verifier checks set partitions,
membership, widening, signatures, failure slots, and failure exits before a
backend can assign bits.

Linux x86-64 uses dense nonzero 32-bit atom codes in declaration-identity order
and `%r10d` as the dedicated call-failure carrier; zero means success. Ordinary
atoms still use normal argument positions and `%eax` results. Scalar/function
results remain in `%rax`, aggregate results remain in caller-owned storage, and
neither direct nor indirect failing calls consume a source ABI position.

**Why orthogonal rather than a result union:** a `none` function may fail, an
aggregate result already has independent caller-owned lifetime, and wrapping
every result would change every value convention and indirect signature merely
to represent an outcome the tour already assigns its own register. A hidden
out-parameter would instead consume an argument position and make the declared
channel alias ordinary storage. Both alternatives erase the one visible
mechanism [0940] chose.

**Pinned by** `positive/atoms-and-error-signatures`, the negative declared-error
fixtures, `runtime/atom-values-cross-the-abi`,
`runtime/declared-errors-direct-and-inferred`,
`runtime/declared-errors-indirect-abi`, the malformed-error verifier case, and
the generated lexical, construct and IR records.

### D131 — A function-valued field is one signature-carrying address leaf

**The tour said** that a function is an ordinary code-address value [0870]
[1000], that a struct field may have any ordinary type [0670], and illustrated
a callback as a function field plus explicit state [1000]. D117 and D123 kept
function-valued struct fields as the remaining R2.30 storage form while the
aggregate path and image carriers were still being established.

**Chosen:** an ordinary struct field or variant payload field may have a
concrete function type. Its runtime representation is D123's one `usize` code
address, while its complete recursive descriptor — including declared errors —
remains target-neutral type evidence on the checked and IR field shape.
Construction, individual assignment, whole-struct copy, aggregate parameters
and results, nested ordinary children, variant payload aliases, and arrays
whose element is such a struct all reuse their existing storage and path
operations. This does not separately enable a fixed array whose element is a
function value.

A selection of that field is an ordinary function value and a call callee.
The complete callee selection, including a computed array index, is evaluated
and checked for definite assignment before any argument. Every call through a
field is indirect at runtime even when its current image names a declared
routine; direct calls to declarations keep their existing instruction.
Replacing a mutable field requires structural signature agreement, and the
root binding still decides whether the field is writable.

A function address has no all-zero value [0540]. A struct, active variant case,
or nonempty array of structs containing one therefore has a zero image only
when every field selected by that zero image does. An omitted module image,
whole `zeroed`, or trailing `of zeroed` cannot invent a null callback. A static
module struct or selected payload may instead carry a declared function, a
no-capture anonymous function, or a static function-binding chain. Neutral IR
records one routine relocation on that scalar field; whole module-image copies
copy the relocation into distinct storage. The verifier proves the relocation
target and every field/element/payload load and store against the field's
recursive descriptor before the Linux x86-64 backend emits a symbol or an
indirect call.

**Why retain a descriptor beside one machine word:** flattening the callback's
own parameters into its containing struct would make layout depend on what the
address can be called with rather than what the value occupies. Erasing the
descriptor would instead let a whole aggregate copy or an indexed field load
turn a deterministic type mismatch into an indirect ABI mismatch. The same
carrier-plus-descriptor rule at every storage depth is D123 composed with
D118's path rather than a field-specific calling convention.

**Pinned by** `positive/function-valued-struct-fields`;
`negative/function-field-assignment-signature-mismatch`,
`function-field-cannot-be-filled-with-zeroed`,
`function-field-construction-signature-mismatch`,
`function-field-error-signature-mismatch`, `function-field-has-no-zero-image`,
`function-field-unassigned`, `function-variant-payload-signature-mismatch`, and
`module-function-field-without-image`; the malformed aggregate-image verifier
case; the generated construct, lexical and IR records; and
`runtime/function-valued-struct-fields` on Linux x86-64.

### D132 — A folded aggregate image recursively contains aggregate fields

**The tour said** that a module binding already has its value before the entry
point [1460], that a struct literal takes its nominal context from its use
[0710], and that fields retain source order while each target supplies widths,
alignment and padding [0750]. D120 admitted an ordinary child as a contextual
runtime value and D121 did the same for an ordinary-struct variant payload, but
both kept the corresponding module image refused because D67/D81 could carry
only scalar and compact fixed-array leaves.

**Chosen:** a labelled or nominal module construction may give an ordinary
child, at any depth, exactly D120's contextual forms: `zeroed`, a matching
labelled or nominal construction, a direct module struct image, or one directly
selected ordinary child of matching nominal type. A selected variant case may
give an ordinary-struct payload the same forms. Written and inferred module
constructions share the rule. Type aliases preserve the declaration that owns
the child, and every copied image owns distinct storage.

These forms remain contextual. They do not make a child or payload a general
operand, discard or independently evaluated aggregate expression. An omitted
field, `of zeroed`, explicit `zeroed`, or a copied absent source has the absent
all-zero image. A written nested construction remains a written image even
when all of its folds are zero, as D24 and D66 require.

The target-neutral aggregate image keeps D66's flat top-level fold run and
extends D67/D81's descriptor run with `Nested`. Its `Offset` and `Count` select
one contiguous declaration-order run of direct child descriptors after the
top-level descriptors. A child descriptor may itself be `Nested` or
`Selected`; scalar descendants carry one fold or D131 routine relocation in
their descriptor, while fixed-array descendants retain `Absent`, `Finite`,
`Repeated` or `Hybrid` and share the item's existing fold run. `Selected` and `Nested` offsets count
descriptors; finite and hybrid offsets count folds. Neither run contains a
target width, byte offset, padding byte or host representation.

Direct image names and selected-child sources join the existing
per-declaration static-image graph. Forward references and aliases are followed
before an image is gathered. A path that returns to a declaration reports
L0305 once, including a cycle that alternates ordinary-child selections,
variant payloads and whole aggregate aliases; invalid members or nominal
mismatches retain their contextual owner and add no graph diagnostic.

The verifier first proves both item-owned vector partitions. It then walks the
recursive descriptor tree with monotonically increasing descriptor and fold
cursors: each direct-child count must match its neutral shape, every offset is
canonical and in range, every descriptor is consumed once, every ordinary
scalar or compact array fold fits the selected target, and every D131 routine
relocation agrees with its recursive signature. A nested form on another field
kind, a skipped or backward descriptor run, an unconsumed descendant, a wrong
child count, and a 32-bit-only range failure are ordinary release-build IR
faults before a backend accessor runs.

The backend recursively replays the same neutral field and selected-payload
shapes used for runtime layout. It writes scalar folds or routine symbols at
this target's widths, emits compact array forms, and derives every internal gap, inactive variant
tail and aggregate tail as zero padding. Thus one image may contain a `.long`
`usize` child and occupy 20 bytes under the synthetic 32-bit facts while the
same IR contains a `.quad` child and occupies 40 bytes on Linux x86-64. No
startup code, target image blob or recursive aggregate SSA value is introduced.

A nonzero module array image whose element is an ordinary struct remains the
separate array-literal value boundary: D132 adds recursion at ordinary fields
and ordinary variant payloads, not a per-element aggregate image carrier.

**Why one recursive descriptor run:** flattening child leaves into their parent
would erase nominal boundaries and variant ownership; target byte blobs would
duplicate images per target; startup stores would contradict [1460]; and one
new vector per depth would encode an implementation limit. The existing
item-owned descriptor partition already represents a recursive shape once an
ordinary child can point into it.

**Pinned by** `positive/module-struct-image-with-a-child`,
`positive/recursive-module-images`,
`negative/recursive-module-image-cycle`,
`negative/recursive-module-image-nominal-mismatch`, the recursive aggregate
malformed-image verifier cases, the lowering and 32-/64-bit backend seams, the
generated lexical and IR records, and
`runtime/recursive-module-images-are-laid-out-and-distinct` on Linux x86-64.

### D133 — Undo is selected only while declared failure leaves its block

**The tour said** that `undo` is registered lexically, runs in reverse order
only when failure leaves its block, includes a failed `try` and failure from a
deeper call, and excludes return, transfer and panic [1110]. It did not say how
a caller's recovery divides the failing callee from its own block, how undo and
defer registrations interleave, which state delayed arguments read, or how the
failure atom survives calls made while unwinding.

**Chosen:** reaching `undo call(...)` appends a failure-only entry to D129's
current lexical cleanup frame. It resolves the call immediately in source
order but evaluates neither its callee nor any argument. The entry becomes
active only after the statement is reached. When it is selected, its indirect
callee and arguments are evaluated late, left to right, from the state at that
failure edge, and the entry is removed before evaluation begins.

A direct or taken guarded `fail`, or a `try` whose call reports failure,
creates a failure-propagation edge. The latter includes an atom produced by any
depth of failing calls. Such an edge does not join a selected `if`, exhaustive
`match`, or bare `begin` block: it runs reached entries in every lexical frame
it leaves, innermost frame first. Within one frame all cleanup registrations
remain in one stack. Reverse registration order selects every applicable
entry, so defer and undo calls interleave on failure; normal fallthrough and a
successful return select only defer. A caller's call-site `else` handles the
failure without leaving the caller's block and therefore does not select that
block's undo entries. Undo entries in the failing callee have already run as
the failure left the callee.

Undo never applies to ordinary fallthrough, successful return, structured
transfer, or trap stop. No trap is converted to declared failure and no trap
unwinds, including one raised while evaluating a cleanup. R4.10 still owns
loops and their transfers, so this decision enables none of them.

Definite assignment uses only the failure edges on which an undo call actually
runs. A delayed argument may consequently be unassigned on every normal,
successful-return or locally recovered edge, but must be assigned on each
propagating failure edge that reaches its registration. The failing atom is
formed and stored before cleanup begins, then reloaded for the eventual failure
terminator after all normally completing applicable calls. Cleanup evaluation
cannot accidentally replace the failure being propagated.

Undo introduces no target-specific IR or runtime registration. A selected
entry lowers as the same ordinary direct or indirect call as defer, including
register and stack arguments, fixed-array and enabled aggregate values, and
function-valued callees. A discarded fixed-array, nominal aggregate, or
anonymous multiple-result aggregate receives an ordinary caller-owned shaped
temporary. The verifier therefore checks the resulting calls, storage,
failure carrier and terminator under existing rules, and the x86 backend owns
only their established calling convention.

**The alternatives:** keep a second undo stack, which would place every undo
before or after every defer instead of preserving lexical reverse order; run
undo for every non-normal exit, which would make return a failure and could not
distinguish a locally recovered call; or capture the callee and arguments at
registration. The first changes source order, the second erases the declared
failure edge [0970], and the third contradicts [1110]'s delayed compensating
action. All were declined.

**Pinned by** `positive/undo-evaluates-on-failure`,
`negative/undo-cannot-see-later-local`, `negative/undo-needs-call`,
`negative/undo-read-not-assigned-on-failure`,
`runtime/undo-cleanups-follow-failure-edges`, `runtime/undo-call-shapes`, and
`runtime/undo-does-not-unwind-traps` on Linux x86-64, together with the parser,
checker/flow, cleanup-policy, lowering/verifier and x86 backend public-seam
cases and the generated lexical, construct and IR records.

### D134 — A computed aggregate element has a checked internal address

**The tour said** that an array is a value and assignment copies [0520], that
an enabled array element is a place [1810], that indexing checks the length
before computing an address [0580] [1950], and that evaluation order is fixed
[0410]. It never distinguishes a whole aggregate element at a known index from
one at a computed index. D127 made the known position an identity step but left
the computed form refused because the contextual aggregate operations then had
no carrier for its address.

**Chosen:** every whole aggregate-element context D127 admits also accepts a
computed index: typed and inferred local copies, whole assignment from
`zeroed`, construction, storage, calls or non-loop control values, aggregate
arguments and named results, and a variant part inside the element. Aggregate
parameters and named results are ordinary storage endpoints in those same
copies. A chain may contain more than one computed index; each is evaluated
from the root outward, exactly once.

Lowering evaluates and bounds-checks a computed destination before evaluating
its assigned value. It forms an internal storage address carrying the complete
target-neutral shape reached, stores that carrier in an unnamed `usize` frame
slot when it must cross a control edge, and applies the existing contextual
aggregate operations through it. The address is unspellable in Landin source,
is never a source pointer or alias, and creates no new source type or ABI
position. Known indexes remain D127's identity steps and introduce no runtime
operand.

The verifier proves that an indexed address starts at fixed-array storage, that
its operand is `usize`, that the reached element shape agrees with the address
slot, and that an arbitrary integer cannot substitute for it. The Linux x86-64
backend performs the bounds check before multiplying by the target-derived
padded element extent and adding the result to the target-derived storage
base. It derives every later child, array and variant offset from the neutral
shape as before. D22's definite-assignment rule is unchanged: a computed read
of tracked local storage needs the whole-array fact, and a computed write
establishes no particular element fact.

A computed variant subject is copied once into independent shaped storage
before its exhaustive tag cascade, so payload aliases of scalar, fixed-array
or ordinary-aggregate shape all refer to that one subject value. A computed
variant destination preserves its siblings in shaped storage while its selected
case is formed in source order, then writes the complete element back. Calls
registered by `defer` or `undo` use the ordinary complete-call parser and may
therefore delay a selected function-field callee as well as a direct or locally
stored function value.

**Why an internal checked address:** expanding one operation per scalar leaf
cannot represent a target-sized fixed-array field compactly; exposing a source
pointer would enable aliasing and pointer syntax R2.50 owns; and one special
computed-element opcode per construction, copy, call, control or variant form
would duplicate the contextual operation family. One verified shaped address
lets those existing forms compose without freezing target offsets in IR.

**The alternatives:** keep D127's computed refusal, materialise every computed
element in a temporary and never address the original, or make every subobject
path carry interleaved runtime values. The first contradicts [0520] and [1810]
after every other element context exists. The second cannot update the original
place without another carrier. The third would put block-local values into the
shared identity path and make every existing path consumer distinguish two
meanings. All were declined.

**Pinned by** `positive/computed-whole-array-elements`,
`positive/variant-part-at-a-computed-index`, the malformed runtime-address
verifier case, the generated IR record, and
`runtime/computed-aggregate-elements`, `runtime/r230-composition`, and
`runtime/r230-composition-trap` on Linux x86-64.

### D135 — Parameterized type declarations collect their formals before their bodies

**The tour said** that type and fixed parameters are compile-time [1290], that
a type takes them through its own declaration rather than a function [1350],
and that `fixed` marks compile-time knowledge [1490]. It did not settle the
binder spelling, the scope that owns those names, or whether textual order
could make a fixed formal's declared type resolve differently.

**Chosen:** a parameterized type declaration is written `name: type (t: type,
fixed n: u32) = rhs`, with `fixed` before its name. `fixed` is reserved. Its
arguments are positional: a type application is `name(type_argument, ...)`,
where an argument is a type or an integer for a fixed formal. A fixed formal
may supply an array bound, so `[n]t` is an alias body. The grammar admits that
formal list before either an alias type or a struct body. A parameterized atom
union remains outside the enabled kernel. D142 later adds one direct concept
constraint to a type formal without changing this positional substitution. The
same compile-time-only binders are admitted in declared-routine syntax and
resolution; D138 enables exact direct-call deduction, and D139 separately
enables target-selected module declaration lists.

One type-declaration scope contains all of the formals. The resolver collects
the complete formal list into that scope before it resolves any fixed formal's
declared type or the declaration right-hand side. Thus a formal may name one
written later, but the formals do not escape to the module or another
declaration.

A fully applied alias is normalized during checking. Its enabled result is a
scalar, fixed-array or nominal aggregate descriptor; an alias around a
parameterized struct instance keeps that instance's identity rather than
introducing another one. A fully applied struct instead interns D137's nominal
instance. A struct type formal accepts every enabled concrete
identity: scalar, structural atom set, exact fixed array, nominal instance or
structural function signature. The substituted field or payload position then
decides whether that identity is legal there. A fixed formal has an integer
type and accepts an integer literal; a nested application may forward its
caller's fixed formal. Substitution therefore covers fixed bounds and every
concrete field and payload shape the ordinary struct already admits.

A parameterized declaration named without arguments, an application with the
wrong arity or argument kind, a fixed actual outside its declared integer type,
a bound outside D136's fixed-expression forms, and recursive alias expansion
are refused. The substituted extent of an array or nominal instance must fit
the target `usize`. The declaration, its body and its formals are a compile-time
template: formals have no runtime type, IR slot or ABI position, and no
instantiation writes a type, length, layout or other per-application metadata
onto a template syntax node.

A template is still a declaration and is validated even when never applied.
The checker uses symbolic formals, not a guessed instantiation, to reject an
unresolved or non-type free name, a fixed formal whose declared type is
decidably non-integer, an unsupported decidable field or alias-result shape,
duplicate field or case names, an unconditional alias-expansion cycle and
D137's unconditional by-value nominal recursion. A question whose answer
genuinely depends on an actual remains for application checking. Its primary is
the application and its related label is the template field or expression; two
distinct bad applications therefore remain distinct. Declaration order does
not move an unconditional defect onto an outer application.

**Why one declaration scope:** resolving while reading would make a correct
alias depend on its formal order, while making each formal a module declaration
would leak its name and create collisions unrelated aliases cannot share. A
function-shaped type maker would instead introduce execution where [1350]
requires substitution. All were declined.

**Pinned by** the parameterized-alias and parameterized-struct parser and
resolution public-seam cases; the checking and lowering public-seam cases;
`positive/parameterized-type-alias-scalar`,
`positive/parameterized-type-alias-fixed-array`; the repository `core/vec`
module and `runtime/core-vec-pointer-storage`; the
`positive/parameterized-struct-basic`,
`positive/parameterized-struct-instances`; the `negative/parameterized-alias-*`,
`negative/parameterized-atom-union`, `negative/parameterized-struct-*` and
`negative/nominal-struct-recursive-layout` fixtures; the generated lexical,
construct and IR records; and `runtime/parameterized-type-alias-fixed-array`
and `runtime/parameterized-struct-values` on Linux x86-64.

### D136 — Fixed-array bounds use a closed target-independent fold

**The tour said** that an array's length is a compile-time value [0370], that
its size is part of its type [0520], that fixed parameters are compile-time
[1290], and that parameterized types use substitution rather than execution
[1350]. Prototype 3 wrote `[64 * 1024]u8`. None said which expressions could
supply a bound or whether accepting a call there would execute user code.

**Chosen:** the syntax between an array type's brackets is an expression. Its
fixed meaning is deliberately closed: integer literals, references to fixed
formals, parentheses, unary `-`, and the non-wrapping arithmetic `+`, `-`, `*`,
`/` and `%`. These operations use mathematical integer answers within the
widest enabled integer magnitude; they do not acquire an operand width from a
host or target. Every intermediate answer must remain in that range, division
or remainder by zero is impossible under [1950], and a negative final answer is
refused. When source legality otherwise admits the bound, the folded answer is
D17's canonical element count and D18 checks its target byte extent exactly as
it does for a literal bound. A final answer of zero is accepted: `[0]T` and any
admitted fixed expression that folds to zero denote D17's canonical
zero-element shape. Its size is zero, its alignment is one, and the ordinary
rules for its context still apply; in
particular this does not add empty literal syntax or make repetition valid in a
context whose length is zero.

A boolean or a comparison/logical result is not an integer count. Wrapping,
bitwise, complement and shift operations need an operand width and are not in
this target-independent fold. A runtime or storage name is not a fixed formal;
a type formal or another non-value name is diagnosed as such rather than called
runtime storage. A call is syntactically valid in the brackets but is not a fixed expression:
the compiler rejects it and never executes its body. No other expression form
is admitted, and an implementation becoming better at ordinary constant
folding does not enlarge this set.

The same evaluator handles a direct bound and an alias-template bound such as
`[n * 2]t`. During symbolic template validation an unknown fixed formal remains
unknown; during an application its substituted value is folded locally. Before
a nested template application can inherit an application origin, the nested
template is validated on its own. An unconditional inner defect is therefore
reported once at the inner declaration regardless of declaration order. Only a
failure that depends on substitution is primary at the application and relates
the failing template expression, so two bad applications remain distinct. No
instantiation writes a value, type or shape onto the template syntax, and fixed
actuals in a type application remain D135's integer literal or forwarding fixed
formal rather than growing a second expression grammar in argument position.

**Why a closed mathematical fold:** executing a helper would contradict [1350]
and make compile-time effects possible. Reusing the ordinary target-width fold
would make type identity depend on a selected target before D18 asks its layout
question. Admitting whatever an optimiser happens to fold would move source
legality between compiler versions. All three were declined.

**Pinned by** the parser, checking and lowering public-seam cases;
`positive/fixed-array-bound-expression` and
`positive/fixed-array-bound-zero`; `negative/fixed-array-bound-call`, which
contains a valid user call whose body is never run;
`negative/fixed-array-bound-invalid`; the generated lexical, construct and IR
records; and `runtime/fixed-array-bound-expression` and
`runtime/fixed-array-bound-zero` on Linux x86-64.

### D137 — A parameterized struct application is one canonical nominal instance

**The tour said** that ordinary structs are nominal [0710], that type and fixed
parameters are compile-time substitution [1290] [1350], and that target layout
is not host type identity [0750]. It did not say whether two applications of
one struct declaration are the same nominal type, whether an unused formal
participates, or where the instantiated field shape lives.

**Chosen:** a fully applied struct interns one checker-owned identity keyed by
the source template declaration and the complete ordered tuple of normalized
actuals. Aliases are erased before they enter the tuple. Scalar identities,
structural atom sets, exact fixed arrays including nominal elements, nominal
instances, structural function signatures and mathematical fixed magnitudes
are the only key forms. Equal keys reuse one identity. A different actual or
template remains a different nominal type even when every field, byte of
layout, and used formal is otherwise equal. Identity is target-independent.
Normalizing a nominal identity for a function-signature part or type-actual key
does not request that identity's layout. When a formal carrying that descriptor
is later substituted into a by-value field, payload or nominal array element,
the checker reconstructs the binding from the interned template and actual
tuple and materializes the required layout then. This promotion is recursive
through nested nominal and nominal-array actuals, checks D18 at that value use,
and treats a currently building identity as L0313. It applies even to an
element of a zero-length array.

The checker substitutes the tuple while walking the source body and builds one
layout for that canonical instance against the selected target when a value
site requires it. Scalar,
function, fixed-array, ordinary-child and existing variant payload shapes use
the same field descriptors and contextual value paths as a nonparameterized
struct. The body and formal nodes receive no instantiated answer, no synthetic
declaration is created, and the template and its formals create no IR item,
slot or ABI position. Lowering maps only concrete nominal identities and their
instantiated neutral shape trees.

Every template is first walked symbolically. An identity-only nonconcrete
struct or nominal-array actual retains a transient obligation containing its
source template and symbolic binding run rather than collapsing to an
unqualified unknown. If another template substitutes that obligation at a
by-value position, the checker follows it through any number of used-formal
wrappers; reaching an active nominal obligation is L0313. The obligation is
local to declaration validation: it interns no guessed actual, writes no AST
metadata and disappears with the checking run. A plain unused formal, phantom
actual or function-signature mention never promotes it. Free names, decidable
fixed-formal and field-shape errors, duplicate fields and cases, and
unconditional by-value recursion are therefore rejected even when no instance
is requested. A truly
actual-dependent failure is primary at each application and relates the field
or expression in the template. An invalid layout state stores no application
provenance: a repeated use of the same canonical key re-evaluates the bounded
body walk so it receives its own primary while retaining one identity and
tuple. Fixed actuals remain integer literals or
forwarded fixed formals. Parameterized atom unions remain
deferred; D138 and D139 separately define generic routine instances and fixed
conditional module declarations.

An alias expansion that reaches no type remains L0307. A nominal field,
nominal array element or variant payload that would require a finite instance
to contain itself by value is instead L0313, whether the cycle crosses aliases
or templates. Function-signature references do not form such a value-layout
edge: a function field is the already enabled one-`usize` carrier. This applies
to parameter and result positions, recursively nested function signatures, and
ordinary nonparameterized structs as well as parameterized instances. An
ordinary signature lookup may therefore take the canonical empty-actual nominal
identity before that struct's layout is ready and follows ordinary alias chains
without settling them by value. Mutually recursive ordinary structs connected
only by such signature references each have a finite pointer-carrier layout,
independent of declaration order. When a declared or anonymous routine's
multiple named results form D128's caller-owned aggregate, its direct result
parts materialize before their target placement is measured; that ABI use does
not promote a nested callback signature into a by-value edge. A failed replay
is cached at its application node, so one written application has one primary
while a second written application still receives its own dependent report. A
zero-length nominal array at a field or payload still validates its element
identity and is not an escape from the recursion rule.

**Why the complete tuple:** dropping an unused actual makes adding the first
field that uses it silently change existing type identity. Structuralizing the
instantiated body makes two declarations equal contrary to [0710]. Putting
layout in the key makes a source type change with the selected target. Mutating
the AST or synthesizing declarations makes one application overwrite another
or leak compile-time binders into runtime representation. All were declined.

**Pinned by** the checking, lowering and verifier public-seam cases;
`positive/parameterized-struct-basic`,
`positive/parameterized-struct-instances`,
`positive/parameterized-struct-identity-only`,
`positive/parameterized-struct-lazy-value-layout`;
`positive/ordinary-struct-function-signature-recursion`,
`positive/ordinary-struct-function-signature-alias-first`,
`positive/ordinary-struct-function-signature-alias-last`, the two
`positive/ordinary-struct-mutual-function-signatures-*` order fixtures, and
`positive/multiple-named-generic-nominal-results`; the
`negative/parameterized-struct-*` (including the unused indirect, mutual and
multi-wrapper recursion cases) and `negative/nominal-struct-recursive-layout`
fixtures; the generated IR and
diagnostic catalogue; and `runtime/parameterized-struct-values` and
`runtime/parameterized-struct-lazy-value-layout` on Linux x86-64.

### D138 — Direct generic calls deduce one checker-owned routine instance

**The tour said** that type and fixed parameters are compile-time-only [1290],
that a call supplies runtime arguments [1920], and that specialization is an
implementation choice rather than generic meaning [1350]. It did not say
where facts about two concrete uses of one routine body live or which context
may participate in deduction.

**Chosen:** a generic routine template has no standalone function value or IR
item. A direct call first synthesizes each runtime argument without an expected
parameter type. A context-free integer literal therefore takes [0200]'s `i32`.
The checker then recursively unifies each written runtime parameter pattern
with that independently synthesized normalized descriptor. Scalar and atom-set
constants agree exactly. A direct type formal binds the complete scalar,
structural atom-set, fixed-array, nominal, pointer/slice reference,
`any`-concept or concrete function-signature descriptor; every repeat must
agree exactly.

A fixed-array pattern recursively matches its exact element descriptor and
bound. A direct fixed formal in the bound binds the argument length. A computed
D136 bound never contributes an equation to solve: the checker defers it until
another direct occurrence or an explicit static tuple has bound every formal
it references, then folds and compares the result exactly. A formal that occurs
only inside `n * 2` or another computed expression remains undeduced. Nominal
elements participate by identity.

A parameterized nominal pattern requires an argument instance interned from the
same source template, then recursively matches every stored normalized actual
in declaration order. This includes phantom type and fixed actuals that do not
appear in the struct body. Ordinary aliases erase consistently; a parameterized
alias pattern is expanded symbolically and its result is unified without
inventing an actual. A function-signature pattern recursively matches parameter
and result counts and types plus its infallible, concrete or still-inferred
error form; parameter and result labels do not participate [1000]. A nested
type formal may therefore bind from a nominal actual tuple, fixed-array element,
function parameter, function result or concrete function error set.

Every static formal must be bound. Deduction uses no return context, conversion,
constraint search, arithmetic inversion or user-code execution. A call either
leaves all static formals for deduction or names every type/fixed formal in its
one named call list; a partial explicit tuple is refused. A saturated explicit
static tuple bypasses binding and runs the same recursive walk as exact
validation. Type actuals are resolved as type views, while a fixed actual is an
integer literal or a forwarded caller fixed formal and must fit its substituted
declared integer type. Fixed ranges are validated after the complete tuple is
known. After deduction or explicit saturation, substitution builds the concrete
runtime signature and ordinary call checking applies that signature. A generic
routine may write a concrete declared atom error set; substitution carries it
on the instance signature and bounds callers exactly like an ordinary declared
set. For private `! ...`, the template itself still has no signature. Each
concrete routine identity instead publishes an initially inferred signature,
then contributes its directly failed atoms and its instance-view call targets
to the whole-program least fixed point. Calls from or to ordinary routines and
same- or different-key generic instances use one graph; direct and mutual
same-key recursion therefore close without syntax recursion. `try`, recovery
and inference all resolve a call through the active view's recorded instance
target rather than the deliberately absent template signature. Equal keys share
one inferred set, while unequal keys retain separate signatures and may settle
to different sets. An empty result becomes infallible; a nonempty result becomes
a concrete atom set before body checking resumes and before lowering. Call
recovery, `try`, `fail`, `defer`, and `undo` then use only that finalized
ordinary descriptor.

The checker interns an opaque routine identity from the source template and
complete normalized actual tuple. Equal keys reuse one identity; unequal keys
remain distinct. The instance publishes its substituted signature before its
body is checked, so recursion at the same key is legal. Re-entering the same
active template with a different tuple is refused as non-finite expansion.
Each instance owns a layered fact view keyed by that identity and the original
source declaration or node. An unwritten fact falls back to module and
nongeneric facts, while writes remain in that one view; no instance answer is
put on syntax and no AST is cloned or synthesized. Template defects independent
of actuals, including an impossible literal operand, are checked without a
guessed instance; dependent operations wait for a concrete view.

Lowering selects that same view and creates one deterministic local routine
item per ready identity in checker interning order. A generic call records its
target identity in its caller's view, so nested and recursive calls remain
stable. The template, type formals and fixed formals create no item, slot,
runtime signature part or ABI position. This executable increment carries every
enabled direct-formal descriptor through routine parameters, results, locals
and calls, including atom sets, function signatures and nominal aggregate
transport/layout. Recursive structural deduction changes no descriptor,
transport, layout or ABI rule: static arguments have no runtime synthesis,
flow fact, cleanup or ABI position, and lowering maps only written runtime
arguments to runtime formals. A fixed formal used as an expression in the
concrete body has its declared integer type and lowers to the instance actual as
a target-neutral constant; it is not a slot or hidden parameter. A direct type formal still cannot bind a
function descriptor whose error graph is currently inferred, because it is not
yet a complete actual key. A generic template itself remains unavailable as a
function value: only a direct call chooses the concrete instance signature.

**Why an instance view:** writing `t = u8` on the template declaration or its
nodes makes a later `t = i32` call overwrite the first. Resetting shared tables
around a recursive walk makes nested instances depend on traversal order.
Cloning syntax invents declarations and provenance for a compile-time
substitution. A checker-owned identity plus overlay avoids all three.

**Pinned by** the checking public-seam case `routine instance views keep source
facts`, the lowering case `generic routines lower once per key`,
`negative/generic-routine-repeated-deduction-conflict`,
`negative/generic-routine-undeduced-formal`,
`negative/generic-routine-infinite-expansion`,
`negative/generic-inferred-error-unhandled`,
`negative/generic-inferred-template-not-function-value`,
`negative/generic-try-infallible-instance`,
`negative/generic-routine-unused-unconditional-defect`,
`negative/generic-computed-pattern-undeduced`,
`negative/generic-explicit-computed-pattern-mismatch`,
`negative/generic-structural-repeated-conflict`,
`negative/generic-wrong-nominal-template`,
`positive/generic-structural-deduction`,
`positive/generic-zero-nominal-array-signatures`,
`runtime/core-mem-raw-storage`, and
`runtime/generic-identity-deduction`,
`runtime/generic-fixed-array-deduction`,
`runtime/generic-direct-descriptor-deduction`,
`runtime/generic-structural-deduction`,
`runtime/generic-zero-nominal-array-signatures`,
`runtime/generic-declared-errors`,
`runtime/generic-routine-inferred-errors`,
`runtime/generic-try-effective-signature`, and
`runtime/generic-same-key-recursion` and
`runtime/diagnostic-loggers-dispatch` on Linux x86-64. The malformed-error
verifier case uses a generic-instance item to pin that only the finalized
concrete signature and ordinary failure opcode reach neutral IR.

### D139 — Fixed conditionals select module declarations without execution

**The tour said** that `fixed` marks compile-time knowledge [1490], showed a
conditional on `compiler.arch` [1500], and forbade compile-time calls [1540].
It did not say where a conditional may occur, whether a false arm is parsed,
or how target selection reaches whole-program resolution.

**Chosen:** `fixed if expression then declaration* (elsif expression then
declaration*)* (else declaration*)? end if` is a module-declaration form
only. It may nest, every arm may be empty, and an arm opens no scope: its
selected declarations splice into the one module scope across all input files.
It has no `public` modifier or trailing name, and is not a block, struct,
signature or template-local form.

The parser retains every arm in immutable syntax and reports lexical, parser,
refusal and recovery faults in false arms. A configuration stage runs after
target selection and before resolution. It records an activity view rather
than pruning syntax. Resolution, checking, template validation, identity
interning and lowering use only that view; a name in an inactive arm has no
semantic diagnostic or declaration identity, while an active use of it is
unresolved normally. Nested conditionals in an inactive arm are parsed but
not evaluated.

The fixed expression is closed. It admits bool and mathematical D136 integers,
the compiler-owned architecture values `x86_64`, `arm64`, `cortex_m0` and
`synthetic_32`, literals, parentheses, unary `-`, D136 arithmetic, integer
comparisons, bool or architecture equality, and `not`, `and`, `or`.
`compiler.arch` is the only intrinsic and is recognized only by this stage;
its target identity comes from the selected `Target_Facts` constructor, never
a target label. Structural validation visits both logical operands even when
evaluation then short-circuits. Calls, runtime or module names, measurements,
controls, aggregates, arrays and width-dependent operators are rejected and
never execute. Every active `if` and `elsif` condition is validated and
evaluated even after a true arm; the final answer must be bool.

**Why an activity table:** deleting branches would destroy parser diagnostics
and mutate a shared syntax authority; making ordinary resolution decide the
condition would introduce a compiler module and runtime execution before
R4.30. A selected immutable view preserves the whole-program declaration set
without pulling options, build modes, widths, byte order or general builtin
modules forward.

**Pinned by** the target-description constructor and configuration-stage
public-seam cases; `positive/fixed-conditional-selects-declarations`,
`positive/fixed-conditional-nested-inactive`,
`positive/fixed-conditional-exclusive-duplicates`,
`positive/fixed-conditional-cross-file-forward`, and
`positive/fixed-conditional-symmetric-boundaries`; the arithmetic and
short-circuit/later-`elsif` call boundary case
`negative/fixed-conditional-evaluator`; the active duplicate and
active-reference-to-inactive cases
`negative/fixed-conditional-active-duplicate`,
`negative/fixed-conditional-active-reference-inactive`,
`negative/fixed-conditional-active-generic-error` and
`negative/fixed-conditional-inactive-parser-error`; the lowering and verifier
cases, generated lexical, construct and IR records; and
`runtime/fixed-conditional-runtime` and
`runtime/fixed-conditional-generic-runtime` on Linux x86-64. The selected
nested generic and inactive-template boundaries are
`positive/fixed-conditional-generic-activity` and the lowering seam records
that only a selected generic instance receives an item.

### D140 — `escaping` precedes an explicit parameter convention

**The tour said** that `in`, `inout` and `sink` are conventions written before
a parameter name [0900], that `escaping` is orthogonal to all three [0780]
[0900], and that attributes are prefix words [0760]. It did not say how the
two prefixes are ordered when one parameter carries both.

**Chosen:** `escaping` first, then an optional explicit convention, then the
name: `escaping inout item: ptr mut node`. The parser retains explicit `in`
apart from the omitted default even though both have the same language
meaning. Type and fixed formals keep their existing spellings and admit neither
runtime modifier.

**The alternatives:** convention first, or both permutations. Convention first
makes the general prefix attribute interrupt the parameter it qualifies;
admitting both creates two source spellings for one signature fact and makes
recovery decide whether a repeated modifier was an order variation or a second
modifier. Either is workable, and neither was selected by the tour.

**Pinned by** the parser case `reference signature syntax is represented` and
the resolution case `return sources retain parameter positions`.

### D141 — An empty slice uses the lowest aligned non-null base

**The tour said** that an empty slice has a canonical aligned address, is not
null, cannot be dereferenced, and yields that base through `base_of` [0580]. It
did not select one aligned address.

**Chosen:** the numerical address equal to the element alignment: one for a
byte-aligned element, four for an ordinary `u32`, and so on. It is the lowest
positive aligned address, depends only on target facts and element layout, and
therefore remains stable across compiler runs without reserving real storage.
The zero length is checked before any address arithmetic, so the address is
never accessed.

**The alternatives:** a compiler-owned static sentinel, one sentinel per type,
or any implementation-selected aligned nonzero pattern. A static symbol makes
the observable integer address link-dependent; per-type sentinels add storage
and identity with no language value; an unspecified pattern contradicts
`canonical` once pointer-to-integer conversion can observe it.

**Pinned by** `runtime/r250-references`, the empty-slice IR verifier path, and
the Linux x86-64 backend's target-derived empty-base emission.

### D142 — Concepts and conformances are collected before constrained instantiation

**The tour said** that a concept is a named requirement bundle [1230], a
conformance registers a type [1240], a leading binder quantifies a
parameterized type [1250], the key is `(type, concept, input types)` [1270],
and every collision is an error [1280]. It did not settle the enabled grammar,
the scopes, how an uninstantiated parameterized collision is found, or where a
constraint lookup is performed without already having R2.70's evidence table.

**Chosen:** `concept` and `is` are contextual words. A concept declaration
carries one nonempty collected type-formal list, zero or more direct parent
concept names, and an ordered run of named complete function signatures. A
concept entry's error set is infallible or concrete, never inferred. A direct
`is concept_name` may constrain a type formal in a type, routine, concept or
conformance binder. The concept and conformance scopes collect their complete
static binder before resolving any target, input or signature type.

A conformance carries an optional leading type/fixed binder, one target type,
one direct concept name, and a labelled run. Labels supply every concept input
formal after the represented type and every direct concept entry exactly once.
The whole-program key is the normalized represented type, concept identity and
ordered normalized input-type tuple; function labels are payload, not key.
Concrete supplied functions have exactly the substituted concept signature.
Composed concepts require separate conformances to every named parent; having
the child never synthesizes a parent.

R3.10 makes the whole program the closed graph of modules reachable from the
entry directory after first-matching ordered-root selection. Every conformance
in that graph is collected whether used or public; unreachable directories and
later root matches contribute nothing. A conformance declares no module name,
so `public` on one is refused rather than changing registration visibility.

A parameterized conformance quantifies one complete nominal type family. Its
target is that declaration fully applied to the binder in the same positional
order and kind, with every binder used once. This closed family form covers the
container conformances that forced [1250], avoids arithmetic inversion and
specialization, and lets collection reject a second family for the same target
template and concept even if no generic call requests an instance. A concrete
exception under such a family is also a collision. Lookup substitutes the
family binder, checks its own constraints, and interns the resulting concrete
key. There is no search by return context, conversion, precedence, weak entry,
or orphan rule.

Collection retains parameterized supplying functions and the concrete binder
tuple selected by lookup. R2.70 owns turning that retained selection into an
evidence schema and validating the substituted generic entry at that ABI
boundary; R2.60 emits no table and adds no generic dispatch operation.

**Why the family restriction:** arbitrary overlapping type patterns require a
general unification and specialization order the language has neither stated
nor wanted. Silently checking only requested overlaps would contradict
[1280]'s whole-program rule. One complete nominal family gives parameterized
containers their required quantifier while keeping collision collection finite
and independent of use.

**Pinned by** `positive/concepts-and-conformances`,
`positive/parameterized-conformance-lookup`,
`negative/conformance-collision`,
`negative/parameterized-conformance-collision`,
`negative/constraint-not-satisfied`,
`negative/conformance-entry-signature-mismatch`,
`negative/composed-conformance-missing-parent`, and
`negative/concept-composition-cycle`, plus parser, resolution and
checker register cases.

### D143 — `zeroable` is one closed compiler concept family

**The tour said** that the compiler alone supplies `zeroable` conformances
because only it knows bit patterns [0550], while [0540] separately distinguishes
having a zero image from accepting the contextual word `zeroed`. It did not
say whether `zeroable` needs a source declaration, whether users may add a
missing entry, or how zero-length and nested enabled shapes enter the set.

**Chosen:** `zeroable` is the sole compiler concept identity in R2.60 and needs
no source declaration. A source declaration cannot impersonate that identity,
and every source conformance naming it is L0319: users can neither synthesize a
false entry nor override a true one. Lookup supplies a conformance for every
enabled scalar; for a fixed array exactly when its element is zeroable, even at
length zero; and for a nominal aggregate exactly when its recursively active
all-zero field and first-variant-case payload shape has a zero image. Atoms,
functions, pointers and slices are outside the family. The algorithm is the
same checker predicate that admits an all-zero aggregate image, so contextual
`zeroed` and the generic concept cannot drift.

The set is closed and named. No source query enumerates it, no declaration is
synthesized, and no reflection hook asks whether an arbitrary representation
happens to be zero. A successful constrained lookup interns only the concrete
semantic key for later evidence work.

**Pinned by** `positive/compiler-zeroable-conformances`,
`negative/nonzeroable-constraint`,
`negative/nonzeroable-zero-length-constraint`,
`negative/compiler-conformance-reserved`, the checker register case, and the
existing aggregate zero-image fixtures.

### D144 — Evidence order is semantic and physical layout is target-derived

**The tour said** that generic code receives a table of concept functions and
that the evidence also carries the represented type's size and alignment
[1310]. It did not state table identity, member order, hidden-argument order,
composition, the physical cell layout, or how the first backend may share code
without making an x86 representation the semantic schema.

**Chosen:** one evidence identity realizes one concrete D142 conformance key:
the normalized represented type, direct concept identity and ordered input-type
tuple. Parameterized families materialize only concrete keys selected by
lookup; an ordinary collected key may be emitted without waiting for a call.
The target-neutral logical run is the represented type's size, its alignment,
then every direct concept function in concept declaration order. Conformance
labels select providers and never reorder that run. Parent concepts retain the
separate conformances D142 requires rather than flattening their entries into a
child table. The compiler `zeroable` conformance consequently has only the two
layout members and synthesizes no source provider.

Size is the complete padded target-byte size of one represented value and
alignment is that value's target-byte alignment. Both are runtime `usize`
values. A direct function member retains its substituted concrete signature and
names the ordinary provider routine or selected generic provider instance; its
concrete error set uses D109's existing orthogonal call outcome. The semantic
schema contains no byte offset, register, relocation spelling or host-sized
integer.

Every physical member is one target pointer-width cell, and the table is
aligned to the target pointer alignment. Therefore Linux x86-64 places size,
alignment and the first function at offsets 0, 8 and 16, while synthetic-32
places them at 0, 4 and 8. A table with `N` direct functions occupies
`(N + 2) * pointer_bytes`. `Landin.Evidence` owns semantic positions;
`Landin.Targets` alone derives these offsets, extent and alignment.

A concrete generic call passes the direct table and then each distinct table in
its represented-formal constraint/parent closure, depth-first in concept
declaration order, for every constrained type formal in generic-formal order.
This preserves D142's separate parent conformances while making inherited
entries reachable without flattening a child table. The existing caller-owned
aggregate result address remains first, evidence pointers follow, and written
runtime parameters remain after them in source signature order.
Static type and fixed formals still create no runtime position. Inside the
active routine view, `T.entry(...)` loads the declaration-order function word
from that hidden table and makes the ordinary verified indirect call. Size and
alignment remain table members even where the current concrete view answers
`sizeof T` or `alignof T` directly by resolving the formal through that routine
instance's type actual. The node's complete concrete descriptor lives only in
the active instance overlay. Later shared and `any` consumers therefore use the
same semantic measurement and provider schema; D147 gives the erased consumer
a separate flattened physical table without changing these direct generic
offsets.

The Linux baseline may alias two concrete generic symbols to one emitted body
only when a bounded IR comparison proves their signatures, slots, operand graph
and allowed operations have one physical meaning on that target. Evidence
identity may differ because it arrives through the hidden parameter; signed
arithmetic, aggregates, static table addresses and every unproved operation
prevent folding. A failed sharing proof emits separate concrete bodies and
cannot affect source correctness. This is baseline code folding, not R4.50's
direct-call specialization policy.

**The alternatives:** putting function words first was viable, but makes the
two representation facts every evidence consumer needs a variable-position
suffix; the fixed prefix was chosen. Reordering by conformance labels would
make source-equivalent labelled payloads ABI-different. Flattening parents
would make a child ABI change when a separately registered parent changed.
Encoding `.quad` or eight-byte offsets in IR would turn the first backend into
the language definition. Calling providers directly from constrained generic
bodies would leave a table that no executed path proved. All were declined.

**Pinned by** `runtime/generic-evidence-indirect`,
`runtime/generic-composed-evidence`, `runtime/generic-parameterized-evidence`,
`runtime/allocator-vec-pressure`,
`negative/parameterized-conformance-entry-signature-mismatch`; the target case
`evidence ordering and layout`; the backend case `generic evidence is ordered indirect
and shared`; IR verifier evidence identity, entry and signature checks; and the
recorded target and lowering artefacts.

### D145 — `any C` has direct-concept identity and explicit pointer erasure

**The tour said** that `any C` is a copyable data-pointer/table pair [1370],
that construction is explicit and takes its concept from context where it can
[1380], and that calls select table entries [1390]. It did not state whether
`any` is reserved, whether parents imply conversions, how an omitted context
is selected, whether a value may be copied into the pair, or how concepts with
additional input types are written.

**Chosen:** `any` becomes the thirty-fourth reserved kernel word. `any C` is a
structural type whose identity is exactly the direct source `Concept_Id` of
`C`; aliases preserve it, while parent composition creates no subtype or
conversion. The enabled source form admits a concept with exactly its one
represented type formal and an empty D142 input tuple. There is no implicit
conversion either from a concrete value/pointer or between two `any` types.

`any(pointer)` evaluates exactly one pointer expression and never copies the
unknown-sized pointee. In a destination, argument or result context, that
context supplies `C` and lookup selects the exact concrete D142 conformance
key, materializing a parameterized family and generic provider when needed.
Without a context, construction succeeds only when exactly one already
collected source concept has an exact conformance for the pointer's referent;
zero or multiple candidates require an explicit `any C` context. Compiler
concepts do not participate. The construction node retains its concrete
conformance solely so lowering can form a static table address; later copies
carry no static concrete type fact. The enabled construction forms runtime
storage; a module static image cannot yet carry the two relocations and is
refused rather than fabricated.

**The alternatives:** erasing a by-value object would either copy an unknown
size or create hidden storage. Choosing the first conformance by declaration
order would make unrelated declarations alter meaning. Treating a parent as
an implicit conversion would add concept subtyping the language has never
claimed. Encoding input tuples without source syntax would guess part of the
D142 key. All were declined.

**Pinned by** `runtime/any-inferred-construction`,
`runtime/any-parameterized-provider`, `negative/any-source-not-pointer`,
`negative/any-construction-needs-context`, and
`negative/any-concept-identity-mismatch`.

### D146 — Erased entries have one object-safe `self` pointer

**The tour said** that a mutable entry writes `self: ptr mut T`, that no extra
permission marker belongs in the pair [1370], and that dispatch inserts the
data pointer first [1390]. It did not bound other occurrences of hidden `T`,
say whether binding mutability gates a call, settle inherited-name collisions,
or state how origin analysis sees the pair.

**Chosen:** every entry exposed by the direct concept's distinct finite
represented-formal-constraint/parent closure must have first runtime input parameter
named `self`, of exact direct type `ptr T` or `ptr mut T`, where `T` is that
entry's concept's represented formal. `inout`, `sink`, `ptr ptr T` and a
parameterized referent that merely contains T are not that receiver ABI. Hidden `T` may occur nowhere in another runtime
parameter or result: a caller that knows only `any C` has no source type with
which to supply or receive it. The concrete provider keeps that substituted
ordinary signature. `value.entry` is only the immediate callee operation; the
two-word pair has no bound-method closure representation, so the selection
cannot be stored as a standalone function value. An entry name must be unique across the closure when it is
selected; an inherited collision is diagnosed rather than receiving source
order precedence.

Construction requires its pointer permission to satisfy every exposed `self`:
a read-only pointer cannot create a capability whose table includes mutable
`self`. Once created, the pair needs no permission bit. Binding mutability says
whether the two pair words may be replaced; it does not revoke write authority
already carried by a valid mutable data pointer, just as an immutable binding
may hold a `ptr mut T`.

The pair is reference-bearing for local origin/escape analysis. Construction
copies the complete origin fact of its pointer operand; copies, aggregate
storage, control joins, arguments and results carry that fact unchanged or
through the existing conservative join. A dynamic call maps implicit formal
one to the pair receiver and written argument one to formal two, so `escaping`,
`from self`, borrow and return checks reuse the ordinary call rules. An integer-
created untracked pointer remains untracked rather than regaining evidence.

**The alternatives:** storing a mutable bit would make the promised pair a
third semantic field or give one `any C` two runtime types. Requiring a mutable
pair binding to call a mutable entry would conflate replacement of the pair
with authority already inside it. Calling an entry that mentions hidden `T`
elsewhere based on one arbitrary conformance's signature would make another
conformance ABI-incompatible. All were declined.

**Pinned by** `runtime/any-heterogeneous-dispatch`,
`runtime/any-return-origin`, `negative/any-readonly-source-for-mutable-entry`,
`negative/any-entry-not-object-safe`, `negative/any-entry-not-bound-value`,
`negative/any-self-not-exact`, `negative/any-self-convention`, and
`negative/any-frame-origin-escape`.

### D147 — An `any` pair points at a flattened dispatch table

**The tour said** that the pair is two words [1370], that calls go through its
table with data first [1390], and that erased and generic evidence are one
semantic mechanism [1690]. D144 deliberately kept parent conformance tables
separate and fixed direct generic offsets, so it did not say how one erased
table pointer reaches inherited entries.

**Chosen:** the target-neutral pair order is data pointer then table pointer.
Both are target pointer-width cells, the pair aligns to pointer alignment, and
its extent is twice pointer width: data/table offsets are 0/8 and size/alignment
16/8 on Linux x86-64, and 0/4 with 8/4 on synthetic-32. The pair is transported
by the existing shaped-value/caller-owned-result ABI and may be copied whole or
stored as an aggregate field; neither word is a source-selectable field and
`zeroed` cannot construct it. After D145/D146 checking, target-neutral IR may
use the same private two-`usize` shaped carrier as a slice uses physically,
just as it erases a checked pointer to one `usize`; that carrier creates no
source array/index operation, while evidence descriptors and verifier checks
still own every table function position and signature.

A concrete conformance used by `any` receives a distinct physical erased table.
It repeats D144's size/alignment prefix and then flattens object-safe provider
function words: direct concept entries first, followed depth-first by each
distinct represented-formal constraint and named parent in declaration order.
The parent conformance identities and their D144 direct tables remain separate;
the flattened table repeats relocations rather than flattening semantic
conformance identity. Consequently D144's generic offsets and hidden arguments
remain unchanged. An inherited call uses its flattened semantic position.

Construction evaluates and stores the data pointer, then stores the selected
static flattened-table address. Dispatch loads the pair's table, loads the
verified function position, loads the data pointer, and makes the ordinary
indirect call with data as runtime argument one and written arguments after it.
Concrete provider signatures may differ in the referent identity of `self`,
but D146 proves that this erased position is uniformly one pointer carrier and
that every remaining parameter/result has one non-hidden source identity.

**The alternatives:** adding all parent table pointers to the value would break
the two-word representation. Changing D144's direct table suffix would move
existing generic ABI positions. Walking parent links would add links and loads
while still needing an erased receiver rule. A flattened erased table keeps
those concerns separate and was chosen.

**Pinned by** `runtime/any-heterogeneous-dispatch`,
`runtime/any-composed-dispatch`, `runtime/any-aggregate-storage`, the target
case `evidence ordering and layout`, the backend case
`any dispatch uses a flattened real table`, the existing evidence verifier
checks, and the generated target/lowering artefacts.

### D148 — Guarantee coverage is classified at observable failure boundaries

**The tour said** that Landin makes a deliberately smaller claim than memory
or resource safety [1720], and named four kinds of answer for the operation
table R2.90 would establish. It did not say what counted as one operation, so
two inventories could both look complete while one listed syntax nodes and
the other listed only machine instructions.

**Chosen:** one guarantee row is one observable failure boundary. A source
construct may occur in more than one row: pointer access, for example, has a
statically checked permission boundary and a separate pointee-validity boundary
outside the guarantees. `static` means the compiler rejects the stated bad
case; `trap` means a value not decidable during compilation stops synchronously;
`beyond-lifetime` means an explicit operation discards origin information and
later lifetime use is permitted without analysis; `outside` means the operation
is admitted but the stated property is never claimed. Ordinary accepted
behaviour is evidence for a row, not a fifth guarantee class.

#### Guarantee coverage

The register below covers every construct for which the current fixture matrix
claims acceptance or emission. `check.py` compares that set mechanically,
validates each cited diagnostic and fixture, and generates the reading copy
`compiler/tests/guarantees.matrix`. A new accepted construct therefore needs a
classified failure boundary before the repository gate can pass.

| Operation | Class | Constructs | Behaviour | Evidence |
| --- | --- | --- | --- | --- |
| `source.lexical` | static | 0010, 0020, 0030, 0210, 0220, 0230, 0250, 0260, 0270, 0280, 1750, 1760, 1770, 1780, 1830 | L0010--L0014 or L0320--L0323 | `negative/character-literal-empty`, `negative/character-literal-invalid-codepoint`, `negative/character-literal-multiple`, `negative/malformed-float-exponent`, `negative/malformed-hex-float-exponent`, `negative/malformed-integer-digit`, `negative/raw-literal-inconsistent-indentation`, `negative/text-literal-unknown-escape`, `negative/unterminated-raw-literal`, `negative/unterminated-text-literal`, `negative/unknown-byte` |
| `source.structure` | static | 1740, 1800, 1810, 1820, 1840 | L0100--L0112 | `negative/variant-part-end-name-mismatch`, `unit/parser-nesting-limit` |
| `declarations.names` | static | 0040, 0050, 0060, 0080, 0090, 0100, 0110, 0120, 0130, 0140, 1790, 1795, 1850 | L0200 or L0201 | `negative/duplicate-in-a-module`, `negative/local-used-above-its-declaration` |
| `types.values` | static | 0070, 0160, 0170, 0180, 0190, 0200, 0210, 0250, 1870, 1880, 1890 | L0300, L0301 or L0304 | `negative/character-literal-needs-u32`, `negative/float-literal-not-enabled`, `negative/float-type-not-enabled`, `negative/integer-literal-not-a-float`, `negative/literal-above-its-type`, `negative/type-name-is-not-a-type` |
| `float.ieee` | static | 0170, 0210, 0220, 0230, 0240, 0290, 0350, 1940 | f32/f64 decimal and hexadecimal literals plus inherently typed infinity and canonical quiet NaN names follow IEEE binary32/binary64 through runtime and module arithmetic and comparison, preserving exact hexadecimal values, nearest-even rounding, gradual underflow, signed zero and unordered NaN behavior; arithmetic NaNs use the canonical quiet pattern, L0300 rejects a finite literal that becomes infinity, and L0301 rejects an invalid named special, a width mismatch, mixed classes and integer-only operators | `negative/float-remainder-is-integer-only`, `negative/float-special-name-unknown`, `negative/float-special-on-integer-type`, `negative/float-special-width-mismatch`, `negative/hex-float-overflows-context`, `runtime/float-decimal-runtime`, `runtime/float-hexadecimal-runtime`, `runtime/float-named-specials`, `runtime/module-float-arithmetic` |
| `conversion.integer` | trap | 0150, 0190, 0310, 0470, 0700, 1460, 1670, 1880, 1940, 1950, 1960 | explicit conversion among enabled integer types preserves the mathematical value; L0300 rejects a known value outside the destination range and a runtime value outside it traps, without truncation, wrapping or signedness reinterpretation | `negative/integer-conversion-known-binding-out-of-range`, `negative/integer-conversion-known-out-of-range`, `runtime/integer-conversion-out-of-range-traps`, `runtime/integer-conversion-signed-overflow-traps`, `runtime/integer-conversion-unsigned-overflow-traps`, `runtime/integer-conversions` |
| `conversion.float-width` | trap | 0170, 0210, 0230, 0240, 0310, 0700, 1880, 1940, 1950, 1960 | explicit f32/f64 conversion widens exactly or narrows to nearest with ties to even, preserving signed zero and the infinity/NaN class; L0300 rejects a known finite narrowing overflow and an equivalent runtime conversion traps | `negative/float-width-conversion-known-out-of-range`, `runtime/float-width-conversion-overflow-traps`, `runtime/float-width-conversions` |
| `conversion.integer-to-float` | static | 0150, 0170, 0190, 0210, 0310, 0700, 1880, 1940, 1960 | explicit conversion from every enabled integer to f32 or f64 preserves the mathematical value when exact and otherwise rounds to nearest with ties to even; the enabled integer range cannot overflow either float width | `runtime/integer-to-float-conversions` |
| `conversion.float-to-integer` | trap | 0150, 0170, 0190, 0210, 0230, 0240, 0310, 0700, 1880, 1940, 1950, 1960 | explicit conversion from f32 or f64 to every enabled integer truncates toward zero and then requires the result to fit; L0300 rejects a known out-of-range, infinity or NaN source and an equivalent runtime conversion traps | `negative/float-to-integer-known-nan`, `negative/float-to-integer-known-out-of-range`, `runtime/float-to-integer-conversions`, `runtime/float-to-integer-nan-traps`, `runtime/float-to-integer-out-of-range-traps` |
| `conversion.bool-to-integer` | static | 0150, 0180, 0190, 0310, 0700, 1880, 1940, 1960 | explicit conversion from bool to every enabled integer maps false to zero and true to one; both results fit every enabled destination | `runtime/bool-to-integer-conversions` |
| `conversion.bool-to-float` | static | 0170, 0180, 0190, 0210, 0310, 0700, 1880, 1940, 1960 | explicit conversion from bool to f32 or f64 maps false to positive zero and true to exactly positive one; both values are exact in either enabled destination | `runtime/bool-to-float-conversions` |
| `conversion.integer-to-bool` | trap | 0150, 0180, 0190, 0200, 0310, 0700, 1880, 1940, 1950, 1960 | explicit conversion from every enabled integer to bool maps zero to false and one to true; L0300 rejects every other known value and an equivalent runtime conversion traps | `negative/integer-to-bool-known-out-of-range`, `runtime/integer-to-bool-conversions`, `runtime/integer-to-bool-out-of-range-traps` |
| `conversion.float-to-bool` | trap | 0150, 0170, 0180, 0190, 0210, 0240, 0310, 0700, 1880, 1940, 1950, 1960 | explicit conversion from f32 or f64 to bool maps either signed zero to false and exactly positive one to true; L0300 rejects every other known finite or nonfinite value and an equivalent runtime conversion traps | `negative/float-to-bool-known-invalid`, `runtime/float-to-bool-conversions`, `runtime/float-to-bool-invalid-traps` |
| `text.literal-storage` | static | 0260, 0270, 0280, 0430, 0570, 0600, 0610, 1770, 1880, 1900, 1940 | L0301 for a mismatched identity, writable context, byte escape in text or codepoint escape in bytes; L0303 for a write through a read-only view; L0304 keeps text indexing separate; quoted and raw literals default to `utf8`, decode to validated UTF-8 or UTF-16, preserve canonical view identity and static origin, and share width-keyed read-only storage with one trailing zero element excluded from slice lengths | `negative/cstring-literal-write`, `negative/raw-literal-needs-read-only-slice`, `negative/raw-literal-write`, `negative/text-literal-codepoint-in-byte-context`, `negative/text-literal-needs-byte-slice`, `negative/text-literal-needs-read-only-slice`, `negative/text-literal-write`, `negative/text-view-byte-escape`, `negative/text-view-identities-are-distinct`, `negative/text-view-indexing-deferred`, `runtime/hosted-text-views`, `runtime/raw-literal-bytes`, `runtime/text-literal-bytes` |
| `arithmetic.known` | static | 0290, 0300, 0390, 1950 | L0300 or L0306 | `negative/compound-assignment-zero-divisor`, `negative/divisor-is-zero`, `negative/literal-above-its-type` |
| `arithmetic.runtime` | trap | 0290, 0300, 0320, 0390, 1950, 1960 | trap | `runtime/compound-assignment-overflow-traps`, `runtime/checked-overflow-traps`, `runtime/checked-subtraction-traps`, `runtime/checked-multiplication-traps`, `runtime/checked-negation-traps`, `runtime/signed-division-overflow-traps`, `runtime/a-zero-divisor-traps`, `runtime/a-zero-remainder-divisor-traps`, `runtime/negative-left-shift-traps`, `runtime/negative-right-shift-traps` |
| `arithmetic.total` | static | 0320, 0330, 0340, 0350, 0390 | L0301 for an inapplicable operand; admitted nonnegative shifts and wrapping operations are total | `negative/compound-assignment-float-remainder`, `negative/condition-is-not-believed`, `runtime/compound-assignment`, `runtime/shifts-fill-with-zeros-beyond-the-width` |
| `ranges.measurements` | static | 0360, 0370 | L0300, L0301 or L0306 | `negative/lenof-scalar`, `runtime/measurements-answer-for-the-target` |
| `assignment.flow` | static | 0390, 0400, 0410, 0420, 1900, 1910 | L0302 or L0303 | `negative/assigned-on-one-path-only`, `negative/assignment-to-an-immutable-binding`, `negative/compound-assignment-immutable`, `negative/compound-assignment-unassigned`, `runtime/compound-assignment` |
| `pointer.permission` | static | 0430, 0440, 0450, 0460 | L0301 or L0303 | `negative/any-readonly-source-for-mutable-entry`, `negative/sink-through-dereference` |
| `inout.exact-alias` | static | 0900 | L0301 when one provably identical binding-rooted place fills two inout parameters | `negative/inout-same-place-twice` |
| `inout.possible-alias` | outside | 0430, 0770, 0900 | non-guarantee: distinct pointer or computed paths may still alias | `runtime/inout-pointer-alias-is-unchecked` |
| `pointer.validity` | outside | 0430 | non-guarantee: a permitted pointer may still be invalid or stale | `runtime/r250-references` |
| `pointer.integer-origin` | beyond-lifetime | 0470, 0860, 1690, 1720 | non-guarantee: integer-to-pointer conversion carries no origin through a direct or erased value | `runtime/r250-references`, `runtime/any-untracked-pointer-origin`, `runtime/diagnostic-loggers-dispatch`, `negative/frame-origin-return` |
| `pointer.integer-width` | trap | 0470, 1950, 1960 | trap | `runtime/pointer-to-small-integer-traps` |
| `arrays.initialization` | static | 0520, 0530, 0540, 0550, 0560 | L0300--L0304 or L0313 | `negative/array-initializer-length-mismatch`, `runtime/whole-arrays-copy-between-storage` |
| `raw.prefix` | static | 0420, 0510 | L0202 prevents representation access; `core/mem` reports `raw_full`, `uninitialized`, `raw_empty` or `raw_not_empty` before an invalid transition | `negative/core-mem-private-representation`, `runtime/core-mem-raw-storage` |
| `raw.backing` | outside | 0430, 0470, 0510, 1720 | non-guarantee: the supplied byte pointer may be invalid, misaligned or smaller than the declared capacity | `runtime/core-mem-raw-storage` |
| `allocation.failure` | static | 0940, 1230, 1280, 1290, 1310, 1360 | `core/mem` reports `out_of_memory`, which a caller must handle or declare; its failing allocator makes the runtime boundary deterministic | `runtime/core-mem-allocators`, `runtime/core-vec-pointer-storage`, `runtime/derived-parser` |
| `allocation.backing` | outside | 0430, 0470, 0770, 1360, 1720 | non-guarantee: caller-supplied arena storage may be invalid or cease to live after an origin-erasing pointer conversion | `runtime/core-mem-allocators`, `negative/core-arena-frame-escape` |
| `slices.bounds-known` | static | 0570, 0580, 1950 | L0300 or L0306 | `negative/index-outside-the-length`, `negative/readonly-slice-write` |
| `slices.bounds-runtime` | trap | 0570, 0580, 1950, 1960 | trap | `runtime/computed-array-index-traps`, `runtime/local-array-computed-store-traps`, `runtime/slice-index-read-traps`, `runtime/slice-index-write-traps`, `runtime/slice-half-open-upper-traps`, `runtime/slice-inclusive-upper-traps`, `runtime/slice-lower-after-upper-traps` |
| `atoms.sets` | static | 0630, 0640 | L0301 or L0312 | `negative/atom-match-not-exhaustive`, `runtime/atom-values-cross-the-abi` |
| `aggregates.variants` | static | 0670, 0680, 0690, 0700, 0710, 0720, 0750, 1210 | L0301, L0308--L0312 or L0313 | `negative/struct-literal-field-not-given`, `negative/variant-match-not-exhaustive` |
| `origins.escape` | static | 0770, 0780, 0790, 0800, 0830, 0840 | L0314--L0316 | `negative/frame-origin-return`, `negative/borrowed-source-inout`, `negative/returned-reference-missing-from`, `negative/core-arena-frame-escape`, `negative/core-text-frame-slice-escape`, `negative/core-diag-frame-message-escape`, `runtime/diagnostic-loggers-dispatch` |
| `origins.aliasing-limit` | outside | 0770, 0910 | non-guarantee: a pre-existing copy or indistinguishable arena is not tracked | `positive/reference-origins-and-consume`, `negative/use-after-sink` |
| `functions.abi` | static | 0870, 0880, 0890, 0900, 0920, 0930, 0980, 1000, 1020, 1030, 1460, 1920, 1970 | L0301, L0302 or L0502 | `negative/call-with-too-few-arguments`, `runtime/r230-composition` |
| `extern.c-boundary` | static | 0430, 1570, 1580, 1975 | L0301 for a signature outside R3.50's fixed integer/bool/pointer subset | `positive/external-scalar-c-boundary`, `negative/external-aggregate-boundary`, `negative/external-float-abi-not-enabled` |
| `host.io` | outside | 0430, 1580, 1650, 1660, 1680, 1975 | non-guarantee: files, descriptors, arguments and streams reflect mutable host state | `runtime/hosted-io-reads-parser-input`, `runtime/derived-parser` |
| `host.io-failure` | static | 0940, 0960, 1030, 1975 | `core/io` reports foreseeable host failure as declared atoms which callers handle or declare | `runtime/hosted-io-reads-parser-input`, `runtime/diagnostic-loggers-dispatch`, `runtime/derived-parser` |
| `diagnostics.retention` | outside | 0950, 1680 | non-guarantee: `core/diag.bounded(N)` retains at most N notes and reports every later note through its `dropped` count instead | `runtime/diagnostic-loggers-dispatch`, `runtime/derived-parser` |
| `diagnostics.delivery-failure` | static | 0940, 0960, 0950, 1030, 1680 | a streaming diagnostic write reports `io_failed`, which a caller must handle or declare; bounded overflow does not use that channel | `runtime/diagnostic-loggers-dispatch`, `runtime/derived-parser` |
| `execution.resource-exhaustion` | outside | 0950, 1770, 1970 | non-guarantee: the kernel sets no recursion-depth, stack, or host-resource bound | `runtime/recursive-fibonacci` |
| `consume.local` | static | 0910 | L0302 or L0315 | `negative/use-after-sink`, `negative/sunk-inout-not-restored` |
| `consume.copy-before` | static | 0860, 0910, 1720 | a value copied before the sink remains independently usable | `runtime/copy-before-sink-remains-live` |
| `errors.control` | static | 0940, 0960, 0970 | L0301 for an undeclared or unhandled outcome | `negative/unhandled-declared-error`, `runtime/declared-errors-direct-and-inferred` |
| `results.destructure` | static | 0990 | L0200, L0301, L0302 or L0308 | `negative/result-destructure-needs-multiple`, `runtime/r230-composition` |
| `functions.anonymous` | static | 1010 | L0201 for capture; complete signature checks otherwise apply | `negative/anonymous-function-captures-local`, `runtime/inferred-function-values` |
| `control.flow` | static | 1050, 1060, 1080, 1090 | L0301 or L0302 at every reachable join and exit | `negative/if-expression-missing-else`, `runtime/control-expression-edges-keep-source-order` |
| `control.loops` | static | 1130, 1140, 1150, 1160, 1170, 1180, 1190, 1320 | L0301 for a non-bool condition, mismatched range, non-traversable source, missing/ambiguous/non-exact iterable evidence, or incomplete/inconsistent value exit; L0303 for a write to a read-only storage element or copied iterable item; a taken transfer runs active defers and targets its named or nearest loop edge, while natural completion alone enters `complete` | `negative/loop-condition-not-bool`, `negative/loop-value-missing-break-value`, `negative/loop-value-missing-completion`, `negative/loop-value-type-mismatch`, `negative/for-range-needs-integer`, `negative/for-range-endpoints-disagree`, `negative/for-source-not-traversable`, `negative/for-collection-element-read-only`, `negative/for-array-element-read-only`, `negative/for-any-element-read-only`, `negative/for-iterable-ambiguous-evidence`, `negative/for-iterable-item-read-only`, `negative/for-iterable-missing-conformance`, `runtime/loop-control-flow`, `runtime/loop-values`, `runtime/for-range-traversal`, `runtime/for-collection-traversal`, `runtime/for-aggregate-element-traversal`, `runtime/for-any-element-traversal`, `runtime/for-iterable-evidence-traversal` |
| `cleanup.defer` | static | 1100 | the registered call is checked at every ordinary and successful-return edge | `negative/defer-read-not-assigned-on-return`, `runtime/defer-cleanups-follow-control-edges` |
| `cleanup.undo` | static | 1110 | the registered call is checked at every propagated-failure edge | `negative/undo-read-not-assigned-on-failure`, `runtime/undo-cleanups-follow-failure-edges` |
| `generics.substitution` | static | 1220, 1280, 1290, 1300, 1310, 1350, 1500, 1650, 1660, 1700 | L0300, L0301, L0306, L0307, L0313 or L0318 | `negative/generic-routine-undeduced-formal`, `runtime/generic-structural-deduction`, `runtime/core-vec-pointer-storage` |
| `concepts.conformance` | static | 1230, 1240, 1250, 1260, 1340 | L0301 or L0317--L0319 | `negative/conformance-collision`, `negative/constraint-not-satisfied`, `negative/compiler-concept-reserved` |
| `any.construction` | static | 1370, 1380 | L0301, L0314 or L0318 | `negative/any-source-not-pointer`, `negative/any-readonly-source-for-mutable-entry` |
| `any.dispatch` | static | 1390 | malformed table positions cannot be produced by accepted source; verifier failure is a compiler defect | `negative/any-entry-not-object-safe`, `runtime/any-heterogeneous-dispatch` |
| `modules.visibility` | static | 1410, 1420, 1450, 1480 | L0006 or L0007 for an unresolved root; L0202 for a private member or representation | `negative/module-not-found`, `negative/imported-private-name`, `negative/core-mem-private-representation`, `negative/core-text-private-position`, `runtime/core-mem-raw-storage` |
| `entry.point` | static | 1540 | L0502 before executable emission | `runtime/constant-return-exits-with-its-code` |
| `module.images` | static | 0180, 0340, 0350, 0410, 1460, 1890, 1930, 1940 | L0300, L0304 or L0305; module-known bool `not`, `and` and `or` fold left to right into scalar and aggregate images, short-circuit `and`/`or`, and execute no initializer CFG | `negative/module-value-from-a-call`, `runtime/module-known-short-circuit-bools`, `runtime/recursive-module-images-are-laid-out-and-distinct` |
| `configuration.fixed` | static | 1980 | L0300, L0301, L0305 or L0306 in the selected declaration view | `negative/fixed-conditional-evaluator`, `runtime/fixed-conditional-generic-runtime` |

This is a coverage register, not an optimizer contract. `unchecked` [1120], C
calls and raw allocation are absent because the current compiler does not
implement those operations; their enabling work must add rows. Driver and
backend inability have diagnostic owners in `diagnostics.matrix`, but are host
failures rather than source semantic operations and therefore are not invented
as language guarantees here.

#### Conformance and evidence coverage

The conformance/evidence coverage register is separate because one semantic
operation can travel through several physical mechanisms:

| Mechanism | Rules | Evidence |
| --- | --- | --- |
| `compiler-zeroable` | D143 | `positive/compiler-zeroable-conformances`, `negative/nonzeroable-constraint` |
| `ordinary-direct` | D142 | `positive/concepts-and-conformances`, `negative/conformance-entry-signature-mismatch` |
| `ordinary-parent` | D142 | `runtime/generic-composed-evidence`, `negative/composed-conformance-missing-parent` |
| `parameterized-provider` | D142, D144 | `positive/parameterized-conformance-lookup`, `runtime/generic-parameterized-evidence` |
| `collision` | D142 | `negative/conformance-collision`, `negative/parameterized-conformance-collision` |
| `constraint-refusal` | D142, D143 | `negative/constraint-not-satisfied`, `negative/nonzeroable-zero-length-constraint` |
| `generic-direct-table` | D144 | `runtime/generic-evidence-indirect`, `negative/parameterized-conformance-entry-signature-mismatch` |
| `generic-parent-tables` | D144 | `runtime/generic-composed-evidence` |
| `erased-direct-table` | D145--D147, D154, D155 | `runtime/any-heterogeneous-dispatch`, `runtime/diagnostic-loggers-dispatch`, `runtime/derived-parser`, `negative/any-concept-identity-mismatch` |
| `erased-parent-flattening` | D147 | `runtime/any-composed-dispatch` |
| `erased-parameterized-provider` | D145--D147, D154, D155 | `runtime/any-parameterized-provider`, `runtime/diagnostic-loggers-dispatch`, `runtime/derived-parser` |
| `verifier-boundaries` | D144, D147 | `unit/evidence-verifier` |
| `target-layout-64` | D144, D147 | `unit/evidence-layout`, `runtime/any-aggregate-storage` |
| `target-layout-32` | D144, D147 | `unit/evidence-layout` |

**The alternatives:** classifying syntax-node kinds gives internal recovery
nodes equal standing with user operations and misses one operation's several
safety boundaries. Classifying only IR opcodes omits every statically refused
operation. Treating every accepted operation as “safe” would overstate the
language exactly where [1720] refuses that claim. Those inventories were
rejected in favour of observable boundaries plus mechanical construct closure.

**Pinned by** `compiler/tests/guarantees.matrix`,
`compiler/tests/conformances.matrix`, `compiler/tests/diagnostics.matrix`, the
prototype and target matrices, and the full `check.py` coverage pass.

### D149 — `inout` exclusivity is checked only for a provably identical place

**The tour said** that `inout` may replace its argument exclusively [0900],
while [0770], [0860] and [1720] reject a borrow checker or whole-program alias
claim. It did not state what a caller passing the same storage twice must prove.

**Chosen:** one call may not fill two `inout` parameters with the same provable
binding-rooted place. Equality follows declaration identity and an identical
ordinary field path; that case is L0301 at the later argument with the first as
its related place. Distinct pointer paths and computed indexes may alias at
runtime, but proving that requires alias analysis Landin does not claim. Such
possible aliasing is accepted and explicitly outside the guarantees. The
callee's writes still occur in [0410] source order; acceptance is not a
non-alias promise.

**The alternatives:** accepting `f(x, x)` would make “exclusively” false in the
one case the local checker can answer. Rejecting all pairs of pointer or index
paths would reject ordinary code without proving overlap. Interprocedural alias
analysis or ownership would reverse [0770]. All were declined.

**Pinned by** `negative/inout-same-place-twice` and
`runtime/inout-pointer-alias-is-unchecked`.

### D150 — The reached module graph has one deterministic identity order

**The tour said** that a module is one directory [1410], an import searches
ordered roots and binds its final segment [1420], imports are per file [1450],
and the compiler receives roots rather than acquiring packages [1480]. It did
not settle the file prelude, qualification in non-value positions, discovery
order, cycles, visibility failures, compatibility invocation, entry selection
or what “whole program” means to the conformance register.

**Chosen:** `import` is reserved and every source file begins with zero or more
plain `import a/b` declarations before its module declarations. Each path is a
nonempty slash-separated identifier tuple. Aliases [1430] and selected imports
[1440] are recognized refusals owned by R4.30. A plain import binds only the
last segment in this file's import scope. Locals and signature declarations
shadow that binding; it shadows the same spelling in the module scope for
qualified lookup. Duplicate final-segment bindings are refused. Imports do not
enter sibling files, inject members or re-export anything.

The namespace's first selection resolves a public declaration in the selected
module and is available in every declaration-reference position, including a
concept constraint and a declared error set. A private
member is distinguished from a missing one and related to its declaration.
Public declarations may mention private identities, but those identities stay
unnameable across the boundary, and a value carrying one does not expose that
private type's fields. Variant cases inherit the containing type's
visibility. A namespace itself is no runtime or type value. `public` on a
conformance is refused; every unmarked conformance in the reached graph still
enters the single D142 register.

The request supplies one entry directory and ordered roots. A module contains
the bytewise-sorted direct regular `.ldn` children; other entries are ignored
and an empty module is legal. Each import segment must match a listed directory
entry exactly. Roots are tested in request order and the first complete
directory wins without merging. Discovery visits the entry first, imports in
source order and newly selected modules FIFO. A selected directory is loaded
once, so cycles are legal. Symlink identity and root defaults are outside this
guarantee. The explicit-file request remains a compatibility mode forming one
synthetic module when no roots are supplied.

Only after graph closure do configuration, resolution, checking and lowering
run over that canonical source order. “Whole program” is exactly this reached
graph, so unused reached conformances collide and unreachable or shadowed-root
conformances do not participate. Only the designated entry module supplies
[1970]'s hosted `main`.

**The alternatives:** recursively sweeping subdirectories would erase module
boundaries; merging roots would replace [1420]'s precedence with accidental
filesystem composition; injecting imported members would erase [1440]; making
conformances public would make generic behavior depend on lexical imports; and
choosing a reached library `main` would make the entry depend on traversal.
Loading by filesystem enumeration or hash order would also make declaration
identities and diagnostics host-dependent. All were declined.

**Pinned by** `unit/module-graph`, `unit/module-conformance-register`,
`negative/core-mem-private-representation`,
`negative/core-text-frame-slice-escape`, `runtime/core-vec-pointer-storage`,
and the parser, resolution, driver and hosted-entry cases.

### D151 — Raw storage is a private library state machine

**The tour said** that `slice_from` lies by describing uninitialized bytes as
`[]mut T` [0510]. R3.20 derived the necessary transitions with a non-zeroable
pointer element, but deliberately proposed no spelling.

**Chosen:** the repository-owned `core/mem` module declares a private
parameterized nominal `raw(item)` with a byte pointer, capacity and initialized
count. D150 permits public routines to carry that private identity, so callers
hold it through inferred bindings without being able to name its type or
select its fields. R3.40 adds the public parameterized alias `storage(item)` so
another core module may name the same identity in a field or signature without
exposing its representation. D135's alias introduces no second nominal
identity. Cross-module field selection through such a value is L0202, related
to the private type declaration. Code in the defining module retains ordinary
field access; no field-visibility syntax or special raw type kind is
introduced.

`reserve` records a supplied byte pointer and capacity with initialized count
zero. `capacity` and `initialized` expose only their respective counts.
`admit` checks for `raw_full`, writes at `base + initialized * sizeof item`,
then increments the count and returns the admitted index. `get` checks for
`uninitialized` before reading an index. `release` checks for `raw_empty`,
decrements first and returns the former tail. `dispose` checks for
`raw_not_empty`, returns the byte pointer and clears pointer and capacity. The
caller saves the capacity-derived byte extent before disposal; allocator
ownership remains R3.40's composition rather than state stored in `raw`.

Growth is transactional by composition: a replacement begins empty; reads of
the old prefix and admissions to the private replacement may be rolled back by
tail release without changing the old value. Only after the full copy succeeds
does the caller drain and dispose the old value and publish the replacement by
assignment. `transfer` performs the copy as one initialized-source to
next-destination transition, so a reference-valued item is not exposed as a
borrow between the two raw values. `raw` never yields a slice over capacity and
never gives spare storage a `T` image. The public checks are declared atom
outcomes, not traps, because these are foreseeable container conditions
[0940].

The state machine does not validate the allocation behind its byte pointer.
Supplying insufficient, misaligned, stale or otherwise invalid storage remains
the unsafe pointer operation [0430]/[1720] says it is. Returned pointer-valued
items retain the conservative local `from storage` origin, so a caller ends
that view before mutating the raw value again [0800].

**The alternatives:** a built-in raw-storage kind would add syntax, type-table
and backend machinery for an invariant a private module can express. A public
record would let callers forge counts. Reintroducing `slice_from` would make
the original false value claim. Requiring `zeroable` would reject the pointer
element that derived the contract. Trapping invalid transitions would turn
foreseeable container state into process termination. All were declined.

**Pinned by** `negative/core-mem-private-representation`,
`runtime/core-mem-raw-storage`, the rooted fixture execution path, and the
`raw.prefix` and `raw.backing` guarantee rows.

### D152 — The parser-support core is raw-backed and byte-oriented

**The prototypes said** that parser support needs allocator-threaded vectors,
arena allocation and text positions, while Z3, Z9 and Z10 left their exact
minimum unresolved. R3.20 and D151 established the honest raw-storage
boundary, but did not compose it into the modules the derived parser can use.

**Chosen:** `core/mem.allocator(provider)` has `alloc` and `free` entries.
Allocation reports the declared `out_of_memory` atom. `arena_over` builds a
monotonic allocator over a caller-supplied pointer and byte extent, aligning
each successful result and refusing a result that does not fit. `fail_over`
adds a successful-allocation budget and public counters so exhaustion and
cleanup paths have deterministic executable evidence. Both returned allocator
handles retain `from base`; returning one over frame storage is L0314. Freeing
does not reclaim monotonic space. The pointer and extent remain unsafe
caller-supplied backing under [0430], [0470] and [1720]. This ordinary library
allocator is not [0820]'s built-in lexical `arena` block, whose exact region
semantics remain R4.10.

`core/vec.list(item)` contains one D151 `mem.storage(item)`. It threads an
allocator through `reserve`, `push` and `release`, while `length`, `capacity`,
`get` and `pop` expose only initialized values. Growth allocates an empty
replacement, recursively transfers the complete initialized prefix, rolls
back that replacement on failure, and publishes it only after draining and
freeing the old storage. The recursive traversal is the kernel spelling until
loops are enabled. A failing reserve leaves the old list and its values
unchanged. Pointer elements are valid inputs; no `zeroable` constraint is
introduced. Internal raw-state errors are mapped to `out_of_memory`, `empty`
or `out_of_bounds` at the vector boundary.

`core/text` supplies an opaque nominal byte `position`, traversal, bounded
byte access with `past_end`, and a half-open subslice whose result is `from
source`. Positions are byte offsets because the parser consumes source bytes.
This is not the complete [0600] text design: D161 subsequently adds the
read-only `[]u8` literal view, while the other literal contexts, UTF-8 scalar
decoding, codepoint indexing and the permanent text/string boundary remain
R4.10.

The composition exposed four language rules needed by ordinary modules. D135
aliases may normalize to a nominal aggregate, selected calls are statement
calls under [1810], a qualified declaration reference may appear in a declared
error set, and origin inference follows selected calls and distinguishes a
slice of a by-value fixed-array parameter from a retained slice parameter or
`inout` storage. These are general language rules rather than privileges for
`core/*`.

Maps and trees are absent because the R3 parser does not need them. A public
initialized-prefix slice, small-vector storage, iterable integration and the
broader container surface remain R4.20. Allocator acquisition and ownership
also remain outside the compiler; the current modules only thread an allocator
supplied by their caller.

**The alternatives:** expose vector capacity as `[]mut item`, require
`zeroable`, publish a partially copied replacement, store an allocator in each
container, treat parser text as codepoints now, or implement the prototype's
map and tree before a workload needs them. The first two repeat the false raw
storage model D151 rejected; the third breaks failure atomicity; the fourth
confuses capability threading with ownership; and the last two settle wider
library design without parser evidence. All were declined.

**Pinned by** `runtime/core-mem-allocators`,
`runtime/core-vec-pointer-storage`, `runtime/core-text-byte-positions`,
`negative/core-arena-frame-escape`,
`negative/core-text-frame-slice-escape`,
`negative/core-text-private-position`, and the `allocation.failure`,
`allocation.backing`, `raw.prefix`, `origins.escape` and
`modules.visibility` guarantee rows.

### D153 — Hosted I/O is a libc-backed capability over a scalar import seam

**The tour and prototypes said** that hosted arguments begin in C `argc` and
`argv` form [1650], that the entry is where a root capability is minted
[1660], that world access is passed as an ordinary argument [1680], and that
`core/io.world` admits real and in-memory providers. They did not choose how
the first backend reaches Linux services or how much of [1570]/[1580]'s
foreign surface must become executable before the complete C work.

**Chosen:** D153 is exactly [1975]. The compiler implements bodyless
`extern(c)` declarations for fixed scalar/pointer signatures and carries them
as signature-only IR routines. The Linux backend captures entry `argc` and
`argv`, then emits a small fixed bridge whose implementations tail-call libc
for arguments, text length, read-only open, file read/write/close and errno.
`core/io` alone declares that bridge and turns it into a `world(provider)`
capability, an opaque file value, a public pointer-and-length argument view,
standard output/error descriptors and declared host-failure atoms. The system
provider is ordinary conformance evidence; generic callers do not know which
provider they received.

The bridge uses libc rather than direct syscalls because the hosted executable
already uses the C runtime and libc supplies the smallest stable host contract
for this workload. File descriptors remain private library representation.
Arguments exclude `argv[0]`; a runtime fixture's new `run_args` metadata pins
the distinction. Reads expose EOF as count zero and host failure as
`io_failed`; writes complete the requested slice or fail. `open_read` maps
Linux libc `ENOENT` to `not_found`, `EACCES` to `no_access`, and every other
failure to `io_failed`.

The backend's calls to `strlen`, `open`, `read`, `write`, `close` and
`__errno_location` are private runtime dependencies, not names reserved from
Landin source. A non-external Landin declaration with one of those spellings is
therefore given a deterministic whole-program assembler name, just as two
reached module declarations with the same short name are. The selected hosted
entry and an `extern(c)` declaration retain their required ABI spellings. This
prevents a public Landin `open` from interposing on the bridge while preserving
the explicit foreign-symbol contract.

**The alternatives:** direct Linux syscalls would couple the first hosted
library to kernel numbers and conventions without reducing the already-linked
C boundary. Enabling aggregate returns, unions, variadics, callbacks, foreign
allocation ownership or generated header bindings would pre-empt R4.40.
Making I/O a compiler intrinsic or global singleton would defeat [1660]'s
replaceable capability. Passing C-shaped parameters to Landin `main` would
reverse [1650]'s chosen ordinary no-argument entry.

This selects the bootstrap provider, not permanent compiler ownership of I/O.
R4.30 and R4.40 retain both direct libc declarations with explicit library
linkage and target-specific `core` providers built over inline assembly or
separately linked syscall wrappers. Either may implement the same `world`
capability without changing its callers.

**Pinned by** `positive/external-scalar-c-boundary`,
`negative/external-aggregate-boundary`,
`runtime/hosted-io-reads-parser-input`, `runtime/derived-parser`, the rooted
fixture execution path, and
the `host.io`, `host.io-failure` and `extern.c-boundary` guarantee rows.

### D154 — Diagnostics separate retention from delivery failure

**The tour and prototype 2 said** that a diagnostic sink is an ordinary
capability [0950] [1680], that a parser reports foreseeable syntax mistakes and
continues, and that bounded and streaming sinks must be interchangeable. They
did not say whether bounded overflow or a failed hosted write belongs to the
parser's error channel, how a retained message keeps its origin, or whether the
two implementations use the same dynamic call path.

**Chosen:** `core/diag.log(logger)` is an object-safe concept with `note` and
`failed`. `note` receives a mutable self pointer, `core/text.position`, a
`u8`-represented warning/error severity and an `escaping []u8` message, and
declares `core/io.io_failed`. `failed` reports whether any error-severity note
has been received. A producer accepts `any diag.log` and invokes both entries
through D147's ordinary erased evidence table; it neither names nor branches on
the concrete logger.

`bounded(capacity)` is a parameterized private nominal implementation. It
retains the first `capacity` entries in order, counts every later note in
`dropped`, and counts error severity even when that note is dropped. Overflow
therefore returns normally and never raises `io_failed`. Entry and logger
representation stay private; checked accessors report `out_of_bounds` rather
than exposing unused storage. Until R4.10 supplies the final text types, one
entry retains the message address and byte length internally. The `escaping`
parameter prevents a frame-backed slice at the capability boundary; explicit
integer-pointer conversion remains subject to [0470]'s honest validity limit.

`streaming` retains a mutable `core/io.system` pointer and a borrowed file. It
writes `W:` or `E:`, the decimal byte position, `:`, and the message bytes as the
note arrives. Each write propagates `io_failed`; the error count is updated
before delivery is attempted, so `failed` describes what the logger received
rather than what the host accepted. Both implementations receive the same
ordered calls in the executable evidence.

The implementation pressure also closes two existing representation seams. A
fixed formal used in a generic routine body is D138's per-instance constant and
has no ABI position. An aggregate place reached through pointer `.val` uses the
same target-neutral runtime-address storage path as a computed aggregate index;
`.val` is not encoded as a fictitious field zero.

**The alternatives:** treating bounded overflow as failure would make a parser
stop because its reporting policy is intentionally finite. Ignoring a failed
stream write would claim delivery that did not happen. Giving each logger a
different producer interface would erase the capability abstraction, while
specializing the producer would make optimization the semantic basis contrary
to [1310]. Retaining arbitrary frame bytes behind an origin-erasing address was
also declined; `escaping` states the lifetime consequence at the call.

**Pinned by** `runtime/diagnostic-loggers-dispatch`,
`negative/core-diag-frame-message-escape`, the parameterized and erased
conformance registers, the `diagnostics.retention`,
`diagnostics.delivery-failure`, `origins.escape`, `pointer.integer-origin` and
`host.io-failure` guarantee rows, and the rooted fixture execution path's
recorded merged output.

### D155 — The derived parser is ordinary composition, not a privileged stage

**Prototype 2 said** that a useful parser retains positioned bad input,
reports foreseeable syntax faults through a replaceable sink, recovers and
keeps valid nodes, while allocation, nesting and delivery failures take
explicit paths. It used loops and the future text surface, and therefore did
not settle what the enabled R3 kernel could honestly execute.

**Chosen:** the derived lexer and parser are ordinary rooted Landin modules.
The lexer classifies an intentionally ASCII configuration grammar over
`core/text` byte positions and emits bad-character and unterminated-string
tokens rather than dropping bytes. The recursive-descent parser stores a
recursive variant tree as arena-allocated `value` nodes reached through
`core/vec.list(ptr mut value)`. Syntax mistakes call an erased `any
core/diag.log`, recover at a newline, brace or end boundary, and do not enter
the public error set. Excess nesting is reported and recovered internally.
Only `core/mem.out_of_memory` and `core/io.io_failed` leave `parse_file`.

The same parser body runs with bounded and streaming D154 providers. No
specialized parser copy is emitted or required. Until R4.10 enables loops and
the complete UTF-8 text model, scanner, recovery and sequence walks use
recursion over R3's byte positions; that is an implementation substitution,
not a second parser design.

The program also pins general compilation rules already implied by the
language. A `try` call followed by another statement is the statement form of
[1810], not an expression consuming the rest of the body. A pointer to an
ordinary nominal needs the target's identity without forcing its value layout,
including when nested in a parameterized wrapper; only by-value recursion is
L0313 under D137. A concrete call's named recovery binding and body are checked
even when result inference first reaches the call. Stored aggregate results
from calls or control expressions are produced in caller-owned temporary
storage before being copied into a nested or runtime-addressed destination.
None is a parser-only exception.

**The alternatives:** implementing the workload inside the Ada frontend would
test the wrong language; stopping at the first syntax fault or putting each one
in the declared error channel would reverse Y1 and [0950]; waiting for loops,
UTF-8 text or specialization would make the first major compiler milestone
depend on later surface or optimization work. Adding special AST allocation,
diagnostic or parsing intrinsics would duplicate the ordinary allocator,
container and evidence mechanisms. All were declined.

**Pinned by** `runtime/derived-parser`,
`positive/try-statement-before-return`, its `DERIVATION.md`, the prototype
derivation register, and the complete rooted fixture path.

### D156 — Loop transfers are ordinary CFG edges with lexical cleanup

**The tour said** that [1130] repeats unconditionally, [1140] tests before an
iteration, [1180] gives `break` and `continue` optional guards, and [1100]
executes deferred calls when a lexical block is left. It did not state the
definite-assignment approximation at a back edge or whether a transfer selects
[1110]'s failure-only cleanup.

**Chosen:** the first R4.10 increment enables unlabelled `loop` and `while`
statements and their unlabelled, valueless `break` and `continue` transfers.
The neutral IR represents them only with its existing blocks, branches and
jumps: the loop header is an ordinary backward target, and no loop opcode or
backend-specific form is introduced. A guarded transfer branches after
evaluating its condition once. A taken transfer is a
`Structured_Transfer`, so it runs active `defer` entries from inner to outer
through the loop-body boundary and never selects `undo`.

Definite assignment is intentionally conservative. The condition is checked
with the incoming facts; the body is checked with those facts, but an
assignment made only in an iteration does not establish a fact after the loop.
This is sound for a `while` that may run zero times and avoids claiming a fixed
point the checker has not computed. Origins join the incoming and one-body
facts because that analysis is monotone union. Labels, `break with`,
`complete`, value-producing loops and iterable `for` remain in R4.10 rather
than being approximated in this first increment; D157 subsequently enables
the labels and completion edge without changing this representation.

**The alternatives:** lower a loop to recursion, add a neutral loop opcode,
skip cleanup on iteration edges, or treat one body pass as proof of assignment
after the loop. Recursion changes stack behavior, an opcode duplicates the
existing control-flow graph, skipping cleanup violates lexical registration,
and the last choice is unsound for zero iterations. All were declined.

**Pinned by** `negative/loop-condition-not-bool`,
`runtime/loop-control-flow`, the syntax, resolution, checking, flow, lowering
and verifier seams, and the `control.loops` guarantee row.

### D157 — Loop labels and completion select explicit existing edges

**The tour said** that [1180] gives loops ordinary-name labels and lets
`break` and `continue` name one, while [1170] runs `complete` only when a loop
finishes without `break`. It did not state how an implementation should retain
those targets or whether a conditional loop's false edge and a breaking edge
share one block.

**Chosen:** a label is retained on its loop syntax node and on each targeted
transfer; it is neither a value declaration nor an IR operand. Resolution,
flow checking and lowering select the nearest enclosing loop whose label
matches, while an unlabelled transfer continues to select the nearest loop.
The selected loop's existing cleanup boundary controls [1100]/[1110] exactly
as it does for the nearest-loop form.

A `while` with `complete` has two distinct CFG destinations. Its false
condition edge enters the completion block, whose ordinary fallthrough then
enters the post-loop block. Every `break` targets the post-loop block directly
and therefore skips completion. `continue` still targets the condition header.
An unconditional `loop` has no natural exhaustion edge and consequently
cannot carry `complete`. Definite assignment remains D156's conservative
incoming state after either exit.

**The alternatives:** introduce labels into ordinary lexical name resolution,
encode target depths in the syntax tree, add labelled IR jumps, or route
`break` through `complete` and suppress it dynamically. The first creates a
value namespace where the language promises only control names; the second is
fragile under tree rewrites; the last two duplicate structure already stated
by explicit CFG edges. All were declined.

**Pinned by** `runtime/loop-control-flow`, the syntax, flow and lowering seams,
and the `control.loops` guarantee row.

### D158 — Loop values reuse the caller-owned control join

**The tour said** that [1190]'s `break with` makes a loop an expression, that
every break from such a loop yields the same type, and that a finite loop's
`complete` path supplies its exhaustion value. It did not state where that
value lives while lexical cleanup runs or how a labelled break crosses an
inner loop.

**Chosen:** a value-producing loop has the same consumer-owned neutral join
slot as D125's `if`, `match`, and bare-block expressions. Each taken `break
with` evaluates its guard once, evaluates the value only on the taken edge,
writes the target loop's join slot, performs D156's structured cleanup, and
jumps directly to that loop's post-loop block. A labelled break selects both
the cleanup boundary and join slot of the nearest matching loop; an intervening
loop owns neither.

Every break targeting a value-producing loop must carry `with`, and all values
are checked against the type and complete identity inferred from the first
one or supplied by context. A conditional value loop must have `complete`,
and that block must not fall through: it leaves through a compatible `break
with`. An unconditional loop needs no synthetic exhaustion value because it
has no natural exhaustion edge. Scalar, function, pointer and atom results use
the join's ordinary slot. Fixed arrays, structs, slices and `any` use D125's
destination-aware block-value path; a targeted break retains the complete
destination path while nested control runs, fills it, and only then performs
lexical cleanup. This keeps an arbitrarily nested result target-neutral without
forming an aggregate IR value.

**The alternatives:** add a loop-result IR instruction, store the result in a
compiler-global temporary, evaluate a guarded value before its guard, or pass
an inner loop's destination outward implicitly. Each either duplicates the
existing CFG/storage model, changes source evaluation order, or loses the
explicit labelled target. All were declined.

**Pinned by** `negative/loop-value-missing-break-value`,
`negative/loop-value-missing-completion`, `negative/loop-value-type-mismatch`,
`runtime/loop-values`, `runtime/loop-any-values`, and the `control.loops`
guarantee row.

### D159 — Integer range traversal is retained bounds over ordinary CFG

**The tour said** that [1150] traverses `a..<b` and `a..b`, optionally binds
an index, and shares [1170]--[1190]'s completion, labels and values. It did not
state when bounds run, the index type, what descending bounds mean, or how an
inclusive range ending at the integer maximum avoids an overflow after its
last body execution.

**Chosen:** the first `for` increment admits ascending integer ranges. The
lower bound runs once, then the upper bound runs once; both have one integer
type. The current element is an immutable copy of that type and the optional
index is immutable `usize`, starting at zero. A half-open range tests `<`; an
inclusive range tests `<=` and, after its body, checks equality with the saved
upper bound before incrementing. Thus an inclusive range whose upper bound is
the type's maximum completes without forming an out-of-range successor. A
lower bound greater than the upper bound is an empty traversal.

Lowering uses only D156's slots, comparisons, branches and backward jumps.
`continue` targets the shared step block, so both element and index advance
exactly once; natural exhaustion selects [1170]'s completion block and
`break` skips it. Bounds are outside the body scope. The iteration bindings
are ordinary local declarations inside that scope, so name resolution,
definite assignment and lowering use the same declaration side tables as any
other local. The parser retains collection traversal too, but checking reports
its named R4.10 deferral until [1160]'s permission-sensitive element binding
and iterable evidence are implemented.

**The alternatives:** re-evaluate the upper bound per iteration, desugar the
header into source nodes, widen the element to create an inclusive sentinel,
or give `continue` a separate increment sequence. These change observable
order, invent source that was not written, fail for the widest type, or let
the two paths drift. All were declined.

**Pinned by** `runtime/for-range-traversal`,
`negative/for-range-needs-integer`,
`negative/for-range-endpoints-disagree`,
`negative/for-iterable-missing-conformance`, and the `control.loops`
guarantee row.

### D160 — Collection traversal aliases one element of the source's storage

**The tour said** that [1150] traverses a collection with the same binding
shape as a range, and [1160] that the binding carries no marker because the
type already decided: over `[]mut T` the element is a writable place, over
`[]T` it is not, and over anything else that satisfies iterable it is a
copy. It did not say how a fixed array traverses, when the source is
evaluated, what an index over a collection counts, or whether a read-only
element is a copy or a place.

**Chosen:** the source is evaluated once, before the first test, to a base
address and an element count: a slice supplies both, and a fixed array
supplies the address of its storage and its compile-time length. A hidden
`usize` counter runs from zero while it is below that count; the optional
index binding is that counter. Before each body run the element's address is
formed from the base and the counter, and the element binding is an alias
through that address for the whole body: reads and writes go through it, so
a body that writes the storage by index sees the change through the element
and vice versa. A slice element is writable when the slice is `[]mut T`; a
fixed array's element is writable when the array itself sits in a place the
body could assign, which is the same question `items[k] = v` asks of
`items`. Every other element is a read-only place, refused at a write by
L0303 with [1160]'s note. An element whose type is a scalar, pointer, atom,
function or struct is enabled. An array, slice or `any` element, and a source
that is a struct or `any` value awaiting [1320]'s iterable evidence, keep the
named R4.10 refusal, L0304.

Lowering keeps this inside the existing alias table that D78's payload
bindings and [0990]'s named returns already use: the element declaration
maps to a runtime-address alias whose slot is refreshed in the loop body's
first block. Scalar reads and writes of the element load and store through
that address; struct elements reach their fields through the same rooted
storage a slice index produces. No new IR opcode, slot kind or verifier rule
was added. Origin analysis gives the element the source's facts, so a
reference read out of an element derives from wherever the storage came
from. Definite assignment treats every part of a struct element as assigned
on entry to the body, as it does a copied struct.

**The alternatives:** copy each element into a local and write it back
after the body, which would make `items[k]` and `item` disagree inside one
iteration and would silently drop a write when the body leaves through
`break`; hand out a pointer and require `item.val`, which contradicts [1160];
or desugar the loop into an index loop over source nodes, which invents
source that was not written. All were declined.

**Pinned by** `runtime/for-collection-traversal`,
`negative/for-collection-element-read-only`,
`negative/for-source-not-traversable`,
`negative/for-iterable-missing-conformance`, and the `control.loops`
guarantee row.

### D161 — Byte-context text is a pooled read-only datum and slice

**The tour said** that [0260]'s text literal takes `utf8`, `[]u8`, `utf16` or
`cstring` from context, defaults to `utf8`, lives in read-only storage and
carries an uncounted trailing NUL. [0270] closed its escape set and separated
byte escapes from codepoint escapes. It did not state whether one literal
context could be enabled before the text types, whether equal literals share
an object, or which stage owns malformed spelling.

**Chosen:** the seventh R4.10 increment admits a quoted literal only where a
direct context supplies read-only `[]u8`. Its unescaped source content must be
shortest-form UTF-8; `\n`, `\r`, `\t`, `\e`, `\\`, `\"`, `\'` and `\xNN` decode
to bytes, including an arbitrary byte from `\xNN`. A well-formed `\u{...}` is
text rather than bytes and is L0301 in this context. A literal with no context
still defaults to the deferred `utf8` and is L0304; `utf8`, `utf16`, `cstring`
and their codepoint representation remain later R4.10 work at this decision.
D181 supplies them.

Malformed UTF-8 source content or an unknown, incomplete or nonscalar escape
is lexical L0320 at the offending run. The scanner first retains the complete
escape-aware token, so an escaped quote cannot close it; the shared decoder
then validates every token before configuration can hide a declaration. An
unclosed token remains L0014. The parser retains one text node and its source
span, and checking supplies its complete immutable `[]u8` reference
descriptor.

Lowering decodes the content into one anonymous target-neutral fixed array of
`u8`, appends one zero byte, marks the datum read-only and constructs each
literal value as its base address plus the decoded length. Equal decoded byte
sequences throughout the program use one datum, even when their source escape
spellings differ; this identity is observable when their element addresses
are converted to integers. Module values carry the same datum relocation and
length as a static slice image. Anonymous datums are registered before item
bodies are filled and completed in item order afterward, preserving the IR's
contiguous-run invariant. The Linux backend emits them in `.rodata`; no text
opcode, runtime initialization or writable copy was added.

**The alternatives:** enable `utf8` and codepoint decoding at the same time,
make a literal a fixed `[N]u8`, synthesize a writable copy in each context,
give equal occurrences distinct storage, omit the trailing NUL, or let the
checker and lowering each interpret escapes independently. Those choices
either pull [0600]'s indexing and representation questions into this slice,
lose [0260]'s contextual carrier or read-only promise, duplicate flash on the
small targets the language preserves, contradict the stated C boundary, or
permit two compiler stages to disagree about the bytes. All were declined.

**Pinned by** `runtime/text-literal-bytes`,
`negative/text-literal-codepoint-in-byte-context`,
`negative/text-literal-malformed-codepoint-escape`,
`negative/text-literal-needs-byte-slice`,
`negative/text-literal-needs-read-only-slice`,
`negative/text-literal-short-byte-escape`,
`negative/text-literal-unknown-escape`, `negative/text-literal-write`, the
lexer and backend cases, and the `source.lexical` and `text.literal-storage`
guarantee rows.

### D162 — Decimal f32 and f64 values keep IEEE bits through runtime operations

**The tour said** that f16, f32 and f64 exist [0170], that a float literal is
recognisably distinct from an integer [0210], that decimal exponents and
separators are accepted [0220], and that signed zero and arithmetic-produced
IEEE special values are observable [0240]. It did not state the type of a
contextless float, whether one width could arrive before the others, how a
finite decimal overflow is treated, or whether module folding may inherit the
compiler host's arithmetic.

**Chosen:** the eighth R4.10 increment enables f32 and f64. A decimal literal
has digits on both sides of its dot and may have `e` or `E`, an optional sign,
and a nonempty decimal exponent; underscores follow the integer digit-run
rule. It takes f32 or f64 from context and otherwise defaults to f32. Integer
and float literals remain separate classes with no implicit conversion. The
literal rounds once to IEEE binary32 or binary64; a finite spelling that would
become infinity is L0300. Unary minus flips the IEEE sign bit, preserving
negative zero and a NaN payload.

At runtime `+`, `-`, `*`, `/`, unary minus and all six comparisons use the
value's IEEE width. Division by signed zero yields infinity or NaN rather than
[1950]'s integer refusal or trap. Equality is false for an unordered NaN,
inequality true, and every ordered comparison false. Values retain their raw
bits through local and module scalar storage, fixed arrays, ordinary structs,
internal parameters and returns. Representation-class routine sharing treats
a float as distinct from a same-width integer. The first external C boundary
continues to refuse float signatures until R4.40 supplies its register classes.

A module float at this increment may use a literal, its unary minus or
`zeroed`, also inside a static aggregate image. Float arithmetic in a module
image remains a named R4.10 refusal: the target-neutral folder does not borrow
the compiler host's rounding mode or NaN behavior. D166 subsequently enables
hexadecimal floats [0230], D167 enables the named `infinity` and `nan` members
[0240], and D175 enables module float arithmetic and comparison. f16 and
explicit integer/float conversions [0310] remain separate hosted increments.

**The alternatives:** default to f64, admit decimal literals only with an
explicit type, treat a float's same-width integer carrier as interchangeable,
lower float operations through integer arithmetic, or evaluate module values
with the Ada host's float types. Those choices contradict the tour's inferred
f32 examples, lose IEEE behavior, make routine sharing change operations, or
make cross-compilation depend on the host.

**Pinned by** `runtime/float-decimal-runtime`,
`negative/float-literal-not-enabled`,
`negative/float-literal-overflows-context`,
`negative/float-remainder-is-integer-only`,
`negative/float-type-not-enabled`,
`negative/integer-literal-not-a-float`,
`negative/malformed-float-exponent`,
`negative/external-float-abi-not-enabled`, the lexer cases, and the
`float.ieee` guarantee row.

### D163 — A character is one decoded Unicode scalar with fixed type u32

**The tour said** that [0250]'s character literal is a codepoint typed `u32`
and [0270] gives literals one closed escape set. It did not say whether the
byte escape denotes a character, whether raw source may contain more than one
scalar, or which stage rejects a nonscalar `\u{...}` value.

**Chosen:** the ninth R4.10 increment admits a single-quoted literal only when
its content decodes to exactly one Unicode scalar value. Raw content is one
shortest-form UTF-8 scalar. The simple escapes `\n`, `\r`, `\t`, `\e`, `\\`,
`\"` and `\'` denote their codepoints, and `\u{...}` denotes one scalar written
in hexadecimal. The byte-only `\xNN` form is not a character spelling. Empty,
multiple, malformed UTF-8, unknown-escape, surrogate and above-`10FFFF`
contents are lexical L0322; an unclosed quote remains L0014.

The literal's type is always `u32`, including in an inferred binding. A
different scalar context is L0301 rather than an implicit conversion. Its
decoded value uses the existing integer constant carrier, arithmetic,
comparison, module folding and aggregate images; the IR and backend need no
character-specific operation or representation. Lexing, checking and lowering
call one decoder so they cannot disagree about the scalar.

**The alternatives:** treat `\xNN` as a codepoint, infer an integer type from
context, retain UTF-8 bytes as the value, or permit a quoted grapheme cluster.
Those choices erase [0270]'s byte/codepoint boundary, contradict [0250]'s fixed
type, or turn a scalar literal into the text representation work [0600] owns.
All were declined.

**Pinned by** `runtime/character-literal-codepoints`,
`negative/character-literal-byte-escape`,
`negative/character-literal-empty`,
`negative/character-literal-invalid-codepoint`,
`negative/character-literal-multiple`,
`negative/character-literal-needs-u32`, the decoder and lexer cases, and the
`source.lexical` and `types.values` guarantee rows.

### D164 — Raw byte text uses matching quote runs and exact indentation

**The tour said** that [0280]'s raw literal has the same number `N` of quotes
on each side, with `N` at least three, interprets no escape, and strips the
closing delimiter's indentation from every line. It did not define whether a
longer quote run closes a literal, how indentation mismatches are handled, or
which currently enabled text carrier receives the bytes.

**Chosen:** the tenth R4.10 increment admits raw literals in D161's direct
read-only `[]u8` context. The maximal opening quote run chooses `N`; the first
later run of at least `N` quotes closes the token, consumes exactly `N`, and
leaves any additional quotes for following tokens. Runs shorter than `N` are
content. Backslashes and [0270]'s apparent escapes are ordinary bytes. Raw
source content must remain shortest-form UTF-8, and the view carries the same
uncounted trailing NUL as quoted text. At this decision a literal without a
direct byte-slice context defaults to the then-deferred `utf8`; D181 later
enables that default.

A closer is line-leading when an earlier line ending is followed only by
spaces or tabs before it. That exact byte prefix is removed at the start of
every nonblank content line that begins after a line ending; content on the
opener's own line is unchanged. A nonblank line with a shorter or different prefix is lexical
L0323; horizontal bytes on a blank line are discarded. Line endings, including
the one immediately after an opener or before the closer, remain content. An
inline closer has no indentation to remove. A mismatched or absent closing run
remains the existing unterminated-literal L0014.

After indentation is removed, raw and quoted literals with equal byte content
share D161's one pooled read-only datum. Checking, module images, aggregate
fields, calls and lowering otherwise use the same slice path; neither IR nor
the backend learns a raw-literal operation.

**The alternatives:** fix the delimiter at three quotes, close on a shorter
run, silently leave under-indented lines unchanged, count visual columns rather
than exact source bytes, interpret escapes, or allocate raw and quoted content
separately. Those choices contradict [0280], make tabs target/editor dependent,
or duplicate representation that is observably identical after decoding. All
were declined.

**Pinned by** `runtime/raw-literal-bytes`,
`negative/raw-literal-inconsistent-indentation`,
`negative/raw-literal-needs-read-only-slice`,
`negative/raw-literal-write`, `negative/unterminated-raw-literal`, the raw
decoder and lexer cases, and the `source.lexical` and `text.literal-storage`
guarantee rows.

### D165 — Compound assignment retains one destination and one operator

**The tour said** that assignment is a statement, listed thirteen compound
spellings [0390], fixed destination-before-value evaluation [0410], and said
that `inc x` means what `x += 1` means [0400]. It did not say whether the
destination was re-evaluated for its implicit read, whether it had to be
assigned already, or whether a compound form inherited every failure boundary
of its binary operator.

**Chosen:** `place op= value` evaluates `place` once, reads its existing scalar
value, evaluates `value`, applies the corresponding [1820] binary operator and
writes the result through that retained place. The thirteen forms are `+=`,
`-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `<<=`, `>>=`, `+%=`, `-%=` and
`*%=`. Destination evaluation and its implicit read both precede the
right-hand expression. A computed index or pointer path is retained as an
internal address, not reconstructed after the expression.

The destination must be assigned on every arriving path because the operation
reads its old value; success leaves it assigned. It needs the same binding or
reference write permission as plain assignment. Both operands have the
destination scalar type under [1890]: ordinary arithmetic admits integers and
floats, while remainder, wrapping, shifts and bitwise forms admit integers
only. Known zero integer divisors and negative shifts retain [1950]'s L0306.
Runtime checked overflow and impossible integer operands retain [1960]'s trap;
the three wrapping forms and admitted shifts remain total. Float division by
signed zero retains D162's IEEE result.

This is one read-modify-write language operation but makes no atomicity or
concurrency claim. Aggregates, slices, `any`, functions, pointers and atoms
have no applicable binary operator and are L0301 rather than acquiring a
copy-update meaning.

**The alternatives:** desugar by copying the place syntax into both sides of
plain assignment, evaluate the right-hand side before reading the old value,
let an unassigned destination become initialized, or define separate compound
operator rules. Those choices duplicate observable calls in indexes, reverse
[0410], permit a read of indeterminate storage, or let two spellings of one
operation drift. All were declined.

**Pinned by** `runtime/compound-assignment`,
`runtime/compound-assignment-overflow-traps`,
`negative/compound-assignment-as-expression`,
`negative/compound-assignment-float-remainder`,
`negative/compound-assignment-immutable`,
`negative/compound-assignment-unassigned`,
`negative/compound-assignment-zero-divisor`, and the `arithmetic.known`,
`arithmetic.runtime`, `arithmetic.total` and `assignment.flow` guarantee rows.

### D166 — Hexadecimal floats are converted from source bits, not host floats

**The tour said** that [0230]'s hexadecimal float literals express every
representable value exactly, including subnormals. It did not define the
required exponent syntax, the result of a spelling between two representable
values, or whether the compiler may ask its own floating-point implementation
to read the value.

**Chosen:** a hexadecimal float is `0x`, a nonempty hexadecimal digit run, a
dot, another nonempty hexadecimal digit run, and a required `p` or `P` binary
exponent. The exponent has an optional sign and a nonempty decimal digit run.
Each digit run admits [0220]'s separators but neither begins nor ends with one.
Like D162's decimal form, the literal takes f32 or f64 from context and
otherwise defaults to f32; it remains a float rather than sliding into the
integer class.

Conversion reads the hexadecimal significand as bits and combines it with the
written binary exponent. An exactly representable normal or subnormal value
therefore reaches its target with the exact bits [0230] promises. A value
between target values rounds to nearest with ties to even, including at zero,
the subnormal/normal boundary and an exponent carry. Underflow may produce
zero. A finite spelling that rounds to infinity is L0300, as for D162's decimal
form; a zero significand remains zero even with an arbitrarily large exponent.

The conversion uses only bounded integer accumulation of the significant,
round and sticky bits. It does not parse through an Ada floating-point type,
so cross-compilation does not inherit the host's width, rounding mode or
handling of subnormals. The resulting IEEE pattern follows every D162 storage,
aggregate, internal-call, arithmetic and comparison path without new IR or
backend operations. An absent or incomplete binary exponent is lexical L0321.
Enabling this form removes the scanner's final deferred token family; L0010
continues to name parser-level constructs that [1830] leaves disabled.

**The alternatives:** use the compiler host's hexadecimal conversion, accept
only spellings already exact in the contextual width, or retain an arbitrary
precision significand. The first makes a target value host-dependent, the
second contradicts ordinary literal rounding, and the third retains far more
source state than the precision, round bit and sticky bit require. All were
declined.

**Pinned by** `runtime/float-hexadecimal-runtime`,
`negative/hex-float-overflows-context`,
`negative/malformed-hex-float-exponent`, the lexer cases, and the `float.ieee`
and `source.lexical` guarantee rows.

### D167 — IEEE special values are inherent type-qualified constants

**The tour said** that [0240] writes infinity and NaN as members of a float
type, that unary minus supplies their negative forms, and that NaN comparison
is unordered. It did not say whether the qualifier or the surrounding context
chooses the width, which NaN payload a source name denotes, whether a signed
NaN retains that sign, or whether the names are valid module images.

**Chosen:** the thirteenth R4.10 increment enables exactly `f32.infinity`,
`f64.infinity`, `f32.nan` and `f64.nan`. The type before the dot is an inherent
part of the value: it does not convert to another contextual float width, so a
width mismatch is L0301. No other scalar type has these members, and no other
member of f32 or f64 is a named value. An unknown type-qualified member is
also L0301 rather than an unresolved module or runtime field selection.

Infinity has the ordinary positive IEEE pattern. `nan` denotes one canonical
quiet NaN: `0x7FC00000` for f32 and `0x7FF8000000000000` for f64. Unary minus
flips only the sign bit of either named value, preserving the quiet NaN's
payload. These bits use the existing float IR carrier, storage, internal-call,
arithmetic and comparison paths; no new runtime operation or backend opcode is
introduced.

A named special and its unary minus are compile-time scalar leaves, not member
reads from storage. They are therefore valid in module scalar images and in
the scalar leaves of module arrays and structs wherever a float literal is
valid. General module float arithmetic remains D162's L0304 boundary at this
increment and is subsequently enabled by D175. f16 and explicit integer/float
conversions remain separate hosted increments.

**The alternatives:** infer the width from context despite the written type,
spell the values as unqualified lexical literals, preserve an unspecified or
host-chosen NaN payload, or reject them from static images as field reads.
Those choices respectively make the qualifier misleading, add another token
family for values the tour writes as members, make generated target bits
depend on the compiler host, or deny a constant spelling where an equivalent
literal image is already accepted. All were declined.

**Pinned by** `runtime/float-named-specials`,
`negative/float-special-name-unknown`,
`negative/float-special-on-integer-type`,
`negative/float-special-width-mismatch`, the direct checking case, and the
`float.ieee` guarantee row.

### D168 — Integer conversion checks a mathematical value, not its bits

**The tour said** that [0310] writes conversion as a type applied to a value,
rejects an impossible compile-time conversion, and traps when a runtime value
does not fit. It did not say whether signedness changes reinterpret a pattern,
whether every enabled integer width participates, or how a module conversion
is folded without compile-time execution.

**Chosen:** the fourteenth R4.10 increment enables an application of any
enabled integer type to one integer value. The source keeps its own integer
type and the destination is the applied type; no contextual or implicit
conversion is introduced. The mathematical source value must lie between the
destination's inclusive minimum and maximum. Widening a signed value therefore
preserves its sign, a negative value never converts to unsigned, and crossing
to a signed type rejects an unsigned value above that signed maximum. There is
no truncation, wrapping or same-width bit reinterpretation.

An integer literal operand is checked immediately in the destination context.
A conversion of a module-known integer expression is folded through the same
target-aware integer fold as its source; an impossible known result is L0300.
At runtime the neutral IR retains the source and destination integer types, and
the Linux backend sign- or zero-extends the source before comparing it with the
destination bounds. An out-of-range value reaches [1950]'s existing `ud2` trap;
an in-range value stores the destination-width pattern. The same conversion
opcode continues to carry [0470]'s pointer-to-integer address check.

Conversion from a float to an integer and conversions involving bool remain
L0304 at this increment. D169 subsequently admits conversion between the two
enabled float widths, D170 admits conversion from an enabled integer to either
float width, D171 admits the remaining float-to-integer direction, and D172
admits bool as an integer source, and D173 admits integer-to-bool conversion.
Float-to-bool conversion and the deferred u128, i128 and packed integer widths
gain no spelling through this increment.

**The alternatives:** reinterpret the low bits, make narrowing wrap, allow a
negative signed value to cross to same-width unsigned, or give module
conversions a runtime initializer. Those choices contradict [0310]'s fit and
trap rule, make signedness a representation cast, or contradict [1460]'s rule
that nothing runs before the entry point. All were declined.

**Pinned by** `runtime/integer-conversions`,
`runtime/integer-conversion-out-of-range-traps`,
`runtime/integer-conversion-signed-overflow-traps`,
`runtime/integer-conversion-unsigned-overflow-traps`,
`negative/integer-conversion-known-binding-out-of-range`,
`negative/integer-conversion-known-out-of-range`, and the
`conversion.integer` guarantee row.

### D169 — Float-width conversion rounds an IEEE value, not its carrier

**The tour said** that [0310] writes conversion as a type applied to a value,
rejects an impossible compile-time conversion, and traps when a runtime value
cannot convert. It did not say how f64 narrows to f32, whether underflow or
loss of precision is impossible, or what happens to signed zero, infinity and
NaN.

**Chosen:** the fifteenth R4.10 increment enables f32 or f64 applied to one
float value. An untyped float literal is checked directly in the destination
context, as every contextual literal is under [1880]. A typed f32-to-f64
conversion is exact. A typed f64-to-f32 conversion rounds to nearest with ties
to even, including at the subnormal boundary; loss of precision and underflow
to signed zero are ordinary IEEE rounding rather than failures.

Signed zero and infinity retain their sign and class. A NaN remains a quiet
NaN with its sign; its payload after a width change is not a language-visible
identity. A finite f64 which would round beyond f32's greatest finite value is
the one impossible width conversion: L0300 rejects it when the source is known
under [1880] or [1940], and an otherwise identical runtime conversion traps.
Converting infinity is not overflow because infinity is a value of both float
types.

Module-known conversions fold their IEEE carrier bits with bounded integer
work, including the narrowing round bit and sticky bits, so cross-compilation
does not borrow the compiler host's float conversion. Runtime Linux x86-64
uses the corresponding SSE width conversion and explicitly distinguishes a
finite result overflow from an infinity or NaN source. The existing
target-neutral conversion operation now admits every numeric result. D170
subsequently admits its integer-to-float direction, D171 admits its
float-to-integer direction, D172 admits bool as an integer source, D173 admits
integer-to-bool conversion, D174 admits float-to-bool conversion, and D176
admits bool as a float source.

**The alternatives:** require exact representability, silently produce
infinity on finite overflow, trap on gradual underflow, expose a NaN payload
mapping, or fold module conversions through a host float. Those choices make
ordinary IEEE narrowing impractical, contradict [0310]'s impossible-conversion
rule, discard gradual underflow, turn an unspecified IEEE payload into source
identity, or make cross-target output depend on the compiler host. All were
declined.

**Pinned by** `runtime/float-width-conversions`,
`runtime/float-width-conversion-overflow-traps`,
`negative/float-width-conversion-known-out-of-range`, and the
`conversion.float-width` guarantee row.

### D170 — Integer-to-float conversion rounds the mathematical integer

**The tour said** that [0310] makes conversion explicit and distinguishes an
impossible known conversion from one which traps at runtime. It did not say
whether integer-to-float conversion requires exact representation, how it
rounds, or whether the upper half of u64 participates.

**Chosen:** the sixteenth R4.10 increment enables f32 or f64 applied to a value
of any enabled integer type. The source is the integer's mathematical value,
not its carrier bits. An untyped integer operand first takes [0200]'s default
i32 source type; a wider literal therefore writes an explicit integer
conversion before the float conversion. There is still no implicit conversion
between numeric classes.

An exactly representable integer is preserved. Every other value rounds to
nearest with ties to even. Every enabled integer, including u64's maximum and
i64's minimum, lies inside the finite range of both f32 and f64, so precision
loss is ordinary rounding and no integer-to-float conversion can report L0300
or trap. The result of converting integer zero is positive zero.

The module folder derives the IEEE exponent and retained, round and sticky bits
with bounded integer work. The Linux backend sign- or zero-extends narrower
sources before SSE conversion. Because SSE's qword conversion is signed, a u64
above i64's maximum is halved with its low bit retained as sticky information,
converted, and doubled; this produces the same nearest-even result without
reinterpreting the source as negative. The neutral conversion verifier admits
this one mixed-class direction. D171 subsequently admits the other direction;
D172 admits bool as an integer source, D173 admits integer-to-bool conversion,
D174 admits float-to-bool conversion, and D176 admits bool-to-float conversion.

**The alternatives:** require exact representation, saturate at a float
boundary, reinterpret an unsigned carrier as signed, use a compiler-host float
for module images, or make the conversion implicit. Those choices discard the
ordinary IEEE conversion rule, invent a failure despite the float range, lose
the upper half of u64, make cross-target output host-dependent, or contradict
[0310]. All were declined.

**Pinned by** `runtime/integer-to-float-conversions`,
`negative/float-to-bool-known-invalid`, and the
`conversion.integer-to-float` guarantee row.

### D171 — Float-to-integer conversion truncates before checking range

**The tour said** that [0310] makes conversion explicit, rejects an impossible
compile-time conversion, and traps when a runtime value cannot convert. It did
not say how a fractional float becomes an integer, whether the fractional part
participates in the range check, or what infinity and NaN mean as integers.

**Chosen:** the seventeenth R4.10 increment enables every enabled integer type
applied to an f32 or f64 value. A typed source retains its float width. An
untyped float operand first takes [0210]'s default f32 type, so the source is
rounded to f32 before conversion; there is still no implicit conversion
between numeric classes.

The finite source is truncated toward zero, then that mathematical integer is
checked against the destination's inclusive range. The ordering matters:
`u8(-0.75)` is zero and succeeds, while `u8(-1.0)` fails; `i8(-128.9)` is
-128 and succeeds, while `i8(-129.0)` fails. Infinity and NaN have no integer
result and always fail. A known failure is L0300 under [1880] or [1940], and an
otherwise identical runtime failure traps under [1950].

The module folder decodes the IEEE sign, exponent and significand with bounded
integer work and checks the truncated magnitude without using the compiler
host's floating-point conversion. The Linux backend performs the same carrier
decode directly rather than using SSE's indefinite overflow result, which
cannot distinguish every valid u64 value from failure. The neutral conversion
operation consequently admits either numeric class in either direction;
D172 subsequently admits bool as an integer source and D173 admits integer as
a bool source; D174 subsequently admits float as a bool source.

**The alternatives:** round to nearest, floor negative values, saturate at the
destination boundary, reinterpret the carrier bits, use a compiler-host float
for module images, or assign an integer sentinel to infinity or NaN. Those
choices either invent a different ordinary conversion rule, hide [0310]'s
required failure, make cross-target output host-dependent, or give nonfinite
values a mathematical integer they do not have. All were declined.

**Pinned by** `runtime/float-to-integer-conversions`,
`runtime/float-to-integer-out-of-range-traps`,
`runtime/float-to-integer-nan-traps`,
`negative/float-to-integer-known-out-of-range`,
`negative/float-to-integer-known-nan`,
`negative/float-to-bool-known-invalid`, and the
`conversion.float-to-integer` guarantee row.

### D172 — A bool has the integer image zero or one

**The tour said** that bool is a scalar type [0180] and that conversion is an
explicit type application [0310]. It did not assign a numeric image to false
or true, or say whether every numeric value has a truth value.

**Chosen:** the eighteenth R4.10 increment enables any enabled integer type
applied to a bool value. False converts to zero and true converts to one. Both
values lie in every enabled signed and unsigned integer range, so this
direction is total: it cannot report L0300 or trap. Typed and inferred module
values fold to the same image, and runtime conversion zero-extends the bool's
one-byte carrier before storing the destination width.

This increment does not define truthiness. Applying bool to an integer or
float remains L0304, as does applying a float type to bool. D173 subsequently
admits only zero and one from the integer direction, and D174 settles the
float-to-bool direction including negative zero, infinity and NaN. D176 later
maps bool's already-fixed images into the two enabled float widths.

**The alternatives:** use all-bits-one for true, preserve an unspecified bool
carrier, or simultaneously admit numeric-to-bool truthiness. Those choices
make the result depend on representation or settle a distinct semantic
question without program evidence. All were declined.

**Pinned by** `runtime/bool-to-integer-conversions`,
`negative/float-to-bool-known-invalid`, and the
`conversion.bool-to-integer` guarantee row.

### D173 — Only the canonical integer images convert to bool

**The tour said** that conversion is explicit and an impossible conversion is
refused when known or traps at runtime [0310]. D172 fixed bool's integer images
at zero and one, but did not say whether conversion back accepts only those
images or assigns truth to every nonzero integer.

**Chosen:** the nineteenth R4.10 increment enables bool applied to any enabled
integer value. Integer zero converts to false and integer one converts to true;
every other value is impossible. An untyped integer first takes [0200]'s
default i32 type, preserving the rule that conversions retain a typed source
rather than giving the literal a bool context.

A direct literal or module-known chain outside zero and one is L0300. A runtime
source is zero-extended from its own width, compared with one, and traps before
storing the one-byte bool result when it is larger; a signed negative carrier
therefore fails the same comparison without being mistaken for true. Module
images fold the source integer before reserving data. The neutral conversion
operation now admits bool on either side of the integer boundary.

Float-to-bool remains L0304 at this increment. D174 subsequently settles
signed zero, fractional values, infinity and NaN rather than inferring them
from the integer image rule.

**The alternatives:** make every nonzero integer true, accept any value whose
low bit is one, saturate into the bool domain, or reinterpret the low byte.
Those choices make conversion hide a noncanonical value or become a bit cast,
where [0310] instead provides a checked boundary. All were declined.

**Pinned by** `runtime/integer-to-bool-conversions`,
`runtime/integer-to-bool-out-of-range-traps`,
`negative/integer-to-bool-known-out-of-range`,
`negative/float-to-bool-known-invalid`, and the
`conversion.integer-to-bool` guarantee row.

### D174 — Float converts to bool only at its canonical images

**The tour said** that conversion is explicit and impossible conversions are
refused when known or trap at runtime [0310]. D172 fixed false and true at the
mathematical integer images zero and one, while D173 accepted only those
integer images on conversion back. Neither decided how the IEEE values around
those images behave.

**Chosen:** the twentieth R4.10 increment enables bool applied to f32 or f64.
Positive and negative zero both convert to false because they compare equal as
IEEE numbers. Exactly positive `1.0` converts to true. Every other value,
including negative one, fractions, infinity and NaN, is impossible. An untyped
float first takes [0210]'s default f32 type, preserving its source width before
conversion.

A direct or module-known impossible source is L0300; the equivalent runtime
case traps. Static folding decodes the IEEE carrier with bounded integer work.
The Linux backend ignores the sign bit only while recognizing zero, then
requires the complete positive-one carrier, so negative zero succeeds but
negative one does not. This was recorded as completing explicit conversion
among the enabled scalar types, but D172's bool-to-float refusal still remained
in the checker; D176 closes that omitted direction without introducing
implicit truthiness.

**The alternatives:** make every nonzero float true, accept any value that
truncates to zero or one, reject negative zero, or make NaN true because it is
not equal to zero. Those choices import truthiness, make conversion silently
discard a fraction, or distinguish IEEE zeros where ordinary comparison does
not. All were declined.

**Pinned by** `runtime/float-to-bool-conversions`,
`runtime/float-to-bool-invalid-traps`,
`negative/float-to-bool-known-invalid`, and the
`conversion.float-to-bool` guarantee row.

### D175 — Module float arithmetic is an IEEE carrier fold

**The tour said** that module values are known before execution [1460], that
the known subset contains operators over known values [1940], and that f32 and
f64 arithmetic and comparisons have IEEE behavior [0290], [0350]. D162 left
module float operators deferred because using the compiler host's float
operations would make cross-compilation inherit that host's rounding mode and
NaN behavior.

**Chosen:** the twenty-first R4.10 increment enables module-level f32 and f64
`+`, `-`, `*`, `/` and all six comparisons. Operands may be any [1940]-known
float expression, including forward or chained module names, conversions,
named infinities and NaNs. Their results may initialize scalar bindings or
scalar leaves of module arrays, repetitions, structs and variant images.

The shared target-neutral evaluator decodes IEEE carrier bits and uses bounded
integer significands for addition and division and a double-width integer for
the exact product. Every finite result rounds once to nearest with ties to even
and retains gradual underflow. Exact cancellation produces positive zero;
otherwise the IEEE sign rules preserve signed zero. Arithmetic overflow and
finite division by signed zero produce signed infinity rather than L0300 or a
trap. Invalid operations and arithmetic with a NaN produce the width's D167
canonical positive quiet NaN; NaN payload propagation is not a source-visible
identity. Comparisons equate the two zeros, order finite values and infinities,
and leave NaN unordered, so only `<>` is true for an unordered pair.

Checking, static aggregate-image lowering and Linux datum emission call the
same evaluator. No module initializer runs, no float operation is added to a
datum at runtime, and no compiler-host floating-point operation decides an
image. The ordinary runtime path remains the SSE implementation D162 already
enabled.

**The alternatives:** fold through Ada float operations, reject overflow or
division by zero because integer module folds do, preserve a host-selected NaN
payload, flush subnormals to zero, or keep float comparisons out of module bool
images. Those choices respectively make cross-compilation host-dependent,
contradict IEEE arithmetic, expose an unspecified carrier detail, lose gradual
underflow, or leave [1940]'s operator subset inconsistent by operand class.
All were declined.

**Pinned by** `runtime/module-float-arithmetic`, the direct checking vectors,
and the `float.ieee` guarantee row.

### D176 — Bool converts to exact positive float images

**The tour said** that conversion is explicit [0310], that bool has only false
and true [0180], and that f32 and f64 carry IEEE binary32 and binary64 [0170].
D172 fixed bool's mathematical images at zero and one but deliberately left a
float type applied to bool refused. D174 was then recorded as completing the
enabled scalar conversion matrix even though that refusal remained.

**Chosen:** the twenty-second R4.10 increment enables f32 or f64 applied to a
bool value. False converts to exactly positive floating zero and true converts
to exactly positive floating one. Both images are exact in binary32 and
binary64, so this direction is total: it cannot report L0300 or trap, and it
does not introduce truthiness or an implicit conversion.

The target-neutral fold writes the destination width's exact IEEE carrier for
literal, named and computed module-known bool values, including scalar leaves
of array and struct images. Runtime Linux code zero-extends the canonical
one-byte bool and converts that zero or one into the selected SSE width. The
neutral conversion verifier admits bool as a source for either numeric class.
f16 remains refused, and [1975]'s external floating-point ABI remains deferred;
neither boundary is changed by an internal scalar conversion.

**The alternatives:** reinterpret bool's byte as float bits, produce negative
zero for false, route through a contextual integer conversion, or keep the
direction refused. Those choices contradict D172's mathematical images, make
the result representation-dependent, add a conversion not written by the
program, or leave the claimed scalar matrix incomplete. All were declined.

**Pinned by** `runtime/bool-to-float-conversions` and the
`conversion.bool-to-float` guarantee row.

### D177 — A module bool is a static image, not routine control flow

**The tour said** that bool has only `false` and `true` [0180], that its
logical words return bool [0340], and that `and` and `or` short-circuit from
left to right [0410]. [1460] says nothing runs before the entry point, while
[1940] admits every [1820] operator over module-known values. D24 already
applies those rules to scalar leaves of module aggregate images. The remaining
scalar path nevertheless lowered `and` and `or` through routine-style CFG, and
the backend's datum fold correctly rejected its `Branch` instruction.

**Chosen:** the twenty-third R4.10 increment makes every scalar module bool a
target-neutral static image. The one shared lowering-time folder evaluates
literal, named, forward and chained module-known operands, comparisons, `not`,
`and` and `or`; its existing logical cases visit the left operand first and
visit the right operand only when the result still depends on it. The same
folder continues to write bool leaves in fixed arrays, repetitions, structs
and variants. A bool datum's neutral block carries no computed value, and datum
emission reads its canonical zero-or-one image directly, so no initializer is
executed and no CFG `Branch` reaches data emission. Routine expressions keep
their existing CFG and observable short-circuit behavior.

This is an implementation conformance repair, not a new source rule. Checking
still validates every written subtree before folding: short-circuiting does not
hide an ill-typed operand, a call, an impossible integer operand, or another
initializer that [1940] refuses. Module declaration order remains irrelevant
[0130], and a cycle remains refused even if another declaration could skip a
reference to it.

**The alternatives:** teach the backend datum fold to interpret CFG, add a
non-short-circuit logical opcode, or retain a second scalar-only syntax folder.
Those choices respectively turn static data into executable control, contradict
[0410], or let scalar and aggregate images disagree. All were declined.

**Pinned by** the lowering case `module bools become static images`,
`runtime/module-known-short-circuit-bools`, the generated IR, and the
`module.images` guarantee row.

### D178 — Aggregate traversal elements keep their storage shape

**The tour said** that a fixed array's element type is part of its structural
identity [0520], that a slice carries its element type and permission [0570],
and that collection traversal binds an element place [1150] [1160]. D160
enabled scalar, pointer, atom, function and ordinary-struct elements but left
fixed-array, slice and `any` elements together behind L0304. It did not require
those three runtime representations to advance together.

**Chosen:** the next collection-traversal increment enables an element whose
type is a fixed array or slice. The containing fixed array records the complete
immediate element shape: an inner fixed array retains its length, scalar or
nominal element and nominal identity; an inner slice retains its full reference
descriptor. A slice source already carries the equivalent descriptor. The
element binding receives that shape before its body is checked, and definite
assignment treats the complete fixed-array value or the two slice cells as
assigned on every entered iteration.

D160's source and control rules do not change. The collection expression runs
once, the hidden `usize` counter visits addresses in increasing index order,
and the binding remains an alias to the selected storage for the complete body.
Replacing a whole fixed-array or slice element requires the write permission of
the containing collection. Indexing through a slice element separately follows
the `mut` permission carried by that inner slice. `continue`, labelled or
unlabelled `break`, natural `complete`, and lexical cleanup retain their D157
and D158 edges.

A `break with` may copy the fixed-array value or the two-cell slice descriptor
from the current alias into the caller-owned loop destination before cleanup.
Target-neutral lowering represents the runtime alias with the existing
address-shaped slot. A computed scalar index below a fixed-array alias forms an
address and uses the existing indirect load or store; recursive neutral shape
transport handles the complete fixed-array copy. No new IR operation, verifier
rule, backend-only type fact or host-width query is introduced.

An `any` element and a struct or `any` source requiring [1320]'s iterable
evidence remain the named R4.10 refusal, L0304. They need erased element
identity or evidence-driven value production, neither of which is implied by
the fixed-size storage shapes enabled here.

**The alternatives:** copy an aggregate element into a detached local, flatten
an inner array or slice into a scalar placeholder, enable `any` by treating its
two cells as a slice, or invoke iterable evidence during lowering. Those
choices lose element aliasing, lose structural identity or permission, confuse
two unrelated two-cell representations, or bypass the checked evidence call.
All were declined.

**Pinned by** `runtime/for-aggregate-element-traversal`,
`negative/for-array-element-read-only`,
`runtime/for-any-element-traversal`, the retained
`negative/for-iterable-missing-conformance`, and the `control.loops` guarantee
row.

### D179 — An `any` traversal element keeps erased identity and evidence

**The tour said** that collection traversal binds an alias to an element of a
fixed array or slice [1150] [1160], and that `any C` is one erased data pointer
paired with evidence for exactly C [1370] [1390]. D178 deliberately left that
element type separate from fixed-array and slice elements: the same two-word
size did not make an `any` a slice.

**Chosen:** a collection traversal admits an `any C` element. A containing
fixed array records C in the target-neutral descriptor for its repeated
element; a slice already records C in its referent descriptor. The loop
binding receives that exact concept identity before its body is checked and
aliases the complete two-word element in the selected storage. Dynamic entry
selection therefore reads the element's data pointer and its own evidence
table, including when one collection holds values erased from different
concrete types.

D160's evaluation, permission and control rules remain unchanged. A computed
slice source is formed once before its base and length are saved. The hidden
`usize` index still advances in storage order. Replacing an element requires a
writable slice or assignable fixed array; reading and dispatch through a
read-only slice remains valid. `continue`, `break`, natural `complete` and
lexical cleanup keep their existing edges. A `break with` copies both `any`
cells into the caller-owned loop destination before cleanup, so the result
keeps the selected erased identity and evidence.

The address-shaped alias and the existing two-cell storage-copy path are
representation mechanisms only. No operation interprets an `any` data pointer
as a slice base, interprets evidence as a length, or admits `any C` itself as a
collection source. A struct or `any` source requiring [1320]'s iterable
evidence remains the named R4.10 refusal, L0304.

**The alternatives:** copy the element into a detached local, infer C again
from the data pointer, treat the pair as a slice, or enable evidence-driven
sources at the same time. Those choices respectively lose element aliasing,
discard the erased identity, confuse unrelated representations, or couple a
storage walk to an unimplemented evidence call. All were declined.

**Pinned by** `runtime/for-any-element-traversal`,
`negative/for-any-element-read-only`, the retained
`runtime/for-iterable-evidence-traversal`, and the `control.loops` guarantee
row.

### D180 — Struct and erased sources traverse through exact iterable evidence

**The tour said** that traversal uses [1320]'s `iterable` concept [1150],
that its `item` result makes a non-storage element binding a copy [1160], and
that evidence tables follow concept declaration order [1310]. D160--D179 had
only enabled direct fixed-array and slice storage. Treating an `any C` source
as the other existing two-cell carrier would instead confuse erased data and
evidence with a slice base and length.

**Chosen:** the next collection-traversal increment admits a source whose
type is a struct or `any C` when there is one unambiguous concept named
`iterable` and exactly one conformance to it
`iterable` supplies two associated type inputs and [1320]'s four entries in
that order. The entries have the exact infallible signatures shown at [1320]:
no convention, permission, error-set, result-origin, cursor identity, Item
identity, or erased concept is inferred or converted. Conformance arguments
remain label-addressed, while the retained provider table and calls remain in
concept declaration order. Missing, multiple, malformed, or non-exact
evidence is L0301.

The source expression is evaluated once and copied into independent traversal
storage. `first` runs once against that stored source. Each head calls
`at_end`; false calls `item` and copies its result into the immutable element
binding. Body fallthrough or `continue` runs applicable cleanup, calls `next`,
copies the returned cursor into the retained cursor, advances the optional
immutable `usize` index, and tests again. `break` runs applicable cleanup but
does not call `next`; natural completion alone enters `complete`. Aggregate,
fixed-array, slice and `any` cursors and Items retain their complete checked
identity. Aggregate cursor replacement uses separate result and retained
storage, so a provider never receives an aliased input/output cursor. An
`any` Item and an `any` loop result copy both erased cells.

Because [1320]'s `item` result has no `from`, its binding has no source-derived
origin; an implementation returning such a reference must satisfy the
ordinary exact result-origin rule at its own declaration. Assigning to the
copied binding is L0303. The stored source is passed as [1320]'s ordinary
in-value parameter, so no traversal call obtains a new write permission.
Ranges and direct array/slice traversal retain D159--D160 and D178--D179
unchanged. In particular, an `any C` source remains a data/evidence pair for C
through every provider call and is never decoded as a slice.

**The alternatives:** choose the first conformance in source order, derive
Cur or Item from provider bodies, share an aggregate cursor's result and input
storage, make Item an alias, call `next` before cleanup, or reinterpret `any`
as a slice. Those choices respectively make declaration order semantic, lose
associated-type identity, permit hidden result/input aliasing, contradict
[1160], move effects across a loop edge, or confuse unrelated representations.
All were declined.

**Pinned by** `runtime/for-iterable-evidence-traversal`,
`negative/for-iterable-ambiguous-evidence`,
`negative/for-iterable-item-read-only`,
`negative/for-iterable-missing-conformance`, retained range and collection
runtime fixtures, and the `control.loops` guarantee row.

### D181 — Hosted text views retain identity over pooled encoded storage

**The tour said** that [0600]'s `utf8`, `utf16` and `cstring` are distinct
views over `[]u8`, `[]u16` and `ptr u8`; that [0260]'s quoted and [0280]'s raw
literals take one of those contexts and default to `utf8`; and that [0270]
separates byte escapes from Unicode scalar escapes. D161/D164 had enabled only
the direct `[]u8` contexts. The tour did not settle whether representation
identity could leak through structural generics, whether the terminator was a
byte or an element, or how static pointer images name pooled data.

**Chosen:** the next R4.10 text increment admits quoted and raw literals in
direct `utf8`, `utf16` and `cstring` contexts and makes contextless literals
`utf8`. Each is a canonical immutable reference identity distinct from the
other two and from its backing pointer or slice type. That identity is carried
by parameters, results, struct fields, control joins, exact generic actuals and
evidence descriptors. Binding mutability remains separate and cannot grant
write permission through a text view. Literal storage has static origin, so a
literal may be returned without inventing a parameter-derived origin.

Unescaped source is validated as shortest-form UTF-8. In a text context,
`\u{...}` must name one Unicode scalar value and is encoded as shortest-form
UTF-8 for `utf8` and `cstring`, or as one UTF-16 code unit or surrogate pair
for `utf16`. The simple [0270] escapes denote the corresponding scalar values.
`\xNN` remains exclusive to D161's byte-slice context, and `\u{...}` remains
excluded from it. Raw content has no escapes: after D164's indentation rule,
its validated UTF-8 scalars are retained for `utf8`/`cstring` or transcoded to
UTF-16. Malformed source and escape spelling retain L0320/L0323; a valid
escape used in the wrong context is L0301.

Lowering pools decoded content by element width. Equal UTF-8 byte sequences
may therefore share one `u8` datum across `[]u8`, `utf8` and `cstring`, while a
UTF-16 sequence names a separate `u16` datum. Exactly one zero element follows
every datum. A slice image excludes it from its code-unit length; `cstring`
carries only the base address. Module and aggregate images hold verified data
relocations, including cstring fields, and the Linux backend emits every pool
entry in read-only storage. No runtime initialization or text-specific opcode
is introduced.

This decision does not inherit operations from a representation. `lenof`
continues to expose the existing slice length for `utf8` and `utf16`, but
integer or position indexing remains [0610]'s separate R4.10 work. Range
slicing and collection traversal likewise require their own text operation or
evidence instead of treating a hosted view as an ordinary slice. Existing
byte-slice literals, ranges, arrays, origins and evidence behavior are
unchanged.

**The alternatives:** erase each view to its backing reference, give each
occurrence distinct storage, count the terminator, store a cstring as a slice,
accept byte escapes as Unicode scalars, or enable integer indexing with the
representation. Those choices lose declared identity, duplicate read-only
data, contradict [0260]'s length and C boundary, admit invalid text, or decide
[0610]'s linear codepoint semantics without its own evidence. All were
declined.

**Pinned by** `runtime/hosted-text-views`, retained byte-literal runtime
fixtures, `negative/cstring-literal-write`,
`negative/text-literal-codepoint-in-byte-context`,
`negative/text-view-byte-escape`,
`negative/text-view-identities-are-distinct`,
`negative/text-view-indexing-deferred`, the decoder, IR verifier and backend
cases, and the `source.lexical` and `text.literal-storage` guarantee rows.
