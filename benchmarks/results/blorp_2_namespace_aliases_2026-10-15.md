# Module aliases, qualified names and `private` (M1b part A)

Checkpoint 2a parsed `path as Alias`, `private` declarations, `Alias.name`
values and `Alias.Type[args]` types and rejected each until "the namespace
milestone". They are now namespace facts; the three rejections, their render
text and the fixtures that only pinned them are deleted. Base `origin/main`
`75fa1d3fe`, rebased onto `2f1c8af1e` (checkpoint 3 and M4 step 1) before landing.

## Facts and where they live

- **Alias rows.** `ModuleAlias { module, name, target, path }` is one row per
  import that writes `as Alias`, scoped to the importing module and carrying
  the written path for diagnostics (`ModuleImport` now keeps `path`). An alias
  is not a value or type: `module_alias(namespace, module, name)` is the only
  query. A repeated alias in one module is `RepeatedModuleAlias`; an alias
  equal to a declared or imported name of its module is
  `ModuleAliasNameConflict` (GUIDE, Qualified Imports: an alias "cannot reuse a
  name that already means something else"). Each module is imported once
  (GUIDE, One Import Per Module), so `int as A` + `int as B`, and `int as
  IntOps` + `int: add`, stay `module imported more than once`; the accepted
  form is one row, `int as IntOps: add`, and its help now says so.
- **Visibility.** `Visibility` is stored on the namespace's declared rows
  (functions, declared types, variants carry their union's). It is consulted in
  exactly three places, all in the namespace: import selection
  (`PrivateImportSelection(name, path)`: `secret is private to ./hidden` /
  `remove private or import a public declaration`), qualified resolution
  (`PrivateQualifiedName`), and the set a method selection may bind:
  `exported_functions(namespace, module)` publishes a module's public
  functions and `build_callables` binds receiver methods from that set only,
  so `make_holder(3).secret_value()` is `unknown function` for an importer
  (by type selection or `methods_only`) while `shown()` binds. Within its
  module a private declaration is unchanged. Declared and forwarded type
  rows are one table: `TypeBinding.origin` is `DeclaredType(Visibility)` or
  `ImportedType`.
- **Qualified resolution.** `plan_base`'s `QualifiedName`/`QualifiedApplication`
  arms and `resolve_type`'s `QualifiedType` arm resolve `{ module, name }`
  through the alias row, then the target module's *own* declarations
  (`qualified_function`, `qualified_variant`, `qualified_type` return
  `ExportedDeclaration | PrivateDeclaration | NoDeclaration`); forwarded
  imports are never exported ("imports are not reexported"). A qualified
  function is a direct call through the same `function_contract` as a bare
  call; a qualified constructor builds that union's variant through
  `plan_qualified_variant`, taking a generic union's arguments from the
  expectation exactly as a bare constructor does and otherwise reporting
  `constructor needs an expected union type`; a qualified type reuses the
  atomic/applied candidate resolution shared with bare types. Nothing splits
  a spelling.
- **Exact rejections.** `H is a module alias` / `write H.name to use a
  declaration of that module`; `module ./hidden declares no public missing` /
  `H names module ./hidden; qualify a public function, constructor or type it
  declares; imports are not reexported`; `H.visible names a function` / `call
  it with arguments; a function is not a value`; `unknown module alias Shared`
  / `add path as Shared to the import block` (types only: in values the parser
  mints a qualified name only under a declared alias).

## Fixtures (`blorp_2/test/e2e/fixtures/namespace/`)

Shared modules `shapes.brp` (union, flag union, record, public and private
functions) and `hidden.brp` (private record and function, public wrapper).

| Fixture | Behaviour | Exact stdout / diagnostic |
| --- | --- | --- |
| `alias_call.brp` | `IntOps.add` / `IntOps.to_string` | `3` |
| `alias_constructor.brp` | `S.Circle(2)`, `S.Square(3)`, nullary `S.On` through `S.area`/`S.flag_value` | `12 9 1` |
| `alias_type.brp` | `S.Span` in a signature, `S.make_span` | `5` |
| `combined_import.brp` | `./shapes as S: area, Flag(On, Off)` | `12 0` |
| `private_local.brp` | private function called in its module, directly and via public wrappers | `42 7 7` |
| `public_method.brp` | `make_holder(3).shown()` by type selection | `3` |
| `private_method.brp` | `make_holder(3).secret_value()` by type selection | `4:20 unknown function` |
| `private_methods_only.brp` | the same through `Holder methods_only` | `4:20 unknown function` |
| `private_selection.brp` | `./hidden: secret` | `2:15 secret is private to ./hidden` |
| `private_type_selection.brp` | `./hidden: Point` | `2:15 Point is private to ./hidden` |
| `private_qualified.brp` | `H.secret()` | `4:7 secret is private to ./hidden` |
| `unknown_qualified.brp` | `H.missing()` | `4:7 module ./hidden declares no public missing` |
| `bare_alias.brp` | `value = H` | `4:13 H is a module alias` |
| `qualified_not_called.brp` | `value = H.visible` | `4:13 H.visible names a function` |
| `two_aliases.brp` | `int as A` + `int as B` | `3:5 module imported more than once` + note `2:5` |
| `alias_and_plain.brp` | `int as IntOps` + `int: add` | `3:5 module imported more than once` + note `2:5` |
| `alias_conflict.brp` | `./shapes as Shape: Shape` | `2:17 module alias reuses a visible name` + note `2:24` |
| `unknown_qualified_type.brp` | `Shared.Span` without an alias | `1:23 unknown module alias Shared` |

Stdout values are one per line. The six accepted fixtures measured at most 16,627
pilot allocations and 75.9M retired instructions on the final base; the
group's shared ceiling is 19,000 / 88M (about 14% above the maximum).

## Tests

- Namespace (`test_namespace/test_aliases.brp`, 8): exported functions omit
  private declarations while the private function stays locally visible; the alias row's module,
  target and path; qualified lookups distinguishing exported, private and
  missing for functions, variants and types while the private function stays
  locally visible; private function/type selections rejected at the selection;
  an alias reusing a selected name or a local declaration; a repeated alias
  across two modules.
- Checker (`test_check/test_qualified_names.brp`, 12): a type selection binds
  public methods only; qualified call as a
  direct call; qualified payload and nullary constructors; qualified record
  type in a signature; qualified generic constructor with and without an
  expectation; private function/type, unknown name, bare alias, uncalled
  function and unknown type alias, each with exact message, help and span.
- E2e: the fifteen fixtures above.

Four mutations each fail exactly their oracle and nothing else: exporting
private functions to method selection fails the exported-functions namespace
test and the public-methods-only checker test; ignoring
visibility at import selection fails the two private-selection tests;
removing the alias/visible-name conflict check fails the two alias-conflict
tests; resolving a qualified private function as unknown fails the
private-qualified test. Sources were restored from a snapshot and
`cmp`-checked.

## Identity, gate and frontier

**Identity.** Baseline pilot built from `2f1c8af1e`
(`e3226f85b23fcea345bc27848035e31e3c94e003f82ef505d6002ee2272b2617`, generated C
`3dd18687fecc66d281348659357fa81dcaf509204f560d94d77e5c9dd4e71f7d`) against its
own temp library; candidate from this commit
(`d98b056a35afe27444e46e4433aa0a03ec72bfc27a6a1f8a58ae0d023540072d`, generated C
`201fdb73f472c7714c6037a421aada95316ca79951d28a661747f99d2dc94d24`).
`scratchpad/ml/identity.sh` compiles every e2e fixture with each pilot, builds
the accepted C with `-std=c11 -Wall -Wextra -Werror -pedantic -O0` and runs
it. All **385** pre-existing fixtures (391 at `2f1c8af1e` less the six deleted
`unsupported/` fixtures that only pinned the removed rejections) are
byte-identical in generated C, compile exit/stdout/stderr and native
exit/stdout/stderr; the only diff headers are the new `namespace/` fixtures.
The same held against baselines from `75fa1d3fe`, `59f2d40c2`, `df76dab1d`,
`f453bedee` and `0b67aa921` at each rebase.

**Gate.** On the rebased commit, `env BLORP_2_INSTRUCTION_CHECK=required make
-C blorp_2 test`: exit 0 with no failures; **2,582 unit/runtime/grammar
callbacks and 406 e2e cases pass** (log `scratchpad/ml/logs/full-gate-ns6.log`;
the harness's nested `[PASS]` lines are not additional cases). The namespace
group's maximum is 16,627 allocations / 75.9M instructions under 19,000 / 88M.

**Frontier.** Compiling each of the pilot's 34 own source files as a root with
`--library-root blorp_2/standard_library_temp`, before and after: the first
error is lexical for 22 (`unsupported character`), a parse error for 10
(`expected a newline after the return expression` 6, `expected a return
expression` 3, `expected ')' after the grouped expression` 1), and only
`runtime/float.brp` and `runtime/string.brp` reach the checker, where both
stop at `expected a main function` (they are not roots). The namespace
frontier is therefore unchanged by this part: 0 of 34 files pass the checker
before and after, because every file first hits syntax the lexer and parser
do not accept yet (`test_parse/test_source_tree` is parse-only and
unaffected). Per-file lists:
`scratchpad/ml/frontier/{baseline,candidate}.txt`.

## Follow-ups

- `build_callables` scans the namespace's exported set linearly per method
  request; the namespace could publish function rows with their visibility
  directly.
- `plan_qualified_variant` keeps the `called: Bool` flag of its bare
  precedent (`plan_variant`); a closed form would replace both together.
- The declaration of a variant is read in one place
  (`declared_variant_contract`); the bare path filters by visibility through
  `variant_candidates`, the qualified path by the namespace's
  `qualified_variant`.
