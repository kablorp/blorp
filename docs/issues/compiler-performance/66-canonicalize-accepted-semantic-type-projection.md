# Canonicalize Accepted Semantic-Type Projection

**Status:** Measurement-gated after Issues 62-65

**Roadmap:** [Stage 06 Latency Reduction Roadmap](STAGE06_LATENCY_REDUCTION_ROADMAP.md)

**Dependencies:** Issues 62 through 65; refresh the production profile before
admitting an implementation

**Primary owners:**

- `blorp/src/compiler/stage_06_typecheck/headers/type_header_install.brp`
- `blorp/src/compiler/stage_06_typecheck/headers/accepted_alias_graph.brp`
- `blorp/src/compiler/stage_06_typecheck/headers/accepted_record_graph.brp`
- `blorp/src/compiler/stage_06_typecheck/headers/accepted_union_graph.brp`
- `blorp/src/compiler/stage_06_typecheck/decl.brp`
- Stage 06 phase profile fixtures

## Objective

Make accepted declaration construction reuse semantic projections that are
provably identical, especially repeated expansion of transparent alias chains,
without weakening installation-site qualification, generic substitution,
opaque-type boundaries, or graph provenance.

Unlike Issues 62-65, the exact production duplication key is not yet proven.
This issue therefore begins with an admission measurement. If no precise,
high-hit key exists or production impact is too small after the preceding
issues, close the issue without a cache.

## Current Projection Boundary

Accepted alias, record, and union products convert graph-owned
`ResolvedTypeShape` values into the `SemanticType` spellings consumed by the
body checker.

The recursive worker is:

```blorp
private pure func semantic_type_from_resolved_shape_with_substitutions(
	graph: TypeHeaderGraph,
	shape: ResolvedTypeShape,
	installation: TypeHeaderInstallation,
	substitutions: List[SemanticTypeSubstitution],
) -> Option[SemanticType]
```

For a declared type it first projects all arguments, then follows transparent
aliases recursively:

```blorp
DeclaredTypeShape(id, args):
	semantic_args ?= semantic_types_from_resolved_shapes_with_substitutions(
		graph,
		args,
		installation,
		substitutions,
	)

	match type_header_graph_declared_type_expansion(graph, id):
		Some(TransparentAliasExpansion(parameters, target)):
			var alias_substitutions = substitutions
			-- append parameter replacements
			semantic_type_from_resolved_shape_with_substitutions(
				graph,
				target,
				installation,
				alias_substitutions,
			)
		Some(NominalDeclaredType):
			name ?= resolved_declared_type_name(graph, id, installation)
			Some(SemanticNamedType(name, semantic_args))
```

The result depends on more than the displayed type text:

- exact `TypeId` and header graph;
- local versus imported installation;
- installation module scope and path;
- prelude ownership;
- generic and dimension substitutions;
- transparent versus opaque expansion; and
- the semantic argument vector.

Any cache omitting one of these distinctions is incorrect.

The unit of reuse must be an exact graph-owned declared header or alias
`TypeId`, not an arbitrary caller-provided structural `SemanticType` tree. This
keeps ownership and cache cardinality bounded by accepted graph products.

## Profile Evidence

With the maintained mixed type-header fixture at 8 modules, 32 shapes per
module, 64 probes per module, and import fan-out 4, the optimized isolated
phase medians were:

| Phase | Time per iteration | Allocations per iteration |
| --- | ---: | ---: |
| accepted graph | 32.2 ms | 366,956 |
| callable headers | 2.48 ms | 39,182 |
| bound modules | 2.36 ms | 30,302 |
| type headers | 1.59 ms | 27,916 |
| indexed graph | 1.30 ms | 11,099 |

The fixture deliberately constructs nested transparent aliases:

```blorp
type alias MixedM0Alias0 = List[Option[MixedM0Node]]
type alias MixedM0Alias1 = List[Option[MixedM0Alias0]]
type alias MixedM0Alias2 = List[Option[MixedM0Alias1]]
```

Scaling `shapes_per_module`, which also lengthens this alias chain, produced:

| Shapes and alias-chain scale | Accepted phase |
| ---: | ---: |
| 8 | 11.0 ms |
| 32 | 33.0 ms |
| 128 | 252.9 ms |

The 4x increase from 32 to 128 caused about a 7.7x time increase. Function
instrumentation observed approximately 65,946 recursive semantic projection
calls per iteration in the representative fixture.

This proves a scaling problem in the synthetic accepted window. It does not yet
prove which exact results can be reused in the production compiler graph.

## Admission Measurement

Before writing a cache, add a profile-only `SemanticProjectionMetrics` value:

```blorp
struct SemanticProjectionMetrics {
	root_requests: Int,
	recursive_node_visits: Int,
	declared_type_visits: Int,
	transparent_alias_expansions: Int,
	nominal_name_resolutions: Int,
	substitution_lookups: Int,
	maximum_alias_depth: Int,
	repeated_exact_alias_requests: Int,
	unique_exact_alias_requests: Int
}
```

Metrics must be returned explicitly by a benchmark-only or trace-owned path.
Do not introduce mutable global profiling state into the pure production
worker.

An “exact alias request” for admission purposes must at least identify:

```text
same TypeHeaderGraph provenance
same declared TypeId
same local/imported installation and prepared module scope
same semantic argument vector
same active substitution environment relevant to that alias
```

If the current types cannot represent that identity directly, count declared
alias visits by `TypeId` and installation scope and stop at a lower-bound
estimate. Do not serialize a shape to a string or trust a hash collision as
semantic equality.

Admit implementation only if, on the refreshed optimized compiler self-check:

1. accepted semantic projection remains at least 3% of total retired
   instructions or allocations;
2. exact request count is at least twice the unique exact request count, or
   another exact counter proves that at least 50% of projection work repeats;
3. one of the precise strategies below can represent its key without adding a
   managed owner field to every resolved shape; and
4. estimated retained memo size is less than the allocation volume it removes.

If any condition fails, record the evidence and close the issue as rejected.

## Candidate Strategies

Compare the smallest applicable strategies; do not implement all of them.

### Strategy A: Cache installation-specific nominal names

Cache only:

```text
(prepared installation scope, local/imported mode, TypeId)
    -> resolved semantic nominal name
```

This removes repeated `resolved_declared_type_name` and prelude-owner checks but
does not cache recursive types or substitutions. It is the safest candidate if
nominal name resolution remains measurable after Issues 62-65.

### Strategy B: Cache transparent-alias semantic templates

Normalize each transparent alias target once into a parameterized semantic
template that retains exact `TypeParameterId` and dimension-parameter identity:

```blorp
private union SemanticTypeTemplate:
	TemplateNamed(String, List[SemanticTypeTemplate])
	TemplateParameter(TypeParameterId)
	TemplateDimensionParameter(TypeParameterId, Bool)
	TemplateTuple(List[SemanticTypeTemplate])
	TemplateFunction(Bool, List[SemanticTypeTemplate], SemanticTypeTemplate)
	-- other exact SemanticType cases
```

Instantiate that template with the call's semantic arguments. This can make a
long alias chain a one-time graph operation while keeping each request's
substitution explicit.

The template type is illustrative. Reuse an existing exact phase-specific type
if one already expresses this invariant. Do not create a second general type
language unnecessarily.

### Strategy C: Memo exact declared-type expansion requests

Memo:

```text
(installation scope, declared TypeId, semantic arguments)
    -> Option[SemanticType]
```

This is eligible only if `SemanticType` has a safe exact dictionary key or a
small interned identity. A linear memo list, string key, or hash-only equality
is not acceptable: it could reproduce the same scaling problem or conflate
distinct generic/opaque types.

## Recommended Selection Rule

Choose the first strategy that removes the measured dominant repetition:

1. Strategy A if name/owner resolution dominates and provides the required
   whole-compiler instruction reduction.
2. Strategy B if transparent alias expansion dominates and exact template
   instantiation can reuse existing parameter IDs.
3. Strategy C only if exact semantic arguments already have an efficient,
   proven key representation.
4. Reject the issue if none passes the admission and prototype gates.

Do not combine strategies merely to make a benchmark pass.

## Incremental Implementation Plan

### 1. Pin semantic behavior before measurement

Strengthen focused tests for:

- local and imported transparent aliases;
- opaque aliases remaining nominal outside their defining boundary;
- same alias source name in different modules;
- generic aliases instantiated with different type arguments;
- dimension and variadic-dimension parameters;
- recursive records through aliases;
- prelude types provided by the owner and by the global prelude;
- rejected/missing declared expansions; and
- accepted and recoverable graph paths.

Assert exact `SemanticType` trees, not only successful typechecking.

### 2. Add metrics and refresh both profiles

Run the accepted phase matrix and the direct compiler self-check. Report call
counts, exact/unique request counts, maximum depth, allocations, retired
instructions, elapsed, RSS, and checksums.

Stop here if the admission gate fails.

### 3. Prototype candidates outside the retained production API

Use the actual production projection logic behind a temporary benchmark-local
strategy selection. Feed every candidate the same graph and projection request
list. Compare semantic outputs pairwise with the baseline.

Select one strategy before changing accepted graph construction. Delete the
losing prototypes.

### 4. Install one graph-owned memo/template product

The selected product belongs beside the type-header graph or accepted builder
that owns all of its provenance. Thread it explicitly through projection. It
must not live in body-local `TypecheckState`, be reconstructed per module, or
persist across compiler requests.

### 5. Cut over one declaration family at a time

Use these checkpoints:

1. accepted aliases;
2. accepted records;
3. accepted unions and constructor fields; and
4. any remaining global/callable header consumer proven by search.

After each checkpoint, compare exact projection counts and checksums. Delete
the superseded projection at that family before moving to the next; do not keep
dual authority.

### 6. Remove profiling prototypes and reprofile

Keep the phase benchmark's stable semantic checksum and useful scaling metrics.
Remove runtime strategy switches and production-only counters.

## Fast Feedback Loop

Functional loop:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_type_header_dependencies.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_immutable_sharing.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_phase_profile.brp
```

Scaling loop, run with the same compiler binary:

```bash
for shapes in 8 32 128; do
  bin/blorp run --release \
    blorp/benchmark/compiler/compiler_typecheck_phase_profile.brp -- \
    accepted 10 8 "$shapes" 64 4 memory
done
```

Production loop:

```bash
<compiler> check --no-format blorp/src/main.brp
scripts/compiler-check --changed
scripts/compiler-check --stage typecheck
```

Use alternating baseline/candidate binaries for the self-check. Verify exact
output hashes and diagnostics before considering timing.

## Measurable Acceptance Criteria

The issue has two valid outcomes.

### Accepted implementation

- [ ] The admission measurement proves at least twice as many exact requests as
      unique exact requests, or at least 50% repeated projection work by an
      equally precise counter, and at least a 3% production share.
- [ ] The retained key includes exact graph, declaration, installation, generic,
      dimension, and opaque-boundary semantics relevant to the result.
- [ ] No key is based on display strings, generated names, source formatting,
      or an unchecked hash.
- [ ] Semantic projection tests cover every correctness case above and produce
      baseline-identical type trees and errors.
- [ ] Exact repeated alias-expansion visits and semantic nodes allocated by the
      selected projection path fall by at least 50%.
- [ ] At 128 shapes, accepted-phase elapsed time improves by at least 20% and
      total accepted-phase allocations improve by at least 20% relative to the
      immediate parent.
- [ ] The ratio `time(128 shapes) / time(32 shapes)` falls below 6.0 from the
      observed baseline of about 7.7.
- [ ] Whole Stage 01-06 retired instructions improve by at least 1%.
- [ ] Median optimized compiler self-check wall time does not regress by more
      than 2%.
- [ ] Memo entries are bounded by exact unique requests and are released with
      the graph; leak-check passes.
- [ ] One retained strategy and one semantic authority remain.

### Rejected implementation

- [ ] The issue records refreshed production and scaling measurements.
- [ ] It identifies which admission condition failed or why every precise
      strategy lost.
- [ ] All prototype production changes, cache fields, and strategy switches are
      removed.
- [ ] Useful behavior tests and honest profiler improvements may remain.

## Pitfalls and Gotchas

### Opaque aliases

Opaque aliases are nominal outside their defining boundary. Expanding them
because their source target happens to match a transparent alias is a semantic
bug and an optimization fence violation.

### Installation-specific spelling

The same definition may spell differently when installed locally, imported,
or supplied by the prelude. A definition-only cache key is insufficient.

### Generic substitution capture

Caching a result containing the first request's concrete arguments would
poison later instantiations. Either cache an exact argument-keyed result or a
parameterized template.

### Managed key overhead

Adding graph/scope/type payloads to every recursive shape can cost more ARC and
memory than the cache saves. Prior dense-module work rejected this kind of
per-declaration carrier expansion. Keep provenance on the owning memo product.

### Synthetic-only victory

The nested-alias fixture is intentionally adversarial. A large fixture win is
not sufficient without the whole-compiler admission and acceptance thresholds.

## Non-Goals

- Do not redesign the inference metavariable solver.
- Do not change type alias, opaque type, or qualification semantics.
- Do not intern every `SemanticType` globally.
- Do not add cross-request caches.
- Do not add managed identity fields to every resolved type-shape node.
- Do not optimize parsing or body inference in this issue.

## Expected Result

If admitted, the accepted phase should expand each semantically identical alias
or nominal projection once per exact installation context, bringing deep alias
scaling closer to the amount of unique semantic output. If precise reuse is not
available, the issue should end with a documented rejection rather than a
fragile cache.
