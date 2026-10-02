# Name-text inspection census

Date: 2026-09-28. Read-only measurement pass feeding
the retired identity plan (see Git history) step A0/C0a
(the identity-first migration) and grounded in
the retired identity plan (see Git history) T3
(name interning at the lexer). No compiler source changes in this commit.

Compiler commit: `8486ff7b2ae0` (`origin/main`, clean). `bin/blorp --version`:
`target: aarch64-apple-darwin`, `cc: Apple clang version 21.0.0
(clang-2100.3.34.2)`, `optimization: cli=-O0 runtime=-O2`, 8-way split;
`scripts/compiler-build-status` reports FRESH after `make`.

## What this decides

- **T3's lexer-interning prep landed; the id-carrying-AST half did not.**
  `blorp/src/compiler/stage_02_lex/token.brp` already stores `Token` as a
  scalar `struct` with `payload: Int` indexing into `LexResult.texts`, a
  flat interned-text table built once per scan (commit `2c171a5d8`, "Lex
  tokens as inline structs with interned texts and read them as columns in
  the parser"; the `token_kind_of` allocation regression the roadmap's
  2026-09-24 entry flagged for this same design was evidently fixed before
  landing, since it is now on `main`). But `ParsedIdentifier` (`stage_03_parse/parsed_ast.brp:28`)
  still stores `{ text: String, span: SourceLocation }` — the parser copies
  the interned text back out into an ordinary `String` at the first
  identifier token it consumes, and every later phase (module resolution,
  typecheck's own `SourceNameTable`, Core lowering, backend) re-hashes and
  re-compares that `String`. The roadmap's actual ask — carry a
  `SourceNameId` in `ParsedIdentifier` and convert every keyed-on-text
  consumer to key on the id — is unstarted. `graph/source_name_table.brp`'s
  own header comment already states the constraint the shim must respect:
  "`SourceNameId` is deliberately not semantic identity: it only replaces
  repeated `String` keys ... Resolved products must carry `DefinitionId`,
  `ModuleId`, or another semantic entity ID instead."
- **Sites that must change before a name can safely carry only an id (class
  3, and the two class-1 sites that inspect a user spelling's structure
  rather than compare it to one fixed constant):**
  - `stage_06_typecheck/type_system/semantic_type.brp:358`
    `split_canonical_module_type_name` — parses `module_path::type_name`
    back apart from the same file's `canonical_module_type_name` (`:637`)
    concatenation via `raw_index_of("::")`; two call sites at `:615` and
    `:724` (`owner_local_type_name`, `display_type_name`).
  - `stage_06_typecheck/type_system/semantic_type.brp:284/289/301`
    `strip_type_param_bounds`/`is_legacy_single_letter_type_param` — splits
    a type-parameter name at `":"` to recover bounds.
  - `stage_06_typecheck/type_system/type_resolution.brp:111/116/117` —
    splits a qualified name at the first `"."` into `alias_name`/`local_name`.
  - `stage_06_typecheck/decl.brp:2706`, `infer.brp:7970`,
    `headers/callable_headers.brp` (4 sites), `headers/implementation_headers.brp`
    (5 sites), `headers/type_parameter_discovery.brp:29-30` — all strip a
    leading `"#"` sigil off a type-parameter spelling with `.substring(1,
    ...)`/`.starts_with("#")`; the sigil is source syntax embedded in the
    name text itself, not a separate flag.
  - `stage_08_core_lower/identity.brp:117-166` — `CORE_UFCS_PREFIX` strip
    (`starts_with`/`substring`) and two independent `"::"`-split functions
    recovering `module_name`/`type_name` from one flattened string; the
    matching concatenation is `flatten_canonical_core_type_name_with_prefixes`
    in the same file, consumed by `lower.brp:1442`.
  - `stage_08_core_lower/lower.brp:948-954` — splits a callable's lowered
    name at `CALLABLE_ID_SEPARATOR` to recover the "clean" name and a
    disambiguating hash suffix.
  - `stage_09_core/resolve.brp:368-399`, `stage_09_core/std_inline.brp:239-263`,
    `stage_09_core/synth_name.brp` (a whole module dedicated to this),
    `stage_09_core/collection_plan.brp:107-124`,
    `stage_09_core/string_pipeline.brp:392-431` — five independent,
    near-duplicate implementations that strip `"__mono_"` (`MONO_NAME_MARKER`)
    and `"__pure"` (`PURE_NAME_SUFFIX`) markers back off a name produced by
    `mono.brp`'s `mangle_specialization_name`/`mangle_generic_data_name`
    (which literally embeds `"__mono_"` at construction, `mono.brp:1294-1360`).
    This is the single largest concentration of parse-back risk in the
    compiler: one synthesis site, five independent parsers, all keyed on
    the same two string markers baked into the name's bytes.
  - `stage_09_core/runtime_projection.brp:167` — recovers a trait method's
    "clean" name by stripping `impl_decl.trait_name + "_"` off
    `method.name`.
  - `stage_09_core/c_type_layout.brp:82-134` — parses a **C type string**
    (not a Blorp source name) to recover a payload type name from
    `"blorp_StackOption_"`-prefixed and pointer-suffixed C identifiers; this
    is downstream of C-symbol synthesis, so it is class 3 against a
    synthesized C string, not a source spelling, but it still breaks if the
    shim changes what a projected type symbol looks like.
  - `stage_06_typecheck/graph/source_name_table.brp:232/237` and
    `stage_09_core/backend_projection.brp:152` also parse a name
    (module-path segment, `.brp` suffix, a known runtime-name suffix) but
    are lower risk: they operate on paths/suffixes fixed by the file system
    or a closed runtime-name catalog, not on a compiler-synthesized
    mangling scheme, so they only need reclassifying, not restructuring.
- **Sites that are safe under the shim as written (class 1, compiler-known
  constant vs. a name's stringified id looked up once):** the `== "main"`
  (4), `== "Self"` (5), and C-reserved-identifier/struct-member membership
  checks in `stage_10_backend/c_naming.brp` (`C_RESERVED_IDENTIFIER_INDEX`,
  54 entries; `C_RESERVED_STRUCT_MEMBER_INDEX`, 1 entry) compare a spelling
  against one fixed, finite vocabulary that never changes at runtime — each
  can become one id constant resolved once from the name table (or, for
  the reserved-identifier lists, kept as literal text comparisons forever
  since they must reject exact C keyword spellings regardless of Blorp
  identity, which is itself display/ABI work, not identity work). The one
  exception in this group is **`== "_"` (34 sites** across
  `stage_03_parse/language_parser.brp`, `stage_06_typecheck/infer.brp` (12),
  `stage_07_ctfe/ir.brp`, `stage_08_core_lower/lower.brp` (9),
  `stage_09_core/cancellation_plan.brp`, `stage_10_backend/emit.brp` (9)):
  `"_"` is a real, unbindable user-source spelling (the wildcard binder),
  compared as text at every phase from parsing through emission, and an
  interning shim would still make this safe (a fixed sentinel id for the
  one spelling `"_"`), but only if every one of those ~34 sites is migrated
  together — a partial conversion would let a stringified-id `"_"` collide
  with a real user identifier that happens to stringify to the same digits
  before the cutover, or vice versa. This is worth calling out as a single,
  bounded, high-fanout slice on its own (see Slice list below), separate
  from the general "safe to leave as text" literals.
- **`is_runtime_erased_union_payload_type_name`/`normalize_type_name`
  (`type_system/semantic_type.brp:272`, `type_name_metadata.brp:49`) compare
  against compiler-internal type-name catalogs, not arbitrary user
  spellings** — safe to convert to id-keyed lookups once those catalogs are
  built from the same name table, but they are catalogs of *known type
  names* (`Int`, `String`, tensor/list/dict scalars, etc.), so the id they
  need is a type-name id, not a general source-name id; do not conflate the
  two tables.
- **The C-emission boundary already has a working id-keyed precedent to
  copy.** `stage_10_backend/c_symbol_projection.brp` (`git log --oneline -30
  -- blorp/src/compiler/stage_10_backend` — commit `71876d394 "Publish
  callable symbols by definition ID"`, then `f3d5780bd "Project
  artifact-local type names to short C symbols"` shrinking the self-compile
  artifact 94.9 MB→75.7 MB, -20.2%, and `b35ee33d6 "Compact backend
  temporary names"`, -5.76% more) already mints every callable and type C
  symbol from a `DefinitionId`/declaration-order ordinal, not from the
  source spelling, and resolves every type-name occurrence — including
  baked IR names such as stack-option/inline-list/tensor callees — through
  one program-wide symbol inventory (`preserved_symbol_index`,
  `callable_symbol`, `projected_name_conflicts_with_preserved`). This is the
  existing model the migration's C1p1 "checked `EmissionCompatibilityId`"
  step should imitate for local/binder names, not a separate design. The
  parts of the C-emission boundary this recent work did **not** touch are
  `foreign func` declarations and explicitly exported names — those must
  keep their exact user spelling as real C identifiers forever and can
  never be replaced by a stringified id (they are the one place the ABI is
  the user's own text).
- **Ordered conversion slices, with file ownership, so several workers can
  run in parallel without touching the same file:**

  | slice | files | risk addressed | can start |
  | --- | --- | --- | --- |
  | 1 | `stage_09_core/synth_name.brp`, `resolve.brp:360-400`, `std_inline.brp:230-265`, `collection_plan.brp:100-130`, `string_pipeline.brp:385-435` | consolidate 5 duplicate `"__mono_"`/`"__pure"` parsers into 1 canonical accessor keyed on the `mono.brp` synthesis site; highest fanout class-3 risk | now (semantics-preserving refactor, no shim dependency) |
  | 2 | `stage_06_typecheck/type_system/semantic_type.brp`, `type_resolution.brp` | `split_canonical_module_type_name`, bounds-split, alias/local-split | after slice 1's pattern is agreed, reuse its accessor style |
  | 3 | `stage_08_core_lower/identity.brp`, `lower.brp:940-960` | UFCS-prefix strip, `"::"` split (2 functions), `CALLABLE_ID_SEPARATOR` hash split | independent of 1/2 |
  | 4 | `stage_06_typecheck/decl.brp`, `infer.brp`, `headers/callable_headers.brp`, `headers/implementation_headers.brp`, `headers/type_parameter_discovery.brp` | `"#"`-sigil type-parameter stripping (10 sites) | independent; touches typecheck headers only |
  | 5 | `stage_03_parse/language_parser.brp`, `stage_06_typecheck/infer.brp`, `stage_07_ctfe/ir.brp`, `stage_08_core_lower/lower.brp`, `stage_09_core/cancellation_plan.brp`, `stage_10_backend/emit.brp` | the 34 `== "_"` wildcard-binder sites, converted together to one sentinel check | after slice 6 lands (needs the name table's sentinel-id API) |
  | 6 | `stage_06_typecheck/graph/source_name_table.brp` | extend the existing `SourceNameTable`/`SourceNameId` API with a stable, reserved sentinel id for `"_"` and any other fixed compiler literal (`"main"`, `"Self"`) | now — pure API addition, no call-site changes |
  | 7 | `stage_09_core/c_type_layout.brp` | C-type-string prefix/suffix parsing (`blorp_StackOption_`, pointer suffix) | after slice-owner of recent short-symbol work (`c_symbol_projection.brp`) confirms the projected-name shape is stable |
  | 8 | `stage_10_backend/c_naming.brp`, `c_symbol_projection.brp` | already id-keyed for callables/types; extend the same pattern to locals/binders per C1p1 | last — depends on slices 1-5 landing so local binder identity exists to key on |

  Slices 1-4 have no shared files and no shim dependency: they are
  semantics-preserving refactors that collapse today's ad hoc string
  surgery into one named accessor per concept, which is exactly the
  "moving deletion frontier" the retired identity plan (see Git history) describes and can
  land independently of when the id-carrying `ParsedIdentifier` change
  happens. Slice 5 needs slice 6 first. Slice 7 needs coordination with
  whoever touches `c_symbol_projection.brp` next (same file family as the
  landed short-symbol work). Slice 8 is the actual `CoreVar`/binder
  representation change from the retired identity plan's C8 and should
  not start until the others reduce the surrounding parse-back surface.

## Method

1. `make` (`-O0` CLI link); `bin/blorp --version` and
   `scripts/compiler-build-status` confirmed FRESH at `8486ff7b2ae0`.
2. Read `docs/WORKER_CHECKLIST.md`, the retired identity plan (see Git history) (full A0/A1
   sections and the identity vocabulary table), and
   the retired identity plan (see Git history) T3's section and its 2026-09-24 status
   row (`perf/lexer-token-struct`, "parked").
3. Grepped `blorp/src/compiler` (by `stage_02_lex` .. `stage_10_backend`),
   `blorp/src/lsp`, `blorp/src/lib`, and `standard_library/src` per class;
   read every flagged site's surrounding function to classify it (user
   spelling vs. compiler-synthetic name; parsed-back vs. compared/emitted
   only) rather than trusting the raw grep count, since a bare `"__"` or
   `.split(` substring match overcounts (confirmed directly: a naive
   `grep '"__'` returned 2,146 hits, almost all substrings of ordinary
   `__def_N_...`/`__mono_...` identifier text, not prefix-check call sites;
   the real `starts_with("__")` call-site count is 1).
4. Cross-checked the `Dict[String`/`Set[String]` per-stage counts against
   the retired identity plan's stated 2026-09 baseline (120/63/185/231 for
   typecheck/core-lowering/core/backend at `afc4dcfd`) to confirm the
   codebase has not drifted materially since that census (see table 1
   below — typecheck and core-lowering are unchanged, Core is +1, backend
   is unchanged).
5. Read `stage_02_lex/token.brp`, `stage_03_parse/parsed_ast.brp`, and
   `stage_06_typecheck/graph/source_name_table.brp` directly to determine
   T3's actual landed state, and `git log --oneline -30 -- blorp/src/compiler/stage_10_backend`
   plus `git show --stat` on `f3d5780bd`/`b35ee33d6` to confirm the recent
   short-symbol/temporary-name work's scope.

## 1. Per-stage totals by class

Stage directories: `stage_02_lex`, `stage_03_parse`, `stage_04_modules`,
`stage_06_typecheck`, `stage_07_ctfe`, `stage_08_core_lower`, `stage_09_core`,
`stage_10_backend`, `blorp/src/lsp`, `standard_library/src`. (`stage_01` and
`stage_05` do not exist as separate directories in the current layout;
`blorp/src/lib` is included where it carries compiler-facing code.)

| stage | `Dict[String` | `Set[String]` | `.name.text` reads | literal `== "<Ident>"` compares |
| --- | ---: | ---: | ---: | ---: |
| stage_02_lex | 1 | 0 | 0 | 0 |
| stage_03_parse | 0 | 0 | 20 | 5 |
| stage_04_modules | 15 | 0 | 16 | 7 |
| stage_06_typecheck | 120 | 10 | 290 | 170 |
| stage_07_ctfe | 1 | 0 | 7 | 9 |
| stage_08_core_lower | 63 | 0 | 38 | 133 |
| stage_09_core | 186 | 31 | 0 | 1,381† |
| stage_10_backend | 231 | 10 | 0 | 178 |
| blorp/src/lsp | 27 | 0 | 0 | 0 |
| standard_library/src | 51 | 0 | 0 | 187† |

† `stage_09_core` and `standard_library/src`'s literal-equality count is
dominated by non-name string-literal comparisons (enum tag strings,
runtime-call-name dispatch, JSON keys, CLI flag text); see caveat in
Method step 3 — do not read this column as "name compares" for those two
rows without the same manual reclassification the report above applied to
the smaller, fully-classified counts (`== "main"` 4, `== "_"` 34, `==
"Self"` 5, `is_runtime_erased_union_payload_type_name` 5 call sites,
`normalize_type_name` 23 references).

| class | description | count | notes |
| --- | --- | ---: | --- |
| 1 | `== "main"` | 4 | all compare a user-source function-declaration spelling |
| 1 | `== "_"` | 34 | user-source wildcard binder spelling; spans parse→emission (see above) |
| 1 | `== "Self"` | 5 | user-source `Self` type spelling |
| 1 | `starts_with("__")` call sites (exact prefix check, not substring) | 1 | `stage_10_backend/emit.brp:13206` |
| 1 | `normalize_type_name` references | 23 | compiler-internal type-name catalog, not raw user text |
| 1 | `is_runtime_erased_union_payload_type_name` call sites | 5 (2 definitions + 3 call sites) | compiler-internal type catalog |
| 1 | `builtin("...")` literal calls | 1,521 | native-runtime symbol ABI; 755 in `standard_library/src`, 1 in `stage_10_backend`, remainder split across frontend/CLI; must never be id-substituted (foreign ABI) |
| 1 | C-reserved-identifier/struct-member membership lists | 55 entries, 1 index each | `stage_10_backend/c_naming.brp`; finite closed vocabulary |
| 2 | `mangle_specialization_name`/`mangle_generic_data_name` (definitions) | 2 | both embed `"__mono_"` |
| 2 | `module_member_prefixes`/`flatten_canonical_core_type_name_with_prefixes` sites | ~90 | `stage_08_core_lower/identity.brp`, `lower.brp`, `stage_09_core/resolve.brp`, `mono_specialize.brp`, `mono_option.brp` |
| 2 | `core_trait_impl_type_key` call sites | 13 | `stage_09_core/trait_resolve.brp`, `resolve.brp`, `backend_projection.brp`, `runtime_projection.brp` |
| 3 | `.split(`/`raw_index_of(`/`index_of(`/`.substring(` on a semantic name (excludes file-path/manifest/URI parsing) | ~40 | see "What this decides" list above for the exact sites |
| 3 | duplicate `"__mono_"`/`"__pure"` parse-back implementations | 5 modules | `resolve.brp`, `std_inline.brp`, `synth_name.brp`, `collection_plan.brp`, `string_pipeline.brp` |
| 4 | `type_to_string` call sites | 153 | rendering/diagnostic boundary |
| 4 | `display_type_name` call sites | 7 | |
| 4 | `core_type_to_string` call sites | 11 | |
| 4 | `should_fail` typecheck fixtures pinning diagnostic text | 860 | of 1,398 total typecheck fixtures (465 `should_pass`) |
| 4 | `core_var_to_json`/`decode_core_var_json` name field round-trip | 1 pair | `stage_09_core/ir.brp:3462-3512`; dump/tool boundary |
| 5 | `c_local_name` call sites | 8 | |
| 5 | `c_var_name` call sites | 83 | |
| 5 | `c_type_name` call sites | 140 | |
| 5 | `c_identifier` call sites | 43 | |
| 5 | `c_field_name` call sites | 15 | |
| 6 | files mentioning `CoreVar` | 50 | matches the retired identity plan's stated count exactly — no drift |
| 7 | `EXPECT-C`-bearing fixtures | 214 | across `blorp/test/compiler` |

## 2. T3 (lexer name interning) landed vs. not landed

| piece | status | evidence |
| --- | --- | --- |
| Lexer publishes one append-only interned-text table per compile | **Landed** | `stage_02_lex/token.brp`: `Token` is a scalar `struct` with `payload: Int` into `LexResult.texts`; `token_kind_of(texts, token)` recovers the boxed `TokenKind` on demand |
| Identifier tokens carry an id, not text, through lexing | **Landed** | same file; `payload` is "an id into `LexResult.texts`" for text-carrying tags |
| Parser converts match sites to read `TokenTag` directly instead of rebuilding `TokenKind` per read | **Landed** (this was the fix for the regression the roadmap flagged) | commit `2c171a5d8` "Lex tokens as inline structs with interned texts and read them as columns in the parser" is on `main`; the roadmap's 2026-09-24 entry describing `token_kind_of`'s per-read allocation regression predates this landing |
| `ParsedIdentifier` carries the interned id forward (not just text) | **Not landed** | `stage_03_parse/parsed_ast.brp:28`: `record ParsedIdentifier { text: String, span: SourceLocation }` — still a plain `String` |
| Every `Dict[String, ...]` keyed on a source name converted to key on the id | **Not landed** | `stage_06_typecheck`'s own `SourceNameTable`/`SourceNameId` (`graph/source_name_table.brp`) exists and is explicitly scoped as "not semantic identity," but it interns starting from typecheck, not from the lexer's table, and per-stage `Dict[String` counts (table above) show typecheck/core/backend are still majority string-keyed |
| Formatter still reads spellings byte-for-byte from the parsed AST | **Confirmed necessary, unaffected either way** | `ParsedIdentifier.text`/`.span` is exactly what `blorp/src/format/projection.brp` reads; `bin/blorp format --check` is T3's own named oracle |

Net: T3's *lexer* half is done and already paid its bug ("Perceus's
`protect_repeated_consumes` had no `LiteralMatchExpr` arm" — a genuine
compiler bug found in the same window, not a T3 defect, and fixed
separately per the retired identity plan's row). The *parser-onward*
half — the actual "every consumer keys on the id" conversion this migration
needs — has not been attempted, so every class in this census still applies
to the current source, not to a hypothetical pre-T3 state.

## 3. Formatter and test-suite confirmation

- The formatter reads exactly `ParsedIdentifier.text` and `.span`
  (confirmed via `grep -n 'ParsedIdentifier' blorp/src/format/projection.brp`
  and reading `stage_03_parse/parsed_ast.brp:28`) — the parsed AST, not a
  lexer token stream and not a typed/Core representation. A shim that
  changes what `.text` contains at any point before formatting would break
  `bin/blorp format --check blorp/src standard_library/src` immediately;
  this is the correct oracle T3 already names.
- 860 `should_fail` + 465 `should_pass` fixtures under
  `blorp/test/compiler/stage_06_typecheck` (1,398 total) exist; diagnostic
  text asserted by `should_fail` fixtures is the primary regression surface
  for any change to how a name renders in an error message.
- 214 files carry `EXPECT-C` assertions across `blorp/test/compiler`; these
  pin generated C text, including identifier spelling where a fixture
  asserts on a specific symbol name.
- `blorp/test/compiler/stage_10_backend/test_core_emit.brp` exists as the
  dedicated Core-emission test file.
- `blorp/test/lsp` has 12 baseline/measurement Python harnesses
  (`test_lsp_native_baseline.py`, `test_lsp_native_measurements.py`, etc.)
  plus `.brp` fixtures under `analysis/` and `capabilities/`
  (`document_symbol_query.brp`, `hover_query.brp`, `definition_query.brp`,
  `references_query.brp`, `document_highlight_query.brp`) that assert on
  symbol/hover output, i.e. rendered name text reaching the LSP client.

## Commands run

```
make
bin/blorp --version
scripts/compiler-build-status

grep -rn '== "main"' blorp/src standard_library/src
grep -rn '== "_"' blorp/src standard_library/src
grep -rn '== "Self"' blorp/src standard_library/src
grep -rn 'starts_with("__' blorp/src standard_library/src
grep -rn 'normalize_type_name' blorp/src standard_library/src
grep -rn 'is_runtime_erased_union_payload_type_name' blorp/src standard_library/src
grep -rn 'builtin("' blorp/src standard_library/src

grep -rn 'split_canonical_module_type_name' blorp/src standard_library/src
grep -rn 'flatten_canonical_core_type_name_with_prefixes\|module_member_prefixes' blorp/src standard_library/src
grep -rn 'mangle_specialization_name\|mangle_generic_data_name\|core_trait_impl_type_key' blorp/src standard_library/src
grep -rnE '\.split\(|raw_index_of\(|index_of\(|\.substring\(|starts_with\(|ends_with\(' \
  blorp/src/compiler/stage_04_modules blorp/src/compiler/stage_06_typecheck \
  blorp/src/compiler/stage_08_core_lower blorp/src/compiler/stage_09_core blorp/src/lsp

for d in blorp/src/compiler/stage_0*_* blorp/src/lsp standard_library/src blorp/src/lib; do
  grep -rc 'Dict\[String' "$d"; grep -rc 'Set\[String' "$d"
done

grep -rl 'CoreVar' blorp/src standard_library/src | wc -l
for f in c_local_name c_var_name c_type_name c_identifier c_field_name; do
  grep -rn "\b$f(" blorp/src standard_library/src | wc -l
done
for f in type_to_string display_type_name core_type_to_string; do
  grep -rn "\b$f(" blorp/src standard_library/src | wc -l
done

find blorp/test/compiler/stage_06_typecheck -path '*should_fail*' -name '*.brp' | wc -l
find blorp/test/compiler/stage_06_typecheck -path '*should_pass*' -name '*.brp' | wc -l
grep -rl 'EXPECT-C' blorp/test/compiler | wc -l

git log --oneline -30 -- blorp/src/compiler/stage_10_backend
git show --stat f3d5780bd
git show --stat b35ee33d6
git log --oneline -5 -- blorp/src/compiler/stage_02_lex/token.brp
```
