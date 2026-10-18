# Demand-loaded Option/Result helpers — read-only proposal

## Problem and current evidence

Accepted tracked-plan base: `7acd6df25c4fe62c726614e8e9ea970071c35f73` (M2 landed); the historical draft reference `fb5fe691dc722918e8f29fa5b17d8fe9b45e5341` is explicitly reconciled to this base. Cost B remains unfrozen: root must name it before any feature setup or first sample. Plan-worktree creation does not freeze cost B. Parent/pilot AGENTS and `docs/HANDOFF_SPEC.md` were read; current host import/UFCS rules were checked in GUIDE540–635, GRAMMAR31–39 and the host prelude. A separately reviewed tracked plan precedes implementation; no compiled job follows from this document. The separate append prototype383947, B5b and its failed epoch remain untouched; this proposal does not roll that baseline.

These real source requirements lack temporary operation modules:

| Host signature and declaration | Actual compiler caller / receiver |
| --- | --- |
| `option.is_some[T](self: Option[T]) -> Bool`, host `standard_library/src/option.brp:50` | `blorp_2/src/check/bodies.brp:105`, `find_variant` returns an Option. |
| `option.is_none[T](self: Option[T]) -> Bool`, host `option.brp:66` | `src/load/load.brp:156`, `known: Option[RequestedModule]`; also inference retained hints at372/409. |
| `option.get_or[T](self: Option[T], default_val: T) -> T`, host `option.brp:85` | `src/load/load.brp:167`, `site: Option[Span]`; inference579 unwraps `Option[Option[InferenceType]]`. Two-argument List.get_or calls are a different API. |
| `option.to_result[T,E](self: Option[T], error: E) -> Result[T,E]`, host `option.brp:204` | `src/check/signatures.brp:117`, optional entrypoint; explicit import at `src/check/inference.brp:35`. |
| `result.is_ok[T,E](self: Result[T,E]) -> Bool`, host `standard_library/src/result.brp:35` | `src/check/recursion.brp:181,183`, `checked: Result[Void,CheckError]`. |

Unqualified `src/` anchors are under `blorp_2/`. This is a bounded manual map, not a resolved inventory. Host Option/Result are declared in their host modules; target ownership stays with existing `_base.brp:13–19`. Do not copy host union declarations, traits, hashing, callbacks or whole modules.

## Proposed solution and exact code

One library writer owns only new `standard_library_temp/option.brp` and `result.brp`, tests and bounded docs. **Prelude is unchanged.** `_base` keeps Bool/Option/Result and constructor identities; operation modules import those exact types, without an implicit prelude. Option imports `_base.Result` directly, not result operations. New operation-module exports are functions, not replacement type declarations/reexports. No builtin/designation change follows.

Proposed `option.brp` (currently absent):

```blorp
import:
    _base: Bool(True, False), Option(Some, None), Result(Ok, Err)

pure func is_some[T](self: Option[T]) -> Bool:
    match self:
        Some(_): True
        None: False

pure func is_none[T](self: Option[T]) -> Bool:
    match self:
        Some(_): False
        None: True

pure func get_or[T](self: Option[T], default_val: T) -> T:
    match self:
        Some(value): value
        None: default_val

pure func to_result[T, E](self: Option[T], error: E) -> Result[T, E]:
    match self:
        Some(value): Ok(value)
        None: Err(error)
```

Proposed `result.brp` (currently absent):

```blorp
import:
    _base: Bool(True, False), Result(Ok, Err)

pure func is_ok[T, E](self: Result[T, E]) -> Bool:
    match self:
        Ok(_): True
        Err(_): False
```

Current `standard_library_temp/prelude.brp:3–8` remains literally unchanged. A consumer requests only operations it needs; this exact header works with host modules and the proposed temporary modules:

```blorp
import:
    option: is_some, is_none, get_or, to_result
    result: is_ok
```

Host prelude already enables Option/Result methods; explicit named imports also enable direct calls/UFCS and repeated exposure of the same function is idempotent. Target prelude supplies `_base` types/constructors but no Option/Result operations: named function imports provide both call styles. No zero-import parity is claimed. `load/load.brp:306–328` seeds root/base/prelude, and link_module:250–258 follows written imports; unreferenced new files are not discovered or checked. Thus unrelated programs keep their loaded graph by construction; verify unchanged C/diagnostics/costs rather than waive gates. The current fixture/embedded-source scan found no preexisting explicit option/result operation import; this is not a full resolved inventory.

### Separate future SOURCE import migration — not this feature

After feature acceptance and separate SOURCE-policy approval, these real import edits preserve bodies under BOTH libraries:

```blorp
-- src/check/inference.brp:35, before
    option: to_result
-- after; existing .is_some/.is_none/.get_or/.to_result calls stay unchanged
    option: is_some, is_none, get_or, to_result

-- src/load/load.brp:5, before
    option: to_result
-- after; site.get_or(...) and known.is_none() stay unchanged
    option: is_none, get_or, to_result

-- src/check/recursion.brp:34, retain existing option import and add
    option: is_some
    result: is_ok
-- existing checked.is_ok() at181/183 stays unchanged
```

Only import operations actually used per file. The migration gets its own bounded LOC/cost review; no source edits, SOURCE waiver or self-compilation claim belongs to this library increment.

Get_or evaluates its default argument normally even for Some; this is not get_or_else. Inputs are borrowed. Managed get_or returns independently owned payload/default references; to_result retains the selected borrowed child/error into its ordinary owning result. Predicates return unmanaged Bool and must not consume managed arguments. No fresh String allocation is needed inside these helpers. UTF-8/NUL contents pass unchanged; no String representation or ASCII refinement follows.

## One real-main witness

Proposed `test/e2e/fixtures/generic/managed/option_result_helpers.brp`, registered in existing `test/e2e/test_generics.brp` through its normal harness:

```blorp
import:
    io: print
    list: get
    option: is_some, is_none, get_or, to_result
    result: is_ok
pure func payload(value: Result[String, String]) -> String:
    match value:
        Ok(text): text
        Err(error): error
pure func truth(value: Bool) -> String:
    match value:
        True: "true"
        False: "false"
func printed(value: String) -> String:
    print(value)
    value
func main() -> Int:
    missing = get(["unused"], 1)
    fallback = "fallback"
    print(Some("é\0").get_or(printed("eager")))
    print(get_or(missing, fallback))
    print(fallback)
    ok = Some("ok").to_result("unused-error")
    error = missing.to_result("error")
    print(truth(Some("kept").is_some()))
    print(truth(missing.is_some()))
    print(truth(Some("kept").is_none()))
    print(truth(missing.is_none()))
    print(truth(ok.is_ok()))
    print(truth(is_ok(error)))
    print(payload(ok))
    print(payload(error))
    0
```

Exit0, empty stderr, exact stdout `eager\né\0\nfallback\nfallback\ntrue\nfalse\nfalse\ntrue\ntrue\nfalse\nok\nerror\n`. The `eager` line observes normal default evaluation even for Some; the impure printed helper/nested-call shape already exists in `effects/nested.brp`. Ownership callbacks must show temporary roots retire safely while returned Strings remain owned; fallback/result snapshots survive earlier calls. All five operations are explicitly imported; both direct and UFCS routes are exercised. No pure zero-argument empty factory remains. `get[T](List[T],Int)->Option[T]` matches host list:68 and target list:9; the String element fixes T, absent index1 yields typed None. Do not invent `None[String]`: explicit call type arguments are deferred (grammar122/parser1207), and local binding annotations still reject (check/bodies723–724). No new language feature is required by this witness. Before code capture the real missing-module/name red with exact message/help/span; none was run here.

## Granular tests and acceptance

Reuse parser generic/header/tail-match coverage; no grammar feature or mechanical new parser suite. Add only focused callbacks in existing suites:

- `test/unit/test_load/test_load.brp`: operation files remain unloaded without explicit imports and enter the sealed module inventory when selected; compare published module facts, not source-text patterns.
- `test/unit/test_check/test_generics.brp`: public named/method routes retain `_base` owners, rigid T/E signatures and exact payload/default/result types.
- `test/unit/test_specialize/test_generic_unions.brp`: concrete Int/String get_or, mixed String/Int to_result, and actual-caller `Result[Void,String].is_ok`; assert published constructor identities/field types, not spellings.
- `test/unit/test_own/test_managed_union.brp`: get_or acquires the borrowed selected String before return in both arms; to_result acquires only the selected child/error; predicates consume neither borrowed root nor payload. Reuse independent raw Option/Result verifier and runtime-helper suites; add no duplicate malformed-IR matrix or new ownership form.

Existing managed generic unbox fixture `generic/managed/basic.brp` establishes the language shape, not helper acceptance. After coordinator-named source-matched artifacts/budget approval, the narrow command is:

```sh
"$HELPER_HOST" test --suite --std-dir "$HELPER_HOST_STD" --timeout 180 blorp_2/test/unit/test_load/test_load.brp blorp_2/test/unit/test_check/test_generics.brp blorp_2/test/unit/test_specialize/test_generic_unions.brp blorp_2/test/unit/test_own/test_managed_union.brp
```

Then run the new normal-main callback, full components/e2e and matched shared controls under the existing harness. Separately break a predicate arm, replace get_or's `Some(value): value` with `Some(value): default_val` while leaving `None: default_val` unchanged, and omit selected-child acquisition; require the owning oracle to fail and restore exact bytes. The get_or mutant remains valid source and must fail the output oracle, not setup. Root/expert review precedes maintained plan commit and implementation.

## Bounds, dependencies and stop

Prospective physical ceilings: production50 gross/+50 net, tests300 gross/+300 net, one fixture60 lines, implementation docs20. No compiler/native production edits. Proposed new-fixture ceiling40,000 compile allocations/200M normal-min3 instructions is unmeasured and requires review; it does not widen any existing limit.

**Cost feasibility still UNVERIFIED.** Shared programs with no new imports should retain their graph and costs; all unchanged +5% allocation/normal-min3 and inherited absolute11500/65M guards, or tighter fixture-owned caps, remain binding. API-using programs newly load/validate the selected module's helpers; measure them against reviewed new-input caps, never fabricate a successful B. The append +5.31%/+5.82% failures remain FAIL and are not relabeled by this explicit surface. Demand loading is the public API design, not a counter exemption. Any shared absolute/relative breach stops; no automatic widening, special case or new builtin. Explicitly reconcile the accepted planning base before feature setup, then freeze the coordinator-named fixed B, exact C, current source-matched normal/diagnostic pilots and host/library/corpus before samples; no silent baseline roll or refreeze after failure. Runtime retains do not prove compiler costs.

### Prospective FEATURE proxy roles and metric

Use the original schema-1 `artifact_construction_complete` checkpoint and original host inputs. This is a prospective, unfrozen proposal correction; it neither extends append's FULL exit TOTAL exception nor rewrites any existing sample, budget or verdict. Original SOURCE roles and contracts remain unchanged.

| Role | Exact artifact and pin |
| --- | --- |
| Normal producer/proxy | `/Users/keithphilpott/.codex/worktrees/host-utf8-file-admission/blorp/bin/blorp-stage2`, SHA256 `34ac1a913c79fc14130c77fe4339f24885a2fa65f1d25fc4b873b627e10e1f33` |
| Diagnostic proxy | `/Users/keithphilpott/.codex/worktrees/host-utf8-file-admission/blorp/bin/blorp-stage2-diagnostic`, SHA256 `be31a5a3a070deef54707d8676a7c6157042484f40d0424dd5fb46835c09ff93` |
| Explicit original host library | `/Users/keithphilpott/.codex/worktrees/host-utf8-file-admission/blorp/standard_library/src`, Git tree `090ed68c5bd688cb8e2197c72bc572e4dc32e6d7` |
| Original 598 host/source pins | `/Users/keithphilpott/.codex/worktrees/bootstrap-carried-current/blorp/build/carried-current-port/cost-preparation/original-source-598.sha256`, manifest SHA256 `bea8dc2fc442fcbeff9c3935de3935cde2237588c08bb7de6920f3850b8a85c2`; verify all members before setup |

Normal proxy calls compile `blorp_2/src/main.brp` with `--std-dir` selecting that original library, `--no-format`, one fixed canonical output path, and `/usr/bin/time -l`. Unset `BLORP_CC`, `BLORP_LEAK_CHECK` and `BLORP_MEMORY_STATS`; require exit0, exact generated-output stdout and empty stderr. Sample order is B1,C1,C2,B2,B3,C3; compare each variant's minimum of three positive retired-instruction counts under the prospective +5% gate.

Diagnostic B/C proxy calls use the same compile arguments and explicit library, unset `BLORP_CC` and `BLORP_LEAK_CHECK`, and set `BLORP_MEMORY_STATS=1`. Require exit0, exact generated-output stdout and exactly one schema-1 `artifact_construction_complete` checkpoint with one positive `total_allocations` field; allow only valid schema-1 checkpoint records in stderr. Apply the separate +5% allocation gate to that construction checkpoint, never exit TOTAL and never a subtracted/normalized count. Preserve full raw C and compare diagnostic/normal output to each variant's producer C. Compiler source and host library are identical across this library-only B/C, so also require exact B/C proxy C. The proxy does not consume the new target operation bodies and does not prove self-compilation or their runtime execution.

`/Users/keithphilpott/CLionProjects/blorp/bin/blorp`, SHA256 `c04f68ba64ac06f6cd3f924cdb4d87ce6b3d40d0f8fba2ef89b20e324b21ca57`, with explicit ROOT host library remains FUNCTIONAL only. Its host library is `/Users/keithphilpott/CLionProjects/blorp/standard_library/src`, Git tree `e34e2fbb50ec0d19b143f6041d869165a973a8c8`; the 91-member manifest at `/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/write-file-e906-01/current/cost-preparation/host-std.sha256` has SHA256 `d34b7233333654a50867c7efb1f7fa1942f8d039978064f9407e79c00d78e84b`. It replaces neither original producer/proxy nor SOURCE role. Target strict observations still require positive balanced allocations/releases and zero leaks under all inherited shared/absolute gates. Root must review these roles and the current source-matched target pilot choice before setup; this plan creates no controller or cost artifact.

Dependencies: independent compiler-expert AND ergonomics review of explicit imports, `_base` ownership, eager defaults and test oracles; root review/maintained plan commit before implementation; source-matched current artifacts and approved fixed FEATURE contract. Do not reuse append6e merely because it parses this witness. Later SOURCE import migration waits for this feature and its own policy approval. HOF/trait/builtin/ownIR/opaque/control/path changes and M6/M8 completion remain out of scope. If any required syntax/ownership shape is unsupported, stop rather than implement a new language feature.
