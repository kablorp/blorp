# Prelude-selected canonical trait

Canonical Equatable is selected by the configured prelude's ordinary trait
binding. It may be declared in a normal library module while `_base` remains
import-free. The new foundation receiver allowance requires the actual selected
TraitId and actual library module roles. User modules and other traits receive
no additional ownership permission.

Only Check changes. Namespace remains the binding authority. Specialize, Own,
Emit, the accepted representation, default target library and bootstrap pin are
unchanged in this preparatory slice. A qualified successor seed must be published
and pinned before production library activation.

## Provenance

Base main: `f9b989c2f6fb93ec3dc614d357433ae0a7dfdeb1`. Source04 manifest:
`295b1da3e3498ab597b414652996e39437223a5f5e6860a75fd9f3a0d353beef`.
Actual compiler C: `9e7f0baea10268e5dac8d457a2b1ff16ed13ef5cc9d48aacec02815504c4f85f`
(21,186,583 bytes), identical across the seed/A/B/C self-compilation proof.
The immutable seed used was `blorp2-seed-547ad33c7c2d`.

Root: `/Users/keithphilpott/CLionProjects/blorp`. Raw evidence and independent
reviews: `build/traits-implementation-2026-10-22/T5-trait-location-qualification/`,
with command/stream/guard records in neighboring `T0-qualification/T5-trait-location-*`
directories. Paired candidate binaries are built from the actual proof C using
Apple Clang 21, `-O0`, `-lm -lpthread`, and memory diagnostics 0/1. Their SHA-256
values are normal `68f40d1878aeca0948112b3f3d3bd0eccda2f1b3d53436dcbc4d4941b66ba8a7`
and diagnostic `6c312ea483cce6ff2f6def60046cd581ee66f30fb59c75e7503bfc1ec70e33af`.
Actual link commands, flags, tools and source inventories are in `COST_PAIR_BUILD.json`.

## Matched fixed-input costs

Original revision: `02b13d25d04b7c5670cb94052ea9675cc9ba3428`. Both roles use
its frozen compiler source/library, the same Root cwd, private environment and
physical `T0-qualification/measured.c` output path. The environment is hashed,
not reproduced here. One strict pair precedes the fixed serial normal order
P1 C1 C2 P2 P3 C3; no sample was discarded or rerun. All 180 guards stayed fixed.
This measures cumulative compiler feature cost through this preparatory change;
it does not measure future default-library activation or T4b.

| Metric | Original | Candidate | Change | Ceiling |
| --- | ---: | ---: | ---: | ---: |
| Allocations | 30,981,091 | 31,181,082 | +0.645526% | +5% |
| Retired instructions, minimum of three normal runs | 911,992,267,423 | 915,416,516,197 | +0.375469% | +5% |

Both strict runs have positive equal allocation/release counts and zero leaked
objects/bytes. The candidate allocation count equals the previously qualified
T4a count. Normal instruction samples in actual execution order:

| Sample | Retired instructions | Peak RSS, bytes |
| --- | ---: | ---: |
| P1 | 912,027,874,827 | 310,378,496 |
| C1 | 915,461,140,601 | 311,345,152 |
| C2 | 915,416,516,197 | 308,641,792 |
| P2 | 911,996,159,199 | 310,198,272 |
| P3 | 911,992,267,423 | 310,902,784 |
| C3 | 915,435,096,913 | 312,393,728 |

The frozen-input emitted C is role-specific: Original `276cdc4811404c6949da747a6099acbd124fc54da7b5c582348027709864dbc0`,
candidate `38374a2178e4b5016f8cf6d18015700993eb8c32fc7749bb1f79cc87921b122d`.
Every sample matches its frozen role identity. Those outputs are distinct from
the current-source compiler C above. Raw `time -l` reports establish actual
retired instructions; elapsed time is not substituted for that measurement.

## Validation and limits

Hosted unit/runtime/grammar: 4,489 passed. Target components: 188 callbacks across
27 ordinary suites, each with positive balanced strict accounting. The maintained
proof compared 582 accepted/rejected fixtures under A/B and passed 602 native
checks. The new location fixture stays below its new 33,000 allocation cap
(observed 27,134); existing caps are unchanged. The first diagnostic/instruction
observations governing its 33,000/95M caps remain in the source04 packet.

Both ordinary and ASan/UBSan current-source strict compilations used 34,407,108
allocations/releases and zero leaks/bytes, emitted the same current compiler C,
and had no unexpected streams or sanitizer diagnostics. This observation is
separate from the frozen-input cost comparison. All 48 isolated CLI calls
(24 cases per A/B role) matched exact status, streams, accepted C and rejected
output absence/preserved sentinels. Retained red/green tests establish the new
identity/ownership behavior; faults restoring base fallback and widening library
ownership each fail exactly the intended one of eight unchanged callbacks.

The native gate retains 119 inherited allocation-debt rows with unchanged
ordered identities and limits. Broad instruction checks were explicitly disabled
and are unmeasured; the matched comparison above does not qualify every fixture
instruction budget. This is not a full M8/resource PASS. Local validation does
not replace the three-platform seed publication gates. Production-library
activation and generic automatic equality remain separate increments.

Handwritten line changes: compiler 18 added / 5 deleted / +13; tests 421 / 22 /
+399; explicit fixture-library source 52 / 0 / +52; references 39 / 23 / +16;
workflow 1 / 1 / zero net. This report is counted separately.
