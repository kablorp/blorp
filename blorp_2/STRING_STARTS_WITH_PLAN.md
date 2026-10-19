# Ordinary target String.starts_with

Status: canonical source/test-first preview, UNRUN; root and independent
API/ergonomics, code/data and test review precede plan publication. Implement
only after publication and observed REDs; compiled work needs an exclusive START.
The earlier queue and contract02 packets remain sealed.

## API and source invariants

Add `pure func starts_with(value: String, prefix: String) -> Bool` to target string.
Empty prefix is True; compare counted bytes until prefix end (True), first
mismatch or missing value byte (False). Case, UTF-8 spelling, BOM, NUL and LF are
exact. Named and UFCS calls borrow both inputs; no normalization or reconstruction.
The String-specific helper uses existing byte_at, Int equality/add and match.
Positions stay in 0..length(prefix), inclusive. Increment occurs only for a present
matching prefix byte, hence below length; recursion reaches exactly length, where
byte_at returns None. No negative position or overflowing increment is formed.
The full module and fragment include a permanent note beside prefix_bytes_equal:
linear native-stack use is temporary; replacement needs accepted scalar loops.
No @tail_recursive/TCO/constant-stack claim, hidden clamp or ASCII restriction.
4096 matching bytes is bounded coverage; stop on stack failure without shrinking
that witness or changing stack limits. No per-byte String is built; Option/ARC
may allocate. Hold if temporary stack use is unacceptable. Preserve existing
exports; no new builtin/runtime/Char/Bytes/prelude/framework or Slice dependency.
Keep both source consumers (load:96, utils/text:9) queued for later migration.

## Frozen baseline, complete library and tool roles

B is accepted Numeric `a656f5ce1de963c8e9c162460e181d696b39c1d5` through all repairs.
SOURCE41.json binds all 41 compiler files to B and the retained producer pins.
C changes only string.brp: constructor imports, one IntOps alias and the helper/API.
FULL_LIBRARY_B_C.json freezes all 12 B/C library members; both use B's README.
The 11 compilable B members match retained pins; their historical README differs.
FEATURE_ONLY_LIBRARY.preview.patch adds 18 lines, deletes one, net +17; fragment
19 lines, complete C string module 44. No queued Slice/Path/List API is inserted.
Use the same retained physical normal02ecee8f / diagnosticef9365be pair for B/C;
both were linked from C9ab6dde0. TOOLS_AND_RETAINED_PAIR.json binds full hashes,
root-local paths, modes, generation/link receipts and clang/time identities.
ROOT974 plus explicit HOST_STD91 run host TestSuites; all pins/modes were checked.
Source41 is unchanged: no rebuild, new HOST/construction campaign or cost claim.
Preserve existing HOST caps, metrics and producer/STD roles; transfer no allowance.
All library postimages are ignored review files, not installed production source.

## Four relative cost controls

FOUR_COST_CONTROLS.json binds exactly these fixtures, old caps and native oracles:

| Fixture under test/e2e/fixtures | Allocations cap | Instructions cap |
| --- | ---: | ---: |
| return/zero.brp | 131100 | 440000000 |
| mortal_string/alias.brp | 150000 | 600000000 |
| string_literal/unicode.brp | 134000 | 450000000 |
| string_operations/concat.brp | 205000 | 600000000 |

These cover default imports, live owned aliases, UTF-8 literals and UTF-8/NUL concat.
Use one fixed corpus/library/output slot; install COMPLETE B/C outside measurement
and restore B in finally before classification, without changing root/other trees.
Per fixture: diagnostic B-strict,C-strict require one positive balanced allocation/
release report and zero leaked objects/bytes; normal B1,C1,C2,B2,B3,C3 requires
memory modes unset before timing and one positive retired-instruction counter per
sample. Take min(all three) per variant: 32 compiler calls if later authorized.
Retain all raw streams/status/counters/C; all eight C outputs per input must match.
Link unmodified C with existing strict sanitizer flags; check each real-main oracle.
Targets are +5%, hard ceilings +10%, independently for allocations and normal min3
instructions on EACH input; old absolutes also bind. C*100>B*105 is a target miss,
C*100>B*110 a hard miss. Report each target miss for root review; a miss <=10%
within other guards does not stop remaining authorized controls. No aggregate
win offsets a miss. Hard/absolute breach, drift, invalid/missing counter, unexpected
C/status/semantic/leak/sanitizer result or scope/LOC breach stops immediately.
No retry, filtering, widening, baseline roll, borrowed old samples or allowance.
No original Slice success sample, remaining491 state, HOST or C-only call repeats.

## Existing semantic gates and new feature tests

FULL_CORPUS_IDENTITY.json is source identity for 870 accepted-B test files, not
870 executable cases or a full-corpus min3 claim. TEST_PREVIEW_MAP.json binds
four new files and two additive registry lines; the other 869 files are identical.
Existing full tests/harness own the semantic gate: preserve all old literal
status/stdout/stderr, expected-C, diagnostic/output-state oracles and absolute caps.
Run focused checks then usual unit/runtime/grammar/full-native gates; record actual
coverage/failures. Their existing absolute checks add no relative cost controls.
The two real-main fixtures have 20 argv rows plus one counted-NUL/lifetime row;
EXPECTED_CASES.json and unchanged test previews bind exact bytes and statuses.
Cases cover empty/equal/short/long prefix; first/middle/last mismatch; case;
UTF-8/emoji/decomposed spelling; /library/ containment/siblings; LF; 4096 matching
bytes and late mismatch. NUL is source text, never argv. Aliases survive repeated
calls and a String escapes its producer; named, UFCS and pure calls must admit.
The missing-argument branch remains an optional fixture-contract witness.
Install only the tests first; observe actual missing-export RED via admission and
CLI, retaining full message/help/SourceId/byte spans/status. Do not guess diagnostics.
After GREEN inspect generated C: ordinary byte calls, no per-position extraction/
encoding. Prove source-valid mutants equality->True, increment->2, missing-value
->True: each compiles and fails its named semantic witness. Restore exact bytes
before fresh affected GREEN; compiler/setup failure is not a kill. Use existing
Example/verify_all, strict C11/Wall/Wextra/Werror/pedantic/O0, ASan/UBSan/no-recovery
and real main. No C rewrite, alternate entrypoint, new harness or shared framework.

## Bounds, review and holds

Hard physical limits: production 45 gross/+45 net; tests 180 gross/+180 net with
registry; two fixtures/70 combined lines; public API/temporary notes 15 lines.
Previews: tests 148+2 registry, including 50 fixture lines; API notes seven lines.
Each C-only fixture has proposed 150000 allocations/600000000 normal min3 limits,
no successful absent-feature B denominator. Stop before any bound is breached.
Supporting inventories and execution details remain binding in the packet JSON.
Code and test-runner review precede any later implementation commit. Dirname stays
held behind accepted prerequisites. Normalize stays held: growing List.append
endpoint metadata is O(k^2), a valid negative design, not permission to implement.
No Path engine, source shim/migration, SOURCE gate waiver or old campaign restart.
