# Stage 06 Latency Reduction Roadmap

**Status:** Ready for incremental implementation

**Profile baseline:** `e80ac7e619a9f2f7c3f6e005cd53c36520118c8d`

**Scope:** Compiler latency through Stage 06, including the Stage 07 CTFE work
that Stage 06 requests while producing typechecked artifacts. C emission and C
compiler latency are outside this roadmap.

## Objective

Reduce the latency and allocation volume of the compiler's frontend on a real
compiler self-check without reopening the broad representation migrations that
previous profiles rejected.

The roadmap deliberately starts with exact, measured repeated work. Each issue
has its own semantic boundary, counters, rollback point, and acceptance gate.
No issue depends on optimistic wall-clock timing alone.

## Current Production Profile

The representative workload is:

```bash
bin/blorp check --no-format blorp/src/main.brp
```

At the baseline revision this checks a graph with approximately:

- 353 modules;
- 16,113 declarations;
- 1,732 resolved imports; and
- 9.88 MiB of source.

An optimized (`-O2`) compiler took approximately 11 seconds on the profiling
host. Absolute wall time varied with host temperature and frequency, so the
stable result is the sampled share and the exact operation counts:

| Area | Optimized sample share |
| --- | ---: |
| Stage 06 typechecking | 74.03% |
| Stage 07 CTFE requested by Stage 06 | 10.34% |
| Stage 03 parsing | 7.92% |
| Stage 02 lexing | 5.83% |
| Stage 04 plus pipeline coordination | 1.89% |

Stage 06 plus its CTFE dependency is therefore about 84% of the measured
frontend. The adapter boundary itself is effectively free. Previously dominant
scope publication is no longer the main problem: `scope_add_symbol` fell from
roughly 13% in the older profile to less than 1% here.

The current opportunities are:

| Order | Issue | Direct evidence | Expected whole-check opportunity |
| ---: | --- | --- | ---: |
| 1 | [62: Use exact constructor-skeleton lookup](62-use-exact-constructor-skeleton-lookup.md) | 3,429 full projections across 19,666 skeletons | likely 2-5% |
| 2 | [63: Make CTFE constructor resolution typed and module-stable](63-make-ctfe-constructor-resolution-typed-and-module-stable.md) — implemented | typed binders were reclassified through a target-first name list | correctness prerequisite completed; name-only catalog deleted |
| 3 | [64: Evaluate CTFE dependency globals once per graph](64-evaluate-ctfe-dependency-globals-once-per-graph.md) | 1,748 dependency evaluations for 157 artifacts | likely 3-8% |
| 4 | [65: Index type-home state](65-index-type-home-state.md) | about 215,000 linear finds and 215,000 writes | likely 1-3% |
| 5 | [66: Canonicalize accepted semantic-type projection](66-canonicalize-accepted-semantic-type-projection.md) | accepted phase is 13x the next isolated phase; alias-depth scaling is superlinear | measurement-gated |
| 6 | [67: Index remaining CTFE environment lookup](67-index-remaining-ctfe-environment-lookup.md) | binding scans consume about 5.4% before Issue 64 | measurement-gated after Issue 64 |

The percentages overlap and must not be added. Each issue must refresh its
baseline after the preceding issue lands.

## Intended End State

```text
DeclarationSkeletonGraph
  exact constructor identity lookup
              |
              v
TypeHeaderGraph and accepted declaration products
  exact indexed type homes
  canonical semantic projection where reuse is proven
              |
              v
typed-AST-authoritative CTFE constructor resolution
              |
              v
one graph-owned CTFE dependency-global environment table
              |
              v
artifact-local target-program global rewriting
  indexed lexical/global lookup
```

This preserves the existing phase boundary:

- Stage 06 owns parsing-independent semantic checking and typed artifacts.
- Stage 07 owns compile-time evaluation.
- Stage 06 may schedule Stage 07, but must not duplicate its evaluator or move
  evaluation rules into the typechecker.
- Durable declaration and module identity remains authoritative. No issue may
  infer identity from names, paths, generated C symbols, or source formatting.

## Shared Correctness Invariants

Every issue must preserve:

1. accepted and recoverable graph behavior;
2. exact `ModuleId`, `TypeId`, `ConstructorId`, and definition identity;
3. source-order diagnostics and their source spans;
4. private/public visibility and local-over-imported precedence;
5. deterministic overload, alias, and constructor resolution;
6. CTFE rejection of self, later, runtime-initialized, and cyclic globals;
7. debug-only visibility policy;
8. fresh body-local inference and mutable-local CTFE state;
9. byte-identical successful compiler output for the same request, except for
   an issue's explicitly named correctness regression whose new expected result
   is pinned before implementation; and
10. no new leaks or graph-lifetime retention of session-local state.

## Shared Measurement Protocol

### Stable evidence first

Each implementation begins by adding temporary or test-owned counters for the
specific repeated operation it removes. Counters are more stable than wall
time and make regressions actionable in CI.

At minimum record:

- operation requests;
- unique semantic keys;
- candidates or nodes visited;
- cache/index hits and misses where applicable;
- allocations and releases in the owned profile window; and
- a semantic checksum or exact output hash.

Temporary production counters, switches, and alternate implementations must be
removed before merge. Deterministic counters that protect an architectural
bound may remain in a focused benchmark or test fixture.

### Controlled whole-compiler comparison

For every issue:

1. build baseline and candidate compilers with the same pinned bootstrap and
   optimization level;
2. run at least five alternating baseline/candidate pairs;
3. discard only a clearly documented cold-start run, not inconvenient samples;
4. compare medians for elapsed time and peak RSS;
5. compare deterministic allocations, releases, retired instructions when
   available, and the issue-specific operation counters; and
6. require identical exit status, diagnostics, and output hash outside any
   explicitly named correctness regression. The compiler self-check itself must
   remain identical.

Use the production-shaped command:

```bash
<compiler> check --no-format blorp/src/main.brp
```

Do not use a full replay response's JSON serialization time as compiler latency.
Target-only replay is suitable for header/graph work but does not represent the
full dependency CTFE path. The direct optimized self-check is the final arbiter.

### Focused profile commands

The maintained Stage 06 phase benchmark supports:

```bash
bin/blorp run --release \
  blorp/benchmark/compiler/compiler_typecheck_phase_profile.brp -- \
  headers 20 8 32 64 4 memory

bin/blorp run --release \
  blorp/benchmark/compiler/compiler_typecheck_phase_profile.brp -- \
  accepted 10 8 32 64 4 memory
```

The CTFE dependency benchmark supports:

```bash
bin/blorp run --release \
  blorp/benchmark/compiler/compiler_ctfe_typecheck_profile.brp -- \
  5 24 32 retained
```

An issue may extend these fixtures with a narrowly named metric. It must not
make a synthetic workload exercise an otherwise unused production path merely
to manufacture a performance win.

## Sequence and Dependencies

### Issue 62: constructor lookup

Start here. It is a local Stage 06 change with a direct proof of unnecessary
work and no dependency on later representations. Its result also makes the
type-header portion of later profiles easier to interpret.

### Issue 63: typed and module-stable CTFE constructors

Implemented after Issue 62's measurement checkpoint. Stage 07 now treats typed
binding and constructor decisions as authoritative, resolved constructors carry
an explicit issuing-table domain, and the target-first name-only catalog has
been deleted. Dependency global evaluation is now stable across requesting
artifact order, satisfying Issue 64's correctness prerequisite.

### Issue 64: graph-owned CTFE global evaluation

Implement only after Issue 63 proves dependency evaluation is module-stable.
This issue changes evaluation lifetime and needs an uncontaminated profile. It
is distinct from rejected Issue 35: typed CTFE dependency preparation is
already deduplicated; evaluated global environments are not.

### Issue 65: type-home index

Implement after Issue 64. It is semantically independent, but both changes
touch prepared typecheck facts and their performance shares overlap. Serial
integration keeps the attribution honest.

### Issue 66: accepted semantic projection

This is measurement-gated. First reprofile accepted graph construction after
Issues 62-65. Implement a cache only if exact duplicate projection work remains
large in the production self-check and a key can be represented without string
or source-shape heuristics.

### Issue 67: remaining CTFE environment lookup

Implement last. Issue 64 should eliminate many environment queries entirely.
Recount the remaining operations before changing `CtfeEnv`; reject the issue if
the residual share is small. Constructor lookup is not bundled here: Issue 63
owns its typed-identity correction and removal.

## Merge Discipline

Each issue is one independently revertible change. An issue may contain several
TDD checkpoints, but the final commit must:

- have one authority for the migrated lookup or evaluation result;
- delete the superseded scan/rebuild path;
- contain no runtime strategy flag or compatibility fallback;
- preserve all semantic checks and diagnostics;
- pass its focused tests and `scripts/compiler-check --changed`;
- pass `scripts/compiler-check --stage typecheck` for Stage 06 work;
- pass the relevant CTFE and leak suites for Stage 07 work; and
- record before/after measurements in the issue document or commit message.

If an implementation misses its issue-specific performance admission or
acceptance gate, remove the candidate and restore the original production
implementation, retaining only useful tests or profiling improvements.
Complexity is not justified by an unmeasurable win.

## Roadmap Completion Criteria

The roadmap is complete when:

- type-header construction performs no graph-wide constructor projection per
  variant;
- CTFE treats typed name patterns as bindings and uses typed constructor
  identity without consulting a target-owned name list;
- every dependency module's CTFE global environment is evaluated at most once
  per graph and policy;
- type-home lookup and replacement perform no linear list scan;
- accepted semantic projection has either been made demonstrably closer to
  linear in alias depth or rejected with production evidence;
- residual CTFE environment lookups are indexed or proven too small to justify
  the representation cost;
- every accepted issue reduces deterministic work and does not regress Stage
  01-06 wall time by more than normal measurement noise; and
- a final optimized self-check profile identifies the next bottleneck rather
  than assuming these historical shares remain current.
