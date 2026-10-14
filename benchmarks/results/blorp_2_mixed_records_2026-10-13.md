# Mixed finite records: implementation and validation

Status: implementation and per-object runtime tests approved by two independent
compiler reviewers; final frozen and combined live strict/native gates pass.
This is the first increment of
[the roadmap](../../blorp_2/ROADMAP.md),
not completion of the roadmap. Validation used an uncommitted snapshot on
`codex/blorp-2-aggregate-roadmap`, based on
`79deebd455856e5955d215ff2ec36f17860feb14`.

## Behavior and ownership

Fixed records now preserve all currently supported finite field types through
checking, specialization, ownership insertion, independent verification and C
emission. Numeric-only fixed records remain inline. Other fixed records have an
ARC root, including Void-only and unmanaged-union fields. Each owning stored
occurrence has its own obligation, even when two fields contain the same pointer.
Root duplication does not duplicate child obligations. Final root destruction
releases every owning field and then frees the root.

Managed field projections acquire the projected value before retiring the parent.
Subsequent uses refer to that acquired backing. Numeric projections independently
require a live managed receiver. Constructor fields retain written evaluation
order while using declaration-owned storage identities. Recursive declarations
remain rejected before concrete expansion, including unused and mutually
recursive declarations.

## Evidence and provenance

The repository host compiler was FRESH: binary SHA256
`286a1720a36a75599f910e1b8ab838df642a3983409cd30ed3a6ef3dcf16ba79`.
The reviewed pilot source manifest SHA256 is
`a1ac7986ec834bbed1d6a38b50350fe2f52d946752266ec915936bb76c27279a`;
pilot binary `c596e0eab9db288d4255e1c6f7b0291097a922ff7a58959b1eb4992563ff983b`,
generated compiler C
`44735a031ca3319ed32afb6140b338bb0e6cd81d2905826ca6981d461ae0dbbf`.
Pilot and fixture development builds use O0. The generated pilot includes memory
diagnostics. Host compilation uses the repository's pinned bootstrap.

Local ignored artifacts live under `blorp_2/build/roadmap/`:

| Evidence | Result |
| --- | --- |
| `strict-unit/` recorder packet | 1,509 unit callbacks in 99 suites pass with ASan, UBSan and host leak checking; no source drift during the command. |
| `strict-final-records/` recorder packet | Final repaired frozen source plus current runtime/grammar suites: 1,722 callbacks in 111 suites pass with ASan, UBSan and host leak checking; no source drift during the command. |
| `e2e-final-records/` recorder packet | 248 grouped cases pass, zero failures; 601 printed callbacks include native assertions and wrapper/group callbacks. |
| `local-traversal-full-unit.log` | 1,701 callbacks across unit, runtime and grammar suites pass before adding the aggregate runtime suite. |
| `generated/` | Five inspected target-C programs cover mixed fields, nested projection, duplicate record slots, union payloads and child-free Void roots. |
| `first-slice-frozen/source.tar` | Source/unit/e2e snapshot before the independent contextual-inference track changes the checker. |
| `baseline/` | Original compiler, generated C, frozen sources, target library and hashes. |
| `local-traversal/` | Matched shape-count measurements, complete sample JSON and generated-host-C setter evidence. |

Reproduce the strict and end-to-end checks from the repository root:

```sh
bin/blorp test --suite --sanitize --leak-check --timeout 180 blorp_2/test/unit
bin/blorp test --suite --timeout 0 blorp_2/test/e2e
```

The end-to-end wrapper builds the pilot once, compiles each fixture to C once,
checks allocation/instruction ceilings, and builds/runs the unmodified C with
the fixture's real main. The new identity-reassignment example observes both
the old alias and `current = identity(current)` before replacing current with a
fresh record. Ordinary self-assignment alone does not establish acquisition
ordering because lowering reuses its ValueId.

## Scaling and review-driven repair

An independent reviewer identified shared visit-vector carriers in declaration
cycle checking, layout verification and C definition ordering. Each state update
could retain an old vector root and trigger a full COW copy. These traversals now
use local vectors and typed enter/finish tasks. The reusable pending stack tracks
logical depth rather than retaining an old root through a fallible remove.
Generated host C confirms local pointer consumption at setters, without the old
root retain. DFS, diagnostic order and dependency-before-parent order are
preserved. All four shape outputs and the five managed fixture outputs remain
byte-identical to the pre-repair draft.

Three serialized samples per binary use the same frozen 16/32/64/128 distinct
record/function workloads, input paths, library root and toolchain. Relative to
the pre-repair draft, allocations decrease 1.27/1.62/1.89/2.05%, and minimum
retired instructions decrease 0.48/0.85/0.92/0.92%. Relative to the original
pre-feature compiler, the complete feature adds 4.47/5.74/6.70/7.31% allocations
and 2.93/5.35/9.36/16.22% minimum retired instructions. All measured compilations
report zero leaked allocations and bytes. These are owned-input compilation
proxies, not self-compilation measurements. Existing declaration/instance scans
remain; these samples do not establish overall linear compiler complexity.

The six production files before the second repair add 1,524 physical lines against
the base revision.
Correctness and complete ownership contracts take precedence over a smaller
implementation; no collection cache, alternate compiler path or runtime tracing
was added. One independent reviewer approved the code and traversal repair with
zero remaining code findings. A second reviewer identified a separate new
multiplier: sequential record-field transfer verification published a complete
state after each field, copying O(existing owners) entries per owning field.
That boundary now validates narrow transfer actions against a local owner vector
and publishes once. Its 94 focused verification callbacks pass, including the
exact duplicate-transfer diagnostic. The complete frozen unit directory also
passes 1,509 callbacks. Two independent compiler reviewers approve the repaired
code and runtime tests with zero remaining findings. Integrated final gates were
still required at that checkpoint; the combined results below complete them.

The second repair adds 26 production lines, with no test change. Its isolated
candidate is built from the frozen first-slice source with only verify.brp changed:
verifier SHA256 `2df78b30dd133fb9cb12a5ed0f2aeb9ab7da362fccfbd03cdcea4b27c22d39e7`,
binary `9aa053a9744b40125bc00bb53e024595dd65ed5ea6baf54e087e3c63482bc17e`,
C `d67dcdec3c46f2340345d1935dfb963c7e8d92fb0581d134fcd22b371712b15a`.
Generated C shows one initial immutable-input sharing retain, then direct local
setters with no per-field vector retain. It does not establish linearity of the
existing whole verifier, whose per-operation state rebuilding is unchanged.

Three paired samples per width use 16/32/64/128 owning fields:

| Owning fields | Before / after allocations | Before / after minimum retired instructions |
| --- | --- | --- |
| 16 | 13,620 / 13,606 | 62.381M / 62.726M |
| 32 | 17,221 / 17,191 | 73.942M / 74.090M |
| 64 | 24,406 / 24,344 | 99.245M / 99.068M |
| 128 | 38,815 / 38,689 | 159.088M / 157.689M |

All 24 compiler runs report zero leaked allocations and bytes; all four outputs
are byte-identical before/after. The width-128 output also compiles with strict
C11/O0/ASan/UBSan and exits 0 through its normal main. Native LeakSanitizer is
unavailable in this Apple ASan toolchain; exact target destruction comes from the
separate per-object runtime assertions. Evidence is under
`record-transfer-repair/`.

## Remaining acceptance

The user approved direct C runtime-helper tests using the same pure production
fragments and test-local real allocator observation. Twenty native cases pass
under strict C11/O0/ASan/UBSan against the frozen checkpoint, covering repeated
children, nested records, active/inactive unions, List fields and child-free
managed roots. See `runtime-validation/checkpoint-1/` for source fingerprints and
the log. Five isolated shared-production-source mutations then produced exactly
the intended native failures, with every other case passing:

| Mutation | Failing cases / passing controls |
| --- | --- |
| Omit the second owning record slot's drop | 2 / 18 |
| Omit a child-free managed record's root free | 1 / 19 |
| Omit active owning union child cleanup | 2 / 18 |
| Omit initialized List element cleanup | 3 / 17 |
| Incorrectly retain a child when duplicating its record root | 4 / 16 |

The unchanged TestSuite regenerated the production fragments; neither emitted C
nor C assertions were rewritten. Every mutant compiled successfully. Two initial
mutation drafts failed host parsing and were retained as superseded attempts;
those failures do not count as oracle evidence. Each of the five source snapshots
was restored byte-identically, reran all 20 native cases successfully, and a final
clean baseline rerun also passed. Diffs, fingerprints, recorder packets and logs
are under `runtime-validation/`.

The final combined live branch passes 1,800 printed unit/runtime/grammar checks
across 115 suites and 275 normal-main end-to-end cases (678 printed callbacks,
270 suites), with no source drift. Both commands use scripts/record-validation;
packets are under repository-root `build/roadmap/integrated-20261013/{strict,e2e}`.
The integrated diagnostic pilot SHA256 is
`370bb7b4cb406d2c7008fc721e7a5554d077776299d0ca70f596f213722ebcad`;
its generated C is
`ad9ee46df976ddaca96dc3fede64e8d8907c13c409f8a6b06dedede1384639f1`.
The preserved source archive is
`5303eb112068c8b3ebeef81fbbda03954f211658e9553bd32366452f3ea47254`.
Those gates ran on `blorp-2` before moving the unchanged work to the separate
branch. They also include contextual inference and owned match-prefix increments;
the earlier frozen counts remain evidence for this record slice alone.
Host leak checks and emitted release calls alone do not prove target-runtime
destruction. These exact per-object checks are separate from phase-level ownership
insertion and malformed-IR verification tests.
