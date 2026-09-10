# Add One Coherent Profiling Command And Reproducible Artifact Bundle

**Status:** Ready after Issues 2, 4, and 5

**Roadmap dependencies:** Explicit modes/selection, structured exact output,
and native sampling/symbol maps

**Unblocks:** Normal profiling adoption and Issue 7 integration

## Issue Summary

Add one user-facing profiling workflow that clearly distinguishes profiling a
program from profiling the compiler, chooses the appropriate measurement mode,
builds the correct artifact, and produces a reproducible result bundle.

The command should make the safe, low-observer-effect path the default:

```text
blorp profile compiler --through=c-emission
blorp profile compiler --through=stage06
blorp profile run program.brp -- --program-args
```

These default to optimized native CPU sampling. Exact and count-only modes are
explicit:

```text
blorp profile compiler --mode=calls --module=compiler/stage_06_typecheck
blorp profile run --mode=exact --function=app/work::solve app.brp
```

## Motivation

Current commands use the same word for different operations:

- `compile --profile` adds probes to the produced program;
- `run --profile` compiles and executes a probed program;
- `test --profile` profiles generated test artifacts;
- `compile --time-phases` measures broad compiler pipeline regions; and
- profiling the compiler itself requires external scripts and native tools.

This creates avoidable measurement mistakes. A developer investigating
compiler latency can accidentally profile execution of the output program, run
an exact `-O0` artifact, or sample a stale compiler binary. The command should
encode the repository's measurement discipline so the result is useful by
default.

## Goals

- Make compiler self-profiling a one-command operation.
- Make optimized native sampling the default CPU mode.
- Expose calls and selective exact timing without ambiguous Boolean flags.
- Separate compiler workload boundaries from produced-program profiling.
- Capture phase timings alongside native samples when profiling the compiler.
- Create a self-describing output directory with raw and derived artifacts.
- Verify binary/source identity and semantic output.
- Propagate target, build, sampler, and report failures accurately.
- Avoid generated artifacts in the repository.
- Provide concise terminal guidance to the top report and next useful command.

## Non-Goals

- Do not add a web service, daemon, or remote profile store.
- Do not upload profiles automatically.
- Do not make exact instrumentation the default.
- Do not hide platform sampler limitations.
- Do not combine benchmark statistical comparison with one-shot hotspot
  profiling; benchmark wrappers remain responsible for repeated performance
  experiments.
- Do not preserve ambiguous `--profile` aliases indefinitely.
- Do not compile generated C to a native binary when profiling the compiler
  only through C emission.

## Command Model

Add `profile` as a top-level CLI action with explicit targets:

```text
blorp profile compiler [options] [source]
blorp profile run [options] <file.brp> [-- args...]
blorp profile test [options] <file.brp|directory> ...
```

### Common options

```text
--mode cpu|calls|exact          default: cpu
--output-dir PATH               default: a new system-temporary directory
--frequency HZ                  cpu mode only, named default near 100 Hz
--module LOGICAL_PATH           repeatable calls/exact selector
--function MODULE::FUNCTION     repeatable calls/exact selector
--threads N
--retain-generated-c            default: false
--human                         print concise human summary
```

Reject mode-inapplicable combinations, such as `--frequency` with `calls` or
`--function` with `cpu` until native filtering has defined semantics.

### Compiler options

```text
--through stage06|core-lowering|early-core|late-core|c-emission
--workload PATH                 default: blorp/src/main.brp in a source checkout
--subject-compiler PATH         profile this already-built compiler executable
--build-subject-with PATH       compiler used to build a fresh subject compiler
--workers N
```

The **subject compiler** is the executable whose runtime behavior is measured.
The **builder compiler** constructs that subject from the current compiler
source. The workload is the source graph that the subject compiles. Keep these
three identities separate in configuration, logs, hashes, and errors.

By default, use the repository's pinned bootstrap/build route to construct a
fresh subject compiler from the current checkout. `--build-subject-with`
overrides only the builder. `--subject-compiler` skips subject construction and
measures the supplied executable. Reject supplying both options unless a later
explicit workflow gives the combination a distinct meaning.

CPU mode can sample an ordinary optimized subject. Calls/exact modes require a
subject built with their corresponding function-profile mode. Embed a small
profile capability/build descriptor in compiler executables so the command can
verify mode, metadata schema, source revision, and runtime ABI before launching
the workload. A plain or differently instrumented `--subject-compiler` is an
invalid configuration, not a zero-row successful profile.

Use canonical compiler phase boundaries rather than translating arbitrary
user strings into private functions. `stage06` uses the accepted typecheck/check
route; Core boundaries use the existing stop-after pipeline contract;
`c-emission` emits C and stops before the host C compiler.

The command must never compile that emitted C unless a separate option and
profile target explicitly asks to profile host C compilation. The user asked
for compiler-to-C latency, and accidentally including Clang/GCC would invalidate
the profile.

### Program/test options

`profile run` builds the target at the configured optimized profiling flags,
then profiles target execution. `profile test` preserves the ordinary test
runner's timeout, aggregation, stdin, signal, and exit contracts while adding
the chosen instrumentation/sampler.

Do not make program arguments compete with profile options. Follow the current
`run ... -- args` boundary and test it.

## Artifact Bundle

Create a unique directory with a versioned manifest:

```text
blorp-profile-<timestamp>-<short-revision>/
  manifest.json
  command.txt
  target.stdout
  target.stderr
  phase-timings.ndjson
  symbol-map.ndjson
  cpu.raw                         # platform-native, cpu mode only
  stacks.native.folded            # cpu mode only
  stacks.logical.folded           # cpu mode only
  top.self.tsv
  top.cumulative.tsv
  modules.tsv
  stages.tsv
  functions.ndjson                # calls/exact mode only
  human.txt
```

Only files applicable to the mode are present. The manifest lists every
expected artifact with status and SHA-256 so absence cannot be confused with an
empty profile.

Required manifest fields include:

- schema version;
- exact user command and normalized internal commands;
- target kind and compiler boundary;
- Git revision and dirty state;
- bootstrap release;
- compiler executable path and SHA-256;
- generated-C and native binary SHA-256 where applicable;
- standard-library root and source inventory fingerprint;
- C compiler/version/flags;
- profile mode, sampling frequency, selectors, worker/thread count;
- host OS, architecture, CPU identity, and timestamp;
- target and sampler exit status;
- output semantic hash;
- duration and sample/count diagnostics; and
- completeness status with explicit failure reasons.

Do not put secrets or the entire ambient environment in the manifest. Record a
small allowlisted set of environment variables that affect Blorp compilation,
runtime workers, profiling, or standard-library resolution.

## Build And Freshness Rules

Default compiler profiling must use a subject compiler built from the current
checkout. If the working tree is dirty, record it and either build that working
tree or require `--subject-compiler`; do not silently reuse `bin/blorp` without
proving its source identity.

Reuse the normal build contention lease so parallel benchmark/test jobs do not
overwrite shared build products. A profile command may use a temporary build
directory or verified cache, but its manifest must identify the resulting
binary.

For CPU sampling, use `-O2`, retained symbols/line tables, and the platform
unwind policy from Issue 5. For calls/exact mode, use the same optimization
level unless the user explicitly requests a debug profile. Label debug profiles
so they cannot be compared accidentally with optimized results.

Perform a bounded warmup where the workload supports it. Record warmup status
and exclude it from the captured profile. Do not run an unbounded hidden warmup
on arbitrary user programs.

## Output And Terminal UX

On success, print a compact result:

```text
Profile complete: /tmp/blorp-profile-.../
Mode: cpu, 100 Hz, 10.42 s, 1,039 samples, 0 lost
Top self: scope_add_symbol 10.4%, Scope_destroy 9.8%, ...
Open: .../human.txt
```

On partial collection, say `Profile incomplete` and list the missing/lost
facts. A target failure remains a target failure even if the profiler wrote a
valid partial profile. A sampler failure remains distinct from a compiler
failure. Use a small result variant rather than a Boolean success flag:

```blorp
union ProfileCommandResult:
    ProfileComplete(ProfileBundle)
    ProfileTargetFailed(ProfileBundle, Int)
    ProfileCollectorFailed(ProfileBundle, String)
    ProfileBuildFailed(String)
    ProfileInvalidConfiguration(String)
```

Match current CLI error/exit conventions when mapping the variants to process
status.

## Migration From Existing Flags

Update repository docs, benchmarks, tests, and scripts to the new command.
Remove ambiguous public `--profile` spellings after all owned call sites move:

- `compile --profile` becomes an internal instrumentation option used by
  `profile run/test --mode=exact`, or a clearly named low-level
  `--instrument-functions=exact` option if direct artifact production remains
  valuable;
- `run --profile` becomes `profile run --mode=exact`;
- `test --profile` becomes `profile test --mode=exact`; and
- `--time-phases` remains available because it is a cheap compiler diagnostic,
  while `profile compiler` enables it automatically.

Because Blorp is pre-0.1, do not retain a compatibility shim solely to avoid
updating repository call sites. If a brief bisectable transition is required,
remove it within this issue before acceptance.

## Implementation Steps

1. Add CLI parser/help tests for the full command grammar and invalid
   combinations.
2. Model target, mode, selection, compiler boundary, and output policy as
   variants/structs.
3. Implement artifact-directory creation and manifest lifecycle first, using a
   fake collector in tests.
4. Add fresh compiler resolution/build identity and contention handling.
   Keep builder compiler, subject compiler, and workload identity separate.
5. Integrate CPU sampling from Issue 5.
6. Integrate calls/exact instrumentation and structured output from Issues 2
   and 4.
7. Add compiler boundary mapping and automatic phase timing.
8. Add semantic output hashing and complete/partial result states.
9. Produce derived summaries through one analysis path.
10. Migrate repository-owned scripts/docs/tests and remove ambiguous flags.
11. Run one Stage 06 and one C-emission compiler profile on macOS and Linux.

## Tests

### Parser and validation

Cover every target/mode, option ordering, repeated selectors, `--` argument
boundary, invalid mode combinations, missing source, invalid compiler boundary,
and help examples.

### Bundle lifecycle

Using fake short-lived collector/target commands, cover:

- complete success;
- compiler build failure;
- target exit failure;
- sampler failure before and after target start;
- timeout and signal termination;
- output directory collision;
- disk/write failure;
- dirty and clean checkouts;
- stale compiler identity rejection;
- a plain subject supplied for calls or exact mode;
- a subject instrumented for a different mode or metadata ABI;
- conflicting subject and builder options;
- truncated machine profile; and
- cleanup with and without `--retain-generated-c`.

Every result must leave a readable manifest when the output directory was
successfully created.

### Compiler boundary

For `stage06`, `late-core`, and `c-emission`, assert the expected final phase
row and the absence of later work. Specifically, C-emission must produce a C
hash but no host-native compilation; Stage 06 must not run Core or emission.

### End-to-end

- Profile a tiny program in CPU, calls, and exact modes.
- Profile `blorp/src/main.brp` through Stage 06 and C emission.
- Compare target exit status and output hash with an unprofiled invocation.
- Parse every applicable artifact and validate manifest hashes.
- Confirm no `.c`, native binary, raw sample, or profile file appears in the
  repository working tree.

Actual native sampler tests may be capability-gated, but fake collector and
bundle tests are mandatory everywhere.

## Fast Feedback Loop

Develop the orchestration against fake collectors so each test completes in
well under a second. Then run CLI parser and integration owners:

```bash
bin/blorp test blorp/test/lib/test_cli_args.brp
bin/blorp test blorp/test/cli/test_main.brp
blorp/test/cli/test_cli.sh --smoke --timeout 30
```

Run one tiny real native sample before trying compiler self-compilation. Use the
Stage 06 compiler boundary for the first compiler smoke because it is faster
than complete C emission.

Before review:

```bash
make
scripts/test compiler-blorp runtime leak cli
make quality
```

Run one real macOS and one real Linux collection where infrastructure is
available, then retain only compact textual evidence, not raw samples, in the
change report.

## Acceptance Criteria

- [ ] `blorp profile compiler`, `profile run`, and `profile test` have clear,
      tested grammar.
- [ ] CPU sampling is the default mode; calls/exact are explicit.
- [ ] Compiler profiling uses a verified current compiler executable.
- [ ] Builder, measured subject, and compiled workload identities are distinct
      and recorded.
- [ ] Prebuilt calls/exact subjects must advertise the requested instrumentation
      mode and compatible metadata/runtime ABI.
- [ ] `--through=c-emission` does not invoke Clang/GCC on emitted program C.
- [ ] Compiler profiles automatically include phase timing.
- [ ] Every run creates a versioned manifest with command, build, host, mode,
      output, and completeness identity.
- [ ] Complete, target-failed, collector-failed, build-failed, and invalid
      configurations remain distinct.
- [ ] Raw and derived profile artifacts have recorded hashes.
- [ ] A one-command Stage 06 and C-emission profile works on supported hosts.
- [ ] Target output and exit behavior match the corresponding unprofiled run.
- [ ] Repository-owned uses of ambiguous `--profile` are migrated and the old
      public alias is removed.
- [ ] No generated artifact is left in the source tree by default.
- [ ] Help and `docs/DEVELOPMENT.md` teach the profiling ladder and show how to
      inspect the bundle.

## Pitfalls And Review Questions

- Is the command profiling the produced program when the target says compiler?
- Does C-emission mode accidentally include host C compilation?
- Can a stale `bin/blorp` pass without a matching source/binary identity?
- Is `--subject-compiler` actually treated as a builder, or can a normal
  uninstrumented subject silently produce an empty calls/exact profile?
- Are optimized sampled runs compared to debug exact runs without a label?
- Does a successful sampler hide a failed target exit?
- Can a manifest claim completeness before all writers flush?
- Are ambient secrets copied into the manifest?
- Do selector flags accidentally affect CPU sampling despite undefined
  semantics?
- Does cleanup use a broad or unresolved path?
- Was the old interface retained as permanent duplicated behavior?

This issue is complete when the recommended profiling workflow is easier than
the ad hoc scripts it replaces and makes the measurement boundary obvious from
the command itself.
