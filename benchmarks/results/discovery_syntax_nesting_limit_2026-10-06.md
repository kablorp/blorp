# Discovery syntax nesting limit (2026-10-06)

`MAX_SYNTAX_NESTING` in `blorp/src/compiler_new/stage_01_discovery/parse/parse_state.brp`
is **128**. This record is the measurement behind it
(`docs/DISCOVERY_REDESIGN.md` section 3.14): the limit is the largest depth every
walker survives with margin on both platforms at the declared stack size, kept
clear of what the rest of the pipeline takes.

Base `8bb937e82` plus the change that adds the limit. Unsanitized builds, default
`-O0` test programs. Linux arm64: the repository's Docker image
(`blorp-test-linux-arm64`, Ubuntu 24.04, clang 18) on Apple silicon. macOS:
Apple clang 21, arm64.

## What counts

One level each: a bracketed form (grouping, call arguments, subscript, list,
tuple, vector, record, update, dict, interpolation hole), an indented block, a
lambda, a control expression read as an operand, a prefix operator
(`not`, `-`, `detach`), a written type and a type argument, a parenthesized
dimension, a pattern. Counted in
`ParseState.nested` and `nested_recovering`, the only way a parse function enters
one. Exempt (loops in every walker): left spines, `else if`, `match` arm and
`select` arm chains. One exception goes the other way: a dimension sum or
product and a run of array suffixes are loops in the parser, but the type and
dimension walkers recurse on the left-nested tree (3,000 terms passed and 5,000
overflowed the dump on macOS), so each term or suffix counts one level
(`chain_fits`). Making those walkers loop would remove the count.

## The stack the proofs run on

- The proof tests are `TestSuite` programs. `blorp test` generates a serial batch
  harness whose `main` calls each suite directly (`src/test/generated_test_harness.brp`);
  the emitted C `main` calls the user's `main` with no fiber in between. They run on
  the **main thread**, not on a 128 or 256 KB fiber stack
  (`BLORP_DEFAULT_FIBER_STACK_SIZE`).
- The main stack is 16 MB on both platforms: macOS asks at link time
  (`-Wl,-stack_size,0x1000000`, `platform_stack_size_argument` in `host_c.brp`);
  on Linux the runtime constructor `__blorp_raise_main_stack_limit`
  (`BLORP_MAIN_STACK_BYTES`, `runtime.c`) raises the soft limit, best effort. The
  container's shell reports 8192 KB; the test programs get 16 MB from the
  constructor. `test_runtime/test_sys/test_main_stack.brp` proves it by recursing
  300,000 frames, which 8 MB cannot hold.
- Sanitized builds use 128 MB and are outside the proof.

## Evidence for the value

### 1. The repository's own sources

Deepest nesting of brackets plus indented blocks, by a token scan of all 3,855
`.brp` files under `blorp`, `standard_library`, `examples`, `pkg` and `benchmarks`
(block depth taken from the indent of each statement line, bracket depth from
unquoted `([{` / `)]}`; prefix and lambda chains are rare and counted as zero):
**23** (`standard_library/src/validation.brp:1206`; next `synth_string.brp:1511`
22, `json.brp:383` 21). The tree parser's own count over the same files reached
12, but it reads only the shapes the slice supports, so it is a lower bound.
128 is more than five times the corpus maximum, and the old parser's corpus
parity is unaffected (no corpus module nests past 23).

### 2. Generated C and the older passes

`clang` stops a translation unit at `-fbracket-depth` 256 by default. A value `if`
nested to depth N opens N + 2 C brackets (100 deep: 102, 200 deep: 202); calls,
lists and parenthesized forms flatten to temporaries, and lambdas stay at 9. So
256 is the ceiling on value `if` depth through C, and 128 keeps half of it.
Independent of that, the compiler's older passes (typecheck, Core) overflow the
macOS 16 MB stack: nested value `if`s compiled at 200, 220 and 240 and crashed at
250 (compile exit 139); lambdas compiled at 300 and crashed at 400; parenthesized
forms, lists and call arguments compiled at 500 and crashed at 600. The older
typecheck is outside the proof, but a limit well under 250 keeps source the new
parser accepts inside what the rest of the pipeline can compile.

### 3. What the walkers sustain

The same parser, with the limit raised to 1,000,000 and no frame changes, run
through parse, mint, dump, ID census and legacy projection. The deepest depth that
passed and the first that overflowed (depths 128, 256, 512, 1000, 1500, 2000, 3000,
4000). Method: `discovery_syntax_nesting_limit_probe_2026-10-06.brp.txt`, a probe
whose arguments are form, depth and phase; the Linux numbers are one fresh process
per cell in the Docker image, the macOS ones the probe linked with the embedded
-O0 runtime and `-Wl,-stack_size,0x1000000` (a slightly conservative runtime).
Depth is in source units, so an operand `if` counts two levels (the operand and
its block) and a `select` one level per `select`.

| Form | Linux arm64 passes | overflows | macOS passes | overflows |
| --- | ---: | ---: | ---: | ---: |
| record literals | 1,000 | 1,500 | 512 | 1,000 |
| record updates | 1,000 | 1,500 | 512 | 1,000 |
| dict literals | 1,000 | 1,500 | 512 | 1,000 |
| four braced forms in turn | 1,000 | 1,500 | 512 | 1,000 |
| vectors | 1,500 | 2,000 | 1,000 | 1,500 |
| lists | 1,500 | 2,000 | 1,000 | 1,500 |
| call arguments | 1,500 | 2,000 | 1,000 | 1,500 |
| groupings, subscripts, `not` chains | 4,000+ | none | 4,000+ | none |
| lambdas | 1,000 | 1,500 | 512 | 1,000 |
| value `if`s | 1,500 | 2,000 | 1,000 | 1,500 |
| operand `if`s (2 levels each) | 512 | 1,000 | 256 | 512 |
| `with`, `concurrent`, `debug` blocks | 2,000 | 3,000 | 1,000-1,500 | 1,500-2,000 |
| `select` blocks | 2,000 | 3,000 | 1,000 | 1,500 |
| written types | 1,500 | 2,000 | 512 | 1,000 |
| patterns | 2,000 | 3,000 | 1,000 | 1,500 |

The weakest walker is the legacy projection of operand `if`s: 256 units (512
counted levels) on macOS, 512 units on Linux. At the limit that is a margin of
4 on macOS and 8 on Linux; every other form has at least 4 (macOS) and 7 (Linux: record literals pass at
1,000, which is 7.8 times the limit).

## Choice

128: more than five times anything in the repository, half of clang's default
bracket depth, half of the depth at which the older passes crash, and at least
four times below the weakest walker on the weaker platform. A smaller value would
also work; 128 leaves room for generated and machine-written sources.

## Proof at the limit

`test_syntax_nesting.brp` (parse, mint, dump, census, and rejection one level
past the limit with `SyntaxNestingTooDeep`) and `test_syntax_nesting_projection.brp`
(the legacy projection) put the innermost construct of each counted form at level
`MAX_SYNTAX_NESTING`; the first covers 47 cases, the second 24. Both files pass
on macOS arm64 and in the Linux arm64 Docker image (`bin/blorp test`, 16 MB main
stack as above). A change to the stack size or to `MAX_SYNTAX_NESTING` is a change
to this measurement.

## Cost of the counter

Allocations of tree-parsing (`scan_module_declaration_prefix_with_bodies`) the
same 574 sources under `blorp/src` and `standard_library/src` (16,491
declarations, no diagnostics), `bin/blorp run --memory-stats`, macOS arm64,
identical input text in both runs:

| Build | Allocations |
| --- | ---: |
| before (`f2a7215b4`'s parent, no counter) | 12,396,696 |
| counter with `too_deep` built eagerly at each site | 13,476,979 (+8.7%) |
| counter with `too_deep` a function (the landed form) | 13,260,518 (+7.0%) |

Building the refusal eagerly cost 216,000 allocations (1.7%), mostly the
`StopPoint` that `parse_block_recipe` made on every block; passing it as a function
removes that. The remaining 864,000 are the closure each nesting site passes to
`ParseState.nested` for its capturing `inner` function and the pair it returns.
A refusal that is a plain value (`RejectedRecipe`) allocates nothing either way.
The tree path is test-only today, so the cost is recorded, not removed; a
compiler that inlines a known function argument, or a two-call enter and leave
API, would take it back.

## Stack and fibers

The proofs run on the main thread and rely on its 16 MB. A source nested to
the limit needs roughly 7 to 16 KB of native stack per level in the weakest
walker, so about 1 to 2 MB at 128 levels; a fiber's 128 or 256 KB would hold 8
to 30 levels. Tree-path parsing therefore must run on the main stack (or a stack
sized for the limit), and the limit is re-measured if the stack size or the
limit moves.
