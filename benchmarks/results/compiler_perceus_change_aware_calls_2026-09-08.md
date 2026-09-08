# Change-Aware Perceus Call Checkpoint

Date: 2026-09-08

## Scope

This checkpoint lets Perceus retain an immediate source `CallExpr` only when
two independent ownership-normalization obligations are proven neutral:

- no consuming argument is a managed direct field alias that requires a
  protective binding; and
- temporary binding cannot materialize an owned closure callee or a borrowed
  argument.

The borrowed-argument proof is deliberately narrow. It accepts only literal,
static-string, variable, and void leaves for which the existing temporary
materializer returns the exact source node and classifies the value as
non-owned. Calls containing projections, casts, control flow, binding spines,
or other result-producing arguments remain on the established conservative
normalization path.

After neutral normalization is proven, recursive insertion starts from the
source callee and argument list. The argument list is updated only when a child
reports a change, and the source call is retained only when every child also
retains its source. Three debug counters partition every call insertion visit
into source reuse or reconstruction. The benchmark additionally requires every
call in the focused neutral workload to reuse its source and requires the
borrowed-call protection fixture to retain at least one reconstruction.

## Direct Perceus measurements

Platform: `macOS-26.6.2-arm64-arm-64bit-Mach-O`.

Candidate timing worker SHA-256:
`39e3cbbf1350f045492e1a73b612cbbf9f58544edee2cd6a986e37f350988068`.
Candidate counter worker SHA-256:
`1c550a3d1c7986c1ad95723ce882f821fd65e06fe6da71b1c644c31d85d5f2ea`.
The immediate-parent timing and counter workers were
`5d8f4395629bc580a1e01f859cc8755a751fd7566bd081bdcbbe7c971b979021`
and
`933f46c2397b65434ea5c9ac9cdec5806fcaf710be98587b602d217cc8cabc73`.

The focused workload contains 512 managed-let transfer workers plus the fixed
sentinel. Its calls have ownership-neutral leaf arguments:

```bash
benchmarks/compiler_perceus_memory \
  --baseline-bridge /tmp/blorp-managed-let-final.XCrqrX/timing/compiler_backend_worker \
  --baseline-counter-bridge /tmp/blorp-managed-let-final.XCrqrX/counters/compiler_backend_worker \
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
| measured-window allocations | 101,173 | 100,136 | -1.02% |
| measured-window releases | 97,062 | 96,025 | -1.07% |
| paired measured-window time | — | ratio 0.9871, MAD 0.0090 | -1.29% |
| paired whole-worker time | — | ratio 1.0001, MAD 0.0156 | neutral |
| peak RSS | 51,314,688 bytes | 51,773,440 bytes | +0.89% |
| calls reused | 0 | 513 | +513 |
| calls reconstructed | 513 | 0 | -513 |

Parent and candidate post-Perceus artifacts were byte-identical with SHA-256
`e630dcfdd127bff65eb4e3cdb7edcdc67c0b5a37ca17f582b9348f710c3b532f`.

The unchanged default linear fixture reused all 65 visited calls. Allocations
fell from 208,572 to 208,431 (-0.07%) and releases fell from 198,832 to 198,691
(-0.07%). Its paired measured-window ratio was 0.9990 with MAD 0.0054 and its
whole-worker ratio was 1.0078 with MAD 0.0086, so timing is classified as
neutral. Peak RSS rose 1.05%. The post-Perceus artifact remained byte-identical
with SHA-256
`9172d24911c47031a114bc9c69f1be4f71a08af69652c9243e744d2172e94308`.

The conservative borrowed-call protection fixture made five call insertion
visits: one source reuse and four reconstructions. This locks the negative path
without treating a serialized-equal reconstruction as source identity.

## Acceptance result

- exact call decisions are mechanically partitioned by debug counters;
- the focused workload reuses every eligible call;
- the ownership-sensitive fixture retains conservative reconstruction;
- the focused direct window has a deterministic allocation and release win;
- focused and default post-Perceus Core are byte-identical to the immediate
  parent; and
- complex ownership-sensitive arguments retain the old normalization path.

## Next boundary

Aggregate construction remains the largest explicitly opaque, frequently used
non-binding family. Its proof must account for direct field-alias retention,
boxed-storage transfer metadata, and recursive field changes. It should be a
separate checkpoint with family-specific counters and fixtures rather than an
extension of the call proof.
