# Dimension solver kind preservation, 2026-10-07

> Publication note: this packet is a path-only projection of the privately archived original evidence. Original measurement, review, seal and copy hashes below remain historical original-byte authority; they do not hash the projected metadata or controllers. Numeric results, timestamps, source/compiler/C hashes and unchanged payload bytes are preserved. The [publication contract](compiler_reader_cuts_publication_2026-10-07/README.md) and its `PUBLICATION_MANIFEST.json` identify current public byte hashes. Historical controllers are evidence, not directly runnable configurations.


The solver now admits named factors by `SemanticTypeVarKind`, preserving that
contract in its immutable sum-of-products representation. This is a bounded
correctness and reader cut preceding parameter-list or Core carrier changes.

## Boundary

Previously `dim_to_canonical` discarded the kind of every `SemanticTypeVar` into
`DimMonomial.vars: List[String]`. Reconstruction inferred kind from its spelling,
and two candidate selectors separately tested the dimension sigil. A dimension
parameter named `Rows` could not solve `Rows + 1 = 5`; an ordinary type parameter
named `#Rows` could bind as a dimension. Same-spelling differing kinds could cancel.

Only explicit dimension parameters now enter that private named-factor channel.
Ordinary type parameters use the existing `DimOpaqueTypeFactor(SemanticType)` path,
which retains their full structural identity and compares through `types_equal`.
Reconstruction supplies the known dimension kind. Both downstream sigil checks
and the spelling-derived constructor call are deleted. Existing dimension sorting,
meta-session checks, meta-first binding priority, nonlinear restrictions and opaque
algebra stay in place. No new public carrier or runtime-name table is added.

This changes internal semantic-kind behavior; public dimension syntax remains
`#N`. `DimBindVar` and substitution remain name-based, and parameter-list/Core
kind migration is still open. This slice does not complete cross-phase identity.

## Regressions

Eight new owning-suite controls cover the two admission reversals, same-spelling
kind distinction, exact kind preservation during meta reconstruction, named
isolation, mixed candidate priority and opaque commutativity/multiplicity. On the
unchanged FRESH O2 baseline, seven fail as expected and 19 pass: 26 total, no
compile/setup failure. One old opaque-identity control is strengthened to squared,
non-isolatable factors: its previous `Stuck` expectation inadvertently depended on
an unsigilled dimension being ineligible. A separate direct comparison now checks
legitimate dimension binding to the exact opaque ordinary-variable remainder.

## Census and deferred work

Manual dimension-solver census: two `is_dimension_parameter_name` calls and one
`semantic_type_variable_named` call become zero, along with their imports. The
spelling scanner lists an older accessor name and does not observe these three
calls; its 502-entry allowlist remains unchanged. Scanner coverage is a separate
follow-up, not an asserted enforcement-ratchet improvement.

The audits rejected a shortcut for boxed tensor-loop C types: production prepare
re-derives storage from binder type, but standalone prepared Core and JSON accept
an independent ABI spelling. Retiring that reader needs a structural storage
carrier. Packed-enum formatter ownership likewise lacks the early type identity
needed for a complete cut; an emitter-only derived projection index is possible
but adds per-artifact cost. Provisional generic union payload storage cannot replace
RecvAttempt ABI policy. These remain separate from this complete solver consumer cut.

## Validation and resource evidence

**Accepted within the tested scope.** Source/tests and resource
comparison each received independent APPROVE with zero findings. Final test-runner
validation passed with unchanged source, tests, generated inputs and compiler.

| Gate | Result |
| --- | --- |
| Owning dimension solver | 26 passed, 0 failed |
| Manifest `types` stage: 31 suites plus leak | 2,313 passed, 0 failed |
| Serial broad compiler | 6,790 passed, 0 failed |
| Actual strict spelling enforcement | 502 allowlisted, 0 new, 0 stale |
| Identity census; hygiene; diff; FRESH O2 | PASS; 3,446 census rows |

Counts overlap. The manifest owns this solver in `types`; the generic
`--stage typecheck` shortcut omits it. No backend/runtime representation changed,
so no additional codegen/sanitizer gate was selected. The existing leak check,
production fixtures and complete frozen-C identity provide the scoped evidence.
Passing child logs may be pruned by `compiler-check`; aggregate raw logs and exact
commands are retained in the [test-runner report](compiler_dimension_kind_preservation_2026-10-07/final-validation/TEST_RUNNER_REPORT.md).
[Fail-before report](compiler_dimension_kind_preservation_2026-10-07/fail-before/TEST_RUNNER_REPORT.md)
retains the actual seven failures. All foreground native jobs completed and
released the shared serial slot before documentation integration.

| Workload | Baseline allocations | Candidate allocations | Baseline minimum instructions | Candidate minimum instructions | Instruction delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| Self | 244,863,442 | 244,863,442 | 228,763,175,100 | 228,947,991,780 | +0.080790% |
| Small | 1,689,096 | 1,689,096 | 1,598,495,230 | 1,599,798,388 | +0.081524% |

Baseline is exact `8fe717e28d461088258f7744db77f2d9c8d02a0f`; candidate changes only
the solver production file. Both actual stage2 normal/diagnostic pairs match Apple
clang 21, aarch64, CLI/runtime O2, split 8 and `self-8fe717e28d46`, modes 0/1.
Three normal samples per side/workload and paired diagnostic allocations pass exact
integer ceilings `candidate * 200 <= baseline * 201`. The paying consumers are
solver admission, equality, candidate selection and reconstruction in this slice.

Both whole frozen outputs are byte-identical: self 83,843,873 bytes, SHA256
`e203bf534162e77443563c1ff7037a7cef3c245d7f1d51ba4456c8e7ca5aef5e`;
small 40,512 bytes, SHA256
`8316ceeb6e78c5e7d6431c33d1a22b0b9ff9bb59b2ecd603fbc38b8a5b618abb`.
Frozen input was independently verified against the exact revision plus regenerated
embedded std **after baseline**, then all 3,873 paths/bytes were guarded throughout
candidate phases. This timing is retained. Explicit retained compiler arguments
leave incidental raw `compiler_stage=1`, outside-repository revision and skipped
freshness fields unchanged; paired construction and FRESH stage1 source inventories
establish actual stage2 authority. Builder-reported binary/C hashes are pinned
immediately and rechecked, along with all four raw records and frozen input.

[Independent resource review](compiler_dimension_kind_preservation_2026-10-07/RESOURCE_REVIEW.md)
and [comparison proof](compiler_dimension_kind_preservation_2026-10-07/comparison.json)
retain provenance, raw sample spreads and exact acceptance. Comparison SHA256:
`3e56e4927802e082e37f04a88a72286d9620316ea836824963ed50adfc26b752`.
Background work is permitted; there is no quiet-window, latency, speed or isolated
helper-allocation claim. Flat totals do not prove the opaque path allocation-free.

The [evidence packet](compiler_dimension_kind_preservation_2026-10-07/README.md)
retains 93 exact payloads in 1,634,520 stored bytes, with lossless gzip for large
records. Large C/compiler products and body object remain in scratch with hashes
recorded as omissions; small C is retained. [Copy manifest](compiler_dimension_kind_preservation_2026-10-07/COPY_MANIFEST.json)
SHA256 `49cb158d6da887bbca5d72ae0e9419eb897e76aa850561c2388f6215cba6f617`
records raw/stored hashes and encodings. The initial body-object copy was removed
by the retained `delivery_repair.py`; its omission remains explicit.
