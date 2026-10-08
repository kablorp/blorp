# Independent baseline controls report: v2 STOP

Compiler authority: HEAD2ee + accepted dictionary309, installed `a17a6ed3…`.
Repository build status was **FRESH O2** before the owning test invocation.
Frozen owning suite `83c1a86c…`, tests-only patch `75b6785f…`, oracle input
`8c9aca63…`; exact pins/snapshots are in `baseline-frozen-provenance.json`,
`owning-suite-frozen.brp`, `tests-only.patch`, and `ranked_getter_oracle.frozen.brp`.

| Command/gate | Result | Cases |
| --- | --- | --- |
| scripts/compiler-build-status | FRESH O2, exit0 | n/a |
| owning test_core_emit suite | parse/setup failure, exit1 | 0 executed |
| contextual tensor-specialize | skipped after failure | unverified |
| checked-get/set runtime | skipped after failure | unverified |
| multi-index runtime | skipped after failure | unverified |
| ranked oracle compile/run/C | skipped after failure | unverified |
| final build status | skipped after failure | not rerun |

| Failure | First actual error | Classification | Reproduction | Log |
| --- | --- | --- | --- | --- |
| owning emitter compilation | test_core_emit.brp:26574:1: expected declaration | new controls parse failure; no compiler behavior or production defect proved | first run only; no automatic retry | baseline-owning-emit-packet/stderr.log |

The new assignment is `valid = valid` at line26573 followed by the unparenthesized
continuation `and c_source.contains(case.value_declaration)` at line26574.
Later parser diagnostics cascade. The initial inline-if syntax correction is
preserved separately; v2 still does not reach executable controls. No Bool case ran, so this is **one failed gate
invocation, zero pass/fail test-case evidence**, not seven failing controls.

Both executed validation packets have `source_changed_during_run: false`.
Frozen production, test, allowlist, tracked/untracked docs and compiler bytes
matched after the failure; `source_changed_during_batch: false`. Compiler hash
remains `a17`. No source/test/doc/allowlist edits or native retries were made.
Baseline C was not generated. Final FRESH was not rerun because the batch stops
at the first failure; unchanged production/bin pins are preserved.

`commands.json` records exact argv, durations and packet paths. The serial wrapper
owned session31488 exited1, all synchronous child commands were waited, no matching
owned scheduler/batch process remains, and the owned native slot is released.
Design must provide a corrected tests-only freeze and root phase GO before a new
attempt. Original raw packet/source snapshots remain untouched.

The original first attempt remains preserved at `../baseline-controls/`; this v2
packet retains actual saved source/patch bytes, not reconstructed content.
