# Checked String slicing

Status: reviewed and approved by root and the independent compiler/source_port
expert on 2026-10-18, with zero findings. Approval includes the prospective feature
cost contract and hard ceilings below; it is not a measured result or a SOURCE
exception. No slice implementation, tests, builds or measurements have run.
Commit this plan first. Prepare failing tests afterward; implementation requires
both host and target REDs recorded under a coordinator-granted compiled lane.

Planning base B is accepted main `db8abb15af4250eba1ad4c6d3efc8171cf35adaf`.
This is the bounded library feature planned by
[the String boundary](BOOTSTRAP_SOURCE_PLAN.md#string-and-library-boundary) and
[library parity](LIBRARY_PARITY.md), not a compiler-source migration or bootstrap
completion claim. Preserve the separate path.join port and its evidence.

## Contract and scope

Provide matching host and temporary-target interfaces:

```blorp
pure func slice(value: String, start: Int, end: Int) -> Option[String]
```

Offsets and length count bytes. Require `0 <= start <= end <= length` and both
endpoints at UTF-8 scalar boundaries; otherwise return None. Full-width guards
precede subtraction, indexing, pointer arithmetic and narrowing. Preserve exact
counted bytes, including NUL, with no rounding, replacement or normalization.
Given a valid String, endpoint checks suffice: do not rescan the input or result.
Check both endpoints even for an empty range inside a scalar.

Borrow the input. A materialized successful runtime call returns Some containing
a fresh, independently owned String, including whole and empty ranges. The input
remains usable. Constant-folded host expressions may use existing static literal
storage; literal value tests are separate from opaque runtime identity tests.
Failure allocates no result and leaves input ownership unchanged.

For `"Aé🙂\0Z"` (nine bytes): `(1,7)` selects `"é🙂"`, `(7,8)` selects NUL,
`(3,3)` selects empty, and `(2,2)` fails. The ordinary target example is:

```blorp
import:
    string: slice
    io: print
func main() -> Int:
    match slice("Aé🙂\0Z", 1, 7):
        Some(text): print(text)
        None: print("none")
    0
```

Legacy host substring is unchanged. Add no public target substring, Char/Bytes or
Path type, ingress work, unchecked fallback, cache, dispatch registry, general
builder, dirname/normalize implementation or compiler-source call migration.

## First red and shortest feedback

The first target TestSuite callback passes this exact source to existing
`parse_modules` and expects success, without importing a nonexistent parsed
variant into the host test itself:

```blorp
pure func slice_text(value: String, start: Int, end: Int) -> Option[String]:
    builtin("string.slice")
func main() -> Int:
    0
```

Expected baseline red is `unknown builtin operation`, current exact supported-
operation help, and quoted-label byte span `89..103`. Retain the source and actual
message/help/byte span before implementation; no red has yet been executed.
After label acceptance, assert the precise parsed variant and declaration span.

The first host test imports `string: slice`: its expected initial red is the
unknown public API. Its first semantic assertion is `slice("é",0,1) == None`.
The corresponding target normal-main witness matches that result and returns
0 for None, 1 for Some. It must compile successfully and exit 0 after the change.
No baseline success is invented for either new API.

After the approved build, the narrow loops are the new host slice suite and new
target parse/check slice suites, followed by the existing direct String runtime
suite. Capture exact diagnostics rather than only nonzero exits.

## Production path and ownership

Host: add an ordinary wrapper and private boundary predicate to
`standard_library/src/string.brp`. Check Int bounds first. An endpoint at length
is valid; otherwise existing byte_at supplies unsigned 0..255, and continuation
bytes 128..191 are invalid endpoints. Use named bounds. Only after both checks
call existing `substring(value,start,end-start)` and wrap Some. Current native,
synthesized and pipeline substring paths allocate/copy even full and empty
ranges. No host builtin, CTFE, backend or native change is justified. Stop if
opaque runtime tests contradict this design instead of expanding those owners.

Target production inventory is exactly:

| File under `blorp_2/` | Responsibility |
| --- | --- |
| `standard_library/string.brp` | Nongeneric pure declaration using `builtin("string.slice")` |
| `src/utils/syntax.brp` | Closed `StringSliceBuiltin` variant |
| `src/parse/parse.brp` | Label decoding and supported-label help |
| `src/namespace/builtins.brp` | `StringSlice(DesignatedOption[Variant])`, sole runtime contract, declaration help and exhaustive observers |
| `src/check/signatures.brp` | Attach designated foundation Option; validate purity, nongenericity, three ordered parameter types and exact Option[String] |
| `src/specialize/specialize.brp` | Translate actual Some/None identities through existing translate_option |
| `src/emit/emit.brp` | Operation adapter and existing reached-runtime selection |
| `src/runtime/string.brp` | Dedicated pure string_slice_runtime fragment |

The sole typed contract is Pure, `[String,Int,Int]`, and
`OptionalResult(String, designated_option)`. Consumers do not recover semantics
from a label or reconstruct signatures. Generic lower/own/verify production
remains unchanged: call arguments borrow, the ordinary Option has an owning
result obligation, payload projection borrows its parent, and escape acquires
the child before retiring the parent. Their independent tests remain mandatory.

Follow StringFromCodepoint emission: initialize String scratch to NULL, call the
helper exactly once, save its status, and pass it to append_optional_value and
c_union_value with designated identities. Some takes the fresh root; scratch
has no additional retain/drop. Extend existing RuntimeRequirements with one
string_slicing field and its typed reached-operation case, then append the
fragment only when required, following concat. No second requirement mechanism.

```c
uint8_t blorp_string_slice(const struct blorp_string *value,
    int64_t start, int64_t end, struct blorp_string **result);
```

First reject `start<0 || end<start || end>value->length`. Then inspect each
endpoint below length through unsigned-char loads and reject continuation bytes
using named RFC 3629 mask/tag constants. Only afterward form the selected pointer
and difference. Success calls existing blorp_string_from_bytes once, including
empty output: one fresh root, reference count one, exact bytes and terminator.
Invalid input leaves the output pointer untouched and allocates nothing.
Existing valid source allocation bounds establish selected-length safety; do not
fabricate enormous String objects or add a whole-input validator.

## Test inventory and independent oracles

Planned test changes, counted together below:

- New host `blorp/test/test_runtime/test_text/test_string_slice.brp`.
- New `blorp_2/test/unit/string_slice_inputs.brp` and one `test_string_slice.brp`
  in each existing `test_{parse,check,specialize,lower,own,verify,emit}/` owner.
- Existing `test/unit/test_emit/test_runtime_requirements.brp`,
  `test/test_grammar/test_conformance.brp` and
  `test/unit/test_parse/test_string_literals_syntax.brp` for reached selection,
  grammar and exact supported-label help.
- Existing `test/runtime/test_string.brp` and `test/runtime/fixtures/string_test.c`.
- New `test/e2e/test_string_slice.brp`, its registration in
  `test/e2e/test_end_to_end.brp`, and three fixtures under
  `test/e2e/fixtures/string_slice/`: `bounds.brp`, `bytes.brp`, `ownership.brp`.

Phase callbacks cover exact accepted/rejected signatures and diagnostics,
designated/concrete constructor identities, ordered operands, owned Option
representation, borrowed input, ignored result cleanup, duplicated Options and
child acquisition before parent retirement. Raw verifier tests independently
reject wrong argument types/arity, malformed constructor payload/layout,
use-after-retirement and duplicate/missing transfers. Swapping the two Int
operands is well-typed and needs a semantic oracle, not verifier rejection.
Emission proves no helper for an unused declaration and exactly one when reached
only through an existing first-order function value.

Value cases include 2/3/4-byte scalars, continuation witnesses 0x80/0xbf,
decomposed marks, BOM, CRLF, NUL, whole/end/empty ranges, empty inside a scalar,
both invalid endpoints, reversed/negative bounds, Int64 extremes and values above
2^32. Compute negative constants through existing Int operations if the target
literal syntax requires it; no new syntax dependency.

Host tests use impure bounds and heap input to prevent CTFE. Keep input and two
payloads live while checking distinct roots, including whole and empty slices;
check result survival after source release. Do not assert an exact host payload
refcount inside Option matching, where aliases affect it.

The direct native exception uses the same production fragment and existing
delegating allocator wrappers, C11/O0/Wall/Wextra/Werror/pedantic, ASan/UBSan and
no recovery. Check destruction counts before inspecting the borrowed source,
then exact byte arrays, source references, untouched sentinel output on failure,
one allocation on success, zero on failure and balanced final frees. Never
dereference freed objects. No generated-language internal calls or alternate main.

Each e2e fixture compiles once; run unchanged C through real main. Additional
argv rows do not multiply compiler inputs. Bytes/status/streams are independent
literal expectations. Ownership covers source/Option aliases, ignored Some/None,
payload escape, caller reuse and result survival after source destruction.

Prove mutations removing signed/reversed/full-width guards, narrowing early,
accepting either bad endpoint, shortcutting empty, using strlen/wrong offsets,
swapping Int operands, inverting status and breaking payload retirement. Semantic
and native mutants must compile and fail the intended oracle. Malformed IR must
receive exact verifier rejection. Retain failed attempts, exact restorations and
restored owning greens; no compiler-error mutant counts as runtime proof.

## Physical budgets and documentation

Count readable physical additions/deletions/net, including comments and blanks.
Do not compress formatting or delete coverage to fit.

| Category | Gross estimate | Hard gross / net ceiling |
| --- | ---: | ---: |
| Host production | 35–46 | 50 / +50 |
| Target production | 106–144 | 150 / +140 |
| Combined production | 141–190 | 200 / +190 |
| Tests excluding language fixtures | 650–900 | 1000 / +1000 |
| Three language fixtures | at most 92 | 3 files / 100 lines |
| Public API documentation | at most 30 | 30 added lines |

Target gross estimate: parsed variant/label/help 8–12; contract/check/specialize
16–22; emitter and reached selection 46–58; native fragment 24–32; library 4–6;
remaining exhaustive observers/imports 8–14. This is a feasibility estimate, not
proof that 150 lines suffice. Stop before a breach; do not expand generic owners.

Public documentation owners are `docs/GUIDE.md`, `docs/GRAMMAR.md`,
`blorp_2/grammar.ebnf`, `blorp_2/LIBRARY_PARITY.md`, `blorp_2/ROADMAP.md`,
`blorp_2/README.md` and `blorp_2/standard_library/README.md`. Keep their API,
byte-boundary and ownership statements coherent within the combined allowance.
This plan and one later benchmark evidence report are counted separately.

## Approved prospective feature cost contract

This is a new target builtin/library feature. The draft proposed, and root plus
the independent peer approved, +5% allocation and normal min3 instruction targets,
+10% hard ceilings, separately for EACH unchanged
input and the fixed supporting-host construction proxy. Every tighter absolute
cap remains binding. A target miss is reported individually; a hard miss stops.
No aggregate win offsets a miss, and no new-only input receives an invented B.

B remains db8 for the complete slice and all repairs; C is exactly B plus the
reviewed target feature. B compiler-source tree is
`4622d5c8dbd4aab98d60a7135bd9c4c33a043b96`; target-library tree is
`5ae98f5e2dc6f734353eeed51f3c960924de6bff`. Freeze all B library members and C's
same complete library plus the slice declaration, rather than deleting new APIs
from C or adapting B. Exclude pending path.join. Freeze the current B corpus,
negative/output-state cases and existing caps by path and bytes before sampling;
no corpus/call count is claimed yet.

Historical SOURCE R0 failures belong to that campaign: they are neither this
feature's automatic gate nor a passing result. Preserve their original criteria,
failures and limitations. This feature contract waives no SOURCE gate, resets no campaign
and resolves no pending user baseline-policy question. Root/peer approved this
separate feature role prospectively; jobs still require a lane and implementation
requires both initial REDs.

### Fixture ceiling evidence

Closest retained normal-main observations are historical, not db8/slice samples:

| Fixture | Source lines | Allocations | Normal min3 instructions | Existing cap |
| --- | ---: | ---: | ---: | ---: |
| from_codepoint_nul | 9 | 11192 | 38566223 | 250000 / 800000000 |
| from_codepoint_ownership | 9 | 11470 | 38696714 | 250000 / 800000000 |
| file_read/basic | 17 | 14497 | 55530591 | 205000 / 600000000 |
| file_read/ownership | 18 | 14847 | 55865335 | 205000 / 600000000 |

The [String report](../benchmarks/results/blorp_2_string_integer_apis_2026-10-16.md)
and [read report](../benchmarks/results/blorp_2_target_file_read_2026-10-17.md)
retain their versions and toolchains. The codepoint cases directly exercise an
owned Option[String]; read adds borrowed String input and escaping owned payload.
Their old generous caps are not a justification for copying 205k/600M here.

Root and the independent peer approved these prospective C-only compiler ceilings:

| Fixture/scaffolding | Maximum source lines | Allocations / normal min3 instructions |
| --- | ---: | ---: |
| bounds: parameterized indices and one Option consumer | 24 | 25000 / 90000000 |
| bytes: shared match/print helper, counted literals and selected ranges | 28 | 35000 / 120000000 |
| ownership: source/Option aliases and escaping-payload helper | 40 | 45000 / 150000000 |

Extra arguments, calls, matches and ownership branches explain headroom over the
small historical witnesses; this is not a linear cost prediction. Bulk encoding
and failure classes live in phase/native suites. These tighter caps remain
unmeasured. Breach means stop and review the cause, never automatic widening.

### Explicit hosts, libraries and metric

Use the original frozen SOURCE pair, read-only:

- Normal: `/Users/keithphilpott/.codex/worktrees/host-utf8-file-admission/blorp/bin/blorp-stage2`,
  SHA256 `34ac1a913c79fc14130c77fe4339f24885a2fa65f1d25fc4b873b627e10e1f33`.
- Diagnostic: same directory, `blorp-stage2-diagnostic`, SHA256
  `be31a5a3a070deef54707d8676a7c6157042484f40d0424dd5fb46835c09ff93`.
- Explicit host stdlib for every such call:
  `/Users/keithphilpott/.codex/worktrees/host-utf8-file-admission/blorp/standard_library/src`,
  recorded Git tree `090ed68c5bd688cb8e2197c72bc572e4dc32e6d7`.

Reverify complete file membership/bytes and tool identities before/after future
sampling. These identities come from retained receipts, not a new FRESH claim.
The original inspectable command authority is
`/Users/keithphilpott/.codex/worktrees/source-byte-migration-plan/blorp/build/source-byte-migration/cost-preparation/direct/`.
Read its recipes; never execute its historical setup or overwrite its artifacts.

The owned packet root is
`/Users/keithphilpott/.codex/worktrees/string-slice-plan/blorp/build/string-slice/cost-db8-01/`.
Its fixed CWD is `canonical/`; host input is `canonical/blorp_2/src/main.brp`,
target library is `canonical/blorp_2/standard_library/`, and output is
`canonical/same-output.c`, all relative to that packet root. Freeze each corpus
input's full canonical path. B/C install outside measurement at those SAME
paths. SOURCE host calls explicitly use the frozen host std path above. Each
variant emits compiler C once outside sampling; link that unchanged C at O0 into
normal diagnostics0 and strict diagnostics1 target compilers with `-lm -lpthread`.
Target calls explicitly name their complete installed target library.

The host allocation proxy is ONLY the existing unique schema1
`artifact_construction_complete total_allocations` checkpoint: set
BLORP_MEMORY_STATS=1, unset BLORP_LEAK_CHECK, require status0, exact Generated LF
stdout, valid complete C and one positive checkpoint. This preserves the original
metric meaning under a separate db8 feature denominator; it is not SOURCE R0
compliance, FEATURE exit TOTAL, full-process leak balance or self-compilation.
This proxy covers construction of the target compiler, not the new host wrapper's
library-loading cost: that host stdlib remains frozen. Normal proxy samples
unset memory/CC modes. Keep/review complete intentional
compiler-C differences; every output must equal its own variant's setup C.

For target inputs, strict calls require positive balanced allocations/releases
and zero leaked objects/bytes; normal calls use memory modes unset and serial
B1,C1,C2,B2,B3,C3, minimum of all three instructions per variant. Preserve all
raw statuses, streams, counts, C and failures; no filtering/resampling/normalizing.
Freeze intentional supported-label help deltas prospectively per variant;
unexpected fixture C or diagnostic differences stop. No host-only limitation
relaxes target/native zero. Retain old strict-host failures literally; checkpoint
sampling does not turn them green or grant a new exception.

Functional c04 is separately
`/Users/keithphilpott/CLionProjects/blorp/bin/blorp` with explicit
`/Users/keithphilpott/CLionProjects/blorp/standard_library/src`; freeze its full
identity before use. Never rebuild it or substitute the wrapper library there.
Host wrapper validation later uses this isolated slice worktree's fresh bin/blorp
and explicit standard_library/src, with make then FRESH status under a granted
lane. That toolchain does not replace either frozen functional or cost role.

## Execution, review and stop rules

After this plan's docs commit and a lane, establish both host and target REDs.
Only then implement the host and complete target path; run focused
phase/host/native tests and restored mutations.
Run the candidate's normal-main fixtures and inspect complete C. Then run
std-check and current-stack unit/runtime/grammar/e2e. Use explicit Make component,
test-compiler and test-e2e phases so a prior generation is not repeated by make
test. Any parallel gate first needs successful pathless warmup and coordinator
authorization; compiled work remains serialized here.

Freeze the reviewed complete candidate and prospective packet before quiet cost
sampling. Root plus independent code-reviewer/test-runner review cover the actual
diff, gates, physical counts, all per-input/proxy verdicts and limitations before
implementation commit. Plan approval alone does not approve the finished code.
Stop for a host/ownership gap, unexpected output, unapproved mechanism, scope or
budget breach, or frozen-input drift. Retain a minimal witness and report it;
do not repair adjacent work or silently change a denominator.
