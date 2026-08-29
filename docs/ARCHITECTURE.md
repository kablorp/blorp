# Blorp Compiler Architecture

This document defines the current production compiler boundaries. Source files
and phase-specific tests remain the detailed source of truth; this document
explains which phase owns each decision and the invariants passed forward.

## Production Flow

```text
source text
  -> lexed tokens and trivia
  -> parsed source AST
  -> finalized source AST
  -> loaded module graph
  -> bound names and declaration identities
  -> accepted declaration headers and trait topology
  -> typed module graph
  -> compile-time evaluation
  -> Core lowering
  -> early Core normalization
  -> late Core representation and ownership
  -> backend-ready Core
  -> C artifact
  -> platform C compiler
  -> native executable
```

Compilation is in process. Normal compiler phases exchange typed Blorp values;
there is no JSON or helper-process boundary inside production compilation.
JSON is reserved for external protocols such as LSP JSON-RPC and isolated
benchmark replay.

`compiler/src/pipeline.brp` is the authoritative cross-stage orchestration
module. From an accepted typed frontend graph, it invokes Core lowering, the existing
`stage_09_core/pipeline.brp` Core subpipeline, and the backend emission
boundary. Numbered stage modules continue to own their transformations; CLI
and LSP modules adapt their own requests and results without defining compiler
phase order.

## Source Ownership

Compiler source is organized by dependency direction:

| Stage | Responsibility |
| --- | --- |
| `pipeline.brp` | Whole-compiler sequencing across typed frontend, Core lowering and normalization, and backend emission |
| `stage_01_file_io` | Source text, spans, diagnostics, embedded inputs, and build metadata |
| `stage_02_lex` | Tokens, trivia, indentation, and lexical diagnostics |
| `stage_03_parse` | Parsed AST, parser, traversal, and source-AST finalization |
| `stage_04_modules` | Source discovery, module identity, imports, binding, and accepted graph products |
| `stage_05_types` | Semantic types, environments, contexts, builtins, refinements, and dimensions |
| `stage_06_typecheck` | Declaration identities and headers, inference, validation, and typed AST |
| `stage_07_ctfe` | Compile-time evaluation and materialization |
| `stage_08_core_lower` | Typed frontend to Core lowering |
| `stage_09_core` | Core model, transformations, representation, ownership, reuse, and invariants |
| `stage_10_backend` | Backend-ready Core projection and C artifact emission |
| `stage_11_format` | Source formatter |
| `stage_12_cli` | Public command dispatch, build/run/test sessions, package commands, purify, and lint |
| `stage_12_lsp` | Native LSP protocol, workspace actor, analysis, capabilities, diagnostics, and stdio process |

The public executable entry point is `compiler/src/stage_12_cli/main.brp`; it
adapts command requests to `compiler/src/pipeline.brp`. The native runtime lives under
`compiler/lib/`, primarily `runtime.c`, `runtime_decl.c`, and `minicoro.h`.

Dependencies should move from earlier stages to later stages. Shared facts that
are genuinely needed by several later stages belong at the earliest phase that
can construct them correctly, not in a generic utility module.

## Frontend

### Lex And Parse

`stage_02_lex/lexer.brp` converts source text into tokens with exact spans and
trivia. Indentation and continuation are lexical facts. The parser in
`stage_03_parse/language_parser.brp` constructs phase-specific source values;
it does not decide semantic type compatibility or backend representation.

`source_ast_finalize.brp` owns parser-adjacent structural normalization such as
interpolation, nested-function identity, and subscript-read normalization.
Source locations remain attached so later diagnostics never need to recover
provenance from formatted text.

### Module Graph

`stage_04_modules` discovers project, standard-library, source-package, and
native-package sources under one explicit configuration. It assigns canonical
module identities, resolves imports, and separates parser-recovery artifacts
from modules admitted to semantic checking.

Important invariants:

- local, standard-library, source-package, and native-package origins are
  explicit values rather than path-string guesses;
- import precedence is selected once by the module graph;
- duplicate or ambiguous module identities are rejected before typechecking;
- parser recovery never reserves accepted declaration identity; and
- later phases do not rescan project configuration or rediscover source files.

### Typechecking

Typechecking admits declarations through opaque phase products. The current
graph owns bound imports, declaration skeletons, resolved type parameters,
type headers, callable and global headers, trait topology, and implementation
headers before body inference consumes them. Global-header completion then
checks each initializer once and retains an opaque completed product; pending
or rejected initializer headers cannot enter accepted body checking. Exact
indexed dependency graphs provide stable topological order and iterative cycle
classification before initializer-local inference begins.

Stage 06 owns:

- bidirectional expression inference;
- purity and closure-capture checking;
- match exhaustiveness;
- trait and implementation validation;
- resource and concurrency restrictions;
- tail-recursion annotation validation; and
- construction of typed modules consumed by CTFE and Core lowering.

Accepted type aliases, records, unions, and constructors are graph-owned
authorities. Their canonical indexes are built from accepted type headers once,
and each selected module receives only the source-visibility overlay required
for its body checks. Accepted body environments do not republish those graph
declarations as lexical symbols. `Env` remains authoritative for provisional
header construction, body-local type parameters, refinements, variables, and
nested lexical scopes. Callables, globals, traits, and implementations still
use the legacy accepted-environment path pending their own vertical cutovers.

Exact identities established by the graph must survive later phases. A pass
must not reconstruct semantic identity from declaration names, module strings,
source order, or generated C spelling.

Compilation projects a successful typechecked graph into a Core-lowering input
containing only typed programs, exact import bindings, source include
directories, identity allocation state, and requested summaries. The helper
that owns the rich typechecked result returns before Core entry, so semantic
environments, diagnostics, and CTFE preparation state reach their last use
before Core preparation starts. The command-level `CliCompilePlan` still owns
its source graph until command completion; this boundary deliberately does not
claim otherwise. Adding a typecheck field to the projection requires a
specific Core consumer; it is not a general escape hatch for retaining the
typed graph.

Remaining typechecking decomposition is tracked in
[COMPILER_PRIORITIES.md](COMPILER_PRIORITIES.md). Production behavior belongs
here only after a phase product becomes authoritative.

## Compile-Time Evaluation

Stage 07 evaluates supported pure immutable global initializers before Core
lowering. Evaluation follows dependency and source-order rules established by
the accepted frontend. Unsupported operations produce compile-time diagnostics;
they do not silently become hidden startup work.

Evaluated values retain their semantic type and ownership requirements. The
backend may emit a value statically only when the complete object graph is
representable without pointers to mortal runtime objects. See
[OWNERSHIP_MODEL.md](OWNERSHIP_MODEL.md#compile-time-constants) for the storage
contract.

## Core Pipeline

Core is the typed representation used for semantic lowering, optimization,
ownership, and C preparation. `stage_09_core/ir.brp` defines the model;
JSON rendering is a debugging/tooling projection rather than an internal phase
boundary.

The production order is:

```text
lower + ffi_boundary + list_layout
  -> debug_blocks
  -> desugar + ssa
  -> mono + list_layout
  -> synth
  -> match_lowering
  -> trait_resolve
  -> resolve
  -> std_inline
  -> tailrec
  -> string_pipeline + collection_pipeline
  -> parallel_tensor_pipeline + tensor_fusion + tuple_sroa
  -> function-reference adaptation + tensor_specialize + specialize
  -> callable resolution + backend projection + match projection + dce
  -> consume_specialize
  -> record-update ownership lowering + dictionary ownership preparation
  -> perceus
  -> reuse
  -> closure
  -> resource
  -> fairness
  -> prepare
  -> reuse for prepared unions
  -> backend emit
```

`early_pipeline.brp` owns early-stage orchestration, observations, stops,
and diagnostics. `pipeline.brp` owns the contiguous late-Core order.
Changing order requires a test that demonstrates the dependency between the
affected stages.

The grouped late stages above are semantically significant. Specialization
first adapts function references and specializes tensor dispatch before general
ABI specialization. The projected DCE stage then resolves callable IDs and
projects backend calls and matches before pruning. Perceus ingress runs consume
specialization, lowers record updates to ownership-visible forms, and prepares
dictionary literals so every transferred entry is explicit. These operations
are not emitter cleanup and must not be reordered or omitted from ownership
analysis.

### Early Core Responsibilities

- Lower source semantics without inserting ad hoc retain/release operations.
- Erase or retain `debug:` nodes according to one explicit build mode.
- Convert mutable locals and supported syntax into regular Core control flow.
- Monomorphize concrete generic declarations before representation-sensitive
  work.
- Compile matches to semantic decision trees.
- Resolve traits and calls to exact callable identities.
- Lower verified self-tail recursion into loops.
- Fuse only pipelines whose callback count, order, and failure behavior are
  preserved.

### Late Core Responsibilities

- Select concrete collection, tensor, Option, Result, closure, and call layouts.
- Remove unreachable declarations without changing observable initialization.
- Make consuming-call contracts explicit.
- Insert lexical ownership through Perceus.
- Reuse allocations only from proven ownership and runtime uniqueness facts.
- Convert closures and task captures while preserving retained lifetimes.
- Insert resource cleanup and cooperative fairness checkpoints.
- Reject unresolved or unsupported representation before backend emission.

Every Core form admitted to a semantic pass must have an explicit arm. A
catch-all that treats a child-bearing form as having no type, use, ownership,
or effect is not a valid forward-compatibility strategy.

## Ownership And Representation

Source code has value semantics. Core makes the implementation of those
semantics explicit through owned, borrowed, consumed, transferred, duplicated,
and dropped values.

The ownership sequence is deliberately split:

1. Lowering and synthesis preserve source value behavior and attach known call
   contracts.
2. Perceus balances managed lexical values with explicit ownership nodes.
3. Reuse consumes only ownership facts that prove an allocation can be reused.
4. Closure and resource passes add ownership required by their protocols.
5. Final preparation rejects ownership or representation ambiguity.
6. The emitter lowers explicit facts; it does not rediscover source semantics.

The normative ABI is [OWNERSHIP_MODEL.md](OWNERSHIP_MODEL.md). The user-facing
model is [MEMORY_MODEL.md](MEMORY_MODEL.md).

## Backend

`stage_10_backend` receives backend-ready Core and produces one C artifact.
Backend projection chooses C spelling and ABI details already justified by
Core representation facts. Unsupported Core is an internal compiler error,
not an invitation for the emitter to guess.

The emitted C embeds or references the runtime according to the compile
request. Embedded artifact writing and host compilation preserve runtime and
program C as ordered parts; they do not construct a second combined source
string. The platform C compiler performs final native optimization and linking.
Blorp's compiler must still emit structurally sound C; C optimization is not a
substitute for eliminating nonlinear compiler work or unnecessary runtime
allocation.

Useful inspection commands:

```bash
./blorp compile --dump-core-after=lower,mono,closure file.brp
./blorp compile --stop-after=resolve file.brp
./blorp compile --check-invariants --dump-core-after=match file.brp
```

Use `./blorp compile --help` for the current stage and flag inventory.

## CLI And Tooling

The CLI builds one source graph and dispatches typed requests for `check`,
`compile`, `run`, `test`, `format`, `purify`, `lint`, `package`, and `lsp`.
Commands should share compiler services rather than maintain parallel parsers,
type models, module discovery, or diagnostic rendering.

The formatter works from parsed syntax and trivia. Purify and lint consume
compiler facts appropriate to their analyses. Package commands validate the
portable-source boundary described in [PACKAGES.md](PACKAGES.md).

## Native LSP

`stage_12_lsp` uses the production lexer, parser, module graph, and typechecker.
It retains the stage 06 frontend-specific boundary because its immutable
analysis snapshots stop before the reusable compilation sequence enters Core;
routing that call through the top-level pipeline would be a semantic
passthrough rather than shared orchestration.
Its process shape is:

```text
framed bytes
  -> typed protocol message
  -> serialized workspace actor transition
  -> immutable analysis snapshot
  -> compiler worker result
  -> current-revision publication
```

Only the actor advances workspace revisions. Analysis operates on immutable
snapshots. Results publish only when revision, configuration epoch, document
identity, and cancellation token remain current. The current advertised
semantic capabilities are `textDocument/documentSymbol`,
`textDocument/definition`, `textDocument/references`, `textDocument/hover`, and
`textDocument/documentHighlight`; unsupported capabilities are not advertised.
Document symbols use compiler-owned names and
source ranges from the target module index, while definition and reference
queries require complete semantic coverage. When operationally admitted, all
five requests pass through the typed `query_dispatch` boundary before the
actor executes their pure snapshot query; non-query envelopes return to
document dispatch unchanged. The query functions consume the captured
semantic-index state directly rather than reaching back through the actor
workspace. The actor captures exactly one immutable workspace snapshot per
accepted query and executes the query synchronously before returning to the
event loop.
Hover follows the same exact-identity path as definition and references. Its
first slice publishes only the indexed declaration name and selection range;
type rendering is deferred until the typed compiler product has a stable
protocol-facing representation.
Target-level analysis failures publish their structured diagnostics. If a
graph-wide failure, planning failure, or rejected completion has no trustworthy
source span, the actor publishes an empty publication at the current target
identity to replace older diagnostics without fabricating a location. Stale
completions publish nothing.

## Build

`make` resolves the immutable bootstrap compiler from `compiler/bootstrap.env`,
uses it to compile `compiler/tools/generate_build_sources.brp`, generates
embedded standard-library/runtime/build metadata, and compiles
`stage_12_cli/main.brp` to C without embedding the bootstrap runtime. The
platform C compiler links that generated C against a separately compiled copy
of the current workspace runtime. This avoids a one-bootstrap-generation delay
for runtime fixes while the generated runtime-source provider remains embedded
for programs compiled by the resulting `./blorp`.

The bootstrap is a build input, not a second production compiler architecture.
The newly built `./blorp` is the executable used for local development and
tests.

## Tests And Gates

Use the narrowest gate that owns the changed boundary:

```bash
scripts/compiler-check --changed
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
scripts/test compiler-tools
scripts/test compiler-core-sanitize
scripts/test runtime
scripts/test leak
scripts/test doctest
scripts/test cli
scripts/test lsp
scripts/test package
```

`compiler/tests/compiler_test_ownership.json` assigns every production
compiler module to focused suites and integration checks. `make quality`
rejects unowned modules or nonexistent ownership entries.

Codegen changes require generated-C inspection. Ownership changes require
canonical event checks plus relevant runtime, leak, and sanitizer coverage.
Protocol and CLI changes require process-level fixtures, not only pure codec
tests.
