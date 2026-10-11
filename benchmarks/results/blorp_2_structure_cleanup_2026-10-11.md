# Blorp 2 specialization cleanup

Base: `bdc31dd85` on `blorp-2`. This is a semantics-preserving response to
the four low-priority findings in the source architecture audit.

## Scope and invariants

Remove the optional instance-key result inside the already classified user-call
branch. Remove concrete signature purity and binding mutability; their checked
counterparts remain authoritative for source legality. Remove the derived
binding-type discovery append only after direct specialization tests cover
unused nested managed and record payload captures and unused initializers in
both match arms. Correct the two stale README architecture descriptions.

Keep nominal identities, instance request order, child-first layouts, complete
binding types, diagnostic provenance, checked purity/mutability errors and
emitted fixture C unchanged. No contextual inference, ownership change, host
planner repair, visitor framework or new measurement controller is included.

## Acceptance fixed before implementation

- Add the specialization regressions before production changes; require them
  to pass on the base and candidate and fail under a relevant deliberate mutant.
- Production lines must decrease. Report test and documentation lines separately.
- Compare fresh baseline/candidate builds made with the same FRESH host,
  toolchain, flags and frozen valid fixture corpus. Require byte-identical C.
- Retain allocations and retired instructions from three serial matched pairs.
  Investigate any repeatable increase above 1% in aggregate or 3% for an
  individual fixture in either metric; existing fixture limits stay unchanged.
- Run the affected direct suites, the full pilot unit/runtime/grammar gate
  normally and with sanitizers/leak checks, and the ordinary e2e gate at its
  existing zero timeout. Obtain independent code-reviewer and test-runner review.

The pilot cannot self-compile yet. Owned-input costs are compilation proxies,
not self-compilation measurements. Source snapshots, binaries, raw samples and
recorder packets are retained under ignored
`blorp_2/build/structure-cleanup/`.

## Implementation and regression evidence

`specialize.brp` now constructs a complete instance key directly inside the
already classified user-call branch. Runtime calls keep their existing path.
Concrete signatures carry parameter/result types; concrete bindings carry
origin, type and span. Checking retains purity and mutability and their legality
checks. Layout discovery collects types from signatures, initializers, scrutinees
and exits without appending the derived binding inventory. Full binding translation
and recursive child-first union preparation remain intact.

Two direct Blorp TestSuite cases protect unused managed/record payload captures
and unused nested generic initializers in both match arms. They assert nominal
layout IDs, representations, concrete binding origins/types/spans and call
request order. Record layouts are eagerly prepared; the record assertions prove
identity/type preservation. Both cases pass on unchanged base production.
A wrong capture-type mutant fails the new capture case; a lost recursive
layout-dependency mutant fails both new cases and an existing managed case.
Exact base restoration passes all seven collection tests before production edits.
These receipts and source snapshots are retained in the
[implementation handback](../../blorp_2/build/structure-cleanup/implementation/handback.md).

The README now describes owned inline union fields, immediate payload borrows,
ordinary self/mutual recursion and transient generic growth checking.

## Final validation

All final packets exit successfully with stable source fingerprints. The
[validation entrypoint](../../blorp_2/build/structure-cleanup/RESULTS.md)
links source snapshots, binaries, raw samples, hashes and recorder packets.

| Check | Result |
| --- | --- |
| Focused specialization/ownership/emission, normal and strict | 213/213 each |
| Four additional constructor suites, normal and strict | 72/72 each |
| Full unit/runtime/grammar, normal and strict | 1,023/1,023 each across 64 suites |
| Ordinary e2e, timeout 0 | 151 cases plus orchestration callback pass |
| Frozen fixture C identity | 134/134 baseline/candidate identical |
| Normal/diagnostic and repeated C identity | All 1,608 samples match their fixture's output |
| Strict diagnostic compiler processes | 804/804 balance allocations/releases, zero leaks |
| Independent compiler code review | Approved without findings |
| Build freshness / whitespace | FRESH host; clean `git diff --check` |

The full test gate initially caught ten stale concrete signature constructors
in four additional test modules. Those fields and unused imports were removed;
the corrected full ordinary/strict gates supersede the failed packet.
Exploratory test-authoring and scratch build-script failures remain separately
labelled in the handbacks. No unresolved pilot failure remains.

The full runnable gates were:

```sh
bin/blorp test --suite --timeout 180 blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
bin/blorp test --suite --sanitize --leak-check --timeout 180 blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
bin/blorp test --suite --timeout 0 blorp_2/test/e2e
```

## Matched costs and source size

The exact baseline is `bdc31dd859b85d78ffebb266d103e14ad6989245`.
All 16 production inputs and 134 valid fixtures were frozen. Only
`specialize.brp` differs between production snapshots; candidate SHA-256 is
`e504bd97559b380da0701d622f5a9e687870410a985307bfa6c33b325428479e`.
The same FRESH host (`4dd4a29a…938ec`) and Apple Clang 21.0.0 built both
normal/diagnostic pilot pairs at `-O0`, diagnostics disabled/enabled respectively,
with `-lm -lpthread`. Three serial matched pairs reverse variant order in pair 2.
Normal processes supply retired instructions; strict diagnostic processes supply
deterministic allocations. Instruction totals sum per-fixture medians.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 487,214 | 483,019 | -0.861018% |
| Retired instructions | 4,802,169,090 | 4,798,898,618 | -0.068104% |

Every fixture allocates less. The largest individual instruction increase is
`match/shadow.brp`, +0.275104%; all preset 1% aggregate / 3% individual triggers
pass. The instruction delta is too small to support a speed improvement claim.
The test-only constructor correction followed measurement; production, corpus,
host, toolchain, flags, binaries and scripts were explicitly reverified before
reusing those measurements. The repository's `lock` command is a no-op;
serialization came from the team's agreement to withhold compiled work.

Production: +13/-44 = **31 fewer lines**. Tests: +199/-61 = **138 added lines**,
including the two regressions and mechanical constructor migration. README:
**3 added lines**. This retained report adds **129 lines** separately.

These costs cover whole pilot fixture compilation, including loading/emission;
they do not measure self-compilation, isolated specialization cost or target
runtime destruction. Existing fixture ceilings, inputs and timeouts are
unchanged. Future source forms must re-establish the occurrence/payload coverage
argument before relying on the reduced discovery inventory. The broader host
sanitizer investigation remains separate and was not rerun or claimed complete.
