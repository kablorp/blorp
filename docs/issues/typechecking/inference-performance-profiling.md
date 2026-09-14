# Isolate And Profile Body-Checking Work

**Status:** Proposed measurement work. Exact profiling now reports self and
inclusive active time; this issue must use that capability rather than
reimplement profiler accounting.

**Current state:** The production body-check facade accepts `BodyCheckContext`
and returns a complete accepted or recovered `BodyCheckOutcome`. Whole-compiler
profiles do not isolate this pure body operation from graph construction,
other phases, and output materialization.

**Next action:** Add a small deterministic fixture of independently prepared
contexts, first proving that repeated and reordered checks produce identical
complete outcomes. Then time only `check_body_context` over that fixture.

**Read first:** `blorp/src/compiler/stage_06_typecheck/decl.brp` and its nearest
body-check tests,
`blorp/benchmark/compiler/compiler_typecheck_name_lookup_profile.brp`, and
the [profiling guide](../../DEVELOPMENT.md#function-profiling-and-flame-graphs).

## Boundary And Fixtures

The measured input is exactly `BodyCheckContext`; the kernel is exactly
`check_body_context(context)`; and the retained output is the complete
`BodyCheckOutcome`. Do not add a production `InferInput`, benchmark mode, or
partial inference product. Context and graph construction occur before the
timer; output inspection, fingerprinting, and release occur after it.

Begin with one small accepted body and one rejected body. Expand to small,
medium, and large fixtures spanning traversal, lexical scopes, calls,
generics, trait/UFCS dispatch, data/control flow, closures/resources/
concurrency, and error recovery. Vary body count and individual body width
separately. Include low-complexity controls so fixed harness overhead and
small/editor workload regressions remain visible.

The fixture owns graph/module facts needed for its entire lifetime. Its
constructor validates exact callable identities, expected accepted/rejected
counts, structural counters, and source/context fingerprints before publishing
an opaque ready value. Invalid or incomplete fixtures cannot be timed.

Freshness is a correctness gate:

```text
fingerprint(check_body_context(context))
    == fingerprint(check_body_context(context))
```

Check this across repeated samples, source/reverse/shuffled context order,
and checks following another accepted or rejected body. Fingerprints must
cover callable identity, accepted/rejected variant, typed body and semantic
types, selected call targets, diagnostics/errors and spans. A changed input or
output fingerprint invalidates the measurement.

## Fast Feedback

One sample retains the results of `contexts.map(check_body_context)` inside
the timed window. A private benchmark-local wrapper may exist only to make
function profiles legible; it cannot change inputs or policy. Calibrate on a
release build after one warmup so a routine sample lasts at least 50 ms, with
a named cap. Use one worker unless concurrency is the question. Report raw
samples, median, range, and median absolute deviation. Keep exact-profile or
native-sampling runs separate from uninstrumented latency runs.

Emit machine-readable sample records with revision, dirty state, compiler and
C-compiler identities, flags, platform, workers, fixture fingerprints,
family/scale/body and node counts, accepted/rejected counts, repetitions,
clock/profile mode, output fingerprint, and any invariant failure. Report
allocations, releases, retained bytes, and peak memory only when measured;
never print an unavailable value as zero. A control kernel that merely visits
context identities is reported separately, not automatically subtracted.

For a baseline/candidate claim, use the same fixture and matched build inputs,
warm both, alternate execution order, preserve raw observations under
`benchmarks/results/`, and require identical semantic output. Confirm a local
mechanism with self-time or native samples, then check whole-compiler replay
before claiming a user-visible speedup.

## Counterfactuals Are Disposable

A later experiment driver may create a temporary detached worktree at an exact
clean base revision, apply one checked-in context-validated patch, build a
benchmark binary, run the same matrix, capture exit/output/fingerprints, and
remove the worktree even after failure. It must never edit and revert the
developer's active tree or patch by function-name search-and-replace.

Classify each experiment before running:

- **Semantics-preserving on a proven fixture:** a resource scan may be skipped
  only when a structural assertion proves the fixture is resource-free;
  output fingerprints must match. Equivalent meta-free or nongeneric controls
  follow the same rule.
- **Destructive upper bound:** skipping validation or injecting preselected
  resolution intentionally changes semantics. Label the result
  `destructive_upper_bound`; it is only an Amdahl-style ceiling, never an
  expected production speedup or a reason to merge complexity by itself.

Probe broad clusters—finalization, metas, environment lookup, generic
substitution, traits/UFCS, resources, diagnostics, typed-tree validation—before
leaf helpers. Stop subdividing when the cluster's full removable share is too
small to matter. Rank candidates by measured self share, removable fraction,
representative workload coverage, evidence confidence, implementation cost,
and correctness risk; do not convert that judgment into a spurious precise
score.

## Acceptance

The deliverable is a trustworthy harness and an evidence-ranked optimization
backlog, **not** a production solver rewrite. Accept only when the direct
context/facade boundary, complete retained outcomes, freshness/order tests,
fixture and output fingerprints, setup-excluded timing, raw provenance,
independent profile corroboration, and disposable-worktree safety are proven.
At least one semantics-preserving and one destructive experiment must exercise
their different validity rules. Begin any actual optimization as a separate
TDD change and verify it against both this harness and end-to-end compilation.
