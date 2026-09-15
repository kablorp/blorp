# Step 4A: Typed Exceptional Dimension Factors

**Status:** Implemented in the Step 4A worktree; nominal session-owned
`MetaId` remains a separate follow-up.

## Why this cut exists

The dimension solver previously stored every monomial factor as a `String`.
An unbound meta became `"?m" + id`, and reconstruction parsed that spelling
back into `SemanticMetaType`. Non-exact division serialized its canonical
operands with a debug string. Thus a real meta and an unrelated
`SemanticTypeVar("?m1")` could acquire the same factor identity inside an
opaque division and make `dim_solve` report `DimSolved` for distinct types.
Packet 139 records the failing probe and a rejected all-typed-factor rewrite:
that rewrite increased focused allocations and retired instructions by about
37% even after an equality fast path.

The accepted representation separates the common and exceptional cases:

```blorp
private union DimSpecialFactor:
    DimMetaFactor(Int)  -- becomes MetaId with session ownership
    DimOpaqueDivisionFactor(DimCanonical, DimCanonical)
    DimOpaqueTypeFactor(SemanticType)

private record DimMonomial {
    coeff: Int,
    vars: List[String],                 -- ordinary names, existing sort path
    specials: List[DimSpecialFactor]    -- semantic identities, not display text
}
```

An ordinary `#N` factor keeps its original string and sort. A meta has a
distinct variant and numeric ID; non-exact division retains normalized
numerator/denominator values; other opaque types retain the immutable
`SemanticType`. No parser or formatter change is involved, and these factor
strings are type-checker inputs, not source strings carried to emission.

## Implementation and invariants

- `dim_to_canonical` creates typed special factors for metas, non-exact
  divisions, and opaque types. It no longer uses `type_to_string` or the
  `?mN` spelling as solver identity.
- Ordinary products still use `List[String].concat().sort()`. Joining two
  empty special lists reuses the empty value instead of allocating a new
  list. The ordinary sorted-term merge remains unchanged.
- Exceptional factors compare by variant and semantic value. Division
  operands compare recursively as canonical values; opaque types use
  `types_equal`. Duplicate special factors and exceptional terms compare as
  multisets. Singleton lists take a direct equality path to avoid repeated
  recursive counting in nested divisions.
- Exceptional terms coalesce by semantic identity and preserve encounter
  order when a symbolic binding is reconstructed. Their equivalence test is
  order-independent, so reordered expressions still solve equally. The
  resulting `SemanticType` tree may retain a different but equivalent term
  order for differently ordered source expressions; it is not a promised
  canonical print order. Focused tests check both semantic equivalence and
  reconstruction of opaque division.
- When multiple singleton metas can be isolated, the solver tries numeric
  meta IDs in ascending order, then tries singleton named dimension variables
  in lexical order, independent of sum and opaque-term order. This intentionally
  replaces the former lexical spelling order (`?m1`, `?m10`, `?m2`) for IDs
  beyond one digit. Products containing metas are not sortable binding
  candidates because this solver cannot isolate them.
- Reconstruction of a factor back to `SemanticType` occurs only on a
  binding-result path. An opaque division rebuilds its canonical operands
  there, while an opaque type shares the original immutable type value.

For example, the previously colliding expressions now remain distinct:

```blorp
left  = 1 + (SemanticMetaType(1) / 3)
right = 1 + (SemanticTypeVar("?m1") / 3)
-- dim_solve([], left, right) == DimStuck
```

The `?m1` type variable is an internal constructed probe, not documented
source syntax. It checks that the compiler cannot mistake display spelling
for provenance.

## Fast feedback and evidence

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_dim_solver.brp
scripts/compiler-check --changed
bin/blorp test --sanitize --timeout 180 \
    blorp/test/compiler/stage_06_typecheck/type_system/test_dim_solver.brp \
    blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp
benchmarks/compiler_blorp_benchmark_runner \
    compiler-dim-canonical-factor-profile \
    blorp/benchmark/compiler/compiler_dim_canonical_factor_profile.brp \
    plain 8 4096 plain
```

The retained benchmark also accepts `multiterm`, `opaque`, `mixed`, and
`nested` as its final argument. It builds expressions outside the measured
loop and requires all 4,096 solves to succeed. The `mixed` and `nested`
modes are candidate-only stress checks, not before/after claims.

The collision and binding-order tests failed before their respective solver
changes. All 17 focused solver tests pass after them, including factor
permutation/multiplicity, nested opaque identity, symbolic binding
reconstruction, and order-independent meta/named binding choices.
Independent validation built the compiler and passed three changed-owner
suites (two changed production sources), plus 17/17 dimension-solver and
30/30 context tests under ASan/UBSan. Formatting and `git diff --check`
also pass. The final broad `scripts/test compiler-blorp runtime` gate passes
4,583 compiler tests and 4,474 runtime tests (9,057 total), with no failures.

One warm direct pair of the eight-factor workers gives the following cost
screen. Counts are for 4,096 solves, with zero retained objects/bytes in
every run. Sampled peak is whole-worker footprint, not a precise solver
heap ceiling; elapsed times were noisy and are not used for a speed claim.

| Mode | Allocations baseline → current | Instructions baseline → current | Sampled peak baseline → current |
| --- | ---: | ---: | ---: |
| Plain product | 864,256 → 864,256 | 1,148,907,252 → 1,164,738,496 (+1.38%) | 1,081,632 → 1,081,632 B |
| Multi-term merge | 1,433,600 → 1,433,600 | 1,882,402,319 → 1,910,866,612 (+1.51%) | 1,065,248 → 1,081,632 B |
| Opaque division | 1,007,616 → 954,368 (−5.28%) | 1,327,229,080 → 1,275,547,541 (−3.89%) | 1,098,016 → 1,065,248 B |

The focused worker grows 738,088→757,720 B (+2.66%). The baseline and
current worker cache keys are
`50d37cd96a704442dd02c7ca1c37d109d873c1501c539ba2b46a2f5e85217435`
and `e17ffbd412838c868229de5f7282c4f86a67844d9dfad5f306630deabc371cd6`.
These are small-number screens, not statistically robust latency estimates.

The candidate-only `nested` mode solves 4,096 cases with 1,044,480
allocations/releases, 1,381,954,785 retired instructions, and zero retention;
`mixed` solves all 4,096 with 974,848 allocations/releases and zero
retention. Neither mode has a comparable baseline worker, so no improvement
claim is made for them.

## Acceptance and next boundary

This cut is accepted only with the collision, equivalence, symbolic-bind,
and nested tests green; changed-owner and sanitizer gates green; and no
material allocation, instruction, peak, or code-size regression on the
focused and selected compiler guards. The selected CTFE comparison follows
from one warm direct pair: both workers return checksum 2,538, perform 72
dependency body checks with three reuses, report zero errors, and allocate
770,319/release 770,316 objects with three objects/192 B retained. Retired
instructions are 1,569,630,894→1,569,636,750 (near exact parity); sampled
peak footprint is 14,942,520→14,975,288 B (+0.22%). Worker size is
6,378,816→6,398,400 B (+0.31%). The baseline/current cache keys are
`d99a9995faf7a0945c06f483c3ba72c2424bcdf654e0ab82a0ff3e51b312306c`
and `58f0879968eb6687b0bb82dd1fc9b6aa84b70b14b202a75569e0efd0349d30c0`.
This is a selected guard, not a whole-compiler memory-ceiling result.

`SemanticMetaType`, `DimMetaFactor`, `DimBindMeta`, and the opaque context
solver still use a raw `Int`. Two independently issued index-zero metas can
still alias across contexts. The next Step 4A slice must inventory every
fresh inference-session boundary, issue deterministic session identities,
and migrate those types together to nominal `MetaId`. It must not infer
provenance from a debug string or introduce a process-global counter.

The retained product benchmark reaches equality before
`dim_solve_multiple_terms`; it does not screen equations that bind a symbolic
factor or return `DimStuck`. Before optimizing that branch, add a small
bind/stuck mode with an unchanged baseline worker so candidate-record
construction and sorting have direct allocation/instruction evidence. Do
not generalize the equality-path cost result to that branch.
