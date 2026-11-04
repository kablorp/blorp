# Blorp 2 seals static capture environments by value

- **Base:** `fc91dc310` (main, which includes the inline-tuple change).
- **Candidate:** this branch, measured as commit `4be382f46` plus a test-only fix.
- **Setup:** Apple M4, macOS 26.7.1, Apple clang 21.0.0. Every run was serial.

## Change

A capturing lambda passed to a specialized higher-order callee got a counted heap cell. The callee borrowed it and freed it at once.

Specialize now records each capture environment that some instance turns into a runtime closure. That happens in two ways:
- a lambda created as a value;
- a static callable parameter that a body uses as a value, found by `check/model.body_callable_parameter_values`.

`seal_records` seals every other environment as `ValueFields`, a new layout fact: a C struct passed by value, with field-wise `dup` and `drop`. Verify rejects a non-counted environment in a runtime closure, and emit writes the struct and its helpers.

On the self-compile, 144 environment types are sealed by value (190 by-value typedefs against 46). The one environment that becomes a runtime closure (`own.edge_live_owners`, `blorp_r_646`) keeps its cell.

## Result (fixed workload, stage 2)

Measured with `SELF_STAGE=2 measure_fixed_workload.sh BASE CAND OUT BASE`: each side's stage-2 compiler compiles the base `blorp_2/src`.

| | base | candidate | change | ceiling |
| --- | ---: | ---: | ---: | --- |
| strict allocations | 13,359,818 | 12,480,319 | **−879,499 (−6.58%)** | at most −5% |
| -O2 instructions retired, best of 3 interleaved | 11,358,682,470 | 10,962,761,501 | **−3.49%** | at most −2.5% |
| -O2 runs 1/2/3 | 11.366 / 11.359 / 11.359 G | 10.978 / 10.973 / 10.963 G | | |
| atomic RC ops, same input (base src) | 234,078,287 | 233,259,813 | **−818,474 (−0.35%)** | not higher |
| ... record decrements | 77,346,228 | 76,483,064 | −863,164 | |
| ... increments, all kinds | 110,359,871 | 110,390,387 | +30,516 | |
| atomic RC ops, own source | 234,078,287 | 234,217,084 | +138,797 | reported only |
| peak memory footprint (3 runs) | 152.7–154.2 MB | 150.9–152.8 MB | within noise | |
| String fallback copies, calls / bytes | 735,623 / 18,777,406 | 734,692 / 18,788,224 | −931 / +10,818 | |
| production lines (`blorp_2/src`) | | +165 / −25 | +140 net | at most +130; report up to +150 |
| test lines | | +480 / −14 | +466 net | about +250 estimated |

**Output identity.** The outputs differ by design, since code generation changed. Each RC-counting build reproduces its side's output exactly (`cmp`). `make -C blorp_2 test` and `scripts/blorp2-fixpoint --prove` run on the final tree; their verdicts are in the handback. Both strict leak checks balance:
- base: 13,359,818 allocations and releases;
- candidate: 12,480,319 allocations and releases.

**Same-input RC.**
- **Method:** the candidate's tagged counter is built from its `markers/marked.c` and run on the base `blorp_2/src`.
- **The +30,516 increments** are the measured compiler's own new conversion bookkeeping in `prepare_function`, not new `dup`s in generated code.
- **The own-source rise** happens only because the candidate's source is larger.

**Against the spike's census.** The spike counted 873 k static environment cells on `df06da9aa`. The drop here also includes the three environments that this change's own source adds.

## Deviations

- **Production lines: +140 net against +130.** The spike was +126. The additions over the spike are:
  - an explicit-origin `sealed_record_layout`, with an internal error when an environment arrives without a counted layout;
  - the `check/model` query, as its own function;
  - comments.
- **The copies criterion is missed.** `emit.append_value_field_actions` makes 580 String fallback copies (8,700 bytes). Each one builds a field's `value.blorp_rf_N_M` selector from a literal, as the counted arm's interpolated selector already does. Removing them would need `append_storage_operation` to take a selector writer instead of a String, which this change leaves alone. Total String fallback calls still fall.
- **Test lines: +466, above the estimate.** Four new suites drive it, including the emit suite added in review, plus the extra forwarding tests.

## AArch64 copy cost

The spike measured this on `df06da9aa`. Calls that receive an environment larger than 16 B copy at most about 5 M instructions (0.04%), which is included in the −3.49% above.

## Raw samples

The raw samples are in the ignored `build/blorp_2_static_environments/` of the measuring worktree:
- `summary.txt`;
- per side: `leak.txt`, `time_{1,2,3}.txt`, `prof.tsv` and `copies_report.md`;
- RC `tagged.tsv` for the base, for the candidate on the same input, and for the candidate on its own source;
- both `provenance` files.

Self C SHA-256: base `ef4a9993c146a2a2…`, candidate `9012f95342a32960…`.
