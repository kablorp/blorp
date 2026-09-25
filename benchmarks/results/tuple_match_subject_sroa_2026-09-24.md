# Constructor-match tuple scalar replacement (2026-09-24)

The candidate extends `tuple_sroa` to remove a direct tuple match
subject when the semantic match is a chain of constructor tests on distinct
tuple fields. Borrowed payload bindings are attached to the constructor case
that proves them. Unsupported trees, including a whole-tuple fallback binding,
remain unchanged. This is not a general inline-tuple representation change.

## Matched self-compile

- Base: `f2212bc1897cf23506418b27c03c9abf0112f323`.
- Frozen input: `d5fe8d9d8288165e6dbe55868c11e060d62b6db4`, same canonical
  `/private/var/.../blorp-perf-input/<revision>` path on both runs.
- Apple Clang 21, arm64 macOS, stage-2 compilers built with CLI and runtime
  `-O2`. Baseline binary SHA-256:
  `23651935fee41064f7710ebb379fce59b1457fb50446a8b0af605468fca46065`;
  candidate binary SHA-256:
  `565ecdd89f038978323a71b23cd0d20e9d0859d1160c680f6f8894d6591f27f9`.
- In each worktree, run `env BLORP_CLI_C_OPTIMIZATION=-O2 make`, then
  `env BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/build_stage2_compiler <binary>`.
  The binaries were `/tmp/blorp-tuple-match-control-stage2` and
  `/tmp/blorp-tuple-match-stage2`, built in the clean control and candidate
  worktrees respectively. Both reported `compiled_by: self-f2212bc1897c`
  and `optimization: cli=-O2 runtime=-O2` in `--version`.
- Both compilers finished at C emission; the emitted C was not compiled for
  the measurement. Baseline and candidate output C hashes differ by design:
  `7c71460be979095ec4144397ad247bc462a6cc3a59e170dc90606a59ebf8dd4d`
  versus `8dc0a84986a3163f81bee9e3f92b871cd4398fb9f9ac76f8f2abbb714002b21a`.

| Compiler-process metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocator calls | 221,139,560 | 214,841,257 | -6,298,303 (-2.85%) |
| Retired instructions, median of 3 | 177,060,987,903 | 174,881,569,173 | -2,179,418,730 (-1.23%) |
| Retired instructions, minimum of 3 | 176,798,654,761 | 174,838,300,892 | -1,960,353,869 (-1.11%) |
| Emitted C bytes | 83,803,990 | 83,901,903 | +97,913 (+0.12%) |

The frozen compiler's emitted C has 2,515 versus 2,297 static
`blorp_tuple_new` call sites and 272 versus 203 `blorp_box_struct` call sites.
These are static call-site counts, not dynamic allocation counts. On the
small two-Option fixture, the target function changes from one tuple and two
struct-box calls to zero of each; its distinct payloads and managed-String
variant both pass at runtime. A three-outcome fixture verifies inner versus
outer fallback priority. The broader self-compile allocation difference is
observed, not estimated from those call-site counts.

Raw local outputs:
`/tmp/blorp-tuple-match-control-instructions.json`,
`/tmp/blorp-tuple-match-candidate-instructions.json`,
`/tmp/blorp-tuple-match-control-self.c`, and
`/tmp/blorp-tuple-match-candidate-self.c`.
The `self_compile_measure` JSON reports `compiler_stage: 1` for a custom
`--compiler` path; the stage-2 build commands and nested binary version
information establish the actual stage.

## Correctness gates

- `scripts/compiler-check --changed --base main`: 2,139/2,139, including
  Core sanitizer selection.
- Focused Core tuple SROA 30/30, Core mono Option 6/6, runtime match fixture
  4/4, and the fixture's leak check 4/4 with zero leaked objects.
- `scripts/test --no-build --serial compiler-blorp`: 5,079/5,079.
- Generated-C audit: 221/221. The optimized fallback-priority function's C
  contains no tuple allocation and retains distinct 100/200 fallback arms.
- Independent review found no correctness defect in binding scope, evaluation
  order, fallback placement, or fail-closed handling.

Instruction samples were sequential, but other host work may still have
affected wall time; no latency claim is made. The optimized tree shape is
intentionally narrow, so these numbers do not estimate the benefit of
scalarizing all tuple matches.
