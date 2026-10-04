# Managed-record migration: repaired verification checkpoint

The integrated S2/S3/S4 change and 317 `struct` declaration replacements pass
the selected broad gates. This checkpoint is not full S4 acceptance, a release,
or keyword retirement. The legacy `struct` parser fixture remains intentional.
No instruction-count or latency improvement is claimed.

## Provenance

Evidence below was collected before this checkpoint commit, on base
`02c0786a609f6ef7b65f5fd6eba243af8fbd66bf`, with the integrated migration.
The final source diff SHA256 was
`a1f464e147606463c5b47fa8c68426d67d25266b6487d3957a119989748be9a3`;
only this report and roadmap status changed afterward. Compiler and runtime
used `-O2`, eight-way splitting, bootstrap `dev-8228a8fa12e3`, and Apple Clang 21.
Installed compiler SHA256:
`5333d2dce6d925dc5a269289c483a39898fdd53eaa025678d8ad113bb3d08f7b`.

Retained raw packets and generated C are in
`/tmp/blorp-fixed-spelling-verify.RGgg2k/`; these local artifacts are not
permanent repository assets. `REPAIR_RESULTS.md` there records individual
repairs and reviewer findings. The commands below regenerate the checks.

## Executed gates

| Selected gate | Passed | Failed |
| --- | ---: | ---: |
| Compiler Blorp: 5,557 suite checks and 804 marked fixtures | 6,361 | 0 |
| Discovery/compiler-new | 343 | 0 |
| Standard-library check: 91 modules | 1 | 0 |
| Runtime | 4,663 | 0 |
| Compiler tools | 218 | 0 |
| Total | 11,586 | 0 |

```bash
env BLORP_CLI_C_OPTIMIZATION=-O2 scripts/record-validation \
  --output /tmp/blorp-fixed-spelling-verify.RGgg2k/repair-final-broad -- \
  scripts/test --no-build --serial \
  --log-dir /tmp/blorp-fixed-spelling-verify.RGgg2k/repair-final-gate-logs \
  compiler-blorp compiler-new std-check runtime compiler-tools
```

Build first and confirm FRESH before using `--no-build`. The recorded command
exited zero, without timeout or source changes. Independent test-runner review
rehashes the artifacts and verifies the strict fixture census.

Focused checks passed 203/203, 109/109, and 419/419. Four new positive nominal
dimension fixtures pass; four negatives match exact diagnostic expectations.
The original direct fixed-record dimension parser fixture is unchanged and passes.

## Ownership and representation oracles

Managed Option/list/vector helpers enforce exactly 2/9/2,002 allocations and
matching releases, respectively, with zero live objects after helper return.
List and vector reads keep 9 and 101 owners live before consumption. Sharing,
COW value preservation, and counter-active guards remain checked. Genuine
scalar Options retain zero-allocation expectations.

Seven loop variants now resolve each iterable field from its own nominal
payload. The all-seven regression and Clang syntax check pass; independent C
inspection confirms correct field projections and release-before-counter lifetimes.
The separate general heterogeneous OR-pattern binding-type hole is not fixed
by this bounded caller repair.

## Self-hosting oracle

```bash
env BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-fixpoint \
  --work-dir /tmp/blorp-fixed-spelling-verify.RGgg2k/repair-fixpoint-stages
/tmp/blorp-fixed-spelling-verify.RGgg2k/repair-fixpoint-stages/blorp-stage2 \
  run --no-format \
  blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_pass/nominal_dimension_record_applications.brp
```

Stages 1, 2, and 3 emitted byte-identical 77,773,084-byte C, SHA256
`daae57fdf54955c7af8d0a029295bc799f59807586af65afb15ecda9fff0cba6`.
The actual stage-2 compiler SHA256 is
`5c073925362ff1cf674c1e143454025bcf84f359cba9d4ab236fadb1a02bef5c`;
its compile-and-run fixture exits zero. The recorder's installed-bin hash is
not the hash of this separately named stage-2 executable. Build-version metadata
changes after committing, so these hashes identify the precommit evidence only.

## Remaining acceptance

Run compiler-new parity, formatter/doctest, leak, relevant sanitizers, the
stage-2 codegen audit, hygiene/quality, and CLI/LSP/package integration gates.
Finish standalone benchmark caller checks. Review any failures against the
managed-record contract rather than weakening ownership or allocation checks.
Rebuild after the checkpoint commit before using `--no-build`; retain all new
repairs as a separate change. Main and the original integration checkout remain
untouched by this verification checkpoint.
