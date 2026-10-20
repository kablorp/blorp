# Blorp 2 receiver declaration checking

Receiver declarations are checked for overlap after signature acceptance and
before bodies. Visibility comes from the frozen namespace; candidates carry
accepted function identities and signatures. Declaration overlap and call
selection use the existing inference equality engine, replacing the separate
receiver matcher. Ground types use semantic equality; flexible declaration
parameters have distinct ranges, while caller parameters remain rigid.

Transient name groups check each unordered pair once. A user module skips an
inherited/inherited pair only when the exact prelude subset was already checked.
Repeated routes to one FunctionId are one candidate. Diagnostics retain the
introduced occurrence, both declarations and relevant import sites. Only rendering
looks up spellings. There is no pair cache or second resolution path.

Against the accepted keyword base, production is **455 added / 431 deleted,
net +24 lines**; tests are **615/83, net +532**. Earlier equality preparation
adds nine production lines, making the cumulative change +33, within +102.

## Behavioral evidence

Owning suites cover nominal and rigid identities, ordered/phantom arguments,
finite unification, unused conflicting declarations, route deduplication and
inherited/new prelude clashes. Nine valid behavioral mutants are killed:
ground guard, nominal identity, rigid owner, bare/applied distinction, argument
length/order, lost constraint, duplicate route and skipped inherited/new pair.
Their red runs execute **51 passing / 18 failing callbacks**; all **69 restored
callbacks** pass. The positive same-identity prelude reimport remains green.

Root and independent compiler experts reviewed the code and integration. Twelve
of thirteen integrated files equal the standalone source; the syntax composition
adds only diagnostic note lines to the accepted keyword model. Earlier isolated
ground-case costs and mutants remain evidence for their exact unchanged owners,
not newly measured current-stack results.

## Matched integration costs

The current pair uses the frozen normal host `899e0a92…`, diagnostic host
`86ba69ff…`, Apple Clang21/macOS arm64 and identical O0 diagnostic pilot flags.
Baseline keyword pilot is `6258891f…`, C `433d2e1d…`; candidate is `825cde56…`,
C `6efeaaec…`. Complete hashes/manifests are retained in the raw packet.

There are **3,016 Blorp measurement invocations**, plus one candidate-build
invocation and its native link: 896 strict calls, 2,112 normal samples and eight
host source-to-C proxies. All 445 corpus inputs and three complete provider
stresses preserve outcomes, full diagnostics and C. Every strict counter is
positive and balanced with zero leaked objects/bytes. Seven expected diagnostic
files have nine reversible checkout-root relocations; actual output is never
normalized. Normal timing unsets both memory variables outside time; rejected
inputs are strict checked but have no normal instruction claim.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Accepted-corpus allocations | 4,569,988 | 4,645,155 | +1.644796% |
| Corpus sum of per-input min3 instructions | 14,484,834,455 | 14,711,585,929 | +1.565441% |
| Return-zero allocations | 8,227 | 8,458 | within 8,513 |
| 32x1 allocations | 23,176 | 23,794 | within 31,000 |
| 32x1 instructions | 65,935,059 | 68,715,365 | +4.216734% |
| 32x16 instructions | 238,243,741 | 243,751,143 | +2.311667% |
| 128x8 instructions | 578,157,419 | 605,897,237 | +4.797970% |
| Host artifact-construction allocations | 22,897,743 | 23,357,376 | +2.007329% |
| Host source-to-C min3 instructions | 42,155,283,607 | 42,994,360,862 | +1.990444% |

All **808 cap decisions pass** under the explicitly reviewed +5% correctness-pass
allowance and retained absolute limits. Worst strict allocation growth is
3.069360%; worst timed growth is the 128x8 stress above. The original eight
tighter-limit failures remain failures in the
[cost decision](https://github.com/kablorp/blorp/blob/b1dd8fda7d5f6c3451f6dd492c54cd8d876fdd2b/blorp_2/UFCS_OVERLAP_PLAN.md#complete-collection-and-correctness-feature-cost-decision).
These are marginal costs against the keyword base. Different-source host
proxies are not self-compilation or directly comparable across report roots.

Remaining work includes repeated method-route scans, linear candidate deduplication
and inherited-set membership. IntMap already uses hashing and returns its stored
entries without rebuilding them. A credible follow-up would measure canonical
unique introductions from the existing visibility/signature producer while
preserving source provenance and conflict order. Selection also reprojects an
already accepted signature by ID; passing AcceptedFunction directly can remove
that small lookup. Neither follow-up needs a cache; neither is implemented here.

Raw joint commands, full hashes, C, streams and per-input arithmetic are retained
under the coordinator's ignored `build/ufcs-keyword-integration/`; standalone
costs and nine mutants remain under `quality-ufcs-integrated`'s ignored
`blorp_2/build/ufcs-integrated/`.

## Destination

The literal actual-main Make gate passes **2,852 component checks and 445 e2e
checks**, with 351 native links/522 runs and one O0 pilot build. Its compiler C
is byte-identical to the paired candidate. The destination host remains FRESH
at `390bdd0d…`; it is not substituted into paired measurements.

The dynamic frontier parses **35/37 modules**: Char literals stop `lex.brp` at
byte7471; function-type syntax stops `specialize.brp` at byte11650. Make/frontier
take249.13/20.04 seconds. Full streams, 83 known-category host-emitted C warnings,
separate O0/O2 artifacts and stable input/index proofs are retained under the
primary checkout's ignored `blorp_2/build/ufcs-landing/`. This remains a parsing
frontier, not a self-compile claim.
