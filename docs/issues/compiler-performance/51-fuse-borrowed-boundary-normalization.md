# Fuse Borrowed Boundary Normalization

**Status:** In progress — Checkpoint A implemented; Checkpoints B–C proposed

**Roadmap:** Perceus ownership optimization, Tranche 4D

**Dependencies:** Issues 48–50

**Parallel work:** None. This issue changes the shared borrowed-boundary
traversal authorities. Complete and commit each checkpoint below before starting
the next one, and do not implement it concurrently with another Perceus rewrite.

## Objective

Replace the independent all-owner call, aggregate-transfer, and result-position
reconstruction passes with at most one borrowed-boundary reconstruction traversal
for each nonempty function, lambda, or global-initializer ownership region.

The final implementation must be simpler as well as faster:

- an ordinary function has one ordered catalog containing its borrowed
  parameters followed by its exact referenced managed globals;
- a lambda retains its existing parameter, capture, then global catalog order;
- global initializers retain their exact referenced-global catalog;
- one exhaustive traversal owns binder, compiled-match, resource, and collection
  descent for the three borrowed-boundary families;
- call contracts, prepared storage metadata, and function-result position remain
  distinct typed concerns; and
- the superseded all-owner structural walkers and their duplicate helper families
  are deleted.

This is an output-preserving compiler optimization. It must not add, remove, or
reorder ownership operations in the resulting Core program.

## Why This Issue Exists

Issues 48–50 removed owner-multiplied reconstruction but intentionally retained
three independently validated all-owner passes:

```blorp
call_body = protect_borrowed_calls_for_owner_catalog(env, owners, body)
aggregate_body = retain_borrowed_aggregates_for_owner_catalog(env, owners, call_body)
retain_borrowed_results_for_owner_catalog(env, owners, return_type, aggregate_body)
```

Those passes still reconstruct overlapping portions of the same body and
duplicate substantial binder, match, resource, and collection traversal code.

Ordinary functions also retain a transitional split left by Issue 49:

```text
borrowed-parameter catalog: call -> aggregate -> result
referenced-global catalog:  call -> aggregate -> result
```

Fusing each catalog independently would leave two structural walks per ordinary
function and would not satisfy the ownership-region objective. This issue must
first prove that parameter and global owners can share one ordered function
catalog while preserving the immediate parent's output.

The intended complexity after the change is:

```text
catalog construction: O(P + G)
structural normalization: O(N)
indexed boundary candidates: proportional to matching name buckets
explicit compatibility queries: measured separately
```

where `P` is borrowed parameters, `G` is exact referenced managed globals, and
`N` is the number of expressions in the ownership region.

## Immediate Parent And Comparison Points

The initial parent is main after Issue 50. Record its exact commit in the
benchmark report before making changes.

This issue has two output-comparison boundaries:

1. Checkpoint A compares the combined function catalog with the unchanged Issue
   50 parameter-then-global implementation.
2. Checkpoint C compares the fused normalizer with the committed Checkpoint A
   three-pass implementation.

Commit Checkpoint A separately. Preserve production and debug/counter workers
for both comparison boundaries before deleting or renaming their authorities.
Do not use a pre-Tranche-4 revision as either baseline.

## Required Reading

Read Issues 48–50, their benchmark reports, and the Perceus roadmap. Inspect
every helper reachable from:

- `normalize_borrowed_owner_catalog`;
- `protect_borrowed_calls` and `protect_borrowed_param_calls`;
- `retain_borrowed_aggregate_transfers` and
  `retain_borrowed_param_aggregate_members`;
- `retain_borrowed_results_for_owners` and the scalar result helpers;
- `first_borrowed_owner_aliasing_expr`;
- `normalize_lambda_body_ownership`;
- `rewrite_function` and global-initializer rewriting;
- compiled-match, loop, and lexical-shadow context helpers; and
- every incoming `DupExpr`/`DropExpr` or unresolved-identity compatibility path.

Before implementation, create an inventory mapping every `CoreExpr` variant and
every nested expression-bearing Core record to the children visited by each of
the three current all-owner passes. The inventory must be reviewed and enforced
by a test; a prose-only table is not sufficient.

## Scope

### Included ownership regions

- ordinary function bodies;
- lambda bodies; and
- global initializers with a nonempty referenced managed-global catalog.

Nested lambda bodies are opaque to an outer borrowed-boundary traversal and are
normalized by their own invocation. Global discovery and runtime-capture
discovery retain their established semantics even where those discovery
authorities inspect nested syntax.

### Explicit non-goals

Do not include any of the following:

- match- or loop-local borrowed-owner balancing owned by Tranches 5–6;
- resource, mutable-slot, select, or concurrency binding lifetime redesign;
- cross-pass ownership-fact retention;
- referenced-global discovery optimization;
- changes to call contracts or prepared storage metadata;
- elimination or canonicalization of emitted `DupExpr`/`DropExpr` operations;
- a public or phase-crossing generic Core visitor API; or
- changes to runtime ARC behavior.

Scalar helpers that remain live only for the local-binding paths above are not
deleted merely to make the fusion diff larger. The obsolete all-owner structural
authorities must be deleted.

## Required Design

### Ownership-region identity is distinct from owner origin

`BorrowedOwnerEntry.origin` already distinguishes function parameters, lambda
parameters, lambda captures, and referenced globals. Catalog region identity
must describe the independently owned body rather than whichever owner source
created the catalog.

Use region variants equivalent to:

```blorp
private enum BorrowedOwnerRegionKind:
	FunctionOwnerRegion
	LambdaOwnerRegion
	GlobalInitializerOwnerRegion
```

Do not infer the region from the first catalog entry. Empty entry lists continue
to bypass catalog construction and borrowed-boundary reconstruction entirely.

### One ordered catalog per region

Preserve these orders exactly:

```text
ordinary function:
  managed borrowed parameters in declaration order
  then exact referenced managed globals in ascending global index

lambda:
  managed lambda parameters in declaration order
  then runtime captures in established capture order
  then exact referenced managed globals in ascending global index

global initializer:
  exact referenced managed globals in ascending global index
```

For ordinary functions, referenced-global discovery must be evaluated against
the pre-normalization contract body during Checkpoint A. Prove that it selects
the same exact global definitions as discovery against the current
parameter-normalized body. Do not assume that the two are equivalent merely
because current rewrites normally introduce parameter references.

If a combined function catalog cannot reproduce byte-identical Core and C, stop
Checkpoint A and revise the one-region design. Do not silently retain two
catalogs while claiming one function-region traversal.

### Traversal dimensions are independent

The current passes have different child domains. For example, call
normalization traverses some transparent expressions that aggregate
normalization intentionally treats as opaque, while result normalization follows
only result-carrying children. A fused traversal must therefore carry independent
typed dimensions equivalent to:

```blorp
private enum BorrowedCallTraversal:
	TraverseBorrowedCalls
	SkipBorrowedCalls

private enum BorrowedStorageTraversal:
	TraverseBorrowedStorage
	SkipBorrowedStorage

private enum BorrowedResultPosition:
	OrdinaryBorrowedPosition
	BorrowedResultPosition

private struct BorrowedChildMode {
	call_traversal: BorrowedCallTraversal,
	storage_traversal: BorrowedStorageTraversal,
	result_position: BorrowedResultPosition
}
```

The exact names may differ. Do not replace these independent concerns with one
exclusive `Call | Storage | Result` union: a subtree may participate in more
than one boundary family.

Lexical visibility and result satisfaction are separate context:

```blorp
private record BorrowedNormalizationContext {
	env: PerceusEnv,
	owners: BorrowedOwnerCatalog,
	shadowed_owner_ids: Dict[Int, Bool],
	result_satisfied_owner_ids: Dict[Int, Bool]
}
```

The design must express all of the following without spelling heuristics:

- lexical shadowing disables an owner for every enabled boundary family;
- an existing `DupExpr` satisfies only the matching owner's result obligation
  beneath that node;
- result satisfaction does not escape upward, enter a sibling, or enter a
  non-result child;
- call or storage retention can make the affected evaluated value owned without
  hiding unrelated lexical identity;
- call and storage handling can both apply to overlapping syntax; and
- match bindings affect only the child regions in which their definitions are
  live.

### Explicit ownership transitions

The old passes sometimes observe wrappers inserted by an earlier pass. A fused
walk cannot depend on a second traversal rediscovering those wrappers.

Return a typed local normalization effect, or use an equivalently explicit
mechanism, whenever a boundary action changes what a parent must do. The design
must distinguish at least:

- no ownership transition;
- a boundary value made independently owned by call protection;
- a transferring storage child made owned; and
- a result obligation already satisfied by an incoming or inserted retain.

Do not infer these states from synthetic variable spelling or by rescanning the
new expression tree. Keep the effect private to Perceus unless another measured
consumer is established.

### Structural and action order

For each node:

1. derive an explicit `BorrowedChildMode` for every expression-bearing child;
2. normalize enabled child domains exactly once;
3. rebuild the parent once;
4. apply the parent call contract to consuming evaluated children;
5. apply prepared storage-transfer metadata to the relevant child slots; and
6. apply result ownership when the rebuilt node is in result position.

This is a construction rule, not a claim that compiler-internal action events
occur in the same chronological order as three whole-program passes. A
post-order walk necessarily interleaves actions from different families.

Correctness is defined by the resulting Core ownership wrapper nesting,
generated C, and runtime behavior. Action counts and the action multiset must
match the immediate parent. The chronological debug trace of rewrite-helper
calls is not an output contract and must not be preserved by buffering actions.

### Result-satisfaction scope

Result satisfaction is path-local. For:

```blorp
DupExpr(owner, body)
```

only the matching owner is satisfied, and only while normalizing `body` in
result position. Satisfaction must not affect:

- the parent of the `DupExpr`;
- a sequence's first expression;
- a let or borrow-let initializer;
- conditions or match scrutinees;
- another conditional or match branch;
- resource acquisition or cleanup unless it is independently a result child; or
- call and storage queries for the same owner.

Encode these rules in child modes and focused tests, not comments alone.

### Compatibility islands

Incoming ownership nodes and unresolved identities remain compatibility cases,
but they may not regain structural authority over a region.

Required rules:

- `DupExpr` and `DropExpr` are structurally traversed once by the fused walker;
- the current `protect_borrowed_calls_legacy_active` behavior, which rewalks a
  subtree once per active owner, must not remain reachable from the fused path;
- an exact local alias query may scan a candidate name bucket or, where
  unresolved identity requires it, the ordered owner catalog;
- scalar query work must not recursively rewrite the queried subtree;
- fallback requests, candidate visits, and any fallback expression visits are
  counted by boundary family; and
- ownership-ready benchmark fixtures have zero scalar fallbacks.

The structural-visit claim is independent of catalog size. Candidate and
fallback work is reported separately and must not be hidden in the fused visit
counter.

### Exhaustive child-mode inventory

The inventory is part of the implementation contract. It must:

- name every `CoreExpr` variant from `ir.brp`;
- cover expression children stored inside records, lists, options, compiled
  match trees, loop structures, resource scopes, select arms, and concurrent
  blocks;
- record the old call, storage, and result behavior for each child;
- distinguish nested-lambda opacity from leaf expressions;
- group variants only when all three old authorities have identical child
  behavior; and
- fail a test when a new `CoreExpr` variant is added without an inventory entry.

The production normalizer may group proven-identical variants. It must not use a
catch-all generic child mapper for variants with expression children.

## Required Implementation Sequence

### Checkpoint A: unify ordinary-function catalogs

This checkpoint retains all three existing all-owner walkers.

1. Add mixed parameter/global fixtures and capture the Issue 50 Core, generated
   C, action counters, and region counters.
2. Separate catalog region identity from entry origin.
3. Discover ordinary-function globals from the contract body and assert exact
   membership equivalence with the current discovery point.
4. Concatenate parameter entries followed by exact global entries.
5. Run the existing call, aggregate, and result passes once over that combined
   catalog.
6. Remove the second ordinary-function catalog invocation; do not change lambda
   or global-initializer behavior yet.
7. Prove exact output and measure the mixed function fixture.
8. Commit this checkpoint and preserve its production and counter workers.

Checkpoint A is independently valuable: an ordinary function with both owner
sources changes from six structural normalization passes to three.

Checkpoint A was implemented on 2026-09-04. The fixed high-owner point reduced
structural normalization visits by 59.4%, direct Perceus time by 11.7%,
allocations by 6.3%, and releases by 6.5%, with byte-identical post-Perceus Core
and generated C. See
[`compiler_perceus_tranche4d_checkpoint_a_2026-09-04.md`](../../../benchmarks/results/compiler_perceus_tranche4d_checkpoint_a_2026-09-04.md)
for the fixture, paired measurements, hashes, and threshold rationale.

### Checkpoint B: lock the fusion contract

This checkpoint adds no production cutover.

1. Add the exhaustive, test-enforced child-mode inventory.
2. Add the fixed fusion fixture and its exact structural/action census.
3. Add a failing assertion requiring one fused structural visit per visited
   expression under the union of enabled child domains.
4. Preserve separate counters for legacy call, storage, and result visits;
   fused visits; candidate visits; fallbacks; actions; and reconstructed nodes.
5. Add overlap and path-local result-satisfaction regressions.
6. Build and preserve the Checkpoint A timing and counter workers.

Do not begin production fusion until the fixture is demonstrably ownership-ready
and all expected action counts are nonzero and exact.

### Checkpoint C: fuse and cut over

1. Implement the fused normalizer alongside the committed three-pass path.
2. In focused/debug comparisons, run each authority from the same input and
   compare complete resulting Core plus action counts. Do not feed one result
   into the other.
3. Cut over global initializers first; they have one simple owner-source kind.
4. Cut over lambdas second; Issue 50 already gives them one mixed ordered
   catalog and a dedicated region fixture.
5. Cut over ordinary functions last, using the combined Checkpoint A catalog.
6. After each region cutover, prove exact Core and generated-C output before
   proceeding.
7. Delete `protect_borrowed_calls`,
   `retain_borrowed_aggregate_transfers`,
   `retain_borrowed_results_for_owners`, their catalog wrappers, and helpers used
   only by those all-owner structural traversals.
8. Retain only scalar helpers still reached by named Tranche 5–6 local-binding
   paths or explicit non-structural compatibility queries.
9. Confirm that no public or phase-crossing visitor API was introduced.
10. Reprofile and run the broad output-preserving gates once.

Do not start Tranche 5 fact collection or alter emitted ownership operations in
this issue.

## Benchmark Contract

### Checkpoint A mixed-catalog matrix

Add `mixed_function_owner_catalog` and
`--mixed-function-owner-catalog-matrix` to
`benchmarks/compiler_perceus_memory`.

Use two uncalled ordinary functions with an exact, validated fixed body. Hold
body geometry and total catalog membership constant while comparing the Issue
50 split catalogs with the combined catalog:

```text
functions=2
body_nodes=1536 per function, exact
managed borrowed parameters=32 per function
exact referenced managed globals=8 per function
consuming call sites=32 per function
transferring storage sites=32 per function
result terminals=32 per function
nested lambda regions=0
worker invocation=false
measurement window=perceus-direct
```

The fixture must exercise both parameter and global owners in every boundary
family. All eight globals must enter each function catalog through exact DCE
discovery; do not pad the catalog with unrelated globals.

Record split and combined catalog construction, region counts, call/storage/
result visits, candidate and fallback work, action counts, allocations, releases,
direct Perceus time, post-Perceus Core hash, and generated-C hash.

### Checkpoint C fusion matrix

Add `borrowed_boundary_fusion` and
`--borrowed-boundary-fusion-matrix`.

The primary timing fixture contains only ordinary function regions so nested
lambda work cannot pollute the measured visit count:

```text
functions=2
body_nodes=1536 per function, exact
managed borrowed parameters=32 per function, fixed
exact referenced managed globals=8 per function, fixed
structural call slots=96 per function, fixed
structural storage slots=96 per function, fixed
structural result slots=96 per function, fixed
active sites per boundary family=8,32,96
nested lambda regions=0
worker invocation=false
measurement window=perceus-direct
```

Use 96 fixed-size structural slots for each family. At density `D`, exactly `D`
slots in each family are active and the remainder are replaced by same-size,
same-traversal-domain non-boundary expressions. Do not add or remove carriers
between density points.

Use existing prepared-Core contracts and metadata rather than recognizing
benchmark names:

- active call slots use a consuming argument contract; inactive slots use the
  same expression geometry without a consuming boundary;
- active storage slots use prepared ownership-transfer metadata; inactive slots
  use the same Core variant and geometry with metadata specifying an already
  owned/non-transferring slot; and
- active result slots return a borrowed owner alias; inactive slots return an
  independently owned value of the same managed type.

Rotate active sites through parameter and global owners at every density. Add
fixed non-result reads if necessary so all eight globals remain exact catalog
members at every point. Assert exact catalog membership rather than inferring it
from the requested fixture parameters.

The serialized body uses fixed sequence, conditional, match, and resource
carriers. The fixture builder must fail if it cannot meet the exact 1536-node
target without an opaque padding wrapper. Padding must remain traversable under
the union child-mode inventory.

Add separate non-timing region fixtures for:

- a global initializer with exact referenced global owners;
- an outer lambda with parameter, name-mode capture, and exact-global entries;
- a nested lambda normalized as its own region; and
- empty owner catalogs that run zero borrowed-boundary traversals.

### Required measurements

Record, per region kind and in total:

```text
legacy call visits
legacy storage visits
legacy result visits
fused normalization visits
catalog slots by owner origin
candidate visits by boundary family
fallback requests and fallback expression visits by boundary family
rewrite actions by boundary family
reconstructed nodes
allocations and releases
direct Perceus elapsed time
post-Perceus artifact hash
generated-C hash
```

For each density point, assert the exact expected call, storage, and result
action counts. Do not merely assert that the counts are nonzero. Region-specific
counters must prove that nested-lambda or global-initializer work is not being
charged to ordinary-function measurements.

Run seven warmed paired samples, alternating parent/candidate order. Build
timing workers without debug counters and separate counter workers with the
instrumentation enabled.

## TDD And Fast Feedback

### Tests written before Checkpoint A

- a function with both borrowed parameters and referenced globals;
- the same owner spelling with distinct parameter/global definition identities;
- parameter-before-global tie-breaking when an expression can alias more than
  one catalog entry;
- consumed and unmanaged parameters excluded from the catalog;
- a parameter shadowing a global without hiding a distinct exact global;
- global discovery membership before and after parameter normalization;
- an empty combined catalog; and
- byte-identical Core and C against the split-catalog parent.

### Tests written before Checkpoint C

- a consuming call whose argument contains a transferring aggregate;
- a transferring aggregate containing a consuming call;
- a returned aggregate containing parameter and global projections;
- a returned aliasing call with consuming arguments;
- conditionals selecting different owners in call, storage, and result modes;
- an existing `DupExpr` satisfying one result path but not a sibling path;
- an existing `DropExpr` around overlapping boundaries;
- match/resource binder shadowing of only one owner;
- prepared tuple retain masks, boxed `needs_release`/
  `transfers_ownership`, and list-set `transfers_ownership` in returned and
  consumed positions;
- a call-traversable but storage-opaque child such as the current cast boundary;
- nested lambda opacity and exact separate region counts;
- unresolved/name-mode compatibility queries without structural per-owner
  rewalks; and
- every inventory entry whose three child modes differ.

Use this loop while editing production code:

```bash
bin/blorp check --no-format blorp/src/compiler/stage_09_core/perceus.brp
bin/blorp test blorp/test/compiler/stage_09_core/test_core_perceus.brp
python3 -m unittest blorp.test.compiler.benchmark.test_perceus_memory
```

Use counter assertions and immediate-parent artifact comparison as the primary
feedback loop. Do not repeatedly compile the compiler or run the full suite.
Build timing/counter workers only after focused correctness passes. Perform one
compiler self-compilation and the broad gates after the direct benchmark meets
its landing criteria.

## Acceptance Criteria

### Checkpoint A

- Every ordinary function has one ordered catalog containing parameter entries
  followed by exact referenced-global entries.
- A nonempty combined function catalog runs exactly three all-owner structural
  passes; an empty catalog runs zero.
- Exact global membership matches the Issue 50 discovery result.
- Catalog entry order, candidate tie-breaking, action counts, resulting Core,
  generated C, and runtime behavior are identical to the split-catalog parent.
- On the fixed mixed-source fixture, structural normalization visits fall by at
  least 40%, the paired direct-Perceus median improves by at least 8%, and
  direct-window allocations fall by at least 5%. The original prospective 10%
  allocation target was revised after the completed implementation reproducibly
  removed about 6.3% while also clearing the stronger structural-work and time
  gates; no broader optimization was added merely to meet the estimate.
- A low-work mixed-source control does not regress direct time by more than 5%
  or allocations/releases by more than 2%.
- The checkpoint is committed independently and its production and counter
  workers are preserved for Checkpoint C.

If exact output or the fixed-fixture performance gate fails, stop and revise the
region model before beginning fusion.

### Checkpoint B

- Every `CoreExpr` variant and nested expression-bearing Core record appears in
  the test-enforced child-mode inventory.
- The inventory test fails when a variant is added without an entry.
- The fixed fusion fixture has exactly 1536 nodes per function at all density
  points, exact catalog membership, exact active boundary counts, and no opaque
  padding wrapper.
- All three legacy passes materially traverse the fixture and all expected
  action counts are exact.
- Scalar fallbacks are zero on the ownership-ready timing fixture.
- The failing fused-visit assertion and separate counter schema exist before
  the production fused walker.

### Checkpoint C

- An empty ownership region runs zero borrowed-boundary reconstruction
  traversals. Every nonempty function, lambda, or global-initializer region runs
  exactly one fused reconstruction traversal.
- Nested lambdas are separate regions and are opaque to the outer normalizer.
- Fused structural visits are independent of catalog size for a fixed body;
  candidate and explicitly allowed fallback work remain separately visible.
- At every fusion-matrix density, fused visits are at least 50% lower than the
  Checkpoint A sum of call, storage, and result visits.
- At the 32-site density point, the paired direct-Perceus median is at least 10%
  faster and direct-window allocations are at least 15% lower than Checkpoint A.
- At the 8-site point, direct time does not regress by more than 5%, and
  allocations or releases do not increase by more than 2%.
- Call, storage, and result action counts and action multisets exactly match
  Checkpoint A. Compiler-internal helper-call chronology is not compared.
- Result satisfaction is path-local and does not suppress call or storage
  handling for the same owner.
- No fused compatibility path recursively rewrites a subtree once per owner.
  Ownership-ready fixtures have zero scalar fallbacks.
- Resulting ownership wrapper order, post-Perceus Core, generated C, and runtime
  output are byte-identical to Checkpoint A at every matrix point. There is no
  canonicalization exception.
- `protect_borrowed_calls`, `retain_borrowed_aggregate_transfers`,
  `retain_borrowed_results_for_owners`, their catalog wrappers, and helpers used
  only by those all-owner structural traversals are deleted or consolidated.
- Scalar local-binding helpers retained for Tranches 5–6 have named remaining
  callers; no second all-owner production traversal remains.
- Record the reachable borrowed-boundary production helper count and line count
  before and after fusion. The candidate must remove duplicated binder/match/
  resource helper families, and total source in that inventory must not grow by
  more than 10% without a separately reviewed justification.
- No public or phase-crossing generic Core visitor API is introduced.
- Compiler self-compilation records direct Perceus time, allocations, releases,
  peak RSS, region/action counts, post-Perceus hash, and generated-C hash against
  Checkpoint A.
- Focused Perceus, benchmark-contract, changed compiler, Core sanitizer,
  compiler, runtime, leak, and codegen-audit gates pass.

Failure to expose the fixed-fixture performance gains is a stop/go failure. Do
not retain a more complicated fused visitor solely because it appears
architecturally attractive.

## Final Validation

After the focused loop and benchmark gates pass, run once:

```bash
make
scripts/compiler-check --changed
scripts/test compiler-blorp
scripts/test compiler-core-sanitize
scripts/test runtime
scripts/test leak
blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh bin/blorp
git diff --check
```

Inspect the generated C for every overlapping-boundary regression. Confirm that
no compiler or test invocation left generated `.c` artifacts in the repository.

## Expected Result

Checkpoint A first removes the transitional double-catalog reconstruction from
ordinary functions. Checkpoint C then performs one explicit, exhaustive
borrowed-boundary walk for each nonempty ownership region while keeping call,
storage, and result semantics independently typed.

The fixed fusion fixture should show an observable reduction in direct Perceus
time and allocation even though owner scaling was already removed by Issues
48–50. Production code should lose the duplicate all-owner match, binder,
resource, and collection traversal families without absorbing the distinct
local-binding work reserved for later tranches.
