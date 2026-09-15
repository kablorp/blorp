# Cancellation-Plan Child Accumulation

Issue 100 replaced repeated `List.concat` calls in cancellation-plan child
result accumulation with an ownership-local append helper. The final code is
commit `c6053254`; the original experimental candidate was `5475e5d1`, based
on `9ecb72e9`.

## Decision

Accept the minimal accumulation change. The heavy combined workload reduced
median retired instructions by 27.35% and process time by 30.77%. Affected
deep and match shapes reduced allocations by 16-18% and elapsed by about 38%.
The small workload also improved.

The experimental candidate included a public statistics API and a second Core
traversal. Those were removed before acceptance: they duplicated production
classification, were used only by the benchmark, and were unnecessary once
external allocations and instruction counts established the mechanism.

## Focused results

The heavy workload uses `50 512 512` (iterations, depth, width). Five samples
alternated baseline/candidate order. Shape allocation counts are deterministic;
elapsed values are medians.

| Shape | Allocation change | Baseline elapsed | Candidate elapsed | Change |
| --- | ---: | ---: | ---: | ---: |
| deep lets | 640,300 to 537,900 (-15.99%) | 103,716 us | 64,779 us | -37.54% |
| wide lets | 743,100 to 640,600 (-13.79%) | 74,546 us | 71,326 us | -4.32% |
| managed matches | 717,300 to 589,350 (-17.84%) | 106,586 us | 66,327 us | -37.77% |
| cancelling lets | 646,650 to 544,150 (-15.85%) | 103,723 us | 66,124 us | -36.25% |
| leaf | 300 to 300 | 23 us | 21 us | -8.70% |

| Heavy process median | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| retired instructions | 7,117,508,410 | 5,171,200,398 | -27.35% |
| cycles | 1,646,878,171 | 1,129,544,388 | -31.41% |
| real time | 0.39 s | 0.27 s | -30.77% |

The small guardrail uses `5000 2 2`. Median retired instructions improved from
2,790,787,526 to 2,568,473,167 (-7.97%), process time from 0.12 to 0.11 seconds,
and isolated leaf elapsed from 1,714 to 1,597 us (-6.83%) with identical
30,000 allocations.

All runs reported `workload_valid=True`. Stable expression visits, planned
owner counts, site/protection counts, and per-shape checksums matched. The raw
process samples are retained in
`compiler_cancellation_plan_child_accumulation_2026-09-15.tsv`; every
per-shape record is retained in
`compiler_cancellation_plan_child_shapes_2026-09-15.tsv`. The complete raw log
had SHA-256
`e8472bd3e8ffe4e99cba4102a21eb509dbc477ff38ab79db3bb669745524bbc8`.

## Provenance and reproduction

The final candidate source SHA-256 was
`81a5ab7dde63a374f8882fa1473de3f9b9508c5cecb74e77f2fd8eb74e84034d`;
the matched baseline overlay was
`85ffa3ff45019081cd69836a119666de5f61b04c91f96a17c470658d17095e66`.
Measured benchmark binaries were
`f6d851e9de609e444e7c983b0a24bdb4a4dd7d32a3267f74b294318212c3d43e`
(candidate) and
`0cd3879bdba89ac16ed35799759f9ea80b4cc9835d0297d77be992db9c7d93d1`
(baseline).

Create two worktrees at `c6053254`. Apply the exact three-call control patch to
the baseline, then build each tree and cache the identical benchmark
separately:

```bash
issue100_root=$(mktemp -d /tmp/blorp-issue100.XXXXXX)
baseline_tree="$issue100_root/baseline"
candidate_tree="$issue100_root/candidate"
git worktree add --detach "$baseline_tree" c6053254
git worktree add --detach "$candidate_tree" c6053254

perl -0pi -e \
  's/sites = append_child_results\(sites, child_analysis\.sites\)/sites = sites.concat(child_analysis.sites)/' \
  "$baseline_tree/blorp/src/compiler/stage_10_backend/cancellation_plan.brp"
perl -0pi -e \
  's/protections = append_child_results\(protections, child_analysis\.let_protections\)/protections = protections.concat(child_analysis.let_protections)/' \
  "$baseline_tree/blorp/src/compiler/stage_10_backend/cancellation_plan.brp"
perl -0pi -e \
  's/match_protections = append_child_results\(\n\t\t\t\tmatch_protections,\n/match_protections = match_protections.concat(\n/' \
  "$baseline_tree/blorp/src/compiler/stage_10_backend/cancellation_plan.brp"
shasum -a 256 \
  "$baseline_tree/blorp/src/compiler/stage_10_backend/cancellation_plan.brp"

make -C "$baseline_tree"
make -C "$candidate_tree"

BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
BLORP_BENCHMARK_CACHE_DIR=/tmp/issue100-baseline-cache \
"$baseline_tree/benchmarks/compiler_cancellation_plan_profile" 1 2 2

BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
BLORP_BENCHMARK_CACHE_DIR=/tmp/issue100-candidate-cache \
"$candidate_tree/benchmarks/compiler_cancellation_plan_profile" 1 2 2
```

Resolve the single executable below each cache and collect the alternating
samples:

```bash
baseline_bin=$(find /tmp/issue100-baseline-cache -type f \
  -name compiler_cancellation_plan_profile -perm -111)
candidate_bin=$(find /tmp/issue100-candidate-cache -type f \
  -name compiler_cancellation_plan_profile -perm -111)
raw=/tmp/issue100-final.raw
: > "$raw"

for workload in heavy small; do
  if [ "$workload" = heavy ]; then
    samples=5; args="50 512 512"
  else
    samples=3; args="5000 2 2"
  fi
  for sample in $(seq 1 "$samples"); do
    if [ $((sample % 2)) -eq 1 ]; then
      variants="baseline candidate"
    else
      variants="candidate baseline"
    fi
    for variant in $variants; do
      if [ "$variant" = baseline ]; then
        binary="$baseline_bin"
      else
        binary="$candidate_bin"
      fi
      echo "BEGIN workload=$workload sample=$sample variant=$variant" >> "$raw"
      /usr/bin/time -lp "$binary" $args >> "$raw" 2>&1
      echo END >> "$raw"
    done
  done
done
shasum -a 256 "$raw" "$baseline_bin" "$candidate_bin"
```

For the shape TSV, emit one row for each `CANCELLATION_PLAN_PROFILE` line,
carrying forward workload/sample/variant from the preceding `BEGIN`, and split
its `key=value` fields. For the process TSV, emit one row at `END`, adding the
numeric prefixes from `real`, `instructions retired`, `cycles elapsed`, and
`peak memory footprint`. Preserve block order; the retained tables contain 80
shape rows and 16 process rows respectively.

```bash
awk 'BEGIN {
  OFS="\t"; print "workload","sample","variant","shape","elapsed_us", \
    "allocations","releases","current_objects","bytes_allocated", \
    "expression_visits","planned_owners","sites","let_protections", \
    "match_protections","checksum","workload_valid"
}
$1 == "BEGIN" {
  split($2,p,"="); w=p[2]; split($3,p,"="); s=p[2]
  split($4,p,"="); v=p[2]
}
$1 == "CANCELLATION_PLAN_PROFILE" {
  delete x
  for (i=2; i<=NF; i+=1) { split($i,p,"="); x[p[1]]=p[2] }
  print w,s,v,x["shape"],x["elapsed_microseconds"],x["total_allocations"], \
    x["total_releases"],x["current_objects"],x["bytes_allocated"], \
    x["expression_visits"],x["planned_owners"],x["sites"], \
    x["let_protections"],x["match_protections"],x["checksum"], \
    x["workload_valid"]
}' "$raw" > /tmp/issue100-shapes.tsv

awk 'BEGIN {
  OFS="\t"; print "workload","sample","variant","real_seconds", \
    "instructions_retired","cycles_elapsed","peak_memory_bytes", \
    "workload_valid"
}
$1 == "BEGIN" {
  split($2,p,"="); w=p[2]; split($3,p,"="); s=p[2]
  split($4,p,"="); v=p[2]; valid="True"
}
$1 == "CANCELLATION_PLAN_PROFILE" && $NF != "workload_valid=True" {
  valid="False"
}
$1 == "real" { real=$2 }
/instructions retired$/ { instructions=$1 }
/cycles elapsed$/ { cycles=$1 }
/peak memory footprint$/ { peak=$1 }
$1 == "END" { print w,s,v,real,instructions,cycles,peak,valid }
' "$raw" > /tmp/issue100-process.tsv
```

## Validation

- focused cancellation-plan suite: 36/36;
- changed-owner checks: 2/2 suites and 2/2 special checks, including Core
  sanitizer and generated-C audit;
- representative generated C was byte-identical, SHA-256
  `9bbb8904d7334fd65412d5b3f194db7b945f1724dffeb1c719851157e75eb485`;
- compiler build status: `FRESH`;
- `git diff --check`.
