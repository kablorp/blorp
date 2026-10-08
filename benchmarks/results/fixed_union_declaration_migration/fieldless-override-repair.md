# Fieldless union explicit equality and hashing

The common scalar layout exposed two real regressions for ordinary fieldless
unions: hashed collections bypassed authored callbacks, and constant evaluation
used tag equality before Core could restore an authored equality call. The
repair keeps scalar storage unchanged, chooses authored callbacks before native
shortcuts, and synthesizes one explicitly originated native tag-equality callback
only when a scalar union authors hashing but retains default equality.

Default tag equality still supplies default hashing. Potentially matching custom
equality requires explicit hashing: equal keys must have the same hash, which
tag hashing cannot guarantee for a different equality relation. This is a
deliberately conservative, nonrecursive pattern rule, including conditional
implementations whose other bounds may be inapplicable. Exact accepted hash
implementations and real installed native hashes precede fallback. Canonical
trait identities exclude unrelated namesakes and Orderable-only implementations.

## Reproduction and validation

Raw packet: `/tmp/fieldless-override-probes.SHeBht`.

Pinned 8999 versus pre-repair root e27, using the same unmigrated staging Std:
authored Eq+Hash collections changed from correct to incorrect; Eq-only keys
changed from rejected to admitted; constant-false equality changed from false
to true at constant evaluation. Runtime equality alone passed because later Core
trait resolution repaired it. Direct-method discrepancies existed on both hosts
and are not attributed to this migration.

Updated source owners, executed through existing hosts before rebuilding:

- Accepted semantic catalog: 30/30, including default, Eq-only, pair, Hash-only,
  conditional Hashable cycle, inapplicable bound, namesake/subtrait, native Bool,
  exact-bound precedence and direct-evidence controls.
- Inference: missing-help regression 340/341 RED, then 341/341 GREEN, with a
  namesake Hashable control. The diagnostic branch now retains the exact identity
  it already used for the failed obligation; dispatch is unchanged.

The intermediate fresh e90 host executed runtime bridge 8/8 with 3 allocations,
3 releases, zero leaks/bytes. Hash-only emitted Core and C were byte-identical to
the earlier inspected nine-owner artifacts: authored hash via the registered
adapter, native tag equality via its explicit generated origin, and a custom
Dict constructor using both callbacks. Default keys retained the native fastpath.
Core SHA `b881dc8d08b3f0bfb1700b23d863638efaddf6e3eb34e26407307a09b605b30c`;
C SHA `c4104e4b2661c160f640fbb45d3ff00105e7488fea914b433fbec9ef7beb8e54`.

The final host was rebuilt after the identity-only help correction:

```sh
BLORP_BOOTSTRAP_COMPILER_BIN=<worktree:union-migration-bridge>/bin/blorp BLORP_CLI_C_OPTIMIZATION=-O2 make
```

Final binary SHA `ee23938ff1411e093f1de268b230a202ef6623759b990fb8cf1427750de17823`.
Build status was FRESH with this explicit override: CLI/runtime O2, split8,
Apple clang 21.0.0, compiled_by self-cbffad8a3b2c, cbff-dirty. Compiler/Std input
manifests were identical before/after the final build, manifest SHA
`1f83d2a0711a2c945d5605579c109cf6b458a60edf24e845809cb614366ad7a2`.
The frozen staging override SHA remains
`2ebad178e2fae23d1062ab25f628762891a650a474152ac6df6dea4a78479014`.
Its reproducible source recipe is in [README](README.md); default immutable-pin
closure is not claimed and no release/pin changed.

Final public check, explicit own Std and `--no-format`, rejected the single new
fixture with exactly five intended errors and five actionable helps: ordinary
and fixed bare hashing, ordinary and fixed Dict keys, and a Hashable-bound call.
Actual messages/help are pinned in the fixture. Diagnostic SHA
`2bf557224a9c6d4ddb3dfe290515da22e6652fd0228f2247f83e93c0e2d1cc76`.
Exact fixture census is 839: preceding 838 plus this one marker, not relaxed.

Focused commands (all invoked from the root checkout):

```sh
repair_std=<worktree:43a9>/standard_library/src
bin/blorp test --timeout 180 --std-dir "$repair_std" blorp/test/compiler/stage_06_typecheck/test_accepted_semantic_catalog.brp
bin/blorp test --timeout 180 --std-dir "$repair_std" blorp/test/compiler/stage_06_typecheck/test_infer.brp
bin/blorp test --timeout 180 --leak-check --std-dir "$repair_std" blorp/test/runtime/types/test_fieldless_union_scalar_bridge.brp
bin/blorp check --no-format --std-dir "$repair_std" blorp/test/compiler/stage_06_typecheck/infer_fixtures/infer/should_fail/fieldless_custom_equality_requires_hash.brp
```

The first owner ran through host8a and the second through e90, executing updated
source implementations; runtime used e90. Only the final public check used ee239.
They are separate source/binary epochs, not a claim that all were rerun on ee239.

## Scope and limitations

Ten production repair owners; final production diff SHA
`8c218567186763dcb905a013d270b8d4d2113c21f45131c9f4e3e0755aa968f9`.
No physical storage, ABI, backend, bootstrap pin, or general trait-closure redesign.
Only this worker's unrelated formatter hunks were removed; migration declarations
and coordinator edits were preserved. No staging tree mutation or rebuild.

Earlier source setup stops executed zero assertions; intermediate aggregate
matrix failures were isolated before correction. Earlier 8a Core owners 179/179
and runtime8, and pre-repair root402/parser epochs, are separate historical
epochs, not rerun final-host broad acceptance. Final independent broad gates
remain the coordinator's next step. No performance claim, commit, or publication.
All worker compiled children ended and the token was released after the final
public check.
