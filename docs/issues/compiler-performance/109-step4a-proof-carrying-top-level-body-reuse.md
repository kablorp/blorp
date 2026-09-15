# Step 4A: Carry Accepted Function Proof Through Complete Materialization

**Status:** Implemented in this worktree for top-level functions, including
private wrappers. Step 4A remains open. This executes the first bounded
deletion candidate from the [validation inventory](108-step4a-body-validation-rule-inventory.md).

## Context

An independently checked function already reaches `CheckedBodyArtifact` only
through `ValidatedBody`. The complete-program materializer previously reduced
every outcome to `TypedFunctionInfo` and then called
`typecheck_validate_typed_program`. Thus an accepted reused body ran
`typed_expr_contains_meta` and, if meta-free, `typed_expr_type_error` a second
time. This was safe but repeated work. The same final audit remains necessary
for standalone materialization, rejected recovery, foreign declarations, and
implementation methods that this cut does not yet carry as proof-bearing
materialized methods.

Using a `CallableId`, source name, or `already_validated: Bool` to skip the
audit would not prove that the *typed payload being emitted* is the one that
passed validation. The accepted branch now carries the opaque body value
itself until both final validation and typed-program projection:

```blorp
private union MaterializedFunctionBody:
    ReusedValidatedBody(ValidatedBody)
    UnvalidatedFunctionBody(TypedFunctionInfo)

private union MaterializedTypedDecl:
    MaterializedFunctionDecl(MaterializedFunctionBody)
    MaterializedUncheckedDecl(TypedDecl)
    MaterializedPrivateDecl(MaterializedTypedDecl)
```

`ReusedValidatedBody` is constructed only from a `BodyCheckAccepted` artifact.
`BodyCheckRejected` preserves its prior diagnostics and carries the recovered
typed function as `UnvalidatedFunctionBody`. Standalone and missing-artifact
paths also use the unchecked variant. In the final validator, only
`MaterializedFunctionDecl(ReusedValidatedBody(_))` skips re-auditing;
`materialized_typed_decl` projects that same opaque value to the public
`TypedFunctionDecl`. Private declarations recursively preserve the variant.
All other typed declarations still call `typecheck_validate_typed_decl`.

This is a proof-carrying materialization boundary, not a change to public
syntax, diagnostics, or the standalone `typecheck_validate_typed_program` API.
Implementation methods remain within `TypedImplDecl` and are still audited by
the complete-program path; lifting their accepted proof through method-list
materialization is a separate cut.

## Focused feedback and guard

The new structural test was observed failing before implementation, then
passing afterward. It guards the accepted/unchecked variants and validator
branch, plus private, implementation, and rejected routing. The production
compiler builds and `bin/blorp check --no-format` accepts `decl.brp`.

```bash
python3 -m unittest blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_body_check_order.brp \
    blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
scripts/compiler-check --changed
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
```

The focused structural module passes 60/60 and independent structural
discovery passes 87/87. The two focused Blorp suites pass
23 + 158 = 181/181; an independent changed-owner gate passes four production
sources and 11 focused suites, and targeted ASan/UBSan runs pass the same
181 tests. The selected retained CTFE workload keeps checksum
2,538, 72 dependency body checks, three reused bodies, zero errors, and
3 / 192 retained objects/bytes. Its pre-cut local worker key is
`9763e23168316ef4158a2e277266da5f9df18be679eb6b4329483a5b0dc374b9`;
the final formatted candidate key is
`ed96e01155e4e13ae849fceaf9936829256f3c0f3c772df2f12ef7ed9969b6ae`.
These are uncommitted local benchmark snapshots, not Git revisions.

| Selected workload signal | Pre-cut | Candidate | Reading |
| --- | ---: | ---: | --- |
| Allocations / releases | 770,322 / 770,319 | 770,121 / 770,118 | 201 fewer calls each (−0.026%) |
| Warm retired instructions | 1,571,520,729 | 1,571,812,270 / 1,568,686,464 | Near parity across a short screen; no instruction win claimed |
| Warm peak footprint | 15,040,824 B | 15,008,056 / 14,975,288 B | Near parity |
| Worker code size | 6,375,936 B | 6,377,968 B | +2,032 B (+0.032%) |

The first pre-cut direct run had 297 page faults, so its instruction and
elapsed-time result is not used for the warm comparison. Two post-format
candidate samples differed by about 0.2% in retired instructions, larger
than this cut's apparent signal; no wall-time or instruction win is claimed.
The direct control flow removes two body-query calls per accepted top-level
function. Exact typed-node visits have not yet been instrumented.

## Acceptance and remaining work

- Accepted top-level reuse projects the exact `ValidatedBody` payload without
  re-running meta freedom or typed-body coherence. Private wrappers retain
  that proof.
- Standalone, rejected, foreign, and implementation-method declarations keep
  the existing validation/recovery path and diagnostic order.
- Selected CTFE correctness and retained bytes are unchanged; allocation
  calls fall slightly, while warm instructions, footprint, and code size remain
  near parity.
- Independent changed-owner/sanitizer checks and code review found no blocking
  issue. The formatter needed two passes on this large source; the post-format
  changed-owner gate, 181 focused tests, 87 structural tests, direct typecheck,
  and `format --check` all pass. The targeted sanitizer run was before the
  whitespace-only formatting and was not repeated.
- Implementation-method proof transport is addressed in the subsequent
  [implementation-method packet](110-step4a-proof-carrying-implementation-method-reuse.md).
  Nominal session-owned meta IDs, solver-lifetime measurement, and broader
  finalization/validation traversal remain Step 4A tasks.
