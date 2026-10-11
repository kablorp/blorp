# Blorp 2 simplification results, 2026-10-10

The four bounded changes from the [simplification audit](blorp_2_simplification_audit_2026-10-10.md)
are implemented and independently reviewed. The full pilot gate passes. Three
isolated slices meet their preset cost ceilings; interning exceeds its isolated
allocation ceiling. After that tradeoff was disclosed, the user requested
committing the completed refactors, authorizing retention of the typed result
with this measured exception. Combined measurements do not override the
isolated result, and existing e2e budgets remain unchanged.

## Changes and line counts

| Slice | Result | Production lines | Test lines |
| --- | --- | ---: | ---: |
| Emission | Render `OwnedValueOperation` directly; project borrowed arguments while rendering instead of rebuilding a lower operation and temporary argument list. | -26 | +21 |
| Interning | Return the complete `InternedName { names, id }` result; remove the parser's second search and impossible missing-name branch. | 0 | +14 |
| Validation | Return `Result[Void, Diagnostic]` from validation-only helpers in ownership insertion and verification. | 0 | 0 |
| Call collection | Thread the existing accumulator through assignments and exits, preserving evaluation order and original call facts. | -1 | +225 |
| Total | No new framework, cache, index, visitor, or pipeline layer. | **-27** | **+260** |

Counts are physical handwritten lines relative to `6621df612`, including the
new 225-line collection suite. Production IRs remain distinct; independent
ownership verification and all prior rejection tests remain intact.

## Matched compilation costs

Before implementation, the coordinator set a 1% ceiling on aggregate allocation
or retired-instruction increases and 5% on each fixture. Existing e2e budgets
also remain unchanged. These ceilings apply to each isolated slice and the
combined candidate, separately.

The workload is the same 110 valid e2e input files, frozen by SHA-256. Six pilot
source variants use one FRESH host compiler and Apple Clang 21 at `-O0`.
Each variant compiles every input in three serial pairs, reversing variant order
in pair two. Allocation counts are deterministic across the three diagnostic
runs; instructions use each fixture's median normal-run hardware count.
The totals below sum those per-fixture results. Input loading, process startup,
temporary prelude checking and C emission are all inside this measured boundary.
These are compilation proxies, not pilot self-compilation or target runtime
measurements; the pilot cannot self-compile yet.

| Variant | Allocations | Change | Retired instructions | Change | Preset ceiling |
| --- | ---: | ---: | ---: | ---: | --- |
| Baseline | 335,144 | — | 3,873,666,589 | — | Reference |
| Emission | 333,361 | -0.532% | 3,872,356,393 | -0.034% | Pass |
| Interning | 340,168 | **+1.499%** | 3,846,577,083 | -0.699% | **Fail: aggregate allocations** |
| Validation | 335,144 | 0.000% | 3,875,391,561 | +0.045% | Pass |
| Call collection | 332,559 | -0.771% | 3,872,041,815 | -0.042% | Pass |
| Combined | 335,800 | +0.196% | 3,841,700,993 | -0.825% | Pass |

All individual allocation and instruction increases stay below 5%. Interning's
largest allocation increase is 1.746% for `match/many_arms.brp`; that fixture's
instruction count falls 10.732%. Small instruction differences in the other
slices do not establish a speedup. Every diagnostic run reports zero leaks;
all 3,960 generated target C files are byte-identical to their matched baseline.

### Interning carrier diagnosis

The isolated increase is exactly **5,024 additional allocations**, one per
successfully consumed name. The host boxes the new fixed record because it
contains the managed name table:

- `variants/interning/compiler.c:59119` allocates the result record.
- `:99493` constructs it in both existing-name and appended-name paths.
- `:84375` consumes it; the parser reads its ID/table and releases the wrapper.
- The baseline returns the table directly and searches again at
  `variants/baseline/compiler.c:84347`.

The missing-name append uses the same list capacity path in both variants.
A read-only token tally matches the additional allocations for all 110 inputs.
For `return/zero.brp`, ten prelude names plus `main` and `Int` explain twelve
extra allocations. This isolates result boxing rather than additional growing
table copies.

No small, clean representation change was found that preserves the complete
typed result and removes this host allocation. A callback, extra parser state,
or a second interning path would add complexity beyond this slice. The worker
and coordinator recommend retaining the product with a disclosed allocation
exception, consistent with the user's preference for less repeated work and
clear data. Following disclosure of this result and the deferral alternative,
the user's instruction to commit authorizes retaining the carrier for this
slice. **The original isolated gate remains failed; this is a documented
exception, not a change to the preset ceiling or future acceptance policy.**

## Validation and independent review

The independent test-runner executed:

```sh
scripts/record-validation \
  --output blorp_2/build/simplification/independent-full-gate \
  -- make -C blorp_2 test
```

The command passed in 66.620 seconds with exit 0, empty stderr and
`source_changed_during_run=false`:

- 785 unit callbacks in 50 suites, including all five new callbacks.
- 86 grammar callbacks.
- Nine native runtime invariants and their TestSuite wrapper.
- 127 e2e cases and their TestSuite wrapper, including all 110 native
  compilation budget rows.

Focused source-restored suites passed before integration. Deliberate mutations
also proved the new assertions: a wrong borrowed operand failed five emitter
tests; a wrong returned name ID failed four name tests, including both new
direct-result assertions; parent-before-argument collection failed its order
test, and erased call spans failed both new collection tests. Every mutation
was restored and verified by source hash before final validation.

The independent compiler reviewer reported zero blockers, should-fix findings
or nits, and judged each source slice an improvement. Semantic approval is
complete; the user's subsequent commit instruction permits the disclosed
interning allocation exception.
The four unrelated host-backend draft files are unchanged and excluded.

## Evidence and provenance

The ignored local entrypoint is `blorp_2/build/simplification/README.md`:

- `baseline/` and `variants/`: frozen sources, generated compiler C, normal and
  diagnostic native binaries, source and binary hash inventories.
- `corpus/fixtures.tsv`: 110 input identities and frozen input paths.
- `build.zsh`, `measure.zsh`, `variant-build/`, `matched-measurements/`: exact
  serial commands and recorder packets.
- `samples/`, `summary.json`, `summarize.rb`: raw reports and read-only metric
  reduction. The analyzer correctly exits unsuccessfully for the isolated
  interning ceiling; its raw result is preserved.
- `emission/`, `interning/`, `validation/`, `collector/`: focused suites,
  deliberate mutation evidence and restoration receipts.
- `final-source.sha256`, `independent-full-gate/`: final source inventory and
  independent full-gate packet.

Baseline revision: `6621df612b0f256ad401e336b2f8a81cc32e7355`.
FRESH host SHA-256:
`8d9c5a7b33b2fc4203f90d14b671cfead8ba63b5b3b4f645142015645683ad66`.
Copied-source baseline compiler C SHA-256:
`5919df82442e398d05341e1b3a8411bcb3c1b0aa0565b3bd7eace22d1d6a043e`.
Copied-source combined compiler C SHA-256:
`f996a05d05840092c0d50431c610ef2cb856f873aa2cfcca9f2e0138581aed53`.
The actual-root full-gate compiler C SHA-256 is
`abe3300b769f8c9e0c32d71687146df4f5e24ded045f2f8b98861761ff1d4b71`.
Host-generated compiler C includes source-path provenance, so copied and
actual-root compiler C hashes differ; all 16 source module contents match and
all target program C outputs match byte for byte.
