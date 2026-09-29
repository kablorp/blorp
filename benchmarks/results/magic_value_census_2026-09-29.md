# Magic-value census

Date: 2026-09-29. Read-only pass over `blorp/src` at `origin/main` `c47e62f23`;
no compiler source changed, nothing built or run. Line numbers are for that commit.

Question: where does a value stand in for a type (a sentinel Int, a packed Int, a
positional tuple, an anonymous Bool, an empty value meaning none, a bare number,
a bare id Int) instead of an explicit Option, union, record, enum, opaque type or
named constant. Input was ten cheap probes (167 raw rows, unreliable); every
site below was reopened. Sites already owned by the name-to-id work (trait-name
Strings, type-name spellings, identifier text, binder id ranges, the
source-location handle, the field-ref sentinel, the `blorp_*` builtin registry)
are marked `owned` and are not proposed here.

Representation facts used for cost:

- `Option[Int]` as a return value is a stack value (`blorp_StackOption_Int`, e.g.
  `blorp_parse_int` in runtime_decl.c:1512). Inside a record or union variant it
  allocates a box (definition_index.brp:120-123). So the probes' blanket
  "use `Option[Int]`" is free at function boundaries and costly in stored fields
  and hot payload columns; none of the steps below add an `Option` to a stored
  field on a hot path.
- Opaque types over Int are free (`into_opaque` / `from_opaque`).

## ROI order

Benefit is what the step prevents or removes; cost is files, sites, test churn,
behaviour and allocation risk. Rank 1 is the best return.

| Rank | Step | Benefit | Cost | ROI |
| --- | --- | --- | --- | --- |
| 1 | S1 delete dead typecheck `Context` counters and `mint_def_id` | Removes 9 fields and a function that look like live id spaces but are never read; smaller `Context` copied on every session reset. | 3 files, ~30 lines (context.brp, test_context.brp, one profile benchmark). No behaviour change; compile-checked by the type checker. | Very high |
| 2 | S2 import the authored-id ceiling in two Core passes | Removes a drift hazard on a collision-safety invariant (synthetic ids vs authored ids), 2 sites. | 2 files, 2 lines. No behaviour change (same value). | Very high |
| 3 | S3 confirm and guard the 64-bit retain/release masks | Latent silent miscompile or C undefined shift at >= 63 fields/elements (unconfirmed); removes duplicate `int_power_of_two`; 8 sites. | Probe test plus a diagnostic guard: 2-3 files, small. Full opaque mask type is a second, larger stage. Codegen unchanged for valid programs (verify with generated C identity). | High |
| 4 | S4 decode module-slot tables once | Removes 5 hand decoders of two different '+1 / +2 offset, 0 = absent' conventions (off-by-one class); fixes the family at its encoders. | 2 files (decl.brp, bound_module_graph.brp), ~9 sites, typecheck-graph suites. No allocation change: `List[Int]` stays, only the accessor returns `Option`. | High |
| 5 | S5 skeleton chain terminator and the bridge edge terminator | Removes 6 + ~8 sites of `-1` chain ends (4 hand-written walkers). | 2 files, one accessor each. No behaviour change; not hot after headers. | Medium-high |
| 6 | S6 record/field locator split and opaque locators | Removes a two-meaning `Dict[Int, Int]` (sign encoding) and two duplicated `* 2 + flag` encodings; fail-closed reads no longer carry correctness. | 2 files, ~12 sites; accepted-authority tests. One extra Dict per accepted record table (built once). | Medium |
| 7 | S7 small local `Option` conversions | 8 sites where a fake -1/"" is created only to be tested (A07, A08, E01, E05, X01, A13). | 6 files, one function each; no hot path (`Option` is a return or local). | Medium (cheap) |
| 8 | S8 name the remaining numbers | 18 sites (ASCII codes, tag width limits, BMP limit, loop bound, byte width). | 5 files; cosmetic; no risk. | Low-medium |
| 9 | S9 Bool mode parameters and pair-to-pattern cleanups | ~14 sites (trim/case enums, lexer, entrypoint, prepare, CTFE triple). | 6 files; lexer path is per pipe-string line, measure before landing. | Low |
| 10 | S10 `Dict[K, Bool]` to `Set[K]` | 194 declarations, one convention; gain is clarity. | 46 files; needs a Set-vs-Dict membership measurement (Set is separate chaining, Dict has the newer slot layout) before any hot module moves. | Low |
| 11 | S11 purity/variadic/mutable Bool to enums | ~1,200 refs (`SemanticFunctionType` 307, Core `FunctionType` 296, lambdas 137, var-decl 138). Clearer patterns; no bug found. | Very large blast, needs a stage-neutral `Purity` first (enum lives in stage 6 today). | Low |
| 12 | S12 opaque Core `DefId` (with node/binder id types) | Prevents cross-space id mix-ups (def ids count up, node/binder ids count down); no live bug found. | 196 `def_id: Int` in 36 files; belongs inside the Core id migration, not on its own. | Lowest |

## Sites

Verdicts: `change` (a real value-for-type convention worth fixing), `leave`,
`fp` (false positive: the code is not what the probe said), `owned:<work>`.
Merit: high, medium, low. `n` is source lines / occurrences. Rows A22, A23, A26,
B07, D01, D04, E06, F07, X01-X03 are sites the probes missed or misread.

| Id | Site | n | Verdict | Merit | Finding |
| --- | --- | --- | --- | --- | --- |
| A01 | allocation_analysis.brp:891 (`missing_component`) | 1 | leave | - | Named local sentinel inside one function (`component_assignments`); never escapes. |
| A02 | allocation_analysis.brp:942,1000,1001,1209 (`component_by_owner.get_or(_, -1)`) | 4 | leave | - | List is total over owners, so -1 is an unreachable default. If it were reached, `List.set(-1, _)` is a documented no-op (std list.brp), so it would drop facts silently rather than crash; acceptable for an internal total table. |
| A03 | allocation_report.brp:125-130,138,164,165 (BFS predecessor lists, `-1` cursors) | 7 | leave | - | Local breadth-first search in `witness_path`; the parallel lists and -1 never leave the function. |
| A04 | semantic_type.brp:416,454; stage_08 identity.brp:166 (`raw_index_of` then `< 0`) | 3 | owned:type-name spellings | - | These parse the `module::Type` / `alias.Type` spellings; the reader disappears with type-name ids. Each already converts to `Option` on the next line. |
| A05 | package_manifest.brp:244,248,261 (`end_index = 0 - 1`) | 3 | leave | - | Scan cursor inside one function; could be a helper returning `Option[Int]` but nothing escapes. |
| A06 | synth_hash_collections.brp:120 (`DICT_MISSING_SLOT = -1`) | 1 | leave | - | Named constant in synthesized Core for the runtime table probe; mirrors the runtime layout (same file's 112-118 constants). |
| A07 | accepted_trait_implementation_authority.brp:584,606 (`module_id_table_index(...).get_or(-1)`) | 2 | change | low | Missing module becomes key -1; `indices.get(-1)` is None (no conflict) and `set(-1, _)` is a no-op, so an unresolved module would silently skip the duplicate-method check. `implementation_method_ids_are_valid` runs first, so today it is unreachable; a `match` makes that dependency explicit. |
| A08 | decl.brp:1930 and type_header_graph.brp:1759-1761 (`definition_id.get_or(-1)` into `definition_table_field_id`) | 2 | change | low | Probe named definition_index.brp:1761; the real second site is type_header_graph.brp:1761. -1 goes through `definition_id(-1)` and a row lookup only to yield None. `definition_id.and_then(...)` at both callers; no API change. |
| A09 | definition_index.brp:126 (`MISSING_RESOLVED_FIELD_IDENTITY_VALUE`) | 1 | owned:field-ref sentinel | - | Opaque scalar chosen because `Option[FieldId]` inside records/variants boxes (comment at 120-123). |
| A10 | global_header_completion.brp:51 (`GLOBAL_HEADER_MODULE_INDEX_MISSING`) | 1 | leave | - | Private named constant; the only reader (156-159) converts to `Option` at the accessor. |
| A11 | bridge.brp:783 (`NO_PREPARED_MODULE_INDEX`) | 1 | change | low | One name is used for three roles in `imports_target` propagation (2521-2577): missing module index, empty edge-list head, chain end. Edge indices are not module indices; rename or split into `NO_DEPENDENT_EDGE`. |
| A12 | module_view.brp:206 (`BOUND_CANDIDATE_NO_RELATED_ROW`) | 1 | leave | - | Scalar-struct column (`struct` rows stay inline); converted once by `bound_candidate_related_index` (431-434). |
| A13 | module_view.brp:208 (`BOUND_CANDIDATE_NO_SOURCE_NAME`, 10 uses) | 1 | change | low | -1 is paired with a separate `uncataloged_*_name: Option[String]` in the request variants (2783-2797): two fields that must agree, unenforced. A `SourceNameRef = Cataloged(index) | Uncataloged(String)` union states the coupling. |
| A14 | type_system/context.brp:433,502,508 (`slot < 0`, `meta_slot < 0`) | 3 | fp | - | Bounds checks that fail closed, not a sentinel. |
| A15 | static_string_literal_pool.brp:76 (`id_value < 0`) | 1 | fp | - | Validation returning the explicit `NegativeStaticStringLiteralId` error. |
| A16 | c_symbol_projection.brp:328 (`candidate.def_id < 0`) | 1 | fp | - | Validation returning `InvalidCallableDefinitionId`. |
| A17 | emit.brp:1272 (`def_id = -1` in `diagnostic_emission_context`) | 1 | leave | - | Used only by the two internal diagnostic walkers (22568, 22589) with `UnprojectedCEmissionSymbolsForTests`; the def id is never read for output. |
| A18 | pass_runner.brp:1123 (`next_node_id = -1`) | 1 | owned:source-location handle | - | Node ids count down from -1 (`core_source_loc_from_raw`). |
| A19 | lib/source.brp:44 (`COMPILER_PRELUDE_FILE_ID = -1`) | 1 | owned:source-location handle | - | Private, encapsulated behind `SourceLocation`. |
| A20 | token.brp:755,758,761,764 (`id = -1` for payload-less tokens) | 4 | leave | - | `Token.payload` is documented (token.brp:139-160) as a per-tag scalar so the struct stays all-scalar for inline list storage; only `token_payload` produces -1 and `current_payload` reads it. Hot path; an Option would box. |
| A21 | ctfe eval.brp:2042,2314 (`count < 0`, `size < 0`) | 2 | fp | - | Clamp of `drop_left` count; explicit `CtfeEvalInvalid` error for negative tensor size. |
| A22 | declaration_skeleton.brp:1305,1446,1497,1637,1654 (+ producer 1349-1352) | 5 | change | medium | Probe missed. `previous_same_name_index_by_skeleton: List[Int]` is a linked list threaded through a list, terminated by -1; four hand-written walkers each spell `>= 0` and `get_or(_, -1)`. One producer, four consumers, all in one file. A named terminator plus one `previous_same_name_skeleton(index) -> Option[Int]` accessor removes the repeated encoding. |
| A23 | compact_expression_product.brp (91 x `.get_or(-1)`) | 91 | leave | - | Probe missed the largest cluster. The file header says it is a test oracle with no production callers, and each site reads a bounded stack or root list after a length check. Not worth converting; if the oracle is retired the family goes with it. |
| A24 | language_parser.brp:902,982,1008 | 3 | leave | - | Hot parser path: payload/offset defaults after a bounds test; -1 cannot equal a non-negative offset. |
| A25 | infer.brp:10977,11188 (`callable_id ... get_or(-1)`) | 2 | leave | - | Feeds only an internal-error message that is emitted when the target is `Some`, so -1 is unreachable. |
| A26 | decl.brp:7636-7640,8287-8294,8779-8790,8809-8810,9101-9106; bound_module_graph.brp:374-389,407-414 | 9 | change | medium | Probe missed. `positions_by_module_id: List[Int]` encodes 'slot + 1, 0 = absent' in decl.brp (three hand decoders, one encoder at 7715) and 'target = 1, module k = k + 2, 0 = absent' in bound_module_graph.brp. Two different offset conventions for the same idea; an off-by-one here silently selects the wrong module environment. |
| A27 | trace.brp:50 (`TYPECHECK_TRACE_UNINDEXED = -1`, 41 uses) | 1 | leave | - | Named diagnostic-only trace argument. |
| A28 | declaration_skeleton.brp:1285 (`module_position = -1` = target module first) | 1 | leave | - | Local loop cursor; could iterate `[target] ++ modules`. |
| A29 | declaration_skeleton.brp:511-560 (`raw < 0` means builtin trait id) | 5 | owned:trait identity | - | `TraitId` sign encoding is documented and owned by trait_identity.brp with pinned tests. |
| A30 | bound_module_graph.brp:200,217,290,576; indexed_graph.brp:1055; bridge.brp:2838; definition_index.brp:428 | 7 | fp | - | Bounds and validity checks. |
| B01 | accepted_record_authority.brp:97-107 (`record_index * 2 + owner_local`) | 3 | change | low | Encoded and decoded only through three private helpers, but `AcceptedRecordLocator` is a transparent `type alias`, so nothing stops arithmetic on it. Make it opaque (no runtime cost). |
| B02 | accepted_global_authority.brp:120-127,693-697 (`definition_id * 2 + owner_local`) | 3 | change | low | Same encoding, but the decoder is inlined twice in `binding_at` (`/ 2`, `% 2 == 1`) instead of using accessors next to `global_locator`. Same fix as B01, duplicated logic. |
| B03 | accepted_record_authority.brp:248,296,312-325,384,595-600,717 (`record_or_field_locators_by_definition_id`) | 6 | change | medium | One `Dict[Int, Int]` holds two kinds of value: a record index (>= 0) and a negated packed field locator (`0 - (index * stride + field) - 1`). Readers at 384 and 717 pass a field's key and rely on `List.get(negative)` being None; 595 passes a record's key and relies on the same. Correct today only because definition ids are disjoint and `get` fails closed. Two dicts (record index by id, field position by id) state it directly. |
| B04 | allocation_analysis.brp:1004 (`caller * count + callee` dedup key) | 1 | leave | - | Private key in one function; unique because components are in [0, count). |
| B05 | lib/source.brp:51,53 | 2 | owned:source-location handle | - | Documented packing behind opaque `SourceLocation`. |
| B06 | c_naming.brp:386-389 (`owner_id >= 0` else `n` + negated) | 4 | owned:binder id ranges | - | Owner is a binder id; sign is the authored/minted split. |
| B07 | prepare.brp:2119,2710-2818; emit.brp:4105-4120,7496-7512,18990-19010 (release/retain masks as Int) | 8 | change | high | Probe partly missed. Retain/release masks are `Int` bitsets built with repeated doubling (`int_power_of_two` exists twice, prepare.brp:2119 and emit.brp:7496; `bit *= 2` at emit.brp:4113) and decoded with `/ bit % 2`. Emitted C uses `1UL << field_index`. I found no guard on element/field count in the three producers: at >= 63 elements the Int wraps (division by zero yields 0 in Blorp) and the C shift is undefined at >= 64. Latent, unconfirmed: a 64-field union variant or 64-element tuple probe would settle it (not run: read-only pass). |
| B08 | token.brp:679-691 (`text_id * STRING_LITERAL_KIND_BITS + ordinal`) | 3 | leave | - | Encapsulated by pack/unpack helpers. The constant is a stride of 8 named `_BITS`; misleading name, and correct only while there are <= 8 literal kinds (6 today). |
| C01 | lexer.brp:1094,1162-1166 (`(String, Bool, Cursor, Bool)`) | 5 | change | low | Destructured by index; per pipe-string line, not per token, so a record is acceptable. A `match` destructure is the smaller fix. |
| C02 | infer.brp:533 and dim_constraints in decl/env/typed_ast_json/parser (`List[(SemanticType, SemanticType)]`, 110+ refs in src) | 1 | change | low | Left/right of an equality; positional access `constraint[0]`, `[1]` in decl.brp (2991,3188,3268,4243,4500,7363). A `DimConstraint` record touches parser, typecheck and JSON. |
| C03 | infer.brp:1118; decl.brp:3619,6054; state.brp:226,761,1756,2323 (`List[(String, String)]` function to trait name) | 4 | owned:trait-name Strings | - | Pair carries a trait name. |
| C04 | entrypoint.brp:145,160-161,226 | 3 | change | low | `Result[(CoreParam, CoreExpr), String]` read by `[0]`/`[1]`; `Result[(CoreProgram, Int), String]`. Destructure with a pattern or return a record. |
| C05 | graph_prepare.brp:114,142,173 (`List[(Int, CoreLowerCallableName)]`) | 3 | leave | - | Built and turned into a Dict inside the same file. |
| C06 | prepare.brp:3817-3846 (`Option[(CoreType, CoreType)]`, `payloads[0]`, `[1]`) | 3 | change | low | Probe called it a Result payload list; it is an (ok, err) pair indexed by constructor spelling. Pattern-match the pair. The `"Result"`/`"Ok"`/`"Err"` strings are owned by the name work. |
| C07 | synth_hash_collections.brp:531 (`Option[(List[CoreType], CoreType)]`) | 1 | leave | - | Local helper returning (params, return); matched immediately. |
| C08 | closure.brp:611-612 (diagnostic snapshot tuples) | 2 | leave | - | Test/diagnostic snapshot shape. |
| C09 | command_line.brp:29 (`pairs: List[(String, String)]`) | 1 | leave | - | Input/output pair read once in the CLI; name is in the surrounding code. |
| C10 | expression_documents.brp:3257,3356 | 2 | leave | - | Private renderers over the JSON entry shape (name, expression), (key, value). |
| C11 | ctfe value.brp:149 (`(String, CtfeValue, ResolvedFieldIdentity)` triple) | 1 | change | low | Only real triple; three fields of three types by position. |
| C12 | ctfe value.brp:104,148; context.brp:240; ir.brp:208; eval.brp:1264,1280,1301 | 7 | leave | - | Pairs (name, binding), (key, value), (id, function) read in the same file; idiomatic. |
| D01 | parsed_ast.brp:58,278; infer.brp:721; type_header_graph.brp:251; definition_identity.brp:107; semantic_type.brp:32; ir.brp:1237 (purity Bool in function types and lambdas) | 7 | change | medium | Probe found the parser two only. The same positional purity Bool crosses `SemanticFunctionType` (307 refs), Core `FunctionType` (296), lambdas (parsed 85, typed 52) and the header shapes, while `enum Purity` already exists (env.brp:66) but lives in stage 6, so the parser and Core cannot use it. Needs a stage-neutral home first. |
| D02 | parsed_ast.brp:53; type_header_graph.brp:242-246 (variadic-dimension Bool) | 6 | change | low | Six variants carry an anonymous Bool meaning variadic. |
| D03 | parsed_ast.brp:252-253; infer.brp:700-701 (string interpolation Bool) | 4 | change | low | Probe misread it: the Bool is `is_multiline` (language_parser.brp:7105 passes `kind == InterpolatedPipeStringLiteral`), not raw vs interpolated. `ParsedStringLiteralForm` already exists for the non-interpolated case. |
| D04 | parsed_ast.brp:289 (`ParsedVarDeclExpr` Bool = mutable, 138 refs) | 1 | change | low | Probe missed; same anonymous Bool family. |
| D05 | synth_string.brp:1912 (`trim_left`, `trim_right`), 2658 (`expect_lower`) | 2 | change | low | Local Bool mode parameters with five call sites (3289-3305, 3419, 3427); `TrimEnds`/`LetterCase` enums. |
| D06 | lower.brp:1367 (`core_lowering_type_metrics_enabled() -> Int`) | 1 | leave | - | `foreign func` mirrors the C ABI (`== 0` at six call sites). |
| D07 | token.brp:182-183,232-233 (`trivia_start`, `trivia_count`) | 4 | leave | - | All-scalar struct requirement documented at token.brp:150-160. |
| E01 | source_package_layout.brp:37,59 (`""` = no subpath) | 2 | change | low | `Option[(String, String)]` with "" for the missing half, and `parts[0]`, `parts[1]` reads; `alias/` and `alias` also collapse to the same value. `Option[String]` subpath. |
| E02 | lib/source_graph.brp:265 (`path.trim() == ""`) | 1 | leave | - | Normalises an environment variable that is set but empty into `None` immediately. |
| E03 | resolve.brp:443 (`source_module.get_or("")`) | 1 | leave | - | "" never matches a builtin module key; still spelling-based (see name work). |
| E04 | resolve.brp:730; backend_projection.brp:655; closure.brp:3394; allocation_report.brp:84 (`get_or(_, [])`) | 4 | fp | - | Absent equals empty list by meaning. |
| E05 | backend_projection.brp:569 (`is_some()` then `get_or("")`) | 1 | change | low | Test-then-default; a `match` removes the fake empty name. |
| E06 | lower.brp:6165-6166 and 88 other `Dict[String, Bool]`, 101 `Dict[Int, Bool]` in src (Dict as set) | 194 | change | medium | Family, not a single site: 194 declarations in 46 files, values effectively always True, while `Set[T]` exists and is used 64 times. `Set` is documented as separate chaining while Dict has had recent slot-layout work, so this is gated on measuring membership cost in the hot ones before converting. |
| F01 | list_layout.brp:447-451 (255, 65535, 4294967295) | 3 | change | low | Unnamed width limits next to named `INLINE_WIDTH_*`; derive from the width. |
| F02 | collection_pipeline.brp:113; match_lowering.brp:110 (`CORE_SYNTHETIC_ID_SEED = 2147483648`) | 2 | change | medium | Both duplicate `CORE_AUTHORED_BINDER_ID_CEILING` (ir.brp:1128, exported) and each comment says the seed must stay above every authored id. If the ceiling changes the copies would silently collide with authored ids. Import it. (`lower.brp:1610 QUESTION_BIND_ID_BAND = 4294967296` is the same family, tied to `MINTED_BINDER_ID_FLOOR`.) |
| F03 | lower.brp:6258,6262 (`while steps < 16`, `steps = 16` to exit) | 2 | change | low | The bound is described in the doc comment but not named, and the loop exits by assigning the bound. |
| F04 | synth_string.brp:55 | 1 | fp | - | Already a named constant. |
| F05 | emit.brp:26217 (`64` in emitted C text) | 1 | leave | - | Single use inside a C template string. |
| F06 | package_manifest.brp:159-172,404-419 (ASCII 92, 34, 110, 116, 10, 9, 13, 8, digits) | 10 | change | low | Same file already uses Char literals (`'\\'` at 234). Precedent for named byte constants exists (emit_literal.brp:35-43). |
| F07 | synth_string.brp:2943,2979 (`int_literal(65535)`) | 2 | change | low | Probe missed: BMP limit inside synthesized Core. |
| F08 | synth_hash_collections.brp:112-118; mono_instance.brp:37-59 (HASH_TAG_*) | 27 | leave | - | Named; mirror the runtime table layout / arbitrary tags. |
| F09 | specialize_tensor_fill.brp:91 (`Some(1)` Bool width) | 1 | change | low | Byte width 1 is `INLINE_WIDTH_1` from list_layout.brp. |
| F10 | emit.brp:18547-18548 (`-1L` in emitted C) | 2 | leave | - | C source text. |
| G01 | pass_runner.brp:134; ir.brp:1180; mono_data.brp:68,108 (`next_def_id`, `def_id: Int`; 196 `def_id: Int` in 36 files) | 4 | change | medium | Def ids count up, node ids and binder ids count down from -1, all bare `Int`. A mix-up would produce silent id collisions. `DefinitionId` is already opaque in stage 6, but Core carries raw Ints. Cross-cutting. |
| G02 | type_system/context.brp:86-96 (`def_id_counter`, `lower_*_counter`, `desugar_counter`, `ssa_mut_counter`) | 9 | change | medium | Confirmed dead: none of the nine counter fields is read outside `context.brp`, its constructors (146-154, 1455-1463), test_context.brp and compiler_infer_session_reconstruction_profile.brp; `def_id_counter` is read only by `mint_def_id`/`DefIdStep` (context.brp:105,1415), which only test_context.brp calls. Leftovers from lowering-in-typecheck. Delete, do not type. |
| G03 | format expression_documents.brp:1006 (`next_temp`) | 1 | leave | - | Local counter. |
| H01 | mono_impl.brp:72 (`TO_STRING_CORE_SENTINEL = "blorp_to_string"`) | 1 | owned:builtin registry (A2) | - | One of 485 `== "blorp_*"` comparisons in 16 files. |
| X01 | cli_args.brp:475 (`raw_index_of("::")`) | 1 | change | low | `index_of` returns `Option`; `raw_index_of` is public and documented as returning -1. Other callers are the builtin's own implementations (eval.brp:2117, intrinsic.brp:278, synth_string.brp:467,3167) or name parsers (owned). |
| X02 | infer.brp:15844,16843 (`subscript_single_static_value(...).get_or(0)`) | 2 | leave | - | A non-static index is rejected by `validate_tuple_subscript` and the result type is suppressed on error; index 0 is only a placeholder. |
| X03 | infer.brp:6726 (`parse_int().get_or(0)`) | 1 | leave | - | Out-of-range literals are rejected by the parser (should_fail/integer_too_large.brp); hex/underscore forms do not exist. |

## Proposed steps

Each step is independently landable, one change per change. Gate column names
the smallest check from AGENTS.md; every step also gets code-reviewer and
test-runner review.

### S1 Delete dead `Context` counters (G02)

- What: remove `def_id_counter`, `lower_destruct_counter`, `lower_param_counter`,
  `lower_question_bind_counter`, `lower_resource_counter`,
  `lower_task_scope_counter`, `lower_current_task_scope_id`, `desugar_counter`,
  `ssa_mut_counter`, and `mint_def_id` / `DefIdStep`. Re-grep first; my grep found
  no reader outside constructors, `test_context.brp:132-208`, and
  `compiler_infer_session_reconstruction_profile.brp:280-285`.
- Files: `stage_06_typecheck/type_system/context.brp` (86-96, 105, 146-154,
  1415-1418, 1455-1463), `test/compiler/stage_06_typecheck/type_system/test_context.brp`,
  `blorp/benchmark/compiler/compiler_infer_session_reconstruction_profile.brp`.
- Explicit form: none; deletion (AGENTS rule 14, feedback: delete legacy).
- Risk: none if the grep holds; `Context` is a record, so removing fields shrinks
  copies. Gate: `scripts/compiler-check --stage typecheck`.

### S2 Import the authored-id ceiling (F02)

- What: `collection_pipeline.brp:113` and `match_lowering.brp:110` import
  `CORE_AUTHORED_BINDER_ID_CEILING` from `ir.brp` instead of repeating 2147483648.
  Check `lower.brp:1610 QUESTION_BIND_ID_BAND` in the same look.
- Risk: none (same value). Coordinate with the binder-id owners because the
  constants belong to their range work. Gate: `scripts/compiler-check --changed`,
  Core suites.

### S3 Retain/release masks (B07)

- What (first commit): add a fixture with a 64-element tuple and a 64-field union
  variant and run it; if it miscompiles, add a checked guard (diagnostic or boxed
  fallback) where masks are built (prepare.brp:2710-2818, emit.brp:4105). Second
  commit if warranted: one opaque `OwnershipMask` with `mask_with_bit`,
  `mask_contains_bit` and a bound, replacing both `int_power_of_two` copies and the
  `/ bit % 2` decode.
- Sites: prepare.brp 2119, 2710-2818; emit.brp 4105-4120, 4181-4184, 7496-7512,
  18990-19010.
- Risk: codegen; generated C must be identical for existing tests (read the C,
  run codegen audit). Not on a runtime hot path (compile-time). Gate:
  `scripts/test compiler-core-sanitize leak`, codegen audit.

### S4 Module-slot tables (A26)

- What: replace `positions_by_module_id: List[Int]` decoding in decl.brp
  (7636-7640, 8287-8294, 9101-9106, build 7715 and 8765-8790) and
  bound_module_graph.brp (374-389, 407-414) with one small opaque
  `ModuleSlotTable` per meaning (`slot_of(module_id) -> Option[Int]`), keeping the
  dense List storage.
- Explicit form: opaque type plus accessor; the +1/+2 arithmetic is written once.
- Risk: low; `Option[Int]` only as a return. Gate: `scripts/compiler-check --stage typecheck`.

### S5 Chain terminators (A22, A11)

- What: `declaration_skeleton.brp` add `previous_same_name_skeleton(index) -> Option[Int]`
  and a named end-of-chain constant used by the producer at 1349-1352; rewrite
  the four walkers (1305, 1446, 1497, 1637). In `bridge.brp:783` split
  `NO_PREPARED_MODULE_INDEX` from the edge-list terminator.
- Risk: none in behaviour; the walkers are not on a per-node path. Gate:
  typecheck stage suites.

### S6 Record/field locators (B03, B01, B02)

- What: in accepted_record_authority.brp keep record indices and field positions
  in two Dicts (`record_index_by_definition_id`, `field_position_by_definition_id`
  holding `(record_index, field_index)` packed by named helpers) instead of the
  negative-encoded single Dict; make both `*Locator` aliases opaque with accessors
  used by `binding_at` (accepted_global_authority.brp:693-697).
- Risk: one more Dict per accepted table; accepted-authority tests. Gate:
  `scripts/compiler-check --stage typecheck`.

### S7 Small `Option` conversions (A07, A08, A13, E01, E05, X01)

- decl.brp:1930 and type_header_graph.brp:1759-1761: `definition_id.and_then(...)`.
- accepted_trait_implementation_authority.brp:584,606: `match` on the module id.
- module_view.brp:208: `SourceNameRef` union (only if the coupling with
  `uncataloged_*_name` is worth a variant; otherwise leave).
- source_package_layout.brp:37,59: `Option[String]` subpath; note the
  `alias/` vs `alias` collapse.
- backend_projection.brp:569, cli_args.brp:475.
- Risk: none; no stored `Option[Int]`. Gate: `scripts/compiler-check --changed`.

### S8 Name the numbers (F01, F03, F06, F07, F09)

- Sites: list_layout.brp 447-451, lower.brp 6258/6262, package_manifest.brp
  159-172/404-419, synth_string.brp 2943/2979, specialize_tensor_fill.brp:91.
- Risk: none. Gate: focused suites plus `git diff --check`.

### S9 Modes and pairs (D05, C01, C04, C06, C11)

- synth_string.brp trim/case enums; lexer.brp:1094 tuple; entrypoint.brp
  145/160/226; prepare.brp:3817-3846; ctfe value.brp:149 triple.
- Risk: lexer measured with the existing pipe-string tests; others none.

### S10 Dict as set (E06)

- Do first: a microbenchmark of `contains` on `Dict[String, Bool]` vs `Set[String]`
  and the same for Int keys. Convert only families where Set is not slower.
  Otherwise document the convention.

### S11 Purity and other Bool payloads (D01-D04)

- Prerequisite: a stage-neutral `Purity` enum (env.brp:66 sits in stage 6). Pilot in
  the parser (`ParsedFunctionType`, `ParsedLambdaExpr`, `ParsedVarDeclExpr`,
  `ParsedDimNameType`, string interpolation using `ParsedStringLiteralForm`,
  ~350 refs in 14 files) before touching typed/Core.

### S12 Core `DefId` (G01)

- Fold into the Core id migration; do not start separately.

## Counts per theme

`n` counts source occurrences; rows counts finding rows.

| Theme | change (rows / n) | leave | fp | owned |
| --- | --- | --- | --- | --- |
| A Absent as -1 / 0 / negative | 6 / 20 | 14 / 121 | 5 / 14 | 5 / 11 |
| B Several facts packed in one Int | 4 / 20 | 2 / 4 | 0 / 0 | 2 / 6 |
| C Positional tuples | 5 / 13 | 6 / 16 | 0 / 0 | 1 / 4 |
| D Anonymous Bool payloads and modes | 5 / 20 | 2 / 5 | 0 / 0 | 0 / 0 |
| E Empty value as none / Dict as set | 3 / 197 | 2 / 2 | 1 / 4 | 0 / 0 |
| F Unnamed or duplicated numbers | 6 / 20 | 3 / 30 | 1 / 1 | 0 / 0 |
| G Bare Int for distinct id spaces | 2 / 13 | 1 / 1 | 0 / 0 | 0 / 0 |
| H Special function marked by a string | 0 / 0 | 0 / 0 | 0 / 0 | 1 / 1 |
| X Extra sites | 1 / 1 | 2 / 3 | 0 / 0 | 0 / 0 |
| Total | 32 / 304 | 32 / 182 | 7 / 19 | 9 / 22 |

Change rows by merit: high 1, medium 8, low 23. The 91-site `compact_expression_product.brp` cluster (A23) dominates the `leave` site count; without it leave is 91 sites.

## Probe reliability

- Ten probes reported 167 rows, about 115 after the summary's own filtering.
  After reading each site, most `change` findings are 2-4 sites; the rest are
  bounded local sentinels, named constants or checks that fail closed. About 40%
  of finding rows are leave and a fifth false positive or owned.
- False positives in the summary: context.brp 433/502/508 (bounds checks),
  static_string_literal_pool.brp:76 and c_symbol_projection.brp:328 (explicit
  error variants), ctfe eval.brp 2042/2314 (clamp and validation), synth_string.brp:55
  (already named), `get_or(_, [])` rows (absent equals empty).
- Misreads: parsed_ast.brp:252-253 Bool is `is_multiline`, not raw vs interpolated;
  prepare.brp:3844 indexes a pair, not a list of payloads; definition_index.brp:1761
  is really type_header_graph.brp:1761; `expression_documents.brp:1006`
  is a local counter; several `Option[Int]` suggestions ignore that a stored
  `Option[Int]` in a record or variant allocates.
- Missed: the 91-site `get_or(-1)` cluster in `compact_expression_product.brp`
  (a test oracle with no production callers); the slot-plus-one tables in decl.brp
  and bound_module_graph.brp; the linked list threaded through
  `declaration_skeleton.brp`; retain/release bitmasks; the dead typecheck counters;
  the purity Bool family beyond the parser; `Dict[K, Bool]` used as a set.
- Line numbers were usually right within a few lines except where noted; confidence
  labels were uniformly optimistic ("high" on named constants that mirror ABI or
  runtime layout).
- Re-probe of `decl.brp`, `infer.brp` and `headers/`, `graph/`: greps for
  `-1`, `< 0`, `>= 0`, `get_or(`, `raw_index_of`, `[0]`/`[1]`, Bool payloads, `== ""`
  and literals produced A22, A26, D01-D04, X02 and X03; the rest were
  bounds checks or `length() > 0` tests. The `[0]/[1]` uses in decl/infer are
  `constraint[..]` (C02), `pair[..]` (C03, owned) and `enumerate()` entries
  (idiomatic).
- Not verified: the 64-field mask overflow (B07) was not executed; behaviour of
  `Set` versus `Dict` performance (S10) was not measured.

