# Step 4A: Carry Accepted Proof Through Implementation Methods

**Status:** Implemented in this worktree as a bounded continuation of the
[top-level proof-carrying cut](109-step4a-proof-carrying-top-level-body-reuse.md).
Step 4A remains open.

## Why this boundary matters

An independently checked implementation method can produce a `ValidatedBody`,
but complete-program materialization previously projected every explicit and
synthesized default method to `TypedFunctionInfo` before final validation.
That discarded the accepted proof and made the final typed-program audit walk
the method body again for unresolved metas and typed-expression coherence.
The top-level function cut removed that duplicate walk only for top-level and
private functions; leaving implementation methods behind would make acceptance
mean different things depending on declaration shape.

Skipping by method name, callable ID, or a parallel `Bool` list would permit a
proof for one payload to authorize another. The materialized implementation
therefore owns the same proof-bearing union used by top-level functions:

```blorp
private record MaterializedImplInfo {
    decl: ParsedImplDecl,
    for_type: SemanticType,
    type_params: List[BoundTypeParam],
    methods: List[MaterializedFunctionBody]
}

private union MaterializedFunctionBody:
    ReusedValidatedBody(ValidatedBody)
    UnvalidatedFunctionBody(TypedFunctionInfo)
```

Both source methods and synthesized trait defaults append the exact
`method_result.body`. The final validator still checks the implementation
target type first, then visits methods in source/default order and produces
the same labels. `ReusedValidatedBody` needs no second meta/coherence audit;
`UnvalidatedFunctionBody` retains that audit for rejected recovery, standalone
checks, and any path without an accepted artifact. Public `TypedImplInfo` is
projected from this same list only at the typed-program boundary. The public
standalone `typecheck_validate_typed_program` contract is unchanged.

## Implementation and fast feedback

The structural regression was observed failing before this implementation. It
guards proof transport through `MaterializedImplDecl`, exact method-list
projection, and the absence of the old unchecked `TypedImplDecl` route. A
source-language regression covers one accepted and one rejected explicit
method, verifies that the one error is the `String` mismatch, and compares
typed output, errors, and diagnostics under source, reverse, and deterministic
shuffled body schedules. The existing implementation schedule test also covers
accepted explicit and synthesized default methods.

After building once with `make`, use the smallest repeatable loop while
changing this boundary:

```bash
python3 -m unittest blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_body_check_order.brp
bin/blorp format --check blorp/src/compiler/stage_06_typecheck/decl.brp \
    blorp/test/compiler/stage_06_typecheck/test_body_check_order.brp
```

After that loop, run `scripts/compiler-check --changed`, the relevant
sanitizer gate, and the retained selected CTFE guard:

```bash
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
```

This selected workload is a regression screen, not evidence of an
implementation-method-specific speedup: it does not isolate method reuse. A
future method-heavy microbenchmark should count typed-node visits removed by
this cut before claiming a method-path throughput win.

The structural module passes 61/61 and support discovery passes 88/88. The
body-order suite passes 24/24. Independent changed-owner checks pass four
production sources and 11 focused suites; targeted ASan/UBSan checks pass
24 body-order and 158 declaration tests. The selected CTFE workload keeps
checksum 2,538, 72 dependency body checks, three reused bodies, zero errors,
and 3 / 192 retained objects/bytes. Local uncommitted worker snapshots are
`ed96e01155e4e13ae849fceaf9936829256f3c0f3c772df2f12ef7ed9969b6ae`
(pre-cut) and
`683a60a35f852f500005bafa69242de7de5c439c52e2531d65102cacd9e3398a`
(candidate), not Git revisions.

| Selected workload signal | Pre-cut | Candidate | Reading |
| --- | ---: | ---: | --- |
| Allocations / releases | 770,121 / 770,118 | 770,319 / 770,316 | +198 calls each (+0.026%); no allocation win claimed |
| Warm retired instructions | 1,570,235,666 | 1,571,119,208 | +0.056%, inside the earlier ~0.2% short-screen variation |
| Warm peak footprint | 14,942,520 B | 14,909,752 B | −0.22%, near parity |
| Worker code size | 6,377,968 B | 6,379,168 B | +1,200 B (+0.019%) |

Both direct runs had ten page faults. The short run is inadequate for a
reliable wall-time claim. This cut is an architectural deletion of redundant
method validation, with resource costs screened as small and mixed rather
than a demonstrated whole-compiler performance improvement.

## Acceptance

- Accepted explicit and synthesized default methods retain their exact
  `ValidatedBody` payload through complete materialization and projection;
  no second body meta/coherence audit runs for them.
- Rejected methods remain recoverable and receive the old final audit. An
  invalid implementation target remains checked before its methods.
- Method order, typed JSON, errors, and diagnostic order are unchanged across
  body schedules. Standalone typed-program validation remains intact.
- The selected benchmark preserves checksum, body-check/reuse counts, and
  retained memory. Allocations, retired instructions, footprint, and code size
  show no large regression. No latency win is claimed.

Nominal session-owned meta IDs, solver-lifetime measurement, and broader
finalization traversal remain Step 4A work. This cut does not introduce source
strings into later compiler stages or alter public language behavior.
