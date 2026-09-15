# Step 3 Complete Body-Outcome Publication

**Decision:** Accepted as a performance-neutral enabling slice. Semantic
outputs and deterministic work counters match, all resource changes remain
within the roadmap guards, and the change deletes real transient authorities
and a quadratic seed-admission pattern. No material latency or retired-
instruction improvement is claimed.

## Provenance and method

The baseline is `main` at `e25b7f89`, immediately before the Step 3 completion
slice. The candidate is the current worktree after direct ordinary row
publication, complete-table refinement, explicit CTFE row-order projection,
linear seed admission, and direct publication after the seed-fill loop without
adding a redundant coverage-validation pass.

Both workers were generated from their own source with Apple clang at
`-O2 -fwrapv` on Darwin arm64. Direct workers were invoked under
`/usr/bin/time -lp`; this avoids including the benchmark runner's source hash
and cache setup in the process counters.

| Worker | SHA-256 | Bytes |
| --- | --- | ---: |
| Baseline | `b0eb937947b97b9c4313e6b0946bf67ceac258c80b4d4dc6711da2f0a09c933c` | 6,499,264 |
| Candidate | `1da146e9c4ec8f4eb9d1dc5674eb341080478a2e0c7567f6e2baf407baa58fab` | 6,499,888 |

The candidate is 624 bytes larger (+0.0096%), below the 1% code-size guard.

## Normal selected workload

Command arguments were `1 24 32 retained selected`. Both variants reported:

- checksum 846 and `workload_valid=True`;
- 24 dependency body checks and one reused body check;
- 24 planned/evaluated global modules with no duplicate evaluation;
- 46 import-binding applications, one evaluated declaration, and no errors;
- one retained object / 64 retained bytes.

Managed allocations/releases were 256,937 / 256,936 for baseline and
256,940 / 256,939 for candidate: three additional calls, or +0.0012%.

| Pair | Order | Baseline instructions | Candidate instructions | Change | Baseline peak | Candidate peak | Baseline RSS | Candidate RSS |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | candidate → baseline | 682,699,553 | 660,545,891 | -3.25% | 14,942,496 | 14,926,136 | 20,119,552 | 20,086,784 |

This final exact-source point sample favors the candidate, but it is not used
as evidence of a material win. A three-pair reproducibility audit of the
immediately preceding candidate measured instruction changes of -0.129%,
-0.008%, and +0.090%; the earlier larger reduction was order/noise sensitive.
The final in-process elapsed window was 69,625 → 64,633 microseconds, likewise
only a point sample. The accepted characterization is neutral within guards.

## Width guard

Arguments `1 1 1024 retained selected` isolate one wide selected dependency.
Both variants reported checksum 1,033, one checked and one reused CTFE body,
one retained object / 64 bytes, and no errors. Baseline allocations/releases
were 308,618 / 308,617; candidate was 308,621 / 308,620. The constant
three-call delta confirms that complete publication adds no managed allocation
per body. Source-order projection still performs linear scalar-ID work.

| Metric | Baseline → candidate, pair 1 | Change | Candidate → baseline, pair 2 | Change |
| --- | ---: | ---: | ---: | ---: |
| Retired instructions | 977,701,342 → 977,886,730 | +0.019% | 977,564,529 → 978,029,831 | +0.048% |
| Peak footprint | 17,793,336 → 17,973,584 | +1.013% | 18,006,328 → 17,695,032 | -1.729% |
| Maximum RSS | 22,953,984 → 23,101,440 | +0.642% | 23,166,976 → 22,839,296 | -1.414% |
| Managed allocations | 308,618 → 308,621 | +0.0010% | 308,618 → 308,621 | +0.0010% |

The first width pair's peak-footprint result was 0.013 percentage points above
the 1% investigation threshold, so the order was immediately reversed. The
second pair changed direction and favored the candidate by 1.729%; RSS also
changed direction. That is host/order noise, not a repeatable regression. This
width case has one seed row, so it exercises wide completion and source-order
publication but is not an empirical dense-seed scaling proof. An intermediate
candidate that added exact coverage validation after filling the seed table
also added approximately one allocation per body; it was rejected. The
accepted candidate relies on the already-proved subset admission plus the
exhaustive fill loop and constructs the opaque complete product directly.

## Correctness and ownership evidence

The final focused results are:

- `make`: pass; `scripts/compiler-build-status`: `FRESH`;
- body order/coverage suite: 31 / 31 pass;
- CTFE profile suite: 18 / 18 pass;
- declaration boundary suite: 69 / 69 pass;
- `scripts/compiler-check --changed`: 2 sources, 7 suites, 0 failures;
- `scripts/test --no-build compiler-blorp`: 4,649 / 4,649 pass.

The body suite covers accepted and rejected outcomes, missing coverage,
main-validation-policy compatibility, source order independent of
insertion/schedule order, implementation methods, and a valid empty complete
table. The CTFE suite covers recursion, repeated roots, selected reuse, a
16-body chain, methods, bodyless dependencies, and fallback accounting.

Generated C was inspected at the ordinary producer. The mutable `rows`
dictionary exists only as a local value during the checking loop; the
`BodyOutcomeTable` and `CompleteBodyOutcomeTable` records are constructed
after insertion completes. There is no retained table/builder alias forcing a
dictionary copy per admission.

Raw local samples were retained under `/tmp/step3-*` during the run. They are
diagnostic scratch artifacts, not repository inputs.
