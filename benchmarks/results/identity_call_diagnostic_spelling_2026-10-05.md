# Call diagnostic spelling authority

Status: focused and broader compiler/tooling gates, generated-C inspection,
matched stage-2 measurements and independent code review passed. This record
makes no speedup claim.

## Change and boundary

`infer.brp`'s private `call_name` now takes `IdentifierSpellings` and delegates to
existing `identifier_spelling`. The arity and argument mismatch diagnostic callers
pass the authority from `context.state.facts.identifier_spellings`. No authority,
resolver, stored spelling, or lookup mode was added. Both messages retain their
existing format when identifier ids and compatibility text agree.

The test fixture gives the named callee a valid table id spelling `increment`
while retaining compatibility text `add_one` for the existing standalone Env
lookup. Separate tests assert complete ordered error lists for arity and Int/String
argument mismatch. An explicit `SpellingsFromIdentifierText` test verifies both
messages retain `add_one` even with the same mismatched id.

Existing table-mode missing-id fallback (`name_spelling_or_text`) is preserved.
This slice proves valid-id canonical precedence; it does not tighten that policy.

## Provenance

- Parent/source input: `ff4da4b31dc2f5e0e1b9425a2ac96c06f6399a63`.
- Worktree: `<worktree:identity-roadmap-vet>`.
- Candidate build: `BLORP_CLI_C_OPTIMIZATION=-O2 make`, exit 0; status FRESH.
- Toolchain: bootstrap `dev-c3040e79c7d8`; Apple clang 21.0.0
  (`clang-2100.3.34.2`); CLI/runtime `-O2`; normal runtime diagnostics disabled.
- Baseline binary SHA-256:
  `3ecd2fb3c08d13588ef495102a29fbd38eb2818149998fe68756cfce29aa6da5`.
- Candidate binary SHA-256:
  `11664cad06210226480e559b4c03ccf2a3bae5c3a9f8244d77e80d9b702a032b`.
- Candidate `infer.brp` SHA-256:
  `125bb68ef0a597a015dc6e1aaf6b526728d517dde42f08160ff83967d389b93b`.
- Final `test_infer.brp` SHA-256:
  `9b3a50f54bd33f2055182ede73dbfe029d74ef235642c6613f7f5d60026170e3`.

## Tests

All commands ran serially with the repository `bin/blorp` after a fresh build.
Raw artifacts are under `/tmp/blorp-identity-execution-20261005/`.

| Command | Before implementation | After implementation |
| --- | --- | --- |
| `bin/blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_infer.brp` | 337 pass, 2 fail | 339 pass, 0 fail |
| `bin/blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_typecheck_state.brp` | Not rerun in this slice | 27 pass, 0 fail |
| `bin/blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_typed_name_identity.brp` | Not rerun in this slice | 2 pass, 0 fail |

Before log `name-display-before.log` failed only the new table-backed arity and
argument tests. Existing direct-call messages and explicit standalone mode passed.
Candidate logs: `name-display-after-infer.log`, `name-display-after-state.log`,
`name-display-after-identity.log`. Final test-only formatter changes were rerun in
`name-display-after-infer-formatted.log`: all 339 pass, exit 0.

`git diff --check` passes. `format --check` flags both edited files; exact HEAD
copies also fail (`name-display-format-before.log`), starting with preexisting
import ordering. Only the new test region and registrations were formatted.
The production helper/diagnostic region already matches formatter output. No
unrelated formatting cleanup was applied.

## Generated C

Exact helper snapshots: `name-display-helper-before.c` and
`name-display-helper-after.c` in the raw artifact directory. The bootstrap-generated
candidate helper (`brp_1NL`) borrows `IdentifierSpellings` and `TypedExpr` pointers.
Its typed-name arm calls existing spelling projection `brp_gQ` with the name id
and compatibility text. The helper contains no retain, release, or cleanup calls.

Both diagnostic callers directly pass the existing facts authority field:

```c
brp_1NL(brp_v_13EX->f0->f5->f8, brp_v_13Fl);
brp_1NL(brp_v_13Mq->f0->f5->f8, brp_v_13MO);
```

These appear at `split_body_1.c` lines 155829 and 155898 in the candidate build.
There is no context/authority copy or retain at these call sites. The existing
spelling projection borrows the table and retains the returned String; its
standalone arm retains compatibility text as the baseline helper did. Lookup is
confined to diagnostic formatting; successful-call inference is unchanged.

## Matched stage-2 measurements

The [complete measurement records](identity_call_diagnostic_measurements_2026-10-05.json)
retain all samples, checkpoints, output hashes and toolchain fingerprints.
Baseline and candidate normal/diagnostic pairs are stage 2, CLI/runtime `-O2`,
Apple clang 21.0.0; this task's native work ran serially against frozen input
`ff4da4b31dc2f5e0e1b9425a2ac96c06f6399a63`. The small workload matches that revision
byte for byte, SHA-256 `6a67158fb09aac383ec40e77e5c5b1d64fd068b19edf6e2596a6f25060d9cc93`.

| Workload | Allocations, both sides | Retired instructions, baseline minimum | Candidate minimum | Change | Generated C |
| --- | --- | --- | --- | --- | --- |
| Small | 1,732,636 | 1,603,605,557 | 1,601,623,119 | -0.12% | Identical, 39,575 bytes |
| Compiler self | 246,958,527 | 228,191,696,413 | 228,241,847,301 | +0.02% | Identical, 78,520,699 bytes |

Each pair has three normal instruction samples and a separate diagnostic
allocation run. Every checkpoint allocation count is unchanged. Both pass the
0.5% enabling-cut budget; these small instruction differences are not evidence
of a speedup.

Small measurements used `benchmarks/self_compile_measure --stage2 --program small
--samples 3 --input-rev ff4da4b31dc2f5e0e1b9425a2ac96c06f6399a63`, before and after
the production edit. The candidate additionally used `--baseline` and
`--require-identical`. Compiler-self measurements reused those preserved stage-2
binary pairs with `--compiler`, `--diagnostic-compiler`, `--skip-build-check`,
`--program self` and the same samples/input; the candidate likewise required
identity. Exact commands and paths are retained in the combined JSON.

Tooling limitation: explicit `--compiler` mode labels the raw self records'
`compiler_stage` as 1 even when supplied a stage-2 binary. The records are
unmodified. Their normal/diagnostic SHA pairs and complete fingerprints equal
the corresponding stage-2 small records, including `compiled_by: self-*`, proving
the actual stage. `--stage2` would rebuild and override the preserved binaries.

## Independent gates

Code-reviewer: 0 blockers, 0 should-fixes, 0 nits; correctness approved.
Independent test-runner verified final source/test hashes and every measurement
pair. `compiler-check --changed`: all 422 tests pass across five suites, log
`independent-compiler-check.log` in the raw artifact directory. That invocation
rebuilt the CLI at its default `-O0`; the runner recorded its FRESH fingerprint
and restored the intended `-O2` build before broader `--no-build` gates. Its
binary SHA returned exactly to the candidate hash above.
Broad serial gates pass: `compiler-blorp` 6,594/6,594 (5,764 suite tests plus all
830 expected production fixtures); `compiler-tools` 241/241. Logs are
`independent-gates/compiler-blorp.log`, `independent-gates/compiler-tools.log` and
`independent-broad-gates.log`. Final build status is FRESH, CLI/runtime `-O2`,
candidate binary SHA unchanged. Independent static checks pass and all 44 local
documentation links/anchors resolve.

An unrelated native leak job was observed during the later broad gate. Its
observed process age placed its start after the last measurement completed;
there is no evidence of measurement overlap. Exact process start time was not
available after it exited. This task did not start concurrent native work.

Successful-input measurements establish a non-regression boundary; they do not
measure invalid-call rendering lookup cost. The completed gates above accept
this bounded diagnostic-authority change.

## Current-main publication validation

The squash parent is `6205aba411eb322df8a0b8e40043b53b45101965`, preserving the
four main commits after the original audit. The reviewed feature is `1590a2f9b`.
Only `infer.brp` differs from that parent among compiler build inputs. The
candidate source and regression-test hashes above are unchanged. Both parent
and candidate were rebuilt with CLI/runtime `-O2`; the candidate CLI SHA-256 is
`49b51be3eed3efb08e3ba089654c55635ae1d19d815c18992171f4b0c0c1a199`.

The combined JSON's `current_main_integration` preserves all four new raw records,
commands, stage-2 fingerprints and checkpoint counts separately from the original
measurements. The input revision is frozen to the squash parent. Each side has
three instruction samples and a separate diagnostic allocation run. The explicit
compiler-stage metadata limitation described above still applies to the self
records; their SHA pairs and full fingerprints match the stage-2 small records.

| Workload | Allocations, both sides | Retired instructions, baseline minimum | Candidate minimum | Change | Generated C |
| --- | --- | --- | --- | --- | --- |
| Small | 1,732,636 | 1,605,390,510 | 1,612,035,213 | +0.41% | Identical, 39,575 bytes |
| Compiler self | 247,133,465 | 228,581,196,944 | 228,456,793,804 | -0.05% | Identical, 78,536,166 bytes |

Every allocation checkpoint is unchanged. Both observed instruction comparisons
are within the 0.5% enabling limit. This team serialized its native work, but
other tasks' native jobs were observed on the host during candidate work, so this
was not a fully quiet host comparison. These results make no speedup or latency
claim. Raw build, measurement and postmerge gate logs are retained under
`/tmp/blorp-identity-publish-20261005/`.

Independent postmerge gates pass: focused `compiler-check --changed` 422/422
across five suites with explicit `BLORP_CLI_C_OPTIMIZATION=-O2`;
`compiler-blorp` 6,602/6,602 (5,772 suite checks and all 830 expected production
fixtures); `compiler-tools` 241/241 (139 fixtures and 102 Python checks).
Broad gates ran serially with `--no-build` in 10m51s. Final build status is FRESH,
CLI/runtime `-O2`, and the candidate CLI/source/test hashes remain unchanged.
Logs are `independent-compiler-check.log`, `independent-gates/compiler-blorp.log`,
`independent-gates/compiler-tools.log`, `independent-broad-gates.log` and
`independent-build-status.log` under the publication artifact directory.
