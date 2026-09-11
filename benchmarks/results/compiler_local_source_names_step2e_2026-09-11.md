# Local Source Names Step 2e Results — 2026-09-11

## Revisions And Host

- Baseline: `a0ef13d4` (`Normalize qualified alias source names`)
- Candidate: uncommitted Step 2e local-declaration packet
- Baseline compiler SHA-256:
  `fd689eb464dedd0120f255b1d2e8e64b3c0a0d2e4e05f2188f39947f249fe3ac`
- Candidate compiler SHA-256:
  `f29665573d40071643c4a7795d77474be3a78941508ccb362764b1a28d1e389f`
- Platform: macOS, `/usr/bin/time -lp`
- Sampling: one retained baseline/candidate pair per workload; no repeated
  wall-time sampling and no wall-time claim

## Workloads

The mixed Stage 06 workload builds and checks nine graph modules with 1,078
source and typed declarations and 30 resolved imports. Both runs reported
`workload_valid=True` and checksum `3270`.

The bound-phase workload isolates accepted typechecking work across 32 modules.
Both runs reported semantic checksum `120388240154574545`, constructor checksum
`4522423758094903886`, 33 primary outputs, 32 secondary outputs, and identical
constructor lookup work.

The production screen typechecks the existing qualified-alias sort fixture. It
exercises the real loader, graph binder, declaration prescan, and typechecker.

## Commands

```bash
/usr/bin/time -lp benchmarks/compiler_typecheck_profile 1 8 32 64 mixed 4

/usr/bin/time -lp benchmarks/compiler_typecheck_phase_profile \
	bound 1 32 4 16 16 memory

/usr/bin/time -lp <baseline-or-candidate-blorp> check --no-format \
	blorp/test/compiler/stage_06_typecheck/infer_fixtures/infer/should_pass/qualified_alias_sort.brp

stat -f '%z' <baseline-or-candidate-blorp>
shasum -a 256 <baseline-or-candidate-blorp>
```

## Raw Counters

| Workload | Metric | Baseline | Candidate | Change |
| --- | --- | ---: | ---: | ---: |
| mixed graph | setup microseconds | 128,883 | 128,627 | -0.1986% |
| mixed graph | measured window microseconds | 330,117 | 328,926 | -0.3608% |
| mixed graph | instructions retired | 7,311,818,742 | 7,369,860,338 | +0.7938% |
| mixed graph | cycles | 1,825,624,723 | 1,832,197,609 | +0.3600% |
| mixed graph | maximum RSS | 33,947,648 | 34,111,488 | +0.4826% |
| mixed graph | peak footprint | 26,034,536 | 26,149,200 | +0.4404% |
| bound phase | total allocations | 101,681 | 102,839 | +1.1389% |
| bound phase | total releases | 100,533 | 101,691 | +1.1519% |
| bound phase | retained objects | 1,148 | 1,148 | 0.0000% |
| bound phase | allocated bytes | 94,144 | 94,408 | +0.2804% |
| bound phase | instructions retired | 5,251,107,414 | 5,279,135,072 | +0.5337% |
| bound phase | cycles | 1,299,939,182 | 1,308,370,567 | +0.6486% |
| bound phase | maximum RSS | 24,428,544 | 24,608,768 | +0.7378% |
| bound phase | peak footprint | 18,235,704 | 18,366,776 | +0.7188% |
| qualified check | instructions retired | 2,944,278,603 | 2,951,556,355 | +0.2472% |
| qualified check | cycles | 735,296,408 | 738,368,055 | +0.4177% |
| qualified check | maximum RSS | 30,851,072 | 30,851,072 | 0.0000% |
| qualified check | peak footprint | 24,756,584 | 24,691,048 | -0.2647% |
| compiler | executable bytes | 19,336,224 | 19,336,896 | +0.0035% |

The mixed one-shot real time was 14.33 seconds for the candidate. The
production candidate took 0.52 seconds. Setup and window samples are retained
because the harness reports them, but neither is used to claim a latency
improvement.

## Interpretation

The principal result is structural: the graph local-declaration relation no
longer retains string keys, and every consumer uses the compilation-local
source-name domain. Mixed, isolated-phase, and production native guards all
remain below 0.80%, and the compiler executable is effectively unchanged.

The bound-phase allocation delta is deterministic and understood. Catalog
construction occurs before the benchmark resets its memory counters; the
measured delta is the one required `String -> SourceNameId` projection for each
of 1,158 graph-local registrations. It adds exactly 1,158 allocations and
releases. The resolved integer key is then reused for local-name and alias
collision probes, so no subsequent projection is performed during that
registration. Retained objects do not increase, allocated bytes grow only 264
bytes, and native phase guards remain below 0.74%. This packet is accepted as a
bounded normalization step, not as a standalone speedup claim.

The next packet should avoid repeating the projection cost at every consumer:
where practical, carry `SourceNameId` from graph admission into registration
and semantic lookup. That is the path from a retained diagnostic spelling
table to progressively string-free later pipeline stages.
