# Compiler Maintainability Roadmap

This roadmap turns the compiler maintainability audit into an actionable plan.
It focuses on places where compiler behavior is still recovered from names,
fallback scans, optional typed payloads, or late rescue paths. The goal is not
to remove every migration shim immediately. The goal is to retire the shims that
make semantic identity and phase boundaries hard to reason about.

## Goals

- Represent semantic distinctions directly in AST, Typed AST, Core, or session
  data instead of encoding them in source-like strings.
- Move checks to the earliest phase that has enough information.
- Make later Core phases consume explicit contracts rather than rediscovering
  layout, ownership, purity, or callee identity.
- Keep migration boundaries inventoried with tests until they are deleted.

## Priority Model

- **P0:** Semantic identity or correctness can depend on load order, encoded
  names, or ambiguous fallbacks.
- **P1:** Phase boundaries are respected mostly by convention, comments, or
  partial invariants.
- **P2:** Tooling, ergonomics, or low-risk cleanup that reduces future drift.

## Call Resolution Alignment

`docs/CALL_RESOLUTION.md` is the governing design for call and name resolution
cleanup. This roadmap should bridge into that plan rather than introduce a
parallel resolver model.

Constraints to preserve while removing ad-hoc code:

- Keep the documented source-level resolution order stable: local values,
  functions, constructors, then trait-method names for bare identifiers.
- Keep field access ahead of UFCS. Tuple fields, record fields, and
  function-valued fields must continue to win over method syntax.
- Keep method-only UFCS candidates method-only. Type imports and prelude type
  registration enable `value.method(...)`; they do not make `method(...)`
  available as a bare call.
- Keep method syntax selection in its current order: ordinary in-scope
  functions that accept the receiver are considered before method-only UFCS
  candidates.
- Preserve overload selection behavior for higher-order functions, including
  delayed handling of flexible lambdas and current-function purity bias.
- Treat module aliases as source-level resolution facts. The existing fake
  `Module` value is a migration shim, not a model to deepen.
- Carry callable identity forward metadata-first. Existing names and mangled
  forms can remain compatibility paths until typed metadata covers every call
  shape.

## Phase 1: Stabilize Semantic Identity

### 1. Replace cross-module record fallback scans

**Priority:** P0

`compiler/lib/infer.ml` currently falls back to scanning every loaded module for
a record by bare name when the environment lookup misses. The loaded-module list
is assembled from session state, so duplicate record names can become
order-sensitive.

Plan:

- Introduce an explicit module-qualified record/type identity for indirect type
  references that cross module boundaries.
- Use `Session.type_index` or a stricter successor as the lookup boundary, but
  make duplicate public type names a diagnostic instead of silently replacing
  entries.
- Remove the scan over `Modules.get_all_modules ()` from record-field
  resolution once typed identity is available.
- Add regression tests with two imported modules that both define `record Config`
  and a third module that references one indirectly through a union payload.

Progress:

- `Session.type_index` now preserves duplicate public type homes as ambiguity
  instead of letting the later registration overwrite the earlier one.
- Record-field resolution no longer scans `Modules.get_all_modules ()` by bare
  record name. The remaining legacy fallback resolves only when the session type
  index has exactly one home.
- Bare ambiguous record field/update access now reports the ambiguous modules
  instead of producing a generic "not a record" error or selecting a cache-order
  winner.

Remaining:

- Carry module-qualified identity for every indirect payload so the legacy bare
  fallback can be deleted, not just made conflict-aware.
- Add an integration regression around the remaining legacy path once a
  source-level case that still produces a bare indirect payload is isolated.

Acceptance:

- Indirect record resolution is deterministic and conflict-aware.
- No production path searches all loaded modules by bare record name.
- Diagnostics name the ambiguous modules and suggest importing or qualifying the
  intended type.

### 2. Make UFCS target identity structured

**Priority:** P0

UFCS dispatch currently encodes module path and selected overload identity into
names like `__ufcs_std$list__get#123`, then later phases parse those strings
back into module/function/def-id facts.

This is the Core handoff part of `docs/CALL_RESOLUTION.md` Phase 6. The current
`#<def_id>` suffix is an intentional migration bridge; removing it safely means
lowering from typed `resolved_call` metadata, not changing how source calls are
selected.

Plan:

- Audit the typed `resolved_call` coverage for all method-call shapes:
  ordinary function-as-method, prelude method-only UFCS, imported-type
  method-only UFCS, qualified impl methods, and overloaded higher-order methods.
- Lower selected direct calls from `expr_type_info.resolved_call` into
  `Core.var.vdef_id` or a richer `Core.call_target`, while preserving the
  existing mangled name as the emitted-symbol compatibility name.
- Replace the `__ufcs_...#<def_id>` handoff only after Core receives the same
  selected `def_id` from typed metadata. Keep the string path behind an
  assertion or compatibility branch until coverage is complete.
- Keep `Codegen_names.parse_ufcs_name` temporarily for backend compatibility,
  then delete it only after Core resolution no longer needs it for selected
  source-level UFCS calls.
- Add tests for overloaded UFCS methods with the same source name but different
  purity and callback signatures, plus fixtures that assert field access wins
  over UFCS and method-only candidates are not callable bare.

Progress:

- Core lowering now copies direct callable ids from typed `resolved_call`
  metadata onto the lowered callee `Core.var.vdef_id` when the callee lowers to
  a `CVar`.
- Inference now has unit coverage for local method syntax, imported
  function-as-method syntax, prelude method-only UFCS, imported-type
  method-only UFCS, overloaded higher-order method-only UFCS, and the existing
  qualified impl-method path.
- Selected method-only UFCS calls now carry their chosen overload target and an
  explicit `CallMethodOnlyUfcs` syntax marker in typed metadata, including the
  source module origin, instead of recovering provenance from the parsed
  `__ufcs_...#<def_id>` suffix.
- The legacy `__ufcs_...#<def_id>` suffix path remains active, and lowering
  now rejects mismatches between that encoded id and the typed `resolved_call`
  id instead of silently choosing one.
- Qualified module calls that lower through `CField` now carry the selected
  direct callable id on the module-alias `CVar`, preserving the qualified-call
  shape needed by monomorphization and intrinsic dispatch.
- `Core_resolve` now maintains a def-id-to-canonical-name index and prefers
  carried callable ids for selected bare and qualified user calls, while
  treating duplicate Core def-ids as ambiguous instead of order-dependent.
- Selected direct call identity now has an explicit transitional Core call kind
  instead of being smuggled through the qualified module-alias `CVar`.
  Monomorphization can still specialize selected generic calls before
  resolution, and `Core_resolve` replaces the selected id with the canonical
  `CKUser` target before later stages.

Remaining:

- Audit parsed-export fallback coverage for qualified functions before making
  Core handoff invariants strict.
- Delete UFCS string parsing and first-arg UFCS recovery only after the typed
  metadata path covers parsed exports, ambiguous/unselected UFCS recovery, and
  imported prelude methods end to end.

Acceptance:

- No compiler phase needs to parse `__ufcs_` names to recover selected overload
  identity.
- Different overloads of the same UFCS method cannot collide in temporary
  inference environments.
- Core dumps show the selected target in a form that is understandable without
  reverse-engineering a mangled string.
- The `call_resolution_matrix.brp` behavior is unchanged.

### 3. Replace `__pure` suffix routing for overloads

**Priority:** P0

Pure/impure overload disambiguation still relies on suffixing the pure variant
with `__pure`. The flattening pass documents a case where the impure primary
name can win and the pure variant may become unreferenced.

This should move in lockstep with the call-resolution plan, especially
`resolved_call` metadata and `Purity_analysis` consuming callable ids. A
name-only fix here would keep the same maintainability problem under a different
suffix.

Plan:

- Make overload resolution return the selected overload entry, including purity
  and `def_id`, for ordinary calls, qualified calls, and UFCS calls.
- Update module flattening so pure/impure overloads are declarations with
  distinct identities, not names that downstream phases rediscover by suffix.
- Update `Core_resolve` and `Core_mono` to consume the selected identity instead
  of trying the unsuffixed name and then `name ^ "__pure"`.
- Keep flexible-lambda overload selection deferred until expected argument
  types can upgrade lambda purity, matching the current resolver behavior.
- Preserve helpful diagnostics for old/internal spellings until the old path is
  removed.

Progress:

- `Core_resolve` now prefers carried callable ids when tagging selected user
  calls, so a call whose source spelling is the impure primary can still route
  to the selected pure overload's canonical Core name.
- `Core_mono` now indexes generic bodies by `cf_def_id` and consults carried
  ids before trying source-name or `__pure` suffix fallbacks for bare calls and
  qualified module calls. Duplicate generic body ids are treated as ambiguous
  and fall back to the older name path instead of selecting by insertion order.
- Unit coverage now includes bare and qualified generic overload calls where
  the visible callee name is the unsuffixed primary but the selected callable id
  targets the pure `__pure` body.

Remaining:

- Module flattening still represents pure/impure overload pairs by suffixing
  the pure declaration name. That suffix is now less authoritative at call
  sites, but it is still part of the declaration naming model.
- `Core_mono` and backend helper passes still keep name/suffix fallback paths
  for unannotated or hand-built Core. Those should become assertions or
  compatibility-only branches after typed call metadata covers parsed-export
  and legacy Core inputs.
- Flexible-lambda overload selection still depends on the existing inference
  machinery; the next cleanup is to make the selected overload entry the only
  source of callable identity for those delayed choices.

Acceptance:

- A pure caller selects the pure overload when both pure and impure bodies exist.
- The generated Core/C target is selected by `def_id`, not by suffix fallback.
- Tests cover pure and impure callbacks, flexible lambdas, qualified calls, and
  method syntax.

## Phase 2: Structure Compiler-Owned Operations

### 4. Add specs for synthesized std bodies

**Priority:** P1

`compiler/lib/core_intrinsics.ml` synthesizes std function bodies with a large
name-based dispatcher. Some arms validate arity with helper patterns, but others
only check the first argument type before using `List.nth` or `List.hd`.

Plan:

- Introduce a `std_body_spec` table keyed by module path and function name.
  Each entry should declare arity, receiver shape if any, type-variable policy,
  return-shape constraints, and the synthesis callback.
- Convert the highest-risk arms first: `std/string`, `std/set`, `std/dict`,
  `std/slice`, `std/bytes`, fixed-point helpers, and math helpers.
- Make malformed specs return `None` or a structured Core error, never an OCaml
  `Failure("nth")`.
- Keep the existing IR-building helpers, but require all dispatch arms to obtain
  params through arity-checked helpers.

Progress:

- Added malformed-arity unit coverage across the high-risk synthesized std
  areas: string, bytes, set, dict, fixed, slice, and math.
- Added explicit arity gates to the synthesized string, bytes, set, dict,
  fixed, and slice dispatch arms that previously accepted a receiver-shaped
  first parameter and then indexed into the remaining parameter list.
- Added checked parameter binders in `core_intrinsics.ml` and converted the
  synthesized bytes, set, dict, fixed, and slice arms to consume exact-arity
  binders instead of indexing `params` after branch guards.
- Removed the remaining direct `List.nth params` and `List.hd params` reads
  from `core_intrinsics.ml`; legacy arms now route through one checked
  parameter boundary that converts malformed missing-parameter access into
  `None`.
- Introduced the first `std_body_spec` table for the malformed-signature cases
  currently covered by tests. The synthesis wrapper now checks module path,
  function name, arity, receiver shape, and selected return-shape constraints
  before entering those legacy dispatcher arms.
- Expanded `std_body_spec` coverage to wrapper-style std bodies for bytes,
  fixed, time, stream, hash, tensor constructors/accessors, vector reductions,
  and matrix operations. The matcher now supports explicit first-parameter
  tensor checks and return-shape checks for named, option-wrapped, and tensor
  returns.
- Expanded the guard across the synthesized collection/text surface:
  `std/list`, `std/string`, `std/set`, `std/dict`, and the remaining
  `std/bytes` IR-built bodies now declare module path, arity, receiver shape,
  and practical return-shape constraints in the spec table.
- Added collision regressions for the old name-first dispatcher behavior:
  stream calls with list-shaped signatures, tensor/vector calls with list
  receivers, matrix calls with non-tensor receivers, and string/bytes hash
  variants with swapped receiver types.
- Added collection/text collision regressions for list-vs-string length/count,
  list-vs-set map, list-vs-stream find, dict-vs-list set/length, and
  bytes-vs-list/string overload names.
- Extended the spec matcher with optional per-parameter shape constraints, so
  table entries can reject malformed non-receiver arguments instead of relying
  on branch-local first-argument checks.
- Expanded fixed, slice, and scalar math specs to declare exact argument shapes
  and return shapes, including same-width float unary/binary/ternary math and
  float classification helpers.
- Added malformed-signature regressions for fixed return-shape mistakes, slice
  wrong-return/wrong-prefix cases, and scalar math calls with wrong return type
  or wrong non-first argument type.
- Replaced the local `checked_param` bridge with `std_body_checked_params`,
  returned by the spec check and passed into the legacy dispatcher as its
  checked parameter boundary.
- Extended exact per-parameter spec coverage to bytes, time, stream, hash, and
  tensor/vector/matrix wrapper bodies where non-receiver arguments are concrete
  parts of the std signature.
- Added wrapper collision regressions for bytes append/blit, time
  `from_parts`/`format_time`, stream range/take, vector dot, matrix multiply, and
  hash HMAC calls with malformed later arguments.
- Added an explicit function-parameter shape to the synthesized-body spec
  matcher and used it for list, set, and stream callback positions.
- Filled in concrete list/string/set/dict/stream parameter shapes for index,
  count, second-collection, string, and char arguments that were previously
  guarded only by arity plus receiver shape.
- Added malformed-signature regressions for list callback/index/collection
  mismatches, string `Char`/`Int`/`String` argument mismatches, set
  callback/second-set mismatches, and stream callback mismatches.
- Added relation-aware parameter shapes for receiver element/key/value
  invariants, covering list element arguments, same-element list operands, set
  element/set operands, and dict key/value arguments.
- Added malformed-signature regressions for list element/default/target
  mismatches, set element/same-element set mismatches, and dict key/value
  mismatches.
- Clarified the transitional synthesis boundary with explicit
  spec-checked-vs-legacy-unchecked parameter results and documented the shallow
  vs relation-aware parameter-shape semantics.
- Split the synthesized-body spec table into subsystem-specific groups, so new
  entries land near the subsystem they guard instead of in one monolithic list.
- Added an explicit spec-table entry for the remaining `std/system`
  compatibility wrapper, `now_microseconds`, and corrected the nearby comment
  so it no longer implies all system synthesis arms have been removed.
- Added a first spec-owned synthesis action for `std/hash` wrappers, moving
  those C builtin forwards out of the ad hoc name-match dispatcher.
- Extended spec-owned synthesis actions to `std/time` wrappers and the
  `std/system.now_microseconds` compatibility wrapper.
- Moved the remaining stream C wrappers and bytes C-only wrappers to
  spec-owned synthesis actions, leaving their old name-match dispatcher arms
  behind.
- Moved fixed C wrappers to spec-owned synthesis, including explicit trailing
  default-precision synthesis for `fixed` and `from_int`.
- Moved tensor constructor/access C wrappers and matrix kernel C wrappers to
  spec-owned synthesis, leaving tensor `length` and vector reductions in the
  hand-built IR path.
- Moved tensor/vector `length` to spec-owned synthesis as an explicit
  `TensorLength` action, removing the remaining name-only legacy arm for tensor
  length while keeping vector reductions in the hand-built IR path.
- The covered malformed entries now return `None` instead of raising
  `Failure("nth")` or silently accepting ignored extra parameters.

Remaining:

- Expand `std_body_spec` coverage from the current std-wrapper/tensor guard
  layer to the remaining synthesized bodies and move synthesis callbacks behind
  the table.
- Continue folding local arity binders into the checked-parameter API where it
  reduces branch-local signature logic.
- Add further relation shapes only when a remaining signature invariant cannot
  already be represented by the current receiver, parameter, and return-shape
  table.
- Move from ad hoc branch guards to one table that declares arity, receiver
  shape, return-shape constraints, and synthesis callback together.

Acceptance:

- Malformed-arity tests exist for each synthesized std subsystem, not only
  `std/list`.
- `core_intrinsics.ml` has no direct `List.nth params` or `List.hd params`
  outside arity-checked helpers.
- Adding a new synthesized body requires adding its spec and tests.

### 5. Shrink `CKUnknown` to a true unresolved state

**Priority:** P1

`Core_specialize` still uses `CKUnknown` plus callee names to recognize bitwise
operators, tensor functions, and debug reflection helpers. These are
compiler-owned operations and should be explicit before specialization.

Plan:

- Resolve bitwise functions to `CKIntrinsic` or a dedicated call kind during
  inference or `Core_resolve`.
- Represent `type_name` and `is_heap` as explicit debug-reflection Core nodes or
  explicit compiler-owned call kinds.
- Resolve tensor reductions and elementwise operations through a typed registry
  instead of testing `func_name` under `CKUnknown`.
- Add an invariant that any remaining `CKUnknown` at the specialize boundary is
  one of a deliberately documented set.

Progress:

- Bitwise operators now resolve to `CKIntrinsic` in `Core_resolve` through the
  intrinsic registry, instead of reaching `Core_specialize` as `CKUnknown`
  name matches.
- Added regressions proving bitwise calls resolve to intrinsics while a
  user-defined `bit_and` still wins by normal user-function resolution.
- Debug reflection helpers (`type_name` and `is_heap`) now resolve to explicit
  `CKIntrinsic` calls before specialization. `Core_specialize` folds only those
  tagged calls, not arbitrary callees with matching source names.
- Added resolver coverage for bare, imported, module-qualified, and prefixed
  debug reflection calls, plus specialization coverage proving unresolved
  reflection-shaped names no longer fold by name.
- Matrix tensor kernels (`multiply_vector`,
  `multiply_transposed_vector`, `outer`) now resolve through the
  module-aware builtin table to typed placeholder C builtins. `Core_specialize`
  still appends dimensions and selects the element-specific runtime entry, but
  no longer recognizes those operations from `CKUnknown` source names.

Acceptance:

- `Core_specialize` no longer pattern-matches `CKUnknown` by source name for
  compiler-owned operations.
- Unknown calls that survive resolution produce clear errors or are documented
  as intentionally deferred.
- Existing tensor, bitwise, and debug reflection tests pass with the explicit
  call representation.

### 6. Replace manual runtime ABI string maps with typed contracts

**Priority:** P1

`Core_specialize.void_boxed_arg_positions` is a string-keyed map that must stay
in sync with runtime C signatures. Existing invariants help, but the contract is
still duplicated outside the runtime-facing metadata.

Plan:

- Move runtime builtin ABI facts into a typed builtin descriptor table.
- Include argument passing, boxed positions, ownership behavior, purity, and
  whether the function is backend-specific or plain C runtime.
- Make `Core_specialize`, `Core_codegen_prepare`, invariants, and emit consume
  the same descriptor.
- Add a consistency test that compares descriptor coverage against
  `runtime_decl.c` declarations for compiler-owned runtime calls where feasible.

Acceptance:

- A runtime builtin's erased-storage behavior is declared once.
- Adding a new runtime builtin without ABI metadata fails a unit test.
- Emitter-side boxing fallback is only retained for direct unit fixtures, not as
  a production semantic recovery path.

## Phase 3: Make Ownership Facts Explicit

### 7. Remove Perceus branch alias fallbacks

**Priority:** P1

Perceus still falls back to a conservative occurrence counter when branches
return aliases into the target value. That fallback is documented and tested,
but it means ownership behavior is inferred from occurrences rather than carried
as explicit branch-result facts.

Plan:

- Add a branch-result ownership summary that can represent fresh result,
  borrowed alias, consumed owner, and mixed branch cases.
- Compute that summary before branch balancing and store or pass it explicitly.
- Use the summary in `CIf`, `CMatchArms`, and decision-tree `CMatch` paths.
- Delete legacy `count_uses` fallback paths once all branch forms consume the
  structured summary.

Progress:

- Removed the alias-return branch fallback from Perceus `CIf`, `CMatchArms`,
  and compiled `CMatch` balancing. Branches that return aliases now use the
  existing `ownership_uses.returns_alias` summary directly, so borrowed reads
  in the same branch no longer inflate refcounts through `count_uses`.
- Added unit coverage for alias-returning `if`, raw match-arm, and compiled
  decision-tree branches that borrow the owner before returning a field alias.
- Freshened pattern bindings that shadow the owner being balanced, including
  existing RC operators on the shadowed binding, so branch-local drops target
  the outer owner instead of the match payload.
- Added nested match/if and pattern-shadowing coverage, including runtime
  leak/sanitize regressions for shadowed match payloads and nested mixed
  branches.

Acceptance:

- Branch balancing does not treat every occurrence as consuming unless a named
  invariant says it must.
- Alias-returning branch tests still pass under leak check and sanitize.
- New ownership tests cover nested match/if combinations and pattern-shadowing
  cases.

## Phase 4: Finish Typed Payload Migration

### 8. Split parsed and typed expression shapes

**Priority:** P1

`Ast.expr` still carries optional `expr_type`, optional `expr_type_info`, and
optional RC annotations. The project already has hygiene tests around this
boundary, but later phases can still observe missing metadata unless guarded.

Plan:

- Continue moving typed-only operations onto `Typed_ast.expr` accessors.
- Make Core lowering accept typed expressions whose semantic/value/proof
  metadata is required by construction.
- Retire legacy `expr_type` reads after the final compatibility callers are
  removed.
- Keep a test inventory that fails when new production callers read legacy
  typed payloads directly.

Progress:

- Removed the remaining production caller of `Ast.expr_type_info_from_type`.
  Inference now builds structured expression metadata through its value-slot
  helper, and the source hygiene inventory only allows the compatibility helper
  at its `Ast` definition boundary.
- Moved LSP hover expression metadata access behind
  `Type_metadata_format.hover_type_view_for_expr` and added a hygiene guard so
  hover does not read the transitional AST typed payload directly.

Acceptance:

- Core lowering cannot receive an expression without structured type metadata.
- Hover, diagnostics, and formatter compatibility paths are explicit and
  isolated.
- `Ast.expr_type_info_from_type` becomes a compatibility helper used only in
  tests or removed entirely.

## Phase 5: Tooling and Low-Risk Cleanup

### 9. Replace LSP text heuristics with parser-backed spans where practical

**Priority:** P2

Signature help and cursor lookup use text-level heuristics. This is acceptable
for lightweight tooling, but it is brittle around nested calls, multiline
expressions, and strings.

Plan:

- Reuse parser/typed AST spans for signature-help call-site detection when the
  document parses.
- Keep text fallback for incomplete documents, but isolate it behind a named
  fallback module.
- Add LSP tests for nested calls, method syntax, multiline calls, and string
  literals containing punctuation.

Progress:

- Signature help now uses parsed `ECall` spans before falling back to the
  text scanner, and resolved call metadata supplies the source function name for
  method syntax while preserving module-qualified lookup names.
- Added regressions for long multiline calls that exceed the old text fallback
  window, method syntax active-parameter mapping, module-qualified calls,
  nested calls, and punctuation inside string arguments.
- Added a separate regression for the best-effort text fallback on incomplete
  documents that do not have a parsed AST.

Acceptance:

- Parsed documents use AST span lookup first.
- Text fallback is documented as best-effort and tested separately.

### 10. Reuse strict path classification in CLI formatting

**Priority:** P2

The CLI auto-format skip for std files uses a plain string-prefix check, while
`Modules.is_path_under_dir` already handles directory boundaries.

Plan:

- Replace the local prefix check in `compiler/bin/blorp.ml` with the shared
  strict path classification.
- Add a small unit or CLI test where a user directory has a `std` prefix but is
  not the configured std directory.

Progress:

- Replaced the CLI auto-format std skip's raw prefix check with
  `Modules.is_path_under_dir`, exposed the strict helper at the module
  boundary, and added a regression for `std/` versus `std_backup/` paths.

Acceptance:

- User files under paths such as `std_backup/` are not misclassified as stdlib
  files.
- Stdlib files remain excluded from auto-formatting.

## Suggested Execution Order

1. Cross-module type identity and record resolution.
2. Structured call targets for UFCS and pure/impure overloads.
3. Std body synthesis specs and malformed-arity coverage.
4. `CKUnknown` reduction and typed runtime builtin ABI metadata.
5. Perceus branch ownership summaries.
6. Typed AST payload cleanup.
7. LSP and CLI cleanup.

Each item should land with a focused regression test. If an item touches user
syntax, diagnostics, or public behavior, update `docs/GUIDE.md` and
`docs/GRAMMAR.md` in the same change.
