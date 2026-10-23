# Blorp 2 String buffer reuse

2026-10-23. Increment A: unique transferred String buffers reuse capacity;
shared buffers preserve value semantics. This adds no public API, List changes,
general consuming user-function ABI, or legacy compiler/runtime changes.

## Measured results

The isolated comparison is **f9b989c2f6fb93ec3dc614d357433ae0a7dfdeb1
versus that same source plus this change**. Both compilers are genuinely
self-built before measurement. Allocations and normal retired instructions
are the primary metrics; elapsed time is secondary.

| Workload | Metric | Original | Candidate | Change |
| --- | --- | ---: | ---: | ---: |
| 50,000 concat-only appends, then checksum | Allocations | 50,004 | 5 | −99.990% |
| Same | Normal retired instructions | 1,264,991,046 | 15,930,940 | −98.741% |
| Existing `compiler_emit` benchmark | Allocations | 178,811 | 129,129 | −27.785% |
| Same | Normal retired instructions | 2,435,751,670 | 1,368,769,475 | −43.805% |
| Whole frozen compiler source | Allocations | 34,397,870 | 30,783,027 | −10.509% |
| Same | Normal retired instructions | 261,451,879,586 | 262,202,389,267 | +0.287% |

Both preimplementation whole-compilation ceilings, +5% allocations and +5%
instructions, pass without amendment. Every diagnostic sample has balanced
allocation/release counts and zero leaked objects/bytes. Runtime allocation
counters do **not** count realloc calls: the five-allocation result does not
mean no resizing. Separate native tests force relocation and independently
observe 13 resizes over 4,096 one-byte appends, with a geometric copied-byte
bound. Spare-capacity append performs neither allocation nor resize.

The mixed emission benchmark still contains ordinary borrowed `append_int`
calls, which copy the growing prefix and allocate a temporary decimal String.
Its improvement is partial. Increment B would introduce a direct integer-append
builtin and needs a separately qualified/pinned seed before its library change
can land. This change does not publish or rotate that seed.

## Ownership and runtime boundary

Direct and UFCS calls to the already accepted `StringConcat` builtin publish
the existing runtime target. Named/stored callable references retain their
ordinary borrowed wrapper. No spelling-based identification or user-function
inlining is involved.

`ConsumedArgument(ValueId, OwnerId)` transfers one locally last-used obligation,
including a nearest-loop-owned String in a terminal arm. The independent
verifier checks pre-call argument contracts, discharges that owner, checks the
other borrow again, and publishes a distinct result owner. Captured outer
owners, continuing joins, dependent RHS operands and later uses stay borrowed
or reject malformed IR. Loop edges retain their fresh acquire-before-retire
batches. There is no persistent history of all retired local owners.

String roots carry byte length and capacity, excluding the trailing NUL.
Only the transferred reference's atomic count of one permits mutation.
Enough capacity means suffix-only copying; otherwise checked geometric growth
uses the existing memory-resize authority. Shared inputs copy before releasing
exactly one transferred reference. Counted UTF-8, embedded NUL bytes and the
terminator are preserved. The existing two String root allocators initialize
capacity; file, argv, slice, codepoint and numeric producers delegate to them.

Actual emitted C for the concat-only loop uses `blorp_string_concat_take_left`
on its first append each iteration. It has no additional old-header release
in that arm; recur acquires a fresh result obligation. The break arm preserves
its ordinary retain/release transfer. Runtime tests and phase tests jointly
establish reuse; exact stdout alone would not establish it.

## Measurement protocol and reproduction

Apple clang 21.0.0, arm64 macOS. Compiler binaries use C11 `-O2`, `-lm
-lpthread`, with separate `BLORP_MEMORY_DIAGNOSTICS=0/1` links from the same
physical C per version. Native benchmark links use `-fwrapv -O2 -march=native
-flto -pthread`, the same libraries, and separate diagnostic modes. Normal
instruction counters come from `/usr/bin/time -l`; diagnostic runs use strict
leak checking. No generated C is rewritten and real `main` entrypoints run.
Compiler link flags and source/binary identities were recorded at build time;
their empty stdout/stderr logs are retained. The full link command arrays were
reconstructed afterward from the witnessed invocations and are labeled as such.
Native benchmark build commands and every measurement command are retained
directly with their samples.

Native workloads have one warmup and five serial, interleaved samples per
version/mode. Whole compilation has three serial, interleaved samples per
version/mode, compiling the identical frozen f9 source/library from the same
CWD to the same physical output pathname. Tables use minimum normal
instructions and deterministic diagnostic allocations. Every version/mode
emits identical stdout for each native workload. Whole-source C changes
intentionally across versions and is deterministic within each version.
This task's compiled jobs were serialized; unrelated activity on the shared
Mac was not globally controlled. Elapsed-time differences should not be read
as a controlled latency comparison.

The concat-only input is this complete Blorp program:

```blorp
import:
    io: print

pure func accumulate(count: Int) -> String:
    chunk = "item\n"
    var output = ""
    for index in 0..count:
        output = output.add(chunk)
    output

func main() -> Int:
    output = accumulate(50000)
    var checksum = 0
    for index in 0..output.length():
        match output.byte_at(index):
            Some(byte): checksum = checksum.multiply(33).add(byte)
            None: void
    print(output.length().to_string())
    print(checksum.to_string())
    0
```

Expected stdout is `250000\n-4187085076922603056\n`. The unchanged
[emission workload](../blorp_2/compiler_emit.brp) emits checksum
`-4239430305840994758` and byte count `263793`.

Flat source inputs with 128, 512 and 1,024 straight-line appends check for
new ownership-history scan costs. Their minimum-of-three compilation
instructions are respectively 421,119,505 → 421,752,454 (+0.15%),
1,172,989,600 → 1,135,275,992 (−3.22%), and
3,277,728,926 → 3,095,892,818 (−5.55%). This is relative evidence against
an added quadratic scan, not a claim that the whole compiler scales linearly.
Both versions' actual emitted programs print the exact append count.

Median whole-process seconds, secondary only: concat 0.116 → 0.00450;
emission 0.197 → 0.112; whole compilation 30.59 → 30.83. These include process
startup and do not isolate the benchmark's internal timer.

Original self-built compiler C SHA256:
`0d12c2441150582ff78e40e762d923493f781bf9d019946cb81b5eb9aba54830`.
Measured candidate stage2/stage3 C SHA256:
`360c787f9a0317d21b927093e1cc53480478733e3abf4e690399efccb42b47f2`.
On the frozen f9 input, candidate output C SHA256:
`a0688e572c3566a106f4f3ce700eeba2ba06e0412fceb5165d61967c3f7ece9e`.

## Integration, tests and limits

Main advanced independently to `aa87ef7ae5460ce048bafe6b1a7112f2c5ede921`
with a canonical-trait selection change. The String patch applies unchanged;
the entire measured f9 candidate source, binaries and raw samples are preserved.
Final qualification runs on aa87 plus this change. The f9 cost comparison is
an isolated feature measurement, **not a measurement of aa87's interaction**.

Final qualification on aa87 plus this change passes:

- The maintained `scripts/blorp2-fixpoint --prove` produces identical compiler
  C through three generations and agrees on all 583 fixture contracts.
- The self-built compiler passes 603 native e2e checks, with zero failures.
- Complete components pass 4,769 checks: 4,581 hosted and 188 across 27 selected
  self-hosted suites. All 27 strict target memory reports balance with zero leaks.
- An ASan/UBSan build of the actual self-built compiler compiles the entire
  current source through its ordinary main, exits 0, emits identical compiler C
  and reports 31,035,642 matching allocations/releases with zero leaks. This
  descriptive current-source count is separate from the frozen-input comparison.
- GCC 16.2.0 compiles the unchanged concat-reuse fixture C with strict C11
  warnings, normally and with diagnostics. Both real-main runs preserve exact
  UTF-8/NUL output; the diagnostic run balances 15 allocations/releases.
- Both native benchmarks emit byte-identical C before and after integration,
  preserving the isolated runtime measurements above.

Current compiler C SHA256:
`044ce4ce23c1085f76027967e3e0c946f6b580a23bd567d1085bbf01edd3c299`.
Independent code and test review receipts accompany the retained evidence.
The full native e2e gate uses Clang; local GCC coverage is the new fixture,
not the entire e2e matrix. Linux and other architectures are left to CI.

The broad gate uses the repository's existing CI policy: **118 allocation FAIL
debt rows remain explicit**, and broad fixture instruction caps are disabled
and unmeasured. No existing cap or policy source changes. The new concat-reuse
fixture is within its compiler allocation limit, 115,557/205,000. Historical
debt-name identity was not independently compared; 118 matches the prior report's
count. The separate matched instruction/allocation measurements above supply
feature cost evidence. Behavioral passes are not resource passes.

| Handwritten scope | Added | Deleted | Net |
| --- | ---: | ---: | ---: |
| Production | 311 | 58 | +253 |
| Tests, including new files | 1,190 | 71 | +1,119 |

Production stays below A's +400-line ceiling. Necessary coverage is retained;
no compressed formatting or deleted coverage is used to meet it.

Preserved early failures include unsupported source forms found by the actual
seed and a stale pre-step drop-bucket snapshot. That snapshot omitted newly
scheduled unused results; retirement now re-reads the updated bucket. A named
regression and deliberate mutation cover the ordering. Runtime unique-reuse,
shared-release and verifier-discharge mutations also fail their named oracles
and restore source bytes exactly. String is a leaf, so projected descendants
of a consumed String are inapplicable; nested later borrows are tested directly.
The first broad component compilation also exposed two existing test-only
ValueId extractors missing the new argument variant; each gained an explicit
branch, and their original 37 callbacks pass. The failed gate remains retained.
The next run found two ownership expectations tied to borrowed concat calls.
Their five callbacks now check exact intermediate-owner consumption and borrowed
recursive-call arguments. The nested-loop observer selects the actual concat
results rather than temporary literal owners, checks both drops and consumption
on inner edges, and requires independent verification. Its old literal-owner
selection had not established the intended lifetime claim. Production was
unchanged by these test corrections; both failed broad runs remain retained.

Raw samples, exact commands, frozen inputs, manifests, binary/C hashes,
rejected attempts and review receipts live under the ignored
`build/audits/string-cow-implementation-2026-10-23/`. The approved revision-3
plan and two preimplementation reviews are under
`build/audits/string-cow-plan-2026-10-23/`.
