# Declaration-spelling parser allocation pin

Source migration at root `cbffad8a3b2cc62cf0194e13c97b44bc775ace4d` changes the
load-budget workload's `enum E` declaration to `fixed union E`. This note
justifies its exact allocation pin, not a parser optimization or new table-copy
allowance. `EXACT_TOLERANCE` remains 100.

All runs use the same unchanged root host SHA-256
`e27b8bc719a8e7f4554368be27d522e039ccaed6c8717d9c698fdebe77296ea9`, CLI/runtime O2,
split 8. Build status is FRESH only with the authorized staging-host override
`BLORP_BOOTSTRAP_COMPILER_BIN=<worktree:union-migration-bridge>/bin/blorp`;
this is not default pinned-bootstrap freshness. No rebuild or parser source change.

The scratch baseline and candidate differ only in that declaration's spelling.
Their repeated item is the unchanged record, payload union, fieldless declaration
and alias from `test_load_allocation_budget`. Text construction precedes reset;
the counted boundary is `load_module(empty_discovery_builder(), ..., text)`.
Both parses have zero diagnostics, identical retained definition/node counts,
and one additional candidate token per repeat. Memory and oracle active flags
are 1 before/after; the leak-enabled observation also asserts byte availability 1.

| Repeats | Legacy allocations | Fixed allocations | Added allocations | Legacy live managed-byte delta | Fixed live managed-byte delta |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 64 | 11,554 | 11,750 | 196 | 307,090 | 309,688 |
| 128 | 22,955 | 23,343 | 388 | 558,482 | 563,640 |
| 2,000 | 356,207 | 362,211 | 6,004 | 7,961,234 | 8,041,272 |

Added allocations equal `3 * repeats + 4`; added retained managed bytes equal
`40 * repeats + 38`. Token counts are `39 * repeats` versus `40 * repeats`,
definition counts are `10 * repeats` in both, and node counts are `4 * repeats`
in both. The scratch suite passes its product/counter assertions; strict teardown
reports 3 allocations, 3 releases, zero leaked objects/bytes after the suite.
These process-end counters are not the per-parse allocation costs.

Source inspection explains the added path: contextual `fixed` is an identifier,
so the lexer creates its Token, `interned_spelling` returns its result tuple,
and `lexed_bridge` creates the rewritten identifier Token. The repeated spelling
is an intern hit with no table mutation; its initial miss is startup work.
The additional no-bracket type-parameter check returns the builder unchanged.
This fits the three added owned products rather than repeated table copying.
ManagedBytes measures retained live bytes, not cumulative allocation/copy traffic;
the byte slope alone cannot exclude transient copies. The matched product counts,
constant allocation slope and source inspection support this bounded repin;
they are not a general proof of parser cost or latency.

Raw local packets are `/tmp/union-parser-allocation-migration.uysQHi/matched`
(allocation-only observation) and `matched-bytes` (separate leak-enabled
observation). Each retains exact argv, host hash, fingerprints, stdout and stderr.
The final scratch source is retained alongside them as
`migration_allocation_probe.brp`, with the old declaration introducer supplied
only by that historical baseline. The temporary checkout source was removed
before handoff. These temporary paths are not retained repository artifacts.

The migrated 2,000-repeat exact pin is therefore 362,211. The unchanged tolerance
still rejects an extra per-repeat table allocation. User accepts this temporary
source-migration allocation cost; no production performance rewrite is included.

After the repin and temporary EnumKeyword corpus exemption, exact owning suites
pass 24/24 load-budget cases and 2/2 corpus cases (773 files, 98 token kinds with
four exemptions). Source and host remain frozen during the recorded command;
raw result is the local packet's `owners/`. Remove EnumKeyword and its explicitly
temporary exemption together in the separate enum-internals cut.
