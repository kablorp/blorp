# Discovery M4: direct expression and body minting (2026-10-07)

This slice replaces the existing expression/body recipe group with direct
syntax construction. It deletes generic recipes, mint walkers and accepted
token-index replay, while preserving the grammar currently covered by M4.
The assignment boundary uses a typed statement-head completion context so a
terminal subscript becomes a place without first minting an expression that
would be discarded. Types, patterns and local heads are read where their IDs
belong. Unsupported forms return their saved entry state; rejected expression
trials discard their mint and keep span/spelling diagnostics.

The owning design and remaining milestone criteria are in
[`DISCOVERY_REDESIGN.md`](../../docs/DISCOVERY_REDESIGN.md), sections 3.16 and 8.
This is a structural migration and a bounded allocation comparison, not a
speed claim or evidence for the M6 default-switch ceiling.

## Correctness evidence

The baseline is clean commit `c2709e2268325fcb677084c623d3f98289b2a124`.
Repository `bin/blorp` was `FRESH`; tree sources compile into the test programs
and are outside this executable's production inputs. Baseline expression,
body and syntax-nesting suites pass 160 checks. The existing full census was
reused only after all 3,604 corpus paths and their content hashes matched
exactly. Its original embedded base label is retained; the separate provenance
record binds that unchanged input corpus to `c2709e2`.

The frozen candidate passes the following serial gates:

| Gate | Passed | Failed |
| --- | ---: | ---: |
| Independent focused and importing suites | 423 | 0 |
| `compiler-blorp` | 6,828 | 0 |
| `compiler-new` | 1,023 | 0 |
| `compiler-new-parity` | 3,619 | 0 |

The production gate includes 5,974 TestSuite checks and 854 fixtures. Full
parity assembles and compares 2,976 of 3,460 accepted corpus modules, with zero
mismatched files. The remaining 484 accepted modules still stop at unread
grammar: 439 function bodies, 26 global initializers and 19 implementations.
The one fewer corpus input is the intentional deletion of `parse/recipes.brp`.
The parity gate retains its existing rejected-module allowances; this result
does not complete the rejected-module subset criterion.

Focused regressions pin grouped and ungrouped assignment roots, exact nested
subscript-place IDs, grouped thread counts without expression IDs, rejected
local-definition trial rollback, nesting limits and grouped block-lambda
classification. Their AST/span/ID assertions and the full differential are
independent of the allocation probe below.

The deletion-aware census compares 3,595 unchanged surviving inputs, eight
edited survivors and one deleted input, with no additions. All 484
module/owner/reason mappings match exactly, including the edited inputs. All
unchanged stop locations match; the five source-line shifts belong to edited
files. No corpus input changed during the gates. The matching semantic-map
SHA256 is
`25fab1422c05e41085fdd3460f476857fc7c232e7f474f1c27db4a94cdfaffdd`.
The durable [comparison](discovery_direct_mint_cost_2026-10-07/census-comparison.json)
lists the edited paths and line shifts; the
[baseline provenance](discovery_direct_mint_cost_2026-10-07/census-baseline-provenance.json)
records the exact-input census reuse.

The [gate commands](discovery_direct_mint_cost_2026-10-07/gate-commands.json)
retain the focused, broad and census invocations.

Raw validation artifacts are retained in
`/tmp/blorp-m4-direct-mint-baseline/` and
`/tmp/blorp-m4-direct-mint-gates/`. The latter contains the final gate logs.

## Compiler emission observation

The first candidate build failed with
`internal C emission failure: missing projected callable Recognized (683)`.
A bounded expected-type probe succeeded when two `Recognized(None)` results
were explicitly bound as `Recognition[Option[ErrorMap]]`. Those ordinary type
annotations are retained. This establishes an expected-type-sensitive build
rough edge; it does not establish or fix the underlying compiler cause.

The failed source patch and command/log are retained under
`/tmp/blorp-m4-direct-mint-emission-rough-edge/`; patch SHA256 is
`fcde12708efcd6ba0e83f697746baf3f3b348158897a9ef47d21efc9132e6a14`.
The green narrowed probe log is
`/tmp/blorp-m4-direct-mint-with-option-type-probe.log` (39 checks passed).

## Allocation boundary and oracle

The probe measures `assemble_module(lexed)` on one six-function syntax
fixture. It includes parser-state setup and module assembly. Text creation,
lexing, dumping and ID census run outside the scalar counter interval. The
fixture covers loops and conditionals, typed binders and match patterns,
subscript assignment, lambdas and nested local functions, interpolation,
leading-dot continuations and
`concurrent(max_threads: ((2)), timeout: 3)`. Semantic typechecking of that
fixture is outside this parser boundary.

The assembly result remains live at the final counter reads. Both
`MemoryStatsActive` and `OracleStatsActive` must equal one at each endpoint.
The probe uses counters-only diagnostics, without `reset_mem_stats` or leak
metadata. Managed allocations, managed releases, the live-object delta and
backing malloc events are measured. Retained bytes and retired instructions
are not measured.

Each retained executable is built once with the same repository compiler and
toolchain, using `--release --memory-stats` and its snapshot's identical
standard library. Three alternating baseline/candidate pairs run serially in
fresh processes with `BLORP_MEMORY_STATS=1`, `BLORP_THREADS=1` and
`BLORP_LEAK_CHECK` unset. Each process has a 180-second timeout. Acceptance
requires all six functions to assemble, zero census problems, byte-identical
syntax dumps (including spans and IDs), matching family and spelling counts,
and repeatable counters within each source. There is no preset allocation
ceiling for this structural slice.

## Matched allocation result

All three independent processes for each retained binary produce exactly the
same counters. All six runs produce matching family/spelling counts, zero
census problems and the same syntax oracle SHA256:
`12cc4fc3b02bd8c9a93360ffd32400b153bd26d32810a4fc939e00b332c6bf78`.

| Counter, assembly interval | Baseline | Candidate | Candidate minus baseline |
| --- | ---: | ---: | ---: |
| Managed allocations | 4,381 | 3,602 | -779 |
| Managed releases | 3,856 | 3,074 | -782 |
| Backing malloc events | 4,381 | 3,602 | -779 |
| Live managed objects, endpoint delta | 525 | 528 | +3 |

The measured fixture allocates 17.8% fewer managed objects during assembly.
Three more objects are live at the retained-result endpoint; that difference
is not attributed here. These allocation results do not establish lower
retained memory, leak freedom, faster execution or full-corpus cost. Retired-instruction
verification and the M6 ceiling remain separate work.

The identical output has six items, eight definitions, 27 spellings, 28
statements, 13 blocks, 59 expressions, seven patterns, 19 written types, 56
name uses and 13 binders. Dimensions and type binders are zero. Imports are
zero. The
[sample ledger](discovery_direct_mint_cost_2026-10-07/samples.json) records each
launch's counters, executable hash, stdout hash and oracle hash. Complete
stdout/stderr logs for all six processes are retained beside it. The exact
[probe source](discovery_direct_mint_cost_2026-10-07/allocation_probe.brp.txt),
[fixture](discovery_direct_mint_cost_2026-10-07/measured-fixture.txt) and
[sample collector](discovery_direct_mint_cost_2026-10-07/collect_samples.py.txt)
are retained as data, outside the compiler corpus.

A separate leak-enabled teardown pair reuses the same native executables,
with no rebuild. Both exit zero: baseline reports 8,369 allocations and
8,369 releases; candidate reports 7,590 allocations and 7,590 releases. Both
report zero leaked objects and bytes. These whole-process counters include
setup and oracle work and are separate from the assembly interval. The
[teardown record](discovery_direct_mint_cost_2026-10-07/teardown.json) and raw
stdout/stderr logs retain this bounded result. It does not explain the three
extra live objects at the earlier endpoint or validate broader workloads.

## Deleted input and build provenance

`recipes.brp` was absent from the baseline's 484 stop records, but that fact
alone did not establish whether it assembled. A separate data probe reads
its exact archived bytes without importing it or restoring it in the
checkout. Both parsers assemble 40 items with zero census problems and an
identical dump, including spans and IDs. Dump/output SHA256 is
`859cff17f5ed9a20b1846458b73831abdf0c53b39b7109b10fc14a7a9b7aaccd`.
The [deleted-input comparison](discovery_direct_mint_cost_2026-10-07/deleted-recipe-comparison.json),
[probe](discovery_direct_mint_cost_2026-10-07/deleted_recipe_probe.brp.txt) and
raw logs retain the input and binary hashes. This establishes syntax
preservation for the deleted input; it does not compare its import resolution.

The baseline source snapshot comes from `git archive c2709e2`; tracked
build-info remains from that archive. The ignored generated embedded standard
library is overlaid identically in both snapshots after verifying the standard
library sources match. The candidate snapshot overlays the frozen tracked
edits and removes the recipe module. The two probes use identical logical
source paths in their snapshots. The
[archive provenance](discovery_direct_mint_cost_2026-10-07/archive-provenance.json)
records archive and generated-input hashes. The
[final provenance](discovery_direct_mint_cost_2026-10-07/final-provenance.json)
records all nine changed/deleted compiler-corpus paths, compiler/toolchain
identity and the shared diagnostic runtime cache's manifest/object/header
hashes. The compiler SHA256 is
`e7967dadb21329dce55ef8b99a7d7baa5528323f71c040b965cd9eacc70ee049`.

The native probes use Apple clang 21.0.0 on arm64 Darwin 25.6.0, release
program compilation and the same diagnostic runtime at `-O2`. Exactly one
runtime-cache entry serves the builds. Its
[manifest](discovery_direct_mint_cost_2026-10-07/runtime-cache-MANIFEST.txt)
is retained. The CLI itself reports its earlier production commit
`5fed50a38bf0`, with CLI `-O0`/runtime `-O2`, and remains `FRESH` before and
after: this slice changes test-only tree-parser inputs rather than the
installed production compiler.

The structured [commands](discovery_direct_mint_cost_2026-10-07/commands.json)
retain exact argv, working directories and environment overrides for both
builds, sample launches, the deleted-input probe and the separate teardown
pair. To reproduce, prepare the two source snapshots and the identical
generated support, copy the retained `.brp.txt` probes to the recorded logical
`.brp` paths, and run those commands with the recorded compiler. Place the
collector in the artifact directory beside the retained executables. Raw
build logs and binaries remain under `/tmp/blorp-m4-direct-mint-allocation/`.

Repository hygiene, artifact scanning and whitespace checks pass. Review of
the source reports zero findings. M4 remains open for grammar coverage,
rejected-header recovery, rejected-module subset parity and final outcome
unification; M6 performance verification has not run.
