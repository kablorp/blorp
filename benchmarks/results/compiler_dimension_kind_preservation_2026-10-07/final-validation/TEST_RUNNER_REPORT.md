# Dimension-kind solver: independent final correctness

PASS. The frozen candidate fixes all seven baseline regression failures and passes the surrounding manifest types stage, leak coverage and broad compiler tests. No source, tests, documentation, allowlist or compiler inputs were edited by the test-runner.

| Gate | Result | Evidence |
| --- | --- | --- |
| Owning dimension solver | 26 PASS / 0 FAIL | owning.log |
| Types stage, 31 suites plus leak | 2313 PASS / 0 FAIL aggregate | types.log |
| Serial compiler-blorp | 6790 PASS / 0 FAIL aggregate | compiler-blorp.log and broad-logs/ |
| Actual magic spelling enforcement | PASS, 502 findings, 0 new / 0 stale | magic-strict.log; plain --strict, no report flag |
| Identity census check | PASS, 3446 rows, budgets within baseline | identity.log and hygiene.log |
| make hygiene-check | PASS; helper5/5, manifest369 modules/271 suites/9 checks | hygiene.log |
| git diff --check | PASS | diff-check.log |
| Freshness | FRESH CLI/runtime -O2 before and after | fresh-before.log, fresh-after-types.log, fresh-after.log |

Counts overlap across the owning, surrounding and broad gates and are not a unique-test total. The types check's successful child logs are deleted by the repository tool; its retained final machine-readable verdict is authoritative for the aggregate.

Failure table: none. The separately retained fail-before packet is `../fail-before/`: exact baseline had19PASS/7functionalFAIL/26. The candidate owning suite has26PASS/0FAIL. No setup/compiler failure, rerun, threshold change or timeout override occurred.

## Frozen authority

- Base/HEAD: `8fe717e28d461088258f7744db77f2d9c8d02a0f`.
- Solver source SHA256: `9e152a0c7631de1756f484332b67b1137a1c795ae63de8d3b2ec07ae73a334dd`.
- Owning test SHA256: `746b60e7407aaee75ffa327be6fa21f9112e722b5979b39256e6ebcaa1cd5fb2`.
- Candidate repository CLI SHA256: `e830b836caf032dfe774857c32be5864dfa29c0bc50929490f7f42b9c507550d`, identical before/after. Its dirty stamp accurately represents this uncommitted source/test candidate.
- Reviewed controller SHA256: `6b3f185b1fa0a92828f08fce4fdcc3e73532436a3aeb484d71aac4d24eaabeeb`.
- All5140 protected tracked/untracked paths, generated build stamps and installed/build binary hashes are identical before/after. All9 source guard reports have `source_changed=false`. The types gate's normal make was permitted to refresh ignored build outputs, but no actual transition occurred (`build_changed=false`).

`before.json`/`after.json` retain individual file hashes; `validated-source.patch` and two frozen .brp snapshots preserve the actual tested delta. `commands.json` records each exact argv, environment and start timestamp; `results.json` records exit/count/duration. `FINAL_RESULT.json` records completed PASS and unchanged authority. Durations are execution metadata, not performance evidence.

## Commands and scope

The whole foreground batch ran under:

```sh
python3 /tmp/blorp-identity-wave-7ab679600/native_slot_serial.py --cwd <worktree:reader-cuts> --wait-seconds 600 -- python3 /tmp/blorp-dimension-kind-cut/final-validation/run.py
```

The controller recorded changed-plan `--base8fe`, exact owning suite, `scripts/compiler-check --stage types`, `scripts/test --no-build --serial compiler-blorp`, actual plain `check-magic-spellings --strict`, `compiler-identity-census --check --json`, hygiene, diff and freshness guards. CLI optimization stayed -O2. `scripts/check-compiler-identities` does not exist in this checkout; the actual checker above was used.

The manifest owns dim_solver under `types`; the generic AGENTS typecheck shortcut omits this owner and was not substituted. No duplicate changed-check execution was added. Core sanitizer, codegen audit, parser parity and public grammar gates were not selected for this semantic solver-only cut. Public dimension syntax remains unchanged; existing source/diagnostic fixtures ran in compiler-blorp. The spelling scanner does not cover the three retired helper calls, so the502 census/unchanged allowlist is enforcement evidence, not a claimed three-row reduction.

Matched stage2 C/resource evidence is root-owned and separately reviewed; this report makes no performance or generated-C identity claim. Foreground session12123 exited0; every owned subprocess was waited, the shared slot is released and no owned child remains (`NATIVE_RELEASE.json`). No further correctness gate remains in the agreed scope.
