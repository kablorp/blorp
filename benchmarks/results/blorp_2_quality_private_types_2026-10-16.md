# Private types in public declarations

The checker rejects a private type in public function parameters/returns,
record fields and union payloads, including nested type arguments. The rule
is enforced once during unqualified annotation-head resolution. Namespace
lookup publishes `NamedType { head, origin }`; mandatory `TypeScope.access`
states whether a public declaration is being checked. Qualified heads retain
the provider's existing public-offer check; recursive arguments retain access.
Private declarations and body-only uses stay valid. Names remain IDs until
diagnostic rendering.

The coordinator and independent compiler-expert reviewer approve the source
and tests. A separate test-runner reproduced the mutation, behavior and cost
evidence. No cache, extra lookup, callback or duplicate privacy check is added.
Three compiler-source declarations become public: InferenceVariableId,
InferenceParameterConstraint and RecordOrigin. These are bootstrap consistency
changes, not a claim that the pilot checks its whole source today.

## Provenance and physical cost

Integrated source base: naming feature
`3640e81fa623dc81030b55c231376199adf479c3`, production-identical to published
main `741835cf43c858b23c544ecc5bd4b5a1cbbfe737`. The exact 17-file rule patch is
`5f12e8c4f717431944e67f055b117059ac9c13387cb78859820f6a91e27e6c80`.
Only namespace insertion context changed from the earlier reviewed prototype;
the naming authority and all eight new-file bytes are preserved.

| Artifact | SHA256 |
| --- | --- |
| FRESH frozen normal host | `899e0a92cfe1bc91f992bd3ccdd0755448903eb91d91780ac4870bd13d8cfa17` |
| Diagnostic host sibling | `86ba69ffea8200080157edb25cbc49825654a14d2c09a6161dec447ab0e648be` |
| Preserved naming baseline pilot | `6a90da1df36ef30d5d043188116cf06bdabf731b7c7cf1a72db748277e03eb56` |
| Baseline C | `1090d73cfd350dd31425d18f69074ffb58a4c6a364a77ace9ed58ba8ef96382b` |
| Private candidate pilot | `ba622531f88df9ce67f0272ff3eedbe999a736e264e9779a3dbbab3968d10ea9` |
| Candidate C | `34911054fd4df47a04dd608b4adaf7e6f124492becd881bd6fe92138674e576e` |

The host stays frozen, CLI `-O0`/runtime `-O2`, split8, bootstrap
`dev-0e1598ed616e`, Apple Clang 21 on macOS arm64. The candidate is generated
once and linked `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1`, with `-lm -lpthread`.
Normal instruction runs unset both diagnostic variables with env **outside**
`/usr/bin/time -l`; allocations/leaks come from separate strict runs. Inputs,
libraries and physical output paths match across each pair.

Physical deltas, excluding this report and shared docs: production +66/-19 =
**+47** (ceiling +66); test code +386/-3 = **+383**; six fixtures **+29**.
There are two production TypeScope constructors, both with mandatory access;
two parameter-list updates preserve it. The earlier +45 count is historical.

Actual generated C allocates NamedType and PublicTypeUse. Successful head
lookup also receives an eagerly constructed UnknownType/NonApplicableType
argument, whereas the baseline constructed that error only on failure.
`resolve_head` returns `blorp_StackResult`, so there is no heap Result to count.
These are source/C-site observations, not a dynamic allocation-stack breakdown.

## Granular tests and behavior

The original TDD run failed ten forbidden-annotation callbacks while the six
priority controls and four positives passed. Integrated owning suites pass
**75/75**, both initially and after mutations: 20 private-type, three
declaration, 14 signature, 35 namespace and three render callbacks. Typed errors
carry both NameIds; tests assert exact messages, help, source spans and no note.
Private heads reject before arity; public/unknown precedence stays unchanged.

Three independent mutations fail their intended callbacks: bypass privacy
(10/20 failures), lose nested access (5/20), and replace published origin with
Implicit (3/35). All original source hashes are restored before the green run.

All six new ordinary fixture commands reject with exact diagnostics, empty
stdout and no C, in normal and strict modes. Five were accepted by the naming
baseline; the sixth intentionally changes bad-arity precedence. The final
445-input strict matrix gives baseline 354 accepted/91 rejected and candidate
349/96. All 349 shared successes emit byte-identical C. Every strict report is
positive, balanced and leak-free, including the repeat used to confirm cost.

The separate cumulative original-431 matrix compares pre-naming `81abd521`
with the final private candidate: 331 shared successes emit identical C; its
18 new rejections are exactly the previously accepted naming migrations.
There is no additional privacy-policy change on that original archive. Its
one both-rejected diagnostic change is the already accepted duplicate-capture
message. Those changes are not attributed again to this rule.

## Measured costs and explicit decision

| Metric | Baseline | Candidate | Change | Accepted ceiling |
| --- | ---: | ---: | ---: | ---: |
| Shared-349 strict allocations | 4,609,098 | 4,669,137 | +1.302619% | +1.5%, conditional rescope |
| Sum of per-input min3 normal instructions | 14,491,712,481 | 14,520,098,265 | +0.195876% | +0.5% |
| Canonical host-build checkpoint allocations | 22,730,378 | 22,768,244 | +0.166588% | +1% |
| Canonical host-build min3 normal instructions | 41,871,019,152 | 41,970,968,109 | +0.238707% | +1% |

The original corpus allocation ceiling was **+0.5%**. Two complete strict
series reproduce the +60,039 allocation increase exactly, exceeding the
original allowance of 23,045. The run stopped before normal/host measurements.
Both failed receipts remain. The coordinator and independent compiler-expert
test-runner agreed to a narrow **+1.5% corpus allocation** rescope, published
before continuation as `2d51a14756e83d66b14abe1505d1628158df073e`. No other
ceiling changed and no fixture budget changed. The direct typed design is
preferred to extra machinery for this modest measured cost.

The four individual preflight allocation/instruction deltas respectively are:
return-zero +1.879243%/+0.176040%; projection +0.376916%/+0.114300%; access
+0.314246%/+0.045036%; chain-64 +0.785507%/+0.040029%. All meet their limits:
the earlier reviewed return-zero allocation rescope is +2%, others +1%.
All four emit identical C with zero leaks. Historical pre-naming samples remain
labelled separately; they do not establish this integrated acceptance.

The normal corpus has 2,094 samples, three alternating pairs per input. The
table uses each input's independent minimum; the separate minimum of complete
corpus totals is 14,498,736,780 to 14,529,060,735 (+0.209149%). These are
different aggregates and are not conflated. Every normal C output also matches
its strict output.

The canonical host proxy uses immutable Git baseline source, never the dirty
integration checkout, and frozen candidate snapshots at the same physical
source/output paths. Three alternating normal pairs and one diagnostic run per
variant give within-variant identical C. Allocations use the single
`artifact_construction_complete` checkpoint. This is a **host-build proxy**,
not pilot self-compilation.

The credible representation follow-up is measured unmanaged representation for
finite scalar TypeAccess/TypeTermError after ordinary opaque erasure. NamedType
also needs a separately reviewed extension admitting finite unmanaged union
fields in inline fixed records, with layout, ownership, generated-C and cost
tests. This is unproven future work; M8 does not automatically remove the cost.
The current host is unchanged.

## Destination validation and retained evidence

The destination's literal `make -C blorp_2 test` passed in 255.84 seconds:
2,799 component checks (2,633 host callbacks and 166 native runtime cases),
445 e2e checks, 351 native C links and 522 fixture executions, with no failures.
All 351 strict cost reports were positive, balanced and leak-free; all existing
allocation and instruction caps passed. The destination host remained FRESH
(`390bdd0d`), and all 4,622 tracked input hashes, staged blobs and HEAD stayed
unchanged throughout validation. The destination O0 pilot is `aa49fa7e`; its
generated C is exactly the isolated reviewed `34911054` C. The independent
receipt is `blorp_2/build/private-landing/REPORT.md` in the main checkout.

The actual destination `scripts/blorp2-fixpoint --frontier` also passed in
20.11 seconds, measuring 33/35 source modules parsed. The remaining stops are
the Char literal at lex offset 7438 and reserved `pure` at specialize offset
11650. The host emitted the same `34911054` C to build the separate O2 stage A
(`10296617`); the O0 artifact and previous naming/fixpoint evidence remain preserved.
This is a measured frontier, not self-compilation or fixpoint proof.

Owning suites, mutations, exact new rejections, complete strict/normal corpus
and host proxies are recorded above. Raw commands,
manifests, stdout/stderr, C, samples and the original failures remain in the
private integration worktree under ignored `build/quality-private-integrated/`:
`gates/REPORT.md` and `final/REPORT.md` are the independent receipts. No latency
claim, fixpoint proof or old-compiler release gate is implied.

The earlier isolated frontier command stopped at setup with exit 2: `bin/blorp` was absent.
The existing script and Makefile have no external-host selector; no host copy,
symlink or rebuild was introduced. The actual destination invocation above
resolves that setup limitation using its normal repository host.
