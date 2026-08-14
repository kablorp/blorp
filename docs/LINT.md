# Lint

`blorp lint` is the report-only typed source analyzer. It reuses the compiler's
normal source graph, parser, and typechecker; it does not maintain a separate
parser, type model, or discovery path.

```bash
blorp lint src/main.brp
blorp lint src/ tools/
blorp lint --format json src/
blorp lint --fail-on-findings src/
blorp lint --disable loop.list-lookup src/
```

Lint typechecks the complete import graph but reports findings only for files
selected explicitly, including files selected by a directory argument. If any
selected root fails parsing or typechecking, the invocation reports ordinary
compiler diagnostics, exits nonzero, and emits no findings. In JSON mode the
failure result remains a valid `{"schema_version":1,"findings":[]}` envelope.

Findings are sorted deterministically by path, position, rule ID, end position,
and message. Human output uses this form:

```text
path.brp:4:9: advice[structure.single-field-record]: message
```

The default exit status is zero even when findings exist. Pass
`--fail-on-findings` to make any finding fail the command for CI. Lint is
read-only and never formats or rewrites a source file.

Use repeatable `--disable RULE_ID` options for intentional, rule-specific
suppressions. Rule IDs are validated strictly; a misspelled or unsupported ID
is a usage error rather than a silently ignored suppression.

## Rules

All current rules have `advice` severity and remain report-only.

| Rule ID | Confidence | Reports |
| --- | --- | --- |
| `structure.single-field-record` | High | Records containing exactly one field. |
| `structure.single-field-struct` | High | Structs containing exactly one field. |
| `structure.single-variant-union` | High | Payload unions containing exactly one variant; enums are excluded explicitly. |
| `function.pure-no-parameters` | High | Source-defined pure functions with no parameters, unless the callable is used as a value or callback. |
| `option.immediate-parameter-match` | High | An `Option[T]` parameter directly matched by the first body expression. |
| `loop.list-lookup` | Medium | Typed `get`, `get_or`, or list subscript operations nested in a loop. |
| `loop.manual-list-index` | High | `while index < list.length()` traversal. |
| `loop.repeated-list-lookup` | High | Repeated lookup of the same simple list and index within one loop body. |
| `collection.list-append-accumulator` | High | A narrow non-escaping `[]` accumulator shape classified as `filter`, `map`, or `filter_map`. |
| `function.constant-parameter` | Medium | A parameter of a private, non-escaping function that receives one closed-world direct-call value. |

Loop advice relates the resolved list operations to the enclosing typed range
and its index uses before recommending direct iteration, `enumerate`, `zip`, or
`windows`; otherwise it gives only a conservative restructuring suggestion.

The accumulator rule intentionally rejects bodies containing additional reads,
mutations, nested loops, closure capture, or noncanonical control flow. The
constant-parameter rule propagates literals, immutable global definitions,
constructors, and forwarded parameters to a fixed point; public functions,
escaping callables, local runtime values, unresolved values, and dynamic
dispatch stay unknown. If a caller parameter's name is rebound anywhere in its
body, forwarding through that name is conservatively unknown rather than
guessed across lexical scopes. Recursive propagation is supported.
Displayed findings include at most three call-site edges so reports remain local
even when the fixed-point analysis spans a longer forwarding chain.

The current language typechecker rejects subscripting a `List`; bounds-checked
list access uses `get` or `get_or`. The typed traversal still classifies list
subscript nodes so the lint rule remains correct if such a node is supplied by a
future accepted frontend form, while the command's atomic error policy means an
invalid source never emits that finding today.

Focused lint is not a replacement for `scripts/test compiler-tools` or the
broader compiler integration gates.

The initial runtime and peak-memory observations for the focused fixture and
the `compiler/blorp/src`, `std`, `tools`, and `examples` corpus passes are kept
in
[`benchmarks/results/compiler_lint_baseline_2026-08-14.json`](../benchmarks/results/compiler_lint_baseline_2026-08-14.json).
They are local baseline observations, not performance claims.

## Initial corpus triage

The final measured report produced 1,440 findings in `compiler/blorp/src`, 207
in `std`, 84 in `tools`, and 5 in `examples`. These counts are intentionally not a
gate. The review identified these recurring legitimate advisory cases:

- parser and protocol loops that intentionally advance an index by variable
  amounts;
- pure zero-argument factory functions that produce a fresh logical value;
- API boundaries that intentionally normalize an `Option` immediately; and
- local append accumulators where the imperative shape remains clearer than a
  collection combinator.

Generated compiler build-info and embedded-standard-library modules are
excluded through an exact module inventory. TestSuite and other callback
functions are suppressed through resolved callable identity. Remaining cases
can be suppressed by rule for an invocation; source-level exemptions and CI
enforcement remain future hardening work.
