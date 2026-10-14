# Multiple union fields

Status: implementation, focused validation, mutation oracles, quiet matched
costs and combined sanitized/full e2e validation pass. Two independent compiler
experts approve the source and final evidence: zero P0–P2 findings, one
nonblocking P3 recorded below. This accepts the multiple-field increment in the
[roadmap](../../blorp_2/ROADMAP.md).

## Behavior and published facts

Variants admit ordered fields, for example `Pair(String, String)` and
`Fields(Int, Float, String, Void)`. Construction evaluates written children in
order; patterns bind names or discard individual positions with `_`. Nullary
variants remain distinct from a one-field Void variant. Exact arity, duplicate
binder, annotation/module/type-parameter and finite-cycle errors retain typed
identities, teaching help and written spans.

One ordered constructor base replaces the unary postfix path. Parsed field
annotations resolve through the existing ordinary type authority. Checked and
concrete field vectors are complete immutable facts; standalone projections
carry a validated nominal variant plus ordinal. There is no second field table,
spelling-derived meaning or incomplete published type.

Each managed stored occurrence acquires its own obligation, even when two slots
contain the same value/pointer. Sequential verification consumes each obligation
once, checks the actual parent, field, type and live borrow backing, and rejects
empty raw constructed operations beside a valid nullary leaf. A same-typed
alternative ordinal can be memory-valid; lowering and native exact-value tests
observe source semantics rather than inventing historical binding verification.

Nonempty variants use one uniform C projection:
`.payload.blorp_up_<variant>.blorp_uf_<field>`. Unary C therefore deliberately
changes; nullary tags do not acquire an empty C struct. Dup/drop traverses every
active stored field, including independently owned repeated pointers. This
feature adds no separate union heap root or consuming language-call ABI.

## Tests and evidence to finalize

Ignored evidence entrypoint: `build/roadmap/multiple-payloads/`.
`HANDBACK_IMPLEMENTED.md`, `raw/HANDBACK.md`, `native/results.md`,
`cost/results.md`, `cost/independent-review.md` and recorder packets preserve
inputs and exact results. Intended first-red and setup-only failed runs are
distinguished.

- Focused typed/grammar: 657 checks across 33 suites, including 26 new callbacks.
- Raw verification: 170 checks across seven suites, all 151 old callbacks plus
  19 new independently authored checks.
- Runtime helpers: 60 preserved C cases plus 12 new cases, all passing, using
  actual production fragments and real allocation/free occurrence observers.
- Native group: seven real-main programs and eight exact rejection commands,
  observed through 11 group callbacks; five additional approved C inspections.
- Both old/new Clang layout inspections cover nine record and three unary union
  shapes with matching size/alignment. This is not a global ABI-stability claim.
- Stress: all 16 feature programs compile with strict C11/O0, ASan/UBSan and
  default Clang limits, then produce exact real-main outcomes.
- Cleanup mutation: nine intended new C assertions fail and 63 controls pass;
  exact emitter restoration returns all 72 checks to green.
- Lowering mutation: only the second-field ordinal unit oracle fails (25/1).
  A separately labelled mutant pilot executes the duplicate-first control
  successfully and prints `7\n` instead of `42\n` for distinct-second escape.
  This is normal-main semantic evidence, not an alternate internal driver.
- Ownership mutation: 39 passing checks and exactly two failed duplicate-slot
  observers; all 15 old unary controls pass. Exact restoration returns 41/41.
- Verifier mutation: 18 controls pass and the exact second-discharge observer
  fails. Later conservation still rejects this malformed complete program; the
  oracle proves the early diagnostic boundary, not whole-program acceptance.
  Exact restoration returns 19/19.
- Final sanitized unit/runtime/grammar: 1,975 printed checks across 124 suite
  summaries, exit 0, zero failures, no source drift, 24.997 seconds. The strict
  launcher reports three balanced allocations/releases and zero leaked bytes;
  this counter is not a count of all compiled child processes.
- Final normal build-once e2e: 321 cases; 762 printed passing checks across
  309 suite summaries, exit 0, no timeout/source drift, 169.039 seconds. The
  wrapper records exactly one pilot generation and link.

The first full e2e run passed 320 cases and failed one existing match rejection
callback. Its expected text still described the retired unary Int contract.
An isolated normal compiler invocation establishes the new field-count
diagnostic at the same location. The unchanged public callback fails before and
passes after migration of that one expected message/help string; all source,
exit-status, no-publication and sentinel-output preservation checks remain.
No production change was needed. The fresh strict/full reruns above include
that reviewed correction; the initial failed packet remains retained.

The host's nested singleton List/Option pattern defect is separately reproduced
in `HOST_PATTERN.md` and independently reviewed. Five test observers use exact
length/index and separate Option matching while retaining all original identity,
type and owner assertions. No host production fix or weaker pilot oracle is
claimed. Native LeakSanitizer is unavailable on this Apple toolchain; ASan/UBSan,
compiler strict counters and exact helper destruction observations are distinct
evidence.

## Costs, provenance and limits

Branch `codex/blorp-2-aggregate-roadmap`, HEAD `79deebd`. FRESH host SHA
`286a1720a36a75599f910e1b8ab838df642a3983409cd30ed3a6ef3dcf16ba79`,
Apple Clang 21 arm64, host CLI O0/runtime O2; pilot O0 with diagnostics.
Immutable accepted direct-unary baseline source archive is
`add34e836f3f0614703fdf38f92239e8ced1314aa3272233d12167b3b0bff372`,
compiler `0ebc82ccfae396561ab47410ecda48c1ee5725934db50c96f15f696382f95be2`.

`review-final-2/sha256.txt` records final identities:

- Source archive: `29af2e7455beced2aece90a810b634fafa750cff4a0ba557dbc8aadfcc6872b3`.
- 503-input manifest: `9d340713dcfc6c3398983484f4e85c4aab9665d7a1069ff63229f39109076b52`.
- Frozen native/cost compiler: `218ab7763c927a8bc15c1ca2730cc839f043e8fc02385cc074337a46b841bf2b`.
- Generated host C: `aaa533029b7acca5bddae77a43f0c23d6fad2687490d2076abfaac453bccbab5`.
- Final full-wrapper executable: `966f0e333cfe43a3ec06f939fb1fd316722979341bd8a9bc1ff6684ca5dba95e`.

The final wrapper produces the identical frozen host C, with its separately
linked tested executable retained in `final-e2e-2/`. Costs used the previous
`review-final` snapshot; the final snapshot changes exactly the one e2e expected
diagnostic. All producer sources, binary/C and 43 frozen cost inputs remain
identical. The earlier manifest matched all 503 files at its review epoch; it
is not falsely claimed to match the later corrected e2e file.

Twenty frozen controls, three matched samples each: all 120 invocations balance
strict counters and meet unchanged +3% allocation/instruction ceilings. Maximum
allocation increase is +0.9861% (wrap32); maximum minimum-of-three retired
instruction increase is +1.3893% (wrap64). Twelve unaffected controls have 36
identical C pairs. Eight unary controls have 24 deliberate layout changes,
covered separately by native layout/value/ownership checks. Sixteen new feature
points contribute 48 balanced samples and 32 repeat-C identity comparisons.

At widths 16/32/64/128, scalar-field allocations are
13,186/15,370/19,713/28,377; String-field allocations are
15,697/18,505/24,096/35,256. Distinct-instance instructions grow superlinearly:
124,988,476/204,448,152/406,147,907/965,778,173. The baseline rejects the new
syntax, so these are candidate feature proxies, not baseline improvements or
self-compilation. Quiet before/mid/after inventories show no other active named
compiler processes; samples cannot exclude unrelated work between observations.

These candidate-only widths do not prove whole-compiler linearity. Independent
generated host-C inspection establishes inherited repeated copying in ownership
use-vector updates and lowering definition-prefix threading. New capture,
stored-owner, scheduler and freeze vectors use direct local consuming updates.
`C-ownership.md` gives exact chains; `performance-decision.md` requires bounded,
separately reviewed preparatory remedies before General List implementation.
The unused `uses`/`position` parameters in `build_definition` are one nonblocking
P3 cleanup, deferred to that owning preparation without removing last-use/drop
scheduling outside the helper.
The [accepted owning follow-up](blorp_2_ownership_builders_2026-10-13.md) now
resolves that cleanup and the use-vector copying mechanism. Lowering-prefix
preparation remains later work; the original candidate evidence above is unchanged.
Existing nominal-instance scans and duplicate-binder scans also remain visible;
no cache/index, host rewrite or speculative ownership optimization is included.

Production decreases 44 physical / 25 nonblank noncomment lines across nine
modules versus accepted direct-unary source. Typed/grammar tests grow 660/590;
raw tests grow 535/445. Native/runtime tests and fixtures grow 746 physical lines,
independently recounted against the accepted source archive; root registration
adds two. Test totals include schema migration alongside new observations.
No reduction depends on compressed formatting or deleted tests.

General Lists, functional updates, recursive data and broader managed/generic
tail loops remain separate unimplemented milestones. No commits or pushes had
occurred at validation time.
