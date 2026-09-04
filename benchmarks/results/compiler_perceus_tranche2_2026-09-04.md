# Perceus Tranche 2 — Borrowed-Call Protection

This report compares the Tranche 2 candidate with its immediate parent,
`5e8df737`, using separately compiled production and debug/profile backend
workers. Samples alternated baseline/candidate order. The benchmark measures
direct Perceus over decoded ownership-ready Core; process startup and JSON
transport are outside the reported inner window.

## Change

The function-parameter borrowed-call pass now builds one stable owner catalog
and reconstructs each supported Core region once. Exact variable lookups narrow
through name-indexed owner candidates. At a consuming boundary, the earliest
matching owner is sufficient: the previous owner-major pass used that owner to
retain the evaluated result, after which later owners no longer observed a
borrowed result.

The optimized path preserves exact owner order, binder shadowing, synthetic
temporary spelling, call contracts, evaluate-once behavior, and list-set
aggregate transfer. Name-only owners use their indexed direct rules and retain
the exact scalar name-summary predicate only for complex result queries.
Incoming ownership nodes likewise remain explicit, counted compatibility
islands rather than silently changing established alias semantics. Globals and
nested-lambda value ordering remain in their existing passes for Tranche 4.

## Fixture

The dedicated `borrowed_call_protection` shape declares a heap-record type,
then gives each of two functions a fixed 128-node body and 1, 8, or 32 ordinary
name-only heap-record owners. Only owner zero contributes its managed `String`
field projection to a consuming call. Extra owners therefore increase catalog
size without increasing syntax or real alias work. The matrix runs without
invoking the functions; the end-to-end check invokes them with valid heap-record
constructors.

```text
globals=1
functions=2
body_leaves=128
body_shape=borrowed_call_protection
parameter_type=HeapRecord(BenchBorrowOwner { BENCH_PAYLOAD: String })
params_per_function=1,8,32
samples=7
warmup=true
measurement_window=perceus-direct
```

## Paired results

| Owners per function | Baseline visits | Candidate visits | Visit reduction | Inner-time ratio | Allocation ratio | Release ratio |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 256 | 256 | 0.0% | 1.012 | 1.002 | 1.002 |
| 8 | 2,090 | 256 | 87.8% | 0.891 | 0.870 | 0.866 |
| 32 | 8,378 | 256 | 96.9% | 0.668 | 0.607 | 0.599 |

At 32 owners, the direct Perceus window improved by 33.2%, allocations fell
39.3%, and releases fell 40.1%. The one-owner point is effectively neutral and
shows the catalog/pass setup does not impose a material fixed penalty.

The candidate counters were constant at all three owner counts:

```text
borrowed_call_node_visits=256
borrowed_call_alias_fallback_requests=0
borrowed_call_owner_candidate_visits=2
borrowed_call_rewrite_actions=2
borrowed_origin_member_visits=2
borrowed_origin_storage_slots=0
```

Owner-catalog slots alone scaled with the inputs: 2, 16, and 64. The benchmark
now rejects owner-scaled reconstruction visits, fallback requests, rewrite actions,
origin-member visits, or retained origin storage.

## Correctness

For every matrix point, baseline and candidate post-Perceus Core hashes were
identical. A separate seven-pair 32-owner backend-emission check produced the
same 66,000-byte generated C artifact from both workers. The focused Perceus
suite passed 313/313 tests, including a new
two-owner conditional fixture that asserts one evaluate-once retain using the
first owner's stable synthetic name. Benchmark contract tests passed 30/30.

The compatibility paths are intentionally visible in counters. A later tranche
may replace complex result queries with richer local-definition facts, but that
is not required to obtain or validate the independent reconstruction win here.

## Reproduction details

The focused matrix used harness SHA-256
`cb1ba1d7dc4aea0e3a48b4bac5a143222e53256f39d3928a95aa0e81fcc5b108`,
candidate worker SHA-256
`11cebfd79b511f1014401a50bdc8fffb9cec8f7e2a39e67da22a53d48e9235c1`,
candidate counter-worker SHA-256
`79712ba0f99f05e59b54f4ae1df3a0b2cb66c2fe3ce6c2b763756f0a92924808`,
baseline worker SHA-256
`256badd2cbbce0185e9bde2b589e4833eaaba3f5ee7466fa025c3c4da00dafd1`,
and baseline counter-worker SHA-256
`9d2603e8c7847a8ae2d369fb91bd0c714c2911e0096a17427e7ee7e048684c15`.

The seven baseline/candidate inner-window samples in microseconds were:

| Owners | Baseline samples | Candidate samples | Paired-ratio median ± MAD |
| ---: | --- | --- | ---: |
| 1 | 933, 934, 933, 924, 949, 950, 929 | 964, 944, 935, 944, 967, 943, 940 | 1.012 ± 0.010 |
| 8 | 1086, 1080, 1077, 1084, 1069, 1078, 1149 | 965, 975, 985, 954, 961, 961, 959 | 0.891 ± 0.011 |
| 32 | 1533, 1536, 1550, 1530, 1521, 1534, 1576 | 1036, 1021, 1037, 1021, 1023, 1024, 1007 | 0.668 ± 0.003 |

Three additional alternating direct-worker invocations of the 32-owner request
under `/usr/bin/time -lp` retired 202,591,041; 188,733,920; and 188,667,322
instructions for the parent, versus 188,767,519; 177,622,623; and 177,504,038
for the candidate. The medians were 188,733,920 and 177,622,623; the median
paired candidate/parent ratio was 0.941, or 5.9% fewer instructions. Every
response had the same post-Perceus hash. Maximum RSS was 10,420,224 bytes for
the parent and 10,567,680 bytes for the candidate. The request SHA-256 was
`401fdd92eaceab1aa93864f3f7ddb8ed1032fa056308b67cb3b10f448f960946`;
the exact candidate and parent workers were
`1d08b9f1df129e8966820147578308d88f467a1f8bc5c8a78e152b4bab4d18ae`
and
`256badd2cbbce0185e9bde2b589e4833eaaba3f5ee7466fa025c3c4da00dafd1`.

The corresponding post-Perceus artifact byte counts and SHA-256 hashes were:

| Owners | Bytes | SHA-256 |
| ---: | ---: | --- |
| 1 | 25,502 | `d06d1d48fd84782e7e723103191230f31f8677d6f6fa3f79fa75a0312ce0594e` |
| 8 | 27,700 | `ef540b829c8953a8941194be39144dca39eae243f14a8a5aaae5d398a584678e` |
| 32 | 35,236 | `56817b218b550d6960d8316513741a18638a3e4e34186aada9995d5f7fafa5ae` |

At 32 owners, the seven-pair full-backend window was neutral: paired median
ratio 1.005 ± 0.008 MAD, identical allocation counts (65,342), and identical
66,000-byte C with SHA-256
`ea7d8f9be9428d0ad3da085817a182a7b96251a4d36c450cc2534bbbedaf4e32`.

## Production self-compilation

Both isolated compiler binaries compiled the same candidate source checkout.
This detail matters: compiling each binary's own checkout changes definition
IDs because the candidate contains the Tranche 2 implementation, making raw
artifact comparison invalid even when compiler behavior is identical. Each
phase was warmed, then measured as three alternating parent/candidate pairs
with `/usr/bin/time -lp` and no concurrent benchmark or test process.

| Phase | Parent wall (s) | Candidate wall (s) | Parent instructions | Candidate instructions |
| --- | --- | --- | ---: | ---: |
| Stop after Perceus | 67.97, 66.15, 66.97 | 67.67, 68.14, 68.82 | 1,159,045,439,113; 1,160,090,598,094; 1,159,373,262,362 | 1,157,752,439,975; 1,157,793,285,188; 1,157,708,857,187 |
| Full C emission | 62.48, 60.80, 60.95 | 60.94, 65.01, 60.68 | 1,041,250,794,215; 1,041,581,910,743; 1,042,221,505,420 | 1,040,133,677,425; 1,040,528,894,433; 1,040,289,545,315 |

The stop-after-Perceus medians were 66.97s parent and 68.14s candidate
(+1.75% wall time) while candidate retired 0.14% fewer instructions. Full
emission medians were 60.95s parent and 60.94s candidate (neutral wall time)
while candidate retired 0.12% fewer instructions. RSS medians were 6.161GB vs
6.147GB through Perceus and 2.112GB vs 2.106GB through full emission; RSS is
reported as a noisy diagnostic, not a gate.

Raw maximum-RSS samples were:

| Phase | Parent RSS (bytes) | Candidate RSS (bytes) | Maximum parent | Maximum candidate |
| --- | --- | --- | ---: | ---: |
| Stop after Perceus | 6,161,154,048; 6,161,104,896; 6,161,055,744 | 6,146,392,064; 6,161,154,048; 6,147,211,264 | 6,161,154,048 | 6,161,154,048 |
| Full C emission | 2,111,979,520; 2,111,897,600; 2,111,995,904 | 2,098,495,488; 2,105,720,832; 2,112,782,336 | 2,111,995,904 | 2,112,782,336 |

All three same-input pairs were byte-identical. The post-Perceus artifact was
316,884,982 bytes with SHA-256
`f43dab82d23b3102f77a77230adaa297e3308f8f76ce98aac684c413ab1e3d4a`.
The generated compiler C was 100,791,419 bytes with SHA-256
`4da8c46a097449d5fed098b97b1aab36b4a1a54cf038b25528506d88f6f36aae`.
The candidate and parent production compiler SHA-256 hashes were
`c315066933950951bbc9c1e936f48360daf31063810d7d43fa9a8d10b8cc0e89`
and
`ec9a7085ea15c64cd1d22e8948cdf26aba465ec0491bd1c280e0396cd6431c07`.
