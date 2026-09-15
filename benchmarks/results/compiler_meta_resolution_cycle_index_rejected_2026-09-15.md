# Meta-Resolution Cycle Index: Rejected

Issue 102 tested replacing linear cycle-path membership in type-meta
resolution with four 60-bit masks for absolute meta IDs `0..239`, falling
back to a list for larger IDs. Candidate commit
`f2b9353002407a8b1c11582db2e065dbb25f2ea2` was based on
`9ecb72e934c42f730fe15b5f3f05ee62a76db5f6`. No candidate code was merged.

## Decision

Reject the candidate. It introduces a correctness regression for negative meta
IDs, and its timing harness exercises a second public resolver rather than the
production implementation. The available measurements therefore cannot
establish a production compiler improvement.

The candidate's mask membership returned `False` for every negative ID instead
of consulting the fallback path. `bind_meta` accepts any `Int`, so a `-1 -> -1`
binding recursed until the test process crashed with exit 139. The same
production-resolver probe passed on the baseline. This alone makes the
candidate unsafe to merge.

The fixed absolute-ID window is also poorly aligned with the cost under study.
It accelerates IDs `0..239`, not chains by depth. All later IDs retain linear
membership, while the synthetic benchmark always starts its chains at ID 0.
It consequently does not represent shallow chains allocated after ID 239 or
establish the real compiler's ID and depth distributions.

## Measurement limitations

The fixture timed a new public `resolve_type_metas_profile` traversal rather
than production `resolve_type_metas`. Approximately 295 of the 430 added lines
in `context.brp` were profiling records, counters, and that duplicate
traversal; the full candidate added 981 lines and removed 16. The candidate
did not retain paired baseline/candidate samples, measure retired instructions,
prove cross-revision output identity, or enforce the issue's 2% shallow-case
guardrail. Its candidate-only smoke results cannot support acceptance:

| Shape | Resolution requests | Comparisons | Allocations | Elapsed |
| --- | ---: | ---: | ---: | ---: |
| 2 iterations, depth 8, width 3, deep | 16 | 0 | 190 | 67 us |
| 2 iterations, depth 8, width 3, siblings | 48 | 0 | 578 | 88 us |
| 1 iteration, depth 241, width 1, deep | 241 | 240 | 1,032 | 349 us |
| 1 iteration, depth 241, width 1, siblings | 241 | 240 | 1,038 | 275 us |

## Validation

The candidate build was fresh. Its existing focused suites passed 19/19, and
independent production-boundary probes passed 8/8 for IDs 0, 59, 60, 239,
240, and 241, a 239/240 mutual cycle, and sibling isolation. The independent
negative-ID probe failed 0/1 with exit 139; the identical baseline probe passed
1/1.

Broader candidate checks passed `compiler-check --stage typecheck` (44 sources,
38 suites, and 2 checks) and `compiler-check --stage types` (19 sources, 26
suites, and 2 checks). Those gates did not cover the admitted negative-ID
state. Diff whitespace checks passed.

## Follow-up boundary

Any retry must first measure production chain-depth and absolute-ID
distributions. It should fix negative IDs with a correct fallback, add retained
tests at every mask boundary plus negative, high-ID, self-cycle, mutual-cycle,
and sibling cases, and avoid adding a second production-like public resolver.
Benchmark the actual resolver using paired alternating revisions, late absolute
IDs, exact output identity, retired instructions, allocations, and elapsed
time. Accept only if deterministic work improves by at least 10% on a
representative workload and shallow cases remain within 2%.
