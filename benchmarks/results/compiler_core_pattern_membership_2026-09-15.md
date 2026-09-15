# Core Pattern Binding Membership

Issue 113 replaces two boolean
`core_pattern_bound_names(pattern).contains(name)` queries with one shared,
short-circuiting `core_pattern_binds_name` traversal. Ordered bound-name
projection remains unchanged for consumers that need the names.

## Decision

Accept. Both production consumers stopped allocating a bound-name list for
their boolean query. On 512-name patterns, allocations fell 99.5% at the
`compile_match_cases` boundary and 33.1% at the broader `convert_program`
boundary. The latter still performs an ordered projection while discovering
closure free variables; that separate list-producing use is intentionally
unchanged.

The two-name early-hit controls also improved. All paired runs preserved the
complete serialized production output, retained object count, and retained
bytes.

## Workloads And Results

The wide match rows use 10 iterations, 512 names per pattern, and 64 cases.
The wide closure rows use 5 iterations with the same width and cases. Each
median is from five alternating pairs after one warmup pair.

| Consumer / position | Baseline time | Candidate time | Time change | Baseline allocations | Candidate allocations | Allocation change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| match / early | 22,822 us | 125 us | -99.5% | 334,351 | 1,551 | -99.5% |
| match / late | 23,720 us | 1,869 us | -92.1% | 334,351 | 1,551 | -99.5% |
| match / miss | 23,842 us | 1,972 us | -91.7% | 334,351 | 1,551 | -99.5% |
| closure / early | 204,326 us | 196,515 us | -3.8% | 502,421 | 336,021 | -33.1% |
| closure / late | 204,040 us | 194,818 us | -4.5% | 502,421 | 336,021 | -33.1% |
| closure / miss | 205,651 us | 192,058 us | -6.6% | 502,421 | 336,021 | -33.1% |

The two-name early controls used one case. Match ran 1,000 iterations and
improved from 1,377 to 1,185 us with allocations falling from 27,001 to
24,001. Closure ran 500 iterations and improved from 2,583 to 2,519 us with
allocations falling from 41,001 to 39,501. Each control median uses seven
alternating pairs after one warmup pair; neither control regressed.

Releases fell by the same absolute amount as allocations in every workload.
Retained objects and bytes were identical within each pair: 4 objects / 224
bytes for match, 91 / 4,496 for the wide closure rows, and 28 / 2,016 for the
small closure control. All 88 measured runs reported `workload_valid=True`.
Paired samples are retained in
`compiler_core_pattern_membership_2026-09-15.tsv`.

## Fixture Boundary

The match shape reaches `core_name_may_occur_free` through
`compile_match_cases`: a named list spread encloses a `RawMatchExpr` whose
case patterns have the requested early, late, or absent target. The closure
shape reaches `expr_consumes_var` through `convert_program`: a detached task
captures the target, then consumption analysis scans the same raw-match
patterns. Fixture construction, warmup, and JSON observation are outside the
measurement window.

The modeled comparison count describes the new predicate. Baseline always
materializes every name before `contains`, including on an early hit. Candidate
early-hit rows visit one name per query; late and miss rows visit the full
width. The benchmark calls only public production boundaries and introduces
no profiling API into compiler code.

The all-variant regression compares direct membership with
`core_pattern_bound_names(pattern).contains(target)` over names, constructors,
qualified constructors, tuples, lists and nested spreads, or-patterns,
wildcards, literals, duplicates, early hits, late hits, and misses.

## Output Identity

Every pair required identical full-result JSON length and checksum. A separate
compiler-level check compiled the same absolute `examples/at_a_glance.brp`
input with both compilers. Final Core dumps were byte-identical with SHA-256
`ec6b392c953fb32250bac6174ff52f0c13a9b76eaddae1a58782c1a1c7a37501`;
generated C was byte-identical with SHA-256
`4be553ea3f6dd20748dc3c3f6ae57343a8c7e76102175063ae1e99e272ffce75`.

## Provenance And Reproduction

Both variants derive from revision
`f6af78c039d1b9b362aa5f6f4e334c938e9254f7` plus the accepted Issue 112
worktree changes. The Issue 113 baseline/candidate source SHA-256 values are:

| Module | Baseline | Candidate |
| --- | --- | --- |
| `traverse.brp` | `5aeeeaeef1173cce220fb8906f16825cb236dafe1c54a17b2db71e2f5ddff16d` | `52ee9fc6463f3096fa7e0a6d65445f01b5279c8bb71d01f8ba05d053f69d347f` |
| `closure.brp` | `def1e6f3b629a420ff0aa58ca528f83de286aacab2be511e44e8cb5db194c1c0` | `703ed1275b0557b7dcce888867025a896ac23c4611fcc0a67ed4669ed5b3b08a` |
| `match_lowering.brp` | `f2e3bd590e2c31847d9d8779d596558da5b0261707519df68f2847581e5bfb71` | `cbfbb7576402ca0e59e2f5d19369f97dfc1e81d524c0422f926170a869cb2b6b` |

The same fresh pre-Issue-113 compiler compiled both benchmark variants. Its
SHA-256 was
`a8ae574dcdb788955c224cca90e7b9978c42f09fd2e424fc34fb652680877d2c`.
The plain baseline/candidate benchmark binaries were
`733ff4fdac1e01c396c98f0ae13aeb3bd989429e9923a15785b20d22c28206f1`
and
`0e66283c91eb950750c2f30e64c5aba89a483ed473a9e3fd1e4baaa360900131`.
The benchmark driver SHA-256 was
`3354bfd2199a9d7b2b4bc32e230d3ea62512e034d4c9fcf0f45b9dd180f26cd9`;
the fixture SHA-256 was
`ae89ac2af62fb76daa241bf5257506fc8918329553e20d563e2b7d149d04d50d`.

To reconstruct both trees after this result is committed, resolve the commit
that added this report, create two detached worktrees, and reverse only Issue
113 in the baseline tree:

```bash
issue113_root=$(mktemp -d /tmp/blorp-issue113.XXXXXX)
candidate_root="$issue113_root/candidate"
baseline_root="$issue113_root/baseline"
candidate_revision=$(git log --diff-filter=A --format=%H -- \
  benchmarks/results/compiler_core_pattern_membership_2026-09-15.md | head -1)
git worktree add --detach "$candidate_root" "$candidate_revision"
git worktree add --detach "$baseline_root" "$candidate_revision"

python3 - "$baseline_root" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
traverse = root / "blorp/src/compiler/stage_09_core/traverse.brp"
text = traverse.read_text()
start = text.index("pure func core_pattern_binds_name(")
end = text.index("pure func core_pattern_bound_names(", start)
traverse.write_text(text[:start] + text[end:])

closure = root / "blorp/src/compiler/stage_09_core/closure.brp"
text = closure.read_text()
replacements = [
    (
        "traverse: core_pattern_binds_name, core_pattern_bound_names, ",
        "traverse: core_pattern_bound_names, ",
    ),
    (
        "core_pattern_binds_name(case.pattern, variable.name)",
        "core_pattern_bound_names(case.pattern).contains(variable.name)",
    ),
]
for candidate, baseline in replacements:
    assert text.count(candidate) == 1
    text = text.replace(candidate, baseline)
closure.write_text(text)

lowering = root / "blorp/src/compiler/stage_09_core/match_lowering.brp"
text = lowering.read_text()
candidate = ".core_pattern_binds_name(match_case.pattern, name)"
baseline = (
    ".core_pattern_bound_names(match_case.pattern)\n"
    + "\t" * 10
    + ".contains(name)"
)
assert text.count(candidate) == 1
lowering.write_text(text.replace(candidate, baseline))
PY

(cd "$baseline_root" && shasum -a 256 \
  blorp/src/compiler/stage_09_core/{traverse,closure,match_lowering}.brp)
(cd "$candidate_root" && shasum -a 256 \
  blorp/src/compiler/stage_09_core/{traverse,closure,match_lowering}.brp)
```

Build one compiler, then use it for both benchmark variants so compiler
differences stay outside the measured comparison:

```bash
make -C "$baseline_root"
benchmark_compiler="$baseline_root/bin/blorp"

for variant in baseline candidate; do
  if [ "$variant" = baseline ]; then
    tree="$baseline_root"
  else
    tree="$candidate_root"
  fi
  BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  BLORP_COMPILER_BENCHMARK_COMPILER="$benchmark_compiler" \
  BLORP_BENCHMARK_CACHE_DIR="$issue113_root/$variant-cache" \
    "$tree/benchmarks/compiler_core_pattern_membership_profile" \
      plain match miss 1 8 2
done

baseline=$(find "$issue113_root/baseline-cache" -type f \
  -name compiler-core-pattern-membership-profile -perm -111 -print -quit)
candidate=$(find "$issue113_root/candidate-cache" -type f \
  -name compiler-core-pattern-membership-profile -perm -111 -print -quit)
```

Run paired samples from the candidate tree:

```bash
(cd "$candidate_root" && benchmarks/compiler_pass_compare \
  --label issue113-match-miss \
  --baseline-bin "$baseline" --candidate-bin "$candidate" \
  --baseline-source-root "$baseline_root" \
  --candidate-source-root "$candidate_root" --allow-dirty-source \
  --fixture blorp/benchmark/compiler/compiler_core_pattern_membership_profile.brp \
  --fixture blorp/benchmark/compiler/compiler_core_pattern_membership_profile_fixture.brp \
  --prefix CORE_PATTERN_MEMBERSHIP_PROFILE \
  --time-field elapsed_microseconds \
  --checksum-field semantic_checksum \
  --stable-field semantic_bytes --stable-field consumer \
  --stable-field position --stable-field iterations --stable-field width \
  --stable-field cases --stable-field expected_comparisons \
  --stable-field workload_valid \
  --metric-field allocations --metric-field releases \
  --metric-field retained_objects --metric-field allocator_bytes \
  --pairs 5 --warmup-pairs 1 \
  --results "$issue113_root/issue113-match-miss.json" \
  --json -- match miss 10 512 64)
```

Repeat for the other table rows. For compiler-level identity, build the
candidate compiler and compile one identical absolute input with both:

```bash
make -C "$candidate_root"
input="$candidate_root/examples/at_a_glance.brp"
for variant in baseline candidate; do
  if [ "$variant" = baseline ]; then
    compiler="$baseline_root/bin/blorp"
  else
    compiler="$candidate_root/bin/blorp"
  fi
  (cd "$candidate_root" && "$compiler" compile --no-format --dump-core \
    --dump-core-file="$issue113_root/semantic-core-$variant.txt" \
    -o "$issue113_root/semantic-c-$variant.c" "$input")
done
cmp "$issue113_root"/semantic-core-{baseline,candidate}.txt
cmp "$issue113_root"/semantic-c-{baseline,candidate}.c
shasum -a 256 "$issue113_root"/semantic-core-*.txt \
  "$issue113_root"/semantic-c-*.c
```

## Validation

- predicate regression: 8/8 Core traversal tests;
- Core match: 32/32;
- Core closure: 8/8;
- benchmark typecheck: passed;
- all eight retained workload shapes: `workload_valid=True` with identical
  same-shape semantic checksums and serialized sizes;
- generated Core and C identity: byte-identical;
- `scripts/compiler-check --changed`: passed three sources, five suites, Core
  sanitizer, and leak checks in 162.15 seconds;
- `scripts/test compiler-blorp`: passed 4,577/4,577 tests in 3m20s;
- `scripts/compiler-build-status`: `FRESH` after the broad gates;
- `git diff --check`: passed.
