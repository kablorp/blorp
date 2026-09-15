# Step 4A: Session-Owned Meta Identity Boundary

**Status:** The dimension-factor prerequisite is implemented in
[packet 140](140-step4a-typed-exceptional-dimension-factors.md). Nominal,
session-owned `MetaId` is not yet implemented.

## Why the next cut needs a representation change

`SemanticMetaType(Int)` is currently interpreted against whichever
`Context.solver` receives it. Each independently reconstructed context starts
issuing at index zero. Passing a meta from one such context to another can
therefore make an unrelated binding appear to resolve it. The opaque solver
and fail-closed unissued-index checks from earlier packets prevent many bad
states, but they cannot distinguish two *issued* index-zero metas.

A temporary, test-only probe demonstrated this precise failure. It called
`fresh_meta(CONTEXT_EMPTY)` twice, bound index zero in the second context, and
asked whether the first meta stayed unresolved in that second context. The
assertion failed. This is an internal cross-session safety boundary, not a
claim that normal source programs currently exchange metas between bodies.

The dimension solver was a second dependency. Before packet 140, its
canonical monomials stored every factor in `List[String]`: an unbound meta
became `"?m" + id`, and `dim_type_var`/`dim_meta_id_from_name` parsed the
prefix back into a meta. A temporary probe showed that nested opaque
division could equate a real `SemanticMetaType(1)` with
`SemanticTypeVar("?m1")`:

```blorp
left  = 1 + (SemanticMetaType(1) / 3)
right = 1 + (SemanticTypeVar("?m1") / 3)
-- Before packet 140, dim_solve([], left, right) incorrectly returned DimSolved.
```

The top-level addition sent each division through the old opaque canonical
fallback, which serialized factors using display text. The `?m1` spelling is
an internal constructed type-variable probe, not documented source syntax.
It exposes why merely tagging ordinary monomial factors is insufficient.

A prototype replaced normal dimension strings with typed meta/type-variable
factors and passed a direct spelling-collision test. Review found the nested
opaque-division collision above; the prototype also replaced stable factor-list
merge sort with append-heavy insertion sort without a representative dimension
cost screen. It was withdrawn in full. Packet 138's independently verified
binding-graph change remains; no half-normalized dimension representation is
left in production.

A second, fully structured dimension-factor prototype made non-exact division
carry canonical operands and passed ten focused solver tests, including the
two identity failures and a permutation of distinct factors with the same
display spelling. Its first eight-factor run allocated 2,129,920 objects. An
ordered-equality fast path lowered that to 1,183,744 but did not meet the
performance gate: the unchanged baseline uses 864,256 allocations/releases
for 4,096 solves (+37% in the optimized candidate). One warm direct pair
showed 1,147,267,408→1,577,175,905 retired instructions (+37.5%) and
1,048,864→1,081,632 B peak footprint (+3.1%); worker size grew
737,448→739,608 B. Both workers solved all 4,096 cases with zero retained
objects/bytes. The baseline and optimized candidate keys were
`64295d92f28f59f45b01af217be1bf1e82735994b03d6e4bb17f3e1b22a248de`
and `7e48cf3972c69a6ab02d0fb759a802536c9bf8165468c9d47f35ef6f522b5ca7`.
The cost was a property of this candidate's combined representation and
algorithms; no single allocation source was isolated. That rewrite and its
temporary failing tests were also withdrawn. The standalone factor-heavy
benchmark became packet 140's fast loop and now covers ordinary products,
multi-term merging, opaque divisions, and nested factors. Packet 141 adds
bind/stuck modes. The old measurements above record the rejected prototype,
not the current solver.

## Target representation and ownership

The remaining identity implementation should give a meta a nominal issuer plus dense slot:

```blorp
-- Shape, not a committed API.
opaque type MetaSessionId = MetaSessionIdRep
opaque type MetaId = MetaIdRep  -- { session: MetaSessionId, slot: Int }
union SemanticType:
    ...
    SemanticMetaType(MetaId)
```

The session key must be explicit and deterministic within one compilation,
not a process-global counter or a packed integer with an arbitrary range.
The body path already has a table-issued `CallableId` in `BodyCheckContext`;
module preparation has a `ModuleId`, and global initializer work has its own
issued definition identity. These IDs are table-local and need exact issuer
provenance; normal and CTFE rechecks of one callable also need distinct
purposes or invocation identities. Packet 141 inventories the constructor
boundaries and this missing contract. A reset must create or receive a new
session identity; clearing bindings while reusing the same issuer would allow
stale meta aliasing.

Packet 140 gives metas, non-exact division, and opaque fallback typed factor
identities while preserving the ordinary `List[String]` factor-sort path.
It removes `?mN` parsing inside the dimension solver, but its meta factor and
`DimBindMeta` still carry raw `Int`; both must move to `MetaId` with the
context solver. `type_to_string` remains display-only.

## Finite implementation strategy

1. Add the two failing regression cases as permanent tests, with diagnostics
   or typed outcomes checked precisely. Keep normal same-session binding and
   existing dimension equivalence tests alongside them.
2. Issue explicit session keys at every inference-context construction
   boundary. Validate that reverse/shuffled body schedules issue the same
   identities and diagnostics as source order.
3. Introduce nominal `MetaId` in `SemanticType` and the opaque solver, then
   convert `lookup_meta`, `bind_meta`, `occurs_meta`, unification, zonking, and
   dimension results together. Do not add a public raw-`Int` compatibility
   constructor for production callers.
4. ~~Replace dimension meta-name parsing with typed canonical factors, including
   structured opaque division identity.~~ Packet 140 completed this
   prerequisite. It documents the intentional exceptional-term reconstruction
   order and numeric singleton-meta binding order, with focused fixtures.
5. Measure focused meta/dimension workloads before broad integration. If the
   representation increases allocations, instructions, peak memory, or worker
   code size materially, reduce the payload/copy boundary before proceeding;
   do not retain a correctness-only rewrite with a large resource regression.

## Fast feedback and acceptance

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_dim_solver.brp
scripts/compiler-check --changed
bin/blorp test --sanitize --timeout 180 \
    blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp \
    blorp/test/compiler/stage_06_typecheck/type_system/test_dim_solver.brp
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
benchmarks/compiler_blorp_benchmark_runner \
    compiler-dim-canonical-factor-profile \
    blorp/benchmark/compiler/compiler_dim_canonical_factor_profile.brp \
    plain 8 4096
```

Use the retained dimension probe's ordinary, multi-term, opaque, nested, and
packet 141 bind/stuck modes, with setup outside the measured window; keep the
existing meta-resolution and binding-chain probes. Use a
small number of warm before/after pairs; compare allocation/release counts,
retired instructions, peak footprint, checksum/diagnostic order, and worker
size. Elapsed time is a confirmation signal only when stable enough to trust.

Acceptance requires distinct sessions' equal-numbered metas never alias;
issued/unissued and cycle checks still fail closed; dimension equivalence,
non-exact division, and opaque-expression distinctions remain sound;
accepted body/CTFE/Core products stay meta-free; and no material regression
appears in the focused or selected compilation guards.
