# Blorp 2 integer append

This continues String buffer reuse with a pure nongeneric
`builtin("string.append_int")` contract, `(String, Int) -> String`.
Direct and UFCS calls may transfer a last-used destination through the existing
`ConsumedArgument` representation. Named and stored callable wrappers borrow.
Decimal digits use a checked 21-byte stack buffer; concat and integer append
share the existing checked capacity growth and unique/shared storage rules.
There is no new String builder, ownership representation, public signature,
List optimization or legacy compiler change.

## Staged integration

Compiler support lands with the existing production library implementation,
`add(self, IntOps.to_string(value))`. A supporting seed must then pass the
maintained three-platform publication gates and be pinned before that library
body changes to `builtin("string.append_int")`. Support-only compiler costs
and activated-library costs are distinct measurements. An explicitly selected
local library copy may validate activation before publication; it is never a
default-build fallback or evidence that the production library is activated.

## Fixed measurement boundary

The baseline is main `5a88da075`, including the production equality library.
All 61 compiler/library files were frozen before implementation. The baseline
was freshly built through the pinned seed and a genuinely self-built compiler;
its repeated compiler C is
`d7a6e56fd5654d92ecbd7abdecd19302244a08289d77d15ada2620f64d52c11e`.

Normal and diagnostic performance compilers link the same physical C at
`-std=c11 -O2`, with `BLORP_MEMORY_DIAGNOSTICS=0/1` and `-lm -lpthread`.
Whole-compilation measurements use the same frozen source/library, working
directory and physical output pathname, with three interleaved serial samples
per version and mode. Allocations are deterministic strict diagnostic counts;
normal instructions use the minimum of three. Every raw sample, failed attempt,
input/binary/toolchain hash, command, output hash and memory report is retained.
Output may intentionally differ between versions but must be stable within each.

The unchanged `compiler_emit` workload uses the corresponding old/new library
implementation for each native version, with exact checksum/byte-count identity.
Native links use `-fwrapv -O2 -march=native -flto -pthread`, separate normal and
diagnostic modes, one warmup and five interleaved serial samples per version/mode.
Native instruction measurements include process startup and the real main;
no elapsed-time speedup or comparison with the benchmark harness timer is claimed.
Runtime allocator tests independently observe spare-capacity and resize behavior;
managed allocation counters do not count `realloc` calls.

The existing preimplementation ceilings remain: no more than +5% whole frozen
compilation allocations or normal retired instructions, and no more than +550
net handwritten production lines for String increments A and B together.
Increment A used +253, leaving +297 for B. Production/test gross additions,
deletions and net changes are reported separately. Existing fixture caps and
the allocation-debt policy remain unchanged; broad disabled instruction checks
are not instruction-cost qualification.

## Matched measurements

| Boundary | Baseline allocations | Candidate allocations | Change | Baseline normal instructions | Candidate normal instructions | Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Support only, frozen whole compilation | 31,918,638 | 31,912,590 | -0.019% | 273,203,360,817 | 273,197,241,813 | -0.002% |
| Activated-library preview, frozen whole compilation | 31,918,638 | 30,080,158 | -5.760% | 273,190,222,476 | 272,712,992,617 | -0.175% |
| Activated-library preview, native compiler_emit | 129,129 | 54,969 | -57.431% | 1,368,770,570 | 147,556,951 | -89.220% |

Support cost is essentially flat; its tiny instruction difference is not a
meaningful speedup claim. Both whole-compilation comparisons pass the unchanged
+5% allocation and normal-instruction ceilings. Allocations are identical in
all repeated diagnostic samples, with positive exact balance and zero leaks.
The native program retains checksum `-4239430305840994758` and 263,793 emitted
bytes in every sample. Its nine integer-append sites select the consuming
helper. Ordinary `to_string` remains necessary for printing the checksum and
byte count; those calls do not construct digit Strings for append operations.

Normal/diagnostic maximum process RSS in bytes, respectively:
support baseline 301,973,504/314,884,096 and candidate 307,003,392/311,410,688;
activation whole baseline 304,218,112/310,706,176 and candidate
302,874,624/310,902,784; native baseline 7,274,496/7,651,328 and candidate
5,160,960/4,997,120. These are observed process RSS maxima, not production
managed-heap peak measurements. Median external elapsed observations remain
in the raw JSON; they are not used for a speedup claim.

The support compiler C is the proved `09c3f134...` artifact. The explicitly
activated preview reproduces its own compiler C exactly at SHA-256
`551613a1fa856dba77584e694dcb770dc939334e87a0e3137bff94ace76a5c84`.
Both support and activated compilers emit the same stable C for the frozen
baseline input, SHA-256
`a5ea78af325b71fd09f04e703109b2b540601ca4511c7f2ff51784ed64c79508`.
Full binary/toolchain/input hashes and serial commands are in
`performance-spec.json`, the build folders and `measurements/`.
These preview gains are not yet the production default: supporting-seed
publication, pin verification and library activation remain required.

Handwritten compiler production changes: 89 lines added, 37 deleted, **+52 net**
across nine files. Tests: 910 added, 8 deleted, **+902 net** across 17 files,
including the fixture and independently requested emitter matrix. Combined
String A+B production growth is **+305**, below the unchanged +550 ceiling.

## Validation status

The old compiler rejects the new label with the exact unknown-builtin diagnostic.
The maintained parser regression failed before implementation and passed after.
Initial test-author host syntax/model setup failures are retained separately.
Independent validation passes all 42 new phase callbacks and 48 native runtime
cases, including ASan/UBSan and normal/strict modes. The maintained self-built
fixpoint passes: all three emitted compiler generations have C SHA-256
`09c3f13437f18378b0ab376150e698ff472de8bb4a6052f9c2c2254f7d82a5b1`,
all 585 fixture comparisons agree, and all 608 native e2e checks pass.
Exactly 125 existing allocation-debt FAIL rows remain recorded under the
explicit policy; broad-suite instructions were disabled and remain unqualified.
The new integer-append fixture uses 133,608 allocations against its 205,000 limit.
A separate normal `-O0` compile measured 1,595,760,904 retired instructions;
its new instruction cap is 1,800,000,000, replacing the provisional 600,000,000.
Every existing fixture cap stays unchanged.

The complete component gate passes 4,690 host PASS callbacks and 188 target
callbacks across 27 suites compiled by the actual self-built B. All 27 target
strict reports balance with zero leaks. Whole-source ASan/UBSan and strict
accounting reproduce the exact proved C, with 31,950,874 allocations and releases
and zero leaked bytes. Clang 21 and GCC 16.2 accept the new real-main fixture
with strict C11 warning flags in normal and diagnostic modes; exact stdout
includes NUL bytes and integer extrema, and diagnostic targets balance all
18 allocations/releases. Four valid, well-typed deliberate faults each trigger
named failures: incorrect Int64-minimum formatting, missing transferred-reference
release, hardcoded String validation of the unmanaged Int operand, and loss of
unique-buffer reuse. Every mutation was restored byte for byte; the final runtime
and verifier run passes all 58 reported callbacks.
Local support correctness and cost qualification are complete. Supporting-seed
publication/pin and production-library activation remain separate stages.

Raw evidence lives under the ignored
`build/audits/string-append-int-2026-10-23/`. The earlier approved String A+B
design, cost ceilings and architecture reviews remain under
`build/audits/string-cow-plan-2026-10-23/`.
