# Blorp 2 function recursion (2026-10-10)

The first recursion increment is implemented and independently reviewed: self
and mutual function calls, including finite generic instantiations. Recursive
heap data remains the next increment in the [historical recursion plan](https://github.com/kablorp/blorp/blob/79deebd455856e5955d215ff2ec36f17860feb14/blorp_2/RECURSION_PLAN.md).
That plan maps decisions to primary Rust, Lean, OCaml and Perceus sources and
separates established techniques from pilot-specific restrictions.

The local [evidence navigator](../../blorp_2/build/recursion/README.md) links
ignored snapshots, binaries, generated C, raw samples, mutations and recorder
packets. No commit or push was made.

## Behavior and boundaries

At baseline `44086d74b87a8cdf986f6c2a9260bbdcdd5c6665`, the new checker
acceptance tests reject recursive functions (`checker-before.log`). The final
checker accepts self/mutual calls through existing resolved signatures, while
preserving arity, type and purity checks. The existing specialization request
queue reuses complete concrete keys; C signatures already precede definitions.
No production ownership, emission or runtime changes were needed.

Simply removing call-cycle rejection would allow unbounded specializations such
as `grow[T]` calling `grow[Token[T]]`. A transient declaration-owned
type-parameter dependency graph rejects cycles containing a nesting edge.
Bare-parameter permutations/copies/merges and concrete resets remain finite.
The graph is discarded before checked facts are published. Its reachability
query fails closed on invalid internal identities. The single call observer is
shared by checking and specialization, including record children and all
supported binding/match occurrences.

This is a conservative termination restriction for the current first-order
nominal type algebra, not a general polymorphic-recursion algorithm. Function
recursion uses the C stack; no tail-call or constant-stack guarantee is claimed.
Static IR identities remain function-local; each invocation has distinct runtime
values and obligations. Recursive String parameters have phase tests, while
terminating matches with managed prefix values/parameters await the next match
ownership increment. Recursive heap types and cyclic values are not enabled.

## Tests and oracle checks

| Boundary | New observations |
| --- | --- |
| Checker: 22 callbacks | Self/mutual acceptance, exact growing-instantiation diagnostics and spans, finite permutations/merges/resets, growth hidden in bindings, reassignment, records, UFCS, arguments and match occurrences |
| Specialization: 7 callbacks | Exact recursive instance target IDs, argument order, distinct Int/String keys, unused generic exclusion, finite permutation/merge/reset instance counts |
| Independent ownership: 23 callbacks | Direct lower/use/ownership tests, borrowed parameters, distinct owned results, nested/repeated arguments, last use, unused result cleanup, handwritten malformed ownership IR, emitted call/release/return ordering |
| Grammar: 1 callback | Recursive declarations and calls remain in the restricted grammar |
| Native: 9 fixtures | Self/mutual/UFCS/argument/binding/record/generic calls, mortal String results and arm-local owners live across recursion, through normal main and unmodified emitted C |

Three deliberate oracle breaks failed as intended, then were restored:

- Removing record-child call observation fails the record-field growing-type
  case: 1/22 checker callbacks fails. Restored checker SHA256
  `e8bdd8066957c92eb184106cb3fe8bc319bc394152ef8281f77acb32c92059df`.
- Omitting inserted `DropOwner` operations fails 6/23 ownership callbacks.
  Restored ownership inserter SHA256
  `3dce8ae677e4b994fdc0af8e21a7d975382c72241a36008d9cd77a2d16d57270`.
- Replacing the missing-result-owner negative test input with a valid input
  fails exactly that callback: 1/23. This tests negative-oracle sensitivity;
  it is a test-input mutation, not a production-code mutation.

Initial iterations hit unsupported equality in ownership test setup, literal
pattern failures, and the host restriction on `?=` inside checker loops. Explicit
variant/field comparisons and Result matching resolved them. Original failures
and corrected runs remain in separate local packets linked by the navigator.
The final independent compiler review reports zero
blockers, should-fixes or nits and approves the implementation, tests and plan.

## Matched costs and output identity

Both pilots were built by the same FRESH host, SHA256
`494413b6febc7121aa8beeed10af0c16cf2acbaf6b692edbef960fae0e72ba05`,
with Apple clang 21 and `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1 -lm -lpthread`.

| Artifact | SHA256 |
| --- | --- |
| Baseline source tar | `938e43e6122bdbe4195d9cd0c5c6d286fd0d3fa8f065d8438bfdd3a0ed7d3a26` |
| Baseline compiler | `73a87cec9efd05b2c63568ebf716300e444135ba908573528d121d87893d2d61` |
| Baseline compiler C | `03d05c4496aef8bae72f930543c9c3e6ea92cc6b1ae44789fca3d305b9ae05c2` |
| Candidate source tar | `8b33158f59bf779a8158fc5c549914fbb46ad79540b568c85a72100a0cc68db9` |
| Candidate compiler | `acced841b9e8d2e132124ca26f17ff5f8f117f7422db56693560ec1f4453e902` |
| Candidate compiler C | `5f8b17fbced184edff80a95b8344e0cf5cba6618f215a47baacfaa8e52cb2683` |

Three serialized samples for each baseline/candidate pair give 36 rows. Every
sample records strict compiler leak diagnostics, retired instructions and C
from the same compilation. These include process startup and are owned-input
compilation proxies, not self-compilation or phase-only measurements.

| Old workload | Allocations baseline → candidate | Minimum retired instructions baseline → candidate |
| --- | ---: | ---: |
| return/zero | 692 → 692 | 30916437 → 30959795 |
| nested/calls | 1343 → 1346 | 32928497 → 32876699 |
| mortal_string/basic | 1047 → 1050 | 31991729 → 31956843 |
| generic/box | 2214 → 2223 | 35261664 → 35272575 |
| union/values | 3668 → 3688 | 39329459 → 39381498 |
| match/constructor_spine | 8806 → 8813 | 53158067 → 53347457 |

Maximum allocation growth is **0.545%**; maximum minimum-instruction growth is
**0.356%**, below the unchanged 10%/5% investigation stops. All **86 old valid
fixtures** emit byte-identical baseline/candidate C with strict zero compiler
leaks. Existing fixture ceilings are unchanged. Each new fixture has explicit
10,000-allocation/100M-instruction ceilings. The final full run observes
1748–2685 allocations and 34,663,908–37,281,488 instructions across those nine
fixtures, all within limits. These counters describe the pilot compiler
process, not allocations of the emitted program.

## Final independent validation

The following final recorder packets pass with unchanged inputs during each
run and the same worktree fingerprint:
`511b4f39121d63525cfbf55435466c69191f72f39563716b5d735bf328f09f52`.

| Command | Result | Packet under build/recursion/validation/ |
| --- | --- | --- |
| `make -C blorp_2 test` | 720 unit/runtime/grammar reported cases; 112 e2e cases; all pass; 57.982s | `independent-full/` |
| `env BLORP_LEAK_CHECK=strict bin/blorp test --suite --timeout 180 blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar` | 720 reported cases pass; 5.324s; 849152 allocations/releases, zero leaked bytes | `independent-strict/` |
| `bash blorp_2/build/recursion/matched-costs.sh` | 36 matched samples, unchanged output, both growth thresholds pass | `independent-matched-costs/` |
| `bash blorp_2/build/recursion/old-c-identity.sh` | 86/86 byte-identical C pairs, strict zero compiler leaks | `independent-old-c-identity/` |

The 720 count comprises 628 unit callbacks, 82 grammar callbacks, nine direct C
String-runtime cases and their one Blorp wrapper. The e2e runner reports 95
native fixtures plus 17 frontend checks. Pilot and native fixtures use O0;
native tests use ASan/UBSan. Runtime totals and compiler leak counters do not
prove future aggregate destruction; that increment has its own required leak
oracle and phase matrix in the plan.

Formatted handwritten production delta is **0 net lines** (+185/-185).
Test/fixture delta is **+1346 net lines**: +1421 new and -75 in tracked tests.
The bulk is independently constructed malformed ownership IR and granular
boundary assertions. Documentation-only source comparisons, qualifications
and this report were added after the final compiled gates; compiled inputs
remain unchanged.
