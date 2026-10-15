# Blorp 2 performance fixes: linear emission and indexed name lookup, 2026-10-15

Finding 1 of [the 2026-10-14 verification](blorp_2_perf_verification_2026-10-14.md) was that `emit`
appended each C fragment to the whole output, so every append copied everything emitted so far:
emission was quadratic in output size and took 63% of instructions on a compiler-sized input. After
this change, emit collects fragments and joins them; the emitted C is byte-identical. On the
compiler-sized proxy, emit falls from 46.1G to 0.76G instructions and the whole compile from 55.4G
to 10.1G (3.9 s to 0.6 s). Emit now grows linearly (exponent 1.0) in every dimension measured.

For finding 2, a bucket index replaces the linear `find_name` scan (see
[Name lookup index](#name-lookup-index)). It cuts a lookup to about 3.8K instructions at any table size.
Interning stays quadratic in distinct names until the lexer interns each module in one batch, because
`intern_name` still copies the table for each new spelling. This note records that interim cost.

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

## Name lookup index

The index commit on `blorp2/perf-fixes`. It changes only `blorp_2/src/utils/names.brp` (formatted lines 110 -> 243) and its unit suite
(292 -> 435). The emitted C is byte-identical for all 334 e2e fixtures.

### Key, place, lifetime and collisions

- **Place.** `NameTable` is opaque over `{ spellings: List[String], buckets: List[List[NameId]] }`.
- **Authority.** `spellings` is the authority: an ID is a spelling's position. `buckets` is an index
  derived only from `spellings`, written only by `program_names` and `extend_names`.
- **Key.** The complete spelling. A wrapping FNV-style hash over its bytes chooses a bucket: FNV-1a's
  basis and prime, adding each byte where FNV xors (the subset has no bit operations). Bytes are read
  with `StringOps.get` and `to_int`, as the lexer reads them.
- **Collisions.** A lookup compares full spellings with `text::equals` within that one bucket, so a
  collision costs one comparison and never yields a wrong ID.
- **Growth.** The table starts with 31 buckets and grows from n to 2n+1 when names outnumber buckets,
  rehashing every spelling locally. Counts stay odd so the remainder reads every hash bit.
- **Lifetime.** One compilation. IDs are never compared across tables, and `same_name_table` compares
  spellings only.
- **API.** `find_name` and `intern_name` keep their signatures. `intern_name` is `find_name` plus a
  one-spelling `extend_names`. `extend_names(names, spellings)` is the batch builder the lexer will
  use.

### Lookup cost

Harness: `perf/micro/harness.brp` builds a table of N names with `intern_name`, then performs L
lookups of existing spellings round-robin. The cost of one lookup is
`(instructions(N, 100,000) - instructions(N, 0)) / 100,000`, minimum of three runs. "Before" is
`names.brp` at `c4289f0b1`.

| names | find_name before | find_name after |
| ---: | ---: | ---: |
| 256 | 46,236 | 3,760 |
| 1,024 | 277,383 | 3,752 |
| 4,096 | 835,384 | 3,843 |

### Build cost

| names | intern_name build, before (instructions / allocations) | intern_name build, after (instructions / allocations) |
| ---: | ---: | ---: |
| 256 | 34.0M / 782 | 31.4M / 2,310 |
| 1,024 | 355.8M / 3,088 | 159.2M / 9,239 |
| 4,096 | 4,289.8M / 12,306 | 1,988.8M / 36,908 |

Instructions fall because each new spelling's lookup is now constant. Allocations roughly triple.
`intern_name` extends a table that the caller still holds, so each new spelling copies both
`spellings` and the outer `buckets` list. The bucket it appends to is also copied, because that inner
list is still shared with the previous table. The copy itself was already there; the index makes it
larger. It goes away when the lexer builds each module's table in one `extend_names` batch.

That batch is linear (`perf/micro/new/extend.brp`):

| names | allocations | instructions |
| ---: | ---: | ---: |
| 1,024 | 4,136 | 34M |
| 4,096 | 16,449 | 83M |
| 16,384 | 65,630 | 280M |

### Whole pipeline with today's parser

Load-phase instructions and allocations (the `pre_check` pilot). The emit commit leaves load
unchanged, so "before" is `c4289f0b1`.

| input | load before | load with the index | exponents before, per doubling up to this row | exponents with the index |
| --- | ---: | ---: | --- | --- |
| unions 256 | 356M / 45,988 | 328M / 53,351 | | |
| unions 512 | 1,308M / 87,463 | 1,022M / 102,003 | | |
| unions 1024 | 5,096M / 170,410 | 3,582M / 199,296 | | |
| unions 2048 | 15,681M / 336,301 | 13,389M / 393,870 | 1.88, 1.96, 1.62 | 1.64, 1.81, 1.90 |
| composite 4/4 | 3,213M / 951,853 | 2,520M / 967,645 | | |
| composite 8/4 | 9,719M / 1,899,169 | 7,090M / 1,930,491 | 1.31, 1.41, 1.60 | 1.24, 1.31, 1.49 |

Load stays quadratic in distinct names for the reason above: the copy per new spelling. Whole-compile
allocations rise by +0.3% on composite 4/4 (4,559,058 -> 4,574,850 against the emit commit) and by +14%
on unions 2048 (410,444 -> 468,013). Composite 4/4 instructions fall from 10,089M to 9,394M.

### Projection: the lexer move (scratch tree, not a commit)

To estimate what interning each module in one batch gives, a scratch tree combined this index with
the parser from the unlanded reference commit `ef66fbd9b` (branch `blorp2/interning-prepass-ref`).
That parser extends the table once per module before parsing. It is not the planned lexer design;
it only stands in for its cost. Raw data: `perf/proj.tsv`.

| input | load before | load projected | whole compile projected |
| --- | ---: | ---: | ---: |
| unions 2048 | 15,681M | 757M | 2,890M / 408,326 |
| composite 4/4 | 3,213M | 1,572M | 8,446M / 4,517,933 |
| composite 8/4 | 9,719M | 3,267M | 21,543M / 9,028,755 |

Projected load exponents are 0.82, 0.90, 0.96 for unions and 1.05, 1.01, 1.06 for composite.

### Tests

`test_utils/test_names` has five new tests: a batch that skips known and repeated spellings, lookup
hits and near misses, growth across two doublings, a collision in one bucket, and IDs stable across
extension and growth. Each oracle was
checked by mutation:

| mutation | tests that failed |
| --- | --- |
| lookup trusts the bucket without comparing spellings | 3, including the collision test |
| growth rehashes only the input spellings | 2 |
| a bucket stores the wrong ID | 6 |
| misses return the first ID | 8 |
| `extend_names` appends known and repeated spellings too | 1, the batch-skip test |
| no-op control, and a hash that ignores bytes | none (expected) |

"left" and "third" share bucket 28 of 31; the collision test failing under the first mutation shows
that they collide.

## Not measured

Self-compilation (the composite is a count-matched proxy), optimized builds, the cost of compiling
the emitted C, and peak memory.
