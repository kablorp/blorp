# Blorp 2 stored callable values

The compiler now represents functions stored in bindings, records, Lists,
captures and results as ordinary typed values. A value contains one typed
operations pointer and its existing managed capture environment. Static
callback specialization remains available through the same checked operand,
body translation and ownership pipeline. Purity is checked before
specialization and has no runtime tag.

Architecture review removed duplicate scoped signature facts, discarded
capture identities followed by re-resolution, and a second emission inventory
walk. The canonical checked binding/capture identities, one source-ordered
operand list, and one explicit checked-to-runtime binding translation remain.
There is no new closure heap wrapper, function-pointer cast, signature
registry, cache, or parallel callable body checker. Coordinator and independent
architecture review approve this model; an additional cross-boundary review
also approves and discloses the reviewer's earlier implementation work.

## Matched compiler costs

Baseline is main `43615cdb459a0ecd221a7f67de253aad749770da`, including the
landed ordered-operand and verified-projection changes. Both source epochs
were compiled by the same immutable Blorp 2 seed
`b4dff9b4fbd1ded4f7b8c0f3148d3e213d5469fa59bfa5be77bd48c8cd14206d`.
The final candidate source inventory is
`a09ee907933b3e9b59e448ad65efdece635b92af03194905334b6fe6874f6cb6`;
the common target-library inventory is
`1c1452d171eb5e216cd789b7179ccd6b6c8c4d87667a7ab2b7257c50be5e813f`.

Normal and diagnostic roles were linked with the same Apple Clang 21,
strict C11 warnings, `-O0` and memory diagnostics respectively disabled and
enabled. Both compiler roles consumed the same physical baseline source43,
library14, cwd and output path. For each input the predetermined normal order
was B,C,C,B,B,C, followed by one strict diagnostic B,C pair: 40 compiler
executions total. Normal instructions use min3; allocations use the strict
diagnostic sample. Runs were serial; unrelated OS background activity was not
excluded. Wall time is not the acceptance metric.

| Common input | Baseline allocations | Candidate allocations | Growth | Normal instructions growth |
| --- | ---: | ---: | ---: | ---: |
| Whole compiler, baseline source43 | 27,286,314 | 27,997,096 | +2.6049% | -0.0968% |
| `return/zero.brp` | 100,140 | 104,415 | +4.2690% | +0.3551% |
| `string_operations/concat.brp` | 105,103 | 109,600 | +4.2787% | +0.4496% |
| `generic/managed/basic.brp` | 105,185 | 109,570 | +4.1688% | +0.3997% |
| `list/empty_string.brp` | 107,216 | 111,691 | +4.1738% | +0.4067% |

All five outputs are deterministic within each role and byte-identical across
roles. All strict compiler reports balance with zero leaks. The four retained
control outputs also pass their real-main, exact-output, strict accounting and
ASan/UBSan checks; their shared hashes permit one native proof per B/C pair.

The predeclared 3% allocation criterion **fails on exactly the four small
controls**. These four recorded comparisons are accepted as temporary debt
under the user's instruction to defer modest allocation regressions. This
does not establish a new 4.3% ceiling or waive future comparisons. Whole-source
allocation and all five normal-instruction criteria pass. The existing
absolute diagnostic-instruction limits fail for both baseline and candidate on
all four small controls; the empty-String allocation limit also fails for both.
Those inherited failures and original 3% failures remain in the raw receipts.
No existing fixture cap changes. Check/Spec review found no obvious redundant
new traversal or retained fact cache; allocation growth has not been attributed
by a measured phase breakdown.

## Correctness and footprint

- All 3,905 hosted component checks pass across 363 maintained suites;
  330 nested runtime checks pass separately. Earlier setup and stale-oracle
  failures remain recorded and receive no passing credit.
- Five dedicated callable native cases pass exact behavior, strict ownership
  accounting and ASan/UBSan. Lower/Own fault mutations fail the intended
  granular predicates and restoration passes all five callbacks.
- The actual target-owned text suite passes, deliberately fails when its
  callback returns False, and passes after exact restoration. All six real-main
  runs pass strict sanitizer checks, normal/diagnostic compiler outputs agree,
  and restored C is byte-identical. This is the first self-hosted suite; other
  component suites still use the temporary legacy TestSuite observer.
- Current-source fixpoint passes: four self-emissions, including both compiler
  roles and the next generation, are byte-identical. Both strict self-compiles
  report 29,571,626 allocations/releases and zero leaks; both strict C11 links
  pass. The direct-List positional mutation fails with exactly exit3 instead
  of exit25; restoration reproduces C and balanced 7/7 ownership counts. This
  proves positional sensitivity, without claiming a COW branch executed.
- The full self-built e2e invocation reports **564 passing fixture checks and
  one failure**, plus **782 passing nested native checks**. Its sole failure
  was the obsolete expectation that a qualified function cannot be stored.
  After changing only that expectation, the complete namespace owner passes
  **19/19 callbacks and 8/8 nested native checks** on the unchanged compiler,
  source43 and library14. This closes the sole failure and covers all 565
  current fixture checks; it is not a second all-green full invocation. The
  original full-run FAIL receipt remains immutable. Its 114 allocation-debt
  records and the focused run's 8 records remain separately visible under
  the existing CI policy; instruction counters are disabled for these e2e
  invocations and measured separately above.
- The obsolete standalone annotated-lambda rejection also uses the unchanged
  executable program as an ordinary accepted syntax fixture. The syntax and
  unsupported owners retain 29 callbacks together, and pass in the full run.
  Both changed expectations now describe unused stored values accurately,
  without claiming callback invocation.

Local qualification used macOS/Clang. The isolated checkout ran the component,
target-text and e2e recipe commands with the explicit frozen TestSuite host and
compiler roles, rather than claiming a literal full `make test` invocation.
The pinned seed remains the production builder; the legacy host is only the
temporary observer for suites not yet self-hosted. Coordinator and independent
review approve landing based on the combined evidence above.

Composed handwritten production grows by **1,203 lines**: compiler/runtime
1,864 added / 719 deleted (+1,145), target test library 58 added. Test owners
grow by 2,334 added / 248 deleted (+2,086), and fixture changes are
147 added / 4 deleted (+143): **+2,229 test/fixture lines**. Counts are per path
with rename detection disabled and include new files. This includes the
test-entry path and mechanical source admission; it is not claimed to be
irreducible callable machinery.
The earlier three-finding cleanup saved 21 lines within the feature, rather
than reducing the feature's overall footprint.

Raw samples, literal argv, full streams, toolchain/environment/source pins,
emitted C, code-review receipts and deliberate-fault evidence are retained
under the coordinator checkout's ignored
`build/self-hosted-tests-goal3/`: `final436-qualification01`, `final-cost40`,
`final-native5`, `host-components-attempt03`, `granular-phase-sensitivity01`,
`e2e-selfbuilt-candidate02`, `namespace-selfbuilt-focused01`, and
`architecture-review-current`. Private environment values are not
published. No release or bootstrap pin is changed by this feature.
