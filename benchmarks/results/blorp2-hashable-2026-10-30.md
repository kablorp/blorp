# Ordinary Hashable and IntMap probing

Baseline: `f54f9f45f9141a00d1dbd8751df7241a3b5e9a22`.

The target library defines ordinary `Hashable` beside `Orderable` in
`_base.brp`, with a pure `hash(Self) -> Int` requirement. This placement lets
`int.brp` implement the trait under the existing foundation ownership rule;
no compiler exception, builtin, canonical designation or derivation was added.
Hashable is independent of Equatable. Where values support equality, equal
values must have equal hashes; different values may collide. Hashes may be
negative, including INT_MIN. Implementations are explicit.

Int's implementation returns its input. IntMap now selects its initial slot
from `key.hash()` and retains its existing signed normalization, equality,
probing, growth and insertion order. Its key type remains Int; this change
does not generalize the map. Identity hashing preserves its old distribution.
The prelude exposes the trait name and Int's receiver methods, without
introducing a named `hash` value that would conflict with local bindings.

Production Blorp source grows by 10 lines; test source grows by 102 lines.

## Behavior and oracle evidence

- Before implementation, the new library suite rejected the unavailable
  public Hashable import at line 2, column 12, as expected.
- All nine Hashable cases and twelve IntMap cases pass, normally and under
  ASan/UBSan with strict balanced accounting. They cover signed Int limits,
  bounded generic dispatch, custom record hashing, collisions, shared maps,
  growth and insertion order.
- A separate ordinary program uses the prelude-only Hashable bound and a
  local variable named `hash`; it succeeds with zero allocations and leaks.
  Programs missing the generic bound or relying on automatic record hashing
  reject at the expected source locations with the ordinary trait diagnostics.
- In an isolated library copy, Int.hash returns input + 1. The actual map
  suite still passes all twelve callbacks. Removing only the copied map's
  hash call then fails exactly the home-slot callback, with eleven passes.
  Both runs are sanitized and balanced. This proves the hash abstraction is
  used even though the production identity implementation preserves behavior.
- The maintained self-hosted proof passes 503 component checks in 65 suites,
  108 native checks, and 633 A/B fixture comparisons: 519 accepted and 114
  rejected per compiler. Every result also satisfies its status/output shape.
  Broader explicitly deferred suites remain deferred.
- A, B and C emit identical compiler C, SHA256
  `2ab3b0f77035256a80f9da7f95625386dc46fe607ce7d85f208c4a01bc681f58`.
  All 1,319 guarded input files remain unchanged; all reported strict
  accounting balances have zero leaks.

## Matched costs

Ceilings declared before implementation: at most 3% more allocations or
normal retired instructions, 5% more peak RSS, and 35 added production lines.
Actual self-built B compilers from the baseline and candidate compile the
same final candidate source/library input. The baseline is retained as a Git
snapshot. Both versions use the Makefile's Clang -O0 recipes and the same
pinned producer, `blorp2-seed-f426e350082c`.

| Metric | Baseline B | Candidate B | Change |
| --- | ---: | ---: | ---: |
| Normal retired instructions | 63,310,894,046 | 63,342,485,828 | +0.050% |
| Strict allocations/releases | 19,061,137 | 19,061,137 | unchanged |
| Normal peak RSS, bytes | 270,188,544 | 267,911,168 | -0.84% |
| Strict peak RSS, bytes | 263,847,936 | 262,832,128 | -0.38% |

All ceilings pass. One serial normal and one strict diagnostic sample per
version were taken; the tiny instruction difference establishes no speed gain.
All four output hashes match the compiler-C hash above. Raw commands,
toolchain and binary fingerprints, manifests and logs remain under ignored
`build/hashable/`, including `integration/functional-results.json`,
`candidate/mutation-results.json` and `integration/measurement/results.json`.
The maintained proof's raw outputs are under `blorp_2/build/fixpoint/`.

The earlier proof against `905b4e7d5` and its sample pair are preserved under
`build/hashable/candidate/`, including the exact source snapshot and relocated
proof artifacts. After upstream union syntax landed, the feature was rebased
without changes to its six implementation/test files. The final proof and
matched costs above were rerun against the new parent. Mutation results apply
to the same unchanged feature source.

Publication also adopts the subsequent bootstrap-only commit `a5785d3fd`.
The new default producer, `blorp2-seed-905b4e7d5326`, builds compiler C identical
to the proved C above; that compiler emits the same C again. This exact output
identity connects the default build to the validated compiler without repeating
the full suite. All 1,319 guarded source/library/test/Make inputs remain
unchanged. Bridge artifacts are under `build/hashable/pin-bridge/`; the matched
cost samples above retain their recorded f426 producer provenance.
