# Checked and specialized product lifetime witnesses

## Problem and approved boundary

Existing [checked type lifetime tests](test/unit/test_check/test_type_product_lifetimes.brp)
construct TypeRef values directly. Parser/loader lifetime tests cover their own
products, while target runtime tests use a reduced Expr/Form shape. Complete
Checked/Specialized projections produced by the real phases need independent
retained-child witnesses. These host lifetime tests do not measure target stack
margins or establish self-compilation.

Root and independent compiler-expert review approved this first packet from the
product acceptance design. Start from accepted main
`ca458fad441175dd471253b4ec89553364aac900` in its own worktree. The hard scope is
two owning test modules plus one source-only helper: at most300 gross added test
lines and150 fixture/helper lines. Production, exports and data models stay
unchanged. Further Lowered/Owned, accounting and final A/B/C work need separate
reviews and acceptance; [the source plan](BOOTSTRAP_SOURCE_PLAN.md) retains those
open gates.

## Tests through existing producers

Extend `test/unit/test_check/test_type_product_lifetimes.brp` and add
`test/unit/test_specialize/test_product_lifetimes.brp`. One optional shared
`test/unit/product_lifetime_inputs.brp` publishes only source Strings. It must
not retain a program, collect optional phase products or execute tests.

Use N=16/32/64/128 with two source shapes: nested calls ending in integer7, and
finite generic record/union applications whose arguments alternate through Lists.
For example, a two-level argument has `Box[Wrap[Box[Wrap[Int]]]]`, with the
corresponding normal record/variant constructors. These are existing language
forms, not new recursive generic families.

Each owning suite calls its actual public producer prefix, selects a child
expression or parameter signature/layout roots, and returns only that child and
the issued IDs/rows needed to interpret it. The producer's whole program and
unselected function rows then retire before the caller checks:

- every nested call target uses its actual issued identity, its complete one-child
  shape and Int signature, with exactlyN calls and integer7 at the leaf;
- Checked applied record/union argument Lists retain their actual declaration IDs,
  complete argument order/arity, exact alternating depth and Int leaf;
- Specialized children retain the issued instance handles, complete signature and
  record/union field/variant chain through the retained layout roots, ending in Int.

Do not invent raw IDs, recover semantics from a spelling, clone an AST or add a
production observer. Phase tests stop at their owning product; no emitted C or
alternate fixture entrypoint is used. Existing parser/load/scalar lifetime tests
remain independent controls. The source helper does not select or inspect phases.

## Narrow feedback and acceptance

Write the assertions first. Through the existing producers, retain one exact
source-leaf negative control and restored green so the new leaf oracle is observed
failing; this is a test-only control, not a claimed production bug or replay of
ordinary opaque's historical mutants. Capture the exact patch, true statuses,
callback names/counts, raw streams and restoration pins. No automatic retries.

Ask root for the smallest focused compiled lease after the concrete packet is
ready. The normal host command uses the preserved ROOT host/std and five unset
modes under root's globally serialized lane:

```bash
bin/blorp test --suite --timeout 180 \
  blorp_2/test/unit/test_check/test_type_product_lifetimes.brp \
  blorp_2/test/unit/test_specialize/test_product_lifetimes.brp
```

The actual leased command will name the pinned ROOT executable and explicit
`--std-dir`; it must not build a local compiler implicitly. Expected restored
green is the existing eight Checked controls plus eight new callbacks per phase:
24 PASS,0 FAIL, exit0 and empty stderr. Verify exact counters from actual
registration before the lease. Required final checks are those two owning suites,
their bounded oracle control, physical line accounting, unchanged production
pins, link/path checks and git diff --check. Root/independent code and test review
precede the test commit. Commit this short plan separately before implementation.

The frozen opaque feature tree/evidence and original-R0 SOURCE cost hold remain
untouched. A passing host test does not close pilot leak accounting, actual-source
admission, destruction-depth margins or final all-O0 A/B/C acceptance.
