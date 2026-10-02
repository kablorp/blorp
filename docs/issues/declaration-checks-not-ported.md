# Declaration checks from the retired compiler were not ported

Status: open.

Several checks on declarations and headers that the retired compiler made have
no counterpart in the self-hosted checker; the Guide still states three of them
(parameter names, alias conflicts, timeout types), and the others guard
against ambiguity or late internal errors. Each program below is accepted by
`bin/blorp check`:

```
func greet(name: String) -> String:          -- the same function defined twice
	"hello " + name

func greet(name: String) -> String:
	"hi " + name
```

```
func my_custom_builtin(x: Int) -> Int:       -- `builtin` body outside the standard library
	builtin
```

```
func bad[elem](x: elem) -> elem:             -- Guide, Generics: parameter names start
	x                                        -- with a capital letter (also `Elem_Type`, `#n`)
```

```
import:
	fixed as Fixed                           -- Guide, Qualified Imports: "error: Fixed
                                             -- already names the Fixed type"
```

```
func main(args: List[String]) -> Int:
	concurrent(timeout: "5000"):             -- Guide: timeouts are Int milliseconds or Duration
		a = compute()
	0
```

A module whose public function exposes a private type
(`private record Config` returned by public `default_config()`) is also
accepted; an importer then cannot name the type it receives, and the existing
fixture reports a confusing mismatch between `Config` and
`.../leaky_types_mod.Config` instead.

The duplicate definition runs and silently uses the second body (`greet("x")`
prints `hi x`); the user `builtin` body fails late in Core with
`unsupported Core lowering shape: builtin function bodies require an explicit
marker`; the String timeout fails in Core lowering with `target: invalid Core
lowering type: concurrent timeout expected Int milliseconds or Duration, got
String`, which `check` never reaches.

## Where to look

- Duplicate definitions and `builtin` bodies: declaration collection in
  `stage_06_typecheck/decl.brp` (type declarations already reject a user
  `= builtin` in `headers/type_header_install.brp`).
- Type and dimension parameter names: `discover_implicit_type_parameters_in_type`
  and explicit parameter lists in `stage_06_typecheck/headers/callable_headers.brp`.
- Alias against a prelude type: the alias conflict checks in
  `stage_06_typecheck/state.brp` cover imported and top-level names but not
  prelude types.
- Concurrent timeout type: `lower_typed_optional_timeout` in
  `stage_08_core_lower/lower.brp` is where the timeout is first interpreted;
  the type belongs in typecheck.
- Private types in public signatures: no check exists.

## Fixtures (9)

Under `blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_fail/`:
`builtin_outside_std`, `module_builtin_outside_std`, `duplicate_func_same_purity`,
`generic_dim_param_lowercase`, `generic_type_param_lowercase`,
`generic_type_param_underscore`, `import_alias_shadows_builtin_type`,
`visibility_public_returns_private_type` (rejected only for the incidental
mismatch). Under `blorp/test/compiler/stage_06_typecheck/infer_fixtures/infer/should_fail/`:
`concurrent_timeout_type`.

## Acceptance

Each is rejected at typecheck with the pinned message or an equally specific
one with a help line, passes `run_blorp_check_fixtures.py`, and is marked
`-- RUN-BLORP-CHECK`. These checks are independent; they can land separately.
