# Eliminate Temporary-Buffer-to-Managed-Buffer Copies

**Status:** Implemented

## Objective

Remove runtime paths that build a complete result in a temporary raw C buffer,
allocate a second managed `String` or `Bytes`, copy the complete result into it,
and then free the temporary buffer.

Start with collection serializers whose result size can be computed exactly
without repeating expensive work. Do not turn this into a general buffer
architecture change. Unknown-length streaming paths are follow-up candidates
only after a separate prototype shows that direct managed growth improves both
latency and memory behavior.

The desired steady-state shape is:

```text
compute exact output length
        |
        v
allocate the final managed value once
        |
        v
write directly into its trailing storage
        |
        v
return that same allocation
```

The current avoidable shape is:

```text
allocate raw temporary storage
        |
        v
format or read the complete result
        |
        v
allocate the final managed value
        |
        v
copy every result byte
        |
        v
free the temporary storage
```

For a nonempty `N`-byte result, the latter adds one raw allocation, one raw
free, and one `N`-byte copy. It also briefly keeps both the temporary capacity
and the final managed allocation live.

## Why This Is An Evidence-Gated Cleanup

Writing into managed storage is clearly preferable when the exact final size
is already known or is cheap to calculate. It is not automatically preferable
for every growable buffer.

`String` and `Bytes` use inline trailing storage:

```c
struct blorp_String {
    blorp_Object header;
    long len;
    long capacity;
    char data[];
};

struct blorp_Bytes {
    blorp_Object header;
    long len;
    long capacity;
    unsigned char data[];
};
```

They are allocated through `blorp_alloc`, which owns ARC, allocation
statistics, leak metadata, and pooled-allocation behavior. A managed object
must therefore **never** be passed to raw `realloc`. Growing it requires
allocating a replacement managed object, copying the live prefix, and
releasing the old object.

The managed `capacity` field describes logical writable capacity. The
allocator may round a small object's physical block up to a pool size; that
implementation detail is separate from the returned logical capacity.

That distinction creates three classes of candidate:

1. **Exact-size outputs:** allocate once and fill directly. These are the
   required scope of this issue.
2. **Upper-bound outputs:** direct allocation may retain much more memory than
   the logical result. Accept only with explicit capacity and latency evidence.
3. **Unknown-length streams:** managed geometric growth may copy more often
   than raw `realloc`, and it may return a value with up to roughly twice the
   required capacity. These are not part of the first implementation.

The goal is less work, not merely the absence of a visibly named temporary
buffer.

## Current Runtime Inventory

All locations are in
`blorp/src/lib/runtime/native/runtime.c`. Locate the named functions rather
than relying on line numbers, which will drift.

### Required first tranche

| Function | Current sizing | Current avoidable work | Initial decision |
| --- | --- | --- | --- |
| `blorp_list_to_string_string` | performs an upper-bound sizing pass; exact compatible sizing is cheap | raw allocation, final full copy, raw free | implement direct exact allocation first |
| `blorp_list_to_string_bool` | upper bound only; exact size from element values is cheap | raw allocation, `snprintf` per value, final full copy, raw free | implement after the benchmark characterizes the current path |
| `blorp_list_to_string_int` | upper bound only | raw allocation, final full copy, raw free | prototype exact digit sizing; accept only if retired instructions fall |
| `blorp_vector_to_string_int` | upper bound only; also renders a two-dimensional shape | raw allocation, final full copy, raw free | share the integer-width primitive; accept only if both one- and two-dimensional cases improve |

`blorp_list_to_string_string` is the highest-confidence first change because it
already traverses the input before formatting. The implementation should turn
that existing pass into an exact length calculation and write into one final
managed allocation.

Boolean sizing needs another cheap traversal but removes both the temporary
buffer and unnecessary `snprintf` calls. Integer sizing needs digit-count work
in addition to formatting. It might exchange a cheap `memcpy` for too many
integer divisions, so the integer family is explicitly conditional on the
benchmark result.

### Upper-bound numeric serializers

These functions allocate from conservative per-element bounds:

- `blorp_vector_to_string_float32`
- `blorp_vector_to_string_float16`
- `blorp_vector_to_string_float`
- `blorp_list_to_string_float`
- `blorp_list_to_string_float32`
- `blorp_list_to_string_float16`

They must not be changed by simply replacing the raw allocation with a managed
allocation of the same upper-bound capacity. Common float renderings are much
shorter than the 24- or 32-byte bounds, so that version could retain several
times the logical result size.

They are optional only if a prototype meets all of these conditions:

- each floating-point element is formatted once, not once for sizing and once
  for output;
- the returned managed capacity is acceptably close to the logical length;
- medium and large workloads retire fewer instructions;
- peak and retained memory do not regress; and
- formatting remains byte-for-byte identical for finite values, `-0`,
  infinities, and NaNs.

If no simple design meets those conditions, record the result and leave these
functions unchanged. A float-output builder is a separate issue, not a reason
to broaden this one.

### Unknown-length or externally sized buffers

The following sites exhibit the same final-copy shape, but have different
growth and ownership constraints:

| Area | Functions | Why it is deferred |
| --- | --- | --- |
| standard input | `blorp_read_all`, `blorp_read_line_nullable` | final length is not known before reading; `getline` owns its raw storage contract |
| file iteration | `blorp_for_each_line`, `blorp_for_each_chunk` | the reusable raw buffer avoids repeated capacity allocation; callbacks may retain the managed value |
| file handles | `blorp_file_read_text_fd`, `blorp_file_read_bytes_fd` | handles may refer to regular files, pipes, devices, or changing files; direct pre-sizing needs a correct fallback |
| regex replacement | `blorp_regex_replace_all` | exact sizing would normally repeat regex matching; managed growth can retain excess capacity |
| process capture | `blorp_ProcessBuffer`, `__process_buffer_to_string`, `__process_buffer_to_bytes`, `blorp_exec_output` | output is streamed and may be large; raw `realloc` can grow in place while managed storage cannot |
| temporary paths | `blorp_mkstemp_path` | `mkstemp` requires a unique mutable C string; changing the boundary needs an explicit uniqueness argument |

These paths should become individual follow-up issues if profiling shows that
the final copy matters. A promising follow-up may specialize regular files
using `fstat` while retaining the existing stream fallback. The existing
`blorp_read_file` and `blorp_file_read_chunk_fd` functions demonstrate direct
writes into managed storage when the allocation size is known.

### Intentional copies that are not candidates

Do not include these in the issue:

- small stack formatting buffers used by scalar `to_string` functions;
- `Bytes`-to-`String` and `String`-to-`Bytes` value conversions;
- copies required to create an independently owned FFI result;
- C-string copies required for APIs that need NUL termination or mutable
  storage;
- payload copies that transfer bytes from external library storage into a
  Blorp-owned value; and
- `blorp_vector_to_string_bool`, which currently uses repeated managed string
  concatenation rather than a raw temporary-to-managed final copy.

The scalar stack-buffer cases perform only the one copy required to create the
managed result. Removing their stack buffer would not eliminate a heap
allocation and could complicate formatting.

## Required Design

### 1. Measure before changing production code

Add a narrow, reproducible benchmark for collection serialization. Prefer a C
harness that includes `minicoro.h` and `runtime.c`, following the precedent in
`blorp/test/runtime/test_runtime_allocator_stats.py`. This keeps compiler time
outside the measured interval and permits the harness to inspect `len` and
`capacity` without adding a test-only production API.

The harness must cover:

- empty, one-element, medium, and large collections;
- short and long strings, Unicode strings, and an embedded-NUL string;
- all-false, all-true, and mixed Boolean lists;
- small positive integers, mixed signs, zero, and supported integer extrema;
- one-dimensional and two-dimensional integer vectors;
- current one-row and one-column vector rendering, including the existing
  loss of rank when `len == capacity`;
- a throughput mode that releases each result immediately; and
- a retained-results mode that exposes capacity inflation and peak footprint.

Every result must contribute its length and selected bytes to an observable
checksum so the optimizer cannot discard the work.

Measure optimized code (`-O2`, matching the cached runtime build) in paired,
alternating control/candidate runs. Report at least:

- retired instructions where the host supports them;
- wall time as a secondary, noise-sensitive signal;
- managed allocation count;
- logical result bytes and returned capacity bytes; and
- peak memory or peak footprint for the retained-results workload.

Timing and CPU-counter runs must use the ordinary production allocator path
with all allocation/leak/profile instrumentation disabled. Collect allocation
counts and allocator-byte snapshots in a separate process using lightweight
allocator statistics. Do not call `blorp_reset_mem_stats` in the timed process:
that API enables full per-object metadata and would measure a materially
different allocator path.

Do not add raw-allocation counters or profiling switches to production
`runtime.c`. The simple source shape establishes that each accepted conversion
removes one raw allocation/free pair; platform allocation tooling may be used
as supplemental evidence.

### 2. Allocate the final managed result exactly once

The exact-size shape should be local and explicit:

```c
size_t output_size = /* exact byte count, excluding the NUL terminator */;
if (output_size > (size_t)LONG_MAX) {
    blorp_fatal_invalid_runtime_length("String", LONG_MAX, LONG_MAX);
}

blorp_String* result = blorp_string_alloc_uninit(
    (long)output_size,
    (long)output_size
);

size_t pos = 0;
/* Fill result->data directly. */
result->data[pos] = '\0';
return result;
```

Use `size_t` and the existing checked arithmetic helpers while sizing. Convert
to `long` only after checking `LONG_MAX`. At the end, `pos` must equal the
precomputed logical size, `result->len` must equal that size,
`result->capacity` must not be smaller, and `result->data[result->len]` must be
NUL.

Do not introduce a passthrough “finalize” helper that merely assigns `len` and
returns its argument. Keep the final invariant visible at the write site.

### 3. Share only a genuinely reused integer primitive

If both integer serializers pass the fail-fast performance gate, add one small
primitive for the exact decimal byte width of a `long`. It must handle
`LONG_MIN` without signed overflow and should share magnitude logic with
`blorp_format_long_decimal` where doing so remains clear.

For example, the safe magnitude conversion is:

```c
static unsigned long blorp_long_magnitude(long value) {
    return value < 0
        ? (unsigned long)(-(value + 1L)) + 1UL
        : (unsigned long)value;
}
```

Do not create a general formatting framework for two call sites. If the helper
does not remain used by both list and vector serialization, keep the logic at
its sole owner instead.

### 4. Preserve exact rendering semantics

This is an allocation/copy refactor, not a formatting change. Preserve:

- brackets, braces, commas, spaces, and nested vector braces;
- Boolean spelling (`True` and `False`);
- integer spelling for zero, negative values, and extrema;
- current empty and null-input behavior; and
- current string-list handling, including embedded NUL behavior;
- null runtime string elements, which currently render as `""`; and
- current one-row and one-column integer-vector geometry.

`blorp_list_to_string_string` currently formats with `%s`, so an embedded NUL
terminates the visible element even though a Blorp `String` carries an explicit
length. Characterize that behavior before changing the function. Preserve it
for this refactor; if it is incorrect language behavior, file a separate
semantic issue rather than silently fixing it here.

Likewise, the runtime does not retain tensor rank. The integer-vector formatter
currently treats a value as two-dimensional only when `len > 0` and
`capacity > len`; a nominal `N x 1` value therefore renders like a flat vector.
Preserve that behavior in this issue.

## Implementation Sequence

### Step 1: establish the harness and behavior tests

Before editing `runtime.c`:

1. Add the focused benchmark and capture the control result.
2. Add or strengthen runtime behavior tests around collection serialization.
3. Prove all expected output fixtures against current `origin/main`.
4. Confirm the benchmark's returned-capacity accounting against the current
   exact managed result.

The behavior tests should live under `blorp/test/runtime/collections/`. Do not
put test helpers or counters in production runtime code.

### Step 2: implement string-list direct construction

Turn the existing sizing pass into an exact rendering-size calculation, then
write quotes, visible string bytes, separators, and brackets directly into the
managed result.

Accept this step only if:

- output is byte-identical;
- the returned capacity equals the logical result length;
- the raw temporary allocation and final copy are gone; and
- medium and large string-list workloads retire fewer instructions with no
  repeatable small-input latency regression.

### Step 3: implement Boolean-list direct construction

Compute the exact size from the values, allocate once, and use fixed-size
copies for `True` and `False`. Do not retain `snprintf` for fixed literals.

Measure this independently. Keep it only if the extra sizing traversal is
outweighed by removing `snprintf`, the raw allocation, and the final copy.

### Step 4: prototype the integer family

Add the smallest safe decimal-width calculation, then prototype list and
vector serialization. Measure before polishing or expanding tests.

Keep the integer change only if:

- both list and vector workloads retire fewer instructions;
- the two-dimensional vector case is correct;
- the extra digit-sizing traversal does not regress short collections; and
- production code remains concise enough that the change is a clear cleanup.

If the exact-sizing pass loses to the current single formatting pass plus
`memcpy`, revert the production prototype and record the rejection in this
issue. Do not compensate with caches, lookup tables, a new builder, or retained
upper-bound capacity.

### Step 5: stop and report

Do not continue mechanically into floats, file I/O, regex, or process capture.
Update the inventory with accepted and rejected candidates, record benchmark
results, and open narrowly scoped follow-up issues only where the evidence
supports them.

## Implementation Results

All four required serializer families were accepted. Each now computes its
exact result size, performs one managed `String` allocation, and writes into
that allocation directly:

- `blorp_list_to_string_string`
- `blorp_list_to_string_bool`
- `blorp_list_to_string_int`
- `blorp_vector_to_string_int`, including its current matrix rendering

The integer serializers reuse one `LONG_MIN`-safe magnitude calculation and
decimal-width helper. The existing decimal formatter skips its prefix
`memmove` when the caller supplies an exact-width destination. Empty results
use the explicit-length string constructor, avoiding an unnecessary `strlen`.

The float, file I/O, regex, and process-capture candidates remain unchanged.
Their sizing and growth constraints are materially different and do not belong
in this issue.

### Performance evidence

The final comparison compiled both `origin/main` and the working runtime with
`-O2 -fwrapv`. Seven alternating pairs supplied loop-only wall-time medians.
macOS `/usr/bin/time -lp` supplied exact hardware `instructions retired`
counters for seven alternating pairs of the same uninstrumented binaries.
Those instruction counts cover each short-lived harness process, including
fixture setup, characterization, and teardown as well as the repeated render
loop; the large repeated workloads keep that fixed overhead from determining
the result.

| Family and workload | Control wall time | Candidate wall time | Wall change | Control instructions | Candidate instructions | Instruction change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| String list, 64 elements | 25.324 ms | 4.533 ms | -82.10% | 640,448,844 | 128,895,285 | -79.87% |
| String list, 4,096 retained | 42.629 ms | 7.882 ms | -81.51% | 1,007,614,599 | 196,129,633 | -80.54% |
| Mixed Boolean list, 64 elements | 37.452 ms | 1.941 ms | -94.82% | 857,349,023 | 79,869,254 | -90.68% |
| Mixed Boolean list, 4,096 retained | 59.591 ms | 2.457 ms | -95.88% | 1,326,624,082 | 97,226,733 | -92.67% |
| Integer list with extrema, 64 elements | 24.546 ms | 7.668 ms | -68.76% | 618,132,294 | 206,361,948 | -66.62% |
| Integer list with extrema, 4,096 retained | 39.073 ms | 12.395 ms | -68.28% | 962,653,443 | 310,201,705 | -67.78% |
| Integer vector with extrema, 64 elements | 24.154 ms | 7.717 ms | -68.05% | 618,355,657 | 207,760,869 | -66.40% |
| Integer vector with extrema, 4,096 retained | 39.431 ms | 12.538 ms | -68.20% | 962,128,563 | 312,095,483 | -67.56% |
| Integer matrix with extrema, 64 elements | 24.936 ms | 8.068 ms | -67.65% | 624,846,846 | 216,775,401 | -65.31% |
| Integer matrix with extrema, 4,096 retained | 39.122 ms | 12.922 ms | -66.97% | 969,593,820 | 322,006,702 | -66.79% |

One-element string, Boolean, integer-list, and integer-vector instruction
counts also improved by 65–70%. The ordinary benchmark had no losing empty,
singleton, one-row, or one-column case. All characterized control/candidate
outputs had identical hashes, checksums, and logical byte counts. Every run
made exactly one managed allocation per result, candidate capacity equaled
logical length, and retained peak footprint was neutral or lower.

### Validation and review

| Gate | Result |
| --- | --- |
| Focused collection behavior | 8/8 passed |
| Focused ASan/UBSan behavior | 8/8 passed |
| Runtime gate | 4,469/4,469 passed |
| Leak gate | passed |
| C static analysis | passed; five pre-existing `core.StackAddressEscape` warnings |
| Independent code review | approved; no findings |
| Final optimizer review | accepted all four families |

The production C diff is `+162/-63` (net `+99`). The increase is the explicit
checked sizing and direct-fill passes for four serializers; it introduces no
builder, cache, growth scheme, or representation change. The dedicated
benchmark is 419 lines, the behavior test is 68 lines, and benchmark
documentation adds 24 lines.

## Fast Feedback Loop

During implementation:

```bash
# Rebuild only the cached optimized runtime object after runtime.c changes.
make prepare-blorp-cli-runtime

# Run the new benchmark's short characterization mode.
benchmarks/runtime_managed_buffer_copy_profile --quick

# Run the focused behavior suite.
bin/blorp test blorp/test/runtime/collections/test_collection_to_string.brp
```

If the final test filename differs, keep it narrowly owned by collection
serialization and record the exact command here.

Before review:

```bash
scripts/test runtime
scripts/test leak
bin/blorp test --sanitize blorp/test/runtime/collections/test_collection_to_string.brp
make c-static-analysis
```

Inspect the changed functions directly and confirm that each accepted path has
one final managed allocation, no raw result buffer, and no full-result final
`memcpy`.

## Performance Acceptance Gate

An accepted family must satisfy all of the following on paired optimized
builds:

- fewer retired instructions for medium and large inputs;
- a clear improvement (target at least 3%) on at least one representative
  medium or large workload;
- no repeatable latency or instruction regression greater than 2% on small
  representative inputs;
- no increase in returned capacity bytes for the required exact-size paths;
- no peak-memory regression in the retained-results workload; and
- byte-identical output and an identical observable checksum.

Wall time alone is not sufficient to accept or reject a small runtime change.
Retired instructions and deterministic capacity/allocation facts are the
primary signals. Report noisy or mixed wall-time results honestly.

If only the string-list path meets the gate, merge only that path. The issue is
not a mandate to keep a uniform but slower abstraction.

## Correctness And Safety Acceptance Criteria

- [x] Control behavior tests are written and pass before production changes.
- [x] A reproducible `-O2` benchmark exists and keeps setup/compilation outside
      the measured interval.
- [x] Every accepted function allocates its final managed result once and
      writes directly into its trailing storage.
- [x] No managed `String`, `Bytes`, or `blorp_Object` is passed to raw
      `realloc`.
- [x] All size arithmetic is checked and every `size_t`-to-`long` conversion is
      guarded by `LONG_MAX`.
- [x] Returned `len`, `capacity`, and String NUL termination are correct.
- [x] Empty, null, extrema, Unicode, and embedded-NUL cases retain their current
      output.
- [x] One- and two-dimensional integer vector output remains correct if the
      integer family is accepted.
- [x] Runtime, leak, focused sanitizer, and C static-analysis gates pass.
- [x] A test-runner review reports the exact commands, pass counts, and any
      failures.
- [x] A code review finds no ownership, bounds, formatting, or portability
      defect.
- [x] A final optimizer review validates the before/after evidence and rejects
      any family whose speedup comes from retained capacity or changed output.
- [x] The benchmark leaves no generated or temporary C artifacts in the
      repository.

## Code-Quality Acceptance Criteria

- [x] The production diff is net-negative or narrowly net-positive, with every
      new helper reused by more than one accepted path.
- [x] Fixed text is copied directly rather than routed through `snprintf`.
- [x] There is no general builder type, cache, invalidation mechanism, or
      representation change.
- [x] Comments explain only non-obvious ownership, overflow, or compatibility
      constraints.
- [x] Deferred sites remain unchanged and are not partially migrated.
- [x] Review distinguishes logical size, allocation capacity, peak live bytes,
      and retired instructions rather than calling all four “memory savings.”

## Required Review

Before commit:

1. A runtime/C review must verify ARC allocation boundaries, overflow handling,
   NUL termination, capacity invariants, and exact output compatibility.
2. A test review must report the focused and broad runtime/leak/sanitizer
   results.
3. A performance review must reproduce the paired benchmark and verify that no
   accepted family loses retired instructions or retained-memory behavior.
4. The final issue update must list accepted functions, rejected prototypes,
   production versus benchmark/test diffstat, and the exact measurements.

## Expected Result

The high-confidence string and Boolean list paths should each remove one raw
allocation/free pair and one full-result copy per conversion while preserving
one exact managed allocation. The practical speedup will depend on element
size and collection length; no whole-program claim should be made from this
micro-optimization.

The integer family may or may not be worthwhile because exact sizing repeats
digit work. This issue is successful if it establishes the harness, lands the
clear direct-construction wins, and rejects marginal variants promptly. It is
not necessary—or desirable—to erase every temporary buffer in `runtime.c`.

## Follow-Up Boundary

Any later work on streamed file reads, process capture, regex replacement, or
float serializers must answer a different design question: how to grow or
pre-size a managed value without increasing repeated copies or retained
capacity. Such work requires its own issue and measurements. It must not be
smuggled into this mechanical first tranche.
