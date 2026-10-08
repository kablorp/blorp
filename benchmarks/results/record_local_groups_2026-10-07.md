# Immutable local record groups

Status: implemented, independently reviewed and validated. This report records
the work-branch checkpoint before publication.
Shared typed storage and main `87e312047` are reconciled in measured candidate
`3d42ce5c8`. Fresh focused, selected, broad, sanitizer/probe and fixpoint gates
pass, and both matched stage-2 cost guards pass. The current receipt below
retains source/binary provenance and measurements. Refreshed generated-C review
and final hygiene/artifact/diff checks also pass.

The original evidence below is historical, bound to baseline
`7b4f6aaca1346e56234fcd0388068f92e858dfc6` and its later main integration
`fd576db79`. Its tables, function mapping and gate counts are preserved as a
prior checkpoint; the shared-storage receipt supersedes its pending acceptance
status and supplies current costs.
## Change and limits

R1 in the [record roadmap](../../docs/RECORD_ALLOCATION_ROADMAP.md) extends the
existing `tuple_flatten` local group path. Immutable literal managed records
and their immutable aliases can become field owners when every use is a field
projection. The existing whole-use walk, binder issuer and group projection
handling serve both products. No second optimizer, traversal or schema map was
added. The existing declaration field-count index is replaced with one concrete
field schema; late invariant count queries derive from that same schema.

Checked `CoreProductBuild` operands are evaluated once in written order. Only
completed owners/references are rearranged into declaration order. Missing,
ambiguous or generic declarations and operand/type mismatches fail closed.
Ordinary ownership handles managed children; mutable source reads are captured
before later mutation, and existing immutable borrowed values stay borrowed.
Binder identity uses name plus id, not the raw id alone.

Whole calls, enclosing storage, captures, record matches, root identity,
mutable records, branches and direct producer results retain their containers.
This changes neither record representation policy nor call/storage ABI. It
adds no Option/Result-specific path and does not activate the 128-byte policy.
Existing logical tuple behavior is preserved; tuple storage belongs to the
other worker. The reconciliation below extends this same declaration issuer
to generated tuple declarations through the accepted shared layout authority.

## Historical allocation evidence

The unchanged retained probe runs at N=256 and N=512:

| Case | Baseline total | Candidate total | Accounting |
| --- | ---: | ---: | --- |
| Local and immutable alias | N | 0 | All record containers removed |
| Shared managed child | N+1 | 1 | Containers removed; shared child remains |
| Branch and call result | N | N | Later slices |
| Fresh mutable assignment | N+1 | N+1 | Later slice |
| Unique update | 1 | 1 | Existing reuse preserved |
| Root identity | N | N | Observable containers preserved |
| Inline fixed control | 0 | 0 | Existing inline behavior preserved |

Values match, every interval balances allocation/release counts, and live deltas
are zero. The final ASan/UBSan probe passes all 18 rows. The new 11-case runtime
suite also tests fresh managed children (64 → 32 allocations at 32 iterations),
unused effectful children, written order, mutable-child snapshots and whole-use
controls. The baseline fails its six new elimination expectations and passes
the five conservative controls. Candidate normal and ASan runs pass all 11.
Counter-active assertions prevent an uninstrumented zero from passing.

## Historical compiler cost and complexity

Measurements use matching normal/diagnostic stage-2 O2 compilers, Apple clang
21.0.0 and the same frozen baseline input. Normal/diagnostic generated C is
identical within each pair. The guard was at most 1% growth in retired
instructions and peak RSS for both self-compile and the small control, defined
before candidate measurements. Retired-instruction rows use the harness's
minimum; RSS rows use the maximum. Wall time is recorded but is not acceptance
evidence.

| Self-compile metric | Baseline | Final candidate | Change |
| --- | ---: | ---: | ---: |
| Managed allocations | 260,893,568 | 259,165,079 | −1,728,489 (−0.66%) |
| Retired instructions | 252,347,486,664 | 251,542,580,372 | −0.32% |
| Peak RSS, bytes | 2,293,235,712 | 2,292,121,600 | −0.05% |
| Group-pass allocations | 8,461,708 | 8,665,255 | +2.41% |
| Resolve-pass allocations | 3,970,761 | 3,151,177 | −20.64% |
| Ownership-pass allocations | 61,645,757 | 60,534,168 | −1.80% |

The first pilot unnecessarily built whole-use facts for record producers it
could not expand: group-pass allocations grew 16.81%. A narrow producer filter
preserves existing tuple admission and accepts only record builds or already
grouped aliases before asking for those facts. Complete alias/whole-use analysis
still runs for admitted literals. This removes 1,219,238 pilot allocations and
leaves the pilot's generated C byte-identical.

The initial two-sample small control showed +1.36% peak RSS and failed the
guard. A matched five-sample repeat for both versions measured allocations
1,729,030 → 1,725,598 (−0.20%), retired instructions
1,624,898,990 → 1,619,300,527 (−0.34%) and peak RSS
39,354,368 → 38,993,920 (−0.92%). Small generated C is identical across versions.
Both initial and repeated measurements are retained; the first RSS increase
did not repeat. These small differences support the guard, not a strong speed
or memory-improvement claim.

The small-control runs reuse the verified stage-2 binaries through external
compiler arguments. The harness labels such runs `compiler_stage: 1` by default;
the packet preserves that raw field and records `executed_binary_stage: 2`.
Their compiler hashes match the full stage-2 measurement pairs.

Production diff: **171 added / 66 deleted / net +105 lines** across
`tuple_flatten.brp`, `product_type.brp` and the mechanical `late_invariants.brp`
schema migration. Generalized branches and the replaced count-only authority
remove redundancy, but this slice does not reduce total production LOC. The
code-reviewer approved a bounded exception for this first consumer, checked
schema admission and measured cost filter. No future deletion is credited.

## Historical generated C and ownership

The frozen self-compile output shrinks 85,148,283 → 85,147,518 bytes. In
`resolve_global_value_expr`, the field-only local
`CoreGlobalValueResolveContext` loses its maker, retained fields, projection
temporary and box drop. The candidate forwards `resolutions` and `scope`
directly to `resolve_global_value_expr_inner`. Other context constructions with
whole-value sinks remain boxed.

That change lets ordinary ownership inference consume `scope` through recursive
resolver calls. Callers retain or transfer it, cancellation frames protect it
until transfer, and non-consuming branches release it. The retained C comparison
maps 18 changed function bodies to the global-value resolver family; those
differences are container elimination and the resulting scope ownership/cleanup
schedules. C signatures and physical storage representations are unchanged.
Most raw diff lines are temporary renumbering after two removed temporaries.
Per-function local-name normalization is a review aid, not an equivalence proof.

Three codegen fixtures and five memory controls now observe root identity so
their physical layout/allocation assertions remain meaningful. Every original
layout, allocation and size assertion is preserved. The three fixtures' existing
advisory diagnostic multisets are identical between baseline and candidate.

The [packet](record_local_groups_2026-10-07/manifest.json) retains compiler/source
hashes, raw measurements, probe output, C excerpts and changed-function mapping.
Core excerpts retain only the selected branch and redact checkout-derived name
prefixes; the full frozen final C hash is
`9080dcdcb9d3c1fe627ab911175f891092341a89e264843f98cd338d3d370d06`.

## Historical reproduction and gates

From each corresponding source checkout, build at O2, then measure against the
same frozen input; run baseline first and candidate second, one compiled
workload at a time:

```bash
export BLORP_CLI_C_OPTIMIZATION=-O2
record_group_label=baseline # Use candidate in the implementation checkout.
make
benchmarks/self_compile_measure --stage2 --input-rev 7b4f6aaca1346e56234fcd0388068f92e858dfc6 \
  --samples 2 --label "$record_group_label" \
  --output "/tmp/record-local-${record_group_label}-self.json"
benchmarks/record_scalar_prepare --sanitize \
  --output "/tmp/record-local-${record_group_label}-probes.json"

# Reuse each verified stage-2 pair for the five-sample small control.
benchmarks/self_compile_measure --compiler bin/blorp-stage2 \
  --diagnostic-compiler bin/blorp-stage2-diagnostic --skip-build-check \
  --program small --samples 5 --label "$record_group_label" \
  --output "/tmp/record-local-${record_group_label}-small.json"

BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --changed --base origin/main
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/test --no-build --serial \
  compiler-blorp compiler-new compiler-new-parity runtime
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-fixpoint --work-dir /tmp/record-local-fixpoint
make hygiene-check
```

Final integrated-tree results:

| Gate | Result |
| --- | --- |
| O2 build and freshness | PASS; `fd576db791a0-dirty`, pinned bootstrap `dev-dbc23276a2a6` |
| `compiler-check --changed --base origin/main` | PASS; 6,024 checks, 37 sources, 43 suites, 3 special checks |
| Generated-C audit | PASS; 238 cases, included as one special gate above |
| Compiler / compiler-new / parity / runtime | PASS; 7,085 / 1,060 / 3,646 / 4,781 tests (16,572 total) |
| `compiler-fixpoint` | PASS; stages 1, 2 and 3 emit identical C |
| `make hygiene-check` | PASS |
| `make artifact-scan` and `git diff --check` | PASS |

Fixpoint C SHA256:
`0abb3548ff7b601c034949dabe0b1e5e16239d4f8b37c4a6e4bbc910e28b0424`.
The compiler remains FRESH after the final static checks.

The first hygiene run detected two renamed exact-site census fingerprints for
the replaced declaration-derived map. The reviewed generator update replaces
two entries with two entries, retaining 868 exact sites; budgets, coverage,
allowed boundaries and capabilities are unchanged. No ratchet was relaxed.
Code-reviewer verdict: approved within R1 scope, P0/P1/P2 findings all zero.

At that checkpoint, shared storage was still pending. The current receipt below
records its reconciled validation; executable R2 transport remains unvalidated.
The implementation is committed on the work branch. No Docker gate, push or
landing has been performed.

## Shared-storage reconciliation

The current integration consumes reviewed storage commit `ce6e8156e` and cleanup
`8f9fecfa3`. It preserves the accepted common production paths and reconciles
the same four R1/use-analysis files. `CoreInterimRecordFields` accepts the real
Core program, derives generated physical fields through the existing catalog
and managed layout view, and derives counts from those fields. Logical tuple
admission remains independent of physical product classification.

Seven new controls cover nested physical fields, Unit ordinals, ambiguous and
generic source records, generated/source name collisions, missing nested rows,
and logical admission. Against the accepted storage base, the four production
files add **542 lines and remove 371, net +171**, including R1, the shared
use-walk extraction and this reconciliation. Independent review accepts this
bounded capability increase; it is not a LOC reduction or a credit against
future deletions.

## Current storage/main receipt

The [retained receipt](record_local_groups_2026-10-07/storage-main-refresh/manifest.json)
compares baseline `ce72f2a467071f8418833d00c0920c3798c76d23` (accepted storage
`8f9fecfa3` plus main `87e312047`) with candidate
`3d42ce5c8b47fd77f4f82971589d288146fa379c` (R1 plus the same storage/main).
Both normal/diagnostic stage-2 pairs use bootstrap `dev-0e1598ed616e`, CLI/runtime
O2 and Apple clang 21.0.0. Both compile frozen input
`8f9fecfa36c30c2802b7da048f02df2ba40b8f07`; the small input hash is unchanged.
There are two self-compile samples and five small-control samples per version.
Normal and diagnostic C match within each measurement pair.

| Workload / metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Self / managed allocations | 285,949,331 | 284,188,419 | −1,760,912 (−0.62%) |
| Self / minimum retired instructions | 271,816,169,523 | 271,121,110,661 | −0.26% |
| Self / maximum peak RSS, bytes | 2,380,988,416 | 2,380,185,600 | −0.03% |
| Small / managed allocations | 1,756,710 | 1,753,278 | −3,432 (−0.20%) |
| Small / minimum retired instructions | 1,655,495,493 | 1,654,275,237 | −0.07% |
| Small / maximum peak RSS, bytes | 39,288,832 | 38,846,464 | −1.13% |

The predefined ceilings of at most 1% instruction and maximum RSS growth pass
for both workloads. These small cost differences establish non-regression,
not a strong speed claim. Self-compile C shrinks 86,823,465 → 86,822,700 bytes
(−765); small C is identical, SHA256
`2033e2664146c6d016466cdcada9d1f3e07724743d656f770b7656aeeecb3f96`.
Fresh review independently maps 18 meaningful changed bodies to the same
global-value resolver family. All declarations and storage outside function
bodies are byte-identical; no functions are added or removed, and signatures
are unchanged after local-name normalization. The one removed context maker
and resulting scope retains, transfers, releases and cancellation cleanup
schedules account for every meaningful difference. Whole-context constructions
remain. The [fresh mapping](record_local_groups_2026-10-07/storage-main-refresh/fresh-c-review-mapping.json)
records current symbols, source locations and each ownership difference;
normalization remains a review aid, not an equivalence proof. Reviewer verdict:
approved, P0/P1/P2 findings all zero.

All four measurement JSON files preserve raw `compiler_stage: 1`: the harness
used external compiler arguments and records that default. The retained
[stage-2 pair manifest](record_local_groups_2026-10-07/storage-main-refresh/stage2-pairs.json)
proves the executed binaries' actual stage and matching hashes. Numeric fields,
hashes and raw schemas are preserved; host names and absolute machine-local
paths are scrubbed recursively.

| Current gate | Result |
| --- | --- |
| O2 build/freshness | PASS; source `3d42ce5c8`, CLI/runtime O2 |
| Focused record / tuple / final invariant suites | PASS; 27 / 51 / 59 (137 total) |
| Retained allocation probes | PASS; 24 normal and 24 ASan/UBSan rows, balanced releases and zero live deltas |
| Selected compiler checks | PASS; 7,155 checks, 69 sources, 79 suites, six special checks |
| Compiler / compiler-new / parity / runtime | PASS; 7,273 / 1,064 / 3,672 / 4,831 (16,840 total) |
| Three-stage fixpoint | PASS; stages 1, 2 and 3 emit identical C |

The selected special checks include Core sanitizer, generated-C audit, leak,
CLI smoke, compiler tools and LSP. Their completion is retained with the
aggregate count; a deleted child log is not reconstructed into a subcount.
Fixpoint SHA256 is
`5781e493ac1ace80dde79e16e87c44ca88b864cd87c31aadeb9098136ca8dda0`.
The current probe retains local/alias containers at zero and the shared managed
child at one; branch/direct-call results and recursive result controls remain
boxed. These controls do not validate R2 transport.

Reproduce each matched measurement from its corresponding source checkout,
using the verified normal/diagnostic stage-2 pair:

```bash
export BLORP_CLI_C_OPTIMIZATION=-O2
make
scripts/compiler-build-status
record_normal_compiler=bin/blorp-stage2-record-refresh
record_diagnostic_compiler=bin/blorp-stage2-record-refresh-diagnostic
record_self_receipt=/tmp/record-refresh-self.json
record_small_receipt=/tmp/record-refresh-small.json
record_normal_probe_receipt=/tmp/record-refresh-probes.json
record_sanitized_probe_receipt=/tmp/record-refresh-probes-sanitize.json
benchmarks/build_stage2_compiler --diagnostic-output "$record_diagnostic_compiler" \
  "$record_normal_compiler"
benchmarks/self_compile_measure --compiler "$record_normal_compiler" \
  --diagnostic-compiler "$record_diagnostic_compiler" --skip-build-check \
  --input-rev 8f9fecfa36c30c2802b7da048f02df2ba40b8f07 \
  --program self --samples 2 --output "$record_self_receipt"
benchmarks/self_compile_measure --compiler "$record_normal_compiler" \
  --diagnostic-compiler "$record_diagnostic_compiler" --skip-build-check \
  --input-rev 8f9fecfa36c30c2802b7da048f02df2ba40b8f07 \
  --program small --samples 5 --output "$record_small_receipt"
benchmarks/record_scalar_prepare --output "$record_normal_probe_receipt"
benchmarks/record_scalar_prepare --sanitize --output "$record_sanitized_probe_receipt"
scripts/compiler-check --changed --base origin/main
scripts/test --no-build --serial compiler-blorp compiler-new compiler-new-parity runtime
scripts/compiler-fixpoint --work-dir /tmp/record-refresh-fixpoint
make hygiene-check
make artifact-scan
```

The source implementation was committed on the work branch at this checkpoint.
Final hygiene, artifact and diff checks pass; the independent test-runner
audit confirms retained gate aggregates, provenance, probes and cost guards.
These validation runs did not use the Docker gate or perform publication.
No Option/Result special case
or 128-byte representation policy is activated.
