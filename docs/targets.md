# Target contracts

`spec.md` [1975] owns the language-facing C and link-name rules. ROADMAP.md
R5.20 records implementation evidence and dispositions; this page explains
the package boundaries, not a second work list.

| fact or operation | owner |
|---|---|
| pointer width, alignment, byte order, architecture, intended C ABI | `Landin.Targets` |
| implemented C signatures, records and variadic calls | `Landin.Targets.Capabilities` |
| object format, symbol prefix, available backend/debug format and triplet | `Landin.Targets.Capabilities` |
| source-level C subset eligibility | checking, using capability queries |
| physical C transport | backend ABI planner; currently guarded SysV only |
| frame preflight and emission selection | `Landin.Backend.Dispatch` |
| assembly, local labels, libc dependencies, register/frame placement and DWARF | concrete backend |
| logical hosted helper identities | `Landin.Hosted`, shared by checker and backend |
| GNU archive/build-id arguments | target-guarded `Landin.Backend.Toolchain` |
| C alias identities | ordinary `core/c`, guarded by the selected ABI fact |
| actual header/tool ABI verification | `bindings/generate.py`, explicit Clang target and sysroot |

The Linux and Darwin descriptions both use 64-bit pointers, eight-byte pointer
alignment, sixteen-byte stack alignment and little-endian storage. Equal widths
do not imply equal calling conventions. Darwin's description names its own ABI,
but C signatures, C records, variadic calls, backend and debugger availability
remain disabled until their roadmap owners implement them. Native Landin source
can be checked against `--target=darwin-arm64`; an emission request reports
L0500 before writing outputs or invoking tools. The default remains Linux. Existing in-process x86 assembly-text tests may
supply synthetic 32-bit layout facts while inspecting ELF text. That deliberate
test seam does not grant the synthetic target an emitter or toolchain; Darwin
facts are refused by the concrete x86 emitter as well as by driver dispatch.

Darwin layout facts follow Apple's
[ARM64 platform ABI](https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms).
The description does not claim Darwin argument allocation, varargs or C record
support. R5.30 owns those and the native linker policy; R5.40 owns Mach-O debug
identity and source debugging. The synthetic 32-bit description still supplies
an independent width control and has no object format or C ABI.

A logical external name such as `_entry` stays unchanged in checking and IR.
The target mapping yields `_entry` on ELF and `__entry` on Darwin. Quoting an
assembly operand is a later rendering step, and a leading underscore in source
does not escape the platform prefix. The same mapping applies to explicit
native names, C imports/exports and compiler-owned hosted helpers. Local labels
are allocated separately. Existing ELF spelling and golden records remain valid.

`core/c` deliberately continues to assert `compiler.c_sysv_lp64`; a Darwin
LP64 description cannot satisfy that identity. The binding generator separately
probes Clang's target macros and data model before writing its four outputs.
Neither a host pointer width nor an architecture name enables that contract.
There is no added language scalar or configuration fact in R5.20. The generator
and compiler remain separate tools, with their own independently tested guards.
