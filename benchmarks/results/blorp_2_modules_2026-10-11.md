# Blorp 2 local modules

Baseline: `42b723ac5dcf5af60f5b0e641f962dfcf654af4a`, branch `blorp-2`.
The [design](../../blorp_2/MODULES_PLAN.md) records the approved scope, identity
ownership and primary-source implementation research. This implements the first
step of the [calculator roadmap](../../blorp_2/CALCULATOR_PLAN.md).

## Result and boundaries

Selective relative imports retain original declaration IDs. Every function's
annotations and body resolve in its defining module. Types and variants remain
local, imported bindings are not reexported, and only root-local main selects the
entry ABI. Complete namespaces remain separate from accepted semantic facts.
The loading shell inventories each normalized logical path once; annotated
declarations and the absence of module initialization permit dependency cycles.
All later compilation and diagnostic rendering remain pure. Qualified spans
preserve both primary and secondary file locations.

Aliases, wildcard/type/constructor imports, private declarations, bare library
imports, qualified calls and multiline selector lists remain deferred. Logical
path normalization does not canonicalize symlink aliases. Runtime cyclic data
remains forbidden.

## Reproduction and test oracles

The frozen baseline rejects the first import fixture at its slash with
`unsupported character`, exit 1, and no C. Receipt:
`blorp_2/build/imports/baseline/import-red/`.

The integrated ordinary gate passed **1,112 callbacks across 73 suites**, with
empty stderr: `blorp_2/build/imports/unit-fourth/`. Independent strict ASan/UBSan
and leak validation passed the same **1,112 callbacks** in 8.535 seconds with
an unchanged source fingerprint and balanced zero-leak diagnostics:
`blorp_2/build/imports/independent-tests/strict-unit-runtime-grammar-frozen/`.

Two deliberate faults establish independent negative oracles:

- Removing module qualification from duplicate-function lookup failed 8 of 28
  checker callbacks, including same-spelled helpers and imported generic main.
  Original checker restored byte-for-byte; packet
  `build/imports/checker/oracle-module-identity/validation/` under `blorp_2/`.
- Disabling reuse of non-root module paths failed exactly the diamond loader
  test, while the other 8 loader callbacks passed. Original/mutant sources and
  receipt: `blorp_2/build/imports/loader-oracle/`. The loader was restored
  byte-for-byte, SHA256 `789ae9a678a902f711c4206714276f0762747a8a61cc8e5ea441371d1692e34b`.

The first native e2e run passed 153 of 157 cases, including all 6 import cases.
Four existing cases crossed narrow allocation ceilings; behavior, sanitizers
and instruction ceilings passed. Their baseline and new counts justify the
following deliberate 100-allocation ceiling increases:

| Case | Baseline allocations | New allocations | Old ceiling | New ceiling |
| --- | ---: | ---: | ---: | ---: |
| call/one | 968 | 1,037 | 1,000 | 1,100 |
| pure/calls | 1,244 | 1,316 | 1,300 | 1,400 |
| nested/order | 1,545 | 1,617 | 1,600 | 1,700 |
| ufcs/chain | 1,539 | 1,611 | 1,600 | 1,700 |

Initial e2e receipt: `blorp_2/build/imports/independent-tests/end-to-end/`.
The independent complete e2e rerun passed **157 of 157 cases**, including all 6
module cases, plus its orchestration callback. It took 80.986 seconds, exited 0
with empty stderr and an unchanged source fingerprint. Receipt:
`blorp_2/build/imports/independent-tests/end-to-end-final/`.

Independent compiler-expert/code-reviewer verdict: **approve**, with zero
blockers, should-fixes or nits. The reviewer checked identity/visibility,
entrypoint ownership, qualified diagnostics, API/test migrations, loader
construction and the retained gates, mutation oracles and cost evidence.

## Matched owned-input costs

Both frozen executables were built by the same fresh repository host compiler,
linked at `-O0` with allocation diagnostics. Apple Clang 21.0.0, arm64 macOS.
The host build's CLI/runtime flags are `-O0`/`-O2`; the generated pilot executable
and native fixture programs use `-O0`.

All 134 baseline fixture files and the prelude were frozen. Three serial paired
samples per fixture alternated compiler order. Each sample runs the complete
pilot CLI through C emission under strict leak diagnostics and `/usr/bin/time -l`.
No pilot build, target C compilation or native execution is inside this measured
boundary. This is an owned-input proxy, **not self-compilation**.

| Counter, summed over 402 compilations per compiler | Baseline | Candidate | Change | Ceiling |
| --- | ---: | ---: | ---: | ---: |
| Allocations | 1,449,057 | 1,489,272 | +2.78% | +15% |
| Retired instructions | 15,966,968,185 | 16,178,697,245 | +1.33% | +10% |

Allocations repeat exactly across the three samples; instruction changes by
sample are +1.20%, +1.42%, +1.36%. All **134 C outputs are byte-identical** in
every sample. Every compiler sample reports zero leaks.

One evidence entrypoint: `blorp_2/build/imports/matched-final/` contains
`measure.sh`, `fixtures.txt`, `costs.tsv`, `sources.tar`, `candidate`,
`candidate.c`, per-sample counters/C and the `validation/` recorder packet.
The baseline executable and archived sources remain in
`blorp_2/build/imports/baseline/`.

| Artifact | SHA256 |
| --- | --- |
| Baseline executable | `0fbd4bcafb558c9d0c3ccd14b50b8c82595b936079a7252eff79f160825588e2` |
| Candidate executable | `bd9b08e0b58d7d535d71322576dcf7235b75194eab8224143e8d568010833711` |
| Candidate C | `19edfc6c5e732df3e4873d5d5e0e04592b8c1e07b4f4436176edf0257b07ea46` |
| Candidate production-source archive | `eac3dcea09786725a8492a2f0af972c720747dc2ff8459c537c02dc3308d86ac` |
| Repository host bin/blorp | `4dd4a29a428d7fa8ecd40068f043d8a7ee910df0c6272ba3062c97dfebf938ec` |

The final e2e run rebuilt its pilot once, producing executable SHA256
`e8e10c564bee320d449b4b1309a61df9a8ec67259c993e9d224e2bd1e2742e84`.
Its generated C is byte-identical to the measured candidate. The native
`__TEXT,__text` section also matches, SHA256
`83ab339ac74f887757d42f28f3c59641a74da396a3bcb363252d331d09734650`;
Mach-O UUID metadata differs. Raw section/UUID evidence is retained beside the
final independent e2e receipt. The matched measurement keeps its own frozen binary.

## Module growth and physical storage

A generated chain uses distinct module/function names, selective edges and a
root main returning 42 through every function. Three samples each:

| Modules | Allocations | Median retired instructions |
| ---: | ---: | ---: |
| 8 | 3,897 | 42,020,219 |
| 16 | 7,468 | 54,155,907 |
| 32 | 14,615 | 80,349,473 |
| 64 | 28,898 | 141,643,708 |

Every chain's unchanged C compiles with default compiler limits, `-O0`, ASan and
UBSan, then exits 42 with empty output. Compiler samples are leak-clean. Sources,
commands and raw evidence: `blorp_2/build/imports/growth/`.
This bounds observed behavior; it does not establish asymptotic linearity.
Complete name-table proof scans, growing declaration concatenation and flat
namespace queries retain potential quadratic work. No unmeasured index was added.

An upfront 64-span storage probe produced the same sum, 6112, with 134 allocations
for a tagged source carrier versus 6 for an opaque scalar carrier. The scalar
Span stays inline in generated C. Evidence: `blorp_2/build/provenance/`.

## Size and remaining tooling work

Physical handwritten `.brp` lines, including comments and blank lines, counted
separately from generated artifacts; census: `blorp_2/build/imports/line_counts.json`.

| Owner | Baseline | Candidate | Net |
| --- | ---: | ---: | ---: |
| Production, 16 to 20 modules | 13,635 | 14,743 | +1,108 |
| Tests/helpers, excluding fixture inputs | 37,852 | 40,296 | +2,444 |
| Fixture inputs | 2,008 | 2,064 | +56 |

This is feature growth, not a line-reduction claim. Four production modules own
source identity, common declaration identity, namespace facts and the loading shell.

The existing performance comparator recursively selects every `.brp` as a root.
New sibling dependencies make its default selection unsuitable for multi-file
workloads, and explicit `--fixture main.brp` currently fingerprints only the root.
A follow-up must define executable-root selection and fingerprint the complete
dependency bundle before claiming comparable module workloads. No filename-based
semantic heuristic, input rewrite or alternate entrypoint was introduced here.
