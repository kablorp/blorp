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
- Candidate source revision: `745a72616ec6101339f18ff58519021ad2aa8b94`
- Baseline compiler SHA-256: `9a57fab54e72db4b40af11aa06a1db8329c85db163582a50ff45050adc6687a5`
- Baseline profile C SHA-256: `3259f3e64714ddf7e214e691009d9a19eddfb376eeec52e19b823a8126c6e428`
- Baseline profile executable SHA-256: `48d24bed168977aee6bea5524c546bcff621a4d91ac0c1bba4822d3b9e4721cb`
- Candidate compiler SHA-256: `c2f103f1d2d928b3e7d190c0b296ab4ac973f0d1006e8c78b047105d18c6811f`
- Candidate profile C SHA-256: `2b3bbdaa1f159c70263768ce69e538680ee631d0c9d5a8b4d0afd210dd2fce65`
- Candidate profile executable SHA-256: `5fda2f947b5b4dfc5f8f365c069bd83cb2696097e0f11ab001bd7bc99e89a6ac`

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

## Reproduction

The candidate benchmark source is overlaid unchanged onto the baseline so the
only production difference is `env.brp`. From a clean checkout, create the two
detached worktrees and build their compilers:

```bash
git worktree add /tmp/blorp-issue108-baseline \
  9ecb72e934c42f730fe15b5f3f05ee62a76db5f6
git worktree add /tmp/blorp-issue108-candidate \
  745a72616ec6101339f18ff58519021ad2aa8b94
cp /tmp/blorp-issue108-candidate/blorp/benchmark/compiler/compiler_implementation_pattern_profile.brp \
  /tmp/blorp-issue108-baseline/blorp/benchmark/compiler/
make -C /tmp/blorp-issue108-baseline
make -C /tmp/blorp-issue108-candidate
```

Compile from each worktree with a relative source path so compiler module
identity is independent of the worktree's absolute path. The benchmark uses
runtime allocation counters and its own narrow profile window; compiler-wide
`--profile` instrumentation is deliberately off. Build the generated C with
the same `cc -O2 -fwrapv -pipe -w` flags on both sides:

```bash
artifact=/tmp/blorp-issue108-artifacts
mkdir -p "$artifact/baseline" "$artifact/candidate"
for side in baseline candidate; do
  root=/tmp/blorp-issue108-$side
  (cd "$root" && bin/blorp compile --no-format \
    -o "$artifact/$side/implementation_pattern_profile.c" \
    blorp/benchmark/compiler/compiler_implementation_pattern_profile.brp)
  cc -O2 -fwrapv -pipe -w \
    -I"$root/blorp/src/compiler/stage_04_modules" \
    -I"$root/blorp/src/compiler/stage_06_typecheck/graph" \
    "$artifact/$side/implementation_pattern_profile.c" \
    -lm -lpthread -o "$artifact/$side/implementation_pattern_profile"
done
shasum -a 256 "$artifact"/baseline/* "$artifact"/candidate/*
```

Collect five samples per side, alternating order within each pair:

```bash
candidate=/tmp/blorp-issue108-candidate
result_root="$candidate/benchmarks/results/issue_108"
for sample in 1 2 3 4 5; do
  if ((sample % 2 == 1)); then
    sides=(baseline candidate)
  else
    sides=(candidate baseline)
  fi
  for side in "${sides[@]}"; do
    /usr/bin/time -lp "$artifact/$side/implementation_pattern_profile" \
      20000 32 8 0 1000000000 \
      > "$result_root/${side}_${sample}.out" \
      2> "$result_root/${side}_${sample}.time"
  done
done
```

The sides run in alternating order (`baseline,candidate` for odd samples and
`candidate,baseline` for even samples), matching the retained collection.
Verify every output reports
`workload_valid=True`, compare semantic/work counters pairwise, then take the
median of the five values for each side. The scaling rows use the candidate
binary with arguments `5000 8 4 0 1000000000`, `5000 16 4 0 1000000000`, and
`5000 16 8 0 10`.

## Medians

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Production window elapsed micros | 1,063,491 | 806,150 | -24.20% |
| Production allocations | 14,280,000 | 8,520,000 | -40.34% |
| Production releases | 14,280,000 | 8,520,000 | -40.34% |
| Process instructions retired | 34,138,156,814 | 27,239,650,814 | -20.21% |
| Process real seconds | 1.47 | 1.22 | -17.01% |
| Trait obligations visited | 5,120,000 | 5,120,000 | unchanged |
| Substitution entries compared | 10,560,000 | 10,560,000 | unchanged |
| Baseline scan enumeration allocations | 640,000 | 640,000 | unchanged in probe |
| Indexed scan enumeration allocations | 0 | 0 | unchanged in probe |
| Baseline/indexed semantic checksum | 2,728,960,000 | 2,728,960,000 | unchanged |
| Production semantic checksum | 20,000 | 20,000 | unchanged |

`/usr/bin/time -lp` measured the whole benchmark process, not only
the production window. The counted baseline and indexed windows are unchanged
between binaries; the production window is the changed mechanism.

## Scaling Matrix

Raw matrix: `benchmarks/results/issue_108/candidate_scaling_matrix.out`.

| Iterations | Bounds | Traits per bound | Miss | Trait visits | Substitution comparisons | Result |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 5,000 | 8 | 4 | none | 160,000 | 180,000 | valid |
| 5,000 | 16 | 4 | none | 320,000 | 680,000 | valid |
| 5,000 | 16 | 8 | 10 | 55,000 | 15,000 | valid first-failure result |

Doubling bound width with fixed traits doubles obligation visits, confirming
aggregate-linear obligation traversal. The substitution comparisons grow from
180,000 to 680,000 because each visited bound performs a name scan over the
substitution list.

The counted model establishes the exact first-failure visit count. The
production window independently establishes the same false result and semantic
checksum, but its pure callback does not expose a callback-order counter; code
inspection and the unchanged early-exit structure protect that ordering claim.

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
