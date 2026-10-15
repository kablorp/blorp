# Unary recursive unions: boxed representation and iterative release

The pilot now admits a union that names itself as one direct variant payload,
the first shape of [roadmap milestone M4](../../blorp_2/ROADMAP.md#m4-recursive-types):

```blorp
fixed union Nat:
    Zero
    Succ(Nat)
```

Mutual recursion, recursion through a record or `List`, a generic union naming
itself, and two self payloads in one variant stay rejected with the existing
message; its help now names the admitted form. This note records the design,
the generated C, the bounded-stack evidence and the matched identity check.

## Provenance

| Artifact | Value |
| --- | --- |
| Baseline source | `f453bedee` (origin/main after rebase) |
| Candidate source | the commit carrying this note, on branch `blorp2/recursive-unary` |
| Host compiler | `bin/blorp` FRESH from the same bootstrap for both pilots, Apple clang 21.0.0 |
| Baseline pilot (`bin/blorp compile` of the archived `f453bedee` source, `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1`) | `6208923b1f681bc8b7b1c3300efaf93f0a4332fa68f82cfe5c8b25fdc841da4d`, generated host C `f9005e20b74b3eb98f22614b0fb48eaa075c9929788ec862560c2757c09fed8e` |
| Candidate pilot (same recipe) | `d100cf66fd4e075821d2b0b02193407b544b740b023abb5d151fd47c07222542`, generated host C `608e057a8d7f521fb6333064401d0af33a35f66c3de569d3b69f23be08ed78d7` |
| Target C flags | `-std=c11 -O0 -Wall -Wextra -Werror -pedantic`; e2e and runtime tests add `-fsanitize=address,undefined -fno-sanitize-recover=all` |

Raw samples (both pilots and their C, every fixture's captured C/stdout/stderr/
exit for both, the scaling inputs, per-run counters and the recipe
`measure.sh`) are under the ignored `blorp_2/build/recursive-unary-20261015/`.
The recursive-release mutation binaries are under the session scratch
directory `scratchpad/m4/mutation/`.

## Design

Checking (`check/declarations.brp`) walks declared types with an explicit
worklist; a variant payload is now visited as `VisitVariantPayload(owner,
field)`, and a payload naming `owner` itself is the admitted edge instead of a
`RecursiveAggregateType` rejection. A bare union name resolves only for a
non-generic union, so generic self-reference arrives as an applied type and is
rejected as before. A second self payload in one variant is rejected at that
annotation, so every value of the union is a chain.

Specialization (`specialize/specialize.brp`) follows the roadmap's "reserve
instance identities locally and publish only complete layouts": while a union's
payloads are prepared, a self payload is held as `ReservedSelfPayload` and no
row is published; after every child layout is frozen the union takes the next
identity and `complete_payloads` fills the reserved slots with it. The layout's
representation is a new `UnionRepresentation` variant, `BoxedRecursive`, and
`value_ownership` reports it as `ManagedUnionRoot`, so insertion and verification
treat it exactly as the other managed roots. A boxed child makes an enclosing
union owning and an enclosing record managed by the existing rules.

Verification (`verify/verify.brp`) replaces the former negative for this shape
with a positive rule: a self payload is valid only under `BoxedRecursive`, at
most one per variant, a boxed layout must have one, and the layout graph walk
treats a boxed self payload as a pointer edge rather than a storage dependency,
so a cycle closed through a record is still "recursive aggregate layout is
unsupported".

Emission (`emit/emit.brp`) borrows Rust's `Box` for finite recursive size and
`LinkedList`'s iterative drop for teardown, and OCaml's boxed tagged blocks for
the node shape. A boxed union value is `struct blorp_u_N*`; its node holds the
count, the tag and the same payload union an inline union uses. Construction
allocates one node from the same compound literal, so stored children keep the
existing acquisition rule (`store_payloads`), and matching reads `->tag` and
`->payload` through the pointer. The final release is a loop, not a recursive
call, as the roadmap requires for every newly admitted release graph. No
forward declaration is emitted: C allows the self-pointer member inside the
struct's own definition, which is the first mention of the tag.

## Generated C

From `blorp_2/test/e2e/fixtures/recursive/depth.brp` (union instance 0):

```c
enum blorp_tag_0{blorp_v_0_0,blorp_v_0_1};
struct blorp_u_0{_Atomic uint64_t references;enum blorp_tag_0 tag;
  union{struct{struct blorp_u_0* blorp_uf_0;} blorp_up_1;}payload;};
struct blorp_u_0* blorp_union_make_0(struct blorp_u_0 fields){
  struct blorp_u_0* value=malloc(sizeof *value);if(!value)abort();
  atomic_init(&value->references,UINT64_C(1));
  value->tag=fields.tag;value->payload=fields.payload;return value;}
void blorp_union_dup_0(struct blorp_u_0* value){
  (void)atomic_fetch_add_explicit(&value->references,UINT64_C(1),memory_order_relaxed);}
void blorp_union_drop_0(struct blorp_u_0* value){
  struct blorp_u_0* node=value;
  while(node!=NULL){
    if(atomic_fetch_sub_explicit(&node->references,UINT64_C(1),memory_order_acq_rel)!=UINT64_C(1))return;
    struct blorp_u_0* child=NULL;
    switch(node->tag){case blorp_v_0_0:break;
      case blorp_v_0_1:child=node->payload.blorp_up_1.blorp_uf_0;break;}
    free(node);node=child;}}
```

Line breaks are added here; the emitted helpers are single lines. `Succ(n)`
emits `blorp_union_make_0((struct blorp_u_0){.tag=blorp_v_0_1,.payload.blorp_up_1={.blorp_uf_0=blorp_owner_k}})`
after `blorp_union_dup_0` acquired `n` for the slot; `Zero` is also a node. A
variant with other payloads beside the self-reference releases them in its
`case` before saving the child, for example `Step(String, Trail)` emits
`blorp_string_release(node->payload.blorp_up_1.blorp_uf_0);child=node->payload.blorp_up_1.blorp_uf_1;`.
A node is freed only once, after its payloads are read; a shared node ends the
walk and keeps its tail.

## Bounded-stack evidence

Source construction of a deep chain is itself recursive today: managed values
remain outside `@tail_recursive` loops, so a 100,000-deep chain built by
`Succ(build(n-1))` overflows during construction (`blorp_f_1`, the `build`
function) even on the default 8 MiB stack, under ASan and plain `-O0` alike;
a 10,000-deep build overflows a 512 KiB stack in the same function. The roadmap
anticipated this: deep destruction is isolated from construction depth in an
approved runtime-helper test that builds the chain iteratively from completed
children.

`blorp_2/test/runtime/fixtures/recursive_union_test.c`, driven by
`test_recursive_union.brp` through the same production emission fragments, builds
Succ^100000(Zero) in a loop and releases it on a pthread whose stack is 512 KiB
(`pthread_attr_setstacksize`), asserting 100,001 allocations and 100,001 frees.
Companion cases cover the leaf, a short chain, nonfinal release, a retained
middle node that stops the walk and later frees its tail, and two roots sharing
one tail. All cases run under ASan/UBSan.

Mutation oracle: with the emitted release replaced by a recursive one
(`blorp_union_drop_0(value->payload...)` per node, same count and free logic),
`chain_release` still passes and `deep_release` fails with
`AddressSanitizer: stack-overflow ... in blorp_union_drop_0` (exit 134). With the
iterative release both pass. The replaced fragment and both binaries are under
`scratchpad/m4/mutation/`.

The e2e `deep.brp` fixture builds a 10,000-deep chain by ordinary recursion,
prints its length and releases it under ASan with memory diagnostics on; it
exercises the real end-to-end path but, for the reason above, cannot be the
bounded-stack proof.

## Tests

Unit tests at the owning phases, each red before its implementation:

| Suite | Callbacks | Covers |
| --- | ---: | --- |
| `test_check/test_recursive_unions.brp` | 10 | admission of the unary shape (unused, beside a String, in two variants); exact rejection text and span for two self payloads, mutual, List, generic, record cycles |
| `test_specialize/test_recursive_unions.brp` | 6 | `BoxedRecursive` with the union's own instance in its payload; no layout when unused; owning/managed parents; `ManagedUnionRoot` |
| `test_verify/test_recursive_unions.brp` | 8 | real program verifies; positive boxed rule; self payload under inline, boxed without self, two self payloads, record cycle, direct mutual boxed layouts (ordering rule), inline record holding a box all rejected |
| `test_emit/test_recursive_unions.brp` | 6 | node struct defined once with its headers; exact constructor/retain/release text; the release helper is a loop containing no call to itself; a String sibling payload released before the child is saved; construction and `->` projections |
| `test_runtime/test_recursive_union.brp` | 8 | the runtime cases above, including 100,000 nodes on 512 KiB, plus `Trail` cases with a String beside the self child: exact frees of nodes and Strings, and a retained node keeping its String and tail |

Three existing tests pinned shapes that step 1 now admits (`Next(Node)` unused
and reachable, `Pair(Int, Loop)`); they now assert admission. The e2e fixture
`union/direct/union_self_unused.brp` became `union_mutual_unused.brp` with a
mutual cycle, keeping its "rejects without publishing C" oracle.

E2e: `test_recursive_unions.brp` runs `depth.brp` (exit 3), `shared.brp` (one
chain in two record fields; exit 4), `deep.brp` (stdout `10000`), `trail.brp`
(a `Step(String, Trail)` chain inside an inline owning union, printing each
String), and three `should_fail` fixtures with exact text.

## Gates

| Gate | Result |
| --- | --- |
| `bin/blorp test --suite --timeout 180 blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar` | 2,554 callbacks pass, 0 fail |
| `bin/blorp test --suite --timeout 0 blorp_2/test/e2e` | 393 e2e cases pass, 0 fail (874 `[PASS]` lines including nested native-input cases) |
| `make -C blorp_2 test` | exit 0 (both runs above, serial, on a quiet machine) |

## Identity, corpus costs and ceilings

Every e2e fixture was compiled by both pilots with the same flags and its C,
stdout, stderr and exit compared. Of the 383 pre-existing fixtures, 379 are
byte-identical; four rejection fixtures (`record/recursive_direct.brp`,
`record/recursive_mutual.brp`, `record/recursive_union.brp` and
`union/direct/union_mutual_unused.brp`) differ only in the stderr help line that
this change rewrites, and neither pilot writes C for them. The seven new
`recursive/` fixtures are rejected by the baseline pilot. The former
`union/direct/union_self_unused.brp` was the shape this change admits; it was
renamed to `union_mutual_unused.brp` with a mutual cycle so its oracle still
rejects.

Matched existing-corpus compile cost, three alternating base/candidate pairs per
fixture on a quiet machine, `BLORP_LEAK_CHECK=strict` allocations (stable across
runs) and minimum retired instructions from `/usr/bin/time -l`:

| Fixture | Base allocations | Candidate | Change | Base min instructions | Candidate min | Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `return/zero.brp` | 8,671 | 8,674 | +0.03% | 53,536,295 | 53,179,083 | −0.67% |
| `union/values.brp` | 12,291 | 12,295 | +0.03% | 62,590,397 | 62,071,259 | −0.83% |
| `union/direct/managed_record_escape.brp` | 14,028 | 14,039 | +0.08% | 67,435,382 | 66,759,772 | −1.00% |
| `list/literal_entries.brp` | 17,652 | 17,662 | +0.06% | 76,774,300 | 76,124,375 | −0.85% |
| `calculator/float.brp` | 41,619 | 41,670 | +0.12% | 132,837,754 | 132,201,562 | −0.48% |
| `tail_recursion/accumulator.brp` | 17,829 | 17,847 | +0.10% | 77,273,927 | 76,654,942 | −0.80% |

The small allocation increases come from the added union representation arm
and the per-variant self-payload scan; they are far inside the 3% preparatory
ceiling, and existing fixture ceilings are unchanged.

New-feature scaling, candidate pilot only (the baseline rejects these inputs),
three runs each, allocations stable, minimum instructions:

| Shape | 16 | 32 | 64 | 128 |
| --- | ---: | ---: | ---: | ---: |
| Chain depth `Succ(...Zero)` in one `make`: allocations | 15,542 | 19,536 | 27,519 | 43,468 |
| Chain depth: instructions | 70,741,421 | 80,309,553 | 99,602,148 | 141,175,023 |
| Distinct boxed unions, each constructed once: allocations | 25,782 | 42,599 | 76,468 | 144,162 |
| Distinct boxed unions: instructions | 97,441,079 | 141,969,939 | 235,928,197 | 437,953,256 |

Each doubling costs less than twice the previous allocations and instructions
for both shapes (depth: ×1.26, ×1.41, ×1.58 allocations; unions: ×1.65, ×1.80,
×1.89), so the added phases are at most linear in the chain depth and in the
number of boxed layouts over this range. The inputs are generated by
`measure.sh` and retained beside the samples.

Deviation: the roadmap asks for numerical fixture limits before implementation.
All four `recursive/` ceilings were set after measuring, at measured +15%:

| Fixture | Allocations | Instructions | Ceiling |
| --- | ---: | ---: | --- |
| `recursive/depth.brp` | 12,425 | 62,706,991 | 14,300 / 72,000,000 |
| `recursive/shared.brp` | 14,428 | 67,482,499 | 16,600 / 77,600,000 |
| `recursive/deep.brp` | 15,238 | 69,869,926 | 17,500 / 80,400,000 |
| `recursive/trail.brp` | 14,293 | 68,163,309 | 16,500 / 78,400,000 |

## Size

`git diff --stat f453bedee -- blorp_2/src`: 6 files, +436/−125 lines. Tests:
31 files, +1,141/−42; documentation and this note: 3 files, +333/−21. Test growth is new phase coverage plus
the three admission flips; no existing assertion was compressed or removed.

## Left undone

- Deep source-level construction and traversal await the managed tail-loop
  increment; until then a long chain can only be built iteratively in C or at
  call depth the C stack allows.
- Mutual, generic and branching recursive shapes (roadmap item 5, later steps),
  which need a release worklist rather than this chain walk.
- The specializer would still recurse without bound on a mutual cycle that
  checking failed to reject; it relies on the checker's admission rule rather
  than its own cycle detection (pre-existing, unchanged here).
- `Zero` allocates a node per construction; a shared static leaf is the obvious
  later representation step.
