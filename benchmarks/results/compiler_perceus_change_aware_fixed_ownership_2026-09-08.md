# Change-Aware Perceus Fixed-Ownership Checkpoint

Date: 2026-09-08

## Scope

This checkpoint makes the ownership normalization for `UnboxExpr`,
`BinaryExpr`, `FieldExpr`, and `TupleFieldExpr` report exact source identity.
The proof is deliberately narrow:

- neutral unboxes retain their source root;
- unmanaged literal, variable, void, and explicitly primitive-returning binary
  operands retain their source root;
- consuming collection equality retains its established direct-field
  protection; and
- projections rooted in a variable or an explicitly borrowed/argument-alias
  call retain their source root.

Unproved and ownership-sensitive forms still run the old normalization and use
the opaque insertion route. The unchanged path allocates neither a replacement
root nor temporary child/binding lists before recursively checking its fixed
children.

Four debug counters partition every fixed-root visit into source reuse or
reconstruction and separately count ownership-normalization rewrites.

## Behavioral matrix

Fixture version 11 adds `fixed_ownership_change_matrix`. Each of the four root
families has one neutral case, one case whose recursively processed child
changes, and one ownership-sensitive case. The projection child-only cases use
an explicit argument-alias return contract so projection normalization remains
neutral while the call child changes.

For two workers the exact decisions are:

| Counter | Count |
| --- | ---: |
| fixed-ownership visits | 32 |
| original roots reused | 16 |
| roots reconstructed | 16 |
| normalization rewrites | 8 |

The bridge also inspects the post-Perceus Core. It requires the exact fixed-root
counts and the established borrowed-argument, equality-result, and owned-field
owner wrappers. Counter and timing workers produced identical 44,608-byte Core
with SHA-256
`cbd07b2324cbda25f5aa2dbee4ff0da72cf5d72841eeff7c2e666558dd42b343`.
The immediate parent produced the same artifact.

## Focused direct-Perceus result

Platform: `macOS-26.6.2-arm64-arm-64bit-Mach-O`.

The scaled `fixed_ownership_neutral` workload used two 1,024-node workers. It
contains 584 eligible fixed roots; all 584 retained their exact source and none
were reconstructed.

```bash
benchmarks/compiler_perceus_memory \
  --globals 1 \
  --functions 2 \
  --body-leaves 1024 \
  --global-reads-per-function 0 \
  --params-per-function 2 \
  --body-shape fixed_ownership_neutral \
  --measurement-window perceus-direct \
  --baseline-bridge <parent-timing-worker> \
  --baseline-counter-bridge <parent-counter-worker> \
  --samples 7 \
  --no-warmup \
  --json
```

| Metric | Parent | Candidate | Change |
| --- | ---: | ---: | ---: |
| measured-window allocations | 39,895 | 36,535 | -8.42% |
| measured-window releases | 37,946 | 34,586 | -8.85% |
| fixed roots reused | 0 | 584 | +584 |
| fixed roots reconstructed | 584 | 0 | -584 |
| paired measured-window time | — | ratio 0.9274, MAD 0.0560 | -7.26% |
| paired whole-worker time | — | ratio 0.9998, MAD 0.0093 | neutral |
| peak RSS | 37,093,376 bytes | 36,864,000 bytes | -0.62% |

The removed 3,360 allocations and releases are deterministic. Parent and
candidate produced byte-identical 206,996-byte post-Perceus Core with SHA-256
`8acabe341f0e0249deb82e6360aab1f0761f4e07c7c464a4bae2ecb5b2f770d3`.

Worker SHA-256 values:

- candidate timing: `008f84a56b4b0aac8cdd62095e83db24001f370caf13544d9fcedf6524a52d78`;
- parent timing: `aa77ea98ebf53847a8abb9461b6f4cbb68567684694b6fe8f7321dd4d079aecc`;
- candidate counters: `4ba12660e681363894e0bffb4f129fdb197aa3320cb2ba04d945b8665f730e08`;
- parent counters: `9a1783251f35929a1ac0face4878464a7b8afc0414aee6fac13dfe5395c29d28`.

## Composition controls

All controls remained byte-identical to the immediate parent:

| Workload | Parent allocations | Candidate allocations | Parent releases | Candidate releases |
| --- | ---: | ---: | ---: | ---: |
| aggregate escape | 28,061 | 27,793 | 26,330 | 26,062 |
| managed-let transfer | 100,136 | 100,136 | 96,025 | 96,025 |
| default linear fixture | 208,431 | 208,431 | 198,691 | 198,691 |

Aggregate escape gained another 0.95% allocation reduction because its neutral
projections now compose with the change-aware aggregates. Managed-let transfer
and the default fixture were allocation-neutral. Their respective artifact
hashes were
`85814dcda70cfe2caf3874260e513832d446c469007c4126068ce5e6efa76eb8`,
`e630dcfdd127bff65eb4e3cdb7edcdc67c0b5a37ca17f582b9348f710c3b532f`,
and `9172d24911c47031a114bc9c69f1be4f71a08af69652c9243e744d2172e94308`.

## Compiler self-compilation and profile

The immediate-parent and candidate compilers each compiled the same current
`blorp/src/main.brp` through Perceus. Both produced an exact 314,508,345-byte
Core snapshot with SHA-256
`3b760cfd569489a5c52cd6a002be5db77aaf582e2ff717eb3ca00e8f05cb5400`.

With lightweight compiler memory checkpoints enabled, whole-process managed
allocations fell from 414,864,981 to 414,575,827 (-0.07%) and releases fell
from 406,168,960 to 405,879,806 (-0.07%). Live objects and allocator bytes at
the stop boundary were identical. These perturbative counts establish no
self-host regression; they are not timing measurements.

A one-millisecond macOS sample captured 50,115 samples during candidate
self-compilation. Generated-C symbol mapping gave these inclusive maxima:

| Function | Samples | Share of capture |
| --- | ---: | ---: |
| `insert_drops_program` | 6,630 | 13.23% |
| function-level insertion rewrite | 4,408 | 8.80% |
| `insert_drops_expr_inner` | 4,188 | 8.36% |
| `insert_drops_expr_inner_result` | 2,784 | 5.56% |
| `insert_drops_non_binding_expr` | 1,481 | 2.95% |
| `insert_drops_ownership_node` | 1,094 | 2.18% |
| `insert_drops_change_aware_fixed_ownership` | 10 | 0.02% |

The new helper is not a remaining hotspot. The residual
`insert_drops_ownership_node` sample combines ownership-sensitive calls with
the four match families, so this profile does not attribute the 1,094 samples
specifically to match reconstruction.

## Admission decision

Issue 60 clears its landing criteria, but this profile admits neither a match
identity checkpoint nor Tranche 5:

- match reconstruction is not isolated from ownership-sensitive call
  normalization, so a match-specific production design is not yet justified;
- no remaining target-specific scalar-summary family is material enough to pay
  for Tranche 5's all-value fact collection; and
- the fixed-arity path itself is now negligible.

The automatic change-aware insertion sequence ends here. Any continuation
should begin with narrow measurement that separates remaining match and
sensitive-call work, not with a generic match rewriter or consumer-free
all-value fact product.

## Verification

- production compiler rebuild and `perceus.brp` type-check passed;
- all 345 focused Core Perceus tests passed;
- all 80 benchmark contract tests passed;
- matrix counters were identical across repeated debug-worker runs;
- fixed, composition, default, and self-host artifacts matched the parent; and
- changed-source sanitizer and independent review are recorded with the final
  handoff.
