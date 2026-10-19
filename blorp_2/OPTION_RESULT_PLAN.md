# Option and Result: catalog and addition plan

## Status and scope

The target library is `blorp_2/standard_library/`, separate from the host
`standard_library/src/`. Its `_base.brp` already owns Bool, Option, Result and
their constructors. The operation modules `option.brp` and `result.brp` are
implemented for the five ordinary helpers: Option `is_some`, `is_none`,
`get_or`, `to_result` and Result `is_ok`. Accepted named references and forwarding
permit a named-only four-helper library increment. The current
[accounting](STANDARD_LIBRARY_GAPS.md) counts Option.map(5), Result.map(14), map_err(6), and_then(4).
Some compiler consumers still need M7 lambdas/captures and explicit operation imports.

At base `1f3f407198efa55703ba8dea7a4be1c5239cfc89`, an actual self-compile
stops loading `result: map_err` in `src/main.brp:10`. All 41 compiler source
files parse. Pure function-type annotations parse, but checking rejects
function types and lambdas. Pure functions may return Void. After the five
ordinary helpers are added, the actual source probe reaches
`src/check/check.brp:20:13`: `opaque types are not supported yet`, with no C
produced. That existing independent language requirement remains outside this
library slice. These are historical probe results, not a current-main frontier
observation; no current frontier is claimed without an actual current probe.

The owner abandoned the remaining HOF-removal migration. Preserve existing
compiler callbacks and their phase boundaries. The older
[five-helper proposal](OPTION_RESULT_HELPERS_PLAN.md) and held candidate are
historical predecessors, not the complete current demand or current cost authority.

## Historical resolved compiler inventory

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

**Implemented.** Typed phase tests and the ordinary native witness cover this
subset; the frozen acceptance epoch below owns its cost boundary.

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
branch results and ownership. At that checkpoint main's `map_err` import remained
unavailable; this slice did not establish self-compilation or a current frontier.

### 2. Support the pure callable forms the census actually uses

[NAMED_CALLABLES_PLAN.md](NAMED_CALLABLES_PLAN.md) owns the first increment:
named pure references, forwarding and direct-call specialization. Lambdas and
immutable captures follow under a separately reviewed increment.

Pure function types, named references, forwarding and direct-call specialization
are implemented. [LAMBDAS_PLAN.md](LAMBDAS_PLAN.md) owns the separately reviewed
noncapturing and immutable-capture increments, starting with ordinary generic
`apply` witnesses. Its shared M7 baseline and cost limits remain unchanged.
Known-callee specialization is the bounded starting hypothesis; prove that it
handles these named references and lambdas before designing a general closure ABI.

The path must cover generic argument/result inference, pure-call enforcement,
captured-value lifetime, lowering, ownership insertion, independent verification
and emission. Preserve rejection of mutable captures and impure callees in a
pure callback slot. Purity is semantic information; it needs no late pure-Void
restriction. Do not stop at noncapturing callbacks or bypass unsupported bodies.

Named exit: accepted pure types, named references, forwarding and direct calls
permit step3's bounded named-only library increment now. Full callable exit still
requires representative named and capturing programs through their ordinary native
mains, typed phase facts, correct capture ownership and existing resource checks.
The library increment does not satisfy the full lambda/capture compiler census.

### 3. Add the four callback helpers as a named-only increment

Accepted named-callable semantics permit `option.map`, `result.map`, `map_err`
and `and_then` now, with the exact selected pure host signatures. Lambda/capture
completion remains separate. Bodies are ordinary matches. Option.map calls its
callback only for Some; Result.map/and_then only for Ok; Result.map_err only
for Err. The bypass variant/payload propagates unchanged. The selected branch
contains one invocation; no invocation occurs in the bypass branch.

For example, use the accepted named-callable path in an ordinary definition:

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
no looser than +3%, plus existing fixture limits. The sole exception is the
shared named/lambda callable-M7 increment: its [bounded resource decision](NAMED_CALLABLES_PLAN.md#prospective-scope-and-costs)
uses +8% cumulative hard limits and a +6% reassessment against the unchanged
initial M7 B, not a fresh allowance per stage. It changes no fixture limit or
LOC budget and authorizes no lambda implementation before its separate frozen
architecture and cost plan. All other slices retain the +3% rule. Label host
source-to-C measurements as proxies until self-compilation works. Ordinary library helpers
need shared-control and API-using fixture cost evidence with prospectively
reviewed ceilings; never fabricate a successful baseline for a new input.
Keep old failures/held evidence historical. A repeatable breach stops the
slice for diagnosis/rescoping; do not widen a gate or add counter-specific code.

Implementation was authorized after this catalog landed. No remaining
SOURCE-removal campaign is planned. Obtain two independent reviews and
test-runner acceptance for every increment before integration.

### Ordinary-helper implementation epoch

Freeze B at `6eb6886c76a4e6cc0427defe690b6ebb288bb9b6` before setup. This
slice adds only the five ordinary helpers and their tests; compiler source,
foundation and prelude remain unchanged. Prospective physical bounds are
50 added production lines, 300 added test lines and 60 lines for the fixture.
Retain existing coverage when reconciling the held candidate.

The new real-main witness uses the current generic suite limits: 150,000
compile allocations and 600,000,000 strict diagnostic-mode instructions.
Normal diagnostic-free minimum-of-three instructions must also stay within
600,000,000. Its missing-module B rejection is retained; it has no successful
B denominator. Compare `return/zero.brp`, `generic/managed/basic.brp`,
`option_input/parse_int.brp` and `conversion/integer.brp` under the B and candidate
library roots: byte-identical C, balanced strict counts, and independent +3%
allocation/normal-minimum-of-three instruction ceilings, plus existing limits.

The source-matched retained C (`ddb3454d…`) and diagnostic pilot (`7b2f277d…`)
come from the rename acceptance packet. Link one normal `-O0` diagnostic-free
pilot from those same C bytes for instruction samples. The 41 compiler source,
nine B library, host/library and tool pins must remain stable. This measures
target input compilation; it makes no target self-compilation cost claim.
The [epoch packet](../build/bootstrap-evidence/option-result-ordinary-2026-10-18/)
retains full identities, raw observations, effective faults and restoration.
A repeatable breach stops the slice for diagnosis/rescoping.

The [ordinary-helper acceptance report](../benchmarks/results/blorp_2_option_result_ordinary_2026-10-18.md)
records passing matched costs, phase/native gates, effective restored faults
and the actual source frontier.

## Named-only callback-helper implementation epoch

Production is limited to `standard_library/option.brp` and `result.brp` using
existing `_base` identities, ordinary matches and pure direct callback calls.
No compiler, builtin, runtime, solver, prelude, source migration or HOF removal
change is included. Stop for root if nested constructor/callback needs new machinery.

### Prospective bounds and tests

Hard added/net ceilings: production40/+40 across2 modules; nonfixture500/+500;
one native fixture <=100 physical lines; API docs <=80 additions; this amendment
<=120 physical lines; later report <=100. Forecast production20-28 additions.
Count replacements/mechanical ports; no compression, deleted coverage, deletion
credit against additions or borrowed predecessor room. Prefer existing phase helpers.
Owners relative to blorp_2/test/: unit/test_check/test_generics.brp;
unit/test_specialize/test_generic_unions.brp; unit/test_own/test_managed_union.brp;
unit/test_emit/test_generic_ownership.brp; e2e/test_generics.brp.
Reuse load/compilation/module_input/native helpers. Extend current5-helper
inventory/ownership observers to distinguish9 by declaration/union identity;
retain every original5 assertion. API docs: standard_library/README.md, LIBRARY_PARITY.md,
README.md, ROADMAP.md, ../docs/GUIDE.md and ../docs/GRAMMAR.md parity links/status; same80 ADD.
Check4 Pure signatures/rigid owners/exact callback input-result types, T!=U/E!=F,
and same-shaped foreign unions; diagnostics pin kind/help/span. Cover named/imported
callbacks, forwarding, eager data evaluation/order, impure callback/wrong argument-result-error rejection, Void,
and existing body_types scope. Do not weaken established diagnostics for convenience.
For each actual checked helper's canonical VariantIds/CallableParameterId, count
nested callback invocations: selected1, bypass0. A concrete T=E=String bypass-call
negative witness must fail that oracle. Specialize proves direct target/type choices,
erased static argument and dense runtime slots; no spelling-based semantic lookup.
Own/Verify prove input borrowing, immediate payload provenance, selected callback
result transfer once, bypass independent returned owner and return/unused cleanup.
Verify independently rejects omitted acquisition and duplicate child transfer.
New fixture: blorp_2/test/e2e/fixtures/generic/managed/option_result_callbacks.brp;
all8 branches, Int/String/Void, UTF8/NUL, aliases, result survival after callee locals.
Real main exit0/exact prewritten bytes/stderr0; unchanged ASan/UBSan/strict0 harness.
Freeze fixture/oracle bytes before RED; retain exact B missing-export diagnostic,
status/no-C, not old missing-module evidence. Native output cannot prove call count.
Two temporary faults: duplicate selected callback through an unused well-typed
local in actual Option.map; omit actual BorrowedResult return acquisition in Own.
Pin exact named semantic failures before leases. Restore exact bytes AND modes
unconditionally before classification, verify pins/index, then restored GREEN.
Setup/type failure is not an effective fault; retain typed bypass/Verify negatives.

### Frozen costs and four mandatory unchanged shared controls

Root names/approves accepted B/complete C before implementation/setup; 1d02a6700
is context, not selected/frozen B. Freeze full sources/library/corpus/physical
paths, producer/tool/std identities and output states. No roll after failure.
Controls: blorp_2/test/e2e/fixtures/return/zero.brp plus these3 tiny data-only
programs at inputs/shared/{name}, unchanged B/C; these are not extra native fixtures.
option-min.brp:
```blorp
import:
    option: get_or
func main() -> Int:
    get_or(Some(7), 0)
```
result-min.brp:
```blorp
import:
    result: is_ok
func main() -> Int:
    value: Result[Int, String] = Ok(7)
    match is_ok(value):
        True: 1
        False: 0
```
named-forward-min.brp:
```blorp
pure func identity[T](value: T) -> T:
    value
pure func apply[T, U](value: T, callback: pure (T) -> U) -> U:
    callback(value)
pure func forward[T, U](value: T, callback: pure (T) -> U) -> U:
    apply(value, callback)
func main() -> Int:
    forward(7, identity)
```
No larger substitute, dropped control or cherry-picking after a breach.
Each control AND frozen HOST proxy independently require C<=1.03B allocations
and normal min3 instructions; all old absolutes/strict0 remain binding.
Shared C/status/diagnostics/output states stay byte-exact; normal/strict agree per role.
HOST retains original normal34ac1a91/diagnosticbe31a5a3 and STD090ed68c roles/pins;
unique schema1 artifact_construction_complete.total_allocations, not exit TOTAL
or ROOT974 substitution. Complete original598 provenance must close before reuse.
Reuse source-matched A for B/C; verify C/normal0/diagnostic1 pins; no ABI/closures/M7 reset.
New C-only caps:150000 allocations/600M strict diagnostic instructions/600M normal
min3; positive balanced strict0/unmodified C. No successful B denominator.
Finite leases:1 API RED;1 focused GREEN;4 fault/restored focused calls;1 component,
1 full native,1 actual frontier call, all through existing commands/harness.
Exact reuse avoids setup; otherwise separately lease1 C generation/2 O0 links
(normal0/diagnostic1). Cost:36 target calls (4x8 controls+4 C-only), plus8 original
HOST calls (diag B/C+normal B1,C1,C2,B2,B3,C3); no other samples.
Literal argv/CWD/pins/output absence/failure sets need review before START.
Stop first unexpected setup/semantic/pin/identity/strict/cost/LOC result; preserve
raws, restore faults, RETURN lane; no retry/repair/refreeze/waiver or next job.
Root+peer approve/publish this amendment before implementation; two final
independent reviews plus test-runner acceptance precede root integration.
