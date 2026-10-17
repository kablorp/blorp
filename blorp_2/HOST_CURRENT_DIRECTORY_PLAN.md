# Return a checked current directory from the supporting host

## Status and problem

Supporting-host implementation and the reviewed validation are complete.
All four cost caps, exact fixpoint and actual candidate-host API checks pass.
Root and independent code/evidence review approved; only docs review and
integration remain pending. Target library/loader integration is separate M6 work.

[M6](ROADMAP.md#seven-shell-and-path-functions) approves
`get_current_directory() -> Result[String, String]`. At the original planning base
the host had only `getcwd() -> String`. Its fixed buffer and empty failure sentinel cannot satisfy
that contract. This is a missing API, not an executed runtime regression.

At that base the search found the old declaration/builtin and native implementation,
not the new API. No pre-implementation behavioral red was claimed.
The legacy control and subsequent mutant results are recorded below. New API
absence is an availability failure, not evidence that a native failure oracle
has executed. Post-implementation mutants prove those behavioral oracles.

Current source (`standard_library/src/system.brp:123`):

```blorp
func getcwd() -> String:
    builtin("blorp_getcwd")
```

Current source (`blorp/src/lib/runtime/native/runtime.c:39164`):

```c
blorp_String* blorp_getcwd(void) {
    char buf[4096];
    if (getcwd(buf, sizeof(buf))) {
        return blorp_string_create(buf);
    }
    return blorp_string_create("");
}
```

## Contract, ownership and permitted files

Add one host API, leaving the old API/body/callers untouched. It is impure and
takes no arguments. Ok owns a fresh, nonempty absolute String containing exactly
the valid UTF-8 pathname the OS returned; do no extra normalization, symlink
lookup, trimming or Unicode repair. Err owns valid text and prints nothing.
No environment/PWD fallback, fixed maximum path buffer or empty success sentinel.
OOM retains the existing checked allocator's infrastructure-failure behavior.

Grow only for ERANGE. Other OS failures, including EINTR, return immediately;
pin that policy with call-count/error tests rather than silently adding retries.
Save errno before cleanup. Its exact message is
`get_current_directory: failed; errno=<platform decimal code>`.
Representational exhaustion uses EOVERFLOW with that same format. Validation
failures use the exact fixed messages in the native implementation, without
claiming an OS errno. Native success shape precedes UTF-8 validation.

The raw allocation is private staging, with one current owner across realloc.
No managed pathname exists before validation. After validation create one owned
String, free staging, and transfer the String once to an ordinary existing Result.
Both tags have release-mask bit zero set. The Core caller owns the outer Result;
dropping it drops its String once. An escaping matched String gets the normal
independent owner before its Result dies; it is not a borrowed native pointer.

Current precedents are `runtime.c:4635` (counted UTF-8 predicate), `:4712`
(`blorp_string_create_len`), `:8434-8465` (existing Result factories),
`ownership.brp:693` (zero-argument owned builtins), and
`type_system/builtins.brp:241` (legacy getcwd effect metadata).
The ordinary `builtin("...")` body carries its C name; no bodyless-builtin
registry or backend special case is needed.

| Owner | Reviewed implementation |
| --- | --- |
| `standard_library/src/system.brp` | New documented monomorphic API beside getcwd |
| `blorp/src/lib/runtime/native/runtime.c` | One directory query and its private numeric-error helper |
| `blorp/src/lib/runtime/native/runtime_decl.c` | `blorp_Result* blorp_get_current_directory(void);` beside getcwd |
| `blorp/src/compiler/stage_09_core/ownership.brp` | Add C name to `BUILTIN_NO_ARGS_OWNED`; arity zero, ReturnOwned |
| `blorp/src/compiler/stage_06_typecheck/type_system/builtins.brp` | Register public name as `ImpureNonWaiting`, beside getcwd |
| `blorp/test/test_runtime/test_sys/test_current_directory.brp` (new) | Public API tests and native-fixture orchestration |
| `blorp/test/test_runtime/test_sys/fixtures/current_directory.c` (new) | Direct native helper tests with local libc wrappers |
| `blorp/test/test_compiler/test_stage_09_core/test_core_ownership.brp` | Named zero-argument owned-result and wrong-arity assertions |
| `blorp/test/test_compiler/test_stage_06_typecheck/test_type_system/test_builtins.brp` | Named registration/impurity/non-parking assertions |
| `docs/GUIDE.md`, `docs/GRAMMAR.md` | Short matching public contract/example; no new syntax |
| This plan | Reviewed decisions and final bounded evidence |

Implementation stays within these owners. Existing compiler suites already
have manifest owners; the new runtime suite needs no manifest entry. A later
docs-only grant permits the bounded M6 host-status paragraph in ROADMAP;
other global roadmap/parity changes remain separate. No target namespace/checker/
specialization/runtime/library or loader
changes, broad legacy rename, new Path/Bytes/FFI surface, filesystem abstraction,
cache, test controller, production tracing or error-string classification.
The pre-read foundation-root-role placeholder is separately deferred.

## Implemented code

The wrapper is `standard_library/src/system.brp:127-129`; GUIDE contains its
ordinary Result-handling example. The legacy wrapper/body/callers are unchanged.
The native implementation is `runtime.c:39172-39217`, with its declaration,
effect classification and zero-argument owned-result contract in the owners above.

The named 256-byte seed is a growth choice, not a pathname limit. Capacity
includes the terminator and is bounded by LONG_MAX+1, so strlen's successful
length fits long. Only ERANGE grows; checked allocators retain OOM handling.
Successful getcwd supplies a terminator within capacity: never scan spare bytes
or inject unterminated success as a supposedly safe strlen-validation test.

Shape and counted UTF-8 validation precede managed pathname allocation. The
ordinary Result factory owns the fresh String after staging is freed. Numeric
errors reuse decimal append, which consumes its prefix; no fixed error buffer,
locale-sensitive strerror, new Result shape or second UTF-8 decoder was added.
Production code is authoritative; retained hashes below identify what was built.

## Tests, mutations and acceptance

Blorp TestSuites own all tests. Reuse the direct-include/compile-once precedent in
`test_read_file_safety.brp:198-247` and `fixtures/read_file_admission.c:1-56`.
The new C fixture includes the production runtime and minicoro unchanged,
compiled with memory diagnostics plus ASan/UBSan. Test-local getcwd/free/realloc
wrappers delegate to real libc except the deliberately scripted query outcome;
they introduce no production hook, generic fault matrix or replacement main for
a language fixture. Every named native case is a Blorp callback.

Public callbacks: `current directory matches the current host directory`,
`ignored Results release across repeated calls`, and
`matched directory survives its Result scope`. Compare normal native CWD with
the legacy API only in the ordinary short-path integration case; do not infer
the new failure contract from the legacy sentinel. Run the suite with leak checks.
Core tests assert `builtin_contract("blorp_get_current_directory", 0)` is exactly
`{ args = [], result = ReturnOwned }` and arity one is rejected. Type metadata
tests assert registered, impure and non-parking behavior.

| Named native case | Required independent oracle |
| --- | --- |
| Real OS success | Exact bytes against a delegated libc query; nonempty absolute path |
| ERANGE grows beyond the old buffer | Script a valid absolute path longer than 4096 bytes; observe increasing capacities and eventual exact success |
| Growth then syscall failure | ERANGE followed by EACCES; exact saved platform code, no success or live staging |
| EINTR returns an error | One query, exact EINTR text; no implicit retry |
| Cleanup cannot replace errno | Free wrapper changes errno; returned decimal remains the captured failure |
| Valid multibyte/whitespace path | Preserve all pathname bytes and counted length; no normalization |
| Terminator excludes spare capacity | Valid terminated path with malformed bytes after it; returned String excludes those bytes |
| Malformed UTF-8 path rejects | Exact fixed error for overlong, surrogate, truncated and bad-suffix inputs before String publication |
| Empty/relative native success rejects | Exact fixed shape error and one staging cleanup |
| Each call owns its pathname | Keep two Results alive; distinct fresh roots, exact bytes, independent destruction |
| Result owns either payload | Both tags have mask 1; releasing only Result frees its payload once |

All cases observe real allocations/frees by occurrence, not by dereferencing
freed objects or conflating a reused address. Raw-event counters survive managed-stat
resets; fixture assertions use per-query raw-event deltas. Realloc transfers the one staging
obligation; final free occurs once. After releasing Result, managed counts must
balance with zero live objects and staging must be gone. Successful native calls
use exactly two managed allocations (String + Result), one raw initial buffer
and the observed growth reallocs. Fixed validation errors use two managed
allocations. Numeric errno cases use three managed allocation occurrences:
prefix String, new appended String and Result; append frees the prefix before
return. Releasing Result completes three releases/live0. Assert counters active.
No managed pathname allocation precedes validation; a fixed-error case's
allocation count must expose one.

The >4096 test is synthetic sizing coverage, not a claim the real OS accepts
arbitrarily long paths. The real OS may return ENAMETOOLONG or another error;
preserve it. Capacity-exhaustion/allocator-OOM branches receive source review;
do not add a production limit override or unsafe huge-allocation probe to fake
executed coverage of those branches.

Prove separate compile-successful mutants: return ERANGE instead of growing;
read errno after cleanup; bypass UTF-8 validation; omit final staging free;
clear the Result payload release mask. Each intended named assertion must fail.
Restore exact source bytes and rerun green after each. A build error, timeout or
unrelated failing callback is not a kill. Keep raw diffs, logs and source hashes.

The executed focused/scoped gates and their exact results are retained below.
FRESH was required before direct tests; the native C fixture was staged for the
unchanged artifact-scan policy. The ordinary GUIDE example compiled to raw Core/C:
its native boxed Result is consumed by stack_result_from_boxed, its owned payload
moves through the existing adapter, and main releases the stack Result after
matching. No generated C or fixture entrypoint was rewritten.

## Costs, freeze boundary and limits

A disk stdlib edit selects declarations, not an executable's embedded runtime.
Own FRESH hosts were built with matching runtime/declarations; the original
source-refactor host/stdlib epoch was not changed. This host prerequisite does
not authorize target M6 wiring, loader diagnostics or M8 self-compilation.

The existing self_compile_measure --stage2 harness rebuilt a normal/diagnostic
pair for each workload, separately, before 3 normal samples. Setup time is not
measured CLI cost. Each pair, stage1 host, C output and JSON was archived before
the next build. There were no reused samples, retries, filters, toolchain waivers,
new controller, normalized C or cost/epoch resets. All original samples remain.
For self and small independently, positive allocation totals and normal min3
must each satisfy the unchanged +0.5% cap: exact integers 200*C <= 201*B.
Self caps passed before candidate small; all four passed before embedded C/fixpoint.

Measured CLI calls use --no-embed-runtime and one frozen stdlib. Normal and
diagnostic C agree within every pair; full raw B/C measured outputs are compared.
Build-C instead uses each variant's own compiler/stdlib tree. Root and independent
compiler/API review approved producer-backed review of source-to-ID projection,
representative stable/shifted symbols, unchanged tag/layout facts, actual effect
and ownership additions, complete embedded stdlib source, literal-pool IDs and
serialized ownership. Full raw diffs stay retained; not every build-C hunk is
manually attributed, and no normalized/general equivalence claim is made.
Stop on caps/input/tool drift, unexpected semantics, retention or tool defects.

Keep non-telemetry behavior/diagnostics checks separate from JSON phase/memory/time
metrics; the harness does not preserve raw compiler stdout/stderr. Generated
output-path messages are not an identity oracle. O2 supporting-host fixpoint
requires exact stage2/stage3 C; it does not establish pilot self-compilation.
The existing suite must also run on the actual candidate stage2 or stage3,
with explicit candidate stdlib, because frozen DDD does not contain the new API.

Original ceilings remain 130 gross/+120 net production, 500 gross/+480 net tests,
and 24 gross/+24 net public documentation; this plan is limited to 360 lines.
Actual production is +56/0 deleted; tests +375/0 deleted. GUIDE/GRAMMAR add 20,
ROADMAP adds 3/deletes 5; the API comment adds 1: 24 gross/+19 net public docs.
The API comment is also included in production's 56; no test coverage was deleted.
Only the two named new test files were added. Final reviews precede commits.

## Retained acceptance

B is `ddd1855092c1daec0726eb929207de4a1506e34c`:
host source tree `33d50604c606ce0eaaa7dddd6f11783e8b66eed2`, stdlib tree
`797e50bb0c5109ae7b8a35fbe15a0027c0879203` (including accepted dirname).
C is `59679bf6b9d00688a0d78dd056958528b36d38d9` plus the unchanged reviewed
11-file feature patch `c91eda21521c9d0f36e6ce0cd988fe05f6ad28db51028b7cb1ed91e1070082dc`.
Its exact 600-file source/91-file stdlib manifest is retained at
`build/host-current-directory/offline-cost-source-manifest.json`, SHA256
`b5543b284def30b5b33a00ed53555ae6c5deda4c308bd38949e7233be9af8d4a`.
The 11-file source map SHA256 is
`200d2265943f3e11e2f46a9b8188c7159fe5b1755e9b02d39559ada625f609fb`.
The plan/ROADMAP acceptance refresh is a separately reviewed docs-only delta.

Listed cost/fixpoint compilers use CLI/runtime O2, split 8, aarch64-apple-darwin;
normal memory diagnostics=0, diagnostic=1. Invocation variables were
BLORP_CLI_C_OPTIMIZATION=-O2 and BLORP_MEMORY_DIAGNOSTICS=0; the existing builder
links normal/diagnostic runtime modes separately. Exact compile/link flags and
recipes remain in cost/B/setup/source/ and fixpoint.log. Each workload rebuilt
its own pair; actual normal/diagnostic hashes match across self/small per variant.

For reproduction, use the recorded environment in each B/C worktree. Repeat
with --program small and distinct fresh output paths; preserve retained records.

```sh
benchmarks/self_compile_measure --stage2 --samples 3 --program self \
  --input-rev ddd1855092c1daec0726eb929207de4a1506e34c \
  --output build/current-directory-self.json \
  --keep-output build/current-directory-self.c
```

| Compiler artifact | SHA256 |
| --- | --- |
| B FRESH stage1 | `20e63f96dfef1d882ddfa305ded4598cc1d743d1e81baf974ff4d2abf5e1cbff` |
| C FRESH stage1 / pinned mutant driver | `324e6e476314660dfa9b8f09c856e50f2fc1494c16224aad3d27da6b5d751e2e` |
| B normal stage2 | `41ad632a0959ae4a04ced568f5c15ebe5cab47f0d51698e273b84e66f62e31ca` |
| B diagnostic stage2 | `49481d03056b65941e25eea2ccc4b7cedef4668d981b6023dd2e278bf9981a1a` |
| C normal stage2 / API host | `46d4a132c42ae012beacd153b143f59f108fc51c8b550267db9e8a01c1ed02c6` |
| C diagnostic stage2 | `df1caea8220069c2bd422826d16d320dc4f77ceaddcf27221e1ba2e4ba6191bd` |
| C fixpoint stage3 | `af6f417941fab30e7d6cda5be7ba65b5926b9fb4701e3b32e7cfe64272e9b4ad` |

Bootstrap is dev-0e1598ed616e; verified aarch64 macOS asset SHA256
`f0ddd748f51b2f449a46d5bfcf30aeb9c2f2f07468d761514dd408b40ca3ee91`.
BLORP_CC=/usr/bin/clang is Apple clang 21.0.0 (clang-2100.3.34.2), command SHA256
`5b1ddb7e9c11b87a034fc88b212e8ac243cfe2b4db696d767aa44c79595fc09a`;
resolved Xcode clang SHA256 is
`1590ac950a3d627817d09ade5cb60b2115f17a72182a3141e010b4bcc482a0c9`.
DDD is the single frozen input revision: all 3534 Git blobs plus marker/embedded
stdlib (3536 files) match; full manifest SHA256
`630c0fbdbbf361f8376ceaae4c9cfd553a48486802d77a0c0ce605fc5b959ca6`.
Embedded std SHA256 is `4a0b6f4ae1dbe9273b100117071adce40983af1a92986334f811389bb10572a1`;
small.brp bytes SHA256 is `6a67158fb09aac383ec40e77e5c5b1d64fd068b19edf6e2596a6f25060d9cc93`.
Every source/tool/pin/host/frozen-input hash matched before and after execution.

| Workload / metric | B | C | Change | 200*C <= 201*B |
| --- | ---: | ---: | ---: | --- |
| Self allocations | 289945739 | 289945739 | 0% | pass |
| Self normal min3 instructions | 271451606225 | 271423361096 | -0.0104052% | pass |
| Small allocations | 1760226 | 1760226 | 0% | pass |
| Small normal min3 instructions | 1660851368 | 1661249903 | +0.0239958% | pass |

| Workload / variant | All three normal instruction samples, retained order |
| --- | --- |
| Self B | 271451606225, 271875132474, 271839938201 |
| Self C | 271423361096, 271863962502, 272016603385 |
| Small B | 1694804925, 1660851368, 1661165928 |
| Small C | 1693629326, 1661259816, 1661249903 |

Normal/diagnostic C is exactly equal in all four pairs; B/C measured self/small
C is exactly equal. Self SHA256:
`ed7bf38e785ceece18f7d7f4a881e792a81d65af406b157764102dcd1b47e4da`;
small `5b45cea5855e12bc9a7820536e82d44b3570b82d27cd0e366fcb773dc0900a4b`.
All three fixpoint C outputs are byte-identical, SHA256
`dde67f22f39be0a64421fb523eb39ee68c8fa89256eaa41efa7285eef52a43cc`;
stage2/stage3 cmp and full diff both exit 0.

The own-tree compiler-C diff is 23316025 bytes/24188 hunks, retained unchanged.
The new stdlib callable advances sequential definition IDs before DCE; the first
TomlString tag symbol shifts 8vh to 8vi with ordinal 0/layout unchanged. Actual
effect dispatch and ownership dictionary insertion are reviewed as additions;
the complete B/C embedded system literals exactly match their source bytes.
Literal-pool and serialized ownership changes are described from their producers,
not presumed all renames. The approved granularity limit above remains explicit.
The two ordinary stage1 embedded small C files have one full raw B/C diff:
14953 bytes/23 hunks, all reviewed as the native helper addition and expected
callable/closure ID shifts. No rewritten/normalized C or extra embedded pair.

| Executed correctness evidence | Result |
| --- | --- |
| Focused trait/builtin/Core suites | 39 passed, exit 0 |
| compiler-check --changed, including Core sanitizer | 2703 passed, exit 0 |
| std-check / runtime / doctest | 1 / 4844 / 1067 passed, exits 0 |
| Hygiene / artifact scan / whitespace | pass |
| Candidate stage2 existing current-directory suite | 4 outer / 13 nested native, exit 0 |

The four outer callbacks are three public API behaviors plus one native launcher;
13 nested native cases are not additional public callbacks. Broad/focused/mutant
repetitions overlap; do not sum their counts as unique coverage. Native cases
use O0, diagnostics=1 plus ASan/UBSan. The candidate stage2 driver's final footer
is 3 allocations/3 releases/0 leaks/0 bytes. TestSuite resets counters per outer
callback and after the suite: that footer is the final driver epoch, not total
API/child-process traffic. Native child assertions prove their own ownership.

| Compile-successful mutant | Intended native failure | Red failures / 13 |
| --- | --- | ---: |
| Return ERANGE instead of growing | ERANGE grows beyond the legacy buffer | 2 |
| Read errno after free | cleanup cannot overwrite saved errno | 1 |
| Bypass UTF-8 validation | malformed UTF-8 rejects before publication | 1 |
| Omit successful staging free | Ok owns and releases its String once | 6 |
| Clear successful payload mask | Ok owns and releases its String once | 6 |

Each mutant exited 1 after native compilation succeeded; exact source restoration
then passed 13 native cases and 4 outer callbacks, exit 0, with FRESH host/hashes.
Only nested native callbacks compiled the mutated runtime. Public callbacks ran
in test drivers using the unchanged runtime embedded in the archived compiler;
they prove no mutant behavior. The legacy control log passed one test, but its
exact process exit was lost in bookkeeping; no exit status is fabricated.
That borrowed CLI-O0/runtime-O2 control host was
`cc0038ef024c63228c47edc00b0bfa7296147753235ba5645045482648cbed78`, not a cost baseline.
Passing compiler-check nested logs were deleted by the documented runner policy;
its outer stdout/footer remain retained.

Raw samples, all 48 phase checkpoints per record, C, binaries, versions, flags,
mutants, stop history and producer account remain under ignored
`build/host-current-directory/`. Final cost receipt is `cost/final-result.json`,
SHA256 `f0c60e23dcd65e93773e9fb71a42af74da0cfaed484dde174b761a72c791c797`;
its 106-entry artifact manifest SHA256 is
`67c22ca0592dcbbbb046670cfd90f416a5b5f364b7b84a38ee0e87de084b272a`.

Validation ran on native aarch64 macOS/Apple clang only; Linux, x86_64 and other
C toolchains were not run. Full compiler-blorp/compiler-new/parity, dedicated
leak/CLI, full premerge/Docker/release gates are not claimed. Capacity exhaustion
and OOM are source-reviewed only; long-path sizing is synthetic, not proof of
OS acceptance of arbitrary lengths. Measured frozen input omits the new API;
the actual candidate-stage2 suite covers it separately. Target Result/library
contracts, target native helper/emission and loader CWD/error integration remain
pending M6 work; this does not complete M6, M8 or a frozen-host epoch transition.

## Handback and review gates

Code/evidence review is approved; final docs review and root integration remain.
Root owns integration and publication. No merge, rebase, commit, push,
baseline replacement or new epoch is authorized by this status refresh.
