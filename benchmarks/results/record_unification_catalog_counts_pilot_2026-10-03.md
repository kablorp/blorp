# One-record compiler pilot (2026-10-03)

`AcceptedSemanticCatalogTableCounts` in
`blorp/src/compiler/stage_06_typecheck/type_system/accepted_semantic_catalog.brp`
is now a non-ABI `record` rather than a `struct`. This scalar-only type is
constructed and compared during accepted semantic-catalog validation. No
language-wide syntax, Core lowering, or other declaration changed. The pilot
tests whether that one internal value can use the intended unified heap-record
representation; it does not claim that all compiler structs can be converted.

## Behavior and generated representation

The added focused test obtains catalog counts and requires
`same_object(counts, counts)`. Before the keyword edit, the catalog suite had
three passes and `[FAIL] catalog counts have record identity` (`1 of 4 tests
failed`); after the edit it passed 4/4. The existing test still pins all ten
semantic count values. `test_bound_module_graph.brp` passed 23/23.

The same `blorp/src/main.brp` input was emitted to final Core and C without
host-compiling that output. Final Core changes the declaration from
`value_record` (`abi_type:null`, `origin:legacy_struct`) to `heap_record`
(`abi_type:null`). Baseline C's `brp_tyrV` was an inline ten-`long` struct with
`static inline brp_tyrV_make`; candidate C has a `blorp_Object` header,
`blorp_alloc`, `BLORP_INSTALL_TAG`, and a pointer-returning maker. Baseline
compiler-body C: 79,593,320 bytes, SHA-256
`122e988980db4634bdcd67799edaa3aeeae1fbd9161b97800f4930047ef07555`.
Candidate: 79,594,617 bytes (+1,297), SHA-256
`ffd6fbb38733c4f3ae5282221f8ef758950540ff41537566b57ebc0f6316c43a`.
Raw Core/C: `/tmp/blorp-record-unify-20261003.DJvqm2/`.

## Matched stage-2 measurement

Baseline was clean `main` at
`4d14444928c8c4a488f4a8ec461b810539a056e0` in
`/Users/keithphilpott/CLionProjects/blorp`; candidate was dirty
`codex/record-unification-pilot` at that same source base in
`/Users/keithphilpott/.codex/worktrees/r2-ownership-questions/blorp`.
Both used frozen input revision `4d14444928c8c4a488f4a8ec461b810539a056e0`,
Apple clang 21, `cli=-O2 runtime=-O2`, eight translation units, and five
serial instruction samples. From each respective checkout:

```bash
env BLORP_CLI_C_OPTIMIZATION=-O2 make
env BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --stage2 \
  --input-rev 4d14444928c8c4a488f4a8ec461b810539a056e0 --samples 5 \
  --label record-unification-baseline \
  --output /tmp/blorp-record-unify-20261003.DJvqm2/baseline-stage2.json
env BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --stage2 \
  --input-rev 4d14444928c8c4a488f4a8ec461b810539a056e0 --samples 5 \
  --label record-unification-candidate \
  --baseline /tmp/blorp-record-unify-20261003.DJvqm2/baseline-stage2.json \
  --output /tmp/blorp-record-unify-20261003.DJvqm2/candidate-stage2.json \
  --require-identical
```

The two compilers emitted **identical output C** for the frozen input:
79,855,729 bytes, SHA-256
`337e2977a5cd2b3fa96206ea22fd41a0f0486c4e1319136ad79c75b9921d4372`.
Raw cross-worktree totals were 213,948,810 versus 213,955,112 allocations
(+6,302), with +6,300 reported at `source_discovery_complete` and +2 at
`typed_frontend_complete`; backend emission had zero delta. Retired-instruction
minima were 204,191,286,742 and 204,073,975,409; medians were
204,244,820,313 and 204,142,404,557. The five-sample ranges overlap:
204,191,286,742–204,473,416,130 baseline and
204,073,975,409–204,415,566,225 candidate. No speed claim follows.

An A/A control reran the **exact baseline stage-2 binaries** from the
candidate cwd on the same frozen input. The normal binary SHA-256 was
`85b76d1a24b71f51f93f687025227fb3a473453eac93b9a3b7a6276abe4a1b71`
and diagnostic binary SHA-256 was
`d649c23bba0d4af933337694ea7c39f311c164a48e4b5005cb981344bdac3e0e`
on both baseline and A/A runs. A/A allocations were 213,955,110, exactly
+6,300 versus the main-cwd baseline, all in source discovery. Thus the
cross-cwd +6,300 is not attributable to the record conversion; the
same-cwd candidate delta is **+2 allocations**, in typed frontend. The A/A
raw file is `baseline-aa-candidate-cwd.json` in the directory above. From
the candidate checkout, the control invocation was:

```bash
env BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure \
  --compiler /Users/keithphilpott/CLionProjects/blorp/bin/blorp-stage2 \
  --diagnostic-compiler /Users/keithphilpott/CLionProjects/blorp/bin/blorp-stage2-diagnostic \
  --skip-build-check \
  --input-rev 4d14444928c8c4a488f4a8ec461b810539a056e0 \
  --label record-unification-baseline-aa-candidate-cwd --samples 2 \
  --baseline /tmp/blorp-record-unify-20261003.DJvqm2/baseline-stage2.json \
  --output /tmp/blorp-record-unify-20261003.DJvqm2/baseline-aa-candidate-cwd.json \
  --require-identical
```

Its harness `compiler_rev` reads later main HEAD `35ce001c`, and
`compiler_stage` reads `1`, because this explicit-binary, skipped-build-check
invocation uses current checkout metadata. The exact matching baseline
binary hashes, frozen input, and output hash establish the control's actual
compiler provenance. The underlying cwd-sensitive discovery mechanism was
not isolated further.

## Correctness gates and limit

`scripts/compiler-check --changed --base 4d1444492` passed 27/27;
`scripts/test --no-build --serial compiler-blorp leak` passed 6,351/6,351
and 1,153/1,153; `compiler-blorp-sanitize` passed 4,863/4,863; hygiene
passed. The `-O2` compiler fixpoint passed: stage 1, 2, and 3 output C all
had SHA-256 `328624263d99f9bf2d78a4fe3a4e14b99d3791ea80616dc06e19c7191c6470d3`.
Full gate logs and fixpoint artifacts are retained beside the JSON files.
This is one active scalar-only internal type, not a proof for managed fields,
ABI-exposed types, or wholesale `struct` removal.
