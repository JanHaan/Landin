# The Benchmark Game, measured

Five of the Benchmark Game's programs are Landin fixtures, and this page
records what they cost against seven other languages on one machine. It is
derived from measurements and decides nothing: `ROADMAP.md` owns the work
they led to, and the fixtures in `examples.md` are the programs.

The figures below are the baseline taken before any code-generation work
aimed at them. Each later measurement is added beside them rather than in
place of them, so the page keeps showing what changed.

## How they were measured

One host: an AMD EPYC 7302 (Zen 2) under NixOS on Linux 6.18. Every program
was pinned to one core with `taskset` and run alone at the Benchmark Game's
performance size. Wall time is the median of three runs when the first took
under a minute, and one run otherwise, with a fifteen-minute cap. Peak
resident memory is GNU time's. Other work ran on other cores throughout,
including compiler builds during the fasta, reverse-complement and
binary-trees runs. Repeated runs agreed within 0.3 per cent, but a
difference of a few per cent between programs is still noise.

Each language ran the Benchmark Game's own single-threaded program that uses
no explicit SIMD, where one exists. Otherwise it ran the closest program
made sequential by the smallest change, or a port using only the standard
library. Zig, which the Benchmark Game no longer carries, ran ports of the
Landin programs. Every output was byte-identical to C's, and every output
at the correctness size to the Benchmark Game's own file.

| language | version and flags | checks |
|---|---|---|
| Landin | `refine` built from `main` at `ba9c4cc4`, `--optimize speed`, the x86-64-v1 baseline, static, no C library | on |
| C | gcc 15.2.0, `-O3 -march=native -fomit-frame-pointer` | none |
| Ada | GNAT 16.1.0, `-O3 -gnatNp -march=native` | off |
| Rust | rustc 1.95.0, `-C opt-level=3 -C target-cpu=native -C codegen-units=1` | on |
| Zig | 0.16.0, `ReleaseFast -mcpu=native` | off |
| Go | 1.26.7, `GOAMD64=v3` | on |
| Node.js | 24.19.0 | on |
| Python 3 | CPython 3.13.15, no extension modules | on |

The nix compiler wrappers drop `-march=native` silently unless
`NIX_ENFORCE_NO_NATIVE=0` is exported where the compiler runs, inside the
development shell for GNAT; the C and Ada figures are with it set.

`--build-mode release` changes no generated code, and `--level x86-64-v3`
measured within two per cent of the baseline on fannkuch-redux and
mandelbrot, so Landin ran with the defaults.

## Time

Seconds, and in brackets the multiple of C's time.

| | fannkuch-redux 12 | mandelbrot 16000 | fasta 25,000,000 | reverse-complement, fasta's 25,000,000 | binary-trees 21 |
|---|---|---|---|---|---|
| Landin | 106.1 (2.7) | 92.3 (5.0) | 14.2 (4.7) | 6.15 (7.9) | 236.4 (15.9) |
| C | 39.7 | 18.6 | 3.05 | 0.78 | 14.9 |
| Ada | 25.3 (0.64) | 18.5 (0.99) | 2.89 (0.95) | 3.73 (4.8) | 13.2 (0.89) |
| Rust | 36.6 (0.92) | 4.49 (0.24) | 2.11 (0.69) | 0.79 (1.0) | 16.3 (1.1) |
| Zig | 39.8 (1.0) | 19.4 (1.04) | 4.03 (1.3) | 0.74 (0.95) | 13.4 (0.90) |
| Go | 38.6 (0.97) | 18.6 (1.0) | 3.77 (1.2) | 0.80 (1.0) | 31.1 (2.1) |
| Node.js | 42.9 (1.1) | 19.3 (1.04) | 17.3 (5.7) | 4.09 (5.2) | 14.2 (0.95) |
| Python 3 | over 900 | 875.8 (47) | 41.6 (13.6) | 3.23 (4.1) | 99.1 (6.7) |

Landin's geometric mean over the five is six times C's time.

### After the first fixes

The cheapest of the causes below were fixed next: small copies and clears
written as moves at `speed`, traps moved after each routine's body, `movapd`
between registers, the slice element's self-comparison dropped, a result
allowed its dying operand's register, routine-wide registers chosen by loop
depth, jumps threaded past empty blocks, and `hosted/heap` and
`core/region` reworked. The same five sources, rebuilt and run the same way
on the same core with no build running beside them, produced the same
output:

| | fannkuch-redux 12 | mandelbrot 16000 | fasta 25,000,000 | reverse-complement, fasta's 25,000,000 | binary-trees 21 |
|---|---|---|---|---|---|
| Landin, before | 106.1 (2.7) | 92.3 (5.0) | 14.2 (4.7) | 6.15 (7.9) | 236.4 (15.9) |
| Landin, after | 84.8 (2.1) | 72.2 (3.9) | 9.72 (3.2) | 4.82 (6.2) | 79.5 (5.3) |
| Landin, after the second fixes | 47.4 (1.19) | 21.1 (1.13) | 6.04 (2.0) | 1.53 (2.0) | 56.9 (3.8) |

The geometric mean fell from six times C's time to 3.9, and binary-trees'
peak from 656 megabytes to 394.

The second fixes went after the larger causes: float and pointer slots
forwarded, a forwarded value kept across writes that cannot reach its slot,
identical operations and checks within a block computed once, results
computed in their own register with immediate operands, float registers in
routines that call, every slot given a register over its live interval,
indexed accesses as scaled operands, `and` and `or` conditions as jumps,
float comparisons fused with their branches, division by a constant as a
multiplication, and `core/mem` moving words. Run the same way, with the same
output, the geometric mean is 1.8 times C's time: fannkuch-redux and
mandelbrot within a quarter of C's, Go's and Zig's, and reverse-complement
faster than Ada's, Node.js's and Python's.

### Closing the remaining gap

The next fixes came from measuring native arm64 and ordinary programs as
well as these five. The arm64 backend gained what x86-64 had: floating-point
values in registers, results in their own register with immediate operands,
fused comparisons, division by a constant as a multiplication and small
copies as moves. Both backends give small routines registers, caller-saved
where no call crosses a value. Immutable module values fold; a check a
dominating comparison or a type's range proves is removed; a callee reads an
aggregate argument where its caller keeps it when nothing can change it; an
allocator resizes a block in place or with `mremap`. Then small direct calls
are copied into their callers at `speed`, slices and small structs are split
into scalars, a branch whose arms only compute becomes a choice, and every
x86-64 routine starts on a 64-byte boundary. fasta's port now counts in its
lookup, as the Benchmark Game's C program does, rather than leaving at the
first match.

Copying an unchanged executable moved its time by up to half, with where its
code landed in physical memory, so these times are the median of three
fresh copies of each executable, C's re-measured the same way in the same
session:

| | fannkuch-redux 12 | mandelbrot 16000 | fasta 25,000,000 | reverse-complement, fasta's 25,000,000 | binary-trees 21 |
|---|---|---|---|---|---|
| Landin, before | 47.6 (1.20) | 21.2 (1.14) | 6.09 (1.99) | 1.63 (2.10) | 57.6 (3.87) |
| Landin, after | 41.7 (1.05) | 20.0 (1.07) | 3.78 (1.23) | 0.99 (1.30) | 32.8 (2.22) |
| C | 39.7 | 18.6 | 3.08 | 0.76 | 14.8 |

The geometric mean fell from 1.86 times C's time to 1.32, with every output
the C program's.

On an Apple M1 Pro, at sizes of a few seconds (fannkuch-redux 11, mandelbrot
4000, fasta 2,500,000, binary-trees 16, reverse-complement on that fasta's
output), as multiples of C built with the system's own compiler:

| | fannkuch-redux | mandelbrot | fasta | reverse-complement | binary-trees |
|---|---|---|---|---|---|
| Darwin, before | 2.35 | 8.66 | 10.8 | 6.87 | 4.89 |
| Darwin, after | 1.07 | 1.50 | 2.51 | 2.01 | 1.60 |
| Linux arm64, before | 2.60 | 8.99 | 4.39 | 7.53 | 9.18 |
| Linux arm64, after | 1.18 | 1.55 | 0.99 | 2.26 | 2.98 |

Landin's own times are nearly the same on both systems; the multiples differ
because C's do, fasta's C being two and a half times faster on Darwin and
binary-trees' twice as fast on Linux.

Seven ordinary programs, each against a straightforward C one: a `core/vec`
list pushed, read and popped ten million times, a `core/map` of a million
keys looked up eight million times, a `core/sort` of two million integers
and records, `text.format` writing three million lines, a lexer over 33
megabytes, word count over 171, and a hundred million calls through
`any shape`. After the first of these fixes they ran 1.8 (sort) to 9.5
(vec) times C's time, from 2.2 (word count) to 13.9, the largest gains in
vec, map, the lexer and sort; copying small calls then took a further third
off word count and a fifth off vec, and splitting structs nearly a fifth off
the lexer.

## Peak resident memory

Megabytes, before the fixes.

| | fannkuch-redux | mandelbrot | fasta | reverse-complement | binary-trees |
|---|---|---|---|---|---|
| Landin | 1.1 | 1.4 | 1.1 | 262 | 656 |
| C | 1.1 | 1.1 | 1.1 | 249 | 264 |
| Ada | 1.3 | 1.1 | 1.1 | 132 | 263 |
| Rust | 1.4 | 33 | 1.3 | 249 | 264 |
| Zig | 1.1 | 1.1 | 1.1 | 249 | 132 |
| Go | 1.9 | 1.9 | 1.9 | 162 | 288 |
| Node.js | 44 | 52 | 1,230 | 554 | 1,241 |
| Python 3 | — | 9.8 | 10 | 455 | 273 |

## What the programs were

| | fannkuch-redux | mandelbrot | fasta | reverse-complement | binary-trees |
|---|---|---|---|---|---|
| C | #3 | #8 | #2 | #5 | #1 |
| Ada | #3, its chunks run in sequence | #2 | #2 | #1 | #1 |
| Rust | #2, made sequential | #1, made sequential | #3 | #2 | a port of #1 without its crate |
| Zig | the Landin port | the Landin port | the Landin port | the Landin port | the Landin port |
| Go | #8 | #8 | #1 | #2 | #1 |
| Node.js | #8 | #2 | #8 | #2 | #7 |
| Python 3 | #6 | #3 | #2 | #2 | #2 |

The programs differ in ways that matter to their times:

- Rust's mandelbrot iterates eight pixels together, which `target-cpu=native`
  turns into AVX2. It does more iterations than the others and is still four
  times faster.
- Rust's fasta compares integer thresholds against the raw seed and does no
  floating-point arithmetic. Python's uses `bisect` and writes the ALU
  sequence as one block.
- The Landin fasta timed here stopped its probability search at the first
  cumulative probability above the random number, a branch the processor
  mispredicts about once a symbol. The port now counts the probabilities
  the number reaches, as C's program does, which the compiler selects
  without a branch.
- C's fannkuch-redux uses a different permutation generator and skips the
  last flip.
- In binary-trees, C, Ada and Rust allocate and free each node through
  `malloc`; Zig bump-allocates in one arena per tree; Go, Node.js and Python
  use their collectors; Landin uses one `core/region` per tree over
  `hosted/heap`.

## Where Landin's time went

The checks are not where the time goes. Hand-edited assembly of
fannkuch-redux that keeps every bounds and overflow check runs at gcc
`-O2`'s speed, and with the traps moved out of the hot path all its checks
together cost about three per cent. Hand-edited assembly and library
copies, each with output unchanged, measured these causes:

| cause | measured on | gain |
|---|---|---|
| A small fixed copy or clear through `rep movsb` or `rep stosb`, including every 16-byte slice passed by value | fasta, binary-trees, fannkuch-redux | 24, 13 and 5 per cent |
| Every check's trap inline, so that a passing check is a taken branch | fannkuch-redux | 13.5 per cent |
| A register-to-register `movsd`, which waits on its destination | mandelbrot | 21 per cent |
| `hosted/heap` reading and writing its headers a byte at a time, and placing them unaligned | binary-trees | 35 per cent, and a node's slot from 64 bytes to 32 |
| `core/region`'s ledger copied on every doubling and mapped and unmapped above 4 KiB | binary-trees | a further 21 per cent, and 29,000 fewer system calls at depth 16 |
| Floating-point temporaries forwarded through the stack rather than kept in registers | mandelbrot | 35 per cent |
| Each operation computed in `%rax` or `%xmm0` and copied out | mandelbrot, fannkuch-redux | 41 and about 25 per cent |
| `core/mem`'s `copy` and `find` working a byte at a time | reverse-complement | 58 per cent |
| No inlining | all five | about 10 per cent each |

With all of them applied by hand, mandelbrot at 4000 ran in 1.20 seconds
against C's 1.15, fannkuch-redux at 11 in 2.77 against 2.70 for a C program
using Landin's algorithm, reverse-complement in 80 milliseconds against 46,
and binary-trees at depth 18 in 6.9 seconds against 1.29.

## Compile time

The same programs, and a hello-world in each language, compiled on the same
host with cores 0 to 7 available to every compiler. Each figure is the median
wall time in seconds of five compiles, after one more that warms the caches,
each in a fresh directory and in the compiler's own nix environment, so no
shell start-up is timed. A compile includes assembling and linking. Landin's
is the release `refine`. C, Ada and Rust use their precompiled standard
libraries. Go keeps its standard library in its build cache and Zig its
runtime in its own, and a comment that changes on every compile makes each
rebuild and relink the program itself; Zig compiles the parts of its standard
library a program uses together with it, so ReleaseFast optimizes them again
every time. The programs are the ones timed above, so a row compares one
benchmark rather than one text: Ada's fannkuch-redux is 258 lines and
Landin's 110. Every Landin program also checks its library from source,
about 11,500 lines over 31 files for any program that imports `core/io`.
Node.js and Python compile nothing ahead of time and are left out.

Optimized, as the benchmark builds are: Landin at `--optimize speed`, C at
`-O3 -march=native`, Ada at `-O3 -gnatNp`, Rust at `opt-level=3` with one
codegen unit, Zig ReleaseFast and Go's default:

| program | Landin before | Landin after | C | Ada | Rust | Zig | Go |
|---|---|---|---|---|---|---|---|
| hello-world | 1.16 | 0.29 | 0.09 | 0.42 | 0.23 | 14.41 | 0.24 |
| fannkuch-redux | 1.19 | 0.31 | 0.15 | 0.64 | 0.99 | 14.50 | 0.24 |
| mandelbrot | 1.25 | 0.35 | 0.12 | 0.39 | 0.60 | 14.47 | 0.24 |
| fasta | 1.23 | 0.31 | 0.18 | 0.79 | 0.50 | 14.46 | 0.26 |
| reverse-complement | 1.23 | 0.32 | 0.15 | 0.49 | 0.46 | 14.45 | 0.22 |
| binary-trees | 1.24 | 0.34 | 0.17 | 0.55 | 0.34 | 15.27 | 0.30 |

Unoptimized: Landin at `--optimize none`, C and Ada at `-O0` (C with
`-fgnu89-inline`, which fannkuch-redux's non-static `inline` needs to link
there), Rust's default, Zig Debug and Go with `-gcflags=-N -l`:

| program | Landin before | Landin after | C | Ada | Rust | Zig | Go |
|---|---|---|---|---|---|---|---|
| hello-world | 0.99 | 0.28 | 0.09 | 0.42 | 0.22 | 0.79 | 0.23 |
| fannkuch-redux | 0.99 | 0.32 | 0.09 | 0.53 | 0.31 | 0.79 | 0.23 |
| mandelbrot | 1.03 | 0.35 | 0.09 | 0.36 | 0.33 | 0.81 | 0.25 |
| fasta | 1.04 | 0.31 | 0.10 | 0.63 | 0.33 | 0.79 | 0.25 |
| reverse-complement | 1.05 | 0.34 | 0.10 | 0.44 | 0.31 | 0.79 | 0.22 |
| binary-trees | 1.06 | 0.35 | 0.12 | 0.46 | 0.28 | 0.91 | 0.28 |

Peak resident memory of the optimized compiles, in mebibytes, the largest
process the compiler waited for:

| program | Landin before | Landin after | C | Ada | Rust | Zig | Go |
|---|---|---|---|---|---|---|---|
| hello-world | 68 | 37 | 26 | 34 | 84 | 229 | 54 |
| fannkuch-redux | 69 | 42 | 34 | 44 | 99 | 230 | 56 |
| mandelbrot | 79 | 44 | 32 | 35 | 100 | 229 | 57 |
| fasta | 79 | 42 | 35 | 41 | 99 | 229 | 56 |
| reverse-complement | 79 | 42 | 33 | 38 | 98 | 229 | 51 |
| binary-trees | 80 | 44 | 36 | 37 | 94 | 227 | 57 |

Landin compiles on one core, as C and Ada do here; Go and Zig Debug use
more, so their processor time exceeds their wall time by up to 80 per cent.

### Where the compiler's time went

Before, hello-world cost Landin almost what fannkuch-redux did, because nearly
all of it went to the library. Three causes, each measured alone against the
compiler before them:

| cause | change | hello-world at speed |
|---|---|---|
| Every routine of every imported module lowered, emitted and assembled: hello-world emitted 546 routines and 69,192 lines of assembly, of which the linker kept 34 | only the routines a program can reach are lowered, 64 for hello-world in 8,278 lines | 1.18 to 0.64 seconds |
| A fifth of the compile in GNAT's runtime: each indexed read of a container built a controlled reference, finalized under abort deferral, accessors returned whole records that the controlled scope kept GCC from eliding, and the checker elaborated about ten container instances for every routine it checked | reads through `Element`, the instances at library level | 1.24 to 0.63 seconds, with byte-identical assembly |
| The IR verifier's atom-set and encoding duplicate checks quadratic per set, its pointer-provenance trace clearing every block for every slot, and x86-64 emission allocating every routine once to test its frame and again to emit it | linear checks, a trace that clears what it marked, a frame bound that allocates only when the bound fails | lowering a third and emission at speed 30 per cent faster, with byte-identical assembly |

Together they take hello-world from 1.16 to 0.29 seconds and the five ports
from 1.19 to 1.25 seconds to 0.31 to 0.35 at speed, with each port's output
unchanged.
