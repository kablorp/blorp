# Identity work counter checkpoint

## Retained production replay

The frozen compiler input is parent revision
`bbea8789383f51f471358569acb4c0ae1091b2c8`, tree
`f1d74095c39d9a47abf10774029e2248168a5427`, with
`blorp/src/main.brp` blob `e4edf283c6bb7f761c4e42d07885e57f63561f72`.
The candidate `bin/blorp` SHA-256 is
`7f06499cd86f3910236211ed8fdaff9289936ab2663a95d3eb92e10c0f1e0229`;
the benchmark worker SHA-256 is
`bdc611b5e3c464021291769f494b01d49312fd233fde89b2a6e3b173233c37dc`.
`benchmarks/compiler_identity_work_replay` builds that worker through the
existing benchmark helper, with the CLI main and required LSP native hooks.
The worker self-compiles the frozen main through `--stop-after=specialize`,
selecting only the four marker functions and registration function in
`--profile-mode calls`. This is the earliest measured late-Core boundary that
exercises both central scope lookup and CoreVar equality.

Two serialized runs exited successfully with identical counts, after
subtracting the one schema-registration call from every marker:

| Marker | Calls in each run | Coverage |
| --- | ---: | --- |
| `identity_work_core_var_equal` | 111,577 | Central `core_var_equal` calls |
| `identity_work_local_scope_lookup` | 4,731,560 | Central stage-6 `scope_lookup` calls |
| `identity_work_observed_core_var_constructor_helper_calls` | 358,423 | `stage_08_core_lower/lower.brp:core_var_impl` calls only |
| `identity_work_observed_display_lookup` | 0 | `unsupported_current_authority`; not a runtime-demand estimate |

Both calls-mode diagnostics say `functions_selected=5`,
`functions_observed=5`, `calls_observed=5,201,565`, and
`calls_completed=0`; all reported loss/corruption and abandoned-frame fields
are zero. The extractor rejects missing/nonzero diagnostics, incomplete marker
rows, unequal call totals, mismatched counts, mismatched Core hashes, and
unsuccessful runs. The two ~389 MiB serialized Core outputs share SHA-256
`24dea825ed4482742dcf50f90570c5b86aab00ff44eb2c3ae5ba325b5d7e365d`.
The unfiltered and five-selector exact-mode specialize pairs produced these
same counts and Core hash.

Retained artifacts outside the repository:

- `/tmp/blorp-id-c0b-calls-counts.json` — checked extraction and provenance.
- `/tmp/blorp-id-c0b-calls-{1,2}.log` — raw profiles, diagnostics, stderr,
  success status, and resource rows.
- `/tmp/blorp-id-c0b-calls-{1,2}.core` — serialized output identity oracle.
- `/tmp/blorp-id-c0b-calls-worker/compiler_identity_work_replay` and
  `/tmp/blorp-id-c0b-calls-build.log` — worker and build evidence.

This is an observability checkpoint, not a fast routine benchmark: runs took
41.39/39.27 seconds and peaked at 8,394,670,080/8,394,145,792 bytes RSS.
The named Core-stage stop serializes ~389 MiB. A no-dump probe was rejected:
the stop emitted the same Core JSON to stdout, making a ~389 MiB log, with
42.28 seconds and 8,397,635,584 bytes RSS. Its diagnostic is
`/tmp/blorp-id-c0b-no-dump-1.log`; it is not acceptance evidence. Earlier
lower stopped before Core equality (zero calls); a Perceus probe exceeded the
fast-feedback resource boundary. Neither is the retained production result.

## Coverage and normal-build contract

`covered_helper_sites = [stage_08_core_lower/lower.brp:core_var_impl]` and
`total_static_constructor_sites = 47`. The denominator is a pinned,
source-shape-conditional census of lexically adjacent `name`, `id`, `def_id`
fields in complete-field CoreVar literals under stage 8/9. It excludes record
updates and is **not** a semantic total-construction count. The focused test
fails if the per-file census or sole covered helper changes. C3a owns moving
the remaining raw sites to a central constructor; C0b does not rewrite them.

No current central ID-to-display/name accessor serves Core and backend.
C1/C3 must move the registered-but-uncalled display marker to that accessor
when the display authority exists. Separate string-hash calls cannot be
observed without library/runtime intrusion; scope-lookup and CoreVar-equality
counts are explicit proxies, not exact hash/string-equality counts.

The debug-only markers use `black_box_int(0)` and no mutable runtime counter.
Parent and candidate normal `examples/hello.brp` generated C were
byte-identical, SHA-256
`e26bd0ce67ff86cbaf838aa47d6b123a0c4d44ab6b0770bcf1619f9928615025`.
The candidate's normal compiler-importing fixture C had no marker or
registration symbols/calls; parent and candidate fixture binaries both
reported `allocations=0` after allocator reset around measured calls. That
compiler-importing fixture C was **not** byte-identical: importing the
debug-only module shifts generated definition IDs. It is the allocation
oracle, not the byte-identity oracle. Artifacts are
`/tmp/blorp-id-c0b-hello-{parent,candidate}.c`,
`/tmp/blorp-id-c0b-{parent,normal}.c`, and
`/tmp/blorp-id-c0b-counts.json` for the two-run toy exact-profile fixture
(2 equality, 2 scope, 0 allocations).

## Validation and friction

`scripts/compiler-check --changed` passed 2,473/2,473 selected cases,
five suites and two checks; `scripts/compiler-check --validate-manifest`
passed 348 modules/253 suites/10 checks. A first production-worker build
exposed missing local include paths; an initial link exposed LSP native hooks
pulled in by CLI main. These were resolved only in the benchmark worker's
include/link inputs, with backwards-compatible helper options and focused
command-construction tests. The failed diagnostics remain under
`/tmp/blorp-id-c0b-replay-build.log` and related build logs.
