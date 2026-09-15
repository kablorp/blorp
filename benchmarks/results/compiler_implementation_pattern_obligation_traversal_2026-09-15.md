# Implementation Pattern Obligation Traversal

## Summary

Issue 108 is an admitted narrow refactor, not a trait-resolution cache change.
The nested obligation traversal is aggregate-linear in declared obligations,
but `bound.bounds.enumerate()` materialized one indexed collection per visited
bound. Carrying the bound index manually removes that allocation while
preserving obligation order, bound identity lookup, short-circuit behavior, and
semantic checksums.

Substitution lookup remains a linear scan per visited bound. The retained
profile shows the expected triangular comparison count as bound width grows;
that is a separate mechanism and was not changed here.

## Provenance

- Baseline source revision: `9ecb72e934c42f730fe15b5f3f05ee62a76db5f6`
- Baseline compiler SHA-256: `9a57fab54e72db4b40af11aa06a1db8329c85db163582a50ff45050adc6687a5`
- Baseline profile C SHA-256: `3259f3e64714ddf7e214e691009d9a19eddfb376eeec52e19b823a8126c6e428`
- Baseline profile executable SHA-256: `fc8ed2d003780d157968681ce15dc9fcfa692c52ad7c5961f6bf29f5e5aad3b9`
- Candidate compiler SHA-256: `c2f103f1d2d928b3e7d190c0b296ab4ac973f0d1006e8c78b047105d18c6811f`
- Candidate profile C SHA-256: `2b3bbdaa1f159c70263768ce69e538680ee631d0c9d5a8b4d0afd210dd2fce65`
- Candidate profile executable SHA-256: `cf8c2099f091584eed91c089514fddc5f25c0fc4eaa124e49261dc70a1940c98`

## Workload

The focused workload was:

```bash
/usr/bin/time -lp implementation_pattern_profile 20000 32 8 0 1000000000
```

That means 20,000 successful pattern-match requests, 32 bound parameters, 8
trait obligations per parameter, no duplicate stride, and no in-range miss.
Every synthetic bound carries resolved trait identities, and the production
callback validates that each received identity's name and definition ID match
the current obligation.
Raw sample output is retained under `benchmarks/results/issue_108/`.

## Medians

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Production window elapsed micros | 3,596,257 | 2,589,552 | -27.99% |
| Production allocations | 14,280,000 | 8,520,000 | -40.34% |
| Production releases | 14,280,000 | 8,520,000 | -40.34% |
| Process instructions retired | 34,182,821,217 | 27,268,083,806 | -20.23% |
| Process real seconds | 4.91 | 3.81 | -22.40% |
| Trait obligations visited | 5,120,000 | 5,120,000 | unchanged |
| Substitution entries compared | 10,560,000 | 10,560,000 | unchanged |
| Baseline scan enumeration allocations | 640,000 | 640,000 | unchanged in probe |
| Indexed scan enumeration allocations | 0 | 0 | unchanged in probe |
| Baseline/indexed semantic checksum | 2,728,960,000 | 2,728,960,000 | unchanged |
| Production semantic checksum | 20,000 | 20,000 | unchanged |

`/usr/bin/time -lp` measured the whole optimized benchmark process, not only
the production window. The counted baseline and indexed windows are unchanged
between binaries; the production window is the changed mechanism.

## Scaling Matrix

Raw matrix: `benchmarks/results/issue_108/candidate_scaling_matrix.out`.

| Iterations | Bounds | Traits per bound | Miss | Trait visits | Substitution comparisons | Result |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 5,000 | 8 | 4 | none | 160,000 | 180,000 | valid |
| 5,000 | 16 | 4 | none | 320,000 | 680,000 | valid |
| 5,000 | 16 | 8 | 10 | 55,000 | 15,000 | valid first failure |

Doubling bound width with fixed traits doubles obligation visits, confirming
aggregate-linear obligation traversal. The substitution comparisons grow from
180,000 to 680,000 because each visited bound performs a name scan over the
substitution list.

## Output Identity

`blorp/src/main.brp` emitted different C because the compiler source itself
changed. For an unchanged runnable workload, clean baseline and candidate
compilers emitted byte-identical C:

```bash
bin/blorp compile --no-format -o /tmp/blorp-issue108-control/list_ops.c \
  benchmarks/blorp/list_ops.brp
bin/blorp compile --no-format -o /tmp/blorp-issue108-candidate/list_ops.c \
  benchmarks/blorp/list_ops.brp
cmp /tmp/blorp-issue108-control/list_ops.c /tmp/blorp-issue108-candidate/list_ops.c
```

Both files had SHA-256
`3df0a168562f73c81fd368f7161d6772a1ac44473b8a74db9954c1541842c604`.

## Validation

- `bin/blorp test blorp/test/compiler/stage_06_typecheck/test_accepted_semantic_catalog.brp`
- `bin/blorp test blorp/test/compiler/stage_06_typecheck/test_implementation_pattern_profile_benchmark.brp`
- `scripts/compiler-check --changed`
- `scripts/compiler-check --stage typecheck`
- `scripts/test compiler-blorp`
