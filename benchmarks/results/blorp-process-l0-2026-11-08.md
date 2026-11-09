# Shared I/O errors, process L0, 2026-11-08

The affected selection passes 125 callbacks in 18 active suites / 12 groups.
The four new ordinary callbacks pass ASan/UBSan strict checks with 154
allocations/releases and zero leaks. Mapping and phrase mutations each fail
one named callback; both were restored. The pristine baseline rejects the
missing internal decoder. All 14 native codes, unknown-code boundaries and
existing phrases retain their values.

Production: +161/-143 (304 gross / +18 net). Tests: +174/-62
(236 gross / +112 net).

## Matched measurements

Base source: `329e273772bb1002a031ab035e11985d90e3897f` (the later
`163da8a37` changes only the process plan). Candidate source is the isolated
`/Users/keithphilpott/.codex/worktrees/process-api-resume/blorp` tree; source hashes before/after match.
The baseline self-built compiler generated candidate C. Apple clang 21.0.0
links the same C with `-std=c11 -O0 -lm -lpthread`; normal/diagnostic modes
differ only by `BLORP_MEMORY_DIAGNOSTICS=0/1`.

Three serial normal samples alternate baseline/candidate against frozen
baseline compiler source and library, with the same cwd and argv paths.
Instruction comparisons use medians. Allocation counts come from separate
strict diagnostic runs. Own-source has one normal observation and one strict
run, compared with that pair's baseline; no latency speedup is claimed.

| Workload | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed allocations | 13,544,664 | 13,544,664 | +0% |
| Fixed instructions, median of 3 | 36,920,853,402 | 36,930,156,195 | +0.025197% |
| Own-source allocations | 13,544,664 | 13,545,855 | +0.008793% |
| Own-source instructions | 36,920,853,402 | 36,929,710,040 | +0.023988% |

All eight fixed-input outputs are byte-identical, SHA-256
`15819f0364ecaac3a58c53b9f790b933b21424f6bd3f86dd5327d6f001a18b20`.
Own-source normal and diagnostic output reproduce candidate C, SHA-256
`ed43acf0a766e38b5ff97f1bf4de8fe2106e32b8970cfa2127b5c0f40bf3f2ce`. All strict allocation/release counts
balance with zero leaked objects or bytes.
Normal binary: `9887c25c2d73913c36ac05a58dd6a629ba190c5be590cd8fe1015e3f326457b8`;
diagnostic: `cac4fcce4d66097ca020392ee2e2f53b776dbebed31a2b033e2c19c3b02a1af4`.

All four measured changes pass the original +0.2% ceilings. Public errors
and their formatting now belong to io; fs and the internal decoder import
them without a cycle. This follows the user's explicit ownership decision.

## Reproduction and limits

```sh
python3 blorp/build/roadmap-coordination/measure_slice.py \
  /Users/keithphilpott/.codex/worktrees/process-api-resume/blorp process-l0
```

Use a new output label: retained directories cannot be overwritten. Raw
samples, emitted C, source manifests and binary hashes are under
`/Users/keithphilpott/.codex/worktrees/list-roadmap-continue/blorp/blorp/build/roadmap-coordination/process-l0/`;
shared baseline provenance and frozen hashes are in the sibling `baseline/`.
The script retains exact compile/time commands and flags. Worker focused and
mutation evidence is under `/Users/keithphilpott/.codex/worktrees/process-api-resume/blorp/build/process-roadmap/`.

Focused behavior, sanitizer and cost evidence is followed by the combined
local qualification below. Four-platform branch CI passes.

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
