# Union lookup index simplification (2026-10-03)

`AcceptedUnionLocator` was a public one-field `struct` containing only
`union_index: Int`. The union authority stored it in a name-keyed dictionary,
then immediately read that field in every consumer. Its canonical/builtin
fallback also mapped `Option[Int]` to `Option[AcceptedUnionLocator]` on each
lookup. This cut removes the wrapper, stores the `Int` directly, and returns
`Option[Int]` from the private lookup. It does not change the authority's
lookup precedence or union payload representation.

The existing `test_accepted_union_authority.brp` suite covers local,
imported, canonical, and builtin lookups; it passed 10/10 after the edit.
No new user-visible behavior is intended.

## Matched stage-2 self-compile

Both samples used the same worktree, frozen input revision
`1a767d0c798457f57cdb4c697a17e3c3f3132774`, Apple clang 21,
`cli=-O2 runtime=-O2`, eight-way split, and five serial retired-instruction
samples. The baseline and candidate JSON are retained at
`/tmp/blorp-record-locator.eJersk/baseline.json` and
`/tmp/blorp-record-locator.eJersk/candidate.json`.

```bash
env BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --stage2 \
  --input-rev 1a767d0c798457f57cdb4c697a17e3c3f3132774 \
  --samples 5 --label record-locator-baseline \
  --output /tmp/blorp-record-locator.eJersk/baseline.json \
  --keep-output /tmp/blorp-record-locator.eJersk/baseline.c

env BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --stage2 \
  --input-rev 1a767d0c798457f57cdb4c697a17e3c3f3132774 \
  --samples 5 --label union-index-direct \
  --baseline /tmp/blorp-record-locator.eJersk/baseline.json \
  --output /tmp/blorp-record-locator.eJersk/candidate.json \
  --keep-output /tmp/blorp-record-locator.eJersk/candidate.c \
  --require-identical
```

| Measure | Baseline | Candidate | Difference |
| --- | ---: | ---: | ---: |
| Typed-frontend allocations | 34,376,002 | 34,277,290 | -98,712 (-0.29%) |
| Total allocations | 213,959,064 | 213,860,352 | -98,712 (-0.05%) |
| Retired instructions, minimum | 204,089,670,151 | 204,074,763,850 | -0.01%; ranges overlap |
| Peak RSS bytes | 2,147,106,816 | 2,150,924,288 | +0.18%; noisy |

All other per-phase allocation deltas were identical. Both compilers
emitted 79,859,038 bytes of frozen-input C with SHA-256
`5372009292908af0dbc1b2112c4db97786afdc02ec99eda87b41f6361a26509d`.
The baseline and candidate stage-2 normal compiler SHA-256 values were
`def04925cebbe43eb9513894e1ee434116fb80901faaf5d8e09b352e5e679cb2`
and `4a502bfbbd584b4a7b3d4b955d503083582385fbae70ab9faf3c658af67bb31b`.
The first pair used different stage-1 generator binaries after `bin/blorp`
was rebuilt, so it was not sufficient by itself to attribute the difference.
The same-generator control below removed that ambiguity. The overlapping
instruction ranges do not support a speed claim.

## Same-generator control

The generator binary was frozen at
`/tmp/blorp-record-locator.eJersk/generator-candidate` (SHA-256
`ed47f555df84784f0eda83da66968fac3ed266801b6f984ba2aa35638c16a3f3`).
In the **same worktree**, the source module was first restored exactly to
`main` (empty file diff; baseline source SHA-256
`03d1bec53af93fe7fe8192799e5b9530cdf7c4df6f78f33ee6eb89c6ca1709dd`),
then reapplied to the exact candidate diff (diff SHA-256
`477c0ebab54b2c39906e46eb7a34d5a9398cb4ae9bc59673449bcb8e127c6149`,
candidate source SHA-256
`d0bf6058af3973741373582f99e2779cbd764775e4174f28f0fc3fea498eb53b`).
Each state was built with `BLORP_CLI_C_OPTIMIZATION=-O2 make`, then passed
through that same frozen generator:

```bash
env BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/build_stage2_compiler \
  --generator /tmp/blorp-record-locator.eJersk/generator-candidate \
  --generated-c /tmp/blorp-record-locator.eJersk/baseline-same-generator.c \
  --diagnostic-output /tmp/blorp-record-locator.eJersk/baseline-same-generator-diagnostic \
  /tmp/blorp-record-locator.eJersk/baseline-same-generator

# After restoring the candidate source and rebuilding bin/blorp:
env BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/build_stage2_compiler \
  --generator /tmp/blorp-record-locator.eJersk/generator-candidate \
  --generated-c /tmp/blorp-record-locator.eJersk/candidate-same-generator.c \
  --diagnostic-output /tmp/blorp-record-locator.eJersk/candidate-same-generator-diagnostic \
  /tmp/blorp-record-locator.eJersk/candidate-same-generator
```

Each binary pair was measured from this worktree with
`--skip-build-check --input-rev 1a767d0c798457f57cdb4c697a17e3c3f3132774
--samples 5`; the baseline used `--compiler .../baseline-same-generator
--diagnostic-compiler .../baseline-same-generator-diagnostic`, and the
candidate used the corresponding `candidate-same-generator` paths plus
`--baseline .../baseline-control.json --require-identical`.

The controlled raw measurements are
`/tmp/blorp-record-locator.eJersk/baseline-control.json` and
`/tmp/blorp-record-locator.eJersk/candidate-control.json`. Both compilers
report `compiled_by: self-1adc96092c6a` and `cli=-O2 runtime=-O2`, and
compile the same frozen input from the same cwd. Their shared native runtime
objects have SHA-256 `93d0ac919a7d792c61700225e6b318de4e2e4e456bf99a1e1e85c378de4a3c99`
(normal) and `7e17285aa63abdd41cef8f48f1a242f400d9dcb7407739ccb0ffe7959f1fe54d`
(diagnostic). The controlled measurement JSON records
`c_optimization: -O0 (default)` because that environment variable was not
set for its compile-to-C workload; the compared compiler binaries themselves
were built at `-O2` in both arms. They reproduce
**213,959,064 → 213,860,352 total allocations**
and **34,376,002 → 34,277,290 typed-frontend allocations**: exactly
98,712 fewer in both comparisons. All later phase deltas remain identical.
Their frozen-input C remains byte-identical at the hash above. Controlled
retired-instruction samples overlap (baseline
204,140,547,032–204,584,337,649; candidate
204,004,919,171–204,606,400,216). The generated *compiler-body* C changes
as expected: baseline SHA-256
`8d7a48357dab389986dea6d53bf3458c42968fb7f64a808319cc00d5e871c514`,
candidate SHA-256
`f663bb5de6b725487affbc40033b6818029f4c746cd7e35d8ada61877ea02c9a`.

## Gates

The owning suite passed 10/10 before and after the reversible control.
`scripts/compiler-check --changed --base main` passed 14/14 across the
owning union-authority and semantic-catalog suites. The serial broad gates
passed `compiler-blorp` 6,353/6,353, leak 1,154/1,154, and
`compiler-blorp-sanitize` 5,557/5,557. `make hygiene-check` passed.
After restoring the exact candidate source diff, the `-O2`
`scripts/compiler-fixpoint` emitted 77,912,122 bytes of C with SHA-256
`f663bb5de6b725487affbc40033b6818029f4c746cd7e35d8ada61877ea02c9a`
at stages 1, 2, and 3. Fixpoint artifacts are retained under
`/tmp/blorp-record-locator-fixpoint.qY98Uo`.
