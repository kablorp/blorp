# Filesystem decisions

`fs`, `io` and `system` became `io/fs`, `io/error` and `io/environment`
(the modules landing). The `Path` landing then replaced `io/fs` and `io/error`
with one module per operation under `io/fs/`, each owning an exact error union,
and made every operation take a `Path`. Names below are as written when each decision was made; the amendments say what
changed. `IOError`, `IOErrorKind` and `default_if_not_found` no longer exist.

This file records the decisions behind the `fs` library and the lent-resource
design that would follow it, so they outlive the plan they were made in. The
contract of each operation lives in the
[standard library README](standard_library/README.md#the-file-modules); this
file says why it is that way and what is still open. Every decision below was
approved by Keith on the date given, except those marked open or deferred.
`io.describe` below is history: `IOError` and `IOErrorKind` implement
`Stringable` instead.

## Where it stands

Part 1, the filesystem library, needs no language change. It has landed
through phase 2c:

| Phase | Content | Commits |
| --- | --- | --- |
| 1 | One `SystemCall` contract for every system builtin | `d49f3eec2` |
| 2a | `IOError`, `read_text`, atomic `write_text`, `entry_kind`; the compiler moved onto `fs` and the old `read_file` and `write_file` builtins were deleted | `5e6511ab5`, `2aa6f43b6`, seed `71bafb8ea`, `bb389b64a` |
| 2b | Listing, creating, removing and renaming; `remove_directory_tree`; `with_temporary_directory` | `41810bb15`, `9a606f6f6`, seed `75a68d4fa`, `61ebe7fa5` |
| D18 | A `write_text` path ending in `/` | `b00632782`, `ef34d216b` |
| 2c | Line natives and `fold_lines` | `6c973b3cd`, seed `073ad2a89`, `cc85d0506` |

Part 2, lent resources, is a language feature. It has not started and starts
only when a consumer needs it (see below).

Two rules shaped every landing. The compiler imports `fs` and is built by a
pinned earlier compiler, the seed, which rejects a builtin it does not know.
So a new native lands first, then the seed is replaced by a build that knows
it (a seed rotation, "seed" in the table), then the `fs.brp` code that calls
it. And each phase set cost ceilings before it started. One of them counts
the instructions the new compiler spends compiling the base commit's own
source, which separates the cost of the new code from the cost of a bigger
compiler; across phases 1 to 2c it may rise by at most 1.5% in total, and it
has risen by about 0.18%.

## Standing rules

- **R1, 2026-11-02.** Only Blorp's own standard library matters; there is no
  compatibility with the retired compiler's library.
- **R2, 2026-11-02.** A helper may borrow a resource, provided every rejection
  and limitation has a clear explanation.
- **R3.** Console output (`print`, `print_error`) is in the prelude; all other
  IO stays an explicit import. Amended 2026-11-10 from "IO stays an explicit
  import, and the prelude does not change". Amended 2026-11-11: each file
  operation is an explicit import of its own `io/fs/` module, and `Path` stays
  an explicit import too, because landing 8, which would have put `Path` and
  `to_path` in the prelude, was dropped.
- **R4, from the roadmap.** Paths stay `String`. Errors carry fixed text, never `strerror` text.
  A NUL in a path is rejected before the system call.
  Amended 2026-11-11 (the `Path` landing): operations take a
  `Path`, which cannot be empty or hold NUL, so no operation reports a NUL
  path; an error carries no path (`"${path}: ${error}"` is the caller's to
  write). Errors still carry fixed text.

## Part 1 decisions

**The C boundary**

- **D1, 2026-11-02, order.** Part 1 now, Part 2 only for a gated consumer.
  Callbacks remove the same failure classes for today's consumers with no
  language change.
- **D2, 2026-11-02, the contract.** `SystemCall`, with one match per compiler
  phase, replaces twelve hand-maintained label sites.
- **D3, 2026-11-02, typed results: Int codes.** Natives return Int codes,
  lists or Strings, and Blorp decoders turn them into kinds and entries, so
  the compiler knows no `fs` type. Since `23f25d7d3`, the error decoder lives
  in `_io_errors.brp`, shared with the process API (`PROCESS_DECISIONS.md`
  P4), while the entry decoder stays in `fs.brp`. The rejected option had the
  compiler own the `fs` enums, so both sides agreed by construction; for the
  same five operations the phase 0 spike measured +517 compiler lines and
  +2.0% self-compile instructions for it, against +141 and +0.64%. The cost
  is that the C codes and the decoders are two spellings of one table, kept
  in agreement by tests (D15); an unknown code decodes as `OtherOs` or
  `Other`, never a crash.
- **D17, 2026-11-03, listing.** The listing native returns kind-coded names:
  each element is one byte holding the entry code, then the name. One
  directory read gives names and kinds, and an entry is examined with `lstat`
  only where the directory entry gives no type, so on file systems that
  report types a listing costs no system call per entry. An entry removed
  while the directory is read is left out.
- **D37, 2026-11-05, reading lines.** The natives keep no state.
  `next_lines(descriptor, carried)` returns `[]` at the end, `[final]` for a
  last line without LF, or complete lines then the unfinished one, which
  `fs.brp` passes back in. Reads are 64 KiB blocks, growing only for a longer
  line, and at most three short reads keep the unfinished line whole UTF-8.
  Rejected: a C reader behind the Int, a slot table, byte reads and seeking.
- **D38, 2026-11-05, close.** `fs.close` returns `Result[Void, Int]`, and
  `with_descriptor` ignores it: a descriptor that was only read loses
  nothing when its close fails.

**Errors**

- **D10, 2026-11-03.** Named kinds replace numeric codes; a raw errno
  survives only in `OtherOs`.
- **D14, 2026-11-03.** An `IOError`'s `path` is always the path the caller
  passed. Naming the failing component would need an error payload carrying
  a String beside the code; revisit when a consumer needs it. Superseded
  2026-11-11 by the `Path` landing: errors carry no path at all, so a failure
  never says whether the path or one of its parents refused.
- **D34, 2026-11-04, the exception to D14.** When `with_temporary_directory`
  cannot remove its directory, the error names that directory, not
  `parent`: the body was given that path, and it is the only one that says
  what was left behind. A failure to create the directory still names
  `parent`. Superseded 2026-11-11 with D14: `TemporaryDirectoryError` names
  no directory, and the body's `Path` is the only name of it. Exceptions to
  "an error carries no path" no longer exist.
- **D15, 2026-11-03, testing codes.** An e2e example receives a directory
  that `prepare.sh` builds and provokes every reachable kind; a C test
  checks errno to code against numeric literals.
- **D8, 2026-11-03.** A file name that is not UTF-8 fails the whole listing
  with `InvalidUtf8` until a `Path` type exists, rather than silently
  skipping the entry. A `Path` is still UTF-8, so the rule stands until `Path` is byte-backed.

**Reading and writing**

- **D16, 2026-11-03.** No read size cap. Memory runs out first; a bounded
  read with a caller-stated limit comes when a consumer needs one.
- **D4, 2026-11-03, symlinks under `write_text`.** Write through the link:
  resolve the final target and replace that file in its own directory, so
  the link survives and the rename stays on one file system. A dangling link
  is `NotFound`, a loop `OtherOs`. Replacing the link instead would break
  dotfile managers.
- **D5, 2026-11-03, durability.** Ordering only: after a crash, readers see
  the complete old contents or the complete new ones. `fsync` on Linux,
  `F_BARRIERFSYNC` on macOS with `fsync` as the fallback, never retried after
  a flush error. Full durability (`F_FULLFSYNC`, milliseconds per file) comes
  later as a separately named call.
- **D6, 2026-11-03, observing system calls in tests.** Runtime C tests may
  rename system calls around the included runtime text and record or fail
  them, so production code carries no test shim.
- **D18, 2026-11-04, a `write_text` path ending in `/`.** One `stat` with the
  slash kept decides, by the mode: a directory or a link to one is
  `IsADirectory`, anything else `NotADirectory`, nothing `NotFound`, and
  nothing is created. `lstat` was tried first and broke on macOS 15, where a
  slashed link to a file resolves without ENOTDIR.

**Directories**

- **D9, 2026-11-04.** `remove_directory_tree` on a missing path is
  `Err(NotFound)`, for explicitness, although Go returns success.
- **D20, 2026-11-04.** Only a real directory is a root for
  `remove_directory_tree`; a file or a link, even to a directory, is
  `NotADirectory`, after trailing slashes are stripped.
- **D21, 2026-11-04.** A final `.` or `..`, and a `/` in a temporary
  directory's prefix, are refused as `OtherOs` before any system call.
- **D22, 2026-11-04.** The walk never crosses a device: a mount point in the
  tree, a root that is a mount point and `/` are `CrossesDevices`. The first
  failure stops the walk, and a directory moved during it is
  `ChangedDuringRemoval`.

**Callback operations**

- **D11, 2026-11-04.** Callback operations are generic in the callback's
  error type and take a pure converter from the operation's own error union
  (`IOError` when this was written; now `ReadError` for `fold_lines`,
  `TemporaryDirectoryError` for `with_temporary_directory`), as in
  `with_temporary_directory[T, E](parent, prefix, body, on_error)`; without
  it, an application with its own error union nests Results. A trait that converts
  an error union (named `FromIOError` then) would serve here and in Part 2 (D29), but a trait method's first
  parameter must be `Self` today. If that language change lands, the
  converter parameter goes, in a breaking change.
- **D39, 2026-11-05, `fold_lines`.** `fold_lines[T, E](path, initial, step:
  (T, String) -> Result[T, E], io_error)`; an `Err` from `step` stops
  reading and is the result, so reading a header does not read the whole
  file. A separate `Stop` variant waits for a consumer that needs one.
- **D40, 2026-11-05, collecting lines.** A pure String `lines()` with the same
  line rules, used as `read_text(path).lines()`, rather than an
  `fs.read_lines`. Built: `string.lines`, whose agreement with `fold_lines`
  the `fs/lines` example checks on every rule case. A List accumulator in
  `fold_lines` copies the list on every line, so collecting lines goes through
  `read_text`.
- **D13, 2026-11-05, a `Path` type.** Deferred. Reopen with `Bytes`, or if D8's error
  turns out to be common. Amended 2026-11-11: a `Path` type exists, a UTF-8
  spelling that is never empty and never holds NUL.
  The byte-backed form stays deferred.

- **`rename` and `IsADirectory`, 2026-11-11.** Renaming a file onto a
  directory fails with `EISDIR`, which is `IsADirectory` in `RenameError`.
  This case was missing from the decisions above; `RenameError` also has
  `NotFound`, `PermissionDenied`, `NotADirectory`, `DirectoryNotEmpty`,
  `ReadOnlyFilesystem`, `NoSpace`, `CrossesDevices` and `OtherOs`.

## Part 2: lent resources (not started)

A library scope opens a resource, lends it to a callback and releases it
when the callback returns, so users never open or close anything and a
leaked descriptor, a use after close, a double close and a shared cursor stay
impossible. Blorp will have no `with` block; scopes are callbacks.

It starts when a consumer needs two resources in lockstep (merging two files,
copying one into another while transforming it), an unbounded streaming
write, or an interactive process session or socket. Until then, two Part 1
operations cover the commonest cases without lending anything:
`rewrite_lines(source, target, transform)` and `write_lines(path, state,
next)`, each publishing its target by rename. Neither is built yet.

The approved shape, all 2026-11-04 unless noted:

- **D23, callbacks only,** with `rewrite_lines` and `write_lines` as above.
- **D24, D32, the declaration.** `resource type Reader = Int`, an opaque type
  only its declaring module can wrap or unwrap, with the existing
  `into_opaque` and `from_opaque`. There is no `releases` clause: the
  compiler never releases anything, and each module releases in one private
  helper, as `with_descriptor` does today.
- **D31, scoped callables.** A `scoped` parameter is called only during the
  callee's call, on the caller's task. A lambda capturing a resource or a
  scoped parameter is itself scoped, task bodies are never scoped, and
  scopedness is marked on the parameter only, not in trait requirements.
- **D12.** A user function may take a `scoped` body, so helpers compose
  scopes.
- **D35, no resource in a pure context.** A resource may not be a parameter
  of a pure function or a pure callable type, nor a capture of a pure lambda.
  Check rejects it where it is written.
- **D27, D33, serving.** `net.serve` is a scope with ordinary handler
  parameters, so no loop syntax is needed. A handler's `Err` ends that
  connection and goes to `on_error`; `serve` fails only when the listener
  does.
- **D30.** The release sees the body's outcome, by library convention.
- **D25.** `shareable` resources are deferred. **D26** was withdrawn, and
  **D28** (`?=` inside a `with` body) is moot.
- **D29, error conversion.** Decided together with D11, which chose a
  converter argument for now. Whether Part 2 uses such a conversion trait stays
  open until a trait method can take a first parameter that is not `Self`.
- **D7, open.** A test-only resource type and scope, so tests can count
  releases.

A resource may appear only as a whole parameter type and as a call argument,
never in a result, field, tuple or type argument, written or inferred. The
soundness review estimated about 40 parse lines and 250 to 350 Check lines,
with no ownership or specialization change.

## Later

- `append_text`, `copy_file`, a temporary-root query, `Bytes`, `Path` (D13)
  and full durability (D5).
- A consumer-driven `Stop` variant for `fold_lines` (D39).
- `read_text` copies its buffer into the String, so a large file peaks at two
  to three times its size.
- Run as root, the fs e2e examples cannot provoke `PermissionDenied` and are
  reported as not run, so a root-only CI would not test the decoders end to
  end.
- Binding a lambda to a local before passing it costs an allocation that an
  inline lambda does not.
