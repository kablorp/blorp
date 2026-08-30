# Make `List.concat` COW-Capable

## Summary

Change the existing `List.concat` implementation so it can consume and reuse a
unique left-hand list allocation instead of always allocating a third list and
copying both inputs.

The public Blorp API remains unchanged:

```blorp
pure func concat[T](left: List[T], right: List[T]) -> List[T]
```

The implementation should lower `concat` to one ownership-aware runtime
intrinsic:

```blorp
list_concat_owned(left, right)
```

That intrinsic consumes one owned reference to each operand and returns one
owned list. It should:

- return the right allocation when the left list is empty;
- return the left allocation when the right list is empty;
- append into the left allocation when it is unique and has enough capacity;
- grow the left allocation geometrically when it is unique but too small;
- copy the left list first when another live value shares it;
- preserve pointer-backed managed elements and inline-value layouts;
- remain correct when both operands refer to the same list allocation.

## Why This Matters

The source API already presents `concat` as an ordinary value-semantic list
operation. Its synthesized Core implementation does not currently take
advantage of Blorp's COW ownership model.

The current implementation in
`blorp/src/compiler/stage_09_core/synth_list.brp`, function
`synthesize_concat`, always performs this shape of work:

```text
evaluate left
evaluate right
read both lengths
allocate an exact-sized result
copy every left element into the result
copy every right element into the result
set the result length
```

Consequences:

1. Every concat allocates a new list, even when the left list is dead, unique,
   and already has spare capacity.
2. Every concat copies the complete left prefix. A chain such as
   `a.concat(b).concat(c)` repeatedly copies earlier elements.
3. Pointer-backed lists retain elements while copying and release the old
   owners later, adding ARC traffic that is unnecessary when storage can be
   reused.
4. Compiler code cannot rely on `concat` as an efficient way to combine
   incrementally accumulated results, which encourages bespoke `append_*`
   walkers and mutable accumulation helpers.

This issue does not make every concat tree linear. It removes the unnecessary
allocation and left-prefix copy when normal COW conditions permit reuse. It is
the appropriate runtime/compiler foundation before considering concat-tree
fusion or collection builders.

## Current Implementation Map

| Responsibility | Current location |
| --- | --- |
| Public `concat` and `Addable` implementation | `std/list.brp`, around `pure func concat` |
| Core synthesis and builtin dispatch | `blorp/src/compiler/stage_09_core/synth_list.brp`, `synthesize_concat` and the `name == "concat"` branch |
| Intrinsic ownership contracts | `blorp/src/compiler/stage_09_core/ownership.brp`, `intrinsic_contract` |
| Runtime list representation and COW helpers | `blorp/src/lib/runtime/native/runtime.c`, `blorp_list_copy_with_capacity`, `blorp_list_copy_span_uninit`, and `blorp_list_ensure_capacity` |
| Runtime declarations embedded into generated C | `blorp/src/lib/runtime/native/runtime_decl.c`, list operation declarations |
| Intrinsic enum, registry, and C rendering | `blorp/src/compiler/stage_10_backend/intrinsic_renderer.brp` |
| Intrinsic renderer tests | `blorp/test/compiler/stage_10_backend/test_codegen_intrinsic_renderer.brp` |
| List synthesis tests | `blorp/test/compiler/stage_09_core/test_core_synth_list.brp` |
| Ownership contract tests | `blorp/test/compiler/stage_09_core/test_core_ownership.brp` |
| Perceus ownership tests | `blorp/test/compiler/stage_09_core/test_core_perceus.brp` |
| Runtime COW behavior tests | `std/test/list/test_list_cow.brp` |
| Managed and inline element concat tests | `std/test/list/test_list_reverse_concat_bulk.brp` |
| Existing concat cleanup test | `std/test/list/test_list_cleanup_ir.brp` |
| Generated-C audit fixtures | `blorp/test/compiler/pipeline/codegen_audit/should_pass/` |

Line numbers are intentionally omitted because the compiler sources are being
actively reorganized. Locate the named declarations rather than relying on a
stale line number.

## Scope

### Required

- Add a two-argument `list_concat_owned` Core/runtime intrinsic.
- Give both arguments `CowConsumeArg` ownership contracts.
- Replace the synthesized allocate-and-copy Core tree with the intrinsic.
- Reuse/grow the left allocation through the existing list layout and COW
  helpers.
- Add focused Core, renderer, ownership, runtime, allocation, leak, and
  sanitizer coverage.
- Inspect generated C and prove that source `concat` emits the new runtime
  call.

### Not In Scope

- Changing the public `List.concat` name or signature.
- Changing list `+` syntax or its `Addable` implementation.
- Rewriting compiler call sites or `append_*` helpers.
- Stealing or splicing the right list's backing storage.
- Moving managed elements out of a unique right list without retain/release.
- Flattening or fusing arbitrary concat expression trees.
- Introducing ropes, builders, or a new list representation.
- Generalizing the work into a collection framework.

Do not expand this issue to include those changes.

## Semantic and Ownership Contract

The new intrinsic has this logical contract:

```text
list_concat_owned(left: owned List[T], right: owned List[T])
    -> owned List[T]
```

In `blorp/src/compiler/stage_09_core/ownership.brp`, add an explicit intrinsic
contract:

```blorp
"list_concat_owned":
	fixed_contract(
		arity,
		[CowConsumeArg, CowConsumeArg],
		ReturnOwned,
	)
```

Both arguments must be `CowConsumeArg`, not `BorrowArg`, `ConsumeArg`, or
`TransferArg`:

- The runtime consumes one owner for each operand.
- Perceus retains an operand before the call when that source value remains
  live afterward.
- A dead unique left operand can reach the runtime with a unique reference and
  be mutated in place.
- `CowConsumeArg` communicates that the callee may either reuse or replace the
  consumed allocation.

Do not rely only on `consuming_handoff_intrinsic` in
`blorp/src/compiler/stage_10_backend/emit.brp`. This operation consumes two
arguments, and its complete contract belongs in `intrinsic_contract`.

## TDD Sequence

Implement the tests and production changes in this order. Each test should be
observed failing for the intended reason before the corresponding production
change is made.

### 1. Add the ownership contract test

In `blorp/test/compiler/stage_09_core/test_core_ownership.brp`, extend the intrinsic
contract family test with:

```blorp
check_contract(
	intrinsic_contract("list_concat_owned", 2),
	{
		args = [CowConsumeArg, CowConsumeArg],
		result = ReturnOwned,
	},
)
```

Use the exact local `check_contract` signature and surrounding assertion style.
Before implementation, this should fail because the intrinsic has no explicit
contract.

### 2. Add a synthesis-shape test

In `blorp/test/compiler/stage_09_core/test_core_synth_list.brp`, use the existing
`synthesized_named` and `contains_intrinsic` helpers to add a focused test:

```blorp
private pure func test_concat_uses_owned_cow_intrinsic() -> Bool:
	match synthesized_named(
		"concat",
		[LIST_INT_TYPE, LIST_INT_TYPE],
		LIST_INT_TYPE,
	):
		Some(body):
			(
				contains_intrinsic(body, "list_concat_owned")
				and not contains_intrinsic(body, "list_alloc")
				and not contains_intrinsic(body, "list_copy_span_uninit")
				and not contains_intrinsic(body, "list_set_len")
			)
		None:
			False
```

Add the test to that file's `TestSuite`. Before implementation, it should fail
because concat contains the old allocation and span-copy tree.

### 3. Add intrinsic renderer tests

In `blorp/test/compiler/stage_10_backend/test_codegen_intrinsic_renderer.brp`:

- import the new `TwoArgIntrinsic` variant;
- assert that `parse_intrinsic("list_concat_owned")` has arity 2;
- assert its exact C rendering;
- increment `EXPECTED_INTRINSIC_COUNT` from 151 to 152.

Expected rendering:

```blorp
render_intrinsic("list_concat_owned", ["left", "right"])
	== Ok(
		"blorp_list_concat_owned((blorp_List*)left, (blorp_List*)right)",
	)
```

Follow the test file's existing formatting and `Result` assertion patterns.

### 4. Add runtime behavior and allocation tests

Extend `std/test/list/test_list_cow.brp` with all of the following cases:

1. Unique left list with spare capacity is reused with zero allocations during
   the concat operation.
2. Shared left list is not modified, its alias remains valid, and concat
   allocates a replacement.
3. `values.concat(values)` duplicates all values correctly and remains valid
   when `values` is read after the concat.
4. Empty-left concat returns the right values without allocating.
5. Empty-right concat returns the left values without allocating.
6. Chained concat remains correct.

Allocation tests must construct all inputs before resetting memory statistics,
and must capture statistics immediately after concat, before constructing an
expected list literal or performing unrelated allocating work:

```blorp
func test_concat_reuses_unique_left_capacity() -> Bool:
	var left: List[Int] = [1, 2, 3]
	left = left.append(4)
	right: List[Int] = [5]

	reset_mem_stats()
	joined: List[Int] = left.concat(right)
	stats: MemStats = get_mem_stats()

	(
		stats.total_allocations == 0
		and joined.length() == 5
		and joined.get(0) == Some(1)
		and joined.get(4) == Some(5)
	)
```

Verify that the append actually leaves spare capacity under the current list
growth policy. If it does not, prepare the list with enough appends to create
spare capacity. Do not weaken this into a vague allocation ceiling.

For the shared case, create the alias before resetting statistics:

```blorp
left: List[Int] = [1, 2, 3]
alias: List[Int] = left
right: List[Int] = [4]

reset_mem_stats()
joined: List[Int] = left.concat(right)
stats: MemStats = get_mem_stats()

-- Assert exactly one replacement allocation, unchanged left/alias values,
-- and joined values [1, 2, 3, 4].
```

Retain the existing managed-element and inline-struct tests in
`std/test/list/test_list_reverse_concat_bulk.brp`. Add cases there only
if the existing assertions do not exercise both sides of concat.

### 5. Add the repeated-owner Perceus regression

In `blorp/test/compiler/stage_09_core/test_core_perceus.brp`, add a focused ownership
regression where the same list value supplies both consumed arguments to
`list_concat_owned`.

Copy the construction and assertion style from the existing `CowConsumeArg`
intrinsic tests. The required invariant is:

- the generated ownership graph supplies two owned references to the call;
- it does not consume one reference twice;
- if the original value remains live after the call, it receives the additional
  retain required for that later use.

This test protects `xs.concat(xs)`, which is the easiest aliasing case to turn
into a use-after-free or double release.

## Implementation Steps

### Step 1: Add the runtime declaration

In `blorp/src/lib/runtime/native/runtime_decl.c`, beside the other list COW declarations, add:

```c
blorp_List* blorp_list_concat_owned(blorp_List* left, blorp_List* right);
```

### Step 2: Implement the runtime operation

In `blorp/src/lib/runtime/native/runtime.c`, place the implementation beside
`blorp_list_reverse_owned` and `blorp_list_ensure_capacity`.

Use existing helpers rather than duplicating list layout logic:

- `blorp_is_unique`
- `blorp_list_ensure_capacity`
- `blorp_list_copy_with_capacity`
- `blorp_list_copy_span_uninit`
- `blorp_release`

The implementation should have this structure:

```c
// Consume one owned reference to each operand and return one owned list.
blorp_List* blorp_list_concat_owned(blorp_List* left, blorp_List* right) {
    if (!left) return right ? right : blorp_list_new(0);
    if (!right) return left;

    if (left->len == 0) {
        blorp_release(left);
        return right;
    }
    if (right->len == 0) {
        blorp_release(right);
        return left;
    }

    long left_len = left->len;
    long right_len = right->len;
    if (right_len > LONG_MAX - left_len) {
        blorp_fatal_invalid_runtime_length("List", left_len, right_len);
    }
    long total_len = left_len + right_len;

    left = blorp_list_ensure_capacity(left, total_len);
    blorp_list_copy_span_uninit(
        left,
        left_len,
        right,
        0,
        right_len
    );
    left->len = total_len;
    blorp_release(right);
    return left;
}
```

Treat this as an implementation outline, then match local C formatting.

#### Why the copy-before-release order is required

`blorp_list_copy_span_uninit` retains copied elements for pointer-backed owning
lists. The runtime must copy from `right` before releasing the consumed right
owner. Releasing first would make managed source elements unavailable.

#### Why `left == right` is valid

The intrinsic consumes two owned arguments. When both arguments point to the
same allocation, ownership lowering must materialize two owned references.
Therefore the allocation is shared when `blorp_list_ensure_capacity` examines
it:

1. capacity growth copies the left elements and consumes one owner;
2. the second owner keeps `right` alive;
3. the right span is copied into the result;
4. releasing `right` consumes the second owner.

Do not add a name-based or pointer-based frontend special case for this. Prove
the ownership behavior in the Perceus test and under ASan.

#### Capacity-overflow requirement

The `left_len + right_len` check above is mandatory. Also inspect
`blorp_list_ensure_capacity`: its current geometric `new_cap *= 2` loop must not
wrap when `min_cap` is very large. If it is not already guarded on the target
branch, harden only that loop:

```c
while (new_cap < min_cap) {
    if (new_cap > LONG_MAX / 2) {
        new_cap = min_cap;
        break;
    }
    new_cap *= 2;
}
```

This is part of making the new runtime path correct, not a general allocation
refactor.

### Step 3: Register the ownership contract

Add the exact contract shown above to
`blorp/src/compiler/stage_09_core/ownership.brp`.

No backend ownership special case should be needed. The normal emitter obtains
consumed argument indices from this contract. If implementation appears to
require a separate emitter exception, stop and determine why the contract is
not being honored.

### Step 4: Add the backend intrinsic

In `blorp/src/compiler/stage_10_backend/intrinsic_renderer.brp`:

1. Add `ListConcatOwned` to `TwoArgIntrinsic`.
2. Add this entry to the intrinsic specification list near the other list
   intrinsics:

   ```blorp
   intrinsic_spec("list_concat_owned", TwoArgs(ListConcatOwned)),
   ```

3. Add this `TwoArgIntrinsic` renderer branch:

   ```blorp
   ListConcatOwned:
	   "blorp_list_concat_owned((blorp_List*)${left}, (blorp_List*)${right})"
   ```

Use the actual two-argument renderer variable names in that function. Do not
add a new prepared-list renderer abstraction; `list_reverse_owned` is the
relevant direct-intrinsic precedent.

### Step 5: Replace concat synthesis

In `blorp/src/compiler/stage_09_core/synth_list.brp`, replace the body of
`synthesize_concat` with a single intrinsic call:

```blorp
private pure func synthesize_concat(
	list_type: CoreType,
	left: CoreExpr,
	right: CoreExpr,
) -> CoreExpr:
	intrinsic_call(
		"list_concat_owned",
		[left, right],
		list_type,
	)
```

Keep the existing dispatch guard that requires:

- two parameters;
- a concrete list element type;
- matching left, right, and return list types.

Delete the old synthesized length reads, `list_alloc`, two
`list_copy_span_uninit` calls, and `list_set_len` tree. Do not keep it as a
fallback.

## Runtime Invariants to Verify

| Case | Expected behavior |
| --- | --- |
| Unique left, enough capacity | Return the same left allocation; zero allocation |
| Unique left, insufficient capacity | Allocate one geometrically grown replacement and consume old left |
| Shared left | Allocate one replacement; preserve every other left alias |
| Empty left | Consume empty left and return right |
| Empty right | Consume empty right and return left |
| Same allocation passed twice | Duplicate values without UAF, double release, or leaked owner |
| Pointer-backed managed elements | Retain copied right elements before consuming right |
| Inline structs/primitives | Copy bytes with the existing stride/layout rules |
| Source value used after concat | Perceus retains it before the consuming call |

Do not infer element layout from type names or C symbol spelling. Monomorphic
list synthesis already guarantees matching `List[T]` operands, and the runtime
helpers carry the concrete storage mode, element size, and release function.

## Generated-C Verification

Add a small source fixture under
`blorp/test/compiler/pipeline/codegen_audit/should_pass/`, following the directory's
existing directive syntax:

```blorp
import:
	list: List, concat


pure func join(left: List[Int], right: List[Int]) -> List[Int]:
	left.concat(right)


func main() -> Int:
	join([1, 2], [3]).length()
```

The fixture should require the generated function to contain:

```c
blorp_list_concat_owned(
```

Also manually compile an equivalent temporary source and inspect its C:

```bash
./blorp compile --no-format -o /tmp/blorp-list-concat-cow.c \
  /tmp/blorp-list-concat-cow.brp
rg -n "blorp_list_concat_owned|list_copy_span_uninit" \
  /tmp/blorp-list-concat-cow.c
```

The source-level concat function should use one
`blorp_list_concat_owned(...)` call. Do not assert that
`blorp_list_copy_span_uninit` is absent from the entire generated C file,
because the embedded runtime itself legitimately defines or uses that helper.
The Core synthesis test is the authoritative assertion that the old inline
tree is gone.

Delete the temporary generated C after inspection.

## Performance Measurement

Correctness tests are not enough to claim that this is faster. Add a focused
allocation contract, patterned after the existing executable benchmark
contracts in `benchmarks/`:

- Blorp fixture:
  `benchmarks/blorp/profiles/list_concat_cow_allocations.brp`
- Shell contract:
  `benchmarks/list_concat_cow_allocations`

Measure at least:

1. one concat with unique left and spare capacity;
2. one concat with shared left;
3. a chain of concats over prebuilt small chunks.

Construct inputs before resetting statistics. Emit a stable checksum so the
result cannot be optimized away. Report iterations, result, allocations,
releases, current objects, and bytes allocated in the same machine-readable
style as existing benchmark contracts.

Expected allocation changes for the concat operation itself:

| Scenario | Current synthesis | New intrinsic |
| --- | ---: | ---: |
| Unique left with spare capacity | 1 | 0 |
| Unique left requiring growth | 1 exact result | 1 geometrically grown result |
| Shared left | 1 | 1 |

The chained benchmark should improve when geometric spare capacity can be
reused, but do not require a linear-allocation claim for arbitrary concat
trees. Record before/after output under `benchmarks/results/` if the issue's
completion report makes a performance claim.

## Test Commands

Run the narrow tests first:

```bash
make
./blorp test blorp/test/compiler/stage_09_core/test_core_ownership.brp
./blorp test blorp/test/compiler/stage_09_core/test_core_synth_list.brp
./blorp test blorp/test/compiler/stage_10_backend/test_codegen_intrinsic_renderer.brp
./blorp test blorp/test/compiler/stage_09_core/test_core_perceus.brp
./blorp test std/test/list/test_list_cow.brp
./blorp test std/test/list/test_list_reverse_concat_bulk.brp
./blorp test std/test/list/test_list_cleanup_ir.brp
```

Run the aliasing and managed-element tests under the sanitizer and leak checker:

```bash
./blorp test --sanitize --timeout 180 std/test/list/test_list_cow.brp
./blorp test --sanitize --timeout 180 \
  std/test/list/test_list_reverse_concat_bulk.brp
./blorp test --leak-check --timeout 180 std/test/list/test_list_cow.brp
./blorp test --leak-check --timeout 180 \
  std/test/list/test_list_reverse_concat_bulk.brp
```

Then run the relevant gates:

```bash
scripts/test compiler-blorp
scripts/test compiler-core-sanitize
scripts/test runtime
scripts/test leak
blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh ./blorp
make quality
```

Run the new allocation contract before and after the implementation and retain
the output in the completion report.

## Common Failure Modes

### Releasing `right` before copying

This causes use-after-free for managed right-hand elements. Copy first, then
release the consumed owner.

### Borrowing either argument in the ownership contract

This prevents reliable in-place reuse or makes the runtime release an owner it
does not possess. Both operands are consumed.

### Assuming two source arguments cannot alias

`xs.concat(xs)` is valid source code. Test it directly under Perceus, ASan, and
the leak checker.

### Mutating a shared left list

All existing aliases must retain their original contents. Reuse only after the
normal uniqueness check.

### Losing element release metadata

Pointer-backed lists use `elem_release`; inline lists use `storage_mode` and
`elem_size`. Reuse existing copy/capacity helpers so this metadata remains
coherent.

### Measuring fixture allocations instead of concat allocations

Create operands before `reset_mem_stats()` and capture `get_mem_stats()` before
creating expected values or performing unrelated work.

### Overengineering right-hand transfer

The bounded implementation copies the borrowed span from the consumed right
owner and then releases it. Moving right elements without retains requires
clearing source slots and handling aliasing/layout cases. That is a separate
issue.

### Adding backend special cases

The standard intrinsic renderer and ownership contract should be sufficient.
If special-case emission seems necessary, stop and diagnose the missing generic
behavior instead of adding another parallel path.

## Acceptance Criteria

- [ ] The public `std/list.brp` API is unchanged.
- [ ] `concat` synthesis contains `list_concat_owned` and no longer constructs
      the old allocation/copy/set-length Core tree.
- [ ] `list_concat_owned` has ownership contract
      `[CowConsumeArg, CowConsumeArg] -> ReturnOwned`.
- [ ] The runtime consumes exactly one owner from each operand.
- [ ] Unique left with spare capacity performs zero allocations during concat.
- [ ] Shared left remains unchanged and concat returns correct values.
- [ ] `xs.concat(xs)` is correct and passes sanitizer/leak tests.
- [ ] Empty-left and empty-right cases avoid unnecessary allocation.
- [ ] Managed pointer elements retain/release correctly.
- [ ] Inline struct and primitive lists preserve values and layout.
- [ ] Generated C calls `blorp_list_concat_owned` directly.
- [ ] The focused allocation contract records an improvement for the reusable
      case.
- [ ] Focused compiler/runtime tests, sanitizer tests, leak tests, codegen
      audit, and `make quality` pass.

## Completion Report

The implementing agent should report:

1. the exact files changed;
2. the before/after Core shape for `concat`;
3. the generated-C call site;
4. before/after allocation measurements for all benchmark scenarios;
5. focused test counts and gate results;
6. any remaining limitation, especially concat-tree behavior or capacity
   growth behavior.
