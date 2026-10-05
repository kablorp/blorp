# Explicit-source binary equality pilot

Pre-commit measurement snapshot, recorded 2026-10-05 09:53:55 UTC. Statements
about no commit and pending independent acceptance describe this snapshot, not
any later integration state.

Artifact root: `/tmp/blorp-explicit-eq-baseline.AsZOhr/`. All relative raw log,
Core, C and fixpoint artifact names below refer to that scratch root, not the
durable `benchmarks/results/fixed_union_explicit_eq/` evidence directory. This
report is copied byte-identically into that directory as `EVIDENCE.md`.

Production owner: `blorp/src/compiler/stage_06_typecheck/infer.brp` only.
Base: `073b78ae63d82273fe918be8c3e80e49172bc527`, branch
`codex/fixed-union-explicit-eq`. No commit, merge, push, bootstrap pin, or
automatic/default Eq synthesis was performed.

## Scope and provenance

Concrete non-generic accepted records and ordinary/fixed unions with explicit
pure `Equatable.equals` or independently selected `not_equals` methods now use
existing selected typed calls. Exact builtin TraitId and graph CallableId are
retained. Existing assignability, bounds, dimension, debug and resource call
checks are reused; parsed-call argument inference is unchanged. Operands are
inferred once in source order.

Actual builtin/scalar/resource/legacy-enum kinds, generic declarations, original
uninstantiated generic signatures, and accepted nominal aggregates containing
resources remain outside the route. No new semantic schema or Core/CTFE owner.
The namesake trait control verifies only unchanged scalar comparison, not
aggregate namesake or aliased-trait implementation closure.

Frozen infer SHA256:
`b181362e32036251fbd81b3993fef45abf0cbfab7dffbf1ec59a202d5d282828`.
Candidate bin SHA256:
`4611891e58f941a14acaedc203e7c867e87f054f759e3c4182a77d22d7da1036`.
FRESH stage1, O2/O2, bootstrap `dev-d44472d3a5d0`, Apple Clang21,
8-way split, memory diagnostics disabled, metadata `073b78ae63d8-dirty`.

## Failure-before / success-after

Pristine 073 baseline bin SHA256:
`e35cefd0a9e3189ddaa5a795cfc75ed80fd837a7f18c25b95d0834dd6bc972b3`.
Original four-test baseline: 2 PASS, 2 FAIL (`regression.log`); folded equals
and folded independently overridden not_equals fail, runtime controls pass.
Raw log SHA256:
`c65f5a0ac06d0be0cbf58f957c1ca1d9defe49e1f4f64941323268e942ce2a4c`.
The first candidate original four controls pass; expanded six-test raw log is
retained as `candidate-regression.log` (5 PASS, 1 known default-method FAIL),
SHA256 `6e2207bc8ab61c0a62fb4e729b5ff675a21f9ca76d431c1004451fd4f202bf53`.

Final expanded runtime corpus: 9/9 (`frozen-regression.log`). This is NOT the
original four-test baseline corpus: it also covers imported explicit impls,
transparent receiver aliases, source-order/evaluation-once, scalar namesake
control, and ordinary/fixed union explicit folding/runtime methods.

The separate alias minimization comparison uses a FRESH 073-derived compiler
with unrelated `MemoryCounter` standard-library additions, NOT pristine073.
Its bin SHA256 is
`d4866fa2cafa0da8948bdc124da1d67b5801775d73f5bf7114015367f84add3b`.
Its compiler infer source is pristine073, SHA256
`d4f90542f236a4448afa3475551425e8641088032dd5e41afe3eaa2d884dbdd3`.
Expanded seven-test comparison: 4 PASS, 3 folded FAIL (`final-baseline.log`).

## Known failures retained, not closed

Manual repros under `benchmarks/results/fixed_union_explicit_eq/` are outside
passing gate discovery and retain unchanged intended results.

* `default_not_equals_repro.brp`: 1 runtime PASS, 1 folded FAIL
  (`default-manual.log`). Accepted declaration preparation skips default method
  facts. Outer raw binary wrongly folds structurally; the default body's CTFE
  intrinsic equals is UNSUPPORTED, not structurally evaluated. Follow-up must
  publish existing valid default callable facts and preserve selected inner
  calls or observe a safe runtime fallback. No hardcoded negation was added.
* `aliased_builtin_impl_repro.brp`: baseline and candidate reject before this
  route with `internal typecheck error: invalid accepted implementation record
  for trait 'Equatable'` (`alias-only-baseline.log`, `alias-only.log`). The
  transparent receiver alias and unrelated namesake controls pass separately.

## Generated output audit

`frozen-lower-core.log` SHA256:
`d992f875006dcf1c12425a4836643a48503130b47764947e4854eeb449e46a97`.
Core selected callable IDs match explicit methods: record 122/123,
ordinary union 149/150, fixed union 152/153, each exact builtin Equatable
equals/not_equals respectively.

`frozen-regression.c` SHA256:
`987d9a04a959d00df0124aeb3a194533dcc6e19c10621799d8eea4006ca40735`.
Generated from the exact nine-test fixture plus a scratch runnable main and
exact helper copies. All eight folded Eq/Ne constants are 1; runtime calls
preserve distinct selected methods. File-trace operands run A,B then C,D once,
with both operand releases. Scalar comparison remains C `long == long`.
Codegen changes are intentional; no baseline/candidate byte-identity or
performance claim is made. Initial missing-main and forbidden dotted-path
scratch compile attempts are retained as harness setup diagnostics.

## Final gate results

* Owning declaration typed-AST suite: 170/170 (`decl-premise-final.log`),
  including exact selected IDs and non-vacuous resource exclusion premise.
* Actual `compiler-check --changed --base 073b78ae6`, O2: 519/519,
  five selected suites (`compiler-check.log`). Plan is routing only.
* Actual `compiler-check --stage ctfe`, O2: 191/191,
  11 suites plus dependency-demand special check (`ctfe-check.log`).
* Warmup prerequisite: exit0 (`warmup.log`).
* Actual compiler-blorp: 6520/6520 (5690 suites +830 check fixtures),
  `gates/compiler-blorp.log`.
* Actual serial runtime: 4673/4673 (`gates/runtime.log`).
* Actual serial leak-check: 1165/1165 (`gates/leak.log`).
* Actual serial Core ASan/UBSan: 2375/2375
  (`gates/compiler-core-sanitize.log`).
* Combined broad gate: 14733/14733 (`broad-gates.log`).
* O2 fixpoint: PASS exit0 (`fixpoint.log`); all three raw C stages are
  75,576,724 bytes, SHA256
  `6b395442baf9f17ce565237323eb2bf452005a0f259d13a500fa00d93ae97060`.
  Stage2 binary SHA256:
  `976be0b9c6c5458fe91fe7461502884e0d9dbbfbed6f45b7aae4b61220ba0465`.
  Stage3 binary SHA256:
  `838b65ee4364af8d49512704d8317008d27da4cd876c818b5ab818ec9dd767dd`.
  Raw outputs and binaries are retained under `fixpoint/`.
* Existing generated-C audit, `--jobs 1`: 228/228 (`codegen-audit.log`).
* Final standalone original four: 4/4 (`original-four-candidate.log`),
  SHA256 `265ebb58a219b6a84176969f4e60006b1858bbae2ba309ebe640d3ad91936c6b`.
* Expanded fixture stage1 and retained stage2 per-test leak-check: each 9/9,
  zero tracked live objects per exercised test (`fixture-leak.log`,
  `stage2-fixture-leak.log`), identical log SHA256
  `61d52ba6a4fd39ec98a660b7cbfa3e5a4d4f45a81597e3c776ba249d1f3df034`.
  The final process 3 allocations/3 releases is a post-suite harness interval,
  NOT total fixture allocation cost: the suite resets counters before each test
  and again before returning. This is scoped leak coverage, not universal proof.
  Stage2 version reports self-073b78ae63d8, O2/O2, split8, diagnostics0 and
  Apple Clang21 (`stage2-version.log`).

### Commands

```sh
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --changed --base 073b78ae6
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --stage ctfe
scripts/test --serial --no-build --log-dir /tmp/blorp-explicit-eq-baseline.AsZOhr/gates compiler-blorp runtime leak compiler-core-sanitize
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-fixpoint --work-dir /tmp/blorp-explicit-eq-baseline.AsZOhr/fixpoint
bash blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh bin/blorp --jobs 1
bin/blorp test --timeout 180 /tmp/blorp-explicit-eq-baseline.AsZOhr/test_original_four.brp
bin/blorp test --timeout 180 --leak-check blorp/test/runtime/types/test_explicit_binary_equality.brp
/tmp/blorp-explicit-eq-baseline.AsZOhr/fixpoint/blorp-stage2 test --timeout 180 --leak-check blorp/test/runtime/types/test_explicit_binary_equality.brp
```

### Failure table

| Boundary | Outcome | Scope |
| --- | --- | --- |
| Original baseline four | 2 folded FAIL / 2 runtime PASS | Fixed by this cut; final standalone 4/4 |
| Default-method manual repro | 1 folded FAIL / 1 runtime PASS | Open; unchanged expectations, excluded from passing corpus |
| Aliased builtin impl manual repro | Same preparation error before/after | Open; excluded from passing corpus |
| Required candidate gates above | No failures | Actual commands completed |
| Generic/default/native migration closure | Not attempted | Explicitly outside this cut |

No failed gate was weakened, timed out differently, or rewritten to pass.
Selected focused gates and broad gates overlap; their counts are not unique
coverage totals. Staged and unstaged whitespace checks, including new manual
evidence files, are clean. Independent review/test-runner acceptance remains
the next integration prerequisite.

Runtime fixture SHA256:
`5b5fe03be16ca2251cd0d02d03e6d9be74289e72d7cf53f1e4bc84694ab24935`.
Final declaration test SHA256:
`7543a39e7203c3143ec09e804536ca3aa6f92227fe0d45a3c20805bd30db8746`.
Imported helper SHA256:
`bf05ae672483579f0ad24da16594913f0746f85fa11f2a8b58ea05234133997d`.
Namesake scalar helper SHA256:
`fcffc084407c928875fea9841fdc327f025aa442aa667c9915afd68fc1a2b86a`.
All full logs and raw outputs remain at the artifact root
`/tmp/blorp-explicit-eq-baseline.AsZOhr/`, not beside the durable evidence copy.

## Post-snapshot bounded formatting audit (2026-10-05)

A final independent format check exposed noncanonical added hunks alongside
pre-existing file-wide formatting debt. Pristine073 inputs were exported using
read-only `git archive`; baseline and candidate scratch copies were formatted
with the same FRESH formatter. Initial complete formatter deltas are retained
at `/tmp/blorp-explicit-eq-format.OOgond/` as `infer-candidate.diff` and
`decl-candidate.diff`, with pristine `*-baseline.diff` comparisons.

Only added helper/test hunks, added TypedExpr import wrapping, the new equals
NameId import placement, and the two added test-list entries were canonicalized
via apply_patch. Unrelated imports and existing bodies were not reordered or
reformatted. Remaining full formatter add/remove lines match pristine073
exactly as multisets: inference 98 lines, declaration test 648 lines; diff
interleaving differs in a few repeated closing lines. No new-hunk formatting
change remains. Whole-file `format --check` therefore still reports existing
baseline debt; it is not represented as a passing file-wide format gate.

Final formatting-only production SHA256:
`8a7b15e73de616e2f2606d094ca65a779b35a4a49de1378e0932d212ede5e4af`.
Final declaration test SHA256:
`e7657a84364ef70d78f5ee3fb3a621e11ed7927cc5b65bdd0ad306fe18aec991`.
Runtime fixture/helper source bytes are unchanged. O2 rebuild is FRESH and
produces the same bin SHA256 `4611891e58f941a14acaedc203e7c867e87f054f759e3c4182a77d22d7da1036`.
Focused final reruns pass runtime9 with per-test leak checks and declaration170
(`runtime.log`, `decl.log` in the formatting artifact root). Recompiling the
SAME unchanged scratch input `/tmp/blorp-explicit-eq-baseline.AsZOhr/codegen_main.brp`
produces `formatted-regression.c`, byte-identical to the retained original C,
SHA256 `987d9a04a959d00df0124aeb3a194533dcc6e19c10621799d8eea4006ca40735`.
No semantics changed. Identical rebuilt binary and same-input C support reuse
of previous broad/fixpoint evidence; no repeated broad gates were run for this
formatting-only correction. Independent final-byte acceptance remains required.
