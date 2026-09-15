# Step 4A: Narrow The Inferred-Body Validation Handoff

**Status:** Implemented in this worktree; Step 4A remains open. This follows
the solver and body-product cuts through
[packet 106](106-step4a-acyclic-meta-head-resolution.md).

## Context and boundary

Independent body inference already zonks the typed body before validation.
The previous `InferredBody` nevertheless wrapped the entire
`TypecheckFunctionBodyResult`, whose `TypecheckState` includes the solver,
environment, module view, counters, and other broad state. Subsequent
solved/validated checks read only the typed function, ordered error strings,
and ordered diagnostics. Carrying the broad state across that boundary kept
an unnecessary ownership path alive even though accepted artifacts eventually
dropped it.

The new private product is:

```blorp
private record BodyValidationIssues {
    errors: List[String],
    diagnostics: List[TypecheckDiagnostic]
}

private record InferredBodyRep {
    typed: TypedFunctionInfo,
    issues: BodyValidationIssues
}

opaque type InferredBody = InferredBodyRep
```

`inferred_body_from_materialized` is the one constructor from the finalized
function result. It extracts the two issue lists and typed function; no
`Context`, solver, `Env`, module facts, or full `TypecheckState` are in the
resulting product. Solve and semantic validation thread `BodyValidationIssues`
instead of copying broad state. Rejected recovery still receives the same
typed function, errors, and diagnostics in the same order. The separate final
whole-program validator adapts its `TypecheckState` to the same private issues
logic and writes back only error/diagnostic fields; other state is unchanged.

The constructor is protected by a structural boundary test, while existing
body-order, rejected-recovery, and exact diagnostic tests check public
behavior. This is a lifetime/representation cut, not a move of semantic
checks to a later phase.

## Rejected preparation

A simpler candidate kept `InferredBody = TypecheckFunctionBodyResult` and
called `reset_meta` on the embedded `Context` before validation. It copied
the broad state without proving a narrower product. On the selected CTFE
guard it moved allocations from 769,887 to 770,391 and did not improve the
measured peak footprint. That candidate was removed. An attempted struct
carrier was also removed because Blorp structs cannot store lists or records;
the diagnostic explicitly directs such fields to records.

## Fast feedback and resource guard

```bash
python3 -m unittest blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_body_check_order.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
scripts/compiler-check --changed
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
```

Independent verification passed: 59 structural boundary tests, 181 focused
body-order and declaration tests, `scripts/compiler-check --changed` (four
production sources, 11 suites), and 181 targeted ASan/UBSan tests for the two
focused Blorp suites. The changed-owner gate took 21.30 seconds and the
targeted sanitizer run took 23.76 seconds.

The retained selected CTFE workload keeps checksum 2,538, 72 dependency body
checks, three reused bodies, and 3 / 192 retained objects/bytes. The
pre-cut worker (`6eb807c093d68c5bf88cde7c7f7310e3ce9785db429e1b934a1b436de31acb5b`)
made 769,887 allocations and 769,884 releases; the narrowed product worker
(`9763e23168316ef4158a2e277266da5f9df18be679eb6b4329483a5b0dc374b9`)
made 770,322 and 770,319, a 0.056% allocation-call increase. In a short
B-A-A-B direct run, the warmed pre-cut worker retired 1,572,903,555
instructions with 15,008,056 B peak footprint; the candidate retired
1,570,589,071 / 1,569,252,534 instructions with 15,057,208 /
14,991,696 B peak footprint. The first baseline run had 301 page faults;
no wall-time claim is made. Worker size fell from 6,391,872 to 6,375,936
bytes (−0.249%). These are local uncommitted snapshot keys, not git commits.

This cut is accepted for the type-level ownership boundary with a small,
explicit allocation cost; it does **not** claim that the selected workload's
peak memory fell. The direct benefit is that validation cannot retain solver
state by its product type. A later body-local memory probe should isolate
long-lived solver payloads before claiming a lower whole-compiler ceiling.

## Acceptance and remaining work

- `InferredBody` and rejected validation products do not carry
  `TypecheckState` or solver state; accepted `ValidatedBody` remains the only
  CTFE-facing body product.
- Rejected diagnostics, accepted typed projection, and body scheduling retain
  their previous behavior.
- The selected guard shows no material instruction, footprint, retained-byte,
  or code-size regression; the allocation delta is recorded rather than
  described as a win.
- Session-owned nominal meta IDs, final whole-program traversal fusion,
  and a measured solver-lifetime memory probe remain Step 4A work.
