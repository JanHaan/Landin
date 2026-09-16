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
R6.50/R6.60 retain emission and startup. The original synthetic-32 goldens
remain unchanged.

## Cortex-M0 layout and ABI planning

R6.20 adds `Targets.Cortex_M` (`cortex-m0`), selecting ARMv6-M Thumb,
little endian and base AAPCS32 soft-float identity. `refine --target=cortex-m0`
checks source against these facts. Assembly/executable requests fail with
L0500 before writing output or invoking tools. Implemented C signatures,
records, varargs, object/debug output and a compiler toolchain triplet remain
disabled. The independent environment tools are not a compiler linker path.
`core/c` and the header generator still accept only their two hosted ABIs.

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
has 32 KiB flash, 16 KiB RAM and a 4 KiB stack reservation. Packed encodings,
over-aligned source types and deferred scalar widths are not enabled here.

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
at calls, and allocate no red zone below sp. This is an obligation for R6.50's
actual frame/emitter implementation, with a handwritten executable witness
here. GCC's C routines may use r7 as a local frame base; no continuous mixed-C
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
