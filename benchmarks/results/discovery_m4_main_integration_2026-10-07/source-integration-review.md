This source review preceded evidence-path normalization. Source hashes still match; see path-normalization.json for the subsequent evidence-only changes.

# M4 current-main integration review

Base: `39aff089ef41d60925ed7564e0ab139f8dfd34a4`.
Reviewed feature: `d5bf20be48638481cadf8344325d847f59e0430d`.
Reviewed combined staged and working diff in `m4-parser-land/blorp`.

Findings: no actionable source integration defects.
Severity counts: blockers 0; should-fix 0; nits 0.
Verdict: approve SOURCE integration; final documentation/evidence approval pending current-main gates and roadmap update.

Evidence:
- The branches share base `5fed50a38bf09d8e0e32c92965d59604a90c91fa`; 24 paths overlap. Every current-main-only changed path remains unchanged by integration, preserving scalar payload, callback, Option layout and record lifetime changes.
- Production overlap against the approved feature consists of current-main enum retirement and mechanical payload-free `fixed union` migration. `tree_body_parser.brp:55,389,987,1192,1474` retains loop context, next-line operator entry, direct match-arm controls and explicit concurrent parameter owners.
- `tree_expression_parser.brp:85,792` retains expression context and interpolation authority parking. No production recipe imports, Recipe constructors, `skip_body`, `DeferredBody`, `resumed_at` or `resumed_after` remain in discovery sources.
- Existing feature tests survive; overlapping main test changes retain union migration and split or-pattern diagnostic matches without relaxing their equality assertions.
- `docs/GUIDE.md:3693,3696` retains both enum-as-ordinary-name and contextual-name rules.
- All 261 feature evidence paths present in the combined diff remain byte-identical to the feature revision. Historical packets were not rewritten.
- `git diff 39aff089e --check` exits 0.

Pending documentation/evidence review:
- Update current-main roadmap row and stale 698-unread-module exit criterion after the independent census; distinguish complete accepted corpus from rejected-subset/full-grammar completion.
- Inline bodies and token body-presence checks are met; rejected-head lexical recovery, position-query enforcement, outcome unification and StopReason deletion remain open.
- No compiled commands were run by this reviewer. Current-main build, gates, corpus zero-stop and source/binary freeze proof belong to the independent test-runner.

Reviewed source SHA256:
- tree_body_parser.brp: 811e60f7c807e590412546e2c555283bc1f8b3f9b63903d07a64e71f58d0f2bd
- tree_expression_parser.brp: a2be09e59d7c15d5fd3795e17cf21b84b8c6ede5eb548dad57fdf2e132365589
