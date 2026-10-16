# UFCS attribution: borrowed namespace facts help; scaling still fails

The reviewed borrowed-entry query removes unnecessary list materialization and
reduces allocations, but it does **not** make declaration-time UFCS validation
acceptable under its original cost limits. On the frozen `fb257c946` boundary,
the candidate adds **2.332% normal instructions / 2.907% allocations** on zero
and **6.893% / 6.413%** on the 128-provider stress. This is diagnostic evidence,
not integration acceptance or a validated current-main result. No full corpus,
mutants, frontier, full gate, commit or publication ran.

The code change is +15 physical production lines over the first prototype,
**+28 total production** versus the frozen baseline; tests remain **+277**.
Root and an independent reviewer approved the query patch with zero findings.
All **44 focused tests** pass: five clash/visibility/hint tests, eight shared
unifier tests and 31 namespace tests. All 27 strict samples report equal
allocations/releases and **zero leaked objects/bytes**. All 54 measured runs
and nine excluded warmups emit byte-identical C.

## Measurement mode correction

The [first negative preflight](blorp_2_ufcs_feasibility_2026-10-15.md) is preserved
unchanged, including its +276 allocations and +2.578% instruction result.
Its reproduction and all six original timing commands set
`BLORP_LEAK_CHECK=strict`: **those instruction samples were strict-instrumented,
not normal compilation measurements**. Treating that instruction percentage as
normal cost was incorrect. Its deterministic allocation result remains valid.
This report's fresh, explicitly separated normal series is authoritative for
normal instructions; strict instruction numbers remain raw diagnostic data.

Every normal run below uses:

```bash
env -u BLORP_LEAK_CHECK -u BLORP_MEMORY_STATS /usr/bin/time -l \
  -o OUTPUT.time PILOT --library-root blorp_2/standard_library_temp INPUT OUTPUT.c
```

Strict runs are separate invocations, with both variables first unset and then
`BLORP_LEAK_CHECK=strict` set. Each workload/pilot gets one excluded normal
warmup, three normal samples and three strict samples. Pilot order rotates
baseline/old/borrowed, old/borrowed/baseline, borrowed/baseline/old. Runs were
serial under the coordinator's exclusive compiled slot. The slot was explicitly
released after these measurements; subsequent work was source/report inspection.

## All normal samples and strict allocations

“Old” is the unchanged first UFCS prototype; “borrowed” adds the reviewed query
patch. Instructions are retired instructions over the complete source-to-C CLI.
Each strict allocation count is identical across its three samples.

| Input / pilot | Normal samples 1, 2, 3 | Normal minimum | Delta vs baseline | Strict allocations | Delta vs baseline |
| --- | --- | ---: | ---: | ---: | ---: |
| zero / baseline | 34,135,259; 34,168,865; 34,065,814 | 34,065,814 | — | 8,428 | — |
| zero / old | 34,833,923; 34,910,916; 34,786,676 | 34,786,676 | +2.116% | 8,704 | +3.275% |
| zero / borrowed | 34,892,322; 34,914,348; 34,860,186 | 34,860,186 | +2.332% | 8,673 | +2.907% |
| 32×16 / baseline | 239,576,012; 239,555,343; 239,519,217 | 239,519,217 | — | 144,643 | — |
| 32×16 / old | 246,046,947; 246,020,262; 246,200,335 | 246,020,262 | +2.714% | 147,007 | +1.634% |
| 32×16 / borrowed | 245,768,757; 245,745,440; 245,803,998 | 245,745,440 | +2.599% | 146,752 | +1.458% |
| 128×8 / baseline | 575,565,033; 575,522,098; 575,465,826 | 575,465,826 | — | 295,382 | — |
| 128×8 / old | 615,802,456; 615,910,421; 615,687,883 | 615,687,883 | +6.989% | 314,997 | +6.641% |
| 128×8 / borrowed | 615,193,459; 615,289,168; 615,132,603 | 615,132,603 | +6.893% | 314,326 | +6.413% |

Borrowing saves **31 / 255 / 671 allocations** versus old on zero/32/128.
Normal instructions change by **+73,510 / −274,822 / −555,280**, respectively.
The query patch is an allocation win, not evidence of a zero-input instruction
win. No broader speed claim follows from these three input proxies.

The original ceilings remain reference gates: zero +0.5% normal instructions
and allocations <=8,513; 32-provider stress <=31,000 allocations; 128-provider
stress +1% normal instructions and allocations; production <=+102. Zero and
128 fail. The 32 absolute ceiling also fails on the baseline itself, as below.
The user permits discussing scoped representation/lookup costs; no acceptance
waiver is inferred, especially for growing quadratic work.

## Exact stress census and the 31,000 mismatch

Measured inputs are the unmodified retained
`build/quality-ufcs/inputs/methods_same_name_32_16/main.brp` and
`methods_same_name_128_8/main.brp`, pinned by the original 185-file manifest.
All manifest entries still verify. Neither input nor counter definition changed.

| Input | Provider files | Functions/provider | Total provider functions | Distinct records | Shared function spelling |
| --- | ---: | ---: | ---: | ---: | --- |
| 32×16 | 32 | 16 | 512 | 32 | describe |
| 128×8 | 128 | 8 | 1,024 | 128 | describe |

Each provider declares `Item_i` and `describe(Item_i)`. Its other 15 or seven
functions have globally unique `op_i_j` names. The root imports every Item_i
(thereby its methods), and main returns zero. There is **one shared name**, not
16/eight shared names. Including the seven default modules gives 39/135 modules
and 536/1,048 accepted signatures. Unused functions are checked then omitted
from target C; C identity is consequently a modest oracle here. No target-native
method-call behavior is claimed; focused tests cover semantic checking.

The roadmap's historical cost row says only “32 modules sharing a name”, with
29,993 measured allocations and a 31,000 ceiling; it pins no filename, bytes or
compiler. The retained historical `cost_base.tsv` explicitly records
`methods_same_name_32_16/main.brp ... allocs=149837`, not 29,993. A 32×1 input
also exists in retained historical inputs, but inspected evidence does not tie
29,993 to its exact bytes/toolchain. That association remains **unverified**.
The historical baseline TSV was copied read-only to owned evidence as
`build/quality-ufcs/reference/historical-cost-base.tsv`, SHA-256
`67e24e99055a450d9f21c67632eb661c15cd81a1d50253a8878194006eb8b3fe`.

Thus the current plan selected a broader stress than the unidentified historical
31,000 case. This report retains the ceiling and measured 144,643 baseline;
it does not silently replace the input, scale a limit, or call it passing. A
canonical workload/expectation needs explicit resolution before acceptance.

## Attribution: what improved and what remains

The unchanged old prototype was freshly compiled with the existing calls API,
selecting receiver_clashes, callables, inference, model, namespace and int_map.
On zero it records:

| Function/operation | Calls |
| --- | ---: |
| reject_receiver_clashes / name_counts | 1 / 1 |
| introduced_names / count_introduction | 7 / 32 |
| declared_functions | 16 |
| receiver_bindings / reject_group / reject_pair / types_overlap | 8 each |
| selected_receiver | 16 |
| offered_value | 112: 16 introduction checks + 96 canonical candidate queries |
| IntMap probes for global counts / introduction groups / inherited IDs | 92 / 82 / 46 |
| solve_overlap | 0 |
| inference_type | 2, from ordinary body inference, not receiver overlap |

The profiler describes 1,295 functions, selects 157, observes 87 and reports
4,008 calls. Every loss/corruption counter is zero. `calls_completed=0` is the
calls-only mode's non-timed field, not evidence of missing end events. No fresh
stress call profile or exact-time ranking is claimed; stress counts below are
derived from the actual sources and loop structure, not new instrumentation.

The query patch borrows Namespace's existing immutable insertion-ordered entry
list, then uses namespace-owned declared_function / offered_function projections.
ModuleScope stays private; Entry was already public. The checker interprets no
visibility flag; offered_function calls the one existing private offer rule.
No stored index, cache or second overlap matcher was added. Own private functions
still participate locally and private providers remain hidden. Function order,
canonical routes, P/N proof and diagnostic order are unchanged.

Generated C confirms module_entries (`compiler.c:144419`) returns the existing
list, and both function projections (`144454`, `144487`) return stack
Option[Int] values. Some(entry) is the existing pointer; offer returns the
existing Entity through a stack Result. The old ID-list append/growth path and
OfferedFunction allocation are absent from introduction enumeration. Early
offer checks increase on zero from 16 to all 23 provider functions, and on the
stress inputs from 48/144 to 535/1,047; their carrier cost is not hidden.

The measured allocation savings exactly match source/C representation work:
the runtime grows inline ID lists from capacity four by doubling. Zero's nine
nonempty projections allocate 15 list buffers; eliminating those plus 16
OfferedFunction wrappers saves 31. Each 32×16 provider contributes two projected
lists, each with three buffers, plus one wrapper: 32×7+31=255. Each 128×8
provider contributes two lists with two buffers each, plus one wrapper:
128×5+31=671. These equations explain the observed reduction; they do not claim
all remaining allocations are necessary.

Remaining cost has several owners:

* **Grouping:** the global count map filters unique names, per-module transient
  maps preserve introduction order/counts, and the inherited-ID map reuses exact
  prelude proofs. These are separate temporary facts, not retained namespace
  fields. IntMap records, list/index growth, update/probe/ARC costs remain. On
  zero, 15 global names and seven introduction maps lead to only eight genuine
  groups. Better map representation may lower these constants, but not remove
  independent grouping obligations.
* **Introduction routing:** selected_receiver scans the complete written method
  suffix for each offered shared function. The stress root therefore visits
  32²=1,024 / 128²=16,384 edges, in addition to zero's 192 prelude visits.
  This is avoidable repeated selection work; it is not a slow List get.
* **Canonical candidate collection:** zero's eight groups query 12 method edges
  each, including eight type edges to functionless _base. The stress adds one
  describe group with 44/140 edge queries. Deduplication's listed_function scans
  preceding candidate IDs: 496/8,128 comparisons for the distinct providers.
* **Pair enumeration/head materialization:** describe produces 496/8,128
  unordered pairs, plus eight prelude pairs. The exact shared solver's concrete
  mismatch rule rejects every pair before generic inference. Nevertheless,
  `inference.disjoint_heads` calls `model.type_head` twice per pair; generated C
  RecordHead constructors allocate (`compiler.c:57964`). The stress describe
  group alone therefore materializes **992 / 16,256 RecordHead objects**.
  The 128 count is 85.8% of that candidate's 18,944 added allocations versus
  baseline. This is a source/C-derived contribution, not allocation-site tracing.

The last three mechanisms grow quadratically in independent provider count.
Replacing IntMap with a dict cannot fix pair counts or repeated candidate/edge
visits. A credible bounded next design would consume each selected immutable
edge once and avoid forming cross-head pairs using **the same concrete-head
incompatibility rule** as the shared solver, while generic-head candidates still
reach the solver and canonical first-conflict order is preserved. It must not
become a recursive structural matcher or another persistent index. No such
mechanism was implemented or authorized by this experiment; it needs a reviewed
delta and fresh measurements, not acceptance as a minor lookup constant.

## Provenance and reproducibility

All pilots use Apple clang 21.0.0 (`clang-2100.3.34.2`), arm64 macOS, and
`-O0 -DBLORP_MEMORY_DIAGNOSTICS=1 -lm -lpthread`. Generated C was unmodified.
The frozen host was checked FRESH, SHA-256
`899e0a92cfe1bc91f992bd3ccdd0755448903eb91d91780ac4870bd13d8cfa17`;
no host rebuild ran. The original old source/library manifest verified before
profiling; the original binary/C and negative report are unchanged.

| Artifact | SHA-256 |
| --- | --- |
| frozen baseline pilot | 0f08564c3dd3b1228cc24b9be923cfd5aca33ef398610417ce12aea9e9dbd832 |
| frozen baseline C | e1b044511151d29a97f312a2b12895adc18228df079aef91ec029a9168bb1259 |
| old pilot | c7a6b49c824b2367ba029a0d5b1f383d950f18d2562347597ed260473c7116bf |
| old C | 7dabe83e025dcb91d24d67b684f2bc82ecad70f93f4f82204905171faf55726d |
| borrowed pilot | ff16c0d4a0d51bd1cfd027eceeb169f8c58893228435bef02ee5319ddcf753f8 |
| borrowed C | dc95909b416b5a810dd431f5d4f0fb1977fe18b51dc476e91c1be3dfb45c2b08 |
| borrowed source/library manifest | 15d3145940d3711330925188df623022b4ff1a8159768be7cc18a40e139745f5 |
| old calls-profile pilot | 5f08200044567ae00224eaed3c142a5d3e8cbdb665183a7015ff7b4425ace5d6 |
| old calls-profile C | bebd4510f012ba6ce2f0d8e8cb0c2f34d59ff2b5deb04bd3e14cae4c29753032 |
| old calls output | 8a98ec657a20b2c336f8d2a52e9c5c8383b5a695b11122d334aef74304049dbc |

Zero's input is the repository `blorp_2/test/e2e/fixtures/return/zero.brp`.
Stress main-file hashes are respectively
`2b1b4d11417160e58212cc9ae7eade9bd372afe635453bfb9e05d87bd72976d4` and
`f4cf20218e24914ab9ad510702e6186d0da609ca721428b70651d1e950a034a1`;
the complete provider manifest is retained. All target C hashes are
`8541b77d1cdd6453b8d71aa5f866c2e9cc6860d2129b7aa14ca86fbdd8c54208`.

Raw evidence is under ignored `build/quality-ufcs/attribution/`: `commands.json`
records all exact argv arrays; `measure.rb` reruns the bounded CLI experiment
after serial-slot approval; `samples.json`, `summary.json`, `measure/` retain
every normal/strict/warmup time, stderr, stdout and C; `focused.log` contains
44/44 results; `profile/` retains instrumented C/binary/profile/build logs;
`borrowed/` retains normal C/binary/source manifest/build logs; `old-source/`
preserves pre-query source. `input-check.txt` verifies all retained input bytes.
No historical scratch path is needed to interpret these results.

The entire experiment remains against `fb257c94659a10d09bc6c56215af64c13845bd4d`,
before the accepted question/pattern/private stack. Rebase and remeasure against
that accepted stack, plus independent correctness/design/test-runner gates,
are still required. The current recommendation is **retain the clean query
improvement as a candidate, reject integration acceptance, and review the
quadratic work before any wider run**.
