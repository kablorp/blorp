# Compiler Module Membership Step 2a

Date: 2026-09-10

## Decision

Accept the Step 2a implementation. Graph-owned `BoundModuleVisibility` is now
the sole accepted visible/direct membership authority, and `ModuleView` no
longer retains parallel module-path containers. Semantic outputs match the
parent baseline. At the normal workload, retained bytes and instructions
improve while the allocation-call count has a small 0.36% guard regression.
The sparse scale point improves all measured deterministic resource metrics,
and native artifact sizes stay well inside the 1% guard.

## Measurement Contract

The parent is commit `c7b15a2a` with only the benchmark-counter and fingerprint
instrumentation applied. The candidate is the Step 2a worktree immediately
before its commit. Both workers were built with their own compiler and run
directly under macOS `/usr/bin/time -lp` so retired instructions describe the
isolated generated worker rather than build or shell work.
The full-compiler size guard uses the installed `bin/blorp` artifact in each
worktree; its hashes are recorded with the raw TSV metadata.

The narrow import-binding measurement used one baseline/candidate pair:

```bash
compiler-module-binding-profile 10 64 16
```

The end-to-end construction guard used one baseline/candidate pair at its
normal shape:

```bash
compiler-typecheck-phase-profile bound 1 8 32 64 4 memory
```

A sparse scale guard checked that membership validation grows with edges, not
the complete module domain:

```bash
compiler-typecheck-phase-profile bound 1 128 1 1 1 memory
```

The raw values and worker SHA-256 digests are in
`compiler_module_membership_step2a_2026-09-10.tsv`. Setup was outside the
allocation-counter window in both builds. Both typecheck workers fingerprinted
the source-direct count and canonical path sequence with the same markers: the
parent projected that relation from `ModuleView` membership over direct graph
order, while the candidate read the explicit normalized prefix. The checksum
therefore detects source/ambient misclassification as well as ordinary
visible/direct changes.

## Results

| Measurement | Metric | Parent | Candidate | Change |
| --- | --- | ---: | ---: | ---: |
| Module binding | allocations | 46,135 | 45,525 | -1.322% |
| Module binding | releases | 44,653 | 44,045 | -1.362% |
| Module binding | retained objects | 1,482 | 1,480 | -0.135% |
| Module binding | allocated bytes | 102,344 | 101,648 | -0.680% |
| Module binding | retired instructions | 256,225,689 | 254,196,444 | -0.792% |
| Module binding | worker bytes | 1,761,936 | 1,762,528 | +0.034% |
| Bound phase | allocations | 30,366 | 30,476 | +0.362% |
| Bound phase | releases | 30,198 | 30,324 | +0.417% |
| Bound phase | retained objects | 168 | 152 | -9.524% |
| Bound phase | allocated bytes | 14,088 | 12,480 | -11.414% |
| Bound phase | retired instructions | 5,636,928,599 | 5,630,040,978 | -0.122% |
| Bound phase | worker bytes | 9,332,144 | 9,333,792 | +0.018% |
| Sparse 128-module guard | allocations | 385,642 | 347,311 | -9.940% |
| Sparse 128-module guard | releases | 383,584 | 345,509 | -9.926% |
| Sparse 128-module guard | retained objects | 2,058 | 1,802 | -12.439% |
| Sparse 128-module guard | allocated bytes | 261,200 | 234,648 | -10.165% |
| Sparse 128-module guard | retired instructions | 11,953,834,764 | 11,716,553,551 | -1.985% |
| Full compiler | binary bytes | 19,227,440 | 19,245,408 | +0.093% |

The module-binding checksum remained `126080`, with 64 aliases, 64 imported
names, 128 import bindings, and zero errors. The bound-phase checksum remained
`5254183091536699898`; its constructor-lookup checksum remained
`8938789772392276139`, with identical output and work counts. The 128-module
scale checksums also matched (`-8390288998339449221` and
`5263884647089367453`). The source-direct checksum closes the ambient-module
coverage gap. At sparse scale, avoiding transitive surfaces during
source binding compounds the retained-membership deletion: allocations fall
9.94% and retired instructions fall 1.99%.

## Timing And Memory Guards

One-shot wall time is not used as a claim. Module binding moved from 5,098 to
4,990 microseconds, the bound phase from 17,538 to 13,074 microseconds, and the
sparse scale guard from 176,482 to 160,937 microseconds. All three samples
decreased, but their short windows and concurrent host activity make them too
noisy to support a latency claim.

Operating-system memory is similarly coarse for these short-lived workers.
Module-binding maximum RSS moved from 4,210,688 to 4,276,224 bytes and peak
footprint from 2,654,496 to 2,720,032 bytes. The bound-phase maximum RSS moved
from 25,198,592 to 25,182,208 bytes and peak footprint was unchanged at
19,186,000 bytes. At sparse scale, maximum RSS fell from 43,532,288 to
43,450,368 bytes and peak footprint from 37,470,544 to 37,421,416 bytes. These
are small absolute movements, are not accepted as improvements or regressions,
and do not contradict the exact allocation
counters. A future packet should use a retained-process memory probe if OS peak
memory becomes a primary claim.

## Feedback-Loop Consequence

The useful loop was the focused registration, visibility, and declaration suites, followed by
one direct parent/candidate pair for each retained benchmark shape. Collecting
many noisy elapsed samples would not have changed the decision. Future Step 2
packets should keep this pattern: one red structural test, focused suites, one
mechanism-level pair, then the changed/stage gate once the design is stable.
