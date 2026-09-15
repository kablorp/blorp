# Call-Signature Name Index: Rejected

Issue 111 tested a private occupied-name dictionary for fresh callee type
parameter names. Candidate commit
`e87f2177b969bac1be6c8d0c696d91e10e47f153` was based on
`9ecb72e934c42f730fe15b5f3f05ee62a76db5f6`. No candidate code was merged.

## Decision

Reject the submitted candidate and evidence. The dictionary algorithm appeared
semantically equivalent, but the timed benchmark called a separate profile
reimplementation rather than production `call_signature`. Its allocations,
retired instructions, and elapsed time therefore could not establish a
production improvement. The unconditional `bound_params.length() > 1`
threshold was not justified by real width/collision observations or a paired
no-collision guardrail.

The commit also placed roughly 305 lines of public profile records, functions,
and model logic in `infer.brp`, creating parallel name-allocation authorities.
Tests compared those two models instead of exact production call-signature
output.

Correctness screening did not find a spelling/order defect: ordinary and
dimension prefixes, duplicate source parameters, numeric collision suffixes,
and first-available-name order matched in the model. Focused owner suites
passed 322/322, a representative generated-C comparison was byte-identical
(SHA-256
`3d8d4a3f9a920ba63149f5b12eb9fdaff80de0d2540a142034e8d0174f296d6a`),
and the candidate build was fresh. These checks establish that the experiment
was safe to reject; they do not prove its performance.

The candidate-only synthetic samples included 3,567,000 allocations and 4.112
billion retired instructions for a collision-heavy case, versus 396,000
allocations and 516.7 million instructions for a no-collision multi-parameter
case. With no matched production baseline, these absolute values are not an
optimization result.

## Follow-up boundary

Revisit with only the small private dictionary implementation and a benchmark
that reaches real `call_signature` through inference. First measure actual
parameter widths and collision retries. Retain paired baseline/candidate
allocations, retired instructions, and elapsed time for empty, one-parameter,
two-parameter no-collision, ordinary/dimension collision, duplicate, and deep
numeric-suffix cases. Require exact inferred output and a no-collision
regression within 2% before choosing any threshold.
