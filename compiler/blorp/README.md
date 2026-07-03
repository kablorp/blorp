# blorp self-hosting compiler code

This directory contains Blorp modules that are part of the compiler
implementation. These files should be written as library code with focused
TestSuite coverage under `compiler/blorp/tests`.

As the compiler migration progresses, prefer contiguous Blorp-owned pipeline
slices with one OCaml transfer point at the boundary. The current supported
backend route owns a real Core tail: `compiler_core_reuse.brp`,
`compiler_core_closure.brp`, `compiler_core_resource.brp`,
`compiler_core_fairness.brp`, `compiler_core_prepare.brp`, then
`compiler_core_emit.brp`.
Shared shallow Core expression traversal helpers live in
`compiler_core_traverse.brp`; pipeline passes still own their phase-specific
recursive rules.

The frontend migration has a live hoisted parser path backed by
`compiler_source.brp`, `compiler_parse_diagnostic.brp`, `compiler_token.brp`,
`compiler_lexer.brp`, `compiler_parser.brp`, and `compiler_parsed_ast.brp`.
These modules define pure data-model and helper APIs for Blorp-owned lexing and
parsing, and the production compiler routes source parsing through the existing
bridge protocol. Filesystem-backed compiler parses whose
supplied source matches the file on disk send path-only parse requests so the
Blorp parser bridge executable reads the source file before parsing; synthetic
parser calls still send source text directly. Source-preserving callers request
the raw parse phase; compile/check/run request the `typecheck_source` phase,
which finalizes interpolation, nested functions, and subscript reads before the
OCaml middle consumes the source AST. Parser bridge artifacts also include a
Blorp-owned syntactic module surface from `compiler_module_surface.brp` and
`compiler_module_surface_json.brp`; the CLI source graph uses that surface for
import discovery, and OCaml validates it before storing parser results in the
module parse cache.
The lexer currently covers the structural token stream, ordinary line comments,
docstrings, ordinary/raw strings, pipe strings, interpolation payloads, char
literals, and lambda-body newline behavior inside grouping tokens. The parser
currently covers an initial function-declaration slice with type parameters,
parameters, return types, docstrings, purity metadata, declaration diagnostics,
and a precedence expression core for literals, names, unary/binary/logical
operators, ranges, calls, fields, subscripts, list literals, tuple expressions,
record literals, record updates, dict literals, vector/tensor literals,
indented block bodies, `if`/`else`, simple `match` cases with qualified
constructor patterns, lambda expressions with optional parameter and return
annotations, function annotations, qualified type names, `while`, `for`,
`break`/`continue`, void primaries, local `var`
declarations, typed bindings, assignments, compound assignments, `?=`
bindings, builtin function-body markers, bounded generic parameters, dimension
parameters, tensor array/range/function/tuple types, import blocks, records,
structs, unions, enums, builtin/resource type declarations, simple type
aliases, foreign blocks, trait and impl declarations, and top-level var/const
declarations. Private declaration wrappers are represented explicitly.
Structured concurrency coverage includes `concurrent:` blocks,
`for ... concurrently(...)` loops, `detach`, and `select:` blocks. The parser
also represents `with` resource blocks and `debug:` blocks explicitly. Remaining
frontend cleanup should retire parser-adjacent OCaml transforms, expand focused
fixture coverage for current syntax, and keep parser/source-AST ownership
contiguous with the CLI source-graph frontier.

`compiler_diagnostic.brp` is the general pure diagnostic renderer for the
Blorp-owned compiler substrate. It renders Rust-style source diagnostics from
explicit source text rather than reading files during formatting, so later
typecheck and environment slices can keep error rendering deterministic and
phase-local.
`compiler_type.brp` is the first semantic type substrate: it mirrors the
current OCaml type constructors for named, array/tensor, function, tuple,
dimension, range, `Self`, and inference-meta forms, and provides pure display,
structural equality, tensor-name normalization, array decomposition, and numeric
or dimension predicates. It also provides type-parameter bound stripping,
occurs checks, cycle-safe substitution, dimension arithmetic normalization, and
array/tensor dimension validation. `compiler_context.brp` owns the baseline
context-threaded unifier over this type model.
`compiler_dim_solver.brp` ports the canonical sum-of-products dimension solver:
it handles commutative/associative/distributive dimension expressions, exact
constant division, contradictions, and simple meta or `#` dimension-variable
bindings. `compiler_context.brp` delegates dimension arithmetic to that solver;
production typecheck integration remains a later checkpoint-4 slice.
`compiler_type_widening.brp` ports the explicit value-slot widening decisions
from the OCaml frontend. It keeps semantic type and runtime value type separate
for mutable bindings, arguments, collection elements, bitwise operands, method
receivers, and numeric operands.
`compiler_refinement.brp` ports the range/subscript proof metadata and
proof-env helpers used by inference. It keeps collection identities, dimension
identities, range bounds, offset checks, branch narrowing, and binding/expr
proof payloads explicit instead of encoding them as ad hoc strings or side
tables.
`compiler_module_type_identity.brp` ports the local type-name identity helper
used by module loading. It extracts record, union/enum, and type-alias names
from parsed declarations, treating `private` wrappers as transparent and
returning a sorted unique list.
`compiler_generic_params.brp` ports structured generic-parameter helpers:
trait references, bounded type parameters, parser-source spelling, and param
name extraction. Later Env/typecheck slices should use this representation
instead of encoding bounds in raw strings.
`compiler_type_metadata.brp` ports type-policy facts used by typecheck and Core
resolution: recursion storage, primitive module homes, struct scalar eligibility,
native operator fast paths, builtin to-string fallbacks, and constructor-space
classification.
`compiler_env.brp` ports the explicit frontend environment substrate as a pure
value: lexical scopes, symbols, aliases, type/record/constructor lookup,
trait functions, trait defs, impls, overloads, UFCS methods, resource policies,
proof metadata attachment points, and alias/nominal-dimension resolution.
`compiler_builtins.brp` ports compiler-visible builtin metadata and core Env
population for primitive types, `Option`/`Result` constructors, foundational
traits/impls, builtin functions, purity/effect classification, resource
argument policy, special inference hooks, and loop-producer metadata.
`compiler_type_resolution.brp` ports the named source-annotation resolution
entrypoints over the Blorp Env: qualified module aliases, optional owner
qualification, nominal dimension disambiguation, and alias expansion or
preservation.
`compiler_context.brp` is the first explicit per-compilation context model for
the Blorp-owned frontend. It carries module-origin policy, type-home ambiguity,
resource cleanup metadata, trait-home conflict reporting, definition-id counters,
meta origins/bindings with head resolution and zonking, baseline unification
with explicit substitutions, and Core lowering counters as ordinary values. The
production OCaml session still owns mutable compiler execution today; new Blorp
frontend slices should extend this value instead of introducing ambient state.

The Blorp-owned CLI surface is split by responsibility: `compiler_cli.brp`
owns top-level planning and dispatch, `compiler_cli_args.brp` owns pure argument
parsing, `compiler_cli_plan.brp` owns shared plan data, `compiler_cli_source_graph.brp`
owns source reading/import graph/package source discovery, and
`compiler_cli_artifact_json.brp` owns bridge artifact encoding.

New work in this directory should usually expand that production path and delete
or shrink the matching OCaml implementation in the same slice. Avoid adding
standalone wrapper programs, optional compilation paths, or parallel tool
directories unless the production compiler actually needs that interface.

Renderer argument bundles currently use records because they carry C snippet
strings, template enums, and other managed/compiler values. Do not mechanically
convert these to structs unless struct fields can represent those types; current
struct fields are limited to primitive values and other structs.
