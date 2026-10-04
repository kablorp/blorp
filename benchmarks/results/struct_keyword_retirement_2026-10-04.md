# Legacy record keyword retirement

Result: keyword retirement passes correctness/review gates. Same-cwd allocations
are unchanged; sampled instruction deltas are small, with no speed or allocation
benefit claim. Only the narrow S5 literal-only projection pilot is parked.
Full artifacts: `/tmp/blorp-struct-retirement.VfMogY`. Compact machine evidence
is retained in `struct_keyword_retirement_2026-10-04/` beside this report.
Copied raw files were compared byte-for-byte with their originals;
[SHA256SUMS](struct_keyword_retirement_2026-10-04/SHA256SUMS) verifies all retained
machine evidence. The main census summary omits only the large per-local rows.

## Contract and change

S1–S4 already established managed record semantics and explicit native snapshot
adapters. This cut removes the legacy `struct` declaration form from lexers,
parsers, discovery, source-form models, formatter and lint. `struct` becomes an
ordinary identifier. `record` and `fixed record` retain generic/dimension
parameters, managed fields, ARC/COW and value-preserving updates. `fixed` remains
contextual before `record` and an identifier elsewhere. Neither spelling promises
inline/stack placement, no allocation, or a foreign aggregate-by-value ABI.

Formatter `RecordSpelling` retains ordinary/fixed variants. Its JSON requires
explicit `form` equal to `record` or `fixed record`; the legacy boolean fallback
is deleted. Parser AST JSON separately uses `ordinary_record`/`fixed_record`.
Editor copies and maintained language/ownership docs agree. Native C `struct`
syntax and scalar Option/Result storage remain valid. Git recognizes 20 fixture
renames: 17 inference/typecheck plus three discovery.

## Failing-first and correctness evidence

Only the new identifier regressions failed before implementation: old parser
195/196 and discovery 27/28 passed. Direct formatter baseline exited 1 at 1:17:
`` `struct` is a reserved keyword and cannot be used as a name; choose another
identifier such as `struct_name` ``. See `baseline-old-parser.log`,
`baseline-discovery.log`, `baseline-formatter-repro.log`, and
`baseline-provenance.md` under the artifact root. JSON schema and Kotlin lexer
regressions were added first but not executed against the pre-change baseline.

Candidate [focused checks](struct_keyword_retirement_2026-10-04/focus-final-metadata.json)
passed 460/460 across ten suites. That packet predates one test-local rename;
the final broad packet covers it. Final broad-v2 passed 19,893/19,893 across 12
serial gates: compiler-blorp 6,390; compiler-new 343; parity 3,425; tools 219;
std-check 1 (91 modules); runtime 4,664; leak 1,158; Core ASan/UBSan 2,374;
doctest 1,057; CLI-deep 177; LSP 36; package 49.

Exact command: `scripts/test --no-build --serial --log-dir
/tmp/blorp-struct-retirement.VfMogY/broad-gate-logs-final-v2 compiler-blorp
compiler-new compiler-new-parity compiler-tools std-check runtime leak
compiler-core-sanitize doctest cli-deep lsp package`, through
`scripts/record-validation` at O2. Retained [broad](struct_keyword_retirement_2026-10-04/broad-gates-final-v2-metadata.json),
[quality](struct_keyword_retirement_2026-10-04/quality-final-metadata.json), and
[editor](struct_keyword_retirement_2026-10-04/editor-lexer-final-metadata.json)
metadata include exact commands and stdout/stderr hashes. Quality exited 0;
cached offline Java 21 Kotlin lexer tests passed 2/2, zero skips. Completed final
packets report unchanged source. Independent review: approve, zero blockers or
should-fixes; test-runner: pass.

The identifier runtime oracle prints `42`, exit 0. Generated
`identifier-codegen-final.c` SHA-256 is
`128155bb7bba74e1f0a4048728a78ef1c0b6efe1a56a0dd1ba13873b668fe529`.
Lines 47504–47513 show Counter's managed object header; 47654–47664 show
parameter/local values, field projection, comparison with 42, and release.
This proves the managed-record code path, not allocation-free storage.

Earlier packets are failure history: an interrupted recorder was incomplete;
Git's unstaged index still named 21 deleted fixture paths; an unformatted input
used the already-formatted category. Reviewed renames were staged and the input
moved to existing `format/should_fail`, preserving strict golden/fixpoint checks.
The first complete broad packet then passed 19,892 with one CLI failure from
embedded `struct Box`. A one-line spelling repair and full v2 rerun resolved it.
Original baseline logs still name the original input path. No oracle was weakened.

## Provenance and measured cost

Frozen input/baseline HEAD: `681105c14bffd65799b8f2048f5940adb731d3da`.
Final gated candidate is that HEAD plus reviewed staged edits: tracked diff SHA
`f75429527fdd0cb162ec9d07047e85370fcc2ba3c4379510de0dfe7b75fc032d`;
worktree fingerprint `582ee9006dfc665986f97b9422c7d73cc7165486b1df092a1c57a6447fc1d318`.
These fingerprints precede this docs/evidence addition. FRESH installed binary
SHA `65e10960f8363d685f642a3d3af7071b21de69b1ebb9846a97c6180ae0d9be4e`;
bootstrap `dev-8228a8fa12e3`; Apple clang 21.0.0; CLI/runtime O2; eight-way split.
Baseline main stayed clean. Tracked input archive SHA
`5707984383302d0c1ec65cd8e4f447ce077cd1bcbeca5a9b6037feb8c1f23400`;
small input SHA `6a67158fb09aac383ec40e77e5c5b1d64fd068b19edf6e2596a6f25060d9cc93`.

Stage-2 normal/diagnostic pair hashes (matching provenance, diagnostic modes 0/1):

| Pair | Normal SHA-256 | Diagnostic SHA-256 |
| --- | --- | --- |
| Baseline | `bcb22d818c9d9980583573b5172a5df6b31dd20c2bae88bd00820d4fb12f5314` | `396ecb611b6b29e219d6e3164deb9bfe1b891d22de7c69c646608b01bb633a60` |
| Candidate | `95ae94b39826402de1626a7a13f038b517c26cd7d9ea93c190347ee5beef928b` | `876a150d0af28b75c62107e810ca2aed51f3153c454356b69367c58d94a3d0bb` |

Six untouched raw JSON files are retained: [baseline self](struct_keyword_retirement_2026-10-04/baseline-self.json),
[baseline small](struct_keyword_retirement_2026-10-04/baseline-small.json),
[same-cwd self](struct_keyword_retirement_2026-10-04/aa-self.json),
[same-cwd small](struct_keyword_retirement_2026-10-04/aa-small.json),
[candidate self](struct_keyword_retirement_2026-10-04/candidate-self.json), and
[candidate small](struct_keyword_retirement_2026-10-04/candidate-small.json).
Primary control runs the same baseline binary from the candidate cwd:

| Workload | Same-cwd baseline allocations | Candidate allocations | Baseline min instructions (2 samples) | Candidate min instructions (5 samples) |
| --- | ---: | ---: | ---: | ---: |
| self | 271,631,867 | 271,631,867 | 232,020,484,129 | 232,299,430,964 (+0.120%) |
| small | 2,131,517 | 2,131,517 | 1,772,884,477 | 1,771,921,823 (-0.054%) |

Every same-cwd phase allocation is exactly unchanged. Main-cwd baseline
allocations were 271,625,525 and 2,130,905; +6,342/+612 cwd deltas are entirely
discovery work, not change costs or savings. Small sampled instruction deltas and
asymmetric 2/5 samples do not establish statistically proven neutrality or no
regression. The small sampled cost is accepted for source cleanup; no optimization
win is claimed. Coordinator serialization/process checks supplied isolation;
harness `lock` is compatibility passthrough. Wall time/RSS are not acceptance.

All baseline/A-A/candidate and normal/diagnostic outputs are identical C:
self 77,343,652 bytes, SHA `a546417791f556e4e964595770a6d5e89f03ffec6861cbd42f8e499ebac23a73`;
small 39,575 bytes, SHA `3f4e7cf0fbabc5459ba7802a4fc5cb69a20d0699e4c19991f19dcf374cce4abe`.
External-pair JSON says `compiler_stage=1`/`stage2_built_by=null` because its
invocation lacks `--stage2`; actual paths, versions and hashes establish stage 2.
Raw metadata was not rewritten.

## Narrow S5 pilot: parked

The retained [census script](struct_keyword_retirement_2026-10-04/s5_literal_census.py)
was validated on [tiny fixtures](struct_keyword_retirement_2026-10-04/s5-census-fixture.brp)
before main: two scalar projections were accepted; whole-value call, capture and
managed-field cases were rejected. See [fixture results](struct_keyword_retirement_2026-10-04/s5-fixture-census.json).
An initial scratch CLI-signature error was corrected; successful schema-validated
fixture/census packets supply the evidence.

Boundary: `compile --check-invariants --stop-after=fusion --dump-core-after=fusion
--dump-core-file=s5-main-fusion.txt`, then the script over that dump. [Main summary](struct_keyword_retirement_2026-10-04/s5-main-census-summary.json):
18,234 top-level functions, 224 bodyless, 11,653 record locals, zero strict
eligible. [Core metadata](struct_keyword_retirement_2026-10-04/s5-main-core-packet-metadata.json)
and [census metadata](struct_keyword_retirement_2026-10-04/s5-main-census-packet-metadata.json)
retain commands/provenance. The 394,526,824-byte dump stays outside Git, SHA
`766b2907a9c27d164012c3d22c056b157ec29e7f4e982d73a4736ac1aa735fef`.

This strict subset admits literal primitive/enum-field records with resolved
projection-only use; aliases, embedded impl methods, globals, managed fields,
call/branch right-hand sides, mutable bindings, capture and whole-value/rebinding
uses are excluded. Rejection counts overlap. Static zero is not an exhaustive
no-go or dynamic ROI result. It parks only this literal-only pilot without
production implementation or another profile. The wider S5 roadmap remains open.
