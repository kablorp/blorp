# Dynamic global initializer scope fix

Large managed global constructor lists could exceed Clang's default nesting
limit. Ownership balancing preserves each list result in a derived temporary
before releasing an element. Emission wrapped each remaining tail in a GNU
statement expression, making C nesting grow with the list length.

A private immutable admission fact is computed once per dynamic initializer.
It accepts a closed constructor spine with canonical compiler temporaries,
unique final C identifiers, valid lexical references and selected type names.
Only admitted derived ownership-result RHS scopes emit sequentially. Other
initializers and ordinary function expressions retain their existing scopes.
The original Core RHS still reaches the binding/cleanup helper, preserving
owner bookkeeping, evaluation order and the temporary cursor.

The production change is confined to `stage_10_backend/emit.brp`: 182 added,
9 removed, **173 net handwritten production lines**. The Core suite adds 269
and removes 2 lines; the new runtime fixture has 376 lines, **643 net test
lines**. No ownership pass or Core data model changes.

The identity census amendment adds exactly six reviewed site keys and raises
five affected count caps: backend `id` 17→19, `name` 132→134, spelling predicates
13→14, C projections 25→26 and string dictionaries 225→229. These sites validate
discard spelling, selected type symbols and final C namespace collisions. The
seven new member-read rows remain heuristic inventory; three `def_id` reads
raise the actual count from 36 to 39 within its existing cap of 40. All prior
keys, unrelated limits, classifications and boundary/capability metadata remain
unchanged. This is accounting for the repair, not an identity-debt retirement.
A scratch seventh dictionary still fails both the unseen-key and count-cap
checks; admitting its key alone still fails the cap. The original gate STOPs
are retained separately from post-amendment completion.

## Correctness evidence

The public reproduction uses 300 references to three prior managed record
globals. Literal-only lists take an existing fast path and are not a useful
reproduction. The 300-element case is sufficient; it is not claimed minimal.

On clean `5b4b9467b11061ea1d77c76045ceb5f61f074398`, Linux Clang 18 reports
`bracket nesting level exceeded maximum of 256` at the first raw brace depth
257 in `__blorp_init_globals`. The captured actual native input and forced
runtime header are retained. Neither the compiler limit nor artifact flags
were changed.

Focused fail-before: seven conservative fallback controls pass, and the
sequential ownership-result emission control fails. Pass-after: all eight
pass. The three runtime regressions check order, shared-list append and record
copy-on-write behavior. Those ordinary tests keep the container alive; shutdown
ownership is checked separately with sanitizer and leak runs.

The public final Core is byte-identical across the change, SHA-256
`f863a6e92c476a204e7e981dc1b2f41c07096316aa8d427de7008bea64cf2d08`.
Generated C outside `__blorp_init_globals` is byte-identical. Its ordered 902
retain/allocation/release-hook/append/release calls match, including 300 retains,
appends and releases. All 600 Core locals remain distinct. Initializer lexical
brace depth falls from 302 to 3; the whole C artifact's maximum falls to 7.
These lexical counts do not model preprocessor expansion; actual default-limit
Clang execution is the acceptance oracle.

The rebuilt Linux candidate passes the public reproduction with default
Clang 18 flags. Public and runtime AddressSanitizer/UndefinedBehaviorSanitizer
runs pass; captured native invocations prove the sanitizer flags were present.
The standalone public shutdown report records **307 allocations, 307 releases,
zero leaked objects and zero bytes**. The runtime suite's report also has zero
leaked objects and bytes (its test measurement epoch reports three allocations
and releases; it is not the global-initialization allocation count).

| Check | Result |
| --- | --- |
| Six owning backend suites | 442 passed, 0 failed |
| Core sanitizer | 2,634 passed, 0 failed |
| Generated-C audit | 238 passed, 0 failed |
| Standard leak gate | 1,254 passed, 0 failed |
| Broader compiler gate | 7,289 passed, 0 failed |
| Census unit tests | 32 passed, 0 failed |
| Strict magic, census, hygiene, whitespace and FRESH | PASS |

Counts overlap and are not a unique sum. Compiled results are preserved from
the original attempt; after the stale final command path and census STOPs,
only the remaining static checks were run against the reviewed metadata.
The [composite completion](compiler_c_initializer_nesting_2026-10-08/gates/reconciled/FINAL_RESULT.json) links
both preserved STOPs and their original compiled PASS records. Exact commands
and logs remain separate; a STOP is not rewritten as a successful attempt.
The equivalent retained stage-two-to-three fixpoint passes: both ordinary
builder generations emit **84,974,862 identical bytes**, SHA-256
`bc7a127b8ae89668ccf099b3f716e30a75b80f60ba6e92e840f87a8d6d2d17b9`.
The previously validated ordinary stage-two build is reused, followed by an
ordinary stage-three build and C-only generation. Both read the current
candidate source. The `scripts/compiler-fixpoint` wrapper itself was not run.
The [fixpoint record](compiler_c_initializer_nesting_2026-10-08/fixpoint/FINAL_RESULT.json) and actual release
receipt retain the ordinary builder/version/whole-C checks. Final integrated
premerge remains a separate landing gate.

## Cost boundary

Baseline and candidate use ordinary `-O2` stage-two compiler pairs, matching
normal and diagnostic builds, the same frozen `5b4b9467` self-compile input and
unchanged small program. Normal and diagnostic C must agree within each pair.
The intentional baseline/candidate C difference is covered by generated-C
review, behavior, ownership and fixpoint checks.

The acceptance ceiling was fixed before candidate measurement: allocations
and minimum retired instructions may increase by at most 1% on both workloads.
Three instruction samples are retained per workload; elapsed build time is
not an efficiency claim. The four original resource records are retained as
privacy projections: [baseline self](compiler_c_initializer_nesting_2026-10-08/cost/baseline/baseline-self.json),
[baseline small](compiler_c_initializer_nesting_2026-10-08/cost/baseline/baseline-small.json),
[candidate self](compiler_c_initializer_nesting_2026-10-08/cost/candidate/candidate-self.json) and
[candidate small](compiler_c_initializer_nesting_2026-10-08/cost/candidate/candidate-small.json).
The [comparison](compiler_c_initializer_nesting_2026-10-08/cost/candidate/comparison.json) preserves the exact
integer ceilings and within-pair output qualification.

| Workload / metric | Baseline | Candidate | Change | Result |
| --- | ---: | ---: | ---: | --- |
| Self allocations | 284,086,867 | 284,099,387 | +0.004407% | PASS |
| Self minimum instructions | 271,222,687,541 | 270,826,570,677 | -0.146049% | PASS |
| Small allocations | 1,753,167 | 1,753,167 | 0% | PASS |
| Small minimum instructions | 1,654,609,705 | 1,654,994,443 | +0.023252% | PASS |

Small generated C is byte-identical across the change. Self C changes only
inside global initialization: 38 DropTemp wrappers become sequential aliases.
Exact reconstruction yields the candidate bytes; all 1,113 local declarations
and 1,672 ordered ownership/list/cleanup lines remain unchanged. Other global
initializers retain their scopes. These results show acceptance within the
declared ceilings, not a broad speed claim.

The original Mono reader cut has a separate 0.5% ceiling. This fix's cost
acceptance does not establish acceptance of that cut.

## Scope and review

Source and emitted-C review both report zero findings. Unsupported calls,
mutable/source/borrowed bindings, branches, exits, unknown raw struct names,
cached derived-name mismatches and output-name collisions fall back to lexical
emission. This is a bounded emitter repair, not generic scope normalization.
Other unusually large unsupported initializers remain separate work.

The bounded fix components are accepted. The final [test-runner report](compiler_c_initializer_nesting_2026-10-08/TEST_RUNNER_REPORT.md), [independent component review](compiler_c_initializer_nesting_2026-10-08/review/FINAL_COMPONENT_REVIEW.md), [source review](compiler_c_initializer_nesting_2026-10-08/review/ACTUAL_SOURCE_REVIEW.md), [self-C review](compiler_c_initializer_nesting_2026-10-08/self-c-review/SELF_C_REVIEW.md) and [resource review](compiler_c_initializer_nesting_2026-10-08/review/RESOURCE_REVIEW.md) distinguish this acceptance from pending integration work.

Evidence publication is a privacy projection, not verbatim raw evidence. The
[projection manifest](compiler_c_initializer_nesting_2026-10-08/PROJECTION_MANIFEST.json) records original decoded,
projected decoded and stored hashes for every payload. Only private checkout,
evidence, home/cache and temporary paths, plus machine/builder host labels,
are projected. Command flags and argument order, metrics, source/binary hashes,
timestamps, versions and platform facts remain intact. Logs use deterministic
lossless gzip. Original raw records and large C/binary/source inventories
remain private under explicit hashes.

Validation, measurements and fixpoint retain their historical source authority
`5b4b9467b11061ea1d77c76045ceb5f61f074398`. After the batches closed, integration
preserved the existing local commit `98983aa8f512116239a202e66ad7b5cc556c4fec`,
which changes two nonpaying benchmark tuple-tag lines. Compiler, tests, census
and paying source bytes remain unchanged; this does not relabel the original
records as measurements or a full-tree freeze of that newer commit.

Pending: the separate Mono-only comparison with its 0.5% ceiling and full
combined host/Linux landing gates. Neither is established by the bounded fix
checks or this publication packet.
