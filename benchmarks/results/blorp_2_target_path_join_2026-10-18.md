# Ordinary target path.join: fixed FEATURE acceptance

Implementation and validation are complete; coordinator owns final review, commit and landing.
Frozen B is accepted main `af92d13708736bde34c164858d7323875fb216aa`.
Measured code/tests/library patch is `fc65fe65c1fe1f928fc6b2680128865759b8f4e21f8e6391ee5beffe352fc58b`.
Final maintained status/report edits are separate from those measured bytes.
Main advanced only through plans to `ca458fad441175dd471253b4ec89553364aac900`; B never rolled.
The [owning plan](../../blorp_2/TARGET_PATH_JOIN_PLAN.md) and [seven-path contract](../../blorp_2/ROADMAP.md#seven-shell-and-path-functions) retain scope and ceilings.

## Behavior and ownership

The ordinary30-line target module exports pure `path.join(String, String) -> String`.
Absolute child wins, then empty base; otherwise retain/add `/`. Empty child adds/preserves a trailing separator.
UTF-8, embedded NUL, backslashes, dot/parent components and separator runs preserve their counted bytes.
There is no normalization, filesystem access, opaque Path, new primitive, prelude import, compiler/runtime/backend edit or source migration.
At most two existing concatenations run. Emitted C borrows inputs, acquires a returned child and owns fresh concatenations; intermediate and caller cleanup occur after use, with shared operands surviving.
Native sanitizer success is not an executed native ARC occurrence-total measurement.

## Correctness and oracle sensitivity

| Gate | Actual result |
| --- | --- |
| Original missing-module TDD at8c5, before implementation | Both library callbacks failed for the configured target path module, not host fallback/syntax |
| Fresh accepted-M2 composition unit |2 named callbacks PASS; actual module loading and pure caller checking |
| Full unit/runtime/grammar |3315 callbacks/277 suites PASS,0 FAIL; exit0, empty stderr |
| Full existing e2e route |478 outer callbacks PASS,0 FAIL;19 path argv cases+1 counted-NUL/alias case nested under2 callbacks |
| Focused native | Strict C11/O0/Wall/Wextra/Werror/pedantic ASan+UBSan/no-recovery links and3 exact-byte normal-main runs PASS |
| Current three mutation/restoration pairs |18 compiled/native calls;3 predicted oracle failures then3 freshly compiled restored greens |

The three ordinary-source faults disable absolute-child precedence, disable the trailing-separator test, and remove the inserted slash.
Their named existing normal-main oracles reject `/library/base//module.brp`, `directory//module.brp`, and `/library` (all with LF), respectively; restored expected bytes pass.
Each module restoration occurs unconditionally before result interpretation. All6 strict compiles have positive balanced counts/zero leaks; all6 sanitizer links/native runs are clean. Restored C matches the validated original exactly.
Functional c04/ROOTstd91 observations are22,217/23,531 allocations; they are a different producer/path role from the FEATURE observations below and are not mixed into its ratios.

## Frozen roles, corpus and method

All40 compiler source files are identical B/C, aggregate pin `b45850b85e008c6476c57c2e6a31891ca3bd6574220f340855da5afd1cc404d6`.
Complete B/C libraries contain9/10 files including README; only the new path module changes executable library code.
The current corpus is503 compiler invocation states:501 shared+2 C-only, including383 shared successes/118 rejections, absent/preserved outputs and malformed CLI options.
The478 physical fixture files (including helpers),150 generated dependencies,478 e2e callbacks and20 path native rows are separate denominators.
The retained FT collectors ran once, serially and quietly:1004 strict+3012 alternating normal+8 supporting proxy calls=4024. No rebuild, warmup, retry, filtering, resampling, cap change or refreeze occurred.
Normal order is B1,C1,C2,B2,B3,C3; retain all3 positive retired-instruction observations and compare their minima. Each shared state and the original construction proxy independently has hard+3% allocation AND normal min3 instruction gates; all tighter absolute caps remain.
One physical canonical CWD/source/input/library/output boundary is used for both variants. Library installation occurs outside measured intervals, validating the complete known map before switching the one pinned scratch path module.

| Role | Exact identity |
| --- | --- |
| Original producer/normal proxy | `34ac1a913c79fc14130c77fe4339f24885a2fa65f1d25fc4b873b627e10e1f33` |
| Original diagnostic proxy | `be31a5a3a070deef54707d8676a7c6157042484f40d0424dd5fb46835c09ff93` |
| Explicit original host std tree | `090ed68c5bd688cb8e2197c72bc572e4dc32e6d7`;91 members/original598 pins verified |
| Unmodified target-compiler C | `3d3a5f75896062d02e67ce8497eafda23bd7b048d2404629f4dd0bbc43a8c6bf` |
| Shared B/C normal O0 diagnostics0 | `5847e3bddde4a39553e990b531fe40be6cdc8e613eb91ce0edc0d0a19525181d` |
| Shared B/C diagnostic O0 diagnostics1 | `1bfa1260ca4c0e7a6dce7c813af5009e8a81ff61324f97defb7ed24c17cb23cc` |

The one generation/two links passed; both links retain identical90 inherited warnings (28 pointer/integer,59 equality-parentheses,3 const-List),0 errors. c04/ROOTstd91 remains functional-only/read-only.
Target strict uses positive balanced allocations/releases and zero leaked objects/bytes. Normal memory/leak/CC controls are unset before `/usr/bin/time -l`.
Proxy allocation metric is the unique schema1 `artifact_construction_complete total_allocations`, MEMORY_STATS=1/leak unset/status0, with48 complete raw checkpoint records per diagnostic. It is not exit TOTAL, host strict-leak success or target self-compilation; it does not execute the new path bodies.

## Actual costs and identities

| Metric | B | C | Verdict |
| --- | ---: | ---: | --- |
| Every501 shared allocation counts | Equal per state | Equal per state |0% each, PASS |
| Largest shared normal min3 increase, i0415-absent |33,690,015|33,766,828|+0.2280%, PASS |
| New arguments fixture allocations/min3 | No B observation |22,242 /54,289,774|205,000 /600,000,000 caps, PASS |
| New counted aliases fixture allocations/min3 | No B observation |23,556 /55,753,447|205,000 /600,000,000 caps, PASS |
| Original construction checkpoint allocations |24,240,232|24,240,232|0%, PASS |
| Original proxy normal min3 instructions |21,576,469,163|21,546,576,906|Hard+3%, PASS |

All503 state verdicts and the proxy pass independently. Identical code/workloads explain the unchanged allocation work; instruction variation is a gate observation, not a speedup claim.
All shared complete C/status/stdout/diagnostic/output-state bytes match; normal output matches strict. New target C also matches the native-validated functional C. Every target strict call has zero leaks.
Before/after source/library/corpus/tool/binary maps,2775 static files,816 setup artifacts and all598 original pins verify. No whole-process host leak exception is extended to target/native calls.
This FEATURE acceptance grants no SOURCE cumulative/R0 waiver or epoch change. Historical89/8a observations and unavailable old M2 pilots/raw remain historical; these are new functional/setup/cost artifacts.

## Retained evidence and physical scope

Owned raw root is `/Users/keithphilpott/.codex/worktrees/target-path-join-m2/blorp/build/path-join-m2/`.
`cost-preparation-af92-01/` holds the complete503 cases/config/recipes/maps; `cost-af92-01/` retains every4024 command/status/stream/time/C/output and all source/library materializations.
Freeze SHA `aee08f113cad5e58ffc03de5ab5619e94437e4e4d1b79980bbdd69e28e6e5721`; campaign receipt `ecba904ca2ddf6d21ebdaca7285cf02576898cfa25cd762b25ad928d1a2d9278`.
Final23,763-entry raw map SHA `86327fd71cc7c18fa69d33071c399f3bdb183a3b9ecc82ff677887588b53ba8e`; final pin receipt `0558bd86e8f3bf57e17c13a9edb14663b140d6786963e99f0409b1c1f6414a96`.
`functional-m2-01/` receipt is `7ff60f961c4ae319c2eb312acefe7620924df05978cd157d7d76386703ccd8c9`; mutation receipt is `a89200640c494ae70ad12609b76d9b1fba61682fcfad5b35ed931c00996b8640`.
Root already byte-verified functional/mutation copies under `ROOT/build/bootstrap-evidence/path-join-m2-2026-10-18/`; root retains/verifies the new raw before any archival. No evidence tree was archived.
Production is30 gross/+30 net (cap60/+60); tests133 including two fixtures/36 lines (caps250/two fixtures50). Owning plan22+README3 API/design lines remain25; this benchmark evidence report is counted separately. No coverage or code was compressed/deleted.
