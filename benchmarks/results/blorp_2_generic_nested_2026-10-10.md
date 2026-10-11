# Nested generic applications and unmanaged union payloads

The pilot now compiles inferred and written `Box[Box[Int]]`, including a rigid
`double_box[T](value:T)->Box[Box[T]]` declaration, heterogeneous generic union
payloads, and existing inline records carried by generic unions. This is step 5
of `blorp_2/GENERICS_PLAN.md`, starting from `1a8c37390`.

## Boundaries and representation

Parsed applications retain recursive `TypeSyntax` children and their individual
spans. Checking recursively resolves them into the existing nominal, rigid
`TypeRef` tree. Argument inference is unchanged; expected result types do not
infer missing generic parameters.

Specialization publishes `ConcreteUnion.variants: List[Option[TypeRef]]` and
complete declaration-plus-ordered-argument instance keys. Child inline union
layouts are prepared before their parent is appended. No `PayloadShape` or
Int-specific pattern carrier remains. Existing payload annotations remain Int
or their declaration's own parameter; this increment adds no recursive data
syntax or managed layout.

Lowered and owned projections retain their exact selected variant identity and
source value. Lowering uses the specialized binding type. The independent
verifier checks every layout, including unused ones, before trusting unmanaged
ownership: record IDs must exist, union payload IDs must precede their parent,
and actual String payloads are rejected. Projection validation independently
checks selected variant, scrutinee identity, nominal owner and exact result type.

Every payload-bearing union uses one uniform tagged C union with a typed member
per payload variant. Nullary construction initializes only `.tag`. This changes
prior Int-payload C spelling deliberately; no separate scalar storage path was
introduced to preserve old text. Payload-free C identity and whole-corpus cost
comparisons are owned by the coordinator.

## Tests and evidence

The three initial executable-program tests fail on the frozen baseline and pass
with the implementation. Receipts are under ignored
`blorp_2/build/generic-nested/first-red` and `initial-green-retry`.

The new `test_nested_generics.brp` suite has 17 callbacks covering recursive
syntax and inner spans/errors, rigid nested substitution, complete nested keys
and deduplication, concrete variant payloads, lower and ownership projection
facts (including variant position 1), unchanged inference restrictions, existing
nongeneric tail-loop composition, and emitted C dependency/member shape.
`test_nested_payload_verify.brp` has 13 callbacks constructing raw ownership IR
independently: equal-payload sibling variants, equal-shaped other owners, another
same-typed scrutinee, wrong nominal projection/constructor types, nullary
projection, and invalid unused layouts. Diagnostics check full spans and notes.

Removing selected-variant position equality causes exactly the wrong-sibling
callback to fail (1/13). Removing the earlier-layout guard causes exactly the
self, existing-but-forward, and out-of-range callbacks to fail (3/13). Both
mutations were restored byte-for-byte; the restored 30 callbacks pass.
Receipts: `mutation-selected-variant`, `mutation-layout-dependency`, and
`restored-green`. The owning grammar adds an exact malformed inner-bracket case.

The existing real-main e2e runner builds the pilot once at -O0, compiles each
fixture's unmodified emitted C at -O0 with ASan/UBSan, and checks exact exit,
stdout and stderr. `native-e2e` passes all 138 inner cases, including all 110
preexisting native fixtures and 11 new fixtures: inferred/written nesting,
both heterogeneous variants, both record fields, saved versus replaced nested
values, both enum payload values, and depth 20. Source stayed unchanged during
that run. No alternate entrypoint or test controller was added.

New ordinary examples measured 3,108–4,567 allocations and approximately
38–42 million retired instructions; they use the existing generic-example
limits of 20,000 allocations/200 million instructions. Depth 20 measured 28,258
allocations/102,861,874 instructions and has a named 50,000/200 million limit.
All preexisting fixture limits remain unchanged. The coordinator's independent
final gate rechecks the named-limit consolidation made after the first native
run. These owned-input compilation costs are proxies, not self-compilation.

Inspected original generated C is retained under `inspected-c/`: heterogeneous
members have their exact aggregate/scalar types, record layouts precede union
storage, and depth 20 emits 20 separate, dependency-ordered struct declarations
rather than deeply nested C expressions. The default C toolchain limits pass.

Formatted handwritten production growth is **109 lines**, below the
preimplementation investigation stop of 400 production lines. Tests and
executable fixtures grow **1,363 lines**. Independent compiler-expert implementation and review
are separate; the reviewer reports no source findings. The tests and complete
producer-to-consumer path replace the Int-only representation in this slice.

## Matched costs and C identity

The immediate baseline is `1a8c373904d89efa65e3e9cbd06769e28a55b7f0`.
All 110 preexisting valid fixture inputs are frozen byte-for-byte. Baseline and
candidate are compiled by the same FRESH host executable, SHA256
`8d9c5a7b33b2fc4203f90d14b671cfead8ba63b5b3b4f645142015645683ad66`,
using Apple Clang 21 with native pilot executables at `-O0`. Normal executables
supply hardware instruction counts; separate diagnostic executables supply
allocations and strict zero-leak checks. Three serial matched pairs reverse
compiler order in the second pair. No other agent runs compiled work during
measurement. Allocation counts are deterministic; instruction totals sum the
three-sample median for each fixture.

| Whole unchanged corpus | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 335,800 | 339,838 | +1.203% |
| Retired instructions | 3,831,804,230 | 3,844,491,998 | +0.331% |

The largest individual increase is `match/many_arms.brp`: allocations +4.133%,
instructions +5.184%. These pass the preset 10% aggregate and 15% individual
ceilings. All existing e2e limits remain unchanged and pass. This increment
supports additional values; it makes no compilation-speed improvement claim.

All 1,320 measured C outputs are stable within each compiler across pairs and
diagnostic modes. Across baseline/candidate, all 81 payload-free outputs remain
byte-identical. The other 29 change only with the intentional payload storage
representation: typed variant members, corresponding construction/projection,
and tag-only nullary initialization. Raw diffs are retained in `c-diffs/`, with
the complete classification in `c-diffs/status.tsv`. Existing native outcomes
and exact emission assertions validate those changed programs; emitted C was
not normalized or rewritten for comparison.

The original `da8fa4c71` source was also rebuilt with this same host and compared
against the immediate baseline and candidate on the six original, unchanged
inputs. Three serial pairs retain median and minimum instruction statistics.
The largest cumulative increase is `match/constructor_spine.brp`:
7,628 to 8,947 allocations (+17.292%) and 42,070,361 to 44,133,395 median
instructions (+4.904%). No workload reaches the original 25% investigation
threshold. The original baseline was not advanced between steps.

These measurements cover input-to-C compilation, not pilot self-compilation or
target runtime performance. All 660 immediate diagnostic compilations and 54
cumulative diagnostic compilations report balanced allocations/releases and
zero leaks. Host-emitted C for baseline and candidate native compiler builds
has the same warning categories and counts: 36 per build (3 const qualifier,
26 equality parentheses, 7 pointer/integer comparison). Those host warnings
remain retained; fixture C is compiled with the existing strict warning gates.

## Independent final validation and inherited host failure

| Gate | Result |
| --- | --- |
| Full `make -C blorp_2 test` | 815 unit, 87 grammar, 9 runtime, 138 e2e callbacks pass, plus wrappers; 71.318s |
| Strict full unit suite | 810 pass, 5 fail on per-test leaks; 5.669s |
| Strict new phase/verifier suites | 30/30 pass, no per-test leaks or sanitizer errors; 2.414s |

The independent full gate rechecks the consolidated ordinary/depth fixture
limits. All 121 native budget rows pass. Strict commands use
`--suite --sanitize --leak-check --timeout 180`. The strict whole-suite failure
is retained as a failure; a process-final zero-leak summary does not override
the five per-test reports.

The failing callbacks in the unchanged `test_tail_recursion_check.brp` are
ordinary arity, type, purity, parameter-shadow and name-error precedence tests.
They leak respectively 3, 5, 2, 3 and 1 objects. Both current source and an exact
archived `1a8c37390` baseline reproduce all five with identical counts. Every
callback directly matches `Check.check_errors(failure).first.kind`; nearby
tests with a named intermediate value pass.

The unchanged failing suite is directly reproducible with the recorded host:

```sh
bin/blorp test --suite --sanitize --leak-check --timeout 180 \
  blorp_2/test/unit/test_tail_recursion_check.brp
```

A minimal independent host TestSuite reduces the problem to:

```blorp
import:
    test: TestSuite

fixed union Kind:
    Known(String)
    Other
fixed record Error { kind: Kind }
fixed record Errors { first: Error, remaining: List[Error] }
pure func make() -> Errors:
    { first = { kind = Known("value") }, remaining = [] }
pure func test_temporary_projection() -> Bool:
    match make().first.kind:
        Known(_): True
        Other: False
pure func test_named_projection() -> Bool:
    error = make().first
    match error.kind:
        Known(_): True
        Other: False

tests: TestSuite = {
    description = "Temporary nested projection",
    tests = [
        ("temporary projection", test_temporary_projection),
        ("named projection control", test_named_projection),
    ]
}
```

The direct projection leaks one `Kind`; the control that binds
`error = make().first` and matches `error.kind` passes. The complete TestSuite,
generated C, after-Perceus Core and diagnostic notes are retained under
`host-temporary-leak/`. In generated `driver.c`, lines 48060 and 48066 both
retain the same Kind, while line 48078 releases it once. The redundant outer
`Dup` already exists after host Perceus insertion; C emission faithfully
projects that incorrect ownership plan. Source inspection points to
`blorp/src/compiler/stage_09_core/perceus/results_and_loops.brp:988` and
`:1911`: binding normalization classifies the immediate projection owner before
insertion. Recursive projection materialization at `:1621` and `:3946` later
acquires ownership without invalidating the earlier alias-retain decision.
This source mapping is a high-confidence diagnosis; no host repair was
implemented or validated in this increment.

This is an unresolved host-compiler ownership bug, not evidence of target
managed-union support. The bounded follow-up should fix temporary-root nested
projection ownership in the host Perceus pass and add direct TestSuite and Core
regressions. Do not reshape the five pilot tests to hide it or broaden this
increment into a backend rewrite. The affected new strict suites, target native
sanitizers and independent compiler review pass; unrestricted host leak safety
and the strict whole-unit gate are not claimed.

## Evidence entrypoint

All local artifacts are under ignored `blorp_2/build/generic-nested/`:

- `baseline/`, `candidate/`, `corpus/` and `host.sha256` freeze sources, native
  binaries, inputs and toolchain identity; `build.sha256` files identify C and
  executables. `preexisting-host.diff` preserves the four excluded host drafts.
- `baseline-build`, `candidate-build`, `matched-measurements`,
  `cumulative-measurements`, `final-independent`, `strict-unit`,
  `strict-new-phase`, `strict-tail-reproduction` and `strict-tail-baseline`
  are repository-owned recorder packets. All have stable source fingerprints;
  the three strict tail/full failing receipts correctly exit 1.
- `summary.json` and `cumulative/summary.json` retain individual raw samples and
  comparisons. `samples/` and `cumulative/samples/` retain C and process streams.
- `final-source.sha256`, `final-tests.sha256` and `final-docs.sha256` identify
  the frozen integration inputs. Source/test hashes still match after every
  gate; `completion-docs.sha256` identifies the evidence/progress documentation
  closed after validation.

The four preexisting host draft files were neither edited nor included in this
increment. No host rebuild, workaround, additional production tracing or test
framework was introduced. Managed String payloads and their destruction/borrow
contracts are the next separately validated generics increment.
