# Step 3a: Reuse One Validated Body-Outcome Table

**Status:** Implemented in the current worktree; Step 3 remains open.

## Boundary and decision

Phase 6 already checks each body in a fresh session and returns
`BodyCheckAccepted` or `BodyCheckRejected` with an exact `CallableId`. Before
this packet, `BodyOutcomeIndex` built a module-scoped dictionary from those
outcomes for CTFE subset and ordinary materialization. The seeded CTFE-to-
ordinary path then copied the seed outcomes into another list, checked missing
contexts, and rebuilt the same dictionary from that list. Plan provenance was
also checked with separate `filter` and `map` passes before admission.

The first production consumer is seeded ordinary materialization. The
validated `BodyOutcomeTable` remains keyed by definition ID and stores the
accepted/rejected union directly:

```blorp
private record BodyOutcomeTableRep {
	by_definition_id: Dict[Int, BodyCheckOutcome]
}
```

CTFE subset and ordinary materialization both consume this table. Seeded
completion validates the seed once, reuses exact-ID rows, replaces only
policy-incompatible rows with a fresh body check, and passes the resulting
table directly to ordinary materialization. It no longer builds the
intermediate outcome list or a second dictionary. One admission loop checks
plan provenance, module ownership, and duplicates; plan mismatch still takes
precedence over ID errors. Parsed declaration traversal, not dictionary
iteration, continues to determine typed output and diagnostic order.

The table is intentionally allowed to be partial for a CTFE subset. A complete
body producer, not the table type, establishes full body coverage. This packet
does not claim a source-order row relation, a graph-wide body catalog, or removal of
the CTFE bridge's per-dependency `checked.filter(...).map(...)` grouping.

## Fast feedback and behavior

- Failing-first structural test: seeded success must call the table consumer
  without appending an outcome list or rebuilding a second table. It failed
  before the production edit and passes afterward.
- `bin/blorp test blorp/test/compiler/stage_06_typecheck/test_body_check_order.brp`:
  21/21, including out-of-order mixed accepted/rejected seeds versus ordinary
  typed output and source-order diagnostics, stale-plan rejection, and duplicate
  subset admission.
- `bin/blorp test blorp/test/compiler/stage_07_ctfe/test_ctfe_typecheck_profile_benchmark.brp`:
  15/15, including selected-module CTFE body reuse.
- `python3 -m unittest blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary`:
  54/54.
- `scripts/compiler-check --changed`: build and 6/6 selected suites passed.
- `scripts/test compiler-blorp`: 4,551/4,551 passed.
- `scripts/test runtime leak`: runtime 4,474/4,474 and leak 890/890 passed.

## Paired resource screen

The retained benchmark now accepts a final `selected` argument, which selects
the last dependency as a compiled output module and exercises seeded reuse:

```bash
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
```

Baseline was `main` at `10bfbb95`; candidate was the current Step 3a worktree
based on `f8171016`. Both workers used identical benchmark source, compiled
with Apple clang 21.0.0 at `-O2 -fwrapv` on Darwin 25.6.0 arm64. The baseline
worker SHA-256 was `64525f56db424d0a5394f97db9152b1be14fc56c55416ce6f210f4e07e2f73ff`;
the candidate was `527a8347681f52ed8c7e66f319be351c998518ef1930eeeb392341148a60a2ca`.
The benchmark source was copied into a temporary detached baseline worktree
for this comparison; that worktree was removed afterward.

| Selected workload, 3 iterations | Baseline | Candidate |
| --- | ---: | ---: |
| Checksum | 2,538 | 2,538 |
| CTFE dependency body checks / reused bodies | 72 / 3 | 72 / 3 |
| Allocations / releases | 772,770 / 772,767 | 772,599 / 772,596 |
| Retained objects / bytes | 3 / 192 | 3 / 192 |
| Native worker bytes | 6,354,000 | 6,354,784 |

Two alternating direct worker pairs (`/usr/bin/time -l`, same arguments)
recorded the following raw process observations. The first ran baseline then
candidate; the second ran candidate then baseline:

| Pair | Baseline retired instructions | Candidate retired instructions | Baseline peak footprint | Candidate peak footprint | Baseline maximum RSS | Candidate maximum RSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1,570,256,119 | 1,572,417,010 | 14,942,520 | 15,008,056 | 20,004,864 | 20,004,864 |
| 2 | 1,570,953,631 | 1,572,265,742 | 15,008,080 | 15,008,056 | 20,054,016 | 20,004,864 |

Allocations fall by 171 (0.022%) in the seed-bearing workload. Instructions
are 0.08–0.14% higher, peak footprint ranges from effectively equal to 0.44%
higher, and worker size is 0.012% higher—all below the roadmap's investigation
thresholds. In-process elapsed samples crossed directions, so this packet
makes no latency-win claim. A non-selected 3 × 24 × 32 guard kept checksum
2,916 and retained 3 / 192 while allocations fell 766,575 → 766,338; that
separate mode does not exercise seeded completion.

## Acceptance and next cut

This is an enabling Step 3 packet, not the checkpoint resource acceptance:
one old list and one duplicate table construction are deleted, both
materializers have a production table consumer, and no guard threshold is
breached in the paired screen. The measured allocation benefit is small.
Step 3b should replace the CTFE bridge's copied per-module outcome lists and
per-dependency scans with one validated module-scoped table handoff. It must
show a stronger latency/work reduction without retaining a parallel body
authority, then revisit full source-order rows and completeness proof.
