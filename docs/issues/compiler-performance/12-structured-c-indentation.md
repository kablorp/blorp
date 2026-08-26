# Avoid Repeated C Statement Re-Indentation

**Status:** Ready for a low-risk pilot; broad conversion requires measurement

## Issue Summary

Stop repeatedly splitting and rebuilding already assembled C statement strings
when nesting generated blocks. Introduce a minimal indentation-aware C fragment
or writer abstraction, convert one measured high-cost emitter family, and
expand only when the pilot improves time and allocations without bloating the
backend.

The issue is not permission to rewrite the entire emitter at once.

## Profile Evidence

The compiler self-compilation baseline took 180.545 seconds, performed 704.1
million allocations, reached 2.218 GB peak RSS, and emitted 86.093 MB / 1,252,640
lines of C. External sampling attributed 2,056 samples, 1.368% and about 2.49
seconds, to `emit.indent_statements` and direct library/runtime work.

There are currently 74 static `indent_statements` call sites in
`compiler/src/stage_10_backend/emit.brp`. Nested loops, matches, conditionals,
concurrency blocks, and statement expressions can indent text that was already
assembled and indented at a lower level. Each call splits on newline, creates
line strings, prepends two spaces, and concatenates a new result.

The backend as a whole took 62.340 seconds in the no-runtime baseline and made
217.4 million allocations while adding only about 218,000 live objects. This is
consistent with high transient string churn, though `indent_statements` is only
one contributor.

## Current Code

Primary file: `compiler/src/stage_10_backend/emit.brp`.

```blorp
private pure func indent_statements(statements: String) -> String:
	if statements == "":
		""
	else:
		var result: String = ""

		for line in statements.split("\n"):
			if line.length() > 0:
				result += "  " + line + "\n"

		result
```

The helper discards empty lines and always emits a trailing newline for each
nonempty input line. Those details are observable in generated C and must be
preserved unless deliberately changed with fixture updates.

## Problem Statement

The emitter represents structured C as fully materialized flat strings too
early. Parent constructs must parse those strings back into lines to add
indentation. Deeply nested generated code can be copied and re-indented several
times before final assembly.

## Goals

1. Represent indentation structurally until final rendering on selected hot
   paths.
2. Avoid splitting and copying the same statement block at each nesting level.
3. Preserve exact generated C, including blank-line and trailing-newline rules.
4. Keep the abstraction small and readable.
5. Prove a pilot before converting dozens of call sites.

## Non-Goals

- Do not rewrite all backend emission in one commit.
- Do not change C identifier projection or ownership lowering.
- Do not alter semantic ordering of generated statements or cleanups.
- Do not emit packed/minified C.
- Do not rely on the C formatter to repair generated output.
- Do not introduce a mutable global output buffer.

## Candidate Designs

### Candidate A: Structured C Fragment

Use a compact private union/record that holds lines or nested blocks and renders
once:

```blorp
union CFragment:
	CLine(String)
	CBlock(List[CFragment])
	CIndented(CFragment)
```

This is expressive but risks many fragment allocations. Use only if benchmarked.

### Candidate B: Writer With Explicit Indent Level

Thread a private writer/builder through selected emission functions:

```blorp
record CWriter {
	parts: List[String],
	indent_level: Int,
	at_line_start: Bool
}
```

Append indentation when a line is written, not by rewriting old text. The
writer must use ownership-friendly append/concat behavior; a list of tiny
strings can be worse than the current representation.

### Candidate C: Deferred Indentation Pair

As a low-touch pilot, return `{statements, base_indent}` or a list of unindented
lines from one high-cost subtree and render it once at the parent. This is less
general and may be the best first merge point.

Choose based on a focused allocation benchmark. Simplicity is a requirement;
do not assume an AST-like fragment tree is automatically faster.

## Mechanical Implementation Sequence

1. Add exact tests for `indent_statements`: empty input, one line, multiple
   lines, blank lines, existing indentation, and trailing/no trailing newline.
2. Build a focused benchmark that creates statement blocks of configurable
   width and nesting depth using the current helper.
3. Identify one high-frequency family, such as match branch emission or loop
   body emission, rather than choosing by source aesthetics.
4. Prototype Candidate B or C behind private helpers for that family.
5. Assert byte-for-byte equality of generated C between legacy and candidate
   rendering for the fixture.
6. Measure elapsed time, allocations, output bytes, and peak temporary/live
   objects.
7. If the pilot wins materially, migrate mechanically adjacent call sites.
8. If it does not win, revert the abstraction and retain only any independent
   consuming string-append improvement proven by measurement.
9. Run backend tests, codegen audit, C compilation, static analysis, and whole-
   compiler measurement.

## Invariants And Pitfalls

- Preserve statement and cleanup order exactly.
- Preserve braces, semicolons, and trailing newlines.
- Understand whether empty lines are intentionally removed today.
- Preprocessor directives may require column zero and must not be blindly
  indented.
- Multiline C literals/comments must not be split or rewritten incorrectly.
- Statement expressions use specific indentation and final-value placement.
- A fragment tree can retain large child strings and increase peak RSS.
- A parts list can create millions of tiny allocations; consider chunked
  assembly or consuming string append.
- Generated C size is not the only metric; native C compile time and memory must
  not regress.

## Fast Feedback Loop

Add a backend benchmark with:

```text
lines/block: 8, 64, 512, 4,096
nesting depth: 1, 4, 16, 64
blank-line ratio: 0%, 10%
iterations adjusted to keep runs under a few seconds
```

Report output byte/line count, stable hash/checksum, elapsed microseconds,
allocations/releases, and peak live objects. Include one representative Core
fixture that exercises nested match/if/loop emission, not only synthetic text.

## Functional Tests

Run:

```bash
./blorp test --timeout 180 compiler/tests/test_compiler_core_emit.brp
./blorp test --timeout 180 compiler/tests/test_compiler_core_backend_projection.brp
scripts/compiler-check --stage backend
tests/test_compiler/codegen_audit/run_codegen_audit.sh ./blorp
make quality
```

Compile the generated C with the configured C compiler. Compare generated C
bytes or a normalized exact fixture for the pilot paths. If output formatting
intentionally changes, inspect and explain every changed line.

## Acceptance Criteria

- One measured emitter family no longer re-splits/re-indents complete child
  statement strings at each nesting level.
- The pilot output is byte-for-byte equivalent or has explicitly reviewed
  formatting-only differences.
- Deep nested workloads materially reduce allocations and elapsed time.
- Generated C size, native C compilation time, and native compiler peak memory
  do not materially regress.
- The new abstraction is private, small, and simpler than the duplicated string
  work it replaces.
- Broader conversion occurs only after the pilot meets these criteria.
- Backend tests, codegen audit, C compilation, and quality checks pass.

