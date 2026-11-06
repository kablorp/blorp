# Blorp 2 Dict phase 2, 2026-11-02

Phase 2 of [DICT_PLAN](../../blorp/DICT_PLAN.md): the `{}` and `{k => v}` literals.
`=>` is a token, the parser reads a `DictExpression`, and checking rewrites each
literal as calls to `empty`, `with_capacity` and `set` of the module that declares
the prelude's `Dict`, found once at admission (`CanonicalContracts.dict_literal`).
Lower, own, verify, specialize and emit are unchanged.

## Provenance

- Base: `e5418568c` (pinned seed `blorp2-seed-83bc73dac61b`). Candidate: this change
  on top of it. Apple M-series macOS, Apple clang.
- Both trees are snapshots (`git archive`). In each, the seed builds `A`, `A` builds
  `B`, and `B` is linked at `-O0` and `-O2` with `-DBLORP_MEMORY_DIAGNOSTICS=0` and at
  `-O0` with `=1` for strict allocations. Each `B` compiles its own snapshot's
  `blorp_2/src` with its own library root.
- Instructions: `/usr/bin/time -l`, a warmup and 3 alternating serial rounds, minimum.
- Raw samples and scripts: `build/dict2/` (ignored, not retained).
- The self-compile rows were measured before the review fixes (braced-form and Dict
  entry messages, the purity check at admission, simpler planning code: 17 more
  production lines, none on a hot path). They were not repeated.

## Self-compile

| Metric | Base | Candidate | Change | Ceiling |
| --- | ---: | ---: | ---: | --- |
| `-O2` instructions, min of 3 | 15,221,273,584 | 15,312,299,870 | +0.60% | +1.0% |
| `-O0` instructions, min of 3 | 45,265,520,637 | 45,603,100,441 | +0.75% | +2.0% |
| Strict allocations | 15,147,470 | 15,224,894 | +0.51% | +1% |

The compiler uses no literals, so this is the cost of checking and running the
added code. The rounds were stable to within 0.3% (`-O2` base 15,221 M to 15,254 M,
candidate 15,312 M to 15,366 M).

**Output identity.** Each tree's C is the same whichever `B` compiles it: base source
gives `4148f452...` under both the base and the candidate `B`, and candidate source
gives `53f4bd62...` under both. The two hashes differ only because the source
differs. The fixpoint's B/C self-compile hash is also `53f4bd62...`.

## Cost identity

`test/e2e/fixtures/dict/literal_cost.brp` builds a five-entry Dict with a literal
100 times; `call_chain_cost.brp` writes the same calls out as
`D.set(D.set(D.set(D.set(D.set(D.with_capacity(5), base, 1), base + 1, 2), base + 2, 3), base + 3, 4), base + 4, 5)`.

- Both pin 1,001 strict allocations in the e2e harness.
- Their generated C, after replacing the `/* literal_cost.` and
  `/* call_chain_cost.` function comments with one placeholder, is byte-identical
  across the whole program (SHA-256 `01a417ce...`, 490 lines each). Compared with
  `sed` and `cmp`.
- Five entries outgrow the minimum seven slots, so the pin protects the capacity:
  with the capacity written as 0, the literal fixture allocates 1,501 times.

The written receiver chain `D.with_capacity(5).set(base, 1)...` cannot be the
comparison today: overloaded receiver `set` is selected before the chain's K and V
are solved, and checking fails with "cannot infer the type parameter from the
argument" (also on the base compiler). A literal avoids that because its `set` is
known by identity.

## Lines

Production, net, in `blorp_2/src` (ceiling 330): 214.

| Directory | Added | Removed | Net |
| --- | ---: | ---: | ---: |
| `check/` | 145 | 13 | 132 |
| `parse/` | 79 | 20 | 59 |
| `lex/` | 2 | 2 | 0 |
| `utils/` (`syntax.brp` token and AST, `names.brp` foundation words) | 28 | 5 | 23 |

Tests: 655 added and 23 removed, mostly the two `test_dict_literals.brp` suites and
four e2e fixtures (135). The edits to deferred suites (`test_records`,
`test_record_admission`, `test_module`, `test_grammar/test_records`,
`e2e/test_records`, `test_record_update_syntax`) cannot run under Blorp 2 yet.

## Tests and gates

- `make -C blorp_2 test`: exit 0, 962 passes (938 before), every strict report
  balanced. New: 12 parse cases, 8 check cases and 4 e2e cases.
- `scripts/blorp2-fixpoint --prove`: FIXPOINT.
- Oracles, each broken in the source and rebuilt:
  - entries prepended instead of appended: the order fixture prints `key 3` first and
    the literal fixture's output changes; 4 parse cases fail;
  - `{}` parsed as an empty record: 2 parse and 3 check cases fail, and the literal
    fixture is rejected;
  - capacity 0: the cost fixture allocates 1,501 times against its 1,001 pin;
  - a root-module `set` preferred over the library's: the decoy check case fails;
  - the parser's `=>` hook removed: the stray-arrow parse case fails;
  - the root-mismatch remap removed: the `{}`-against-a-record check case fails;
  - an impure `set` admitted: the prelude-Dict check case fails.
