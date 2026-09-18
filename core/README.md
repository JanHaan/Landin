# Repository-owned core modules

These ordinary Landin modules use explicit roots and imports, with no user-code
module initialization. `spec.md` owns their language contracts;
[R6.70](../ROADMAP.md#r670--implement-the-freestanding-landin-core-slice)
owns freestanding implementation and acceptance.

## Constrained Cortex-M0 consumers

The consumers use the existing memory and collection implementations. No
allocator is hidden in a container or selected implicitly by the target.

| Module | Interface and boundary |
|---|---|
| `core/mem` | `allocator`, `allocate`/`free`, caller-backed `arena` and `failing`, typed `storage`, `new`/`delete` and byte buffers. Requests and capacities use target `usize`. Raw backing and lifetime belong to the caller. |
| `core/vec` | `list`, `new_list`, `reserve`, `push`/`pop`, initialized views, length/capacity and `release`. Operations receive an allocator explicitly. Growth copies privately, rolls back on failure and publishes a complete replacement last. |
| `core/pool` | A provider over caller bytes and initialized slot metadata. Exact frees reclaim aligned slots for lowest-index reuse. No backing allocation or fallback heap. |
| `core/panic` | The canonical four-atom `panic_kind` domain. An entry-module public ordinary `(kind: panic.panic_kind, site: u32) -> noreturn` handler replaces the terminal default; no reporting or allocation dependency is imported. |
| `core/cpu` | Cortex-M0 PRIMASK save/disable/restore, mask observation, WFI and compiler/device/completion barriers. A target assertion refuses import on other targets. |

The arena aligns the absolute address, not its offset. Alignment zero and one
mean byte alignment; other `usize` alignments are honored when representable.
Overflow and exhaustion report `out_of_memory` before changing the cursor. A
zero-byte request still checks alignment/address arithmetic and may consume
padding; it need not have a distinct address. Arena free does not reclaim
individual allocations. A pool zero-byte request consumes a slot and must be
freed with its original size. `new_bytes(0)` instead returns an empty descriptor
without asking the provider. These are deliberately distinct contracts.

Zero-sized vector elements retain logical capacity in `usize`; it is not
silently truncated to a physical byte count. Nonzero byte-count overflow is
checked before allocation. Failed reserve preserves the old length, capacity
and values. Raw storage publishes an initialized prefix only after complete
stores. It is not an ownership token: aliases, backing extent, provider identity,
free order and lifetime remain manual obligations under D148/D193.

`disable_interrupts()` returns the prior PRIMASK. Restore that saved value,
including on early returns; an ordinary `defer` can do this. Each nested section
retains its own value. Thread and handler mode are supported. Only PRIMASK bit
zero is implemented; the rest of the carrier is reserved. Restoring a saved
value is the supported use. Ordinary calls can clobber flags; exception return
restores interrupted flags from the hardware frame. NMI, HardFault and DMA are
not excluded by PRIMASK.

`wait_for_interrupt()` executes DSB SY then WFI. An enabled pending interrupt
can wake the core while PRIMASK delays handler entry, and wakeups can be
spurious. Recheck the condition. `compiler_barrier()` invalidates compiler
memory knowledge, `device_barrier()` adds DMB SY ordering, and
`completion_barrier()` adds DSB SY completion. None proves device completion
or supplies missing cache coherence. The selected core has no cache, FPU,
exclusive-access primitives or VTOR. Ordinary DMA buffers remain slices.

## Other modules and closure

`core/failing`, `core/region`, `core/small`, `core/map`, `core/tree`, `core/sort`
and `core/text` contain reusable target-neutral code. Existing tests and R6.50
image dispositions remain authoritative; absence of hosted imports does not
promise that every composition fits 32 KiB. `core/io`, `core/diag`, `core/heap`
and the hosted C aliases in `core/c` are outside this consumer closure. Even
unused hosted declarations in a selected module must meet target checks.

The [probe runner](../environments/cortex-m/freestanding.py) copies only its
declared import closure and records every source hash. Each link accepts the
compiler-generated object, pinned `thumb/v6-m/nofp/libgcc.a` and GNU-generated
linker stubs. The map records selected private helper members. There is no libc,
hosted startup, heap provider or scheduler. ELF/map/assembly/linker inputs and
fresh-directory comparisons are retained. The profile remains 32 KiB flash,
16 KiB RAM and a 4 KiB stack reservation. Observed watermarks describe those
runs, not a complete maximum-depth proof. D231 enables infallible `noreturn`
without changing allocator errors into traps. A direct nonreturning call does
not run a pending deferred mask restoration; a nonreturning cleanup stops
later cleanups. ROADMAP.md records panic implementation and milestone status.

R6.80's [generated device fixtures](../devices/README.md) import no core module.
Their consumers explicitly import `core/cpu` and optionally `core/panic`;
ordinary DMA slices retain the completion/boundary/lifetime obligations above.
No allocator, heap, scheduler or hosted initialization enters that closure.
