# Visibility-width fixture fail-fast refactor, 2026-09-14

This is a benchmark-driver change, not a compiler optimization. Unexpected
local/import registration or name-query failure now ends the current worker
instead of continuing through later loops against a partial view. Expected
idempotent-alias and duplicate-selective outcomes still run and are checked.
The driver separates local registration, import admission, name queries, and
one-iteration observation. Duplicate counts are derived from the validated
alternating attempt sequence, and successful query count follows from every
query succeeding; neither needs a per-attempt counter write.

The regression test first failed against the prior driver: a deliberately
foreign current-module ID returned a partial `Some(result)` instead of `None`.
After the refactor, `bin/blorp test
blorp/test/compiler/pipeline/test_module_binding_benchmark.brp` passed 7/7,
including batched and sequential invalid-owner cases. Valid output checksums,
bound/import counts, duplicate counts, and query hits are unchanged.

Two cached, direct worker binaries were built with the same current `bin/blorp`
and Clang `-O2`. The *worker executable*, not the benchmark shell wrapper, was
timed with `/usr/bin/time -l`, so cache hashing and wrapper work are excluded.
Each run used 100 iterations and 16 modules. One paired run per shape, plus a
reverse-order repeat for the wide shape:

| Shape (aliases/selectives/locals/duplicates/queries; batching) | Before instructions | After instructions | Before/after allocations | Output |
| --- | ---: | ---: | ---: | --- |
| 32/32/16/16/128; both batched | 144,627,981 | 144,145,360 | 45,501 / 45,501 | identical, `status=OK` |
| 32/32/16/16/128; both sequential | 178,916,931 | 178,751,533 | 65,701 / 65,701 | identical, `status=OK` |
| 128/128/64/64/512; both batched | 850,703,440 | 848,918,164 | 179,901 / 179,901 | identical, `status=OK` |
| Wide reverse-order repeat | 851,980,640 | 847,823,213 | 179,901 / 179,901 | identical, `status=OK` |

The wide direct-worker instruction reduction is about 0.2–0.5% across these
pairs, with allocation parity. Executable size fell from 1,953,824 to
1,936,336 bytes (0.9%). Single-run elapsed time, RSS, and peak-footprint
samples are too noisy here to claim a user-visible improvement. Most
import-admission instructions remain in the production API, so this small
driver reduction does **not** close the Step 2e Cut A resource gate reported
in [the historical scorecard](compiler_step2e_cut_a_gate_2026-09-14.md).
