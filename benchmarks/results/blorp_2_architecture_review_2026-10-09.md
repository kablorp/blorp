# Blorp 2 architecture before bindings

Date: 2026-10-09. Reviewed production revision:
`afe38d0465a353146423dab8140feeef0e4134b8`, branch `blorp-2`, worktree
`/Users/keithphilpott/.codex/worktrees/1332/blorp`.
Production and tracked test source were unchanged during this review.
Pending documentation adds granular memory-test requirements to
[AGENTS.md](../../blorp_2/AGENTS.md) and the
[memory plan](../../blorp_2/MEMORY_PLAN.md#phase-level-test-contract).

## Verdict and scope

The current architecture is a sound foundation for the supported unmanaged
subset. No current semantic correctness defect was established. There are
specific extension boundaries to address with bindings; a general rewrite,
global registry or complete SSA framework is not justified.

This is a source/contract audit with independent code-reviewer and test-runner
input, plus a bounded native stress probe. It is not exhaustive correctness
verification or a measured performance comparison. The previous 190/190 normal
and UBSan/leak gates belong to the
[match report](blorp_2_match_2026-10-09.md); they were not rerun for this audit.

## Current boundary and authority map

| Boundary | Authority and lifetime | Existing guarantee |
| --- | --- | --- |
| Lexing | One source input; byte spans and token classifications | Explicit ASCII subset, indentation and lexical diagnostics. |
| Parsing/interning | One parsed program with its complete name table; IDs scoped to that table | `ParsedProgram` seals syntax and spelling authority together. Unary application order is explicit. |
| Checking | Program-owned function/union positions, union-owned variant positions, function-local parameter/arm roles | Resolves names, nominal types, arity, purity, constructor patterns, coverage and acyclic calls before sealing `CheckedProgram`. |
| C emission | Borrows the checked program and projects IDs to C names | No source-name resolution, arity checking or purity checking repeated; unmanaged representation selected here. |
| I/O shell | File reads/writes, CLI and diagnostic presentation | `main.compile` and diagnostic rendering are pure; filesystem operations surround the pipeline. |

Keep the program seals, ID-based consumers, complete immutable results and pure
pipeline. The public checked record views do not themselves permit callers to
construct a `CheckedProgram`. Declaration-order alignment of temporary signature
tables is established inside checking, rather than accepted from external code.

## Changes to make with the first binding increment

### 1. Separate binding identity from binding origin

Evidence: [check.brp:78](../../blorp_2/src/check.brp#L78) defines
`BindingRole = SoleParameter | ArmBinding(Int)` and wraps that role as
`BindingId`. [emit.brp:57](../../blorp_2/src/emit.brp#L57) projects those roles
to C parameter/arm names. One parameter and one tail match make this sufficient
today. Several local declarations, scopes or matches need distinct identities
even when their spelling and origin are the same.

Use one function-owned binding allocator. Keep origin, semantic type, mutability
and diagnostic location as binding facts; do not derive identity from an arm
position or source spelling. Source `BindingId` and computed `ValueId` answer
different questions and must remain distinct. Scope lookup chooses the nearest
binding; it does not mint a replacement identity for each read or assignment.

Acceptance: separate named tests for parameter/local/arm shadowing, sibling
scope isolation, the chosen initializer visibility rule, immutable assignment,
and reassigning one binding while another still refers to its original value.
Preserve the existing match fixtures throughout this slice.

### 2. Publish the typed occurrence facts lowering needs

Evidence: [check.brp:102](../../blorp_2/src/check.brp#L102) publishes a base plus
operations. `ResolvedValue` retains the final type temporarily, and
[resolve_value](../../blorp_2/src/check.brp#L966) computes each operation's
type, but the published checked value discards those occurrence types.
Binding reads/literals also lack their own published use spans. Current
unmanaged C emission needs neither, so this is an extension gap rather than
a present typing failure.

As typed lowering arrives, preserve the type and source occurrence of each
produced value instead of re-inferring them from callers, spellings or nested C.
Function signatures remain the declaration authority; occurrence result types
describe the computed values. Do not copy entire signatures into competing
registries or repeat established arity/purity validation.

Acceptance: a chain whose intermediate values have different types retains
each result's exact type and location; lowering needs no name lookup or semantic
recheck. Reads of distinct shadowed bindings retain distinct binding IDs.

### 3. Introduce a small ordered value representation

Evidence: [main.brp:12](../../blorp_2/src/main.brp#L12) currently connects
checking directly to emission. [emit.brp:238](../../blorp_2/src/emit.brp#L238)
turns a checked unary spine into nested C; a tail match emits direct returns.
There is no identity for each intermediate computed result. This is compact
and correct for the current subset, but a managed reassignment needs a visible
point at which its RHS owner exists before the old owner is released.

Start with straight-line typed definitions and a return, using local builders.
For example, a future source body:

```blorp
original = 1
var current = original
current = 42
original
```

can lower to the following illustrative IR:

```text
v0: Int = constant 1
v1: Int = constant 42
return v0
```

Two bindings may initially map to `v0`; rebinding changes only the local
binding-to-value mapping. This does not require a mutable runtime cell or ARC.
Define block parameters/edge transfers when non-tail matches or assignments
across branches first require them. Defer loops, general phi construction,
dominance machinery and ownership passes until their working examples arrive.

Acceptance: lowering tests assert types, binding/value relationships, source
evaluation order and exactly-once computation. Native fixtures independently
assert results. Introduce no target ownership operations for current unmanaged
values.

### 4. Make the new phase contracts directly testable

Evidence: [test_match.brp:33](../../blorp_2/test/unit/test_match.brp#L33) and
[test_emit.brp:11](../../blorp_2/test/unit/test_emit.brp#L11) commonly obtain
their inputs through earlier phases. They provide useful integration and typed
output assertions, but do not isolate every internal semantic responsibility.
Some callbacks also combine several independent negative cases.

For new lowering and ownership boundaries, use minimal valid typed fixtures,
prepare upstream products outside any observed phase cost, and give separate
invariants/failures separate named callbacks. Preserve seals through valid
builders; do not expose unchecked production constructors for convenience.
The independent ownership verifier needs its own malformed ownership-IR tests,
independent of insertion. Existing end-to-end and native mutation tests remain
valuable additional oracles.

Acceptance: changing one phase's protected behavior fails its own named test;
missing acquisition, wrong owner, wrong order and missing edge transfer produce
distinct verifier failures when those operations are introduced. Requirements
are recorded in the memory plan, not represented by empty suites today.

## Smaller improvements and measurements

**Intern once and return the identity.**
[parse.brp:170](../../blorp_2/src/parse.brp#L170) interns a spelling, then scans
the resulting table again to recover the ID.
[names.brp:65](../../blorp_2/src/names.brp#L65) already performs that lookup.
Returning the updated table and resolved ID together removes repeated work and
the artificial possibility that a just-interned name is missing. This is a
small independent slice. Keep the simple storage until measurement justifies
an index. Compare parsing costs and whole owned-input compilation costs before
claiming a speed or allocation improvement; test stable IDs, repeated names
and independent table extensions.

**Probe cycle-check scaling before choosing an optimization.**
[check.brp:1544](../../blorp_2/src/check.brp#L1544) repeatedly scans functions
while [is_settled](../../blorp_2/src/check.brp#L1489) linearly scans settled IDs.
A long acyclic chain declared before its callees settles one function per
round; worst-case work is cubic in function count for that shape. This is a
static complexity finding, not a measured latency regression. Compare the
same 16/64/256-function graphs in opposite declaration orders at the checking
boundary. If material, consider local dense ID marks and a worklist; preserve
exact cycle diagnostics and calls in every match arm. Do not add a general
graph service or cached dependency registry preemptively.

**Keep grammar coverage claims bounded.** The conformance suite tests explicit
positive/negative source cases against parsing; it does not interpret
`grammar.ebnf`. Editing only that specification therefore does not mechanically
change the test oracle. Keep grammar/test review together. Consider a direct
grammar-consistency mechanism only as a separate scoped improvement.

## Bounded native probe

The host was FRESH. A scratch Blorp `TestSuite`, outside tracked source,
compiled through the current pure pipeline, then invoked Clang with strict
C11 warnings and `-O2`, using default structural limits. All four callbacks
passed and native executables returned 42:

- 32 nested identity calls.
- 300 nested identity calls.
- 32 alternating constructor/unwrap layers.
- 128 alternating constructor/unwrap layers.

Command:

```sh
bin/blorp test --suite --timeout 180 \
  blorp_2/build/architecture-review/test_depth.brp
```

Scratch source, generated inputs/C, native compiler stderr and log are retained
under ignored `blorp_2/build/architecture-review/`. This probe did not reproduce
a default-limit failure and does not establish unbounded backend scaling.
No speedup or memory improvement is claimed.

## Recommended order

1. Establish function-owned binding definitions and scope rules with direct
   tests as the first binding slice.
2. Preserve typed occurrence facts and lower scalar bindings into ordered value
   definitions before implementing managed values.
3. Add one managed type with explicit layout/call contracts, insertion,
   independent verification and runtime tests together.
4. Take the interning change independently; optimize cycle checking only after
   its focused scaling probe supports the change.

Keep representation planning out of checking until concrete storage decisions
are needed; move those decisions into their own authority before managed
aggregates arrive. Defer imports/namespace products, specialization, general
SSA analysis and reusable caches until a supported example requires them.
