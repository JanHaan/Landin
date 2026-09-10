# Prototype 3 derivation

This fixture is the executable R4.70 derivative of
`prototype-3-containers.md`. The prototype remains the historical design and
finding record; its raw-storage sketches and obsolete spellings are not edited
or silently treated as current APIs. The reusable program is
`examples/derived_containers/workload`, while this directory supplies the
hosted entry and exit-status oracle. The run writes neither stdout nor stderr:
status 42 is its complete oracle.

## Section coverage

| Prototype section or pressure | Executable evidence |
|---|---|
| Opening parameterization, allocator, escape and specialization pressure | One `containers_run` composes the repository `core` modules without copying them. `evidence_less` is a constrained generic routine called with `i32` and `u32`; both calls execute the selected `sort.ordered.less` entry. The heterogeneous drawable list retains genuinely runtime-selected evidence. |
| `core/mem` — allocation as a capability | Every allocating container receives its provider explicitly. The workload uses `heap.system`, `mem.arena`, `pool.provider`, and the generic `failing.counted(pool.provider)`/`failing.counted(heap.system)` conformances. No container stores a provider or imports a hidden heap. |
| `core/mem` — bump allocator over borrowed storage | `map_operations` runs over an explicit caller-backed `mem.arena`. Its no-op `free` is used only for ordinary arena composition, never as evidence that failure rollback reclaimed storage. |
| `core/mem` — allocator that fails on purpose | Vector, small-vector, map, and tree failures use `failing.count_down` over a reclaiming fixed pool. Each path checks attempts, delegated calls, injected failures, frees, live extents, and the pool's accepted/rejected free counts. |
| `core/mem` — slices from an allocator | `raw_reference_prefix` obtains one exact provider extent, creates private typed storage with `mem.reserve`, publishes two pointer values with `mem.admit`, exposes only the initialized prefix, releases both values, disposes empty storage, and frees the original byte extent. It never fabricates a typed spare-capacity slice. |
| `core/vec` — growing array | The application reverses a fixed array into the prototype's 20 descending numbers, pushes all 20 into a list, sorts its initialized view, observes 1 and 20 at the ends, pops and restores the tail, then explicitly releases it. A separate pointer list injects replacement failure at length eight, proves the old first/eighth values and allocation remain intact, retries growth, and finishes with zero live pool extents. |
| `core/small` — inline capacity and spilling | `small(i32, 2)` stores 11 and 13 inline. An injected first spill failure leaves the inline arm, length, capacity, and values unchanged; retry spills to capacity four, pop returns 17, and release re-establishes an empty inline value while both wrapper and pool report zero live extents. |
| `core/map` — open addressing without null | The normal arena path declares both composed conformances, inserts colliding keys, updates through a preceding probe chain, removes and reuses a tombstone, performs no-tombstone geometric growth, gets retained values, and removes again. A separate churn path reaches capacity-eight pressure with three tombstones, proves through the public `capacity()` query that the next absent insertion transactionally compacts at the unchanged capacity, resets the tombstone count, and preserves every survivor. The application path also maps the sorted numbers to squares and observes key 3 as 9 and key 20 as 400. |
| `core/map` — entry enumeration | `entries()` creates a manual bucket-position cursor. `next_entry(map, cursor)` scans monotonically, returns each live `entry(K, V) from map` once, and reports `end_of_entries` on both empty and exhausted maps; repeated exhausted calls remain exhausted. Before compaction, exact count and sums prove three live records are found through three interleaved tombstones without yielding a dead bucket; the post-compaction walk finds all four survivors. Scalar entries are copied before a later mutation, while pointer-bearing keys and values exercise retained entry origins. The cursor deliberately has no map identity or generation check, is not transferable between maps, and must be discarded after any mutation. |
| `core/map` — three-acquisition rollback | Three independent reclaiming-pool cases inject failure before the first, second, and third acquisition of a same-capacity tombstone-compaction replacement. They observe exact partial frees 0, 1, and 2, unchanged capacity/tombstones/old entries, a missing new key, successful three-acquisition retry, retirement of the three old extents, tombstones reset to zero, and final zero live extents. |
| `core/tree` — arenas and indices | Eight named leaves receive IDs 0 through 7. Refused leaf and branch appends preserve every ID, count, retained name, and cached leaf count. The branch retry receives ID 8, names the contiguous range, reports eight leaves, retains `"branch"`, and releases the two vector extents exactly. |
| `app` — using all of it | `containers_run` is the stable application routine. It executes the 20-number list/sort/squares flow, array compositions, direct raw prefix, every deterministic failure path, tree, and heterogeneous drawables before producing one boolean for `main` to map to status 42. |
| `app` — heterogeneous `any drawable` values | A `vec.list(any drawable)` contains interleaved `circle` and `label` values. The two implementations have different sizes and field offsets, and their draw entries make different counter/total contributions. `draw_all` invokes each erased `ptr mut T` entry, mutating the original provider counters and a shared canvas; exact totals, per-type call counts, and two label sentinels detect incorrect evidence routing. The initialized any pairs survive vector storage and traversal; explicit release leaves the counted hosted allocator at zero live allocations. |
| Cross-prototype support | Prototype 2's rule that unknown `any` evidence remains indirect is exercised by the drawable calls. Prototype 4's heterogeneous mutable capability-chain pressure is represented by different erased layouts in one list, original-pointee mutation, initialized-prefix traversal, explicit allocator threading, and no assumption that optional specialization replaces semantic evidence. |

## R4.70 compositions

The derivative keeps all three previously isolated compositions in ordinary
workload code rather than in unreachable probes:

- `reverse_seed` accepts the complete `[20]i32` directly as `inout` and reads
  and writes indexed parameter elements while reversing the seed used by the
  vector.
- `numbers_path` saves `lenof source`, mutates the slice descriptor afterward,
  and uses both the saved source-free scalar and the shortened source.
- `array_compositions` ranges directly over `array_box.rows`, whose element is
  the fixed array `row`, writes a complete selected row, and reads the complete
  nested shape back.

The comments `R470_DEBUG_EVIDENCE_ENTRY`, `R470_DEBUG_SORTED_LIST`, and
`R470_DEBUG_CONTAINERS_DONE` are stable debugger source markers in executed
workload. The first is hit with `(left, right) = (-1, 1)` and
`(0xFFFF_FFFF, 1)`: equal low 32-bit patterns require signed `i32` to report
less and unsigned `u32` not to report less. At the second, `count = 20`,
`first = 1`, and `last = 20`. At the third, all fourteen path locals are true:
`signed_order`, `unsigned_order_ok`, `numbers_ok`, `arrays_ok`, `raw_ok`,
`vector_ok`, `small_ok`, `map_ok`, `reference_entries_ok`,
`map_first_failure_ok`, `map_second_failure_ok`, `map_third_failure_ok`,
`tree_ok`, and `drawables_ok`.

The map policy is equally explicit. Tombstone pressure rebuilds transactionally
at the current capacity; pressure with no tombstones doubles geometrically.
Enumeration exposes `entries()` and `next_entry`, returning `entry(K, V) from
map` or `end_of_entries` for an empty or exhausted walk. Its cursor is only a
manual bucket position: there is intentionally no map/generation validation,
it cannot be transferred between maps, and any mutation invalidates it.

## Findings Z1-Z19

| Finding | Derivative disposition and evidence |
|---|---|
| Z1 — quantified conformance for parameterized types | `failing.counted(A)` is used with both pool and heap providers through its existing quantified `mem.allocator` conformance. The derivative does not revive the source-incompatible historical `vec.list(T) is iterable` sketch; retained-origin traversal uses `vec.used`. |
| Z2 — constrained and fixed parameters on types | `map.map(collision_key, i32)` selects a constrained key parameter, while `small.small(i32, 2)` selects a fixed inline bound. Both execute, rather than serving only as type-checking examples. |
| Z3 — pointer/slice system primitives | D151's private raw-storage operations are used through `mem.reserve`/`used`; the rejected general `slice_from`, `base_of`, and public pointer-arithmetic sketch is not duplicated. |
| Z4 — size and alignment in evidence | Constrained allocation runs through map and every generic provider wrapper. Pool slot alignment and exact extents are checked by their existing target-width-aware APIs; no specialization-time host constant is assumed. |
| Z5 — accessor results retain their source | `vec.used`, `small.used`, and `mem.used` views are consumed inside scopes that end before growth or release. Pointer-bearing `map.next_entry` results likewise retain the map while used. `negative/r470-container-entry-live-map` proves that keeping such an entry live blocks both insertion and release. |
| Z6 — `escaping` on a generic value | Pointer vectors, map entries, tree names, and erased drawable pairs all cross generic retaining operations. Reference-free scalar cases use the same APIs without a special convention. |
| Z7 — variant pattern binding aliases payload storage | Small-vector inline writes, the spill transition, spilled pop, and release execute both variant arms. Publication follows the last inline-payload read, and post-failure views still expose the original inline values. |
| Z8 — honest uninitialized storage | D151/D198 representations are used exactly: initialized prefixes for vec/raw K/V values and fully initialized map buckets. Neither pointer nor erased values need a zero image, and no capacity slice claims uninitialized objects exist. |
| Z9 — concrete allocator error set | Every provider and counted wrapper exposes `mem.out_of_memory`; injected and delegated failures are distinguished with counters while container error handling remains provider-independent. |
| Z10 — allocator threading | Every mutating allocation/release call names the provider argument. Lists and maps retain only their item/key/value parameters and move between provider implementations without a provider type in their identity. |
| Z11 — composed concepts require explicit parents | `u32` and `collision_key` each declare `map.equatable` and `map.hashable` separately. `negative/core-map-missing-parent-conformance` remains the stronger direct refusal. |
| Z12 — a pointer target is an `inout` place | Each counted wrapper retains `ptr mut` to its concrete provider and delegates allocation/free through `.val`; success and free counters prove those calls reach the original state. |
| Z13 — `sink` on a struct field | The obsolete `drop_slice` sketch is not recreated. Current `mem.dispose`, `vec.release`, `small.release`, `map.release_map`, and `tree.release` clear their live initialized states before exact provider release. |
| Z14 — payload-free variant arm | `tree.add_leaf` and subsequent `tree.get` execute the current payload-free `leaf` arm; branch nodes execute the payload-bearing arm and cached count path. |
| Z15 — no gap | Preserved as the prototype's deliberate no-gap finding. Bounded `while` loops, ordinary `break`, failure recovery, and result assignment express every probe/traversal here; the derivative introduces no label, value-break, or complete-clause requirement. |
| Z16 — reference permission follows the reference | Sorting receives a writable initialized view; read-only tree names and pointer values retain their permissions; mutable erased drawable entries update their original pointees without replacing the stored evidence pair. |
| Z17 — contextual named struct construction | Pool records, map keys, nodes, canvas values, and parameterized container results are constructed in named contexts throughout the running program. |
| Z18 — conventions do not appear at call sites | Direct calls pass ordinary places (`reverse_seed(seed)`, container/provider state, and pointer targets) while declarations alone carry `inout`, `escaping`, and constrained conventions. |
| Z19 — exact failure rollback | Reclaiming pool evidence—not arena no-op free—proves vector replacement atomicity, small spill atomicity, all three same-capacity map-compaction acquisition positions with 0/1/2 partial frees and retry, and tree append preservation. Every path checks final zero live extents and no rejected free. |

## Negative controls

The derivative adds three controls specific to its public application and map
enumeration surface:

- `negative/r470-container-missing-order-evidence` calls `evidence_less` with a
  type that has no `sort.ordered` conformance (`L0318`).
- `negative/r470-container-entry-live-map` keeps a pointer-bearing entry live
  across both `insert` and `release_map`; each mutation is refused (`L0315`).
- `negative/r470-container-entry-wrong-from` extracts a pointer item returned
  by `next_entry(source, cursor)` but claims `from wrong`; exact source matching
  rejects it (`L0316`).

Existing focused negatives isolate the remaining contracts more strongly than
copies under a new prefix would:

- missing composed evidence: `negative/core-map-missing-parent-conformance`
- live initialized views: `negative/core-vec-used-live-growth`,
  `negative/core-vec-used-live-release`, and `negative/core-small-live-view`
- frame-backed raw/list views: `negative/core-mem-used-frame` and
  `negative/core-vec-used-frame`
- retained map key/value frame escape: `negative/core-map-key-frame-escape` and
  `negative/core-map-value-frame-escape`
- retained tree names/nodes: `negative/core-tree-frame-name` and
  `negative/core-tree-node-escape`
- erased frame origins: `negative/any-frame-origin-escape` and
  `negative/generic-any-carrier-frame-escape`
- source-bearing traversal mismatch: `negative/iterable-retained-item-source`

These citations are intentional reuse of the R4.20 corpus, not omitted R4.70
coverage.
