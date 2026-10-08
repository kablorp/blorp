# Independent dictionary getter reader validation

Verdict: correctness, selected sanitizer, emitted-C and scanner gates PASS. Resource/cost acceptance is separately owned and remains pending. No source/test/allowlist/baseline/doc edits or commits by this test-runner.

Base revision: `2ee201fb5cb74e8a7b4f3d068a143d8d71dd2bad`. Parent checkout `<worktree:reader-cuts>`. Reviewed three-path compiler/test/allowlist patch SHA256 `309c7f9089401bdf5b503d6546412893aeee37f5dc21f5312c64d0c3998824db`; full tracked patch `9f017569c13a2d389843f4448d4bce8b87dc2f962d8f417d32fe20b0b5c8c9d3`; untracked resolution design document SHA256 `7ba78a958b7e1fabacc85629eca200f21a45b15ed165f0eb7f541ce0787e2855`. All frozen inputs unchanged throughout this batch.

`BLORP_CLI_C_OPTIMIZATION=-O2 make` succeeded. Repository compiler was FRESH before tests and after all gates, SHA256 `a17a6ed3cdfcac11df20e459bea1b7235a57768194d73551a78c0a76964513ab` unchanged after build. Status: aarch64-apple-darwin, Apple clang21, CLI/runtime O2, split8, memory diagnostics0. Dirty stamp is accurate because the reviewed candidate and unrelated docs exist; compiler source authority is the pinned patch on exact2ee, not an entire clean checkout.

| Gate | Passed | Failed | Result |
| --- | ---: | ---: | --- |
| Selected owning collection + Core sanitizer (`compiler-check --changed --base 2ee...`) | 2,500 | 0 | PASS |
| Additional program specialization suite | 23 | 0 | PASS |
| Serial `compiler-blorp` | 6,775 | 0 | PASS |
| One-worker codegen audit | 232 | 0 | PASS |
| Three focused generated-C pairs | 3 identical | 0 differing | PASS |
| Actual magic enforcement (`--strict`, without `--report`) | 504 allowlisted | 0 new / 0 stale | PASS |
| Identity census (`--check --json`) | 3,446 rows; checked budgets | 0 gate failures | PASS |
| Diff whitespace/hygiene | — | 0 errors | PASS |

Counts overlap across gates and are not summed as unique tests. Actual owning collection output in `broad-logs/compiler-blorp.log` confirms all35 tests pass, including all three admission regressions, the existing nullable/already-specialized key-box controls, and the fresh Int128 key-box ownership/evaluation control. The current manifest selects one production module, this owning suite and `compiler-core-sanitize`; it recommends `compiler-blorp`. Program specialization was not selected, so it ran once separately (23/23). The selected total includes the owning suite and sanitizer; do not count them again as separate unique coverage.

Failure table: no candidate failures, timeouts, retries or compile/setup errors. No fixpoint was needed or claimed; all three retained successful workloads emitted identical C.

| C oracle | Base and candidate SHA256 |
| --- | --- |
| `dict_get_or_fast_path.brp` | `9a563e6059251d228f301d4239360e53b22c6b21a8f458e8d9bfa3f3ae1d126b` |
| `dict_opaque_alias_key.brp` | `16b0e9781c195dcefdfa144044e67988bbb25e4016422a6fe62538e8080121d5` |
| Retained dictionary payload/alias layouts | `a18e191a0703084c8031259be124d424537efff564824d73ff5bd702c09b1559` |

Each compile used `--no-format --no-embed-runtime -o <scratch>`. Base C was captured before production changes with FRESH exact-base stage1 SHA256 `151ef0ac264ffeab97a521c39d02f96a7b627ba0019979ff21c97557db5b2cd8`, after independently confirming 32/35 pass and exactly three intended admission failures. The third oracle's source `dict_get_layouts.brp` SHA256 `7b0d518fdad6eebb494a13ba6f770335936c9d5410822466837c437fb20abb07` copies 12 retained dictionary tests into main, covering primitive widths/Option alias, nullable String, Int128/range/enum/record. Directly compiled runtime behavior was not separately executed; these are C identity checks. The codegen audit supplied its standard generated-C expectation coverage. The opaque-key fixture is a hash/key-layout control, not getter coverage.

The fail-before test file SHA was `f694c647ec8d1bfb9e8493418bce4059c4124f92feab7369ed9ed8922ffa4480`; the candidate test file is `9eb79e7d2dedae1ac09446cd75c1a8b8898deab4e782e42b6835b55cc45633e0`. After successful TDD, root authorized strengthening four binder-name checks in the positive fresh-key control to `core_var_equal`; test count and admission regression tests are unchanged. This candidate suite passed. Original TDD attempt's fourth failure was a test premise error (FloatBox is nonallocating), corrected to Int128Box with no production fix. Its raw packet/pins and exact reconstructed original-content source sidecar are preserved in `/tmp/blorp-dict-get-reader-validation/FIRST_ATTEMPT_PRESERVATION.json`, with explicit reconstruction method/timing; no compiler bug is claimed.

Evidence: `commands.json` gives exact command vectors, logs, exits and before/after fingerprints. `selected-plan.json` records current ownership selection. `candidate-frozen-provenance.json`, `validated-candidate.patch` and `provenance.json` pin source/binary. `c-oracles.json` records byte comparisons. Eight `*-packet/metadata.json` records (build, focused, program, broad, three oracles, codegen) all report `source_changed_during_run=false`; whole-batch source_changed=false. Actual strict evidence is `candidate-magic-strict.log`, separate from census/report behavior. Full raw logs remain untouched.

Owned foreground invocation: `python3 /tmp/blorp-identity-wave-7ab679600/native_slot_serial.py --cwd <worktree:reader-cuts> --wait-seconds 600 -- python3 /tmp/blorp-dict-get-reader-candidate-validation/gate_batch.py`. Session33531 completed exit0; owned slot explicitly released and no test-runner native jobs remain. Background host activity is permitted by repository policy and does not invalidate correctness; no quiet-host or speed claim. No baseline full gates, resource samples, broad carrier work or unrelated repeated gates were run. Root owns resource GO and integration/documentation after independent review/cost acceptance.
