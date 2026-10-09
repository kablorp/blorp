# Blorp 2 first managed String slice

Date: 2026-10-09. Baseline source: `49d480ea5d30`. Status: pilot implementation,
unit/grammar/e2e and sanitizer validation complete; exact target object-lifetime
observations await approval. Broader host validation is recorded separately below.

Follow-up validation uses granular compiler-stage tests and direct C runtime
unit tests, as recorded in the current [memory test contract](../../blorp_2/MEMORY_PLAN.md#phase-level-test-contract).
The event tracing proposal in this historical record is deferred; the
measurements below remain evidence for the original implementation slice.

## Scope and authorities

The working fixture is `value = 7.to_string(); value.length()`, written as
ordinary Blorp bindings and UFCS calls; its real `main` returns 1. The explicit
`src/prelude_temp.brp` supplies compiler-known Int/String declarations and two
concrete pure runtime functions. It is an input source, not a host import or
automatic fallback. Grammar conformance tests cover this separate prelude
entrypoint. The pure pipeline receives both sources and preserves diagnostic
origin.

Checking publishes exact callable identities and types. Lowering retains
function-local `ValueId` identities. Ownership insertion publishes distinct
`OwnerId` obligations and owner/parameter-dependent borrows. The independent
verifier reads actual definitions/acquisitions/drops/transfers, without consulting
the inserter's last-use analysis or drop schedule. Only verified output reaches
C emission. A String is one mortal managed leaf, with atomic ARC and inline
decimal bytes; it has no owned children.

Borrowed parameters and owned results use one conservative ABI. A returned owner
may alias an argument; the result owner exists before the caller drops its
argument owner. Managed matches, String payloads/literals, joins, COW and reuse
remain outside this slice. Unsupported managed matches are rejected by insertion
and independently by verification, including malformed raw IR with no arms.
The verifier also requires the zero-argument Int entry ABI.

## Provenance and budget

All builds use the repository host, Apple Clang 21, and `-O0` pilot/fixture
compilation. The pilot includes `-DBLORP_MEMORY_DIAGNOSTICS=1`; one strict
leak-checking compilation supplies emitted C, allocation counters and macOS
`/usr/bin/time -l` retired instructions. Startup and reporting are included.
These are owned-input compilation proxies, not self-compilation or target
allocation counts.

The initial frozen pilot executable has SHA-256
`3387018b63b77452f8040a386ff9cb9c45c9dbd48ded275548abe59422b40df0`.
It was built by host
`c67d5bb315a67999ec5d608eaa41aab83f8d75e6220b44b936ea2a4849b7ba0a`.
A necessary host ownership repair changed that host. Therefore the frozen
baseline pilot sources were archived from the same baseline revision and
rebuilt with the repaired host, using the same Clang/O0/diagnostic settings as
the candidate. The comparison below does not mix the original and repaired
host compilers.

Repaired host SHA-256:
`f6d946861a5a07faa506cb598e0e64d8af0f89289551737b5e0dc42443554a8c`.
Complete source/binary fingerprints and raw samples live under
`blorp_2/build/mortal-string-evidence/`; its `baseline/` contains the original
frozen evidence and `baseline_same_host/` contains the matched rebuild.

The production ceiling was set to 8,000 lines before implementation. Canonically
formatted pilot production changed from 4,651 to 7,184 lines, including the
six-line target prelude. Test/helper/fixture Blorp sources changed from 9,560 to
12,628 lines. The new ownership and verification modules account for 1,473
production lines. This slice adds actual managed behavior and its independent
verification; it is not a semantics-preserving representation refactor.

Investigate repeatable allocation or instruction growth above 25%. Existing
instruction growth remains below that threshold. The allocation increase
crosses it and is attributed below; affected e2e ceilings were raised explicitly.
New managed examples retain their predeclared 20,000-allocation and
200-million-instruction ceilings.

## Matched compilation measurements

All 43 frozen existing valid fixtures emit byte-identical C with both the
matched baseline and candidate. Every measured compiler run reports equal
allocations/releases and zero leaked objects/bytes.

These refreshed samples use the final frozen sources. Candidate pilot SHA-256:
`542779c6da377e3ce1c150f564fc3363c903a712b2637d0d1ba6619f2a8d4f88`.
Matched baseline pilot SHA-256:
`7e17b2de07da0ac925ebb13fb7c5493847594a083a85fba827073cd791d51317`.
Four target runtime helpers use ordinary external C linkage so strict builds can
include unused ABI operations without warning suppression or artificial uses.

| Fixture | Baseline allocations | Candidate allocations | Baseline instructions | Candidate instructions |
| --- | ---: | ---: | ---: | ---: |
| binding_capture_shadow | 1146 | 1740 | 32,203,798 | 36,388,698 |
| binding_ordered_calls | 1270 | 1928 | 32,071,445 | 34,149,382 |
| binding_parameter_shadow | 651 | 1175 | 30,109,820 | 32,007,020 |
| binding_pure_mutation | 834 | 1412 | 30,791,361 | 32,761,175 |
| binding_self_assignment | 500 | 997 | 29,804,477 | 31,606,403 |
| binding_union_current | 1165 | 1772 | 31,825,650 | 33,837,892 |
| binding_union_original | 1244 | 1851 | 32,136,035 | 34,092,680 |
| binding_unused_initializer | 670 | 1229 | 30,312,415 | 32,408,423 |
| binding_values | 785 | 1344 | 30,792,219 | 32,747,120 |
| bindings | 827 | 1386 | 30,811,769 | 32,794,161 |
| call_one | 309 | 806 | 29,066,596 | 30,982,711 |
| integer_maximum | 364 | 861 | 29,254,135 | 31,142,710 |
| integer_minimum | 364 | 861 | 29,249,865 | 31,113,488 |
| match_binding_current | 1661 | 2302 | 34,647,020 | 35,426,326 |
| match_binding_empty | 1535 | 2159 | 33,058,908 | 34,874,894 |
| match_binding_original | 1428 | 2051 | 33,328,880 | 34,641,665 |
| match_binding_outer | 1346 | 1935 | 32,361,702 | 34,322,193 |
| match_constructor_argument | 969 | 1560 | 31,200,340 | 33,188,111 |
| match_constructor_spine | 4404 | 6458 | 42,110,320 | 47,043,922 |
| match_empty | 777 | 1317 | 30,659,529 | 32,499,934 |
| match_many_arms | 53923 | 63158 | 277,579,661 | 304,719,777 |
| match_scalar_capture | 965 | 1525 | 31,218,167 | 33,160,642 |
| match_selected_arm | 1220 | 1853 | 32,089,007 | 34,107,754 |
| match_shadow | 1074 | 1686 | 31,585,641 | 33,560,897 |
| match_sibling_empty | 1028 | 1621 | 31,460,769 | 33,392,886 |
| match_sibling_payload | 907 | 1482 | 31,081,805 | 33,153,723 |
| match_value | 908 | 1483 | 31,181,547 | 33,018,973 |
| match_values | 1303 | 1927 | 32,318,410 | 34,260,485 |
| match_whole_empty | 1167 | 1751 | 31,877,404 | 33,798,108 |
| match_wildcard | 743 | 1282 | 30,605,128 | 32,392,419 |
| nested_calls | 577 | 1127 | 29,957,738 | 31,910,926 |
| nested_order | 665 | 1252 | 30,160,842 | 32,208,334 |
| pure_calls | 483 | 1015 | 29,643,507 | 31,665,052 |
| return_42 | 164 | 626 | 28,580,408 | 30,470,234 |
| return_zero | 161 | 623 | 28,811,948 | 30,372,845 |
| ufcs_calls | 579 | 1129 | 29,943,803 | 32,097,037 |
| ufcs_chain | 668 | 1255 | 30,136,268 | 32,172,232 |
| union_direct | 967 | 1550 | 31,651,094 | 33,209,725 |
| union_first | 686 | 1216 | 30,360,150 | 32,219,470 |
| union_identity | 967 | 1546 | 31,153,056 | 33,132,221 |
| union_receiver | 972 | 1555 | 31,208,828 | 33,291,808 |
| union_second | 689 | 1219 | 30,470,579 | 32,244,370 |
| union_values | 2092 | 2872 | 34,757,101 | 37,246,632 |

The largest allocation percentage increase is return zero: 161 to 623
(+286.96%). The largest instruction increase in the final matched sample is
`binding_capture_shadow`: 32,203,798 to 36,388,698 (+13.00%). The 256-arm stress
fixture grows from 53,923 to 63,158 allocations (+17.13%) and 277,579,661 to
304,719,777 instructions (+9.78%); its existing ceilings remain unchanged.

Three interleaved return-zero repetitions keep allocations exactly 161/623.
Baseline instructions are 29,122,495 / 28,642,739 / 28,435,504; candidate
instructions are 30,716,033 / 30,373,608 / 30,462,591. The minimum-to-minimum
increase is 6.82%. Whole-process instruction counts vary across these short
runs; allocation counts are stable. No speedup is claimed.

A separately compiled phase-prefix probe reads the same explicit inputs, stops
at a named boundary, discards that complete result and reports strict allocations.
Its shell differs slightly from the full compiler CLI, so its totals are
attribution evidence rather than quantities to add mechanically to whole runs.

| Completed prefix | Allocations |
| --- | ---: |
| source loading | 10 |
| prelude lexing | 335 |
| prelude parsing | 424 |
| prelude checking | 434 |
| program lexing | 494 |
| program parsing | 526 |
| checking | 544 |
| value lowering | 555 |
| ownership insertion | 577 |
| independent verification | 588 |
| C emission | 621 |

Prelude processing adds 424 allocations over source loading; insertion and
verification add 33 on return zero. The new fixed prelude work explains most
of the small-input percentage increase. No cache, implicit reduced prelude,
or bypass was added to avoid that cost.

## Test oracles and validation

Direct ownership insertion: 12/12. Independent verification: 27/27. Callbacks
cover last uses, unused values, borrowed parameter escape, transfer, replacement
ordering, wrong/dead/duplicate/unknown owners, missing/double drops, malformed
calls, cross-arm reads, invalid variant membership, entry ABI and unsupported
managed match shapes. Setup mints opaque IDs from one small seed; malformed IR
is constructed directly and is not derived from ownership insertion.

Meaningful deliberate mutations:

- Disabling the verifier's live-owner exit rejection fails only the missing-drop
  callback (22/23 passed at that point); restored source passes.
- Removing inserted drops makes the actual parse/check/lower/own/verify pipeline
  reject the managed example; restored source passes.
- The two entry ABI callbacks fail before their check (24/26), then all 26 pass.
- The raw empty managed-match callback fails alone before the signature fallback
  (26/27), then all 27 pass.
- Forcing all prelude call identities to String length fails three distinct
  identity/authority callbacks; the exact original source was restored.

Runtime fragment tests protect the emitted C ABI/shape; they are not runtime
lifetime oracles. Native fixtures check conversion lengths, unused results,
borrowed-parameter identity/reassignment, surviving aliases and Int64 extrema
through their real `main`. String bytes and exact per-object destruction remain
unobserved by those ordinary exit/ASan/UBSan checks. The proposed explicit runtime
event compile mode is awaiting user approval and is not implemented.

Independent final validation:

| Check | Result | Wall time |
| --- | --- | ---: |
| Unit + grammar | 256 + 57 callbacks pass | 2.08 s |
| Unit ASan/UBSan + strict per-test leaks | 256 callbacks pass, zero leaked | 2.36 s |
| Exact default e2e command | 65 cases pass, 49 native fixtures, one pilot build | 30.90 s |
| Root native ASan + UBSan | All six managed fixtures return expected status, empty stdout/stderr | — |
| Root pilot ASan + UBSan + strict leaks | All six managed inputs compile cleanly with identical target C | — |

The default e2e timeout applies to artifact execution; its measured wall time
also includes host harness compilation. The rejection CLI checks now run once
as an explicit case; valid fixtures share one measured/native execution path.
Test-runner report/logs: `build/mortal-string-evidence/test-runner-final-report.md`.

## Necessary host compiler repair and remaining host evidence

The first pilot C emitter failed with ASan use-after-free while returning
`Ok(match ...: borrowed_string | fresh_string)`. The old Result destructor
freed the alias before the caller retained it. Core already lacked the required
Dup, so the failure was not in the pilot's target String runtime.

The bounded `perceus/borrowed.brp` repair normalizes consuming arguments at
their result-producing branches using existing ownership traversal. Two alias
branches acquire once; the fresh branch does not acquire again. Shadowing is
respected. The focused registered Core/native suite passes 7/7 with ASan,
UBSan and strict leak checks after a FRESH host rebuild. Corrected retained
C has retains at lines 48077/48080, fresh concat at 48083 and old Result
release at 48098. Full reproduction and Core/C artifacts are in
`blorp_2/build/host_result_alias/`.

The broad existing Perceus suite source-checks, but host C emission stack-overflows
before its tests execute. A pre-fix host reconstructed from archived HEAD with
the same pinned bootstrap, CLI-O0/runtime-O2/split8 and Clang also fails with
the same backend stack-guard frames at the default 8,176 KiB stack. This
classifies the stack failure as pre-existing; it is not a passing broad gate.
The archived host built FRESH in 38.17 s; its broad-suite command failed in
14.21 s before test output. No broad stack repair is part of this increment.
Archived host SHA-256:
`d8d46344d55c8e91b51398b88f337213434cdf2ae7c53996a8ffd42606f94038`.

The required default-stack `compiler-core-sanitize` gate was run and failed
after 42.82 s during compilation of its 59-source batch, before any test
callbacks executed. A one-off 65,520 KiB subprocess stack allowed the existing
460-callback Perceus suite to execute with ASan/UBSan and strict per-test leak
checking. Both the archived pre-fix and current host report 222 passes and
238 leak failures, taking 22.72 s and 23.22 s respectively. All callback names,
outcomes and leaked-object counts match byte-for-byte; the comparison diff is
empty. Thus these leak failures are also pre-existing on this workload, with
no observed regression from the bounded repair. Neither run reports an
ASan/UBSan crash. The default stack remains unchanged; this diagnostic does
not make the broader gate pass. Exact commands, hashes, crashes and comparisons
are retained in `build/host_result_alias/host-gate-classification.md`.

Strict unit tests also exposed a separate existing host early-loop-exit cleanup
defect: a projected managed header local acquired twice but released once on
the break edge, bypassing its later outer drop. The original pre-fix pilot C
already contains that imbalance. The retained two-callback reproduction leaks
Header/List/String on early exit and passes on normal completion.
`resource_management.brp:662` only recognizes an immediately trailing drop in
the relevant sequence shape; the later-use sequence hides the outer obligation.

The pilot validator only needs inline WrittenName before duplicate rejection.
It now keeps that name and reads the complete header directly when validation
needs it. This narrows the managed temporary lifetime and removes unnecessary
work; both error-path leak tests then pass, as does the full 256-case strict-leak
suite. The host's general loop defect remains unfixed and explicitly reproduced
in `build/host_result_alias/test_projected_header_break.brp`, with diagnosis and
saved Core/C in `projected-header-break-report.md` beside it.

A separate ignored two-callback reproduction also shows a host nested
`Result[List[Option[Int]], ...]` pattern fails while structural equality passes:
`blorp_2/build/test_nested_option_pattern.brp`. It is recorded as a distinct
unfixed host defect; production last-use analysis does not use that nested
pattern.

## Reproduction

Run from the repository root after checking host freshness:

```sh
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 blorp_2/test/unit blorp_2/test/test_grammar
bin/blorp test --suite --timeout 180 blorp_2/test/e2e
bin/blorp test --suite --sanitize --leak-check --timeout 180 blorp_2/test/unit
bin/blorp test --sanitize --leak-check --timeout 180 \
  blorp/test/test_compiler/test_stage_09_core/test_borrowed_call_match_results.brp
```

The e2e orchestrator builds the pilot once at run start and passes its executable
to every group. Each valid fixture has one measured compilation, then a strict
C11/O0/UBSan build and execution of unchanged C. Additional root sanitizer
observations compile unchanged emitted managed-fixture C with ASan+UBSan and
run the same entrypoint; no generated symbols, drivers or rewritten C are used.
