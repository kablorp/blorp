# Compact Expression Concurrency And Recovery Checkpoint

Command:

```bash
bin/blorp run --leak-check --timeout 180 \
  blorp/benchmark/compiler/compact_expression_product_schema_probe.brp
```

Relevant retained output:

```text
COMPACT_EXPRESSION_SCHEMA case=empty roots=0 nodes=0 children=0 allocations=47 releases=45 retained_objects=2 current_live_bytes=424 product_abi_bytes=360
COMPACT_EXPRESSION_CONCURRENCY_ROWS case=empty concurrent_params=0 concurrent_for_payloads=0
COMPACT_EXPRESSION_SCHEMA case=small_module roots=16 nodes=48 children=32 allocations=251 releases=243 retained_objects=8 current_live_bytes=4936 product_abi_bytes=360
COMPACT_EXPRESSION_CONCURRENCY_ROWS case=small_module concurrent_params=0 concurrent_for_payloads=0
COMPACT_EXPRESSION_SCHEMA case=concurrency roots=3 nodes=13 children=10 texts=13 control_identifiers=5 typed_binders=1 references=7 bound_name_comparisons=1 allocations=119 releases=108 retained_objects=11 current_live_bytes=2552 product_abi_bytes=360
COMPACT_EXPRESSION_CONCURRENCY_ROWS case=concurrency concurrent_params=3 concurrent_for_payloads=1
COMPACT_EXPRESSION_SCHEMA case=legacy_tree_small_module roots=16 allocations=83 releases=2 retained_objects=81 current_live_bytes=5824 shallow_bytes=48
blorp: leak check: 103 allocs, 103 releases, 0 leaked, 0 bytes
```

Generated-C inspection:

- product record and ordinary heap request: 360 bytes;
- concurrent-parameter row: 24 bytes, 8-byte alignment;
- concurrent-for row: 16 bytes, 8-byte alignment;
- generated C SHA-256: `6a5fd39d56386065d8704f56e2721491f884f562f6acae08850597165edaf119`;
- probe source SHA-256: `9a3b13e4fdcd2a496cd83af9f60cea20860cd40db16025ee79f84846a6deea2b`;
- raw probe output: `/tmp/compact-expression-concurrency-probe.txt`;
- generated C inspected with Clang record-layout output:
  `/tmp/compact-expression-concurrency-probe.c`.

This freezes milestone-1 schema coverage at all 48 `ParsedExpr` variants. It
is a retained-layout and semantic checkpoint, not a construction or
whole-compiler speedup claim.

Focused validation:

- normal: 40/40 passed;
- sanitizer: 40/40 passed;
- leak check: 40/40 passed, 0 leaked bytes.

The earlier callable checkpoint's 4,965-test aggregate result predates these
test-only schema additions. The production parser path remains unwired, so no
new broad aggregate result is claimed here.
