# The Ada bootstrap compiler

This directory holds `refine`, the Ada bootstrap compiler for the language
`spec.md` defines. It is a real compiler under construction, not a
prototype: `spec.md` is the normative language specification and `tour.md`
explains the language, and nothing here may quietly decide language
semantics.

Start with [the layout](#layout) for where each stage lives, then
[package ownership](#package-ownership) for what each package may and may
not do, and [building](#building) for the commands. For the intermediate
representation and the reasons for its structure, read
[the IR guide](../../docs/ir.md), a maintained, non-authoritative account
derived from the implementation and its tests, and for each target's
frames, calls and images [the target contracts](../../docs/targets.md).

`D248` names a decision recorded in `spec.md`, and `[1975]` a numbered
paragraph of `tour.md` or `spec.md`; `refine explain D248` prints either.

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
    formatting/         the one layout of a source, as edits
    devices/            a device's SVD and its policy, projected onto Landin
    bindings/           C headers bound for Landin from what Clang says of them
    driver/             request/results, source maps and report provenance
    server/             the language server, its stand-in, positions and protocol
    main/               the `refine` entry point
  tests/src/            the harness, the fakes and the suites
```

The build generates `Landin.Build_Identity` under its ignored generated-source
directory. `scripts/build_identity.py` supplies the exact release tag, revision,
compiler-input digest, dirty state and build mode; the host triplet comes from
`Landin.Targets.Selection`. Release identity comes only from an exact numeric
`v` tag on HEAD, independently of optimization mode. More than one such tag is
refused. Tracked edits throughout the checkout and untracked compiler inputs
mark it dirty; ignored generated outputs do not. The digest remains restricted
to compiler inputs. A source archive without Git metadata has an unknown
revision and no assigned release. The identity carries no checkout path or
wall-clock time. `refine version` renders a concise banner, and its `--json`
form retains the full provenance with a release `version` or `null`.

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
| `Landin.Hosted` | the one hosted name the compiler owns: the argument initializer a hosted entry calls, shared by checking and emission | encode target prefixes, libc names or machine signatures |
| `Landin.Packed` | bounded raw-image masks, field/index algebra, encoding membership and explicit register access plans | access hardware, validate source values or infer optimizer facts |
| `Landin.Machine` | source machine conventions and checked placement metadata | infer target widths, perform host effects or reinterpret a calling convention |
| `Landin.Memory` | D227 memory operation identities and ordering legality | select instructions, infer aliases or choose a target |
| `Landin.Layouts` | source representation policy names | place fields or derive target widths |
| `Landin.Optimization` | optimization objectives, specialization modes and their request spellings | change source meaning or disable runtime checks |
| `Landin.Serials` | process-unique identities for trees and checking tables, so a stale key or tree is refused rather than matched by a reused address | reach output, numbering or iteration order |
| `Landin.Build_Reports` | deterministic compiler decisions, outcomes and work counts | claim assembled-byte measurements or diagnose source |
| `Landin.Json` | reading a protocol message as strict RFC 8259 JSON, bounded in depth and never raising; the same reader with a deeper bound for a tool's own output, such as Clang's AST; and writing canonical JSON | convert a floating-point number, accept a duplicate key or invalid UTF-8, or write a build report or source map |
| `Landin.Xml` | reading a vendor's file as strict well-formed XML 1.0 in the subset an SVD is written in, bounded in depth and never raising, its refusals placed by line and column (D555) | read a document type declaration or an entity it declares, accept bytes that are not UTF-8, or write XML |
| `Landin.Source` | immutable snapshots, byte offsets, spans, line maps | read a file, or know an encoding beyond bytes |
| `Landin.Source` storage | heap-allocated text and line maps, owned and freed by their snapshot, which is limited and handed out by reference | put a source file in an automatic object, or copy a snapshot |
| `Landin.Source.Sets` | a compilation's snapshots and their identities | acquire bytes from a host |
| `Landin.Provenance` | origins and the declaration side table | know what a declaration means |
| `Landin.Debugging` | optional source snapshots, source result labels and compilation-directory context, with access to immutable declaration syntax | copy represented types/layouts, read the host or encode a debugger file format |
| `Landin.Source.Names` | identities for the byte runs a program names | know that a spelling is reserved |
| `Landin.Tokens` | the lexical vocabulary, the token, the fault, the stream, and the space the stream keeps beside its tokens: blanks, line ends and the three comment forms, found by offset | render prose, assign a diagnostic code, or build a token |
| `Landin.Tokens.Lexer` | the scan, the only construction of a token or a piece of space, which together cover every byte of the file, and D161's validation of complete text-literal spelling and [1750]'s comment encoding | know what a token means or decide its contextual text view |
| `Landin.Tokens.Spacing` | every source's space for the whole compilation, keyed by source and freed with the table | be read by anything that decides what a program means, or keep a token |
| `Landin.Tokens.Text` | D161/D181's shared UTF-8 validation for literals and comments, and byte, UTF-8 and UTF-16 literal decoder | diagnose, choose a literal context, or own emitted storage |
| `Landin.Syntax` | the node table, extents, anchors, origins, soundness, and the retained independent C-convention, variadic, bodyless-import, visibility, C-layout and symbol-literal facts, and D233's fact that a later shared name reuses its first name's type, `at` and `from` nodes | know that types or IR values exist, or hold a diagnostic |
| `Landin.Syntax.Precedence` | [1820] as data: levels, operators, folds, first sets | contain a parsing decision |
| `Landin.Syntax.Parser` | the parse and the only construction of a tree, read by the grammar alone first and with D260's recovery only when that reading has something to report (D1074); its contextual decisions: a final `try` expression apart from a `try` statement with more body items after it, the initialized condition binding (D185), the caller parameter (D186), the two-token `unchecked` region (D187), one declaration node per shared name (D233), and contextual-name bindings and assignments, told apart by their punctuation before control words are dispatched | assign a diagnostic code, or read a byte |
| `Landin.Syntax.Repairs` | D261's smallest change that mends a refused statement: its own scan and parse of one line, and of the routine that holds it, each as a local, the routine only for its first refused line (D1076), and the report restated as that change | decide what a program means, keep anything past the call, or try a line outside a routine body |
| `Landin.Syntax.Dump` | a canonical text for a tree | be a stable interface or a serialisation |
| `Landin.Syntax.Forest` | one tree per source for the whole compilation, on the heap and freed with the forest | hand out a tree that can be copied, written to or kept past the forest |
| `Landin.Formatting` | D252's layout of one source's bytes: the scan and the parse as locals, the edits that take the source to the layout, a re-scan that the edits changed no token and no comment, and D359's account of each line the edits change | read anything later than the parse, keep anything past the call, break or join a line, or write a file |
| `Landin.Modules` | the deterministic reached graph: module identities, selected directories/root ordinals, source membership and resolved import edges | read the host, parse source, own a scope or depend on a stage |
| `Landin.Modules.Availability` | source namespace availability from target facts, independent of root selection | read the host, resolve imports, enable an ABI or select runtime authority |
| `Landin.Resolution` | declarations, scopes, which declaration each name means and which declaration each declaring node made, and the fields and fill of a construction as it classified them | hold a diagnostic, or decide what a name may be called |
| `Landin.Types` | the scalar names and value categories, their widths, and ordinary scalar storage size against a target | hold a machine fact of its own, or ask the host for one |
| `Landin.Evidence` | target-neutral semantic evidence-table positions: size, alignment, then direct concept functions in declaration order | know machine bytes, target offsets, or physical layout |
| `Landin.Checking` | the type of every runtime node and declaration, the concept and conformance table, interned nominal and routine instances with their per-instance facts and layouts, and D188's range-subtype identities; the full list is under "What the four largest packages own" below | decide a rule, execute user code, synthesize a source declaration, mutate a template, or ask the host for a width |
| `Landin.Checking.Spelling` | how a checked type is written for a person: the one spelling the checker interns for a pointer union and a server shows over a name | decide a type, or spell one a second way |
| `Landin.Cleanup` | target-neutral exit kinds and the defer/undo applicability policy | parse a cleanup, track definite assignment, emit a call, or name a target |
| `Landin.IR` | the target-neutral instructions, shapes, descriptors, images, paths and source aliases into existing storage; the full list is under "What the four largest packages own" below | hold a scope tree, name a machine, ask a width, synthesize a declaration, or hold an offset, register or padding byte |
| `Landin.IR.Control_Flow` | linear-space adjacency and entry reachability of structurally checked IR | assume reachability or store represented object bytes |
| `Landin.IR.If_Conversion` | under size and speed, D338's proof that neither arm of a two-armed `if` can trap, call or touch anything but a private slot, or that its one trapping operation is a checked update `x = x + k` the other arm leaves alone, and the rewrite of its branch to choices and stores | speculate a trap, a call, a memory access or a store outside a private slot, or convert at `--optimize none` |
| `Landin.IR.In_Place` | under size and speed, the proof that a callee cannot tell its `in` aggregate from its caller's storage (D94, D95), with a whole-unit summary of which routines may write outside their frame; the rewrite to an address parameter whose home a zero carrier clears; and dropping a caller's slice or `any` temporary that nothing can change before its call | revise the convention, read a parameter in place across a possible write outside the frame, or touch a C or machine-convention entry |
| `Landin.IR.Inlining` | D339's copies, at speed only: which direct calls are copied into their callers, the copy of each body with its arguments stored into copied parameters, its returns and failures rejoining the caller, values that cross it carried in slots, and each copied block, slot and alias recording the call it came from | copy a routine whose address is taken, copy a copy's own calls, change a trap's site or order, grow a routine past its bound, or run for a firmware target |
| `Landin.IR.Dominance` | a routine's dominator tree from its control-flow graph, in O(E log V) work and linear space, with constant-time dominance questions | assume reachability, or say what holds in a block |
| `Landin.IR.Liveness` | each slot's live interval over the laid-out order of a routine's values, in work bounded linearly in the routine, and each block's loop depth | choose a location, a register or which slots one may hold |
| `Landin.Panics` | canonical entry-hook validation, source-byte site spaces, final nonzero atom codes, and the text of D361's hosted default report for a site | a runtime reporting library, allocation in an image, or how a backend writes the report |
| `Landin.Backend.Trap_Reports` | D361's distinct report lines in the order a backend meets them, and their assembler string spelling | decide a line's text, choose a section or write to a stream |
| `Landin.IR.Effects` | conservative opcode effects and policy weights, including observable traps | infer alias permissions from unchecked regions |
| `Landin.IR.Pipeline` | the optimization passes `refine compile` runs between lowering and emission, in its order, for the driver and for any test that inspects emitted code | choose what a pass does, or emit |
| `Landin.IR.Rewriting` | shared arena compaction for verified transforms | change slot, signature, shape, image or semantic instance identities |
| `Landin.IR.Scalar_Replacement` | splitting small scalar-part slots into one scalar slot per part, as simplification's first step and verified with its output: at speed, entry copies of the parameter parts a loop reads, rewritten part accesses, whole copies and clears, and the piece record a debugger reads | split a slot whose address is taken, a partial copy, a routine result or a part whose load checks, or move a trap |
| `Landin.IR.Scratch_Arrays` | the optimization passes' scratch arrays: on the heap, sized by the unit, filled in place and freed on any exit | place a unit-proportional array or its initializer on the host stack |
| `Landin.IR.Shape_Measurement` | memoized represented extents under target facts and an explicit size limit | choose machine placement or allocate work per represented array element |
| `Landin.IR.Simplification` | verified simplification under the selected objective: local rewrites, reads of immutable module values as their images, and checks a dominating comparison, a type's range or a passed check proves | reassociate floating arithmetic, create cross-block values, or infer a fact or alias from an unchecked region |
| `Landin.IR.Specialization` | whole-program static-evidence devirtualization with retained instance entries and indirect fallbacks | create semantic instances or specialize exposed or unknown entries without proof |
| `Landin.IR.Specialization_Policy` | bounded benefit and profitability estimates | claim assembled-byte costs or depend on host word width |
| `Landin.IR.Verifier` | release-build well-formedness of a completed Unit, including atom/error set membership, descriptor/carrier, multiple-result slot and static function-image agreement, call-failure slots and exits, valid neutral subobject paths and recursive image descriptors, plus target-aware fit of every static fold | diagnose source, repair malformed IR, or choose backend policy |
| `Landin.IR.Dump` | canonical human-readable text for a Unit | be a stable interface, a reader, or a serialisation |
| `Landin.Backend` | where a routine's cells live, an extent no frame a backend plans for a routine exceeds, which frame preflight answers from, the recursive target extent of one neutral field shape, where a scalar or fixed-array leaf at any path depth sits inside an aggregate datum or slot, how wide one element of an array of either is, the target-byte replay of scalar, fixed-array and unfolded variant runs, each atom's dense code, how many items hold each linker spelling, which indirect access an indexed address folds into, and D536's one form for a run in a static image | name a machine, choose a register, or ask the host a width |
| `Landin.Backend.Work_Arrays` | heap-owned backend scratch with lexical exception-safe reclamation | place instruction-proportional arrays on the host stack |
| `Landin.Backend.Reciprocals` | the multiplier, shift and 65-bit correction that divide every dividend of one width by one known divisor that is neither zero nor a power of two | choose instructions or registers, or ask the host a width |
| `Landin.Backend.C_ABI` | SysV AMD64 classification and one call/entry/result placement plan from target facts and neutral shapes, including independent GP/SSE banks and aggregate rollback | ask the host for layout, put register placements in IR, or change the internal Landin ABI |
| `Landin.Backend.Arm32_ABI` | Cortex-M AAPCS32 argument/result planning, at the base PCS and D616's VFP variant, and the internal Landin convention's, from neutral signatures | emit instructions, enable C source capability or infer ABI from pointer width |
| `Landin.Backend.Cortex_M` | Cortex-M instruction selection at every level, reusable stack homes, frames, internal and C calls, C records copied by value into and out of the registers and outgoing area Arm32_ABI plans (D920), checked operations, ELF assembly and line/function CFI from verified IR | change language semantics, enable a C capability, own language startup/linking or promise full variable/type debugging |
| `Landin.Backend.AAPCS64_ABI` | arm64 C classification and argument/result placement from neutral shapes and target facts, under the standard AAPCS64 or Apple's variant of it as the description's C ABI says | infer layout from the host, choose a convention by architecture, reuse SysV transport or change source semantics |
| `Landin.Backend.RiscV_ABI` | explicit LP64D C carrier classification and register/stack placement from neutral shapes and target layout, including mixed FP/integer aggregates, split carriers and variadic integer transport | infer the selected ABI from LP64 widths, put transport in IR or access the host |
| `Landin.Backend.RiscV` | RV64 and RV32 instruction selection, stack homes, frame records, native and LP64D calls, the hosted entry's initializer call and ELF data images from verified IR | parse/check source, put physical transport in IR, access files or run tools |
| `Landin.Backend.RiscV_Instructions` | native XLEN-parametric integer immediate, memory and indexed-address instruction selection, with independent Zba and XTheadBa capabilities | infer a width from the host, rank extension sets, choose an ABI, access files or invoke tools |
| `Landin.Backend.Arm64` | arm64 instruction selection, stack homes, frame records, native/C calls, the hosted entry's initializer call and data images, for every arm64 description | parse/check source, put physical transport in IR, spell an object format's directives, write files or run tools |
| `Landin.Backend.Arm64.Platform` | what arm64 assembly spells per object format: page relocations, read-only sections, symbol types and sizes, the local-label seed and the unit's trailer | select instructions, choose a C convention or name a libc function |
| `Landin.Backend.Arm64.Selection` | which constants an arm64 instruction can carry, the move-wide lines for any pattern, the shift, mask or reciprocal sequence that divides by a known divisor, and the scratch registers selection writes, which allocation leaves alone | read IR, choose a location or ask the host a width |
| `Landin.Backend.ELF` | the ELF directive spellings every ELF backend shares: symbol types and sizes, the read-only, relocated read-only, data and zero sections, the panic flag's section and the non-executable stack note | own a backend's line discipline, choose which section a datum belongs in, or spell ARM's `%` section types |
| `Landin.Backend.Dispatch` | backend selection for frame preflight and assembly/debug emission | choose language semantics or discover host tools |
| `Landin.Backend.Xtensa` | windowed Xtensa emission from verified IR: frames, the bank of memory words each routine's logical words live in, integer ABI carriers and every IR operation, written as RISC-V-form logical instructions that `Xtensa_Machine` selects as they are written | parse or check source, keep a logical instruction in its output, access files or run tools |
| `Landin.Backend.Xtensa_Machine` | the Xtensa instructions for each logical instruction: every word read from and written to its home at a7 + 4×N, or held in a2-a6 in a routine without assembly, through the transient a8-a13; CALL8 and CALLX8 calls; and shortening a local jump proved in range | define language semantics, alias a word that has no home, or execute bytecode |
| `Landin.Backend.X86_64` | the assembly text for one target, every register in it, collision-safe whole-program symbols, the hosted entry's initializer call, D161's read-only literal data, the target-width scalar, finite-array, compact repetition, nested-child and selected-variant directives and padding for recursively written aggregate images, and D187's omission of exactly the overflow, element-index, slice-range and integer-conversion edges an instruction is marked for | decide a language error mapping, write a file, or run a tool |
| `Landin.Backend.X86_64.Allocation` | deterministic stack homes, the five available SysV callee-save GP registers, slots' registers over their live intervals, and the four caller-saved registers selection leaves alone between two operations | give a location a register selection writes inside its interval, or allocate failure registers |
| `Landin.Backend.X86_64.Machine` | selected instruction counts and optional canonical body-equivalence evidence | canonicalize external symbols as local labels or equate counts with assembled bytes |
| `Landin.Backend.Site_Counts` | the build report's static instruction, stack-traffic and call sites in an arm64, RISC-V or Thumb routine's final text, following the registers it sets from its stack or frame pointer | select, rewrite or assemble an instruction, or equate a count with assembled bytes |
| `Landin.Backend.Debug_Locations` | format-independent lexical visibility and definite initialization at IR instruction boundaries | choose storage, encode debugger records or read the host |
| `Landin.Backend.Dwarf` | shared DWARF type/scope/location encoding parameterized by backend placement and section policy | change language types, choose variable storage, read the host or write files |
| `Landin.Backend.X86_64.Dwarf` | x86 allocation adapter, register encodings and ELF entry points for the shared DWARF encoder | change source facts or choose variable storage |
| `Landin.Backend.Toolchain` | target-specific assembly, link and debug-bundle command arguments, the triplet they use, D364's ordered driver candidates and what to install when none is found, and D202's ordered library arguments with D524's directories, firmware's as static archives (D923) | infer target policy from the host, invoke a tool directly, or search a PATH |
| `Landin.Backend.Firmware` | compiler-owned reset text and the linker script derived from the selected profile's regions, placements and boot kind (D545), keeping a C archive's constructors where the driver sees them (D924) | perform host effects or initialize user modules by executing source code |
| `Landin.Backend.Images` | D537's one pre-emission measure of a unit's written, mutable and zero images against a budget the caller selects, and its refusal's message | choose a target's or a profile's budget, read a profile's capacities as constants, or ask the host's width |
| `Landin.Backend.Entry_Point` | [1970]'s one hosted entry shape, asked of the IR | raise a defect for a module that simply has no `main` |
| `Landin.Diagnostics` | codes, severities, labels, notes, fixes and their edits, ordering | render, apply a fix, or own the catalogue of codes |
| `Landin.Diagnostics.Fixes` | the one constructor and sentence of each kind of fix, and whether it is exact or likely | decide which names a position could mean, or where a fix may appear |
| `Landin.Diagnostics.Suggestions` | [1860]'s nearness: the distance, its bound and the deterministic order of the names a stage offers | choose candidates, or offer one out of scope or inaccessible |
| `Landin.Diagnostics.Modules` | catalogue diagnostics for rooted module discovery failures | perform filesystem discovery or invent diagnostic codes |
| `Landin.Diagnostics.Text` | deterministic rendering, sharing a primary snippet with its first related label only when source and complete span agree | decide severity or ordering policy |
| `Landin.Diagnostics.Catalogue` | every diagnostic code, and what each requires of its occurrences | hold a message, or a code nothing raises |
| `Landin.Diagnostics.Warning_Policy` | catalogued warning selection and ordered invocation overrides, preserving diagnostic data when denied | change language legality, suppress an error or perform host effects |
| `Landin.Diagnostics.Explanations` | what `refine explain` prints for each code, generated from `docs/diagnostics.md` | be edited by hand, or say anything the page does not |
| `Landin.Diagnostics.Citations` | each construct's and decision's title, document, register section and page, generated from `tour.md` and `spec.md` | be edited by hand, or say anything the documents do not |
| `Landin.Diagnostics.Citations.Texts` | the text `refine explain --full` adds, a construct's to its next heading and a decision's `Chosen` paragraphs, generated from the same documents and rendered for a terminal | be edited by hand, or say anything the documents do not |
| `Landin.Diagnostics.Citations.Answers` | reading `[1590]`, `1590`, `D275` and `d275`, and what `refine explain` prints for one | decide which numbers exist, or reach a file |
| `Landin.Bindings` | `refine bindings`' generator (D820) as a function of what Clang printed: the target rows, the policy, the target's triple and macros, the preprocessed headers without their markers, the AST, the enum probe's question and answers, and the four outputs | read a file, run a process, or read C text |
| `Landin.Bindings.Texts` | the generated spellings: Landin and C identifiers from C names, reserved words as `Landin.Tokens` has them, Python's quoting in every message, decimal enumerator values of any width, and the metadata's sorted JSON | decide what a declaration becomes |
| `Landin.Bindings.Clang` | reading Clang's JSON AST: the declarations a policy selects, each record's and enum's identity and typedef names, and C types from Clang's structural type nodes or, where it gives none, its printed spellings | read header text or guess a type Clang did not print |
| `Landin.Bindings.Policies` | the binding policy read from JSON, each key checked and a duplicate refused, and a reference position's annotation | accept a key it does not know |
| `Landin.Bindings.Generation` | selection, dependency collection, record classification, layout, and every declaration's Landin, C and metadata, rendered in an order that depends on names alone | read a file or ask Clang |
| `Landin.Devices` | what the SVD importer's parts share: a fault's kind, input and place, the files made, and the spellings of an SVD's numbers and names | read a file, or know a chip |
| `Landin.Devices.Policies` | D556's selection policy read from JSON: the SVD it was reviewed against, the notice, the layout, the selection, access policies, numeric enumerations and reviewed reset corrections | read the SVD, or accept a member it does not know |
| `Landin.Devices.Projection` | D557's projection of a policy's selection onto Landin: property inheritance, peripheral derivation, alternate registers, fields, encodings, the modules, the correspondence, the manifest and D542's interrupts.ldn, as bytes | read or write a file, expand an array or cluster, or name a chip in compiler source |
| `Landin.Diagnostics.Lexical` | turning a scanner fault into a diagnostic, and a word with a capital into one once the parse says what it names | invent a code, or a roadmap item |
| `Landin.Diagnostics.Syntactic` | turning a parse failure into a diagnostic, and naming the constructs only the parser can meet | invent a code, a construct, or a refused form's standing |
| `Landin.Diagnostics.Resolution` | turning a duplicate or an unknown name into a diagnostic | invent a code, or attach a sentence to no place |
| `Landin.Diagnostics.Checking` | turning a type that does not agree, a checker-recognised deferred use or D251's warning into a diagnostic, including the refused-type table and L0304 ownership | invent a code, a construct, or a refused form's standing |
| `Landin.Platform` | the host interfaces every effect goes through, including descriptor-bound reads, protected input identities, prepared publication handles, retained formatter leases, the resource meter a stage report reads and the byte channel a server talks through | perform an effect, or let a measurement decide anything |
| `Landin.Platform.Publication` | D907's shared artifact group: protected input paths and original read identities, preparation before generation, staged validation and installation, retention through group verification, rollback and final recovery cleanup | perform native filesystem effects, choose a command's outputs, or overwrite a concurrent change to complete recovery |
| `Landin.Platform.Native` | the only filesystem implementation that reaches a disk: D907's descriptor-bound snapshot reads, pinned-directory, no-clobber publication and retained recovery through `landin_publication.c`, retained read leases and inode-preserving formatting through `landin_format_replace.c` (D358), the running executable's own directory through `landin_executable.c`, the process's own resource counters through its host C adapter, and standard input, output and error as a channel through `landin_channel.c` | be reached except through the interface |
| `Landin.Platform.Overlays` | a filesystem over another with some files' bytes held in memory, listed in their directories, so a held buffer is read exactly as the saved file would be | write or remove through the host beneath, or decide which buffers are held |
| `Landin.Platform.Native.Byte_Strings` | exact, chunked copying of length-delimited foreign bytes, including embedded zero bytes in source snapshots, binary artifacts and tool captures | interpret bytes as NUL-terminated text or perform another host effect |
| `Landin.Platform.Native.Tools` | process supervision and capture, using its host POSIX C adapter for spawning, pinned staging-directory tool output, cancellation forwarded to a tool's process group with bounded shutdown and direct-child reaping before cleanup, an environment of exactly the variables named when one is asked for (D821), and capture files, and GNAT for path lookup; `Landin.Source_Maps`, `Landin.Build_Reports.Sources`, `Landin.Devices.Projection` and `Landin.Bindings.Generation` use `GNAT.SHA256` as pure computation | grow a second host concern |
| `Landin.Targets` | target facts, typed architecture identity and each architecture's configuration atom, layout arithmetic, physical evidence-cell offsets/extents and D147 any data/table offsets, extent and alignment derived from pointer facts | ask the host how wide a pointer is |
| `Landin.Targets.Firmware` | the firmware profile a device description selects, its image budget (D537), the cores and the SVD `cpu/name` of each, their architectural vector slots and the closed set of boot image kinds with their second-stage slot and checksum and the image block's words and its reading (D542-D545, D588, D637), and source assembly admission | name a device, invoke tools or derive target widths from the host |
| `Landin.Targets.Assembly` | each target's operand register table, the `general` class and the register it chooses, a register's spelling at a width, `{name}` substitution, the registers an ordinary block overwrites and those never named, each target's line comment and its removal from block text (D597), the refusals of other comment forms and digit separators, and hosted assembly text admission | decide an operand's type or read the host's registers |
| `Landin.Targets.Packed` | packed image storage measurement and width-specific transaction eligibility from target facts | enable source syntax, select instructions or claim a Cortex emitter |
| `Landin.Targets.Layouts` | target-byte placement of complete source-indexed field units under explicit layout policy | expand array elements into planner entries or decide C subset eligibility |
| `Landin.Targets.RiscV_ISA` | the supported RV64 and RV32 ISA strings and their independent standard/vendor extension sets | rank levels, select an ABI, ask the host what executes or admit unimplemented ISA strings |
| `Landin.Targets.Levels` | CPU feature levels per family, each level's feature set, each target's default level, and the spelling of every level and feature | change layout, a calling convention or a C ABI, be read by the IR, or be read by checking except for an atomic access's availability (D690), Cortex-M block text and a firmware program's reference description |
| `Landin.Targets.Selection` | the one list of target names and the description each selects, which the driver, the server, the test harness and the Python checks read | accept a triplet, a fixture label or a second spelling |
| `Landin.Targets.Capabilities` | implemented C signature/record/varargs capabilities, object and debug formats, logical-to-object symbol prefixes, backend availability, the hosted system a target runs on, toolchain triplets, and the reach and image budget of static data a program with no firmware profile emits under (D537) | infer capability from width, invoke a tool, or canonicalise a triplet |
| `Landin.Configuration` | D139's immutable active-declaration view after target selection, the one table of `compiler.NAME` fixed facts, and D202's request mode/overrides, option origins and ordered library requests | mutate syntax, resolve an ordinary source name, or expose a general compiler module |
| `Landin.Stages` | the compilation context, the stage interface, pipelines, and everything a stage builds that outlives it | know which stages exist, or which order they run in |
| `Landin.Stages.Syntax` | running the scan and the parse over a compilation, and keeping each source's tree and space in it | keep anything of its own, or decide reporting policy |
| `Landin.Stages.Configuration` | validate and select D139 fixed declaration arms, collect and evaluate D202's global typed options, fixed compiler facts, scalar target measurements, assertions and library directives before resolution | execute user code, mutate syntax, resolve ordinary declarations or add a runtime declaration |
| `Landin.Stages.Resolution` | the order the trees are walked in through the D139 activity view, including D185's condition-initializer outer scope and guarded-body binding scope and D186's caller-skipping positional call map | own the resolution table, or a code |
| `Landin.Stages.Checking` | D247's routine-declaration and struct-field bounds, the type passes, concept and conformance collection, generic interning and instantiation, fixed-expression evaluation, inferred-error fixed points and checking-stage diagnostic order; the full list is under "What the four largest packages own" below | own a table, a code, execute user code, synthesize a declaration, or choose a target-dependent operator width |
| `Landin.Stages.Folding` | the shared constant folder for checked ordinary expressions in checking and lowering, a generic both stages instantiate with their tables and the few answers only each stage has: how a name reaches its tree, which scalar a conversion targets, a character's value, a float special's bits, and what to do when a module value is worked out from itself; integers and bools fold to their value, floats to their IEEE bit pattern, and an overflow is a distinct outcome from an unknown | report a diagnostic, hold a cycle set of its own, or fold anything the checker has not typed |
| `Landin.Stages.Checking.Flow` | definite assignment, including D156/D157's conservative post-loop assignment boundary and D185's initialized condition binding, D178's complete fixed-array traversal element, D180's copied iterable Item and D182's whole-view utf8 index read, use-after-`sink`, restoration of consumed `inout` parts, explicit fallthrough/return-compatible edge facts, and lexical cleanup execution states | decide a type, infer a nonliteral condition's value, or lower a value |
| `Landin.Stages.Checking.References` | function-local origin and derivation flow, exact `from` agreement, `escaping` obligations and live-view mutation checks; D146 maps an erased construction and implicit self to its pointee fact, D180 gives [1320]'s source-free Item result no source alias, and D182 keeps an indexed codepoint view derived from its utf8 source; integer-created pointers deliberately terminate its evidence | infer a signature across calls, claim ownership, or make an aliasing assumption about volatile storage |
| `Landin.Stages.Lowering` | the walk from checker identities to verified IR, text datums and traversals, evidence tables, aggregate results, cleanups and regions; the full list is under "What the four largest packages own" below | own the Unit, work out a scope, derive target layout, synthesize a declaration, or raise a diagnostic |
| `Landin.Commands` | public command grammar, help, query dispatch and normalization into the existing driver request | implement a language rule or perform host effects outside `Landin.Platform` |
| `Landin.Commands.Catalogue` | the shared command/option definitions used by parsing, help, reference and shell completion, and what each option needs of its request and the sentences refusing one, which the driver reads too (D565) | assign a release version or decide warning selection outside the invocation policy |
| `Landin.Commands.Response_Files` | bounded quoted argument expansion through the supplied filesystem | expand environment variables or execute shell text |
| `Landin.Commands.Presentation` | human, short and structured rendering of the driver's retained diagnostics and positions | reread source files or alter a diagnostic's meaning |
| `Landin.Commands.Tracing` | native argument-vector tracing through the supplied tool runner | execute a command outside that capability |
| `Landin.Commands.Bindings` | `refine bindings` (D820): checking the request, reading the headers and policy and running the named Clang through `Landin.Platform` in an environment of its own (D821), from a private directory it removes, and selection of the four outputs for D907's shared `Landin.Platform.Publication` group through adapter compilation and verification | generate a binding, parse C, or replace a file outside the output directory |
| `Landin.Commands.Devices` | `refine svd`: reading the SVD and policy through `Landin.Platform`, reporting a projection's fault at its place, and selection of generated and manifest-listed stale outputs for D907's shared `Landin.Platform.Publication` group | project an SVD, or replace a file outside the output directory |
| `Landin.Driver` | argument and `--emit` classification, the `explain` and `fmt` subcommands, output/toolchain selection, protected input registration and artifact verification through `Landin.Platform.Publication`, and the result, with its report as data beside its rendering | implement a language rule, acquire a package or expose a public orchestration protocol |
| `Landin.Driver.Loading` | reading named files, and the ordered-root discovery of an entry module and every module its imports reach, an import of `core`, `hosted` or `platform` from the library root alone, through `Landin.Platform` | decide what a buffer holds, cache a module across compilations, or acquire a package |
| `Landin.Driver.Library` | where the repository-owned library is: beside the executable in an installed or a checkout layout, or a directory `--library=DIR` names, which imports name it, and where it looked when it found none | search any other default root, read a source, or acquire a package |
| `Landin.Driver.Assembler_Sites` | placing an assembler's refusal of a `.s` line at the `assembler.block` whose text wrote it, by that text alone | change emitted assembly, or place a line two blocks share |
| `Landin.Driver.Boot_Stage` | D588's check of an assembled object's `.boot2`, its size and the relocations that reach it, and the boot ROM's checksum written into it, as computation on the object's bytes | read or write files, run the assembler, or name a device |
| `Landin.Driver.Image_Block` | D638's reading of an assembled object's `.embedded_block` and the relocations in it, as computation on the object's bytes | read or write files, run the assembler, or name a device |
| `Landin.Driver.ESP_Image` | D683 and D685's ESP application image, made from a linked RV32 or Xtensa executable's loaded segments and the description's chip facts, and its read-back, as computation on the executable's and the image's bytes | read or write files, run a tool, or name a chip the description does not |
| `Landin.Driver.Checking` | the stages a loaded program runs, in their one order, and the panic contract after them, for `refine` and a server alike | decide whether a stage runs past a refusal, or hold a compilation |
| `Landin.Server` | the language server's namespace: the compiler's third client after `refine` and the test program | decide anything a stage decides |
| `Landin.Server.Holes` | D253's stand-in: which routine bodies of a source a server may check as `loop do end loop`, and the bytes it checks instead | change what a stage accepts, or stand in for anything but a body |
| `Landin.Server.Analysis` | one analysis of one module for a server: loaded through the editor's buffers, checked by `Landin.Driver.Checking`, and reported with D253's stand-in where it applies | keep a compilation between two analyses, or report inside a stood-in body |
| `Landin.Server.Transport` | the protocol's framing: header lines, Content-Length and a body, read from a channel and bounded, and a body framed to write | parse a body, or read past a header it cannot read |
| `Landin.Server.Positions` | the one conversion between a byte offset and an editor's line and character, in UTF-8 or UTF-16 units | count a column any other way |
| `Landin.Server.Texts` | open source as counted slices of immutable byte strings, ranged edits in editor units, freeing a string no slice names, and materialization for analysis | copy an unchanged source suffix for an edit, or decide protocol lifecycle |
| `Landin.Server.Documents` | the documents an editor holds open, each held over the filesystem by path, and the module each belongs to: its directory under the roots, or itself alone | read a file a document does not hold, or decide what a module means |
| `Landin.Server.Sessions` | one session from `initialize` to `exit`: dispatch, the lifecycle's refusals, when to analyse, and the exit status | keep a compilation past one analysis, or answer a request it does not offer |
| `Landin.Server.Answers` | each answer as the protocol's JSON: capabilities, published diagnostics, formatting edits, code actions, definitions and hover | decide anything a stage decided, or convert a position itself |
| `Landin.Server.Navigation` | what is at a byte of a checked module: the name it is in, where that is declared, its type as the checker spells one, its written header and its doc comment [2000] | answer where the stages decided nothing, or inside a held body |
| `Landin.Build_Reports.Sources` | off-target report provenance rendered from the compilation | read the host or add report data to the executable |
| `Landin.Build_Reports.Firmware` | post-link Cortex ELF load extents, selected libgcc members, the second stage, the image block and the selected profile for build evidence, a profile's limits alone (D589), D546's linker script contract, and D924's sections a firmware image's C archives brought that startup cannot honour | infer bytes from instruction counts or include toolchain paths in the report |
| `Landin.Build_Reports.Stacks` | D447's depth report: each emitted routine's backend frame, the deepest stack its call graph closes, and where that graph is opened, rendered from the compilation and the backends' routine statistics | read the host, guess an opening's cost or size a backing |
| `Landin.Source_Digests` | per-emission memoization of immutable source snapshot hashes shared by maps and reports | retain digests beyond one emission or read source files from the host |
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
`linker.library` requests a library through the platform driver as its
`-lNAME` (D523), preserving source order and repetitions, and
`linker.directory` and `-L` name where it is searched (D524); configuration
records each directive with its place, the driver resolves a relative
directory against the declaring file's directory through the platform
interface and asks whether it exists, and only after a failed link looks
for each library (D525). None changes that driver's hosted-runtime linkage
policy. `refine run` (D526) reaches the host through the filesystem's
private directory and tree removal and the tool runner's attached run, so
the commands cases hold it to fakes.

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
D235's several-atom union is instead `Landin.Checking.Intern_Pointer_Union`'s
two-cell aggregate nominal, keyed by its atom set and pointer type, with no
source body; `Landin.IR.Admits_Reserved_Zero` lets the backends load its zero
code cell, and the DWARF writer names it by its canonical spelling.
D206 separately refuses known null integer constructions and checks dynamic
zero after target-width conversion, even in `unchecked`; origin erasure does
not erase non-nullness. The library's absent backing uses named pointer unions,
and `dispose` reports `raw_empty` rather than returning an invalid pointer.

D203's C convention and variadic flags follow the complete recursive signature,
not the bodyless import flag or a concrete callee item. Checking admits only
[1975]'s selected C subset and lowering promotes unnamed outgoing C arguments;
verification checks the same signature facts for direct and indirect calls.
`compiler.c_sysv_lp64`, `compiler.c_darwin_lp64`, `compiler.c_aapcs64_lp64`,
`compiler.c_riscv_lp64d` and `compiler.c_aapcs32`
are early fixed configuration bools, with no runtime storage. Ordinary `platform/c`
accepts any supported contract, LP64 or Cortex-M's ILP32 AAPCS32; generated
bindings assert their selected contract. Header
parsing and C adapter generation belong to the separate bindings tool, not to
the scanner, parser, type checker or native backend.
`compiler.c_runtime` is another early bool: true when C's runtime starts the
program and its library is linked, always on Darwin and FreeBSD and on Linux
under `--link=libc`, and false for a static Linux request, a check without
emission among them, and on firmware. The driver sets the request's half
from `--link`; the configuration stage reads the target's half.

D209--D211 add independent `--optimize=none|size|speed` (default size) and
`--specialize=off|auto|all` (default auto) controls. The driver runs verified
specialization, then, at speed, verified inlining (D339), then scalar
replacement and simplification verified together, then verified
if-conversion, then verified in-place parameter reads, then option-aware frame
preflight and selected-target emission. Legacy
backend `Text` callers explicitly retain none/off;
the command-line default never inherits that reference convenience.
`Landin.Optimization` owns typed controls; `Landin.IR.Specialization` owns
incoming-evidence proof and profitability, `Landin.IR.Inlining` owns which
calls are copied into their callers, `Landin.IR.Scalar_Replacement` owns
which slots become one scalar slot per part, `Landin.IR.Simplification` owns
conservative neutral rewrites, `Landin.IR.If_Conversion` owns which branches
become choices, `Landin.IR.In_Place` owns which `in` aggregates
a callee reads where its caller keeps them, and each native backend owns
allocation and selection.
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
interchangeable. The identity is a `Landin.Serials` serial, not a host
address: a freed compilation's tree or table may be followed by another at
the same address, and a serial is never issued twice in one process. Serials
serve only this internal equality check and the owner of a checking key,
never source numbering, target layout, output or iteration order.
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
`Landin.Build_Reports.Firmware` reads the finished Cortex ELF and linker map
through that platform boundary when an executable report is requested. It
measures occupied flash and static RAM extents from load segments and lists
the selected libgcc member names without host-specific paths.

The report's fields are listed under [the build report](#the-build-report).

Frame preflight and emission do not plan a routine twice. Preflight asks
`Landin.Backend.Frame_Bound`, which needs only the reference frame, and
plans the frame only for a routine the bound does not show addressable.
Emission plans each routine once, and when debug output is requested keeps
the plan and frame for the DWARF encoder, which reads them rather than
planning again; Cortex-M's tentative emission hands its frame to the
final one. `scripts/quality.sh` obtains those from pinned Linux object
tools. Complete mandatory runtime profiles and quantitative acceptance are
recorded in `compiler/tests/README.md`, not inferred from the existence of
these packages.

D471's stack-limit check is each backend's own prologue code, asked for
by `Landin.Backend.Prepares_Stacks`, a scan of the whole unit for a
`compiler.stack_prepare`; `Landin.Backend.Call_Free` says which routines
may go unchecked, and `Stack_Limit_Margin` and `Unchecked_Stack_Bytes`
are D472's per-target figures, which `compiler.stack_prepare` and the
depth report read from the same place. The cell, the switch's save of it
and the trap after a routine's other traps are the backend's, beside its
switch routine.

`--stack-report=PATH` is D447's depth report (D467, D468), written after
emitted assembly or a linked executable and refused without one. Each
backend records, in the same `Routine_Statistics`, a routine's
`Stack_Bytes`: how far its code takes the stack pointer below its caller's,
the return address, frame record, frame and largest call or push area
included, and whether a failed check calls out, a runtime helper is called
or the routine is naked. `Landin.Backend.Dispatch.Stack_Facts_Of` holds
what the code outside the program's routines takes: the switch routine's
frame on the leaving stack, the first frame `compiler.stack_prepare` lays,
where the entry starts below a prepared top, D361's report, and D472's
margin above a prepared stack's base, largest unchecked frame and what
the margin pays before a selected handler.
`Landin.Build_Reports.Stacks` reads the call graph from the unit the
backend was given, closes it where a call names its routine, and renders
`landin-stack-report-1`: the target, level and controls, `switch_bytes`,
`prepared_bytes`, `entry_bytes`, `margin_bytes`, `unchecked_bytes`,
`handler_entry_bytes`, a
`trap` object, `openings` (`kind`,
`routine`, `file`, `line`, `column`, `callee` when one is named) and one
`routines` row per emitted routine with `frame_bytes`, `depth_bytes`,
`closed`, `address_taken`, `switches`, `traps`, the deepest `path` and the
`openings` it reaches. Files are named relative to their module's root, as
D361's report names them, so the bytes do not depend on where the program
was read or written. The report is frames and depths; sizing a fibre's
backing from them, alignment of the top and D461's exception frame
included, is its reader's arithmetic. The same measure decides D474:
`Fit_Handler` refuses, after emission and before the driver writes
anything, a program that prepares a stack and selects a handler that does
not fit the margin or whose graph is open.

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

A CPU feature level (D255) is a `Landin.Targets.Levels.Feature_Level` held
beside the description in the compilation, not a field of it. Comparing two
`Target_Facts` therefore still answers which backend, object format and ABI,
which is the only question `Targets.Capabilities` and the backends' guards
ask, and no stage that lays data out is handed a level. Configuration reads
it for `compiler.feature`, and emission and the toolchain arguments read it
to select instructions. Checking reads it for three questions only: whether
an atomic access is available at the level (D690), which instructions a
Cortex-M `assembler.block` may use, and which reference description a
firmware program without one receives.

The `darwin-arm64` description has 64-bit pointers, eight-byte pointer
alignment, sixteen-byte stack/scalar maximum alignment and little-endian
storage. Its Darwin AAPCS64 LP64 ABI identity is distinct from SysV AMD64.
A described ABI does not enable C signatures, C records, variadic calls,
assembly or debugging: each capability is explicit. The Darwin arm64 lowering
enables Darwin C transport and assembly; Darwin source debugging adds Mach-O
DWARF and native LLDB coverage, and the shared hosted and derived programs
run on both targets.
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
Compiler-local labels are separate. `Landin.Hosted` supplies the argument
initializer's name to both checking and emission; the C library's spellings
that differ by operating system are the library's own, in `platform/libc`.
`Backend.ELF` holds the directive spellings every ELF backend shares. See [target contracts](../../docs/targets.md).

A compilation owns everything its stages build and frees it when it ends.
The tables are aliased components of `Landin.Stages.Compilation`, the forest
frees its trees and the source set its snapshots, and each snapshot frees its
bytes and line map. A reference to any of them comes from an accessor whose
parameter is aliased, so it cannot be converted to anything that outlives the
compilation: a dangling tree or span is refused where it would be written, not
found afterwards. This used to be a decision the other way, that nothing was
freed because the process was short; a process that checks on every edit is
not, and `memory` holds a repeated check of the derived log filter to leaving
nothing behind.

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

A diagnostic may carry fixes: each an ordered set of edits, spans of one or
several sources and the bytes that replace them, with a kind, an
applicability and the sentence rendered as its `help` line. A fix is exact
when the rule decides the replacement and applying it keeps the program's
meaning, and likely when it guesses at what was meant, such as a declared name
near a misspelling. The catalogue's `Fixes` column says which codes may carry
one and which must, and `Landin.Stages.Report` holds every edit to whole
characters of a source the compilation read. `Landin.Driver.Outcome` hands the
sorted report back as data beside its rendering, with each source's path, so
a client applying a fix, or sending one to an editor, never reads the text
back. The compiler builds fixes and never applies one; the test program does,
in its `fixes` suite.

A warning is a catalogued observation about legal source (D251). An exact fix
is offered where the edit is safe; an advisory need not carry one. Recommended
warnings do not change the exit status or generated bytes. Compilation
requests may suppress or deny warnings by code. Denial fails the invocation
before emission, without changing language legality or weakening an error.

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

Ada leaves open the order in which a call's actuals, and an aggregate's
components, are evaluated, and GNAT's choice differs between the debug and
the release build. So no two of them may emit IR: an `IR.Emit_*` or
`Lower_*` call is bound to a constant first, and the declarations' order is
the order emitted. `check.py` refuses two such calls as siblings; before it
did, only the build-modes comparison noticed the instructions swap.

D213 distinct identities reuse the nominal inventory with one unnameable
representation child. `Landin.Checking` retains the exact base descriptor and
per-node conversion fact, including routine-instance overlays; the checker
alone authorizes construction or extraction. Lowering preserves the base
image and origins while native calls use aggregate storage. Admitted C bases
retain their selected-target C classification. A scalar atom image keeps its declaration
identity, checked against the field's atom set before the backend assigns a
runtime code.

D266 written-type applications keep the existing stage boundaries. Syntax
retains the complete written type and its one value operand; resolution
looks up names inside that type as type uses. Checking supplies the same
complete descriptor an alias supplies and authorizes only the existing scalar,
text and distinct-representation conversions. Lowering, folding and origin
analysis preserve the corresponding existing behavior. A written pointer
type application remains separate from the contextual `ptr(value)` operation.

## What the four largest packages own

`Landin.Checking`, `Landin.IR`, `Landin.Stages.Checking` and
`Landin.Stages.Lowering` each own an order of magnitude more than any other
package, too much for a table cell. Their rows point here, and each has one
paragraph below.

**`Landin.Checking`** owns what type every runtime node and declaration
has, including concrete parameterized-alias application shapes and D136's
canonical folded array counts, but no template or formal syntax metadata.
It owns the closed compiler and source concept identities and the
whole-program conformance table, keyed by normalized represented type,
concept and input tuple (D142); the table keeps selected parameterized
binders, the generic evidence schema's declaration-ordered provider runs,
constrained-routine evidence runs and per-view evidence selections.
It owns the exact any-concept, construction and flattened-dispatch
positions, without physical layout (D145, D146).
It owns opaque nominal and routine instances, interned by source template
and an ordered tuple of normalized actuals, each a scalar, a structural
atom set, an exact fixed array, a nominal, a structural function signature
or a mathematical fixed value; descriptor keys are bound to their limited
compilation table, and each stored tuple has bounded typed traversal.
A routine instance publishes its substituted signature before graph
discovery and owns a complete overlay of source-node and declaration facts,
with global fallback, plus caller-view generic-call targets, and its
signature finalizes inferred errors before body checking.
Every enabled nonparameterized struct is its template's canonical empty
tuple, and D137's structs separate identity-only function and type-actual
mentions from by-value field, payload and array edges, for parameterized
instances and empty-actual ordinary structs alike, following ordinary
nominal aliases without forcing layout.
It keeps transient nonconcrete nominal obligations for unused-template
recursion checks, and reconstructs interned concrete bindings to promote
nested nominal and nominal-array descriptors lazily at value uses.
It builds one selected-target layout per canonical instance without
mutating its template, with per-instance unseen, building, ready or invalid
layout state and bounded replay of an invalid layout for each
application-local diagnostic.
It owns structural atom and error sets, fixed-array and anonymous result
shapes, aggregate element identity, recursive first-class target-neutral
function signatures on values and aggregate fields, and ordered result
runs; the target-dependent runtime layout of scalar, fixed-array,
unfolded-variant and nested ordinary runs is kept outside the
target-independent nominal keys.
It owns the range-subtype identities, interned on the written range and
carried beside a node's or declaration's base integer kind rather than
becoming one, with the check each value still owes its destination (D188).

**`Landin.IR`** owns the target-neutral instructions: items, slots, blocks and
values, including signature-only external routine items, D161's read-only
anonymous fixed-array datums and D177's canonical static bool images; generic
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

Every `assembler.block` form is one IR instruction with the same
conservative effects and ordinary register and frame restrictions: named
operands (D248), the Cortex-M-only `u32` shorthand through r0 (D230) and the
operand-free block. `platform/cortex_m` uses `general` operands;
[the core guide](../../core/README.md) records its public interfaces.
Compiler-host tests verify the source and IR restrictions on Cortex-M, and
the freestanding lane executes the generated firmware. Nonreturning control
(D231) and selected panic handlers (D232) work on every backend.

**`Landin.Stages.Checking`** owns the three type passes and checking-stage
diagnostic order.
For concepts it owns conformance collection (D142), constrained concrete
lookup, family collision checking, the closed compiler `zeroable` predicate
(D143), evidence provider finalization and `T.entry` evidence selection, and
the identity, construction, object-safety, permission and dynamic-selection
checks of `any` (D145-D147).
For text it owns the contextual read-only byte-literal view (D161), the
canonical immutable hosted-text identities (D181), the exact `usize` ordinal
(D259) and the distinct `core/text.position` byte-position and utf8-index
forms (D182), identity-preserving utf8 and utf16 range selection (D183) and
the exact immutable `u32` text-traversal Item (D184).
For conditions and loops it owns the ordinary binding check followed by the
exact-bool condition requirement (D185), complete collection
traversal-element shapes and erased concept identity (D178, D179), and the
exact named-`iterable` selection and copied Item identity for struct and
`any C` sources (D180).
For generics it owns compile-time-only positional substitution, the closed
target-independent fixed-expression evaluator (D136), scalar, fixed-array
and nominal-aggregate normalization of parameterized aliases, symbolic
validation of unused nominal and routine templates, canonical
`(template, normalized actual tuple)` struct and routine interning,
context-free recursive structural direct-call deduction with deferred exact
computed-bound checks (D138), per-instance substituted signatures, bodies and
fact views, per-instance inferred-error fixed-point nodes, one active-view
effective-call-signature lookup for inference, `try` and recovery, and eager
concrete recovery-binding materialization before a recovery body is checked.
For recursion it owns same-key recursion and finite-expansion refusal,
identity-only versus value-layout requirements for generic and ordinary
signature recursion, ordinary alias-chain identity lookup, transient
symbolic nominal obligations across used-formal wrappers, lazy recursive
promotion from interned concrete actual tuples, substituted per-instance
layout, bounded replay of a repeated invalid layout, and the separation of
by-value recursion (D137, L0313).

**`Landin.Stages.Lowering`** owns the walk that first finds which routines,
ready instances, conformances and module bindings a program reaches (D296),
then eagerly maps checker nominal identities and the reached conformance and
routine-instance identities into deterministic IR order,
registers D161/D181's width-keyed content-pooled read-only text datums and
static slice or cstring relocations, lowers D182's utf8 ordinal scan with
D259's `usize` counter and D182's checked direct position access, D183's
retained-source UTF-8/UTF-16 boundary-checked ranges, D184's
retained-source UTF-8/UTF-16/cstring scalar
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

## What the x86-64 backend emits

This section records the Linux x86-64 backend and the decisions made for it.
[Target contracts](../../docs/targets.md) describe the other backends'
registers, stacks, C ABIs and object formats.

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
compile rather than raising `Compiler_Defect` at run time. The internal
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
named-result exit. Written `true` and `false` fix their `if` or `elsif` edges;
no other condition is believed. A typed binding, assignment
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
Inferred errors and generic discovery are solved together (D215). Recovery
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
with its own `code`. Without `--debug`, equivalent closures emit identical
assembly text for a given target on macOS and Linux, including when emitting
for `linux-x86-64`. With `--debug=full` or `--debug=lines`, assembly identity
also requires the compilation directory and source spelling to be fixed:
DWARF records them in `comp_dir` and `.file` (see
[Deterministic artifacts](../../docs/targets.md#deterministic-artifacts)).
The finishing
half depends on the selected target's driver: Linux uses
`x86_64-pc-linux-gnu-gcc` or `aarch64-linux-gnu-gcc`, Cortex-M uses `arm-eabi-gcc` and then `arm-none-eabi-gcc`, and Darwin uses
`/usr/bin/clang` with `-arch arm64`. Direct Darwin assembly with full debugging
uses an explicitly named object and `/usr/bin/dsymutil` before publication;
the driver owns executing those commands through Platform, while Toolchain
owns their argument policy. A host where that driver is absent
reports `L0500` rather than falling back to whatever bare `gcc` names.
The supported Linux finishing path is the triplet-selected GNU driver and
its assembler/linker. A named driver override must accept that target's
emitted assembly and argument conventions; selecting an executable does not
translate the assembly dialect. In particular, explicit ELF symbol names
beginning with `.L` remain permitted. Generated local labels choose a disjoint
prefix. The separately pinned Clang C-header frontend does not establish
LLVM assembler compatibility for every permitted ELF spelling.
Declared whole-program symbols keep their readable short spelling when it is
unique. Repeated short names across modules receive deterministic declaration
prefixes, as do non-external declarations named like a C import of the same
program. The selected `main`, C imports and public
C definitions retain their ABI spelling unless an explicit C symbol override
selects another; private C definitions without overrides keep collision-safe
internal names. Checking decodes and validates overrides and refuses
incompatible same-symbol declarations or multiple definitions. Thus an ordinary
lexer function named `open` cannot interpose on `platform/libc`'s call to libc
`open`.

The `Runtime` fixture class compiles programs, links them, runs them on the
target and checks their statuses. The gate's Linux corpus therefore proves the scalar
arithmetic and non-loop expression-valued control-flow kernel, early returns,
lexical deferred and failure-only undo cleanup, declared atom errors and source
order, register/stack and recursive calls, folded module values, fixed arrays,
ordinary structs and their target-derived module and frame layouts on the
hardware the backend emits for. A host without the target toolchain fails
rather than silently skipping that evidence. The shared hosted coverage is
complete on both native targets, within its recorded physical-image limits.

The native path sits behind the whole frontend. `refine` scans and parses
every `.ldn` file it is given and resolves every name in them as one module.
It collects concepts and ordinary or parameterized conformances into one
collision-checked table, checks the type of everything and that every name
is assigned before it is read, and reports what none of those stages could
read. It lowers every function it accepted into `Landin.IR`, verifies it and
can dump it. Fully applied positional
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
to the driver, and the recovering parser is where that happened — and its row
stays so its number is never handed to another rule.

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
Each must yield a tree whose invariants hold rather than a crash, and each
stream must give its input back byte for byte from its tokens and its space,
as every `.ldn` file in the repository must, faulty ones included.

`Landin.Syntax` is a flat table, not a pointer structure: a `Node_Id` is a
dense integer, so resolved names, checked types and IR values each go in an
array of their own rather than a map keyed on an access value. Name resolution
is the first to take that up, and it does it once for the whole compilation:
one array of `Declaration_Id` with one run per source and a first index, which
is what `Landin.Syntax` already does with a node's children. A child's
index is lower than its parent's and a child's extent lies inside it, both as
postconditions. A construct the parser could not read becomes an error node of
the band it needed — one per band, so a case over a band still covers the
hole — and `Is_Sound` propagates upward so that one syntax mistake does not
become a cascade of type errors about a hole. Trees live in the compilation's
`Landin.Syntax.Forest`, one per source and freed with the compilation, which
is name resolution's answer to where they live: a tree cannot be an element of a
container, because it is limited with unknown discriminants, and an
initialised allocator whose value is the parse is the one form Ada gives for
building one where it will outlive the call.

A diagnostic code is written in exactly one place, `Landin.Diagnostics.Catalogue`, and `check.py` refuses a code literal anywhere else in `src/`. The catalogue is one table, a named aggregate over the code names holding every column of a code in its row, so a code with no row, or a row missing a column, does not compile; the reporting packages' failures are the code names derived, and the catalogue's header lists the steps a new code takes. The catalogue holds no prose: `L0003` is raised with two sentences, for a source that is missing and one that cannot be read, because one rule was violated and the difference between them is wording. What a code requires of every occurrence — a source, a non-empty span, how many secondary labels, how many notes — is in the row, and `Landin.Diagnostics.Lexical` checks the row against the diagnostic it just built.

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
remain distinct. All targets preserve the default terminal trap instructions;
on a hosted target with no selected handler each failed check first passes
its D361 report line, a merged read-only string, to one compiler-owned
writer that writes it to standard error and executes the terminal
instruction, Linux by its `write` system call and Darwin and FreeBSD through
their C libraries. Firmware keeps the bare instruction.

The stage seam is one interface and one pipeline, contract-tested with fake
stages. Named per-stage packages arrive as each stage is written, which is
what keeps the seam a seam rather than an empty directory tree with
aspirational names in it.

## The build report

`refine check`, `compile` and `run` write this JSON with
`--build-report=PATH` once the request's outputs and tools have succeeded;
[package ownership](#package-ownership) says which packages build it.

The outer JSON has `schema: 1`, a `build` object in
`landin-build-report-1` format, `sources` and `items`; a linked Cortex
executable also has a `firmware` object. The optional outer `link` field
records the selected link mode, `static` or `libc`. A source entry contains
`source`, `path_hex`, `sha256`; an item contains `item`, `declaration`, `name`,
`source`, `first`, `last`, `name` being its symbol's spelling (D421).
`left_indirect` lists every evidence call the emitted program still makes
through a table, each with its `routine`, `source`, `line`, `column`, the
`provider` a concrete table holds and `why`, a sentence. The nested build
carries `target`, the selected CPU feature `level`, and the `optimize` and
`specialize` controls, plus
`specializations`, `routines`, `layouts`. Every backend fills every field
of a `routines` row for every routine it emits, with one meaning on every
target. `frame_bytes` is what the prologue reserves below the frame record
and the registers it pushes: slot cells, spill and save homes and incoming
register homes, rounded to the stack's alignment. It is not the routine's
stack. `stack_bytes` is: how far the routine takes the stack pointer below
where its caller had it before the call, the return address, frame record,
pushed registers and largest call or push area included. The depth report
calls the same figure `frame_bytes`. `save_bytes` are the callee-saved registers it saves, in
the frame or pushed beside the frame record, never the record itself;
`spill_bytes` and `spill_count` its spill homes. `register_count` is the
distinct registers the allocation holds a value or slot in, saved or not,
and zero on RISC-V, Xtensa and Cortex-M, which give every one a home.
`instructions`, `stack_loads`, `stack_stores`, `direct_calls` and
`indirect_calls` are static sites in the routine's final text: a load or
store reaches the stack through the stack or frame pointer or a register
set from one since the last label or call, and a push, a pop and x86-64's
call and return are stack traffic too. x86-64 counts them from its
selected stream and the other backends with `Landin.Backend.Site_Counts`.
Instruction/stack counts are static emission sites, `estimated_growth` is
an IR policy score, and neither claims assembled bytes.

## Building

From the repository root, with the toolchain `TOOLCHAIN.md` pins:

```sh
./scripts/build.sh
./scripts/test.sh
```

On the Mac use `./scripts/test.sh --host`; the unqualified suite includes
Linux workload cases and is not the Mac compiler-host command.

`scripts/dev-build.sh` uses GPRbuild checksum recompilation for the edit loop,
and `scripts/dev-test.sh` accepts an exact `--suite`, `--case`, or `--fixture`
selector. On the Mac add `--host`; run Linux workloads in native development
slots. Filtered runs identify themselves and never replace the complete
suite. [The process guide](../../docs/process.md) explains both native
policies, debugger selection and Linux-only resume.

### Host adapters

The stages remain Ada 2022. The host-only C adapter
`src/platform/landin_file_identity.c`, compares the host headers' `struct stat`
identities without transcribing Darwin and Linux structure layouts into Ada.
`Landin.Platform.Native.Paths_Overlap` combines it with canonical path lookup
for report/source/artifact preflight, including hard links, symbolic links and
not-yet-created output leaves. Two absent ASCII leaves that differ after
ASCII case folding are distinct on any filesystem, so an `--emit=exe` build
on XFS, ZFS or NFS is not refused for `prog` beside `prog.s`. An unresolved
identity is refused conservatively;
this does not protect against concurrent filesystem replacement. No host
identity operation determines Landin target layout or emits program code.

`Landin.Platform.Publication` supplies the group state machine used by the
compiler driver and both generators; none owns a separate replacement or
rollback protocol. `Prepare` captures each output's expected version or
absence before generation; `Stage_Path` names its private staging location;
`Protect` records consumed input names and original read identities. `Commit`
validates every stage, captures and checks old entries, then installs into
absent names without clobbering a concurrent entry. `Abort_Transaction`
recovers in reverse order; `Finish` discards prior versions only after the
command has verified the group. Directory artifacts have checked trees.
Stale manifest outputs use the same delete-only preparation. Native recovery
keeps uncertain entries in a journalled `.refine-publication-...` workspace
and diagnoses that workspace before another invocation can reuse its outputs.
A public name may briefly be absent, and readers do not get an atomic group
snapshot. Synced files and entries do not establish power-loss durability.

Compiler snapshot reads bind bytes and identity to one descriptor. The
protected closure includes sources, response files, policies, supplied tool
inputs, selected tools and known resolved libraries; bindings additionally
records Clang's consumed-header dependencies. External tools report filenames,
not the identities of their original read descriptors. Arbitrary wrappers,
interpreters and implicit toolchain internals are outside this closure.
Executable identity observations do not pin pathname-based execution against
a noncooperating namespace replacement.
The driver refuses relative or indirect assembly and linker file directives
that would change meaning in staging, naming the route through plain absolute
paths or a standalone assembly input or linker script.

Formatting is the separate inode-preserving mode of the same publication
contract: its original read descriptor remains open through the write, so
renamed-in saves are not overwritten and invisible metadata and hard-link
behavior are preserved. `--check` and `--stdout` acquire no writable lease.
Concurrent writes through another descriptor to that inode and hostile
same-credential or privileged access to private storage remain outside the
contract. Public directory-entry changes are handled through the capture
and no-clobber protocol even when made through a directory descriptor.
Tool cancellation uses signal-safe
notification and ordinary Ada cleanup, forwards to the active process group,
stops its remaining ordinary members and reaps its direct child before
recovery; group escape and credential changes are outside supervision.
Automatic child reaping (`SIGCHLD` ignored or `SA_NOCLDWAIT`) is refused
before spawning without changing the inherited policy. Native callers must
not change that policy or let another waiter or handler reap owned children.
A lost wait-status reservation clears the saved identifier before cleanup.

The separate `Same_File` query answers true only for existing host objects
with matching identity. Explicit source arguments load each proven object
once, retaining its first successful spelling and snapshot for diagnostics.
Unknown identity still reads and reports normally; equal bytes in distinct
files do not merge declarations. Rooted module ownership remains separate.
Native byte reads and writes report expected name, permission/use and device
failures as ordinary outcomes. Cleanup retains those outcomes without masking
programming or resource exceptions. A tool capture that cannot be read raises
`External_Tool_Failed` through the adapter's owned cleanup path.
`src/platform/landin_resource_usage.c` reads this process's processor time and
peak resident set with `getrusage`, excluding children, and reports KiB on both
hosts. The driver reads it through `Landin.Platform.Resource_Meter` only for
`--stage-report=PATH`, which writes one row per stage (loading, then each
pipeline stage and emission) with its processor time and the peak resident
set when it ended, plus the compilation's deterministic sizes. Loading scans
and parses each module it reads, a rooted request's and the library modules
named files import, to find their imports; that processor time is counted in
the `syntax` row and not in `loading`, which is reading and import search
alone. A module refused while it loads still writes a `syntax` row for the
parsing that refused it. A refused
program is measured up to the stage that refused it. No measurement reaches a
decision, a diagnostic or an artifact; a host without a meter writes zeros.
An incompatible `--debug` emission request is refused before loading. With
explicit source files, it writes a requested stage report with no stage rows
and zero sources if the report path does not overlap an input. With `--root`,
imports have not been discovered, so it writes no stage report: their paths
cannot be checked for overlap without loading them. A command-line misuse,
including `--firmware-entry` on a hosted target, writes no stage report.
`src/platform/landin_tool_process.c` owns POSIX spawn attributes and wait/signal
constants. `Native.Tools` passes the already-open capture descriptors and
literal argument vector. Merged capture retains one ordered byte stream;
`Output_Only` retains stdout in `Output` and stderr in `Error_Output`, so the
harness can enforce both expected stdout and empty stderr. The adapter creates
captures in exclusive private directories under `$TMPDIR`, or `/tmp`, and
unlinks each data file before launch, retaining its descriptor through the
read. It never reopens or unlinks a capture by its earlier pathname. Private
workspace reads, writes and tool outputs use pinned directory descriptors;
cleanup captures and inspects the owned root before removing it, preserving
any replacement and reporting uncertain recovery. The adapter starts each tool in its own
process group and uses a monotonic deadline. On timeout it kills that group and reaps the direct child
before reporting `Timed_Out`; adapter exceptions also stop an owned child.
Expected host-policy refusals carry their cause and corrective action before
optional tool paths, so GNAT's bounded exception message cannot hide the route.
The group is established before execution through
[POSIX spawn attributes](https://pubs.opengroup.org/onlinepubs/007904975/functions/posix_spawn.html).
Descendants that deliberately leave the group are outside this supervision
contract. The focused native tests use a short-lived child and delayed marker,
and preserve exit/signal distinctions, argument bytes and capture modes.
The shared project builds both adapters with warnings as errors; source checksums
include C sources and headers as well as Ada sources.

## Target, memory and device seams

Darwin uses the shared DWARF encoder with x29-relative stack locations and
Apple section/CFI conventions. Full executable output retains its object and
packages a matching dSYM before publication; direct assembly uses an explicit
`/usr/bin/dsymutil` step. The native UUID and full
Landin source/assembly digest bind the executable, dSYM and optional source map.
See [target contracts](../../docs/targets.md#native-source-debugging) for native
commands, identity matching and the demonstrated debugger presentation limits.

The [Cortex-M environment probes](../../environments/cortex-m/README.md)
are separate C/assembly controls for QEMU and a synthetic device lane on it.
`Targets.Cortex_M` and `Backend.Arm32_ABI` supply layout/transport planning,
with independent executable controls under that environment. The existing
neutral shape machinery supplies storage. `Backend.Cortex_M` adds assembly
emission and compiler-generated QEMU execution. `--target=cortex-m0`
accepts checking, `--emit=asm` and D229 firmware linking with explicit
`--firmware-entry=NAME`. C signatures and records follow AAPCS32 (D920), and
firmware links C archives (D923); variadic C calls remain refused (D922). Cortex
`--debug=lines` enables the explicit [line/function contract](../../docs/targets.md#cortex-source-debugging);
`--debug=full` remains refused. `Backend.Firmware` owns reset/script generation; the older external
startup/linker probes remain independently identified test harnesses. See
[target contracts](../../docs/targets.md#cortex-m-layout-and-abi-planning).

`Landin.Memory` owns the neutral operation/order vocabulary.
`Configuration` recognizes the exact compiler member syntax; resolution visits
runtime operands and checking validates fixed orders, pointer permission,
unsigned scalar identity and target capability. `IR.Memory_Access` retains
that contract through verification and optimization. Native backends implement
scalar atomics/volatile access and barriers. Cortex-M implements admitted
one-, two- and four-byte loads/stores and barriers, retaining alignment checks
and refusing RMW/eight-byte memory intrinsics. The [target guide](../../docs/targets.md#explicit-memory-operations)
records actual instruction requirements. Packed/register/volatile-pointer type
syntax and the ordinary CPU/cache modules are owned separately.

Packed storage uses `Landin.Packed` for unsigned image algebra and access
planning, `Targets.Packed` for target storage/capability queries, and syntax/checking for
encoded unions and explicit packed positions. Neutral shapes retain geometry
and encoding tables through verification and optimization. Native backends
implement checked extraction/insertion and raw aggregate copies; the DWARF
consumer exposes the raw carrier. Explicit register-image intrinsics use the
existing volatile IR boundary with retained reserved-bit guards. General
register wrappers remain deferred; the Cortex emitter preserves the same raw
image and validation contracts.

The native debugger gates include a D231/D232 program that enters a selected
handler through erased evidence and a generic nonreturning callback. Source
breakpoints, values, operation sites and unwind frames execute under GDB/LLDB
at three profiles. Darwin out-of-line panic edges carry their originating
source line. On x86-64 a failed check's trap is laid out after its routine's body,
one per operation and kind, so a passing check falls through; each keeps its
operation's line, variable locations and lexical scopes, and the body's frame
description. Those native sessions remain separate from Cortex line/function debugging.

The [device modules](../../devices/README.md) are ordinary Landin modules
that `refine svd` writes from a vendor's SVD and a reviewed policy
(`Landin.Devices`, `Landin.Commands.Devices`); a program compiles them
through the same frontend, packed and volatile IR and firmware path as any
other source. Nothing from the SVD reaches the target except what those
modules declare.

The complete [prototype-1 derivation](../tests/driver/DERIVATION.md) compiles
through `--target=cortex-m0 --firmware-entry=start --emit=exe`. Initializer inference settles recovery bindings while deferring concrete
recovery bodies to the enclosing routine walk, so inferred bindings can recover with existing
loop transfers. Firmware BSS has an explicit RAM LMA and no load payload.
These repairs add no syntax, register metadata semantics, IR operation or
general C support. Routine debugger-risk policy covers both native backends;
Cortex has the explicit line/function source-debugging contract.

The FreeBSD x86-64 and arm64 descriptions share the existing ELF backends and
C ABI planners. Hosted libc spelling is the library's `platform/libc`, target identity
and availability in `Targets` and `Targets.Capabilities`, and Clang/sysroot
argument policy in `Backend.Toolchain`. `compiler.os` selects libc records
without changing C transport facts. The FreeBSD supervisor emits on Linux;
its VM effects belong to the external test environment. See the
[FreeBSD lanes](../tests/freebsd/README.md).

## Debugging an internal defect

A defect the compiler finds in itself ends the run with the report rendered
so far and a line `refine: internal compiler defect in STAGE: MESSAGE`.
When the message is a failed contract, such as `failed precondition from
landin-syntax.ads:1393`, it names the declaration whose contract failed,
not the call that broke it. The debug build checks contracts (`-gnata`,
which the release build leaves out), and the `gdb` the pinned GNAT bundles
stops where the check fails. In the Nix shell, which sets
`LANDIN_BUILD_TAG`:

```sh
gdb --args compiler/ada/build/$LANDIN_BUILD_TAG/debug/bin/refine check program.ldn
```

```text
(gdb) catch assert
(gdb) run
(gdb) backtrace
```

Below the run-time library's frames, the first Landin frame is the
subprogram whose contract failed, and the next is its caller. A defect
raised as `Compiler_Defect` stops the same way under `catch exception
landin.compiler_defect`. The driver handles every defect so that it can
write the report, so `catch exception unhandled` never stops on one.

## Profiling

The Linux nix shell carries `perf` and valgrind beside the pinned toolchain,
so `refine` and the programs it emits can be profiled to the routine, and
their calls counted, without leaving it. Both come from `flake.lock`'s
package set rather than `environments/pins.sh`: what they measure is
developer evidence, never a gate's. Start the program under the tool rather
than attaching to it: a host with Yama's `ptrace_scope` at 1, as most
distributions ship, answers an attach with "ptrace: Operation not
permitted", and the user-space sampling below needs no privilege at the
default `perf_event_paranoid` of 2. The `gdb` on the shell's `PATH` is the
one the pinned GNAT bundles, built without Python, so a script that needs
GDB's Python does not run there.

Where `refine`'s time goes, by routine. Both build modes keep symbols and
DWARF; build the release compiler with `LANDIN_BUILD_MODE=release
./scripts/build.sh --compiler-only` to measure what a user runs.

```sh
perf record --call-graph dwarf,65528 -o refine.perf -- \
    compiler/ada/build/nix-x86_64-linux/release/bin/refine check program.ldn
perf report -i refine.perf --no-children --sort symbol
```

Unwind with DWARF and the largest stack copy `perf` allows. Frame-pointer
unwinding (`-g`) drops a leaf's immediate caller, so a `memmove`'s cost
shows one frame too high. A 16 KiB copy, `dwarf,16384`, truncates stacks
inside the IR verifier, whose frame is larger than that. `--stage-report` says which
stage to look in first; this says which routine.

Counting calls is valgrind's callgrind, which counts every call exactly and
records who made it, so nothing has to be rewritten with counters:

```sh
valgrind --tool=callgrind --callgrind-out-file=program.callgrind ./program
callgrind_annotate --tree=caller program.callgrind
```

Each routine's line gives its own cost, and each line above it a caller and
how many times that caller called it, `(131,768x)`; `--tree=calling` gives
the callees instead. A program built with `--debug=full` is attributed to
source lines too, and `callgrind_annotate --auto=yes` prints them. That is
the supported way to count calls per routine and per call site: an
instrumenting mode in `refine` itself would emit different code from the
program being measured, which callgrind's exact counts, taken from the
unchanged binary under simulation, do not. Callgrind runs the program
about fifty times slower, so count on a small input and time on a large
one. A generic instance is a symbol named after its routine (D421), so both
tools name it rather than an address.
