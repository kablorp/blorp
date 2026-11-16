# Filesystem decisions

`fs`, `io` and `system` became `io/fs`, `io/error` and `io/environment`
(the modules landing). The `Path` landing then replaced `io/fs` and `io/error`
with one module per operation under `io/files/`, each owning an exact error union,
and made every operation take a `Path`. Names below are as written when each decision was made; the amendments say what
changed. `IOError`, `IOErrorKind` and `default_if_not_found` no longer exist.

This file records the decisions behind the `fs` library and the lent-resource
design that would follow it, so they outlive the plan they were made in. The
contract of each operation lives in the
[standard library README](standard_library/README.md#the-file-modules); this
file says why it is that way and what is still open. Every decision below was
approved by Keith on the date given, except those marked open or deferred.
`io.describe` below is history: `IOError` and `IOErrorKind` implement
`Stringable` instead. On 2026-11-15, the public `io/fs/` directory became
`io/files/` at Keith's request; private `fs.*` builtin labels and native
operation identities retain their names.

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

Part 2 has completed S1 checking, S2 natives and S3 public byte streaming.
The qualified seed is pinned; Reader/Writer scopes and the public io/files
namespace pass final proof and cost qualification. S4 text adapters are next.

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
  operation is an explicit import of its own `io/files/` module, and `Path` stays
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

## Part 2: lent resources (S3 complete)

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
Baseline: `26a3a4fe06a3193ffb082ff75d06bbb29d51c1a6`. Consumer:
bounded-memory binary copy, transformations and early termination.
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

Today `standard_library/io/files/read.brp:124` keeps a private descriptor alive
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

Keep the existing `io/files/read` and `io/files/write` modules and error unions.
The first public surface is exactly these four operations and two resource
declarations; signatures below are proposed syntax, not available today.
The qualifier belongs after the parameter's colon, before its callable type.

```blorp
-- In io/files/read. Construction/projection remain owner-module-only.
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

-- In io/files/write. The Int carries a private native transaction, not a file fd.
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
Other builtin declarations keep their policy; the S2 brief below extends the
same boundary to raw reader-descriptor operations to honor the no-manual-close
requirement. S1 does not depend on this rule. Acceptance must reject every restricted
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
are approved; see S2 below.
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

## S2 native implementation brief

**Status:** implementation, source review, functional and matched cost gates
pass. Base is published
S1, `2b36404cd3418d2f8a1072645afcffb5c3f3e73f`. The S1 lifetime rules and
transaction/error contracts above remain authoritative. This increment adds
native mechanisms; public library scopes wait for the S3 seed rotation.

### Native declaration access

Keith clarified that lending is synchronous, handles cannot escape, and
application code has no manual close operation. The coordinator applies the
approved library-only native rule to the complete raw-handle family: existing
`fs.open_read`, `fs.next_lines`, `fs.close`, new `fs.read_chunk`, and the four
new writer-context operations. Otherwise an ordinary user declaration of an
old raw builtin bypasses the scoped interface. Other existing builtins retain
their rules. This is the same module-role check, not a new authority mechanism.

Check obtains the declaring function's existing loader-published ModuleKind
by ModuleId. Only LibraryModule may declare these operations. Reject at the
builtin occurrence with an exact message/help/span; never grant authority
from a path, prefix, function name or opaque representation. The explicitly
configured library root is trusted. Keep permission facts out of codegen.

The primitive contracts are:

```blorp
-- Proposed private labels; S3 library wrappers, not application declarations.
func native_read_chunk(descriptor: Int) -> Result[List[UInt8], Int]:
    builtin("fs.read_chunk")
func native_writer_begin(path: String) -> Result[Int, Int]:
    builtin("fs.writer_begin")
func native_writer_write_all(handle: Int, data: List[UInt8]) -> Result[Void, Int]:
    builtin("fs.writer_write_all")
func native_writer_finish(handle: Int) -> Result[Void, Int]:
    builtin("fs.writer_finish")
func native_writer_discard(handle: Int) -> Result[Void, Int]:
    builtin("fs.writer_discard")
```

Names are represented by closed SystemOperation variants after parsing. All
five use the current primitive SystemSignature algebra, impure borrowed
parameters, and fresh success/error payloads. No native record ABI is added.

### One writer lifecycle

The current `runtime/fs.brp` has `blorp_fs_write_target`, prepare/metadata
helpers, `blorp_fs_write_all`, `blorp_fs_fill_temporary`, `blorp_fs_replace`
and `blorp_fs_write_path`. Extract one private transaction lifecycle instead
of keeping a second full implementation for streaming.

The transaction struct above owns its descriptor and allocated pathnames.
Core preparation, writing, finish and discard operate on a pointer to that
struct; consuming finish/discard release its contents. Storage ownership is
separate: the existing whole-file C operation can keep the struct on its
stack, while native writer-begin allocates it for a multi-call scope and the
native finish/discard wrapper frees that allocation. Both use the same state
transitions and error precedence. There is no registry or closed-state flag.
Private discard reports the first sticky write error, otherwise the close
error, otherwise the unlink error, and always frees state. The library ignores
that private cleanup result when preserving the body's Err. Transfer resolved
target paths only after successful resolution: the existing resolver releases
its path on failure, so cleanup must not release that dangling value again.

Use the existing allocator/release instrumentation for every owned allocation.
Preserve old bulk write behavior with the existing syscall-fault suite before
adding streaming cases. Reuse target resolution and mode/owner rules exactly;
resolve once before lending, never again at finish. Sticky first write error
blocks publication even if the body catches it; subsequent empty writes also
return that error. Native wrappers expose no callable/cleanup representation.

Byte reads request at most the named 64 KiB limit, retry EINTR, return a short
nonempty success immediately, and return an empty List only at EOF. Fill a
fresh concrete UInt8 List buffer directly where the existing allocation helpers
permit; free it on EOF/error. Never decode UTF-8 here or accumulate input.

### Work split, tests and acceptance

Runtime worker owns `src/common/codegen/runtime/fs.brp` and direct-runtime C
probes/Blorp test suite. Compiler worker owns closed operation names/signatures,
module-role admission, emission requirements, native fragments wiring and
language/API documentation. Agree on exported fragment/function names before
editing. Both review this seam first; the coordinator authorizes implementation
after two approvals. Compiled gates remain serialized under one lease.

Add failing cases before code: genuine library declarations accept the exact
contracts; user declarations of every raw-handle label reject even with valid
types, harmless names or a fabricated resource type. Convert the old direct
user raw-native positive fixtures to exact permission rejections; preserve
positive runtime coverage through existing ordinary `fold_lines` execution
and the approved direct-C exception, not a production privilege bypass.

Native probes cover healthy/empty/short/EINTR reads and writes, zero progress,
first-error persistence, metadata/begin failures, body discard, flush/close/
rename/directory-flush failure, symlinks/modes, and balanced descriptors/memory.
Test each operation's required fragment under strict C warnings; new writer
operations must request the existing write prelude on macOS. Demonstrate a
sticky-error mutation would publish or change the observed error, and that
the test fails. No public Reader/Writer declarations or library use of new
labels may land before the qualified seed knows them.

Run focused native-contract/runtime suites, full tests and fixpoint, then the
same matched cost tool and +3% allocation/instruction / +5% peak ceilings.
Existing S2 line ceilings remain 600 added / +450 net production and 900 /
+800 tests, reported separately; warn the coordinator before exceeding them.
Record corrections and measured costs here, without compressed formatting or
deleted coverage. Two independent code/test reviews are required before commit.
Return exact diff, gate counts, generated-C inspection, fault/oracle evidence,
line counts, cost provenance and lease state. Stop for a new ABI, ownership
representation, registry, permission authority or a lifecycle counterexample.

Early approvals: `streaming_native_runtime` and `streaming_native_contracts`
both approve the shared lifecycle, primitive ABI, role-based permission boundary
and existing test seams, without a new ownership representation or registry.
Exports agreed: FS_WRITE_RUNTIME, FS_WRITER_RUNTIME,
fs_writer_write_all_runtime and fs_read_chunk_runtime. Permission is checked
once before free/implementation/default-function dispatch in resolve_function,
using the immutable module row; no role field is added to downstream products.
The combined forecast was 325–430 added production lines and 730–960 test
lines. A provisional 1,000 / +900 test allowance was unused and is withdrawn:
actual production is 219 added / 37 deleted / +182 and tests 854 / 94 / +760,
inside the original 600 / +450 and 900 / +800 limits. No scope or cost
exception is needed.

The independent code-reviewer reports zero findings. Fresh build and focused
139 callbacks pass; full tests pass 1,801 component callbacks across 24
programs and 1,073 native/runtime/e2e callbacks across 19 suites. Native probes
pass 120/120 with strict C warnings, ASan/UBSan and strict zero-leak reports.
The sticky-error source mutation fails exactly 1/120, and the permission
mutation fails three authority callbacks; both sources were restored
byte-for-byte and revalidated. Input path/byte storage is released before
later writer operations in the native probes. Fixpoint proves a.c/b.c/c.c
output identity, 742 A/B fixture comparisons, and the full component/native
suites under B; seed.c is a distinct artifact, not a fourth equal generation.
Bootstrap tooling passes 38/38. Independent functional review approves all
1,330 frozen inputs. Logs live under `build/s2-native/` and
`build/streaming-io-2026-11-13/{s2-contracts,s2-test-runner}/`.

For S2 the fixed-input generated C is expected to change in the shared native
filesystem helpers: bulk writes now use the common writer lifecycle. Inspect
and bound that diff; do not apply S1's byte-identical-C criterion to an intended
runtime change. The preserved bulk fault tests and new native probes own its
behavioral equivalence. Allocation/instruction/peak ceilings stay unchanged.

## S2 qualification: matched cost record, 2026-11-14

Base `2b36404cd3418d2f8a1072645afcffb5c3f3e73f`; candidate
`7261a269dfe85075bad1f216e25e9938620086e0`, before documentation-only
qualification amendment. Same pinned seed, Darwin arm64 host and Apple clang
21.0.0 as S1. Serial builds use `-O2`, normal binaries for three alternating
`/usr/bin/time -l` samples and diagnostic binaries for strict allocation/peak
runs. All four strict runs have equal allocations/releases and zero leaks.

```sh
blorp/scripts/self-compile-cost 2b36404cd3418d2f8a1072645afcffb5c3f3e73f \
    7261a269dfe85075bad1f216e25e9938620086e0 --rounds 3 \
    --output build/streaming-io-2026-11-13/s2-cost
```

| Metric | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed-input allocations | 14,047,729 | 14,047,729 | 0.0000% |
| Fixed-input peak heap, bytes | 168,687,929 | 168,689,604 | +0.0010% |
| Fixed-input instructions, median of 3 | 12,390,751,585 | 12,387,995,619 | -0.0222% |
| Own-source allocations | 14,047,729 | 14,071,697 | +0.1706% |
| Own-source peak heap, bytes | 168,687,928 | 169,026,667 | +0.2008% |
| Own-source instructions, median of 3 | 12,377,529,499 | 12,397,596,954 | +0.1621% |

All comparisons pass +3% allocation/instruction and +5% peak ceilings; no
exception is needed. The small instruction decrease is not a speed claim.
Fixed-input C differs in exactly three diff hunks: the descriptor-helper caller
comment and replacement of the old atomic-write helpers by the common writer
lifecycle. No other C differs. Base C SHA256 is
`2ead6c8aca0ce5551e83cdafce7f6c5bc42cd81e8b56f91b89d6747b55019918`;
candidate is `0249025ce6bf4d5df35dacf3dd8acd5337595de4dd45f29fae61e128a96427de`.
The complete diff is retained as `fixed-input.diff` alongside all raw samples
and `report.txt` under the ignored output directory. Native fault tests and
sanitizers establish the intended runtime change's behavior.

The measured `blorp/src` tree is
`5b0c6e4ef58bbd43c266b7d2fe30d809ace7e4ef`; the standard-library and scripts
trees are unchanged from S1's record. Final documentation amendments preserve
these source inputs; reproduce with the published S2 revision sharing those
trees. As in S1, the tool removes its temporary binaries; binary provenance is
the frozen source/seed/toolchain/recipe, not a retained executable hash. Local
qualification does not claim remote platform qualification or per-fixture
retired-instruction gates, which remain disabled by default.
Final code-reviewer and independent test-runner qualification approvals both
report zero findings. Source inputs remain unchanged after qualification edits.

## S3 public API implementation brief

**Status:** overlay prototype passes; qualified S2 release and pin verified;
public integration and final qualification pass. Base is `93798484557cc60d060121f4e11763c4f453836d`. Source
reviewers inspect the concrete overlay before porting; final integration still
requires independent code/test approvals and the standard gates.

The public surface is the four operations already specified above, in the
existing read/write modules. Promote the read module's private Descriptor to
resource Reader and with_descriptor to with_reader; fold_descriptor becomes
fold_reader. The two line-fold step parameters become scoped so captured
Writer/Reader callbacks compose. Preserve line batching, CRLF/error behavior
and the borrowed-accumulator caveat. Do not retain parallel descriptor types
or duplicate open/close scopes. Writer uses S2 begin/write/finish/discard with
a private raw Int, directly wrapped only for its body argument. Capture the
body result, then match it to exactly one consuming finish/discard; body Err
prevails, and native sticky write errors still prevent publication after Ok.

Port the two reviewed overlay modules; no compiler model changes or new
library collection/text features. Publish and verify the three-platform S2
seed first, then change its release tag, source commit and three digests
together in bootstrap.env. Existing compiler sources and generated embedded
library must build with that pin before the public APIs land. No hidden host
override or fallback is introduced. Documentation describes all four APIs,
generic error conversion, synchronous/no-escape semantics, byte chunk bounds,
atomic publication and postrename directory-flush errors, plus no manual close.

Retain six normal-main fixture families under the ordinary e2e harness:
binary copy; chunk-independent transform/generated output; two-reader compare
with 17/31 logical windows and offsets; early Ok/application Err under a low
descriptor limit with target preservation; immutable scoped alias/forwarding
with outer Reader captured by inner Writer. Share only the transfer helper
actually used by several examples. Current supported annotations/control-flow
syntax is sufficient. Also exercise returned chunk data after its Reader scope
ends, since Bytes is owned data, not a loan.
The sixth family folds lines into an outer Writer: success publishes normalized
lines; a step Err stops further callbacks and discards output. Compare unequal
lengths in both orders, including empty/nonempty, to protect EOF handling.

Generate known bytes independently through existing prepare-script conventions
and compare complete output; no compiler-internal entrypoint or rewritten C.
The bounded-memory copy child only copies; verification runs outside that
process. Measure a small multi-chunk file and a larger file to show peak does
not scale with total size. Kernel short-read scheduling and sticky/fault
injection remain owned by S2's native probes; the two-reader fixture does not
claim to force kernel boundaries. Use independent expected exit/output/content
oracles and retain both successful and failed-scope cleanup checks.

The ignored prototype is at
`build/streaming-io-2026-11-13/s3-draft/REPORT.md`, with formatted library
overlay, normal-main examples, preparation scripts and a final source manifest.
All six families passed sanitizers/strict leaks. A 16 MiB copy peaked at
66,264 requested heap bytes versus 66,273 for a 327,681-byte copy. Library
changes are 93 added / 19 deleted / +74 net; examples are 490 lines. These are
prototype observations, not the final pinned-seed qualification.

One exploratory activation pair saw +0.5505% allocations and +0.8310%
instructions with identical compiler C; no model optimization is justified.
The pair used different library argument lengths and did not freeze exact
pre-format overlay hashes. Final measurements must use frozen matched
revisions under one qualified new seed, with seed-only and library deltas
distinguished, not reuse this prototype pair as acceptance evidence.

Acceptance: fresh pinned build; existing fold_lines suites and all new fixtures
under the ordinary driver; full tests, fixpoint and bootstrap shell checks;
native sanitizer/strict accounting; emitted-C scope ordering/ownership review;
matched allocations/instructions/peak within the existing +3%/+3%/+5% limits.
S3 ceilings are 200 added / +180 net production and 900 added / +875 net
tests/examples, documentation separate. The test ceiling corrects the initial
700 / +650 forecast before porting: six complete fixture families, shared
strict-report parsing and independent whole-file/peak oracles forecast
802–827 added / +795–820 net lines. No coverage is removed to fit the estimate. After porting, the formatter
expanded readable fixture registration beyond the forecast: tests/support
measure 877 added / 12 deleted / +865 net, including the strict-path helper
and report-parser tests. The routine net correction from +850 to +875
accommodates that observed formatting; gross remains 900. No compressed
formatting or production scope change is used to fit a line counter. No unrelated test deferral, std feature,
scope inference redesign or collection refactor. Report an actual gap before
expanding scope. Root serializes compiled gates and owns publication.

Handback: exact source/pin provenance, diff, line counts, gate counts and
failure table, complete-byte/peak-memory evidence, C inspection, problems not
fixed, review verdicts and compiled-lease state. Keep draft artifacts ignored;
carry this brief with reviewed implementation, not a planning-only commit.

### S3 qualified seed

Release `blorp-seed-93798484557c` binds source
`93798484557cc60d060121f4e11763c4f453836d`. All four platform gates and
three seed jobs succeeded in run `43682846127`. All three binaries and
provenance archives match release SHA256SUMS; provenance source and compiler-b
bindings match, with reproduced compiler C hash
`83b6dde30aa6c2bc3f64bfb834028d69bdafb9ae85fe31c9fc840a1313d3e135`.
The pin changes tag, source and all three binary digests together. A fresh
pinned build and 38 bootstrap checks pass before changing the actual library.
Independent API/code review approves the pin and port. Evidence is retained
under `build/streaming-io-2026-11-13/s3-seed/`.


## S3 integration qualification, 2026-11-15

Reader replaces the private Descriptor scope; fold_lines uses that same scope
with scoped step forwarding. Writer saves the callback result before choosing
one consuming finish/discard operation. Application errors prevail over discard
errors; native sticky write failures prevent publication after a caught error.
No compiler source or downstream representation changes are needed.

The fail-first normal copy compile, using the qualified S2 seed and unchanged
library, rejected the missing public Reader import with its selection help.
After integration, the ordinary filesystem suite passes 28/28 checks with
instruction ceilings enabled, including all old fold_lines cases and six new
normal-main streaming families. Report parsing passes 11/11. Every fixture
uses the existing sanitizer/strict-accounting harness and independent complete
byte comparisons; no alternate fixture entry or generated-C rewrite is used.

The exact native allocation observations distinguish first-created targets
from the ordinary harness's normal-then-strict sequence: normal creates the
target, so strict replaces it and saves one allocation per target. Final exact
expectations use that measured sequence. Both observations and argv are
retained in s3-integration/measurements.json; no semantic or cost waiver was
applied to those initial expectation failures.

| Copy input | Requested managed-heap peak | Complete byte comparison |
| --- | ---: | --- |
| 327,681 bytes | 66,685 bytes | pass |
| 16 MiB | 66,668 bytes | pass |

Both post-rename final-source children use the same verified binary and generated C, have
balanced allocations/releases and zero leaks, and stay below the 131,072-byte
ceiling. Verification occurs in the parent. These are tracked requested-heap
measurements, not process RSS. The input grows over 51-fold without growing
peak storage. Exact argv, hashes and raw reports are retained in
s3-integration/io-files-copy-peak.json; the earlier namespace observations
remain labeled as pre-rename evidence.

A temporary public-library mutation replaced discard with finish on the Writer
body-Err branch. Exactly two cases failed at independent target-byte comparison:
early scope termination and the failed line fold. Source was restored
byte-for-byte, and the complete 28-case suite passed again. Generated C review
confirms Reader closes after its callback and Writer chooses exactly one
finish/discard after its callback, preserving the original application Err.

Before the namespace rename, production library changes were 93 added /
19 deleted / +74 net lines and tests/support were 877 / 12 / +865. The
combined final rename-aware diff is 112 added / 38 deleted / +74 net
production lines and 972 / 103 / +869 test/support lines. These complete
counts include overlapping path replacements; subtraction does not measure
independent rename churn. The qualified seed pin changes five configuration
values. Documentation is separate. Code, API,
documentation and artifact-manifest reviews report no actionable findings.
Before the public namespace rename, the full ordinary gate passed 1,806
component and 1,079 native callbacks (2,885 total). Fixpoint exited 0, with
identical compiler C and all 749 A/B fixture outputs equal; B repeated all
2,885 selected callbacks. Bootstrap passed 38/38. These are pre-rename
results, retained with complete artifacts. The user-requested `io/files/`
rename has now passed a fresh pinned build, 87 focused component checks,
28 file integration callbacks with instruction ceilings enabled, complete
selected suites under B and final matched cost qualification.
The pre-rename component recount excludes the 24 outer directory summaries;
S2's earlier 1,801 component total omitted an interleaved three-test ownership
summary and should read 1,804. The raw passing results are unchanged.
Evidence lives under build/streaming-io-2026-11-13/{s3-integration,s3-test-runner}/.


### Public directory name, 2026-11-15

Keith chose `files` over the abbreviated `fs`. Move the standard-library
modules, mirrored library-test directory, public file e2e group and fixtures,
imports, registries, diagnostic help/expectations and current documentation
together. Keep private `fs.*` builtin labels, C symbols and compiler native
operation identities: these are implementation contracts, not the directory
name. Refresh the generated embedded-library inventory through the normal
build. No loader alias, path-based trust exception or compatibility module is
introduced. Historical references to the old monolithic io/fs.brp remain
historical; no active import may resolve to the removed directory.

The additional mechanical path replacements are reported in the complete
production/test diff, separately from the original S3 feature-only count.
Routine gross test ceiling correction: 900 to 1,000 added lines for the
approved rename; +875 net stays fixed. Production and performance ceilings
stay fixed. Retain readable formatting and every test. After focused A checks,
one fresh full `--prove` run qualifies final-source selected components and
native suites under B, source identity and all A/B fixture outputs; prior
full A results remain explicitly pre-rename rather than being relabeled.
That final proof exited 0: all 749 fixture comparisons match, 1,806 component
and 1,079 native callbacks pass (2,885 total), and seed/a/b/c C share SHA256
`49f9d2c4d538fb54015af2ff90f9172c227adddba0953ddbf4db49a03810ef53`.
Bootstrap exits 0 with 38/38 checks. All 1,347 frozen semantic inputs remain
unchanged; no tests or limits were weakened. The manifest SHA256 is
`18699eda77af90be6befd2f2d0f05f66f8e1bad0956561f77093d25bdb2af810`.
Code/docs review and independent test-runner review approve the final tree.
Complete logs and fixpoint artifacts are retained under
`build/streaming-io-2026-11-13/s3-files-test-runner/`.


### S3 matched cost qualification, 2026-11-15

The seed switch and feature are measured separately. Local pin-only baseline
`402f04598a344cccfad7894feac142169dc0fbe1` is published S2
`93798484557cc60d060121f4e11763c4f453836d` with only bootstrap.env replaced
by the verified S2 seed pin. Its tree is
`b27d3031627706b02fd2437b1cdf9f8e6a46fc10`. Recreate it from that published
S2 source and the five pin fields in this landing; the local commit itself is
not a separately published feature. This avoids attributing seed changes to
the public library API.

```sh
blorp/scripts/self-compile-cost 93798484557cc60d060121f4e11763c4f453836d \
    402f04598a344cccfad7894feac142169dc0fbe1 --rounds 3 \
    --output build/streaming-io-2026-11-13/s3-seed-cost
blorp/scripts/self-compile-cost 402f04598a344cccfad7894feac142169dc0fbe1 \
    db01418361d3f35bbe45276d2b11887bd6fc83bf --rounds 3 \
    --output build/streaming-io-2026-11-13/s3-cost
```

Matched host/toolchain: Darwin arm64, Apple clang 21.0.0, normal and diagnostic
binaries built by the production recipes at -O2. Instructions are the median
of three alternating normal /usr/bin/time -l samples; allocations/peak use
strict diagnostic runs with identical argv lengths. All eight strict runs
across the two comparisons balance allocations/releases with zero leaks.

| Qualified seed change only | Old pin | New pin | Change |
| --- | ---: | ---: | ---: |
| Fixed allocations | 14,071,697 | 13,875,792 | -1.3922% |
| Fixed requested-heap peak, bytes | 169,026,238 | 169,032,029 | +0.0034% |
| Fixed instructions | 12,416,213,526 | 12,313,711,559 | -0.8255% |
| Own-source allocations | 14,071,697 | 13,875,792 | -1.3922% |
| Own-source requested-heap peak, bytes | 169,026,237 | 169,032,463 | +0.0037% |
| Own-source instructions | 12,419,573,610 | 12,324,512,227 | -0.7654% |

| API and namespace, same new pin | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed allocations | 13,875,792 | 13,875,792 | 0.0000% |
| Fixed requested-heap peak, bytes | 169,032,024 | 169,032,024 | 0.0000% |
| Fixed instructions | 12,325,778,676 | 12,340,099,260 | +0.1162% |
| Own-source allocations | 13,875,792 | 13,953,461 | +0.5597% |
| Own-source requested-heap peak, bytes | 169,032,023 | 169,066,908 | +0.0206% |
| Own-source instructions | 12,327,107,753 | 12,407,543,563 | +0.6525% |

Both comparisons stay within +3% allocation/instruction and +5% peak ceilings;
no exception is needed. Small instruction differences are observations, not
a general speed claim. Fixed-input generated C is identical in both comparisons,
SHA256 `83b6dde30aa6c2bc3f64bfb834028d69bdafb9ae85fe31c9fc840a1313d3e135`.

Measured feature source trees are src
`40b37483446094a9de4622aa37015fe07e716d59` and standard_library
`0d1247ef55cd994540e175ac040ad13542ab63b1`; baseline trees are src
`5b0c6e4ef58bbd43c266b7d2fe30d809ace7e4ef` and library
`73bcddd03cf0d94ee9c6c12ee329146f22812297`. Final owning-document/NEXT
amendments preserve all compiled inputs. Raw samples, emitted C hashes and
reports are retained in the two ignored output directories. The tool removes
temporary binaries: seed-comparison executable hashes were observed before
cleanup, but feature-comparison executable hashes were not retained; its
binary provenance is the exact source, seed, flags, toolchain and build recipe,
not an invented executable hash. Neither local result claims remote platform
qualification; CI runs the platform gates after publication.

Approved follow-up: replace io/_codes integer constants with a fixed union and
shared protocol helpers, preserving precise public errors and wire behavior.
It is a separate change after this landing, before the S4 text adapter work.


### S3 Linux fixture-locale repair, 2026-11-15

Published run 43739611660 passed macOS but all three Linux jobs failed the same
four streaming allocation expectations. All reports balanced with zero leaks.
The retained logs do not identify the historical awk implementation/locale.
An independent GNU Awk 5.3.1 reproduction under en_US.UTF-8 produces the exact
byte-inflation signature: the intended 65,536-byte input becomes 91,750 bytes,
and 257 five-byte patterns become 1,799 bytes rather than 1,285. Thus those
expectations were being exercised against different input bytes and lengths.

The preparation script now sets/exports LC_ALL=C before awk and validates the
length of each generated input and both generated byte oracles. Fixed output
has the intended 00 FF 80 41 0A byte pattern. Removing the locale forcing makes
the length guard fail before compilation, with an exact expected/actual byte
count. Fresh pinned build and all 28 ordinary file cases pass with instruction
ceilings on, inherited UTF-8 locale and the same GNU awk. No runtime counts or
production behavior change. Source/library trees retain their qualified hashes.

The repair adds 15 test-support lines: the combined S3 test diff is now
987 added / 103 deleted / +884 net. Routine net ceiling correction is +875 to
+900; gross stays 1,000. This preserves the byte guards without compressing
formatting or deleting coverage. No performance or correctness gate is waived.
Reproduction, GNU source hash, mutation, build and ordinary harness logs are
retained under build/streaming-locale-2026-11-15/ in the main checkout.

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


## Typed native error kinds follow-up

This separate change follows published S3/io/files, base
`1fbdd721a9b394bf09fa0199199fe72c5eb5fda8`. Root and API/data review approved
an exhaustive explicit-wire encoder, fixed NativeErrorKind, order-independent
private typed inventory, plain-loop decoder and shared OtherOs conversion.
Operation-specific public errors, native C enum/masks and builtin ABI stay
unchanged. The temporary-directory success-path mismatch remains OtherOs(-12).
No compatibility constants or sentinel reverse lookup are retained.

Preimplementation ceilings: production 250 added and net <= 0; tests/support 200
added/net +200; docs separate. Matched whole-source allocations/instructions
and peak heap must each stay within +1%, with strict leaks zero. Final selected suites, fixpoint, bootstrap and matched cost qualification
pass; their exact evidence is recorded below.


### Narrow decoder measurement and accepted compiler debt

The approved typed inventory remains in use. Generated C establishes that
module List constants are materialized at each use today, so each positive
native-code decode constructs and drops one 15-element List; negative/zero
codes skip construction; there is no success-path global allocation.
Fixed NativeErrorKind is a native C enum and
Option[NativeErrorKind] is an unboxed stack struct. No cache, compiler rewrite,
wire-tag coupling or fallback sentinel was introduced to hide this cost.

One ordinary main repeats 4,096 checks of literal codes 2, 12, -37, verifying
PermissionDenied, OtherOs(-12), OtherOs(37) and exact sum 106,496. The published
ab0d0434 library snapshot (source-identical to the repaired current baseline)
and candidate were compiled with one identical
compiler. Strict O0/ASan/UBSan allocations rise 3 to 8,195 (exactly 8,192 positive
calls), all released; peak heap is 195 bytes on both. A single normal O0 timing
pair reports 15,778,042 to 32,175,170 retired instructions (+103.9%); elapsed 0.19s
on both is not a speed claim. Complete commands, source/binary/C hashes and
raw samples are in ignored build/native-errors-2026-11-15/decoder-measurements.json
and the baseline/candidate strict/normal logs. This isolated error-heavy
witness does not substitute for the unchanged +1% whole-source gates. Root and
API review accepted retaining the sound typed model while recording this
bounded constant-lowering debt; no performance improvement is claimed.


### Focused fixture costs and bounded correction

The first focused run preserved its exact failures: read native allocations
162 to 171 (+9), fold_lines 6,135,863 to 6,136,168 (+305), and directory
operations 484 to 507 (+23). A same-host baseline/candidate ordinary write
fixture independently measured 164 to 176 native allocations (+12), with
byte-identical stdout. Each increase is one materialized inventory List per
positive-code decode. Exact expected native counts were updated; no native
runtime/ABI or observable error outcome changed.

The write fixture also initially exceeded its unchanged compile-allocation
ceiling: 241,231 observed against 238,950. Same-host, same-output fixed-fixture
measurement with archived source-identical baseline std versus candidate std
reports 236,463 to 241,229 allocations (+2.0155%) and 756,518,657 to
765,704,438 retired instructions (+1.2142%). The old allocation ceiling had
only 1.05% headroom on the current baseline. Root approved the bounded
allocation-cap correction 238,950 to 244,000 (+5,050), preserving the original
failure and raw write-measurements.json under the ignored evidence directory.
This is not a blanket 15% reset: the 844,075,447 instruction ceiling, all other
fixture compile ceilings and all +1% whole-source ceilings remain unchanged.


### Typed-error final functional qualification

The final ordinary selected suites under self-built B pass 1,823 component
callbacks across 24 programs and 1,079 native callbacks across 19 suites:
2,902 total. Fixpoint and bootstrap both exit 0; all 749 A/B fixture outputs
match and seed/a/b/c C share SHA256
`2473ba89c7cce0c7c3e19f658f3d1cbeef3c55c6b98397c69540a1308878654e`.
Bootstrap passes 38/38. All 1,348 final frozen semantic inputs remain unchanged.
The script's legacy “first native”/“broader deferred” wording is retained in
raw logs; its actual test-e2e invocation runs all 19 selected native suites.
No standalone per-file source parse inventory is claimed.

The initial A full run found two further exact native expectations attributable
to the measured positive-code lookup: user read-module coexistence makes one
NotFound decode (1 to 2 allocations), and the binary round trip checks missing
files/directories with both read APIs (44 to 48). Only those two expectation
fields changed. Their compiler ceilings and outputs are unchanged; final B
passes both. Test/support totals are now 142 added / 7 deleted / +135 net;
production remains 214 added / 290 deleted / -76 net, within preset ceilings.

A focused 253-case repeat passed the corrected I/O cases but one unrelated
Void/String projection fixture received SIGKILL without stderr. Its exact
unchanged strict binary/argv/environment replay exited 0 in 0.208 seconds,
with 3 balanced allocations and the same binary hash. Code signing verified;
no cause was established. The initial A run and final full B run both pass
that case, with no repeated kill. No timeout/signing/source workaround or
expected-outcome waiver was applied. Original failures, system logs, replay
and complete final artifacts remain under
build/native-errors-2026-11-15/test-runner/.

Code/API/docs review and independent functional review approve the source.
The unchanged +1% whole-source allocation/instruction/peak gates pass in the
matched measurements below.


### Typed-error matched cost qualification, 2026-11-15

Baseline is the published repaired streaming tree
`1fbdd721a9b394bf09fa0199199fe72c5eb5fda8`; measured candidate is
`f2929f83167a62b2718ce6d77c89cb07ab4f63d0`, before this documentation-only
qualification amendment. Both use qualified seed blorp-seed-93798484557c.
Darwin arm64, Apple clang 21.0.0 and production build recipes at -O2 are
matched. Normal instructions use three alternating /usr/bin/time -l samples;
strict diagnostic runs supply allocations and requested managed-heap peak.
All four strict runs balance allocations/releases with zero leaks.

```sh
blorp/scripts/self-compile-cost 1fbdd721a9b394bf09fa0199199fe72c5eb5fda8 \
    f2929f83167a62b2718ce6d77c89cb07ab4f63d0 --rounds 3 \
    --output build/native-errors-2026-11-15/cost
```

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed-input allocations | 13,953,461 | 13,953,461 | 0.0000% |
| Fixed-input requested-heap peak, bytes | 169,066,472 | 169,066,472 | 0.0000% |
| Fixed-input instructions | 12,390,995,249 | 12,392,064,932 | +0.0086% |
| Own-source allocations | 13,953,461 | 13,956,806 | +0.0240% |
| Own-source requested-heap peak, bytes | 169,066,471 | 169,099,499 | +0.0195% |
| Own-source instructions | 12,384,731,609 | 12,393,105,586 | +0.0676% |

All comparisons pass the preset +1% ceilings without an exception. These small
instruction differences are observations, not a speed claim. Fixed-input C is
byte-identical, SHA256
`49f9d2c4d538fb54015af2ff90f9172c227adddba0953ddbf4db49a03810ef53`.
The isolated positive-error-path regression remains explicitly recorded above;
whole-source success does not erase it.

Baseline source/library tree hashes are
`40b37483446094a9de4622aa37015fe07e716d59` /
`0d1247ef55cd994540e175ac040ad13542ab63b1`; candidate hashes are
`7089f81c4f10ec1ee8f60efdd4db749204ddd7c0` /
`6ff24022d2b96b491f80c38d79ded6a3a23d65d5`. Final owning-document/NEXT
amendments preserve every compiled input. Raw samples, emitted C, reports and
all six completed build artifact hashes are retained under the ignored output
directory; hashes were observed after both builds completed and before tool
cleanup. Source/API and independent functional reviews approve the change.
Local qualification does not claim that the post-publication platform jobs
have run yet.
