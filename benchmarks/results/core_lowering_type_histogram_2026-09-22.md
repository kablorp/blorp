# Core lowering type histogram, real self-compile (2026-09-22)

Follow-up to `core_lowering_allocation_attribution_2026-09-22.md`, requested
before implementing cut 1: real numbers from the frozen self-compile, not
only the synthetic fixture.

## Instrumentation

New counters at the type-lowering choke point
(`core_lower_type_with_prefixes`, `blorp/src/compiler/stage_08_core_lower/lower.brp`),
opt-in through `BLORP_CORE_LOWERING_TYPE_METRICS=1`, following the same
pattern as `BLORP_TYPECHECK_BODY_METRICS`/`BLORP_TYPECHECK_PHASE` (see
`blorp/src/compiler/stage_06_typecheck/bridge.brp` and
`blorp/src/compiler/stage_06_typecheck/decl.brp:11107`): a C-side hash table
keyed by the lowered `CoreType`'s `core_type_to_json` text
(`blorp/src/lib/runtime/native/runtime.c`, `__blorp_core_lowering_type_*`),
recording total calls and per-shape counts, flushed to stderr as
`BLORP_CORE_LOWERING_TYPE_METRICS`/`BLORP_CORE_LOWERING_TYPE_TOP` lines. With
the variable unset it is one branch per call and no allocation — confirmed
by rerunning `benchmarks/compiler_core_lowering_allocation_attribution`
after adding it: identical output to before.

Command (frozen self-compile input, `--stop-after=lower`):

```bash
base=$(git rev-parse origin/main)
input=$(benchmarks/self_compile_measure freeze --rev "$base")
BLORP_CLI_C_OPTIMIZATION=-O2 make
BLORP_COMPILER_MEMORY_PROFILE=1 BLORP_CORE_LOWERING_TYPE_METRICS=1 bin/blorp compile \
  --stop-after=lower --no-format --std-dir "$input/standard_library/src" \
  "$input/blorp/src/main.brp" >/dev/null 2>lower_histogram.log
```

`lower_typed_program_with_ctfe_replacements` is called once per module, so
the counters are cumulative across the whole run; the last
`BLORP_CORE_LOWERING_TYPE_METRICS` line before the final
`core_lowering_complete` checkpoint is the total for the whole compile.

## Result: calls, distinct shapes, top 30

```
BLORP_CORE_LOWERING_TYPE_METRICS schema=1 calls=1275348 distinct=22180
```

Top 30 by count (module-path prefixes on user types elided below for
readability; the raw log keeps the full frozen-input path):

| rank | count | type |
|---|---|---|
| 1 | 167795 | `String` |
| 2 | 76936 | `CoreExpr` |
| 3 | 69715 | `Bool` |
| 4 | 66561 | `Int` |
| 5 | 33099 | `Void` |
| 6 | 28908 | `CoreType` |
| 7 | 25913 | type param `T` |
| 8 | 22911 | `json::JsonValue` |
| 9 | 16853 | `List[String]` |
| 10 | 15135 | `Option[String]` |
| 11 | 14600 | `SemanticType` |
| 12 | 11932 | `List[T]` |
| 13 | 10767 | `CoreVar` |
| 14 | 8975 | `CoreJsonError` |
| 15 | 6426 | `InferContext` |
| 16 | 6271 | `SourceLocation` |
| 17 | 6110 | `(String, JsonValue)` tuple |
| 18 | 6012 | `CoreSourceLoc` |
| 19 | 5987 | `Option[CoreExpr]` |
| 20 | 5939 | `List[CoreExpr]` |
| 21 | 5840 | `Doc` |
| 22 | 4883 | `FunctionBodyC` |
| 23 | 4679 | `Option[Int]` |
| 24 | 4572 | `ParsedExpr` |
| 25 | 4334 | `CoreParam` |
| 26 | 4068 | `PerceusEnv` |
| 27 | 3946 | `TypedExpr` |
| 28 | 3885 | `CtfeValue` |
| 29 | 3663 | `Option[T]` |
| 30 | 3627 | type param `S` |

Of these 30 rows (650,342 calls, 51% of all calls), **22 are arg-less named
types or bare type parameters** (580,044 calls, 89% of the top-30's calls,
45% of all calls); only 8 rows are parameterized (`List[...]`, `Option[...]`,
one tuple), totaling 70,298 calls. The pattern holds into the tail: this is
the compiler compiling itself, so its own record/union names (`CoreExpr`,
`CoreType`, `SemanticType`, `CoreVar`, ...) dominate exactly the way a
`List[String]`-heavy user program's own domain types would dominate for that
program. **Arg-less named types and type parameters dominate the histogram**,
confirming the coordinator's hypothesis and picking the design below.

## Design decision

Per the coordinator's steer: since arg-less scalars dominate, add the
cheaper half first (module-level constants, no memo, no probe) and measure
before building the per-function pre-walk memo.

Implemented: `core_lower_type_with_prefixes`'s `SemanticNamedType` arm
already had a `VoidType` short-circuit; added four more for the remaining
built-in scalars with zero args — `String`, `Bool`, `Int`, `Char`, `Float` —
returning a shared module-level `CoreType` constant instead of rebuilding
`NamedType(name, [])` (`blorp/src/compiler/stage_08_core_lower/lower.brp`,
new `CORE_CHAR_TYPE`/`CORE_FLOAT_TYPE` constants; reused the existing
`CORE_STRING_TYPE`/`CORE_INT_TYPE`/`CORE_BOOL_TYPE` constants already used by
literal-expression lowering rather than duplicating them). Each check is a
single `args.length() == 0 and normalized == TYPE_NAME_X` comparison already
alongside the existing Void check — no probe, no cache, no per-call linear
scan, so the "identity probe must cost less than what it saves" gate does
not apply here (there is no probe).

**Did not implement the per-function pre-walk memo (point 2's identity-keyed
cache).** The histogram shows why it would not pay for itself here: the
handful of parameterized types that actually recur by shared object
(`List[String]`, `Option[String]`, `List[CoreExpr]`, ...) are a small
minority of calls (70,298, 5.5% of the total), and the compiler's own
record/union names that dominate the rest are *already* cheap to lower (an
arg-less `NamedType` build is roughly 1-2 allocations: `normalize_type_name`
and `flatten_canonical_core_type_name_with_prefixes` are no-ops for a name
with no `::` in it, so the only work left is the `NamedType` node and the
`Result` wrapper). A back-of-envelope estimate — cache the 8 parameterized
top-30 rows, save roughly 3 of their ~4 allocations per repeat occurrence —
comes to on the order of 200K saved allocations, well under the roughly
6.5M-allocation budget the fixture's 25% figure would have suggested, and
nowhere near enough to justify restructuring the recursive-descent
expression lowering to thread an updated `CoreLowerContext` per node (the
obstacle already documented in
`core_lowering_allocation_attribution_2026-09-22.md`). Keeping only the
constants, as the coordinator's fallback said to do.

## Acceptance

Compared a clean build of the parent commit (`e2a27e3f`, cut 0 only) against
this worktree's build (parent + type-metrics counters + scalar-constant
cut), both against the frozen `origin/main` self-compile input, under
`benchmarks/self_compile_measure lock --`:

```bash
benchmarks/self_compile_measure --compiler <parent-build>/bin/blorp --skip-build-check \
  --label lower-parent --input-rev "$base" --samples 1 --output /tmp/lower-parent.json
benchmarks/self_compile_measure --label lower-cut1 --input-rev "$base" --samples 3 \
  --baseline /tmp/lower-parent.json --output /tmp/lower-cut1.json --require-identical
```

```
output C : IDENTICAL (160090804 vs 160090804 bytes)

metric                                  baseline        candidate     delta
allocs core_lowering_complete        19,333,605       19,025,651    -1.59%
allocs pass_mono_complete            28,370,561       28,370,561    +0.00%
allocs TOTAL                        245,612,730      245,304,778    -0.13%
instructions retired (min)      211,230,622,551  211,188,163,503    -0.02%
peak RSS bytes                    2,810,118,144    2,795,208,704    -0.53%
```

- **core_lowering_complete: -307,954 allocations (-1.59%)** — real, small,
  measured directly (not the fixture's 25% estimate; that estimate used a
  synthetic type shape, `List[String]`, that is far more expensive to
  rebuild than the arg-less scalars that actually dominate the real
  histogram). This matches the manual estimate above almost exactly.
- `pass_mono_complete` unchanged, as reported per the coordinator's ask —
  the scalar-constant cut has no effect on monomorphization's own type
  substitution work (it never rebuilds an already-lowered `CoreType`).
- Byte-identical generated C, confirmed by `self_compile_measure
  --require-identical`.
- Instructions retired: -0.02%, i.e. no measurable regression ("noise", not
  a rise) — satisfies the "instructions not rising beyond noise" gate,
  trivially, since this change adds no probe (only constant returns already
  guarded by existing comparisons).

## Gates

All run under `benchmarks/self_compile_measure lock --`, foreground, serial:

```
bin/blorp test --timeout 300 blorp/test/compiler/stage_08_core_lower/test_core_lower.brp
  -> All 143 tests passed
bin/blorp test --timeout 300 blorp/test/compiler/stage_09_core/test_core_json.brp
  -> All 115 tests passed
scripts/compiler-check --changed
  -> BLORP_GATE_RESULT gate=compiler-check status=PASS passed=2218 failed=0 tests=2218
scripts/test --serial compiler-blorp compiler-tools
  -> BLORP_GATE_RESULT gate=test status=PASS passed=5143 failed=0 tests=5143
scripts/test leak
  -> BLORP_GATE_RESULT gate=test status=PASS passed=963 failed=0 tests=963
```

## What's left out

- The per-function identity-keyed memo (point 2's pre-walk design) is not
  implemented. The histogram-driven estimate above (~200K allocations, well
  under 1% of lowering's ~19.3M) does not justify the cost of restructuring
  expression lowering to thread context per node. If a future session wants
  to revisit it, the pre-walk itself (collecting distinct `SemanticType`
  objects reachable from a function body by `blorp_same_object` identity,
  before lowering the body) is orthogonal to the context-threading problem
  and could be prototyped against `benchmarks/blorp/profiles/core_lowering_allocation_attribution.brp`'s
  fixture first.
- Cut 2 (compact locations) remains untouched, as before.
