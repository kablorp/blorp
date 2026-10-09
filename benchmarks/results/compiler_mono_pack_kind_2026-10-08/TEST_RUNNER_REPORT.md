# Mono trailing-pack kind cut: independent test/resource result

Verdict: **PASS / APPROVE within the tested scope**. No current gate failures.
All three foreground batches were consumed with exit 0; their serial wrapper
released the shared lock, and all owned child commands were waited. No retries,
threshold overrides, timeout changes, source edits, commits or native jobs remain.

## Authority

- Worktree: `${WORKTREE}`
- Base and frozen input: `5e6ef4bcfb8871b9a666f042145f313502737609`.
- Published-base mono source: `460626f3f4372df869bf8fe8c23a8e34134f08cd5e0bd4e19aeccb2ea2c94a16`.
- Candidate mono source: `9b092b9e8a0b93cdeca3f61a049f03a802e72dcb557ad60ce6034a954be67910`.
- Frozen owning test: `087e2db7ed68ee5fc3706bb18fe04f9e169167f0dd55cd6c51ec97925c31965b`.
- Installed baseline/candidate SHA: `9507499508cf467d3854c4f59c859203ce8056ca686046be0476477429a84846` / `597e3c29beec86133c38ccc26d8b252597a4c96190b162ff4a2f27e1e4f1963e`.
- Both installed binaries reported FRESH, cli/runtime `-O2`, normal memory mode,
  Apple Clang 21.0.0 and `5e6ef4bcfb88-dirty`; only the candidate body changed.
  Tests-only changes make the baseline checkout dirty without changing its body.

The exact production change is the already typed `TensorVariadicDim` admission;
its name remains the substitution key and `#_` remains the wildcard. No public
syntax, Core carrier, parameter issuer, formatter registry or resolution-stage
change was performed. Scanner/allowlist files remain unchanged: the removed call
is a manually audited reader (three calls become two), outside the scanner's
currently recognized accessor vocabulary.

## Correctness gates

| Gate | Passed | Failed | Evidence |
| --- | ---: | ---: | --- |
| Owning Core Mono | 39 | 0 | `candidate-owning-mono.log` |
| Core sanitizers | 2557 | 0 | `final-gates/core-sanitize.log` and full copied gate log |
| Mono specialization context | 34 | 0 | `final-gates/context-test_core_mono_specialize.log` |
| Monomorphization context | 7 | 0 | `final-gates/context-test_core_monomorphize.log` |
| Serial compiler-blorp | 7046 | 0 | `final-gates/compiler-blorp.log` and full copied gate log |

Counts overlap and are not summed as unique tests. The read-only current manifest
selected the owning suite and Core sanitizer and recommended compiler-blorp.
The final batch reused the already pinned owning 39/0 result at identical source,
test and FRESH installed-binary authority; it ran the selected sanitizer directly
to retain complete child stdout instead of compiler-check's successful cleanup.

Actual standalone `python3 scripts/check-magic-spellings --strict` passed with
498 allowlisted findings, no new findings and 0 stale. This was enforcement,
not report mode. `scripts/compiler-identity-census --check` passed at 3444 rows
within baseline budgets. `make hygiene-check`, `git diff --check` and final FRESH
passed. Source/test/docs/generated-input/index/installed snapshots are byte-equal
before/after final gates. Both original chat architecture documents retain their
recorded hashes (`README.md` 05496dde..., `MODULE_RESOLUTION_DESIGN.md` 7ba78a958...).

Failure table for candidate/resource/final gates: **none**.

Historical TDD evidence belongs to the coordinator's preserved logs: the initial
39-case attempt had six failures, including one incorrect new nonterminal-pack
expectation. Correcting that test premise (without production changes) gave
34 PASS / five intended functional FAIL, rather than a compile/setup failure.
The final 39/0 covers those five regressions. No earlier failure was overwritten.

## Matched resource comparison

| Workload | Allocations base → candidate | Minimum instructions base → candidate | Instruction delta |
| --- | --- | --- | ---: |
| Self | 249479886 → 249479886 | 233128988530 → 233050360371 | -0.033727320% |
| Small | 1722783 → 1722783 | 1625933040 → 1626589664 | +0.040384443% |

All four exact integer checks passed: `candidate * 200 <= baseline * 201`, for
allocations and minimum instructions separately in both workloads. Each normal
record retains three instruction samples; paired diagnostic allocation totals
are positive. The harness required matching normal/diagnostic output and checked
toolchain provenance; no skip-build-check or mismatch flag was used.

Whole output C is byte-identical by independent `cmp`, hash and byte count:
self 84239845 bytes, `e91eefbed412ecf17f22f4a1df58f128a5b1e88f24445c748862ffc592ba4a56`;
small 40571 bytes, `9ce3c4d32148311c393a6775383f007c7e06cd24007f0f4452609b86ae26f083`.
The frozen input independently matches the exact git archive plus generated
stdlib and completion marker (3914 files); small input SHA is
`6a67158fb09aac383ec40e77e5c5b1d64fd068b19edf6e2596a6f25060d9cc93`.
Baseline 31 payload pins and candidate 30 payload pins, their actual pairs and
frozen input were re-read unchanged through final gates.

Actual stage2 authority is retained builder argv/shared generated C/body object,
generator SHA and `compiled_by: self-5e6ef4bcfb88`, cli/runtime O2, diagnostic
modes 0/1. Raw JSON's `compiler_stage: 1` is derived from using explicit pair
flags rather than `--stage2`; it was not rewritten. The version's split-8 stamp
does not describe the stage2 builder's single shared C/body object. These are
metadata qualifications, not inferred different measurement subjects.

Background work is permitted by the repository protocol; minimum-of-runs is the
instruction acceptance signal. Wall times are secondary and do not establish a
speedup. This small cut passes the cost ceiling; no speed claim is made.

## Reproduction and closed records

All batch controllers/argv/raw logs are retained here. Approved controllers:
baseline `117bc574...`, candidate `3b33e440...`, final gates `46f1b522...`.
Foreground sessions: 76847, 34014, 71436, each consumed at exit 0.

The guarded final batch ended before the coordinator's subsequent metadata-only
roadmap/results/projected-evidence integration. Those additions are outside this
frozen validation window; this report does not claim a rerun after them. The
coordinator's separate post-metadata checks own that final delivery boundary.

- `BASELINE_COMPLETE.json`: `8c36a830e6e5b8ea6bf9f89d0f447128ac18d1cf36794e465e1d1a0b0ca574b2`
- `CANDIDATE_COMPLETE.json`: `e86cb0cf31968070ed7230e613b39bb0c4a3d660fd504362f8e99a4c42b92389`
- `comparison.json`: `147f267d3fdea0a159408d972a8ecbf9bf8e6967b63c7e4f19691869f300a266`
- `final-gates/FINAL_RESULT.json`: `988018e3482d9c03d3b1a20852334eeefc257f05ad6853e81d04b980747533f0`

Full Docker/premerge was not requested for this wave's validation. Generated-C
audit is not selected by this module's manifest; existing self/small outputs are
identical, so a codegen fixpoint is not triggered. Wider binder/kind authority
migrations remain unverified and outside this delivery.
