# Blorp 2 block-owned lowering, 2026-10-14

This preparation removes repeated copying of a growing **block** definition
vector while preserving the published lowered IR. Expression traversal remains
recursive and retains its inherited wide/deep sharing costs. Two compiler-expert
reviewers approved the final source with zero findings. The full combined gate
passes; independent final evidence review approved with zero findings.
Current-main preservation and fresh gates pass in the
[rebase receipt](blorp_2_main_rebase_2026-10-14.md).

## Boundary and scope

Previously, `ValueBuilder` carried cursor, definitions and bindings through both
block construction and recursive expression helpers. The final private
`ExpressionBuilder` contains only cursor and expression definitions. Readonly
bindings are explicit parameters of `lower_value`, `lower_arguments` and
`lower_record`; their existing `BuiltValue` result cannot return a map alias.
Each expression starts with an empty vector, and its completed chunk merges once
into its local statement/arm/function owner. Binding assignment follows RHS
completion. Parameter rows, prefix/body products and branch-local captures keep
their established identities, types, spans and order.

```blorp
-- Private expression state; no block prefix or binding snapshot is returned.
private fixed record ExpressionBuilder {
    next_value: Int,
    definitions: List[ValueDefinition]
}
```

Function prefix/body products complete before one common final merge. The small
private `BuiltTail` carries definitions and the already-constructed LoweredTail.
Arms complete prefix/exit products before merging them. This is required because
the host retained the old outer accumulator inside fallible continuations,
turning otherwise local appends into COW copies. No task stack, traversal
framework, cache, public IR change or consuming-ABI inference is introduced.

Changes are limited to [lower.brp](../../blorp_2/src/lower.brp) and
[test_lower.brp](../../blorp_2/test/unit/test_lower.brp): **+22 production lines**
(624 versus 602; 196 added/174 removed) and **+151 test lines**
(153 added/2 removed). Unchanged public `lower` formatting is preserved.
Final source SHA-256 is
`bb2b57870ef62f8115e36ae7e70121f5db9c61fc2ec101a5a0a2b2030b32dec7`;
test SHA-256 is
`cc344696394ac8dfd9f30fdafec4ea0db7fe863921acb2912fcd0c662e5fc412`.

## Semantic and physical evidence

The suite grows from 16 to **19 passing callbacks**. Three new granular controls
pin scalar identity/type/span, nested UFCS rows followed by another statement,
and a zero-argument call preserving its waiting receiver. Existing alias,
reassignment, parameter, capture/branch and constructor controls remain. The UFCS
oracle checks callee arity and argument ValueIds, not exact FunctionInstanceId
target equality. Omitting only IntegerValue(20) at the new statement-chunk merge
produces **18 PASS/1 FAIL**, exactly the nested-UFCS/next-statement callback;
stderr is empty. The exact source hash was restored. An initial mutation
indentation setup failure is retained separately and is not a semantic red.

Actual combined CLI C:
`build/next-increments-20261014/compiler-combined.c`, SHA-256
`d97485f255cbc277c02df63bf159bf68506b1b4ef10c6a5922da4a74536b52f3`.
These source-root observations were checked individually, not inferred from one
successful loop. The changed appends consume their destination using cleanup-pop
and `ensure_capacity`, without a per-append retain of the old root.

| Owner | Actual C growth sites |
| --- | --- |
| ExpressionBuilder | `brp_tyT`, 62506: cursor + definitions only; no map field/destructor. |
| Expression definitions | 84182: incoming builder/vector still retained before append; **inherited COW debt**. |
| Argument IDs / record fields | 84318 / 84446: local roots; argument prefix may need first snapshot COW. |
| Recur definitions / IDs | 85007 / 85033: local roots. |
| Statement definitions | 85214: local root; result has no binding-map alias. |
| Arm captures / completed arm | 85528 / 85660, 85701: local roots; completed root initialized once from captures. |
| Arm inventory | 85887: local root. |
| Parameters / final function | 86033 / 86216, 86257: local roots; final root initialized once from parameters. |
| Program functions | 86402: local root. |

Map setters consume their local roots; each arm initially borrows the same outer
snapshot, and an initial snapshot COW is distinct from repeated prefix copying.
The phase-probe C has the same construction shape, SHA-256
`1d2ae8748e958b259acd1c5cce99b7a440cd4ad62c819b75ec7dd4da4080004c`.
This does not establish globally linear lowering or compilation.

## Matched phase measurements

Baseline is `e59346426d42f39d139408f44a4b030f695028b8`, with a FRESH host
`92d1e10d88bd1048d101a9864528695e4c34de6251435ab1c4e6c68ac743b30b`.
Host reports CLI -O0/runtime -O2; pilot/probe native flags are
`-O0 -DBLORP_MEMORY_DIAGNOSTICS=1 -lm -lpthread`, Apple clang 21.0.0 on arm64 macOS.
Phase native hashes: baseline `4ac623f5eff7e9c33dbe0951db0bbc6ed192eb5908d0e3e11cbb8cc2c57ed914`,
candidate `ca226b149040c5b5ce18800a9d30c73f06ec988075ef749c1047ad085178bf23`.

Each series has 72 samples: three R0 and R128 runs per shape/width. Setup,
checking and specialization stay outside the counter bracket. Minimum retired
instructions use `(min(R128) - min(R0)) / 128`; the bracket includes lowering,
output destruction and O(1) entry-definition checksum observation. Counters are
stable, checksums exact, and every process is strictly leak-balanced. The scratch
probe is measurement-only, not a test entrypoint or rewritten e2e fixture.

| Shape/width | Allocations before → after | Instructions before → after |
| --- | --- | --- |
| Statements 16 | 306 → 316 (+3.27%) | 668157 → 649423 (−2.80%) |
| Statements 32 | 578 → 590 (+2.08%) | 1370032 → 1217482 (−11.13%) |
| Statements 64 | 1122 → 1136 (+1.25%) | 3064748 → 2345686 (−23.46%) |
| Statements 128 | 2210 → 2226 (+0.72%) | 7651852 → 4604051 (−39.83%) |
| Wide 16 | 388 → 318 (−18.04%) | 831515 → 701295 (−15.66%) |
| Wide 32 | 725 → 577 (−20.41%) | 1688175 → 1384273 (−18.00%) |
| Wide 64 | 1398 → 1092 (−21.89%) | 3766862 → 3033415 (−19.47%) |
| Wide 128 | 2743 → 2119 (−22.75%) | 9412096 → 7508209 (−20.23%) |
| Deep 16 | 162 → 166 (+2.47%) | 343652 → 355455 (+3.43%) |
| Deep 32 | 290 → 295 (+1.72%) | 645073 → 662582 (+2.71%) |
| Deep 64 | 546 → 552 (+1.10%) | 1322755 → 1347939 (+1.90%) |
| Deep 128 | 1058 → 1065 (+0.66%) | 2971150 → 3013019 (+1.41%) |

Statement allocations add 10/12/14/16 as buffer capacity grows; deep adds 4/5/6/7.
These positive costs are retained, not called zero regressions. The coordinator
interprets the phase requirement as no **material** regression, subject to
independent reviewer agreement. The numeric whole-CLI ceiling remains +3% per
frozen input. No ceiling was raised.

## Whole-CLI proxy and retained limits

The **combined namespace + lowering** comparison has 36 frozen owned inputs and
216 alternating samples, identical emitted C and strict leak balance. Maximum
allocation change is **+0.299562%** (`fields-128`); maximum minimum-instruction
change is **−0.059467%** (`wrap-128`). This is not lowering-only attribution or
self-compile evidence: the pilot cannot self-compile. Baseline native hash is
`e6ac8ab7d079670fbceac2eaefb1abd04f1010e7e7230dfb561caf0305d1a4e1`;
combined candidate is `c898422cd391e2939ddaa935f498c98b2c7a22adc2131bd6f5491920d40c7fea`.

Raw phase receipts and recipe are under
`build/next-increments-20261014/lowering/{phase-baseline,phase-separated,measure_phase.rb}`;
phase recipe SHA is `2a593a4f83719f6367a9f5676ea08243b1c2efda573e50948c75b5c84ce5c6f5`.
Source archive/host provenance: `build/next-increments-20261014/baseline/`.
Whole-CLI samples/summary: `build/authority-fixes/next-preparations-combined-20261014/`.
Unit/mutation receipts: `lowering/separated-{unit,mutation}.*.log` in that build root.

Full-expression task prototypes were rejected: the first added +54 substantive
lines and large phase work, with +3.001277% whole-CLI allocations breaching the
unchanged ceiling; a direct scheduler added +86 lines and still regressed.
The block-only +38 draft exposed branch-continuation COW; completing products
before merging (+41 draft) fixed it. Removing the redundant expression projection
and readonly state field converged to this +22-line design. Rejected drafts and
`phase-{candidate,direct,block,freeze}` receipts remain in the same lowering build
directory; setup failures are distinct from behavioral/performance failures.

| Remaining acceptance | Status |
| --- | --- |
| Actual combined unit/runtime/grammar + normal-main e2e gate | `make -C blorp_2 test`: 2109 PASS/0 FAIL in 138 suites; 325 e2e PASS/0 FAIL; frontend and build-once callbacks each 1 PASS. Exactly one Generate/Link; stderr empty. Receipts: `build/next-increments-20261014/final-pilot.{stdout,stderr}.log`. |
| Independent final source, physical-proof and scaling review | Approved with zero findings. |
| Accepted checkpoint then current-main rebase | [Fresh preservation, cost and pilot gates pass](blorp_2_main_rebase_2026-10-14.md); before General List implementation. |

General Lists, updates and recursive data are not implemented by this preparation.
