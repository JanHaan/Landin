# The vocabulary of origins, access and concepts: a review

*A frozen input of the third roadmap, placed under `roadmap/inputs/` at the
exchange and trimmed to what its items cite. Nothing was cut from it but its
pointers to the planning files. It is not edited once the item that decides
it is complete.*

2026-11-16, over `origin/main` 29d4f681f, plus R13.92's branch
`r13-92-container-holds` (read, not edited) for `from held` and D1369.
Dates and counts were gathered in two files beside the planning copy, made
by subagents, which stay in the planning record. The judgement is mine,
made at the session's own effort, which was not raised.

Every removal here is a candidate in R19's input list
(`simplification-candidates.md`): `in` is SC-22, the match-arm conventions
SC-14, the multi-input concepts and their labels SC-17, `zeroable` SC-18,
`try for` SC-05, and the derivation of `held` SC-23. Nothing is decided;
the maintainer decides each inside the R19 item that takes it.

## The finding in one paragraph

Fewer words were added than it feels. Of the 31 forms a programmer writes
here, 26 were in the first specification of 2026-08-20. Only five came
later: `escaping into` (10-27), `sink` on a match arm (10-19), `through`
and the call through a concrete type's name (both 11-15), and `held`
(11-16, on R13.92's branch). What grew is the rules attached to the words:
dozens of decisions say where an existing word may stand and what it lends.
The vocabulary is close to minimal. Every unwritten case is already the
default: `in`, non-escaping, read-only, immutable, independent (no
`from`). Six forms can go without touching a single library signature,
because the library never writes them. That six is the whole of the
reduction. I looked for merges that would change what the library writes
(`sink` into `inout`, `inout` into `ptr mut`, `held` derived from the
type, `escaping` always naming a target) and none holds up; the reasons
are below.

## The reduced vocabulary

| Word or form | Fate | Replacement |
|---|---|---|
| `ptr T`, `ptr mut T` | keep | — |
| `[]T`, `[]mut T` | keep | — |
| binding `mut` | keep | — |
| `addr x`, `p.val` | keep | — |
| `in` written on a parameter | **remove** | leave it unwritten; it already means the same (D140) |
| `inout` parameter | keep | — |
| `sink` parameter | keep | — |
| `inout` / `sink` on a match-arm binding (D433, [1220]) | **remove** | read the payload, change it and assign the case; to consume, pass the whole union `sink` to a routine that matches it |
| `escaping`, `escaping into p` | keep (one marker with an optional target) | — |
| `from p, q` | keep | — |
| `from held p` | keep (see "unsure") | — |
| `unchecked … end unchecked` | keep | — |
| `concept (t: type) … end` | keep, **one type input only** | a concept that took several inputs takes one; the extra inputs become entries' parameter types, or the concept splits in two |
| input labels in a conformance list (`idx: usize, item_type: u32`, [1270]) | **remove** with the line above | — |
| `is` (constraint, conformance, parents) | keep: one word, one meaning, three positions | — |
| `through field` / `through routine` | keep | — |
| `(t: type) f(t) is c` generic binder | keep | — |
| `any C`, `any(p)`, `self` | keep | — |
| `t.entry(…)` | keep | — |
| `T.entry(…)` through a concrete type (D1364) | keep, by the maintainer's decision | (its only consumer went with D1363; it now has none) |
| `distinct`, `type`, `fixed` formals | keep | — |
| `is zeroable` as a written bound | **remove** (SC-18; decided after R20 with the library's generic containers) | none needed today |
| `try for` / `fallible_iterable` | **remove** (SC-05) | `while` with `try next(…)` |

The reduced vocabulary is exactly the subset the library writes today:
107 files, 1352 functions, 156 conformances, and not one of the six forms
marked "remove".

### Four library signatures, in the reduced vocabulary

These signatures are among the densest in these words. They come out of the
reduction unchanged, which is the point: the words that go are words the
library never needed. Each word is glossed so the set can be checked
against what it says.

`core/vec` on R13.92's branch, the densest container trio:

```landin
public push: (item: type, provider: type is mem.allocator,
              inout value: list(item), memory: provider,
              escaping into value added: item) -> none ! mem.out_of_memory
public get:  (item: type, value: list(item), index: usize)
             -> (result: item from held value) ! mem.out_of_bounds
public at:   (item: type, inout value: list(item), index: usize)
             -> (slot: ptr mut item from value) ! mem.out_of_bounds
```

`inout`: may grow and move the block. `escaping into value`: `added` is
kept in the list's storage and nowhere else. `from held value`: the
result is what the list holds, not a view of its block. `from value`: a
view that locks the list. Each of the four words answers a question no
other word answers. Removing any one either loses a check (`inout`
locks views [0830]) or refuses a program the library has (`held`:
two usability rows of the second roadmap; `into`: a frame node on a frame list).

`core/map` on the branch:

```landin
install_at: (key: type is cmp.hashable, item: type,
             inout value: map(key, item), at: usize, was_dead: bool,
             escaping into value added_key: key,
             escaping into value added_item: item) -> (placed: bool)
```

`core/fibre`, prototype 5's caller-stack fibres:

```landin
    … escaping into g state: state_type)
```

`hosted/blocking`, the field-supplied conformance:

```landin
host is io.files through services
host is io.process through services
```

Without `through`, each line is again one forwarding routine per entry:
34 routines over eight concepts before D1363.

### What the reduction changes, shown where it applies

```landin
-- [1220] today: write into a payload through the arm
match s.kind
    inline(inout buf): buf[0] = v
    …
-- reduced: read, change, assign the case
match s.kind
    inline(buf):
        mut b := buf
        b[0] = v
        s.kind = inline(b)
    …

-- D433 today: consume the pointer the arm holds
match t
    ptr (sink l): free_tree(memory, l)
-- reduced: the routine takes the union sink and matches it itself
free_node: (…, sink t: tree_ref) -> none = match t … end
```

```landin
-- [1270] today: one type, two conformances keyed by input labels
indexable: type = concept (t: type, idx: type, item_type: type)
    get: (s: t, i: idx) -> (item: item_type)
end indexable
utf8 is indexable (idx: usize, item_type: u32, get: utf8_nth)
utf8 is indexable (idx: position, item_type: u32, get: utf8_at_pos)
-- reduced: one input; the two ways are two concepts, or two functions
by_count: type = concept (t: type)
    nth: (s: t, i: usize) -> (item: u32)
end by_count
by_position: type = concept (t: type)
    at: (s: t, i: position) -> (item: u32)
end by_position
utf8 is by_count (nth: utf8_nth)
utf8 is by_position (at: utf8_at_pos)
```

The last rewrite is the one with a real cost: a generic routine over
"anything indexable by any index type" cannot be written. Nothing in the
library writes one (0 multi-input concepts in 31), and `any C` already
refuses a concept with more than one input (D145).

## Judging the vocabulary as a whole

**Words that say the same thing in different positions, and could be
one.** Two already are: `is` is one word for constraint, conformance and
parents, with one meaning ("conforms to"); `escaping` takes an optional
target rather than having a second keyword. The one overloaded word is
`mut`: on a binding it means "may be rebound", in `ptr mut`/`[]mut` it
means "may write the pointee". [0070] keeps them apart deliberately as
two independent questions, and a second spelling would add a word. Keep.

**Pairs where one is the default.** Each pair already has its default
unwritten: convention `in`, non-escaping, read-only, immutable,
independent result, plain `from` (the broader one) beside `held`. The
only lapse is that the default can also be written: `in`, which the
library writes 0 times and which D140 kept only as "a distinct syntax
fact". Remove it.

**Words added to patch one case where a general rule already covered it.**
- `sink` on a match arm (D433) answered one example, `free_tree`'s
  `ptr (sink l)`. The `sink` parameter already covers it: pass the union
  and match inside. The library uses it 0 times. Remove.
- `inout` on a match arm ([1220], the first spec) owns the
  alias-until-last-use cluster: D77, D78, D85, D405, D1085, D1112. A
  copy and an assignment cover it. The library uses it 0 times. Remove.
- The call through a concrete type's name (D1364) answered one private
  routine in `hosted/blocking`, and D1363 removed that routine the same
  day. Calling the supplying function by name always covered it. It has
  no consumer now. The maintainer has decided to keep it, so it stays.
  But it is the clearest case here of a form outliving its reason.
- `held` (D1369) answers two usability rows (two usability rows of the second roadmap). A more
  general rule nearly covers it: a `from` result whose type is a type
  formal of the routine, or built only from formals by value, cannot be a
  view of the source's own storage beyond D1369's stated non-guarantee.
  That rule derives `held` from the signature for 10 of the 11 results
  the library marks. The eleventh, `core/tree`'s `get`, returns the
  concrete `node`, where only the author knows. So the rule does not
  replace the word. Adopting it would leave two ways to say one thing.
- `through routine`, the computed form inside D1363, has 3 uses, all in
  `hosted/events`, where the system handle is per thread. It is a case on
  top of the general `through field`. Keep it: the alternative is three
  forwarding conformances written out.
- `escaping into` (D445) is not a patch. Plain `escaping` refused every
  frame-to-frame keep, and prototype 5's fibres on caller stacks needed
  exactly that. On R13.92's branch it becomes the container insert's
  normal form (15 uses in `core`).

**Is there a smaller set that expresses everything the library writes?**
Yes: the set above, six forms smaller, and the library's signatures do
not change. I found no smaller set that rewrites library signatures and
keeps their checks:
- `sink` into `inout`: `close(sink f)` is the only check against using a
  handle after close. 13 of the 18 sunk library values are handles.
- `inout` into passing `addr x` as `ptr mut`: loses [0830]'s view lock,
  which `inout` alone triggers. A pointer argument may be passed while a
  view of its target lives.
- `escaping` always naming a target: plain `escaping` means "kept beyond
  any parameter" (module storage, an allocation), which has no parameter
  to name.
- `from` inferred: RP4, retained position, and no new evidence.

**Where a word looks redundant and I would keep it.**
- Explicit `T.entry` (D1364): redundant, kept by decision. See above.
- `through` beside entry lists: both may appear on one conformance
  (`(less: f) through inner`). That is one form with an override, not two
  forms.
- `self` is recognised by its spelling, not reserved. It looks like an
  arbitrary convention, but it is the one place a concept says which
  parameter `any` supplies. Without it the rule would be "the first
  parameter", which forbids an entry whose first parameter is not the
  value.
- `fixed` means "known at compile time" both on a formal and in
  `fixed if`: one meaning, two positions, like `is`.

## Word by word

Counts: library occurrences/files; ex = examples.md; fx = fixture files,
positive+runtime / negative. Inferable means the checker could derive it
from the body. "Promise" means only the author can state it, and the
checker holds callers to it.

| Form | Since | Means | Near | lib | ex | fx | Inferable? | Lost without it |
|---|---|---|---|---|---|---|---|---|
| `ptr T` | first spec | a read-only reference, one word | `[]T` | 313/30 | 2 | 173/199 | no (a type) | the pointer itself |
| `ptr mut T` | first spec | may write the pointee | binding `mut` | 540/52 | 9 | 189/133 | no | write permission in types |
| `[]mut T` | first spec | may write the viewed elements | `ptr mut` | 205/50 | 13 | 100/52 | no | the same for slices |
| binding `mut` | first spec | the binding may change | `ptr mut` | 485/56 | 230 | 782/411 | yes, but deliberate | immutability by default |
| `addr`, `.val` | first spec | take an address; name the pointee | — | 334/46, 855/39 | 83, 8 | many | no | pointers |
| `in` written | D140, 08-30 | same as unwritten | unwritten | **0** | 0 | 4/1 | — | nothing |
| `inout` | first spec | may replace the caller's place, exclusively | `ptr mut` | 187/37 (176 params) | 44 | 155/87 | no: a promise | the view lock and exclusivity |
| `sink` | first spec | consumes; the caller's place is dead after | `inout` | 22/14 (18 params) | 1 | 21/22 | no: a promise | use-after-close of handles |
| arm `inout`/`sink` | first spec / D433 10-19 | write or consume through a match binding | `inout`/`sink` params | **0** | 0 | 9/8 | — | only brevity |
| `escaping` | first spec | the callee may keep this beyond the call | `escaping into` | 48/13 | 0 | 18/36 | from the body, but RP4 keeps it written | frame-escape checking at call sites |
| `escaping into p` | D445, 10-27 | kept only in `p`'s storage | `escaping` | 2/2 (15 in `core` on the branch) | 0 | 2/5 | same | frame nodes on frame lists, fibres on caller stacks |
| `from p` | first spec | the result borrows from `p` | `held` | 133/41 | 2 | 97/93 | from the body, RP4 | the caller's borrow tracking |
| `from held p` | D1369, 11-16 (branch) | the result is what `p` holds, not a view of it | `from p` | 11/5 (branch) | 0 | 1/1 | partly from the type, 10 of 11 | pushing back what was read out (two usability rows of the second roadmap) |
| `unchecked` | first spec | a region without the removable checks; origins stay | — | 26/9 | 0 | 43/9 | no | checked defaults |
| `concept` | first spec | a bundle of entries over one type | — | 31/17 | 1 | 103/92 | no | generics |
| `is` (×3) | first spec | conforms to | — | 161/23 constraints, 156/42 conformances, 7/7 parents | 12, 5 | many | no: conformance is always declared | — |
| `through` | D1363, 11-15 | a field (or a routine) supplies the entries | entry list | 17/4 | 0 | 9/11 | no | 34 forwarding routines |
| generic binder | first spec | one conformance for a whole family | — | 5/5 | 0 | 25/3 | no | traversing or sorting a generic container generically |
| input labels, multi-input concepts | first spec ([1270]) | one type conforms several ways | two concepts | **0** | 0 | 5/7 | — | "indexable by any index type" generic code; nothing written today |
| `any C`, `any(p)` | first spec | a run-time provider; build one | generics | 56/15, 12/9 | 4, 82 | many | no | runtime dispatch, printing |
| `self` | first spec (recognised name) | the parameter `any` supplies | — | 410/43 | 4 | 110/66 | no | entries callable through `any` |
| `t.entry` | first spec | an entry through a type parameter | `T.entry` | 107/18 | 0 | 36/7 | no | generics |
| `T.entry` | D1364, 11-15 | an entry through a concrete type | calling the function | **0** | 0 | 2/3 | — | nothing written today (kept by decision) |
| `distinct` | first spec | a new type, same representation | alias | 9/7 | 0 | 37/35 | no | nominal types |
| `is zeroable` | first spec | may be zero-filled | `zeroed` | **0** | 0 | 4/4 | yes: the compiler knows | nothing written today |
| `fixed` formal | first spec | a compile-time integer | `fixed if` | 28/3 | 0 | 22/26 | no | arrays sized by a parameter |
| `type` formal | first spec | a compile-time type | — | 330/30 | 13 | 238/229 | no | generics |

`provides`, `over`, `from value`, `lend`/`lent`, `ref` and `out` are not
language words. `provides` is tour prose. `over` is library naming
(`events.over`, `region.over`). `from value` is `from` naming a parameter
called `value`. `lend`, `lent` and `ref` do not exist. `out` is an
assembler operand word ([1630]) and outside this vocabulary. `with` belongs
to `break with`, which is control flow, SC-01.

## What I am unsure of

1. **`held` against the type rule.** A rule that derives `held` from a
   result typed by a type formal covers 10 of 11 uses and needs no word in
   generic containers. I keep the word because the eleventh (`tree.get`)
   would otherwise refuse or need `held` anyway, and two ways to say one
   thing is worse than one word. If `core/tree`'s `get` could return a
   generic or handle type instead, the word could go. The maintainer
   decided that `held` ships with R13.92, and that the derivation is R19's
   candidate SC-23.
2. **Multi-input concepts.** Zero library use, and removal simplifies the
   conformance key, L0341 and D145's restriction. But the first spec put
   them there on purpose ([1270]: "how finely they distinguish what an
   operation costs, is the standard library's business"), and R20's
   library review is where that business is decided. I would decide this in
   R20, not R19.
3. **Arm `inout`.** The copy-and-assign replacement copies the payload. For
   a large inline payload (`core/small`'s inline array in prototype 3)
   that cost is unmeasured. The library uses variants in only four files,
   so the absence of uses is weaker evidence than elsewhere.
