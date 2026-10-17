# Existing host compile-time ownership leak

The user's decision of **2026-10-17** permits the existing host compiler's known
compile-time ownership leak as a documented bootstrap limitation. It no longer
blocks Blorp 2 self-compilation. The host defect remains unresolved; its failed
strict result is not green and this decision is not evidence of a repair.

This applies only to the supporting host process compiling target source,
including the host source-to-C proxy. It does not apply to Blorp 2 pilot/compiler
processes A/B/C, fixture compilations by them, native helpers, target programs or
their runtimes, even when the host produced their C. All their existing strict
zero-leak gates and required positive, balanced allocation/release count oracles
remain mandatory.

Completed, valid output and exact status/diagnostic/behavior oracles are still
required. Matched allocation and retired-instruction thresholds, frozen inputs,
source/binary/library/toolchain provenance and C identity requirements remain
binding. Do not subtract leaked host allocations from cost results. This changes
no numerical feature cap, source R0/cumulative or local 3% rule, measurement epoch,
or unrelated acceptance condition. It authorizes no new runner or waiver mechanism.

## Original target-CWD supporting-host observation

The original baseline strict host proxy finished C emission, then failed the
host's exit-time ownership report:

| Observation | Recorded value |
| --- | ---: |
| Process exit | 99 |
| Allocations | 23,224,178 |
| Releases | 22,711,214 |
| Live objects | 512,964 |
| Retained bytes | 34,890,725 |
| Complete emitted C bytes | 7,919,919 |

The arithmetic is exactly `23,224,178 - 22,711,214 = 512,964`.
The raw complete C SHA256 is
`8c1c1996072b62573cd5201dd1ba51096c93e1c21418cc915c70614a3acd0d1c`;
the retained record confirms it matches the B producer. Compiler stdout was empty.

The read-only packet is `build/target-current-directory/cost/proxy/` in managed
worktree `target-current-directory-plan/blorp`. Preserve `strict-B-failure.json`,
`failure-inputs.json`, `strict-B.command.json`, `strict-B.stderr`, `strict-B.exit`,
`strict-B.stdout`, `strict-B.c` and `stop.json`. The stderr SHA256 is
`0825f96db582cb5c7178868e1044b2dfc58e6ed747426ebbb41993705061622e`.
At that original stop only one baseline proxy call had run; seven candidate/normal calls
remained unexecuted. That observation alone supplies no matched proxy-cost verdict;
its original raw files retain their failed strict host status.

Future reports must retain the real exit status and leak counts and identify the
known host limitation separately. Completed C does not excuse compiler errors,
incomplete output, wrong oracles or an unrelated failure. Host repair remains
separate work; pilot/native strict gates and matched cost acceptance still bind.

The [roadmap](ROADMAP.md#cost-and-evidence-rules) and feature plans link here as
the single authority for this narrow user decision.
