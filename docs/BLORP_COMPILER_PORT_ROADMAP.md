# Blorp Compiler Port Roadmap

Status: active, checked against code on 2026-07-31.

This is the detailed execution plan for deleting the remaining OCaml compiler
and tool implementation. It records only the current boundary, remaining
inventory groups, deletion order, and required proof. Completed migration
history belongs in Git.

Use [ARCHITECTURE.md](ARCHITECTURE.md) for the full live pipeline and
[COMPILER_ROADMAP.md](COMPILER_ROADMAP.md) for cross-cutting compiler
priorities.

## Current Production Path

Normal `check`, `compile`, and `run` begin and end in the Blorp executable:

```text
Blorp CLI / source graph / source reads / parse
  -> Blorp typecheck / CTFE
  -> Blorp Core lowering / flattening / FFI boundary / list layout
  -> Blorp debug / desugar / SSA / mono / synthesis / match
  -> Blorp trait and call resolution / std inline / tailrec
  -> Blorp string, collection, parallel-tensor, and tensor-update fusion
  -> Blorp runtime-declaration projection / tuple SROA
  -> Blorp value, collection, and tensor specialization
  -> Blorp DCE / consume specialization / Perceus / reuse
  -> Blorp closure / resource / fairness / final preparation / C emission
  -> Blorp artifact writing / runtime cache / host C / optional execution
```

Ordinary `check`, `compile`, `run`, and `purify` make no OCaml call. Their
compilation and analysis pipelines are contiguous Blorp call graphs. The OCaml
host remains for `lsp` and package commands.

The immutable compiler named by `compiler/bootstrap.env` is a build trust root,
not part of the compiler being migrated.

The unsupported OCaml REPL and its line editor were deleted instead of
preserving a weakly tested host-only feature. A future REPL should be a new
Blorp-owned client of the ordinary compile/run services, not a porting
prerequisite or compatibility path.

## Migration Rules

1. Move one contiguous production responsibility at a time.
2. Add focused behavior or parity tests before changing routing.
3. Route production through the Blorp implementation before deleting OCaml.
4. Delete replaced OCaml implementation and implementation-only tests in the
   same change.
5. Keep remaining JSON and process boundaries command-specific; use typed
   values inside compilation.
6. Do not add optional parallel implementations or source-spelling heuristics.
7. Preserve existing definition IDs, ownership facts, diagnostics, stage
   observations, and deterministic output.
8. Keep compatibility code only for an explicitly named bootstrap condition,
   with a deletion condition beside it.
9. Stop a slice when its responsibility is complete. Do not absorb adjacent
   refactors merely because the same files are open.

## Inventory Contract

`compiler/blorp/src/stage_99_meta/ocaml_port_inventory.tsv` is the exact
machine-checked list of production OCaml sources. Every tracked production
`.ml`/`.mli` file must belong to one of these groups:

| Group | Responsibility and deletion condition |
| --- | --- |
| `bridge` | Process/JSON boundary clients and decoders; delete after no OCaml phase boundary remains |
| `backend` | C names, types, layout helpers, and Core projection; delete after Blorp owns all final representation policy |
| `final_core` | Option/result/tensor/hash-container layout policy; delete after no OCaml consumer selects runtime storage |
| `middle_core` | Remaining semantic worker, Core model, fusion, specialization, and orchestration |
| `lowering` | Ratchet: source-to-Core lowering is Blorp-owned and must not return to OCaml |
| `ctfe` | Remaining top-level initializer facade; delete after no OCaml type/tool path consumes it |
| `type_system` | OCaml type/env/infer/typecheck support still used by remaining consumers |
| `parser` | OCaml parsed-AST/module-surface facades still used by remaining consumers |
| `tools` | Host command shell, test runner, LSP, packages, diagnostics, platform, and generators |

The TSV, not this table, owns the path list and counts.
`scripts/check-compiler-port-inventory` enforces coverage and the allowed group
names.

An OCaml file should be deleted, not ported, when its only remaining callers
are implementation-only tests or another file being deleted in the same
slice.

## Checkpoint 1: Remove The Semantic Middle

Status: implementation complete; full cross-platform validation pending.

### Goal

Make Blorp own the contiguous Core pipeline from source lowering through final
C emission, eliminating `blorp-ocaml-middle`.

### Result

The CLI carries a typed `CoreProgram` directly from tuple SROA into the
Blorp-owned late pipeline. Specialization builds one declaration/layout index
per program and composes value, collection/stream, and tensor current-node
rewrites under one recursive traversal. Runtime declaration projection remains
a normal Core pass; it is no longer a serialization boundary.

The private middle executable, protocol/client, strict OCaml decoder, OCaml
pipeline, specializer/fallback, emitter/projection, representation helpers,
invariants, registry helpers, and implementation-only tests have been deleted.
Build, release, install, CI, and benchmark wiring no longer expects
`blorp-ocaml-middle`.

### Completed Execution

1. Captured focused Core inputs for each remaining pass family and asserted exact
   semantic output, not only generated-C success.
2. Extended the corresponding Blorp Core pass or added the narrow missing pass in
   the existing `stage_09_core` pipeline.
3. Preserved pass order in one pipeline manifest without duplicating orchestration
   in the CLI or bridge.
4. Compare stage dumps and generated C on collection pipelines, tensor
   pipelines, tuple-return scalar replacement, generic specialization, and
   unsupported-layout fallback cases.
5. Routed the production pipeline directly from Blorp tuple SROA through the
   remaining Blorp middle stages to specialization/DCE.
6. Deleted the OCaml worker, decoder, orchestration, replaced pass modules, and
   implementation-only tests.
7. Removed the worker from build, release, cache, and bootstrap toolchain
   manifests.

### Required Edge Cases

- List producer callback order and element ownership.
- `filter_map` payload lifetime and forward-compacting handoff writes.
- Parallel vector/matrix scope and fallback behavior.
- Tensor bounds proofs, raw views, scalar fills, reductions, and layout.
- Tuple boxing and nonescaping return-call scalar replacement.
- Generic and trait-specialized callable identity.
- Stage dumps, `--stop-after`, and invariant checks at the moved boundary.
- Unsupported representation must fail closed rather than select a guessed
  runtime ABI.

### Proof

```bash
scripts/test compiler-unit compiler
scripts/test compiler-deep
scripts/test compiler-core-sanitize
scripts/test runtime leak
make quality
git diff --check
```

Inspect generated Core before and after the removed boundary and generated C
for every representation-changing case.

### Deletion Condition

Met: no production command starts `blorp-ocaml-middle`, and no OCaml module
performs a Core-to-Core semantic transformation.

## Dependency Waves After The Semantic Middle

Checkpoints 2 through 4 describe ownership boundaries, not strict sequential
gates. Their remaining files form a consumer graph: tools still consume OCaml
parser and type-system facades, while some frontend and tool modules still
consume representation helpers.

With checkpoint 1 cut over, migrate one semantic or tool consumer, delete the
representation/frontend dependencies that became unreachable, and repeat.
Never retain a mirror merely to make an inventory group disappear in one later
batch, and never port an orphaned dependency whose last consumer can be
deleted.

## Checkpoint 2: Unify Final Representation Facts

### Goal

Make Blorp the only owner of ownership contracts, final Core layout, boxing,
runtime operation selection, and C naming. Remove each OCaml mirror when its
last semantic or tool consumer moves.

### Current Progress

The OCaml Core model, structured Core errors, ownership contracts, tensor and
erased-storage layout helpers, Option layout policy, and their
implementation-only tests have been deleted. Their production responsibilities
are owned by the Blorp Core pipeline. The remaining `final_core` files are
narrow type/layout helpers still consumed by host-side ABI and tooling paths.

### Execution

1. Identify the final production consumer of every `ownership`, `final_core`,
   and `backend` inventory file.
2. Move missing facts into typed Blorp manifests, phase-specific Core nodes, or
   final preparation. Do not recreate OCaml string maps in Blorp.
3. Keep foreign ABI policy separate from internal representation policy.
4. Make option/result, tuple, list, tensor, hash-container, record, union, and
   erased storage choices explicit before C emission.
5. Delete each OCaml mirror as soon as its last production consumer is gone.
6. Remove bridge projection helpers once no OCaml Core value must be serialized.

### Required Edge Cases

- Stack, nullable-pointer, and boxed `Option` layouts.
- Stack and boxed `Result` payloads.
- Inline versus pointer collection storage and element destructors.
- Foreign-visible record/struct field order and scalar ABI.
- Closure capture ownership and owned managed returns.
- COW consume, transfer, borrowed-result aliasing, and resource cleanup.
- Static constants and immortal object graphs.

### Proof

Run focused ownership/layout unit tests, generated-C audits, ASan/UBSan, leak
tests, compiler-shaped benchmarks, and the normal quality gate. A successful C
compile without an inspected representation is not sufficient proof.

### Deletion Condition

Blorp owns every final representation fact. Any remaining `ownership`,
`final_core`, or `backend` file is an explicit dependency of a checkpoint 3 or
4 consumer and is deleted immediately when that consumer moves. These groups
become empty in the checkpoint 4 cleanup pass, except for an explicitly
documented native source generator that remains part of the build.

## Checkpoint 3: Delete Frontend And Type-System Mirrors

### Goal

Delete OCaml parser, type-system, CTFE, and typed-AST code after their remaining
tool and compatibility consumers move to Blorp.

The production source path already parses, typechecks, evaluates constants,
and lowers typed programs in Blorp. Therefore, start with reachability:

1. Classify each `parser`, `ctfe`, and `type_system` file as production-used,
   test-only, or orphaned.
2. Delete orphaned functions/files and migrate tests to the authoritative Blorp
   owner before porting more code.
3. Replace remaining OCaml consumers with typed Blorp artifacts rather than
   rebuilding semantics from source.
4. Keep parser consumers on the raw parsed AST and semantic consumers on the
   finalized typed program.
5. Introduce structured diagnostics with source spans before moving tools that
   currently depend on rendered typecheck text.
6. Preserve one graph-wide definition-ID space across parse, typecheck, CTFE,
   Core, tools, and diagnostics.

### Required Edge Cases

- Qualified/selective imports, aliases, package roots, and private exports.
- Generic bounds, traits, overloads, UFCS, refinements, range and tensor
  dimensions.
- Purity, resources, operation results, unused imports, and declaration
  ordering.
- CTFE dependency order, recursion, constants, materialization, and unsupported
  pure operations.
- Raw parser output for formatter/LSP versus finalized source for typecheck.
- Diagnostics retain exact file, line, column, and help text.

### Proof

Use the existing parser, infer, typecheck, formatter, purify, compiler-unit,
compiler-owned Blorp, and doctest suites. For each deletion, prove the public
behavior remains covered outside the removed OCaml implementation test.

### Deletion Condition

No compiler semantic path depends on `parser`, `ctfe`, or `type_system`
mirrors. Any remaining files serve only named checkpoint 4 tool consumers and
are deleted as those tools move; the groups become empty in the checkpoint 4
cleanup pass.

## Checkpoint 4: Port Tools And Delete The OCaml Host

### Goal

Move every public command to Blorp and delete `blorp-ocaml-host`.

### Current State

- `check`, `compile`, `run`, `format`, and `purify` are Blorp-owned.
- `purify` consumes resolved callable identities and typed purity requirements,
  computes module-local recursive candidate sets, rewrites parser-owned keyword
  spans, and validates every proposed rewrite before writing.
- `test` is fully Blorp-owned. Discovery, retained frontend graphs, bounded
  batching, TestSuite and doctest harnesses, host-C compilation, captured
  execution, timeout handling, leak/profile policy, and aggregate reporting do
  not cross the OCaml host boundary. The architecture and completed cutover
  are documented in
  [BLORP_TEST_SESSION_ROADMAP.md](BLORP_TEST_SESSION_ROADMAP.md).
- `lsp` and package commands delegate to the OCaml host.
- Their maintained coverage enters through retained OCaml suites, the public
  `lsp` and `package` gates, and Blorp-owned package modules. The OCaml suites
  remain until the coverage ledger proves public parity; new behavior coverage
  must survive the eventual host deletion.
- Package parsing/hash/inventory and source validation have Blorp-owned
  components, but the public package command shell remains OCaml-owned.

### Order

1. **Test runner:** first add a test-specific execution/reporting effect and
   prove representative compiler-suite parity. Then move discovery,
   `TestSuite` identity, doctest extraction, harness construction, semantic
   isolation groups, scheduling, timeout/process cleanup, caching, and result
   framing before changing production routing.
2. **Packages:** manifest validation, source validation, content hashing,
   artifact pack/unpack, cache publication, fetch, and vendor.
3. **LSP:** diagnostics, symbols, hover, completion, signature help,
   references, declarations/definitions, inlay hints, and formatting over
   shared parse/typecheck outputs.
4. Delete the host dispatcher and every tool module after its public command
   and tests have moved.
5. Delete parser, CTFE, type-system, ownership, layout, and backend mirrors
   made unreachable by the moved tools.

### Tool Invariants

- Tools call shared compiler services; they do not implement another parser or
  typechecker.
- Formatter remains a raw-parse consumer.
- Doctest remapping uses structured spans, never parsed diagnostic strings.
- Test timeouts terminate process groups and remove temporary artifacts.
- Test grouping follows semantic isolation requirements, not file-count
  heuristics.
- Test-result caching remains disabled until compilation artifacts expose an
  exact transitive source-dependency manifest that participates in the cache
  key. Do not infer dependencies from direct input paths or timestamps.
- LSP sessions cannot leak declarations or diagnostics between documents.
- Package hashes cover normalized relative paths and raw file contents.
- Cache entries become visible atomically only after verification.

### Proof

```bash
scripts/test compiler-unit-deep
scripts/test doctest cli lsp package
scripts/test
make security-check
make docker-premerge-gate
```

Also run protocol-level LSP tests and local package fetch/vendor tests.

### Deletion Condition

No public command delegates to OCaml, `compiler/bin/blorp_ocaml_host.ml` is
deleted, the `tools` inventory group is empty, and the final consumer cleanup
has emptied `parser`, `ctfe`, `type_system`, `ownership`, `final_core`, and
`backend` except for explicitly retained native source generators.

## Checkpoint 5: Remove Bridges And Bootstrap Compatibility

### Goal

Leave one shipped Blorp executable and one immutable external bootstrap
toolchain used only to build it.

### Current Boundary

The standalone typecheck and backend workers are benchmark-owned and no longer
participate in bridge preparation, installation, CI test setup, or release
packaging. Production typechecking and backend emission remain in the public
Blorp compiler. The parser helper is the only shipped compiler worker boundary.

### Execution

1. Delete process clients, JSON codecs, and cache keys for retired parser,
   typecheck, renderer, and host boundaries.
2. Keep only serialization that is a public artifact/protocol or an explicit
   test fixture.
3. Remove old executable-name and environment-selector fallbacks after their
   remaining OCaml-hosted tool consumers move.
4. Publish and verify a complete release before rotating
   `compiler/bootstrap.env`.
5. Build from a fresh bootstrap cache on macOS ARM64, Linux x86_64, and Linux
   ARM64.
6. Delete obsolete helper executables from release archives and installation.

### Deletion Condition

The `bridge` group is empty. The released toolchain contains one public Blorp
binary; that same binary becomes the external build trust root when pinned.

## Cross-Cutting Validation

Before deleting an OCaml implementation, require:

| Area | Evidence |
| --- | --- |
| Parser/source model | Parser fixtures, formatter regressions, exact diagnostics |
| Module/type system | Infer/typecheck pass/fail fixtures and direct Blorp tests |
| CTFE | Constant behavior, materialization, static C, and failure diagnostics |
| Core | Stage snapshots, invariants, generated-C audit, runtime behavior |
| Ownership/layout | ASan/UBSan, leak accounting, generated Core/C inspection |
| Tools | Public CLI exit status, stdout/stderr, files, protocol messages |
| Performance | Comparable before/after measurements for affected workloads |
| Platforms | macOS ARM64, Linux x86_64, Linux ARM64 before a release pin |

Small deletion slices:

```bash
scripts/test compiler-unit compiler
git diff --check
```

Production-boundary slices:

```bash
make
scripts/test compiler-unit compiler runtime leak doctest cli
scripts/test compiler-deep
make quality
```

Final shell or release changes:

```bash
scripts/test
scripts/premerge-gate
make docker-premerge-gate-all
```

## Definition Of Done

The migration is complete when:

- `check`, `compile`, `run`, `test`, `format`, `purify`, package commands, and
  `lsp` execute through Blorp-owned code;
- no OCaml process owns parser, module graph, typecheck, CTFE, typed AST, Core,
  ownership, C emission, artifact, runtime-cache, host-C, or tool behavior;
- the OCaml production inventory is empty;
- no retired compiler bridge or helper is shipped;
- the pinned public Blorp compiler is the only external build trust root; and
- normal, deep, sanitizer, leak, quality, preview, and cross-platform gates
  pass.
