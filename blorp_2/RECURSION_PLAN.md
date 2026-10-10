# Recursion in bounded increments

The user approved this sequence on 2026-10-10. Each increment must pass its
own phase tests and independent compiler review before the next is enabled.
The README and grammar, rather than this plan, describe implemented support.
Read both [AGENTS.md](AGENTS.md) and the [parent AGENTS.md](../AGENTS.md).

## Established precedents and local choices

These primary sources were checked on 2026-10-10. Each comparison supports a
specific decision; the pilot still needs its own invariants and tests.

- **Discover concrete instances by identity.** Rust's
  [monomorphization collector](https://doc.rust-lang.org/nightly/nightly-rustc/rustc_monomorphize/collector/index.html)
  follows dependencies between concrete instances from roots until no new
  instances remain. Our small request queue reuses exact concrete keys before
  following their children. This is the same graph-discovery principle, not a
  claim that Rust uses our queue or termination rule. Deduplication cannot stop
  infinitely many different keys. Test exact self/mutual target identities,
  distinct instantiations, permutations and resets.
- **Make borrowing and RC explicit.**
  [Counting Immutable Beans](https://arxiv.org/abs/1908.05647), Lean's
  [borrow inference](https://lean-lang.org/doc/api/Lean/Compiler/LCNF/InferBorrow.html)
  and [explicit RC pass](https://lean-lang.org/doc/api/Lean/Compiler/LCNF/ExplicitRC.html)
  supply precedent for borrowed parameters, liveness-driven RC operations and
  projected values whose lifetime depends on their parent. The recursive-union
  increment will carry the exact parent/variant provenance and acquire an
  obligation before a child escapes.
  Our independent verifier is local validation machinery; those precedents do
  not prove our implementation. Test borrowing, early parent cleanup and escape
  separately.
- **Put cleanup on explicit control-flow edges.**
  [Perceus](https://www.microsoft.com/en-us/research/uploads/prod/2021/06/perceus-pldi21.pdf)
  derives precise RC operations from explicit control flow and ownership
  resources. Returning match arms give this pilot a small, testable first
  boundary. Keeping prefix owners until the selected arm returns can be correct
  while retaining values beyond their last use; it does not establish Perceus's
  garbage-free result. Test every selected edge and escaping result before
  refining scheduling from a measured example.
- **Break recursive layout with indirection.** The Rust Book's
  [recursive type example](https://doc.rust-lang.org/book/ch15-01-box.html)
  explains why recursively embedded values need a finite-size indirection.
  OCaml's [value representation](https://ocaml.org/docs/memory-representation)
  supplies precedent for tagged constructor blocks with fields. Atomic ARC and
  boxing every variant, including leaves, are Blorp pilot choices. Test canonical
  layout identities and exhaustive active-variant cleanup rather than copying
  either language's complete runtime model.
- **Separate destruction depth from call depth.** Rust's
  [LinkedList destructor](https://doc.rust-lang.org/src/alloc/collections/linked_list.rs.html#1177-1195)
  explicitly removes nodes in a loop. The planned unary final-release loop will
  apply that structural idea to ARC; its shared-tail stopping rule needs
  separate tests.
  Lean's borrow analysis also accounts for cleanup that would occur after a tail
  call. OCaml's [tail-modulo-constructor transformation](https://ocaml.org/manual/5.5/tail_mod_cons.html)
  makes clear that constant-stack behavior requires a qualifying transformation.
  Ordinary C calls currently promise neither TCO nor bounded-stack traversal.
- **Prove acyclicity from construction rules.** OCaml permits
  [cyclic immutable recursive values](https://ocaml.org/manual/5.5/letrecvalues.html),
  so immutability alone is insufficient. Blorp constructors accept completed
  children and provide no recursive value bindings, backpatching, lazy knot
  tying or shared mutable references. Whole-value reassignment preserves this
  induction. Test invalid forward/self references and borrowed child lifetimes;
  revisit the argument when adding any capability that can create an edge.

The positive parameter-dependency-cycle check below is a conservative,
pilot-specific termination restriction, not a general algorithm for polymorphic
recursion. It can reject finite programs when an unreachable call path appears
to grow types. Its argument depends on the current first-order nominal type
algebra; richer type computation or destructuring requires a fresh review.

## 1. Function recursion

Start with the ordinary fixture `test/e2e/fixtures/recursion/self.brp`:

```blorp
fixed union Step:
    Stop
    Once
pure func walk(step: Step) -> Int:
    match step:
        Stop: 7
        Once: walk(Stop)
func main() -> Int:
    walk(Once)
```

Accept self and mutual calls through the existing resolved call contracts.
Signatures are known before bodies; specialization reuses an already requested
concrete function identity; C signatures precede definitions. Preserve the
existing arity, type and purity checks in recursive bodies and unused helpers.
Ordinary calls use the C stack. No tail-call or constant-stack execution
guarantee is part of this first increment.

Generic function recursion must still produce finitely many concrete keys.
Build transient dependencies between declaration-owned type parameters from
resolved call substitutions. A dependency beneath a type application grows
type depth. Reject a cycle containing such an edge. Bare-parameter cycles,
including copying and permutations, and paths broken by concrete resets are
finite. With finite constructors and ground leaves, bounded type depth bounds
the concrete key set. This is a checking rule, not a runtime budget or a
second published call authority.

Test exact recursive instance identities and argument order. Test growing
substitutions in every supported call occurrence, including unused binding
initializers, record fields and unselected match arms. Independent raw
ownership inputs must exercise recursive argument borrowing, distinct result
obligations, last uses, return acquisition, use after drop, leaks, double drops
and invalid provenance. Native fixtures use their real main and include
mortal String results and arm-local owners held across recursive calls.

## 2. One nongeneric recursive union

The next working example requires no arithmetic, collections or new control
flow:

```blorp
fixed union Nat:
    Zero
    Next(Nat)
pure func make() -> Nat:
    Next(Next(Zero))
pure func walk(value: Nat) -> Int:
    match value:
        Zero: 7
        Next(child): walk(child)
func main() -> Int:
    walk(make())
```

Begin with direct self-reference in a nongeneric unary union. Keep existing
Int-only unions inline. Box every variant of a recursive union, including its
nullary variants; immortal leaf shortcuts are unnecessary. Mixed Int and self
payloads may use the same complete variant contracts. Cross-union, generic
recursive and multiple-field payloads remain explicit rejection cases until
their increments. Managed records are not a prerequisite.

### Authorities and ownership

- Checking resolves the self-reference to its canonical UnionId. No later
  consumer recovers that distinction from the declaration spelling.
- Specialization reserves the concrete identity in a local builder before
  resolving children, then publishes a complete immutable layout. A recursive
  child refers to that identity instead of recursively embedding a layout.
- The canonical concrete variant contract identifies its payload type and
  whether it owns a child. Cleanup consumes this contract; do not collect a
  competing list of destructor fields.
- Lowering retains the actual capture type and exact selected-variant/parent
  relationship. Function-local ValueIds and OwnerIds remain distinct domains.
- Construction consumes a named child obligation. A fresh owner can transfer;
  a borrowed child must first acquire an obligation. Function arguments borrow.
- A projected child's provenance names the actual parent and selected variant,
  backed by a live parent owner or borrowed parameter. Verify this relationship
  from the actual projection and arm, independently of insertion.
- Every tail-match arm returns. Carry prefix obligations into each selected
  arm and discharge or transfer them there; no join representation is needed.
  Acquire an escaping child before dropping its parent. Keeping prefix owners
  through the selected arm is an acceptable first scheduling policy, without
  claiming earliest-death cleanup or minimal peak memory.
- Emission uses typed storage facts to select RC operations and owner alias
  types. A narrow local context derived from verified definitions is sufficient;
  no destructor registry or string-based type inference is needed.

### Acyclic values are mandatory

Recursive types do not permit cyclic runtime values. Construct a fresh immutable
root only from already complete values. There is no field assignment or mutable
reference through which the new root could be inserted into an old value. No
recursive value binding, backpatching or lazy knot tying is available.

```blorp
var value = make_zero()
snapshot = value
value = wrap(value)
```

The new root refers to the previous value. Reassignment changes the binding,
not the previous node, and `snapshot` continues to observe that node. The raw
ownership verifier rejects forward/self child value uses and invalid or reused
child obligations. Do not add a runtime cycle detector or collector.

### Bounded-stack destruction

An atomic root reference count starts at one. Retaining a root does not retain
its child. A nonfinal release preserves the root and every child obligation.
Final release saves the active child, frees this root once, and continues by
decrementing the child in a loop. A leaf or shared tail stops the walk. Unary
self-recursive destruction needs neither recursive C calls nor a worklist.

Constructors, projections, RC calls and destruction use the same concrete union
identity. Forward C struct declarations and pointer children leave room for
later mutual types without implementing dispatch for them now.

### Required tests and stop rules

| Boundary | Required observations |
| --- | --- |
| Checking and specialization | Canonical self identity, complete layouts, nominal separation, unused/pass-through layouts, exact diagnostics for deferred shapes. |
| Lowering and uses | Construction order, actual child type and selected variant, reassignment versions, child dependency keeping the parent alive. |
| Ownership insertion | Fresh transfer, borrowed acquisition, unused roots, shared tails, escaping children, selected-edge cleanup, RHS established before old owner retirement. |
| Independent raw verifier | Missing/double child transfer, wrong type/parent/variant, early parent drop, unacquired escape, forward child use, leaks, double drops and sibling-owner misuse. |
| Emission | Typed RC and aliases, active-variant child cleanup only, nonfinal release before child access, iterative final release, acquisition before parent cleanup. |
| Normal native fixtures | Traversal, escaped child surviving a temporary parent, shared-tail survival after one parent drops, both var snapshot/replacement observations, moderately deep destruction. |

Use the existing O0 real-main fixture path with ASan/UBSan. Compiler-process
allocation counters do not measure allocations of the emitted program.
Sanitizer success alone does not prove all children were freed. Investigate
`/usr/bin/leaks --atExit -- <fixture executable>` as a narrow native leak check;
require an intentionally omitted child cleanup to fail its oracle before relying
on it. This preserves the normal entrypoint and emitted code.

Exact per-object aggregate destruction is a distinct runtime test question.
The existing direct-C test exception covers String only. If a reliable required
oracle needs that exception extended, prepare the concrete test change and seek
explicit approval under AGENTS.md; do not silently add a C fixture driver or
claim aggregate leak coverage from compiler counters.

Preserve old valid fixture C and existing cost ceilings. Establish numerical
ceilings for new fixtures before implementation, using the existing owned-input
measurement protocol. Stop and report if the host compiler blocks correct code,
the leak oracle cannot detect omitted cleanup, or the scope needs multi-child
destruction machinery. Preserve negative evidence.

## 3. Mutual and regular generic recursive data

After the unary self-recursive path is independently green, add mutual type
references and regular generic recursive instances in separate working examples.
Reserve identities before following recursive child requests, reuse complete
concrete keys, and reject type-changing recursion that would create an unbounded
instance graph. Extend bounded-stack destruction and its tests with each shape.

A useful List needs both a head and a tail. Multiple constructor fields or an
appropriate record payload are another explicit increment, followed by managed
element cases and their complete destruction tests. Supporting recursion alone
does not claim these collections or their efficient representations are ready.
