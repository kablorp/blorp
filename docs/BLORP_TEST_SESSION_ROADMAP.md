# Blorp-Owned Test Session Roadmap

Status: active execution roadmap for checkpoint 4 of the
[compiler port roadmap](BLORP_COMPILER_PORT_ROADMAP.md).

Rebased on `main` on 2026-08-04. The retained frontend graph and direct
single-suite compile/execute candidate now exist. Typechecking Phase 1 also
landed opaque, module-scoped identities and an indexed graph. Production
`blorp test` still delegates to OCaml, while the candidate now uses scoped
process sessions for host-C compilation and native execution. Cancellation is
injectable and covered across cold runtime-cache preparation, host-C
compilation, and native execution, but invocation-level signal ownership and
production routing remain open. The immediate migration boundary is therefore
merging and releasing the process foundation, rotating the bootstrap, adding
one signal broker, and making a narrow production cutover, not another
source-store abstraction.

This roadmap covers the migration of `blorp test` from the OCaml host to a
Blorp-owned, invocation-local compilation session. It is intentionally more
detailed than the parent roadmaps because this migration crosses frontend
artifact ownership, graph-wide identities, whole-program Core compilation,
native process supervision, doctest source mapping, and test-result framing.
Delete this file after the production route has moved and its durable contracts
have been folded into [ARCHITECTURE.md](ARCHITECTURE.md).

## Outcome

One `blorp test` invocation must:

1. discover the source graph once and parse each logical source identity once;
2. retain structural module surfaces and finalized frontend programs in Blorp
   values;
3. reuse standard-library, package, and test-module artifacts whenever their
   semantic compatibility keys match;
4. construct combined harnesses at explicit compilation-compatibility and
   harness-mode boundaries, with execution isolation applied independently;
5. compile each compatible batch without launching another Blorp compiler;
6. use per-suite native child processes only where process or filesystem
   isolation requires them;
7. preserve current diagnostics, ordering, timeout, cleanup, and result
   behavior; and
8. remove the `test` command's dependency on `blorp-ocaml-host`.

The C compiler and generated native test executables remain external processes.
Avoiding those boundaries would require an interpreter, JIT, or dynamic loader
and is not part of this migration. The process-count target is therefore zero
OCaml hosts, zero nested Blorp compilers, one native execution per compatible
shared batch, and one native execution per suite that requires isolation.

## Non-Goals

- A persistent compiler daemon or reuse between separate CLI invocations.
- A persistent test-result cache before exact transitive source manifests exist.
- Changes to source-language test declarations or the `TestSuite` API.
- Reworking inference, Core semantics, ownership, or backend optimization solely
  for this migration.
- Removing the OCaml runner before production parity and rollback criteria pass.
- Collapsing the entire test tree into one unbounded Core program or native
  binary.
- Hiding semantic isolation behind file-count, path-prefix, or timing heuristics.

## Current Architecture

The production path currently is:

```text
blorp test
  -> Blorp CLI planning
  -> blorp-ocaml-host
  -> OCaml discovery, classification, grouping, and reporting
  -> for each generated harness:
       nested blorp __compiler-build-synthetic-executable
       -> C compiler
       -> native test executable
```

The relevant owners are:

- [`compiler_cli_main.brp`](../compiler/blorp/src/stage_12_cli/compiler_cli_main.brp)
  routes `test` to the OCaml host.
- [`test_runner.ml`](../compiler/lib/test_runner.ml) owns production discovery,
  batching, harness compilation, native execution, timeout handling, doctests,
  and reporting.
- [`compiler_cli_test_discovery.brp`](../compiler/blorp/src/stage_12_cli/compiler_cli_test_discovery.brp)
  already has structural Blorp discovery and explicit isolation values.
- [`compiler_cli_generated_test_harness.brp`](../compiler/blorp/src/stage_12_cli/compiler_cli_generated_test_harness.brp)
  already generates selector and run-all harnesses.
- [`compiler_cli_test_plan.brp`](../compiler/blorp/src/stage_12_cli/compiler_cli_test_plan.brp)
  is a deliberately narrow, unwired single-suite candidate.
- [`compiler_cli_test_effect.brp`](../compiler/blorp/src/stage_12_cli/compiler_cli_test_effect.brp)
  compiles that candidate from its retained graph and returns typed captured
  execution data; production routing does not call it yet.
- [`compiler_cli_source_graph.brp`](../compiler/blorp/src/stage_12_cli/compiler_cli_source_graph.brp)
  discovers each source identity once and retains source text and finalized
  programs in `CliFrontendModuleGraph`. Compiler execution no longer requires
  parsed-, surface-, or typed-AST JSON artifacts.
- [`compiler_typecheck_bridge.brp`](../compiler/blorp/src/stage_06_typecheck/compiler_typecheck_bridge.brp)
  builds one target-specific `CompilerIndexedGraph` per request. The graph has
  opaque module-scoped definition keys, accepted loaded modules, and one owned
  definition index, but its prepared context is private and completed typed
  artifacts are not session-retained.
- [`compiler_core_graph_prepare.brp`](../compiler/blorp/src/stage_08_core_lower/compiler_core_graph_prepare.brp)
  lowers and flattens the selected typed graph into a whole-program Core value.

The current OCaml runner already combines ordinary suites, uses selector
harnesses for isolated suites, bounds generated-source batches, and uses
BEGIN/END heartbeat framing to apply timeout policy to the active suite. Those
behaviors are migration requirements, not evidence that the current ownership
or process boundaries should be retained.

## Constraints Discovered In The Existing Pipeline

### Frontend Artifacts

`CliFrontendModuleGraph` already retains source text, logical and physical
identity, origin, resolved import edges, and one `FinalizedTypecheckProgram` per
discovered source. Adding a generated harness parses only that synthetic root
and reuses the existing graph sources. `ModuleSurface` remains a
syntax-oriented declaration index, not a typed import interface. The remaining
source work is to make identity/digest policy explicit and instrument parse
counts; do not introduce a parallel `SessionSourceStore` record that copies the
same graph.

### Definition Identity

Phase 1 now gives every callable and source definition an opaque key containing
its canonical module identity and declaration facts, and dependency modules are
planned in canonical order. Integer IDs are still allocated within a
target-specific graph with the target first. Changing the generated harness
can therefore move dependency IDs even though the underlying definition keys
are stable. One generated compatible batch is safe; typed modules still cannot
be shared across separately built harness graphs until this remaining numeric
identity boundary is made explicit.

Generated harnesses also use fixed logical names today. Multiple retained roots
need distinct deterministic identities so diagnostics, callable keys, source
spans, CTFE facts, and Core symbols cannot collide.

### Semantic Closure

The graph loader makes a broad module set available and typechecking computes a
reachable semantic closure. The CLI currently still passes every graph module
as a target, and Core lowers every selected typed module. A session-wide source
store is therefore not itself a semantic universe, and "exact closure" is not
one current pipeline value. The session must distinguish the name-resolution
closure, transitive CTFE closure, and batch compile/Core closure. Unrelated
discovered test files must not alter any of them, name resolution, trait
selection, diagnostics, or definition identity.

### Typed Imports And CTFE

The current import artifact carries parsed declarations. Each consumer rebuilds
imported types, signatures, traits, and implementations from those declarations.
Retaining a completed module without retaining this import-registration work
would produce an impressive reuse counter while leaving substantial repeated
typechecker work in place.

CTFE reuse is also root-dependent today: a dependency or prelude that imports
the current target cannot reuse an evaluation prepared for another target.
Checked source modules and evaluated source modules must therefore be different
artifact phases with different keys.

### Whole-Program Core

Core preparation lowers all selected modules and the generated target into one
program. Monomorphization, dead-code elimination, ownership analysis, and
backend emission remain whole-program work. Retaining typed modules removes
frontend rebuilding but does not make an arbitrarily large combined Core graph
safe or fast. Semantic isolation determines what may be combined; measured
resource limits may further subdivide a compatible partition without changing
its semantics.

### Process Supervision

The structured Blorp process API is blocking and does not yet expose the
streamed stdout/stderr events needed for per-suite heartbeat timeouts in a
shared binary. The current host boundary also has weaker signal forwarding than
the structured process abstraction. A test-specific execution effect must own
process groups, concurrent output draining, timeout escalation, output limits,
signal propagation, exit classification, and temporary-artifact cleanup before
the production route moves.

### Doctests

Parsed Blorp declarations retain documentation and source spans, so extraction
can be Blorp-owned. Typecheck errors are still commonly consumed as rendered
strings. Correct doctest diagnostics require structured spans and an explicit
synthetic-to-origin source map; parsing rendered diagnostics is forbidden.

## Architectural Decisions

### One Invocation-Local Session

Introduce a `CompilerTestSession` owned by the `test` command. It is created
after CLI validation and destroyed before command exit. It contains no global
mutable cache and cannot survive into another invocation.

The session has four conceptually separate stores. The first begins as an owned
`CliFrontendModuleGraph`; it is not a second frontend representation:

1. `SessionSourceStore`: an ownership wrapper around the retained frontend
   graph plus physical/logical identity, parser mode, raw digest, and planned
   use counts that are not yet represented by that graph.
2. `SessionSemanticUniverse`: deterministic definition identities, exact import
   graph, ambient-module configuration, checked module artifacts, typed import
   interfaces, evaluated module artifacts, and structured diagnostics.
3. `SessionCompileStore`: generated-root identity, selected typed closure,
   prepared Core, emitted C, and native artifact for one compatible batch.
4. `SessionExecutionState`: scheduler state, process handles, output framing,
   temporary directories, suite results, and counters.

These may be separate records or modules rather than one large record. The
separation is an ownership rule: source and shared typed artifacts can outlive a
batch; Core and native artifacts cannot be reused across incompatible roots;
process state must never leak into compiler-pure APIs.

Every retained artifact has a planned-use count and an explicit last-use
release point. Shared std/package import interfaces may live for the invocation.
Suite-only checked/evaluated roots are released after their final batch. Core,
emitted C, native binaries, and captured output are bounded to the explicit
in-flight window, then released or unlinked immediately. Instrument current and
peak live source bytes, parsed nodes, typed nodes, Core declarations, emitted C
bytes, and captured output so lower CPU time cannot conceal unbounded session
RSS.

Compilation is demand-driven through a bounded producer/consumer window.
Queued batches retain plans and keys only. Through cutover, at most one batch
retains prepared Core or emitted C, and at most the effective execution-worker
count retains native binaries or execution state; sanitizer mode retains one.
Completed results retain fixed-size metadata and bounded spool references rather
than all captured output in memory. Release Core and emitted C after C
compilation, and unlink native artifacts and output spools after final reporting.

### Explicit Compatibility Keys

Every reusable typed artifact needs a structural key. At minimum it includes:

- physical file identity, logical module identity, display path policy, parser
  mode, and raw content digest;
- compiler semantic/version identity;
- resolved package and standard-library source identities;
- exact direct-import identities and imported typed-interface fingerprints;
- ambient module and prelude configuration;
- target-independent language options that affect parsing or typechecking; and
- the identity policy for graph-wide definitions.

Effective test debug policy, sanitizer, leak instrumentation, target ABI,
native features, C flags, and link inputs belong to the compile key, not the
frontend key, unless they demonstrably change source semantics. Current profile
mode is reporting policy and does not change the compile key. Keep these key
types distinct so adding a backend or reporting option does not silently
invalidate or, worse, incorrectly reuse a typed module.

Do not deduplicate parsed programs by digest alone: paths, nominal module names,
source text, and spans are embedded in parsed values, and one physical source
can have multiple logical package identities. Do not use timestamps, list
positions, direct-root-only hashes, or path-prefix guesses. Source
normalization, symlink treatment, duplicate roots, package identity, and case
sensitivity must be characterized from current behavior and represented by
constructors that reject ambiguous identities. Initially every raw-byte change,
including comments, invalidates checked artifacts because spans, definition
keys, doctests, and diagnostics can change.

### Stable Definition Universe Before Typed Reuse

Typed reuse is gated on extending the existing opaque definition-index design,
not building an independent session identity system. `CompilerIndexedGraph`
already supplies module-scoped definition keys, collision rejection, canonical
dependency planning, and graph-compatible prepared scopes. Its integer IDs are
still target-first and graph-local. Do not retain typed modules from one graph
inside another or add graph-local remapping.

Delay this change until the direct single-suite route and combined compatible
batches are measured. Most suites can then inhabit one generated-root graph and
need no cross-root typed reuse. If separately compiled isolation batches still
spend material time rebuilding shared type work, introduce a graph-owned base
universe plus generated-target overlay as a coordinated typechecking-roadmap
slice. Preserve opaque module and definition keys and make the overlay
relationship directly validated.

The future base-universe overlay must:

1. preserve the resolved opaque module identity already produced by loading;
2. use the existing opaque declaration keys rather than inventing session-local
   key spelling;
3. keep imported IDs stable when a generated root changes;
4. give each generated root an identity derived from its mode, ordered suite
   set, isolation partition, and source digest;
5. record base-universe and target-overlay identity plus the high-water mark in
   every retained artifact;
6. place generated and batch-local roots in a separate non-colliding namespace;
   and
7. validate that every callable/source key and integer ID belongs to the
   retained base plus its exact target overlay.

Never retain a typed tree whose IDs refer to a discarded graph-local table.

### Explicit Root Closures

Materialize a `ResolvedRootClosure` from resolved edges, prelude policy, ambient
modules, and canonical module order. It owns three explicit selections:

- `NameResolutionClosure`: declarations visible while checking the root;
- `CtfeClosure`: target/prelude dependencies whose evaluation affects the root;
  and
- `BatchCompileClosure`: checked/evaluated modules selected for Core lowering.

Only the canonical batch compile closure may reach Core. Generated harnesses
must be dependency-graph leaves: retained source and implicit modules may not
import a generated root. If that invariant cannot be established for a graph,
CTFE is evaluated fresh for that root and the artifact is not published.

### Phase-Specific Typed Artifacts

Replace ambiguous state such as `ctfe_evaluated: Bool` at the session boundary
with phase-specific values:

- `CompilerCheckedModule` contains the finalized typed program before CTFE
  materialization;
- `CompilerTypedImportInterface` contains canonical public types and
  signatures, trait/impl registrations, CTFE export declarations, definition
  identities, and explicit direct-versus-transitive application rules; and
- `CompilerEvaluatedModule` contains a checked module plus values evaluated
  under a transitive CTFE environment key.

`CompilerTypedImportInterface` is a new semantic artifact, not a renamed
`ModuleSurface`. Build it under parity tests before using interface fingerprints
to narrow compatibility. The initial low-risk key is conservative: the frozen
resolved closure's raw digests and import syntax. Interface-only invalidation
belongs to a future cross-invocation incremental compiler roadmap.

Wrap retained artifacts with source identity, origin, rewritten import
configuration, closure key, definition-arena identity, typed phase, CTFE key,
import bindings, and structured diagnostics. Cache only completed artifacts;
import cycles and failures keep graph-level diagnostics and never publish a
partial SCC.

### Graph-Level Validation

Before lowering a batch, validate the assembled typed graph as a whole:

- all referenced callable, constructor, trait, implementation-target, and
  definition IDs belong to the retained arena;
- imported typed-interface fingerprints match;
- trait and overload environments match the module's key;
- CTFE values refer only to retained compatible definitions;
- source spans point into retained source identities; and
- generated/Core names are collision-free and the generated root is a leaf.

This validation is initially enabled in all tests and debug builds. It may be
made cheaper in production only after counters and sanitizer coverage show that
the construction boundary is reliable.

### Separate Compilation, Harness, Isolation, And Resource Decisions

Represent four typed planning decisions rather than one overloaded isolation
value:

| Decision | Purpose | Representative inputs |
| --- | --- | --- |
| `CompilationCompatibilityKey` | What can inhabit one generated program | Effective always-debug test policy, sanitizer/leak instrumentation, target/native features, link inputs, std/package identity |
| `HarnessMode` | How suites are invoked from that program | Run-all or selector |
| `ExecutionIsolation` | What must be fresh for each suite | Shared process, fresh process, or fresh cwd/`TMPDIR` |
| `ResourceBatch` | How a compatible compile is bounded | Ordered source-byte budget through cutover |

Execution isolation must be data produced by discovery or a named test policy
table. Existing path-based policy may be preserved at that one construction
boundary during migration, with tests for normalization and precedence; later
work can replace it with declared metadata. "Fresh filesystem" means a unique
cwd and `TMPDIR`, not a sandbox: absolute filesystem access and the rest of the
inherited environment remain available.

Preserve the current deterministic run-all budgets through production cutover:
256 KiB when unsanitized and 128 KiB when sanitized. The legacy selector path
has no source-byte budget and groups suites by isolation root. Preserve that
observed grouping for parity through cutover only as a named migration resource
policy, not as semantic compilation compatibility.

Record typed-node count, Core size, emitted C size, phase latency, and
process-tree RSS per batch. Tune batching only in a separate post-cutover
change. The resource batcher may subdivide only within a matching
(`CompilationCompatibilityKey`, `HarnessMode`) partition.
`ExecutionIsolation` controls process, cwd, and `TMPDIR` behavior; it does not
itself make compatible suites ineligible to inhabit the same selector binary.

### Extend The Structured Process Subsystem

Add a cancellable streaming process session beside `std/process`, then add a
narrow test-runner adapter. The first implementation lives in
`std/process_session` because the pinned bootstrap compiler predates its runtime
operations and the production compiler CLI imports `std/process`; both modules
share one runtime preparation and spawn foundation. Merge the public modules
only after a bootstrap rotation can compile the session operations. Do not
create a competing runtime primitive or teach pure compiler stages about
processes. The same session API must be usable for C compilation so interrupts
are correct on both sides of native execution. Its contract must include:

- executable, arguments, cwd, and an explicit environment overlay;
- a new process group and retained process handle;
- concurrent stdout/stderr streaming without pipe deadlock;
- line framing that tolerates split reads and a final unterminated line;
- a dedicated inherited bidirectional control transport carrying
  length-prefixed, versioned suite/test records and parent acknowledgements;
- run-all inactivity deadlines reset only by valid control records;
- graceful termination followed by bounded forced group termination;
- scoped SIGINT/SIGTERM handling, child cancellation, handler restoration,
  guaranteed reaping, and shell-compatible 130/143 command exits;
- per-suite retained-output limits that continue draining and discarding after
  truncation, plus separate bounded unscoped-output and control-channel limits;
- exit, signal, timeout, spawn failure, and protocol failure as distinct values;
  and
- cleanup registered before process launch and run on every exit path.

One invocation-level cancellation broker installs process-global handlers once,
registers every active C compiler and native process group, fans cancellation
out to all registered groups, waits for reaping, and restores prior handlers
after the registry is empty. Individual process sessions must not race by
installing and restoring their own handlers. Test interruption with multiple
native workers and a C compiler active concurrently.

Stdout and stderr remain raw bytes and preserve ordering only within each
stream. They are never control messages and need not be valid UTF-8. The
control transport endpoints must not leak to processes spawned by a test. Unknown,
duplicate, out-of-order, oversized, and missing records are protocol failures
with the implicated suite reported.

In run-all mode, the harness emits `SuiteBegin` and waits for `Start`; the
parent marks that suite active before acknowledging. At completion, the harness
flushes stdout and stderr, emits `SuiteEnd`, and waits for `Continue`. The parent
keeps that suite active, drains both output streams to `EAGAIN`, then
acknowledges; the harness must not begin the next suite before that
acknowledgement. Shared-process eligibility requires that a completed suite
leave no background writer able to emit after `SuiteEnd`. These barriers are
required because separate descriptors provide no cross-stream ordering.

Model inherited descriptor mappings explicitly in the process session. The
parent allocates the pipe and passes the write endpoint to the native harness;
the compiler-owned harness/runtime helper marks it close-on-exec before user
test code can spawn descendants. Pass the selected descriptor as generated
harness configuration, not a fixed descriptor number, magic environment value,
or new public source-language API.

Generated harnesses own structured test-event production. A compiler-owned
reporting layer must observe each `TestSuite` entry structurally and emit
`SuiteBegin`, `TestResult`, and `SuiteEnd` while preserving existing `std/test`
rendering. It may refactor shared runner internals, but must not change
`TestSuite` or require user test changes. `TestResult` must never be synthesized
by parsing stdout.

Keep deadline meanings separate. User `--timeout` remains a native execution
timeout and `0` disables it. Selector execution uses one execution deadline;
run-all uses an active-suite inactivity deadline. C compilation remains outside
that user timeout unless a separately named compile deadline is introduced.
An optional invocation deadline, if added later, is another explicit setting.

A fatal shared-batch crash, timeout, or protocol error aborts that native
process. During migration, report the active suite as failed and unstarted
suites as not run, matching characterized behavior; do not silently reschedule
them because that can duplicate side effects. Any future retry policy requires
an explicit option and separate semantics.

Process-group cleanup covers descendants that remain in the group. A descendant
that deliberately creates a new session cannot be killed portably and is
outside the guarantee. Cleanup failures are reported. Retained-artifact debug
mode and uncatchable host termination are explicit exceptions to immediate
artifact deletion; add stale-run cleanup for leftovers from SIGKILL or host
failure.

Stale cleanup owns a private per-invocation run root with an owner lock/lease,
creation time, and optional retained marker preserving current
`BLORP_TEST_RETAIN_RUN_ARTIFACTS=1` behavior. It only removes unlocked,
unretained roots older than a named minimum age. It never follows symlinks and
verifies canonical containment before every deletion, so a concurrent active
invocation or crafted directory entry cannot be removed.

### Doctests Are Synthetic Sources With Provenance

Represent each extracted doctest as structured data containing the owning
source identity, declaration identity, original span, generated span, imports,
and test body. Generate a synthetic source plus a segment source map. Carry
structured diagnostics through typecheck and remap spans before rendering.

Doctests may share retained source and standard-library artifacts, but their
generated roots have the same uniqueness and compatibility requirements as
ordinary harnesses. Multiple examples in one declaration, tabs, blank lines,
interpolation, imported names, and diagnostics spanning generated wrapper text
need focused fixtures.

### Characterized Option Semantics

Preserve current public behavior until a separate change intentionally improves
it:

- there is no test `--release` mode;
- current `--debug` does not select a different test compilation because test
  harnesses are already compiled with debug behavior;
- current `--profile` changes test reporting rather than compiler optimization;
- sanitizer execution is single-worker;
- automatic macOS scheduling remains capped at four workers until separate
  code-signing stability evidence justifies a change;
- repeated execution stops after the first failing iteration;
- `--timeout 0` disables the native execution timeout;
- `BLORP_TEST_TIMEOUT` and `BLORP_TIMEOUT`, `BLORP_SANITIZE`,
  `BLORP_LEAK_CHECK`, `BLORP_NO_FORMAT`, and `BLORP_GATE_RESULT` retain their
  documented precedence with CLI options;
- `BLORP_TEST_RETAIN_RUN_ARTIFACTS=1` preserves run artifacts for debugging and
  marks them ineligible for stale cleanup;
- formatting occurs before the immutable source snapshot is built;
- `--warmup-only` compiles the production warmup artifact but runs no suites;
  and
- `--no-cache` does not currently disable a hidden persistent test-result cache,
  because that cache is not active.

### Session Reuse Is Not A Result Cache

Invocation-local values are released when the command exits and need no
persistent invalidation protocol beyond structural compatibility keys. Keep
`--no-cache` behavior correct and keep persistent test-result caching disabled
until compilation returns an exact transitive manifest of normalized relative
paths plus raw source bytes and every non-source input affecting the artifact.

Treat cache layers separately:

| Layer | Lifetime | Control during this roadmap |
| --- | --- | --- |
| Frontend/test session artifacts | One `blorp test` invocation | Always structurally keyed; a test-only reuse-disabled mode exists only for attribution benchmarks |
| Persistent test results | Cross-invocation | Disabled; current `--no-cache` must not be misreported as making other caches cold |
| Runtime/native support artifacts | Cross-invocation validated cache | Existing `BLORP_RUNTIME_CACHE`/warmup policy; isolate its namespace for cold measurements |
| OS filesystem/page caches | Host-controlled | Not called cold; pair and alternate benchmark runs |

The new session must report whether reuse came from the current invocation or a
pre-existing native cache. A cold benchmark uses a fresh isolated runtime-cache
namespace with no warmup; `--no-cache` alone does not establish that state.

## Incremental Execution Plan

Each slice is independently mergeable. Move the exact eligible single-suite
public route after Slice 1 passes, while unsupported modes continue through the
OCaml runner. Expand that internal eligibility boundary after each parity gate;
do not expose a user-facing legacy-runner switch. Slice 7 is the complete
cutover, not the first production use. Compare moved and legacy shapes on the
same revision while both remain available internally.

The rebased critical path is:

1. move C compilation and native execution onto the scoped process session,
   add invocation-level cancellation, and prove cleanup under interruption;
2. route the exact narrow single-suite shape already represented by
   `CliBlorpTestSuitePlan`, preserving raw child output and exit behavior;
3. measure that production route before adding reuse machinery;
4. complete the existing typed control transport and generated events, then
   move compatible multi-suite batches and isolation scheduling;
5. move doctests and remaining option/reporting shapes; and
6. add cross-root typed reuse only if counters show meaningful repeated
   typechecking after compatible suites have already been combined.

### Slice 0: Characterization And Instrumentation

Add a deterministic benchmark driver, proposed as
`scripts/bench-blorp-test-session`, that can run the current and candidate
routes with identical arguments and record machine metadata, revision, command,
mode, cache state, exit status, wall time, peak RSS, and session counters under
`benchmarks/results/`.

Extend `BLORP_TEST_TIMINGS=1` or an internal equivalent to report:

- files discovered and unique source identities;
- source bytes read, parses, surface builds, and finalized programs;
- definition arenas, checked modules, reused checked modules, typed import
  interface builds/applications, `typecheck_import_decls` work, and CTFE runs;
- harnesses, semantic partitions, resource batches, and Core preparations;
- nested compiler, C compiler, and native execution process counts;
- current/peak live parsed nodes, typed nodes, Core declarations, emitted C
  bytes, captured output, aggregate process-tree RSS, and native cache hits; and
- discovery, frontend, Core, C compilation, execution, and cleanup time.

Record baselines for a tiny single suite, a mixed isolation fixture, the full
`compiler/blorp/tests` tree, representative runtime/std directories, doctests,
leak checking, and sanitizer mode. A baseline is invalid when another compiler
gate is contending for the machine, the route differs, cache state is unknown,
or children survive the measurement.

Acceptance:

- counters add negligible time when disabled;
- output has a stable machine-readable form plus concise human timings;
- an interrupted run leaves no child process or repository artifact;
- the driver can compare routes without changing source files; and
- before any candidate measurements are inspected, the tiny-suite latency and
  compiler-suite aggregate process-tree RSS regression ceilings, minimum and
  maximum pair counts, confidence-interval precision rule, and policy for
  rejecting contended pairs are committed.

Current implementation status: `benchmarks/blorp_test_session_policy.json`
registers the exact tiny-suite latency and compiler-suite aggregate-RSS
workloads, a 10% upper-confidence-bound regression ceiling, a 10 percentage
point maximum interval width, 10-30 measured pairs, and at least 10,000
bootstrap samples. Registered runs hold an exclusive canonical per-user host
advisory lease; official build/test gates hold the shared side through
`scripts/with-build-lock`. The owner-only namespace rejects symlinks and foreign
ownership, and overrides are rejected for evidence. Registered comparisons use
even alternating pair counts and fingerprint the resolved OCaml host alongside
each route. Together these controls reject concurrent
participating compiler gates, not arbitrary machine load.
The legacy runner now produces one invocation-local harness plan shared by
execution, repeat runs, and mandatory benchmark counters. Those counters cover
planned run-all and selector harnesses, suites assigned to combined execution,
combined native executions, and source files left for individual handling.
Broader workload baselines, runtime/frontend work counters beyond the legacy
runner's direct ownership, and the non-forgeable control transport remain open
Slice 0 work.

The schema-v2 benchmark policy now also fixes commands, cache state, sample
counts, supervisor timeouts, and fingerprint inputs for the remaining required
characterization shapes. A dedicated eight-suite fixture provides deterministic
shared-import fan-out. The runtime shape uses an explicit compatible value-types
subset because the full types directory intentionally contains trait-name
collision fixtures that cannot share one combined harness. Characterization
runs hold the exclusive contention lease and record policy identity without
claiming comparison thresholds. Clean baseline result collection for every
catalog entry remains open. Registered characterization is baseline-only so
its three-run sample cannot be mistaken for balanced candidate evidence.

### Slice 1: Scoped Process And Single-Suite Cutover

Implement this as three mergeable sub-slices:

1. extend the structured process subsystem with a cancellable streaming
   session, covered by deterministic process tests;
2. move the candidate's C compiler and native child onto that session and add
   one invocation-level cancellation owner; and
3. route the exact eligible single-suite public shape through the Blorp
   candidate after output, exit, timeout, and cleanup parity pass.

Do not add a temporary OCaml, JSON, or nested-Blorp compiler boundary. The
existing typed control protocol is retained for Slice 5 multi-suite boundaries;
inherited control descriptors and generated events are not prerequisites for
reporting one suite whose complete native output and status can be forwarded
without parsing it.

Acceptance:

- single-suite pass, assertion failure, compile failure, crash, signal,
  execution timeout, timeout disabled with `0`, spawn failure, binary/huge
  output, and parent SIGINT/SIGTERM match the characterized public contract;
- C compiler and native child are cancelled and reaped before command exit;
- one invocation-level broker owns signal state and cancels the active C
  compiler or native process without handler-install/restore races;
- descendants remaining in the child process group are terminated on timeout
  and interrupt, with the new-session limitation documented;
- stdout/stderr are drained as bytes; test names, pass/fail counts, assertion
  output, and leak reporting match without parsing rendered `[PASS]`/`[FAIL]`
  text; and
- no temporary source, C file, binary, cwd, or process survives completion
  outside documented retain/SIGKILL cases, and lease-aware symlink-safe stale
  cleanup neither removes an active nor deliberately retained run.

Current implementation status: the pure incremental control-frame codec now
defines a fixed versioned header, typed event/acknowledgement frame kinds, a
one-MiB payload bound, split-read decoding, binary payload preservation, an
encoder-independent golden wire vector, and explicit malformed/truncated-stream
failures. The decoder retains bounded input segments so partial payloads are not
recopied after every read; one feed is bounded to 1 MiB plus its header, one
partial frame to 256 segments, and the feed-byte cap intrinsically bounds the
number of minimum-size frames without making validity depend on read
boundaries. Versioned typed payloads now carry suite identity/metadata,
structural per-test assertion and leak results, verified suite totals, and
correlated suite-boundary acknowledgements. The encoder allocates each payload
once at its checked exact size. Length-prefixed strings use allocation-free
UTF-8 validation and retain the overall one-MiB frame limit without a stricter
`TestSuite` label limit; the typed boundary rechecks that frame cap and
structural values are range-checked. Mirrored pure parent/child state machines
reject skipped, duplicated, stale, incomplete, or summary-inconsistent flows,
including leak results from a non-leak-check suite. The parent validates the
ordered planned paths and leak modes, and remains in an explicit pending state
until `Start` or `Continue` has actually been transmitted. `TestResult` does not
add a per-test round trip. The suite-boundary barriers deliberately leave
stdout/stderr outside the control channel so a future parent can drain arbitrary
output bytes before allowing the child to advance. Inherited descriptor
transport and generated harness event emission remain open for Slice 5.

The process foundation now has one shared structured-command preparation and
spawn primitive that owns transient strings, environment overlays, file
actions, attributes, and pipes, and returns an explicit child handle with
idempotent descriptor and reaping cleanup. Supported runtime platforms require
atomic `O_CLOEXEC` file creation; pipe creation uses the corresponding atomic
descriptor APIs, and remaining non-atomic descriptor creation participates in
the spawn synchronization boundary. Shell execution also releases that
boundary immediately after spawning instead of holding it for the command
lifetime.
Nullable managed `Option` fields now share one Core representation/cleanup
policy, which closes the environment-command ownership leak exposed by this
work for both blocking and streaming commands.

`std/process_session` now provides a scoped process resource, immutable command
customization, nonblocking stdin writes, bounded simultaneous stdout/stderr
polling, explicit stream readiness and lifecycle states, observable-lifetime
timeouts, aggregate capture limits, process-group terminate/kill operations,
and guaranteed close/reap cleanup. A deadline remains active after leader exit
while a descendant retains captured stdout or stderr; a silent descendant is
still terminated at scope exit but does not replace the leader's recorded exit
with a timeout. Focused normal, leak-check, and sanitizer
tests cover bidirectional environment-aware feedback, output exceeding pipe
capacity on both streams, timeouts, spawn failure, capture limits, idempotent
stdin close, process-group kill after both a live and an already-exited leader,
write backpressure recovery with exact input delivery, malformed commands, and
single-poll cleanup. Exit observation retains the unreaped group leader until
scope cleanup, so the process-group identity cannot be reused before descendant
termination. Poll waits convert the `Duration` microsecond representation at
the C boundary. Runtime-union metadata distinguishes typed integer constructor
arguments from pointer-erased integer payloads. The module remains separate
only for the bootstrap
boundary described above. Existing blocking process behavior remains the
production API. The structured-command adapter now streams byte stdin from an
offset without allocating a suffix after partial writes, accumulates bounded
output chunks, and preserves completion, interruption, and process errors as
distinct values. The single-suite candidate injects a session-backed artifact
runner, so both the host C compiler and native test executable use scoped
process groups; deterministic checkpoints interrupt both the active compiler
and a started native executable and return structured cancellation results,
while focused process-session checks verify reaping and bounded descriptor
cleanup. Runtime-cache compilation now accepts an injected typed command
executor. The production default preserves the blocking process path, while
the candidate injects the scoped session executor. Warm verified entries bypass
that executor; interrupted cold builds retain captured stdout/stderr, remove
their scoped staging tree, publish no partial entry, and never fall back to an
embedded runtime. Ordinary cache I/O or compiler failures retain the existing
best-effort embedded-runtime fallback. Focused cache and candidate tests cover
all four cases. Invocation-level SIGINT/SIGTERM brokerage and production wiring
remain open. Inherited control-descriptor mappings, the
dedicated bidirectional control transport, and generated harness event emission
remain open for Slice 5. An
unwired single-suite candidate now compiles directly from the retained frontend
graph, executes through the shared captured-program boundary, and returns typed
target/status/stdout/stderr results without another Blorp compiler process.
Its suite plan uses the production runner's effective always-debug compilation
policy, and the run-effect boundary projects `BuildArtifact` into a compact
carrier so typed/Core state and observations are released before C compilation
and native execution begin.
It must remain unwired until the invocation-level cancellation broker is in
place and the pinned bootstrap compiler has been rotated. The pinned
`dev-6bddc68c9ea2` bootstrap cannot emit the ProcessSession builtin bodies; the
production compiler still builds only because the candidate-only session runner
is unreachable from `compiler_cli_main`. After the process foundation is
merged and released, rotate `compiler/bootstrap.env`, add scoped handler
install/restore with shell-compatible 130/143 exits, then route only the exact
eligible single-suite shape. Keep the OCaml fallback for every ineligible
shape.

The candidate-effect checkpoint itself is not yet a valid strict per-test leak
gate. Running that compiler-heavy checkpoint with outer `--leak-check` reports
roughly 255,000 retained frontend objects at each test boundary even though the
process-level final summary returns to zero. The focused process-session suite
has zero leaks in normal, interruption, timeout, escaped-descendant, and
explicit-kill cases. Treat the candidate result as a frontend artifact lifetime
or measurement-boundary issue, not evidence of a live process resource; resolve
it before broadening the production route to leak-check mode.

### Slice 2: Retained Frontend Graph Hardening

Core implementation is present: `CliFrontendModuleGraph` retains raw text,
origin, resolved edges, and finalized programs, and generated-root insertion
reuses those values. Finish the slice by adding exact identity/digest and parse
counters, rejecting normalized aliases deterministically, and proving that the
candidate never reparses retained source. Keep formatter/raw-AST ownership
separate. Do not create a parallel source-store model.

Acceptance:

- each logical source identity for source, package, and std modules is parsed
  once in the candidate route;
- repeated roots and normalized aliases resolve to one explicit identity or a
  deterministic duplicate-input error matching characterized behavior;
- edits, changed comments, missing files, normalization, and package boundaries
  invalidate the right source artifact; and
- parser/typecheck diagnostics retain exact source paths and spans.

### Slice 3: Stable Typecheck Universe And Typed Reuse

Phase 1 of the typechecking roadmap completed the opaque module-scoped key and
indexed-graph prerequisites. Do not continue this slice on the critical path to
the first production test cutover. After direct batching is measured, land only
the independently justified sub-slices below, comparing fresh and retained
results after each and retaining no parallel representations:

1. expose the existing indexed graph's exact root closures and use only the
   canonical batch compile closure downstream;
2. convert retained typecheck and CTFE diagnostics to structured values keyed by
   `SessionSourceIdentity` and byte span, retaining rendering adapters that
   preserve current output;
3. if counters justify cross-root reuse, extend the indexed graph with a
   validated base-universe/generated-target overlay while typechecking remains
   fresh;
4. introduce `CompilerCheckedModule` and `CompilerTypedImportInterface`, first
   reusing std/shared imports and then suite modules; and
5. introduce `CompilerEvaluatedModule` with its separate transitive CTFE key and
   generated-root leaf check.

Make the prepared typecheck graph a deliberate API and add assembled-graph
validation before Core lowering. Do not claim reuse until mutation/ownership
audits prove retained values and side tables remain valid across roots. Do not
implement interface-only or cross-invocation invalidation in these slices.

Acceptance:

- permuting discovered suite order does not change source definition identity
  or diagnostics;
- two compatible roots reuse std/shared checked modules and typed import
  interfaces while distinct generated roots remain collision-free;
- retained and fresh modes produce equivalent structured artifacts for trait
  resolution, overloads, private exports, generics, import cycles, target- and
  prelude-dependent CTFE, and failure publication;
- counters prove imported declaration registration and CTFE work were removed,
  not merely relabeled as module reuse; and
- graph validation catches wrong arenas, closure keys, CTFE keys, imported
  interfaces, callable/constructor/trait IDs, and generated/Core collisions.

### Slice 4: Session-Native Harness Compilation

Feed generated harness roots and retained typed closures directly into the
ordinary Core pipeline. Remove nested
`__compiler-build-synthetic-executable` calls from the candidate route. Keep
whole-program passes and backend emission unchanged.

Current implementation status: complete for the unwired single-suite
candidate. It compiles the retained graph through the ordinary Core/backend
path and launches only the C compiler and resulting native executable. This
slice becomes production evidence after Slice 1 moves both child phases onto
the scoped process path.

Acceptance:

- candidate-route nested Blorp compiler count is zero;
- generated C and observable results match fresh compilation on parity fixtures;
- debug normalizes to the effective always-debug test policy, profile reuses
  that compile key as reporting-only policy, and sanitizer/leak/ABI/link-input
  differences remain distinct;
- compiler and linker failures preserve command, exit classification, and
  useful diagnostics; and
- retained frontend artifacts are not mutated or consumed by one batch.

### Slice 5: Isolation-Aware Combined Suites

Port deterministic planning for multiple roots. Build run-all harnesses for
shared suites and selector harnesses for process/filesystem-isolated suites.
Separate compile compatibility, harness mode, execution isolation, and resource
batching. Preserve the current source-byte budgets and schedule native
executions with bounded concurrency and deterministic final reporting.
Complete inherited control-descriptor mapping and generated structured events
here. The parent must use the existing typed frame/state-machine protocol for
suite boundaries and acknowledgements; stdout/stderr remain arbitrary byte
streams and are never parsed as control data.

Acceptance:

- suite selection and result order are stable across filesystem enumeration and
  `--jobs` values;
- each shared batch gets one native execution;
- each isolated suite gets a fresh process, and filesystem-isolated suites get
  unique cleaned cwd/`TMPDIR` values;
- a fatal shared-batch event fails the active suite and marks unstarted suites
  not run without implicit retry, while other already independent batches
  follow characterized scheduling behavior;
- valid control records reset the active-suite inactivity deadline; and
- adversarial stdout/stderr writes immediately before and after suite boundaries
  are attributed correctly by the flush/drain/acknowledgement barrier;
- peak RSS and generated-C size remain bounded on the compiler-owned suite; and
- an N-batch scaling fixture proves that live Core, emitted-C, native-artifact,
  and captured-output memory follows the configured in-flight window rather
  than total suite count.

### Slice 6: Structured Diagnostics, Doctests, And Option Parity

Land three mergeable sub-slices:

1. carry the structured compiler diagnostics introduced in slice 3 through test
   execution and reporting, without changing ordinary rendering;
2. port doctest extraction and byte-span segment source maps; and
3. finish option/environment parity and normalized run-manifest comparison.

Exact doctest columns are intentional hardening beyond the current line-only,
not-wired remap helper. It must land with focused tests rather than being
described as existing parity. Replace the current raw-string Option/Result
import heuristics with structural imports from the parsed declaration/context.

Acceptance:

- diagnostics point to original documentation byte spans, lines, and columns,
  including CRLF, tabs, Unicode, multiline spans, and wrapper-only errors;
- ordinary suites, doctests, repeated runs, profiling, sanitizer, leak checking,
  debug behavior, formatting policy, timeout/env precedence, `--timeout 0`,
  `--sanitize=off`, `--std-dir`, repeat early-stop, jobs, gate-result framing,
  and warmup behavior match;
- unsupported combinations fail during plan construction with actionable
  diagnostics; and
- there is no semantic fallback that reparses rendered diagnostics or guesses a
  test binding from source text.

### Slice 7: Complete Production Cutover

Freeze the OCaml runner except for characterization fixes and expose it through
a test-only oracle target that does not require preserving the generic OCaml
host. Remove the remaining OCaml fallbacks from `CliRunTest`; the public CLI has
one route and the candidate has no dependency on OCaml semantic modules.

Acceptance:

- all focused, fault-injection, default, deep, sanitizer, leak, doctest, CLI,
  native macOS, and Linux amd64/arm64 Docker gates pass from a clean worktree;
- benchmark counters show zero OCaml host and nested Blorp compiler processes;
- for tiny and compiler-owned suites, the upper endpoint of the paired 95%
  confidence interval remains within the pre-registered slice-0 latency and
  aggregate process-tree RSS regression ceilings, while structural counters
  show the expected reduction in frontend/startup work;
- interruption and timeout audits find no surviving descendants; and
- the route can be reverted in one commit without changing artifact formats or
  source semantics.

### Slice 8: Delete The OCaml Test Runner

After the slice 7 gates have passed, move any uniquely valuable fixtures to
Blorp-owned tests. Delete the OCaml runner `.ml`/`.mli`, its host dispatch branch,
Dune dependencies, test-only parity target, and unreachable fixtures; update
architecture ownership and refresh the migration inventory. After this point,
rollback is a normal source revert, not a retained routing option.

Acceptance:

- no public or internal production path references OCaml test orchestration;
- no test exists solely to exercise deleted implementation details;
- the full premerge and both supported Docker architecture gates pass; and
- durable session, isolation, process, and diagnostic contracts live in
  `ARCHITECTURE.md` rather than this temporary roadmap.

## Fast Feedback Loops

### Per-Edit Loop

Slice 0 must add a measured phase-local target before implementation proceeds:

```bash
scripts/test-blorp-test-session-fast --case planning
scripts/test-blorp-test-session-fast --case protocol
scripts/test-blorp-test-session-fast --case source-map
scripts/test-blorp-test-session-fast --case typecheck-artifact
scripts/test-blorp-test-session-fast --case process
```

The first three cases are pure, launch no children, import only their owning
modules, and have a named 15-second changed-source median budget on the recorded
reference development machine. The typecheck-artifact case has a named
60-second budget; the deterministic one-helper process case has a named
30-second budget. Put these constants in the script, report actual timings, and
re-baseline them only with committed evidence. CI asserts behavior and
structural work counters rather than failing on noisy wall time.

Current fast-loop status: `protocol` is registered with the 15-second median
reference budget and `process` with the planned 30-second reference budget.
The process case runs one dedicated helper that concurrently exercises stdin,
stdout, and stderr; its initial three-sample median on the reference development
machine was 3.071 seconds, and a later three-sample median was 2.256 seconds.
The latest process median after identity-safe supervisor hardening is 2.318
seconds; the corresponding protocol median is 2.746 seconds.
It deliberately excludes the broader process suite's
intentional background-descendant fixtures. Embedded runtime inputs are checked
against a content-hash manifest before launch, so the loop fails closed instead
of exercising a stale `./blorp` binary. Both cases use a clean `BLORP_*` case
environment, nonblocking bounded diagnostic tails, and process-tree cleanup.
The supervisor retains the unreaped group leader through stabilization, so its
PID remains a stable process-group identity while same-group descendants are
terminated on every supported platform. Linux additionally uses pidfds, with a
birth-identity validation after opening the handle, to terminate observed
cross-session descendants without a PID check/use race. macOS has no equivalent
stable process handle, so an observed cross-session descendant is reported as a
cleanup survivor instead of risking a signal to a reused PID; deliberately
creating a new session remains outside the portable guarantee. Atomic per-PID
snapshots carry ancestry, group, state, and birth identity together. Snapshot
merging rejects same-PID replacements, saturated macOS PID buffers fail closed,
drain work is bounded per supervisor turn, and loss of the required process
sampler triggers group-anchored emergency cleanup. Cleanup resamples after
termination so same-group children forked during shutdown cannot escape. The
case uses bounded sampler retries and bounds the final output flush as well. It
still invokes the production TestSuite
runner, so it launches the OCaml host, nested compiler, and native test child.
That transitional route does not satisfy the intended childless pure-test
contract. The `planning`, `source-map`, and `typecheck-artifact` cases remain
open and should be registered only when their focused owning tests exist.

Keep the existing broader compiler-owned files as checkpoint tests, not the
claimed inner loop:

```bash
make
./blorp test compiler/blorp/tests/test_compiler_cli_test_discovery.brp
./blorp test compiler/blorp/tests/test_compiler_cli_generated_test_harness.brp
./blorp test --timeout 30 compiler/blorp/tests/test_compiler_cli_test_effect.brp
```

The candidate-effect test is intentionally a checkpoint: it compiles the
compiler-owned harness before exercising four retained-graph compile/run
fixtures, so it is not suitable as a per-edit latency claim. Use the same path
with `./blorp check --no-format` to catch module/type errors earlier, and run
the full checkpoint before merging changes to the candidate execution boundary.

Add focused files beside those tests for session keys, stable IDs, graph
assembly, process framing, and source maps rather than growing one all-purpose
integration file. Pure planning and parsing tests should not launch native
children. Process-effect tests should use tiny fixture executables with
millisecond-scale deterministic synchronization, never sleeps as correctness
signals.

During slices 1-6, use the direct OCaml characterization loops and focused
Blorp process fixtures:

```bash
(cd compiler && dune exec test/run_tests.exe -- --scope=deep test '^TestRunner\.')
(cd compiler && dune exec test/run_tests.exe -- --scope=default test '^DoctestRemap\.')
./blorp test --no-format --no-cache --suite --timeout 10 \
  tests/test_blorp/sys/test_process_command.brp
./blorp test --no-format --no-cache --suite --sanitize -j 1 --timeout 20 \
  tests/test_blorp/sys/test_process_command.brp
```

The old and candidate routes must also emit a normalized test-only run manifest
covering discovered suites, compatibility and isolation decisions, batch plan,
statuses, normalized diagnostics, result order, and output hashes. Comparing
that manifest is the parity oracle; passing unrelated OCaml unit tests is not.
Do not preserve OCaml-shaped APIs merely to make parity fixtures easier.

### Slice Gate

For every mergeable slice:

```bash
scripts/test compiler-unit compiler-unit-deep compiler
scripts/test compiler-deep
scripts/test cli
```

Run `scripts/test doctest` for source-map or doctest changes,
`scripts/test leak` for cleanup/ownership changes, and the focused sanitizer
gate for process, Core graph assembly, or retained-artifact lifetime changes:

```bash
scripts/test compiler-blorp-sanitize
scripts/test compiler-core-sanitize
```

Use `scripts/test --timings --log-dir <dir>` on failures so compact console
output does not discard child-runner evidence.

### Cutover Gate

Before slice 7 merges:

```bash
scripts/test
scripts/test compiler-unit-deep compiler-deep std-check
scripts/test compiler-blorp-sanitize compiler-core-sanitize
make quality
make docker-premerge-gate-all
```

Also run the preview CLI smoke documented in `AGENTS.md`, including
`--warmup-only`, `--no-cache`, timeout, leak, sanitizer, REPL, and LSP commands.

## Test Strategy

### Structural Unit Tests

- Source identity normalization, duplicate inputs, symlinks, missing files, and
  content changes including comments.
- Compatibility-key equality and inequality for every semantic, backend, and
  execution option.
- Stable definition allocation under input permutation and generated-root
  variation.
- Separate name-resolution, CTFE, and batch compile closures; conservative
  closure keys; cycles; and failed artifact non-publication.
- Compilation-compatibility and harness-mode partitioning before resource
  subdivision; execution isolation changes launch policy without silently
  changing compilation eligibility.
- Deterministic batching at exact threshold boundaries and oversized singleton
  behavior.
- Control framing across partial reads, malformed lengths/versions, descriptor
  inheritance, duplicates, missing END, and paths that contain framing-like
  text; raw stdout/stderr across invalid UTF-8, NULs, and unterminated lines.
- Byte-span source-map construction and diagnostic remapping across wrapper
  segments, CRLF, tabs, Unicode, multiline spans, and wrapper-only errors.

### Behavioral Parity Matrix

Cover at least:

| Area | Cases |
| --- | --- |
| Discovery | file, directory, multiple roots, duplicate roots, empty tree, missing path, deterministic order, normalization |
| Test identity | valid public `tests`, missing binding, private binding, wrong type, ambiguous/imported names, malformed source |
| Harnesses | one suite, shared run-all, selector, generated-name collisions, quoting and unusual paths |
| Results | pass, assertion failure, compile failure, native nonzero exit, signal, timeout, protocol failure, mixed stdout/stderr |
| Isolation | shared, process, filesystem, leak baseline, sanitizer, cwd/env restoration, descendant cleanup |
| Options | characterized debug behavior, profile reporting, repeat early-stop, jobs/macOS cap, timeout/env precedence, `--timeout 0`, format/no-format, cache/no-cache, `--sanitize=off`, `--std-dir`, gate-result, warmup, suite/doc modes |
| Doctests | no/multiple examples, imports and alias conflicts, private declarations, union constructors, compile/runtime failure, exact byte-span origin, CRLF/tabs/Unicode/blank lines, wrapper-only errors |
| Resources | per-suite/unscoped/control output caps, binary output, large batch, oversized suite, bounded parallelism, interruption, low file-descriptor limit |
| Platform | native macOS, Linux/glibc amd64, Linux/glibc arm64, signal/exit and cwd-spawn differences |

Parity assertions should compare structured planned suites, isolation classes,
exit classifications, normalized diagnostics, and result order. Avoid brittle
full-output snapshots for elapsed times, temporary paths, compiler command
paths, or platform-specific signal text.

### Invalidation And Reuse Tests

Use instrumented fake or tiny real graphs to prove both reuse and non-reuse:

- unchanged shared std/module sources parse and typecheck once across roots;
- changing any raw byte, including a comment, produces a distinct conservative
  checked-artifact key in a separately constructed session snapshot;
- changing an exported interface, private implementation, or CTFE dependency in
  another snapshot cannot reuse a stale artifact;
- changing a backend flag preserves frontend reuse and invalidates compile
  artifacts;
- changing isolation or timeout affects planning/execution but not typed values;
- a failed parse/typecheck/CTFE never becomes a successful reusable artifact;
  and
- one session cannot observe artifacts from a previous invocation unless an
  existing separately validated native cache is explicitly involved.

### Process And Cleanup Tests

Process tests must verify process groups, not only direct child exit. Fixtures
should spawn a descendant, write its PID through a controlled channel, and
prove the descendant is gone after timeout, interrupt, spawn failure cleanup,
and ordinary completion while it remains in the group. Separately characterize
a descendant that calls `setsid()` as outside the portable guarantee. Run
repeated timeout tests under sanitizer/leak gates to expose handle, buffer, and
temporary-directory leaks.

Test output backpressure with simultaneous stdout and stderr larger than pipe
capacity, invalid UTF-8, and NUL bytes. Test a noisy suite followed by a passing
suite and output that resembles old marker text. Test interrupt during C
compilation and native execution, handler restoration, read-only artifacts,
descendant-held cwd/file descriptors, duplicate basenames, parallel cleanup,
and stale-run cleanup. Every test records created artifact paths and asserts
they are absent afterward unless retain mode was explicitly selected.

### Scaling Tests

Generate deterministic source graphs that vary modules, declarations per
module, import fan-out, trait instances, generic calls, CTFE dependencies,
suite count, and harness source bytes independently. Assert operation counters
and fit expected linear bounds; wall-clock thresholds are reserved for the
benchmark driver because shared CI timing is noisy.

## Benchmark Method

Run two distinct experiments from the same built revision:

1. legacy versus candidate route, measuring the total migration including host
   and nested-compiler removal; and
2. candidate reuse-enabled versus candidate reuse-disabled, using the same
   session implementation, batch plan, runtime-cache namespace, process
   schedule, and result manifest to attribute the incremental reuse benefit.

Use the repository's paired benchmark convention: alternate baseline/candidate
order, hash normalized outputs, record paired deltas, and collect enough pairs
for a stable median and 95% bootstrap confidence interval. The benchmark driver
owns and prints the named warmup count, pair count, and stopping policy; do not
silently stop after a favorable sample. Separate these states:

Adaptive stopping is permitted only after the pre-registered minimum pair count
and only when the pre-registered confidence-interval width is reached; stopping
must not depend on the observed direction of the result.

- cold compiler/runtime/native caches;
- warm validated native caches;
- `--no-cache` correctness path; and
- within-invocation session reuse counters.

Primary metrics are wall time, aggregate process-tree peak RSS, unique parses,
checked modules, typed-interface builds/applications, import-registration work,
CTFE evaluations, Core preparations, emitted C bytes, C compiler invocations,
native executions, OCaml host invocations, and nested Blorp compiler
invocations. CPU time, current/peak live node counts, captured output, and
filesystem bytes are useful secondary metrics where portable.

Required workload shapes:

1. one tiny suite, protecting startup latency;
2. many tiny compatible suites, exposing repeated frontend/process overhead;
3. a shared-import fan-out fixture, proving std/module reuse;
4. mixed shared/process/filesystem isolation, protecting execution semantics;
5. the full compiler-owned Blorp suite, representing the main target;
6. doctests, sanitizer, and leak modes; and
7. one oversized suite plus many small suites, exercising resource subdivision.

Every pair must have identical normalized discovery, batch-plan, result,
diagnostic, order, and output hashes. Do not publish a speedup from a contended
machine, unmatched cache states, different compiler revisions, missing or
different results, or surviving processes. Store raw evidence under
`benchmarks/results/`; this roadmap should retain only the conclusions that
change sequencing or acceptance thresholds.

## Risks And Required Responses

| Risk | Required response |
| --- | --- |
| Retained IDs refer to graph-local side tables | Gate typed reuse on stable identity and whole-graph validation |
| Broad source store changes semantics | Separate source availability from exact semantic closure |
| Typed values are consumed or mutated downstream | Audit ownership, clone only at the consuming boundary, and add reuse-after-compile tests |
| Mega-batches increase Core time or RSS | Partition semantically, then apply measured deterministic resource caps |
| Shared binary corrupts per-suite timeout/result attribution | Use a bidirectional length-prefixed control transport with begin/end drain barriers and fail closed on protocol errors |
| Child or descendant survives interruption | Extend structured process groups, forward signals, escalate termination, test descendant PIDs, and document the new-session limit |
| Doctest errors point into generated wrappers | Require structured diagnostics and segment source maps before cutover |
| Candidate parity depends on OCaml behavior bugs | Characterize public behavior, retain intentional contracts, and fix confirmed bugs in a separate change |
| Benchmark gains come from unrelated migration work or cache | Run legacy/candidate and reuse-on/off experiments; report session counters and isolated cache states |
| Platform process behavior diverges | Gate native macOS and Linux/glibc amd64/arm64 in Docker before cutover; preserve the characterized macOS worker cap |
| Migration blocks removal of other OCaml middle code | Depend only on Blorp compiler services and isolate the frozen runner behind a test-only oracle target |

## Production Readiness And Rollback

The production route may move only when all slice 7 gates pass and no known
P0/P1 correctness, cleanup, or diagnostic-parity issue remains. Performance is
not allowed to compensate for semantic or cleanup regressions. "Stabilized"
means the fault-injection, full premerge, native macOS, Linux/glibc amd64/arm64,
and slice-0 latency/RSS budget gates all passed on the cutover revision; elapsed
calendar time or one nominal follow-up slice is not evidence.

Keep the cutover as a routing-only commit after the implementation slices. A
rollback restores that routing without changing source artifacts, cache
formats, or test declarations. Do not dual-route individual suites in
production: mixed ownership makes ordering, cleanup, and performance failures
harder to reason about. Once slice 8 deletes the oracle, rollback is a source
revert and does not justify retaining dormant routing code.

## Definition Of Done

- `blorp test` is planned, compiled, executed, and reported by Blorp-owned code.
- Every logical source identity in one compatible session is parsed once;
  counters and scaling tests enforce the invariant.
- Standard-library and shared checked modules, typed import interfaces, and
  eligible evaluated artifacts are reused across compatible harnesses with
  stable identity, explicit closures, and phase-specific compatibility keys.
- Compile compatibility, harness mode, execution isolation, and resource
  subdivision are separate typed decisions.
- No OCaml host or nested Blorp compiler is launched by the test route.
- Native process groups, timeouts, interrupts, output, and cleanup pass focused
  and platform gates.
- Doctest diagnostics use structured source maps.
- Persistent result caching remains off until exact transitive manifests exist.
- Benchmarks show the work removed and report latency/RSS without cache or
  contention ambiguity.
- The OCaml test runner and temporary parity hook are deleted.
- Durable contracts are moved to `ARCHITECTURE.md`, parent roadmaps are updated,
  and this execution roadmap is deleted.
