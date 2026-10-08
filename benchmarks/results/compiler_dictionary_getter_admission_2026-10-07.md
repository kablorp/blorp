# Dictionary getter admission, 2026-10-07

> Publication note: this packet is a path-only projection of the privately archived original evidence. Original measurement, review, seal and copy hashes below remain historical original-byte authority; they do not hash the projected metadata or controllers. Numeric results, timestamps, source/compiler/C hashes and unchanged payload bytes are preserved. The [publication contract](compiler_reader_cuts_publication_2026-10-07/README.md) and its `PUBLICATION_MANIFEST.json` identify current public byte hashes. Historical controllers are evidence, not directly runnable configurations.


Correctness, selected sanitizer and generated-C gates **PASS**. The matched
stage2 self/small resource comparison **passes** within both unchanged 0.5%
ceilings. Base `2ee201fb5cb74e8a7b4f3d068a143d8d71dd2bad` already contains the
[three accepted reader cuts](compiler_identity_reader_cuts_2026-10-07.md).
This delivery retires one dictionary prefix reader; no speed or wall-time claim.

## Scope and contract

`specialize_collection.brp` now chooses a private immutable `CollectionErasedSlots`
policy once and passes it to boxing. Fallback admission uses the existing
alias-aware Option runtime selector shared with the generic getter producer.
Unknown suffixes, incompatible or non-Option results and wrong arities stay
unboxed. Existing pre-specialized nullable getters still box their erased keys.
There is no duplicate runtime-name registry or new public IR/runtime schema.

| Boxing caller | Existing authority | Policy |
| --- | --- | --- |
| Generic dictionary getter | Exact generic dispatch; original `runtime_name.is_some()` branch | First slot |
| Set add | Exact operation branch | First slot |
| Dictionary insert | Exact operation branch | First and second slots |
| Five-name fold branch | Existing exact operation set | First slot |
| Fallible stream fold | Exact operation branch | First slot |
| General fallback | Exact existing admissions, then two-argument shared Option selector | Classify once |

The generic producer's return conditions and fresh-key map/key bindings and
release sequence remain unchanged. One obsolete magic-spelling allowlist row is
removed. Broader builtin registry, formatter, parameter-kind carriers, nominal
identity, binder authorities and compiler-stage rearchitecture remain open.
Preexisting Void selector/native reachability is unchanged and **unverified**;
this cut does not claim every selector output has an implemented runtime symbol.

## Regression and correctness evidence

FRESH O2 exact-base compiler plus new tests: 35 total, **32 pass / 3 intended fail**
(unknown suffix, incompatible/non-Option payload, wrong arity). The candidate
passes **35/35**, including existing nullable/already-specialized key boxing,
14 primitive payloads, aliases, generic layouts, repeated boxing, managed borrowing
and fresh-key evaluation/ownership controls.

The first TDD attempt had 31 pass / 4 fail because a new positive control wrongly
expected allocating ownership for nonallocating FloatBox. A tests-only correction
to Int128Box produced the intended result; no compiler bug or production fix is
claimed. Original raw evidence and exact-hash reconstructed original-content
source are retained with the reconstruction method stated in
[the preservation manifest](compiler_dictionary_getter_admission_2026-10-07/tdd/FIRST_ATTEMPT_PRESERVATION.json).
After TDD, four name-only binder checks were strengthened to `core_var_equal`
(name + id); the candidate native suite verifies these stronger comparisons.

| Command/boundary | Result |
| --- | --- |
| O2 `make`; `scripts/compiler-build-status` | PASS; FRESH before tests and after gates |
| `scripts/compiler-check --changed --base 2ee201fb5cb74e8a7b4f3d068a143d8d71dd2bad` | 2,500 passed, 0 failed; collection suite + Core sanitizer |
| Additional program-specialization suite | 23 passed, 0 failed; absent from selected plan |
| Serial `scripts/test --no-build ... compiler-blorp` | 6,775 passed, 0 failed |
| One-worker codegen audit | 232 passed, 0 failed |
| Three focused C pairs | Byte-identical |
| `scripts/check-magic-spellings --strict` (without report mode) | PASS; 504 allowlisted, 0 new, 0 stale |
| `scripts/compiler-identity-census --check --json`; `git diff --check` | PASS; 3,446 census rows within budgets; clean diff |

Counts overlap and are not additive unique-test totals. Census rows include
heuristic triage, not unresolved bug counts. All eight build/gate/oracle packets
report `source_changed_during_run=false`; whole-batch inputs and binary stayed
frozen. The dirty stamp accurately includes the candidate and preserved docs.
Earlier `--strict --report` invocations were census-only; the separate strict
command above is enforcement evidence. The scanner itself is unchanged.

| Retained C oracle | Matching base/candidate SHA256 |
| --- | --- |
| `dict_get_or_fast_path.brp` | `9a563e6059251d228f301d4239360e53b22c6b21a8f458e8d9bfa3f3ae1d126b` |
| `dict_opaque_alias_key.brp` | `16b0e9781c195dcefdfa144044e67988bbb25e4016422a6fe62538e8080121d5` |
| Retained dictionary payload/alias layouts | `a18e191a0703084c8031259be124d424537efff564824d73ff5bd702c09b1559` |

Compiles used `--no-format --no-embed-runtime -o <scratch>`. The opaque-key fixture
is a key-layout control; the third copies 12 retained dictionary getter tests
into runnable main. These three checks prove C identity, not separate runtime
execution. [Independent report](compiler_dictionary_getter_admission_2026-10-07/correctness/TEST_RUNNER_REPORT.md),
[commands](compiler_dictionary_getter_admission_2026-10-07/correctness/commands.json),
[plan](compiler_dictionary_getter_admission_2026-10-07/correctness/selected-plan.json)
and [C comparisons](compiler_dictionary_getter_admission_2026-10-07/correctness/c-oracles.json)
retain exact arguments, results and hashes.

Reviewed three-path patch SHA256:
`309c7f9089401bdf5b503d6546412893aeee37f5dc21f5312c64d0c3998824db`.
Production file SHA256: `4df0e49ff89b8a9276b5f18359fdc688a975736cd872a34d335626e45c1ee84e`.
FRESH O2 candidate stage1 SHA256: `a17a6ed3cdfcac11df20e459bea1b7235a57768194d73551a78c0a76964513ab`.
Exact-base stage1 SHA256: `151ef0ac264ffeab97a521c39d02f96a7b627ba0019979ff21c97557db5b2cd8`.
[Source/binary provenance](compiler_dictionary_getter_admission_2026-10-07/correctness/provenance.json)
and [validated patch](compiler_dictionary_getter_admission_2026-10-07/correctness/validated-candidate.patch)
preserve validation authority. Large generated C, archives and executables stay
in owned scratch; the durable packet retains their hashes/proofs, not copies.

## Matched resource acceptance

Use the maintained [measurement protocol](../README.md#self-compile-measurement-protocol):
owned native jobs serialized, background activity permitted, at least three
normal samples per side and workload, minimum retired instructions and paired
diagnostic allocations, exact frozen input/pair identity and generated-C checks.
The unchanged allocation and instruction increase ceilings are 0.5%.
The selector can construct a nullable name for unrelated two-argument fallback
calls; the accepted measurements cover this enabling cost without a speed claim.

| Workload | Base allocations | Candidate allocations | Allocation delta | Base minimum instructions | Candidate minimum instructions | Instruction delta | Whole generated C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Self | 245,063,861 | 245,078,157 | +0.005833581% | 229,266,550,292 | 229,384,176,098 | +0.051305263% | Identical |
| Small | 1,689,044 | 1,689,099 | +0.003256280% | 1,598,242,714 | 1,597,713,063 | -0.033139585% | Identical |

[Self](compiler_dictionary_getter_admission_2026-10-07/resource/comparison/resource-summary-self.json) and
[small summaries](compiler_dictionary_getter_admission_2026-10-07/resource/comparison/resource-summary-small.json)
match the raw records. [Final pin proof](compiler_dictionary_getter_admission_2026-10-07/resource/comparison/COMPARISON_COMPLETE.json)
rechecks all four JSON/C pairs and recomputes both budgets after later commands.
[Controller review](compiler_dictionary_getter_admission_2026-10-07/review/IMPLEMENTATION_CONTROLLER_REVIEW.md)
records the repair adding those protections; [resource report](compiler_dictionary_getter_admission_2026-10-07/resource/RESOURCE_REPORT.md)
retains samples and background observations. Actual stage2 construction/pair
provenance controls identity; outside-repository raw fields remain stage1,
unknown revision/freshness and are not rewritten. Owned resource session70900
exited 0 and released its slot. [Independent resource review](compiler_dictionary_getter_admission_2026-10-07/review/RESOURCE_REVIEW.md)
approves acceptance with zero findings.

[Next-cut preparation](compiler_dictionary_getter_admission_2026-10-07/review/NEXT_CUT.md)
proposed an emitter-local ranked tensor getter ABI descriptor before deleting
two suffix readers. That separate follow-up is now accepted in
[the ranked getter results](compiler_ranked_tensor_getter_abi_2026-10-07.md), with
its own controls, review and acceptance gates. The proposal remains historical.
Vector formatting needs a wider transfer of authoritative enum facts and remains
deferred.
