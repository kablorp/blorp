# List `append`, `set` and `concat` intrinsics (ML part 1)

The pilot's temporary `list` module gains three fresh-result update wrappers,
threaded through the pipeline exactly as `repeat`, `length` and `get` are:

```blorp
pure func append[T](values: List[T], value: T) -> List[T]:
    builtin("list.append")
pure func set[T](values: List[T], index: Int, value: T) -> List[T]:
    builtin("list.set")
pure func concat[T](left: List[T], right: List[T]) -> List[T]:
    builtin("list.concat")
```

The List literal (part 2), removal, and unique-root in-place reuse (deferred to
M8) are not part of this increment.

## Provenance

| Artifact | Identity |
| --- | --- |
| Source | `origin/main` at `6c8c9b2b8` (rebased from `4960e16b9` after lexer interning), branch `blorp2/list-intrinsics` |
| Host `bin/blorp` (FRESH) | `328170d6089f389f9f2a16e83eaab62142dffae8db77dd3dab176e9027fcad27` |
| Baseline pilot (built from `6c8c9b2b8`) | `a0dd7b49e2c207a2022b397be180164432d4f5ab96fc81c5a2e44dfd01309ea0` |
| Baseline generated host C | `ac60b8600843ae270ad6e670b47b0e7a211854a0256bdf9f973ebc5254b179db` |
| Candidate generated host C | `ad415cf6798c56cd3a2121cb0cdec546057d13c8babce2d583249e5e77d23b80` |
| Candidate pilot | `9fc88a7001b80136f534de986c18069fca46de4da9167150f2c2c41c31f363f5` |

Both pilots are `make -C blorp_2 test-compiler` builds: Apple clang 21,
`-O0 -DBLORP_MEMORY_DIAGNOSTICS=1 -lm -lpthread`. Fixture C links with
`-std=c11 -Wall -Wextra -Werror -pedantic -O0` (plus ASan/UBSan in the e2e
harness). The baseline pilot is measured against a frozen copy of the baseline
temp library, since it cannot parse the new builtin labels.

## The three contracts

**Checking.** `written_operation` takes E from the header's first `List[E]`
parameter (one `first_list_element` helper now serves `length`, `get` and the
three updates); `runtime_contract` is the sole authority for the shapes
`ListAppend(E): (List[E], E) -> List[E]`, `ListSet(E): (List[E], Int, E) ->
List[E]` and `ListConcat(E): (List[E], List[E]) -> List[E]`, all pure. A
mismatched header is rejected at its label with the operation-specific help
(`declare a pure function with List[E] and E parameters returning List[E]`, and
so on). Specialization substitutes E once; the verifier reads the same contract.

**Ownership.** Identical to `repeat`: every parameter is borrowed by the runtime
call (managed parameters as `BorrowedResult(ParameterBorrow)`, the `Int` index
unmanaged), the result is one owned List root, and the wrapper's return
transfers that owner. No acquisition or drop is inserted in the wrapper; the
runtime acquires each stored occurrence itself.

**Runtime.** Each helper borrows its inputs, allocates one fresh root of the
exact result length, publishes `length` only as slots are initialized, and
applies the element's stored-occurrence acquisition to every slot it stores,
surviving or replacement. Old roots keep every alias. `set` with a negative or
out-of-range index copies the input unchanged (the host's documented behaviour:
no panic, no `Option`); `append` and `concat` always produce the longer List.
`append` aborts only when `length` would exceed `INT64_MAX` or the allocation
would exceed `SIZE_MAX`; `concat` checks the combined length the same way; `set`
reuses a size the input already allocated. A helper is emitted only where its
operation is called, so programs that do not update Lists emit identical C.

## Semantics probe against the host

`scratchpad/ml/probe.brp` run with `bin/blorp run --no-format` (host
`standard_library/src/list.brp`):

```
append empty 1 [7]
append nonempty 3 [1, 2, 3]
set 0 3 [9, 2, 3]
set 2 3 [1, 2, 9]
set 3 (out) 3 [1, 2, 3]
set -1 (out) 3 [1, 2, 3]
set empty 0 (out) 0 []
concat empty left 2 [1, 2]
concat empty right 2 [1, 2]
concat both 4 [1, 2, 3, 4]
concat both empty 0 []
original after set 3 [1, 2, 3]
updated 3 [1, 42, 3]
```

The nine pilot fixtures below print the same lengths and elements for the same
operations on `Int`, a managed `Entry { number: Int, text: String }` and an
inline `Point { x: Int, y: Int }`.

## Generated C per element layout

Managed record element (`list/append_entries.brp`): one allocation, one copy
loop, one `blorp_record_dup_0` per stored occurrence including the appended
value.

```c
struct blorp_l_0_r0* blorp_list_append_0_r0(const struct blorp_l_0_r0 *values,blorp_r_0 value){
const uint64_t count=(uint64_t)values->length;
if(count>=(uint64_t)INT64_MAX||count>=(SIZE_MAX-sizeof(struct blorp_l_0_r0))/sizeof(blorp_r_0))abort();
struct blorp_l_0_r0* result=malloc(sizeof *result+(size_t)(count+1)*sizeof *result->values);if(!result)abort();
atomic_init(&result->references,1);result->length=0;
for(uint64_t index=0;index<count;index++){blorp_r_0 element=values->values[index];blorp_record_dup_0(element);result->values[index]=element;result->length++;}
blorp_r_0 element=value;blorp_record_dup_0(element);result->values[count]=element;result->length++;return result;}
```

Inline record element (`list/append_points.brp`): the same shape with no
ownership operation, because `Point` is stored by value.

```c
for(uint64_t index=0;index<count;index++){blorp_r_0 element=values->values[index];result->values[index]=element;result->length++;}
blorp_r_0 element=value;result->values[count]=element;result->length++;return result;}
```

`Int` element (`list/set_int.brp`, `list/concat_int.brp`):

```c
struct blorp_l_0_i* blorp_list_set_0_i(const struct blorp_l_0_i *values,int64_t index,int64_t value){
const uint64_t count=(uint64_t)values->length;
struct blorp_l_0_i* result=malloc(sizeof *result+(size_t)count*sizeof *result->values);if(!result)abort();
atomic_init(&result->references,1);result->length=0;
for(uint64_t slot=0;slot<count;slot++){int64_t element=(index>=0&&(uint64_t)index==slot)?value:values->values[slot];result->values[slot]=element;result->length++;}
return result;}
struct blorp_l_0_i* blorp_list_concat_0_i(const struct blorp_l_0_i *left,const struct blorp_l_0_i *right){
const uint64_t first=(uint64_t)left->length;const uint64_t second=(uint64_t)right->length;
if(second>(uint64_t)INT64_MAX-first||first+second>(SIZE_MAX-sizeof(struct blorp_l_0_i))/sizeof(int64_t))abort();
struct blorp_l_0_i* result=malloc(sizeof *result+(size_t)(first+second)*sizeof *result->values);if(!result)abort();
atomic_init(&result->references,1);result->length=0;
for(uint64_t index=0;index<first;index++){int64_t element=left->values[index];result->values[index]=element;result->length++;}
for(uint64_t index=0;index<second;index++){int64_t element=right->values[index];result->values[first+index]=element;result->length++;}
return result;}
```

Line breaks are added here; the emitted C is one line per helper, as before.
A nested element (`List[List[Int]]`) acquires with `blorp_list_dup_0_i`.

## Fixture ceilings

Pilot cost of compiling each new fixture (allocations / retired instructions,
`-O0` pilot with memory diagnostics), and the ceiling set from it:

| Fixture | Exact stdout | Measured | Ceiling |
| --- | --- | ---: | ---: |
| `list/append_int.brp` | `0 -1 -1 1 7 -1 3 7 9` | 17,217 / 74.5M | 19,800 / 88M |
| `list/append_entries.brp` | `2 42 missing 3 42 42 4 42 42` | 18,948 / 78.8M | 21,800 / 93M |
| `list/append_points.brp` | `0 -1 -1 1 1 -1 3 1 6` | 21,245 / 83.9M | 24,400 / 99M |
| `list/set_int.brp` | `3 1 1 3 7 1 3 1 9 3 1 1 3 1 1 0 -1 -1` | 20,097 / 81.1M | 23,100 / 96M |
| `list/set_entries.brp` | `2 42 42 2 42 7 2 42 42 2 42 42` | 20,376 / 82.1M | 23,400 / 97M |
| `list/set_points.brp` | `2 1 1 2 3 1 2 1 1` | 20,721 / 82.6M | 23,800 / 97M |
| `list/concat_int.brp` | `2 1 -1 2 1 -1 5 1 2 0 -1 -1` | 18,821 / 78.1M | 21,600 / 92M |
| `list/concat_entries.brp` | `3 42 7 4 42 42 2 42 missing` | 20,578 / 82.6M | 23,700 / 97M |
| `list/concat_points.brp` | `3 1 4 2 3 -1 1 1 -1` | 21,839 / 85.1M | 25,100 / 100M |

Each stdout value is one line. Ceilings carry about 15% allocation and 18%
instruction headroom.

## Whole-pilot cost on existing inputs, and one raised ceiling

Every pilot compile parses and checks the complete temp library. Adding three
generic wrappers costs a constant number of pilot allocations on every input:

| Input | Baseline pilot + baseline library | Candidate pilot + new library | Change |
| --- | ---: | ---: | ---: |
| `syntax/continuation.brp` | 9,206 | 10,090 | +884 |
| `syntax/pipe_string.brp` | 9,243 | 10,127 | +884 |
| `syntax/import_block.brp` | 8,570 | 9,454 | +884 |
| `return/zero.brp` | 7,341 | 8,225 | +884 |
| `list/entries.brp` | 16,629 | 17,517 | +888 |
| `list/nested.brp` | 15,266 | 16,161 | +895 |
| `record/update/aliases.brp` | 13,381 | 14,271 | +890 |

Decomposition on `return/zero.brp`:

| Pilot | Library | Allocations |
| --- | --- | ---: |
| baseline | baseline | 7,341 |
| candidate | baseline | 7,341 |
| candidate | baseline + `append` only | 7,619 |
| baseline | baseline without `get` | 7,011 |
| candidate | new (three wrappers) | 8,225 |

The candidate pilot with the old library costs exactly the baseline, so the
compiler changes add no work to inputs without List updates; the new
emission inventory contributes nothing when no update is called. One generic
builtin wrapper costs 278-330 pilot allocations per compile in both pilots.
The increase is the pilot's per-declaration library cost, not this design's;
checking only referenced library declarations is the bounded follow-up that
removes it. The `syntax` group's shared ceiling moves from 10,000 to 11,500
allocations (its four tightest fixtures measured 9,454-10,127); its 65M
instruction ceiling is unchanged (at most 88.7% used).

## Identity on existing fixtures

`scratchpad/ml/identity.sh` compiles every e2e fixture with each pilot,
builds the C with the strict flags above and runs it with no arguments. For
all **338** pre-existing fixtures the generated C, compile exit status, stdout
and stderr, and the native exit status, stdout and stderr are byte-identical
between the baseline and candidate pilots (`diff -r` reports only the nine
new fixture directories), both before and after the rebase onto `6c8c9b2b8`. 303 of the 338 are accepted and run; 35 are
rejection fixtures.

## Tests

- Checker (`test/unit/test_check/test_list_updates.brp`, 14 callbacks): the
  three concrete and three generic headers are admitted with their real E;
  wrong arity, a non-List first parameter, a different return element, an
  impure header, a `String` index, a value of another element type, and sides
  with different elements are rejected with the exact message, help and label
  span.
- Ownership (`test_own/test_generic_list_phases.brp`, +4): each wrapper's
  operation list is exactly its borrowed parameters plus one owned root
  transferred by the return, with no acquisition; the contracts carry a
  structured E in every position.
- Verifier (`test_verify/test_list_membership.brp`, +8): raw ownership IR with
  an unknown record E is rejected before argument checks for all three; valid
  `Int` contracts with one drop verify; a missing argument and a `List` index
  are rejected at the definition span.
- Runtime fragments and emission (`test_unit/test_runtime/test_list.brp`,
  +7): growth and combined-length checks, one `malloc`, acquisition per stored
  slot, `set`'s single replacement, no ownership operations for unmanaged E,
  helpers present only where called (including nested `1_i`), absent from
  repeat-only programs.
- Native (`test/runtime/fixtures/generic_list_test.c`, +9 cases through the
  existing allocator observer): `Int`, empty, mortal `String`, nested List,
  managed `Entry` in and out of range, inline record, `Entry` concat and empty
  concat, each checking reference counts, aliases, allocation counts and that
  every object is freed exactly once.
- E2e: the nine fixtures above under ASan/UBSan.

Oracles were proven before the implementation compiled (the checker and
verifier suites failed on the unknown operations; two verifier spans and
message prefixes were corrected from the probe output in the same session).

Final gate `env BLORP_2_INSTRUCTION_CHECK=required make -C blorp_2 test`:
exit 0 with no failures; **2,422 unit/runtime/grammar callbacks and 352 e2e cases pass** (the harness's nested `[PASS]` lines are not additional cases). Logs: `scratchpad/ml/logs/full-gate-rebased.log` (run after the rebase onto `6c8c9b2b8`).

## Size

Production: `+293/-35` lines across `src` (`emit.brp` +143/-14 for the
update-helper inventory and the shared `element_fragments`; `runtime/list.brp`
+74/-4 for the three helpers and the factored root allocation; the rest is
variant threading) and +6 in the temp library. Tests: +660 lines in existing
suites and C cases, +220 in the new checker suite, +206 in nine fixtures.
Documentation: +48/-27 across README, LIBRARY_PARITY, ROADMAP and the grammar.

## Retained scratch

`/private/tmp/claude-501/-Users-keithphilpott-CLionProjects-blorp/6797a039-3cd3-4a6a-9bfd-d635448ccc1f/scratchpad/ml/`:
`probe.brp`/`probe.out` (host semantics), `identity.sh` with
`identity-baseline2/` and `identity-candidate2/` (post-rebase; the pre-rebase
pair is retained too), `baseline2/` (pilot, C, frozen library), `smoke/` (generated C of the nine fixtures), `alloc/` and `logs/`.
