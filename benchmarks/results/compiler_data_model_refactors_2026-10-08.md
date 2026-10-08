# Compiler data-model cleanup

Frozen self-compile input: `0e1598ed616ed48d03b20bb5a7fe39c61ade6a18`.
Coordinator branch: `codex/data-model-refactors`, based on that committed main.
Main's unrelated bootstrap edit was not included.

## Candidate changes

- Perceus stores payload-parent membership instead of unread contract lists.
  Definition-ID contract buckets and fallback selection remain unchanged.
- Preliminary callable validation stores only kind and diagnostic name, keyed
  by definition ID. C spelling and reservations remain in the final projector.
- CTFE constructs each imported function view once, sharing it between the
  callable and source-group indexes. The loop owns its list accumulator locally.
- CTFE removes an unreachable singleton recovery branch; the lookup's original
  `Option` representation and diagnostic text remain unchanged.
- Discovery drops unused member, supertrait, and variant-payload ordinals,
  including solely obsolete construction plumbing. Row order remains canonical;
  parameter ordinals and bound joins are unchanged.

Changed production files: **124 fewer lines**. Tests: **121 additional lines**.
The ten AGENTS policy lines and measurement artifacts are counted separately.

## Matched measurements

Paired normal/diagnostic stage-2 compilers, Apple clang 21.0.0
(`clang-2100.3.34.2`), CLI/runtime `-O2`, two normal samples each.
The workload stops at emitted C; native compilation is setup, not measured work.
[Baseline](compiler_data_model_refactors_2026-10-08_baseline.json) and
[candidate](compiler_data_model_refactors_2026-10-08_candidate.json) retain
binary hashes, toolchain provenance, both instruction samples, and checkpoints.
The baseline's dirty marker came from the AGENTS policy edit, not compiler code.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 249,479,888 | 249,042,516 | -437,372 (-0.18%) |
| Retired instructions, minimum | 233,410,594,250 | 232,934,139,384 | -0.20% |
| Retired instructions, median | 233,467,494,668 | 233,022,200,630 | -0.19% |

Allocation reductions by checkpoint: typed frontend **389,759**, fused backend
match **2,287**, fused ownership/Perceus **2,287**, emission **43,039**.
Every other allocation delta is unchanged. These are batch checkpoint deltas,
not isolated function attribution. Discovery has no self-compile allocation win.

Both outputs are byte-identical: 84,239,845 bytes, SHA-256
`00d0d4b7edc82d61540a4a7909e592ba85690fe89f5d47f576504bd4628a5173`.
Peak RSS changed only -0.05%; do not claim a meaningful retained-memory win.
Wall time is not acceptance evidence.

An earlier three-way CTFE lookup union was rejected after generated-C review:
successful lookup allocated a wrapper where `Option[CtfeFunction]` uses a pointer.
The final revision removes that cost even though the aggregate prototype won.

Acceptance ceilings set before work: hold/reject whole-compile allocation or
instruction growth above 1%, or owning-phase allocation growth above 2%.
Production growth over 50 lines or 2% of an owning module requires rescoping or
explicit review. No improvement in one metric excuses a regression in another.

```bash
BLORP_CLI_C_OPTIMIZATION=-O2 make
scripts/compiler-build-status
BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --stage2 \
  --input-rev 0e1598ed6 --samples 2 --label candidate \
  --baseline /tmp/baseline.json --output /tmp/candidate.json --require-identical
```

Run the same command without `--baseline`/`--require-identical` on the unchanged
compiler sources first. Do not regenerate the frozen input from a different
revision or compare bootstrap-built and stage-2 binaries.

## Validation

Source and generated-C review: no blockers, should-fixes, or nits. The final
lookup returns a pointer (`static void* brp_2KE`); the rejected union is absent.
The fresh checkout compiler and both stage-2 hashes were checked after gates.

| Check | Passed | Failed |
| --- | ---: | ---: |
| Combined owning suites | 971 | 0 |
| Core ASan + UBSan | 2,551 | 0 |
| Generated-C audit gate | 1 | 0 |
| Rewritten compiler suites | 1,064 | 0 |
| Full discovery parity | 3,636 | 0 |
| Compiler Blorp gate | 7,042 | 0 |
| Leak gate | 1,221 | 0 |

```bash
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --changed --base 0e1598ed6
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/test --no-build --serial \
  --log-dir /tmp/blorp-data-model-gates \
  compiler-new compiler-new-parity compiler-blorp leak
```

Full logs and large C artifacts remain under
`/tmp/blorp-model-refactor-validation.uvkvrf/`; raw matched measurements above
are retained in this directory. The broad gates ran serially and reported
12,963 passing checks; parity reported zero mismatched files.

### Landing inventory reconciliation

The first current-main Docker premerge build passed, then hygiene stopped on
identity-census drift. Review reconciled three changed Perceus dictionary
fingerprints, removed the two deleted preliminary C-naming dictionary sites,
and tightened the backend dictionary ceiling from 229 to 227. The Perceus
lexical name-read ceiling changes from 420 to 421 solely for the membership
key `union_decl.name`, replacing `entry.parent_type_name`; no semantic lookup
is added. The checker's reported `uses.brp` location is the last candidate in
the directory, not the introduced read in `env.brp`. Other inventory budgets,
coverage, approved spelling boundaries, and checker implementation are unchanged.

During landing, main advanced to `a8413c9f3` with the product-storage rewrite.
The cleanup applied cleanly while preserving its product nodes and prepared
emission Result boundary. Main independently removed two backend dictionary
sites; composing both deletions tightens the combined ceiling to 225. The
measurements above remain historical results on the stated frozen toolchain,
not a claim about the newer combined compiler.

## Current-main recheck (`a8413c9f3`)

Matched O2 normal/diagnostic stage-2 builds used frozen input
`a8413c9f38b22884c12fad3722c49be243ee0eeb` and the same bootstrap manifest.
Allocations repeated exactly in both rounds: **284,632,215 → 284,184,846**,
saving **447,369 (-0.1572%)**. Checkpoint reductions were typed frontend
398,939; fused backend match 2,323; fused ownership/Perceus 2,323; emission
43,784. All other allocation deltas were zero.

| Round | Minimum instructions delta | Median instructions delta |
| --- | ---: | ---: |
| Initial | -0.1697% | -0.1645% |
| One built-binary resample | +0.2251% | +0.2840% |

Instruction results are mixed; **do not claim an instruction speedup or exact
nonregression**. Both rounds remain within the predeclared 1% significant-growth
ceiling. Concurrent host work was observed, and the current measurement lock
is a no-op. Process-scoped instruction counts and bounded resampling do not
prove continuous host quietness. No wall-time or meaningful retained-RSS claim.

All four outputs were byte-identical: 86,912,985 bytes, SHA-256
`c5bcc86e9777d0919a6fa36a27fd54f7fb462d4366169666f3b7fcc30d924b5d`.
Accept the allocation/output evidence and measured growth-ceiling compliance;
final correctness acceptance still requires the external combined-tree gate.

Retained raw pairs: [initial baseline](compiler_data_model_refactors_current_main_2026-10-08_baseline.json),
[initial candidate](compiler_data_model_refactors_current_main_2026-10-08_candidate.json),
[resample baseline](compiler_data_model_refactors_current_main_2026-10-08_baseline-resample.json),
and [resample candidate](compiler_data_model_refactors_current_main_2026-10-08_candidate-resample.json).
[Measurement notes](compiler_data_model_refactors_current_main_2026-10-08_notes.md)
record commands, sample spreads, contention observations, and the resample's
stage-label caveat: it reused the same stage-2 binary hashes without rebuilding.

### External landing gate and known baseline failure

The external `linux/amd64` Docker premerge run on the combined `a8413c9f3`
tree passed Build and Quality. Its test gate reported 13,224 passed and one
failed. Compiler tools, rewritten compiler, discovery parity, standard-library
check, runtime, leak, doctest, CLI-deep, and LSP gates passed. Compiler-Blorp's
combined 281-source suite failed during C compilation, before running its tests;
the 863 production check fixtures passed.

The failing C initializes `test_core_emit`'s global case list with 396 nested
list-tail statement expressions. Maximum bracket depth is 399; Clang rejects
the opening at depth 257 against its default limit of 256. An external fresh
build of untouched `a8413c9f3`, using the same manifest's 281 source paths,
bootstrap, O2 compiler, and Clang 18.1.3, reproduced the nesting-limit failure.
This establishes a baseline failure, not its introducing commit or sole Core
pass cause. No bracket-depth override or emitter workaround was applied.

Publication proceeds at the user's explicit direction despite that known
failure. Main subsequently advanced to `2d1de5a6d`; its unrelated parser and
global-table cleanup is retained. The measurements and external gate above
describe the stated `a8413c9f3` boundary, not a fresh full gate on that newer
main composition.
