# Ownership function index prototype

## Question

Can late Core assign exact, dense, function-local occurrence identities without
trusting `CoreSourceLoc`, and is building that index cheap enough to justify an
indexed Perceus analysis?

## Workload

The retained `compiler_perceus_allocations` harness decoded the post-DCE Core
for a self-compile of `6cbacd58cd47c31fddd26567338378b32ad48dcd`, advanced it to the production
pre-Perceus boundary, and visited each function body. The compiler executable
was built from the same revision plus this prototype; the profile program was
compiled in release mode by the harness.

```bash
BLORP_PERCEUS_SKIP_BUILD=1 \
BLORP_PERCEUS_COMPILER="$PWD/bin/blorp" \
BLORP_PERCEUS_INPUT_REV=6cbacd58cd47c31fddd26567338378b32ad48dcd \
BLORP_PERCEUS_PROFILE_MODE=index \
  benchmarks/compiler_perceus_allocations

BLORP_PERCEUS_SKIP_BUILD=1 \
BLORP_PERCEUS_COMPILER="$PWD/bin/blorp" \
BLORP_PERCEUS_INPUT_REV=6cbacd58cd47c31fddd26567338378b32ad48dcd \
BLORP_PERCEUS_PROFILE_MODE=perceus \
  benchmarks/compiler_perceus_allocations
```

Both modes use the same source boundary. Allocation counts are the initial
decision signal; wall time was not recorded. The retained harness also prints
releases, live objects, and live allocated bytes for the index mode. Those
fields verify that the per-function indexes are released at the boundary, but
they do not measure cumulative copied payload volume.

## Results

The workload contains 15,323 function bodies and 1,014,957 Core expression
occurrences. Current whole-pass Perceus allocated 48,382,396 objects. That
whole-pass denominator also includes global processing; the index prototype
measures function bodies only, so the ratio is context rather than an exact
break-even calculation.

| index representation | allocations | allocations/node | result |
| --- | ---: | ---: | --- |
| frame-local child-id lists, then concatenate | 7,831,208 | 7.72 | rejected |
| reserved flat edge ranges with an unchecked placeholder | 6,694,423 | 6.60 | rejected |
| threaded record builder with validated optional edge slots | 6,758,016 | 6.66 | rejected |
| locally owned node and edge builders, then validated publication | 2,948,429 | 2.91 | retained |
| three parallel node columns | 7,709,380 | 7.60 | rejected |

Reserving the edge range before visiting children and publishing only a fully
assigned index established the correct shape. Generated-C inspection then
showed that helper calls retained lists out of a threaded builder record before
each append, forcing COW. Moving both accumulators into the traversal function
removed 3,809,587 allocations (56.4%) from the validated version. The retained
row reports 2,948,429 allocations and releases, with zero live objects at the
end of the boundary. Splitting the node row into expression/start/count
columns added about one allocation per node in the earlier prototype, so this
slice retains the single row list. That is a Blorp representation result, not
a general argument against columnar IR.

## Correctness

`test_core_perceus.brp` verifies that:

- two physical occurrences with the same synthetic source/node id receive
  distinct dense occurrence ids;
- consumers see the original expression identity through the compatibility
  payload;
- direct children remain in canonical evaluation order; and
- a 4,097-node sequence indexes without recursive Blorp stack growth.

The focused suite passed 374/374 tests. The index is not in the production
Perceus path yet, so generated C is unchanged by construction.

## Decision

Keep the occurrence-index adapter and retained construction benchmark, but do
not build it during normal compilation until a bottom-up summary prototype can
replace enough of the 48.4M-allocation Perceus pass to repay the 2.95M build
floor. That figure is an allocation-call count, not a copied-byte or
instruction claim. Because the compatibility rows retain `CoreExpr` payloads,
the index must also be consumed and released before any rewrite whose COW
behavior depends on unique ownership. The next experiment should fill id-keyed
summary facts during a forward postorder scan, compare those facts against the
legacy summary walk on the duplicate-synthetic-id and ownership-event fixtures,
and measure the combined index-plus-summary boundary before production wiring.
