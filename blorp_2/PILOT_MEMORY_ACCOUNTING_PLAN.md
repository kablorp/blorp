# Strict memory accounting in self-built pilots

## Problem and boundary

Accepted baseline is `ab68426bedd9243208e8568b61abbc015347c0c9`.
Self-built target compilers currently allocate through libc without producing
`blorp: leak check: A allocs, R releases, L leaked, B bytes`; defining
`BLORP_MEMORY_DIAGNOSTICS=1` alone cannot satisfy the existing strict reader.
Host-built compiler accounting is a different runtime and object ABI.
This runtime/emission increment implements the root-reviewed V2 design
(SHA256 `681b841ad21ba874fa170c413b64ad0fc5d5f32d8a8026620d9bf73054afa09c`),
retained under the coordinator's ignored opaque-composition evidence.
It changes no language API, ownership representation, phase algorithm or ledger.

## Actual routing census

These are all 26 explicit libc call occurrences in the accepted target sources:

| Owner | Allocation / resize / release lines |
| --- | --- |
| `src/runtime/string.brp` | allocate51, release99 |
| `src/runtime/string_concat.brp` | allocate10 |
| `src/runtime/list.brp` | shared root118, release154, argv root236 |
| `src/emit/emit.brp` | record release814/allocate824, boxed allocate1658/release1754 |
| `src/runtime/system.brp` | allocate29/92/124/180, resize57, release36/40/44/49/53/98/131/138/142/146/186 |

The shared List factory also serves literals/repeat/append/set/concat; it must
retain initialized-length publication. System scratch/error paths count too.
`emit:2587` selects the prelude; memory precedes every allocation user, once.
`emit:2680–2712` owns noargs Int/Void, argv Int/Void and invalid-argv exit.
Seven existing runtime fragment writers need the same memory prelude:
`test_string`, `test_string_concat`, `test_record` (shared aggregate harness),
`test_current_directory`, `test_file_read`, `test_write_file`, `test_print_error`.
`test_float` emits no allocation user. Existing independent malloc/free ledgers
remain in mode0; their raw-pointer ABI and occurrence assertions stay intact.

## Small implementation

Add one literal `MEMORY_RUNTIME: String` in `src/runtime/memory.brp`.
Its private C authority is allocate/resize/release and start/finish. For example,
`string.brp:51` changes `result=malloc(size)` to
`result=blorp_memory_allocate(size)`, and final release uses that same authority.
Mode0 uses object-like malloc/realloc/free aliases, a no-op start macro and
single-evaluation identity finish: no getenv, counter, prefix or function call.
Mode1 uses a max_align_t-aligned size-only prefix and checked aggregate counts;
requested bytes exclude the prefix. One C11 atomic_flag protects each complete
checked counter update, including backing resize success/failure, so concurrency
cannot interleave a check and commit. No registry, tracing or reset API exists.
Reject prefix/count/byte overflow and underflow as infrastructure failure.
Positive resize preserves one allocation lifetime; NULL failure preserves the
old pointer, payload, header and every counter. NULL release does nothing.
Start validates the environment once before effects or argv; only unset/empty
and strict are accepted. Finish reports the exact existing line only in strict
mode, preserves the requested status when balanced, and returns named99 on leaks.
Fatal abort/signal paths remain failures without fabricated balanced reports.

The noargs Int main keeps `return blorp_memory_finish((int)blorp_f_0());`.
Argv Int reuses existing `blorp_result`; argv cleanup precedes finish. Void
finishes0 after effects/cleanup; failed argv admission finishes1 after its
initialized-prefix cleanup. No alternate language main or atexit controller.

## Test first and acceptance

Prepare `test/runtime/test_memory.brp` using the existing direct-C exception,
production fragments and real backing-allocation occurrence observations.
First RED emits and compiles an ordinary noargs Int main whose unused String
literal allocates/releases one root, requiring exact1/1/0/0. Use the existing
parse/check/specialize/lower/own/verify/emit entrypoints and unmodified output;
current code must fail for missing reporting, not a nonexistent module import.
Then an independent17-byte direct-C allocation probe omits release (strict99,
exact1/0/1/17), restores release (green), and separately double-releases under
ASan (specific UAF or double-free failure) versus single-release green. Keep raw.
Named callbacks also cover successful/failed resize and content preservation,
alignment/SIZE_MAX, checked counter overflow, single evaluation, invalid mode
before effects, zero normal getenv calls, partial argv cleanup and the existing
reader's missing-report rejection. Tests must not infer destruction from totals.
Direct C observations may inspect the internal arithmetic helper but must not
rely on the prefix layout to identify allocations or manufacture object owners.
Owning emitter tests check all five exits and unchanged direct-return shape.

First command, only after a root compiled-lane grant and ROOT host FRESH check:

```sh
cd /Users/keithphilpott/.codex/worktrees/pilot-memory-accounting/blorp
/usr/bin/env -u BLORP_CC -u BLORP_LEAK_CHECK -u BLORP_MEMORY_STATS -u BLORP2_COMPILER -u BLORP_2_INSTRUCTION_CHECK /Users/keithphilpott/CLionProjects/blorp/bin/blorp test --suite --timeout 180 --std-dir /Users/keithphilpott/CLionProjects/blorp/standard_library/src blorp_2/test/runtime/test_memory.brp
```

Then run runtime/emitter/harness tests, inspect unmodified generated C, and run
full components/e2e with one freshly built pilot. Real compiler success and late
source rejection must retain strict zero; opaque's product-lifetime tests remain
separate. Never weaken the reader, ledger, sanitizer class or existing ceiling.

## Bounds, dependencies and handback

Hard limits: production260 gross/+250 net; maintained tests500 gross/+480 net,
including one direct-C runtime fixture of at most130 readable lines and no
added language fixtures. Forecast is about230 production/450 tests;
report actual physical additions/deletions, including mechanical expectation
updates, without compressed formatting or removed coverage. Normal operations
remain aliases. FEATURE costs target+5%, hard+10% per shared input and original
schema1 construction proxy, preserving every tighter existing cap. No baseline,
corpus, epoch, freeze or sample is selected by this plan; review those before use.
Expected emitted-C changes are the one prelude, allocator names and main hooks;
require exact frozen identities afterward, with no postcompile normalization.

Production waits for exact-V2 independent confirmation and root plus independent
code/test review of this plan; commit the reviewed plan before implementation.
Root coordinates all compiled jobs and final integration. Preserve source/tool
pins, complete commands/status/streams/C and raw observations under ignored
`build/pilot-memory-accounting/`. Stop on scope/cost breach, unexpected oracle or
host defect; report it without a fallback, new mechanism, retry or waiver.
