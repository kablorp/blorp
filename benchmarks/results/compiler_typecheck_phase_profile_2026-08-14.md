# Isolated typechecking phase profile

Date: 2026-08-14

## Contract

`compiler_typecheck_phase_profile` constructs and validates the complete Phase
1-3 product chain once, then repeats exactly one pure phase constructor from
its immediate accepted input. The runtime function-profile window excludes
fixture construction and result reporting. Opaque fixture and plan types
prevent callers from pairing a stage with the wrong predecessor product or a
non-positive iteration count.

The representative fixture has eight dependency modules, 32 type shapes and
64 callable probes per module, import fan-out four, and ten measured phase
iterations. Function instrumentation compiles generated C with `-O0`; these
times are attribution evidence and a before/after feedback loop, not native
release-mode compiler latency.

The sample TSV records the base revision, changed source hashes, compiler
binary SHA-256, and benchmark runner input hash. That runner hash covers all
compiler and benchmark Blorp sources, std, the runner, compiler and bootstrap
binaries, C compiler, build configuration, instrumentation mode, and platform.

The wall-clock column brackets the begin/end controls and therefore includes
profile-window transition overhead. This is negligible for substantial phases
but dominates the accepted-graph join; use the function profile when evaluating
that constructor itself.

## Baseline

Each median is from five warm serial runs of the content-addressed executable.
All runs produced identical output counts and checksums.

The structural checksum covers phase-owned identities and principal output
shape. It is a benchmark equivalence guard rather than a complete serialization
of retained parsed AST; focused compiler suites remain the semantic authority.

| Phase | Median for 10 iterations | Per iteration |
| --- | ---: | ---: |
| indexed graph | 207.999 ms | 20.800 ms |
| importable modules | 14.552 ms | 1.455 ms |
| bound modules | 119.497 ms | 11.950 ms |
| declaration skeletons | 189.072 ms | 18.907 ms |
| alias dependencies | 119.792 ms | 11.979 ms |
| resolved type parameters | 25.590 ms | 2.559 ms |
| type headers | 491.746 ms | 49.175 ms |
| accepted graph join | 0.175 ms | 0.018 ms |

Raw samples are in `compiler_typecheck_phase_profile_2026-08-14.tsv`.
The exact attribution rows supporting the findings below are in
`compiler_typecheck_phase_profile_2026-08-14_attribution.tsv`. Inclusive
function times overlap and must not be added.

## Measured opportunities

The strongest shared low-risk candidate is the definition index's second-level
lookup shape. Its dictionaries are keyed only by module display bucket, then
linearly scan every callable or source-definition entry in that module. On this
fixture:

- indexed-graph construction issued 11,110 source-ID lookups, which consumed
  about 63% of the measured phase envelope, and called
  `compiler_source_definition_key_name` 1.53 million times;
- skeleton construction issued 5,210 callable-ID lookups, which consumed about
  14% of the measured phase envelope;
- type-header construction issued 5,360 source-ID lookups, which consumed about
  21% of the measured phase envelope.

This optimization is now implemented as an exact, collision-safe name sub-index
inside each module bucket. Bulk indexing builds each module's name maps locally
and publishes them once, avoiding repeated copies of the outer persistent
dictionaries. Exact key equality remains the final correctness check, and all
public projections retain definition-ID ordering.

Matched optimized-C measurements found a 28.0% indexed-graph improvement, a
3.4% skeleton improvement, and a 4.9% type-header improvement. The design,
rejected alternatives, raw medians, and equivalence checks are recorded in
`compiler_typecheck_definition_name_index_2026-08-14.md`.

The second candidate is owner-module association during resolved type-parameter
construction. `compiler_bound_module_graph_find` was called 5,440 times and
consumed about 21% of the measured phase envelope. The phase
should either consume type skeletons already paired with their validated bound
owner or use an exact identity-keyed owner index without reconstructing and
checking the same association for every type. A typed owner/skeleton product is
preferable if it can remove the missing-owner state after skeleton construction.

Smaller candidates are repeated list-based duplicate suppression in alias
reference collection and repeated type-header identity probes during resource
and value-layout completion. They should follow the two measured index changes,
not precede them.

## Feedback loop

```bash
# Build/cache once, then use the same dimensions on both revisions.
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_phase_profile indexed 10 8 32 64 4
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_phase_profile skeleton 10 8 32 64 4
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_phase_profile headers 10 8 32 64 4

# Focused output-equivalence and determinism guard.
./blorp test --timeout 60 \
  compiler/blorp/tests/test_compiler_typecheck_phase_profile.brp
```
