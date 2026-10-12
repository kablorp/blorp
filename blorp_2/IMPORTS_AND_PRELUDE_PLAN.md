# Type imports, method visibility, and the target prelude

Status: implemented in `blorp_2`, including its target library and input fixtures.
The sections below retain the approved design and implementation sequence.
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
that exact declaration is already supplied by base/prelude. A method-only
selector does not satisfy this requirement, even if its target module knows
the type. Resolve all ordinary type bindings before method-only requests;
reordering import rows must not change the result. A same-spelled declaration
from a different owner never satisfies the requirement.
A type declared in the importing module itself is independently visible too;
it does not need a self-import. Existing local UFCS keeps working.

An ordinary type selector may follow a type binding already visible in its
target module to the original declaration. Thus `int: Int` works even though
the foundational module owns Int, and `foo_1: Foo` may explicitly import the
Foo that `foo_1` imported. This is type forwarding by identity, not a new
declaration or a `reexport` feature. Type forwarding must terminate and report
missing/conflicting bindings, including an import cycle with no declaration
at its origin. Importing a function continues to expose none of its signature
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
    _base/
        types.brp
        prelude.brp
    int.brp
    float.brp
    string.brp
    list.brp
    io.brp
```

`_base/types.brp` is the sole declaration owner:

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

The base scope includes its type declarations and their constructors:
True, False, Some, None, Ok, and Err. This explicitly lets library operation
modules name those constructors without importing a higher-level operation
module. Base declares no functions and imports nothing. Base type names share
the module's type namespace with normal imports: a distinct module-level type
declaration cannot replace an implicitly visible base type. Test this rule
and migrate local test declarations to names such as Maybe where appropriate;
ordinary local value shadowing retains its existing rules.

`_base/prelude.brp` selects operations through the same import mechanism:

```blorp
import:
    int: Int
    float: Float
    string: String
    list: List
```

These imports supply UFCS functions; they do not make bare `add`, `length`,
or `to_string` calls available. A bare function call needs a named function
import. IO remains explicit (`io: print`). Prelude imports define its supplied
scope directly; no `reexport` syntax or wrapper declarations are required.

Bool, Option and Result need no operation modules yet. Their types and constructors
are supplied by base; add separate modules when operations need them.

| Source role | Implicit scope |
| --- | --- |
| Foundation types | Its own declarations; no prelude or operation imports. |
| Foundation prelude | Base plus its written imports; no implicit self-prelude. |
| Target-library operation module | Base plus its written imports. |
| Application root or ordinary user library/helper module | Base, prelude, and its written imports. |

Module role is explicit input-inventory data derived from the configured
target library and designated foundation inputs. Do not guess it from an
arbitrary basename or classify all dependency files as standard library. A
relative dependency within the target library has the same scope policy as a
bare-loaded library module. Moving user code out of main into a helper must
not change its implicit scope.

`_base` is reserved compiler input: users cannot import these designated
modules explicitly, via either bare or relative paths. No opt-out is included.
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
Keep the general module-cycle policy unchanged in this work: the pilot
currently accepts cycles without initialization. The target library's
base/operations/prelude dependency structure must be acyclic. A general cycle
ban is a separate language decision, not a side effect of this migration.

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

Two current traps require focused tests. `namespace.brp` and
`check.brp:lookup_target` currently share candidates between direct and receiver
calls, while `validate_import_binding` rejects conflicts before a call site.
Those paths cannot implement method-only visibility unchanged. Also,
`check.brp:synthesize_value` currently uses receiver contracts to contextualize
constructor expressions before synthesizing their bases. Preserve unique
candidate contextual typing. When competing methods cannot supply one receiver
context, request a receiver annotation with a teaching diagnostic; do not
silently change existing constructor inference or choose the first candidate.
Test receiver chains and field-then-method expressions as well as single calls.

Keep source loading impure and all subsequent compilation/diagnostic rendering
pure. Use local builders and freeze once at each existing boundary. No global
method registry, persistent cache, duplicated type authority, new ownership
path, or backend import repair is needed.

## Implementation order

Each slice starts with a failing Blorp TestSuite test, includes its executable
example when complete, and lands green after independent review.

1. **Establish the contract and shortest feedback loop.** Add parser/grammar
   cases for the agreed suffix, type/constructor selections, malformed forms,
   comments, blank lines, and mixed selections. Record current import and
   receiver-context tests, a frozen cost corpus, and source/binary provenance.
   Review parser, ergonomics, and identity rules before implementation.

2. **Make foundation declarations one authority.** Separate the current
   builtin-type authority from its legacy runtime-function fallback and move
   declarations to `_base/types.brp`, including ordinary Bool/Option/Result.
   Keep ordinary union/record checking and source locations; allow builtin
   declarations only for the configured foundation role. Introduce explicit
   source roles and base visibility, then remove the replaced declaration
   owners in the same slice. Move the old String `length` wrapper to
   `string.brp` and retain the existing Int `to_string` wrapper. Migrate bare
   and receiver calls that relied on legacy prelude functions to explicit
   function imports, which are already supported; remove the runtime-name
   fallback now. Implicit operation visibility is supplied only in step 5.
   During these intermediate slices, the existing positional foundation input
   points to `_base/types.brp`; this is one evolving input path, not a second
   compatibility mode.
   This includes local Option/Result declarations that would now conflict.
   Parse empty/comment-only operation modules without dummy declarations.

3. **Resolve ordinary type imports and forwarding.** Extend bare selectors
   beyond functions to builtin types, records, and unions without capitalization
   heuristics. Preserve explicit constructor selection. Complete type-binding
   closure before declaration/signature checking; cover cycles, diamonds,
   aliases of the same identity through several modules, and same-spelled
   different owners. Support `foo: Foo` through an operation module's existing
   binding. Keep function imports from forwarding signature types.

4. **Implement type-enabled UFCS and `methods_only`.** Construct checker-owned
   method visibility from accepted signatures, and enforce the independent
   caller type requirement. Carry explicit callable visibility and preserve
   CallNotation until target selection. Keep direct imports separate. Cover
   builtin types, generic unions, existing nongeneric records, and the current
   concrete List[String] receivers; no new collection or record capabilities.
   Preserve contextual constructor inference, arity,
   purity, argument diagnostics, and original resolved call contracts. Deliver
   the three-module Foo fixture above, plus missing-type and ambiguity cases.

5. **Supply the ordinary prelude and migrate every target module.** Load and
   check `_base/prelude.brp` through the module pipeline and supply its selected
   scope to all user modules. Standard-library operations get base only.
   Remove the positional foundation input and obsolete target prelude file;
   update Makefile, harness, commands, embedded program strings,
   fixtures, documentation, and benchmark callers together. Restore the
   existing convenient UFCS operations through ordinary imports. Keep IO
   explicit. Verify that only one authority for each type/function remains.

6. **Review and validate the whole migration.** Independently review identity,
   visibility, contextual inference, generic matching, and library layering.
   Run the full pilot suites, applicable native sanitizers, mutation oracles,
   and matched cost measurements. Record actual costs and handwritten
   production/test LOC separately. Remove superseded implementation/docs in
   each slice rather than leaving a final compatibility cleanup project.

Steps 2–4 are serial where their authorities depend on each other. After the
contracts are fixed, library/fixture inventory and negative-test preparation
can run alongside the owning implementation with disjoint file ownership.
Do not have two agents independently redesign namespace or checker facts.

## Test matrix and acceptance

| Boundary | Required cases and observable results |
| --- | --- |
| Parser / EBNF | Exact suffix; constructor syntax unchanged; mixed selections; malformed placement/combinations; empty/comment-only modules. Inspect typed selectors and exact error/help/spans. |
| Loader / roles | One load/parse per normalized module path, including shared prelude/base; reserved foundation imports reject; root/helper/library roles remain distinct; missing foundation files preserve output files. |
| Namespace | Forwarded types retain original IDs; type/constructor overlap is idempotent; missing/conflicting types and ambiguous bare type/function selectors reject; method-only imports add no type/constructor binding; import order is irrelevant. |
| Accepted signatures / UFCS visibility | Local module functions only; no dependency/prelude method forwarding; zero-parameter functions excluded; exact and applied receiver matching; unconstrained T excluded from type selection. |
| Call checking | Two operation modules compose; DirectCall/ReceiverCall obey explicit binding availability; named import upgrades the same function's availability without duplication; distinct applicable methods are ambiguous; wrong receiver/arity/purity rejects with typed errors. |
| Contextual inference | Bare constructor plus unique method context; competing contexts require annotation; multi-step receiver chains, field access followed by UFCS, and contextual generic receivers preserve existing behavior. |
| Prelude / library | Same defaults in root and user helper; stdlib does not acquire prelude; Int/Float `add`, String/List `length`, and numeric `to_string` resolve by type; Option/Result/Bool remain ordinary unions. |
| Ownership / backend | Imported managed Strings/unions and existing inline records retain checked, concrete, lowered, ownership and verifier contracts; generated C references the selected function; real fixtures remain sanitizer-clean. |

Create focused suites under `test/unit/` alongside the existing
`test_import_syntax.brp`, `test_namespace.brp`, `test_union_imports.brp`,
`test_module_check.brp`, `test_prelude.brp`, and `test_typecheck_programs.brp`.
Use direct phase inputs and typed errors; avoid one subprocess per semantic
test. Grammar cases belong in `test/test_grammar/test_conformance.brp`.
E2e fixtures belong under `test/e2e/fixtures/import/`, exercised by the normal
`test/e2e/test_end_to_end.brp` entrypoint and owning fixture group.

Negative cases include absent caller Foo despite foo_ops importing it;
same-spelled unrelated Foo; unknown type selector; inaccessible constructor;
direct use of a method-only function; prelude/base type conflicts; and method
ambiguity with primary call and both declaration/import locations. Verify
typed errors, exact rendered diagnostics, help, and source spans independently.
Include a type and function both named Foo, unique wrong arity, a wrong-arity
receiver match beside a different-type method with matching arity, and several
receiver matches whose accepted counts all differ from the supplied count.

Demonstrate failure when method-only bindings are deliberately admitted to
direct lookup, when receiver identity is ignored, and when dependency methods
are incorrectly forwarded. Restore sources before final gates. These are
bounded oracle checks, not a new mutation-test framework.

Narrow feedback starts with the affected existing unit suite. Final pilot
commands are the existing ones:

```sh
scripts/compiler-build-status
# Run make only if the host is STALE/UNKNOWN, then recheck freshness.
bin/blorp test --suite --timeout 180 blorp_2/test/unit
bin/blorp test --suite --timeout 180 blorp_2/test/runtime
bin/blorp test --suite --timeout 180 blorp_2/test/test_grammar
bin/blorp test --suite --timeout 0 blorp_2/test/e2e
git diff --check
```

The e2e entrypoint builds the pilot once via `make -C blorp_2 test-compiler`;
do not add another preparatory build or a persistent cache. Use the owning
suite's existing sanitizer/leak modes and inspect emitted C for affected
fixtures. Paths, syntax examples, and the pilot EBNF/README must match each
implemented slice. Do not advertise planned syntax as supported early.

For equivalent loaded workloads in preparatory refactors, use investigation
ceilings of +15% allocations and +10% retired instructions, matching the
existing module plan. Freeze root inputs, library/configuration, compiler
binaries, and C flags before paired runs; investigate repeatable excess before
acceptance. Supplying a full default prelude adds mandatory source work:
measure that separately, identify the added modules, and set explained
per-fixture numerical budgets before implementing that slice. Do not silently
raise ceilings or attribute all increases to imports. Until self-compilation
exists, these are owned-input compilation proxies, not self-compile evidence.
Require each source to be loaded/parsed once; avoid building a whole-program
method cross-product. Start with scans over selected modules, measure complete
construction plus lookup, and add an index only for a demonstrated repeated
query. Compare runtime results for every fixture; require byte-identical C
only where declaration inventory/order and semantics are unchanged.

## Scope, handoff, and completion

No changes to the existing compiler, `standard_library/src`, or its language
syntax are part of this roadmap. `blorp_2/src` and host TestSuite imports
continue to use the host compiler's supported grammar until self-hosting;
the new import spelling applies to pilot input modules. Target modules,
embedded input programs, and `standard_library_temp` must all follow the new
rules. Preserve upstream reference source and provenance when moving active
declarations; reference copies now live outside compilation inputs under
`reference/standard_library/`. Inactive traits/FFI and future Set/Dict stay inactive.

Defer traits, general overload resolution, function reexports, private items,
qualified calls, module aliases, wildcard imports, prelude opt-out, a general
cycle ban, and expansion of List. No extra tooling framework is required.

Use compiler-expert implementers and independent compiler-expert/code-reviewer
and test-runner review. Each implementation brief follows
[HANDOFF_SPEC](../docs/HANDOFF_SPEC.md), names one slice, quotes its current
change site and intended code, supplies a failing test and runnable acceptance
criteria, and declares disjoint file ownership when work is parallel. Return
test counts, diagnostics/C evidence, measurement provenance, LOC, and remaining
limits. Report an uncertain inference/identity boundary to the coordinator;
do not guess, broaden the overload model, or alter host semantics to bypass it.

Completion means the working Foo fixture and all migrated calculator/library
fixtures pass, every listed boundary has granular tests, base/prelude are
ordinary explicit source inputs with their designated roles, replaced
authorities/fallbacks are gone, and independent reviews approve. Planning
alone does not mark any of those implementation criteria complete.
