# Fixed layout R0 baseline and placement census

This is a baseline and a set of current-behavior probes. No production layout
or ownership code changed. The checkout was clean at
`3990960409a0a7af4d59d11d638b87c2b7cc35e1` before the probe/report files
were added. The frozen self-compile input uses that same revision.

## Reproduce the baseline

Host: `MacBook-Air-4.local`, `arm64`, macOS; Apple clang version 21.0.0
(`clang-2100.3.34.2`). Bootstrap tag `dev-0322140767b0`, target
`aarch64-apple-darwin`, compiler version `blorp 0.0.1`. The bootstrap-built
`bin/blorp` was FRESH, dirty false, eight-way split, `cli=-O2 runtime=-O2`,
SHA-256 `0ea7a5a1f27bf4fd8947fa27d886968c815d809c680d40d10cde88511cb5fc8d`.

```sh
BLORP_CLI_C_OPTIMIZATION=-O2 make
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-build-status
BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --stage2 \
  --label fixed-layout-r0-base-399096040 \
  --input-rev 3990960409a0a7af4d59d11d638b87c2b7cc35e1 \
  --samples 5 --output /tmp/fixed-layout-r0-baseline-399096040.json \
  --keep-output /tmp/fixed-layout-r0-self.c
```

The retained raw JSON is
[`fixed_layout_r0_baseline_399096040.json`](fixed_layout_r0_baseline_399096040.json)
(file SHA-256 `159fd2fd6d884955d74880a9eaa9c40ebc672619d4bc5e9409024f02d2f7a9e7`).
Stage-2 normal binary SHA-256:
`cbd585b16bc26149541d446f32c3171dad59c25e1d7d7419de0749a34cc68614`;
diagnostic binary SHA-256:
`06c4b9da4ad2693b6360591e28b6b67a5693c5f5ec6858f4747aa441f33a9077`.
Both identify as `compiled_by: self-3990960409a0`, `-O2`; the diagnostic
binary has `memory_diagnostics: 1`. The harness required their emitted C to
match byte for byte. Both produced SHA-256
`b8cdac82dacc0576cc2b095056e725a1d246b8cc7869454da58a31cc2ca7864f`,
79,794,082 bytes. The copied generated C is at `/tmp/fixed-layout-r0-self.c`;
that temporary path is not a durable artifact. This is the measurement's
*output* C, not the C body used to build the stage-2 compiler.

The retained linkable stage-2 body is
`blorp/build/_build/blorp-cli/stage2_main.c`, SHA-256
`8a9c88f126cdca4de62bed45627479434c582b3cd8731e2275c73f516f9813a2`.
`benchmarks/build_stage2_compiler` names that path as its default generated C,
and `self_compile_measure --stage2` invokes that builder. Its file timestamp
precedes `stage2_main.o` and `bin/blorp-stage2`; the latter's SHA-256 matches
the raw JSON above. This supports the build-input provenance, although the
JSON does not independently attest the stage-2 body C hash. The body has no
backend `#error` directives.

Total managed allocations: **213,831,836**. Retired-instruction samples:
204,579,008,004; 204,664,494,414; 204,958,987,593; 204,510,144,889;
204,612,923,825. Minimum 204,510,144,889; sample spread 448,842,704
(0.219% of minimum). Peak RSS 2,147,762,176 bytes. Selected checkpoint
deltas: source discovery 7,922,473; typed frontend 34,352,531; Core lowering
17,446,170; tuple flatten 7,633,330; ownership/Perceus 46,539,642;
cancellation plan 10,479,447; backend emission 16,554,515. Every checkpoint,
phase time, raw instruction sample, and binary fingerprint is in the JSON.
The five wall-time samples are host-noise context, not an acceptance metric.

## Current placement evidence

`rg -n '^\s*struct [A-Za-z_][A-Za-z0-9_]*\s*\{' blorp/src standard_library/src pkg -g '*.brp'`
finds 108 declarations: 53 in `compiler_new`, 27 in `compiler`, 4 in
`blorp/src/lib`, 3 in `blorp/src/test`, 2 in `blorp/src/lsp`, and 19 in the
standard library. The discovery table row file accounts for 42 declarations.
This is a declaration inventory, not a construction or allocation count.

| Destination | Current representation/evidence |
| --- | --- |
| Typed local, direct parameter/result | `Point` probe below: direct value, zero root allocations. |
| Typed record/struct field | Current `struct` can be embedded by value; see `docs/STRUCT_PAYLOAD_ROADMAP.md` and `stage_10_backend/emit_record_layout.brp`. |
| Typed list element | Inline storage is exercised by `blorp/test/runtime/types/test_struct_vector_memory.brp`; backend has a boxed fallback in `emit.brp` at `emit_inline_list_set`. |
| Typed source-union/Option payload | Typed representation is conditional on payload layout; erased union variants box the value. |
| Stored tuple | `TupleStructElement` in `emit.brp` boxes each value into the tuple's pointer slot. |
| Dictionary key/value | Erased pointer storage requires a box for a struct; no executed dictionary count was established. |
| Closure environment capture | The typed capture path can be inline; `ClosureAbiStruct` call arguments/results box at `emit.brp`'s closure ABI boundary. |
| Foreign boundary | No universal by-value contract was established here; R2 must check each exposed ABI before emission. |

The frozen self-compile C has 377 matching *lines* for `blorp_box_struct(`.
A lexical scan that excludes quoted strings and comments identifies 375 actual
generated-C call expressions: some lines contain more than one call. The
earlier estimate of 370 subtracted quoted-literal lines from matching lines
and was not an expression count. These are static sites, not allocations;
their executed counts appear in the bounded diagnostic below.

For fresh nested ordinary records, a bounded source search for a literal in
another literal finds `PerceusGlobal.value = { ... }` at
`blorp/src/compiler/stage_09_core/perceus/env.brp:726` as a candidate:
`PerceusGlobal` is a record and `value` is a `CoreParam` record. The search
also finds struct fields, collection literals, and updates, which are false
positives for R3. `CoreParam` has other uses and the parent type's full
construction/escape closure has not been proved. No self-compile allocation
saving is inferred from this source occurrence.

## Executable probes

```sh
bin/blorp-stage2 run --release --memory-stats --no-format \
  benchmarks/blorp/profiles/fixed_layout_r0_struct.brp
# checksum 100000000; allocations 0; releases 0

bin/blorp-stage2 run --release --memory-stats --no-format \
  benchmarks/blorp/profiles/fixed_layout_r0_nested_record.brp
# fresh: checksum 50005000, allocations 20000, releases 20000
# separately owned child: checksum 99990000, allocations 20000, releases 20000

bin/blorp-stage2 compile --no-format -o /tmp/fixed-layout-r0-managed-stage2.c \
  benchmarks/blorp/profiles/fixed_layout_r0_managed_sketch.brp
# expected exit 1; first diagnostic at 3:7 is
# "expected `=` after top-level variable declaration"
```

The nested probe runs each shape for 10,000 iterations after resetting memory
stats. `/tmp/fixed-layout-r0-nested.c` (SHA-256
`97bf35f9057bd84608ff492935718c77d9cb4e705e18a4eb92d7a5a81dd50088`)
shows separate `brp_ty1_make` (`Child`) and `brp_ty2_make` (`Parent`)
functions, each calling `blorp_alloc`. Thus the first R3 fixture has exactly
one child root allocation per fresh parent available to remove, assuming the
whole type can use one inline field layout. Its escaping control deliberately
uses the child after parent construction and does not qualify for the first
R3 pilot. `/tmp/fixed-layout-r0-struct.c` (SHA-256
`4076a5a5f86cc3cd29ee8d8bae17ecb4530f378edf65783cf1a593bc3d5dfa42`)
is the direct-value control. These C files are temporary inspection artifacts.
The managed-field file is an expected-fail design sketch: neither `fixed`
syntax nor field-wise ownership exists at this revision. Its current parser
message is not the intended R1/R2 diagnostic.

## R0 exit status and R2/R3 decision rule

The frozen baseline, declaration inventory, selected placement examples, and
three small fixtures are established. The dynamic self-compile census of current
`struct` constructions and placements is **NOT ESTABLISHED**. The reachable
dynamic construction count for one `PerceusGlobal`/`CoreParam` nested site is
measured below, but the parent type's full construction and escape closure is
**NOT ESTABLISHED**. Consequently the roadmap's R0 exit
criterion for a production go/no-go threshold based on reachable dynamic
allocations is still open. R1's syntax-equivalence work can proceed with these
fixtures and baseline because it claims no production speedup. The fixture
thresholds below do not authorize R2/R3 production performance claims.

The remaining follow-up is to map representative `struct` constructor and
transport-box sites back to source declarations, count their execution by
destination, and identify a production candidate with enough reachable
allocations to justify R2/R3. Keep instrumentation outside production compiler
sources and retain the uninstrumented stage-2 control and emitted-C identity
oracle. Set the broader production allocation threshold only after those
counts and candidate closure are known.

### Prepared diagnostic (do not run alongside R1 gates)

The first preparation attempt mistakenly used the measurement-output
`/tmp/fixed-layout-r0-self.c` as a linkable body. Its hash and anchors passed,
but Clang stopped at two `#error` directives already present in that
unmodified C, for `compiler_stdin_read_raw` and
`compiler_stdout_write_all`. No diagnostic binary or counters resulted; the
probe was not run. The revised input is the retained stage-2 body above.

`benchmarks/fixed_layout_r0_instrument.py` accepts only that stage-2 body C
hash and asserts one exact anchor for each edit. It places atomic counters at
generated-C `blorp_box_struct` calls, the `CoreParam` and `PerceusGlobal`
maker bodies, and the one fresh-child callsite feeding `PerceusGlobal`. The
box wrapper is inserted after all includes, so it calls the original helper
from `runtime_decl.c` and counts generated-C calls only; internal native
runtime calls are outside this counter. The candidate's nested-site count is
one source pattern, **not** an all-`struct` or all-record census. The script
does not change compiler sources or the uninstrumented control binary.

After the compiled-run window is released, prepare and build with the
Makefile-derived stage-2 compile/link recipe, then run one serialized frozen
self-compile:

```sh
BLORP_CLI_C_OPTIMIZATION=-O2 python3 -B benchmarks/fixed_layout_r0_instrument.py \
  --input blorp/build/_build/blorp-cli/stage2_main.c \
  --output /tmp/fixed-layout-r0-stage2-probe.c \
  --binary /tmp/fixed-layout-r0-stage2-probe

frozen_input=$TMPDIR/blorp-perf-input/3990960409a0a7af4d59d11d638b87c2b7cc35e1
/tmp/fixed-layout-r0-stage2-probe compile --no-format --no-embed-runtime \
  --time-phases --std-dir "$frozen_input/standard_library/src" \
  -o /tmp/fixed-layout-r0-stage2-probe-output.c \
  "$frozen_input/blorp/src/main.brp" \
  2> /tmp/fixed-layout-r0-stage2-probe.stderr
rg '^BLORP_R0_CENSUS ' /tmp/fixed-layout-r0-stage2-probe.stderr
shasum -a 256 /tmp/fixed-layout-r0-stage2-probe-output.c
```

Require the output-C SHA-256 to equal the uninstrumented baseline
`b8cdac82dacc0576cc2b095056e725a1d246b8cc7869454da58a31cc2ca7864f`.
Record the diagnostic C/binary hashes and counters. The instrumented binary's
instruction, RSS, and wall-time values are not comparable to the baseline.
Only executed counts and output-C identity are evidence from this run. The
frozen input directory and stage-2 body C are generated artifacts; regenerate
from the exact base revision if either is missing, then recheck the respective
hashes before using the probe.

### Completed diagnostic census

One serialized diagnostic self-compile used the exact frozen input directory
above. The build command used `--input blorp/build/_build/blorp-cli/stage2_main.c`,
`--output /tmp/fixed-layout-r0-stage2-probe.c`, and
`--binary /tmp/fixed-layout-r0-stage2-probe`; the compile command above used
`/tmp/fixed-layout-r0-stage2-probe-output.c` and redirected stderr to
`/tmp/fixed-layout-r0-stage2-probe.stderr`. These `/tmp` paths are temporary.
The script SHA-256 at execution was
`21c846196fd469f584e3db2e7b77ecb441f8762ab775b30f72f8db74b4fdd8b4`;
after a docstring-only correction, the historical script SHA-256 was
`29183620f553f2c74b3db6597fead410889660dc764aa97344928def3b38a12e`
and the current extended callsite-census script SHA-256 is
`abdc751e8ef4a1a5457208ba3054c72eddc887b9f5ae974140eda5566d11c3fb`;
the instrumented C SHA-256 was
`0b6a59bb72fa70867fb2ba9f9b6015d75dcb95cf35fd196774e61793e507ea92`;
the diagnostic binary SHA-256 was
`dc7823e9131a534b9e552f572d8ae66d6a46187f4130ce90fad1c9750f13abf6`.
The stderr file SHA-256 was
`453cf1e9b58f6dc573f62fd5885986ca18a44693b4278248db9490a955f5254c`.
The probe exited successfully and emitted C with SHA-256
`b8cdac82dacc0576cc2b095056e725a1d246b8cc7869454da58a31cc2ca7864f`,
79,794,082 bytes: exactly the uninstrumented baseline output identity.

The single counter line was:

```text
BLORP_R0_CENSUS generated_box_calls=2133784 coreparam_make=295205 perceusglobal_make=3178 nested_coreparam_site=3178
```

`generated_box_calls` covers generated-C calls to `blorp_box_struct`, including
stack Option and other transport values; it does not attribute boxes to source
`struct` declarations or include calls inside the separately linked native
runtime. `CoreParam` has many construction sites. The measured nested site
accounts for 3,178 fresh child constructions that directly feed
`PerceusGlobal`, the same count as that record's maker in this run. Removing
one child root at this site could save at most 3,178 direct allocations,
0.00149% of the 213,831,836 baseline total, before any new boxes or ownership
cost. This one candidate is too small to justify a broad R3 implementation on
self-compile savings alone. It does not establish the parent type's complete
construction/escape closure or the roadmap's all-`struct` dynamic census.

Before implementing R2 or selecting a production R3 type, measure an actual
dynamic reachable-construction count for that type or a tightly isolated
production pass. For R2, the comparable targeted heap-record fixture must
lose one root allocation per typed fixed value without a new box, leak,
duplicate release, or unexplained retain/copy cost. For R3, the closed parent
type must have one uniform fresh-child layout at *every* constructor; a mixed
or independently escaping child rejects the first pilot. The targeted R3
fixture must move from two aggregate allocations to one per construction.
For production, require a total-allocation reduction commensurate with the
measured reachable count and no unexplained phase increase. Compare five
serialized `-O2` stage-2 instruction samples against this 0.219% baseline
spread; changes smaller than the spread alone support no speed claim, and an
increase beyond it requires explanation or rejection. Preserve correctness,
ownership/leak evidence, RSS, and generated-C inspection as independent gates.
The measured `PerceusGlobal` nested site gives a 3,178-allocation direct
upper bound, but no broader R2/R3 self-compile allocation target is justified
until another candidate's dynamic reachability and closure are established.

### Bounded callsite census checkpoint

The diagnostic-only script now assigns stable IDs 0–374 to the 375 actual
generated-C `blorp_box_struct` call expressions in the pinned stage-2 body.
It leaves calls inside strings/comments and the separately linked native
runtime untouched. Its manifest records each original C line and the explicit
`sizeof(C type)`, plus a destination only when the emitted operation proves it.
The source `struct` inventory includes 157 declarations when `private struct`
is counted; the earlier 108-declaration search omitted that spelling. Generated
C does not carry an exact source-name mapping for value-struct typedefs, so all
157 source rows remain **unattributed**, not zero-hit. The manifest's site IDs
with no stderr counter row are the 280 zero-hit *callsites* in this run.

Two temporary static scanner checks passed (quoted/commented calls and
multiple calls on one line); `git diff --check` is clean. One serialized
diagnostic build and one self-compile used the same frozen stage-2 body and
input revision as above. The instrumented C SHA-256 is
`5f74d194d31fe03ce7656e3347c6d0e8c4056719dba8f0f7b965b612cd69504d`;
binary SHA-256 is
`2f789098b3fc83a4eac7dc63ccb909e5d0801887f3e3f0b76e126225f53ba499`.
The compiled output C SHA-256 is exactly the baseline
`b8cdac82dacc0576cc2b095056e725a1d246b8cc7869454da58a31cc2ca7864f`.
The emitted counter line independently repeats the prior 2,133,784 aggregate
box calls, 295,205 `CoreParam` makers, and 3,178 each for `PerceusGlobal`
makers and the selected nested site. The 95 nonzero callsite counters sum to
**2,133,784**, reconciling exactly with that aggregate.

| Proven destination in generated C | Executed boxes |
| --- | ---: |
| Stack `Result` payload | 1,016,018 |
| Closure result ABI | 485,629 |
| Closure argument ABI | 264,517 |
| Stored tuple element | 39,310 |
| Dictionary value | 29,790 |
| List fallback | 0 |
| Unknown destination | 298,520 |
| **Total** | **2,133,784** |

The unknown bucket is material. Its largest callsite, ID 88, executed 143,409
times and passes a stack `Option[Int]` to generated `brp_c_872`; ID 57 executed
76,256 times and passes another `Option[Int]` through a temporary before a
generated constructor. The first has a directly visible constructor call but
the current classifier leaves it unknown; the second needs a bounded
producer/consumer trace to prove the sink. A second attribution pass could
reduce the unknown bucket without a new compiled run. Neither call count
establishes a source `struct` conversion opportunity: the hot unknown values
are compiler-specialized stack Options. The high box traffic therefore does
not itself identify an R3 parent/child pilot.

Raw site counts and phase stderr are retained in
[`fixed_layout_r0_box_sites_399096040.stderr`](fixed_layout_r0_box_sites_399096040.stderr)
(SHA-256 `0f231e14da75831976fa163071e5085e1dd7ec884abc7f29492584ab4166e4d4`);
the static site/declaration map is
[`fixed_layout_r0_box_sites_399096040.json`](fixed_layout_r0_box_sites_399096040.json)
(SHA-256 `36e0ed4a1a7b91f2e5b98fe8cc2e40ce1b6ba5383cbe74b26a34d49daba5ea14`).
The temporary instrumented C, binary, and output C are not durable artifacts.

This checkpoint does **not** close R0's per-declaration dynamic construction
census or R3 parent construction/escape closure. Keep the production R3
candidate unselected. A predeclared pilot admission bar is at least 1,069,159
reachable removable child roots (0.5% of baseline allocations), with a net
saved allocation count of at least 80% of that reach and no unexplained phase
increase. The targeted fixture must still change from two allocations to one
per construction and pass ownership/codegen gates. For a self-compile speed
claim, the five serialized `-O2` stage-2 instruction samples must improve by
more than the baseline 448,842,704-instruction spread (0.219%) with identical
frozen inputs/toolchain; a regression larger than that spread rejects or
requires explanation. R2's targeted ownership/allocation gate remains separate
from this performance admission bar.
