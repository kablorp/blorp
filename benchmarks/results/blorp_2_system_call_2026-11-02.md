# Blorp 2 SystemCall contract, phase 1 (2026-11-02)

Phase 1 of `blorp_2/FILESYSTEM_PLAN.md`: the four system builtins
(`system.get_current_directory`, `system.read_file`, `system.write_file`,
`process.run_to_files`) move onto one `SystemCall` contract. It ports step 1 of
the phase 0 spike (`fa7be5d26`, `benchmarks/results/blorp_2_filesystem_spike_2026-11-02.md`)
onto `acc2af52a`; it applied without conflict, so the Dict migration changed no
step-1 site.

## Provenance

| | Base | Candidate |
| --- | --- | --- |
| Commit | `acc2af52a` | `acc2af52a` plus the `blorp2/system-call` commit |
| B (sha256) | `3a3d6498f0b6fdeca7ab71fb470a83f7753a21f37fe8ae035dda0fd404a88b8b` | `09c38f6a1853a93fdb9ab59087e3accff1c6eb1dccb288da37caf9635a0ed03c` |
| Self C (sha256) | `4d083e4ad751562578a5ce26bb227c65260bcffb69ee0cb544796caa905a8095` | `26c00853f9074c826e1e63b0a4b0c3a625156de4a98897e588f9e0797a743a45` |
| Self C bytes | 25,238,325 | 25,224,332 |

Both build from the pinned seed. The base ran from a copy of `acc2af52a`:

```bash
mkdir -p build/system_call/base_tree
git archive -o build/system_call/base.tar origin/main blorp_2 scripts Makefile AGENTS.md docs benchmarks/blorp_2
tar -x -f build/system_call/base.tar -C build/system_call/base_tree
```

Machine: Apple M4, macOS 26.7.1, Apple clang 21.0.0, load average 3 to 5 from
other sessions (one gate run at load 8 to 11 hit its own process timeouts and
was discarded; see Gates). Every run was serial. Raw samples are under the
ignored `build/system_call/` of the candidate worktree. Paths below are
relative to it, with `W` the worktree root.

## Ceilings

| Metric | Ceiling | Measured |
| --- | --- | --- |
| Compiler logic, `src/` without `src/runtime/`, net | +45 lines | +39 (+202 -163) |
| `src/runtime/`, net | +40 lines | +34 (+55 -21) |
| Self-compile allocations | +0.5% | 15,066,826 to 15,051,694 (-0.10%) |
| Self-compile instructions, -O2 | +0.5% | 14,851,580,376 to 14,849,081,663 (-0.02%) |
| Self-compile instructions, -O0 | +0.5% | 42,966,475,857 to 43,068,152,648 (+0.24%) |
| Fixed-input instructions, -O2 | +0.1% | 14,871,164,946 to 14,877,432,790 (+0.042%) |
| Self C | the three listed changes | met, below |

Instructions are the minimum of five interleaved runs. Tests and fixtures: net
+51 lines. Run-to-run spread under this load was 0.2% at -O2 and 0.3% at -O0
(the base itself ranged 42.93G to 43.04G at -O0 across sessions). Before the
review fixes the same measurements gave -0.03% at -O2 (attribution `timing`
stage), +0.14% at -O0 and +0.013% fixed-input, so the fixes did not change the
picture beyond that noise.

### Commands

```bash
# Allocations and the self C of each tree (base from build/system_call/base_tree).
cd build/system_call/base_tree && blorp_2/scripts/attribution/run --output ../base \
  --stage build --stage allocations --stage timing
cd W && blorp_2/scripts/attribution/run --output build/system_call/candidate2 \
  --stage build --stage allocations --stage timing

# -O0 compilers: the self C linked at -O0, no memory diagnostics.
clang -w -O0 -DBLORP_MEMORY_DIAGNOSTICS=0 build/system_call/base/self.c -o build/system_call/o0/base -lm -lpthread
clang -w -O0 -DBLORP_MEMORY_DIAGNOSTICS=0 build/system_call/candidate2/self.c -o build/system_call/o0/candidate2 -lm -lpthread
```

Every timed run is `/usr/bin/time -l <compiler> --library-root <library> <main.brp> <out.c>`
and the figure is its `instructions retired` line. Five iterations, base then
candidate in each, never overlapping:

| Measurement | Base command | Candidate command | Output check |
| --- | --- | --- | --- |
| -O2 self-compile | `base/timing/atomic` on `base_tree/blorp_2/src/main.brp` | `candidate2/timing/atomic` on `W/blorp_2/src/main.brp` | each `cmp`ed to its own `self.c` |
| -O0 self-compile | `o0/base`, same input | `o0/candidate2`, same input | same |
| Fixed input | `base/timing/atomic` on `base_tree/blorp_2/src/main.brp` with `base_tree/blorp_2/standard_library` | `candidate2/timing/atomic` on the same two paths | baseline output `cmp`ed to `base/self.c` |

Raw runs: `build/system_call/measure_o2/runs.tsv`, `measure_o0/runs.tsv`,
`measure_fixed/runs.tsv`, with the `time_*` files beside them.

## Self C

The candidate -O2 compiler compiled the base `src` and library
(`measure_fixed/candidate.c`, sha256
`057c58328fd02ca89f7f55b6411a8e5035612bf0562d210aebb24b21074754c5`, identical
before and after the review fixes). Against the base self C
(`diff measure_fixed/baseline.c measure_fixed/candidate.c`, 6 hunks, all among
the three listed changes):

1. Lines 469-612 of the base: the failure-helper, current-directory and
   read-file fragments leave their old place.
2. Lines 4968-5110 of the candidate: the same text returns after the
   aggregates, in first-call order. With the out-parameter renames removed,
   the moved lines are the same multiset as the removed ones (checked by
   sorting both blocks and diffing; the only residue was my own normalizing).
3. `blorp_get_current_directory` and `blorp_read_file` take separate success
   and error out-parameters.
4. Three call sites (base lines 5132, 5167, 5496): locals
   `blorp_runtime_N_value` and `blorp_runtime_N_error`; `write_file` has only
   `_error`, since its success payload is Void.

The base compiler on the base `src` reproduces the base self C exactly. The
candidate's own self C (`candidate2/self.c`) additionally differs from the
first candidate tree's (`candidate/self.c`) only by the emission of the edited
`parse.brp` and `syntax.brp` code, mainly renumbered record types.

## Declaration help

For each of the four labels, a mismatched declaration gives the same
diagnostic text under the base and candidate compilers:

```bash
cd build/system_call/help   # for each label L: query() -> Int: builtin("L")
../base/timing/atomic       --library-root ../base_tree/blorp_2/standard_library L.brp L.base.c > L.base.txt 2>&1
../candidate2/timing/atomic --library-root ../base_tree/blorp_2/standard_library L.brp L.cand.c > L.cand.txt 2>&1
cmp L.base.txt L.cand.txt   # silent for all four
```

The label help for an unknown builtin now lists the system labels first; three
tests pin it.

## Gates

- `make -C blorp_2 test`: exit 0, 949 PASS lines, 0 FAIL, against the base's
  948 (the one new suite, `test_parse/test_system_labels.brp`).
  An earlier run of the same tree at load 8 to 11 exited 2 with two process
  timeouts (`exec handshake timeout reaps the acknowledged child`, `ordinary
  List remove import reaches real main`, both `process.run_to_files: timed
  out`); neither is related to this change, and the rerun at load 4 passed.
- `scripts/blorp2-fixpoint --prove`: exit 0, `fixtures_identical_under_a_and_b=663`.
- The new suite fails when `WriteFile`'s label is changed to
  `"system.read_file"` (checked after the final edit, then restored).
- `grep -rn '"system\.\|"process\.' blorp_2/src`: only the four arms of
  `system_operation_label`, plus the `process.run_to_files:` prefix inside the
  C error text of `runtime/process.brp`, which is message text and not a label.

## Edited tests the gate does not select

**Native C fixtures** (`test/runtime/fixtures/current_directory_test.c` and
`file_read_test.c`). Their suites (`test/runtime/test_*.brp`) cannot compile
(they import the legacy `fs`, `process` and `system` modules), so I built the
fixtures directly against the candidate's emitted runtime, as the suites would:

```bash
cd build/system_call/native
# read.brp and cwd.brp are the FILE_READ_SOURCE / CURRENT_DIRECTORY_SOURCE programs.
../candidate/timing/atomic --library-root W/blorp_2/standard_library read.brp read_full.c
../candidate/timing/atomic --library-root W/blorp_2/standard_library cwd.brp cwd_full.c
head -480 read_full.c > file_read_runtime.c            # everything before the forward declarations
head -461 cwd_full.c  > current_directory_runtime.c
cp W/blorp_2/test/runtime/fixtures/{file_read_test.c,current_directory_test.c} .
clang -std=c11 -O0 -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined \
  -fno-sanitize-recover=all file_read_test.c -lm -o file_read_test               # exit 0
clang ... current_directory_test.c -lm -o current_directory_test                 # exit 0
./file_read_test <case>  # 19 cases; exit 0 with empty stdout and stderr, as the suite requires
./current_directory_test <case>  # 13 cases, same rule
```

All 32 cases pass (19 file-read, 13 current-directory). This built the
fragments from the first candidate tree; the review fixes touch only parse and
a comment, which cannot change these fragments.

**Blorp 2 suites.** Each was run alone, serially, with
`make -C blorp_2 test-target-components TARGET_COMPONENT_SOURCES=<suite>` in
both the candidate and the base tree. Result: all 28 fail at their own parse
or syntax rot in both trees, with the same first error at the same construct
(candidate line numbers are 1 to 2 higher where this change added an import
line). None reaches the code this change edited, so none passes and none fails
because of this change.

| Suite (under `blorp_2/test/`) | First error, both trees |
| --- | --- |
| `e2e/test_current_directory.brp`, `e2e/test_file_read.brp`, `e2e/test_file_write.brp` | `?=` cannot be used inside a lambda body |
| `runtime/test_current_directory.brp`, `runtime/test_file_read.brp`, `runtime/test_write_file.brp` | expected `:` after if condition |
| `unit/test_check/test_current_directory.brp`, `test_file_read.brp`, `test_write_file.brp` | expected `)` after the grouped expression (`and` as an operator) |
| `unit/test_emit/test_builtin_functions.brp`, `test_current_directory.brp`, `test_file_read.brp`, `test_write_file.brp` | the same |
| `unit/test_lower/test_result_contracts.brp` | the same |
| `unit/test_lower/test_file_read.brp`, `test_write_file.brp` | expected a match pattern |
| `unit/test_own/test_current_directory.brp`, `test_file_read.brp`, `test_write_file.brp` | expected a newline after the return expression, or the grouped expression |
| `unit/test_specialize/test_current_directory.brp`, `test_file_read.brp`, `test_write_file.brp` | expected a newline after the return expression |
| `unit/test_verify/test_file_read.brp`, `test_result_ownership.brp`, `test_write_file.brp` | expected `)` after the grouped expression |
| `unit/test_runtime/test_system.brp` | expected `)` after the grouped expression |
| `unit/test_parse/test_string_literals_syntax.brp` | `+=` is not supported yet |
| `test_grammar/test_conformance.brp` | expected `)` after the grouped expression |

The gated suites this change touches pass: `test_parse/test_file_read`,
`test_write_file`, `test_float_builtin_labels`, `test_system_labels`,
`test_emit/test_run_to_files`, `test_lower/test_run_to_files`,
`test_specialize/test_run_to_files`, `test_check/test_run_to_files`.

## Found, not done

- The primitive labels are still spelled twice (`primitive_operation` and
  `PRIMITIVE_LABELS`).
- 28 suites that mention the system operations cannot compile; the table above
  lists them. Their edits in this commit were made mechanically and are
  unchecked. They need porting before the phase 2a operations rely on them.
- `emit.brp` `payload_use`/`PayloadUse` could be written as two optional local
  declarations plus the address and value strings; that form needs four
  matches over the payloads and is not shorter, so it stays.
- The e2e process tests (`process.run_to_files: timed out`) fail when the
  machine load is above about 8. A failed gate run leaves an orphaned
  `process_child reap-startup` process that has to be killed by hand.
