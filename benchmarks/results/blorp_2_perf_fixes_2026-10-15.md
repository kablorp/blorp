# Blorp 2 performance fixes: linear emission, 2026-10-15

Finding 1 of [the 2026-10-14 verification](blorp_2_perf_verification_2026-10-14.md) was that `emit`
appended each C fragment to the whole output, so every append copied everything emitted so far:
emission was quadratic in output size and took 63% of instructions on a compiler-sized input. After
this change, emit collects fragments and joins them; the emitted C is byte-identical. On the
compiler-sized proxy, emit falls from 46.1G to 0.76G instructions and the whole compile from 55.4G
to 10.1G (3.9 s to 0.6 s). Emit now grows linearly (exponent 1.0) in every dimension measured.

The name-table half of this work (finding 2) is recorded separately once it lands.

## Change

Commit `59145318b` on `blorp2/perf-fixes`, base `origin/main` `c4289f0b1`. Only
`blorp_2/src/emit/emit.brp` changes (formatted lines 2,372 -> 2,386).

Each loop that accumulates C now collects its children into a local `var fragments: List[String]`,
calls each child with `""`, and joins once. This is the shape `append_list_prototypes` and
`append_list_runtime` already used. The converted loops are the top level of `emit` (runtimes,
aggregates, prototypes, functions), `aggregate_runtime_contents`, `append_aggregate_definitions`,
`append_ownership_operations`, `append_match`, and `append_function`, which joins
`[opening, body, tail, closing]`. Each nesting level copies its own text once, so total copying is
the output size times the nesting depth (at most four levels).

The brief asked for one `List[String]` threaded through every `append_*` helper. That is still
quadratic under the host compiler (defect 1 below), because the helpers return `Result`.

## Provenance

- Baseline: `origin/main` `c4289f0b1`, exported with `git archive`. Candidate: `59145318b`. Both were
  built with the same host `bin/blorp` (status FRESH, SHA-256 `7f7289d2…`) using the Makefile's flags,
  `clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1`.
- Machine: Apple M4, macOS 26.7.1, Apple clang 21.0.0, arm64. Load average was about 3.5 because
  other workers were running. Instruction and allocation counts do not depend on load; wall times
  do, and are noisy.
- Scripts and raw data are in the session scratchpad under `perf/` and are not committed:
  - `gen.py` (`00dd02f4…`) generates the inputs.
  - `build.sh` (`32823145…`) builds the full pilot and two phase-prefix pilots.
  - `measure.sh` (`be1a6deb…`) runs the measurements.
  - `slopes.py` computes exponents.
  - `tools/compare.sh` (`dac65e64…`) checks output identity.
  - Raw data: `base.tsv`, `emit.tsv`.

## Method

- **Inputs.** The verification report's generators were gone, so they were rebuilt from its
  descriptions:
  - `functions N`: N functions calling each other in a binary tree, all reachable.
  - `statements N`: one function of N bindings, each reading the previous one.
  - `unions N`: N unions of four payload variants.
  - `composite S`: S/4 of the compiler's own counts. At 4/4 that is 34 modules plus `main`, 22
    functions of 14 statements per module, 4 unions and 7 records per module, and a four-arm tail
    match in every fourth function, with local names repeated across functions. That gives 48.9K
    identifier tokens (compiler: 53.4K), 2,887 distinct spellings (about 2.7K) and 14.9K lines,
    and the output is 1.78 MB.

  The numbers are comparable within this note, not with the 2026-10-14 tables.
- **Instructions.** `/usr/bin/time -l` "instructions retired", the minimum of three runs without leak
  checking, all serial, under `ulimit -s 65520`.
- **Allocations.** The `BLORP_LEAK_CHECK=strict` count, from one run.
- **Phases.** Two cut-down pilots are built from the same sources: `pre_check` (`compile` returns
  before checking) and `pre_emit` (`compile` stops after verify). Load is `pre_check`, check through
  verify is `pre_emit - pre_check`, and emit is `full - pre_emit`.
- **Exponent.** log2 of the growth per doubling, so 1.0 is linear and 2.0 quadratic.

## Output identity

All 334 `.brp` files under `blorp_2/test/e2e/fixtures` were compiled by both pilots: 299 compile and
35 are rejected. Generated C, stdout, stderr and exit status are byte-identical (0 differences).
The C for `composite_4` and `functions_1024` is also identical. The ten `test_emit` suites and
`runtime/test_record` pass.

## Scaling of emit instructions

| dimension | sizes | emit instructions, base | exponents, base | emit instructions, after | exponents, after |
| --- | --- | --- | --- | --- | --- |
| functions | 256, 512, 1024, 2048 | 87M, 293M, 1,057M, 4,003M | 1.76, 1.85, 1.92 | 30M, 60M, 118M, 236M | 0.98, 0.98, 1.00 |
| statements in one function | 256, 512, 1024, 2048 | 31M, 102M, 357M, 1,316M | 1.72, 1.81, 1.88 | 16M, 30M, 60M, 121M | 0.95, 0.98, 1.02 |
| composite | 1/4, 2/4, 4/4, 8/4 | 2,673M, 11,682M, 46,117M, 183,484M | 2.13, 1.98, 1.99 | 179M, 381M, 762M, 1,527M | 1.09, 1.00, 1.00 |

Allocations are essentially unchanged: -0.2% to +0.25% across these inputs (for example `composite_4`
4,569,375 -> 4,559,058; `functions_2048` 1,249,463 -> 1,252,563).

## Per phase, composite (instructions / allocations)

| scale | build | load | check..verify | emit | total | wall s (noisy) |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 4/4 | base | 3,213M / 951,853 | 6,108M / 3,187,702 | 46,117M / 429,820 | 55,438M / 4,569,375 | 3.95 |
| 4/4 | after | 3,214M / 951,853 | 6,113M / 3,187,702 | 762M / 419,503 | 10,089M / 4,559,058 | 0.56 |
| 8/4 | base | 9,719M / 1,899,169 | 16,755M / 6,372,885 | 183,484M / 859,514 | 209,957M / 9,131,568 | 16.96 |
| 8/4 | after | 9,729M / 1,899,169 | 16,748M / 6,372,885 | 1,527M / 838,834 | 28,004M / 9,110,888 | 1.52 |

Emit was 83% of instructions at 4/4 and is now 8%. The largest phase is now check through verify
(61%), followed by load (32%).

## Host-compiler defects

These are host-compiler costs. Blorp 2 source was shaped around them rather than redesigned; the
host compiler should remove them. Reproductions are under the session scratchpad's `micro/`,
compiled with `bin/blorp compile --no-format` and `clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1`.

1. **A list threaded through a `Result`-returning helper is copied on every call.** In `v1.brp` the
   loop calls `append_checked(result, index)`, which returns `Ok(output.append("x"))`, then rebinds
   `result` in the `Ok` arm.
   - 5,000 calls: 5,004 allocations, 1.22G instructions. 10,000 calls: 10,004 allocations, 4.82G.
   - The generated C retains the `var` before the call (`blorp_retain(brp_v_4L)`), because the var
     stays live in the `Err` arm. The callee therefore sees reference count 2 and
     `blorp_list_ensure_capacity_checked` copies.
   - Clearing the var in the `Err` arm (`v3.brp`) does not help, and neither does threading a
     `Result` var (`v5.brp`).
   - The same helper returning a plain `List` is linear (`plain.brp`: 10,035 / 20,037 allocations,
     51M / 85M instructions).
2. **A `var` list declared before a `?=` is copied on every later append.**
   - `local2.brp` (one `?=` between the declaration and the appending loop): 10,020 / 20,021
     allocations and 1.23G / 4.84G instructions at 5,000 / 10,000 appends.
   - `local3.brp` (the same code with the `?=` before the declaration): 5,031 / 10,033 allocations and
     29M / 40M instructions.
   - `emit.brp` works around this by placing every `?=` ahead of the `var fragments` declaration in
     `emit` and `aggregate_runtime_contents`; comments there state the rule.
3. **`into_opaque` passed directly as a generic argument fails to compile.**
   `listed.append(into_opaque Id(position))` reports "Conflicting type arguments for generic function
   'list__append'". Binding `id = into_opaque Id(position)` first compiles (`t/b.brp` against
   `t/d.brp`, under `perf/micro/t/`). This was found while writing the name index.

## Residual and follow-ups

- Loops inside a single construct still concatenate onto a growing string: record fields
  (`append_record`, `append_record_ownership`), union variants (`append_union`,
  `append_union_action`), parameters (`c_parameters`), call arguments, payload fields, recur
  arguments and string-literal bytes (`append_string_bytes`). Each grows only with that construct's
  width, not with output size. The byte loop would need an allocation per byte to collect fragments.
- `append_function`, `append_match` and `append_aggregate_definitions` now always receive `""` as
  `output`. Removing that parameter belongs with the lexer-interning change or a small cleanup of its
  own.

## Not measured

Self-compilation (the composite is a count-matched proxy), optimized builds, the cost of compiling
the emitted C, and peak memory.
