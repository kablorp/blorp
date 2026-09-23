# Type Interning Roadmap

Goal: one table of types per compilation, so that two structurally equal
types are the same row, equality is an integer compare, substitution that
changes nothing returns the input, and mono, trait dispatch and lowering key
by type id instead of by rendered strings or linear scans. Names follow the
same rule where a measured cost remains. This is the table approach of
[`FRONTEND_FACTS_ROADMAP.md`](FRONTEND_FACTS_ROADMAP.md) applied to types; it
extends that roadmap's T3, T5 and T6 rather than replacing them.

Each step lands on its own with a measurement taken before it starts. Read
[`WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md) first. There is no measurement
lock; run gates directly.

Anchors are against main at `dab2f490` (2026-09-23).

Companions: [`CORE_NODE_TABLE_ROADMAP.md`](CORE_NODE_TABLE_ROADMAP.md) (its
step N5 consumes this roadmap's I3) and
[`STRUCT_PAYLOAD_ROADMAP.md`](STRUCT_PAYLOAD_ROADMAP.md) (its step S4 consumes
this roadmap's I6 name ids).

## What is true today

**Two type representations.** The typechecker's `SemanticType`
(`stage_06_typecheck/type_system/semantic_type.brp:16`, eleven variants,
metas as `SemanticMetaType(MetaSessionId, Int)`) and Core's `CoreType`
(`stage_09_core/ir.brp:731`, fourteen variants). Lowering converts one to the
other in `core_lower_type_with_prefixes_impl` (`lower.brp:1342`): 1,275,348
calls per self-compile producing only 22,180 distinct shapes
(`benchmarks/results/core_lowering_type_histogram_2026-09-22.md`). Six
arg-less scalars are already module constants; everything else allocates a
fresh `CoreType` per call. There is no type scheme; generalization is by
name at zonk time.

**Equality.** `types_equal` (`semantic_type.brp:789`, 80 sites) gained a
`same_object` short-circuit on 2026-09-23 (`c92c10a0`). `core_type_equal`
(`ir.brp:829`, 37 sites) and `core_mono_type_equal` (`mono.brp:203`, 139
sites, with its own dim normalization) have none. `MetaSessionId` already
does pointer-first equality (`meta_identity.brp`), which is the pattern.

**What still allocates on no change.** `apply_subst_with_visited` and
`apply_subst_list` (`semantic_type.brp:1287, 1274`) rebuild every node;
`qualify_module_local_types` (`:486`, 76,275 calls, 2.55 allocations each)
uses `args.map(closure)`; mono's `apply_type_substitution` family
(`mono.brp:818-842`) rebuilds every non-leaf; `split_canonical_module_type_name`
(`:340`) allocates a tuple and substrings 679,274 times (1.17M allocations).
The identity-preserving variants that did land this week measured -1.28%,
-1.48% and -0.59% of total allocations each (`b962c0ed`, `3672b40c`,
`45de87be`).

**Keys that are strings or scans.**

- Mono deduplicates instantiation requests by a *linear list scan* over
  mangled names: `request_is_generated` (`mono_specialize.brp:779`) walks
  `List[CoreMonoFunctionRequest]` comparing `request.mangled_name ==
  mangled_name`. `mangle_specialization_name` (`mono.brp:1268`) sorts the
  substitution and renders it.
- Trait dispatch keys on a rendered type: `core_trait_impl_type_key`
  (`trait_resolve.brp:278`) flattens a `CoreType` to `Name_Arg1_Arg2`, used
  from `resolve.brp`, `runtime_projection.brp`, `backend_projection.brp`.
- The callee's function type is lowered fresh at every call site:
  `CallExpr.callee_type_lowering` is 852,492 allocations, 33% of call
  lowering's budget. A memo by the callee's definition id was marked GO and
  not implemented, pending one check: whether `info.resolved_call`'s
  definition id is instantiation-specific.
- `Dict[String, ...]` counts: typecheck 122, core 180, lowering 53, backend
  38 (463 total). Rendered *types* are never dictionary keys outside trait
  dispatch; rendered *names* are, everywhere.

**Names.** The lexer interns token texts (`LexResult.texts`, 84,531 distinct
of 1,746,333 tokens, `2c171a5d`), and because `interned_text` returns the
table element, same-spelled identifiers in one file already share a `String`
allocation. Interning stops at `ParsedIdentifier { text: String, span }`.
The typechecker interns again into `SourceNameId` (5 files, 31 uses, never
leaves stage 06). `DefinitionId` reaches 23 files and `CoreVar.def_id` is
read at 362 sites, so definition identity does flow; the published
definition *table* (T5) is parked at +11% instructions because it was built
inside the per-module lowering loop.

**Negative evidence that shapes the order.** T-A (dense name-keyed authority
tables) and the `SourceNameId` bucket conversion were measured at zero
allocation change and reverted; the doc's conclusion "dictionary probes do
not allocate" stands. So name keys are a cleanliness and instruction item,
not an allocation lever, and they come last here.

**Concurrency.** The compile pipeline is sequential (no `List.concurrent`, no
tasks in stages 06 to 10). One table per compilation needs no lock. The LSP
runs analyses on immutable snapshots, so a table lives with the snapshot.

**Rendering oracles.** 860 typecheck diagnostic fixtures pin `type_to_string`
output; the `type_name` intrinsic makes `core_type_to_string` user-visible;
mangled names appear in generated C; `test_immutable_sharing.brp` pins
allocation ceilings on shared type fixtures and will need its numbers
updated by any step here.

## Measurement

Same rules as `CORE_NODE_TABLE_ROADMAP.md`: frozen input, three samples for
instructions, byte-identical C for every step in this roadmap (none of them
changes what is emitted; a step that changes mangled names would be a
different roadmap), stage-2 build for instruction claims, instrumentation
allocation-neutral with the flag off. Rows to watch: `typed_frontend_complete`
(36.9M), `core_lowering_complete` (18.0M), `pass_mono_complete` (16.6M),
`pass_trait_resolve_complete` (3.3M).

## Steps

| step | what lands | expected effect | parallel with |
| --- | --- | --- | --- |
| I1 | identity-preserving substitution and qualification (`apply_subst*`, `qualify_module_local_types`, mono `apply_type_substitution*`, `split_canonical_module_type_name` without the tuple) | typed frontend -1.5M to -2.5M; mono -1M to -2M | everything |
| I2 | mono request dedup by dictionary; callee function type memoized by definition id | lowering -0.8M; mono instructions -1% to -2% | everything |
| I3 | `CoreTypeTable`: hash-consed `CoreType` rows built by lowering and extended by mono; `core_type_equal` and `core_mono_type_equal` short-circuit on identity | lowering -1.2M (1.27M constructions become 22k); mono substitution shares rows; instructions -1% to -2% | N1 to N4 of the node roadmap |
| I4 | `SemanticType` interned at its hot producers (`localize`, `qualify`, `apply_subst`, unify's rebuilds) | typed frontend -2M to -4M | I3 |
| I5 | trait dispatch keyed by type id; `Dict[String, BackendTypeNaming]` and `CoreLayoutTypeIndex` keyed by type id | trait resolve instructions -10% to -20% of its row; allocations flat | after I3 |
| I6 | name ids: `ParsedIdentifier` carries the lexer's id; `SourceNameTable` becomes a view of the lexer table; `CoreVar.name` becomes a name id with the spelling in one table | allocations flat (per T-A); `blorp_string_eq` samples down; unlocks `CoreVar` as a struct (S4) | after CORE_ID_MIGRATION step 6 |
| I7 | definition table built once after lowering (T5 as re-specified), consumers converted one at a time | instructions -1% to -3%; the parked +11% must not recur | after I3 |

### I1: substitution that returns its input

**Context.** The four functions above rebuild unconditionally; the three
that were converted this week each paid back about 1% of total allocations.
`split_canonical_module_type_name` allocates a tuple for two substrings on
every call.

**Change.** The same shape the landed conversions use: compute the children,
compare each with `same_object`, return the input when all match.

```
-- before (semantic_type.brp, apply_subst_with_visited)
SemanticNamedType(name, args):
	SemanticNamedType(name, apply_subst_list(subst, args, visited))

-- after
SemanticNamedType(name, args):
	next_args: List[SemanticType] = apply_subst_list_or_same(subst, args, visited)
	if same_object(next_args, args): typ
	else: SemanticNamedType(name, next_args)
```

`qualify_module_local_types` drops the closure in favour of a direct loop with
an accumulator that is only started when a child changes (the "copy the
untouched prefix once" pattern from `60a66556`). `split_canonical_module_type_name`
returns a struct of two `Int` split offsets and lets the two callers take the
substrings they need, or returns the two strings without the tuple through a
small record only where both are consumed.

**Expected ROI.** Typed frontend -1.5M to -2.5M (of 36.9M); mono -1M to -2M
(of 16.6M). Per-function numbers come from
`benchmarks/results/typecheck_body_helper_allocations_O2_2026-09-22.md`.

**Risks.** None structural. Watch `test_immutable_sharing.brp` ceilings.

**Oracle.** Byte-identical C; typecheck and mono suites; diagnostic fixtures.

### I2: dictionaries where lists are scanned; memo the callee type

**Context.** `request_is_generated` is quadratic in the number of mono
requests (thousands on the self-compile). The callee type re-lowering is the
largest single approved-but-unstarted cut in lowering.

**Change.** A `Dict[String, Int]` from mangled name to request index alongside
the request list (the mangled name stays the key until I3 provides type ids;
that is a string probe, which does not allocate, and it removes the scan).
For the callee memo, first verify the open question with a test that
instantiates one generic at two types and asserts `info.resolved_call`
yields distinct ids; if it does, memoize `core_lower_value_type(callee_type)`
in a `Dict[Int, CoreType]` keyed by that id in the lowering context; if it
does not, key by `(def_id, lowered argument types)` after I3.

**Expected ROI.** Lowering -0.8M allocations; mono instructions -1% to -2%
from the removed scan (measure on stage 2).

**Risks.** The memo's correctness hinges on the verification above; the
report must include the test.

**Oracle.** Byte-identical C.

### I3: the Core type table

**Context.** 1.27M `CoreType` constructions for 22k shapes; two structural
equalities with 176 call sites; mono substitution rebuilding type trees per
instantiation.

**Change.** Intern at construction, without changing the `CoreType` type
itself in this step. A `CoreTypeTable` built by lowering as a local
accumulator and published on `CoreProgram`; every constructor call in type
lowering goes through `intern_core_type(table, typ)`, which returns the
existing row's allocation when a structurally equal type exists:

```
record CoreTypeTable {
	rows: List[CoreType],           -- row index is the type id
	by_shape: Dict[String, Int]     -- transitional: shape key -> row; replaced by a structural hash in I3b
}

pure func intern_core_type(table: CoreTypeTable, typ: CoreType) -> (CoreTypeTable, CoreType)
```

Because interned types are shared allocations, `core_type_equal` and
`core_mono_type_equal` gain the `same_object` short-circuit and their
structural fallback stays for the rare uninterned type. Mono's
`apply_type_substitution` interns its results, so instantiations that
produce the same concrete type share one row. A second commit (I3b) replaces
the shape-string key with a hash over the children's ids, since after
interning a type's identity is its children's identities plus its head.

The `CoreTypeId` becomes a first-class handle only in N5 of the node roadmap,
when expressions start carrying it; this step delivers the sharing and the
short-circuits with no representation change.

**Expected ROI.** Lowering -1.2M allocations; mono -1M to -3M from shared
substitution results; instructions -1% to -2% from the equality
short-circuits (176 sites, many in hot synth and invariant paths).

**Risks.** The transitional shape key renders types to strings, which is the
exact instrumentation trap recorded in the attribution report; it must be
replaced in I3b before the step is called done, and the I3 report must show
the rendering cost is below the savings or go straight to the hash.
`normalize_dim` differences between the two equalities must be resolved
before interning, or the table will hold two rows that one equality
considers equal.

**Oracle.** Byte-identical C; `test_core_mono*.brp`, `test_core_specialize*.brp`,
`test_core_trait_resolve.brp`.

### I4: interned semantic types

**Context.** The same pattern one stage earlier: `localize_module_types`
(828,488 calls), `resolve_alias_seen` (1.5M), unify's rebuilds. After I1 many
of these return their input; the remainder construct.

**Change.** A `SemanticTypeTable` on the typecheck `Context` (which already
carries the meta solver and counters), interning at the producers above.
Metas are excluded (they are mutable slots by design). The six scalar
constants are the first six rows.

**Expected ROI.** Typed frontend -2M to -4M.

**Risks.** `types_equal` distinguishes meta sessions; the table must never
intern a type containing a meta. `test_type.brp` pins that two sessions with
the same slot stay unequal.

**Oracle.** Byte-identical C; 860 diagnostic fixtures; typed-AST JSON tests.

### I5: dispatch and layout keyed by type id

**Context.** `core_trait_impl_type_key` renders a type per lookup;
`CoreLayoutTypeIndex` and `BackendTypeNaming` key by type name.

**Change.** With I3's table, the key is the row index. Delete the rendering
helpers. Per the frontend roadmap's working agreement, convert every lookup
on a data source in one task and grep for stragglers.

**Expected ROI.** Instructions in `pass_trait_resolve`, `pass_resolve_callables`
and the backend naming lookups; allocations flat. Report samples of
`blorp_string_eq` and `blorp_dict_hash_string` before and after.

**Oracle.** Byte-identical C (the key is internal; mangled names unchanged).

### I6: names as ids

**Context.** Interning exists at the lexer and again in the typechecker;
`ParsedIdentifier` and `CoreVar.name` are strings between and after. The
measured allocation effect of name-id keys is zero; the reasons to do it are
instruction count, cleanliness, and enabling `CoreVar` to become a struct
(`STRUCT_PAYLOAD_ROADMAP.md` S4), which needs `{ name_id: Int, id: Int,
def_id: Int }`.

**Change.** T3 completed: `ParsedIdentifier { name: NameId, span }` with the
text reachable through the compilation's name table; `SourceNameTable`
becomes a pass-through view; `CoreVar.name` becomes `NameId` and the C
emitter reads the spelling from the table (this is `CORE_ID_MIGRATION.md`
step 6's "spellings in one table", so do it as that step or right after it).
The formatter is the strongest oracle for the parser half.

**Expected ROI.** Allocations flat; `blorp_string_eq` samples down; the
enabling effect is S4's.

**Risks.** Hygiene (same-named locals differ by `id`, not by name);
diagnostics render through the table; the name table must be per
compilation and append-only for the LSP's incremental reparse.

**Oracle.** Byte-identical C; `bin/blorp format --check` clean on the whole
tree; diagnostic fixtures.

### I7: the definition table, built once

**Context.** T5 parked at +11% because the table was built in the per-module
loop and made `decls` non-unique. `441f568a` showed the consumer side pays
(DCE indexes by definition id: instructions -0.32%).

**Change.** Build `DefinitionTable` once after lowering from the final
`decls` (ids only, per the node roadmap's rule), publish it on
`CorePassState` next to `CoreProgramFacts` (N4 of the node roadmap shares the
record), and convert consumers one per commit: mono's
`collect_generic_functions`, DCE roots, Perceus `build_env`'s callable index.

**Expected ROI.** Instructions -1% to -3%. Go/no-go: each consumer's pass
row must not rise.

**Oracle.** Byte-identical C.

## Parallelism

I1, I2 and I3 touch different files from each other (`semantic_type.brp`;
`mono_specialize.brp` and `lower.brp`'s call lowering; `lower.brp`'s type
lowering, `ir.brp` equality, `mono.brp` substitution) and can run as three
workers at once. I4 follows I1 in the same files. I5 and I7 follow I3. I6
waits for `CORE_ID_MIGRATION.md` step 6. None of these touch union layout or
`CoreSourceLoc`, so the two companion roadmaps run alongside. The one shared
seam is `ir.brp`: this roadmap edits `core_type_equal` and later adds the
type table field; the node roadmap edits `CoreSourceLoc` and `CoreProgram`.
Both are additive; merge main before every gate run.

## Not in this roadmap

Changing `type_to_string` output, mangled names, or anything that alters
generated C; the LSP's own symbol tables; parser cursor work (T7b).
