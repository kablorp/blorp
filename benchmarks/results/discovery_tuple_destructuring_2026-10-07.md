# Discovery M4: flat tuple destructuring (2026-10-07)

The tree body parser now reads `(a, _, c) = value` using the existing language
grammar: two to four flat names or discards, with an optional trailing comma
and bracket-joined target lines. Named targets finish as binders in written
order before the RHS and statement. Discards carry spans without binder IDs;
no target expression or name-use IDs are issued. The legacy projection
preserves the frozen AST and source spans.

A private `TupleBinding` result shares the existing target parser between
loops and destructuring without representing an impossible single loop binder
at the assignment boundary. A token-kind predicate selects flat comma-bearing
heads immediately followed by `=`; arity belongs to the target parser.
Reserved keyword tokens select that path, while keyword-token soft words keep
the frozen expression route. Grouped, nested, typed and non-name targets
remain unsupported. Unsupported or malformed values restore the saved whole
body entry, including prior statements and target IDs.

This is coverage of existing grammar, without new syntax, diagnostics,
recovery behavior, recipes or token replay. The owning design and remaining
M4 criteria are in [`DISCOVERY_REDESIGN.md`](../../docs/DISCOVERY_REDESIGN.md),
sections 3.16 and 8. General rejected-body conversion remains open.

## Correctness evidence

The baseline is clean commit `a5f366653d4becf09244a30ce12a1d8eff711f9a`.
Repository `bin/blorp` is `FRESH`. Its build inputs are unchanged by this
slice; the tree parser and projection are compiled into the test programs.
The prior census was reused only after all 3,603 tracked corpus paths and byte
hashes matched exactly. Its embedded older base label is preserved; the
[baseline provenance](discovery_tuple_destructuring_2026-10-07/census-baseline-provenance.json)
binds those identical inputs to this baseline.

The new body regression initially failed with 47/48 checks passing, and the
projection regression failed with 43/44 passing. The frozen candidate passes
these serial independent gates:

| Gate | Passed | Failed |
| --- | ---: | ---: |
| Focused and importing suites | 427 | 0 |
| `compiler-new` | 1,026 | 0 |
| `compiler-new-parity` | 3,619 | 0 |

Focused coverage pins valid target widths/discards/trailing commas, exact
post-order IDs, multiline targets, opening-parenthesis RHS anchors, following
statements/declarations, lambda/local-function/trait/implementation contexts,
reserved and soft keyword routes, unsupported targets and whole-entry rollback.
The stale stop fixture now uses non-name targets to retain its negative
`TupleDestructuring` assertion; flat name targets have positive coverage.

Full parity compares 3,114 of 3,460 accepted modules with zero mismatched files,
up from 2,976. The 346 remaining unread modules have 301 function-body stops,
26 global-initializer stops and 19 implementation stops. The completed prefix
contains 40,074 declarations, including 30,207 functions, versus 36,208 and
26,666 at baseline. These counts retain the parity gate's existing rejected
module allowances and do not close the rejected-module subset criterion.

The [matched census](discovery_tuple_destructuring_2026-10-07/census-comparison.json)
retains 3,603 paths: 3,598 unchanged inputs and five edited inputs, with no
additions or deletions. Every one of the 148 former tuple-first stops advances:
138 modules fully assemble; ten reach later unread grammar (five soft keyword
names, two opaque conversions, two operators after blocks and one value on the
next line). The ten later stops move forward in their unchanged inputs. No unrelated
stop mapping or location moves, and no input changes during validation. The remaining 336 baseline non-tuple stops
retain their mappings. The candidate semantic-map SHA256 is
`053b35157855ff32d8628ce2ec8607a2786cc27350e8c58566508c404f3fdd31`.

## Allocation boundary

The shared target parser's precise result introduces a transient
`TupleBinding` on existing tuple loops. A matched fixture measures that cost
rather than changing the data model to avoid an unmeasured compiler expense.
The fixed 341-byte input contains one function with ten existing
`for (a, _, c)` loops; it contains no new destructuring assignments, which the
baseline cannot read.

Scalar counters bracket only `assemble_module(lexed)`. Text creation, lexing,
dumps and ID census are outside the interval. The result remains live at final
reads. Both memory/oracle active flags must equal one at each endpoint.
Retained native executables use the same final repository compiler, identical
standard-library/generated support, release flags and shared diagnostic
runtime. Three alternating process pairs run serially with
`BLORP_MEMORY_STATS=1`, `BLORP_THREADS=1`, `BLORP_LEAK_CHECK` unset and a
180-second per-process timeout. Acceptance requires an assembled item, zero
census errors, byte-identical trees/spans/IDs/spellings/counts and repeatable
per-source counters. There is no allocation ceiling or speed claim for this
coverage slice; retired instructions and retained bytes are not measured.

## Matched allocation result

All three processes per retained executable produce identical per-source
counters, and all six produce the same syntax oracle SHA256:
`db5025c1f275885e5e6ae120c540e4f71232c1b5297ec5a045e72213b593f722`.

| Counter, assembly interval | Baseline | Candidate | Candidate minus baseline |
| --- | ---: | ---: | ---: |
| Managed allocations | 2,041 | 2,071 | +30 |
| Managed releases | 1,726 | 1,756 | +30 |
| Backing malloc events | 2,041 | 2,071 | +30 |
| Live managed objects, endpoint delta | 315 | 315 | 0 |

This ten-loop fixture adds three allocation/release events per written loop.
It records the current cost of the precise shared result boundary; it does
not establish execution time, retained bytes, leak freedom or full-corpus
cost. No separate teardown pair was run because the live-object endpoint
delta is unchanged. General performance verification remains M6 work.

The identical output contains one item and definition, four spellings,
21 statements, 11 blocks, 41 expressions, 30 name uses and 21 binders;
imports, patterns, written types, dimensions and type binders are zero.
The [sample ledger](discovery_tuple_destructuring_2026-10-07/samples.json)
records counters, executable/output/oracle hashes and repeatability. Raw
stdout/stderr for all six processes, the exact
[probe source](discovery_tuple_destructuring_2026-10-07/allocation_probe.brp.txt),
[fixture](discovery_tuple_destructuring_2026-10-07/measured-fixture.txt) and
[collector](discovery_tuple_destructuring_2026-10-07/collect_samples.py.txt)
are retained as data outside the compiler corpus.

## Provenance and reproduction

The baseline source is `git archive a5f3666`; tracked build-info comes from
that archive. Identical ignored generated embedded-standard-library support
is overlaid only after verifying standard-library source identity. The
candidate snapshot overlays the five frozen source/test changes. Logical
probe paths match in both snapshots. The
[archive provenance](discovery_tuple_destructuring_2026-10-07/archive-provenance.json)
and [final provenance](discovery_tuple_destructuring_2026-10-07/final-provenance.json)
retain source, fixture, probe, compiler, toolchain and runtime hashes.

Both executables use Apple clang 21.0.0 on arm64 Darwin 25.6.0 and the same
single diagnostic runtime cache entry at `-O2`. The repository compiler
SHA256 is `e7967dadb21329dce55ef8b99a7d7baa5528323f71c040b965cd9eacc70ee049`;
it remains `FRESH` before and after all validation. Its earlier embedded
production commit label is preserved and distinguished from parser source
provenance. The [runtime manifest](discovery_tuple_destructuring_2026-10-07/runtime-cache-MANIFEST.txt)
is retained beside the source hashes.

The exact [commands](discovery_tuple_destructuring_2026-10-07/commands.json)
record each build, collector invocation and direct sample launch separately,
with executable argv, working directory, environment overrides and
unsets, timeouts, output paths and exit status. To reproduce, prepare the two
snapshots and identical generated support, copy the retained `.brp.txt` probe
to the recorded `.brp` path, and run those commands with the recorded compiler.
Binaries, archives and build logs remain in
`/tmp/blorp-m4-tuple-loop-allocation/`.

The [gate results](discovery_tuple_destructuring_2026-10-07/gate-results.json)
and [gate commands](discovery_tuple_destructuring_2026-10-07/gate-commands.json)
record the independent focused/importing, broad and census checks. Raw gate
logs remain in `/tmp/blorp-m4-tuple-gates/`; initial failing regressions are
`/tmp/blorp-m4-tuple-red-body.log` and
`/tmp/blorp-m4-tuple-red-projection.log`. No corpus source changes during gates
or measurement. Repository hygiene, artifact scanning and whitespace checks
pass. Source review reports zero findings. M4 remains open for other grammar,
rejected-header recovery/layout ownership, rejected-module subset parity and
final outcome unification.
