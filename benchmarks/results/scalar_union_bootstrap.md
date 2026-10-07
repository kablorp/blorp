# Locally validated scalar-union bootstrap precursor

This preparatory cut is validated locally against base
`99d44a587d504258b79596afe274f429c5022f13`. It retains enum declarations,
production Std and the immutable `dev-d2959d886320` bootstrap pin. It does not
authorize release/pin publication or acceptance of the separate retirement branch.

Non-generic ordinary/fixed unions whose **entire declaration** has no payload
fields use the existing scalar Core representation. Source semantics remain
separate: default nominal tag equality is available, authored equality wins,
and Hash is not automatically derived. Authored Hash-only keys receive a native
tag-equality callback; authored Eq+Hash uses the selected callbacks. Generic and
payload-bearing declarations remain managed. Full conditional payload equality
is planned, not delivered; neither spelling promises checked fixed placement.

## Provenance and epochs

Validated pre-closeout whole diff SHA256 (including Guide/roadmap):
`ed8f55d39c3043173d59ec0c06d30e1d35e7cbb165bbeef2aee4042e9e00301c`.
Production+Std manifest:
`675da78534c94c40068adee33ec50d545a82b70873935c1a930a58a07efe5429`.
Source/tests remained unchanged during this documentation closeout.
Normal pinned make succeeded without a bootstrap override; source manifests
verified unchanged through the independent gates and fixpoint.

- Initial final-candidate FRESH CLI O0/runtime O2 binary:
  `4fe220250e0391d1520203609deabdfb6c6f1c848c96222d545455a4770fff45`.
- Compiler C: `98d6d07e6e6f84cbaf24e6cde837b379d4cbdf242fcd0ad73a5d9a3cc52add43`.
- Subsequent normal pinned O2 make: exit 0/FRESH; binary
  `4c17400c0950c0ddec2a3adef10c3c6e8b6f93ea7d0751e3957204ba652a19a7`;
  compiler C unchanged. Earlier O0 gates are not relabeled O2 tests.
- O2 fixpoint: exit 0; actual stage2/stage3 byte comparison exit 0.
  Stage1/2/3 C are each 80,851,060 bytes, SHA256
  `ac4e24aaa41ff4120d1fb66c5c17ba6d7230300d8570d9402881121298a07df5`.
  Stage2 binary: `ae2471e79bd79fc4d41229fb5e705dd81fef66a7f2f3c3c890cac09e44f7d00d`.

## Replay entry points and results

Run from the repository root after a matching FRESH build. Default gate limits,
artifact optimization and sanitizer configuration were unchanged.

```sh
scalar_union_validation_dir=$(mktemp -d /tmp/blorp-scalar-union-validation.XXXXXX)
env -u BLORP_STD bin/blorp test --warmup-only
env -u BLORP_STD scripts/test --serial --no-build --log-dir "$scalar_union_validation_dir/compiler" compiler-blorp
env -u BLORP_STD scripts/test --serial --no-build --log-dir "$scalar_union_validation_dir/sanitize" compiler-core-sanitize
env -u BLORP_STD scripts/test --serial --no-build --log-dir "$scalar_union_validation_dir/leak" leak
env -u BLORP_STD bin/blorp test --suite --timeout 180 \
  blorp/test/test_runtime/test_types/test_enum.brp \
  blorp/test/test_runtime/test_types/test_packed_enum_tensor.brp \
  blorp/test/test_runtime/test_types/test_union_equality.brp \
  blorp/test/test_runtime/test_collections/test_hashable_standard_keys.brp \
  blorp/test/test_runtime/test_collections/test_value_shaped_hash_keys.brp
env -u BLORP_STD bash blorp/test/test_compiler/test_pipeline/codegen_audit/run_codegen_audit.sh bin/blorp --jobs 1
env -u BLORP_STD -u BLORP_BOOTSTRAP_COMPILER_BIN BLORP_CLI_C_OPTIMIZATION=-O2 make
env -u BLORP_STD -u BLORP_BOOTSTRAP_COMPILER_BIN BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-fixpoint --work-dir "$scalar_union_validation_dir/fixpoint"
```

Warmup passed. Compiler: **6703/6703** (5864 native + 839 fixtures);
Core sanitizer: **2438/2438**; leak: **1192/1192** (1156 combined + 30 native
+ 6 diagnostic controls); selected runtime owners: **63/63**; codegen audit:
**228/228**, also **228/228** with retained stage2. Counts overlap; do not sum them.

Channel replay owners are `blorp/test/test_compiler/test_stage_10_backend/test_core_emit.brp`
(366/366 source-owner assertions before rebuild) and
`blorp/test/test_runtime/test_memory/test_leak_baseline_channel_failed_send_string.brp`
(2/2 strict per-case checks on the rebuilt candidate). The original test remains.
The added case covers dynamic String accepted/would-block/timed-out/sealed sends,
managed receive and buffered cleanup.

## Real RED and strict ownership proof

The earlier candidate's leak gate stopped at C setup, before combined-suite
assertions: scalarized SendAttempt wrappers emitted two unsupported String
channel bodies. Retained minimal Core/C reproduced this. The repair selects
declared scalar constructor constants by issued IDs; native statuses are mapped
to those constants, not guessed to equal variant tags. Managed RecvAttempt and
release masks remain unchanged. The final independent leak gate above passed.

Scratch-only dynamic channel runs passed **18 allocations/18 releases/0 leaks/0 bytes**;
a direct driver of the tracked new case passed **21/21/0/0**. Generated C contains
runtime `blorp_string_concat` calls, so these are not static-literal-only proofs.
Suite process counters reset between cases and are not per-case allocation totals.
Stage2 scratch copied-Std fixed-Bool/native/packed probe passed **9/9/0/0**;
authored callback probe **8/8/0/0**; cached ordinary/fixed tag globals passed both
runtime parities (**5/5/0/0**, **6/6/0/0**), including generic equality and inequality.

Raw nonportable packet: `/tmp/blorp-scalar-bootstrap.6lg7gk`; final independent
report `independent-channel/REPORT.md`, SHA256
`925f917725226d2ac96d5a7eaab1409848d69ef48a1706da1421106f51c04235`.
Scratch sources/copied Std/Core/C live there, not in portable test discovery.
Earlier RED/setup and pre-channel reports retain their original epochs.

No performance comparison or whole-compiler allocation reduction is claimed.
Old empty variants already used immortal singletons. Scalars can reduce ARC/storage
work and enable existing packed list widths; direct Options remain allocation-free
but may grow from an 8-byte nullable pointer to a 16-byte stack value. Surviving
erased Option storage can require a struct box. Bare-root user Bool identity
collision and legacy enum Eq-only collection behavior are retained baseline
limitations, not newly promised semantics. Release/pin, retirement-branch gates
and full payload/generic equality remain separate work.

## Integrated publication state

The passes above belong to the original base99d44 precursor, not the integration
onto main `c148b2d2ca876fa1963a76f4a4e94cc8e136470c`. Current integration retains
the same feature and removes a redundant diagnostic wrapper. Its narrowly
approved [identity-debt amendment](scalar_union_identity_census.md), with
[exact machine evidence](scalar_union_identity_census.json), preserves semantic
classifications and unsupported coverage; it does not establish identity improvement.
Integrated macOS validation completed successfully; Linux premerge completed
with a sanitizer failure. The user explicitly directed publication despite
that disclosed failure. This is not a green premerge or sanitizer acceptance.

The new c148 macOS epoch used normal immutable-pin O2 make (exit 0, FRESH):
binary `1e9c1f276abcc55a583ae4183c5cce3ae7759ec3d2df7964e737182dee680a73`,
compiler C `34eee6b6791a110fd3a7f6bad0412fcfb3a8863b50aa1b86c9a56ac5e08cccd9`.
Changed compiler checks passed **4739/4739**, seven runtime owners **83/83**,
strict channel **2/2**, and the three added scalar-key functions **26 allocations/
26 releases/0 leaks/0 bytes**. Actual O2 fixpoint passed: all three C files are
81,574,164 bytes, SHA256
`cc0d8a58ecf58a1d32e7e32b9db3ca298f584555a3584a80cbd3163caf8c4500`;
stage2 codegen audit **228/228**. Raw commands and same-source provenance:
`/tmp/blorp-scalar-publish-validation.oIaAGl/REPORT.md` (SHA256
`700a70acf245e64f899e60f6ff8873a8de705a8742c84ad59ed76e74e24c14b6`).

Linux arm64 `scripts/docker-gate --premerge-gate --platform linux/arm64`
exited **2**. Build, quality (including census), tooling, broad tests
**18696/18696**, codegen audit, preview and examples passed; final premerge
**FAIL** at `make test-asan`. UBSan reported incorrect hash/equality callback
function-pointer types, followed by an ASan CHECK failure and SIGSEGV.
Sanitizer cause is unclassified; no baseline attribution or waiver is claimed.
The initial Git-preflight failure and authorized exact retry remain separate
epochs. Full tracked sources and staged/unstaged diffs stayed unchanged.
Raw final report: `/tmp/blorp-scalar-publish-docker-retry.Xc1ugc/REPORT.md`
(SHA256 `6fc55916d10bb0de8b53edb28eec2e548df45e6ea6248d79eaa6473708b62165`).

Publication parent advanced afterward to
`657da18e7764b3e6a93b9df698ce4d4be5846cf0`, preserving its unrelated upstream
discovery changes without conflicts. The native/Linux proof above remains
at c148; no further rerun was performed, as directed by the user.

A strict nonempty Dict literal owner leaks four objects/144 bytes on pristine
`c68074aeae2f635758e4d98b688abe5f33c27d29` and the matched candidate: both 12/13,
byte-identical stdout/stderr using the same baseline fixture and Std. Raw proof:
`/tmp/blorp-scalar-baseline-leak.JVGKoj/REPORT.md` (SHA256
`c6d6d7a6290568521a2a49de60329e092e2ed1f0f68aa248b56f34fe8b7d8412`). This inherited failure is not
waived or repaired and earlier leak PASS is not relabeled as current leak-free
acceptance. That c680 comparison is not proof that c148 is completely leak-free.
No bootstrap rotation, enum retirement or payload-Eq completion follows.
