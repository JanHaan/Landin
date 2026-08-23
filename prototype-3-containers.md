## LANDIN PROTOTYPE 3 — A GENERIC CONTAINER LIBRARY

```landin
Current with specification 0.1.0. Its own findings Z1-Z19 are all
resolved below.

This one was chosen because it presses on five things at once:
parameterised types, concepts, allocator threading, escape rules and
specialisation. A driver never instantiates anything and a parser
barely does. A container library does nothing else.

Four containers, deliberately different in shape:

  vec    a growing array — the one that reallocates, so it is where
         the borrow rule earns its keep or fails to
  small  inline capacity spilling to the heap — a fixed value
         parameter and a variant holding storage
  map    open addressing — a composed concept, and no null to use
         as an empty marker
  tree   arena-backed, children as indices — the idiom the language
         keeps recommending, tested for once

Two conventions this file adopts, because calls could not be written
without deciding them, and both follow the tour rather than inventing:

  A type parameter that appears in the type of a value parameter is
  deduced and left out at the call, as sort(values) does at [1300]. One
  that appears only in the return type cannot be deduced and is named,
  as sort(T: i32, data: values) does in the same place. Explicit type
  arguments are therefore always named, never positional, which keeps
  positional arguments to ordinary values.

Where a spelling had to be invented, the line is marked [Zn] and the
question is written out at the end.
```

---

## core/mem  —  allocation as a capability

```landin
public out_of_memory: atom

```
The concept is the one from the tour at [1360], unchanged. Note
what it settles for everybody: the error set of alloc is concrete.
A concept entry is reached through a table, and [0960] forbids an
inferred set where the set must be concrete, so an allocator that
wanted an error of its own could not have one. Out of memory is
out of memory, so that is the right answer here — but it is a
general constraint on concept design that nobody has stated. [Z9]
```landin
public allocator: type = concept (A: type)
    alloc: (inout a: A, size: usize, alignment: usize) -> (p: ptr mut u8) ! out_of_memory
    free:  (inout a: A, p: ptr mut u8, size: usize) -> none
end allocator

```
Three primitives every allocator needs and that the language does
not name. They are the system-tool layer of [0490], so belonging to
core and nowhere else is defensible — but core has to be able to
say them, and that privilege should be written down rather than
assumed. [Z3]
```landin
public offset:     (p: ptr mut u8, n: usize) -> (q: ptr mut u8) = ... end
public base_of:    (T: type, s: []mut T) -> (p: ptr mut u8) = ... end
public slice_from: (T: type, p: ptr mut u8, n: usize) -> (s: []mut T) = ... end

```
slice_from is where the honesty runs out, and it is worth being
plain about it. It hands back a []T over storage holding no T at
all. The language has no word for uninitialised memory: bindings
must be assigned before use, nothing says that about the elements
of a slice, and requiring T to have a zero image would rule out
list(ptr node), which is exactly what the tree below needs. So the
containers carry the invariant themselves — vec by its len, map by
its state array. slice_from is where the promise is made rather
than checked, which is [1730] with the check missing. [Z8]

```landin
public align_up: (v: usize, a: usize) -> (r: usize) =
    r = (v + a - 1) / a * a
end align_up

```

## core/mem  —  a bump allocator over borrowed storage

```landin
public bump: type = struct
    base: ptr mut u8
    size: usize
    used: usize
end bump

```
escaping, for a real reason: the bump keeps the buffer long after
this call returns, so the caller has to prove the buffer outlives
it. A buffer on the stack of a function that returns the bump is
refused, and that is the bug this rule exists for.
```landin
public bump_over: (escaping buf: []mut u8) -> (b: bump) =
    b = (base: base_of(buf), size: lenof buf, used: 0)
end bump_over

bump_alloc: (inout a: bump, size: usize, alignment: usize)
            -> (p: ptr mut u8) ! out_of_memory =
    off := align_up(a.used, alignment)
    fail out_of_memory when off > a.size
    fail out_of_memory when size > a.size - off
    p      = offset(a.base, off)
    a.used = off + size
end bump_alloc

```
A bump frees nothing. The signature still takes the size, because
the concept says so and a general allocator needs it.
```landin
bump_free: (inout a: bump, p: ptr mut u8, size: usize) -> none = ... end

bump is allocator (alloc: bump_alloc, free: bump_free)

```

## core/mem  —  an allocator that fails on purpose

This is the payoff of [1360] that almost nobody gets in C: the
out-of-memory path of every container below is reachable from a
test, by handing it this instead of the real one.

It is also the first type taking a constrained type parameter. The
tour has list: type (T: type) and it has a constrained parameter
on a function, but never the two together. [Z2]
```landin
public counted: type (A: type is allocator) = struct
    inner: ptr A
    left:  u32
end counted

public count_down: (A: type is allocator, escaping inner: ptr A, n: u32)
                   -> (c: counted(A)) =
    c = (inner: inner, left: n)
end count_down

counted_alloc: (A: type is allocator, inout c: counted(A),
                size: usize, alignment: usize) -> (p: ptr mut u8) ! out_of_memory =
    fail out_of_memory when c.left == 0
    dec c.left
```
Passing a pointer target where an inout is wanted. Surely
intended, never shown. [Z12]
```landin
    p = try A.alloc(c.inner.val, size, alignment)
end counted_alloc

counted_free: (A: type is allocator, inout c: counted(A),
               p: ptr mut u8, size: usize) -> none =
    A.free(c.inner.val, p, size)
end counted_free

```
And here is the hole this file kept walking into. The line means
"for any A satisfying allocator, counted(A) satisfies allocator",
and there is nowhere to put the "for any A". Written with a prefix
binder, which is invented. [Z1]
```landin
(A: type is allocator) counted(A) is allocator
    (alloc: counted_alloc, free: counted_free)

```

## core/mem  —  slices from an allocator

sizeof and alignof applied to a type parameter. Specialised they
are constants; compiled once against a table they are not, so the
evidence has to carry the size and the alignment of the type as
well as the concept's functions. [1310] describes the table as
holding the functions and says nothing about layout. Without this
no generic container can allocate at all. [Z4]
```landin
public new_slice: (T: type, A: type is allocator, inout a: A, n: usize)
                  -> (s: []mut T) ! out_of_memory =
    raw := try A.alloc(a, n * sizeof T, alignof T)
    s   = slice_from(T: T, p: raw, n: n)
end new_slice

```
sink, and it earns its place: after drop_slice the place the
caller named is dead, so the obvious use-after-free is refused and
it costs nothing at run time.
What it is not is ownership. A slice descriptor is a copyable
value: copy it first and the copy is refused nothing, so freeing
through both is a double free this does not catch. sink is a
use-after-consume check on one place. Affine values would be the
other thing, and they are parked with a condition in BACKLOG.md.
The catch: every caller below passes a struct field rather than a
binding, and what sink means for a field is not stated. [Z13]
```landin
public drop_slice: (T: type, A: type is allocator, inout a: A, sink s: []mut T)
                   -> none =
    return when lenof s == 0
    A.free(a, base_of(s), lenof s * sizeof T)
end drop_slice

```

## core/vec  —  a growing array

```landin
import core/mem

public empty: atom

```
The capacity is the length of the slice; len is how much of it
holds real values. Elements at and above len are the storage that
slice_from made a promise about and nobody has written yet.
```landin
public list: type (T: type) = struct
    items: []mut T
    len:   usize
end list

public new_list: (T: type) -> (l: list(T)) =
    l = (items: [], len: 0)
end new_list

grown: (cap: usize) -> (n: usize) =
    n = if cap == 0 then 8 else cap * 2 end if
end grown

```
The allocator is threaded, not stored, and the reason turned out
sharper than the visibility argument that was made for it. If list
stored its allocator it would be list(T, A), so a list in an arena
and a list on the heap would be different types and no function
could take both. Threading keeps the type parameterised by T
alone. The price is one more argument at every mutating call,
which is what the code below reads like: judge it there. [Z10]
```landin
public reserve: (T: type, A: type is allocator,
                 inout l: list(T), inout a: A, want: usize)
                -> none ! out_of_memory =
    return when want <= lenof l.items
    fresh := try mem.new_slice(T: T, a: a, n: want)
    for k in 0..<l.len do
        fresh[k] = l.items[k]
    end for
    mem.drop_slice(a, l.items)
    l.items = fresh
end reserve

```
escaping on v reads oddly until T is taken seriously. For T = u32
it says nothing: [0840] already has it that a value holding no
references is unconstrained, so the obligation is vacuous and the
caller proves nothing. For T = ptr node it is exactly right, since
the list keeps what v refers to. One word covers both, because the
origin travels with the type. [Z6]
```landin
public push: (T: type, A: type is allocator,
              inout l: list(T), inout a: A, escaping v: T)
             -> none ! out_of_memory =
    if l.len == lenof l.items then
        try reserve(l, a, grown(lenof l.items))
    end if
    l.items[l.len] = v
    inc l.len
end push

public pop: (T: type, inout l: list(T)) -> (v: T) ! empty =
    fail empty when l.len == 0
    dec l.len
    v = l.items[l.len]
end pop

```
One accessor, since 0.1.0. It hands out the widest permission the
storage has, and a caller who wants less writes
'xs: []i32 = vec.used(l)' and relaxes it by [0440]. The pair of
accessors that every language with deep const ends up needing is
not needed here. The from clause says the one thing the signature
could not otherwise: the list has to hold still while the view is
alive.
```landin
public used: (T: type, l: list(T)) -> (s: []mut T from l) =
    s = l.items[0..<l.len]
end used

public release: (T: type, A: type is allocator, inout l: list(T), inout a: A)
                -> none =
    mem.drop_slice(a, l.items)
    l.items = []
    l.len   = 0
end release

```
The four entries of iterable, and the same missing quantifier as
before. The cursor is an index rather than a pointer, so nothing
can move under the traversal, at the price of one bounds check the
compiler can hoist. [Z1]
```landin
list_first:  (T: type, s: list(T)) -> (c: usize)   = 0 end
list_at_end: (T: type, s: list(T), c: usize) -> (yes: bool) = c >= s.len end
list_item:   (T: type, s: list(T), c: usize) -> (v: T)      = s.items[c] end
list_next:   (T: type, s: list(T), c: usize) -> (c2: usize) = c + 1 end

(T: type) list(T) is iterable (Cur: usize, Item: T,
                               first:  list_first, at_end: list_at_end,
                               item:   list_item,  next:   list_next)

```

## core/small  —  inline capacity, spilling

```landin
import core/mem

```
A fixed value parameter on a type. [1520] gives one on a function
and [1350] a type parameter on a type; a small vector is the
ordinary shape that wants both. [Z2]
Restricted to a T with a zero image, and that restriction is the
honest form of [Z8]: the inline slots have to hold something and
[0540] gives no honest value for a T without one. So
small(ptr node, 4) does not exist until a raw-storage type does
[0510].
```landin
public small: type (T: type is zeroable, fixed N: u32) = struct
    len: usize
    store: variant
        inline:  (buf: [N]T) |
        spilled: (heap: []mut T)
    end store
end small

public new_small: (T: type is zeroable, fixed N: u32) -> (s: small(T, N)) =
    s = (len: 0, store: inline(buf: zeroed))
end new_small
```
zeroed is honest now, because T is constrained to have a zero
image. What that costs is that the shape does not exist for the T
which wanted it most. [Z8]

The match bindings are inout, which is invented. [1210] shows
bindings being read, and whether a binding aliases the payload or
copies it is nowhere stated. For a [N]T payload the difference is
a whole array copy. The mechanism to reuse is obvious, since in,
inout and sink are already the parameter conventions, which is
[1710]'s "an existing mechanism expresses it" exactly. [Z7]
```landin
public push_small: (T: type is zeroable, fixed N: u32, A: type is allocator,
                    inout s: small(T, N), inout a: A, escaping v: T)
                   -> none ! out_of_memory =
    match s.store
        inline (buf):
            if s.len < usize(N) then
                buf[s.len] = v
                inc s.len
                return
            end if
            fresh := try mem.new_slice(T: T, a: a, n: usize(N) * 2)
            for k in 0..<s.len do
                fresh[k] = buf[k]
            end for
            fresh[s.len] = v
            inc s.len
            s.store = spilled(heap: fresh)

        spilled (heap):
            if s.len == lenof heap then
                bigger := try mem.new_slice(T: T, a: a, n: s.len * 2)
                for k in 0..<s.len do
                    bigger[k] = heap[k]
                end for
                mem.drop_slice(a, heap)
                heap = bigger
            end if
            heap[s.len] = v
            inc s.len
    end match
end push_small
```
The inline arm assigns to s.store while buf is still bound out of
it. That is the borrow rule of [0830] at point blank range: the
write invalidates the binding. Here it happens to be the last use,
but the rule is written about locals and a match binding is not
obviously one. [Z7]

```landin
public small_used: (T: type is zeroable, fixed N: u32,
                   s: small(T, N)) -> (v: []mut T from s) =
    v = match s.store
            inline  (buf):  buf[0..<s.len]
            spilled (heap): heap[0..<s.len]
        end match
end small_used
```
A match as an expression, from [1080]. Both arms yield []T, and the
inline arm yields a slice into the small vector itself — which is
exactly what the from clause has to say, or the caller could spill
the vector while holding the view. The other half of the question
stays with [Z7]: if an in binding copies the payload rather than
aliasing it, this slice points into a copy that is already gone.

## core/map  —  open addressing, without null

```landin
import core/mem

public missing: atom

public equatable: type = concept (K: type)
    eq: (a: K, b: K) -> (yes: bool)
end equatable

```
A composed concept, per [1340]. A type conforming to hashable needs
its own equatable conformance as well: the composed declaration
supplies only what it adds. The tour states that rule and then
shows button is widget supplying only focus, with no sign of the
drawable and clickable conformances it must also have. [Z11]
```landin
public hashable: type = concept (K: type) is equatable
    hash: (k: K) -> (h: u64)
end hashable

```
No null, so no key value can mean empty, and a sentinel key would
be a lie for K = ptr node in any case. A parallel state array is
what a good implementation does anyway, for the probe's cache
behaviour, so the missing null pushed the design the right way
without anybody arguing about it.
```landin
slot_free: atom
slot_used: atom
slot_dead: atom
slot: type = slot_free | slot_used | slot_dead

public map: type (K: type is hashable, V: type) = struct
    state: []slot
    keys:  []K
    vals:  []V
    len:   usize
    dead:  usize
end map

public new_map: (K: type is hashable, V: type) -> (m: map(K, V)) =
    m = (state: [], keys: [], vals: [], len: 0, dead: 0)
end new_map

```
hash returns u64 and the index is usize, which is u32 on the small
target. usize(K.hash(k)) would compile and then trap in the field
on any key wider than a byte or two, so the reduction has to
happen in u64 first. No implicit conversion caught a portability
bug that C would truncate silently and Rust would wrap silently,
and it caught it while reading rather than while running.
```landin
index_of: (K: type is hashable, k: K, n: usize) -> (i: usize) =
    i = usize(K.hash(k) % u64(n))
end index_of

public get: (K: type is hashable, V: type, m: map(K, V), k: K)
            -> (v: V) ! missing =
    n := lenof m.state
    fail missing when n == 0
    mut i := index_of(k, n)
    loop do
        s := m.state[i]
        break when s == slot_free
        if s == slot_used and K.eq(m.keys[i], k) then
            v = m.vals[i]
            return
        end if
        i = (i + 1) % n
    end loop
    fail missing
end get

```
Grow at three quarters and count tombstones, so a map that is
churned rather than filled still rehashes.
```landin
crowded: (K: type is hashable, V: type, m: map(K, V)) -> (yes: bool) =
    yes = (m.len + m.dead + 1) * 4 > lenof m.state * 3
end crowded

```
place never allocates and never fails, because the caller has
already made room. That is why it can be called from inside
rehash without the cleanup problem below repeating.
```landin
place: (K: type is hashable, V: type, inout m: map(K, V),
        escaping k: K, escaping v: V) -> none =
    n     := lenof m.state
    mut i := index_of(k, n)
    loop do
        s := m.state[i]
        if s == slot_used and K.eq(m.keys[i], k) then
            m.vals[i] = v
            return
        end if
        if s <> slot_used then
            if s == slot_dead then
                dec m.dead
            end if
            m.state[i] = slot_used
            m.keys[i]  = k
            m.vals[i]  = v
            inc m.len
            return
        end if
        i = (i + 1) % n
    end loop
end place

```
Three allocations that can each fail, and the cleanup is
triangular: the second failing frees one, the third failing frees
two. None of that is written here. undo entries are registered
where control reaches them, so the triangle comes out of the order
rather than out of the text. [Z19]
```landin
rehash: (K: type is hashable, V: type, A: type is allocator,
         inout m: map(K, V), inout a: A, want: usize)
        -> none ! out_of_memory =
    ns := try mem.new_slice(T: slot, a: a, n: want)
    undo mem.drop_slice(a, ns)

    nk := try mem.new_slice(T: K, a: a, n: want)
    undo mem.drop_slice(a, nk)

    nv := try mem.new_slice(T: V, a: a, n: want)
    undo mem.drop_slice(a, nv)

    old_state := m.state
    old_keys  := m.keys
    old_vals  := m.vals

```
Committed from here, and nothing fallible follows, which is
the discipline undo asks for: an entry cannot be called off,
so a failure after the handover would free what m now owns.
```landin
    m.state = ns
    m.keys  = nk
    m.vals  = nv
    m.len   = 0
    m.dead  = 0

    for k in 0..<want do
        m.state[k] = slot_free
    end for

    for k in 0..<lenof old_state do
        if old_state[k] == slot_used then
            place(m, old_keys[k], old_vals[k])
        end if
    end for

    mem.drop_slice(a, old_state)
    mem.drop_slice(a, old_keys)
    mem.drop_slice(a, old_vals)
end rehash

public insert: (K: type is hashable, V: type, A: type is allocator,
                inout m: map(K, V), inout a: A,
                escaping k: K, escaping v: V) -> none ! out_of_memory =
    if crowded(m) then
        try rehash(m, a, if lenof m.state == 0 then 16
                         else lenof m.state * 2 end if)
    end if
    place(m, k, v)
end insert

public remove: (K: type is hashable, V: type, inout m: map(K, V), k: K)
               -> none ! missing =
    n := lenof m.state
    fail missing when n == 0
    mut i := index_of(k, n)
    loop do
        s := m.state[i]
        fail missing when s == slot_free
        if s == slot_used and K.eq(m.keys[i], k) then
            m.state[i] = slot_dead
            dec m.len
            inc m.dead
            return
        end if
        i = (i + 1) % n
    end loop
end remove

public release_map: (K: type is hashable, V: type, A: type is allocator,
                     inout m: map(K, V), inout a: A) -> none =
    mem.drop_slice(a, m.state)
    mem.drop_slice(a, m.keys)
    mem.drop_slice(a, m.vals)
    m = new_map(K: K, V: V)
end release_map

```

## core/tree  —  arenas and indices, the idiom under test

```landin
import core/mem
import core/vec

public no_such_node: atom

```
A handle, not a pointer. u32 rather than usize, because halving
the width of every edge is the reason for doing this at all.
```landin
public node_id: type = distinct u32

```
A variant case with no payload, written bare. It is an atom, and
[1700] holds that atoms are the same idea wherever they appear, so
this ought to need no decision — but every variant in the tour
carries a payload, so the spelling has never appeared. [Z14]
```landin
public node: type = struct
    name: utf8
    kind: variant
        leaf |
        branch: (first: node_id, count: u32)
    end kind
end node

```
The whole tree is one list. Every edge is an index into it, so no
node refers to another node and the structure has exactly one
origin: whatever backs the list. It can be moved, copied, written
to flash and read back, and [0860]'s complaint about pointers
travelling through struct fields does not apply, because there are
none. This is the first time the idiom the language keeps
recommending has been written out, and it holds up.
```landin
public tree: type = struct
    nodes: vec.list(node)
end tree

public new_tree: () -> (t: tree) =
    t = (nodes: vec.new_list(T: node))
end new_tree

public add_leaf: (A: type is allocator, inout t: tree, inout a: A, name: utf8)
                 -> (id: node_id) ! out_of_memory =
    id = node_id(u32(t.nodes.len))
    try vec.push(t.nodes, a, (name: name, kind: leaf))
end add_leaf

```
Children are contiguous, so a branch is a first index and a count.
That only works if the children were added together, which is the
usual discipline for this representation and better said out loud
than discovered.
```landin
public add_branch: (A: type is allocator, inout t: tree, inout a: A,
                    name: utf8, first: node_id, count: u32)
                   -> (id: node_id) ! out_of_memory =
    id = node_id(u32(t.nodes.len))
    try vec.push(t.nodes, a,
                 (name: name, kind: branch(first: first, count: count)))
end add_branch

public get: (t: tree, id: node_id) -> (n: node) ! no_such_node =
    fail no_such_node when usize(u32(id)) >= t.nodes.len
    n = t.nodes.items[usize(u32(id))]
end get

```
Recursion over indices. No pointer is ever formed, so nothing here
can dangle and nothing needs an origin.
```landin
public count_leaves: (t: tree, id: node_id) -> (n: u32) ! no_such_node =
    this := try get(t, id)
    n = match this.kind
            leaf: 1
            branch (first, count):
                begin
                    mut total: u32 = 0
                    for k in 0..<count do
                        total += try count_leaves(t, node_id(u32(first) + k))
                    end for
                    total
                end
        end match
end count_leaves
```
A match arm whose value takes several statements has to open a
bare block to get one. That is [1080] working as designed, and it
reads heavily. Worth watching before deciding it needs anything.

## app  —  using all of it

```landin
import core/mem
import core/vec
import core/map
import core/tree
import core/sort (sort, ordered)

```
Hashing is one of the few places where wrapping is the point, and
the language makes it say so: a plain * would trap here on the
first key big enough to overflow the multiply.
```landin
hash_u32: (k: u32) -> (h: u64) = u64(k) *% 0x9E37_79B9_7F4A_7C15 end
eq_u32:   (a: u32, b: u32) -> (yes: bool) = a == b end

u32 is map.equatable (eq: eq_u32)
u32 is map.hashable  (hash: hash_u32)

less_i32: (a: i32, b: i32) -> (yes: bool) = a < b end
i32 is ordered (less: less_i32)

```
Sixty-four kilobytes of static storage, one bump allocator over
it, and nothing else in this program allocates anywhere. On the
small target that is the whole memory story, and it is legible in
four lines.
```landin
mut pool: [64 * 1024]u8 = zeroed

run: () -> none ! out_of_memory =
    mut a := mem.bump_over(pool[0..<lenof pool])

```
A list, filled and sorted with the generic sort from [1290].
```landin
    mut numbers := vec.new_list(T: i32)
    for k in 0..<20 do
        try vec.push(numbers, a, 20 - i32(k))
    end for
    sort(vec.used(numbers))

```
A map from those to their squares.
```landin
    mut squares := map.new_map(K: u32, V: u32)
    for n in numbers do
        try map.insert(squares, a, u32(n), u32(n) * u32(n))
    end for
    nine := map.get(squares, 3) else 0

```
A tree: three leaves under one branch.
```landin
    mut t := tree.new_tree()
    first := try tree.add_leaf(t, a, "a")
    _      = try tree.add_leaf(t, a, "b")
    _      = try tree.add_leaf(t, a, "c")
    root  := try tree.add_branch(t, a, "root", first, 3)
    total := tree.count_leaves(t, root) else 0

    report(nine, total)
end run

```
What generics cannot do, from [1400]: one list holding values of
different types. The list is generic in exactly one type, and that
type is the two-word pair. drawable and canvas are the tour's,
from [1340].
```landin
draw_all: (items: vec.list(any drawable), target: ptr canvas) -> none =
    for w in items do
        w.draw(target)
    end for
end draw_all

```

---

```landin
[Z] WHAT THIS ONE FOUND
The resolutions below cite the pre-release revisions this
specification passed through, 0.0.1 to 0.0.17, on the way to 0.1.0.
They are kept because when one thing was settled relative to another
still carries information.

```

---

```landin
Nineteen, which is more than the first two prototypes together, and
that is the expected shape: a driver uses the language's edges and a
container library uses its middle. Four of them mattered more than the
rest — Z1, which nothing works without; Z5, the borrow rule stopping
one step short of where containers need it; Z16, what a parameter
convention means for a reference; and Z19, the first concrete evidence
in the errdefer argument rather than another opinion about it.

Fifteen went into tour 0.0.8 as forced, Z1 among them. Z5 and Z16 went
into 0.0.9 together, having turned out to be one question. Z13 and Z18
went into 0.0.10, both settled by asking what the compiler already
knows, and Z19 into 0.0.11 as undo. All nineteen are worked in.

Z1  A conformance for a parameterised type has nowhere to put its
    quantifier. "counted(A) is allocator" and "list(T) is iterable"
    mean "for any A" and "for any T", and there is no way to say so.
    Written here with a prefix binder,

        (T: type) list(T) is iterable (Cur: usize, Item: T, ...)

    which reads acceptably and puts the binder where every other
    binder in the language is: left of what it introduces. The
    functions supplying the entries are themselves generic, and the
    conformance's instantiation supplies their type argument, leaving
    a function of exactly the concept's shape — so nothing new is
    needed beyond the binder itself.

    This is the finding of the file. Without it there is no generic
    container that can be traversed, sorted, or handed to any other
    generic code, so nothing above works at all.

Z2  A type declaration needs the same parameter kinds a function
    signature has. map wants a constrained parameter,
    map: type (K: type is hashable, V: type), and small wants a fixed
    value parameter, small: type (T: type, fixed N: u32). [1350] shows
    only a plain type parameter and [1520] shows fixed only on a
    function. Nothing here suggests a difficulty; it needs saying.

Z3  Slices and pointers have no stated way between them, and every
    allocator needs both directions plus pointer arithmetic. Written
    here as offset, base_of and slice_from in core. A core-only
    privilege is defensible under [0490], but it should be stated
    rather than assumed, because the alternative reading is that the
    language cannot express its own allocator.

Z4  sizeof T and alignof T on a type parameter are constants when the
    call is specialised and are not when it is compiled against a
    table. The evidence therefore has to carry the size and alignment
    of the type as well as the concept's functions. [1310] describes
    the table as holding the functions and is silent about layout.

Z5  RESOLVED at 0.0.9, together with Z16, which turned out to be the
    same question from the other side. A returned reference names
    what it was derived from; the convention on that parameter says
    whether the view reads or writes, and the caller knows the source
    must hold still. No clause means an independent result, which is
    what keeps two live allocations out of one allocator legal — the
    thing that killed option (a) below. Derivation stops at the three
    primitives of [0500], so the allocator does not have to claim its
    storage borrows it. Written rather than inferred, which also
    removed every carve-out at the edges. Option (c) as set out here,
    with the polarity kept: say what borrows, not what is fresh.

    The original finding, for the record.

    The accessor hole, and the one that deserved the most thought.

        xs := vec.used(numbers)
        try vec.push(numbers, a, 5)      -- reallocates
        use(xs)                          -- stale

    [0830] catches this when the view is taken directly, xs := l.items,
    because the derivation is visible in one expression. Through a
    function it is not, and reading a container through an accessor is
    the ordinary way to read one — so the most likely dangling-slice
    bug in the library sits exactly where the rule stops.

    Three ways out, none free:

    (a) Conservative: a reference-typed result borrows every
        reference-typed argument. Purely local, no annotation. It also
        marks new_slice(a, n) as borrowing the allocator, which would
        forbid a second allocation while the first slice is alive.
        That is not a corner case, that is allocation.

    (b) Leave it, and list it in [0860] with the other holes. Honest,
        cheap, and leaves the commonest failure unguarded.

    (c) Mark it, as the dual of escaping. escaping says the callee
        keeps a reference to an argument; the new word says the caller
        does. One word, local, no interprocedural analysis, symmetric
        with something already present.

    By [1710] this is a candidate, not a decision: the programmer must
    say it, the compiler cannot work it out locally, and it is the
    missing half of a mechanism that exists. What it does not do is
    let two old mechanisms leave, so it should be argued rather than
    slipped in, and (b) is a legitimate answer.

Z6  escaping on a generic value parameter says the right thing at both
    extremes with no special case: vacuous for T = u32, since [0840]
    already has it that a value holding no references is
    unconstrained, and exact for T = ptr node. A pleasant result,
    worth writing down because it looks wrong at first reading.

Z7  A pattern binding needs a stated convention. push_small wants to
    write into the payload it matched, and whether a binding aliases
    the payload or copies it is not said. For a [N]T payload the
    difference is a whole array copy, and for small_used the
    difference is between a valid slice and a dangling one. The
    mechanism to reuse is obvious — in, inout and sink are already the
    parameter conventions — which is [1710]'s first line exactly. Two
    questions come with it: whether an inout binding borrows the
    matched value for the arm, and what happens when the arm assigns
    to the variant field it is bound out of.

Z8  There is no notion of uninitialised storage, and a container
    cannot avoid having some. slice_from returns []T over memory
    holding no T. Requiring a zero image would forbid list(ptr node),
    which the tree needs, so that is not the answer. The containers
    hold the invariant themselves and it works, but the type []T
    claims more than is true between the allocation and the write.
    Either core's privilege covers this too, or there is a separate
    raw-storage type; one of the two should be said.

Z9  A concept entry must have a concrete error set, because it is
    reached through a table and [0960] forbids an inferred set there.
    So the allocator concept fixes out_of_memory for every allocator
    that will ever exist. Right for allocation, but it is a general
    constraint on concept design that nobody has written down.

Z10 Threading the allocator rather than storing it holds up, and for a
    better reason than visibility. A stored allocator makes the
    container list(T, A), so a list in an arena and a list on the heap
    become different types and no function takes both. Threading keeps
    the type parameterised by T alone. The cost is one more argument
    at every mutating call.

Z11 [1340] says a conformance is declared explicitly even when the body
    is empty, then shows button is widget supplying only focus, with
    no sign of the drawable and clickable conformances it also needs.
    The rule is right; the example undercuts it.

Z12 Passing a pointer target where an inout is wanted,
    A.alloc(c.inner.val, size, align). Ordinary and surely intended,
    never shown.

Z13 RESOLVED at 0.0.10. sink takes a place, and a field of a binding
    is a place, so every call in this file stands as written. The
    path must be rooted in a binding with no dereference and no
    computed index — the line where the analysis is still provable.
    A sunk place is dead until assigned again, which closes the
    window between the release and the repointing that a temporary
    binding would have left open, and a place sunk out of an inout
    parameter must be assigned again before returning.

    The original finding, for the record.

    sink on a struct field. drop_slice takes sink s: []T and every
    caller passes l.items rather than a binding. Killing a binding is
    well defined; killing a field is not, and every caller here
    reassigns the field immediately afterwards, which suggests the
    rule wants to be about the assignment rather than about the field.

Z14 A variant case with no payload, written bare: leaf | branch: (...).
    It is an atom and [1700] holds that atoms are one idea everywhere,
    so this ought to need no decision — but every variant in the tour
    carries a payload, so the spelling has never appeared.

Z15 Not a gap, an observation. Nothing here wanted a label, a break
    with a value or a complete clause, which is the second prototype
    in a row to say so — see Y4. The map probes were written with
    loop, break and a fail after the loop, and read better for it.

Z16 RESOLVED at 0.0.9 with Z5. The conventions read the same for
    both kinds of parameter — may I write to what you gave me — and
    on a reference that reaches the viewed storage, not only the
    binding. const in the type was weighed and declined: it answers
    only this half, leaves Z5 untouched, and would have been the
    language's first implicit conversion.

    The original finding, for the record.

    What a parameter convention means for a reference type is not
    stated, and it is the same question as whether a pointer is to
    mutable or immutable storage.

    sort at [1290] takes inout data: []T and writes through it, so the
    convention evidently governs the storage the slice views, not the
    slice value. But used takes l as in and hands back a []T that sort
    then writes through — so a read-only parameter produced a writable
    view of the same bytes, and nothing complained. The same holds for
    ptr: nothing says whether ptr T may be written through, or whether
    that depends on how the pointer arrived.

    Two coherent answers. Either the convention governs only the
    binding, and writability lives in the type — which means a second
    pointer and slice type and is a large change. Or the convention
    governs the viewed storage, in which case a slice returned from an
    in parameter must be read-only, and there has to be a way to say
    which of the two a returned reference is. The second is smaller
    and fits Z5's option (c), since both want a word about what comes
    back rather than what goes in.

Z17 [0710] says anonymous struct values take their type from context
    and then says they never flow into a same-shaped named type — and
    its own example, here: point = (x: 1.0, y: 2.0), does exactly
    that. The coherent reading is the one the number literals already
    use: a struct literal is untyped and takes a named type from
    context, whereas a value already typed as an anonymous struct,
    such as a return list, does not convert to a named one. Every
    constructor above depends on this, so the wording needs fixing.

Z18 RESOLVED at 0.0.10: nothing is written at the call site. A
    convention belongs to the declaration and appears nowhere else.
    The marker would have bought legibility rather than safety,
    since a caller that misuses what it got is told so at its next
    use, and escaping already puts an obligation on the caller from
    the signature alone. The three examples were made to agree, and
    [0780]'s was a bug rather than a third spelling.

    The original finding, for the record.

    How an inout argument is written at the call site is inconsistent
    in the tour. [0830] writes push(inout l, v); [0980] writes
    process(source: src, target: dst, owned: buf) with no marker; and
    [0780] writes push(addr head, n) where the parameter is
    inout head: ptr node, which would need the argument to be head,
    not its address. Three examples, three spellings.

    It matters more than it looks. With a marker, sort(vec.used(...))
    becomes sort(inout vec.used(...)), which is absurd for a value
    nobody can observe afterwards — so a marker pushes toward Z16's
    second answer, where writability belongs to what is returned
    rather than to the argument. Without one, an ordinary call gives
    no sign that it changes its argument, which is a strange silence
    in this language. Decide it, and fix the three examples.

Z19 RESOLVED at 0.0.11 as undo, and the argument moved twice on the
    way, so both corrections belong here.

    First, this finding overstated its own case. A flag and a
    conditional defer is linear, not quadratic — three lines per
    resource, however many there are. Only the else chain written
    above was quadratic. So it was never about line count, and the
    declined-errdefer position held up better than this said.

    What survives is the failure mode. Forgetting to set a flag frees
    storage that is still in use, and under an arena, where free does
    nothing, that mistake is silent until somebody runs the same
    container on a real allocator. The workaround is a trap that the
    usual test environment hides, which is a different and worse
    thing than being verbose.

    Second, the shape. A cancellable defer was considered and
    dropped: the cancel always sits where the block succeeds, so it
    is hand-made bookkeeping for a question the block's exit already
    answers. And defer with an argument was dropped because it reads
    as a call. What went in is a word of its own — to defer is to do
    it later, and this may never be done at all.

    The original finding, for the record.

    rehash makes three allocations that can each fail; the second
    failing has to free one, the third has to free two.
```

---
