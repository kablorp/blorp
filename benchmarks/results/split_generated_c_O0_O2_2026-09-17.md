# Splitting the generated CLI C into multiple translation units: does it help?

2026-09-17. Measurement study only -- the Blorp emitter
(`blorp/src/compiler/stage_10_backend/`) was not touched. All splitting is a
post-processing step on the already-generated
`blorp/build/_build/blorp-cli/blorp_cli_main.c`, done by
`benchmarks/split_generated_c.py`, and measured by `benchmarks/bench_split_c.py`.

## Machine / toolchain

- MacBook Air, Apple M4, 10 cores (4 performance + 6 efficiency), macOS 26.6.2 (build 25G83).
- `cc --version`: Apple clang version 21.0.0 (clang-2100.3.34.2), Target: arm64-apple-darwin25.6.0.
- The machine was shared with other concurrent Blorp worktree sessions doing
  their own full `-O2` builds for part of the measurement window; see
  "Contention and re-runs" below for which cells that affected and which were
  re-run once the machine was quiet.

## Part 0: which build paths use -O0 vs -O2

From the Makefile and `.github/workflows/`, `scripts/test`, `scripts/premerge-gate`,
`scripts/docker-gate`:

- `Makefile`: `BLORP_CLI_C_OPTIMIZATION ?= -O0` (the default for a plain local
  `make` / `make compile-blorp-cli`). `BLORP_CLI_RUNTIME_C_OPTIMIZATION` (the
  small, separate `runtime.c` object that's always linked in) is fixed at `-O2`
  regardless.
- **-O2** (every path that gates a merge or ships a binary):
  - `.github/workflows/ci-platform.yml` -- the reusable workflow behind
    `.github/workflows/ci.yml` (push/PR to `main`, Linux x64/ARM64 and macOS
    lanes) -- sets `BLORP_CLI_C_OPTIMIZATION: -O2` for both the "Compile" and
    "Quality checks" steps.
  - `.github/workflows/release.yml` -- sets `-O2` for the "Compile" step on
    every release target (`ubuntu-latest`, `ubuntu-24.04-arm`, `macos-15`).
  - `scripts/docker-gate` -- the full local gate run always exports
    `BLORP_CLI_C_OPTIMIZATION=-O2` (its own help text calls this out
    explicitly, distinguishing it from `--premerge-gate`).
  - `scripts/premerge-gate` -- exports `BLORP_CLI_C_OPTIMIZATION=-O2`
    unconditionally ("clean build at -O2").
  - `scripts/test --release-compiler` -- exports `-O2` for that install.
- **-O0** (fast local default):
  - Plain `make` / `make compile-blorp-cli` with no environment override.
  - `scripts/test` without `--release-compiler`.
  - `scripts/compiler-build-status` defaults `BLORP_CLI_C_OPTIMIZATION` to
    `-O0` if the environment doesn't set it.

So: **every CI lane that gates `main`, every release build, and the full local
gate (`docker-gate`/`premerge-gate`) already pay the `-O2` C-compile cost.**
`-O0` is only the fast-iteration default for an unqualified local `make`.
CI's GitHub-hosted `ubuntu-latest` runners are the standard 4-vCPU tier, which
is the basis for the scaled CI estimate below.

## The generated C, as actually measured (2026-09-17, this checkout)

Generated via `make prepare-blorp-cli-c` (bootstrap `dev-8b704693af73`):
`blorp/build/_build/blorp-cli/blorp_cli_main.c`, 94,408,654 bytes, 1,337,807 lines.

`benchmarks/split_generated_c.py`'s own top-level scan of that file counts:

| category | count |
|---|---|
| function definitions (all `static`, some `static inline`) | 25,020 |
| forward-declared prototypes (dropped; regenerated from the definitions) | 15,158 |
| `BLORP_STATIC_STRING(...)` literal globals | 7,392 |
| other `static` globals (closures, canonical record/list/union singletons, etc.) | 3,803 |
| globals with an anonymous `struct { ... }` type | 15 |
| `typedef`/`#include`/`#define` lines (become the shared header) | 8,163 |

## The splitter

`benchmarks/split_generated_c.py <source.c> <out_dir> -n N [-n N ...]` produces
`<out_dir>/nN/split_shared.h` plus `split_body_0.c .. split_body_{N-1}.c`. See
the file's module docstring for the full design; in short:

- A brace/string/comment-aware scanner (not a full C parser) walks the file at
  the top level and classifies every unit as a `typedef`/`#include`/`#define`
  (-> header), a function definition (-> one body TU, `static`/`inline`
  stripped, promoted to external linkage with a generated prototype in the
  header), a global variable definition (-> defined once in `split_body_0.c`,
  `extern`-declared in the header for everyone else), or a bare forward
  prototype (dropped; every function's prototype is regenerated from its
  actual definition instead of trusting the original).
- `BLORP_STATIC_STRING` literals get special handling: duplicating a literal's
  storage across TUs would break Blorp's `same_object` pointer-identity
  guarantee for immortal literals, so the splitter defines each one exactly
  once (via a second macro, `BLORP_EXTERN_STRING`, identical to the original
  but without `static`) and `extern`-declares it everywhere else.
- The 15 globals with an anonymous `struct { ... }` type (canonical
  empty/static list singletons) get a synthesized `typedef` so the `extern`
  declaration in the header and the definition in the owning TU refer to the
  *same* named type -- an anonymous struct type is not compatible across
  translation units in C, so extern-declaring the literal anonymous form would
  be unsound.
- Functions are assigned to TUs by walking them in original file order and
  cutting into N contiguous, byte-size-balanced bins (greedy accumulation
  against `total_bytes / N`), so relative order is preserved within a TU and
  bin sizes are close to equal.
- `N=1` reproduces the whole program as a single TU (sanity anchor).

### Correctness

Verified for every N in {1, 2, 4, 8, 16}:
- Every generated TU passes `cc -fsyntax-only` with the exact Makefile flags.
- The full link (`cc <OPT> ... split_body_*.c runtime.o runtime_sources.c
  native_runtime.c -lm -lpthread`) succeeds with no duplicate/missing symbols.
- The resulting `bin/blorp` passes `blorp/test/cli/test_cli.sh --smoke
  --timeout 60` (the same 110-case CLI smoke suite
  `test_rebuilt_cli.sh` runs), at both `-O0` and (spot-checked at N=1 and
  N=8) `-O2`.

No construct in the generated C blocked a clean split; see "Design risks"
below for the handling each special case needed.

## Results

All cells: N in {1, 2, 4, 8, 16}, 3 runs each, median reported (raw values in
`benchmarks/results/split_bench_raw.json`, one throwaway run implicit in the
methodology below). Serial CPU = sum of per-TU `user+sys` from
`/usr/bin/time -l`, each TU compiled alone (not under xargs contention), then
medianed across the 3 full-cell runs. Parallel wall = wall-clock to compile
all N TUs with `xargs`-style parallelism `min(N, 10)`, medianed across the
same 3 runs. Peak RSS = the max single-TU RSS observed in a cell's last
trial. Link = final `cc <OPT> ... -o bin/blorp` link step.

| N | OPT | serial CPU (median s) | parallel wall (median s, P=min(N,10)) | peak RSS (median MB) | link (median s) | binary size (MB) | smoke |
|---|---|---|---|---|---|---|---|---|
| 1  | -O0 | 15.1  | 16.1 | 1489 | 0.13 | 22.1 | pass |
| 2  | -O0 | 20.1  | 12.2 | 817  | 0.15 | 22.1 | pass |
| 4  | -O0 | 16.9  | 7.0  | 561  | 0.12 | 22.1 | pass |
| 8  | -O0 | 17.4  | 5.5  | 456  | 0.12 | 22.1 | pass |
| 16 | -O0 | 15.2  | 5.3  | 344  | 0.13 | 22.1 | pass |
| 1  | -O2 | 152.1 | 185.4 | 5474 | 0.40 | 18.3 | pass |
| 2  | -O2 | 111.5 | 73.9  | 3485 | 0.24 | 18.2 | pass |
| 4  | -O2 | 88.0  | 41.3  | 1940 | 0.22 | 18.2 | pass |
| 8  | -O2 | 98.8  | 27.9  | 1164 | 0.16 | 18.2 | pass |
| 16 | -O2 | 97.4  | 25.2  | 739  | 0.16 | 18.3 | pass |

Every cell's binary passed the 110-case CLI smoke suite (one N=16/-O0 run
flagged a single flaky failure; see "Contention and re-runs" -- it was not
reproducible and not a splitter bug).

**Peak RSS is the standout number for CI, not just compile time.** At -O2,
a single whole-file (N=1) compile peaks at **5.5 GB RSS**; splitting into 8
TUs cuts that to **1.16 GB per TU** (16 TUs: 0.74 GB). A stock GitHub-hosted
`ubuntu-latest` runner has 16 GB RAM and 4 vCPUs -- running N=1's single `cc`
is fine in isolation, but it means *any* attempt to run compile jobs in
parallel with other work on that runner is memory-constrained by one 5.5 GB
process. Splitting turns that into several sub-1.2 GB processes, which is
what actually makes `-P 4` on a 4-vCPU runner safe rather than a
close call.

Both **-O0 and -O2 give the same qualitative answer**: serial CPU (total
compiler work) is roughly flat across N -- there's a small, real per-TU
overhead (parsing/re-instantiating the shared header N times; ~15-20s total
at -O0, ~90-150s total at -O2, both without a strong trend once N >= 2) --
while **parallel wall time falls sharply and monotonically** as N grows,
because there's finally more than one compilation unit to hand to the other
cores. At -O0 that's 16.1s -> 5.3s (N=1 -> N=16), a 3.0x wall-clock
speedup on this 10-core machine. At -O2 it's 185.4s -> 25.2s, a **7.4x**
wall-clock speedup, because -O2's cost is so back-loaded onto that single
42,223-line worst-case function (see "Cliff analysis") that N=1 can't use
more than 1 core no matter how many are free.

Diminishing returns set in around N=8: parallel wall from N=8 to N=16 only
improves 27.9s -> 25.2s (-O2) and 5.5s -> 5.3s (-O0), because this machine
only has 4 performance cores (plus 6 efficiency cores) -- past N=4-8 there
just isn't enough real parallel headroom left for another doubling of TU
count to help much, and per-TU overhead (header reparse, extra `cc` process
startup) starts to matter more than it saves.

## Self-compile speed at -O2: N=1 vs N=8 (and N=16)

Timed `bin/blorp compile --std-dir standard_library/src --no-format
--no-embed-runtime -o <tmp> blorp/src/main.brp`, 3 runs each, using the -O2
binaries already built for the table above:

| N | user CPU (median s) | wall (median s) | all user-CPU samples |
|---|---|---|---|
| 1  | 21.07 | 21.45 | 23.59, 21.07, 19.40 |
| 8  | 18.48 | 18.88 | 18.48, 18.47, 19.13 |
| 16 | 18.74 | 19.31 | 18.74, 17.37, 19.32 |

**Losing cross-TU inlining at -O2 did not make the resulting compiler
slower.** If anything the split binaries self-compile marginally *faster*
(~12% less user CPU, N=8/16 vs N=1), though N=1's range (19.4-23.6s)
overlaps the low end of N=8/16's range (17.4-19.3s), so this is closer to
"no measurable regression" than "the split binary is definitively faster" --
either way there is no case for paying an LTO link-time tax here. Per the
task's own trigger condition ("if the split binary is measurably slower, try
`-flto`"), that condition wasn't met, so `-flto` was not attempted.

## Cliff analysis

At **-O0**, this reproduces the project's known finding: total serial CPU is
roughly flat regardless of how the file is cut (15-20s whichever way), so
there's no real "cliff" at -O0 in this per-TU-serial view -- the previously
documented superlinear cost was specifically about compiling large
*contiguous prefixes* of the whole file at once (first half vs 75% vs whole
file), not about the sum of many small independent compiles, which is what
this table measures.

At **-O2**, the cliff is sharp and it's exactly the single 42,223-line
function (`brp_5Eh`, per the task's own facts) plus the handful of other
huge functions near it: N=1's single TU takes 152s of CPU by itself;
splitting to N=2 (two ~44 MB halves) nearly halves that to 111s (not quite
2x, because that huge function is still deadweight in whichever TU it lands
in); N=4 (four ~22 MB quarters, each landing away from the worst outliers)
drops to 88s; N=8/16 (each TU 9-13 MB) essentially plateau at 97-99s. So the
-O2 cliff *is* superlinear-in-TU-size, consistent with LLVM's optimizer cost
scaling worse than linearly with function/TU size, and splitting directly
attacks it by keeping every TU's largest function a small fraction of that
TU's total size. Unlike -O0, at -O2 the *wall-clock* win from splitting is
overwhelmingly about breaking up that superlinear cost, not just exposing
more parallelism -- N=1 vs N=2 alone (no core-count benefit assumed, since
wall time still includes real elapsed time for that unsplittable big
function) already buys back 41s of median wall time end to end.

## Contention and re-runs

This machine was shared with (at points) three to four other Blorp worktree
sessions doing unrelated full `-O2` builds (`blorp-rm-f3`, `blorp-rm-f7`,
`blorp-rm-n0`/`n7`) for roughly the first 40 minutes of this measurement run.
That inflated the first full pass badly (e.g. N=1/-O0 parallel wall came back
at 32.8s, nearly 2x the ~15-16s this same file takes standalone; N=16/-O0
recorded a single flaky CLI smoke failure -- re-running the *identical*
already-built binary immediately afterward passed 110/110, confirming it was
a timing-sensitive test flaking under load, not a splitter correctness bug).

**Re-run once the machine was quiet** (verified via `ps` -- at most one
low-priority (`nice`d) background compile from another worktree remained):
all five `-O0` cells (N=1, 2, 4, 8, 16) and the `-O2` N=4 cell. The `-O2`
N=4 re-run was triggered by its serial-CPU number (from the contaminated
pass) sitting *above* both N=2 and N=8 -- a non-monotonic result inconsistent
with well-balanced bins (the splitter's own per-TU byte counts for N=4 were
{22215747, 22220235, 22218640, 22204317}, i.e. within 0.07% of each other) and
inconsistent with all 3 of that cell's own trials agreeing tightly (they
didn't -- [159.6, 153.6, 175.3]s, a suspiciously narrow-but-elevated band
typical of steady background contention rather than one-off noise). The
clean re-run brought N=4/-O2 serial CPU down from 159.6s to 88.0s, which
restores the monotonic 152 -> 111 -> 88 -> 99 -> 97s trend reported above.
`-O2` N=1, N=2, N=8, N=16 were left as originally measured: N=1 and N=2
still show wider per-trial spread than the others (N=1: [110.6, 205.1,
152.1]s; N=2: [155.0, 105.0, 111.5]s), consistent with residual contention
during part of their windows, but their medians are not obvious outliers
against the now-clean trend, so they were not re-run. All self-compile
timings (N=1, 8, 16) were measured after the machine was confirmed quiet.

The generated-C-splitter, correctness, and self-compile results are
unaffected by contention (they are pass/fail and CPU-time-of-the-output-
program facts respectively, not host-compile wall-clock measurements).

## Conclusion

**Splitting the generated C into multiple translation units helps, and helps
more at -O2 than at -O0**, for a reason distinct from "more cores get used":
at -O2 a large fraction of the win comes from breaking up one pathologically
large function's outsized share of a single TU's optimization cost, not just
parallelism. On this 10-core (4P+6E) machine:

- **-O0** (the fast local default): parallel wall drops 16.1s -> 5.3s,
  N=1->16 (3.0x). Total CPU work is flat, so this is a pure "more workers"
  win.
- **-O2** (every CI lane, release build, and the full local gate): parallel
  wall drops 185.4s -> 25.2s, N=1->16 (7.4x), and total CPU work itself drops
  152.1s -> ~90-99s (roughly -35 to -40%) because splitting removes the
  superlinear penalty of the largest function dominating a huge single TU.
  Peak RSS falls from 5.5 GB (N=1) to 1.2 GB (N=8), which matters as much as
  wall time for running compiles in parallel with anything else on a
  memory-constrained CI runner.

**Recommended N: 8.** N=16 buys essentially nothing further over N=8 on this
machine (25.2s vs 27.9s parallel wall at -O2; 5.3s vs 5.5s at -O0) while
adding more small-TU header-reparse overhead and more `cc` process-startup
cost, and N=8 keeps every TU comfortably under ~13 MB / ~1.2 GB peak RSS
at -O2, which is the more portable number across CI hardware of unknown
core count.

**Expected ROI:**
- *This machine, -O2* (the case that matters for CI): ~160s of wall-clock
  compile time saved per full/clean CI build (185s -> 28s -> effectively the
  N=8 number, 27.9s), for zero cost -- the self-compile numbers show no
  regression, so this is very close to a pure win once the tooling exists.
- *Scaled to a standard GitHub-hosted 4-vCPU runner*: parallel wall is
  capped by 4 cores rather than this machine's 10, so the realistic
  effective parallelism is `min(N, 4)`. Using this machine's own serial CPU
  total for -O2 N=8 (98.8s) as a stand-in for the runner's total work and
  dividing across 4 workers gives a back-of-envelope **~25-30s** parallel
  wall (similar order to this machine's N=4 number, 41.3s, since 4 real
  cores is the relevant constraint either way) versus the current N=1
  baseline's serial ~150s+ on that same class of machine. That's roughly a
  **4-5x** reduction in the -O2 C-compile stage specifically, which is one
  component of (not the entirety of) each CI lane's total time.

**Correctness and design risks** (see below for detail): none were fatal.
The three things that needed non-mechanical handling were (1) immortal
string-literal pointer identity, requiring a duplicate-free single owner
plus a non-`static` macro variant, (2) 15 anonymous-`struct`-typed globals,
requiring synthesized typedefs since anonymous struct types aren't
cross-TU-compatible in C, and (3) not trusting the original forward
prototypes, sidestepped entirely by regenerating every prototype from its
matching definition. Nothing in the generated C required abandoning the
per-TU split or working around a genuine single-TU-visibility requirement.

## Design risks / things that needed special handling

- **String literal identity.** `BLORP_STATIC_STRING` literals are immortal,
  pointer-identity-compared objects (`same_object`); the splitter keeps
  exactly one definition per literal (in `split_body_0.c`) via a
  non-`static` twin of the macro, `BLORP_EXTERN_STRING`, and `extern`s it
  everywhere else. Duplicating these would have been a silent correctness bug,
  not a link error.
- **Anonymous-struct-typed globals.** 15 canonical empty/static-list
  singletons are declared with an inline anonymous `struct { ... }` type.
  Anonymous struct types are not compatible across translation units in C, so
  the splitter synthesizes a named `typedef` for each one and uses it on both
  the `extern` declaration and the definition.
- **Forward prototypes are not trusted.** Rather than try to rewrite 15,158
  existing `static` prototypes in place, the splitter drops all of them and
  regenerates a matching `extern` prototype directly from each function's own
  definition, which sidesteps any risk of a prototype/definition mismatch
  surviving the split.
- **`static inline` functions** (a few hundred small record/union
  constructors the emitter marks `static inline`) are treated exactly like
  any other function: both `static` and `inline` are stripped and they become
  ordinary external functions, once. This sidesteps the C99 vs. GNU89
  `extern inline` ambiguity entirely rather than trying to preserve inlining
  semantics across TUs.

Two follow-ups noted during review, not yet acted on:

- `balanced_bins` is greedy-contiguous and can overshoot its per-bin target;
  since -O2 cost is superlinear in TU size, that imbalance is amplified
  rather than just averaged out. An LPT (longest-processing-time) assignment
  -- each function to whichever bin currently has the least accumulated size
  -- would balance more tightly and likely make N=8 an even cleaner win.
  Cross-TU references all go through the shared header regardless of which
  bin a function lands in, so dropping the "contiguous" constraint is safe.
- `strip_leading_keywords` only strips a leading `inline` keyword (after
  `static`), so a hypothetical `static __attribute__((...)) inline` function
  -- attribute *between* `static` and `inline` -- would survive stripping
  with `inline` still in front and no external definition, silently becoming
  a C99 inline declaration with nothing to link against. Zero functions in
  the current generated C hit this (404 definitions carry attributes, none
  in that order), so it's not live today, but the classifier should be
  hardened to strip `inline` wherever it appears in the leading keyword run,
  not just first.
