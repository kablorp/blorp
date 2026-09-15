# Zero-Copy Callable Symbol Emission

Issue 136 replaced the projected-Core copy with an immutable symbol plan. The
baseline is revision `bdce2c5a9c8161c00e17ef30a8933d3c467d1a59`; the
candidate was measured from the Issue 136 working tree after a fresh `make`.
The baseline and candidate compiler SHA-256 values were respectively
`0fd3b6538707f355ab58b1ba2ea04eca31373d51578cdefb621637c557f5bb21`
and `d0bf6093c1cf27dae5f24b0b321e72ac42922ef7b5ad18149ec396132f412c19`.

## Direct mechanism result

The retained profile was run for three iterations. Observation of the final
plan happens after the measured window; both builds produced the same
definition/call counts and checksum. The baseline rebuilt-node values are
observed counters. The candidate zeros are schema-compatible structural values:
`CEmissionSymbolPlan` cannot own a `CoreProgram`, declaration, or expression,
so there is no projected Core value to count.

| Calls workload | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Rebuilt Core expressions | 37,632 | 0 | -100% |
| Rebuilt declarations | 768 | 0 | -100% |
| Managed allocations | 144,541 | 37,009 | -74.4% |
| Managed releases | 114,838 | 36,490 | -68.2% |
| Retained objects | 29,703 | 519 | -98.3% |
| Allocated bytes | 1,919,472 | 33,344 | -98.3% |
| Window | 51,277 us | 24,197 us | -52.8% |
| Symbol checksum | `6834344076934152102` | same | identical |

The deep workload also reported the candidate's structural zero for rebuilt
expressions/declarations. Managed allocations fell from 4,012 to 1,648,
retained objects from 523 to 9, allocated bytes from 49,984 to 704, and the
measured window from 1,160 us to 792 us. The closure, wide, error-early, and
error-late modes all reported `workload_valid=True` and the same structural
zero.

Commands:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_c_symbol_projection_profile calls 3 256 96 16
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_c_symbol_projection_profile deep 3 256 96 1
```

## Deterministic backend replay

The checked-in generator produced a 2,533,172-byte request with SHA-256
`d3c69458d4b1feda5d285e1d0a49f33d54ffbe1185fc49c8c946cc24637e5be5`.
All six executions in the alternating order baseline/candidate,
candidate/baseline, baseline/candidate produced 139,742 C bytes and response
SHA-256 `9f2b7513b50273bc4dfaaad4f1a5616b2f0e7dd851c12b9216ef1ce11dd8e9f8`.
The [raw replay rows](compiler_c_symbol_zero_copy_backend_2026-09-15.json)
retain execution order, worker hashes, elapsed time, RSS, and verification
status.

| Replay metric | Baseline median | Candidate median | Result |
| --- | ---: | ---: | --- |
| Elapsed | 0.622884 s | 0.632404 s | +1.5%; within the regression guard |
| Peak RSS | 66,306,048 | 65,929,216 | -0.57% |
| Retired instructions | 5,834,766,722 | 5,827,565,536 | -0.12% |
| `/usr/bin/time` wall time | 0.36 s | 0.36 s | neutral |
| Backend worker binary | 14,756,408 B | 14,756,408 B | identical size |

The separate macOS `vmmap` sample was not mixed into the ordinary RSS rows.
It observed physical footprint falling from 53,896,806 to 52,114,227 bytes
(-3.3%), `MALLOC_SMALL` virtual size falling from 58,720,256 to 54,525,952
bytes (-7.1%), and allocation count falling from 615,519 to 592,573 (-3.7%).
A single sample is directional rather than statistical evidence; the
deterministic managed allocation and retained-object counters above are the
primary memory evidence. The first candidate replay was a cold outlier; the
alternating-pair median remained inside the 5% regression threshold.

## Production-route parity

The production fixture ran as three alternating pairs. Raw benchmark output is
retained in
[`compiler_c_symbol_zero_copy_2026-09-15.json`](compiler_c_symbol_zero_copy_2026-09-15.json).

- Generated C: 15,284 bytes and SHA-256
  `ca245b831db5ce8ff07f2731ce078395b5e56f024fb65b59ff29d80a54eaf607`
  for both builds.
- `-O0` object: 10,984 bytes and SHA-256
  `6143a25bde2242a1e4d3d86d527a30714003a8c38aa7b9ffaf0779b9eadd7d4c`
  for both builds.
- `-O2` object: 6,336 bytes and SHA-256
  `edf008ae3241005d14ce9e0940512dda7e3fe09ada5659c081f02240d9a19a3a`
  for both builds.
- Runtime output remained `C_SYMBOL_HASH_CHECKSUM=243`.
- The compiler executable decreased from 19,721,696 to 19,705,728 bytes
  (-0.08%); the isolated backend worker size was unchanged.
- Compile-to-C median changed from 0.445427 s to 0.409551 s (-8.1%); peak
  process RSS changed from 49,086,464 to 49,184,768 bytes (+0.2%). With only
  three pairs, these host-level results are guards rather than strong claims.

## Validation

- `scripts/compiler-check --changed`: 2 sources, 4 suites, Core sanitizer,
  and generated-C audit passed.
- `scripts/test --no-build compiler-blorp`: 4,642/4,642 passed.
- Backend-memory harness: 12/12 passed.
- Focused symbol projection/emission: 38/38 passed.
- `git diff --check`: passed.

The change is accepted: the reconstruction mechanism is gone, deterministic
memory work drops substantially, artifact and runtime outputs are identical,
and host instruction/latency guards show no material regression.
