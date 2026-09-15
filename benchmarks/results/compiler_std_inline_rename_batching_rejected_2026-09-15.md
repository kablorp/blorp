# Standard-Inline Rename Batching: Rejected

Issue 109 tested batching lambda and semantic-match binders into a single
rename prefix before the existing path. The experiment was based on
`9ecb72e934c42f730fe15b5f3f05ee62a76db5f6`; no production or benchmark code
from the candidate was merged.

## Decision

Reject. On the heavy modeled workload, median optimized elapsed increased from
10,481 to 13,081 us (+24.81%). Allocations changed from 74,199 to 74,039
(-0.22%), far below the acceptance threshold. Although modeled path entries
fell from 82,560 to 16,640 (-79.84%), lookup comparisons were unchanged at
332,800 and directly profiled list-copy events increased from 640 to 1,920
(+200%). The heavy regression was sufficient to reject without proceeding to
the shallow guardrail.

The experiment's semantic checksums matched, but its benchmark called a
second partial clone implementation rather than production `clone_expr`.
That duplicate handled only variables, sequences, tuples, and lambdas, so it
could not validate the real standard-inline boundary or branch restoration,
patterns, captures, selects, and concurrency. Its public profile types and
roughly 459 lines of duplicate traversal were unsuitable for production.

The original worker retained aggregate samples but not a reconstructible
candidate commit/patch, source roots, host/order, or raw-log hash. The numbers
above are kept only as sufficient rejection evidence, not as an acceptance-
quality baseline.

## Follow-up boundary

Any retry must exercise the real standard-inline entry point, preserve exact
`CoreVar` identity and sibling scope restoration, cover deep and shallow
matrices, and retain immutable baseline/candidate sources plus raw allocation,
retired-instruction, and elapsed samples. Do not introduce a second clone
authority merely to measure the first.
