# Match-Bound Name Deduplication

Issue 110 replaced
`bound.concat(core_pattern_bound_names(pattern)).unique()` with ordered,
incremental admission while traversing the pattern. The accepted candidate was
`8d846708a677223508c3685d68fd32620faa732f`, based on
`9ecb72e934c42f730fe15b5f3f05ee62a76db5f6`. Final all-variant fixture and
regression coverage are commit `1db0b0ca`.

## Decision

Accept. On the duplicate-heavy focused workload, the candidate reduced median
retired instructions by 35.0%, allocations by 14.7%, and measured elapsed time
by 39.1%. The small workload did not regress. Core and generated-C identity
checks passed.

The optimization preserves the existing order: unique incoming names, then
the first occurrence of each pattern name. Incoming `bound` is unique by
construction because both rewrite entry points start empty and all recursive
scope extensions use the same admission helpers. The retained fixture covers
every `CorePattern` variant, including list spread and nested order.

## Workloads and results

The heavy command arguments were `20 64 512 16`: 20 iterations, 64 incoming
names, 512 requested cases, and 16 pattern binders. Structural work counters
describe one iteration; time and memory cover all iterations. Five samples
alternated baseline/candidate order.

| Heavy median | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| retired instructions | 4,976,450,178 | 3,235,691,165 | -34.98% |
| cycles | 1,126,440,948 | 755,878,097 | -32.90% |
| elapsed | 216,614 us | 131,975 us | -39.07% |
| allocations | 1,546,621 | 1,319,661 | -14.67% |
| releases | 1,397,786 | 1,296,378 | -7.25% |
| peak memory | 28,492,112 bytes | 11,256,120 bytes | -60.49% |

The deterministic model's membership comparisons fell from 1,885,320 to
522,648 per iteration. Every run reported `workload_valid=True` and semantic
checksum `-4471445784387596906`.

A separate three-pair small guardrail (`20 4 4 2`) improved median elapsed
from 534 to 513 us (-3.93%), allocations from 9,981 to 9,461 (-5.21%), and
retired instructions from 32,293,575 to 31,574,883 (-2.23%). Its semantic
checksum was identical at `-1178270980756535734`.

Raw heavy and small results are retained in
`compiler_match_bound_names_profile_2026-09-15.tsv`. The complete combined raw
log had SHA-256
`eafa9efa4047c824d6abda738d346ad7bccf2fcee539b83ab43de1860cc8e634`.

## Reproduction

The retained samples ran on Darwin 25.6.0 arm64, Apple M4, using Apple clang
21.0.0. The following creates both source roots from immutable revisions. The
baseline receives exactly the three benchmark-only files so both variants run
the same harness; it does not receive `flatten.brp`.

```bash
issue110_root=$(mktemp -d /tmp/blorp-issue110.XXXXXX)
baseline_tree="$issue110_root/baseline"
candidate_tree="$issue110_root/candidate"

git worktree add --detach "$baseline_tree" \
  9ecb72e934c42f730fe15b5f3f05ee62a76db5f6
git worktree add --detach "$candidate_tree" \
  8d846708a677223508c3685d68fd32620faa732f
for tree in "$baseline_tree" "$candidate_tree"; do
  git -C "$tree" checkout 1db0b0ca -- \
    benchmarks/compiler_match_bound_names_profile \
    blorp/benchmark/compiler/compiler_match_bound_names_profile.brp \
    blorp/benchmark/compiler/compiler_match_bound_names_profile_fixture.brp
done

make -C "$baseline_tree"
make -C "$candidate_tree"

BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
BLORP_BENCHMARK_CACHE_DIR=/tmp/issue110-baseline-cache \
"$baseline_tree/benchmarks/compiler_match_bound_names_profile" \
  plain 20 64 512 16

BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
BLORP_BENCHMARK_CACHE_DIR=/tmp/issue110-candidate-cache \
"$candidate_tree/benchmarks/compiler_match_bound_names_profile" \
  plain 20 64 512 16
```

Repeat with `20 4 4 2` for the small guardrail. Resolve the one executable
below each cache directory, then use this collection loop:

```bash
baseline_bin=$(find /tmp/issue110-baseline-cache -type f \
  -name compiler-match-bound-names-profile -perm -111)
candidate_bin=$(find /tmp/issue110-candidate-cache -type f \
  -name compiler-match-bound-names-profile -perm -111)
raw=/tmp/issue110-final.raw
: > "$raw"

for workload in heavy small; do
  if [ "$workload" = heavy ]; then
    samples=5; args="20 64 512 16"
  else
    samples=3; args="20 4 4 2"
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

Each `BEGIN`/`END` block maps to one TSV row. Extract the named fields from its
`MATCH_BOUND_NAMES_PROFILE` line and the numeric prefixes of `instructions
retired`, `cycles elapsed`, and `peak memory footprint`; preserve block order:

```bash
awk 'BEGIN {
  OFS="\t"
  print "workload", "sample", "variant", "elapsed_us", "allocations", \
    "releases", "retained_objects", "instructions_retired", \
    "cycles_elapsed", "peak_memory_bytes", "semantic_checksum", \
    "workload_valid"
}
$1 == "BEGIN" {
  split($2, workload_pair, "="); workload = workload_pair[2]
  split($3, sample_pair, "="); sample = sample_pair[2]
  split($4, variant_pair, "="); variant = variant_pair[2]
}
$1 == "MATCH_BOUND_NAMES_PROFILE" {
  delete value
  for (field = 2; field <= NF; field += 1) {
    split($field, pair, "="); value[pair[1]] = pair[2]
  }
}
/instructions retired$/ { instructions = $1 }
/cycles elapsed$/ { cycles = $1 }
/peak memory footprint$/ { peak = $1 }
$1 == "END" {
  print workload, sample, variant, value["elapsed_microseconds"], \
    value["allocations"], value["releases"], value["retained_objects"], \
    instructions, cycles, peak, value["semantic_checksum"], \
    value["workload_valid"]
}' "$raw" > /tmp/compiler_match_bound_names_profile.tsv
```

The measured binaries had SHA-256
`5721ab8266983270870159d4acb34e8c1f05a136217200044f39ad402a2267da`
(baseline) and
`ed49481a78694976d430908539aa8d27ccad17479d89382a5e48adab341e4e58`
(candidate).

## Validation

- flatten suite: 23/23;
- changed-owner suite and Core-sanitizer special check: passed;
- `scripts/test compiler-blorp`: 4,557/4,557;
- manifest: 322 production modules, 237 suites, 8 checks;
- normalized lower Core identity SHA-256:
  `d04da60e2da4b0db348b6837efadd74286b0a66ba59b62aaa5b1530167f36309`;
- generated-C identity SHA-256:
  `4be553ea3f6dd20748dc3c3f6ae57343a8c7e76102175063ae1e99e272ffce75`;
- `git diff --check`.
