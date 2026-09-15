# Inference Constructor Coverage Index

Issue 114 replaces recursively materialized, repeatedly scanned constructor-name
lists with one invocation-local membership dictionary and one iterative pattern
worklist. The measured boundary is production `infer_expr` match inference, not
a model of the private helper.

## Decision

Accept the candidate. On the duplicate-heavy wide workload, median retired
instructions fell 14.60% and median measurement-window time fell 19.33%. The
two-constructor control changed by +0.47% in retired instructions and -1.28% in
measurement-window time, both inside the 3% guardrail. Exact profiling reported
zero dictionary copies.

The dictionary is membership-only. Missing variants are still emitted by
iterating the union declaration's `all_names`, so diagnostic order cannot depend
on dictionary iteration. The worklist appends only `TypedOrPattern`
alternatives; it intentionally does not descend into constructor payloads.

## Workloads and results

Seven managed-counter pairs followed one warmup pair and alternated execution
order. Five separate `/usr/bin/time -lp` pairs also alternated order. Fixture
construction, warmup, exact diagnostic observation, and typed-case observation
were outside the measurement window. Values below are medians.

| Workload | Arguments | Baseline | Candidate | Change |
| --- | --- | ---: | ---: | ---: |
| duplicate-heavy instructions | `50 16 64 128 4` | 1,137,134,142 | 971,139,520 | -14.60% |
| duplicate-heavy elapsed | `50 16 64 128 4` | 52,954 us | 42,717 us | -19.33% |
| duplicate-heavy allocations | `50 16 64 128 4` | 738,901 | 685,451 | -7.23% |
| two-constructor instructions | `10000 1 2 2 1` | 1,078,030,054 | 1,083,084,785 | +0.47% |
| two-constructor elapsed | `10000 1 2 2 1` | 48,801 us | 48,174 us | -1.28% |
| two-constructor allocations | `10000 1 2 2 1` | 820,001 | 810,001 | -1.22% |

The five process-timed pairs independently produced a duplicate-heavy median
of 1,137,134,142 versus 971,139,520 instructions (-14.60%) and a control median
of 1,078,030,054 versus 1,083,084,785 (+0.47%). Their in-process elapsed medians
were 53,595 versus 42,542 microseconds (-20.62%) and 48,830 versus 48,374
microseconds (-0.93%), respectively.

All samples reported the same exact diagnostic checksum
`-6678540278359703321`, the expected typed match-case count, and
`workload_valid=True`. Retained objects were 3 for both variants. Retained
allocator bytes were 288 for both variants. Releases fell by the same absolute
amount as allocations.

Raw paired samples are retained in
`compiler_infer_constructor_coverage_2026-09-15.tsv`.

## Mechanism evidence

The duplicate-heavy exact-profile run used one iteration, 16 cases, 64
alternatives per case, 128 unique constructors, and duplicate stride 4. The
baseline recursively called `typed_pattern_constructor_names` 1,040 times and
then performed a second case-level deduplication. The candidate made one
`match_case_constructor_name_index` call, 1,024 dictionary admissions, and 129
dictionary membership queries (128 declared constructors plus the sentinel).

Runtime copy counters were:

| Variant | Dict copies | Dict entries copied | List copies | List entries copied |
| --- | ---: | ---: | ---: | ---: |
| baseline | 0 | 0 | 140 | 1,304 |
| candidate | 0 | 0 | 93 | 3,020 |

The candidate's larger list-entry count is geometric growth of the single
worklist, not nested result-list construction. The zero dictionary-copy count
confirms that `Dict.set` receives unique ownership rather than cloning COW
state. Generated C likewise transfers `seen` directly into the specialized
dictionary update before `blorp_dict_cow`; it does not retain `seen` first.

The complexity analyzer's seven target findings disappeared:

- two growing-accumulator findings (reported degree 4);
- two linear scans inside nested traversals (reported degree 3);
- the `all_names * seen_names` membership scan; and
- two dependent nested traversals.

No finding names `typed_pattern_constructor_names`,
`match_case_constructor_names`, `match_case_constructor_name_index`, or
`missing_constructor_names` in the candidate output. Unrelated Core constructor
catalog findings are outside this issue.

## Correctness

The regression combines a nested `or`, qualified and unqualified outer
constructors, duplicate alternatives and cases, and a nested constructor
payload. It requires the byte-exact diagnostic:

```text
Non-exhaustive match on OuterChoice: missing OuterLater, OuterLast
```

The nested payload deliberately uses an inner constructor also named
`OuterLater`. This proves that `OuterWrap(IC.OuterLater(_))` contributes only
`OuterWrap`, and that missing names remain in union declaration order. The
pre-existing Option diagnostic is now also checked for exact equality rather
than substring containment.

## Provenance

Both source trees derive from revision
`bdce2c5a9c8161c00e17ef30a8933d3c467d1a59`. Baseline and candidate
`infer.brp` SHA-256 values are
`1f1dd4bff6c35857a3c587175627a7e7a63fcab62dd644223ce3b84a51b12f06`
and
`91e80f849f4754179215682d15fe5d9c66d8f728e4d7a261c9f632329b65fa8f`.
The benchmark driver and fixture SHA-256 values are
`5fee5bc38f59eb5a3afd318892dbd618d65318cfbcbd3f56a55b21f41577eac2`
and
`9fc6ad91479dc33ba5fdc09286f5b85f4644cbf74f39758dd8551c36ee873c23`.

The measured plain binaries are `/tmp/blorp_issue114_artifacts/accepted-baseline`
(`9eb7ca657821f9024ca3a0f48237d435bf91419478af8cdf2239a868260b652a`)
and `/tmp/blorp_issue114_artifacts/accepted-candidate`
(`07129f7c14ba9347e0a0646318b248c586c659cb2db4deec89205d7df3054eeb`).
Profile binary SHA-256 values are
`30213f65248917cabc9a70b7795d4ca6d67d1e71fcd8d7fcb43955ea753586a9`
and
`9a89a96ece8e9572004e6bed55549bc6ad057323f8d6f2d3a7ff5a9122242b90`.
The baseline/candidate complexity JSON hashes are
`0149de7042a6d9a44a7539dc04a1fbd4bd9c6cc66ec8ca2220222cc17957c293`
and
`93a42d2b34040bb8ba29c0ba326e38a9a1d5b9ba180f798e370d11840e7c5868`.
The retained paired-sample TSV SHA-256 is
`28fbf46138f68d486ab4fdc68f3dea956554d2c3b976c319ccd8e6505defc571`.

Measurements ran on Darwin 25.6.0 arm64 with Apple clang 21.0.0.

## Reproduction

Use underscore-only temporary checkout names. The compiler currently projects
absolute module paths into generated C identifiers, so a hyphen in a temporary
worktree name can make the generated C invalid.

```bash
issue114_commit=$(git log -1 --format=%H -- \
  benchmarks/results/compiler_infer_constructor_coverage_2026-09-15.md)
issue114_root=/tmp/blorp_issue114_reproduction
mkdir -p "$issue114_root/worktrees" "$issue114_root/artifacts"
git worktree add --detach "$issue114_root/worktrees/candidate" "$issue114_commit"
git worktree add --detach "$issue114_root/worktrees/baseline" "$issue114_commit^"

for file in \
  compiler_infer_constructor_coverage_profile.brp \
  compiler_infer_constructor_coverage_profile_fixture.brp; do
  cp "$issue114_root/worktrees/candidate/blorp/benchmark/compiler/$file" \
    "$issue114_root/worktrees/baseline/blorp/benchmark/compiler/$file"
  cmp "$issue114_root/worktrees/candidate/blorp/benchmark/compiler/$file" \
    "$issue114_root/worktrees/baseline/blorp/benchmark/compiler/$file"
done

make -C "$issue114_root/worktrees/baseline"
make -C "$issue114_root/worktrees/candidate"
unset BLORP_STD

for variant in baseline candidate; do
  tree="$issue114_root/worktrees/$variant"
  "$tree/bin/blorp" compile --no-format \
    -o "$issue114_root/artifacts/$variant.c" \
    "$tree/blorp/benchmark/compiler/compiler_infer_constructor_coverage_profile.brp"
  cc -O2 -fwrapv -pipe -w \
    -I"$tree/blorp/src/compiler/stage_04_modules" \
    -I"$tree/blorp/src/compiler/stage_06_typecheck/graph" \
    "$issue114_root/artifacts/$variant.c" -lm -lpthread \
    -o "$issue114_root/artifacts/$variant"
done

"$issue114_root/worktrees/candidate/benchmarks/compiler_pass_compare" \
  --label issue114-duplicates \
  --baseline-bin "$issue114_root/artifacts/baseline" \
  --candidate-bin "$issue114_root/artifacts/candidate" \
  --baseline-source-root "$issue114_root/worktrees/baseline" \
  --candidate-source-root "$issue114_root/worktrees/candidate" \
  --allow-dirty-source \
  --fixture-source blorp/benchmark/compiler/compiler_infer_constructor_coverage_profile.brp \
  --fixture-source blorp/benchmark/compiler/compiler_infer_constructor_coverage_profile_fixture.brp \
  --prefix INFER_CONSTRUCTOR_COVERAGE_PROFILE \
  --time-field elapsed_microseconds \
  --checksum-field error_checksum \
  --stable-field workload_valid \
  --stable-field error_count \
  --stable-field typed_case_count \
  --stable-field expected_pattern_visits \
  --metric-field allocations --metric-field releases \
  --metric-field retained_objects --metric-field allocator_bytes \
  --pairs 7 --warmup-pairs 1 \
  --results "$issue114_root/artifacts/duplicates.json" \
  --json -- 50 16 64 128 4

"$issue114_root/worktrees/candidate/benchmarks/compiler_pass_compare" \
  --label issue114-control \
  --baseline-bin "$issue114_root/artifacts/baseline" \
  --candidate-bin "$issue114_root/artifacts/candidate" \
  --baseline-source-root "$issue114_root/worktrees/baseline" \
  --candidate-source-root "$issue114_root/worktrees/candidate" \
  --allow-dirty-source \
  --fixture-source blorp/benchmark/compiler/compiler_infer_constructor_coverage_profile.brp \
  --fixture-source blorp/benchmark/compiler/compiler_infer_constructor_coverage_profile_fixture.brp \
  --prefix INFER_CONSTRUCTOR_COVERAGE_PROFILE \
  --time-field elapsed_microseconds \
  --checksum-field error_checksum \
  --stable-field workload_valid --stable-field error_count \
  --stable-field typed_case_count --stable-field expected_pattern_visits \
  --metric-field allocations --metric-field releases \
  --metric-field retained_objects --metric-field allocator_bytes \
  --pairs 7 --warmup-pairs 1 \
  --results "$issue114_root/artifacts/control.json" \
  --json -- 10000 1 2 2 1
```

The following loop performs the independently alternating process samples and
retains every raw output. It also derives the process rows later combined with
the managed-counter JSON; it does not rely on copying the table above.

```bash
process_tsv="$issue114_root/artifacts/process.tsv"
printf '%b\n' \
  'measurement\tworkload\tpair\tvariant\titerations\tcases\toptions\tunique\tduplicate_stride\texpected_pattern_visits\telapsed_microseconds\tallocations\treleases\tretained_objects\tallocator_bytes\terror_checksum\ttyped_case_count\tinstructions_retired\tcycles_elapsed\tmaximum_rss_bytes' \
  > "$process_tsv"

for workload in duplicates control; do
  if [[ "$workload" == duplicates ]]; then
    workload_args=(50 16 64 128 4)
  else
    workload_args=(10000 1 2 2 1)
  fi

  for pair in 1 2 3 4 5; do
    if (( pair % 2 == 1 )); then
      variants=(baseline candidate)
    else
      variants=(candidate baseline)
    fi

    for variant in "${variants[@]}"; do
      output="$issue114_root/artifacts/$workload-$pair-$variant.out"
      timing="$issue114_root/artifacts/$workload-$pair-$variant.time"
      /usr/bin/time -lp "$issue114_root/artifacts/$variant" \
        "${workload_args[@]}" > "$output" 2> "$timing"
    done

    # Normalize retained rows after preserving alternating execution order.
    for variant in baseline candidate; do
      output="$issue114_root/artifacts/$workload-$pair-$variant.out"
      timing="$issue114_root/artifacts/$workload-$pair-$variant.time"
      instructions=$(awk '/instructions retired/{print $1}' "$timing")
      cycles=$(awk '/cycles elapsed/{print $1}' "$timing")
      rss=$(awk '/maximum resident set size/{print $1}' "$timing")
      awk -v workload="$workload" -v pair="$pair" -v variant="$variant" \
        -v instructions="$instructions" -v cycles="$cycles" -v rss="$rss" '
          /^INFER_CONSTRUCTOR_COVERAGE_PROFILE / {
            for (field_index = 2; field_index <= NF; field_index++) {
              split($field_index, item, "=")
              field[item[1]] = item[2]
            }
            printf "process\t%s\t%s\t%s", workload, pair, variant
            names = "iterations cases options unique duplicate_stride expected_pattern_visits elapsed_microseconds allocations releases retained_objects allocator_bytes error_checksum typed_case_count"
            count = split(names, ordered, " ")
            for (ordered_index = 1; ordered_index <= count; ordered_index++) {
              printf "\t%s", field[ordered[ordered_index]]
            }
            printf "\t%s\t%s\t%s\n", instructions, cycles, rss
          }
        ' "$output" >> "$process_tsv"
    done
  done
done
```

Derive the complete retained TSV and verify that every sample is semantically
valid. `NA` marks the retired-instruction, cycle, and RSS fields on managed rows
because those counters are supplied only by `/usr/bin/time`.

```bash
samples_tsv="$issue114_root/artifacts/all-samples.tsv"
head -n 1 "$process_tsv" > "$samples_tsv"
for workload in duplicates control; do
  jq -e '[.raw_pairs[] | .baseline.workload_valid and .candidate.workload_valid] | all' \
    "$issue114_root/artifacts/$workload.json" >/dev/null
  jq -r --arg workload "$workload" '
    .raw_pairs[] | (.pair + 1) as $pair |
    ["baseline", "candidate"][] as $variant | .[$variant] |
    ["managed", $workload, $pair, $variant, .iterations, .cases, .options,
     .unique, .duplicate_stride, .expected_pattern_visits,
     .elapsed_microseconds, .allocations, .releases, .retained_objects,
     .allocator_bytes, .error_checksum, .typed_case_count, "NA", "NA", "NA"] |
    @tsv
  ' "$issue114_root/artifacts/$workload.json" >> "$samples_tsv"
done
tail -n +2 "$process_tsv" >> "$samples_tsv"
awk -F '\t' 'NF != 20 { exit 1 }' "$samples_tsv"
```

Rebuild at `-O0` with exact profiling, run the duplicate-heavy shape once, and
extract the function and collection-copy counters. The final search checks the
generated candidate C around the dictionary COW boundary.

```bash
for variant in baseline candidate; do
  tree="$issue114_root/worktrees/$variant"
  "$tree/bin/blorp" compile --profile --no-format \
    -o "$issue114_root/artifacts/$variant-profile.c" \
    "$tree/blorp/benchmark/compiler/compiler_infer_constructor_coverage_profile.brp"
  cc -O0 -fwrapv -pipe -w \
    -I"$tree/blorp/src/compiler/stage_04_modules" \
    -I"$tree/blorp/src/compiler/stage_06_typecheck/graph" \
    "$issue114_root/artifacts/$variant-profile.c" -lm -lpthread \
    -o "$issue114_root/artifacts/$variant-profile"
  "$issue114_root/artifacts/$variant-profile" 1 16 64 128 4 \
    > "$issue114_root/artifacts/$variant-profile.out" \
    2> "$issue114_root/artifacts/$variant-profile.log"
done

rg 'typed_pattern_constructor_names|match_case_constructor_names|match_case_constructor_name_index|dict__set|dict__contains|COLLECTION_COPY_PROFILE_COUNTERS' \
  "$issue114_root/artifacts/"*-profile.log

candidate_log="$issue114_root/artifacts/candidate-profile.log"
candidate_c="$issue114_root/artifacts/candidate-profile.c"
coverage_symbol=$(awk '/match_case_constructor_name_index /{print $2; exit}' "$candidate_log")
dict_set_symbol=$(awk '/^dict__set__mono_sig.*String.*Bool /{print $2; exit}' "$candidate_log")

awk -v signature="static blorp_Dict* $coverage_symbol(" '
  index($0, signature) == 1 && /\{$/ { emit = 1 }
  emit { print NR ":" $0 }
  emit && /^}/ { exit }
' "$candidate_c" | rg -C 4 'seen = .+\(seen, name->text, 1\)'

awk -v signature="static blorp_Dict* $dict_set_symbol(" '
  index($0, signature) == 1 && /\{$/ { emit = 1 }
  emit { print NR ":" $0 }
  emit && /^}/ { exit }
' "$candidate_c" | rg -C 4 'cleanup_pop_slot\(&self\)|blorp_dict_cow'
```

Finally, reproduce the static analysis and print hashes for every artifact used
to reach the decision:

```bash
for variant in baseline candidate; do
  tree="$issue114_root/worktrees/$variant"
  (
    cd "$tree"
    scripts/complexity-check blorp/src/main.brp \
      --module-prefix blorp/src/compiler/ --json
  ) > "$issue114_root/artifacts/complexity-$variant.json"
done

shasum -a 256 \
  "$issue114_root/artifacts/baseline" \
  "$issue114_root/artifacts/candidate" \
  "$issue114_root/artifacts/baseline-profile" \
  "$issue114_root/artifacts/candidate-profile" \
  "$issue114_root/artifacts/duplicates.json" \
  "$issue114_root/artifacts/control.json" \
  "$issue114_root/artifacts/all-samples.tsv" \
  "$issue114_root/artifacts/complexity-baseline.json" \
  "$issue114_root/artifacts/complexity-candidate.json" \
  "$issue114_root/worktrees/baseline/blorp/src/compiler/stage_06_typecheck/infer.brp" \
  "$issue114_root/worktrees/candidate/blorp/src/compiler/stage_06_typecheck/infer.brp" \
  "$issue114_root/worktrees/candidate/blorp/benchmark/compiler/compiler_infer_constructor_coverage_profile.brp" \
  "$issue114_root/worktrees/candidate/blorp/benchmark/compiler/compiler_infer_constructor_coverage_profile_fixture.brp"
```

## Validation

- focused inference suite: 312/312 passed;
- `scripts/compiler-check --changed`: passed one source and both owning suites
  in 9.85 seconds;
- `scripts/test compiler-blorp`: passed 4,635/4,635 tests in 3m28s;
- benchmark control and duplicate-heavy workloads: valid with exact diagnostic
  checksum and typed-case count identity;
- one-option fixture shape: both variants report two expected visits for two
  direct-pattern cases and `workload_valid=True`;
- production and benchmark Blorp files pass `bin/blorp format --check`; the
  added test hunks match formatter output, while the complete legacy test file
  retains unrelated pre-existing formatting drift;
- benchmark launcher passes `bash -n`;
- `git diff --check`: passed.
