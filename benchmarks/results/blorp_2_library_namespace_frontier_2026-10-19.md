# Actual compiler-source namespace frontier

This is an isolated integration result, not acceptance of the pending library
features. Planning main is `afc3527ecbd98119b02012e06f298aa84ff2ecc1`.
The candidate is in the managed `codex/library-namespace-frontier` worktree.
Its production changes remain uncommitted; main does not contain this cohort.

## Candidate and commands

The real candidate combines the reviewed compiler import closure, the loader's
`get_current_directory` migration, List `contains_with`/`contains` and `join`,
Option `map`, and Result `map`, `map_err` and `and_then`. It changes 21 production
files, with 122 additions and 27 deletions. The loader tests add 33 lines and
remove two. All 41 compiler source modules and all 12 target-library files are
present; no stub, alternate entrypoint or synthetic replacement is used.

The retained accepted Numeric compiler executes the ordinary CLI, from that
worktree:

```sh
<numeric-compiler> --library-root blorp_2/standard_library \
  blorp_2/src/main.brp <owned-output-directory>/compiler.c
```

Its diagnostic executable SHA256 is
`ef9365be6d735face891f197f7fa33d1e6a36c319431f6b341567a64414b8466`.
The changed source and target library are runtime inputs to this executable;
the probe does not establish a new compiler build or a self-compilation fixpoint.
Memory-reporting modes were unset. No timing or allocation claim is made.

## Observed results

The tests-first loader call failed with the exact missing-export diagnostic for
`working_directory_result`, exit 1 and zero callbacks. After applying the reviewed
cohort, the same loader suite passed all 36 callbacks, including all 33 original
cases, with exit 0 and empty stderr.

The subsequent single actual compiler-source invocation exited 1, with empty
stdout, 583 bytes of stderr, and no emitted C. Its first diagnostic, with the
worktree prefix omitted, was:

```text
blorp_2/src/utils/text.brp:8:11: error: two functions named equals can accept the same receiver
help: rename one of them, or change a first parameter so that no value fits both receivers, String and String
```

The notes identify `blorp_2/standard_library/string.brp:14:11` and its prelude import
at `blorp_2/standard_library/prelude.brp:7:13`. `check/check.brp` runs this receiver-clash
validation after namespace, declaration, constant and signature checking, before
function-body checking. Thus the actual input has passed the missing-import
frontier. Later missing library members, loops, lambdas and subsequent compiler
phases have not been exercised by this probe.

## Limits and follow-up

The source `utils/text.equals` bridges the host library's lack of an ordinary
String equality function. A separately reviewed follow-up can rename it to
`same_text`, preserving its body and migrating its callers. Do not relax the
receiver-clash rule or substitute a target-only implementation.

Membership retains a temporary Int-only `contains` adapter and linear recursive
stack use. Join is naturally String-specific; its balanced copying is temporary.
These and the other pending features retain their own resource and acceptance
gates. Neither this probe nor its reviews waive those gates or authorize merging
a feature with unresolved failures.

Raw commands, output and guards are retained under the ignored directory
`build/bootstrap-evidence/library-namespace-frontier-2026-10-19/preparation01/`.
Receipt SHA256 values are: RED `474469e630a4a436565d26f463a0021b7e406fe3be42582ab26a78d779c837c0`,
GREEN `ef6b2c1fad2ed228b677919bbcdc30c4a4ca577c7f0edf789b306832b1fdd4f5`,
and source probe `957e8588b270de56e48d8e59cb51bad1b122e158169695bcd8ec24c59e1e1f43`.
