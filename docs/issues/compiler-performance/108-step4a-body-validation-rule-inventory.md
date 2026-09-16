# Step 4A: Body Validation Rule And Traversal Inventory

**Status:** Current-code function-body inventory for the next Step 4A
validation cut. It supplies the relevant Phase 9A prerequisite, not the entire
Phase 9A closure or a claim that validation/finalization has been fused. It
follows [packet 107](107-step4a-inferred-body-issue-handoff.md).
Update or retire this packet as individual rules acquire explicit owners; the
production types and tests must become the durable authority.

## Why this inventory is a separate cut

`CheckedBodyArtifact` is already issued only from `ValidatedBody`, but a
validated independent body may later be projected into `TypedFunctionDecl` and
audited again by `typecheck_validate_typed_program`. The body-materialization
path also runs several separate recursive queries before that audit. Skipping
one on the basis of a function name, `CallableId`, or an assumed clean body
would weaken the product boundary: a standalone or recovered typed declaration
does not carry the same proof as an accepted independent artifact.

The immediate task is to identify which checks need lexical inference state,
which consume finalized facts, and which can legally share a traversal. It
also records the current diagnostic sequence so a subsequent extraction can
test parity before changing work or ownership.

## Current body path and diagnostic order

The independent path is `check_function_body_artifact` in `decl.brp`:

```text
fresh body inference state
  -> check main signature
  -> infer_expr -> finalize_infer_result
  -> return-type/body-result check
  -> debug assignment, then debug impure calls
  -> impure callback parameters
  -> impure calls inside pure lambdas
  -> impure calls in a pure function
  -> module assignments in a pure function
  -> non-tail recursive calls, if annotated
  -> materialize TypedFunctionInfo
  -> solve: parameter, source-return, semantic-return, body metas
  -> validate: body type coherence, unless body still has a meta
  -> CheckedBodyArtifact or RecoveredBodyArtifact
```

`typecheck_materialize_function_body_with_signature` owns the pre-product
checks above. `solve_typed_function_body` and `validate_body_type_info` own
the final two checks. Errors are appended to ordered `errors` and
`diagnostics` lists; the solve pass reports signature metas in the order
shown, then one body-meta error. A body-meta failure suppresses body-coherence
checking, but other collected errors remain. Rejected recovery keeps the typed
body and ordered issues, while CTFE receives only accepted artifacts.

The separate standalone/whole-program materializer ends with
`typecheck_validate_typed_program`, which visits declarations in program
order. It checks functions (including implementation methods), globals,
foreign functions, records, aliases, traits, and unions. When an independent
accepted body is reused by this materializer, its `TypedFunctionInfo` is
projected from the artifact but the complete-program function validator still
does the meta and coherence checks. This is a repeated safety audit, not a
reason to delete the audit for standalone or rejected declarations.

## Rule ownership ledger

“Walk” describes the current search scope, not a measured node-visit count.
These rules can short-circuit; a nested helper may revisit a subtree.

| Rule / production owner | Facts needed and current time | Current walk | Diagnostic and recovery contract | Representative guard |
| --- | --- | --- | --- | --- |
| Main signature: `decl.brp` `check_main_signature` | Parsed signature, resolved return trait, main policy; before body inference | Parameters only | Error precedes body inference; wrong main policy must not leak into dependency checks | `test_typecheck_decl.brp` main cases |
| Body return compatibility: `check_function_like_body_result` | Final expression type, declared type, type parameters, source span; just after `finalize_infer_result` | No body-tree walk | Return mismatch or missing annotation precedes post-body purity/debug checks | `test_typecheck_decl.brp` return cases |
| Debug block assignment: `check_debug_block_body` -> `typed_expr_has_debug_block_assignment` | Typed debug nesting and assignment forms; after finalization | Whole-body-capable Boolean traversal, including debug subtrees | At most one `debug: blocks cannot assign` before debug impure-call messages | `fixtures/typecheck/should_fail/debug_block_assignment.brp` plus declaration tests |
| Debug block impure calls: `check_debug_block_body` -> `typed_expr_debug_block_impure_call_names` | Resolved purity requirements inside debug blocks; after finalization | Separate whole-body-capable traversal, with nested purity traversal | One message per returned call name, after assignment message | `fixtures/typecheck/should_fail/debug_block_impure_call.brp` and `test_infer.brp` |
| Pure callback parameters: `check_pure_function_like_callback_params` | Signature parameter types and source labels; after finalization | Parameter loop only | Per-parameter errors after debug checks, before lambda/body purity | `fixtures/typecheck/should_fail/pure_impure_callback.brp` |
| Nested pure-lambda calls: `check_nested_pure_lambda_body_calls` -> `typed_expr_pure_lambda_impure_call_names` | Typed lambda purity and resolved call requirements; after finalization | Whole-body-capable traversal | Lambda errors precede enclosing pure-function call errors, even in an impure enclosing function | `fixtures/typecheck/should_fail/pure_lambda_calling_impure.brp` |
| Pure-function calls: `check_pure_function_like_body_calls` -> `typed_expr_impure_call_names` | Enclosing `is_pure`, resolved call/purity requirements; after finalization | Eligible body traversal only for pure functions; the purity walker descends into pure, not impure, nested lambdas | Per-call errors follow lambda errors | `fixtures/typecheck/should_fail/pure_calling_print.brp` |
| Pure-function module assignments: `check_pure_function_like_module_assignments` -> `typed_expr_module_assign_names` | Enclosing `is_pure`, typed assignment target scope; after finalization | Whole body only for pure functions | Per-assignment errors follow call-purity errors | `test_typecheck_decl.brp` purity cases |
| Tail recursion: `check_tail_recursive_function_body` -> `typed_expr_has_non_tail_recursive_call` | Annotation, typed call tree, function name and tail-position context; after finalization | Whole body only when annotated | One error after purity/module-assignment errors; current name-based recursive-target test must not be silently reinterpreted | `fixtures/typecheck/should_fail/tailrec_not_tail.brp` |
| Meta freedom: `solve_typed_function_body` -> `typed_expr_contains_meta` | Finalized signature and nested typed-body types; after materialization | Signature types plus one whole-body-capable walk | Parameter, source return, semantic return, body order; rejection retains typed recovery | `test_typecheck_decl.brp` `test_function_body_solver_rejects_all_signature_metas_in_order` |
| Typed-body coherence: `validate_body_type_info` -> `typed_expr_type_error` | Final typed expression slots, call metadata, nested types; after meta check | Whole body if body has no meta | One first incoherence error; skipped for a body with unresolved metas | `test_infer.brp` `test_typed_expr_type_error_rejects_missing_call_metadata` covers the helper; no declaration-boundary fixture yet |
| Complete-program invariants: `typecheck_validate_typed_program` | Materialized typed declarations and their final types; after all declarations | Declaration walk; functions/globals may each run the two body walks again | Declaration order and existing internal-error text; standalone/recovered paths still require this audit | `test_typecheck_decl.brp` direct validator tests |

The final five body-query families are distinct from `finalize_infer_result`:
finalization itself recursively resolves expression types before these checks
run. For a clean non-pure, non-tail-recursive function, debug assignment,
debug impure calls, pure-lambda calls, meta freedom, and type coherence are
five separate whole-body-capable queries after finalization. Pure and
`@tail_recursive` functions enable more; accepted reuse can add the later
meta/coherence audit. This is a static call-path count, **not** measured
per-node visits or a whole-compiler cost claim.

## Diagnostic spans and acceptance gates

The table below gives the exact fixed text or production interpolation
template for the body-path rules above. `<...>` denotes a runtime insertion;
`\n` denotes a newline in the emitted message. “Issuer span” is the
`TypecheckDiagnostic.span` supplied by the rule itself, before any enclosing
diagnostic-location pass. Rules that call `typecheck_state_add_error` or
`infer_error` supply `None`; the return-type helpers supply the parsed body
span. The next cut must capture **final public spans** alongside text before
moving a rule, especially for inference-owned errors.

| Rule family | Error text/template at issuer | Issuer span | Acceptance effect |
| --- | --- | --- | --- |
| Main signature | `MAIN_GENERIC_MESSAGE`; `MAIN_SIGNATURE_MESSAGE`; `main return type '<type>' does not implement ExitStatusAble\nhelp: Return Int or Void, or implement ExitStatusAble for a type owned by this module`; or `main parameter must be List[String], got <type>` | `None` | With `ValidateProgramMain`, adds body-session errors and prevents `CheckedBodyArtifact`; `IgnoreMainName` deliberately skips it |
| Return compatibility | `Function '<name>' returns wrong type\n    expected: <type>  (declared return type)\n       found: <type>  (body expression)`; or `Function '<name>' body has type <type> but no return type is declared\n    help: add '-> <type>' to the function signature, or use '-> Void' if discarding the result` | `Some(body_span)` | Rejects the independent body on error |
| Debug block | `debug: blocks cannot assign`; then `debug: blocks cannot call impure function '<call>'` for each returned call | `None` | Rejects the independent body on error |
| Callback/lambda/function purity | `Pure function '<name>' has impure callback parameter '<param>'`; `Pure function '<lambda>' cannot call impure function '<call>'`; `Pure function '<name>' cannot call impure function '<call>'` | `None` | Rejects the independent body on error |
| Pure module assignment | `Pure function '<name>' cannot assign to module-level variable '<variable>'` | `None` | Rejects the independent body on error |
| Tail recursion | `@tail_recursive function '<name>' has recursive call not in tail position` | `None` | Rejects the independent body on error |
| Unresolved meta | `internal typecheck error: typed program contains unfinalized inference meta in <label>: <type>` for each signature slot; `internal typecheck error: typed expression contains unfinalized inference meta in <label> body` | `None` | Cannot issue `SolvedBody` or `CheckedBodyArtifact`; rejected recovery keeps typed body and issues |
| Typed-body coherence | `internal typecheck error: typed expression has incoherent type info in <label> body: <detail>` | `None` | Cannot issue `ValidatedBody` or `CheckedBodyArtifact`. Applies only to a body that has accumulated no other issues: a body already carrying errors or diagnostics is rejected regardless, and its typed form legitimately holds recovery nodes such as an unresolved call, so the audit is suppressed there exactly as it is for `body_has_meta` |
| Complete-program audit | Reuses unresolved-meta and coherence templates for functions, plus declaration-specific internal-error templates in `typecheck_validate_typed_decl` | `None` at these validators | Guards the final `TypecheckProgramResult`/graph. It does not retroactively revoke an already issued independent artifact; skipping its accepted-reuse portion requires carrying that artifact's exact proof, while standalone/recovered declarations still need checking |

Inference-owned examples have different local issuers and must retain their
own ordering. `check_debug_only_reference` emits
`debug-only function '<name>' can only be used inside a debug: block`.
`check_with_body_resource_escape` emits
`scoped resource values cannot escape a with block` or
`scoped resource-derived values cannot escape a with block: <refs>`.
`check_match_exhaustiveness` dispatches Bool, open scalar, List, or
constructor-specific variants, and capture checks dispatch resource, stream,
and mutable-variable variants with distinct help text. Their helpers currently
call `infer_error` with `None`; any later source-location attachment and all
variant-specific templates must be frozen in public fixtures before a move.
They reject body acceptance through the inference error list, not through a
later whole-body audit.

## Checks that must not move merely to reduce scans

| Rule / production owner | Why it currently belongs early | Scope and example |
| --- | --- | --- |
| Match exhaustiveness: `infer.brp` `check_match_exhaustiveness` | Runs after a match's cases are typed while scrutinee and case coverage facts are in scope; moving it requires retaining exact coverage, not reconstructing names from the final tree | One match/case set; `fixtures/typecheck/should_fail/non_exhaustive_option.brp` |
| Debug-only reference/call: `check_debug_only_reference`, `check_debug_only_call` | Needs `in_debug`, suppression policy, and resolved call's `debug_only` fact at the use site | One reference/call; `test_infer.brp` debug-only cases |
| Lambda capture: `check_lambda_captures` and nearby capture helpers | Needs lexical `Env`, free-variable facts, mutable/resource origins and precedence among capture errors | One lambda's parsed subtree; `fixtures/typecheck/should_fail/closure_mutable_assign.brp` |
| Concurrent/detach capture: `task_capture_error` and callers | Needs task scope and lexical capture categories before leaving the task construct | One task body; `fixtures/typecheck/should_fail/file_resource_detach_capture.brp` |
| `with` resource escape: `check_with_body_resource_escape` | Needs scoped resource and derivation facts while the `with` scope is active | One `with` body/type; resource fixtures and `test_infer.brp` |

Assignment legality, expected-type constraints, pattern binding, loop/select
control context, and resource availability likewise remain inference-owned.
The separate rule inventory in the Phase 9 issue describes their broader
families; this packet names the concrete cut points relevant to body-wide
validation work.

## Next implementation cut and fast loop

The first deletion is now implemented for **accepted, reused top-level**
functions in [packet 109](109-step4a-proof-carrying-top-level-body-reuse.md).
It requires a materialization result that carries
the exact `ValidatedBody` proof with the exact typed payload through the
complete-program validation boundary. A bare ID set, source-name lookup, or
Boolean `already_checked` flag is insufficient: those can mark a different or
recovered typed value as accepted. Standalone and rejected bodies stay on the
current validation path; implementation methods still need proof transport.

Before extending that change, add a focused test with accepted reuse, standalone
materialization, and rejected recovery, asserting typed output and exact
diagnostic ordering. Establish an isolated nested-body benchmark or test-only
visit counter for `typed_expr_contains_meta` and `typed_expr_type_error`.
Then delete only the duplicate accepted-reuse walk and measure it; do not
merge purity, debug, or tail-recursion walkers into a flags record as part of
that cut.

Fast feedback should be:

```bash
python3 -m unittest blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_body_check_order.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
scripts/compiler-check --changed
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
```

For the benchmark, report checksum/body-check/reuse counts, typed-node visits
for each removed query, allocation/release counts, retired instructions, peak
and retained bytes, worker code size, and a warm latency screen. Accept the
cut only if the visit count demonstrably falls, diagnostics and rejected-body
recovery remain exact, and the other metrics have no material regression. A
cleaner type boundary without a resource win can be considered separately,
with its cost called out rather than described as an optimization.

## Acceptance for this inventory cut

- The post-finalization call sequence and whole-program recheck are explicit.
- Every listed rule names its current owner, required facts, traversal scope,
  diagnostic/recovery order, and representative test.
- Lexical checks are distinguished from candidates for post-solve validation.
- The next cut has a proof-carrying implementation condition and a short
  resource/diagnostic feedback loop; this packet makes no runtime improvement
  claim and changes no compiler behavior.
