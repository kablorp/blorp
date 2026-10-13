# Type imports, method visibility, and the target prelude

Status: implemented in `blorp_2`, including its target library and input fixtures.
This document records the current semantic contract. The original implementation
sequence and cost ceilings remain in the [committed design](https://github.com/kablorp/blorp/blob/4b05ea3b431d9fbe4e906a0802bd41060b6f397f/blorp_2/IMPORTS_AND_PRELUDE_PLAN.md).
See [README](README.md) for current usage and the
[validation report](../benchmarks/results/blorp_2_imports_prelude_2026-10-12.md)
for tests, review, mutation checks, costs, and remaining limits.

## Goal and first working example

Separate the identity of a type from the modules supplying its UFCS functions.
Use one foundational type authority, an ordinary source-defined prelude, and
explicit method visibility. Preserve the pure pipeline, complete immutable
facts, and the existing ownership contracts.

```blorp
-- foo.brp: the declaration owner
fixed record Foo { value: Int }
```

```blorp
-- foo_1.brp: an independent operation module
import:
    ./foo: Foo
    int: Int

pure func doubled(value: Foo) -> Foo:
    { value = value.value.add(value.value) }
```

```blorp
-- foo_2.brp: another operation module
import:
    ./foo: Foo

pure func number(value: Foo) -> Int:
    value.value
```

```blorp
-- main.brp
import:
    ./foo: Foo
    ./foo_1: Foo methods_only
    ./foo_2: Foo methods_only

pure func make_foo() -> Foo:
    { value = 21 }

func main() -> Int:
    value = make_foo()
    value.doubled().number()
```

The pilot compiles this unchanged root and its dependencies, the C compiler
builds the emitted C at `-O0`, and the real entrypoint exits 42 with empty
stdout/stderr. The baseline cannot import this record or parse `methods_only`.
Build the pilot once per e2e run, as the existing harness requires.

## Language contract

| Import selection | Effect in the importing module |
| --- | --- |
| `foo: Foo` | Import the type and enable `foo`'s receiver functions for that type through UFCS. |
| `foo_1: Foo methods_only` | Enable `foo_1`'s receiver functions for the independently visible, exact `Foo`; import no type or constructors. |
| `foo: Foo(First, Second)` | Import the union type, those constructors, and the module's receiver functions for that type. |
| `foo: Foo()` | Import the union type without constructors, and enable its module's receiver functions. |
| `foo_1: doubled` | Import that function for both direct calls and UFCS. |

`methods_only` follows the type name and is a contextual import modifier. Do
not interpret `methods`, `methods only`, or `Foo(methods_only)` as alternative
modifier spellings. Constructor parentheses retain their existing meaning,
including selecting a constructor literally named methods_only. Combining
constructor selection with a trailing modifier is rejected with a teaching
diagnostic. The contextual word remains a valid identifier elsewhere.

The selector production is:

```ebnf
import_symbol = identifier [ constructor_selection | spaces "methods_only" ] ;
constructor_selection = spaces "(" spaces [ identifier { spaces "," spaces identifier } ] spaces ")" ;
```

The parser publishes a named selector, a constructor selector, or a method-only
selector with its spans. A bare name is resolved as a function or type by
namespace lookup; capitalization does not determine its category.
If a bare selector names both a visible type and a target-local function,
reject it as an ambiguous import selection. Do not import both implicitly or
choose a namespace by priority. Explain both matches and suggest renaming the
function or selecting through a module with an unambiguous surface. This does
not prohibit same-spelled local type/function declarations. Constructor and
method-only selectors already identify their relevant namespace explicitly.

An ordinary type import is required for a user-defined receiver type unless
that exact declaration is already supplied by the prelude. A method-only
selector does not satisfy this requirement, even if its target module knows
the type. Resolve all ordinary type bindings before method-only requests;
reordering import rows must not change the result. A same-spelled declaration
from a different owner never satisfies the requirement.
A type declared in the importing module itself is independently visible too;
it does not need a self-import. Existing local UFCS keeps working.

An ordinary type selector may follow a type binding already visible in its
target module to the original declaration. Thus `int: Int` works because `int`
imports Int from `_base`, and `foo_1: Foo` may explicitly import the
Foo that `foo_1` imported. This is type forwarding by identity, not a new
declaration or a `reexport` feature. Type forwarding must terminate and report
missing/conflicting bindings. The loader bans import cycles, but the namespace
still rejects a forwarding cycle with no declaration at its origin rather than
inventing an identity. Importing a function continues to expose none of its signature
types, sibling functions, or constructors as names.

Method selection considers only functions declared in the selected module.
Its imports and implicit prelude are not recursively forwarded. Empty method
sets are valid; an operation module need not invent a function to expose a
base type. Types, functions, and selected constructors reached through several
paths retain their original identities. Overlapping exposures of the same
identity are idempotent; different types with the same visible name conflict.
Keep diagnostics for malformed or repeated explicit import rows separate from
harmless overlap between explicit imports and the implicit scope.
Constructor selections through a forwarded union resolve variants from the
original UnionId, even if the forwarding module did not import their names.

Receiver selection uses accepted first-parameter types. A fixed receiver head
can be a builtin type or an existing nominal union/record identity. A selector
such as `Option` selects that type constructor; ordinary type matching still
distinguishes `Option[Int]`, `Option[String]`, and a generic `Option[T]` receiver.
An unconstrained first parameter `T` is not automatically associated with
every type; explicitly importing its function still allows UFCS. Selecting
`List` does not add general List operations or representations to this slice.

Different modules may contribute same-named methods. Narrow candidates by
receiver type using existing matching/unification and by supplied arity;
select one distinct applicable FunctionId or report ambiguity at the call.
Do not rank candidates by specificity, import order, return type, or purity,
and do not add a general overload solver based on later arguments. After a
unique target is selected, existing argument checking and purity enforcement
apply. Direct function-name conflict rules remain separate. Explicit and
prelude method exposures participate in the same identity-based candidate
set; an explicit import is not an override of a different applicable method.
Preserve receiver-compatible candidates before filtering arity. If exactly one
matches the receiver, run existing arity checking and retain ArgumentCountMismatch
even when a different-type candidate happens to have the right argument count.
For several receiver matches with no matching arity, report an arity error with
the available counts. Likewise retain the existing receiver mismatch for an
otherwise unique candidate. Multiple incompatible candidates need a typed
no-applicable-method diagnostic; absence, incompatibility, and ambiguity are
distinct outcomes.

## Target library structure and defaults

```text
blorp_2/standard_library_temp/
    README.md
    _base.brp
    prelude.brp
    int.brp
    float.brp
    string.brp
    list.brp
    io.brp
```

`_base.brp` is the sole declaration owner, and the only module that may
declare builtin types:

```blorp
type Int = builtin
type Float = builtin
type String = builtin
type Void = builtin
type List[T] = builtin

fixed union Bool:
    True
    False

fixed union Option[A]:
    Some(A)
    None

fixed union Result[Value, Error]:
    Ok(Value)
    Err(Error)

-- Set, Dict, and other foundational declarations remain deferred.
```

Bool, Option, and Result remain ordinary nominal unions. They acquire no
primitive representation or name-based runtime recognition. Builtin operations
continue to receive explicit, checked constructor roles.

Base declares no functions and imports nothing. Any module may import it as
`_base`, selecting types and constructors like any other module, for example
`_base: Int, Bool(True, False)` in `int.brp`. Library operation modules name
base types and constructors only through such imports; this keeps every
dependency written where it is used. Base type names share the module's type
namespace with normal imports: a distinct module-level type declaration cannot
replace a base type visible in that module. Test this rule and migrate local
test declarations to names such as Maybe where appropriate; ordinary local
value shadowing retains its existing rules.

`prelude.brp` selects base types and operations through the same import mechanism.
Each type comes from base, where it is declared; each operation module adds only
its receiver methods, so no reader is told that `Int` comes from `int`:

```blorp
import:
    _base: Int, Float, String, List, Void, Bool(True, False), Option(Some, None), Result(Ok, Err)
    int: Int methods_only
    float: Float methods_only
    string: String methods_only
    list: List methods_only
```

These imports supply UFCS functions; they do not make bare `add`, `length`,
or `to_string` calls available. A bare function call needs a named function
import. IO remains explicit (`io: print`). Prelude imports define its supplied
scope directly; no `reexport` syntax or wrapper declarations are required.

Bool, Option and Result need no operation modules yet. The prelude selects their
types and constructors from base; add separate modules when operations need them.

The prelude is the only implicit import, and only user modules receive it.
Following GHC's `NoImplicitPrelude` for `base`, everything under the library
root, the prelude included, sees only its own declarations and written imports.

| Source role | Scope |
| --- | --- |
| Foundation types (`_base.brp`) | Its own declarations. |
| Foundation prelude (`prelude.brp`) | Its written imports; no implicit self-prelude. |
| Target-library module | Its written imports, including any base types it uses. |
| Application root or ordinary user library/helper module | The prelude's selections and its written imports. |

Module role is explicit input-inventory data derived from the configured
target library and designated foundation inputs. Do not guess it from an
arbitrary basename or classify all dependency files as standard library. A
relative dependency within the target library has the same scope policy as a
bare-loaded library module. Moving user code out of main into a helper must
not change its implicit scope.

The prelude is reserved compiler input: no module can import it explicitly, via
either a bare or a relative path. No opt-out is included. Base is an ordinary
import target; importing it explicitly from a user module overlaps the
prelude's selections idempotently.
The shell receives an explicit library root; there is no host-library or
working-directory fallback. The compiler command is:

```sh
blorp_2/build/compiler --library-root blorp_2/standard_library_temp \
  blorp_2/test/e2e/fixtures/import/method_modules/main.brp \
  blorp_2/build/method_modules.c
```

The positional legacy prelude input and `src/prelude_temp.brp` are removed;
all callers use the configured library root. Missing foundation files produce
source-aware load diagnostics.

## Module layering and placement

Import cycles are banned, and the compiler enforces it. After loading, when
every module's import targets are resolved, a pure depth-first walk in load
order reports the first cycle at the import that closes it. A module importing
itself is a cycle too. For a root given as `main.brp` in `/project`:

```text
/project/helper.brp:2:5: error: import cycle: main.brp -> /project/helper.brp -> main.brp
help: move the declarations both modules need into a third module that both import
```

The walk names modules by their display paths, as other load diagnostics do:
the root keeps its command-line spelling and dependencies show their normalized
absolute paths. It runs before checking, so a cyclic program reports the cycle rather than a
later error. The host standard library, this target library and the pilot's own
sources had no import cycles when the ban was introduced. The
[cost report](../benchmarks/results/blorp_2_imports_prelude_cycles_2026-10-13.md)
records the matched cost of the explicit base imports and of the walk.

Acyclicity is a loader guarantee, not yet a type: a sealed `ParsedProgram` can
still be cyclic, and `LoadedProgram` is an ordinary record. A follow-up moves
the check into program sealing so that only an acyclic program can be sealed;
it needs `parse.brp` and is sequenced after the layout branch.

The target library is layered so that it is acyclic by construction:

1. `_base` declares the builtin and base types and imports nothing.
2. Operation modules (`int`, `float`, `string`, `list`, `io`) import base
   types from `_base` and, where needed, other operation modules.
3. The prelude imports base types and operation methods.
4. User modules receive the prelude implicitly and import anything else.

The library stays acyclic because library modules never receive the prelude
and never import user modules. A user module's dependency on the prelude is
implicit, so the walk over written imports cannot see it; the loader instead
rejects any module under the library root, the prelude included, that imports
a user module:

```text
a library module cannot import a user module
help: library modules may import only other library modules and _base
```

The application root is a user module wherever it lives, even under the
library root.

Library functions are placed by these rules:

- A function lives in its receiver's module: `split(String) -> List[String]`
  belongs in `string`, and `join(List[String])` in `list`.
- It moves to a higher module only when staying would create a cycle over a
  module-defined type.
- Mutually recursive module-defined types share a module.

Builtin types never force an import: they are declared in `_base`, which is the
one import a module is expected to need for naming them.

## Phase responsibilities and immutable facts

| Fact | Owner and publication boundary |
| --- | --- |
| Library configuration, paths, source bytes, module roles | Loading shell; publish explicit source/module inventory once. |
| Written selectors and modifier distinction | Parser; typed import variants and source spans. |
| Declaration identity, visible types/constructors, method-selection requests | Namespace builder; immutable identities and provenance, no accepted signatures. |
| Accepted parameter/result types | Checker; existing authoritative signature inventory. |
| Selected module's receiver functions | Checker-owned local builder after signatures; publish derived UFCS bindings with original FunctionIds. |
| Direct/UFCS availability | Scope-owned callable binding with an explicit visibility variant, distinct from import provenance. |
| Resolved call and contract | Body checker; existing complete call contract, then checked target/substitution. |
| Runtime/layout/ownership facts | Existing specialization and later phases; no import-name interpretation. |

Do not put accepted types into the parsed-only Namespace. Resolve forwarded
type bindings with a finite monotone local builder/worklist, then seal the
namespace before declaration payloads and signatures are checked. A cycle
with no originating declaration must fail rather than invent an identity.
Reject conflicting type identities before deriving method visibility.

After accepting signatures, derive only the selected receiver functions,
separating direct visibility from UFCS visibility. Borrow signatures from
their sole authority; do not copy them into method bindings. Reuse existing
primitive, UnionId, RecordId, VariantId, and FunctionId domains; introduce a
narrow receiver-head variant only where a consumer needs that distinction.
Normal scope lookup still uses NameIds. Receiver eligibility and post-lookup
target selection use resolved type/declaration identities, never spelling-based
semantic classification.

Calls and bindings need separate explicit distinctions. Keep the existing
`syntax.brp` call-site discriminator:

```blorp
fixed union CallNotation:
    DirectCall
    ReceiverCall
```

Add a scope-binding discriminator along these lines:

```blorp
fixed union CallableVisibility:
    DirectAndUfcs
    UfcsOnly
```

Named function imports and local functions receive `DirectAndUfcs`;
type-enabled imports and `methods_only` selections receive `UfcsOnly`.
Direct lookup admits only the first variant; receiver lookup admits both,
then performs type-directed candidate selection. This property belongs to
the importing scope's binding, not the shared function declaration. When the
same FunctionId is exposed both ways, merge availability to `DirectAndUfcs`
without duplicating the candidate. Import provenance remains diagnostic data,
not an implicit availability flag. Erase notation only after resolution has
enforced these rules; later IR need not retain source notation.

Keep source loading impure and all subsequent compilation/diagnostic rendering
pure. Use local builders and freeze once at each existing boundary. No global
method registry, persistent cache, duplicated type authority, new ownership
path, or backend import repair is needed.

## Validation coverage

| Boundary | Required cases and observable results |
| --- | --- |
| Parser / EBNF | Exact suffix; constructor syntax unchanged; mixed selections; malformed placement/combinations; empty/comment-only modules. Inspect typed selectors and exact error/help/spans. |
| Loader / roles | One load/parse per normalized module path, including shared prelude/base; explicit prelude imports reject and explicit base imports reach the designated base; import cycles, including self-imports, reject at the closing import while diamonds load; library modules importing user modules reject; root/helper/library roles remain distinct; missing foundation files preserve output files. |
| Namespace | Forwarded types retain original IDs; type/constructor overlap is idempotent; missing/conflicting types and ambiguous bare type/function selectors reject; method-only imports add no type/constructor binding; import order is irrelevant. |
| Accepted signatures / UFCS visibility | Local module functions only; no dependency/prelude method forwarding; zero-parameter functions excluded; exact and applied receiver matching; unconstrained T excluded from type selection. |
| Call checking | Two operation modules compose; DirectCall/ReceiverCall obey explicit binding availability; named import upgrades the same function's availability without duplication; distinct applicable methods are ambiguous; wrong receiver/arity/purity rejects with typed errors. |
| Contextual inference | Bare constructor plus unique method context; competing contexts require annotation; multi-step receiver chains, field access followed by UFCS, and contextual generic receivers preserve existing behavior. |
| Prelude / library | Same defaults in root and user helper; stdlib acquires neither prelude nor base implicitly; Int/Float `add`, String/List `length`, and numeric `to_string` resolve by type; Option/Result/Bool remain ordinary unions. |
| Ownership / backend | Imported managed Strings/unions and existing inline records retain checked, concrete, lowered, ownership and verifier contracts; generated C references the selected function; real fixtures remain sanitizer-clean. |

The direct suites for [import syntax](test/unit/test_import_syntax.brp),
[namespace identity](test/unit/test_type_import_namespace.brp),
[call selection](test/unit/test_import_selectors.brp),
[module loading](test/unit/test_module_input.brp), and
[foundation contracts](test/unit/test_builtins.brp) exercise these boundaries.
Grammar checks live under [test/test_grammar](test/test_grammar/), and native
examples under [test/e2e/fixtures/import](test/e2e/fixtures/import/).
The [validation report](../benchmarks/results/blorp_2_imports_prelude_2026-10-12.md)
retains independent reviews, mutation checks and matched costs. Use the current
[README commands](README.md) and [AGENTS.md](AGENTS.md) for validation.

## Scope limits

These rules apply to pilot input modules. The pilot implementation and host
TestSuite still use the existing compiler and its library until self-hosting.
The import backport to the existing compiler is deferred. Traits, general
overload resolution, function reexports, private items, qualified calls, module
aliases, wildcards, prelude opt-out and general List expansion remain outside
this contract. Preserve the source provenance under
[reference/standard_library](reference/standard_library/).
