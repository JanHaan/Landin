# R19.20's reading: how far the checker folds

*Read by R19.20 on 2026-11-21 over `0649b1fc6`, read-only, for R19.90, the
fold D1664 records. It confirms R19.10's sampled reading,
[`value-model-reading.md`](value-model-reading.md), against every citation
of D24 to D109 in `compiler/ada/src` and against the text of all 86
decisions, and it scopes the fold. Line numbers are at that base; the
subprogram names are what to search for once the tree has moved. It is not
edited once R19.20 is complete.*

The sample held in outline. It missed four checker sites that repeat the
general dispatch, two small lowering branches and a third scalar-element
boundary, and it put the gate's remainder too low. Corrected, the
per-slice sites hold about 1,900 lines of checking and lowering, which
fold to about 500, and the fold is size L rather than M. Every per-slice site still
collapses into a general routine that already exists. No IR form or
backend changes.

## 1. The rules that survive

Thirteen statements still decide something. Each decision of D24 to D109
belongs to one of them, or to none and is superseded (section 2).

| Rule | Decisions that hold it | What it still decides |
|---|---|---|
| Write order | D29, D32, D36, D37 | each element is stored as it is evaluated; a repeated value is evaluated once; a mixed prefix is stored before its suffix; a failure leaves the prefix written |
| Compact whole-array operations | D32, D36 (D28 and D30 stated it first) | a whole clear, fill or copy is one operation, never one per element. D28 and D30 are superseded, so R19.90 states this in D32's surviving text |
| Static images | D24, D26, D34, D38, D66, D67, D68, D81 | the [1940]-known fold, one image per binding, the repeated and hybrid encodings, field images, the selected-case image |
| Inferred shape | D25, D33 | the first element, or the repeated value, gives the element type, an untyped integer defaulting to `i32`; later elements must match; the extent fits `usize` |
| `lenof` of a literal | D31 | a measured literal is checked, not formed, and nothing in it is evaluated |
| Layout and measurement | D44, D45, D74, D75 | struct and variant layout under [0750]; D75's sentence "the tag value zero selects the first case" is stated nowhere else |
| Nested layout | D86 | a child struct is one field with its padded size and alignment |
| Construction syntax | D72 | `T(field: value, ...)` takes its body from `T` |
| Case before payload | D76 | the case is selected before its payload is evaluated |
| Exhaustive match | D77 (with D405) | a duplicate case is L0311, a missing one L0312 |
| Arm aliasing | D78, D85 | arm names alias the payload in place, an array payload by element |
| Whole-aggregate definite assignment | D102, D104 (and D29's whole-array read) | a whole read needs every element or field assigned, and a variant field needs its case selected before it crosses a call |
| By-value transport | D94-D99, D106-D109, D96's carrier sentence | callee slot and its copy, zero carrier, argument temporary, hidden result pointer, field identities in place of offsets |

## 2. Every decision

21 are live, 16 partly live, 47 superseded, and 2 refused syntax that was
later enabled. "Partly live" names the sentence that survives. Everything
else in a partly live decision's Chosen paragraph is a cell, and R19.90
marks it as such.

| Decision | Verdict | Superseded by, or the rule it holds |
|---|---|---|
| D24 | live | static images |
| D25 | partly live | inferred shape; its list of positions "outside this slice" is superseded by D241 |
| D26 | partly live | static images; its scalar element is the boundary Q-122 asks about |
| D27 | superseded | D241; the absent zero image is D10's |
| D28 | superseded | D241; its one-clear rule moves to D32 |
| D29 | live | write order; its boundary list is superseded by D241 |
| D30 | superseded | D241; its one-clear rule moves to D32 |
| D31 | live | `lenof` of a literal; its scalar-element sentence is lifted by D1664 |
| D32 | partly live | write order, compact operations |
| D33 | partly live | inferred shape; its scalar element is lifted by D1664 |
| D34 | partly live | static images (repeated encoding) |
| D35 | superseded | D33 and D34; its scalar element is Q-122's |
| D36 | partly live | write order (prefix, then one fill) |
| D37 | partly live | write order; D36's rule on assignment |
| D38 | partly live | static images (hybrid encoding) |
| D39-D41, D43 | superseded | D241 |
| D42 | superseded | D241, with D118 for the path |
| D44, D45 | live | layout and measurement |
| D46, D47, D49-D59 | superseded | D241 (D59's absent image is D10's) |
| D48 | superseded | D118/D119 for the subobject path, D241 |
| D60, D61 | superseded | D24 and D66 (chain, cycle and distinct storage) |
| D62 | superseded | D42 and D118 |
| D63 | refused syntax | enabled by D64; D72 for construction |
| D64 | superseded | D72 and D241 |
| D65 | superseded | D241 |
| D66, D67 | partly live | static images (field images) |
| D68 | partly live | static images (compact repeated and hybrid field images) |
| D69 | superseded | D24's chain and D66's carrier |
| D70 | superseded | D241, D24's chain |
| D71 | superseded | D66, D67 and D24's chain |
| D72 | live | construction syntax |
| D73 | refused syntax | enabled by D74 |
| D74 | live | layout and measurement |
| D75 | partly live | layout: the zero tag selects the first case |
| D76 | live | case before payload |
| D77 | live | exhaustive match |
| D78 | live | arm aliasing |
| D79 | superseded | D76 for the order, D241 |
| D80 | superseded | D241 |
| D81 | partly live | static images (selected-case image) |
| D82 | superseded | D67 and D68 |
| D83 | superseded | D24's chain and D81 |
| D84 | superseded | D241, which names it; D76 for the order |
| D85 | live | arm aliasing |
| D86 | live | nested layout |
| D87-D93 | superseded | D118/D119 for depth, D241 for the forms |
| D94, D95, D97-D99 | live | by-value transport |
| D96 | partly live | by-value transport (field identities on the carrier) |
| D100, D101, D105 | superseded | D98 and D99 (argument temporary), D72 |
| D102, D104 | partly live | whole-aggregate definite assignment |
| D103 | superseded | D76, D98 and D99 |
| D106-D109 | live | by-value transport |

61 of the 86 carry boundary wording that is now false ("this slice",
"remains outside", "not enabled", an L0304 that no longer fires). The mark
on a superseded decision covers its whole text. Each partly live
decision's false sentences are named in its mark.

## 3. The compiler's citations

There are 491 occurrences on 376 lines, as R19.10 counted.

| Kind | Lines | What the fold does |
|---|---|---|
| Comment on general code or on representation that stays | 271 (60 in checking, 211 elsewhere) | re-point to the surviving rule (section 1), or to D241 or D118/D119 for a superseded admission. Superseded D28, D47-D58, D80, D84 and D88-D91 name IR operations that stay (whole clear, copy and fill, copying a variant part, nested field runs), so their comments are re-pointed, never deleted |
| Comment on a per-slice branch | 58 (53 checking, 5 lowering) | go with their code (below) |
| Inside text a user sees | 40 (24 checking, 5 parser, 6 explanations, 2 catalogue, 1 references, 2 compiler-defect texts in lowering) | re-point to the surviving rule; the notes citing D74, D76, D77 and D78 already cite live decisions and stay |
| False positives | 7, all in `landin-diagnostics-explanations.adb` | none; they are wrapped D405, D472, D545, D546, D557, D653 and D973 |

Four comments are stale today and are corrected in the same pass:
checking 9375 (cites D86's depth limit, which D119 removed), 10856-10862
(parameters and returns "need a whole-value rule this slice does not
have", yet both are admitted), 30613 ("first executable slice"), 38710
(D51's gate); and flow 70 and 130 (D88-D90 and "the parent/child set",
the scheme D118/D119 replaced).

### The per-slice sites

| Site (base lines) | What it special-cases | After the fold | Lines |
|---|---|---|---|
| checking, `Declared_As_Node`'s gate, 10856-11255 | 21 `Is_*_Init` predicates (13 array, 8 struct) and two allow-lists | `Gate_Refuses` keeps [1940]'s module refusals and "needs a named body or an initializer"; everything else is the general check, whose mismatch is L0301 | ~400 → ~100 |
| checking, binding initializer, 34646-34878 and 34973-34988 | the general dispatch repeated by form, plus a scalar `zeroed` arm | one `Check_Contextual_Value` call | ~245 → ~20 |
| checking, assignment, 35351-35381, 35415-35643, 35736-35750 | the same dispatch, the D49/D50 pre-pass for an array field, a scalar `zeroed` arm | one call | ~275 → ~30 |
| checking, `Check_Array_Field`, 31723-32053 (missed by the sample) | a struct literal's array label: the dispatch again, in a static and a runtime half | the runtime half becomes one call; the static half stays, being [1940]'s image check | ~330 → ~170 |
| checking, `Check_Fixed_Array_Payload`, 30789-31011 (missed) | a variant payload's array field, the same way | the same split | ~215 → ~110 |
| checking, `Admit_Array_Field`, 25492-25572, with 21 caller lines | an array field is typed only where a caller opts in | removed (section 4.2) | ~100 → ~10 |
| checking, `Is_Zeroed_Scalar_Place`, 25759-25795, and the scalar `zeroed` arm near 32136 (missed) | an allow-list of places scalar `zeroed` may fill | removed; the general check's scalar branch (38113) already takes `zeroed` | ~40 → 0 |
| checking, `Synthesise`'s array-field and child refusals, 27307-27328 and 27353-27375 (missed) | refuse a whole array field or child by its own message | the generic mismatch | ~45 → 0 |
| checking, `lenof [..]`, 26352-26443 | a scalar element (D31) with two messages of its own | `Infer_Value`'s first-element rule | ~90 → ~15 |
| checking, counted repetition in `Infer_Value`, 39020-39145 | infers only a scalar element (D33) | lifted | ~30 changed |
| checking, `Infer_Literal_Shape`, 38839-38842 (missed) | a module literal infers only a scalar element (D26) | Q-122's | ~10 |
| lowering, `Lower_Binding_Statement`'s array arm, 14672-14790 | literal, mixed, repetition and `zeroed` stored inline | the existing final `Write_Array_Value` call | ~120 → 0 |
| lowering, `Lower_Binding_Statement`'s aggregate arm, 14843-14855, and `Lower_Assignment_Statement`'s field arm, 15699-15708 (missed) | `zeroed` cleared inline | `Write_Shaped_Value`'s `zeroed` branch, which emits the same clear | ~22 → 0 |

What stays: `Check_Module_Value` and the static halves ([1940]),
`Admit_Variant_Field` (a variant part has no value), the image encodings
in IR, lowering and the backends, the case-first order, the alias
handling, and flow's depth-one fact set, which is kept beside the nested
one by design. Its comments call it a dense table, but both are ordered
sets, and the fold corrects the wording.

### Lowering's collapse gives the same IR, with two exceptions to check

Read against `Write_Shaped_Value`, the general writer stores each scalar
element with the same `Emit_Store_Slot_Field`, in the same order. It
evaluates a repeated value once, before the same fill, and emits the same
clear for `zeroed`. Two differences remain:

- The general writer omits the fill when the prefix already fills the
  array. A checked mixed form always has a suffix, so only a zero-length
  repetition is affected. Its value is still evaluated once.
- The general writer first checks for widening into a union, a distinct
  conversion and a packed array. A packed array goes through a temporary
  and a copy, which the inline code never makes. R19.90 checks whether a
  packed binding reaches this arm, and the build-modes comparison and this
  host's manifest show any other difference.

## 4. What the reading decides

1. **Diagnostics once bindings and assignment share the general check.**
   The general check's mismatch, "does not have the required array type and
   shape" with its generic note, replaces the duplicates' "this is not an
   array of the type written here". Each caller keeps its own label: "the
   type declared here" for a binding and "the place written here" for an
   assignment. The general check already takes a caller's label. The D17
   note, which only restated the array type, goes. The nominal-type note
   that cites D213 moves into the general check's nominal mismatch, so no
   form loses it. A refusal that was L0304 only because its position was
   not on an allow-list becomes the L0301 a type disagreement is, or an
   acceptance. The commit lists each such change, as R19.90's exit
   evidence asks.
2. **Array fields become general places.** `Selected_From` types an array
   field everywhere, as it does a scalar field, and `Admit_Array_Field`
   goes. Three of its callers (16871, 35271, 35375) call it only for its
   side effect, recording the field's type and shape. That recording and
   the private-representation check move into `Selected_From`. The refusal
   "this selects a whole array field" becomes the generic mismatch. This is
   the riskiest step, so it is the last checker step, with its own fixture
   run.
3. **Two scalar-element boundaries are lifted, a third is asked.** A counted
   repetition and `lenof` of a literal take any element shape (D1664). Then
   `negative/r720-counted-repetition-scalar-element` and the `ptr` and
   struct lines of `negative/r491-inferred-repetition-refusals` are
   accepted, and become positive fixtures. The latter keeps its L0331 and
   L0301 lines. The same boundary at module scope, D26 and D35, is outside
   D1664's words, so the maintainer decides it as Q-122. Until answered it
   is kept as a recorded boundary.
4. **Fixtures that name a superseded decision.** 257 fixtures name a
   decision of D24 to D109 in `fixture.meta`, about 150 of them only
   superseded ones. They keep pinning the general rule, so none is removed.
   Their summaries are re-pointed to the rule section 1 names, in the same
   commit as the marks. `check.py` holds the spec's "Pinned by" lists to
   the fixture tree, so the marks keep each list.
5. **The tour and D241 change with the lifts.** [0560]'s table says the
   counted form infers a binding's type, and [0370]'s fine print says a
   measured literal's elements are "checked to have one scalar type".
   D241's "Counted repetition keeps [0560]'s scalar element" is amended to
   name D1664. R19.90 edits all three.

## 5. Order of the work

R19.30 rewrites the aggregate assignment's write order in
`Write_Shaped_Value` and the assignment arm. A binding writes a fresh slot,
where no overlap can arise, so R19.30 leaves the binding's inline loops
alone. Those loops are a second copy of D29's order. R19.90 runs after
R19.30 in the serial order. It then collapses the binding into the general
writer that R19.30 has settled, and R19.30's in-place writing without
overlap is what a fresh slot gets. Neither item rewrites the other's code
twice.

Within R19.90, each step below is one commit, checked by the fixtures its
sites touch:

1. The register: mark the 49 superseded and refused-syntax decisions, and
   name the false sentences in the 16 partly live ones. D32 states the
   compact whole-array operations rule. This step is explanatory.
2. Re-point the 271 general comments and fix the stale ones.
3. Fold the binding and assignment checks, `Is_Zeroed_Scalar_Place` and
   the gate.
4. Fold `Check_Array_Field`'s and `Check_Fixed_Array_Payload`'s runtime
   halves.
5. Make array fields general places, removing `Admit_Array_Field`.
6. Lift the two boundaries, and Q-122's if the answer is to lift it. Turn
   the refusing fixtures positive and add a runtime fixture for a
   repetition and a `lenof` of a struct element.
7. Collapse lowering's three inline sites, with the build-modes
   comparison, this host's manifest and `scaling.sh`.
8. Re-point the 40 user-visible notes and their about 20 `expected.txt`
   files, and regenerate the catalogue.

The size is L: about 1,900 lines folded to about 500 in the checker and
lowering, 271 comments re-pointed, about 150 fixture summaries
re-pointed, and about 30 expected outputs changed. The register marks
alone are S.
