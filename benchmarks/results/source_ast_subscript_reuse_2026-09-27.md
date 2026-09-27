# Source-AST subscript rewrite reuse pilot (2026-09-27)

Source finalization rewrites subscript reads after interpolation finalization
and nested-function hoisting. The old rewrite rebuilt every traversed
expression and list even when a subtree contained no subscript read. This
pilot returns the original managed node on unchanged paths and updates a list
only after one of its children changes. The semantic pass order and the
existing subscript lowering are unchanged.

## Frozen comparison

- Compiler and input base: `99d074858788722249130aba89a4c1ef8082c1f7`.
- Both compilers: FRESH `-O2`, bootstrap `dev-2f1a59c43baa`, Apple clang
  21.0.0.
- Self baseline and candidate: `/tmp/discovery-wave-parent.json` and
  `/tmp/subscript-reuse-self.json`.
- Small baseline and candidate: `/tmp/discovery-wave-parent-small.json` and
  `/tmp/subscript-reuse-small.json`.
- Discovery-only profiles:
  `/tmp/discovery-wave-baseline-{1,2,3}.profile` and
  `/tmp/subscript-reuse-discovery-{1,2,3}.profile`.

| Measure | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Self discovery allocations | 8,485,711 | 7,942,053 | -543,658 (-6.41%) |
| Self whole-compile allocations | 192,930,155 | 192,386,497 | -543,658 |
| Self retired instructions, minimum of three | 149,596,417,890 | 149,273,147,494 | -0.22% |
| Self peak RSS bytes | 2,088,173,568 | 2,086,420,480 | -1,753,088 |
| Small whole-compile allocations | 1,351,076 | 1,343,705 | -7,371 |
| Small retired instructions, minimum | 1,086,518,828 | 1,083,681,509 | -0.26% |
| Discovery current objects | 2,011,084 | 2,000,565 | -10,519 |
| Discovery allocator bytes in use | 163,830,688 | 167,784,352 | +3,953,664 (+2.41%) |

The discovery AST is byte-identical (SHA-256
`9ebecf272451ae59a4be0c3c90c1681aa27f4b1c2b2fd6db78bba39613903d04`).
Self generated C is byte-identical (SHA-256
`034f8ad049f2476e2076a4dc0aded94e0f3a8bdae9c6944d2351a047a428a1f9`),
as is small generated C (SHA-256
`6f2a9556f4ff0baaf899211a2b4cb197b27958885e89016df0131287607551ae`).

The allocator-byte increase is a real phase-local tradeoff. It is consistent
with reusing original parser lists that preserve spare capacity and then
COW-copying that capacity at the first changed element; the old unconditional
`map` produced compact replacement lists. Full self-compile peak RSS did not
regress, so this result supports an allocation and instruction improvement,
not a discovery-memory improvement.

Generated-C inspection confirmed unchanged expression branches retain and
return the original node, constructors occur only on changed branches, and
list `set` is reached only after a changed child. Independent review found no
skipped or double-rewritten child and no unsupported identity comparison.

Validation passed the focused source-finalization suite (28/28),
`scripts/compiler-check --changed` (59/59), and `scripts/test compiler-blorp`
(5,170/5,170). Independent test logs are retained at
`/tmp/subscript-reuse-test-runner-{focused,plan,changed,compiler-blorp}.log`.
