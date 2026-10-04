# Managed-record migration: remaining gates

Implementation checkpoint: `83a9c1082811d90bb45dd839975a1273ed6b8e46`.
The [repair checkpoint](record_s4_repair_checkpoint_2026-10-03.md) records
the preceding 11,586 selected checks and self-hosting fixpoint. The first
sections record the feature checkpoint before integration; the final section
records validation on current main. Keyword retirement is still separate.

## Committed-source integration

The remaining integration run passed 13,830 checks with zero failures:

| Gate | Passed |
| --- | ---: |
| Discovery parity | 3,422 |
| Leak suites and diagnostics | 1,158 |
| Core ASan/UBSan | 2,374 |
| Full compiler ASan/UBSan | 5,557 |
| Doctests | 1,057 |
| CLI deep integration | 177 |
| LSP | 36 |
| Package | 49 |

```bash
env BLORP_CLI_C_OPTIMIZATION=-O2 scripts/test --no-build --serial \
  --log-dir /tmp/blorp-fixed-spelling-verify.RGgg2k/committed-remaining-logs \
  compiler-new-parity leak compiler-core-sanitize compiler-blorp-sanitize \
  doctest cli-deep lsp package
```

The compiler was FRESH and the worktree clean at the checkpoint commit.
Installed compiler SHA256:
`149da2fae37c89a9d8af1d161386bed526d29fc1e67b34f15e1d28a7c4198b92`.
Independent test-runner review verified counts, artifact hashes, unchanged
source, no timeout, and no unexpected sanitizer errors. Raw packet:
`/tmp/blorp-fixed-spelling-verify.RGgg2k/committed-remaining-gates`.

## Stage-2 oracle and bounded follow-up repairs

A stage-2 compiler was built from the committed sources, not substituted
with a bootstrap-built executable. Its SHA256 is
`f9cdb416b9c9b9c81aa7d2d216c96516530a886623e89577b6eb9efeb537833e`.
Its generated compiler C is byte-identical to the previously verified
77,773,084-byte stage-1/2/3 fixpoint output, SHA256
`daae57fdf54955c7af8d0a029295bc799f59807586af65afb15ecda9fff0cba6`.
These follow-up repairs do not modify production compiler or runtime sources.

The direct stage-2 audit initially passed 217/228 fixtures. All 11 failures
were obsolete C expectations: managed constructors/fields, native snapshot
copy-out, union release masks, pointer collection layouts, canonical empty
lists, and managed Option dispatch. No compilation or warning-sweep failure
was found. New controls preserve ordinary versus fixed record value behavior,
genuine scalar enum payload layout, and wide scalar Option fallback.
Canonical Pair lists now have typed global pool pins and same-type runtime
identity checks, rather than an unrelated String return satisfying their oracle.

The attempted bounded-range filter-map control was rejected because the
public generic result widened to `List[Int]`; it was replaced with a valid
`Int128` control, not a compiler change. Its direct mapper uses a stack Option;
the closure ABI still boxes that temporary, which is legitimate and not a
zero-allocation claim.

Quality first failed at the benchmark census vocabulary: its `range` tag
described the removed Core expression, not the surviving `for_range` or
bounded integer type. Only that stale tag was removed. One duplicated allowlist
entry was removed; the live producer remains covered by the retained entry.

## Actual layout benchmark

The standalone driver initially failed on hardcoded C type names. It now
uses final Core plus the existing emission symbol/member authorities; its
eight-row mapping is validated before probe generation. The first real helper
execution additionally found five forbidden loop-local `?=` operations.
Precise Result accumulators preserve the first error and all missing,
duplicate, field-identity, and authority checks.

```bash
BLORP_RECORD_LAYOUT_SKIP_BUILD=1 \
BLORP_RECORD_LAYOUT_KEEP_STAGE=1 \
BLORP_RECORD_LAYOUT_COMPILER=/tmp/blorp-fixed-spelling-verify.RGgg2k/committed-stage2 \
  benchmarks/compiler_record_layout
bash blorp/test/compiler/benchmark/test_record_layout.sh
```

The real stage-2 driver passes with eight rows at each of `-O0` and `-O2`;
size/alignment, header, allocator bytes, and measured field offsets/sizes agree
between modes. Renamed mock types and members prevent the old hardcoding from
passing; five corrupt mapping cases reject before C compilation. The schema-3
metadata contract remains unchanged. Helper, final Core, mapping and probe C
are retained in the existing KEEP_STAGE directory for independent inspection.

Local packets `repaired-record-layout-harness` and
`repaired-record-layout-probe-2` retain the executed checks. Raw scratch
artifacts are local and not permanent repository assets. Four additional
small standalone profile inputs execute successfully with the current compiler;
their output is smoke evidence, not a performance comparison. Snapshot observer
costs and the alias profile's bootstrap default remain separate measurement debt.

## Final follow-up validation

The fixture/helper repairs and bounded documentation cleanup have independent
code-review approval with no P0/P1/P2 findings. Final recorded checks pass:

| Check | Result | Packet under the artifact root |
| --- | --- | --- |
| Actual stage-2 codegen audit | 228 passed, zero failed | `final-stage2-codegen-audit` |
| Full quality | All five subtargets pass | `final-quality` |
| Fresh-binary discovery parity | 3,422 files, zero mismatches | `final-fresh-parity` |
| Four new runtime controls, actual stage 2 | All exit zero | `final-stage2-runtime-controls` |

Artifact root: `/tmp/blorp-fixed-spelling-verify.RGgg2k`. Commands:

```bash
blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh \
  /tmp/blorp-fixed-spelling-verify.RGgg2k/committed-stage2 --jobs 1
BLORP_CLI_C_OPTIMIZATION=-O2 make quality
BLORP_CLI_C_OPTIMIZATION=-O2 make
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-build-status
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/test --no-build --serial \
  --log-dir /tmp/blorp-fixed-spelling-verify.RGgg2k/final-fresh-parity-logs \
  compiler-new-parity

for fixture in fixed_record_matches_struct_layout canonical_empty_list_literals \
  parallel_filter_map_stack_fallback union_struct_enum_payload_typed; do
  /tmp/blorp-fixed-spelling-verify.RGgg2k/committed-stage2 run --no-format \
    "blorp/test/compiler/pipeline/codegen_audit/should_pass/$fixture.brp" || exit "$?"
done
```

Quality includes hygiene, tooling, benchmark tooling, generated-artifact scan,
and C static analysis. Its 32 Python test groups pass (462 cases, three
intentional skips); non-fatal subprocess ResourceWarnings remain. C analysis
reports no findings under its existing checker configuration, which still
suppresses `unix.BlockInCriticalSection`.

`make quality` rebuilt the internal CLI's dirty-tree build stamp without
reinstalling `bin/blorp`. The first follow-up parity run therefore used the
original installed binary and is not the final FRESH oracle. An `-O2 make`
refresh restored FRESH status before `final-fresh-parity`, whose installed
compiler SHA256 is
`743b106feb342817d1b0fb58cf33e2775e277dc058ce476c018dc0a546cf7f11`.
The actual stage-2 audit and runtime controls still use the separately named
`f9cdb416…` compiler, not the recorder's installed compiler field. Parity's
two existing known divergences remain explicitly documented in its raw log.

Each final packet records unchanged source during its run; the final audit
and quality share the frozen tracked diff SHA256
`39e8dd8e6a2447fbdc7cd3b5d8239f17d7bf38d76c68dbe401719e18749b282d`.
The earlier integration and layout packets belong to their separately recorded
bounded snapshots, not a claimed universal fingerprint. Final prose/status
updates were made after compiled checks completed.

The remaining S4 correctness gates are satisfied in this checkout. Rebuild
before using `--no-build` if build status is not FRESH. No release, keyword
removal, performance improvement, merge, or push is implied by this record.

## Integration on current main

The squash was prepared on `4535746a6a210791994027030a7309de820ee166`,
preserving all seven intervening main commits. Core conflict resolution keeps
the runtime-tag authority and identity cleanup while deleting obsolete
value-record and range-expression paths. Discovery docs retain main's concise
organization. The exact marked-fixture census is 826 (716 compiler and 110
compiler-new); this includes main's diagnostic additions, not a guessed count.

All compiled checks below ran against one frozen source snapshot, tracked
diff SHA256 `33349ebdac741d98e9684b3a02712eff200761a414c82fc67a2085db7a4c847b`.
The installed compiler was FRESH, SHA256
`4bf64ef41f2b83b0d976bcc25a3f34e0163a667ddaaebf123c1f53a6b608b91b`.
Packets are under `/tmp/blorp-record-s4-publish.daoiPi`:

| Packet | Result |
| --- | --- |
| `integrated-gates` | 13 gates, 25,438 passed, zero failed |
| `integrated-fixpoint` | Three byte-identical compiler C outputs |
| `integrated-stage2-codegen-audit` | 228 passed, zero failed |
| `integrated-quality` | All five targets; 463 Python cases, three skips |
| `integrated-stage2-runtime-layout` | Four compiled/executed controls; eight layout rows each at O0 and O2 |

The broad gates cover compiler suites/fixtures, discovery and parity, compiler
tools, standard library, runtime, leaks, both sanitizer gates, doctests, CLI,
LSP, and packages. The two existing parity divergences remain documented;
694 negative discovery fixtures still use their legacy diagnostic oracle.
The ResourceWarnings and static-checker suppression noted above persist.

Each fixpoint C file is 75,408,665 bytes, SHA256
`70a58a3a98972be917801a0b455212dce39eb35235b9cf592fb3df59190d2409`.
This is equality across stages for the integrated input, not against the older
feature's C output. The actual audit/runtime/layout target is
`/tmp/blorp-record-s4-publish.daoiPi/fixpoint/blorp-stage2`, SHA256
`8d0ee21dd12eaa43742fc236be7c059f262b5a46e7d860a17c1b9984ec1a5553`,
not the installed compiler recorded by the packet wrapper.

```bash
env BLORP_CLI_C_OPTIMIZATION=-O2 scripts/test --no-build --serial \
  --log-dir /tmp/blorp-record-s4-publish.daoiPi/integrated-gate-logs \
  compiler-blorp compiler-new compiler-new-parity compiler-tools std-check \
  runtime leak compiler-core-sanitize compiler-blorp-sanitize \
  doctest cli-deep lsp package
env BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-fixpoint \
  --work-dir /tmp/blorp-record-s4-publish.daoiPi/fixpoint
blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh \
  /tmp/blorp-record-s4-publish.daoiPi/fixpoint/blorp-stage2 --jobs 1
env BLORP_CLI_C_OPTIMIZATION=-O2 make quality
```

Packet metadata retains the exact commands, log hashes, source fingerprints,
exit codes, and timeouts. Independent code-review and test-runner reviews
approve the integration. Final documentation updates follow the frozen runs.
This closes S4 correctness validation; it does not claim a performance win,
release validation, or retirement of the `struct` keyword.
