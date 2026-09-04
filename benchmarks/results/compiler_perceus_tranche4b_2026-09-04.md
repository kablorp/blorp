# Perceus Tranche 4B — Referenced-Global Normalization

This report compares the Tranche 4B candidate with its captured
instrumentation-only scalar parent using separately compiled production and
debug/profile backend workers. Seven warmed pairs alternated parent/candidate
order. The focused matrix measures direct Perceus over decoded
ownership-ready Core; worker startup and JSON transport are outside the
reported inner window.

## Change

Ordinary function bodies and global initializers now discover exact managed
global reads once and normalize one-or-more referenced globals through a dense
owner catalog. Parameter normalization remains a separate preceding phase,
and each owner entry records whether its source is a function parameter or a
referenced global plus the original parameter/global index.

Empty discovery results return an empty entry list and do not allocate a
catalog. Every nonempty ordinary function/global region uses the same indexed
all-owner call/aggregate/result traversals. Nested lambdas remain explicitly on
the scalar path for Issue 50.

## Fixture

Each of two uncalled functions has exactly 256 expression nodes and 32 fixed
ownership-boundary sites: 12 consuming calls, 12 transferring aggregate slots,
and 8 branch-local result terminals. Those sites cycle through 1, 8, or 32
exact global identities while 384 globals remain declared.

```text
globals=384
functions=2
body_nodes_per_function=256
body_shape=referenced_global_boundary
boundary_sites_per_function=32
params_per_function=0
referenced_globals_per_function=1,8,32
samples=7
warmup=true
measurement_window=perceus-direct
worker_invocation=false
```

## Paired results

| Referenced globals per function | Parent visits | Candidate visits | Visit reduction | Paired inner-time ratio | Allocation ratio | Release ratio |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1,082 | 1,082 | 0.0% | 1.001 | 1.003 | 1.003 |
| 8 | 8,824 | 1,082 | 87.7% | 0.894 | 0.863 | 0.856 |
| 32 | 35,176 | 1,082 | 96.9% | 0.589 | 0.588 | 0.575 |

At 32 referenced globals, the paired direct-Perceus median improved by 41.1%,
allocations fell from 60,465 to 35,535 (41.2%), and releases fell from 58,654
to 33,724 (42.5%). At one global, timing was neutral; allocations increased
0.32% and releases increased 0.34%, both within the 2% guard.

Candidate catalog/discovery counters were:

| Referenced globals per function | Discovery nodes | Read candidates | Exact matches | Catalog slots | Normalization visits | Alias fallbacks | Rewrite actions |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 897 | 2 | 2 | 2 | 1,082 | 0 | 64 |
| 8 | 897 | 16 | 16 | 16 | 1,082 | 0 | 64 |
| 32 | 897 | 64 | 64 | 64 | 1,082 | 0 | 64 |

The fixed discovery walk and owner-independent reconstruction show no scaling
with the 384 declared-but-unreferenced globals. The retained sorted-list
deduplication handles at most the measured 64 exact candidates in this fixture;
its bounded cost did not justify adding a second discovery authority.

## Correctness

Parent and candidate post-Perceus Core artifacts were byte-identical at every
matrix point:

| Referenced globals | Bytes | SHA-256 |
| ---: | ---: | --- |
| 1 | 220,836 | `958ad1902d6e07d8fe595caa2fd8c253d812d331012e664cd413d2c45fd3b0bd` |
| 8 | 220,836 | `1df9dda483e5e1408c85cba7839fabc90abca8bbe6395e58a17f165112e01e65` |
| 32 | 220,928 | `c26405fe9226312a6361f1a9f3690ca2fed2968d1d5e3c59104854c197dc559f` |

A separate rooted backend-emission comparison invoked both workers and
produced byte-identical C at every point:

| Referenced globals | C bytes | C SHA-256 |
| ---: | ---: | --- |
| 1 | 103,645 | `976a7123a66c6b61a4e8097fa5c443f49af3d373c2c75bd51ebd96ea16e48c8e` |
| 8 | 103,645 | `fc9e72bb4bcdf77566537fcec7ce2863bb214a94fe45258815d364d48a39f2bd` |
| 32 | 103,645 | `2a12721c200d58c168dacc0924a36c57252a2a3b43996295789f0ef2b5e9f2f6` |

The focused Perceus suite passed 325/325 tests, including new exact-collision,
multi-global ordering, repeated-reference, and global-initializer
dependency/self-exclusion cases.
The benchmark contract suite passed 44/44 tests.

## Reproduction details

The candidate timing and counter-worker SHA-256 hashes were
`07f472a348972f0bdabe148f7c91c31593346c3a06301fd9ed3bff35bf60f6a5`
and
`490ad9d5b029b66fda8d132ab662d6ce22bcad82d6773c2a851ca9136bab868f`.
The scalar parent timing and counter-worker hashes were
`17512f5ed81adc919051b1f2be26f46664063e8c27225e69f2392fd375196151`
and
`8b7f73964697218eec49efcca9ce9bb7d11355421dbed8c74935eb107da2fcea`.
The final harness SHA-256 was
`629d04531f39dff677d9c89d6b47df7efc02b88bdbd9512e309f15ba7f7e693d`.

## Production self-compilation smoke

The current production compiler successfully compiled `blorp/src/main.brp`
through the complete pipeline and emitted compiler C after the focused gates
passed. This is a correctness smoke only; the tranche-wide compiler
self-compilation reprofile remains intentionally deferred to the 4D fusion
checkpoint.
