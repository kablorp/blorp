# Blorp OCaml Host Exit Roadmap

Status checked against code on 2026-07-25.

This roadmap removes the two remaining non-semantic responsibilities from the
OCaml compiler host:

1. receiving and executing the serialized Blorp CLI/module-graph plan; and
2. writing generated artifacts, invoking the host C compiler, and running the
   resulting binary.

The semantic middle is a separate migration concern. Core lowering and the
early Core pipeline through synthesis are now Blorp-owned; until the
remaining middle Core passes are ported, one narrow OCaml worker may remain:

```text
Blorp CLI, files, graph, parse, typecheck, and CTFE
  -> Blorp Core lowering, graph flattening, FFI annotation, and list layout
  -> Blorp debug, desugar/SSA, mono, post-mono list layout, and synthesis
  -> one versioned post-synthesis Core request
  -> OCaml match-through-specialize Core worker
  -> one versioned post-specialize/pre-DCE Core response
  -> Blorp function-reference normalization, late Core pipeline, and C emission
  -> Blorp artifact writer, host C invocation, and program execution
```

There must be exactly one production handoff in this temporary architecture.
The worker is not a second CLI, must not rediscover source modules, and must not
write artifacts or run programs. When the semantic middle ports, deleting that
one worker makes compilation end-to-end Blorp without another shell cutover.

This document expands Checkpoint 11 of
`BLORP_COMPILER_PORT_ROADMAP.md`. That roadmap remains authoritative for which
semantic stages are OCaml- or Blorp-owned.

The checkpoints were executed in document order. Checkpoint C cut over
`check`, which needs no backend effects, and built the compile/run path through an
in-memory `BuildArtifact` under focused tests using typed worker requests and
decoded response fixtures. Raw Core-to-C emission still uses the smaller
`CArtifact` compatibility shape until the legacy bridge is removed. The real
worker process client lands with the structured process API in Checkpoint F.
Compile/run became authoritative in Checkpoint J, after the artifact,
filesystem, process, host-C, runtime, and observability checkpoints are
complete.

## Current Boundary

The public `blorp` executable is Blorp. Ordinary `check`, `compile`, and `run`
now stay inside `compiler_cli_main.brp` for command execution and host effects.
All three discover, parse, typecheck, and run CTFE from the in-memory Blorp
graph. Compile and run invoke exactly one sibling `blorp-ocaml-middle` process
with the typed semantic request. That worker returns after specialization;
Blorp then normalizes first-class function references before DCE, runs the
complete late Core pipeline, emits C, writes artifacts, invokes the host C
compiler, manages the runtime cache, and runs the resulting program.

The late-pipeline boundary is represented explicitly. The semantic worker and
`emit_core_c` bridge exchange pre-DCE `CoreProgram`; `run_pre_dce_tail` returns
`PreparedCoreProgram`, and only the prepared emitter accepts that value. The
CLI therefore cannot accidentally repeat Perceus, resource, fairness, prepare,
or prepared-reuse passes after `execute_late_core_stages` has completed them.

`CliOcamlHostPlan` has no source-command variant. Run-plan JSON is rejected at
the serializer, the OCaml bridge decoder represents compile graphs only, and
the obsolete OCaml run/C-compiler effect path has been deleted. The remaining
general host delegation is for commands not yet migrated (`test`, `purify`,
`package`, `repl`, and `lsp`).

Bootstrapping is now a separate immutable artifact boundary. Release archives
carry `blorp-bootstrap-compiler`, inherited from the verified pinned toolchain,
plus bootstrap-specific host, parser, typecheck, and renderer executables. The
launcher selects those helpers explicitly, so the immutable host cannot consume
the new release's bridge protocols merely because both generations share an
installation directory. A `blorp-bootstrap-layout` manifest represents this
bundle explicitly; the tooling does not infer compatibility from neighboring
filenames. Installed bundles use content-addressed generation directories and
an atomically replaced active-generation pointer, preventing interrupted or
concurrent upgrades from mixing their members. The build invokes only that
artifact's fixed
`__compiler-host-compile-wrapper` command. The current
`compiler/bin/blorp_ocaml_host.ml` no longer implements that command or links
its argument parser. Toolchains published before the isolated bundle are
accepted temporarily by resolving their immutable `blorp-ocaml-host` and
packaging it with that release's matching helpers. That fallback can be deleted
after the first release containing the complete, verified isolated bundle is
pinned on every supported target.

The desired change is not to move the existing CLI-plan protocol into another
file. The CLI plan must become an internal Blorp value. Only the semantic input
needed by the temporary OCaml middle crosses a process boundary.

The frontend graph also owns source-definition identity. Target, imported
modules, and CTFE dependencies are typechecked from one graph-wide DefId plan;
the OCaml middle preserves those IDs and reserves all generated Core IDs above
the highest source function or constructor ID. Mixing Blorp-resolved calls with
OCaml-reminted declarations, or restarting generated IDs at zero, is invalid.

## Non-Negotiable Invariants

1. **All gates are green first.** Do not move the production boundary while a
   compiler, runtime, leak, doctest, CLI, sanitizer, package, or example gate
   has an unexplained failure.
2. **One bridge only.** A production source command makes at most one OCaml
   request and receives at most one OCaml response.
3. **No fallback.** After a slice becomes authoritative in Blorp, delete the
   OCaml production path in the same slice. Do not retain a retry or parity
   fallback.
4. **No CLI protocol at the semantic boundary.** The worker receives typed
   compiler data and compile-stage options, not argv, `CliRunPlan`, source
   paths to reopen, or a module-discovery request.
5. **No OCaml effects after the response.** C emission, output selection,
   filesystem writes, `cc`, runtime caching, timeout handling, and child exit
   propagation are Blorp responsibilities.
6. **Typed values inside Blorp.** JSON exists only at the worker boundary.
   Filesystem and process behavior use records, enums, unions, and `Result`.
7. **Behavioral parity before deletion.** Exit codes, diagnostics, output,
   cleanup, sanitizer behavior, runtime cache identity, and stage observation
   are observable compiler behavior.
8. **The pinned bootstrap is immutable.** Keep the release named by
   `compiler/bootstrap.env` until an all-green committed revision has published
   replacement artifacts. Rotate the pin in a later, isolated commit. The
   manifest is the authoritative release identity for both the bootstrap
   compiler and CI cache keys.
9. **One identity domain per compile graph.** Source functions, impl methods,
   and constructors receive deterministic graph-wide DefIds in Blorp. Every
   typed module installed in the OCaml middle comes from that graph response,
   and generated Core declarations allocate strictly above its high-water mark.
10. **Late ownership runs exactly once.** Pre-DCE and prepared Core use distinct
    types at the backend boundary. Bridge emission owns the late pipeline for
    pre-DCE input; CLI emission consumes the already prepared result.

## Checkpoint A: Freeze A Green Baseline

Goal: establish evidence that host-exit failures are caused by the cutover,
not by pre-existing migration regressions.

Implementation:

1. Run `scripts/premerge-gate` from a clean bootstrap build.
2. Record the revision, bootstrap tag, platform, and gate result in this file.
3. Add a compact host-boundary inventory test or script that asserts normal
   `check`, `compile`, and `run` enter only the current expected handoff.
4. Reconcile the bootstrap source of truth through one checked-in manifest
   consumed by both the wrapper and CI; do not silently choose whichever
   environment variable happens to be present. Complete:
   `compiler/bootstrap.env` owns the tag, artifact version, and target
   checksums, and workflow cache keys read the tag through the wrapper.
5. Once the revision is committed and CI is green, let the existing release
   workflow publish immutable `dev-<sha>` binaries. Do not pin them yet.

Evidence:

- `scripts/premerge-gate`
- preview smoke commands in `AGENTS.md`
- Linux x86_64 and ARM64 premerge jobs
- macOS ARM64 CI/release build

Exit condition:

- all gates pass at one committed revision;
- the baseline uses a known bootstrap tag; and
- no test depends on an uncommitted local compiler helper.

## Checkpoint B: Define The Single Semantic Worker Contract

Goal: replace the general CLI-plan handoff with one phase-specific protocol.

Status: implemented and authoritative for normal `compile` and `run`. The
private worker receives strict post-synthesis Core schema 4 and starts at match
compilation; no source or typed AST crosses this boundary.

New Blorp file:

- `compiler/blorp/src/stage_09_core/compiler_semantic_worker_protocol.brp`

Temporary OCaml file:

- `compiler/bin/blorp_ocaml_middle.ml`
- `compiler/bin/dune` adds the private companion executable without exposing a
  second public CLI

The request should be a typed record equivalent to:

```text
SemanticMiddleRequest
  schema_version and required capabilities
  target_module
  prepared_core
  next_definition_id
  main_and_module_import_bindings
  debug_mode
  require_main
  invariant_checks
  requested_stage_observations
```

The response is a union, not optional fields with coupled meanings:

```text
SemanticMiddleResponse
  SemanticMiddleCompiled(pre_dce_core, observations)
  SemanticMiddleStopped(stage, rendered_snapshot, observations)
  SemanticMiddleFailed(diagnostics)
```

Successful compilation returns the machine-readable pre-DCE Core JSON consumed
by the Blorp late pipeline. Earlier OCaml Core forms are intentionally outside
that projection schema, so requested early/middle observations and stop
snapshots are stable rendered Core text rather than pretending to be backend
Core JSON.

Implementation:

1. Use the phase-specific Core vocabulary in `compiler_core_json.brp`; do not
   nest the current CLI artifact or typed-program JSON.
2. Assemble every dependency into one prepared Core graph in Blorp. The worker
   must not receive source paths and call `Modules.load_module`.
3. Preserve stable callable ids, module-qualified type identities, selected
   call metadata, source locations, import bindings, FFI policy, and initial
   layout facts. Validate those invariants before spawning the worker.
4. Return exactly the pre-DCE Core shape consumed by
   `compiler_core_pipeline.brp`. Keep JSON decoding in
   `compiler_core_json.brp`.
5. Keep the worker entry function limited to strict post-synthesis Core decode,
   early-stage invariant validation, and the still-OCaml middle passes.
6. The worker reads one request from stdin and writes one response to stdout.
   Source diagnostics use the typed response; infrastructure failures use
   stderr. It accepts no public CLI flags. The Blorp process client is added in
   Checkpoint F after the required process semantics exist.
7. Add a protocol capability/version handshake. A schema mismatch is a hard
   infrastructure error with expected and actual versions.
8. The executable consumes exactly one stdin request and then exits. Add the
   test-only invocation counter at the Blorp process-client seam in Checkpoint
   F, where it can actually prove one process invocation per source command. A
   process-local worker counter would always start from zero and could not
   detect duplicate spawns.

Tests:

- new `compiler/blorp/tests/test_compiler_semantic_worker_protocol.brp`
- new `compiler/test/test_semantic_middle_worker.ml`
- malformed schema, missing field, and unknown variant
- multi-module graph with a shared dependency
- imported aliases, traits, foreign declarations, CTFE globals, and `main`
- `--stop-after`, `--dump-core-after`, and invariant-check requests
- infrastructure failure distinct from source diagnostics

Raw malformed/truncated stdout tests land with the real process client in
Checkpoint F. Before that client exists, the worker executable is smoke-tested
directly: malformed request JSON exits nonzero on stderr, while valid semantic
failures remain versioned `SemanticMiddleFailed` responses.

Implemented evidence on 2026-07-13:

- 8 Blorp protocol tests;
- 9 OCaml protocol/worker tests, including a real typed target and two explicit
  typed modules with no module-cache dependency;
- explicit import-binding table and resource-cleanup restoration regressions;
- private `blorp_ocaml_middle.exe` stdin/stdout smoke tests; and
- `scripts/test compiler-unit compiler-unit-deep compiler`: 3,443 passed; and
- `scripts/test compiler-deep`: 1,904 passed.

Exit condition:

- the protocol round-trips all production typed-program and pre-DCE Core
  forms; and
- the worker can compile representative fixtures without reading `.brp`
  files or invoking the backend.

## Checkpoint C: Keep The CLI Plan Inside Blorp

Goal: cut ordinary `check` over to Blorp and build a typed, testable compile/run
path from an internal CLI plan through an in-memory `BuildArtifact`.

Status: complete on this branch. Check, compile, and run all keep their CLI
plans inside Blorp. Compile/run cross only the typed semantic-middle boundary.

Primary files:

- `compiler_cli_main.brp`
- `compiler_cli.brp`
- `compiler_cli_plan.brp`
- `compiler_cli_source_graph.brp`
- `compiler_typecheck_bridge.brp`
- `compiler_semantic_worker_protocol.brp`

Implementation:

1. Add typed Blorp executors:
   - `execute_check_plan`
   - `execute_compile_plan`
   - `execute_run_plan`
   - shared `compile_frontend_graph`
2. Run graph typechecking and CTFE directly from the in-memory
   `CliFrontendModuleGraph`. Do not serialize that graph merely to call back
   into Blorp through OCaml.
3. Cut ordinary `check` over immediately: it ends after Blorp typecheck unless
   an explicitly requested Core observation requires the semantic worker.
   Ordinary `check` must make zero OCaml calls.
4. Under focused tests, compile/run build exactly one semantic-worker request,
   accept one decoded response fixture, run `compiler_core_pipeline`, and call
   `try_emit_core_program_c_artifact_with_profile`. Do not add a temporary
   subprocess mechanism. Do not make this path production-authoritative until
   Checkpoints D through I are complete.
5. Split `CliRunFrontendModuleGraph` so the removed check handoff cannot be
   represented, while compile/run can retain their temporary production
   handoff until Checkpoint J. Internally, keep phase-specific records for
   check, compile, and run so invalid option combinations are unrepresentable.
6. Remove the check arm from `write_cli_plan_file`,
   `run_ocaml_host_with_plan`, and `execute_cli_plan`. Remove the remaining
   source-command arms in Checkpoint J.
7. Keep general host delegation only for commands not yet migrated in
   Checkpoint 12 of the main roadmap. It must be a visibly separate legacy
   command boundary, not a path source commands can enter.

Tests:

- extend `test_compiler_cli.brp` and `test_compiler_cli_args.brp`
- check/compile/run each build the correct typed internal plan
- ordinary `check` makes zero worker calls
- compile/run encode one worker request and consume one response each
- ordinary `check` emits no `CliRunPlan` JSON file
- directory check, package imports, `--std`, `--no-format`, and multiple-root
  diagnostics

Deletion after the check cutover:

- check-plan decoding from `compiler_blorp_bridge.ml`
- `run_check_from_frontier_options`
- the check-specific OCaml decoder and implementation-only tests

Deletion completed during Checkpoint J:

- source run-plan host serialization and decoding;
- `run_file_from_frontier_options` and `run_file`; and
- the OCaml run frontend/options/frontier types and their implementation-only
  tests.

Compile graph decoding remains in current source only for the in-memory
test-runner compatibility route. The REPL separately uses the legacy
direct-source pipeline. The immutable bootstrap compiler contains its own
already-compiled graph decoder.

Implemented evidence on 2026-07-13:

- `CliRunCheck`, `CliRunCompile`, and `CliRunSource` carry phase-specific typed
  options over a command-neutral `CliFrontendModuleGraph`;
- `CliOcamlHostPlan` deliberately has no check variant;
- `compiler_cli_typecheck.brp` owns neutral in-memory graph typechecking,
  `compiler_cli_execute.brp` owns direct check execution, and the semantic and
  backend-heavy compile/run executors remain outside the production CLI import
  graph;
- the OCaml check option decoder, frontier variant, runner, and implementation-
  only tests are deleted;
- a valid check succeeds with `BLORP_OCAML_HOST_BIN` pointing to a missing
  executable, while compile still fails through that path, proving the check
  does not invoke the host;
- source-graph setup preserves package-configuration diagnostics, including
  actionable `blorp package fetch <alias>` guidance for an unavailable
  content-addressed package, and direct check does not cascade into type errors
  after graph setup fails;
- source-graph discovery uses a generated embedded-std source lookup when no
  explicit override exists, while preserving the documented `--std-dir`,
  `BLORP_STD`, `blorp.toml`, embedded precedence and synthetic
  `<embedded:std/...>` source identities;
- focused Blorp execution tests: 3 passed;
- CLI planning and typed graph tests: 87 passed;
- CLI gate: 51 passed, including the permanent zero-host regression;
- CLI deep integration gate: 81 passed, including directory and package-import
  checks through the production Blorp check path;
- compiler-unit gate: 1,622 passed; and
- a clean pinned-bootstrap public CLI build completed successfully. The cold
  whole-program build took about 14 to 18 minutes on macOS ARM64, while an
  unchanged follow-up `make` completed in about 2 seconds. The cold-build cost
  is a performance issue to address separately, not a reason to reintroduce
  the host boundary.

## Checkpoint D: Make `BuildArtifact` A Complete Blorp Boundary

Goal: ensure all information needed after semantic compilation is represented
by a typed Blorp artifact, with no hidden OCaml module state.

Status: complete on this branch. The raw `CArtifact` remains only at the
temporary legacy bridge, while the Blorp-owned compile/run path upgrades it
immediately to a complete `BuildArtifact` and derives host-C policy solely
from that typed value.

Primary files:

- `compiler_artifact_json.brp`
- `compiler_core_emit.brp`
- `compiler_cli_args.brp`
- new `compiler_build_artifact.brp`

Implementation:

1. Keep `CArtifact` as the explicitly temporary raw-emission/legacy-bridge
   shape. Immediately upgrade it to a phase-specific `BuildArtifact` that
   includes:
   - generated C text;
   - structured native link arguments;
   - include directories;
   - runtime requirements;
   - imported native feature requirements such as raylib/TLS;
   - source identity for diagnostics; and
   - profile/debug/sanitizer compatibility facts.
2. Do not infer raylib use afterward from OCaml `Modules.get_all_modules`.
   Record the requirement while traversing the Blorp-owned graph/artifact.
3. Keep link arguments as a list. Never join and resplit shell text.
4. Add a strict decoder even if the normal in-process path no longer needs
   JSON. It remains valuable for the temporary worker and artifact fixtures.
5. Separate pure policy from effects:
   - `build_c_invocation` produces a typed command;
   - `write_compile_artifact` writes requested output;
   - `execute_c_invocation` runs the command.

Implementation notes:

- `compiler_build_artifact.brp` owns `BuildArtifact`, structured platform link
  arguments, runtime/native requirements, source identity, compatibility
  facts, and the pure `build_c_invocation` projection.
- foreign link groups are validated before Core lowering and split exactly
  once while entering the structured artifact; downstream code never joins or
  resplits command text;
- raylib and TLS requirements derive from typed graph origins and canonical
  module identities, so user modules cannot spoof native requirements; and
- `compiler_artifact_json.brp` has a strict versioned codec for every artifact
  field while retaining the raw codec solely for the temporary OCaml bridge.

Tests:

- extend `test_compiler_artifact_json.brp`
- round-trip every artifact field
- malformed runtime requirement and unknown feature variant fail explicitly
- foreign include/link arguments preserve item boundaries and ordering
- raylib/TLS requirements do not depend on global module state

Exit condition:

- deleting OCaml module caches after C emission cannot change the command that
  Blorp will execute.

Focused evidence on 2026-07-13:

- build-artifact policy tests: 4 passed;
- strict artifact-codec tests: 6 passed;
- CLI execution tests cover embedded/external runtime selection, profile and
  optimization facts, source identity, and exact raylib/TLS graph derivation;
- the combined artifact, CLI, environment, inference, Core-emission, and
  Perceus suites passed 750 tests with no failures;
- the Perceus suite passed all 139 tests under ASan and UBSan, including a
  regression proving a matched owner outlives retention of its borrowed
  payload;
- production and ASan CLI builds both check a normal source successfully and
  report the expected global-self-reference diagnostic without invoking freed
  memory. An unchanged follow-up `make` completes in about 2 seconds;
- production compiler and CLI gates passed all 1,537 tests after the cold
  self-hosted build exposed and closed CTFE string-case and closure-value
  parity gaps. CTFE now evaluates lexical closures while recursively rejecting
  captured closures that cannot be materialized as global data; and
- the complete default gate passed all 9,572 tests: compiler-unit, compiler,
  runtime, leak, doctest, and CLI.

## Checkpoint E: Add The Minimum Robust Filesystem Surface

Goal: perform compiler artifact I/O with `std/fs.brp`, not ad hoc `system`
helpers.

Status: complete on this branch. The implementation uses the existing `FileWriter` and
`Directory` resource types for temporary resources. Their opaque runtime
handles carry whether cleanup removes the path, and `resource_path()` exposes
the associated path. This is deliberate bootstrap compatibility: the pinned
`dev-9f56c40d2b91` compiler has a closed resource-layout registry and cannot
compile a standard library that introduces another `resource type`. Ordinary
writers/directories never remove their paths; only handles created by the
temporary factories do. This keeps cleanup scoped without weakening the pinned
bootstrap contract or adding a compatibility compiler path.

Required standard-library work:

- add atomic replacement built on same-directory temporary creation, flush,
  close, and rename;
- add scoped temporary file/directory resources whose cleanup is automatic;
- expose path-rich `IOError` values consistently; and
- keep binary/text writes explicit.

Proposed APIs:

```text
write_text_atomic(path, text) -> Result[Void, IOError]
with temporary_directory(parent, prefix) ?= ...
with temporary_file(parent, prefix) ?= ...
```

Implementation:

1. Add runtime primitives only where `fs` cannot express race-free
   create/rename behavior. Do not build atomicity from predictable paths.
2. Use `with` resources for every handle and temporary directory.
3. `compile -o` writes a sibling temporary file and atomically renames it only
   after the complete C artifact is written.
4. A failed write leaves an existing destination unchanged and cleans the
   temporary path.
5. Remove compiler use of `system.mkstemp_path`, `system.write_file`, and
   `system.remove_file` as this boundary moves. Do not expand the overlapping
   `system` file API.

Tests:

- runtime tests for full write, overwrite, write failure, cleanup, and rename
- compiler CLI tests for default `.c` path and `-o`
- interrupted/failed write does not truncate an existing destination
- spaces and non-ASCII path components on supported platforms

Exit condition:

- the Blorp artifact writer passes focused parity and failure tests;
  neither the production path nor the immutable bootstrap compiler retains the
  former generic OCaml artifact writer.

Implemented evidence on 2026-07-14:

- `write_text_atomic`, scoped temporary files/directories, recursive directory
  creation, atomic rename, and symlink-safe recursive removal are exposed by
  `std/fs.brp` with path-rich `IOError` results;
- operation-result metadata and both OCaml and Blorp ownership-contract suites
  cover every new runtime primitive without duplicate registrations;
- filesystem runtime tests pass 7 tests normally and under strict leak check;
- compiler artifact-writer tests pass 4 focused cases, including replacement
  and failure behavior.

## Checkpoint F: Add A Structured Process API

Goal: let Blorp invoke `cc` and programs without shell parsing or global
environment mutation.

Status: complete on this branch. The old convenience wrappers remain for
unmigrated callers, but all new compiler effects use `ProcessCommand`.

The current `std/process.brp` `run` and `run_inherit` APIs are insufficient:
they do not model stdin bytes, cwd, child-only environment changes, timeout,
process groups, or signal termination.

Proposed phase-specific types:

```text
ProcessStdin = InheritStdin | NullStdin | BytesStdin(Bytes)
ProcessStream = InheritStream | CaptureStream | NullStream
ProcessExit = Exited(Int) | Signaled(Int) | TimedOut
ProcessGroup = InheritProcessGroup | NewProcessGroup
ProcessEnvironmentChange { name: String, value: Option[String] }
ProcessCommand {
  program: String,
  args: List[String],
  cwd: Option[String],
  environment: List[ProcessEnvironmentChange],
  stdin: ProcessStdin,
  stdout: ProcessStream,
  stderr: ProcessStream,
  timeout: Option[Duration],
  process_group: ProcessGroup,
}
ProcessResult { exit: ProcessExit, stdout: Bytes, stderr: Bytes }
```

Implementation:

1. Add `process.run_command(ProcessCommand) -> Result[ProcessResult,
   ProcessError]` as the primitive compiler-facing API.
   Captured streams remain bytes until a caller explicitly decodes text.
2. Keep `run` and `run_inherit` as simple wrappers if they remain useful.
3. Pass argv directly to the OS. The compiler must not use `shell`.
4. Child environment overrides must not call global `setenv`/`putenv`.
5. Stream stdin and drain stdout/stderr concurrently so large compiler
   diagnostics cannot deadlock. Do not rely on pipe-buffer size.
6. A timeout terminates the complete process group, waits for it, and closes
   all descriptors. Represent timeout separately from exit code 124 internally;
   translate to CLI convention only at the outer boundary.
7. Preserve signal-derived exit status consistently across macOS and Linux.
8. Add
   `compiler/blorp/src/stage_12_cli/compiler_semantic_worker_client.brp` on
   this API. It sends the encoded request through `BytesStdin`, captures
   exactly one response, and maps spawn, exit, stderr, and decode failures to
   distinct infrastructure errors.

Tests:

- new `tests/test_blorp/sys/test_process_command.brp`
- large stdin plus large stdout/stderr without deadlock
- argument boundaries containing spaces, quotes, and empty strings
- cwd and child-only environment
- normal exit, signal exit, spawn failure, timeout, and descendant cleanup
- inherited versus captured streams

Exit condition:

- compiler execution uses no shell command strings and mutates no global
  environment for a child process.

Implemented evidence on 2026-07-14:

- `ProcessCommand` models exact argv, stdin bytes, each output stream, cwd,
  child-only environment changes, process groups, timeout, and a per-command
  capture limit;
- the runtime writes stdin while draining stdout/stderr, terminates timed-out
  process groups, waits for children, and distinguishes exits, signals, and
  timeouts;
- process tests pass 11 cases normally and under strict leak check; and
- the semantic worker client passes 8 focused protocol/process cases,
  including malformed output and response-size enforcement.

## Checkpoint G: Port Host C Invocation And Runtime Packaging

Goal: reproduce `Test_runner` compilation behavior in maintainable Blorp code.

Status: implementation complete on this branch. Exact host-C policy, typed
host/toolchain discovery, the verified runtime CAS, and production compile/run
assembly are Blorp-owned. Full platform-gate validation remains.

New Blorp files:

- `compiler/blorp/src/stage_12_cli/compiler_host_c.brp`
- `compiler/blorp/src/stage_12_cli/compiler_runtime_cache.brp`
- `compiler/blorp/src/stage_12_cli/compiler_platform.brp`

OCaml references to study exactly:

- `Test_runner.compile_c_from_stdin`
- `Test_runner.sanitizer_cc_args`
- `Test_runner.precompile_runtime`
- `Test_runner.runtime_cache_key`
- `Test_runner.runtime_cache_verified`
- `Test_runner.tls_backend_runtime_cc_args`
- `Test_runner.tls_backend_link_cc_args`
- `Test_runner.has_raylib_import`
- `Test_runner.raylib_linker_flags`
- `Ffi_boundary.link_flags_cc_args`

Implementation:

1. Build `HostCCompileRequest` from `BuildArtifact`, compile profile, sanitizer
   mode, platform, and runtime artifact. Keep option policy pure.
2. Feed generated C to `cc` through `BytesStdin`; preserve `-x c - -x none`
   so following object files are not parsed as C.
3. Preserve `-fwrapv`, optimization level, pthread/math libraries, macOS stack
   size, include directories, sanitizer flags, and foreign link flags.
4. Replace raylib whitespace splitting with structured arguments at the point
   they are discovered.
5. Model TLS backend as an enum. Validate `BLORP_TLS_BACKEND` once at the CLI
   boundary; keep OpenSSL cflags/libs as structured lists.
6. Port the runtime object cache as an immutable CAS entry with staged
   publication and a READY/manifest verification contract.
7. The cache key must include all semantic inputs: runtime sources and headers,
   target/platform identity, C compiler identity, optimization, sanitizer,
   TLS backend and flags, and ABI-affecting compiler/runtime options.
8. A stale or unverifiable entry is rebuilt; it is never partially reused.
   Concurrent publishers must converge without exposing an incomplete entry.
9. If runtime precompilation fails, fall back only to the existing explicit
   embedded-runtime mode. Do not silently retry a failed user C compilation.
10. Format `cc` failures as compiler infrastructure diagnostics while
    preserving complete captured stderr for `--verbose`/logs.

Tests:

- port behavioral tests from `test_test_runner.ml` and
  `test_compiler_test_runner.ml` before deleting them
- runtime CAS hit does not invoke `cc` a second time
- each key component invalidates the cache
- concurrent cache publication and stale entry repair
- C input larger than pipe buffers and compiler stderr larger than pipe buffers
- sanitizer, TLS unsupported/OpenSSL, raylib, foreign include/link flags
- generated-C failure includes source identity and compiler output

Exit condition:

- the Blorp host-C and runtime-cache implementations pass focused parity tests.
  The OCaml source-run implementation is deleted; shared test/bootstrap
  machinery remains only where another current command still reaches it.

Implemented evidence on 2026-07-14:

- host-C tests pass 6 cases, including exact embedded/external argv, sanitizer
  policy, TLS/runtime mismatches, real stdin compilation, and diagnostics;
- runtime-cache tests pass 3 cases covering semantic key inputs, verified
  reuse, object/READY corruption repair, and concurrent publisher convergence;
- host platform tests pass 6 cases for OS normalization, compiler/target
  probing, compiler-family detection, cache roots, TLS validation, and quoted
  argument boundaries;
- host environment tests pass 2 cases proving overrides remain structured and
  unsupported TLS does not invoke `pkg-config`.

## Checkpoint H: Port Program Execution Semantics

Goal: implement and test the complete Blorp-owned `run` effect path for the
production switch in Checkpoint J.

Status: implementation complete on this branch. The artifact-to-program effect
path, CLI option/environment assembly, and production routing are Blorp-owned.

Implementation:

1. Create a scoped compilation directory and select `program.bin` within it.
2. Compile through `compiler_host_c.brp`.
3. Run with the user arguments after `--` as exact argv items.
4. Apply `BLORP_THREADS` and `BLORP_LEAK_CHECK=strict` to the child environment
   only.
5. Inherit terminal streams for normal `run`; capture only where the command
   contract requires it.
6. Translate `ProcessExit` to the documented CLI status at one outer function.
7. On timeout, report the configured duration, terminate descendants, clean
   artifacts, and return the conventional timeout status.
8. Preserve `--release`, `--profile`, `--debug`, sanitizer modes, and
   `--leak-check` without using process-global mutable state.

Tests:

- CLI preview smoke for `run`
- exact argv propagation, including empty and spaced arguments
- exit 0, nonzero exit, signal termination, timeout, and spawned descendant
- threads and leak-check environment do not leak into the compiler process
- temp artifacts are removed on success, compile failure, runtime failure, and
  timeout

Exit condition:

- given a `BuildArtifact`, the Blorp executor compiles and runs it with no OCaml
  effect helper; the public command uses this executor.

Implemented evidence on 2026-07-14:

- program-runner tests pass 4 cases normally and under strict leak check;
- exact empty/spaced/quoted argv and child-only thread/leak environment values
  reach a real compiled C program;
- inherited stdio, timeout classification, conventional status translation,
  and temporary executable cleanup are covered.

Remaining validation gaps:

- complete the signal/descendant and macOS/Linux architecture matrix; and
- keep the CLI parity tests for timeout, sanitizer, leak, thread, observation,
  dump-file, and timing policy green during deletion.

## Checkpoint I: Preserve Observability And Diagnostics

Goal: avoid making the cutover correct but operationally opaque.

Status: implemented on this branch; full gate validation remains. Parse/typed
output stays on Blorp frontend data, semantic and late observations cross their
typed boundaries once, and requested late snapshots do not replace mandatory
final pipeline completion.

Implementation:

1. Keep `--dump-ast` and `--dump-typed-ast` on the Blorp-owned frontend data.
2. Send only requested early/middle stage observations through the worker
   response. Do not run the worker once per dump stage.
3. Run late stage dumps, `--stop-after`, invariant checks, and profile timing in
   Blorp after the response.
4. Preserve stdout/stderr placement and status for handled CLI results.
5. Distinguish source diagnostics, worker protocol failures, C compiler
   failures, and program failures with phase-specific error variants.

Tests:

- existing dump/stop/profile CLI fixtures
- multiple requested stage snapshots still make one worker call
- malformed worker output is an infrastructure error, not a source diagnostic
- output stream and exit-code parity tests

## Checkpoint J: Production Cutover And OCaml Host Deletion

Goal: remove the general OCaml host from source compilation.

Status: source-command cutover is implemented on this branch. Check makes zero
OCaml calls; compile/run make one semantic-middle call; all post-worker effects
are Blorp-owned; source run is unrepresentable in `CliOcamlHostPlan`; and the
OCaml run effect implementation is deleted. The general host remains for
unmigrated non-source commands, including test execution. The old compile
implementation remains only behind the explicitly named pinned-bootstrap
wrapper.

Implementation order:

1. Verify the Checkpoint C `check` path remains direct and makes zero worker
   calls by default.
2. Route `compile` through one semantic worker call and Blorp artifact writing.
3. Route `run` through one semantic worker call and Blorp C/program execution.
4. Remove the source-command variants from the serialized CLI artifact.
5. Delete source command execution from `blorp_ocaml_host.ml`.
6. Rename/build the remaining temporary executable as
   `blorp-ocaml-middle`, containing only the semantic worker entry point and
   its required OCaml libraries.
7. Remove `BLORP_OCAML_HOST_BIN` from source-command behavior. If non-source
   tools still require a legacy host, give that boundary a different explicit
   name so it cannot become a fallback.
8. Delete OCaml tests that test only removed host wiring. Keep or port
   behavioral tests that protect public compiler behavior.
9. Use `rg`, dune dependency inspection, and OCaml coverage/dead-code tools to
   delete newly orphaned decoders, option conversion, module orchestration,
   artifact, process, and cache helpers.

Completed deletions:

- `run_file`
- `run_file_from_frontier_options`
- source run-plan variants and run frontend/options records in the Blorp/OCaml
  bridge; and
- OCaml host C invocation, runtime-cache selection, and child execution used
  only by source run;
- `write_compile_output`, `compile_file_with_opts`,
  `run_compile_from_frontier_options`, and their generic compile-option
  adapter;
- OCaml AST/typed-AST debug rendering and the test-only `Typed_ast_debug`
  module; and
- OCaml Core profiling and compile-profile helpers superseded by Blorp-owned
  compile timing.

Completed bootstrap-source deletions:

- `run_bootstrap_compile` and the current host's hidden compile-wrapper command;
- the wrapper argument parser and its implementation-only OCaml tests; and
- the current build's dependency on the just-built OCaml host for compiling
  the Blorp CLI.

Do not delete yet:

- OCaml match-through-specialize passes used by `blorp-ocaml-middle`;
- OCaml synthesis retained by bootstrap and in-memory compatibility callers;
- OCaml Core lowering retained by test-runner, REPL, and direct in-memory
  compatibility callers;
- their behavior-focused tests until the corresponding semantic stage ports;
- bridge decoders required solely by the pinned bootstrap, unless the
  bootstrap ratchet has removed that requirement; or
- OCaml tools still explicitly scheduled in Checkpoint 12 of the main roadmap.

## Checkpoint K: Ratchet The Bootstrap

Goal: publish and consume a compiler that exercises the new architecture
without making the migration change depend on its own release.

Status: source-side separation is complete. `compiler/bootstrap.env` is the
single checked-in release identity consumed by the resolver and CI cache keys.
Release archives now preserve a dedicated `blorp-bootstrap-compiler` and its
matching bootstrap-specific helper generation, while the resolver supports the
old `blorp-ocaml-host` artifact name only for the currently pinned immutable
toolchain. The pin intentionally remains unchanged until release CI publishes
and verifies all three target artifacts; rotation and removal of the old-name
fallback remain separate commits.

Implementation:

1. Merge the all-green host-exit revision while still bootstrapping from the
   previously pinned immutable release.
2. Let release CI publish `dev-<merged-sha>` for every supported bootstrap
   target and verify checksums.
3. In a separate commit, update the single bootstrap manifest and its cache
   key to that release.
4. Build from clean caches on macOS ARM64, Linux x86_64, and Linux ARM64.
5. Delete only the compatibility code whose named condition was that old
   bootstrap.

This separation prevents a circular release dependency and makes a failed pin
rotation independently revertible.

## Validation Matrix

Every production-boundary slice runs the focused tests first and then the full
gate before deletion:

| Concern | Required evidence |
| --- | --- |
| Protocol | Blorp decode tests, OCaml worker decode tests, malformed fixtures |
| One bridge | invocation-count tests for check/compile/run and stage dumps |
| Artifact I/O | atomic write/cleanup runtime tests and CLI `-o` tests |
| Process | argv/env/cwd/stdio/timeout/process-group runtime tests |
| Runtime cache | hit, invalidation, corruption, concurrency, clean-cache tests |
| C invocation | generated-C audit, sanitizer, TLS/raylib/FFI fixtures |
| Run semantics | CLI smoke, exit/signal/timeout/argv tests |
| Ownership | focused ASan and leak gates before and after the boundary |
| Platforms | macOS ARM64, Linux x86_64, Linux ARM64 |

Required final commands:

```bash
make
scripts/test compiler-unit
scripts/test compiler-unit-deep
scripts/test compiler
scripts/test compiler-deep
scripts/test std-check
scripts/test runtime
scripts/test leak
scripts/test doctest
scripts/test cli
make quality
scripts/premerge-gate
```

## Definition Of Done

This roadmap is complete when:

- the Blorp executable owns `check`, `compile`, and `run` command execution;
- ordinary `check` makes no OCaml call;
- `compile` and `run` make exactly one call to a phase-specific OCaml semantic
  worker while that worker is still needed;
- no CLI plan or module graph is serialized for OCaml command execution;
- Blorp decodes the worker result, runs the late Core pipeline, emits C, writes
  artifacts, invokes `cc`, manages the runtime cache, and runs programs;
- no OCaml process performs filesystem, C compiler, runtime-cache, or child
  program effects for those commands;
- the general `blorp-ocaml-host` source-command path and its test-only code are
  deleted;
- all gates pass from a clean, immutable bootstrap; and
- the remaining OCaml executable is visibly and mechanically limited to the
  semantic middle that later checkpoints will port.
