# Accepted-Alias Cycle Membership Index: Rejected

Issue 99 tested replacing the accepted-alias resolver's path-local
`List[String]` membership scan with a `Dict[String, Bool]`. Candidate commit
`1dd8d43e29340e6ab0513a4ddcfc2acd2d22f66e` was based on
`9ecb72e934c42f730fe15b5f3f05ee62a76db5f6`. The production change was not
merged.

## Decision

Reject the candidate. It did not meet the 10% wide/deep acceptance threshold,
failed the 2% shallow guardrail on independent repetition, and the retained
benchmark did not isolate the production resolver.

The benchmark called a second public, statistics-producing resolver rather
than `accepted_alias_resolve`. Its baseline updated a statistics record inside
every list comparison, while its candidate removed that instrumented work.
Consequently, the apparent improvement cannot be attributed to the production
`List.contains` to `Dict.contains` substitution. Production also retained the
ordered list while COW-updating a dictionary, so it paid for both path
representations.

## Measurements

The candidate's retained seven-pair wide/deep screen reported:

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| allocations | 4,786,922 | 4,458,662 | -6.86% |
| measured elapsed | 1,199,502 us | 1,095,283 us | -8.69% |
| process elapsed | 1,209,906 us | 1,105,358 us | -8.64% |

All three aggregate signals missed the required 10% improvement. The claimed
100% reduction in `alias_names_compared` was not a total-work measure: it did
not count string hashing, dictionary comparisons, or COW dictionary updates.

An independent 15-pair shallow rerun produced:

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| allocations | 43,602 | 43,602 | 0.00% |
| measured elapsed | 3,149 us | 3,256 us | +3.40% |
| process elapsed | 6,064 us | 6,327 us | +4.34% |

Its raw result was written to
`/tmp/issue99-independent-shallow.json` with SHA-256
`10ca45aad1db794381b1a507cea5ed44984655ff0d9631a86f19cb8baae2031b`.
That temporary path is recorded for audit context, not treated as durable
evidence.

## Correctness and validation

The semantic rewrite appeared correct: immutable path updates preserved
sibling isolation and tested cycle behavior. The following checks passed on
the candidate:

- focused accepted-authority and profile tests: 12/12;
- changed-owner selection: 6/6 suites;
- typecheck stage: 38/38 suites and 2/2 checks;
- `scripts/test compiler-blorp`: 4,558/4,558;
- representative generated C was byte-identical, SHA-256
  `cbc0692473886ebfab1cb1f9838081425c0b764edff6941d093c16de074cf38c`;
- `git diff --check`.

The baseline compiler was fresh at `9ecb72e9`, SHA-256
`058cdb3168cc3909811c8fdaad68143166a3cd0796a6c9942b3d3486454aaa7f`.
The candidate compiler was fresh at `1dd8d43e`, SHA-256
`6f9be03490b3b3f1429b3e045d91657f296d374c4ad2a5e485479833e3fe32ac`.

## Follow-up boundary

Revisit only with a benchmark of the actual production resolver, equivalent
instrumentation outside the timed boundary, and a single compact path
representation. It must report retired instructions as well as allocations
and elapsed time, robustly stay within the shallow guardrail, and clear the
wide/deep threshold.
