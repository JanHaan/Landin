# R19's input: simplification candidates

*A frozen input of the third roadmap, placed under `roadmap/inputs/` at the
exchange and trimmed to what its items cite. Nothing was cut from it but its
pointers to the measurement files. It is not edited once the item that
decides it is complete.*

Audit of 2026-11-16 over `origin/main` 29d4f681f, read-only. It covers all
206 `[NNNN]` headings of `tour.md` and `spec.md`, the grammar [1740]-[1830]
and the 841 decisions of `spec.md`'s register. Six of the headings are
principles or a deferred form, not constructs ([0620], [1680]-[1730]).
Full measurements, with patterns and per-construct tables, and the raw
scripts stay in the planning record.

"lib" means the 107 `.ldn` files under `core/`, `hosted/` and `platform/`.
"fx" means fixture files under `compiler/tests/fixtures`, as positive and
runtime / negative. "dec" counts `spec.md` decisions that cite or patch the
construct. All counts come from grep and are approximate. Many fixtures
exist only to pin the construct itself, so a high fixture count measures
test churn, not demand. The register holds almost no Language evolution or
Usability rows on any candidate: only three of the second roadmap's rows touch the
area. The register is therefore no evidence either way.

## R19's input list

One list with a stable identifier per candidate. An R19 item names the
candidates it takes. Nothing here is decided: the maintainer decides each
one inside the R19 item that takes it. The scope is anything that makes
sense and can be called simplification. "Status" is `open`, or what has to
happen before the candidate can be decided. SC-01 to SC-21 keep the
audit's ranking order. SC-22 to SC-28 come from the vocabulary review
(`roadmap/inputs/vocabulary-review.md`), the
value-model reading and the two "measure first" constructs; SC-29 was moved in from the constructs examined, at the maintainer's decision of 2026-11-16. Duplicates
between the reports are merged into one entry, which says where else the
candidate appears. The call through a concrete type's name (D1364) is not
in the list: it is examined and kept by decision.

| Id | Status | Construct | Change | Replaced by | Breaks | Size | Evidence |
|---|---|---|---|---|---|---|---|
| SC-01 | open | [1190] `break with` and [1170] `complete` | remove both; loops become statements again | a mutable local or the named return, then plain `break`; or a helper that `return`s | lib 0; one derived program (Binary search) in examples.md; about 36 fx files; `with` and `complete` leave the keyword lists | M | strong on use. Removes D158's loop join and D430's `complete` clause, and partly D157, D159 and D234. No prototype uses it, and prototype 2's Y4 found a parser did not need it. |
| SC-02 | open | [1180] labels on loops and blocks | remove | `return` from an extracted function, or a flag | lib 0 across 126 `loop`, 294 `while`, 232 `for` and 44 `begin`; about 35 fx; examples 0 | M | strong on use, thin on loss: nested firmware loops are the likely user, and the board tests have none. With SC-01 gone, the label-or-value ambiguity goes too. D156, D157, D234; shares L0332. |
| SC-03 | open | [1010] anonymous functions | remove | a declared function passed by name; it captures nothing anyway | lib, examples and prototypes 0; about 8 fx files; tour [1000] and [1010] merge | S | strong. D123, D187, D464; it has its own lowering item kind. |
| SC-04 | open | [0670]/[1795] the inline named struct `t: type = (a: T)` | remove this spelling; parameter, result and payload lists keep theirs | `struct … end` | lib 0 against 183 block declarations; about 16 fx files (R490 fixtures); 2 diagnostics examples | S | strong. Removes the `->` lookahead rule in [1795]. D73, D74, D189. |
| SC-05 | open | [1320] `try for` and `fallible_iterable` | remove | `while` with `try next(…)` | lib 1 match is a comment; about 2-7 fx | S | strong, but the gain is small. The rest of the iteration question is SC-17. Also in the vocabulary review. |
| SC-06 | open | [1630] the Cortex-M0 positional `assembler.block(text, value)` | remove | the operand form `inout value: u32 at r0 = …` | lib 0 of 40 `assembler.block` lines; 4 fx; 2 probe call sites in `environments/cortex-m/probes/core-cpu.ldn` | S | strong. D248 kept it only "until lowering exists", and lowering now exists on every target. |
| SC-07 | open | [1070] a declaration in an `if` or `while` condition | remove | a binding on the line before | lib, examples and prototypes 0; 7 fx | S | strong on use. D185, plus a [1840] scope row. Only the narrower scope of a `bool` is lost. |
| SC-08 | open | [1440] importing selected names `import m (a, b)` | remove (`as` stays) | `import m` with `m.a` | lib 0 against 188 plain imports; 22 fx; 1 line in prototype 3 | S | strong. D150, D201, D242, D191; shares L0201. |
| SC-09 | open | [0100] several names in one declaration `a, b: T = v` | remove | one declaration per name, which [0100] already says it means | lib 0, devices and bindings 0; 3 lines in examples.md (atom lists); about 39/30 fx | S | strong on use, but the pattern for parameter lists is narrow. Removes D233's one-evaluation rule and the shared `mut` warning. |
| SC-10 | open | [0480] pointer unions with two or more atoms (D235) | reduce to the one-atom form | an error set on the one-atom form, or a `(state, ptr)` record | all 28 library unions have one atom; about 8/25 fx | M | strong on use. Removes a two-cell aggregate form from every backend's IR, ABI and widening. D235, D429, D874, D1115. |
| SC-11 | open | [0560] array fill | reduce to `[n of v]`; `[of v]` and `[e1, …, of v]` go | the length written out, or `zeroed` and assignments | lib 1 use (`[8 of closed]`, a kept form); about 50/40 fx | M | strong on use. 24 decisions cite [0560], and D36-D38 cover the mixed form alone. |
| SC-12 | open | [0720] struct literal `of` fill | reduce to `of zeroed` | name every field | lib and devices 0; about 15/6 fx; prototype 1 has one `of false`, which becomes `of zeroed` | S | strong on use. D214. Whether to drop `of zeroed` too is the maintainer's call (it hides fields added later). |
| SC-13 | open | [0750] `layout(optimal)` | remove | write the fields largest-alignment first | lib 0; 3 fx; two doc sentences | S | strong on use, small gain. D210. |
| SC-14 | open | [1220] `inout` and `sink` bindings in a `match` arm | remove the writing bindings; reading bindings stay | copy out, change, and assign the case; or write through a slice | lib 0; about 11/8 fx; prototype 3 sketches 3 | M | moderate. 10 decisions (the alias-until-last-use cluster). Only 4 library files use variants at all, so the sample is thin, and the cost of copying a large payload is unmeasured. Also in the vocabulary review (D433). |
| SC-15 | open | [0020]/[1780] block comments `--( … )--` | remove | line comments | lib, examples and prototypes 0; 8 fx (6 negative); L0013; the nesting rules in highlight/ | S | strong on use, small gain. |
| SC-16 | **decided 2026-11-16: remove** | [0660] range subtypes `T range a .. b` | remove | `distinct` plus a checking constructor | lib and devices 0; prototype 1's `baud_rate`; about 14/27 fx | M | thin on intent. It is the heaviest rule set in its section: 7 decisions and a list of refused positions, and D236 says it "does not compose". But the [1730] principle names it as a proof carrier, and an out-of-range constant stops being a compile error. |
| SC-17 | waits on R20 | [1320]/[1270] the `iterable` protocol and concepts with several inputs | decide in R20, not R19 | slices from containers (`vec.used`) | lib 0 conformances, and every library concept takes one input; about 16 fx; prototypes 2, 3 and 4 | M | Strong on use, but the compiler recognises `iterable` by name and no library module defines it. That gap is the library's. R20 decides whether containers iterate; remove the protocol only if they do not. Also in the vocabulary review (input labels in a conformance list). |
| SC-18 | waits on R20 | [0550] `zeroable` as a user-visible bound | remove | none needed today | lib 0; tour [1350]; prototype 3; 9 fx | S | strong on use, thin on the future: generic containers in R20 may want it. Decide with SC-17. Also in the vocabulary review. |
| SC-19 | open | [0640] D332's atom union written in place `x: a \| b` | remove; require an alias | a declared alias | lib 0 against 58 aliases; examples.md 3; about 6/5 fx | S | weak. It was added on purpose after a complaint, and examples.md writes it. |
| SC-20 | open | [0980] positional arguments followed by named ones | remove | all positional or all named | lib 0; 3/6 fx | S | weak on benefit. |
| SC-21 | open | [0360] inclusive `..` in `for` and slices | reduce to `..<` (`..` stays in `range` and `at`) | `..<` with the end plus one | lib 0 against 353 `..<`; examples.md 2; about 21/5 fx | S | Strong on use, but this is a real loss: a loop to a type's maximum (`0 .. 255` over `u8`) needs a wider counter. |
| SC-22 | open | `in` written on a parameter ([0900], D140) | remove | leave it unwritten; it already means the same | lib 0; 4/1 fx; 1 prototype line | S | strong. D140 kept it only as "a distinct syntax fact". From the vocabulary review. |
| SC-23 | open | `held` in `from held p` (D1369, ships with R13.92) | derive it from the result's type: a `from` result whose type is a type formal, or built from formals by value, is what its source holds | the rule; `tree.get` (concrete `node`) needs a generic or handle result, or keeps a form of its own | 11 library uses in 5 files would drop the word; 2 fx | S-M | moderate: covers 10 of 11 uses. Removes a keyword that has shipped, which the maintainer accepts doing cleanly in this roadmap. From the vocabulary review. |
| SC-24 | needs a checker read first | the value-model decisions D24-D109 | fold about 86 slice decisions into about eight rules, and the checker's per-slice paths with them | [1880]'s contexts and D241's general admission, which already state the rule | spec register; 491 citations of 71 of these decisions in `compiler/ada/src`; no program changes | M spec, unknown compiler | strong for the register, unknown for the code. See the value-model section. |
| SC-25 | open | a counted repetition infers only a scalar element (D241's boundary) | lift it: a repetition infers any element shape, as literals already do | — | additive; removes a special case | S | moderate. See the value-model section. |
| SC-26 | open | aggregate assignment write order (D29 against D209) | one rule: the value is formed as if first, and is written in place where no overlap is shown | — | a literal that reads its own destination changes meaning (`a = [a[1], a[0]]`); lowering and fixtures | S language, M lowering | the two decisions' texts; overlap cost unmeasured. A behaviour fix as much as a simplification. |
| SC-27 | measure first | [0590] arithmetic on whole arrays | remove | a `for` loop or a library function over slices | 21/35 fx; library use unknown (no grep sees it) | M | thin until an instrumented checker run counts array operator nodes over the library and examples. Rests on D209 and D240. |
| SC-28 | judge first | [0730] array fields in packed structs | remove, or have the SVD generator emit them | one field per element | 19 `r640` fx; prototype 1's GPIO case | M | zero library and generated-device use. Whether prototype 1's GPIO case is a requirement is the maintainer's call. |
| SC-29 | decide in R19.10 | [0230] hexadecimal float literals | remove, or keep for exact constants | a decimal literal that rounds to the same value, or a bit pattern through a conversion | lib 0; 9 fx | S | unused today; R22's math and float-text work is where exact constants and round-trip tests get written, so keeping them is the case to judge. Settled in R19.10 so nothing breaks after the breaking windows; R22.20 uses what R19.10 kept. |

### Examined and not recommended for R19

- **[1240] calling an entry through a concrete type's name (D1364).**
  Unused (lib 0, 5 fx), but removing it would reverse the decision R13.90
  took the day before this audit. Kept.
- **[0600] `utf16`.** Unused today (lib 0, 13 fx). R21's Windows layer talks
  UTF-16 to every wide API, so removing it now and needing it in R21 is the
  wrong order. Decide it in R21.10.
- **[0400] `inc` and `dec`.** These duplicate `+= 1` exactly, but the library
  writes `inc` and `dec` 214 times against 6 uses of `+= 1`. Removing them
  means rewriting about 35 library files, 11 example files, about 245
  fixtures and 16 prototype statements for two keywords. Only [1710]'s
  "two old ones leave" argues for it.
- **[1530] `option` build switches.** Unused (lib 0, 19 fx). It is the only
  way a user can steer `fixed if` without generating source. Whether it
  stays belongs with the build tool, which is outside this roadmap. Keep it.
- **[1040] `caller` parameters.** Unused (lib 0, about 20 fx), and nothing
  else can do its job. The library may not have its assertion helpers yet.
  Review it in R20.
- **[0960] `! …` inferred error sets.** The library uses none, but
  examples.md has 51 lines, prototype 4 has 4 and the fixtures about 100.
  The application-side convenience looks real.
- **[0220] `0b` literals and the `\e` escape.** Unused, but each is one
  clause of a scanner rule, so there is almost nothing to gain.
- **[1620] `seq_cst` and `thread_fence`.** The library uses neither, but
  store-load ordering cannot be said without them.
- **[1640] `section:` against `region:`.** A merge is possible but needs a
  decision on how an image without a device description names its regions.
  This is not a simplification of the language.

### Where the complexity sits, and the candidates do not reach it

Five of the six most-patched paragraphs belong to the value model: [0520]
arrays are values (53 decisions), [0410] evaluation order (46), [0540]
`zeroed` (34), [0710] struct literals typed from context (33) and [0750]
layout (27). [1940] module values known at compile time (41) is the same
chain seen from the module side. "Structs, variants and nesting" (72) and
"arrays, slices and text" (43) are the largest language sections. D24-D87
is a long chain of per-context admissions, each allowing one more place
where a literal, `zeroed` or a copy may appear. The candidates above trim
the edges of that model (SC-11, SC-12, SC-14) but leave its core alone. The next section reads D24-D109 for a uniform
rule.

## The value model: what a uniform rule would replace (D24-D109)

I read D24-D87 and the chain they continue, D88-D109, by the sentence each
one chose. I also read D29, D209 and D241 in full.

**What the chain is.** D24-D109 are the first roadmap's admissions of the
value forms, made one cell at a time. There are six forms: a literal, a
repetition, a mixed repetition, `zeroed`, a copy from a name, and a field
selection. Each was admitted in one context at a time: a typed or inferred
module binding, a typed or inferred local, an assignment, a field, a
label, a variant payload, an argument, a result. Nearly every decision
ends "remains outside this slice", and a later one says "D… later
admits". [1880] now lists the contexts once. D241, at the construct
audit, admitted every form in every governed position and left a short
list of recorded boundaries. So for the language, the uniform rule exists
already:

> A value form of type T is accepted wherever [1880] supplies T. A module
> position also needs [1940]'s known value. A form with no type of its own
> (`zeroed`, an untyped struct literal, an uncounted repetition) needs a
> destination that supplies one.

**What that rule replaces.**

1. *The register, not the language.* About 86 decisions (D24-D109) record
   slices that D241 and [1880] have since generalised. Most of their
   "Chosen" text now describes boundaries that no longer exist. They could
   fold into about eight statements that still decide something:
   - D29's write order into a destination;
   - D10 and D24's static images;
   - definite assignment of an array as a whole (D29, D32);
   - D76's case selected before its payload is evaluated;
   - D78 and D85's arm aliasing, which shrinks to reading if candidate SC-14
     goes;
   - D86-D91's nesting, now any depth;
   - D94-D109's by-value transport through caller-owned storage;
   - D241's boundaries.

   The compiler cites 71 of these decisions 491 times, 137 of them in
   `landin-stages-checking.adb`. Folding the register means re-pointing
   those citations. Whether the checker still has one code path per slice
   is the open part. Size: M for the specification; unknown for the
   compiler until someone reads the checker (an R19.10 task for an Opus
   reader, not a count).

2. *D241's remaining boundaries.* Two go with candidate SC-11 (mixed
   repetition needs a typed destination; `[of v]` needs an array
   destination). One generalises rather than goes: "a counted repetition
   infers only a scalar element" is the one place repetition still lags
   literals, which D241 opened to every element shape. The uniform rule
   lifts it; it is a small addition that removes a special case. The rest
   are the rule itself and stay: an untyped struct literal needs a named
   type, a variant part has no value of its own, and a module image folds
   only what [1940] knows.

3. *One semantic inconsistency, which a uniform rule would decide.* D29
   makes `place = [e1, …, en]` write each element as soon as it is
   evaluated, so a later element sees an earlier write (`a = [a[1], a[0]]`
   leaves both elements equal) and a trap leaves a changed prefix. D209
   makes array arithmetic keep each operand whole before writing, and lets
   the compiler write in place when it can show no overlap. D241's call
   payload "fills a temporary that is then copied". So one program
   statement, an aggregate assignment, has two meanings depending on how
   its right side is spelled. A uniform rule: every aggregate assignment
   behaves as if its value were formed first, and is written in place
   wherever the compiler shows no overlap, as D209 already allows.

   This is breaking only for a literal that reads its own destination,
   which nothing in the library is known to do (not counted: no grep sees
   it). D29's argument against it is that a hidden array-sized temporary
   hides a cost the language promises to keep visible. Under the uniform
   rule the temporary appears only when the literal reads the destination,
   and D209 already accepts the same trade for arithmetic. Size: S for the
   language, M for lowering and fixtures. Evidence: the two decisions'
   texts. Thin on the cost side until the overlap cases are measured.

The forms axis is where the language can still shrink: candidates SC-11 and
SC-12 (fills) and SC-14 (writing arm bindings). The contexts axis has already
been made uniform. The rest of the value model's weight is in the register
and possibly in the checker, not in what a programmer writes.

## A possible grouping, for R19.10 to accept or change

If every candidate were taken, they would fit about ten groups:

- loops as statements: SC-01, SC-02, SC-07;
- one spelling for a declaration: SC-03, SC-04, SC-09, SC-19;
- fills and layouts: SC-11, SC-12, SC-13;
- unions and matches: SC-10, SC-14;
- imports, comments and assembly: SC-06, SC-08, SC-15;
- iteration: SC-05 now, with SC-17 and SC-18 after R20's answer;
- the parameter and origin words: SC-22, SC-23;
- the value model: SC-24 after its checker read, with SC-25;
- on their own: SC-26 (a behaviour fix), SC-16 (decided: remove), SC-27 and
  SC-28 (measure or judge first), SC-29 (keep or remove).

## Constructs examined and kept

One line each, taken from the measurement tables. The reasons are given in
the measurement files of the planning record; a bare "KEEP" means the construct is the base form, used
throughout the library.

- [0010] Line comments — KEEP
- [0030] Doc comments — KEEP
- [0040] Declaring a name — KEEP
- [0050] Type from the value — KEEP
- [0060] Mutable variables — KEEP
- [0070] Two questions about a reference — KEEP
- [0080] Declaring now, assigning later — KEEP (thin lib use)
- [0090] Making a name public — KEEP
- [0110] The name is always on the left — KEEP
- [0120] Declaring a type — KEEP
- [0130] Order does not matter in a module — KEEP
- [0140] Shadowing — KEEP
- [0150] Integer types — KEEP
- [0160] Pointer-sized integers — KEEP
- [0170] Floating point — KEEP (zero library float code)
- [0180] Booleans — KEEP
- [0190] Integer literal takes type from context — KEEP
- [0200] Default `i32` — KEEP
- [0210] Float literals always have a point — KEEP
- [0220] Bases, separators, exponents — KEEP, `0b` weak candidate (below)
- [0240] Infinity, NaN, negative zero — KEEP (only spelling; no float library)
- [0250] Character literals — KEEP
- [0260] Text literals typed from context — KEEP
- [0270] Escapes — KEEP (trim `\e` optional, S)
- [0280] Raw text literals — KEEP
- [0290] Arithmetic — KEEP
- [0300] Overflow traps; wrapping separate — KEEP
- [0310] Conversions written out — KEEP
- [0320] Shifts — KEEP
- [0330] Bitwise operators — KEEP
- [0340] Logical operators — KEEP
- [0350] Comparison — KEEP
- [0370] `sizeof alignof lenof offsetof` — KEEP
- [0380] `addr` and `.val` — KEEP
- [0390] Assignment is a statement — KEEP
- [0410] Evaluation order is fixed — KEEP
- [0420] What the dot means — KEEP
- [0430] `ptr`, `addr`, `.val` — KEEP: the pointer type is the hardware and C boundary
- [0440] writable passes where read-only expected — KEEP: the one implicit relaxation, removes the const/non-const pair
- [0450] permission is shallow — KEEP (rule)
- [0460] pointer to a fixed address — KEEP: drivers; same `ptr(n)` form as 0470
- [0470] pointers and integers — KEEP (core/arena, core/mem, platform)
- [0480] no null: pointer union — KEEP the one-atom form; CANDIDATE reduce the several-atom form (see B)
- [0490] what to use instead — KEEP (prose)
- [0500] no pointer arithmetic — KEEP (absence)
- [0510] `mem.storage(t)` — KEEP: library type under vec/spill/map, not a language construct
- [0520] Arrays are values — KEEP
- [0530] Letting the literal set the length — KEEP (thin): an inference rule, not syntax; library 0 uses of `:= [`
- [0540] `zeroed`: the all-zero value — KEEP: 127 library uses
- [0570] Slices are views — KEEP
- [0580] The empty slice — KEEP: small, 6 library uses
- [0600] Text: `utf8`, `utf16` and `cstring` — KEEP `utf8`/`cstring`; CANDIDATE: remove `utf16`
- [0610] Indexing text by scalar or by position — KEEP: RP1 retains ordinal indexing
- [0630] Atoms — KEEP: foundation of `fail`/`try`
- [0640] Enumerations are unions of atoms — KEEP the declared union, CANDIDATE to drop the in-place spelling (weak)
- [0650] Distinct types — KEEP: [1730]'s proof carrier and the replacement for range subtypes
- [0670] Structs — KEEP the block and the anonymous inline form; CANDIDATE to drop the named inline declaration
- [0680] Structs with a variant part — KEEP: the only payload-carrying sum; thin library use but no overlap
- [0690] Cases with no payload — KEEP: the same part as 0680, a case with no fields
- [0700] Constructing values and converting them — KEEP: already the merge of construction and conversion
- [0710] Struct literals take their type from context — KEEP
- [0730] Register images: flags, selections and sets — KEEP the construct; CANDIDATE (drop array fields)
- [0740] Reading and writing a device register — KEEP (overlap with volatile noted)
- [0750] Field order and layout — KEEP, CANDIDATE to remove `layout(optimal)`
- [0760] Attributes — KEEP: reference table, each word is its own construct elsewhere
- [0770] frame reference cannot leave — KEEP (core check)
- [0780] `escaping` — KEEP both: `into` is used by core/fibre and hosted/thread, prototype 5
- [0790] `from` — KEEP: RP4
- [0800] borrow through `from` lasts across the call — KEEP (rule; prose could fold into 0790/0830)
- [0810] pointer from integer is untracked — KEEP (the declared hole; prose could fold into 0470)
- [0820] arenas are ordinary allocators — KEEP: library, not language
- [0830] view into a local holds it — KEEP (core check; RP4 sits beside it)
- [0840] mixed origins: shortest-lived — KEEP (rule)
- [0850] volatile outside borrow rules — KEEP: the whole hardware layer
- [0860] what lifetime checks do not catch — KEEP (prose)
- [0870] Declaring a function — KEEP: the base form of every routine
- [0880] One-line functions — KEEP: not a construct of its own, it is [1080]'s final value used on one line
- [0890] Returning nothing, and never returning — KEEP: a result type plus a type fact; `_exit`, `first_frame` and process exit use it
- [0900] Three parameter conventions — KEEP: RP4 protects `escaping`; `inout` is the only output channel besides results
- [0910] `sink` consumes a place — KEEP: used for every handle that ends
- [0920] Several results — KEEP
- [0930] Every result is assigned before returning — KEEP: the check that makes named results safe
- [0940] Errors: what can fail is in the signature — KEEP
- [0950] What deserves an error, and what does not — KEEP: guidance, no syntax
- [0960] Passing a failure on: `try` — KEEP `try`; CANDIDATE: reduce `! ...`
- [0970] Leaving early: `return` and `fail` — KEEP: 1274 library uses, `when` 280
- [0980] Calling: positional, then named — KEEP, but CANDIDATE to drop the mixed form (weak)
- [0990] Using a multiple result — KEEP
- [1000] Functions are values — KEEP: callbacks, `core/sort`, handlers
- [1020] Throwing a result away — KEEP: ubiquitous, and [1080] depends on it
- [1030] Handling a failure: `else` — KEEP: 282 library uses; most-patched construct (9 decisions) but central
- [1040] Passing the call site: `caller` — KEEP, with a doubt: zero library, example and prototype uses
- [1050] Branching with `if` — KEEP: core, 764 library uses
- [1060] Every construct fits on one line — KEEP: a layout property, no construct to remove
- [1080] Blocks have values — KEEP: 143 library uses, makes `else`/arms values
- [1090] Bare blocks: `begin ... end` — KEEP: needed for arm and `else` blocks and `unchecked`; bare statement form unused in library (examples 9)
- [1100] Cleanup on the way out: `defer` — KEEP: 118 positive fixtures; library 6 (arenas)
- [1110] Cleanup only on failure: `undo` — KEEP: 12 library uses, no other cleanup-on-failure form
- [1120] Switching checks off for a region: `unchecked` — KEEP: 52 library uses; named in the principles
- [1130] Repeating: `loop` — KEEP
- [1140] Repeating while a condition holds: `while` — KEEP: 142 library uses
- [1150] Walking a range or a collection: `for` — KEEP
- [1160] Writing through a loop binding — KEEP: a typing rule, no syntax
- [1200] Cleaning up several acquisitions — KEEP: idiom, no syntax
- [1210] Pattern matching: `match` — KEEP
- [1230] declaring a concept — KEEP
- [1240] making a type conform — KEEP the form and `through`; CANDIDATE reduce the type-name call (see C)
- [1250] conformance for a generic type — KEEP: otherwise no container is iterable, allocated or compared generically
- [1260] a concept fixes its error sets — KEEP (rule)
- [1280] where conformances live, collisions — KEEP: RP2
- [1290] generic function — KEEP
- [1300] calling a generic function — KEEP: needed for fixed and return-only parameters
- [1310] how generic code runs — KEEP (the implementation reading of 1690)
- [1330] integer ranges are not values — KEEP (absence)
- [1340] combining concepts — KEEP
- [1350] generic types — KEEP
- [1360] allocation is a concept — KEEP: central design constraint
- [1370] `any C` — KEEP: [1690]
- [1380] `any(...)` — KEEP
- [1390] calls go through the table — KEEP: the one method-call form, used in lib and examples
- [1400] what `any` can do that generics cannot — KEEP (prose, fold into 1370)
- [1410] A module is a directory — KEEP
- [1420] Importing a module by its path — KEEP
- [1430] Renaming an import — KEEP (thin): the only collision tool, zero library uses
- [1450] Imports belong to one file — KEEP: a scoping rule; shrinks if [1440] goes
- [1460] Module-level values are known at compile time — KEEP: follows from no compile-time execution (RP3)
- [1470] Packages and versions — KEEP: prose only, RP6, no compiler cost
- [1480] Where modules come from: the roots — KEEP
- [1490] the word `fixed` — KEEP (prose, fold into 1500/1520)
- [1500] `fixed if` and compiler facts — KEEP: the one portability mechanism, no macros
- [1510] `compiler.assert` — KEEP
- [1520] `fixed` parameter — KEEP: sized arrays in generics
- [1540] no compile-time execution — KEEP: RP3
- [1550] What the compiler produces — KEEP
- [1560] The `compiler`, `assembler` and `linker` modules — KEEP
- [1570] Calling conventions — KEEP
- [1580] Importing from C — KEEP
- [1590] Linking a library — KEEP
- [1600] Exporting to C — KEEP
- [1610] Choosing a symbol's linker name — KEEP
- [1615] Storage local to each thread — KEEP
- [1620] Atomics — KEEP (see note)
- [1640] Placing code and data on a microcontroller — KEEP
- [1650] Where a program starts — KEEP
- [1660] Where capabilities come from — KEEP (principle, no syntax)
- [1670] When a check fails — KEEP
- [1675] Two things in flight: fibres — KEEP
- [1740] A source file is an import prelude and declarations in any o — KEEP (the file shape); `import as` and `import (names)` are zero-use forms owned by tour [1430]/[1440], flagged in secti
- [1750] A source file is bytes — KEEP: it is what spans point at; no form to remove
- [1760] Identifiers are lower case, and no identifier is a keyword — KEEP; C-candidates below free keywords: `with`, `complete`, `inc`, `dec`
- [1770] The kernel's literals include characters, floats and text — KEEP, with CANDIDATE K (hex float literals, now SC-29)
- [1790] A binding names one thing, and says how much it may change — KEEP; CANDIDATE E (in-place atom union)
- [1795] Type aliases and declared identities — KEEP; CANDIDATE D (inline struct body is a second spelling of `struct ... end`)
- [1800] A function is a value with a body, and its returns are named — KEEP; CANDIDATES F (anonymous function) and L (`caller`)
- [1810] Statements do one thing each, and only exits carry 'when' — KEEP the core; CANDIDATES A, B, C, G, H, I
- [1820] Precedence, tightest first, and comparison does not chain — KEEP; `offsetof` KEEP (generated bindings and from-c use it, section 3)
- [1830] What is not enabled is refused, and named — KEEP: it is the mechanism by which every CANDIDATE here becomes a "withdrawn" note (D212 is the model)
- [1840] The kernel's scopes, outermost first — KEEP (nine scopes is what the language needs; no form)
- [1850] One scope gives one name to one thing — KEEP
- [1860] A name that names nothing is refused — KEEP
- [1870] The kernel's types, and what each of them holds — KEEP; CANDIDATE M (`utf16`)
- [1880] Where a literal's type comes from, and what a context is — KEEP
- [1890] What each operator takes and what it gives — KEEP
- [1900] What may be written, and what may not — KEEP
- [1910] Assigned before it is read — KEEP
- [1920] What a call means — KEEP
- [1930] What may be discarded — KEEP
- [1940] A module value is known when the compiler reads it — KEEP: it is the price of no compile-time execution (RP3); the 41 decisions are mostly D24-D83 aggregate/array static ima
- [1950] An operand an operation cannot take — KEEP
- [1960] A trap stops at the operation — KEEP
- [1970] The first hosted path has one entry shape — KEEP
- [1975] The selected hosted C boundaries — KEEP
- [1980] Declared errors are an orthogonal payload-free atom outcome — KEEP; the `! ...` form was weighed and kept, see section 3
- [1990] Firmware and machine directives have explicit target contrac — KEEP
- [1995] A stack switch resumes another stack, and every frame checks — KEEP
- [1996] Each thread has its own instance of thread storage — KEEP
- [2000] What a doc comment is about — KEEP
- [0620], [1680], [1690], [1700], [1710], [1720], [1730]: a deferred form and the principles; prose, not constructs.
