# Index guard review

Verdict: APPROVE bounded continuation; 0 blockers, 0 should-fix findings in the staged content. The original controller STOP remains valid historical evidence. This approval permits reuse of the completed host component; it is not overall landing acceptance.

## Observed authority

Read-only checks used `git --no-optional-locks`; no index mutation, native command or repository edit occurred.

- HEAD remains `0e1598ed616ed48d03b20bb5a7fe39c61ade6a18`.
- All 5,768 index mode/blob/stage/path entries exactly match `git ls-tree -r` for staged tree `f212347db4b0c5c2f8e837833d5f8a3cc31b700a`. Stage tuple SHA256: `b8da79a6f08b8ca28944ce51b312b35650c290338abf6c852cc38e72c9184dbb`.
- The 46-file cached binary diff against HEAD retains SHA256 `2b0b387eae82e90de3e5265508230d6f847ac5d62f030431d28e3d76f41a76ce`.
- Initial and stopped snapshots differ only in raw index SHA256: `f97faf75b48aa525a362b0b29bfc825844c70289dd87528db0a330cbe713d9a6` → `14432eab2d029cb9be450b769ca4696cd51685ff9ec2cfecfd538b02b348fe33`. Current bytes independently match all 5,768 initial tracked-file hashes and both original architecture drafts; the untracked set remains empty.
- `host-premerge.log` SHA256 `cbd6de83caac10fac87c23c1407017f58799626f2632605cfe7fb33092f2bd3d` records host premerge PASS, 19,291 passed / 0 failed, including sanitizers, security, drift and hygiene. Docker was explicitly skipped by this host command. Host invocation configured `BLORP_TEST_TIMEOUT=60`.

## Diagnosis and recording limit

`scripts/premerge-gate:437` invokes `git status` while snapshotting. This is consistent with an index stat/cache refresh. Original index bytes were not retained, so neither the exact changed metadata field nor the triggering command can be proved retroactively. Identical logical stage entries and protected file bytes establish that this is not staged-content or source drift.

Controller `run.py` SHA256 `d923d128041c9bad290c8441bc0a345075b9cec25c827399ec150b933b56c1ec` checks the raw index after the host process returns, before appending its command result. Consequently original `commands.json` omits that host result. Preserve original STOP (`FINAL_RESULT.json` SHA256 `d670bff6bdc1ed3a2ac6691f6cbfbd11824edab7b7325176cfb50add4caca1ce`) and logs unchanged. Independent inspection of `scripts/premerge-gate:147–211` establishes that the final PASS verdict is emitted only with exit code 0 and `gate_finished=1`; the trap exits with that code. Thus the preserved final PASS also proves host exit 0. The controller waited for that child before its guard threw; coordinator consumed/released wrapper 43513 with exit 1. Retain this trap/reaping qualification in a separate receipt; do not synthesize an original command entry.

## Remaining acceptance

Run only remaining post-host FRESH, required full Linux/amd64 Docker gate with its documented `--no-sanitize` and default budgets, final FRESH and cached whitespace checks. Guard HEAD, logical stage tuples / expected tree / cached diff, protected working bytes, original drafts, installed compiler and retained resource authority. Record raw index hashes diagnostically. Stop on any logical/content drift or actual gate failure; do not rerun host merely to resolve bookkeeping.

Overall PASS requires actual remaining results and owned-process/slot release. Old 5e measurements retain their accepted paying-input reuse limits; this continuation does not produce a new 0e resource measurement.
