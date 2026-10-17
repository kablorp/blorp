# Integer-facing String operations

**Status: reviewed acceptance.** Implemented in checkpoint `260f1f098`, merged
with published prerequisites at `f64caa19b`. Focused phase/native tests, six
mutation oracles, the full gate and
3,640 matched cost calls pass their hard ceilings. There are 105 allocation
misses of the +5% target (maximum +5.62%); normal instructions remain within +5%.
The [acceptance report](../benchmarks/results/blorp_2_string_integer_apis_2026-10-16.md)
records exact evidence and limits. Implementation, cost and documentation reviews
are complete; source Char/classification migration is separate and unimplemented.
The approved design below originated at `98f3472feaaf5183ef0fd5fdf3a24cda3fea5f91`.

## Problem and governing contract

[BOOTSTRAP_SOURCE_PLAN](BOOTSTRAP_SOURCE_PLAN.md#string-and-library-boundary),
[ROADMAP M6](ROADMAP.md#m6-library-and-shell) and
[LIBRARY_PARITY](LIBRARY_PARITY.md#planned-interface-delta) require two matching
host/target interfaces before source Char migration. The temporary String library
previously ended at [length](standard_library_temp/string.brp):17:

```blorp
pure func length(value: String) -> Int:
    builtin("string.length")
```

It now also exposes these ordinary target declarations:

```blorp
pure func byte_at(value: String, index: Int) -> Option[Int]:
    builtin("string.byte_at")

pure func from_codepoint(value: Int) -> Option[String]:
    builtin("string.from_codepoint")
```

All Strings contain valid UTF-8; lengths and indices count bytes. `byte_at`
returns an unsigned byte 0–255 or None outside bounds, including Int64 extremes.
It allocates nothing and never validates or constructs a substring.
`from_codepoint` rejects negatives, D800–DFFF and values above 10FFFF before
narrowing; every other scalar, including NUL and noncharacters, yields exact
UTF-8. No replacement or normalization. Host source wrappers may use Char
internally; target code requires no Char/Bytes representation.

## Producer-to-consumer design

| Fact and producer | Owner, lifetime and consumers |
| --- | --- |
| Parsed builtin variants in `src/utils/syntax.brp`; labels/help in `src/parse/parse.brp:2552–2600` | Parsed function body through checking; spelling recognition only here. |
| `StringByteAt(DesignatedOption)` / `StringFromCodepoint(DesignatedOption)` in `src/namespace/builtins.brp` | `runtime_contract:115` remains the sole signature authority: pure `[String, Int] -> OptionalResult(Int, option)` and pure `[Int] -> OptionalResult(String, option)`. Checker `src/check/signatures.brp:380–420` attaches foundation constructors and validates the declaration. |
| Concrete Option constructors in `src/specialize/specialize.brp:2032–2144` | Existing `translate_option` maps checked constructors to the result's concrete instance. Concrete calls retain them through lowering, ownership, verification and emission. Public TypeRef is unchanged. |
| Ownership and independent validation in `src/own/own.brp`, `src/verify/verify.brp:420–466` | Ordinary layout classification owns obligations. Input String is borrowed; successful encoding's fresh String transfers into Some and is released by ordinary union paths. No parallel signature/ownership authority. |
| Bytes and C lowering in `src/runtime/string.brp`, `src/emit/emit.brp:1022–1168` | Runtime helpers use existing counted String storage. Shared `append_optional_value` builds actual Some/None through `c_union_value`; native scratch has no separate escaping lifetime. |

Update exhaustive operation observers, builtin declaration help and runtime names.
Reuse generic lowering/ownership/verification; change their production logic only
if a concrete missing invariant is demonstrated and reviewed.

Use two small operation-specific emitters, each calling its helper once and then
`append_optional_value`. Do not adapt `append_parse_number` into an owning-pointer
adapter. Existing `ListGet[String]` Option ownership is the precedent.

## Native ABI and lifetime

Follow the existing parse/List-get status-plus-out-pointer ABI:

```c
uint8_t blorp_string_byte_at(
    const struct blorp_string *value, int64_t index, int64_t *result);
uint8_t blorp_string_from_codepoint(
    int64_t scalar, struct blorp_string **result);
```

Failure writes nothing and allocates nothing. Byte access checks signed full-width
bounds before indexing, then converts through `unsigned char` to Int64. Encoding
validates Int64 before conversion to uint32_t, encodes into a four-byte stack
buffer and invokes trusted `blorp_string_from_bytes:50` exactly once. Name scalar
limits/buffer capacity; document UTF-8 encoding constants locally. Success returns
one fresh String with reference count one, including scalar zero's one counted
NUL byte. Existing construction supplies the trailing terminator.

The emitter initializes scratch, saves status and selects Some/None by status,
never by payload zero. Some takes the fresh String obligation: no scratch release
or extra retain afterward. Copies, parent-to-child escape, ignored results and
final/nonfinal destruction use existing union/ARC behavior.

Put both helpers in existing `string_runtime()`: no new runtime-requirement flags,
allocator, validation pass or helper framework. Existing String C gains helper
definitions; preserve/review full raw diffs rather than claim old C identity.

## Reds, focused tests and mutations

Establish two separate executable callback reds before production: one expects
parsing/checking of `string.byte_at`; the other expects `string.from_codepoint`
returning the designated owning Option[String]. Existing APIs must suffice to
express the red without referring to nonexistent new enum constructors. Capture
actual rejection text/spans; no pre-execution red is claimed here.

Keep separate real-main fixtures: byte access of "é" at offset one returns 169;
encoding 233 returns a String through a Some-pattern parent and observes length 2,
with another successful encoder result ignored. The latter must exercise owning
cleanup without depending on byte_at. Add boundary/output cases within the limits
below; use only ordinary fixture main entrypoints.

Named phase callbacks belong in existing `test/unit/test_{parse,check,specialize,
lower,own,verify,emit}/` owners, reusing current input helpers and Option-contract
precedents. Assert:

- Parsing/checking: labels, purity, nongeneric arity/types and designated Option;
  reject incorrect payload/same-shaped ordinary unions with exact kind/help/span.
- Specialize/lower: concrete Some/None IDs, unmanaged Option[Int] versus
  InlineOwningPayload Option[String], operand order and call spans.
- Own: one owned encoder result, unused-result drop and acquire-child-before-parent
  retirement. Verify independently rejects an unmanaged encoder result or wrong
  runtime Option payload. Reuse existing generic union coverage; do not duplicate
  its entire matrix.
- Emit: one helper call, status-selected tag, Some(0), ordinary owning transfer
  and cleanup. Inspect unmodified generated C.

Extend `test/runtime/test_string.brp` and its existing
`fixtures/string_test.c` dispatch under the approved direct-C helper exception:
real allocator/free observations, no new main or generated language-symbol calls.
Cover empty/Int64 bounds, NUL, valid multibyte bytes; encoding width boundaries,
D7FF/D800/DFFF/E000, 10FFFF/110000, noncharacters, Int64 extrema and 4294967361.
Require byte access/invalid scalar zero allocations and unchanged out; successful
encoding exactly one allocation/final free and correct independent expected bytes.

Mutate unsigned conversion, bounds, narrowing order, surrogate rejection,
status-versus-zero and ownership cleanup separately; require the owning callback
or native/e2e oracle to fail, restore, then rerun green.

## Budgets and acceptance

| Scope | Estimate | Hard ceiling |
| --- | --- | --- |
| Production | 180–240 gross / +160–220 net | 260 gross / +230 net |
| Tests excluding fixtures | 420–620 gross / +400–600 net | 700 gross / +650 net |
| Fixtures | 4–6 / 100–160 lines | 6 / 180 lines |

Route accounting: host 69 gross/+63 net + accepted argv 38/+38 + this 260/+230
is at most 367 gross/+331 net, within the aggregate 630/+480. Host ownership repair,
source Char migration, slicing and future filesystem admission remain separate.
No arbitrary expansion is authorized. Report physical production/test/fixture
counts separately.

Feature costs target +5%, hard +10% per unchanged input and host source-to-C proxy;
stricter existing fixture ceilings still bind. Provisional new-fixture limits are
205,000 allocations/600,000,000 instructions for minimal cases and 250,000/800,000,000
for ownership cases. Measure before acceptance; limits are not predictions.
Use frozen matched source/binary/library/toolchain, strict counts separately from
normal min3 instructions, raw per-input samples and actual C/diagnostic outcomes.

## Sequence, commands and handback

After design review/root confirmation, obtain the explicit compiled-lane grant;
characterize the baseline and record both reds. Implement byte access then owning
encoding as one complete supported slice. Update owning README/library parity,
builtin help and grammar documentation where applicable; source migration remains
separate. Matching host wrappers are now published and validated with explicit
source-library selection. No commit before independent implementation reviews.

From the approved checkout's own FRESH supporting host, serialized:

```sh
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 \
  blorp_2/test/unit/test_lower/test_option_contracts.brp \
  blorp_2/test/runtime/test_string.brp
make -C blorp_2 test
```

Run all affected granular owners during iteration; require native sanitizers and
real-main e2e instruction checks. The runtime suite reads relative fixture paths:
run from the intended checkout. Target helpers are emitted C, requiring no new
host-native builtin. The published host-wrapper prerequisites include the original
host discard fix; both interfaces are now available for source Char migration.
Supporting-host transitions require separate reviewed provenance, never a
--std-dir runtime claim.

Return branch/source hashes, separate LOC, exact red/mutant/restored outcomes,
phase/runtime/e2e verdicts, C review and per-input/proxy costs. Stop on a ceiling
breach, host defect, ownership ambiguity, unexpected C delta or required extra
mechanism; report to root instead of adding a workaround.
