# Recursive data through records and Lists

Step 2a of [roadmap item 5](../../blorp_2/ROADMAP.md): the pilot now admits
recursion that passes through a record field or a List element. That covers
the shapes its own source declares (by the design inventory, 30 types in 8 groups across
`utils/syntax.brp`, `check/model.brp`, `check/inference.brp` and
`specialize/specialize.brp`): a union whose payload is a record holding the
union, `List[Self]` payloads, mutual recursion between records and unions,
record-only cycles, and generic unions applied to a recursive type. Two shapes
stay rejected with the existing message: union-only cycles (`A(B)`, `B(A)`;
`Node(Maybe[Node])`), which are step 2b, and a generic declaration that
instantiates itself again, which is step 2c. By owner decision, final release
recurses through each group's helpers. The worklist design is kept for
reference on the unlanded branch `blorp2/recursive-worklist-ref`.

## Provenance

| Artifact | Value |
| --- | --- |
| Baseline source | `695064130` (origin/main) |
| Candidate source | branch `blorp2/recursive-mixed`, rebased on `695064130` |
| Host compiler | `bin/blorp` FRESH, Apple clang 21.0.0 (clang-2100.3.34.2), arm64 macOS |
| Baseline pilot (`git archive` of the baseline, `bin/blorp compile --no-format`, `clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1`) | binary `c72cd861…66aa`, C `9b5afdbc…a065` |
| Candidate pilot (`make -C blorp_2 test-compiler`, same flags) | binary `21a39c9c…1cae`, C `93079a1f…a588` |
| Target C flags | `-std=c11 -O0 -Wall -Wextra -Werror -pedantic`; e2e and runtime tests add `-fsanitize=address,undefined -fno-sanitize-recover=all` |

Raw samples are under the ignored `blorp_2/build/recursive-mixed/`. That
directory holds both pilots, every fixture's captured C, stdout, stderr and
exit status for both (`identity_base/`, `identity_candidate/`), the scaling
inputs, `corpus.txt`, `native.txt`, `scaling.txt`, and the scripts
`round6.sh`, `baseline.sh` and `measure.sh`. The depth probe is in `depth/`.
All runs were serial.

## Design

**Checking** (`check/declarations.brp`). The finite-layout rule is now that
the by-value storage graph must be acyclic. A union instance stores each
direct payload by value, and that includes the payloads of an applied generic
union's body at its arguments, so `Maybe[Node]` is walked as `Just(Node)`.
Three kinds of edge are pointers that a cycle may pass through: a record
field, a List element, and a non-generic union's one direct self payload. The
walk runs once per union instance (a declaration plus its checked arguments).
It is rooted, in declaration order, at every union at its own parameters, at
every record field, and at every type found behind a pointer edge. As a
result, a generic body's own instances are checked whether or not anything
applies it. Completed instances are grouped by declaration, so a lookup
compares only that declaration's instances. A separate pass rejects a generic
declaration whose body reaches an application of itself to one of its
parameters (step 2c).

**Specialization** (`specialize/specialize.brp`). Identities stay in
post-order, so acyclic programs number exactly as before. A builder-local
`PartialType` carries pending references to layouts that are still being
prepared. An in-progress layout is marked when a child refers back to it.
When a layout completes:

- If nothing referred back to it, it publishes its slot and revisits nothing.
- If something did, it fills the references to itself in the slots published
  since it started, and does nothing to earlier slots.

Each pending reference is either owning (union) or managed (record), decided
by group membership. Sealing rejects a slot that is still pending.

**Verification** (`verify/verify.brp`). The layout walk follows storage by
value only. Managed records, boxed unions and Lists are pointer edges: their
targets must exist, and each is walked as a root of its own. Index ordering is
no longer a layout rule.

**Emission** (`emit/emit.brp`). Each layout keeps the direct helper it had at
step 0, so a recursive group's release helpers call one another. Three things
make that C compile:

- One prototype block precedes every aggregate definition. It declares the
  record and List helpers, as before, and now also every boxed union's tag
  and `dup`/`drop` helpers.
- Definition order follows storage by value only. A managed record, a boxed
  union or a List is a pointer to a forward-declared type.

The unary boxed chain keeps step 1's iterative release.

## Generated C

From `blorp_2/test/e2e/fixtures/recursive/tree.brp` (`Expr` is record 0,
`Form` is union 0, `List[Expr]` is the one List layout), with line breaks
added:

```c
void blorp_union_drop_0(struct blorp_u_0 value){switch(value.tag){case blorp_v_0_0:break;
  case blorp_v_0_1:blorp_string_release(value.payload.blorp_up_1.blorp_uf_0);
    blorp_list_drop_0_r0(value.payload.blorp_up_1.blorp_uf_1);break;
  case blorp_v_0_2:blorp_record_drop_0(value.payload.blorp_up_2.blorp_uf_0);break;}}
void blorp_record_drop_0(blorp_r_0 value){
  if(atomic_fetch_sub_explicit(&value->references,UINT64_C(1),memory_order_acq_rel)!=UINT64_C(1))return;
  blorp_union_drop_0(value->blorp_rf_0_0);free(value);}
void blorp_list_drop_0_r0(struct blorp_l_0_r0* value){
  if(atomic_fetch_sub_explicit(&value->references,1,memory_order_acq_rel)!=1)return;
  for(int64_t index=0;index<value->length;index++){blorp_r_0 element=value->values[index];(void)element;
    blorp_record_drop_0(element);}free(value);}
```

From `recursive/kinds.brp`, the inline union `Kind` (index 0) stores the
boxed union `Links` (index 1), which is defined later. The prototype block
declares `Links` before `Kind`'s helpers call it:

```c
typedef struct blorp_r_0* blorp_r_0;void blorp_record_dup_0(blorp_r_0);void blorp_record_drop_0(blorp_r_0);
struct blorp_u_1;void blorp_union_dup_1(struct blorp_u_1*);void blorp_union_drop_1(struct blorp_u_1*);
enum blorp_tag_0{...};struct blorp_u_0{...struct{struct blorp_u_1* blorp_uf_0;} blorp_up_1;}payload;};
```

Without that declaration `kinds.c` fails `-Werror` with an implicit
declaration of `blorp_union_drop_1`.

## Release depth

Release recursion depth follows structure depth. The scratch probe
`blorp_2/build/recursive-mixed/depth/probe.c` includes the pilot's C for
`tree.brp`, builds an `Expr` chain iteratively in C, drops the root on a
thread of the given stack size, and bisects the deepest chain that releases.
"Field" chains use two helper frames per level (record, union). "Alternating"
chains put a one-element `Call` List on every second level, as nested checked
expressions do.

| Target C | Stack | Field chain | Alternating Field/Call |
| --- | --- | ---: | ---: |
| `-O0` | 8 MiB (main thread default) | 75,003 | 58,335 |
| `-O0` | 512 KiB (macOS secondary thread default) | 4,786 | 3,722 |
| `-O2` | 8 MiB | 105,007 | 105,007 |
| `-O2` | 512 KiB | 6,703 | 6,703 |

A self-linked record, `record Node { value: Int, next: Option[Node] }`
(`recursive/linked.brp`, probe `depth/probe_linked.c`), releases at most
87,505 nodes on 8 MiB and 5,584 on 512 KiB at `-O0`, and 262,520 and 16,760
at `-O2`.

For comparison, these are the nesting extremes of the pilot's own source
(`blorp_2/src`, by a scan of that source):

| Measure | Maximum | Where |
| --- | ---: | --- |
| block indentation | 22 levels | `emit/emit.brp:650` |
| bracket nesting | 8 | `check/bodies.brp:695` |
| method calls in one chain (UFCS nests each receiver) | 49 | `runtime/list.brp:167` |
| `and`/`or` operators in one expression | 14 | `lex/lex.brp:880` |

Even if each block level cost five `Expr`-equivalent levels, the deepest tree
the pilot builds from its own source stays below about 200 levels. That is at
least 18 times below the worst measured limit (3,722 at `-O0` on 512 KiB) and
about 290 times below the 8 MiB `-O0` limit. Source construction and
traversal of such trees already recurse to the same depth.

## Tests

Unit tests at the owning phases:

| Suite | Callbacks | Covers |
| --- | ---: | --- |
| `test_check/test_recursive_aggregates.brp` | 25 | Admission through records, Lists, `Maybe[Self]` in a record, record-only and mutual records, applied-record arguments, and a direct self payload inside a record group. Rejection with exact text, help and span of union-only cycles, two self payloads, generic reinstantiation (direct, through a List, a record or a pair), generic bodies that close a union-only cycle whether used or unused, and `Loop[T]: L(Loop[Int])` both used and unused. |
| `test_check/test_recursive_unions.brp` (step 1) | 10 | The unary shape; the List, record and record-only cases are flipped to admission. |
| `test_specialize/test_recursive_aggregates.brp` | 7 | The `Expr`/`Form` group entered at the record and at the union (same identities), owning `List[Self]`, `Maybe[Node]` key resolution, mutual records managed in child-first order, a boxed self payload inside a group, and one slot per pending instance. |
| `test_verify/test_recursive_unions.brp` | 11 | A managed record holding itself; inline unions holding each other, and an inline record/union pair, rejected as a by-value cycle; self payload, boxed and summary rules. Every rejection pins its exact message. |
| `test_emit/test_recursive_aggregates.brp` | 4 | Record and List prototypes precede every aggregate definition; the group's release helpers call each other (exact text); a by-value dependency with a higher index is defined first; boxed helpers are declared in the same prototype block. |
| `test_emit/test_recursive_unions.brp` (step 1) | 6 | Now pins the boxed `Nat` prototypes once. |
| `test/runtime/test_recursive_aggregates.brp` | 6 | Using production emission fragments and counting allocator wrappers: a Field chain, a Call with its List, a shared subtree, a nonfinal release, a 1,000-deep alternating tree and one List of 100,000 managed records, each with exact allocation and free counts on the default stack. A list helper that skips its elements fails four of the six. |

The e2e suite `test_recursive_groups.brp` prints the expected stdout for six
programs: `tree` (`17\n5`), `group` (`10`), `links` (a boxed self payload
inside a record cycle, `8`), `branches` (a record holding `Option` of a union
holding it, `7`), `linked` (a record linked through `Option` of itself, `6`)
and `kinds` (an inline union storing a later boxed union, `5`). Each has a
compile-cost ceiling of its measured cost plus 15%. The record/List-cycle
pins in `test_records.brp`, `test_direct_union_payloads.brp`,
`test_managed_records.brp`, `test_list_membership.brp`,
`test_managed_union.brp` and `test_nested_payload.brp` now assert acceptance,
and `recursive/reject_list.brp` became `list_payload.brp`.

## Gates

`make -C blorp_2 test` passes: 3,585 unit, runtime and grammar callbacks, and
415 of 415 e2e cases.

## Identity

Of the 414 e2e fixtures (408 existing plus 6 new), 397 compile identically
with both pilots (C, stdout, stderr, exit status). The 17 that differ are all
recursion fixtures:

| Fixture | Change |
| --- | --- |
| `record/recursive_{direct,mutual,union}`, `recursive/list_payload` | rejected, now admitted (exit 1 to 0, C emitted) |
| `recursive/{tree,group,links,branches,linked,kinds}` | new; the baseline rejects them |
| `recursive/reject_{generic,mutual}`, `union/direct/union_mutual_unused` | still rejected; only the help text changes, to "recursion is supported through a record field, a List element or one direct self payload of a non-generic union, such as Next(Node)" |
| `recursive/{depth,deep,trail}` | C gains one line, the boxed `Nat` prototypes (`struct blorp_u_0;` plus `dup`/`drop`); exit status and stdout are unchanged |
| `recursive/shared` | The same line, and record `Pair`, which points to the boxed `Nat`, is now defined before `Nat` because only by-value storage orders definitions. Exit status and stdout are unchanged. |

## Costs

Compile costs are the minimum of three serial runs with
`BLORP_LEAK_CHECK=strict`. The allocation counts were identical in all three
runs. Ceilings are +3% for allocations and retired instructions.

| Fixture | Base allocations | Candidate | Change | Base instructions | Candidate | Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `return/zero` | 8,823 | 8,890 | +0.76% | 54,052,279 | 53,895,872 | -0.29% |
| `union/values` | 12,516 | 12,626 | +0.88% | 63,219,849 | 63,055,924 | -0.26% |
| `union/direct/managed_record_escape` | 14,258 | 14,389 | +0.92% | 68,033,814 | 67,809,329 | -0.33% |
| `list/literal_entries` | 17,913 | 18,080 | +0.93% | 76,616,874 | 76,454,313 | -0.21% |
| `calculator/float` | 42,204 | 42,744 | +1.28% | 134,379,235 | 135,022,091 | +0.48% |
| `tail_recursion/accumulator` | 18,091 | 18,291 | +1.11% | 77,161,641 | 77,126,776 | -0.05% |
| `recursive/depth` | 12,470 | 12,609 | +1.11% | 63,114,422 | 63,042,949 | -0.11% |

The increase is about 67 allocations per program plus, from `flat-n`, about
47 allocations and 111,000 retired instructions per record/union pair. It is
not attributed to a phase: no profile was run.

Generated-program runtime (ceiling +5%) was measured on `list/literal_entries`,
`union/direct/managed_record_escape` and `recursive/deep`: -0.15%, +0.56% and
-0.61% in minimum retired instructions. The first two emit byte-identical C
under both pilots, so those differences are noise. `recursive/deep` differs
only by the prototype line. Programs with new helper shapes are ones the
baseline rejects.

Scaling, from three runs each:

| Input (n declarations of each kind) | 16 | 32 | 64 | 128 |
| --- | ---: | ---: | ---: | ---: |
| `flat-n` allocations, base / candidate | 39,398 / 40,224 | 69,811 / 71,380 | 130,078 / 133,126 | 251,088 / 257,087 |
| `flat-n` instructions (millions), base / candidate | 131.6 / 133.1 | 210.6 / 213.6 | 371.9 / 378.8 | 720.7 / 734.9 |
| `groups-n` (n independent `Expr`/`Form` groups) allocations | 53,364 | 97,740 | 185,923 | 362,753 |
| `groups-n` instructions (millions) | 166.3 | 280.7 | 514.5 | 1,015.9 |
| `depth-n` (one Field chain literal nested n deep) allocations | 23,002 | 35,077 | 59,220 | 107,603 |
| `depth-n` instructions (millions) | 88.2 | 118.0 | 180.7 | 318.4 |

`flat-n` is non-recursive, so the baseline accepts it. Its overhead grows from
+1.1% to +2.0% because of a fixed cost per layout. Allocations grow linearly in every shape.

Two quadratic costs were found and removed before this measurement. At
`flat-128` they were worth about 37M instructions and 9,000 allocations. The
first was that every completed layout rebuilt every slot list, because its
own slot was published pending. The second was that every union expansion
scanned all completed instances.

Production source: +1,487 / -709 lines (net +778). Of that, the specializer is
+840 / -324, the checker +501 / -290, verify +83 / -52 and emit +62 / -42.
Test source: +1,091 / -177 lines.

## Roadmap

M4's release decision (step 3) and its status cite this report. The depth
table is the evidence; the worklist release is recorded as an optimisation to
take if data approaches it or release must run on small thread stacks.

## Left undone

- Union-only cycles (2b) and generic reinstantiation (2c) stay rejected.
- A possible simplification, recorded and not done: resolve pending
  references once at sealing, by key, instead of at each back-referenced
  completion. Pending keys can nest (`Maybe[?Node]`), so that needs a fixed
  point over the slots.
- Deep source-level construction and traversal still use ordinary call depth.
- A host-compiler defect, now
  [CF-026](../../docs/COMPILER_FAULTS.md): an or-pattern nested in a
  constructor pattern, `Some(First | Second):`, passes `check` and then fails
  emission.
