# Independent baseline controls report: v3 STOP

Authority is unchanged compiler production HEAD2ee + accepted dictionary309;
installed compiler `a17a6ed3…` was **FRESH O2** before this batch. Frozen tests
`1355d3d4…`, tests-only-v3 patch `97132e62…`, scratch preparation `5fe71603…`
and runnable oracle `8c9aca63…` are physically retained with exact hashes in
`baseline-frozen-provenance.json`. Earlier v1/v2 actual-byte packets are preserved.

| Gate | Result | Counts |
| --- | --- | --- |
| build status | FRESH O2, exit0 | n/a |
| owning old-parser AST | PASS, exit0 | syntax only |
| scratch preparation old-parser AST | PASS, exit0 | syntax only |
| owning emitter suite | FAIL, exit1 | 369 pass / 3 fail / 372 total |
| contextual tensor-specialize | skipped after failure | unverified |
| two focused runtime tensor suites | skipped after failure | unverified |
| ranked oracle compile/run/C | skipped after failure | unverified |
| final build status | skipped after failure | not rerun |

All365 retained controls passed. New controls: four pass (all12 ABI forms,
incompatible parts, full-pipeline runtime projection, explicit scalar unbox
kind) and three fail. These are baseline output-assertion failures, not proved
production defects. The owning suite reports Bool results without failing C
text; no detailed rendered C was emitted by those controls.

| Failure | First error/evidence | Classification | Reproduction | Log |
| --- | --- | --- | --- | --- |
| standalone ranked getters sequence receiver before read | Bool assertion FAIL | new control fails on unchanged baseline | first v3 run only | baseline-owning-emit-packet/stdout.log |
| standalone ranked getter lookalikes keep runtime fallback | Bool assertion FAIL | new control fails on unchanged baseline | first v3 run only | baseline-owning-emit-packet/stdout.log |
| pipeline ranked struct unbox uses validated parts | Bool assertion FAIL | new control fails on unchanged baseline | first v3 run only | baseline-owning-emit-packet/stdout.log |

Both old-parser probes passed before executing tests. AST probes exercise syntax
only; they do not replace typechecking/emission checks. Full AST stdout remains
in scratch packets and must not be printed/copied into a large durable packet.
There were no compiler diagnostics in the owning run. The first actual failure
was receiver sequencing. No speculative source/test fix or automatic repeat.

All four executed validation packets have `source_changed_during_run: false`.
Full tracked/untracked source/test/docs and scratch proposal/oracle guards match
before/after; `source_changed_during_batch: false`, binary hash remains `a17`.
Baseline oracle C was not generated; runtime, C identity and broader acceptance
remain unverified. Final FRESH was not rerun after stopping; unchanged production
and compiler pins are preserved. `commands.json` records exact argv/durations.

Foreground session58888 exited1; every synchronous child call was waited, no
matching owned scheduler/batch processes remain and native slot is released.
Owner/root must diagnose the three baseline assertions before a corrected freeze
and new GO. Source snapshots and raw logs are unchanged.
