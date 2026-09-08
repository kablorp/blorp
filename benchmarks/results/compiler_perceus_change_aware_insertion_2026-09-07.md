# Change-Aware Perceus Insertion Checkpoint

Date: 2026-09-07

## Scope

This checkpoint makes the private `insert_drops_expr` traversal retain its
input `CoreExpr` when the source root and every relevant child are known to be
unchanged. It deliberately covers only ownership-neutral leaves, simple
expression shells, unmanaged lets, borrow lets, and sequences. Ownership
normalization, aggregates, matches, loops, resources, and concurrency remain
conservative and are counted as opaque rewrite results.

The existing `PerceusInsertedExpr` result carries the exact source-reuse bit.
No generic Core traversal API or second per-node result wrapper was added.

## Direct Perceus measurement

Platform: `macOS-26.6.2-arm64-arm-64bit-Mach-O`

Fixture: default linear benchmark, 384 globals, 64 functions, 64 body leaves,
8,838 input expression nodes. Seven paired samples ran in alternating AB/BA
order without warmup:

Candidate timing worker SHA-256:
`2c71e7874a1ef4e08a8aaff25e8241df117060e7ce3acc16b1b1a89dd9dc2dc6`.
Candidate counter worker SHA-256:
`95234d3b079ce9e017f081575a59177a2f913740ec350a2e3bcd357fd6dc5227`.
Baseline timing and counter worker SHA-256 values were
`6f598628cf4e8722bb4d03d3ce4c2679eb29617bca19bb8200c1b4efaaf37b6c`
and `187e856c9a2314096a3d81995d22484201997537a50e83e047555212da819d3b`.

```bash
benchmarks/compiler_perceus_memory \
  --bridge /tmp/blorp-changeaware-reviewed.WIXLOj/timing/compiler_backend_worker \
  --baseline-bridge /tmp/blorp_post4_candidate/timing-final/compiler_backend_worker \
  --counter-bridge /tmp/blorp-changeaware-reviewed.WIXLOj/counters/compiler_backend_worker \
  --baseline-counter-bridge /tmp/blorp_post4_candidate/counters-final/compiler_backend_worker \
  --measurement-window perceus-direct \
  --samples 7 \
  --no-warmup \
  --json
```

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| measured-window allocations | 222,020 | 208,764 | -5.97% |
| measured-window releases | 212,280 | 199,024 | -6.24% |
| paired measured-window time | — | ratio 0.9607, MAD 0.0086 | -3.93% |
| paired process time | — | ratio 1.0007, MAD 0.0069 | within process noise |
| peak RSS | 62,603,264 bytes | 63,307,776 bytes | +1.13% |

The post-Perceus artifact was byte-identical in both workers:
`9172d24911c47031a114bc9c69f1be4f71a08af69652c9243e744d2172e94308`.

Measured-window microseconds were
`[28830, 27913, 27720, 27902, 27530, 28419, 27856]` for the candidate and
`[29529, 28799, 29116, 29165, 28820, 28911, 28996]` for the baseline.
Allocations were exactly 208,764 candidate and 222,020 baseline in every
sample.

The candidate's insertion decisions were:

| Counter | Count |
| --- | ---: |
| node visits | 8,838 |
| completed rewrite actions | 8,838 |
| original nodes reused | 8,644 |
| results not reusing their source | 194 |
| conservative opaque results | 65 |

Thus 97.8% of completed insertion results retained their immediate source node
on this fixture. The benchmark now rejects incomplete reuse/reconstruction
partitions and opaque counts that exceed non-reused results.

## Compiler self-check

One same-source compiler compilation stopped after Perceus produced identical
299 MB Core dumps with SHA-256
`435d65ff5a1a5a3938895e64c7a27c3068abb431717a5481ecc007b1ec459e32`.
The single run was timing-neutral (63.55 seconds baseline, 63.47 seconds
candidate) and is not treated as a performance estimate. The direct window is
the acceptance measurement for this checkpoint.

## Verification

- `perceus.brp` type-check passed.
- All 345 focused Core Perceus tests passed.
- All 61 Perceus benchmark contract tests passed.
- `scripts/compiler-check --changed` passed its production type-check, focused
  suite, and sanitizer check.
- Generated post-Perceus Core was byte-identical in the paired benchmark and
  compiler self-check.
