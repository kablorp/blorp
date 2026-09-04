# Perceus Tranche 1 Result: Collect User-Call Contracts Once

**Date:** 2026-09-04
**Immediate parent:** `c5c05c98c1ece3e03ab3823efb019cb15789144f`
**Candidate:** working tree on that parent
**Fixture:** `compiler_perceus_memory`, version 5
**Platform:** macOS 26.6.2, arm64

## Result

Tranche 1 replaces parameter-by-parameter Core body summaries and body-rescanning
fixed-point waves with:

1. an exact `(name, def_id)` callable catalog constructed during the existing
   declaration scan;
2. one demand-directed contract-equation collection per inferred function;
3. dense callable and parameter identities;
4. sparse reverse parameter-flow adjacency; and
5. a frontier solver that visits newly relevant reverse edges without inspecting
   Core expressions.

On the maintained 32-managed-parameter fixture, the direct-Perceus window is
6.3% faster and performs 3.18% fewer allocations and releases. The candidate
retires 5.3% fewer instructions in the focused worker. Compiler self-compilation
is about 2% lower in retired instructions both when stopping after Perceus and
when continuing through C emission. Peak RSS is effectively flat, with a
0.2–1.1% increase depending on the measurement envelope.

Every maintained candidate/control comparison produced byte-identical
post-Perceus Core. All three production self-compilation pairs also produced
byte-identical post-Perceus Core and byte-identical generated C.

## Behavioral Compatibility

The catalog preserves the three distinct sources of call ownership:

- inferred contracts for functions with bodies;
- fixed nonconsuming inferred contracts for closure-body functions, except for
  the pre-existing direct-builtin-wrapper contract; and
- explicit call-site ownership for declarations without bodies.

User-call resolution is exact. A missing `def_id` does not fall back to another
same-named callable. Specialized functions that share a `def_id` remain distinct
because final resolution compares both the definition ID and name.

Two direct-Core compatibility cases still use the independent scalar analyzer:

- an incoming `DupExpr` for a parameter, because that duplication can cancel a
  later transitive consumption; and
- an unresolved `CoreVar` identity collision between a function parameter and a
  nested binder.

Both cases are identified during the one required collection visit and counted
by total and cause-specific fallback counters. Nested lambda bodies are
inspected for collection accounting but cannot contribute calls or lexical
shadowing to their enclosing callable contract. The scalar fallback counters
are all zero on the ownership-ready benchmark inputs.

Tests cover direct and transitive calls, recursion and mutual recursion,
same-named definitions, missing definition IDs, bodyless declarations,
closure-body contracts, stale incoming call-site contracts, incoming
duplication, unresolved parameter shadowing, and the borrowing policy of
`ListGet`.

## Structural Work Comparison

The principal fixture has one global, four generated functions, one entry
function, 256 body leaves, 32 managed `String` parameters per generated
function, and one nested user-call edge per function.

| Counter | Parent | Candidate |
| --- | ---: | ---: |
| Input Core expression nodes | 1,166 | 1,166 |
| Contract function analyses | 8 | 4 |
| Managed-parameter scalar summaries | 224 | 0 |
| Old scalar wave function reanalyses | 3 | n/a |
| Old scalar wave iterations | 3 | n/a |
| Contract collection expression visits | n/a | 989 |
| Contract collection task pushes | n/a | 985 |
| Managed parameter slots | n/a | 128 |
| Direct parameter inserts | n/a | 32 |
| Unique parameter-flow edges | n/a | 96 |
| Occupied reverse parameter slots | n/a | 96 |
| Flow-dedup entries | n/a | 96 |
| Solver flow visits | n/a | 96 |
| Solver frontier callable visits | n/a | 4 |
| Solver waves | n/a | 4 |
| Solver parameter marks | n/a | 128 |
| Scalar fallback analyses | n/a | 0 |
| Incoming-`Dup` fallback analyses | n/a | 0 |
| Parameter-shadow fallback analyses | n/a | 0 |
| All linear-summary requests in Perceus | 63,845 | 35,045 |
| All linear-summary node visits in Perceus | 1,278,421 | 1,239,637 |

The parent spent 38,784 scalar-summary node visits on the contract work removed
by this tranche. The replacement collector scheduled 989 expression visits, a
97.45% reduction in that specific syntax work. This is not a claim that every
collector operation is equivalent to one old scalar-summary visit; the
allocation, instruction, and elapsed measurements independently establish the
net result.

The collector indexed 128 managed parameter slots transiently while analyzing
the four signatures. The retained graph contains direct parameter indices, 96
occupied reverse slots, and 96 compact reverse flows. It does not retain the
parameter index, function bodies, per-expression fact maps, or the transient
forward-flow and dedup structures.

Functions with no managed parameters skip body collection entirely. This keeps
the fixed cost out of the common zero-managed-parameter case.

## Graph Scaling

The density axis uses 33 mutually recursive functions, eight managed parameters
per function, and 512 body leaves. Each candidate artifact is byte-identical to
the parent artifact for that fixture.

| Call edges per function | Unique flows | Solver flow visits | Occupied reverse slots | Frontier callable visits | Waves | Scalar fallbacks |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 264 | 264 | 264 | 33 | 33 | 0 |
| 8 | 2,112 | 2,112 | 264 | 33 | 5 | 0 |
| 32 | 8,448 | 8,448 | 264 | 33 | 2 | 0 |

The solver visits each unique flow once as density increases. It does not scan
all functions on every wave. It does scan a caller's signature when that caller
gains facts so newly consumed arguments retain signature order; the strict
solver term is `E + sum(updated caller arities)`, rather than only `E`. A
separate 128-function, one-parameter sparse chain required 128 propagation
waves but only 128 frontier callable visits and 127 reverse-flow visits. Its
artifact also matched the parent byte-for-byte.

## Paired Direct-Perceus Measurement

Seven warmed, alternating parent/candidate samples used counter-disabled
workers. Time is the worker's inner direct-Perceus window. Allocation and
release counts are deterministic. RSS is the maximum observed across all seven
process samples, not a median. Ratios below 1 favor the candidate.

| Metric | Parent | Candidate | Paired candidate / parent |
| --- | ---: | ---: | ---: |
| Direct-Perceus time, median | 444,880 us | 416,897 us | 0.9372 |
| Allocations | 5,806,620 | 5,622,213 | 0.9682 |
| Releases | 5,805,385 | 5,620,978 | 0.9682 |
| Worker peak RSS, maximum | 18,726,912 B | 18,939,904 B | 1.0114 |
| Whole worker-process time, median | 0.5471 s | 0.5476 s | 1.0018 |

Raw direct-window times were:

- parent: `444880, 444489, 444607, 446771, 451644, 444207, 453713` us;
- candidate: `414578, 411912, 416897, 418702, 425308, 417184, 415459` us.

Three additional alternating direct worker invocations under
`/usr/bin/time -lp` reported median retired instructions of 11,317,869,717 for
the parent and 10,715,023,418 for the candidate, a paired ratio of 0.9469. Their
artifacts were identical. Maximum RSS was 18,743,296 B for the parent and
18,956,288 B for the candidate.

## Production Self-Compilation

Three alternating pairs compiled `blorp/src/main.brp` with the isolated parent
and candidate production compilers. RSS below is the maximum across the three
runs; time, instructions, and cycles are medians. The final column is the
median of the three within-pair candidate/parent ratios, so it need not equal
the ratio of the two displayed medians.

| Stop point | Metric | Parent | Candidate | Paired candidate / parent |
| --- | --- | ---: | ---: | ---: |
| Post-Perceus Core | Time | 68.14 s | 66.87 s | 0.9800 |
| Post-Perceus Core | Retired instructions | 1,176,928,020,872 | 1,154,799,409,242 | 0.9812 |
| Post-Perceus Core | Cycles | 271,726,467,999 | 265,201,523,087 | 0.9768 |
| Post-Perceus Core | Peak RSS, maximum | 6,137,233,408 B | 6,144,344,064 B | 1.0012 |
| Generated C | Time | 63.69 s | 62.45 s | 0.9645 |
| Generated C | Retired instructions | 1,060,190,186,567 | 1,038,642,427,596 | 0.9797 |
| Generated C | Cycles | 251,670,208,004 | 245,779,777,591 | 0.9771 |
| Generated C | Peak RSS, maximum | 2,103,967,744 B | 2,107,457,536 B | 1.0017 |

Raw stop-after-Perceus pairs were:

| Pair (order) | Parent time | Candidate time | Parent RSS | Candidate RSS | Parent instructions | Candidate instructions |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 (candidate/parent) | 67.46 s | 65.90 s | 6,130,548,736 B | 6,143,229,952 B | 1,176,664,058,503 | 1,155,009,292,607 |
| 2 (parent/candidate) | 68.14 s | 66.87 s | 6,130,614,272 B | 6,144,344,064 B | 1,176,928,020,872 | 1,154,799,409,242 |
| 3 (candidate/parent) | 69.05 s | 67.67 s | 6,137,233,408 B | 6,144,212,992 B | 1,177,408,133,660 | 1,154,725,061,909 |

Raw complete-C-emission pairs were:

| Pair (order) | Parent time | Candidate time | Parent RSS | Candidate RSS | Parent instructions | Candidate instructions |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 (candidate/parent) | 63.68 s | 61.42 s | 2,096,381,952 B | 2,105,901,056 B | 1,060,294,321,708 | 1,038,642,427,596 |
| 2 (parent/candidate) | 63.69 s | 62.62 s | 2,096,431,104 B | 2,107,457,536 B | 1,060,079,046,555 | 1,038,527,153,043 |
| 3 (candidate/parent) | 65.28 s | 62.45 s | 2,103,967,744 B | 2,106,130,432 B | 1,060,190,186,567 | 1,038,683,573,958 |

All six post-Perceus artifacts were the same 315,930,904-byte file:

```text
a96553b28045ca090c5d204efa52ffd66ba3a4bd9181ba06abb730ee2587e8ba
```

All six generated C artifacts were the same 100,543,758-byte file:

```text
d4a8d38ec55a12b125295ecd80af1007389cc7efdbc01351b3b152661e3a483e
```

## Reproduction Identity

```text
candidate production compiler:
26122d2a50db4142fe4cf61b4baa8efe1121e989b809be65def1f7ac33c5b393
parent production compiler:
d982f41e9e4c3cefa1c8e38ee0d2bde75d91f804806501ef5a46df4984f1c28d
candidate timing worker:
720f6e04beb4fddbbb6d082939e32bf040ba008c1c187b22ba9de5cb77bfe043
parent timing worker:
30228748d216ce8f75d85b41073567b170073c9a61a1cf45fe3ca12f2962ad65
candidate counter worker:
4e423449d0a00404d49ae0d2b0f50df3d3f021c225b102b89387fc01b6539c34
parent counter worker:
1819cb853b366ef37e67a8ef1a79eec0bc34db2c22404122f83100bc3168fd0b
bootstrap compiler:
75fe5cc2b3c77a83f606bcaf82e4f5228357975ce7c69e0c86e2a2c5a7f36281
candidate harness:
6963f8e1f76a80f9bd4be66428c79c48b252cd19ce8d34e8fff0c2764518b2cb
principal request:
a70dac9ad885b9edf8af2ba379e51fc9fb2170a435f8819ea03af91b5dcefd0f
```

Workers used Apple clang 21.0.0 with `-O0 -fwrapv -pipe -w`. Counter workers
add Blorp `--debug --profile`; timing and production workers contain no work
counter calls.

The principal timing command was:

```bash
benchmarks/compiler_perceus_memory \
  --bridge "$candidate_worker" \
  --baseline-bridge "$parent_worker" \
  --globals 1 --global-reads-per-function 1 \
  --functions 4 --body-leaves 256 \
  --params-per-function 32 --parameter-type String \
  --body-shape nested_user_call --user-call-edges 1 \
  --measurement-window perceus-direct \
  --samples 7 --no-work-counters --json
```

The production comparison used the two commands prescribed by the roadmap:

```bash
compiler compile --no-format --stop-after=perceus \
  --dump-core-file="$output_json" blorp/src/main.brp
compiler compile --no-format -o "$output_c" blorp/src/main.brp
```

## Verification

- `perceus.brp` type-check: passed.
- Benchmark harness unit tests: 27/27 passed.
- Focused Perceus tests: 312/312 passed.
- Changed-file compiler check: passed the affected source, focused suite, and
  Core sanitizer check.
- `git diff --check`: passed.

## Stop/Go Decision

Proceed. Tranche 1 clears the structural target, reduces direct-Perceus time,
allocations, and retired instructions, preserves exact outputs, and scales with
the unique reverse edges rather than functions multiplied by fixed-point waves.
Retain the two explicit scalar compatibility paths and require their counters
to remain zero on ownership-ready production inputs before beginning Tranche 2.
