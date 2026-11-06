# Accepted-fact cleanup

## F1: default header bounds

F1 removes the second proof of trait-default written header bounds. Trait
contracts remain the proof authority; ordinary free/implementation headers
still validate under their own requirements. Default body annotations and
signature normalization are unchanged. No new representation is retained.

Implementation follows [F1 in the reviewed plan](../../blorp/ARCHITECTURE_FACTS_PLAN.md#f1-prove-a-defaults-written-header-once).
The role dispatch is inline in the existing callback, avoiding a single-use
helper. Production: **16 added / 1 deleted / +15 net lines**. Tests:
**28 added / 0 deleted / +28 net lines**. Documentation is separate.
The F1 landing did not implement F2–F4; later milestone results follow below.

### Provenance and measurement boundary

Baseline: `395731510` (current main after arithmetic operators), not the
earlier `51d98be37` audit snapshot. The initial build at the older snapshot
was superseded before final measurement. Evidence is under
`build/architecture-facts/f1-current/`; the older setup remains under `f1/`.

Pinned seed: `blorp2-seed-9df029bac05b`, full source
`9df029bac05b0d0a39d65325049eaceac1305330`. The seed builds baseline A; A
emits baseline B. Baseline B compiles the candidate compiler source. Each
normal/diagnostic executable pair links the same generated compiler C with
Apple Clang `21.0.0 (clang-2100.3.34.2)`, `-std=c11 -O0 -lm -lpthread`,
differing only in `BLORP_MEMORY_DIAGNOSTICS=0/1`.

Both variants compile the same frozen baseline `src/main.brp` and its complete
import graph with the same frozen target library. Source/library/test hashes,
compiler C and binary hashes, toolchain details and the exact production diff
hash are retained in `frozen-hashes.json` and `provenance.json`.

Three normal CLI samples run serially, alternating baseline/candidate order;
`/usr/bin/time -l` records retired instructions. Separate strict diagnostic
runs record allocations/releases. No Clang compilation/linking or test
execution is inside the measured boundary. The ordinary compiler argv is:

```sh
--library-root build/architecture-facts/f1-current/frozen/blorp_2/standard_library \
build/architecture-facts/f1-current/frozen/blorp_2/src/main.brp OUTPUT.c
```

### Results

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,277,990 | 17,277,974 | −16 (−0.000093%) |
| Retired instructions, minimum of 3 | 49,625,222,134 | 49,620,960,551 | −0.00859% |
| Normal peak RSS, maximum of 3, bytes | 296,943,616 | 294,092,800 | −0.96% |

The instruction difference is noise, not evidence of a speedup. Allocation
and instruction results meet the plan's unchanged +1% ceilings. Every strict
measurement balances allocations/releases with zero live allocations/bytes.

All normal instruction samples:

| Variant | Sample 1 | Sample 2 | Sample 3 |
| --- | ---: | ---: | ---: |
| Baseline | 49,625,320,281 | 49,627,725,770 | 49,625,222,134 |
| Candidate | 49,643,995,846 | 49,642,915,679 | 49,620,960,551 |

All eight frozen-input C outputs (six normal, two diagnostic) are
byte-identical. The candidate also compiles its own changed source:
17,281,556 allocations, strict zero leaks, and 49,628,988,959 retired
instructions in one normal observation. Its own-source normal/diagnostic C
matches baseline B's emission for that same changed source. Own-source counts
are a different workload, not the matched improvement row above.

### Correctness and oracle evidence

- Baseline and candidate each pass all **19 declaration-bound callbacks**;
  both strict runs report zero leaks. Positive behavior is preserved rather
  than presenting the refactor as a new language feature.
- The three new callbacks cover bounded default parameter/return signatures,
  missing default supertrait entailment, and independent authored-method
  header validation. Existing free-header and default-body checks remain.
  Rejections compare the sole diagnostic's message, help, span and absent note.
- In a scratch source copy with F1 applied, bypassing trait-header proof
  produces **17 passes / 2 failures**, exit 1, with zero leaks. The new
  default-header rejection and existing abstract-method rejection fail;
  default body and authored implementation rejections still pass.
  No production source is mutated for this check.
- Generated C inspection confirms the default-role branch returns `Ok(Void)`
  before reading accepted function rows; ordinary roles read the row and call
  the unchanged signature proof, with an invariant error for a missing row.
  A readable inspection excerpt is retained as `header-lambda-readable.txt`.

### Final gate and review

The independent test runner's single `scripts/blorp2-fixpoint --prove` run
passes: B/C compiler-source identity, all **649** candidate A/B fixture
comparisons, **693** component callbacks across 85 suites, and **122**
runtime/native callbacks across five suites. Broader deferred native suites
remain deferred and receive no PASS credit.

A separate baseline-395/candidate comparison also passes **649/649** unchanged
fixtures: exact exit status, stdout, stderr and C, with no normalization.
It compiles each fixture once with baseline B and reuses the candidate B
outputs already retained by the final gate. All 665 fixture/library hashes
match before/after manifests. Evidence: `baseline-fixture-parity.json` and
`baseline-fixture-inputs-{before,after}.json` in the evidence directory.

Code-reviewer and independent test-runner both approve F1 with no blockers.
No resource limits, deferred-suite policy or bootstrap pin change is included.
The previous fixpoint evidence was preserved by move with matching before/after
manifests (4,856 entries, 141,936,550 bytes); it was not used as this baseline.

## F2: private specialization index

`IndexedList` and its four helpers now belong privately to Specialize, their
only production consumer. The old module is deleted. Helper bodies and
storage are unchanged; record settlement/sealing preserves its existing
digest policy, while union sealing still rebuilds its index. There is no new
opaque facade, unchecked transformation API, cache or runtime membership check.

Production: **55 added / 73 deleted / −18 net lines**. Tests, including the
four-line privacy fixture: **178 added / 108 deleted / +70 net lines**.
The Makefile drops one obsolete suite-selection line, counted separately.

### Provenance and costs

Baseline: F1 landing `9f4a9870d`. The baseline binaries are reused only after
verifying all 71 recorded production/library/control hashes against that
revision and matching both executable hashes. Copies, provenance, the frozen
input graph and raw evidence live under `build/architecture-facts/f2/`.
The frozen source retains the old indexed-list module: both compilers process
exactly the same input graph. Normal/diagnostic pairs share generated compiler
C and the F1 Clang/toolchain/flags, differing only in accounting configuration.

As in F1, three normal samples run serially in alternating order through the
ordinary compiler CLI; strict diagnostic runs count allocations/releases.

| Metric | F1 baseline | F2 candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,281,571 | 17,281,571 | 0 |
| Normal retired instructions, minimum of 3 | 49,639,582,742 | 49,640,024,919 | +0.000891% |
| Normal peak RSS, maximum of 3, bytes | 289,685,504 | 293,076,992 | +1.17% |

All instruction samples:

| Variant | Sample 1 | Sample 2 | Sample 3 |
| --- | ---: | ---: | ---: |
| F1 baseline | 49,690,856,534 | 49,639,582,742 | 49,649,497,663 |
| F2 candidate | 49,668,776,849 | 49,651,750,616 | 49,640,024,919 |

Instructions are unchanged within noise; no speed or memory saving is claimed.
Strict runs balance allocations/releases with zero live allocations/bytes.
All eight common-input C outputs are byte-identical.

Cumulative measurement uses the same initial frozen `395731510` compiler and
library input as F1. Initial baseline versus F2: **17,277,990 → 17,277,974
allocations**, **49,625,222,134 → 49,623,576,261 minimum normal instructions**
(−0.00332%, noise). The F2 normal samples are 49,649,983,057;
49,624,676,611; 49,623,576,261. All three outputs and its diagnostic output
match the initial baseline C. Incremental and cumulative allocation/instruction
results meet the unchanged +1% ceilings; no limits were amended.

Compiling F2's own changed source observes **17,281,109 allocations**, zero
leaks, and **49,943,374,422 instructions** in one normal observation. The
historical F1 own-source observation was 49,628,988,959 instructions: the
changed-input observation is approximately 0.63% higher. This is separate from
the matched-input comparison and does not establish a runtime improvement.
Baseline-host, candidate normal and candidate diagnostic C for the same F2
source are identical.

### Coverage migration and mutation evidence

The old direct-container suite is removed only after migrating observable
coverage through ordinary `specialize(CheckedProgram)` calls:

| Former direct assertion | Current phase witness |
| --- | --- |
| Repeated key keeps its first position | Repeated `Box[Int]` shares constructor/layout identities |
| Different keys collide without merging | `Box[Int]` and `Box[String]` share the production origin/arity digest but retain distinct fields and constructors |
| New key in an occupied bucket is absent, then appended | The second concrete `Box` layout is created and referenced correctly |
| No bucket gives no candidate | First `Box` request starts with an empty index; existing multi-origin cases remain |
| Index points at a missing entry | Internal-corruption assertion deliberately lost; no longer externally constructible |

The active native harness checks that importing `IndexedList` from the actual
Specialize module produces the exact private-selection message/help at
`:2:44`. This covers the new external boundary; it does not replace malformed
internal-storage coverage. Existing digest case/id/order/count and pending
record/union/List/callable tests remain.

Baseline and candidate both pass **19/19** focused phase callbacks with strict
zero leaks. Tests follow published record/union identities and constructor
field owners after sealing, beyond counting rows.

An initial 18-case suite did **not** catch bypassed record-field resolution or
discarded record-settlement publication. Its recursive fixture stored an
already-known `Maybe` identity in the record; pending references lived inside
that union. Those surviving runs remain under each mutant's `initial-18/`.
A direct `Tree.Branch(Wrap)` / `Wrap.next: Tree` witness was added, requiring
the record's pending field to resolve to the exact completed union identity.
It also checks repeated requests and is included in existing stage checks.

The final 19-case suite detects each scratch-source mutation:

| Mutation | Result |
| --- | --- |
| Record lookup ignores key arguments | 2 failures: occupied-bucket separation and constructor/layout reuse |
| Record fields skip pending-reference resolution | 2 failures: stage acceptance and the direct pending-field witness |
| Record settlement discards its updated entries | Same 2 failures |
| Record sealing drops the preserved index | 14 failures, including constructor and recursive-layout witnesses |

Every mutant exits 1 with strict zero leaks. Mutants change only scratch Blorp
sources, compiled into ordinary TestSuites; production source was not mutated,
and no generated internal function is called directly.

### Final gate and reviews

Independent code-reviewer and test-runner approvals report no findings. The
single final `scripts/blorp2-fixpoint --prove` run reaches its complete
`FIXPOINT` marker and final artifact line: compiler C identity, **691** active
component callbacks across 84 suites, **123** runtime/native callbacks across
five suites, and **650/650** candidate A/B fixture comparisons pass.

Separately, baseline-F1 versus retained candidate-B outputs match on all
**650 fixtures**, exactly comparing exit/stdout/stderr/C without normalization.
This adds one baseline compilation per fixture and reuses existing candidate
outputs, rather than rerunning component or native gates. All 1,366
source/test/control hashes and 716 source/library/fixture hashes remain
unchanged during their respective checks. The prior F1 fixpoint tree was
preserved by move with verified hashes before replacement.

One evidence-collection limitation is explicit: after the gate completed, its
zsh wrapper attempted to assign to the reserved variable `status`, so the
numeric gate-exit-status file was not captured. The full success output,
individual stage results and final artifact line are retained; the script ends
immediately after that line with no cleanup trap. No numeric exit status was
invented, and no second broad gate was run. `test-runner-review.json` records
this distinction alongside the independent counters/hash checks.

F3/F4 remain outside this implementation. No resource limit, test-deferral
policy or bootstrap pin changes.

## F3: admitted receiver scopes

Check now publishes complete per-module receiver visibility once. Each stored
function candidate holds only its `FunctionId` and introduction span; accepted
signatures remain the contract authority. A function body selects its scope
by module ordinal. Calls read that scope, retaining call-specific type
selection, arity, purity and diagnostic spans. A missing name is a semantic
miss; a missing, duplicate or out-of-range module scope is an invariant error.
Constructor-versus-unknown diagnostics remain a separate namespace query.

The ordinary candidate map is collected directly from namespace entries:
named functions first, then qualifying public functions in method-import order,
deduplicated by identity with the first route anchor preserved. Family and
overlap checks consume that same map in their original per-module inventories
and order. The namespace's existing entry-to-value projection is shared with
`named_value`, preserving all variants and origin rules. No second candidate
authority, lazy lookup fallback or general cache is introduced.

Scopes survive only through body checking. `CheckedProgram` contains none;
generated C drops their list owner immediately after `resolve_functions`
returns (`direct/scope-lifetime-c.txt` retains the inspection excerpt).

Production: **291 added / 196 deleted / +95 net lines**, below the +150
ceiling. Tests: **526 added / 18 deleted / +508 net lines**, including the
new 23-callback suite and three mechanical internal-API migrations. Only one
of those migrated older suites was already active; the other two remain
deferred and receive no PASS credit. Makefile/README/plan/report changes are
counted separately.

### Inputs, revisions and rejected draft

Current measurement baseline is `2972ae0ce`, including the explicit HashMap
key bound. The earlier `1321b6e25` setup was superseded when main advanced.
Baseline A was built by pinned seed `51d98be37bf4`; A emitted baseline B.
The baseline and candidate normal/diagnostic pairs use identical Clang and
flags as F1/F2, with accounting as their only within-pair difference.
Evidence is under `build/architecture-facts/f3-current/`; final candidate
artifacts and measurements are in its `direct/` directory. Frozen source,
library, C and executable hashes are retained with provenance.

The first complete-scope draft repeatedly reconstructed ordinary candidates
per name. It **failed** the unchanged whole instruction ceiling:
**+5.1763% instructions**, +0.47494% allocations. Its target control also
grew +7.5062% instructions and +4.3033% allocations. These failures and the
source diff remain in `failed-preflight.json` / `failed-draft.patch`; they
were not waived or relabeled as passes. Bulk collection removed those repeated
queries and reduced production by another ten lines before final validation.

### Matched costs

Both revisions compile the same frozen baseline compiler source and library.
Three normal samples alternate execution order; separate strict diagnostic
runs count allocations/releases. Startup/input reading and all compiler
phases are included, C compilation/linking is excluded.

| Whole compiler metric | Baseline | Final F3 | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,281,455 | 17,315,746 | +0.19843% |
| Normal retired instructions, minimum of 3 | 49,926,468,300 | 47,372,070,221 | −5.11632% |
| Normal peak RSS, maximum of 3, bytes | 290,734,080 | 289,964,032 | −0.26% |

| Normal compiler sample | Baseline | Final F3 |
| --- | ---: | ---: |
| 1 | 49,973,020,058 | 47,394,824,859 |
| 2 | 49,930,251,816 | 47,376,357,644 |
| 3 | 49,926,468,300 | 47,372,070,221 |

The additional ordinary CLI control declares 128 public Int receiver
functions and makes 256 calls to one of them. Its real main was linked and
returned the expected 255. This exercises complete admission, including
unused eligible names, rather than pruning the domain to observed calls.

| Receiver-heavy metric | Baseline | Final F3 | Change |
| --- | ---: | ---: | ---: |
| Allocations | 136,964 | 140,633 | +2.67881% |
| Minimum normal instructions | 580,736,125 | 583,399,347 | +0.45859% |

All target instruction samples are retained: baseline 581,505,310;
580,736,125; 581,058,053, candidate 585,142,587; 583,558,618; 583,399,347.
No improvement is claimed for this target. All strict runs balance
allocations/releases with zero live allocations/bytes. Eight compiler-input C
outputs and eight target-input C outputs are byte-identical within each group.

The target's allocation result is **FAIL under the original +1%
interpretation**. Both independent reviewers approved an explicit F3-only
minor allocation exception: at most **141,072** allocations (+3% rounded
down), leaving 439 allocations above the reproduced 140,633 observation.
An independent repeat reproduced both baseline and candidate counts exactly.
This amendment follows the owner's standing instruction to handle small
budget adjustments without another prompt. Target instructions, every
whole/cumulative ceiling, fixture limits, zero leaks and C identity remain
unchanged. It is not a waiver for the rejected first draft or other inputs.

Cumulative measurements use F1's original frozen `395731510` source/library:
**17,277,990 → 17,312,662 allocations** (+0.20067%) and
**49,625,222,134 → 47,371,641,483 minimum normal instructions** (−4.54120%).
The final samples are 47,411,706,185; 47,371,641,483; 47,454,816,431.
All three normal outputs and the diagnostic output match the initial
baseline C; both unchanged +1% cumulative ceilings pass.

F3's own changed source observes **17,389,062 allocations**, zero leaks and
**47,776,606,244 instructions** in one normal observation. This changed-input
observation is separate from the matched comparison. Its baseline-host,
normal and diagnostic C are identical.

### Coverage, mutations and final gate

The new active suite checks selected function/method identities and complete
rendered diagnostics (message, help, span, notes and sole error). It covers
ordinary-only and bare-generic names, zero-argument arity, private/public
providers, first/duplicate import routes, inherited-only prelude visibility,
local prelude additions, distinct call occurrences, unused conflicts and
exact local/import/module rejection ordering. Direct admission tests use real
predecessor products and malformed module inventories, not fabricated contexts.

All **23** receiver callbacks and **18** existing active supertrait callbacks
pass together with strict zero leaks. Two scratch-source mutation proofs
compile and run ordinary TestSuites: omitting ordinary candidates fails
15/23 callbacks; admitting a family/function conflict fails the specific
family-before-overlap callback (1/23). Both exit 1 with balanced accounting.
Production source was not mutated for these checks.

The independent single `scripts/blorp2-fixpoint --prove` run exits **0**:
compiler fixpoint C identity, **714** active component callbacks, **123**
runtime/native callbacks and **650/650** candidate A/B fixture comparisons
pass. A separate baseline-2972/B comparison also passes **650/650**, exactly
matching exit/stdout/stderr/C (530 accepted, 120 rejected). All 1,368
source/test/control inputs remained unchanged; the comparison preserved
all 2,480 reused B output files and 668 inputs (650 fixture files, 16 library
files and two compiler binaries). The previous F2 proof was copied with
verified hashes before replacement.
Deferred suites receive no PASS credit.

Main subsequently received a bootstrap-only update, `c1de434f4`. It was
incorporated without changing any Blorp source. The new pinned seed
`blorp2-seed-2972ae0ce09e` emits byte-identical F3 compiler C to the reviewed
and tested artifact (`direct/landing-seed.c`); the unchanged tests were not
needlessly rerun. Measurements still describe the frozen 2972 baseline and
their recorded toolchain.

Independent code-reviewer and test-runner approvals cover the source and
evidence; both separately approve the bounded target allocation amendment.
No F4 implementation or additional test-deferral/fixture-limit change is included.
