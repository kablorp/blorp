# Perceus Tranche 4D — Checkpoint A Function Catalogs

This report compares the Checkpoint A candidate with the committed Issue 50
parent, revision `15f1a833`. Separate production and debug/profile backend
workers ran seven warmed pairs with alternating parent/candidate order. The
matrix measures direct Perceus over decoded ownership-ready Core; worker startup
and JSON transport are outside the reported inner window.

Environment: macOS 26.6.2, arm64.

```bash
benchmarks/compiler_perceus_memory \
  --mixed-function-owner-catalog-matrix \
  --baseline-bridge <issue-50-timing-worker> \
  --baseline-counter-bridge <issue-50-counter-worker> \
  --samples 7 \
  --json
```

## Change

An ordinary function now constructs one ordered borrowed-owner catalog:

1. managed borrowed parameters in declaration order;
2. exact referenced managed globals in ascending global-index order.

Referenced globals are discovered from the annotated contract body before any
borrowed-boundary normalization. The existing call, aggregate-transfer, and
result-position walkers each consume the combined catalog once. This removes
the second three-walk global normalization sequence without changing those
walkers, lambda normalization, or global-initializer normalization.

Catalog region identity is now independent of entry origin: function, lambda,
and global-initializer regions have explicit variants. The function path also
appends global entries directly after parameter entries, avoiding an
intermediate global list and concatenation.

## Fixture

Each of two uncalled ordinary functions has exactly 1,536 serialized expression
nodes. Each body contains 32 consuming calls, 32 transferring aggregate values,
and 32 borrowed result terminals. Every family exercises both parameters and
globals. The high point has 32 managed borrowed parameters and eight exact
referenced managed globals per function; the low control has one of each.

```text
functions=2
body_nodes=1536 per function
parameter/global points=1/1,32/8
call/storage/result sites=32/32/32 per function
nested_lambdas=0
worker_invocation=false
measurement_window=perceus-direct
samples=7
```

The inert sequence padding is balanced so fixture size is not limited by
Python JSON recursion depth. Its node count, evaluation order, and final value
are exact and unchanged by balancing.

## Paired Results

| Parameters / globals | Parent visits | Candidate visits | Visit reduction | Paired inner-time ratio | Allocation ratio | Release ratio |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 / 1 | 13,722 | 6,274 | 54.3% | 0.948 | 0.943 | 0.940 |
| 32 / 8 | 15,476 | 6,290 | 59.4% | 0.883 | 0.937 | 0.935 |

At the high point, the paired direct-Perceus median improved by 11.7%.
Allocations fell from 115,067 to 107,819 (6.3%), and releases fell from
111,000 to 103,752 (6.5%). Each candidate point performed exactly 64 call, 64
aggregate-transfer, and 64 result rewrites with zero scalar alias fallbacks.

The original issue estimated a 10% allocation reduction. A brief follow-up
removed the intermediate global list and concatenation, but the reproducible
result remained 6.3%. The landing gate was therefore revised to 5%: the change
comfortably clears the structural-work and elapsed-time gates, and no unrelated
optimization was added merely to satisfy a prospective estimate.

## Correctness

Immediate-parent and candidate post-Perceus Core artifacts were byte-identical
at both matrix points:

| Parameters / globals | Core bytes | Core SHA-256 |
| ---: | ---: | --- |
| 1 / 1 | 419,452 | `c0f79a820b47a9ce53d9b8d0acd1f901c1fa5ca0c31de05e44da45809be5aede` |
| 32 / 8 | 412,732 | `1a31a9fdf0d4eca0ddc3323951cd2961a5e9499cd5b348682beb6e810afd4a68` |

Separate backend-emission comparisons also produced byte-identical C:

| Parameters / globals | C bytes | C SHA-256 |
| ---: | ---: | --- |
| 1 / 1 | 229,284 | `f0b6c823728a19a0c0f6cdedf3aff11401e9bba90287418c5f513e823882197f` |
| 32 / 8 | 222,697 | `bef22c88b951db2d3f6f95d4c692d52245d5d9c83b83f231b16caeab402f9dbb` |

The focused Perceus suite passed 329/329 tests. The benchmark contract suite
passed 52/52 tests.

## Reproduction Details

Measured candidate timing worker SHA-256:
`c8a486a0782b91a66fc4cdabf6b46d7ac911c9d27cede9ba12b9a285cab087f3`

Measured candidate counter worker SHA-256:
`35425f38cd3b78eb2fd073b618badc4d81afdc9a17db5b1d23af502274646f3d`

Immediate-parent timing worker SHA-256:
`63dfb8ed1218cfd6f4bea090b4de1d776ef8fed4fc041270e3daa8936e90d9d0`

Immediate-parent counter worker SHA-256:
`1cd943af9ae49258579b4815b577f83967228a404529af08b4ccbbe9be4c6300`

Harness SHA-256:
`7bdaa9c228e93181ca3b521b5e51bbc18df5516f96664764c4281a44bc457b51`

Checkpoint A workers are preserved under
`/tmp/blorp_issue51a_checkpoint_a/{timing,counters}/compiler_backend_worker`.
Their binary hashes differ from the measured disposable workers because the
generated worker build embeds its temporary output path.
