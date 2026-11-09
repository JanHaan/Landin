# Prototype-5 firmware counterpart derivation

This is the executable derivative of `prototype-5-server.md`'s firmware
half: its `firmware/tick`, `firmware/board` and `firmware/app` sections,
complete and with no placeholder bodies, in `compiler/tests/counterpart/`.
The prototype remains a historical stress sketch. Its hosted half is
`examples/derived_server/`, whose `app/protocol` this program shares
unchanged, as the sketch has one `app/protocol` serve both; its map is
`compiler/tests/fixtures/runtime/derived-server-two-process/DERIVATION.md`.
The sketch's `core/fibre` is the library's, with D464's spellings, and its
`drivers/uart` is prototype 1's derived receive driver,
`compiler/tests/driver/drivers/uart`, over that derivation's synthetic
UART and DMA (`models.DriverPeripheral`). `D448` names a decision recorded
in `spec.md`; `refine explain D448` prints it.

`environments/cortex-m/counterpart.py` runs it, the `counterpart` lane of
the gate's `cortex-m-programs` job, on QEMU's micro:bit at every
optimization profile, and judges its trace against the single-core answer
(D448): requests are answered one at a time, in the order they
arrived, and none is begun before the one before it has been answered.

| Prototype section | Complete source and behavior |
| --- | --- |
| core/fibre | The library's `core/fibre` and `core/fibre/stacks`, as D444, D463 and D464 made them. The device's group is `turns_over` the board, its two stacks cut from `fibre_backing`, module storage the program declares, so nothing allocates. |
| firmware/tick | `firmware/tick/tick.ldn`: SysTick's handler, at vector 15, adds one to an `atomic.cell(u32)` with `atomic.sole_add`, a load and a store (D449, D511); `now_ticks` loads it; `start_counting` programs SysTick from the 16 MHz core clock, a tick a millisecond. |
| firmware/board | `firmware/board/board.ldn`: the board is one handle that provides `fibre.scheduler`, `fibre.turns` and `time.clock`. Its turns are the library's round, `stacks.round`, which it holds as `any fibre.turns`; its clock reads the tick count widened to 64 bits, and its sleep yields until a whole number of ticks and one more have passed, so it never returns early. |
| firmware/app | `firmware/app/main.ldn`: a taker fibre reads the serial line through `uart.read` and splits it into lines, queuing each, up to four, and answering `busy` itself for a fifth; an answerer fibre takes the oldest, answers it through `protocol.answer` on the board's clock, or `protocol.refuse` for a line that is no request, and only then takes the next. The reset stack makes the group and joins it for the rest of the device's life. `firmware/trace` records when each request arrived, began and ended being answered, and each refusal, with its tick. |
| app/protocol | `examples/derived_server/app/protocol/protocol.ldn`, unchanged: `WAIT <ms> <tag>` and `NOW <tag>`, and `malformed` for anything else. Over the board its `time.sleep` is a switch point (D446), so the taker takes `NOW b` while `WAIT 200 a` sleeps. |

The derivation departs from the sketch where the compiler refused its
spelling or the sketch left a choice open; D1034 to D1036 record each.

- The sketch's `firmware/board` wrote the round of turns by hand, because
  the library had none (V8). The library's round is that round (D444), so
  the board lends it, and the idle wait for an interrupt is the
  application's idler given to `round_over`. A provider supplies
  `scheduler` and `turns` in two conformances, since `turns` adds only
  `yield`.
- The sketch's taker waited on `uart.take_events()`, prototype 1's
  latch over the DMA's notifications. Those come only at the half and the
  end of the ring, so a short line raises none; prototype 1's application
  arms a timer for them. The taker reads what has arrived at every turn
  instead, and yields when nothing has.
- The sketch's `uart.tx`, a transmit side prototype 1 did not write, is
  `firmware/serial`, a writer over the synthetic UART's data register, in
  a module of its own so prototype 1's derivative is unchanged.
- The sketch's answerer dropped a line that is no request. The derivative
  answers it `malformed`, as the hosted session does, and treats a line
  longer than the queue's 64 bytes as one; a refusal for a full queue is
  `busy`, and every line, refused or queued, is numbered as it arrives.
- `begin` is a keyword, so the tick's start is `start_counting`. A
  struct literal for `admit`'s state needs a named type from its
  destination, so each state is a typed binding.
- The sketch guessed 640 bytes for each fibre's stack. The stacks are
  2,048 bytes: at `none` the answerer's painted to 1,568 and the taker's to
  1,264, so 640 would have trapped `stack_exhausted` (D471).

| Finding | Current executable accounting |
| --- | --- |
| V1 | The device's group is made with `turns_over`, because a taker that never ends would starve the answerer under a provider that runs each task to its end. |
| V4 | The switch points are the board's: `yield`, `sleep` and the group's `wait`. The queue, the arrival count and the trace switch nowhere. |
| V5, V6 | The queue and the trace are plain module state written by both fibres, one context (D446), with no atomic and no critical section. |
| V8 | The round of turns is the library's, `core/fibre/stacks`' `round`, with the device's idler, a wait for an interrupt. |
| V9 | Each fibre's stack is measured: the lane paints the backing before the group cuts it, reads each fibre's deepest write when the run ends, and fails a run that leaves less than D461's exception frame above the record. |
| V10 | SysTick's handler is the tick's one writer and adds with `atomic.sole_add`; a fibre reads the count when its turn comes, and the handler never switches (D449). |
| V11 | Each fibre runs on the process stack and SysTick's handler on the main stack, so every interrupt taken in a fibre stacks one exception frame on that fibre's stack (D447, D461). |
| V12 | The debugger's view of a switch is `runtime/stack-switch-frames`' sessions (D469), on Cortex-M0 the evidence lane's `switch` control; this derivative adds none. |
| V13 | The oracle: one answer at a time, in arrival order, `busy` only for a full queue. |
| V15 | The reset stack starts both fibres only as a group it joins. |
| V2, V3, V7, V14 | The hosted server's, not this derivative's. |

## What the lane runs

Three scenarios, each in a session of its own, at every profile:

- `two-in-flight`: `WAIT 200 a`, then `NOW b` once `a` has begun being
  answered, so the request for two operations in flight is presented as
  the hosted client presents it. The device answers `a done` and then
  `b done`, and `b` is begun only once `a` has been answered.
- `queue-full`: `WAIT 200 a`, then five `NOW` requests at once, of which
  four wait and the fifth is refused `busy`, then the four answered in
  order.
- `refusals`: a request with no tag, one longer than the queue keeps, and
  `WAIT 5 z` ended by `\r\n`; `malformed`, `malformed`, `z done`.

`judge` in the runner decides each run. It numbers the lines it fed, reads
the trace and what the device wrote, and fails the run on any of these:

- a missing answer, an answer begun while another was being answered, or
  one begun out of arrival order;
- a wait answered before its ticks;
- `busy` for a queue with room, or a queued request beyond four;
- a line the device did not take, or a byte it refused;
- a lost trace, or a request for two in flight that was not presented;
- a trap, a halt or a timeout.

It derives the expected answer to each line from the protocol's rules,
written again in Python, never from the firmware.

Four controls build the same source with one mutation each, at the first
profile, and require the run to fail for the mutation's reason: `overlap`,
a second answerer over the same queue, D448's declined alternative, which
answers `b` first; `missing`, `b`'s answer never written; `trap`, a take
reading a row past the queue, which its bounds check traps; and
`timeout`, SysTick never started, so the first sleep never ends and the
idle round waits for an interrupt that never comes.

## Premises and limits

- A tick is a millisecond of the emulator's clock. Under `machine.py`'s
  `-icount shift=0,align=off,sleep=off` that clock reaches the next tick
  across each stop the harness makes at an access to the synthetic device:
  in one measured run 205 of 247 consecutive stops were one tick apart
  and 41 two. So the trace's ticks order its events and bound each wait
  from below, which is what the oracle uses them for, and do not measure
  how long the firmware's own instructions took.
- The serial line is prototype 1's synthetic UART and DMA, which take a
  byte only while the driver's channel is enabled; the lane feeds a line
  between the driver's reads, and the oracle fails a run in which the
  model refused a byte. No baud rate, framing or FIFO is modelled.
- The program does not fit the constrained reference's 32 KiB of flash
  (D1036): at `size` it takes about 56 KB and at `none` about 66 KB, of the
  micro:bit's 256 KiB, with about 5 KiB of static RAM and the 4 KiB main
  stack within its 16 KiB. The figures move with the compiler, and each
  run's are in its `result.json`.
- Paint is a run's deepest write, not a bound on any stack (D447, D470).
