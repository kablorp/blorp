# Explicit fixed unions in the compiler

105 ordinary union declarations in `blorp/src` now explicitly promise fixed
storage: 54 bare enums and 51 unions with payloads. The only production edits
are the declaration headers, in 29 files. No record, variant, function, test,
standard-library declaration or compiler rule changes.

## Storage and scope

Bare unions already compile to C enums. Nonrecursive payload unions already
store their tag and active payload by value; `fixed` checks that their payloads
are unmanaged, nongeneric and nonrecursive. It also supplies the declared
promise required to inline a record containing a union:
[`inline_record_field`](../../blorp/src/common/codegen/specialize/specialize.brp)
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

## Changed declarations

Paths below are relative to `blorp/src/`.

| Module | Newly fixed unions |
| --- | --- |
| `common/analysis/assemble.brp` | `VisitState` |
| `common/analysis/check/bodies.brp` | `JoinBindingState`, `VoidPosition` |
| `common/analysis/check/declarations.brp` | `PayloadSpan`, `TypeAccess` |
| `common/analysis/check/errors.brp` | `AbsentSupertrait`, `ArithmeticTrait`, `CanonicalFamily`, `CheckerInvariant`, `ComparisonTrait`, `ConstantError`, `ListElementReference`, `QualifierKind`, `RecursionError`, `TypeTermError`, `UnsupportedForm` |
| `common/analysis/check/inference.brp` | `InferencePublication`, `InferenceReadiness`, `InferenceRelation`, `SlotOrigin` |
| `common/analysis/check/instantiation_paths.brp` | `PathOperation` |
| `common/analysis/check/model.brp` | `BindingOrigin`, `EqualityMember`, `ListLengthTest`, `NominalId` |
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

## Matched self-compilation measurement

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

## Peak heap tradeoff and ceilings

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

## Validation and review

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
