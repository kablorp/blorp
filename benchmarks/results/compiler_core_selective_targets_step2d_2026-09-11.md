# Core Selective Target Step 2d Results — 2026-09-11

## Revisions And Host

- Baseline: `0f68273a` (`Normalize selective definition import targets`)
- Candidate: uncommitted Step 2d worktree
- Baseline compiler SHA-256:
  `aa70b80fe7d9ba2cb0e9186cc2dc0fb8c684d55015641e08d0bff49dbeb59d5d`
- Candidate compiler SHA-256:
  `2909313053f2683fec2fea94eb5d1d607fb9ff615e2b296e587049263fac4d98`
- Platform: macOS, `/usr/bin/time -lp`
- Sampling: one retained baseline/candidate pair per workload; no wall-time
  claim

## Workloads

The Core call-resolution profile constructs 556 declarations, 128 import
bindings, 32 module import scopes, deliberate duplicate identities, builtins,
foreign functions, globals, and constructors. Step 2d changes half of the
synthetic selective bindings to exact definition-ID bindings while keeping the
total binding count unchanged. Its deterministic counters isolate environment
construction and make path-retention changes directly observable.

The production screen compiles the existing 32-name selective-import graph
fixture through backend emission. This guards whole-process instructions,
cycles, RSS, peak footprint, compiler size, and generated output.

## Commands

```bash
/usr/bin/time -lp <baseline-or-candidate-blorp> run --release --no-format \
	blorp/benchmark/compiler/compiler_core_call_resolve_profile.brp \
	-- 1 512 32 4 64 4

/usr/bin/time -lp <baseline-or-candidate-blorp> compile --no-format \
	-o /tmp/blorp-step2d-selective.c \
	blorp/benchmark/compiler/selective_import_graph_fixture/main.brp

stat -f '%z %N' <baseline-blorp> bin/blorp
shasum -a 256 <baseline-blorp> bin/blorp
shasum -a 256 /tmp/blorp-step2d-selective.c
```

## Final Raw Counters

| Workload | Metric | Baseline | Candidate | Change |
| --- | --- | ---: | ---: | ---: |
| Core resolve | module-path entries | 162 | 98 | -39.5062% |
| Core resolve | module-path membership checks | 674 | 610 | -9.4955% |
| Core resolve | allocations | 6,802 | 6,850 | +0.70567% |
| Core resolve | releases | 6,801 | 6,849 | +0.70578% |
| Core resolve | retained objects | 1 | 1 | 0 |
| Core resolve | retained bytes | 176 | 192 | +16 bytes |
| Core resolve process | instructions retired | 31,907,223,325 | 32,474,390,512 | +1.7776% |
| Core resolve process | cycles | 8,202,369,973 | 8,249,921,428 | +0.5797% |
| Core resolve process | maximum RSS | 248,283,136 | 250,626,048 | +0.9436% |
| Core resolve process | peak footprint | 219,496,976 | 221,135,352 | +0.7464% |
| selective compile | instructions retired | 4,596,060,359 | 4,594,001,851 | -0.0448% |
| selective compile | cycles | 1,109,319,786 | 1,109,661,406 | +0.0308% |
| selective compile | maximum RSS | 50,003,968 | 49,954,816 | -0.0983% |
| selective compile | peak footprint | 36,733,312 | 36,651,344 | -0.2231% |
| compiler | executable bytes | 19,300,176 | 19,318,976 | +0.0974% |
| generated C | bytes | 1,533,809 | 1,533,809 | exact |

The baseline Core checksum was `-4750382870899280581`; the candidate checksum
was `8150285675370929752`. The change is expected because the observation schema
now includes callable/global/constructor ID indexes and the fixture contains exact bindings.
Both runs reported `workload_valid=True` and `error_count=0`.

Generated C remained 1,533,809 bytes. Its SHA-256 changed from
`9ac6e7cc009f155c5ab8f2f717dee55a2825d78eb855e23a64e8db665f187ea9`
to `ad2e5f7c5d39cd891c9ac63c0ead60b89ac15424c9715d2d118d324b104c35fb`.
The complete 29-line unified diff contains only one private symbol rename in
its declaration, call, and definition (`brp_nX` to `brp_nt`). Preserving graph
global semantic IDs means those globals no longer consume fresh Core IDs, so
the downstream private symbol projection changes without changing emitted
behavior or artifact size.

## Design Feedback From The Measurement Loop

The first correct implementation constructed the new callable target twice for
each declaration. It produced 7,880 allocations, +15.8% over the baseline, and
was rejected before the broad gate. Reusing the same target for the ID and name
indexes reduced the final candidate to 6,849 allocations (+0.69%).

The final 48-allocation increase corresponds to the additional exact builtin,
foreign, global, and constructor target indexes. Retained object count remains
one and retained bytes increase by sixteen. A future visibility
table may allow sparse or shared indexing, but introducing a second requested-ID
set in this packet would duplicate import membership and risk doing more work
than it removes.

## Interpretation

The intended structural metrics improve materially: exact imports remove 64
module-path entries and 64 path membership checks from an otherwise identical
binding workload. The deterministic managed-allocation increase is below 0.7%.
The isolated command's secondary native counters range from +0.58% to +1.78%.
That command includes compilation of the benchmark outside its deterministic
managed-memory window, so the result is retained as an investigated secondary
guard rather than averaged away. Directly attributed path counters and
allocation shape remain bounded, while the production compile ranges from
-0.22% to +0.03%. Compiler size grows by 18,800 bytes (+0.10%). There is no
evidence of a material production regression.

One-shot real time moved from 3.61 to 3.64 seconds for the isolated command and
remained 0.28 seconds for the production compile. These short-run
movements are recorded for transparency and are not used as evidence of either
a latency regression or improvement.
