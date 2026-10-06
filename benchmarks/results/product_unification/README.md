# Product unification inputs

Retained inputs for the acceptance of the scalar replacement slice of
[`docs/PRODUCT_UNIFICATION.md`](../../../docs/PRODUCT_UNIFICATION.md).

`cursor_original_loops_managed.patch` applies to `blorp/src/lib/source.brp`
with `git apply`. It restores the per-byte `var cursor` / `source_advance`
reconstruction loops that the source-level scanner replaced (the reverse of
that change's `source.brp` edits) and spells `Cursor` as `record`, so the
inline fixed-record representation does not remove its allocations. Build one
stage-2 compiler from a frozen input with the patch and one without it; the
plan says how the pair is compared. Drop the `record` respelling from the
patch to run the `fixed record` control.
