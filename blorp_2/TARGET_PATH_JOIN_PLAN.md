# Ordinary target path.join

Add only pure `path.join(base: String, child: String) -> String` to the target library.
Absolute child wins, then empty base; otherwise retain/add `/`, without normalization.
UTF-8, NUL, backslash and repeated separators preserve exact counted bytes.
The [seven-path contract](ROADMAP.md#seven-shell-and-path-functions) owns semantics.
Original unmeasured planning base was `8c5abe719549db3faac7403cccca779151978d6a`; actual frozen FEATURE B is `af92d13708736bde34c164858d7323875fb216aa`.

Implemented the ordinary 30-line module, two 18-line real-main fixtures, two existing-style suites and e2e registration.
No prelude import, compiler/runtime/backend change, source migration, primitive, loop, trait or extra mechanism.
Caps: production 60 gross/+60 net; tests 250 including at most two fixtures/50 lines; public docs 25.
Actual shape: production 30, tests 133 including 36 fixture lines, plan22+README3 API/design lines; benchmark evidence is reported separately.
Each new fixture: at most 205,000 allocations and 600,000,000 normal retired instructions; all tighter existing caps bind.

Root and independent peer approved the complete packet/setup; B/C, full libraries/corpus and original host roles were frozen once before all4024 calls.
FEATURE hard limits: +3% allocations and normal min3 instructions for each unchanged input and the original schema1 construction checkpoint proxy.
Use one physical boundary, alternating serial B/C samples, strict pilot/native zero and exact unchanged C/diagnostic bytes; never roll B/refreeze after failure.
This feature contract grants no SOURCE cumulative/R0 waiver; the [old host strict leak](HOST_BOOTSTRAP_LIMITATIONS.md) remains failed and separate.
Functional c04/ROOTstd91 remains separate from original34ac/be31+std090 cost roles; one C and shared B/C normal/diagnostic pilots were verified.
TDD red2, current unit2/full components3315/e2e478 passed; three current decision/separator mutants killed named oracles and freshly restored greens passed.
All4024 matched calls and strict/native sanitizer gates passed; [acceptance evidence](../benchmarks/results/blorp_2_target_path_join_2026-10-18.md) records exact identities/costs and historical limits.
Root owns compiled-job grants, plan/code commits and landing; root plus independent code-reviewer/test-runner review precedes each commit; stop for scope/cap/API/identity failure.
