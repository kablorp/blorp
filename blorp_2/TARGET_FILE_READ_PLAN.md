# Target read_file publishes counted UTF-8 through the designated Result

## Problem, authority, and dependencies

Implemented and validated, including final destination unit/runtime/grammar and
e2e gates. Root/peer review is complete. The [evidence report](../benchmarks/results/blorp_2_target_file_read_2026-10-17.md)
records gates, matched costs and the separately failed supporting-host strict checks.
[M6](ROADMAP.md#seven-shell-and-path-functions) needs
`func read_file(path: String) -> Result[String, String]`; the target adapter and
builtin are implemented. This adds one shell API, not loader migration, write_file,
path/stderr APIs, frontier progress, or self-compilation. Loading remains the
effect boundary; the compiler pipeline after loading stays pure.

Accepted CWD and host numeric-file-error source/library baseline is
`891f64c989a9c0b30002c3e98d8fce028de1ddb1`; temporary adapter provenance pins it.
Frozen source/library, host/pilot pairs and corpus hashes are retained in the report.
The known host leak follows [the bootstrap decision](HOST_BOOTSTRAP_LIMITATIONS.md).

## Witness and expected behavior

`test/e2e/fixtures/file_read/basic.brp` uses the ordinary entrypoint:

```blorp
import:
    system: read_file
    list: get
    io: print
func main(arguments: List[String]) -> Int:
    match get(arguments, 1):
        None:
            print("missing path")
            2
        Some(path):
            match read_file(path):
                Ok(contents):
                    print(contents)
                    0
                Err(error):
                    print(error)
                    1
```

Argument zero is the executable; `argument_input/basic.brp` establishes index1.
Future reproduction: `$compiler_B --library-root "$library_B"` followed by
`blorp_2/test/e2e/fixtures/file_read/basic.brp build/file-read/basic.c`.
B should reject the missing read_file import; record its actual diagnostic,
help/span, exit, and untouched output before code. No red execution is claimed.
After implementation, compile once and pass explicit temporary data-file paths:
Ok prints exact contents plus one LF, exits0; Err prints exact error plus LF,
exits1; stderr is empty. Prepare OS data files, never rewrite BRP inputs or C.
Accepted and pending-CWD `io.brp` provide only print, not print_error. These stdout
errors, including missing-path usage, are fixture oracles, not the compiler-shell
M6 stderr contract; print_error and loader migration remain separate.
Target `runtime/string.brp:106` uses counted fwrite then LF; its print_bytes test
covers NUL. Compare stdout Bytes and independent native length/memcmp beyond NUL.
Add file_read/ownership.brp for an ignored result and a String escaping its Result.
Third fixture file_read/nul_path.brp constructs `read_file("input\0suffix")` in
ordinary main. Its driver creates readable `input` and passes an explicit temp CWD;
argv cannot carry NUL. Expect exact NUL-path Err/status1; never rewrite the fixture.

## Proposed solution: reuse the CWD facts

Pending CWD provides ResultResult(success, error, constructors); DesignatedResult
carries opaque ok/err IDs. Its Impure zero-argument call owns either String branch.
Read-file adds `ReadFileBuiltin` / `ReadFile(DesignatedResult[Variant])` with:

```text
parameters = [PrimitiveRuntimeType(BuiltinString)], purity = Impure
return = ResultResult(PrimitiveRuntimeType(BuiltinString),
                     PrimitiveRuntimeType(BuiltinString), designated.result)
checked type = AppliedUnionType(variant_owner(result.ok), [StringType, StringType])
```

| Producer (paths under src/) | Published fact / consumer |
| --- | --- |
| `utils/syntax`, `parse/parse` | Exact `system.read_file` label, parsed tag/span; no new syntax form |
| `namespace/builtins:43,105,143` (pending CWD) | One designation supplies Ok/Err declaration IDs; runtime_contract alone owns purity, one String parameter, ordered payloads |
| `check/signatures:385,410` (pending) | Accept ReadFile with those IDs; reject generic/pure/wrong arity/type/result/tail annotations; ordinary pure callers reject effects |
| `specialize/specialize:2052,2164` (pending) | Reuse translate_result in the call's concrete result instance; runtime_signature reads ResultResult |
| `lower/lower`, `own/own:614` | One borrowed path operand; InlineOwningPayload Result becomes OwnedResult; normal projections/acquire/drop rules |
| `verify/verify:452` (pending) | Independently check arity/types, both payloads, distinct complete variants/common owner, result membership and ownership; no name recovery |
| `emit/emit:1141,1233,2040,2498` (pending) | One ReadFile call, typed constructor transfer, inventory-selected fragment; no repeated signature solving |

Use the CWD signature error text unchanged: `builtin declaration does not match
its runtime contract`; read-file help is exactly `declare an impure nongeneric
function with one String parameter returning Result[String, String]`.
Keep label span/no note. Do not introduce Result/FFI registries or another carrier.
Update exhaustive observers directly. Generic lower/own/verify production should
already suffice; report a concrete gap before expanding their design.

Pending emit:1154 calls `blorp_get_current_directory(&scratch)`.
Read-file instead calls `blorp_read_file(path,&scratch)` once with the borrowed path.
Both use `c_union_value(result.ok/err, [scratch])` by actual designated IDs;
transfer that String once, with no scratch retain/release afterward.

Add operation-specific emission beside CWD, reusing c_union_value and active-slot
dup/drop. No host Result box. Export literal SYSTEM_READ_FILE_RUNTIME from
runtime/system.brp, selected only for reached calls. Add the temporary system
declaration with the host signature; do not put it in the implicit prelude.

## Total native contract and cleanup

```c
uint8_t blorp_read_file(const struct blorp_string *path,
                      struct blorp_string **result);
/* BLORP_READ_FILE_OK=1, BLORP_READ_FILE_ERROR=0. Every normal return assigns
 * one owned nonnull UTF-8 String. Input is borrowed; status is not a union tag. */
```

Use existing `string_runtime()` validation, trusted counted factory, and release.
At `runtime/string.brp:50` the factory mallocs even length0 with references1;
there is no empty singleton. Empty success uses that factory after close, with
no malloc(0) or new cache. Validate nonempty staging before calling the factory.
Copy counted path bytes into private terminated storage, rejecting embedded NUL
before fopen. Open rb, seek end, ftell, seek start, allocate raw content staging,
and perform one counted fread. Close before UTF-8 admission/publication. Stable
regular files are the supported input; streams and concurrent snapshots are not.
No arbitrary file/path ceiling: check representability against Int64 and SIZE_MAX
including the String header/terminator; named EOVERFLOW reports an unrepresentable
size. On supported LP64, LONG_MAX=INT64_MAX < SIZE_MAX-header-1, so positive ftell
cannot reach that size guard. Pin the inequality by native _Static_assert and
source-review the guard, without claiming execution coverage. A named tell_overflow
case returns ftell=-1/errno=EOVERFLOW, expecting numeric tell-failed Err and one close;
it tests the reachable OS-error route, without huge allocation or a fake wide long.
OOM keeps existing target malloc-abort policy. No growth/retry IO algorithm.

Snapshot errno immediately after failure, before ferror, close, free or formatting.
On short read save first, query ferror once, close once, free staging, then Err.
ferror set selects numeric read failure; otherwise retain exact short-read text.
Primary failure beats cleanup; close failure beats malformed encoding. Attempt
close once including EINTR, never use that FILE afterward. All normal returns
free private path/content buffers; every acquired stream is consumed by one close.
Real close/EINTR descriptor outcomes are platform-sensitive: delegated-close
tests prove one attempt/no FILE reuse, not universal OS descriptor closure.

| Failure | Exact payload (numeric suffix is saved platform decimal int) |
| --- | --- |
| Open / seek end / tell / seek start | `read_file: open failed; errno=` / `read_file: seek end failed; errno=` / `read_file: tell failed; errno=` / `read_file: seek start failed; errno=` |
| Read I/O / close / unrepresentable size | `read_file: read failed; errno=` / `read_file: close failed; errno=` / `read_file: size failed; errno=` (EOVERFLOW) |
| Non-I/O short read | `read_file: short read` |
| NUL path | `read_file: path contains embedded NUL; use a path without NUL` |
| Malformed contents | `read_file: invalid UTF-8; save the file as UTF-8` |

The target deliberately omits the host's `, or use read_bytes for binary data`:
read_bytes is unavailable; UTF-8 rejection semantics remain identical. At
implementation update ROADMAP's M6 Read bullet and LIBRARY_PARITY's read_file row
with this teaching-text exception, alongside README; do not alter the host message.
Use a named bounded stack numeric formatter then the existing String factory.
Fixed ASCII only; no strerror, printing, repair or byte decoding.

## Test-first coverage and oracle mutations

First checker witness must reject before tags, then succeed via existing parse/check.

| Boundary | Required named checks |
| --- | --- |
| Parse/namespace/check | Exact label/span/help; arities0/2, wrong parameter/result, pure/generic wrappers, tail annotation, pure caller; published ReadFile IDs and ordered String payloads |
| Specialize/lower/own | One operand/span; concrete/reversed declaration IDs; InlineOwningPayload; borrowed path; fresh result, unused/duplicate Result, both projections, escaping child acquired before parent drop |
| Independent verifier | Missing/duplicate/cross-owner variants, wrong either payload, wrong operand/return type, unmanaged result, missing/duplicate owner drops; both String payloads cannot themselves distinguish swapped roles |
| Emitter/runtime publication | One invocation, actual designated IDs in both branches, no scratch release/extra retain, fragment absent without calls; small mirrored runtime/system unit |
| Real main | Empty/multibyte/CRLF/BOM/NUL success; missing/NUL path and invalid encoding Err; exact stdout Bytes/status/stderr; ignored result and escaped payload |

Native owners: `test/runtime/test_file_read.brp` and `test/runtime/fixtures/file_read_test.c`.
TestSuite includes unchanged production String/system and verified aggregates:
C11/O0/Wall/Wextra/Werror/pedantic, ASan/UBSan/no-recovery. Named callbacks and
headers before aliases; wrappers delegate real IO/alloc/free, scripting selected
outcomes. No language-symbol calls, alternate main, C rewrites or production hooks.
Cases: empty/multibyte/NUL/CRLF/BOM, forbidden leads/continuations/overlongs,
surrogates/above-max/truncation, NUL-path/no-open, ENOENT, seek/tell/EOVERFLOW,
EIO/EINTR prefix reads, EOF/stale errno, close ENOSPC/EINTR and combined failures.
Poison errno in ferror/free/close independently. Check the actual FD with EBADF
before counters/oracle opens. Observe actual path-copy destination by exact live
source identity, staging via fread destination, and output via out pointer; clear
identities before free/reuse, never infer allocations by size/order or read freed
objects. Guard every active close before libc to catch duplicate/unowned FILEs.
Assert raw staging/path free once, borrowed input bytes unchanged, output ref1,
and ordinary active Ok/Err String destruction once, including empty/two live calls.
Mutate saved errno, EOF classification, UTF-8 gate, staging/path free, duplicate
close, constructor selection and owner/drop separately; compile-successful intended
assertion reds, exact restore/hash check and owning green after every mutation.

## Before-code budgets, commands, and acceptance

| Physical scope | Estimate added/net | Hard ceiling added/net |
| --- | --- | --- |
| Production including temp declaration | 225–280 / +210–265 | 300 / +280 |
| Tests including native C, excluding language fixtures | 1100–1320 / +1070–1290 | 1400 / +1350 |
| Language fixtures | 3 files, 65–95 lines | 3 files, 100 added |
| Public docs (README/grammar/roadmap/parity/temp docs) | 25–38 | 40 added |

Count comments/blanks; remove no coverage or compress formatting. Stop before a cap
breach. New fixtures provisionally bind 205000 allocations/600000000 normal instructions
from CWD precedent, not measured headroom; stop if unrealistic. Preserve all tighter
existing fixture ceilings, including separate harness diagnostic-run limits.

Future serialized correctness commands, only after review and a compiled grant:

```sh
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_check/test_file_read.brp
bin/blorp test --suite --timeout 180 blorp_2/test/runtime/test_file_read.brp
bin/blorp test --suite --timeout 180 blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
BLORP_CC=/usr/bin/clang BLORP_2_INSTRUCTION_CHECK=required make -C blorp_2 test-compiler test-e2e
make hygiene-check artifact-scan
git diff --check
```

Require intended FRESH host, exact diagnostics, phase/native/main checks, sanitizers,
mutation proof and full C inspection. Register the case module in test_end_to_end;
e2e builds the pilot once, each fixture once at O0, then runs its real main.

Freeze B/C, host pair, both libraries, registry/all unchanged inputs (also rejections),
flags/toolchain/CWD and hashes. Generate actual B/C pilot C once using repository
recipes; link unchanged C in modes0/1 per Makefile/compare-compilers, never reconstruct
e74. Existing e2e owns strict counts/absolute limits; relative costs use ordinary CLI:

```sh
env -u BLORP_MEMORY_STATS BLORP_LEAK_CHECK=strict "$pilot_diag" --library-root "$target_std" "$input" "$out_c"
/usr/bin/time -l -o "$time_log" env -u BLORP_LEAK_CHECK -u BLORP_MEMORY_STATS "$pilot_normal" --library-root "$target_std" "$input" "$out_c"
"$normal_host" compile --no-format --std-dir "$host_std" -o "$proxy_c" "$target_src/blorp_2/src/main.brp"
```

Root approves concrete pair/build paths first. Retain all B/C,C/B,B/C normal runs;
require <=+5% allocations and normal min3 instructions per unchanged input AND
host source-to-C proxy. Use matching diagnostic host counters for proxy allocations.
Phase snapshots do not prove strict balance. Pilot/native strict zero and positive
balanced counts remain mandatory; the host-only decision above does not reset R0/3%,
epochs, old packets or samples, or authorize a controller. Within-variant
normal/diagnostic C must match; unchanged-input C/diagnostics must remain exact;
review intentional new compiler-C deltas without normalization. New-only calls
have no fictional baseline; report their native allocation lifetimes separately.
These are owned-input/proxy costs, not self-compile evidence or M6 completion.

Hand back hashes/LOC, red/green/mutants, commands/inputs/C, costs and limits.
Root/peer review precedes code/commit; stop for ABI/budget drift, host defects, C/cost
breach. Implementation, costs, destination validation and review are complete; remaining M6 work is separate.
