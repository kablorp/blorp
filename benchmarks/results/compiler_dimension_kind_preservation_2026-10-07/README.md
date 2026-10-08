# Dimension kind evidence

> Publication note: this packet is a path-only projection of the privately archived original evidence. Original measurement, review, seal and copy hashes below remain historical original-byte authority; they do not hash the projected metadata or controllers. Numeric results, timestamps, source/compiler/C hashes and unchanged payload bytes are preserved. The [publication contract](../compiler_reader_cuts_publication_2026-10-07/README.md) and its `PUBLICATION_MANIFEST.json` identify current public byte hashes. Historical controllers are evidence, not directly runnable configurations.


Raw records retain their original bytes and paths. `COPY_MANIFEST.json` records
original and stored hashes; `.gz` payloads restore exactly with `gzip -dc`.
Large generated C and compiler binaries remain in scratch with hashes retained
in construction/comparison records and the omission manifest. Small C is retained.

- `comparison.json` and `RESOURCE_REVIEW.md`: independently accepted resource proof.
- `baseline-commands.json`, `candidate-commands.json`: exact paired-stage construction
  and measurement commands. Actual stage2 provenance qualifies incidental raw
  `compiler_stage=1` for explicitly supplied retained binaries.
- `frozen-input.json.gz`: exact revision plus regenerated embedded std, independently
  checked after baseline and pinned throughout candidate phases.
- `fail-before/TEST_RUNNER_REPORT.md`: seven intended baseline failures.
- `final-validation/TEST_RUNNER_REPORT.md`: passing final gates and complete source guards.
- `implementation/`: exact reviewed source/test patches and construction pins.

Baseline and candidate use frozen revision
`8fe717e28d461088258f7744db77f2d9c8d02a0f`. Three normal samples per workload,
paired diagnostic allocations, whole C identity and exact 0.5% integer ceilings
were checked. Background work is permitted; no speed or quiet-window claim is made.
