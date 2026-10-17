# Drop-wrapped mixed results preserve branch ownership

The existing compiler's Perceus alias normalizer now descends through `Drop`.
For `Drop(other, If(condition, borrowed, owned))`, only the borrowed result
acquires an ownership unit. The Drop's variable, types, release policy and
location stay unchanged. This is the prerequisite for the separately parked
discarded-result repair, not completion of that repair.

## Scope and regression proof

Production changes only `perceus/results_and_loops.brp`: **9 added, 0 deleted**.
The owning `test_core_perceus.brp` changes **165 added, 1 deleted, net +164**.
The approved ceilings are +15 production / +165 tests. No classifier, new pass,
IR form, runtime or backend rule was added.

Five callbacks cover both mixed orders, nested Drop metadata and acquisition
origins, unchanged wholly owned source identity, and a managed Let whose borrowed
source is read afterward. The owned arm uses the existing `blorp_getcwd`
ReturnOwned contract. The integration oracle derives the real consumed-parameter
contract and checks mutually exclusive releases separately from the final release.

Removing only the nine-line case with the final tests unchanged gives **474 pass /
4 intended failures**. Restoring exact source gives **478/478**. All 473 existing
callbacks and the new wholly owned control pass under the mutant.

| Correctness gate | Passed | Failed |
| --- | ---: | ---: |
| Selected compiler checks, including Core sanitizer | 3,138 | 0 |
| Compiler Blorp suites | 7,229 | 0 |
| Generated-C audit | 241 | 0 |
| Leak gate | 1,270 | 0 |

Counts overlap. These are separate receipts, not a unique-test sum. The scoped
1,216-byte C artifact from the existing emission API shows borrowed-arm-only
acquisition, one release of each local owner, and the final payload release after
its later read. It was inspected, not executed as a new standalone program.
All temporary diagnostic edits were restored exactly.

## Matched O2 acceptance

Baseline source is `4f2bd4bc77410aac3422ae5f4d2bc10ce6ddc234`.
Candidate measurements used `fb9a296ac7775108103a2a430e7653d2ab1737ea` plus
the reviewed source/test patch. The intervening commits change documentation
only; advancing the candidate to 4f2bd4bc preserves that exact patch.
Frozen workload: `6211caf3b88cc6fa8439c1c3943f9c5893649dba`.

Both checkouts used pin `dev-0e1598ed616e`, Apple Clang 21.0.0
(`clang-2100.3.34.2`), arm64, CLI/runtime `-O2`, and matching normal/diagnostic
stage-2 binaries. Each workload has one diagnostic allocation run and three
normal instruction samples. Normal and diagnostic full C agree within each pair.

| Workload | Baseline allocations | Candidate allocations | Baseline minimum instructions | Candidate minimum instructions | Instruction change |
| --- | ---: | ---: | ---: | ---: | ---: |
| Frozen self-compile | 289,858,552 | 289,858,549 | 271,348,249,113 | 271,478,888,274 | +0.048144% |
| Small program | 1,755,591 | 1,755,591 | 1,652,586,215 | 1,654,511,510 | +0.116502% |

Both independently pass allocations `C * 1000 <= B * 1001` and instructions
`C * 200 <= B * 201` (+0.1% / +0.5%). The harness does not enforce these caps;
root checked the unrounded JSON integers explicitly. Wall time is not acceptance.

Small-program C is identical. Self-compile C decreases by eight bytes; the complete
18-line diff moves one borrowed alias temporary and retain inside its Drop body.
Cleanup/read/retain order, the owned concatenation arm and later cleanup are
unchanged. Root and an independent compiler reviewer inspected the delta.

The candidate's O2 fixpoint passes: stage 1, 2 and 3 all emit
`441cbcd5c75847993a4e6168c1890e7ab6925f4a99f29a07e1a3007fe7b6c102`.
This is the existing compiler's self-compilation check, not the Blorp 2 M8 proof.

## Reproduction and retained evidence

Export `BLORP_CLI_C_OPTIMIZATION=-O2` for the entire sequence, then run `make`
and require FRESH build status. Run the
owning suite, `scripts/compiler-check --changed`, serial `compiler-blorp` and
`leak` gates, and the existing codegen audit. Run `scripts/compiler-fixpoint`
at O2. In each checkout run `benchmarks/self_compile_measure --stage2 --samples 3
--input-rev 6211caf3b88cc6fa8439c1c3943f9c5893649dba` for `--program self` and
`--program small`, retaining JSON and C; compare each candidate to its baseline.
Keep compiled calls serial and enforce the two integer caps above.

Raw correctness, mutation and inspection receipts are under
`/Users/keithphilpott/.codex/worktrees/8d2a/blorp/build/host-discarded-option-leak/prerequisite/acceptance/`.
Matched measurements, archived pairs, full C and fixpoint outputs are in each
checkout's `build/host-mixed-drop-costs-6211caf3/`; the baseline checkout is
`/Users/keithphilpott/.codex/worktrees/bootstrap-scope-reset/blorp`.
The source/test-only patch SHA256 is
`3f490514cc85dd3c6810fb3d8e02dba6021ffca7ace724334e6a44e6074a70a6`.
The original discard slice retains the same baseline and cumulative cost caps.
