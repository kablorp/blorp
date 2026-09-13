# Compiler optimization round 2 — 2026-09-13

This round started from `644575ed80c30a10b5f9805371719e72fc9bebba` and
investigated six independently branched function families. Two production
changes and one measurement-only artifact were accepted. The tested integration
also includes the concurrent `ea5fdde8` typechecking change; all final gates
below ran on that combined tree before local `main` was fast-forwarded.

The measured boundary is Blorp source through C emission, not native compilation
of the emitted target C. A separate compiler build was necessary to compare
compiler implementations. For paired comparisons, both compilers received the
same input source tree, with warmups and alternating sample order. Temporary
benchmark and C outputs were kept outside the repository.

| Function family | Decision | Most relevant evidence |
| --- | --- | --- |
| `mono_data.find_transparent_alias` | Accept a first-transparent-wins, pass-local dictionary | Compiler-self C emission: 37.43s to 35.75s median, 3 pairs (4.49% faster); emitted C byte-identical; peak RSS essentially flat. `early_core` phase: 7.61s to 6.00s median. |
| `consume_specialize.find_clone_target` and sibling candidate/key scans | Accept an ordered candidate catalog and zero-candidate fast path | Direct `rewrite_program` at 512 candidates: 6,178µs to 3,155µs median, 3 pairs; Core JSON identical. At zero candidates: 6,870µs to 278µs median over 20 repetitions and 7 pairs. |
| `prepare.find_union_decl` and sibling declaration scans | Reject index prototype | With 1,024 unrelated declarations and 128 queries of each kind, 36,918µs to 37,239µs median (0.87% slower), 5 paired samples; no meaningful allocation improvement. |
| `env.scope_add_symbol` | Reject function-local optimization | Unique-name insertion copies dictionary entries quadratically across immutable scope updates. A safe win would require batching at caller boundaries, outside this function-family slice. No production edit landed. |
| `context.lookup_meta` / `bind_meta` | Reject speculative dense representation | A meta-heavy synthetic chain scales badly, but the representative inference suite called `lookup_meta` only 23 times and `bind_meta` 8 times. No production edit landed. |
| `match_lowering.replace_semantic_match_fail` | Accept measurement artifact; defer production fix | An 8-arm ordered list match creates 40,320 fallback leaves and 334,670 C lines; fixing sharing requires a graph/block representation beyond this bounded optimization. |

The alias index has a real fixed cost when generic templates exist but no alias
lookups occur: at 128 aliases and zero uses, the isolated pass rose from 9,158µs
to 10,069µs over 200 iterations (5 paired samples). A representative Core dump
contains many named-type nodes, so missed lookups can amortize that build cost;
compiler-self C emission is the controlling workload for the accepted change.

The consume index retains a cost at 512 candidates: allocations rose from
32,057 to 35,652 in the one-iteration direct-pass fixture (11.2%), although
retained objects, allocated bytes, and generated Core matched. The explicit
zero-candidate fast path avoids catalog query and rewriting work when candidate
discovery finds nothing. A 1,024-candidate/1,024-call stress measurement remains
open; do not extrapolate the 512-candidate ratio to that size.

After integrating the two production changes and the match characterization,
three compiler-self C-emission pairs compared alias-only with the combined
compiler on identical source. Median wall time was 35.92s to 35.39s; all six
emitted C files had the same SHA-256. This is a net combined-tree regression
check, not isolated evidence of a consume-pass speedup: the combined tree also
includes the concurrent typechecking change.

Final merged-tree verification: `make`; `scripts/test --no-build compiler-blorp
runtime leak doctest cli lsp package std-check` (11,153 passed, 0 failed);
`scripts/test --no-build compiler-core-sanitize` (1,938 passed, 0 failed);
and `blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh bin/blorp`
(217 passed, 0 failed). The benchmark fixtures and commands are in
`blorp/benchmark/compiler/` and `benchmarks/`; the match-sharing rationale and
reproduction command are in
`docs/issues/compiler-performance/52-share-match-continuations.md`.
