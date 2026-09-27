# Identity hot-path call profiling checkpoint

## Accepted candidate: direct function selectors

The first C0b marker module is rejected because it changed the compiler's
source graph and the normal compiler C differed beyond definition-ID
renaming, even though marker calls themselves erased and compiled programs
remained byte-identical. Its apparent 25,004-allocation discovery regression
was measured from different worktree directories and is confounded by path
construction; the parent reproduces the higher count when run from the
candidate directory. Those cross-directory records are retained only as
rejected measurement evidence at
`/tmp/blorp-id-d0-measure.LoXsWT/{parent,candidate}.json` and adjacent C.

The revised candidate makes **no production source changes**. A benchmark-only
worker profiles the existing functions directly, with exactly these three
`--profile-function` selectors in `--profile-mode calls`:

| Selector | Meaning |
| --- | --- |
| `stage_09_core/ir::core_var_equal` | CoreVar equality calls |
| `stage_06_typecheck/type_system/env::scope_lookup` | Central local-scope lookup calls |
| `stage_08_core_lower/lower::core_var_impl` | Calls to the one observed CoreVar constructor helper |

The full selector spelling is pinned in the focused test. The parser requires
exactly three selected and observed functions, the exact three result rows,
call-total agreement, and zero profiler loss/corruption diagnostics. An
unsupported display lookup is reported as metadata with `profiled_calls=0`,
not as a synthetic profiler row or a claim about runtime demand. There is no
registration function, runtime global counter, atomics, or production
instrumentation.

The frozen production replay input is parent revision
`bbea8789383f51f471358569acb4c0ae1091b2c8`, tree
`f1d74095c39d9a47abf10774029e2248168a5427`, with
`blorp/src/main.brp` blob `e4edf283c6bb7f761c4e42d07885e57f63561f72`.
The revised `-O2` compiler SHA-256 is
`a376b4d921948ec2fe55b274bee63719e5ea591049a9f33457068453292159ff`;
the disposable worker SHA-256 is
`95dafc3c4c6dce952a5e9fb60687436e3f2ce6fc353bf400414dfa27cc12b4c8`.
The benchmark worker self-compiles the frozen main through
`--stop-after=specialize` with an explicit Core dump file, selecting only the
three functions above. The two runs were serialized:

| Existing function | Calls, run 1 | Calls, run 2 |
| --- | ---: | ---: |
| `core_var_equal` | 111,577 | 111,577 |
| `scope_lookup` | 4,731,560 | 4,731,560 |
| `core_var_impl` | 358,423 | 358,423 |

Both runs exited with status 0. Diagnostics report `profile_mode=calls`,
`functions_selected=functions_observed=3`, `calls_observed=5,201,560`,
`calls_completed=0`, and zero loss/corruption and abandoned-frame fields.
Both ~389 MiB Core outputs have SHA-256
`24dea825ed4482742dcf50f90570c5b86aab00ff44eb2c3ae5ba325b5d7e365d`.
The checked extraction is `/tmp/blorp-id-c0b-direct-o2-counts.json`; raw
profiles/stderr and Core outputs are
`/tmp/blorp-id-c0b-direct-o2-{1,2}.log/.core`. Build evidence is
`/tmp/blorp-id-c0b-direct-o2-build.log`; the worker is at
`/tmp/blorp-id-c0b-direct-o2-worker/compiler_identity_work_replay`.
Elapsed time was 43.86/39.43 seconds and peak RSS was
8,398,766,080/8,399,011,840 bytes. This is a reproducible observability
checkpoint, not a low-resource routine benchmark.

Normal disabled-build evidence against the pre-C0b `bbea8789` compiler:
the generated compiler C is byte-identical (SHA-256
`24a5a7c15933a6d9ea3fd7587d6c8d5845107b4dc0e4752b86ef3c7acf0176d3`).
The compared files are
`/tmp/blorp-id-c0b-parent.tXYzFE/blorp/blorp/build/_build/blorp-cli/blorp_cli_main.c`
and `blorp/build/_build/blorp-cli/blorp_cli_main.c` in this worktree.
The normal toy fixture generated C is also byte-identical (SHA-256
`c329e7088086850dd6296265676c41cc2ae38f45ae13ee0664479152489ef70d`),
and both normal runs report `allocations=0` after allocator reset. Artifacts:
`/tmp/blorp-id-c0b-direct-normal-{parent,candidate}.c/.log`.
Two `-O2` toy exact-profile runs additionally reported exactly two equality
and two scope-lookup calls, with zero measured allocations
(`/tmp/blorp-id-c0b-direct-o2-toy-{1,2}.log`).

The integrated D0 gate compares current-main parent
`c4f7c16352e664714da74ba26e8f99f14ef52240` with direct-selector candidate
`db9146e95323`, compiling the same frozen current-main input from the same
working directory with fresh `-O2` compilers and two instruction samples.
Generated program C is byte-identical (78,677,202 bytes, SHA-256
`d968bfd95186825d9e33c80815140f76b7729fc5c66f421c20bcd87521e2b643`).
Every allocation checkpoint is identical, including discovery at 8,509,405
and the 195,308,238 total. Minimum retired instructions are
151,476,328,277 parent and 151,474,784,130 candidate (-0.001%). The retained
records and generated C are
`/tmp/blorp-id-d0-measure.LoXsWT/{parent,candidate}-same-cwd.json/.c`.

An earlier cross-worktree comparison is rejected measurement evidence. It
ran each compiler from its own differently sized checkout path and reported
25,004 extra transient discovery allocations even after compiler C became
byte-identical; rerunning the parent from the candidate working directory
reproduced the candidate count exactly. Self-compile comparisons must hold
the working directory fixed because discovery constructs path strings and
its allocation count is path-sensitive. The rejected records are the other
`parent*.json` and `candidate*.json` files in that artifact directory.

## Historical evidence, not current acceptance

The earlier unfiltered exact-mode specialize replay of the marker candidate
already included profiler rows for the original functions, independently of
their markers:

| Existing function | Direct calls | Former marker count after registration subtraction |
| --- | ---: | ---: |
| `core_var_equal` | 111,577 | 111,577 |
| `scope_lookup` | 4,731,560 | 4,731,560 |
| `core_var_impl` | 358,423 | 358,423 |

The raw row evidence is `/tmp/blorp-id-c0b-specialize-1.log`. It supports the
call-boundary substitution but is not a replay of the revised worker. The
old paired five-marker calls-mode artifacts
(`/tmp/blorp-id-c0b-calls-{1,2}.log` and `.core`,
`/tmp/blorp-id-c0b-calls-counts.json`) are retained only as rejected-candidate
diagnostics. They must not be used as revised-candidate acceptance evidence.
The old calls-mode pair took 41.39/39.27 seconds, peaked at
8,394,670,080/8,394,145,792 bytes RSS, and serialized ~389 MiB Core output
each run. A no-dump probe streamed that Core output to stdout instead and did
not improve resources (`/tmp/blorp-id-c0b-no-dump-1.log`).

## Coverage limits

`covered_helper_sites = [stage_08_core_lower/lower.brp:core_var_impl]` and
`total_static_constructor_sites = 47`. The denominator is a pinned,
source-shape-conditional census of lexically adjacent `name`, `id`, `def_id`
fields in complete-field CoreVar literals under stage 8/9. It excludes record
updates and is **not** a semantic total-construction count. The test fails if
the per-file census or observed helper changes. C3a owns moving remaining
raw sites to a central constructor; this checkpoint does not rewrite them.

No current central ID-to-display/name accessor serves Core and backend.
C1/C3 must add the display selector at that authority when it exists. Separate
string-hash calls cannot be observed without library/runtime intrusion;
scope-lookup and CoreVar-equality call counts are explicit proxies, not exact
hash/string-equality operation counts.

The compiler-sized replay uses explicit Core dump files and `/dev/null`
output. Its benchmark-only LSP native hook link input remains necessary
because it imports CLI main. The 47-site census and unsupported display
status are coverage labels, not additional profiler rows.
