# Capture Reproducible Validation Evidence At Handoff

**Status:** Proposed

**Owner:** one opt-in validation recorder, `docs/DEVELOPMENT.md`, and the
existing structured test/benchmark outputs

**Current state:** Focused failures retain reruns; broad gates and benchmarks
can emit logs, but successful cross-command handoffs are assembled manually.
**Next action:** Test one opt-in recorder around fake success/failure commands,
then verify a real focused and broad packet without changing the runners.
**Read first:** `scripts/compiler-check` failure artifacts, `scripts/test`
structured gate output, and the existing benchmark JSON precedent.
**Fast loop:** The proposed `test_record_validation.py` with fake commands;
no broad gate while changing packet formatting.
**Decision:** Accept exact status/provenance with safe environment capture;
reject a wrapper that hides failures or adds mandatory daily ceremony.

## Objective

Let an agent hand a reviewer a compact, verifiable account of what was run,
against which source and binary, with the raw output retained. Cover positive
and negative optimization experiments. Do not require this recorder for every
tiny edit, and do not turn a green command exit into an unsupported performance
claim.

## Why

`scripts/compiler-check` already retains a selection and exact rerun for a
failure but removes successful temporary logs. `scripts/test` emits structured
gate results and can retain full logs with `--log-dir`. Benchmark scripts can
emit raw samples, but every handoff currently assembles revisions, command
lines, binary identity, semantic checks, and caveats differently. A reviewer
often has to ask which executable ran or whether the claimed fixture was
identical. The solution should preserve evidence once, close to execution.

## Proposed Minimal Recorder

A standalone, opt-in command can wrap one validation command and write a
versioned packet outside the repository by default:

```bash
# Proposed interface; it is not implemented yet.
scripts/record-validation --output /tmp/blorp-evidence/focused \
  -- scripts/compiler-check --changed --base origin/main

scripts/record-validation --output /tmp/blorp-evidence/default \
  -- scripts/test --no-build --log-dir /tmp/blorp-evidence/gate-logs

scripts/record-validation --output /tmp/blorp-evidence/consume-bench \
  -- benchmarks/compiler_consume_candidate_index_profile \
    plain 1 512 8 512 25 none --samples 7 --json
```

One packet should contain `metadata.json`, captured stdout/stderr or a combined
ordered log, and the wrapped command's exit status. The wrapper must return
that same status to the caller. It should print its output location and one
copyable rerun command; it must not turn a failure into success because it
managed to write a report.

Required metadata:

```json
{
  "schema_version": 1,
  "command": ["scripts/compiler-check", "--changed"],
  "cwd": "<absolute worktree path>",
  "started_at_utc": "<timestamp>",
  "elapsed_ms": 1234,
  "exit_code": 0,
  "git_head": "<full revision>",
  "git_dirty": true,
  "tracked_diff_sha256": "<digest or explicit unavailable>",
  "bin_blorp_sha256": "<digest or explicit absent>",
  "artifacts": ["stdout.log"]
}
```

Values in angle brackets are placeholders, not literal output. Add an exact
allowlist for individually named, known-safe environment values that affect a
run (for example `BLORP_COMPILER_TEST_TIMEOUT` and `CC`). Never include a whole
prefix such as `BLORP_*`: user-defined `BLORP_API_TOKEN`-style variables may
contain secrets. Redact or hash sensitive values rather than printing them.
The worktree fingerprint must account for relevant untracked source; a Git HEAD
alone is insufficient. If that cannot be captured safely, record `unknown`
and list the limitation rather than inventing a hash.

### Reviewer usage

```text
Change: pass-local candidate index; no source-language behavior change.
Focused: /tmp/blorp-evidence/focused (exit 0, selected 1 owner suite).
Broad: /tmp/blorp-evidence/default (all recorded gate results exit 0).
Performance: /tmp/blorp-evidence/consume-bench (7 pairs, Core hash equal).
Caveat: allocations rose 11.2%; 1,024-candidate stress remains open.
Decision requested: accept this bounded slice, not close the full issue.
```

This human summary is written by the agent or reviewer; the recorder must not
decide acceptance or infer causality from elapsed time. For a negative
experiment, the same packet should say "rejected" with the measurement,
without hiding that tests passed.

## Test-First Plan

Add focused tests under `blorp/test/build/` using fake success/failure
commands and temporary output directories. Before the recorder exists, prove
the documented invocation fails. Cover:

1. exact argument preservation including spaces and shell-special text;
2. stdout/stderr capture, process exit 0/nonzero/signal/timeout;
3. wrapped command status preserved even if report writing succeeds;
4. existing output directory refused unless explicit safe append/replace is
   specified; never recursively delete a user-provided directory;
5. packet format validation and hashes of captured artifacts;
6. dirty tracked and untracked source identities represented honestly;
7. missing binary and no-Git checkout recorded as unavailable, not an error
   that masks the wrapped command result;
8. environment allowlist excludes a fake `BLORP_API_TOKEN` secret despite its
   `BLORP_` prefix;
9. one real `scripts/compiler-check` and one real `scripts/test --log-dir`
   packet can be read by a reviewer without rerunning the commands.

The recorder should not parse arbitrary human output to declare "all tests
passed." If it summarizes `BLORP_GATE_RESULT`, validate its exact schema and
counts; otherwise leave the raw log authoritative.

## Fast Feedback Loop

```bash
python3 blorp/test/build/test_record_validation.py
scripts/record-validation --output /tmp/blorp-evidence-smoke \
  -- scripts/compiler-check --help
```

These paths are proposed. Use a tiny fake command for most iterations; do not
run a six-minute gate while changing JSON formatting. After the implementation
is stable, run one focused and one broad smoke with the real scripts, inspect
their metadata by hand, and obtain test-runner/code-reviewer review.

## Acceptance / Rejection

- [ ] A packet identifies exact command, source state, compiler binary, exit
      status, and raw output without requiring trust in a prose summary.
- [ ] It is opt-in and does not add latency to ordinary `scripts/test` use.
- [ ] Failures remain failures; rejected experiments remain documented.
- [ ] No secret environment dump or destructive output-directory behavior.
- [ ] Reviewer can reproduce the three example handoff commands from a clean
      checkout or see precisely why reproduction requires a dirty source tree.
- [ ] If the packet adds more ceremony than clarity for a one-command change,
      keep it optional and narrow its use to performance/release/integration.

## Non-Goals

- Automatically deciding whether an optimization is worth merging.
- Uploading logs or creating GitHub issues/PRs.
- A new test runner or a second structured gate format.
- Treating a binary hash as proof that its source matches the worktree; issue
  03 owns build freshness.
