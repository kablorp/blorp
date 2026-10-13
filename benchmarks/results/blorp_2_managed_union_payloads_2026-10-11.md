# Finite inline unions with managed String payloads

Date: 2026-10-11. The generics step-6 path passes strict phase and full pilot
tests, real-main native fixtures, eight deliberate fault checks, matched costs
and host fixpoint. Independent compiler and test-runner reviews accept this
bounded increment. Separate host Core failures remain explicit below.

## Problem and reproduction

The immediate step-5 pilot baseline supports finite unmanaged nested union
payloads but rejects `Box[String]`. The first regression uses this real program:

```blorp
fixed union Box[T]:
    Box(T)
pure func box[T](value: T) -> Box[T]:
    Box(value)
pure func unbox[T](value: Box[T]) -> T:
    match value:
        Box(payload): payload
func main() -> Int:
    unbox(box(42.to_string())).length()
```

The retained first-red packet is
`blorp_2/build/managed-union/first-red/`. It fails 1/1 with
`specialized union payload must be unmanaged`, help
`use Int, an inline record, or an unmanaged union; String payloads are not supported`,
span 183..186 and payload-declaration note 25..26. Source stayed unchanged.
No tracked control continues to require that obsolete rejection.

The expected native result is exit 2 with empty stdout and stderr. A second
program saves `unbox(current)`, replaces `current` with a box containing
`7.to_string()`, and returns the saved String's length: exit 2. Its companion
reads the replacement and must exit 1. Existing immutable `ValueId` identities
must survive the mutable source binding's reassignment.

The owning design and source anchors are in
[GENERICS_HANDOFF.md](https://github.com/kablorp/blorp/blob/4b05ea3b431d9fbe4e906a0802bd41060b6f397f/blorp_2/GENERICS_HANDOFF.md) and
[MEMORY_PLAN.md](../../blorp_2/MEMORY_PLAN.md). This extends their existing
root/child distinction and borrowed synchronous call ABI.

## One layout authority and explicit child obligations

Tagged union storage stays inline. `Box[String]` has no separately allocated or
reference-counted Box root. Its aggregate obligation owns the active child's
obligation. Dup/drop helpers visit only the selected variant; String retains
its existing leaf ARC runtime.

Specialization publishes the complete payload inventory and one bottom-up
summary. Current frozen code, `candidate/src/specialize.brp:54`:

```blorp
fixed union UnionRepresentation:
    InlineUnmanaged
    InlineOwningPayload
fixed record ConcreteUnion {
    variants: List[Option[TypeRef]],
    representation: UnionRepresentation
}
```

Earlier child layouts precede parents. `ValueOwnership` is an O(1) view:
`NoOwnership`, `ManagedStringLeaf`, or `InlineOwnedFields(UnionInstanceId)`.
There is no duplicate managed flag or parallel stored-child inventory.
Every value of an owning layout has an aggregate obligation, including nullary
or unmanaged active variants; their helper cases perform no child work.

Lowering already supplies exact `PayloadValue(VariantInstanceId, ValueId)`
facts. Ownership now records the transfer and immediate borrow edge explicitly.
Current frozen code, `candidate/src/own.brp:59,76,82`:

```blorp
fixed union BorrowSource:
    ParameterBorrow(ValueId)
    OwnerBorrow(OwnerId)
    PayloadBorrow(ValueId)
fixed union ResultOwnership:
    UnmanagedResult
    BorrowedResult(BorrowSource)
    OwnedResult(OwnerId)
fixed union StoredPayload:
    UnmanagedPayload(ValueId)
    OwnedPayload(ValueId, OwnerId)
-- OwnedValueOperation member:
ConstructDefinition(VariantInstanceId, StoredPayload)
```

A borrowed child is acquired before construction, then that exact owner is
consumed into the new aggregate. A final-use owned child transfers its existing
owner; the inserter filters exactly that consumed owner from the current local
drop bucket. A later-use child acquires a separate obligation and retains its
original scheduled drop. Previously published rows are not patched. Calls keep
their existing borrowed parameter/owned result contract.

`PayloadBorrow` names the immutable immediate parent only. Accepted parent
`ResultOwnership` supplies ancestry, without copied source trees. Returning an
extracted managed child acquires an independent owner before return, so it
survives the caller's replacement/drop of the original box.

The independent verifier recomputes every catalog row and every variant,
including unused layouts, once before using accepted summaries. It validates
operation, nominal type, selected variant, exact source, result provenance and
active obligation before publishing per-value facts. Forward/self borrow edges,
missing or repeated child transfers, inactive owners, leaked owners and double
drops reject. An unrelated acquisition does not reactivate the original owner.

The existing source owned-prefix guard remains, including already-dropped owned
values; prefix acquire/drop operations also remain guarded. Verified borrowed
prefixes can compose within supported tail-match shapes. The raw verifier can
follow an owned parent while its exact original obligation is active, but the
current source control shape does not admit owned-parent projection lifetimes.
Transitive borrow-use scheduling and general joins are separate work.

Emission consumes `VerifiedProgram` mechanically. A disposable function-local
owner-type projection selects typed aliases and String or aggregate dup/drop;
it is not a second published ownership analysis. Child-first layouts emit
`blorp_union_dup_`/`blorp_union_drop_` helpers immediately. Only owning layouts
get helpers; unmanaged output keeps its existing spelling. Finite nested owning
unions compose through earlier helpers without an arbitrary depth restriction.
Recursive declarations, managed records, heap aggregate roots, COW and
contextual generic inference remain excluded. No cache, new IR layer,
measurement controller, helper driver or hidden emitter RC was added.

## Focused tests and recorded evidence

The authoritative focused packet is
`blorp_2/build/managed-union/phase-82-green/`. It reports exit 0, 82/82 passed,
2,873 ms, no timeout and `source_changed_during_run=false`.

| Suite | Callbacks | Main independent oracles |
| --- | ---: | --- |
| `test_managed_union_specialize.brp` | 4 | Complete String/nested/unused summaries; phantom argument remains unmanaged |
| `test_managed_union_lower.brp` | 6 | Exact source, selected variant, concrete type and global IDs across rebinding/arms |
| `test_managed_union_own.brp` | 15 | Final/later use transfer, immediate parent borrow, uniform nullary/Int obligations, unused constructor drop bucket and existing guards |
| `test_managed_union_verify.brp` | 44 | Raw malformed IR, independent catalog validation, transfer/lifetime/provenance rejection and dynamic boundary supplement |
| `test_managed_union_emit.brp` | 13 | Independently expected C bodies, active-only helpers, typed aliases, nested dependency order and per-function/global-arm identities |

The verifier and emitter suites were authored by separate compiler experts.
They supplement their raw typed cases with dynamic real-fixture stage-lifetime
checks. Exact failure assertions retain diagnostics, help and spans where
applicable. The emitter cases check complete small C bodies, including nullary
`VariantDefinition`, unmanaged active variants and absence of inactive payload
work.

Repeat the focused receipt from the checkout with a FRESH intended host:

```sh
scripts/compiler-build-status
bin/blorp test --suite --sanitize --leak-check --timeout 180 \
  blorp_2/test/unit/test_managed_union_specialize.brp \
  blorp_2/test/unit/test_managed_union_lower.brp \
  blorp_2/test/unit/test_managed_union_own.brp \
  blorp_2/test/unit/test_managed_union_verify.brp \
  blorp_2/test/unit/test_managed_union_emit.brp
```

The recorded host SHA-256 is
`4dd4a29a428d7fa8ecd40068f043d8a7ee910df0c6272ba3062c97dfebf938ec`.
The final process summary of 3 allocations/3 releases is suite cleanup, not
total compilation cost or target String allocation evidence.

Twelve ordinary source fixtures run their unmodified real `main` through the
existing e2e runner; no alternate native entrypoint or fixture adapter exists:

| Fixture | Expected exit | Purpose |
| --- | ---: | --- |
| `basic` | 2 | Construct and extract a mortal String |
| `saved` / `current` | 2 / 1 | Saved extraction versus replaced binding |
| `shared` / `shared_box` | 2 / 2 | Independent String/aggregate obligations survive replacement |
| `unused` | 0 | Unused aggregate destruction |
| `nested` / `nested_saved` | 2 / 2 | Finite composition and surviving extracted child |
| `both_variants` | 1 | Both String-bearing branches execute |
| `unmanaged_variant` / `nullary_variant` | 7 / 7 | Owning layout's inactive String slot is untouched |
| `deep` | 2 | Twenty nested layouts and extractions |

These live in `blorp_2/test/e2e/fixtures/generic/managed/`. All twelve pass in
the final native run, with exact exit status and empty stdout/stderr. The
depth-20 fixture uses 33,187 allocations/122,924,917 compilation instructions
against its 50,000/200,000,000 ceilings. Generated C compiles at `-O0` with
warnings-as-errors, ASan/UBSan and the toolchain's default structural limits.
Existing direct String runtime tests supply mortal-root destruction checks.
Compiler per-test leak counters do not measure target aggregate destruction.

An initial development 82-case run passed 68 and failed 14: thirteen dynamic
fixtures had accidentally received host-formatter separators unsupported by the
then-current pilot grammar, and one nested literal-pattern oracle did not match
its observed expected rows. Compact fixtures were restored; the last-use test
uses existing exact `List[Option[Int]]` equality with the same independently
derived rows `[Some(1), Some(3), Some(4), None]`. The old pattern and observations
are retained as a suspected host limitation, without claiming a proven cause.
The restored authoritative 82-case run passes, as do the later full gates.
Separately authorized source-trivia syntax work is outside the frozen
managed-only cost snapshot.

The first combined gate exposed five stale contract expectations, all migrated
with independent review: two String-specific borrow diagnostics generalized to
managed parameters, one newly valid borrowed prefix, and two formerly rejected
String payload programs. The latter now assert exact nominal layouts, signatures,
call targets and source spans. A separate teaching regression pins an owned
`Box(borrowedString)` prefix at span 198..201. Its message is `owned managed
values before a tail match are not supported yet`, with help to create managed
values in the selected arm or a separate straight-line function. Only two
production diagnostic literals changed; the guard bytes are unchanged. The
first red passes 4/5; restored strict diagnostic/ownership suites pass 96/96.
Packets are `contract-migration/` and `owned-prefix-diagnostic/`.

## Source growth and cost stop conditions

The immediate step-5 sources and managed-only candidate sources are frozen at
`blorp_2/build/managed-union/{baseline,candidate}/src/`, with source manifests.
This excludes later trivia changes. Exact formatted physical line counts:

| Production file | Step 5 | Managed candidate | Net |
| --- | ---: | ---: | ---: |
| `specialize.brp` | 1,480 | 1,499 | +19 |
| `own.brp` | 940 | 1,015 | +75 |
| `verify.brp` | 1,377 | 1,539 | +162 |
| `emit.brp` | 775 | 996 | +221 |
| **Total** | **4,572** | **5,049** | **+477** |

The original 400-line investigation threshold stopped broad expansion at +511.
Independent review removed duplicate published emission value types, a second
helper loop and an isomorphic private source carrier, reaching a reviewed +474
milestone. The exact final census is +477. Review found the remaining typed
transfer, independent checks and active-child emission necessary; the coordinator
explicitly reassessed the ceiling to **at most +500**, conditional on semantic,
strict-leak, mutation and matched-cost gates. This does not change cost limits.

New test/support files and twelve fixtures contain **4,086 exact physical lines**.
The net step-6 test estimate is **+4,452**. Its attribution limit is explicit:
the initial cumulative test delta from `1a8c37390` was +5,650, less the retained
step-5 report's +1,363, giving +4,287. Subsequent bounded contract and diagnostic
migrations add an independently counted 102 and 63 lines respectively. A
complete frozen step-5 test tree was unavailable; the total/existing attribution
uses that retained census, unlike the exact production snapshot comparison and
exact new-file count. The separate frontend trivia migration belongs to trivia.
Incidental old recursion-test formatter churn was removed by matching the
retained step-5 checksum and reapplying six intended carrier/message changes.

Unchanged acceptance ceilings: at most **10% aggregate** and **15% individual**
growth in both allocations and retired instructions on the unchanged corpus.
Existing fixture caps must not increase. Ordinary new fixtures use
20,000 allocations/200 million instructions; depth 20 uses 50,000/200 million.
No compilation-speed improvement is claimed. These owned-input costs are
compilation proxies, not pilot self-compilation or target runtime measurements.

## Matched costs and provenance

Final snapshots and fresh samples are under
`blorp_2/build/managed-union/final-cost/`. The baseline reuses the original
step-5 binaries after verifying all 16 source contents, artifacts, host and
flags; the final candidate was rebuilt with the same repaired FRESH host,
SHA-256
`4dd4a29a428d7fa8ecd40068f043d8a7ee910df0c6272ba3062c97dfebf938ec`.
Their only source differences are `specialize.brp`, `own.brp`, `verify.brp` and
`emit.brp`; the other twelve files match byte-for-byte. Separately authorized
trivia changes are excluded. Each variant's normal and diagnostic native
executables were built at `-O0` from that variant's single generated compiler C
body, with `BLORP_MEMORY_DIAGNOSTICS=0` and `=1` respectively.

The corpus freezes all 121 preexisting valid inputs, excluding new managed
fixtures. Three quiet serial matched pairs reverse variant order in pair 2.
`BLORP_THREADS=1` is explicit. Diagnostic runs supply deterministic allocations
and strict compiler-process leak checks; normal runs supply retired instructions
through `/usr/bin/time -l`. Instruction totals sum each fixture's three-sample
median rather than taking a median of whole-corpus sums.

| Whole unchanged corpus | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 406,252 | 408,462 | +0.543997% |
| Retired instructions, sum of fixture medians | 4,262,327,540 | 4,280,167,931 | +0.418560% |

The largest allocation increase is `match/constructor_spine.brp`, +2.6154%.
The largest instruction increase is `match/many_arms.brp`, +1.7476%.
All aggregate and individual comparisons pass the unchanged 10%/15% ceilings.
This is a bounded cost increase for added functionality, with no speed-improvement
claim. All twelve new managed-fixture budgets pass the separate native gate.

All 726 diagnostic compilations balance allocations/releases and report zero
leaked objects/bytes. Streams are empty apart from the expected diagnostic
summary. Normal/diagnostic C matches for every sample, and each compiler's C is
stable across all three pairs. All 121 cross-variant outputs are byte-identical;
`c-diffs/status.tsv` has 121 `identical` rows. These checks cover 1,452 generated
program C files. They do not measure target runtime allocation or destruction.

Raw final evidence is under `blorp_2/build/managed-union/final-cost/`: `summary.json`,
`summary.txt`, `samples/`, `corpus/fixtures.tsv`, `c-diffs/status.tsv`, and both
variants' source/host/artifact manifests and build logs. Retained SHA-256 values:

| Artifact | Baseline | Candidate |
| --- | --- | --- |
| Normal pilot | `fdfe49372a9ee4c34b484ff975f3bac7f94b6769afee4b358b161a5729358316` | `6b0af9753c454d3d1e04f392479be9d07983ff944b5b9332d9e89d02faaed0a2` |
| Diagnostic pilot | `3abec6a563edf777c8a261e50f217cbac0e2bdee0d404b0cf2d684dcf2175e64` | `6ac9d47a2197b9410842c4b6c6948a051f1e6ed2cc4f514686d692e112358884` |
| Generated compiler C | `b56c25e63c2c4126dbce46ad206d28f160250fcfe67cc1b1d8a82cd6b1b41e78` | `3795fcf06065a645a5cffb6a0b7388b11a1c35ecd1f0b4c8b76da6651a09c532` |
| Source inventory | `277bf89838d0e36e97a12fe6680a8a32c762efa130ca82358638c9019253b436` | `e7d394dc47a8b5a6d7b20931d8412b53560297ea4500d49b06ad7960c27593bc` |

`summary.json` SHA-256 is
`e3d437c3c5764749e0db00e56250bdbbc60f03e7a675f86ba45571c417f5d124`;
the frozen corpus manifest SHA-256 is
`97d748207e390070e5efad87d61af29001133e6617794d02601604d1885b9f3e`.
The existing `measure.zsh` and `summarize.rb` entrypoints retain exact measurement
and aggregation rules; no new controller was introduced. Original costs remain
intact as a prior milestone. Final `own.brp` is SHA-256
`95efc5def5be13ddd3bd74e0698a2e0716da748e5eb87bc42428fa910922ea1c`;
the final candidate differs from that milestone only in the two diagnostic
literals described above. All source/artifact manifests were rechecked afterward.

## Host blockers repaired; separate host failures retained

**HOST1: repaired temporary nested projection ownership.** The host previously
retained `match make().first.kind` twice and released it once, causing five old
pilot per-test leak failures. The separate
[projection repair report](compiler_nested_temporary_projection_2026-10-11.md)
records strict 815/815 frozen pilot tests, mortal runtime/Core regressions,
matched costs and fixpoint. This pilot feature did not reshape those old tests.

**HOST2: repaired singleton consuming-call branch balancing.** The canonical
pilot `Ok(match ... Some: concat(output,name); None: output)` exposed a missing
drop on the append arm after the caller transferred its input. The separate
[branch repair report](compiler_singleton_call_branch_ownership_2026-10-11.md)
records the mortal-String reproduction, resolved consuming-contract guard,
runtime/Core regressions and mutation. Valid pilot source remained canonical.
The repaired FRESH host above produces the strict 82/82 receipt and both final
matched pilot build pairs described above. An earlier baseline built with HOST1
alone is excluded from the final cost comparison.

**Remaining unrelated strict Core aggregate lifetime failure.** The public
`insert_drops_expr` regression's corrected Boolean oracle passes, but strict
checking retains a transitive Core aggregate. Controlled old-target/new-target
comparison records 58/65 leaked objects respectively; this establishes an
inherited lifetime failure, not its root cause. Two unchanged full-Core
assertions also remain red. No third host repair or release workaround is part
of this pilot slice.

**Remaining cancellation timeout.** A broad Core sanitizer run passed 364
callbacks then its native batch exceeded the existing 180-second limit. Samples
enter `cancellation_plan.analyze_current_behavior_expr`. Depth-4096 protection
list reconstruction is a bounded complexity hypothesis; isolated baseline
attribution is not established. This is separate from HOST1/HOST2 and from the
earlier compilation-stack failure. Neither limits nor excluded drafts were
changed to obtain acceptance. Both remaining issues are detailed in the host
reports; unrestricted host Core/sanitizer acceptance is not claimed here.

## Final validation and acceptance

The final strict packet `independent-combined-strict-3` passes 913 unit,
10 runtime (9 native assertions/1 wrapper) and 98 grammar callbacks: 1,021/1,021
in 7.816 seconds. `independent-combined-e2e-2` passes 151 cases plus its wrapper
in 74.296 seconds, including 134 native fixtures/budgets. Artifact timeout is
explicitly zero. All sources stay unchanged within each recorder packet.

Eight deliberate faults trigger their intended assertions: producer child
transfer/drop (2/2 failures), raw verifier transfer/parent/summary (1/1/3), and
emitter active-drop/inactive-slot/owner-type (11/2/3). Exact byte restoration
passes every owning suite under strict ASan/UBSan/leak checking. The initial
ambiguous target attempt changed no bytes and produced a green; it receives no
red credit. `mutations/RESULTS.md` retains precise faults and all 16 meaningful
red/restored packets. Independent review accepts every fault and restoration.

Host standard leak checks pass 1,267/1,267; the codegen audit passes 241/241.
These workload results coexist with the separate Core limitations above.
The standard host fixpoint emits byte-identical C in stages 1, 2 and 3, SHA-256
`283ed8a9940dfc2d2af2f8fc795432db661d46984548989795a156e5cd81001e`.
Full provenance and commands are in `independent-final-validation.md` and the
linked host report. Later report-only edits do not change any of the 237
source/test inputs bound by the final receipts; they do change the whole-tree
fingerprint, so no receipt is claimed to cover those prose edits.

| Required final evidence | Status |
| --- | --- |
| Full pilot unit/runtime/grammar gates, strict where required | **PASS**, 1,021/1,021 |
| Equivalent ordinary e2e command, all real-main fixtures under native ASan/UBSan | **PASS**, 151 cases/134 native fixtures |
| Deliberate missing-transfer, wrong-projection/summary, active-drop and inactive-payload mutations; exact restoration | **PASS**, all eight pairs |
| Same repaired-host baseline/candidate normal and diagnostic builds; three serial matched pairs | **PASS**, frozen managed-only snapshots |
| Corpus aggregate/individual allocation and instruction results against unchanged 10%/15% caps | **PASS**, all 121 unchanged fixtures |
| New ordinary/depth fixture budgets and unchanged existing caps | **PASS**, all 134 fixtures |
| Unchanged-corpus generated C identity | **PASS**, all 121 byte-identical |
| New owning-layout generated C and default-toolchain depth review | **PASS**, exact C oracles/native depth 20 |
| Standard host compiler fixpoint | **PASS**, all three stages identical |
| Independent final compiler review and test-runner audit | **PASS**, zero outstanding findings in this increment |
| Final acceptance and generics completion update | **PASS**, supported managed subset marked complete |

The final costs reuse the existing `measure.zsh` and `summarize.rb` entrypoints
and frozen corpus. No measurement controller, commit or push is included.
