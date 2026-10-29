# Landin prototype 5 — a server with two requests in flight

> **Not learning material.** This is a design stress test: a small network
> server that keeps two requests in flight, and a Cortex-M0 counterpart
> that has to answer the same requests on one core, written before the
> compiler had fibres to find where the specification was silent,
> ambiguous or wrong. It is not a program you can compile: it leaves bodies
> out with `...`, and its fibre interface is the sketch `core/fibre` was
> written from, in spellings that have since changed. Its findings at the
> end are the point. The server that actually runs is
> [`examples/derived_server/`](examples/derived_server/), with its fixtures
> `runtime/derived-server-two-process` and `runtime/derived-server-fake-turns`;
> the firmware counterpart is not derived yet. To learn Landin, read [the
> tour](tour.md), whose [1675] teaches fibres.
>
> The sketch itself begins at its first module heading, `core/fibre`. The
> notes between this banner and that heading say what it presses on and
> reconcile the sketch with the library, and a reader can skip them.

Current with specification 0.2.8. Its own findings V1-V15 are all
resolved below: V15 while it was written, the rest by D444-D449. The fibres
exist now, in `core/fibre` and its submodule `core/fibre/stacks`, and the
runtime fixtures those decisions name pin them. The hosted half is derived
as `examples/derived_server`, whose
`compiler/tests/fixtures/runtime/derived-server-two-process/DERIVATION.md`
maps `app/protocol`, `app/session`, `app/server` and `app` to their
executable sources and says where the derivative's spellings differ from
the sketch's (D489). It runs over `hosted/blocking` in a process of its own
(D490); the event provider's half of that evidence, and D448's single-core
answer, wait for the providers and the firmware counterpart.

A server that answers two kinds of request, one line each:

```text
WAIT 200 a      answered "a done" after 200 milliseconds
NOW b           answered "b done" at once
```

A client sends `WAIT 200 a` on one connection and then `NOW b` on another.
With two operations in flight `b` is answered first, after next to no
time; with one at a time `b` waits behind `a`. The device below takes the
same two lines on one serial line and answers them in order, which is the
honest answer on one core. The order of the two answers is what tells the
cases apart, and that is what a trace of a derived program can check.

Deliberately small, because the point is not the server. What it presses
on, none of which the first four prototypes touched:

- a fibre — a stack of its own that a call can switch to and back from,
  backed by storage the caller supplies, since the execution model refuses
  stackless coroutines and keeps stackful fibres reachable
- a group — fibres a routine starts and waits for before it goes on, so
  that what they borrow from its frame outlives them, as an argument
  outlives the call it was passed to
- concurrency as a capability — whether the two requests overlap is the
  provider's answer, not the function's, and the same source has to be
  right for a provider that blocks, one that switches and one that has a
  single core
- where a switch can happen, and what that does to state the first four
  treated as the program's alone: the last errno, a module counter, a
  ring between two fibres
- an interrupt that has to wake a fibre it cannot switch to, on a core
  without read-modify-write atomics
- stopping: a server blocked in two receives has to be told to stop

Prototype 4 already did hosted I/O and `any` dispatch through an argv-built
chain; this one takes its capabilities as given and builds on them. The
server's network calls are `core/net`'s `network` concept as it ships, and
the device's serial port is prototype 1's receive driver, with a transmit
side that file did not write, `uart.tx`, an `io.writer` as [1660] says a
UART is.

Where a spelling had to be invented, the line is marked [Vn] and the
question is written out at the end. Nothing invented here is decided by
being written down: `core/fibre` is the design record the stack-switch
work starts from, and every spelling in it may change there.

---

The execution model in ROADMAP.md binds this sketch. Concurrency is an Io
handed down like an allocator, minted at the entry point [1660], with no
keyword, second calling convention or colored function type [1680].
Stackless coroutines are refused rather than parked, as the tour's WHAT WAS
TRIED AND DROPPED records. Fibres are cooperative here: a fibre gives the
core away only by calling the provider that runs it, either to yield or in
a call that waits, and nothing preempts it. A single-core device may still
have fibres, for structure; whether two requests are ever in flight on it
is a separate question, and V13 asks it.

Nothing here schedules in the library beyond what the sketch needs: a
provider that runs each fibre to its end, and a round of fixed turns. An
operating system's or an RTOS's scheduler is another provider of the same
concepts, never a kernel inside `core`.

The first draft of this file started fibres the way C starts threads, and
read like it. What it was, and why it went, is V15.

---

D464 changed five of the sketch's spellings when the switch was written,
each because the sketch's would not compile or would not hold. `task`'s
entry is `run: (self: ptr mut task_type) -> none`, since an `inout self`
has no erased table and a provider is handed `any task`. The switch's, the
providers' and the group's failure is `mem.out_of_memory`, not
`stack_too_small | stack_misaligned`: a stack is never misaligned, and
lent backing too small for its use is out of memory, as an arena's is.
`prepare` takes a fourth record, `after`, the one a fibre resumes when its
task has ended, because "whoever started it" is not the round's next turn.
A round's wait when nobody can run is the concept `stacks.idler`, given to
`round_over`. And a group made over `turns` keeps its provider as
`any turns`, beside an unused `any scheduler`, because the one does not
convert to the other.

D463 put the switch, `prepare` and `switch`, in the submodule
`core/fibre/stacks` with the library's round of fixed turns, `stacks.round`,
so a program over `whole` or the blocking host carries no switch. D471 to
D473 replaced the check `space.limit` was kept for: the record keeps no
limit, every routine of a program that prepares a stack checks its own
frame against the current stack's limit in its prologue, a switch carries
each stack's limit in the frames it saves, and `prepare` keeps no room
above it. D447 and D461 replaced V11's sentence that every fibre's stack
carries the deepest interrupt nesting: on Cortex-M0 a fibre runs on the
process stack, and its backing holds the one exception frame the core
pushes. The sketch below keeps its own spellings, and its findings their
wording. Deriving the firmware counterpart belongs to the roadmap's item
that runs it.

## core/fibre  —  the capability this sketch had to invent

Three layers, of which a program uses the last. The first is the switch,
which a provider builds a scheduler from; the second is what a provider
is; the third is the group, which is all an application calls.

```landin
import core/failure
import core/time

public stack_too_small:  atom
public stack_misaligned: atom

```
The caller's record of one fibre: where its stack pointer was saved, the
lowest address its stack may reach, and whether it has finished. A group
keeps these at the base of the stacks it cuts, so an application never
declares one. [V9]
```landin
public space: type = struct
    saved:  usize
    limit:  usize
    status: u8
end space

```
What a provider starts: one entry, no error set, since a fibre's first
frame has no caller to fail to. An application does not write one; a
group makes it from a routine and a state. [V2]
```landin
public task: type = concept (task_type: type)
    run: (inout self: task_type) -> none
end task

```
The switch. `prepare` lays out a first frame on `stack` that calls
`work.run`, marks the record finished and switches back to whoever started
it. `switch` saves the callee-saved registers and the frame pointer on the
leaving stack, stores its stack pointer in `leaving.val`, and resumes
`entering.val`. Pointers rather than two `inout` records, because both
commonly sit in one table. [V12]
```landin
public prepare: (escaping record: ptr mut space, escaping stack: []mut u8,
                 escaping work: any task)
                -> none ! stack_too_small | stack_misaligned = ... end

public switch: (leaving: ptr mut space, entering: ptr mut space) -> none = ... end

```
What runs fibres. Concepts and not types, the lesson prototype 4 learnt
about Io: the program never learns which one it got.

A `scheduler` may run a task to its end inside `start`, before returning;
a program written against it must be right when every task does. `wait`
returns once one of its fibres has finished, or at once when none is
running, which is how a group waits for a free stack. `turns` is a
`scheduler` that can also `yield`, and that entry is its promise: a task
that yields lets every other unfinished task of the provider run before it
resumes. A provider that runs every task to its end has nothing to yield
to, and so does not provide `turns`. [V1]

`yield` gives the core to another fibre of this provider that can run,
and returns at once when there is none. A provider that waits for events
waits here when every fibre is waiting. [V4]
```landin
public scheduler: type = concept (provider: type)
    start:    (self: provider, escaping record: ptr mut space,
               escaping stack: []mut u8, escaping work: any task)
              -> none ! stack_too_small | stack_misaligned
    finished: (self: provider, record: space) -> (yes: bool)
    wait:     (self: provider) -> none
end scheduler

public turns: type = concept (provider: type) is scheduler
    yield: (self: provider) -> none
end turns

```
Called on a provider the program holds as itself rather than erased, the
entries go through the module, as `time.sleep` does for a clock.
```landin
public yield: (provider: type is turns, host: provider) -> none = ... end

```
A provider that has no second stack to give: it runs every task to its
end, on the caller's stack, before `start` returns. Every hosted blocking
provider is one of these, `system.host` among them, and so is a device
that wants none.
```landin
public whole: type = struct
    reserved: u32
end whole

whole is scheduler (start: whole_start, finished: whole_finished,
                    wait: whole_wait)

whole_start: (self: whole, escaping record: ptr mut space,
              escaping stack: []mut u8, escaping work: any task)
             -> none ! stack_too_small | stack_misaligned =
    _ = self
    _ = stack
    work.run()
    record.val.status = 0
end whole_start

whole_finished: (self: whole, record: space) -> (yes: bool) =
    _ = self
    yes = record.status == 0
end whole_finished

whole_wait: (self: whole) -> none =
    _ = self   -- nothing is ever running
end whole_wait

```
The group. It cuts `backing` into `count` equal stacks, each with its
record at the base, and borrows the backing and the provider for as long
as it is used [0790]. Made over a `scheduler`, a group may run each task to
its end as it is admitted; made over `turns`, its tasks take turns, and a
provider that cannot promise that is refused where the group is made,
not when a task waits for ever. [V1]
```landin
public group: type = struct ... end group

public group_over: (runs: any scheduler, backing: []mut u8, count: usize)
                   -> (g: group from runs, backing)
                   ! stack_too_small | stack_misaligned = ... end

public turns_over: (runs: any turns, backing: []mut u8, count: usize)
                   -> (g: group from runs, backing)
                   ! stack_too_small | stack_misaligned = ... end

```
`admit` waits, through the provider, until one of the group's stacks is free; copies
`state` onto the top of that stack, as a call passes an argument; and
starts a fibre whose first frame calls `work` with the copy. Because each
task's state lives on its own stack, one group holds tasks of different
state types, and the group has no slots to size or zero.

`work` is an ordinary routine. Its error set is the library's, because a
group has to hold any task's failure until `join` hands it on, and an
error set cannot be a generic parameter. [V2]

`state` is kept past the call, in the group, and so is `escaping` [0780],
which refuses everything a frame lends — including what the caller's own
caller lent it, which outlives the group by construction. The sketch
writes the rule it needs as `escaping into g`. [V3]
```landin
public admit: (state_type: type, inout g: group,
               work: (inout state: state_type) -> none ! failure.reason,
               escaping into g state: state_type)
              -> none ! stack_too_small = ... end

```
Wait until every task admitted to `g` has finished. The first failure any
of them had is `join`'s; the rest ran to their own ends regardless, since
nothing cancels a fibre. A group must be joined before its backing goes,
and nothing but the program's `defer` makes sure it is. [V3] [V7]
```landin
public join: (inout g: group) -> none ! failure.reason = ... end

```

## app/protocol  —  one request, answered, on any provider

Shared unchanged by the server and the device. It knows a line, a clock and
a writer, and nothing about sockets, serial lines or fibres.

```landin
import core/io
import core/text
import core/time

public malformed: atom

```
A request borrows its tag from the line it was read from [0790].
```landin
public request: type = struct
    wait: time.duration
    tag:  []u8
end request

public parse: (line: []u8) -> (asked: request from line) ! malformed = ... end

```
The only place a request can give the core away is `time.sleep`, and only
if the clock's provider is the one that runs fibres. A clock that blocks
the thread holds every other request behind this one, and the source does
not say which it got. [V4]
```landin
public answer: (clock_type: type is time.clock, clock: clock_type,
                provider: type is io.writer,
                inout out: io.buffered_writer(provider),
                asked: request) -> none ! io.io_failed =
    if u64(asked.wait) > 0 then
        time.sleep(clock, asked.wait)
    end if
    try io.put(out, asked.tag)
    try io.put(out, " done\n")
    try io.flush(out)
end answer

```

## app/session  —  one connection, served by an ordinary routine

```landin
import core/failure
import core/io
import core/net
import core/time
import app/protocol

```
What serving a connection needs. A fibre captures nothing, as nothing does
[1010], so this is the state a group copies onto the fibre's stack. Both
capabilities are erased from one provider handle, which [1660] allows, so
the same session runs over the blocking host and over a second Io.
```landin
public session: type = struct
    connection: io.file
    network:    any net.network
    clock:      any time.clock
end session

```
Requests served, by both connections. No atomic and no lock: two fibres of
one provider never run at once, and nothing in `served_one` can switch.
That is true of these providers and false of a thread. [V5] [V6]
```landin
mut served: u32 = 0

served_one: () -> none =
    served +%= 1
end served_one

```
Serve one connection to its end. Nothing in it knows it runs on a fibre.

The connection is copied out before the close sinks it, because sinking
`self.connection` out of an `inout` would need a replacement before
returning [0910], and no `io.file` means closed — prototype 4's W3 again.
The copy is the double close that `sink` does not prevent, said once more.

Both buffers live on the fibre's stack, which is why its size is not a
number to guess. Reading a line waits; under a provider that runs fibres,
the wait is where the other connection gets the core. [V4] [V9]
```landin
public serve: (inout self: session) -> none ! failure.reason =
    mut connection := self.connection
    defer net.close_socket(self.network, connection) else none
    mut incoming: [256]u8 = zeroed
    mut lines := io.lines_over(self.network, connection, incoming)
    mut outgoing: [256]u8 = zeroed
    mut out := io.buffered_over(self.network, connection, outgoing)
    loop do
        item: io.line = try io.read_line(lines)
        break when item.finished
        asked := protocol.parse(item.bytes) else (problem)
            _ = problem
            try io.put(out, "malformed\n")
            try io.flush(out)
            continue
        end
        try protocol.answer(self.clock, out, asked)
        served_one()
    end loop
end serve

```

## app/server  —  two in flight, or one, as the provider says

```landin
import core/failure
import core/fibre
import core/io
import core/net
import core/time
import app/session

```
Accept a connection, admit it, repeat. The group and its stacks are this
frame's, and the `defer` joins it before the frame goes, as a region's
release would be deferred [0820].

Over the blocking host `admit` serves each connection to its end before it
returns, so the next `accept` waits for it, and `NOW b` waits behind
`WAIT 200 a` in the listener's queue. Over a provider that switches,
`admit` returns at the session's first wait, the loop accepts the second
connection while the first sleeps, and a third waits inside `admit` for a
free stack. The source is the same. [V1]

A connection's failure is that connection's: the group keeps the first
one for `join`, and the loop does not stop for it.
```landin
serve_forever: (runs: any fibre.scheduler, network: any net.network,
                clock: any time.clock, listener: io.file)
               -> none ! failure.reason =
    mut stacks: [2 * 16 * 1024]u8 = zeroed
    mut sessions := try fibre.group_over(runs, stacks, 2)
    defer fibre.join(sessions) else none
    loop do
        connection: io.file = try net.accept(network, listener)
        try fibre.admit(sessions, session.serve,
                        (connection: connection, network: network,
                         clock: clock))
    end loop
end serve_forever

```
The request this prototype is about, made by a client in the same
program, which is how a test of the server would make it. The client
needs the stronger concept: under a provider that runs each task to its
end, `NOW b` would only be sent once `a` had been answered, and the test
would measure nothing. So it asks for `turns`, and the blocking host is
refused here, where the group is made. [V1]

Each request records the order its answer came in through `heard`, a
pointer into the caller's storage. That is the reference `escaping into`
exists for: the caller's storage outlives this frame, and the group dies
with it. [V3]
```landin
public answers: type = struct
    order: [2]u8
    count: usize
end answers

asking: type = struct
    network: any net.network
    to:      net.address
    line:    []u8
    tag:     u8
    heard:   ptr mut answers
end asking

ask: (inout self: asking) -> none ! failure.reason = ... end

public ask_both: (runs: any fibre.turns, network: any net.network,
                  to: net.address, inout heard: answers)
                 -> none ! failure.reason =
    mut stacks: [2 * 8 * 1024]u8 = zeroed
    mut asks := try fibre.turns_over(runs, stacks, 2)
    defer fibre.join(asks) else none
    try fibre.admit(asks, ask, (network: network, to: to,
                                line: "WAIT 200 a\n", tag: u8('a'),
                                heard: addr heard))
    try fibre.admit(asks, ask, (network: network, to: to,
                                line: "NOW b\n", tag: u8('b'),
                                heard: addr heard))
    try fibre.join(asks)
end ask_both

```
Stopping. A signal is an event to a provider that waits for events, and a
fibre waiting on it would shut the listener and both connections, so that
each session blocked in a receive fails and ends through its ordinary
`defer`, and the group's join returns. Nothing cancels a fibre: what
stops it is its I/O failing. Whether it does fail, rather than wait for
ever on a descriptor that was taken away from under it, is the provider's
to promise. [V7]

## app  —  the hosted program

```landin
import core/fibre
import core/net
import core/time
import hosted/system
import app/server

```
The roots are made here and lent down, as [1660] makes them. Nothing is
copied into an allocation to make it outlive a fibre: the fibres that use
`host` are joined before `serve_forever` returns, and so before `main`'s
frame goes. The erased `runs` is the host itself, a provider of
`fibre.scheduler` that runs each task to its end. A second Io, made here
instead of `system.new()`, changes this line and no other. [V1] [V3]
```landin
public main: () -> (code: i32) =
    code = 1
    host := system.new()
    runs: any fibre.scheduler = any(addr host)
    network: any net.network = any(addr host)
    clock: any time.clock = any(addr host)

    address := net.loopback(net.ipv4, 7070)
    listener := net.listen(network, address) else (problem)
        _ = problem
        return
    end
    defer net.close_socket(network, listener) else none

    server.serve_forever(runs, network, clock, listener) else (problem)
        _ = problem
        return
    end
    code = 0
end main

```
`hosted/system`'s last-error cell is the process's [1975]. Two fibres share
it through one handle. A failure in one, then a switch, then a failure in
the other, and the first reads the second's errno. Prototype 4 never had
to ask, because nothing ran between a failing call and the read that
followed it. [V4]

## firmware/tick  —  time from an interrupt

```landin
import core/time
import platform/cortex_m

```
One writer, the handler; any number of readers. The first draft counted
with `ticks +%= 1` in the handler and read the count with an atomic load,
which D227 calls a race: an ordinary read-modify-write is not an access to
the atomic object the readers load. A single writer needs no
read-modify-write at all, so the handler loads and stores, both of which
Cortex-M0 has. [V10]
```landin
mut ticks: u32 = 0

link(vector: 15)
extern(interrupt) system_tick: () -> none =
    now := compiler.atomic_load(addr ticks, compiler.relaxed)
    compiler.atomic_store(addr ticks, now +% 1, compiler.release)
end system_tick

public now_ticks: () -> (count: u32) =
    count = compiler.atomic_load(addr ticks, compiler.acquire)
end now_ticks

```
The handler cannot switch to the fibre that waits for the tick: it runs on
whatever stack it interrupted, and switching from an interrupt would
return into a different fibre's frame. So it only counts, and whoever
waits looks at the count when its turn comes. Every interrupt frame lands
on the stack of the fibre that was running, so every fibre's stack carries
the deepest interrupt nesting as well as its own. [V11]

## firmware/board  —  a round of fixed turns, written in the application

```landin
import core/fibre
import core/time
import platform/cortex_m
import firmware/tick

```
No priorities, no timers, no preemption. Entry 0 is the stack the reset
handler started on; the others are the fibres a group started, each
registered by `start` with the record the group keeps for it. This is the
whole scheduler, and it is written here because the library does not have
one. Whether it should is V8.
```landin
public table: type = struct ... end table

```
The device's one provider: a scheduler that takes turns, and a clock whose
sleep takes turns until enough ticks have passed. Both are one handle, so
a request's `time.sleep` is a switch point on this device and on no
hosted blocking provider.
```landin
public board: type = struct
    turns: ptr mut table
end board

board is fibre.turns (start: board_start, finished: board_finished,
                      wait: board_wait, yield: board_yield)
board is time.clock (now: board_now, sleep: board_sleep)

board_now: (self: board) -> (reading: time.instant) = ... end
board_finished: (self: board, record: fibre.space) -> (yes: bool) = ... end
board_wait: (self: board) -> none = ... end   -- yields until one has finished

```
`start` prepares, registers the record, and returns: the fibre runs at the
next turn.

`yield` moves to the next unfinished entry after the current one. After a
whole round in which nobody did anything but yield, it waits for an
interrupt, since nothing can change before one arrives. "Nobody did
anything" is what the yielders say by yielding; the provider cannot tell a
fibre that yields with work to do from one that polls. [V4]
```landin
board_start: (self: board, escaping record: ptr mut fibre.space,
              escaping stack: []mut u8, escaping work: any fibre.task)
             -> none ! fibre.stack_too_small | fibre.stack_misaligned =
    try fibre.prepare(record, stack, work)
    ...   -- the record joins the round
end board_start

board_yield: (self: board) -> none =
    t := self.turns
    was := ...    -- the current entry's record
    next := ...   -- the next entry, round the table, that has not finished
    if next == was then
        cortex_m.wait_for_interrupt()
        return
    end if
    ...           -- the next entry becomes the current one
    fibre.switch(was, next)
end board_yield

board_sleep: (self: board, span: time.duration) -> none =
    begin_at := tick.now_ticks()
    wanted := ...   -- span in ticks, rounded up
    loop do
        break when tick.now_ticks() -% begin_at >= wanted
        board_yield(self)
    end loop
end board_sleep

```

## firmware/app  —  one core, one answer at a time

```landin
import core/failure
import core/fibre
import core/io
import platform/cortex_m
import drivers/uart
import firmware/board
import app/protocol

```
Static storage, as prototype 1's receive buffer was. Two fibres: one that
takes lines off the serial line as they arrive, and one that answers them.
The first exists so that `NOW b` is taken while `WAIT 200 a` sleeps,
rather than overrunning the receive buffer; the second answers one
request at a time, so `b` is answered after `a`. Receiving is not an
operation in flight; answering is. [V13]

A group cuts its backing into equal stacks, so the taker gets as much as
the answerer though it needs less. [V9] [V11]
```landin
mut table:      board.table = zeroed
mut stacks:     [2 * 640]u8 = zeroed
mut rx_storage: [256]u8 = zeroed

```
Lines waiting to be answered, written by one fibre and read by the other.
No atomics and no critical section: both fibres are one CPU context, and
neither can switch inside `push` or `take`. The compiler must still not
keep `head` in a register across a yield, which nothing yet says. [V5]
```landin
waiting: type = struct
    lines: [4][64]u8
    sizes: [4]u8
    head:  u8
    count: u8
end waiting

mut queue: waiting = zeroed

```
The taker answers `busy` itself when four requests already wait: on one
core, a fifth is refused rather than kept, and the refusal is an answer.
Neither routine ends, and neither fails: there is nobody on the device to
tell.
```landin
taker: type = struct
    receive: uart.rx
    device:  board.board
end taker

take_lines: (inout self: taker) -> none ! failure.reason =
    mut scratch: [64]u8 = zeroed
    loop do
        if uart.take_events() == 0 then
            fibre.yield(self.device)
            continue
        end if
        n := uart.read(self.receive, scratch[0..<lenof scratch])
        ...   -- split into lines; push each, or answer `busy`
    end loop
end take_lines

answerer: type = struct
    send:   uart.tx
    device: board.board
end answerer

answer_lines: (inout self: answerer) -> none ! failure.reason =
    mut room: [64]u8 = zeroed
    mut out := io.buffered_over(self.send, uart.line, room)  -- its one file
    loop do
        if queue.count == 0 then
            fibre.yield(self.device)
            continue
        end if
        line := ...   -- the oldest waiting line, copied out of the queue
        asked := protocol.parse(line) else (problem)
            _ = problem
            continue
        end
        protocol.answer(self.device, out, asked) else (problem)
            _ = problem
        end
    end loop
end answer_lines

```
The reset stack makes the group and joins it, and joining is what it does
for the rest of the device's life: it is entry 0 of the round, and `join`
yields until two routines that never end have ended. The group is `turns`,
because a taker that never returns would starve the answerer under a
provider that runs each task to its end. The `else` arms halt, because a
device with no one to tell has nothing better to do, as prototype 1's did.
```landin
start: () -> noreturn =
    console := uart.open(..., rx_storage[0..<lenof rx_storage]) else (problem)
        _ = problem
        halt()
    end
    device: board.board = (turns: addr table)
    runs: any fibre.turns = any(addr device)
    mut both := fibre.turns_over(runs, stacks, 2) else (problem)
        _ = problem
        halt()
    end
    fibre.admit(both, take_lines, (receive: console, device: device)) else (problem)
        _ = problem
        halt()
    end
    fibre.admit(both, answer_lines,
                (send: uart.transmitter(...), device: device)) else (problem)
        _ = problem
        halt()
    end
    fibre.join(both) else (problem)
        _ = problem
    end
    halt()
end start

```
The first draft handed `start`'s own frame to an escaping `start` of the
board, which was refused, and wrongly, since a `noreturn` frame outlives
everything it starts. The group took the question away: the states are
copied onto the fibres' stacks, and nothing of `start`'s frame is kept by
anyone. [V15]

---

## WHAT THIS ONE FOUND

Fifteen, and more than prototype 4 found: this one stretches the language
rather than using it. V15 was resolved while the file was written. The
other fourteen were open when it was finished, each with a proposed answer,
and were decided together as D444-D449 before any fibre existed; one of
them, V1, was decided differently from its proposal. The decisions are
pinned by the fixtures that will implement them.

---

V1  RESOLVED by D444: two concepts, told apart by an entry rather than a promise.
`scheduler` starts a task, says whether it has finished and waits for one to
finish, and may run each task to its end. `turns` is a `scheduler` that can
also `yield`, and the entry's contract is the promise: a task that yields
lets every other unfinished task run before it resumes. A provider that
runs every task to its end has nothing to yield to, so it never provides
`turns`, and no concept became a promise without an entry, which the
proposal below wanted. A program that needs turns asks for them with
`turns_over`, and is refused there.

The original finding, for the record.

What a scheduler may do with a task, and what a program may
assume of it.

The server is right under a provider that runs each task to its end and
under one that switches at waits. The device and the test client are not:
the device's taker never ends, so the answerer would never start, and the
client would send `NOW b` only after `a` was answered. The programs name
the same capability and need different things of it. A concept fixes what
every implementation may be asked for [1260], and one concept fixes too
little for the device and too much for the server.

Proposed: two concepts, as prototype 4's W4 said is the answer when one
does not fit, and two ways to make a group. `fibre.scheduler` may run a
task to its end as it is admitted, and a program written against it must
be right when every task does. `fibre.turns` promises that a task which
yields lets every other unfinished task of the provider run before it
resumes, and `turns_over` asks for it, so a program that needs overlap is
refused where it asks for a group, not hung when it runs. The blocking host
provides `scheduler` alone; the device's board and the event-driven Io
provide both. Nothing about progress beyond that is promised: no fairness,
no deadline.

`turns` adds a promise and no entry. No concept has done that: a concept
has been its entries, and conformance has been supplying them. Whether a
concept may be a promise, and whether conformance to one is then the
provider's word alone, is the part of this the specification has to
answer, and it reaches beyond fibres.

V2  RESOLVED by D444: as proposed. A task's error set is `failure.reason`, the group
keeps the first failure and `join` fails with it, and a task with atoms of
its own maps them before returning. Error sets as generic parameters are
recorded in ROADMAP.md's register with what would bring them in.

The original finding, for the record.

Where a task's failure goes.

A fibre's first frame has no caller to fail to: it was entered by a switch.
The group gives it one. The task is an ordinary routine with an error set,
the group keeps the first failure, and `join` fails with it, so a failure
reaches whoever waits for the work, as a returned failure reaches the
caller. The provider's own `task` keeps its empty set, because that is
what the first frame calls, and a failed check inside a fibre is the
program's [1670] handler, as anywhere else.

What is left is the error set. A group holds any task's failure, so every
task's set has to fit one the group can name, and an error set cannot be a
generic parameter. The sketch uses `failure.reason`, every atom `core`
fails with, which covers the server's network failures and refuses a task
that fails with an atom of the program's own.

Proposed: the group's set is `failure.reason`, and a task with its own
atoms maps them before returning, which is what `core/failure` already asks
of a set that holds both. Whether an error set should become a generic
parameter, so that a group of the program's own tasks carries their own
atoms, is a language question this file found and does not answer: it
would reach every generic that passes a failure through.

V3  RESOLVED by D444 and D445: as proposed for the state, and by the program's
`defer` for the join. A parameter marked `escaping into g` may be kept in
`g`'s storage when its argument outlives `g`'s origin, decided locally, so
`main` lends `host` to the sessions and the client its `heard`. A group is
joined by `defer`, as a region is released; a check that a frame-backed
group is joined on every path is recorded in ROADMAP.md's register.
`fibre.within` was declined: it makes the group and the states both
parameters of the body, so nothing local can order them.

The original finding, for the record.

What a group may borrow, and who makes sure it is joined.

The group's backing is the caller's frame, and that is legal today: the
group comes `from` the backing [0790], as an arena comes from its space.
The state is not. `admit` keeps it past the call, in the group, so it is
`escaping` [0780], and `escaping` refuses every reference with frame
origin — including the ones the caller's caller lent it, like the
session's capabilities built from `main`'s `host` and the client's `heard`.
Those outlive the group by construction: whatever a routine is lent
outlives that routine's frame, and the group dies with the frame.

Proposed: `escaping into g`, a parameter that may be kept in another
parameter's storage, checked as the same-origin update [0780] already is:
the kept reference must outlive `g`'s origin. A parameter of the routine
making the group always does; a local of the same frame does if it is
declared before the group. That is local reasoning of the kind the origin
rules already do, and it lets `main` lend `host` to the sessions without
copying it anywhere.

The rest is not a rule the checker can make. The group must be joined
before its backing goes, and only the program's `defer` makes sure of it.
Forget the `defer` and a fibre runs on a dead frame. Landin has no
destructor to do it and has refused one; affine values, parked, would make
the handle a value that must be consumed. Two ways remain: a check that a
group whose backing has frame origin is joined on every path out, as
[0910] checks that a sunk place is replaced; or no handle at all, a call
`fibre.within(runs, backing, count, body, state)` that makes the group,
calls `body` with it and joins before returning, at the price of one more
routine and state at every use. The first keeps the code as written here;
the second cannot be got wrong.

V4  RESOLVED by D446: as proposed.

The original finding, for the record.

Where a switch can happen.

The specification says nothing about it, because nothing switched. The
first draft assumed a fibre could lose the core anywhere and so wanted a
lock round `served_one`, round the device's queue and round
`last_errno`. Cooperative fibres make it narrower: a fibre loses the core
only inside a call to the provider that runs it. But a provider is a
handle that supplies many concepts, and the call that switches need not
be `yield`: in this file it is `net.accept`, `io.read_line`, `time.sleep`
and, on the device, `board.sleep`. Whether `last_errno` is safe to read
after a failing call depends on whether anything between them was one.
And `yield` with nobody else to run returns at once, so a fibre that polls
by yielding spins; the board waits for an interrupt after a round in which
everybody yielded, and cannot tell a fibre that polls from one that has
work.

Proposed: a switch happens only inside a call to an entry of the provider
that runs the calling fibre, and a provider says which of its entries may
switch, as `hosted/system` says which retry. `last_errno` and every
query that does not wait are never switch points. The errno cell is then
safe in a fibre that reads it before its next call to that provider, which
is what "read it immediately" already asks; a provider that can switch
inside `defer`'s close says so. For waiting: `yield` waits for an event
when every unfinished fibre has yielded since the last one, and a fibre
that wants to wait on something only it can see uses a wait entry of the
provider rather than polling.

V5  RESOLVED by D446: as proposed.

The original finding, for the record.

Is a fibre a CPU execution context?

D227 says a context is a thread or an interrupt handler, and its races are
between contexts. A fibre is neither. If each fibre is a context, the
device's queue and the server's counter race, which they do not: one runs
at a time. If fibres of one provider are one context, the switch has to be
something the compiler cannot see through, or an optimizer that inlines
the switch could keep `queue.head` in a register across it.

Proposed: every fibre of one provider is part of the one CPU context
running that provider, the switch is sequenced-before in that context, and
a switch is a full compiler memory boundary, as D227's explicit primitives
are. A fibre does not move between threads; if a later provider moves
them, the move is a synchronization it must supply, and this answer is
reopened then.

V6  RESOLVED by D446 and D449: as proposed: threads are not a provider of the fibre
concepts, and the atomic wrapper names the single-writer update.

The original finding, for the record.

Code that is right because one fibre runs at a time.

`served +%= 1` is correct under every provider in this file, and racy
under a provider that runs tasks on two threads. Nothing in the source says
which it assumed. On Cortex-M0 the counter cannot be made atomic at all:
ARMv6-M has no read-modify-write, and D227 refuses one rather than mask
interrupts behind the program's back.

Proposed: threads are not a provider of `fibre.scheduler` or `fibre.turns`.
A provider of those concepts runs at most one of its fibres at a time, and
the concepts say so; a thread is a capability of its own, and state it
shares is the atomic wrapper's or a lock's. The wrapper answers Cortex-M0
by offering only what the core has: load, store, and a single-writer
increment, as `firmware/tick` writes by hand, and no read-modify-write
that a second writer could break.

V7  RESOLVED by D449: as proposed.

The original finding, for the record.

Stopping, when nothing cancels.

There is no cancellation, and there should not be one: unwinding another
fibre's stack is unwinding, which Landin does not do [1670], and a fibre's
`defer` runs only when the fibre does. So a server stops by failing the
I/O its fibres wait on. That rests on something no provider promises: that
shutting or closing a descriptor another fibre is waiting on wakes that
fibre with a failure. Over epoll it does not, for a close: a closed
descriptor leaves the interest list silently, and the fibre waiting on it
is never woken. A signal, likewise, has to reach a fibre as an event, not
as a handler that runs Landin code on some fibre's stack.

Proposed: an Io that runs fibres wakes every fibre waiting on a descriptor
when it is shut or closed through the provider, and the woken call fails
`io_failed`; closing a descriptor another fibre waits on is the closer's
mistake to avoid but never a fibre lost for ever. Signals reach a provider
as a waitable event and are read by an entry that waits like a receive. A
fibre that never ends holds its group's `join` for ever, as the device's
two do on purpose, and a fibre that is never resumed never runs its
`defer`s; both are stated rather than prevented. Its stack is the group's
backing, so nothing is released under it.

V8  RESOLVED by D444: as proposed.

The original finding, for the record.

Where a scheduler lives.

The device's board is forty lines and has no priorities, timers or
preemption, which is what makes it not a kernel. It is written in the
application because the library has none, and every device that wants two
fibres would write it again. The event-driven Io wants the same round with
a wait on epoll or kqueue where the board waits for an interrupt.

Proposed: `core/fibre` carries the switch, `whole`, and one round of fixed
turns over caller-supplied records, with the wait when nobody can run
supplied by the provider built on it: an interrupt wait on a device, the
event wait in the hosted Io. Priorities, timers, preemption and anything
else a kernel does stay out of the library, and an RTOS supplies its own
provider of the same concepts.

V9  RESOLVED by D447: as proposed.

The original finding, for the record.

How large a fibre's stack is, and what happens past it.

The server guessed sixteen kilobytes and holds two 256-byte buffers in
`serve` alone. The device guessed 640 bytes for each of two fibres out of
16 KiB of RAM and cannot afford to guess high, and a group's equal stacks
give the taker as much as the answerer, which needs more. Nothing reports
what a routine needs, and the group reaches it through the provider's
`any`, so its call graph is open at the one place a bound is wanted.
`admit` copies the state onto the stack as well, so a large state is
stack too. Past the backing, the stack runs into whatever is beside it: on
a device, the other fibre's stack; on a host, whatever the allocator put
there. Caller-supplied backing has no guard page unless the caller maps
one.

Proposed: the record keeps its stack's lowest address, and every switch
checks the saved stack pointer against it, failing the program's [1670]
handler past it — a late check, but on the device the only one there is.
The compiler reports, for each routine a program admits to a group, the
deepest stack of a call graph it can close, and says where an `any` call,
recursion or a foreign call opened it; the size is then the program's to
choose with that in hand, and a group of unequal stacks is one more way to
make one. `admit` refuses a state that leaves less than a stated minimum
of its stack. Which panic kind a stack past its limit is, is part of the
answer.

V10  RESOLVED by D449: as proposed, and half found while writing.

The original finding, for the record.

An interrupt cannot wake a fibre.

The handler has to leave the wake for the fibre to find. The first draft
did that with an ordinary `ticks +%= 1` in the handler and an atomic load
in the reader, which by D227 is a race, the handler's access being an
ordinary one to the object the reader loads atomically. One writer needs
no read-modify-write; the corrected handler loads and stores. That serves
a tick. It does not serve a flag that the handler sets and a fibre clears,
which is read-modify-write from two sides and is a critical section on
Cortex-M0, D227's PRIMASK protocol.

Proposed: the atomic wrapper names the single-writer case as its own
operation, available on every target, and refuses a shared
read-modify-write where the target has none, pointing at the critical
section. A wake that needs more than a counter goes through the provider:
a handler records an event the board looks at before it waits for an
interrupt, never a switch.

V11  RESOLVED by D447: as proposed.

The original finding, for the record.

Interrupt frames land on the running fibre's stack.

On Cortex-M with one stack pointer, an interrupt pushes its frame, and
every nested handler's, onto whichever stack was current. Each fibre's
backing must then hold the deepest interrupt nesting on top of its own
deepest call, and that is paid once per fibre. Cortex-M has a second stack
pointer for exactly this: thread mode on the process stack, handlers on
the main stack.

Proposed: on Cortex-M, fibres run on the process stack pointer and
handlers on the main stack, so the main-stack reservation pays for
interrupts once and a fibre's backing is its own calls alone. The reset
stack, entry 0 here, stays on the main stack. The frame-pointer exemption
for call-free leaves is untouched by this: a leaf that switches is not
call-free.

V12  RESOLVED by D447: as proposed.

The original finding, for the record.

What a debugger sees.

A backtrace in a fibre runs down to `prepare`'s first frame and has to
stop there cleanly rather than wander into the bytes below the backing. A
fibre that is not running is not a thread to GDB or LLDB: its frames are
on a stack nothing points at except its record. And a backtrace taken in
`switch` has to show the leaving fibre's frames, not half of each.

Proposed: the first frame ends the frame-pointer chain and says so in its
unwind information; `switch` is written so that, stopped anywhere in it,
the frames above are the leaving fibre's; and the records are ordinary
data a debugger script walks to show a suspended fibre's frames from its
saved stack pointer. No debugger is taught about fibres.

V13  RESOLVED by D448: as proposed.

The original finding, for the record.

What "two operations in flight" means on one core.

The device takes `NOW b` while `WAIT 200 a` sleeps and answers it after
`a`. That needs two fibres and keeps one operation in flight, if an
operation is the answering of a request and not its receipt. It could as
well have answered `b` first: the board takes turns, and the answerer could
have been two answerers. Whether it should is not the device's question to
settle; it is what the single-core answer is.

Proposed: on one core an operation in flight is a request whose answering
has started and not finished. The device answers in arrival order and
refuses with `busy` when its queue is full; receipt goes on in a fibre of
its own. Fibres on the device are for structure — taking input while
answering — and not to overlap answers. A trace of a derived program then
checks that answers come in request order and that no answer starts
before the previous one has finished.

V14  RESOLVED by D449: as proposed.

The original finding, for the record.

A fake that says a wait cannot end.

`core/io/fake`'s network answers `timed_out` at once for a call that would
wait, because "nothing in one thread could ever end the wait". With a
round of turns, another fibre in that thread can. A test of this server
over the fake network fails every accept before the client fibre has
connected.

Proposed: the fake network, given a scheduler, yields where it would wait
and answers `timed_out` only after a whole round in which nothing it
waits for arrived; without one, it behaves as now. The justification in
the library reference is reworded either way, because it was true only of
programs without fibres.

V15  RESOLVED while writing, by structure rather than by a rule: an
application starts fibres as a group, which it waits for before it goes
on, and hands each one an ordinary routine and a state. The switch and the
providers stay underneath, for whoever builds a scheduler.

The original finding, for the record.

The first draft started fibres the way C starts threads, and read like it.
Each fibre needed a struct, a declaration that the struct was a
`fibre.task` with a `run` entry, and an `any` built over it: a function
and a `void *` with more words. `start` returned with the fibre still
running, so its stack, its record and its state had to outlive the
caller, and all three were `escaping`. The session moved into a region,
then the host handle was copied into the region too, because an `any`
built from `main`'s binding had frame origin. The server kept an array of
records beside an array of stacks and found a free one by polling
`finished` in a loop of yields, which is a thread pool written by hand.
A session's failure had nowhere to go, since the entry had no error set,
so it was dropped. And the device handed `start`'s own frame to the
board's escaping `start`, which was refused, though a `noreturn` frame
outlives everything it starts.

None of that was the language's cost. Landin's own costs are the provider,
handed down, and the stack, lent by the caller, and the group keeps both
visible, each once. The rest was the shape of the interface: a fibre that
outlives the routine that started it is a thread, and needs a thread's
bookkeeping. One that does not is a call that happens to wait for more
than one thing.

---
