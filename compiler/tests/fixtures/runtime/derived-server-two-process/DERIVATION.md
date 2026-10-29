# Prototype-5 server derivation

This is the executable derivative of `prototype-5-server.md`'s hosted half:
its `app/protocol`, `app/session`, `app/server` and `app` modules, complete
and with no placeholder bodies, in `examples/derived_server/`. The
prototype remains a historical stress sketch. Its firmware half,
`firmware/tick`, `firmware/board` and `firmware/app`, is derived by the
roadmap's firmware item and is not here; `app/protocol` is written so that
it can be shared with it unchanged. The sketch's `core/fibre` is the
library's, with D464's spellings.

Two fixtures run it. `runtime/derived-server-two-process` is the server in
a process of its own and a client in another, the server started through
`io.programs` and stopped with SIGTERM. `runtime/derived-server-fake-turns`
is the same server and the prototype's own client in one process, over
`core/io/fake`'s network and signals on a round of turns, which is what the
event provider's half of the two-process fixture will show on the hosts.

| Prototype section | Complete source and behavior |
| --- | --- |
| core/fibre | The library's `core/fibre`, `core/fibre/stacks` and `hosted/blocking`'s scheduler, as D444, D463 and D464 made them: a `task`'s `run` takes `ptr mut`, failures are `mem.out_of_memory`, and a group made over `turns` keeps it as `any turns`. The server writes no provider. |
| app/protocol | `examples/derived_server/app/protocol/protocol.ldn` reads `WAIT <ms> <tag>` and `NOW <tag>`, words separated by one space, the tag at least one byte with no space, the wait at most `longest_wait`, a minute; anything else is `malformed`. `answer` sleeps on the clock and writes `<tag> done`; `refuse` writes `malformed`. It imports `core/cmp`, `core/io`, `core/text` and `core/time` and nothing hosted. |
| app/session | `examples/derived_server/app/session/session.ldn` serves one connection to its end through a line reader and a buffered writer on the fibre's stack, answers a line too long for its 256-byte buffer `malformed` as it does any other, counts answered requests in the module's `served`, and keeps the connections being served in a table of `at_once` entries so stopping can shut them. |
| app/server | `examples/derived_server/app/server/server.ldn`: `serve_forever` accepts and admits each connection to a group of two over `any fibre.scheduler` whose stacks are its frame's, joined by `defer`; `serve` announces the address and serves with no signal waiter; `serve_until_terminated` watches SIGTERM, announces, and serves beside a fibre of a group over `any fibre.turns` that waits for the signal; `ask_both` is the prototype's client. |
| app | `examples/derived_server/app/app.ldn` reads `--io=blocking` or `--io=events` and `--port=N` through a `hosted/system` handle and mints the providers in `over_blocking` and `over_events`, the only routines that know which one they got; `examples/derived_server/main.ldn` calls it. |

The derivation departs from the sketch's spellings where the compiler
refused them or the sketch left a choice open, and D489 records each:

- An `any C` is no provider of `C` [1290], so the sketch's `net.accept(network, ...)`,
  `io.lines_over(self.network, ...)` and `protocol.answer(self.clock, ...)`
  do not compile. The server calls the erased entries, `network.accept(listener)`;
  `session.stream` holds the erased network and is the reader and writer
  `io.lines_over` and `io.buffered_over` are given; and `answer` takes its
  clock as `any time.clock`, which the firmware counterpart will make from
  its board.
- The sketch's `main` held one `any fibre.scheduler`. A provider that
  delivers signals is erased three ways, as `fibre.turns` for the signal
  waiter's group, as `signal.signals` and as `fibre.scheduler` for the
  sessions' group, because the three do not convert (D464).
- The sketch's stopping shut "the listener and both connections". The
  waiter shuts each connection being served, both directions, and closes
  the listener, so the accept and every receive fail `io_failed` (D449);
  the server's own end is clean only when the waiter stopped it, which it
  notes in a `bool` of `serve_until_terminated`'s frame kept through
  `escaping into` (D445).
- An `accept` or a client's `receive` that times out is tried again: over
  the hosted providers no limit is set and it never does, and over the
  fake network a round in which only a sleeping clock moves times it out
  (D483).
- The sketch's `serve` failed the session on a line too long for its
  buffer; the derivative answers it `malformed`, and the line reader skips
  the rest of it.

| Finding | Current executable accounting |
| --- | --- |
| V1 | The sessions' group is made over `fibre.scheduler` with `group_over`, so the same `serve_forever` serves one connection at a time over `hosted/blocking` and two at once over a provider of turns; `ask_both` and the signal waiter's group ask for `turns` with `turns_over`, which refuses the blocking host where the group is made. The two-process fixture's blocking half sees `a` answered first. |
| V2 | Every task's set is `failure.reason`. A session's failure is kept by the group and dropped at `serve_forever`'s deferred `join`, so one connection's failure stops nothing else; the signal waiter's is `join`'s, which `serve_until_terminated` fails with. |
| V3 | Each session's state refers to `serve_forever`'s parameters, the signal waiter's to a local declared before its group, and each ask's to `ask_both`'s `inout` parameter, all kept through `escaping into`; every group is joined by `defer`. |
| V4 | The switch points are the provider's: the clock's `sleep`, `accept`, the line reader's reads, the writer's flush and `next_signal`. `served_one` and the open-connection table switch nowhere. No `last_errno` is read. |
| V5, V6 | `served +%= 1` and the connection table are plain module state: the fibres of one provider are one context (D446). Over the blocking host there is one fibre at a time anyway. |
| V7 | Over a provider of signals, SIGTERM is read by a fibre and stops the server by failing its I/O; over `hosted/blocking` no signal is waited for and SIGTERM's default disposition ends the process (D477), which the two-process fixture checks. The event provider's clean stop is checked in-process now. |
| V8 | The in-process fixture runs the server on `core/fibre/stacks`' round, the library's round of turns, under `core/io/fake`'s signals. |
| V9 | The stacks are guessed, as the sketch's were: 16 KiB for each session and for the signal waiter, 16 KiB for each ask. Every routine checks its frame against its stack's limit (D471), so a guess too small traps rather than overruns. |
| V14 | `runtime/derived-server-fake-turns` runs the server over the fake network given a round of turns (D483), whose waiting calls take turns. |
| V15 | The server, the waiter and the client start fibres only as groups they join. |
| V10, V11, V12, V13 | The firmware counterpart's and the debugger's, not this derivative's. |

`runtime/derived-server-two-process` is the exit evidence's shape. Run
without arguments, the fixture's program starts itself again through
`io.programs` as the server, `serve --io=blocking --port=0`, which calls
the same `app.entry` the example's `main` does. It reads the server's
first line, `listening on 127.0.0.1:<port>`, sends `WAIT 1000 a` on one
connection and `NOW b` on another, and reads the second with a limit of
500 milliseconds, half of `a`'s wait: an answer within it came first, and
none means `a` comes first (D490). Over the blocking provider it requires
`a` first, sends SIGTERM, and requires the server to have ended by that
signal and written nothing more. It then starts the server with
`--io=events`, which this build refuses with status 3 and no output.

When `hosted/events` lands, two things change and nothing else. In
`examples/derived_server/app/app.ldn`, `over_events` mints the event
handle, erases it as `any fibre.turns`, `any signal.signals`,
`any fibre.scheduler`, `any net.network`, `any time.clock` and
`any io.world`, listens through `listening` and calls
`server.serve_until_terminated`, returning 0 when it returns and 1 when it
fails, as `over_blocking` does. In the fixture, `refused_events(host)`
becomes `exchange(host, "--io=events", "ba", true)`: `b` first, then a
clean end, status 0, with `stopped after 2 requests` as the server's last
output line. The fixture's summary and this paragraph say so then.

`runtime/derived-server-fake-turns` runs `serve_until_terminated`, the
routine the event provider will serve with, beside `ask_both` in a fibre,
over `core/io/fake`'s network and signals on one round and a clock that
takes a turn for each millisecond it sleeps. It requires `b` answered
before `a`, two requests served, 200 milliseconds slept, two connections
made, the server stopped by SIGTERM which the client raises once both
answers are in, and the server's two lines on standard output.
