# Record storage cleanup, 2026-10-07

Base: `b5a05c9593cf70caafa159b6fb86e5fe2b26c28b`. This is a record-only
preparatory cleanup; construction migration and scalar replacement remain
separate work. No tuple representation changes or runtime speed claims.

Production source removes 164 lines net: 112 in sparse update preparation and
reuse, 22 in assignment-query consolidation, and 30 in release emission. Tests and
documentation are counted separately.

Sparse `RecordUpdateExpr` rows contain authored replacements in written order.
Ownership supplies inherited fields from declarations and produces complete
storage rows. One staging path replaces inheritance-shape classification and
parallel single/nested update planning. JSON validates spelling against checked
field identity; ownership uses identities and declaration metadata.

## Reviewed identity census reconciliation

The pristine base passes the old census, and its exact keys equal the baseline.
The historical baseline revision is outside main's ancestry; this is a label
issue, not pre-existing exact-site drift. The retained
[evidence](record_storage_cleanup_identity_2026-10-07.json) records all 34 added
and 35 removed keys, source excerpts, and hashes of changed production files.

- 32 added/33 removed dictionary sites are declaration-index annotations:
  value types change to the heap/inline declaration union, the builder is
  renamed, two old resolvers disappear, and materialization gains the index.
- One `Set[String]` fingerprint changes with the consuming-state structure;
  its ownership-type set keeps its existing meaning.
- Lowering loses one spelling-based field selection. JSON gains one metadata
  consistency check after resolving the field identity. The total spelling
  predicate count stays flat; lowering's budget decreases 3 to 2 and Core's
  increases 16 to 17. This validates ingress data, not field selection by name.
- Core's string dictionary budget decreases 188 to 187. The consuming-slot
  index uses global checked field IDs: `CoreFieldRef` guarantees distinct IDs,
  and monomorphization preserves refs and declaration order.

Unrelated budgets, coverage metadata, approved boundaries and unsupported
capabilities are preserved. The lexical census does not establish complete
semantic identity migration.

## Validation

Fresh compiler: pinned `dev-dbc23276a2a6`, Apple Clang 21, CLI/runtime `-O2`,
eight split translation units, base `b5a05c9593cf` plus this change. Review
reports zero blockers, should-fixes or nits. Hygiene passes: six harness tests,
374-module/274-suite manifest, 3,444 census rows within reviewed budgets,
504 approved magic-spelling sites and no stale entries.

This cleanup's compiled workloads run serially. Independent chats also ran
compiled gates on the machine; gate elapsed times are not performance evidence.

The new written-order runtime regression fails on the earlier main compiler.
Final focused checks pass: 71 reuse, eight nested ownership and seven update
order tests. Earlier integrated checks also passed 157 JSON, 44 consuming
specialization and 70 pipeline tests; the selected gates rerun these.

The behavioral baseline compiler is `87630c7074d7888b154a3317e66cfb451380d0c1`
(an earlier main revision), built with the same bootstrap, Clang and O2
settings.

A selected leak gate exposed a staging regression in the existing nested
`NameTable` oracle: 1,010 allocations instead of the baseline's 11 for 1,000
updates, with correct values and no leaks. The first staged field's take proof
rejected the following list append's synchronous operations. Its explicit
fall-through contracts now include `list_len` (arity 1), `list_ensure_capacity`
and `list_set_len` (arity 2), plus prepared list retain/raw-store operations and logical record construction.
All operands must complete normally; owner, alias, source-slot and early-exit
checks remain. Unknown/user calls and cooperative checkpoints stay conservative.
The representative complete append-prefix Core test fails before the fix and
passes after; negative tests isolate observation and exit rejection.

The fresh compiler restores the original oracle to 11 measured allocations
(19 total allocations/releases, zero leaks), matching baseline. The original
48-allocation ceiling remains. The unique list-field oracle also passes its
32-allocation ceiling for 1,000 reordered updates.

Generated-C inspection:

- Mixed record release/COW fixture: byte-identical C to baseline
  (`db7209a0ab10360e1c5392e97960fa8e3428b3a835086b3c7d801a1a852e10bf`).
- Reordered fixture: static-string first-use order and replacement staging
  change; `second` runs before `first`, values remain in their declared slots.
- Nested ownership fix: exactly one generated line changes from an unconditional
  Dict retain to unique-source slot clearing/shared-source retain. List take
  and evaluation sequence stay intact.

Final selected gate on `b5a05c9593cf` passes:

| Check | Result |
| --- | --- |
| `make hygiene-check` | PASS |
| `scripts/compiler-check --changed --base origin/main` | PASS: 4,726/4,726 |
| Owning suites within selected gate | PASS: 988/988 |
| Core sanitizer within selected gate | PASS: 2,516/2,516 |
| Generated-C audit within selected gate | PASS: 233/233 |
| Leak within selected gate | PASS: 1,221/1,221 |
| `scripts/test --no-build --serial compiler-blorp` | PASS: 6,962/6,962 |
| `scripts/test --no-build --serial compiler-new` | PASS: 1,007/1,007 |
| `scripts/test --no-build --serial compiler-new-parity` | PASS: 3,632/3,632 |
| `scripts/test --no-build --serial runtime` | PASS: 4,780/4,780 |
| `scripts/compiler-fixpoint` | PASS: all three stages emit identical C |

The selected total counts the generated-C audit as one shell check. The first
broad run passed compiler-blorp 6,960/6,960 but exposed six parser allocation
pins and six matching load pins. Named-parameter creation stages `binder_names`
before `parameters`; its later replacement constructs managed `ParameterRow`
and inline `RowRange` values. Explicit `RecordExpr` field recursion preserves
the take across these synchronous constructions, with observation/exit guards.
The complete representative prefix fails before and passes after this extension.
Focused parser 29/29 and load 25/25 pins pass unchanged; the complete generated-C
diff restores one binder-name list field take. The worktree has advanced onto
`b5a05c9593cf` without conflicts; the selected gate passes again on this base.
All 11 runtime allocation oracles pass. The final fixpoint comparison matches
all three stages byte-for-byte: generated C is 82,201,013 bytes, SHA-256
`11707be91fe37d19f39ee62d30f583e1d60bcb6b611032d579b13637e52d2121`.
This checks self-compilation stability, not baseline/candidate performance.
