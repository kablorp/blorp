# Legacy callable keywords: parser capability

Legacy parser slice A accepts ordinary function declarations/import selections
named `and`, `or`, `not`, direct `and(...)`/`or(...)`, and called UFCS/qualified
members. Existing token/name-table identities feed ordinary name/member/call
products. Binding/type/field/module-alias names remain reserved. Unqualified
`not(...)` remains unary; host Boolean helpers and bootstrap rotation are later
slices. No standard-library, prelude, token, runtime or backend change is included.

The fixed B is `af7a2e85f8db8f7f5359cf44604ff07cee3faf86`; C is its reviewed
dirty source delta. Production is 140 ADD/42 DEL/+98, within 180/+150.
Nonfixture tests/registry/inventory are 256 ADD/2 DEL; the new fixture is 19 lines.
GUIDE/GRAMMAR are 8 ADD/5 DEL. This report is counted separately.

## Correctness

| Check | Actual result |
| --- | --- |
| Initial semantic RED | one intended identity FAIL, unary control PASS |
| Focused current owner |9 PASS/0 FAIL |
| Default immutable-bootstrap make |PASS; installed CLI-O0/runtime-O2 FRESH |
| Real maintained fixture through that CLI |exit17, empty stdout/stderr |
| Discovery parser fixtures |28 PASS/0 FAIL |
| compiler-new |1064 PASS/0 FAIL |
| compiler-new-parity |3363 PASS/0 mismatched files |
| compiler-blorp |6383 unit+864 production fixtures=7247 PASS/0 FAIL |

The af7 `compiler-check --changed --plan` selects `test_parser` and the new
`test_callable_keywords` owner, then exactly compiler-new/parity/compiler-blorp;
all selected gates are covered. The parity log retains its documented diagnostic
differences; this is no claim that every existing parser diagnostic is identical.
Earlier test import/indent setup failures, the record-seed assertion failure,
and the stale 863-fixture inventory failure are retained. The only harness change is 863→864 for the new
marked fixture; no marker, assertion or old fixture was removed.

## Matched actual legacy self-compilation

Both clean B and C used default pinned bootstrap `dev-0e1598ed616e` to build
FRESH O2 stage1 compilers, then the maintained `build_stage2_compiler` helper
built paired O2 normal/diagnostic producers from one shared body per role.
Its versions report `compiled_by:self-...`; raw external-pair measurement JSON
still says `compiler_stage:1`. That field is retained, not rewritten; the separate
producer record supplies actual stage2 generation/body/runtime provenance.

`self_compile_measure` compiled the same physical frozen af7 full legacy source
and host STD snapshot, with one diagnostic allocation run and three normal
BSD instruction samples per role. All 595 tracked source/STD members match af7.
A single private environment map, unchanged STD91, tool/SDK identities, runtime
modes and source guards bind the pair. No resampling or budget change occurred.

| Metric | B | C | Change | Independent hard limit |
| --- | ---: | ---: | ---: | ---: |
| Total allocations |289,948,094 |289,948,094 |0.000000% |+3% |
| Normal instructions, min3 |271,630,005,137 |271,830,700,991 |+0.073886% |+3% |

Every normal/diagnostic output and B/C output is byte-identical: 86,750,829 bytes,
SHA256 `265d311873189f1d7c3d2df0132b7cfcfebd076beac971fbd3cc178987912283`.
Normal samples were B 271,630,005,137–272,238,479,577 and
C 271,830,700,991–272,376,538,250; minima determine acceptance. Both independent
limits pass. Wall time and RSS are retained as diagnostics, not performance claims.
Existing fixture/resource ceilings remain unchanged. This is actual legacy
self-compilation, not the separate Blorp2 construction proxy.

## Retained evidence

[Cost receipt](../../build/bootstrap-evidence/legacy-callable-keywords-2026-10-19/acceptance01/cost/RECEIPT.json),
[B raw measurement](../../build/bootstrap-evidence/legacy-callable-keywords-2026-10-19/acceptance01/B-self.raw.json),
[C raw measurement](../../build/bootstrap-evidence/legacy-callable-keywords-2026-10-19/acceptance01/C-self.raw.json),
[producer provenance](../../build/bootstrap-evidence/legacy-callable-keywords-2026-10-19/acceptance01/cost/BUILT_PRODUCERS.json),
[full gate log](../../build/bootstrap-evidence/legacy-callable-keywords-2026-10-19/acceptance01/gates02/compiler-blorp.log),
[default build/main proof](../../build/bootstrap-evidence/legacy-callable-keywords-2026-10-19/acceptance01/default-bootstrap/RECEIPT.json).
Normal-sample C is transient: the maintained tool checks its hash before deletion.
Retained diagnostic C and per-sample instruction values remain independently available.
Raw generated C remains at the exact owned-worktree paths bound by the measurements.
The accepted O0 executable is preserved byte/mode-exact before the O2 transition.
The bootstrap pin remains unchanged; rotation is a later slice.
