# Struct payload and erased union census (S0)

Date: 2026-09-23. Read-only measurement pass for
[`docs/STRUCT_PAYLOAD_ROADMAP.md`](../../docs/STRUCT_PAYLOAD_ROADMAP.md) step
S0. No compiler source changes in this commit.

Compiler commit: `53f5e73cc620` (`origin/main`, clean). `bin/blorp --version`:
`target: aarch64-apple-darwin`, `cc: Apple clang version 21.0.0
(clang-2100.3.34.2)`, `optimization: cli=-O0 runtime=-O2`, 8-way split;
`scripts/compiler-build-status` reports FRESH. `-O0` is the CLI's own build
level (fast edit-loop link); it does not change what C the compiler emits,
only how fast the compiler itself runs, so it does not affect any count
below.

## What this decides

- **S1 reach (struct + fieldless-enum fields get typed storage): 8 of 532
  source unions** are fully unlocked — every non-scalar field across every
  variant is a `struct` or a fieldless `enum`, so extending
  `source_union_typed_payload_field_supported` to accept those two kinds
  (as S1 proposes) removes every remaining blocker for `CliTestCandidateProgress`,
  `ExpectedValueSlotContext`, `ResourceArgPolicy`, `TypeWideningReason`,
  `Intrinsic`, `OwnershipContractViolation`, `CoreForeignDefaultArgPolicy`,
  `CtfeBodyWorklistFallback`. Small on its own, as the roadmap expects; its
  value is unlocking S4.
- **S2 reach (also accept record, union, `String`, list/dict/set, function,
  tuple, tensor, `Bytes` fields, matching the mono path): 352 of 532 source
  unions (71% of the 495 non-generic erased unions)** become fully typed,
  cumulative with S1's 8. This includes `CoreExpr` (89 variants), every IR
  type mentioned in the roadmap (`SemanticType`, `ParsedExpr`, `TypedExpr`),
  and 8 generic unions' concrete monomorphizations are unaffected either way
  (already typed by `mono_data.brp`).
- **S2 risk / residual gap: 143 unions (29%) still erased after both S1 and
  S2 as scoped.** All but 3 of these are blocked purely by an **opaque
  type** field (`opaque type X = Rep`) — 182 opaque-field instances across
  143 unions, of which 25 fields resolve to `Int` and 15 to `String`
  underneath the wrapper. Neither S1 nor S2's predicate (which matches on
  the field's own `SemanticNamedType` name, not what an opaque type
  unwraps to) reaches these; a union with an `AnalysisPurpose`- or
  `DocumentUri`-shaped ID field stays erased even though the payload is
  really a scalar. This is a real gap in the roadmap's S1/S2 scoping worth
  flagging to whoever picks up S2 — it is the single largest reason S2 does
  not reach "most of the IR" as S0's own pre-estimate expected (some
  compiler-internal IR unions clear this bar, but a large share of the
  LSP/typecheck-authority unions do not, because they are built from opaque
  ID/table wrappers). On the runtime side, the risk list the roadmap asked
  S0 to audit turned out to be short: the leak checker's live-object
  summary reads only `type_tag`/`alloc_size`/`refcount`, never a union
  payload field, and the fallible-stream `Option`-macro operates on the
  stream's own generic `void*` pull() protocol, a different erasure
  boundary from source-union payload storage. No genuine "walks a union
  payload as `void*`" runtime helper was found; the real S2 risk surface is
  the emitter (`match_projection.brp`/`emit.brp` release-policy derivation
  and destructor emission for recursive unions), not `runtime.c`.

## Method

1. `make` (`-O0` CLI link); `bin/blorp --version` and
   `scripts/compiler-build-status` confirmed FRESH.
2. `benchmarks/self_compile_measure --input-rev
   0c2e104331a224226088519bb0509c00b9ac0b70 --keep-output
   /tmp/s0_census_self.c --samples 1 --output /tmp/s0_census_measure.json`
   — the self-compile C this census reads. **112,905,985 bytes, 1,231,638
   lines.** Total allocations for the run: 183,621,914 (no counter in this
   output or in `BLORP_COMPILER_MEMORY_PROFILE` attributes allocations to
   `blorp_box_struct` or union construction specifically — see the Dynamic
   weight section).
3. Union declarations: `grep -rnE
   "^\s*(private |pub |public )?union [A-Za-z]" blorp/src standard_library/src`
   found 539 lines; a small Python parser (kept in
   `/tmp/s0census_scripts/` for this run, not committed) filtered 4 doc-text
   false positives ("...union gets...", "...union call site...", "...union
   destroy...", "...union cannot be retained...") and parsed variant field
   lists for the remaining **532 source unions**, classifying each field by
   name against the compiler's own struct (136), record (1,534), enum
   (256), and union (532) declaration lists, its 207 `opaque type` aliases
   (resolved transitively to their representation type) and 10 `type
   alias` declarations (resolved transparently, since aliases are
   substituted before this predicate runs and opaque types are not). This
   reproduces `source_union_typed_payload_field_supported`
   (`lower.brp:5939`) and `lower_union_payload_storage` (`lower.brp:5973`)
   by name-matching rather than by re-running the compiler's own type
   checker, so a handful of edge cases (one union path through a
   re-exported `type alias`, `StoredDefinitionTable`) fell back to
   "unknown" and are called out individually rather than silently
   miscounted.
4. Pattern counts: `grep -c` / `grep -o | wc -l` for single-token C patterns
   against `/tmp/s0_census_self.c`; `grep -oFf` with a wordlist of the 2,480
   distinct variant names belonging to erased unions, for the "most
   construction sites" ranking (see caveat below).
5. Runtime audit: manual read of
   `blorp/src/lib/runtime/native/runtime.c` around the leak checker
   (`__blorp_collect_live_object_types`, `__blorp_print_live_object_type_summary`,
   ~line 3010-3060 and 38997-39008) and the fallible-stream `Option` macro
   (`BLORP_DEFINE_FALLIBLE_STREAM_FIND_STACK_OPTION`, ~line 32468); grepped
   for `foreign`/JSON-dump code reading union payloads generically (none
   found at the line numbers named in the task brief — the file has grown
   since those were noted, and no equivalent code exists today).

Caveat on the "most construction sites" ranking (item below): emitted C
mangles every constructor with a per-module path prefix and (for union
variants) a `def_id`, so a plain source variant name almost never appears
literally in the C except as a *substring* inside its case label, its
`__def_NNN_Name(` constructor, its `_destroy` accessor text, and any local
identifier that happens to end in that text. The wordlist match here counts
all of those together — it is a relative, order-of-magnitude ranking, not a
precise call-site count, exactly as the reference
`emitted_c_pattern_census_2026-09-23.md` census disclosed for its own
"identifiers" category. 35 of 2,480 variant names are reused across more
than one union (e.g. `Ok`, `Some`, `CliError`); their occurrence counts were
split evenly across the owning unions rather than dropped, which slightly
smooths the ranking for unions built from generic/common variant names.

## 1. Union storage census

| | count |
| --- | ---: |
| Source-declared unions (blorp/src + standard_library/src) | 532 |
| Generic (has type parameters) — always erased at the source level | 8 |
| Already `TypedUnionPayloadStorage` today | 29 |
| `ErasedUnionPayloadStorage` today | 503 |
| — of which erased purely by generic type params (fields otherwise typed-eligible) | 0 (all 8 generic unions also have a non-scalar/type-param field) |
| — of which name-erased regardless of fields (`RecvAttempt`) | 1 |
| — of which erased by a field type | 502 |

The 8 generic unions are `Option`, `Result`, `ParseResult`,
`SemanticQueryResult`, `ProtocolInputOutcome`, `ProtocolResponse`,
`CoreCollectionEligibility`, `RecvAttempt`. Their monomorphized
instantiations are already typed by `mono_data.brp:861`, per the roadmap.

### Blocking category, first non-scalar field found per erased union

Scanning each erased union's variants and fields in declaration order and
reporting the first field whose type is not one of the accepted scalars:

| blocking category | unions |
| --- | ---: |
| String | 136 |
| record (heap record) | 118 |
| union | 104 |
| list/dict/set | 30 |
| opaque type (wraps `Int`) | 25 |
| opaque type (wraps `String`) | 15 |
| fieldless enum | 14 |
| type parameter | 6 |
| `Bytes` | 4 |
| opaque type, other representations (one union each unless noted; `ResolvedModuleIdentityRep` x5, `ModuleViewRep` x4, several x2) | ~59 total across ~50 distinct wrapped types |
| struct (`ValueRecordType`) | 1 |
| unknown (`StoredDefinitionTable`, an imported-name alias edge case) | 1 |
| name-erased (`RecvAttempt`) | 1 |

Total: 503, matching the erased count above (502 field-blocked + 1
name-erased).

### Full-reach counts (every non-scalar field checked, not just the first)

This is the number that actually sizes S1 and S2, since a union can have a
struct field *and* a `String` field — S1 alone would not unlock it.

| step | predicate adds | non-generic unions fully unlocked |
| --- | --- | ---: |
| S1 | struct, fieldless enum | 8 |
| S1+S2 | + record, union, `String`, list/dict/set, function, tuple, tensor, `Bytes` | 352 |
| remaining after S1+S2 | — | 143 |

(495 = 532 total − 8 generic − 29 already-typed is the non-generic erased
population these percentages are against.)

### Twenty erased unions with the most emitted construction sites

Wordlist-match ranking (see caveat above), against the 2,480 distinct
variant names belonging to the 503 erased unions:

| rank | union | occurrences (proxy) |
| ---: | --- | ---: |
| 1 | `CliAction` | 4,602 |
| 2 | `CoreExpr` | 2,887 |
| 3 | `JsonValue` | 1,439 |
| 4 | `CliPackageAction` | 1,020 |
| 5 | `Result` (generic; mono instantiations typed) | 945 |
| 6 | `Option` (generic; mono instantiations typed) | 805 |
| 7 | `SemanticType` | 404 |
| 8 | `ParsedExpr` | 389 |
| 9 | `TypedExpr` | 383 |
| 10 | `PreparedBackendOp` | 327 |
| 11 | `Intrinsic` | 314 |
| 12 | `PreparedTensorOp` | 254 |
| 13 | `CoreDecl` | 218 |
| 14 | `CtfeEvalError` | 210 |
| 15 | `Expression` | 205 |
| 16 | `ProtocolInputOutcome` (generic; mono typed) | 175 |
| 17 | `PreparedListOp` | 167 |
| 18 | `CoreType` | 165 |
| 19 | `CoreLowerError` | 163 |
| 20 | `Value` | 152 |

`CoreExpr` at rank 2 is the roadmap's primary S2 target and matches
expectations; `CliAction`/`JsonValue`/`CliPackageAction` ranking above it
reflects both genuinely high constructor traffic in the CLI/JSON paths and
this ranking's shared-variant-name smoothing (several of `CliAction`'s 19
variant names, e.g. `CliError`/`CliPackage`/`CliCheck`, are reused by other
small CLI-adjacent unions).

## 2. Read and write shape counts in the emitted C

| pattern | occurrences |
| --- | ---: |
| `(void*)(long)(` — erased scalar payload write-side box (roadmap's `(void*)(intptr_t)`; actual emitted form is `(void*)(long)`) | 3,816 |
| total `(long)` casts (write-side boxes + read-side unboxes + unrelated, e.g. the string-byte-index cast) | 11,521 |
| — read-side/other `(long)` casts (total minus the 3,816 write-side boxes above; includes `PrimUnbox`'s `((TYPE)(long)value)` reads) | ~7,705 |
| `->data.` variant field accesses, typed and erased combined (`VariantFieldAccessor` and `ErasedVariantFieldAccessor` emit textually identical `->data.Ctor.fieldN` raw access; only `ErasedVariantFieldAccessor` wraps the result in an extra unbox cast — see `match_projection.brp`/`emit.brp:17825-17920`) | 48,382 |
| `release_mask` — total occurrences | 21,148 |
| `release_mask` — struct field declarations (`unsigned long release_mask`) | 4,147 |
| `release_mask` — assignments (writes) | 8,081 |
| `release_mask` — bitwise-`&` reads | 2,973 |
| `->release_mask` specifically | 6,954 |
| `blorp_box_struct(` calls | 247 |
| `blorp_unbox_struct(` calls | 32 |

`VariantFieldAccessor` and `ErasedVariantFieldAccessor` (`match_projection.brp:16,25`)
emit the *same* raw C text for a variant field read
(`emit_match_accessor`, `emit.brp:17825`); the erased form is distinguished
only downstream, by `match_accessor_value_source` (`emit.brp:17886`)
wrapping the erased read in `boxed_storage_value_source` — a `PrimUnbox`
`((TYPE)(long)value)` cast, a `PointerUnbox` `((TYPE*)value)` cast, or
`blorp_unbox_struct(value, TYPE)` for a boxed struct. So there is no
separate C token that means "this was an `ErasedVariantFieldAccessor`" —
the cast forms counted above are the only textual signal.

### `blorp_box_struct` by boxed type (top entries, via `sizeof(...)`)

| boxed type | calls |
| --- | ---: |
| `blorp_StackOption_Int` | 147 |
| `blorp_StackOption_Bool` | 14 |
| `blorp_StackOption_CliSanitizerMode` | 9 |
| `json::JsonScanner` | 6 |
| `TraitMethodIdRep` | 6 |
| `blorp_StackOption_ImplMethodTarget` | 4 |
| `ProtocolPosition` | 4 |
| `AcceptedUnionConstructorLocator` | 4 |
| (long tail: ~15 more types at 1-3 calls each) | ~50 |

`blorp_StackOption_Int` at 147 is up from the roadmap's stale count of 82
(2026-09-16), consistent with the compiler having grown roughly 12-17% in
that window per other 2026-09 census reports. The roadmap's stale total of
137 `blorp_box_struct` calls is now **247**.

## 3. Runtime helpers audited for erased-slot assumptions

| site | what it reads | at risk under S1/S2? |
| --- | --- | --- |
| `__blorp_collect_live_object_types` / `__blorp_print_live_object_type_summary` (`runtime.c` ~3010-3060, called from `__blorp_leak_report` ~3062 and `blorp_print_live_object_summary` ~38997) | `meta->type_tag`, `meta->alloc_size`, `obj->refcount` — object-header metadata only | No. Never touches a union's payload fields. |
| `BLORP_DEFINE_FALLIBLE_STREAM_FIND_STACK_OPTION` macro (`runtime.c` ~32468), instantiated for `Int`/`Int8`/`Int16`/`Int32`/`Int64`/`UInt8..64`/`Float`/`Float32`/`Float16`/`Bool`/`Char` | `found.value`, a generic `void*` from `FallibleStream`'s own `pull()` protocol, unboxed via `blorp_channel_unbox_*` and repacked into a `blorp_StackOption_*` (already-typed, mono-generated) | No, directly — this is a different erasure boundary (the stream's `void*` transport protocol), independent of source-union payload storage. It is worth re-confirming after S2 lands only if `Option`'s own mono layout changes, which S1/S2 as scoped do not touch. |
| JSON-dump-of-union-payload / foreign-marshalling code reading union payloads generically as `void*` | — | Not found. No such generic walker exists in the current `runtime.c` (44,886 lines); grepping for `foreign` and JSON-dump code near the previously-noted line numbers (~29932, ~32548) turned up unrelated tensor-map and stream code — those line numbers have drifted as the file grew and no equivalent payload-generic helper was found elsewhere. |

Net: the roadmap's S2 risk item ("the runtime's generic union helpers …
must not assume `void*` slots") did not turn up a concrete hit in
`runtime.c`. The real risk surface for S2 is in the compiler's own emitter
(`match_projection.brp` accessor construction, `emit.brp`'s release-policy
derivation and the recursive-union iterative destructor worklist, 38
`blorp_union_destroy_stack_grow(` call sites) — code that already knows
about `TypedUnionPayloadStorage` because monomorphized generics use it
today, so this is a widen-the-existing-path change, not new code.

## 4. Dynamic weight

No available counter attributes allocations to `blorp_box_struct` or union
construction specifically:

- `self_compile_measure`'s allocation counters (from
  `/tmp/s0_census_measure.json`) are per-pass (`pass_perceus_complete`,
  `pass_mono_complete`, etc.), not per-construct-type.
- `BLORP_COMPILER_MEMORY_PROFILE=1` (documented at `runtime.c:1416` and
  around the pool-slab-limit comments at `runtime.c:3255-3300`) reports
  per-size-class pool slab high-water marks, not per-call-site or
  per-type-tag allocation attribution.

What follows is **static only**: 247 `blorp_box_struct` call *sites* and
3,816 write-side `(void*)(long)(` cast occurrences in the emitted C. Turning
either into a per-self-compile *execution* count would need per-node
execution profiling (the `compiler_exact_profile_recipe.md` workflow, a
profiled stage-2 build) which is out of scope for this bounded census; the
self-compile's total allocation count for scale is 183,621,914. Anyone
picking up S2 who wants a real instructions/allocations estimate should run
that profiling rather than trust an extrapolation from these static counts.

## 5. Candidate structs (roadmap S4 table)

| type | construction sites in emitted self-compile C | lives in these union payloads today |
| --- | ---: | --- |
| `CoreVar` | 71 (`__CoreVar_make(` calls, 72 occurrences minus 1 definition) | `CoreExpr` (`VarExpr`, `AssignExpr`, `DupExpr`, `DropExpr`, `LetExpr`, `BorrowLetExpr`), `CoreImportedVariableResolution`, `CoreRetainPolicy` (`CowFieldTakeRetainPolicy`), `CoreSsaBodyStep`, `TensorReadMode`, `CancellationOwnerIdentity`, and ~10 Perceus-internal frame-stack unions (`PerceusOwnershipSummaryFrameStack`, `PerceusInsertBindingFrameStack`, `PerceusLambdaNormalizeFrameStack`, each with several variants carrying a `CoreVar`) |
| `SourceSpan` | 5 (`__SourceSpan_make(`, 6 minus 1 definition) | `PositionMappingError` (`SpanOutsideDocument`, `SpanSourceMismatch`) — an LSP-only union, not `CoreSourceLoc`/`CoreExpr` |
| `CoreParam` | 42 (`__CoreParam_make(`, 43 minus 1 definition) | none directly as a bare union-variant field; only reached via `List[CoreParam]` fields on `CoreExpr`'s `LambdaExpr` and `TailrecLoopExpr`, which is a list-element concern (S5), not a union-payload one |
| `CoreLowerScopeEntry` | 0 — the type does not appear anywhere in this self-compile's emitted C | none as a union-variant field |

`CoreLowerScopeEntry` producing zero hits is worth a flag rather than a
silent zero: `lower.brp:508`'s docstring describes it as a hot per-scope-push
record, so its total absence from the emitted C for this specific frozen
input means either the compile of `blorp/src/main.brp` never reaches a code
path that pushes a lowering scope entry for this input, or the record gets
fully eliminated (SROA/DCE) before reaching C emission for every call site
exercised here. Either way, this census's allocation-count claim for it is
"not observed," not "zero" — it should be re-measured on a call path known
to exercise `push_local_scope` before anyone sizes S4's `CoreLowerScopeEntry`
row from this report.

No allocation counts from `core_lowering_allocation_attribution_2026-09-22.md`
were available broken out per these four exact record types (that report's
detail is at the pass level and around specific tuple/`Option[Int]` boxing
fixes, not a per-record-type histogram), so allocation counts above are
construction-site counts only, not allocation counts; `CoreVar`'s roadmap
figure of "349k allocations in lowering" comes from that separate report,
not from this one, and the two are not directly comparable (this census's
71 is call-*site* count in the emitted C text, not a dynamic execution
count — see the Dynamic weight caveat above, which applies here too).

## Commands run

```
make
bin/blorp --version
scripts/compiler-build-status
benchmarks/self_compile_measure --input-rev 0c2e104331a224226088519bb0509c00b9ac0b70 \
  --keep-output /tmp/s0_census_self.c --samples 1 --output /tmp/s0_census_measure.json

grep -rnE '^\s*(private |pub |public )?union [A-Za-z]' blorp/src standard_library/src
grep -rhoE '^(pub |public )?opaque type [A-Za-z_][A-Za-z0-9_]* = [A-Za-z_][A-Za-z0-9_]*' blorp/src standard_library/src
grep -rhoE '^(pub |public )?type alias [A-Za-z_][A-Za-z0-9_]* = [A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?' blorp/src standard_library/src

grep -c '(void\*)(long)(' /tmp/s0_census_self.c
grep -o '(long)' /tmp/s0_census_self.c | wc -l
grep -o -- '->data\.' /tmp/s0_census_self.c | wc -l
grep -o 'release_mask' /tmp/s0_census_self.c | wc -l
grep -oE 'release_mask = [^;]+;' /tmp/s0_census_self.c | wc -l
grep -oE 'release_mask & ' /tmp/s0_census_self.c | wc -l
grep -o -- '->release_mask' /tmp/s0_census_self.c | wc -l
grep -o 'blorp_box_struct(' /tmp/s0_census_self.c | wc -l
grep -oE 'blorp_box_struct\([^;]*sizeof\([A-Za-z_][A-Za-z0-9_ ]*\)\)' /tmp/s0_census_self.c \
  | grep -oE 'sizeof\([A-Za-z_][A-Za-z0-9_ ]*\)' | sort | uniq -c | sort -rn
grep -o 'blorp_unbox_struct(' /tmp/s0_census_self.c | wc -l
```

(The union parsing, classification, and wordlist construction-site ranking
used small Python scripts kept in `/tmp/s0census_scripts/` for this run,
not committed, in the same spirit as the reference
`emitted_c_pattern_census_2026-09-23.md` census's shell-history-only
scripts.)
