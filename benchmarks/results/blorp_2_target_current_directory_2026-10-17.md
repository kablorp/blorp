# Target current-directory costs, 2026-10-17

Frozen baseline: main `72164f17a21d8e375efceb77503b92318e97340d`. All 483 target cases pass: shared allocations are unchanged, worst normal min3 growth is +0.552871%, and both C-only cases meet 205000-allocation/600M-instruction caps.

| Host source-to-C proxy | B | C | Change |
| --- | ---: | ---: | ---: |
| TOTAL allocations | 23224178 | 23328551 | +0.449415% |
| Normal min3 instructions | 20631844365 | 20734800215 | +0.499014% |

The separate O2 host pair is pinned in the raw packet; the proxy is not target self-compilation. All six normal outputs match their diagnostic and retained same-variant producer C. Both unchanged +5% ceilings pass.

Host strict runs remain failed with exit 99: B reports 512964 leaked allocations/34890725 bytes; C reports 515331/35048857. The user accepts this known HOST-only bootstrap limitation. Pilot/native memory gates remain strict; original R0/3% policy is unchanged.

Validation: 2604 unit + 229 runtime + 179 grammar reported checks (including nesting), 458 e2e cases, 13 native sanitizer cases and six effective/restored mutants. The [plan](../../blorp_2/TARGET_CURRENT_DIRECTORY_PLAN.md) reconciles exact LOC and the accepted test ceiling.
Raw commands, full hashes and original reports: `build/target-current-directory/cost/` (`corpus/costs.tsv`, `proxy-completion/summary.json`, `proxy-pair.json`). No observation was rerun or excluded; original parser-stop history and both host memory failures are preserved.
