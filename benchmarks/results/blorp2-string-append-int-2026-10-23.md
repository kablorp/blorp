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

Compiler support landed as `a9b1939155aa748d5ccfc1eea85eeb51e771bafa`,
with the production library still using `add(self, IntOps.to_string(value))`.
The supporting `blorp2-seed-a9b1939155aa` release then passed all three platform
gates and publication. Its binaries and provenance were verified before pinning
it and changing the library body to `builtin("string.append_int")`.
Support-only compiler costs and activated-library costs remain distinct.
The original explicitly selected local library copy established preview results;
the cold default build below confirms the production compiler has the same C.

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
normal instructions use the minimum of three. Raw samples, failed attempts,
input/binary/toolchain hashes, commands and reports were retained during review.
That original ignored evidence packet did not survive the interruption before
activation. The table below preserves the committed, previously reviewed results;
it is not presented as a newly repeated matched measurement. Fresh publication,
default-build, regression and candidate-only benchmark evidence is kept separately.
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

## Historical matched measurements

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
The original `performance-spec.json`, build folders and `measurements/` packet
are no longer available. The fresh cold default build reproduces the preview
compiler C `551613a1...` exactly; this establishes that the generated C is
identical without claiming recovery of the old sample logs. The profiling
compilers used `-O2`; the default builder and correctness gates use `-O0`.

Handwritten compiler production changes: 89 lines added, 37 deleted, **+52 net**
across nine files. Tests: 910 added, 8 deleted, **+902 net** across 17 files,
including the fixture and independently requested emitter matrix. Combined
String A+B production growth is **+305**, below the unchanged +550 ceiling.

## Historical pre-publication validation

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
These are the original local support results; the published qualification below
is a separate run with its own actual counters.

## Published supporting seed and activated default

The supporting release is
[`blorp2-seed-a9b1939155aa`](https://github.com/kablorp/blorp/releases/tag/blorp2-seed-a9b1939155aa),
qualified by [run 40048300138](https://github.com/kablorp/blorp/actions/runs/40048300138).
All eight asset digests and seven `SHA256SUMS` rows match actual downloaded bytes.
All three archives bind the exact source commit, published normal binary and
reviewed compiler C `09c3f134...`. Their compiler, target-library and host-library
inventories match Git exactly. Each platform passes 585 fixture comparisons
(490 accepted, 95 rejected), 608 e2e cases, 4,690 host callbacks and 188 target
callbacks across 27 strictly balanced suites. Each whole-source sanitizer run
balances 31,950,865 allocations/releases with zero leaks. The release retains
125 original-limit allocation-debt FAIL rows per platform; hosted instructions
are disabled and unqualified. These counts differ from the earlier local run.

A fresh checkout of the support commit plus the activation patch, without a
legacy binary or build artifacts and with a separate empty seed cache, passes
the default `make -C blorp_2 example`. It downloads the pinned published seed and
emits compiler C `551613a1...`, exactly matching the measured activation preview.
Compiler/library/pin inputs stay unchanged, and no legacy binary is produced.
The library activation itself changes one production line, with no new compiler
or ownership representation.

Fresh default validation passes the complete fixpoint, 585 fixture comparisons
and all 608 e2e cases. Components pass 4,690 host and 188 target assertions;
all 27 target strict reports balance. Whole-source ASan/UBSan compilation emits
the identical compiler C and balances 30,113,914 allocations/releases, with zero
leaks. The activated compiler records 122 allocation-debt FAIL rows, down from
the supporting release's 125, with every existing limit unchanged. Broad e2e
instructions remain unmeasured. These gates used the support source plus the
activation; the later parser-formatting commit `e94940f6d` is preserved during
integration. The integrated source emits byte-identical compiler C
`551613a1...`, preserving the fully tested compiler program.

Fresh candidate-only `compiler_emit` corroboration retains the exact checksum
and byte count. All five strict samples balance 54,969 allocations/releases.
Five normal samples observe 147,808,484–148,927,123 retired instructions;
minimum 147,808,484. Unrelated activity in a separate worktree is disclosed in
the raw snapshots. This is corroboration, not a new matched speedup or a
quiet-machine claim. An initial component attempt was conservatively stopped
after mistaking identical relative command paths for a possible collision;
the complete fresh rerun above passed, and no output collision was established.

Activation adds one production line and removes one, with no compiler changes;
its only test edit corrects a stale prepublication comment. Existing gates and
resource policies remain unchanged.
Fresh raw evidence is retained under
`build/audits/string-append-int-resume-2026-10-23/`, with independent release
review under `build/audits/string-append-int-release-review-2026-10-23/`.

Integration also preserves the subsequently landed equality-operator commit
`d7dc9fc73`. The full gate counts above describe the activation snapshot;
no additional full suite was run on that combined tree before publication,
as requested by the user. Upstream publication guards are left unchanged.
