# Batch Lexical Parameter Scope Publication

**Status:** Parameter batching rejected at the Phase 0 admission gate;
profiling scaffolding removed and a smaller scalar scope-list cleanup retained

**Dependencies:** Issue 43 is complete. Issue 44 selected this lexical
candidate for exact admission measurement.

**Primary owners:**

- `blorp/src/compiler/stage_06_typecheck/type_system/env.brp`
- `blorp/src/compiler/stage_06_typecheck/decl.brp`
- `blorp/src/compiler/stage_06_typecheck/infer.brp`

## Objective

First, attribute current scope publications and their cost specifically to
function and lambda parameter installation. If that Phase 0 measurement passes
the gate below, publish each function or lambda parameter set to its new
lexical scope as one ordered batch rather than publishing a complete `Scope`,
`Env`, and often `TypecheckState` after every individual parameter binding.

This issue deliberately selects one narrow direction from Issue 44. It does
not authorize a general `Env` redesign, accepted-declaration rematerialization,
or batching of bindings whose visibility is genuinely sequential.

## Phase 0 Outcome (2026-09-08)

The ordered batch prototype preserved the focused environment, function, and
lambda semantics, and it reduced parameter publication to one update per
non-empty scope. It did not meet the admission thresholds. In particular, the
one-parameter function and lambda shapes increased exact allocation/release
counts, while the wide shapes remained well below both the 15% allocation and
10% retired-instruction requirements. The prototype, its tests, the temporary
benchmark fixture, and its profile-only runtime counters were therefore
removed rather than retained as unadmitted production complexity.

### Revisions and executable identity

- Baseline source revision: `4a7aa34b7ecfa237085435cb1d484083143e2400`.
- Candidate source: an uncommitted Phase 0 prototype on that revision; no
  candidate commit was created because the stop gate required deletion.
- Baseline compiler executable SHA-256: `8de2ac88f80f90b5a9e49afd67568b76a1b8659067e903aecfd1418f7a307fa5`.
- Candidate compiler executable SHA-256: `082b22e870108f5d16a8f9e2a805efaa0d652a49dac5f98a9affe80ae3b680b3`.
- Baseline focused executable SHA-256: `c7f86e5e1059d084dbea55de9f73f64c03bd6848fcabbc3986efe9d3ee1deb61`.
- Candidate focused executable SHA-256: `e0973a755dc86cac36aa2e7cefcac7033f189c80529ef9165f55856bb244e6fc`.

### Exact production attribution

A temporary profile-only call-stack classifier attributed every scalar
`scope_add_symbol` entry in a Phase 01-06 self-check. The category sum equals
the exact total; there was no unclassified remainder:

| Category | Scalar publications |
| --- | ---: |
| Ordinary function parameters | 26,105 |
| Lambda parameters | 3,071 |
| Sequential locals | 20,389 |
| Pattern and control-flow bindings | 42,038 |
| Builtin and provisional publication | 106,844 |
| Unclassified | 0 |
| **Total** | **198,447** |

The focused workload also exposed one fixed function-parameter publication
from its required `main` harness. Excluding that separately reported harness,
the scalar baseline count equaled the configured number of bound parameter
names in every isolated shape.

### Logical publication counts

The prototype used a three-field `ParameterBinding` record (`name`, semantic
type, and optional source type). `env.brp` fixed mutability, origin,
refinement, module path, and definition identity for that narrow API, built
the ordered `Symbol` list, and replaced the current scope once. The same
private `scope_add_symbols` primitive temporarily served existing type batches.

The following counts include the fixed harness publication. Candidate scalar
parameter publications were zero; candidate batch publications were one for
the harness plus one for each configured non-empty parameter scope.

| Family | Width | Bound names | Baseline scalar publications | Candidate batch publications |
| --- | ---: | ---: | ---: | ---: |
| Function | 0 | 0 | 1 | 1 |
| Function | 1 | 512 | 513 | 513 |
| Function | 4 | 2,048 | 2,049 | 513 |
| Function | 16 | 8,192 | 8,193 | 513 |
| Function stress | 64 | 8,192 | 8,193 | 129 |
| Lambda | 0 | 0 | 1 | 1 |
| Lambda | 1 | 512 | 513 | 513 |
| Lambda | 4 | 2,048 | 2,049 | 513 |
| Lambda | 16 | 8,192 | 8,193 | 513 |
| Lambda stress | 64 | 8,192 | 8,193 | 129 |

### Allocation and elapsed evidence

Fixture generation and retained parsing occurred before the internal measured
window. Allocations and releases were identical in every row. Both executables
reported zero retained objects and zero retained bytes after each measured
window. Elapsed time is one supporting sample in microseconds; exact allocation
counts are the admission signal in this table.

| Family | Width | Baseline allocations | Candidate allocations | Change | Baseline us | Candidate us |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Function | 0 | 129,619 | 130,134 | +0.397% | 16,018 | 25,507 |
| Function | 1 | 153,683 | 155,222 | +1.001% | 19,545 | 29,029 |
| Function | 4 | 268,883 | 261,206 | -2.855% | 29,323 | 41,419 |
| Function | 16 | 733,779 | 691,286 | -5.791% | 86,881 | 102,169 |
| Function stress | 64 | 659,513 | 612,540 | -7.122% | 75,873 | 84,541 |
| Lambda | 0 | 408,687 | 408,690 | +0.001% | 47,474 | 59,539 |
| Lambda | 1 | 436,335 | 437,874 | +0.353% | 58,205 | 65,316 |
| Lambda | 4 | 557,167 | 551,026 | -1.102% | 77,768 | 82,333 |
| Lambda | 16 | 1,049,711 | 1,014,898 | -3.316% | 198,266 | 131,063 |
| Lambda stress | 64 | 714,703 | 675,794 | -5.444% | 145,199 | 118,449 |

### Retired-instruction evidence

The optimized focused executables were run in three alternating pairs with
five typecheck iterations per process to amortize setup. Values below are the
median process-level retired instructions. The first run's higher cold-start
function-wide baseline did not affect its median.

| Family | Width | Baseline instructions | Candidate instructions | Change |
| --- | ---: | ---: | ---: | ---: |
| Function | 16 | 6,675,194,523 | 6,261,227,667 | -6.202% |
| Function stress | 64 | 5,977,194,097 | 5,378,103,863 | -10.023% |
| Lambda | 16 | 9,780,545,643 | 9,420,808,045 | -3.678% |
| Lambda stress | 64 | 7,048,535,065 | 6,519,228,026 | -7.509% |

Only the function stress row crossed the 10% instruction threshold. Neither
wide row did, neither lambda row did, and no row crossed the 15% allocation
threshold. The common one-parameter allocation regression was additional
negative evidence against the design.

### Correctness and stop decision

During the prototype, the focused suites passed with 32/32 environment tests,
127/127 declaration tests, and 305/305 inference tests. Every benchmark shape
reported zero errors, zero retained objects, and the same semantic checksum
between baseline and candidate (`1028`, `1540`, `3076`, `9220`, and `8452` for
widths 0, 1, 4, 16, and stress 64 respectively). The new batch-API test failed
before implementation because the API was absent, then passed with the
prototype.

Because the focused admission gate failed, the controlled Phase 01-06
candidate comparison, sanitizer sweep, and final production review were not
run. Running them could not admit a design that had already failed exact
allocation and wide-instruction criteria. No adjacent lexical category is
authorized by this result; any future attempt needs a representation that
does not allocate a pending record per binding and must start with a new
admission issue.

## Post-gate Mechanical Cleanup

A review of the rejected prototype exposed an independent inefficiency in the
existing scalar path. `env_add_symbol`, `env_add_accepted_type_symbol`, and
`env_replace_current_scope` rebuilt the complete scope list with a
`get`/`append` loop merely to replace element zero. `env_pop_scope` used the
same pattern merely to remove element zero. The retained cleanup uses the
existing value-semantic `List.set(0, ...)` and `List.drop(1)` operations while
preserving the explicit empty-scope fallback. It does not add an API, builder,
cache, compatibility path, or parameter representation. The production diff
is 10 added and 50 deleted lines.

A clean compiler from baseline revision `4a7aa34b7ecfa237085435cb1d484083143e2400`
and the cleanup candidate were run in three alternating Phase 01-06 self-check
pairs. Every run produced the same output hash. Median supporting results were:

| Measure | Baseline | Cleanup | Change |
| --- | ---: | ---: | ---: |
| Retired instructions | 204,305,300,650 | 204,063,938,254 | -0.118% |
| Cycles | 47,280,074,733 | 46,929,494,300 | -0.741% |
| Wall time | 12.45 s | 12.40 s | -0.402% |
| Peak footprint | 822,723,496 bytes | 823,493,568 bytes | +0.094% |

The footprint difference is less than 0.1% and was not treated as evidence of
a retained-memory change. The instruction reduction, identical output, and
smaller implementation justify this narrow cleanup independently of the
failed batching design.

## Required Reading

Before editing, read:

- `docs/issues/compiler-performance/ENVIRONMENT_REUSE_ROADMAP.md`;
- `docs/issues/compiler-performance/43-delete-legacy-environment-materialization-and-reprofile.md`;
- `docs/issues/compiler-performance/44-optimize-lexical-environments-if-measured.md`;
- `blorp/src/compiler/stage_06_typecheck/type_system/env.brp`;
- `prepare_function_body_state` and its parameter helpers in
  `blorp/src/compiler/stage_06_typecheck/decl.brp`;
- `infer_lambda_params`, `add_lambda_param_bindings`, and
  `infer_lambda_expr` in `blorp/src/compiler/stage_06_typecheck/infer.brp`;
- `blorp/test/compiler/stage_06_typecheck/type_system/test_env.brp`;
- the function-parameter tests in
  `blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp`; and
- the lambda inference tests in
  `blorp/test/compiler/stage_06_typecheck/test_infer.brp`.

Trust the current implementation and tests over line numbers in this document.
Reinventory the named functions before changing them.

## Current Representation

The lexical namespace uses a persistent scope value:

```blorp
private record Scope {
	symbols: List[Symbol],
	symbols_by_name: Dict[String, List[Int]]
}
```

`Env` owns `List[Scope]` together with type parameters, trait and builtin
facts, containment state, and other session data. A scalar binding currently
passes through `env_add_var_with_details`, `env_add_symbol`, and
`scope_add_symbol`.

`scope_add_symbol` performs two persistent collection updates:

```blorp
symbol_index = scope.symbols.length()
name_candidates = scope.symbols_by_name.get_or(symbol.name, [])

{ scope |
	symbols = scope.symbols.append(symbol),
	symbols_by_name = scope.symbols_by_name.set(
		symbol.name,
		[symbol_index].concat(name_candidates),
	)
}
```

`env_add_symbol` then replaces the current scope by reconstructing the scope
list and returns a new `Env`. Callers commonly wrap that result in a new
`TypecheckState` or `InferContext`.

Blorp's value semantics do not require every update to deep-copy all payloads.
COW can reuse uniquely owned collection storage. The problem is that each
parameter currently crosses a persistent publication boundary. Live input and
intermediate snapshots require collection shells, retains, releases, and
destruction even though no consumer observes a partially populated parameter
scope.

## The Safe Batch Boundaries

### Ordinary function parameters

`prepare_function_body_state` creates a new scope, installs effective type
parameters, and then calls `prepare_function_param` once per parsed parameter.
Named and destructured tuple parameters eventually call
`add_function_param_binding`, which publishes one environment per bound name.

The complete function signature has already been constructed before this
loop. A later parameter does not typecheck its annotation by looking up an
earlier value parameter here. The body begins only after every parameter has
been processed. Parameter bindings can therefore be collected in source order
and published once.

Parameter diagnostics must still be accumulated in source order while the
batch is prepared:

- a missing source annotation still reports the existing error and installs
  the signature-provided fallback binding;
- a tuple binder with the wrong tuple arity still reports exactly the existing
  error and installs no partial tuple bindings;
- wildcard binders install no symbol; and
- duplicate or shadowing behavior remains whatever current validation and
  lookup tests establish.

### Lambda parameters

`infer_lambda_params` already resolves every parameter before
`add_lambda_param_bindings` is called. `add_lambda_param_bindings` then loops
over the completed `TypedLambdaParam` list and calls
`env_add_var_with_details` once per parameter.

This is an especially clean batch boundary: all parameter types and errors are
already final, and the lambda body is not inferred until all bindings have
been installed.

### Explicitly deferred lexical bindings

Do not batch:

- sequential `let` or `var` declarations in an expression body;
- loop variables with initialization or checks between bindings;
- pattern bindings while recursive pattern inference is still using the
  progressively refined environment;
- match cases, resource scopes, or concurrent/select arms merely because they
  call `env_push_scope`; or
- compiler builtin or provisional declaration installation.

Those paths require their own evidence and semantic analysis. Do not widen
this issue during implementation.

## Profiling Evidence

### Measurement environment

The admission profile was collected on 2026-09-07 from local `main` at
`34e5986b` on Apple M4 arm64 macOS. The production Phase 01-06 command was:

```bash
bin/blorp check --no-format blorp/src/main.brp
```

Three runs of the current local compiler took `15.58`, `15.39`, and `15.42`
seconds, for a median of `15.42` seconds. This is a local `-O0` wall-time
reference, not a portable acceptance threshold.

The function-instrumented self-check reported approximately:

| Operation | Calls |
| --- | ---: |
| `scope_add_symbol` | 198,292 |
| `env_add_symbol` | 184,751 |
| `scope_lookup` | 4,079,017 |

Function instrumentation charges most collection and ownership work to
runtime helpers below these wrappers, so the wrappers' reported self-time is
not a reliable cost estimate. The call counts show that Stage 06 crosses
scalar scope-publication boundaries at very high frequency, but they include
every caller. They do not attribute those publications to parameters and do
not by themselves satisfy Issue 44's implementation entry criteria.

A 10-second native sample of the same self-check contained 8,450 samples. At
least about 25% of top-frame samples were directly in retain, release, or
destruction helpers. List/dictionary copying and `memmove` contributed another
roughly 8%, while cancellation and cleanup bookkeeping contributed roughly
14%. These percentages describe broad runtime cost pools; they must not be
claimed as costs removable by this issue. They establish why eliminating
unobserved persistent snapshots is worth a focused experiment.

### Function-heavy Stage 06 workload

The maintained retained-program benchmark was run with:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 1 1 16 256 retained
```

The workload contained 273 source declarations and materialized 257 function
bodies. Its generated functions have one parameter and one local declaration
each. One sample reported:

| Operation | Calls | Instrumented inclusive time |
| --- | ---: | ---: |
| complete typecheck graph | 1 | 391.0 ms measured window |
| function body materialization | 257 | 208.3 ms |
| `env_add_symbol` | 1,152 | 3.0 ms wrapper envelope |
| `scope_add_symbol` | 1,152 | 1.7 ms wrapper envelope |

The wrapper timings exclude much of the downstream ARC and collection cost
and must not be used to predict the final speedup. The 1,152 calls also include
non-parameter insertions. This fixture is a useful one-parameter common-case
control, but it neither isolates parameter installation nor demonstrates the
repeated-within-one-scope publication that batching is intended to remove.

### Existing scope cost model

The optimized `compiler_scope_construction_profile` benchmark currently shows:

| Symbols per batch | Median time per batch | Allocations per batch |
| ---: | ---: | ---: |
| 65 | 26.9 us | 468 |
| 257 | 105.8 us | 1,814 |
| 1,025 | 449.4 us | 7,192 |

That fixture constructs union types and constructors, not lexical parameter
scopes. Treat it only as evidence that the existing symbol/index representation
has approximately linear time and about seven allocations per installed
symbol. It is not the focused acceptance benchmark for this issue.

### Lookup is not the target

The optimized name-lookup benchmark measured about 17-18 ns per query for
256-name and 1,024-name environments. Do not replace the lookup dictionary,
change key representation, or redesign lookup ordering in this issue. The
measured candidate is publication, not lookup.

### Relationship to accepted declaration work

Issues 37-43 already removed accepted graph declaration payloads from `Env`.
Do not attribute the entire accepted-graph phase or all ARC/list/dictionary
samples to lexical scopes. In particular, do not reintroduce graph declarations
into `Env`, add a second declaration catalog, or bypass accepted authority
tables as part of this work.

## Phase 0 Admission Gate

Do not change production publication behavior until this gate has passed.

### 1. Attribute production calls

Add profiling-only attribution that distinguishes at least:

- ordinary function parameter binding publication;
- lambda parameter binding publication;
- ordinary sequential local binding publication;
- pattern and control-flow binding publication;
- builtin or provisional declaration publication; and
- any remaining unclassified caller.

Report both bound symbols and published scopes for each category. The sum of
the categorized scalar publications must equal the measured
`scope_add_symbol` total for the profiled route. Do not infer attribution from
function names, the number of source declarations, or total wrapper calls.

The counters may live in a profiling-only benchmark or instrumentation build.
They must not add mutable global state or permanent work to an ordinary
compiler executable.

### 2. Establish a production-shaped parameter fixture

Extend or add a fixture with independently configurable:

- ordinary function count;
- ordinary parameters per function;
- lambda count; and
- lambda parameters per lambda.

Keep function and lambda bodies otherwise fixed. Include parameter counts 0,
1, 4, 16, and 64. The current `compiler_typecheck_profile` shape remains the
one-parameter control; it is not the wide-parameter benchmark.

For each shape, record current scalar parameter publications, total scope
publications, allocations, releases, retained objects and bytes, elapsed time,
and retired instructions. Confirm that current parameter-attributable
publication grows with total bound parameters rather than parameter scopes.

### 3. Fail-fast prototype

Implement the smallest batch-publication prototype needed to measure the new
fixture. It may be a short-lived checkpoint, but it must use the intended
ordered symbol/index construction rather than skipping lookup or diagnostics.
Run the semantic checksum and focused tests before trusting its performance.

Proceed with the complete production change only if all of these hold:

- ordinary and lambda parameter publications are exactly attributed;
- current scalar publication count equals the number of bound parameter names
  for the isolated parameter cases;
- the prototype reduces scope publication to one per non-empty parameter
  scope;
- the wide and stress shapes reduce retired instructions by at least 10% and
  allocations/releases by at least 15%; and
- the common one- and four-parameter shapes do not regress retained memory or
  retired instructions.

If the gate fails, append the measurements, remove the prototype and profiling
scaffolding, mark this issue rejected, and close Issue 44 with a no-action
result. Broad ARC/list/dictionary samples are not grounds for lowering the
gate.

## Required Design

The following design applies only after Phase 0 passes.

### 1. Add a general private scope batch primitive

Generalize the existing `scope_add_type_symbols` mechanism into a private
ordered helper that can add `List[Symbol]`:

```blorp
private pure func scope_add_symbols(
	scope: Scope,
	added_symbols: List[Symbol],
) -> Scope:
	...
```

It must:

1. concatenate the symbol payloads once;
2. number new symbols from the original `scope.symbols.length()`;
3. update `symbols_by_name` in source order;
4. prepend each newer index to the name's candidate list, preserving current
   newest-binding-first lookup; and
5. return the original scope unchanged for an empty batch.

Migrate the existing type-declaration batch helper to this implementation
rather than retaining two equivalent loops. This is code sharing only; do not
change accepted or provisional type behavior.

### 2. Add a narrow variable-binding batch API

Provide one environment API that constructs and publishes an ordered batch of
variable symbols. Its input must represent the same data currently supplied
to `env_add_var_with_module_details`:

- name;
- semantic and optional source type;
- mutability;
- origin;
- refinement;
- optional module path; and
- optional definition ID.

Choose a name and phase type that make this a binding batch, not a generic
escape hatch into `Scope` internals. Do not expose `Scope`, allow callers to
replace indexes independently, or add a Boolean that conflates ordinary and
accepted publication policies.

The variable-binding batch input must make type symbols unrepresentable and
must therefore leave type-containment validity unchanged, exactly as repeated
variable-only `env_add_symbol` calls do. The private generic scope helper owns
no containment policy. Existing ordinary and accepted type-publication
wrappers must retain their current, distinct shadowing and invalidation checks.

Do not introduce an input record whose own allocations erase the publication
savings without measuring it. Reuse an existing binding representation where
that preserves module boundaries, or compare candidate representations in the
focused allocation benchmark before retaining one.

### 3. Prepare ordinary function bindings before publication

Refactor the `prepare_function_param` family so it produces:

- ordered pending parameter bindings; and
- the same ordered diagnostic updates.

After every parameter is prepared, publish the complete binding list once to
the newly pushed scope and create the body `TypecheckState` once. Tuple-binder
names must appear in their current left-to-right order.

Do not preserve the old scalar publication loop as a fallback. Scalar
`env_add_var_with_details` remains valid for genuinely sequential bindings
elsewhere, but `prepare_function_body_state` must have one batch publication
path.

### 4. Batch lambda parameter publication

Replace the loop in `add_lambda_param_bindings` with the same narrow batch API.
Do not change `infer_lambda_params`, expected-type propagation, mutable-capture
checking, or when the lambda scope is pushed and popped.

### 5. Keep module/session ownership unchanged

The result remains an ordinary fresh lexical `Env` owned by one body session.
Do not retain builders or pending binding lists in
`PreparedCanonicalModuleEnvironment`, `PreparedInferSessionEnv`, graph facts,
typed AST, or diagnostics.

If a transient builder is introduced internally, make its unfinished state
unobservable through an opaque or private phase-specific type. Finishing it
must consume the builder and produce one valid `Scope`; do not rely on a naming
convention or undocumented uniqueness heuristic.

## Tests First

Before changing production code, add focused assertions for the batch API and
its two consumers.

### Environment behavior

In `type_system/test_env.brp`, compare scalar and batch construction for:

- an empty batch;
- one binding;
- distinct bindings in source order;
- repeated names, proving the final binding wins;
- lookup of every candidate for a repeated name, if that candidate list is
  observable through the current public API;
- shadowing across current and outer scopes;
- push, batch-add, lookup, and pop restoration; and
- containment validity remaining identical for variable-only batches.

Construct an expected environment through the existing scalar API and compare
all observable lookup results rather than comparing a private representation.

### Function parameters

Cover:

- zero, one, and many named parameters;
- wildcard parameters;
- tuple-destructured parameters;
- tuple arity mismatch;
- missing explicit parameter annotation;
- a parameter shadowing an allowed outer binding; and
- exact error text and order when multiple parameters are invalid.

### Lambda parameters

Cover:

- zero, one, and many lambda parameters;
- expected and explicitly annotated parameter types;
- duplicate-name diagnostics;
- parameter shadowing of an outer immutable or mutable name according to
  current rules; and
- absence of parameter bindings after the lambda body scope is popped.

At least one new assertion must fail before the implementation because it
observes parameter-attributed publication count, not merely because a new API
does not exist.

## Focused Publication Benchmark

Use the Phase 0 benchmark that isolates function and lambda parameter scope
entry. Fixture generation must happen outside the measured window. Its final
acceptance matrix must include at least these shapes:

| Shape | Bodies | Parameters per scope |
| --- | ---: | ---: |
| control | 512 | 0 |
| common | 512 | 4 |
| wide | 512 | 16 |
| stress | 128 | 64 |

Include ordinary functions and lambdas as separately reported cases. Keep
body expressions trivial and identical so the measured delta scales with
parameter count rather than expression inference.

Report:

- parameter bindings prepared;
- lexical scopes entered;
- scope publications;
- scalar `env_add_symbol` calls attributable to parameter installation;
- allocations and releases during the measured window;
- current objects and bytes after the window;
- elapsed microseconds; and
- a semantic checksum proving every parameter lookup resolves to the expected
  type and newest binding.

Logical counters are the CI-stable proof. Do not infer publication count from
elapsed time. Keep benchmark-only counting out of ordinary production state if
it would itself add work to every typecheck.

The expected scaling after the change is:

```text
parameter bindings:  O(total parameters)
scope publications:  O(functions + lambdas)
```

not:

```text
scope publications:  O(total parameters)
```

## Fast Feedback Loop

Use this loop while implementing:

1. Add attribution and the wide-parameter benchmark, then run the Phase 0
   baseline and fail-fast prototype. Stop if the admission gate fails.
2. Format only changed production and test sources after the gate passes.
3. Run the focused environment suite:

   ```bash
   bin/blorp test \
     blorp/test/compiler/stage_06_typecheck/type_system/test_env.brp
   ```

4. Run the focused declaration and inference suites:

   ```bash
   bin/blorp test \
     blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
   bin/blorp test \
     blorp/test/compiler/stage_06_typecheck/test_infer.brp
   ```

5. Run the parameter publication benchmark for the required shapes.
6. Run the maintained function-heavy profile as a one-parameter control:

   ```bash
   BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
     benchmarks/compiler_typecheck_profile 5 1 16 256 retained
   ```

7. Inspect its function profile for `env_add_symbol`, `scope_add_symbol`,
   function-body materialization, and the new batch helper.
8. Run manifest-owned checks:

   ```bash
   scripts/compiler-check --changed
   scripts/compiler-check --stage typecheck
   ```

Because this changes managed collection ownership, run the relevant leak and
sanitizer coverage before review:

```bash
scripts/test compiler-blorp-sanitize
```

Do not run C emission or native C compilation profiles for this issue. The
whole-program performance boundary is Phase 01-06.

## Controlled Phase 01-06 Comparison

Build baseline and candidate compilers from the same bootstrap pin and with
the same C optimization flags. Record their executable hashes. Warm each once,
then run at least three alternating uncontended pairs:

```bash
/usr/bin/time -lp <compiler> check --no-format blorp/src/main.brp
```

For every run record:

- wall time;
- retired instructions and cycles where available;
- peak resident footprint;
- exit status; and
- a hash of stdout and stderr.

Retired instructions and focused allocation counts are the primary acceptance
signals. Wall time is supporting evidence because this workload is sensitive
to host noise. Do not compare a newly optimized candidate against a stale or
differently built baseline executable.

## Acceptance Criteria

### Semantic

- Function and lambda parameter lookup behavior is unchanged.
- Binding, duplicate, shadowing, tuple, wildcard, and missing-annotation
  diagnostics are byte-identical and remain in the same order.
- Parameter bindings cannot escape their lexical scope.
- Type containment validity and restoration are unchanged.
- Accepted declaration authorities and prepared module/session ownership are
  unchanged.
- All focused Stage 06, leak, and sanitizer checks pass.

### Structural

- `Scope` has one ordered batch insertion implementation.
- Existing type-declaration batching reuses that implementation.
- Ordinary function parameter installation publishes exactly one scope for a
  non-empty parameter batch.
- Lambda parameter installation publishes exactly one scope for a non-empty
  parameter batch.
- Neither consumer retains a scalar parameter-publication fallback.
- Scalar environment addition remains available only for bindings whose
  visibility is sequential or whose call sites are outside this issue.
- No builder, pending list, compatibility adapter, or duplicate index survives
  beyond the lexical scope-entry boundary.

### Measured

- In the focused benchmark, parameter-attributable scalar publications fall
  to zero and total scope publications equal the number of non-empty function
  and lambda parameter scopes.
- The common, wide, and stress shapes reduce measured-window allocations and
  releases by at least 15% relative to the immediate parent.
- The wide and stress shapes reduce median retired instructions by at least
  10% relative to the immediate parent.
- Retained object and byte counts after the measured window do not increase.
- The Phase 01-06 self-check produces byte-identical output and does not
  regress median retired instructions by more than 0.05%.
- Prefer a Phase 01-06 retired-instruction improvement of at least 0.10%. If
  the whole-compiler change is below that threshold, retain the implementation
  only when the focused thresholds are met and the production diff is a clear
  net simplification. Record that judgment explicitly.

## Stop Conditions

Abandon or redesign the candidate rather than weakening the criteria if:

- pending-binding records allocate enough to erase the publication savings;
- current Perceus/COW behavior already fuses the scalar updates in optimized
  output and the focused instruction count does not improve;
- batching changes diagnostic order or requires a compatibility path;
- a proposed API exposes `Scope` internals outside `env.brp` merely for speed;
- a caller needs a binding to be visible before the rest of its batch is
  prepared; or
- the change begins absorbing pattern, loop, module, builtin, or accepted
  declaration work without separate profile evidence.

## Required Implementation Report

Before marking this issue complete, append:

- baseline and candidate revisions and executable hashes;
- the final API and ownership design;
- exact logical publication counts for every benchmark shape;
- allocations, releases, retained objects/bytes, elapsed time, and retired
  instructions for baseline and candidate;
- the three-pair Phase 01-06 comparison;
- semantic output hashes;
- test pass/fail counts; and
- any deferred lexical publication candidates discovered during the work.
