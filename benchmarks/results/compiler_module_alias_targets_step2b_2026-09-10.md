# Compiler Module Alias Targets Step 2b

Date: 2026-09-10

## Decision

Accept the Step 2b implementation. Graph-bound qualified aliases now retain
`ModuleId`, not canonical module-path strings, in the ordered alias table,
exact alias index, and import-binding stream. Qualified header joins and CTFE
consume those IDs directly. Parent and candidate semantic fingerprints match.
The standalone binding guard improves allocations, retained memory, and retired
instructions, while graph construction remains bounded. The only threshold
crossing is 1.0149% growth in the specialized standalone worker; the full
compiler grows 0.0973%, and the worker's absolute 17,888-byte increase is
accepted alongside materially better managed-memory counters.

## Measurement Contract

The parent is commit `74e9c504`; the candidate is the Step 2b worktree
immediately before this result is committed. Each worker was built by its own
compiler and run directly under macOS `/usr/bin/time -lp`. Setup remained
outside the managed allocation window.

One pair per affected mode was sufficient:

```bash
compiler-module-binding-profile 10 64 16
compiler-typecheck-phase-profile bound 1 32 4 16 16 memory
```

The standalone shape registers 64 aliases and 64 selective names per iteration,
then verifies exact alias/name lookup. The graph shape creates 32 dependency
modules, requests alias fan-out up to 16, and retains 408 total alias rows. Its
fingerprint includes each local alias spelling and projects its `ModuleId`
through the owning prepared scope's `ModuleTable`. The raw values, commands,
artifact hashes, and compiler hashes are in
`compiler_module_alias_targets_step2b_2026-09-10.tsv`.

## Standalone Binding Results

| Metric | Parent | Candidate | Change |
| --- | ---: | ---: | ---: |
| managed allocations | 45,525 | 44,245 | -2.8116% |
| managed releases | 44,045 | 42,830 | -2.7585% |
| retained objects | 1,480 | 1,415 | -4.3919% |
| retained bytes | 101,648 | 97,000 | -4.5726% |
| retired instructions | 254,377,890 | 252,513,118 | -0.7331% |
| cycles elapsed | 63,850,278 | 62,511,087 | -2.0974% |
| maximum RSS | 4,276,224 | 4,243,456 | -0.7663% |
| peak footprint | 2,720,032 | 2,703,648 | -0.6023% |
| worker bytes | 1,762,528 | 1,780,416 | +1.0149% |

The checksum remained `126080`; alias, selective-name, binding, error, and
deterministic pressure counters were identical. The retained exact dictionary
keeps registration and lookup constant-time, while deleting the old ordered
standalone alias duplicate produces the memory reduction.

## Graph Binding Results

| Metric | Parent | Candidate | Change |
| --- | ---: | ---: | ---: |
| managed allocations | 101,648 | 101,648 | 0.0000% |
| managed releases | 100,500 | 100,500 | 0.0000% |
| retained objects | 1,148 | 1,148 | 0.0000% |
| retained bytes | 93,616 | 93,880 | +0.2820% |
| retired instructions | 5,133,965,750 | 5,144,409,940 | +0.2034% |
| cycles elapsed | 1,262,642,741 | 1,255,608,952 | -0.5571% |
| maximum RSS | 24,215,552 | 24,346,624 | +0.5413% |
| peak footprint | 18,186,528 | 18,252,112 | +0.3606% |
| profiled worker bytes | 9,333,792 | 9,385,648 | +0.5556% |
| full compiler bytes | 19,245,408 | 19,264,128 | +0.0973% |

The semantic checksum remained `120388240154574545`; the constructor lookup
checksum remained `4522423758094903886`. Output counts and deterministic work
counters were identical.

An intermediate implementation retained a heap target record per alias and
added exactly 408 retained objects and 13,056 retained bytes; it was rejected.
The next version removed the retained record but still allocated 408 transient
targets. The accepted representation folds table provenance and `ModuleId` into
the already-allocated graph `ImportableModuleSurface` row, stores the retained
alias as an inline `ModuleAliasBinding`, and keeps standalone paths only in the
exact dictionary and ordered import-binding stream. This restores graph
allocations, releases, and retained objects exactly to the parent values while
the standalone path improves its exact managed-memory counters.

## Timing And Memory Guards

Graph one-shot wall time moved from 0.32 to 0.31 seconds and its instrumented
window from 24,116 to 24,967 microseconds. Standalone wall time rounded to 0.01
seconds for both, while its window moved from 5,288 to 4,914 microseconds. These
short samples support no latency claim. Exact managed counters and retired
instructions are the stronger signals here.

The bound-stage window measures construction, not the later qualified-header
or CTFE consumers. Their removal of canonical-path lookup is established by
structural tests and implementation inspection; it is not used to explain the
single-pair retired-instruction result.

## Feedback-Loop Consequence

The useful loop was one failing declaration-binding test, one alias-heavy
parent/candidate pair, and the exact allocation counters. The first measurement
immediately exposed the per-row retained record and then the transient target
allocation. Review then exposed a standalone linear-scan hazard; one exact
dictionary fixed it, and the existing standalone benchmark verified the result
without a new harness. More timing pairs would not have changed the decision.
Future Step 2 packets should keep this shape: structural red/green tests, one
pair per affected mode, then the changed gate and independent review.
