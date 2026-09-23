# Evidence registers

Four tables that say what the compiler's evidence is, rather than what is
left to do. They are source: `check.py` reads them, holds every row to the
fixture corpus, the compiler's named-refusal tables and the target records,
and generates `constructs.matrix`, `prototypes.matrix` and `targets.matrix`
from them. Edit a row here and regenerate; never edit a matrix.

They were kept in `ROADMAP.md` while the first roadmap built the compiler,
and moved here when it closed, unchanged. The Phase column and some
dispositions still name that roadmap's items; those citations resolve
against its index in `ROADMAP.md` until they are removed.

## Construct inventory

One row for every `[NNNN]` either `tour.md` or `spec.md` defines. It is
generated into `constructs.matrix`, where each row is joined with what the
corpus claims per product target, read from fixture metadata together with
`darwin/parity.json`, `cortex-m/corpus.json` and `driver/fixture.json`, and
with every named refusal and the wording of its [1830] note.

- **State.** `executed`: fixtures claim acceptance, emission and execution,
  and every applicable target outside the recorded gaps executes a claiming
  program. `compiled`: the observable behaviour is a compile-time verdict,
  acceptance with recorded IR or a refusal, that no run can observe more of;
  such a hosted row must also be in the hosted compile-time register below.
  `deferred`: the tour itself says DEFERRED and a live roadmap item owns the
  decision. `transferred`: the tour already assigns the construct to a named
  successor family. `advisory`: design, usage or process prose that adds no
  source behaviour a fixture could discriminate. A named refusal is not a
  state; it is part of a row.
- **Targets** are `all` (Linux x86-64, macOS arm64 and Cortex-M), `hosted`,
  `cortex-m` or `none`; `synthetic-32` is a pre-Cortex model and applies to
  no construct. **Gaps** are applicable targets without the state's
  evidence, and every gap needs an owning item.
- **Phase** is the item that first implemented the row.
- **Owners** are live roadmap items or successor families. A finished owner,
  an unknown owner or an owner the disposition does not mention is refused.
  A disposition of "matrix evidence" means the generated row's evidence is
  the whole explanation.

`check.py` holds all of it on every full run, and
`scripts/tests/test_construct_inventory.py` shows each refusal fires.

| Construct | State | Targets | Gaps | Phase | Owner | Disposition |
| --- | --- | --- | --- | --- | --- | --- |
| `[0010]` | executed | all | none | R1.20 | none | matrix evidence |
| `[0020]` | executed | all | none | R1.20 | none | matrix evidence |
| `[0030]` | executed | all | none | R1.20 | none | matrix evidence |
| `[0040]` | executed | all | none | R1.50 | none | matrix evidence |
| `[0050]` | executed | all | none | R1.50 | none | matrix evidence |
| `[0060]` | executed | all | none | R1.50 | none | matrix evidence |
| `[0070]` | executed | all | none | R2.50 | none | matrix evidence |
| `[0080]` | executed | all | none | R1.50 | none | matrix evidence |
| `[0090]` | executed | all | none | R3.10 | none | matrix evidence |
| `[0100]` | executed | all | none | R1.50 | none | Atom name lists and D233's shared binding, field, parameter and return names are matrix evidence on all three targets. The inferred `a, b := e` shape and the declarations that keep one name are D233's recorded boundary, named by R7.20 in the refusal note. |
| `[0110]` | executed | all | none | R1.50 | none | matrix evidence |
| `[0120]` | executed | all | none | R2.20 | none | matrix evidence; R2.20 records the named `type` source-form boundary |
| `[0130]` | executed | all | none | R1.50 | none | matrix evidence |
| `[0140]` | executed | all | none | R1.50 | none | matrix evidence |
| `[0150]` | executed | all | none | R4.10 | Language evolution | The enabled widths are matrix evidence. D237 transfers u128 and i128 to Language evolution, triggered by a program that needs 128-bit arithmetic; the checker's named refusal says R7.20 transfers them. Arbitrary packed widths are D228's, admitted only in packed fields [0730]. |
| `[0160]` | executed | all | none | R2.10 | none | matrix evidence |
| `[0170]` | executed | all | none | R4.10 | Language evolution | f32 and f64 are matrix evidence. D237 transfers f16 to Language evolution, triggered by a program that needs binary16 values; the checker's named refusal says R7.20 transfers it. |
| `[0180]` | executed | all | none | R1.60 | none | matrix evidence |
| `[0190]` | executed | all | none | R1.60 | none | matrix evidence |
| `[0200]` | executed | all | none | R1.60 | none | matrix evidence |
| `[0210]` | executed | all | none | R4.10 | none | matrix evidence |
| `[0220]` | executed | all | none | R4.10 | none | matrix evidence |
| `[0230]` | executed | all | none | R4.10 | none | matrix evidence |
| `[0240]` | executed | all | none | R4.10 | none | matrix evidence |
| `[0250]` | executed | all | none | R4.10 | none | matrix evidence |
| `[0260]` | executed | all | none | R4.10 | none | matrix evidence |
| `[0270]` | executed | all | none | R4.10 | none | matrix evidence |
| `[0280]` | executed | all | none | R4.10 | none | matrix evidence |
| `[0290]` | executed | all | none | R1.60 | none | matrix evidence |
| `[0300]` | executed | all | none | R1.60 | none | matrix evidence |
| `[0310]` | executed | all | none | R1.60 | none | matrix evidence |
| `[0320]` | executed | all | none | R1.60 | none | matrix evidence |
| `[0330]` | executed | all | none | R1.60 | none | matrix evidence |
| `[0340]` | executed | all | none | R1.60 | none | matrix evidence |
| `[0350]` | executed | all | none | R1.60 | none | matrix evidence |
| `[0360]` | executed | all | none | R1.60 | none | matrix evidence |
| `[0370]` | executed | all | none | R2.10 | none | matrix evidence |
| `[0380]` | executed | all | none | R2.50 | none | matrix evidence |
| `[0390]` | executed | all | none | R1.60 | none | matrix evidence |
| `[0400]` | executed | all | none | R1.60 | none | matrix evidence |
| `[0410]` | executed | all | none | R1.60 | none | matrix evidence |
| `[0420]` | executed | all | none | R1.60 | none | matrix evidence |
| `[0430]` | executed | all | none | R2.50 | none | matrix evidence |
| `[0440]` | executed | all | none | R2.50 | none | matrix evidence |
| `[0450]` | executed | all | none | R2.50 | none | matrix evidence |
| `[0460]` | executed | all | none | R2.50 | none | matrix evidence |
| `[0470]` | executed | all | none | R2.50 | none | matrix evidence |
| `[0480]` | executed | all | none | R4.10 | none | The one-atom optional pointer (D189) and D235's several-atom union, the atom's code beside the pointer, are matrix evidence on all three targets, with GDB and LLDB presentation of both cases. |
| `[0490]` | advisory | none | none | none | none | Usage guidance: pointers serve hardware, the C boundary and library internals, while everyday code uses slices, handles and indices. It states no rule the compiler enforces or a fixture could discriminate; the operations it points to are [0430]-[0480]'s rows. |
| `[0500]` | executed | all | none | R4.20 | none | D196 records `offset` and `base_of` as unneeded; D151 rejects `slice_from`; ordinary address conversion remains the implementation |
| `[0510]` | executed | all | none | R3.30 | none | matrix evidence |
| `[0520]` | executed | all | none | R2.20 | none | Array values, bounds and copies are matrix evidence; D241 adds whole-array discards and inferred literals of any element shape. Its checker refusals of the remaining forms are D241's recorded boundaries, named by R7.20 in the note, and genuine type errors among them are L0301. |
| `[0530]` | executed | all | none | R2.20 | none | matrix evidence |
| `[0540]` | executed | all | none | R2.20 | none | Zero images are matrix evidence. The local-array `zeroed` refusal is a guard no source reaches; D241 keeps it with R7.20's boundary wording, and `zeroed` as an operand is an L0301 type error. |
| `[0550]` | executed | all | none | R2.60 | none | matrix evidence |
| `[0560]` | executed | all | none | R2.20 | none | Typed, counted and mixed repetition are matrix evidence; R2.20 records the named repetition source-form boundary. D241, an R7.20 decision, records the count-less inferred initializer, non-scalar counted inference and zero lengths as the paragraph's boundary. |
| `[0570]` | executed | all | none | R2.20 | none | matrix evidence; R2.20 records the named indexing source-form boundary, which requires a named place |
| `[0580]` | executed | all | none | R2.20 | none | matrix evidence |
| `[0590]` | executed | all | none | R4.50 | none | D209 and matrix evidence |
| `[0600]` | executed | all | none | R4.10 | none | matrix evidence |
| `[0610]` | executed | all | none | R4.10 | none | matrix evidence |
| `[0620]` | transferred | none | none | none | Language evolution | The tour keeps structure-of-arrays as a DEFERRED design record and now says Language evolution holds it: R7.30 transfers inherited C5 there under R551-35, because none of the four derived programs is a simulation that needs one field contiguous. Nothing enables `soa`, which meets an ordinary parse error, and no named refusal is owed to a form the tour places outside the language. |
| `[0630]` | executed | all | none | R2.20 | none | matrix evidence |
| `[0640]` | executed | all | none | R2.20 | none | matrix evidence |
| `[0650]` | executed | all | none | R2.20 | none | named refusal |
| `[0660]` | executed | all | none | R4.10 | none | Scalar range subtypes are matrix evidence under D188. D236 records the struct-field, array-element, reference-target, `addr` and generic-argument positions as the paragraph's permanent boundary, and their named refusals say R7.20 records it. |
| `[0670]` | executed | all | none | R2.20 | none | Both struct forms are matrix evidence; R2.20 records the named inline-struct source-form boundary. D241 adds whole-struct discards and inferred struct copies, makes misused struct values L0301 type errors, and records the untyped literal and module-image forms as boundaries whose note names R7.20. |
| `[0680]` | executed | all | none | R2.20 | none | Variant declaration, storage, construction and matching are matrix evidence, and D241 gives payload arrays every ordinary array-field expression. A variant part as a value, a case outside its part and a copied part are D241's recorded boundaries, named by R7.20 in the note. |
| `[0690]` | executed | all | none | R2.20 | none | matrix evidence |
| `[0700]` | executed | all | none | R2.20 | none | matrix evidence |
| `[0710]` | executed | all | none | R2.20 | none | matrix evidence |
| `[0720]` | executed | all | none | R2.20 | none | matrix evidence; R2.20 records the named all-`of` literal source-form boundary |
| `[0730]` | executed | all | none | R6.80 | Companion tool and ecosystem | D228 packed images, encoded unions and named-boolean set fields are matrix evidence on all three targets, the derived driver on Cortex-M. D238, an R7.20 decision, withdraws the `set(X)` former, whose unresolved application meets [1350]'s ordinary refusal. General SVD generation stays with Companion tool and ecosystem under R551-33, as the paragraph says. |
| `[0740]` | executed | all | none | R6.80 | none | D228 access modes and register operations are matrix evidence, including the generated RP2040 consumers and the derived driver. D238, an R7.20 decision, withdraws the `register(t, read:, write:, reset:)` wrapper, which remains an ordinary parse error. |
| `[0750]` | executed | all | none | R2.20 | none | Source order, optimal and C layout are matrix evidence. D239, an R7.20 decision, withdraws per-field byte order; `negative/r720-field-byte-order-withdrawn` pins that `big u16` is an ordinary field error. |
| `[0760]` | executed | all | none | R6.80 | none | The enabled attributes are matrix evidence, including Cortex-M placement. R7.20 withdraws `volatile` with its pointer type (D238) and `big`, `little`, `weak`, `inline` and `noinline` (D239); `negative/r720-machine-attribute-words-withdrawn` pins `link(weak)`. |
| `[0770]` | executed | all | none | R2.50 | none | matrix evidence |
| `[0780]` | executed | all | none | R2.50 | none | matrix evidence |
| `[0790]` | executed | all | none | R2.50 | none | matrix evidence |
| `[0800]` | executed | all | none | R2.50 | none | matrix evidence |
| `[0810]` | executed | all | none | R4.20 | none | D196 states [0470]'s actual derivation cut; the `pointer.integer-origin` evidence pins its non-guarantee |
| `[0820]` | executed | all | none | R4.80 | none | D212 withdraws the lexical block and builtin parameter type, and R4.80 keeps their named withdrawal diagnostics; explicit ordinary allocator authority, capacity and cleanup replace the unsupported transitive escape promise |
| `[0830]` | executed | all | none | R2.50 | none | matrix evidence |
| `[0840]` | executed | all | none | R2.50 | none | matrix evidence |
| `[0850]` | executed | all | none | R6.80 | none | D227 volatile scalar access is matrix evidence on all three targets. D238 withdraws the `volatile ptr` type; its named L0010 now says R7.20 withdraws it and names the explicit volatile and register operations. |
| `[0860]` | executed | all | none | R2.50 | none | matrix evidence |
| `[0870]` | executed | all | none | R2.30 | none | matrix evidence |
| `[0880]` | executed | all | none | R2.30 | none | matrix evidence |
| `[0890]` | executed | all | none | R2.30 | none | `none` has matrix evidence; `noreturn` has a named refusal owned by R6.70 |
| `[0900]` | executed | all | none | R2.50 | none | matrix evidence |
| `[0910]` | executed | all | none | R2.50 | none | matrix evidence |
| `[0920]` | executed | all | none | R2.30 | none | matrix evidence |
| `[0930]` | executed | all | none | R2.30 | none | matrix evidence |
| `[0940]` | executed | all | none | R2.30 | none | matrix evidence |
| `[0950]` | executed | all | none | R2.30 | none | matrix evidence |
| `[0960]` | executed | all | none | R2.30 | none | matrix evidence |
| `[0970]` | executed | all | none | R2.30 | none | matrix evidence |
| `[0980]` | executed | all | none | R2.30 | none | matrix evidence |
| `[0990]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1000]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1010]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1020]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1030]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1040]` | executed | all | none | R4.10 | none | D192 and matrix evidence |
| `[1050]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1060]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1070]` | executed | all | none | R4.10 | none | D185 and matrix evidence |
| `[1080]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1090]` | executed | all | none | R2.30 | none | Unlabelled `begin`/`end` blocks and D234's labelled bare blocks, left by a `break` naming them with their cleanups run, are matrix evidence on all three targets. |
| `[1100]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1110]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1120]` | executed | all | none | R4.10 | none | D187 and matrix evidence; the division, shift, bool, float and text edges it never removes are named there rather than refused |
| `[1130]` | executed | all | none | R4.10 | none | matrix evidence |
| `[1140]` | executed | all | none | R4.10 | none | matrix evidence |
| `[1150]` | executed | all | none | R4.10 | none | matrix evidence |
| `[1160]` | executed | all | none | R4.10 | none | matrix evidence |
| `[1170]` | executed | all | none | R4.10 | none | matrix evidence |
| `[1180]` | executed | all | none | R4.10 | none | Loop labels and D234's bare-block labels are matrix evidence on all three targets; `continue` naming a block and `break with` targeting one are refused. R7.30 found inherited E1's watch inconclusive, since no derived program or `core` uses a label, `break with` or `complete`, and transferred the watch to Language evolution; the construct stays implemented. |
| `[1190]` | executed | all | none | R4.10 | none | matrix evidence |
| `[1200]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1210]` | executed | all | none | R2.20 | none | matrix evidence |
| `[1220]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1230]` | executed | all | none | R2.60 | none | matrix evidence |
| `[1240]` | executed | all | none | R2.60 | none | matrix evidence |
| `[1250]` | executed | all | none | R2.60 | none | matrix evidence |
| `[1260]` | executed | all | none | R2.60 | none | matrix evidence |
| `[1270]` | compiled | all | none | R2.60 | none | Hosted compile-time rule audited by R4.90: conformance keys include their input tuples. R7.40 supplies the Cortex-M verdict rather than arguing the rule is target-neutral: `negative/r740-cortex-conformance-input-keys` compiles the colliding program for `cortex-m0` and records the same L0317 report, byte for byte, as the two hosted targets make. |
| `[1280]` | executed | all | none | R2.60 | none | matrix evidence |
| `[1290]` | executed | all | none | R2.40 | none | matrix evidence; R2.40 records the named type-parameter source-form boundary |
| `[1300]` | executed | all | none | R2.40 | none | matrix evidence |
| `[1310]` | executed | all | none | R2.70 | none | Evidence tables from R2.70 and D211's proved specialization and build report from R4.50 are matrix evidence; no delayed part remains, so R7.20's exit clause for [1310] can cite this evidence. |
| `[1320]` | executed | all | none | R2.60 | none | matrix evidence |
| `[1330]` | executed | all | none | R4.10 | none | matrix evidence |
| `[1340]` | executed | all | none | R2.60 | none | matrix evidence |
| `[1350]` | executed | all | none | R2.40 | none | Parameterized declarations are matrix evidence. Malformed applications are D135's recorded boundary, and R7.40 corrected the note that promised them from the finished R2.40: it now says R2.40 records this source-form boundary, which `negative/r740-parameterized-application-boundary` pins byte for byte. `set(X)`, which D238 withdrew, meets this refusal as an unresolved application. |
| `[1360]` | executed | all | none | R3.20 | none | matrix evidence |
| `[1370]` | executed | all | none | R2.80 | none | matrix evidence |
| `[1380]` | executed | all | none | R2.80 | none | matrix evidence |
| `[1390]` | executed | all | none | R2.80 | none | matrix evidence |
| `[1400]` | compiled | all | none | R2.80 | none | Hosted compile-time rule audited by R4.90: heterogeneous implicit boxing is refused. R7.40 supplies the Cortex-M verdict: `negative/r740-cortex-inferred-element-mismatch` records the same L0301 report there, byte for byte, as the two hosted targets make. |
| `[1410]` | executed | all | none | R3.10 | none | matrix evidence |
| `[1420]` | executed | all | none | R3.10 | none | matrix evidence |
| `[1430]` | executed | all | none | R4.30 | none | D201 aliases retain file-local namespace lookup |
| `[1440]` | executed | all | none | R4.30 | none | D201 selected imports retain original public declaration identities |
| `[1450]` | executed | all | none | R3.10 | none | matrix evidence |
| `[1460]` | executed | all | none | R1.60 | none | matrix evidence |
| `[1470]` | transferred | none | none | R3.10 | Companion tool and ecosystem | Versions, origins, owner/package naming and the version-conflict error belong to Companion tool and ecosystem, which [1480] says arranges the roots so only one version is reachable; inherited D6 and R551-33 carry the transfer, which R7.30 records as D6's terminal disposition. The compiler's share is [1420]'s first-root rule from R3.10, covered by the driver and resolution suites rather than a fixture claim. |
| `[1480]` | executed | all | none | R4.30 | Companion tool and ecosystem | Explicit ordered roots are matrix evidence from R4.30. Root defaults for the project, user home and system, fetching, version solving, locks and naming authority are Companion tool and ecosystem's under R551-33, as the paragraph says. |
| `[1490]` | executed | all | none | R2.40 | none | matrix evidence |
| `[1500]` | executed | all | none | R2.40 | none | matrix evidence |
| `[1510]` | executed | all | none | R4.30 | none | D202 and fixed assertion fixtures |
| `[1520]` | executed | all | none | R2.40 | none | matrix evidence |
| `[1530]` | executed | all | none | R4.30 | none | D202 and deterministic typed option cases |
| `[1540]` | executed | all | none | R2.40 | none | matrix evidence |
| `[1550]` | advisory | none | none | none | none | Toolchain policy: Landin keeps its own native backends, not LLVM or C. R1.90 left the row bare because no fixture can discriminate it; four later claims were D211, D229 and D230 evidence and R7.10 removed them. Its concrete obligations are other rows' and lanes': the [1570] and [1650] conventions, [1990] firmware, the quality determinism rebuild and the native debugger frame checks. |
| `[1560]` | executed | all | none | R4.30 | none | Compiler facts and assertions, `linker.library`, atomics, volatile and register operations and Cortex-M assembly and placement are matrix evidence; other tool operations meet named refusals. D240, an R7.20 decision, withdraws the `compiler` vector intrinsics in favour of [0590]'s element-wise operators, pinned by `negative/r720-vector-intrinsic-withdrawn`. |
| `[1570]` | executed | all | none | R3.50 | none | `extern(c)`, `extern(interrupt)` and `extern(naked)` are matrix evidence; the derived driver's interrupt handlers execute on Cortex-M. `aapcs`, `sysv`, `win64`, Fortran and Swift are named as room for later conventions, not described constructs. |
| `[1580]` | executed | hosted | none | R4.40 | none | The hosted C boundary is matrix evidence under D203--D205. R7.40 found the checker's [1580] refusal entry unreachable and removed it: the categories the paragraph lists are refused where they are written, as the C boundary's own L0301 naming [1580] and listing them, which `negative/r740-c-category-boundary` pins byte for byte. Cortex-M C signatures are not enabled, an R6.20 restriction that is R730-07's. |
| `[1590]` | executed | hosted | none | R4.30 | none | Hosted archive linkage: Linux runtime evidence and Darwin's native archive-selection replacement under R4.30 and R5.50; Cortex-M refuses the general C surface. |
| `[1600]` | executed | hosted | none | R4.40 | none | Hosted C definitions from R4.40 are matrix evidence; Cortex-M C signatures are restricted. |
| `[1610]` | executed | all | none | R4.40 | none | Native and C link names are matrix evidence on both hosts. R7.40 attributes the Cortex-M evidence that executes outside the fixture corpus: R6.60's `firmware-machine` probe gives a module datum and a native function their link names, and its QEMU session resolves both written symbols in the linked image, recorded in `compiler/tests/cortex-m/probes.json`. The `extern(c)` half stays disabled there by R6.20 and is R730-07's. |
| `[1620]` | executed | all | none | R6.30 | Broader standard library | D227 scalar atomics, orderings and barriers are matrix evidence on all three targets. D240, an R7.20 decision, transfers the wrapper type to Broader standard library under R551-34, as the paragraph now says. |
| `[1630]` | executed | cortex-m | none | R6.60 | none | Cortex-M0 `assembler.block` under D229 and D230 executes in the derived driver and firmware lanes; hosted targets refuse machine assembly by design. |
| `[1640]` | executed | cortex-m | none | R6.60 | none | Cortex-M placement, vectors and keep under D229 execute in the derived driver; hosted targets refuse placement by design. |
| `[1650]` | executed | all | none | R1.80 | none | matrix evidence |
| `[1660]` | executed | hosted | none | R3.50 | none | matrix evidence; the freestanding root is [0460]'s address literal |
| `[1670]` | executed | all | none | R1.80 | none | matrix evidence |
| `[1680]` | executed | hosted | none | R3.60 | none | Capabilities minted at the hosted entry and passed below it are matrix evidence. The freestanding root is [0460]'s address literal, which the paragraph states is a habit rather than an enforced rule. R7.30 transferred inherited C3's tightening to Language evolution untriggered: no program here runs untrusted code. |
| `[1690]` | executed | all | none | R2.50 | none | matrix evidence |
| `[1700]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1710]` | advisory | none | none | none | none | The admission test for a new language feature, a design-process rule. It adds no source behavior; R7.30 dispositioned the parked and watch items it governs in the inherited register. |
| `[1720]` | executed | all | none | R2.90 | none | matrix and guarantee evidence; its stated non-guarantees execute |
| `[1730]` | compiled | all | none | R4.10 | none | `positive/range-subtypes`' recorded IR shows a range-subtype value carrying its proof with no check under D188, a hosted compile-time rule in R4.90's audited register; R7.10 dropped two claims that could not observe elision. R7.40 supplies the Cortex-M verdict on that same fixture, which now also records an accepted `cortex-m0` compilation of its own program. That verdict is acceptance and not a second recorded IR because the elision is a property of the target-neutral IR, which no target selects, and a duplicate program would have added a duplicate IR record for nothing. |
| `[1740]` | executed | all | none | R3.10 | none | matrix evidence |
| `[1750]` | executed | all | none | R1.20 | none | matrix evidence |
| `[1760]` | executed | all | none | R1.20 | none | matrix evidence |
| `[1770]` | executed | all | none | R4.10 | none | matrix evidence |
| `[1780]` | executed | all | none | R1.20 | none | matrix evidence |
| `[1790]` | executed | all | none | R1.60 | none | matrix evidence |
| `[1795]` | executed | all | none | R2.20 | none | matrix evidence |
| `[1800]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1810]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1820]` | executed | all | none | R1.40 | none | matrix evidence |
| `[1830]` | compiled | all | none | R1.30 | none | Hosted compile-time rule: a refusal by name is a diagnostic and nothing executes it. `negative/cortex-refused-type-named` records the same L0304 report for `cortex-m0`, byte for byte, as the two hosted targets make. |
| `[1840]` | executed | all | none | R1.50 | none | matrix evidence |
| `[1850]` | executed | all | none | R1.50 | none | matrix evidence |
| `[1860]` | compiled | all | none | R1.50 | none | Hosted compile-time rule audited by R4.90. R7.40 supplies the Cortex-M verdict: `negative/r740-cortex-name-declared-nowhere` records the same L0201 report for `cortex-m0`, byte for byte, as the two hosted targets make. |
| `[1870]` | executed | all | none | R1.60 | none | matrix evidence |
| `[1880]` | executed | all | none | R1.60 | none | matrix evidence |
| `[1890]` | executed | all | none | R1.60 | none | matrix evidence |
| `[1900]` | executed | all | none | R1.60 | none | matrix evidence |
| `[1910]` | executed | all | none | R1.60 | none | matrix evidence |
| `[1920]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1930]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1940]` | executed | all | none | R1.60 | none | matrix evidence |
| `[1950]` | executed | all | none | R1.60 | none | matrix evidence |
| `[1960]` | executed | all | none | R1.80 | none | matrix evidence |
| `[1970]` | executed | hosted | none | R1.80 | none | matrix evidence; the hosted entry shape |
| `[1975]` | executed | hosted | none | R3.50 | none | matrix evidence; Cortex-M C boundaries are restricted |
| `[1980]` | executed | all | none | R2.30 | none | matrix evidence |
| `[1990]` | executed | cortex-m | none | R6.60 | none | D229 and D230 firmware and machine directives execute through compiler-owned firmware and the derived driver; hosted targets select them away. |

## Hosted compile-time evidence

These rules are observed while compiling. Every other hosted row in the
inventory requires a Linux runtime or ABI fixture with a program and an
attributed construct; a `compiled` hosted row must appear here instead, with
the fixtures that accept and refuse it. The metadata is an auditable claim,
not proof of the source oracle's adequacy. This table does not withdraw any
construct.

| Construct | Accepted | Refused | Rationale |
| --- | --- | --- | --- |
| `[1270]` | `positive/r490-conformance-input-keys` | `negative/conformance-collision`, `negative/r490-conformance-input-alias-collision` | Whole-program conformance keys include normalized input tuples; unequal keys coexist and equal keys collide before runtime. |
| `[1400]` | none | `negative/local-array-literal-inferred-element-mismatch` | Heterogeneous implicit boxing is deliberately absent; mismatched element types are rejected. Ordinary explicit `any` dispatch has separate executed rows. |
| `[1730]` | `positive/range-subtypes` | none | A range-subtype value carries its proof between constrained positions; the recorded IR has no second check. A run cannot observe an elided check, so R7.10 moved this row here from its former principle class. |
| `[1830]` | none | `negative/float-type-not-enabled`, `negative/indexing-not-enabled` | A construct the tour describes and the kernel has not enabled is refused with a diagnostic that names it and the work that enables it; the observable behaviour is that diagnostic. |
| `[1860]` | none | `negative/name-declared-nowhere`, `negative/condition-declaration-out-of-scope` | Every name must resolve in its scope; the observable failure is a compiler diagnostic. |

## Prototype derivation coverage

A row means the fixture is a completed executable or negative derivation of
the named pressure, not merely that it uses a construct the prototype also
used. Source line numbers in the generated `prototypes.matrix` are recovered
from the finding labels, so moving prose cannot stale a hand-copied location,
and each row's inputs, outputs and per-target results are derived from the
fixture's own record rather than asserted here.

| Fixture | Prototype | Findings | Pressure |
| --- | --- | --- | --- |
| `firmware/derived-driver` | P1 | X1, X2, X3, X4, X5, X6, X7, X8, X9 | complete driver/application and explicit declaration/finding adaptations in `compiler/tests/driver/DERIVATION.md`; compiler-owned QEMU reset and independent synthetic Renode protocol execution |
| `negative/r630-frame-dma` | P1 | X6, X8 | tracked frame buffer cannot escape through a DMA descriptor |
| `abi/r630-dma-slice` | P1 | X6, X8 | escaping ordinary slice, serialized external byte writes, completion boundary and ordinary reads/copy |
| `runtime/diagnostic-loggers-dispatch` | P2 | Y1 | recoverable diagnostics use a bounded or streaming capability without becoming parser failure |
| `runtime/derived-parser` | P2 | Y1, Y4, Y5, Y6, Y7 | a complete recursive parser builds an arena AST, logs and recovers from syntax faults, and propagates allocation or diagnostic-delivery failure through shared erased evidence |
| `runtime/derived-containers` | P3 | Z1, Z2, Z3, Z4, Z5, Z6, Z7, Z8, Z9, Z10, Z11, Z12, Z13, Z14, Z15, Z16, Z17, Z18, Z19 | the complete client composes initialized containers, explicit and failing providers, sorting, tree and heterogeneous evidence; its derivation manifest distinguishes executable resolutions from preserved no-gap or superseded sketches |
| `negative/r470-container-entry-live-map` | P3 | Z5, Z16 | a pointer-bearing enumerated entry keeps its map live across insertion and release |
| `negative/r470-container-entry-wrong-from` | P3 | Z5 | entry extraction retains the exact map origin |
| `negative/r470-container-missing-order-evidence` | P3 | Z2 | a constrained generic application call requires its concrete ordering conformance |
| `runtime/parameterized-struct-values` | P3 | Z2 | type and fixed parameters on nominal values |
| `runtime/r250-references` | P3 | Z3, Z18 | pointer/slice carriers and implicit conventions |
| `negative/borrowed-source-inout` | P3 | Z5, Z16 | a derived view prevents moving its source |
| `runtime/variant-match-payload-bindings-update-storage` | P3 | Z7, Z14 | pattern conventions and payload-free cases |
| `runtime/generic-declared-errors` | P3 | Z9 | concept entries retain concrete declared errors |
| `runtime/generic-composed-evidence` | P3 | Z11 | explicit direct and parent conformances compose |
| `negative/sink-through-dereference` | P3 | Z12, Z13 | inout/sink place and permission boundary |
| `runtime/struct-literal-order-and-fill` | P3 | Z17 | contextual anonymous aggregate construction |
| `runtime/undo-cleanups-follow-failure-edges` | P3 | Z19 | failure cleanup moves its arguments at execution |
| `runtime/generic-parameterized-evidence` | P3 | Z1, Z4 | parameterized providers receive target-derived evidence |
| `runtime/allocator-vec-pressure` | P3 | Z6 | an escaping generic value parameter is vacuous for a scalar item and exact for a pointer item |
| `negative/parameterized-conformance-entry-signature-mismatch` | P3 | Z1, Z4 | substituted provider signatures must agree |
| `runtime/derived-hosted-memory` | P4 | W1, W2, W3, W4, W5, W6, W7 | the complete log-filter application selects filters and destinations from retained arguments, reads whole lines across arbitrary chunks, buffers messages with explicit retry, and closes handles through the supplied world |
| `runtime/r480-arena-independent-results` | P4 | W7 | simultaneous ordinary allocations and helper-returned pointers, aggregates, slices, any and callback state remain independent; a helper-retained pointer survives the provider frame without passing a returned-value boundary |
| `runtime/r480-arena-nested-exhaustion` | P4 | W3, W7 | explicitly backed nested providers exhaust independently and ordinary defer runs across normal, failure, return, break and continue exits |
| `negative/r480-callback-frame-escape` | P4 | W6, W7 | ordinary callback-state aggregates retain the tracked frame escape refusal |
| `negative/r480-helper-frame-retention` | P4 | W7 | a helper still cannot retain a tracked nonescaping frame reference in module storage |
| `runtime/constant-return-exits-with-its-code` | P4 | W2 | hosted entry uses the ordinary no-argument shape |
| `runtime/generic-composed-evidence` | P4 | W4 | a narrow concept composes rather than widening |
| `runtime/any-heterogeneous-dispatch` | P4 | W6 | erased state retains mutable permission and dispatch identity |
| `negative/any-frame-origin-escape` | P4 | W6 | erased state retains pointee origin |

## Target applicability coverage

These are applicability assignments, not backend claims. Fixture metadata
makes the finer assignment and `targets.matrix` lists every fixture; a
missing `targets:` is a gate failure. `synthetic-32` is the executable target
model used before the Cortex-M backend existed.

| Scope | Targets |
| --- | --- |
| `prototype-1` | cortex-m |
| `prototype-2` | linux-x86-64, macos-arm64 |
| `prototype-3` | linux-x86-64, macos-arm64, cortex-m, synthetic-32 |
| `prototype-4` | linux-x86-64, macos-arm64 |
