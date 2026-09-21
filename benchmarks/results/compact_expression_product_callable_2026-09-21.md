# Compact Expression Callable Checkpoint

Command:

```bash
bin/blorp run --leak-check --timeout 180 \
  blorp/benchmark/compiler/compact_expression_product_schema_probe.brp
```

Relevant retained output:

```text
COMPACT_EXPRESSION_SCHEMA case=empty roots=0 nodes=0 children=0 lambda_payloads=0 function_payloads=0 callable_params=0 callable_type_params=0 callable_dim_constraints=0 function_annotations=0 allocations=45 releases=43 retained_objects=2 current_live_bytes=408 product_abi_bytes=344
COMPACT_EXPRESSION_SCHEMA case=small_module roots=16 nodes=48 children=32 lambda_payloads=0 function_payloads=0 callable_params=0 callable_type_params=0 callable_dim_constraints=0 function_annotations=0 allocations=249 releases=241 retained_objects=8 current_live_bytes=4920 product_abi_bytes=344
COMPACT_EXPRESSION_SCHEMA case=callable roots=2 nodes=4 children=2 texts=16 type_nodes=6 type_identifier_slices=6 type_identifiers=9 control_identifiers=4 identifier_slices=2 lambda_payloads=1 function_payloads=1 callable_params=4 callable_type_params=1 callable_dim_constraints=1 function_annotations=4 references=0 bound_name_comparisons=1 allocations=137 releases=119 retained_objects=18 current_live_bytes=4040 product_abi_bytes=344
COMPACT_EXPRESSION_SCHEMA case=legacy_tree_small_module roots=16 allocations=83 releases=2 retained_objects=81 current_live_bytes=5824 shallow_bytes=48
blorp: leak check: 103 allocs, 103 releases, 0 leaked, 0 bytes
```

Generated-C inspection:

- product record and ordinary heap request: 344 bytes;
- lambda row: 32 bytes;
- function row: 112 bytes;
- callable parameter: 40 bytes;
- callable type parameter: 40 bytes;
- dimension constraint: 32 bytes;
- function annotation: 8 bytes;
- generated C SHA-256: `c1f599af10729d0837a1e0e5ba14316592a3deec9ababb1bac0413d44e41e16b`;
- probe source SHA-256: `1d024cff55f04b9c478854b47fb1df96ac547484f318e721bf33fdc830b50189`.

This is a retained-layout and semantic checkpoint. It does not claim a
construction or whole-compiler speedup.
