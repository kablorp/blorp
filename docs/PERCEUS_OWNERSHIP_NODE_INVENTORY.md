# Core Ownership Node Inventory

Status: current as of 2026-08-13.

`DupExpr` and `DropExpr` are protocol nodes shared by several Core passes.
Perceus owns general lexical ARC balancing and borrowed-to-owned normalization;
it is not the sole producer of these nodes. This inventory prevents cleanup
work from deleting or duplicating ownership that belongs to another protocol.

The inventory was checked with:

```text
rg -l 'DupExpr\(|DropExpr\(' compiler/blorp/src/stage_09_core -g '*.brp'
```

Constructor syntax appears in pattern matches as well as construction sites,
so every match requires owner review. A textual occurrence is not evidence
that a pass introduces ownership.

## Producers

| Phase | Module | Responsibility |
| --- | --- | --- |
| Pre-Perceus | `core_synth_hash_collections.brp` | Synthesizes accumulator cleanup for generated hash-collection helpers. |
| Pre-Perceus | `core_collection_pipeline.brp` | Marks generated mutable accumulator replacement boundaries, including deliberate no-release drops consumed by later ownership handling. |
| Pre-Perceus | `core_consume_specialize.brp` | Inserts protocol drops when a consuming specialization transfers an argument but must return another result. |
| Perceus | `core_perceus.brp` | Inserts and balances general lexical retains/releases, borrowed-to-owned handoffs, mutable replacement ownership, and branch ownership. |
| Post-Perceus | `core_closure.brp` | Adds closure/capture and task-environment lifetime ownership while converting closure representations. |
| Post-Perceus | `core_resource.brp` | Adds release nodes to resource cleanup paths and preserves ownership wrappers while inserting cleanups. |

These producers must have focused ownership-event tests. Perceus must preserve
and account for ownership nodes already present at its input; it must not
assume every incoming node was emitted by Perceus itself.

## Policy Rewriters And Consumers

| Module | Responsibility |
| --- | --- |
| `core_match_projection.brp` | Rewrites existing retain/release policies to no-op policies for singleton constructors whose representation needs no ARC operation. |
| `core_reuse.brp` | Consumes proven post-Perceus drops when upgrading reuse opportunities, removes matched drops where ownership transfers, and preserves unmatched nodes. |
| `core_prepare.brp` | Preserves ownership nodes while preparing backend forms and policies. |

These modules may change or consume an existing event but do not own general
lexical balancing.

## Structural Preservation And Analysis

The following modules inspect, map, rebuild, serialize, or hash ownership nodes
without introducing an independent ownership protocol:

- `core_dce.brp`
- `core_fairness.brp`
- `core_json.brp`
- `core_match.brp`
- `core_resolve.brp`
- `core_ssa.brp`
- `core_std_inline.brp`
- `core_tailrec.brp`
- `core_traverse.brp`
- `core_tuple_sroa.brp`

Structural passes must preserve variable identity, value type, policy, and
control-flow placement. The canonical ownership-event projection in
`compiler/blorp/tests/test_support_core_ownership_events.brp` is the parity
oracle for cleanup changes.

## Review Rules

1. A new ownership producer must be added to this inventory in the same
   change, with a focused event-placement test.
2. A structural rewrite must compare canonical ownership events before and
   after unless it intentionally consumes or creates a documented event.
3. Event counts alone are insufficient. A moved release, changed policy, or
   wrong variable identity can retain the same count and still be incorrect.
4. No-op policies are still protocol facts. Do not delete their nodes without
   proving the consuming pass no longer needs the structural boundary.
