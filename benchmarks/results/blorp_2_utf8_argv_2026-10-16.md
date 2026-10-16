# UTF-8 native argument admission

Programs emitted by the pilot validate each native argument before publishing
a String. Invalid UTF-8 drops the initialized List prefix and exits before
language `main`.
The change adds 38 production lines; tests add 364 and delete three lines.

## Matched costs

Baseline source is `c02a9efdc25e358e5620f0ef3c5404765f5b0d38`; the candidate
adds the reviewed UTF-8 change. Both compile the same 452 immutable fixtures
with eight unchanged target-library files, one physical input/output boundary,
and `blorp_2/src/main.brp` as the compiler source's relative spelling.

| Boundary | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixture allocations | 5,432,764 | 5,432,703 | -0.001123% |
| Sum of per-input min3 instructions | 18,136,828,114 | 18,159,226,612 | +0.123497% |
| Host source-to-C checkpoint allocations | 23,128,641 | 23,130,238 | +0.006905% |
| Host source-to-C min3 instructions | 41,968,864,570 | 41,962,033,749 | -0.016276% |

All 452 inputs pass the 5% targets and 10% hard ceilings. Worst individual
growth is 0.015373% allocations and 1.430101% instructions. Existing e2e
ceilings remain binding. These host source-to-C measurements are proxies,
not pilot self-compilation; they compile each variant's compiler source.

There are 904 strict calls, 2,712 alternating normal calls, six normal host
proxies and two separate allocation checkpoints. Strict calls balance every
allocation with zero leaks. Normal calls unset leak/memory flags and match
their own variant's full C/status/stdout/diagnostic oracle. Neither samples
nor emitted C were rewritten, excluded or normalized.

Each variant accepts 356 inputs and rejects 96 with identical diagnostics.
Of the accepted C pairs, 151 are byte-identical, 162 add exactly 1,160 String
runtime bytes, and 43 add those bytes plus 228 argv bytes. All raw differences
were reviewed. Twelve semantic mutants are caught after successful builds.
Those mutation receipts precede the c02 rebase: exact protected production/test
identity was checked, then the 5 emitter, 33 argv and 35 String cases were rerun.

## Toolchain and evidence

Apple Clang 21.0.0 (clang-2100.3.34.2), arm64; pilot links use `-O0` and
`-DBLORP_MEMORY_DIAGNOSTICS=1 -lm -lpthread`. The frozen normal host uses
CLI `-O0`/runtime `-O2`; neither frozen host was rebuilt or copied.

```text
normal host:     899e0a92cfe1bc91f992bd3ccdd0755448903eb91d91780ac4870bd13d8cfa17
diagnostic host: 86ba69ffea8200080157edb25cbc49825654a14d2c09a6161dec447ab0e648be
baseline C:      529d516d4549c92aa07cc78d6db45b9161f3adc710fea5c81cca5f12e2dc91f3
candidate C:     535656652858a8f38370f92614e4c439faf6a4c1a89a65a5b2810df49b15dff9
baseline binary: ad357f9b65de098c9fca59fed07ef0f4c904bc449a18f3bdafd20e9ae4d23adc
candidate binary:95165fce1c90fcb5ac46c607a0ea93a38f32eac2afe430e773d625bd25fc43b7
raw manifest:    202e663ff1b19747651b504c166ee23f6d0dfe74723850f3cc11692b80e59c9f
```

The manifest covers 19,434 artifacts under
`/Users/keithphilpott/.codex/worktrees/aab8/blorp/build/utf8-argv/cost-c02/`.
`READY.md` retains the commands and frozen setup; `PER_INPUT_COSTS.tsv` retains
every ratio, and the full handback records provenance and limits. Native
compiler C grows 1,711 bytes and both links retain the same 84 host warnings.

## Acceptance and limits

`BLORP_CC=/usr/bin/clang BLORP_2_INSTRUCTION_CHECK=required make -C blorp_2 test`
passes: 2,743 host component callbacks in 213 suites, 199 nested C runtime
checks in ten suites, and 452 e2e cases in 39 groups. All 712 accepted baseline
and candidate C artifacts also compile/link unmodified with strict C11,
`-Wall -Wextra -Werror -pedantic -O0`, ASan/UBSan and no sanitizer recovery.
That additional check establishes compilation coverage; the e2e suite owns
actual entrypoint execution. The source-tree unit suite reports 36/38 parsed,
at the existing Char/function-type stops; this is not an M8 fixpoint result.

Receipts are under `blorp_2/build/utf8-argv-landing/`. The actual-main generated
compiler C matches the full frozen candidate C above. Its FRESH host is
`390bdd0dd10d2f916c2d795462a278ed6bfa88b4c47928f9807ede748d331c7a`;
the actual-main pilot binary is
`e7fe3332e3f40f36b03dd4238da913543b90489776b06d88ced21e47ece9b128`.
Its filename/build receipt differs from the cost binary; no binary identity is
claimed. Source/library and host-binary hashes match before and after the gate.

Malformed argv is covered by production-helper tests and complete emitter
prefix checks; the String-valued e2e harness cannot supply malformed arguments.
This does not establish that OS-entrypoint case end to end. Legacy host argv,
file/cwd/error admission and byte-splitting substrings remain follow-ups.
Future raw file admission must preserve the transitional lexer's malformed-byte
coverage. No Bytes, Char, ASCII refinement or Unicode normalization is added.
