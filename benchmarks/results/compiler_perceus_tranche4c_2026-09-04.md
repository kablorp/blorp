# Perceus Tranche 4C — Lambda Owner Catalogs

This report compares the Tranche 4C candidate with committed preparation
revision `b181d6ba`. Separate production and debug/profile backend workers ran
seven warmed pairs with alternating parent/candidate order. The focused matrix
measures direct Perceus over decoded ownership-ready Core; worker startup and
JSON transport are outside the reported inner window.

Environment: macOS 26.6.2, arm64.

```bash
benchmarks/compiler_perceus_memory \
  --lambda-owner-matrix \
  --baseline-bridge <b181d6ba-timing-worker> \
  --baseline-counter-bridge <b181d6ba-counter-worker> \
  --samples 7 \
  --json
```

## Change

Each lambda now constructs one ordered borrowed-owner catalog containing:

1. managed lambda parameters;
2. managed runtime captures in their established name-mode representation;
3. exact referenced managed globals in ascending global-index order.

The catalog is consumed once by each existing all-owner call, aggregate, and
result normalization pass. Nested lambda bodies remain opaque to an outer
catalog and are normalized once as their own regions. The scalar per-owner
lambda rewrite loop and its dead single-owner wrapper were removed. Local
match, loop, resource, mutable-slot, and concurrency binding paths were not
changed.

## Fixture

Each of two uncalled functions contains one outer lambda with exactly 256
serialized expression nodes, 12 consuming-call sites, 12 aggregate-transfer
sites, 12 result terminals, and one nested lambda with one managed parameter.
Only the outer managed lambda-parameter count varies.

```text
globals=1
outer_functions=2
lambda_body_nodes=256
body_shape=lambda_borrowed_boundary
outer_lambda_parameters=1,8,32
captures=0
referenced_globals=0
boundary_sites_per_outer_lambda=36
lambda_regions=4
samples=7
warmup=true
measurement_window=perceus-direct
worker_invocation=false
```

## Paired Results

| Outer owners | Parent visits | Candidate visits | Visit reduction | Paired inner-time ratio | Allocation ratio | Release ratio |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1,096 | 1,072 | 2.2% | 1.044 | 1.001 | 1.001 |
| 8 | 9,026 | 1,072 | 88.1% | 0.712 | 0.669 | 0.659 |
| 32 | 36,146 | 1,072 | 97.0% | 0.369 | 0.313 | 0.303 |

At 32 owners, the paired direct-Perceus median improved by 63.1%.
Allocations fell from 47,960 to 14,996 (68.7%), and releases fell from 47,282
to 14,318 (69.7%). At one owner, direct time increased 4.4% and allocations
and releases each increased 0.1%, within the declared low-owner guards.

Candidate allocations rose from 14,424 to 14,996 across the 1-to-32-owner
axis. Catalog entry/index construction is necessarily owner-linear; the claim
here is that the much larger reconstruction work is owner-independent.

Candidate catalog counters were:

| Outer owners | Regions | Parameter slots | Scalar normalizations | Normalization visits | Alias fallbacks | Rewrite actions |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 4 | 4 | 0 | 1,072 | 0 | 74 |
| 8 | 4 | 18 | 0 | 1,072 | 0 | 74 |
| 32 | 4 | 66 | 0 | 1,072 | 0 | 74 |

The constant region, visit, and rewrite counts show that nested lambdas remain
separate regions and reconstruction no longer scales with borrowed-owner
count. The fixed action split is 24 call rewrites, 24 aggregate rewrites, and
26 result rewrites (24 outer terminals plus two nested-lambda terminals).
Capture and referenced-global slots are zero in the intentionally
parameter-only timing fixture. Focused correctness tests cover parameter/capture
spelling exclusion, the intentional name-mode capture/exact-global overlap,
and same-spelling owners across nested lambda regions. Because closure capture
metadata does not distinguish an exact global from another free value, the
mixed catalog test intentionally contains both the name-mode capture projection
and exact-global entry for that source spelling; source-kind timing remains
deferred.

## Correctness

Immediate-parent and candidate post-Perceus Core artifacts were byte-identical
at every matrix point:

| Outer owners | Core bytes | Core SHA-256 |
| ---: | ---: | --- |
| 1 | 77,140 | `b03e8883db23e5fafcbf552067f44d1db6d04a5d7ae46ccad0b8495deb7d7761` |
| 8 | 79,226 | `a4b26ac0c315f295e3718ef4d7abae9d5b0d7c352c8049db43989e12b9032b53` |
| 32 | 86,378 | `14a3d24d7a6f9367f30b945a6791f68f30f370ec75dbf86dbf14d91e7a51d538` |

Separate backend-emission comparisons also produced byte-identical C:

| Outer owners | C bytes | C SHA-256 |
| ---: | ---: | --- |
| 1 | 40,819 | `dfc6bc05638f447996fc3e9db1ee2f529d7ff093b1e8fe0f9563d0dcf86540d0` |
| 8 | 42,191 | `55d4b65479366da0b1353e130200c9aef8a4266c454d0fd491147f53318d879b` |
| 32 | 47,027 | `23ff6bcd991ab94494df546103b39e60d7808618c006ca1ec6b7cbed834d8d21` |

The focused Perceus suite passed 329/329 tests. The benchmark contract suite
passed 48/48 tests. `scripts/compiler-check --changed` passed one selected
production source, one focused suite, and one sanitizer check.

## Reproduction Details

Candidate timing worker SHA-256:
`cb6b683d28bb520231fc15973e4c85d96ff71c69b5898dbeefc1e926000a143b`

Candidate counter worker SHA-256:
`454a68d63e5eeb070a76628e9fd2a1d3cc8ec67d9663489703779a4dca9a788c`

Immediate-parent timing worker SHA-256:
`6ba1931b1f2dc43695d5013f98554021333436ade53033f430c0024b5f2bf18a`

Immediate-parent counter worker SHA-256:
`36c1bcd52abdab29b6acce4cd192a0d7d23edb15eac293c3e06da56bc79bc901`

Harness SHA-256:
`58ca564ff28d8d20d94c8d62c3bd4a02b1dd191d623d107d9e0349c2f3d1f22e`
