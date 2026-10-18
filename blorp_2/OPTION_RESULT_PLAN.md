# Option and Result: catalog and addition plan

## Status and scope

The target library is `blorp_2/standard_library/`, separate from the host
`standard_library/src/`. Its `_base.brp` already owns Bool, Option, Result and
their constructors. The operation modules `option.brp` and `result.brp` are
absent. This change renames the directory and records the inventory and plan;
it implements no helpers or callable semantics.

At base `1f3f407198efa55703ba8dea7a4be1c5239cfc89`, an actual self-compile
stops loading `result: map_err` in `src/main.brp:10`. All 41 compiler source
files parse. Pure function-type annotations parse, but checking rejects
function types and lambdas. Pure functions may return Void.

The owner abandoned the remaining HOF-removal migration. Preserve existing
compiler callbacks and their phase boundaries. The older
[five-helper proposal](OPTION_RESULT_HELPERS_PLAN.md) and held candidate are
historical predecessors, not the complete current demand or current cost authority.

## Resolved compiler inventory

The census covers all 41 modules under `src/`, excluding host tests/tooling and
text embedded in test fixtures. One host Core dump after lowering resolved
each call to its declaration ID and defining file. Only declarations in host
`option.brp` and `result.brp` were selected. No repeated lowered sites were
removed, and no additional value-only references to these library functions
were found. The compiler source is unchanged by the directory rename.

All nine selected overloads are pure. Generic letters below name independent
type parameters; callback arguments have the written pure unary function types.

| Module | Function and parameter types | Result | Sites | Files | Prerequisite |
| --- | --- | --- | ---: | ---: | --- |
| option | `is_some(Option[T])` | `Bool` | 58 | 14 | Existing subset |
| option | `is_none(Option[T])` | `Bool` | 21 | 10 | Existing subset |
| option | `get_or(Option[T], T)` | `T` | 14 | 4 | Existing subset |
| option | `to_result(Option[T], E)` | `Result[T, E]` | 93 | 17 | Existing subset |
| option | `map(Option[T], pure (T) -> U)` | `Option[U]` | 6 | 4 | Callable semantics |
| result | `is_ok(Result[T, E])` | `Bool` | 2 | 1 | Existing subset |
| result | `map(Result[T, E], pure (T) -> U)` | `Result[U, E]` | 8 | 5 | Callable semantics |
| result | `map_err(Result[T, E], pure (E) -> F)` | `Result[T, F]` | 6 | 1 | Callable semantics |
| result | `and_then(Result[T, E], pure (T) -> Result[U, E])` | `Result[U, E]` | 4 | 2 | Callable semantics |

Total: **212 sites**. Five helpers without callbacks cover **188 sites**;
four callback helpers cover **24 sites**, using 17 pure lambda expressions and
seven named pure function references. Captures are required: for example,
`src/own/own.brp:611–612` maps a parent argument while capturing `field`.

[OPTION_RESULT_CALLS.tsv](OPTION_RESULT_CALLS.tsv) lists every resolved site,
its host definition ID, source start and callback form. IDs identify this
particular dump, not a stable public interface. Some host lower-dump end spans
are inverted; source starts provide navigation, and neither inferred call
notation nor capture-layout hints establish binding identity.

Host definitions: [option.brp](../standard_library/src/option.brp), function
headers at 50, 66, 85, 109 and 204; [result.brp](../standard_library/src/result.brp),
headers at 35, 96, 116 and 136. List `map` (18 sites) and List `get_or` (10 sites)
were explicitly excluded by resolved identity. Some/None/Ok/Err, pattern
matching and `?=` are separate language forms, not helper-function counts.

Reproduction from the repository root, after a FRESH host check:

```sh
bin/blorp compile --std-dir standard_library/src --no-format \
  --stop-after=lower --dump-core-after=lower \
  --dump-core-file build/option-result-lower.json \
  blorp_2/src/main.brp -o build/option-result-unused.c
```

The intentional stop exits 0 with `stopped after lower` on stderr and emits
no C. The raw dump has two text header lines before its JSON program. The
retained [inventory packet](../build/bootstrap-evidence/option-result-inventory-2026-10-18/INVENTORY.md)
pins the command, host `c04f68ba`, STD91, all source inputs, raw dump and full
resolved records; two independent inventories agree on all 212 sites.

## Separate host-test demand

A static type/import audit also identifies these APIs in host-run tests.
They are outside the compiler self-compilation implementation set; this is
not an aggregate resolved census of the host test suite.

| API | Signature | Example under `test/unit/` |
| --- | --- | --- |
| Option `and_then` | `(Option[T], pure (T) -> Option[U]) -> Option[U]` | `test_check/test_match.brp:190` |
| Result `get_or` | `(Result[T, E], T) -> T` | `test_emit/test_emit.brp:43` |
| Result `is_err` | `Result[T, E] -> Bool` | `test_harness/test_cost.brp:25` |
| Result `to_option` | `Result[T, E] -> Option[T]` | `test_check/test_receiver_overlap.brp:32` |

Tooling adds no confirmed helper names beyond the compiler set. Current target
library/real e2e inputs use the ADTs and returning builtins; no helper demand
was confirmed there. Embedded parser strings and user-defined lookalikes are
not host-library evidence. Host Option equality assertions belong to the
separate trait dependency; self-hosting TestSuite remains deferred.

## Addition sequence

### 1. Add the five helpers that need no callbacks

Add `option.is_some`, `is_none`, `get_or`, `to_result` and `result.is_ok` as
ordinary generic Blorp functions with tail matches. Reconcile the held
five-helper candidate against the new directory and current main before
reusing any code or evidence. Do not inherit its old base or numeric budgets.

Each operation module explicitly imports its needed types/constructors from
`_base`; Option imports Result directly from `_base`, not the Result operation
module. No duplicate unions, reexports, traits, builtin labels or native helpers
are needed. Keep the existing prelude unchanged; consumers explicitly import
operations. A representative implementation shape is:

```blorp
import:
    _base: Option(Some, None)

pure func get_or[T](self: Option[T], default_val: T) -> T:
    match self:
        Some(value): value
        None: default_val
```

`get_or` evaluates the default argument eagerly even for Some. `to_result`
evaluates its error argument eagerly even for Some. Predicates preserve their
borrowed inputs. Returned managed payloads/defaults/errors remain independently
owned after the input and unused arguments retire. Cover Int, String and Void.

Exit: named imports and UFCS work with the existing `_base` identities, exact
branch results and ownership. Main's `map_err` import is still unavailable;
this slice alone does not clear the current self-compilation frontier.

### 2. Support the pure callable forms the census actually uses

Parsing is complete; semantic function types, function values, invocation and
lambda execution are not. Start with a small end-to-end generic `apply`
witness using a named pure function, then one using an immutable managed
capture. Validate the M7 representation and cost plan before implementation.
Known-callee specialization is the bounded starting hypothesis; prove that it
handles these named references and lambdas before designing a general closure ABI.

The path must cover generic argument/result inference, pure-call enforcement,
captured-value lifetime, lowering, ownership insertion, independent verification
and emission. Preserve rejection of mutable captures and impure callees in a
pure callback slot. Purity is semantic information; it needs no late pure-Void
restriction. Do not stop at noncapturing callbacks or bypass unsupported bodies.

Exit: the representative named and capturing callback programs typecheck and
execute through their ordinary native main functions, with typed phase facts,
correct capture ownership and existing memory/resource checks.

### 3. Add the four callback helpers

Add `option.map`, `result.map`, `map_err` and `and_then` with the exact selected
pure host signatures. Bodies are ordinary matches. Option.map calls its
callback only for Some; Result.map/and_then only for Ok; Result.map_err only
for Err. The bypass variant/payload propagates unchanged. The selected branch
contains one invocation; no invocation occurs in the bypass branch.

For example, after callable semantics are accepted:

```blorp
import:
    _base: Result(Ok, Err)

pure func map_err[T, E, F](self: Result[T, E], f: pure (E) -> F) -> Result[T, F]:
    match self:
        Ok(value): Ok(value)
        Err(error): Err(f(error))
```

Do not place unsupported callback stubs in modules during step 1: the checker
checks every declaration, including unused generic bodies. Implement only the
nine cataloged APIs; defer lazy-default helpers, unused helpers, impure overloads
and trait APIs until there is a separate requirement.

### 4. Close compiler imports and remeasure the frontier

Use the TSV to add only the explicit Option/Result operation imports each
compiler module uses. Host and target imports must select the same APIs;
retain compiler bodies and callbacks. Keep this source/import integration a
reviewable slice after the needed helper/language increments are accepted.

Rerun the actual self-compile with `--library-root blorp_2/standard_library` and
report its next diagnostic. Completing these nine APIs does not establish
complete library parity or the A/B/C fixpoint: other library and language
requirements remain independent.

## Acceptance and cost boundaries

Each implementation slice starts with a failing ordinary fixture and exact
diagnostics where relevant, then typed phase assertions and real-main tests.
Use the existing TestSuite/e2e owners and harness, unmodified generated C,
strict-zero accounting, sanitizers and existing fixture resource ceilings.

Test both variants, eager default/error evaluation, managed result survival,
shared input aliases, Void payloads, and captured String/record lifetimes.
For callbacks, inspect selected/bypassed invocation counts in phase IR and
check exact native values/bytes and cleanup; pure native output alone cannot
prove a callback was invoked only once. Retain effective faults and restoration
for branch selection and ownership oracles. No alternate main or new harness.

Before implementation, freeze that slice's current-main B, candidate scope,
production/test LOC limits, tool/library/input identities and cost procedure.
Compiler data-model changes require matched construction allocations and normal
minimum-of-three retired instructions, with independent prospective ceilings
no looser than +3%, plus existing fixture limits. Label host source-to-C
measurements as proxies until self-compilation works. Ordinary library helpers
need shared-control and API-using fixture cost evidence with prospectively
reviewed ceilings; never fabricate a successful baseline for a new input.
Keep old failures/held evidence historical. A repeatable breach stops the
slice for diagnosis/rescoping; do not widen a gate or add counter-specific code.

No helper implementation or SOURCE-removal campaign is authorized by this
catalog/planning change. Obtain two independent reviews and test-runner
acceptance for every future increment before integration.
