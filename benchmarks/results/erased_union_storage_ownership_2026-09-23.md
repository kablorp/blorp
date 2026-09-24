# Erased storage ownership correctness checkpoint

This change makes CorePrepare's erased-union payload boxing, union cleanup
plans, and emitted channel element-release callbacks use the shared
`CoreSpecializeLayout.boxed_storage_slot_needs_release` policy. Source-level
release policies and typed-union boxing remain unchanged. The erased-union
constructor path also asks the shared layout for the actual boxed payload
value, so Int128/UInt128 store allocated boxes rather than integer bit
patterns. No tuple, dictionary, or Option boxing path was changed.

## Build and focused checks

Build command: `BLORP_CLI_C_OPTIMIZATION=-O2 make`. The build completed on
2026-09-23 and `scripts/compiler-build-status` reported `FRESH`. The compiler
reported Blorp 0.0.1, target `aarch64-apple-darwin`, CLI/runtime optimization
`-O2`, 8-way split, and Apple clang 21.0.0. The built `bin/blorp` SHA-256 was
`fab71b37a1c6d7f4314755d8ab84a544eb54da5396e618bd89dca7468614be61`.

Focused compiler suites passed:

| Command target | Result |
| --- | ---: |
| `blorp/test/compiler/stage_09_core/test_core_specialize_layout.brp` | 9/9 |
| `blorp/test/compiler/stage_09_core/test_core_prepare.brp` | 50/50 |
| `blorp/test/compiler/stage_10_backend/test_core_emit.brp` | 330/330 |

The exact compiler-suite command form was `bin/blorp test --timeout 180
<target>`. Each runtime target below was run with both
`bin/blorp test --leak-check --timeout 180 <target>` and
`bin/blorp test --sanitize --timeout 180 <target>`.

Runtime ownership checks passed in both leak-check and sanitizer modes:

| Command target | Leak-check | Sanitizer |
| --- | ---: | ---: |
| `blorp/test/runtime/memory/test_erased_struct_channel_box_ownership.brp` | 4/4, 0 leaked | 4/4 |
| `blorp/test/runtime/memory/test_erased_union_struct_box_release.brp` | 1/1, 0 leaked | 1/1 |
| `blorp/test/runtime/memory/test_erased_union_wide_box_release.brp` | 1/1, 0 leaked | 1/1 |

The Point channel runtime tests cover `try_recv_attempt` and dropping a
buffered channel. Int128 and UInt128 cover receive and buffered-drop paths.
The Point|String erased-union codegen fixture is a pre-S2 checkpoint and must
be migrated if S2 admits that union as typed storage.

## Generated C evidence

The retained codegen fixture is
`blorp/test/compiler/pipeline/codegen_audit/should_pass/erased_union_wide_payload_ownership.brp`.
The no-runtime command was:

```sh
bin/blorp compile --no-format --no-embed-runtime \
  -o /tmp/blorp-s0-erased-storage.HJ4t9n/wide.c \
  blorp/test/compiler/pipeline/codegen_audit/should_pass/erased_union_wide_payload_ownership.brp
```

The generated C SHA-256 is
`2bdd95913131608a48702dc1e00ce66e26b3a00f36f04e8f92bacd079b287e4c`.
Relevant output:

```c
if ((self->release_mask & 1UL) && self->data.SignedValue.field0) blorp_release(self->data.SignedValue.field0);
if ((self->release_mask & 1UL) && self->data.UnsignedValue.field0) blorp_release(self->data.UnsignedValue.field0);
WideBoxProbe* __borrow_arg_1_1_0 = __def_122_SignedValue(blorp_box_int128(42), 1UL);
WideBoxProbe* __borrow_arg_1_1_0 = __def_123_UnsignedValue(blorp_box_uint128(43), 1UL);
```

All six fixture `EXPECT-C-REGEX` assertions matched. The no-runtime C passed
the codegen audit's Clang syntax/warning flags with `runtime_decl.c` forced in.
Split output was also emitted with `--c-translation-units=2`; both constructor
calls and both destructor release-mask checks appeared in
`wide-split.1.c`. Artifact hashes:

| Artifact | SHA-256 |
| --- | --- |
| `/tmp/blorp-s0-erased-storage.HJ4t9n/wide-split.units` | `0da1216b2dc2f2726aeaf515744fdcd6e44a6e3b426b2ce66da86ff74e573b38` |
| `/tmp/blorp-s0-erased-storage.HJ4t9n/wide-split.0.c` | `89454f98e54c76e5620eb0941a71a1c480a7b539c6b3d0ad74642924cbc92613` |
| `/tmp/blorp-s0-erased-storage.HJ4t9n/wide-split.1.c` | `a45f3cdb8292edb2ed90c070d156b0bb57fa0e6b7711fff9a36721595f912ca2` |
| `/tmp/blorp-s0-erased-storage.HJ4t9n/wide-split.h` | `30b830d7a71dffee22f16cef3a4e45f53f67649037b2056a0842ec91fdf5b379` |

Before the erased-union argument classifier change, the same wide-payload
probe produced `__def_122_SignedValue((void*)42, 0UL)` and
`__def_123_UnsignedValue((void*)43, 0UL)`, while match code called
`blorp_unbox_int128` / `blorp_unbox_uint128` on those fields. The pre-change
Core C artifact SHA-256 was
`acedab213d3ed315923cd30a8cd0ae85ed5111c4a95ba40eaa505004815e8138`.
This is correctness evidence for a pre-existing wide-payload codegen defect,
not a performance claim.

## Bounded pre-existing blocker

The requested blocking `recv(Channel[Point])` runtime check cannot compile to
C on the exact parent/S1a integration build (`4fb3c86350756419aaf0ba680ebc2831e1000a16`,
fresh O2). It was reproduced with `bin/blorp test --leak-check --timeout
180 /Users/keithphilpott/.codex/worktrees/struct-payload-s0/blorp/blorp/test/runtime/memory/test_erased_struct_channel_box_ownership.brp`.
Its generated C initializes a stack Option from `blorp_channel_recv(ch)`,
whose runtime declaration returns `void*`:

```c
blorp_StackOption__Users_keithphilpott__codex_worktrees_struct_payload_s0_blorp_blorp_test_runtime_memory_test_erased_struct_channel_box_ownership__ChannelBoxPoint __blorp_internal_match_scrut_127_1_1_1_1_3 = blorp_channel_recv(ch);
```

Clang reports: `initializing 'blorp_StackOption_...ChannelBoxPoint' with an
expression of incompatible type 'void *'`. This is outside the
storage-ownership patch and was removed from its fixture after reproducing on
the parent build. Keep it as a separate follow-up; it is not counted as a
passing receive test.

## Performance accounting

Independent source review found no P1/P2 issues and one P3 cost caveat: this
change builds `CoreSpecializeLayout` once in each of `prepare_program`,
`build_cleanup_plan`, and `emit_decls`. Each build is per program/emit artifact,
not per field or call, but it adds three type/declaration-index scans across
the full path.

Same-input stage-2 measurement used the corrected parent O2 baseline and the
same frozen d5 input directory. Command:

```sh
BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --stage2 \
  --input-dir /private/var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/blorp-perf-input/d5fe8d9d8288165e6dbe55868c11e060d62b6db4 \
  --program self --samples 3 \
  --baseline /tmp/blorp-struct-payload-parent-stage2-O2.json \
  --output /tmp/blorp-struct-payload-s0-stage2-O2.json \
  --keep-output /tmp/blorp-struct-payload-s0-stage2-O2.c
```

No `--require-identical` was used: the correctness change intentionally
changes generated code for erased struct payloads. Both builds used Apple
clang 21.0.0 and CLI/runtime `-O2`; input revision was
`d5fe8d9d8288165e6dbe55868c11e060d62b6db4`. Parent stage-2 compiler SHA-256
was `2e8dae47f697aca6833ade63566145deea9756afbf4ad3f3edf46fd469cb03a2`; the
candidate stage-2 compiler SHA-256 was
`f4a6e7120b615a6409b369e2ba0cd7a85c0384383aae24273d1860a0c4b797e0`, built
from the fresh candidate `bin/blorp` SHA recorded above.

| Counter | Parent | Candidate | Delta |
| --- | ---: | ---: | ---: |
| Total allocations | 235,758,670 | 235,875,436 | +116,766 (+0.05%) |
| `pass_prepare_complete` allocations | 945,725 | 966,653 | +20,928 (+2.21%) |
| `cleanup_plan_complete` allocations | 1,064,167 | 1,066,898 | +2,731 (+0.26%) |
| `backend_emission_complete` allocations | 20,304,315 | 20,397,422 | +93,107 (+0.46%) |
| Retired instructions, 3-sample min | 185,586,923,044 | 184,994,205,635 | -592,717,409 (-0.32%) |
| Retired instructions, 3-sample median | 185,997,911,859 | 185,016,177,916 | -981,733,943 (-0.53%) |

Retired-instruction sample spread was 4,785,505,278 for the parent and
38,919,692 for the candidate (max minus min). The measurement helper does not
record retired instructions per phase, so phase attribution is available only
for allocations. The phase deltas include the layout builds and the changed
prepared/emitted products; they do not isolate allocation of the layout
indexes alone. The three index builds and their aggregate phase costs are
therefore stated explicitly, with no speedup claim. The helper's `lock`
subcommand is a no-op, so unrelated host work cannot be excluded; the wide
parent instruction spread is a concrete noise caveat.

Candidate C was 164,008,648 bytes with SHA-256
`97f5ac343ab81b0d60994c62f59e36d49a7530399dc961a1acea6a0f4fa3afe2`; parent
C was 164,003,569 bytes with SHA-256
`610fccb41236b5fb08a1645d23858c0eed47fde7dd8144563d51a33bc72341fa`.
The bounded diff had 31 hunks and was coherent with the fix: it adds release
masks/destructors to two erased unions containing boxed value structs
(`CliTestCandidateProgress` and `AcceptedVisibleTraitBinding`), boxes their
struct payloads at constructor sites with bits `1UL` and `2UL`, and adds the
corresponding missing release-bit branches to four other union variants. No
unrelated or wide-integer C changes appeared in this frozen self-compile diff.
