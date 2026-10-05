# Fixed union P1 stage-2 acceptance evidence

No source changes, allowance flags, bootstrap pin changes, commits, or publication.
Both checkouts retain base 133eaf73a63830522b659ab6a2da65f9f2963711.
Both stage-1 compilers were FRESH before the measurements, pinned dev-d44472d3a5d0,
CLI/runtime O2, Apple Clang 21.0.0. Candidate P1 source remains dirty and frozen.
Baseline source has docs-only changes. Manual coordinator token serialized task jobs;
the harness lock subcommand is a no-op. Unknown work elsewhere on the host may add
noise; two samples and their minimum are retained. No speedup claim is made.

## Exact self commands

In baseline 43a9 and candidate fixed-union-frontend respectively, with
BLORP_CLI_C_OPTIMIZATION=-O2:

```text
benchmarks/self_compile_measure --stage2 --samples 2 --input-rev 133eaf73a63830522b659ab6a2da65f9f2963711 --label baseline-fixed-union-p1 --output /tmp/blorp-fixed-union-stage2.5qu3A2/baseline-self.json --keep-output /tmp/blorp-fixed-union-stage2.5qu3A2/baseline-self.c
benchmarks/self_compile_measure --stage2 --samples 2 --input-rev 133eaf73a63830522b659ab6a2da65f9f2963711 --label candidate-fixed-union-p1 --baseline /tmp/blorp-fixed-union-stage2.5qu3A2/baseline-self.json --output /tmp/blorp-fixed-union-stage2.5qu3A2/candidate-self.json --keep-output /tmp/blorp-fixed-union-stage2.5qu3A2/candidate-self.c --require-identical
```

Each stage-2 build used the maintained builder's single generated body C/object
and separate normal/diagnostic native runtime links. Pair provenance matched and
runtime modes were 0 and 1. The two normal samples matched diagnostic emitted C.
Raw measurement JSON, logs and generated C are retained beside this report.

## Self comparison, verbatim

```text
wrote /tmp/blorp-fixed-union-stage2.5qu3A2/candidate-self.json

baseline : baseline-fixed-union-p1 @ 133eaf73a638
candidate: candidate-fixed-union-p1 @ 133eaf73a638
input    : 133eaf73a638  program=self
output C : IDENTICAL (77451514 vs 77451514 bytes)

metric                                               baseline        candidate     delta
----------------------------------------------------------------------------------------
allocs source_discovery_start                             652              652    +0.00%
allocs source_discovery_complete                   18,795,366       18,795,366    +0.00%
allocs typed_frontend_start                                 5                5    +0.00%
allocs typed_frontend_complete                     38,878,636       38,878,636    +0.00%
allocs core_lowering_input_ready                            8                8    +0.00%
allocs core_lowering_complete                      20,486,369       20,486,369    +0.00%
allocs pass_lower_complete                                 64               64    +0.00%
allocs pass_debug_complete                            140,243          140,243    +0.00%
allocs pass_prune_early_complete                      166,271          166,271    +0.00%
allocs pass_desugar_complete                        1,440,616        1,440,616    +0.00%
allocs pass_mono_complete                          23,741,531       23,741,531    +0.00%
allocs pass_synth_complete                            222,712          222,712    +0.00%
allocs pass_match_complete                          5,538,859        5,538,859    +0.00%
allocs pass_trait_resolve_complete                  4,842,389        4,842,389    +0.00%
allocs pass_prune_after_trait_resolve_complete        2,303,997        2,303,997    +0.00%
allocs pass_resolve_complete                        3,699,705        3,699,705    +0.00%
allocs pass_std_inline_complete                     1,950,532        1,950,532    +0.00%
allocs pass_tailrec_complete                          175,286          175,286    +0.00%
allocs pass_fuse_string_complete                    2,588,777        2,588,777    +0.00%
allocs pass_fuse_collection_complete                3,021,496        3,021,496    +0.00%
allocs pass_fuse_parallel_tensor_complete           1,304,632        1,304,632    +0.00%
allocs pass_fuse_tensor_update_complete                43,756           43,756    +0.00%
allocs early_core_complete                                  7                7    +0.00%
allocs pass_tuple_flatten_complete                  7,619,575        7,619,575    +0.00%
allocs runtime_projection_complete                    972,616          972,616    +0.00%
allocs pass_adapt_function_refs_complete            1,952,278        1,952,278    +0.00%
allocs pass_tensor_specialize_specialize_fused_complete        1,749,489        1,749,489    +0.00%
allocs pass_hash_key_callbacks_complete                 3,578            3,578    +0.00%
allocs pass_resolve_backend_match_fused_complete        3,519,375        3,519,375    +0.00%
allocs pass_dce_complete                            2,612,516        2,612,516    +0.00%
allocs pass_consume_specialize_complete             1,986,496        1,986,496    +0.00%
allocs pass_static_string_literals_complete         1,620,111        1,620,111    +0.00%
allocs pass_record_update_ownership_complete        1,742,028        1,742,028    +0.00%
allocs pass_dict_literal_ownership_complete           128,846          128,846    +0.00%
allocs pass_ownership_perceus_fused_complete       55,464,126       55,464,126    +0.00%
allocs pass_reuse_complete                            844,297          844,297    +0.00%
allocs pass_closure_complete                        2,435,160        2,435,160    +0.00%
allocs pass_resource_management_complete              323,784          323,784    +0.00%
allocs pass_fairness_complete                         169,919          169,919    +0.00%
allocs pass_prepare_complete                          904,328          904,328    +0.00%
allocs pass_prepared_reuse_complete                   399,733          399,733    +0.00%
allocs cleanup_plan_complete                        1,230,290        1,230,290    +0.00%
allocs cancellation_plan_complete                  10,500,058       10,500,058    +0.00%
allocs late_core_complete                                   5                5    +0.00%
allocs backend_emission_complete                   16,141,162       16,141,162    +0.00%
allocs artifact_construction_complete                      76               76    +0.00%
allocs TOTAL                                      241,661,755      241,661,755    +0.00%
instructions retired (min)                    223,730,287,224  223,693,748,427    -0.02%
output bytes                                       77,451,514       77,451,514    +0.00%
peak RSS bytes                                  2,202,796,032    2,200,076,288    -0.12%

```

## Small guard and helper metadata limitation

Both small.brp files hash
6a67158fb09aac383ec40e77e5c5b1d64fd068b19edf6e2596a6f25060d9cc93.
Use the exact retained stage-2 pair through --compiler bin/blorp-stage2 and
--diagnostic-compiler bin/blorp-stage2-diagnostic with --program small, --samples 2,
the same --input-rev, O2 environment, corresponding labels/output/C retention,
and candidate --baseline baseline-small.json --require-identical. No build-check
or toolchain bypass flags were used. Each check reports FRESH.

The unmodified helper labels external binary pairs compiler_stage=1 and writes
stage2_built_by_bin_blorp_sha256=null. THESE SMALL JSON FIELDS ARE NOT CORRECT STAGE
PROVENANCE. Raw JSON is unchanged: exact normal/diagnostic hashes match the self
run's stage-2 pair; self-133e version metadata and the self JSON's generator hashes
prove actual stage. Coordinator explicitly approved this reuse rather than
rebuilding unchanged compilers or changing the harness during the syntax task.

## Small comparison, verbatim

```text
wrote /tmp/blorp-fixed-union-stage2.5qu3A2/candidate-small.json

baseline : baseline-fixed-union-p1-small @ 133eaf73a638
candidate: candidate-fixed-union-p1-small @ 133eaf73a638
input    : 133eaf73a638  program=small
output C : IDENTICAL (39575 vs 39575 bytes)

metric                                               baseline        candidate     delta
----------------------------------------------------------------------------------------
allocs source_discovery_start                             652              652    +0.00%
allocs source_discovery_complete                      427,317          427,317    +0.00%
allocs typed_frontend_start                                 5                5    +0.00%
allocs typed_frontend_complete                        763,129          763,129    +0.00%
allocs core_lowering_input_ready                            8                8    +0.00%
allocs core_lowering_complete                         234,845          234,845    +0.00%
allocs pass_lower_complete                                 64               64    +0.00%
allocs pass_debug_complete                              3,506            3,506    +0.00%
allocs pass_prune_early_complete                       15,029           15,029    +0.00%
allocs pass_desugar_complete                            8,246            8,246    +0.00%
allocs pass_mono_complete                              36,925           36,925    +0.00%
allocs pass_synth_complete                              6,876            6,876    +0.00%
allocs pass_match_complete                             23,607           23,607    +0.00%
allocs pass_trait_resolve_complete                     43,805           43,805    +0.00%
allocs pass_prune_after_trait_resolve_complete           16,185           16,185    +0.00%
allocs pass_resolve_complete                           15,308           15,308    +0.00%
allocs pass_std_inline_complete                            14               14    +0.00%
allocs pass_tailrec_complete                            6,702            6,702    +0.00%
allocs pass_fuse_string_complete                        9,880            9,880    +0.00%
allocs pass_fuse_collection_complete                    9,723            9,723    +0.00%
allocs pass_fuse_parallel_tensor_complete               6,031            6,031    +0.00%
allocs pass_fuse_tensor_update_complete                 1,657            1,657    +0.00%
allocs early_core_complete                                  7                7    +0.00%
allocs pass_tuple_flatten_complete                     28,804           28,804    +0.00%
allocs runtime_projection_complete                      3,924            3,924    +0.00%
allocs pass_adapt_function_refs_complete                6,586            6,586    +0.00%
allocs pass_tensor_specialize_specialize_fused_complete            5,371            5,371    +0.00%
allocs pass_hash_key_callbacks_complete                   157              157    +0.00%
allocs pass_resolve_backend_match_fused_complete           13,886           13,886    +0.00%
allocs pass_dce_complete                                3,022            3,022    +0.00%
allocs pass_consume_specialize_complete                    96               96    +0.00%
allocs pass_static_string_literals_complete             1,090            1,090    +0.00%
allocs pass_record_update_ownership_complete            1,084            1,084    +0.00%
allocs pass_dict_literal_ownership_complete               177              177    +0.00%
allocs pass_ownership_perceus_fused_complete           20,245           20,245    +0.00%
allocs pass_reuse_complete                                200              200    +0.00%
allocs pass_closure_complete                            1,507            1,507    +0.00%
allocs pass_resource_management_complete                  164              164    +0.00%
allocs pass_fairness_complete                             219              219    +0.00%
allocs pass_prepare_complete                              279              279    +0.00%
allocs pass_prepared_reuse_complete                       326              326    +0.00%
allocs cleanup_plan_complete                              760              760    +0.00%
allocs cancellation_plan_complete                       6,845            6,845    +0.00%
allocs late_core_complete                                   5                5    +0.00%
allocs backend_emission_complete                        9,672            9,672    +0.00%
allocs artifact_construction_complete                      12               12    +0.00%
allocs TOTAL                                        1,733,952        1,733,952    +0.00%
instructions retired (min)                      1,604,900,420    1,604,854,246    -0.00%
output bytes                                           39,575           39,575    +0.00%
peak RSS bytes                                     37,502,976       37,093,376    -1.09%

```

## Full paired provenance, verbatim JSON excerpts

```json
{
  "compiler_sha256": "cea32dbc0db4d25d90f0bc36e9163964b688ef20586f07454e1dda926711715f",
  "diagnostic_compiler_sha256": "f4e9ab52459da9545e1c2161651a6485acf22e19d8994a17edd3c44695f48897",
  "stage2_built_by_bin_blorp_sha256": "29f646a02726705420cce82ac5d5c7282a50967667628fb4ec69c5f3097bba4c",
  "output_sha256": "d72813c239dc24aff917fb0b1fdbd57c9451079c27d94a1849312b8756657515",
  "output_bytes": 77451514,
  "total_allocations": 241661755,
  "instructions_retired": {
    "min": 223730287224,
    "median": 223809510419.0,
    "samples": [
      223730287224,
      223888733614
    ]
  },
  "toolchain": {
    "cc_version": "Apple clang version 21.0.0 (clang-2100.3.34.2)",
    "compiler_version": [
      "blorp 0.0.1",
      "commit: 133eaf73a638-dirty",
      "target: aarch64-apple-darwin",
      "channel: local",
      "dirty: true",
      "compiled_by: self-133eaf73a638",
      "optimization: cli=-O2 runtime=-O2",
      "split: 8",
      "cc: Apple clang version 21.0.0 (clang-2100.3.34.2)",
      "memory_diagnostics: 0",
      "",
      ""
    ],
    "compiled_by": "self-133eaf73a638",
    "optimization": "cli=-O2 runtime=-O2",
    "commit": "133eaf73a638-dirty",
    "target": "aarch64-apple-darwin",
    "split": "8",
    "cc": "Apple clang version 21.0.0 (clang-2100.3.34.2)",
    "memory_diagnostics": "0"
  },
  "diagnostic_toolchain": {
    "cc_version": "Apple clang version 21.0.0 (clang-2100.3.34.2)",
    "compiler_version": [
      "blorp 0.0.1",
      "commit: 133eaf73a638-dirty",
      "target: aarch64-apple-darwin",
      "channel: local",
      "dirty: true",
      "compiled_by: self-133eaf73a638",
      "optimization: cli=-O2 runtime=-O2",
      "split: 8",
      "cc: Apple clang version 21.0.0 (clang-2100.3.34.2)",
      "memory_diagnostics: 1",
      "",
      ""
    ],
    "compiled_by": "self-133eaf73a638",
    "optimization": "cli=-O2 runtime=-O2",
    "commit": "133eaf73a638-dirty",
    "target": "aarch64-apple-darwin",
    "split": "8",
    "cc": "Apple clang version 21.0.0 (clang-2100.3.34.2)",
    "memory_diagnostics": "1"
  }
}
{
  "compiler_sha256": "b2e20fe4b75c40e17244dece73a8837a6ac772c9462a3a2a64cc5376cfcd4eef",
  "diagnostic_compiler_sha256": "8798e29b713b0204e6d444f93768c21805f8a50099f3bebd70027272fac66931",
  "stage2_built_by_bin_blorp_sha256": "d107945c079c76cf57f8b12baa0d7b57295b615be6737c67c37b97ef17abff0a",
  "output_sha256": "d72813c239dc24aff917fb0b1fdbd57c9451079c27d94a1849312b8756657515",
  "output_bytes": 77451514,
  "total_allocations": 241661755,
  "instructions_retired": {
    "min": 223693748427,
    "median": 223742157809.0,
    "samples": [
      223790567191,
      223693748427
    ]
  },
  "toolchain": {
    "cc_version": "Apple clang version 21.0.0 (clang-2100.3.34.2)",
    "compiler_version": [
      "blorp 0.0.1",
      "commit: 133eaf73a638-dirty",
      "target: aarch64-apple-darwin",
      "channel: local",
      "dirty: true",
      "compiled_by: self-133eaf73a638",
      "optimization: cli=-O2 runtime=-O2",
      "split: 8",
      "cc: Apple clang version 21.0.0 (clang-2100.3.34.2)",
      "memory_diagnostics: 0",
      "",
      ""
    ],
    "compiled_by": "self-133eaf73a638",
    "optimization": "cli=-O2 runtime=-O2",
    "commit": "133eaf73a638-dirty",
    "target": "aarch64-apple-darwin",
    "split": "8",
    "cc": "Apple clang version 21.0.0 (clang-2100.3.34.2)",
    "memory_diagnostics": "0"
  },
  "diagnostic_toolchain": {
    "cc_version": "Apple clang version 21.0.0 (clang-2100.3.34.2)",
    "compiler_version": [
      "blorp 0.0.1",
      "commit: 133eaf73a638-dirty",
      "target: aarch64-apple-darwin",
      "channel: local",
      "dirty: true",
      "compiled_by: self-133eaf73a638",
      "optimization: cli=-O2 runtime=-O2",
      "split: 8",
      "cc: Apple clang version 21.0.0 (clang-2100.3.34.2)",
      "memory_diagnostics: 1",
      "",
      ""
    ],
    "compiled_by": "self-133eaf73a638",
    "optimization": "cli=-O2 runtime=-O2",
    "commit": "133eaf73a638-dirty",
    "target": "aarch64-apple-darwin",
    "split": "8",
    "cc": "Apple clang version 21.0.0 (clang-2100.3.34.2)",
    "memory_diagnostics": "1"
  }
}
```

## Stage-2 fixed-union capability and ownership

Command in candidate:
```text
bin/blorp-stage2 test --leak-check --timeout 180 blorp/test/runtime/memory/test_fixed_union_synonym_ownership.brp
```
Full log: candidate-stage2-fixed-union-ownership.log. 3/3 passed using candidate
normal stage-2 binary b2e20fe4b75c40e17244dece73a8837a6ac772c9462a3a2a64cc5376cfcd4eef.
The leak-test harness standard_library/src/test.brp:332-380 resets counters before
each test, checks get_mem_stats().current_objects, and fails a test/suite for
remaining objects; all three passed. It resets again after the suite, so the
process-exit 3 allocations / 3 releases / zero leaks describe the post-suite
harness interval, NOT program allocation cost or a universal ownership proof.

## Fixpoint

PASS: unmodified O2 scripts/compiler-fixpoint --work-dir
/tmp/blorp-fixed-union-stage2.5qu3A2/fixpoint exits 0. Full log fixpoint.log retained.
Stage 1, stage 2 and stage 3 outputs are all byte-identical; each SHA256 is
8ca7411914f20a815e11132f035eb8bb2a9a33201f4b8bfce5eefc424253fc27.
No raw C normalization was performed. All three output C files and executables
are retained under fixpoint/. Its rebuilt stage-2 executable matches the measured
candidate b2e20fe4b75c40e17244dece73a8837a6ac772c9462a3a2a64cc5376cfcd4eef exactly.
Stage-3 binary SHA256 is
60860e8951dc7bcb5727b7f1e4239699eff526cacc33f0c2d1b50f69de342b8f.

The shared stage-2 build source C differs between baseline and candidate because
it compiles their different compiler SOURCE trees, as expected: baseline hash
76324a105e62d0ab8e57bf4fc86e075e7091ed8c2aaf4b04b4643cba03e9553c, candidate hash
8ca7411914f20a815e11132f035eb8bb2a9a33201f4b8bfce5eefc424253fc27.
This is distinct from measured frozen-input output C, whose baseline/candidate
hash matches d72813c239dc24aff917fb0b1fdbd57c9451079c27d94a1849312b8756657515.

Interpretation: cost-neutral on these frozen ordinary/legacy-source workloads,
with exact phase allocation equality and raw output identity. P1 new fixed syntax
also passed the narrow stage-2 capability fixture and candidate self-host fixpoint.
Neither a checked-fixed guarantee nor a published/pinned bootstrap is claimed.
