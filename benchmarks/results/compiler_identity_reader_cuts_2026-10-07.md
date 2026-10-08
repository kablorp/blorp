# First identity reader cuts, 2026-10-07

> Publication note: this packet is a path-only projection of the privately archived original evidence. Original measurement, review, seal and copy hashes below remain historical original-byte authority; they do not hash the projected metadata or controllers. Numeric results, timestamps, source/compiler/C hashes and unchanged payload bytes are preserved. The [publication contract](compiler_reader_cuts_publication_2026-10-07/README.md) and its `PUBLICATION_MANIFEST.json` identify current public byte hashes. Historical controllers are evidence, not directly runnable configurations.


This delivery integrates all three independently reviewed cuts. Combined correctness,
selected sanitizer and generated-C audit gates **PASS**. The first pair and the
standalone vector cut each passed their measured resource scope; the final
combined resource comparison also **passes** within frozen self/small scope.
These are bounded enabling changes,
with no speed or wall-time claim. Ordering is maintained in
[the identity roadmap](../../docs/IDENTITY_ROADMAP.md#order-and-parallelism).

## Scope and order

Prefer complete consumer changes that use facts already carried by the compiler
before changing carriers, identity authorities or IR schemas.

1. Semantic variable equality now compares both the existing name and
   `SemanticTypeVarKind`. Base plus new tests has exactly two new failures and
   41 passes; the candidate passes all 43. Recursive structure and same-kind
   controls are covered. This changes equality only; Core kind propagation and
   type-parameter-list carriers remain open.
2. Backend projection uses the existing exact parallel filter-map predicate
   instead of two prefix tests. This preserves existing behavior: earlier
   admission already rejects unsupported names. Tests cover all 16 admitted ABI
   names and three lookalikes. Two obsolete magic-spelling allowlist rows were
   removed.
3. The vector option-get reader retains the call's Option result type and admits
   suffixed getters through the same exact layout selector as their producer,
   while preserving the generic getter. Unsupported suffixes and incompatible
   Option payloads no longer enter this rewrite. Base plus new tests has exactly
   two intended failures and 21 passes; candidate focused suites pass 23/23 and
   18/18. Three existing workload C pairs remain byte-identical. One obsolete
   allowlist row was removed. Its layout reads and selector construction were
   measured in the standalone resource comparison below.

All three independent code reviews approved with zero findings. No wider
builtin registry, vector formatter migration, Core parameter-kind carrier,
nominal-identity adoption, binder authority or stage rearchitecture is included.
No resolution-stage implementation is included. The dictionary fallback
prerequisite remains separate, described below.

## Final combined correctness evidence

Base: `7ab679600bcefa2fda3d0a14fe4b432758bad91b`. Validated tree:
`<worktree:reader-cuts>`, with four production files,
three changed owning suite files and three obsolete allowlist deletions.
The recomputed plan selects four owning suites and `compiler-core-sanitize`;
it recommends `compiler-blorp`.

| Command | Result |
| --- | --- |
| `make` with `BLORP_CLI_C_OPTIMIZATION=-O2`; `scripts/compiler-build-status` | PASS; FRESH before tests and after all gates |
| `scripts/compiler-check --changed` | 2,595 passed, 0 failed; selected owning suites and Core sanitizer |
| `scripts/test --no-build --serial --log-dir /tmp/blorp-identity-wave-combined-validation/broad-logs compiler-blorp` | 6,765 passed, 0 failed |
| `blorp/test/test_compiler/test_pipeline/codegen_audit/run_codegen_audit.sh bin/blorp --jobs 1` | 232 passed, 0 failed |
| `scripts/check-magic-spellings --strict` | PASS; 505 allowlisted findings, 0 new, 0 stale |
| `scripts/compiler-identity-census --check --json` | PASS; 3,446 census rows within budgets |
| `git diff --check` | PASS |

Test counts are separate gate aggregates, not additive unique-test totals.
Scanner counts are inventories, not unresolved bug counts; identity rows include
heuristic triage candidates. Worker C oracles are byte-identical for two equality
workloads, three parallel filter-map workloads and three vector workloads.
The final combined self/small outputs are also byte-identical.

The independent report is
`/tmp/blorp-identity-wave-combined-validation/TEST_RUNNER_REPORT.md`; exact
commands, timings and before/after fingerprints are in `commands.json`.
Validation-time compiler/test/allowlist patch SHA256:
`c99980103f311052f7e1ed5e46afbf199b6e92c79a2e9e8619d82793086afaee`.
Validation-time full tracked patch SHA256:
`f764beb90919f8ec9dbf3ecfecb5962f01162570c01aa2f0a9f07295f51dfda4`.
Installed O2 compiler SHA256:
`522ffdece99511889d86c9de6741ddac847efd6aa49f5a7e77c252e8e26f9d9a`.
Compiler, test, allowlist and tracked-document inputs stayed frozen; initial and
final compiler hashes match. All four build/focused/broad/codegen packets report
`source_changed_during_run=false`, including preserved untracked documentation
and result files in their fingerprints. Existing README/resolution drafts were
preserved. No commits or pushes were made.

Earlier `scripts/check-magic-spellings --strict --report` commands produced only
the census: report mode returns before allowlist validation at
`scripts/check-magic-spellings:580–582`. Their success is not strict-check
evidence. The current separate `--strict` command is recorded in
`combined-magic-strict.log`, with unchanged source and binary fingerprints,
and proves zero new and stale entries. The scanner itself was not changed.

The earlier first-pair correctness packet remains historical evidence at
`/tmp/blorp-identity-wave-final-validation/TEST_RUNNER_REPORT.md`: 2,567 selected,
6,760 broad and 232 audit checks. Its broad packet recorded document-only
`source_changed_during_run=true`; it does not describe the final integrated
compiler. The isolated vector packet at
`/tmp/blorp-vector-option-reader-wave3-validation/TEST_RUNNER_REPORT.md` records
2,476 selected, 6,761 broad and 232 audit checks with source changes false.
These counts are superseded by the final combined gate table for current inputs.
The first-pair scratch report carries a dated scan erratum and corrected
census-only label, with original bytes preserved as
`TEST_RUNNER_REPORT.pre-scan-erratum.md`. Standalone vector reports are retained with traceable scan errata and
original-content sidecars; their manifest identifies the sidecars as exact
inverse-patch reconstructions rather than pre-edit copies. Raw logs, ledgers,
metadata and measurements are unchanged.
Earlier report-mode commands are not strict enforcement evidence; the separate
current combined check above supplies that evidence for the integrated tree.

## Resource protocol and historical attempts

Current acceptance follows the maintained
[measurement protocol](../README.md#self-compile-measurement-protocol).
`benchmarks/README.md:1893–1900` and `docs/WORKER_CHECKLIST.md:139–142` permit
background activity and use minimum retired instructions across repeated runs.
Owned native jobs are serialized. Measurements retain matched source, binary,
toolchain, frozen input, paired diagnostic allocations and generated-C identity
checks; the allocation and instruction ceilings remain 0.5%. No quiet-host or
wall-time claim is made.

The initial attempt, one bounded retry and renewed wave2 attempt used a stricter
scratch quiet-host rule. Their samples were rejected under that then-active rule
and remain excluded from acceptance; no rejected baseline metrics were reused.
That admission rule is superseded by the repository protocol above. Historical
logs are retained in `/tmp/blorp-identity-wave-final-validation/resource-retry/`
and `/tmp/blorp-identity-wave-wave2-resource/TEST_RUNNER_REPORT.md`, including the
retry sample window 23:24:55.490103–23:26:40.845941 UTC and renewed wave2 baseline
self window 23:45:35–23:47:18 UTC. Candidate/small measurements did not proceed
after those rejections. They do not establish a candidate regression.

The vector wave2 availability wait exited 75 after 120 seconds without starting
a native command. Its UNVERIFIED report and prepared batch remain at
`/tmp/blorp-vector-option-reader-wave2-validation/TEST_RUNNER_REPORT.md`.
The later wave3 correctness and standalone resource results supersede that
availability outcome within their explicit scopes.

Retained compiler pairs are actual O2 stage2 normal/diagnostic binaries with
Apple clang 21.0.0 and `self-7ab679600bce` construction provenance. Explicit-pair
harness records still report `compiler_stage=1` because that field follows the
rebuild flag; actual stage2 identity is established by pair hashes and
construction provenance. Raw metadata was not edited. The baseline compiler
source matches 7ab exactly; its known formatting-only fixture diff explains its
dirty checkout/version stamp.

## First pair resource acceptance

This accepted comparison covers semantic variable equality and exact parallel
filter-map admission, before vector integration. The standard harness used
three fresh normal samples per side/workload and paired diagnostic allocations.
Source, binary, archived-input, small-workload and paired-output checks stayed
intact. Background activity was recorded without a quiet-window claim.

| Workload | Base allocations | Candidate allocations | Base minimum instructions | Candidate minimum instructions | Instruction delta | Generated C |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Self | 245,056,112 | 245,056,112 | 229,157,014,450 | 229,357,161,486 | +0.087341% | Identical |
| Small | 1,689,044 | 1,689,044 | 1,596,202,656 | 1,596,939,719 | +0.046176% | Identical |

Both allocation deltas are 0%; both instruction increases are within 0.5%.
This is resource acceptance for the first pair, not evidence of a speedup or
final combined acceptance. Raw records, pair/input provenance and the
[verbatim comparison tables](compiler_identity_reader_cuts_2026-10-07/comparison-tables-verbatim.md)
are retained in `compiler_identity_reader_cuts_2026-10-07/`. The independent
report with sample spreads and observed background activity is
`/tmp/blorp-identity-wave-wave3-resource/TEST_RUNNER_REPORT.md`; exact commands
are in its `resource-commands.json`.

## Standalone vector resource acceptance

The frozen vector-only patch SHA256 is
`3a6d31701c498c106b125e1765a24a60bc5a503db8e6679fe48e9553889548b1`.
`/tmp/blorp-vector-option-reader-wave3-resource/FINAL_RESOURCE_RESULT.json` records
three normal instruction samples per side/workload, paired allocations,
matching input revisions and byte-identical output. Both primary metrics pass
the unchanged 0.5% increase ceiling.

| Workload | Base allocations | Candidate allocations | Allocation delta | Base minimum instructions | Candidate minimum instructions | Instruction delta | Generated C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Self | 245,056,112 | 245,056,522 | +0.000167309% | 229,073,908,756 | 228,793,451,928 | -0.122430717% | Identical |
| Small | 1,689,044 | 1,689,044 | 0% | 1,597,345,527 | 1,596,550,270 | -0.049786160% | Identical |

Self adds 410 allocations, all in the fused tensor-specialization phase; small
allocations are unchanged. Sample spreads and observed background activity are
retained in the result JSON and `RESOURCE_REPORT.md`. These measurements satisfy
the enabling ceiling within the frozen self/small scope; they are not a speed
or wall-time claim and do not predict the final combined result.

The original scratch controller completed self measurements, then exited 1 on
an input-path comparison between `/var` and the harness's normalized
`/private/var`, which refer to the same physical frozen tree. The authorized
scratch-only repair canonicalized both paths with `Path.resolve()`, revalidated
retained self evidence and ran only the small continuation. No source or binary
rebuild, self-measurement repeat or raw harness JSON edit occurred. Original
controller/failure evidence and the exact repair are preserved in
`CONTROLLER_REPAIR.json`; normal/diagnostic pair hashes and native commands are
in `results/stage2-pair-provenance.json` and `results/resource-commands.json`.

## Final combined resource comparison

**PASS within the frozen self/small scope.** The combined candidate uses the
validated compiler inputs above, three new normal samples per workload and
paired diagnostic allocations. It reuses only the accepted first-pair wave3
baseline records, after rechecking their JSON/C pins, exact-base source, frozen
3,871-file archive, generated input, small workload, paired binaries and O2
Apple clang 21.0.0 toolchains. Rejected quiet-policy records were not reused.

| Workload | Base allocations | Combined allocations | Allocation delta | Base minimum instructions | Combined minimum instructions | Instruction delta | Generated C | Acceptance |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| Self | 245,056,112 | 245,056,522 | +0.000167309% | 229,157,014,450 | 228,946,800,997 | -0.091733370% | Identical | PASS |
| Small | 1,689,044 | 1,689,044 | +0.000000000% | 1,596,202,656 | 1,597,845,135 | +0.102899152% | Identical | PASS |

Both exact integer +0.5% ceilings pass. Self adds 410 allocations; small
allocations remain unchanged. Minimum instruction spreads (base/candidate)
are 0.104149%/0.030537% for self and 0.115988%/0.029377% for small. Observed
background activity is recorded (8 PIDs during self, none during small), with no
quiet-window, speed or wall-time claim. This is bounded resource acceptance.

Custom `bin/blorp-reader-cuts-stage2` and
`bin/blorp-reader-cuts-stage2-diagnostic` outputs preserve the earlier accepted
first-pair binaries. Their full hashes and construction provenance are retained
with the [combined evidence](compiler_identity_reader_cuts_2026-10-07/combined/RESOURCE_REPORT.md).
Source/test/allowlist and stage1 fingerprints stayed fixed. Final FRESH,
paired-binary hashes, source/input hashes and postrun baseline JSON/C pins passed.
The batch exited 0, released the owned slot, and left no owned native jobs.
After acceptance, only the two newly generated combined stage2 executables were
moved to the scratch packet's retained-stage2-binaries/ directory, with byte
hashes rechecked. The relocation record preserves original measurement paths;
raw records, installed stage1 and earlier pairs remain unchanged.

The independently reviewed controller canonicalizes both filesystem paths at
comparison boundaries; it does not rewrite raw harness metadata. Its SHA256 is
`d3b2556ac7bcb4a332e8d9c7c5afade1639df39c8c95f6ea1954c7ccbabf52d0`;
reviewed expectation SHA256 is
`1bfa394e945b523400680b449e2f21c8b49ac010ec75a9e88eef882571fe3f96`.
Independent composition/controller review approved with zero findings. Accepted
raw JSON, per-phase comparison tables, source/pair/input provenance, exact
commands and postrun proofs are retained under `combined/` and `vector/` in the
result directory. The combined correctness report is retained under
`combined/correctness/`.

## Remaining dictionary prerequisite

Replacing the dictionary producer's generated getter name with its original
generic operation does not cover pre-specialized getters entering the general
fallback. `test_core_specialize_collection.brp:716–729` requires a
`blorp_dict_get_nullable` call with an unboxed Int key to have that key boxed.
Removing the prefix after changing only the generic producer would violate that
existing contract. The next prerequisite is authoritative fallback admission
shared with the producer. Keep the regression and avoid duplicating a runtime
name registry. Caller mapping and bounded acceptance criteria are retained in
`/tmp/blorp-dict-get-reader-audit/HANDOFF.md`; this hypothesis remains deferred.
