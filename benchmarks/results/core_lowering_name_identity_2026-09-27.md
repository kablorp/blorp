# Core lowering name identity pair-match pilot (2026-09-27)

## Boundary and hypothesis

`resolve_name_expr_def_id` reconciles the callable ID encoded in a name with
the ID supplied by resolved-call metadata. Its `match (encoded_id,
resolved_id)` built one heap tuple and boxed both `Option[Int]` elements on
every `TypedNameExpr`. A nested match can branch on the two stack Options
directly, while retaining the original returned Option and the exact conflict
diagnostic. This changes only lowering's implementation of the identity
comparison; it does not cache by definition ID or change the identity rule.

An opt-in attribution-only build split the `TypedNameExpr` node cost into
`NameExpr.reconcile_id` and neighboring steps. With
`BLORP_CORE_LOWERING_TYPE_METRICS=1`, the final cumulative row was
`calls=277660 self_allocations=1110640`: exactly four allocations per name
reference. The generated C showed the input tuple and its two boxed Options,
plus one boxed returned Option. Removing only the input triple predicted
832,980 fewer lowering allocations. The profiling variable on and off gave
the identical `core_lowering_input_ready` to `core_lowering_complete` delta
of 18,250,923 allocations; the temporary attribution labels were removed
from the candidate. Raw logs are
`/tmp/blorp-lowering-name-{off,on}.stderr`.

## Provenance and commands

- Base and frozen input: `5a1219af7f9167de08c56df3f2232fc7b15fa743`.
- Baseline: FRESH stage-1 `/Users/keithphilpott/CLionProjects/blorp/bin/blorp`,
  SHA-256 `fe4aec31b11b29f2146b83db6b41154ba22ca8069c853e996e069667ac5c354f`.
- Candidate: FRESH stage-1 `bin/blorp` in the pilot worktree, SHA-256
  `37aaa65012bf3399b20526b76ac4cec1d4d677e2e3c96502ed2702aeff3427ba`.
- Both binaries: Apple clang 21.0.0, `cli=-O2 runtime=-O2`, 8-way split;
  measured output C used the harness default `-O0` host-C setting. The
  candidate binary was rebuilt after the final source comment and reported
  FRESH before the final runs.
- Baseline JSON: `/tmp/blorp-core-rewrite-current-main-{self,small}.json`;
  final candidate JSON: `/tmp/blorp-lowering-name-final-{self,small}.json`.

```bash
BLORP_CLI_C_OPTIMIZATION=-O2 make
scripts/compiler-build-status
bin/blorp test --timeout 180 blorp/test/compiler/stage_08_core_lower/test_core_lower.brp
benchmarks/self_compile_measure --compiler bin/blorp \
  --input-rev 5a1219af7f9167de08c56df3f2232fc7b15fa743 \
  --program self --label lowering-name-match-final --samples 3 \
  --baseline /tmp/blorp-core-rewrite-current-main-self.json \
  --output /tmp/blorp-lowering-name-final-self.json --require-identical
benchmarks/self_compile_measure --compiler bin/blorp \
  --input-rev 5a1219af7f9167de08c56df3f2232fc7b15fa743 \
  --program small --label lowering-name-match-final-small --samples 5 \
  --baseline /tmp/blorp-core-rewrite-current-main-small.json \
  --output /tmp/blorp-lowering-name-final-small.json --require-identical
scripts/compiler-check --changed --base main
blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh bin/blorp --jobs 1
```

The initial harness attempt used `--input-dir` and canonicalized the frozen
path from `/var` to `/private/var`, changing path-bearing generated C and
making that attempt incomparable. The accepted runs use `--input-rev`, which
retains the baseline's exact frozen path. Commands ran serially.

## Results

| program | lowering allocations, baseline → candidate | change | output C SHA-256, both runs | retired instructions, min | source-discovery allocations |
| --- | ---: | ---: | --- | ---: | ---: |
| self | 18,250,923 → 17,417,943 | -832,980 (-4.56%) | `2be89ae0e9eed650e84c36937ed8edb30f98975c682bd11ba7199b70fa029485` | 150,946,703,524 → 150,813,239,190 (-0.09%) | 8,484,868 → 8,509,872 (+25,004) |
| small | 225,620 → 216,692 | -8,928 (-3.96%) | `6f2a9556f4ff0baaf899211a2b4cb197b27958885e89016df0131287607551ae` | 1,089,370,269 → 1,086,288,105 (-0.28%) | 178,554 → 178,701 (+147) |

Generated C is byte-identical in each baseline/candidate pair: 78,679,647
bytes for self and 40,918 bytes for small. Every downstream phase's
allocation delta is unchanged. The source-discovery allocation increases
occur before typed-to-Core lowering and remain unexplained; they prevent
claiming the full compiler's allocation change is exclusively this cut.
Instruction differences are small and are not a standalone speed claim.

The new generated C for `resolve_name_expr_def_id` branches directly on
stack `Option[Int]` tags. It no longer constructs the pair tuple or the two
input Option boxes; the one boxed returned Option remains. The result is
exactly the predicted three allocations saved per 277,660 self-compile name
references.

## Correctness gates

- Focused Core lowering suite: 148 passed, including new matching-ID
  coverage and an exact diagnostic assertion for conflicting IDs.
- `scripts/compiler-check --changed --base main`: 2,320 passed, 0 failed;
  includes the Core sanitizer gate.
- Direct generated-C audit with `--jobs 1`: 221 passed, 0 failed.
- `git diff --check`: passed.
- Independent test-runner, FRESH `-O2`, all serial: focused Core lowering
  148/148, `compiler-blorp` 5,165/5,165, Core sanitizer 2,172/2,172.
- Independent code review: 0 actionable findings.

No merge or push was performed.
