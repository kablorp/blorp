# Frozen OCaml Test Archive

The `test_*.ml` files in this directory are retained as a historical record of
compiler behavior that was once checked by the OCaml implementation. They are
not part of the Dune build, `scripts/test`, CMake, Make, or CI, and they are not
maintained as executable tests.

Do not add new coverage here. Active compiler coverage belongs in
`compiler/blorp/tests/`. A production CLI diagnostic fixture under
`tests/test_compiler/` must carry `-- RUN-BLORP-CHECK`, and its addition must
update the runner's expected fixture count. The migration audit is preserved as
the dated snapshot `docs/OCAML_TEST_COVERAGE_LEDGER.tsv`; it does not describe
current runnable gates.

The production OCaml host used by the remaining package and LSP boundaries is
still live code under `compiler/lib/` and `compiler/bin/`. This archive status
applies only to the files in this directory.
