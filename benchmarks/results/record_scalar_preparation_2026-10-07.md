# Managed-record scalar replacement: preparation

Status: eligibility audit and baseline probes, not an implemented optimization.
Base: `fca8644296c7b76990bfcda8ee9866fd5fe2cf81`.

## Problem and boundary

Small managed records can allocate even when their users read only fields.
The earlier literal-only pilot was parked after finding zero eligible sites
in its restricted compiler census. A new standalone record walker would both
repeat that limitation and overlap the shared-storage worker.

The live `codex/tuple-record-storage` worktree owns the record-construction
prerequisite, `ProductExpr`/checked `CoreProductBuild`, field-evaluation
normalization, replay of the shared binder supply, Perceus changes, runtime
tuple boundaries and typed storage. Its `docs/TUPLE_RECORD_STORAGE.md` puts
shared storage before scalar replacement and multi-value calls. That order
supersedes the earlier slice ordering in `PRODUCT_UNIFICATION.md`.

This preparation changes four new, independent benchmark/evidence paths.
It changes no compiler, runtime, existing tests or shared roadmap files, and
does not edit, rebase, merge or build the other worker's checkout. The probes
use source-language records so they remain useful when Core forms change.

## Reproduction and baseline

Run from a checkout with FRESH compiler inputs:

```bash
benchmarks/record_scalar_prepare --output /tmp/record-scalar-baseline.json
benchmarks/record_scalar_prepare --sanitize --output /tmp/record-scalar-sanitize.json
```

The runner invokes `bin/blorp run --no-format --memory-stats --leak-check
--release --timeout 180`, adding `--sanitize` for the second command. Nine
cases run at 256 and 512 iterations. Scalar counter endpoints bracket each
workload; formatting happens afterward. The harness calls return `Int`, so
the tested record does not cross the harness's function-reference ABI.
The program checks both counting gates, and the runner rejects wrong values,
missing/duplicate rows, ownership imbalance and broken boxed/inline/reuse
controls. Counts are observed data, not ceilings pinning an inefficient
baseline for future optimizers.

| Probe | Allocations at 256 | At 512 | Interpretation |
| --- | ---: | ---: | --- |
| `local_fields` | 256 | 512 | Literal local; projections only |
| `aliased_fields` | 256 | 512 | Immutable second name; projections only |
| `branched_fields` | 256 | 512 | One record produced by either arm |
| `call_result_fields` | 256 | 512 | Managed return; caller reads fields |
| `managed_child_fields` | 257 | 513 | One shared list setup plus record per iteration |
| `unique_updates` | 1 | 1 | Existing update reuse already succeeds |
| `fresh_reassignments` | 257 | 513 | Initial record plus fresh mutable assignments |
| `observed_identity` | 256 | 512 | Conservative boxed identity-sink control |
| `inline_fields` | 0 | 0 | Inline fixed-record control already succeeds |

Release counts equal allocation counts and every interval's live-object delta
is zero. Both normal and ASan/UBSan runs pass all 18 value/ownership probes,
have identical rows, and finish with zero leaks. Independent verification
rejects seven corrupted output variants: wrong value, missing row, duplicate
row, release imbalance, removed identity boxes, added inline boxes and broken
unique reuse. It also rejects three sanitizer diagnostics from processes
returning exit zero, even with a valid leak footer.

The compiler is FRESH with CLI/runtime O2 and Apple Clang 21. Its retained
banner names `b5a05c9593cf-dirty`; the current source HEAD is `fca864429`, and
build-input freshness confirms their code inputs match. Probe programs are
linked with diagnostic counting through the CLI flags. The retained
[packet](record_scalar_preparation_2026-10-07.json) binds source/compiler
hashes, commands, raw output, normal/sanitized results and generated artifacts.
These are tiny-program allocation observations. No self-compile allocation
or instruction improvement is established, and concurrent unrelated work
makes elapsed time unsuitable as performance evidence.

Capture the reported early Core and final C in one invocation:

```bash
bin/blorp compile --no-format --no-embed-runtime \
  --dump-core-after=specialize --dump-core-file=/tmp/record-scalar-preparation.core \
  -o /tmp/record-scalar-preparation.c \
  benchmarks/blorp/profiles/record_scalar_preparation.brp
```

Core locations include the checkout's resolved paths; its hash binds the
retained artifact rather than promising raw identity across checkout paths.

## Current code and ownership facts

`tuple_flatten.brp:1` describes the existing group machinery: immutable local
builds read only through projections can become groups; whole uses keep boxes.
Its `group_source` at line 540 recognizes built elements or an existing group.
It does not currently admit records. Checked record fields and projections
are defined by `ir.brp:4133` and `:4180`; eligibility must use the declaration
and its ordinals, preserving nominal identity rather than comparing spelling
or field shape.

The probe's early Core retains `make_pair` as a call returning `HeapRecord
Pair`; the call-result case is not silently reduced to a local literal by
the compiler. Final C has typed managed `Pair` construction and a managed
child destructor releasing its list field. `InlinePair` uses an inline
aggregate. Thus the controls distinguish logical record values from their
actual storage and ownership.

Fresh mutable assignment is different from explicit update. Perceus
`mutable.brp:631` prepares a fresh assignment as:

```text
let temporary = fresh_record
seq(drop old_pair, assign pair = temporary)
```

The fresh-record reuse matcher at `reuse.brp:2888` recognizes an adjacent
drop returning the temporary, while its traversal rejects `AssignExpr` at
line 2436. This assignment shape lacks a matching reuse proof. It is not a
general prohibition on reading the old record's fields. Explicit updates
carry an identified source and receive preparation before Perceus in
`record_update.brp:1240`, explaining their one-allocation control. Extending
mutable reuse is a separate option touching files the other worker owns.

## Proposed next implementation, after shared storage

Extend the existing product group-source and use analysis rather than adding
a parallel record pass. Use checked concrete source-record declarations,
their field types and ordinals. Exclude inline records, which already allocate
zero, and declared-native-ABI records at their adapters. No new layout promise
or nominal identity redesign is needed.

For the smallest admitted example:

```blorp
record Pair { first: Int, second: Int }

pure func sum(index: Int) -> Int:
    pair: Pair = { first = index, second = index + 1 }
    pair.first + pair.second
```

the proposed Core result binds the two authored values once, in written
order, and reads those element bindings without constructing a box. Reuse
the storage worker's checked build and binder supply. Managed element values
retain their evaluation and ordinary Perceus ownership, including unused
fields and cancellation cleanup. No new field-specific retain mask belongs
in this optimization.

Local immutable aliases name the same group. Nonliteral branches and call
results need the shared multi-value binding/call machinery. Mutable groups
require simultaneous RHS evaluation and correct per-element cancellation
slots before assignment. Parameters, globals and managed-field reads are
source boxes; projecting them alone must not reconstruct a new box.

Keep whole identity queries boxed under the current conservative admission
policy. The probe uses `same_object(pair, pair)`; a separate valid early fold
could eliminate that query, so its boxing count pins this policy rather than
proving that self-identity semantically requires an allocation. Calls, stores,
returns, comparisons and whole captures are conservative sinks until their explicit shared boundary
is implemented. Multi-value calls use the existing call-graph fixpoint and
function-reference adapters, with four data members initially. A mixed result
returns elements only when no caller stores it whole. Count re-box sites and
preserve source-box identity; never answer identity queries using fabricated
values for flattened storage.

## Acceptance, dependencies and stop conditions

The construction/storage prerequisite must land and its final APIs must be
reviewed before compiler edits start. Rebase this preparation afterward and
rerun the probes; current allocation totals are not predictions for that base.

Before implementing admission, refresh the compiler's dynamic maker census
and classify real checked sites beyond the parked pilot's exclusions. A
literal-only synthetic win with no exercised compiler sites is insufficient.
If the shared machinery is absent, the live census finds no useful cases, or
implementation requires a second walker/layout/binder authority, stop and
report the boundary instead of growing a parallel optimizer.

Require correct values, written evaluation order, managed-child ownership,
aliases, unchanged identity/source-box controls, existing unique reuse,
and mutable `continue`/cancellation behavior. Require zero record allocations
per iteration for admitted cases, count necessary re-boxing separately, and
prove net self-compile allocation reduction with non-regressing retired
instructions on matched stage-2 O2 builds. Review before/after Core and C;
run owning suites, selected compiler gates, sanitizer/leak/runtime controls,
the C audit and stage-2/3 fixpoint. No speed claim comes from this preparation.

Handback: the admitted shapes and exclusions, exact code boundary reused,
matched workload/compiler provenance, raw observations, attributable C
changes, gate results and any deferred boundary. This preparation remains
independent of the other worker's integration.
