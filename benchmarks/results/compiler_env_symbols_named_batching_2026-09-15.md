# Environment Symbol History Batching

## Decision

Accept the narrow `env_symbols_named` accumulation change. Appending each
matching symbol directly to the uniquely owned result preserves exact scope and
overload order while removing repeated copies of the already-collected prefix.
No environment representation, lookup, or shadowing rule changed.

## Provenance

- Baseline production revision: `9ecb72e934c42f730fe15b5f3f05ee62a76db5f6`
- Candidate production revision: `f27966a51675e073f181b4710ad8238ba730e8eb`
- Benchmark main SHA-256: `9a2c0e29bbfab546a81b8469eff9ae2d89008bcab49aac49672e5fce06e4c3e9`
- Benchmark fixture SHA-256: `9fcfddca7af349ce37bcf5b8e4e73fc3268cc2075884febf2b7682cf03dbb1e2`
- Baseline compiler SHA-256: `35ce405299333bc2987c775ec8d41c55013a047d4f5c02f32eaa300be50aea29`
- Candidate compiler SHA-256: `76ee0b55473d9173788ef166b2ec25c9df49d7e9cc29aa45777860281776a626`
- Baseline benchmark executable SHA-256: `2f15d0b605ab4cc1b5e045e55adb38a85330457c38b77dfe44f765de1b16d9de`
- Candidate benchmark executable SHA-256: `6b13bd6a978d9a24f5c0932ec8974d909ca4b8a03ec6d796dea8aad3a61dc091`

The final harness is overlaid unchanged on both production revisions. It runs
one present-name and one absent-name query per iteration. `scope_visits`
therefore counts both traversals: 32,000 for the shallow workload and 1,024,000
for the wide workload. Raw outputs and macOS `/usr/bin/time -lp` samples are in
`benchmarks/results/issue_103/`.

## Results

Each row is the median of three alternating process pairs. Each process also
takes five same-boundary timing samples and reports their median. Allocation
and release counters cover one of those five windows and are exactly balanced.

| Workload and metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Shallow window, median us | 3,752 | 1,364 | -63.65% |
| Shallow allocations/releases | 46,001 | 8,001 | -82.61% |
| Shallow retired instructions | 517,557,277 | 227,108,116 | -56.12% |
| Wide window, median us | 948,047 | 34,379 | -96.37% |
| Wide allocations/releases | 1,434,001 | 10,001 | -99.30% |
| Wide retired instructions | 79,703,842,064 | 3,199,801,164 | -95.99% |

All 12 process outputs report `workload_valid=True`, zero absent matches,
balanced allocations/releases, and identical ordered identities and
checksums. The wide checksum is `2097610337543031480`; the shallow checksum is
`-7175579759607345520`. The modeled old implementation recopies 313,959,000
prefix entries in the wide workload. The retained implementation performs no
such prefix concat.

The first sample on each side includes the runner's cold artifact build. It is
retained, but the three-process median prevents that one-time build from
driving the result. The direct five-sample window excludes fixture setup and
native compilation.

## Reproduction

Use the fixed paths below because generated C symbols include the absolute
module path. Start in the final checkout containing this report and harness:

```bash
repo=$PWD
git worktree add --detach /tmp/issue103baseline \
  9ecb72e934c42f730fe15b5f3f05ee62a76db5f6
git worktree add --detach /tmp/issue103candidate \
  f27966a51675e073f181b4710ad8238ba730e8eb
for root in /tmp/issue103baseline /tmp/issue103candidate; do
  cp "$repo/blorp/benchmark/compiler/compiler_env_symbols_named_profile.brp" \
    "$root/blorp/benchmark/compiler/"
  cp "$repo/blorp/benchmark/compiler/compiler_env_symbols_named_profile_fixture.brp" \
    "$root/blorp/benchmark/compiler/"
  cp "$repo/benchmarks/compiler_env_symbols_named_profile" "$root/benchmarks/"
  make -C "$root"
done
```

Collect three alternating pairs for each workload:

```bash
results="$repo/benchmarks/results/issue_103"
for workload in shallow wide; do
  for sample in 1 2 3; do
    if ((sample % 2 == 1)); then
      sides=(baseline candidate)
    else
      sides=(candidate baseline)
    fi
    for side in "${sides[@]}"; do
      root="/tmp/issue103$side"
      if [[ "$workload" == shallow ]]; then
        args=(2000 8 2 1 5 1)
      else
        args=(1000 512 2 1 5 1)
      fi
      BLORP_COMPILER_BENCHMARK_WORKSPACE_ROOT="$root" \
      BLORP_COMPILER_BENCHMARK_COMPILER="$root/bin/blorp" \
      BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
      BLORP_BENCHMARK_CACHE_DIR="/tmp/issue103benchmarkcache/$side" \
      /usr/bin/time -lp "$root/benchmarks/compiler_env_symbols_named_profile" \
        "${args[@]}" \
        > "$results/${workload}_${side}_${sample}.out" \
        2> "$results/${workload}_${side}_${sample}.time"
    done
  done
done
```

The six positional controls are iterations, scope count, matches per nonempty
scope, overloads per nonempty scope, empty-scope stride, and unrelated symbols
per nonempty scope. The wrapper uses the shared runner's plain mode, which
builds generated C with `cc -O2 -fwrapv -pipe -w`.

## Output Identity And Validation

An unchanged inference fixture emits byte-identical C with both compilers:

```bash
mkdir -p /tmp/issue103identity
(cd /tmp/issue103baseline && bin/blorp compile --no-format \
  -o /tmp/issue103identity/baseline.c \
  blorp/test/compiler/stage_06_typecheck/infer_fixtures/infer/should_pass/ufcs_type_import_option.brp)
(cd /tmp/issue103candidate && bin/blorp compile --no-format \
  -o /tmp/issue103identity/candidate.c \
  blorp/test/compiler/stage_06_typecheck/infer_fixtures/infer/should_pass/ufcs_type_import_option.brp)
cmp /tmp/issue103identity/baseline.c /tmp/issue103identity/candidate.c
```

Both files have SHA-256
`cbc0692473886ebfab1cb1f9838081425c0b764edff6941d093c16de074cf38c`.
The candidate also compiled `blorp/src/main.brp` through C emission in 37.31
seconds; the emitted C SHA-256 was
`891bd333ac94d819e936e0594e3f92f160e78702e17b57a388f49fae0ba1ea73`.

Validation completed before closure:

- environment suite: 34/34
- benchmark contract: 2/2
- changed-owner gate: one source, two suites, one check
- typecheck stage: 38 suites and two checks
- compiler suite: 4,561/4,561

The acceptance thresholds are exceeded in both widths, output order and
identity are unchanged, and the implementation remains a seven-line local
rewrite. Further environment representation work is outside this result.
