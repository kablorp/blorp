# Tensor native projection preparation

Status: independently reviewed preparation, accepted by the independent
test-runner. Exact baseline and candidate builds are FRESH; all four raw C
comparisons and owner/sanitizer gates pass. Commit remains pending.
Planned commands below are not validation.

This three-file refactor makes the tensor element C type an explicit argument
to the storage classifier. Every original arm projected the same element type
exactly once. The two callers supply the unchanged query. No native authority,
logical tag, type admission, representation, or declaration order changes.
The raw-proof fallback was already evaluated eagerly.

The future canonical native probes are held under
`benchmarks/fixtures/union_native_authority/` and excluded from this preparation
and its commit. Their imported-name source legality and current scalar controls
pass, but reordered canonical mappings are unverified. Direct enum foreign crossings in those
probes are historical scalar controls, not managed-union admission policy.

## Frozen sources

Baseline revision: `66944f3e97af7c394661747af69ef9f1afa44dfd`.
Baseline checkout: `<worktree:union-native-baseline>`.
Candidate checkout: `<worktree:union-native-authority>`.

Reviewed candidate production SHA-256:

| Source | SHA-256 |
| --- | --- |
| `stage_08_core_lower/list_layout.brp` | `1d03a6c838eb02862328f882240fef11eedb9a14387a6efcdccbf0e104d71934` |
| `stage_08_core_lower/lower.brp` | `c660c6ad2108458c9eae97a2868ceda5f0015ea4805864cdb63eb4581461a4f4` |
| `stage_09_core/prepare.brp` | `c6d4a7c7211d19ce567a018caa9f4765ada58dc66f9b05bfb1f1d678879223d9` |

## Planned serialized validation

Run only after the coordinator grants the global compiled token. Build baseline
first, then candidate, retaining separate logs and binary hashes. In each
checkout:

```sh
BLORP_CLI_C_OPTIMIZATION=-O2 make
scripts/compiler-build-status
bin/blorp --version
shasum -a 256 bin/blorp blorp/build/bootstrap.env
```

Use both compilers against the same absolute baseline-owned source paths and
baseline `standard_library/src`. Compile with `--no-format --no-embed-runtime`,
using separate output files; compare complete C bytes and retain SHA-256s.

```sh
bin/blorp compile --no-format --no-embed-runtime \
  --std-dir <worktree:union-native-baseline>/standard_library/src \
  -o /tmp/union-native-plumbing-baseline-small.c \
  <worktree:union-native-baseline>/benchmarks/self_compile/small.brp
```

The candidate command changes only compiler/output path. Repeat for frozen
`blorp/test/compiler/pipeline/codegen_audit/should_pass/` inputs:

- `tensor_raw_view_loop.brp`
- `tensor_proven_loop_raw_load.brp`
- `tensor_loop_views_direct.brp`

Candidate focused owners after FRESH build:

```sh
bin/blorp test --timeout 180 blorp/test/compiler/stage_08_core_lower/test_core_list_layout.brp
bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_specialize_layout.brp
bin/blorp test --timeout 180 blorp/test/compiler/pipeline/test_core_c_type_layout.brp
scripts/compiler-check --changed --plan
scripts/compiler-check --changed
```

No performance claim is made. Static review found zero findings. Independent
test-runner acceptance is recorded below; commit remains pending final review.

## Observed baseline

Exact baseline build succeeds and reports FRESH. Checkout remains clean.
Build stamp: commit `66944f3e97af`, dirty false, bootstrap
`dev-d44472d3a5d0`, CLI/runtime O2, 8-way split, Apple clang 21.0.0,
`aarch64-apple-darwin`, memory diagnostics 0.
Binary SHA-256: `a53a0b858c39b8e7a97b6e40095d67017ac5bab5caa38fdfe90be5c370edd9d2`.
Bootstrap manifest SHA-256:
`ff3744a93cc221bf8279b4c291b433e476f49e55b83d56849da178845d4bba88`.
Build log: `/tmp/union-native-plumbing-baseline-build.log`.

All four baseline compile commands succeed, using the absolute baseline Stdlib
and source paths specified above.

| Frozen input | Input SHA-256 | Baseline C SHA-256 |
| --- | --- | --- |
| `small.brp` | `6a67158fb09aac383ec40e77e5c5b1d64fd068b19edf6e2596a6f25060d9cc93` | `3f4e7cf0fbabc5459ba7802a4fc5cb69a20d0699e4c19991f19dcf374cce4abe` |
| `tensor_raw_view_loop.brp` | `25f65369007ab34d3abeebc78570e7b8196f98163f73cbb88607ef96774ca9b7` | `b39dfedd3bfe04f9cc3b08766daaf1738f53ccecb4469d6fecc4d10e15b182c4` |
| `tensor_proven_loop_raw_load.brp` | `f0ad9e6a823f5f0dbe5670edc1c1dc3ca7d301ab322e7912094f1f2702567ccc` | `41aef8a70c83bec50cc3cf6e108b6a115d38f864a48ccf89352970ac176cd3d7` |
| `tensor_loop_views_direct.brp` | `63f5cad188092da1579245400fe8ba608955f41f21b32d279482ab7576b02788` | `3b7ef7e5325f1e25d4c96207e6517c0f63e6ceb123b65ca989346c928e31657e` |

Raw C and compiler logs use `/tmp/union-native-plumbing-baseline-` prefixes and
the sample suffixes `small`, `tensor-raw-view`, `tensor-proven-load`, and
`tensor-loop-views` (extensions `.c` and `.log`).

## Observed candidate identity

Candidate build succeeds and reports FRESH. Build stamp is
`66944f3e97af-dirty`; bootstrap, O2 levels, split, Clang, target, and diagnostic
mode match baseline. Binary SHA-256:
`bafb65de6d9d1cfbcc85f55081a6927a427feb0055f365307e46b98019d047df`.
Build log: `/tmp/union-native-plumbing-candidate-build.log`.
All three reviewed production source hashes remain unchanged.

The candidate compiles the four exact baseline-owned absolute input paths with
the same baseline Stdlib path. All commands succeed; complete `cmp` comparisons
pass, and candidate C hashes equal every baseline C hash above.
Candidate artifacts use the matching `/tmp/union-native-plumbing-candidate-`
prefix, sample suffix, and `.c`/`.log` extensions.

Read-only routing selects `test_core_list_layout.brp`, `test_core_lower.brp`,
`test_core_prepare.brp`, and `compiler-core-sanitize`. The actual selected gate
command preserves the built O2 configuration:

```sh
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --changed > /tmp/union-native-plumbing-selected-gates.log 2>&1
```

This selected command passes: 2,627 tests, zero failures, including the three
focused owners and Core ASan/UBSan checks. Focused owner counts are 20 for list
layout, 150 for Core lowering, and 57 for Core preparation (227 total).
The top-level PASS result remains in the log above. The routing script deletes
its detailed successful suite/sanitizer log directory; those files were inspected
during execution but are no longer retained. Do not cite their former paths as
recoverable artifacts. Sanitizer counts are included in the selected total.

The extra focused command also passes:

```sh
bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_specialize_layout.brp blorp/test/compiler/pipeline/test_core_c_type_layout.brp > /tmp/union-native-plumbing-extra-owners.log 2>&1
```

Its retained log reports 10 specialization-layout tests and 17 C-type-layout
tests, zero failures. These counts overlap sanitizer coverage and are not added
to the selected total. Candidate build status remains FRESH after all gates.

## Independent preparation acceptance

The independent test-runner accepts this preparation: focused owners pass
227/227, extra layout owners pass 27/27, and Core ASan/UBSan passes 2,400/2,400.
All four complete generated-C comparisons use the same frozen absolute inputs
and Stdlib paths and pass; their hashes match the author results above.

Evidence is retained under `/tmp/union-native-projection-independent.TND2tE`.
All 14 command/provenance packets record exit code 0 and
`source_changed_during_run=false`. The baseline and candidate provenance packets
confirm the frozen build/source facts above. Owner logs are `owners/stdout.log`
and `extra/stdout.log`; detailed sanitizer evidence is retained at
`sanitize-logs/compiler-core-sanitize.log`. The identity packet is
`identity/metadata.json`, alongside the four baseline/candidate C pairs.

These counts overlap and are not a distinct-test total. This acceptance covers
only the tensor projection preparation, not broad gates, stage 2/fixpoint,
performance, or canonical native authority.

Pending future-native source setup is separately checked with `bin/blorp check
--no-format benchmarks/fixtures/union_native_authority/canonical_native_tags.brp`
and two `run --release --leak-check --no-format` invocations, without arguments
and with `-- ipv6`. All succeed. The native typed C parameter probe controls pass;
observed leak totals are respectively 3 allocations/3 releases and 4/4, both
zero leaked. Logs use `/tmp/union-native-authority-probe-` prefixes:
`legality.log`, `control-default.log`, and `control-ipv6.log`. These are setup
and existing-enum controls only, not canonical native authority implementation,
reordered native mapping proof, or future managed-union foreign admission.
