# The Ada bootstrap compiler

This directory holds the bootstrap implementation described by `ROADMAP.md`.
It is a real compiler under construction, not a prototype: `spec.md` is the
normative language specification and `tour.md` explains the language, and
nothing here may quietly decide language semantics.

For an introduction to the intermediate representation and the reasons for
its structure, read [the IR guide](../../docs/ir.md). It is a maintained,
non-authoritative account derived from the implementation and its tests.

D230's Cortex-only scalar `assembler.block` has one explicit u32 operand/result
through r0, with the same conservative effects and ordinary register/frame
restrictions as result-free assembly. `core/cpu` uses this ordinary source
surface; [the core guide](../../core/README.md) records its public interfaces.
The compiler-host Cortex tests verify source/IR restrictions and the native
Linux freestanding lane executes the generated firmware. ROADMAP.md owns the
R6.70 implementation and its exact-revision closure binding. D231/D232 now implement
nonreturning control and selected panic handlers on all three backends.

## Layout

```text
compiler/ada/
  landin_common.gpr     build policy: language version, warnings, modes
  landin_lib.gpr        the compiler library, built by everything else
  refine.gpr            the `refine` executable
  landin_tests.gpr      the repository's own test program
  TOOLCHAIN.md          the pinned toolchain and warning policy
  src/
    base/               exceptions, policies, byte encoding and build reports
    source/             source snapshots, spans, line maps, provenance
    diagnostics/        diagnostic transport and text rendering
    platform/           host adapters and their native implementations
    modules/            reached module/source/import topology
    stages/             target facts, fixed-configuration activity and seams
    syntax/             the tokens, the scan, the syntax table and the parse
    resolution/         declarations, scopes and what each name means
    checking/           types, node facts, IR and verified transformations
    backend/            the frame, and the assembly emitted against it
    driver/             request/results, source maps and report provenance
    main/               the `refine` entry point
  tests/src/            the harness, the fakes and the suites
```

`compiler/tests/` sits outside this directory on purpose. Fixtures describe
the language, not this implementation, and must survive the bootstrap being
replaced.

## Preparing task-directed model context

`scripts/context_pack.py` builds a read-only context pack for a particular
task without putting every compiler body in one prompt. From the repository
root, for example:

```sh
python3 scripts/context_pack.py compiler/ada \
    --query='variant match checking and its fixtures' \
    --budget-tokens=500000
```

The pack contains the applicable `AGENTS.md`, compiler guidance and project
files, Ada specifications, a mechanical declaration and dependency index, and
exact source slices ranked by the query. Every source block names its original
path and SHA-256 digest, and exact slices also name their line span. Outlines
are navigation aids, not source, and an exact file must be consulted before it
is edited.

The script is standard-library-only. If the optional `tiktoken` package is
available, `--tokenizer=auto` counts `o200k_base` tokens; otherwise it visibly
uses an estimate of one token per three UTF-8 bytes. `--tokenizer=o200k` fails
unless the exact counter is available. `--compact-interfaces` removes comments
and optional layout from the specification copies in the pack, but it is off by
default because specification comments often carry compiler invariants.

## Package ownership

Every compiler package specification has one row here. `check.py` compares
the table with the source inventory, including private and generic packages.
The boundary in each row applies to that package, not automatically to all
its children; target-neutral `Landin.Backend` and its x86-64 allocator have
different responsibilities.

| package | owns | must not |
| --- | --- | --- |
| `Landin` | the namespace and the three exceptions | contain any logic |
| `Landin.Byte_Encoding` | byte-preserving hexadecimal ASCII encoding | interpret an encoding or access the host |
| `Landin.Hosted` | exact logical compiler-owned hosted helper identities shared by checking and emission | encode target prefixes, libc names or machine signatures |
| `Landin.Packed` | bounded raw-image masks, field/index algebra, encoding membership and explicit register access plans | access hardware, validate source values or infer optimizer facts |
| `Landin.Machine` | source machine conventions and checked placement metadata | infer target widths, perform host effects or reinterpret a calling convention |
| `Landin.Memory` | D227 memory operation identities and ordering legality | select instructions, infer aliases or choose a target |
| `Landin.Layouts` | source representation policy names | place fields or derive target widths |
| `Landin.Optimization` | optimization objectives, specialization modes and their request spellings | change source meaning or disable runtime checks |
| `Landin.Build_Reports` | deterministic compiler decisions, outcomes and work counts | claim assembled-byte measurements or diagnose source |
| `Landin.Source` | immutable snapshots, byte offsets, spans, line maps | read a file, or know an encoding beyond bytes |
| `Landin.Source` storage | heap-allocated text and line maps, never freed while the process lives | put a source file in an automatic object |
| `Landin.Source.Sets` | a compilation's snapshots and their identities | acquire bytes from a host |
| `Landin.Provenance` | origins and the declaration side table | know what a declaration means |
| `Landin.Debugging` | optional source snapshots, source result labels and compilation-directory context, with access to immutable declaration syntax | copy represented types/layouts, read the host or encode a debugger file format |
| `Landin.Source.Names` | identities for the byte runs a program names | know that a spelling is reserved |
| `Landin.Tokens` | the lexical vocabulary, the token, the fault, the stream | render prose, assign a diagnostic code, or build a token |
| `Landin.Tokens.Lexer` | the scan, the only construction of a token, and D161's validation of complete text-literal spelling and [1750]'s comment encoding | know what a token means or decide its contextual text view |
| `Landin.Tokens.Text` | D161/D181's shared UTF-8 validation for literals and comments, and byte, UTF-8 and UTF-16 literal decoder | diagnose, choose a literal context, or own emitted storage |
| `Landin.Syntax` | the node table, extents, anchors, origins, soundness, and the retained independent C-convention, variadic, bodyless-import, visibility, C-layout and symbol-literal facts | know that types or IR values exist, or hold a diagnostic |
| `Landin.Syntax.Precedence` | [1820] as data: levels, operators, folds, first sets | contain a parsing decision |
| `Landin.Syntax.Parser` | the parse, including contextual separation of a final `try` expression from a `try` statement followed by more body items, D185's initialized condition-binding form D186's contextual caller parameter and D187's two-token contextual `unchecked` region, contextual-name bindings and assignments selected by their punctuation before control-word dispatch, and the only construction of a tree | assign a diagnostic code, or read a byte |
| `Landin.Syntax.Dump` | a canonical text for a tree | be a stable interface or a serialisation |
| `Landin.Syntax.Forest` | one tree per source for the whole compilation, on the heap and never freed | hand out a tree that can be copied or written to |
| `Landin.Modules` | the deterministic reached graph: module identities, selected directories/root ordinals, source membership and resolved import edges | read the host, parse source, own a scope or depend on a stage |
| `Landin.Resolution` | declarations, scopes, and which declaration each name means | hold a diagnostic, or decide what a name may be called |
| `Landin.Types` | the scalar names and value categories, their widths, and ordinary scalar storage size against a target | hold a machine fact of its own, or ask the host for one |
| `Landin.Evidence` | target-neutral semantic evidence-table positions: size, alignment, then direct concept functions in declaration order | know machine bytes, target offsets, or physical layout |
| `Landin.Checking` | the type of every runtime node and declaration, the concept and conformance register, interned nominal and routine instances with their per-instance facts and layouts, and D188's range-subtype identities; the full list is under "The four long rows, in full" below | decide a rule, execute user code, synthesize a source declaration, mutate a template, or ask the host for a width |
| `Landin.Cleanup` | target-neutral exit kinds and the defer/undo applicability policy | parse a cleanup, track definite assignment, emit a call, or name a target |
| `Landin.IR` | the target-neutral instructions, shapes, descriptors, images, paths and source aliases into existing storage; the full list is under "The four long rows, in full" below | hold a scope tree, name a machine, ask a width, synthesize a declaration, or hold an offset, register or padding byte |
| `Landin.IR.Control_Flow` | linear-space adjacency and entry reachability of structurally checked IR | assume reachability or store represented object bytes |
| `Landin.Panics` | canonical entry-hook validation, source-byte site spaces and final nonzero atom codes | runtime reporting or allocation |
| `Landin.IR.Effects` | conservative opcode effects and policy weights, including observable traps | infer alias permissions from unchecked regions |
| `Landin.IR.Rewriting` | shared arena compaction for verified transforms | change slot, signature, shape, image or semantic instance identities |
| `Landin.IR.Shape_Measurement` | memoized represented extents under target facts and an explicit size limit | choose machine placement or allocate work per represented array element |
| `Landin.IR.Simplification` | verified local simplification under the selected objective | reassociate floating arithmetic, create cross-block values or infer unchecked alias facts |
| `Landin.IR.Specialization` | whole-program static-evidence devirtualization with retained instance entries and indirect fallbacks | create semantic instances or specialize exposed or unknown entries without proof |
| `Landin.IR.Specialization_Policy` | bounded benefit and profitability estimates | claim assembled-byte costs or depend on host word width |
| `Landin.IR.Verifier` | release-build well-formedness of a completed Unit, including atom/error set membership, descriptor/carrier, multiple-result slot and static function-image agreement, call-failure slots and exits, valid neutral subobject paths and recursive image descriptors, plus target-aware fit of every static fold | diagnose source, repair malformed IR, or choose backend policy |
| `Landin.IR.Dump` | canonical human-readable text for a Unit | be a stable interface, a reader, or a serialisation |
| `Landin.Backend` | where a routine's cells live, the recursive target extent of one neutral field shape, where a scalar or fixed-array leaf at any path depth sits inside an aggregate datum or slot, how wide one element of an array of either is, and the target-byte replay of scalar, fixed-array and unfolded variant runs | name a machine, choose a register, or ask the host a width |
| `Landin.Backend.Work_Arrays` | heap-owned backend scratch with lexical exception-safe reclamation | place instruction-proportional arrays on the host stack |
| `Landin.Backend.C_ABI` | SysV AMD64 classification and one call/entry/result placement plan from target facts and neutral shapes, including independent GP/SSE banks and aggregate rollback | ask the host for layout, put register placements in IR, or change the internal Landin ABI |
| `Landin.Backend.Arm32_ABI` | Cortex-M0 base AAPCS soft-float and internal Landin argument/result planning from neutral signatures | emit instructions, enable C source capability or infer ABI from pointer width |
| `Landin.Backend.Cortex_M` | ARMv6-M instruction selection, reusable stack homes, frames, internal calls, checked operations and ELF assembly from verified IR and Arm32_ABI plans | change language semantics, enable general C source, own language startup/linking or claim Landin source debugging |
| `Landin.Backend.Darwin_ABI` | Apple arm64 C classification and argument/result placement from neutral shapes and target facts | infer layout from the host, reuse SysV transport or change source semantics |
| `Landin.Backend.Arm64` | Darwin assembly, stack homes, frame records, native/C calls, hosted runtime and Mach-O data/symbol rendering | parse/check source, put physical transport in IR, write files or run tools |
| `Landin.Backend.Dispatch` | backend selection for frame preflight and assembly/debug emission | choose language semantics or discover host tools |
| `Landin.Backend.X86_64` | the assembly text for one target, every register in it, collision-safe whole-program symbols, the hosted entry argument/libc bridge, D161's read-only literal data, the target-width scalar, finite-array, compact repetition, nested-child and selected-variant directives and padding for recursively written aggregate images, and D187's omission of exactly the overflow, element-index, slice-range and integer-conversion edges an instruction is marked for | decide a language error mapping, write a file, or run a tool |
| `Landin.Backend.X86_64.Allocation` | deterministic stack homes and the five available SysV callee-save GP registers | allocate selection-owned scratch, argument, failure or SSE registers |
| `Landin.Backend.X86_64.Machine` | selected instruction counts and optional canonical body-equivalence evidence | canonicalize external symbols as local labels or equate counts with assembled bytes |
| `Landin.Backend.Debug_Locations` | format-independent lexical visibility and definite initialization at IR instruction boundaries | choose storage, encode debugger records or read the host |
| `Landin.Backend.Dwarf` | shared DWARF type/scope/location encoding parameterized by backend placement and section policy | change language types, choose variable storage, read the host or write files |
| `Landin.Backend.X86_64.Dwarf` | x86 allocation adapter, register encodings and ELF entry points for the shared DWARF encoder | change source facts or choose variable storage |
| `Landin.Backend.Toolchain` | the one command line that finishes a compilation, the triplet it is found by, and D202's ordered archive arguments | infer target policy from the host, invoke a linker directly, or search a PATH |
| `Landin.Backend.Firmware` | compiler-owned reset text, constrained linker script and bounded image materialization | perform host effects or initialize user modules by executing source code |
| `Landin.Backend.Entry_Point` | [1970]'s one hosted entry shape, asked of the IR | raise a defect for a module that simply has no `main` |
| `Landin.Diagnostics` | codes, severities, labels, notes, ordering | render, or own the catalogue of codes |
| `Landin.Diagnostics.Modules` | catalogue diagnostics for rooted module discovery failures | perform filesystem discovery or invent diagnostic codes |
| `Landin.Diagnostics.Text` | deterministic rendering, sharing a primary snippet with its first related label only when source and complete span agree | decide severity or ordering policy |
| `Landin.Diagnostics.Catalogue` | every diagnostic code, and what each requires of its occurrences | hold a message, or a code nothing raises |
| `Landin.Diagnostics.Lexical` | turning a scanner fault into a diagnostic | invent a code, or a roadmap item |
| `Landin.Diagnostics.Syntactic` | turning a parse failure into a diagnostic, and naming the constructs only the parser can meet | invent a code, a construct, or a roadmap item |
| `Landin.Diagnostics.Resolution` | turning a duplicate or an unknown name into a diagnostic | invent a code, or attach a sentence to no place |
| `Landin.Diagnostics.Checking` | turning a type that does not agree or a checker-recognised deferred use into a diagnostic, including the refused-type table and L0304 ownership | invent a code, a construct, or a roadmap item |
| `Landin.Platform` | the host interfaces every effect goes through | perform an effect |
| `Landin.Platform.Native` | the only filesystem implementation | be reached except through the interface |
| `Landin.Platform.Native.Tools` | process supervision and capture, using its host POSIX C adapter and GNAT path/temp-file support; `Landin.Source_Maps` and `Landin.Build_Reports.Sources` use `GNAT.SHA256` as pure computation | grow a second host concern |
| `Landin.Targets` | target facts, typed architecture identity, layout arithmetic, physical evidence-cell offsets/extents and D147 any data/table offsets, extent and alignment derived from pointer facts | ask the host how wide a pointer is |
| `Landin.Targets.Firmware` | constrained Cortex memory-map facts and source assembly admission | invoke tools or derive target widths from the host |
| `Landin.Targets.Packed` | packed image storage measurement and width-specific transaction eligibility from target facts | enable source syntax, select instructions or claim a Cortex emitter |
| `Landin.Targets.Layouts` | target-byte placement of complete source-indexed field units under explicit layout policy | expand array elements into planner entries or decide C subset eligibility |
| `Landin.Targets.Capabilities` | implemented C signature/record/varargs capabilities, object and debug formats, logical-to-object symbol prefixes, backend availability and toolchain triplets | infer capability from width, invoke a tool, or canonicalise a triplet |
| `Landin.Configuration` | D139's immutable active-declaration view after target selection and D202's request mode/overrides, option origins and ordered library requests | mutate syntax, resolve an ordinary source name, or expose a general compiler module |
| `Landin.Stages` | the compilation context, the stage interface, pipelines, and everything a stage builds that outlives it | know which stages exist, or which order they run in |
| `Landin.Stages.Syntax` | running the scan and the parse over a compilation | keep anything of its own, or decide reporting policy |
| `Landin.Stages.Configuration` | validate and select D139 fixed declaration arms, collect and evaluate D202's global typed options, fixed compiler facts, scalar target measurements, assertions and library directives before resolution | execute user code, mutate syntax, resolve ordinary declarations or add a runtime declaration |
| `Landin.Stages.Resolution` | the order the trees are walked in through the D139 activity view, including D185's condition-initializer outer scope and guarded-body binding scope and D186's caller-skipping positional call map | own the resolution table, or a code |
| `Landin.Stages.Checking` | the type passes, concept and conformance collection, generic interning and instantiation, fixed-expression evaluation, inferred-error fixed points and checking-stage diagnostic order; the full list is under "The four long rows, in full" below | own a table, a code, execute user code, synthesize a declaration, or choose a target-dependent operator width |
| `Landin.Stages.Folding` | the shared constant folder for checked ordinary expressions in checking and lowering, a generic both stages instantiate with their tables and the few answers only each stage has: how a name reaches its tree, which scalar a conversion targets, a character's value, a float special's bits, and what to do when a module value is worked out from itself; integers and bools fold to their value, floats to their IEEE bit pattern, and an overflow is a distinct outcome from an unknown | report a diagnostic, hold a cycle set of its own, or fold anything the checker has not typed |
| `Landin.Stages.Checking.Flow` | definite assignment, including D156/D157's conservative post-loop assignment boundary and D185's initialized condition binding, D178's complete fixed-array traversal element, D180's copied iterable Item and D182's whole-view utf8 index read, use-after-`sink`, restoration of consumed `inout` parts, explicit fallthrough/return-compatible edge facts, and lexical cleanup execution states | decide a type, believe a condition, or lower a value |
| `Landin.Stages.Checking.References` | function-local origin and derivation flow, exact `from` agreement, `escaping` obligations and live-view mutation checks; D146 maps an erased construction and implicit self to its pointee fact, D180 gives [1320]'s source-free Item result no source alias, and D182 keeps an indexed codepoint view derived from its utf8 source; integer-created pointers deliberately terminate its evidence | infer a signature across calls, claim ownership, or make an aliasing assumption about volatile storage |
| `Landin.Stages.Lowering` | the walk from checker identities to verified IR, text datums and traversals, evidence tables, aggregate results, cleanups and regions; the full list is under "The four long rows, in full" below | own the Unit, work out a scope, derive target layout, synthesize a declaration, or raise a diagnostic |
| `Landin.Driver` | argument and `--emit` classification, R3.10's private ordered-root graph discovery through `Landin.Platform`, pipeline orchestration, output/toolchain selection and the result | implement a language rule, acquire a package or expose a public orchestration protocol |
| `Landin.Build_Reports.Sources` | off-target report provenance rendered from the compilation | read the host or add report data to the executable |
| `Landin.Source_Maps` | optional source-name tables and their assembly-bound build identity | resolve names through new host reads or change language source identities |
| `Refine` | printing and the exit status | contain a decision |

D201 keeps aliases and selected imports in the source file's import scope.
Resolution retains each selected declaration's original identity and diagnoses
private, missing, duplicate and reserved bindings at their import sites.
Labelled applications retain their callee classification, argument roles and
role-local positions. Resolution reads a direct callee's immutable signature
syntax even when its declaration occurs later; checking completes runtime
positions against the full direct or indirect signature. The table retains no
separate formal declaration identity for an argument.

D202 adds configuration declarations to immutable syntax but gives them no
runtime identities or storage. The configuration stage consumes them before
ordinary declaration traversal; its option origins let resolution diagnose
collisions with active module and file-import bindings.

The driver accepts `--option=NAME=VALUE` and
`--build-mode=debug|release` as explicit request configuration. The latter
controls `compiler.build_mode`, independently of the Ada build's
`LANDIN_BUILD_MODE`; it changes neither emitted checks nor optimization.
`linker.library` requests a static archive through the platform driver,
preserving source order and repetitions. It does not change that driver's
hosted-runtime linkage policy.

D187 follows them too, and adds no stage: the parser recognises the region,
`Landin.IR` records it on the instructions it is emitting, and the backend is
the only place that decides an edge is not written. Nothing in checking,
resolution or flow reads the flag, because a region removes no static rule.

D189 adds one node kind and one descriptor field and no stage. The parser
owns the pointer member of an atom union and the `ptr` arm head, which is
`Landin.Syntax.Pointer_Case` rather than a name because the reserved word is
not a case name and resolution has nothing to bind it to. `Landin.Checking`
owns `Reference_Descriptor.Empty_Atom`: the union's representation is a
pointer, so it is a field of the pointer descriptor and not a
`Landin.Types.Type_Kind`, and the price of that choice is that the positions
which would read the carrier as an address are guarded by name in
`Landin.Stages.Checking` rather than by an exhaustive case. Reference
checking gives the bound pointer the subject's own origin and gives the empty
case none; lowering emits the reserved zero and one comparison against it.
D206 separately refuses known null integer constructions and checks dynamic
zero after target-width conversion, even in `unchecked`; origin erasure does
not erase non-nullness. The library's absent backing uses named pointer unions,
and `dispose` reports `raw_empty` rather than returning an invalid pointer.

D203's C convention and variadic flags follow the complete recursive signature,
not the bodyless import flag or a concrete callee item. Checking admits only
[1975]'s selected C subset and lowering promotes unnamed outgoing C arguments;
verification checks the same signature facts for direct and indirect calls.
`compiler.c_sysv_lp64` and `compiler.c_darwin_lp64` are early fixed
configuration bools, with no runtime storage. Ordinary `core/c` accepts either
supported LP64 contract; generated bindings assert their selected contract. Header
parsing and C adapter generation belong to the separate bindings tool, not to
the scanner, parser, type checker or native backend. The authoritative closures
of R4.40 and R4.50 are recorded in ROADMAP.md.

D209--D211 add independent `--optimize=none|size|speed` (default size) and
`--specialize=off|auto|all` (default auto) controls. The driver runs verified
specialization, then verified simplification, then option-aware frame preflight
and selected-target emission. Legacy backend `Text` callers explicitly retain none/off;
the command-line default never inherits that reference convenience.
`Landin.Optimization` owns typed controls; `Landin.IR.Specialization` owns
incoming-evidence proof and profitability, `Landin.IR.Simplification` owns
conservative neutral rewrites, and each native backend owns allocation and selection.
Call verification checks the addressed storage shape of every aggregate or
array argument and hidden result, for direct calls, ordinary function values
and erased dispatch. A usize carrier alone does not establish an extent,
element type or nominal identity. C nominal checks and erased-self adjacency
remain separate requirements.
The IR also has deliberate raw usize address transport and integer operations.
Plain slots or parameters carry bits without promising a reached type, and word
comparisons do not impose source-pointer compatibility. Reloading plain storage
does not restore pointee metadata: typed stores, calls and `Pointer_Address`
still require matching evidence, and annotating a raw load cannot supply it.
The source checker separately enforces Landin pointer comparison and conversion
rules; the verifier does not reinterpret every low-level word as a source pointer.
The shared checker/lowering constant folder memoizes known module-binding
values only within one fold request. Recursive references reuse completed
values; unknown and overflowing folds keep the stage's cycle and diagnostic
behavior. Later requests start fresh because semantic tables may have gained
facts or changed their active instance context.
Recursive shape measurement shares a memo across descendant layout queries
within one public request. Complete shapes key the results, while the unit,
target and maximum stay fixed for that request. Return or failure discards the
memo; later calls recheck their own target, limit and unit. An in-progress entry
refuses a represented cycle instead of recursing indefinitely.
Specialization and final-body sharing collect address exposure through one
shared traversal of retained IR references. Explicit/imported roots, scalar and
aggregate function images, evidence entries and runtime function addresses feed
each consumer's existing local marks. The traversal retains no cache; consumers
refresh their marks after IR changes, and single-routine queries share its policy.
Specialization counts eligible normalized instances once per template before
profitability decisions. The pass-local counts exclude exposed or unproven
instances, preserve report order and do not change the evidence proof or cost
policy; one template's instances cannot affect another's single-instance rule.
Backward demand removes a pure function address when it has no users,
including a projection left after specialization turns a call direct. A live
function value retains its signature; numeric folding still excludes it.
Resolution and checking tables retain the identity of each immutable forest
tree when prepared. `Covers` checks that exact object as well as its source
number and node count; an equally sized tree from another compilation is not
interchangeable. Host addresses serve only this internal equality check, never
source numbering, target layout, output or iteration order.
Generic instance ownership follows the resolver's lexical scopes. A nested
no-capture anonymous signature begins from file scope, so its declarations
remain independent of the enclosing generic routine's instance overlays.
Help and identity responses follow complete command-line validation, including
deferred target, mode, override and root checks. Valid informational requests
return before source discovery and reads. Source-dependent option typing remains
a compilation-stage check, so information alone does not load option declarations.
Build-report collision preflight uses the same actual artifact list as source
protection. A source-map path is reserved only when full debug information or
caller coordinates require a map; filesystem identity still decides aliases
between reports, emitted artifacts and every discovered source.
A first-class imported C routine address is loaded through its ELF GOT entry,
so Linux PIE linking does not require an invalid PC-relative relocation to an
external definition. Defined routines retain direct relative addresses; symbol
quoting and static function-pointer relocations keep their existing identities.
The selected-machine layer owns the signed-immediate boundary for nonnegative
target extents. Indexed access, slice scaling and array-fill suffix offsets
use a full-width register when their arithmetic constant exceeds that bound.
`Landin.Targets.Layouts` supplies one target-byte placement plan to checking,
measurements, paths and image emission. Source field identity and physical
placement order are distinct, and array lengths do not size placement metadata.

`Landin.Build_Reports` is typed off-target evidence. Producers append actual
specialization decisions, layout plans and routine metrics in stable identity
order. A specialization decision's `retains_fallback` says whether any
indirect call remains in that item immediately after specialization, including
erased dispatch and ordinary function-value calls; it is independent of the
action and does not predict later simplification. Scalar IR measurement dumps
name the measured type separately from the result type.
`Landin.IR.Dump.Text` also offers `With_Metadata => True` for diagnostic
inspection: it adds pointee definitions and references on shapes, signatures,
results, slots and instructions, and identifies `Place_Address` storage.
Pointee references are printed as identity edges rather than recursively
expanded types. The default compact dump retains the older recorded format;
its equality alone does not establish equality of pointer metadata. These
reached-type facts are distinct from source positions and lifetime claims.
`Landin.Build_Reports.Sources` adds snapshot hashes, hexadecimal path
bytes and half-open item-origin spans using pure computation. The driver alone
writes `--build-report=PATH` through `Landin.Platform`, after successful output
and tools; failure is an ordinary failed request, not a source warning. No
report bytes or provenance strings become mandatory executable storage.

The outer JSON has `schema: 1`, a `build` object in
`landin-build-report-1` format, `sources` and `items`. A source entry contains
`source`, `path_hex`, `sha256`; an item contains `item`, `declaration`, `source`,
`first`, `last`. The nested build carries the target and both controls, plus
`specializations`, `routines`, `layouts`. Instruction/stack counts are static
emission sites, `estimated_growth` is an IR policy score, and neither claims
assembled bytes. `scripts/quality.sh` obtains those from pinned Linux object
tools. Complete mandatory runtime profiles and quantitative acceptance are
recorded in `compiler/tests/README.md` and ROADMAP.md, not inferred from the
existence of these packages.

`--debug=full` requests Linux or Darwin source-debugger metadata; `--debug=none` is the
default. This control is independent of `--build-mode`, `--optimize` and
`--specialize`. Full debugging writes line information using the compilation's
source IDs and expands the existing `.sources.json` table to every source.
The optional metadata does not change the caller-coordinate ABI. See
`compiler/tests/README.md` for the scripted debugger gate.

Register allocation and specialization remain enabled under full debugging.
Only identical-body sharing is suppressed, so two source routines retain
distinct breakpoint locations. DWARF describes represented types and physical
locations using the immutable IR and the same backend layout/allocation plans
as instruction emission. Source declaration syntax supplies names and lexical
extents; it does not decide machine layout. The sections are non-allocated
DWARF 4 metadata, and frame information covers saved registers so a caller's
register-resident locals remain inspectable while stopped in a callee.

DWARF is an output encoding. Source identity, represented types and allocation
facts remain usable by other emitters, including a possible future PDB path;
neither DWARF record numbers nor ELF packaging belong in the neutral IR.

For a Linux source session, compile with `refine --debug=full --emit=exe
program.ldn -o program`, then open `gdb ./program`. Ordinary commands such as
`break main`, `break program.ldn:12`, `run`, `next`, `step`, `bt`, `info args`
and `info locals` use the emitted metadata. `--optimize=none --specialize=off`
gives the reference code path; full debug also supports the default baseline
optimization. The compilation directory is recorded so relative source paths
can be found when GDB starts elsewhere. On Darwin select `--target=darwin-arm64`
and use native LLDB; [target contracts](../../docs/targets.md#native-source-debugging)
give its commands and artifact identity checks.

GDB uses its C-compatible expression and display rules for these values;
it does not parse Landin expressions. For example, inspect a pointer with
`print *pointer_param`. Variant displays expose a zero-based `tag` and named
case overlays at their actual physical offsets. Inspect the case selected by
the tag; the other overlays describe inactive storage.

D192 supersedes D186's string representation through those same seams:
checking owns the exact three-u32 struct contract and named-forward-only rule;
lowering constructs file_id, line and column through the ordinary aggregate
ABI. IR records only which source files have injected coordinates, and
`Landin.Source_Maps` renders their off-target filename table, or the complete
source table when full debugging is requested. The driver writes
it beside the output and passes its build identity to the linker. Flow and
reference checking use the checker-owned caller signature fact and resolution's
labelled positions; neither constructs source sites. No per-site datum or
filename enters the emitted runtime data.

A caller-using `--emit=exe -o app` also writes `app.sources.json`. Keep that
file with the build artifacts; it need not ship on the target. Read the
Linux executable's build ID with `readelf -n app`, then resolve recorded coordinates:

```sh
python3 scripts/source-location.py app.sources.json 1 42 9 --build-id HEX_ID
```

The resolver writes the original filesystem path bytes followed by ASCII
`:line:column` and a newline. It does not decode the path through the terminal
encoding; non-UTF-8 paths therefore survive even with strict UTF-8 stdout.

For `--emit=asm -o app.s`, use `app.s.sources.json` and `--assembly app.s`
instead. The assembly identity includes a comment binding its file map, even
when a source edit leaves the instructions unchanged. The decoder rejects a
missing or mismatched build identity and preserves arbitrary filesystem bytes.

Public specifications stay narrow, and a representation is private wherever a
caller could otherwise assemble a value the package would not have produced:
`Landin.Targets.Target_Facts` is private because a description must come from
a named target, not from a record literal that happens to describe the
development host. Where a type is limited, that is deliberate too: a
compilation cannot be copied out from under its stages.

The `darwin-arm64` description has 64-bit pointers, eight-byte pointer
alignment, sixteen-byte stack/scalar maximum alignment and little-endian
storage. Its Darwin AAPCS64 LP64 ABI identity is distinct from SysV AMD64.
A described ABI does not enable C signatures, C records, variadic calls,
assembly or debugging: each capability is explicit. R5.30 enables Darwin
C transport and assembly; R5.40 adds Mach-O DWARF and native LLDB acceptance.
R5.50 runs full shared hosted and derived-program parity on both targets.
Darwin scalar part addressing retains `IR.Element_Total` through target-byte
placement, including a field position beyond the Ada host `Natural` range.
The bounded emission regression preserves the existing physical-layout seam;
no semantic stage or source-debugging placement plan changes.
The checker asks capability queries; only the backend classifies ABI carriers.
`Landin.Backend.Dispatch` selects frame preflight and assembly emission, passing
neutral debug information to the concrete emitter. Toolchain arguments also
require the selected target, so a named tool cannot enable GNU arguments for
Darwin. The existing SysV classifier retains its runtime target guard.

Logical link names stay in checking and IR. `Targets.Capabilities.Link_Symbol`
adds Darwin's underscore before assembly quoting; ELF leaves the name intact.
Compiler-local labels are separate. `Landin.Hosted` supplies the exact helper
names to both checking and emission; each backend owns its libc dependencies
and physical signatures. See [target contracts](../../docs/targets.md).

A snapshot's bytes and line map are allocated once and not freed. A
compilation owns its sources for as long as it exists, the process is short,
and a compiler that frees source text while a diagnostic still points into it
has traded a leak for a dangling span. That is a decision, not an oversight;
when the roadmap needs a longer-lived process it will be revisited there. R1.50
extends it to the trees for the same reason, and to the four tables a
compilation now owns.

Frame and C argument-stack planning accept an explicit byte budget and check
addition and alignment before exceeding it. Only `Stack_Limit_Exceeded` becomes
the x86 preflight's frame-too-wide answer; allocation, shape and ABI defects
remain visible. The emission plan uses the same placement with the target's
normal limit.

Backend storage addresses require an actual frame home, including zero-byte
homes. DWARF whole-alias metadata validates array storage before querying its
shape. Register locations share one formatter: a direct binding resides in
the register, while an indirect binding resides at the address held there.
Address slots remain pinned by the current allocator. Initialized, in-scope
bindings remain available during return and failure preparation, including an
implicit return whose source anchor precedes the binding. Each terminal's
location range ends before any saved register is restored or the frame is
removed; following blocks cannot extend that range across an epilogue.

Symbolic type normalization retains proven incompatibility with C field
representation through aliases and arrays. Template validation uses those
negative facts to reject unavoidable C-layout errors while leaving unknown
fields for concrete instantiation. A pointer's own representation remains
independent of its referent's C compatibility.

Pointer metadata keeps nominal identity through nested arrays; it does not
require an opaque type's value layout. Accessing the pointee materializes that
layout before checking fields or element strides. Verification distinguishes
these identity edges from by-value bodies and checks any explicit body against
the canonical nominal shape. Debug output uses a DWARF declaration without
size or members for a type whose layout has not been materialized, and emits
the full description when the layout exists.

Reference checking retains the backing storage of match payloads and builtin
collection elements separately from references carried in their values.
Computed selectors preserve runtime-address aliases, and traversal captures
its array storage or slice base once. Element addresses and stores follow
that captured backing; returned-array temporaries, iterable results, text
scalars and index bindings keep frame storage. Nested payload aliases remain
subject to the same live-use checks as direct matches.

Early iterable headers use the exact declared concept signature while the
concrete provider table is still being prepared, sharing the query used by
erased-call typing. This supplies the Item and Cur types needed by local
inference without accessing an absent provider. Conformance validation still
checks every provider before lowering can consume the table.

Module discovery preserves the first directory spelling for reads and
source diagnostics. Before loading another selected directory, the driver
asks the platform whether it names an existing module's directory object.
Proven aliases share one module identity and one set of state; uncertain
identities stay separate. The target-neutral module table retains topology
and original paths without performing host queries.

Parser lookahead keeps a per-parse delimiter index and caches conformance
suffix decisions only outside nested delimiters. The index balances parentheses
and brackets independently, preserving the existing lookahead rules. Signature
queries reuse matching closes and unmatched openers stop conformance lookahead
without rescanning their tail. These heap-backed tables are proportional to
the token stream; this is not a general linear-time parser guarantee.

Generic instances preserve written range constraints when publishing local,
parameter and result types. Their signatures carry those bounds too, so
ordinary range checking covers generic stores and call boundaries. This does
not enable constrained types as generic actuals.

Owed runtime range checks belong to the active routine view. Unwritten views
inherit the global answer; instance writes preserve the global layer and other
instances. Repeating a constraint is idempotent, while a conflicting rewrite
within one view raises a compiler defect. Written range constraints remain
source facts shared across views.

Array-field element queries use the complete child shape, including nominal,
reference and nested-array identity. The former scalar-only field accessor,
which could expose a default `bool` for those children, has been removed.

A missing hosted entry reports L0502 at an active top-level `main` declaration
in the entry module when present, otherwise at the start of its first source
(including an empty file). Imported and local names do not supply that anchor.
The refusal still occurs before output writes or host-tool invocation.

Diagnostic text rendering reads at most a 160-byte window around each label,
with up to three extra bytes to preserve a UTF-8 boundary. Omission markers
identify clipped line ends, while locations and structured spans retain the
original byte coordinates. Within snippets, tabs display as `\t` and bytes
outside printable ASCII display as `\xNN`. Underlines count the characters in
these displayed forms, including spans inside a multi-byte sequence and points
at line end. This keeps snippets aligned for arbitrary source bytes without a
terminal-dependent Unicode width table. The complete rendered report defaults
to a 1 MiB text budget and ends with an explicit notice if truncated. This presentation
limit does not remove diagnostics, related labels or notes from the structured
report. Small explicit budgets let tests cover the same boundary without large
sources. The source layer exposes a terminator-free line span so rendering
never needs to copy an entire long line merely to select its excerpt.

Generic checking coalesces identical complete diagnostics from different instances
of one template. Instance-view transitions attribute each newly collected
report once, covering early discovery, nested instances and final body checks.
The comparison includes code, severity, primary and related labels, messages
and notes; distinct actual-type messages or source locations remain separate.
Ordinary checking and diagnostic transport retain their existing duplicate
policy. Failure unwinding restores the view without allocating diagnostic keys.

A compilation owns everything a stage builds that outlives the stage that built
it: the interned identities, the declaration sites, the trees, and what every
name in them means. Two facts about the seam decide that it has to be there
rather than in a stage. `Run` takes `Item` as an `in` parameter of a limited
interface, so a stage cannot keep anything in itself; and `Stage_Reference` is a
library-level access type, so a stage object cannot be a local of one
compilation either — `Append (Line, Local'Access)` on a local instance is
rejected as "non-local pointer cannot point to local object". The price is that
`Landin.Stages` gains one `with` clause per representation as the roadmap adds
them. The line that keeps it a seam is exact: this package may depend on a
representation and may never depend on a stage. Ada enforces that for the
specification only — a parent's spec may not `with` its own child — and a
parent's *body* may, so `landin-stages.adb` growing a `with
Landin.Stages.Syntax` to build a default pipeline is how the rule would
actually be broken. Nothing but the rule stops it, and `Landin.Driver` is
what owns the pipeline.

## The four long rows, in full

Four packages own an order of magnitude more than any other, and a table
cell is the wrong place to read a list that long.  Each is spelled out
here, one paragraph per package, in the words the table used to hold.

D213 distinct identities reuse the nominal inventory with one unnameable
representation child. `Landin.Checking` retains the exact base descriptor and
per-node conversion fact, including routine-instance overlays; the checker
alone authorizes construction or extraction. Lowering preserves the base
image and origins while native calls use aggregate storage. Admitted C bases
retain their selected-target C classification. A scalar atom image keeps its declaration
identity, checked against the field's atom set before the backend assigns a
runtime code.

**`Landin.Checking`** owns what type every runtime node and declaration has,
including concrete parameterized-alias application shapes and D136's canonical
folded array counts but no template/formal syntax metadata; D142's closed
compiler/source concept identities and concrete whole-program conformance
register keyed by normalized represented type, concept and input tuple,
retaining selected parameterized binders plus R2.70's declaration-ordered
provider runs, constrained-routine evidence runs and per-view evidence
selections, and D145/D146's exact any-concept, construction and
flattened-dispatch positions without physical layout; opaque checker-owned
nominal and routine instances interned by source template and an ordered
normalized scalar, structural atom-set, exact fixed-array, nominal, structural
function-signature or mathematical fixed-value actual tuple, with descriptor
keys bound to their limited compilation table and bounded typed traversal of
each stored tuple; routine-instance state publishes its substituted signature
before graph discovery and owns a complete source-node/declaration fact
overlay with global fallback plus caller-view generic-call targets, while
checker-owned per-instance signatures finalize inferred errors before body
checking; every enabled nonparameterized struct is its template's canonical
empty tuple, while D137's structs separate identity-only function/type-actual
mentions from by-value field/payload/array edges for both parameterized
instances and canonical empty-actual ordinary structs, following ordinary
nominal aliases without forcing layout; retain transient nonconcrete nominal
obligations for unused-template recursion checks, reconstruct interned
concrete bindings to promote nested nominal and nominal-array descriptors
lazily at value uses, and build one selected-target layout per canonical
instance without mutating their template; per-instance
unseen/building/ready/invalid layout state, with bounded invalid-layout replay
for each application-local diagnostic; structural atom/error sets, fixed-array
and anonymous result shapes, aggregate element identity, recursive first-class
target-neutral function signatures on values and aggregate fields, ordered
result runs, and target-dependent
scalar/fixed-array/unfolded-variant/recursively nested ordinary runtime layout
kept outside target-independent nominal keys; D188's range-subtype identities,
interned on the written range and carried beside a node's or declaration's
base integer kind rather than becoming one, with the check each value still
owes its destination.

**`Landin.IR`** owns the target-neutral instructions: items, slots, blocks and
values, including signature-only external routine items, D161's read-only
anonymous fixed-array datums and D177's canonical static bool images; R2.70
evidence descriptors with represented shapes, ordered routine/signature
entries, static table addresses and signed function-word loads, including
D147's direct and flattened erased table descriptors plus opaque-at-source
two-cell shaped any transport; a deterministic IR-owned nominal identity map
retaining each checker instance's source template without making an item;
atom-set descriptors, atom identities, orthogonal call-failure slots and
failure exits; recursive callable signature descriptors with ordered result
runs on declared or anonymous routines, static function datums, code
addresses, function-value slots, nominal aggregate storage, aggregate fields
and calls; scalar, compact fixed-array, unfolded variant, anonymous result and
recursively nested ordinary shapes carrying nominal child and element
identity; recursively indexed folded aggregate images, routine relocations and
compact child/payload segments; arbitrary-depth neutral paths through
contextual, variant and indexed-element operations; and checked internal
addresses for whole aggregate elements at computed indexes; D187's per-item
region depth and the one instruction flag it sets, which the verifier holds to
the opcodes carrying a removable edge; and D188's second checked integer
operation, whose operand and result types are identical and whose two folded
bounds the verifier holds to values that type holds.

**`Landin.Stages.Checking`** owns the three type passes, D142
concept/conformance collection, constrained concrete lookup, family collision
checking, D143's closed compiler `zeroable` predicate, R2.70 provider
finalization and `T.entry` evidence selection, D145--D147 any
identity/construction/object-safety/permission/dynamic-selection checking,
D161's contextual read-only byte-literal view, D181's canonical immutable
hosted-text identities, D182's exact `u32`/`core/text.position` utf8-index
selection, D183's identity-preserving utf8/utf16 range selection, D184's exact
immutable `u32` text-traversal Item, D185's ordinary binding check followed by
its exact-bool condition requirement, D178/D179's complete collection
traversal-element shapes and erased concept identity, D180's exact
named-`iterable` selection and copied Item identity for struct and `any C`
sources, compile-time-only positional substitution, D136's closed
target-independent fixed-expression evaluator,
scalar/fixed-array/nominal-aggregate normalization of parameterized aliases,
symbolic validation of unused nominal and routine templates, canonical
`(template, normalized actual tuple)` struct and routine interning, D138
context-free recursive structural direct-call deduction with deferred exact
computed-bound checks, per-instance substituted signatures/bodies and fact
views, per-instance inferred-error fixed-point nodes, one active-view
effective-call-signature lookup for inference/`try`/recovery, eager concrete
recovery-binding materialization before a recovery body is checked, same-key
recursion and finite-expansion refusal, identity-only versus value-layout
requirements for generic and ordinary signature recursion, ordinary
alias-chain identity lookup, transient symbolic nominal obligations across
used-formal wrappers, lazy recursive promotion from interned concrete actual
tuples, substituted per-instance layout, bounded repeated-invalid replay,
D137/L0313 by-value recursion separation, and checking-stage diagnostic order.

**`Landin.Stages.Lowering`** owns the walk that eagerly maps checker nominal,
conformance and ready routine-instance identities into deterministic IR order,
registers D161/D181's width-keyed content-pooled read-only text datums and
static slice or cstring relocations, lowers D182's utf8 ordinal scan and
checked direct position access, D183's retained-source UTF-8/UTF-16
boundary-checked ranges, D184's retained-source UTF-8/UTF-16/cstring scalar
traversal, and D185's stored condition bindings through ordinary
target-neutral CFG and scalar operations, passes hidden evidence tables,
builds direct plus used flattened erased tables, lowers selected generic and
any concept entries through ordinary indirect calls with injected data, then
builds and verifies the IR without creating items for templates or static
formals; including caller-owned scalar and shaped control joins,
temporary-first aggregate call/control results copied into nested or
runtime-addressed destinations, D178/D179's fixed-array, slice and `any`
element aliases, D180's one-time stored struct/`any C` sources and
declaration-ordered iterable calls with exact cursor and copied Item carriers,
one-time computed collection sources, checked computed-element address slots,
plus reverse-order cleanup calls on selected exits, D187's region depth around
a marked bare block and the required flag on every text boundary slice
address, and refusing to run on a refused program.

## What is deliberately absent

The detailed transport account below records the Linux implementation and
its R2–R4 decisions. Darwin now covers the same enabled hosted language;
its register, stack, C ABI and object contracts are described in
[target contracts](../../docs/targets.md). Neither native implementation
enables the deferred language or freestanding work owned by ROADMAP.md.

`Landin.Backend` lays out a routine's frame and
`Landin.Backend.X86_64` emits assembly for every operation in the enabled
kernel: scalar constants and arithmetic, expression-valued non-loop control
flow and calls; module and
local fixed-array indexing, copying, clearing and filling; and recursively
nested ordinary structs with scalar, fixed-array, ordinary-child and unfolded
variant fields, contextual construction, inspection, whole copies and clears,
and arbitrary-depth scalar, array, child, payload and known- and
computed-element paths. A computed whole aggregate element is bounds-checked
once and retained as an internal shaped address; it remains a
source value/place rather than exposing a pointer.
Folded module images recursively contain ordinary-child and ordinary-payload
images in a neutral descriptor tree; only the selected target supplies their
widths, offsets and padding. That is every
opcode `Landin.IR`
spells, so the case that dispatches them is exhaustive: a new opcode fails to
compile rather than raising `Compiler_Defect` at run time. R2.30's internal
scalar convention passes six arguments in registers and every later one in an
aligned run of eight-byte stack slots, so `L0503`'s former register-only limit
is retired. A flat ordinary-struct or fixed-array argument occupies one such
position as an internal address and is copied into independent shaped callee
storage before the body runs; a direct field or depth-one child path preserves
its neutral field identities on that address, contextual `zeroed` clears a
fresh shaped caller temporary, array literals or repetitions fill one in
source order with compact suffix fills, and flat struct construction fills one
by nominal scalar, fixed-array or variant labels. Variant-bearing storage and
constructed temporaries retain compact case and payload shapes across the copy;
a complete depth-one ordinary child and its literal construction retain their
nested field runs as well. Struct and fixed-array results use a hidden
destination pointing to caller-owned shaped storage and copy from an independent
named-result slot on leave; runtime evidence covers flat, variant-bearing and
depth-one nested struct shapes. Matching calls can fill typed locals, direct or
field-qualified assignments, and named returns without an aggregate SSA value;
a local can infer that returned nominal body or array shape as well. Aggregate
variant payloads use the same shaped-value writer: calls, distinct conversions,
control values and computed elements preserve the selected payload path without
requiring the expression itself to name storage. Calls can
also feed returned storage directly into a matching aggregate argument, or run
to completion in a shaped temporary before explicit discard. An `if`,
exhaustive `match`, or bare `begin` block can produce a scalar, fixed-array or
currently enabled aggregate value, or a function value with its recursive
signature. Explicit fallthrough and return facts make only continuing arms
fill one consumer-owned neutral join slot; returning arms use the ordinary
named-result exit, and no condition is believed. A typed binding, assignment
or return supplies storage directly, while an argument or discard owns a fresh
shaped temporary. Landin-convention aggregate argument and result contexts
use that internal convention. D203/D204's separate C signature facts instead
select SysV AMD64 LP64 classification: independent integer/SSE banks, complete
aggregate rollback to inline stack bytes, and C hidden-result storage. This
never repurposes the internal failure carrier as a C error channel.
Internal call emission and preflight share checked physical argument-count
arithmetic. Stack areas must fit the signed displacement encoding after final
alignment; incoming areas also reserve the saved-frame and return-address
prefix. This bounds internal calls as well as the separate C placement plan.
Inferred and explicitly typed local or module function values
are represented by target code addresses and called through verified
`Indirect_Call` IR. A first-class recursive neutral descriptor, not a concrete
callee item, carries each complete signature through checking, routine and
static-datum items, address values, slots and calls. Mutable replacement
requires an agreeing signature; function-valued parameters and named results
occupy one ordinary code-address carrier and share aggregate-result and
stack-argument conventions. Two or more signature results form one anonymous
structural aggregate: its ordered fields retain names for whole binding,
selection and by-name destructuring, while function-value agreement ignores
those labels and compares the ordered types. One hidden caller destination and
one callee result slot carry it through direct, indirect, early-return and
control-expression paths. Static module chains resolve to one declared or
anonymous routine address and have no implicit zero image. A no-capture
anonymous function sees the module and its own signature/body declarations,
lowers to a deterministic routine item and receives a backend-local symbol.
Function-valued ordinary and variant-payload fields retain that descriptor and
one `usize` carrier through construction, assignment, whole copies, nested and
indexed aggregate paths, caller-owned ABI storage and indirect calls. Static
aggregate images carry verified routine relocations, and a containing aggregate
has no implicit zero image when its active zero shape contains a function.
Atom declarations and
unions are structural declaration-identity sets carried as ordinary values.
D216 retains that metadata through generic keys, array elements, ordinary and
variant fields, static images, slice views and payload aliases. The IR verifier
requires exact sets on loads and member subsets on stores; an atom carrier
never supplies numeric type identity. D213 distinct identities use opaque
nominal descriptors with one unnameable representation child, preserving target
layout and origins without exposing source fields or inherited operations.
Conversion discovery preserves fixed-formal expression typing and contextual
literal inference instead of treating either as an ordinary initialized binding.
R4.90 closes inferred errors and generic discovery together (D215). Recovery
subtrees are separate syntax members, and deferred recovery/type facts belong to
the active routine-instance view. Only complete error components publish atom
sets that can enter generic keys; newly enabled handlers may discover further
instances before the final inventory assertion. The queue also retains recursive
expansion ancestry. Circular key/effect deduction is a source diagnostic, while
ordinary recursive effect graphs remain least-fixed-point inference.
The error finalizer's effect, requirement and call-edge matrices, plus its
signature/declaration flags, live in heap storage owned by one limited
controlled object. Normal completion, a suspended inference pass and partial
allocation or later exceptions release the same tables. Dense graph storage
still grows with program dimensions; it no longer reserves those matrices in
the host stack frame.

Concrete error sets are part of recursive function signatures; private `! ...`
routines, including separate concrete generic identities, are solved as one
whole-module least fixed point before lowering. Direct and indirect failing
calls keep their successful scalar, function or caller-
owned aggregate convention and add one neutral failure slot. `try`, `fail`, and
call-site `else` become explicit control edges, including recovery values and
exhaustive atom matches. Active deferred cleanups and failure-only undo entries
run in one lexical reverse order before a failure leaves their blocks; only
defer runs on normal and successful-return exits, and traps unwind neither.
Cleanup syntax retains the ordinary complete callee, so a selected function
field is evaluated late with its arguments. On
Linux x86-64 ordinary atoms use dense nonzero 32-bit
codes and the normal argument/`%eax` result positions; `%r10d` is the dedicated
error carrier, with zero meaning success. It consumes no source parameter or
result position. Completion into
an aggregate destination contributes an ordinary whole-place flow fact, so
branch joins and guarded-return edges require no call-specific exception. Each
early or final aggregate-result exit copies that complete independent slot to
the hidden caller destination.

What is reachable is the path around it. `--emit=asm` writes the assembly and
`--emit=exe` assembles and links it through the driver
`Landin.Backend.Toolchain` names, so a constant-return `main` runs and exits
with its own `code`. The assembly half is host-independent by the rule that
nothing outside `Landin.Targets` may ask the host anything: emitting for
`linux-x86-64` produces identical assembly text on macOS and on Linux. The finishing
half is not, and says so — a host without the target's triplet-prefixed
driver reports `L0500` rather than reaching for whatever `gcc` names, which
on macOS would hand ELF-only assembly to a toolchain that emits Mach-O.
The supported Linux finishing path is the triplet-selected GNU driver and
its assembler/linker. A named driver override must accept that target's
emitted assembly and argument conventions; selecting an executable does not
translate the assembly dialect. In particular, explicit ELF symbol names
beginning with `.L` remain permitted. Generated local labels choose a disjoint
prefix. The separately pinned Clang C-header frontend does not establish
LLVM assembler compatibility for every permitted ELF spelling.
Declared whole-program symbols keep their readable short spelling when it is
unique. Repeated short names across modules receive deterministic declaration
prefixes, as do non-external declarations named like one of the hosted
bridge's private libc dependencies. The selected `main`, C imports and public
C definitions retain their ABI spelling unless an explicit C symbol override
selects another; private C definitions without overrides keep collision-safe
internal names. Checking decodes and validates overrides and refuses
incompatible same-symbol declarations or multiple definitions. Thus an ordinary
lexer function named `open` cannot interpose on the bridge's call to libc `open`.

The `Runtime` fixture class compiles programs, links them, runs them on the
target and checks their statuses. The Linux gate therefore proves the scalar
arithmetic and non-loop expression-valued control-flow kernel, early returns,
lexical deferred and failure-only undo cleanup, declared atom errors and source
order, register/stack and recursive calls, folded module values, fixed arrays,
ordinary structs and their target-derived module and frame layouts on the
hardware the backend emits for. A host without the target toolchain fails
rather than silently skipping that evidence. The completed R2 items extended
the semantic and representation core; R5.50 establishes complete shared hosted
coverage on both native targets, within its recorded physical-image limits.

The native path sits behind the whole frontend: `refine` scans and parses every
`.ldn` file it is given, resolves every name in them as one module, collects
concepts and ordinary or parameterized conformances as one collision-checked
register, and checks the
type of everything and that every name is assigned before it is read, reports
what none of the four could read, lowers every function it accepted into
`Landin.IR`, verifies it and can dump it. Fully applied positional
parameterized aliases and structs are compile-time-only templates. Checking
substitutes type and fixed integer actuals, including a fixed formal passed to a
nested application. An alias records only the resulting ordinary scalar or
fixed-array descriptor; a struct interns D137's canonical nominal identity and
builds its selected-target field and variant layout only when a value site
requires one. Function-signature and type-actual normalization retain identity
without creating a by-value edge. Ordinary signature parameters and results
likewise use a struct's preallocated empty-actual identity through aliases, so
self and mutual signature-only recursion never enters the ordinary layout
recursion guard; routine ABI positions request any needed concrete layout when
checking the body, with direct multiple results materialized before their
caller-owned aggregate is placed. Substituting a generic descriptor at a value use
reconstructs its canonical binding and recursively materializes nested nominal
or nominal-array layout there, including D18 checks. Symbolic declaration
validation retains a checker-local template and binding obligation for a
nonconcrete identity, follows it only when another template uses that formal by
value, and interns no guessed instance. It rejects invalid free names,
decidable fixed-formal/result or field shapes, duplicate labels, unconditional
expansion cycles and impossible by-value nominal recursion in an unused
template. Concrete instances use the
same contextual aggregate storage, images, calls and control paths as ordinary
structs. D138 direct generic calls instead intern one checker routine identity per
complete normalized tuple. A direct generic call either deduces every static
formal from positional runtime arguments or names every static formal in the
same named call list; static entries have no evaluation, IR value or ABI
position. The checker recursively unifies each runtime parameter's written type with the
independently synthesized argument descriptor. Direct type formals bind every
enabled normalized descriptor: scalar, structural atom set, exact fixed array,
nominal aggregate identity, or structural function signature whose error set is
already concrete. Fixed-array patterns recurse through exact bounds and
elements; a direct fixed bound binds its length, while a computed bound is never
inverted and is folded only after another relation or an explicit tuple binds
its formals. Parameterized nominal patterns require the same source template and
match the complete stored tuple, including phantom actuals. Parameterized alias
patterns expand symbolically, and function patterns recurse through ordered
parts and error forms while ignoring labels. One checked descriptor-to-signature
conversion preserves a fixed array's nominal element identity even at length
zero, and the public signature seam rejects malformed descriptor combinations.
Repeated relations agree exactly;
a saturated explicit tuple binds nothing and validates every pattern. Each
identity owns a layered view of the original source nodes and declarations,
publishes its substituted signature before its body, and records generic call
targets in the caller's view. A concrete declared atom error set is carried by that instance signature
through ordinary call, recovery, propagation, failure and cleanup paths. For
private `! ...`, each identity first publishes an inferred signature and then
contributes the shared body's direct failures and per-view call targets to the
same deterministic graph as ordinary routines. Finalization mutates only that
checker-owned signature: empty becomes infallible, nonempty becomes concrete,
and a named recovery binding is settled in the matching instance overlay.
Same-key direct or mutual recursion reuses the building identity; different
keys and templates keep distinct graph nodes. A different tuple of the same
active template is still refused as non-finite expansion. Lowering activates
each ready view and emits one deterministic local routine item carrying only
the finalized concrete error descriptor. Templates and static formals create no
IR, slot or ABI position, no generic error opcode exists, and no
instantiation-specific answer is written to syntax.

A width is a function of a type and a target description, never a property of
either alone, and `Landin.Types.Width` is the only place one is formed.
`usize` is [0160]'s pointer-width integer, so it is as wide as
`Landin.Targets.Pointer_Width` says and no wider — which is how a 32-bit
target description stays 32-bit on a 64-bit host. A literal's value is held in
`Landin.Types.Magnitude`, whose bound is written out as `2 ** 64 - 1` because
that is a fact about `u64`; a host width leaking in would be
`Long_Long_Integer`, whose range is a fact about the machine running the
compiler.
`L0001` is retired — the catalogue said it retires when the frontend is wired
to the driver, and R1.40 is where that happened — and its row stays so its
number is never handed to another rule.

Both halves are held to the grammar from both sides. `check.py` compares
`Landin.Tokens`' reserved words with `spec.md`'s own `keyword` production,
derives every positive program in the corpus from the grammar and refuses
every negative one the frontend rejects, and compares
`Landin.Syntax.Precedence` with [1820]'s own
levels, operators, fold and first sets. The harness lexes every program in the
corpus and compares each token with what `check.py`'s independent tokeniser
produced, parses every one and requires the same verdict `check.py` reached,
parses every truncation of every one, mutates every corpus program by byte
insertion, deletion and replacement, and parses fixed-seed raw byte streams.
Each must yield a tree whose invariants hold rather than a crash.

`Landin.Syntax` is a flat table, not a pointer structure: a `Node_Id` is a
dense integer, so R1.50's names, R1.60's types and R1.70's values each go in
an array of their own rather than a map keyed on an access value. R1.50 is the
first to take that up, and it does it once for the whole compilation: one array
of `Declaration_Id` with one run per source and a first index, which is what
`Landin.Syntax` already does with a node's children. A child's
index is lower than its parent's and a child's extent lies inside it, both as
postconditions. A construct the parser could not read becomes an error node of
the band it needed — one per band, so a case over a band still covers the
hole — and `Is_Sound` propagates upward so that one syntax mistake does not
become a cascade of type errors about a hole. Trees live in the compilation's
`Landin.Syntax.Forest`, one per source and none freed, which is R1.50's answer
to where they live: a tree cannot be an element of a container, because it is
limited with unknown discriminants, and an initialised allocator whose value is
the parse is the one form Ada gives for building one where it will outlive the
call.

A diagnostic code is written in exactly one place, `Landin.Diagnostics.Catalogue`, and `check.py` refuses a code literal anywhere else in `src/`. Each column of the catalogue is an exhaustive case over the code names, so a code with no row is a missing-case error rather than a warning. The catalogue holds no prose: `L0003` is raised with two sentences, for a source that is missing and one that cannot be read, because one rule was violated and the difference between them is wording. What a code requires of every occurrence — a source, a non-empty span, how many secondary labels, how many notes — is in the row, and `Landin.Diagnostics.Lexical` checks the row against the diagnostic it just built.

The scanner's former deferred-token band is historical. Floats, characters,
raw text and compound assignment are enabled; D164 removed its final family.
`Landin.Tokens.Text` validates literal spelling and encoding. Named refusals
under [1830] belong to parser/checker tables for still-deferred constructs,
not a lexical band. L0010 is parser-only; numeric code bands do not determine
which stage owns a diagnostic.

Loop-transfer origin states have limited controlled owners in the reference
checker. The loop vector borrows lexical frame addresses; growing it copies no
owned state. Completion moves a state without allocation and clears its former
owner. Exceptional exits finalize each owner. A checker-instance test probe
injects bounded failures at ownership/traversal boundaries; ordinary compiler
instances have no probe. This repair does not change declaration-by-field
storage growth or claim recovery from arbitrary host exhaustion.

The parser recognises [0890]'s `noreturn` return position as a distinct
return form (D231). Checking and IR retain its infallible signature identity
through generic and evidence calls, and flow removes its continuation.
The spelling remains an ordinary identifier outside the return position.
D232 validates an entry-module `panic_handler` against `core/panic` before any
output. Checked backend edges transport two ordinary scalar arguments; the
handler's private reentry latch prevents recursive reporting. `--panic-map`
adds byte ranges and line offsets to the existing build-bound source map.
Neither that map nor source filenames enter a default constrained image.
Private startup/host-root guards use site zero, and hardware/naked obligations
remain distinct. All targets preserve the default terminal trap instructions.

The stage seam is one interface and one pipeline, contract-tested with fake
stages. Named per-stage packages arrive as each stage is written, which is
what keeps the seam a seam rather than an empty directory tree with
aspirational names in it.

## Building

The stages remain Ada 2022. The host-only C adapter
`src/platform/landin_file_identity.c`, compares the host headers' `struct stat`
identities without transcribing Darwin and Linux structure layouts into Ada.
`Landin.Platform.Native.Paths_Overlap` combines it with canonical path lookup
for report/source/artifact preflight, including hard links, symbolic links and
not-yet-created output leaves. An unresolved identity is refused conservatively;
this does not protect against concurrent filesystem replacement. No host
identity operation determines Landin target layout or emits program code.
The separate `Same_File` query answers true only for existing host objects
with matching identity. Explicit source arguments load each proven object
once, retaining its first successful spelling and snapshot for diagnostics.
Unknown identity still reads and reports normally; equal bytes in distinct
files do not merge declarations. Rooted module ownership remains separate.
Native byte reads and writes report expected name, permission/use and device
failures as ordinary outcomes. Cleanup retains those outcomes without masking
programming or resource exceptions. A tool capture that cannot be read raises
`External_Tool_Failed` through the adapter's owned cleanup path.
`src/platform/landin_tool_process.c` owns POSIX spawn attributes and wait/signal
constants. `Native.Tools` passes the already-open capture descriptors and
literal argument vector. Merged capture retains one ordered byte stream;
`Output_Only` retains stdout in `Output` and stderr in `Error_Output`, so the
harness can enforce both expected stdout and empty stderr. Both temporary
files share the owned cleanup path. The adapter starts each tool in its own
process group and uses a monotonic deadline. On timeout it kills that group and reaps the direct child
before reporting `Timed_Out`; adapter exceptions also stop an owned child.
The group is established before execution through
[POSIX spawn attributes](https://pubs.opengroup.org/onlinepubs/007904975/functions/posix_spawn.html).
Descendants that deliberately leave the group are outside this supervision
contract. The focused native tests use a short-lived child and delayed marker,
and preserve exit/signal distinctions, argument bytes and capture modes.
The shared project builds both adapters with warnings as errors; source checksums
include C sources and headers as well as Ada sources.

See `TOOLCHAIN.md`. From the repository root:

```sh
./scripts/build.sh
./scripts/test.sh
```

On the Mac use `./scripts/test.sh --host`; the unqualified suite includes
Linux workload cases and is not the Mac compiler-host command.

`scripts/dev-build.sh` uses GPRbuild checksum recompilation for the edit loop,
and `scripts/dev-test.sh` accepts an exact `--suite`, `--case`, or `--fixture`
selector. On the Mac add `--host`; run Linux workloads in native development
slots. Filtered runs identify themselves and never replace exact-revision
acceptance. [The process guide](../../docs/process.md) explains both native
policies, debugger selection and Linux-only resume.

Darwin uses the shared DWARF encoder with x29-relative stack locations and
Apple section/CFI conventions. Full executable output retains its object and
packages a dSYM through the selected Apple driver. The native UUID and full
Landin source/assembly digest bind the executable, dSYM and optional source map.
See [target contracts](../../docs/targets.md#native-source-debugging) for native
commands, identity matching and the demonstrated debugger presentation limits.

R6.10's [Cortex-M environment probes](../../environments/cortex-m/README.md)
are separate C/assembly controls for QEMU and a synthetic Renode device lane.
R6.20 adds `Targets.Cortex_M` and `Backend.Arm32_ABI` layout/transport planning,
with independent executable controls under that environment. The existing
neutral shape machinery supplies storage. R6.50 adds `Backend.Cortex_M` assembly
emission and compiler-generated QEMU/Renode execution. `--target=cortex-m0`
accepts checking, `--emit=asm` and D229 firmware linking with explicit
`--firmware-entry=NAME`. General C source and Landin source debugging remain
refused. `Backend.Firmware` owns reset/script generation; the older external
startup/linker probes remain independently identified test harnesses. See
[target contracts](../../docs/targets.md#cortex-m0-layout-and-abi-planning).

R6.30's `Landin.Memory` owns the neutral operation/order vocabulary.
`Configuration` recognizes the exact compiler member syntax; resolution visits
runtime operands and checking validates fixed orders, pointer permission,
unsigned scalar identity and target capability. `IR.Memory_Access` retains
that contract through verification and optimization. Native backends implement
scalar atomics/volatile access and barriers. Cortex-M implements admitted
one-, two- and four-byte loads/stores and barriers, retaining alignment checks
and refusing RMW/eight-byte memory intrinsics. The [target guide](../../docs/targets.md#explicit-memory-operations)
records actual instruction requirements. Packed/register/volatile-pointer type
syntax and the ordinary CPU/cache modules retain their separate R6 owners.

R6.40 uses `Landin.Packed` for unsigned image algebra and access planning,
`Targets.Packed` for target storage/capability queries, and syntax/checking for
encoded unions and explicit packed positions. Neutral shapes retain geometry
and encoding tables through verification and optimization. Native backends
implement checked extraction/insertion and raw aggregate copies; the DWARF
consumer exposes the raw carrier. Explicit register-image intrinsics use the
existing volatile IR boundary with retained reserved-bit guards. General
register wrappers remain deferred; the Cortex emitter preserves the same raw
image and validation contracts. ROADMAP.md owns the
remaining audits, evidence and closure obligations.

The native debugger gates include a D231/D232 program that enters a selected
handler through erased evidence and a generic nonreturning callback. Source
breakpoints, values, operation sites and unwind frames execute under GDB/LLDB
at three profiles. Darwin out-of-line panic edges carry their originating
source line; this does not enable Cortex source debugging.

R6.80's [device modules](../../devices/README.md) use the existing frontend,
packed/volatile IR and Cortex firmware path without compiler changes. Vendor
metadata is off target; the compiler does not parse SVD or run generators.
