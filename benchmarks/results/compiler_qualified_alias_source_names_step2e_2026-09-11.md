# Qualified-Alias Source Names Step 2e Results — 2026-09-11

## Revisions And Host

- Baseline: `71a5a2fe` (`Normalize Core selective definition targets`)
- Candidate: uncommitted Step 2e qualified-alias packet
- Baseline compiler SHA-256:
  `2909313053f2683fec2fea94eb5d1d607fb9ff615e2b296e587049263fac4d98`
- Candidate compiler SHA-256:
  `fd689eb464dedd0120f255b1d2e8e64b3c0a0d2e4e05f2188f39947f249fe3ac`
- Platform: macOS, `/usr/bin/time -lp`
- Sampling: one retained baseline/candidate pair per workload; no repeated
  wall-time sampling and no wall-time claim

## Workloads

The mixed Stage 06 workload builds and checks nine graph modules containing
1,078 declarations and 30 resolved imports. It exercises indexed-graph
construction, prepared scope entry, import registration, and the full type
header/body path. Both runs reported `workload_valid=True` and checksum `3270`.

The production screen typechecks the existing qualified-alias sort fixture. It
guards the real loader/binder/typechecker path with a small, repeatable command.

## Commands

```bash
/usr/bin/time -lp benchmarks/compiler_typecheck_profile 1 8 32 64 mixed 4

/usr/bin/time -lp <baseline-or-candidate-blorp> check --no-format \
	blorp/test/compiler/stage_06_typecheck/infer_fixtures/infer/should_pass/qualified_alias_sort.brp

stat -f '%z' <baseline-or-candidate-blorp>
shasum -a 256 <baseline-or-candidate-blorp>
```

## Raw Counters

| Workload | Metric | Baseline | Candidate | Change |
| --- | --- | ---: | ---: | ---: |
| mixed graph | setup microseconds | 128,335 | 128,883 | +0.4270% |
| mixed graph | measured window microseconds | 327,585 | 330,117 | +0.7729% |
| mixed graph | instructions retired | 7,299,171,293 | 7,311,818,742 | +0.1733% |
| mixed graph | cycles | 1,837,668,667 | 1,825,624,723 | -0.6554% |
| mixed graph | maximum RSS | 33,914,880 | 33,947,648 | +0.0966% |
| mixed graph | peak footprint | 26,050,896 | 26,034,536 | -0.0628% |
| qualified check | instructions retired | 2,940,697,677 | 2,944,278,603 | +0.1218% |
| qualified check | cycles | 729,016,379 | 735,296,408 | +0.8614% |
| qualified check | maximum RSS | 30,785,536 | 30,851,072 | +0.2129% |
| qualified check | peak footprint | 24,658,280 | 24,756,584 | +0.3987% |
| compiler | executable bytes | 19,318,976 | 19,336,224 | +0.0893% |

The mixed benchmark's one-shot real time moved from 16.03 to 16.14 seconds,
most of which is profile reporting outside the 330 ms measured workload. The
production check moved from 0.57 to 0.52 seconds. Neither short wall-time
sample is acceptance evidence.

## Design Feedback

A broad prototype cataloged every declaration name while migrating only alias
lookup; instructions increased 1.27%. Immutable incremental table construction
increased them 3.45%. Migrating local and imported-name maps before their
consumers could carry IDs increased them 1.57%. All three were removed.

The accepted candidate catalogs qualified aliases only and replaces the graph
`Dict[String, ModuleId]` with `Dict[Int, ModuleId]`. Every reported resource
and artifact metric stays within 0.87% of the immutable baseline. The packet is
accepted as a bounded identity/ownership foundation; it does not claim an
overall speedup or complete source-string retirement.
