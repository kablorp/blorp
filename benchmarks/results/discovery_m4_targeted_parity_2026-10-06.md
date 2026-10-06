# Discovery M4 targeted corpus runs (2026-10-06)

What `scripts/compiler-new-parity --stop-reason LABEL` (and `--files PATH...`)
saves over a full corpus run, measured on one real stop reason.

## Provenance

Main `a8229c8a4` plus the hand-back-scope change, `bin/blorp` `FRESH` after
`make`, Apple Silicon, serial runs, `-O0` bin/blorp. The machine was shared with
other workers (load average 8 to 16 throughout), so wall times are noisy; the
pairs below were taken back to back. Stop reason: `multiline-call-arguments`
(314 modules in the stored census; the table in
`discovery_m4_stop_reason_census_2026-10-06.md` counts 295 at an older main).

## Where the time goes in a full census (adapter differential, 3,560 files)

| Step | `-O1` (gate) | `-O0` (targeted) |
| --- | ---: | ---: |
| `bin/blorp compile` of the dumper to C (14 MB) | 21 s | 21 s |
| host C compile | 92 s | 15 s |
| run over the whole corpus | 84 s | 203 s |

Output of the two binaries over the whole corpus is byte-identical.

## Before and after

| Run | Wall time |
| --- | ---: |
| full `--stop-census` (before: the only way to see one reason) | 1:53 (back to back with the rows below), 3:27 to 3:54 at higher load |
| `--stop-reason multiline-call-arguments --stop-census`, 314 modules | 0:51, 0:55 (0:42 and 1:17 at other loads) |
| `--stop-reason multiline-call-arguments --adapter-only`, 314 modules | 1:00 |
| `--stop-reason multiline-call-arguments` (token dumps and adapter), 314 modules | 1:45 |
| full `scripts/compiler-new-parity` (the gate, unchanged) | 4:36 |

The targeted census is about half the full one at equal load; its run phase is
25 s of the 42 to 55 s, and one file runs in 3.5 s. The rest is the fixed cost of
rebuilding the dumper (about 21 s to C and 15 s of C compile), which an edit to
the tree parsers always pays because they are inside the dumper. The full census
table is unchanged by the change (same rows and counts as before it).
