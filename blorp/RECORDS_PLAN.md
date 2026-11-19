# Records by value

Plan revision 1, 2026-11-17, written against origin/main `7d4eb74be`. The
records-by-value pilot of 2026-11-12 measured the options; its report, scripts
and raw samples are in the main checkout's ignored
`build/pilots/2026-11-12/records-by-value/`.

**Status:** approved by Keith on 2026-11-16 (decisions below) and landed in
this change, after recursive unions and deep release. No seed rotation was
needed, because the pinned seed builds it. The compiler's own binary has
stored its records by value since the pin moved to `blorp-seed-7564157d33bf`
on 2026-11-18 (`AUDIT_CLEANUP_PLAN.md`, change 6).

## Problem

Every record that was not `fixed` was a counted heap cell, so building,
updating or returning one allocated, however small it was. Records caused
7.86 M of the 14.01 M allocations of a stage-2 self-compile (56%). `fixed`
was the only way to keep a record inline, and specialize read it as a
declared promise, so `record` and `fixed record` used two rules.

Storing every record that does not contain itself by value (the pilot's rule
A) removed 52% of the self-compile's allocations but cost 62% more
instructions and 136% more cycles, and the compiler overflowed its stack:
the compiler copies a record about ten times after building it, and a copy
of a value acquires every counted pointer the value holds.

## Keith's decisions, 2026-11-16

1. **Bound of one.** A record is a value (`InlineFields` or `ValueFields`)
   when a copy of it acquires at most one counted pointer; otherwise it stays
   a counted cell. No program then does more reference counting than before.
2. **One machinery for `record` and `fixed record`.** `fixed` only constrains
   fields, in Check. Specialize decides inline, value or counted from the
   field layouts, does not read `declaration.fixed` for records and asserts
   nothing about it.
3. **"Contains itself" is decided in Check.** Records join the classification
   the recursive-unions landing introduced for unions. A record that holds
   itself by value, through `Option`, unions, tuples or opaque types, is a
   counted cell.

## Design

**One fact, decided in Check, records first.** `declare_types` now builds
private `ResolvedRecord` rows beside `ResolvedUnion`, and
`validate_finite_declarations` publishes both kinds with `contains_itself`
from one walk (`contains_itself` in `check/declarations.brp`). A record's
walk follows its fields through every record, union, tuple and opaque type
they store by value, at their substituted arguments; Lists, Strings and
callables end it. Records are classified first, following every union
whether boxed or not, so a record's fact depends on no other. Unions are
classified second, and the walk takes a `RecordEdges` value saying which
records are pointers: a record that contains itself is a counted cell and
ends a union's walk, and every other record, and every tuple, is followed by
value. So `Node(Box[Tree])` with `record Box[T] { value: T }` makes `Tree`
contain itself, while `record Expr { form: Form }` with a `union Form` of
variants `Lit(Int)` and `Neg(Expr)` makes `Expr` a cell and leaves `Form`
inline, as before.

Every by-value cycle of instances still passes through a declaration that
contains itself (the recursive-unions argument, now with records on the
cycle as well), so verify's by-value cycle walk stays the independent proof.

**The bound stays out of Check.** Check treats every record that does not
contain itself as by-value storage, whatever specialize decides for it, so
union boxing and the finiteness checks remain declaration facts that no
layout changes. A union that reaches itself only through a record the bound
keeps counted is boxed although that record is already a pointer: one cell
more, never a wrong layout.

**Specialize's rule** (`record_representation`). A record that contains
itself, or a capture environment (a runtime closure may hold it as
`void*`; `sealed_record_layout` still stores an environment no closure holds
by value), is a counted cell. Any other record or tuple is classified by
what a copy costs in reference counting, a closed `CopyCost` of `NoCount`,
`OneCount` or `SeveralCounts`, summed over its fields:

- `Void`, numbers and inline records cost nothing;
- a String, a List, a callable, a boxed union and any record that is not
  inline cost one, since a value record holds one counted pointer and a
  counted record or boxed union is a pointer;
- an inline union costs its widest case, a case the sum of its payloads.

`NoCount` is inline, `OneCount` a value, `SeveralCounts` a counted cell.
The same `CopyCost` decides whether a union payload owns children, so the
fact has one source. `inline_record_field`, the three-way storage policy
(`InlineEligible`, `DeclaredInline`, `AlwaysManaged`) and the fixed-record
assertion are deleted.

A field whose layout is still in progress is a back reference: it lies on a
cycle of layouts, which passes through a pointer, so it costs at least one,
and counts as one. That is exact for a record (one that is not inline costs
a holder one) and a boxed union, but undercounts an owning union whose
widest case holds more. A record that holds such a union, directly or inside
another union's payload, would then be a value whose copy acquires two
counts, and which it was would depend on whether specialization met the
union or the record first (`union Shape: Pair(String, String) |
Many(List[Wrapper])` with `record Wrapper { shape: Shape }`).
`recount_value_records` removes the undercount: every record that read the
union's one count was published while the union was in progress, so when a
union that was referred back to completes, each value record published since
it began is costed again from completed layouts, and one over the bound
becomes a counted cell. A value and a counted record both cost a holder one
count and both make a union payload owning, so the change moves no other
layout, and the result is the same in either order.

**Verify** accepts `Void` among an inline record's fields. **Emit** gives an
inline record whose fields are all `Void` one unused byte, since C has no
empty struct. Lower, own and emit already handled `ValueFields` for any
record: capture environments used it. `ValueFields` means a struct whose
copy acquires each counted field; a declared record or tuple has at most one,
while a capture environment that no runtime closure holds keeps every field
it captured (`sealed_record_layout`), as before. Deep release passes the
depth through a value record's drop to each counted field, as it does for
inline unions.

## Tests

- Check (`test_check/test_recursive_records.brp`): records through an
  `Option` of themselves, a union payload, a generic record and a tuple, an
  opaque type, a mutual cycle and a union that contains itself contain
  themselves; Lists, Strings and callables end a record's walk; a union
  through a record that does not contain itself, or through a tuple,
  contains itself; a record that contains itself ends a union's walk.
  `test_recursive_unions.brp`'s pointer case is renamed for records that
  contain themselves. `CheckedRecord.fixed` had no reader left and is
  deleted, so `test_fixed_types.brp` counts fixed unions only and shows a
  fixed record's acceptance by the program's.
- Specialize (`test_specialize/test_record_storage.brp`, which replaces
  `test_inline_union_fields.brp`, and `test_tuple_storage.brp`): inline for a
  fixed union, a Bool, an ordinary fieldless union and `Void`; by value for
  one String, an owning union with one pointer, a generic record at
  `Box[String]`, a value record and a counted record; counted for two
  Strings, a value record beside a String, an owning union whose widest case
  holds two Strings and a record that contains itself; tuples likewise, and
  a tuple closing a cycle through a List counts its in-progress element as
  one. A record holding an owning union on a cycle, directly (`Wrapper`) or
  inside another union's payload (`Holder`), is counted whether
  specialization meets the union or the record first.
- Verify (`test_verify/test_value_records.brp`, and
  `test_inline_union_fields.brp` updated): value records verify through
  calls, updates, Lists and captures; a value record without an owner, and
  one whose owner is never dropped, are rejected with their messages; an
  inline record with `Void`, or with an ordinary fieldless union, verifies.
- Runtime (`test_runtime/value_record_suite.brp` with
  `fixtures/value_record_test.c`): the helpers emitted for a one-String
  record copy and drop it, store it in a List and hold it in a counted
  closure environment, under the strict leak check and ASan, with the live
  allocation count after each step.
- Existing runtime probes: deep release's emitted-helpers probe builds its
  `Branch` chain through Lists as values now (`release_helpers_test.c`), and
  the List reuse probe gives `Entry` a second String so that its managed
  element stays a counted record (`list_reuse_test.c`).
- E2e (`test_compile/data.brp`): `record/returned_value`, the lexer's
  `SkippedLines` shape, allocates only its List; `record/value_copies`
  copies, updates, stores and captures a value record;
  `recursive/deep_opaque_record_chain` releases a million records that
  contain themselves through an opaque type. Deep release's
  `recursive/deep_record_chain` (through `Option`) keeps its count.

## Measurements

Host: Apple M4, 32 GB, macOS 26.7.1, Apple clang 21.0.0, seed
`blorp-seed-4fee244ad96f`. Base `7d4eb74be`; the candidate is this change's
`blorp/src` and `blorp/standard_library`, measured at `c21286002`, whose
source the landing commit keeps. Scripts, logs and raw samples are in the
ignored `build/records-landing/` of the landing worktree.

**Stage 2, the ceilings.** Each side's seed-built compiler compiled its own
source; that C was linked with `clang -std=c11` at `-O2`, at `-O2` with
`-DBLORP_MEMORY_DIAGNOSTICS=1`, and at `-O0 -g -fno-omit-frame-pointer` with
diagnostics. Both stage-2 compilers then compiled the base's
`blorp/src/main.brp` and library from the base tree: one strict run of each
diagnostic binary (allocations, peak heap), and nine alternating
`/usr/bin/time -l` rounds of each `-O2` binary on a 64 MB stack.

| Measure | Base | Candidate | Change | Ceiling |
| --- | ---: | ---: | ---: | --- |
| Allocations | 14,443,431 | 11,910,882 | -17.53% | at least -12% |
| Instructions, median of 9 | 12,754,688,189 | 11,899,587,036 | -6.70% | at least -3% |
| Cycles, median of 9 | 3,068,061,708 | 2,930,026,460 | -4.5% (minimum -4.1%) | no worse than base |
| Peak heap, bytes | 172,960,764 | 174,808,621 | +1.07% | at most +10% |
| Atomic count operations | 265,721,417 | 217,894,359 | -18.0% | reported |

Elapsed time fell from a median of 0.76 s to 0.73 s; peak RSS rose 6.9%,
within its noise (peak heap is the deterministic measure). Count operations
by kind: records -42.3%, Lists +9.5%, unions +57.2% (an inline union now
holds value records), Strings +1.5%. The seed-built and stage-2 candidates
write byte-identical C for the base's source (`817552605484cb21`); it
differs from the base's (`881974ec29f60dc8`) because the representation
changed, and is 0.6% smaller. The recount (above) left that C unchanged:
the review's bound scanner finds no value record over the bound in it, or
in the compiler's C for its own source, but capture environments (59 and
61), and none in any of the 635 e2e fixtures and trait inputs that compile
alone (19 environments; `bound_scan_final.log`).

**Stack.** Both compilers, at `-O2` and at `-O0`, compile their own source
on the default 8,176 KB stack. The sum of all emitted functions' frames:

| Build | Base | Candidate |
| --- | --- | --- |
| `-O2` total | 444,096 B | 551,664 B (+24.2%) |
| `-O2` frames over 1 KB / over 4 KB | 8 / 1 | 23 / 1 |
| `-O2` largest | 4,704 (`elaborate_value`) | 5,040 (`elaborate_value`) |
| `-O0` total | 3,545,728 B | 4,452,256 B (+25.6%) |
| `-O0` frames over 4 KB / over 16 KB | 142 / 9 | 213 / 17 |
| `-O0` largest | 45,536 (`plan_body_base`) | 53,200 (`plan_body_base`) |

Under a reduced limit, the `-O0` candidate needs between 2,048 and
2,560 KB and the base between 1,536 and 2,048 KB; both `-O2` builds pass at
1,024 KB. `__TEXT` grew 0.75% and `memcpy` calls in machine code from 146 to
273.

**Seed-built row.** `blorp/scripts/self-compile-cost 7d4eb74be c21286002
--rounds 3`: fixed-input allocations 14,443,432 to 14,508,983 (+0.45%),
instructions +0.48%, peak heap -0.03%; own source +0.75% and +0.69%. Both
binaries come from the seed, which stores every record in a cell, so this
row is the new work alone. It was +0.93% and +0.73% before the walk stopped
substituting the fields of declarations without type parameters. Allocation
sites put the rest in Check's classification walk, which now walks records
and continues union walks through by-value records: `met` +17,820 (its
occurrences, cells under the seed), `stored_type` +10,910, `root_fields`
+7,682, `substitute_type` +3,364; substitution as a whole
(`occurrence_fields` and `substituted_fields`) +3,440. Specialize's
`copy_cost` and recount add none measurable.

**E2e.** Every program's output and exit status is unchanged. 120 expected
runtime allocation counts fell and none rose: `streaming_compare` at
327,681 bytes from 146,807 to 58,484, `lookup_errors` from 1,684 to 1,508,
`owned_loop_condition_projection` from 202 to 101. No existing compile
ceiling changed. The new cases' ceilings are the larger of three serial
compiles plus 15%, rounded up; run allocations are exact:

| Program | Compile allocations | Compile instructions | Run allocations |
| --- | ---: | ---: | ---: |
| `record/returned_value` | 72,856 | 272,970,074 | 1 (base: 1,001) |
| `record/value_copies` | 76,305 | 282,866,139 | 8 (base: 10) |
| `recursive/deep_opaque_record_chain` | 72,607 | 271,060,711 | 1,000,000 (base: the same) |

**Red first.** The new and rewritten suites, run against the base compiler
(`red_first.sh`): Check 9 of 10 fail (the base has no record fact, so the
suite reads every record as not containing itself; the passing test expects
that), Specialize record storage 7 of 13 and tuple storage 2 of 5, Verify
inline records 2 of 3 and value records 3 of 3, and the runtime probe stops
at its catalogue. The tests that pass on the base guard behaviour that does
not change: inline records of fixed unions, Bools and numbers, counted
records over the bound or containing themselves, and the owning union
rejected when forced inline.

**Lines.** Production (`blorp/src`): +409, -212, net +197, within the +200
ceiling. Tests (`blorp/test`, suites, fixtures and C probes): +1,406, -405.

**Gates.** `make -C blorp test INSTRUCTION_CHECK=on` passed all 3,145
cases, no ceiling exceeded (`make_test_final_2.log`), on `d95f6b770`, which
differs from the landing commit only in this line. The fixpoint runs in
branch CI.

## Raising the bound later

The bound is one because the compiler copies records far more often than it
builds them, and today every copy of a value acquires each counted pointer
it holds. The pilot measured bounds of two (allocations -32.8%, cycles
-7.8%, but `-O0` frames half as large again) and eight (cycles +36%). Three
changes would make copies rarer or cheaper, each measurable alone at stage 2:

1. **Field moves in own.** An update of an owned record projects (acquires)
   every inherited field and then drops (releases) the old record. Moving
   the fields out instead needs no count at all.
2. **Borrowed records by address.** A borrowed by-value record over 16 bytes
   is copied by the caller for every call clang does not inline; passing it
   by address, as Swift's `@guaranteed` and Rust's indirect pass mode do,
   copies nothing.
3. **`static` emitted functions.** Every `blorp_f_N` has external linkage, so
   clang keeps the platform ABI for each call it does not inline. Adding
   `static` alone saved 1.0% of the base compiler's instructions in the
   pilot.

After each, rerun the pilot's variant measurement at a higher bound. Raising
the bound needs a count in `CopyCost` beyond one, which the closed type
makes a visible change rather than a constant to edit.

## Follow-ups

- Check's classification walk is the new work's whole compile cost (0.45%
  of a seed-built self-compile's allocations, above): each walk rebuilds a
  declaration's field list and searches its expanded occurrences linearly.
- An inline union is as large as its widest case, so a union holding a
  large value record grows every List of it; a rule boxing an outsized case
  (Rust's `large_enum_variant`) is the matching tool if the bound rises.
