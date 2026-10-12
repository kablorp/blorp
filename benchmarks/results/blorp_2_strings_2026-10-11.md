# Blorp 2 UTF-8 String literals

Baseline: `2f5795cc7`, branch `blorp-2`. The
[design](../../blorp_2/STRINGS_PLAN.md) owns syntax, phase contracts and cost
bounds. This implements step 3 of the
[calculator roadmap](../../blorp_2/CALCULATOR_PLAN.md).

## Behavior and architecture

Quoted expressions construct ordinary managed Strings. Literal contents accept
valid UTF-8, nine fixed escapes and one-to-six-digit Unicode scalar escapes.
Raw text retains its exact bytes without normalization. Length and source
spans count bytes; identifiers and comments retain their existing ASCII rules.
Interpolation, multiline input literals and IO remain separate increments.

Lexing validates raw UTF-8 and publishes the original quoted contents and byte
span. Parsing decodes expression escapes once. Builtin declaration labels keep
their exact raw spelling, so Unicode escapes cannot create intrinsic aliases.
Typed literal variants carry value bytes through checking, specialization,
lowering, ownership and emission. No new pass, identity table or cache is added.
Lowering assigns each occurrence an existing function-local ValueId. Ownership
assigns a fresh obligation, and the independent verifier derives its String
type and requires an owner. Existing rules handle borrowing, return transfer,
copies and drops.

The target runtime's byte constructor allocates one root, copies exactly the
explicit length, and appends a separate NUL terminator. Embedded NUL belongs to
the value. Int formatting delegates to this constructor; ARC stays unchanged.

Review identified a backend limit before final validation: strict C11 Clang
flags reject a quoted string with 4,096 decoded bytes. Reproduction and stderr
are retained at `blorp_2/build/strings/limits/`. Emission instead declares a flat
function-local static const unsigned-byte array, named from the existing
ValueId. This avoids the C token limit and automatic stack initialization.
Backing bytes have static storage; each runtime String still has ordinary fresh
owned storage. An empty array uses one dummy byte and logical length zero.

## Test evidence

The frozen baseline rejects `length("hello")` with `quoted builtin labels are
only allowed in builtin bodies`; no C is emitted. Receipt:
`blorp_2/build/strings/baseline/first-literal-red/`. Three direct syntax callbacks
also fail behaviorally before implementation: `build/strings/syntax-red/`.
Focused host syntax/type iteration failures are retained separately; they are
not counted as behavioral TDD evidence.

The runtime slice has four emitted-fragment callbacks and 22 native cases.
It checks exact bytes with explicit lengths, including UTF-8 and NUL, copied
input, independent roots, reference transitions and balanced final frees.
Deliberately copying `length+1` rather than `length` makes nine native cases
fail with ASan stack-buffer-overflow. The runtime source was restored
byte-identically before the green rerun. Receipts under
`blorp_2/build/strings/runtime/`: `green-focused/`, `oracle-overread/`, and
`green-restored/`. The mutation receipt records concurrent workspace edits;
the restored receipt records stable inputs. Its restored runtime SHA256 is
`3baa773873e8a8d3cec86741ad585323e97776aad396de497ce5db259498ce4c`.

Direct phase tests observe decoded bytes, published types, zero-operand literal
definitions, fresh owners, borrowed length calls, return transfer, copies and
reassignment. Malformed ownership inputs test missing/borrowed/duplicate/leaked
owners and incorrectly declared types. Emission tests observe exact projected
byte initializers and explicit lengths. Existing restrictions on managed
prefixes before tail matches and managed values in annotated tail-recursive
functions remain covered.

An emitted-length `+1` mutation fails four of fourteen direct ownership/emission
callbacks. After byte-identical restoration, all fourteen plus eight phase
callbacks pass. Receipts: `build/strings/mutation-length-red/` and
`restored-green/` under `blorp_2/`. The long-literal oracle requires every one of
4,096 initializer bytes and the full-width constructor length, independently
of the native process's truncated status. Both literal-returning match arms
are selected by the normal-main fixture.

The native fixtures use their normal main and unchanged generated C. Their
length and lifetime results combine with exact parser/emitter byte assertions
and independent runtime byte tests. They do not independently compare every
literal byte through the entire native pipeline; no alternate entrypoint or
additional C assertion driver is introduced.

Final validation after the implementation freeze:

| Gate | Result | Time |
| --- | --- | ---: |
| Strict unit/runtime/grammar/tooling | 1,230 passing checks across 79 suites | 15.993 s |
| Full e2e | 183 cases plus orchestration callback passed | 85.100 s |

The strict total contains 1,208 Blorp callbacks and 22 nested native runtime
cases. ASan/UBSan report no issues. Strict harness diagnostics report three
allocations, three releases and zero leaked objects/bytes; e2e stderr is empty.
All 15 new literal fixtures pass their measured ceilings. Ordinary examples
observed at most 2,870 allocations / 37.7M instructions; their ceilings are
4,000 / 50M. The two-tail-arm fixture observed 18,004 / 75.6M, bounded by
22,000 / 100M. The long fixture observed 30,386 / 106.5M, bounded by 40,000 /
140M. These are narrow workload costs, separate from the matched comparison.

Both final packets record unchanged worktree fingerprint
`5c6823f38cfafb916cfd1e7ae72d2e25bff2836ec9fc66f89f11ede8af4031d6`.
Before the next Void/print increment, subsequent tracked changes only completed
report/README/roadmap prose.
Independent compiler-expert code/test review approved with no remaining
findings; an independent test runner executed both gates. Commands:

```sh
scripts/record-validation --output blorp_2/build/strings/independent-tests/strict-final -- \
  bin/blorp test --suite --timeout 180 --sanitize --leak-check \
  blorp_2/test/unit blorp_2/test/runtime \
  blorp_2/test/test_grammar blorp_2/test/tooling
scripts/record-validation --output blorp_2/build/strings/independent-tests/end-to-end-final -- \
  bin/blorp test --suite --timeout 0 blorp_2/test/e2e
```

## Measurement boundary and provenance

Frozen inputs under `blorp_2/build/strings/baseline/` include the prelude, target
library, 147 existing executable fixture roots and their local dependencies.
Three paired samples alternate compiler order. Both compilers receive the same
explicit frozen library root. Measurements cover the whole pilot process
through C emission, excluding pilot builds, C compilation and native execution.
Allocations and retired instructions each have a predeclared +10% aggregate
ceiling. This is an owned-input proxy; the pilot cannot compile itself yet.

The String runtime extension intentionally changes an existing String program's
C prefix. The comparison checks both complete runtime prefixes against their
frozen source fragments, then compares the remaining C byte-for-byte. Programs
without the String runtime must remain completely byte-identical. Comparison
artifacts never become execution inputs.

The separate growth probe uses 256, 1,024 and 4,096 repetitions of ASCII, raw
UTF-8 and Unicode escape text, with three samples per shape/size. It measures
scan/decode/emission growth; it does not establish a complexity proof or a
performance claim against the existing compiler.

| Sum over 441 compilations per compiler | Baseline | Candidate | Change | Ceiling |
| --- | ---: | ---: | ---: | ---: |
| Allocations | 1,945,932 | 1,955,754 | +0.50% | +10% |
| Retired instructions | 18,400,687,102 | 18,347,791,608 | -0.29% | +10% |

Instruction costs are effectively flat; this is not a speedup claim. All
compilations report balanced releases and zero leaks. Each of the 107 programs
without the String runtime is entirely byte-identical in all three samples.
For the other 40, both runtime prefixes match their source fragments exactly,
and all remaining C is byte-identical. Receipt: `matched-costs-final/` under
`blorp_2/build/strings/`; raw pairs and counters are under `samples/`,
`costs.tsv` and `projection.tsv`.

The first comparison stopped because my raw-fragment extractor appended an
extra newline. It did not indicate a compiler difference. The corrected
extractor joins raw lines with the language's separators; the full paired run
was repeated. The failed packet is `matched-costs/`, and its original partial
samples/extraction are retained under `prefix-extraction-red/`.

Growth results, mean over three serial samples:

| Shape | Repetitions | Allocations | Retired instructions |
| --- | ---: | ---: | ---: |
| ASCII `a` | 256 | 2,824 | 35.93M |
| ASCII `a` | 1,024 | 8,200 | 48.89M |
| ASCII `a` | 4,096 | 29,704 | 103.10M |
| Raw UTF-8 `é` | 256 | 3,848 | 39.01M |
| Raw UTF-8 `é` | 1,024 | 12,296 | 60.50M |
| Raw UTF-8 `é` | 4,096 | 46,088 | 188.66M |
| Escaped `\u{E9}` | 256 | 8,967 | 49.25M |
| Escaped `\u{E9}` | 1,024 | 32,775 | 103.13M |
| Escaped `\u{E9}` | 4,096 | 128,007 | 361.94M |

Allocation growth is exactly linear for these inputs, but instruction growth
exposes increasing work at the largest sizes. Inspection proves a growing-copy
mechanism: the pilot's existing `text.concat` helper calls the host's
non-consuming `blorp_string_concat`, which allocates exact capacity and copies
its inputs. Each emitter comma copies the accumulated C prefix; subsequent
`append_int` must grow that exact-capacity buffer. Repeated escape appends also
copy the decoded prefix. Copied bytes therefore grow quadratically in those
loops even though allocation counts stay linear. Byte access and UTF-8
validation do not repeatedly scan the whole source.

Retained candidate C anchors: emitter loop at line 77981, concat wrapper at
101761, runtime concat at 8002, and decoder appends at 89167. The source helper
is `blorp_2/src/text.brp`. These establish the mechanism; attributing individual
instruction deltas requires a narrower profile. A bounded follow-up should
measure consuming accumulation at these two loops, without introducing a new
phase, representation or cache. Per the parent development rule, this host
construction cost is recorded rather than distorting the language or pipeline
to hide it. Receipt: `growth-final/`; raw data: `growth.tsv` and `growth/`.

The actual 4,096-byte native target also compiles at strict C11 `-O0`. Its
assembly places the backing bytes in `__TEXT,__const`; the function has a
64-byte frame and passes the static address directly to the constructor,
without a 4,096-byte automatic initializer. Evidence: `native-inspect/long.c`
and `long.s`, with receipt `inspect-long-c/`.

| Baseline artifact | SHA256 |
| --- | --- |
| `inputs.tar` | `93cea73fb3a3936e6b4a2df485a9439a6635c3aad8530e9b80d398d08994fae7` |
| `compiler` | `c1253956de058b278bb813313fac0ac0c45e971f7052c83cf999f7dd86707c08` |
| `compiler.c` | `d6f9b7dea00f4e1b2c638ef902c18965ae98ed05fb3c7cbdb8e31ff8385b94f6` |

| Candidate artifact under `blorp_2/build/strings/candidate/` | SHA256 |
| --- | --- |
| `inputs.tar` (source, library, tests and EBNF) | `9d68da14f0ea46c755e4c098c568f4cba16e99fba4df6194a6d2ba408c8d85a0` |
| `compiler` | `a1461b477789ff91be791cc83829890d99e7ed61800832fa0f456d6bff852bc6` |
| `compiler.c` | `51456b5f0a9a4a01408186cfd3f7ef603ed67ebe6b10f629d17fb6d0cef4a68e` |

Candidate source snapshot and live compiler sources compared byte-identically
before measurement. The candidate binary/C come from the final e2e build.
Measurements and final gates share the unchanged worktree fingerprint above.

Handwritten production changes: **580 added / 73 deleted = +507 lines**,
including the shared runtime, within the design's 600-line target. Test changes:
**1,686 added / 60 deleted = +1,626 lines**, counting the new Blorp suites,
fixtures and native runtime cases. Generated C and ignored evidence are
excluded. Formal EBNF grows by 22 lines; documentation is separate.

The repository host binary SHA256 is
`4dd4a29a428d7fa8ecd40068f043d8a7ee910df0c6272ba3062c97dfebf938ec`.
Toolchain: Apple Clang 21 on arm64 macOS. Pilot and fixture builds use `-O0`;
the existing host CLI/runtime use `-O0`/`-O2`.

Temporary host Char conversion helpers inspect byte values and encode Unicode
escapes. They are bootstrap dependencies to cover later, rather than evidence
that the pilot already accepts those APIs or implements its own UTF-8 encoder.
