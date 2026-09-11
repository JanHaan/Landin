# Complete prototype-4 application derivation

This is the executable derivative of `prototype-4-app.md`, including the
R4.20 handoffs and D191/D196/W7 resolution. The prototype remains a historical
stress sketch; this program has no placeholder bodies. ROADMAP.md R4.80 owns
acceptance and closure evidence.

| Prototype section | Complete source and behavior |
| --- | --- |
| core/mem addition | `core/mem/allocation.ldn` initializes allocated objects; `core/mem/bytes.ldn` owns initialized byte extents; `core/region/region.ldn` records allocations against an explicit ordinary parent provider. |
| core/io/root/arguments | `core/io/io.ldn` and `core/io/memory.ldn` supply the same ordinary erased world protocol. `examples/derived_hosted/app/entry.ldn` alone mints hosted world/heap capabilities. `examples/derived_hosted/main.ldn` calls that root. |
| app/read | `examples/derived_hosted/app/reader.ldn` reads arbitrary-length complete lines across explicit chunk boundaries, preserves empty lines and final unterminated lines, and closes the consumed reader on every handled exit. |
| app/filter | `examples/derived_hosted/app/filter.ldn` implements exact level tokens, valid-UTF-8 substring matching, and stateful nth-line sampling as heterogeneous `any filter` values. |
| app/dest | `examples/derived_hosted/app/dest.ldn` implements text and count destinations, arbitrary copied byte messages, transactional append allocation, and cursor-based delivery/retry. The queue receives its allocator explicitly before erased dispatch; count emission needs none. |
| app/config | `examples/derived_hosted/app/config.ldn` copies the complete argument table's bytes, builds a runtime-sized vector of independently allocated heterogeneous filters, selects a destination, diagnoses and recovers from numeric input, and closes a newly opened destination if object allocation fails. |
| app/run | `examples/derived_hosted/app/app.ldn` composes configuration, line reading, ordered short-circuit filters, message copying, destination dispatch, explicit bounded retry, and reader/destination cleanup; diagnostic capability is passed to `run_logged`/`build_logged`. |

The app/read spelling differs from the sketch where implementation evidence
requires it: line growth takes an ordinary allocator argument; the borrowed
line still comes from the reader. Reader failures are terminal. The program's
run-lifetime region replaces the withdrawn lexical arena promise and uses no
hidden frame buffer. Its metadata consumes the same explicit parent capacity
as payloads. Individually released region allocations remain recorded until
region release; parent `free` decides whether capacity becomes reusable.

Configuration stores a valid file capability plus an `owns_output` flag:
counting borrows stdout, text owns an opened file. This avoids manufacturing
an invalid integer descriptor while respecting the enabled atom/pointer union
boundary. Output opens only after complete argument validation. Identical path
spellings are rejected; resolving filesystem aliases is outside this app's
path comparison and remains the caller's responsibility.

The destination protocol receives an owned message assembled with explicit
allocator authority before dispatch. Text writes consume its cursor; count
emission reads its bytes and updates fixed counters. Both providers are
selected dynamically and reached through their evidence pairs. `world.write`
returns no byte count on failure, so retrying a multi-byte call could duplicate
an unknown committed prefix. One-byte delivery makes progress knowable for
these providers. A failed call commits zero bytes; a successful call commits
one. This is a library/provider contract, not a compiler effect guarantee.
The application retries once; direct message users may explicitly retry later
while keeping the same message and stream alive. Diagnostic and count writes
have no resumable cursor and terminate on failure.

| Finding/support pressure | Current executable accounting |
| --- | --- |
| W1 | Only hosted entry mints authority; the complete application runs against memory and system worlds without inspecting provider identity. |
| W2 | Both worlds supply user arguments, excluding argv[0]; every retained byte is copied with a checked extent and explicit allocator. |
| W3 | Reader shutdown consumes the whole reader. Every acquired file closes once, even when close reports failure; close is never retried. |
| W4 | No allocator is added to the destination concept: message preparation allocates before dispatch; count state is fixed and text consumes an existing message. |
| W5 | Filter traversal uses initialized `vec.used` values; it does not pretend generic iterable copies are mutable places. |
| W6 | Each heterogeneous pair preserves its mutable provider pointer and evidence; sample filters update original state through indirect calls. |
| W7 | The historical proof missed helper-side-effect escape into module state. [0820]'s lexical promise is withdrawn; ordinary region/arena providers preserve useful helper results and simultaneous allocations without claiming transitive lifetime checks. |
| `prototype-2-parser.md` | The application reuses `core/text` UTF-8/positions and `core/diag` bounded/streaming `any log` capabilities used by `examples/config_parser/lexer/lexer.ldn`, `examples/config_parser/parser/parser.ldn`, and `runtime/derived-parser`. Command-line options need no recursive grammar parser; that complete support program remains separately executable. |
| `prototype-3-containers.md` | It directly reuses initialized allocation, vector growth/retention, explicit heap/arena providers, and `core/failing` accounting. The complete container support program is `examples/derived_containers/workload/workload.ldn`, pinned by `runtime/derived-containers`; its derivation records Z1-Z19. |

`runtime/derived-hosted-memory` starts with runtime-selected level, match, and
sample filters plus a text destination. It checks exact output despite a
partial-prefix delivery failure. Further cases cover a 9998-byte line with
one-byte reads, trailing and final unterminated lines, empty input, copied
configuration after argument mutation, arbitrary binary message copying and
retry, transactional append exhaustion, nested regions over explicit finite
backing, allocation-failure sweeps including metadata failures, and terminal
read/write/close/configuration failures with exact handle/allocation accounting.

`runtime/r480-hosted-count` runs the actual hosted root with real argv and an
input file, comparing counts and summary. `runtime/r480-hosted-text` runs that
same root with an output path and a 9011-byte final unterminated line, reads
back and checks every byte from the real file, closes it, and removes it.
The runtime/quality/debugger matrices retain the original fixture oracles and
native execution requirements; independent review and exact acceptance are
recorded by the roadmap, not inferred from focused development checks.

`negative/r480-reader-live-line` preserves the refusal of a genuine second
refill while the first line remains live. Separate loop-local line scopes may
refill after the prior iteration has ended; they do not weaken that oracle.
The bounded diagnostic case passes the same `core/diag.log` abstraction as
the parser, observes three distinct recoverable notes, and verifies a streaming
diagnostic failure stops before the reader opens.
