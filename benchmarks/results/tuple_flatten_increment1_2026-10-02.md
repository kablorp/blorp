# Tuple flattening, increment 1 (2026-10-02)

Increment 1 of [`docs/VALUE_TUPLES_AND_STATE_HANDOFF.md`](../../docs/VALUE_TUPLES_AND_STATE_HANDOFF.md):
`tuple_flatten.brp` makes match subjects and taken-apart local tuples groups of
element locals. Baseline: the stage-2 compiler of `cfc041f43`. Candidate: the
stage-2 compiler of `13873d6e1`, which is `cfc041f43` plus this change and
nothing else in compiler or standard library source (later merges of `main`
are not measured here). Both built at `-O2` from the Makefile's recipes;
Apple clang 21, Apple Silicon.

## Self-compile

Input: the frozen tree of `cfc041f43` (`self_compile_measure freeze`), compiled
with `compile --no-format --no-embed-runtime`. Allocations from the diagnostic
links (`BLORP_MEMORY_STATS=1`), tuples from a link against a runtime whose
`blorp_tuple_new` counts calls (appendix B of the design), instructions, peak
RSS and wall time from `/usr/bin/time -l` on the normal links, medians of five
interleaved runs, never two binaries at once. Each compiler's links emit
identical C.

| | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Tuples allocated | 3,446,082 | 2,336,386 | −1,109,696 (−32.2%) |
| of which pairs | 2,833,475 | 2,076,915 | −756,560 |
| of which triples | 612,604 | 259,471 | −353,133 |
| Allocations | 211,823,963 | 210,457,849 | −1,366,114 (−0.64%) |
| Instructions (median) | 203.60 G | 203.16 G | −0.44 G (−0.21%) |
| Peak RSS (median) | 2.152 GB | 2.151 GB | unchanged |
| Wall (median) | 37.8 s | 38.0 s | within noise (shared, loaded host) |

Earlier candidates of this branch measured −0.76 and −0.81 G instructions;
the final one keeps the box of a local whose whole value a match binds, and
does one more walk per function with a tuple local, which accounts for part
of the difference. Run-to-run spread of one compiler's instructions on this
host is about 0.5 G, so −0.44 G is a single interleaved run's median, not a
precise figure; the tuple and allocation counts are exact.

Re-boxing count: 0. The pass never flattens a value that came out of a box
(a source keeps its box), and the only box it builds is a whole-subject
binding used whole, built from the subject's own elements on that path only.
A leaf binder naming a matched local's whole value counts as a whole use of
the local, so the local keeps the box it was built into rather than having
one rebuilt per pass of a loop. The allocation fixture pins each shape:
`whole_binding_in_loop`, a list element put into a list, an `Option` payload
stored, and a list element passed to a generic `T = (Int, Int)` parameter
allocate nothing per call.

### Against the estimate

The design estimated about −1.5 M tuples and −0.86 G instructions, from the
census's match subjects (1.05 M) and arm-built locals (0.45 M). Measured:
−1.11 M tuples. The census's match-subject sites (`core_mono_type_equal`,
`collect_call_substitution`, `call_single_direct_consume`, `core_type_equal`)
no longer allocate a tuple. The arm-built locals still do: `(a, b) = match ...`
whose arms build a tuple with a managed element (0.43 M of the 0.45 M is
`module_view.bound_import_request_local_name`) needs the multi-value binding
`UnpackLetExpr` of the design's section 3.3, which section 9 places in
increment 2.

A first candidate retired 4.3 G more instructions, not fewer: its driver
threaded the growing declaration list through a tuple per function, copying
it each time, and its use walk concatenated a list per assignment. Sampling
attributed the extra list copies to `run_tuple_flatten_pass`; the measured
candidate has the fix.

### A compiler bug met on the way

Storing a match payload binding of a borrowed value inside a loop
over-releases it, with the baseline compiler too (ASan heap-use-after-free;
repro: `match node: Dummy(source): for _ in 0..2: edges = edges.append({source = source})`
on a borrowed `node`). The pass's own use walk hit it; the walk now stores
the subject once per match instead of once per binder. Not fixed here.

## Probe

`benchmarks/ownership_shapes/value_tuple_probe.brp`, 100,000 calls, `-O2`,
compiled by each stage-2 compiler. Allocations exact; instructions per call
net of the `empty` mode, median of three.

| Mode | Allocations before | after | Instructions per call before | after |
| --- | ---: | ---: | ---: | ---: |
| `subject_or` (`match (left, right):` with or-patterns) | 100,003 | 3 | 705 | 72 |
| `subject_control` (the same tests as nested matches) | 3 | 3 | 87 | 88 |
| `pair_inline`, `pair_call`, `record_pair` | 0 / 100,000 / 200,001 | unchanged | | |

The split subject is as cheap as its hand-written control. The tuple-return
shapes are unchanged, as increment 1 does not change signatures.

## Contract shifts

Inferred ownership contracts of the self-compile's functions, printed after
the ownership-contracts pass by compilers built from `cfc041f43` and
`13873d6e1` with the same print-only patch (not committed): 17,835 functions
each. 94
functions move 155 parameters from owned to borrowed, and none move the other
way: each is a parameter that only a match subject or a flattened local tuple
took over. The list is in
[`tuple_flatten_contract_shifts_2026-10-02.tsv`](tuple_flatten_contract_shifts_2026-10-02.tsv);
most are equality and comparison helpers written as `match (left, right):`.
Their cost is not measured one by one: a shift removes the retain a caller
made to hand the argument over and the release in the callee, about 16
instructions per call (section 2.4), and their total effect is inside the
self-compile numbers above. The Core suite pins the
rule on a small program: a parameter placed in a returned tuple keeps its
owned contract, and one placed in a match subject becomes borrowed.

## Fixpoint

`BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-fixpoint` at `261f1766d`
(this change merged with `main`): stages 1, 2 and 3 emit identical C
(`7179e64b08b4a3c723cd8b97713359f465deb425a7912d6fd93a91c1ad2a260b`).

## Prior `origin/main` refresh against `deb198af8` (2026-10-02)

This is a separate stage-2 comparison after merging `origin/main` at
`deb198af83a62` into the candidate at `c012919f35f`. Both compilers were
built from clean checkouts at `-O2` with bootstrap `dev-0322140767b0` and
Apple clang 21.0.0 on Apple Silicon. Both compiled the same frozen
`deb198af83a62` source and standard-library input. The five normal-binary
instruction samples for each revision ran serially; allocation counts came
from the paired diagnostic binaries. The harness verified normal/diagnostic
generated-C identity within each revision.

| Self-compile metric | Baseline `deb198af83a62` | Candidate `c012919f35f` | Change |
| --- | ---: | ---: | ---: |
| Total allocations | 215,010,542 | 213,645,604 | −1,364,938 (−0.63%) |
| Instructions retired, minimum | 204,578,198,210 | 203,830,818,449 | −747,379,761 (−0.37%) |
| Instructions retired, median | 204,631,122,930 | 203,876,898,519 | −754,224,411 (−0.37%) |
| Emitted C bytes | 80,218,376 | 79,792,776 | −425,600 (−0.53%) |

The emitted-C SHA-256 hashes are
`0163da5b65ec3656b0cdce4a17a8f85568883577f6a4f6fb56194b39e48986db`
for the baseline and
`e204a87263f300b508c4c8a37bef890ce22201bd26f9c8562740adfff17e5fef`
for the candidate. Different C across revisions is expected from this Core
rewrite. A small-program stage-2 guard emitted identical C across revisions
(SHA-256 `3f4e7cf0fbabc5459ba7802a4fc5cb69a20d0699e4c19991f19dcf374cce4abe`),
with 1,505,418 to 1,496,533 allocations and 1,465,074,999 to 1,462,098,357
minimum retired instructions. The small candidate run recorded a transient
dirty worktree because the runtime gate had reformatted one fixture signature;
that formatting-only change was restored after the run. The full self-compile
pair recorded clean compilers and worktrees.

Validation on that base passed: the focused tuple-flatten and early-Core
suites; `scripts/compiler-check --changed --base origin/main` (3,864/3,864,
including Core sanitizer, generated-C audit and leak); `scripts/test
--no-build --serial compiler-blorp runtime` (6,316/6,316 compiler and
4,661/4,661 runtime); and `make hygiene-check`. At `-O2`, the candidate
fixpoint's stages 1, 2 and 3 emitted byte-identical C with SHA-256
`e45d5fa2ff7d3c7b518f2fddb083e6e0b867a933bc147a069f1dd9bc538aa487`.
The tuple-specific allocation census and re-boxing count in the earlier
sections belong to the historical `cfc041f43` to `13873d6e1` comparison;
neither was remeasured for this current-`origin/main` pair.

## Integration-base refresh against `be99917ce`

The final compiler-source comparison used clean stage-2 compilers from
`be99917ce9f` and `b630b628854`, each built at `-O2` with Apple clang 21.0.0
and bootstrap `dev-0322140767b0`. Both compiled the same frozen
`be99917ce9f` source and standard-library input. Each measurement ran five
serial instruction samples and verified normal/diagnostic generated-C
identity within its revision. Raw JSON, C, and logs are retained under
`/tmp/blorp-tuple-increment1-be99917-20261002/`.

| Self-compile metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Total allocations | 215,081,904 | 213,718,236 | −1,363,668 (−0.63%) |
| Instructions retired, minimum | 204,120,167,812 | 203,895,737,567 | −224,430,245 (−0.11%) |
| Instructions retired, median | 204,292,114,762 | 204,097,468,998 | −194,645,764 (−0.10%) |
| Emitted C bytes | 80,178,764 | 79,754,507 | −424,257 (−0.53%) |

The instruction difference is small relative to the observed sample spread;
the repeatable result is the allocation reduction, not a confident latency
improvement. Baseline C SHA-256 was
`ad8075c562afe599684a8ec617fe08d18758c4744a8f99b3620735fd48fb7100`;
candidate C SHA-256 was
`541e17156280089a56339421824722528c5a2e1805957b4fafefabd4651920a2`.
Cross-revision C difference is expected from this Core optimization.

On this integration base, focused Core tests passed 66/66; selected compiler
checks passed 3,864/3,864, including Core sanitizer, generated-C audit and
leak; compiler-blorp passed 6,316/6,316; runtime passed 4,661/4,661; and
`make hygiene-check` passed. The `-O2` stage-1/2/3 fixpoint emitted identical
C with SHA-256
`0e5738bab4a2c3f45663cffeced73f904e7c9ab0f1f82a6746c245a1f59f3b85`.
The later `9715fed0` main commit changed documentation only, so it does not
alter this compiler-source comparison. Tuple-specific counts and re-boxing
were not remeasured on this base.
