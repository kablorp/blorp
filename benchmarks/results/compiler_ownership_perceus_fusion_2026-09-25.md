# Ownership-contract annotation fused into Perceus

Date: 2026-09-25

## Change and boundary

The normal late-Core pass resolves global values, infers ownership contracts
once, and annotates each `UserCall` in Perceus's existing call rewrite. The
standalone `ownership_contracts` and `perceus` passes remain the internal
snapshot and differential-control path. A request to observe either pass
selects that path; the CLI's named `perceus` dump also selects it. The CLI
does not expose `ownership_contracts` as a public stage.

The pass only fuses call-site annotation into Perceus. Ownership equation
collection and solving are unchanged. For early Perceus contract queries,
constructor contracts take priority; inferred, fixed, and direct-wrapper
contracts come from the solved environment; explicit call-site contracts use
the source call's existing `consumed_args`. The focused differential fixture
covers each case, unresolved identity, a preexisting explicit index merged
with inferred consumption, and a call whose argument is rewritten by Perceus.

## Measurement

Both compilers used Apple clang 21.0.0, bootstrap `dev-6cbacd58cd47`,
`cli=-O2 runtime=-O2`, and input revision
`555b6c75473ea6303df338194e933341e26801d9`. The control compiler was a
fresh clean build at that revision, SHA-256
`0dce54ca5a5b8d572ddad507fb6bba1c32a618cbe8d654010b12de00f5fce981`.
The candidate was a fresh dirty build of that revision plus this change,
SHA-256
`cd18e3fadea194af75245ade013326ca75b9c698648f3be631a99648c10862bd`.
Both builds reported `FRESH`. Each row below uses one retained instruction
sample; wall time is excluded from acceptance.

```bash
benchmarks/self_compile_measure --program self --samples 1 \
  --input-rev 555b6c75473ea6303df338194e933341e26801d9 \
  --label ownership-fusion-candidate-full \
  --baseline /tmp/core-rewrites-base-full.json --require-identical \
  --output /tmp/core-ownership-fusion-candidate-full.json \
  --keep-output /tmp/core-ownership-fusion-candidate-full.c
```

| Full self-compile metric | Control | Candidate | Change |
| --- | ---: | ---: | ---: |
| ownership contracts + Perceus allocations | 48,414,312 | 47,779,038 | -635,274 (-1.31%) |
| whole-compile allocations | 210,474,100 | 209,838,825 | -635,275 (-0.30%) |
| whole-compile retired instructions | 169,207,269,670 | 168,766,632,130 | -440,637,540 (-0.26%) |
| peak RSS bytes | 2,138,947,584 | 2,141,192,192 | +0.10% |

The ownership and Perceus measurements are treated as one span because
fusion changes their boundary. The 635,274 allocation reduction in that span
is also present in the whole compile; it is not a cost shifted into Perceus.
Emitted C was byte-identical, 83,580,905 bytes, SHA-256
`772a2159d3df1611954d96b071c456312a6bcb6100a1bdf468b984a75d7a4eab`.
Both compiles completed without diagnostics.

The earlier small input (`--program small --samples 1`) showed 19,618 to
19,348 combined allocations (-270, -1.38%); whole allocations 1,513,212 to
1,512,941 (-271); retired instructions 1,267,976,308 to 1,269,918,972
(+0.15%). Its emitted C was byte-identical, SHA-256
`b14e002cf83bd89ace4c862a0cf0137f36b21cde683a993671641f0c2e3b096a`.
The small instruction delta and single samples limit any speed claim; the
full input establishes no instruction regression in this comparison.

## Retained artifacts and validation

- Full control JSON: `/tmp/core-rewrites-base-full.json`, SHA-256
  `13fc9d91a0785d5a6de62c2f9f95521ee8576da3c663cdff3ea6ee52e9c08a39`.
- Full candidate JSON: `/tmp/core-ownership-fusion-candidate-full.json`,
  SHA-256 `bcddba454f788f6ff6a31895a5710519ad875248152f184129f40705c97e40a6`.
- Full control/candidate emitted C: `/tmp/core-rewrites-base-full.c` and
  `/tmp/core-ownership-fusion-candidate-full.c`, both with the C hash above.
- Small control/candidate JSON: `/tmp/core-ownership-fusion-base-small.json`
  (SHA-256 `f67fe8243fb80b15aa2e68c7fe21805ea103472d3a6bf10171afb311cc2baf13`)
  and `/tmp/core-ownership-fusion-candidate-small.json`
  (SHA-256 `106242f79d892e8ee282d4eb85e52ff7bdd8ba902190a0dcaa203b9659333060`).
- The focused test passed 375/375 Perceus and 52/52 pipeline tests. The
  pre-change differential test first passed for contract-query behavior, then
  its direct final-Core parity assertion failed before implementation and
  passed after it. The CLI `perceus` dump matched the frozen control Core
  byte-for-byte, SHA-256
  `b3477453677cc91dc33cb4cc7fa3577977cf6df3eb27835882f5e19ae89d91ba`.
- `scripts/compiler-check --changed` passed 2,572/2,572 tests across four
  sources, two suites, and one sanitizer special check. The standalone
  `scripts/test compiler-core-sanitize` passed 2,145/2,145 ASan+UBSan tests.
  Logs: `/tmp/core-ownership-fusion-compiler-check.log` and
  `/tmp/core-ownership-fusion-sanitize.log`.

## Decision

Accept the bounded fusion. It preserves the measured output and the internal
ownership/Perceus observation boundaries while reducing combined and total
allocations on both retained inputs. The full-input instruction sample also
improves; with one sample, it is evidence of no material regression rather
than a precise user-visible latency estimate. Ownership equation collection
remains a separate experiment.
