# Compiler String construction migration

Implementation and full functional qualification complete; matched resource
ceilings passed. Parent: `eeee55b3c0c2a699155b1e1b4a2f2be2a8e090d4`.

274 compiler construction templates in 13 production files now use existing
String interpolation. Numeric leaves retain explicit `IntOps.to_string`, matching
the original `append_int` definition. Compact C templates use readable quoted
chunks without introducing line feeds. Loops, algorithms, compiler data models,
runtime concat implementations, tests and standard library are unchanged.

The typed census was frozen before editing: 925 eligible String calls, including
all later skips and chunk boundaries, plus 134 actual List operations excluded
from migration. The patch removes 835 String calls (90.27%), exceeding both the
800-call and 85% targets. Total dot-concat calls fall from 1,059 to 224: 90 retained
String calls and all 134 unchanged List calls. Production: 328 ADD / 676 DEL /
net -348; tests and standard library: 0/0/0.

Twenty-seven original roots remain logged as readability deferrals, principally
assembly of only dynamic fragments; additional concat boundaries keep long
interpolated C chunks readable. Variable-sized append/join algorithms remain.
No compiler bug, unsupported selected syntax, or host parser limitation was
observed. Exact source locations,
original expressions and reasons are in ignored `source02/SKIPS.json` and
`PROBLEMS.md`; none was silently excluded from the denominator.

## Local validation

The ordinary focused suite passed 608 callbacks for both the pilot and complete
source02, with identical exact stdout, empty stderr and equal guards. Actual
pinned-Make generation and serial diagnostic/normal links passed with empty
stderr and equal guards. Both independent source02 code and test reviews
approved local qualification.

The sole matched resource experiment used the same frozen accepted E2 input
and library, CWD, physical output pathname, private environment and tools, with
O0 normal and diagnostic binaries from each actual compiler C. Its numerical
ceilings were +1% allocations and +1% normal minimum-of-three retired instructions.
The exact schedule was one strict parent/candidate pair, then P1 C1 C2 P2 P3 C3;
there were no additional, confirmation or replay samples.

| Matched frozen input | Parent | Candidate | Change |
| --- | ---: | ---: | ---: |
| Strict allocations/releases | 31,123,985 | 31,025,573 | -98,412 (-0.31619%) |
| Normal retired instructions, minimum of 3 | 920,937,133,410 | 920,571,534,669 | -0.03970% |

Both strict reports had positive balanced counts and zero leaks/bytes with no
other diagnostics. All six normal calls had empty stdout/stderr and positive
actual retired-instruction counters. Every call passed its complete before/after
guards and produced byte-identical frozen-input C:
`d1ba3810c75e407c0bf2afd16de72b7bed89610f527373e5171ef87857770a62`.
The sampled instruction difference supports the ceiling check, not a speed claim.

The candidate's own compiler C is separately
`276cdc4811404c6949da747a6099acbd124fc54da7b5c582348027709864dbc0`,
19,169,976 bytes versus parent 19,138,489 (+31,487 / +0.1645%). That comparison
uses changed compiler source and is distinct from the identical fixed-input
output above. Current-source self-compilation observations must remain separate
from the matched resource experiment.

## Integration and evidence

The unchanged authoritative fixpoint gate passed: seed/A/B/C compiler C is
identical, all 581 fixture C/status/diagnostic contracts are byte-identical to
accepted Parent evidence (486 accepted and 95 located-help rejections), and all
584 native cases passed (1,371 raw PASS rows, zero FAIL rows).

Full components passed 4,539 checks: 4,351 hosted and 188 target checks, with
27 positive balanced zero-leak target reports. Current-source self-compilation
passed under both ordinary strict accounting and ASan/UBSan: 30,981,049 balanced
allocations/releases, zero leaked bytes, no other diagnostics, and exact compiler
C above. This changed-input observation is separate from the matched experiment.
The sanitizer link used the ordinary generated C with address/undefined checks
and no recovery; no emitted-code rewriting or alternative entrypoint was used.

The existing 117 native allocation-debt FAIL markers remain visible under
`record-allocation-debt`; broad retired instructions are unmeasured under the
accepted disabled policy. No limits, tests, freshness guards or gates changed.

Ignored preserved worker evidence: Root
`build/string-concat-migration-2026-10-22/worker/`, including `BASELINE.json`, `CENSUS.json`,
`source02/`, `candidate-build/BUILD_RESULT.json`, `CANDIDATE_SOURCE.json`, focused
raw calls and `LOCAL_COST_SUMMARY.json`. The complete finite cost collector and
all eight raw calls are under Root's matching `cost-preparation/measurement/`.
Authoritative raw runs, archived fixpoint proof, contract audit and final reviews
are under Root
`build/string-concat-migration-2026-10-22/root-qualification/`. All original
snapshots remain preserved. No migration beyond frozen source02 is included.
