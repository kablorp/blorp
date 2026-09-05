# Pool Immutable String Literals As Static Artifact Data

**Status:** Implemented

## Objective

Emit each distinct value-position string literal once as immutable,
artifact-scoped static storage and reference that storage from every use. Teach
ownership lowering that these literals are immortal so it does not surround
them with runtime allocation, retain/release, or cancellation-cleanup code.

This is a deliberate change to Blorp's current ownership/storage contract.
Today strings are always mortal managed allocations. The implementation must
update that contract coherently; it must not quietly restore the former lazy
cached-literal helper.

## Implementation result

The implementation adds one deterministic post-`consume_specialize` Core pass,
preserves the assigned IDs through ownership and late Core, validates the pool
at the backend boundary, and emits static objects using the runtime's exact
`blorp_String` type.
Perceus and C emission omit literal-attributable ARC and cancellation cleanup;
the runtime's existing immortal/COW behavior protects the static bytes.

A controlled self-host census compiled identical current source with the
pinned bootstrap and optimized candidate compilers using identical
`--no-format --no-embed-runtime` flags:

| Measurement | Direct parent | Candidate | Change |
| --- | ---: | ---: | ---: |
| Generated C lines | 1,419,845 | 1,295,688 | -8.74% |
| Generated C bytes | 100,728,611 | 91,509,015 | -9.15% |
| Dynamic string construction sites | 25,244 | 991 | -96.07% |
| Distinct static literal objects | 0 | 6,964 | +6,964 |
| Static literal references | 0 | 24,253 | +24,253 |
| `blorp_retain(...)` sites | 50,181 | 50,176 | -0.01% |
| `blorp_release(...)` sites | 74,331 | 63,448 | -14.64% |
| `blorp_release_arc_only(...)` sites | 2,245 | 1,635 | -27.17% |
| Cancellation cleanup scopes | 48,305 | 35,579 | -26.35% |
| Self-host C emission wall time | 33.10s | 32.76s | -1.01% |
| Native `cc -O2` wall time | 86.16s | 79.55s | -7.67% |
| Native `cc -O2` peak RSS | 6.31 GiB | 5.68 GiB | -9.97% |

The remaining 991 construction sites are dynamic compiler/runtime operations,
not direct value-position `LiteralExpr(StringLiteral(...))` emission. Timings
are single local macOS arm64 observations; the structural counts are the stable
acceptance measurements.

## Current problem

`emit_string_literal_expr` in
`blorp/src/compiler/stage_10_backend/emit.brp` emits a fresh heap string at every
value-position literal occurrence:

```blorp
private pure func emit_string_literal_expr(value: String) -> String:
	literal_c: String = c_string_literal(value)
	length_c: String = value.length().to_string()

	if string_contains_nul(value):
		"blorp_string_create_len(" + literal_c + ", " + length_c + "L)"
	else:
		"blorp_string_create(" + literal_c + ")"
```

Because a string literal is currently `FreshOwned`, Perceus and the backend
must also balance it like any other heap allocation. A repeated literal can
therefore contribute allocation calls, cleanup frames, retains/releases, and
destructor paths at every use site.

The current self-host C artifact at `3d8ec393b04d`, excluding embedded runtime
source, contains:

| Measurement | Current value |
| --- | ---: |
| Generated compiler C | 1,416,117 lines / 100,448,633 bytes |
| `blorp_string_create(...)` / `_len(...)` call sites | 25,223 |
| Distinct rendered literal constructions | approximately 7,933 |
| Duplicate construction sites | approximately 17,290 |
| Most repeated literal (`"Error: unknown package command: "`) | 2,049 sites |

The exact distinct count is an orientation metric because escaped spelling and
the optional explicit length must be normalized to literal bytes in the
compiler, not deduplicated with a regex. It nevertheless shows ample repeated
data.

Refresh this census against the direct parent revision. Issues 52 and 53 can
remove duplicated matches and cleanup first; do not claim their savings again
as string pooling. The acceptance target below compares identical sources and
flags on the direct parent and candidate, while retaining this historical
census for context.

## Why the previous literal cache is not the solution

Commit `5f899c5f` intentionally removed cached/immortal string behavior and
established the current mortal-string contract. The old emitted shape was a
lazy assignment expression similar to:

```c
(__sl_0 ? __sl_0 : (__sl_0 = blorp_string_create("...")))
```

That design had several undesirable properties:

- process-lifetime heap allocations and special leak/profiling treatment;
- special cases across ownership, global initialization, COW, and tests; and
- unsequenced read/write hazards when the same cached literal appeared more
  than once in one C expression.

The existing audit fixture
`blorp/test/compiler/pipeline/codegen_audit/should_pass/string_literal_helper_reuse.brp`
explicitly rejects that assignment shape. Keep rejecting it.

The new design has no lazy initialization and performs no heap allocation. All
literal storage is defined statically before execution. The change is closer to
C string constants, but retains the `blorp_String` layout and COW contract.

## Required ownership and storage model

`StringLiteral` is already an exact Core distinction; no source-name heuristic
is required. Give a value-producing `LiteralExpr(StringLiteral(...))` an
explicit immortal/static ownership fact rather than `FreshOwned`. One
acceptable extension to the ownership vocabulary is:

```blorp
union CoreValueProvenance:
	FreshOwned
	Borrowed
	Alias(CoreVar)
	StaticImmortal
```

The exact type may follow the ownership-roadmap implementation, but the facts
must remain explicit:

- `StaticImmortal` never requires `DupExpr`, `DropExpr`, cancellation cleanup,
  or global shutdown cleanup;
- it is safe across calls, returns, captures, tasks, and aggregates because its
  storage lives for the artifact lifetime;
- passing it to a consuming API is valid because runtime retain/release of an
  immortal object are no-ops;
- a COW operation sees it as non-unique, allocates a mortal copy, and mutates
  only that copy; and
- dynamically constructed strings remain ordinary tracked, mortal owners.

If the current Perceus plan cannot represent this fact without scattering
literal checks, add the narrow ownership variant and make all downstream
switches exhaustive. Do not emit ordinary drops and rely solely on the runtime
immortal check: that would avoid deallocation but would not shrink the C.

Literal patterns used only for comparison are not value objects and do not
need pool entries. `emit_string_literal_comparison` already compares against C
bytes directly; preserve that allocation-free path.

Make the storage distinction explicit in Core. Add an opaque pool ID and a
value-expression variant in `blorp/src/compiler/stage_09_core/ir.brp`:

```blorp
opaque type StaticStringLiteralId = Int

-- Add to CoreExpr.
StaticStringLiteralExpr(
	StaticStringLiteralId,
	String,
	CoreType,
	CoreSourceLoc,
)
```

Add `blorp/src/compiler/stage_09_core/static_string_literals.brp` and run it
immediately after `consume_specialize` and before Perceus. The pass traverses
reachable value expressions in deterministic declaration/expression order,
assigns one ID per exact byte string, and rewrites only
`LiteralExpr(StringLiteral(...))` value nodes. Literal match-case keys remain
ordinary `CoreLiteral` comparison data. Later passes preserve the ID/value
pair; the backend rejects an unclassified value-position `StringLiteral`.

At Stage 10, collect the surviving `StaticStringLiteralExpr` nodes by their
already-assigned IDs to emit definitions. This is not a second interning
authority: validate that one ID always has one byte value and one byte value
always has one ID. Gaps are allowed when a later transform removes the last use.

## Required C representation

Collect all reachable value-position string literals in a deterministic
artifact-level pool keyed by exact byte sequence and byte length. Emit one
static definition per distinct key before functions that reference it. Prefer
one shared declaration macro plus one compact invocation per literal so the
pool does not replace dynamic-call lines with many initializer lines:

```c
#define BLORP_STATIC_STRING(name, length, bytes) \
    _Static_assert(sizeof(bytes) == (length) + 1, "string literal byte length"); \
    static blorp_String name = { \
        .header = { BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 }, \
        .len = (length), \
        .capacity = (length), \
        .data = bytes \
    }

BLORP_STATIC_STRING(__blorp_string_literal_17, 3L, "a\000b");

#define BLORP_STRING_LITERAL_17 (&__blorp_string_literal_17)
```

The emitted definition uses the runtime's actual flexible-array type, which
avoids a backing-struct cast and any global strict-aliasing exception. The
supported Clang/GCC C toolchains allocate the initialized trailing bytes in
static storage. A redundant cast at use sites is harmless.
Required properties:

- storage layout is ABI-compatible with `blorp_String` (`header`, byte length,
  capacity, bytes, trailing NUL);
- array capacity is `byte_length + 1`, including empty strings;
- embedded NUL bytes do not truncate data or affect the stored length;
- escaping cannot merge a hex/octal escape with following bytes;
- Unicode is pooled by the exact encoded bytes used by the runtime;
- names/IDs are deterministic under identical Core input;
- definitions are initialized by C static data, not constructors, lazy guards,
  atomics, mutexes, or heap calls; and
- generated code never writes this storage directly.

`static const` is optional. Current runtime ARC helpers accept mutable object
pointers and atomically read the header, so a non-const internal definition may
be the cleanest ABI fit. Immutability is enforced by the compiler/COW protocol:
`blorp_is_unique` returns false for `BLORP_IMMORTAL_REFCOUNT`, and
`blorp_string_cow` copies a non-unique string before mutation.

Use the same canonical bytes as `c_string_literal`, but deduplicate before C
escaping. First-seen traversal order or sorted byte order is acceptable; name
the policy and test it. Do not key the pool by rendered C text, source spelling,
pointer identity, or a hash without equality confirmation.

## Pool construction guidance

1. **Add the lowering test first.** Add
   `blorp/test/compiler/stage_09_core/test_core_static_string_literals.brp`.
   Walk a `CoreProgram`, assign ordered IDs, and report occurrence counts. Prove
   `"a\0b"`, `"a"`, empty, Unicode, quotes, and backslashes have correct
   distinct identities; prove comparison-only literals are not rewritten.
2. **Add the pass at one authoritative boundary.** Wire
   `static_string_literals.brp` immediately after `consume_specialize` and
   before Perceus in `pipeline.brp`/`pipeline_stage.brp`. Update
   `docs/ARCHITECTURE.md`. Do not independently intern literals in Perceus and
   Stage 10.
3. **Classify string literals as static immortal.** Update Perceus result
   ownership, temporary detection, argument normalization, closure capture,
   aggregate construction, returned literals, globals, and cancellation
   planning. Remove now-impossible literal `DupExpr`/`DropExpr` operations.
4. **Emit definitions once.** Collect the explicit IDs into a small Stage 10
   record such as:

   ```blorp
   record StaticStringLiteralEntry {
       id: StaticStringLiteralId,
       value: String,
       byte_length: Int,
       occurrences: Int
   }
   ```

   Use explicit IDs from the pool in rendering. The occurrence count is useful
   for tests/measurement but need not survive production emission.
5. **Preserve the COW boundary.** Add a test that assigns a literal, performs a
   string update/append through the normal consuming COW path, and proves a
   second reference still observes the original literal.
6. **Define observability intentionally.** Static literals are program data,
   not dynamic heap allocations. `get_mem_stats()` and leak checking must not
   count them. `is_unique(literal)` must return `False`, matching other immortal
   values. Define and test `refcount(literal)` consistently; prefer the current
   runtime immortal result unless the public API already normalizes immortal
   values. `size_of(literal)` must return the same result as a dynamically
   created `String` under the existing `sizeof(blorp_String)` contract; this
   issue does not redefine it as total trailing-storage allocation size.
7. **Update globals without broadening scope accidentally.** A global whose
   value is exactly a literal can point to pooled storage and needs no shutdown
   drop. Records/lists/unions containing literals may continue to be dynamically
   materialized; making recursively static string-containing object graphs is a
   follow-up unless it falls out mechanically and receives its own tests.
8. **Keep FFI semantics explicit.** Borrowed string data remains valid for the
   artifact lifetime. A foreign boundary that promises mutation or ownership
   outside Blorp's retain/release ABI must receive an explicit mortal copy; do
   not assume arbitrary C may write static storage.
9. **Delete stale mortal-literal special cases and documentation.** Update
   `docs/OWNERSHIP_MODEL.md`, the Perceus ownership roadmap, memory API docs,
   codegen audit comments, and tests in the same change.

## Semantic and safety requirements

- Every value-position occurrence of identical literal bytes denotes the same
  immutable static object within one generated artifact.
- There is no runtime initialization order and no process-exit cleanup for the
  pool.
- Retain, release, ARC-only release, task cancellation, and normal return are
  safe no-ops for the static object's lifetime.
- COW mutation never writes pooled bytes and returns a normal mortal owner.
- Threaded use is read-only and race-free.
- Empty strings, embedded NULs, all supported escapes, and Unicode preserve
  current byte length and equality/order semantics.
- Literal comparison patterns remain allocation-free and need no pooled object
  unless the same source value also occurs in value position.
- Dynamic strings, FFI-returned strings, formatted strings, concatenation, and
  `to_string` remain mortal and visible to memory/leak instrumentation.
- Static strings do not receive destructor IDs or allocation metadata.
- Pool IDs and generated C are deterministic.
- No source string spelling or generated C name controls ownership behavior.

## Tests to add or update

### Ownership and Core

Extend `blorp/test/compiler/stage_09_core/test_core_perceus.brp` with:

- returned literal has `StaticImmortal`, not `FreshOwned`;
- repeated literal argument needs no `DupExpr`/`DropExpr`;
- literal stored in list/record/union transfers without a pre-retain;
- literal captured by a closure/task needs no capture retain/drop;
- literal across a cancellable point needs no cleanup registration;
- dynamic string expressions remain owned and balanced; and
- exact `CoreVar`/definition ownership behavior is otherwise unchanged.

### Backend C shape

Extend `blorp/test/compiler/stage_10_backend/test_core_emit.brp` to cover:

- three equal literals produce one definition and three references;
- unequal literals produce separate definitions;
- empty, embedded-NUL, Unicode, quote, slash, and control-byte initializers;
- deterministic pool order/names;
- literal-only global points directly to static storage and has no global drop;
- local/return/call/closure/aggregate literal uses contain no
  `blorp_string_create*`, retain/release, or cleanup frame attributable to the
  literal; and
- literal match comparisons still use direct bytes and allocate nothing.

Update the existing `string_literal_helper_reuse.brp` audit to require pooled
storage while continuing to reject the old lazy assignment:

```blorp
-- EXPECT-C: static struct
-- EXPECT-C: __blorp_string_literal_
-- EXPECT-NOT-C: blorp_string_create("\n")
-- EXPECT-NOT-C: (__sl_0 ? __sl_0 : (__sl_0 =
```

The exact one-definition/three-reference count belongs in `test_core_emit`,
because the codegen-audit comment format checks presence/absence rather than
occurrence counts.

Update `string_literal_nul_length.brp` to assert a length-3 static object with
four storage bytes and no `_create_len` call.

### Runtime ownership and observability

Update or add coverage for:

- `blorp/test/runtime/memory/test_memstats_observability.brp`: executing only a
  literal produces zero dynamic allocations/current objects;
- a neighboring test proving `to_string(7)` still produces one dynamic object;
- `blorp/test/runtime/memory/leak_check_baselines/string_literal_lifecycle.brp`;
- literal capture and concurrent reuse;
- `is_unique(literal) == False`;
- defined `refcount` and correct `size_of` behavior;
- literal COW append/update leaves the pooled original unchanged; and
- FFI copy/mutation boundaries if any accept consumed mutable strings.

## Detailed fast feedback loop

### 1. Red/green pool identity and Perceus behavior

```bash
bin/blorp check --no-format blorp/src/compiler/stage_09_core/static_string_literals.brp
bin/blorp test blorp/test/compiler/stage_09_core/test_core_static_string_literals.brp
bin/blorp check --no-format blorp/src/compiler/stage_09_core/perceus.brp
bin/blorp test blorp/test/compiler/stage_09_core/test_core_perceus.brp
```

Start with a tiny Core program containing `"same"` three times, `"different"`,
`"a\0b"`, and a literal comparison case. Assert two value-pool entries plus the
NUL entry, no entry for comparison-only bytes, and no literal-owned drops. This
loop exercises working-tree source without rebuilding the compiler.

### 2. Red/green static C emission

```bash
bin/blorp check --no-format blorp/src/compiler/stage_10_backend/emit.brp
bin/blorp test blorp/test/compiler/stage_10_backend/test_core_emit.brp
```

Assert exact definition/reference counts and inspect the emitted initializer.
Keep the emitter test small enough to print the whole artifact on failure. Test
NUL and Unicode before broad integration; they catch byte/character and C
escaping mistakes early.

### 3. Inspect one integrated source probe

After one `make`, compile an audit fixture without the runtime implementation:

```bash
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-string-pool.XXXXXX")
probe_c="$probe_dir/probe.c"
bin/blorp compile --no-format --no-embed-runtime \
  -o "$probe_c" \
  blorp/test/compiler/pipeline/codegen_audit/should_pass/string_literal_helper_reuse.brp
wc -l -c "$probe_c"
rg -n '__blorp_string_literal_|blorp_string_create|blorp_(retain|release)\(' "$probe_c"
rm -f "$probe_c"
rmdir "$probe_dir"
```

The fixture must show one pooled newline object, three references, no heap
creation, and no lazy assignment expression.

### 4. Exercise COW and memory observability

```bash
bin/blorp test blorp/test/runtime/memory/test_memstats_observability.brp
bin/blorp test --leak-check --suite --timeout 30 \
  blorp/test/runtime/memory/leak_check_baselines/string_literal_lifecycle.brp
bin/blorp test blorp/test/runtime/text/
```

Add/run a focused literal-COW test before the broader text directory. Verify
the mutated result is mortal/unique where expected and the same literal used
again still has its original bytes.

### 5. Recount the self-host artifact

```bash
self_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-string-census.XXXXXX")
self_c="$self_dir/blorp.c"
bin/blorp compile --no-format --no-embed-runtime -o "$self_c" blorp/src/main.brp
wc -l -c "$self_c"
rg -o 'blorp_string_create(_len)?\(' "$self_c" | wc -l
rg -o '__blorp_string_literal_[0-9]+ = \{' "$self_c" | wc -l
rg -o '__blorp_string_literal_[0-9]+' "$self_c" | sort -u | wc -l
rg -o 'blorp_(retain|release|release_arc_only)\(' "$self_c" | sort | uniq -c
rg -o 'BLORP_TASK_CLEANUP_SCOPE' "$self_c" | wc -l
rm -f "$self_c"
rmdir "$self_dir"
```

Use identical source and flags for baseline/candidate. Attribute any remaining
`blorp_string_create*` calls: they should represent dynamic construction paths,
not `LiteralExpr(StringLiteral(...))` emission.

### 6. Final gates and profiling

```bash
scripts/compiler-check --changed
scripts/test compiler-blorp
scripts/test runtime
scripts/test leak
blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh bin/blorp
```

Run the relevant sanitizer gate if ownership/COW/runtime declarations change.
Report C-emission time and `-O2` native C compilation time in addition to line
and byte counts; do not claim speed from source size alone.

## Acceptance criteria

1. The explicit pre-Perceus Core pass deduplicates reachable value-position
   literals by exact bytes and byte length with deterministic IDs; later passes
   preserve `StaticStringLiteralExpr` identity.
2. Each distinct pooled value has exactly one statically initialized
   ABI-compatible `blorp_String` object and no runtime initializer/cleanup.
3. Perceus represents literal storage as immortal/static and emits no
   literal-attributable `DupExpr`, `DropExpr`, retain/release, or cancellation
   cleanup. Runtime no-op checks alone do not satisfy this criterion.
4. All direct `LiteralExpr(StringLiteral(...))` value emission stops calling
   `blorp_string_create`/`blorp_string_create_len`; remaining calls are
   attributed to dynamic string construction.
5. Empty, embedded-NUL, Unicode, escaped, global, local, returned, captured,
   aggregate, concurrent, and COW-mutated cases are covered.
6. The former lazy cached-assignment shape remains absent and explicitly
   rejected by the codegen audit.
7. Static literals are excluded from MemStats/leak allocation counts;
   dynamically created strings remain fully observable.
8. `is_unique`, `refcount`, `size_of`, COW, FFI, retain/release, and task
   cancellation semantics are documented and tested for pooled strings.
9. Controlled self-host C is net smaller in both lines and bytes than the
   direct-parent baseline, with no increase in retain/release or cleanup counts.
   A 3% reduction remains the measured target, not an unsupported hard gate;
   report and explain the result after any prior issue 52/53 savings.
10. `docs/OWNERSHIP_MODEL.md`, the Perceus roadmap/current constraints, memory
    API docs, audit comments, and stale mortal-literal tests are updated in the
    same change.
11. Focused Core/emitter/runtime tests, codegen audit,
    `scripts/compiler-check --changed`, compiler Blorp tests, runtime/leak gates,
    and relevant sanitizer checks pass.
12. The PR reports before/after unique literals, literal occurrences,
    construction calls, retain/release/cleanup counts, C lines/bytes, C-emission
    time, and `-O2` native C compile time.

## Out of scope

- a runtime string-interning hash table;
- lazy cached literal initialization;
- interning dynamically created strings;
- changing string equality, ordering, encoding, or public mutation syntax;
- pooling literal-pattern comparison bytes as `blorp_String` objects; and
- recursively static records/lists/unions containing strings unless proposed
  and tested as a separately reviewed extension.
