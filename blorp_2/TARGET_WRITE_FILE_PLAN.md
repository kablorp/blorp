# Target write_file returns ordinary Result[Void, String]

## Problem, dependencies, and scope

Implementation and validation are complete against accepted main `e906b8104f269ace2ca990693a5bae417f73b006`. Coordinator owns landing and destination validation. The fixed write-only patch is `447e022744f559b0a84fc4d2013d56a096a2a76608689f628cd3d4c83b83f929`. [Current evidence](../benchmarks/results/blorp_2_target_write_file_2026-10-18.md) records 189 focused, 3258 component and 467 functional e2e passes, Linux Clang/GCC native checks, effective mutation/restoration proofs and all 3932 matched FEATURE cost calls. Read-file, concat, stderr and the bounded first-order predecessor are accepted in this baseline. M6 and compiler main/loader migration remain open. The original plan-only base was `74a3b3bdbca1772370af494dc17c26aef5d1a112`; it was never the measurement baseline.

Loading remains the effect boundary and the compiler pipeline afterward stays pure. No main/loader migration, read/path API change, host repair, atomic publication, durability, retry/fallback, general IO/FFI framework, carrier, registry or cache. The [known host leak](HOST_BOOTSTRAP_LIMITATIONS.md) remains failed strict status 99 and a host-only bootstrap exception; pilot/native strict zero, costs and original epochs remain unchanged.

## Witness and original before/after

The future-tense instructions and old source anchors below retain the original
pre-implementation design. Current implementation anchors are
`utils/syntax.brp:385`, `parse/parse.brp:2649`, `namespace/builtins.brp:151`,
`check/signatures.brp:385`, `specialize/specialize.brp:2189`,
`emit/emit.brp:1195,1297,2115,2583`, `runtime/system.brp:154` and
`standard_library/system.brp:13`. The report reconciles the original red
and preliminary mutation evidence with the final accepted-stack gates.

Future `test/e2e/fixtures/file_write/bytes.brp` exercises ordinary main, after both dependencies:

```blorp
import:
    system: write_file, read_file
    list: get
    io: print, print_error
func main(arguments: List[String]) -> Int:
    match get(arguments, 1):
        None: 3
        Some(path):
            match write_file(path, "\u{FEFF}é😀\r\n\0tail"):
                Ok(_):
                    match read_file(path):
                        Ok(text):
                            print(text)
                            7
                        Err(error):
                            print_error(error)
                            2
                Err(error):
                    print_error(error)
                    1
```

Future reproduction: `"$compiler_B" --library-root "$library_B" blorp_2/test/e2e/fixtures/file_write/bytes.brp "$scratch/bytes.c"`. Record actual missing-write_file diagnostic/help/span, status and untouched output before implementation; no red run is claimed. Compile unchanged generated C once at O0 and run its real main with explicit temporary paths. Success exits 7, stdout is exactly BOM/UTF-8/CRLF/NUL/tail plus print's LF, stderr empty. Preseed a longer file and check exact stored Bytes independently through host read_bytes; this catches a compensating write/read bug. Missing-parent input exits 1 with exact Err plus LF on stderr and empty stdout; get its platform numeric OS code from the host's same failing operation, never assume a universal decimal errno.

Current `standard_library/system.brp:4–8` imports `_base: String, Result` and declares get_current_directory. Preserve read_file's future addition; add Void and the new declaration. Host `standard_library/src/system.brp:47` uses parameter `content`; the target's `contents` is the same positional String interface, not a new semantic distinction:

```blorp
-- Before: _base: String, Result
-- After:
import:
    _base: String, Void, Result
func write_file(path: String, contents: String) -> Result[Void, String]:
    builtin("system.write_file")
```

Refresh adapter provenance against accepted host system.brp revision/SHA256. `namespace/builtins.brp:143` currently gives GetCurrentDirectory an Impure/[]/ResultResult(String,String,constructors) contract. Add `WriteFileBuiltin` / `WriteFile(DesignatedResult[Variant])`, whose sole signature authority is:

```text
purity = Impure; parameters = [PrimitiveRuntimeType(BuiltinString), PrimitiveRuntimeType(BuiltinString)]
return_type = ResultResult(PrimitiveRuntimeType(BuiltinVoid), PrimitiveRuntimeType(BuiltinString), designated.result)
checked result = AppliedUnionType(variant_owner(designated.result.ok), [VoidType, StringType])
```

Static source inspection finds no mixed-payload model gap: `_base.brp:17` has ordinary Result[Value,Error]; specialize:172 maps Void, :1392 treats it as nonowning, and :1500 selects InlineOwningPayload because Err owns String. `translate_result:2052` preserves constructor IDs independent of payload types; verifier:452 checks the two ordered payloads independently. No exact target Result[Void,String] fixture was found: first future TDD must prove ordinary Ok(void)/Err(String) through these paths before adding WriteFile. If that fails, reduce and report the smallest typed gap; do not add another representation.

`emit/emit.brp:1141` currently constructs both CWD branches with `c_union_value(result.ok/err, [scratch], unions, span)`. WriteFile instead initializes its String error scratch to NULL, calls the native helper once with two borrowed inputs, then uses `c_union_value(result.ok, ["(uint8_t)0"], unions, span)` and `c_union_value(result.err, [scratch], unions, span)` by actual designated IDs. Void is an actual uint8_t payload field (`emit:345`), not an absent field. No fake String, scratch retain/release or Ok allocation. Reuse :1121 StringFromCodepoint's NULL/out-pointer ownership precedent, c_union_value and the normal conditional Result construction; no host Result box or alternate emitter.

| Producer/owner (under src/) | Published fact / consumer |
| --- | --- |
| `utils/syntax`, `parse/parse` | Closed system.write_file label, parsed tag/span/help; update exhaustive label observers and EBNF |
| `namespace/builtins`, `check/signatures:385,410,414` | One designation supplies constructors; one contract owns impurity, two Strings and ordered Void/String payloads; reject wrong headers |
| `specialize/specialize:2052,2164` | Reuse translate_result in the concrete result instance; runtime_signature consumes accepted contract |
| `lower/lower`, `own/own:611` | Ordinary call, two borrowed inputs, one owning Result obligation even on Ok; Void projection unmanaged, Err projection borrowed/acquired only when escaping |
| `verify/verify:422,452,1412` | Independently verify signature, constructor membership/distinctness/coverage, ordered payloads and live borrows/ownership; no name recovery |
| `emit/emit:1121,1141,1233,2040,2498`; `runtime/system` | One write invocation; branch-specific payload construction; reachability-selected literal constant SYSTEM_WRITE_FILE_RUNTIME |

## Native contract and error policy

```c
uint8_t blorp_write_file(const struct blorp_string *path, const struct blorp_string *contents, struct blorp_string **error);
/* BLORP_WRITE_FILE_OK=1, BLORP_WRITE_FILE_ERROR=0; status is not a union tag.
 * Initialize *error=NULL; every failure publishes one fresh owned UTF-8 String. */
```

Borrow path/contents unchanged. Reject counted NUL path before allocating/opening; otherwise copy path to private terminated storage, fopen wb, save open errno before free, and free the copy once. Existing valid String size bounds permit path length+1 on supported LP64; inspect/check representability before narrowing, with no arbitrary cap or fabricated huge-allocation test. For nonempty contents request its complete counted bytes once; empty contents skips fwrite but still creates/truncates/closes. On short write capture errno immediately, close once, return the primary write error even if close fails. On full/empty write close once and return Ok only after close success. Close EINTR returns Err without retry or FILE reuse. Partial output is allowed; nothing prints. Keep existing malloc-abort infrastructure policy. Host `runtime.c:35172–35204` already uses wb, counted fwrite, saved numeric errno and one close; it returns ResultOk(NULL). Reuse the accepted read_file numeric-format pattern locally without a shared IO framework: named bounded stack capacity, fixed ASCII prefix, saved decimal errno, existing trusted String factory. Success creates no error String; failure creates exactly one String with references 1. No extra UTF-8 scan of already-valid input contents, strerror, decoding or repair.

Exact payloads: `write_file: open failed; errno=`, `write_file: short write; errno=`, `write_file: close failed; errno=` followed by saved platform decimal errno (including 0). Short transfer always uses that message, without a new ferror classification. NUL-path payload: `write_file: path contains embedded NUL; use a path without NUL`. Host currently says `write_file: string contains embedded NUL`; document this target teaching-text difference in parity/README, without changing host. Wrong builtin signatures use `builtin declaration does not match its runtime contract` with exactly `declare an impure nongeneric function with two String parameters returning Result[Void, String]`; preserve label span/no note. Ordinary pure caller uses `pure functions cannot call impure functions` / `mark the callee pure or remove pure from the caller`.

## TDD, independent oracles, and commands

| Boundary / future owner | Required named cases |
| --- | --- |
| `test/unit/test_check/test_write_file.brp`, parse/namespace | Accepted contract; arities 0/1/3, each wrong parameter, swapped/wrong result payload, ordinary lookalike Result, pure/generic/tail header and pure caller; exact message/help/source/span/note; derive label bounds from exact source bytes |
| Mirrored specialize/lower/own suites | Ordinary mixed Result prerequisite green; concrete/reversed declaration IDs; both distinct payload roles, borrowed path/contents, same String in both argument positions with two live borrows and no acquisition/drop/early retirement, InlineOwningPayload/OwnedResult, Ok unmanaged projection, Err escaping acquisition, ignored/duplicated Result and selected-arm cleanup |
| `test/unit/test_verify/test_result_ownership.brp` | Raw malformed IR independent of insertion: missing/duplicate/cross-owner variants, swap Void/String roles, wrong either payload, argument/return type, unmanaged result, early/wrong-owner borrow, missing/double Result or String drops; exact obligation/operation/span |
| Mirrored emitter/runtime publication | One call and correct designated tags in both branches, Ok uint8 zero, Err scratch-only transfer; runtime fragment omitted when unused; no NULL String retain/release or helper allocation on Ok |
| `test/runtime/test_write_file.brp`, `fixtures/write_file_test.c` | Empty/create/truncate, counted UTF-8/NUL/CRLF/BOM, missing parent, NUL path/no-open, open EACCES, short/EIO/EINTR, fclose ENOSPC/EINTR, combined primary precedence; same String supplied as both path and contents remains live with unchanged refs/bytes and no retain/drop; path free once, success error=NULL, one fresh failure String, active Ok no child drop/Err one String drop |
| `test/e2e/test_file_write.brp`, three fixtures | bytes witness and missing-parent case; empty/ownership fixture truncates a seeded file, reads back empty, ignores/aliases Result and escapes Err payload; NUL-path fixture uses a literal in normal main and preserves existing prefix file. Exact NativeCase Bytes/status plus independent filesystem Bytes, no C/internal-symbol bypass |

Native TestSuite compiles unchanged production String/SYSTEM_WRITE_FILE_RUNTIME plus verified aggregate fragments with C11/O0/Wall/Wextra/Werror/pedantic, ASan/UBSan/no-recovery. Use the approved runtime-helper C exception: test-local wrappers after libc headers delegate real allocation/free/open/write/close and script selected outcomes. Identify path staging from actual fopen pointer and error output from out-pointer, not allocation sizes/order; clear identities before free/reuse, never read freed memory. Track active FILE/FD ownership and guard duplicate closes; after delegated real close assert fcntl/EBADF before other opens. Scripted close EINTR proves one attempt/no reuse, not universal platform FD disposal. Poison errno independently in free/close to prove saved-primary preservation; two simultaneous errors prove distinct fresh roots. Test actual active Ok/Err aggregate destruction separately.

Mutate NUL guard, wb truncation, counted write length, short-write status, saved errno/close precedence, one cleanup and each emitted payload role separately. Require compile-successful failures in the intended assertions; record exact mutation and restoration hashes and owning green after each. No mutation runner/framework. Inspect complete emitted C for uint8 Ok, NULL initialization, one helper call, borrowed operands, active-slot destruction and absence of extra scratch ownership; verify native and real-main oracles independently.

Before code set physical budgets: production estimate added 140–165/net +130–155, hard added 190/net +175; tests excluding language fixtures estimate added 950–1100, hard added 1350/net +1350 (prospectively revised from 1200 because the retained native/mixed-Result prerequisites plus independently required two-borrow and Void/String verifier coverage project 1294–1339 readable physical test lines); at most 3 language fixtures/100 added lines; public docs at most 40 added lines. Count comments/blanks and report each category separately; stop before a breach, without compressed formatting/deleted coverage. New fixtures provisionally cap 205000 allocations/600000000 normal instructions using current CWD precedent (`test/e2e/test_current_directory.brp:16`), subject to evidence; retain every tighter existing/diagnostic cap. Update this API in README/grammar/ROADMAP/parity/temp docs with implementation; no M6-complete claim.

Future serialized correctness loop after root grant, from repository root (make/recheck host if not intended FRESH):

```sh
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_check/test_write_file.brp
bin/blorp test --suite --timeout 180 blorp_2/test/runtime/test_write_file.brp
bin/blorp test --suite --timeout 180 blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
BLORP_CC=/usr/bin/clang BLORP_2_INSTRUCTION_CHECK=required make -C blorp_2 test-compiler test-e2e
make hygiene-check artifact-scan
git diff --check
```

Register the e2e suite in test_end_to_end; build pilot once and each unchanged fixture once at O0. Retain supported Linux Clang/GCC correctness/sanitizer evidence separately. Root pins actual accepted B/candidate C, normal/diagnostic supporting host pair, host/target libraries, complete registered baseline inputs including rejections, CWD/paths/flags/toolchain and source/input/C/binary hashes before costs. Concrete paths are future coordination work, not a new permission mechanism. Generate actual B/C pilot C once, link unchanged C at O0 with BLORP_MEMORY_DIAGNOSTICS=0/1 and -lm -lpthread per Makefile; use these recorded bindings:

```sh
"$producer" compile --no-format --std-dir "$host_std" -o "$pilot_c" "$target_src/blorp_2/src/main.brp"
"$cc" -O0 -DBLORP_MEMORY_DIAGNOSTICS=0 "$pilot_c" -o "$pilot_normal" -lm -lpthread
"$cc" -O0 -DBLORP_MEMORY_DIAGNOSTICS=1 "$pilot_c" -o "$pilot_diag" -lm -lpthread
env -u BLORP_MEMORY_STATS BLORP_LEAK_CHECK=strict "$pilot_diag" --library-root "$target_std" "$input" "$out_c"
/usr/bin/time -l -o "$time_log" env -u BLORP_LEAK_CHECK -u BLORP_MEMORY_STATS "$pilot_normal" --library-root "$target_std" "$input" "$out_c"
/usr/bin/time -l -o "$proxy_time" env -u BLORP_LEAK_CHECK -u BLORP_MEMORY_STATS "$normal_host" compile --no-format --std-dir "$host_std" -o "$proxy_c" "$target_src/blorp_2/src/main.brp"
env -u BLORP_MEMORY_STATS BLORP_LEAK_CHECK=strict "$diagnostic_host" compile --no-format --std-dir "$host_std" -o "$proxy_diag_c" "$target_src/blorp_2/src/main.brp"
```

Require serial B/C,C/B,B/C normal samples/minimum-of-three instructions and separate strict allocation/release counts. Feature-local hard ceiling is +5% allocations and normal instructions for EACH shared input AND fixed host source-to-C proxy; preserve all R0/local+cumulative 3% source-refactor rules, frozen epochs and stricter fixture caps. Within-variant normal/diagnostic C must match; unchanged-input C/diagnostics stay exact across B/C; review intentional compiler-C changes without normalization. Pilot/native strict zero and positive balanced counts remain mandatory; retain host strict status 99/leaks and completed-output validity, subtract nothing. New-only calls have no invented baseline. Label costs as owned-input/fixed-host proxies, not self-compilation, and state omissions.

Hand back branch/diff/hash, separate physical LOC, exact red/green/restored mutations, C and gate verdicts, raw commands/artifacts and every per-input cost verdict in one benchmark report. Root plus independent code-reviewer/test-runner review precede plan commit and future implementation/commit. Stop for an ordinary mixed-Result gap, unapproved mechanism, new host bug, contract ambiguity, ABI/budget drift, unexplained C or cost breach; report the smallest reproduction/direct options to root. Those original evidence gaps are closed by the linked report. Every shared invocation and the fixed supporting-host proxy passes the unchanged +5% allocation and normal min3 instruction gates. This FEATURE proxy uses full exit TOTAL allocations with memory stats unset, not the SOURCE artifact-construction checkpoint. Both supporting-host strict calls remain FAILED status 99 under the documented host-only exception; target/native strict zero remains binding. Original source-refactor epochs and historical failures are preserved without subtraction or denominator changes.
