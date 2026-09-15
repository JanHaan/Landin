# Target contracts

`spec.md` [1975] owns the language-facing C and link-name rules. ROADMAP.md
R5.20/R5.30 record implementation evidence and dispositions; this page explains
the package boundaries, not a second work list.

| fact or operation | owner |
|---|---|
| pointer width, alignment, byte order, architecture, intended C ABI | `Landin.Targets` |
| implemented C signatures, records and variadic calls | `Landin.Targets.Capabilities` |
| object format, symbol prefix, available backend/debug format and triplet | `Landin.Targets.Capabilities` |
| source-level C subset eligibility | checking, using capability queries |
| physical C transport | backend ABI planner; separate SysV and Darwin planners |
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
the driver. The default target remains Linux. `--debug=full` is refused for
Darwin before effects; R5.40 owns source debugging and Mach-O debug identity.
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
No GNU build-id flags reach the Darwin driver. Caller-source sidecars remain
available, but do not claim Mach-O debug identity.

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
