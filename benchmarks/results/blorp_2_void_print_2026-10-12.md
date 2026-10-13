# Blorp 2 Void, ordered statements and print

Step 4 of the [calculator roadmap](https://github.com/kablorp/blorp/blob/4b05ea3b431d9fbe4e906a0802bd41060b6f397f/blorp_2/CALCULATOR_PLAN.md) is complete.
The [design](https://github.com/kablorp/blorp/blob/4b05ea3b431d9fbe4e906a0802bd41060b6f397f/blorp_2/VOID_PRINT_PLAN.md) owns the bounded semantics and
predeclared acceptance criteria. The normal
[Hello World fixture](../../blorp_2/test/e2e/fixtures/effects/hello.brp) imports
`io.print`, produces exactly `Hello, World!\n`, and exits zero.

## Behavior and phase contracts

The input prelude owns the new builtin Void type. Its single value, `void`, has
an explicit literal variant and remains unmanaged through every phase. C uses
a canonical zero `uint8_t` carrier uniformly in parameters, locals, generic
payloads and returns. This is an internal unit representation, not another
surface numeric type.

One ordered statement list replaces the former binding/assignment prefix in
parsed, checked and concrete functions and arms. Binding inventories still own
BindingId/type/scope facts. A discarded expression introduces no binding and
must return Void. Lowering retains all its normal value definitions and ignores
only the returned reference. Call discovery, generic specialization, tail-call
checking and intermediate-type visitors consume the same statement sequence.
No additional pass, cache or effect framework is introduced.

The temporary target library contains concrete `print(String) -> Void`, adapted
from io with recorded upstream provenance. The closed StringPrint contract owns
its impure status and signature. Its runtime borrows the String, writes its
explicit bytes with fwrite, appends LF and returns canonical unit. Ownership
drops a temporary only after the call. Emission includes the print fragment
only when its typed operation is used; prior programs retain identical C.

Pure callers are rejected, including UFCS and impure wrappers. A final expression
remains mandatory; main still takes no arguments and returns Int. Existing
record-field, direct union-payload, managed-prefix-before-match and annotated
tail-loop restrictions remain. Selected match arms may print. Input, conversion
and Float remain later increments.

## Tests and review

Three public compile/check callbacks fail behaviorally before implementation,
and the baseline compiler rejects the normal Hello fixture without emitting C.
Receipts: `blorp_2/build/effects/tdd-public-red/` and `tdd-native-red/`.
Host syntax/type iteration failures are retained separately.

Granular tests cover syntax, typed checking and diagnostics, specialization,
ordered lowering, ownership analyses/insertion, independent verification and
emission. New phase and ownership suites contain 23 and 11 callbacks. They
observe complete phase facts, generic Void values/payloads, discarded-only
calls, preserved tail restrictions, purity, exact error text/help/spans, and
malformed ownership IR. The verifier rejects owned/borrowed/wrongly typed unit
values and invalid print argument/result contracts. Three new native runtime
cases check borrowed reference counts, exact empty/UTF-8/NUL output and canonical
unit, bringing that suite to 25 cases.

The independent runner deliberately omitted DiscardExpression lowering. Seven
of eight native callbacks failed after successful strict C linking; the empty
output unit case passed. These are native result mismatches, not compiler or
warning failures. The harness combines status/stdout/stderr in one diagnostic,
so the mutation logs do not isolate stdout as the sole differing observation.
Byte-identical restoration passed 8/8. Restored lower.brp SHA256:
`465d401ac6b1508a7234f6ce0275f893a67f5f4a81f07e062a6dc1059636a3e8`.
Packets under `build/effects/independent-tests/`: `discard-mutation/` and
`restored-focused/`.

| Independent gate | Result | Time |
| --- | --- | ---: |
| Strict unit/runtime/grammar/tooling | 1,254 Blorp callbacks + 25 nested native C cases passed | 16.723 s |
| Final full e2e | 191 cases + orchestration callback passed | 92.887 s |

Strict validation uses ASan, UBSan and strict leak checking. Its runner reports
three allocations, three releases and zero leaked objects/bytes. All native
fixtures use unmodified generated C, strict C11, default structural limits and
`-O0` with ASan/UBSan. There are no sanitizer findings; final e2e stderr is empty.
Each e2e run builds the pilot once and compiles each fixture once.

The first full e2e gate exposed four allocation ceilings and one stale parser
diagnostic expectation. Native behavior, C identity and instruction bounds
already passed. The bounded test-only corrections were:

| Fixture | Observed allocations | Old ceiling | New ceiling |
| --- | ---: | ---: | ---: |
| call/one | 1,150 | 1,100 | 1,300 |
| pure/calls | 1,431 | 1,400 | 1,600 |
| nested/order | 1,732 | 1,700 | 2,000 |
| ufcs/chain | 1,726 | 1,700 | 2,000 |

Their 40M instruction ceilings remain unchanged. The second-expression case now
expects `expression statement must return Void` at its first expression's byte
span 20:21. Exact teaching help is pinned by the public contract suite. The
17 affected callbacks passed a focused rerun, then the full e2e gate passed.
The original red packet remains at `independent-tests/full-e2e/`; final packets
are `full-strict/` and `full-e2e-final/`.

Strict validation and mutation restoration record fingerprint
`4934473a037cfc5b6f9031cd598327cda84c8cc416013061a6d5ae8b2b7ad2b6`.
Only the five e2e expectation files changed before the final e2e, cost and C
inspection packets, whose unchanged fingerprint is
`696b05f1e621106eb0332671a27d780a637922a0924c871b5f73c73b426953e4`.
Production sources are identical across these gates. Subsequent tracked changes
complete only report/README/roadmap/design-status prose.

Commands:

```sh
scripts/record-validation --output blorp_2/build/effects/independent-tests/full-strict -- \
  bin/blorp test --suite --timeout 180 --sanitize --leak-check \
  blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar blorp_2/test/tooling
scripts/record-validation --output blorp_2/build/effects/independent-tests/full-e2e-final -- \
  bin/blorp test --suite --timeout 0 blorp_2/test/e2e
```

Independent compiler-expert code/test/document and test-runner reviews approve
the increment with no remaining findings. The reviewer separately reproduced
all paired counters, C comparisons and frozen-input hashes.

## Generated C and native bytes

Retained inspection under `build/effects/native-inspect/` covers Hello, bytes,
mutation order and the 64-print sequence. All four normal-main programs compile
and execute with exact stdout and empty stderr. The bytes case produces
`0a c3 a9 f0 9f 98 80 00 31 32 33 0a`: empty print, UTF-8 é and supplementary
emoji, NUL immediately followed by digits, then LF.

The sequence has 64 io.print wrapper calls, 64 String constructors/releases and
maximum C brace depth two. Print's uint8_t result has no ownership obligation;
the literal owner is released after the borrowed call. There is no accumulating
C nesting or output-formatting requirement. Receipt: `inspect-c-final/`.
The first inspection probe incorrectly expected 64 direct runtime calls; there
is one runtime call in the wrapper and 64 calls to that wrapper. `inspect-c/`
retains this failed probe; the corrected assertion passes without production
changes or generated-C edits.

Ordinary new fixtures observed at most 6,153 allocations / 45.4M instructions,
bounded by 15,000 / 100M. The final sequence run observed 20,073 / 87.4M, bounded by
100,000 / 400M. These development ceilings deliberately leave headroom and are
separate from the matched aggregate guard.

## Matched costs and provenance

The frozen baseline is the independently accepted, uncommitted String increment
on HEAD `2f5795cc7`, not HEAD alone. Source, library, tests, EBNF, compiler and
compiler C are retained under `build/effects/baseline/`. Three serial paired
samples alternate compiler order over 162 frozen prior executable roots.
Both receive the same frozen program/library sources, but use their respective
preludes: the new mandatory Void declaration is an explicit input difference.

The boundary is the entire pilot process through C emission, excluding pilot
builds, native C compilation and program execution. This is an owned-input
proxy, not self-compilation. Allocations and retired instructions each have a
predeclared +10% aggregate ceiling.

| Sum over 486 compilations per compiler | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 2,158,107 | 2,186,643 | +1.32% |
| Retired instructions | 20,209,097,766 | 20,284,249,973 | +0.37% |

Both bounds pass. Instruction cost is effectively flat; this is no speedup
claim. Every process reports balanced allocations/releases and zero leaked
objects/bytes. All 486 complete generated-C pairs are byte-identical.
Receipt: `build/effects/matched-costs/`; raw pairs/counters: `samples/`,
`costs.tsv` and `projection.tsv`. The retained `measure.sh` reruns this boundary.

| Artifact | SHA256 |
| --- | --- |
| Baseline inputs.tar | `9d68da14f0ea46c755e4c098c568f4cba16e99fba4df6194a6d2ba408c8d85a0` |
| Baseline compiler | `a1461b477789ff91be791cc83829890d99e7ed61800832fa0f456d6bff852bc6` |
| Baseline compiler.c | `51456b5f0a9a4a01408186cfd3f7ef603ed67ebe6b10f629d17fb6d0cef4a68e` |
| Candidate inputs.tar | `6d797347ebcd34ca4f84771ae3381c90e3739a81e0ece9c8ee901e91e4f95c40` |
| Measured candidate compiler | `fbd46fff587941d4a191a5aa57325d1c02eeb64e39211899e429c9c4c2a4e091` |
| Candidate compiler.c | `a2b43ce6ce048eae64aacee817a27951ec54cffcbfa0dc74f68fc9517705cb89` |
| Final e2e compiler | `0e1ba57649bfca7f7625062378dc6e82ffb106ac3d710b47b7f3533e276aa92b` |

Candidate inputs, library, tests and grammar match their frozen copies exactly.
The measured binary comes from the focused e2e build. The final full-e2e build
has a different binary hash and byte-identical compiler C; no binary identity
claim is made. Its copies are retained at `independent-tests/final-build/`.
The host is FRESH with SHA256
`4dd4a29a428d7fa8ecd40068f043d8a7ee910df0c6272ba3062c97dfebf938ec`.
Toolchain: Apple Clang 21.0.0 on arm64 macOS. Pilot and fixture builds use `-O0`;
the existing host CLI/runtime use `-O0`/`-O2`.

Relative to the frozen String increment, handwritten production changes are
**727 added / 234 deleted = +493 lines**, including the 81-line io adaptation
and its commented upstream source/provenance, within the 700-line target.
Tests are **1,674 added / 127 deleted = +1,547 lines**. Formal EBNF is
28 added / 18 deleted; documentation, generated C and ignored evidence are
separate. The earlier measured concat growth remains a separate follow-up.
