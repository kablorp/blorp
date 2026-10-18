# Coalesce concrete type-argument translation

## Status and dependencies

The three-site first-order migration is implemented and validated. The
[current report](../benchmarks/results/blorp_2_first_order_type_arguments_2026-10-18.md)
records the frozen accepted baseline, effective mutations, full functional gates
and 3,920 successful matched calls. The amendments below retain the prospective
contracts and historical evidence limits; eight callbacks and broader M7 remain.

The original plan is retained at commit
`9ae95d9fb8c475b38823e6e78729f19fd61ef5e8`. Its planning base was
`0424983629beeae222337216cbea8d89276a38e8`, compiler source tree
`8a45f02fdf5c9d1bf5e8634426817c9df664568c`. Historical line anchors below
refer to that base. The parent [AGENTS.md](../AGENTS.md), [Blorp 2 rules](AGENTS.md),
[handoff spec](../docs/HANDOFF_SPEC.md), and
[source plan](BOOTSTRAP_SOURCE_PLAN.md#acceptance-and-cost-boundaries) govern.

## Problem and scope

The source plan's first-order pilot coalesces three identical type-list
translations. They currently pass a function value to private
`translated_list[T,U]`, retaining a compiler-source callback dependency.
There is no intended language or diagnostic change and no feature red to invent.
The read-only reproduction is:

```sh
rg -n 'translated_list' blorp_2/src/specialize/specialize.brp
```

At the planning base this finds the helper definition and eleven calls. Three
calls translate `List[Checked.TypeRef]` through the same `concrete_type` child,
with identical context. After this pilot those three use one private first-order
helper; the other eight calls and generic function-type helper remain unchanged.

Only [specialize](src/specialize/specialize.brp) may change in production.
Existing specialization TestSuites may receive the bounded characterization below.
No new fixture files, library/runtime API, public export, data carrier, dispatch
enum, registry, cache, traversal framework or semantic recomputation. Do not
migrate other callbacks, signature parameters, record fields or M7 in this slice.

The complete eleven-to-eight domain-traversal proposal additionally coalesces
record-construction fields and record-update replacements, both calling
`translate_record_field`. Its arithmetic is `11 - (3 - 1) - (2 - 1) = 8`.
That second pair is separate. This pilot leaves eight callback calls, not eight
completed first-order traversals, and does not retire the HOF dependency.

## Proposed solution and code

Add private `concrete_types(arguments, substitution, unions, span, records)` next
to `concrete_type`. Pass its existing facts directly rather than a larger state
container. Each child still goes through `concrete_type`; sealed prepared
instances remain the authority for all subsequent lookups.

| Existing site | Child span | Lookup retained after successful translation |
| --- | --- | --- |
| `concrete_record`, lines 560-565 | `span` | `lookup_record_instance` |
| `concrete_type` / `AppliedUnionType`, lines 627-632 | `span` | `find_union_instance` |
| `translate_call` / `Checked.UserFunction`, lines 2173-2178 | `call.span` | `find_instance` |

Current record code (`src/specialize/specialize.brp:560`):

```blorp
concrete ?= translated_list(
    arguments,
    pure func(
        value: Checked.TypeRef,
    ): concrete_type(value, substitution, unions, span, records),
)
lookup_record_instance(declaration, concrete, records, span)
```

Replace just the list translation:

```blorp
concrete ?= concrete_types(arguments, substitution, unions, span, records)
lookup_record_instance(declaration, concrete, records, span)
```

The two other sites retain their existing `match`, success/error branches,
lookup keys and diagnostic construction. Replace their matched expression with
`concrete_types(arguments, substitution, unions, span, records)` and
`concrete_types(arguments, substitution, unions, call.span, records)` respectively.

Use the existing `translated_list` loop shape from lines 483-503, with a direct
child call:

```blorp
private pure func concrete_types(
    arguments: List[Checked.TypeRef],
    substitution: List[TypeSubstitution[TypeRef]],
    unions: List[UnionInstance],
    span: Span,
    records: List[RecordInstance],
) -> Result[List[TypeRef], Diagnostic]:
    var concrete: List[TypeRef] = []
    var failure: Option[Diagnostic] = None

    for argument in arguments:
        match concrete_type(argument, substitution, unions, span, records):
            Ok(value):
                concrete = concrete.append(value)
            Err(error):
                failure = Some(error)
                break

    match failure:
        Some(error):
            Err(error)
        None:
            Ok(concrete)
```

The local List builder has no published alias while growing. Preserve one child
call per visited argument, checked argument order, immediate break on the first
Err, unchanged Diagnostic payload and cleanup of the partial builder. Empty
arguments yield `Ok([])`. Only a complete successful list reaches instance
lookup. Do not move any surrounding expression, change substitution/nominal
equality, discover an instance, resolve names or reconstruct checked facts.
Do not use propagation inside the loop to add another source-subset dependency.

Signature parameters are deliberately excluded: their callback consumes
`Checked.TypeUse` and passes each element's own span. It is not this translation.

## Testing and limits of the oracles

Reuse the existing `checked` and `specialized` helpers in
[test_generic_records](test/unit/test_specialize/test_generic_records.brp),
`checked` in [test_multiple_function_parameters](test/unit/test_specialize/test_multiple_function_parameters.brp)
and [test_multiple_union_parameters](test/unit/test_specialize/test_multiple_union_parameters.brp),
and `specialize`/`target_is` in
[test_specialization_collection](test/unit/test_specialize/test_specialization_collection.brp).
These enter through ordinary checking and public specialization; they do not
forge `CheckedProgram` or call the new private helper.

First obtain baseline green for existing receiver/phantom-record tests,
`test_ordered_calls_and_instances_preserve_int_string_permutation`,
`test_forwarding_substitution_is_permuted_and_caller_owned`,
`test_phantom_keys_include_every_argument_and_nominal_owner`,
`test_third_concrete_payload_uses_the_third_argument`,
`test_later_argument_prepares_a_nested_semantic_dependency`, and collection
ordering tests. Their no-argument calls also exercise an empty type-argument list.

Add one baseline-green callback to `test_generic_records.brp`, using its existing
`specialized` helper and this embedded source, with a final newline:

```blorp
fixed record Pair[A, B, Phantom] { first: A, second: B }
pure func make[A, B, Phantom](first: A, second: B, phantom: Phantom) -> Pair[A, B, Phantom]:
    { first = first, second = second }
func main() -> Int:
    first = make(7, "left", 0)
    second = make(8, "right", "tag")
    first.first
```

Assert the published concrete facts: exactly two record instances, each with
ordered `[IntType, StringType]` fields despite different phantom arguments;
distinct owners in first-use order; each specialized `make` return and actual
`ConstructRecord` owner agree; and both main binding types name the corresponding
owner. This couples asymmetric field order to phantom-key identity through
reachable code. Use the existing public concrete variants/projections, not a
new test export or a source-text/count assertion.

Prove sensitivity with separate, compile-successful mutants: reverse the helper's
result order; omit a later translated argument. The named ordering, phantom,
third-payload or new record assertion must fail for the intended wrong instance
or argument sequence. Restore exact source bytes and rerun green after each.
Build failures, timeouts and unrelated failures are not oracle kills.

First-error behavior also requires direct comparison with the old loop and the
three surrounding matches: the same child call/arguments/span, Err assignment,
break and final Err payload, with lookup unreachable after failure. Accepted
checked facts normally exclude those defensive child errors. Existing checker
rejections do not dynamically test that branch. Do not add an export, sealed-fact
bypass or observer to manufacture it; report that executed coverage limit.

## Future commands and acceptance

Run only after a separate writer/compiled-lane grant, from the authorized
implementation checkout. Verify the supporting host is FRESH after `make` before
direct tests; stop if it is not. No commands here authorize work during planning.

```sh
scripts/compiler-build-status
make
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 \
  blorp_2/test/unit/test_specialize/test_generic_records.brp \
  blorp_2/test/unit/test_specialize/test_multiple_function_parameters.brp \
  blorp_2/test/unit/test_specialize/test_multiple_union_parameters.brp \
  blorp_2/test/unit/test_specialize/test_specialization_collection.brp
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_specialize
BLORP_CC=/usr/bin/clang BLORP_2_INSTRUCTION_CHECK=required make -C blorp_2 test
```

The first test command is the narrow baseline/characterization/mutation loop;
run an individual owning suite when that is shorter. Require baseline and
restored callback counts and exact outcomes, then focused/full gate success.
Read raw generated host C for the builder's ownership/append behavior and
changes caused by removing captures; do not infer uniqueness or lower cost from
source alone. Require complete local B/C fixture C identity, stdout/status and
exact diagnostics, including notes/help/spans. No emitted-C changes, alternate
main, helper invocation or native execution protocol change is authorized for
the target fixtures; do not repair their output C.

Planning estimate: 30-40 gross added / +10-20 net production lines, not a promise.
Hard ceilings: **100 added / +48 net production**, **100 added / +95 net tests**,
**zero new fixture files or lines**. Test limits include callback registration
and any test-local helper. Reuse existing helpers and assertions; if a meaningful
test needs more, report before committing. Report production, tests, fixtures and
documentation separately; do not compress formatting or delete coverage.

## Historical proposed cost boundary

This is the original proposed criterion, retained as history. Its cumulative
C/R0 requirement is prospectively superseded for this exact three-site slice
by the current finishing contract below. Original compliance is UNVERIFIED;
no original passing or failing measurement is claimed here.

Follow the source-plan cost contract and the explicit baseline/library policy in
[the source-byte plan](SOURCE_BYTE_MIGRATION_PLAN.md#commands-identity-and-costs).
This is a separate measurement, not permission to reuse another pilot's samples.
Freeze the then accepted integration base and a single supporting-host epoch:
same normal/diagnostic host binaries, explicitly identical host stdlib for every
producer/proxy, bootstrap provenance, Clang, flags and paired build modes.
Generate each pilot C once; link unchanged C into normal diagnostics0 and strict
diagnostics1 producers. Keep setup outside measured boundaries.

| Variant | Compiler source and temporary target library |
| --- | --- |
| R0 | Exact unmodified reset `78bc406d6646eb7a1b61700b71d1faa9e9eaca09` and its original temporary target library |
| B | Immediately preceding accepted source and matching target library |
| C | This three-site source refactor over B, with B's identical target library |

Use the original **452 byte-identical shared programs** cumulatively. Local B/C
also includes all four accepted API fixtures (`byte_at`, `byte_at_zero`,
`from_codepoint_ownership`, `from_codepoint_nul`) with their existing exact bytes
and absolute caps. Verify membership and bytes, not just counts. Do not ask R0 to
accept unsupported APIs, change its source/library or construct an overlay.

Require **C/B <= 1.03 per local input**, **total C/R0 <= 1.03 per shared reset
input**, and **both ratios for the frozen-host source-to-C proxy**, separately
for allocations and normal min3 retired instructions. Cumulative totals include
all intervening accepted feature and target-library costs; subtract none.
Keep full cumulative raw target C diffs and explain every accepted intervening
feature change, including UTF-8 argv cleanup and String helpers. An unexplained
diff stops; local source refactoring still requires exact B/C target C identity.
Host-generated compiler C may change; preserve and inspect it separately rather
than claiming its cross-version identity or normalizing it.

Reuse the direct recipes with one physical input/CWD/output boundary, three
serial alternating normal samples per variant and separate strict leak/count
runs. Require positive balanced strict allocations/releases with zero leaks;
normal memory modes stay unset. The host diagnostic allocation checkpoint is a
cumulative construction proxy, not full-process strict leak balance or target
self-compilation. Retain every sample and all source/library/C/binary/tool hashes,
commands and raw outcomes. Preserve stricter existing fixture ceilings. No
speedup is predicted; a cap breach cannot be offset by aggregate wins.

## Review, handback and stop conditions

Keep this plan separately reviewable from later implementation. After the
coordinator resolves integration order and dependencies, freeze B/epoch and
obtain baseline green before production changes. Implementation needs root and
independent code-reviewer/test-runner evidence before any commit; the coordinator
owns integration and publication.

Return branch/commits and exact patch hashes; physical added/deleted/net counts;
baseline, mutant and restored named outcomes; generated-C/diagnostic identity;
local/cumulative per-input and proxy verdicts; frozen provenance and raw paths;
and observed limits. State that eight callbacks and the function-type helper
remain. Stop for stale premises, wider scope, LOC/test/cost breach, unexpected
identity or error-order change, ownership/host-compiler defect, missing evidence,
or any need for another mechanism. Reduce and report the witness to root; do not
fix adjacent work, waive a ceiling, adapt fixtures or add a counterfactual reset.

## Current finishing amendment

### Deliverable and ownership

The managed worktree is
`/Users/keithphilpott/.codex/worktrees/finish-first-order/blorp`, branch
`codex/finish-first-order`, prepared from main
`e29a5396a147fc94b91a51f5285f2b0bd265429a`. Landing order is source-byte
migration, concat, stderr, this slice, then unary control. Refresh onto the actual
accepted preceding main before freezing final correctness/cost baselines; this
preparation base is not authority to measure an obsolete source stack.

The original candidate at `e8f9/blorp` remains untouched. Only
`src/specialize/specialize.brp` and
`test/unit/test_specialize/test_generic_records.brp` were transferred; their
reviewed binary diff SHA256 is
`37c65a28b7a96441d7c626c42acc4629a93ad1eb1a17c7ea3804bb7288ea9bcb`.
The transferred patch matches exactly. Production is +28/-18, net +10;
tests are +44/-0, net +44; fixture growth is zero. The original 100 gross/+48
net production and 100 gross/+95 net test ceilings remain binding. This plan
and the eventual evidence report are counted separately as documentation.

The private helper publishes only a complete successful List. Argument order,
substitution, union/record authority and each original span remain unchanged.
The same first child error is returned before instance lookup; empty arguments
return `Ok([])`. No spelling lookup, new phase, cache or general iterator is
introduced. Eight generic translated_list calls and its function-typed helper
remain; this is not completion of callback migration.

### Current correctness and mutation protocol

Wait for root's exclusive compiled lease. Use the explicitly pinned approved
host (borrowed c04/root standard library when no local host is available), with
its real executable, source, runtime, standard-library and toolchain provenance.
Do not relabel a borrowed binary FRESH for this worktree. Its explicit library
selection and exact commands are retained before execution.

First run the four named owning suites with the new record characterization
and the accepted baseline production file. Then restore the exact candidate
production bytes and run the same suites. Baseline characterization must pass;
there is no invented functional red for this source refactor. Preserve each
raw command, exit, stdout/stderr, named callback count and source hash.

Prove two separate compile-successful semantic mutants: reverse the new
helper's translated result order, then omit a later translated argument. Use
only the helper body. Ordering, phantom-owner or third-argument callbacks must
fail for the intended wrong sequence; compile failures/timeouts are not kills.
Restore and hash the exact candidate after each mutant and rerun its owning
suite green before the next change. Do not add an export or forge checked facts.
Defensive child-error coverage remains the direct old/new loop and caller review
specified above, not an executed first-error claim.

After mutation restoration, run the whole specialization unit directory and all
current unit/runtime/grammar suites. Generate candidate pilot C once with the
pinned host at the chosen canonical source/output boundary and link unchanged C
at O0 for diagnostics modes 0 and 1. Read the generated helper and its callers
for captured-owner removal, append ownership and partial-builder cleanup. Run
all current e2e cases using the linked candidate, required instruction counters,
unmodified fixture C and normal language entrypoints. No per-fixture compiler
rebuild or generated-internal call is permitted. Root repeats destination
acceptance after integration.

### Prospective current matched-cost contract

Before any current sample, root and an independent compiler expert agreed this
refreshed contract under the user's explicit roadmap-adjustment authorization.
It supersedes only this three-site slice's historical C/R0 hard landing gate.
The original criterion and any actual historical results stay literal; original
compliance is UNVERIFIED unless retained actual observations establish otherwise.
This is a prospective decision with no current measurements to tune against,
not an inherited source-byte exception, feature subtraction or new host epoch.

The current local requirement is at most +3% allocations and normal minimum-of-
three retired instructions for every applicable current input and the whole
frozen-host source-to-C proxy. Freeze B at the then accepted preceding main and
C at that base plus this exact two-file patch; target libraries must be byte-
identical. Include the complete current registered corpus, current feature/API
cases and their exact existing absolute caps, rather than reusing only the
historical 452+4 subset. No fictional R0 observations for newer APIs. Current
registered invocation identities, bytes, modes and expected diagnostics must be
frozen and reviewed before execution. Freeze B, its complete target library,
the host/checkpoint protocol and complete corpus before the first sample.
Never roll B forward to C or refreeze after a failed observation. Each input
and the same original checkpoint proxy must pass both exact integer tests:

```text
100 * C_allocations <= 103 * B_allocations
100 * C_normal_min3_instructions <= 103 * B_normal_min3_instructions
```

Use one physical source/input/CWD/output boundary, explicit frozen libraries,
serial strict pilot calls and three alternating normal samples per variant.
Strict pilot counts must be positive, balanced and leak-free; all normal memory
modes stay unset. Complete local B/C emitted fixture C, exit, stdout/stderr and
diagnostic bytes must match exactly. Host-generated compiler C may differ;
retain and review its raw delta separately. Never normalize C or diagnostics.

Preserve the original host proxy's schema1
`artifact_construction_complete total_allocations` checkpoint protocol with
`BLORP_MEMORY_STATS=1`, leak mode unset, status 0 and exact Generated output.
A different approved host/metric epoch requires an explicit matched transition
and policy review; exit-time strict totals cannot replace that checkpoint
silently. Keep the known old-host strict-leak limitation separate from mandatory
pilot/native zero-leak acceptance. All existing absolute input/e2e and physical
LOC ceilings remain binding, as do exact local C/diagnostic identity and positive
balanced strict zero-leak checks. No aggregate offset can compensate for a
failed input or proxy metric. Stop and retain a failure; this contract supplies
no automatic widening. No performance result or full readiness is claimed until
the numerical gates and actual samples pass.

### Review and completion

Static transfer/source review and `git diff --check` precede lane use. Root and
an independent compiler expert review the refreshed complete patch/plan and,
after execution, all correctness, mutation, identity and cost evidence before
commit. Root owns squash integration and push. Keep raw receipts under ignored
`build/finish-first-order/`; retain one concise benchmark result with exact
commands, hashes, counts, numerical ratios and coverage limits before landing.
No new controller, cache, test observer, API or optimization is authorized.
