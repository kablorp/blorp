# Direct managed allocation: RSS and cost on frozen self-compile

Status: initial allocator-only candidate measured on
`codex/runtime-rss-accounting-f0e8`, based on
`4973f2104519046b3ffd16a4eb78f383e5a7acac`. A subsequent boxed tensor
fill ownership fix has focused validation but has not been remeasured. No
commit or integration.
Host: MacBook-Air-4.local, arm64, Apple clang 21.0.0
(`clang-2100.3.34.2`), CLI and runtime `-O2`, eight-way compiler C split.

## Mechanism and scope

The original allocator retained 16 KiB slabs per thread and size class.
The matched baseline's opt-in histogram reported 105,631 per-class
high-water slabs, whose sum times 16 KiB is 1,730,658,304 bytes. The
high-water values are not a simultaneous process snapshot or an idle-slab
count. Baseline backend checkpoint allocator bytes were 1,856,228,608, so
the pool was a plausible large retaining root. A separate diagnostic-only
owning-thread census was preserved at
`/tmp/blorp-runtime-rss-pool-census-diagnostic.patch` and removed from the
candidate when the user explicitly requested no slabs.

A bounded individually malloc-owned per-thread free-list candidate passed
four of five initial native tests but failed the release-only worker test:
the worker's 64-byte block appeared in its cache at depth one, the
thread-exit callback ran once, yet the interposed `free` never received
that exact block. Observed stderr included `cached=block depth=1` and
`tracked frees=0 drains=1`. The thread-local state being unavailable to
the callback is a plausible explanation, not a proven root cause.
Preserving a cache safely would require more lifecycle machinery. The
user explicitly authorized direct malloc/free when caching complicated
the design, so this candidate removes the slab and cache machinery.

`blorp_alloc` now mallocs each managed object directly, reserving at
least `sizeof(blorp_Object)` for a zero/small request. It preserves the
existing header layout and marks `alloc_class` DIRECT. Final ARC release
runs the destructor and frees the original malloc base. The runtime's
existing `backing_libc_malloc_events` counts these calls when allocator
stats are enabled; slab/cache-only public counters and diagnostics were
removed from the matching C and Blorp `MemStats` layouts. No allocator
capacity or tuning control remains.

## Reproduction and provenance

All compiler builds, tests, and self-compiles were serialized with
`python3 /tmp/blorp-memory-pilot-run-20260927.py env
BLORP_CLI_C_OPTIMIZATION=-O2 COMMAND ...`; the wrapper holds a real
`fcntl` lock. Build and verify the checkout with `make` and
`scripts/compiler-build-status` under that wrapper. Build the stage-2
compiler with `benchmarks/build_stage2_compiler OUTPUT`. Both stage-2
builds report `compiled_by: self-4973f2104519` and CLI/runtime `-O2`.

Baseline stage-2 executable:
`/tmp/blorp-runtime-rss-base-4973f-stage2`,
SHA-256 `247e614bea528f2660e0623ece97009efc48f2e1bc018509c9058e34ea332f7b`.
Candidate:
`/tmp/blorp-runtime-rss-direct-4973f-stage2`,
SHA-256 `7e0df931162e3bac66bfd2a2016d06a921b86e8ca07697a448020fb4850558fe`.
Their compiler-generated C files are `/tmp/blorp-runtime-rss-{base,direct}-4973f-stage2.c`,
SHA-256 respectively `368622846837417e9fb665f1dd230a887df13f13797c2fb8b3aefc558a8e5c17`
and `831cf8e87d8f10b06f56990facf7e9989357be393ece9975122075924d879c6d`.
The candidate source hashes are runtime.c
`d1f39719befa7de9374cbd3e66ee18d4afb1da28249967ae6bd2d73bd71f0cb4`,
runtime_decl.c `cef4d81ca2c3a670d67e61815e43a55005d6273de6bb883bf6f217aed08a2c73`,
and standard_library/src/memory.brp
`9fa28ae5b48ce17b0611d7a63a8452c76848d141d3027d37a2951b4a023fc7d8`.
The checkout is dirty by design; no candidate commit exists.

Frozen input revision:
`4973f2104519046b3ffd16a4eb78f383e5a7acac`. Preserve this exact
path spelling in every lane:
`/var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/blorp-perf-input/4973f2104519046b3ffd16a4eb78f383e5a7acac`.
Do not normalize `/var` to `/private/var`.

For each row below, run `benchmarks/self_compile_measure` under the
wrapper with `--compiler /tmp/blorp-runtime-rss-{base,direct}-4973f-stage2
--skip-build-check --input-rev 4973f2104519046b3ffd16a4eb78f383e5a7acac
--samples 1 --baseline /tmp/blorp-runtime-rss-base-4973f.json
--require-identical --output /tmp/blorp-runtime-rss-{base,direct}-pairN.json`.
The logs use the same stems with `.log`. Run order was B1, C1, B2, C2,
B3, C3, one instrumented checkpoint run plus one uninstrumented sample per
harness invocation. These runs did not overlap compiled activity. Because
`--compiler` names an external stage-2 executable, the harness metadata
labels `compiler_stage: 1`; the executable's version and stage-2 build
recipe establish its actual provenance.

| Pair | Retired instructions B / C | Peak RSS bytes B / C | Backend allocator bytes B / C | Wall seconds B / C |
| --- | ---: | ---: | ---: | ---: |
| 1 | 143,604,884,295 / 204,170,092,768 | 2,017,230,848 / 1,816,117,248 | 1,856,228,608 / 1,044,277,488 | 11.11 / 13.29 |
| 2 | 143,534,534,447 / 204,226,084,617 | 2,019,016,704 / 1,817,493,504 | 1,856,228,608 / 1,044,277,488 | 11.27 / 12.96 |
| 3 | 143,364,167,108 / 204,114,887,519 | 2,018,197,504 / 1,815,887,872 | 1,856,228,608 / 1,044,277,488 | 11.06 / 13.44 |

All six runs generated byte-identical C, SHA-256
`6556b41b14b0c0e63aec23bd097c514c61abb30a7de62a831cd929e514e77164`,
78,751,725 bytes. Both lanes recorded exactly 188,042,651 managed
allocations. Median paired peak RSS changed about -9.98% (roughly 201 MB);
backend checkpoint allocator bytes fell 811,951,120 bytes. Retired
instructions rose about 42.28%. Observed wall time was higher in each
candidate sample; it is secondary and noisier than the instruction count.
The allocator-byte decrease is not a claim that all those pages returned
to the OS. The candidate's peak RSS remained around 1.82 GB, and the
current backend RSS in each run was about 1.816-1.818 GB.

These numbers describe the allocator-only binary above. A broader runtime
gate later found a pre-existing boxed tensor fill use-after-free that the
old slab retention masked in ordinary execution. The direct allocator made
the corresponding Int128 value test fail; AddressSanitizer also found the
same use-after-free with the original allocator. Final Core kept an explicit
`BoxExpr(Int128Box)` on a `DirectRuntimeCall`, but that emitter route skipped
the existing boxed-fill handler. Generated C boxed one value, copied its
pointer into both vector slots, released it, then unboxed the dangling
pointer. The bounded emitter fix sends direct runtime vector and matrix
fills through the existing boxed-fill handler, which creates and owns a fresh
box for each slot. The same route stores Float16 values as encoded bits,
without an element destructor. An initial handler classification installed
one for Float16 and crashed on the bit pattern `0x3e00`; focused runtime
and sanitizer tests caught and resolved it. The combined source was
measured separately below; these allocator-only figures remain historical.

## Validation and decision

The direct ownership regression failed against the interim cache before
this fix (C test returned 2 because two final releases did not both pass
their exact pointers to `free`), then passed after the direct change.
Focused native direct/oracle/coverage tests: 7/7. The newly named Blorp
`test_allocator_direct_release.brp` fixture: 1/1 under a FRESH `-O2`
stage-1 compiler. Before the emitter fix, the expanded Option fixture failed
2/46 normal tests (Int128 and UInt128 vector fill). A newly added Float16
fill test then crashed before the release-classification correction. After
both corrections, all 47/47 pass normally and with AddressSanitizer. The direct-runtime Core emitter
test covers boxed Int128 vector and matrix fill; its suite passes 345/345.
An independent changed-source run passed four focused suites and the
generated-C audit, 376/376, before the Float16 classification correction;
the audit now asserts encoded-bit storage without element release. The
Float16 audit fixture exits zero normally and under AddressSanitizer after
the correction. Broader gates against the corrected source are recorded below.

This is a deliberate simplicity/memory-versus-CPU tradeoff. The user asked
to remove slabs and permitted complete cache removal if a bounded cache
made lifecycle safety complex. Do not tune a new capacity or reintroduce
pooling as part of this change. Landing requires an explicit decision on
the measured instruction cost.

## Final diagnostic-mode build and comparison

The final normal and diagnostic stage-2 compilers were built with
`BLORP_CLI_C_OPTIMIZATION=-O2` from one generated compiler body. The stage-2
builder compiled that body as one object, then linked separate mode-0 and
mode-1 runtime objects; the version stamp's `split: 8` describes the stage-1
Make configuration rather than eight stage-2 body objects. Generated stage-2
C was 73,456,759 bytes, SHA-256
`d4aa8131a4cd69cd69036d82457ad2454a888c170a11b2b18dc51d3fb0534508`.
The shared body object SHA-256 was
`cfcc8981de49cbd3e8e5e8b90203bcf930ab385d39f645105afa6be7be3fae9e`.
The normal and diagnostic binaries were
`/tmp/blorp-direct-diagmode-final-stage2-4973f` (SHA-256
`ee91c4a04ddcc41d925a30ffaddb44435bd44aee59d8e94acb6f110db2b84272`)
and `/tmp/blorp-direct-diagmode-final-stage2-diagnostic-4973f` (SHA-256
`e0b81f6443f5af5c2d640282c026fefdb8889fe59a0c86d659a30d9b16034478`).
The linked runtime-object SHA-256 values were
`dfc918daad7197e32f9aa163e668ad485832a9c2e228064e03228a9e86a8e4f8`
(mode 0) and
`387aa1cbc481e065021b02c315ae9a0e31bbb572323483e2075f9c009648fd99`
(mode 1). The preserved corrected pre-accounting direct binary was
`/tmp/blorp-direct-boxfix-stage2-4973f`, SHA-256
`6ee2e2f1517b9d30c220a28eefd7540b9c300c9d2a82c9f46795065a125f1542`.

Three alternating B/C pairs compiled the same frozen checkout at
`/var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/blorp-perf-input/4973f2104519046b3ffd16a4eb78f383e5a7acac`.
The invocation was `/usr/bin/time -l COMPILER compile --no-format
--no-embed-runtime --time-phases --std-dir INPUT/standard_library/src -o
OUTPUT INPUT/blorp/src/main.brp`, under the shared pilot lock. `B` is the
corrected direct binary with diagnostic-capable runtime but profiling off;
`C` is the final mode-0 direct binary. Raw stderr samples are
`/tmp/blorp-diagmode-final-{B,C}{1,2,3}.log`; parsed records and binary/C
hashes are `/tmp/blorp-diagmode-final-pairs.json`.

| Pair | Retired instructions B / C | Peak RSS bytes B / C | Wall seconds B / C |
| --- | ---: | ---: | ---: |
| 1 | 204,044,092,828 / 184,435,004,255 | 1,814,986,752 / 1,826,521,088 | 13.13 / 12.11 |
| 2 | 203,933,400,665 / 184,570,566,025 | 1,814,970,368 / 1,828,454,400 | 13.12 / 12.23 |
| 3 | 204,047,092,859 / 184,366,309,100 | 1,815,314,432 / 1,828,651,008 | 13.22 / 12.20 |

All six produced byte-identical C, 78,751,725 bytes, SHA-256
`6556b41b14b0c0e63aec23bd097c514c61abb30a7de62a831cd929e514e77164`.
Median retired instructions fell 9.61% after removing diagnostic hot-path
accounting; median peak RSS rose 0.74% against the corrected direct binary.
Median wall time fell from 13.13 to 12.20 seconds, a secondary noisy signal.
The matched mode-1 binary reported 188,042,651 managed allocations, exactly
the corrected pre-accounting sample's count, with identical per-checkpoint
counts; its record is
`/tmp/blorp-direct-diagmode-final-stage2-4973f-sample.json`.

Against the original pooled baseline's median, final mode-0 direct malloc
still has 28.50% more retired instructions and 9.40% less peak RSS. The
managed-object slabs and free lists are removed; separate fiber object/stack
pools remain. Neither this RSS comparison nor the allocator-byte reduction
proves that libc returns freed pages to the OS.

## Final validation

The corrected compiler passed `compiler-blorp` 5,175/5,175, runtime
4,503/4,503, leak 977/977, Core ASan/UBSan 2,180/2,180, CLI 118/118,
LSP 37/37, package 46/46, changed-file suites 553/553, compiler tools
175/175, and generated-C audit 221/221. Native direct allocator/oracle/
mode tests passed 8/8. A real typecheck replay reported active nonzero
managed counters; a real backend probe reported 524 allocations and 522
releases, while a mode-0 stats-bearing fixture failed closed. The hygiene
prefix through its record-update allocation probes passed after updating
legacy benchmark consumers to compile diagnostic runtimes. Its retained
output is `/tmp/blorp-memory-final-hygiene.log`; the target then stopped at
an old body-cache assertion. The revised build-configuration contract passed
separately, followed by build-source generation, release-toolchain,
`scripts/test` harness, split-translation (5/5), and generated-artifact scan.
The full hygiene target was not rerun from the beginning after that final
test-only assertion edit. The last aggregate `compiler-check --changed` run
stopped at the old LSP probe; its passing suites/tools/audit are retained in
`logs/compiler-check-20260927-183456-71377`, and the corrected LSP gate's
37/37 result is `/tmp/blorp-memory-final-lsp/lsp.log`.
