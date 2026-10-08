# Allocation explanation and `no_alloc` roadmap

Status: implementation in progress. The final-Core analysis and allocation
explanation flag described through milestone 3 are implemented. Backend-plan
and behavior-configuration coverage is still incomplete, so reports explicitly
make no executable allocation-free guarantee. The proposed `no_alloc` syntax
and enforcement in milestones 4 and later are not implemented. This remains a
design/acceptance document rather than the current language reference for those
later milestones. Recheck symbol locations and pipeline order before further
implementation; do not transplant historical line numbers into code.

## Outcome and boundaries

Let a human or agent ask why a piece of Blorp code might allocate, and put a
compile-time guard around code that must not allocate:

```blorp
-- Proposed syntax. This block is also valid inside an impure function.
pure func add_coordinates(x: Int, y: Int) -> Int:
	no_alloc:
		x + y
```

The first useful deliverable is a **conservative allocation explanation pass
over final prepared Core**, callable directly by tests and a report command.
The public block follows only when its obligation survives every preceding
pass and `check`, `compile`, `run`, and `test` cannot bypass verification.
This is not a dynamic allocation counter disguised as a static proof.

Non-goals: managed-field structs, parser-step elimination, table-backed ASTs,
general effect polymorphism, user-asserted foreign safety annotations, an ARC
traffic profiler, or making every standard-library operation allocation-free.
Unknown cases fail closed; improving precision is subsequent work, not an
excuse to weaken the guarantee. No runtime trap is the source-language
implementation of `no_alloc`.

## What exists, and what it does not prove

| Current owner | Relevant fact and consequence |
| --- | --- |
| `standard_library/src/memory.brp` | `MemStats` is a managed record; snapshots allocate. Exact allocation intervals use scalar `read_memory_counter(MemoryCounter)` endpoints. Counters observe executions, not all paths or allocation causes. `total_releases` counts deallocations, not every ARC decrement. Snapshot bytes are not peak bytes. |
| `blorp/src/lib/runtime/native/runtime.c` | `blorp_init_object_header`, managed release accounting, raw buffer allocation, pool allocation, tracing, and scheduler allocation are different paths. The former `BLORP_TRACE_ALLOCS` return-address table was removed; it never gave a complete source-level allocation proof. |
| `stage_09_core/ir.brp` | Explicit boxes, list allocation/construction, record/union construction and reuse, closure creation, drops, resources, and concurrency already expose many relevant operations. `CoreCallKind` is richer than user/builtin/foreign; every variant needs an explicit policy. |
| `stage_09_core/type_policy.brp`, `ownership.brp` | Ownership and representation facts are reusable inputs, **not** allocation summaries. A scalar-returning call can allocate temporaries. `FreshOwned` describes a result, not all work in a call. |
| `stage_09_core/pipeline.brp` | Late order includes projection, DCE, consumption, static strings, ownership, Perceus, reuse, closure, resource management, fairness, preparation, and prepared reuse. Checking before these transformations is insufficient. |
| `stage_10_backend/emit.brp` | C emission still chooses allocation-relevant helper behavior. In particular, `emit_iterative_union_destructor` generates a work stack grown by `realloc`. A final release can allocate even when the source has no constructor. |
| `stage_09_core/cancellation_plan.brp` | Generated cleanup behavior must be included; source-expression classification alone cannot cover it. |
| `blorp/src/check/command.brp` | `execute_check_plan` currently uses frontend validation only. It does not run final Core. Silently adding a syntax node without changing this command would give misleading successful checks. |
| `stage_09_core/pass_runner.brp` | Pass results and diagnostics have a shared protocol. Add a structured allocation diagnostic; do not squeeze a source contract violation into an emission error string. |

Paths beginning `stage_` in this document are relative to
`blorp/src/compiler/`. Follow `docs/ARCHITECTURE.md` for application boundaries.

## Contract decisions implementers must preserve

### Meaning of allocation

`no_alloc` means **no dynamic heap allocation attributable to normal execution
of the region**, including transitive calls and implicit generated operations.

- Include managed-object creation even if an allocator pool supplies storage
  without a system `malloc`; the pool is not an exemption.
- Include raw backing buffers, capacity growth, `realloc` requests even if
  they return the same address, dynamic boxing, closure environments,
  task/fiber creation, and allocating destruction/resource cleanup.
- Include required runtime bookkeeping and cold/lazy initialization reached
  by an otherwise apparently harmless operation. Warm caches are not proof.
- Stack values and immutable statically emitted storage are allowed. This is
  not a bounded-stack, no-ARC, no-blocking, constant-time, or no-I/O contract.
- ARC operations are allowed **only when their actual retain/drop policy and
  reachable cleanup are proven allocation-free**. Never classify every
  `DropExpr` as free. Recursively compute destructor effects.
- Compiler activity, program startup before entry, unrelated concurrent
  tasks, optional profiler/leak/sanitizer bookkeeping, OS activity outside
  the language execution model, and terminal infrastructure failure handling
  are outside the source-region guarantee. No ordinary language/runtime
  allocation may be relabeled as instrumentation to bypass it. V1 rejects
  task/scheduler/callback boundaries it cannot summarize.
- Foreign calls are unknown by default. A compiler-owned runtime contract is
  trusted only after implementation audit and tests. No V1 user escape hatch
  that merely asserts a foreign function is allocation-free.

Optional instrumentation may allocate while observing an otherwise certified
program; the source contract is not a promise that an instrumented process
never calls the system allocator. Acceptance testing must distinguish
instrumentation allocations from the underlying operation without suppressing
the latter. Explicit calls from the region to profiling, memory-reporting,
or scheduler APIs are ordinary subject operations, not excluded automatic
instrumentation. Prewarm the observer only, not cold subject runtime paths.
See milestone 6.

### Region and control-flow semantics

The proposed `no_alloc:` block is an expression with the body's result type,
normal lexical scope, and unchanged purity. It adds an allocation obligation,
not a new owner or a purity escape. Nested regions are supported.

```blorp
-- Proposed syntax; the record allocation outside the region is permitted.
record Box {value: Int}

pure func read_box(box: Box) -> Int:
	no_alloc:
		box.value

pure func concatenate(left: String, right: String) -> String:
	no_alloc:
		left + right  -- reject: dynamic result storage may be needed
```

Arguments evaluated inside the region, callees, implicit conversions,
reassignment destruction, loop operations, and exit cleanup all count.
Ownership of a returned existing value may transfer out; future destruction
by its recipient is outside this invocation, but cleanup performed while
leaving the region is inside. Creating a closure and executing its body are
distinct: analyze capture/environment construction now; include the body
when called. An annotated block inside a closure remains an obligation on
the closure body even if the closure is created elsewhere.

Unknown branch conditions join both branches. V1 does not prove loop bounds,
uniqueness, spare capacity, or impossibility of cold runtime paths from
profiling. Existing canonical constant folding/DCE may remove unreachable
operations before analysis. The checker does not run speculative user code
or its own second optimizer. Results are defined by Blorp's canonical Core
pipeline, independent of host C `-O0`/`-O2` allocation elimination.

Preserve region entry/exit during transformations. Never obtain a proof by
hoisting an allocation or its required cleanup across the region boundary.
Borrowing or eliminating the allocation altogether may establish a proof;
moving it outside to silence the diagnostic may not. V1 treats the region
as an optimization-motion fence, not as an inlining ban within the region.
Imported callees are checked transitively without requiring annotations on
each function.

### Conservative answers and diagnostics

Distinguish these results in APIs and reports:

1. Proven allocation-free under the stated runtime/representation contracts.
2. May allocate, with an operation/callee/cleanup witness.
3. Cannot prove, with an explicit unknown boundary witness.

A function may have both known allocation and unknown-call witnesses. Retain
both facts; do not overwrite one with the other. Only the empty set of risks
is a proof. No source-name heuristics, missing-entry defaults, purity-based
guesses, or inference from return type.

Concrete counterexample: `string.levenshtein` is pure and returns `Int`, but
its runtime implementation allocates two dynamic-programming rows with
`malloc`. The current builtin runtime-effect system also has a
`NoRuntimeEffect` default; do **not** reuse that default as an allocation
proof. Allocation knowledge must be an explicit, closed contract.

```text
error[allocation-contract]: cannot prove this no_alloc block allocation-free
  read_value(tokens, index)
  -> construct Identifier payload
  -> heap-boxed union representation may allocate
help: use an allocation-free tag/payload accessor, or move this work outside
      the constrained region in your source
```

Only offer a specific alternative when one actually exists. An unknown
callback diagnostic says the target is unknown, not that it definitely
allocates. Release diagnostics identify the value's cleanup policy and the
allocating destructor helper. Anchor the error at the operation and attach
the enclosing block and a bounded, deterministic call-chain explanation.

## Architecture: one fact model, multiple consumers

The checker is a final-Core analysis, not C-text pattern matching. But final
Core alone is not currently the whole allocation authority. Extract or share
the allocation-relevant emission/runtime decisions first; do not maintain an
optimistic checker beside a more powerful emitter.

Extend the normalized, compilation-owned facts in
[`allocation_contracts.brp`](../blorp/src/compiler/stage_09_core/allocation_contracts.brp)
and [`allocation_analysis.brp`](../blorp/src/compiler/stage_09_core/allocation_analysis.brp).
[`allocation_report.brp`](../blorp/src/compiler/stage_09_core/allocation_report.brp)
owns current report rendering; region obligations and rejection diagnostics below
remain proposals.

| Table | Key and payload | Owner/lifetime |
| --- | --- | --- |
| Runtime operation contracts | Validated builtin/runtime operation identity + concrete layout/mode; local allocation effect and callback/destructor dependencies | Immutable compiler data, no user-spelling lookup |
| Declaration/cleanup index | Dense local function/type slot mapped from `CoreFunction.def_id` and accepted type identity | Construct once per analysis |
| Allocation sites | Dense site ID; owner function, exact Core operation kind, compact origin, allocation reason | Once per final Core traversal |
| Dependency edges | Caller site to direct callee, destructor, runtime callback, or explicit unknown target | Adjacency arrays; not expanded call-chain strings |
| Function summaries | Local risks plus transitive risk categories and bounded witness references | One row per concrete function/SCC member |
| Region obligations | Stable source region ID, clone/instantiation identity, original span, generated owner, result | Created upstream, discharged at verification |
| Region membership | Site ID to region-instance IDs, including generated exit-cleanup fragments | Sparse rows only for constrained operations |

Use existing exact declaration IDs; names are display-only. `CoreCallKind`
still contains runtime symbol strings in some variants: validate those against
one closed registry at the boundary and issue IDs there, rather than starting
a whole compiler symbol-normalization project. An unregistered operation is
explicitly unknown. Layout-dependent operations must not be keyed only by
runtime name.

Illustrative shape (design pseudocode, not a drop-in Blorp declaration):

```text
AllocationRisk = MayAllocate(site_id) | UnknownAllocation(site_id)
Summary = { local_risks, transitive_risk_categories, witness_edges }
Site = { owner_id, operation_kind, origin_id, reason_id }
Proof = { prepared_program_revision, contract_catalog_revision,
          backend_allocation_plan_id, behavior_configuration_id, region_results }
```

Do not add per-node rendered diagnostic strings or retain whole earlier ASTs
for explanations. Use source tables/locations and IDs. Final-Core node IDs
may be assigned in deterministic traversal order; upstream region IDs are a
different identity domain and must survive cloning and lowering explicitly.
No lookup by approximate line-range containment.

Frontend `SourceLocation` is just packed offsets and singleton source tables
currently issue file ID zero. Neither is a compilation-wide identity. Define
region origin as `(compilation_source_id, start_offset, end_offset, ordinal)`
using the graph's validated source/module identity to issue a dense source
catalog key. Specialization adds a distinct concrete owner/clone ID. Test
two modules with identical offsets and identically named functions.

Each region instance is a synthetic **analysis root**, with its own local
site memberships and outgoing call/cleanup edges. Function summaries describe
whole callees; they must not charge allocations elsewhere in the containing
function to its small region. A structural wrapper is a fence and origin
carrier, not the complete membership mechanism. When ownership/resource/
control-flow lowering emits exit cleanup outside that wrapper, emit an
explicit region-fragment wrapper carrying the enclosing region-instance IDs
around that cleanup. Splits/clones preserve those IDs or map to explicit
clone instances. The final walk publishes sparse site/region membership rows
from both ordinary and fragment wrappers. No per-node membership lists are
required for unannotated code. Keep these compile-time wrappers in the
certified prepared artifact; the C renderer traverses their bodies
transparently without mutating that artifact or emitting calls/closures.
There is no post-verification wrapper-erasure rewrite.

`CoreSourceLoc` is an opaque packed `Int`: authored handles encode module and
line/column coordinates, zero is synthetic, and negative pass-minted ids resolve
through `minted_origins`. It is not an authored byte-extent or region identity.
Extend the report's source-origin handling with a compact authored region catalog,
linking synthetic operations to their originating obligation/call. Reuse the
existing module/source ownership; do not retain whole earlier graphs or duplicate
paths per fact row. Render diagnostics while the source catalog is available.

Build local facts once, condense recursion into SCCs, and propagate finite
risk categories with a worklist/reverse edges. A recursive SCC with no local
risk and no risky outgoing edge can be allocation-free; initialize the
fixed point accordingly rather than declaring every recursion unknown.
Unknown external edges remain unknown. Termination is not part of the
allocation guarantee. Target linear indexing/traversal plus bounded-state
SCC propagation, not one recursive AST scan per call site or region.

The verifier runs after prepared reuse **and after allocation-relevant backend
helper plans/configuration are frozen**, before emitting C. Lift their plan
construction to the shared preparation boundary; C rendering may not make a
new unrecorded allocation decision. Proofs bind the exact prepared program,
contract catalog, concrete backend allocation/helper plan and every
behavior-affecting configuration field. Any later change invalidates them.
A backend preflight validates plan/configuration identity and consumes the same helper
plans/catalog and rejects an unclassified allocating emission path as an
internal invariant failure; it does not discover ordinary user errors while
printing C. Single/split C output must share this preflight.

Use an opaque verified-admission product at the production emission boundary,
with explicit `NoObligations` versus `VerifiedObligations` states; construction
validates the prepared artifact and configuration it carries. The existing
public `prepared_core_program` wrapper alone is not a certificate. Test-only
unprojected emission helpers must not become a production bypass. Do not add
an optional boolean that means "someone probably checked this earlier."

### Concrete classification traps from the current emitter

| Concrete representation/operation | Required classifier behavior |
| --- | --- |
| `PrimBox`, `PointerBox`, `VoidBox`, Float/Float32/Float16 boxes | No direct allocation in current runtime; floats are bit-packed into pointer-sized storage. Analyze the operand. A helper named `box` alone is not evidence of allocation. |
| Int128/UInt128/scalar ABI struct boxes | Heap allocation risk; see `emit.brp` box rendering and the actual runtime helper |
| `CoreBoxedStorageValue`, closure/task argument adapters | Classify implicit boxing in the storage/ABI plan, not just explicit `BoxExpr` children |
| Generated tuple `ProductExpr` | Managed typed record constructor allocates; inline aggregate fields do not require erased-slot boxes |
| Dict iteration with a pair binder | Typed native product factory constructs a managed key/value record; seemingly read-only iteration can allocate |
| Source-record `ProductExpr` | Use the concrete record representation: managed construction allocates, while eligible fixed records are inline; accept only when final Core removes allocation |
| `ClosureCreateExpr` | Static zero-capture representation differs from allocated capture environment |
| `ClosureCall` | Unknown target and argument/result ABI boxing are independent risks; V1 rejects unresolved closure calls |
| `ForeignDefaultArgs` | Defensive argument copying can allocate even if the foreign body is audited; `@no_copy` is not an allocation-free promise |
| Stack `Option`/`Result`, nullary union instance | Use selected layout, not the blanket claim that all union constructors allocate |
| Recursive union release | Include iterative destructor `realloc`, nested field effects, and erased/dynamic release uncertainty |

Owners to inspect alongside `emit.brp`: `stage_10_backend/`'s
`emit_tuple_product_adapters.brp`, `emit_tuple_product_plan.brp`,
`prepared_backend_renderer.brp`, and
`intrinsic_renderer.brp`, plus `stage_09_core/operation_metadata.brp`.
The existing iterative SCC implementation in
`stage_06_typecheck/headers/global_header_completion.brp` is a precedent for
an explicit-stack implementation; do not introduce host-recursion limits on
large compiler call graphs.

## Milestones and dependency order

```text
0 Contract/coverage fixtures
  -> 1 Shared operation and cleanup facts
  -> 2 Final-Core summary analysis
  -> 3 Allocation explanation interface (first useful tool)
  -> 4 Region syntax/provenance across stages
  -> 5 Command/LSP enforcement (public feature release)
  -> 6 Runtime oracle, end-to-end gates, performance acceptance
  -> 7 Optional precision improvements, individually measured
```

Milestones 4 and 5 are one public release boundary: parser support alone must
not ship as working `no_alloc`. Milestone 6's focused runtime oracle should
be developed alongside 1/2, then used for the release gate. No implementation
milestone is complete merely because the next stage can compensate for it.

Implementation status:

| Milestone | Status | Current boundary |
| --- | --- | --- |
| 0. Contract/coverage inventory | Complete | Core expression/call coverage is manifest-owned and new variants fail closed. |
| 1. Shared operation and cleanup facts | Partial | The closed Core/cleanup catalog and runtime pilot exist; backend helper plans and behavior configuration do not yet publish complete structural identities. |
| 2. Final-Core summary analysis | Complete for report scope | Deterministic dense identities, iterative SCC propagation, cleanup memoization, separate may/unknown facts, source sites, and bounded work counters are implemented. |
| 3. Allocation explanation interface | Complete | Human and versioned JSON reports run after final prepared Core without C emission; executable coverage remains explicitly incomplete. |
| 4-7. Source contracts, enforcement, runtime oracle, precision | Not implemented | No `no_alloc` syntax or allocation-contract rejection is available yet. |

Completed report milestones 0, 2 and 3 are represented by the status table above,
the canonical [contracts](../blorp/src/compiler/stage_09_core/allocation_contracts.brp),
[analysis](../blorp/src/compiler/stage_09_core/allocation_analysis.brp), and
[report](../blorp/src/compiler/stage_09_core/allocation_report.brp) owners and their
[`test_core_allocation_*` suites](../blorp/test/test_compiler/test_stage_09_core/test_core_allocation_contracts.brp).
Their invariants remain requirements: explicit coverage for every Core variant,
separate `may_allocate` and `unknown` facts, deterministic artifact-local ids,
iterative SCC propagation (safe recursion can converge), bounded witnesses and
node/edge work, and no analysis tables when reporting is disabled. Allocation
facts remain a separate effect channel from purity and ownership; analysis must
not mutate ownership policies or treat a pure/owned result as an allocation proof.

### 1. Publish allocation facts shared with runtime/emission plans

**Context.** Prepared Core exposes much of the work, but release helpers and
runtime dispatch can still introduce hidden allocation. This is the main
soundness prerequisite, not a cosmetic registry.

**Implementation strategy.** Extend the narrow accepted runtime/representation
boundary with allocation facts and dependencies. Audit
`runtime_projection.brp`, `backend_projection.brp`, `builtin_registry.brp`,
`type_policy.brp`, `prepare.brp`, and the matching emitter consumers. Extract
the predicate/plan for iterative union destruction from emitter-only logic
into a shared preparation owner; emitter and checker consume the same plan.
Include nested field destruction and runtime callbacks as edges. Unknown
dynamic destructor dispatch is not free. COW and reuse forms remain
`MayAllocate` unless a compiler proof removes every allocating fallback.
Do not infer no allocation solely from `RecordReuseExpr`/`UnionReuseConstructExpr`.

**Example.** A self-recursive union's drop depends on a destructor plan with
`RawScratchGrowth`; a primitive scalar drop has no such dependency.
`ListGetExpr` may require boxing for some layouts and no boxing for others.

**Fast loop.** Extend `test_core_allocation_contracts.brp` with the missing
Core/layout/helper cases; use `test_core_prepare.brp` and codegen helper fixtures.
Compare generated C before/after factoring: this milestone changes fact
publication, not runtime behavior.

**Acceptance.** Safe pilot operations have proven contracts; all other
operations explicitly report risk/unknown. Runtime contract tests include
cold paths, shared storage, capacity exhaustion, destructor recursion, and
callback invocation. No new unverified purity/name whitelist. Fact extraction
is shared with emission; ordinary builds retain identical generated C.

### Current allocation report interface

`compile --explain-allocations[=human|json]` reports after final prepared Core,
without C emission/linking. The default is human output; JSON is one versioned
object. `-o`, `--ast`/AST output options and any `--stop-after` are rejected.
Diagnostics go to stderr. A valid program exits successfully even when the report
contains risks: inspect the report's status and witnesses, not its exit status.
The report does not enforce the proposed source contract.

```json
{"schema_version":1,"report_kind":"core_allocation_analysis",
 "executable_guarantee_status":"unavailable",
 "owners":[{"definition_id":42,"core_status":"may_allocate",
 "may_reasons":["heap_box"],"may_witness_path":[8,17]}]}
```

Ids are artifact-local; source/display and catalog provenance accompany the facts.
`Safe`, `MayAllocate` and `Unknown` are conservative Core classifications, not an
executable certificate. Explicit unsupported/unknown witnesses and incomplete
backend-plan/configuration coverage prohibit an executable allocation-free claim.
Reports preserve both may and unknown risks, distinguish conditional from definite
allocation and keep compiler-generated provenance explicit. When source contracts
land, a violated obligation must fail even in report mode.

### 4. Carry allocation regions through the language and all transforms

**Context.** Source range heuristics lose obligations when functions are
inlined, specialized, eliminated, or turned into closures. An explicit
region identity must survive independently of the original AST object.

**Implementation strategy.** Add contextual `no_alloc` block syntax using
the existing indented expression-block conventions. Add precise parsed,
typed, and Core variants and origin/clone metadata. Prefer a dedicated
`AllocationScopeExpr`-style Core boundary plus compact region table, not
rewriting the source block into an ordinary lambda/call (which could itself
allocate). V1 fence semantics forbid motion of allocating operations and
exit cleanup across that boundary. Preserve control flow and result type.

Inventory and update parser/finalizer/traversals, typed traversal and
serialization, CTFE, Core lowering/serialization/traversal, optimizers,
monomorphization, ownership/reuse, closure/resource lowering and preparation.
Update central traversal first, then enumerate specialized hand-written walks
with tests; do not patch only the exhaustiveness errors. Clone identities
combine source-region origin and generated concrete owner, never strings.
CTFE preserves an obligation record even if evaluating the enclosing
expression removes its runtime body; an erased region is explicitly marked
with its elimination reason, not lost from the inventory.

Mechanical source route: both discovery parser/lexer owners under
`blorp/src/compiler_new/stage_01_discovery/` and the legacy
`stage_02_lex/token.brp` keyword/tag tables;
`stage_03_parse/language_parser.brp` (`parse_block_after_colon`),
`parsed_ast.brp`, `parsed_ast_json.brp`, `parsed_ast_traverse.brp`;
`stage_06_typecheck/infer.brp`, `typed_ast_json.brp`,
`graph/typed_expr_children.brp`; `stage_08_core_lower/lower.brp`; Core
`ir.brp`/`traverse.brp`; and `blorp/src/format/engine/expression_documents.brp`.
Use the existing debug-block plumbing as a traversal checklist, **not** its
semantics: debug inference forces `Void`, whereas this block preserves the
body's type. Add token variants without silently renumbering existing
serialized tags. Review purify/lint-specific exhaustive walks separately.
New wire variants require explicit reader/writer and cache-version handling;
old artifacts cannot silently drop the contract. This does not require a
new bootstrap pin merely to represent new compiler AST variants: keep the
compiler's own source within the pinned bootstrap's supported language until
a separately authorized bootstrap upgrade.

**Example.** A generic helper instantiated once for a scalar and once for a
boxed payload must not reuse the scalar proof for the allocating instance.
A `break`, `continue`, or propagation exit from a region keeps required
cleanup in its obligation. A nested lambda's body is not spuriously charged
at closure creation, but its own marked regions remain checked.

**Fast loop.** Parser/formatter round-trip, typed/Core JSON round-trip and
one before/after fixture per transforming pass. Extend existing
`test_core_traverse.brp`, `test_core_pipeline.brp`, closure/resource/ownership
owner suites, and add a region-preservation inventory test. No public release
yet; put this work on the feature branch until milestone 5 passes.

**Acceptance.** Every source region becomes a verified, rejected, explicitly
eliminated, or explicitly unresolved obligation—never silently disappears.
No allocation moves across its fence to obtain acceptance. Nested/loop/
closure/monomorphic/generic cases preserve location and identity. Formatter,
lint, purify, and debug handling preserve the construct. Grammar and Guide
updates land with the public feature, not as claims about today's language.
Tests must exclude allocating work before/after a region while including
generated cleanup on every exit from it. Check split/fragment membership,
not just that a lexical wrapper survives a dump.

### 5. Enforce contracts consistently in CLI, editor, and artifact paths

**Context.** `check` is currently frontend-only, while compile/run/test prepare
Core. An annotation ignored by `check` would undermine fast feedback.

**Implementation strategy.** Publish a cheap "contains allocation obligations"
fact during frontend graph construction. Keep unannotated `check` on its
existing fast path. For annotated inputs, invoke a shared application-layer
allocation-validation route that reuses frontend products and runs the
canonical lowering/preparation pipeline without C emission/linking. Do not
make frontend type inference import the backend or run `compile` as a shell
subprocess. Compile/run/test consume the same verifier; do not create four
independent analyses. V1 checks **every marked declaration in the entire
loaded frontend graph**, including unused imported declarations; there is no
dependency-certificate shortcut. Entry-point DCE must not erase an unchecked
obligation.
The validation-only route must support module checking without a `main`
function (the equivalent of `require_main = False`). Extend
`blorp/src/check/command.brp`, the application service around
`lib/frontend_validation.brp`/compile preparation, and
`blorp/src/lsp/analysis/compiler_service.brp`; do not change ordinary
typechecking into unconditional full compilation.

For generic declarations, validate a symbolic body only where contracts are
representation-independent and validate concrete instantiations otherwise.
V1 has no universal allocation-effect parameter: an unresolved generic
obligation receives a precise "cannot prove for this generic body" diagnostic,
not a green universal promise. Reject unsupported unconstrained cases rather
than sampling one instantiation.

Keep unused obligations in an **analysis-only preparation product**, rooted
before DCE independently of the ordinary executable roots. Prepare that batch
once, sharing immutable frontend inputs, and validate its otherwise-unused
owners without emitting them. The production prepared artifact retains its
normal dead-code behavior and receives its own final verification against
its own frozen backend plan. Do not retain analysis roots or their generated
closures/destructors/static data in successful executable output. Do not
prune a verified prepared artifact ad hoc: if a body-affecting transformation
is unavoidable, rerun canonical preparation and reverify the resulting
artifact. A certificate from the analysis-only product is not an emission
certificate for a differently optimized production product.

Typechecking may reject malformed/ill-typed blocks and record unsupported
generic obligations early. It must not reject a mere allocation candidate
that the canonical Core pipeline is permitted to eliminate, or `check` and
compile would implement different acceptance rules.

LSP uses the same application service asynchronously with snapshot/version
identity and cancellation. Current diagnostics are complete replacement
publications: parse/type errors may publish immediately, but successful
typechecking with obligations must **not publish an empty diagnostic list**
while allocation validation is pending. Retain the prior publication (with
its prior snapshot identity; do not relabel it as current), and publish one
combined result for the new snapshot once all required checks finish. A
separate pending-status protocol is optional future work, not assumed here.
Discard stale results; do not block ordinary edits on repeated whole-program
analysis. Cache only against complete semantic input/catalog/config identities,
or use no persistent cache in V1. Allocation errors are source diagnostics
with stable codes, not "internal C emission failure".

**Example.** A module with an unused annotated allocating function fails both
`check` and `compile`. A region in an unused imported body is also validated
against the same runtime contracts, without keeping that body in emitted C.
A metadata-only Core dump or
`--stop-after` before verification states that allocation verification was
not performed; such an artifact cannot be treated as a certified executable.

**Fast loop.** Same pass/fail fixture through `check`, `compile`, `run`, and
`test`; compare reason/location/help. Add LSP open/change/version/cancellation
cases. Use existing command, source-graph, and pipeline tests first, then
`scripts/test cli lsp` after a successful warmup and under gate serialization.

**Acceptance.** No successful executable/artifact path can skip a failed
obligation, including split output and cached test artifacts. `check` and
LSP never claim an unverified block is proven. Unannotated check does not
start Core. Failures publish no partial executable/C artifact. Reviewed docs
and examples clearly distinguish proposed effect from purity and ARC.

### 6. Validate the proof against runtime behavior and enforce cost budgets

**Context.** Static classification needs an independent execution oracle.
`MemStats` alone misses raw buffers and allocating release helpers; a zero
delta on one path is not proof of the universal property.

**Implementation strategy.** Build a test-only, allocation-free observer for
the classified operation boundaries: managed allocation attempts, raw
malloc/calloc/realloc/aligned allocation requests, and generated cleanup
scratch allocation. Include direct virtual-memory requests (`mmap` for fiber
stacks in the current runtime, plus supported platform equivalents); these
can bypass libc allocation wrappers entirely. Distinguish logical managed requests from backing
allocator events so one object is not double-counted as two semantic
allocations. Use fixed counters/preallocated storage, no formatted logging
inside the measured region, and no full leak metadata in this oracle mode.
Audit coverage of raw bypasses, including direct system mappings; add a
coverage check so a newly introduced raw allocation site must be assigned an
oracle/contract owner. Observer overflow is a failed/incomplete test, never
silently interpreted as zero events. Platform allocator interposition is an
independent supplemental check, not the only portable test mechanism.

Place the native oracle harness with runtime tests, following
`blorp/test/test_runtime/test_runtime_allocator_stats.py` for a small C harness.
Its direct Python invocation is the fast loop; explicitly wire the new
harness into `scripts/test runtime` and its ownership checks. The existing
allocator-stats Python test is wired through quality, so merely placing a
neighboring file does not make the runtime gate execute it. Keep generated
scratch C/binaries in a task-specific temporary directory.

Tests mark entry/exit in a harness outside pure source code. Scope tracking
must handle nesting and exceptional exits and, if fibers are exercised,
must follow execution context rather than assuming OS-thread identity.
V1 can conservatively reject concurrent scopes instead of building a general
cross-task recorder. No public runtime aborting `no_alloc` mode is required.

**Example matrix.**

| Case | Expected proof and observation |
| --- | --- |
| Scalar arithmetic, audited scalar borrow/read | Accept; zero covered heap requests |
| Static string, primitive scalar | Accept when final representation is static/inline |
| Payload union/record constructor | Reject unless final Core completely removes allocation |
| Empty collection canonical singleton | Accept only for exact known static representation |
| COW update with shared receiver or exhausted capacity | Reject; exercise both allocating paths |
| Retain/transfer of existing reference | Accept only for audited operation policy |
| Final release of recursive union | Reject if destructor scratch stack can grow |
| Capture construction versus callback invocation | Separate creation effects from body effects |
| Foreign/unknown indirect call | Unknown/reject, even if one observed run allocates zero |
| Mutual recursion with no risky operations | Accept; no termination guarantee |
| Resource cleanup and early exits | Include cleanup effects and preserve diagnostic origin |
| Scalar and managed generic instantiations | No proof reuse across different concrete layouts |
| Profiling, leak, sanitizer mode | Source verdict stable; observer distinguishes instrumentation |
| Fresh process versus warmed runtime | Same proof; exercise lazy initialization paths |

**Fast loop.** One tiny static fixture plus its dynamic oracle per contract
class; inspect the exact generated helper. Run focused invariant/ownership
tests, then manifest checks, `scripts/test compiler-blorp`, CLI/LSP, relevant
runtime, `compiler-core-sanitize`, `leak`, codegen audit, and `make quality`
once on the combined frozen tree. Do not run the entire suite per table row.

**Performance acceptance.** Measure ordinary unannotated self/small and an
annotated call-graph fixture with fixed inputs and the same optimization level.
Record instructions, allocations, peak bytes/RSS, output size, and time to
first allocation diagnostic. The analyzer performs no runtime instrumentation
in release programs. Ordinary unannotated builds must allocate no analysis
tables and emit identical C; investigate repeatable >1% instruction/allocation
or >2% peak-memory regressions before acceptance (thresholds trigger review,
not permission to hide smaller systematic regressions). Measure analysis
overhead separately; require structural near-linear scaling for doubled
graphs and many regions sharing callees. Use one deterministic screen and
at most three alternating pairs if noise needs resolution, not ten.

**Acceptance.** Independent code-reviewer and test-runner approve coverage,
proof invalidation, diagnostics, runtime contract audits and measurements.
No accepted test region allocates through a covered normal path. The oracle
finds deliberately misclassified raw growth and destructor allocations.
Unknown coverage is documented and conservatively rejected. Public docs
describe exclusions and how to respond to unknown-call diagnostics.

### 7. Improve precision only where rejected real code justifies it

**Context.** Conservative V1 is useful without proving every COW operation or
supporting generic callback effects. Avoid turning its initial delivery into
an unbounded optimizer project.

**Strategy and example.** Rank actual rejection reasons. A subsequent task
may propagate exact callback targets, or prove both unique ownership and
sufficient capacity for one collection operation. Require an explicit proof
object consumed by the allocating fallback owner; "it was unique in the
benchmark" is not an implementation. Another task may remove a destructor's
scratch allocation; then update the canonical helper contract and its tests.
Parser split-return optimization remains a separate task and can use
allocation explanations/regression contracts where applicable.

**Fast loop.** One previously rejected fixture, one adversarial counterexample,
and the affected runtime/Core owner tests, followed by one measured workload.

**Acceptance.** More cases accepted without weakening existing guarantees;
negative/shared/cold paths remain rejected. No global effect-polymorphism or
new record-layout feature is smuggled into a precision patch. Each follow-up has
its own reviewed scope and measured benefit; V1 completion does not depend on it.

## Coordination and validation

The remaining lanes share a schema: contracts/runtime owns milestone 1 and the
runtime portion of 6; language/tooling owns 4–5; analysis/reporting extends the
existing owners as those facts become available. Freeze helper-plan, region-id and
diagnostic schemas before dependent consumers. Schedule Core enum/traversal/codec
edits serially. Milestones 4–6 form the public release boundary; no temporarily
unsound syntax lands as a working contract.

Use [Worker Checklist](WORKER_CHECKLIST.md) and
[Developer Guide](DEVELOPMENT.md) for build status, focused gates, serialization,
test registration and review/handoff; use the
[self-compile protocol](../benchmarks/README.md#self-compile-measurement-protocol)
for frozen-input measurements. Allocation-specific evidence is the accepted and
rejected fixture pair, complete versus unknown proof coverage, the exact generated
helper/Core excerpt, artifact/catalog/configuration identity, and milestone 6's
runtime observations and cost budgets. Verify current CLI help before using a
proposed flag.

## Completion checklist

- [ ] Complete shared backend/runtime allocation and cleanup contracts; the Core catalog and exhaustive coverage tests are implemented.
- [ ] Region syntax/provenance survives all relevant transforms.
- [ ] Consistent `check`/compile/run/test enforcement and honest LSP status.
- [ ] Runtime oracle catches raw growth, boxing and allocating destruction.
- [ ] Independent review, combined gates, documented exclusions and cost budget.

The report tool is available. Ship the public `no_alloc` contract only when
shared backend coverage and milestones 4–6 are complete.
