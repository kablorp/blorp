# Compact Expression Select/With Checkpoint

Command:

```bash
bin/blorp run --leak-check --timeout 180 \
  blorp/benchmark/compiler/compact_expression_product_schema_probe.brp
```

Relevant retained output:

```text
COMPACT_EXPRESSION_SCHEMA case=empty roots=0 nodes=0 children=0 select_arms=0 with_bindings=0 with_error_maps=0 allocations=39 releases=37 retained_objects=2 current_live_bytes=360 product_abi_bytes=296
COMPACT_EXPRESSION_SCHEMA case=small_module roots=16 nodes=48 children=32 select_arms=0 with_bindings=0 with_error_maps=0 allocations=243 releases=235 retained_objects=8 current_live_bytes=4872 product_abi_bytes=296
COMPACT_EXPRESSION_SCHEMA case=select_with roots=2 nodes=11 children=9 texts=13 type_nodes=1 type_identifier_slices=1 type_identifiers=1 control_identifiers=3 select_arms=3 with_bindings=1 with_error_maps=1 references=6 bound_name_comparisons=3 allocations=103 releases=89 retained_objects=14 current_live_bytes=3256 product_abi_bytes=296
COMPACT_EXPRESSION_SCHEMA case=legacy_tree_small_module roots=16 allocations=83 releases=2 retained_objects=81 current_live_bytes=5824 shallow_bytes=48
blorp: leak check: 103 allocs, 103 releases, 0 leaked, 0 bytes
```

Generated-C inspection:

- product record and ordinary heap request: 296 bytes;
- select arm: 32 bytes;
- with binding: 48 bytes;
- with error map: 24 bytes;
- generated C SHA-256: `89fb3714c6f047d66f0621c2b36e7b776b6d57caaadb7d5ad9c1931b295028eb`;
- probe source SHA-256: `c2a4c052127ced8f67f01ebd98c141c79de0abcda68eff1da34e9cf4447c656e`.

This is a retained-layout and semantic checkpoint. It does not claim a
construction or whole-compiler speedup.
