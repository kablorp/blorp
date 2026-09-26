# Precomputed trait-implementation lookup facts

Date: 2026-09-25

Baseline revision and frozen input: `6cbacd58cd47c31fddd26567338378b32ad48dcd`.
Candidate: the dirty worktree at the same revision. Both compilers were built
with `BLORP_CLI_C_OPTIMIZATION=-O2`; `bin/blorp --version` reported Apple clang
21.0.0 and bootstrap `dev-048a5864cd98`.

## Hypothesis

`accepted_trait_implementation_authority` builds a filtered view for every
module. Each view used to rediscover facts which depend only on the accepted
implementation table:

- the implementation and trait owner module paths for each method,
- the accepted trait method name, and
- the compiler-trait link for each implementation.

Publishing these facts once in `AcceptedTraitImplementationTableRep` should
remove repeated header-completion allocations without moving the work into
body inference. The module authority should retain only its visibility filter
and module-specific indexes.

## Change

The accepted table now publishes qualified method rows and compiler-trait links
by implementation index. Per-module authority construction reads those rows
instead of repeating definition, module, method, and compiler-link lookups.
Metrics expose the number of published rows and links. A focused regression
test first failed because the metrics fields did not exist, then passed after
the table construction was implemented.

## Fast attribution loop

The frontend-only run used the frozen self-compile input and stopped after
lowering:

```bash
BLORP_TYPECHECK_BODY_METRICS=1 BLORP_COMPILER_MEMORY_PROFILE=1 \
  bin/blorp compile --stop-after=lower --no-format \
  --std-dir "$input/standard_library/src" \
  "$input/blorp/src/main.brp" >/dev/null 2>/tmp/typecheck-trait-precompute-final.stderr
```

Allocation counts are deterministic. The relevant rows were:

| Row | Baseline | Candidate | Delta |
| --- | ---: | ---: | ---: |
| `global_header_completion` | 5,223,836 | 4,837,901 | -385,935 (-7.39%) |
| `graph_completion` | 5,362,969 | 4,977,034 | -385,935 (-7.20%) |
| `module_bodies` | 21,595,562 | 21,595,562 | 0 |

The unchanged body row is the boundary check: the removed preparation work was
not deferred to inference.

## Matched benchmark

Both programs used three serial samples through
`benchmarks/self_compile_measure`, the same frozen input, and
`--require-identical`. Retired instructions are the minimum sample. Wall time
is intentionally not used as acceptance evidence.

| Workload and metric | Baseline | Candidate | Delta |
| --- | ---: | ---: | ---: |
| self compile typed-frontend allocations | 31,185,865 | 30,799,930 | -385,935 (-1.24%) |
| self compile total allocations | 210,848,103 | 210,462,168 | -385,935 (-0.18%) |
| self compile retired instructions | 169,369,801,109 | 168,925,069,759 | -444,731,350 (-0.26%) |
| self compile peak RSS bytes | 2,137,178,112 | 2,131,247,104 | -5,931,008 (-0.28%) |
| small program typed-frontend allocations | 849,047 | 819,802 | -29,245 (-3.44%) |
| small program total allocations | 1,546,265 | 1,517,020 | -29,245 (-1.89%) |
| small program retired instructions | 1,291,850,676 | 1,272,069,398 | -19,781,278 (-1.53%) |
| small program peak RSS bytes | 35,651,584 | 35,897,344 | +245,760 (+0.69%) |

The small-program RSS difference is one noisy process-level observation and is
not treated as a regression or improvement. All three final self-compile
instruction samples (`169,161,252,078`, `169,001,607,553`, and
`168,925,069,759`) were below all three baseline samples
(`169,483,696,328`, `169,419,102,916`, and `169,369,801,109`).

Generated C was byte-identical:

- self compile: 83,572,173 bytes,
  SHA-256 `d8e32024643afe21bf7607bda49e585977df5b1de098fa7bda1d8f26afb6aa8e`
- small program: 42,475 bytes,
  SHA-256 `b14e002cf83bd89ace4c862a0cf0137f36b21cde683a993671641f0c2e3b096a`

Raw result files for this run:

- `/tmp/trait-authority-base.json` (SHA-256
  `98d3373a2d481f2aecc6ad0fc6d2be072afd6b7d2b8a1621be08cd283e6712d3`)
- `/tmp/trait-authority-candidate-final.json` (SHA-256
  `6570189dee394794bfca26ed4211b9f0cc851cac30284c4bd79412cf362de73c`)
- `/tmp/trait-authority-base-small.json` (SHA-256
  `83c3c17e324cb1fa5dd63a06da61d114c1db0c4cc32231f1c4f2093796f815a3`)
- `/tmp/trait-authority-candidate-small-final.json` (SHA-256
  `5670d05304c7e4913b35c15c84d68eacfbb737cd1ab8919b4fb2f747e92b2b08`)

## Validation

The final focused regression passed 167/167 tests and directly checks both
the published row count and the qualified-method lookup which consumes the
new row. `scripts/compiler-check --changed --base 6cbacd58` passed 539/539
across seven selected suites plus the declaration-boundary check. The serial
`compiler-blorp` gate passed 5,119/5,119 with a FRESH `-O2` compiler. An
independent read-only review found no semantic, ordering, visibility, table
alignment, or ownership defect.

## Recommendation

Accept this bounded cut. It removes repeated stable-fact reconstruction,
improves allocations and retired instructions on both retained workloads,
keeps body-check allocation work flat, and preserves generated output. It does
not complete the broader typecheck tables roadmap; it establishes the useful
boundary for further independently measured cuts.
