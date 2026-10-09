# Mono terminal dimension-pack kind, 2026-10-08

Mono now uses the existing `TensorVariadicDim` variant to select a dimension-pack
substitution. Its name remains the substitution key; Mono no longer checks that
key for a `#` prefix at this terminal-pack consumer.

## Boundary and regressions

Lowering already maps `SemanticVarDimsType` to `TensorVariadicDim`, Core JSON
preserves this explicit variant, and specialization accepts terminal packs without
a spelling restriction. Previously, an unsigilled named pack admitted by these
boundaries silently produced no substitution evidence. Ordinary type parameters
with the same spelling remain a different substitution domain.

The owning suite covers named/implicit packs, fixed and runtime prefixes, an empty
remainder, caller-rigid evidence in both insertion orders, conflicting evidence,
wildcard, nonterminal and identity controls. On the corrected tests-only baseline,
five regressions fail and 34 controls pass; the candidate passes all 39 cases.
An initial run also failed an incorrect new nonterminal-pack expectation. That
oracle was corrected to preserve the existing skipped-binding behavior; both
original runs remain retained. This establishes an internal Core contract fix,
not a demonstrated source-language diagnostic bug. Source dimension syntax
remains `#N`.

The two remaining Mono sigil-reader calls require kinds in Core value-parameter
and parameter-list carriers. The helper's one allowlist row stays. Manual Mono
consumer count changes from three to two; this is not complete family retirement.
The `#_` wildcard, name-based binding identity, substitution API and IR schema
remain unchanged.

## Resource acceptance

| Workload | Baseline allocations | Candidate allocations | Baseline minimum instructions | Candidate minimum instructions | Instruction delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| Self | 249,479,886 | 249,479,886 | 233,128,988,530 | 233,050,360,371 | -0.033727% |
| Small | 1,722,783 | 1,722,783 | 1,625,933,040 | 1,626,589,664 | +0.040384% |

Both allocations and minimum retired instructions pass the unchanged exact
ceiling `candidate * 200 <= baseline * 201`. Each side uses three normal samples
and paired diagnostic allocations. Full samples remain in the raw records.
Both entire frozen output C files are byte-identical: self 84,239,845 bytes,
SHA256 `e91eefbed412ecf17f22f4a1df58f128a5b1e88f24445c748862ffc592ba4a56`;
small 40,571 bytes,
SHA256 `9ce3c4d32148311c393a6775383f007c7e06cd24007f0f4452609b86ae26f083`.

Base and frozen input are `5e6ef4bcfb8871b9a666f042145f313502737609`.
Production changes only `mono.brp`, from SHA256
`460626f3f4372df869bf8fe8c23a8e34134f08cd5e0bd4e19aeccb2ea2c94a16`
to `9b092b9e8a0b93cdeca3f61a049f03a802e72dcb557ad60ce6034a954be67910`.
The owning test SHA256 is
`087e2db7ed68ee5fc3706bb18fe04f9e169167f0dd55cd6c51ec97925c31965b`.
The frozen 3,914-file input was independently compared with the exact Git archive
plus regenerated embedded standard library, then guarded through both workloads.

Actual stage2 pairs share a generated compiler C/body object for normal and
diagnostic links. Both use Apple clang 21, aarch64, CLI/runtime O2, and memory modes
0/1. The explicit-pair harness records `compiler_stage=1`; retained construction
commands, shared body hashes, pair pins and `compiled_by: self-5e6ef4bcfb88`
establish actual stage2. Its version's `split: 8` stamp does not describe this
builder's single-body C compilation. Raw metadata remains preserved. Source,
tests, index, input, pairs and installed compiler were guarded; final FRESH and
foreground completion/serial-slot release passed on both batches.

The measurements permit background work and use the established minimum-of-runs
policy. There is no quiet-window, latency, speed or isolated helper-cost claim.
Flat workload totals do not prove this individual reader allocation-free.

## Validation

Source/tests, the resource comparison and [final delivery review](compiler_mono_pack_kind_2026-10-08/FINAL_REVIEW.md) each received
independent APPROVE with zero outstanding findings. The [test-runner's final guarded batch](compiler_mono_pack_kind_2026-10-08/TEST_RUNNER_REPORT.md) passed:

| Gate | Result |
| --- | --- |
| Owning Mono | 39 passed, 0 failed |
| Selected Core ASan | 2,557 passed, 0 failed |
| Mono specialization / monomorphization | 34 / 7 passed, 0 failed |
| Broad compiler-blorp | 7,046 passed, 0 failed |
| Strict spelling enforcement | 498 allowlisted, 0 stale |
| Identity census | 3,444 rows, within baseline |
| Hygiene; diff; final FRESH O2 | PASS |

Counts overlap. The manifest selects the owning suite and `compiler-core-sanitize`;
the sanitizer ran directly to retain its complete child log. The owning pass is
reused from the candidate resource batch at identical source/test/compiler authority.
Native commands ran serially; all foreground children completed and released the
shared slot before this documentation integration. Full premerge/Docker was not
run for this implementation slice. No generated-C audit was selected by the Mono
manifest; complete frozen self/small C identity is retained.

The [evidence packet](compiler_mono_pack_kind_2026-10-08/README.md) retains the raw
measurement records, construction commands/logs, original completion seals,
corrected fail-before and passing owning logs, resource review and selected gate
logs. It replaces only path prefixes with role tokens; nested historical hashes
still identify original bytes. The [publication manifest](compiler_mono_pack_kind_2026-10-08/PUBLICATION_MANIFEST.json)
separately records original, published and decoded hashes. Full C/compiler products
and redundant source/input inventories stay private with listed hashes. This is a
bounded evidence projection, not a newly measured run. Documentation and evidence
integration follows the accepted source/tests; it does not change the compiler
body or require another resource measurement.
