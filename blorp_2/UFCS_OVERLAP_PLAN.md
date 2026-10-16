# UFCS workload and ground-equality delta

The source design and prospective workload/cap adjustment have coordinator and independent compiler-expert agreement. Publication requires a separate documentation/test review. No compiler, production edit or benchmark ran to prepare this plan. The separate +9 accepted-type equality preparation still needs its own acceptance gates. The [negative attribution report](../benchmarks/results/blorp_2_ufcs_attribution_2026-10-16.md) preserves the rejected prototype and its costs.

The authoritative design is [TYPE_EQUALITY_PLAN.md](TYPE_EQUALITY_PLAN.md) on accepted main. It replaces only same_type's leaf fallback with direct constructor/identity comparisons, keeping all composite/rigid branches. It is +9 including the removed import. Only after its independent validation may types_overlap add the +3 ground case:

```blorp
-- No flexible declaration variables: use the solver's accepted-type equality.
if left_parameters.is_empty() and right_parameters.is_empty():
    Ok(same_type(left, right))
else if disjoint_heads(left, right):
    Ok(False)
else:
    -- Existing solver path unchanged.
```

This is the existing solver's accepted-type case, not another matcher. inference_type(value, [], start) yields AcceptedType; inference_head retains it; inference_action delegates to same_type. There are no flexible slot/binding/occurs/error paths in this case. Rigid parameters compare owner kind/identity/position. Bare/applied forms remain distinct, argument ordering/length and nested List/application equality remain unchanged. Nonempty lists, including phantom generic declarations, use the existing solver unchanged. Accepted type identity belongs to model/signature acceptance; inference's slots remain query-local and no new fact survives the query.

## Freeze before implementation or measurement

Before implementing the ground increment, freeze a fresh accepted-main baseline B, its library, complete source, normal/diagnostic host provenance, emitted C and normal-O0 diagnostic-enabled pilot. The accepted stack must include question/pattern/private rules and the independently accepted equality preparation. The dirty fb257 UFCS prototype and its old costs are historical diagnostics, not B. If integration has not yet accepted preparation, first compare its candidate independently with its own accepted-main baseline; do not mix stages to hide a regression.

Record baseline outcome/stdout/full diagnostic/C and strict allocation count for every discovered fixture and all three pinned stress trees. Run baseline zero and32x1 before ground implementation; if B itself exceeds either absolute allocation ceiling, STOP for an explicit revised decision. Do not trim providers/functions, rewrite inputs, scale the ceiling, or substitute another library to fit it. This draft does not establish that either baseline fits.

Pin the borrowed-plus-preparation candidate U separately, then compare U with U+ground. Record actual source/binary/C/library/host/toolchain manifests for each. Preparation and the isolated ground increment each require no allocation growth per unchanged accepted fixture or stress input, <=+0.5% normal instructions, <=+1% canonical host allocation/instruction proxy, and exact outcomes/C/strict zero leaks. Preparation stays <=+20 production lines. The cumulative UFCS estimate is +28 borrowed +9 preparation +3 ground =+40; the original hard whole-change +102 ceiling remains. Report actual production/test deltas separately against declared bases.

## Pinned prospective stress inputs

The reviewed scratch evidence retains unchanged copies of all three source trees. This document also defines their complete bytes below, so resuming does not depend on scratch files. Each tree hash is SHA256 of sorted UTF-8 lines `file_sha256  relative/path\n`, with relative paths inside that tree. The default library is a separate frozen input. Reconstructing a tree is setup outside measurement; verify the complete tree hash before using it.

| Workload | Providers | Functions/provider | Files | Tree SHA256 |
| --- | ---: | ---: | ---: | --- |
|32x1|32|1|33|faa261d4eb22ee35ee44a44ee56b5ec3e0bb719254a66e6914a526075acce566|
|32x16|32|16|33|52a7c6170dbe0a03cc66f79ebbc5ae253140bca9894a9403414eed5ff35248bf|
|128x8|128|8|129|e7a4d7f945020071a5ef0b3a791ac5d4cfe24b98e7e7be3654e115fe2b2b00a6|

The following ordinary shell setup reproduces every source byte. Run from the
repository root into a fresh ignored directory; it does not modify e2e fixtures.
It is a workload recipe, not a new test runner or production generator.

```bash
ufcs_workload_root=blorp_2/build/ufcs-pinned-inputs
mkdir -p "$ufcs_workload_root"
for ufcs_case in 32x1 32x16 128x8
do
    case "$ufcs_case" in
        32x1) ufcs_providers=32; ufcs_functions=1 ;;
        32x16) ufcs_providers=32; ufcs_functions=16 ;;
        128x8) ufcs_providers=128; ufcs_functions=8 ;;
    esac
    ufcs_tree="$ufcs_workload_root/$ufcs_case"
    mkdir "$ufcs_tree"
    printf 'import:\n' > "$ufcs_tree/main.brp"
    ufcs_provider=1
    while [ "$ufcs_provider" -le "$ufcs_providers" ]
    do
        printf '    ./ops_%s: Item_%s\n' "$ufcs_provider" "$ufcs_provider" >> "$ufcs_tree/main.brp"
        {
            printf 'fixed record Item_%s { value: Int }\n' "$ufcs_provider"
            printf 'pure func describe(item: Item_%s) -> Int:\n    item.value\n' "$ufcs_provider"
            ufcs_function=2
            while [ "$ufcs_function" -le "$ufcs_functions" ]
            do
                printf 'pure func op_%s_%s(item: Item_%s) -> Int:\n    item.value\n' "$ufcs_provider" "$ufcs_function" "$ufcs_provider"
                ufcs_function=$((ufcs_function + 1))
            done
        } > "$ufcs_tree/ops_$ufcs_provider.brp"
        ufcs_provider=$((ufcs_provider + 1))
    done
    printf 'func main() -> Int:\n    0\n' >> "$ufcs_tree/main.brp"
    (
        cd "$ufcs_tree" || exit 1
        printf '%s\n' *.brp | LC_ALL=C sort | while IFS= read -r ufcs_file
        do
            shasum -a 256 "$ufcs_file"
        done
    ) > "$ufcs_workload_root/$ufcs_case.sha256"
    shasum -a 256 "$ufcs_workload_root/$ufcs_case.sha256"
done
```

These three prospective trees contain 195 files: 192 provider files plus three
mains. The older 185-entry historical manifest has a different scope: 33 files
for 32x16, 129 for 128x8, and 23 other reproduction/reference files. It excludes
the prospective 33-file 32x1 tree. Its retained SHA is
`5c59b4fd7f6f41cf813e45fb89d6864a1f5878c13131282598de4955f6a503f1`;
it remains historical evidence, not an input needed to reconstruct this plan.

Both32-provider main files have the SAME SHA2b1b4d11417160e58212cc9ae7eade9bd372afe635453bfb9e05d87bd72976d4. The128 main SHA is f4cf20218e24914ab9ad510702e6186d0da609ca721428b70651d1e950a034a1. A main-only hash cannot identify these workloads; complete provider manifests are mandatory. Default library bytes are an additional separately frozen input, not part of the tree hashes above.

Each provider has one distinct nominal Item_i receiver for shared name describe, plus K-1 globally unique op_i_j functions. These are one shared-name group, not K groups. Main imports all Item_i and returns zero. Unused provider functions are checked and omitted from emitted target C; identical C is a limited oracle, so existing focused overlap/routing tests and normal-entrypoint native fixtures remain mandatory.

## Numerical full-UFCS acceptance against B

The original prospective zero limit was
`min(8513, floor(B_zero_allocations *1.01))`. On the frozen current boundary,
B uses8,229 allocations, U uses8,474, and the ground candidate uses8,460:
the latter is+231/+2.8071% and **149 over the original8,311 ceiling**.
Both candidates emit identical zero C with balanced counts and no leaks.
The ground owning/model suites pass72/72; broader ground costs remain unrun.
These negative receipts stay valid under their original rule.

Root and two compiler experts agree to remove **only zero's
relative limb**, retaining the already specified absolute8,513 ceiling.
This follows the user's allowance for minor documented inefficiency; it is an
explicit post-observation exception, not a claim that the old limit passed.
The new validation pass checks receiver declarations in the loaded library
even when main never calls a receiver function. Its transient name counts,
introduction groups and inherited-ID proofs serve that new correctness rule.
For this pinned library they impose a small validation floor; it is not a
general constant cost. Exact attribution of the231 allocations is unknown.
IntMap already uses hashed lookup, and namespace entries share its stored
values list. Do not describe this as a linear-map or list-rebuilding problem.

Credible deferred work is measuring the physical cost of map/Option/group
updates and consuming selected routes once instead of repeating import/method
suffix scans. Replacing the map with a Dict alone would not remove routing
scans or pair enumeration. No index, cache or counter-directed special case is
authorized. All other limits below remain unchanged; normal instructions,
stress, aggregate corpus costs or the host proxy can still reject this design.
Use fresh matched B ratios, never historical allocation numbers.

| Workload/metric | Ceiling |
| --- | --- |
|Zero strict allocations|8513 absolute; explicitly revised zero-only exception above|
|Zero normal retired instructions|B_zero_min3 *1.005|
|Shared accepted corpus aggregate allocations|B_corpus_allocations *1.01|
|Shared accepted corpus sum of per-input normal min3 instructions|B_corpus_instructions *1.005|
|Prospective32x1 strict allocations|31000 absolute|
|Prospective32x1 normal min3 instructions|B_32x1 *1.01|
|32x16 and128x8, each strict allocations and normal min3 instructions|Corresponding B count *1.01|
|Canonical host proxy allocations and normal min3 instructions|Corresponding B count *1.01|
|Whole UFCS physical production delta|<=+102|

Use integer comparisons rather than rounded displayed percentages. Preserve the unidentified historical29993 sample as unidentified, its31000 ceiling, the historical32x16 TSV149837, and the current attribution baseline144643. The retained measure_inputs.sh selects32x16/128x8, not32x1; no recovered receipt links29993 to the prospective32x1 bytes/toolchain. Passing the prospective gate will not reproduce that historical sample. Preserve the original zero and stress breaches and the correction that the first timing series was strict-instrumented. This is a scoped workload-resolution decision, not a blanket cost waiver.

## Tests, measurements and stop rule

Before modifying production, add/confirm ordinary producer-based tests for both-empty equal/distinct nominal types, Lists/nested applications, rigid owner kind/identity/position and bare/applied boundaries. Preserve all flexible/repeated/phantom/occurs controls and canonical conflict ordering. Kill guard-and-to-or, erased nominal/rigid identity, conflated bare/applied, and ignored argument length/order mutations. Functional tests should already pass on the equivalent solver; removing the shortcut requires a real cost oracle, not an invented semantic red test.

Run only with an explicit exclusive compiled slot. Use existing ordinary CLI/library/fixture entrypoints, unmodified emitted C, strict allocation/leak runs separate from normal instruction samples. Put `env -u BLORP_LEAK_CHECK -u BLORP_MEMORY_STATS` OUTSIDE `/usr/bin/time -l`; take at least3 serial alternating pairs. Keep all argv, raw output/time/exits/C and before/after fingerprints. Compare the SAME final legal fixture/library bytes and same physical output path. Enumerate intentional UFCS rejections separately; do not turn them into a silent smaller unchanged corpus. Host proxies use the SAME canonical source/result paths and existing diagnostic artifact_construction_complete checkpoint, with copying outside timing.

Source/C predict removing992/16256 RecordHead materializations in the32x16/128x8 describe groups after both stages. Verify this; it is not already a measured saving. Group maps, repeated routing scans, dedup scans and pair enumeration remain. No general speedup or cost closure is promised.

STOP and hand back on a repeatable cap breach, baseline absolute-cap breach, source/binary/input drift, missing positive counters, leak, C/outcome mismatch, changed error ordering, host fault or need for a new matcher/cache/selector/framework. Retain negative receipts; do not continue wider gates without root direction. Independent source/test review, full destination Makefile gate and dynamic frontier are still required before publication.

### One bounded diagnostic collection after the ground preflight

The later normal zero preflight fails the unchanged+0.5% instruction limit:
three alternating pairs give minima33,772,012 for B and34,680,542 for ground
(+2.690186%). The32x1 strict count is23,801, balanced with zero leaks and
unchanged C, within31,000. No broader acceptance follows.

Root and two compiler experts agree to one collection-only exception to the
cost stop rule. Freeze the existing B/ground binaries, complete source/library,
discovered fixture corpus, three pinned stress trees and canonical host-proxy
commands before execution. Use the existing ordinary serial CLI recipes for
strict counts and at least three alternating normal pairs per declared input.
Measure that finite inventory once; keep the existing limits and record every
numerical breach rather than stopping at its first cost ratio. Report aggregate
and worst-input results and a cap-by-cap failure table. Previously observed
failures remain failures, not replacement baselines or passed gates.

Abort immediately on provenance drift, setup/I/O/host failure, invalid/missing
counters, timeout/resource-limit errors, leaks or unexpected behavior,
diagnostic or C changes. Enumerate intentional language changes separately;
never silently omit workloads from the unchanged corpus. No adaptive rerun,
source optimization, new framework, disabled limit or further cap exception is
authorized by this collection. Its purpose is a complete accept/defer/rescope
decision, not acceptance despite red evidence. Publication still requires an
explicit reviewed cost decision and the ordinary correctness/destination gates.

### Complete collection and correctness-feature cost decision

The finite collection completed all 4,524 compiler calls without an outcome,
full-diagnostic, C-identity, counter, leak or provenance failure. It measured
all 445 fixtures (349 accepted/96 rejected) and the three declared stress trees.
The original limits still fail in eight places: corpus allocations +1.644796%
and instructions +2.019801%; zero instructions +2.490860%; 32x1/32x16/128x8
instructions +4.568961%/+2.409657%/+4.853801%; canonical host allocations
+2.028825% and instructions +1.883797%. These results do not pass the old gates.
The isolated ground increment passes every declared G/U limit.

Root and two independent compiler experts accept this explicit rescope: the
new mandatory declaration-validation pass may cost **at most +5% allocations
and normal instructions**, uniformly against B, for the declared unchanged inputs and
host boundary. Check allocations separately for all 448 strict inputs, including
rejections; check instructions for the declared 352 accepted/stress inputs,
the accepted-corpus aggregates (instructions sum independent per-input minima),
and the canonical host source-to-C proxy. Rejection instructions remain unmeasured and excluded.
Retain zero's absolute 8,513, 32x1's absolute 31,000 and the +102 production-line
limits in addition to this relative bound. All G/U limits stay unchanged.
This is a post-observation correctness-feature allowance, not a refactor
speedup, an automatic baseline replacement or a general waiver for later work.

On the retained data, the worst allocation increase is +3.069360% on a rejected
input; the worst accepted allocation/instruction increases are +2.807828% and
+2.706098%. The 128x8 stress's +4.853801% instruction increase has little margin;
these observations establish no wider-scale bound. No adaptive remeasurement
or source optimization is authorized by the decision.

The additional work is explicit in `check/receiver_clashes.brp`: declaration
name counts, introduction groups, selected-route scans, inherited membership
proofs and unordered receiver-pair validation before bodies. One inference
solver and borrowed namespace facts replace the old matching path. IntMap is
already hashed and namespace entry lists are shared; substituting another map
alone would not remove the scans or pair enumeration. Exact dynamic attribution
of the 231-allocation zero increase is unknown. Current route selection rescans
method suffixes; canonical candidate collection repeats edge scans and linear
FunctionId deduplication; inherited membership is rescanned for each pair.
A credible separate follow-up is to measure carrier/COW costs and have the
existing visibility/signature producer expose canonical unique introductions
once, with explicit inherited-proof provenance and preserved conflict order.
Change only the measured owning boundary; another map alone is insufficient.
No speculative index, cache, second matcher or counter-directed shortcut
belongs in this change.

Full correctness, mutation, destination Make/frontier and independent source
reviews remain required before implementation publication. The raw collection
and its original eight failures remain in the `quality-ufcs-integrated` worktree's ignored
`blorp_2/build/ufcs-integrated/fresh-base-c4ec/complete-cost-preparation/`.
