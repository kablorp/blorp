# Unary structured-step preparation

Measured 2026-10-18 against accepted main
`782824efbdedbebb2b0f3176d325e69edb42bcbd`. Its production and target-library
bytes equal the functional checkout's `89fdc1bb9` base. The candidate is exactly
that baseline plus the reviewed unary preparation and mechanical consumers;
the carried-binding feature is separate.

Lowered blocks now distinguish execution steps from introduced values. Joins
publish one typed result and empty carried fields; ownership, verification and
emission preserve unary behavior. The experiment tests whether this boundary
fits the prospectively approved hard +3% allocation/instruction ceilings without
changing source acceptance, generated fixture C or diagnostics.

All 3,944 serial calls passed in one frozen epoch, without retries, regeneration,
baseline movement or cap changes. Every absolute fixture ceiling passed.

| Boundary | Allocations B / C | Change | Normal min3 instructions B / C | Change |
| --- | ---: | ---: | ---: | ---: |
| Worst shared allocation input: 64-module direct chain | 78,991 / 79,119 | +0.162% | measured separately for every state | |
| Worst shared instruction input: rejected match block, preserved output | measured separately for every state | | 34,553,255 / 34,914,841 | +1.046% |
| ORIGINAL SOURCE checkpoint | 23,582,063 / 23,722,433 | +0.595% | 20,987,785,374 / 21,099,538,571 | +0.532% |

The complete workload has 492 shared states: 461 absent-output and 31
preserved-output cases, covering 467 fixture files and 150 generated dependency
files. SOURCE ran first (six normal and two diagnostic calls), followed by 984
strict pilot calls and 2,952 alternating normal calls. Each state has three
samples per variant; acceptance uses their minimum independently. Strict calls
require positive balanced allocation/release counts and zero leaked objects or
bytes. Complete C, status, stdout, diagnostics and output-state bytes match;
no C or diagnostic normalization is used. These are compiler-input proxies,
not self-compilation or isolated-phase instruction measurements.

SOURCE retains the original schema1
`artifact_construction_complete total_allocations` metric. Its normal producer
and proxy SHA256 is
`34ac1a913c79fc14130c77fe4339f24885a2fa65f1d25fc4b873b627e10e1f33`;
the diagnostic proxy is
`be31a5a3a070deef54707d8676a7c6157042484f40d0424dd5fb46835c09ff93`.
Both use the explicit `host-utf8-file-admission/blorp/standard_library/src`.
All 598 original host/source/library pins pass before and after collection.
Normal memory modes are unset; SOURCE diagnostic sets `BLORP_MEMORY_STATS=1`
with leak mode unset. Exit-time totals and FEATURE TOTAL are not substituted.

Exactly two original-host C generations and four `/usr/bin/clang -O0` links
produce the normal/diagnostic pilots, with `BLORP_MEMORY_DIAGNOSTICS=0/1` and
`-lm -lpthread`. Apple Clang 21.0.0 and `/usr/bin/time -l` are pinned. The raw
compiler C intentionally differs: +933 net lines and +29,538 bytes. Its common
runtime prefix and reached runtime fragments are unchanged; all four links
exit 0 with the same 88 warning messages at 43 statement sites. Fixture C
identity is a separate, complete observation above.

Functional validation uses the separately identified c04 host and explicit
ROOT standard library: 216 focused callbacks, 3,276 unit/runtime/grammar
callbacks, and 467 e2e cases pass. E2e executes ordinary mains from unmodified C
at C11/Wall/Wextra/Werror/pedantic/O0 under ASan and UBSan. Instructions are
disabled only in that concurrent functional lane. An initial path-bearing
warmup CLI usage error executed no callbacks; the corrected pathless warmup
and every subsequent gate exit 0. Nine earlier unary mutations retain their
named failures, exact source restorations and green reruns; the production
patch identity is unchanged at this port.

Physical production delta: 432 added / 265 deleted / +167 net, against caps
800/+250. Tests: 969 added / 522 deleted / +447 net, against 1,400/+450.
No source-fixture or target-library bytes change.

Frozen epoch SHA256:
`92c91980b90e9e52a3674fcb755a3b2ba8bfb47725338d2cdc931ced52961e91`.
The exact source/test port hash is
`ae054d8b08cfb669531af6f087ca2668f92b48a83722b85d1ea6611d81858368`.
Raw commands, counters, C, binaries and per-input verdicts are under
`bootstrap-unary-current/blorp/build/unary-current/source-cost-01/`;
`source-preparation/` holds the complete input/recipe/role maps. The post-run
2,285-file mode/hash guard and canonical 49-member check report no drift.
Root retains that ignored bundle before archival or publication.

The current-base gate passes. The approved prospective contract supersedes only
the historical R0 cumulative hard landing gate: its criterion and historical
failures remain unchanged, and original cumulative compliance remains
UNVERIFIED. No intervening feature cost is subtracted and no old input is
retrofitted. Final review and publication remain coordinator-owned.
