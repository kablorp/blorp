# Type-header count record pilot (2026-10-03)

This cut converts the six-`Int` `TypeHeaderSemanticCounts` from `struct`
to `record`. It is embedded in the managed `TypeHeaderTable` and read by
accepted-semantic-catalog validation, so it exercises nested product
ownership on the production compiler path. It has no identified foreign or
native by-value ABI. The test built a graph from
`record Item {value: Int}`, checked one record/field, and required
`same_object(counts, counts)`: 1/59 failed before the keyword edit;
59/59 passed after.

The candidate compiler's C maker for the count type (`brp_tyoH_make`)
allocates a `blorp_Object`-headed record and installs its type tag.
`TypeHeaderTable` stores a `brp_tyoH*` field and releases it in its
destructor. This is the intended temporary two-root representation, not
parent/child inline fusion. The inspected C is retained at
`/tmp/blorp-record-simplify-FabHlW/header-counts-compiler.c`
(SHA-256 `90d96ee69d7e59a9ad8d284395e98ceebae3e513642a8c52fdf5104a667b5516`,
maker near line 125445); the type's source declaration is in
`blorp/src/compiler/stage_06_typecheck/headers/type_header_graph.brp`.

## Matched stage-2 comparison

The control is the same-worktree, `-O2` stage-2 baseline captured before
this type changed. The intervening two-metric migration produced
**byte-identical normal and diagnostic stage-2 binaries**, so its
measurement is a valid binary control for this cut. Both compilers compiled
frozen input `df4a21773fad0882f83f34ad4c74b3ef630b4336` from the
same cwd with Apple clang 21, `cli=-O2 runtime=-O2`, eight translation
units, and five serial instruction samples:

```bash
env BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --stage2 \
  --input-rev df4a21773fad0882f83f34ad4c74b3ef630b4336 --samples 5 \
  --label record-header-counts-candidate \
  --baseline /tmp/blorp-record-simplify-FabHlW/baseline.json \
  --output /tmp/blorp-record-simplify-FabHlW/header-counts-candidate.json \
  --require-identical
```

Normal compiler SHA-256 changed from
`e8711582adef5ea81146a4fafaa3f1602ae2f4501e28945cfd58d126f686aec6`
to `15e7d742fce52fff67427fb853a3cf86230973e2eb2ab97adf12f3a5285891eb`.
Allocations changed **213,956,660 → 213,956,661**, entirely in the typed
frontend checkpoint; all later per-phase deltas are unchanged. Both
compilers emitted identical frozen-input C: 79,857,227 bytes, SHA-256
`285ed6a8142567996b483c5e2ff40c68dac016110a326a92122eab40a4e4e182`.
Retired-instruction minima were 204,281,925,796 and 204,191,874,291;
their five-sample ranges overlap. Peak RSS changed
2,150,432,768 → 2,155,823,104 bytes; one-pair RSS is noisy and no
latency claim follows. The exact allocation delta is consistent with one
extra nested heap root on this workload, not evidence for all nested
records.

## Gates

`scripts/compiler-check --changed --base 4c53fef5` passed 1,252/1,252
across four focused suites and the selected leak gate. The serial broad
gates passed: `compiler-blorp` 6,353/6,353 and
`compiler-blorp-sanitize` 4,865/4,865. `make hygiene-check` passed.

With `BLORP_CLI_C_OPTIMIZATION=-O2`, `scripts/compiler-fixpoint`
reached a fixpoint: stages 1, 2, and 3 each emitted 77,924,776 bytes of C
with SHA-256
`8d7a48357dab389986dea6d53bf3458c42968fb7f64a808319cc00d5e871c514`.
The retained fixpoint artifacts are under
`/tmp/blorp-record-simplify-FabHlW/header-fixpoint`.
