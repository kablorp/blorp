# Self-compilation workstream register — 2026-10-18

Companion to [SELF_COMPILATION_HANDOFF.md](SELF_COMPILATION_HANDOFF.md).
Statuses describe the exact held candidates, not current-main capabilities.
All seven app subthreads were asked to leave stable checkpoints for transfer.
None of the feature candidates below is landed unless explicitly stated.
Paths are local recovery locations; preserve uncommitted files and ignored
evidence before archiving. Each table gives the actual working tree, which may
differ from the app thread's original checkout.

The problem is unfinished work distributed across private candidates and
retained evidence. Resume by recovering the named source/artifact identities,
reviewing the existing next-command packet, and assigning a serial execution
window through the coordinator. Acceptance requires the owning expected exit,
streams, diagnostic/callback results and unconditional mutation restoration,
followed by current-base integration acceptance before marking work landed.
The handoff's [runnable acceptance section](SELF_COMPILATION_HANDOFF.md#execution-review-and-runnable-acceptance)
owns the common commands; no second runner is required.

## App subthreads

| Thread title and ID | Working trees / branches | State and next step |
| --- | --- | --- |
| **Blorp 2 joins and managed control flow** — `01a14aed-bbeb-73a2-8734-9650c7f520ea` | `restricted-control-plan/blorp`, `codex/restricted-control-plan` | Restricted-if implementation authored. Latest run: 17/21 pass; four fixtures were invalid pure Void declarations. Fixture-only repair `71e8668d`, full candidate `5bd798f4`, is **unrun**. Review repair, rerun the same 21 assertions, then complete native/full acceptance. Top-level propagation remains design work. Reassigned-variable join carriers are already **landed** at `7acd6df25`; reuse them. |
| **Blorp 2 ordinary opaque type support** — `01a14aed-cd4b-7153-801d-7d279777f969` | `opaque-m2-composition/blorp`, `codex/ordinary-opaque-m2-composition` | Semantic-key preparation and opaque feature authored; full standalone component/e2e run green. Not accepted/landed. Review the preparation separately, current-base composition and pending acceptance. Optional phase benchmark is drafted, entirely unrun. |
| **Blorp 2 first-order library and shell** — `01a14aed-d438-73f0-b1d6-da1e2b5d7279` | `option-result-composition/blorp`, `codex/option-result-composition`; `loader-shell-plan-recovery/blorp`, `codex/loader-shell-s1` | Option/Result helpers: effective 18 mutations/restored controls and full standalone functional green. Current-base acceptance pending. Loader S1 authored and 54 focused checks passed; original pinned host library lacks `get_current_directory`, so compatible host/library composition must be explicit. Actual full shell integration incomplete. |
| **Blorp 2 first-order source migration** — `01a14aed-b82a-73a1-a02a-fbe2ce49b412` | `first-order-written-fields/blorp`, `codex/first-order-written-fields`; `int-ordering/blorp`, `codex/int-ordering` | Written-field translator accepted: current full functional/native gates and all 4,032 fixed-B SOURCE cost calls pass; [report](../benchmarks/results/blorp_2_first_order_written_fields_2026-10-18.md). Three historical effective/restored mutation pairs retain their original composition/pin limits. Fixed B remains `47c008b8`. Int ordering: all 24 phase checks green; native real-main/full acceptance pending. Broader callback ledger is **landed documentation**, not completed migrations. |
| **Blorp 2 pure path helpers** — `01a14aed-bbe4-7681-9765-b5a86f9d282e` | `string-slice-m2/blorp`, `codex/string-slice-m2`; `target-path-dirname/blorp`, `codex/target-path-dirname` | Slice authored: full components and native real-main cases green. Three native faults plus restored control queued; current-base acceptance remains. Dirname plan is **landed** at `9451ecddb`; tests authored but unrun, implementation pending accepted Slice/Int/scalar loops. Normalize still needs managed List carriers. Path join itself is **landed** at `ab68426be`. |
| **Blorp 2 flat patterns and source rewrites** — `01a14aed-c20a-7301-bcfb-58da6d7d47e3` | `qualified-pattern-source-plan/blorp`, `codex/qualified-flat-patterns-land` | Qualified-flat implementation held. First fault/restored pair exercised; four remaining pairs, fresh functional pilot, full/current acceptance pending. Broader nested/list/literal source simplification not complete. Also served as independent reviewer for control, M3 plans and Option/Result proposals. |
| **Blorp 2 compiler workloads and independent…** — `01a14aed-d83d-7d10-8686-1ad5bb5ffdc7` | `boolean-m2-composition/blorp`, `codex/boolean-m2-composition` | Boolean feature: phase/mutation/full standalone functional green; local annotations separately held. Lower read-dependency deduplication: red/green and one effective mutation/restored pair with five named failure witnesses, ARC controls and matched internal workload checks done. First profile completed, then metadata-check mismatch stopped the sequence; exact mode correctly reports `calls_observed=0`. Review amendment, retain first observation, run only remaining three profiles. Full feature acceptance/landing pending. |

All worktree names above expand under
`/Users/keithphilpott/.codex/worktrees/`. The ellipsis in the last title is part
of the title returned by the app. Use thread IDs to inspect or message the
original owners. Their current tasks are checkpoint-only, not authorization to
start overlapping compiled runs.

## Native subagents in the current coordination session

These are session-local agent handles, not independently resumable app threads.
Another coordinator can recover their files and assign a new specialist.

| Agent | Responsibility | Completion state |
| --- | --- | --- |
| `/root/ordinary_tail_prep` | Specialize/Lower/Emit side of the common Loop recut | **Checkpoint returned; implementation static only.** Earlier preparation passed emitter 16/16 and owner batch 787/787; admission TDD reached 26 pass / 2 intended failures. New scalar composition has not compiled or run. Tree `ordinary-tail-prep/blorp`, branch `codex/ordinary-tail-prep`, HEAD `b7bf8f4d`. |
| `/root/target_memory` | Strict target memory accounting, then common Loop Own/Verify | Memory accounting **completed and landed** at `d9185bdc8`. Current Loop core and most tests authored but **unrun/incomplete**. Tree `m3-loop-ownership/blorp`, branch `codex/m3-loop-ownership`, HEAD `b7bf8f4d`. Checkpoint returned. |
| `/root/compiler_review` | Independent compiler/code/test review across the slices | Latest assigned review **completed**: published SOURCE-policy documentation approved. M3 interface and several designs reviewed; complete current M3 core/test composition still requires review and execution. |

Earlier session handles recorded in this conversation were
`/root/architecture_audit`, `/root/argv_compiler`, `/root/argv_review`,
`/root/argv_tests`, and `/root/boolean_implementation`. They are **not present in
the current live-agent inventory**, so do not treat them as active workers or
infer a completion verdict from their names. Recover historical outputs from the
parent conversation if needed. Current argv behavior is exercised by existing
fixtures; actual self-compilation still has the separate proof in the handoff.

The app owners also reported earlier session-local review helpers. Opaque's
`review_key_preparation` and `review_key_tests` completed, with approvals in its
`REVIEWS.md`; source migration's `semantic_keys` and `specialize_callbacks`
completed. The following handles are no longer live and their final verdicts
were not recovered at this checkpoint: `annotation_contract_review`,
`managed_control_contract`, `phase_fact_scaling_audit`, `flat_pattern_recovery`,
`ownership_acceptance_review`, `review_path_join`, and
`qualified_pre_edit_review`. None is a worker the next coordinator should wait
on. Recover a retained review before counting it as acceptance.

## Exact recovery artifacts and known limits

### Common Loop: preserve both sides

Author directory:
`/Users/keithphilpott/.codex/worktrees/ordinary-tail-prep/blorp/build/m3-ordinary-prep/`.

- `ordinary-tail-prep-final.patch`: `604ca4d30c29b37a6c99497efd50acbfd33fab467650d72f1e4d82f928606b02`.
- `specialize-admission.patch`: `b6315f06…`; `lower-loop-producer.patch`:
  `a862ce40…`; `emit-loop.patch`: `4a33109e…`.
- `scalar-author-tests.patch`: `c8cb4ea8…`; `COMMON_LOOP_DESIGN.md`:
  `c308341b…`.

Peer directory:
`/Users/keithphilpott/.codex/worktrees/m3-loop-ownership/blorp/build/m3-loop-ownership/`.

- `owned-loop-interface.patch`: `dff2f73d…`, already applied to author tree.
- `ownership-core-01.patch`: `666283f9…`, incremental and excludes that interface.
- `ownership-test-ports-02.patch`:
  `df91a6a598d09ce072077ef7162ee7a0d2b9c820452b35fc5bfbfa463d0ab898`.
- `ORIGIN_RULE_MAP.md`: `1706959e…`; maps old source-annotation tests to their
  actual checking/specialization authority. It is not permission to delete raw
  resource-safety coverage.

Four suites still reference obsolete tail products: Own `test_own` and
`test_tail_recursion_phases`; Verify `test_managed_union` and
`test_tail_recursion`. Finish these before claiming a runnable composition.
Keep old callback oracles or explicit independently reviewed replacements.
The final capture-order test intentionally uses raw admission input to isolate
precedence; it makes no source-constructibility claim.

### Other candidate and durable-evidence locations

| Track | Primary local artifact directory | Already preserved outside worker tree |
| --- | --- | --- |
| Restricted if | `restricted-control-plan/blorp/build/restricted-if-a/`; latest `focused21-void-fixture-repair/` | Keep the original 17/4 run and setup failures alongside the repair. |
| Opaque | `opaque-m2-composition/blorp/build/opaque-m2-composition/` | Integration `build/bootstrap-evidence/opaque-m2-full-functional-2026-10-18/`; 136 files preserved. |
| Option/Result | `option-result-composition/blorp/build/` | Integration `build/bootstrap-evidence/option-result-composition-f3d6-2026-10-18/`; complete functional receipt `869b04a4…`. |
| Written fields | `first-order-written-fields/blorp/build/first-order-written-fields/`; `fixed-B-47c008b8/SOURCE_FIXED_PACKET.md` | Candidate source `d64edee3…`, patch `2589b3e5…`; existing 13-case/mutation evidence in `validation-01/`. |
| Int ordering | `int-ordering/blorp/build/int-ordering/` | Integration `build/bootstrap-evidence/int-imported-global-probe-2026-10-18/` retains the host crash reproduction. |
| Slice / dirname | `string-slice-m2/blorp/build/`; `target-path-dirname/blorp/build/` | Integration `build/bootstrap-evidence/string-slice-m2-2026-10-18/`; dirname-plan evidence under `target-dirname-plan-2026-10-18/`. |
| Boolean / annotations | `boolean-m2-composition/blorp/build/` | Integration `build/blorp2-boolean-read-dependencies-pilot-01/`, including `PROFILE_CHECKS_AMENDMENT.md` and original stopped profile. |

Integration means `/Users/keithphilpott/CLionProjects/blorp`. Short artifact
hashes above are lookup aids, not substitutes for checking full hashes before
applying/reusing files. A preserved old functional receipt proves its frozen
source/library combination only.

Local annotations additionally have their own tree
`/Users/keithphilpott/.codex/worktrees/local-binding-annotations/blorp`, branch
`codex/local-binding-annotations`, HEAD `697fa767`. Twenty-callback and mutation
evidence is preserved in integration
`build/bootstrap-evidence/local-annotations-2026-10-18/`; acceptance/landing
remains separate. Opaque's retained-product tests came from
`compiler-product-lifetimes/blorp`, branch `codex/compiler-product-lifetimes`,
and **are landed** at `d82bdf85c`. The O0 script work came from
`fixpoint-o0-default/blorp`, branch `codex/fixpoint-o0-default`, and **is landed**
at `f1a27fcb2`/`fedb88c85`; no actual fixpoint was run there.

Slice's exact next commands are in integration
`build/bootstrap-evidence/string-slice-m2-2026-10-18/native-four-call-ready-01/FROZEN_COMMAND_PINS.json`.
Qualified-flat's next pairs are in
`build/bootstrap-evidence/qualified-flat-d82-2026-10-18/execution-packet/COMMANDS_17_PLUS_CMP.tsv`
with `MUTATIONS.json`; add its 20 missing non-Blorp support-fixture pins before
full validation. The initial fault/restored 19-case receipt is preserved there.

### Retained migrations without a current dedicated owner

Do not lose these when redistributing work:

- `source-port-current/blorp`, `codex/source-port-current`: byte/Char and parser
  classification ports; compose with current sources before claiming removal.
- `first-order-fills/blorp`, `codex/first-order-fills`: candidate and focused
  functional evidence retained; remaining mutation pairs queued.
- `first-order-scalar-adapters/blorp`, `codex/first-order-scalar-adapters`:
  candidate plus comparison/mutation work still pending.
- `finish-first-order/blorp`, `codex/finish-first-order`: retained sorting/
  callback work. Fresh-copy quadratic lookup/sorting limitations are documented;
  do not claim efficient data structures or complete callback removal.
- `list-string-join-plan/blorp`, `codex/list-string-join`: String-list join
  implementation and substantial functional evidence retained, but a recorded
  absolute allocation check still fails. Not accepted or mergeable as-is.
- `APPEND_INT_PLAN.md` and retained candidate: acceptance failed; not a completed
  first-order library dependency. Resolve or choose a reviewed ordinary source
  replacement rather than silently treating it as available.

### Specific traps for the next coordinator

1. Int's original inline test callbacks hit a host imported-global initialization
   crash. Named callbacks passed all 24 phase checks without changing assertions.
   This is a documented host limitation, not a target-language semantics change.
2. Written-fields historical per-call standard-library snapshots covered 83
   top-level files, omitting eight nested files. The explicit correction and
   current 91-file identity/continuity evidence are retained; do not retroactively
   claim all 91 were checked per historical call. Future inventories recurse.
3. Boolean internal workload measurements include a wide-shape instruction
   regression; do not claim a universal speedup or isolate phase instructions
   from whole-process measurements.
4. Older functional candidates have 40 source modules; current main has 41.
   Reuse binaries only with exact source, target-library and toolchain
   correspondence. Do not conflate old full-green runs with destination testing.
5. `path.dirname` is only planned, and `path.normalize` remains unfinished.
   Standalone filesystem primitives do not establish actual loader integration.
6. Strict target allocator accounting is landed; full target-built compiler
   destruction and leak acceptance is still future work.

Return the branch/patch, reviewed source identity, exact command results and
outstanding limitations for each resumed slice. Keep the coordinator as the sole
integration/publishing authority. Do not archive any listed worktree until its
borrowed ignored evidence is copied and verified elsewhere.
