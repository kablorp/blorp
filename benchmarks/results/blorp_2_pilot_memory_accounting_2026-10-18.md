# Target memory accounting: bounded runtime and FEATURE acceptance

The increment adds one emitted MEMORY_RUNTIME authority for all 26 target
allocation/resize/release occurrences and start/finish hooks for all five main
exits. Mode 0 uses libc object aliases and identity/no-op macros. Mode 1 uses a
max_align_t size prefix, checked counters and one atomic_flag across each complete
backing transition; failed positive resize preserves the live allocation and counts.
Strict reports use the existing format and return 99 for leaks. No registry,
tracing, language API, ownership representation or phase algorithm is added.

## Runtime proof and its limits

| Boundary | Actual evidence |
| --- | --- |
| First public pipeline/ordinary main (84 lines) | Before implementation, native exit 0/empty streams but required `1/1/0/0` report missing: callback RED. Unchanged test then GREEN with exact `1/1/0/0`. |
| New target MEMORY_RUNTIME, 20 native cases/direct C | Independent 17-byte leak `1/0/1/17` exits 99; restored release `1/1/0/0`. Specific ASan UAF/double-free versus single-release green; successful/failed resize/content/backing occurrences, alignment/SIZE_MAX, counter arithmetic, mode validation, mode 0 ABI/no getenv/single evaluation and partial argv cleanup pass. |
| Retained ordinary target main | Unmodified unused/before/after String C, strict C11/`-O0` ASan+UBSan/no recovery, diagnostics 1: exit 0/empty stdout/exact `3/3/0/0`. Actual C has three paired roots and direct start/call/finish main. |
| Owning emission/reader | All five exits finish after effects/cleanup; Int main without arguments preserves direct return. Existing reader rejects missing reports; independent mode 0 malloc/free ledgers retain raw-pointer ABI and occurrence assertions. |
| Worktree full gates | 3,359 component callbacks PASS; 478 e2e cases PASS, with 1,060 total PASS callback lines. Destination validation remains coordinator-owned, including accepted main's newer product-lifetime tests. |
| Host-generated pilot A | Functional retained success `9514/9514/0/0` and late Int/Float source rejection `8304/8304/0/0` with original exit 1/diagnostic/no C. These counts use the OLD host-generated runtime. |

The 1,006 matched strict compiler requests below also run host-generated pilot A,
using its OLD host runtime across feature source variants B/C. They do not execute
the new target allocator in that compiler. The normal e2e native harness unsets
leak mode; it does not prove strict accounting for every emitted target fixture.
These gates do not establish a target-built compiler B or full M8 self-compilation.
Mode 0 macro/ABI/no-getenv/single-evaluation evidence is not a measured native
overhead result. Mode 1 runtime overhead remains unmeasured until M8.

Failed setup, stale expectation and platform ASan-exit attempts remain retained.
The ASan configuration explicitly uses `abort_on_error=0`/`exitcode=77` while keeping
the specific fault-class and absent-report oracles. No generic nonzero acceptance.

## Frozen FEATURE method and costs

B is accepted `7b17de45214f46b9d2908017b1ab5a6ea8def716`; C is B plus reviewed
code/test patch `052e6fa5e7781e9c9de85b76809c5ce1f8d61fd9a476b4af5f147484eb017c7f`.
Full accepted Path libraries remain identical ten-file maps; compiler sources are
40 files in B and 41 in C. B's accepted product-lifetime tests/README are preserved.
The 503 shared states contain 385 successes/118 rejections and 472 absent/31 preserved output states;
478 physical fixtures and 150 generated inputs are separate inventories.

Reviewed adaptations of the Path FT recipes ran 1,006 strict + 3,018 normal + 8
original proxy calls once, serially and quietly. Each normal boundary retains
B1, C1, C2, B2, B3, C3 and uses
the minimum of all three positive samples. No warmup, retry, dropped sample,
resampling, a roll of B, epoch change or cap adjustment. Each input and proxy independently
passes the +5% target and +10% hard ceiling, retaining every tighter absolute fixture cap.

| Metric | B | C | Largest increase / result |
| --- | ---: | ---: | --- |
| Worst of 503 shared allocation ratios, i0216 | 9,538 | 9,539 | +0.010484378%, PASS |
| Worst of 503 normal instruction-minimum ratios, i0118 | 40,871,410 | 42,004,488 | +2.772299757%, PASS |
| Original schema 1 construction allocations | 24,240,232 | 24,249,954 | +0.040106877%, PASS |
| Original proxy normal instruction minima | 21,551,505,606 | 21,558,449,216 | +0.032218677%, PASS |

All 1,006 strict requests have one positive balanced report with zero leaked
objects/bytes; 770 expected exit 0 and 236 expected exit 1 outcomes retain exact
stdout/diagnostics/output states. Root and independent review approved all 385
complete raw success-C diffs: memory prelude, allocator names and main hooks.
All 3,018 normal outcomes match their respective complete strict C/diagnostic/sentinel
oracle. Target +5% misses: 0; hard +10%/tighter absolute failures: 0, independently per row.

The original producer/normal proxy is `34ac1a91`, diagnostic proxy `be31a5a3`, explicit
original std tree `090ed68c` (91 files), with all 598 original pins verified. Functional
`c04`/`ROOTstd91` is a different role. Proxy allocations use only the unique schema 1
`artifact_construction_complete total_allocations` field: `BLORP_MEMORY_STATS=1`, leak unset,
status 0/exact Generated stdout, 48 complete checkpoint records per diagnostic.
Exit TOTAL is not substituted. These are supporting-host source-to-C construction
proxy numbers, not target-built A/B/C or old SOURCE R0 compliance. No SOURCE waiver.

The six compiled setup calls ran once. Four `-O0` diagnostics 0/1 links each retain 90
warnings: 28 pointer/integer, 59 equality-parentheses, 3 discarded-qualifier; 0 errors.
A pre-call metadata path lookup failed; valid B generation was not repeated, and
root explicitly granted the remaining five calls. Its failure/partial records remain.
All 4,171 setup/source/role pins match after the campaign; canonical source restores C.
Root and independent raw reviews approve all three cost phases with zero issues.

## Scope and retained evidence

Production: 132 physical additions/35 deletions/+97 net (caps: 260 additions/+250 net).
Tests: 445 additions/71 deletions/+374 net (caps: 500 additions/+480 net),
including one 130-line readable C fixture and no added language fixtures.
Mechanical complete-C/main expectation changes retain coverage. No accepted B test
is deleted or credited against these bounds. Maintained evidence/docs are separate.

Owned raw root is `/Users/keithphilpott/.codex/worktrees/pilot-memory-accounting/blorp/build/pilot-memory-accounting/`.
`broad-02/`, `helpers-03/`, `late-rejection-01/` and all earlier failed/approved
checkpoints retain functional evidence. `cost-preparation-7b17-01/` holds exact
maps/recipes/cases; `cost-7b17-01/` retains all 4,032 measured commands, statuses,
streams, times, checkpoints, C outputs and materializations, plus the original freeze.
Freeze SHA `ddbdc35b`;
campaign `623e5222`, complete results `a9329bad`, final pins `22cb73dd`, raw map `0036a395`.
Verified external copies are under `/Users/keithphilpott/.codex/task-evidence/pilot-memory-accounting/2026-10-18-checkpoint04/`.
Original failures remain unchanged. Root owns final evidence review, destination
gates and landing. Full target-built strict self-compilation and mode 0/mode 1
overhead remain M8 follow-up, not results of this runtime increment.
