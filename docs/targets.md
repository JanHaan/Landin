# Target contracts

`spec.md` [1975] owns the language-facing C and link-name rules. ROADMAP.md
R5.20/R5.30/R5.40/R5.50 record implementation evidence; R5.51 consolidates
retained debt and current acceptance dispositions; this page explains
the package boundaries, not a second work list.

| fact or operation | owner |
|---|---|
| pointer width, alignment, byte order, architecture, intended C ABI | `Landin.Targets` |
| implemented C signatures, records and variadic calls | `Landin.Targets.Capabilities` |
| object format, symbol prefix, available backend/debug format and triplet | `Landin.Targets.Capabilities` |
| source-level C subset eligibility | checking, using capability queries |
| physical C transport | backend ABI planner; separate SysV, Darwin and Cortex-M planners |
| frame preflight and emission selection | `Landin.Backend.Dispatch` |
| assembly, local labels, libc dependencies, register/frame placement and DWARF | concrete backend |
| logical hosted helper identities | `Landin.Hosted`, shared by checker and backend |
| native driver, archive resolution and platform link arguments | target-guarded `Landin.Backend.Toolchain` |
| C alias identities | ordinary `core/c`, guarded by the selected ABI fact |
| actual header/tool ABI verification | `bindings/generate.py`, explicit Clang target and sysroot |

The Linux and Darwin descriptions both use 64-bit pointers, eight-byte pointer
alignment, sixteen-byte stack alignment and little-endian storage. Equal widths
do not imply equal calling conventions. Darwin enables C signatures, C records,
variadic calls and native Mach-O emission. `--target=darwin-arm64 --emit=exe`
selects `/usr/bin/clang -arch arm64`; `--toolchain=PATH` explicitly overrides
the driver. The default target remains Linux. `--debug=full` selects native DWARF and
dSYM packaging on Darwin; the synthetic target has no debug capability.
The synthetic 32-bit seam has no emitter, object format or C ABI.

Darwin transport follows Apple's
[ARM64 platform ABI](https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms)
and the [Arm procedure-call standard](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst),
checked against the Apple tools and SDK pinned in
`environments/macos-arm64/policy.json`. Integer/pointer arguments use x0–x7,
float arguments v0–v7. Homogeneous float aggregates of up to four leaves use
the float bank. Other aggregates through sixteen bytes use integer chunks;
larger values use caller copies and pointers. Indirect results use x8 without
consuming x0. Fixed stack arguments are naturally packed; promoted variadic
tails use eight-byte stack slots. Narrow integer arguments are extended by the
caller. The native C differential corpus covers both call directions, bank
exhaustion, partial chunks, nested arrays, callbacks and large results.

Every emitted routine and hosted helper keeps an x29/x30 frame record; sp is
sixteen-byte aligned and x18 is unused. Native Landin calls use eight integer
bit carriers then stack slots, address-based aggregate transport and a separate
w8 declared-error carrier. The backend emits already verified cleanup edges.
Stack growth touches each 4 KiB page. Frame/incoming/outgoing/copy preflight
retains a signed-2-GiB budget. Conditional branches expand through adjacent
inverted branches; the baseline still requires direct branches to fit the
architecture's 128-MiB reach. R5.20's explicit broader resource/scaling
limitations remain; this adds no recovery guarantee for arbitrary exhaustion.

Darwin's minimal hosted bridge supplies argument access, malloc-backed aligned
allocation, open/read/write/close and immediate errno capture through `__error`.
It uses Apple's open flags and variadic placement. The platform's ordinary
startup and libSystem come from the native Apple driver.

Archive requests retain source order and repetition. Linux keeps `-l:libNAME.a`
and GNU build-id arguments. Darwin queries the selected driver with
`-print-file-name=libNAME.a` and passes an existing returned file directly;
Apple's bare response requires that file in the invocation directory. A custom
driver can resolve another archive search policy. Missing archives fail; `-l`
and `-hidden-l` cannot guarantee archive selection when a dylib is also present.
No GNU build-id flags reach the Darwin driver. Caller-source sidecars use the Mach-O identity contract below.

A logical external name such as `_entry` stays unchanged in checking and IR.
The target mapping yields `_entry` on ELF and `__entry` on Darwin. Quoting an
assembly operand is a later rendering step, and a leading underscore in source
does not escape the platform prefix. The same mapping applies to explicit
native names, C imports/exports and compiler-owned hosted helpers. Local labels
are allocated separately. Existing ELF spelling and golden records remain valid.

`core/c` asserts `compiler.c_sysv_lp64 or compiler.c_darwin_lp64`. Each fact
identifies its own implemented ABI, not LP64 generally. Generated bindings
assert the selected fact. The generator supports `x86_64-pc-linux-gnu` and the
pinned `arm64-apple-macos26.0.0` deployment triple, independently probing Clang's
triple, macros and data model. The native Apple corpus regenerates all binding
categories, including TLS, nullable callbacks and incoming-varargs adapters;
existing Linux generated files remain unchanged.

## Native source debugging

`refine --target=darwin-arm64 --debug=full --emit=exe program.ldn -o program`
produces `program.s`, `program.o`, `program`, `program.dSYM` and
`program.sources.json`. Apple Clang receives `-gdwarf-4 -x assembler` and
`-save-temps=obj`; explicit assembler input prevents preprocessing from
rewriting the compiler assembly. The language selection resets before archive
arguments. Clang invokes its native dsymutil after linking. Output preflight
protects the retained object and dSYM bundle as well as existing artifacts.

Open `lldb ./program`, then use `breakpoint set -n main`,
`breakpoint set -f program.ldn -l 12`, `run`, `next`, `step`, `bt` and
`frame variable`. The dSYM can accompany a deployed executable without its
object file; source text must remain available for source listing, or be
remapped using LLDB's `target.source-map` setting.

`Backend.Dwarf` shares represented type, scope and availability serialization.
Each backend supplies the same placement plan it uses to emit instructions.
Darwin's frame base is DWARF register 29 (x29), with negative frame-relative
homes and dereferences for indirect bindings. CFI describes x29/x30 saves,
the CFA at x29+16 and each return's restoration, including hosted helpers.
The frame pointer remains present with debugging disabled. No Darwin fact
enters parsing, checking or neutral IR semantics.

Apple's dsymutil requires a relocatable compilation-unit low address when
rewriting the selected location/range lists. The Darwin encoder supplies it;
ELF retains its existing address-base convention. Both formats now describe
empty payload structures without claiming child DIEs, avoiding the native
verifier warning while retaining the same represented byte size. Native object and dSYM verification
and LLDB sessions check the result. Compilation-unit and assembler line tables
use DWARF 4; the native CIE is version 1. These are output encodings, not IR
versions or language rules.

Debuggers display Landin's represented types through their C presentation.
A variant is a truthful tag plus named payload overlays; users select the
active payload using the tag. LLDB canonicalizes scalar display names, such as
`i32` to `int`. It does not evaluate Landin expressions. Source aliases from
matches, named-result destructuring and loops remain inspectable in their
live scopes. The native backend currently uses stack homes under baseline
optimization; it does not claim x86's saved-register allocation. Uninitialized
or unavailable variables have no valid location, and ranges end before frame
restoration. R5.50 adds the complete parser, containers and hosted application to the
native LLDB matrix, using the existing Linux source/value oracles.

### Exact identity and optional deployment

The map's `build_id` is the full SHA-256 digest of the compiler assembly and
its selected source snapshots, including filename bytes and source hashes.
The backend adds that digest to `__TEXT,__landin_id`, without filenames. It
therefore contributes to the native linker's `LC_UUID`, including when only a
source comment changes. The map separately hashes the final emitted assembly.
The Apple-generated UUID matches the linked executable to its dSYM; the full
Landin digest matches that executable to its caller/source table. R5.30's
caller sidecars alone did not provide this Mach-O binding.

```sh
python3 scripts/source-location.py program.sources.json 2 11 12 \
    --macho program --dsym program.dSYM/Contents/Resources/DWARF/program
```

Lookup refuses a mismatched digest or dSYM UUID. The native reader supports
the implemented thin arm64 Mach-O target and validates load-command bounds;
universal binaries are outside this target contract. `--assembly` remains
available, and Linux retains `--build-id` with the full GNU build ID.
These identities match builds; they are not signatures or tamper-proof
attestations against a modified executable.

`--debug=none` remains the default and emits only a caller-needed source map.
Neither that map nor source filenames need deployment. `strip -S -x` removes
optional source-debugging information from a copy while preserving executable
behavior, the identity section and UUID. When debugger acceptance is selected, it runs the copy alone in a
fresh deployment directory, refuses source breakpoints without debug artifacts,
and separately resolves its caller coordinates against retained matching data.

Platform references, checked against the pinned Apple tools:
[Apple debug artifacts and UUIDs](https://developer.apple.com/documentation/xcode/building-your-app-to-include-debugging-information),
[dsymutil](https://www.llvm.org/docs/CommandGuide/dsymutil.html),
[Arm DWARF register assignments](https://github.com/ARM-software/abi-aa/blob/main/aadwarf64/aadwarf64.rst),
and [LLDB scripting](https://lldb.llvm.org/use/tutorials/script-driven-debugging.html).

## Hosted parity and physical limits

The shared [target applicability matrix](../compiler/tests/targets.matrix)
and [native parity path](../compiler/tests/darwin/README.md) distinguish
language behavior from platform transport and packaging. The two hosted
backends run the same runtime profiles and complete prototype derivatives.
Architecture-selecting source, C register rules, symbol prefixes, archive
availability and native trap delivery have explicit executable counterparts.
The fault-endpoint adapter changes only fixture host services, never parsing,
checking, neutral IR or the Landin program's expected failure behavior.

The existing 2 GiB zero-reserved-global regression exposes a limitation of the
pinned Darwin default executable layout: dyld aborts before `main` when the
image reaches the shared-cache region. The native Clang control has the same
failure. Apple's [shared-region constants](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/osfmk/mach/shared_region.h)
place the arm64 shared region at `0x180000000`; the default executable starts
at `0x100000000`. These observed layout limits do not define different array
semantics. Darwin now emits the complete wide element address, and all four
profiles retain successful assembly/linking followed by the original failed
status-42 execution and matching control. The result is explicitly
`platform-limited`; no passing runtime verdict or general large-image support
is claimed. R5.51 R551-07 retains R5.20's large-image placement/preflight transfer to the
scale and self-hosting successor, with an explicit activation condition. No giant materialized object sweep or
new exhaustion guarantee is introduced.

## Cortex-M environment boundary

R6.10's [execution profile](../environments/cortex-m/README.md) pins QEMU's
Cortex-M0 micro:bit CPU lane and a synthetic Renode peripheral lane. C/assembly
probes establish the environment. R6.20 adds layout and ABI planning below;
R6.50 adds compiler-generated M0 execution; R6.60 adds compiler-owned firmware startup and linking.
The original synthetic-32 goldens
remain unchanged.

## Cortex-M0 layout and ABI planning

R6.20 adds `Targets.Cortex_M` (`cortex-m0`), selecting ARMv6-M Thumb,
little endian and base AAPCS32 soft-float identity. `refine --target=cortex-m0`
checks source and emits ARMv6-M assembly against these facts. The toolchain
identity is `arm-none-eabi`. Executable requests require the explicit
`--firmware-entry=NAME` source identity (D229); missing or invalid entries report
L0502. C signatures, records, varargs and object/source-debug output remain
disabled. The independent external startup/linker harness remains distinct
from the compiler-owned firmware path.
`core/c` and the header generator still accept only their two hosted ABIs.

D231's infallible `noreturn` is shared across target descriptions. Its signature
identity survives ordinary function values, generics and erased evidence. An
ordinary Cortex firmware entry may use it; interrupt/naked signatures remain
`()->none`. A violated nonreturning-call promise traps after the call on every
backend. Hosted C signatures support it within their existing ABI; Cortex
continues to refuse the general C source surface.

The existing scalar and recursive shape machinery supplies all byte placement;
there is no separate Cortex layout algorithm in checking or neutral IR.

| represented value | Cortex-M0 storage and alignment |
|---|---|
| enabled integer and float scalars | 1/2/4/8 bytes with equal natural alignment; bool occupies one byte |
| `usize`, `isize`, references, optional atom/pointer, function address | four bytes, aligned four; semantic identities remain distinct |
| slice, utf8/utf16 view, `any` | two four-byte cells, aligned four; slice base then length, any data then table |
| cstring | one four-byte pointer |
| natural structs, fixed arrays and instantiated generic records | shared source-order placement, element stride and final padding, bounded by target `usize` |
| variants | smallest enabled tag carrier, followed by maximally aligned/padded case storage; the golden example is 12 bytes, payload at four |
| ordinary atoms and declared-error codes | four-byte unsigned carriers; dense nonzero identities, zero reserved for successful call outcome |
| direct and flattened erased evidence tables | size/alignment at 0/4, functions at 8, 12, …; extent `(N+2)*4`, alignment four |

Distinct wrappers retain their base representation. Caller coordinates retain
D192's three `u32` fields (12 bytes), rather than turning into pointer-sized
integers. The 32-bit maximum object extent is 4294967295 bytes; it is a layout
arithmetic limit, not an available-RAM promise. The selected probe image still
has 32 KiB flash, 16 KiB RAM and a 4 KiB stack reservation. D228 packed images use the same target facts;
over-aligned source types and deferred scalar widths remain unavailable.

`Backend.Arm32_ABI` derives placement from neutral signature parts, including
entry signatures and direct/indirect call operands. It selects the convention
explicitly; a four-byte pointer never implies compatibility. The external C
planner follows [AAPCS32 2025Q4](https://github.com/ARM-software/abi-aa/blob/2025Q4/aapcs32/aapcs32.rst):
r0–r3 precede the stack, double-word arguments start at even registers or
8-byte stack addresses, and a composite may split at the register/stack
boundary. Narrow integers extend to 32 bits. Stack argument extents round to
four bytes; the total outgoing area rounds to eight. Soft-float values use
core bit carriers, including float-only records; there is no HFA register bank.
C composite results through four bytes use r0; larger results use a hidden
address in r0, consuming that argument position. Scalar 64-bit results use
r0/r1. Variadic tails use this same base PCS after default promotions, with
unpromoted tails refused by the planner. Empty/non-C/variant records and
Landin errors or multiple results are outside the C boundary.

The internal Landin convention uses the same scalar/word placement but passes
aggregate, array, slice and any values by address, with the required callee
value copy. `inout` instead carries the original place address. Aggregate and
multiple results always use caller-owned storage, even below five bytes.
Its address comes first; the existing signature's generic evidence pointers
follow in D144 order, then written parameters. Static type/fixed parameters
consume no runtime position. Erased dispatch inserts its data pointer in the
provider's self position, without a hidden table argument. Declared failure
uses r12: zero on success, otherwise the nonzero atom code. Successful scalar
results remain in r0/r1, and failed calls promise no successful result. C
calls do not preserve this internal error carrier. Linker call veneers may
clobber r12 on entry; it is only an outcome after the called routine returns.

The selected frame obligation keeps r11 in every Landin routine, including
leaves, pointing to an eight-byte record: previous r11 then incoming lr.
Publish the frame pointer only after constructing that record. Preserve
r4–r11 and sp, reserve r9 from allocation, treat r0–r3/r12/lr and condition
flags as call-clobbered, maintain sp modulo four at all times and modulo eight
at calls, and allocate no red zone below sp. R6.50 implements this record and
checks its construction through instruction stepping, including leaves and
nested calls. The earlier handwritten witness remains independent evidence. GCC's C routines may use r7 as a local frame base; no continuous mixed-C
r11 chain or foreign-exception unwinding is promised. Code addresses retain
the Thumb low bit for tables and indirect calls; data pointers gain no such bit.
[Arm ELF32](https://github.com/ARM-software/abi-aa/blob/2025Q4/aaelf32/aaelf32.rst),
[GNU Arm directives](https://sourceware.org/binutils/docs/as/ARM-Directives.html)
and [GCC Arm options](https://gcc.gnu.org/onlinedocs/gcc-14.2.0/gcc/ARM-Options.html)
are checked against the pinned tools. Their unsigned plain C char and ILP32
model are measured, not inherited from the hosted `core/c` aliases.

The [probe guide](../environments/cortex-m/README.md#r620-layout-and-abi-evidence)
distinguishes Ada planner/IR tests, GCC layout measurements and executed
C/assembly witnesses. No language semantic decision, instruction selection,
Landin startup or source debugger is supplied by these plans.

## Explicit memory operations

R6.30/D227 admits unsigned scalar memory primitives through
`Targets.Capabilities.Memory_Access`, independently of backend availability.
Widths are 1/2/4/8 bytes on hosted targets and 1/2/4 on Cortex-M0. Every implemented access
checks natural alignment at runtime, including inside `unchecked`. The M0
source contract refuses exchange/add/compare-exchange. R6.50 emits the admitted
loads/stores and barriers; it introduces no atomic runtime helper. Synthetic-32 refuses these operations.

The initial hosted lowering deliberately strengthens every atomic ordering.
x86 uses aligned MOV for loads, XCHG for stores/exchanges, LOCK XADD for wrapping
fetch-add and LOCK CMPXCHG for strong compare-exchange, with MFENCE before and
after each. Darwin uses DMB ISH before and after, ordinary scalar load/store,
and a baseline LDXR/STXR retry loop for read-modify-write; a failed comparison
clears the reservation with CLREX. It requires no LSE extension or out-of-line
atomic helper. Retry loops promise no wait-free bound. Scalar volatile accesses
use exactly one width-matched load/store and no implicit hardware fence.

Compiler barriers have no hardware instruction. Thread fences use MFENCE or
DMB ISH. Device barriers use MFENCE or DMB SY; completion barriers use MFENCE
or DSB SY. CPU atomic contracts assume ordinary coherent RAM (x86 write-back;
Arm Normal shareable memory). Device/MMIO behavior requires platform mappings,
permitted bus width and the device's completion protocol. A fence cannot turn
an arbitrary user pointer into a valid device mapping or drain a device's
internal command queue. On x86, MFENCE provides global visibility ordering,
not instruction serialization or a peripheral acknowledgment; posted writes
can require a device-specific readback. On Arm, DSB waits for architectural
completion, which also does not imply peripheral-command completion. No portable cache-maintenance builtin is enabled.

Official architecture and toolchain references checked on 2026-09-16:
[Armv6-M reference manual DDI0419E](https://documentation-service.arm.com/static/5f8ff05ef86e16515cdbf826),
[Arm A-profile manual entry](https://developer.arm.com/documentation/ddi0487/mc/)
and [Arm's explanation of SC instruction sequences](https://developer.arm.com/community/arm-community-blogs/b/tools-software-ides-blog/posts/armv8-sequential-consistency),
[Intel architecture manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html),
[GCC atomic builtins](https://gcc.gnu.org/onlinedocs/gcc/_005f_005fatomic-Builtins.html),
[GCC memory clobbers](https://gcc.gnu.org/onlinedocs/gcc-14.2.0/gcc/Extended-Asm.html),
and [Arm CMSIS cache operations](https://arm-software.github.io/CMSIS_6/latest/Core/group__Dcache__functions__m7.html).
The pinned M0 tools execute the supported load/store/barrier and nested PRIMASK
controls, and independently show GCC's RMW needs an unresolved helper.
The cache model demonstrates stale reads and destructive maintenance, under an
explicit two-byte cache-line abstraction; the cacheless emulator cannot test
physical cache behavior. See the [probe guide](../environments/cortex-m/README.md).

R6.40 connects `Targets.Packed` to source declarations and neutral field
geometry. One carrier of 1/2/4/8 bytes uses the selected target's size and
alignment, with least-significant-bit numbering and little-endian byte order.
Unsigned field widths through 64 bits do not add ordinary scalar widths or
calling conventions. Natural, C and optimal layouts retain their contracts.
Native x86-64 and Darwin arm64 lowering extract and insert that carrier and
validate encoded members. M0 remains limited to one-, two- and four-byte
volatile transactions; describing an eight-byte ordinary image does not enable
an eight-byte MMIO access. The Cortex emitter preserves this distinction.

Packed debug types expose one unsigned `raw` member and their true storage
size. This preserves unnamed encodings without claiming independently
addressable fields or ordinary array strides. Full named bitfield/bit-array
presentation is a retained debugger limit; the
[DWARF 4 specification](https://dwarfstd.org/doc/DWARF4.pdf) and
[bit-offset clarification](https://dwarfstd.org/issues/081130.1.html) distinguish
those representations. Native debugger controls inspect a raw image containing
an unnamed pattern. The [probe guide](../environments/cortex-m/README.md)
distinguishes compiler-generated hosted peripheral execution, independent M0
C controls, and abstract model assertions.


## Cortex-M0 assembly implementation

`Backend.Cortex_M` consumes verified IR and `Backend.Arm32_ABI` entry/call plans.
It does not change ordinary, C or optimal layout. Source slots remain pinned;
verified block-local scalar temporaries reuse eight-byte stack homes only after
their last operand read. Heap-owned work arrays keep allocation scratch off the
Ada host stack. r0-r7 are selector scratch, with r4-r7 saved, r8/r10 untouched,
r9 reserved, and r11 the frame pointer. The fixed prologue saves r4-r7, constructs
the eight-byte previous-r11/lr record, publishes r11, then reserves aligned
homes and incoming-register staging. Every epilogue restores that chain and the
saved registers. Incoming stack arguments start 24 bytes above r11. Outgoing
arguments use the planner's aligned stack area plus private r0-r3 staging.

| Selection | Implemented choice and boundary |
|---|---|
| Instructions and constants | ARMv6-M low-register forms; high-register MOV/BX where admitted. Small constants use MOVS and shifts; other constants use aligned adjacent literal islands skipped in execution. No MOVW/MOVT, Thumb-2 arithmetic, FPU or exclusive-access instructions. |
| Addresses and branches | Frame offsets materialize into a low register; no narrow displacement is assumed. Conditional transfers invert a nearby condition over an absolute Thumb jump. Direct BL relocations permit GNU veneers; indirect calls use BLX. ELF function identity carries the Thumb bit, ordinary data identity does not. |
| Frames and limits | Shared target-byte placement, no red zone. Preflight reserves selector and outgoing-call overhead inside the 32-bit address budget and reports L0504. The external test map's 32 KiB flash/16 KiB RAM/4 KiB stack limits are separate from that arithmetic bound. |
| Integer operations | Enabled 8/16/32/64-bit values, explicit narrow extension and pair operations, width-bounded shifts, signed/unsigned comparisons, checked overflow, division-zero and signed minimum/-1 handling. D187 removes only its specified checks. |
| Conversion and floating operations | Software IEEE arithmetic/comparison and integer-to-float/float-width helpers. Float-to-integer selection decodes the IEEE carrier and checks range before constructing the integer; bool accepts only its specified domain. Finite narrowing overflow traps. |
| Calls and values | Direct/indirect entries, value copies, inout places, caller-owned aggregate/multiple results, generic evidence and erased self/table dispatch. Capture r12 immediately after a Landin call; foreign helpers and veneers may clobber it. Every successful Landin return writes zero privately. |
| Images and checks | Raw packed copies retain every bit. Extraction validates named encodings even when discarded or unchecked; insertion fit, indices and reserved policies retain their guards. Ordinary atoms still exclude zero. |
| Memory and traps | One aligned LDRB/LDRH/LDR or STRB/STRH/STR per admitted transaction. Atomic orders are conservatively strengthened by DMB SY before and after; compiler barriers emit no hardware operation, device/thread barriers use DMB SY, completion uses DSB SY. Checked failure uses UDF #1. No interrupt masking or helper atomics. |

The instruction envelope follows the official
[ARMv6-M Architecture Reference Manual](https://documentation-service.arm.com/static/5f8ff05ef86e16515cdbf826),
with executable legal/illegal encoding controls under the pinned assembler.
Per-routine ELF input sections support placement and garbage collection by the
external test linker; they do not enable a Landin section or keep directive.
The flash-to-SRAM control forces a real call veneer while preserving the
selected core and physical RAM map.

The emitter performs no body sharing. Shared optimization and specialization
still transform verified IR before selection, preserving atom domains, stored
array/struct shapes, memory effects and private call-status validation. Hosted
body-sharing repairs remain unchanged. Code size is a retained physical-image
constraint, not a competitive-optimization claim.

D230 adds one u32 input/output in r0 to ordinary `assembler.block`. The input
is loaded from its verified value home and the result is saved before later
code. The existing low-register/flag clobbers and full opaque effects remain;
no high-register, frame or naked-body restriction is relaxed. `core/cpu` uses
MRS PRIMASK/CPSID I, MSR PRIMASK/ISB SY and DSB SY/WFI through this source
surface. CPU functions retain ordinary framed Landin calls in both thread and
handler mode. Its explicit barriers preserve D227, including the difference
between a compiler boundary and device completion. The freestanding consumers
retain map/module/helper closure evidence under the same fixed image profile.

### Runtime helper boundary

The external test link selects the pinned GCC 14.2.1
`thumb/v6-m/nofp/libgcc.a` (SHA-256
`137aa204587d2cefcc3eea90685a29d1e2f058a0a9cbdc29329e6f27c6249903`).
Helpers use the Arm base runtime ABI, not Landin's r12 failure outcome.
The [Arm runtime ABI](https://github.com/ARM-software/abi-aa/blob/2025Q4/rtabi32/rtabi32.rst)
and [GCC runtime description](https://gcc.gnu.org/onlinedocs/gccint/Libgcc.html)
are checked against actual linked code and execution.

| Helper family | Purpose and transport |
|---|---|
| `__aeabi_lmul` | low 64-bit product, two core-register pairs; checked selection first proves the product fits |
| `__aeabi_idivmod`, `__aeabi_uidivmod` | 32-bit quotient in r0 and remainder in r1 |
| `__aeabi_ldivmod`, `__aeabi_uldivmod` | 64-bit quotient in r0/r1 and remainder in r2/r3; also bounds checked multiplication |
| `__aeabi_fadd/fsub/fmul/fdiv`, `__aeabi_dadd/dsub/dmul/ddiv` | soft IEEE f32/f64 arithmetic in core bit carriers |
| `__aeabi_fcmp*`, `__aeabi_dcmp*` | ordered/equality predicates; inequality inverts equality |
| `__aeabi_i2f/ui2f/l2f/ul2f`, corresponding `*2d` | signed/unsigned integer-to-float rounding |
| `__aeabi_f2d`, `__aeabi_d2f` | float-width conversion with Landin's retained finite-overflow guard |

The linked archive is an external pinned compiler runtime dependency. Source
provenance includes GCC's [Arm integer routines](https://github.com/gcc-mirror/gcc/blob/releases/gcc-14.2.0/libgcc/config/arm/lib1funcs.S)
and [soft-float routines](https://github.com/gcc-mirror/gcc/blob/releases/gcc-14.2.0/libgcc/config/arm/ieee754-sf.S);
their headers carry GPLv3 with GCC Runtime Library Exception 3.1. Every image
retains requested helper names, archive path/hash, ELF/map/disassembly and an
empty undefined-symbol inventory. This links no libc, allocator, scheduler or
atomic emulation. Division guards prevent entering the archive's divide-zero
fallback; dependency members remain visible in the map. The firmware linker explicitly selects the pinned thumb/v6-m/nofp archive
with `-lgcc`. General runtime/CPU-library packaging remains R6.70.

The [execution guide](../environments/cortex-m/README.md#r650-compiler-generated-execution)
separates generated code, independent controls, target refusals and physical
limits. Compiler-owned startup is D229; Landin source debugging remains R6.100.


## Cortex-M0 firmware images

`--target=cortex-m0 --firmware-entry=NAME --emit=exe` selects the entry-module
source definition; its exported symbol may differ. `Backend.Firmware` generates
the reset source and linker script for the existing 32 KiB flash/16 KiB RAM
profile. The top 4 KiB of RAM is reserved for stacks, with eight-byte-aligned
initial MSP `0x20004000`. Static images cannot overlap `0x20003000`.
The 48-word vector image starts at zero. There is no VTOR relocation, FPU,
exclusive-access implementation or change of board. D229 owns the exact
implemented/reserved slots, typed handlers and ordinary/naked obligations.

The driver retains `OUTPUT.s`, `OUTPUT.o`, `OUTPUT.ld`, `OUTPUT.map` and the ELF.
The assembler uses Cortex-M0/Thumb/soft-float/AAPCS flags and fatal warnings.
The linker uses those flags plus `-nostdlib -nostartfiles -nodefaultlibs`, the
explicit generated script, `--gc-sections --build-id=none --emit-relocs` and
`-lgcc`. Host writes and invocations pass through `Landin.Platform`.
There is no implicit hosted startup, libc, allocator or scheduler. Source
library requests refuse. Assembler/linker failures retain the invoked tool's
diagnostic and driver failure status. ELF attributes and helper selection do
not enable the general C source surface.

`.text.*` and `.rodata.*` reside in flash; `.data.*`, `.bss.*` and `.ramtext.*`
execute in RAM, with flash load images for initialized data and RAM code.
Startup copies both load images and clears BSS before source entry. GNU ARM
veneers handle out-of-range calls between flash and RAM. Link assertions bound
physical images; L0505 independently bounds pre-GC static materialization to
8 MiB. Explicit symbol/section collisions and alignment/convention violations
refuse rather than silently changing requested placement. Section retention
is independent of calling convention, and a kept vector image retains its
referenced handlers. Linker symbols are private fixed assembly inputs, not
user-code module initialization or general static address arithmetic.

D232 enables the same canonical `core/panic` handler contract on Linux, Darwin
and Cortex. Default checks retain UD2/BRK/UDF termination. A selected handler
uses the ordinary two-scalar ABI and a four-byte private entry latch, with
process-wide exchange/exclusive synchronization on hosted targets and ordinary
single-core word accesses on ARMv6-M. No source atomics, FPU, cache, VTOR or
interrupt-masking helper are added on Cortex. Compiler startup clears the latch;
synthetic entry/root violations use site zero. Naked fallthrough and hardware
faults retain separate machine obligations. `--panic-map` is optional off-target
mapping, not Cortex source-debugger acceptance.

R6.80's [device fixture interface](../devices/README.md) preserves vendor
32-bit transaction sizes independently of field masks. Its real RP2040 address
constants are data, not a target/board selection. Execution explicitly remaps
a bounded peripheral subset while retaining the accepted M0 map and ABI;
RP2040's dual M0+ hardware is not claimed as an executable target.

R6.90's [driver evidence](../compiler/tests/driver/DERIVATION.md) uses the same
32 KiB flash, 16 KiB RAM and 4 KiB stack reservation. Compiler-owned firmware
links NOLOAD BSS with an explicit RAM LMA; initialized data and RAM code retain
flash load images. This prevents a zero-fill ELF segment inheriting a spurious
flash address. QEMU checks poisoned reset and vector/frame state; a separately
named Renode model executes the complete program's GPIO/timer/UART/DMA path.
Its finite count and drain acknowledgment are synthetic premises, not RP2040
or microbit peripheral behavior. No target layout, MMIO width or ABI changes.
