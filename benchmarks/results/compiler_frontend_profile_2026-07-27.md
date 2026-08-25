# Frontend-Through-Typecheck Profile Baseline

Measured 2026-07-27 from profile artifact
`0f5290b41f3997785f3d29f5ac1f07e5657ec8e5327d0b23df4daf30149a87c3`.
Raw elapsed samples are in
`compiler_frontend_profile_2026-07-27.tsv`.

The compiler source was clean at revision
`3322653d8efbaef77e89b3cd96f2539d6fb80422` before these result files were
added. Measurements ran on an Apple M4 (`arm64`), Darwin 25.5.0, using Apple
Clang 21.0.0. Every recorded run reported `workload_valid=True`, zero errors,
and the expected source and typed declaration counts.

## Feedback Loop

The representative fixture is deliberately function-heavy:

```bash
BLORP_TYPECHECK_PROFILE_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 5 1 16 256 fallback
```

Run the retained-program control alongside it when a change may move work
between parsing and typechecking:

```bash
BLORP_TYPECHECK_PROFILE_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 5 1 16 256 retained
```

Use at least three alternating samples and compare medians. The first run for a
new compiler-source key rebuilds the instrumented fixture; cached runs complete
in roughly two seconds.

## Baseline

| Mode | Median for 5 iterations | Per iteration |
|------|-------------------------|---------------|
| frontend (`fallback`) | 1,461.608 ms | 292.322 ms |
| typecheck control (`retained`) | 1,238.117 ms | 247.623 ms |
| frontend boundary delta | 223.491 ms | 44.698 ms |

A representative profile sample reports these inclusive phase envelopes:

| Phase | 5-iteration time | Share of frontend elapsed |
|-------|------------------|---------------------------|
| parse through typecheck | 1,461.230 ms | 100.0% |
| prepared-program typecheck | 1,168.283 ms | 80.0% |
| graph preparation and parsing | 286.840 ms | 19.6% |
| program body materialization and validation | 919.063 ms | 62.9% |
| function body materialization | 795.820 ms | 54.5% |
| function signature registration | 226.057 ms | 15.5% |
| typed-program validation | 115.066 ms | 7.9% |
| lexing | 168.241 ms | 11.5% |

Typed-program validation and per-function materialization are siblings inside
the broader program-body envelope. Lexing is included in graph preparation.
Function-profile rows are inclusive and recursive rows overlap, so rows must
not be added as independent wall time.

A production `check --no-format` of
`compiler/blorp/src/stage_06_typecheck/compiler_infer.brp` took 13.37 seconds
and peaked at 613,089,280 bytes RSS on the same machine. That check is a useful
real-source guardrail, but it is too slow for the primary iteration loop.

## Scaling

Single balanced-fixture samples showed elapsed time close to proportional to
the combined declaration count:

| Modules | Type depth | Probes/module | Declarations | Per iteration |
|---------|------------|---------------|--------------|---------------|
| 1 | 32 | 64 | 97 | 79.473 ms |
| 1 | 64 | 128 | 193 | 153.546 ms |
| 1 | 128 | 256 | 385 | 306.813 ms |
| 2 | 64 | 128 | 385 | 305.839 ms |

Equivalent declaration counts had equivalent total latency in these runs.
This is a smoke check, not an independent algorithmic scaling result:
`type_depth` adds one chained record declaration per level while the balanced
cases also increase probe count, and the width comparison covers only one
versus two modules. The samples found no gross scaling regression in these
combined workloads, but they do not rule out depth-only or wider-graph
nonlinearities.

A function-heavy fixture (`1` type level and `256` probes, 258 declarations)
took 287.241 ms per iteration. The inverse type-heavy fixture (`256` type
levels and `1` probe, also 258 declarations) took 44.843 ms. Function
declarations are therefore the representative pressure to retain in the fast
loop.

## Current Targets

1. Function body materialization is the dominant envelope. Finalization and
   typed-expression validation are now measured independently, and finalization
   stores semantic and runtime value types only in its canonical value slot.
   Accessors derive both views from that slot, so malformed mirrors are no longer
   representable. A recursive struct that combined the two validation traversals
   was measured and rejected; keep the specialized `Bool` and `Option[String]`
   traversals until the ownership cost of aggregate returns is addressed.
2. Signature registration is no longer a low-risk latency target. The completed
   aggregate production measurement found 0.045% fewer instructions on the CLI
   request and no measurable wall-time change. The remaining state/context
   copies require ownership-aware result threading.
3. Lexing is the largest non-typecheck phase. First-character guards in
   `scan_one` remove impossible docstring, comment, and raw-string prefix probes.
   Measure symbol dispatch separately before replacing its ordered prefix chain.
4. `scan_symbol_or_error` remains the next narrow lexer target. It currently
   attempts operators beginning with unrelated characters; dispatching on the
   already-peeked character can reduce those probes without changing token
   precedence.
5. Add independently controlled depth, declaration-count, and graph-width
   fixtures before using this benchmark as an algorithmic scaling gate.

## Typed-Expression Validation Experiment

The typed-program validator previously called
`compiler_typed_expr_contains_meta` (now `typed_expr_contains_meta`) and then
`compiler_typed_expr_type_error` (now `typed_expr_type_error`). A one-pass
experiment returned a stack struct
containing `Option[String]` and `Bool`, preserved meta-error precedence, and
passed the focused infer and declaration suites.

The implementation was still rejected. Six alternating five-iteration samples
of the retained function-heavy fixture averaged 1,264.744 ms for the combined
traversal and 1,166.525 ms for the two specialized traversals, an 8.4%
regression. The profiled validation envelope was also substantially slower.
Returning and merging the string-bearing aggregate at every recursive node
cost more than the eliminated walk under the generated ownership model. No
source changes from this experiment were retained. Raw samples are in
`compiler_typed_expr_validation_profiled_2026-07-29.tsv`.

## Lexer First-Character Guard Result

`scan_one` now checks the already-peeked character before probing docstring,
comment, raw-string, or raw-pipe prefixes. Recognition order and the prefix
helpers themselves are unchanged.

On one iteration of the retained function-heavy fixture, structural counts
changed as follows:

| Operation | Baseline | Candidate | Change |
|-----------|----------|-----------|--------|
| `starts_with` calls | 38,839 | 21,473 | -17,366 (-44.7%) |
| docstring-delimiter probes | 4,478 | 257 | -4,221 (-94.3%) |
| raw-pipe-block probes | 4,478 | 16 | -4,462 (-99.6%) |

The original whole-process comparison is retained in
`compiler_lexer_first_character_guards_profiled_2026-07-29.tsv`, but it does
not establish a latency result. The fixture repeats typechecking while lexing
only twice during request setup, so its 20-iteration process counters do not
amplify this lexer change. The operation counts above are the evidence for
retaining the narrow guards; a dedicated repeated-lexing fixture is still
needed for a production latency claim.

## Grouped Lexer Dispatch Experiment

Grouping the two `'-'` branches and the two `'r'` branches under one outer
character check preserved behavior, including standalone `-` symbols and
identifier near-misses such as `r`, `rawish`, and `record`. The focused lexer
suite passed all 25 tests.

The source-level simplification was rejected because its generated result was
larger and it did not measure faster. At `-O0`, `scan_one` grew from 4,732 to
5,128 bytes, from 1,183 to 1,282 static instructions, from 193 to 205 branch
sites, and from 111 to 124 call sites. Ten alternating direct profiler pairs
were also mixed: the grouped candidate averaged 0.52% slower in `compiler_lex`
and 0.60% slower in `scan_one`. The larger lowering is consistent with nested
aggregate-return branches duplicating ownership cleanup. Keep the flat
short-circuit guards until that control flow lowers more compactly. Raw samples
are in `compiler_lexer_grouped_dispatch_profiled_2026-07-29.tsv`.

## Module-Surface Accumulation Result

`module_surface_exports` and `module_surface_private_names` now accumulate
symbols into one uniquely owned list instead of recursively concatenating each
declaration's additions. Source order and decoded declaration indexes are
preserved.

The A/B artifacts were generated from base revision `a0a1b138`. The candidate
contains the module-surface accumulation patch later committed in `7bd4db16`;
the baseline retains the recursive accumulation. Each row is one process
invocation of:

```text
BLORP_TYPECHECK_PROFILE_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 1 1 16 WIDTH retained
```

Two order-alternated samples at each width produced these phase-local means:

| Width | Recursive | Iterative | Reduction | Speedup |
|------:|----------:|----------:|----------:|--------:|
| 256 | 1.679 ms | 0.557 ms | 66.8% | 3.01x |
| 512 | 4.180 ms | 1.067 ms | 74.5% | 3.92x |
| 1024 | 13.137 ms | 2.097 ms | 84.0% | 6.27x |

Every run reported `workload_valid=True` with the expected checksum. Complete
artifact keys, binary SHA-256s, fixture configuration, host information, and
raw timings are in
`compiler_module_surface_accumulation_profiled_2026-07-29.tsv`. These results
establish a phase-local scaling improvement, not an end-to-end latency claim.

## Signature Registration Result

The first target now rejects resource arguments for a non-builtin function
before scanning its parameter types. Five A/B samples alternated the old and
new cached profile binaries with this workload:

```text
iterations=5 modules=1 type_depth=16 probes_per_module=256 mode=retained
```

The operation counts were identical within each variant:

| Operation | Old | New | Change |
|-----------|-----|-----|--------|
| recursive resource scan calls | 3,945 | 2,655 | -1,290 |
| scoped-carrier scan calls | 1,290 | 0 | -1,290 |

The median paired instrumented times fell 88.0% in the policy row, 26.0% in the
signature-registration envelope, and 14.4% for the full profiled workload.
Those are profiling signals, not production latency claims: removing
instrumented calls reduces profiler overhead in every enclosing row. Raw
profile measurements are in
`compiler_signature_registration_2026-07-27.tsv`.

Nine unprofiled A/B pairs then used 100 iterations of the same fixture.
Absolute old and new medians were 1,679.212 ms and 1,677.278 ms respectively,
while the median paired ratio had the new binary 1.2% slower. The mixed
direction and sub-noise median difference mean no whole-workload latency change
was measurable. Raw unprofiled measurements are in
`compiler_signature_registration_unprofiled_2026-07-27.tsv`.

All measured runs reported `workload_valid=True` and zero typecheck errors.

## Semantic Boundary Type Reuse Result

Resource-boundary validation now consumes the semantic parameter types already
computed by registration. Parsed parameters remain available only to recover a
diagnostic name when a resource parameter is rejected.

Five profiled A/B pairs used:

```text
iterations=5 modules=1 type_depth=16 probes_per_module=256 mode=retained
```

The operation counts were identical within each variant:

| Operation | Old | New | Change |
|-----------|-----|-----|--------|
| canonical annotation calls | 4,015 | 2,730 | -1,285 |
| parsed parameter conversions | 3,855 | 2,570 | -1,285 |

The final-source profile pairs were stable: median paired time improved 35.7%
in the resource-boundary row, 6.0% in signature registration, and 2.6% across
the complete instrumented workload. These remain profiling signals rather than
production latency claims. Raw measurements are in
`compiler_signature_boundary_reuse_profiled_2026-07-27.tsv`.

Seven final-source unprofiled A/B pairs then used 200 iterations:

| Measurement | Old median | New median | Change |
|-------------|------------|------------|--------|
| retired instructions | 58,475,904,161 | 57,697,634,453 | -1.3% |
| peak RSS | 137,904,128 bytes | 137,854,976 bytes | no material change |

The median paired instruction reduction was 1.3%, with every pair between 1.3%
and 1.4%. Elapsed and user timings were noisy and inconclusive: their paired
medians improved by about 0.8% and 1.2%, but the sample included reversals and
one roughly 10% slow outlier. Raw measurements are in
`compiler_signature_boundary_reuse_unprofiled_2026-07-27.tsv`.

All measured runs reported `workload_valid=True` and zero typecheck errors.

The old source is commit `1a04ce4ce1b425bc1ec0bb37ef08c272565cd52a`.
The new compiler-source patch has SHA-256
`567568aca859143a903c26bf1253ced9a487c89ef698ae5dd9796b4f74680d13`,
calculated with:

```bash
git diff 1a04ce4ce1b425bc1ec0bb37ef08c272565cd52a -- \
  compiler/blorp/src/stage_06_typecheck/compiler_typecheck_decl.brp |
  shasum -a 256
```

The unprofiled binaries were built from the base and patched source trees with
the same host compiler and C flags. The host compiler SHA-256 was
`96fb1743a1e4293e4d208f0a26cbf1bb865fb699e8ea5b880578cdf94c044b1c`,
the semantic worker SHA-256 was
`535ac8dd3398144d1b5b13bbb22122e5db1a5af7db919670308bacc6ecc0dd6e`,
and the bootstrap bridge SHA-256 was
`5c0d99b9ca8da35c2e5d008bc1ca08ec9b6eda2dd8de8010a686a43079bbaa88`.
The build and measurement commands were:

```bash
host_root=/path/to/built/blorp
source_root=/path/to/base-or-patched-source
cd "$source_root"
export BLORP_COMPILER_BRIDGE_BIN=$("$host_root/scripts/blorp-compiler-bootstrap" --print-path)
export BLORP_OCAML_MIDDLE_BIN="$host_root/compiler/_build/default/bin/blorp_ocaml_middle.exe"
unset BLORP_COMPILER_BRIDGE_RENDERER_SOURCE BLORP_COMPILER_RENDERER_HELPER
unset BLORP_FRONTEND_PARSER BLORP_STD
unset BLORP_COMPILER_PARSER_BRIDGE_BIN BLORP_COMPILER_RENDERER_BRIDGE_BIN
unset BLORP_COMPILER_REQUIRE_PREPARED_BRIDGE BLORP_COMPILER_TYPECHECK_BRIDGE_BIN
"$host_root/compiler/_build/blorp-cli/blorp" compile --no-format \
  -o /tmp/compiler_typecheck_profile.c \
  compiler/blorp/benchmarks/compiler_typecheck_profile.brp
cc -O0 -fwrapv -pipe -w /tmp/compiler_typecheck_profile.c \
  -lm -lpthread -o /tmp/compiler_typecheck_profile
/usr/bin/time -lp /tmp/compiler_typecheck_profile 200 1 16 256 retained
```

## Signature Source-Type Sharing Result

Ordinary signature registration still constructs the temporary
`CompilerFunctionType` (now `SemanticFunctionType`) used for implicit
type-parameter discovery, but now
shares its immutable parameter and return values instead of deep-copying them.
The existing traversal and profiling boundary remain unchanged, and dedicated
coverage protects nested parameter/return candidate ordering.

Five profiled A/B pairs used the retained workload above. The structural count
changed consistently:

| Operation | Old | New | Change |
|-----------|-----|-----|--------|
| `compiler_type_copy` calls | 52,755 | 50,180 | -2,575 (-4.9%) |

The semantic-registration row improved 3.2% by paired median and signature
registration was effectively flat, with a 0.4% median improvement and mixed
directions. However, the complete instrumented workload was 6.0% slower by
paired median, and the remaining `compiler_type_copy` calls reported higher
inclusive time in every pair. The cause of this instrumented regression is
unresolved, so the profile timing does not support a latency improvement claim.
Raw measurements are in
`compiler_signature_source_type_sharing_profiled_2026-07-27.tsv`.

Seven unprofiled A/B pairs then used 200 iterations:

| Measurement | Old median | New median | Change |
|-------------|------------|------------|--------|
| retired instructions | 57,659,154,847 | 57,367,964,602 | -0.5% |
| peak RSS | 137,920,512 bytes | 137,822,208 bytes | no material change |

Retired instructions improved in every pair, between 0.48% and 0.54%, with a
0.502% median paired reduction. Elapsed and user timings were mixed and
inconclusive; their paired medians regressed by 0.80% and 0.93%. Raw
measurements are in
`compiler_signature_source_type_sharing_unprofiled_2026-07-27.tsv`.

The old source is commit `60d47a459c8a557165426160f8f6269e76f6ba78`.
The new compiler-source patch has SHA-256
`4f37661cb29da0ba26d3be5424da1e57d98c8682d15f56cd46f1402481e7afe6`.
Both variants used the same host compiler, semantic worker, bootstrap bridge,
and C flags recorded in the preceding result.

## Callback Semantic-Parameter Reuse Result

Function body materialization previously converted every parsed parameter
annotation a second time solely to enforce the pure-callback boundary. It now
passes the registered function signature's semantic parameter types to that
existing check. This also closes a correctness hole: an impure callback hidden
behind a transparent type alias was previously accepted by the unit-level
pipeline because the parsed annotation had not been canonicalized.

Five profiled A/B pairs used the retained workload above:

| Operation | Old | New | Change |
|-----------|-----|-----|--------|
| `compiler_param_type_from_parsed` calls (now `param_type_from_parsed`) | 2,570 | 1,285 | -1,285 (-50.0%) |

The callback-check row improved by 56.3% at the paired median, with every pair
between 49.6% and 62.9%. The complete instrumented workload remained noisy:
two pairs improved, three regressed, and the median pair regressed by 2.1%.
That timing therefore does not establish a whole-workload latency gain. Raw
measurements are in
`compiler_callback_semantic_param_reuse_profiled_2026-07-27.tsv`.

Seven unprofiled A/B pairs then used 200 iterations:

| Measurement | Old median | New median | Change |
|-------------|------------|------------|--------|
| retired instructions | 57,370,826,293 | 57,144,558,428 | -0.4% |
| peak RSS | 137,854,976 bytes | 137,904,128 bytes | no material change |

Retired instructions improved in every pair, between 0.384% and 0.445%, with a
0.397% median paired reduction. Elapsed and user timings improved by paired
medians of 3.9% and 3.3%, respectively, but each had two reversals and the
sample showed substantial scheduling noise. The stable claim is reduced work,
not a measured latency percentage. Raw measurements are in
`compiler_callback_semantic_param_reuse_unprofiled_2026-07-27.tsv`.

The baseline is the preceding source-type-sharing patch
`4f37661cb29da0ba26d3be5424da1e57d98c8682d15f56cd46f1402481e7afe6`.
The candidate compiler-source patch has SHA-256
`20c7e5b05b7bc1cc1acd3cf278625802c594a1e9964c59cc9e74550c90512417`.
Both variants were built under equal-length underscore-only worktree paths
with the same host compiler, semantic worker, bootstrap bridge, and C flags
recorded above.

## Return Value-Match Reuse Result

Function body checking previously compared the finalized body value type with
the declared return type once for diagnostics and then repeated the identical
alias resolution and compatibility traversal when deciding whether to install
the declared return value slot. Body materialization now computes that boolean
once and passes it to both private consumers. Coverage additionally asserts
that a compatible dimension-erasing return updates both the semantic and value
types of the materialized body.

Five profiled A/B pairs used the retained workload above:

| Operation | Old | New | Change |
|-----------|-----|-----|--------|
| `compiler_return_types_compatible` calls | 2,570 | 1,285 | -1,285 (-50.0%) |

The local return-check and return-materialization rows became cheaper, but the
complete instrumented workload regressed in all five pairs, by 10.7% at the
paired median. The fifth candidate sample was a severe 3.06-second outlier.
As with the preceding source-sharing result, function instrumentation and
layout are not reliable latency evidence for this change. Raw measurements are
in `compiler_return_value_match_reuse_profiled_2026-07-28.tsv`.

Seven unprofiled A/B pairs then used 200 iterations:

| Measurement | Old median | New median | Change |
|-------------|------------|------------|--------|
| retired instructions | 57,116,608,728 | 56,378,487,988 | -1.3% |
| peak RSS | 137,969,664 bytes | 137,805,824 bytes | no material change |

Retired instructions improved in every pair, between 1.222% and 1.342%, with a
1.290% median paired reduction. Elapsed and user timings each improved in four
pairs and regressed in three, with paired median improvements of only 0.4% and
0.7%; one slow baseline sample materially affected the elapsed range. The
stable claim is reduced work, not a measured latency percentage. Raw
measurements are in
`compiler_return_value_match_reuse_unprofiled_2026-07-28.tsv`.

The baseline is the preceding callback semantic-parameter patch
`20c7e5b05b7bc1cc1acd3cf278625802c594a1e9964c59cc9e74550c90512417`.
The candidate compiler-source patch has SHA-256
`ddc96672559622f8d1a4005d3207753070022cf2b15f7ab2302153f0ddba90e6`.
Both variants were built under equal-length underscore-only worktree paths
with host compiler
`e5a3366c3f73071ff4c711249d5eb7f67bc09a7da8e858ee53984d2809bf77a0`
and semantic worker
`535ac8dd3398144d1b5b13bbb22122e5db1a5af7db919670308bacc6ecc0dd6e`.

## Canonical Zonked Value-Slot Reuse Result

Every inferred expression stores a canonical `CompilerValueSlot` (now
`ValueSlot`) plus mirrored
semantic and runtime value types. Finalization previously zonked all three
representations independently. It now checks each mirror against the canonical
slot, reuses the zonked slot type when they agree, and independently zonks a
mismatched mirror so the typed-program validator can still report malformed
state. Focused coverage exercises a widening slot whose semantic and value types
resolve from different metas and also verifies that finalization preserves an
incoherent mirror for the existing diagnostic.

Five profiled A/B pairs used the retained workload above:

| Operation | Old | New | Change |
|-----------|-----|-----|--------|
| `compiler_zonk_type` calls (now `zonk_type`) | 25,650 | 15,390 | -10,260 (-40.0%) |
| recursive meta-resolution calls | 28,210 | 17,950 | -10,260 (-36.4%) |
| `compiler_types_equal` calls (now `types_equal`) | 17,975 | 28,235 | +10,260 (+57.1%) |

The added instrumented equality calls dominate this build: the directly
changed zonk-info row regressed by 191.9% at the paired median, finalization
regressed by 99.1%, and the complete instrumented workload regressed in all five
pairs by 16.6%. These internally distorted timings do not establish production
latency; the profile is useful here for exact operation counts only. Raw
measurements are in
`compiler_zonk_value_slot_reuse_profiled_2026-07-28.tsv`.

Seven unprofiled A/B pairs then used 200 iterations:

| Measurement | Old median | New median | Change |
|-------------|------------|------------|--------|
| retired instructions | 56,376,558,765 | 56,249,148,083 | -0.2% |
| peak RSS | 137,986,048 bytes | 137,723,904 bytes | -0.2% |

Retired instructions improved in every pair, between 0.187% and 0.237%, with a
0.211% median paired reduction. Peak RSS was also lower in every pair, with a
0.178% paired median reduction, but that is too small to treat as a material
memory improvement. Elapsed and user timings each improved in three pairs and
regressed in four, with paired median regressions of 0.2% and 0.3%. The stable
claim is the small reduction in work, not a latency improvement. Raw
measurements are in
`compiler_zonk_value_slot_reuse_unprofiled_2026-07-28.tsv`.

The baseline is the preceding return value-match patch
`ddc96672559622f8d1a4005d3207753070022cf2b15f7ab2302153f0ddba90e6`.
The candidate compiler-source patch has SHA-256
`d225fd8f89e55c0f90b7270ece6e00625362ad8fd475cb51f80ae6e29acb2d30`.
Both variants were built under equal-length underscore-only worktree paths
with host compiler
`fb160bd02dbdbdf11480beb75d434aefee8925b9ef2f1c8de0f0977f105485f2`,
semantic worker
`535ac8dd3398144d1b5b13bbb22122e5db1a5af7db919670308bacc6ecc0dd6e`,
and bootstrap bridge
`5c0d99b9ca8da35c2e5d008bc1ca08ec9b6eda2dd8de8010a686a43079bbaa88`.

## Compact Typed-Expression Metadata Result

`CompilerTypedExprInfo` (now `TypedExprInfo`) previously retained
`semantic_type` and `value_type`
beside the canonical `ValueSlot` that already contains the semantic
type and widening decision. The mirrors have been removed. Named accessors now
derive both type views from the slot, and typed-AST JSON continues to emit the
same fields for artifact compatibility. Finalization zonks the slot once rather
than conditionally maintaining three representations. Validation still checks
the slot's internal semantic/decision invariant, while cross-representation
incoherence is now unrepresentable.

The retained bridge replay used identical parser and renderer binaries and
alternated baseline and compact typecheck workers. Responses were byte-identical.

| Workload | Baseline elapsed | Compact elapsed | Paired change | Baseline RSS | Compact RSS |
|----------|------------------|-----------------|---------------|--------------|-------------|
| default, 20 runs | 144.765 ms | 143.602 ms | -1.16% | 12,271,616 bytes | 12,353,536 bytes |
| wide, 10 runs | 569.830 ms | 572.147 ms | -0.79% | 25,165,824 bytes | 25,223,168 bytes |
| `compiler_infer.brp`, 5 pairs | 12.73 s | 12.90 s | -0.24% | 590,512,128 bytes | 590,397,440 bytes |

The absolute and paired timing directions disagree in the wider samples, and
RSS changes are below one percent, so these measurements do not establish a
whole-frontend latency or peak-RSS improvement. A `vmmap` sample of the wide
replay reported the same 247,013 allocations for both workers but reduced the
`MALLOC_SMALL` reservation from 37,748,736 bytes to 33,554,432 bytes (36 MiB to
32 MiB). Physical footprint was effectively flat (20,656,947 versus 20,552,089
bytes). The supported conclusion is narrower: the typed-expression model owns
two fewer recursive type values per node, reserves less small-allocation space
under the wide fixture, and has a single representable source of truth.

The baseline typecheck bridge SHA-256 is
`86781ef422c97f6f1c9792bfbf1b08d286226157fbc0b6691bf5cbcc97eeda8f`.
The compact bridge SHA-256 is
`4b46b5578ab43ca8a456e828b7418e30040cb0816dfdd5ffa9bcfc739d2208be`.

## Canonical Return Alias Boundary Result

Function signatures canonicalize annotations during registration, and finalized
typed-expression slots carry canonical semantic and value types. Return
compatibility nevertheless resolved both inputs through the complete alias
reconstruction traversal on every function body. The comparison is now an
environment-free canonical boundary: it accepts the in-scope type-parameter
names plus the two canonical types and calls structural compatibility directly.
Focused coverage verifies nested generic function-alias expansion before this
boundary and forwarding a call result through an alias-typed return.

Five profiled A/B pairs used the retained function-heavy workload with five
iterations per sample:

| Operation | Baseline | Canonical boundary | Change |
|-----------|----------|--------------------|--------|
| `compiler_env_resolve_alias` calls (now `env_resolve_alias`) | 11,705 | 9,135 | -2,570 (-22.0%) |
| return compatibility calls | 1,285 | 1,285 | unchanged |
| return compatibility inclusive time | 34.565 ms | 18.437 ms | -46.7% |

The exact call reduction is two full alias resolutions for each compatibility
check. As in earlier function-profile experiments, instrumentation distorted the
complete workload: every candidate sample was slower, with an 11.7% paired
median regression. That result is not production latency evidence. Raw samples
are in `compiler_return_alias_boundary_profiled_2026-08-01.tsv`.

A fair unprofiled bridge comparison then built baseline and candidate workers
from the same pinned bootstrap and alternated 20 measured runs after two
warmups:

| Measurement | Baseline median | Canonical boundary median | Paired change |
|-------------|-----------------|---------------------------|---------------|
| elapsed | 91.798 ms | 91.509 ms | -0.68% |
| peak RSS | 12,763,136 bytes | 12,730,368 bytes | -0.26% |

The 1,282,207-byte responses were byte-identical. The supported conclusion is
reduced redundant work and a clearer canonical-type contract, not a measurable
whole-worker speedup or memory reduction. Broader alias caching should wait for
an alias-heavy scaling fixture with expanded-node and reconstructed-node counts.
Aggregate replay evidence is in
`compiler_return_alias_boundary_unprofiled_2026-08-01.tsv`.

The baseline source is commit `53002113`, with
`compiler_typecheck_decl.brp` SHA-256
`88e9408c70ea094a9ded29b822fb7a6245bac33bfef1effa3c3a69e84510af69`.
The candidate source SHA-256 is
`fcd2f16635c2a4d1cc95af41b258fec46ccfb8fb88fe7960d7c3477999d364fd`.

## Alias Target Sharing Result

Full alias resolution copied every immutable alias target before passing it to
pure substitution, which then either shared or reconstructed that value before
the resolver traversed it again. Alias targets are immutable environment data,
and the head-only resolver already passes them directly to the same substitution
function. Full resolution now follows that established ownership boundary.

An `alias` mode in `compiler_typecheck_profile` provides a deterministic fast
feedback loop. The measured workload performed 2,560 resolutions through a
16-alias chain whose final structural target contained 129 nodes. It validated
all results while reporting 40,960 logical alias expansions and 330,240 logical
result nodes.

Five alternating profiled pairs produced:

| Measurement | Baseline median | Shared-target median | Change |
|-------------|-----------------|----------------------|--------|
| defensive copy calls | 737,424 | 368,784 | -368,640 (-50.0%) |
| resolver-node visits | 371,200 | 371,200 | unchanged |
| alias expansions | 40,960 | 40,960 | unchanged |
| full resolver inclusive time | 309.731 ms | 250.164 ms | -19.2% |
| alias workload elapsed | 511.705 ms | 449.520 ms | -12.15% |

Every elapsed pair improved, between 11.3% and 12.5%. The 368,640-call reduction
is exact: each resolution no longer copies the 129-node final target plus the 15
one-node intermediate alias targets. Required alias expansion and resolver
traversal counts are unchanged. Raw samples are in
`compiler_alias_target_copy_profiled_2026-08-01.tsv`.

A fair unprofiled full-worker comparison alternated 20 measured runs after two
warmups on the existing typecheck-memory fixture:

| Measurement | Baseline median | Shared-target median | Paired change |
|-------------|-----------------|----------------------|---------------|
| elapsed | 91.505 ms | 91.301 ms | -0.30% |
| peak RSS | 12,763,136 bytes | 12,763,136 bytes | -0.13% |

The 1,282,207-byte responses were byte-identical. The supported conclusion is a
material improvement for alias-heavy resolution, with no measurable change to
the broad worker fixture. This slice adds sharing, not a cache, and preserves
cycle handling and final structural reconstruction. Aggregate replay evidence
is in `compiler_alias_target_copy_unprofiled_2026-08-01.tsv`.

The baseline `compiler_env.brp` SHA-256 is
`05032f39d76b7b5ebe9da5f839c38f89b3d995a0842e911abe08d01b9434e3e5`;
the candidate is
`05b247381222497c29a1fdcdeb3580441afc8e5208c7329b034e899f2388d000`.
The corresponding profiled artifact SHA-256 values are
`a6bf048979af630404eadd36588cf6c610f0da81a8b6662cca4409d310b6eb8f`
and `ab60a7314fc8ed2c2ac108792e9a0bf158cecf8f4a4f090e70a30c161b5e0fc2`.

## Alias Registration Sharing Result

Transparent alias registration deep-copied the immutable target before storing
it in the persistent environment. Registration now retains the target directly,
matching the sharing boundary used by other immutable compiler values. Opaque
alias registration still copies its target; this slice does not change that
nominal boundary.

The new `alias-register` workload constructs one 129-node structural target,
then registers it under 16 names in each of 256 fresh environments. Target
construction is outside the timed region. The timed workload includes one
validating lookup and structural comparison per environment, so the elapsed row
below is registration plus validation. Ten alternating profiled pairs produced:

| Measurement | Baseline median | Shared-target median | Change |
|-------------|-----------------|----------------------|--------|
| defensive copy calls | 561,408 | 33,024 | -528,384 (-94.1%) |
| alias registrations | 4,096 | 4,096 | unchanged |
| registration-plus-validation elapsed | 117.721 ms | 30.069 ms | -74.5% |

The call reduction is exact: 4,096 registrations no longer reconstruct the
129-node target, removing 528,384 recursive copy calls. The remaining 33,024
calls come from one 129-node validating lookup per iteration. All ten combined
elapsed pairs improved, between 73.1% and 77.3%. The isolated
`compiler_env_add_alias` profile row (now `env_add_alias`) fell from a
59.939 ms median to 5.649 ms.
Raw measurements are in
`compiler_alias_registration_copy_profiled_2026-08-01.tsv`.

A fair whole-worker comparison alternated 20 runs after two warmups using
workers built from the same post-merge compiler and pinned bootstrap:

| Measurement | Baseline median | Shared-target median | Paired change |
|-------------|-----------------|----------------------|---------------|
| elapsed | 92.954 ms | 93.475 ms | +0.22% |
| peak RSS | 12,763,136 bytes | 12,713,984 bytes | -0.39% |

The 1,282,207-byte responses were byte-identical. Both whole-worker differences
are noise-level, as expected for a fixture that does little alias registration.
The supported conclusion is a material reduction in work for alias-heavy
registration, not a measurable broad typecheck speedup. Aggregate replay
evidence is in
`compiler_alias_registration_copy_unprofiled_2026-08-01.tsv`.

The production baseline is merge commit `5d38ca2d` plus the same uncommitted
`alias-register` harness used by the candidate. The measured fixture and runner
SHA-256 values are
`c70a7c64e9a36087f43ba07232e63f023abf5e2d95e2fe30cd9d477bbed70c9f`
and `30f3b66f30ea652028e1f3cb1def5a1070afc856eeb523a48400c2eb4ed99c6d`.
The baseline `compiler_env.brp` SHA-256 is
`05b247381222497c29a1fdcdeb3580441afc8e5208c7329b034e899f2388d000`.
The candidate source SHA-256 is
`9c927b757e824a969b9434a339b169433d061ff630a0791fc4e3abf088a80fd6`.
The baseline and candidate typecheck worker SHA-256 values are
`91621e11f1e273bc930cc3bc4b1e37e33ffb492cde49d6d8e47b9c88581cd4cb`
and `f2d3fa6c80978dc157d6b049633c52e9156ad42c89bcdf46e72eecf0831f379a`.
