# Source-AST Finalization Diagnostic Batching

## Decision

Accepted. The heavy diagnostic workload reduced retired instructions by
27.25%, directly satisfying the proposed diagnostic-heavy gate.
`finalize_exprs` now appends each child diagnostic into its uniquely owned
result rather than concatenating every child list into the growing prefix.
Exact AST and diagnostic checksums match the baseline. In seven paired,
alternating samples after an unmeasured production-path warmup, clean, dense,
and heavy workloads improved elapsed time;
the clean path also removed 28.48% of measured allocations.

The dense and heavy fixtures improve total allocations by only 0.80% and
0.42%, because diagnostic construction dominates that process-level count.
The operation-specific model nevertheless removes 100% of the old
growing-prefix recopying (3,924,480 dense and 44,018,688 heavy element copies),
paired elapsed medians improve 17.63% and 48.66%, the clean path improves both
time and allocations by more than 10%, and exact output identity holds.

## Provenance

- Baseline revision: `9ecb72e934c42f730fe15b5f3f05ee62a76db5f6`
- Candidate revision: `51f3fd8fd7a8151afd7eab644883720fbbe823de`
- Common fresh compiler SHA-256:
  `efd7bff50fc7d1effe12e61ad969521ffe113406350428908b2d857b9b55073e`
- Benchmark harness SHA-256:
  `4eb54d794e469ea9ae457a062054761bc1659999e4b5cf8164e4155cead7dfe7`
- Baseline owner-source SHA-256:
  `10f159143ca761577cba53e4643a209d854782505498874b2dc8c099ee02135d`
- Candidate owner-source SHA-256:
  `01616160c740d49b4888d8aec837dfcf31375f65b510f55a2002530cbce28acb`
- Focused test SHA-256:
  `417097c1a27f73d8b8d6a91dea8a30da2a624395b141300923915ef674c8435d`
- Baseline/candidate benchmark binary SHA-256:
  `70dd7601f4df51d75c0487b89613a5c1c8f73a90e50e71068881557e0ffeac2a` /
  `8bf5d2e5c28ba37cab0a7d921d8804a0d8754f73b4a617f98281c71e28a0bd15`
- Retained paired samples:
  `benchmarks/results/compiler_source_ast_finalize_diagnostics_2026-09-14.tsv`
  (SHA-256 `34817b874dc16fb51d1995e11b97980e5998bfdef214b9744cc78824c1a7c215`
  including its header).
- Retained retired-instruction samples:
  `benchmarks/results/compiler_source_ast_finalize_diagnostics_instructions_2026-09-14.tsv`,
  SHA-256 `6c97a5586536099dfafb8c2ccd6b6959edb20b6db452b894c4c02fff2b612069`.
- Raw outputs:
  `/private/tmp/blorp-issue106-warm-results.VdywWI/{variant}-{workload}-{N}.out`.
- Raw hash manifest:
  `/private/tmp/blorp-issue106-warm-results.VdywWI/sha256.txt`, SHA-256
  `bce577c84d46a138040dbde2baa4b0425db5fba9418e1579225957e0b089acf1`.

The benchmark did not exist at the baseline revision. The identical candidate
harness was copied into an archive of the baseline source before both variants
were emitted with the common compiler and compiled with `cc -O2`.

## Reproduction

```bash
base_dir=$(mktemp -d /tmp/blorp-issue106-base.XXXXXX)
cand_dir=$(mktemp -d /tmp/blorp-issue106-candidate.XXXXXX)
out=$(mktemp -d /tmp/blorp-issue106-results.XXXXXX)
compiler=/Users/keithphilpott/CLionProjects/blorp/bin/blorp
harness=blorp/benchmark/compiler/compiler_source_ast_finalize_diagnostics_profile.brp

git archive 9ecb72e934c42f730fe15b5f3f05ee62a76db5f6 | tar -x -C "$base_dir"
git archive 51f3fd8fd7a8151afd7eab644883720fbbe823de | tar -x -C "$cand_dir"
cp "$harness" "$base_dir/$harness"
cp "$harness" "$cand_dir/$harness"
(cd "$base_dir" && "$compiler" compile --no-format -o "$out/baseline.c" "$harness")
(cd "$cand_dir" && "$compiler" compile --no-format -o "$out/candidate.c" "$harness")
cc -O2 "$out/baseline.c" -o "$out/baseline"
cc -O2 "$out/candidate.c" -o "$out/candidate"

printf 'workload\tsample\tvariant\telapsed_microseconds\ttotal_allocations\t' \
  > "$out/samples.tsv"
printf 'total_releases\tretained_objects\tast_checksum\tdiagnostic_checksum\n' \
  >> "$out/samples.tsv"
run_one() {
  variant=$1 workload=$2 sample=$3
  case "$workload" in
    clean) args=(5 1024 0 1 1) ;;
    dense) args=(5 1024 2 4 1) ;;
    heavy) args=(2 4096 3 8 1) ;;
  esac
  raw="$out/${variant}-${workload}-${sample}.out"
  "$out/$variant" "${args[@]}" > "$raw"
  line=$(cat "$raw")
  field() { printf '%s\n' "$line" | sed -E "s/.* $1=([^ ]+).*/\\1/"; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$workload" "$sample" "$variant" "$(field elapsed_microseconds)" \
    "$(field total_allocations)" "$(field total_releases)" \
    "$(field retained_objects)" "$(field ast_checksum)" \
    "$(field diagnostic_checksum)" >> "$out/samples.tsv"
}
for workload in clean dense heavy; do
  for n in 1 2 3 4 5 6 7; do
    if (( n % 2 )); then
      order=(baseline candidate)
    else
      order=(candidate baseline)
    fi
    for variant in "${order[@]}"; do
      run_one "$variant" "$workload" "$n"
    done
  done
done
shasum -a 256 "$out"/*.out "$out"/*.c "$out/baseline" "$out/candidate" \
  > "$out/sha256.txt"

# Run a second seven-pair alternating matrix for dense and heavy under the
# macOS process counter. Parse "instructions retired" from stderr into the
# retained instruction TSV.
/usr/bin/time -lp "$out/baseline" 2 4096 3 8 1 >/dev/null \
  2> "$out/baseline-heavy-1.instructions"
```

## Results

| Workload | Paired samples | Baseline median µs | Candidate median µs | Change | Baseline allocations | Candidate allocations | Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| clean | 7 | 2,099 | 1,639 | -21.92% | 35,950 | 25,710 | -28.48% |
| dense | 7 | 64,147 | 52,840 | -17.63% | 792,430 | 786,080 | -0.80% |
| heavy | 7 | 284,940 | 146,275 | -48.66% | 2,171,952 | 2,162,762 | -0.42% |

| Diagnostic workload | Baseline median retired instructions | Candidate median retired instructions | Change |
| --- | ---: | ---: | ---: |
| dense | 1,839,092,089 | 1,663,024,598 | -9.57% |
| heavy | 8,608,494,007 | 6,262,844,707 | -27.25% |

Every sample reported `workload_valid=True`. Allocations minus releases and
retained objects were identical between variants: 2,055 clean, 5,127 dense,
and 29,703 heavy. The clean/dense/heavy AST checksums were respectively
`94e33982...`, `4f75a65c...`, and `f7184e98...`; diagnostic checksums were
`e3b0c442...`, `d4580f28...`, and `0335b8e7...`, identical in each pair.

The dense workload produced 7,680 diagnostics and modeled 3,924,480 elements
recopied by the old growing-prefix concat. The heavy workload produced 21,504
diagnostics and modeled 44,018,688 old prefix copies. That prefix count is a
deterministic model of the baseline operation, not a hardware counter.

Validation passed the 23-test source-AST finalization suite, the owning
compiler check, manifest validation, and all 4,557 `compiler-blorp` tests.
