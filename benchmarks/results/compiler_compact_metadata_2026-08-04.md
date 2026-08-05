# Compact Compiler Metadata

Measured on 2026-08-04 from revision
`ce4107fcdaaee675800f6b9f5b5bb38c4248896a` on Apple arm64. Each slice was
built and measured independently before the next slice was applied.

The allocation comparisons use `BLORP_LEAK_CHECK=1`. Leak tracking perturbs
absolute memory use, so these counters are evidence about deterministic object
count differences rather than headline peak RSS. Worker responses were
byte-identical within every comparison.

## Typecheck Metadata

The captured typecheck request has SHA-256
`9fe690f244a61bcfc9f7c7223573d1c8560b4a3cc6566b46744f174416b028c9`.

| Representation | Allocations | Retained objects | Retained bytes |
|---|---:|---:|---:|
| Original value slot and proof record | 987,647 | 67,079 | 4,732,959 |
| Phase-valid `CompilerValueSlot` union | 983,609 | 65,157 | 4,634,591 |
| Allocation-free empty proofs | 982,647 | 64,196 | 4,603,839 |

The compact value slot removes 4,038 allocations, 1,922 retained objects, and
98,368 retained bytes. Replacing the always-allocated proof record with four
precise variants removes another 962 allocations, 961 retained objects, and
30,752 retained bytes. Together they remove 5,000 allocations and 129,120
retained bytes from this request.

Sub-percent RSS and short-run latency movements were observed but are not used
as evidence for these two slices. The deterministic allocation counts are the
acceptance criterion.

Worker SHA-256 values:

| Worker | SHA-256 |
|---|---|
| Original | `f970c3205df9d4ebdf29f8070848adb285bff093f6d70d7fb8fdedf3806534f0` |
| Compact value slot | `ab38ee4c40462de05cccb9cb6443ed126558dae2eae60975df152cb1f4cfeb03` |
| Allocation-free empty proofs | `b4a35f4a6f8a1cb78474c86152c1b158c5c1d05d9bdd8036c6c3fe756314ffc7` |

## Core Source Locations

`compiler_core_source_loc_request.brp` constructs 100 functions containing
10,200 known source locations. Its request SHA-256 is
`d283221c17cba6684348c481076bfc915f05bf386adf699d9dd89b4a9e07f72e`.

| Representation | Allocations | Retained objects | Retained bytes |
|---|---:|---:|---:|
| `KnownSourceLoc(CoreSourceSpan)` | 4,979,116 | 504,404 | 55,953,586 |
| `KnownSourceLoc(String, Int, Int, Int, Int)` | 4,958,816 | 484,204 | 55,307,186 |

Flattening the span into the location removes 20,300 allocations, 20,200
retained objects, and 646,400 retained bytes. Across six alternating samples,
median peak RSS fell from 95,207,424 to 94,593,024 bytes (0.65%) and median
elapsed time fell from 420.8 to 417.9 ms (0.69%). Generated C and the complete
329,863-byte worker response were byte-identical. The sub-percent timing result
is directional rather than a headline speed claim; the allocation reduction is
the primary evidence. Raw samples are in
`compiler_compact_metadata_core_source_loc_2026-08-04.tsv`.

Worker SHA-256 values:

| Worker | SHA-256 |
|---|---|
| Nested source span | `36cd2e18f533e3eb656c2ecf126a45a1612678f13293ad12c9687a8d6a859d5a` |
| Flattened source location | `bfc5dedb262fe3aec40294791224560128de85d1a2d842b01ccc1a699c477f39` |

## Rejected Candidate

Making `CompilerExplicitAnnotationOrigin` payload-free preserved behavior but
produced exactly the same allocation totals on the compiler typecheck replay.
Explicit expression ascriptions are too rare in compiler source to justify the
API change, so that experiment was reverted.

Directly matching proof variants in each proof predicate was also tested after
review raised a concern that the shared accessors might allocate transient
`Some` values. A deterministic request containing 512 range/subscript proof
functions (`692a74358a33fadfcac0d09f5cae7069004f7ad7f7c8f5b6d0b1096afa53c03e`)
produced byte-identical output and exactly 6,820,842 allocations with both
implementations. The duplicated direct-match code was therefore reverted.
