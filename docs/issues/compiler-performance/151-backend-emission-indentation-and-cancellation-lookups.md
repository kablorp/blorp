# Cut Backend Emission String Work And Cancellation-Plan Lookups

**Status:** Ready. Coordinator-owned acceptance; three bounded cuts.

**Current state:** Backend emission is 2.8 to 3.0 seconds of a 23 second
self-compile and 39.4M allocations. In the 2026-09-16 profile:
`emit.indent_statements` ran 195k times, splitting each nested statement
block into lines and re-concatenating with two-space prefixes (`string.split`
201k calls), so every nesting level re-copies its whole body;
`cancellation_plan.cancellation_let_protection` ran 231k `find` scans at
3.7 µs each with 8.7M `core_vars_equal` comparisons, meaning the
`let_protections_by_uniq` buckets are wide; and
`cancellation_plan.analyze_current_behavior_expr` ran 997k times with a very
large inclusive time, suggesting the same subtree is analyzed from more than
one entry.

**Next action:** Make `indent_statements` a single pass without a line list,
key let-protection lookups by full variable identity, then attribute and
bound repeated behavior analysis. One cut per commit, measured.

**Read first:** `blorp/src/compiler/stage_10_backend/emit.brp`
(`indent_statements`, `FunctionBodyC`, `terminal_body`, a few of the 76
call sites); `blorp/src/compiler/stage_10_backend/cancellation_plan.brp`
(`cancellation_let_protection`, the `let_protections_by_uniq` construction,
`analyze_current_behavior_expr` and its five callers, `core_vars_equal`);
`blorp/test/compiler/stage_10_backend/test_core_emit.brp` and the
cancellation-plan suites; `blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh`;
[issue 53](53-minimize-and-compact-cancellation-cleanup.md) for the
cancellation ABI (do not change it); the
[measurement protocol](../../../benchmarks/README.md#self-compile-measurement-protocol).

**Fast loop:**

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_10_backend/test_core_emit.brp
make && scripts/compiler-build-status
benchmarks/self_compile_measure --label issue-151-<cut> --input-rev <baseline input_rev> \
  --baseline benchmarks/results/self_compile_baseline_O0_2026-09-16.json \
  --output /tmp/issue-151-<cut>.json --require-identical
```

**Decision:** Accept when generated C is IDENTICAL, backend_emission
allocations fall by at least 20% and its retired instructions by at least
10% (the coordinator confirms at `-O2`), and the emitter, cancellation, and
codegen-audit checks pass. Consult the coordinator before threading an
indentation depth through emitter signatures or changing any cancellation
protection decision.

## Cuts

### A. Single-pass `indent_statements` (emit.brp)

Rewrite `indent_statements` to scan the input once, appending `"  "` at the
start of each non-empty line and `"\n"` after it, into a string sized from
the input, with no intermediate list. Reproduce the exact current behavior:
empty lines are dropped, every emitted line ends with a newline, and a final
line without a trailing newline is still emitted. Add a focused test with
those three shapes. If the after-measurement still shows indentation above
3% of backend instructions, report the numbers and stop; emitting nested
blocks at a known depth is a separate decision.

### B. Exact let-protection lookup (cancellation_plan.brp)

`cancellation_let_protection` narrows by `variable.uniq` and then scans with
`core_vars_equal` (name, uniq, def_id). Key the index by the full identity
(for example a nested dictionary uniq to name to protections, or a composite
string key built once at index construction) so the lookup is a direct hit.
Preserve first-match order inside any remaining bucket. Add a test with two
variables that share `uniq` but differ in name or def_id.

### C. Repeated behavior analysis (cancellation_plan.brp)

Count how many times each Core node is visited by `analyze_current_behavior_expr`
during one function's plan on the self-compile (a temporary counter is fine;
remove it before handoff). If nodes are visited more than once per plan
because callers re-enter on subtrees already analyzed, compute the analysis
once per function body and look it up; if visits are already about one per
node, record the negative result and skip this cut. Do not alter which
protections are planned.

## Invariants And Tests

- Generated C is byte-identical for the self-compile and the small program.
- No cancellation protection, cleanup order, or emitted C changes; the
  cancellation ABI in issue 53 and `OWNERSHIP_MODEL.md` is untouched.
- `test_core_emit.brp`, the cancellation-plan suites, and
  `blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh bin/blorp`
  pass.
- No emitter output is buffered in a new global; helpers stay pure.

## Measurement

Report harness tables (self and small) after each cut; primary metrics are
backend_emission allocations and retired instructions. Include the node-visit
count from cut C.

## Acceptance And Rejection

Accept: IDENTICAL C on both programs; backend_emission allocations down at
least 20% and instructions down at least 10%; small program not up more than
1%; listed suites, the codegen audit, and
`benchmarks/self_compile_measure lock -- scripts/compiler-check --changed`
green. Reject any change to protection decisions or emitted text.
