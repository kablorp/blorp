# Typecheck metric-record migration (2026-10-03)

Base: `df4a21773fad0882f83f34ad4c74b3ef630b4336`, after merging
main into the one-type record pilot. This cut changes two non-ABI,
scalar-only declarations, `TypedProgramInventory` and
`AcceptedTraitImplementationAuthorityMetrics`, from `struct` to
`record`. The bridge test's `same_object` guard failed before and passed
after; existing inventory strings and real trait-metric fields stayed
unchanged. No source-language-wide `struct` behavior changed.

The retaining scratch program imported both types, called
`typed_decls_inventory`, constructed a metrics value, and passed each
value twice to `same_object`. Its final Core declares both as
`heap_record`. Generated C has a `blorp_Object` header and a
`blorp_alloc`/tag-installing maker for each
(`brp_ty0_make` and `brp_ty8_make` in the retained output). The scratch
source was removed after inspection; Core/C artifacts are under
`/tmp/blorp-record-simplify-FabHlW/metric-probe-*`.
To replay, put this source at
`blorp/test/compiler/stage_06_typecheck/test_record_metric_probe.brp`
and compile it with
`bin/blorp compile --no-format --dump-core-after=lower --dump-core-file=/tmp/metric-probe-core.txt -o /tmp/metric-probe.c blorp/test/compiler/stage_06_typecheck/test_record_metric_probe.brp`:

```blorp
import:
    ../../../src/compiler/stage_06_typecheck/inventory: typed_decls_inventory
    ../../../src/compiler/stage_06_typecheck/type_system/accepted_trait_implementation_authority:
        AcceptedTraitImplementationAuthorityMetrics
    memory: same_object

func main(args: List[String]) -> Int:
    inventory = typed_decls_inventory(args.length(), [])
    metrics: AcceptedTraitImplementationAuthorityMetrics = {
        accepted_trait_table_entries = args.length(),
        accepted_implementation_table_entries = 0,
        accepted_trait_semantic_conversions = 0,
        accepted_implementation_semantic_conversions = 0,
        accepted_qualified_implementation_method_rows = 0,
        accepted_compiler_implementation_links = 0,
        module_view_trait_indices = 0,
        module_view_implementation_indices = 0
    }
    if same_object(inventory, inventory) and same_object(metrics, metrics):
        0
    else:
        1
```

## Stage-2 control

Both runs used the **same worktree cwd**, frozen input revision
`df4a21773fad0882f83f34ad4c74b3ef630b4336`, Apple clang 21,
`cli=-O2 runtime=-O2`, eight translation units, and five serial
instruction samples. At baseline, the production `.brp` files matched
`df4a2177`; the dirty checkout contained documentation edits only. The
candidate changed just the two production declaration keywords and the
new test. Each run rebuilt its stage-2 compiler:

```bash
env BLORP_CLI_C_OPTIMIZATION=-O2 make
env BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --stage2 \
  --input-rev df4a21773fad0882f83f34ad4c74b3ef630b4336 --samples 5 \
  --label record-metrics-baseline \
  --output /tmp/blorp-record-simplify-FabHlW/baseline.json
# Apply the two source changes, then rebuild with the same -O2 setting.
env BLORP_CLI_C_OPTIMIZATION=-O2 make
env BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --stage2 \
  --input-rev df4a21773fad0882f83f34ad4c74b3ef630b4336 --samples 5 \
  --label record-metrics-candidate \
  --baseline /tmp/blorp-record-simplify-FabHlW/baseline.json \
  --output /tmp/blorp-record-simplify-FabHlW/candidate.json --require-identical
```

The baseline and candidate stage-2 normal binaries have the **same**
SHA-256, `e8711582adef5ea81146a4fafaa3f1602ae2f4501e28945cfd58d126f686aec6`;
their diagnostic binaries also match exactly,
`c0bcca81ad6f17118e73ac391eb6367b6bcdad2f7d1b237e42ac200eb571f5d9`.
All phase allocation rows and total allocations are identical at
213,956,660. Both emitted identical frozen-input C: 79,857,227 bytes,
SHA-256
`285ed6a8142567996b483c5e2ff40c68dac016110a326a92122eab40a4e4e182`.
Instruction minima were 204,281,925,796 and 204,170,127,380; the
five-sample ranges overlap. This is **not exercised in the production
self-compile binary**, not proof that the converted types cost zero when
used. The retaining fixture proves the representation change.

## Gates

The focused bridge suite failed the new representation test before the
source edit (1/129 failed), then passed 129/129; declaration tests passed
166/166. `scripts/compiler-check --changed --base df4a2177` passed
681/681. Compiler-Blorp passed 6,352/6,352, leak 1,153/1,153, and
Compiler-Blorp ASan/UBSan 4,864/4,864. `make hygiene-check` passed.
This source-only migration did not change the compiler's own stage-2 C
binary, so no new codegen/fixpoint claim is made for it.
