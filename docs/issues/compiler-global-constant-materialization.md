# Global Constant Materialization Limitations

This audit began by replacing pure zero-argument factories with top-level
constants. Three compiler limitations prevent some otherwise mechanical
conversions. The affected factories must remain functions until these cases
are fixed and covered by ownership and self-host tests.

## Persistent Generic Stores

Two nested generic-store construction shapes are not currently safe to reuse
as global empty values and then derive updated values from them.

The attempted conversions of LSP `source_store()` and `analysis_cache()` both
typechecked. Their focused tests crashed, and sanitizer runs reported heap
use-after-free errors after a persistent update. `SourceStore` wraps
`UriStore[SourceLayers]`; `AnalysisCacheSnapshot` contains two
`ModuleStore[...]` values. Both factories therefore remain in place.

This does not apply to every persistent global. `DEPENDENCY_STORE_EMPTY` and
other direct, concrete empty stores already covered by sanitizer tests continue
to work. The failure is recorded narrowly rather than generalized beyond the
two reproduced nested generic-factory shapes.

## Imported Constant Initialization

Global initializers that construct compiler semantic union values are not
fully supported by C emission. Converting `builtin_union_types()` into a global
list typechecked, but generated-C preparation failed with:

```text
internal C emission failure: missing projected callable `SemanticNamedType`
```

For the same reason, `accepted_alias_table()` constructs the builtin aliases
while building the graph-owned table: the `TaskResult` target contains
`SemanticNamedType` construction and cannot be materialized as an imported
global constant. The name-only projection can be a constant because CTFE
discards the temporary semantic unions and materializes only the resulting
string list into generated C.

The self-host build also rejects an imported global initializer whose nested
lambda calls the private topology helper `builtin_trait_kind_supertraits`,
reporting that the function cannot be found during compile-time evaluation.
`builtin_trait_topology_is_acyclic()` remains executable so it continues to
detect topology drift instead of being replaced with a literal `True`.

## Imported Record Field Access

Direct field access on an imported record constant can lose the imported
global's module identity during lowering and produce generated C that refers to
an undeclared unqualified name. Binding the imported constant to a local value
before field access works. The CSV constant regression test uses that supported
form and records the workaround next to the assertion.
