# Imported header scope transitions

Date: 2026-09-25

Baseline revision and frozen input:
`7a4098204aecccaf92b1441de450ebcc49d12895`. The exact baseline adds only
the seven opt-in preparation attribution probes retained by the candidate.
Both compilers were FRESH Apple clang 21 `-O2` builds made by
`dev-6cbacd58cd47`.

## Attribution

`prepared_module_environments` now reports its seven sequential sections under
`BLORP_TYPECHECK_BODY_METRICS=1`. The first frontend-only self-compile split the
remaining preparation work as follows:

| Section | Allocations |
| --- | ---: |
| `prepare_products` | 21,356 |
| `prepare_bases` | 1,530,864 |
| `prepare_traits` | 1,377 |
| `prepare_trait_authority` | 137,096 |
| `prepare_callables` | 772,996 |
| `prepare_impls` | 29,117 |
| `prepare_environments` | 830,540 |

Temporary nested probes narrowed `prepare_bases` to 511,114 allocations in
import-module installation. Across 27,085 compatible import edges, entering and
then restoring the imported session scope accounted for exactly 108,340
allocations. The header section already owns the exact imported
`PreparedModuleScope` used for shape resolution. The installer otherwise reads
the importing session's `module_view`; it does not need the session's
`module_scope` changed.

## Change

Compatible imported sections are installed directly while the typecheck state
remains in the importing module's scope. Incompatible scopes still take the
existing diagnostic path before installation. A source-boundary regression was
written first and failed while the redundant enter/restore calls remained.

The retained seven-row attribution after the change shows the cost at the
expected boundary:

| Row | Baseline | Candidate | Delta |
| --- | ---: | ---: | ---: |
| `prepare_bases` | 1,530,864 | 1,422,524 | -108,340 (-7.08%) |
| `global_header_completion` | 4,796,978 | 4,688,638 | -108,340 (-2.26%) |
| `graph_completion` | 4,936,165 | 4,827,825 | -108,340 (-2.19%) |
| `module_bodies` | 21,602,156 | 21,602,156 | 0 |

## Matched measurements

The harness used three serial samples, the same frozen input, and
`--require-identical`. Retired instructions are the minimum sample. Wall time
is not acceptance evidence.

| Workload and metric | Baseline | Candidate | Delta |
| --- | ---: | ---: | ---: |
| Self typed-frontend allocations | 30,765,931 | 30,657,591 | -108,340 (-0.35%) |
| Self total allocations | 210,466,712 | 210,383,250 | -83,462 (-0.04%) |
| Self minimum retired instructions | 169,059,663,505 | 169,067,681,628 | +8,018,123 (+0.005%) |
| Self peak RSS bytes | 2,139,750,400 | 2,135,932,928 | -3,817,472 (-0.18%) |
| Small typed-frontend allocations | 817,618 | 814,138 | -3,480 (-0.43%) |
| Small total allocations | 1,514,689 | 1,511,356 | -3,333 (-0.22%) |
| Small minimum retired instructions | 1,264,684,124 | 1,262,769,022 | -1,915,102 (-0.15%) |
| Small peak RSS bytes | 35,635,200 | 35,602,432 | -32,768 (-0.09%) |

The self compiler's earlier source-discovery checkpoint increased by 24,878
allocations while the small workload increased by 147. This is a change in the
candidate compiler's startup/discovery allocation footprint, not work moved out
of typechecking: the direct typecheck rows remove exactly four allocations per
compatible import edge, every later phase is allocation-identical, and retained
object count at `typed_frontend_complete` is identical at 5,910,869. Allocator
bytes at that checkpoint differ by 256 bytes. Whole-process allocations still
fall on both workloads.

Generated C was byte-identical:

- self compile: 83,590,280 bytes, SHA-256
  `8960232d0aa11ebf05ed7050305cac0da53c054fed2a3424ed803326f519eca8`
- small program: 42,475 bytes, SHA-256
  `b14e002cf83bd89ace4c862a0cf0137f36b21cde683a993671641f0c2e3b096a`

Raw retained results:

- `/tmp/typecheck-import-scope-baseline.json` (SHA-256
  `de8e35e01af62d76c2ae06d9b9bd325f470e18347b33b3003abcd0ff8773b1a4`)
- `/tmp/typecheck-import-scope-candidate.json` (SHA-256
  `da344b3473e0a6809ac2a8f5e0bd5a6cddcda9871eeaf5314eb2d8d62e1e95a2`)
- `/tmp/typecheck-import-scope-baseline-small.json` (SHA-256
  `17ec816671389c074599b832cb9d6608618d7bd7645c79be6aefd27708a955f4`)
- `/tmp/typecheck-import-scope-candidate-small.json` (SHA-256
  `d75552521dc0937d4b17f64d01535c75425d87c7660b9cc53de40abaf21a6bdc`)

## Validation

The opt-in metrics contract passed and the declaration-boundary suite passed
70/70 during the fast loop. On the final FRESH Apple clang 21 `-O2` build,
`scripts/compiler-check --changed --base 7a4098204aecccaf92b1441de450ebcc49d12895`
selected two production sources, ten suites, and the metrics special check;
266/266 tests passed. The serial `compiler-blorp` gate passed 5,120/5,120.
A comment-only correction after that broad gate left generated compiler C
counts and bytes unchanged; the final focused gate was rerun, while the broad
gate was not repeated.

Independent review found no blocking issues. It traced section-owned scope
resolution, importer-owned alias lookup, imported builtin policy, incompatible
scope diagnostics, execution order, and ownership through the production
paths, and returned `ACCEPT`.

## Recommendation

Accept. The cut removes a semantically redundant per-edge state transition,
reduces allocations at its measured boundary and process-wide, preserves
output, and keeps instructions flat. It does not complete the broader
preparation target; the retained attribution rows make the next cut
independently measurable.
