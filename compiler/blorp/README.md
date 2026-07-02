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
parsing, and the production compiler now routes hoisted source parsing through
the existing bridge protocol by default. Filesystem-backed compiler parses whose
supplied source matches the file on disk send path-only parse requests so the
Blorp parser bridge executable reads the source file before parsing; synthetic parser
calls still send source text directly.
Source-preserving callers pass `hoist_nested=false` to retain parser-level
nested function declarations without selecting a different frontend parser.
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
also represents `with` resource blocks and `debug:` blocks explicitly. Broader
parity fixtures remain a later frontend slice.

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
