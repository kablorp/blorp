# Accepted Callable Exact Targets Step 2e Results — 2026-09-11

- Baseline compiler: `2111998c5dcd5ef49ebdc52550146af5962f09ed9868b8da7433135774159dc1`
- Candidate compiler: `aed081ddad97985df9dacb833f925f9584476a3e81481f4cefc62848fecb8bfb`
- Platform: macOS arm64, `/usr/bin/time -lp`
- Sampling: one retained parent sample plus one candidate run; no repeated
  wall-time sampling

Command:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile accepted 1 32 4 16 16 memory
```

Both runs produced semantic checksum `-6362768653699369705`, constructor
checksum `-2142865109331864226`, 1,257 primary outputs, 65 secondary outputs,
136 accepted constructor rows, and 353 accepted field rows.

Allocations move from `278349` to `278382` (+0.0119%), releases move from
`189347` to `189380` (+0.0174%), retained objects remain `89002`, and allocated
bytes remain `6490056`. Instructions move from `8458546611` to `8460316056`
(+0.0209%); cycles improve from `2325715780` to `2322167528` (-0.1526%).
Maximum RSS moves +0.2861%, peak footprint +0.3423%, and executable size
+0.0044%. All deterministic and native guard movements remain below 0.35%.

The 33 transient allocation/release pairs correspond to constructing the
provenance-bound visibility value for 33 module slots. They retain no objects
or bytes after the phase. A stack-only representation was considered, but
Blorp structs intentionally cannot store records or collections; weakening
that language invariant or splitting the aggregate solely to remove these
bounded calls would be disproportionate to this packet.

The measured fixture uses qualified imports, so it is a whole accepted-stage
regression guard rather than a claim about the selective-target path's latency.
The one-shot setup/window times are retained for reproducibility and are not
used as performance claims.

## Rejected Broader Representation

An earlier prototype also replaced the accepted-callable table's
`Dict[String, ...]` visibility maps with `Dict[Int, ...]`. Two implementations
both added 6,632 allocations and releases (about +2.4%) while retained objects
and allocated bytes stayed neutral. Removing allocation from source-name ID
lookup did not change those counts, isolating the cost to generic integer-keyed
dictionary representation/boxing rather than string projection. That prototype
was fully reverted. A compact integer-map runtime or a dense source-name
relation is prerequisite evidence for revisiting that table migration.
