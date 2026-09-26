# Table-owned qualified implementation candidates

Date: 2026-09-26

Baseline revision and frozen input:
`cca15ac4a76af5b25aaecb18b519a987f888c242`. Both compilers were fresh
Apple clang 21 `-O2` builds made by `dev-555b6c75473e`.

## Change

The accepted trait/implementation table now publishes the qualified method
candidate index once. Each prepared module authority stores a dense one-based
visibility rank for each implementation (`0` means not visible) instead of
rebuilding nested module-path and method-name dictionaries.

Qualified lookup reads the shared candidate list and selects the matching
implementation with the lowest module-specific visibility rank. This keeps the
existing direct-import precedence explicit; a regression reverses the direct
order of a base-trait and subtrait implementation and verifies that the chosen
callable changes with it.

The former per-implementation qualified-row lists were only retained for a
metric after publication moved to the table. They were removed and replaced by
one scalar row count, so the table does not keep both source rows and its final
index.

## Attribution

One serial frontend-only self-compile with opt-in phase metrics:

| Row | Baseline | Candidate | Delta |
| --- | ---: | ---: | ---: |
| `prepare_impls` | 29,117 | 29,848 | +731 |
| `prepare_environments` | 830,645 | 532,523 | -298,122 (-35.89%) |
| `global_header_completion` | 4,688,783 | 4,391,393 | -297,390 (-6.34%) |
| `graph_completion` | 4,827,926 | 4,530,536 | -297,390 (-6.16%) |
| `module_bodies` | 21,586,316 | 21,586,316 | 0 |

The small table-construction increase is paid once. The former qualified index
was rebuilt in every prepared module, accounting for the larger final-projection
reduction. No allocations moved into body checking.

## Matched measurements

`benchmarks/self_compile_measure` ran three serial samples against the same
frozen input with `--require-identical`. Retired instructions are the minimum
sample; wall time is intentionally omitted.

| Workload and metric | Baseline | Candidate | Delta |
| --- | ---: | ---: | ---: |
| Self typed-frontend allocations | 30,633,167 | 30,335,777 | -297,390 (-0.97%) |
| Self total allocations | 205,672,552 | 205,375,162 | -297,390 (-0.14%) |
| Self retired instructions | 158,238,371,450 | 157,315,702,439 | -922,669,011 (-0.58%) |
| Self peak RSS bytes | 2,155,151,360 | 2,142,191,616 | -12,959,744 (-0.60%) |
| Small typed-frontend allocations | 812,521 | 788,776 | -23,745 (-2.92%) |
| Small total allocations | 1,497,269 | 1,473,524 | -23,745 (-1.59%) |
| Small retired instructions | 1,231,113,741 | 1,163,981,064 | -67,132,677 (-5.45%) |
| Small peak RSS bytes | 35,602,432 | 35,504,128 | -98,304 (-0.28%) |

Generated C was byte-identical:

- self compile: 83,784,415 bytes, SHA-256
  `e4dce9716adf3928dcad1b663078a31f5c72adbd7d4f112e8e515833036eb3b8`
- small program: 42,475 bytes, SHA-256
  `b14e002cf83bd89ace4c862a0cf0137f36b21cde683a993671641f0c2e3b096a`

Raw results:

- `/tmp/prepared-module-baseline.json`
- `/tmp/prepared-module-candidate.json`
- `/tmp/prepared-module-baseline-small.json`
- `/tmp/prepared-module-candidate-small.json`

## Validation

- The changed-source owner gate passed 540/540 across seven suites and the
  declaration-boundary check.
- The direct-import-order suite passed 168/168 independently.
- The release `compiler-blorp` gate passed 5,135/5,135.
- Independent review found no correctness or visibility issue. It confirmed
  that conflict filtering precedes rank publication and that minimum-rank
  selection reproduces the former first-visible-match behavior.

## Recommendation

Accept. The table owns canonical candidate facts, module projections own only
visibility and precedence, body allocations are unchanged, and both measured
workloads reduce allocations and retired instructions.
