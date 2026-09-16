"""D227 bounded models. Abstract state exploration, never hardware proof.

Store buffers are FIFO, byte-addressed memory is coherent, each model step is
indivisible, and termination explores every state in the finite two-store
program. Fences drain the issuing CPU's buffer. This is a deliberately small
TSO machine, not an Arm architecture simulator or a complete language model.
The independent SC oracle enumerates program-order-preserving permutations.
Cache examples have one two-byte write-back line and explicit DMA RAM writes.
"""
from itertools import permutations, product
import json


def store_buffer(fence):
    # pc0, pc1, memory x/y, each CPU's pending store, read results
    initial = (0, 0, 0, 0, False, False, -1, -1)
    seen, pending, outcomes = set(), [initial], set()
    while pending:
        state = pending.pop()
        if state in seen:
            continue
        seen.add(state)
        pc0, pc1, x, y, b0, b1, r0, r1 = state
        if pc0 == pc1 == 2 and not b0 and not b1:
            outcomes.add((r0, r1))
        for cpu in (0, 1):
            s = list(state)
            pc, buffered = state[cpu], state[4 + cpu]
            if pc == 0:
                s[cpu], s[4 + cpu] = 1, True
                pending.append(tuple(s))
            elif pc == 1 and (not fence or not buffered):
                s[cpu], s[6 + cpu] = 2, state[3 - cpu]
                pending.append(tuple(s))
            if buffered:
                s = list(state)
                s[4 + cpu], s[2 + cpu] = False, 1
                pending.append(tuple(s))
    return outcomes, len(seen)


def sc_oracle():
    outcomes = set()
    for order in permutations(('wx', 'ry', 'wy', 'rx')):
        if order.index('wx') > order.index('ry') or order.index('wy') > order.index('rx'):
            continue
        memory, reads = {'x': 0, 'y': 0}, {}
        for op in order:
            if op[0] == 'w':
                memory[op[1]] = 1
            else:
                reads[op[1]] = memory[op[1]]
        outcomes.add((reads['y'], reads['x']))
    return outcomes


def fence_axioms():
    # Independent axiomatic reading of D227's SC fence rule, not a store
    # buffer implementation. Each thread does W(1); F(sc); R(other).
    # R reads 0 => R coherence-before the other thread's W => its fence
    # precedes the other's fence in S. Two such edges are a forbidden cycle.
    outcomes = set()
    for r0, r1 in product((0, 1), repeat=2):
        constraints = []
        if r0 == 0: constraints.append((0, 1))
        if r1 == 0: constraints.append((1, 0))
        for order in permutations((0, 1)):
            if all(order.index(a) < order.index(b) for a, b in constraints):
                outcomes.add((r0, r1))
    return outcomes


def release_sequence():
    # Enumerate modification sequences after the publishing release write.
    # Only intervening RMWs carry the release; a plain store ends it. A
    # failed CAS reads but does not enter modification order. Values are
    # chosen distinct here so each reads-from source has one identity.
    cases = []
    for middle in product(('rmw', 'store'), repeat=2):
        chain = ('release',) + middle
        for source in range(3):
            walking = 0
            while walking < source and chain[walking + 1] == 'rmw':
                walking += 1
            edge = walking == source
            # Independent set-based definition of a contiguous prefix.
            oracle = 'store' not in chain[1:source + 1]
            assert edge == oracle
            cases.append(dict(modifications=chain, acquire_source=source,
                              synchronizes=edge, relaxed_synchronizes=False))
    return cases


def publication(ordered):
    # Separate propagation of payload and notification. Release/device
    # contract is the premise that payload precedes notification visibility.
    results = set()
    for order in permutations(('payload', 'flag', 'observe', 'read')):
        if order.index('observe') > order.index('read'):
            continue
        if ordered and order.index('payload') > order.index('flag'):
            continue
        data = flag = 0
        observed = False
        for event in order:
            if event == 'payload': data = 42
            elif event == 'flag': flag = 1
            elif event == 'observe': observed = flag == 1
            elif observed: results.add(data)
    return results


def tearing():
    # A 16-bit device write split into two byte events versus a scalar
    # single-copy atomic event. CPU and DMA bus guarantees are distinct.
    values = set()
    for order in permutations(('low', 'high', 'read')):
        value = 0
        for event in order:
            if event == 'low': value |= 0xff
            elif event == 'high': value |= 0xff00
            else: values.add(value)
    return values


def cache_cases():
    # Initial CPU line is dirty; DMA sees RAM, not the private cache.
    ram, cache = [0, 0], [1, 7]
    assert ram[0] == 0                    # TX without clean is stale
    ram[:] = cache                       # clean to DMA visibility point
    assert ram == [1, 7]
    ram[0] = 42                          # receive after handoff
    assert cache[0] == 1                  # fence alone cannot invalidate
    stale = cache[:]
    cache = ram[:]                       # invalidate + subsequent refill
    assert cache == [42, 7]
    ram[:] = stale                       # forbidden stale post-RX clean
    assert ram[0] == 1                    # overwrites completed DMA data
    ram, dirty = [42, 7], [1, 9]
    dirty = ram[:]                       # invalidating a shared dirty line
    assert dirty[1] == 7                 # loses unrelated CPU write of 9
    return dict(stale_read=1, visible_after_invalidate=42,
                stale_clean_overwrite=1, shared_line_lost_write=7)


def run():
    weak, weak_states = store_buffer(False)
    strong, strong_states = store_buffer(True)
    assert weak == {(0, 0), (0, 1), (1, 0), (1, 1)}
    assert strong == sc_oracle() == fence_axioms() == {(0, 1), (1, 0), (1, 1)}
    assert publication(False) == {0, 42}  # volatile / no device premise
    assert publication(True) == {42}
    assert tearing() == {0, 255, 65280, 65535}
    # IRQ delivery masking leaves DMA able to modify memory and pend IRQ.
    irq_masked, dma_ram, pending_irq, handler_seen = True, 0, False, 0
    dma_ram, pending_irq = 42, True
    if pending_irq and not irq_masked: handler_seen += 1
    assert dma_ram == 42 and handler_seen == 0
    irq_masked = False
    if pending_irq and not irq_masked: handler_seen += 1
    assert handler_seen == 1
    return dict(kind='abstract-model', status='passed',
                weak_states=weak_states, fenced_states=strong_states,
                weak_outcomes=sorted(weak), fenced_outcomes=sorted(strong),
                publication_unordered=[0, 42], publication_ordered=[42],
                tearing=sorted(tearing()), caches=cache_cases(),
                sc_fence_axioms=sorted(fence_axioms()),
                release_sequences=release_sequence(),
                dma_while_irq_masked=dma_ram)


if __name__ == '__main__':
    print(json.dumps(run(), sort_keys=True, indent=2))
