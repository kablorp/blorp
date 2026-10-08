# Independent resource-controller review

Reviewed controller: `/tmp/blorp-ranked-tensor-reader-resource/compare_resources.py`
SHA256 `44e48b8694dc5ef338b7f95e63699dd0f39b5b217ed0905ecb807a56ddd28ba6`.
Role: code-reviewer; read-only/syntax/template checks, no candidate pin/native run.

| Severity | Evidence | Finding and bounded correction |
| --- | --- | --- |
| should-fix | compare_resources.py:202–220, :358–367, :400–406 | Generated candidate-main.c/body object are not guarded after setup; their first file pins occur only in final sealing. A changed construction artifact would be sealed as current evidence. Validate/pin setup-produced C/object against the trusted setup-log hashes immediately, recheck in verify_state/final sealing. |

Counts: blocker0, should-fix1, nit0. Verdict: **approve after the should-fix**
for resource execution. The coordinator accepted this bounded finding. It does
not block the separately authorized preparation correctness qualification.

Verified existing boundaries: post-dictionary compiler-source inventory/reused
stage2 pair0de63d…/5950a6… and retained stage1a17; exact immutable baseline pins,
canonical full input authority, accepted dictionary source/tests preservation,
only emit+exact two allowlist-row removals admitted; full post-gate tracked,
untracked, generated-input and generator freezing; O2 and normal/diagnostic
header matching; three normal minimum instruction samples and diagnostic
allocations; immediate validated raw JSON/C pins and final four-record reread;
whole-C identity and integer ceilings `candidate*200 <= baseline*201`.

Process behavior is synchronous/timeout process-group termination with wait;
README requires the owned serial lock wrapper. Background work is observed,
not vetoed; no quiet/wall-time/speed acceptance. Failed/nonempty comparison
outputs cannot be overwritten or automatically retried.

Independent `py_compile` passed (cache kept outside source). Read-only
`--check-template` passed, rechecking sealed baseline/payload/input authority;
no candidate config/comparison payload/native command was created. Six existing
TEMPLATE_PROBES are explicitly synthetic and match44e; they do not establish
real cost or candidate correctness. New construction-pin behavior remains
unverified pending author repair and a bounded follow-up review.
