# Selective typed closure environments: current-base outcome

Date: 2026-09-24

## Decision and scope

Accept the selective ordinary-closure typed environment optimization as a
targeted allocation cut. It stores eligible by-value struct captures inline in
the closure allocation. Closure/task ABI and task capture representation are
unchanged. This report does **not** claim a self-compile speedup or a latency
improvement.

The focused `struct_payload_closure_capture.brp` oracle moved from 2,048 to
1,024 allocations with identical checksum `1,052,672` and zero live objects.
For self-compilation, total allocations fell by 89,125 (0.0388%), while median
retired instructions rose by only 21,524 (effectively flat at this scale).
Generated self-compile C grew by 2,731 bytes. The evidence supports the focused
allocation result, not a broader speed claim.

## Exact comparison boundary

- Base: `b72b0c7c009f12f16cf41c558e5e6c4500338011`.
- Candidate: `f9a47fdcd365bb48f50fb58df9163cac941d2c6e`, comprising production
  commit `41592efda88e2f83ae0994fe638b0b6d1ca4910c` and test/coverage commit
  `f9a47fdcd365bb48f50fb58df9163cac941d2c6e`.
- Frozen input: revision `d5fe8d9d8288165e6dbe55868c11e060d62b6db4`, at
  `/var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/blorp-perf-input/d5fe8d9d8288165e6dbe55868c11e060d62b6db4`.
- Host/toolchain: arm64 macOS, Apple clang 21.0.0
  (`clang-2100.3.34.2`); stage-1 and stage-2 compilers used CLI/runtime O2,
  split count 8.
- Each revision had a fresh O2 stage-1 build followed by one immutable
  stage-2 binary. The stage-1 builds used
  `BLORP_CLI_C_OPTIMIZATION=-O2 BLORP_CLI_C_SPLIT_JOBS=2 make`, and build
  status was FRESH before stage-2 construction.

Stage-2 construction used `benchmarks/build_stage2_compiler` in each checkout,
with output paths `/tmp/blorp-s3-main-b72-f9a47fdc/baseline-stage2` and
`/tmp/blorp-s3-main-b72-f9a47fdc/candidate-stage2` respectively. Their
recorded versions and full executable hashes are below.

| Revision | Stage-1 executable SHA-256 | Stage-2 executable SHA-256 | Stage-2 version / built by |
| --- | --- | --- | --- |
| Base `b72b0c7c` | `bea8f06f920e59948b8e8b516914fed88fbffec400fbe2d3f994745d52b8bcf9` | `3de8fb7634026268b25afc7da7269aa9d11ae75f7d2acc518863c09da92f463f` | `b72b0c7c009f` / `self-b72b0c7c009f` |
| Candidate `f9a47fdc` | `00712ee8b16c634d268c69a1284dd14868bac039be36fa07c310cb0e4db8bac8` | `b04124d94bd16b28d5428843fd2edf3d0b0f1bd1a3e7e397dc9f067d072738d1` | `f9a47fdcd365` / `self-41592efda88e` |

Both stage-2 `--version` outputs confirmed `cli=-O2 runtime=-O2`. Stage-2
construction generated 77,983,203 bytes of C for the base
(`865724a691b940931f477dc91cbf29db127f1e08f46558fc3fe87c2bf50d0199`) and
78,064,067 bytes for the candidate
(`e0f1bd54173cdef54f6cc378a24833ebd720e3e0e5ea8d8d9440200695239c03`).

## Stage-2 self-compile samples

Each invocation used `benchmarks/self_compile_measure measure --compiler
<immutable-stage2> --skip-build-check --input-dir <frozen-input> --program
self --samples 1`, with a unique label, JSON path, and kept-C path. The order
was B1, C1, B2, C2, B3, C3. Before, during, and after each sample, process
checks found no competing compiler/self-compile job. Before C1, a process check
found an unrelated compiler test in progress; it was allowed to finish before
C1 began. The sequence was preserved after that pause. Retired-instruction
samples varied, particularly candidate C3; generated-C hashes and allocation
counts were stable within each revision.

For example, B1 used:

```sh
env BLORP_CLI_C_OPTIMIZATION=-O2 \
  benchmarks/self_compile_measure measure \
  --compiler /tmp/blorp-s3-main-b72-f9a47fdc/baseline-stage2 \
  --skip-build-check \
  --input-dir /var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/blorp-perf-input/d5fe8d9d8288165e6dbe55868c11e060d62b6db4 \
  --program self --samples 1 --label s3-b72-B1 \
  --output /tmp/blorp-s3-main-b72-f9a47fdc/B1.json \
  --keep-output /tmp/blorp-s3-main-b72-f9a47fdc/B1.c
```

The other samples used the same command shape with the matching baseline or
candidate compiler, labels `s3-b72-B2`, `s3-b72-B3`, `s3-f9a47fdc-C1`,
`s3-f9a47fdc-C2`, `s3-f9a47fdc-C3`, and corresponding JSON/C paths.

| Sample | Revision | Allocations | Retired instructions | Emitted C bytes |
| --- | --- | ---: | ---: | ---: |
| B1 | Base | 229,698,258 | 179,426,638,369 | 83,801,259 |
| C1 | Candidate | 229,609,133 | 179,323,485,745 | 83,803,990 |
| B2 | Base | 229,698,258 | 179,323,464,221 | 83,801,259 |
| C2 | Candidate | 229,609,133 | 179,315,909,715 | 83,803,990 |
| B3 | Base | 229,698,258 | 179,298,166,771 | 83,801,259 |
| C3 | Candidate | 229,609,133 | 179,487,255,633 | 83,803,990 |

The base's generated C was stable at SHA-256
`f76bf324f5952cde83a67fb999155f772e0e2ebe1e7b96a7d6aea5f5b00551ef`; the
candidate's was stable at
`7c71460be979095ec4144397ad247bc462a6cc3a59e170dc90606a59ebf8dd4d`. The
cross-revision C change is expected: the candidate contains typed closure
environment fields and associated emitted operations.

| Metric | Base | Candidate | Delta |
| --- | ---: | ---: | ---: |
| Total allocations | 229,698,258 | 229,609,133 | -89,125 (-0.0388%) |
| `typed_frontend_complete` allocations | 33,944,831 | 33,838,063 | -106,768 |
| `backend_emission_complete` allocations | 19,527,799 | 19,545,443 | +17,644 |
| Other phase allocation rows, net | — | — | -1 |
| Retired instructions, minimum | 179,298,166,771 | 179,315,909,715 | +17,742,944 |
| Retired instructions, median | 179,323,464,221 | 179,323,485,745 | +21,524 |
| Emitted C bytes | 83,801,259 | 83,803,990 | +2,731 (+0.0033%) |

The paired retired-instruction deltas (candidate minus base) were
-103,152,624, -7,554,506, and +189,088,862; their median is -7,554,506.
The median-of-samples comparison is a separate statistic (+21,524). Neither
supports a robust self-compile instruction improvement. Wall time and peak RSS
are omitted from the conclusion; no latency claim is made.

## Focused behavior and gates

Using the same fixture source and frozen standard library with the exact
stage-2 binaries, `run --release --timeout 180` produced:

| Compiler | Allocations | Checksum | Live objects |
| --- | ---: | ---: | ---: |
| Base stage 2 | 2,048 | 1,052,672 | 0 |
| Candidate stage 2 | 1,024 | 1,052,672 | 0 |

The baseline and candidate commands differed only in the compiler executable:

```sh
<stage2-compiler> run --release --timeout 180 \
  --std-dir /var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/blorp-perf-input/d5fe8d9d8288165e6dbe55868c11e060d62b6db4/standard_library/src \
  benchmarks/blorp/struct_payload_closure_capture.brp
```

The candidate also passed the projected Point split-emitter suite (18/18),
CoreEmit (338/338), captured-channel and managed-closure owner-drop runtime
fixtures (1/1 each), leak checks (3 allocations, 3 releases, zero leaked
objects), ASan+UBSan checks (1/1 each), and the generated-C audit (221/221).
The broad serial gate exited 0 with 17,097/17,097 checks:

- compiler-blorp: 5,070/5,070
- compiler-tools: 115/115
- runtime: 4,496/4,496
- leak: 974/974
- compiler-core-sanitize: 2,102/2,102
- compiler-blorp-sanitize: 4,340/4,340

Broad gate logs are in
`/tmp/blorp-s3-current-gates-f9a47fdc/`. The exact focused fixture outputs
are `/tmp/blorp-s3-main-b72-f9a47fdc/baseline-closure.log` and
`/tmp/blorp-s3-main-b72-f9a47fdc/candidate-closure.log`.

## Artifacts and measurement caveat

Build logs and immutable stage-2 executables are in
`/tmp/blorp-s3-main-b72-f9a47fdc/`: `baseline-make-O2.log`,
`baseline-stage2-build.log`, `candidate-stage2-build.log`,
`baseline-stage2`, and `candidate-stage2`.
Each sample's retained JSON, log, and generated C are `B1` through `B3` and
`C1` through `C3` in that directory.

With a reusable binary, the measurement JSON reports `compiler_stage=1`,
`compiler_build_status=skipped`, and no `stage2_built_by_bin_blorp_sha256`;
`compiler_rev` is also `unknown`. These fields describe the skipped build
path, not the binary's actual stage. Stage-2 identity and optimization were
verified from the recorded stage-2 build logs, executable SHA-256 values,
`--version` output, and the exact frozen input recorded in every JSON. The
stage-2 C hashes and binary hashes above provide that provenance.
