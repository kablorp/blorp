# Concrete accepted scoped-call binder: correctness prerequisite

This cut binds already-resolved scoped accepted-unresolved trait calls when the
first selected method is concrete. Materialized defaults exercise that boundary;
there is no default-body-only gate. It does not change bare-global dispatch,
publication, CTFE admission, syntax, or runtime layout. It is accepted as a
correctness prerequisite with an explicitly measured temporary lookup cost,
not a performance improvement.

## Provenance

- Worktree: `<worktree:fixed-union-concrete-binder>`.
- Base: `175a3821519ec6749f541933a72cf6fcb4e70590`; uncommitted production changes
  are confined to inference and accepted trait implementation authority.
- Retained matching baseline:
  `/tmp/blorp-default-facts-combined.B6X7p3/root-175a-baseline-blorp`, SHA256
  `8d3a1be4ba3831484c2e15f4c6d926e0f8988c41e2dccfae63a4c2ab68ea25a6`.
- Candidate: `BLORP_CLI_C_OPTIMIZATION=-O2 make`, then
  `scripts/compiler-build-status` reports FRESH, CLI/runtime O2, split 8,
  Apple clang 21.0.0, compiled_by `dev-d44472d3a5d0`, memory diagnostics 0.
  Candidate SHA256:
  `232a75d1db0b4066267567e02ae4a9ef3118227f281ddf17e5b4c8833deaf84b`.
- Raw artifacts: `/tmp/blorp-concrete-binder-red.xE6TSE`.
  `frozen-manifest.sha256` pins production, tests, probes, helpers, and launchers.
  It describes the independently validated pre-style checkpoint. Subsequent
  formatting changes include production import order and the newly added UFCS
  Option-adapter wrapper layout, plus small-probe import order, whitespace, and
  tuple layout. None are substituted into the historical manifest or Core/C.

## Meaningful RED and preservation

The original declaration regression had 182 passing checks and one failing
exact-target check (`decl-red.log`). Independent setup established successful
typechecking, a selected outer published default, distinct issued inner/default
IDs, and an accepted-unresolved inner call. The preceding 181 checks passed.
The regression demands the exact accepted inner callable in both call and
callee metadata, not merely the result value.

The unchanged absolute-path Eq probe fails with the retained baseline:
`compile-time constant evaluation does not support intrinsic function call
'equals' yet`. The unique-slot custom trait probe similarly fails for `agrees`.
Candidate tests pass both folded and runtime results. Final baseline logs are
`final-eq-baseline.log`, `final-custom-baseline.log`, and
`final-purity-baseline.log`; candidate counterparts have `-candidate.log`.

The pure implementation of an impure slot is accepted by baseline (1/1).
An initial candidate rejected it (`purity-candidate-before.log`); validation
now compares signature shape separately and allows only the established purity
refinement direction. The call's conservative impure contract remains unchanged.

## Focused GREEN

Commands use the candidate `bin/blorp test` and these exact owning suites:

| Suite | Passed | Raw log |
| --- | ---: | --- |
| `test_typecheck_decl.brp` | 192 | `frozen-decl.log` |
| `test_infer.brp` | 336 | `frozen-infer.log` |
| `test_accepted_semantic_catalog.brp` | 10 | `frozen-authority.log` |
| Eq default probe | 2 | `final-eq-candidate.log` |
| Unique custom trait default probe | 2 | `final-custom-candidate.log` |
| Impure-slot/pure-implementation probe | 1 | `final-purity-candidate.log` |
| Explicit independent `not_equals=False` probe | 2 | `frozen-explicit-ne-probe.log` |

The table-policy controls require genuine accepted graph-issued private
`Box[T]` and `Box[Int]` implementations: ordinary lookup selects the generic
first; the second-only authority selects the concrete target; the concrete query
returns Template without skipping the first. This is a table-boundary policy
proof, not a claim that every overlapping public program is coherent. Separate
admitted controls cover alias-erased instance bounds and a method-generic slot.
Issuer, missing member, registered compiler-member, true absence, exact selected
identity, immediate closure resolution, and ordinary selected calls are covered.

## Actual Core and C

The three `*_program.brp` launchers import the unchanged test functions because
TestSuite sources may not define `main`. Compile each using:

```bash
bin/blorp compile --dump-core-after=lower --dump-core-file=/tmp/probe.lower.core \
  --no-format benchmarks/results/fixed_union_concrete_binder/default_inner_call_program.brp \
  -o /tmp/probe.c
```

Actual retained outputs are `eq/custom/purity.lower.core`, matching `.c` files,
and bounded `*.core-excerpt.jsonl`. Each launcher also ran successfully with
`bin/blorp run` (exit 0, `*-program-runtime.log`). Definition IDs below belong
to those exact executable compilation domains:

| Program | Outer target | Inner target | Contract |
| --- | --- | --- | --- |
| Eq | `not_equals` 123 | `equals` 124 | pure |
| Custom | `disagrees` 123 | `agrees` 124 | pure |
| Purity | `not_equals` 124 | `equals` 125 | outer remains impure, inner implementation pure |

Lower Core records selected trait calls and identical callee `def_id` values.
Eq/custom runtime wrappers select outer ID 123. Generated C has folded globals
`FOLDED_DEFAULT_NOT_EQUAL = 1` and `FOLDED_DISAGREES = 1`; each runtime default
calls its concrete implementation (`brp_1Z -> brp_20`, returning `!0`). The
explicit `not_equals=False` control independently passes folded/runtime checks.

## Independent integration validation

The independent runner retained its raw report at
`independent/REPORT.md`, SHA256
`aadd9afbc1e82a1737ef788ccfa2c52fe52d344c86021953cb8d2f75660e7d3c`.
These actual gate results overlap and must not be summed as unique coverage:

| Gate | Passed | Raw artifact under `independent/` |
| --- | ---: | --- |
| Exact owning suites | 538 | `focused.log` |
| Actual changed selection, base175a | 609 | `selected.log` |
| CTFE stage | 191 | `ctfe.log` |
| Serial compiler/runtime/leak wrapper | 12397 | `broad.log`, `gates/` |
| Stage1 generated-C audit | 228 | `codegen-audit.log` |
| Stage2 generated-C audit | 228 | `stage2-audit.log` |
| Candidate-built stage2 standalone probes | 7 | `stage2-probes.log` |

Warmup succeeded. All three actual candidate O2 fixpoint C outputs were
75,726,250 bytes and byte-identical, SHA256
`81af02ef05c7db1ea01270443b14bd640d8cd0f54af8baaecea0e483b09547d7`.
The stage2 executable was SHA256
`0a1c4fedea88ba28b4499317e9664dcc3418738f8ea8a729133e12ce54614fda`.
Raw outputs and comparisons are in `independent/fixpoint/` and `fixpoint.log`.
Stage1/stage2 launcher lower Core and generated C were byte-identical in all
three pairs. The runner independently repeated exact inner/callee target and
folded-global predicates, and actual launcher runs exited0 with zero tracked
leaks. TestSuite leak summaries are process-end checks, not workload cost metrics.

The actual commands are recorded in the raw independent report; notably:

```bash
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --changed --base 175a3821519ec6749f541933a72cf6fcb4e70590
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --stage ctfe
scripts/test --serial --no-build --log-dir /tmp/blorp-concrete-binder-red.xE6TSE/independent/gates compiler-blorp runtime leak
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-fixpoint --work-dir /tmp/blorp-concrete-binder-red.xE6TSE/independent/fixpoint
```

No sanitizer repeat, main integration, commit, push, bootstrap pin, or release
was performed in this checkpoint. Root pre-binder validation is not used as
candidate validation.

## Historical ordinary-lookup adapter cost

One small benchmark repeatedly calls the existing ordinary
`accepted_find_impl_method_info_by_trait_id` API against one valid accepted
concrete method. Authority construction, receiver construction, warmup, target
validation, checksum construction, and reporting are outside scalar allocation
and release endpoints. Both MemoryStatsActive and OracleStatsActive are checked.
`reset_mem_stats` enables tracked allocation/mutex overhead, so instruction
results are explicitly whole-process tracked-mode observations.

Measured source SHA256
`a676c5483c75972b6d8ce0e620f02f7cd90045236e3a0b18a2cd0049737983fc`
is retained separately as `adapter-measured-a676.brp`. A byte-identical copy
was built in disposable baseline `/tmp/blorp-fixed-union-adapter-baseline-175a`
at exact175a and in this candidate tree, using the same retained175a compiler
host. Source manifests differ only in the two frozen production files: this
is not candidate imports compiled twice by different host binaries.

Existing `compiler_blorp_benchmark_runner` built diagnostic O2 workers;
`compiler_pass_compare` retained seven alternating paired windows. Separate
`/usr/bin/time -l` worker samples retained seven alternating pairs. Optimized
binary disassembly proves each loop performs the real ordinary lookup and
Option replacement with a countdown/backedge; finalTarget*iterations is only
a final-result/iteration checksum, not an execution oracle by itself.

| Metric, 100,000 lookups | Baseline | Candidate |
| --- | ---: | ---: |
| Managed allocations | 1,800,000 | 1,900,000 |
| Managed releases | 1,799,995 | 1,899,995 |
| Whole-process retired instructions, median | 2,766,020,307 | 2,906,409,554 |
| Whole-process retired instructions, minimum | 2,764,248,518 | 2,904,656,936 |

The adapter adds exactly one allocation and release per ordinary successful
lookup in this workload. Median instructions rise 5.0755% (minimum 5.0794%).
This is an accepted temporary correctness cost, not zero-cost match fusion,
a speedup, a plain-latency claim, or a production-phase regression percentage.

Full commands, worker/C hashes, source manifests, raw sample order, and
retention caveats are in `adapter-COMMANDS.md`, `adapter-build-manifest.sha256`,
`adapter-{baseline,candidate}-sources.sha256`, `adapter-paired.json`,
`adapter-instructions-summary.json`, and the14 raw instruction stdout/time
files. Packet manifest `adapter-artifacts.sha256` has SHA256
`9be304b69d1f1f5d82c08787bf9a559dd08cceac19d1f5f2edb947d5c8ace42e`.
Candidate C was copied from the actual runner temporary file; baseline C was
regenerated with the same host/source/flags after runner cleanup. Execution
proof uses each actual measured binary's disassembly.

## Canonical-source checkpoint and cost supplement

The final canonical benchmark is 171 lines, SHA256
`fc66330b8338695d6aae80f9e3d7f40f661cd8334ea10f1dc7bd1839696f8d1c`,
with a byte-identical disposable 175a baseline copy. This is a separate matched
snapshot from the retained historical 120-line a676 source and packet above.
Production formatting is confined to import ordering and the new UFCS wrapper:

- Inference SHA256:
  `d551d56d27b88309a83a8223b89e3136a1dd5a4060742f7ac6849fab91920f04`.
- Accepted authority SHA256:
  `4c555881c10de9567b97dcef95f205708a2453ff35921ce8d09a1673901655e4`.

The own compiler was rebuilt O2 from this source checkpoint, then reported
FRESH (`canonical-candidate-build.log`, `canonical-fresh.log`). Its binary is
byte-identical to the historical 232a candidate, SHA256
`232a75d1db0b4066267567e02ae4a9ef3118227f281ddf17e5b4c8833deaf84b`.
Actual post-style owner checks pass 192/336/10 (`canonical-focused.log`);
styled standalone leak controls pass 2/2/1/2 with zero leaks
(`canonical-probes.log`). These current checks do not relabel historical broad,
audit, or fixpoint results as post-style runs. Existing tests and production
semantics remain unchanged; no blanket inherited-module reformatting was done.

Both canonical workers were newly built with the same retained175a host and
diagnostic O2 flags. Their measured binaries are byte-identical to their
historical counterparts: baseline SHA256
`6fde9400c75ae695102fbffdeb979cd39eda990685d6b78b7bd401c49cd33d4c`,
candidate SHA256
`da04aba2d5c52ec5b36114f9bdfaebc69ccb5c54b78d989b1938c99053c8db17`.
Both actual runner-generated canonical C files were captured before cleanup,
SHA256 baseline
`22d8fe657d3d7311a96c8e994fdd4f69cfa21b3a4738702b8be224935f599f65`,
candidate
`ec2aa25c681e898721ba52b9a87a27cff67001e7f3846316ac9c216f77765e0f`.
The differing C source hashes are retained rather than overwritten onto a676
attribution. Disassembly again confirms the actual ordinary lookup and Option
replacement execute within each optimized countdown loop.

Tiny N=1 controls give baseline 18 allocations/13 releases, candidate 19/14,
both counter gates 1, checksum 123, valid True, tracked_reset. Seven new alternating
N=100000 pairs reproduce exactly +1 allocation/release per lookup:

| Canonical metric, 100,000 lookups | Baseline | Candidate |
| --- | ---: | ---: |
| Managed allocations | 1,800,000 | 1,900,000 |
| Managed releases | 1,799,995 | 1,899,995 |
| Whole-process retired instructions, median | 2,766,037,738 | 2,906,431,155 |
| Whole-process retired instructions, minimum | 2,763,840,989 | 2,904,989,637 |

Median tracked-mode whole-process instructions rise 5.0756% (minimum 5.1070%).
All paired rows preserve both active gates 1, checksum 12,300,000, valid True, and
tracked_reset. This confirms the same accepted correctness cost, not a
production-phase percentage, plain-latency improvement, or zero-cost adapter.

Full canonical commands, source/worker/C manifests, actual sample order, and
raw data are retained separately as `canonical-COMMANDS.md`,
`canonical-build-manifest.sha256`, `canonical-{baseline,candidate}-sources.sha256`,
`canonical-paired.json`, `canonical-instructions-summary.json`, and the 14 raw
instruction stdout/time files. `canonical-artifacts.sha256` has SHA256
`16ad8c2afd901c6163ec09a2b538ec538d9f327c8253958aff0d420a8daca7b5`.
No historical raw report, fixpoint, or a676 artifact was modified.

## Honest setup limitations and remaining review

- Initial missing generated inputs were setup failure, not RED. Normal Makefile
  generation produced embedded std SHA256
  `436d03364aec9c4d3117913ca1db06a884bc3681e3a8c16c98deebfdbd98ad44`
  and build-info SHA256
  `85b5c6bde0078704119647391e647a80db648b5d2de52db2d01c2e9f9626f9e5`.
  The initial raw failure log was overwritten; those diagnostics survive only
  in the task transcript. It has not been reconstructed.
- Unsupported `--dump-core-after=ctfe`, missing executable `main`, and an
  attempted `from ... import` launcher syntax were evidence setup failures.
  `lower` snapshots plus generated C provide the retained evidence instead.
- Earlier custom fixture attempts omitted required method imports or reused Eq
  member names. They are not semantic RED. The retained custom fixture imports
  `CustomEquality, disagrees` and uses unique members, without changing import
  registration.
- The first benchmark build rejected unsupported benchmark spelling forms.
  Its raw log is retained as setup failure, not performance data; corrected
  source was identical in both measured roots.
- A separate private-Eq consumer diagnostic did not establish a dispatch bug:
  its original checkout was missing, and the later diagnostic setup was rejected
  as orphaned. It is not a semantic RED or part of this cut's proof.
- Final source/docs/benchmark review remains required before commit. Historical
  measured-source hashes and independently validated pre-style evidence are
  retained rather than relabeled as later formatted inputs.
