# Blorp 2 counted stderr output, 2026-10-18

`io.print_error(message: String) -> Void` borrows its argument, requests every
counted byte once on stderr, and attempts one LF after a full transfer. A short
transfer, including EINTR, stops without LF or retry. Void conveys no delivery
status. The host still attempts LF after a short write; that narrow difference
is intentional. Compiler-shell migration remains pending. The
[accepted design](../../blorp_2/TARGET_STDERR_PLAN.md) supplies the scope and caps;
its original planning-only restriction was superseded by explicit implementation
and final-validation grants.

All target correctness and cost gates passed. Every shared input independently
stays below +5% allocations and normal min3 retired instructions. The supporting
host's known compile-time leak remains **FAILED_HOST_LEAK_LIMITATION**, under the
[narrow existing exception](../../blorp_2/HOST_BOOTSTRAP_LIMITATIONS.md).
This report makes no self-compilation claim.

## Frozen boundary and provenance

B is accepted post-concat main `8a0417724d38531d1b86d1951ceaa9dd650e682b`.
C adds only the reviewed print_error feature and reserved-identifier fixture fix;
the feature-only patch SHA256 is
`7bf97ab80d94100fe5e91febefe6c54041cc0885912b4e0769eb8133a873fe72`.
The landing branch is `codex/finish-stderr-landing`. Collection used the retained
`/Users/keithphilpott/.codex/worktrees/finish-stderr/blorp` canonical paths.
All 40 compiler source and nine target-library files per variant were checked
against B or C. The 837-file functional inventory matches the landing candidate;
the two accepted EOF test-writer repairs are baseline inputs, not feature changes.

The producer is `/Users/keithphilpott/CLionProjects/blorp/bin/blorp`, SHA256
`c04f68ba64ac06f6cd3f924cdb4d87ce6b3d40d0f8fba2ef89b20e324b21ca57`.
Its explicit host standard library is
`/Users/keithphilpott/CLionProjects/blorp/standard_library/src`, with all 91 files
pinned before and after. B was generated exactly once after the archived concat
build disappeared; its C matches the required predecessor hash. C reuses the
validated generation and diagnostic pilot. O0 normal/diagnostic links use the
same C within each variant, `-DBLORP_MEMORY_DIAGNOSTICS=0/1 -lm -lpthread`.
Apple Clang 21.0.0, arm64 Darwin 25.6.0, retains 87 inherited link warnings;
no warning or sanitizer policy was weakened.

| Artifact | B SHA256 | C SHA256 |
| --- | --- | --- |
| Generated C | 567a2dd0122edf7c38298ba196a3cf222df08c0d3f69ef2322fd5ddcd2e9d91e | f6ca2464aa7c7e5880e5902888a0ef6bd03a574cc39756bed127518d2663f42b |
| Normal pilot | 4230d56e604658c831568328f1ae52a71f9f5fb9bc9627544f0c91aaf44b521d | 12532b5502ae276d218fcee04f853927df28dd6c098dee5749fe0d5e1ee98f4e |
| Diagnostic pilot | 61f3a3f3210f5cc2dca6abfb92948947c0194aeacc66c025d4fe8e61456b5a90 | fe993c113456dee871585997add66ef1b766b67fdb5767582c2369293ed1ea4c |

Before any acceptance sample, root and an independent expert approved the
existing supporting normal/diagnostic pair, respectively
`34ac1a913c79fc14130c77fe4339f24885a2fa65f1d25fc4b873b627e10e1f33` /
`be31a5a3a070deef54707d8676a7c6157042484f40d0424dd5fb46835c09ff93`.
Safe copies live at root `build/bootstrap-evidence/frozen-supporting-host/`.
Retained provenance identifies common stage2 C `7ee2f11069ec420ccf2f303b22a28d5e70747a939ec3ae2e6c0f1885ffe66641`,
O2 CLI/runtime, Apple Clang 21, and printed `90734f4de3cb-dirty` metadata.
The unavailable old 4cc4/485a static packet remains UNAVAILABLE/NOT EXECUTED;
zero stderr acceptance samples used it. No historical sample was substituted.

## Commands, complete corpus, and costs

Existing direct collectors `strict.sh`, `normal.sh`, then `host-proxy.sh` ran
serially in one exclusive quiet reservation, each exiting 0. Setup and source,
library, output-state installation are outside measured calls. The frozen
packet includes every argv, absolute oracle path, cap, and all 1,956 derived
case files: 487 shared invocation/output states plus two C-only cases, 464
fixture files and 150 generated dependencies. Strict calls set leak checking
and unset memory stats; normal calls unset both and use `/usr/bin/time -l`.
The order is B1,C1,C2,B2,B3,C3, with min3 instructions binding per input.
Exactly **976 strict + 2,928 normal + 8 host proxy = 3,912 calls** completed.
Every target strict report has positive balanced counts and zero leaks.
Statuses, stdout, exact diagnostics, output absence/preservation and complete
raw C agree across shared variants and within each strict/normal variant.
All original absolute caps remain unchanged. No failure was retried, filtered,
excluded or refrozen.

| Binding measurement | B | C | Change |
| --- | ---: | ---: | ---: |
| Largest shared allocation increase, i0354 | 11,360 | 11,615 | +2.244718% |
| Largest shared instruction increase, i0358 | 48,811,671 | 49,680,383 | +1.779722% |
| Feature host FULL TOTAL allocations | 23,453,146 | 23,469,443 | +0.069487% |
| Feature host normal min3 instructions | 20,872,620,578 | 20,857,494,531 | -0.072468% |

Shared corpus allocation sums are 6,153,486 / 6,175,578; sums of per-input
instruction minima are 19,726,352,720 / 19,757,702,651. These are descriptive,
not alternate acceptance metrics. C-only bytes/alias fixtures use 10,555/12,878
allocations and 38,239,723/41,271,305 normal min3 instructions, each below its
unchanged 205,000 / 600,000,000 caps. No new-only baseline was invented.

The host proxy uses FULL exit TOTAL allocations, with memory stats unset;
no checkpoint, subtraction or second metric replaces it. Both diagnostic runs
actually exit 99 with empty stdout, complete C, and the full validated positive
leak table: B 516,337 leaked objects / 35,115,967 bytes; C 516,666 / 35,137,097.
Both remain failed host checks. All three normal runs per variant exit 0,
produce exact Generated-LF stdout and empty stderr, and match that variant's
strict C byte for byte. Target/native zero-leak requirements remain binding.

## Correctness, oracle proofs, and limits

The initial parser/checker acceptance test failed 1/1 with exact `unknown builtin
operation`, closed-label help and span 55..75 before implementation. Focused
phase/native validation then passed 139 events. Independent raw verifier cases
cover wrong borrow/drop obligations separately from ownership insertion.
Nine compile-successful behavior/ownership mutants each failed its intended
oracle and restored exact source plus owning green: routing, NUL truncation,
missing LF, continuing after short writes, message retry, LF retry, helper
retain, helper release and omitted ownership drop. The allocator observer's
balanced malloc/free mutant also failed zero-extra-allocation assertions after
the independent-review correction. An earlier unused-function compile failure
was explicitly disqualified as a mutation proof.

The full component refresh passed 3,190 events. An initial required full e2e run
was preserved red, 463/1: fixture local `alias` was reserved. Root reviewed the
two-token `kept_message` correction. The existing owning stderr suite then
passed with required instruction counters (two fixture and two real-main
checks plus its forwarder). The full refreshed e2e passed 464/0 with counters
explicitly disabled for additional FUNCTIONAL evidence; the final quiet packet
above independently covers every cost cap. Both fixtures compile unchanged C
once at O0 and run real main with exact byte/status oracles. Native fragment
tests retain C11/O0/Wall/Wextra/Werror/pedantic, ASan/UBSan/no-recovery.

Parser spelling becomes a closed variant once; checked, specialized, lowered,
owned, independently verified and emitted operations retain typed meaning.
Generic lower/ownership/verifier production is unchanged. Reached-only emission
selects the literal helper; it borrows String and returns unmanaged uint8 Void,
without helper allocation/retain/drop. Stdio wrappers establish request counts
and termination, not kernel syscall counts, delivery durability or SIGPIPE policy.

Physical added/net lines: production **41/31**, tests **593/559**, two fixtures
**21/21**, public API docs **17/15**, all within the accepted ceilings. The
20-line ignored direct TestSuite forwarder keeps total test additions 613.
This required benchmark evidence is reported separately from API documentation.

Raw evidence is retained outside managed-worktree deletion risk at
`/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/print-error-8a0417724-01/`.
`prepared-input-binary-pins.json` SHA256 `a10cf24f88ad898f78891ad75ef3972a8eda9e196e1f366cb9a8312ab29ccd05`
binds the prepared inputs and artifacts; receipt `5962013e8ea827533f78b96dc541baaf5554ea883a676e395dce792206c017d9`
records exact build commands. `raw-strict/`, `raw-normal/`, `raw-proxy/` retain
full reports, outputs, commands, timing and per-file hashes; `COST_RESULT.json`
records every summary and cap result. Original focused/mutation and functional
logs are retained in the root's `retained-2026-10-18` backup. Final root and
independent review precede commit; destination validation remains separate.
