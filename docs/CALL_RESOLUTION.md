# Call and Name Resolution

This document describes how Blorp currently resolves names and calls, where
purity is attached today, and how we should move toward a single semantic
resolution model shared by `check`, `compile`, and semantic tools such as
`purify`.

`format` is intentionally different. It should remain parse/print oriented so it
can work on partial or semantically invalid source. It should not require module
loading, type inference, overload resolution, or purity checking.

## Current Model

The surface AST keeps ambiguous source forms:

- `EIdent name`
- `EFieldAccess(obj, field)`
- `ECall(callee, args)`

After inference, expression metadata records types, proofs, and transitional
optional resolved-call facts:

- `expr_type_info.semantic_ty`
- `expr_type_info.value_ty`
- `expr_type_info.proofs`
- `expr_type_info.resolved_call`

Function identity and purity are spread across several structures:

- `Env.FuncSymbol`: visible functions in lexical/import scope, with a
  `callable_id`, function type, type parameters, purity, origin, module path,
  dimension constraints, and debug-only status.
- `Env.overload_entry`: overload candidates, with `ol_def_id`,
  `ol_func_type`, `ol_purity`, `ol_module_path`, constraints, and other
  signature data.
- `env.overloads`: bare-name overload candidates.
- `env.ufcs_methods`: method-only candidates enabled by imported types and
  prelude types.
- `Ast.TyFunc.is_pure`: function type purity.
- `Builtin_metadata`: builtin effect metadata.
- Trait method signatures and impl methods: purity exists on trait method
  signatures and on the concrete functions in impl blocks.

The important consequence: inference performs the most precise source-level
selection, but only part of that selection is currently preserved as a
structured fact for later tools. Purity analysis can consume `resolved_call`
where inference has attached it, while Core resolution and remaining fallback
paths still re-read names, types, module aliases, and mangled strings.

## Imported Names

Import handling lives mostly in `compiler/lib/typecheck.ml`.

### Selective Imports

Example:

```blorp
import:
    list: map
```

The type checker:

1. Loads the module.
2. Verifies the symbol is exported.
3. Registers the local imported name, rejecting collisions with previous
   imports, module aliases, and top-level declarations.
4. Adds the exported declaration to `Env` through `process_imported_decl`.
5. Registers imported functions as overload entries when they come from a
   module.

Imported functions become bare-name call candidates. Their purity comes from the
imported function declaration and is stored both in the function type and the
environment entry.

### Qualified Imports

Example:

```blorp
import:
    dict as D
```

The alias is stored in `state.module_aliases` and `import_bindings`. It is not a
runtime value. Today inference represents the alias object in typed field access
with a sentinel `TyNamed("Module", [])` so later lowering can preserve
`D.func`.

### Type Imports and Method-Only UFCS

Example:

```blorp
import:
    heap: Heap
```

When a type is imported without an alias, the type checker scans that module for
exported functions whose first parameter head matches the imported type. Those
functions are registered in `env.ufcs_methods` as method-only entries. They are
available as `value.method(...)`, but not as bare `method(value, ...)` unless the
function itself was explicitly imported.

Prelude setup uses the same mechanism for core types such as `Option`, `Result`,
`String`, `List`, `Dict`, `Set`, `Bytes`, and primitive families. This is why
prelude type methods work without an explicit import.

Each UFCS candidate carries an overload entry with a purity field. Pure and
impure overloads can coexist.

## Bare Identifier Resolution

Identifier inference is in `compiler/lib/infer.ml`.

For `name`, inference checks:

1. `Env.VarSymbol`: normal variables, parameters, and top-level variables.
2. `Env.FuncSymbol`: functions in scope.
3. Constructors:
   - Nullary constructors resolve to their parent type.
   - Constructors with fields resolve to a pure function type.
4. Trait method names, if known through trait metadata.
5. Otherwise, an undefined identifier error.

Only function-like identifiers can be called. Purity for a bare function comes
from the resolved `TyFunc.is_pure` and from the matching environment entry.

## Bare Calls

Example:

```blorp
f(a, b)
```

The main call dispatcher is `infer_call` in `compiler/lib/infer.ml`.

For `ECall(EIdent name, args)`:

1. Builtin-specific inference may run first for compiler-owned builtins.
2. The callee expression is inferred to a function type.
3. If the name has overload entries and is not a local function, overload
   selection runs:
   - Prefer a full argument-vector match when argument types are known.
   - Otherwise try first-argument-head matching.
   - Higher-order overloads use callback purity as a tiebreaker.
   - Flexible lambdas can delay selection so the expected pure callback type can
     upgrade the lambda to pure.
   - If still ambiguous for a pure/impure pair with the same receiver type, the
     current function's purity biases the choice.
4. Trait-method dispatch for type-parameter receivers can replace the callee
   type with the trait method signature.
5. Argument checking instantiates generics, checks trait bounds, validates
   dimension constraints, and computes the return type.

The resulting typed AST still looks like a call to an identifier, with type
metadata on the callee and whole expression. The generic call path now also
stores resolved-call metadata for direct calls and closure calls after overload
selection and argument checking have completed.

## Qualified Calls

Example:

```blorp
D.set(d, "key", 1)
```

This parses as `ECall(EFieldAccess(EIdent "D", "set"), args)`.

In call inference:

1. If the left side is a module alias and the field names a trait impl method in
   that module, inference can rewrite directly to the impl method's mangled
   function name.
2. If the left side is a module alias and the field names a top-level exported
   function, inference resolves the module function before generic field access
   can treat the alias as a value receiver.
3. Otherwise field-access inference handles module aliases:
   - Look up exported functions in the target module.
   - Look up exported variables in the target module.
   - Preserve `EFieldAccess` for qualified codegen paths.
4. If the module has no top-level function by that name, inference also tries
   module-qualified impl method dispatch based on the first argument type.

Purity comes from the looked-up module function type, builtin metadata, or the
impl method signature. Module-qualified impl method calls carry structured
trait-method metadata on the typed call. Ordinary qualified top-level module
function calls carry direct callable metadata when the target module has a typed
AST in the module cache; parsed export fallback still provides only type and
purity, not a stable callable id.

## Method Calls

Example:

```blorp
xs.map(f)
```

This also parses as `ECall(EFieldAccess(xs, "map"), args)`.

The current priority is:

1. Try ordinary field access first. This lets tuple fields, record fields, and
   function-valued fields keep their meaning.
2. If field access fails and the receiver is a value, rewrite method syntax into
   a function call shape by prepending the receiver:

   ```blorp
   xs.map(f)
   map(xs, f)
   ```

3. Try a normal in-scope function named `map`. It is accepted only if the first
   parameter can accept the receiver type.
4. If the normal function is absent or does not match the receiver, try
   `env.ufcs_methods` for method-only candidates registered from imported types
   or prelude types.
5. Select among UFCS overloads using argument types, callback purity, and
   current function purity.
6. Current implementation encodes a selected UFCS overload as a synthetic
   identifier:

   ```text
   __ufcs_<module_path>__<method>#<ol_def_id>
   ```

   `core_lower` strips the `#<id>` into `Core.Var.vdef_id`.

Purity comes from the selected normal function or selected UFCS overload entry.
When no single UFCS overload is selected, inference temporarily registers the
candidate set under the synthetic name and lets normal call inference continue.

## Implicitly Imported Methods

Implicit methods are not a separate call form. They are UFCS method-only
candidates in `env.ufcs_methods`.

There are two sources:

- Type imports: importing `Heap` from `heap` registers exported heap functions
  whose first parameter is `Heap`.
- Prelude setup: core types have their module methods registered before user
  code is checked.

These methods are intentionally unavailable as bare names. Calling
`map(xs, f)` still requires importing `map`; calling `xs.map(f)` can work from
the method-only table.

Purity is stored per overload entry. Pure and impure method overloads can coexist
and are selected at call sites.

## First-Class Calls

Example:

```blorp
f(x)
```

where `f` is a parameter or variable with function type.

The callee expression infers to `TyFunc`. The call checker uses that function
type directly. Purity comes from `TyFunc.is_pure`.

Purity analysis treats a non-identifier callee as pure only when the callee
expression's semantic type is a pure function type.

## Trait Methods and Operators

Trait support spans inference and Core:

- During inference, trait method names can provide function signatures,
  including purity.
- Calls on type variables with trait bounds can be typed using the trait method
  signature.
- Module-qualified impl methods can be resolved during inference.
- After monomorphization, `core_trait_resolve.ml` rewrites concrete trait method
  calls and overloadable operators to the matching impl function.
- `core_resolve.ml` later tags the call kind as user, foreign, builtin,
  closure, constructor, or unresolved.

This split works for codegen, but it means source-level semantic tools cannot
currently ask one shared question such as "which callable does this call target?"
and get a complete answer.

## Current Purity Checking

`check_purity` runs after inference. It walks the typed AST with
`Purity_analysis.collect_impure_calls`.

It rejects:

- Calls to impure functions from pure functions.
- Pure functions with impure callback parameters.
- Pure functions mutating module-level mutable variables.
- Debug-block violations.
- Concurrency boundaries where purity rules require rejection.

The call walker now first consumes `expr_type_info.resolved_call` when inference
has attached it. That metadata is authoritative for resolved calls. `purify`
can pass temporary pure assumptions by concrete callable id while testing local
candidates, so candidate overlays do not re-resolve selected calls by source
name. Impure-call references also retain the selected callable id when resolved
metadata identifies a direct function or concrete impl method. The older
`prefer_env_purity` bridge now applies only to calls without resolved metadata,
where the typed tree still lacks a semantic target. Calls without resolved
metadata still fall back to reconstructing purity from several sources:

- Module-qualified calls inspected through cached module exports.
- Builtin metadata.
- Callee `TyFunc` metadata.
- `Env.FuncSymbol.purity`.
- Overload and UFCS tables.
- Callback argument types.

This is the same conceptual information used by call inference, but not the same
structured result. That duplication is shrinking as call metadata coverage
improves, but remaining fallbacks are still a drift risk for tools like
`purify`.

`purify` currently has one conservative bridge toward the future model: it
refuses source rewrites for overloaded names because the rewrite step still
targets declarations by a source location key under the unique-name guard.
It now enters through the typed module-check boundary, then takes the
compatibility AST view only for the existing source-rewrite walker. Internally,
candidate viability and dependency pruning are keyed by callable id, and those
candidate ids come from typecheck's declaration-location table rather than
`Env.lookup name`. Candidate pure-assumption overlays also carry the checked
signature directly instead of reconstructing it from a name lookup. This lets
mutually recursive pure functions be rewritten as a group without
reinterpreting resolved calls by source name. The local dependency walker shares
the purity-analysis call traversal, so it does not treat calls inside uninvoked
impure lambdas as work performed by the enclosing function. The unique-name
guard remains intentional because the current typechecker rejects same-name
same-purity function declarations; purifying one sibling of a pure/impure
overload pair would make the rewritten file invalid.

## Core Call Resolution

Core lowering initially emits calls with `CKUnknown`. Later passes resolve them:

- `core_trait_resolve.ml` rewrites concrete trait methods and overloadable
  operators.
- `core_resolve.ml` tags calls as foreign, user, builtin, constructor, closure,
  import alias, UFCS, or unknown.

This is a backend call-kind resolver. It is not a replacement for source-level
name resolution because it runs after inference, lowering, monomorphization, and
some call rewriting. Source tools such as `purify` need earlier semantic facts.

## Problems With The Current Shape

The current design works in many cases, but it leaves illegal or ambiguous
states representable:

- A typed `ECall` can exist without a resolved callable identity.
- A function declaration is often identified by source name, which is wrong for
  pure/impure overload pairs and imported overloads.
- UFCS overload identity is encoded in a string suffix instead of a typed field.
- Module aliases are represented as expressions with a fake `Module` type.
- Purity exists in several places that can disagree.
- Purity analysis re-resolves calls after inference instead of consuming the
  inferred call target.
- Core performs another name-based resolution pass after lowering.

These issues are directly related to `purify` bugs:

- Overload pairs cannot be safely keyed by function name.
- Mutually recursive purity requires a call graph over function identities, not
  names.
- Re-resolving calls in a separate purity walker risks false positives and false
  negatives.

## Proposed Global Model

The semantic compiler should introduce a single source-level resolution layer
that produces explicit identities and resolved call targets.

Current migration status: `Ast.expr_type_info` now has optional
`resolved_call` metadata. The generic call-inference path populates it for
direct calls and closure calls after argument checking has computed instantiated
parameter and return types. Early-dispatched specialized builtins that remain as
call expressions are wrapped at the dispatch boundary so they get the same
metadata; debug reflection builtins that constant-fold to literals intentionally
have no call metadata because no call remains in the typed AST. Constructor
calls now carry constructor callable ids, trait-method calls on bounded type
parameters are represented as deferred trait dispatch with known purity,
module-qualified concrete impl method calls carry trait-method metadata with a
concrete callable id when typed module metadata is available while preserving
the same mangled implementation callee for Core, and typed module-qualified
top-level function calls carry direct imported callable metadata.
`Purity_analysis` consumes metadata where present, preserving callback-specific
diagnostics for HOFs and retaining the old name/type/env fallback for
unannotated call paths. Parsed-export fallback for qualified functions still
needs coverage before purity checking can rely on resolved-call metadata
exclusively.

### Stable Callable Identity

Every callable declaration should get a stable identity before body checking:

```ocaml
type callable_id = private int

type callable_kind =
  | Local_function
  | Imported_function of module_path
  | Builtin_function of builtin_id
  | Foreign_function of foreign_id
  | Constructor_function of type_id
  | Impl_method of impl_id
  | Closure_value

type callable_sig = {
  id : callable_id;
  source_name : string;
  canonical_name : string;
  kind : callable_kind;
  purity : purity;
  params : type_expr list;
  return : type_expr;
  type_params : type_param_decl list;
  dim_constraints : (type_expr * type_expr) list;
}
```

The key invariant: if code has a callable signature, it has exactly one callable
identity and exactly one purity. The function type can be derived from the
signature instead of duplicating purity in several places.

### Explicit Call Targets

Typed AST should distinguish unresolved syntax from resolved calls. Parsed AST
can keep `ECall(callee, args)`, but typed AST should expose variants such as:

```ocaml
type call_syntax =
  | Bare_call
  | Qualified_call of module_path
  | Method_call
  | Method_only_ufcs
  | Trait_dispatch
  | Constructor_call
  | Closure_call

type resolved_call = {
  target : callable_id option;
  syntax : call_syntax;
  callee_sig : callable_sig option;
  instantiated_params : type_expr list;
  instantiated_return : type_expr;
  receiver : expr option;
}
```

For direct calls, `target` is `Some id`. For closure calls, `target` can be
`None`, but the callee expression must have a `TyFunc` and its purity is known
from that type.

The key invariant: after typecheck, a direct call cannot be represented without
its target, and a closure call cannot be represented without a function-typed
callee.

### One Resolver API

Move name and call selection behind a resolver API used by inference:

```ocaml
val resolve_ident :
  env -> string -> loc -> resolved_name result

val resolve_qualified :
  env -> module_alias:string -> member:string -> loc -> resolved_member result

val resolve_call :
  env -> call_syntax_hint -> callee:expr -> args:expr list -> loc ->
  resolved_call result

val select_overload :
  env -> callable_sig Nonempty.t -> arg_types:type_expr list ->
  context_purity:purity -> overload_selection result
```

The resolver should return structured ambiguity and not-found errors instead of
falling back to strings.

### Phase-Specific Types

Use phase-specific data so illegal states cannot cross boundaries:

- Parsed AST: syntax only, names unresolved.
- Typed AST: names and direct calls resolved, types checked.
- Core IR: no source-level overload ambiguity, no module alias sentinel values,
  no UFCS identity encoded in strings.

This lets `format` keep using parsed AST, while `check`, `compile`, and `purify`
consume typed semantic facts from the same pipeline.

### Purity From Resolved Calls

Purity checking should stop re-resolving call names. It should inspect
`resolved_call`:

- Direct call: read `callable_sig.purity`.
- Closure call: read the callee function type purity.
- Constructor call: pure.
- Builtin call: purity is part of the builtin callable signature.
- Trait or impl method call: purity is part of the selected callable signature.

Then `purify` can build a graph over `callable_id`, not strings.

### Purify Algorithm Under The Global Model

`purify` should use the same semantic program as `check`:

1. Typecheck the source and obtain typed declarations with callable IDs.
2. Collect local impure blockers:
   - explicit impure foreign/builtin/bodyless declarations
   - impure callback parameters
   - global mutation
   - concurrency boundaries
   - unresolved or closure calls whose function type is impure
3. Build a call graph over `callable_id`.
4. Compute strongly connected components.
5. Mark an SCC purifiable when:
   - every function in it has no local blocker
   - every outgoing direct call targets an already pure callable or another
     purifiable SCC
   - every closure call is typed pure
6. Rewrite declarations by callable ID and source span, not by name.

This fixes overload pairs and mutual recursion together.

## Implementation Roadmap

This migration should be additive first. The early phases should not change Core
IR, generated C, or runtime behavior. They should only make the semantic facts
that inference already knows observable and testable. Later phases can remove
the duplicate name-based fallbacks once the structured path is complete.

### Phase 0: Lock Down Current Behavior

Goal: build a regression net before changing resolution internals.

Work:

- Add focused tests that cover each call shape:
  - local bare function call
  - local pure/impure overload pair
  - selective import bare call
  - qualified module call
  - module-qualified impl method call
  - record field call and tuple field access
  - normal UFCS through an explicitly imported function
  - method-only UFCS from a type import
  - method-only UFCS from prelude registration
  - pure/impure higher-order overload with a flexible lambda
  - first-class closure call
  - constructor call
  - trait method call on a generic type parameter
  - concrete trait method call after monomorphization
- Add purify regressions for:
  - overload pairs
  - mutually recursive pure functions
  - method-only UFCS
  - qualified calls
  - first-class pure and impure callbacks
- Record a generated-C or Core snapshot for representative UFCS and overload
  cases so later phases can prove "metadata-only" changes do not alter IR.

Invariants:

- No new resolution model yet.
- Existing `check`, `compile`, `run`, and `purify` behavior remains unchanged
  except for known failing fixtures that document current bugs.

Validation:

- `scripts/test compiler`
- `make unit-test`
- Targeted runtime tests for any fixture that reaches Core/codegen.

IR impact: none.

Rollback point: discard tests or mark known bugs as expected-fail if a smaller
urgent fix has to land first.

### Phase 1: Introduce Semantic Identities

Goal: give every callable a stable semantic identity before bodies are checked.

Current state:

- `Env_types.def_id` and `Session.mint_def_id` already exist.
- `Env.overload_entry.ol_def_id` already identifies overload entries.
- Normal `Env.FuncSymbol` entries now carry a `callable_id`.
- Core functions have their own `cf_def_id` lifetime and reset behavior. Do not
  assume Core ids and source semantic ids are the same thing until the bridge is
  explicit.

Work:

- Add a small semantic identity module, or make the existing `def_id` role
  explicit enough to use for source callables.
- Extend `Env.FuncSymbol` with a callable id. Done for normal function symbols;
  remaining work is to thread that identity through every function-like
  registration path and call-site result.
- Extend constructor, builtin, foreign, and impl-method registrations so they
  can expose a callable id when they behave like functions. Constructor symbols
  now expose callable ids; typed impl methods now retain callable ids for
  concrete source-level handoff.
- Decide whether `ol_def_id` becomes the callable id or points to one. The
  important invariant is that overload selection returns the same id that a
  direct function lookup would return for the same callable.
- Store source spans for local callable declarations so source transforms can
  rewrite by identity instead of by name.

Invariants:

- A callable signature cannot exist without an id.
- Two pure/impure overloads with the same source name must have different ids.
- Re-registering the same imported callable must be idempotent or must preserve
  a canonical id.
- Callable ids are stable within one semantic pipeline run. Cross-run stability
  is not required for now.

Validation:

- Unit tests around registration and lookup.
- Tests proving local functions, imported functions, overload entries, UFCS
  entries, constructors, and impl methods all expose ids.

IR impact: none. Lowering still ignores the ids.

Rollback point: ids can remain unused metadata if later phases need to pause.

### Phase 2: Add Resolved-Call Metadata

Goal: attach the result of call resolution to typed calls without changing how
calls are lowered.

Work:

- Add a typed metadata shape for calls:
  - direct callable id and signature
  - closure call with callee function type
  - deferred trait dispatch with trait method purity
  - compiler-specialized builtin with known purity
  - syntax origin: bare, qualified, method, method-only UFCS, constructor,
    trait, closure
- Store optional resolved-call metadata on expression type information. Done
  for the initial generic-call path and for specialized builtin paths that still
  produce call expressions; constructor calls, bounded-type-parameter trait
  dispatch, module-qualified concrete impl method calls, and typed
  module-qualified top-level function calls are covered. Concrete
  module-qualified impl-method calls also carry a callable id when the module
  has typed metadata. Keep it optional while parsed-export qualified fallback is
  migrated.
- Attach this metadata at the end of `infer_call`, after argument inference and
  overload selection have completed.
- Preserve the current AST expression shape, including existing UFCS synthetic
  names, so Core receives the same input as before.
- Add helper queries such as:
  - `Ast.resolved_call_purity` (done)
  - `Ast.resolved_call_direct_callable_id` (done)
  - `Ast.resolved_call_concrete_callable_id` (done)
  - `Ast.expr_resolved_call` (done)
  - `Ast.expr_concrete_callable_id` (done)
  - `Typed_ast.expr_resolved_call` (done)
  - `Typed_ast.expr_call_purity` (done)
  - `Typed_ast.expr_direct_call_id` (done)
  - `Typed_ast.expr_concrete_callable_id` (done)
  - `Typed_ast.walk_calls`

Invariants:

- A typed direct call has exactly one callable id.
- A typed closure call has no callable id, but its callee type is `TyFunc`.
- A typed deferred trait call has known purity even if the concrete impl target
  is chosen after monomorphization.
- A typed compiler-specialized builtin has known purity even if Core keeps a
  later `CKUnknown` path for specialization.
- No ordinary typed call is represented as "unknown source resolution".

Validation:

- Unit tests that inspect typed AST metadata.
- Negative tests for ambiguous overloads and missing UFCS methods.
- Generated Core/C snapshots unchanged from Phase 0.

IR impact: none by design.

Rollback point: metadata can be ignored by all consumers while existing paths
continue to work.

### Phase 3: Centralize Resolver Code

Goal: separate call selection policy from the large `infer_call` body without
changing behavior.

Work:

- Extract candidate gathering and overload selection into a resolver module.
- Keep inference responsible for bidirectional typing, lambda expected types,
  generic instantiation, and argument checking.
- Make resolver results explicit:
  - `Resolved_direct callable_sig`
  - `Resolved_closure`
  - `Resolved_deferred_trait`
  - `Resolved_specialized_builtin`
  - `Resolution_error of structured_error`
- Keep flexible-lambda handling intact. If lambda purity cannot be known before
  expected-argument inference, represent the candidate set explicitly and
  finalize after the lambda has been checked against the chosen parameter type.

Invariants:

- Resolver APIs do not return bare strings for successful direct call targets.
- Ambiguous overloads stay errors, not "pick first" fallbacks.
- Module aliases are resolved as module aliases, not as fake values.
- Method-only UFCS candidates cannot leak into bare-name lookup.

Validation:

- Existing compiler suite.
- Focused unit tests for overload selection and UFCS candidate filtering.
- Diff selected Core snapshots against Phase 0.

IR impact: none intended.

Rollback point: if extraction becomes too large, keep only the typed metadata
from Phase 2 and delay this refactor.

### Phase 4: Move Purity Checking To Resolved Calls

Goal: remove name re-resolution from purity checking.

Work:

- Change `Purity_analysis.collect_impure_calls` or replace it with a typed-call
  walker that consumes resolved-call metadata. Initial opportunistic consumption
  is done; fallback remains active for unannotated calls.
- For each call:
  - direct callable: use the callable signature purity
  - closure: use the callee `TyFunc.is_pure`
  - constructor: pure
  - deferred trait: use trait method purity
  - compiler-specialized builtin: use builtin purity
- Keep the old walker temporarily as an assertion or diagnostic fallback only.
  Resolved-call metadata is now authoritative; `purify`'s temporary pure
  assumptions are keyed by callable id for resolved direct/concrete impl calls.
  Impure-call refs carry that callable id where the typed call target is known.
  If old and new disagree, report a compiler-internal diagnostic in tests before
  deleting the fallback.

Invariants:

- A pure-function purity error cites the resolved target.
- Pure/impure overload pairs are checked by selected callable id.
- Qualified calls and method-only UFCS calls are not reinterpreted by a separate
  name lookup.

Validation:

- Existing typecheck purity tests.
- New tests where name-based analysis used to be wrong:
  - same-name pure/impure overloads
  - method-only UFCS calls
  - module-qualified impl methods
  - flexible lambdas passed to HOF overloads

IR impact: none.

Rollback point: old purity walker can remain active while metadata coverage is
completed.

### Phase 5: Rebuild `purify` On Semantic Facts

Goal: make `purify` a consumer of the same typed semantic facts as `check`.

Work:

- Build a function table keyed by callable id, not source name. Initial
  `purify` candidate/dependency bookkeeping is now callable-id keyed; source
  rewrites now convert the final id set to declaration location keys under the
  current unique-name guard. Candidate ids are read from the typecheck state by
  declaration location instead of from name lookup, and candidate signature
  overlays are carried with the candidate instead of looked up by source name.
- Run `purify` through `Pipeline.typecheck_module_only_typed`, deriving the
  compatibility AST view explicitly only for the current rewrite walker.
- Reuse the shared purity-analysis call traversal for dependency discovery so
  lambda-body traversal follows the same rules as purity checking.
- Build a call graph from resolved direct calls.
- Treat calls to external pure functions as satisfied leaves.
- Treat calls to external impure functions, impure closures, global mutation,
  concurrency, impure callback parameters, foreign declarations, and bodyless
  non-builtin declarations as local blockers.
- Compute strongly connected components over local callable ids.
- Mark SCCs purifiable when all internal functions are locally pure and all
  outgoing edges are already pure or purifiable.
- Rewrite source declarations by callable id and source span.
- Keep the source reparse/comment-preservation path from the current purify fix.

Invariants:

- A rewrite never selects declarations by name alone.
- Pure/impure overload pairs can be purified independently only if the language
  permits same-name same-purity overloads, or if `purify` has a migration rule
  for that policy. Today the unique-name guard intentionally leaves them alone.
- Mutual recursion is handled as a group.
- The rewritten file must typecheck before writing.
- Failed rewrite validation must leave the original file unchanged.

Validation:

- `purify/should_purify`, `purify/should_not_purify`, and
  `purify/should_rewrite` fixtures.
- New fixtures for overload pairs and mutual recursion.
- Manual probes on real `std/` modules in dry-run mode.

IR impact: none, except files that users intentionally rewrite with `purify`
may later compile with explicit `pure` annotations.

Rollback point: current `purify` implementation remains usable until this phase
fully passes its fixtures.

### Phase 6: Carry Callable Identity Into Core

Goal: remove string-encoded source identity from the typed-AST-to-Core boundary.

Work:

- Add optional callable identity to Core call callee variables or call nodes.
- Lower typed resolved calls into Core with explicit identity metadata.
- Replace the `__ufcs_...#<id>` handoff with structured metadata.
- Preserve existing mangled names until Core emit is updated to prefer ids.
- Keep `CKUnknown` only for genuine backend specialization paths, not ordinary
  unresolved source-level calls.

Invariants:

- A source-resolved user call entering Core carries its callable id.
- UFCS identity is not parsed out of a string.
- Import alias and module-qualified calls do not need Core to redo source-level
  lookup when the typed layer already selected a target.
- Compiler-specialized builtins remain representable as deferred backend work.

Validation:

- Core golden tests for UFCS, imports, overloads, and trait calls.
- Generated C diff against pre-phase snapshots for unchanged programs.
- Runtime tests for std collection/text methods and HOF overloads.

IR impact: yes, but intended to be metadata-first. Core pretty output may
change once ids are printed. Generated C should not change until emission starts
using the ids.

Rollback point: keep old string path active behind an assertion until Core
identity metadata covers every call shape.

### Phase 7: Shrink Backend Name Resolution

Goal: make Core resolution a backend call-kind classifier, not a second
source-level resolver.

Work:

- Teach `core_resolve.ml` to prefer callable ids.
- Leave backend-specific choices there:
  - foreign vs user call kind
  - builtin runtime name
  - closure calls
  - constructor calls
  - compiler-specialized builtins
- Remove source-level fallbacks only after tests prove they are dead:
  - UFCS by first-arg type
  - import alias source-name lookup
  - module-path name reconstruction for calls already resolved by typed AST
- Keep diagnostics for any unexpected `CKUnknown` that is not a known
  specialization form.

Invariants:

- Core does not guess source semantics from names when typed metadata is
  available.
- Remaining `CKUnknown` cases are documented specialization hooks.
- No emitted C symbol depends on an ambiguous source name.

Validation:

- Full compiler and runtime suites.
- Codegen audit tests.
- Generated-C review for representative UFCS, overload, trait, constructor,
  foreign, builtin, and closure calls.

IR impact: yes. This is the first phase where Core semantics are intentionally
simplified around the new identity model.

Rollback point: leave removed fallbacks behind a feature flag or temporary
assertion branch until the audit suite is green.

### Phase 8: Make Illegal States Unrepresentable

Goal: remove transitional compatibility states.

Work:

- Split parsed and typed call variants so typed direct calls cannot omit a
  target.
- Remove module-alias sentinel expressions from typed AST.
- Remove string suffix parsing for UFCS ids.
- Delete purity re-resolution fallbacks.
- Add typed-AST invariant checks:
  - no direct call without target
  - no closure call without `TyFunc`
  - no module alias represented as a runtime value
  - no method-only UFCS candidate used as a bare call
  - no ambiguous overload candidate set after typecheck

Invariants:

- After typecheck, semantic tools never perform name resolution.
- After lowering, Core never receives source-level ambiguity.
- Every remaining backend unresolved call is explicitly marked as a backend
  specialization case.

Validation:

- Full test suite.
- Invariant checks enabled in CI paths that already run Core invariant checks.
- LSP definition/autocomplete can query the same resolved identity model.

IR impact: yes. This is the cleanup phase after behavior is already proven.

Rollback point: do not start this phase until `purify` and Core have both been
running on metadata for a while.

## Risk Register

- Flexible lambda overloads: choosing pure/impure HOF overloads too early can
  prevent lambdas from upgrading to pure. Keep a deferred candidate state until
  expected argument types are known.
- Trait dispatch: concrete impl targets may not exist until after
  monomorphization. Represent this as deferred trait dispatch with known purity,
  not as an unknown call.
- Compiler-specialized builtins: some calls intentionally stay late-bound for
  Core specialization. Mark them explicitly so they are not confused with failed
  source resolution.
- ID lifetime: semantic callable ids and Core emission ids have different
  lifetimes today. Bridge them explicitly instead of assuming one counter can
  serve both phases.
- Imported module reuse: session-level overload and UFCS tables must preserve
  canonical ids when the same module is imported more than once.
- Diagnostics: structured resolution must keep or improve current error quality,
  especially "did you mean" suggestions and module-qualified overload errors.

## Milestones

The work can land in four larger milestones:

1. Metadata milestone: Phases 0-2. Typed programs expose resolved targets, but
   IR and behavior are unchanged.
2. Semantic-consumer milestone: Phases 3-5. Purity and `purify` consume typed
   resolution facts.
3. Core handoff milestone: Phases 6-7. Core receives callable identity directly
   and backend resolution stops redoing source lookup.
4. Cleanup milestone: Phase 8. Transitional string/name fallbacks are removed
   and invariant checks enforce the new model.

## Expected End State

The final shape should be:

- `format`: parse and print only.
- `check`: parse, load modules, resolve names and calls, infer types, enforce
  purity.
- `compile`: run the same semantic result as `check`, then lower to Core.
- `purify`: run the same semantic result as `check`, then apply a source
  transform based on callable IDs.

No semantic tool should need to ask "what does this name probably mean?" after
typecheck. It should ask the typed program for the already-resolved target.
