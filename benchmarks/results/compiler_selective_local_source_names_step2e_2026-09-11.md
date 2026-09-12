# Selective Local Source Names Step 2e Results — 2026-09-11

## Revisions And Host

- Baseline: `eeef5803` (`Normalize semantic compilation identity tables`)
- Candidate: uncommitted Step 2e selective-local-name packet
- Baseline compiler SHA-256:
  `debb8c839361a9defdb1bae15fd7ab48a3c86a2984e96c9376dad45dcb609edb`
- Candidate compiler SHA-256:
  `d9f548a825a93b73cb5d152f0665f024a7f5a448fff14141fad37c833467c3f4`
- Platform: macOS, `/usr/bin/time -lp`
- Sampling: one retained baseline/candidate pair per final workload; no
  repeated wall-time sampling and no wall-time claim

## Workloads

The isolated module-binding harness registers 64 graph module aliases and 64
graph selective imported names across 64 modules with 16 exports each. Both
runs reported 1,024 exported symbols, 128 import bindings, zero errors,
`workload_valid=True`, and checksum `12608`.

The production screen typechecks
`blorp/benchmark/compiler/selective_import_graph_fixture/main.brp`. It exercises
the real loader, indexed graph, source-name catalog, import binder, and Stage 06
typechecker.

## Commands

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_module_binding_profile 1 64 16

/usr/bin/time -lp <baseline-or-candidate-blorp> check --no-format \
	blorp/benchmark/compiler/selective_import_graph_fixture/main.brp

stat -f '%z' <baseline-or-candidate-blorp>
shasum -a 256 <baseline-or-candidate-blorp>
```

## Raw Counters

| Workload | Metric | Baseline | Candidate | Change |
| --- | --- | ---: | ---: | ---: |
| module binding | allocations | 6,743 | 6,807 | +0.9491% |
| module binding | releases | 5,328 | 5,392 | +1.2012% |
| module binding | retained objects | 1,415 | 1,415 | 0.0000% |
| module binding | allocated bytes | 97,016 | 97,024 | +0.0082% |
| module binding | setup microseconds | 9,292 | 21,175 | +127.88% |
| module binding | measured window microseconds | 851 | 1,783 | +109.52% |
| module binding | instructions retired | 240,324,656 | 242,102,310 | +0.7397% |
| module binding | cycles | 73,641,759 | 84,734,333 | +15.0629% |
| module binding | maximum RSS | 4,063,232 | 4,079,616 | +0.4032% |
| module binding | peak footprint | 2,457,888 | 2,441,504 | -0.6666% |
| selective check | instructions retired | 2,998,057,875 | 3,013,813,549 | +0.5255% |
| selective check | cycles | 727,318,828 | 751,760,201 | +3.3605% |
| selective check | maximum RSS | 31,096,832 | 31,178,752 | +0.2634% |
| selective check | peak footprint | 24,985,960 | 25,051,520 | +0.2624% |
| compiler | executable bytes | 19,370,576 | 19,387,424 | +0.0870% |

The module-binding process real time was 12.96 seconds for the baseline and
12.51 seconds for the candidate, while the benchmark's own short measured
window reported the opposite direction. The production check was 0.18 seconds
for the baseline and 0.49 seconds for the candidate. These samples demonstrate
why elapsed time is not used as an acceptance signal for this packet.

## Interpretation

The structural result is complete: the graph selective imported-name index is
integer-keyed, every collision consumer uses it, uncataloged graph spellings
fail closed, and the old graph string map is gone. The source-rich ordered rows
remain only for current diagnostic and downstream compatibility consumers.

The isolated harness adds exactly one transient allocation and release per
selective registration. A rejected raw-index sentinel prototype produced the
same counts, demonstrating that the cost was not the lookup's `Option` carrier.
Retained objects are unchanged and allocated bytes grow by eight bytes. The
isolated instruction change is +0.74%, RSS is +0.40%, and peak footprint
improves 0.67%.

The one-shot cycle and microsecond samples are inconsistent with the stable
work and memory counters and are retained as noise, not averaged away. The
production check stays bounded in its primary direct signals: instructions are
+0.53%, RSS is +0.26%, peak footprint is +0.26%, and compiler size grows 0.09%.
Its one-shot cycles are +3.36%. The packet is accepted as a bounded
normalization step, not a standalone speedup claim.

The next performance opportunity is to carry `SourceNameId` from graph
admission into registration and ID-aware lookup, which should remove the
remaining per-registration projection while preserving the one reverse
spelling table needed for diagnostics and debugging.
