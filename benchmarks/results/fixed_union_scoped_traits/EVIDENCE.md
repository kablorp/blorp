# Scoped trait method identity preparation

Pre-commit validation snapshot, 2026-10-05, with independent acceptance recorded
below. This is identity preparation, not the default-callable publisher or
concrete default-body binder.

Artifact root: `/tmp/blorp-scoped-traits.lb0ugU`. Full logs, rejected candidate
logs, frozen standalone input, raw Core/C, and executable snapshots are retained
there. This durable directory contains this evidence note, not those raw logs.
The first selected-gate failure also retains its original logs under
`logs/compiler-check-20261005-050829-74772` in the candidate checkout.

## Contract and scope

Scoped functions retain source spelling separately from their owner:
accepted issuer plus issued `TraitMethodId`, registered compiler `TraitId`, or
explicit unindexed trait spelling. Accepted reads validate issuer before member
lookup; invalid reads are terminal rather than permission for builtin/Env
fallback. Unindexed owners are rejected in the reserved graph domain, not merely
because semantic authority is present. Imported/lexical ordinary-function
precedence is unchanged.

Implementation body preparation uses its already-owned resolved header. The
authority returns either actual issued methods or an explicitly compiler-owned
trait with no linked source row. Linked canonical source rows retain their
issued slots; missing slots cannot enter the compiler branch. The compiler
branch validates the registry and exact Env owner. Existing compiler obligation
and implementation-candidate policies are reused by exact ID, not spelling.
Inherited methods retain their declaring owner and local-first order.

Four production owners changed. Three existing test owners cover metadata,
authority, and inference consumers. One existing benchmark consumer was migrated
from tuple seeds/list equality to the new owner representation and a private
ordered exact-identity comparator. No new public equality API was introduced.

## Before and after

The own O2 baseline was built before production edits at base
`86432d73db3dc0904ff0061a2a71e023306dc212` (compiler sources equal d390).
Its FRESH executable SHA256 was
`0f43d6b8071fd491044016d9cf27a7cd064385fa82c8f16321ec26752e69bbb5`.
`baseline-premise.log` records 171 pass / 1 fail: the materialized default exists,
has a callable, and has no setup errors, but its inner method reference loses the
issued trait identity. The unchanged identity expectation passes after the fix.
The premise control remains in the passing suite.

Final build is FRESH, bootstrap `dev-d44472d3a5d0`, CLI/runtime O2/O2, split8,
Apple Clang21, memory diagnostics0. Native executable SHA256:
`738989b448c6f8014ebfb0aae48347b8242ed514a78f7de0a29f2021e6fcae3f`.

Final focused command uses `bin/blorp test --timeout 180` with the inference,
declaration, semantic catalog, and reconstruction-profile suites. Results:

| Validation | Passed / total | Raw log |
| --- | --- | --- |
| Inference, including three direct invalid accepted-owner consumers | 336/336 | `final-focused-frozen.log` |
| Declaration, including real default metadata and linked missing-slot controls | 173/173 | `final-focused-frozen.log` |
| Semantic catalog/authority | 9/9 | `final-focused-frozen.log` |
| Existing reconstruction benchmark owner | 1/1 | `final-focused-frozen.log` |
| Actual selected checks, final source | 688/688 | `final-compiler-check-frozen.log` |
| Compiler integration | 6534/6534 (5704 assertions +830 fixtures) | `gates/compiler-blorp.log` |
| Compiler tooling | 222/222 | `gates/compiler-tools.log` |
| Leak/ownership | 1170/1170 | `gates/leak.log` |
| Explicit equality runtime, `--leak-check` | 9/9 | `final-explicit-equality-runtime.log` |
| Serial generated-C audit | 228/228 | `final-codegen-audit.log` |

Actual selected command:
`BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --changed --base 86432d73db3dc0904ff0061a2a71e023306dc212`.
It selects 18 suites plus body metrics; its successful internal logs are deleted
by the maintained script, so its full stdout is retained. Broad command:
`scripts/test --serial --no-build --log-dir /tmp/blorp-scoped-traits.lb0ugU/gates compiler-blorp compiler-tools leak`.
Warmup succeeded before these gates. Audit command:
`blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh bin/blorp --jobs 1`.

The final formatting-only conjunction change produced an identical native
executable, binding CLI behavior gates to the final executable. Raw CLI C is
**not** identical: pre-format SHA256
`1c375698ac18bb32c37cba1ad0729285fdc392588442ac29fc6f0dfabf9d4e9a`,
post-format `7e8072f06271ce0e39f6e171d8f830f05fe89187bf222579e5309074783db9c7`.
The first differences are renumbered emitted local identifiers; the entire
unnormalized difference is retained as `final-format-cli.diff`. Final focused
519/519 and actual selected688/688 recompile the final source subjects; broad
source-import results are not represented as rerun after that formatting edit.

## Output oracle and limits

The same standalone `inherited_builtin_control.brp` path was compiled by retained
d390-source host SHA256
`3c180d29e0d8e8d14f9acd24c118e8f04491f5ca25e05870e4bb1225a6845ea3`
and the candidate. That retained host is not FRESH relative to the current root
checkout. Input SHA256:
`ca43268ea9f7ce4b52bd94cde5f4aed1628ddbe51e791df3f75a86e01dd48992`.
Raw final Core and C are byte-identical, without normalization:
Core `5620fc15fa40f6f58b9a267e5722d7537e6a74dc4ea54e894009689277b5a3a5`,
C `31d32a7b6458c024cf0ab142dd133eafabc6c3d9c67bb946372f96a4c822f8de`.
Both earlier runs returned the intended7 and reported zero tracked leaks.

This fixture auto-loads canonical prelude source, proving visible inherited
behavior/Core/C stability, not the graph-to-absent-compiler-source topology.
That reverse inheritance identity closure remains deferred: unchanged
`table_trait_methods_seen` traverses graph-only `table_find_trait_index` and skips
an absent builtin supertrait. Compiler-to-linked-source inheritance is covered;
no universal inheritance claim is made.

No default callable publication, concrete inner-call binding, generic selection
redesign, automatic union Eq, alias registration, Hash/native migration,
stage2/fixpoint, or performance result is claimed. Intrinsic equality remains
unsupported in this unresolved default-body CTFE call path; primitive equality
generally works. This metadata improvement is not genuine default-body folding.
Per-test leak PASS establishes zero tracked live objects for exercised tests;
the trailing process allocation count is not whole-fixture allocation cost.

Rejected authority candidates, malformed helper imports/private-Scope attempts,
and the ordinary-scalar UFCS route mismatch remain in the artifact root. They
are preparation/route failures, not passing tests. The first selected-gate run
executed zero suites because its benchmark consumer still used tuple seeds and
list equality; its expectation was migrated, not weakened. The three final
invalid-owner controls prove a viable fallback first, then exact one-error and
no-target behavior through FuncSymbol, absent-symbol, and trait-UFCS consumers.

## Independent acceptance

Production and the benchmark comparator received code-review approval.
The independent runner verified the eight-file manifest and FRESH O2 executable
before and after execution, repeated focused519/519 and runtime18/18 with leak
checking, and confirmed all three invalid consumers. Its same-path standalone
oracle reproduced raw Core/C identity, intended exit7, and zero tracked leaks.
The selected688 gate was independently verified from its retained artifact, not
rerun; broader gates remain the worker results above. These overlapping counts
must not be summed as distinct coverage.

Report: `/tmp/blorp-scoped-traits.lb0ugU/independent/REPORT.md`, SHA256
`295ae9d7ee7e5663183694008bf74e1a99ffdba5d13bfc56322d9d8188c802de`.
It verified the original evidence-note snapshot SHA256 `88c5a929c473cb45e84ebdc45adee8cd728956e1eb73e0bc2f78e89a8cdd0dc3`;
this subsequent documentation-only acceptance update does not alter source or
raw measurement artifacts. No CLI-C identity or deferred closure is claimed.

## Frozen SHA256 manifest

Paths relative to repository root:

```text
f395028465c0e47a9c0e6ec5ac6ac65849fab25eed4f6df137aafb67b4039024  blorp/src/compiler/stage_06_typecheck/state.brp
6ac46f7f85cf4ca102393888af04f8195ec6d2a45ad7390413a68364ea281486  blorp/src/compiler/stage_06_typecheck/infer.brp
7ea2dd8b896491d7ceb8bda1d3085003ad2a99283b0a313e1e7e08fed08ff53e  blorp/src/compiler/stage_06_typecheck/decl.brp
18373e08495c2fae26f088f68e7bcbf815fe3147ffedc482fc468ef1b76f2839  blorp/src/compiler/stage_06_typecheck/type_system/accepted_trait_implementation_authority.brp
19b09f856e067d7d32b478e9b0ddee6c03b9624b53e09dbbf6c75c4ee636fb8f  blorp/test/compiler/stage_06_typecheck/test_infer.brp
e770ab2c334525d96fd65f16c4503790bd9affbf86c926231e2d732d47667590  blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
20a35cbbdc6aa9bd0b49164b83ad3d7e395658dc05deeea0e82547e89f501fef  blorp/test/compiler/stage_06_typecheck/test_accepted_semantic_catalog.brp
2ef1e908a76a84ae2615c335c0e7b5e45c3d833483426353d5cdc6cec19a8954  blorp/benchmark/compiler/compiler_infer_session_reconstruction_profile.brp
```

All raw artifacts remain at the explicit scratch artifact root above. No commit,
merge, push, bootstrap pin, or production default-fact registration occurred.
