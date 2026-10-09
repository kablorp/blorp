# Mono pack-kind landing, 2026-10-08

The reviewed terminal `TensorVariadicDim` change is integrated onto
`87e312047b4efa1eb320fff4fe22144ac575e66d`. Its 46-file patch remains byte-identical
to the reviewed feature: binary diff SHA256
`2b0b387eae82e90de3e5265508230d6f847ac5d62f030431d28e3d76f41a76ce`.
The validated source/evidence tree is
`0ebd6d460195d6aff21fb5d58bfb6e53d5196142`; this landing report and its evidence
are added afterward without changing compiler or test inputs.

## Current integrated validation

The upstream bootstrap-only commit changed the pin to `dev-0e1598ed616e`.
A fresh O2 build reports that actual `compiled_by` tag, Apple clang 21,
aarch64-apple-darwin, split 8 and memory mode 0. The resolved bootstrap executable
matches the pinned host SHA256
`f0ddd748f51b2f449a46d5bfcf30aeb9c2f2f07468d761514dd408b40ca3ee91`.

| Check | Result |
| --- | --- |
| Build configuration and release toolchain | PASS |
| Package | 49 passed, 0 failed |
| Selected Mono and Core ASan | 2,596 passed, 0 failed |
| Full host premerge | 19,291 passed, 0 failed |
| Required Linux/amd64 CI premerge | 19,291 passed, 0 failed |
| Final FRESH, staged whitespace, source/index/draft guards | PASS |

Host premerge explicitly uses `BLORP_TEST_TIMEOUT=60` and one generated-C audit
worker. Its Docker step is skipped because the separate mandatory CI command is
`scripts/docker-gate --premerge-gate --platform linux/amd64 -- --no-sanitize`.
Linux uses the documented default general 30/runtime 60/leak 60/compiler 360 budgets.
Its sanitizer skip follows the CI policy; host premerge provides macOS UBSan and
selected Core ASan runs separately. Benchmark tooling is skipped because none of
its owning inputs changed. Counts overlap; nested gate counts are not a unique sum.

## Resource authority across the bootstrap update

Both entire compiler C bodies generated with the verified new bootstrap match
the originals by byte comparison: baseline 82,234,569 bytes SHA256
`4523c2344651b2873d67ed77f3a105c98390afe58c15c17164ebffac0c3eed1f`;
candidate 82,234,545 bytes SHA256
`60cdcdd8dbe425e6a42bc012a4764967d1893882e2ee5014557ef83e6c7d2319`.
Candidate C comes from the fresh Make generation; baseline C uses the sealed
3,914-file original payload. Both use the exact Make emission flags.

The 523 paying/generated sources, 10 headers and 19 build/harness/runtime/small
inputs match the original authority except the explicitly verified upstream
bootstrap manifest. Final post-gate rechecking passed, including ignored generated inputs. The independent
bridge review approves this bounded historical compiler-body equivalence.
The [original paired resource experiment](compiler_mono_pack_kind_2026-10-08.md)
retains its exact 5e corpus, versions, raw samples and acceptance ceilings.
This bridge is not a new 87 allocation/instruction measurement, a native-machine
code identity claim or a latest-tree workload cost claim.

## Preserved attempts and evidence

An initial artifact-path guard stopped before any compiler gate; the correction
routes only archived executables to their retained copies. A subsequent 0e host
premerge passed 19,291/0, then its runner stopped because raw index bytes changed.
Independent checks found all 5,768 logical index entries and the full patch
unchanged. The gate's `git status` snapshots are consistent with a bookkeeping
refresh; the exact changed stat/cache field cannot be recovered. That STOP is
preserved, with a separate EXIT-trap/reaping receipt for the actual host PASS.

The first 0e Linux CI attempt lost SSH during the clean build, exited 255 and
returned no compiler verdict. The local runner was consumed and the owned remote
workspace had no surviving container/process in the bounded cleanup observation;
unrelated remote containers were left untouched. Current 87 validation is a
separate guarded run; neither historical STOP is rewritten as success.

The [landing packet](compiler_mono_pack_landing_2026-10-08/README.md) retains raw
commands, gate logs, reviews and boundary receipts. Its manifest distinguishes
original, projected and decoded hashes. Large C files and redundant input/source
inventories remain private with hashes. All foreground children and the supervising session exited successfully, and the
shared native slot was released. Independent code, test-runner and published-byte
reviews are retained in the packet.
