# Independent ranked tensor baseline: v4 PASS

Authority: unchanged HEAD `2ee201fb5cb74e8a7b4f3d068a143d8d71dd2bad` plus accepted
uncommitted dictionary309 compiler production; installed `a17a6ed3…` was FRESH O2
before and after. Frozen owning test `0f48eb43…`, tests-only-v4 patch `6206883c…`,
scratch preparation `5fe71603…`, and ranked oracle source `8c9aca63…` have exact
hashes/saved bytes in `baseline-frozen-provenance.json` and adjacent snapshots.
The proposal is scratch-only; production emit was unchanged.

| Gate | Pass | Fail | Evidence |
| --- | ---: | ---: | --- |
| owning old-parser AST | 1 probe | 0 | baseline-owning-parse-packet |
| owning emitter suite | 372 | 0 | baseline-owning-emit-packet |
| contextual tensor-specialize | 36 | 0 | baseline-context-tensor-packet |
| runtime checked-get/set | 14 | 0 | baseline-runtime-checked-packet |
| runtime multi-index | 5 | 0 | baseline-runtime-multi-index-packet |
| ranked oracle compile | exit0 | 0 | oracle-compile-packet |
| ranked oracle run | exit0 | 0 | oracle-run-packet |

The emitter suite contains365 retained + seven new passing controls. Do not sum
these counts into a unique-test figure. No failures occurred in v4; failure table
is empty. Prior v1/v2 parse-premise errors and v3's three output-premise failures
are preserved in their original packets. Corrected expectations follow actual
unchanged-baseline probe C; no production bug or fix is claimed from those failures.

The seven controls cover exact12 Builtin ABI forms in standalone prepared emission,
statement receiver/argument ordering, incompatible static/dynamic/arity rejection,
all three unsupported lookalikes, full-pipeline runtime projection, explicit
Float/Float32/Float16 unbox, and plain versus shaped full-pipeline struct output.
Standalone Builtin width inlining is distinct from production runtime projection.
Old-parser AST is syntax feedback only. The unchanged scratch proposal's v3
syntax PASS was not repeated; it remains unimplemented/unvalidated beyond syntax.

The runnable source oracle covers rank3/4/5 × Float/Float32/Float16/Int/String/fixed
RankedPoint values, negative-index wrap and scalar out-of-bounds zero. Compile and
run both succeeded, confirming the current factory/record capability for this
representative input. C inspection found f64/f32 typed shape runtime reads at all
ranks; Float16 uses erased shape plus explicit unbox, and Int/String use erased
shape. Real source fixed-record reads inline guarded copies at C lines280/457/646.
(The exact line numbers are recorded in RELEASE_PROOF; it is authoritative.)

Retained whole C: `ranked-getter-oracle.baseline.c`, 39,058 bytes,
SHA256 `6d6faf6b39697b83663601ccb585c959b67728f2395436886dc4a1f2c0bd8ac7`.
`baseline-oracle-readback.json` records source/copy pins, width/read names and bounded
C contexts. No candidate C comparison or resource acceptance is claimed yet.

Exact argv and durations are in `commands.json`: FRESH; compile --no-format --ast
owning input; bin/blorp test --timeout180 four suites; compile --no-format
--no-embed-runtime -o retained C; run --no-format frozen oracle; final FRESH.
All nine validation packets have `source_changed_during_run: false`. Complete
tracked/untracked production/test/docs and scratch proposal/oracle guards match;
batch source_changed is false, bin `a17` unchanged. No test-runner repo edits.

Full AST stdout stays scratch-only and is excluded from durable-copy guidance.
Broader compiler/codegen gates, strict scans, candidate build/C identity and matched
resources were deliberately held for the separately authorized production phase.

Foreground session25072 exited0, all synchronous child commands were waited, no
matching owned scheduler/batch processes remain and shared slot is released.
`RELEASE_PROOF.json` records explicit release and final source/binary/C authority.
No native jobs are left by this worker.
