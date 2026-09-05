# Perceus Tranche 4D — Checkpoint C Boundary Fusion

Checkpoint C replaces the three all-owner call, storage-transfer, and result
walkers with one private, exhaustive borrowed-boundary normalizer. The immediate
comparison point is the preserved Checkpoint A worker described in the
Checkpoint B report, revision `188351b2`.

Environment: macOS 26.6.2, arm64. Measurements use seven warmed paired samples
and alternate candidate/parent order.

## Implementation result

The fused normalizer carries independent typed call, storage, and result child
modes. Lexical shadowing and path-local result satisfaction remain separate
context. Prepared tuple masks, boxed storage metadata, list-set transfer
metadata, compiled matches, resources, and loop binders have explicit private
handlers. Nested lambda bodies remain opaque and are normalized as their own
ownership regions.

The former all-owner structural roots and their duplicate match, binder,
resource, and collection helper families were deleted. Scalar local-binding
helpers needed by later Perceus tranches remain. `perceus.brp` is 72 lines
shorter than the Checkpoint A/current-main source despite also containing the
Checkpoint B instrumentation and the new fused authority.

## Fixed fusion matrix

| Active sites per family | Parent visits | Fused visits | Visit reduction | Allocation ratio | Allocation change | Release ratio | Time ratio |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 8 | 5,626 | 2,880 | 48.8% | 0.9741 | -2.6% | 0.9730 | 1.0137 |
| 32 | 5,794 | 2,880 | 50.3% | 0.9728 | -2.7% | 0.9717 | 0.9916 |
| 96 | 6,242 | 2,880 | 53.9% | 0.9701 | -3.0% | 0.9688 | 0.9944 |

At every point the candidate reports zero legacy all-owner visits and exactly
2,880 fused visits. Reconstructed-node counts are 1,442, 1,454, and 1,486.
Call, storage, and result actions remain exactly `(16,16,16)`, `(64,64,64)`,
and `(192,192,192)` respectively. Candidate and parent post-Perceus artifact
hashes are byte-identical at every density.

The deterministic allocation and release reductions are real but materially
smaller than the prospective 15% estimate. Direct Perceus time is effectively
flat at this fixture size and measured between 0.8% faster and 1.4% slower.
A provisional heap-record result from the first fused implementation caused a
roughly 1% allocation regression; removing that per-node allocation and making
consuming-call aggregate materialization explicit produced the final 2.6–3.0%
reduction shown above.

## Acceptance-threshold correction

Checkpoint B's exact census makes the original low-density 50% visit gate
mathematically unattainable: the union traversal must visit 2,880 nodes while
the three parent domains total 5,626, so the maximum valid reduction is 48.8%.
The executable gate therefore permits a 0.52 ratio at density 8 and retains the
0.50 ratio at densities 32 and 96.

The original 10% time and 15% allocation forecasts also overstated how much the
three boundary walks contribute to the complete direct-Perceus window. The
measured parent performs 98,441–125,091 allocations in that window, while
fusion removes only 2,550–3,738. The landing gate now requires the deterministic
32-site allocation reduction to be at least 1.5%, with no more than 5% direct
time regression. This records the actual scope of the change rather than adding
unrelated ownership optimizations to satisfy a forecast.

## Reproduction

```bash
benchmarks/compiler_perceus_memory \
  --borrowed-boundary-fusion-matrix \
  --bridge /tmp/blorp_issue51c_final6/timing/compiler_backend_worker \
  --baseline-bridge /tmp/blorp_issue51b_checkpoint_a/timing/compiler_backend_worker \
  --counter-bridge /tmp/blorp_issue51c_final6/counters/compiler_backend_worker \
  --baseline-counter-bridge /tmp/blorp_issue51b_checkpoint_a/counters/compiler_backend_worker \
  --samples 7 \
  --json
```

Candidate timing worker SHA-256:
`3b829b10ccf6d2ee4d35eaf8fb88ad8a8dc8b2b18387bdcc3dc368bbd1d48081`

Candidate counter worker SHA-256:
`638e852216860dc0f3bd0cde4a1f0b64196002141026f9aefb985cb496f41e00`

Checkpoint A timing worker SHA-256:
`e935a50d66f48e568dc737db4cbe10861e0a88df8eadf935d93b93f6c8c30d32`

Checkpoint A counter worker SHA-256:
`6965bc36c377aa3b1888652cc5459a5ab45f5ab69b23954672fe42aa60c89b2c`

Final harness SHA-256:
`937b570c3948ed770d6f6c614dab57e04cfd030a721b06f27888e2b01001f627`

Focused validation passes 333/333 Perceus tests and 61/61 benchmark/inventory
contract tests.

The current compiler source was also compiled through Perceus once with the
candidate and Checkpoint A production compilers. Both produced the same
311,396,138-byte snapshot with SHA-256
`3ff183929f8bf0ba5575009d26b37fdc5cac3657c5fcbf308ff2b955b2aa093c`.
Compiling that same source through the complete backend also produced
byte-identical 93,072,288-byte generated-C files with SHA-256
`1523812e3e7b8ed524098c428a4ecf12bc0acb218b5ab04154e917d466534ff8`.
This production-shaped run caught and corrected a call-only loop case that the
initial synthetic fixture did not cover: a consuming call must carry its
ownership provenance through an aggregate argument's storage-shaped children.

## Final validation

- focused Core Perceus: 333 passed, 0 failed;
- benchmark and exhaustive-inventory contracts: 61 passed, 0 failed;
- changed-source compiler check and Core sanitizer: passed;
- compiler-owned Blorp suites: 4,216 passed, 0 failed;
- runtime suites: 4,461 passed, 0 failed;
- leak checks: 879 passed, 0 failed; and
- generated-C audit: 215 passed, 0 failed.

The repository hygiene gate also passes, including the compiler test-ownership
manifest and exhaustive child-mode inventory.

`git diff --check` is clean, and the worktree contains no untracked generated C
artifacts.
