# Loader source snapshots

Status: approved by Keith as built on 2026-11-09. The mechanism landed as
`b05d0876c`, and review fixes landed as `82e82b591`. Before that approval no
plan covered it. This record is that approval.

## What was approved

Language-server work needs the compiler to check a file's unsaved text, not
the copy on disk. A caller passes frozen contents to the loader:

```blorp
load_program_with_sources(root_path, library, sources)
```

Here `sources` is a list of `SourceFile` rows, each a path and its contents.
`blorp/README.md` (the Load phase) gives the exact rules, and
[`blorp-source-snapshots-2026-11-09.md`](../benchmarks/results/blorp-source-snapshots-2026-11-09.md)
gives the costs.

- **One map.** Paths are normalized the same way loading normalizes them,
  and they key one checked map. The map is the opaque `SourceOverrides` in
  `compile/load/load.brp`, so a key is always a normalized path. There is no
  cache, no editor state and no second resolver.
- **Rejected before loading:** duplicate normalized paths, and caller paths
  that contain NUL. Both reject through `SourceLoadFailure`.
- **Supplied contents win.** They are authoritative for every file-backed
  module, including empty or malformed text. They also apply to a
  `--library-root` library's modules, its foundation and its prelude.
- **The embedded library keeps its own contents.** An override for it has no
  effect.
- **Accepted, and documented in the README:**
  - **Unused overrides.** Rows for paths that are never loaded, or that lie
    outside the root, are accepted without comment.
  - **Case.** Keys are lexical and case-sensitive, so `A.brp` and `a.brp` are
    distinct even on a case-insensitive filesystem.
- **The older loading entry points** pass an empty map to the same core and
  keep their `LoadFailure` result.

## Later

The next LSP step exposes module analysis without a required executable
entry point (`blorp/NEXT.md`). Editor state and transport stay outside the
compiler pipeline.
