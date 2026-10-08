# Current managed-record allocation census

Frozen source: `39e13d176c9d2bc625fd5cb48faeaa3e68d7dd42`, containing
`origin/main` at `fca8644296c7b76990bfcda8ee9866fd5fe2cf81`. Fetch and merge
reported already up to date. Production compiler sources were clean and
unchanged throughout this measurement.

This is an allocation ranking and source-use audit, not an optimization.
It adds only new evidence files. The `codex/tuple-record-storage` worker owns
shared construction, field evaluation, ownership and typed storage; none of
its checkout or files were edited, built or integrated here.

## Measurement and controls

The compiler self-compile executed **88,981,528 managed-record maker
allocations**, **35.94%** of **247,558,052** global managed allocations.
There were 1,991 validated makers; 1,172 executed. The disposable rewrite
instrumented 4,273 direct allocator call sites in the generated compiler body.

| Process-destructor endpoint | Allocations |
| --- | ---: |
| All native managed allocations | 247,558,052 |
| Instrumented body direct calls | 140,348,026 |
| Validated record makers within those calls | 88,981,528 |
| External runtime or other residual | 107,210,026 |

The control and instrumented compiler use the same freshly generated body,
the same diagnostic runtime and repository-extracted O2 compile/link recipe.
Both emit byte-identical target C and report exactly the same global managed
allocation endpoint. Target C also matches the original generated body.
The control adds only a nonallocating endpoint report; the instrumented body
adds fixed atomic counters and its report. No timing or instruction result
from the instrumented binary is used as performance evidence.

This reuses the unchanged, previously reviewed
`record_allocation_census_2026-10-04/instrument.py`. A final Core catalog and
C body come from one emission. Every `heap_record` joins to exactly one
current emitted maker and installed semantic tag, with unique C types.
Missing, duplicate or ambiguous joins fail. An inversion audit reconstructs
the original body after undoing allocator-call replacements. The fresh
mapping, raw counters, tool and native artifact hashes are bound in the
[packet](record_allocation_census_2026-10-07/).

Each site is a **maker implementation**, not an authored constructor site.
All source constructions calling one maker share its counter. Unique reuse
bypasses allocation; shared fallback construction counts normally. Counts
start at process birth and include CLI setup, source compilation, artifact
publication and shutdown. They are not type-specific phase counts.
Requested bytes include managed headers and padding; they are cumulative
requests, not retained memory, RSS or allocator backing bytes.

The residual includes calls in the separately linked native runtime and
header-initialization paths. Other body sites are explicitly unclassified.
Neither bucket is attributed to a source record type. Inline aggregate boxing
at generic boundaries likewise is not a managed-record maker event.

## Largest makers and boundaries

Labels abbreviate the full semantic identities retained in the complete
site table. Concrete `CoreMapState` instantiations remain separate.

| Record | Allocations | Representative boundary |
| --- | ---: | --- |
| `OwnershipUseSummary` | 5,523,482 | Returned wrapper; public and collection boxes retained |
| `PerceusOwnershipSummaryFrame` | 5,491,253 | Mutable list/frame-stack storage |
| `CoreMonoDataTypeListRewrite` | 3,723,169 | Two managed fields returned, then projected |
| `CoreMonoDataTypeRewrite` | 3,529,963 | Returned wrapper, then projected |
| `BorrowedChildMode` | 3,496,222 | Returned record, also passed whole |
| `CoreMapState[Int, CoreExpr]` | 3,409,643 | Returned state/result; function-value boundary |
| `CoreGlobalValueResolveContext` | 3,361,108 | Some local-only projections, other whole calls |
| `OwnershipCallContract` | 3,050,577 | Whole validation call and result payload |
| `Token` | 2,884,996 | Discovery storage |
| `PerceusInsertedExpr` | 2,386,840 | Returned result; also whole frame payloads |
| `ConvertedExpr` | 2,313,696 | Returned state/expression, then projected |
| `CoreMapState[StringFusionState, CoreExpr]` | 2,096,143 | Returned state/result; function-value boundary |
| `NodeSchema` | 1,777,880 | Small returned shape; callers project payload |
| `CancellationOwnershipFacts` | 1,565,800 | Whole child-fact list and nested-record storage |
| `CancellationPlanAnalysis` | 1,565,800 | Seven-field result; nested facts are stored whole |
| `InferContext` | 1,338,428 | Whole call/update transport |
| `CoreVar` | 1,220,883 | Whole IR storage and binder identity |
| `PerceusResolvedValueIndex` | 1,176,895 | Returned and mutable dictionary-state wrapper |
| `CoreTraitDiagnosticWork` | 1,077,088 | Whole pending-work list |
| `FunctionBodyC` | 1,064,340 | Four-field returned wrapper; managed strings |

`Cursor` has no managed-record maker in this catalog. Its current declaration
is a `fixed record` with three `Int` fields (`blorp/src/lib/source.brp:12`),
eligible for inline representation. This does not establish zero generic
boxing for every Cursor use. The older census's Cursor-first ranking is no
longer the right starting point. Different revisions and inputs prevent
interpreting subtraction from that census as a measured improvement here.

The clearest local-only case is
`stage_09_core/resolve.brp:2088`: an immutable context is constructed and its
two fields are passed to `resolve_global_value_expr_inner`. The retained
[final-Core witness](record_allocation_census_2026-10-07/local-context.core.json)
shows checked projections at ordinals 0 and 1 and the wrapper's ARC cleanup,
with no semantic whole-record sink. Generated C retains its maker and those
projections. The derived result temporary shares a raw numeric ID with the
context; its different name distinguishes the `(name, id)` identity, and its
origin records the derivation. Raw ID equality is not a binding-identity test.

This proves a real compiler construction remains, not that this particular
branch accounts for all 3,361,108 maker events. Site-specific instrumentation
would be needed to establish that branch's dynamic contribution. A future
pass must preserve the two managed fields' evaluation and ownership.

For returned wrappers, the source audit points to:

- `mono_data.brp:239–280`: list and element rewrites return two-field records;
  callers project the result and request list.
- `traverse.brp:4788–4819`: mapper results are projected and new state/result
  records returned; function-reference adapters belong to the shared boundary.
- `closure.brp:3355–3367` and `:3626–3634`: returned state/expression wrappers
  are projected. Child expression identity must remain observable.
- `perceus/results_and_loops.brp:3031–3046` and `:1162–1168`: returned inserted
  expressions are projected, but whole frame payload uses also exist.

These are candidates for shared multi-value results, not proven removable
allocations. `OwnershipUseSummary` explicitly retains public/collection
boxing (`perceus/uses.brp:230`); its comment records an earlier whole-type
conversion regression. Frames (`uses.brp:193–211`, `:3499–3535`), contracts
(`ownership.brp:109–151`) and child cancellation facts
(`cancellation_plan.brp:1176–1213`) provide concrete exclusion controls.
Eligibility must be per binding/function boundary, not a type-wide spelling
or field-count rule.

The additional ranked rows have concrete boundaries too: discovery lexer
`lex/lexer.brp:647` stores Token values whole, while `tables/row_kinds.brp:710`
returns NodeSchema values and `:1038` projects their payload. InferContext
(`stage_06_typecheck/infer.brp:1129–1218`) is threaded through calls/updates;
CoreVar (`ir.brp:1225–1263`, `:5117`) remains the whole binder representation.
Diagnostic work is stored in lists (`trait_resolve.brp:1367–1411`).
`PerceusResolvedValueIndex` (`results_and_loops.brp:2958–2972`, `:3270`)
wraps returned/mutable dictionary state. `FunctionBodyC`
(`stage_10_backend/emit.brp:1690–1699`, `:2016`) is another returned-wrapper
candidate. CancellationPlanAnalysis (`cancellation_plan.brp:1408–1426`)
has seven fields and contains facts subsequently stored whole; it is outside
the initial four-data-member call boundary.

## Reproduction and provenance

Keep a clean checkout fixed between emission and measurement. Build O2 and
require `scripts/compiler-build-status` to report FRESH first. Set a fresh
scratch directory, then run:

```sh
BLORP_CLI_C_OPTIMIZATION=-O2 make
scripts/compiler-build-status
census_output=$(mktemp -d /tmp/blorp-record-census.XXXXXX)
bin/blorp compile --std-dir standard_library/src --no-format --no-embed-runtime \
  --dump-core-after=final --dump-core-file="$census_output/compiler.final.core" \
  -o "$census_output/compiler.normal.c" blorp/src/main.brp
python3 benchmarks/results/record_allocation_census_2026-10-07/measure.py "$census_output"
python3 benchmarks/results/record_allocation_census_2026-10-07/verify.py \
  --census-dir "$census_output"
```

The runner imports the existing stage-2 recipe extractor rather than copying
the historical host-specific build helper. It sets CLI O2, clears memory/leak
and compiler-metrics modes for the measured children, and enables only
`BLORP_MEMORY_STATS=1`. The packet records exact argument arrays and overrides;
`$REPO` and `$OUTPUT` denote checkout and scratch roots. Ambient environment
outside the named overrides is not claimed to be fully captured.

The generator was FRESH, CLI/runtime O2, Apple Clang 21.0.0, bootstrap
`dev-dbc23276a2a6`. Its historical stamp says `b5a05c9593cf-dirty`, while the
frozen source revision above and build-input checks establish the actual
source. Both diagnostic links report diagnostics mode 1. Their reused stamp
says split 8; the recorded stage-2 native recipe actually builds one
translation unit. Fresh Core is 576,643,953 bytes and body C 82,201,013 bytes;
large artifacts and executables remain outside Git. The packet binds their
hashes rather than promising Core identity across checkout paths.

## Verification and next step

The retained counters reconcile every site to body, maker and native totals.
Twelve malformed-observation cases are rejected. The current-emission oracle
passes at loop bounds four and five: fresh scalar/managed makers count N,
unique updates one and shared updates two, with expected values in both
normal and instrumented executables. Complete body/native totals match at
20 and 23. Duplicate Core rows, unmatched tags, duplicate makers and
unsupported tag escapes are rejected; lexical noncalls are ignored, and
inversion and single delegation pass. Optional pthread mechanics from the
older packet were not rerun.

The first tiny oracle used a separately linked runtime, leaving expected
runtime-only allocations outside its direct counters (15/20 and 17/23).
Regenerating the oracle with embedded runtime restored complete coverage;
this is an observation-boundary correction, not a compiler defect. The full
census intentionally uses separate runtime linking and reports its residual.
The final packet retains the corrected oracle commands, logs and verification.
Regenerate that embedded-runtime oracle with the retained source:

```sh
oracle_output="$census_output/oracle"
mkdir -p "$oracle_output"
bin/blorp compile --no-format --check-invariants --dump-core-after=final \
  --dump-core-file="$oracle_output/oracle.final.core" \
  -o "$oracle_output/oracle.normal.c" \
  benchmarks/results/record_allocation_census_2026-10-04/oracle.brp
python3 benchmarks/results/record_allocation_census_2026-10-04/instrument.py \
  "$oracle_output/oracle.normal.c" "$oracle_output/oracle.final.core" \
  "$oracle_output/oracle.instrumented.c" "$oracle_output/oracle.mapping.json"
for mode in normal instrumented; do
  clang -O2 -DBLORP_MEMORY_DIAGNOSTICS=1 "$oracle_output/oracle.$mode.c" \
    -lm -pthread -o "$oracle_output/oracle.$mode"
  env BLORP_MEMORY_STATS=1 "$oracle_output/oracle.$mode" \
    > "$oracle_output/oracle.$mode.n4.stdout" 2> "$oracle_output/oracle.$mode.n4.stderr"
  env BLORP_MEMORY_STATS=1 "$oracle_output/oracle.$mode" extra \
    > "$oracle_output/oracle.$mode.n5.stdout" 2> "$oracle_output/oracle.$mode.n5.stderr"
done
python3 benchmarks/results/record_allocation_census_2026-10-07/verify.py \
  --oracle-dir "$oracle_output" --census-dir "$census_output"
```

Use the same diagnostic-environment exclusions as the measured child runs.
`make hygiene-check` passes; compiler-check's changed plan selects no production
checks and is a no-op, not a passing behavior gate. No compiler implementation
or code-generation change needs a new broad gate or optimization fixpoint.

After the storage prerequisite lands, rebase and refresh these observations.
Use the real local context as an acceptance case and the returned rewrite,
map-state and converted-expression wrappers to test the shared call boundary.
Extend that common analysis; do not add a parallel record walker, layout
authority or binder allocator. Preserve whole container and identity sinks.
An implementation must show net allocation reduction and non-regressing
retired instructions on matched stage-2 O2 builds, plus ownership tests,
generated-C review and the required gates. Maker counts here are activity
envelopes, never promised savings.
