# Blorp 2 namespace and lowering rebase

The reviewed namespace and block-lowering preparations have been rebased onto
main `d411c7bb0406df3d78aa93382e5d9babf25fb620`. Structural preservation,
fresh matched CLI costs and fresh lowering-phase evidence are independently
approved with zero findings. The final required-instruction pilot gate passes;
independent final source and receipt review approves this checkpoint with zero
findings.

## Integration and provenance

The accepted pre-rebase checkpoint was `833971ffb`; the rebased checkpoint is
`dc9b4a737`. Only the new plan, namespace and lowering commits were replayed.
Older implementation commits already on main were not replayed. The historical
[authority report](blorp_2_authority_fixes_2026-10-13.md) was restored byte for
byte in a reviewed documentation commit; its SHA256 is
`9d867bf8de0d82a4744a5b141a179fb0080d8f0c7d239133a01530bda47f1b39`.

All 17 reviewed production/test file hashes match the pre-rebase manifest.
Five incoming pilot files match main exactly; README retains main's instruction
policy and the reviewed namespace addition. All host compiler/runtime, build,
scripts, standard-library and other main paths remain unchanged from main.
There were no conflicts. Other worktrees were not changed.

`make` rebuilt the host and `scripts/compiler-build-status` reports **FRESH**.
The build label is `eb3883366867-dirty`, reflecting the documentation restoration
during the build, not different compiler inputs. The compiler source/build tree
matches main. Both measured pilot compilers and both phase probes were generated
by that same fresh host and linked with Apple Clang 21.0.0, `-O0`,
`-DBLORP_MEMORY_DIAGNOSTICS=1`, `-lm -lpthread`. The host uses the pinned
`dev-0e1598ed616e` bootstrap, CLI `-O0`, runtime `-O2`, eight-way split.

All artifacts are under ignored `build/next-increments-20261014/rebase/`:
`before.json`, `authority-report-before.md`, `baseline.tar`, `provenance.json`,
host build logs, generation/link logs, the fresh compiler and phase C/binaries,
and raw probe samples. The baseline archive contains current main's complete
pilot tree; the candidate contains the reviewed namespace and lowering changes.
Historical pre-rebase binaries and C were not reused as current evidence.

| Artifact | SHA256 |
| --- | --- |
| Fresh baseline compiler | `49263abc67d3f7ea42866bc6d3b5cd8fef7ac19cb0c7658305df4a5399edeb25` |
| Fresh candidate compiler | `e4800c0928c39e2201ebccf6da83ea84d9fc9ec571f864540e2026f8ef11fad3` |
| Candidate compiler C | `805043d0caa4d6d192b178bf68f1e80c82f1c08b6b9fc1ef5ba785a51072f087` |
| Fresh baseline phase probe | `abc0ead83d36f98990d33dc372102e1677776d508dfcb11d1ab6242d8f1a6a71` |
| Fresh candidate phase probe | `23c9693b103ded9f1b3cef3c277c4434576f01d5c01202e360c5f03aad38e789` |
| Candidate phase C | `3011f4d70eefa954e5bb285a92d358daedcb4351025eb80efb40fb3c59763c47` |

Native compiler links have existing host-generated warnings: baseline
3 discarded qualifiers, 59 equality-parentheses and 9 pointer/integer compares;
candidate 3, 41 and 9 respectively. This is not a warning-free compiler claim.

## Fresh matched evidence

```sh
ruby build/authority-fixes/measure.rb \
  build/next-increments-20261014/rebase/compiler-candidate \
  next-preparations-rebased-20261014 3 \
  build/next-increments-20261014/rebase/compiler-baseline
```

The frozen 36-input corpus was compiled through the same copied runner and
library/output paths, with three alternating pairs per input: **216 runs**.
Allocations are deterministic, every process balances allocations/releases with
zero leaked objects/bytes, and target C is byte-identical for every input.
Maximum allocation increase is **0.299562%**; every input's minimum retired
instructions decreases, with the smallest reduction **0.259053%**. The unchanged
**3% per-input** preparation ceiling passes for both metrics. Raw samples,
input/C/binary hashes and activity snapshots are in
`build/authority-fixes/next-preparations-rebased-20261014/`.

These are combined namespace/lowering owned-input CLI proxies, not
self-compilation or separate attribution of the lowering change.

The same retained phase source was built against current-main and candidate
snapshots, then measured by `lowering/measure_phase.rb`: 72 runs each, widths
16/32/64/128 for statements, wide calls and deep expressions. Setup precedes
the interval; each adjusted instruction sample uses
`(min(R128) - min(R0)) / 128`. All 144 processes balance, deterministic interval
allocation counts and definition checksums match their expected work. Raw
samples and comparison are in `rebase/phase-*-runs/` and
`rebase/phase-comparison.json`.

| Shape, width 128 | Allocations before → after | Instructions before → after (rounded) |
| --- | --- | --- |
| Statements | 2210 → 2226 (+0.724%) | 7664015 → 4609434 (−39.856%) |
| Wide arguments | 2743 → 2119 (−22.749%) | 9426532 → 7515778 (−20.270%) |
| Deep expressions | 1058 → 1065 (+0.662%) | +1.354% |

Small deep-expression instruction increases remain: +2.611% at width 16 and
+2.666% at width 32. Statement width 16 allocations increase 306 → 316
(+3.268%). These are the already-reviewed owning-phase tradeoffs, not a claim
of universal non-regression or an exception to the whole-CLI ceiling.

Fresh generated C confirms local destination ownership before growth for
arguments (compiler C line 82370), record fields (82498), recur arguments
(83059/83085), statements (83266), captures (83580), complete arms
(83712/83753), arm lists (83939), parameters (84085), complete functions
(84268/84309) and program functions (84454). `ExpressionBuilder` contains only
the value cursor and definitions. Initial parameter/capture snapshots are
distinct from the later unique append roots. Recursive `define_value` still
retains its shared vector before growth (82217/82234); that inherited expression
copying remains explicit debt. No whole-compiler linearity is claimed.

## Final acceptance

```sh
env BLORP_2_INSTRUCTION_CHECK=required make -C blorp_2 test
```

| Check | Verdict |
| --- | --- |
| Independent structural and hash preservation review | Approved, zero findings |
| Fresh matched costs and physical C review | Approved, zero findings |
| Fresh phase samples and scaling review | Approved, zero findings |
| Required-instruction pilot gate | Exit 0: 2120 passes in 138 unit/runtime/grammar suites, 325 e2e cases; one Generate/Link, empty stderr. `rebase/final-pilot.{stdout,stderr}.log` |
| Independent final source/evidence review | Approved, zero findings |

Pre-rebase regression and mutation evidence remains in the
[namespace report](blorp_2_namespace_publication_2026-10-14.md) and
[block-lowering report](blorp_2_block_lowering_2026-10-14.md). Those production
and test files are unchanged after rebasing. Net handwritten production change
is **−129 lines** (namespace −151, lowering +22); tests grow **775 lines**.
General Lists, fresh updates and recursive data remain later increments.
