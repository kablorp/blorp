# Local migration bootstrap bring-up

This is a reproducible **temporary local bring-up**, not an immutable bootstrap
release, pin rotation, or default-pin/publication closure. The migration uses a
staging compiler that understands the shared non-generic, payload-free union
layout and its existing equality, hashing and scalar native contracts.

## Reproduce the staging compiler

Start a separate clean checkout at
`cbffad8a3b2cc62cf0194e13c97b44bc775ace4d`. The frozen
[bootstrap-bridge.patch](bootstrap-bridge.patch) changes exactly four production
files: declaration materialization, accepted header layout, accepted union
authority comments, and Core lowering. It excludes declaration migration,
tests, generated inputs and the later root-only fixture/doc corrections.

```bash
git worktree add --detach /absolute/path/union-bridge cbffad8a3b2cc62cf0194e13c97b44bc775ace4d
git -C /absolute/path/union-bridge apply --check /absolute/path/migrated-checkout/benchmarks/results/fixed_union_declaration_migration/bootstrap-bridge.patch
git -C /absolute/path/union-bridge apply /absolute/path/migrated-checkout/benchmarks/results/fixed_union_declaration_migration/bootstrap-bridge.patch
```

From that bridge checkout, use the unchanged pinned bootstrap:

```bash
shasum -a 256 -c /absolute/path/migrated-checkout/benchmarks/results/fixed_union_declaration_migration/staging-production.sha256
env -u BLORP_BOOTSTRAP_COMPILER_BIN BLORP_CLI_C_OPTIMIZATION=-O2 make
env -u BLORP_BOOTSTRAP_COMPILER_BIN scripts/compiler-build-status
bin/blorp --version
shasum -a 256 bin/blorp
```

Then, from the migrated checkout:

```bash
BLORP_BOOTSTRAP_COMPILER_BIN=/absolute/path/union-bridge/bin/blorp BLORP_CLI_C_OPTIMIZATION=-O2 make
BLORP_BOOTSTRAP_COMPILER_BIN=/absolute/path/union-bridge/bin/blorp scripts/compiler-build-status
```

Keep the bridge checkout and executable until local builds no longer depend on
the override. The observed executable digest below identifies the actual run;
another checkout/toolchain/build stamp is not promised to produce identical
binary bytes. Record its own FRESH status and digest. Do not infer that plain
`make` against the unchanged immutable pin has validated the migrated checkout.

## Observed provenance and bounded evidence

- Staging base: `cbffad8a3b2cc62cf0194e13c97b44bc775ace4d`; dirty four-file bridge.
- Patch SHA-256: `30f0f88f0f9454782ffb17e4255f8c7ba2b4d2f654bb73b5516aed79cc66379f`.
- Actual FRESH staging binary: `2ebad178e2fae23d1062ab25f628762891a650a474152ac6df6dea4a78479014`.
- Pinned compiler: `dev-c3040e79c7d8`, aarch64-apple-darwin SHA-256
  `8999d1a144b604f58329fa67ea17f63a8490e19d956a1f6e89d632a52b98d078`.
- Build: CLI/runtime `-O2`, eight split translation units, Apple clang 21.0.0
  (`clang-2100.3.34.2`); stamp `cbffad8a3b2c-dirty`, compiled by the pinned compiler.
- Sorted file SHA-256 aggregate of `blorp/src` and `standard_library/src`:
  `0785445dc80ece4207d72eaa07a070711fb0dc66fc8927ea0fa08c51f23a5390`.
  Compute with `rg --files blorp/src standard_library/src | sort | xargs shasum -a 256 | shasum -a 256`.
- Actual build-input manifest SHA-256:
  `6f2a152231fd0b9fc4b3a3ae24fcf591ecf84a63f896749b5b4a5b42ebc8e98f`.
  Every file in that build manifest reverified unchanged after the staging run.

The historical [oracle source](staging-oracle.fixture.txt) and
[native header](staging-oracle-header.h.txt) are inert evidence, not live source
modules. Pinned baseline `check --std-dir standard_library/src --no-format`
rejected plain/fixed default Eq/Hash and scalar native admission (legacy control
admitted); see [diagnostics](baseline-check.stderr.log). The staging compiler
passed source checking and lowering, then `test --std-dir standard_library/src
--suite --leak-check --timeout 180`: [five cases passed](staging-runtime.stdout.log),
with [3 allocations, 3 releases, zero leaked objects/bytes](staging-runtime.stderr.log).

Root progress separately recorded 402 focused cases: 192 declaration tests,
151 Core-lower tests and 59 header-graph tests, using fresh migrated compiler
`e27b8bc719a8e7f4554368be27d522e039ccaed6c8717d9c698fdebe77296ea9` and
explicit own Std. These overlap the separately repeated 151-case repair run;
do not add the counts. This record does not claim completion of broad gates,
fixpoint, immutable release or bootstrap-pin validation.
