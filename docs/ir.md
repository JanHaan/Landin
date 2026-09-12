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
[roadmap](../ROADMAP.md) owns plans and acceptance evidence. When any of those
change, this account follows them. It must never be used to justify changing
the compiler to match the prose.

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
    -> simplification -> verified IR
    -> target layout, allocation and instruction selection
    -> assembly -> platform assembler and linker
```

Only the Linux x86-64 backend currently emits executable programs. The IR is
nevertheless expressed without x86 registers, stack offsets or instruction
encodings. The backend translates its operations into machine instructions
and supplies the calling convention and object-format details.

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
successfully or exits with a declared failure. A loop is represented with
blocks and a backward edge. There is no separate loop instruction for the
backend to interpret.

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

One of the positive fixtures contains this routine:

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

The following is a schematic reading of the recorded lowering, with
instruction numbers and a forwarding block omitted. It is explanatory
notation, not the dump format:

```text
entry:
    store 0 in r
    condition = load c
    branch condition to then_arm or else_arm

then_arm:
    store 1 in t_then
    a = load t_then
    store a in r
    jump merge

else_arm:
    store 2 in t_else
    b = load t_else
    store b in r
    jump merge

merge:
    result = load r
    leave result
```

Neither `a` nor `b` crosses into `merge`. Each arm writes the shared result
slot, and the merge block loads it. The actual fixture and its dump are
recorded under `positive/arm-scopes-are-siblings` in the
[fixture corpus](../compiler/tests/README.md).

The current IR has no phi instructions or block parameters: the mechanisms
many static single assignment representations use to select a value from
incoming edges. Storage provides that connection here, including for
expression results and short-circuit Boolean expressions. For `and`, the
right operand runs only on the edge where the left operand was true; `or`
uses the complementary choice. These are branches, not eager arithmetic
operations.

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

Target facts also enter verification and simplification where an answer
requires them. A folded initializer must fit the type that will hold it, and
folding a pointer-sized integer operation needs the target's width. This
does not require putting a register or an offset into the IR, or consulting
the host's pointer size.

The operation vocabulary preserves distinctions that affect behavior.
Ordinary integer addition and wrapping addition are different operations.
A checked conversion and a range-subtype check are different too: conversion
can change the integer type, while a range check passes a value of the same
type through only if it satisfies the bounds. A signed right shift describes
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
aggregate where the calling contract requires it.

Module data is also distinct from routine execution. A datum holds a static
value description or image, including nested contents and function
relocations where needed. Instructions used to describe a static value are
not startup code. They do not introduce execution before the entry point.

## Calls, evidence and failure

A function value needs more than an address. Its signature descriptor
retains ordered parameters and results, their shapes, and the applicable
calling-convention and failure information. Direct calls name a routine as
well as a descriptor; indirect calls carry a descriptor even when the
concrete routine is unknown. The verifier can therefore check a call without
mistaking every pointer-sized quantity for a compatible function.

Landin's concepts describe required operations. Evidence tables supply the
implementations for a particular type. The IR describes those tables and
their ordered entries, and has operations to obtain a table address or
project a function from it. An entry index remains a semantic identity until
the backend turns it into an offset.

An `any C` value packages an object with evidence for concept `C`, allowing
runtime selection. The IR retains the represented shape and the relationship
between the selected function and its receiver. Verification checks that
relationship; an erased call cannot freely pair a function from one
projection with an unrelated receiver.

Declared failure is separate from ordinary results. A call can have a
failure slot, and a failure test selects the subsequent control flow. A
failure exit carries an atom belonging to the declared error set. The
backend chooses the physical success and failure carriers. These explicit
edges represent recoverable language-level outcomes; they are distinct from
runtime traps such as a failed arithmetic check.

## Verification and optimization

Verification runs in release builds as well as debug builds. It checks the
completed unit before backend use, and the current specialization and
simplification passes verify their inputs and outputs. It checks storage
runs and identities before dereferencing them, then block structure,
reachability, operand order, type agreement, signatures, shapes, paths,
evidence and static images.

This is structural and semantic consistency checking of a compiler data
structure, not a proof that compilation preserves every program's behavior.
Source diagnostics belong to the frontend. Malformed IR at this boundary is
a compiler defect, and the tests deliberately construct malformed units to
check that they are rejected. Recorded lowering and executable fixtures
provide different evidence: what the compiler produced, and how the emitted
program actually behaved.

Specialization currently proves incoming static evidence where it can and
replaces eligible indirect dispatch with direct calls. It retains existing
instance entries and the working indirect fallback for unknown or exposed
entries. Specialization creates no new semantic instances: generics and
dynamic dispatch must already work without it.

Simplification folds supported constants, forwards eligible local slot
values, simplifies known branches and removes unused computations when
their effects allow it. Values remain block-local. The effects model treats
reads, writes, calls, traps, control flow and required instruction adjacency
conservatively. An unused result alone is not enough to delete an operation:
a possible trap is observable. Floating-point reassociation and assumptions
invented from `unchecked` are outside these rewrites.

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
the emitter, not to the neutral representation.

`Landin.IR.Dump` produces deterministic text for inspection and regression
comparison. `compiler/tests/lowering.ir` records the positive fixture corpus
in that form. Items and their contents use dense identities rather than
addresses or hash iteration order. Source byte offsets are deliberately
absent from the dump, so moving a comment does not rewrite the recorded
lowering; dedicated tests check attribution instead.

The dump has no reader and is not a stable serialization format. Comparing a
fresh dump with the recorded one detects a change in lowering; it does not
make the text an interchange protocol or establish the correctness of the
change. The Ada representation can evolve as implementation evidence
requires, without treating either its printed spelling or this page as a
compatibility promise.

## Keeping this account current

The implementation starting points are `Landin.IR`, `Landin.Stages.Lowering`
and `Landin.IR.Verifier`; their child packages describe dumping, effects,
specialization and simplification. The
[compiler package guide](../compiler/ada/README.md) maps their responsibilities,
and the [test guide](../compiler/tests/README.md) explains the recorded and
executable evidence.

Changes to the representation, its verification boundary or the optimization
pipeline should update this account alongside the implementation. Examples
should continue to follow checked fixtures, and claims about behavior should
be traced to code and tests. A disagreement is a reason to investigate and
correct this derived explanation, never to elevate it into a source of rules.
