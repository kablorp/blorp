# Blorp 2 performance verification after the IR migration, 2026-10-14

Question: did the IR migration (`fb94cb384`..`7ffffd8f1`) cost anything, and does the pilot compiler scale
badly anywhere? Answer: the migration is neutral (allocations -0.4%, instructions -0.3%, no fixture beyond
+-2%), but the compiler is **quadratic in instructions in almost every dimension while its allocation counts
stay linear**, and the quadratic parts are large enough to dominate a compiler-sized input today. Everything
here is a proxy for self-compile: the pilot cannot compile its own source yet, so the closest input is a
count-matched synthetic program (section 2.3). Nothing was optimised or changed; findings are the deliverable.

## Findings, ranked

1. **High: `emit` is quadratic in output size and is 63% of instructions (70% of time) on a compiler-sized input.**
   `emit` builds its result with `output = output.concat(...)` (280 `concat` calls in `emit.brp`); the samples show each one copying the accumulated string
   (`blorp_string_concat` -> `_platform_memmove`: 88% of native samples at compiler size, 79% at twice that).
   Allocations hide it: `emit` is 6% of allocations. Exponent 1.8-2.0 in every dimension that emits C.
   At the compiler's own counts: 16.3G of 25.6G instructions, 1.17 s of 1.68 s. Output is 1.04 MB there.
2. **High: name interning is quadratic in distinct names (parse: 11% of time at compiler size, 90% of instructions on a many-union input).**
   `names::find_name` scans the table with `text::equals` on every identifier, and `names::intern_name`
   copies the whole `List[String]` for each new spelling (native samples: `blorp_list_copy_with_capacity`
   under `intern_name`, and the matching `list_destroy`/`release_element` samples under `parse::consume_variants`,
   `consume_union` and `parse_module`, where the superseded copy is dropped). The compiler's own source has
   about 2.7K distinct spellings; parse is 194 ms at that count and 743 ms at twice the program. The suspected
   linear scan per identifier in `names.brp` is real, and the copy of the table per new name is a second
   quadratic term next to it.
3. **Medium (a note for today's source, the steepest slope measured): namespace, callable and body lookups scan by
   module/function identity, quadratic in modules and in functions.**
   `modules_chain`/`modules_fan_in` are exponent 1.94-1.98: about 43-50K instructions per module pair, 720G
   instructions and 33 s at 4096 modules. At the compiler's 34 modules, namespace plus callables take 17 ms (1% of the compile). Top self time: `source::same_module`/`module_number` (called 60M times
   at 256 modules), `check_methods::append_method` (from `build_callables`), `namespace::contains_type`,
   `visible_types`, `type_candidate`, `first_local_function`. It is the first term to bite beyond about 100 modules.
   Body checking shows the same identity scans (`first_local_function`, `function_number`) and is exponent 1.5-1.9,
   11% of time at compiler size.
4. **Medium: host-stack recursion per item turns size into a SIGSEGV, not a diagnostic.** Under the default 8 MB
   stack the pilot dies (exit 139) at about 1.9K unions/records, 2.3K statements or identifiers, 2.7-2.9K functions
   or match arms in one module, in the baseline and the current build alike. The frames are
   `check_bodies::check_functions` (one per function), `parse::consume_function_lines`/`consume_block_line` (one per
   statement) and `check_types::declare_types` (one per union). The compiler's own 754 functions (before the library modules' functions) leave about a 3.5x margin.
5. **Medium (regression): the migration cut the UFCS receiver-chain depth limit 8.7x, 7,888 -> 903 links under 8 MB.**
   Two steps: `fb94cb384` (concrete tree) 7,888 -> 2,149 and `cfc83f1ca` (checked tree) -> 847. The deep frames at the current head are
   `specialize::translate_expr`/`translate_exprs`/`translate_call`, so the step-1 report's "translation ... stay iterative"
   no longer describes specialization. Practical risk is low: the longest chain in `blorp_2/src` is 5, and nested
   call depth is unchanged (791 -> 847). Chains also cost +2 allocations per link (+1.2% at 4096 links, +0.55% at
   `chain_64`), the only positive outlier in the whole comparison.
6. **Note: allocation counts are linear in every dimension (exponent 0.9-1.0), so the allocation ceilings in the e2e suite
   cannot see findings 1-3.** The fixtures are dominated by a ~35M-instruction startup floor (prelude/base processing,
   6.9K allocations for `return/zero`). The instruction ceilings only constrain tiny inputs.
7. **Note: the migration is neutral.** 299 compiling fixtures: allocations median -0.26% (min -1.39%, max +0.55%), instructions
   (min of 3) median -0.26% (min -1.43%, max +0.59%); at scale 94 points lie within -2.31%..+1.20% (allocations) and -2.22%..+1.56% (instructions). Generated C is byte-identical for
   295 of 299; the four `record/update` fixtures differ as commit `7ffffd8f1` states (update initializer and ownership order).
8. **Note: the error path is not worse than the success path** (a 4096-statement program rejected at its last line: 1.14M allocations,
   10.0G instructions, against 1.52M and 18.3G for the accepted program).

## Provenance

- Baseline: `02317bf8e` (pre-migration). Current: `7ffffd8f1` (`origin/main` at start). Six commits between them.
  Worktree `../blorp2-perf`, detached at `7ffffd8f1`; host compiler `bin/blorp` built there by `make`
  (SHA-256 `064abb9e4222532dd112e67ada6aef02fb638e1acbaab498c7f62a8e6e40f031`), used for both pilots.
- Pilot binaries: `make -C blorp_2 test-compiler` for the current one; the baseline from `git archive 02317bf8e blorp_2`
  built with the same host compiler and the Makefile's flags by hand:
  `bin/blorp compile --no-format blorp_2/src/main.brp -o X.c; clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1 X.c -lm -lpthread`.
  Baseline `4a9876837fc78067e5ec58ec0ca9e01577aa9c9bab60115e2373f7dcc66cd71b`,
  current `f075989533c25519cdc2be4e3845802ec2c99d93b5a60d192cf86cb5ac534343`.
  Scratch-instrumented copy `0ff6e37b55b42340d3cecff0970a4f19754fb3e885d64b63acc3ade436893a09`
  (its C output is byte-identical to the current compiler on `return/zero`, `composite_4`, `functions_tree_256`,
  `modules_fan_in_64`). Phase-prefix binaries `pre_load`..`pre_verify` are the current sources with `compile` stopping after that phase.
  Intermediate builds for the depth bisect: `fb94cb384`, `f94df9705`, `95dcd3b80`, `a121b5425`, `cfc83f1ca`.
- Machine: Apple M4, 10 cores, 32 GB, macOS 26.7.1 (Darwin 25.6.0), Apple clang 21.0.0, arm64.
  Load average was 2.8 at the start: other workers' suites were running elsewhere. Instruction and allocation counts do
  not depend on load; wall-clock figures do and are labelled noisy.
- Generators and raw samples (not committed, ignored): `blorp_2/build/perf/` in the worktree (`scripts/gen.py`
  `856166e5eed7d7f9d0b9b0fe5201964987770503ad25275ff419c8b4a0774f53`, `q1.tsv`, `q2_base.tsv`, `q2_cand.tsv`, `q3_*.tsv`,
  `q3i.tsv`, `prof/`, `sample/`). Source of the hot functions: `names.brp` `0cc8f977...`, `emit.brp` `0960819c...`, `text.brp` `866aaa83...`.

- Commands (all from the worktree root, outputs under `blorp_2/build/perf/`): `python3 -I scripts/gen.py q2` (inputs),
  `scripts/q1.py` (fixtures, base vs current), `scripts/q2.py base|cand` (scaling), `scripts/q3.py N dim...` (probe phases),
  `scripts/q3i.py input...` (phase-prefix instructions), `scripts/threshold.py` (stack bisect), `bin/blorp run --no-format
  --profile-mode exact blorp_2/src/main.brp -- --library-root blorp_2/standard_library_temp INPUT OUT.c` and `sample PID 30 1 -file F`.

## Method

All runs were serial; no compiled binary ran in parallel with another. Flags are `-O0` with
`-DBLORP_MEMORY_DIAGNOSTICS=1`, as in the e2e harness, so costs are those of the test compiler, not of an optimised build.

- **Allocations**: `BLORP_LEAK_CHECK=strict`, the managed-object count reported on stderr (identical across the three samples for every Section 1 fixture; Section 2 and 3 record the first sample).
- **Instructions**: macOS `/usr/bin/time -l` "instructions retired". Section 1 uses the strict run (includes leak bookkeeping, like the
  e2e harness; minimum of 3). Sections 2 and 3 use a separate run **without** leak checking (minimum of 3, one sample above
  3 s), so the bookkeeping cannot create or hide a growth term. Within-side instruction noise on tiny fixtures is up to 5.8%
  (median 0.28%), so only deltas above that are claimed.
- **Order**: Section 1 alternates base, current, three times per fixture. Section 2 ran all of the current build, then all of the baseline.
- **Stack**: Section 2 and 3 inputs ran under `ulimit -s 65520` (64 MB) so that deep-recursion sizes complete; finding 4/5 thresholds
  were measured at the default 8,176 KB by bisection (resolution 8).
- **Per-phase**: a scratch copy of `blorp_2/src` (never production) with a `probe.brp` reading `read_memory_counter(ManagedAllocations)`
  and `now_microseconds()` around each phase, printed to stderr under `BLORP_MEMORY_STATS=1`; plus cumulative phase-prefix binaries for
  instructions. Lex/parse/assemble are interleaved per module inside `load_program`, so they have allocation and time but not their own instructions.
- **Hot spots**: the host profiler (`bin/blorp run --profile-mode exact`, self time, instrumentation overhead, so a ranking not a cost) and
  native `sample` on the unmodified test compiler (1 ms interval). `brp_` symbols are named through the profiler's C-symbol column; the
  two builds agree on every symbol used (`brp_Fw` = `text::concat`, `brp_py` = `names::find_name`, `brp_pz` = `names::intern_name`).

## 1. Did the migration cost anything?

334 fixtures under `blorp_2/test/e2e/fixtures`: 299 compile in both builds, 35 are rejected with identical exit status and messages.
Generated C is identical for 295; the 4 `record/update` fixtures (`aliases`, `escaped_children`, `managed_reorder`, `order`) differ.
For three the only difference is the order of designated initializer fields; for `managed_reorder` the ownership statements
move with it. Both match the commit message of `7ffffd8f1`.

| statistic over 299 fixtures | allocations | instructions (min of 3) |
| --- | ---: | ---: |
| minimum | -1.39% | -1.43% |
| 10th percentile | -0.51% | -0.47% |
| median | -0.26% | -0.26% |
| 90th percentile | -0.10% | -0.09% |
| maximum | +0.55% | +0.59% |
| sum over all fixtures | 3,389,562 -> 3,375,866 (-0.40%) | 15.003G -> 14.953G (-0.33%) |

No fixture is beyond +-2% by allocations or by minimum-of-three instructions. Only `ufcs/chain_64` has more allocations
(18,409 -> 18,511); 8 fixtures have a higher minimum instruction count, all below +0.6%. By median-of-three, `ufcs/chain` reads +2.34%,
but its minimums are -0.13% (one outlier sample of 42.8M against 41.1M-41.2M): noise. The largest fixtures
(`match/many_arms` 85K allocations, 313M instructions; `calculator/float_stress` 61K / 176M) move -0.9% to -1.4%.

The same comparison at scale (section 2) covers 94 points: allocations -2.31% to +1.20%, instructions -2.22% to +1.56%. The ten points
beyond +-2% are all decreases (`statements_*`, `names_same` and the four `composite` sizes); the only increases above +0.3% are `call_chain`
(+0.55% at 64 links, +0.97% at 256, +1.14% at 1024, +1.20% at 4096 links in allocations; +0.5% to +1.6% in instructions).

## 2. Is anything superlinear?

Programs from `scripts/gen.py`, 5 sizes per dimension (16, 64, 256, 1024, 4096), all compiling with exit 0. Exponent is
log base 4 of the growth over a 4x size step; 1.0 is linear and 2.0 is quadratic. Instruction counts include a ~35M startup
floor, so exponents between small sizes understate the slope; the 1024 -> 4096 column is the one to read.
Dimensions: `functions_tree` (N functions called from one another in a binary tree, all reachable), `functions_unreachable`
(N checked, one reached), `modules_chain` (each module imports the next), `modules_fan_in` (N leaves import one shared module and
`main` imports all leaves, using one), `modules_fan_in_used` (as that, `main` calling every leaf), `unions_declared` (N unions of 4
variants), `records_declared`, `union_variants` (one union of N nullary variants), `record_fields` (one record of N fields),
`call_chain` (`1.step().step()...`), `nested_calls` (`step(step(...))`), `match_arms` (one match of N arms; N variants are forced by
exhaustiveness), `match_chain` (N functions each ending in a two-arm match that calls the next), `statements_distinct` (N bindings
reading the previous), `statements_one_var` (N reassignments of one `var`), and `names_distinct`/`names_same`/`names_long` (N
independent bindings with N distinct 17-byte names, with one name, and with N distinct 64-byte names). Nested matches are
unsupported by the pilot (README), so match depth is measured as dispatch depth through calls.

### 2.1 Allocations (current build)

| dimension | N=16 | N=64 | N=256 | N=1024 | N=4096 | exp 256-1024 | exp 1024-4096 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| functions_tree | 19,033 | 55,199 | 200,053 | 779,195 | 3,099,553 | 0.98 | 1.00 |
| functions_unreachable | 13,457 | 30,985 | 101,391 | 383,309 | 1,516,891 | 0.96 | 0.99 |
| modules_chain | 18,918 | 53,023 | 189,373 | 734,683 | 2,915,833 | 0.98 | 0.99 |
| modules_fan_in | 17,106 | 45,120 | 157,090 | 604,868 | 2,395,878 | 0.97 | 0.99 |
| modules_fan_in_used | 24,146 | 74,410 | 275,614 | 1,080,586 | 4,306,246 | 0.99 | 1.00 |
| unions_declared | 9,470 | 17,115 | 47,657 | 169,783 | 658,245 | 0.92 | 0.98 |
| records_declared | 9,372 | 16,727 | 46,115 | 163,631 | 633,659 | 0.91 | 0.98 |
| union_variants | 8,003 | 9,024 | 13,070 | 29,212 | 93,738 | 0.58 | 0.84 |
| record_fields | 10,198 | 18,308 | 50,922 | 181,576 | 710,006 | 0.92 | 0.98 |
| call_chain | 10,518 | 18,514 | 50,414 | 177,930 | 687,910 | 0.91 | 0.98 |
| nested_calls | 10,604 | 18,879 | 51,923 | 184,039 | 712,443 | 0.91 | 0.98 |
| match_arms | 12,468 | 26,884 | 84,836 | 318,084 | 1,257,124 | 0.95 | 0.99 |
| match_chain | 21,880 | 66,389 | 244,393 | 956,349 | 3,804,113 | 0.98 | 1.00 |
| statements_distinct | 12,884 | 30,616 | 101,484 | 384,896 | 1,518,484 | 0.96 | 0.99 |
| statements_one_var | 12,915 | 30,741 | 101,991 | 386,937 | 1,526,667 | 0.96 | 0.99 |
| names_distinct | 8,579 | 13,687 | 34,371 | 117,383 | 455,323 | 0.89 | 0.98 |
| names_same | 8,550 | 13,560 | 33,858 | 115,332 | 447,126 | 0.88 | 0.98 |
| names_long | 8,579 | 13,687 | 34,371 | 117,383 | 455,323 | 0.89 | 0.98 |

### 2.2 Retired instructions (current build, no leak checking)

| dimension | N=16 | N=64 | N=256 | N=1024 | N=4096 | exp 256-1024 | exp 1024-4096 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| functions_tree | 48M | 103M | 424M | 3,308M | 39,994M | 1.48 | 1.80 |
| functions_unreachable | 41M | 66M | 186M | 998M | 9,257M | 1.21 | 1.61 |
| modules_chain | 68M | 306M | 3,185M | 46,622M | 720,646M | 1.94 | 1.98 |
| modules_fan_in | 70M | 327M | 3,526M | 52,078M | 808,144M | 1.94 | 1.98 |
| modules_fan_in_used | 80M | 381M | 3,944M | 57,021M | 880,490M | 1.93 | 1.97 |
| unions_declared | 39M | 69M | 324M | 3,898M | 53,942M | 1.80 | 1.90 |
| records_declared | 36M | 51M | 137M | 939M | 11,163M | 1.39 | 1.79 |
| union_variants | 34M | 38M | 60M | 280M | 3,070M | 1.11 | 1.73 |
| record_fields | 37M | 50M | 131M | 924M | 11,053M | 1.41 | 1.79 |
| call_chain | 37M | 48M | 96M | 376M | 2,877M | 0.99 | 1.47 |
| nested_calls | 37M | 48M | 95M | 377M | 2,878M | 0.99 | 1.47 |
| match_arms | 40M | 65M | 231M | 2,072M | 26,800M | 1.58 | 1.85 |
| match_chain | 52M | 122M | 563M | 4,889M | 62,218M | 1.56 | 1.83 |
| statements_distinct | 40M | 67M | 215M | 1,566M | 18,284M | 1.43 | 1.77 |
| statements_one_var | 40M | 64M | 186M | 1,109M | 11,612M | 1.29 | 1.69 |
| names_distinct | 35M | 45M | 108M | 826M | 10,018M | 1.47 | 1.80 |
| names_same | 34M | 41M | 77M | 333M | 3,147M | 1.05 | 1.62 |
| names_long | 35M | 51M | 192M | 2,008M | 29,078M | 1.69 | 1.93 |

Reading the two tables together: allocations are linear everywhere, while instructions are quadratic for modules (1.94-1.98),
unions (1.90), match arms (1.85), names (1.80-1.93), match chains (1.83), and near-quadratic for functions (1.61-1.80), statements
(1.69-1.77), records (1.79) and union variants (1.73), still rising as the startup floor stops mattering. Even `call_chain` and `nested_calls`
(1.47) are above linear at 4096. `names_same` (one name, N statements, 1.62) against `names_distinct` (N names, 1.80) and
`names_long` (1.93) shows that distinct-name count and spelling length add a term of their own on top of the general one;
`union_variants` (4096 variant names in one union, no other work) is still 11x per 4x.

Rough per-phase attribution of the exponents (details in section 3, from the probe at 256 -> 1024 -> 4096, only phases above 5 ms):

| term | phase | where it grows | evidence |
| --- | --- | --- | --- |
| output copying | emit | every dimension that emits C: exponent 1.8-2.0 (`functions_tree` 1.96, `match_chain` 1.98, `match_arms` 1.89) | `text::concat` + memmove |
| name table | parse | distinct names: `unions_declared` 1.93, `names_long` 1.95, `names_distinct` 1.80, `union_variants` 1.83; flat for `names_same` 0.95 and `call_chain` 0.88 | `find_name`, `intern_name` |
| module/function identity scans | namespace, check callables, check bodies | modules 1.96-1.99; functions 1.87-1.96 (namespace, callables); bodies 1.5-1.9 | `same_module`, `append_method`, `contains_type`, `first_local_function` |
| per-statement state | specialize, check recursion | `statements_*` 1.92-2.03, `names_*` 1.94-1.96 | small in absolute terms (under 0.2 s at 4096) |
| `lower` over deep expressions | lower | `call_chain`/`nested_calls` 1.97-1.99 | 44 ms at 4096 |

### 2.3 Baseline against current, and a compiler-sized proxy

Across all 94 points (`scripts/q2.py base` and `cand`), the current build is within -2.3% to +1.6% of the baseline, and the
difference does not grow with N except for `call_chain` (about +2 allocations per link). The migration neither added nor removed a scaling term.

Because the pilot cannot compile its own source, `composite` is a count-matched proxy: at scale 4/4 it has 34 modules, 748
functions of 14 statements (plus 34 helpers), 136 unions, 238 records, a tail match in every fourth function, 51.7K
identifier tokens (the compiler: 53.4K), 2,740 distinct spellings (2,692, an upper bound that includes keywords), 13.6K lines (21.9K).
It is not the compiler: no real name reuse, no deep expressions, no strings. Sizes 1/4, 2/4, 4/4 and 8/4 of those counts:

| scale (x1/4 of compiler) | modules | allocations (base / current) | instructions (base / current) | delta alloc | delta instr | wall s (current, noisy) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1/4 | 8 | 999,430 / 976,528 | 2,498M / 2,459M | -2.29% | -1.56% | 0.16 |
| 2/4 | 17 | 2,115,118 / 2,066,467 | 7,811M / 7,727M | -2.30% | -1.08% | 0.51 |
| 4/4 | 34 | 4,222,511 / 4,125,223 | 25,808M / 25,637M | -2.30% | -0.66% | 1.73 |
| 8/4 | 68 | 8,437,275 / 8,242,713 | 93,507M / 93,196M | -2.31% | -0.33% | 6.66 |

instruction growth per doubling (1/4->1/2, 1/2->1, 1->2): x3.14, x3.32, x3.64 ; allocations: x2.12, x2.00, x2.00

At compiler size the pilot takes about 25.6G instructions and 1.7 s, and doubling the program multiplies the cost by 3.1, 3.3, 3.6
(approaching 4) while allocations double (x2.00-2.12). Output is 1.04 MB.

## 3. Where does the time go per phase?

Largest synthetic input: `composite` at 8/4 (68 modules, 8.2M allocations, 93G instructions), and 4/4 (compiler-sized).

Fine phases, `composite` 4/4, from the probe build (time is `now_microseconds`, noisy and slightly perturbed by counters):

| phase | ms (probe) | % of probed time | allocations | % of allocations |
| --- | ---: | ---: | ---: | ---: |
| lex | 26 | 1.6% | 318,705 | 7.7% |
| parse | 194 | 11.5% | 562,931 | 13.6% |
| assemble (import resolution, append, seal, cycle check) | 4 | 0.2% | 2,992 | 0.1% |
| load: reads and queue bookkeeping | 11 | 0.7% | 1,487 | 0.0% |
| namespace (build_namespace) | 10 | 0.6% | 4,293 | 0.1% |
| check: declarations and signatures | 6 | 0.3% | 19,565 | 0.5% |
| check: callables | 7 | 0.4% | 4,543 | 0.1% |
| check: bodies | 181 | 10.8% | 1,994,661 | 48.3% |
| check: recursion validation | 2 | 0.1% | 10,833 | 0.3% |
| specialize | 28 | 1.7% | 330,283 | 8.0% |
| lower | 13 | 0.8% | 272,990 | 6.6% |
| own | 11 | 0.7% | 186,888 | 4.5% |
| verify | 12 | 0.7% | 154,131 | 3.7% |
| emit | 1,170 | 69.8% | 262,058 | 6.4% |
| total probed | 1,677 | | 4,126,417 | |

Same table at 8/4:

| phase | ms (probe) | % of probed time | allocations | % of allocations |
| --- | ---: | ---: | ---: | ---: |
| lex | 53 | 0.8% | 635,415 | 7.7% |
| parse | 743 | 11.7% | 1,123,489 | 13.6% |
| assemble (import resolution, append, seal, cycle check) | 11 | 0.2% | 5,749 | 0.1% |
| load: reads and queue bookkeeping | 23 | 0.4% | 2,643 | 0.0% |
| namespace (build_namespace) | 39 | 0.6% | 8,180 | 0.1% |
| check: declarations and signatures | 19 | 0.3% | 38,097 | 0.5% |
| check: callables | 28 | 0.4% | 8,895 | 0.1% |
| check: bodies | 480 | 7.5% | 3,988,490 | 48.4% |
| check: recursion validation | 4 | 0.1% | 21,645 | 0.3% |
| specialize | 64 | 1.0% | 660,458 | 8.0% |
| lower | 26 | 0.4% | 545,909 | 6.6% |
| own | 23 | 0.4% | 373,685 | 4.5% |
| verify | 24 | 0.4% | 308,186 | 3.7% |
| emit | 4,837 | 75.9% | 523,961 | 6.4% |
| total probed | 6,376 | | 8,244,859 | |

Instructions need cumulative phase-prefix binaries, so they exist only at phase-group granularity. The five largest single-dimension
inputs are included to show which dimension moves which phase:

| phase | composite_4: allocations / instructions | composite_8: allocations / instructions | functions_tree_4096: allocations / instructions | unions_declared_4096: allocations / instructions | names_long_4096: allocations / instructions | modules_chain_1024: allocations / instructions | match_chain_4096: allocations / instructions |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| load (lex, parse, assemble) | 884,977 (21%) / 4,347M (17%) | 1,765,206 (21%) / 16,041M (17%) | 680,389 (22%) / 4,952M (12%) | 537,005 (82%) / 48,826M (91%) | 157,932 (35%) / 24,014M (83%) | 240,119 (33%) / 4,188M (9%) | 840,177 (22%) / 6,630M (11%) |
| check (incl. namespace) | 2,033,896 (49%) / 3,825M (15%) | 4,065,308 (49%) / 10,391M (11%) | 1,310,833 (42%) / 7,488M (19%) | 121,098 (18%) / 5,113M (9%) | 133,345 (29%) / 3,157M (11%) | 304,606 (41%) / 41,487M (89%) | 1,206,550 (32%) / 5,278M (8%) |
| specialize | 330,283 (8%) / 529M (2%) | 660,458 (8%) / 1,209M (1%) | 251,992 (8%) / 1,833M (5%) | 35 (0%) / -2M (-0%) | 41,017 (9%) / 854M (3%) | 46,189 (6%) / 174M (0%) | 471,093 (12%) / 2,453M (4%) |
| lower | 272,990 (7%) / 259M (1%) | 545,909 (7%) / 524M (1%) | 157,745 (5%) / 162M (0%) | 16 (0%) / 0M (0%) | 36,903 (8%) / 31M (0%) | 26,696 (4%) / 43M (0%) | 237,595 (6%) / 236M (0%) |
| own | 186,888 (5%) / 215M (1%) | 373,685 (5%) / 432M (0%) | 213,057 (7%) / 245M (1%) | 25 (0%) / -6M (-0%) | 24,615 (5%) / 32M (0%) | 34,915 (5%) / 25M (0%) | 299,044 (8%) / 341M (1%) |
| verify | 154,131 (4%) / 193M (1%) | 308,186 (4%) / 396M (0%) | 147,504 (5%) / 192M (0%) | 16 (0%) / 21M (0%) | 8,216 (2%) / 15M (0%) | 23,626 (3%) / 30M (0%) | 253,971 (7%) / 311M (1%) |
| emit | 262,058 (6%) / 16,271M (63%) | 523,961 (6%) / 64,190M (69%) | 338,033 (11%) / 25,128M (63%) | 50 (0%) / -18M (-0%) | 53,295 (12%) / 972M (3%) | 58,532 (8%) / 774M (2%) | 495,683 (13%) / 46,952M (75%) |
| total | 4,125,223 / 25,639M | 8,242,713 / 93,183M | 3,099,553 / 40,000M | 658,245 / 53,935M | 455,323 / 29,075M | 734,683 / 46,720M | 3,804,113 / 62,201M |

(`unions_declared_4096` shows negative tiny phases: differences of consecutive binaries are accurate to about +-20M instructions.)

Reading: emit is 63-69% of instructions at compiler size and 63-76% on function-heavy inputs; load (parse) takes 83-91% on name-heavy
inputs; check takes 89% on module-heavy inputs. Only emit is invisible to the allocation counter (6% of allocations, 63-69% of instructions).
Lex is linear per input size (exponent 0.9-1.0), except across thousands of tiny modules (1.6, not investigated). Specialize, lower, own and verify are each 1-2% of instructions at compiler size and linear except where
noted in section 2.2.

## 4. Hot spots

Two worst-scaling dimensions (largest exponent with largest absolute cost): **modules** (`modules_chain`, exponent 1.98) and **distinct names**
(`unions_declared`, 1.93 in parse). Emit is added because it dominates the compiler-sized proxy. Host profiler (exact mode) self time, one run each:

`modules_chain_256` (8.9 s instrumented):

| rank | function | self % | calls | avg self us |
| --- | --- | ---: | ---: | ---: |
| 1 | `source::same_module` | 46.9% | 30,384,549 | 0.075 |
| 2 | `source::module_number` | 27.1% | 60,778,815 | 0.022 |
| 3 | `check_methods::append_method` | 8.2% | 4,902 | 81.356 |
| 4 | `namespace::same_type_name` | 6.6% | 6,564,844 | 0.049 |
| 5 | `namespace::contains_type` | 3.8% | 6,235 | 29.239 |

Native `sample` of the test compiler, `modules_chain_1024` (1,690 samples): `module_number` 26.1%, `blorp_cooperative_checkpoint` 17.7%,
`_tlv_get_addr` 12.1%, `same_module` 9.9%, `append_method` 9.6%, `contains_type` 7.5%. (The checkpoint and TLS lookups are the runtime's per-call overhead on 60M calls.) Nearest named callers of the
`module_number` samples: `append_method` <- `build_callables` <- `check_program` 50%; `same_type_name` <- `contains_type` <- `with_type` 20%;
`visible_types` <- `implicit_types` <- `build_namespace` 15%.

`unions_declared_1024` (6.0 s instrumented):

| rank | function | self % | calls | avg self us |
| --- | --- | ---: | ---: | ---: |
| 1 | `text::equals` | 30.5% | 14,020,282 | 0.042 |
| 2 | `names::find_name` | 19.5% | 7,366 | 51.207 |
| 3 | `string::starts_with` | 12.6% | 10,516,288 | 0.023 |
| 4 | `source::same_module` | 11.7% | 3,038,826 | 0.074 |
| 5 | `source::module_number` | 6.8% | 6,099,898 | 0.022 |

Native `sample`, `unions_declared_4096` (2,076 samples): `blorp_release_element_with` 20.6%, `blorp_list_copy_with_capacity` 17.5%,
`blorp_cooperative_checkpoint` 12.5%, `string::starts_with` 11.6% (inside `text::equals`), `_tlv_get_addr` 9.2%, `text::equals` 7.9%,
`blorp_list_destroy` 7.5%, `names::find_name` 5.3%. The 381 list-copy samples sit under `names::intern_name` (`brp_pz`), which copies the name table to add one
spelling; the destroy and release samples (602 and 416) sit under `parse::consume_variants`, `consume_union` and `parse_module`,
the frames that drop the superseded copy (type-destructor frames hide the exact owner, so this is the nearest named function, not proof of ownership).

`composite` 4/4 (compiler-sized proxy), host profiler:

| rank | function | self % | calls | avg self us |
| --- | --- | ---: | ---: | ---: |
| 1 | `text::concat` | 19.7% | 288,599 | 3.917 |
| 2 | `source::same_module` | 17.6% | 13,650,769 | 0.074 |
| 3 | `text::equals` | 14.0% | 29,274,260 | 0.027 |
| 4 | `names::find_name` | 13.9% | 49,364 | 16.234 |
| 5 | `source::module_number` | 10.3% | 27,421,716 | 0.022 |

Native `sample` of the same input (1,238 samples): `_platform_memmove` 88.4%; everything else is under 1.5%. Its callers are
`text::concat` <- `emit::append_operation`/`append_value`/`append_regular_value`/`append_owned_definition`. At 8/4 (4,007 samples) memmove is 78.8%,
`text::equals` 2.4%, `module_number` 1.6%, `find_name` 1.5%. `text::concat` self time is 1.13 s over 289K calls (3.9 us average) in the instrumented run.
`functions_tree_1024` and `match_chain_1024` show `text::concat` fourth (10.7% self time) and first (20.8%).

## Not measured

- Self-compilation. The composite is a proxy built from counts; real name reuse, long expressions, string literals, lists, records of
  records and generics (specialization instances) are absent or sparse. Treat absolute times as indications only.
- Optimised builds (`-O2`/`--release` of the pilot or of the generated C), the host compiler's own cost, and the time to compile or run the emitted C.
- Wall-clock quality. The machine was not quiet; times in tables come from single runs and are used for shares, not claims.
- Peak memory in any rigorous sense: `maximum resident set size` was recorded in `q2_*.tsv` (for example 654 MB at 4096 chained modules,
  390 MB at 4096 match arms) but is not analysed.
- Nested matches (unsupported), generic-heavy programs, tail-recursive loops, string-heavy and list-heavy programs, deep records
  of records, multiple definitions of one name across modules (name resolution conflicts) and import diamonds beyond the fan-in.
- Distinguishing `lex`, `parse` and `assemble` by instructions (interleaved per module; only time and allocations).
- Root cause of the emit copying beyond the call graph: the host `String` add semantics were not read, so "each concat copies" is
  inferred from the `blorp_string_concat` -> `memmove` call graph, not from the runtime source.
- Stack thresholds are bisected to a resolution of 8 items on one machine, one stack size (8,176 KB) and 64 MB.
