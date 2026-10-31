# Blorp 2 cleanup roadmap

Make the Blorp 2 compiler and standard library smaller and more consistent.
Stages run lowest risk first, then highest return within a risk band. Every
stage except C2 and C3 must reduce production lines. C2 is about flat, and
C3 adds about one line per fixed loop. Fixture output stays identical except
where a step names a change, as listed under
[Acceptance criteria](#acceptance-criteria).

## Problem

A read-only probe at `c45796a03` covered every file in `src/` and
`standard_library/`: 62 files, 45,161 lines. It found the same facts and
idioms re-stated across phases. Counts come from these patterns, run in
`blorp_2/`:

| Pattern | `git grep -nE` pattern over `src` | Sites |
| --- | --- | ---: |
| first-error loops | `var (failure\|invalid)[^=]*Option\[` | 228 |
| `Void ?=` guard bindings | `^[[:space:]]+[a-z_]+: Void \?=` | 138 |
| raw identity comparisons | `_number\([^)]*\) == [a-z_]+_number\(` | 93 |
| inline placeholder span | `compiler_source\(\), start = 0, end = 0` | 20 |
| internal-error help text | `report this compiler error` | 17 |
| internal-error messages | `"internal compiler error` | 12 |

Several first-error loops have no `break`, so a later error replaces the
first. This happens in:

- `specialize` `prepare_function`;
- `check/expressions` `freeze_callable_choice`;
- `check/equality` `equality_template`;
- the duplicate-implementation and member loops in `check/traits`;
- `namespace` `declared_entries` (`namespace.brp:544`);
- `verify`'s signature-membership loop (`verify.brp:3658`), which reports
  internal errors only.

Some facts have several authorities:

- **Builtin operations.** Each phase writes its own partial list of builtin
  operations, sometimes with a wildcard arm. A wildcard means a missed
  operation still compiles.
- **Consuming operations.** The set of operations that consume their first
  operand appears in five places, one of them C text.
- **Checked-expression walks.** Three walks over `CheckedForm` disagree on
  which children they visit.
- **Owner types.** Emit rebuilds owner types by position from `own`'s
  numbering.
- **Entrypoint list type.** The entrypoint hard-codes the C name `blorp_l_0_s`.

Each of these breaks [principle 1 or 2](AGENTS.md#principles): a change needs
edits in several places, and a missed edit still compiles.

## Background

The rules come from four documents:

- [`AGENTS.md`](AGENTS.md) owns the principles, the approval rule for new
  mechanisms, and validation.
- The parent [`AGENTS.md`](../AGENTS.md) requires before and after
  self-compile measurements for data-model refactors.
- [`ROADMAP.md`](ROADMAP.md#cost-and-evidence-rules) sets the cost rules.
- [M9](ROADMAP.md#m9-post-self-compilation-architecture-audit) remains the
  full architecture audit. This roadmap is the narrower cleanup queue.

Two pieces of work were in flight when this plan was written:

- **O1, [ownership contracts](ROADMAP.md#ownership-contracts-roadmap),** which
  wrote `own/own.brp`, `lower/lower.brp`, `verify/verify.brp` and the runtime
  C text. O1 landed on 2026-10-30 (`393438c00`), so its gate below is lifted.
- **L3/L4, [list buffer reuse](ROADMAP.md#list-buffer-reuse-roadmap),**
  rewrites `standard_library/list.brp`.

**Gated on O1** means the item lands after O1, or before it only when rebased
onto O1's latest branch. **Gated on L3** means the same for L3/L4.

The gate applies to every commit in every stage that edits one of these
files, whether or not the item is marked:

- O1: `own/own.brp`, `lower/lower.brp`, `verify/verify.brp`,
  `runtime/list.brp` or `runtime/string_concat.brp`;
- L3: `standard_library/list.brp`.

A stage that also touches other files splits those edits into their own
commits, so the ungated part can land first. Examples: C1's `PendingWhile`
comment in `lower`, C3's verify loop, C4's spans and help text, and C6a's and
C7's sites in `own`, `lower` and `verify`.

Facts about the seed that the helpers below rely on:

- `_ ?= expr` parses and checks (`test/unit/test_parse/test_discard_propagation.brp`).
- Generic functions with function-typed parameters exist, for example
  `specialize`'s private `translated_list[T, U]`. No source uses three type
  parameters yet.
- `?=` is rejected inside lambdas ([README](README.md)).
- Opaque types get no automatic `Equatable`. A module may implement it for
  its own opaque type: see `test/e2e/fixtures/equality/dispatch.brp`.
- There is no early return.

## Proposed solution

There are ten stages, C0 to C9. Each stage is a series of small commits with
one concern per commit, and each commit lands on its own. Steps marked
**approval** add a shared helper type or module, or use a language feature in
compiler source for the first time. They wait for Keith's yes, which they ask
for with a concrete example and the simpler alternative.

Line estimates give their basis. They are reading estimates, not prototypes,
and each stage reports its actual count.

### C0: fixture-identity recipe

`scripts/blorp2-fixpoint --prove` already keeps, per fixture, B's C, exit
status, stdout and stderr under `build/fixpoint/fixtures/b/`. To check that a
change leaves fixture output alone:

1. Run `--prove` on `main` and copy that directory aside.
2. Run `--prove` on the candidate.
3. Compare with `diff -r`. Any difference must be one the step names.

This needs no new tooling and no approval.

### C1: delete what nothing uses; fix what misleads

No representation or output changes. Re-run each grep before deleting.

- **Unused imports and constants:**
  - `DOLLAR_BYTE` and the `Text: concat` import in `parse/parse.brp`;
  - the `concat` imports in `emit/diagnostics.brp`, `namespace/builtins.brp`
    and `load/load.brp`;
  - `not` and `occurrence_fields` in `check/signatures.brp`;
  - `ScopedBindingId` in `check/callables.brp`;
  - `accepted_traits` in `check/constants.brp`.
- **Never-constructed variants and their render arms:**
  - five `CheckerInvariant` variants: `VariantOccurrenceWithoutUnion`,
    `DirectCallInSimpleBase`, `ConstructorReceiver`,
    `MissingConstructorArgument` and `RuntimeGenericContract`;
  - `UnsupportedForm.WhileStatement`;
  - `DiagnosticNote.TypeDeclaration`.

  Six other variants are raised only inside `check/render.brp` through
  `render_fault`, so they stay: `InvalidResolvedUnion`,
  `InvalidResolvedVariant`, `InvalidParameterName`,
  `ParameterOwnerWithoutParameter`, `InvalidParsedName` and `InvalidCallName`.
- **Small type deletions:** `traits.brp`'s `EqualityOutcome` and its round
  trip.
- **Skipped after inspection:**
  - `SpecialNames`/`InitialNames.special` has no production reader, but about
    six tests use its ids as handles. Removing it is a test rewrite, not a
    deletion.
  - `check.brp`'s `declaration_id`, `record_declaration_id` and
    `union_declaration_id` cannot move into tests, because they read the
    opaque `CheckedProgram`.
  - Making `recursion.brp`'s `parameter_index` return `Option[Int]` adds
    lines for a miss the preceding loop rules out.
- **Comments:**
  - Move doc comments to the declaration they describe. Today they sit above
    `PendingWhile` (`lower`), `callable_binding_value` (`specialize`),
    `ResolvedImplementation` (`namespace`) and `SelfBinding`
    (`declarations`).
  - Fix `admit_scalar_loop`'s comment, which contradicts its per-function call.
  - Fix the `syntax.brp` comments saying `while`, lambdas, `if` and `private`
    are "rejected until" a milestone.
  - Fix `errors.brp`'s reference to `check_render`.
  - Replace `declarations.brp`'s bare "step 2c" with the concept it names.
- **Unread guard bindings:** `ready: Void ?= ...` becomes `_: Void ?= ...`; the
  annotation stays because a bare constructor needs an expected type. This is
  line-neutral but makes intent visible.
- **Standard library README:** it says "Traits and FFI remain inactive" and
  states a trait-placement rule that `Equatable` does not follow.
- **Gated on O1:** the `own.brp` `borrowed_result` comment, verify's "PRE",
  "old-H", "fresh H" and "P", and `own`'s unread `TerminalArguments` span.

Basis: about 7 variants with their render arms, the test-only records,
`EqualityOutcome`, imports and constants, about −150 lines.

### C2: correct user-visible messages

Each correction is one commit with an exact message, help and span test.

- The `?=` rejection says it "is not supported yet ... arrives with the join
  milestone". It is raised only for a `?=` outside a function's top-level
  statements, so it should say that.
- Parser `KEYWORD_HELP` mentions a select/receive `from`, which Blorp 2 does
  not have.
- The "report this compiler error" help is unified on "input program".
- `lower`'s `invalid_binding` ("invalid checked binding identity") is also
  raised for a break outside a loop, an arm without a value and a missing
  loop context. Each gets its own message. These are internal errors. This
  item is gated on O1.

Basis: lines roughly unchanged.

### C3: one first-error rule

For each loop listed in [Problem](#problem), add the missing `break`, plus a
test that fails before the fix and pins the first error. One site per commit.
`declared_entries` and verify's membership loop report only internal
invariants, which no source program can reach. Their test is a direct phase
test with hand-built malformed input. If that input cannot be built, the
commit justifies the `break` by reading.
Only these sites may change diagnostic order. `prepare_function`'s call loop
carries a `prepared` list, so its fix is a `break`, not a helper.

Basis: about +1 line per site, plus tests.

Status: landed except verify's membership loop, which waits for O1, as does
C2's `invalid_binding` item. The equality summary loop in `traits.brp` had
the same defect and was fixed too. Sites whose failures are unreachable or
indistinguishable from source carry their justification in the commit.

### C4: one internal-error authority

`utils/syntax.brp` holds the only constructors. These lose their copies:
`own.brp` and `emit.brp` (private copies), `traits.brp` (`compiler_span()`)
and `load.brp` (`rejection`). The `own.brp` part is gated on O1.

```blorp
-- Before (own.brp; emit.brp and traits.brp have copies; 20 sites write the
-- span literal inline, and 12 build the message by hand):
private pure func internal_span() -> Span:
	{ source = compiler_source(), start = 0, end = 0 }

private pure func internal_error(span: Span, message: String) -> Diagnostic:
	{ span = span, note = None, message = "internal compiler error: ${message}",
	  help = "report this compiler error with the input program" }

-- After (utils/syntax.brp, next to `diagnostic`):
-- Diagnostics about the compiler itself, not the program, point here.
pure func compiler_span() -> Span:
	{ source = compiler_source(), start = 0, end = 0 }

pure func internal_error(span: Span, message: String) -> Diagnostic:
	diagnostic(span, "internal compiler error: ${message}", "report this compiler error with the input program")
```

Use a real span where one is in reach: `inline_record_field` has
`field.span`, and `postfix_hints` has its own position.

Emit reuses variants for unrelated failures:

- a missing function row is reported as `MissingValueType`;
- a missing selection arm or enclosing loop as `MissingJoinTransfer`;
- a wrong operation shape as `StatementOnlyValue`.

Each gets its own variant. Internal-error text changes on these paths.

Basis: the span swaps are line-neutral. The private copies, the 12
hand-built messages and the duplicate help text save about 60 lines, and the
new emit variants add about 15. Net about −45.

Status: landed at −67 production lines. One exception to the O1 gate: the
shared `internal_error` collides with `own.brp`'s identical private copy, so
that copy was deleted. Left for O1: `own.brp`'s `internal_span`, `lower.brp`'s
hand-built internal messages and `verify.brp`'s inline placeholder spans.
The shared constructors are pinned in `test_syntax`; the four new emit
variants have no rendering test, because the emit diagnostics suite is
deferred.

### C5: local de-duplication, one module per commit

Each commit is mechanical, behavior-preserving, and covered by its module's
suite and the C0 check.

| Module | Change | Gate |
| --- | --- | --- |
| `parse` | One separated-list loop for the six copies (`consume_lambda_parameters`, `consume_tuple_values`, `consume_pattern_fields`, `consume_list_pattern`, `consume_tuple_pattern`, `consume_tuple_for_binder`). One loop for `consume_disjunction_rest`/`consume_conjunction_rest`. One type-parameter list parser that rejects bounds where they are not allowed. Build `loop_control_words`/`indented_value_words` by interpolation. Fold the 14 single-caller `at_*` predicates into `at_symbol`/`at_keyword`. Keep `declared` as a `var` instead of recomputing it from seven lists (`parse.brp:4404`). | |
| `check` | Merge the conflict check in `scope` `bind_local`/`bind_callable`. Merge `callables` `function_contract`/`receiver_contract`, with one purity check and `receiver_bindings` computed once. In `constructors`, one arity check (`find_variant`, `find_qualified_variant`, `plan_known_*`) and one readiness fold (`finish_pending_*`). In `patterns`, one column builder and `CheckedSelection` instead of `BuiltSelection`. In `render`, `type_spelling`'s record arm uses `type_spellings`. In `bodies`, one `Break`/`Continue` arm. Hand loops become `repeat`/`join`. | |
| `specialize` | One list-equality helper for `same_arguments`, `same_callables`, `same_partial_arguments` and `same_known_arguments`. `contains_parameter` uses `any`. One forwarding step for `callable_mode`/`translated_callable`. | |
| `emit`/`lex` | A lookup helper for the 16 `MissingRuntimeArgument` sites. `callable_types` computed once into `ProgramInventory`. Rename `quoted_token` to `hole_quoted_token`. An `append_scanned` helper for `lex`'s three copies. | |
| `lower` | `project_place`/`project_argument` share one id-allocating step (`lower.brp:1225`). | O1 |
| `verify` | `payload_value`/`transfer_value` helpers. One borrow-parent check for the three in `verify_definition_result`. One `discharge_payloads` match. One successor helper in `selection_possibilities`. | O1 |
| `runtime` | One error-message and size-cap helper in the C text. `read_file`/`write_file` pass `path->bytes`. | O1 |
| `standard_library` | One parameter-naming rule: receiver `self`, pairs `left`/`right`, `default`. | L3 for `list.brp` |

Status: the `parse` row landed at −217 lines. `consume_list_pattern` keeps
its own loop (trailing-comma diagnostic and spread), 13 predicates were
folded, and about 30 multi-caller `at_*` predicates could still use
`at_keyword`/`at_symbol`. Self-compile allocations rose 21.9k (+0.09%), from
the per-item list wrapper; instructions are unchanged within noise.

The `check` row landed at −103 lines. `find_variant` and
`find_qualified_variant` had no arity check to merge (only the `plan_known_*`
pair did), and `type_spelling` no longer has a record arm since records and
unions share `NominalType`. Fixtures are identical; self-compile allocations
rose 17.6k (+0.08%, route closures) and instructions fell 0.3%.

The `specialize` row landed at −41 lines: one `same_elements` loop replaces
the four `same_*` list loops, and `contains_parameter`'s nominal arm uses
`any`. The `callable_mode`/`translated_callable` forwarding step was skipped:
the two scan different lists and match different variants, and a shared
helper came out 12 lines larger. Fixtures are identical; self-compile
allocations are unchanged and instructions fell about 0.5%.

Basis: the parse items remove about 300 lines, the de-duplicated pairs about
150, and the verify blocks about 100. About −600.

### C6: identity equality (approval)

This is the first written trait implementation in compiler source, which
[AGENTS.md](AGENTS.md#scope) bounds per reviewed task. The first commit takes
one id through the pinned seed and measures generated C and cost. The rest
follow only if that holds.

```blorp
-- Before, at 93 sites:
union_number(known.declaration) == union_number(key.declaration)

-- After, once in utils/ids.brp:
implements Equatable for UnionId:
	pure func equals(left: Self, right: Self) -> Bool:
		from_opaque UnionId(left) == from_opaque UnionId(right)

-- and at each site, with `UnionId methods` imported:
known.declaration == key.declaration
```

- **C6a:** implement `Equatable` for each opaque id. Replace the raw
  comparisons and the `same_*` helpers that only compare numbers. Keep
  `*_number` for indexing. Each comparing module gains a `methods` import.
  Basis: about line-neutral.
- **C6b:** once the ids are `Equatable`, automatic structural equality covers
  `TypeRef`, `AggregateId`, `BodyOwner` and `ScopedBindingId`. That lets us
  delete `model.brp`'s `same_type`/`same_types`, `same_body`,
  `same_aggregate` and `same_scoped_binding`, plus `specialize`'s `same_type`
  and `same_arguments`. Helpers that compare only part of a value, such as
  `render` `same_kind`, stay. C6b's first commit compiles `TypeRef`'s
  automatic equality through the pinned seed. That covers its recursive,
  list-bearing shape. The commit also measures List `equals` against
  `same_types` before any helper is deleted. If either fails or exceeds the
  ceiling, the structural helpers stay.
  Basis: these helpers total about 250 lines.

`specialize`'s `union_digest` is an alias of `union_number`. It is deleted:
the index keys on `union_number`, and key equality compares declarations.

Fallback, if C6a's first commit exceeds the cost ceiling: named
`same_union`-style helpers beside each `*_number`, with no C6b.

### C7: first-error helpers (approval)

Move `translated_list` into a new `utils/results.brp`, generic over the error
type, because the checker uses `CheckError` and later phases use
`Diagnostic`. Add `first_error` for "check each, stop at the first failure".
The simpler alternative is to keep the hand loops, already made consistent by
C3. The first commit proves three type parameters with a function-typed
argument in the seed.

```blorp
-- utils/results.brp
-- Maps every value, stopping at and returning the first failure.
pure func translated_list[T, U, E](values: List[T], translate: pure (T) -> Result[U, E]) -> Result[List[U], E]:
	...

-- Checks every value, stopping at and returning the first failure.
pure func first_error[T, E](values: List[T], check: pure (T) -> Result[Void, E]) -> Result[Void, E]:
	...

-- Before (verify.brp:3658, after C3 added its break):
var failure: Option[Diagnostic] = None
for value_type in signature_types:
	match verify_type_membership(value_type, program.unions, program.records, span):
		Ok(_): void
		Err(error):
			failure = Some(error)
			break
_ ?= match failure:
	Some(error): Err(error)
	None: Ok(void)

-- After:
_ ?= first_error(signature_types, pure func(value_type: TypeRef) -> Result[Void, Diagnostic]:
	verify_type_membership(value_type, program.unions, program.records, span))
```

Convert only loops that just map or just check, and whose step has no `?=`,
because `?=` is rejected in lambdas. This is a pure refactor: fixture output
stays identical.

Each lambda is a callable value. A capturing lambda passes a managed
environment, and each lambda is its own callable choice, so each converted
site specializes its own helper instance. Measure allocations, instructions
and the compiler's emitted C size per phase. A phase over the ceiling keeps
its loops, and the result is recorded.

Basis: fewer than half of the 228 sites qualify, at 5 to 8 lines each. About
−600 to −900.

### C8: make impossible states unrepresentable

Each commit states its design in its description.

- **Two-tag switches become named `Bool`s:**
  - `DependencyOrigin` becomes `trait_derived`;
  - `SignatureRole` becomes `is_entry`;
  - `LoadMode` becomes a `Bool`;
  - `ResultInferenceState` has three tags but its consumers tell only
    `Incompatible` apart, so it becomes `result_incompatible`.
- **`own`** (gated on O1): `borrow_argument` returns only borrowed or
  unmanaged arguments, so the unreachable `ConsumedArgument` arms and their
  errors go.
- **Trait method parsing** returns one method, not a one-element list.
- **Entrypoint list type** (gated on O1): the argv list type comes from
  `list_c_type(list_element_key(StringType))` in emit and the runtime, not
  the literal `blorp_l_0_s`.

Basis: about −120.

### C9: shared traversals and stacks (approval for new types)

- `type_children(TypeRef)` in `check/model.brp` replaces five hand walks in
  `declarations.brp` and `specialize`'s copy of `contains_parameter`.
- `child_expressions(CheckedForm)` replaces the three `CheckedForm` walks.
  Today only `callable_creations` visits lambda captures. The design note
  decides whether the other two should, and a test pins the outcome.
- One generic `push_at[T]` replaces the eight retyped set-or-append helpers.
  A `WorkStack[T]` owns the list and count that `elaborate_value` (59 push
  pairs) and `declarations` (about 12) keep side by side. **Approval**, with
  the alternative of only `push_at`.
- `own` `insert_steps` splits its join, loop and define arms, with one
  `schedule_drop` and one span rule. Gated on O1.

Each item gets its own commit and fixture identity. A traversal change also
gets the [scaling series](ROADMAP.md#cost-and-evidence-rules).

Basis: the five type walks and three form walks save about 300 lines, and
the stack helpers about 150. About −450.

### Later: single cross-phase authorities

Each item is a producer-to-consumer migration that removes the old
representation in the same change. Each needs its own reviewed design before
code, and each runs as the single writer of the schemas it touches.

1. **Builtin operations.** The closed `ParsedRuntimeOperation` in
   `utils/syntax.brp` is the identity. Each phase owns its own fact as one
   exhaustive `match` with no wildcard:
   - label and help in `syntax`;
   - contract in `namespace`;
   - consumption and the in-place helper name come from O1's
     `reuses_first_operand`/`consuming_helper_name`;
   - the C fragment in `runtime`.

   `specialize`'s 100-line variant rebuild becomes a `map_operation` beside
   the type. This needs no shared table and no registry, and runs after O1.
2. **Owner types.** `own` publishes each owner's type on `OwnedFunction`, and
   emit stops rebuilding them. Gated on O1.
3. **Declaration order.** Assembly publishes the source order of
   declarations, and `namespace` stops merging five kinds by `span.start`.
   The design names the one authority, and the per-kind lists are either
   derived from it or replace it, never both.
4. **Type-parameter classification.** Recorded once at interning, as a
   name-table attribute rather than a token split. Do it only if the design
   shows no net line growth, because a token split touches every
   `IdentifierToken` arm.
5. **Test-entry identity.** Name the test-library words once and share the
   test module path between `load` and `assemble`.

Basis: not estimated until each design exists.

### Out of scope

- **Context records** for threaded parameter bundles (`TranslationContext`,
  `own`'s `sources, enclosing, first_value, span`) trade against
  [CODE_STYLE](../docs/CODE_STYLE.md)'s narrowest-parameter rule. That is a
  separate decision for Keith.
- **Trait home and list recursion.** The `Orderable`/`Equatable` home and the
  list library's recursion belong to the trait work and L3.
- **"host" comments.** References such as "host 4.2" stay until someone
  identifies the document they cite.
- **The Blorp 2 formatter.** It settles the tab and space indentation in
  `bool.brp`.

## Risks and unknowns

- **C6 trait-call and C7 closure costs** are unmeasured. Each stage's first
  commit measures, and each has a stated fallback.
- **Collisions with O1 and L3.** Gated items wait. Rebase before each commit,
  and skip any item already fixed on `main`.
- **Diagnostic changes** are limited to C2, C3 and C4's internal errors, and
  each is pinned by a test.
- **Estimates** come from reading. Stages report actual production and test
  line counts.

## Testing

For each commit:

- the owning module's unit suite, then `make -C blorp_2 test`;
- the C0 fixture comparison, and any differences must be named by the step;
- `scripts/blorp2-fixpoint --prove` before each push that touches `src/`.

For each stage, measure self-compile allocations, minimum retired
instructions and emitted C size before and after, matched and serial, per the
[cost rules](ROADMAP.md#cost-and-evidence-rules). Report production and test
lines separately.

## Acceptance criteria

- Production lines (`src/` and `standard_library/`) fall at every stage
  except C2, which is about flat, and C3, which adds about one line per site. Expected total: about −2,000 before
  the later cross-phase items. Test lines grow only by the tests the steps
  name.
- Fixture output is identical at every commit. The only exceptions:
  - C2's corrected messages;
  - C3's first-error order at the listed sites;
  - C4's internal-error text and emit variants;
  - any change a C9 design note decides and pins.
- Self-compile allocations and minimum retired instructions stay within +3%
  of each stage's frozen baseline, and within +3% of the roadmap-start
  baseline in total.
- `make -C blorp_2 test` and `scripts/blorp2-fixpoint --prove` pass at each
  push.
- Each stage's report gives before and after counts for the problem-table
  patterns it targets.

## Release strategy

Each commit lands on `main` after review. No step changes the seed's input
language, so no seed rotation is needed.

## Handback

At each stage boundary, report:
- the commits, with production and test line changes;
- before and after pattern counts;
- the cost report path;
- items skipped, either because they were already fixed or over the ceiling;
- any finding that proved wrong.
