# Blorp 2 calculator completion

All nine increments of the [calculator roadmap](../../blorp_2/CALCULATOR_PLAN.md)
are implemented. This report covers steps 5–9, starting from the frozen
String/Void/print compiler. The [completion design](../../blorp_2/CALCULATOR_COMPLETION_PLAN.md),
[Option/input design](../../blorp_2/OPTION_INPUT_PLAN.md) and
[Float design](../../blorp_2/FLOAT_PLAN.md) retain the contracts and acceptance criteria.

The ordinary [integer](../../blorp_2/test/e2e/fixtures/calculator/integer.brp) and
[Float](../../blorp_2/test/e2e/fixtures/calculator/float.brp) programs read an
operation and two operands from stdin, print the result and exit zero. They
support add, subtract, multiply, divide and remainder. Missing input, invalid
operands and unknown operations print specified messages and exit one.
For example, `multiply\n6.5\n2\n` prints exactly `13\n`.
The [README commands](../../blorp_2/README.md#float64-calculator) were executed;
their generated C matches the frozen inspection output.

## Accepted facts and ownership

Selective union imports preserve declaration identities and explicitly select
constructors. Option and Bool are ordinary target-library unions. Builtin
declarations name success/failure or equal/different roles; signature checking
accepts their complete nominal contracts once. Specialization checks the
translation to concrete layout/variant identities. Lowering, ownership and
emission consume those facts; independent verification rejects forged roles,
types and ownership claims. No names or variant ordering recover semantics.

ParseInt/ParseFloat borrow counted-byte Strings and return unmanaged numeric
payloads in ordinary Option instances. ReadLine returns one fresh String owner
inside Option; existing exhaustive destruction handles both variants. Numeric
formatting returns one fresh String. Granular tests separately cover checking,
specialization, lowering, borrow analysis, insertion, transfer/drop and malformed
ownership IR. New Float modules each have direct unit suites.

Int arithmetic wraps and avoids C undefined behavior, including minimum divided
by minus one. Numeric parsing consumes every byte and rejects whitespace, NUL,
suffixes and out-of-range input. ReadLine removes LF and preserves other bytes.
Float literals become finite typed binary64 values during parsing, and exact
hexadecimal C projection preserves signed zero and subnormals. Arithmetic can
produce infinity/NaN; formatting preserves a finite round trip and canonical
exceptional text. Float division/remainder by either zero sign returns positive
zero under the parent language principle. This deliberately differs from the
host library's IEEE zero division. Supported execution uses the documented
binary64, startup-locale and default-rounding model, with compile-time guards.

The existing pipeline remains pure after loading. The implementation adds no
pass, registry, cache, fallback, alternate entrypoint or C rewriting. Loaded
nongeneric library declarations retain the existing emission policy; this work
does not add reachability pruning or expand direct record/union fields to Float.

## Executable verdict and component tests

| Final gate | Result | Wall time |
| --- | --- | ---: |
| Strict unit/runtime/grammar/tooling | 1,456 Blorp callbacks plus 40 nested native C cases; all pass | 19.035 s |
| Full e2e | 203 grouped checks plus outer callback; all pass | 112.930 s |

The strict breakdown is 1,297 unit callbacks, one runtime wrapper, 151 grammar
and seven tooling callbacks. The e2e run builds the pilot once, compiles 182
valid fixtures once each, links their unchanged C once each at `-O0`, then runs
299 native executions: 295 named byte-input cases and four existing direct
match/binding executions. The 12 new fixtures contribute 129 executions.
Normal main entrypoints, exact stdout/stderr/status, strict C11, ASan and UBSan
are the verdict. Timeouts remain disabled for e2e. There are no sanitizer
findings; final e2e stderr is empty.

Strict compiler counters balance, including the runner's three allocations and
three releases, zero leaked objects/bytes. These are compiler counters, not
target-wide malloc counts. The approved String-runtime C component suite checks
actual allocator/free/reference-count behavior; raw ownership tests verify
obligations independently. Native ASan/UBSan does not establish target-wide
per-object leak counts on macOS.

Three deliberate mutations prove representative native oracles:

| Mutation after successful strict C linking | Native failures | Restored result |
| --- | ---: | --- |
| Disable ParseInt overflow rejection | 5 exit-status mismatches | 71/71 |
| Reverse Bool result tags | 13 stdout and 3 status mismatches | 71/71 |
| Clamp Float formatting to six digits | 8 stdout mismatches | 57/57 |

All three production files restore byte-identically. The Float mutation catches
the adjacent decimal above an exact halfway value, precision/extremes, 0.1+0.2,
literals and the 64-call fixture. The exact halfway control still passes.
Compiler-expert implementation and separate compiler-expert/code/test review
approve the final integration with P0/P1/P2/P3 all zero.

Retained initial reds remain useful evidence. Two e2e setup runs exposed the
host's unsupported CTFE of String.to_bytes in global Example data; two private
pure constructors now construct identical data at callback runtime. The first
complete run passed every native execution and C comparison but found six
allocation ceilings and the obsolete rejection text for `0.0`. Tests now retain
the actual Int-return type error and full literal span. No production fix was
needed. Old ceilings changed only for the six measured misses; all new
provisional bounds became distinct measured limits, mostly 21–29% allocation
headroom. Strict and e2e gates were rerun after those corrections.

Receipts and detailed classifications are linked from the
[independent runner report](../../blorp_2/build/calculator/independent-tests/final-test-runner-report.md).
The [final fixture costs](../../blorp_2/build/calculator/independent-tests/final-fixture-costs.csv)
and [new ceilings](../../blorp_2/build/calculator/independent-tests/settled-new-fixture-ceilings.csv)
retain every sample. Current-library costs include new declarations and copied
inactive comments; they are a different workload from the frozen comparison.

## Matched cost and C inspection

Three serial alternating baseline/candidate pairs compile the same 170 frozen
program/library inputs through C emission. Each compiler uses its own prelude;
the required Float declaration is the explicit input difference. This is an
owned-input proxy, not self-compilation. The predeclared ceiling is +10% for
both aggregate allocations and retired instructions.

| Aggregate over three samples | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 2,352,681 | 2,389,911 | +1.58% |
| Retired instructions | 21,443,267,488 | 21,628,128,066 | +0.86% |

All 510 C comparisons are byte-identical; all measured compiler allocations
balance with zero leaks. Verdict: within both ceilings. Raw samples and script
are under `blorp_2/build/calculator/`, in `samples/`, `costs.tsv`,
`projection.tsv` and `measure.sh`; the [receipt](../../blorp_2/build/calculator/paired-costs/metadata.json)
records exit zero, 10.976 s and no source drift.

Retained C for both calculators, Float literals, 64 Float calls and 64 ADT result
projections compiles using strict C11/default structural limits and sanitizers.
Each has maximum brace depth four and parenthesis depth three. The two stress
outputs are 37,670 and 39,765 bytes respectively. Inspection confirms flat ADT
projection, exact subnormal/max-finite constants, scalar double parameters and
results, fresh formatter ownership, and releases after borrowed print calls.
The [inspection receipt](../../blorp_2/build/calculator/inspect-c/metadata.json)
links the command; complete programs are under `native-inspect/`.

A separate three-sample narrow compile probe measures extreme-subnormal
projection: Int zero uses 1,206 allocations, Float zero 1,210, smallest subnormal
1,240. Median retired instructions are 32.709M, 32.724M and 32.920M respectively.
This measures the complete small compilation, including lexing/conversion and
C emission, rather than attributing the whole difference to the projector.
Generated host C preserves Float bits in an eight-byte void* carrier with no
separate heap box. Clang's layout dump measures the AST ExpressionBase at 48
bytes, including header/tag/union; Float and Int payload slots are both eight
bytes. The ordinary AST node still allocates. Target values instead use plain
unmanaged double. The [probe receipt](../../blorp_2/build/calculator/float-carrier-cost/metadata.json)
and `carrier-probe/` retain sources, samples, C excerpt and layout dump.

| Net lines against frozen step-4 source | Physical | Nonblank/noncomment |
| --- | ---: | ---: |
| Compiler Blorp | +1,759 | +1,519 |
| Temporary-library Blorp | +3,301 | +41 |
| Blorp tests/fixtures | +5,059 | +4,391 |
| Existing C runtime component tests | +201 | — |

Temporary-library growth includes 3,242 comment lines; 3,213 are verified
verbatim inactive upstream lines after removing the comment prefix. Production
grows 5,060 physical lines, or 1,847 excluding those copied lines, within the
2,000-line aim; active production grows 1,560. Other comments and blank lines
remain counted. Formatting and coverage are preserved. Raw counts and the
per-file copied-line comparison: `line-counts.json`.

## Reproduction and provenance

```sh
scripts/record-validation --output /tmp/calculator-strict -- \
  bin/blorp test --suite --timeout 180 --sanitize --leak-check \
  blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar blorp_2/test/tooling
scripts/record-validation --output /tmp/calculator-e2e -- \
  bin/blorp test --suite --timeout 0 blorp_2/test/e2e
bash blorp_2/build/calculator/measure.sh
bash blorp_2/build/calculator/inspect.sh
bash blorp_2/build/calculator/carrier-probe/measure.sh
```

The last three commands require the retained ignored snapshots and scripts.
The repository host is FRESH, SHA256
`4dd4a29a428d7fa8ecd40068f043d8a7ee910df0c6272ba3062c97dfebf938ec`,
CLI `-O0`, runtime `-O2`. Apple Clang 21.0.0, arm64-apple-darwin25.6.0 builds
the pilot and target programs at `-O0`; target math links `-lm`.
Git HEAD remains `2f5795cc750200a97115dfe5a637f5c4e6e47ddb`; the earlier
String/Void work was already uncommitted and is preserved.

| Frozen artifact | SHA256 |
| --- | --- |
| Baseline inputs.tar | `6d797347ebcd34ca4f84771ae3381c90e3739a81e0ece9c8ee901e91e4f95c40` |
| Baseline compiler | `0e1ba57649bfca7f7625062378dc6e82ffb106ac3d710b47b7f3533e276aa92b` |
| Candidate inputs.tar | `839de3a3f1e90e839620715a6a980812d8bb3e24574b6dc1ea9f83a73fee1895` |
| Candidate compiler | `785c97fe540c551bf5c9f8a2c40cdaa0fbef3fc5d98e85a8159baa6d8cb38da7` |
| Candidate compiler.c | `1588b568d05df250491c397033f78ba3ddf809cdd41df3525588c4ef7697179f` |

Final strict/e2e/cost/C/probe receipts share unchanged source/test fingerprint
`acddb57903a3dea1beb1050db47d8ea69ed9217682610d7e7b520e75df49ac1c`.
Only status/report prose changes afterward. The entire production manifest
matches the start of final validation. Ignored artifacts are local evidence;
tracked tests and these commands reproduce behavior without them.

Before committing, the staged whitespace check exposed trailing spaces on 769
empty copied library comments. These were normalized from `-- ` to `--`;
all active text, line counts, compiler sources, grammar and tests are unchanged.
Counting these as commented empty upstream lines preserves the 3,213 copied-line
net and 1,847 adjusted production lines. Independent review found no issues.
The strict and full e2e gates were rerun successfully in 20.304 s and 115.317 s,
with the same check counts and no sanitizer findings. Both
[strict](../../blorp_2/build/calculator/commit-check/strict/metadata.json) and
[e2e](../../blorp_2/build/calculator/commit-check/e2e/metadata.json) receipts
record unchanged fingerprint
`762987a2bf751a9d96c889a347ab790c552c2d55002ced7e9a61dd52ae60a5f6`;
only this publication note was added afterward.

Two separate host rough edges remain isolated: unqualified imported generic
empty constructors and recursive numeric-cast wrappers. Ordinary qualification
and bounded exact arithmetic avoid those APIs without changing the pilot data
model. Minimal generated-C reproductions remain under `build/option_input/`
and `build/calculator/float-host-cast-hang/`; neither host issue was silently
declared fixed. Float portability beyond the tested execution model, direct
Float fields, recursive data, argument lists and a REPL remain outside this
calculator increment.
