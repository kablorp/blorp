# Discovery redesign M2 current stage cost, 2026-10-03

This records the adopted pure lexer and its temporary bridge against the
integration HEAD. It supplements the current [record construction and token
storage probes](discovery_redesign_record_shapes_2026-10-03.md); the
[original M2 report](discovery_redesign_m2_2026-10-02.md) is historical.

## Provenance and boundary

- Baseline and workload revision: `02c0786a609f6ef7b65f5fd6eba243af8fbd66bf`.
- Candidate: all tracked and untracked, nonignored working-tree files frozen
  before this report was written. No production source changed for measurement.
- Source manifests (per-file SHA-256 and bytes, before generated support):
  - `baseline-manifest.json`: 4195 files, manifest SHA-256
    `31e63e790c6f424d097d58f8a1cba9d16cb510a3e9020d821808a4972bfa85b3`.
  - `candidate-manifest.json`: 4242 files, manifest SHA-256
    `f1eb1fc95db8e4f3c0c6b8505292efb503aca6715697b397f1adfa156a293541`.
  - `input-manifest.json`: 4195 files, manifest SHA-256
    `31e63e790c6f424d097d58f8a1cba9d16cb510a3e9020d821808a4972bfa85b3`.
- Same absolute FRESH generator for both snapshots:
  `/Users/keithphilpott/.codex/worktrees/9a08/blorp/bin/blorp`, SHA-256
  `3e715bd46236b53dbeab871d5cee6995db842cac18f8a5c8ff5b04179af61080`. Its version is
  `02c0786a609f-dirty`, bootstrap `dev-8228a8fa12e3`, CLI `-O0`, runtime
  `-O2`, eight C translation units. Freshness and hash checked before and after.
- Apple clang 21.0.0 (`clang-2100.3.34.2`), `-O2 -fwrapv -w -lm -lpthread`.
  Both use the same frozen HEAD runtime and foreign-header include directories.
  Plain builds supply instructions/RSS; separate
  `-DBLORP_MEMORY_DIAGNOSTICS=1` builds supply managed counters with
  `BLORP_MEMORY_STATS=1`.
- Git archives omit ignored `embedded_std.brp`. The repository build-source
  generator produced it from the frozen HEAD standard library, identically for
  both source snapshots and the input. Support SHA-256:
  `f53975ef5125c2d222048e1519a5aa6993e4a572921326538d0802f8da76eaba`.
  Its generator hash and exact command are in `metadata.json`. No harness API
  adaptation was needed.
- Snapshot files were made read-only. Per-file hashes and the generated support
  hash were verified before and after all runs.
- Tool: `blorp/test/compiler/tools/discovery_adapter_cost.brp`, compiled once
  per snapshot by the same generator. `tables` runs discovery, parsing, freeze
  and invariant checks; `graph` also runs `legacy_frontend_graph`. Both read
  the same frozen HEAD root `blorp/src/main.brp`, on-disk standard library and
  native packages, with the compiler implicit modules.
- Each plain and diagnostic variant was warmed once per mode. Five paired
  rounds alternate baseline/candidate then candidate/baseline, one process at
  a time, under `benchmarks/self_compile_measure lock --`. No wall-time claim.

## Results

All runs found **452 modules**. Managed allocations and releases were identical
across all five samples of each mode/variant. Every measured stage allocation
was released before its counter snapshot. Instructions and RSS below use the
minimum of five plain samples.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations, `tables` | 582,914 | 1,720,273 | +1,137,359 (+195.12%) |
| Releases, `tables` | 582,914 | 1,720,273 | +1,137,359 (+195.12%) |
| Retired instructions, minimum, `tables` | 4,304,331,468 | 6,834,468,260 | +2,530,136,792 (+58.78%) |
| Peak RSS bytes, minimum, `tables` | 130,170,880 | 137,330,688 | +7,159,808 (+5.50%) |
| Allocations, `graph` | 7,667,494 | 8,804,853 | +1,137,359 (+14.83%) |
| Releases, `graph` | 7,667,494 | 8,804,853 | +1,137,359 (+14.83%) |
| Retired instructions, minimum, `graph` | 9,366,645,766 | 11,885,953,084 | +2,519,307,318 (+26.90%) |
| Peak RSS bytes, minimum, `graph` | 325,419,008 | 331,186,176 | +5,767,168 (+1.77%) |

Instruction samples in round order:

- `tables` baseline: 4,304,331,468, 4,408,145,709, 4,317,196,418, 4,324,134,640, 4,310,786,130.
- `tables` candidate: 6,845,195,422, 6,834,468,260, 6,841,775,767, 6,845,052,604, 6,863,492,415.
- `graph` baseline: 9,366,645,766, 9,380,808,951, 9,387,500,529, 9,414,114,730, 9,395,592,229.
- `graph` candidate: 11,885,953,084, 11,976,424,738, 11,908,968,905, 11,934,263,094, 11,904,113,210.

The allocation increment is exactly **1,137,359** in both modes. The graph
adapter adds the same **7,084,580** allocations in either variant. This supports
a discovery-stage attribution for the increment; it does not isolate pure
lexing from bridge work, parsing, freeze or invariant checks. The token-storage
probe has a different retention window and is not subtracted from these totals.

## Output identity and interpretation

Each snapshot also built its own
`blorp/test/compiler_new/tools/discovery_dump.brp`. Its complete plain `tables`
stdout matches byte-for-byte: **892,955 bytes**, SHA-256
`d31ed983d7c0b36a68fb805c34c1b8ebf006dd6d3742c78b6b66b45d80cef54a`. The dump includes
table counts, roots, modules, imports and diagnostics; cost-tool plain stdout
also agrees between variants for each mode. Allocation output intentionally
differs. Generated C and executable hashes are recorded in `summary.json`;
the harness C differs because it implements different lexer paths.

**Recommendation:** accept this as the current M2 cost ledger. The temporary
implementation is slower and allocates more than HEAD; it is not a performance
win. Retain the costs as dependencies for the later direct parser and compiler
tuple/interning work. This does not establish M5/M6 whole-compiler ceilings,
mark a roadmap milestone complete, or validate a stage-2 compiler switch.

The candidate freeze includes the complete dirty integration tree, so this is
a current integration comparison rather than a single-patch bridge experiment.
The common generator differs from the earlier record-probe generator; these
independent probes must not be combined into an absolute cost decomposition.
Instruction spread is about 2.41% for baseline tables, 0.42% for candidate
tables, 0.51% for baseline graph and 0.76% for candidate graph. The substantial
instruction increases exceed that spread. RSS remains a secondary host signal.

## Artifacts and reproduction

Everything is retained under `/tmp/blorp-discovery-m2-current-20261003/`:
`metadata.json`, the three source manifests, `tracked.patch`, read-only source
and input trees, generated C, six binaries, compile/link logs,
`build-commands.json`, `sample-commands.json`, `samples.json`, `summary.json`,
complete dumps and every raw stdout/stderr sample. The shared measurement lock
was released at completion.

```bash
python3 /tmp/blorp-discovery-m2-current-20261003/build.py
benchmarks/self_compile_measure lock -- \
  python3 /tmp/blorp-discovery-m2-current-20261003/measure.py
git diff --check
```

The runner fails on generator/source/input mutation, output or module-count
mismatch, inactive counters, missing time counters or nondeterministic managed
allocations/releases. The initial frozen compile exposed the omitted generated
input; supplying the repository-generated support resolved it. The runner also
corrected its boolean-output parser from words to the tool's `0`/`1` spelling
before restarting all measured rounds.
