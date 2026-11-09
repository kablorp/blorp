# Pure JSON codec, 2026-11-08

Fourteen ordinary callbacks pass, including independent depth-96 and width-256
oracles. ASan/UBSan with strict memory checks passes: 3,773 allocations and
releases, zero leaks. Duplicate-key and surrogate-boundary mutations each cause
named callback failures; both were restored. The pristine baseline rejects the
missing json module. Numbers retain validated exact lexemes; decoded duplicate
keys and invalid surrogate pairs are rejected.

Production: 492 lines in the new module. Tests: 324 lines in the new suite
plus one registration. Documentation: 52 added lines.

## Matched measurements

Base source: `329e273772bb1002a031ab035e11985d90e3897f` (the later
`163da8a37` changes only the process plan). Candidate source is the isolated
`/Users/keithphilpott/.codex/worktrees/lsp-json-foundation/blorp` tree; source hashes before/after match.
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
| Fixed instructions, median of 3 | 36,946,586,465 | 36,956,393,890 | +0.026545% |
| Own-source allocations | 13,544,664 | 13,546,320 | +0.012226% |
| Own-source instructions | 36,946,586,465 | 36,968,203,498 | +0.058509% |

All eight fixed-input outputs are byte-identical, SHA-256
`15819f0364ecaac3a58c53b9f790b933b21424f6bd3f86dd5327d6f001a18b20`.
Own-source normal and diagnostic output reproduce candidate C, SHA-256
`90aa9a201d5307030c3aeb7883c8df42b5247d7386812bc592f084201127c420`. All strict allocation/release counts
balance with zero leaked objects or bytes.
Normal binary: `686fc80a5dcb2ddd520b7fe433c4e348836035b612e3792f01b0d5a09d472044`;
diagnostic: `c6dc800bc564d34984a0c12c445ef5823c98d9ad73f84fde68c178a965064ae8`.

## Reproduction and limits

```sh
python3 blorp/build/roadmap-coordination/measure_slice.py \
  /Users/keithphilpott/.codex/worktrees/lsp-json-foundation/blorp json
```

Use a new output label: retained directories cannot be overwritten. Raw
samples, emitted C, source manifests and binary hashes are under
`/Users/keithphilpott/.codex/worktrees/list-roadmap-continue/blorp/blorp/build/roadmap-coordination/json/`;
shared baseline provenance and frozen hashes are in the sibling `baseline/`.
The script retains exact compile/time commands and flags. Worker focused and
mutation evidence is under `/Users/keithphilpott/.codex/worktrees/lsp-json-foundation/blorp/build/lsp/`.

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
