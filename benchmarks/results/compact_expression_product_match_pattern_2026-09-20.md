# Compact Expression Match/Pattern Checkpoint

Command:

```bash
bin/blorp run --leak-check --timeout 180 \
  blorp/benchmark/compiler/compact_expression_product_schema_probe.brp
```

Relevant retained output:

```text
COMPACT_EXPRESSION_SCHEMA case=empty roots=0 nodes=0 children=0 pattern_nodes=0 pattern_children=0 pattern_identifier_slices=0 pattern_identifiers=0 match_cases=0 allocations=36 releases=34 retained_objects=2 current_live_bytes=336 product_abi_bytes=272
COMPACT_EXPRESSION_SCHEMA case=small_module roots=16 nodes=48 children=32 pattern_nodes=0 pattern_children=0 pattern_identifier_slices=0 pattern_identifiers=0 match_cases=0 allocations=240 releases=232 retained_objects=8 current_live_bytes=4848 product_abi_bytes=272
COMPACT_EXPRESSION_SCHEMA case=pattern_match roots=1 nodes=3 children=2 texts=10 text_rows=3 bool_rows=1 pattern_nodes=13 pattern_children=12 pattern_identifier_slices=7 pattern_identifiers=7 match_cases=1 references=1 bound_name_comparisons=1 allocations=163 releases=150 retained_objects=13 current_live_bytes=2864 product_abi_bytes=272
COMPACT_EXPRESSION_SCHEMA case=legacy_tree_small_module roots=16 allocations=83 releases=2 retained_objects=81 current_live_bytes=5824 shallow_bytes=48
blorp: leak check: 103 allocs, 103 releases, 0 leaked, 0 bytes
```

Generated-C inspection:

- product record: 272 bytes, outside the runtime's 256-byte small-object pool;
- pattern node: 48 bytes;
- pattern identifier slice: 32 bytes;
- pattern identifier: 24 bytes;
- match case: 32 bytes;
- generated C SHA-256: `c2b13db4c9a8f55a6c3b814f05c4e5060e0e16126d1bfbaad45a98f366b74e30`;
- probe source SHA-256: `9ae87d5c491049a5083c528c7396ebc1c3c683d28aee22ad38d459130fda860e`.

This is a retained-layout and semantic checkpoint. It does not claim a
construction or whole-compiler speedup.
