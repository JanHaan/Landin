# Derived hosted log filter

The complete executable derivative of prototype 4 lives in this directory.
Build and run it on native Linux x86-64 with the pinned compiler:

```sh
./scripts/dev-build.sh
compiler/ada/build/linux-amd64/debug/bin/refine --root=. --emit=exe \
  examples/derived_hosted -o compiler/ada/build/log-filter
compiler/ada/build/log-filter --level INFO --match request --every 2 input.log
compiler/ada/build/log-filter --out selected.log --level ERROR input.log
```

User arguments build an ordered heterogeneous filter chain. `--level` accepts
DEBUG, INFO, WARN, ERROR, or FATAL. A level is a complete leading token followed
by a space, tab, or end of line; unknown tokens have level zero. `--match`
requires valid UTF-8 and searches for its copied substring; invalid UTF-8 input
lines do not match. `--every` samples the lines that reached that filter, so
changing option order changes behavior. Invalid encoding, malformed or
unrepresentable numbers, and zero recover to one with distinct diagnostics;
the hosted process reports failure status after processing because its logger
has recorded an error. Repeated filters retain independent state. Unknown
options, missing operands, empty/NUL-containing paths, multiple input paths,
and identical input/output spellings are refused before opening a file.

`--out` selects the text destination; its absence selects eight per-level
counts on standard output. The program prints `kept: N` to standard error.
Input is split on LF, which is removed from each line. Other bytes, including
CR, remain unchanged. Empty lines are real lines, a final unterminated line is
returned once, and a trailing LF creates no phantom line. Reader chunks have
an explicit size, while lines and copied messages grow through the supplied
allocator without a fixed line-length limit. Allocation and read failures are
terminal for that reader; its partial internal line is not a retry protocol.

Every argument is copied before parsing, including a private trailing NUL for
paths. Configuration and match filters therefore survive later mutation of a
memory provider's argument buffers. The reader returns a `from reading` view,
consumed before its next refill. `process` copies each kept line into an owned
message and appends one LF before calling an ordinary erased destination.
The message keeps its completed delivery cursor across failure. Text delivery
writes one byte per `world.write` call: the repository system and memory
providers cannot report failure after completing that one byte. The caller
retries once, from the recorded cursor; a second failure terminates the run.
This deliberately favors a precise retry contract over throughput. A future
provider must honor the same one-byte success/failure contract to participate
in this delivery policy. Count output and diagnostics retain their existing
write-all behavior and report failure without blindly retrying an unknown
prefix. These policies claim neither transactional files nor durable delivery.

The root supplies a heap capability to ordinary `core/region`; every run
allocation, including region bookkeeping, uses that supplied authority.
`defer region.release_region` returns every recorded payload and ledger to the
parent on normal and failure exits. Region free is monotonic until release,
and a monotonic parent still retains its consumed backing after release.
`run`, `build`, and `copy_arguments` require such a run-lifetime allocator:
they deliberately do not individually reclaim configuration graphs. Copies,
retained pointers, and double release remain manual lifetime obligations.

`run_logged` and `build_logged` accept an ordinary `any core/diag.log`, shared
with the prototype-2 parser support. Convenience wrappers create the streaming
logger from the world supplied by their caller. Neither application routine
mints a host capability. The hosted root is `entry`; tests pass the same
application a caller-backed memory world and deterministic allocator failures.

The full source/support/fixture mapping is in
[DERIVATION.md](../../compiler/tests/fixtures/runtime/derived-hosted-memory/DERIVATION.md).
