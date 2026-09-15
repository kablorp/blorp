# Consolidate Compatible Early-Core Invariant Scans

**Status:** Proposed; correctness-sensitive traversal consolidation

**Current state:** normal compilation runs required resolve and standard-inline
invariants after several early-Core stages even when `--check-invariants` is
off. Composite checks such as `check_synth_invariants` and later resolve/std
checks can traverse the same program more than once. A compiler self-compile at
`f6af78c0` observed eight `check_expr_roots` calls totaling 1,698.092 ms self
and 3,565.319 ms inclusive time.
**Next action:** Count program scans and node visits by stage/check family, then
combine only checks that observe the same immutable post-stage program and have
compatible root eligibility.
**Read first:** `blorp/src/compiler/stage_09_core/early_invariants.brp`,
`blorp/src/compiler/stage_09_core/early_pipeline.brp`,
`blorp/test/compiler/stage_09_core/test_core_early_invariants.brp`, and the
early-Core stage ordering in `docs/ARCHITECTURE.md`.
**Fast loop:** Add an invariant mode to the Core work profiler or a dedicated
fixture that runs the production `finish_stage`/invariant boundary and reports
scans, node visits, violations, order, and checksum.
**Decision:** Never remove a required production invariant merely because the
debug flag is off. Ask for guidance if consolidation would cross a transform
boundary or change which diagnostic is reported first.

## Objective

Run compatible invariant predicates during one tree walk per post-stage
program, without weakening stage contracts or changing diagnostic priority.

A combined visitor may carry an explicit check plan rather than repeatedly
calling `check_program_invariants`:

```blorp
record CoreInvariantCheckPlan {
	check_debug: Bool,
	check_string_equality: Bool,
	check_mono: Bool,
	check_resolve: Bool,
	check_std_inline: Bool
}
```

This is illustrative, not permission to add boolean combinations with unclear
validity. Prefer a precise enum/list of check families and construct only legal
plans at the stage boundary. A monomorphic-only predicate must still run only
over monomorphic function, method, and global roots; do not silently broaden it
to generic bodies just to share traversal.

## Invariants And Tests

- Preserve the exact checks required after every early-Core stage.
- Preserve `--check-invariants` as an additive debugging mode.
- Preserve root eligibility for all-program and monomorphic-only checks.
- Preserve traversal order and the first reported violation, including when
  one expression violates multiple families.
- Preserve violation messages, hints, source locations, and stop-after-stage
  behavior.
- Cover every early stage, check-invariants on/off, clean programs, one failure
  per family, multiple failures in one node, failures in different roots, and
  generic versus monomorphic declarations.

Use explicit expected violation sequences in unit tests. A test that only
checks the number of violations cannot protect diagnostic ordering.

## Measurement

Report stage, enabled check families, roots, program scans, expression-node
visits, immediate-child lists materialized, predicates evaluated, violations,
allocations, instructions, elapsed time, and ordered violation checksum. Run a
node-count series with a fixed number of check families and a family-count
series with a fixed program.

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_early_invariants.brp
bin/blorp compile --check-invariants --no-format \
  -o /tmp/blorp-invariant-check.c blorp/src/main.brp
scripts/compiler-check --changed
scripts/test compiler-blorp
```

The self-compile command is a broad confirmation, not the fast loop. Use
`--profile-mode exact` on `early_invariants::check_expr_roots` to confirm the
expected call and self-time reduction, while taking headline latency from
uninstrumented matched compilers.

## Acceptance And Rejection

Accept when compatible composite checks use one scan, total invariant node
visits fall by at least 40% on compiler-shaped input, retired instructions or
allocations improve by at least 10%, single-family controls stay within 3%, and
the complete ordered diagnostic and C-output checksums match. Reject if any
stage contract is weakened, diagnostic priority changes, predicates run over
formerly ineligible roots, the combined dispatcher costs more on normal builds,
or cached results survive a transformation that invalidates them.
