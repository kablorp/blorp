# Cost quirks

Plan revision 1, 2026-11-12, written against origin/main `525b653c2` and
rebased onto `476ceef23` on 2026-11-13; the measurements below were taken on
`525b653c2`. The
cost-quirks pilot of 2026-11-12 found these; its probes, attribution tables
and raw samples are in the main checkout's ignored
`build/pilots/2026-11-12/cost-quirks/`.

**Status:** approved by Keith on 2026-11-12 (decisions below). Four landings,
stacked: L1, L2, L3 and Q2. No seed rotation is part of this plan; the
compiler's own source benefits from L1 and L2 once a later seed carries them.

## Problem

Two programs that mean the same thing could cost very differently, and the
compiler's source bent to avoid the expensive forms. Paired probes (cheap form
against expensive form, strict leak check and copy counts) sorted the
documented quirks:

| Quirk | Expensive form | Finding |
|---|---|---|
| Q1 | a `?=` between a `var` List and its appends | Stale: same cost today. L3 removes the notes. |
| Q3 | a path of a record function that returns a helper's result | Stale: same cost today. L3. |
| Q11 | `"${output}<${label}>;"` with a borrowed hole | 2,006 allocations against 6 for the `+` chain. L1. |
| Q9 | a loop that rebuilds a record of Lists | 6,001 allocations and 4,000 List copies against 2. L2. |
| Q2 | an accumulator passed to a fallible call in a `failure` + `break` loop | 3,000 copies, 19.7 MB, against none when the loop carries a `Result`. Q2. |
| Q4 | a lambda bound to a local before it is passed | One allocation per call. Not changed (decision 3). |
| Q5, Q6 | a record or tuple with a managed field, built and read at once | One allocation each. Records design pilot (decision 4). |
| Q7, Q16 | reading a value after updating it; growing a List element in place | Inherent: the old value is still read. The README rule covers them. |

## Keith's decisions, 2026-11-12

1. L1 and L2: yes.
2. Q2: `?=` stays out of loops. Emit's failure-flag loops become loops that
   carry a `Result`.
3. Q4, the named lambda: change it only if that saves a lot and is simple. It
   does not qualify: one site in `src`, none in the standard library or the
   benchmarks. Not in scope.
4. Q5 and Q6, records and tuples by value: yes in principle, in a separate
   design pilot (below).
5. The README states the cost rule.

## Landings

1. **L1, interpolation as one left-nested chain** (`check`). The checker
   joined interpolation parts as a balanced tree, so every right subtree began
   a new String from its first part and copied it when that part was borrowed
   or a literal. Parts now append in written order to the String the earlier
   parts built, as a written `+` sum does; specialize and lower already walk
   such chains in a loop.
2. **L2, a loop iteration ends the obligations it inherits at their last
   read** (`own`). An owner a loop arm inherits from an enclosing block could
   be moved at its last read in the iteration but was otherwise dropped only
   at the back edge, so a record rebuilt each iteration stayed alive while its
   fields were updated, and every update copied. An owner the iteration
   reads now ends at its last read there, as a yielding join arm's entering
   owner does. One it inherits but never reads still ends at the back edge,
   where a join arm would drop it on entry (see Follow-ups). The README states
   the cost rule in its Own section.
3. **L3, stale notes.** Comments that described copies of the retired host
   compiler.
4. **Q2, loops that carry a `Result`** (`emit`). Each loop that passed its
   accumulator to a fallible call kept an `output` and a `failure` flag; on
   the failure path the old accumulator is the loop's result, so every call
   copied it. One `Result` replaces each pair.

## Records by value

Moved from `NEXT.md` on 2026-11-12. A plain record returned by value is
heap-allocated even when the caller destructures it at once. The lexer's
`SkippedLines` costs one allocation per code line, 37,160 in the self-compile
(`LSP_PLAN.md`, landing 2's measurement). Records are 56.5% of the
self-compile's allocations (7.98 M of 14.13 M at `203541220`). Keith approved
values by representation in principle; the records design pilot owns it.
`LSP_PLAN.md`'s landing 5 made `ResolvedType` a one-case union for this
reason: as a record it cost 22,253 more allocations. It becomes a record
when records are passed by value.

## Follow-ups

Found while landing; none is in this stack.

- **Drop unread inherited owners on entry.** An owner a loop iteration
  inherits but never reads lasts until its back edge, where a yielding join
  arm drops one on entry (`own.brp`, `loop_consumption_uses` against
  `entering_discharges`). In
  `while bag.items.length() < n: bag = { bag | items = bag.items.append(x) }`
  the condition's projection is such an owner, so each append still copies.
  `owned_parameters/loop_condition_projection` records today's count.
- **`loop_uses` carries only held header rows,** and lowering never produces
  a held header (`lower.brp:2190`, `2393`). Remove the parameter or give it a
  producer.
- **A `while` condition's owners last until each arm's exit.** A loop match's
  prefix keeps every owner to its arms, so an update inside the condition,
  such as `[7].append(total)`, copies instead of consuming its operand.
- **Two emit loops still keep a failure flag:**
  - `append_record_ownership`'s field loop, which passes its accumulator to
    `append_storage_operation`;
  - `append_loop`'s header loop, which carries two accumulators under one
    flag, so one `Result` would need a record or tuple.

## Measurements

Host: Apple M4, macOS 26.7.1, Apple clang 21.0.0. Other sessions ran gates
throughout. Allocations come from one strict run of a
`-DBLORP_MEMORY_DIAGNOSTICS=1` binary and are deterministic; instructions are
the median of alternating `/usr/bin/time -l` runs.

`blorp/scripts/self-compile-cost` builds both sides from the pinned seed, so
for L1 and L2 it measures only what the change costs the compiler's passes.
Their benefit to the compiler's own code needs stage-2 compilers: each side's
seed-built compiler compiles its own source at `-O2`, normally and with memory
diagnostics, and both stage-2 compilers then compile the branch base's source.

### L1 (2026-11-12)

Base `525b653c2`, candidate `cost/l1-interpolation-chain`. Stage-2 compilers
compiled the base's source.

| | Base | L1 | Change |
|---|---:|---:|---:|
| Allocations (strict) | 14,130,149 | 13,932,953 | −197,196 (−1.40%) |
| Instructions (median of 5) | 12,377,762,686 | 12,262,323,752 | −0.93% |

- Instruction samples: base 12,377,762,686, 12,398,258,431, 12,385,795,311,
  12,356,183,952 and 12,370,513,772; L1 12,262,323,752, 12,265,225,318,
  12,281,552,516, 12,259,466,492 and 12,236,944,368, alternating sides.
- Stage-1 compilers (SHA-256): base `9f616f54…`, L1 `b2083b29…`. Stage-2 C:
  base `380ae66f…`, L1 `a1963871…`; the L1 stage-2 compiler reproduces its
  own C. Their C for the base's source: base `380ae66f…` (its own stage-2 C),
  L1 `46db21d4…`.
- The interpolation fixtures with 8, 32 and 128 holes allocate 5, 17 and 65
  times at base and twice each with L1. L1 lowers 25 exact runtime counts in
  all, those three included, raises none and raises no compile ceiling.
- A fixture with two 2,000-hole interpolations, one of them a record update's
  replacement that lowering scans for its base's reads, compiles at default C
  limits and allocates 6 times. Lowering's `collect_base_reads` recurses once
  per link of such a chain, and handles the 2,000 links.
- The pilot's attribution of the self-compile at `203541220`: String update
  copies fall from 20.4 MB to 10.3 MB. The largest site,
  `emit.append_selection_body` (8.65 MB), no longer copies.

### L2 (2026-11-12)

Base `cost/l1-interpolation-chain`, candidate `cost/l2-loop-last-read`.

- **Tests.**
  - `test_own`: "an inherited record drops before its field grows", which
    asserts that the record header's drop precedes the update, fails on L1
    and passes with L2.
  - `test_own` guards that pass on L1 too: "an inherited owner an update
    takes is not dropped" and "an inherited owner the iteration never reads
    retires at its edge".
  - `test_verify` guards, which pass on L1 too because verify is unchanged:
    "a back edge cannot retire an owner its iteration dropped", and "a back
    edge cannot discharge an owner made before its loop", which pins the rule
    (`verify.brp`, "loop edge discharges a captured owner") that keeps L2 from
    dropping an owner made before the loop.
- **Probes.** Seven fixtures under `owned_parameters/loop_*`. Each runs under
  strict accounting and ASan and UBSan, and prints the same output under L1
  and L2, which is the base compiler's output too.

  | Fixture | L1 | L2 |
  |---|---:|---:|
  | `loop_record` | 304 | 106 |
  | `loop_reads_every_iteration` | 18 | 18 |
  | `loop_reads_after_loop` | 9 | 9 |
  | `loop_one_branch` | 18 | 18 |
  | `loop_nested` | 25 | 22 |
  | `loop_exits` | 39 | 34 |
  | `loop_projection` | 35 | 33 |

  These are runtime allocations. Their compile ceilings are the L2 test
  compiler's measured cost on `476ceef23` plus 15%.
  `loop_condition_projection` (202 allocations) records the copy L2 leaves:
  see "Drop unread inherited owners on entry" under Follow-ups.
- **Lowered counts.** `record/update/field_accumulator` 57 to 53 and
  `source_loops/managed_headers` 27 to 25. No count rose.
- **Stage-2 self-compile** on L1's source: allocations 13,930,448 to
  13,929,785 (−663), median instructions 12,254,329,814 to 12,247,222,930
  (−0.06%, within noise). The compiler's own source avoids rebuilding a record
  in a loop, so L2 serves user code. Samples: L1 12,268,706,372,
  12,250,684,522, 12,265,757,681, 12,254,329,814 and 12,252,504,057; L2
  12,256,785,788, 12,247,222,930, 12,234,189,345, 12,257,489,950 and
  12,244,823,714. The L2 stage-2 compiler reproduces its own C (`94bd3323…`).

### Q2 (2026-11-13)

Base `cost/l3-stale-notes`, candidate `cost/q2-result-loops`. The rewritten
loops:
- `c_parameters`;
- `append_value_field_actions`;
- `append_union_action`;
- `append_boxed_union_release`;
- the owner-alias loop of `append_input_owners`, which `append_join` now
  calls for its outputs instead of repeating it.

`blorp/scripts/self-compile-cost` was run with five rounds. Both sides are
seed-built, which here is the point: the change is to the compiler's own
loops.

| | Base | Q2 | Change |
|---|---:|---:|---:|
| Fixed input allocations | 14,125,970 | 14,110,365 | −15,605 (−0.11%) |
| Fixed input instructions, median of 5 | 12,357,727,702 | 12,339,989,924 | −0.14% |
| Own source allocations | 14,125,970 | 14,115,792 | −0.07% |
| Own source instructions, median of 5 | 12,346,174,608 | 12,322,892,348 | −0.19% |

The fixed-input C is identical (`8a34d0bbce643bff`).

The pilot estimated about 99,500 allocations from the site's allocation
count. Most of those allocations are the first allocation of a String that
starts from `""`, which no loop shape removes. Two loops of the same pattern
remain (see Follow-ups).

### Explicit fixed compiler unions (2026-11-13)

Landed as `678b1df3b` on 2026-11-13. This record was first written to
`benchmarks/results/explicit-fixed-unions.md` and moved here on 2026-11-16,
because a change's full measurement belongs in its plan (root `AGENTS.md`).
The pass changes how 12 compiler records are stored, which is this plan's
"Records by value" concern.

105 ordinary union declarations in `blorp/src` now explicitly promise fixed
storage: 54 bare enums and 51 unions with payloads. The only production edits
are the declaration headers, in 29 files. No record, variant, function, test,
standard-library declaration or compiler rule changes.

#### Storage and scope

Bare unions already compile to C enums. Nonrecursive payload unions already
store their tag and active payload by value; `fixed` checks that their payloads
are unmanaged, nongeneric and nonrecursive. It also supplies the declared
promise required to inline a record containing a union:
[`inline_record_field`](src/common/codegen/specialize/specialize.brp)
checks the child's declaration flag, even if an ordinary union happens to be
unmanaged. Consequently this annotation pass changes some containing records.

For example, `BorrowSource` only carries opaque integer identities. Making it
fixed lets the ordinary `BorrowedValue` record stay inline; `OwnedArgument`
still cannot be declared fixed because it holds that ordinary record. This
pass does not convert records to make more unions eligible.

The audit covers all 284 source union declarations, public/private and
multiline forms: 10 were fixed already, 105 become fixed, and 169 remain
ordinary. The new candidates form the transitive closure over primitive
payloads, existing fixed records/unions, opaque representations and newly
fixed unions. Imported declarations were traced explicitly, including
`Unreadable`'s already-fixed filesystem `EntryError` and `ListError`.

Each exclusion has a first rejecting payload witness in the raw audit:
80 ordinary records, 39 ordinary unions, 32 applied/callable types, 11 Strings,
four generic declarations and three opaque representations over unfixed types.
These categories count declarations by their first witness, not all reasons.
There were no unresolved payload names. The checker's fixed-storage and cycle
validation accepts the complete changed compiler source.

#### Changed declarations

Paths below are relative to `blorp/src/`.

| Module | Newly fixed unions |
| --- | --- |
| `common/analysis/assemble.brp` | `VisitState` |
| `common/analysis/check/bodies.brp` | `JoinBindingState`, `VoidPosition` |
| `common/analysis/check/declarations.brp` | `PayloadSpan`, `TypeAccess` |
| `common/analysis/check/errors.brp` | `AbsentSupertrait`, `ArithmeticTrait`, `CanonicalFamily`, `CheckerInvariant`, `ComparisonTrait`, `ConstantError`, `ListElementReference`, `QualifierKind`, `RecursionError`, `TypeTermError`, `UnsupportedForm` |
| `common/analysis/check/inference.brp` | `InferencePublication`, `InferenceReadiness`, `InferenceRelation`, `SlotOrigin` |
| `common/analysis/check/instantiation_paths.brp` | `PathOperation` |
| `common/analysis/check/model.brp` | `BindingOrigin`, `EqualityMember`, `ListLengthTest` |
| `common/analysis/check/patterns.brp` | `PatternPosition` |
| `common/analysis/check/recursion.brp` | `ConstructorOperation`, `ConstructorSlot` |
| `common/analysis/ids.brp` | `FunctionRole` |
| `common/analysis/namespace/builtins.brp` | `BuiltinTypeErrorKind`, `BuiltinTypeRole`, `DesignatedUnionRole`, `SystemParameter`, `SystemPayload` |
| `common/analysis/namespace/namespace.brp` | `FunctionSource`, `OfferedValue`, `Origin`, `Space`, `ValueBinding` |
| `common/codegen/emit/diagnostics.brp` | `AggregateKind`, `EmissionFailure` |
| `common/codegen/emit/emit.brp` | `Comparison`, `LocalAssignment`, `OwnershipAction` |
| `common/codegen/lower/lower.brp` | `SourceControl` |
| `common/codegen/own/own.brp` | `BorrowSource`, `Carried`, `EnteringDischarge`, `HeaderEntry`, `Labelling`, `ResultOwnership`, `ReturnTransfer`, `StoredPayload`, `Transfer` |
| `common/codegen/runtime/list.brp` | `ListUpdate` |
| `common/codegen/runtime/system.brp` | `SharedFragment` |
| `common/codegen/specialize/specialize.brp` | `BackReference`, `CallableStorage`, `CaptureBinding`, `RecordOrigin`, `RecordRepresentation`, `RecordStoragePolicy`, `RequestSource`, `UnionRepresentation` |
| `common/codegen/verify/verify.brp` | `AggregateDefinition`, `ExitEdge`, `LayoutVisit`, `OwnerSlot`, `OwnerState` |
| `common/syntax/lex.brp` | `ByteClass`, `PipeForm` |
| `common/syntax/parse.brp` | `BindingOperator`, `EnclosedTypeMode`, `Enclosure`, `ImportOrigin`, `LoopControl`, `OpaqueDirection`, `StatementContext`, `ValueEnding` |
| `common/syntax/source.brp` | `ModuleKind`, `SourceRole` |
| `common/syntax/syntax.brp` | `ArithmeticOperator`, `ComparisonOperator`, `EntryResult`, `FunctionExecution`, `Keyword`, `ParsedBinder`, `ParsedBuiltinType`, `ParsedReceiverHead`, `ParsedRuntimeOperation`, `PatternHead`, `Purity`, `Spacing`, `SpreadTarget`, `StringForm`, `Symbol`, `SystemOperation`, `Visibility` |
| `format/flat.brp` | `NoFlatForm`, `Placement` |
| `format/layout.brp` | `LineContext` |
| `format/printer.brp` | `FormatFault`, `UnbreakableConstruct` |
| `format/source_walk.brp` | `Unreadable` |
| `format/trivia.brp` | `Trivia` |

#### Matched self-compilation measurement

Baseline: `26a3a4fe06a3193ffb082ff75d06bbb29d51c1a6`. Candidate is that revision
plus exactly the 105 header substitutions above. Source snapshot hashes and
the complete candidate patch are retained in the raw evidence. The measured
production diff SHA-256 is
`71e6c184da2d24075ee1d2a9c8f4f76dac50eb6e43b3ce062f3496e19248bdb4`.
Production
`.brp` source remains 74,155 lines; `.brp` tests remain 99,623 lines: 105 production lines
replaced, net zero; zero test edits. Generated compiler C shrinks from
26,259,954 to 26,192,382 bytes (67,572 bytes, 0.2573%).

Host: Apple ARM64, macOS 26.7.1 (25G241) / Darwin 25.6.0, Apple clang 21.0.0
(`clang-2100.3.34.2`). Both builds use the unchanged pinned
`blorp-seed-d62b0aacb2f1`, `-O2`, `-lm -lpthread`, diagnostic flag 0 for
normal instructions and 1 for strict allocation/peak runs. Peak heap is
requested live bytes, excluding allocator/header rounding; it is not RSS.

The ignored `build/fixed-unions-2026-11-13/measure.py` imports the repository's
`blorp/scripts/self-compile-cost` and calls its **unchanged `build_side` and
`measure` functions**. The baseline is an archive of the baseline commit;
the candidate is this checkout, frozen by hashes before measurement. This
allows measurements before making a publication commit. The busy patterns
include the current `NEXT.md` compiler names. Runs are serial; three alternating
normal samples per side and workload use `/usr/bin/time -l`, plus one strict
diagnostic run per side/workload. Both diagnostic sides receive identical
argv and output paths for each workload. Commands actually run:

```sh
mkdir -p build/fixed-unions-2026-11-13/base
git archive 26a3a4fe06a3193ffb082ff75d06bbb29d51c1a6 | tar -x -C build/fixed-unions-2026-11-13/base
python3 build/fixed-unions-2026-11-13/measure.py base
python3 build/fixed-unions-2026-11-13/measure.py measure
```

`build_side` runs the Makefile's `generate-compiler`, `link-compiler` and
`link-test-compiler` recipes with `TEST_COMPILER_FLAGS=-O2`, separate normal
and diagnostic outputs under `blorp/build/compiler-cost/`. `measure` runs
`compile blorp/src/main.brp --library-root blorp/standard_library -o <output>`;
fixed-input runs both binaries in the archived baseline, own-source runs each
in its own source directory. For a committed candidate the equivalent supported
entrypoint is:

```sh
blorp/scripts/self-compile-cost 26a3a4fe06a3193ffb082ff75d06bbb29d51c1a6 <candidate-commit> --rounds 3 --output build/fixed-unions-recheck
```

| Workload / indicator | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Frozen input allocations | 14,062,321 | 13,830,039 | -1.6518% |
| Frozen input instructions, median of 3 | 12,330,523,333 | 12,183,422,300 | -1.1930% |
| Frozen input peak heap, bytes | 164,298,340 | 166,750,364 | +1.4924% |
| Own source allocations | 14,062,321 | 13,824,467 | -1.6914% |
| Own source instructions, median of 3 | 12,323,925,451 | 12,158,089,772 | -1.3456% |
| Own source peak heap, bytes | 164,298,339 | 166,688,242 | +1.4546% |

All four diagnostic runs released every allocation, with zero leaked bytes.
Three samples support this bounded comparison, not a universal speed claim.
Raw retired-instruction samples, in each side's measurement order:

| Workload | Side | Samples |
| --- | --- | --- |
| fixed-input | base | 12,337,435,539, 12,327,390,420, 12,330,523,333 |
| fixed-input | candidate | 12,183,422,300, 12,174,420,694, 12,188,371,339 |
| own-source | base | 12,323,925,451, 12,317,874,730, 12,327,883,545 |
| own-source | candidate | 12,165,826,685, 12,156,258,696, 12,158,089,772 |

Frozen-input emitted C is byte-identical, SHA-256
`5c3e4a6cc0b71d245b6b0b3ee894ad3b7cbc56b92b542bd3e02d6b0fc9a16ad3`.
Own-source candidate C is intentionally different:
`3c078367dfbd34b5b8b345fa5b5b6773ed4fcf04f84c5401c3b5445d24e80616`.
Its changed record layouts are the annotation's intended effect.

Measured compiler binary SHA-256:

| Side | Normal | Diagnostic |
| --- | --- | --- |
| base | `9d3a29fc4171074f2925aecb1a4569d3cb509ee2d11fa97c7c3c0a5224b8c3c7` | `aa8a535155277f76cb1ef64ffb320ffa17ff11e2c718c89d1b3eefaa108b29a5` |
| candidate | `7cf0e0df7f24f15d3665c6ce6a6c8a60db0cfa8748bcbd77d45b5dcc6d1ef4a0` | `a7053ad09a7a0a517bf946d77618a5dcf91590511c3b84711278b440a3e66583` |

#### Peak heap tradeoff and ceilings

Before implementation, the coordinator set +1% ceilings for whole-compilation
allocations, instructions and peak heap on both workloads, with no production
or test line growth. Both peak measurements exceed that initial ceiling; those
failures remain recorded above. Allocations and instructions improve.

Generated-C inspection finds 12 record typedefs changing from counted pointers
to by-value structs: record IDs 12, 117, 180, 181, 192, 249, 375, 380, 414, 457,
478 and 601. Their reference-count headers disappear. Clang's record-layout
dumps show the resulting wider inline payloads in enclosing unions and records;
for example `blorp_u_320` grows from 32 to 104 bytes. Avoiding a separate record
allocation can therefore increase collection element and parent value storage.
For example, the parsed builtin-type declaration becomes a 96-byte value;
its declaration union grows from 32 to 104 bytes, and an enclosing pair grows
from 72 to 216 bytes. Across 53 changed named aggregate sizes, the largest
increase is 144 bytes, with no recursive expansion. This supplies a concrete
size tradeoff consistent with the measured extra 2.4 MB of peak live heap;
it does not attribute every byte of the peak.

The coordinator accepts a routine peak-only correction from +1% to +2% for
this annotation pass. Allocation/instruction ceilings remain +1%, LOC remains
net zero, no existing test limits change, and correctness/leak/fixpoint failures
remain blocking. No compiler mechanism is added to recover this small storage
cost. Independent code review agrees with this scoped correction; the
original +1% peak failures remain recorded.

Static layout commands:

```sh
clang -Xclang -fdump-record-layouts -fsyntax-only build/fixed-unions-2026-11-13/base/blorp/build/compiler-cost/compiler.c
clang -Xclang -fdump-record-layouts -fsyntax-only blorp/build/compiler-cost/compiler.c
```

#### Validation and review

- Formatter: all 29 changed files, no additional byte changes.
- Focused fixed-type checker, union-field specialization and verification:
  44/44 callbacks, 3/3 driver directory checks, zero leaks.
- Full `make -C blorp test`: passed, including formatting, 1,732 component
  callbacks, 24/24 component directory checks and 1,064 native e2e/runtime
  callbacks (2,796 total callbacks); zero leaks. The final 252-callback
  language-surface suite is included in the 1,064, not the whole native gate.
- `scripts/blorp-fixpoint --prove`: passed. A/B/C emit the own-source candidate
  C hash recorded above; all 740/740 A/B fixture outputs are identical. B's
  self-hosted component and native gates also pass: 2,796 callbacks plus
  24 directory checks, with zero leaks.
- `git diff --check`: passed.
- Independent code review: source diff and measurement report approved,
  zero findings.
- Independent test-runner review: approved, all required gates passed.

Raw audit, source/binary provenance, samples, C outputs, static layout dumps
and gate logs live under ignored `build/fixed-unions-2026-11-13/` in the
`explicit-fixed-unions` worktree. This report retains the result and inputs;
raw generated C and logs do not belong in git.
