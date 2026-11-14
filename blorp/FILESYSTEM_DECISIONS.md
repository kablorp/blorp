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

Part 2, lent resources, has completed its compiler milestone S1. Streaming
copy is its consumer; native operations in S2 are next (see below).

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

## Part 2: lent resources (S1 complete)

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
never in a result, source field, tuple or type argument, written or inferred.
Compiler-created closure environments are different: they may carry resources
only while the closure remains scoped. The historical 40 parse / 250–350 Check
line estimate omitted inferred types and ordinary callable values; it is not
an implementation budget or evidence.

### Streaming implementation brief, 2026-11-13

**Status:** S1 lifetime checking is implemented and source-reviewed. Focused,
full, fixpoint, bootstrap and matched cost gates pass. No
streaming filesystem API is exposed yet. S2's native trust decision was
approved on 2026-11-14; its implementation follows S1.
Baseline: `26a3a4fe06a3193ffb082ff75d06bbb29d51c1a6`. The first consumer is
bounded-memory binary copy, including transformations and early termination.
This activates Part 2. The smaller Part 1 producer APIs are not prerequisites.
This brief owns the implementation, measurements and review record.
Before final gates the branch was advanced to `678b1df3b` (explicit fixed
compiler unions), then the S1 diff was restored without conflicts. Final gates
and matched costs use that current-main baseline; the original fail-first
record below remains tied to `26a3a4fe0`. ResourceError follows the new fixed
tag-union convention.

#### Problem and current code

`read_bytes` and `write_bytes` require whole values. `fold_lines` streams one
input, but cannot lend two file cursors or produce unbounded output. Its
borrowed accumulator must not become the foundation of bulk collection:
growing a List in it copies the accumulated prefix.

Today `standard_library/io/fs/read.brp:124` keeps a private descriptor alive
around an ordinary callback:

```blorp
private func with_descriptor[T, E](
    path: Path,
    use: (Descriptor) -> Result[T, E],
    on_error: pure (ReadError) -> E,
) -> Result[T, E]:
    opened ?= path.to_string().native_open_read()
        .map_err(decode_read_error).map_err(on_error)
    outcome = use(into_opaque Descriptor(opened))
    closed = native_close(opened)
    outcome
```

Publishing this descriptor as an ordinary opaque value would let callbacks
return it, or return closures that retain it after close. Opaque privacy alone
does not establish a loan lifetime. The compiler must reject those escapes
before a public reader or writer is introduced.

#### Public surface and syntax

Keep the existing `io/fs/read` and `io/fs/write` modules and error unions.
The first public surface is exactly these four operations and two resource
declarations; signatures below are proposed syntax, not available today.
The qualifier belongs after the parameter's colon, before its callable type.

```blorp
-- In io/fs/read. Construction/projection remain owner-module-only.
resource type Reader = Int

func with_reader[T, E](
    path: Path,
    body: scoped (Reader) -> Result[T, E],
    on_error: pure (ReadError) -> E,
) -> Result[T, E]:
    -- Open, call body with the directly wrapped descriptor, close, return outcome.
    -- The implementation retains the raw Int privately, never a local Reader.
    ...

func read_chunk(reader: Reader) -> Result[Option[Bytes], ReadError]:
    ...

-- In io/fs/write. The Int carries a private native transaction, not a file fd.
resource type Writer = Int

func with_atomic_writer[T, E](
    path: Path,
    body: scoped (Writer) -> Result[T, E],
    on_error: pure (WriteError) -> E,
) -> Result[T, E]:
    ...

func write_all(writer: Writer, data: Bytes) -> Result[Void, WriteError]:
    ...
```

`read_chunk` returns `None` only at EOF; `Some` is nonempty and may be shorter
than the named 64 KiB maximum. Bytes have no character or line boundaries.
An empty write on a healthy writer succeeds without a system write. After a
write failure, even an empty write returns the remembered error without a
system write. Reads and writes retry EINTR;
writes finish short writes and treat zero progress as an OS I/O error.

#### Lifetime rules and owning facts

This is a synchronous loan restriction, not linear ownership or a region
system. No destructor, cleanup instruction, dynamic validity check or new
runtime function-value representation is introduced.

1. `resource type` reuses nominal opaque identity and existing representation
   erasure. Initially it is nongeneric, with a resource-free representation.
   Only its module wraps/projects it. The owner module is trusted to lend a
   valid handle and close exactly once; the compiler cannot prove its native
   implementation correct.
2. A resource may be a whole impure function/callable parameter and argument.
   Reject resource local aliases, results, constants, source aggregates,
   opaque representations and explicit or inferred generic arguments.
   Callable parameter positions such as `(Reader) -> Void` are permitted;
   wrapping that type in a source aggregate does not evade the restrictions.
3. A scoped callable parameter may be invoked or forwarded to another scoped
   parameter. A closure capturing a resource or scoped callable is itself
   scoped, including captures forwarded through intermediate closures.
   Immutable local scoped-callable aliases are allowed. Scoped values cannot
   be results, aggregate children, mutable initializers/reassignments or
   ordinary call arguments. A match/if join preserves scopedness from every
   reachable value arm; inference never erases it.
4. Reject pure resource parameters and pure closures capturing resources,
   including inferred parameter types. No current task syntax exists; a
   future concurrency feature must reject these loans crossing tasks.
5. Passing one Reader twice to an impure helper is legal sequential aliasing.
   D24's earlier shared-cursor claim meant no escaped/shared-task cursor; it
   did not establish exclusive borrowing. Do not add an exclusivity system.
   Keith confirmed on 2026-11-14 that the intended rule is synchronous lending,
   with no concurrent access and no escaping handle.
6. Scoped promises exist on declared parameters, not trait requirements or
   general callable types. Converting a function to an ordinary callable
   deliberately forgets this stronger promise. Indirect calls must then
   reject scoped actuals; never recover permission from a retained function
   identity. Preserving that ability through callable types is deferred.

```blorp
func invoke(body: scoped () -> Void) -> Void:
    body()

func forward(body: scoped () -> Void) -> Void:
    invoke(body)                       -- accepted: synchronous forwarding

func during_read(reader: Reader) -> Void:
    read_more = func(): consume(reader) -- accepted immutable scoped closure
    forward(read_more)
    saved = invoke                    -- ordinary function value; promise erased
    saved(read_more)                   -- error: scoped callable may escape
```

Parser/formatter own `resource type` and parameter qualifier syntax. Check
owns resource identity, parameter promises and escape validation. Inferred
substitutions and lambda parameters must be checked once their types are
known, not just when an annotation contains the word Reader.

The parsed parameter keeps `scoped_qualifier: Option[Span]`, preserving the qualifier's
occurrence without a separate Bool and span. Resource membership is read from
the existing parsed opaque inventory by nominal identity; do not add a second
resource flag to accepted opaque rows merely for convenience.

Current source anchors: `src/common/syntax/syntax.brp:331,989`
(`ParsedParameter`, `ParsedOpaque`), `src/common/analysis/check/model.brp:164,188`
(`CheckedOpaque`, `FunctionSignature`) and `:938` (captures). Keep ordinary
`CallableType(Purity, List[TypeRef], TypeRef)` unchanged.

**Check representation:** `FunctionSignature` retains a sparse, ordered,
unique `scoped_parameters: List[Int]`; signature construction validates that
each position names a callable parameter. Ordinary indirect contracts always
have an empty list, regardless of the eventual stored/specialized identity.
Do not change `TypeUse` or `CallableType`.

After `resolve_body` completes a declared function and its lambda rows, before
`check_execution` rewrites self recursion or the checked function is published,
perform one Check-local admission of that typed body. Carry dense scopedness
facts for bindings and captures only during this admission. Visit statements
lexically. A scoped parameter seeds its binding fact; immutable initialization
preserves scopedness. A lambda is scoped exactly when a capture operand is
resource-valued or scoped; admit its completed body at construction with those
capture facts and typed parameters. Match bindings receive facts through
`EnterArm` / `CheckedPatternArgument` routes, including `BorrowPlace(MatchRoot)`;
value joins combine every arm's scopedness. Do not flatten these contexts
through `child_expressions`.

Reject scoped mutable storage, source aggregates, results and arguments
lacking the declared promise. Calling a scoped callee is legal; discarding
one is harmless. Distinguish a discarded value from an escaping return after
Void-tail normalization. Resource local aliases remain prohibited. Discard
admission facts before publishing Check's accepted products. No region graph,
scope flags in downstream IR, repeated fixed point or general analysis
framework. Validate recursive written resource type uses at declaration/type
resolution. Validate completed explicit/inferred generic actuals once at their
typed call/callable-reference nodes during admission, before Check publishes
anything. Final actuals and the opaque inventory first coexist there without
threading another declaration inventory through inference. Cover method and
named callable choices as well as ordinary calls.

#### Native reader and transaction ownership

Reuse `fs.open_read` and `fs.close`. Add one native chunk read returning
`Result[List[UInt8], Int]`; empty success maps to public EOF. This uses the
existing system signature algebra in `analysis/namespace/builtins.brp:487`.
Do not add Option/record native ABI support just for these operations.

Atomic writes reuse target resolution, temporary creation, metadata copying,
write-all, rename and directory flush in `codegen/runtime/fs.brp:268–490`.
The private manually owned C context avoids a global registry. Arbitrary user
modules may declare existing builtin labels
(see `test/test_compile/fixtures/fs/natives_open_read.brp`). A private Blorp
wrapper does not stop a user from declaring writer-discard with an Int
parameter and passing a forged pointer. The native representation below is
requires the explicit native declaration boundary approved below; never expose
these pointer-consuming labels without enforcing it.

**Decision, 2026-11-14:** Keith approved restricting all four new writer-context operation
variants to declarations whose loader-owned `ParsedModuleRow.role` is
`LibraryModule`. The configured library root is trusted compiler input;
choosing a replacement library explicitly changes that trust. Check reads
the sealed module role via the declaring ModuleId, never a path or spelling.
Existing builtin declarations keep their policy. S1 does not depend on this
rule. Acceptance must reject every restricted
label from a user module with exact message/help/span, accept genuine library
provenance, and preserve existing direct-native fixtures. A resource-typed
argument alone is insufficient: an attacker can declare their own resource.

```c
struct blorp_fs_writer {
    int descriptor;
    char *directory;
    char *target;
    char *temporary;
    int64_t first_failure; /* 0 is existing native success; otherwise real error */
};
_Static_assert(INTPTR_MAX <= INT64_MAX,
               "Blorp file writer handles require pointers representable by Int64");
/* Only successful begin creates this process-local carrier. */
int64_t handle = (int64_t)(intptr_t)writer;
/* Only this native family converts it back. */
struct blorp_fs_writer *writer = (struct blorp_fs_writer *)(intptr_t)handle;
```

Begin resolves once, creates the temporary, sets owner/mode, then transfers
the descriptor and path allocations into this context. Failure releases all
acquired state. One context allocation per writer scope is the expected cost;
measure it. Private native begin returns `Result[Int, Int]`; write borrows the
handle plus byte List; finish/discard each consume the handle and free all
state even on failure. No closed flag or public close/commit operation.

The library captures the callback result, then chooses exactly one finish
or discard call. It never uses `?=` between callback completion and cleanup.

| Event | Cleanup and result |
| --- | --- |
| Reader body completes | Close once, ignore close failure per D38, return body result. |
| Writer body returns Err | Close, attempt unlink, free context; preserve body error. |
| Write fails, even if caught | Remember first error; later writes return it without writing. Body Ok still cannot publish. |
| Writer body Ok | First write failure, otherwise file flush failure, otherwise close failure wins. Close once even after earlier failure. |
| Any failure before rename | No rename; attempt unlink; release all context state. Cleanup never replaces the primary error. |
| Rename fails | Preserve rename error, attempt unlink, free state. |
| Rename succeeds, directory flush fails | Return flush error; target has already been published, as today. |

Preserve current symlink resolution, dangling-link refusal, regular-file
checks, owner/mode rules and umask. Do not call close again after EINTR; retain
the existing platform contract. Resource checking protects callers only after
that native boundary is established; native
unit tests establish the trusted owner's cleanup and pointer-carrier ABI.

#### Several normal-main e2e examples

Add ordinary fixtures under `test/test_compile/fixtures/fs/`, registered by
`test/test_compile/fs.brp`. Tests use the normal entry point and actual files;
they do not call generated internal functions or rewrite emitted C.

1. **Binary copy:** nested reader/writer scopes copy empty, one-byte,
   exact-boundary and multi-chunk files containing NUL and invalid UTF-8.
   Compare complete output bytes; never hash through the implementation under
   test as the only oracle. Inspect/measure live native buffers on a larger
   file to show storage bounded by chunk size, not total input length.
2. **Transform/generate:** increment each byte with UInt8's wrapping addition,
   writing the transformed data in smaller slices, then generate repeated
   chunks without reading a whole input. The exact expected byte sequence is
   independent of physical read boundaries.
3. **Two readers:** compare independently chunked inputs with an explicit
   leftover buffer, consuming bounded slices of 17 bytes on one side and 31
   on the other, including equal data and a late mismatch. This proves nested
   composition and leftover handling, not differing kernel read schedules;
   deterministic physical short-read schedules belong to the native tests.
4. **Early stop/failure:** read a prefix and return Ok, or return a distinct
   application Err after writing. Repeated runs under a low descriptor limit
   prove cleanup; failed writes leave an existing target's bytes untouched.
5. **User helper and aliases:** forward a scoped body, invoke an immutable
   scoped local closure, and capture an outer Reader in an inner writer body.
   Observable output proves the actual callback order, not compilation alone.

Native helper tests, using the approved syscall-wrapper exception in
`test/test_common/test_codegen/test_runtime/fs_suite.brp`, inject short
read/write, EINTR, zero-progress write, partial-write-then-error, flush, close,
rename and directory-flush failure. Assert exact errors, call order, no rename
before successful close, stable first failure, and allocation/descriptor
balance. Catch-and-ignore-write-error is a mandatory publication test;
failed-then-empty writes must also preserve the first failure.

The application code stays within current control-flow syntax. `?=` remains
top-level; it is not added to loops or lambda bodies by this work. A small
named function handles one transfer step:

```blorp
union CopyError:
    ReadFailed(ReadError)
    WriteFailed(WriteError)

func copy_step(reader: Reader, writer: Writer) -> Result[Bool, CopyError]:
    chunk ?= read_chunk(reader).map_err(pure func(error): ReadFailed(error))
    match chunk:
        None: Ok(False)
        Some(data):
            write_all(writer, data)
                .map(pure func(_): True)
                .map_err(pure func(error): WriteFailed(error))

-- copy_chunks loops over copy_step using explicit Result state; no growing
-- borrowed accumulator. Its application Err stops subsequent reads/writes.
func copy_file(source: Path, target: Path) -> Result[Void, CopyError]:
    with_reader(
        source,
        func(reader): with_atomic_writer(
            target,
            func(writer): copy_chunks(reader, writer),
            pure func(error): WriteFailed(error),
        ),
        pure func(error): ReadFailed(error),
    )
```

#### Milestones, gates and ceilings

Every landing needs two independent approvals: code-reviewer and test-runner,
with parser/ergonomics input before S1 and documentation review afterward.
The coordinator owns the compiled-job lease; no parallel compiler gates.

| Milestone | Bounded deliverable and release order |
| --- | --- |
| S1 | Review the Check representation above. Add rejection tests first, then resource/scoped parsing, formatting, declaration/inferred-type validation and closure escape checking. Add a synthetic owner-module resource scope for observable callback order. No public fs handle yet. |
| S2 | Enforce the approved library-only writer-builtin boundary; add native chunk read and atomic transaction operations, plus signature/emission and fault tests. Keep old bulk helpers correct; share lifecycle internals only if independently proven semantics-preserving. No library use of new syntax or labels yet. |
| S3 | Publish/pin a qualified seed carrying S1/S2. Then introduce library Reader/Writer and all five e2e examples. A clean pinned-seed build and fixpoint must pass. |
| S4 | UTF-8 decoder with at most three pending bytes and count, then text/line adapters as a separately reviewed increment. Preserve failed-batch and CRLF semantics. Bulk convenience migration follows only with an efficient accumulator and measured peak memory. |

S1 rejections check exact message, help and span: direct return, inferred local
resource alias, each aggregate/opaque/type-argument escape, inferred generic
identity, pure written/inferred lambda parameter, pure capture, closure return,
ordinary indirect argument, mutable scoped storage, transitive capture, and
match-binder/if/propagation laundering. Match capture bindings must preserve
the scoped fact; rejection of scoped `Ok`/`Some` payload construction prevents
laundering through propagation. Positive counterparts include direct calls,
qualified/UFCS calls, forwarding, immutable aliases, nested scopes and branches.
For erasure, direct `invoke(read_more)` passes while `saved(read_more)` fails.
Trait requirements may not declare scoped parameters in this increment.

Start with the relevant parser/checker TestSuites via:

```sh
make -C blorp compiler
make -C blorp test-target-components TARGET_COMPONENT_SOURCES='<changed suite paths>'
make -C blorp test
scripts/blorp-fixpoint --prove
bash blorp/test/test_bootstrap/test_bootstrap.sh
```

Register each new suite in `test/driver/driver.brp`. Update README, grammar and
formatter with syntax; update `standard_library/README.md` with public APIs.
Prove representative negative oracles by temporarily breaking the protected
check, and native fault oracles by disabling failure recording/cleanup.
Run sanitizer and strict-leak cases; inspect emitted C for the copy and closure
examples. Existing behavior, leak, platform and bootstrap failures block.

Initial ceilings, set before implementation: S1 production at most 1,100
added / +900 net lines, tests 1,500 added / +1,400 net; S2 production 600
added / +450 net, tests 900 added / +800 net; S3 library production 200
added / +180 net, tests/examples 700 added / +650 net. Documentation is
reported separately. These are limits, not targets. Reassess architecture if
S1 needs new general callable types, a lifetime graph or codegen scope flags.

Routine coordinator correction, 2026-11-14: S1's net test ceiling changes
from +1,400 to +1,500; gross stays 1,500. The formatted candidate measures
1,465 added / 8 deleted / +1,457 tests, including the complete diagnostic
matrix and native/formatter fixtures. No coverage or formatting is compressed.
An earlier provisional +950 net production allowance is withdrawn: removing
duplicate validation brought production to 931 added / 33 deleted / +898,
inside the original 1,100 / +900 ceilings. Cost ceilings and architectural
scope stay unchanged; this uses the standing delegation for routine corrections.

For every compiler milestone, matched serial runs of
`blorp/scripts/self-compile-cost BASE CANDIDATE --rounds 3 --output <ignored-dir>`
cover fixed input and own source. Freeze source, seed, compiler flags and
library; preserve raw samples and C hashes. The tool uses each revision's own
pin: at S3, qualify one common new seed and use local measurement snapshots
with that same pin on both sides for implementation attribution. Record their
exact revisions and pin-only differences. Separately report the original
pin-to-new-pin delta and run the ordinary pinned-seed bootstrap gate; do not
attribute a seed change to this feature. Whole-source allocations and
normal retired instructions each have an initial +3% ceiling against that
milestone's fixed base, with peak heap reported separately and a +5% ceiling
when available. Investigate repeatable growth at its owning phase. No claim
that these measurements have run yet. The coordinator records any routine
ceiling correction here with old/new values and evidence, never silently
changes expected outcomes or calls a cost failure a pass.

#### Scope, risks and handback

No seeking, append/direct writes, configurable buffering, general stream
traits, async operations, `with` statement, cancellation framework, full region
inference, native aggregate ABI or global resource registry. Signals, OOM and
process abort remain outside library callback-cleanup guarantees. Three-byte
UTF-8 carry does not bound an unfinished line or an intentionally collected
whole-file value. Do not refactor bulk collection in S1–S3.

Before each implementation handoff, provide the frozen base, exact files,
approved model, first failing test and gate commands. Return the diff, review
verdicts, gate counts/failures, generated-C inspection, production/test line
counts and matched cost record. Stop and report an escaping loan witness,
unexpected native ABI expansion, need for a new ownership representation,
compiler miscompilation or exceeded architectural scope; do not work around
these with a registry, spelling heuristic or unchecked public handle.

Review record: revision 2 includes the completed-body Check admission and
the native trust-boundary blocker. The checker/parser reviewer
(`scoped_checker_design`) and API/native reviewer
(`streaming_io_design_review`) both approved S1 and its initial scaffolding,
with zero blocking/high/medium findings. Reviewed document SHA256:
`6cb523f88c3dc33ad62cbe34fb88d5dcdc16faed11a8a0f5b597257d65e3a13f`
(before this approval record was added). Keith approved S2's library-only
writer-builtin boundary on 2026-11-14. Both reviewers rejected the unsafe
unrestricted raw-Int boundary. S1 source, functional and matched cost reviews
are approved; S2 is next.
The parser/formatter/documentation slice subsequently received independent
approval with zero remaining findings after fixing reserved-field names
(`resource_type`, `scoped_qualifier`) and compact `scoped()` grammar parity.

Fail-first evidence: at baseline `26a3a4fe0`, pin `blorp-seed-d62b0aacb2f1`,
`make -C blorp compiler` succeeds. The new `test_resource_scopes.brp`, selected
with `test-target-components`, compiles and runs: 0 pass / 4 fail, with zero
reported leaks. This establishes unsupported-feature failures, not yet
isolated escape-check sensitivity. The log is
`build/streaming-io-2026-11-13/failing-resource-scopes.log`. Baseline compiler
SHA256: `cee83c836319ac56afb47d371a852b81453826182f14880a38a62d4d191e6b5d`;
diagnostic compiler: `8da1aa18682c633681a2c8d89dac6802b87777462f6a4ef40eff7a10c23d4f69`.
Implementation source and functional reviews are approved. Measurements below
complete qualification; no planning-only commit is published.

Integrated S1 evidence, base `678b1df3b`: fresh pinned-seed build passes;
independent focused selection passes 149 leaf callbacks. `make -C blorp test`
passes 1,797 component callbacks across 24 directory programs and 1,065
native/runtime/e2e callbacks across 19 suites, with zero failures. The synthetic
resource fixture passes the standard harness; all 27 visible leak reports
have zero leaks. The earlier sanitizer-run C and its repeated emitted C are
byte-identical. Mutation oracles fail 24/58 cases with admission disabled and
exactly 1/58 with only inferred-container validation disabled, then sources
were restored byte-for-byte. Logs: `build/streaming-io-2026-11-13/s1-worker/`
and `build/streaming-io-2026-11-13/test-runner/`. Final-base source review has
zero findings. Independent fixpoint proves B/C compiler-source identity,
742/742 A/B fixture comparisons, and the same component/native suites under
the self-built B compiler. Bootstrap tooling passes 38/38. The fixpoint script's
"first native" / "broader DEFERRED" labels are stale relative to its current
ordinary `test-e2e` invocation; the actual B logs contain all 1,065 selected
native callbacks. Per-file source-parse inventory is not run by that script.
Default gates do not enable per-fixture retired-instruction ceilings; the
separate matched whole-source measurement below owns the feature cost gate.
Independent functional review is approved.

## S1 qualification: matched cost record, 2026-11-14

Base `678b1df3b46f9c9efcfeb1705e7b3eb8cd6bdf67`; candidate
`72e1804fe922a629a70e529f5c3c7f7a0c904b7f` (subsequent qualification-record
edits change documentation only). Both pins are `blorp-seed-d62b0aacb2f1`,
source `d62b0aacb2f13193221ea85de62db6d1fc7f1bb8`; ARM64 artifact SHA256
`9345b8ba1fd8fa470e1c11b45b4026a88c1eb6b8aa46c19ef7b5c7282f51de84`.
Host: Darwin 25.6.0 arm64; Apple clang 21.0.0 (clang-2100.3.34.2).

```sh
blorp/scripts/self-compile-cost 678b1df3b46f9c9efcfeb1705e7b3eb8cd6bdf67 \
    72e1804fe922a629a70e529f5c3c7f7a0c904b7f --rounds 3 \
    --output build/streaming-io-2026-11-13/cost
```

Serial Makefile builds from the same seed use `-O2`, with memory diagnostics
off for `/usr/bin/time -l` instruction samples and on for strict allocation
runs. Executables are each snapshot's `blorp/build/compiler-cost/compiler`
and `compiler-diagnostic`; the tool removes those worktrees afterward and does
not retain executable hashes. Their provenance is the frozen revisions, seed,
toolchain and build recipe, not a retained binary. All four strict runs have
balanced allocations/releases and zero leaked bytes. Fixed input uses the
base source/library for both executables; own source uses each snapshot's.

| Metric | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed-input allocations | 13,824,467 | 13,828,464 | +0.0289% |
| Fixed-input peak heap, bytes | 166,693,688 | 166,910,819 | +0.1303% |
| Fixed-input instructions, median of 3 | 12,211,763,450 | 12,222,050,799 | +0.0842% |
| Own-source allocations | 13,824,467 | 14,047,729 | +1.6150% |
| Own-source peak heap, bytes | 166,693,687 | 168,688,360 | +1.1966% |
| Own-source instructions, median of 3 | 12,203,905,206 | 12,396,280,162 | +1.5763% |

Fixed-input emitted C is identical, SHA256
`3c078367dfbd34b5b8b345fa5b5b6773ed4fcf04f84c5401c3b5445d24e80616`.
Every allocation/instruction comparison is within +3%, and peak heap within
+5%; no cost exception is needed. Production is +898 net lines and tests
+1,457, reported separately above. Raw samples, C outputs and `report.txt`
remain under the ignored output directory. These local measurements do not
claim elapsed-time improvement or platform qualification.

The measured source subtrees are `blorp/src`
`cf9b172c0a0cfa02c4e9101d911401331604ace8`, `blorp/standard_library`
`73bcddd03cf0d94ee9c6c12ee329146f22812297`, and `blorp/scripts`
`df11d712c24e5e0bde7eb4ac7ea247df675c5e20`. The documentation-only qualification
amendment preserves them; reproduce using the published S1 revision with those
subtrees in place of the pre-amendment measurement revision above.
Final code-reviewer and independent test-runner qualification approvals both
have zero remaining findings after correcting stale status text.

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
