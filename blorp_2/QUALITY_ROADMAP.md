# Blorp 2 quality roadmap

This is the work queue left by the 2026-10-16 quality reset. Independent bug
hunts found correctness bugs in recently landed Blorp 2 work. Keith then asked
for problems to be solved holistically, so that fixes reduce complexity instead
of adding cases. Every plan is reviewed before code, and every change gets
multiple reviews.

[ROADMAP.md](ROADMAP.md) owns the milestones toward self-compilation. This file
owns the corrections, language rules and cleanups that were decided on the way.
Most of them precede or reshape milestone work. Each section gives:
- the context, including the bug or rule and Keith's decision in his own words;
- the design, with literate code;
- the measured or estimated line and performance cost;
- the current state, with branch names and SHAs;
- the remaining steps.

The investigation plans behind these sections lived in a session scratchpad that
no longer exists. Everything a successor needs from them is restated here. Local
branches named below still hold their code.

## Contents

1. [How work lands](#how-work-lands)
2. [Status at a glance](#status-at-a-glance)
3. [Namespace: one scope per module](#namespace-one-scope-per-module)
4. [`?=` only at a function's top level](#-only-at-a-functions-top-level)
5. [Pattern and binding names](#pattern-and-binding-names)
6. [No private type in a public declaration](#no-private-type-in-a-public-declaration)
7. [UFCS receiver clashes](#ufcs-receiver-clashes)
8. [Host-compiler faults to record](#host-compiler-faults-to-record)
9. [Deferred cost work](#deferred-cost-work)
10. [Maintenance items](#maintenance-items)
11. [Paused milestone branches](#paused-milestone-branches)
12. [Decision log](#decision-log)

## How work lands

The process below is what Keith asked for. The failures behind each rule are
noted in the decision log.

1. **A reviewed plan before code.** A plan contains:
   - a reproduction, with the pilot and the host as oracle;
   - the root cause, stated as the missing invariant;
   - every sibling instance, listed but fixed only when the same edit fixes it;
   - the smallest design, with literate before/after code;
   - the line delta;
   - failing-first tests;
   - cost ceilings set before implementation.

   An independent reviewer judges it and must give an explicit **simplicity
   verdict**: is this the smallest design that keeps each invariant in one place,
   and what existing code could it absorb?
2. **Solve the class, not the case.** If a review round's fixes grow the code or
   add a special case, stop patching and redesign from the invariant. Each fact
   has one enforcement site. A design that checks one fact in several places is
   rejected. Illegal states are unrepresentable. Narrow a result type instead of
   writing an unreachable match arm, and name every sentinel or replace it with a
   type. Don't add code for features that don't exist yet; Blorp 2 has no type
   bounds, for example.
3. **Two independent code reviews on every commit.**
   - A fresh *correctness* reviewer checks the diff, adversarial probes run
     through C with sanitizers and the strict leak check, and C identity.
   - A *design-conformance* reviewer, usually the plan reviewer, checks that the
     approved design is implemented, that illegal states stay unrepresentable,
     and that line counts are honest.
   - Then a separate *test-runner* verifies that the approved repository host is
     FRESH without rebuilding or replacing the frozen compiler, and runs
     `make -C blorp_2 test`, the frontier and the leak check for each code slice.
     Documentation-only slices use their owning link/path and whitespace checks.
4. **Honest costs.**
   - Production and test lines are reported separately.
   - Compressed formatting that hides growth is rejected.
   - An unexplained cost goes back for a root cause with evidence. A "host
     artifact" claim was once a leftover `if False:`.
   - Plans set an **allocation** ceiling on a stress fixture as well as
     instruction ceilings. Allocations are deterministic, and CI sets
     `BLORP_2_INSTRUCTION_CHECK=disabled`, so only an allocation ceiling guards
     scaling in CI.
5. **Keep the queue moving.** Batch review findings into one fold round. Once
   the should-fixes are verified, nits become follow-up commits rather than
   another round. Don't start new plans while finished work waits to land.
6. **The host compiler is frozen.** "It can be more or less frozen." New rules
   land in Blorp 2 only. The divergence is recorded in
   [GRAMMAR.md](../docs/GRAMMAR.md) and [grammar.ebnf](grammar.ebnf).

## Status at a glance

The handoff's implementation baseline is `bd8b39775`; roadmap publication
`05ac9c9ce` changes documentation only. The table records that handoff, rather
than a live `main` tip. Line deltas are production lines in `blorp_2/src`.
The namespace completion checkpoint is recorded below.

The namespace was subsequently squash-merged and pushed as `fb257c946`.
[Remaining quality work](QUALITY_REMAINING_PLAN.md) records the current
execution order, refreshed propagation census and validation contract.

| Item | State | Branch / SHA | Next step | Lines |
| --- | --- | --- | --- | --- |
| Namespace redesign | Six commits built, reviewed twice and gated green; one batch of small fixes open | `blorp2/namespace-scopes` at `bbb3da2f9` | Fold the [open items](#namespace-open-items), spot-check, gate, land | −188 |
| `?=` rule | Preparatory refactors landed (`9c6318caa`..`6122c420c`); plan reviewed | — | Run the rewrite after the namespace lands, then the rule | +479 more |
| Pattern and binding names | Plan revised; delta review not finished | — | Delta review, then five commits after the namespace | +21 |
| Private types in public declarations | Plan revised; delta review not finished | — | Delta review, then implement after the namespace | +66 |
| UFCS clashes | Plan reviewed; cost work not finished | — | Cut the cost, then implement after the namespace | ~+100 |
| Designated runtime results | Done: enforced once in the checker, documented | `bd8b39775` | — | 0 |
| Host faults | Three rows ride the namespace stack; two more to add | — | Add CF rows with the `?=` docs | 0 |

Landing order: the namespace stack, then the `?=` rewrite and its rule, then the
pattern and binding names, then private types, then UFCS. Each of the last
three reads the namespace's new lookups.

**Current completion.** The decided correctness and maintenance queue is
complete: namespace, propagation placement, pattern/binding names, private
types, receiver clashes, emitter diagnostics, keyword authority and multiline
test cleanup. [Remaining quality work](QUALITY_REMAINING_PLAN.md) records the
individual decisions and reports. The final
[receiver checking report](../benchmarks/results/blorp_2_receiver_clashes_2026-10-16.md)
records the passing 2,852-component/445-e2e destination gate and measured
35/37 parser frontier. The deferred cost experiments and paused branch
inventory below remain separate work, not unreported acceptance requirements.

## Namespace: one scope per module

### Problem

On main, `blorp_2/src/namespace/namespace.brp` (938 lines) keeps flat,
program-wide binding lists tagged by module: `functions`, `imports`,
`variants`, `constructors`, `types`, `methods` and `aliases`. That shape caused
three problems.

- **Lookups scan the whole program.** Every lookup filters every list, so the
  checker's name lookups cost 10.3% of instructions at 1,024 functions and 18.8%
  at 2,048. Growth was measured at an exponent of about 1.9.
- **Type forwarding is cubic.** It is a fixpoint over import requests, and a
  256-module forwarding chain cost 110 G instructions.
- **The scope rules are scattered.** They are spread over about a dozen partial
  checks and 13 conflict problem variants. The bug hunt found two holes:
  - **Constructor uniqueness.** A module's scope could hold two constructors of
    one spelling: declared twice, declared and imported, imported from two
    modules, or clashing with the prelude. The checker then picked one by list
    order.
  - **Import per kind.** Selection and visibility mixed declaration kinds, so a
    private function could hide a public union of the same spelling.

A case-by-case fix (`blorp2/namespace-kinds`, `b03020802`, now superseded) grew
through three review rounds, from +39 to +98 lines and from +7 to +16. The one
uniqueness rule ended up in three functions with four problem variants and a
skip rule. Keith held it: "We need to solve problems like this holistically",
and gave the rewrite latitude: "It's ok to change datatypes, delete tests, etc.
But the end result must be clearer and cleaner than what we have today."

### Decisions

- **No ambiguity.** "There must not be ambiguity." "Everything in scope." In
  one module, a spelling denotes at most one entity per name space. That counts
  declarations, imports and the prelude.
- **No re-exporting.** "Re-exporting is not allowed. We need to fix that." A
  module offers importers only its own public declarations, by selection and by
  qualified name alike. The pilot used to forward imported types through
  selections but not through qualified names. The host forwards nothing.
- **Cause-only diagnostics.** A module that imports a failed module reports
  nothing of its own. In practice, building stops at the first failing module in
  dependency order, because only the first problem is ever rendered.
- **Repeats are caught early.** A name repeated within one selection list is a
  parser error. Importing one module twice is an assembly error.
- **Keyed scopes**, accepted reluctantly ("Ugh. I guess that's ok."). They use
  an Int-keyed map that is "deleted once we add a dict implementation". Any
  future dict uses Int or Float keys only.
- **Narrow result types.** "One of our principles is make illegal states
  unrepresentable." A value lookup cannot return a type.
- **An interim message in C1 is acceptable.** "No-one is using this."

### Design as built

There is one module with ordered sections. Only the queries are public: 718
lines, 17 types, 34 functions, 9 of them public. Main has 971 lines, 20 types
and 52 functions. The checker calls five queries where it called twelve, and
`check/namespace.brp` is deleted, so problems reach `render.brp` unchanged.

```blorp
-- What a written name denotes in a module.
fixed union Entity:
    Function(FunctionId)
    Constructor(VariantId)
    Type(TypeHead)
    Alias(AliasedModule)

-- How a name entered its module. The entry's WrittenName span is where a
-- diagnostic points: the declaration, the selection, or the prelude's selection.
fixed union Origin:
    Declared(Visibility)
    Imported
    Implicit

fixed record Entry {
    name: WrittenName,
    entity: Entity,
    origin: Origin
}
```

Every name enters through one private function, which is the only place the rule
is checked. The code below is simplified from the built `enter`; helper names may
differ.

```blorp
-- In one module a spelling denotes at most one entity per space. Functions and
-- constructors share the value space and types have their own; an alias claims
-- both. The same entity arriving again by import, such as the prelude's `Some`
-- and an explicit `_base: Option(Some)`, merges. A second declaration always
-- conflicts.
private pure func enter(built: BuiltScope, incoming: Entry) -> BuiltScope:
    match occupant(built.scope, incoming):
        None:
            { built | scope = with_entry(built.scope, incoming) }
        Some(previous):
            if arrives_by_import(incoming) and same_entity(previous.entity, incoming.entity):
                built
            else:
                { built | problems = built.problems.append(NameConflict({ incoming = incoming, previous = previous })) }
```

Entries enter in source order: the prelude's selections first in a user module,
then the import block, then the declarations. A conflict is therefore always
reported at the later name, with the earlier one as its note. Within the failing
module, the problem with the earliest span is reported. The one exception to
entry order is `methods_only`, which is checked after all import rows because a
later row may import its type.

The offer rule also lives in one place:

```blorp
-- A module offers importers only its own public declarations, by selection and
-- by qualified name alike (no re-export).
private pure func offer(entry: Entry) -> Result[Entity, SelectionProblem]:
    match entry.origin:
        Declared(Public): Ok(entry.entity)
        Declared(Private(_)): Err(PrivateSelection)
        Imported | Implicit: Err(ImportedByTarget(entry.entity))
```

The checker's queries return narrow types, so it never writes an unreachable
arm. These are the query shapes; read the built module for exact names:

```blorp
fixed union NamedValue:
    NamedFunction(FunctionId, FunctionSource)   -- DeclaredHere | ImportedAt(Span)
    NamedConstructor(VariantId)
    NamedAlias(AliasedModule)

pure func named_value(namespace: Namespace, module: ModuleId, name: NameId) -> Option[NamedValue]
pure func named_type(namespace: Namespace, module: ModuleId, name: NameId) -> Option[TypeHead]
pure func offered_value(namespace: Namespace, target: ModuleId, name: NameId) -> Result[OfferedValue, Unoffered]   -- `A.f`, `A.Circle`
pure func offered_type(namespace: Namespace, target: ModuleId, name: NameId) -> Result[TypeHead, Unoffered]       -- `A.Shape`
```

Assembly publishes the dependency order as rows, built from its cycle walk. Each
user module depends on the prelude. The walk uses an explicit stack, so a cycle
of 7,000 modules is reported where the old recursive walk crashed at 2,350.

Conflict text is one table over the two entries' origins. Imports precede
declarations and the prelude enters first, so only these pairs occur:

| New name | Earlier name | Message | Help |
| --- | --- | --- | --- |
| Declared | Prelude | `Some is provided by the prelude` | give this constructor another name; the prelude's constructor Some is always in scope |
| Declared | Imported | `Circle is already imported` | rename this constructor, or remove Circle from the import |
| Declared | Declared | `duplicate constructor name`, or `constructor name conflicts with a function` | give each one a distinct name |
| Imported | Prelude | `Some is provided by the prelude` | omit Some from this selection, or reach it through a module alias |
| Imported | Imported | `Circle is already imported` | select Circle from one module only, and reach the other through a module alias |

Selecting something the target only imports gets a teaching error with a note
at the real declaration:

```
main.brp:2:16: error: Shape is imported by ./facade, not declared there
help: import Shape from the module that declares it, or write ./facade: Shape methods_only to use that module's functions on it
shapes.brp:1:13: note: declared here
```

User modules cannot declare `Ok`, `Err`, `Some`, `None`, `True` or `False`,
because the prelude puts them in every user module's scope.

### The stack

All six commits are on local branch `blorp2/namespace-scopes`, based on
`bd8b39775`. The old worktree
`/Users/keithphilpott/CLionProjects/blorp2-namespace-scopes` is detached at
`c05f34418`, with unfinished work preserved; it is not the stack tip.
The handoff recorded each commit passing `make -C blorp_2 test`: 2,701 to 2,746 unit, runtime and
grammar tests, 427 to 428 e2e cases, frontier 32/34, and zero leaks under
`BLORP_LEAK_CHECK=strict` on all 426 fixtures.

| # | SHA | Commit | Production | Ceiling | Tests |
| --- | --- | --- | --- | --- | --- |
| C1 | `12848ddc9` | Offer only declared types to importers | −8 | ≤ −5 | −410 |
| C2 | `53cf550ac` | Seal the module graph where programs are assembled | −8 | ≤ 0 | −152 |
| C3 | `58aa4fee8` | Reject repeated selection names in the parser | +34 | < 0* | −45 |
| C4a | `fe8b5db7c` | Add an insertion-ordered Int-keyed map (`utils/int_map.brp`) | +116 | ≤ +130 | +95 |
| C4 | `ad9ba0b00` | Give each module one scope | −292 | ≤ −280 | −2,100 |
| C5 | `bbb3da2f9` | Check base type names only in the namespace | −30 | ≤ −20 | +7 |
| | | **Total** | **−188** | ≤ −180 | −2,605 |

\* C3's ceiling was set when its teaching help lived in C4. The help moved to C3
at review, and C4 shrank by the same amount. Keith should restate C3's ceiling
on the record; the open item below should bring C3 to about +24.

Expected fixture changes against main:
- C1: `import/forwarding/facade`, with the interim message;
- C3: `namespace/private_methods_only` (4:20 becomes 5:20), and the new
  `namespace/hidden_ops`;
- C4: `namespace/alias_conflict` and `facade`, with the final texts.

Elsewhere, the C output is byte-identical.

Measured on prototypes and confirmed by two reviewers:

| Input | Main | Stack |
| --- | --- | --- |
| Generated program, 1,024 functions | 15.53 G instr | −9.8% |
| Generated program, 2,048 functions | 31.85 G | −19.3% |
| e2e corpus (425 fixtures) | 17.65 G | about −4% |
| 64-module direct chain | 529–544 M | 250–258 M (ceiling 300 M) |
| 64-module flat program | 375–387 M | 132–134 M (ceiling 160 M) |
| 256-module forwarding chain | 110 G | rejected: no re-export |
| `return/zero` allocations | 8,471–8,494 | 8,398–8,421 |

### Namespace open items

The numbered list records the last batch from the three verification reviews.
Their implementation and current acceptance state are recorded in the
[completion checkpoint](#namespace-completion-checkpoint). Every commit is
already approved; these are should-fixes, and none is a redesign. The handoff
recorded a partial start on item 3 in `assemble.brp` and `test_assemble.brp`.
Those unfinished changes remain preserved in the detached worktree. The
completion was built from the integrated stack tip rather than applying that
earlier patch.

1. **C1 needs a test for the `scan.declared` fix.** In probe `c1/p07`, the
   target declares `func Foo` and only imports a type `Foo`. Selecting `Foo` must
   be accepted. Reverting to `scan.types` currently passes every suite, so add a
   test that fails with it.
2. **C2 needs a seal stress test.** Add a case of about 3,000 rows that the old
   recursive walk could not survive, since `blorp_2/AGENTS.md` asks for depth to
   be pinned.
3. **The C2/C4 seal walk needs typed edges.** The prelude edge is currently
   position −1 in `next` (`assemble.brp:207–210, 239`), and the walk relies on
   `row.imports.get(-1)` returning `None` to pick `row.end`. That is a sentinel
   for a different kind of edge. `check_imports` is also nested seven levels
   deep, with parallel `path`/`next` lists. Restructure it:

   ```blorp
   -- One edge of the module graph. A user module's first edge is the prelude.
   fixed union ModuleEdge:
       PreludeEdge(ModuleId)
       ImportEdge(ModuleImport)

   -- One module on the walk's stack and the next of its edges to follow.
   fixed record WalkFrame {
       module: ModuleId,
       next_edge: Int
   }
   ```

   Each row gets its edge list, prelude first. The stack becomes a list of
   frames referring to the authoritative module rows; an inline scalar frame
   avoids allocating a managed record at each transition. One visit-state
   vector replaces the coupled `on_path` and `done` flags. Keep the depth and the
   cost. Lines should not grow if it can be avoided. The edge type lands in C4,
   where its consumer is.
4. **C3's help.**
   - `Shape(), Shape()` currently says "with all its constructors: Shape()".
     When the constructor lists are empty, fall back to the generic help.
   - About 10 of C3's lines are fault branches for a spelling lookup that cannot
     fail. Remove them, either by quoting the written names from the source text
     through their spans, or by using a fixed help that still teaches
     `Shape(Circle, Square)`.
5. **C4a needs an insertion-order test.** The map promises insertion order
   (`int_map.brp` lines 2, 6–7 and 114), but no test pins it. The mutants
   `replace_moves_to_end` and `growth_reverses_order` pass. Restore one order
   test.
6. **C4's chain test needs allocation ceilings that bite.** They must sit
   between C4's counts and main's. Main's 87,500 and 35,084 currently sit under
   the 100k and 40k ceilings, so CI, which has no instruction check, cannot catch
   a return to main's scaling.

Then each reviewer spot-checks only its own items, a fresh test-runner gates
every commit, and the series is pushed to `main` and `blorp-2`.

### Namespace completion checkpoint

The six commits have been integrated locally on
`codex/blorp-2-quality-followup`, preserving `blorp2/namespace-scopes` and the
old worktree's unfinished changes. The completion replaces the sentinel and
parallel traversal state with typed edges, one scalar frame stack and three
visit states. Selection help is one fixed teaching rule. Constructor errors
project the original declaration and union name through existing identities.

The six open items have implementations and granular tests. Mutation checks
reject the historical `scan.types` mistake, replacement/growth order changes,
wrong closing spans and reversed dependency order. The 3,000-module tests
exercise large cycles and chains; recursive experimental drivers also pass
that size on the current host, so size alone is not a constant-stack oracle.
The production walk is iterative, with an inline-frame C representation.

Production changes are **−195 lines** against the handoff baseline, with
tests/fixtures **−2,358**. C3 is now **−2**, meeting its original `<0` ceiling.
The graph and constructor-diagnostic completion make C4 **−263**, exceeding
its original `≤−280` ceiling. Keith accepted this documented variance when
authorizing the completed namespace change to be committed, squash-merged to
main and pushed. The revised C4 ceiling is `≤−263`; allocation and instruction
ceilings are unchanged.

Both independent source reviews approve the completed model. Fresh gates
pass: 2,712 unit/runtime/grammar tests, 430 e2e cases, and strict zero leaks
on all 429 fixture files. All 348 pre-existing successful C outputs are
byte-identical; only the forwarding and alias-conflict diagnostics and the
new declared-function/imported-type acceptance differ. The frontier remains
32/34. Commands, measurements and exact comparison scope are recorded in the
[namespace measurement report](../benchmarks/results/blorp_2_namespace_scopes_2026-10-15.md#completion-measurements).
Nothing in this checkpoint claims the namespace work is published to main.

### Follow-ups recorded with the stack

- **Delete IntMap when a dict exists.** IntMap is a plain record, not opaque,
  because of CF-030. Make it opaque once CF-030 is fixed, unless a dict replaces
  it first. `EMPTY_SLOT = -1` stays, because `List[Option[Int]]` slots measured
  9,724 allocations on `return/zero` against 8,452.
- **Per-space typed entries were rejected.** They would cost about +37 lines and
  a second `enter`. About eight guarded arms remain where one `Entity` spans both
  spaces. They are documented at `claimed`, their only writer.
- **The loader slows quadratically with module count.** 1,500 modules take
  5 s, and a flat program of 1,024 modules takes 6.8 G instructions. It looks
  like string comparisons in the loader. See [Deferred cost work](#deferred-cost-work).

## `?=` only at a function's top level

### Decision

Keith said: "?= should not be valid in `if` expressions, `match` expressions,
loops, or while conditions." When a narrower reading was tried, he added: "Did
I not already mention that ?= cannot be used inside `if` and `match` blocks?"

The rule: `?=` is valid only among a function body's own top-level statements.
It is never valid inside any `if` or `match` block, at any depth, whether as a
statement or a value, in the tail or not. It is also invalid in loop bodies,
lambda bodies, `while` conditions and `for` iterables. The host stays as it is.

```blorp
func load(path: String) -> Result[Config, String]:
    text ?= read_file(path)            -- valid: top-level statement
    match mode():
        Strict:
            checked ?= verify(text)    -- rejected: inside a match block
            finish(checked)
        Lenient: finish(text)
```

The rule removes work, because no `?=` early return out of a join is ever
needed. M2.3's planned early-return-from-join work for `?=`, and its proofs in
ROADMAP lines 373 and 376, go away.

### Parser contexts

The rule lives in the parser's `StatementContext`, which gains one variant. That
makes five, and each row gives a distinct, accurate message pair:

| Context | `break` / `continue` | `?=` |
| --- | --- | --- |
| `FunctionBody` | rejected: "can only be used inside a loop" | allowed |
| `FunctionBlock` (any `if`/`match` block at function level, statement or value) | rejected: "can only be used inside a loop" | rejected: new message |
| `LoopBody` | allowed | rejected: "cannot be used inside a loop body" |
| `ValueInLoop` | rejected: "used as a value" | rejected |
| `InsideLambda` | rejected | rejected: "cannot be used inside a lambda body" |

The new message, with its help:

```
error: `?=` cannot be used inside an `if` or `match` block
help: match on the Result or Option in place, or move the block into its own function and use `?=` at its top
```

### The rewrite of Blorp 2's own source

At the plan's base, the rule rejects 374 sites in 19 files of `blorp_2/src`:

| File | Sites |
| --- | --- |
| `parse.brp` | 74 |
| `specialize.brp` | 73 |
| `verify.brp` | 55 |
| `declarations.brp` | 26 |
| `inference.brp` | 23 |
| `bodies.brp` | 21 |
| `expressions.brp` | 18 |
| `emit.brp` | 15 |
| others | the rest |

The preparatory refactors brought that to 349 sites plus 10 lambda-body sites.
`standard_library` has none. The 78 in `blorp_2/test` are compiled by the
host, so they are out of scope. With the rule alone the frontier falls from
32/34 to 15/34; with the rewrite it stays at 32/34.

The rewrite is mechanical, and Keith asked for exactly that: "just do the
mechanical rewrite of all the sites". The scripts no longer exist, so this is
the transform to re-implement. Run it after the namespace lands, because both
touch `callables`, `constructors`, `declarations` and `expressions`. Do `parse`
last.

**Form 1: a statement arm.** Match in place, nesting the continuation:

```blorp
-- before
match kind:
    Record(row):
        fields ?= declared_fields(row)
        accept_record(row, fields)
    Union(row): accept_union(row)

-- after
match kind:
    Record(row):
        match declared_fields(row):
            Ok(fields): accept_record(row, fields)
            Err(error): Err(error)
    Union(row): accept_union(row)
```

For an Option, the arms are `Some(value): ...` and `None: None`.

**Form 2: a value `if`/`match` bound to a name.** Give the bound value a
Result type, then use one top-level `?=`. Annotate the temporary to provide
its expected carrier directly. The earlier CF-032 failure report below still
needs a retained standalone reproduction:

```blorp
-- before
shape = match written:
    Named(name):
        head ?= resolve_head(scope, name)
        NamedShape(head)
    Listed(element): ListShape(element)

-- after
shape_result: Result[Shape, CheckError] = match written:
    Named(name):
        match resolve_head(scope, name):
            Ok(head): Ok(NamedShape(head))
            Err(error): Err(error)
    Listed(element): Ok(ListShape(element))
shape ?= shape_result
```

**Form 3: a helper.** Use one only where several `?=` share an arm and the arm
names a real concept. Helpers measured 1.57 lines per site, against 1.38 for
matching in place.

Moving a `?=` above its block is never valid. In every case checked, it would
evaluate an operand early or change which error wins.

The three preparatory refactors landed as `9c6318caa`, `d3ded4a23` and
`6122c420c`, for +33 lines. They split `call_signature` and merged the twin
Option/Bool arms into `verify_two_variant_union`. They added
`translate_record_field` and the named `generic_argument_conflict` and
`link_inference_variables`. Together they keep the rewrite from building 7-deep
pyramids.

### Cost

| Part | Production lines |
| --- | --- |
| Preparatory refactors (landed) | +33 |
| Rewrite | +459 |
| Parser rule | +20 |
| **Total** | **+512**, of which +479 remains |

Tests add about +62 lines, and docs about +23. Lines at 14 or more tabs rise
from 112 to 136; the deepest line stays at 20 tabs. Emitted C must stay
byte-identical on every e2e fixture at every rewrite commit.

### Commits

1. The rewrite, one commit per stage directory, each with C identical and its
   unit suites passing. `specialize.brp` is checked through C identity and host
   tests.
2. The parser rule and its tests. Each rejected shape gets one test pinning its
   message and span: a statement `if`/`match`, a tail arm, a nested block, a
   value position, a `while` condition and a lambda. One test pins an accepted
   top-level `?=`.
3. Docs:
   - GRAMMAR §5.3 with both quotes;
   - the divergence row near GRAMMAR line 1932;
   - the README's statement contexts;
   - ROADMAP M2.3 with join-arm early-return work removed, with no hard-coded site
     counts;
   - ROADMAP M0 reworded. It promised loops for `check_functions` and
     `declare_types`, which stay recursive. Record their overflow limits under
     M3's managed-value tail calls: about 2,680 functions, about 1,890 types, and
     `accept_functions` unmeasured, all at -O0;
   - the GUIDE: remove or rewrite its `?=`-in-block examples (lines 2085,
     2087–2088, 2236, 2279 and 2349), as Keith asked: "Get rid of it";
   - CF-031 and CF-032, below.

## Pattern and binding names

**Implementation checkpoint.** The reviewed implementation has completed its
standalone acceptance at -29 production lines, rather than the historical +21
estimate below. Constructor visibility and local binding creation each have
one authority; `_` is the only whole-arm catch-all. The refreshed collision
inventory is 110 source sites in 14 files. Tests and matched costs are in the
[naming evidence](../benchmarks/results/blorp_2_quality_names_2026-10-16.md);
the destination's full Makefile gate remains a publication requirement.
The following problem examples and estimates describe the original baseline.

Three decisions share one plan, because they share one cause: a bare name could
mean either a binding or something already in scope.

### Decisions

- **A1: no shadowing.** "Ok, let's enforce it." No parameter, local, `var`,
  `?=` binding, `for` binder, pattern capture or lambda parameter may reuse a
  name already in scope. That covers a constructor, function or module alias,
  including the prelude's, and an enclosing parameter or local.
- **Constructors in patterns must be imported.** "They must be imported."
- **`_` is the only catch-all arm.** "Yes, _ is the only catchall." Keith's
  reasoning: "Then it's not ambiguous at all."

### What goes wrong today

Both compilers accept all three of these.

```blorp
fixed union Color:
    Red
    Green
fixed union Light:
    On
    Off
pure func score(color: Color) -> Int:
    match color:
        Red: 1
        On: 2        -- not Light's On: a new name that matches everything
```

`score(Green)` returns 2.

```blorp
import:
    ./shapes: Shape(Circle)        -- Square is not imported
pure func sides(shape: Shape) -> Int:
    match shape:
        Circle(_): 0
        Square: 4                  -- binds a new name, matches everything
```

```blorp
match color:
    Red: 1
    Gren: 2      -- a typo becomes a catch-all and disables exhaustiveness
```

### Design

1. **A whole-arm bare name is never a binding.** It is a constructor, which must
   be in scope, or the error below. `_` is the only catch-all. Field bindings
   such as `Some(value)` and `Circle(radius)` stay. A whole arm that needs the
   value uses the scrutinee, or binds it before the `match`. This deletes
   `BindingCase` (+13 −40).
2. **An unimported constructor in a pattern is an error.** A pattern name that
   spells a constructor of the matched type that isn't imported is rejected at
   `find_variant` (`check/constructors.brp`), with help to import it. This also
   covers payload positions such as `Holds(Cyan)`, and costs about +26 lines.
   `test_foreign_constructor_pattern_is_not_visible` stays.
3. **One binding function.** Every binding passes through `bind_local` in a new
   `check/scope.brp`. That module owns an opaque `LocalBinding`, `lookup_binding`
   and `binding_site`, so no other module can create a binding without the
   check. Opacity holds only within one module, which is why it is a separate
   file. `bind_local` reads only `namespace`, `module` and the enclosing
   function, not the whole `ResolutionContext`.

   A sketch of its signature:

   ```blorp
   -- The only way to introduce a local: rejects a name that a constructor,
   -- function, alias, parameter or enclosing local already holds.
   pure func bind_local(
       scope: LocalScope,
       namespace: Namespace,
       module: ModuleId,
       name: WrittenName,
       value_type: TypeRef,
   ) -> Result[LocalScope, CheckError]
   ```

A repeated or shadowing parameter is now reported during body checking, not at
signature acceptance. That trade keeps one site.

### Fallout and renames

| Where | Sites |
| --- | --- |
| `blorp_2/src`, 13 files | 107: a function shadowed 48, a parameter 21, a local 38, a constructor 0 |
| `standard_library` | 0 |
| Fixtures | 15 of 425 change |
| Unit programs | 26 tests in 13 files |
| Whole-arm bare names | 3 of 3,590 arms in `src`, all used (+2 lines); 4 of 853 fixtures, all testing capture; 2 of 414 unit programs |

The renames follow one naming rule:
- A binder names its role and type: `left_function`, `argument_id`,
  `record_definition`, `right_union`, and `frozen_base`/`frozen_inherited` for
  the `base ?= freeze(base)` idiom.
- When unwrapping an Option, rename the Option holder (`found_name`) and keep
  `Some(name)`.
- Rename the vaguer side of a collision. Bare-noun helpers get verb phrases; for
  example, `verify.brp`'s `value` helper becomes `known_value`.
- Never use filler suffixes or numerals (`_it`, `_2`, `inner`, `tmp`).

The renames change about 180 lines for a net of 0.

### Messages

The wording below is indicative. The plan's exact texts must be confirmed in
its delta review, then pinned by the render tests.

- A shadowing binding: "`x` is already a function in this module", with a note
  at that declaration. There is one noun per kind: constructor, function, module
  alias, parameter, local. The help says to rename the binding.
- A whole-arm bare name: "a bare name in a match arm is a constructor; use `_`
  to match anything".
- An unimported constructor: "Square is a constructor of Shape but is not
  imported", with help "import it: ./shapes: Shape(Circle, Square)".
- Render tests cover every branch: 28 tests, 33 tests in all. They include
  `Gren:`, which is now rejected.

### Cost and commits

The whole set is +221 −200, net **+21** production lines. Instructions rise
about 0.08% and allocations fall about 0.95% on the corpus.

Commits, after the namespace lands:
1. the renames;
2. the rewrites (3 `src` arms, 4 fixtures, 2 unit programs);
3. the whole-arm rule;
4. the imported-constructor rule;
5. the shadowing rule.

Before implementing, re-run the site audit on the then-current main. A delta
plan review was in progress when work stopped. Finish it first.

## No private type in a public declaration

**Implementation checkpoint.** The integrated rule uses one namespace-owned
head/origin projection and one annotation-access check, at +47 production lines.
Owning tests and mutations, shared C identity, zero leaks, normal-corpus and
host-build costs pass. The original +0.5% allocation ceiling failed twice;
the [recorded decision](QUALITY_REMAINING_PLAN.md#other-rule-deltas) conditionally
permits +1.5% for corpus allocations only. The destination's full unit/e2e gate
passes (2,799 component checks and 445 e2e checks); the measured frontier is
33/35, with Char and reserved `pure` still unsupported. Exact evidence is in the
[private-type report](../benchmarks/results/blorp_2_quality_private_types_2026-10-16.md).
The estimates below describe the original handoff.

### Decision

Keith answered "I think no" to whether `Option[Secret]` may appear in a public
signature, and "Yes" to covering fields and payloads too. A public function's
parameter and return types, a public record's field types and a public union's
payload types may not mention a private type, including as a type argument.

```blorp
private fixed record Secret { value: Int }
pure func reveal() -> Option[Secret]:      -- rejected: Secret is private
    Some({ value = 6 })
fixed union Wrapped:
    Holding(Secret)                        -- rejected: public union, private payload
```

Both compilers accept this today.

### Design

The check is one function, `reject_private_type`, called from `resolve_head` in
`check/declarations.brp`. It is driven by a required `TypeScope.access`, which
says whether the declaration being resolved is public. It reads visibility from
the namespace, the one source of that fact, so the namespace's type lookup must
carry a narrow origin:

```blorp
-- Lands with this rule, not before it: nothing else reads the origin.
fixed record NamedType {
    head: TypeHead,
    origin: Origin
}
pure func named_type(namespace: Namespace, module: ModuleId, name: NameId) -> Option[NamedType]
```

The namespace stack deliberately returns `Option[TypeHead]`. A field nobody reads
cost 62 allocations and broke the allocation ceiling. This rule re-adds the
origin in its own commit and pays for it there.

The message names the private type and the public declaration, and teaches both
fixes: make the type public, or make the declaration private. There are tests
for each position, for nested type arguments, and for a qualified head, which
must be rejected for `B.Box[Secret]`. A private type behind a module alias is
already rejected by `PrivateQualifiedName`, with no second error.

### Fallout and cost

Five sites in two files of `blorp_2/src` need it. Making three types public
fixes them, for 0 net lines: `InferenceVariableId`,
`InferenceParameterConstraint` and `RecordOrigin`. `standard_library` and
all fixtures are unaffected. The rule itself costs **+66** production lines,
+0.05% instructions and +0.22% allocations, measured for the variant that reads
the origin from the namespace. The variant that re-read declaration rows cost
+78 lines and +0.94% allocations.

## UFCS receiver clashes

**Implementation checkpoint.** One inference engine now handles receiver
selection and declaration overlap, with accepted function identities and exact
inherited-prelude proof reuse. Production grows by 24 lines against the
accepted keyword base; nine behavioral mutants fail and restored controls pass.
All 808 matched current-base cost decisions and the actual destination gate
pass. Corpus allocations/instructions rise 1.644796%/1.565441%, under the
explicitly reviewed +5% correctness-pass allowance; the original tighter-limit
failures remain recorded. See the
[receiver checking report](../benchmarks/results/blorp_2_receiver_clashes_2026-10-16.md).
The design/cost investigation below is the historical handoff, not the current
implementation or an assertion that its original ceilings passed.

### Decision

Keith's rule: "UFCS can have the same names because they are not ambiguous.
They are only callable by their first-argument types. If multiple UFCS
functions have the same type of first argument and they have the same name,
there is an error." He then settled four details:
- **G3:** receivers that can overlap clash: "Yes, they clash".
  `describe(List[Int])` and `describe[T](List[T])` clash, because
  `[1, 2].describe()` fits both. Specificity never decides.
- **Bounds:** "Let's be conservative and not get into bounds (yet). It would be
  a clash." Blorp 2 has no bounds yet, "so it's hardly worth lines of code".
  The plan contains no bounds code.
- **The prelude reserves its method names:** "If the name is taken by the
  prelude, we shouldn't allow conflicts."
- **Local same-named functions** stay "duplicate function name". The grammar
  cannot declare a UFCS-only function locally; those arrive only through
  imports.

There were two gaps against this rule:
- **G1:** a clash was reported only when a call reached it.
- **G2:** arity broke ties.

| First parameter | Names the prelude reserves |
| --- | --- |
| `Int` | equals, add, to_string, subtract, multiply, divide, remainder |
| `Float` | add, subtract, multiply, divide, remainder, to_string |
| `String` | equals, length, parse_int, parse_float |
| any `List` | length, get, append, set, set_or_keep, concat |
| a bare `T` | all 15 distinct names above |

Importing `Foo` from the module that declares it also brings in that module's
receiver functions. A local `describe(Foo)` beside the module's `describe(Foo)`
therefore clashes.

### Design

There is one solver for calls and for clashes. Today `receiver_matches` and the
`Inference` helpers decide "this receiver accepts this type" separately from the
checker's unifier. Delete `Inference`, `start_inference`,
`inferred_substitution`, `infer_arguments`, `infer_type_arguments`,
`constrain_argument` and `receiver_matches`, about 180 lines. Both uses then go
through one function. This is a sketch; the solver call is elided:

```blorp
-- Two receiver types overlap if they unify with each function's own type
-- parameters as variables. Different outer types can never overlap, so they skip
-- the solver.
private pure func types_overlap(
    left: TypeRef,
    left_parameters: List[TypeParameterId],
    right: TypeRef,
    right_parameters: List[TypeParameterId],
    span: Span,
) -> Result[Bool, CheckError]:
    if disjoint_heads(left, right):
        Ok(False)
    else:
        -- inspect_inference_equality with a ReceiverOverlapConstraint origin
        ...
```

A call's receiver selection uses the same function, with `[]` as the actual
receiver's parameters. `select_receiver_contract` and `choose_receiver` move
into `inference.brp`, because `inference.brp` already imports `callables.brp`.
`receiver_expectation`, `receiver_parameter` and callables' `contains_parameter`
become dead and are deleted.

The check runs once per module, in `check/receiver_clashes.brp`, between
`validate_signatures` and `resolve_functions`. Candidates are grouped by name
once per module. The message names both declarations and both receiver types,
rendered with `type_spelling`, with a note at each declaration. That needs
`NoteLines`, a note kind with per-line text. The message is built only after an
overlap is found, from types already in hand, so it costs nothing when there is
no clash.

### Cost

The plan is about **+102** production lines and 18 tests, with 14 of 14 mutants
killed. Measured against the redesigned namespace:

| Input | Instructions | Allocations |
| --- | --- | --- |
| `return/zero` | +2.3–2.6% | +314 (ceiling 9,300) |
| Corpus | +1.8–2.1% | — |
| Programs over 1 G instructions | +0.05% | — |
| 32 modules sharing a name | +3.5–4.0% | stress ceiling 31,000; measured 29,993 |
| 128 modules sharing a name | +11–12% | +12.5% |

The stress ceiling is what caught a leftover `if False:` that disabled
`disjoint_heads`: that build measured 37,055 allocations and +34.8%.

**Open: Keith found this too expensive.** He asked whether names are sorted and
bisected. They aren't: scopes are IntMap-keyed, so lookup is O(1). The cost lies
elsewhere. Before implementing:
1. **Attribute the cost.** Profile `return/zero` and the corpus with
   `docs/DEVELOPMENT.md`'s recipes, separating grouping from unification.
2. **Check each pair once.** Two candidates from one already-checked module,
   such as the prelude's or a library's own methods, needn't be compared again in
   every importer. An importer checks only pairs that involve its own
   declarations or newly imported candidates. Show how a clash between two
   imports from different modules is caught exactly once.
3. **Build groups only for real candidates.** Count names first, and build
   groups only for names with two or more candidates.
4. **Compare structure before unifying.** Same head and every argument pair
   overlapping, where a type parameter overlaps anything. Fall back to the solver
   only when a parameter occurs twice in one receiver. Don't adopt this if it
   amounts to a second overlap algorithm.

The target is ≤ +0.5% instructions on small programs and on the corpus, with no
line growth beyond +102 unless there's a stated reason. Fourteen check and
namespace suites don't compile on the namespace prototype; the namespace stack
ports them. Gate this change only after the stack lands.

## Host-compiler faults to record

The namespace stack adds CF-028 to CF-030 to
[COMPILER_FAULTS.md](../docs/COMPILER_FAULTS.md):
- **CF-028:** a record bound at a loop body's top and read in one nested arm
  leaks.
- **CF-029:** `from_opaque Wrap(w).get_or(0, row)` infers `T` as both `Row` and
  `Wrap`.
- **CF-030:** unwrapping a value of a generic opaque type miscompiles ownership.

The `?=` docs commit adds two more:
- **CF-031: `?=` inside a bound `match` exits only its arm.** Execution
  continues after the `match`, although GUIDE line 2085 says it returns from the
  function.

  ```blorp
  pure func parse(n: Int) -> Result[Int, String]:
      if n < 0:
          Err("negative")
      else:
          Ok(n)
  func run(n: Int) -> Result[Int, String]:
      chosen: Result[Int, String] = match n < 100:
          True:
              parsed ?= parse(n)
              Ok(parsed)
          False: Ok(0)
      print("reached the line after the match")
      chosen
  ```

  `run(0 - 1)` should return `Err(negative)` without printing. It prints the
  line first. Blorp 2 now rejects this program.
- **CF-032: reported inference failure for `v ?= match`.** The earlier
  investigation reported "Incompatible error type for ?=" with `Ok`/`Err`
  arms, avoided by an annotated temporary, but did not retain the failing input.
  A fresh simple Bool/Int/String example compiles on the frozen host. The
  initializer is inferred without an expected type (`infer.brp:22504`) and
  that message is raised at `infer.brp:22548`; these source facts do not prove
  the reported fault. Keep it explicitly unverified pending reduction; see
  [COMPILER_FAULTS](../docs/COMPILER_FAULTS.md#nested-result-propagation).

## Deferred cost work

Each item below was measured but not fixed. Each needs its own reviewed plan.

- **Generic-recursion validation is cubic** (`check/recursion.brp`,
  `append_dependencies` through `validate_recursive_instantiation`). The cost
  grows with exponent 3.0: 4.2 G instructions at 256 chained generics. Blorp 2's
  own source has 6 generic functions, so it costs nothing today. The sketched fix
  is a numbered graph with visited marks, +50 −24 lines, and it took a
  128-function layered library from 5.07 G to 0.58 G.
- **Specialization's `find_instance` is quadratic** (`specialize.brp`), costing
  1.9–7.7% with exponent 1.2–1.7 in the retained experiment. Bucketing by
  declaration could narrow the search; instances still require equality of
  their complete ordered argument keys. Declaration lookup alone does not
  make that full query O(1); any index needs its own measured proposal.
- **The loader is quadratic in module count.** 1,500 modules take 5 s, and flat
  programs cost 0.525, 1.793 and 6.791 G at 256, 512 and 1,024 modules. Samples
  at 2,048 modules point at string comparisons.
- **String output costs.**
  - Emitting a String literal through `append_string_bytes` (`emit.brp`, about
    line 197) costs 2 allocations per byte and grows quadratically. It is now
    the most expensive per-byte step for a reached literal.
  - `pipe_block` (`lex.brp:926`) concatenates per pipe line, which is quadratic.
  - `render_file_location` (`main.brp:43`) takes a substring per byte, on
    diagnostics only.
  - The emitter's `result = result.concat(...)` threading (`emit.brp` 288,
    419–464, 774–836, 1157–1165, 1464–1575) copies the text built so far at
    each step. The fix is fragments plus one `join`, as `emit.brp:690` already
    does.
- **Flat recursion and managed tail calls.** 43 functions walk a flat list by
  recursing on the next index. Every one is a self tail call, but neither
  compiler turns them into loops, because they carry managed values. Keith
  decided they stay recursive. The realistic overflow limits are `check_functions`
  at 2,697 functions and `declare_types` at 1,909 types at -O0;
  `accept_functions` is unmeasured. Blorp 2's own source has 1,038 functions and
  504 types. M3's shared loops and managed-value tail calls remove the limits.

## Maintenance items

The original bug-hunt backlog follows. The emitter item is now complete:
[its report](../benchmarks/results/blorp_2_emitter_diagnostics_2026-10-16.md)
records the independent reviews, exact diagnostics, unchanged accepted C,
passing destination gates and matched costs. The
[multiline cleanup](../benchmarks/results/blorp_2_multiline_tests_2026-10-16.md)
is also complete: 209 literals in 37 files preserve their exact bytes and pass
576 focused callbacks plus the full destination gate. The
[keyword authority report](../benchmarks/results/blorp_2_keyword_authority_2026-10-16.md)
records the completed mapping refactor, granular/lifetime/mutation checks and
matched costs; the actual destination passes 2,830 component and 445 e2e checks.

1. **One message for 28 failures.** All 28 calls to the emitter's
   `internal_error()` report "invalid checked union identity", including a
   missing record layout and missing runtime arguments. Give each invariant its
   own error, carrying the relevant identity and occurrence span.
2. **Keyword authority. Complete.** One lexer match produces typed keyword
   tokens; parser diagnostics quote their validated source spans. The inverse
   and round-trip inventory are gone. Production shrinks by 26 lines; accepted
   allocations are unchanged and corpus instructions rise 0.246224%, below 0.5%.
3. **Escaped one-line test programs. Complete.** Aligned multiline strings show
   syntax and indentation, with exact byte comparisons and terminal-LF/tab
   mutation oracles. Malformed whitespace and useful short byte fragments retain
   quoted escapes.

## Paused milestone branches

Work stopped at the quality reset. Every branch is local, and each needs a
reviewed plan before it resumes.

| Branch | SHA | Content | Note |
| --- | --- | --- | --- |
| `blorp2/join-carried` | `712b02cd2` | M2.1b WIP: joins that carry reassigned outer `var`s | Lifts the `JoinArmReassignment` staged rejection; M3's loop carriers reuse it |
| `blorp2/constants` | `cc07e5f19` | M5 WIP: module-level constants | Approved design: 89 constants, `ConstantId`, closed `ConstantTerm`, materialised at use, moving to static data when CTFE lands |
| `blorp2/patterns` | `23cd9ccde` | M2b WIP: decision-tree match compiler core and witnesses | Not wired in. The `_`-only and imported-constructor rules above change what it must accept |
| `blorp2/namespace-kinds` | `b03020802` | Superseded namespace patch | Its tests were the redesign's behaviour spec. Delete it after the stack lands |
| `blorp2/question-bind-values` | `adc924ee6` | Superseded narrow `?=` rule | Delete |

Decided changes to milestones:
- **Char goes in M6.** It unblocks `lex.brp`'s Char literals in the frontier.
  Until then, compiler source compares bytes through named Int constants, as in
  `parse.brp`'s `BACKSLASH_BYTE`.
- **M2.3 needs no join-arm `?=` early return**, as stated above. Function-top-level
  propagation still needs a function return that discharges live owners.
- **M0's open managed-call recursion items** become M3 debt, as stated above;
  M4 owns recursive data storage and destruction.

## Decision log

All decisions are Keith's, made on 2026-10-15 and 2026-10-16.

| Topic | Decision |
| --- | --- |
| Constructors | Unique per module scope, declared, imported or from the prelude: "There must not be ambiguity." "Everything in scope." |
| UFCS | Same-named receiver functions are fine when receivers differ; a clash when they can overlap; no bounds code; prelude names reserved per receiver type |
| Re-export | "Re-exporting is not allowed. We need to fix that." |
| Failed dependencies | A module that imports a failed module reports nothing |
| Repeats | A repeated selection is a parser error; a repeated import an assembly error |
| Keyed scopes | Accepted; IntMap is deleted when a dict exists; dicts only with Int or Float keys |
| Rewrite latitude | "The end result must be clearer and cleaner than what we have today" |
| Illegal states | "Make illegal states unrepresentable": narrow result types |
| `?=` | Only at a function body's top level |
| Flat recursion | "Just do the mechanical rewrite of all the sites"; the functions stay recursive |
| Shadowing | Enforced (A1) |
| Pattern constructors | Must be imported |
| Catch-all | `_` only |
| Private types | Not in public signatures, fields or payloads |
| Module aliases | Stay: "Module aliases should be allowed" |
| Runtime Option/Bool | "It must be the prelude's Option or Bool"; "enforce it once for now", with a comment (landed `bd8b39775`) |
| Char | In M6 |
| Host compiler | "It can be more or less frozen" |
| Process | Plans reviewed before code; "each change should be getting multiple reviews"; holistic fixes, not more patches |
