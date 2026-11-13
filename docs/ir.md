# The intermediate representation

Landin's compiler, `refine`, translates checked source into an intermediate
representation, or IR, before it emits assembly. The IR makes execution
order, storage and control flow explicit while retaining the types and
source identities needed to check and explain the result. It is the point
where the compiler stops describing how a program was written and starts
describing what it will do.

This is a maintained, non-authoritative explanation derived from the
implementation and its tests. It defines no language rule, compiler contract
or future work. The [specification](../spec.md) decides language semantics;
the implementation and executable tests establish the current IR; the
[roadmap](../ROADMAP.md) owns plans. When any of those
change, this account follows them. It must never be used to justify changing
the compiler to match the prose.

`D339` names a decision recorded in `spec.md`, and `[1960]` a numbered
paragraph of `tour.md` or `spec.md`; `refine explain D339` prints either.

## Where it sits

The frontend first parses source into a syntax table, resolves names and
checks types, reference use and definite assignment. Lowering consumes those
answers and builds the IR. It does not resolve the program again or decide
whether a source construct is legal. Rejected source does not reach it.

The current path is:

```text
checked source
    -> lowering -> verified IR
    -> evidence specialization -> verified IR
    -> inlining, at speed -> verified IR
    -> scalar replacement and simplification -> verified IR
    -> if-conversion -> verified IR
    -> in-place parameter reads -> verified IR
    -> target layout, allocation and instruction selection
    -> assembly -> platform assembler and linker
```

The same IR feeds every native emitter, x86-64, arm64, RISC-V, Cortex-M
and Xtensa, for hosted executables and firmware alike; the
[capability inventory](capabilities.md) names the targets each supports and
their limits. The IR is expressed without machine registers, stack offsets or
instruction encodings. Each backend translates its operations into machine
instructions and supplies the calling convention and object-format details.
Xtensa's does so in two steps: its emitter writes RISC-V-form instructions
over words kept in memory, and a selector turns each into Xtensa
instructions as it is written ([target contracts](targets.md#xtensa-firmware)).

There is a reason for having a representation between syntax and assembly.
The syntax already preserves nested statements and expressions. Repeating
that structure would leave every backend to rediscover evaluation order,
branch destinations and storage transfers. Lowering makes those decisions
once, in a form that can be inspected and verified before machine code enters
the picture.

## Items, blocks, values and slots

An IR unit contains the routines and data needed for a compilation, together
with shared descriptions of signatures, types and evidence tables. Four
terms describe its executable structure:

| term | meaning |
|---|---|
| item | A routine or a module datum. An imported routine can carry a signature without an executable body. |
| block | A straight-line sequence of instructions with exactly one terminator at the end. |
| value | The result of one instruction, usable by later instructions in the same block. |
| slot | Typed storage belonging to a routine, used for parameters, named results, locals and lowering's temporary storage. |

A terminator jumps to another block, chooses between two blocks, returns
successfully, exits with a declared failure, or traps with `Halt`. A loop is represented with
blocks and a backward edge. There is no separate loop instruction for the
backend to interpret.

A signature records whether its routine returns at all (`noreturn`, D231).
A direct or indirect call of one that does not is followed at once by `Halt`,
its block's terminator, which reports `unreachable` if a faulty callee
returns after all (D232). That `Halt` has control and trap effects, and the
verifier refuses a returning body with a nonreturning signature. Generic and erased evidence signatures retain
the same flag; it never becomes an ordinary IR value type.

An erased call of a concept that no conformance in the program answers has
no evidence table to load its function from, because no value of that `any`
type can be made. Lowering gives it no call at all: the block ends in `Halt`
at the call's site, before its arguments, as `compiler.unreachable()` does
(D377).

An instruction produces at most one value. Its position within its item is
also its value identity, so there is no separate register-like namespace to
keep synchronized. The verifier requires every operand to name a producing
instruction earlier in the same block. A slot has a different identity:
several stores can change its contents, and loads produce new values from it.

That distinction is central. Values describe individual computations; slots
describe storage whose contents can survive a change of block. A slot does
not promise a stack address. The backend may keep eligible storage in a
register, and simplification can remove redundant loads. The neutral
representation does not make that placement decision.

## Following a branch

The positive fixture
[`arm-scopes-are-siblings`](../compiler/tests/fixtures/positive/arm-scopes-are-siblings/program.ldn)
contains this routine. It returns `1` when `c` is true and `2` otherwise:

```landin
f: (c: bool) -> (r: u32) =
    r = 0
    if c then
        t: u32 = 1
        r = t
    else
        t: u32 = 2
        r = t
    end if
end f
```

The two declarations named `t` belong to different scopes. Lowering gives
them different slots; it does not identify storage by spelling. The named
result `r` has one slot shared by both arms and the return path.

Here is its complete compact IR dump, copied from
[`compiler/tests/lowering.ir`](../compiler/tests/lowering.ir). This is the
output of lowering, before evidence specialization and simplification:

```text
unit signatures 1 items 1
signature 1 (in bool) -> u32
item 1 ROUTINE f result u32 signature 1 params 1 slots 4 blocks 5 values 17
  slot 1 c bool param 1
  slot 2 r u32 return
  slot 3 t u32
  slot 4 t u32
  block 1 scope 5 BLOCK length 4
    1 NUMBER u32 0
    2 STORE slot 2 <- 1
    3 LOAD bool slot 1
    4 BRANCH target 2 alternative 3 <- 3
  block 2 scope 6 BLOCK length 5
    5 NUMBER u32 1
    6 STORE slot 3 <- 5
    7 LOAD u32 slot 3
    8 STORE slot 2 <- 7
    9 JUMP target 4
  block 3 scope 5 BLOCK length 1
    10 JUMP target 5
  block 4 scope 5 BLOCK length 2
    16 LOAD u32 slot 2
    17 LEAVE <- 16
  block 5 scope 7 BLOCK length 5
    11 NUMBER u32 2
    12 STORE slot 4 <- 11
    13 LOAD u32 slot 4
    14 STORE slot 2 <- 13
    15 JUMP target 4
```

The headers describe one routine with a Boolean input, a `u32` result, four
slots and five blocks. `scope` refers to a lexical scope in the resolver's
tables; `length` counts the block's instructions. The item header's
`values 17` counts all instruction identities, including stores and
terminators, even though those instructions produce no usable value.

Read `2 STORE slot 2 <- 1` as: instruction 2 writes the value produced by
instruction 1 into slot 2 (`r`). The number after `<-` identifies an operand;
it is not a literal. In contrast, the final `0` in `1 NUMBER u32 0` is the
literal being produced. `3 LOAD bool slot 1` reads `c`, and instruction 4
uses that value to choose block 2 when true or block 3 when false.

The true path is `1 -> 2 -> 4`. The false path is `1 -> 3 -> 5 -> 4`:
block 3 is a forwarding block containing only a jump to the `else` arm.
The dump lists blocks by identity, so block 4's instructions 16 and 17
appear before block 5's instructions 11 through 15. Execution follows the
terminators, not the printed order.

Both arms write slot 2, using separate slots 3 and 4 for their respective
declarations of `t`. Neither arm's loaded value crosses into the merge block.
Block 4 loads `r` afresh as value 16, and `17 LEAVE <- 16` returns it. The
initial store of zero and the loads through `t` are still visible because
this dump shows lowering before optimization.

The current IR has no phi instructions or block parameters: the mechanisms
many static single assignment representations use to select a value from
incoming edges. Storage provides that connection here, including for
expression results and short-circuit Boolean expressions. For `and`, the
right operand runs only on the edge where the left operand was true; `or`
uses the complementary choice. These are branches, not eager arithmetic
operations.

When the `and` or `or` is itself the condition of an `if`, a `while` or a
`when`, no answer crosses a merge. Each operand branches straight to the
block its value decides, and a `not` over one exchanges the two
destinations. Lowering makes the blocks that test the right operands before
it lowers the operands, so that each follows the test before it. A
condition holding a control expression keeps the slot form instead, because
that operand's arms could all leave and strand those blocks. A block nothing
reaches is malformed IR, so a loop likewise makes its blocks only after its
bounds or source, and a `while` whose condition does not jump only after
that condition.

This makes the initial lowering straightforward and its operand rule cheap
to check: block membership and instruction order suffice, without computing
which definitions dominate which uses across the graph. The cost is explicit
loads and stores around merges. Some disappear later, but this form does not
itself provide global value propagation or guarantee the fewest memory
accesses.

## Neutral operations, concrete target facts

Target neutrality means that the IR names a computation or a storage part
without prescribing its machine implementation. It does not mean that a
compilation can ignore its selected target.

For example, `usize` remains `usize` rather than becoming `u64` because the
compiler happens to run on a 64-bit host. Size and alignment operations retain
the shape being measured. Field access retains the identity of the field;
it does not carry a byte offset. The target layout machinery derives sizes,
alignment, padding and placement from those shapes and explicit target
facts. Source field order and physical placement order are separate facts.
An `offsetof` is the same kind of question: its measurement carries the
record's field run, its layout policy and the path of field positions, and
the backend answers it from the placement it computes for the target.

A `layout(c, packed)` record places fields at alignment one, so a scalar
inside it may be unaligned. A backend can tell from the shapes along a field
path, and an address slot that lowering forms for such a scalar is marked
unaligned in the IR, so a target whose ordinary loads need alignment moves
it a byte at a time while the others load it whole.

Target facts also enter verification and simplification where an answer
requires them. A folded initializer must fit the type that will hold it, and
folding a pointer-sized integer operation needs the target's width. This
does not require putting a register or an offset into the IR, or consulting
the host's pointer size.

The operation vocabulary preserves distinctions that affect behavior.
An application of a written type, such as `[]u8(text)`, lowers through the
same checked conversion as an application of an alias for that type. Its
source spelling adds no IR operation; exact representation extraction, text
validation and numeric conversion retain their existing operations and
origin facts.
Ordinary integer addition and wrapping addition are different operations.
A checked conversion and a range-subtype check are different too: conversion
can change the integer type, while a range check passes a value of the same
type through only if it satisfies the bounds. D232 marks range checks used
for representation validation separately: null pointer construction, malformed
text and reserved-bit patterns report `bad_conversion`; subtype bounds report
`out_of_range`. Rewriting and specialization preserve this flag, and proved
constant replacements remove it with the check. The verifier refuses it on
other opcodes. A range check keeps both bounds, but every backend tests
only an edge inside its type: `ptr(n)`'s check is `1` up to the largest
`usize`, and only the nonnull edge is emitted. A load of an atom-typed value
tests that its bits are one of its set's codes. A sealed slot is the
exception: a compiler temporary that nothing but loads and stores names,
which the verifier enforces, so it can only read back a value of its set. An atom
`match` keeps its subject in one, so the subject is tested once where it is
read and each arm only compares. A signed right shift describes
the language's shift semantics; the x86 emitter is responsible for handling
counts that the hardware would otherwise mask.

Instructions in an `unchecked` region retain the flag needed to omit the
particular runtime checks the language permits removing. The verifier limits
it to eligible operations. It supplies neither a new aliasing assumption nor
permission to disregard the source's static rules.

## Keeping data structured

The IR is more than scalar instructions and branches. Arrays, structures,
variants, function values and dynamic dispatch need enough information to
remain distinguishable before their physical representation is chosen.

Shapes describe scalar fields, fixed arrays, nested aggregates and variant
cases. Nominal identities distinguish declared types and their instances
even when their fields look alike. A path into an aggregate records the
successive fields and variant cases it traverses. The backend follows that
path through a target layout to obtain the final address.

Whole-array copy, clear and fill operations stay compact. Describing a
million-element array does not require a million field descriptors or a
million copy instructions. The IR retains element shape and length; the
backend decides how to perform the operation. Initializer contents are a
separate matter: an explicit static image can contain per-element values.

Aggregates generally travel through storage operations and internal address
carriers rather than becoming large scalar values. An internal address used
to pass an aggregate is distinct from a source-language pointer. In
particular, passing a value by an address carrier does not silently change
the source operation into an alias: the receiving routine copies the
aggregate where the calling contract requires it. The caller takes a snapshot
of its own only when a later argument may write storage, as a call or a
statement-bearing expression may; arguments that only read, form values or
trap cannot change the bytes before the receiving routine copies them. A
carrier addresses storage aligned for the parameter's shape: frame and module
storage by their layout, and storage reached through a pointer, slice or `any`
because [0430] makes a pointer's alignment the program's obligation. Each
backend therefore moves an aligned parameter into its fresh slot, or clears
it, by machine words, and keeps byte transfers for a byte-aligned extent.
An aggregate result's hidden address is formed from the caller's own storage
in the same way. Ordinary copies through runtime addresses keep their
conservative forms. A direct `zeroed` internal
aggregate argument instead carries scalar zero in the same argument position;
the callee clears its own complete shaped parameter slot. Stored values still
carry addresses and are copied. C ABI arguments retain caller materialization
and C classification. Lowering emits zero carriers in the final call block,
after source-ordered argument evaluation, so later control-flow expressions
cannot strand a carrier in a predecessor block.

Under size and speed, `Landin.IR.In_Place` lets the receiving routine read
such a parameter where its caller keeps it when nothing could tell the
difference. That holds when:

- the routine only reads the parameter, and passes its address on only as
  another by-value argument;
- nothing it does before its last read can write memory outside its own
  frame: no store through an address or to a module datum, atomic access,
  assembly block, indirect call, call to an import, or direct call to a
  routine that may do any of those, which a whole-unit summary answers;
- for a parameter two words wide or narrower, a slice among them, the read
  is outside loops, where its copy costs more than reading through a carrier
  that may sit in memory.

A call's address of the parameter may pass through a slot that lowering
keeps it in across later arguments. At speed a read through that slot counts
as a read of the parameter, which is how an inlined copy reads a parameter
its caller passed on. The parameter's slot then
becomes an address slot holding the carrier, reached as an `inout` place is,
and keeps its declaration so a debugger still shows the value. Its former
shaped slot stays as its home: a zero carrier clears that home, and the
parameter addresses it. The same pass gives a call the storage of a slice or
`any` argument directly, instead of lowering's fresh copy, when nothing
between that copy and the call can write memory. `--optimize none` keeps
every copy.

Variant selection retains the selected case identity. Each backend derives
its padded payload extent, clears that payload and writes the tag; a bare
case writes only the tag. Inactive bytes and layout padding are unspecified.
Explicit whole-object `zeroed` still clears the complete object, and whole
copies still transfer the complete reserved extent.

Aggregate results currently retain separate named-result storage and the
successful-exit copy. The specification permits direct caller storage only
when equivalence for aliasing, partial results, failure and cleanup is proved;
that permission is not an implemented result-storage optimization.

Module data is also distinct from routine execution. A datum holds a static
value description or image, including nested contents and function
relocations where needed. Instructions used to describe a static value are
not startup code. They do not introduce execution before the entry point.
A datum written `link(thread)` is marked thread storage and is otherwise the
same item; the backend for a target with threads places it in the system's
thread storage and reaches it through the thread pointer, and the dump shows
it as `thread storage` (D496).

A program, one whose entry module declares a public `main`, gets an item only
for the module routines and bindings it can reach (D296), and an evidence
table only for the conformances it reaches. Lowering walks the checked
syntax before it creates any item, from the routines the entry module
defines and from whatever a linker, a C peer or an `assembler.block`'s text
may name: link symbols on data, public or linked C definitions, machine
conventions, imports' link names and placements. A firmware image, a
compilation given `--firmware-entry`, is walked the same way from what the
image starts from instead: the entry and `panic_handler` rather than every
routine of the entry module, and no machine convention that takes no
vector slot (D1358). A reached declaration
reaches every routine or binding a resolved reference in it names, every
generic instance its calls select and every conformance its selections,
`any` constructions and `for` loops read; an instance is walked in its own
checker view. Everything is still checked. What nothing reaches, in a
library module or the program's own, is not lowered, simplified, emitted or
assembled, so a module of a thousand public constants costs a program that
uses one of them a single datum, and a hello-world over `core/io` 64
routines rather than 546. A compilation without such an entry keeps
everything, since anything in it may be what its consumer came for.

A reached conformance does not reach every provider. A direct table's
entry is reached only by a reached `t.entry` selection naming it, in the
instance's own view, so a call of `io.out` lowers the provider's `out` and
none of its other `process` entries; the rest are absent entries, which
name no routine and keep their places (D484). An erased table, and a `for`
loop's iterable table, reach every entry, since an `any` value may have
any of them read. An erased call names a table only for its shape, since
it reads its function from the value's own: every erased table of a
concept has one layout, so the call names the first one the program
builds for an `any` construction, and the table its checker chose is
built, with every provider, only when the program builds none (D1358).

Even a reached entry need not be named by the emitted table. Each
table records its concept, and the backends keep entry N only where code
that can run projects entry N from some table of that concept (D374): the
concept rather than the table a projection names, because an `any` value
may carry any of its concept's tables. A root is a routine that something
other than a call names, a routine without parameters, or the panic handler.
Code that can run is what a root reaches through calls, taken addresses and
the routines an `assembler.block`'s text names by name or link name. So a
routine that only a left-out entry's target calls projects nothing, on a
hosted target too, whose startup and system calls are blocks as on any other.
An entry left out is a zero word in its place, so every offset D144 and
D147 give stays put, and the routine it named is linked only if something
else reaches it.

## Calls, evidence and failure

A function value needs more than an address. Its signature descriptor
retains ordered parameters and results, their shapes, and the applicable
calling-convention and failure information. Direct calls name a routine as
well as a descriptor; indirect calls carry a descriptor even when the
concrete routine is unknown. The verifier can therefore check a call without
mistaking every pointer-sized quantity for a compatible function.

One operation gives a pointer-sized quantity a descriptor on purpose. A C
function type applied to an address, as a loaded library's symbol is found,
lowers to a range check that traps on zero followed by `Code_Address`, which
changes no bits and carries the C signature the source named. Unlike a
function address it names no routine, so nothing about the callee is known
and no call through it is resolved to one. The verifier admits it only from
a plain `usize` and only with a C signature. The way back, `usize(f)` of a C
function value, needs no operation of its own: it is the ordinary integer
`Conversion` of the value's word to `usize`, whose result carries no
descriptor, so what it gives is an integer and never again a function until
`Code_Address` makes one.

Landin's concepts describe required operations. Evidence tables supply the
implementations for a particular type. The IR describes those tables and
their ordered entries, and has operations to obtain a table address or
project a function from it. An entry index remains a semantic identity until
the backend turns it into an offset.

An `any C` value packages an object with evidence for concept `C`, allowing
runtime selection. The IR retains the represented shape and the relationship
between the selected function and its receiver. Verification checks that
relationship; an erased call cannot freely pair a function from one
projection with an unrelated receiver. The receiver is the object's address
whether the entry takes `self` as a pointer or takes a record by value: an
aggregate parameter already travels as the address of its storage, which the
receiving routine copies, so the erased signature replaces that parameter
with the same address word and the verifier holds it to the represented
record.

Declared failure is separate from ordinary results. A call can have a
failure slot, and a failure test selects the subsequent control flow. A
failure exit carries an atom belonging to the declared error set. The
backend chooses the physical success and failure carriers. These explicit
edges represent recoverable language-level outcomes; they are distinct from
runtime traps such as a failed arithmetic check.

## Verification and optimization

Verification runs in release builds as well as debug builds. It checks the
completed unit before backend use, and the current specialization and
simplification passes verify their inputs and outputs; scalar replacement
runs first inside simplification, whose output verification covers both. It
checks storage runs and identities before dereferencing them, then block structure,
reachability, operand order, type agreement, signatures, shapes, paths,
evidence and static images. Pointer-provenance verification indexes stores
and reads, then follows the paths on which each read slot may be
uninitialized, and keeps the first fault in block and instruction order. Its
heap scratch grows with blocks, slots, values and pointer uses, and holds no
table of blocks by slots.
Successors come directly from validated terminators, so constructing a graph
introduces no automatic queue or returned graph temporary. Array byte sizes
and use counts are checked before allocation; partial allocations are released
on faults and host-resource failures. An item with no pointer reads needs no
slot/value dataflow scratch, but still receives signature, true reachability
and ordered pointer/storage checks. There are no additional per-item block,
value or slot caps; D247's existing source limits remain unchanged.

This is structural and semantic consistency checking of a compiler data
structure, not a proof that compilation preserves every program's behavior.
Source diagnostics belong to the frontend. Malformed IR at this boundary is
a compiler defect, and the tests deliberately construct malformed units to
check that they are rejected. Recorded lowering and executable fixtures test
different things: what the compiler produced, and how the emitted program
actually behaved.

Specialization currently proves incoming static evidence where it can and
replaces eligible indirect dispatch with direct calls. It retains existing
instance entries and the working indirect fallback for unknown or exposed
entries. Specialization creates no new semantic instances: generics and
dynamic dispatch must already work without it. Its profitability policy,
D211's, charges an instance's weighted operations as growth under size and
none, where unspecialized instances can share one body; under speed a
rewrite inside an existing instance counts no growth. An instance is not an
export: a public template gives its instances no symbol of their own, so
only a function value, an image or an evidence entry exposes one.

At `--optimize speed`, `Landin.IR.Inlining` then replaces a direct call
to a small routine with a copy of its body (D339). The routine must have a
body, no exposed address, the ordinary convention and Landin's own
transport, and weigh no more than a fixed bound of those weighted
operations, as lowering made it. The copy's own calls stay calls. A caller
grows by at most the larger of a fixed floor and its own weight, and calls
inside loops are copied first. The call's block ends by storing each argument into the copy of its
parameter, copying or clearing a by-value aggregate as the routine's entry
would, or reading it where the caller keeps it when the routine only reads
it and nothing can write that storage while the copy runs. A parameter the
caller passes as a constant is read as that constant, which is what lets
simplification fold the copy. The copy's blocks come next in the item, its
one return last, and the rest of the caller's block after them; values that
crossed the call wait in slots, constants are made again, and the call's
result is read from the copy's result slot. A routine that can fail is
copied only at lowering's failure test after its call: its `fail` stores
the atom into the call's status slot and jumps to the failing block, and
its return to the other. Each copied block, slot and source alias names
its `Inline_Site` — the routine, the call's origin and the call's scope —
and every copied instruction keeps its own origin, so its traps and line
rows are the routine's. Debug emission turns a site into DWARF's inlined
subroutine. Firmware targets, Cortex-M, RV32 and Xtensa, are left alone:
no firmware debugging contract describes an inlined frame.

Scalar replacement runs at size and speed, as the first step of
simplification, which verifies the two passes' output in one walk; at speed
that is after inlining, so an inlined copy's slots are split like the
caller's own, and each piece keeps its slot's inline site. A slot
holding a slice, or a record or fixed array of at most four scalars, is
otherwise reached only through field loads, field stores and whole copies.
Forwarding, the proofs of checks and a backend's register allocation see
through none of those. When every use of a local slot names one of its
parts or copies or clears it whole, the pass gives each part a scalar slot
of its own: part accesses become ordinary loads and stores, a whole copy one
load and store per part, and a clear one store of zero per part. A taken
address, an internal address carrier, a partial copy, a nested path, a
routine's result slot or a source alias keeps the slot whole; D94's callee
copy then still reads complete storage. A parameter the routine never writes
stays whole as its caller's copy arrived; at speed each part a loop reads is
copied out of it once on entry, where a backend can keep it in a register.
The copy's one store comes first, so a check's proof still sees the
parameter's part through it, and the parameter, now read only on entry, may
then be read in place. Parts with packing, atom codes or an erased receiver
are left alone, so every load the pass rewrites carries no check and no trap
moves; a slice's bounds checks read its length from the new scalar slot.
Size keeps declared variables in their frame cells and splits only compiler
temporaries. The analysis is one scan over the instructions and slots and
one strongly connected component walk over the blocks; the rebuild copies
each instruction once and adds at most one load and one store per moved
part.

Simplification folds supported constants, forwards eligible local slot
values, simplifies known branches and removes unused computations when
their effects allow it. A read of a module value that is not `mut` folds to
the static image every backend emits for it, measured for the selected
target, and a measurement [0370] asks for folds the same way; a module
value defined outside the program, given a link name or placed keeps its
read. Values remain block-local. Forwarding hands a load
the stored value itself, so floating-point and pointer slots forward too:
the bits, and a pointer's pointee, are the ones the store verified. A
compiler temporary whose loads were all forwarded, such as the slot that
carries a binary operation's left operand, loses its stores; a declared
slot keeps them as its variable's home. A slot is eligible only while
nothing names it except as a load or store target: any instruction that
addresses it, reads or writes it through another opcode, or names it as an
assembly output leaves it in memory. So no call, element or indirect store,
or memory event can reach an eligible slot, and its forwarded value survives
them all until the slot's own next store, the end of the block or an
assembly block, whose text is opaque. A later load of a slot that nothing
stored to in the block is not replaced by the first one, which would only
stretch a value across code that has no register left for it, but it is
numbered the same. Overwritten stores are dropped only between calls,
because the debugger shows a caller's variables while its callee runs. The
effects model treats reads, writes, calls, traps, control flow and required
instruction adjacency conservatively for everything else. An unused result
alone is not enough to delete an operation: a possible trap is observable.
Floating-point reassociation and assumptions invented from `unchecked` are
outside these rewrites.

Within a block, value numbering gives a later pure operation the value of an
earlier identical one: the same opcode, type, flags and metadata over
operands numbered the same, hashed so that the pass stays linear. That
includes checked operations, an index's bounds check among them. By [1960]
a check that fails stops the program where it stands, so once the earlier
operation completed, the later one cannot fail. Removing the later one is
that proof; its unchecked flag is never set to record it. An
operation in an `unchecked` region proves nothing for a checked one, so the
flag is part of what must agree. An address through an address slot is the
same only while no store has changed that slot and nothing else can reach
it. Loads, stores and calls are never replaced this way. Integer identities
such as `x + 0`, `x * 1`, `x & x` and `x == x` reduce to their operand or
answer; none is applied to a float, where `-0.0 + 0.0` and a NaN's
comparison with itself say otherwise.

A check can also be proved across blocks. A comparison whose branch is the
only way into a block bounds there the slots it compared: `at` in
`while at > 0 do dec at`, `left` and `right` in
`while left < right do inc left dec right`, and `i` in
`for i in first..<lenof s do s[i]`, whose end is a slot stored once, in a
block that dominates the loop, from the length of a slice nothing in the
routine writes. The bound holds in the block's whole subtree of the
dominator tree unless a store to one of those slots can reach a use there
without passing the block again; otherwise it holds only in the block
itself, before the block stores to them. A value's type and what produced
it bound it too. A contradictory comparison is conservatively bounded at
the type's extremum, without stepping outside its numeric range or requiring
the pass to prove the branch unreachable. A `u8` widened to `usize` is always inside a `[256]`
array, and an index that passed a fixed array's check in a block passes any
at least as long later in that block. Such a check cannot fail, so its
instruction keeps its operation and is marked unchecked, which every
backend reads as no check edge. The flag set by an `unchecked` region is
never read as a fact. The dominator tree is Lengauer and Tarjan's, in
O(E log V) work, and each bound then costs a binary search over the blocks
the stores to its slots can reach.

Under size and speed, `Landin.IR.If_Conversion` then turns some branches
into choices (D338). A block that ends in a branch whose arms meet again,
each arm at most one block, computes both arms itself when neither can trap,
call or touch anything but a private slot: a scalar that nothing names but
its own loads and stores. It picks each stored slot's value with `Choose`, an
operation lowering never makes, stores it, and jumps to where the arms met;
nothing reaches the arms' blocks then, and compaction drops them. A checked
`x = x + k` in an arm whose other side leaves `x` alone qualifies too, as
`x + (if c then k else 0)`, because that addition traps exactly when the arm
would have. So `if a < b then inc n end if` becomes a comparison, a choice of
one or zero and an addition, with no branch. A check, a call, a memory access
or a division in an arm keeps the branch, and so does a condition computed
from a slot an arm stores, such as `inc at if at == n then at = 0 end if` in
a loop, where each choice would wait on the one before it. Each arm is held to six operations
besides constants, loads and stores, and the work is linear in the routine.
x86-64 selects a choice as `cmov` or `setcc` and arm64 as `csel`, `fcsel` or
`cset`, each on the flags a comparison right before it leaves when that is
the comparison's only use. The RISC-V backend, for RV64 and RV32, and the
Cortex-M and Xtensa backends select no conditional move: they use the
condition's own zero or one for a choice of one or zero and branch around
one load for any other. Xtensa has `moveqz` and `movnez`; the backend does
not use them.

These passes expose useful facts to the backend while leaving register
allocation and machine instruction selection there. The current controls and
defaults are documented in the
[bootstrap compiler guide](../compiler/ada/README.md); their existence is not
a claim of competitive optimization.

## Source identity and readable dumps

Instructions retain source origins; slots retain declaration identities;
blocks refer to lexical scopes. The IR refers back to established source and
resolution tables rather than maintaining a second scope tree. Debug
emission combines those identities with the backend's actual allocation and
layout plans. DWARF records, machine locations and object sections belong to
the emitter, not to the neutral representation. A slice's two-word carrier
shape also keeps the element the slice reaches, wherever the shape appears —
a slot, a datum, a field, a pointer's referent or an array's element — so a
debugger can present it as an element pointer and a length. Nothing that
executes reads that element: it is not pointee evidence, no layout reads it,
shape comparison ignores it, and the verifier neither requires nor trusts it.
Every named module datum is a variable at its own symbol. A declared slot
that scalar replacement split keeps its declaration and records its first
piece; its location is then each piece's location followed by `DW_OP_piece`,
in address order with padding left empty, available where every piece is.

`Landin.IR.Dump` produces deterministic text for inspection and regression
comparison. `compiler/tests/lowering.ir` records the positive fixture corpus
in that form. Items and their contents use dense identities rather than
addresses or hash iteration order. Source byte offsets are deliberately
absent from the dump, so moving a comment does not rewrite the recorded
lowering; dedicated tests check attribution instead.

The default compact dump preserves the existing recorded format and omits
pointer metadata. `Landin.IR.Dump.Text` with `With_Metadata => True` adds
pointee definitions and identity edges, signature/result/slot/value annotations,
nominal shape identities and `Place_Address` storage endpoints. These are
reached-type facts, not source origins or lifetime guarantees. Comparing compact
dumps alone cannot detect a metadata-only change; focused detailed-dump tests
cover that distinction. Pointee edges are printed without recursive expansion.

`refine compile --emit=ir program.ldn -o program.ir` writes the compact dump
of a program as its backend would receive it, after every pass the request's
`--optimize` and `--specialize` run (D365). It shows why a value lives where
it does without reading the lowering or comparing two assemblies.
`refine compile --help` names it. `--link` still decides whether
`platform/linux` joins the program; `--debug` and `--panic-map`, which
describe machine code, are refused with it. Each evidence entry line in this
dump ends `kept` or `dropped`: whether the emitted table names that entry's
routine or holds a zero word in its place (D374), as every backend decides
it for this unit, so a pruning claim can be read here rather than in the
assembly or `nm`. The recorded corpus dump leaves the word out, because the
backend, not the lowering, decides it.

A dump kept to compare against later should say what produced it, and the
annotated form does:

```sh
refine compile --emit=ir-annotated --optimize=none --specialize=off program.ldn -o program.ir
```

Its first line names the target, the CPU feature level and the optimization
and specialization settings. Each routine's name carries its module and, for
a generic instance, its template's name and item identity, and the dump
carries the metadata `With_Metadata` adds. The compact `--emit=ir` form is
unchanged, so it still compares with the recorded fixtures.

The dump has no reader and is not a stable serialization format. Comparing a
fresh dump with the recorded one detects a change in lowering; it does not
make the text an interchange protocol or establish the correctness of the
change. The Ada representation can evolve as the implementation's tests
require, without treating either its printed spelling or this page as a
compatibility promise.

## Target capability checks

The verifier's target-aware entry checks C signature and variadic-call
capabilities through `Landin.Targets.Capabilities`; the source checker also
checks C record eligibility. A second LP64 description therefore cannot inherit
SysV support from its pointer width. Nominal C-layout metadata describes
structural compatibility and also occurs on distinct scalar storage, even
without an implemented C ABI. Its structural verification remains independent
of that capability. The IR carries logical conventions, source link names and
neutral shapes; ABI carrier assignment, object symbol prefixes and debug
format selection stay in target and backend packages. The Linux and Darwin
description seam compares canonical IR for native generic, aggregate and
control-flow source, and no target contract needed an opcode or IR field.

## How each backend places values

A home is the stack cell a backend keeps a slot or a value in. A source
slot's frame home lasts the routine; the home of a value or a compiler
temporary may be reused once nothing reads it. A location held in a register
needs no home while it is held. Spill and save homes keep what a register
held, and the Xtensa backend's scratch homes keep its logical words. Where
the kind does not matter this page says home.

`Landin.IR.Liveness` gives each slot one live interval over the order the
blocks are laid out in, found backward from every block whose first mention
of the slot reads it, and the loop nesting of every block. Its work is the
routine plus the blocks each slot is live into, bounded by a multiple of the
routine past which the remaining slots get the whole routine.

x86-64 offers rbx and r12-r14 to slots over these intervals, heaviest first
by references weighted with loop depth, so slots whose intervals are
disjoint share a register. A slot holding an address through which an
operation reaches storage counts each such reach as a read, and may hold a
register too. A load whose value dies before its slot is next stored is the slot's
register. In a routine without assembly, values and compiler temporaries'
single-block spans may also take rsi, rdi, r8 and r9 wherever no call, copy,
clear, fill, leave or fail lies in their interval, and for r8 and r9 no
conversion or field or element operation either; selection uses those
registers only there. With the speed objective, eligible float slots and
values in routines without inline assembly use XMM8..XMM15 wherever no call
falls inside their interval, since SysV preserves no XMM register across
one; XMM0 remains instruction scratch. A slot loaded and stored in one block
only, which stores it before reading it, and not given a register for its
interval, may still hold one from that store through its last use, as a
value does.

Size holds a source variable it gives a register there for the whole
routine, and gives single-block spans to compiler temporaries alone, so
every source variable's debugger location covers the routine. At speed a
source variable's debugger location covers its interval and, after the
interval's last position, the rest of that block until a value writes over
the register, including the first address of that value. Address-observed,
parameter-at-a-C-entry, result and C transport slots keep stack homes, and
source debugger locations follow the allocation plan. Argument spills
preserve left-to-right evaluation across later control-flow expressions.

The shared arm64 backend gives every routine an x29/x30 frame record and
keeps source slots in frame homes except at speed. Without optimization,
scalar IR values also have homes of their own; size and speed reuse
nonoverlapping scalar homes. At speed, slots and values whose interval no
call or assembly crosses take x0-x7 or, for floats, d18-d31, neither of
which costs a save; a parameter keeps the argument register it arrives in.
Where enough scalar traffic pays for a save, the rest take callee-saved
registers, which a call leaves alone: a slot over its interval takes one of
x19-x24, a value or a slot's single-block span any of x19-x28, and a float
one of d8-d15. Declared assembly registers remain excluded, addressable
values stay in storage, and CFI describes the saved registers. Native Landin
calls use integer bit carriers, address-based aggregate copies and a
separate w8 failure carrier. The Darwin C planner maps the same verified
signatures onto Apple's independent register banks, HFA rules, indirect
results and packed or variadic stack rules. These choices belong to the
emitter; error propagation and cleanup edges arrive already verified. arm64
body folding is separate from scalar home reuse. Reports record frame,
spill, save and register use, and source debugging reads the same placement
plan for the source slots.

The RISC-V backend, for RV64 and RV32, keeps source slots in frame homes at
every optimization profile, with x8 holding the entry CFA and the saved
caller frame and return address immediately below it. Without optimization
every scalar IR value also has a home of its own; size and speed reuse
nonoverlapping scalar homes as arm64 does, a value's home freed once the
operation that reads it last has run, which takes 36 per cent off the
runtime corpus's frame bytes at both. It keeps no value in a register past
the operation that uses it. The explicit LP64D and ilp32 planner assigns C
carriers without putting register banks or stack positions into the IR. The
emitter asks the target its XLEN and serves RV32 at 32 (D671): an
eight-byte value is a register pair only while one operation looks inside
it, so the IR does not depend on the machine's width, and RV32 takes
neither RV64's layout nor its ABI. Instruction helpers select baseline and
address-generation operations from independent Zba and XTheadBa sets.

The Xtensa backend writes the RISC-V backend's form of each operation over
the logical words x0-x31 and selects Xtensa instructions for it as it is
written. Each logical word is a scratch home at a fixed offset from the
frame base a7, except that in a routine without an `assembler.block` the
emitter's five scratch words, x5-x7, x9 and x18, stay in a2-a6. Every operation therefore
loads its operands from memory and stores its result there, and no value is
allocated a register over an interval as on arm64 and x86-64.

Cortex-M selection uses pinned source slots and reusable width-sized homes
for block-local scalar temporaries. Last reads come from the verifier's
explicit operand runs; live operands cannot share a home, and a call cannot
destroy a live value. Selection uses low-register scratch. Routines with
calls or transient stack changes construct the r11 frame record before
publishing it; eligible leaves use SP-relative homes and preserve r11 and
LR. The shared frame placer owns target-byte offsets and limits. Cortex-M
performs no body sharing. The AAPCS32 planner, `Backend.Arm32_ABI`, consumes
lowered pointer, atom, slice and `any`, distinct and evidence carriers, and
adds the physical result address before the signature's evidence and
parameter run; the emitter consumes the same plans, and external C and
internal Landin transport stay separate. Eight source controls compare
detailed IR, pointer metadata included, against synthetic-32. The
[target guide](targets.md#cortex-m-assembly-implementation) records the
physical choices and [the planning section](targets.md#cortex-m-layout-and-abi-planning)
the ABI.

The shared `Backend.Dwarf` encoder uses neutral source identities and
`Backend.Debug_Locations` availability. Each backend owns its section policy
and CFI, including ELF and the x8 CFA on RISC-V; Darwin's Mach-O sections,
x29 CFI and dSYM packaging stay at the backend and toolchain boundary.
Scalar part addressing on Darwin carries wide IR element positions through
target-byte placement rather than narrowing them through the Ada host index
type. Complete derived programs share the same source, provenance and
location facts across GDB and LLDB sessions; physical encodings and
packaging remain backend-owned. Specialization copies the complete
instruction metadata; it neither erases boundaries nor invents alias facts.

## Memory operations

D227's `Memory_Access` retains operation, scalar width identity and
success/failure orderings. Its variable operand run carries only runtime
values; compile-time ordering atoms do not become machine arguments. The
verifier checks operation/order combinations, arity, operand/result types,
and selected target eligibility. Alignment checks belong to native lowering
and remain enabled inside unchecked regions.

D450's two stack builtins are `Memory_Access` operations too, so they share
its effects and its place in every pass. Their operands are all `usize`:
`Stack_Prepare` carries the stack slice's base and length, the entry function
value and its argument, and gives the stack pointer a switch resumes;
`Stack_Switch` carries the address it saves through and the stack pointer
it resumes, and gives nothing; the limit travels in the frames it saves
(D472). The verifier admits them only where the target's backend emits
them (D453). A prepare's one check, a slice too small, is
`stack_exhausted` (D451) and stays enabled inside unchecked regions. To a
native allocator a switch is a call: it leaves every caller-saved register
changed. The stack-limit check of D471 is no IR operation: a backend adds
it to the prologue of every routine of a program that prepares a stack,
from the routine's frame, which only the backend knows.

All memory primitives conservatively carry read, write, call and trap
effects, so simplification retains discarded accesses. They cannot reach an
eligible slot, so its forwarded value survives them, and address-taken
storage stays pinned by its address paths. Aggregate transfers remain
ordinary copies, with no atomicity promise. The
[target guide](targets.md#explicit-memory-operations) gives each target's
instructions.

## Packed fields and atom codes

D228 adds packed geometry to neutral field shapes: first bit, element width
and total carrier width. Encoded atom sets retain a separate unsigned encoding
table; ordinary values retain their existing atom identities. The verifier
checks geometry, field kinds, encoding membership tables and typed array/address
witnesses. A shaped extraction validates an encoding before producing an atom.
Discarding its result does not remove that check. Field stores preserve the
other image bits and retain fit checks; their effects include reads, writes and
traps. Whole aggregate copies preserve the carrier without extracting fields.

Ordinary atom loads also validate their software codes. The private call-status
slot has a different domain: zero means success, otherwise the code identifies
a declared error. `Is_Failure_Status_Load` recognizes only a slot designated by
a direct or indirect call's failure edge. D235's pointer union has a second
reserved-zero cell: its first field holds the atom's own code, and zero marks
the pointer case. `Is_Union_Code_Load` recognizes a load of that field from a
union held in a frame slot, and `Admits_Reserved_Zero` is the union of the two
predicates. Every implemented backend asks it, and permits zero only for such a load
before `Failure_Test`; ordinary source atom storage does not gain a zero value.
Recovery still observes a named error on the failing branch. The union itself
is an ordinary two-cell aggregate nominal with no source body — code, then one
pointer — and the verifier holds its shape to exactly those cells, so no IR
instruction, ABI position or selection was added for it.

The x86 baseline body-sharing check compares slot and value atom domains as
well as scalar carriers: two u32 carriers can require different validation
branches. Optimized body sharing compares the selected machine operations,
including those checks. Representation sharing cannot erase a validation trap.

The native backends consume the same geometry and map validated atoms to or
from each union's encoding table. Explicit device-register accesses reuse the volatile
memory instruction; fixed modes are checked before lowering and reserved-bit
requirements become retained guards before a write. The operation still has
one scalar transaction. No packed field is an independently addressable object.
Debug information exposes a packed nominal as its unsigned `raw` carrier;
field-level bit-array presentation is not claimed.

## Firmware and opaque assembly

D229 machine conventions are part of checked and IR signatures, independently
of C linkage. Signature equality, generic matching and verification preserve
ordinary, interrupt and naked identities. The verifier rejects ordinary calls
to machine-convention routines, invalid machine signatures, invalid placement
and naked bodies other than one opaque assembly operation followed by leave.
Items retain section, alignment, keep and vector metadata and a separate
immutable-image flag. Placement marks roots/address exposure before optimization;
the generated kept vector image supplies linker relocations to its handlers.
A convention alone is not a retention root.

Every `assembler.block` lowers to one `Assembly` instruction: its interned
text, without its comments (D597), and one entry per operand, each a direction,
a name, the written integer or floating-point type, a register — the target's
canonical full-width name, or empty for
`general` — and, for an output, the scalar frame slot it writes. Inputs are
the instruction's operands in written order, evaluated and kept in slots
before it; it defines no value, and lowering reads each output slot back
after it, filling a multi-output block's anonymous result field by field.
D230's shorthand is one `inout` entry at r0 with no name, and an operand-free
or naked block has no entries. The verifier holds entries to their inputs and
slots, refuses outputs that name parameter slots, holds names and registers
to being distinct, and, given target facts, every
register to the target's table and every type to one register's width;
`cortex ABI/assembly IR` corrupts each. Its fixed read, write, call and trap
effects invalidate memory knowledge and preserve ordering through
optimization and specialization, and simplification never forwards a store
across it into an output slot. Specialization also forgets any local
store-to-load evidence alias for each output slot; a later store can
establish a new alias. It is not a hardware barrier. Cortex emission reads live values from their
compiler stack homes after ordinary low-register-clobbering text; ordinary
text cannot name SP, LR, r9, r11 or other high registers. Naked text owns all
machine state and receives no frame. Ordinary and interrupt routines retain
the eight-byte previous-r11/incoming-LR record when framed; eligible leaves
leave both registers untouched. An interrupt's incoming LR is EXC_RETURN.
The hardware frame separately saves volatile registers and flags.

D248's named operands are checked against `Landin.Targets.Assembly`'s
register tables on every target. A backend chooses each `general` register
through the same table, in its written order, passing over every register the
block holds or its text names, and fills `{name}` at the operand's width.
Every implemented backend emits ordinary blocks. A naked body keeps its
no-frame contract on every target, written in that target's assembly, and
the positional shorthand keeps its Cortex register contract. x86-64's allocator hands
out only rbx and r12-r15 in a routine with assembly, and
never one a block of the routine declares, which it saves instead, so each
input moves straight into its register and each output straight to its slot.

`Landin.Backend.Firmware` constructs reset and the selected memory script;
`Landin.Targets.Firmware` owns board limits and which Cortex-M instructions
an `assembler.block` may use at each level. Startup copies initialized data and RAM code, clears BSS and transfers to the selected
source entry. Neither module-image lowering nor startup executes user module
initializers. Target ELF relocations distinguish Thumb code pointers from data
addresses. The generated firmware probes test these boundaries through actual
QEMU execution, with synthetic devices on the same QEMU; source-level Cortex
debugging is described below.

D232's panic plan is compilation metadata beside the verified IR. It validates
the entry hook before emission and binds byte-position sites to canonical
source snapshots. Backends classify each checked edge and retain the operation's
origin; clones therefore retain sites, and selected-handler immediates prevent
unsafe native body sharing. The failed edge cannot continue or unwind, so the
existing observable trap effects remain barriers. The selected source routine
is public and backend references retain it and its reachable data. Physical
atom codes are refreshed after specialization exposes any additional domains.
The optional source map shares D192 build identity but does not change caller
coordinates. No map or reporting code is required at runtime.

The native debugger gates include a D231/D232 program that enters a selected
handler through erased evidence and a generic nonreturning callback. Source
breakpoints, values, operation sites and unwind frames execute under GDB/LLDB
at three profiles. Darwin out-of-line panic edges carry their originating
source line. On x86-64 a failed check's trap is laid out after its routine's body,
one per operation and kind, so a passing check falls through; each keeps its
operation's line, variable locations and lexical scopes, and the body's frame
description. Those native sessions remain separate from Cortex source debugging.

The [generated device consumers](../devices/README.md) add no IR operation.
Constant addresses and image arithmetic use existing folding; retained data,
volatile accesses, encoded extraction traps and opaque CPU assembly keep their
existing effects. The six optimization/specialization profiles independently
check identical device traces and D232 failure sites, including discarded
extraction under `unchecked`. Existing enum-domain-sensitive body sharing,
array-versus-struct stored-shape and private call-status rules are unchanged.

The [complete derived driver](../compiler/tests/driver/DERIVATION.md) likewise adds
no IR operation. It exposed a checking defect: initializer inference visited
a concrete call's recovery `continue` before its enclosing loop existed.
Recovery bindings settle during inference, but body checking waits for the
routine walk and replays cached calls in their source/routine view. The shared
`r690-recovery-loop-context` execution fixture checks break/continue cleanup
edges through lowering, verification, optimization and every hosted backend.
The full Cortex application executes the same recovered-continue path on
overrun. Volatile transactions, opaque barriers, frame records, private r12
status and retained data keep their existing effects and sharing rules.

The firmware linker now explicitly gives NOLOAD BSS its RAM load address,
avoiding GNU ld's inherited RAM-code VMA/LMA delta. BSS has no file payload;
reset still clears it. A nearly full driver image executes under the original
flash limit, with independent ELF load-header and poisoned-reset assertions.

The Cortex line/function debugger consumes the existing source origins and
generic-template identities. It introduces no target register, DWARF record or
debugger artifact into the IR. `Backend.Dwarf.Line_Sections` emits the bounded
ELF32 function/line contract, and each module datum a declaration names
with its type at its symbol, written by the encoder the hosted description
uses; `Backend.Cortex_M` describes its own physical CFI,
including explicit unwind termination for interrupt/naked routines. No Cortex
variable location plan is advertised or inferred from storage homes: a
routine's slots are not described. Existing
optimization, volatile transaction and private call-status effects remain
unchanged; executable LOAD-image comparisons verify that adding debug metadata
does not change firmware execution or initialization. See the
[target debugger contract](targets.md#cortex-source-debugging).

ELF DWARF location and lexical-range references use section relocations.
They remain correct when another linked object contributes DWARF before the
compiler's object, as FreeBSD's startup objects do; a contribution-relative
offset would select the other object's list. This changes debug serialization,
not the IR's verification or optimization boundary.

## Keeping this account current

The implementation starting points are `Landin.IR`, `Landin.Stages.Lowering`
and `Landin.IR.Verifier`; their child packages describe dumping, effects,
specialization and simplification. The
[compiler package guide](../compiler/ada/README.md) maps their responsibilities,
and the [test guide](../compiler/tests/README.md) explains the recorded and
executed tests.

Changes to the representation, its verification boundary or the optimization
pipeline should update this account alongside the implementation. Examples
should continue to follow checked fixtures, and claims about behavior should
be traced to code and tests. A disagreement is a reason to investigate and
correct this derived explanation, never to elevate it into a source of rules.
