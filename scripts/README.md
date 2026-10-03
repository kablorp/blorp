# Scripts

This directory contains the maintained shell entrypoints for local validation,
Docker validation, and release packaging. Prefer these scripts over calling
lower-level test runners directly.

## Test Gates

`scripts/test` is the main local test entrypoint.

For the shortest manifest-owned compiler feedback loop, use
`scripts/compiler-check`:

```bash
scripts/compiler-check blorp/test/compiler/pipeline/test_type_header_graph.brp
scripts/compiler-check --stage typecheck
scripts/compiler-check --changed
scripts/compiler-check --changed --base origin/main
scripts/compiler-check --changed --plan
scripts/compiler-check --validate-manifest
```

An exact suite path runs only that registered suite. Stage and changed-source
selection come from
`blorp/test/compiler/compiler_test_ownership.json`; the command does not infer
owners from names, imports, timings, or previous failures. `--changed` includes
staged, unstaged, and untracked production compiler sources, while `--base`
also includes committed changes from the merge base with the named ref.

Add `--plan` to print the selected production sources, focused suites, special
checks, exact focused commands, and manifest-owned broad-gate recommendations
without building, running tests, creating logs, or writing generated files. A
plan that selects nothing is a no-op explanation, not a passing validation; use
the task-specific build, docs, or release checks for those changes.

Sources under `blorp/src/compiler_new` and suites under
`blorp/test/compiler_new` (the discovery stage, which `bin/blorp` links through
its adapter) are outside this manifest: `--changed` selects nothing for
them and names their gate, `scripts/test compiler-new`.

The command prints the selected sources, suites, and special checks before it
prepares the compiler once. Suites then use `bin/blorp test`, and registered gate
checks use `scripts/test --no-build --log-dir`. Passing runs remove their
temporary logs. Failing runs retain complete output and an exact rerun under
the ignored `logs/compiler-check-*` tree. `scripts/compiler-check` is focused
feedback only; run the relevant broad `scripts/test` integration gates before
merging.

```bash
scripts/test                    # Blorp compiler, runtime, leak, doctest, CLI
scripts/test compiler-blorp     # Blorp TestSuites + marked production check fixtures
scripts/test compiler-tools     # formatter/purify/lint fixtures + backend/identity tool guards
scripts/test compiler-new       # rewritten compiler stages (blorp/src/compiler_new) TestSuites
scripts/test compiler-new-parity # discovery stage vs the existing front end over the corpus
scripts/test std-check          # broad standard-library source typecheck sweep
scripts/test runtime            # runtime .brp tests
scripts/test leak               # ownership suites, leak baselines, and diagnostics
scripts/test doctest            # standard-library doctests
scripts/test cli                # public CLI and LSP smoke tests
scripts/test cli-deep           # full CLI package and formatter integration tests
scripts/test lsp                # public LSP protocol fixtures
scripts/test package            # focused public package lifecycle integration
scripts/test compiler-blorp runtime  # multiple selected gates
```

Useful options:

```bash
scripts/test --serial           # run selected gates one at a time
scripts/test --verbose          # stream child-runner output
scripts/test --log-dir logs     # keep complete gate logs
scripts/test --no-build         # test the existing installed toolchain
scripts/test --timings          # print generated TestSuite phase timings
scripts/test --release-compiler # build bin/blorp at -O2 for full gate runs
scripts/test --release-artifacts # compile the test artifacts at -O2
```

`scripts/test` is quiet by default. Successful runs print a gate summary with
per-gate timing, total wall-clock time, and setup timing; failures print focused
excerpts and can save full logs with `--log-dir`.
The default gate exercises the production-owned compiler implementation through
`compiler-blorp`.
The `compiler-new` gate runs the TestSuites registered in
`blorp/test/compiler_new/compiler_new_test_ownership.json`, after checking that
every `test_*.brp` under `blorp/test/compiler_new` is registered and that its
tools and support modules type check. It is a default gate, part of the
premerge gate and of the compiler CI lane. The layout check keeps
`compiler_new` sources importing only `compiler_new` and `lib`. The production
`compiler/discovery_front_end.brp` and `compiler/discovery_adapter.brp` modules
are explicit temporary consumers (`temporary_cross_owner_imports` in
`blorp/source_ownership.json`). The isolated test tree imports only
`compiler_new`, `lib`, its own tree and the standard library
(`isolated_test_owners` in that manifest).
The `compiler-new-parity` gate (`scripts/compiler-new-parity`) holds the
discovery stage to the existing front end across every tracked `.brp` file
under `blorp/src`, `standard_library/src` and `blorp/test`: it compiles
`blorp/test/compiler/tools/legacy_front_end_dump.brp` and
`blorp/test/compiler_new/tools/corpus_dump.brp` once each, runs them
sequentially over the file list, and compares every token (kind, byte range,
text; the old `#` plus name is one `DimensionNameToken`), the set of files with
lexer diagnostics and each file's accept/reject verdict. A mismatch prints the
file and the first differing token. It also checks the stage's module graph
(`discovery_module_order_dump.brp`) for the self-compile root and for a
`blorp test` root: each must load at least the expected number of modules. The
same roots run with the standard library read from the compiler's embedded
texts, and fixture projects run with `blorp.toml` source packages and a native
package, each of which must contribute a module with its origin. Known
divergences are listed in the script with a reason: `KNOWN_DIVERGENCES` (today
the two interpolation cases the existing lexer reads wrongly),
`KNOWN_POSITION_DIVERGENCES` (parse diagnostics reported at a different
position) and `WORDING_DIFFERENCES` (diagnostic text the stage deliberately
words differently). An entry that stops disagreeing fails the gate until it is
removed. The gate
takes about 1-2 minutes (mostly the C compiler on the two dumpers), so it is not a
default gate; it is part of the premerge gate.
The `compiler-blorp` gate also runs every fixture explicitly marked
`RUN-BLORP-CHECK` through a small runner
(`blorp/test/lib/run_blorp_check_fixtures.py`) after the TestSuites have run;
`scripts/test` pins the expected fixture count (`expected_blorp_check_fixture_count`)
and passes it to the runner.
Runtime sources owned by the leak gate are excluded from the normal runtime corpus.
The remaining roots compile and run together in one runtime test invocation.
`--no-build` is for controlled CI or local workflows that have already run the
required build and need to preserve that exact toolchain through validation.
Without it, `scripts/test` installs the current compiler before running gates.
`--release-artifacts` passes `--release` to every `bin/blorp test` invocation,
so each generated test artifact is compiled at -O2 instead of the gating -O0
default. It does not change how `bin/blorp` itself is built.
`--release-compiler` exports `BLORP_CLI_C_OPTIMIZATION=-O2` for that install,
trading a slower build for a faster compiler in the gates that follow; see
"Compiler optimization level" in `docs/DEVELOPMENT.md` for the -O0/-O2 split
and the re-link cost of switching levels between runs.

Every gate entry point (`scripts/test`, `scripts/compiler-check`,
`scripts/premerge-gate`, `scripts/docker-gate`) prints exactly one machine-
readable verdict line as the last line of stdout:

```
BLORP_GATE_RESULT gate=<entrypoint> status=PASS|FAIL passed=N failed=N tests=N
```

`<entrypoint>` is the tool's own name (`test`, `compiler-check`, ...), and the
counts are the aggregate across every gate that ran, matching the human
"Total" row. Exit status always agrees with `status`. Automation should read
this line instead of grepping prose; it is the same `BLORP_GATE_RESULT`
format individual gates already emit for their own sub-results.

`scripts/test`, `scripts/premerge-gate` and `scripts/docker-gate`, when
interrupted (SIGTERM, SIGINT, SIGHUP) or aborted before they finish, print
`status=FAIL` and exit nonzero, immediately. Each marks itself finished as its
last statement and its EXIT trap reports FAIL otherwise; none traps a signal,
because bash holds a trapped signal until the foreground command (a
`docker run`, a gate) completes. `premerge-gate` reports FAIL unless its test
run ends with exactly one valid `gate=test` aggregate. `docker-gate` also
reports FAIL when a premerge or bare test run produced no nested verdict.
Before reporting FAIL,
each of the three stops its own child processes (not a process group), so an
interrupted run leaves nothing behind that could print a late verdict;
`docker-gate` starts its containers with `--init` so the forwarded TERM
stops the container too. `--help` prints no verdict, and neither does
`premerge-gate --dry-run` (a verdict would claim a validation that did not
run); a bad `scripts/test` flag prints FAIL.
`blorp/test/build/test_gate_interrupt_verdicts.sh` covers this.

## Validation Evidence Packets

Use `scripts/record-validation` when a reviewer needs a reproducible packet for
one focused check, broad gate, or benchmark. The recorder is opt-in and wraps
one command without changing its exit status:

```bash
scripts/record-validation --output /tmp/blorp-evidence/focused \
  -- scripts/compiler-check --changed
scripts/record-validation --output /tmp/blorp-evidence/gate \
  -- scripts/test --no-build --log-dir /tmp/blorp-gate-logs compiler-blorp
```

Each packet contains `metadata.json`, `stdout.log`, and `stderr.log`. Metadata
records the exact argv, cwd, UTC start time, elapsed milliseconds, exit code,
Git HEAD, start and end tracked/untracked worktree fingerprints, whether source
changed during the run, `bin/blorp` hash when present, captured artifact hashes,
and a small allowlist of known validation environment variables. If `--output`
is inside the Git worktree, that output directory is explicitly excluded from
source fingerprints. The recorder does not parse human output, decide that a
benchmark is acceptable, or dump arbitrary `BLORP_*` environment values.

Existing output directories are refused by default. `--replace` updates only a
previous `record-validation` packet with the same schema and refuses unrelated
files or subdirectories, so an accidental path cannot be recursively deleted.
Use `--timeout SECONDS` to terminate the wrapped process group and record exit
`124`.

The supported report-only typed analyzer is `blorp lint <file.brp|dir> [...]`.
Use `--format json` for the versioned machine-readable envelope and
`--fail-on-findings` when findings should fail CI. See
[`docs/LINT.md`](../docs/LINT.md) for rule IDs, confidence, and failure behavior.

The compiler-owned suites compile and run as one generated program. CI sets
`BLORP_COMPILER_TEST_PROGRESS=1` to stream artifact start, source, result, and
elapsed-time records while preserving the compact final gate output. Reproduce
the CI compiler gate against an already-built toolchain with:

```bash
BLORP_COMPILER_TEST_PROGRESS=1 \
scripts/test --no-build --serial compiler-blorp
```

Use `--timings` with `compiler-blorp` or `compiler-blorp-sanitize` to record
generated TestSuite frontend, typecheck, Core, host-C, and execution phases and
print their totals.
After setup, multiple selected gates run in fixed waves by default:

```text
compiler-blorp
compiler-tools
compiler-core-sanitize
compiler-blorp-sanitize
compiler-new
compiler-new-parity
std-check
runtime
leak + doctest + cli + lsp
package
cli-deep
```

Waves skip gates you did not select. The policy is intentionally static: the
heavy gates already do their own internal work scheduling, and a shell-level
resource scheduler would be harder to reason about than the tests it runs. Use
`--serial` when you need one gate at a time.

CI builds one compiler candidate per platform and restores those exact bytes in
independent test jobs. Ubuntu separates quality, Blorp-owned compiler, and
product/runtime coverage; platform jobs retain the smaller runtime
compatibility set. Each platform build gates only that platform's test lanes, so
a failed or slow platform does not suppress unrelated feedback. Packaging waits
for the matching platform lanes, then archives the shared candidate rather than
rebuilding it; the release workflow still publishes only from a wholly
successful CI run. The candidate carries generated CLI outputs and both embedded
standard-library sources so fresh test checkouts use the build job's exact
generated inputs.

Timeouts:

- `BLORP_TEST_TIMEOUT` overrides generated test artifact timeouts.
- `BLORP_RUNTIME_TEST_TIMEOUT` overrides only the single runtime corpus
  artifact, which defaults to 60 seconds. Ordinary artifacts default to 30
  seconds.
- `BLORP_LEAK_TEST_TIMEOUT` overrides only the consolidated leak-check corpus,
  which also defaults to 60 seconds. That value is a floor per suite batch:
  `bin/blorp test --leak-check` grants each batch the larger of the floor and
  5 seconds (`LEAK_CHECKED_SOURCE_TIMEOUT_SECONDS` in
  `blorp/src/test/plan.brp`) times the number of test sources in it, so a
  large batch on a loaded host does not time out while a hung test still fails
  in bounded time. A timeout failure lists every test source in the batch.
- `BLORP_COMPILER_TEST_TIMEOUT` overrides only compiler-test invocations. The
  grouped compiler-owned Blorp suites default to 360 seconds; individual
  compiler fixtures and codegen audits default to 30 seconds.
- `BLORP_COMPILER_SANITIZE_TEST_TIMEOUT` sets the compiler sanitizer-gate
  timeout (default 180 seconds, reflecting measured ASan overhead).
## Premerge Gate

`scripts/premerge-gate` is the broader local validation gate before merging or
cutting preview builds. It composes:

- clean build at `-O2` (`BLORP_CLI_C_OPTIMIZATION=-O2`; use `--no-release-compiler` for `-O0`)
- `make quality`
- `scripts/test --serial --release-compiler compiler-blorp compiler-tools std-check runtime leak doctest cli-deep lsp compiler-new compiler-new-parity`
- the direct generated-C audit in `blorp/test/compiler/pipeline/codegen_audit/`
- preview CLI/runtime smoke
- example checks and selected example runs
- sanitizer tests
- Docker validation when Docker is available
- lightweight secret-pattern scan
- drift and hygiene checks, including editor TextMate metadata sync

Common forms:

```bash
scripts/premerge-gate
scripts/premerge-gate --quick
scripts/premerge-gate --no-docker --no-sanitize
scripts/premerge-gate --require-docker
scripts/premerge-gate --dry-run
```

Use `--quick` for fast local confidence. Use the full default gate before
claiming a preview/release-sensitive change is ready.

The preview smoke step is guarded as non-mutating: it snapshots Git status plus
tracked and staged diffs before and after the step, and fails if validation
rewrites the working tree.

## Docker Gate

`scripts/docker-gate` runs validation inside an Ubuntu 24.04 container. Like
`scripts/premerge-gate`, it builds `bin/blorp` at `-O2` by default.

```bash
scripts/docker-gate
scripts/docker-gate --premerge-gate
scripts/docker-gate --premerge-gate --all-platforms
scripts/docker-gate --platform linux/arm64 -- blorp/test/runtime/numeric/test_float16_vector.brp
scripts/docker-gate --shell
```

Modes:

- Default volume mode mounts the working tree into the container.
- `--clean` copies source into the image for a more CI-like run.
- `--premerge-gate` runs `scripts/premerge-gate --no-docker` inside Docker.
- Each gate builds the compiler inside its container, which peaks at several
  GB, so `scripts/docker-gate` limits both how many gates run and how hard each
  builds:
  - A gate holds one of `BLORP_DOCKER_GATE_MAX_CONCURRENT` (default 3) slots
    for the length of its `docker run`; later gates wait in a queue and are
    served in arrival order. Slots and queue tickets are directories made with
    `mkdir` (atomic, so simultaneous gates cannot both take the last slot)
    under `BLORP_DOCKER_GATE_SLOT_DIR` (default
    `${TMPDIR:-/tmp}/blorp-docker-gate-slots`), shared by every checkout that
    sees the same directory. Each has an owner file with the holder's pid and
    start time; a slot left by a killed gate is reclaimed, and an interrupted
    gate frees its slot on the way out. A `--clean` run holds its slot for the
    image build (the memory-heavy `make`) as well as the container run. A
    gate killed with SIGKILL leaves its slot to be reclaimed, and its
    `docker run` container keeps running until it ends. A cap of 0 never
    admits a gate; lowering the cap lets gates already holding a higher slot
    finish, so briefly more than the new cap may run.
  - Only gates running a `docker-gate` that has this mechanism are counted.
    Containers started by an older copy (a branch that has not merged `main`)
    cannot be governed, so merge `main` into a branch to get the limit. A
    different `TMPDIR` is a different pool; set `BLORP_DOCKER_GATE_SLOT_DIR`
    to share one.
  - The build's parallel `clang` jobs (`BLORP_CLI_C_SPLIT_JOBS`) default to the
    Docker VM's CPU count divided by the slot count, at least 2; set
    `BLORP_DOCKER_GATE_BUILD_JOBS` to override. Fewer jobs lower a gate's peak
    memory at some cost in build time.

## Landing a Branch

Validate a branch first with the CI-equivalent gate, the same checks CI runs on
Ubuntu x64: from the branch's checkout or worktree run
`scripts/docker-gate --premerge-gate -- --no-sanitize` (a clean -O2 build,
`make quality` and the full `scripts/test` in an Ubuntu container). Gates on
different branches may run in parallel. Then land it:

```bash
scripts/land <branch> --title "<title>" [--body "<text>"] \
    [--record <file> --record-name <name>] [--dry-run]
```

`scripts/land` merges `origin/main` into the branch, in the branch's own
worktree if it is checked out somewhere (that worktree must be clean) and in a
temporary worktree otherwise; a merge conflict stops it, to be resolved on the
branch. It then squash-merges the branch onto `origin/main` as one commit with
the given title and body in a temporary detached worktree, optionally copies a
measurement file into `benchmarks/results/<name>`, and pushes that commit to
`origin main`. If `main` moved before the push, it merges again and retries;
any other push failure stops it. The caller's checkout is never touched, and
it runs no gates. Titles starting with `Merge` or containing an `#<digits>`
issue reference are refused so main's history stays standalone and readable.
`--dry-run` stops after the squash commit and prints its SHA; the branch still
gets the merge from `origin/main`.

## Identifying A Binary

`bin/blorp --version` is the single source of truth for what a given binary
is: commit (plus `-dirty` for uncommitted tracked changes), target triple,
`compiled_by` (the bootstrap tag, or `self-<commit>` for a stage-2 binary
built by `bin/blorp` itself — see `benchmarks/build_stage2_compiler`),
`optimization` (`cli=` and `runtime=` flags actually used), `split` (the
translation-unit count), and `cc` (the first line of `$BLORP_CC --version`,
default Clang). These
values are stamped in at compile time from a small, always-freshly-rebuilt
object (`blorp/src/lib/runtime/native/build_stamp.c`), not embedded into the
generated compiler C, so a new commit relinks the binary instead of forcing a
full recompile.

`scripts/compiler-build-status` reads this block from the built binary — not
ambient environment variables — to decide FRESH/STALE, so its verdict matches
how the binary on disk was actually built regardless of the current shell's
environment. It also flags `STALE` with reason "bootstrap pin changed" when
`blorp/build/bootstrap.env`'s tag no longer matches a `dev-` `compiled_by`,
and prints the version block after a `FRESH` verdict.

## Build Source Generation

`make compiler-build-source-generator` compiles
`blorp/tool/generate_build_sources.brp` with the pinned bootstrap compiler.
The resulting native tool generates build metadata, embedded runtime C, and the
embedded standard library. Production build and CI routes use this tool directly.

`scripts/split-generated-c <generated.c> <out_dir> -n N` splits the compiler's single
generated C file into a shared header and N body translation units that the Makefile
compiles in parallel (`BLORP_CLI_C_SPLIT`). It post-processes the C file and does not
touch the emitter.

`scripts/blorp-cli-embedded-manifest` records what an installed `bin/blorp` was built
from. `write-inputs` hashes the paths listed on stdin into a sorted input manifest,
`write-installed` prefixes that manifest with the compiler binary's SHA-256, and
`verify-installed` reports whether the installed compiler still matches. The Makefile
uses it to decide whether to reinstall `bin/blorp`.

## Build Lock

`scripts/with-build-lock` serializes build/test gates per worktree. `scripts/test`
and `scripts/premerge-gate` use it automatically so concurrent local runs do not
race on generated runtime caches or std embedding. The wrapper also
holds the shared canonical per-user host compiler contention lease. On hosts
without the `flock` utility, the build lock uses Python 3 and a POSIX file
lock held by the command, so termination releases it automatically. Registered
`scripts/bench-blorp-test-session` evidence takes the exclusive side and rejects
a run while any participating build/test gate for that user is active. The
owner-only lease namespace rejects symlinks and foreign ownership before a gate
or benchmark starts.
`scripts/with-compiler-contention-lease --mode shared|exclusive --policy <file> -- <command>`
runs a command while holding that lease; the policy file names the lease. With
`--nonblocking` it fails instead of waiting when the lease is held.
`scripts/with-build-lock` calls it for the shared side.
Named runs selected with `--workload` use the same exclusive lease. The
registered workload kind requires a candidate for comparisons and forbids one
for characterizations; both validate their command and cache policy, while
characterizations also validate sample count, timeout, and fingerprint inputs.

Manual use:

```bash
scripts/with-build-lock make quality
```

## Blorp Test Session Feedback

Use the direct command for the boundary being changed. Planner TestSuites cover
path discovery, the shared frontend graph, and generated aggregate harnesses. A
typecheck covers the shared execution boundary, and the rebuilt-compiler test exercises
the production CLI route:

```bash
bin/blorp test --timeout 30 \
  blorp/test/test/test_discovery.brp \
  blorp/test/test/test_generated_test_harness.brp \
  blorp/test/lib/test_source_graph_context.brp \
  blorp/test/test/test_plan.brp
bin/blorp check --no-format \
  blorp/src/test/effect.brp
blorp/test/cli/test_rebuilt_cli.sh --timeout 90
```

Run `bin/blorp test --timeout 30 blorp/test/runtime/sys/test_process_session.brp`
for the session API; CLI smoke separately covers inherited stdin, stdout, and
stderr for blocking commands. Use `scripts/bench-blorp-test-session` for
repeatable timing or RSS evidence; its process supervisor and registered
workloads are the single benchmark path.

## Compiler Bootstrap

`make install` invokes the pinned release's public `blorp compile` command
directly to build the current compiler. Bootstrap builds do not rewrite source
trees or prepare an intermediate compiler. The compiler is a single
executable; tests, packages, the LSP, and releases do not prepare or install
private workers.

Local compiler builds compile generated compiler C at `-O0` by default for the
shortest edit/build cycle. The separately cached runtime object uses `-O2` and
is shared by fast and release compiler builds; set
`BLORP_CLI_RUNTIME_C_OPTIMIZATION` only when debugging the runtime itself. Set
`BLORP_CLI_C_OPTIMIZATION` to select the generated compiler C optimization
level. Main CI and tagged release builds use `-O2` for both. Both selected
levels participate in their respective cache identities. `make
generate-blorp-cli-c` runs the self-hosted source-to-C phase, and `make
prepare-blorp-cli-runtime` prepares the content-addressed runtime object. CI
uses `make prepare-blorp-cli-c` to produce all C inputs, `make
compile-prepared-blorp-cli` to invoke only the host C toolchain, and `make
install-prepared-blorp-cli` to publish the result. Local `make install` still
composes all phases safely.

Normal builds use `scripts/blorp-compiler-bootstrap`, which reads the immutable
release identity and per-target checksums from
`blorp/build/bootstrap.env`, then downloads and verifies the release into
`$HOME/.cache/blorp/compiler-bootstrap`, or `BLORP_COMPILER_BOOTSTRAP_CACHE_DIR`
when set. Rotate the tag, version, and all target checksums together in that
single manifest only after release CI has published the merged revision.
The current pin uses the `direct` binary layout. The resolver still accepts
historical `single`-archive manifests, but normal builds do not exercise that
compatibility branch; retiring it is a separate manifest-format cleanup. Both
layouts cache only `blorp` and remain isolated from the retired
multi-executable distribution.

Useful compiler bootstrap commands:

```bash
scripts/blorp-compiler-bootstrap --print-id
scripts/blorp-compiler-bootstrap --print-tag
scripts/blorp-compiler-bootstrap --print-path
scripts/blorp-compiler-bootstrap --print-toolchain-dir
```

## Compiler Fixpoint

`bin/blorp` is built from C the pinned bootstrap emitted, so a change to Core
or the backend reaches the compiler's own code only in a later stage.
`scripts/compiler-fixpoint` builds those stages with
`benchmarks/build_stage2_compiler`: stage 1 (`bin/blorp`) emits the compiler's
C and stage 2 is built from it, stage 2 emits it again and stage 3 is built
from that, and stage 3 emits it a third time. Stage 2 and stage 3 must emit
byte-identical C; a difference means the compiler miscompiled itself, and the
script prints the first differing line. It also reports whether stage 1's
output matches, as information: stage 1 was compiled by the bootstrap.

Run it for every change that alters emitted C, before a bootstrap rotation
picks the change up. It needs a `FRESH` `bin/blorp`, builds each stage at the
optimization level `BLORP_CLI_C_OPTIMIZATION` selects, and keeps the stages
and their C in `blorp/build/_build/fixpoint/` (or `--work-dir`). Exit status
is 0 at a fixpoint, 1 when stage 2 and stage 3 differ, and 2 when a stage
could not be built.

```bash
scripts/compiler-fixpoint
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-fixpoint --work-dir /tmp/blorp-fixpoint
```

## Compiler Source Cleanup Audit

`scripts/audit-compiler-blorp-dead-code` builds a conservative whole-compiler
module and declaration reachability inventory. It also reports whole unused
import entries, globally unread field names, unused variants, and Blorp
environment controls with no tracked reference outside compiler source.

```bash
scripts/audit-compiler-blorp-dead-code
scripts/audit-compiler-blorp-dead-code --json
scripts/audit-compiler-blorp-dead-code --module-identity-graph-json
scripts/audit-compiler-blorp-dead-code --module-identity-graph-dot
```

Findings require owner review before deletion; the script intentionally does
not fail the quality gate merely because cleanup remains queued. Track accepted
cleanup work in `docs/issues/` rather than copying point-in-time counts into a
maintained document.

### Compiler identity migration census

`scripts/compiler-identity-census` emits a deterministic identity migration
inventory from compiler stages 6, 8, 9, and 10:

```bash
scripts/compiler-identity-census --json > /tmp/identity-census.json
scripts/compiler-identity-census --check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest blorp.test.build.test_compiler_identity_census
```

The checked-in JSON baseline caps each category, family, and directory. The
`--check` command rejects an increase and a new unlisted C naming boundary at
its source location. `--write-baseline PATH` writes an explicit candidate for a
reviewed migration cut; new boundaries carry `REVIEW_REQUIRED` metadata and
cannot pass `--check` until their rationale, owner, and oracle are filled in.
JSON and text use the same sorted
rows. Exact source shapes are separate from heuristic candidates: member reads,
sparse `Option` fields, and index builders are triage inventory, not confirmed
semantic uses. `unsupported_static` rows name the dynamic or typed oracle needed
for classes that this source scan cannot prove.
Pending-constructor keys include the containing brace expression and its ordinal
among balanced brace expressions in the same scope. Blank lines, comments, and
unrelated statements without braces leave these keys stable; inserting a brace
expression before a site may require an explicit baseline review.

### Compiler anti-pattern census

`scripts/audit-compiler-antipatterns` inventories a small set of recurring
source shapes that are useful during compiler cleanup:

```bash
scripts/audit-compiler-antipatterns
scripts/audit-compiler-antipatterns --json > /tmp/blorp-antipatterns.json
scripts/audit-compiler-antipatterns --rule threaded-state-record --json
scripts/audit-compiler-antipatterns --large-file-lines 8000
```

The census reports string-keyed dictionaries, index builders, large threaded
records, records whose optional fields and booleans may encode illegal states,
small tuple returns, managed parameters returned unchanged from an update-like
conditional, struct container placements whose final layout and hot read sites
need inspection, and large source files. The complete unfiltered counts remain in
JSON when `--rule` selects a review slice, so two revisions can be compared
without accidentally changing the census boundary.

These are review candidates, not lint failures or performance conclusions.
JSON `confidence` describes confidence that the syntactic shape matched, not
confidence that the code should be refactored.
For example, `Dict[String, ...]` is correct before an identity has been
resolved, a boolean can represent an independent fact, and a struct placement
can remain inline. Confirm hotness and representation before changing source.
Use allocation/instruction counters for an ownership claim, generated C for a
layout or backend claim, and exact output identity for every performance
experiment. Run before/after censuses with the same options and source scope.

The module-identity graph modes isolate functions whose signatures or bodies
directly carry `ResolvedModuleIdentity`, `ModuleIdentity`, `FrontendModuleId`,
`ModuleId`, explicit `module_path`/`module_name` String bindings or fields, or a
String-bearing function whose name contains an exact `_module_path`/
`_module_name` token. They then walk callers transitively.
JSON output is intended for mechanical migration inventories: every node has a
deterministic module/function key, source location, direct-fact categories, and its
shortest caller distance from a direct fact. DOT output renders the same node
and edge set with direct handlers boxed.

This is a conservative source dependency graph, not a typechecked call graph.
An edge means the caller references a locally or explicitly imported compiler
function according to the audit's import/name resolver; callbacks and other
value references can therefore appear as calls, while unresolved dynamic or
ambiguous references are absent. Use the graph to select and sequence a bounded
migration, then prove each edit through compiler behavior and allocation tests.

## Drift Checks

`scripts/check-editor-drift` verifies that shared VSCode and IntelliJ TextMate
metadata stay byte-for-byte synchronized, parse as JSON, and keep the IntelliJ
plugin's required editor integration registrations in place. `make
hygiene-check` runs it automatically.

`make hygiene-check` is the seconds-long static set (layout, editor drift,
C-symbol boundary, manifest, std builtins, magic spellings). `make tooling-check` holds the stage-2 self-compile C-symbol
leak check (`scripts/check-c-symbol-projection-self-compile`) and the
Python/shell suites that test the scripts, build, runtime harnesses and
audits. `make benchmark-tooling-check` holds the benchmark-worker `check` runs
and the suites that test the benchmark and measurement scripts; they protect
those scripts rather than the compiler. `make quality` runs all three, then
`artifact-scan` for stray generated files the suites left behind;
`scripts/premerge-gate` runs them too, and so does CI's Quality lane.

`scripts/check-blorp-layout` validates `blorp/source_ownership.json` against
`blorp/src` and `blorp/test`: owner roots, which owners may import which (including
the listed temporary cross-owner imports), the isolated `compiler_new` test tree,
forbidden top-level paths, and that test modules mirror the source layout and are
named `test_*`. `make hygiene-check` runs it.

`scripts/check-c-symbol-projection-boundary` fails when a `.brp` file other than the
backend emitter and its renderer test uses the unprojected C emission APIs
(`*_unprojected_*_for_tests`), so emitted C always goes through symbol projection.
`make hygiene-check` runs it.

`scripts/check-c-symbol-projection-self-compile` compiles `blorp/src/main.brp` with the
built `bin/blorp` (a stage-2 self-compile) and fails if the emitted C still spells a
type by its pre-projection qualified name (its `_make(` and `_destroy` functions, its
`typedef struct`, a pointer cast to it, or a `blorp_StackOption_` payload built from
it). It needs a built `bin/blorp`. `make tooling-check` runs it.

`scripts/check-magic-spellings` fails when a reader or producer of a name's
prefix, suffix or embedded number (`starts_with`, `parse_int`, `__mono_`
concatenation and the named accessors) appears that is not in
`scripts/check-magic-spellings.allowlist`. `--report` prints per-family counts
and `--update` regenerates the allowlist after a deletion; the families and
their replacements are in
`benchmarks/results/magic_spelling_census_2026-09-28.md`. `make hygiene-check`
runs it.

`scripts/check-std-builtins` verifies that standalone standard-library function builtin
bodies use explicit identities matching their source declaration, for example
`builtin("list.__unsafe_list_set_index")`. Bare `builtin` function bodies are not
allowed in `standard_library/src/`. It also requires every non-resource builtin type declaration
to have exactly one scalar, managed-reference, or no-value storage
classification in the compiler language-surface manifest.

## Optional Native TLS Check

`scripts/test-tls-openssl-local` is a manual integration check for the opt-in
OpenSSL TLS runtime backend. It creates a local self-signed TLS endpoint and
runs a Blorp TLS client against it with `BLORP_TLS_BACKEND=openssl`. It is not
part of the default gate because it requires host OpenSSL headers/libraries and
the `openssl` command-line tool.


## Release Helpers

`scripts/target-triple` prints the release target for the current machine:

```bash
scripts/target-triple
```

Supported targets:

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `aarch64-apple-darwin`
- `x86_64-apple-darwin`

`scripts/package-release` copies the public `bin/blorp` command to the target-
qualified release asset `blorp-<target>`. That binary can also become the
immutable compiler when the release is later pinned as the bootstrap:

```bash
scripts/package-release dist
```

Useful environment variables:

- `BLORP_RELEASE_BINARY` selects the binary to package.
- `BLORP_RELEASE_TARGET` overrides the target triple in the asset name.

`scripts/install-dev` downloads, validates, stages, and atomically installs that
executable. It removes private compiler helpers left by older releases.

On main, CI builds the compiler once with its final dev release metadata,
checks the self-hosted source graph, runs the normal test gates, smokes the
target-qualified binary, and uploads it as a workflow artifact. The dev release
workflow downloads and publishes those exact bytes
instead of compiling the compiler again. Explicit `v*` tags still build
independently because the tagged version embedded in the executable differs from
the dev version tested on main.

`scripts/install-dev` installs the latest moving `dev` release:

```bash
curl -fsSL https://raw.githubusercontent.com/kablorp/blorp/main/scripts/install-dev | bash
```

It downloads the matching `blorp-<target>` executable and installs it as
`$HOME/.local/bin/blorp` by default. `blorp` remains the only public command.
Invalid executables are rejected before installation.
The installer temporarily accepts the previous archive format so installing
does not break while the moving `dev` release transitions to direct binaries.

Useful options/environment:

```bash
scripts/install-dev --print-url
scripts/install-dev --install-dir "$HOME/bin"
BLORP_INSTALL_DIR="$HOME/bin" scripts/install-dev
```

Remove the dev binary with:

```bash
rm -f "$HOME/.local/bin/blorp"
```
