# Integer model L0, 2026-11-08

L0 passes its unchanged cost caps. It replaces IntType with
IntegerType(IntegerFormat) in both compiler models, with only Int64Format,
and carries that format through all eight integer operations. Exhaustive
phase-owned projections preserve existing primitive identities, literal
range rules, hashes, List names, C types and helper selection. No UInt8,
inference, library or native behavior was added.

Local qualification and independent code/test reviews pass. Four-platform
branch CI passes; the combined evidence is recorded below.

## Source and toolchain

- Base: `329e273772bb1002a031ab035e11985d90e3897f`.
- Candidate: `/Users/keithphilpott/.codex/worktrees/uint8-integer-model/blorp`.
- Apple clang 21.0.0 (`clang-2100.3.34.2`), arm64-apple-darwin25.6.0.
- Normal/diagnostic binaries link the same candidate C with `-std=c11 -O0`,
  `-DBLORP_MEMORY_DIAGNOSTICS=0/1`, `-lm -lpthread`.
- Source and library hashes match before/after the serial runs. Candidate
  C SHA-256: `3e17f67c9522856830148f165c99c893a2406a16763c43a7ac20d8a308014d33`.
  Normal binary: `917a0f3f63a8588ef8d00179aed19c91f234c6aa2c54945c534b1425f848f48c`;
  diagnostic: `36b6f9be4e42e3f9429272e2af0924c4af86a04ee8ccc6f671b24a437a576211`.

Production: +301/−164, **465 gross / +137 net** lines across 13 files.
Tests: +441/−179, **620 gross / +262 net** across 38 files, including the
mechanical migration and nine new callbacks. The coordinator corrected the
readable, canonically formatted production allowance to 550 gross / +180 net
under the owner's standing delegation; performance caps did not change.

## Measurements

The current baseline compiler generated candidate C. Fixed-input runs compile
the immutable baseline compiler source and library, using the same cwd for
both binaries. Three normal samples alternate baseline/candidate order;
instruction comparisons use each side's median. Strict diagnostic runs
measure allocations separately. Own-source has one normal and one strict
diagnostic run, compared with the matched baseline. These are direct counts,
not an elapsed-time speed claim.

| Workload | Baseline | Candidate | Change | Ceiling |
| --- | ---: | ---: | ---: | ---: |
| Fixed allocations | 13,544,664 | 13,544,664 | +0 | +0 |
| Fixed instructions, median of 3 | 36,939,715,097 | 36,944,809,680 | +0.013792% | +0.1% |
| Own-source allocations | 13,544,664 | 13,572,804 | +0.207757% | +0.3% |
| Own-source instructions | 36,939,715,097 | 37,001,827,610 | +0.168146% | +0.3% |

All strict counts are balanced, with zero leaked objects or bytes. The
earlier root-cwd baseline count of 13,544,652 is not used for comparison:
the paired same-cwd baseline is 13,544,664.

Fixed baseline instructions: 36,965,661,847 / 36,939,715,097 / 36,933,239,346.
Fixed candidate instructions: 36,961,354,714 / 36,944,809,680 / 36,935,517,444.
All six normal and two diagnostic fixed-input C outputs have SHA-256
`15819f0364ecaac3a58c53b9f790b933b21424f6bd3f86dd5327d6f001a18b20`.
Both own-source modes reproduce the candidate C hash above. The minimum-based
cross-check is
+0.006168% fixed and +0.185709% own source; it is retained separately, not
used as the primary aggregation.

## Behavioral evidence and limitations

The affected active selection passes **322 callbacks / 32 suites / 8 groups**
with strict leak checks. A rebuilt candidate then passes **65 callbacks / 6
suites** after source restoration. Pinned-seed builds, changed-file canonical
format checks and `git diff --check` pass.

Six mutation experiments produce named runtime callback failures for range
fitting, primitive projection, List keys/suffixes, type hashes, parsed operation
selection and designated Boolean identity. All mutations were restored. The
pristine baseline rejects the first new suite's missing IntegerFormat import.

Two changed deferred suites were mistakenly included in an exploratory
selection: emit/test_managed_union has pre-existing duplicate imports, and
specialize/test_managed_union lacks map_err. A later unchanged deferred
test_runtime_requirements selection lacks String methods. Their failed logs
are retained; they remain deferred and receive no PASS credit. They were not
fixed or removed. No full-gate or platform claim follows from the focused run.

## Reproduction and raw evidence

The coordinator ran, serially:

```sh
python3 blorp/build/roadmap-coordination/measure_slice.py \
  /Users/keithphilpott/.codex/worktrees/uint8-integer-model/blorp uint8-l0
```

The script requires a new output label and a fresh serial lease; do not rerun
over retained evidence. Its compile command is `BINARY compile SOURCE
--library-root LIBRARY -o OUTPUT`, with `/usr/bin/time -l` for normal runs and
`BLORP_LEAK_CHECK=strict` for diagnostic runs.

- Coordinator raw root:
  `/Users/keithphilpott/.codex/worktrees/list-roadmap-continue/blorp/blorp/build/roadmap-coordination/`.
  `baseline/provenance.json` and `baseline/frozen-hashes.json` own baseline
  provenance; `uint8-l0/results.json`, `source-before.json`, `source-after.json`,
  `*-1/2/3.stderr`, `*-diagnostic.stderr`, `own-*.stderr` and the emitted C
  retain all observations. `measure_slice.py` retains the collection commands
  and corrected median aggregation; primary medians were recomputed from the
  unchanged retained raw samples after collection.
- Worker raw root:
  `/Users/keithphilpott/.codex/worktrees/uint8-integer-model/blorp/build/uint8-l0/`.
  `line-counts.json`, `source-hashes.json`, `FORMAT_SITES.md`, `affected-active.log`,
  its suite list, `final-focused-2.log`, `mutation-*.log` and
  `mutation-results.json` retain focused evidence. `affected-2.log` and
  `final-focused.log` retain the deferred-selection failures.

Recommendation: accept the bounded L0 implementation and unchanged cost caps,
with four-platform branch CI also passed.

## Combined landing qualification

The integrated integer L0, JSON and shared-I/O tree passes
`make -C blorp test INSTRUCTION_CHECK=on`: **1,327 component callbacks in
157 suites / 22 groups**, and **900 native/runtime callbacks / 14 groups**.
Bootstrap shell checks pass **38/38**. `scripts/blorp-fixpoint --prove`
passes compiler C identity, **687/687 fixture pairs**, and the same component
and native selection under the self-built compiler. All 1,374 fixture exit
files independently contain only success or intended rejection (0/1).
Strict accounting records balance with zero leaks; no resource exceptions
were used. Deferred suites and broader native coverage receive no PASS credit.

The first full run exposed one stale expected location after splitting a
fixture import: line 13 became 14. Only that expected line was corrected;
message, help and column stayed exact. The original failure and corrected
green run are both retained. All 1,192 source/test/tool inputs stayed unchanged
through the corrected gates.

Evidence: coordinator `blorp/build/roadmap-coordination/integration/RESULTS.json`,
`make-test.log`, `make-test-corrected.log`, `bootstrap.log`, `fixpoint.log`,
source manifests and `fixture-exit-audit.json`; full fixpoint artifacts remain
in `blorp/build/roadmap-coordination/integration/fixpoint-first3/`. Tested staged tree:
`a76917735c2dbbe56fa7df6de5f3c1c360da98ed` (subsequent edits are reports/index
status only). Four-platform branch CI passes for commit
`23f25d7d33cc987dcbd5d2d91d8b65b10802178e`:
[qualification run](https://github.com/kablorp/blorp/actions/runs/42558963381).
Linux x64 Clang/GCC, Linux ARM64 Clang and macOS ARM64 Clang all pass.
The three implementation commits are published on origin/main.
