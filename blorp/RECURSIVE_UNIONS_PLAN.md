# Recursive unions

Plan revision 1, 2026-11-16, written against origin/main `4d350add0`. The
recursive-unions pilot of 2026-11-12 found the problem and prototyped this
design; its report, fixtures and raw samples are in the main checkout's
ignored `build/pilots/2026-11-12/recursive-unions/`.

**Status:** approved by Keith on 2026-11-16 (decisions below) and landed in
this change, one landing after deep release. No seed rotation: the pinned
seed builds it, and the compiler's own source needs nothing new. Follow-ups:
records by value (below).

## Problem

The most common recursive union could not be written:

```blorp
union Tree:
    Leaf
    Node(Tree, Int, Tree)
```

Check rejected it with "recursive aggregate types are not supported yet", as
it rejected a generic `Link(T, Chain[T])`, mutual `EvenNext(Odd)` and
`OddNext(Even)`, `Next(Option[Node])`, and a generic type through a List
(`Tree[T]: Node(List[Tree[T]])`). Two checker rules kept programs inside the
one shape specialization could lay out:

- Specialization boxed a union only when a payload's key was its own, so Check
  rejected every other union cycle, and every second self payload, because
  emit's release kept one child per node.
- The generic finiteness rule rejected any generic declaration that applied
  itself to a parameter, so regular recursion fell with polymorphic recursion.

## Keith's decisions, 2026-11-16

1. **Infer heap storage.** There is no `indirect` keyword: a union that
   contains itself is stored on the heap, every other union inline.
2. **Accept every recursion whose type arguments do not grow** (the
   expansive-cycle rule), not only types that refer to themselves with their
   own parameters.
3. **Release depth.** The deep-release work (depth budget and park) lands
   first, and this landing follows it: without it, releasing a 100,000-deep
   `Next(Option[Node])` chain overflows the C stack at -O0.
4. **Wording:** "recursive type grows its type arguments without bound", help
   "refer to the type with its type parameters unchanged, permuted or
   replaced by concrete types, as in Link(T, Chain[T])".

## Design

**One fact, decided in Check.** A declaration *contains itself* when its
fields or payloads, followed through the payloads of the unions and the
underlying types of the opaque types it stores by value, at their
substituted arguments, reach it again. Records, tuples, Lists, Strings and
callables are pointers and end the walk. `validate_declarations` publishes
each `CheckedUnion` with `contains_itself` only after the finite checks:
`declare_types` builds private `ResolvedUnion` rows, and
`validate_finite_declarations` turns them into `CheckedUnion`s, so no
published row is unclassified.

**Specialize boxes exactly those unions** (`BoxedCases`), at every instance,
and reads nothing else for it; the self-payload detection is gone. Every
other union stays `PlainCases` or `OwningCases` from its payloads, so
`Option[Node]` is an inline union holding a pointer to `Node`'s node.

Every by-value cycle of instances contains a union that contains itself: map
each instance on the cycle to the declaration whose body wrote its head; the
map stays on the cycle, so it repeats, and the repeated declaration's walk at
its own parameters reaches itself. Verify's by-value cycle walk stays the
independent proof; its three self-payload rules restated the old producer and
are deleted.

**Finite generics.** A declaration's body passes its type parameters to the
types it applies; each such flow keeps the parameter (`Chain[T]`) or nests it
(`Nested[List[T]]`). Specialization makes one layout per argument list, so a
flow that nests its parameter must not lie on a cycle of flows: Kennedy and
Pierce's expansive cycle, the rule `recursion.brp` applies to calls. The
check reuses `strong_components` from `instantiation_paths.brp`: one control
per declaration type parameter and a path per flow, and a flow that nests
its parameter and whose ends share a component is reported at the written
type that holds it. It runs after the opaque and fixed checks and before the
classification, whose substitutions terminate only once growth is rejected.

**Release.** A boxed node may hold any number of payloads of its own layout,
and may reach its own layout through inline unions, other boxed unions,
records and Lists. Deep release, which lands first, releases any such shape
in constant C stack; this landing adds no release mechanism of its own.

## Records follow-up

Records by value (bound of one, approved) extends the same fact to records:
records are classified first, following every union whether boxed or not,
and a record that contains itself becomes a pointer that ends the union walk.
`contains_itself` is named and placed for that: the walk already takes an
`AggregateId` root and reads fields through `root_fields`, a `ResolvedRecord`
row and a `CheckedRecord.contains_itself` join the same pass, and the union
walk then follows records that do not contain themselves, and tuples, as
by-value edges. Records by value landed it
([`RECORDS_PLAN.md`](RECORDS_PLAN.md)).

## Tests

- Check (`test_check/test_recursive_unions.brp`): classification for two self
  payloads, a generic self payload, a mutual cycle, a generic carrier, an
  opaque type, pointer edges, phantom and erased arguments, a union holding a
  recursive union, constant and permuted arguments; growth rejected with
  exact message, help and span for a self application, a mutual cycle and a
  List field.
- Specialize (`test_specialize/test_recursive_unions.brp`): `BoxedCases` for
  each classified union at every instance; `OwningCases` for a carrier and a
  holder.
- Verify (`test_verify/test_aggregate_order.brp`): boxed unions with two and
  with no self payloads verify and are ordered; the same layouts inline are a
  by-value cycle.
- Emit (`test_emit/test_aggregate_order.brp`): definition order. Release is
  checked by behaviour, not by its generated text.
- Runtime (`test_runtime/recursive_union_suite.brp`): a subtree under both
  payloads, a retained subtree, and left and right spines, each node freed
  once. Deep release's `release_suite.brp` releases a million-deep left spine
  of a tree with two own payloads on a 512 KB stack under strict accounting.
- E2e (`test_compile/data.brp`): `binary_tree`, `chain`, `search_tree`,
  `mutual`, `rose`, `deep_chain`, `finite_generics`; the former rejections
  `union_mutual_unused`, `cycle_by_value` and `cycle_two_self_payloads` now
  run; `reject_growing` replaces `reject_generic`.

## Measurements

Host: Apple M4, macOS 26.7.1, Apple clang 21.0.0, shared with other sessions' gates
throughout; every run waited for their binaries. Raw data is in the main
checkout's ignored `build/pilots/2026-11-12/recursive-unions/landing/`.

**Output identity.** Base and candidate compilers, each built from the pinned
seed (`make -C blorp compiler`), compiled every program with a `main` under
the base tree's `blorp/test/test_compile/fixtures`, `trait_inputs` and
`benchmarks/blorp` from the base tree (`identity/identity.sh`). Against
origin/main `af95f7a0e`, after deep release: 744 programs; all 630 that
compile at base emit byte-identical C, ten of them with boxed unions, and 109
rejections are byte-identical. (Against `4d350add0`: 734, 621 and 108.) The five that differ are the
intended ones, which now compile: `recursive/reject_mutual`,
`recursive/reject_generic`, `union/direct/union_mutual_unused`,
`opaque/generic/cycle_by_value` and `cycle_two_self_payloads`.

**Self-compile** (`blorp/scripts/self-compile-cost 4d350add0
recursive-unions --rounds 7`, -O2 compilers):

| | base | candidate | change |
| --- | ---: | ---: | ---: |
| fixed input allocations | 14,198,835 | 14,195,696 | -0.022% |
| fixed input peak heap, bytes | 170,301,553 | 170,301,553 | 0 |
| fixed input instructions, median of 7 | 12,688,442,798 | 12,678,251,368 | -0.080% |
| own source allocations | 14,198,835 | 14,147,706 | -0.36% |
| own source instructions, median of 7 | 12,679,020,357 | 12,633,532,016 | -0.36% |

Fixed-input C is identical (`8fd09726e84223d3`). The fixed-input instruction
samples spread 0.33% (base) and 0.15% (candidate), so the change is noise.

**Lines,** rebased onto deep release, whose release replaces this change's
emit edit. Production (`blorp/src`): +362, -719, net -357. Tests
(`blorp/test`, suites, fixtures and the C probes): +1,329, -75.

**New e2e ceilings.** The measured compile cost after deep release and
library-cost (b), the larger of three serial runs
(`fixture-ceilings-rebased.log`); `data.brp` holds each plus 15%, rounded up.
Run allocations are exact:

| Program | Compile allocations | Compile instructions | Run allocations |
| --- | ---: | ---: | ---: |
| `recursive/binary_tree` | 84,342 | 302,702,365 | 78 |
| `recursive/chain` | 84,029 | 302,098,665 | 32 |
| `recursive/search_tree` | 104,988 | 357,218,254 | 103 |
| `recursive/mutual` | 89,827 | 316,534,241 | 27 |
| `recursive/rose` | 83,219 | 300,877,912 | 12 |
| `recursive/deep_chain` | 73,963 | 275,548,843 | 100,002 |
| `recursive/finite_generics` | 76,757 | 285,518,065 | 9 |
| `union/direct/union_mutual_unused` | 69,450 | 263,281,987 | 0 |
| `opaque/generic/cycle_by_value` | 72,285 | 282,653,887 | 2 |
| `opaque/generic/cycle_two_self_payloads` | 72,036 | 269,952,691 | 3 |

**Existing ceilings.** `make -C blorp test INSTRUCTION_CHECK=on` failed one
case, "nongeneric parent accepts a supported generic child"
(`derived/accepted_nested_generic_head`): one compile retired 35,528,450
instructions against its ceiling of 34,660,030. Eleven alternating runs
(`gates/accepted_nested_generic_head.log`) put base at a median of 33,934,347
and the candidate at 33,812,504 (-0.4%; allocations 4,721 to 4,690): the
ceiling is 2.1% above main's own cost, and loaded runs cross it on either
side. Resetting it is the coordinator's call. The rerun on the rebased
commit passed all 2,986 cases (`gates/make-test-rebased.log`).

**Red first.** The new specialize, verify and emit tests run against base
source fail (4 of 5, 2 of 7, 2 of 4; the one that passes guards unchanged
behaviour). The check suite needs the new field, so its oracle was proved by
breaking the classification and the growth condition: 10 of its 12 tests
fail, all but the two that expect no union to contain itself.

**Binary trees** (pilot, N=15): the record-around-union idiom and the direct
union allocate the same 6,444,415 nodes; the union retires 0.9% fewer
instructions.

## Follow-ups

- A boxed union allocates a node for every nullary variant (`Leaf`, `End`);
  one shared immortal node per such variant would remove them.
- Derived `==` recurses once per level, as release did before deep release.
