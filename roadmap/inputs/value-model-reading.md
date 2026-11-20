# R19.20's input: the checker read against D24-D109

*Read by R19.10 on 2026-11-20 over `4166d7848`, read-only, for Q-81 (SC-24 and
SC-25). It samples, and says what it sampled; R19.20 confirms it against
every citation if SC-24 is taken. It is not edited once R19.20 is complete.*


The input's "about eight rules" needs about eleven. Most of the compiler's citations are comments on code that is already general, but there are a few real per-slice branches, mostly in how bindings and assignments are checked. I sampled rather than read everything; what I sampled is listed at the end.

### 1. D24-D109 by surviving rule

| Rule they fold into | Decisions | Still decides something today? |
|---|---|---|
| D29 write order | D29, D32, D36, D37 | yes: elements are stored as they are evaluated, a repeat is evaluated once, the prefix is stored before the suffix |
| D10/D24 static images | D24, D26, D27, D34, D35, D38, D39, D59-D61, D66-D71, D81-D83 | yes for D24 (folding), D34/D38 (repeated and hybrid image encodings) and D66/D67/D81 (descriptor runs); no for the rest, which are module-position cells |
| An array is definitely assigned as a whole | D29, D32, D92, D93, D95, D96, D102, D104 | yes: a whole read needs every element assigned, and a variant needs its case selected before it crosses a call |
| D76 case before payload | D76, D79, D84, D103 | yes for D76; no for the others, which are cells |
| D78/D85 arm aliasing | D78, D85 | yes |
| D86-D91 nesting | D86-D93 | D86's child layout yes; D87-D93 no (D118/D119 allow any depth) |
| D94-D109 by-value transport | D94, D95, D97-D99, D106-D109 | yes: callee slot, zero carrier, argument temporary, hidden result pointer |
| | D96, D100, D101, D102, D104, D105 | no, these are admission cells |
| D241 boundaries | D25, D33 | yes: the first element sets the type; a counted repetition infers only a scalar element |
| Superseded by [1880]/D241 | D28, D30, D40-D43, D46-D58, D62, D64, D65, D75, D80 | no |
| | D63, D73 | no: these refused syntax that was not yet enabled |
| **Missing from the input's eight** | D31 (`lenof` measures a literal without forming it), D44/D45/D74 (layout and measurement, [0750]), D77 (exhaustive tag match, with D405), D72 (`T(...)` construction syntax) | yes |

### 2. Do the checker and lowering still have one path per slice?

The citations are 491 occurrences on 376 lines:
- 137 lines in `compiler/ada/src/stages/landin-stages-checking.adb`, 41 in lowering, 11 in flow, 6 in references, 2 in folding.
- About 13 occurrences in `compiler/ada/src/diagnostics/landin-diagnostics-explanations.adb` are false positives: wrapped strings that cite D405, D472, D973 and so on.
- 48 occurrences sit inside strings users see (diagnostic notes, the catalogue, explanations). About 18 `expected.txt` fixtures and `compiler/tests/diagnostics.catalogue` quote them, so re-pointing those changes test expectations.

The general rule already exists: `Check_Contextual_Value` (checking.adb:37093-38135) checks every value form against one expected context. Calls (`Check_Call`, 17023), struct-literal labels (31633), blocks, returns and expressions all go through it. Lowering likewise has one general routine, `Write_Shaped_Value`, behind `Write_Array_Value` (lowering.adb:13685).

- **Comment-only on general code:** about 330 lines. They describe general code, or representation and ABI that stays (the IR image descriptors, the D97 zero carrier, the D106 hidden result pointer, the backends). For these, a fold is re-pointing comments.
- **On real per-slice branches:** about 45 lines, in these places:

| Site | What it special-cases | Removed by a uniform rule? | Rough lines |
|---|---|---|---|
| checking.adb:10840-11255, the gate in `Declared_As_Node` | About 20 `Is_*_Init` predicates, one per form × kind × local/module, then two allow-lists and `Gate_Refuses` | Yes. Only the module boundary ([1940]) remains; everything else falls to L0301 | ~300 → ~60 |
| checking.adb:34646-34990, binding initializer | Repeats `Check_Contextual_Value`'s dispatch by form (construction, `zeroed`, case, copy, literal, repetition, mixed) | Yes, becomes one call. Related sites and "because" labels change | ~300 → ~30 |
| checking.adb:35310-35760, assignment | The same duplicate dispatch, plus the D49/D50 pre-pass that admits an array field | Yes | ~350 → ~40 |
| checking.adb:25492-25573, `Admit_Array_Field` (32 references) | An array field is typed only when a caller opts in (D48-D51 heritage) | Yes, if array fields are typed in `Selected_From` everywhere. The riskiest change | ~80 plus call sites |
| checking.adb:26354-26420, `lenof [..]` | Elements must be scalars (D31), which lags D241's literals of any element shape; D241 does not record this boundary | Yes: use `Infer_Value`'s first-element rule | ~70 → ~15 |
| checking.adb:39020-39110, counted-repetition inference | Infers only a scalar element (a D241 boundary) | Lifted only if SC-24's rule is taken; this is a language change | ~30 changed |
| lowering.adb:14684-14790, `Lower_Binding_Statement` | Literal, mixed, repetition and `zeroed` stored inline, where `Write_Array_Value` already exists | Yes, becomes one call; needs the build-modes comparison | ~110 → ~10 |
| checking-flow.adb:140-200 | A dense depth-one fact table beside `Nested_Fact` | No: the split is kept for indexing speed. Line 130's mention of a "parent/child set" is a stale comment | 0 |

Code that stays: `Check_Module_Value` ([1940]), `Admit_Variant_Field` (a variant part has no value), the static-image encodings in IR, lowering and backends, the case-first ordering, and the alias handling.

### 3. Size of the compiler side: M

The contexts axis is already general in calls, fields, returns and control values. What remains is two hand-written duplicates of the general dispatch (bindings and assignment) plus the declaration gate. That is about 950 lines, which would collapse to about 150. The harder parts are `Admit_Array_Field` and two small inference lags. IR and backends are untouched. Re-pointing the 376 comment lines is mechanical and would be size S on its own. The cost that makes it M is diagnostic churn: Related sites and labels move, some L0304 refusals become L0301, and the notes that cite D-numbers change, with their fixtures.

If SC-24 is accepted, R19.20 would still have to:
- Confirm this sample against every citation.
- Decide the wording of the Related site and label once bindings and assignment share the general check.
- Decide whether array fields become general places, which removes `Admit_Array_Field`.
- Decide whether the `lenof` and counted-repetition lags are lifted (language) or recorded as boundaries.
- Map the 376 lines and 48 user-visible notes to the surviving rules.
- Sequence the work with R19.30, which rewrites the same lowering block for D29.

### 4. Can SR-1288 be met by marking instead of folding?

Yes. `spec.md` already has the form: "**Superseded by D192.**" at spec.md:14106 and 38302. 68 of the 86 decisions contain boundary wording ("this slice", "remains outside", L0304, about 230 phrases). Roughly 60-70 marks would cover them. The remaining ~18 decisions (D24, D29, D76, D77, D78, D85, D94, D97, D106-D109 and others) are live rules. Marking leaves the compiler untouched but does not shrink the register.

### What I sampled

- Read through: the declaration gate, the binding-initializer and assignment checks, `Check_Contextual_Value`'s array and aggregate dispatch, `Admit_Array_Field`, `lenof`, counted-repetition inference, `Lower_Binding_Statement` with `Write_Array_Value`, and the flow fact tables.
- Classified from the citation line alone: every other citation site, which I listed but did not read in context.

