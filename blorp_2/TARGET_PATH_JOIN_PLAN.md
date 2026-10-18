# Ordinary target path.join

Add only pure `path.join(base: String, child: String) -> String` to the target library.
Absolute child wins, then empty base; otherwise retain/add `/`, without normalization.
UTF-8, NUL, backslash and repeated separators preserve exact counted bytes.
The [seven-path contract](ROADMAP.md#seven-shell-and-path-functions) owns semantics.
Current accepted base B: `8c5abe719549db3faac7403cccca779151978d6a`; historical 89/8a evidence is not current proof.

Port the ordinary 30-line module, two 18-line real-main fixtures, two existing-style suites and e2e registration.
No prelude import, compiler/runtime/backend change, source migration, primitive, loop, trait or extra mechanism.
Caps: production 60 gross/+60 net; tests 250 including at most two fixtures/50 lines; public docs 25.
Historical shape: production 30, tests 133 including 36 fixture lines, docs 25; count current physical lines independently.
Each new fixture: at most 205,000 allocations and 600,000,000 normal retired instructions; all tighter existing caps bind.

Before samples, root and an independent peer must approve and freeze B, exact C=B+module, full libraries/corpus and host roles.
FEATURE hard limits: +3% allocations and normal min3 instructions for each unchanged input and the original schema1 construction checkpoint proxy.
Use one physical boundary, alternating serial B/C samples, strict pilot/native zero and exact unchanged C/diagnostic bytes; never roll B/refreeze after failure.
This feature contract grants no SOURCE cumulative/R0 waiver; the [old host strict leak](HOST_BOOTSTRAP_LIMITATIONS.md) remains failed and separate.
Current functional host is root's FRESH c04f68ba binary; source-proxy producer/checkpoint recipe and measurement binaries await root freeze.
TDD: missing-module red, 2 unit/2 e2e green, three historical decision/separator faults kill named oracles, exact restoration green; inspect generated ownership C.
Old concat-base counts 21,988/23,310 and full e2e 464/0 are historical only; require current full component/e2e, sanitizer and matched costs.
Root owns compiled-job grants, plan/code commits and landing; root plus independent code-reviewer/test-runner review precedes each commit; stop for scope/cap/API/identity failure.
