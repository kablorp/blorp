# Compiler Boolean Field Layout Roadmap

Status: active; Slices 0-3 and 5 implemented locally and Slice 4 evaluated as
of 2026-07-25; Linux baseline pending.

Last checked against the `compile-speed` branch on 2026-07-25.

This document is the durable plan and measurement log for compact Boolean
storage in generated C. Update the status table, evidence, and decision log
after every accepted or rejected slice so later work does not need to recover
the reasoning from task history.

## Goal

Reduce compiler memory traffic and aggregate-return overhead by storing Boolean
record and struct fields compactly while preserving language semantics and C
foreign-function ABI contracts.

This is a layout project, not a global change to the computational
representation of `Bool`. Boolean expressions, normal function parameters and
returns, runtime helpers, and foreign scalar arguments currently use C `int`.
Those boundaries must remain unchanged unless a separate ABI migration is
designed and released.

## Current Findings

- Scalar `Bool` values and foreign-ABI-visible fields lower through
  `c_type_name` to C `int`.
- Consecutive internal value-struct Boolean fields now use one-bit C `_Bool`
  bitfields; isolated Boolean fields remain ordinary `_Bool`. The three-flag
  probe occupies 1 byte instead of its 12-byte baseline.
- All-nullary enum metadata already drives packed list and tensor storage, but
  it does not currently affect record or struct fields.
- The compiler source currently contains four `struct` declarations. Two have
  Boolean fields, with three Boolean fields in total.
- The compiler source currently contains approximately 81 `record` types with
  125 Boolean fields. Heap-record layout is therefore the broader memory
  opportunity.
- Internal heap-record Boolean fields now use ordinary `_Bool`; a measured
  three-flag object moves from a 64-byte pool allocation to 32 bytes.
  Foreign-reachable heap records preserve C `int` fields for pure and
  `@no_copy` pointer borrows.
- Adding an observed-but-unconsumed third Boolean to the recursive type-shape
  summary is latency neutral (`+0.065%`) and peak-RSS neutral (`-0.171%`).
  Compact aggregate representation was not the source of the prior regression.
- Fusing the standalone function-carrier candidate traversal into that compact
  summary remains slower. Two separately built variants regressed median
  latency by `6.792%` and `7.168%`; both were rejected and removed.

Relevant implementation:

- `compiler/blorp/src/stage_10_backend/compiler_core_emit_type_layout.brp`
- `compiler/blorp/src/stage_10_backend/compiler_core_emit.brp`
- `compiler/blorp/src/stage_08_core_lower/compiler_core_ffi_boundary.brp`

## Non-Negotiable Constraints

1. One representation change per slice.
2. Generated C must remain valid under supported Clang and GCC targets.
3. Foreign-ABI-visible value structs and foreign-borrowed heap records retain
   their existing field order and C field types.
4. The ARC header remains the first physical field of every heap record.
5. Source field order, constructor argument evaluation order, and named field
   semantics do not change.
6. Layout claims require generated-C evidence and actual `sizeof` results.
7. Performance claims require alternating A/B measurements with identical
   workload checksums.
8. A theoretically smaller layout is rejected if measured compilation latency
   or memory use regresses materially.

## Status

| Slice | Change | Status | Acceptance evidence |
|---|---|---|---|
| 0 | Persistent roadmap and generated-C layout probe | Implemented locally | macOS probe and contract pass; Linux size baseline pending |
| 1 | Explicit internal versus foreign-ABI value-struct classification | Implemented locally | Direct, alias, and transitive tests pass; generated-C hash unchanged |
| 2 | Store internal value-struct Boolean fields as `_Bool` | Implemented locally | Three flags shrink from 12 to 3 bytes; live foreign layout and scalar ABI remain unchanged |
| 3 | Pack consecutive internal value-struct Boolean fields | Implemented locally | Three flags occupy one byte on Darwin arm64; bounded replay is latency neutral; Linux validation pending |
| 4 | Re-evaluate the type-shape summary using compact storage | Evaluated; no source change retained | Third-field-only result is neutral; both fused variants regress latency and were removed |
| 5 | Store heap-record Boolean fields as `_Bool` | Implemented | Internal three-flag object falls from 40 requested/64 allocated bytes to 32/32; foreign pointer ABI and ARC tests pass; bounded emitter latency is -1.35% |
| 6 | Pack consecutive heap-record Boolean fields | Not started | Object sizes improve without meaningful latency regression |
| 7 | Reorder internal fields by descending alignment | Not started | Stable layout algorithm, designated initialization, measured size reduction |
| 8 | Consider compact storage for other nullary enums | Not started | Separate design covering tag widths, invalid values, and FFI |

## Slice 0: Layout Probe

The fast feedback loop is:

```bash
benchmarks/compiler_record_layout
```

It compiles
`tests/test_compiler/codegen_audit/should_pass/compiler_record_layout.brp`
through the production compiler backend, adds a temporary read-only C layout
reporter, and builds that generated C at both `-O0` and `-O2`. The same exact
fixture is part of the production generated-C audit gate.

The fixture covers:

- three consecutive Boolean fields in a value struct;
- interleaved Boolean and machine-word fields;
- Boolean fields in a heap record;
- a mixed-field value struct reachable from a foreign signature.

The probe reports C type identity, `sizeof`, and `_Alignof`. It does not mutate
the generated C representation used by production builds.

### Baseline

Record the first verified baseline here:

| Layout | O0 size/alignment | O2 size/alignment | Notes |
|---|---:|---:|---|
| Three consecutive value-struct flags | 12 bytes / 4 | 12 bytes / 4 | Three C `int` fields |
| Interleaved flags and words | 32 bytes / 8 | 32 bytes / 8 | `Bool`, `Int`, `Bool`, `Int` |
| Heap-record flags | 32 bytes / 8 | 32 bytes / 8 | Includes ARC header and one pointer |
| Foreign-ABI mixed value struct | 32 bytes / 8 | 32 bytes / 8 | Field offsets `0, 8, 16, 24`; widths `4, 8, 4, 8` |

Baseline environment:

- Darwin 25.5.0 arm64
- repository revision `16f78a0ac8d1dcd88e7ce85916f8301b5ca390f0`
- repository state `dirty` (the roadmap/probe changes and pre-existing branch
  work were present)
- fixture SHA-256
  `96d1c25e861c3844a3fd97e79611c5da3b55795bd7ee7d704b6e25d0b95aaa23`
- OCaml host SHA-256
  `b856bc62eb069fad375d09f070e8fe06019a992de1c60eab4cac496283a2de64`
- bridge compiler SHA-256
  `09527f58e01a98e154312ba7dff085a26e0c8542fb5f88689ac9b719dfe21b49`
- C compiler command SHA-256
  `355b1bbfc96725cdce8f4a2708fda310a80e6d13315aec4e5eed2a75fe8032ce`
- C compiler version SHA-256
  `ebdd1913203aebbae99a8adad363e300e6cea37bcc703a8f9506410551f809f1`
- C target `arm64-apple-darwin25.5.0`
- generated C SHA-256
  `7b9961d774bcd1b0b53db239efb57c74bf4997b5ff1b70d8fa744297e24d8d1f`

Validation on this worktree:

- the benchmark contract test passes;
- the production audit reports `PASS: compiler_record_layout.brp`;
- the complete production audit is not currently green: 146 cases pass and
  53 cases outside this Slice 0 fixture fail. Slice 0 changes no compiler
  behavior, so those failures remain a separate branch-wide gate.

## Slice 1: Explicit ABI Classification

Build a backend-only registry with an explicit policy:

```blorp
union CompilerCRecordLayout:
	InternalLayout
	ForeignAbiLayout
```

Seed `ForeignAbiLayout` from every `ForeignFunction` parameter and return type,
then follow nested value-struct fields transitively. Type aliases must already
be resolved at this boundary. Classification must not rely on name prefixes,
privacy, or source-path heuristics.

This slice changes no generated C. Its purpose is to make later layout choices
correct by construction.

Implementation evidence:

- `compiler_core_emit_record_layout.brp` owns the explicit
  `InternalLayout`/`ForeignAbiLayout` policy and registry.
- Classification starts from every retained foreign function parameter and
  return type, resolves generic alias chains, and follows value records through
  nested value-record, heap-record, and union fields. Recursive aggregate
  graphs terminate through explicit visited sets.
- Prepared Core may retain a `ForeignCall` after removing its original foreign
  declaration. Classification also scans retained function, impl-method, and
  global-initializer expressions so these live call boundaries remain
  ABI-visible.
- Core DCE treats type aliases as type-dependency nodes, so records reachable
  only through a retained foreign signature alias survive preparation.
- Type aliases and aggregate declarations are indexed once before traversal;
  the foreign-ABI closure does not scan the whole declaration graph per type.
- Existing list-layout and FFI passes each build and reuse one shared type index
  rather than allocating a declaration-wide index for every type query.
- The emitter selects a policy for every value-record declaration. Both
  policies deliberately emit the existing field C type in this slice.
- The focused prepared-Core layout suite passes 7 tests, including direct
  foreign return, generic aliased parameter, transitive value/heap/union
  records, recursive aggregate graphs, valid borrow-mode FFI metadata, and an
  internal control case.
- The DCE, layout-classification, list-layout, and FFI-boundary suites pass 32
  tests, including the alias-target retention regression.
- The broader Core emitter and pipeline suites pass 257 tests.
- The production layout probe retains generated-C SHA-256
  `7b9961d774bcd1b0b53db239efb57c74bf4997b5ff1b70d8fa744297e24d8d1f`
  and all Slice 0 size, alignment, offset, and field-width measurements.

## Slice 2: Narrow Internal Value-Struct Booleans

For `InternalLayout` value structs only, emit ordinary `_Bool` fields while
keeping constructor parameters and computational values as `int`:

```c
typedef struct {
    _Bool first;
    _Bool second;
    _Bool third;
} ThreeFlags;
```

This isolates narrow scalar storage from bitfield masking. The three-field
aggregate is expected to return to the smaller calling-convention class even
before bit packing.

Implementation evidence:

- `c_type_name(Bool)` remains `int`, and value-record constructor parameters
  remain `int`; only field storage selected through `InternalLayout` becomes
  `_Bool`.
- The generated-C contract covers field reads, immutable update, and
  whole-value copying for the compact internal struct. It also executes and
  audits inline list storage, inline tensor storage, stack `Option`, and
  `Result` boxing/unboxing.
- A direct classifier regression models prepared Core containing a retained
  `ForeignCall` with no foreign declaration. The production fixture proves
  this shape survives the real preparation and emission path.
- The focused type-layout suite passes 10 tests, including retained foreign
  calls in ordinary functions, impl methods, and global initializers.
- The DCE, indexed list-layout, FFI-boundary, and type-layout batch passes 35
  tests. The broader Core emitter and pipeline batch passes 257 tests.
- The foreign fixture calls a separately compiled C helper by value. The
  helper independently declares the legacy `{int, long, int, long}` struct, so
  the O0/O2 probe crosses a real translation-unit ABI boundary.
- The benchmark harness contract includes hashes for both support files and
  passes.
- The current full generated C passes the Clang syntax sweep with
  `-Werror=unsequenced` and `-Werror=incompatible-pointer-types`.
- The full fixture passes Clang ASan and UBSan with the external ABI helper.
- The layout classifier pops visited Core expressions from its worklist, so it
  retains only the unvisited frontier rather than every expression in a
  function body.

Measured Darwin arm64 candidate:

| Layout | O0 size/alignment | O2 size/alignment | Change from baseline |
|---|---:|---:|---|
| Three consecutive value-struct flags | 3 bytes / 1 | 3 bytes / 1 | 9 bytes smaller (75%) |
| Interleaved flags and words | 32 bytes / 8 | 32 bytes / 8 | Unchanged because source-order padding remains |
| Heap-record flags | 32 bytes / 8 | 32 bytes / 8 | Unchanged; heap records are outside Slice 2 |
| Foreign-ABI mixed value struct | 32 bytes / 8 | 32 bytes / 8 | Unchanged; offsets `0, 8, 16, 24`, widths `4, 8, 4, 8` |

Candidate provenance:

- fixture SHA-256
  `73508ad8e20c6497826d7e9dca2269e39513b7942adff78d30a59e9d205e8049`
- support header SHA-256
  `cc8014392f760cfee903d42276e4c0d8ac24a8e8d39fa5403807d830e0f2f9b8`
- support source SHA-256
  `1be26a233ff1c8f66008e412a456fab1c1c243fb835ab7ecc5c70a05490b5a53`
- generated C SHA-256
  `86f6172341f70bda5479aeeb10a82d904f20729092639914a7d5d08bf270d187`
- host, bridge compiler, C command, C version, target, repository revision,
  and repository state match the Slice 0 baseline above.

The allocation-light worklist change was measured with six alternating pairs
of the same captured 2,500,654-byte `emit_core_c` request:

| Metric | Append-only worklist | Bounded worklist | Difference |
|---|---:|---:|---:|
| Median elapsed | 0.549 s | 0.542 s | -1.4% |
| Median peak RSS | 60,899,328 bytes | 60,932,096 bytes | +32,768 bytes (+0.05%) |

The request SHA-256 was
`06cae9fdf61a7c7cbda2de472cf0951f495da290e4a6d9cf1531d2b72c20da`.
Every replay produced response SHA-256
`2a4bccf2d1cc38c0ca984a9b82c79ac6e2623747e103dc39a628a0512e00eda4`.
Baseline and candidate bridge SHA-256 values were respectively
`99a26e3cfefed88de221d0cf7f7677f64aa694272e4148816205f169e09d7c99`
and
`3d85b57d46ba2cc85018593c8db9df831bb8b00e47780fd687cede9a5abe803c`.
Treat this as evidence of no bounded-path regression, not a general compiler
latency or peak-RSS claim.

## Slice 3: Pack Consecutive Value-Struct Flags

After Slice 2 is accepted, change consecutive internal fields to standard C
Boolean bitfields:

```c
typedef struct {
    _Bool first : 1;
    _Bool second : 1;
    _Bool third : 1;
} ThreeFlags;
```

Keep fields in source order during this slice. Reads, assignments, whole-value
copies, boxing, unboxing, and inline list/tensor storage must be tested. C
bitfields cannot be addressed directly, so generated code must be audited for
field-address operations before this representation is enabled.

Implementation evidence:

- Value-record storage is represented explicitly as either
  `OrdinaryCValueRecordField(String)` or
  `PackedBooleanCValueRecordField`; the emitter cannot independently select an
  ordinary type and a conflicting bitfield mode.
- Only `InternalLayout` fields whose Core type is `Bool` and which have a
  Boolean neighbor select the packed representation. Isolated internal
  Booleans remain ordinary `_Bool`; foreign-ABI Boolean fields remain ordinary
  C `int`; non-Boolean fields retain `c_type_name`; constructor parameters
  remain `int`; and heap records are unchanged.
- Consecutive declarations pack naturally in C. Non-Boolean declarations
  retain source-order boundaries, so the interleaved probe remains 32 bytes.
- The emitter and the generated Slice 2/Slice 3 fixtures were audited for
  field-address operations. Field access is emitted as a value read; immutable
  update reconstructs the struct; boxing, list, and tensor paths take the
  address of a whole temporary struct rather than an individual field.
- A direct Boolean field passed to a foreign macro is materialized as an
  ordinary scalar `int` first. The regression macro applies `__typeof__` to its
  argument, which fails on a C bitfield and therefore proves the boundary
  materialization remains present.
- The generated-C fixture covers reads, immutable update, whole-value copying,
  inline list and tensor storage, stack `Option`, and `Result`
  boxing/unboxing. Three stateful foreign calls also prove constructor
  arguments retain source evaluation order. The generated declaration and
  runtime behavior pass under Clang and Homebrew GCC 14.
- The complete generated fixture passes the warning sweep with
  `-Werror=unsequenced` and `-Werror=incompatible-pointer-types`, and passes
  Clang ASan plus UBSan with the separately compiled foreign helper.
- The focused DCE, list-layout, FFI, and type-layout batch passes 38 tests. The
  broader Core emitter and pipeline batch passes 257 tests.

Measured Darwin arm64 candidate:

| Layout | O0 size/alignment | O2 size/alignment | Change from Slice 2 |
|---|---:|---:|---|
| Three consecutive value-struct flags | 1 byte / 1 | 1 byte / 1 | 2 bytes smaller (67%) |
| Interleaved flags and words | 32 bytes / 8 | 32 bytes / 8 | Unchanged |
| Heap-record flags | 32 bytes / 8 | 32 bytes / 8 | Unchanged; outside Slice 3 |
| Foreign-ABI mixed value struct | 32 bytes / 8 | 32 bytes / 8 | Unchanged; offsets `0, 8, 16, 24`, widths `4, 8, 4, 8` |

Candidate provenance:

- fixture SHA-256
  `ef470eef0b619f1ea69a6ed762a15df78c87e3a63f3897116a7feb526911c673`
- support header SHA-256
  `60104fe84967e3baaabc0ce108bbe622442600fdd2691dd3c43c1fccb397ba09`
- support source SHA-256
  `718b4f1347ff55063ad08a00fb9bdfe607d01e263da8029afaa80506791c7d45`
- generated C SHA-256
  `694cfaaa688b324d8b45a291e8c4dbd14d2148accfd1442cfef7dcb4dea82ad0`
- host, bootstrap compiler, C command, C version, target, repository revision,
  and repository state match the Slice 0 baseline above.

Six order-alternated pairs replayed the same captured 2,500,654-byte
`emit_core_c` request through the Slice 2 and Slice 3 renderer bridges:

| Metric | Slice 2 ordinary `_Bool` | Slice 3 bitfields | Difference |
|---|---:|---:|---:|
| Median elapsed | 0.525083 s | 0.530277 s | +0.99% |
| Median peak RSS | 60,989,440 bytes | 60,874,752 bytes | -114,688 bytes (-0.19%) |

The request SHA-256 was
`06cae9fdf61a7c7cbda2de472cf0951f495da290e4a6d9cf1531d2b72c20da`.
Slice 2 and Slice 3 renderer SHA-256 values were respectively
`3bf66ee94f80f6256c81007409419b05cce037766abbd35869dcb77e65bfa253`
and
`f7ca72cd91cd0f2d62ae86a1ba1da5f720cceee4db858539175262f0916dc352`.
Every Slice 2 response had SHA-256
`2a4bccf2d1cc38c0ca984a9b82c79ac6e2623747e103dc39a628a0512e00eda4`;
every Slice 3 response had SHA-256
`47fb21960fd72bf54ce1593db63a2f873703f3b3eae9ce8d0c7e6889bb409151`.
The response difference is the expected field declaration change. Treat this
as bounded evidence that bitfield emission is latency neutral, not a general
compiler latency or peak-RSS claim.

All 12 raw samples and their pair order are retained in
`benchmarks/results/compiler_record_layout_slice3_2026-07-25.tsv`.

## Slice 4: Type-Shape Summary Re-evaluation

Completed as a measured rejection on 2026-07-25. No type-shape source change
is retained.

The representation-only experiment added an observed but unconsumed function
carrier bit while retaining the existing traversal and stopping rules. Six
alternating pairs compared these artifacts:

```text
two-Boolean baseline:        dce50aa5387c3972a226bdf832bd9c8129c67617427ac25508e51a371ff85b17
three-Boolean candidate:     d57db4aa09ff5ee120f34a530b13747d1ba926349206a605029cb0685363428c
baseline median:             452.877 ms
three-Boolean median:        453.170 ms
median change:                +0.065%
baseline median peak RSS:  9,609,216 bytes
candidate median peak RSS: 9,592,832 bytes
peak-RSS change:              -0.171%
```

Every run reported workload checksum `388`. Recursive presence, list presence,
candidate detection, and merge call counts remained exactly `4,288`, `4,288`,
`4,288`, and `8,448`, respectively. This isolates the packed three-Boolean
aggregate as neutral under the bounded profiled workload.

The first fused variant removed all `4,288` standalone candidate-scan calls and
reduced named-component expansion from `8,576` to `4,288` calls. It nevertheless
regressed median elapsed time from `465.752 ms` to `497.385 ms` (`+6.792%`) and
median peak RSS by `1.195%`. All six pairs were slower. Its artifact key was
`511d71483870b80af6f581f96fdbf3d08bb7fe87455a144bf26c7b5095a45ff1`.

A second fused variant preserved the `8,448` preflight-helper calls but
flattened their predicate, reducing nested two-flag completion-helper calls
from `8,576` to `128`. It still regressed median elapsed time from `549.800 ms`
to `589.209 ms` (`+7.168%`) and median peak RSS by `0.595%`. All six pairs were
again slower. Its artifact key was
`95207cb05a016a7ad263b5d16496b859b5c59fa1f23853748ffbdaba85c0e531`.
The representation-only field, both fusion variants, and their memo changes
were therefore removed.

Absolute times varied under concurrent local test load, but each comparison
alternated order, all checksums and call counts matched, and both fusion
variants lost every pair. Raw profile rows and pair order are retained in:

- `benchmarks/results/compiler_type_shape_slice4_2026-07-25.tsv`
- `benchmarks/results/compiler_type_shape_slice4_fusion_2026-07-25.tsv`
- `benchmarks/results/compiler_type_shape_slice4_fusion_flat_predicate_2026-07-25.tsv`

## Slices 5-6: Heap Records

Heap records are managed pointers and are rejected from supported default
foreign by-value boundaries. Pure and `@no_copy` foreign calls may still borrow
them by pointer, so foreign-reachable heap records retain their existing C
field layout. Apply the same two-step progression to internal records:

1. ordinary `_Bool` fields without reordering (Slice 5, implemented);
2. consecutive `_Bool : 1` bitfields (Slice 6, not started).

Measure actual object `sizeof`, compiler peak RSS, allocator size-class effects,
and compilation latency after each step.

### Slice 5: Ordinary Heap-Record Booleans

Implemented on 2026-07-25. The change is deliberately declaration-only:

- `c_heap_record_field_type` maps only an internal heap field whose Core type
  is `Bool` to `_Bool`; all other fields retain `c_type_name`.
- Foreign-reachable heap records are tracked transitively in a separate
  registry and retain C `int` Boolean fields for pure and `@no_copy` pointer
  borrows.
- Heap-record constructor parameters remain ordinary C `int`, so scalar and
  call ABI behavior is unchanged.
- The ARC header remains first, fields remain in source order, and constructor
  assignments remain in source order.
- No bitfields or field reordering are introduced in this slice.

The heap fixture gained a third Boolean field so ordinary narrowing has an
observable alignment effect without reordering:

| Layout | Slice 3 renderer | Slice 5 renderer | Change |
|---|---:|---:|---:|
| Heap record with ARC header, three flags, and one pointer | 40 bytes / 8 | 32 bytes / 8 | 8 bytes smaller (20%) |
| Runtime small-object pool allocation | 64 bytes | 32 bytes | 32 bytes smaller (50%) |

The allocator result is measured through the same `blorp_pool_class` and
`blorp_pool_sizes` definitions embedded in the generated program. Both Clang
and GCC report the same object size at `-O0` and `-O2`. The foreign-ABI mixed
value struct remains 32 bytes with 4-byte `int` Boolean fields at offsets 0 and
16.

Generated-C and behavior evidence:

- The declaration contains the ARC header followed by three ordinary `_Bool`
  fields and the pointer payload. Measured offsets are header 0, flags 16/17/18,
  and payload 24.
- The constructor remains
  `LayoutHeapFlags_make(int, int, int, blorp_String*)`.
- Construction, field reads, immutable update, whole-record copying, and ARC
  payload ownership execute successfully at `-O0` and `-O2`.
- Pure and `@no_copy` foreign pointer borrows both exercise a separate heap
  record whose Bool field is statically asserted to remain the size of C
  `int`.
- Clang's unsequenced and incompatible-pointer warning gate passes; GCC syntax
  and execution pass.
- Clang ASan plus UBSan passes. Runtime leak checking reports 11 allocations,
  11 releases, zero leaked objects, and zero leaked bytes.
- The focused type-layout, emitter, DCE, FFI-boundary, and list-layout batches
  pass 296 tests.

The standard self-hosted `./blorp compile --no-embed-runtime` audit path still
rejects the fixture's Slice 3 inline value-struct list literal at the OCaml
Core projection boundary, before heap-record C emission. The same failure
reproduces after removing every Slice 5 fixture addition, so it is not caused
by heap `_Bool` storage. The source-driven production host path supplies the
generated-C warning and execution evidence above; closing the projection gap
remains separate work.

Candidate provenance:

- fixture SHA-256
  `27a09cf6977f313b54dc56289c67d45068b5431c1741628c8a675da316e08c20`
- support header SHA-256
  `bb1034b5bcbd50286a721aff6dd599da0daaed1d15a986ff24ba99ef3bf0c065`
- generated C SHA-256
  `44ca4bff1e398b15be6e3c388ea268b8729896b2e6f4748a50aabc306e8f2293`
- request SHA-256
  `9caf084428150fb2b9bee2b97d44ae25251868f31db9433d0dc279d4aea367bb`
- Slice 3 baseline renderer SHA-256
  `f7ca72cd91cd0f2d62ae86a1ba1da5f720cceee4db858539175262f0916dc352`
- Slice 5 candidate renderer SHA-256
  `1525c15c654996bfd6975e95a6f24b596dded5abb8d992caed447f3d3ce31785`

Six order-alternated pairs replayed the same 2,554,285-byte `emit_core_c`
request:

| Metric | Slice 3 renderer | Slice 5 renderer | Difference |
|---|---:|---:|---:|
| Median elapsed | 0.328106 s | 0.323677 s | -1.35% |
| Median peak RSS | 64,323,584 bytes | 64,266,240 bytes | -57,344 bytes (-0.09%) |

All baseline responses had SHA-256
`dd083ff0c5a958550b9eb5c266244fa7f49eb465ec60fad7a8ac6fde86153d82`;
all candidate responses had SHA-256
`1805324f3854094df751915246fcebc99894ebb1ffb3e6008d8be950e5485c48`.
The generated-C response diff contains only the three internal heap-field type
changes. The candidate was faster in all six pairs, but treat the 1.35%
latency reduction only as evidence that the ABI-safe heap registry does not
introduce a measurable regression, not as a full-build performance claim. The
0.09% RSS difference is immaterial; the compact layout will not affect the
renderer helper's own heap until a later compiler is built by this emitter.
Raw rows are retained in
`benchmarks/results/compiler_record_layout_slice5_2026-07-25.tsv`.

## Slice 7: Alignment-Aware Ordering

Only internal layouts may be reordered. Preserve the ARC header first, then use
a stable descending-alignment order:

```text
ARC header
pointer and machine-word fields
32-bit fields
16-bit fields
byte fields
packed Boolean fields
```

Use designated C initializers so physical ordering cannot alter constructor
argument evaluation or source semantics. Nested value-struct alignment must
come from an explicit layout model rather than guesses based on type names.

## Verification Matrix

Every representation-changing slice must cover:

- declaration rendering;
- constructor evaluation order;
- field reads and assignments;
- immutable record/struct update;
- whole-value copying;
- boxing and unboxing;
- inline list and tensor storage;
- stack `Option`/`Result` wrapping where applicable;
- generated-C warning audit;
- Clang and GCC syntax;
- macOS arm64 and Linux amd64 CI;
- foreign-signature layout preservation;
- focused compiler tests and sanitizers.

## Measurement Protocol

For localized layout checks:

```bash
benchmarks/compiler_record_layout
```

For typechecking latency:

```bash
benchmarks/compiler_typecheck_profile
```

Use at least six alternating baseline/candidate pairs for latency decisions.
Compare medians and retain raw outputs. Every run must report the same valid
workload checksum.

For memory, use the existing bounded typecheck-memory fixture before attempting
a full compiler rebuild. Full-build peak RSS is a confirmation gate, not the
first feedback loop.

## Decision Log

| Date | Slice | Decision | Evidence |
|---|---|---|---|
| 2026-07-25 | Planning | Preserve scalar and foreign `Bool` as C `int`; compact storage only inside eligible aggregates | Avoids a global ABI migration |
| 2026-07-25 | Planning | Narrow fields before introducing bitfields | Separates aggregate width from bitfield masking cost |
| 2026-07-25 | Planning | Delay physical field reordering until compact storage is measured | Keeps each change independently attributable |
| 2026-07-25 | 0 | Accept the local generated-C probe; keep cross-platform status open | macOS O0 and O2 both report 12-byte three-flag structs and 32-byte mixed/heap/foreign layouts |
| 2026-07-25 | 5 | Accept ordinary `_Bool` storage for internal heap-record fields while preserving foreign-borrow ABI | Three-flag object moves from 40 requested/64 allocated bytes to 32/32; bounded emitter latency is -1.35%; ARC/sanitizer checks are clean |
| 2026-07-25 | 1 | Accept explicit ABI classification without changing storage | Direct, aliased, and transitive tests pass; generated-C hash is unchanged |
| 2026-07-25 | 2 | Accept `_Bool` storage for internal value-struct fields locally; keep Linux validation open | Three flags shrink 12 to 3 bytes at O0/O2; scalar, constructor, heap, and live foreign ABI representations stay unchanged |
| 2026-07-25 | 3 | Accept one-bit `_Bool` fields for consecutive internal value-struct Boolean runs locally; keep Linux validation open | Three consecutive flags shrink 3 to 1 byte; six-pair replay is neutral; Clang/GCC and sanitizer checks pass |
| 2026-07-25 | 4 | Reject retaining an unused third type-shape Boolean | The representation is neutral but has no standalone benefit |
| 2026-07-25 | 4 | Reject compact-summary traversal fusion | Both measured variants removed the redundant scan but regressed median latency by 6.792% and 7.168% |
