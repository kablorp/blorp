# Compact Expression Direct Parser Checkpoint

This test-only checkpoint compares the production raw expression parser with
an iterative driver that emits the existing compact product directly. Both
paths lex the same `SourceFile` inside the measured loop. Fixture construction
and one warmup iteration run before memory and elapsed-time measurement.

Base revision: `37fe3cd719754957c01cec005880d41ab3e1f4f2`.

Commands:

```bash
bin/blorp run --release --no-format \
  blorp/benchmark/compiler/compact_expression_direct_parser_probe.brp -- small 1 1000
bin/blorp run --release --no-format \
  blorp/benchmark/compiler/compact_expression_direct_parser_probe.brp -- deep 256 100
bin/blorp run --release --no-format \
  blorp/benchmark/compiler/compact_expression_direct_parser_probe.brp -- wide 128 100
bin/blorp run --release --no-format \
  blorp/benchmark/compiler/compact_expression_direct_parser_probe.brp -- malformed 128 100
```

Retained output:

```text
COMPACT_DIRECT_PARSER workload=small width=1 iterations=1000 baseline_us=9755 direct_us=12369 baseline_allocations=62000 direct_allocations=96000 baseline_releases=62000 direct_releases=96000 baseline_live=0 direct_live=0 baseline_checksum=8000 direct_checksum=14000 warmup=22
COMPACT_DIRECT_PARSER workload=deep width=256 iterations=100 baseline_us=796 direct_us=1325 baseline_allocations=3100 direct_allocations=7100 baseline_releases=3100 direct_releases=7100 baseline_live=0 direct_live=0 baseline_checksum=100 direct_checksum=200 warmup=3
COMPACT_DIRECT_PARSER workload=wide width=128 iterations=100 baseline_us=20499 direct_us=13804 baseline_allocations=131700 direct_allocations=112500 baseline_releases=131700 direct_releases=112500 baseline_live=0 direct_live=0 baseline_checksum=25800 direct_checksum=38800 warmup=646
COMPACT_DIRECT_PARSER workload=malformed width=128 iterations=100 baseline_us=21670 direct_us=14481 baseline_allocations=131900 direct_allocations=112700 baseline_releases=131900 direct_releases=112700 baseline_live=0 direct_live=0 baseline_checksum=25800 direct_checksum=38800 warmup=646
```

The direct path is a mixed result. It is about 27% slower with 55% more
allocations on the small call and about 66% slower with 129% more allocations
on the deep unary case. It is about 33% faster with 15% fewer allocations on
the wide call, including the missing-close recovery variant. These are
single-run checkpoint figures, not whole-compiler claims.

The differential suite compares projected expressions, token cursors, full
diagnostic values, and multi-root ordering against the actual production
parser. The direct driver admits names except the reserved migration-lookahead
spelling `into`, plus scalar literals, grouping, unary,
precedence-based binary/logical/range operators, and postfix calls. Other
primary, postfix, operator, and interpolated-string forms return an explicit
unsupported result without publishing a partial product.

The retained frame-storage probe reports:

```text
COMPACT_DIRECT_FRAME pushes=4128 pops=4128 maximum_depth=4096 retained_slots=4096 reuse_depth=32 checksum=8387056 allocations=11 releases=11 retained_objects=0 current_live_bytes=0
blorp: leak check: 42 allocs, 42 releases, 0 leaked, 0 bytes
```

Generated-C inspection confirms one 48-byte, 8-byte-aligned scalar frame row
stored inline. The deep pass appends frames; the second pass reuses retained
slots through `set`, whose inline-storage branch selects
`blorp_list_set_raw_copy`. `blorp_box_struct` appears only in the generated
storage-mode fallback. The action stack retains all 4,096 slots for that
second 32-frame pass; there is no trimming heuristic.

Hashes:

- compact product source: `dbacec27ef0de00874492e24d9fa9721c01e79a017f4e2f6164026900a6e9c76`;
- raw parser seam: `adaa19d1a83c2ba7db74eb989d78101efaa5632530e77174ceed18b03daf2493`;
- differential test: `9c0b4f803a460fca000ae16e29f696b7ac556923cae6140ef93806563a75b1e4`;
- frame probe: `8da703e944ec8a86adde9cccc7c68d9fa0d4a13ba4779aa1921d2a0a2e722d4f`;
- parser probe: `ac92a3d93374f8157156dc2f382dbef6c7ce6092f75a91234e1c7d16086dfa7b`;
- generated frame-probe C: `ea9529e1d63407ad69d427452b88d29beda1b0ea3b443bbb2588dbe8139a4c02`.

Recommendation: keep this as a measured test-only checkpoint. Do not replace
the production parser yet. The wide-call result justifies investigating a
narrow retained-list representation for production argument parsing, while
the small/deep regressions and driver size argue against a whole-parser rewrite
at this milestone.
