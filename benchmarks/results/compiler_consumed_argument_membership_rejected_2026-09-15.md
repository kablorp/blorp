# Consumed-Argument Membership Prototype: Rejected

## Decision

Reject Issue 105 candidate `5ffb386f9d5c2a4223a1e65c2a878cfbf4348d4e`.
The prototype preserved backend semantics and improved a sparse synthetic case,
but its ordered-position constructor is quadratic in consumed-argument count,
adds substantial allocation work, and regresses the required dense cases. No
candidate production code is retained.

## Candidate

The prototype replaced repeated argument-by-index membership scans with a
`ConsumedArgumentMembership` containing sorted unique positions. It inserted
each raw consumed index into a growing list by reconstructing that list. The
representation was then constructed separately in cancellation planning and
cleanup emission, with a possible third construction in direct-runtime
emission.

The original retained report tested 50,000 iterations with one consumed
position at width 4 and four sparse consumed positions at widths 16 and 32:

| Arguments | Consumed | Legacy us | Candidate us | Change |
| ---: | ---: | ---: | ---: | ---: |
| 4 | 1 | 11,391 | 11,388 | -0.03% |
| 16 | 4 | 53,576 | 34,216 | -36.14% |
| 32 | 4 | 110,214 | 36,234 | -67.12% |

Those checksums matched, but the wider candidate paths added 500,010
allocations and releases per 50,000 iterations where the legacy model recorded
none. No focused retired-instruction samples were retained, so these rows did
not meet the issue's written acceptance gate of at least 10% fewer allocations
or retired instructions.

## Disqualifying Dense Cases

Independent review ran the benchmark at the dense widths required by the
issue. These are 20,000-iteration runs of the candidate harness:

```bash
bin/blorp run --no-format \
  blorp/benchmark/compiler/compiler_consumed_argument_membership_profile.brp \
  -- 20000 16 16
bin/blorp run --no-format \
  blorp/benchmark/compiler/compiler_consumed_argument_membership_profile.brp \
  -- 20000 32 32
```

| Arguments / consumed | Legacy us | Candidate us | Change | Added candidate allocations |
| --- | ---: | ---: | ---: | ---: |
| 16 / 16 | 50,236 | 87,268 | +73.72% | 1,080,054 |
| 32 / 32 | 108,099 | 251,453 | +132.61% | 2,680,134 |

Insertion performs a scan and copies the accumulated prefix for each consumed
position, so construction grows quadratically with dense consumed width. The
prototype selected this path from argument count and raw-index count alone; it
did not account for normalized density. Its benchmark also constructed one
membership per iteration and reused it for three scans, understating
production's two or three independent constructions.

## Correctness Evidence

The candidate's semantic work was sound despite the performance rejection:

- invalid positions were ignored, duplicates collapsed, and positions were
  normalized left-to-right;
- focused backend tests passed 372/372;
- changed-owner checks, Core sanitizer, generated-C audit, and 890 leak checks
  passed;
- the compiler suite passed 4,558/4,558;
- baseline and candidate emitted byte-identical compiler C, SHA-256
  `e1f95b491e7ce8eb1be1652b2281d29686dbde970811238333d0e1804b5edf0e`.

Correctness does not offset the failed dense performance boundary. The public
record was also forgeable and the tests omitted the 7/8 threshold, dense
membership, all-invalid normalization, and optimized direct-runtime and
region-sensitive paths.

## Bounded Future Direction

A new attempt should avoid per-index list reconstruction and build one private,
validated representation per call that is shared across all consumers.
Promising bounded shapes are a boolean/bit mask aligned to arguments or a
linear normalization followed by a two-pointer walk. Admission must include
sparse and dense widths, 7/8 threshold cases, construction allocations,
retired instructions, and the actual number of production constructions. It
must not expose a forgeable representation or infer sortedness at call sites.
