# Independent first-pair resource verdict: PASS

Scope: the two reviewed parent cuts only (semantic variable equality and exact parallel filter-map predicate reuse). No vector integration, schema change or performance gain is claimed. Existing correctness evidence (2,567 selected, 6,760 broad and 232 C audit checks) was not rerun. No source, test, docs, baseline, allowlist, harness or raw-result-metadata changes; no rebuild, commit or push. All owned jobs finished; shared native slot released.

## Protocol correction and availability

The first wave3 scheduler wait was cancelled while unstarted, exit 143, following the coordinator's correction. Current `benchmarks/README.md:1892–1897` and `docs/WORKER_CHECKLIST.md:139–142` explicitly permit concurrent background work and require minimum retired instructions across repeated runs rather than wall time. A clean-host veto was an additional coordinator restriction, not the repository gate. Prior rejected measurements remain excluded; this report uses four fresh harness invocations only. The cancelled controller/log are preserved as `resource_wave3.py` and `scheduler.log`.

Corrected foreground command:

```sh
python3 /tmp/blorp-identity-wave-7ab679600/native_slot_serial.py \
  --cwd <worktree:reader-cuts> \
  --wait-seconds 600 -- \
  python3 /tmp/blorp-identity-wave-wave3-resource/resource_wave3_protocol.py
```

The shared owned-job lock was acquired. The controller runs every command sequentially with `BLORP_CLI_C_OPTIMIZATION=-O2`; full exact argv/cwd/UTC windows/exit results and foreground background-activity records are `resource-commands.json`. `protocol-scheduler.log` records overall completion, exit 0. External activity is observed without killing processes or relaxing any source, toolchain, input, C identity or 0.5% check. Wrapper records say `protocol=repository min-of-runs` and honestly record `quiet_window=false` for all four measurement invocations. No wall-time inference is made.

## Provenance and identity

Base: 7ab679600bcefa2fda3d0a14fe4b432758bad91b. Baseline compiler source is exact base; its formatting-only fixture diff explains the dirty checkout/version stamp. Candidate is the previously validated first two cuts in parent 2c1f. Both freshness checks and final candidate freshness report FRESH; source patch hashes match the prior validated retained-pair records.

Retained pairs are stage2, O2 CLI/runtime, Apple clang 21.0.0 (clang-2100.3.34.2), compiled_by self-7ab679600bce, memory modes 0/1:

| Pair | Normal SHA256 | Diagnostic SHA256 |
| --- | --- | --- |
| Baseline, nominal-type-identity/bin | 789ea481aa37eb676449d1fb65ea7f5492f4d5835d05e0335477faac1acba859 | 5df0efcfb1ec8bff9948b19e22c273d3361bace65128e0de4450ea8309d96b29 |
| Candidate, 2c1f/bin | 720cf00fbb7ba640980fcdf92f7676d2bb7ab9ce3cf69f8de6e06fe2e74c7148 | 902f5adad5eac44b922b8a5dda40f3058b2511cf548227e6d5c2f32152729963 |

Full version strings and absolute paths are in `stage2-pair-provenance.json`. Verified all 3,871 tracked shared frozen files against `git archive` at base; generated embedded std/inventory hashes are in `frozen-input-provenance.json`. Checkout-local small input hashes both match 6a67158fb09aac383ec40e77e5c5b1d64fd068b19edf6e2596a6f25060d9cc93. Post-run binaries, compiler source diffs, frozen inventory and small inputs remain unchanged (`post-run-input-pair-checks.json`).

Each explicit-pair harness invocation uses `--input-rev` base, the same verified `--input-dir`, `--samples 3`, retained `--compiler` and `--diagnostic-compiler`, `--output`, and `--keep-output`. Candidate calls add the corresponding fresh `--baseline` and `--require-identical`. Normal/diagnostic C identity is checked for every sample. Raw harness JSON still reports `compiler_stage=1`, because that field follows the rebuild flag; actual stage2 identity is established by pair hashes and construction provenance. No metadata was altered.

Whole generated C:

| Program | Bytes | SHA256, identical across both pairs |
| --- | --- | --- |
| self | 83,979,351 | 4c4a5cc547c51e405a0c0aa1a707f812966c694496d5ca17e1eb1b8c9fc733e1 |
| small | 40,512 | 8316ceeb6e78c5e7d6431c33d1a22b0b9ff9bb59b2ecd603fbc38b8a5b618abb |

## Matched resource result

All phase allocation deltas are byte-for-byte equal as numeric mappings. Minimum retired instruction counts use three normal samples per side/program. Both primary metrics meet the unchanged maximum increase of 0.5%.

| Program | Allocations base → candidate | Delta | Minimum instructions base → candidate | Delta | C | Ceiling |
| --- | --- | --- | --- | --- | --- | --- |
| self | 245,056,112 → 245,056,112 | +0.000000% | 229,157,014,450 → 229,357,161,486 | +0.087340567% | IDENTICAL | PASS |
| small | 1,689,044 → 1,689,044 | +0.000000% | 1,596,202,656 → 1,596,939,719 | +0.046176029% | IDENTICAL | PASS |

| Instruction samples | Raw counts, run order | Minimum | Maximum | Range / minimum |
| --- | --- | --- | --- | --- |
| self baseline | 229395679419, 229157014450, 229166683493 | 229,157,014,450 | 229,395,679,419 | 0.104149% |
| self candidate | 229381394303, 229402331573, 229357161486 | 229,357,161,486 | 229,402,331,573 | 0.019694% |
| small baseline | 1596202656, 1597768721, 1598054054 | 1,596,202,656 | 1,598,054,054 | 0.115988% |
| small candidate | 1599730856, 1599269764, 1596939719 | 1,596,939,719 | 1,599,730,856 | 0.174780% |

Verbatim standard-harness comparison tables, including every phase allocation row and IDENTICAL output lines, are retained in `comparison-tables-verbatim.md`; original tables remain in `resource-candidate-self.log` and `resource-candidate-small.log`. Derived exact deltas/ceiling booleans are `resource-summary-self.json` and `resource-summary-small.json`. Raw measurements and generated C are retained under corresponding resource-baseline/candidate-self/small filenames.

Background caveat: the monitored full baseline-self invocation observed 47 matching external PIDs, candidate-self 7, and each small invocation 2. This count includes process wrappers and read-only planning among actual compiler/build/test work; it is not a load metric or proof of individual-sample placement. Foreground monitoring excludes the controller's ancestor/descendant processes. Repository min-of-runs acceptance applies despite that activity; the small positive deltas do not demonstrate a speedup or wall-time improvement. Existing earlier noisy records were not reused.

No failure or additional retry. Recommend acceptance of the first two cuts' resource/whole-output gate within this scope; coordinator owns integration and any remaining landing policy.
