# Compiler reader-cut evidence publication

These four packets are path-only publication projections of the exact original
evidence committed in `9ae3db857027202cc6c201abe76c6f3fc39592d6`. Their original
621 files are privately retained together in one Git archive, qualified by its
SHA256 and size in `PUBLICATION_MANIFEST.json`. The manifest maps every original
stored and decoded hash to its published stored and decoded hash. It covers all
public payloads except itself, preventing a self-reference cycle.

Projection replaces only home, worktree and per-user-temp path prefixes using a
deterministic longest-prefix rule. `<worktree:reader-cuts>` identifies the feature
checkout; other `<worktree:NAME>` tokens distinguish observed checkouts, including
background jobs. `<home>` preserves the remainder of other home paths. `$TMPDIR`
and `$TMPDIR_CANONICAL` distinguish the original temp spelling from its canonical
alias. Their physical equivalence was established by the original experiment;
publication does not rerun resolution or collapse dictionary keys. The private
prefix map is preserved outside Git, with per-rule prefix hashes in the manifest.
Shared `/tmp` paths are retained because they identify no machine user.

Measurement numeric values, raw sample order, timestamps, toolchain strings,
acceptance booleans and source, compiler, input and generated-C hash values are
unchanged. Unaffected payloads are byte-identical. Affected gzip files were
decoded, projected and recompressed with the original header timestamp; both
decoded and stored hashes are explicit. Compression does not hide local paths.

Old seal, controller, comparison, review and copy manifests remain historical
original-byte authorities. Their embedded hash fields were not rewritten to
pretend the projected metadata was measured. Such a field may no longer hash a
published JSON, report or controller: verify that public file using this new
manifest's `published` hash. Source/C/compiler hashes still identify the original
unchanged artifacts. Counts and byte totals in old delivery descriptions refer
to the original packets. Authored primary reports and packet READMEs add this
publication qualification; other historical reports retain their original claims
under this same qualification.

Historical Python controllers are evidence, mode 100644, rather than directly
runnable portable configurations. Measurements can be repeated with the maintained
benchmark harness and explicit locally configured inputs/paired compilers. The
public records support recomputing the recorded allocation totals, sample minima,
exact 0.5% ceilings and output hash comparisons. Replaying the exact historical
controllers requires the private originals and their role-root bindings.

No compiler source, tests, ABI, measurement samples, source/C/binary SHA values or
acceptance thresholds were changed by this publication step. There was no native
rerun and no new performance claim. `PUBLICATION_CHECKS.json` records structural
JSON/string-only checks, preserved embedded SHA256 values, decoded path scanning
and unchanged source/C/patch payload checks. Full original restoration is a private
archive verification; publication is explicit about that audit limitation.

The evidence-only [publisher](publish_evidence.py) reproduces this projection:
`python3 publish_evidence.py --archive ORIGINAL.tar --output PUBLIC_TREE --private
PRIVATE_METADATA`. Supply the privately retained original archive; the script
rejects other revisions, unexpected payloads, JSON key collisions and nonpath
record changes. It never edits a repository or reruns native measurements.
