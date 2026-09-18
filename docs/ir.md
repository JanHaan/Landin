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

Linux x86-64 and Darwin arm64 backends emit executable programs. The IR is
expressed without machine registers, stack offsets or instruction encodings. The backend translates its operations into machine instructions
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
successfully, exits with a declared failure, or traps with `Halt`. A loop is represented with
blocks and a backward edge. There is no separate loop instruction for the
backend to interpret.

Signature identity includes D231's `noreturn` return form. A direct or
indirect nonreturning call must be the penultimate instruction of its block,
followed immediately by `Halt`. D232 dispatches that guard as `unreachable` if an invalid callee returns.
It has control and trap effects, and the verifier refuses a returning body
with a nonreturning signature. Generic and erased evidence signatures retain
the same flag; it never becomes an ordinary IR value type.

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
type through only if it satisfies the bounds. D232 marks range checks used
for representation validation separately: null pointer construction, malformed
text and reserved-bit patterns report `bad_conversion`; subtype bounds report
`out_of_range`. Rewriting and specialization preserve this flag, and proved
constant replacements remove it with the check. The verifier refuses it on
other opcodes. A signed right shift describes
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
evidence and static images. Pointer-provenance dataflow keeps its
block-by-slot input and output tables in scoped heap storage, including
when verification exits early after finding a fault.

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

The default compact dump preserves the existing recorded format and omits
pointer metadata. `Landin.IR.Dump.Text` with `With_Metadata => True` adds
pointee definitions and identity edges, signature/result/slot/value annotations,
nominal shape identities and `Place_Address` storage endpoints. These are
reached-type facts, not source origins or lifetime guarantees. Comparing compact
dumps alone cannot detect a metadata-only change; focused detailed-dump tests
cover that distinction. Pointee edges are printed without recursive expansion.

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

## Target capability checks

The verifier's target-aware entry checks C signature and variadic-call
capabilities through `Landin.Targets.Capabilities`; the source checker also
checks C record eligibility. A second LP64 description therefore cannot inherit
SysV support from its pointer width. Nominal C-layout metadata describes
structural compatibility and also occurs on distinct scalar storage, even
without an implemented C ABI. Its structural verification remains independent
of that capability. The IR carries logical conventions, source link names and
neutral shapes;
ABI carrier assignment, object symbol prefixes and debug format selection stay
in target/backend packages. The Linux and Darwin description seam compares
canonical IR for native generic, aggregate and control-flow source. R5.20 adds
no opcode or serialized IR field; the existing complete IR golden is unchanged.


The Darwin backend gives every routine an x29/x30 frame record and every value
a stack home. Native Landin calls use integer bit carriers, address-based
aggregate copies and a separate w8 failure carrier. The Darwin C planner maps
the same verified signatures onto Apple's independent register banks, HFA
rules, indirect results and packed/variadic stack rules. These choices belong
to the emitter; error propagation and cleanup edges arrive already verified.
Neutral specialization and simplification run before either emitter. Darwin
currently uses baseline stack homes without the x86 register allocator or body
folding. Its reports record frame size; backend quality optimization is not a
parity claim. R5.40 consumes these same stack placement plans for DWARF locations.
The shared `Backend.Dwarf` encoder uses neutral source identities and
`Backend.Debug_Locations` availability; Mach-O sections, x29 CFI and dSYM
packaging stay at the backend/toolchain boundary.

R5.50's full hosted audit preserves these boundaries. Scalar part addressing
on Darwin carries wide IR element positions through target-byte placement,
rather than narrowing them through the Ada host index type. Complete derived
programs share the same source/provenance and location facts across GDB and
LLDB acceptance; physical encodings and packaging remain backend-owned.

R6.20 adds a real Cortex-M0 description and `Backend.Arm32_ABI` planning while
leaving this neutral representation unchanged. Eight existing source controls
compare detailed IR, including pointer metadata, against synthetic-32 and plan
their entry/direct/indirect signatures. The planner consumes lowered pointer,
atom, slice/any, distinct and evidence carriers; it adds the physical result
address before the signature's existing evidence/parameter run. External C
and internal Landin transport remain separate. Independent C/assembly probes
execute the selected contract. R6.50's Cortex emitter now consumes those same
plans; no new target-neutral opcode or effect category was needed.
See [the target contract](targets.md#cortex-m0-layout-and-abi-planning).

R6.30 adds `Memory_Access`, retaining operation, scalar width identity and
success/failure orderings. Its variable operand run carries only runtime
values; compile-time ordering atoms do not become machine arguments. The
verifier checks operation/order combinations, arity, operand/result types,
and selected target eligibility. Alignment checks belong to native lowering
and remain enabled inside unchecked regions.

All memory primitives conservatively carry read/write/call/trap effects, so
simplification retains discarded accesses and invalidates forwarded slot
values. Address-taken storage remains pinned by the existing address paths;
x86 allocation uses its existing saved-register/scratch discipline. Argument
spills preserve left-to-right evaluation across later control-flow expressions.
Specialization copies the complete instruction metadata; it neither erases
boundaries nor invents alias facts. Aggregate transfers remain ordinary copies,
with no atomicity promise. Target instructions are described in the target guide.

R6.40 adds packed geometry to neutral field shapes: first bit, element width
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
a direct or indirect call's failure edge. All three backends permit zero for that
transport load before `Failure_Test`; ordinary source atom storage does not
gain a zero value. Recovery still observes a named error on the failing branch.

The x86 baseline body-sharing check compares slot and value atom domains as
well as scalar carriers: two u32 carriers can require different validation
branches. Optimized body sharing compares the selected machine operations,
including those checks. Representation sharing cannot erase a validation trap.

The native backends consume the same geometry and map validated atoms to or
from each union's encoding table. Explicit register accesses reuse the volatile
memory instruction; fixed modes are checked before lowering and reserved-bit
requirements become retained guards before a write. The operation still has
one scalar transaction. No packed field is an independently addressable object.
Debug information exposes a packed nominal as its unsigned `raw` carrier;
field-level bit-array presentation is not claimed. ROADMAP.md owns validation,
limits and exact-revision closure.


Cortex-M selection uses pinned source places and reusable eight-byte homes for
block-local scalar temporaries. Last reads come from the verifier's explicit
operand runs; live operands cannot share a home, and a call cannot destroy a
live value. Selection uses low-register scratch and always constructs the r11
frame record before publishing it, including for leaves. The shared frame
placer still owns target-byte offsets and limits. Cortex performs no body
sharing; specialization and IR optimization retain their existing proofs.
The [target guide](targets.md#cortex-m0-assembly-implementation) records physical
choices. The complete profile corpus, explicit 32-bit counterparts and memory/
packed peripheral execution are retained by the embedded acceptance path.

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

Fixed `assembler.block` text lowers to a memory-access compiler boundary with
an interned payload. D230's scalar form adds one u32 operand and a u32 result;
verification checks that carrier independently of the memory operation's
compiler-barrier tag. The target loads r0 immediately before the text and
saves it immediately afterward. No new implicit register dependency enters IR.
Its existing full memory/call/trap effects invalidate
memory knowledge and preserve ordering through optimization and specialization.
It is not a hardware barrier. Cortex emission reads live values from their
compiler stack homes after ordinary low-register-clobbering text; ordinary
text cannot name SP, LR, r9, r11 or other high registers. Naked text owns all
machine state and receives no frame. Ordinary and interrupt routines retain
the eight-byte previous-r11/incoming-LR record; an interrupt's incoming LR is
EXC_RETURN. The hardware frame separately saves volatile registers and flags.

`Landin.Backend.Firmware` constructs reset and the selected memory script;
`Landin.Targets.Firmware` owns board limits and assembly eligibility. Startup
copies initialized data and RAM code, clears BSS and transfers to the selected
source entry. Neither module-image lowering nor startup executes user module
initializers. Target ELF relocations distinguish Thumb code pointers from data
addresses. The generated firmware probes test these boundaries through actual
QEMU and Renode execution; source-level Cortex debugging remains R6.100.

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
source line; this does not enable Cortex source debugging.
