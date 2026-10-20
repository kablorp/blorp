# Propagate the loader's current-directory failure

Status: implemented and validated. Focused regressions, three effective
fault/restored pairs, the 48-call acceptance campaign and fixed-B SOURCE costs pass.
See the [acceptance report](../benchmarks/results/blorp_2_current_directory_2026-10-20.md).
No host/system primitive or target library API changed.

The remainder is the historical frozen plan; its planning identities and
unapplied-preview wording describe the pre-implementation proposal.

## Source identity, ownership and scope

Planning main is `f627d5aaf64775bb23e4f2e15a955450c0cb336b`. Its compiler source
and target library still match accepted Numeric `a656f5ce1`; this is a source
identity statement, not selection of a SOURCE measurement baseline or producer.
The retained [source preview](../build/bootstrap-evidence/compiler-source-api-migrations-2026-10-19/preview-01/cwd/SOURCE.preview.patch)
and [tests](../build/bootstrap-evidence/compiler-source-api-migrations-2026-10-19/preview-01/cwd/TESTS.preview.patch)
are unapplied. Root reassigned this one getcwd migration from the broader
[loader plan](LOADER_SHELL_INTEGRATION_PLAN.md). Main's IO visibility and existing
Option/Result operation imports remain owned by the import-closure worker.
Preserve that worker's edits during composition; do not replace its import blocks.
Option/Result types and constructors already come from the target prelude for
compiler user modules. No additional constructor import is required by this slice.

Only src/load/load.brp and its existing test_load owner change. Existing host and
target system modules already expose get_current_directory() -> Result[String, String].
The [host API contract](ROADMAP.md#seven-shell-and-path-functions) is a dependency already
provided; the held host31 String.slice wrapper is unrelated to this CWD edit.
Ambient Path/library and source-language prerequisites still govern self-compilation.

## Behavior and concrete source shape

Replace the one system import/call to getcwd() -> String, whose empty failure
sentinel currently enters path construction. The existing entrypoint begins:

```blorp
working_directory ?= working_directory_result(get_current_directory())
```

The pure working_directory_result projection preserves Ok's exact directory bytes.
Err produces LoadFailure with empty SourceInputs.modules, compiler_source(), span
0..0 and note=None. Message is `could not determine current directory: ` plus the
complete error; help is `run the compiler from an accessible working directory`.
The shell queries once before path construction, module identities and file reads.
No fake SourceFile, revalidation/normalization, PWD fallback, retry, chdir or new
filesystem provider is added. All remaining loading/publication behavior stays
unchanged. The small pure projection exposes error context to an ordinary unit
suite without injecting or replacing IO.

## Tests and proof

Characterize accepted B first, then install exact tests before code. Three named
cases cover Ok('/tmp/é space') bytes, the complete Err contract above, and rendering:
`blorp_2: error: could not determine current directory: permission denied` followed
by LF and `help: run the compiler from an accessible working directory`.
The Err input is explicit test data, not claimed execution of an OS failure.
Use existing load/product-lifetime and main diagnostic suites, then current
unit/runtime/grammar/full native gates. Accepted native CWD error/ownership tests
retain the OS leaf proof; add no second filesystem-testing mechanism.
Use the existing CLI/process harness in two explicit CWDs, including a space/UTF-8
directory, with relative library/input/output names. Check actual output location,
exact generated C/status/streams and existing rejection/output-preservation cases.
Prove source-valid mutants changing error origin, adding a fake source row, or
returning empty success on Err. Require the named exact failure, restore bytes,
and rerun affected GREEN. Runtime/host setup failure is not an oracle kill.
After prerequisites compose, compile actual source main with its complete library;
retain a later frontier's exact first diagnostic/phase without claiming self-compilation.

## Bounds and retained SOURCE/HOST costs

Hard proposed ceilings: production 20 gross/+20 net; tests 120 gross/+120 net;
no new fixtures/public API docs; implementation notes at most 10 lines. The reviewed
preview is production +14/-2 (net+12), tests +33/-2 (net+31). Count readable physical
lines; no compressed formatting, deleted coverage or stacked feature allowance.
The [SOURCE policy](BOOTSTRAP_SOURCE_PLAN.md#source-cost-acceptance) binds both
metrics independently at +3% for EACH unchanged owned input AND the supporting-host
source-to-C proxy, preserving old absolutes, strict zero, identity and LOC limits.
Root names/fixes accepted B, complete C, full library/corpus, paths and matched
host/STD/tool/metric roles before setup. Never roll B after failure. HOST allocations
remain the unique positive schema1 artifact_construction_complete.total_allocations
checkpoint, not exit TOTAL. Normal costs use all three alternating samples/min3.
A necessary host/STD transition is a separate explicitly matched epoch for B/C.
Historical R0 failures/trends keep their verdicts; the dated fixed-B policy is no
new waiver or permission to rerun old Slice 491, HOST or successful samples.
Root plus independent code/test review precede implementation commit. Stop on any
missing dependency, scope/LOC, semantic/ownership/identity, counter or cost failure.
No compiler-source migration or supporting-host installation follows from this plan.
