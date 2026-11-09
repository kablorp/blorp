# Loader source snapshots, 2026-11-09

The loader accepts a frozen list of caller-supplied source contents through
`load_program_with_sources`, using the existing load/check pipeline. Normalized
absolute paths are the only keys of one local `Dict[String, String]`.
Duplicate paths, including unused rows, reject before loading. Raw NUL paths
reject before normalization can erase a bad component. Supplied contents are
authoritative for disk-backed modules, including empty or malformed contents;
embedded library modules keep their existing authority. The selected bytes
enter the normal source inventory before parsing.

Legacy loading APIs retain their `LoadFailure` result and pass an empty map
to the same private core. Each entry captures cwd once. No cache, editor state,
second resolver/checker, temporary source-file transport or compiler-fault
fallback was added.

Production: **77 added / 9 removed, 86 gross / +68 net**; ceilings were
300 gross / +140 net. Tests: **469 new lines plus one registration**. README:
six added lines. The ordinary suite contributes 21 new callbacks; together
with existing embedded/grouped loader suites, **34 focused callbacks pass**
with strict zero leaks. The missing-API fail-first witness is retained.
Mutations ignoring the map and accepting duplicates fail 15/21 and 2/21
callbacks respectively, and the restored source passes.

## Matched compiler costs

The isolated candidate is based on
`329e273772bb1002a031ab035e11985d90e3897f`; integration preserves the already
landed `io.describe` import. The same baseline compiler generates candidate C;
Apple clang 21.0.0 links normal and diagnostic binaries from that C using
`-std=c11 -O0 -lm -lpthread`, differing only in
`BLORP_MEMORY_DIAGNOSTICS=0/1`. Sources and binary hashes are retained.

Fixed runs compile one immutable baseline compiler source/library with the
same cwd and argv paths. Three serial normal samples alternate baseline and
candidate; instructions use medians. Separate strict diagnostic runs measure
allocations. Own-source has one normal and one diagnostic observation,
compared with the matched baseline; no latency speedup is claimed.

| Workload | Baseline | Candidate | Change | Ceiling |
| --- | ---: | ---: | ---: | ---: |
| Fixed allocations | 13,544,664 | 13,544,666 | +2 | +4 |
| Fixed instructions, median of 3 | 36,918,135,745 | 36,918,869,121 | +0.001986% | +0.1% |
| Own-source allocations | 13,544,664 | 13,559,081 | +0.106440% | +0.3% |
| Own-source instructions | 36,918,135,745 | 36,942,529,439 | +0.066075% | +0.3% |

All eight fixed-input C outputs have identical SHA-256
`15819f0364ecaac3a58c53b9f790b933b21424f6bd3f86dd5327d6f001a18b20`.
Own-source normal/diagnostic output equals candidate C:
`2b9f7423ad710ae569185c95e4368f2322882075dce473ce2cb18166d3043917`.
Normal binary: `77606121783816f291822d75d45c09706bb995f3051733e64e6cf052d740f6ed`;
diagnostic: `95e71496ddc28a718d6492c49828d7c58ec1fdd9f06ada588789edf7b720cbcb`.
All strict counts balance with zero leaked objects or bytes. Four malformed
CLI controls also preserve exact exit 1, stdout and stderr, publishing no C:
propagation in if/match, explicit opaque arguments, and a Char pattern.

## Override ingress controls

One ordinary measurement main calls the existing loader and `src/main.compile`
on the same frozen 16-file disk graph. It constructs all 16 explicit rows
before selecting 0, 1 or 16 overrides; every supplied row matches disk bytes.
Costs include process/argument work, row construction/selection, admission,
remaining disk reads, normal compilation and output writing. These are
end-to-end ingress controls, not an isolated Dict benchmark.

| Overrides | Allocations / releases | Instructions, median of 3 |
| ---: | ---: | ---: |
| 0 | 103,319 / 103,319 | 499,962,645 |
| 1 | 103,338 / 103,338 | 499,929,910 |
| 16 | 103,558 / 103,558 | 499,947,560 |

Three normal rounds rotate mode order, with separate strict diagnostic samples.
All 15 warmup/normal/diagnostic outputs are byte-identical:
`d6c46e7816497dbfe816c97138891d59165e68f1a22c50a6268a9abb917f10d9`. The emitted program's real main returns 120
under ASan/UBSan with strict zero leaks. All 92 frozen control/compiler inputs
remain unchanged. Small instruction differences here are not a latency claim.

## Evidence and remaining qualification

Reproduction:

```sh
python3 blorp/build/roadmap-coordination/measure_slice.py \
  /Users/keithphilpott/.codex/worktrees/lsp-source-snapshots/blorp source-snapshots
```

Use a fresh output label and serialized compile lease; retained labels cannot
be overwritten. Exact commands, source/binary hashes, flags, raw counters,
output C and acceptance checks live under the coordinator's ignored
`blorp/build/roadmap-coordination/source-snapshots/`. Control sources, frozen
inputs, commands and samples are in `source-snapshots-controls/`; the verified
85-file copy manifest is `copy-provenance.json`. CLI comparisons are in
`source-snapshots-diagnostics/RESULTS.json`. Focused/mutation evidence remains
in the source-snapshot worker's `build/lsp-source-snapshots/`.

The integrated `make -C blorp test INSTRUCTION_CHECK=on` passes:
**1,348 component callbacks / 158 suites / 22 groups**, and **900 native/runtime
callbacks / 14 groups**. A fresh exact `scripts/blorp-fixpoint --prove` retry
exits 0: compiler C identity, **687/687 fixture pairs**, and the same component
and native selection under the self-built compiler all pass. Independent
inspection of all 1,374 fixture exit files finds only 0/1 (1,134/240).
All recorded strict counts balance; all **1,193** source/test/tool inputs stay
unchanged. Both whitespace checks pass. No cost exceptions were needed.
Broader native execution and the existing deferred suites receive no PASS.

The first proof attempt was interrupted during native tests. It is preserved
under `integration-snapshots/fixpoint-interrupted/` and receives no final PASS.
The fresh retry's complete log, exit, manifest comparisons, counts, strict
records and hash provenance are in
`blorp/build/roadmap-coordination/integration-snapshots/RESULTS.json` and
`fixpoint-retry.log`; current full proof artifacts are in `blorp/build/fixpoint/`.
The first-three-slice proof remains hash-verified in
`blorp/build/roadmap-coordination/integration/fixpoint-first3/`.

Independent code-reviewer and test-runner reviews approve the implementation
and evidence. This loader-only slice adds no platform-specific native or ABI
behavior; the normal post-push CI will test its integration on all platforms.
