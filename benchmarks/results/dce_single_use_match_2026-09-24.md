# Single-use DCE match subject

Date: 2026-09-24

## Change and decision

`add_variable_reference` formerly matched `(facts.mode, typ, variable.def_id)`.
The tuple was used once, but generated C allocated both the tuple and a boxed
`Option[Int]` for every call. Matching those three values separately preserves
the branch decision and leaves `def_id` as a stack `blorp_StackOption_Int`.
This is a narrow source-level improvement, not a general match fusion pass.

Accept the single-function rewrite: the matched self-compile comparison removed
2,841,676 allocations (1.238%) with byte-identical emitted C. That is exactly
two allocations per 1,420,838 calls counted at this site in the preceding
generated-C allocation probe. The focused DCE tests and compiler gates provide
the behavior checks; no runtime-program performance claim follows from this
compiler-process measurement.

## Matched measurement boundary

- Clean control: `2380615c9c099a629fe88a0aff36681056fef04e`.
- Candidate: the same revision plus only the DCE source rewrite. The later
  focused test and explanatory comment do not affect the measured code path.
- Both stage-2 compilers were built from fresh O2 stage-1 builds with the same
  `dev-517834b01e21` bootstrap pin, Apple clang 21.0.0, and CLI/runtime O2.
- Frozen self-compile input: `d5fe8d9d8288165e6dbe55868c11e060d62b6db4`,
  using the exact canonical `/private/var/.../blorp-perf-input/<revision>` path
  recorded in the retained JSON. The path spelling matters to generated names.
- Stage-2 executable SHA-256: control
  `a0107b60ed929c4e770efe6876bbea7a30941ff6d4ab181040285d96fbc5be42`,
  candidate `a6c39d59034a9e3e5cc5c6803de1b2a1dac36bc46283eecfd8ec6fcf6a16c710`.
- Harness: `benchmarks/self_compile_measure` with `--compiler` selecting each
  stage-2 binary, `--skip-build-check`, the same `--input-dir`, two samples,
  and `--require-identical` against the previous retained C baseline.
  Because the binaries were passed explicitly, the JSON `compiler_stage`
  field says `1`; their `self-2380615c9c09` version and stage-2 build logs
  establish the actual stage-2 provenance.

| Metric | Control | Candidate | Delta |
| --- | ---: | ---: | ---: |
| Total allocations | 229,573,873 | 226,732,197 | -2,841,676 (-1.238%) |
| Source discovery allocations | 8,414,273 | 8,414,273 | 0 |
| Early prune allocations | 247,889 | 196,981 | -50,908 |
| Post-trait prune allocations | 3,146,477 | 2,287,127 | -859,350 |
| DCE allocations | 3,483,210 | 2,520,880 | -962,330 |
| Perceus allocations | 52,464,239 | 51,495,151 | -969,088 |

Both runs emitted 83,803,990 bytes of C with SHA-256
`7c71460be979095ec4144397ad247bc462a6cc3a59e170dc90606a59ebf8dd4d`.
The stage-2 compiler's *own* generated C changed, as intended; the C emitted
by the compiler while compiling the frozen program did not.

Retired-instruction samples were control `179,558,401,719` and
`179,607,386,909`, candidate `178,634,210,145` and `178,689,145,701`.
They suggest a reduction, but the runs were not alternated, so this report
does not claim a confirmed instruction or latency improvement.

The raw local records are `/tmp/dce-tuple-match-control.json` and
`/tmp/dce-tuple-match-probe.json`. Those temporary paths are not durable;
the figures and hashes above preserve the comparison. The site-call count
comes from the separate temporary generated-C instrumentation, not these
JSON records. The earlier C1 baseline used a different bootstrap pin and was
not used to attribute the allocation reduction.
