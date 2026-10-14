# Generic records and contextual record literals

Status: accepted. Implementation, two independent compiler-expert code reviews,
final strict/native integration and independently reviewed quiet matched costs
pass. Both 3% cost ceilings remain unchanged.

This is the generic-record slice of the [aggregate roadmap](../../blorp_2/ROADMAP.md),
on `codex/blorp-2-aggregate-roadmap` at HEAD `79deebd`. Nothing has been committed
or pushed. Broader direct union payload annotations, multiple fields, general
Lists, updates and recursive data remain separate increments.

## Contracts and quality review

Records now declare ordered parameters using the existing generic grammar:

```blorp
fixed record Box[T] { value: T }

pure func box[T](value: T) -> Box[T]:
    { value = value }

pure func unbox[T](value: Box[T]) -> T:
    value.value

func main() -> Int:
    unused = unbox(box("42"))
    unbox(box(7))
```

Parameters have declaration-owned identities. Concrete keys retain every ordered
argument, including phantom arguments. Field construction/projection translates
through the actual concrete construction/receiver instance, never the first
instance with the same source declaration. Prepared concrete field types are the
authority for projection results; specialization does not reconstruct them.

One pending-record path replaces the former recursive literal checker. Concrete,
rigid and partially inferred literals share the expression's private inference
slots and worklists. A receiving nominal type or uniquely resolved UFCS contract
supplies the owner; field names and unconstrained variables do not. Substitution
is simultaneous and preserves caller-owned rigid parameters. All children finish
in written order before ordinary field mismatches. Projecting an Int field cannot
erase an unresolved receiver's phantom obligations.

Record fields reuse the existing ownership and representation policy. Box[Int]
and Box[Float] are inline; Box[String] and Box[Void] have managed roots. A phantom
String argument creates no child obligation. Symbolic List[T] fields accept
String but reject unsupported concrete elements before lowering, including
pass-through/zero-argument producers without a literal.

Review prompted three bounded improvements: reuse the authoritative concrete
field type; build pending field rows once from the operand range; and assert
exact diagnostic owners, origins, sources, spans and rendering. A fourth change
skips equality scheduling only when both terms are direct AcceptedType variants,
which cannot contain private inference variables. Ordinary mismatch validation,
mixed/private constraints, Deferred readiness and child-first completion remain.
Both experts approve the final production source with zero P0–P3 findings.

## Tests and oracle evidence

Ignored artifacts live at repository-root `build/roadmap/generic-records/`.
`HANDBACK_IMPLEMENTED.md`, `coverage.md`, `C-ownership.md` and
`native-runtime-results.md` describe the evidence by purpose.

| Check | Result |
| --- | --- |
| Actual initial red | Exact old parser rejection passes; desired parse/check examples fail twice. |
| New generic record unit suite | 31 named callbacks pass. |
| Raw concrete field authority | Two cases reject wrong instances, including equal-layout phantom instances. |
| Final combined strict gate | 1,856 printed checks across 118 suites, exit 0, zero compiler leaks, no source drift. |
| Final normal e2e wrapper | 299 cases, 725 printed checks across 292 suite summaries; exit 0, no source drift, one pilot build. |
| New normal-main group | 21 valid fixture compilations, 23 native inputs and three exact rejection callbacks covering six commands. |
| Runtime helper catalogs | Nongeneric 20 plus generic 20 per-object checks pass; two outer callbacks. |
| Final test-only origin refinement | Two raw cases pass strict sanitizers/leak checking, with exact source/offset assertions. |

The first-instance field mutation fails exactly the same-reader callback with
30 controls passing on final sources. Earlier partial-hint removal fails five
intended callbacks; reverse field scheduling fails two. All source mutations were
restored. Raw verifier tests verify their valid baseline before forging the field.

Native fixtures observe results through real main and compile unmodified strict
C11/O0 output under ASan/UBSan. Runtime catalogs use the approved pure production
fragments with real allocation/free observers and the same 20 independent C
assertions. Generic/nongeneric aggregate fragments are byte-identical, 7,630 bytes.
Five retained representative programs establish reader layout identity and child
acquisition before parent retirement. Native LeakSanitizer is unavailable on this
Apple toolchain; these per-object oracles and compiler leak counters are separate
evidence, not a claim of native LSan coverage.

## Provenance and costs

Host `bin/blorp` is FRESH, SHA
`286a1720a36a75599f910e1b8ab838df642a3983409cd30ed3a6ef3dcf16ba79`,
Apple Clang 21 arm64, CLI O0/runtime O2. Pilot builds use O0 with allocation
diagnostics. Final frozen artifacts in `review-final/` are:

- Checker: `3b627cdfb9407d35153055575d66335929e86d6fed884fae08786717b7cfa9dc`.
- Specializer: `a028fa623a1139d8608d741aa26922bab3ae0b6339775375998314837a8d2fb7`.
- Source archive: `20e1acda89928b9c203751256b61b211dfe1e2d3bc826aab30d85b4fd6828dfe`.
- Input manifest: `76e3e7da2757eb6f1a721324d5b61cf63f91a2ab4b1f7e9f6ab38fae05641d32`.
- Frozen executable: `14b2d3b8237b318ceb01d6e65db99963dcd21452ff4b4120c746827d2da9d68c`.
- Generated host C: `16e9de4fd7862d8861694434029bfdc881c55bf9f33b2f9a3908d7717ad37512`.

The normal final e2e build independently produces the same C; its executable is
`95d7177ecfbcf56e07ed18d96f99435a71062dac51278fc5415f6fc583256dad`,
retained with C in `final-e2e/compiler-tested{,.c}`. Initial native/runtime work
used the earlier `943f8106…` candidate. Final combined gates cover the final
production sources. The subsequent seven-line test-only origin refinement and
one README adjective correction are covered by the owning strict suite and
independent rereview, rather than attributed to the preceding full packet.

Twenty unchanged controls at four sizes use one frozen library/input corpus and
three matched samples per compiler. Every pair emits identical C; strict compiler
accounting balances. Maximum allocation growth is fields128 +2.1862%
(71,861 to 73,432); fields64 grows +1.9564%. The initial candidate's two narrow
3% allocation failures were closed by removing settled equality scheduling.
No ceiling was raised. The final `controls-quiet-confirmed` rerun passes all 20
minimum-of-three instruction guards, maximum +0.5291% at fields32. All 120
compilations balance strict accounting; 60 C pairs are identical. Before/mid/after
inventories show idle clangd and only the measured compiler process, with no
external compiler. An independent expert verified raw samples, summaries,
fingerprints and process parentage. Earlier contended runs, including the replay
named `controls-quiet`, remain superseded; their names do not establish quietness.

Sixteen new shape points vary partial literals, nested fields, projection and
phantom-key depth at 8/16/32/64. The 48 matched pairs emit identical C. Projection64
allocations fall from 82,509 to 67,757 after the review refinements. The final
quiet shape replay reduces minimum instructions from 298,419,098 to 252,769,424
for that input. This removes
introduced repeated ancestry reconstruction; inherited concrete-instance and
namespace scans remain. These are owned-input compilation proxies, not
self-compilation, globally linear compilation or a wall-clock speedup claim.

Compared with the accepted integrated baseline, production grows 565 physical
lines (494 nonblank/noncomment). Implementer unit/grammar tests grow 714 lines,
then seven for the final origin assertions; the runtime/native worker adds 440
and root adds two group-registration lines. Production feature growth and test
growth are reported separately; documentation and ignored artifacts are excluded.

Recorder packets `final-strict`, `final-e2e` and `final-verifier-origin-fixed`
retain exact commands, outputs, hashes and stable fingerprints. `cost/` retains
the frozen workloads, raw paired samples, C comparisons and process inventories.
The final quiet packets have stable source fingerprints and exit 0. Independent
expert review approves their raw samples, C identity and narrow acceptance claims.
