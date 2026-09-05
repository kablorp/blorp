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

`blorp/src/compiler/pipeline.brp` is the only authoritative cross-stage orchestration
module. It invokes typed frontend compilation, Core lowering, the existing
`stage_09_core/pipeline.brp` Core subpipeline, and the backend emission
boundary. Numbered stage modules own individual transformations but do not
define whole-compiler phase order. `blorp/src/lib/compilation.brp` is the shared
application boundary that translates command requests and compiler products:
it translates CLI plans and options into pipeline requests and translates
pipeline products into command results.

Check-only and analysis commands also enter typechecking through
`blorp/src/compiler/pipeline.brp`; CLI command modules do not invoke the typechecker
directly. This keeps stopping after the typed frontend as a pipeline policy,
not a second orchestration path.

The LSP compiler service follows the same rule. Stage 6 translates a validated
frontend graph into a typecheck request, while `blorp/src/compiler/pipeline.brp`
invokes the typechecker and returns the completed typed graph to the LSP shell.

## Source Ownership

Compiler source is organized by dependency direction:

| Stage | Responsibility |
| --- | --- |
| `pipeline.brp` | Exclusive whole-compiler sequencing across typed frontend, Core lowering and normalization, and backend emission |
| `command.brp` | Public `blorp compile` command effect, artifact publication, and compiler-output rendering |
| `runtime_source_provider.brp` | Compiler-executable boundary for the build-linked native runtime source and declarations |
| `blorp/src/main.brp` | Sole executable composition root and command dispatch |
| `blorp/src/lib/runtime_sources.brp` | Shared typed contract used to pass runtime source text from the composition root to compile, run, and test effects |
| `stage_01_generated_inputs` | Generated embedded standard-library source and compiler build metadata |
| `stage_02_lex` | Tokens, trivia, indentation, and lexical diagnostics |
| `stage_03_parse` | Parsed AST, parser, traversal, and source-AST finalization |
| `stage_04_modules` | Project and package discovery, module identity, import resolution, retained module surfaces, and validated graphs |
| `stage_06_typecheck` | Semantic types, environments, contexts, builtins, refinements, dimensions, declaration identities and headers, inference, validation, and typed AST; foundational type-system modules live under `type_system/` |
| `stage_07_ctfe` | Compile-time evaluation and materialization |
| `stage_08_core_lower` | Typed frontend to Core lowering |
| `stage_09_core` | Core model, transformations, representation, ownership, reuse, and invariants |
| `stage_10_backend` | Backend-ready Core projection and C artifact emission |
| `blorp/src/format` | Source-format command and rendering engine; temporarily consumes the parser recovery AST through an explicit migration edge |
| `blorp/src/test` | Production implementation of the `blorp test` command; its mirrored tests live in `blorp/test/test` |
| `blorp/src/lsp` | Native LSP protocol, workspace actor, analysis, capabilities, diagnostics, and stdio process |

The public executable entry point is `blorp/src/main.brp`; it dispatches the
compile command through `blorp/src/compiler/command.brp`. The composition root
loads the build-linked runtime through
`blorp/src/compiler/runtime_source_provider.brp` and passes the shared
`RuntimeSources` value explicitly to compile, run, and test effects. Compilation
command effects use `blorp/src/lib/compilation.brp` to adapt requests to
`blorp/src/compiler/pipeline.brp`. The native runtime lives under
`blorp/src/lib/runtime/native/`, primarily `runtime.c`, `runtime_decl.c`, and `minicoro.h`.

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

Accepted aliases, records, unions, globals, source/foreign callables, traits,
and implementations use
separate graph-owned, category-specific
authorities. Their canonical payloads are built from accepted type headers
or completed global headers once; each selected module retains only established
declaration identities and scalar source-name/visibility or constructor locators. Exact lookup validates the complete nominal
identity before addressing category storage, and canonical-name fallback
exposes only public declarations. Canonical module views are retained in the
prepared module facts used by initializer and ordinary-body sessions. The CTFE
artifact path derives a distinct dependency-only view on demand instead of
retaining a second canonical view or exposing target-only imports.

The global authority keeps resolved annotated types available while checking
initializers, but admits an inferred global only when the completion plan names
its exact already-completed dependency. Ordinary bodies see only successfully
completed entries. Local lexical variables remain in `Env` and take precedence
over global-view lookups; selective aliases and qualified module reads resolve
through the module view without rebuilding a legacy variable symbol.

Accepted body environments do not republish alias targets, record fields,
union variants, constructors, or accepted type-containment facts as lexical
symbols. Resource queries ask `Env` only for builtin or provisional facts,
then consult the category-specific accepted record and union authorities.
Owner-local record and variant field spellings are localized from their one
canonical payload only when a payload reader needs them; scalar category and
containment queries do not materialize fields. Recursive capability scans
honor accepted negative containment proofs before opening component payloads.
The accepted-callable table owns one complete semantic entry per accepted
source or foreign callable. Prepared module views retain ordered table indices
for owner-local names, selective imports, qualified access, and ordinary
source-function UFCS. They do not retain copies of signatures or constraints;
owner-local queries localize canonical nominal type spellings at the read
boundary. The accepted trait/implementation table owns one semantic trait or
implementation payload per accepted header. Module views retain compact,
ordered indices for owner-local and public direct-import visibility, inherited
method lookup, and candidates grouped by satisfied trait. Owner-local method
and receiver types are localized only when read; accepted source traits,
implementations, and methods are not republished into prepared `Env` values.

`Env` remains authoritative for provisional header construction, compiler
builtins, body-local type parameters and their bounds, refinements, variables,
and nested lexical scopes. It has no standalone UFCS collection; UFCS reads
from `Env` inspect only actual session functions in those scopes. A
resolved call retains the selected candidate's bound type parameters and
debug-only status; accepted body checking neither republishes graph callables
into `Env` nor scans graph functions by name or definition ID.

Type-header projection into an accepted module session is deliberately narrower
than provisional installation. Authority-present alias, record, and union paths
record known type names and nominal homes only; they do not rebuild targets,
fields, variants, constructors, or containment payloads in `Env`. The alias path
checks authority before converting its resolved target, so that conversion and
containment work is reserved for provisional checking. Compiler builtins remain
the intentional exception because their runtime/type-system primitives are
session inputs rather than graph-owned source declarations.

`PreparedCanonicalModuleEnvironment` is built once per accepted module and
contains reusable declaration and inference-module facts. Every initializer and
ordinary body derives a fresh `PreparedInferSessionEnv`, preserving independent
metas, diagnostics, refinements, and lexical scopes without reconstructing the
module base. CTFE does not retain another graph-owned environment: it constructs
a dependency-only module view on demand, replays reserved definition IDs into a
fresh session, and releases that preparation with the CTFE check.

Exact identities established by the graph must survive later phases. A pass
must not reconstruct semantic identity from declaration names, module strings,
source order, or generated C spelling.

`PreparedModuleScope` may carry a private target-first numeric slot for
addressing graph-owned products such as TypeHeader per-module inventories. The
slot is valid only after compatibility with that product's owning graph is
proved, is unstable when graph composition changes, and is not a nominal module
identity. Durable `ModuleIdentity`, declaration IDs, typed programs, semantic
occurrences, diagnostics, and external projections therefore never replace
their owners with this internal ordinal.

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
  -> static_string_literals
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
bin/blorp compile --dump-core-after=lower,mono,closure file.brp
bin/blorp compile --stop-after=resolve file.brp
bin/blorp compile --check-invariants --dump-core-after=match file.brp
```

Use `bin/blorp compile --help` for the current stage and flag inventory.

## CLI And Tooling

The CLI builds one source graph and dispatches typed requests for `check`,
`compile`, `run`, `test`, `format`, `purify`, `lint`, `package`, and `lsp`.
Commands should share compiler services rather than maintain parallel parsers,
type models, module discovery, or diagnostic rendering.

The formatter works from parsed syntax and trivia. Purify and lint consume
compiler facts appropriate to their analyses. Package commands validate the
portable-source boundary described in [PACKAGES.md](PACKAGES.md).

## Native LSP

`blorp/src/lsp` uses the production lexer, parser, module graph, and typechecker.
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

`make` resolves the immutable bootstrap compiler from `blorp/build/bootstrap.env`,
uses it to compile `blorp/tool/generate_build_sources.brp`, generates
embedded standard-library/runtime/build metadata, and compiles
`blorp/src/main.brp` to C without embedding the bootstrap runtime. The
platform C compiler links that generated C against a separately compiled copy
of the current workspace runtime. This avoids a one-bootstrap-generation delay
for runtime fixes while the generated runtime-source provider remains embedded
for programs compiled by the resulting `bin/blorp`.

The bootstrap is a build input, not a second production compiler architecture.
The newly built `bin/blorp` is the executable used for local development and
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

`blorp/test/compiler/compiler_test_ownership.json` assigns every production
compiler module to focused suites and integration checks. `make quality`
rejects unowned modules or nonexistent ownership entries.

Codegen changes require generated-C inspection. Ownership changes require
canonical event checks plus relevant runtime, leak, and sanitizer coverage.
Protocol and CLI changes require process-level fixtures, not only pure codec
tests.
