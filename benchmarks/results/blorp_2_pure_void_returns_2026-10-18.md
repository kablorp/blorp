# Allowing pure Void returns

Remove the pure-Void restriction at signature checking, generic inference and specialization.
The existing Void calling convention, normalization and cleanup handle the admitted programs.
Independent prospective ceilings permit at most +3% construction allocations or retired instructions.

Baseline: `269581d111ad9e542afe28f051dc77a2be5ce36f`.
Candidate: functional patch `cc20363d`, production patch `a80bc838`; the freeze pins all 51 source/library files.
Producers: preserved host `545a6a07`, normal `34ac1a91`, diagnostic `be31a5a3`, STD91 tree `090ed68c`.
The packet records complete binary/tool hashes, modes, flags and exact commands; no host was rebuilt.
Both variants use `compile --no-format` at the same canonical source, working directory and output path.

| Construction metric | Baseline | Candidate | Change | Verdict |
| --- | ---: | ---: | ---: | --- |
| Allocations | 24,288,915 | 24,250,296 | -0.159% | Pass |
| Retired instructions, minimum of three | 21,634,372,818 | 21,575,830,610 | -0.271% | Pass |

Two setup generations preceded six serial normal calls: B1, C1, C2, B2, B3, C3.
Two diagnostic calls measured schema-1 `artifact_construction_complete.total_allocations`.
Every emitted C file exactly matches its own variant's setup output; no normalization was used.
These are host construction proxies, not Blorp 2 self-compilation or execution-speed measurements.
Historical host compile-time leak checking stays unset; native strict-zero and sanitizer gates remain active.

Initial RED: 101 PASS / 16 FAIL; focused GREEN: 118 PASS / 0 FAIL, with empty stderr.
The full gate passed 3,391 component callbacks, 480 fixture callbacks and 585 nested native callbacks.
All 89 linker warnings matched inherited shapes. Two additional ordinary CLI emissions retained fixture C for review.
Generated C confirms unmanaged Void calls, one String drop and argv cleanup before successful exit.
Handwritten production: 4 added / 40 deleted (-36); tests: 125 added / 125 deleted (0 net).

Raw [cost packet](../../build/bootstrap-evidence/allow-pure-void-proxy-2026-10-18/COST_RECEIPT.json),
[functional receipt](../../build/bootstrap-evidence/allow-pure-void-current-full-acceptance-2026-10-18/RECEIPT.json),
[fixture-C receipt](../../build/bootstrap-evidence/allow-pure-void-generated-c-review-2026-10-18/RECEIPT.json),
and [focused evidence](../../build/bootstrap-evidence/allow-pure-void-focused-2026-10-18/PLAN.json) remain in the main checkout.
