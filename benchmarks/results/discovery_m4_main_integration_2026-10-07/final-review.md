# M4 integration evidence and documentation review

Reviewed the staged portable evidence correction in `m4-parser-land/blorp` over main `39aff089e` and feature `d5bf20be4`.

Findings: none outstanding; the historical-coverage heading nit is resolved.
Counts: blockers 0; should-fix 0; nits 0.
Verdict: APPROVE final source, documentation, evidence correction and matched landing-stage completion.

Verified evidence:
- All 71 historical payload files equal the documented prefix-only normalization of their exact ledger Git originals; all 79 original/current ledger hashes and byte counts match (eight manifest updates accounted separately).
- Eight saved original manifests are byte-identical to committed originals. All 245 historical payload entries match current hashes/sizes; the final 73 integration payload entries also match.
- All six historical `.patch.json` wrappers remain feature-tip byte-identical; source-patch/extraction claims are preserved.
- All 27 current captured-log wrappers reproduce their raw scratch captures under only documented portable-prefix substitutions. Raw and normalized hashes/sizes match; original Docker/premerge FAIL verdicts remain visible.
- All 3,979 frozen inputs match before/after and the current working tree. Source/tests/scripts/compiler inputs are unchanged by evidence normalization.
- Docker receipts support 19,225/19,225 tests, 233/233 codegen audit, zero AST mismatches in 3,634 parity checks, and 3,476/3,476 accepted modules assembled in full. Independent census reports zero stops across 3,618 paths. Rejected modules and differential allowances are explicitly qualified.
- GUIDE and GRAMMAR preserve current-main enum retirement and frozen contextual/loop ownership. Roadmap leaves rejected subset parity, outcome unification, StopReason and rejected-head recovery open; no full-grammar, sanitizer or performance claim is made.
- `git diff 39aff089e --check` passes. No scan rules or encoded-content bypasses were introduced; alias text follows the existing rule.

Validation boundary:
The original full Docker run remains FAIL at security after compiled stages pass. Matched stage completion is acceptable only with exact corrective security plus previously unreached drift/hygiene/artifact checks, and unchanged compiled inputs. Do not relabel this as one full Docker PASS. Final corrective receipts are retained in the 73-payload manifest: exact scanner function verified; run_security=1 and dry_run=0; security, both whitespace checks, hygiene and artifact scan exit 0; FRESH binary and 3,979-input freeze remain unchanged. The historical coverage heading is corrected. No compiled commands were run by this reviewer.
