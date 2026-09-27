# Generated C byte census, 2026-09-27

This is a lexical size census of the local `blorp-cli` build artifact at
`/Users/keithphilpott/CLionProjects/blorp/blorp/build/_build/blorp-cli/blorp_cli_main.c`.
Its 2026-09-27 12:32:24 PDT modification time and the checkout's
`18d682384d125209582d3a5ed78f19fb7ae7b3bb` revision are context, not
proof that this C file was emitted by a particular compiler binary. This is
not a frozen stage-2 self-compile measurement.

```sh
benchmarks/c_emission_bytes \
  /Users/keithphilpott/CLionProjects/blorp/blorp/build/_build/blorp-cli/blorp_cli_main.c \
  --top 25 --json
shasum -a 256 \
  /Users/keithphilpott/CLionProjects/blorp/blorp/build/_build/blorp-cli/blorp_cli_main.c
wc -c \
  /Users/keithphilpott/CLionProjects/blorp/blorp/build/_build/blorp-cli/blorp_cli_main.c
python3 -m unittest benchmarks/test_c_emission_bytes.py
```

The C artifact is 73,392,245 bytes, SHA-256
`458df1c169c7068ed0ce8737c4b361a797d0b7d154af71e0e675d14d39aaa718`.
The independent `shasum` and `wc` commands agreed with the probe. The two
lexical fixture tests passed. The probe uses a read-only memory map; it does
not load or print the C file into the report.

| Lexical class | Bytes | Share |
| --- | ---: | ---: |
| Identifier spellings | 55,027,827 | 75.0% |
| Structural text, C keywords, numbers, whitespace | 16,425,234 | 22.4% |
| String/character/header literals | 1,910,141 | 2.6% |
| Comments | 29,043 | <0.1% |

| Exact spelling family | Bytes | Occurrences |
| --- | ---: | ---: |
| `brp_` callable shape | 701,484 | 101,389 |
| `brp_ty` type shape | 2,776,390 | 347,376 |
| `__t<kind>_<index>` compact temp shape | 4,365,711 | 634,852 |
| `__blorp_internal_` compiler binding shape | 3,264,290 | 76,632 |
| Other identifier spellings | 43,919,952 | 2,830,899 |

The named families use exact lexical forms documented in
`c_symbol_projection.brp` and `c_naming.brp`. They describe spellings, not a
verified Core identity for each occurrence. The unknown bucket deliberately
contains ordinary locals, globals, runtime symbols, type names, fields,
macros, and other forms that cannot be safely separated from C text alone.
Strings and comments are excluded from every identifier figure.

| Largest unknown identifier | Bytes | Occurrences | Length |
| --- | ---: | ---: | ---: |
| `blorp_task_cleanup_pop_slot_with_task` | 2,633,919 | 71,187 | 37 |
| `__blorp_task` | 1,737,252 | 144,771 | 12 |
| `blorp_List` | 1,335,700 | 133,570 | 10 |
| `blorp_String` | 1,195,440 | 99,620 | 12 |
| `blorp_release` | 1,102,777 | 84,829 | 13 |
| `BLORP_TASK_CLEANUP_SCOPE_WITH_TASK` | 960,262 | 28,243 | 34 |
| `blorp_task_cleanup_push_with_task` | 931,986 | 28,242 | 33 |

Repeated cleanup calls and task context names are the largest visible
individual byte contributors. This corroborates the earlier
[`emitted_c_pattern_census_2026-09-23.md`](emitted_c_pattern_census_2026-09-23.md),
which attributed 11.7% of a 111 MB artifact's bytes to cleanup lines and
slots and measured pop calls at 2.6 times push calls. This report adds a
repeatable, disjoint lexical byte count on a newer 73 MB build artifact. It
does not establish a new cleanup mechanism or show that changing it improves
compiler cost.
Ordinary projected callable spellings occupy less than 1% of this artifact.
The unknown bucket cannot establish a large C-size return from converting
globals or locals to IDs. That question requires an identity sidecar or a
bounded emitter change with before/after C and stage-2 measurements. Earlier
compact-name work reduced C size while regressing backend allocations, so
short aliases alone are not an acceptance argument.

For a frozen artifact, run `benchmarks/self_compile_measure` with
`--keep-output`, then pass its JSON to `c_emission_bytes --measurement`. The
probe rejects a C artifact whose SHA-256 differs from the measurement's
`output_sha256` and carries the input/compiler provenance into its JSON. This
mode requires a frozen Git input and a repository compiler with recorded
revisions; `self_compile_measure` runs that report `unknown` for either
revision remain usable without `--measurement` but do not qualify for this
provenance-bound report.

## Frozen main self-compile artifact

After the build-artifact census, a serialized self-compile supplied an
independently hash-bound C file. It was an attribution run with zero timing
samples; it supplies no compiler-performance comparison.

```sh
BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure lock -- \
  benchmarks/self_compile_measure \
  --compiler /Users/keithphilpott/CLionProjects/blorp/bin/blorp \
  --input-rev 18d682384d125209582d3a5ed78f19fb7ae7b3bb \
  --program self --samples 0 --label c-emission-bytes-main \
  --output /private/tmp/c-emission-bytes-main.json \
  --keep-output /private/tmp/c-emission-bytes-main.c
benchmarks/c_emission_bytes /private/tmp/c-emission-bytes-main.c \
  --measurement /private/tmp/c-emission-bytes-main.json --top 25 --json
```

The compiler was `FRESH` at `18d682384d125209582d3a5ed78f19fb7ae7b3bb`,
stage 1, `-O2`, binary SHA-256
`c9f9216f2961999397ef0d084e030ea9fc9d10113bff3a651dd29eb7749825e4`.
The frozen input was the same revision. The retained C is 78,694,485 bytes,
SHA-256 `8408a30be0025931c05b78f56d29fafc1133d42e3166ed31d4343752a923e81a`;
the probe accepted its matching measurement record.

| Lexical class | Frozen C bytes |
| --- | ---: |
| Identifier spellings | 59,885,065 |
| Structural text | 16,424,442 |
| Literals | 2,340,844 |
| Comments | 44,134 |

Recognized spelling families in this file were 701,470 callable-shape bytes,
2,776,374 type-shape bytes, 4,365,711 compact-temp bytes, and 3,264,290
compiler-internal binding bytes. The remaining 48,777,220 identifier bytes
were unknown. The top three unknown identifiers matched the build-artifact
census exactly in name, occurrence count, and token bytes.
