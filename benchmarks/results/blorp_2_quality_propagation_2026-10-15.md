# Explicit propagation in the pilot compiler source

The preparatory rewrite replaces 343 nested propagation statements across 19
production files with explicit local matches. It preserves the original
continuations, first errors and mutation order, without new helpers or phase
products. The separate parser-rule slice will restrict propagation in input
programs; this preparation does not change that grammar.

## Boundary and size

Baseline is the published namespace squash `fb257c94659a10d09bc6c56215af64c13845bd4d`.
The source patch SHA-256 is
`42e82bc7e6800a0269969d17c8dbdee254ade836a3a422b9913b28c60d73f0c5`.
Physical production lines: **+2,267 / -1,825, net +442**. Tests: zero changed
lines. The combined rewrite/parser ceiling is +479; the rule remains a separate
change. There are 136 lines with at least 14 tabs and a maximum depth of 20,
both within the reviewed ceilings. The remaining 504 propagation statements
are function-level statements.

Most sites match `Ok`/`Err` in place. Two specialization callbacks use explicit
Result carriers to preserve their boundary. Fifteen Option lookups match
`Some`/`None` directly instead of wrapping the lookup solely to propagate its
error. This removes pure error/Result construction work without moving an
operand across a branch. In particular, the ownership lookup preserves the
distinction between an absent outer Option and a present inner `None`.

## Independent behavior evidence

Two independent source reviews approve the frozen patch with zero findings.
The separate test runner reports:

- 2,714 unit/runtime/grammar tests and 430 e2e cases pass.
- Parse frontier remains 32/34. The existing gaps are Char literals and a
  function-type `pure` spelling; this is not a self-compilation result.
- All 429 frozen fixture sources match the baseline archive byte for byte.
  Exit status, stdout and exact diagnostics match for all 429. Emitted C is
  byte-identical for all 349 accepted inputs; 80 inputs remain rejected.
- Every strict leak invocation is balanced with zero leaked objects/bytes.
  No fixture's allocation count grows. Accepted allocations sum to
  **4,701,662 -> 4,627,476**; rejected allocations to **606,032 -> 605,130**.

Matched normal-mode baseline/candidate runs used the same frozen fixture and
library bytes, alternating the compiler order between three samples. The table
uses the minimum complete-corpus total and minimum per-stress-input counters,
not a sum of independently selected per-fixture minima. Every result passes
the +0.5% ceiling.

| Retired instructions | Baseline | Rewrite | Change |
| --- | ---: | ---: | ---: |
| Complete 429-input corpus | 20,885,151,580 | 20,765,492,003 | -0.573% |
| `conversion/projection_stress.brp` | 95,202,423 | 94,328,197 | -0.918% |
| `argument_input/access_stress.brp` | 107,047,142 | 106,142,073 | -0.845% |
| `ufcs/chain_64.brp` | 60,630,299 | 60,223,233 | -0.671% |

## Host build workload

This compares host compilation of three compiler-source snapshots at one
canonical input and output path. Copying each snapshot happens outside the
measurement. It measures the cost of building the source, not the pilot's
efficiency on identical input and not self-compilation.

| Metric | Baseline | Rewrite | Change |
| --- | ---: | ---: | ---: |
| Minimum retired instructions, 3 serial samples | 41,938,866,590 | 41,884,078,935 | -0.131% |
| Cumulative allocations through artifact construction | 22,750,762 | 22,660,734 | -0.396% |

The instruction samples use the frozen normal host. Original, mechanical and
parser-rule variants rotate order across the three samples. Baseline samples
are 41,973,448,104; 41,993,754,552; 41,938,866,590. Mechanical samples are
41,886,217,074; 41,884,078,935; 41,925,902,985. A separately linked diagnostic
host provides allocation counts at
`artifact_construction_complete`; these are cumulative counts through that
checkpoint, not an assertion about all process-exit allocations. Its generated
C matches the normal host's C for each source tree at the same canonical
path. Every snapshot's 34 production and seven temporary-library source files
were verified before each invocation. Both measures pass +5%.

Earlier observations used different baseline and candidate source paths,
affecting path-qualified `BLORP_INSTALL_TAG` metadata. Their apparent -1.588%
instruction and -0.771% allocation changes are retained as superseded raw
observations, not source-change attribution. The canonical-path series above
replaces them. Fixture instruction measurements used identical input paths
throughout and are unaffected by this correction.

## Parser rule after the preparation

The separate rule adds **11 production lines**, for **453 combined**, and
309 test/fixture lines. Its final frozen author patch has SHA-256
`2e3b664feb5f8dfbc7396586473c715666e5d909bc89d10c6d3d491d5274d2eb`;
integration also corrects one e2e suite description. Two independent compiler
reviews and the coordinator approve the precise context model and teaching
diagnostic. Conversion bypass fails 11 placement tests; restoration bypass
fails exactly the two after-block positives. The original parser is restored
before green validation.

The independent gate passes **2,734 component tests and 432 e2e cases**.
Frontier remains 32/34. All 429 original fixture outcomes, stdout and exact
diagnostics match, including 349 byte-identical C outputs. The two new fixtures
reject at the operator with the specified message/help, exit 1, empty stdout
and no output C file. All 431 strict runs are balanced with zero leaks.

Every accepted original input remains below its original allocation baseline,
meeting the pre-set no-growth ceiling. Accepted totals are 4,701,662 original,
4,627,476 mechanical and 4,628,087 with the rule. Rejected totals are 606,032,
605,130 and 605,171. Two rejected helpers grow against the original baseline:
forwarding adds two objects and alias-conflict adds four (0.028% and 0.048%).
The approved ceiling covers successful inputs; these are broader audit results,
not a waived ceiling. The coordinator and tester accept the minor state-copy
cost. Source/count analysis attributes it to two managed `ParserState` context
updates per completed match; no allocator-stack profile is claimed. A later
physical carrier/update improvement could combine advance/context construction
or inline fixed carriers with managed children. No parser redesign is justified
for this observation.

| Retired instructions, matched minimum of 3 | Mechanical | Parser rule | Change |
| --- | ---: | ---: | ---: |
| Original 429-input corpus | 20,803,083,534 | 20,748,667,266 | -0.262% |
| Projection stress | 94,318,049 | 94,230,954 | -0.092% |
| Argument access stress | 106,109,348 | 105,987,783 | -0.115% |
| UFCS chain stress | 60,261,341 | 60,074,457 | -0.310% |

All pass +0.5%. Canonical-path host-build minima are 41,884,078,935 mechanical
and 41,902,038,643 parser (+0.043%); checkpoint allocations are 22,660,734 and
22,670,361 (+0.042%). Combined original-to-parser changes are -0.088%
instructions and -0.353% allocations, passing +5%. Parser normal-host samples
are 41,937,944,115; 41,902,038,643; 41,925,319,438. Its independently built pilot
hash is `81abd521bd1a40a02ad3974b13e3ca57c10b64effddfe3022c81ab5fde4595f4`;
generated C is `60904c799a352f0076cda45429ed155ca7838ac2e42f8df728c275dc9602e600`.
The host, native flags and immutable bootstrap are unchanged.

## Provenance and reproduction

Arm64 macOS, Apple Clang 21.0.0 (`clang-2100.3.34.2`), immutable bootstrap
`dev-0e1598ed616e`. The normal repository host is FRESH, SHA-256
`899e0a92cfe1bc91f992bd3ccdd0755448903eb91d91780ac4870bd13d8cfa17`,
CLI `-O0`, runtime `-O2`, split eight. The diagnostic host, linked by the
existing `make build-blorp-cli-diagnostic` target, has SHA-256
`86ba69ffea8200080157edb25cbc49825654a14d2c09a6161dec447ab0e648be`.
It does not replace the normal host.

The baseline pilot hash is
`0f08564c3dd3b1228cc24b9be923cfd5aca33ef398610417ce12aea9e9dbd832`;
baseline C is
`e1b044511151d29a97f312a2b12895adc18228df079aef91ec029a9168bb1259`.
The independently built candidate hash is
`691e10a7f1bbfb6a6bbe05288192fa015a66bf015ca59982b7fb09438dbdacb2`;
candidate C is
`fee5c9f1fd31591f087de1427a380bab9e3883d5063e1ff60ee6d7d8ab032fd1`.
Both pilots use `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1 -lm -lpthread`.
Generated C is unmodified; fixtures use their normal entrypoints.

From a matching source checkout and fresh repository host:

```bash
scripts/compiler-build-status
make -C blorp_2 test
scripts/blorp2-fixpoint --frontier
BLORP_LEAK_CHECK=strict blorp_2/build/compiler \
  --library-root blorp_2/standard_library_temp \
  blorp_2/test/e2e/fixtures/return/zero.brp /tmp/return-zero.c
/usr/bin/time -l bin/blorp compile --no-format \
  blorp_2/src/main.brp -o /tmp/pilot.c
```

Raw artifacts remain in ignored `blorp_2/build/quality-remaining/`: baseline
compiler/C, fixture and source archives, hashes and results under `baseline/`;
the independent commands, manifests, gate logs, frontier, all fixture outputs
and instruction samples under `mechanical-gate/`; the rule's complete gate and
corrected canonical build series under `parser-gate/` (specifically
`host-build-canonical/`). Superseded path-confounded samples remain under
`host-build/` and `parser-gate/host-build/`. They are evidence, not persistent compiler caches. Compilation
and measurements were serialized; read-only reviews and source editing in
other worktrees proceeded in parallel.
