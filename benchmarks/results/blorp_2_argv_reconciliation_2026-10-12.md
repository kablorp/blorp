# Argument regression preservation after imports integration

## Baseline and scope

The pending argument work in worktree `1332` started from
`45f59148cf3671faa7ed65f09a41c56f45f87b80`. The newer local `blorp-2` includes
that capability and the more complete module/prelude implementation at
`e950541abeb9c276c07fdf4986582e5f4d300465`.

The pending branch was rebased onto that revision. The original 92 changed
paths were first copied and hash-verified in the ignored local
[recovery archive](../../blorp_2/build/reconcile-20261012/manifest.json).
That archive includes the complete tracked patch, pending files, and original
untracked files. It preserves the old work without applying its obsolete
compiler or library implementation to the new baseline.

This slice adds regression coverage. It retains the merged implementation,
foundation modules, namespace identities, reachable specialization, runtime,
CLI, and fixture cost ceilings. It adds no production infrastructure or
language capability. The stricter builtin List binder naming rule from the
pending work is not adopted: the current grammar's identifier rule remains
authoritative.

## Selected tests

- [List call ownership](../../blorp_2/test/unit/test_option_ownership.brp):
  reject incorrect List/index argument types, an unmanaged managed argument,
  an incorrect result type, and swapped accepted Option variant roles. Check
  that last-use analysis observes both the List borrow and index.
- [List root ownership](../../blorp_2/test/unit/test_list_ownership.brp):
  validate the positive counterparts, then reject forged unmanaged/fresh
  parameter ownership, an incorrect parameter borrow dependency, and a
  duplicate drop. Invalid cases change one invariant of a valid input.
- [Entrypoint and generic phases](../../blorp_2/test/unit/test_list_phases.brp):
  distinguish declaration identity from concrete instance identity; reject
  unsupported List elements exposed only inside a reachable generic body;
  reject unbounded generic growth through nested List types at checking.
- [C pointer qualifiers](../../blorp_2/test/unit/test_argv_phases.brp):
  protect both borrowed bindings and owner aliases without pinning generated
  register numbers.
- [Runtime selection](../../blorp_2/test/unit/test_list_runtime.brp): a
  reachable union with a List payload needs the List runtime even when main
  takes no arguments and the program constructs only the empty variant.
  The old unused-helper example is not copied because unreachable functions
  are correctly omitted by the merged specializer.
- [Native child lifetime](../../blorp_2/test/e2e/fixtures/argument_input/escaped_string.brp):
  keep the merged fixture's boxed List alias path, then retrieve the child
  again after the first temporary Option is destroyed. All four existing
  input cases check the doubled exact output and original status.

## Evidence provenance

The original pending work's [report](../../blorp_2/build/reconcile-20261012/pending-files/benchmarks/results/blorp_2_arguments_2026-10-12.md),
[design](../../blorp_2/build/reconcile-20261012/pending-files/blorp_2/ARGUMENTS_PLAN.md),
and [validation entrypoint](../../blorp_2/build/args/README.md) remain local
historical evidence. The successful-get-retain mutation previously produced
17 ASan failures and three absent-child control passes. Its matched costs
describe the pre-import pending compiler and must not be attributed to this
rebased slice. The merged branch's original argument/import reports are kept.

Fresh validation and independent expert review for this slice are recorded
under `blorp_2/build/reconcile-20261012/`. The host was rebuilt after the
rebase and reported FRESH at `e950541ab` with CLI `-O0` and runtime `-O2`.

## Fresh validation and review

| Check | Result | Packet |
| --- | --- | --- |
| Focused phases/runtime selection | 37 callbacks pass | `phase-unit-final` |
| Focused ownership | 42 callbacks pass | `ownership-unit` |
| Strict unit/runtime/grammar/tooling | 1,610 Blorp callbacks and 35 String C checks pass; 22.854 s | `final-strict` |
| Full end to end | 216 grouped checks, 313 native executions, 192 measured fixture compilations; one pilot build; 128.234 s | `final-e2e` |
| Pointer qualifier fault injection | Unchanged copy passes all eight argv checks; mutant fails exactly the two new checks, with six controls passing | `qualifier-oracle`, `qualifier-oracle-mutant` |
| Successful-get retain fault injection | Normal argument suite passes all 15 native inputs; mutant produces 13 ASan heap-use-after-free reports, with both absent-value controls passing | `phase-argument-e2e-bound-status`, `get-retain-oracle` |

The current qualifier mutant changes only the two List pointer declaration
arms in an ignored source copy; its copied unit tests are byte-identical.
The current retention mutant changes only the successful-get child retain in
an ignored compiler source copy, builds normally, and runs the existing
argument suite with its compiler path passed explicitly. Fixture inputs and
generated C are not rewritten. Source-copy delta records, compiler build
receipts, and all 13 ASan logs remain in the same local evidence directory.
These fresh 13/2 results are distinct from the historical pre-import 17/3 run.

Both final integration packets record no source drift. Strict diagnostics
report balanced compiler/test-process managed allocations; they do not count
each native List object. Independent generated-C inspection confirms the
first Option's destruction precedes the second lookup, and the wrapper keeps
the argument root alive until main returns.

Two separate compiler-expert subagents reviewed the integration: one as
code-reviewer and one as independent test-runner/reviewer. Both approved with
zero blockers, should-fixes, or nits, including the fresh mutation evidence.
The result adds 17 unit callbacks and strengthens the existing four-case
lifetime fixture. Production line delta is zero; tests grow by 321 inserted
and nine deleted lines, net 312. There is no performance-change claim or
reason to repeat old matched compiler measurements for unchanged production
inputs. `git diff --check` passes, and compiler source and target library
remain identical to the baseline.

Native tests use real main, unchanged emitted C, explicit arguments, `-O0`,
ASan and UBSan. Neither the old evidence nor this slice proves exact final
per-List allocation/destruction totals or native LeakSanitizer coverage.
