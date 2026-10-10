# Blorp 2 optional carriers

Four absent/present carriers now use `Option` directly: parsed payloads
`Option[WrittenName]`, parsed fields `Option[FieldPattern]`, checked payloads
`Option[TypeUse]`, and diagnostic notes `Option[DiagnosticNote]`. The three
replaced unions and `NoDiagnosticNote` are deleted without aliases.
`UnionPayloadDeclaration(Span)` retains its meaning and location. An absent
field remains distinct from an explicit wildcard or binding. Payload types,
annotation spans and nominal owners are preserved. Pure payload substitution
uses `Option.map`; validation and ownership branches retain explicit matches.

Concrete specialization `NoPayload | IntPayload`, three-way payload bindings,
generic carriers, origins and lifetimes remain unchanged. No syntax, inference
capability, framework or cache was added. Both typed-error reviews approved
its preceding freeze; its plan item is now marked complete.

## Tests and identity

The first callback failed against the old API because `PayloadShape` lacked
`Option.map`; after migration it checks both mixed-union alternatives, Int
type and annotation span 34..37. Two further callbacks check absent/discarded
field spans and optional-note rendering with exact locations. All prior
callbacks remain; **three were added**.

Replacing `Some(FieldWildcard(span))` with `None` failed exactly the dedicated
parser callback (1/24). Source restoration was byte-identical. Initial prefix
editing mistakes in preserved payload-binding names were corrected before
passing suites; retained `initial-failure.c` is a migration typo, not a host
compiler defect. Final whole-identifier scans preserve excluded variants.

Worker focused checks passed **369 units + 64 grammar callbacks**:

| Group | Count | Log under `build/generic-expansion/options/` |
| --- | ---: | --- |
| syntax, parse, unions, match, generic unions, checker errors | 93 | `focused-front.log`; final parser in `focused-option-tests.log` |
| main | 12 | `focused-option-tests.log` |
| lex, prelude, lower, own, verify, emit, specialize, generic ownership | 174 | `focused-downstream.log` |
| check, arguments, generics; grammar | 90 + 64 | `focused-integration.log` |

These count distinct final callbacks, excluding the superseded parser run.
`tdd-before.log`, `mutation-discarded-to-absent.log` and `format-check.log`
retain the narrow evidence. Independent strict/full gates follow the freeze;
the expected unit total is 435, previously 432.

All **68/68 valid fixtures emit byte-identical C** versus typed completion;
outputs and balanced strict allocation reports remain in `options/identity/`.
Union/match C was inspected. Every e2e harness, cap and fixture source is also
byte-identical to that freeze. **No caps changed.**

| Formatted physical lines | Typed freeze | Option | Delta |
| --- | ---: | ---: | ---: |
| Production, including six-line temporary prelude | 10,266 | 10,234 | −32 |
| Tests | 19,865 | 19,985 | +120 |

The ≥20-line reduction aim and no-growth ceiling pass. No coverage was removed
or formatting compressed.

## Matched proxies

These measure owned-input compilation, **not self-compilation**. Three quiet
serialized samples use the existing recorder:

```sh
/usr/bin/time -l -o REPORT.time /usr/bin/env BLORP_LEAK_CHECK=strict \
  PILOT blorp_2/src/prelude_temp.brp FIXTURE OUTPUT.c
```

Allocations are deterministic; instructions are minimum-of-three. Raw samples
and extracted tables are in `options/matched/` and `options/matched.tsv`.

| Fixture | Original allocations / instructions | Typed allocations / instructions | Option allocations / instructions |
| --- | ---: | ---: | ---: |
| return_zero | 684 / 30,718,139 | 687 / 30,724,494 | 687 / 30,679,797 |
| nested_calls | 1,292 / 32,467,090 | 1,330 / 32,596,383 | 1,330 / 32,636,149 |
| mortal_string | 1,020 / 31,625,290 | 1,037 / 31,713,286 | 1,037 / 31,699,766 |
| generic_box | 2,091 / 34,668,625 | 2,154 / 34,938,288 | 2,152 / 34,956,324 |
| union_values | 3,574 / 38,807,286 | 3,633 / 39,048,992 | 3,639 / 39,042,586 |
| match_constructor_spine | 7,628 / 49,660,412 | 8,636 / 52,502,235 | 8,665 / 52,507,725 |

Additional maxima are **+0.34% allocations / +0.12% instructions**, below 5%.
Cumulative maxima versus original `da8fa4c71` are **+13.59% / +5.73%**, below
25%. Small increases are retained candidly; no further optimization was added.

Unchanged negative adapters prepare three parsed inputs outside 1,000
iterations: second-argument mismatch, structural conflict and missing coverage.
Their source bytes and output checksums match the typed baseline. Twelve
paired samples, sources, binaries and C are in `options/negative/`;
`options/negative.tsv` extracts results.

| Boundary | Typed allocations / minimum instructions | Option allocations / minimum instructions | Change |
| --- | ---: | ---: | --- |
| check + render | 414,067 / 924,497,709 | 415,065 / 925,968,572 | +0.24% / +0.16% |
| check only | 375,067 / 847,792,478 | 376,065 / 849,707,520 | +0.27% / +0.23% |

Checksums are 925,000 combined and 692,000 check-only. Every positive/negative
sample has zero leaked objects/bytes. This failure proxy does not characterize
all invalid programs.

## Provenance and handoff

The cumulative baseline remains `da8fa4c7134e3c636fb7b67f35918f8d7cdc50b0`
in `arguments/baseline/`. Immediate baseline: `typed-errors/final/sources.tar`,
SHA-256 `03daa89e2a35fa8e1ffc968bba9deb2b511044a15be45d496869406e24269912`;
pilot `aeba97caf9ecd3aaa97f7e82273d546e4c5c10cef8acc5f08d9863e2560ab01e`.
Option pilot `options/final/compiler`:
`0afa6301d52177238f8567175b81da1a35ffac6c5e0346b5a81586b7d421047c`;
generated C `9c4ba3fab87ee857984b4bc9d8365ea688d4641b51dff4d857b7f2cf112a3419`.

The repository host remains FRESH. Builds use `make -C blorp_2 test-compiler`,
Apple clang 21.0.0 (`clang-2100.3.34.2`), arm64 macOS, `-O0`,
`BLORP_MEMORY_DIAGNOSTICS=1`, `-lm -lpthread`; adapters use identical native
flags. Builds are outside measurements. `final/artifacts.sha256` fingerprints
all compared binaries, adapters and archives.

`options/final-sources.sha256` fingerprints source/tests/docs and this report;
`options/final/sources.tar` freezes them. `changed-files.txt` bounds this slice.
Formatting and `git diff --check` pass. The independent runner owns final
strict ASan/UBSan/leak units and full Makefile gates. No commit or push.
