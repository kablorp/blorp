# Blorp 2 integer-facing String APIs, 2026-10-16

`string.byte_at(String, Int) -> Option[Int]` and
`string.from_codepoint(Int) -> Option[String]` are implemented in the target
compiler and temporary library. Byte access borrows unsigned counted bytes;
scalar encoding validates Int64 before narrowing and transfers one fresh String
into ordinary owning Some. Source Char/classification migration remains pending.

**Reviewed acceptance.** All correctness gates and pre-set hard cost ceilings pass.
**105 of 452 unchanged
inputs miss the +5% allocation target**, maximum **+5.6215%**; none breach +10%.
All normal instruction comparisons meet +5%, maximum **+4.1858%**. Implementation,
cost and documentation reviews are complete. The
[approved plan](../../blorp_2/STRING_INTEGER_APIS_PLAN.md) owns scope and ceilings.

## Frozen versions and measurement boundary

Baseline source and its unmodified target library are from
`545a6a07d32fb4c713442e441ddc8d93cd544756`; candidate source/library are from
`f64caa19bdbd2db6063b801870039ecaddf11dde`, merging checkpoint `260f1f098`.
No new builtin declarations were passed to the baseline or removed/adapted.
Production patch SHA256 is
`cb7dfdde88049a7243fb7916cd1d03c6c66b9ca9083d231ee18e027c555961e6`.

| Version | Compiler source Git tree | Target library Git tree |
| --- | --- | --- |
| B | 87da0fb3655f12fdc3f18a71c8b077ea8d35a673 | 04e10029e8fe29225f3ca953a5960d5f74bc427c |
| C | 8a45f02fdf5c9d1bf5e8634426817c9df664568c | 0ff2221cf9d9452af4bc7b152071ef368d9564a6 |

Both exact archived snapshots contain the same 46-file inventory. Their common
`_base.brp` SHA256 is
`878b363f3249aaf0389daff524ab6f6f167a66a2b56d88eb64cf1c983a8aff78`;
prelude SHA256 is
`e653c5007b45c5ec8ba3fba8b9e51caa1825638af80497d05bf03e06f0a9d7b7`.

Use the existing frozen pair in the `host-utf8-file-admission/blorp` worktree:

| Host artifact | SHA256 |
| --- | --- |
| bin/blorp-stage2, normal O2/diagnostics0 | 34ac1a913c79fc14130c77fe4339f24885a2fa65f1d25fc4b873b627e10e1f33 |
| bin/blorp-stage2-diagnostic, O2/diagnostics1 | be31a5a3a070deef54707d8676a7c6157042484f40d0424dd5fb46835c09ff93 |

Both select that worktree's absolute `standard_library/src` explicitly. Its tree
is `090ed68c5bd688cb8e2197c72bc572e4dc32e6d7`; host source tree is
`33d50604c606ce0eaaa7dddd6f11783e8b66eed2`. All 595 tracked host source/library
files match baseline blobs. Actual bytes and file inventory are frozen too.
The one extra existing generated `embedded_std.brp` is separately recorded as
`bfebe3791098cc1fc705cccc86a6d97acfb550cd438f5de49acd571f39cf0f7a`.
Historical 90734-dirty host labels remain intact; no frozen host was rebuilt,
copied or retagged FRESH. Platform is Darwin arm64, Apple Clang 21.0.0.

Two setup emits use one canonical physical source/main/output path and the frozen
normal host; snapshot materialization and verification stay outside measurement:

```sh
env -u BLORP_CC -u BLORP_LEAK_CHECK -u BLORP_MEMORY_STATS   "$HOST" compile --std-dir "$HOST_STD" --no-format blorp_2/src/main.brp -o "$OUTPUT"
/usr/bin/clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=0 "$C" -o "$NORMAL" -lm -lpthread
/usr/bin/clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1 "$C" -o "$DIAGNOSTIC" -lm -lpthread
```

All two emits/four links succeeded, each link retaining 84 host-generated C
warnings. Per-version C and separate pilot binary hashes are in
`baseline/artifacts.sha256` and `candidate/artifacts.sha256` in the raw packet.
Normal pilot hashes: B
`582bf8837a876d2a61d7bc599984d44d4452a16420374beb0d37abd1797bf49c`, C
`006f37d6dcfaa84352fb73cb07f061a5f11e3ecb8ce390962985c1c0158019f2`.
Diagnostic hashes: B
`40f9275ced9a0083b1da5e53e7bf3809578e0fdbeeb04d3f75a2b95deaf8b891`, C
`445d54a26a775523ef5d4178e9c4eeae20ab07473fc9be3b2aabf76441be9885`.

The 452 distinct accepted cost-program paths were counted independently and
matched to baseline fixture files, not inferred from registered e2e cases.
Their sorted path SHA256 is
`16bfe8dcbdfce1e2ab971f18f6119ae04981e3af7360d078e47b9b1490fbc305`.
Every unchanged fixture byte matches baseline. Each variant uses its own exact
target library; both receive identical fixture files at common physical paths.

Strict calls use diagnostic pilots and `BLORP_LEAK_CHECK=strict`, memory stats
unset. All have positive equal allocations/releases, zero leaked objects/bytes.
Normal calls use diagnostics0, all three BLORP memory/CC variables unset outside
`/usr/bin/time -l`; three samples alternate B/C, C/B, B/C. Report min3 retired
instructions per input. Strict instruction counts are supporting data only.
No sample was excluded, repeated, filtered or normalized. Every status, stream,
diagnostic and own-version raw C oracle is checked; unexpected differences stop.

Exactly **904 strict + 2712 normal + 16 new + 8 host = 3640 measured CLI calls**
completed. The two setup host emits and four links are separate. Start/end
provenance checks pass (50 packet entries, 1196 frozen entries); tracked source,
index, status, host bytes, tools and snapshots remained frozen during collection.

## Correctness, mutations and C

Two pre-implementation callback reds rejected the new labels with `unknown
builtin operation`, exact help and spans 75..91 / 60..83. Restored focused tests
pass 115/115; native String cases pass 39/39 under strict C11 flags and ASan/UBSan.
Six independent faults were killed: signed byte, upper bound, premature narrowing,
missing surrogate guard, zero-payload absence and premature owning scratch release.
The last caused the ordinary encoder-main ASan use-after-free; restoration passes.

The merged ordinary-host broad command was:

```sh
BLORP_CC=/usr/bin/clang BLORP_2_INSTRUCTION_CHECK=required make -C blorp_2 test
```

It passes **2569 unit + 215 runtime (nested callbacks included) + 179 grammar
checks**, plus **456 registered e2e cases**. The first attempt exposed three stale
negative-test expected-help assertions; one shared constant now includes both
labels, preserving all three cases. Focused grammar passes 75/75 and the rerun
passes all three. This correction does not alter production or measured trees.

Among the unchanged cost inputs, **356 accept and 96 reject**, preserving exact
status and diagnostics across versions. All normal repetitions match their own
complete raw C oracle. Of 356 accepted programs, **151 C files are byte-identical**;
**205 equal baseline plus exactly the reviewed 1388-byte/25-line helper insertion**,
with no other changed byte. `c-diff-audit.tsv` checks every complete file;
`reviewed-runtime-addition.c.txt` has SHA256
`ad6fe64bba72e340d0f055cbf939864e73ea567b0af5f77b4ccd25b768629f7b`.
All raw C and diffs remain retained.

The host source-to-C diff is also retained in full (111768 lines/2683 hunks),
including widespread generated identifier/enum/static-literal renumbering and
the feature additions. No cross-version host C identity is claimed. Every one
of the six normal/two diagnostic host outputs matches its own setup C exactly.

## Cost results and all target misses

Targets are +5%, hard limits +10%, separately for each unchanged input and host
proxy. Existing stricter fixture caps are unchanged. Highest unchanged-input
allocation ratio is `c0023`, 7418 -> 7835 (+417, **+5.6215%**). Highest normal
instruction ratio is `c0157`, 46597022 -> 48547464 (**+4.1858%**).

The candidate's two ordinary library declarations add fixed input work to each
compile. Observed total differences include exactly +417 allocations on 22 inputs
and +469 on 166 inputs. These are whole-compilation observations; no phase
counters attribute those allocations specifically to parsing, checking or a
particular pass. Measure the owning phase before proposing an optimization.

| Host source-to-C proxy | B | C | Change |
| --- | ---: | ---: | ---: |
| artifact_construction_complete cumulative allocations | 23119520 | 23228802 | +0.4727% |
| normal min3 retired instructions | 20543677195 | 20649221697 | +0.5138% |

This is owned-input compilation plus a host construction proxy, **not target
self-compilation**. The diagnostic checkpoint is cumulative construction work,
not a claim of full-process strict leak balance. It uses the frozen diagnostic
host with `BLORP_MEMORY_STATS=1`, leak mode unset, exactly one positive artifact
checkpoint. All other instruction budgets use normal samples.

Four candidate-only fixtures pass one strict and three normal samples each:

| Fixture | Allocations / cap | Normal min3 instructions / cap | Native exit/stdout |
| --- | ---: | ---: | --- |
| byte_at | 10360 / 205000 | 37162674 / 600000000 | 169 / empty |
| byte_at_zero | 10361 / 205000 | 37203989 / 600000000 | 0 / empty |
| from_codepoint_nul | 11192 / 250000 | 38566223 / 800000000 | 0 / bytes 00 0A |
| from_codepoint_ownership | 11470 / 250000 | 38696714 / 800000000 | 2 / empty |

Native outcomes are the independently validated ordinary-main fixtures and broad
e2e cases; the comparative calls measure their compiler costs. No new success
is compared to an old unsupported rejection.

All **105** +5% allocation-target misses follow; every one passes the +10% hard
limit. Paths are relative to `blorp_2/test/e2e/fixtures/`. There are no instruction
or host-proxy target misses. Ratios below are display-rounded; decisions use exact
integer comparisons. Complete per-input samples remain in the raw packet.

| ID | Input | B allocations | C allocations | Increase |
| --- | --- | ---: | ---: | ---: |
| c0005 | binding/capture_shadow.brp | 10248 | 10786 | 5.2498% |
| c0007 | binding/parameter_shadow.brp | 9291 | 9760 | 5.0479% |
| c0009 | binding/self_assignment.brp | 8999 | 9468 | 5.2117% |
| c0011 | binding/union_original.brp | 10426 | 10964 | 5.1602% |
| c0019 | call/one.brp | 8794 | 9263 | 5.3332% |
| c0021 | constant/called.brp | 7835 | 8255 | 5.3606% |
| c0023 | constant/imported/m.brp | 7418 | 7835 | 5.6215% |
| c0024 | constant/imported/main.brp | 8707 | 9176 | 5.3865% |
| c0025 | constant/integer.brp | 8547 | 9016 | 5.4873% |
| c0026 | constant/nonclosed.brp | 6703 | 7042 | 5.0574% |
| c0028 | constant/seven.brp | 8545 | 9014 | 5.4886% |
| c0042 | generic/arguments.brp | 9242 | 9711 | 5.0747% |
| c0045 | generic/arguments_later.brp | 9244 | 9713 | 5.0736% |
| c0093 | generic/union_parameters/third.brp | 10537 | 11075 | 5.1058% |
| c0095 | import/basic/helper.brp | 7483 | 7900 | 5.5726% |
| c0096 | import/basic/main.brp | 8969 | 9438 | 5.2291% |
| c0097 | import/cycle/helper.brp | 6304 | 6627 | 5.1237% |
| c0098 | import/cycle/main.brp | 6302 | 6625 | 5.1254% |
| c0099 | import/diamond/left.brp | 7897 | 8314 | 5.2805% |
| c0101 | import/diamond/right.brp | 7898 | 8315 | 5.2798% |
| c0102 | import/diamond/shared.brp | 7527 | 7944 | 5.5401% |
| c0104 | import/forwarding/box.brp | 7526 | 7943 | 5.5408% |
| c0107 | import/forwarding/ops.brp | 8079 | 8496 | 5.1615% |
| c0108 | import/generic_methods/box.brp | 7526 | 7943 | 5.5408% |
| c0111 | import/home/helper.brp | 7649 | 8066 | 5.4517% |
| c0113 | import/managed/generic.brp | 7547 | 7964 | 5.5254% |
| c0115 | import/managed/value.brp | 8202 | 8619 | 5.0841% |
| c0117 | import/method_modules/double.brp | 7905 | 8322 | 5.2751% |
| c0118 | import/method_modules/foo.brp | 7455 | 7872 | 5.5936% |
| c0119 | import/method_modules/increment.brp | 7928 | 8345 | 5.2598% |
| c0122 | import/prelude_helper/direct_rejected.brp | 7778 | 8198 | 5.3998% |
| c0123 | import/prelude_helper/helper.brp | 7560 | 7977 | 5.5159% |
| c0125 | import/receiver_types/decimal.brp | 7604 | 8021 | 5.4840% |
| c0126 | import/receiver_types/integer.brp | 7529 | 7946 | 5.5386% |
| c0128 | int/add.brp | 9124 | 9593 | 5.1403% |
| c0129 | int/cancel.brp | 9124 | 9593 | 5.1403% |
| c0133 | int/ufcs.brp | 9127 | 9596 | 5.1386% |
| c0137 | integer/maximum.brp | 8836 | 9305 | 5.3078% |
| c0138 | integer/minimum.brp | 8834 | 9303 | 5.3090% |
| c0156 | list/literal_empty_untyped.brp | 7763 | 8183 | 5.4103% |
| c0159 | list/literal_mixed.brp | 7877 | 8297 | 5.3320% |
| c0171 | main/int_arguments.brp | 9290 | 9759 | 5.0484% |
| c0172 | main/int_nullary.brp | 8464 | 8933 | 5.5411% |
| c0173 | main/pure_int_arguments.brp | 9295 | 9764 | 5.0457% |
| c0174 | main/pure_int_nullary.brp | 8469 | 8938 | 5.5378% |
| c0179 | match/binding_original.brp | 10725 | 11263 | 5.0163% |
| c0180 | match/binding_outer.brp | 10457 | 10996 | 5.1544% |
| c0198 | mortal_string/basic.brp | 9393 | 9863 | 5.0037% |
| c0200 | mortal_string/maximum.brp | 9319 | 9789 | 5.0435% |
| c0201 | mortal_string/minimum.brp | 9317 | 9787 | 5.0445% |
| c0202 | mortal_string/unused.brp | 9016 | 9486 | 5.2130% |
| c0205 | names/duplicate_var.brp | 7930 | 8350 | 5.2963% |
| c0206 | names/function_local.brp | 8113 | 8533 | 5.1769% |
| c0207 | names/function_parameter.brp | 8063 | 8483 | 5.2090% |
| c0208 | names/parameter_shadow.brp | 7980 | 8400 | 5.2632% |
| c0209 | names/typo.brp | 8264 | 8684 | 5.0823% |
| c0212 | names/unimported/shapes.brp | 7498 | 7915 | 5.5615% |
| c0221 | namespace/declared_function_imported_type/ops.brp | 7976 | 8393 | 5.2282% |
| c0222 | namespace/declared_function_imported_type/types.brp | 7455 | 7872 | 5.5936% |
| c0237 | nested/calls.brp | 9300 | 9769 | 5.0430% |
| c0266 | private_type/record_field.brp | 6733 | 7072 | 5.0349% |
| c0268 | private_type/union_payload.brp | 6764 | 7103 | 5.0118% |
| c0269 | pure/calls.brp | 9128 | 9597 | 5.1380% |
| c0277 | record/generic/admission/unused_list_int.brp | 8833 | 9302 | 5.3096% |
| c0316 | record/recursive_direct.brp | 8561 | 9030 | 5.4783% |
| c0317 | record/recursive_mutual.brp | 8847 | 9316 | 5.3012% |
| c0318 | record/recursive_union.brp | 8964 | 9433 | 5.2320% |
| c0349 | recursive/list_payload.brp | 8651 | 9120 | 5.4213% |
| c0355 | return/42.brp | 8467 | 8936 | 5.5392% |
| c0356 | return/zero.brp | 8464 | 8933 | 5.5411% |
| c0357 | string_literal/basic.brp | 8911 | 9381 | 5.2744% |
| c0358 | string_literal/comment_text.brp | 8914 | 9384 | 5.2726% |
| c0360 | string_literal/empty.brp | 8902 | 9372 | 5.2797% |
| c0361 | string_literal/escapes.brp | 8952 | 9422 | 5.2502% |
| c0364 | string_literal/long_unreached.brp | 8734 | 9203 | 5.3698% |
| c0367 | string_literal/nul_digits.brp | 8916 | 9386 | 5.2714% |
| c0369 | string_literal/trigraphs.brp | 8918 | 9388 | 5.2702% |
| c0370 | string_literal/unicode.brp | 8912 | 9382 | 5.2738% |
| c0371 | string_literal/unicode_escapes.brp | 8944 | 9414 | 5.2549% |
| c0373 | string_literal/unused.brp | 8966 | 9436 | 5.2420% |
| c0377 | syntax/next_line_value.brp | 8585 | 9054 | 5.4630% |
| c0379 | syntax/trivia.brp | 8468 | 8937 | 5.5385% |
| c0396 | ufcs/calls.brp | 9297 | 9766 | 5.0446% |
| c0421 | union/multiple/reject_constructor_arity.brp | 8099 | 8519 | 5.1858% |
| c0427 | unsupported/and_or.brp | 7866 | 8286 | 5.3394% |
| c0428 | unsupported/char_pattern.brp | 8275 | 8695 | 5.0755% |
| c0429 | unsupported/for.brp | 7895 | 8315 | 5.3198% |
| c0430 | unsupported/from_opaque.brp | 7823 | 8243 | 5.3688% |
| c0431 | unsupported/if.brp | 7882 | 8302 | 5.3286% |
| c0432 | unsupported/into_opaque.brp | 7823 | 8243 | 5.3688% |
| c0433 | unsupported/join_reassignment.brp | 8314 | 8734 | 5.0517% |
| c0434 | unsupported/lambda.brp | 7896 | 8316 | 5.3191% |
| c0435 | unsupported/list_pattern.brp | 8108 | 8528 | 5.1801% |
| c0436 | unsupported/local_annotation.brp | 7850 | 8270 | 5.3503% |
| c0437 | unsupported/match_in_expression.brp | 8270 | 8690 | 5.0786% |
| c0440 | unsupported/not.brp | 7826 | 8246 | 5.3667% |
| c0441 | unsupported/opaque_import/m.brp | 5878 | 6203 | 5.5291% |
| c0442 | unsupported/opaque_import/main.brp | 6103 | 6428 | 5.3252% |
| c0443 | unsupported/opaque_type.brp | 6053 | 6378 | 5.3692% |
| c0444 | unsupported/or_pattern.brp | 8338 | 8758 | 5.0372% |
| c0445 | unsupported/propagation.brp | 7857 | 8277 | 5.3456% |
| c0448 | unsupported/qualified_pattern.brp | 8315 | 8735 | 5.0511% |
| c0449 | unsupported/range.brp | 7817 | 8237 | 5.3729% |
| c0450 | unsupported/string_pattern.brp | 8131 | 8551 | 5.1654% |
| c0452 | unsupported/while.brp | 7940 | 8360 | 5.2897% |

## Scope, reviews and retained evidence

Production is **114 added / +111 net** lines against baseline; tests excluding
fixtures **554 added / +545 net**, including the one-line grammar expectation
correction. Four fixtures total **30 lines**. All are under the approved
260/+230, 700/+650 and 6/180 ceilings. The generic ownership/verifier path stays
unchanged; no requirement flags, allocator or helper framework were added.

Root and independent compiler review approved the implementation and mutation
closure; independent test-runner review approved broad counts and the full cost
receipt, recommending cost acceptance with all 105 target misses retained.
Root and independent performance review approve actual costs and documentation,
including all 105 retained target misses. Integration and remote publication are
separate coordinator actions.

Raw artifacts live under ignored `build/string-integer-api/`: focused/red/mutation
receipts and `merged-validation.md`; cost packet `cost-f64/` contains approved
READY/setup diff, exact archives/manifests, source/library/binary/tool hashes,
setup commands/exits, strict/normal/new/host command streams and per-call exits,
stdout/stderr/time/counters, complete raw C/diffs, minima/caps and all target
misses. The direct recipe hash is
`f52a63660135e28d75d6bffff9b85b2d4a9a67144d32ed913d027bb9d76b27e0`.
No generic measurement framework or mismatch override was introduced.
