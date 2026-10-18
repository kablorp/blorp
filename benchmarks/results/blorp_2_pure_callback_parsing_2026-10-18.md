# Pure callback type parsing costs

The feature adds one recursive parsed-type variant and rejects it during checking.
Both source-to-C construction costs had prospective, independent +3% ceilings.

Baseline: `9280b815aa435c797cb9e33c8de9dd17a626b4a2`.
Candidate: source patch `d302fd09`; the freeze and oracle-correction manifests pin every input.
Producers: recovered host `545a6a07`, normal `34ac1a91`, diagnostic `be31a5a3`, STD91 tree `090ed68c`.
The packet pins the complete binaries, libraries, tools, modes and exact commands; no host was rebuilt.
Both variants use `compile --no-format` at the same canonical source, working directory and output path.

| Construction metric | Baseline | Candidate | Change | Verdict |
| --- | ---: | ---: | ---: | --- |
| Allocations | 24,247,263 | 24,288,915 | +0.172% | Pass |
| Retired instructions, minimum of three | 21,566,907,351 | 21,588,676,131 | +0.101% | Pass |

Two setup generations preceded six serial normal calls: B1, C1, C2, B2, B3, C3.
Two diagnostic calls measured schema-1 `artifact_construction_complete.total_allocations`.
Every generated C file exactly matches its own variant's setup output; no normalization was used.
These are host construction proxies, not Blorp 2 self-compilation or execution-speed measurements.
Compile-time leak checking stays unset for this historical host; native strict-zero and sanitizer gates passed.

Validation: four original parser callbacks failed before implementation; all 13 new callbacks now pass.
The complete gate passed 3,389 component callbacks, 478 fixture callbacks and 581 nested native callbacks.
Generated-C layout/ownership review passed; 89 linker warnings matched the inherited warning shapes.
Handwritten production: 56 added / 10 deleted (+46); tests: 247 added / 4 deleted (+243).

Raw [cost packet](../../build/bootstrap-evidence/pure-callback-proxy-2026-10-18/COST_RECEIPT.json), [functional receipt](../../build/bootstrap-evidence/pure-callback-current-full-acceptance-attempt02-2026-10-18/RECEIPT.json), and [focused evidence](../../build/bootstrap-evidence/pure-callback-focused-2026-10-18/PLAN.json) remain in the main checkout.
