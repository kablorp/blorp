# Workspace Rename

**Status:** Blocked on occurrence and visibility coverage

## Goal

Implement prepare-rename and rename as one exact workspace edit over a validated
current snapshot. The edit must update the declaration and all identity-equal
references, preserve deterministic URI/range ordering, reject collisions using
compiler-owned visibility, and fail closed if any relevant target is missing.

## Dependencies

Do not start implementation until:

- the existing semantic index supplies an opaque workspace-completeness proof;
- the semantic occurrence projection covers the requested category completely;
- the compiler exposes enough visibility to reject capture and collisions; and
- versioned workspace edits can be produced for open documents without racing
  the actor revision.

Top-level functions, globals, types, constructors, and fields are current
candidate categories. Locals, parameters, methods, traits, and foreign
declarations remain blocked until their identities and references are projected
completely. Supporting one category must not imply support for the others.

## Required Future Tests

The eventual issue must cover declaration plus usages across open and closed
files, unsaved overlays, same spelling with different identities, capture and
collision rejection, stale revisions, partial workspaces, UTF-16 edits,
overlapping-edit rejection, and exact diagnostic/error responses.

No worker may implement rename with textual search, reparsed name matching, or
best-effort partial edits.
