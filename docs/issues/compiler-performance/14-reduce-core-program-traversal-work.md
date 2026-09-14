# Remove The Next Measured Superlinear Core Path

**Status:** Measurement-first. The production-pass work profiler and
match-projection index are in place; the older self-host sample list is not a
current target ranking.

**Current state:** `benchmarks/compiler_core_pipeline_work_profile` exercises
exact production Core pass entry points with independently scaled function,
node, union, alias, callable, call, match, and duplicate-name dimensions. It
reports work counters, allocator facts, elapsed time, and deterministic
checksums. Its owner suite is
`blorp/test/compiler/stage_09_core/test_core_pipeline_work_profile_benchmark.brp`.
See [benchmark guidance](../../../benchmarks/README.md) for the maintained
arguments and examples.

**Next action:** Reprofile current `main` through C emission and use one-axis
direct-pass runs to identify **one** material superlinear lookup or repeated
Core walk. Write a failing scaling/work assertion for that path, then make
one pass-local cut that removes the measured work. If the profile finds no
such path, close this broad issue and open a narrower issue for the actual
dominant per-node work.

**Read first:** [Core pipeline](../../../blorp/src/compiler/stage_09_core/pipeline.brp),
[Architecture](../../ARCHITECTURE.md#core-pipeline), the selected pass, its
nearest suite, and the work-profile fixture/runner. Do not choose a target
from a historical sample share or a function name alone.

## Fast Loop And Hypothesis

Vary one axis at a time while holding the others and output checksum fixed.
For example, measure candidate inspections as union declarations grow at a
fixed match count, or expression visits as body nodes grow at a fixed
declaration count:

```bash
for unions in 8 16 32 64 128; do
  benchmarks/compiler_core_pipeline_work_profile \
    1 match_projection 64 64 "$unions" 8 64 0 4 0
done

bin/blorp test \
  blorp/test/compiler/stage_09_core/test_core_pipeline_work_profile_benchmark.brp
```

The exact pass and fixture arguments must match the chosen current target;
the command above is a working *example*, not an instruction to re-optimize
match projection. Use deterministic visits/candidates, index builds,
reconstructions, allocations, and instructions to establish the mechanism.
Repeated >2.20 work growth for one doubled axis is a useful alarm, not a
substitute for inspecting which production operation caused it. Keep setup
outside the measured pass and compare production entry points, not a copied
toy implementation.

## Change Boundary

An exact declaration lookup should index `CoreDefinitionIdentity` or another
explicit phase identity, preserve declaration order and duplicates, and build
only as often as the declaration epoch changes. A traversal cut must preserve
stage stopping, diagnostics, ownership actions, cancellation cleanup, and
generated C. Reuse unchanged trees or fuse passes only if the first consumer
and traversal validity are explicit. Do not introduce a universal visitor,
pass manager, a new always-built index, or cached facts with no invalidation
rule merely to satisfy this issue.

The first production change must delete the old scan/walk it replaces. If
that deletion requires a broad architectural migration, stop and extract a
smaller preparatory boundary with independent tests and measurement.

## Acceptance

Before/after direct-pass rows must have identical semantic and output
checksums. The selected one-axis series should approach linear deterministic
work, or demonstrate the predicted reduction in repeated visits, with no
zero-query or small-program regression that erases the gain. Confirm the
result on compiler-self C emission without compiling C. Require equivalent
Core snapshots and byte-identical generated C for a representation-only cut;
run the owning compiler suite, `scripts/compiler-check --changed`, relevant
sanitizer/leak gates, and codegen audit where ownership or emission is touched.

Use matched baseline/candidate builds, alternate timed runs, report raw
latency plus allocations/instructions/peak memory, and retain evidence under
`benchmarks/results/`. Reject a synthetic-only win, a displaced allocation
cost, or a new representation that coexists with the old authority.
