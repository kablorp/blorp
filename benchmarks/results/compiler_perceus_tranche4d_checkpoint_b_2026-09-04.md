# Perceus Tranche 4D — Checkpoint B Fusion Contract

Checkpoint B adds the executable contract for borrowed-boundary fusion without
changing the production three-pass normalization path. The immediate parent is
Checkpoint A plus current `main`, revision `188351b2`.

Environment: macOS 26.6.2, arm64.

## Exhaustive child modes

`test_borrowed_boundary_child_mode_inventory.py` records independent call, storage, and
result behavior for every `CoreExpr` variant. Nested paths cover expressions in
records, lists, options, compiled match trees, loops, resource scopes, select
arms, and concurrent blocks. A support test derives both the complete variant
set and the transitively expression-bearing Core composite set from `ir.brp`,
so adding either without updating the inventory fails hygiene.

The inventory is test-only design authority for Checkpoint C. It does not add a
generic production visitor or change any phase boundary.

## Fixed fusion fixture

The matrix contains two uncalled ordinary functions. Each function has exactly
1,536 serialized expression nodes, 32 borrowed parameter owners, eight exact
global owners, and 96 fixed slots in each boundary family. Only the number of
active slots changes:

```text
density points=8,32,96
call slots=96 per function
storage slots=96 per function
result slots=96 per function
literal matches=1 per function
resource scopes=1 per function
nested lambdas=0
opaque padding nodes=0
measurement window=perceus-direct
```

Even-numbered sites rotate through the eight exact globals. Odd-numbered sites
rotate through projections of all 32 borrowed parameter owners. Balanced
ordinary sequences provide exact traversable padding; there is no outer cast or
other opaque padding wrapper.

## Checkpoint A work census

The preserved Checkpoint A counter worker produced the following exact counts.
Actions are totals across both functions.

| Active slots per family | Call visits | Storage visits | Result visits | Call rebuilds | Storage rebuilds | Result rebuilds | Actions per family |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 8 | 2,880 | 2,358 | 388 | 1,442 | 1,266 | 196 | 16 |
| 32 | 2,880 | 2,526 | 388 | 1,454 | 1,326 | 196 | 64 |
| 96 | 2,880 | 2,974 | 388 | 1,486 | 1,486 | 196 | 192 |

Every point reports exactly two normalized function regions, 64 parameter-owner
slots, and 16 global-owner slots. Call, aggregate, and result alias-fallback
requests are zero, as are their fallback expression visits.

The matrix currently fails only at its intentional Checkpoint C assertion:

```text
borrowed-boundary fusion requires one fused structural visit per expression
under the union child domain; Checkpoint C has not implemented that authority:
[0, 0, 0]
```

This red assertion is the production-cutover gate. Checkpoint C must make it
pass while retaining the exact action counts above and byte-identical Core.

## Focused correctness

The Perceus suite includes explicit characterization for a transferring
aggregate inside a consuming call, a consuming call inside transferring
storage under an incoming `DropExpr`, and path-local result satisfaction under
an existing `DupExpr`. The focused suite passes 333/333 tests. The benchmark
contract suite passes 57/57 tests, and the exhaustive inventory passes 4/4.

## Reproduction

```bash
benchmarks/compiler_perceus_memory \
  --borrowed-boundary-fusion-matrix \
  --bridge /tmp/blorp_issue51b_checkpoint_a/timing/compiler_backend_worker \
  --baseline-bridge /tmp/blorp_issue51b_checkpoint_a/timing/compiler_backend_worker \
  --counter-bridge /tmp/blorp_issue51b_checkpoint_a/counters/compiler_backend_worker \
  --baseline-counter-bridge /tmp/blorp_issue51b_checkpoint_a/counters/compiler_backend_worker \
  --samples 7 \
  --no-warmup \
  --json
```

Checkpoint A timing worker SHA-256:
`e935a50d66f48e568dc737db4cbe10861e0a88df8eadf935d93b93f6c8c30d32`

Checkpoint A counter worker SHA-256:
`6965bc36c377aa3b1888652cc5459a5ab45f5ab69b23954672fe42aa60c89b2c`

Checkpoint B harness SHA-256:
`bedd722a5c029b4ee46d886beaf7b9f8f9986b883c2edc4a686f0876f1fcd9c6`

The preserved workers remain under
`/tmp/blorp_issue51b_checkpoint_a/{timing,counters}/compiler_backend_worker`.
