# Batched selective-import type facts

Date: 2026-09-25

Baseline revision and frozen input:
`75774da7b40ed2887de6663fa2dbf041b3776dc4`. The candidate is that
revision plus the three-file production/test diff. Both compilers were FRESH
Apple clang 21 `-O2` builds made by `dev-048a5864cd98`.

## Hypothesis

`register_module_view_type_facts` replayed every graph-selective type import
through two whole-state helpers. Each name therefore crossed a helper boundary
before updating the known-type and type-home dictionaries. The attributed
`prepare_base_view_facts` row was 206,806 allocations across 380 prepared
modules.

Collecting the already-validated `(local name, canonical module path)` pairs
in source-binding order, then updating both dictionaries while their storage is
locally owned, should remove repeated COW work without retaining another table.

## Change

The graph path now builds one transient list of exact type facts and applies it
through `typecheck_state_record_imported_type_facts`. The helper unwraps both
indexes once, preserves an existing resource kind, preserves the first imported
home (and any local home), and publishes the two updated indexes once. The
standalone import path is unchanged.

The focused regression was written first and failed because the batch API did
not exist. It covers duplicate aliases from different module paths, a prior
resource kind, and a prior local home.

## Measurements

The frontend-only profile stopped after lowering. The baseline's detailed
attribution reported 206,806 allocations in `prepare_base_view_facts`. With
the candidate, `global_header_completion` fell from 4,842,861 to 4,796,955
allocations in the diagnostic profile while `module_bodies` remained exactly
21,600,596. The absolute header delta includes the baseline's temporary nested
phase probes; the matched harness below is the acceptance evidence.

| Workload and metric | Baseline | Candidate | Delta |
| --- | ---: | ---: | ---: |
| Self typed-frontend allocations | 30,805,306 | 30,764,340 | -40,966 (-0.13%) |
| Self total allocations | 210,507,658 | 210,466,692 | -40,966 (-0.02%) |
| Self minimum retired instructions | 169,141,815,789 | 168,689,837,412 | -451,978,377 (-0.27%) |
| Self peak RSS bytes | 2,127,724,544 | 2,130,853,888 | +3,129,344 (+0.15%) |
| Small typed-frontend allocations | 819,802 | 817,611 | -2,191 (-0.27%) |
| Small total allocations | 1,517,020 | 1,514,829 | -2,191 (-0.14%) |
| Small minimum retired instructions | 1,270,170,725 | 1,263,955,762 | -6,214,963 (-0.49%) |
| Small peak RSS bytes | 35,618,816 | 35,553,280 | -65,536 (-0.18%) |

Every self candidate instruction sample in the retained rerun was below every
baseline sample. The self RSS observation improved from +0.38% on the first
run to +0.15% on the rerun; the batch is released before environment
publication, so this process-level difference is treated as noise rather than
as either a gain or a regression. At `typed_frontend_complete`, retained object
count was identical at 5,910,419 and allocator bytes were identical at
575,007,600, directly confirming that the batch does not add retained frontend
data. Wall time is not acceptance evidence.

Generated C was byte-identical:

- self compile: 83,577,762 bytes, SHA-256
  `9797ca8acd5afaa50f938f0c924a2a61143ce41d8f64078431b45ce1ff65633e`
- small program: 42,475 bytes, SHA-256
  `b14e002cf83bd89ace4c862a0cf0137f36b21cde683a993671641f0c2e3b096a`

Raw retained results:

- `/tmp/callable-public-probe-base.json`
- `/tmp/selective-type-fact-batch-rerun.json` (SHA-256
  `1ee3c57fe7860ee911d3191c8fd898464994f02e98428072ed1c8e6171e46f5c`)
- `/tmp/callable-public-probe-base-small.json`
- `/tmp/selective-type-fact-batch-small.json` (SHA-256
  `a078fd2fa3b35616a3d0f61ed1b4d6b7ebbae5c3d9a012e3f080bd9dd90b3939`)

## Validation

The focused state suite passed 24/24 and the declaration suite passed 167/167.
On a FRESH Apple clang 21 `-O2` build,
`scripts/compiler-check --changed --base 75774da7b40ed2887de6663fa2dbf041b3776dc4`
passed all seven selected suites and the selected leak check: 1,203 passed and
zero failed. `scripts/test --no-build --serial compiler-blorp` then passed
5,120/5,120 on the same binary.

Independent review found no blocking or major issues. It confirmed that exact
definition-ID filtering, source order, first-home precedence, resource-kind
precedence, and the empty/non-type/incompatible paths are preserved. The
reviewer's only non-blocking observation was that the direct state-helper test
does not independently exercise graph-entry filtering; that path is unchanged
and remains covered by the declaration suite.

## Recommendation

Accept the cut. It reduces deterministic allocation work on both workloads,
improves retired instructions, keeps body checking flat, retains no new
cross-phase data, and preserves generated output.
