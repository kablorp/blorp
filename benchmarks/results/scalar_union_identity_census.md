# Scoped scalar-union feature identity debt

Integration base: `c148b2d2ca876fa1963a76f4a4e94cc8e136470c`; staged precursor
`13edc7c94ba7d5116f910385aefafaadb491d2bd`. This is an explicitly approved feature-debt amendment, not an identity
improvement, semantic completion, new allowlist or blanket ratchet refresh.
[Machine evidence](scalar_union_identity_census.json) retains every exact-site
addition/removal, changed cap, source excerpt and before/after source hash.

The initial integration census rejects 4 added/1 removed exact sites and five
budget increases. Removing the redundant diagnostic wrapper eliminates its
extra Dict formal: Core Dict remains 180. The remaining amendment is exactly
3 added/1 removed keys and the four caps below. The removed snapshot fingerprint
is replaced because its existing `fieldless_enums: Set[String]` field now ends
with a comma; this is not a third new collection.

| Retained family | Before → after | Source and remaining debt | Existing behavior oracle |
| --- | --- | --- | --- |
| type-system Set | 5 → 7 | Env Eq-only accepted fact plus scope snapshot; keyed by scoped source names, not TypeId | test_env scope/shadow/pop; test_type_header_graph accepted/graphless publication |
| type-system name member reads | 77 → 80 | Three symbol.name reads clear Eq on single/batch shadow | Same scoped evidence tests, import/alias and distinct-nominal controls |
| backend name member reads | 141 → 143 | Exact EnumType name joins EnumDecl; native status chooses required declared variant row | test_core_emit nonsequential tags/missing declaration/variant/scalar-recv rejection |
| backend def_id member reads | 42 → 43 | Require actual issued variant ID before constructor-symbol projection | test_core_emit missing-ID rejection; dynamic String channel owner |

Env facts are published once from accepted headers and read without rebuilding
variant shape. Eq is distinct from Hash and physical storage; merging it into
the containment cache would require new invalidation/generation semantics and
was rejected as scope expansion. The semantic String collections remain honestly
classified `legacy_source_shape`, not reclassified as display boundaries.

Core EnumType still carries a physical name, so declaration lookup retains
name-identity debt. Once the declared variant is selected, constructor emission
uses its issued ID, not a guessed native integer tag. Missing IDs fail closed.
The diagnostic signature helper owns no Dict parameter and retains signature
failure before original module/name validation, with unchanged diagnostic text.

Only four max_count values and the exact Env keys changed. Source revision,
schema, coverage, capabilities, allowed boundaries and every unrelated budget
are unchanged. Scanner, tests and magic allowlist are unchanged.

Static validation commands (no compiler/native build):

```sh
scripts/compiler-identity-census --check
scripts/check-magic-spellings --strict
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  blorp.test.test_build.test_compiler_identity_census \
  blorp.test.test_build.test_check_magic_spellings
git diff --check
```

Census: 3410 rows, within amended budgets. Magic: 508 allowlisted findings,
0 stale. Python: 47/47 (32 census + 15 magic). Raw packet:
`/tmp/blorp-scalar-publish-census.B7Gf3r`. Integrated macOS validation now passed
4739 changed checks, 83 selected runtime tests, strict added scalar-key controls
with zero residual, O2 fixpoint and stage2 audit 228/228. Linux quality/census
and broad tests 18696/18696 passed, but final Docker premerge **FAILED** at
sanitizers: incorrect callback function-pointer types (UBSan), then ASan CHECK
failure/SIGSEGV. Cause remains unclassified; no baseline attribution is made.
The user directed publication despite this disclosed failed sanitizer gate,
not as an overall green result. Exact commands, hashes and separate failed
preflight/retry epochs are retained in the
[integrated evidence](scalar_union_bootstrap.md#integrated-publication-state).
Earlier precursor gates remain historical; this amendment is still identity
debt, not identity improvement. Source and census were unchanged during validation.
Known current-main strict Dict leak remains unresolved (see the
[integration limitation](scalar_union_bootstrap.md#integrated-publication-state)).
