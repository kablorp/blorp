# Replace three layout sort callbacks with one domain ordering

**Status, 2026-10-18.** Design reviewed; implementation has not started. The
coordinator and one independent compiler expert are the two required plan
reviewers; both accepted the proof obligation and measurement boundary below.
This docs-only slice publishes the plan. A reviewed plan commit and an explicit
serialized execution window precede TDD, production edits or compiled calls.

## Problem and baseline

At immutable baseline `e906b8104f269ace2ca990693a5bae417f73b006`, the
[emitter](src/emit/emit.brp), lines 2223-2226, still uses three `sort_by` callbacks.
They prevent this path from becoming first-order. Existing emitted behavior is
correct: final ordering is lexicographic `(depth, rank, ordinal)`, followed by
adjacent semantic-key deduplication. This is a source refactor, not a bug fix;
the first test result must be baseline GREEN rather than a manufactured red.

Reproduce the remaining boundary read-only:

```sh
git show e906b8104f269ace2ca990693a5bae417f73b006:blorp_2/src/emit/emit.brp | rg -n 'sort_by'
```

It prints lines 2224-2226. After implementation the callbacks disappear and all
accepted source programs retain byte-identical C and diagnostics. Removing these
three callbacks does not establish complete HOF retirement or self-hosting.
Baseline Git blobs: emit `7299c7c9ffb1d5a7a89f6ca515a71be898fb60f3`;
runtime/list `e36ef97c5cdf430d5b89f73997680e419b848182`.

## Proposed solution and code

One private recursive operation, `ordered_list_layouts`, performs conventional
top-down stable merge sort. Its input/output are the existing `List[ListLayout]`.
It splits at half length, recursively orders both halves, then merges their
Option heads. `get(length)` denotes genuine exhaustion, never an invented row
or invalid-state recovery. A strictly smaller right key wins; equality takes
the left row. No comparator callback/helper, decorated list, cached key table,
new semantic type, String comparison or export is needed. The recursion is the
helper's reason to exist under [CODE_STYLE rule 2](../docs/CODE_STYLE.md).
Ordinary managed recursion is already supported by the [README](README.md);
stack depth is O(log N). Each half preserves its encounter order inductively,
and choosing the left equal head preserves that order across the split.

Current code, `emit.brp:2223-2226`:

```blorp
ordered = layouts
    .sort_by(pure func(layout): list_key_ordinal(layout.key))
    .sort_by(pure func(layout): list_key_rank(layout.key))
    .sort_by(pure func(layout): list_key_depth(layout.key))
```

Proposed replacement:

```blorp
ordered = ordered_list_layouts(layouts)
```

Illustrative complete helper, inserted immediately before `list_layouts`.
This is an uncompiled design example, not a prepared production patch:

```blorp
private pure func ordered_list_layouts(layouts: List[ListLayout]) -> List[ListLayout]:
    if not IntOps.greater_than(layouts.length(), 1):
        layouts
    else:
        midpoint = IntOps.divide(layouts.length(), 2)
        var left: List[ListLayout] = []
        var right: List[ListLayout] = []
        var position = 0
        for layout in layouts:
            if IntOps.greater_than(midpoint, position):
                left = left.append(layout)
            else:
                right = right.append(layout)
            position = IntOps.add(position, 1)
        left = ordered_list_layouts(left)
        right = ordered_list_layouts(right)
        var left_index = 0
        var right_index = 0
        var left_head = left.get(left_index)
        var right_head = right.get(right_index)
        var ordered: List[ListLayout] = []
        while True:
            match left_head:
                None:
                    match right_head:
                        None: break
                        Some(layout):
                            ordered = ordered.append(layout)
                            right_index = IntOps.add(right_index, 1)
                            right_head = right.get(right_index)
                Some(left_layout):
                    match right_head:
                        None:
                            ordered = ordered.append(left_layout)
                            left_index = IntOps.add(left_index, 1)
                            left_head = left.get(left_index)
                        Some(right_layout):
                            right_first = if IntOps.equals(list_key_depth(left_layout.key), list_key_depth(right_layout.key)):
                                if IntOps.equals(list_key_rank(left_layout.key), list_key_rank(right_layout.key)):
                                    IntOps.greater_than(list_key_ordinal(left_layout.key), list_key_ordinal(right_layout.key))
                                else:
                                    IntOps.greater_than(list_key_rank(left_layout.key), list_key_rank(right_layout.key))
                            else:
                                IntOps.greater_than(list_key_depth(left_layout.key), list_key_depth(right_layout.key))
                            if right_first:
                                ordered = ordered.append(right_layout)
                                right_index = IntOps.add(right_index, 1)
                                right_head = right.get(right_index)
                            else:
                                ordered = ordered.append(left_layout)
                                left_index = IntOps.add(left_index, 1)
                                left_head = left.get(left_index)
        ordered
```

The existing adjacent `same_list_key` dedupe in `list_layouts:2227-2237`
remains unchanged. Depth is primary, preserving child-before-parent helper
definitions; rank preserves primitive/Record/Union domains; ordinal retains
nominal instance identity. No field is recovered from emitted spellings.
Bottom-up global-buffer merging was considered: with today's fresh-copy append,
each of log N passes rebuilds a growing N-element list, causing O(N² log N)
slot writes. The chosen split/merge uses O(N²) writes and simpler boundaries.
Insertion sorting would require moving slots through fresh-copy `set`, with
potential O(N³) slot copying. Neither is the proposed implementation.

## Equal-key proof obligation

The coordinator and independent compiler expert accepted this precise rescope:
keep the stable left-biased implementation and review its tie branch, but replace
a dynamic equal-key-origin mutation requirement with observable ordering,
deduplication and C-identity oracles.

Reason: `ListLayout:2107-2110` contains only `element: TypeRef` and
`key: ListElementKey`. Its factories always derive that key from the element.
`runtime/list:12-44,51-96` encodes List depth plus a typed primitive terminal,
RecordInstanceId or UnionInstanceId. In the current closed concrete `TypeRef`
domain consumed by emission at the pinned baseline, equal keys imply
`Concrete.same_type` equality, including phantom instances and distinct nominal
domains. This establishes current emission-row equivalence only; it neither
establishes future opaque semantic identity nor authorizes recovering semantic
meaning from a representation key. Existing `test_flat_key_equality_is_exact_semantic_type_equality`
checks this over primitives, valid specialized nominals and nested Lists.

Consumers (`append_list_prototypes`, `element_fragments`, `append_list_runtime`)
read only those values; equal rows are immediately deduplicated. Thus choosing
the right equal row changes no permitted emitted C, diagnostic or native program
result. ARC pointer identity is not language-level data. A right-biased tie
mutant would survive valid observable tests; it must not be reported as killed.
Do not forge a checked product, add encounter tags to production rows, expose
the private sorter, call generated internal symbols or create an alternate main
to manufacture a distinction. This changes the proposed proof obligation, not
accepted behavior. If review finds a legitimate distinguishing observer, revise
this argument and its tests before implementation; do not extend this proof
beyond the current concrete emission domain.

## Construction cost and measurement boundary

Current target `runtime/list.brp:197-216` always allocates a fresh append/set
root and copies surviving slots, even for a unique input. Empty literal roots
also allocate (`emit:1289-1306` and `list_root_allocation:117`). No target COW
or builder improvement is included here. O(N log N) comparison count does not
make this an O(N log N) target construction.

For N=2^p input rows, this proposed operation performs `2*N*p` appends,
`3*(N-1)` empty-root constructions, and
`S = 3*N*N/2 - 3*N/2 + N*p` slot stores. Its list-root allocation requests
are `A = 2*N*p + 3*(N-1)`; requested bytes are `A*H + S*E`, where H is the
actual emitted root header size and E the actual emitted row slot size.
Do not assume ListLayout is an inline scalar. These figures exclude input,
inventory, final dedupe/output, key/row/Option representation costs and allocator
overhead; they are derived schedule counts, NOT measured total allocations.

| N | Appends | List roots A | Slot stores S | Existing-slot copies |
| ---: | ---: | ---: | ---: | ---: |
| 16 | 128 | 173 | 424 | 296 |
| 32 | 320 | 413 | 1,648 | 1,328 |
| 64 | 768 | 957 | 6,432 | 5,664 |
| 128 | 1,792 | 2,173 | 25,280 | 23,488 |

Measure N=16/32/64/128 through public `emit(VerifiedProgram)`, preparing each
normal parsed/checked/specialized/lowered/owned/verified product outside the
interval. No private hook. Use N distinct Int-only records with parameterized
makers: call all makers in ascending order, then construct their singleton
Lists in descending order and sum their lengths in real main (result N).
Check published concrete IDs and main's definition types so this really supplies
N descending distinct depth-zero rows; do not assume source spelling establishes
ordinal order. Include small odd-sized cases for unbalanced halves. These are
host-compiled public emitter measurements, including inventory/dedupe/emission;
host append behavior can differ from target fresh-copy behavior.

Use one bounded native runtime-helper measurement callback in the existing
`test/runtime/test_generic_list.brp`, under the [authorized direct-C runtime-helper
exception](AGENTS.md#validation). It writes temporary C containing unchanged
public production List runtime fragments and a scalar probe, with delegating
malloc/free counters.
No persistent C fixture or generic harness/export is added. For each N, append
N times from an empty root and separately perform N sets on an N-slot root;
verify old aliases, exact values, root/byte requests and balanced destruction.
Counters observe only allocation requests, never freed objects. Predicted append
requests are N+1 roots and N(N+1)/2 slots; N sets request N roots and N² slots,
excluding their seed. This measures actual primitive copy economics, NOT the
private ordering under target compilation. The merge schedule above composes
those costs analytically. Target execution of this actual private sorter is not
currently available through a supported normal compiler entrypoint; do not
claim it. Both plan reviewers accepted this measurement boundary. Any later
target-execution claim requires evidence through its supported normal entrypoint.

## Scope, conflicts and dependencies

- Production: only the new operation and call in `emit/emit.brp` around 2216-2226.
  No changes to ListLayout, key factories, runtime ABI or adjacent dedupe.
- Unit characterization: existing `test_emit/test_list_phases.brp`, provisionally
  <=110 added lines; native scalar probe in existing `test/runtime/test_generic_list.brp`,
  provisionally <=90. Combined hard test cap 200 added/+200 net; fixtures 0.
  If honest readable tests cannot fit, rescope before editing; do not compress.
- Hard production caps: 250 gross added/+100 net physical lines, including
  imports/comments. Example helper leaves room below that cap; count actual diff.
- M2 owns nearby `function_blocks` (2143), `ProgramInventory`/`program_inventory`
  (2170-2212), and the seven-fill functions including emit's aggregate visits
  (571-572). Do not edit these regions or any lower/own/verify fill. The
  coordinator received the control/M2 owner's explicit reservation acknowledgement:
  only insert the private operation immediately before `list_layouts` and replace
  its three `sort_by` calls. The neighboring inventory and aggregate-fill regions
  remain with their existing owner.
- Opaque preparation may alter TypeRef projections. Revalidate equivalent key
  injectivity and freeze the actual accepted predecessor if it lands first;
  never apply this plan to stale bytes silently.
- This docs-only slice has no compiled slot. Freeze accepted B, exact candidate C,
  source/target libraries, corpus, host binaries/stdlib and checkpoint roles
  before future execution. Start from a clean accepted branch/worktree; do not
  reuse a preserved mixed candidate.

## TDD and runnable gates

After plan agreement, add baseline-green characterization of no layouts,
one key, duplicates, odd halves, and adversarial mixed depth/rank/ordinal order.
Use valid source through ordinary public phases. Existing runtime key tests
protect primitive/nominal/phantom identity. Definition markers must include the
opening `{`, avoiding earlier `;` prototypes; C name checks are output assertions,
never semantic reconstruction in production. Check exactly one definition per
key and child before parent. The mixed witness must include Record1 and Union0,
so rank-versus-ordinal priority is observable, plus same raw number across domains.

Once implementation is green, independently reverse depth, prioritize ordinal
before rank, omit ordinal, omit an exhausted-half row, and bypass dedupe. Every
mutant must build and fail its named output oracle, then restore byte-exactly
and pass. No successful compilation counted as mutation sensitivity. No tie
origin mutation claim. Preserve exact baseline/candidate C over the complete
current corpus and normal native real-main entrypoints.

Run commands only after the coordinator grants the serialized window, in a clean
candidate worktree built from the fixed accepted B:

```sh
scripts/compiler-build-status
# Run make and recheck only if STALE/UNKNOWN; no separate build agent.
bin/blorp test --timeout 180 blorp_2/test/unit/test_emit/test_list_phases.brp
bin/blorp test --timeout 180 blorp_2/test/unit/test_runtime/test_list.brp
bin/blorp test --timeout 180 blorp_2/test/runtime/test_generic_list.brp
bin/blorp test --suite --timeout 180 blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
make -C blorp_2 test-compiler
make -C blorp_2 test-e2e
git diff --check
```

## Acceptance and handback

Require baseline/candidate characterization green, effective restored mutants,
complete components/e2e green, inspected generated C, byte-identical C/diagnostics,
strict zero leaks and all existing absolute caps. Every unchanged owned input
and original SOURCE schema1 `artifact_construction_complete total_allocations`
checkpoint must satisfy <=+3% allocations and normal minimum-of-three retired
instructions against the fixed current accepted B. Preserve the [source-plan
cumulative reset requirements](BOOTSTRAP_SOURCE_PLAN.md#acceptance-and-cost-boundaries)
as well: the prior type-argument slice's R0 exception grants this slice none.
If cumulative compliance is unavailable or fails, report it
UNVERIFIED/FAIL and stop; do not substitute FEATURE TOTAL, change metric regimes,
roll B, refreeze after failure or quietly waive the gate.

Use the collector protocol described by the [accepted type-argument report](../benchmarks/results/blorp_2_first_order_type_arguments_2026-10-18.md)
only after independently reviewing and freezing fresh pins; do not execute its
old install paths or configuration against this new task. Separate strict runs
from normal min3; normal MEMORY_STATS/leak controls unset. The original SOURCE diagnostic
checkpoint uses MEMORY_STATS=1 with leak unset and status 0. Whole-source C can
change because the compiler implementation changed; behavior-generated C for
unchanged owned inputs must be identical.

Hand back exact patch/physical production-test-fixture counts, source/binary/std
hashes, raw paths and matched per-input/checkpoint tables, native primitive
measurements versus the explicitly analytic merge table, mutation failure names
and restored hashes, review findings and accept/reject recommendation. Stop at
any LOC/cost breach, unsupported ordinary entrypoint, legitimate new tie observer,
region conflict or suspected compiler defect. No hidden instrumentation, helper
framework or iterative algorithm redesign is authorized to rescue a failed pilot.
