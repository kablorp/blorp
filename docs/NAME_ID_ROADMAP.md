# Name-to-Id Roadmap

Names in the compiler become ids. Two outcomes, two lanes:

- **Lane A, names to ids.** Every identifier's String content becomes its
  `NameId`, then an `Int`, passed along unchanged; spellings are looked up
  only where a human reads them. Every step is semantics-preserving and
  gated by byte-identical generated C.
- **Lane B, emission by id.** The emitter spells symbols from definition
  and binder ids instead of names, so the generated C shrinks. Steps change
  C by design and are gated by the codegen audit, the runtime and leak
  gates, and the normalized-C oracle showing that only spellings changed.

Measured facts that fix the order (all 2026-09-28):

- A spike that flipped `ParsedIdentifier.text` to the stringified id built
  the compiler, but the result could not typecheck hello world. Names are
  projected to plain Strings early and compared against literal
  vocabularies: typecheck 158 `==` sites and 231 `match` arms, CTFE 9/85,
  core lowering 123/8, Core passes 1,395/426, backend 179/12. The concrete
  walls are the builtin trait registry, the Equatable obligation checks, the
  ownership manifest, the builtin registry, the CTFE intrinsic table and the
  intrinsic/prelude type names. The compilation `NameTable` is reachable
  only during parsing, so nothing after parse can render a spelling. Lane A
  steps 1 to 5 are therefore prerequisites of the flip, not part of it.
- Mangled names do three jobs: Core identity (replaced by `def_id`, except
  that mono instantiations still share ids), classification by parsing
  (about 25 readers; replaced by an explicit origin attribute), and C
  spelling (replaced by symbol projection). Retiring mangling is Lane A
  step 3 and starts with instantiation-specific definition ids.
- Locals spelled from binder ids cut the self-compile C by 1.56%; variants
  spelled from definition ids cut it by 9.04%. About 402k binder
  occurrences still carry their synthetic spelling because their passes
  create them with id 0.

## Rules

- One landing at a time through `scripts/land` from the integration
  checkout; never set `BLORP_LEAK_TEST_TIMEOUT` there (a hygiene test pins
  the recorded environment).
- At most three workers; each brief cites one step below and owns the files
  that step lists. `emit.brp`, `lower.brp`, `infer.brp` and
  `match_projection.brp` have exactly one owner at a time.
- Lane A gate: `benchmarks/self_compile_measure --stage2 --require-identical`
  against a parent frozen at the branch base, self and `--program small`,
  plus the owning suites. Lane B gate: codegen audit with `EXPECT-C-REGEX`
  for projected families, `scripts/test runtime`, `scripts/test leak`,
  `benchmarks/normalize_generated_c_symbols --project-locals` identical,
  and emitted C bytes reported before and after.
- Replaced data is deleted in the same commit. A String that only carries
  what an id already carries does not survive the step that adds the id.
- Machinery cleanups that do not move a name to an id or shrink emission
  (CTFE `NameTable` plumbing beyond what Lane A needs, `ModuleId` in Core) wait until both
  lanes are done. Their censuses are kept in `benchmarks/results/`.

## Lane A: names to ids

| Step | What | Files | Gate | Status |
| --- | --- | --- | --- | --- |
| A0 | Compilation `NameTable`; `ParsedIdentifier.name: NameId`; holes and synthesized spellings interned; field identity `CoreFieldRef`; binder ids unified | stage_02_lex/name_table.brp, stage_03_parse, pipeline.brp, stage_09_core/ir.brp, pass_runner.brp | identical C | done (b6928bb0, 0b17137a, 8186f04c, 7792a130, aa5425ed4, 32307f0d) |
| A1 | Pinned `NameId` constants for the closed vocabulary; unseeded lookups fail loudly; the 43 literal `.text ==` compares use the constants; the compilation table is reachable from typecheck, Core input, `CorePassState`, the emission context, the formatter and the LSP through one boundary helper | name_table.brp, test_lexer.brp, infer.brp, lower.brp, decl.brp, typecheck result records, `CoreGraphUnit`, pass_runner.brp, format/projection.brp, lsp workspace records | identical C; typecheck fixtures unchanged; formatter idempotence | done (375d637a0) |
| A2 | Builtin vocabularies compared by id while the text is still real: trait registry (`type_system/builtins.brp`, 159 arms), Equatable obligations (`env.brp`), ownership manifest (`stage_09_core/ownership.brp`, 179 arms), builtin registry (97), CTFE intrinsics (74), `intrinsic_type`, `prelude_type` | those files; one worker per registry, disjoint | identical C; `scripts/test compiler-blorp` | after A1 |
| A3 | Retire magic spellings (expanded step by step in [`NAME_MANGLING_REMOVAL_ROADMAP.md`](NAME_MANGLING_REMOVAL_ROADMAP.md)): no reader learns a fact from the shape of a String. A3.0 census of every `starts_with`, `ends_with`, `split`, `parse_int` and literal-prefix concatenation on a name-like String, by file, with the record or enum that replaces it; a hygiene grep keeps the pattern from returning. A3.1 functions: every mono instantiation and synthesized function gets its own `def_id` (mono dedups by `(base, type_args)`; flatten's collision workaround goes), then `CoreFunction.origin` (`SourceFunction`, `ImplMethod`, `MonoInstance`, `PureVariant`, `UfcsWrapper`, `Synthesized(kind)`, `HoistedLambda`, `HoistedTask`, `EtaExpansion`, `StaticCallback`, `Entrypoint`, all payloads ids or types) replaces `mono_name_base`, `strip_pure_suffix`, the UFCS and module prefixes, the closure prefixes and the trait-method prefix; last commit deletes the producers and the name becomes display-only. A3.2 binders: a `CoreBinderOrigin` enum where Perceus and cleanup readers recognise their own temporaries by prefix today. A3.3 C type strings: payload `CoreType` rendered at emission replaces `blorp_StackOption_*`, inline-struct and boxed-element spellings and the three `resolved_*` parsers (census in the T6 report; `blorp_StackResult` is an ABI constant and stays) | mono.brp, mono_data.brp, synth_name.brp, the synth_* passes, closure.brp, resolve.brp, std_inline.brp, collection_plan.brp, string_pipeline.brp, flatten.brp, runtime_projection.brp, perceus/*, c_type_layout.brp, list_layout.brp, prepare.brp, emit.brp | identical C at every commit | A3.0 now; A3.1 after B1 and B2 land; A3.2 after B1; A3.3 after B2 |
| A1b | Parser-minted binder ids: the parser gives every binder a per-module counter id carried on the pattern node, replacing lowering's span-derived positive ids, so ids are stable across unrelated edits and fixtures can pin them | stage_03_parse/parsed_ast.brp, language_parser.brp, lower.brp binder sites | identical C up to local spellings (normalized oracle identical); audit fixtures | after A1 |
| A4 | Boundaries render through the table: diagnostics, `type_to_string`, formatter, LSP hover and completion, `--dump-core` and AST JSON, `type_name` metadata | stage_06 diagnostics, format/projection.brp, lsp, ir.brp JSON, type_name_metadata.brp | identical C; the 860 `should_fail` messages unchanged; formatter idempotence | after A1 |
| A5 | Flip `ParsedIdentifier.text` to the stringified id and delete `.text` readers; then String to `Int` one record family per commit (`CoreVar.name`, function names, field and variant spellings, type names) | frontend and Core records | identical C | after A2, A3, A4 |

## Lane B: emission by id

| Step | What | Files | Gate | Status |
| --- | --- | --- | --- | --- |
| B0 | Callables and types projected to short symbols; locals with a binder id spelled `brp_v_<id>` / `brp_vn_<id>` | c_symbol_projection.brp, c_naming.brp, emit.brp | audit, oracle | done (f3d5780b, 32307f0d) |
| B1 | Mint binder ids in every pass that created binders with id 0 (Perceus result and view temps, borrow arguments, aggregate fields, tuple SROA, parallel tensor, record update, tensor specialize, match projection, option fusion, SSA, pipelines); then delete the id-0 spelling fallbacks | the passes; then c_naming.brp, c_symbol_projection.brp | audit, oracle, runtime, leak; C bytes | B1a (authored binders carry ids at lowering) landing; B1b (compiler temporaries spelled from `CoreBinderOrigin`) running |
| B2 | Variant constructors and tags spelled `brp_c_<id>` / `brp_t_<id>` from the variant's `def_id`; literal `TAG_` readers removed | c_naming.brp, lower.brp, flatten.brp, mono_data.brp, prepare.brp, emit.brp, specialize*.brp | audit, oracle, runtime, leak; C bytes | done (c19c3392a, self-compile C −9.04%) |
| B3 | Record members spelled by ordinal or field id for non-ABI records; `c_field_name` keeps only the ABI branch | emit.brp field sites, record layout, c_naming.brp | audit, oracle, runtime, leak; C bytes | after B2 |
| B4 | Closure and task `c_name` / `static_name` deleted; the test-only unprojected emission mode retired | emit.brp, c_symbol_projection.brp, ir.brp closure records, closure.brp, test_core_emit.brp | audit, identical C | after B3 |
| B5 | Variant symbols computed at emission from `def_id` on constructs and match tests, deleting the Core `c_name` / `tag_c_name` Strings kept by B2; `__blorp_reuse_<Type>_` shortened | match_projection.brp, prepare.brp, reuse.brp, emit.brp | identical C | after B1 |

## Interim states on main

Every dual carry or bridge currently on main, with the step that deletes it.
A row leaves this table only when its deletion lands; nothing temporary
becomes permanent by being forgotten.

| Interim state | Introduced by | Deleted by |
| --- | --- | --- |
| `CoreFunction.name` still produced beside `CoreFunction.origin`; readers still parse it | M1.1 (5dfdf344b) | M2.1–M2.6 move readers, M3.1 deletes the producers |
| `origin_name_agreement.brp` invariant reads the mangled markers (`BLORP_ORIGIN_CONTRACT`) | M1.1 | M3.1 |
| `typed_name_identity.brp` census (`BLORP_NAME_IDENTITY`) counts `.text`/id mismatches | A0 (aa5425ed4) | A5, when `.text` is gone |
| `name_spelling_of_text(table, text)` bridge for Core and LSP names held as Strings | A1 (375d637a0) | A5 for Core names; LSP once it reads ids |
| Five temporary cross-owner import permissions for `stage_02_lex/name_table.brp` (format, lsp, test ×2, format/command) | A0/A1 | a small step moving `name_table.brp` to `blorp/src/lib` |
| Variant `c_name` / `tag_c_name` Strings and `CoreUnionConstruct.tag_c_name`, spelled from `def_id` at Core construction | B2 (c19c3392a) | B5 computes them at emission from `def_id` |
| `SOURCE_VARIANT_TAG_PREFIX` fallback for a variant without a `def_id` | B2 | B5 |
| `MANGLED_DEF_ID_PREFIX` / `mangled_definition_name` in identity.brp for hoisted-closure names | T5 (f21b59a9d) | M3.1 |
| `c_local_name` escape branches for locals with id 0 | B0 (32307f0d) | B1b (dense or origin-derived spelling for compiler temporaries) |
| `ImplMethod(trait NameId, method NameId)` without impl/trait def ids and type key; `SourceFunction(NameId)` without a module id; program-wide hoist ordinals | M1.1 | M2.3, M2.5 |
| Span-derived positive binder ids for authored binders | B0/B1a | A1b (parser-minted ids) |
| One sigil read left in `type_parameter_name_kind` (`List[String]` type parameters) | D7 (230835a0b) | type interning, when type-parameter lists carry kinds |
| `--dump-core` JSON carries both name Strings and ids | A0 | A5 |
| `.text` lookups in type header resolution (`declared_unqualified_type`, `type_header_graph_has_unqualified_type_name`, `resolve_named_type`) kept beside `identifier.name` for import, alias and parameter lookups keyed by String | A2 | A4/A5 |

## Finished branches waiting to land

B1a (`core/t7-mint-synthetic-binders`, merging main). T10, T5, D7, the LSP
fix, A1 and M1.1 have landed.

## Appendix: the catalog

`benchmarks/results/name_string_catalog_2026-09-28.md` lists every
name-bearing String, derived name, string-keyed table and `.text` reader
found after A0, with the tidy-up tasks T1–T10, convertible items C1–C8 and
"dead after" items D1–D9. This roadmap supersedes its task order:

- T1, T4 and T9 are A1, A2 and A4/A5. T5 is landing. T2 and T3 landed.
- D1/D2 are B1; D5 is B4; D6 is B2; D4 is B3; D3 follows B1 and A3; D7 is
  landing; D8 is A4/A5; D9 belongs to the type-interning roadmap.
- T6 (payload `CoreType`) is A3.3. The rest of T10 (CTFE environment keys,
  `module_member_prefixes`), C6 and C8 wait until both lanes are done.
