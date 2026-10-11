# Pilot blank lines and single-line comments

The pilot now accepts blank lines and `--` comments without giving those lines
layout meaning. Inline comments end at LF or EOF. The lexer keeps the original
source and byte offsets; parsing and later typed facts need no comment carrier.
Docstrings and retained documentation metadata are deferred.

## Contract and implementation

One cursor and the existing `LinePosition` distinguish a code line from trivia.
Leading whitespace is scanned once. A following LF, comment or EOF makes that
prefix incidental, including mixed or irregular indentation. Before real code,
the existing tabs-only or groups-of-four-spaces validator still applies.
Comment-only LF is discarded; inline-comment LF terminates its real code line.
Comments cannot continue expressions onto another code line.

`--` takes precedence over signed integer scanning; `->` and `-42` are unchanged.
Comments accept ASCII bytes other than CR/LF; LF terminates, and CR retains the
existing line-ending error. Non-ASCII comment bytes reject at their original
byte offset. `---` remains an ordinary comment, with no docstring semantics.

Only `lex.brp` changes behavior. Two parser help strings no longer forbid blank
lines; parser control flow is unchanged. The EBNF explicitly defines trivia,
inline comments, original ASCII boundaries and final trivia at EOF. The README
describes the same rules. There is no preprocessing, source rewrite, synthetic
layout stack, AST metadata, cache or new pipeline layer.

Formatted growth is 67 production lines: lexer 70 added/3 removed, and two
zero-net parser help replacements. This stays below the predeclared 100-line
investigation threshold. Test/fixture growth is 349 net lines: 400 new lexical
and grammar test lines, bounded migrations of old blank-line rejections, and
the native fixture/registration. Previously uncommitted generic work is preserved.
Final frontend integration moves the exact leading/trailing blank sources into
the accepted loop, retains the whitespace-only EOF missing-body diagnostic, and
adds a distinct binding-without-final-expression negative: minus 7 net lines.
The other 25 negative records remain byte-identical. Its focused strict callback
covers 5 accepted and 27 rejected programs; first red and final green are under
`blorp_2/build/managed-union/frontend-contract/`.

## Focused correctness and oracle validation

All commands use the FRESH repository host, SHA-256
`4dd4a29a428d7fa8ecd40068f043d8a7ee910df0c6272ba3062c97dfebf938ec`.
Tests are Blorp `TestSuite` callbacks.

Before implementation, the original 14 lexical and 7 grammar cases all failed:
0/21 passed, with zero reported process leaks. Later additions bring the new
cases to 15 lexical and 11 grammar callbacks. They check complete token traces
or exact diagnostic message/help/span/no-note facts, including NUL/DEL, CR,
UTF-8 rejection, incidental indentation, annotations, preludes, missing bodies
and declarations, real dedents, and forbidden expression continuation.

```sh
bin/blorp test --suite --sanitize --leak-check --timeout 180 \
  blorp_2/test/unit/test_lex.brp blorp_2/test/unit/test_lex_trivia.brp \
  blorp_2/test/unit/test_parse.brp blorp_2/test/test_grammar
```

The recorded affected gate passed 158/158 under ASan, UBSan and strict leak
checking in 1.842 seconds. Changing the blank-line newline guard to unconditional
emission deliberately made 16/26 new cases fail. Restoring the exact lexer bytes
restored 26/26 passing cases. This is an assertion failure oracle, not a compiler
crash, timeout or leak substituted for failure.

The ordinary-main fixture is
`blorp_2/test/e2e/fixtures/syntax/trivia.brp`, registered through the existing
return-zero suite and exact C oracle. Its narrow native run built the pilot once,
compiled unmodified emitted C at `-O0` with warnings, ASan and UBSan, exited zero,
and produced empty stdout/stderr. Compilation measured 995 allocations and
35,717,366 instructions against 2,000/40,000,000 ceilings. The wrapper is an
ignored Blorp `TestSuite` using the existing harness and real fixture entrypoint.

The four packets under `blorp_2/build/source-trivia/green/` are
`affected-strict`, `blank-newline-mutation`, `restored-trivia-strict` and
`native-trivia`. All report unchanged source during execution. Packet sources
and hashes, the first red, exact mutation/restoration and handback are retained
locally under `blorp_2/build/source-trivia/`.

The existing compiler also checks and emits C for the exact unchanged fixture,
including shallow and mixed-indent comment-only lines. This was verified with
`bin/blorp check` and `bin/blorp compile --no-format`, rather than assuming older
grammar prose describes current behavior. Logs and C are retained as
`host-fixture-{check,compile}.log` and `host-fixture.c`.

## Matched owned-input compilation costs

The baseline is the final frozen managed-union candidate, before trivia support. Its
normal/diagnostic binaries are reused only after checking all 16 source contents,
the FRESH host, flags and artifact hashes. The candidate is a separate frozen
16-file source snapshot; only the lexer and two parser help strings differ.
Both pairs are built from one emitted C each at `-O0`, with diagnostics disabled
for retired-instruction samples and enabled for allocation/leak samples.

The existing measurement and summarization scripts were reused on 121 frozen
existing valid fixtures. Three quiet matched pairs reverse variant order in the
second pair. Allocation counts are stable, every diagnostic sample has zero
leaks, normal/diagnostic C matches, and repeated C matches within each variant.
These are pilot owned-input compilation proxies, not self-compilation or target
program runtime measurements. No speed claim is made.

| Metric | Baseline | Trivia candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations, corpus total | 408,462 | 412,348 | +0.9514% |
| Sum of per-fixture median retired instructions | 4,291,886,832 | 4,288,389,192 | −0.0815% |
| Largest individual allocation increase | | `match/binding_outer.brp` | +1.4208% |
| Largest individual instruction increase | | `match/many_arms.brp` | +0.7568% |

The predeclared 5% aggregate and 10% individual investigation ceilings pass.
All 121 existing emitted programs are byte-identical across variants. Fixture
budgets remain unchanged. Source/binary/host manifests, corpus hashes, raw
samples, complete results and C comparisons are under
`blorp_2/build/source-trivia/final-cost/`; `summary.json` and `summary.txt`
summarize the measurements. Shared-machine compiled work was serialized. The
earlier `cost/` packet remains intact as a prior milestone. Final snapshots both
include the managed-prefix diagnostic correction (`own.brp` SHA-256
`95efc5def5be13ddd3bd74e0698a2e0716da748e5eb87bc42428fa910922ea1c`).
The baseline reuses the final managed candidate's C and binaries only after
checking identical 16-file source contents, host, flags and artifact hashes.
Candidate sources match the live 16-file pilot tree byte-for-byte. Final source,
artifact and 237-file source/test inventories were rechecked after measurement.
The final summary SHA-256 is
`784ec41f0dbd5f3186da2a48c0d7b374913c45890b0983d85f22e1c22e2433f4`.

## Integration status

Independent compiler/parser/ergonomics source review found no outstanding issue.
The final combined strict gate passes 913 unit, 10 runtime and 98 grammar checks
(1,021/1,021, 7.816 s). Ordinary e2e passes 151 cases plus its wrapper and all
134 native fixture budgets (74.296 s), including the unchanged trivia fixture.
Final packets are `blorp_2/build/managed-union/independent-combined-strict-3`
and `independent-combined-e2e-2`. They report unchanged sources, no timeout and
no sanitizer/leak findings. E2e's artifact timeout is explicitly zero.
Eight managed ownership fault/restoration pairs also pass independent review.
Standard host leak and codegen gates pass 1,267 and 241 checks respectively.
Independent compiler and test-runner reviews accept the final source and costs.
Later prose edits do not alter
the source/test inventory; full-tree receipt fingerprints describe their earlier
recorded tree, not these report-only edits. The separate host aggregate-Core lifetime failure and
cancellation-planner timeout remain documented in the
[host ownership report](compiler_singleton_call_branch_ownership_2026-10-11.md).
They are not claimed repaired by lexical trivia.
