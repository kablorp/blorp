# Compact Expression Direct Parser Checkpoint

This test-only checkpoint compares the production raw expression parser with
an iterative driver that emits the existing compact product directly. The
`direct_product` window ends after product validation and a node-count
observation. The `direct_consumed` window additionally projects the product
back to `ParsedExpr` and makes the same structural observation as the baseline.
All parser paths lex the same `SourceFile` inside the measured loop; a separate
lex-only window reports that shared cost without subtracting noisy timings.
Fixture construction, exact-result and workload-shape preflight checks, and one
warmup iteration run before memory and elapsed-time measurement.

An earlier version built the deep fixture with adjacent `-` characters. The
lexer interpreted those characters as a comment, so the earlier deep figures
were invalid and are superseded by the results below. The corrected fixture
uses spaced unary operators. Its preflight and focused test assert 256 unary
nodes, 257 total nodes, and an exact maximum action depth of 259.

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
COMPACT_DIRECT_PARSER workload=small width=1 iterations=1000 equivalent=True shape_valid=True nodes=6 unary=0 calls=1 arguments=2 actions_pushed=25 maximum_action_depth=7 lex_us=4305 baseline_us=9305 direct_product_us=11562 direct_consumed_us=11036 lex_allocations=26000 baseline_allocations=62000 direct_product_allocations=96000 direct_consumed_allocations=117000 lex_releases=26000 baseline_releases=62000 direct_product_releases=96000 direct_consumed_releases=117000 lex_live=0 baseline_live=0 direct_product_live=0 direct_consumed_live=0 lex_checksum=279000 baseline_checksum=689000 direct_product_checksum=562000 direct_consumed_checksum=689000 warmup=2219
COMPACT_DIRECT_PARSER workload=deep width=256 iterations=100 equivalent=True shape_valid=True nodes=257 unary=256 calls=0 arguments=0 actions_pushed=517 maximum_action_depth=259 lex_us=8415 baseline_us=15249 direct_product_us=11069 direct_consumed_us=16075 lex_allocations=52200 baseline_allocations=105100 direct_product_allocations=86300 direct_consumed_allocations=189900 lex_releases=52200 baseline_releases=105100 direct_product_releases=86300 direct_consumed_releases=189900 lex_live=0 baseline_live=0 direct_product_live=0 direct_consumed_live=0 lex_checksum=799800 baseline_checksum=2951800 direct_product_checksum=2004600 direct_consumed_checksum=2951800 warmup=87080
COMPACT_DIRECT_PARSER workload=wide width=128 iterations=100 equivalent=True shape_valid=True nodes=130 unary=0 calls=1 arguments=128 actions_pushed=774 maximum_action_depth=5 lex_us=9161 baseline_us=18528 direct_product_us=12273 direct_consumed_us=13437 lex_allocations=65200 baseline_allocations=131700 direct_product_allocations=112500 direct_consumed_allocations=152700 lex_releases=65200 baseline_releases=131700 direct_product_releases=112500 direct_consumed_releases=152700 lex_live=0 baseline_live=0 direct_product_live=0 direct_consumed_live=0 lex_checksum=802900 baseline_checksum=2170100 direct_product_checksum=1615600 direct_consumed_checksum=2170100 warmup=67587
COMPACT_DIRECT_PARSER workload=malformed width=128 iterations=100 equivalent=True shape_valid=True nodes=130 unary=0 calls=1 arguments=128 actions_pushed=774 maximum_action_depth=5 lex_us=9310 baseline_us=19293 direct_product_us=12959 direct_consumed_us=13724 lex_allocations=65000 baseline_allocations=131900 direct_product_allocations=112700 direct_consumed_allocations=152900 lex_releases=65000 baseline_releases=131900 direct_product_releases=112700 direct_consumed_releases=152900 lex_live=0 baseline_live=0 direct_product_live=0 direct_consumed_live=0 lex_checksum=799800 baseline_checksum=2170700 direct_product_checksum=1616200 direct_consumed_checksum=2170700 warmup=67574
```

The product-only boundary remains mixed: versus baseline it is about 24% slower
with 55% more allocations on the fixed small call, 27% faster with 18% fewer
allocations on corrected deep unary input, and 34% faster with 15% fewer
allocations on the wide call. Once the product is consumed by projection, the
small call is about 19% slower with 89% more allocations, deep unary is about
5% slower with 81% more allocations, and the wide valid and malformed calls
are about 27-29% faster but with 16% more allocations. These are single-run
checkpoint figures, not whole-compiler claims. The small workload is a fixed-
cost sample; it is not a scaling pair.

Every timed command first reports `equivalent=True` only after comparing the
projected AST, final cursor, and full diagnostic values with the production
parser. It reports `shape_valid=True` only after checking the workload-specific
node and depth invariants. Baseline and consumed checksums are identical. The
product-only checksum is deliberately different because that boundary observes
validated product node count without constructing a `ParsedExpr`.

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
- differential test: `428d7d97c1ef9ea928adb6cde84a80608a5ad15426d4519c544fc529b69500bf`;
- frame probe: `8da703e944ec8a86adde9cccc7c68d9fa0d4a13ba4779aa1921d2a0a2e722d4f`;
- parser probe: `69ebec54cb05d707b6777957869724cd5ba9b928da4920ccddc19bdb5199e21f`;
- generated frame-probe C: `ea9529e1d63407ad69d427452b88d29beda1b0ea3b443bbb2588dbe8139a4c02`.

Recommendation: keep this as a corrected, measured test-only checkpoint and
do not change production wiring. The corrected results distinguish a promising
product-only boundary from the materially more allocation-heavy consumed
boundary, but they do not establish a whole-parser decision or justify pivoting
to a different optimization. Pause grammar expansion and production migration
until the intended downstream consumer and its required representation are
defined.
