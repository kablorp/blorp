# Exact selected trait targets

This prerequisite preserves an existing `SelectedTraitCall`'s issued method
identity through generic implementation materialization and final trait
dispatch. It does **not** implement caller-selected generic trait evidence.
The legal enum and custom Selector diagnostics below remain follow-on work.

## Boundary

Trait resolution builds a local owned method-ID index. Selected calls use the
actual enclosing method's trait/member and existing projected receiver key,
never the global trait/member/type-name registry as fallback. Missing and
duplicate IDs fail closed. Source methods produce coherent
`SelectedDirectCall(id)` and callee `Some(id)`; native classification reads the
same actual method in collection and finalization. The shared classifier is
invoked separately in those paths, not literally once for the entire pass.

Generic implementation materialization publishes source-method ID, erased
closed receiver, and actual minted target ID. Structural hash buckets use the
existing compatible hash/equality and verify full identity on collisions.
Facts persist across the append-only callable fixpoint; one final remap runs
before generic-data specialization. Local selected-trait source identities
remain intact until that receiver-aware pass. Ordinary self/sibling references
keep their existing direct remapping. Conflicting facts produce a structured
`CoreMonoConflictingImplMethods` error, propagated through Result APIs; missing
facts remain selected and are checked by the existing downstream boundary.

Canonical selected module paths and method display source names are not
interchangeable (`app/main` versus `main`, or `packages/math/stats` versus
`stats`). Core has no module table. This pass does not validate canonical owner
strings by equality, suffix matching, or reconstruction; lowering retains that
responsibility. Synthetic no-source-module fixtures remain legal. The collision
tests prove a Core identity invariant, not reachability of an admitted source
collision. The existing early invariant requires program-wide callable IDs;
the older module-local wording in `resolve.brp` is not used as authority.
Receiver checking uses the inherited `core_trait_impl_type_key` projection,
not a newly proven general type-equivalence policy. Additional receiver-policy
coverage remains unproven; this is not evidence of an introduced regression.

No caller witnesses, CTFE dispatch changes, admission changes, generic request
dedup changes, new IR, builtin spelling exceptions, or bootstrap changes are
included. This selected-target correctness change affects emitted call targets;
it does not fix ownership or the general compound-pattern compiler defect
demonstrated in the saved base2ac and frozen candidate snapshots.
Overlapping suppressed requests are
follow-on work, not permission to borrow another materialized target.

## Provenance and narrow gates

Owned branch: `codex/caller-trait-evidence`, base
`2ac1950a89c18ac11c3db402bc4b0f4cebad6066`. Raw packet:
`/tmp/blorp-caller-trait-evidence.Uk14p9`.

The original source-matching O2 baseline binary was
`b5c1ad858d1437935f5cdaeb2c33e22e1bbf8a3f8d70411f4cc7d648379f2c30`.
It was not copied before replacement and is unavailable. Its build/FRESH logs
and baseline output artifacts remain; later binaries are not relabeled as it.
The first retained partial candidate is `first-candidate-blorp`, SHA
`c63af3f06d9fad26c061b939900830b0510448f7dbd49c51d1aa346d0f74a575`.

Historical raw results are separate snapshots:

- `selected-id-red.log`: 48 passed / 2 failed, exact-ID collision and missing-ID
  fallback controls.
- `selected-id-red-expanded.log`: 49 passed / 3 failed after the duplicate-ID
  control was added; mismatched identity controls already rejected.
- `first-candidate-suite.log`: 53 passed / 1 failed. The remaining old assertion
  expected UnknownCall rather than the new exact direct-call contract.
- `remap-nested-owner-suites.log`: 26 + 57 + 22 passed after crash isolation.
- `remap-reviewed-controls.log`: 28 passed and 55/57 passed. Two strengthened
  diagnostics incorrectly expected `app` rather than the fixture's actual
  canonical `packages/app`; only those expected strings were corrected.
- `remap-reviewed-controls-corrected.log` and final
  `remap-final-owner-suites.log`: 28 + 57 + 22 = 107 passed.

The final O2 candidate is FRESH at the frozen production hashes. Retained
`remap-canonical-blorp` SHA:
`2e34c57f395440e819e4e975611964036333d6ec8f2f7290de02e6eda04e32c3`.
Formatting-only rebuild emitted the same binary as the preceding nested-match
snapshot; source hashes still distinguish them. `final-fresh.log`,
`remap-canonical-build.log`, and `remap-canonical-bin.sha256` retain provenance.

The 31-file compiler/test/fixture freeze is `final-source.sha256`, SHA
`5aba283a778a3b32262c8f3679e19f60afdc4b9cbb583fdc055e730f60902ab0`.
It deliberately excludes this subsequently drafted evidence file.
`final-production-tests.patch` retains tracked changes.
`CURRENT-all-artifacts.sha256` SHA
`cb0199924b0150edf71ac73fdfa23356e0f113d65af61a487072d6eca62501f1`
records artifacts present at source freeze, not retrospective capture times.
Final suite log SHA:
`b15adf7facb016ce3cb47fa10be617652150cc2c2f2be80fcc6df67a878d381f`.

Reproduce the narrow gates from the owned source tree:

```bash
BLORP_CLI_C_OPTIMIZATION=-O2 make
scripts/compiler-build-status
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_mono_impl.brp \
  blorp/test/compiler/stage_09_core/test_core_trait_resolve.brp \
  blorp/test/compiler/stage_09_core/test_core_mono_data.brp
bin/blorp run --no-format --sanitize --timeout 180 \
  benchmarks/results/fixed_union_selected_targets/fixtures/mono_cross_impl_probe.brp
```

The final mixed-call probe prints `before` / `after=True` and exits 0 under
ASan. Raw `remap-final-cross-impl-sanitize.log` SHA:
`045a842330de8358a4dac4539c6d4084c46ce6395e7fc4a566adc6df9f74a308`.
This worker probe is focused evidence, separate from the independent gates
below. Independent validation of the frozen 31-file snapshot is complete;
this prerequisite and its disclosed temporary costs are accepted for local
integration, not presented as a performance win. These historical results do
not assert freshness after later integration. No main publication, push,
release or bootstrap change is claimed.

Independent packet: `/tmp/blorp-selected-independent.FMUV8T`. Actual completed
checks are overlapping snapshots, not additive unique coverage:

- Eight exact owner suites: 180 passed (`owners.log`), including the worker's
  107 checks. Changed-source selection: 2,571 passed, seven suites plus one Core
  ASan check (`selected.log`). Passing nested selected-check logs were deleted
  by the existing runner; only its actual aggregate wrapper is retained.
- CTFE gate: 191 passed (`ctfe.log`); five focused trait runtime suites:
  18 passed, process-end 3 allocations/3 releases/zero leaks
  (`runtime-focused.log`). Normal codegen audit: 228 passed (`codegen.log`).
- Warmed serial broad gate: 12,414 passed / zero failed, comprising compiler
  6,571, runtime 4,673, and leak 1,170. `broad.log` and `gates/` preserve actual
  component verdicts. Broad log SHA
  `2c63eda7aee40bab0f8522fe5dad8f6a9f69a3694cdf38ed876612491271a526`.
- Actual O2 fixpoint: all three generated C files are 76,494,153 bytes with SHA
  `8f87f953a3d5eb764747edc530476c46848fdf56f93ca021bac2d5515e1acc79`.
  `fixpoint.log` explicitly confirms stage1=stage2 and stage2=stage3; log SHA
  `e858320e5e482903ec3f7e7ccfb7a7633ce44cf11dc02e1ada493c01790cc9d6`.
  Actual stage2 binary SHA
  `21f8e8c0f3dde86137f5ffbe6a4d704ffaa6f08ed8b5d33b86485801a3504c34`;
  stage3 SHA
  `2276d616fc66cbe7ecf3541eceb2a01665b599a0e2a36267975a9ab9e6480707`.
- Completed stage2 owner suites: 180 passed (`stage2-owners.log`). Three stage2
  probe runs print `before`/`after=True`; missing/instances/cross-impl report
  respectively 165/788/955 allocations and equal releases, zero leaks. Their
  C, full final Core, compile/run logs and extracted bound facts are retained.
  Actual stage2 serial codegen audit: 228 passed / zero failed
  (`stage2-codegen.log`, SHA
  `d9da9a12a77124c1f1aa115452ed60ca3c479ad13e2a370568c76f0d72fe495f`).
  These checks overlap the normal audit; frozen-self context is recorded below.

Report snapshots read for this note: PROGRESS.md SHA
`155002471e5e692885523f1253b721d6e2a6804346fb3846885a3defa790384b`,
COST.md SHA
`d5cd3832e1e1a9207e59b7da6d54c920e1391d3f8a6c4fe78e4855ef6e523797`.
Later completed raw logs override pending wording in earlier progress prose;
this note does not manufacture missing nested logs. Final REPORT.md SHA
`a6c512de896a9e164629bdda45e054296ce0e18f6035068177d6c84b8fbda1cd`
and `artifacts.sha256` SHA
`4c10cd825c1a481c0b47974145c7135fcb71d1d726694d9b54d19db34cdfc8be`
bind the completed independent report and retained raw packet.

Actual independent wrapper commands from the candidate checkout included:

```bash
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --changed --base 2ac1950a89c18ac11c3db402bc4b0f4cebad6066
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --stage ctfe
scripts/test --serial --no-build --log-dir /tmp/blorp-selected-independent.FMUV8T/gates compiler-blorp runtime leak
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-fixpoint --work-dir /tmp/blorp-selected-independent.FMUV8T/fixpoint
bash blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh /tmp/blorp-selected-independent.FMUV8T/fixpoint/blorp-stage2 --jobs 1
```

Stage2 probes used that exact stage2 binary, with `compile --no-format
--dump-core-after=final --dump-core-file=<packet>/stage2-PROBE.final.core
-o <packet>/stage2-PROBE.c <fixture>` followed by `run --no-format --leak-check
--timeout 180 <fixture>`. PROBE names are mono_instances_probe,
mono_cross_impl_probe and mono_missing_probe; fixtures are under this packet's
repository `fixtures/`. Full actual commands and eight owner filenames are in
the final independent report. These are completed source-snapshot gates,
not promises of freshness after future integration.

## Compound-pattern compiler defect: isolated, not fixed

The stale partial host initially crashed a new mixed direct/trait-call control.
A current-source FRESH O2 host also crashed while compiling the isolated probe
(ordinary compile, no sanitizer flag). That diagnostic host was retained as
`remap-current-blorp`, SHA
`7ec6bb31c686e97d3695cd8a631d96f72fc57dd5df927bb18c71f6477ed026d3`.
Raw backtrace: `mono-cross-impl-current-host-backtrace-2.log`.

Top `brp_4hU` was `mono_impl.brp::remap_selected_impl_expr`. Retained
`remap-current-split-body-5.c` shows only Ok and outer CallExpr tag checks,
followed by unchecked nested SelectedTraitCall/VarExpr field reads. A direct
call's integer ID was read as a managed pointer. Explicit separate matches on
state, expression, call kind, and callee fix this prerequisite's source shape
without extra retains, defensive target fallback, or a pattern-lowering change.
Keep those explicit matches unless a broader pattern-lowering repair is
integrated and independently gated against this source shape; the frozen
candidate's compound tuple pattern recreated invalid nested-field reads.

The small `fixtures/compound_pattern_probe.brp` independently demonstrates
the general defect: `(Ok(_), Wrapped(Text(text)))` must reject Number(30), but
the emitted function checks Wrapped and reads Number's integer as a Text string.
Retained `compound-pattern.c` SHA
`44903af0c0153b1807568eb3d6e4469405e2ef91662a437638ff52ffcd836902`;
ASan/UBSan `compound-pattern-runtime.log` SHA
`70c7cbf0e33ead9fda498bbb2850fcb46adfdcc99d66c073dc16779ceefe5206`.
It fails at C line 47840 reading address 0x1e as a string. Positive execution
precedes the negative call, but buffered stdout was not retained as a separate
positive result. The fixture was subsequently canonical-formatted; its exact
pre-format source was not separately copied. Historical C/log hashes remain
unchanged and are not attributed to the current formatted source bytes.

This known-failing diagnostic is not part of passing suites. Reproduce it
separately with `compile --no-format -o <temporary.c>`, then Clang
`-O2 -g -fsanitize=address,undefined`; do not count its crash as a remapper gate.

Independent confirmation uses the newly retained source-exact 2ac baseline
`b0ac1cb4ded75dd7f5f713743a9b8d2268e1618694b92df981b279f0e83b9fed`
and the current formatted fixture at its exact candidate path. PROGRESS.md
records compile exit0/run exit139, with no flushed stdout. Independently read
`compound.baseline.compile.log`, `.run.log`, `.c` and `.match.core` in FMUV8T:
the generated C again checks Result.OK and Outer.Wrapped but not Inner.Text
before reading Number(30) as a String. C SHA
`0fdaa637dc82d40e93e555ef92ec644ecc7fa6f83f20869ff15fed94dca49b76`;
match Core SHA
`e98daff6e7c75a99421f99e4ae66eead4b9add854c954fcb4f96a99b3dbaa6f2`.
This confirms a pre-existing defect in the saved base2ac snapshot, not a new
frozen-candidate regression. Main/origin subsequently advanced in another task
to `4dc9a9ace` ("Preserve nested pattern guards"); that change has not been
integrated or re-tested here. These findings do not describe later main.

## Caller evidence diagnostics: explicitly unfixed

`fixtures/caller_diagnostic/` retains the original source bytes for a provider
owning enum Choice, its lawful coarse private Equatable implementation
(equals=True, not_equals=False), imported generic same, and nested forwarded.
There is no orphan consumer implementation. Historical admission succeeded.
Runtime main, reverse call order, provider-only and importer-only all return
True. No-private auto-tag control returns False. `runtime.log` also records
zero leaks. `ctfe_direct.log` and `ctfe_forward.log` record folded importer and
provider False but runtime True. Intended future policy is provider True and
importer False; those expectations are not acceptance claims for this cut.

Lowering recorded native/deferred enum BinaryExpr routes, not an issued
SelectedTraitCall witness. Both generic contexts shared forwarded 1604 and
same 1607 instances; later operator/name dispatch selected the global private
implementation. The nongeneric importer True is a separate observed private
visibility leak. Exact-ID preservation is therefore necessary but insufficient
for these diagnostics; it does not implement their missing caller evidence.

Unique custom Selector/pick_marker runtime direct and forwarded results are
11; actual CTFE rejects unsupported intrinsic `pick_marker`. The legal module
alias control retained selected ID122. A dotted implements spelling and an
earlier bad record literal were setup failures, not semantic RED.

`probe-sources.sha256` and `baseline-results.sha256` retain original manifests.
Full `core.snapshots` SHA
`54e379681ddba254f35adccb9cdf31f76fe4e00bfc3e74167c9033fb2ee5c0f1`;
`main.c` SHA
`4700d33b89449d92c862d3c8ab853f70aa75ddf301a26de78199534b3b8e4a73`.
They and bounded extractions are separately pinned in
`CURRENT-observed-baseline-core-c-extractions.sha256`: hashes observed now,
not an assertion that the original result manifest captured these files.

For reproduction, run the retained baseline against main.brp, reverse.brp,
provider_only.brp, importer_only.brp, auto_control.brp, ctfe_direct.brp,
ctfe_forward.brp, selector_main.brp and selector_ctfe.brp under that fixture
directory using `run --no-format --leak-check`; use `compile
--dump-core-after=lower,mono,trait_resolve --dump-core-file=<temporary-path>
--no-format -o <temporary.c>` for complete phase facts. These remain diagnostic
commands, not future-policy gates.

## Cost fixture and independent comparison

`blorp/benchmark/compiler/compiler_selected_trait_pass_profile.brp` SHA
`5beecab82527478306a20ba8c40312d7baadffcc27b243e0631925ba89ae8e90`
calls actual resolve_core_traits (`traits`) and full monomorphize_program
(`mono`) over prebuilt, unambiguous Core. Setup/warmup and final resolver
observations are outside scalar allocation/release endpoints. The observation
checks the actual UserCall target, callee ID, and selected method body 1.
Before/after MemoryStatsActive and OracleStatsActive must all equal 1;
unknown mode is rejected. Final N=1 setup controls pass both modes, while
unknown exits 1. No setup/control numbers are a performance comparison.

The loop retains the last result. Final semantic validity alone is not proof
that every iteration executed. Independent generated C and optimized
disassembly retain the real loop: candidate instruction 0x1001b5aa0 calls
execute `brp_1W`, decrements the counter and branches back at 0x1001b5abc.
Execute calls actual trait resolver `brp_1mp` or full mono `brp_1h9`; observation
stays outside the interval. Tracked counters include allocator/mutex
instrumentation. No elapsed-only win, production-phase percentage, or
performance improvement is claimed.

Independent runner retained a newly rebuilt source-exact 2ac baseline:
`/tmp/blorp-selected-target-baseline.16jYWy/baseline-blorp`, SHA
`b0ac1cb4ded75dd7f5f713743a9b8d2268e1618694b92df981b279f0e83b9fed`.
Its REPORT.md and packet.sha256 preserve exact source, bootstrap, toolchain,
FRESH and binary provenance; packet manifest SHA
`dab56bc31cf5a6e88979e4a636ceeab3785d6f7a33d9a4523c4adcd5030c7845`.
This is distinct from the unavailable historical b5c binary.

The same b0ac host compiled both workers from distinct production source trees
with identical fixture bytes. Existing runner emitted optimized workers using
Apple Clang21, `-O2 -DBLORP_MEMORY_DIAGNOSTICS=1 -fwrapv -pipe -w`, graph/type
headers, `-lm -lpthread`. Worker SHAs baseline/candidate:
`10349d08bb4c045f7da4f2edacebfb24325202668a72a73a35a9a13a80da2b75` /
`1fe25538e501d15ff29a985bb8c2ee379a1fbad6566410c63c382e16a946ebf9`.
Generated C intentionally differs:
`cd9f7e0d3dc542b90be00942a679ff1baa7f2cb99708553f6a71d9040e4534b6` /
`87fbf0b97b6b3e99d61d1dc436a916001f71bd03005855f0e7ec6593b697adf6`.
`cost-workers.sha256` SHA
`3fcddeb9603e1320c608d22e286fe3db64403e02d8017430eb22c4a033a98691`
binds those exact paths. This is source-pass worker cost, not stage2 whole
compiler cost.

Durable unchanged raw pairs: [cost-traits.json](cost-traits.json) SHA
`a99fd18571009540c1983fc7cdbfc0f440574de9abd3e0efdd576f341d447cc3`,
[cost-mono.json](cost-mono.json) SHA
`090012c5f4621fe231859a2972f95da49ecb563f51bc75c61d697f7518070a2a`.
They retain seven alternating pairs, arguments, source status, fixture hashes,
active-counter flags, actual order and every raw sample. Initial cost-traits.log
rejected a missing `--checksum-field` before sampling; the flag-only correction
is setup repair, not a failed compiler gate or performance sample.

All N1/N1000 samples are valid with four active-counter flags1. At N1000,
baseline→candidate allocations/releases are repeatable across every pair:

| Actual pass | Allocations | Releases | Allocation change per iteration |
| --- | ---: | ---: | ---: |
| traits | 97,000→92,000 | 96,988→91,987 | −5 |
| mono | 130,000→169,000 | 129,983→168,977 | +39 (+30%) |

Releases exclude the still-live last result at the interval endpoint; these
counts are not a leak oracle. Separate seven alternating `/usr/bin/time -l`
pairs report minimum whole tracked-process retired instructions:
traits 165,863,230→161,294,918; mono 211,906,745→268,972,333 (+26.93%).
That process includes setup, warmup, observation, reset and reporting, not
solely the measured pass interval. Raw `instructions-*` stdout/time files and
full baseline/candidate disassembly remain in the independent packet.

Unrelated publication/differential compiled work overlapped correctness and
cost runs. A bounded five-minute quiet wait did not reach quiet; coordinator
authorized continuing with interference documented. Our team used one
foreground compiled job at a time and did not interrupt/mutate other tasks.
The current `self_compile_measure lock` is a no-op passthrough, **not** a
serialization mechanism. No quiet latency or small-speedup claim follows.

Historical worker/paired command bindings (executed from the candidate tree):
the recorded root checkout was production-exact 2ac, with documentation dirt
and the identical benchmark fixture only. These paths are not a promise that
an advanced root remains baseline. For reproduction, create a separate clean
base checkout with `git worktree add --detach <new-baseline-path>
2ac1950a89c18ac11c3db402bc4b0f4cebad6066`, copy only the fixture, and verify
its SHA `5beecab82527478306a20ba8c40312d7baadffcc27b243e0631925ba89ae8e90`
in both source roots. Require baseline HEAD equal that revision and baseline
production/build-input manifests to match the saved baseline packet; require
the candidate's 31-file freeze manifest to verify before building workers.
Substitute those separate source roots and new cache/result paths below.
Missing generated inputs must be produced by normal documented Makefile targets,
not by borrowing candidate inputs. Do not run these historical bindings against
an integrated root and describe it as a base2ac comparison.

```bash
packet=/tmp/blorp-selected-independent.FMUV8T
baseline_root=<worktree:43a9>
candidate_root=<worktree:fixed-union-concrete-binder>
common_host=/tmp/blorp-selected-target-baseline.16jYWy/baseline-blorp
baseline_worker="$packet/cost-cache-baseline/selected-trait-pass/30a896e1f1c3a074aa9b0b33fcafb1aa24f392cdd6b4f6834bc84b864105d7ff/selected-trait-pass"
candidate_worker="$packet/cost-cache-candidate/selected-trait-pass/7a205940f12a9a7308aa503b32c9cc0dcebf0e220ca65186c6a6e437a0f639a6/selected-trait-pass"
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
BLORP_COMPILER_BENCHMARK_COMPILER="$common_host" \
BLORP_COMPILER_BENCHMARK_WORKSPACE_ROOT="$baseline_root" \
BLORP_BENCHMARK_CACHE_DIR="$packet/cost-cache-baseline" \
TMPDIR="$packet/cost-temp-baseline" \
benchmarks/compiler_blorp_benchmark_runner selected-trait-pass \
  blorp/benchmark/compiler/compiler_selected_trait_pass_profile.brp plain traits 1
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
BLORP_COMPILER_BENCHMARK_COMPILER="$common_host" \
BLORP_COMPILER_BENCHMARK_WORKSPACE_ROOT="$candidate_root" \
BLORP_BENCHMARK_CACHE_DIR="$packet/cost-cache-candidate" \
TMPDIR="$packet/cost-temp-candidate" \
benchmarks/compiler_blorp_benchmark_runner selected-trait-pass \
  blorp/benchmark/compiler/compiler_selected_trait_pass_profile.brp plain traits 1
for mode in traits mono; do
  benchmarks/compiler_pass_compare --label "selected-$mode" \
    --baseline-bin "$baseline_worker" --candidate-bin "$candidate_worker" \
    --baseline-source-root "$baseline_root" --candidate-source-root "$candidate_root" \
    --allow-dirty-source \
    --fixture-source blorp/benchmark/compiler/compiler_selected_trait_pass_profile.brp \
    --prefix SELECTED_TRAIT_PASS --time-field elapsed_microseconds \
    --checksum-field workload_valid --checksum-field declarations \
    --stable-field mode --stable-field iterations \
    --stable-field memory_active --stable-field oracle_active \
    --stable-field memory_active_after --stable-field oracle_active_after \
    --metric-field allocations --metric-field releases --pairs 7 --warmup-pairs 1 \
    --results "$packet/cost-$mode.json" -- "$mode" 1000
done
```

Instruction pairs use `/usr/bin/time -l "$baseline_worker" "$mode" 1000` and
the corresponding candidate command, baseline-first on odd pairs and
candidate-first on even pairs. The coordinator accepts the measured temporary
costs within the correctness prerequisite; there is no performance-win claim.
None of these results closes caller-witness, CTFE/private-visibility behavior.

## Normal-only frozen-self instruction context

The independent runner completed three alternating pairs (baseline first on
pairs 1/3, candidate first on pair 2), with no C compilation in the measured
windows. Historical cwd and absolute input were the production-exact base2ac
root above; `BLORP_STD` was unset. Actual command shape for each side:

```bash
cd <worktree:43a9>
/usr/bin/time -l env -u BLORP_STD \
  /tmp/blorp-selected-target-baseline.16jYWy/baseline-blorp \
  compile --no-format -o /tmp/blorp-selected-independent.FMUV8T/self-1-baseline.c \
  <worktree:43a9>/blorp/src/main.brp
```

Candidate actually invoked
`<worktree:fixed-union-concrete-binder>/bin/blorp`
(SHA2e34 above), not the equal-byte retained temporary copy, with output
`self-PAIR-candidate.c`; baseline output used `self-PAIR-baseline.c`.
Pair numbers were 1–3. The exact invocation is retained in the independent
runner's task execution transcript; there is no separate self-command artifact.
Both compiled the SAME frozen
root input, not their respective unequal self sources. Reproduction requires
the separate verified base2ac input checkout described above for both sides.

`self-source-resolution.sha256` SHA
`3be4da48b470f58d2add462a417beaa851a1f993f2e52539c10aa47502695694`
pins main (`b05ea3332b3252ecdf82c35dae0bcc303f8ce58d79e5fc7d45226fee419c9a86`),
embedded_std (`436d03364aec9c4d3117913ca1db06a884bc3681e3a8c16c98deebfdbd98ad44`),
configuration and standard-library sources. Actual `self-source-head.txt`
records base2ac; config SHA
`26ebcab3c42e66ba5e6d7c0a3e3680438a07d028fc691f1592a7f96667545632`
matches git2ac. `self-source-baseline-verified.log` SHA
`66f0d05aff62610a641b8212635df49f043ac9cd1fd947752c9f4dc0421573a7`
and `self-build-inputs-verified.log` SHA
`dab3c938db8f0fafeb8f9555b8d4883ce616d41d36babdc1447e592ef55371de`
retain the successful saved-source/build-input checks.

All six emitted C files are byte-identical, SHA
`13f05fc3edb00d1eba49c634875dfd9e35e71027855ed84d57642dc478c6deac`
(`self-C.sha256`). Whole-process instruction minima are
226,267,990,104→227,848,709,740 (about +0.699%); diagnostics0 normal binaries.
Raw `self-PAIR-SIDE.stdout`/`.time` retain each command's output and counters.
This interference-qualified context is not allocation evidence, diagnostic
worker cost, stage2 speed, or a production-phase percentage. No diagnostic
compilers were built for it. All independent compiled jobs are stopped.

All `/tmp` artifacts are local retained evidence, not durable repository
attachments. The committed fixtures and commands enable reproduction if those
artifacts are removed; missing historical binaries/source copies are stated
above rather than reconstructed as original captures.
