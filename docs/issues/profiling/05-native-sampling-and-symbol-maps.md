# Make Optimized Native Sampling And Symbolization First-Class

**Status:** Ready for implementation

**Roadmap dependency:** None for the sampling adapter; rebase final metadata
integration over Issue 1

**Unblocks:** Issue 6

## Issue Summary

Add a maintained, cross-platform compiler-profiling adapter that runs optimized
Blorp executables under native statistical sampling and maps compact generated
C symbols back to logical Blorp functions, modules, source locations, and
compiler stages.

This becomes the normal mechanism for answering “where is CPU time going?”
Exact Blorp probes remain complementary evidence for call counts and focused
timing.

## Motivation

Blorp compiles to native C and already benefits from platform profilers, but
the workflow is manual:

1. build a fresh compiler;
2. arrange an optimized workload;
3. launch it and attach `sample` or `perf`;
4. generate a separate `--profile` C artifact;
5. scrape logical names from string probes;
6. join compact `brp_*` native symbols to those names;
7. collapse stacks; and
8. derive flat, cumulative, stage, and module views.

The retained scripts under `logs/compiler-self-profile-current/` demonstrate
that this can work, but ignored, revision-specific analysis scripts are not a
profiling capability. They also require an instrumented artifact merely to
recover names for an uninstrumented sampled binary.

Sampling should operate on the optimized binary whose latency is being
investigated. PEP 669 explicitly recommends statistical profiling when exact
counts are not required. Go's CPU profiler uses bounded stack sampling and
records lost samples. The first Blorp implementation should rely on mature host
sampling rather than immediately adding signal-safe stack unwinding to the
runtime.

## Goals

- Collect real native call stacks from an optimized compiler or Blorp program.
- Support current macOS arm64 and Linux x86_64/arm64 development hosts.
- Emit a semantic symbol sidecar directly from compiler metadata, without
  scraping profile probes.
- Symbolize sampled addresses against the exact build-ID-matched binary before
  joining native frames to semantic metadata.
- Normalize platform samples into one documented intermediate stack format.
- Produce flat self, cumulative, module, and compiler-stage views.
- Preserve unknown native/runtime frames rather than dropping them.
- Report sample frequency, duration, total samples, unmapped symbols, truncated
  stacks, and lost records.
- Verify that sampled and unsampled runs produce identical semantic output.
- Keep platform-specific tools behind a small adapter boundary.

## Non-Goals

- Do not implement an in-process signal sampler.
- Do not require Clang, LLVM XRay, Instruments.app automation, or privileged
  Linux `perf` access for ordinary builds/tests.
- Do not use exact function probes as the timing source.
- Do not strip runtime/library frames before preserving the raw normalized
  profile.
- Do not infer compiler stage from a substring when the symbol sidecar can carry
  explicit owning module/stage metadata.
- Do not check large native profile artifacts into the repository.
- Do not claim exact call counts from samples.

## Required Reading And Existing Prototype

| Responsibility | Location |
| --- | --- |
| C symbol projection | `blorp/src/compiler/stage_10_backend/c_symbol_projection.brp` |
| Current display-name handoff | `blorp/src/compiler/stage_10_backend/emit.brp`, `emitted_function_display_name` |
| Symbol hashing constraints | `docs/C_SYMBOL_HASHING_ROADMAP.md` |
| Current compiler phase names | `blorp/src/compiler/pipeline.brp` and `docs/DEVELOPMENT.md` |
| Historical sampling prototype | `logs/compiler-self-profile-current/run_profile.sh` |
| Historical stack normalizer | `logs/compiler-self-profile-current/collapse_sample.py` |
| Historical attribution | `logs/compiler-self-profile-current/analyze_profile.py` |

Treat ignored logs as design evidence only. Move reusable behavior into owned
source and write new tests; do not make production scripts import from `logs/`.

## Symbol Sidecar Design

Add an explicit compiler option used by the future profile command:

```text
--emit-symbol-map=<path>
```

The exact public spelling may be finalized in Issue 6, but the compiler API
must be able to request the product independently of function instrumentation.

Emit versioned NDJSON or another equally explicit format. Example:

```json
{"kind":"symbol_map_header","schema_version":1,"build_id":"...","functions":12048}
{"kind":"function","schema_version":1,"c_symbol":"brp_3i9","logical_name":"scope_add_symbol","module_path":"compiler/stage_05_types/env","stage":"stage_05_types","source_path":"blorp/src/compiler/stage_05_types/env.brp","source_line":312,"definition_id":418,"origin":"source"}
{"kind":"symbol_map_end","schema_version":1,"records":12048,"complete":true}
```

Carry explicit origin variants for:

- source functions;
- specialized source functions;
- generated closures;
- generated type destructors/copy helpers;
- compiler-generated adapters; and
- runtime/native functions when the compiler owns useful metadata.

Not every row needs every source field. Absence is explicit. Never use an empty
module path or `-1` definition ID as an undocumented sentinel.

The sidecar contributes semantic identity for the exact native binary. Include
or later fill in:

- Blorp source revision;
- generated-C SHA-256;
- native binary SHA-256 or build ID;
- C compiler and flags; and
- symbol-map schema version.

If the binary does not exist until after the compiler emits the sidecar, the
profile wrapper may create a final manifest joining the C-sidecar identity with
the native binary hash. Do not rewrite semantic function rows based on `nm`
ordering.

The profile metadata plan from Issue 1 and the native symbol plan should share
one authoritative function-description builder. The native map is broader:
sampling must name uninstrumented functions, whereas exact metadata contains
only selected probe IDs.

## Native Build Requirements

The sampled artifact must match the optimized production behavior while
retaining enough unwind/symbol information:

```text
-O2
-gline-tables-only (or the portable local equivalent)
-fno-omit-frame-pointer where the platform sampler benefits
```

Record the exact flags. Validate the incremental overhead of frame pointers on
the compiler workload and keep sampled/unsampled comparison binaries otherwise
identical. Do not compare an `-O0` symbol-rich build with the production `-O2`
compiler.

Preserve the unstripped binary for symbolization. If release publication later
strips binaries, keep debug/symbol data as a profile artifact rather than
changing the shipped binary by accident.

## Post-Link Address Identity And Optimized Code

The semantic sidecar's `c_symbol` is not, by itself, a sufficient join key at
`-O2`. The host compiler may inline a function, split hot and cold portions,
clone or specialize a local function with suffixes such as `.constprop` or
`.isra`, remove a standalone symbol, or decorate a platform symbol with a
leading underscore.

Preserve a sampled program counter or binary-relative address for every native
frame. Before semantic joining, symbolize each distinct address against the
exact unstripped binary and its debug information:

- macOS uses `atos`, `xcrun` symbolization tooling, or the structured
  symbolication already present in `sample`, verified against the binary UUID;
- Linux uses `perf`'s build-ID-aware symbolization, `llvm-symbolizer`, or
  `addr2line`, verified against the ELF build ID; and
- every symbolized result retains its concrete frame plus any inline call
  chain, source file/line, linkage name, and abstract origin exposed by the
  tool.

Join a symbolizer-provided canonical linkage/abstract-origin name to the
compiler sidecar. An inlined function therefore remains visible even when it
has no standalone address range. A split or cloned function should resolve
through debug abstract-origin metadata where available.

When debug information is unavailable and only spelling remains, isolate a
fallback normalizer for platform decoration and recognized host-compiler clone
suffixes. Mark every fallback-resolved frame and report its count separately.
Do not strip arbitrary suffixes until a name happens to match, and do not merge
two possible semantic functions. An ambiguous fallback remains unmapped.

The final bundle records:

- binary UUID/build ID and SHA-256;
- raw sampled addresses/module offsets;
- the symbolizer and version;
- exact, abstract-origin, fallback, ambiguous, and unmapped frame counts; and
- whether inline stacks were available.

A profile whose debug data or build identity does not match the sampled binary
is rejected before semantic attribution.

## Platform Adapter

Define one internal command contract:

```text
sample_process(
    executable,
    args,
    frequency_hz,
    duration_or_until_exit,
    raw_output,
) -> SamplingResult
```

`SamplingResult` includes process status, sampler status, start/stop timestamps,
requested and observed sample rate, and loss/truncation diagnostics.

### macOS

Use `/usr/bin/sample` for the first maintained path because it is available on
supported development hosts and has already worked for compiler profiles.
Parse its call-graph section with fixture-owned inputs. Preserve the raw file.

Do not assume a long-lived process. Start the compiler, obtain its PID, attach
immediately, and sample until exit or the configured maximum. Report startup
samples missed before attachment. An eventual Instruments Time Profiler adapter
may improve fidelity, but it is not required for the first slice.

### Linux

Use `perf record`/`perf script` when available and permitted:

```text
perf record -F <frequency> -g -- <executable> <args...>
perf script
```

Detect permission and availability failures before launching an expensive
workload when possible. Return an actionable message describing
`perf_event_paranoid` or missing tooling. CI parser tests use captured small
fixtures and do not require privileged `perf`.

If frame-pointer unwinding is insufficient, make the call-graph mode explicit
and recorded; do not silently switch between frame-pointer and DWARF behavior.

## Normalized Stack Format

Retain raw platform output, then normalize to folded stacks:

```text
process;thread;native_root;brp_3i9;malloc 14
```

After joining the symbol map, produce semantic stacks:

```text
compiler;stage_06_typecheck;compiler/stage_05_types/env;scope_add_symbol 14
```

Keep separate products:

- raw native folded stacks;
- logical function stacks;
- module-collapsed stacks; and
- stage-collapsed stacks.

Never destructively replace an unmapped frame. Mark it as unmapped and retain
its original native spelling/address. Adjacent duplicate logical module/stage
frames may be collapsed only in the derived architectural view, not raw stacks.

From normalized stacks, compute:

- flat/self samples;
- cumulative/inclusive samples;
- attributed compiler function/module/stage samples, where runtime leaf cost is
  charged to the nearest compiler caller; and
- unmapped frame and sample counts.

Clearly distinguish these views. Cumulative sample percentages overlap; flat
sample percentages partition sampled CPU work.

## Implementation Steps

1. Check in small representative macOS `sample` and Linux `perf script`
   fixtures, trimmed to the minimum needed to test parsing.
2. Move the historical normalizer concepts into `scripts/support/` or the
   repository's existing script-library owner.
3. Define normalized folded-stack and diagnostics types.
4. Add the compiler-owned symbol-description product and sidecar emitter.
5. Add C/native binary identity fields and strict sidecar parsing.
6. Implement macOS collection and normalization.
7. Implement Linux collection and normalization.
8. Add exact-binary address symbolization, including inline frames and build-ID
   validation.
9. Join symbolizer identities to logical functions and retain unmapped frames.
10. Produce flat, cumulative, module, and stage TSV views.
11. Add optional flamegraph/Speedscope rendering only after normalized stacks
    are independently tested.
12. Compare sampled and unsampled optimized compiler runs using the shared
    measurement contract.

## Tests

### Symbol map

Cover:

- long names mapped to compact C symbols;
- two source functions with the same leaf name in different modules;
- specialized functions sharing a source definition;
- generated closure and destructor origins;
- paths/names requiring JSON escaping;
- deterministic output across repeated compilation;
- complete footer and exact record count;
- generated-C and binary identity mismatch rejection; and
- sidecar emission without function probes.

### Parser/normalizer

For both platform fixtures, cover:

- one and multiple threads;
- repeated stacks folded into counts;
- unknown frames;
- addresses with and without symbols;
- macOS leading-underscore decoration;
- inlined frames with no standalone function address;
- hot/cold split symbols and `.constprop`/`.isra`-style clones;
- duplicate and ambiguous fallback spellings;
- truncated native stacks;
- sampler loss diagnostics;
- process exit before attachment;
- nonzero target exit;
- sampler process failure; and
- platform output format rejection with an actionable version message.

### Integration

On supported developer hosts, one smoke test profiles a short optimized Blorp
program. A slower optional/manual test profiles compiler self-compilation. CI
must always test parsing and symbol joining but may skip actual sampling when
host permissions are unavailable.

## Fast Feedback Loop

Run parser fixtures without rebuilding Blorp. Then run the focused symbol-map
backend test and one tiny compile:

```bash
bin/blorp test blorp/test/compiler/stage_10_backend/test_c_symbol_projection.brp
bin/blorp test blorp/test/compiler/stage_10_backend/test_core_emit.brp
```

Use a short native program for the first platform smoke. Only after symbol join
and diagnostics are stable should the worker run a compiler self-profile.

Before review:

```bash
make
scripts/test compiler-blorp cli
make quality
```

Run the platform smoke on macOS and Linux where available. Record a skipped
Linux native collection as unavailable, not passing zero samples.

## Measurement Plan

Use a default sampling rate near 100 Hz. Record one unsampled optimized run and
at least seven alternating sampled/unsampled pairs. Report:

- target wall time and retired instructions;
- sampler CPU time if available;
- requested and observed samples;
- samples per second;
- maximum and median stack depth;
- mapped and unmapped symbols/frames/samples;
- truncated/lost samples;
- native binary and output hashes; and
- frame-pointer build delta relative to the otherwise identical optimized
  binary.

The maintained default should target no more than 5% median target slowdown on
compiler self-compilation. If native tool behavior on one platform exceeds
that, lower the default frequency or document a separate high-resolution mode;
do not hide the overhead.

## Acceptance Criteria

- [ ] Optimized native sampling works through one internal adapter on supported
      macOS and Linux development hosts.
- [ ] Sampling does not require function entry/exit instrumentation.
- [ ] The compiler emits a versioned symbol sidecar from semantic metadata.
- [ ] The sidecar is available independently of `--profile` probes.
- [ ] Sampled addresses are symbolized against the exact build-ID-matched
      binary, including inline frames where debug information provides them.
- [ ] Exact or abstract-origin symbolizer identity maps to logical name, module,
      stage, source, and origin where those facts exist.
- [ ] Decorated/clone-name fallback is isolated, conservative, and reported
      separately from exact symbolization.
- [ ] Platform output normalizes into real folded call stacks.
- [ ] Raw native and normalized outputs are both retained.
- [ ] Flat, cumulative, module, and stage views are clearly distinguished.
- [ ] Unknown/truncated/lost data remains visible and counted.
- [ ] Target output and exit status match the unsampled run.
- [ ] Default sampling overhead is measured and is no more than the accepted
      5% target, or the change remains unaccepted pending a documented design
      adjustment.
- [ ] Parser tests do not require privileged sampling in CI.
- [ ] No reusable implementation remains under ignored `logs/` paths.

## Pitfalls And Review Questions

- Is the symbol map produced by scraping C or exact profile strings instead of
  compiler metadata?
- Does the implementation join only raw C symbol spelling and therefore lose
  inlined, split, cloned, or decorated optimized frames?
- Is every address symbolized with the exact binary UUID/build ID rather than a
  similarly named newer executable?
- Does the sampled binary differ from the unsampled binary in optimization or
  runtime sources?
- Are generated destructors—the current hottest sampled functions—left
  permanently unmapped?
- Does stage attribution guess from function spelling rather than module data?
- Are unmapped runtime leaves dropped, inflating compiler-only percentages?
- Does attachment miss a material share of a short workload without saying so?
- Can sampler failure be mistaken for a target failure?
- Is Linux CI marked green with zero samples because `perf` was unavailable?
- Are huge raw profiles accidentally checked into Git?

This issue is complete when a developer can obtain trustworthy optimized
stacks without first generating an exact-instrumented compiler.
