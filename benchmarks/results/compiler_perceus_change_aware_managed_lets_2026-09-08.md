# Change-Aware Perceus Managed-Let Checkpoint

Date: 2026-09-08

## Scope

This checkpoint lets Perceus retain the immediate source `LetExpr` when all
of the following are proven:

- binding-alias normalization retained the exact RHS;
- mutable-branch normalization retained the exact body;
- recursive insertion retained both child nodes; and
- the existing ownership decision is already neutral: either the managed
  value has one exact direct transfer or its immutable RHS is immortal.

Unused, mutable, repeated-use, branch-balanced, alias-retained, and
shadow-freshened managed lets remain conservative. The owned-temporary
classification used by planning is threaded into normalization so a failed
reuse proof does not add a second RHS ownership scan.

Three debug counters partition every managed-let decision into source reuse or
reconstruction. The benchmark's dedicated transfer shape requires exactly one
reuse per worker and one reconstruction for the fixed sentinel.

## Direct Perceus measurements

Platform: `macOS-26.6.2-arm64-arm-64bit-Mach-O`.

Candidate timing worker SHA-256:
`5d8f4395629bc580a1e01f859cc8755a751fd7566bd081bdcbbe7c971b979021`.
Candidate counter worker SHA-256:
`933f46c2397b65434ea5c9ac9cdec5806fcaf710be98587b602d217cc8cabc73`.
The immediate-parent timing and counter workers were
`2c71e7874a1ef4e08a8aaff25e8241df117060e7ce3acc16b1b1a89dd9dc2dc6`
and
`95234d3b079ce9e017f081575a59177a2f913740ec350a2e3bcd357fd6dc5227`.

The transfer workload contains 512 resolved immutable
`let value = <owned String>; value` workers plus the existing sentinel:

```bash
benchmarks/compiler_perceus_memory \
  --bridge /tmp/blorp-managed-let-final.XCrqrX/timing/compiler_backend_worker \
  --counter-bridge /tmp/blorp-managed-let-final.XCrqrX/counters/compiler_backend_worker \
  --baseline-bridge /tmp/blorp-changeaware-reviewed.WIXLOj/timing/compiler_backend_worker \
  --baseline-counter-bridge /tmp/blorp-changeaware-reviewed.WIXLOj/counters/compiler_backend_worker \
  --measurement-window perceus-direct \
  --body-shape managed_let_transfer \
  --globals 1 \
  --functions 512 \
  --body-leaves 1 \
  --global-reads-per-function 0 \
  --samples 7 \
  --no-warmup \
  --json
```

| Metric | Parent | Candidate | Change |
| --- | ---: | ---: | ---: |
| measured-window allocations | 102,709 | 101,173 | -1.50% |
| measured-window releases | 98,598 | 97,062 | -1.56% |
| paired measured-window time | — | ratio 0.9985, MAD 0.0112 | neutral |
| peak RSS | 51,396,608 bytes | 51,462,144 bytes | +0.13% |
| managed lets reused | 0 | 512 | +512 |
| managed lets reconstructed | 513 | 1 | -512 |

The 1,536 removed allocations and releases are exactly three of each per
reused managed Let. Parent and candidate post-Perceus artifacts were
byte-identical with SHA-256
`e630dcfdd127bff65eb4e3cdb7edcdc67c0b5a37ca17f582b9348f710c3b532f`.

The unchanged default linear fixture is a regression control. It reused 64 of
65 managed lets and reduced allocations from 208,764 to 208,572 (-0.09%) and
releases from 199,024 to 198,832 (-0.10%). Its paired time ratio was 0.9971
with MAD 0.0155, and peak RSS changed by -0.03%. Its post-Perceus artifact
remained byte-identical with SHA-256
`9172d24911c47031a114bc9c69f1be4f71a08af69652c9243e744d2172e94308`.

These measurements establish a deterministic allocation win but no measurable
timing win by themselves.

## Compiler self-check

The immediate-parent and candidate compilers each compiled the current
`blorp/src/main.brp` through Perceus. Both produced a 313,994,294-byte Core
snapshot with SHA-256
`0849271db8b1517be484458da38a382999bca1a94c1c1f66f963e48431f5be60`.

Single wall-clock observations were 45.25 seconds for the parent and 44.74
seconds for the candidate. They are recorded only as a large-input smoke check,
not as a performance estimate.

## Verification

- production compiler rebuild passed;
- `perceus.brp` and `blorp/src/main.brp` type-check passed;
- all 345 focused Core Perceus tests passed;
- all 66 Perceus benchmark contract tests passed;
- `scripts/compiler-check --changed` passed its focused suite and sanitizer;
- final code review reported no findings; and
- post-Perceus Core was byte-identical on the transfer, default, and compiler
  self-compilation inputs.

## Next boundary

The next useful slice is exact change-aware reporting from opaque call and
aggregate normalization. Most non-immortal managed RHS values pass through
those helpers, so managed-let composition must remain conservative until their
source identity is explicit.
