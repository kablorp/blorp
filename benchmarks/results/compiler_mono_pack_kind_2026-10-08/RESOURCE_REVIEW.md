# Independent resource review: trailing tensor dimension pack

Verdict: **APPROVE — 0 blockers, 0 should-fix, 0 nits**, within the two measured workloads. Read-only review of completed original evidence; no native tests, measurements, source edits or raw-record changes by reviewer. Broader correctness gates remain separate.

Base and frozen self input: `5e6ef4bcfb8871b9a666f042145f313502737609`. Reviewed two-path candidate patch: `5c04af5ba0eb9d83da7fa6a485a115f65824baa4e08f0bc7e9421fdfaa07aecd`; source `9b092b9e8a0b93cdeca3f61a049f03a802e72dcb557ad60ce6034a954be67910`; suite `087e2db7ed68ee5fc3706bb18fe04f9e169167f0dd55cd6c51ec97925c31965b`. Independent source review previously approved with zero findings.

| Workload | Total allocations, base → candidate | Minimum retired instructions, base → candidate | Instruction delta | Whole C |
| --- | --- | --- | --- | --- |
| Self | 249479886 → 249479886 | 233128988530 → 233050360371 | -0.03372732% | Identical, 84239845 bytes |
| Small | 1722783 → 1722783 | 1625933040 → 1626589664 | +0.04038444% | Identical, 40571 bytes |

Both allocation and minimum-instruction ceilings independently pass the exact integer check `candidate * 200 <= baseline * 201` for each workload. All raw normal instruction samples are positive integers, with three samples per side:

- Self base: `233267224655, 233128988530, 233274002895`; candidate: `233050360371, 233347879923, 233203306566`. Max-minus-min/min spread: 0.06220349% / 0.12766320%.
- Small base: `1626189192, 1626015544, 1625933040`; candidate: `1627137965, 1626589664, 1627893080`. Spread: 0.01575415% / 0.08013183%.

The maintained harness checks every normal output against the diagnostic allocation-run output before writing a successful record (`benchmarks/self_compile_measure:509–515`). Saved base/candidate C was independently compared byte for byte. Self C SHA256: `e91eefbed412ecf17f22f4a1df58f128a5b1e88f24445c748862ffc592ba4a56`; small: `9ce3c4d32148311c393a6775383f007c7e06cd24007f0f4452609b86ae26f083`.

Actual stage2 authority comes from retained builder argv/logs, matching construction hashes, one generated compiler C/body object shared by normal and diagnostic links, and `compiled_by: self-5e6ef4bcfb88`. Both pairs report Apple clang 21.0.0, aarch64-apple-darwin, `cli=-O2 runtime=-O2`, split stamp 8 and correct memory modes 0/1. The raw `compiler_stage: 1` field is derived from the explicit-pair convenience path; it is preserved and qualified by companion pair records. Split stamp 8 does not describe the number of stage2 body objects.

Exact original authorities reviewed:

- `BASELINE_COMPLETE.json`: `8c36a830e6e5b8ea6bf9f89d0f447128ac18d1cf36794e465e1d1a0b0ca574b2`.
- `CANDIDATE_COMPLETE.json`: `e86cb0cf31968070ed7230e613b39bb0c4a3d660fd504362f8e99a4c42b92389`.
- `comparison.json`: `147f267d3fdea0a159408d972a8ecbf9bf8e6967b63c7e4f19691869f300a266`.
- Baseline controller: `117bc57479224c5334a90b2ea5d07556408a9f844f5bced998e3a8ec8af66214`; candidate controller: `3b33e4409a8be03e647f433fdaea4399f8617ce53fadc811014e1fc927be6cab`.
- Base normal/diagnostic pair: `187cb4d5fcecca8c62c7fe62f56e114fc1c4523fdc1804e8e5a6497ab0f55387` / `0a690a82e5cb6622ef527bfdb05106f6486e84ecab50fa31cb83e85ff08c1809`.
- Candidate normal/diagnostic pair: `6f2847bf75396410b53581a04b06d4943973db555794e2bb6af78264588034e5` / `ab1ef5252e2dfb639bacca078effd1ace0249a2608b2645ff515760a4f279837`.

Rechecked 31 baseline and 30 candidate sealed payloads, four candidate measurement JSON/C pins, construction log hashes, exact allowed source delta, sealed source/index/generated-input guard records, 3914 frozen-input files and pair pins. All 13 recorded candidate commands exited zero and waited for children; final FRESH and completion guards hold. Coordinator separately confirmed native slot release; reviewer owns no native jobs.

Background activity was not censused by these controllers. The documented minimum-of-runs policy applies; this report makes no quiet-window, wall-time or speed claim. This new review file does not replace or alter any sealed original record.
