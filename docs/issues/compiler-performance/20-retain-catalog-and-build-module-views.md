# Retain Declaration Authority At The First Production Read

**Status:** Completed by the accepted alias-only vertical slice

## Decision

Issue 20 does not have a catalog-only additive merge point. The first attempt
retained a complete declaration catalog and eager per-module declaration views
while body checking still materialized the same declarations into `Env`. That
duplicated ownership and increased allocations and live memory substantially.
It is rejected.

The replacement strategy is vertical and category-specific:

1. retain only data already produced by accepted type headers;
2. move one production query family to that authority;
3. stop publishing that family into accepted body environments in the same
   slice;
4. preserve the legacy environment path only for provisional header work; and
5. measure the complete compiler before adding the next category.

The first category is type aliases. Records, unions, constructors, type homes,
containment, callables, globals, traits, implementations, overloads, and UFCS
remain separate later slices.

## Problem

Accepted graph declarations were converted back into persistent lexical
environments for every selected module. Type aliases were then repeatedly read
from those environments during annotation canonicalization and inference. This
repeated persistent construction even though accepted type headers already
contained the canonical alias facts.

A broad replacement is unsafe and expensive. The authority must preserve:

- local source spelling;
- selective imported spelling;
- canonical module-qualified names;
- generic parameters and substitution;
- opaque alias targets and defining-module ownership;
- accepted and recoverable graph lifetimes; and
- CTFE artifact preparation.

## Implemented Shape

### Graph Lifetime

`TypecheckGraphFacts` owns one opaque `TypeAliasProjection`. It contains one
canonical `TypeAliasIndex` built from accepted type headers. Accepted and
recoverable graph products share this representation.

The canonical index stores builtin aliases plus canonical transparent and
opaque aliases. Opaque entries retain their defining module. It is built once
in `complete_typecheck_graph`; construction errors reject graph completion with
deterministic internal diagnostics.

### Module Lifetime

When a module is selected for body checking,
`type_alias_projection_find` builds only that module's local and selective-name
overlay. Empty overlays reuse the canonical index directly. Non-empty overlays
share the canonical dictionaries as fallback rather than copying them.

The selected opaque `ModuleView` carries the resulting `TypeAliasIndex`.
`TypecheckState` and `InferModuleFacts` were not widened with another authority
field.

`module_view_without_unqualified_names` clears the accepted alias index along
with local and selective names. Qualified-only views therefore cannot retain a
hidden unqualified alias source.

### Query Authority

Accepted body checking uses the module-view alias index for transparent alias
lookup, recursive and head-only expansion, opaque alias lookup, defining-module
checks, annotation canonicalization, and inference-time resource/capability
shape checks.

Accepted local and imported alias headers no longer publish alias entries into
the body `Env`.

Provisional type-header tests and pre-acceptance construction still use the
legacy `Env` path. Those phases do not yet own an accepted graph product. There
is no accepted-path fallback from a missing alias index to `Env`.

### Recovery And CTFE

Recoverable graphs retain the same canonical projection. An unaffected module
selected from a recoverable graph receives the same module overlay as an
accepted graph. Failed modules remain rejected by the existing global
completion boundary.

Accepted and recoverable CTFE artifact module preparation both derive alias
authority through the graph-owned projection. They do not rebuild alias symbols
in lexical environments.

If a module overlay cannot be projected from accepted headers, preparation
records a deterministic internal error. A canonical index is carried only as a
well-formed placeholder so later code remains typed; the error prevents a
successful body result. The error is not erased with `Option` conversion and
there is no legacy lookup fallback.

## Tests

Focused coverage proves:

- transparent aliases substitute generic arguments;
- opaque aliases do not expand;
- duplicate/cyclic indexes fail closed or terminate deterministically;
- accepted local transparent, generic, and opaque aliases are absent from
  `Env` and available through the module view;
- accepted bodies actually use generic and opaque aliases;
- selective imported builtin and declared aliases resolve canonically;
- imported opaque conversions remain restricted to the defining module;
- provisional header installation still publishes aliases to `Env`;
- unaffected recoverable modules use alias authority;
- accepted and recoverable CTFE artifacts use alias authority; and
- stripping unqualified names also strips alias authority.

Primary commands:

```bash
./blorp test --timeout 180 compiler/tests/test_compiler_type_alias_index.brp
./blorp test --timeout 180 compiler/tests/test_compiler_typecheck_decl.brp
./blorp test --timeout 180 compiler/tests/test_compiler_global_header_completion.brp
./blorp test --timeout 180 compiler/tests/test_compiler_bound_module_graph.brp
./blorp test --timeout 180 compiler/tests/test_compiler_infer.brp
./blorp test --timeout 180 compiler/tests/test_compiler_module_view.brp
./blorp test --timeout 180 compiler/tests/test_compiler_body_check_order.brp
scripts/compiler-check --changed
```

## Measurement Gate

Before merge, run three alternating baseline/candidate production replay pairs
against one captured compiler CLI typecheck request. Every row must have
identical response bytes and SHA-256. Record end-to-end elapsed time, named
typecheck checkpoint time, allocations, releases, current objects, allocator
bytes, and peak sampled RSS.

The slice is not a large performance claim. It is acceptable as the first
authority cutover when output is exact, latency does not materially regress,
and retained memory remains within the 3% gate. A deterministic allocation
increase must be recorded explicitly and reconsidered before widening the
authority.

## Final Measurement

Three order-balanced alternating baseline/candidate pairs used one captured
compiler CLI target-only typecheck request. All six measured rows were verified
and produced the same 2,029,527-byte response with SHA-256
`27bd1660c16a36e99ace6f7a89a0c37680385484639d7b72a5e7ac96f12463b1`.

| Metric | Legacy baseline | Alias authority candidate | Delta |
| --- | ---: | ---: | ---: |
| Median elapsed | 44.589 s | 43.412 s | -2.64% |
| Median named typecheck checkpoints | 24.057 s | 22.882 s | -4.88% |
| Allocations | 263,357,103 | 264,090,833 | +0.28% |
| Releases | 254,349,725 | 255,082,207 | +0.29% |
| Current objects | 9,007,378 | 9,008,626 | +0.014% |
| Allocator bytes | 698,758,368 | 698,870,848 | +0.016% |
| Median peak sampled RSS | 1,053,638,656 | 1,053,540,352 | -0.009% |

The elapsed change was consistent in every pair: -2.71%, -2.79%, and -2.54%.
The slice therefore meets the exact-output, latency, and retained-memory gates.
It does not meet an allocation-reduction goal: transient allocation count rises
by 733,730 per compiler replay. That increase is small relative to total work
and does not increase retained allocator bytes materially, but it is a hard
constraint for the next category. Records/constructors must amortize or remove
this setup cost rather than layering another additive projection with no larger
body-preparation saving.

## Remaining Work

Issue 21 continues with records and fields, unions and variants, constructor
identity/source lookup, type homes and known resource facts, then accepted
containment facts. Issue 22 owns callables, globals, traits, implementations,
overloads, and UFCS. Issue 23 removes obsolete adapters and performs the final
profile/replay audit.

Each category must retain an earlier accepted product, move live readers,
delete the corresponding accepted-body `Env` publication, and pass its own
production measurement before the next category begins.
