# Issue 61: Carry Module IDs In Resolved Call Metadata

**Status:** Implemented; deterministic allocation reduction, no demonstrated latency win

**Roadmap:** [Normalized Compilation Database Roadmap](NORMALIZED_COMPILATION_DATABASE_ROADMAP.md)

**Dependencies:** Issues 56-58 are implemented. They establish one compilation
`ModuleTable`, make `ModuleId` authoritative for graph-owned modules through
Stage 06, and retain that ID domain through CTFE and Core graph preparation.

## Objective

Remove the remaining per-expression canonical-path-to-`ModuleId` probes at the
Stage 06 typed-expression boundary. Resolve imported callable and selected
implementation-method ownership once while Stage 06 still owns the prepared
module scope, then carry the exact ID through Stage 07 CTFE IR translation and
Stage 08 Core lowering.

This is the bounded typed-call follow-up explicitly left by Issue 58. It is not
a general typed-expression arena migration and does not remove source spellings
that diagnostics, JSON, intrinsic recognition, or generated external names
still require.

## Current Work

The accepted graph already retains one shared `ModuleTable`, and both CTFE and
Core use dense module-indexed products. Three accepted-expression paths still
discard the resolved owner and recover it from a canonical path:

1. an imported direct call entering `stage_07_ctfe/ir.brp`;
2. a selected imported trait implementation method entering the same CTFE IR;
3. either form entering `stage_08_core_lower/lower.brp` to select the prepared
   per-module callable-name row.

Each probe repeats a Stage 04 join that Stage 06 can perform once when it creates
the resolved call metadata. Qualified global access is not part of this issue:
its CTFE module-alias metadata already carries `ModuleId`.

The remaining path lookups in `stage_07_ctfe/context.brp` admit external import
binding spellings into the ID domain. Those are resolution-boundary operations,
not repeated typed-expression work, and remain unchanged.

## Representation

Use these phase-specific states:

```blorp
union CallableOrigin:
    CallableLocal
    CallableImported(ModuleId, String)
    CallableImportedUnresolved(String)
    ...

record ImplMethodTarget {
    callable_id: Int,
    module_id: ModuleId,
    module_path: String
}
```

`CallableImported` is the accepted graph state. It carries the foreign key and
the canonical spelling required by typed JSON, intrinsic recognition,
diagnostics, and Core external-name projection. `CallableImportedUnresolved`
is an explicit graphless/provisional state for direct inference and isolated
tool entrypoints; it prevents a sentinel ID. Prepared Core graph lowering must
reject that state rather than guess or repeat a path lookup.

`ImplMethodTarget` is constructed by both ordinary declaration registration and
accepted implementation preparation, then selected during inference. Both
producers carry the current module ID; ordinary construction validates the
supplied path against the current module scope, and accepted-table validation
checks the ID/path pair against the retained `ModuleTable`. The type has no
unresolved variant, and construction fails closed if owner facts are missing.

## Implementation Plan

1. Add failing CTFE and Core tests whose accepted imported-call and selected
   trait-method metadata includes an exact module ID.
2. Resolve `FuncSymbol.module_path` through the existing `InferModuleFacts`
   module-scope table when constructing `ResolvedCallInfo`. Preserve sequential
   inference, callable identity, overload ordering, and every source spelling.
3. Add the current module ID to selected `ImplMethodTarget` values at their two
   Stage 06 construction sites. Do not add a table or identity field per
   expression.
4. Make CTFE IR use the carried ID directly for accepted imported direct and
   selected trait-method calls. Preserve the pre-existing path lookup only for
   explicitly graphless `CallableImportedUnresolved` metadata.
5. Make prepared Core lowering index its module-aligned callable-name list
   directly with the carried ID. Preserve default graphless lowering through
   the explicit unresolved state; reject unresolved metadata in prepared graph
   lowering.
6. Keep typed-AST JSON and lint behavior stable by projecting the retained path.
7. Inspect generated C and measure matched baseline/candidate compiler builds.

## Tests

Focused behavior must prove:

- a real typechecked imported direct call carries the dependency's canonical
  table ID and retained path;
- a real selected imported trait method carries the implementation module's
  canonical table ID and retained path;
- CTFE IR selects the same imported callable by the carried ID;
- prepared Core lowering selects the same callable name by direct list index;
- graphless typed JSON and default Core lowering preserve their existing path
  projection through `CallableImportedUnresolved`;
- callable-origin and implementation-target equality include the ID and path;
- exact ID/path disagreement fails closed at accepted authority, CTFE, and Core
  boundaries;
- malformed/missing module ownership fails closed without a magic ID; and
- CTFE values, typed JSON, Core JSON, diagnostics, callable IDs, and definition
  frontiers remain exact.

Run the owning Stage 06 inference/bridge/JSON, Stage 07 CTFE IR/evaluator, Stage
08 Core lowering, lint, pipeline, leak, and generated-C checks. The changed-file
manifest gate and all reviewer-required suites must pass.

## Measurement Plan

Build baseline and candidate workers serially from the same parent and bootstrap.
Record source patch and worker hashes. Use one imported-call-heavy synthetic
program to vary imported call-site count independently of module count, with at
least 1, 64, 256, and 1024 call sites. Compile through Core so Stage 08 executes.

For each row require byte-identical generated C or an exact semantic/Core/C
checksum, zero errors, and identical callable/definition counts. Record at least
three alternating samples of elapsed time, allocations, releases, retained
objects, allocator bytes in use, and peak RSS when available. Exact structural evidence
must show that accepted CTFE/Core expression lowering no longer calls
`module_table_find_id_by_canonical_path`.

Run production compiler replay only if its command executes the changed Stage 08
boundary and the focused workload shows a measurable signal. A typecheck-only
replay covers Stage 06/07 but not Stage 08 and must not be presented as complete
evidence for this issue.

## Implementation Result

Stage 06 now resolves imported `FuncSymbol` ownership through the retained
module-scope table when constructing `ResolvedCallInfo`. Accepted direct calls
carry `CallableImported(ModuleId, String)`; graphless inference carries the
explicit `CallableImportedUnresolved(String)` state. Both implementation-method
construction paths copy the current canonical module ID into
`ImplMethodTarget` and fail closed if that owner is unavailable.

CTFE IR reads the carried ID for accepted imported direct calls and selected
imported trait methods, validating the retained path with the table's direct ID
projection. Explicit graphless metadata retains its legacy path-to-ID fallback.
Core lowering validates the same ID/path invariant, then indexes the prepared
outer callable-name list with `module_id_table_index`; it no longer allocates the
old intermediate `(module_path, callable_id)` tuple or probes the module-path
dictionary. Prepared graph lowering rejects unresolved imported metadata. Typed
JSON, lint, and generated external names continue to use the retained path.

The accepted imported-call branches contain no
`module_table_find_id_by_canonical_path` call. `stage_07_ctfe/ir.brp` retains one
such call solely for `CallableImportedUnresolved`; `stage_08_core_lower/lower.brp`
has none. The two calls in `stage_07_ctfe/context.brp` continue to admit external
import-binding spellings into the CTFE ID domain.

## Measurement Result

All raw artifacts are ignored under `logs/issue61/`. Baseline commit
`c7654f7d` and the candidate were built serially with bootstrap SHA-256
`f09bb1d5afa87c5a2dd2e5884f6d05f2c9ec23375d6ca5e5e3d18a142cac7d11`.
Baseline and candidate worker SHA-256 values were
`021076353882c3a6df269b1a9f1745cb83e13f0a070f35054801729d4e1ff685`
and `574c5322d54ea40f28cf4365d6bc6191bc57aeb323c41f7af2c5b990fa61b330`.
The measured production-source patch SHA-256 was
`419c538c2aaefb5e5792aa09339b7f1ab9901d96f084482219474340cd639b42`.

### Imported-call scaling

An ignored Blorp generator produced the same small program at 1, 64, 256, and
1024 qualified imported `list.length` call sites. Both workers compiled each
source through Core and C emission in three alternating pairs with
`BLORP_COMPILER_MEMORY_PROFILE=1` and `--time-phases`. Every baseline/candidate
pair emitted byte-identical C; each width had one stable output SHA-256.

| Imported calls | Baseline allocations | Candidate allocations | Allocation/release delta | Median total time delta |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 3,140,524 | 3,140,263 | -261 | +2.67% |
| 64 | 3,256,863 | 3,256,539 | -324 | +0.31% |
| 256 | 3,610,489 | 3,609,973 | -516 | +0.29% |
| 1024 | 5,024,591 | 5,023,307 | -1,284 | -1.12% |

The measured allocation reduction is exactly `260 + imported call sites`.
Because only fixture call-site width changes, the one-allocation slope is
consistent with retiring the intermediate Core target tuple for each call. The
logs do not count the unchanged loaded graph's imported calls, so the fixed 260
term is not attributed more narrowly. Releases fall by the identical count.
Every row retains the same final object count and 32 fewer allocator bytes in
use. Cumulative allocated-byte volume is not exposed by this compiler profile.
Median peak RSS falls by 245,760 to 311,296 bytes across the four widths.
Elapsed medians range from -1.12% to +2.67% and are treated as neutral.

Raw rows, compiler checkpoints, generated sources, output hashes, and C are in
`logs/issue61/final-scaling/`. The authoritative samples are under
`warmed-runs/`; `warmup/` is excluded from the table.

### Compiler self-compile

Both workers compiled the exact same candidate `blorp/src/main.brp`, avoiding a
comparison between different input trees. All 18 measured outputs were
byte-identical with SHA-256
`d455952399b1858ac9e10008ffc1f6e82e1aed92010bdff65a43cfa6b7058587`.

| Metric | Baseline | Candidate | Delta |
| --- | ---: | ---: | ---: |
| allocations | 337,595,261 | 337,552,648 | -42,613 (-0.0126%) |
| releases | 330,679,178 | 330,636,565 | -42,613 (-0.0129%) |
| final live objects | 6,916,083 | 6,916,083 | 0 |
| final live bytes | 677,936,464 | 677,936,432 | -32 |
| median peak RSS | 2,164,228,096 | 2,162,327,552 | -1,900,544 (-0.09%) |

The initial three pairs produced an unfavorable +7.22% total-time median. Before
extending the sample, review predeclared six additional alternating pairs and a
hard rejection threshold: across all nine measured samples, candidate median
total time could be no more than 3.0% above baseline. Output identity and exact
allocator/live-object gates remained mandatory.

Across the final nine samples, baseline total time ranged from 40.867 to 63.235
seconds with a 51.812-second median. Candidate time ranged from 42.003 to 60.787
seconds with a 52.193-second median, a +0.736% difference that passes the
predeclared threshold. Frontend medians were 24.179 and 24.775 seconds (+2.462%);
backend medians were 26.184 and 25.970 seconds (-0.816%). Individual pair deltas
ranged from -13.109% to +5.016%, so the result demonstrates no material
regression but no latency improvement. The deterministic allocator result is
identical in all nine runs.

Raw rows and phase/checkpoint output are under
`logs/issue61/final-self-compile/`; `warmup/` is excluded, the initial three
pairs are in `runs/`, and the predeclared extension is in `extended-runs/`.

A typecheck-only replay was not run because it cannot execute the changed Stage
08 Core boundary. The full self-compile above is the production-path comparison
for this issue.

### Generated C

Candidate compiler C SHA-256 is
`d455952399b1858ac9e10008ffc1f6e82e1aed92010bdff65a43cfa6b7058587`.
Inspection confirms:

- `ImplMethodTarget.module_id` emits as an unboxed `long`;
- `CallableImported` transports its module ID as an immediate integer payload,
  with no per-ID allocation;
- CTFE IR validates the payload with one direct ID-to-path projection and then
  constructs `CtfeIrImportedCall` directly from it for accepted direct and
  selected trait calls; and
- Core callable selection reads `module_id`, converts it to the table index,
  and performs one outer list read before the existing callable-ID dictionary
  lookup. The accepted CTFE and Core branches contain no canonical-path-to-ID
  dictionary probe; only the explicit graphless CTFE fallback retains one.

The repeated-import Core regression proves direct selection by `ModuleId` when
canonical paths share suffixes. A separate negative regression pairs one
module's ID with another module's path and requires fail-closed rejection, so
the retained diagnostic/projection spelling cannot disagree with the join key.

## Conclusion

Accept the bounded migration. It removes one repeated module join at Stage 06
and both accepted downstream path-to-ID joins. The deterministic allocation
slope is consistent with retiring one intermediate Core tuple per imported
call, while focused workload latency is neutral and the production self-compile
does not demonstrate a latency improvement. This is a useful incremental
normalization win, not evidence for a compiler-wide speedup or permission to
add parallel IDs to unrelated typed records.

## Acceptance Criteria

1. Accepted imported callable and implementation-method metadata carries the
   canonical `ModuleId` issued by the retained compilation table.
2. The three named accepted per-expression path-to-ID probes are absent;
   graphless fallback and import-admission lookups remain explicitly classified.
3. No sentinel ID, process-global table, duplicate module table, or test-only
   production API is added.
4. Typed JSON, lint, CTFE, Core naming, diagnostics, identity allocation, and
   generated output remain exact.
5. Focused and production measurements show no material regression. Any speedup
   claim is limited to the measured expression-lowering workload.

## Stop Conditions

Stop and consult before changing `ModuleTable` ownership, `ModuleId` equality,
callable/definition allocation, import visibility, diagnostic text, Core naming,
LSP identity projection, or any Stage 09 representation. Do not broaden this
issue into general definition/type IDs or typed-expression arenas.
