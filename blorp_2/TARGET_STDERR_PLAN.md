# Target print_error writes counted String bytes to stderr

## Problem and dependencies

PLAN ONLY at `891f64c989a9c0b30002c3e98d8fce028de1ddb1`, branch `codex/target-stderr-plan`. This document authorizes no implementation, compiled execution, measurement, commit, push, or epoch reset. [M6](ROADMAP.md#seven-shell-and-path-functions) requires `func print_error(message: String) -> Void`; temporary `io` currently exposes only `print`. Land and accept [target read_file](TARGET_FILE_READ_PLAN.md) first, then rebase an approved implementation onto accepted main. Its worker owns shared compiler files until then. This planning checkout is not the future cost baseline.

Shell output stays impure; the whole compiler pipeline after loading, including diagnostic rendering, stays pure. No compiler-shell migration, write_file/path APIs, host trait/generic change, new IR/carrier/registry, IO framework, retry/fallback, global SIGPIPE policy, or self-compilation claim belongs here. The [host bootstrap leak decision](HOST_BOOTSTRAP_LIMITATIONS.md) covers only the supporting host, including its source-to-C proxy; pilot/native strict zero and all cost rules remain binding.

Future witness `test/e2e/fixtures/stderr/bytes.brp` uses its ordinary main:

```blorp
import:
    io: print_error
func main() -> Int:
    print_error("line1\n\0é😀")
    print_error("")
    7
```

Reproduce with `"$compiler_B" --library-root "$library_B" blorp_2/test/e2e/fixtures/stderr/bytes.brp "$scratch/bytes.c"`. Before implementation record the actual missing-import diagnostic/help/span, status, and untouched output; no red execution is claimed here. Afterward compile the unchanged C at O0 and run real main: status7, stdout zero bytes, stderr exactly `"line1\n\0é😀\n\n".to_bytes()`. Use existing `NativeCase.stderr: Bytes` in `test/e2e/harness.brp:23`; no harness abstraction is needed.

## Proposed solution and actual change sites

Reuse StringPrint with `StringPrintErrorBuiltin` and typed `StringPrintError`. One closed label, `string.print_error`, selects the operation; later phases consume its identity, never spelling. `namespace/builtins.brp:133` currently has:

```blorp
StringPrint:
    { purity = Impure, parameters = [PrimitiveRuntimeType(BuiltinString)], return_type = ValueResult(PrimitiveRuntimeType(BuiltinVoid)) }
```

Afterward share that unchanged contract arm as `StringPrint | StringPrintError:`. The concrete temporary signature matches the existing host String instantiation (`standard_library/src/io.brp:31`); unsupported traits are not imported. Current `standard_library/io.brp:8` and its addition are:

```blorp
-- Before (retained):
func print(value: String) -> Void:
    builtin("string.print")
-- After (add):
func print_error(message: String) -> Void:
    builtin("string.print_error")
```

Refresh the adapter's existing upstream revision/SHA256 against accepted host `io.brp`; document the concrete adaptation. Do not change the host API. `runtime/string.brp:106` currently emits `blorp_string_print`: counted `fwrite(...,stdout)`, unconditional `fputc('\n',stdout)`, uint8 zero. Add the literal String constant `STRING_PRINT_ERROR_RUNTIME` beside it, selected only by reached StringPrintError; keep the existing stdout helper unchanged:

```c
uint8_t blorp_string_print_error(const struct blorp_string *value) {
    const size_t length=(size_t)value->length;
    if(fwrite(value->bytes,1,length,stderr)!=length) return (uint8_t)0;
    (void)fputc('\n',stderr);
    return (uint8_t)0;
}
```

Request the complete counted message once, including length0; on a short transfer, including EINTR, return without LF or retry. After a full transfer attempt LF once; an LF error returns Void without retry. Empty input therefore attempts zero message bytes then one LF. Borrow input; allocate/retain/drop nothing. Void conveys no delivery status and stdio buffering prevents a delivery/durability promise. This is the smallest proposed reading of M6's “stop on unrecoverable output error”; approve it before code. Host `runtime.c:7643` currently appends LF even if its fwrite fails; record that narrow failure-path difference in parity/README rather than silently claiming full error-path parity or changing host behavior. Report a contract objection before adding machinery.

| Producer/owner (under src/) | Published fact and consumer |
| --- | --- |
| `utils/syntax:378`, `parse/parse:2553–2559` | Parsed tag, closed label/help and span; update exact label-help observers; no new syntax form |
| `namespace/builtins:72,133,178,184`; `check/signatures:414–445` | Primitive operation; sole Impure/[String]/Void runtime contract; accepted nongeneric signature; exact ordinary diagnostics |
| `specialize/specialize:2149` | Preserve operation in concrete RuntimeOperation and ordinary runtime signature |
| `lower/lower`, `own/own:611` | Existing call/statement path; borrowed String argument, NoOwnership -> UnmanagedResult for Void; no new representation |
| `verify/verify` | Independently validate runtime signature, operand borrow lifetime and unmanaged result via existing contract, without trusting insertion |
| `emit/emit:122,2003,2044,2495`; `runtime/string:106` | Map typed operation to helper; append imported STRING_PRINT_ERROR_RUNTIME only for the separate reached stderr requirement; ordinary call emission |

Generic lower/own/verify production should suffice; test each boundary before changing it. A concrete gap requires root review. At implementation update only this contract in README, grammar builtin-label documentation, ROADMAP, LIBRARY_PARITY and temp-library README/provenance; parent GUIDE/GRAMMAR receive only a necessary user-facing reference if their existing coverage changes. Do not mark shell integration or M6 complete.

## Test first and prove the oracles

Use Blorp TestSuites and small typed inputs/outputs. Extend existing void-print phase/independent-verifier suites directly where that avoids duplicating their builders; new mirrored runtime/helper and checker suites may be `test/unit/test_runtime/test_string.brp` and `test/unit/test_check/test_print_error.brp`.

| Boundary | Named acceptance cases |
| --- | --- |
| Parse/namespace/check | Exact label/span and accepted contract; 0/2 arguments, wrong argument/result, generic and tail annotation. A pure builtin declaration rejects its runtime contract; both pure Int and pure Void callers reject impure effects. Wrong runtime signatures retain `builtin declaration does not match its runtime contract` / `declare an impure function with one String parameter returning Void`; pin exact help/span/note for each, not only status |
| Specialize/lower/own | Operation/signature/span retained; discard is Void, one borrowed String, unmanaged result; literal, live alias, repeat call and selected-arm cleanup; no acquired Void owner |
| Raw verifier, separately | Wrong arity/type/result ownership; unknown/discharged/wrong-owner borrow; missing/duplicate String drop. Assert the exact violated obligation/operation/span |
| Emitter/publication | Only reached stderr emits its fragment; stdout-only, unused stderr declaration and no-output programs omit it; both operations select both fragments; inspect one call with no helper retain/drop |
| Native helper | Counted NUL/multibyte/internal LF/empty bytes; one-request length and stderr stream; input refs/bytes unchanged; zero additional allocation/free and one eventual caller destruction; short/EINTR write prevents LF and repeat; LF failure has one attempt |
| Real main | Bytes witness above; second `stderr/alias.brp` preserves aliases/reassignment and only selected arm output. Exact stdout/stderr Bytes, status and unchanged generated C through existing harness |

Native owner: `test/runtime/test_print_error.brp` builds `test/runtime/fixtures/print_error_test.c` with unchanged production String fragment plus imported STRING_PRINT_ERROR_RUNTIME, C11/O0/Wall/Wextra/Werror/pedantic and ASan/UBSan/no-recovery. The approved direct-C exception covers helper unit tests only. Test-local fwrite/fputc wrappers, declared after libc headers, delegate real stdio for successful bytes and script short/EINTR/LF-error outcomes with exact call counts; allocator wrappers delegate real malloc/free. Observe independent allocation/free counts and refs while live, never freed memory. No generated-language-symbol call, alternate fixture main, C rewriting or production tracing. Stdio-call tests prove one request/termination, not kernel syscall counts or broken-pipe process policy.

Deliberately mutate stderr to stdout, strlen truncation at NUL, missing LF, retry/continue after short write, helper retain/release and an ownership drop, separately. Require compile-successful reds in the intended named assertions; restore exact source hashes and rerun owning green after each. Keep mutation commands/artifacts under ignored build; no mutation framework. Inspect source and emitted C for counted access, uint8 Void, exactly one helper call, borrowed parameter, selected fragment and unchanged ordinary destruction.

## Budgets, future commands, and handback

Before code: production estimate +50–70 physical lines, hard added90/net+80; tests excluding language fixtures estimate +450–650, hard added750/net+750; at most2 language fixtures/45 added lines; public documentation at most35 added lines. Count comments/blanks and report production, tests, fixtures separately; do not compress or delete coverage for a ceiling. New-fixture provisional caps are 205000 allocations/600000000 normal instructions, following `test/e2e/test_current_directory.brp:16`, with evidence required before acceptance. Preserve every tighter existing cap, including diagnostic-run limits; stop if the proposal cannot hold.

After root/peer plan approval and an explicit compiled grant, serialized correctness commands from repository root:

```sh
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_check/test_print_error.brp
bin/blorp test --suite --timeout 180 blorp_2/test/runtime/test_print_error.brp
bin/blorp test --suite --timeout 180 blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
BLORP_CC=/usr/bin/clang BLORP_2_INSTRUCTION_CHECK=required make -C blorp_2 test-compiler test-e2e
make hygiene-check artifact-scan
git diff --check
```

Require intended FRESH host (make/recheck if needed), register e2e suite in test_end_to_end, and build pilot once/fixture once at O0. On supported Linux Clang/GCC retain correctness/sanitizer evidence; macOS retired-instruction cost evidence remains separate. Before any costs root pins accepted read_file baseline B, candidate C, actual normal/diagnostic supporting host pair, both host/target libraries, all registered baseline inputs including rejections, paths/CWD, flags/toolchain, source/C/binary/input hashes and frozen epoch. No historical artifact substitutes for a matched pair. Bind the following variables to recorded paths for each actual B/C variant; generate pilot C once, then link that same C in modes0/1 using repository Makefile/compare-compilers flags:

```sh
"$producer" compile --no-format --std-dir "$host_std" -o "$pilot_c" "$target_src/blorp_2/src/main.brp"
"$cc" -O0 -DBLORP_MEMORY_DIAGNOSTICS=0 "$pilot_c" -o "$pilot_normal" -lm -lpthread
"$cc" -O0 -DBLORP_MEMORY_DIAGNOSTICS=1 "$pilot_c" -o "$pilot_diag" -lm -lpthread
env -u BLORP_MEMORY_STATS BLORP_LEAK_CHECK=strict "$pilot_diag" --library-root "$target_std" "$input" "$out_c"
/usr/bin/time -l -o "$time_log" env -u BLORP_LEAK_CHECK -u BLORP_MEMORY_STATS "$pilot_normal" --library-root "$target_std" "$input" "$out_c"
"$normal_host" compile --no-format --std-dir "$host_std" -o "$proxy_c" "$target_src/blorp_2/src/main.brp"
env -u BLORP_MEMORY_STATS BLORP_LEAK_CHECK=strict "$diagnostic_host" compile --no-format --std-dir "$host_std" -o "$proxy_diag_c" "$target_src/blorp_2/src/main.brp"
```

Retain serial B/C,C/B,B/C normal samples (min3 instructions), strict diagnostic allocation/release counts and timed normal host proxy samples with its matched diagnostic allocations. Per unchanged input AND source-to-C proxy, feature-local hard ceiling is +5% for allocations and normal instructions; all original R0, local/cumulative3% source-refactor rules and stricter fixture caps remain unchanged. Compare normal/diagnostic C within variant and unchanged target C/diagnostics across variants exactly; inspect intentional compiler-C changes. Pilot/native require strict zero with positive balanced counts; retain real host failed status/leak counts under the documented exception, subtract nothing. New-only costs have no invented baseline. These are owned-input and fixed host source-to-C proxies, not self-compilation; report what they omit.

Return branch/diff/hashes and physical LOC, exact red/green/mutation results, C observations, commands/raw paths, gates and each individual cost verdict in one benchmark report. Root plus independent code-reviewer/test-runner review precede plan commit and future implementation/commit; no push is authorized. Stop for host bugs beyond the named exception, API/failure-policy ambiguity, unapproved mechanisms, budget/ABI drift, unexplained output or cost breach; ask root with the smallest reproduction and direct options.
