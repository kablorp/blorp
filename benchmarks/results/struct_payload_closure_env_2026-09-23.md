# Selective typed closure environments

Date: 2026-09-23

Compiler revision: `d5fe8d9d8288165e6dbe55868c11e060d62b6db4` (dirty worktree).

Toolchain: Apple clang 21.0.0 (`clang-2100.3.34.2`), aarch64-apple-darwin.

## Hypothesis and scope

Ordinary closures that capture a by-value `ClosureAbiStruct` can keep typed
capture fields in an aligned tail of the closure allocation instead of boxing
each struct into an erased pointer slot. The closure header, `blorp_Closure*`
call ABI, and `void* env` field remain unchanged. Typed tails are selected only
for ordinary closures with at least one struct capture; other ordinary
closures and every task closure keep the legacy slot representation.

The generated self-compile C contains 1,091 closure-creation sites: 1,085
legacy sites and 6 typed-tail sites. All 6 typed environments contain a struct
capture (6/1,091 total sites). The number of `blorp_box_struct(` call sites in
the same-boundary C fell from 278 to 272, matching the six eligible captures.
This is a selective optimization; it does not claim a broad closure-layout
change or a generated-C-size win.

## Focused allocation oracle

Fixture: `benchmarks/blorp/struct_payload_closure_capture.brp`. It creates and
indirectly invokes 1,024 closures with distinct pair-struct values, then checks
the checksum and that no managed objects remain. Both runs used `--release`.

| Compiler | Executable SHA-256 | Allocations | Checksum | Live objects |
| --- | --- | ---: | ---: | ---: |
| Exact d5 parent stage 2, O2 | `2e8dae47f697aca6833ade63566145deea9756afbf4ad3f3edf46fd469cb03a2` | 2,048 | 1,052,672 | 0 |
| Selective S3 CLI, O2 | `ec071845d1b0bbd45e04e7a6bc14959a3ae1ef780661aeb0b8ff7dc870527982` | 1,024 | 1,052,672 | 0 |

The parent executable hash matches `compiler_sha256` in the retained parent
stage-2 JSON. The candidate makes one closure allocation per loop iteration;
the oracle preserves behavior and confirms the allocation reduction.

Commands, run serially:

```sh
# From /Users/keithphilpott/.codex/worktrees/struct-payload-s0/blorp
./bin/blorp-stage2 run --release --timeout 180 \
  /Users/keithphilpott/.codex/worktrees/struct-payload-s3/blorp/benchmarks/blorp/struct_payload_closure_capture.brp

# From /Users/keithphilpott/.codex/worktrees/struct-payload-s3/blorp
./bin/blorp run --release --timeout 180 \
  benchmarks/blorp/struct_payload_closure_capture.brp
```

## Self-compile comparison

Both stage-2 measurements used the same frozen input at revision
`d5fe8d9d8288165e6dbe55868c11e060d62b6db4`:
`/private/var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/blorp-perf-input/d5fe8d9d8288165e6dbe55868c11e060d62b6db4`.
Each used `program=self`, three samples, CLI/runtime C optimization `-O2`,
and Apple clang 21.0.0.

Candidate O2 CLI build command:

```sh
BLORP_CLI_C_OPTIMIZATION=-O2 BLORP_CLI_C_SPLIT_JOBS=2 make
```

Parent measurement command (from the S0 worktree, with its exact parent
stage-2 compiler):

```sh
BLORP_CLI_C_OPTIMIZATION=-O2 \
  benchmarks/self_compile_measure --stage2 --program self --samples 3 \
  --input-dir /var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/blorp-perf-input/d5fe8d9d8288165e6dbe55868c11e060d62b6db4 \
  --output /tmp/blorp-struct-payload-parent-stage2-O2.json \
  --keep-output /tmp/blorp-struct-payload-parent-stage2-O2.c
```

Candidate command:

```sh
BLORP_CLI_C_OPTIMIZATION=-O2 BLORP_CLI_C_SPLIT_JOBS=2 \
  benchmarks/self_compile_measure --stage2 --program self --samples 3 \
  --input-dir /var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/blorp-perf-input/d5fe8d9d8288165e6dbe55868c11e060d62b6db4 \
  --baseline /tmp/blorp-struct-payload-parent-stage2-O2.json \
  --output /tmp/blorp-struct-payload-s3-selective-stage2-O2.json \
  --keep-output /tmp/blorp-struct-payload-s3-selective-stage2-O2.c
```

The parent artifact was measured with the same `--stage2 --program self
--samples 3 --input-dir` boundary and `BLORP_CLI_C_OPTIMIZATION=-O2`; its JSON
records the exact parent executable SHA-256 and input revision below.

| Metric | Parent | Selective S3 | Delta |
| --- | ---: | ---: | ---: |
| Total allocations | 235,758,670 | 235,669,526 | -89,144 (-0.04%) |
| `source_discovery_complete` allocations | 8,449,534 | 8,449,533 | -1 |
| `typed_frontend_complete` allocations | 34,738,991 | 34,632,223 | -106,768 (-0.31%) |
| `backend_emission_complete` allocations | 20,304,315 | 20,321,940 | +17,625 (+0.09%) |
| Remaining phase allocation rows | unchanged | unchanged | 0 |
| Retired instructions, minimum | 185,586,923,044 | 184,697,213,287 | -0.48% |
| Retired instructions, median | 185,997,911,859 | 184,762,725,424 | -0.66% |
| Kept C bytes | 164,003,569 | 164,005,392 | +1,823 (+0.0011%) |

The parent compiler SHA-256 is
`2e8dae47f697aca6833ade63566145deea9756afbf4ad3f3edf46fd469cb03a2`; the
candidate stage-2 compiler SHA-256 is
`5ad4737e387eded19fd6d62d9b3d876fcfce1ccd9cc7d81fd11717b256532e41`. The
candidate was built by the O2 CLI compiler with SHA-256
`ec071845d1b0bbd45e04e7a6bc14959a3ae1ef780661aeb0b8ff7dc870527982`.
Parent kept-C SHA-256:
`610fccb41236b5fb08a1645d23858c0eed47fde7dd8144563d51a33bc72341fa`.
Candidate kept-C SHA-256:
`863534753cc301f0f7d93eb0b8398a0ecde69379d6a639de1af8fc464a588523`.

Artifacts:

- Parent: `/tmp/blorp-struct-payload-parent-stage2-O2.json` and
  `/tmp/blorp-struct-payload-parent-stage2-O2.c`.
- Candidate: `/tmp/blorp-struct-payload-s3-selective-stage2-O2.json` and
  `/tmp/blorp-struct-payload-s3-selective-stage2-O2.c`.

Candidate C evidence: it has six typed environment typedefs and six calls to
`blorp_closure_new_typed_inline`; the remaining 1,085 sites use
`blorp_closure_new_inline`. A representative typed environment typedef is at
line 142241, creation at line 295653, and its single destructor definition at
line 1561736 in the candidate kept C. Creation supplies `sizeof(env)` and
`_Alignof(env)` to the inline-tail helper and installs the specialized
destructor.

## Correctness gates and review

- New mixed `Point` + dynamically allocated `String` ordinary-closure runtime
  oracle: normal 1/1, leak-check 1/1 (3 allocations, 3 releases, 0 leaked),
  ASan+UBSan 1/1.
- `scripts/compiler-check --changed`: 363/363 tests; generated-C audit passed.
- `scripts/test --no-build --serial compiler-blorp`: 5,059/5,059.
- `scripts/test --no-build --serial runtime leak compiler-tools compiler-core-sanitize compiler-blorp-sanitize`:
  Runtime 4,496/4,496; Leak 968/968; Compiler-Tools 115/115;
  Compiler-Core-ASan 2,095/2,095; Compiler-Blorp-ASan 4,329/4,329;
  total 12,003/12,003.
- S1's independent review found no production defect; its P2 request for a
  runtime owner-drop oracle is covered by the mixed-capture fixture above.

Runtime fixture commands:

```sh
bin/blorp test --timeout 180 blorp/test/runtime/memory/test_closure_struct_managed_capture_release.brp
bin/blorp test --timeout 180 --leak-check blorp/test/runtime/memory/test_closure_struct_managed_capture_release.brp
bin/blorp test --timeout 180 --sanitize blorp/test/runtime/memory/test_closure_struct_managed_capture_release.brp
```

The final `git diff --check` passed. `scripts/compiler-build-status` reported
`FRESH` before the final documentation-only change.

## Caveats and recommendation

`self_compile_measure lock` is currently a no-op. An unrelated O0 clang/build
and another full-gates process overlapped the candidate measurement. Wall time
and peak RSS are therefore excluded from conclusions; the deterministic
allocation counts, generated-C counts, checksums, and retired-instruction
samples are retained with this host-contention caveat.

Recommendation: accept the selective S3 cut provisionally. The isolated target
shows the intended 2N-to-N capture-allocation change with identical behavior;
self-compile allocations and retired instructions also improve modestly, while
generated-C size is effectively flat. Keep the eligibility restriction and
legacy task path. Final source review and `make hygiene-check` remain before
commit.
