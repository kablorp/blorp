# Scalar coordinates inside source reconstruction (2026-10-04)

Status: accepted for integration after independent review, matched measurements, correctness/quality gates and compiler fixpoint. This report does not claim the change is already committed, merged or published.

Keeping source coordinates as three scalar locals inside reconstruction loops removes 37,834,640 allocations from the matched compiler self-compile (-13.93%) and lowers minimum retired instructions by 8.19%. The small compiler guard removes 438,293 allocations (-20.56%) and lowers minimum instructions by 12.14%. Baseline/candidate emitted C is byte-identical on both frozen workloads.

This is one source-owned optimization in [`blorp/src/lib/source.brp`](../../blorp/src/lib/source.brp), not a compiler scalar-replacement pass, general inliner, new ABI, or layout promise. `Cursor`, `SourceSpan`, and `SourceLineColumnSpan` remain managed record results with the same public API and ownership semantics.

## Why this boundary

The [managed-record allocation census](record_allocation_census_2026-10-04.md) ranked `Cursor` first at 39,522,818 executed maker allocations in its workspace self-compile. Tuple/SSA mint wrappers had only hundreds of events; the narrow literal-only projection pass was already parked after a zero strict-eligible fusion-Core census.

That census was a ranking tool, not the performance baseline here. Its workspace/input-path total of 270,348,690 differs from this pilot's archived-input baseline of 271,597,490. No cross-boundary subtraction or predicted “all Cursor allocations disappear” claim is used.

The selected consumers were `source_cursor_at` and the indexed branch of `source_table_cursor_at`. Previously they repeatedly reconstructed whole `Cursor` records while walking text. The new private `source_scan_cursor(text, start_offset, start_line, target)` retains `offset`, `line`, and `column` as Int locals, then materializes exactly one managed `Cursor` at the boundary. The direct caller starts at offset0/line1; the indexed caller keeps its existing binary search and starts at the selected line offset/number. Both retain the original clamp.

The byte-wise newline/tab/default transitions are unchanged. The four-column tab expression is shared with public `source_advance`, which otherwise keeps its previous behavior. The coordinate oracle has independent loop/state but shares that tab-policy helper; the existing explicit four-column tab-stop test independently protects the formula. The scanner borrows immutable text during the call; it stores no text in the result and creates no new ownership rule. A narrow stale comment correction describes returned endpoints/results as managed records rather than obsolete inline copies.

## Matched performance evidence

Input revision: `06f4a18da9aae41f767d6dd56865c67693500080`, archived before production edits at `/var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/blorp-perf-input/06f4a18da9aae41f767d6dd56865c67693500080`. Every baseline/candidate run used that same frozen directory and the candidate worktree cwd. Small-source SHA was also unchanged. Each workload uses three serial normal instruction samples and one diagnostic allocation process, ending at emitted C; native host compilation is setup, not measured.

| Workload / signal | Baseline | Candidate | Reduction |
| --- | ---: | ---: | ---: |
| Self managed allocations | 271,597,490 | 233,762,850 | 37,834,640 (13.9304%) |
| Self minimum retired instructions | 231,999,385,548 | 212,987,194,147 | 8.1949% |
| Small managed allocations | 2,131,517 | 1,693,224 | 438,293 (20.5625%) |
| Small minimum retired instructions | 1,770,318,221 | 1,555,287,529 | 12.1464% |

Self allocation reduction is exactly 151,098 in typed frontend and 37,683,542 in Core lowering; every other recorded phase has zero allocation delta. Small reduction is entirely Core lowering. These are checkpoint allocation deltas from the uninstrumented matched diagnostic compilers, not type-counter phase attribution or instrumented-census timings.

Normal instruction samples:

| Workload | Baseline samples | Candidate samples |
| --- | --- | --- |
| Self | 231,999,385,548 / 232,268,794,800 / 232,392,554,961 | 213,436,682,569 / 213,356,508,760 / 212,987,194,147 |
| Small | 1,772,356,851 / 1,770,318,221 / 1,770,803,613 | 1,556,515,509 / 1,556,675,092 / 1,555,287,529 |

The host inventory was quiet before measurement and the coordinator serialized compiled work. The harness's `lock` is passthrough on this host, so its presence is not claimed as an effective interprocess mutex. No wall-clock claim is made. The candidate recorder packets returned exit0 with `source_changed_during_run=false`; the retained raw baseline/candidate packets give the full source fingerprints and exact command arrays.

## Output and compiler provenance

Every normal and diagnostic sample output matched within and across its workload pair:

| Emitted frozen-input output | Bytes | SHA-256 |
| --- | ---: | --- |
| Self | 77,337,791 | `86a0e602be71622012bffada0ea7340e13dd6615c65f512b80ab880e8cd13ea0` |
| Small | 39,575 | `3f4e7cf0fbabc5459ba7802a4fc5cb69a20d0699e4c19991f19dcf374cce4abe` |

| Compiler/source artifact | SHA-256 |
| --- | --- |
| Baseline normal stage2 | `95ae94b39826402de1626a7a13f038b517c26cd7d9ea93c190347ee5beef928b` |
| Baseline diagnostic stage2 | `876a150d0af28b75c62107e810ca2aed51f3153c454356b69367c58d94a3d0bb` |
| Baseline same-emission body C | `537b4aa4553bbac9c20b6d6fd8410d3ace2262c8b4345aa1bfab082bda3fa66d` |
| Candidate FRESH installed generator | `fb3dec235569db01ffd62da34e6e9d417350047babdf4e5150f1cf0ed5dbd6f5` |
| Candidate normal stage2 | `93d8ca70238d3fea1a67890c33ca2b9e8e1b378b2961269953517df5617f391c` |
| Candidate diagnostic stage2 | `bc095c408e9630b5aec259022f39f4357a74b334162b605b219e3a67cef43cef` |
| Candidate body C (75,403,731 bytes) | `d48f3b23bf737096b63824f236fe145d28c1c40c9cc9fbf3121b91855dbb8bfe` |
| Candidate `source.brp` | `447a42e9832277e9fdd3c7044690012deb198e8605725d95702b3842b647ad89` |
| Candidate owning test | `88453217e7400b98ab6da4f5a02f4432197c5879deb71d336279ef15b178ada6` |

Both pairs use Apple clang21.0.0, CLI/runtime O2, split8 and diagnostic modes0/1. Bootstrap is `dev-8228a8fa12e3`. The normal/diagnostic runtime object hashes are unchanged: `17dfa45eb223216e295d294304fdba662e7d3ff1e593ceab283efc202b115957` / `3442491ce67875efe3f8850d9fd98aa32526f7bd0858352d0f0412750aff1220`.

Baseline version metadata honestly retains its older dirty681/self681 stamp; current06 source equivalence was established through FRESH build identity and same-emission body equality before copying the pair. Candidate build metadata names self06. This expected stamp difference uses no mismatch override. External scratch binaries have no associated checkout root, so the harness's `compiler_stage=1`/rootless metadata is an invocation limitation, not a claim that these stage2 executables are stage1. Exact binaries, source hashes, shared toolchain/runtime objects and frozen input establish the matched comparison. Source archive SHA is `22bd329c00e764e50055b5c7695ef9869016238ee191312280defea255b5b18e`; small source SHA is `6a67158fb09aac383ec40e77e5c5b1d64fd068b19edf6e2596a6f25060d9cc93`.

## Failing-first and correctness

The valid baseline TDD runs used the installed ordinary `bin/blorp` (SHA `65e10960f8363d685f642a3d3af7071b21de69b1ebb9846a97c6180ae0d9be4e`) and the preserved diagnostic compiler, not the preserved normal stage2 performance binary. Both pass all 14 semantics checks and fail exactly three allocation contracts: 14/17 passed, three failed. Earlier malformed test/scratch setup attempts are retained separately and are not counted as failing-first proof.

Candidate owning suite [`test_source.brp`](../../blorp/test/lib/test_source.brp) passes 17/17. Its exact allocation contracts are:

- Direct `source_cursor_at`: one final Cursor.
- Indexed `source_location_line_column_span`: two endpoint Cursors plus one result, exactly three.
- Unindexed `source_location_line_column_span`: the same three roots.

Fixture construction, warmup and the independently advanced expected coordinates are outside the scalar allocation-counter interval. `reset_mem_stats` activates counters before that interval in these isolated permanent tests; both activity flags are checked before and after. The interval uses monotonic scalar `ManagedAllocations` endpoints, not allocating snapshot records. These isolated regression resets are separate from the full performance workload and disposable census, which do not reset counters.

The new all-offset oracle repeatedly invokes `source_advance` with independent loop/state and compares reconstruction across negative/clamped offsets, EOF, empty and trailing-newline input, tabs/newlines, CR, NUL and UTF-8 byte offsets. It shares the extracted tab-policy helper rather than independently reimplementing that formula; the existing explicit tab-stop expectation protects the shared policy. Existing source/span/prelude/indexed/unindexed tests remain passing.

The owning 17 tests also pass under ASan+UBSan with leak checking and zero leaked bytes. A strengthened fresh-temporary scratch suite passes 2/2 under the same sanitizers/leak boundary, using **runtime-created String text** (`seed.to_string()` concatenated with tab/newline text), not only immortal string literals. Temporary SourceFile and unindexed SourceTable parents survive the borrowed scan call; the retained dynamic probe reports three allocations, three releases, zero leaked objects/bytes. The earlier literal-text temporary packet is retained separately and is not substituted for this stronger proof.

Independent code review: approve, zero blockers and zero should-fix findings. In candidate body C, scanner `brp_7fc` has three `long` locals, a stack OptionChar read, and no record maker/retain/release calls inside its loop; it calls the Cursor maker once after the loop. The direct wrapper borrows parent text through the call without releasing the parent. Indexed and unindexed branches release the retained SourceFile only after the scanner/wrapper returns. The bounded ownership excerpt and exact reviewed body hash are retained; C-symbol names are artifact-local proof anchors, not compiler contracts.

Setup failures do not count as acceptance: compiling the module directly had no main; an initial scratch import traversed a dot component; scratch main signature/arity was initially wrong; an initial scratch TestSuite used `name` instead of `description`. Corrected scratch probes do not modify production source. The valid baseline/candidate/sanitizer packets above are distinguished from those attempts.

## Integration gates and fixpoint

Four broad gates passed 10,001/10,001, with recorder exit0 and `source_changed_during_run=false`:

| Gate | Passed | Failed |
| --- | ---: | ---: |
| Compiler-Blorp | 6,394 | 0 |
| New-Parity | 3,425 | 0 |
| CLI | 146 | 0 |
| LSP | 36 | 0 |

Parity retains two known existing-lexer divergences: interpolation nested three levels deep and braces in an interpolated pipe string, both documented under `docs/issues/interpolation_nesting_in_the_existing_lexer.md`. Its full summary is 3,425 files, 4,086,747 tokens, 176 rejected by both, 23 files with lexer diagnostics, two known divergences, 176 first diagnostics, two position differences, 22 message differences, 86 help differences/additions, and zero mismatched files. Passing parity does not mean those known differences disappeared. The exact parity log is retained.

Full `make quality` passed with recorder exit0 and `source_changed_during_run=false`. Its stdout/stderr and metadata are retained rather than reducing it to a compilation claim. Existing tooling ResourceWarnings for unclosed BufferedReader handles and three skipped tooling tests are visible in stderr; they are not hidden or attributed to this source optimization. The implementer's final read-only cleanup audit reported zero must-fix findings, with no further source edits needed.

Compiler fixpoint passed: all three current candidate-body C emissions are 75,403,731 bytes with SHA `d48f3b23bf737096b63824f236fe145d28c1c40c9cc9fbf3121b91855dbb8bfe`; the stage3 executable SHA is `5d6363319a957a7fcbd4bfefd72f766db38593345e860ddb3f968309767ada63`. Build, stage3 emission and comparison recorders each returned exit0 with `source_changed_during_run=false`. These fixpoint inputs are the changed current compiler source, distinct from the archived06 performance input and its 77,337,791-byte self output.

The coordinator accepted the bounded pilot after these completed gates. Sanitizer/leak coverage here is the owning source suite and two temporary-parent probes, not an exhaustive compiler sanitizer or global leak-free proof. This report does not claim default/runtime/package/release/premerge gates beyond the exact named gates above.

## Reproduction and retained evidence

The [compact evidence packet](cursor_scalar_reconstruction_2026-10-04/) remains below 2 MB. It keeps four raw measurement JSONs; their exact recorder metadata/stdout/stderr; valid TDD, candidate and sanitizer packets; independent code review and bounded C ownership excerpt; source/test/build/toolchain hashes; rejected setup diagnostics; completed broad gate logs/metadata; full quality stdout/stderr/metadata; the strengthened dynamic-String temporary probe; and final fixpoint packets. [MANIFEST.json](cursor_scalar_reconstruction_2026-10-04/MANIFEST.json) binds every retained file. Raw logs are deterministic gzip copies, not trimmed text: their original uncompressed hashes/paths are retained, including the original recorder artifact identities. Large generated C, body objects and executables remain scratch-only and are identified by hashes, not copied into the repository.

From the candidate worktree, with the matching preserved pair and archived input, the self candidate command was:

```sh
benchmarks/self_compile_measure lock -- benchmarks/self_compile_measure \
  --compiler /tmp/blorp-record-s5.hzyXge/candidate-normal \
  --diagnostic-compiler /tmp/blorp-record-s5.hzyXge/candidate-diagnostic \
  --skip-build-check --samples 3 \
  --input-rev 06f4a18da9aae41f767d6dd56865c67693500080 \
  --label cursor-candidate-self \
  --output /tmp/blorp-record-s5.hzyXge/candidate-self.json \
  --keep-output /tmp/blorp-record-s5.hzyXge/candidate-self.c \
  --baseline /tmp/blorp-record-s5.hzyXge/baseline-self.json --require-identical
```

The small command adds `--program small`; baseline commands use the preserved baseline pair with the same input/cwd/sample count. Recorder metadata captures child argv, exits and source fingerprints, not the complete shell environment: its `environment={}` does not capture the `BLORP_CLI_C_OPTIMIZATION` shell prefix or the full inherited environment. O2/build provenance is separately validated by measurement JSON, version evidence and build packets; it is not inferred from that empty environment field or this shortened recipe. `--skip-build-check` is specific to those copied external binaries: fresh source-bound pair validation happened before copying. Future reproduction must build/validate its own corresponding pairs, preserve the current input/small SHA and serialize native work; the flag is not permission to measure stale binaries.

## S5 decision boundary

The evidence accepts this bounded source-coordinate builder optimization. It leaves managed record APIs/layout unchanged. It does not unpark the general literal-only projection pilot, justify a general inliner, reintroduce explicit fixed layout, or close S5. Parent inlining and other managed-field/escape optimizations require their own ownership contracts and matched evidence.
