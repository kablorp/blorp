# Managed-record allocation census (2026-10-04)

The current compiler self-compile executed **124,062,535 managed-record maker allocations**, 45.89% of 270,348,690 global managed allocations. `Cursor` alone accounts for 39,522,818. This supports a bounded source-coordinate reconstruction-loop pilot before considering a general record scalar-replacement pass or inliner. It does not prove an optimization benefit or close S5.

This is disposable generated-C instrumentation, not a new compiler/runtime feature. Production sources were unchanged for the census. The independent reviewer accepted the method and exact oracles before the full ranking was interpreted.

## Workload and provenance

Frozen source revision: `06f4a18da9aae41f767d6dd56865c67693500080`; Git tree: `932793d70dd5727b81888ced3c5f7bff86c98159`. The source checkout was clean for generation and both serial measurement runs. The measured command compiles that checkout's `blorp/src/main.brp` through C emission only. Native compilation and linking of the diagnostic compiler were setup, outside the measured run.

The generator's displayed version still names historical `681105c14bff-dirty`, bootstrap `dev-8228a8fa12e3`, and `self-681105c14bff`. Those strings are not asserted as the workload revision. Current build-input freshness, the clean frozen06 source/tree, and a fresh same-invocation Core/C emission establish the actual input. The fresh body byte-matches the retained stage-2 body. Both linked compilers report diagnostics mode 1, CLI/runtime O2, Apple clang 21.0.0.

| Artifact | SHA-256 |
| --- | --- |
| Generator `bin/blorp` | `65e10960f8363d685f642a3d3af7071b21de69b1ebb9846a97c6180ae0d9be4e` |
| Fresh normal/retained stage-2 body C | `537b4aa4553bbac9c20b6d6fd8410d3ace2262c8b4345aa1bfab082bda3fa66d` |
| Normal diagnostic stage-2 executable | `876a150d0af28b75c62107e810ca2aed51f3153c454356b69367c58d94a3d0bb` |
| Instrumented executable | `d740463d1e8e60241c38002d347cbda40fc971bfd7a93863cffd4e81018ac562` |
| Linked diagnostic runtime object | `3442491ce67875efe3f8850d9fd98aa32526f7bd0858352d0f0412750aff1220` |
| Instrumenter | `39c58b8c48911dc01fe7ca67ff7aa13c3301b9d4846d98b73985eedaeef7f028` |
| Both measured emitted target C files | `537b4aa4553bbac9c20b6d6fd8410d3ace2262c8b4345aa1bfab082bda3fa66d` |

[build.commands.json](record_allocation_census_2026-10-04/build.commands.json) retains the exact repository-extracted native compile/link argument arrays and runtime-object path. [invocations.json](record_allocation_census_2026-10-04/invocations.json) binds the emission/measurement argv, explicit environment overrides, cwd and resolved input/std paths, returned exits, and source checks. It is **retrospectively reconstructed from session tool calls**, not invented contemporaneous runner metadata. The shell inherited its ambient environment; no variables were explicitly cleared and that complete inherited environment was not captured. The explicit stats override and verified linked mode are recorded without claiming other diagnostic variables were absent. [packet.hashes.json](record_allocation_census_2026-10-04/packet.hashes.json) additionally binds the large, scratch-only Core/C artifacts. No 514 MB Core dump, 72 MB C body, object, or executable needs to be checked into the repository.

This census used the **workspace06 input**, not the benchmark harness's archived/frozen-input directory. The reviewer's separate archived-input baseline totals 271,597,490 allocations versus this workspace census's 270,348,690. That path/input-generation difference is not a matched control; neither its difference nor the 39.5 million Cursor count predicts an exact pilot allocation saving. The pilot must use its own matched baseline/candidate workload.

## Event and identity

The wrapper counts only after a delegated `blorp_alloc(requested_size)` succeeds. It records two relaxed-atomic cumulative counters in fixed arrays: executed calls and requested bytes. The delegated allocator call is inserted after the rewrite and excluded from instrumentation, preventing double-counting. The census introduces no per-object metadata, event log, lock, leak tracking, or `reset_mem_stats`; its invocation explicitly requested only stats. The unrecorded ambient-environment caveat above remains separate.

The catalog is the **final Core schema from the same emission invocation** as the instrumented compiler body, not a previous fusion dump or a dump of another frozen input. All 1,939 `heap_record` declarations join one-to-one to the current emitter's exact maker shape and installed semantic type tag. Unmatched, duplicate, or ambiguous Core names/makers fail closed. Monomorphic instantiations retain their complete semantic names. Classification is an explicit flag derived from that join, never a C-name prefix or tag-text heuristic.

The site ID means an artifact-local **maker implementation allocation site**, retaining its C type, offset/line, and Core source location. It is not the authored constructor-call/literal site. Several source sites calling one maker share a counter. Unique reuse/COW bypasses allocation and contributes zero; a shared fallback that calls the maker contributes one. Type installation itself contributes zero.

The lexical rewrite covers 4,156 direct allocator call expressions in the compiler body. An exact inversion audit reconstructs the unmodified input body after undoing those call-expression replacements; only the separately identified preamble and counter/report tail are additional support. Comments, strings, allocator prototypes and address references are not calls. Tag literals use the accepted JSON-compatible C string subset; unsupported C escapes are rejected rather than guessed.

## Counts and coverage

| Process-destructor endpoint | Count |
| --- | ---: |
| Global managed allocations | 270,348,690 |
| Instrumented body direct allocator calls | 172,716,658 |
| Validated managed-record maker allocations | 124,062,535 |
| External-runtime/other residual | 97,632,032 |
| Executed record makers / validated catalog | 1,160 / 1,939 |

The residual includes **all allocator calls inside the separately linked runtime object**, as well as native header-initialization paths; these are not instrumented by rewriting the compiler body. It is not merely an “untagged record” bucket, nor a record classification. Body call sites outside validated makers are explicitly `other_or_unclassified`.

Counts start at process birth and are read by the scratch destructor after the compiler command, including startup, CLI argument processing, artifact publication and shutdown wrappers. The global `backend_emission_complete` checkpoint is 270,348,611, 79 below the process endpoint. `artifact_construction_complete` is 270,348,685, five below it. Type counters were not snapshotted at those checkpoints: there is no exact type-specific phase attribution or subtraction. The 45.89% global fraction describes this endpoint coverage, not a backend-only interval.

Bytes are cumulative **requested object bytes**, including the requested managed header/padding. They are not allocator usable/backing bytes, retained memory, RSS, or a projected saving. Instrumentation adds atomic overhead and changes allocator return-address attribution. No instrumented timing/instruction or leak-site-stack comparison is used as optimization evidence.

## Largest executed record makers

Labels below abbreviate the exact semantic names retained in the complete mapping/count files. Generic `CoreMapState` rows are distinct concrete instantiations.

| Type | Allocations | Requested bytes |
| --- | ---: | ---: |
| source `Cursor` | 39,522,818 | 1,580,912,720 |
| perceus/uses `OwnershipUseSummary` | 5,294,584 | 211,783,360 |
| perceus/uses `PerceusOwnershipSummaryFrame` | 5,187,944 | 249,021,312 |
| mono_data `CoreMonoDataTypeListRewrite` | 3,572,949 | 114,334,368 |
| perceus/borrowed `BorrowedChildMode` | 3,403,946 | 81,694,704 |
| mono_data `CoreMonoDataTypeRewrite` | 3,382,655 | 108,244,960 |
| traverse `CoreMapState[Int, CoreExpr]` | 3,318,267 | 106,184,544 |
| resolve `CoreGlobalValueResolveContext` | 3,105,730 | 99,383,360 |
| ownership `OwnershipCallContract` | 2,974,328 | 95,178,496 |
| perceus/results_and_loops `PerceusInsertedExpr` | 2,314,207 | 92,568,280 |
| closure `ConvertedExpr` | 2,248,236 | 71,943,552 |
| compiler_new/discovery `Token` | 2,092,309 | 83,692,360 |
| traverse `CoreMapState[StringFusionState, CoreExpr]` | 2,036,072 | 65,154,304 |
| compiler_new/discovery `NodeSchema` | 1,737,306 | 41,695,344 |
| cancellation_plan `CancellationOwnershipFacts` | 1,515,949 | 72,765,552 |

[ranking.json](record_allocation_census_2026-10-04/ranking.json) also retains the complete top 15 by requested bytes. `CancellationPlanAnalysis` (1,515,949; 109,148,328 bytes) and `CoreFunction` (636,425; 71,279,600 bytes) enter that ranking; the table above is ordered by allocation count.

## Screened small result wrappers

| Exact source type | Allocations | Requested bytes |
| --- | ---: | ---: |
| `TupleBinderMint` | 493 | 15,776 |
| `CoreSsaFreshVar` | 265 | 8,480 |
| `CoreParallelFreshVar` | 0 | 0 |
| `CanonicalModuleTypeNameSplit` | 345,014 | 11,040,448 |
| `KeepsBoxAnswer` | 274 | 8,768 |
| `LocalFactsAnswer` | 574 | 18,368 |
| `PlacedChild` | 2,776 | 88,832 |
| `PlacedSubtree` | 2,776 | 111,040 |
| `MemoizedTypeShapeCheck` | 20,148 | 644,736 |

The parallel fresh-var maker is present in the validated catalog but unexecuted in this workload; it is not a failed selector or missing scan. Tuple/SSA mint wrappers have tiny dynamic reach compared with `Cursor` and are parked for this optimization decision.

## Exact validation

`oracle.brp` uses the current emitter for scalar and managed-field records. Normal/instrumented stdout matches at loop bounds four and five. Fresh maker counts match N per type, unique updates count one root, and shared updates count two roots; the exit-status record is separately classified. Global/direct totals reconcile at 20/20 and 23/23. A separate C mechanics fixture invokes the actual emitted makers/reuse helpers from four joined pthreads: fresh40, shared80, unique1; two additional type installations per fresh object add zero. It supplements, not replaces, the emitted-language oracle.

Six retained lexical/join tests pass: validated current emission/inversion; duplicate same-tag declarations with distinct source modules or generic metadata; unmatched maker tag; duplicate maker; comments/strings/prototypes/address-reference noncalls; unsupported C-tag escapes. The independent reviewer verified the full 1,939-maker/4,156-site mapping and accepted the diagnostic ranking. Final scripts, mappings and oracle artifacts are hash-bound.

## Reproduction and durable evidence

The [compact packet](record_allocation_census_2026-10-04/) is retained alongside this report (about 1.1 MB, below the 2 MB ceiling). It keeps scripts, the small language/C oracle sources, exact oracle logs, raw complete self-census/checkpoints, full mapping compressed losslessly, rankings, invocation provenance and manifests. `compiler.mapping.json.gz` has a deterministic gzip timestamp and its decompressed SHA matches the original mapping. [MANIFEST.json](record_allocation_census_2026-10-04/MANIFEST.json) binds every retained file; `packet.hashes.json` identifies large scratch-only inputs/results. The reproducible scripts preserve their as-run scratch/repository path constants; adjust those constants to a clean checkout of the recorded revision when replaying elsewhere. The raw version outputs are retained losslessly as [compiler.version.gz](record_allocation_census_2026-10-04/compiler.version.gz) and [normal.version.gz](record_allocation_census_2026-10-04/normal.version.gz), using deterministic gzip instead of trimming their original trailing blank lines. The manifest binds compressed copies and preserves their original 244-byte uncompressed SHA-256; `packet.hashes.json` continues to identify the original raw outputs.

Diagnostic artifact schema (not a product API): [complete-site-counts.jsonl](record_allocation_census_2026-10-04/complete-site-counts.jsonl) has exactly 4,156 rows with `schema=1`, integer `site`, `classification`, nullable exact semantic `record`, integer `count`, and integer `requested_bytes`. It includes zero-count sites from the validated mapping. Raw `S5_SITE` lines print nonzero sites only; the JSONL conversion matches each exact site/type against the mapping, rather than splitting arbitrary tag text or inferring zeros for missing declarations.

Generate paired Core/C in one invocation, then instrument:

```sh
bin/blorp compile --std-dir standard_library/src --no-format --no-embed-runtime \
  --dump-core-after=final --dump-core-file=/tmp/blorp-record-s5.hzyXge/compiler.final.core \
  -o /tmp/blorp-record-s5.hzyXge/compiler.normal.c blorp/src/main.brp
python3 /tmp/blorp-record-s5.hzyXge/instrument.py \
  /tmp/blorp-record-s5.hzyXge/compiler.normal.c \
  /tmp/blorp-record-s5.hzyXge/compiler.final.core \
  /tmp/blorp-record-s5.hzyXge/compiler.instrumented.c \
  /tmp/blorp-record-s5.hzyXge/compiler.mapping.json
python3 /tmp/blorp-record-s5.hzyXge/build_census.py
```

`build_census.py` reuses `benchmarks/build_stage2_compiler`'s compile/link recipe extraction without regenerating the body. Runtime/native compilation belongs to this setup. Run the resulting instrumented compiler and matching normal diagnostic stage-2 control serially:

```sh
env BLORP_MEMORY_STATS=1 /tmp/blorp-record-s5.hzyXge/compiler.instrumented compile \
  --std-dir standard_library/src --no-format --no-embed-runtime \
  -o /tmp/blorp-record-s5.hzyXge/target.instrumented.c blorp/src/main.brp \
  > /tmp/blorp-record-s5.hzyXge/self.instrumented.stdout \
  2> /tmp/blorp-record-s5.hzyXge/self.instrumented.census
env BLORP_MEMORY_STATS=1 bin/blorp-stage2-diagnostic compile \
  --std-dir standard_library/src --no-format --no-embed-runtime \
  -o /tmp/blorp-record-s5.hzyXge/target.normal.c blorp/src/main.brp \
  > /tmp/blorp-record-s5.hzyXge/self.normal.stdout \
  2> /tmp/blorp-record-s5.hzyXge/self.normal.census
cmp /tmp/blorp-record-s5.hzyXge/target.instrumented.c /tmp/blorp-record-s5.hzyXge/target.normal.c
```

Then run `report.py`. Counter modes must remain diagnostics1 plus `BLORP_MEMORY_STATS=1`, without leak tracking or resets. On another input/revision, regenerate both Core and body together and rerun the oracles; stale or unmatched catalog joins are invalid.

The retained tiny sources also regenerate the intentionally omitted tiny C/Core inputs:

```sh
bin/blorp compile --no-format --check-invariants --dump-core-after=final \
  --dump-core-file=/tmp/blorp-record-s5.hzyXge/oracle.core \
  -o /tmp/blorp-record-s5.hzyXge/oracle.normal.c /tmp/blorp-record-s5.hzyXge/oracle.brp
python3 /tmp/blorp-record-s5.hzyXge/instrument.py \
  /tmp/blorp-record-s5.hzyXge/oracle.normal.c /tmp/blorp-record-s5.hzyXge/oracle.core \
  /tmp/blorp-record-s5.hzyXge/oracle.instrumented.c /tmp/blorp-record-s5.hzyXge/oracle.mapping.json
python3 /tmp/blorp-record-s5.hzyXge/test_instrument.py
python3 /tmp/blorp-record-s5.hzyXge/prepare_mechanics.py
```

For each of `oracle.normal.c`, `oracle.instrumented.c`, and `mechanics.c`, the tiny native command was `clang -O2 -fwrapv -w -DBLORP_MEMORY_DIAGNOSTICS=1 INPUT.c -lm -lpthread -o OUTPUT`. Run both oracle executables with `BLORP_MEMORY_STATS=1`, once with no extra argument and once with `extra`; compare stdout and maker counts to the retained exact logs. Run `mechanics` with the same environment and require its exact joined-thread assertion line. These are setup/validation commands, never the self-compile measured boundary.

## Decision

The census makes `Cursor` the first bounded investigation target. Its current source representation is three scalar Int coordinates, and source reconstruction loops repeatedly replace whole `Cursor` records. A source-owned loop can retain scalar coordinates internally and materialize the same managed record at its boundary, without changing public record semantics or adding a general compiler inliner. This is a hypothesis to validate with the separately reviewed pilot, generated-C identity where appropriate, correctness, allocation and quiet retired-instruction gates—not a claimed saving of all 39.5 million allocations.

The previous literal-only projection pass remains parked after its zero strict-eligible fusion-Core census. General inlining, new ABIs, layout promises, parent inlining, managed-field ownership changes and other S5 optimizations remain out of scope and open. This packet records measurement and prioritization only; the Cursor pilot's final accept/reject decision is to be added after its independent gates.
