# Ranked tensor getter ABI facts, 2026-10-07

> Publication note: this packet is a path-only projection of the privately archived original evidence. Original measurement, review, seal and copy hashes below remain historical original-byte authority; they do not hash the projected metadata or controllers. Numeric results, timestamps, source/compiler/C hashes and unchanged payload bytes are preserved. The [publication contract](compiler_reader_cuts_publication_2026-10-07/README.md) and its `PUBLICATION_MANIFEST.json` identify current public byte hashes. Historical controllers are evidence, not directly runnable configurations.


**Accepted within the tested scope.** Independent source and resource reviews
have zero findings. Correctness, sanitizer, codegen and hygiene gates pass;
matched stage2 self/small measurements pass both unchanged 0.5% ceilings with
identical generated C. This retires two suffix readers after the
[dictionary getter cut](compiler_dictionary_getter_admission_2026-10-07.md).

## Boundary and scope

The emitter now admits its twelve existing ranked checked-get symbols through
one private `RankedTensorReadAbi` union. Closed ranks and ABI variants distinguish
plain erased reads from shaped erased, Float64 and Float32 reads. Validation
derives argument convention, rank and representation once; the immutable checked
parts retain representation alongside tensor, indices and static dimensions.
The direct-width renderer matches that representation instead of parsing `_f64`
or `_f32`. Two obsolete allowlist rows are removed.

There is one checked-parts constructor. Arity, static dimensions, argument
evaluation, cleanup, emitted strings and rejection/fallback behavior remain
unchanged. `CoreUnboxKind` still determines explicit scalar unboxing, including
Float16; projected struct C type still determines struct unboxing. There is no
unshaped floating ABI variant, new Core/runtime schema or expanded inlining.
Existing malformed-Core receiver/result coherence is not newly validated.

Standalone prepared Builtin controls exercise both emitter entry paths. Normal
production calls project to DirectRuntimeCall; scalar calls retain their runtime
path. Production struct-unbox emission consumes the validated parts. These paths
are qualified separately in the [source review](compiler_ranked_tensor_getter_abi_2026-10-07/resource/APPLIED_FINAL_REVIEW.md).

The preparation was reviewed and qualified independently before the renderer cut:
372 emitter tests, 36 tensor tests, oracle execution and whole-C identity passed.
Seven new output controls also passed on the unchanged baseline before any
production edit. Initial control development had two syntax stops and three
incorrect output expectations; actual original bytes and diagnostic evidence
are retained. Those were tests-only corrections, not compiler bug fixes.

## Correctness

| Boundary | Result |
| --- | --- |
| FRESH O2 build; selected owning suites, Core sanitizer and one-worker codegen audit | 2,913 passed, 0 failed |
| Serial broad compiler gate | 6,782 passed, 0 failed |
| Contextual tensor specialization | 36 passed, 0 failed |
| Runtime checked get/set and multi-index | 14 and 5 passed, 0 failed |
| Ranked production oracle | Exit 0; whole C byte-identical |
| Actual strict spelling enforcement | 502 allowlisted, 0 new, 0 stale |
| Identity census and repository hygiene | PASS; 3,446 census rows |

Counts overlap. The selected aggregate includes the preserved dictionary cut's
sanitizer selection; successful child logs are removed by compiler-check.
All 14 final validation packets report unchanged source. The allowed generated
build-input delta was empty. Source remained frozen throughout native gates and
measurements; documentation and evidence were integrated afterward.

The source oracle covers ranks 3/4/5 and Float, Float32, Float16, Int, String and
fixed-record payloads, negative wrapping and scalar out-of-bounds zero. Baseline,
preparation and final C are identical: 39,058 bytes, SHA256
`6d6faf6b39697b83663601ccb585c959b67728f2395436886dc4a1f2c0bd8ac7`.
[Final correctness report](compiler_ranked_tensor_getter_abi_2026-10-07/correctness/final-correctness/TEST_RUNNER_REPORT.md),
[hygiene supplement](compiler_ranked_tensor_getter_abi_2026-10-07/correctness/hygiene-supplement/TEST_RUNNER_REPORT.md)
and [commands](compiler_ranked_tensor_getter_abi_2026-10-07/correctness/final-correctness/commands.json)
retain exact invocations and limitations.

## Matched enabling cost

Baseline authority is exact `2ee201fb5cb74e8a7b4f3d068a143d8d71dd2bad` plus the
accepted dictionary production, using its sealed actual stage2 pair. Candidate
stage1 is FRESH O2 `4ec66620466ba1b0328bdbc5a79f86a9e2a2a092a6c4e4eb21ccc5e15661e547`.
Both stage2 pairs match Apple clang 21, aarch64, CLI/runtime O2, split 8 and
`self-2ee201fb5cb7`, with normal/diagnostic modes 0/1. Frozen self input and local
small input match. Incidental outside-repository raw stage/revision/freshness
fields remain unmodified; construction owns actual stage2 authority.

| Workload | Baseline allocations | Candidate allocations | Baseline minimum instructions | Candidate minimum instructions | Instruction delta | Whole C |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Self | 245,078,157 | 245,078,157 | 228,752,978,176 | 228,938,404,430 | +0.081059602% | Identical |
| Small | 1,689,099 | 1,689,099 | 1,596,391,077 | 1,597,176,349 | +0.049190453% | Identical |

Three normal samples per side/workload, paired diagnostic allocations and exact
integer ceilings `candidate * 200 <= baseline * 201` determine acceptance.
Background activity and spreads are retained. Flat total allocations do not
prove this helper allocation-free; there is no quiet-window, latency or speed
claim. Broader registry, formatter/carrier, identity-authority and stage
rearchitecture work remains open.

The independently reviewed controller pins construction artifacts immediately
against builder hashes, then protects raw JSON/C and re-reads all four records
before recomputing acceptance. [Final proof](compiler_ranked_tensor_getter_abi_2026-10-07/resource/comparison/COMPARISON_COMPLETE.json)
SHA256 `df45e885a18a5703863576b431c9ad769dd681e24365b5c7b3c95bc3a1082dba`,
[resource report](compiler_ranked_tensor_getter_abi_2026-10-07/resource/RESOURCE_REPORT.md)
and [independent review](compiler_ranked_tensor_getter_abi_2026-10-07/review/RESOURCE_REVIEW.md)
retain raw authority and qualification. All owned native jobs exited and released
their shared slot.

## Delivery authority

Final emitter SHA256:
`24b9bf114c3db06ba8277bccff6e1559d147ad112adc99a33df6991984bebc31`.
[Wave-only patch](compiler_ranked_tensor_getter_abi_2026-10-07/delivery/ranked-wave-only.patch)
SHA256 `8dc8cd009ff712ecece3c6b1ac8809d7b1e6a08634bfea25189384fbf3f9593c`
contains only emitter, owning tests and two post-dictionary row removals. The
reviewed three-path HEAD snapshot `04767397e49bbe354dc5137e31f93e72c38a539f79078d43e4d9eff857dfda57`
also contains the dictionary's earlier allowlist deletion; that is distinguished
from the two new deletions. Architecture drafts and dictionary code/tests remain
intact.

[Copy manifest](compiler_ranked_tensor_getter_abi_2026-10-07/COPY_MANIFEST.json)
maps original paths and hashes to retained exact bytes. Larger payloads use
lossless gzip, verified by decompression against the original SHA256; relative
links in raw reports retain uncompressed targets. Large generated C, executables,
objects, archives and successful AST dumps stay in owned scratch with hashes and
omission reasons recorded. Raw leaf whitespace attributes preserve log/patch bytes
without weakening production-source checks.
