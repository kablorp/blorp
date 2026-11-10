# `Path`, exact I/O errors and qualified variants

**Status: draft plan, 2026-11-10.** Keith approved P1 to P12 of the earlier
`PATH_DECISIONS.md` on 2026-11-10, with the changes recorded under
"Decisions": no String errors, an exact error kind for every operation, a
`to_path` that can fail, and qualified variants. Seven smaller choices under
"Proposed, needs Keith's OK" await him. Exact kinds need one language change, qualified
access to union variants, which this plan adds as its first landing. This plan
is landing 7 of `MODULES_AND_STRINGABLE_PLAN.md`. When the landings are done it
amends `FILESYSTEM_DECISIONS.md` R3, R4, D8, D13 and D14, and the error types in
`PROCESS_DECISIONS.md`. Keep it small: no traits, no subset unions and no
library helpers for error kinds. The earlier proposal's full
text, with its precedent survey and the alternatives each point weighed, is
`blorp/PATH_DECISIONS.md` at `4b5b7fe65`.

## Problem

- **Paths are Strings.** Swapped arguments type-check (`write_text(path, text)`,
  `rename(source, destination)`). Callers join paths by hand: 97 `+ "/" +` or
  `"${dir}/…"` sites in `test/`. The separator is declared three times, the last
  component is parsed twice, and "under this directory" is written three ways
  (`src/cli.brp`, `src/syntax/source.brp`, `src/source_walk.brp`,
  `src/compile/load/load.brp`).
- **Errors are broader than the operation.** Every `io/fs` operation returns
  `IOError`, whose kind has 15 variants. `read_text` cannot return
  `AlreadyExists`, `DirectoryNotEmpty`, `ReadOnlyFilesystem`, `NoSpace`,
  `CrossesDevices` or `ChangedDuringRemoval`, but a caller that matches every
  case must write arms for them, or a `_` that also hides any kind added later.
  `find_program` can produce 2 of `ProcessErrorKind`'s 9 variants.
  `get_current_directory` returns `Result[String, String]`.
- **Exact kinds cannot be written today.** Variant names are unique across a
  module's unions, so `read_text` and `write_text` cannot both have a
  `NotFound`. A probe at 70f8b7479:

  ```blorp
  fixed union ReadKind:
      NotFound
      InvalidUtf8

  fixed union WriteKind:
      NotFound       -- error: duplicate constructor name
      NoSpace
  ```

  `ReadKind.NotFound` reports "unknown module alias ReadKind": only a module
  alias may stand before the dot (`grammar.ebnf`, the qualified forms).
  Variants in two modules, used as `read.NotFound` and `write.NotFound`,
  compile today, but that would mean a module per operation.

## Decisions

Recorded from Keith, 2026-11-10. P1 to P12 are the earlier proposal's numbers
(`4b5b7fe65`); each is approved as drafted there unless amended here.

- **P1, construction:** `"a/b".to_path()`. Amended by P2.
- **P2, validation (amended):** `to_path(String) -> Result[Path, PathError]`,
  where `PathError` is `Empty` or `ContainsNul`. Nothing else is checked: a
  String is always UTF-8, and length limits depend on the filesystem, so the
  system call reports them as `OtherOs`. A String can hold NUL: a `"\0"`
  literal, `from_codepoint(0)` and the contents of a file. Program arguments
  and environment values cannot. Because a `Path` never holds NUL,
  `PathContainsNul` leaves every operation that takes a `Path`.
- **P3:** no normalization at construction; `normalize()` stays explicit.
- **P4:** `join(Path, String) -> Path`, no `/`. An absolute child replaces
  the base.
- **P5:** `Stringable`, `Equatable` and `Hashable` on the spelling, so
  `a//b != a/b`; no `Orderable`.
- **P6:** operations take only `Path`.
- **P7 (amended):** see "Exact error kinds".
- **P8 (amended):** no String errors. `get_current_directory` returns
  `Result[Path, CurrentDirectoryKind]`. The rest of P8 stands: `Entry.name`
  stays a String, `Command.directory` is `Option[Path]`, `find_program`
  returns `Path`, and `main(args: List[String])` is unchanged.
- **P9:** non-UTF-8 paths stay refused until `Path` is byte-backed.
- **P10:** `path.brp` becomes `Path`'s module, and its String functions are
  deleted:

  | Today | `Path` method |
  | --- | --- |
  | `join` | `join(Path, String) -> Path` |
  | `dirname` | `parent(Path) -> Path`, total: `"a"` is `.` and `/` is `/` |
  | `normalize` | `normalize(Path) -> Path` |
  | `cli.file_name` | `name(Path) -> Option[String]`, `None` for `/` and `..` |
  | `source.module_stem` | `stem` and `extension(Path) -> Option[String]` |
  | `prefix + ".c"` | `with_extension(Path, String) -> Path` |
  | three containment checks | `is_within(Path, Path) -> Bool`, by component |

- **P11:** migrate only at the filesystem boundary. The compiler's
  `SourceFile.path`, `SourceOverrides` and `LibraryContents` stay String.
- **P12:** (c). The prelude takes `Path`, `to_path` and the `io/fs` methods.
  Measured at about `ce8753b6f`, an empty program then costs about +52,000
  allocations and +50% instructions to compile, against 89,222 allocations
  and 333.6 M instructions. A loader that checks a prelude module only when a
  program uses it may follow. Kind unions and constructors stay explicit
  imports.
- **New, exact error kinds:** every fallible I/O operation returns an error
  whose kinds it can all produce. Operations with the same set share one
  union.
- **New, qualified variants:** a variant may be written `Type.Variant`, and
  two unions of one module may declare the same variant name.
- **New, no helpers:** no traits or library functions over error kinds.
  `default_if_not_found` is deleted; its callers match `NotFound` themselves.

## Proposed, needs Keith's OK

Each is the simplest form the reviews found; none is decided.

1. **Bare variant rule.** A bare `NotFound` resolves when exactly one
   constructor of that name is in scope, as today; otherwise it must be
   qualified. The expected type validates a variant but never chooses one,
   which is how the checker works today (`check/constructors.brp`,
   `VariantNotInExpectedType`); `grammar.ebnf`'s "bare variants resolve in the
   expected union type" is inaccurate and is corrected. Choosing by expected
   type would be a new rule, deferred.
2. **Bindings.** A parameter, local or capture may not reuse the name of a
   visible union type, as it already may not reuse an import alias's. Without
   it, `Kind.NotFound` means different things in an expression and a pattern
   when a local `Kind` exists.
3. **Error records.** One generic `IOError[K]` carries the path. `rename`,
   the only two-path operation, gets its own `RenameError` with `source` and
   `destination`, so `IOError` loses a `destination` that is `None` for every
   other operation.
4. **New kinds.** `InvalidPrefix` for `with_temporary_directory`, whose
   prefix stays a String, and `Unreachable` for Linux's working directory
   outside the process's root.
5. **`OutputKind`** wraps `CaptureKind` (`CaptureFailed(CaptureKind)` or
   `Unsuccessful(Captured)`) rather than repeating its seven variants;
   `output` callers match one level deeper.
6. **Races count.** A kind that another process can cause during the call is
   in the operation's union.
7. **`Path` literals.** A String literal where a `Path` is expected becomes a
   `Path`, checked at compile time against P2's rules, as an Int literal must
   fit its expected type. It is a new checker rule, and the checker must know
   which declaration is `Path`, as it knows `Option` and `Result`. Without it,
   every literal path is `.to_path()` plus a `match` or `?=`:

   ```blorp
   config: Path = "settings.conf"            -- checked when compiled
   broken: Path = ""                          -- error: a path cannot be empty
   target ?= args.get_or(1, "out").to_path()  -- runtime: Result[Path, PathError]
   ```

## Proposed solution

### Qualified variants

A variant is reachable through its union, as `ReadKind.NotFound` in an
expression or a pattern. A bare name works as today when it is the only
constructor of that name in scope.

```blorp
import:
    io/fs: ReadKind(), RemoveFileKind()

pure func is_missing(read: ReadKind) -> Bool:
    match read:
        ReadKind.NotFound: True
        ReadKind.PermissionDenied: False
        ReadKind.NotADirectory: False
        ReadKind.IsADirectory: False
        ReadKind.FileTooLarge: False
        ReadKind.InvalidUtf8: False
        ReadKind.OtherOs(_): False
```

The rules, from the parser and ergonomics review (proposals 1 and 2 above):

- **Declaration.** Unions declared in one module may share a variant name.
  Every other conflict in the value namespace stays: a declared constructor
  against an imported one, a function, an import alias or a prelude
  constructor.
- **Imports.** `Union()` imports the type, and its variants are then
  reachable as `Union.Variant`. `Union(V)` takes that union's own `V`, chosen
  by its owner. A bare `V` imported while another constructor `V` is in scope
  is an import conflict, with the help "import Union() and write Union.V".
  `alias.V` is an error when the target declares `V` in more than one union,
  with the same help.
- **Bare use.** Ambiguity is reported by the checker at the use, with the
  message "NotFound is a variant of more than one union: ReadKind,
  WriteKind" and the help "write ReadKind.NotFound or WriteKind.NotFound".
- **Patterns.** The parser already reads `X.Y` in a pattern as qualified. If
  `X` is a module alias it qualifies as today; otherwise `X` must be a
  visible union type and `Y` one of its variants. An alias cannot share a
  type's spelling, because an alias claims both namespaces.
- **Expressions.** The parser is unchanged: Blorp has no capitalization
  rule, so `Kind.missing` cannot be told from a method call by spelling.
  The checker, where an expression is first planned, reads `X.Y` or
  `X.Y(…)` as a qualified variant when `X` is not a data value (a local,
  parameter, capture, constant or constructor) and names a visible union
  type. Existing programs keep their meaning: `union Unit: Unit` with
  `Unit.size()` and a local `Kind = 3` beside `union Kind` both compile today
  and must still.
- **No expected type needed.** A qualified variant of a non-generic union
  names its type, so `x = ReadKind.NotFound` checks without an annotation;
  the "constructor needs an expected union type" help suggests the qualified
  form.
- **Namespace.** The namespace holds one entity per spelling today, and every
  second claim is a conflict. Landing 1 adds one value-namespace entry for a
  spelling the module's own unions share, holding its variant ids, written
  only where declarations enter. Selecting `Union(V)` resolves through the
  union. Variant ids and emitted C need nothing: C names are numbered by id
  (`blorp_v_<union>_<n>`), not spelled.
- **Formatter.** No change. The chain rule counts `ReadKind.Failed(e)` as a
  call link, so `ReadKind.Failed(e).to_string()` breaks where a module call
  would not; the brief records it with a formatter test.

### Exact error kinds

Each operation, or group of operations with the same set, gets a fixed union
of the kinds it can produce, in `io/fs`, `io/process` or `io/environment`.
Inside those modules every shared variant is written qualified. The path
stays with the error through one generic record (proposal 3):

```blorp
-- io/error
record IOError[K: Stringable] {
    path: Path,
    kind: K,
}

-- "settings.conf: no such file", as today.
implements Stringable for IOError[K: Stringable]:
    pure func to_string(value: Self) -> String:
        "${value.path}: ${value.kind}"

record RenameError {
    source: Path,
    destination: Path,
    kind: RenameKind,
}
```

The callbacks of `fold_lines` and `with_temporary_directory` change type with
them: `io_error: pure (IOError[ReadKind]) -> E` and
`pure (IOError[TemporaryDirectoryKind]) -> E`.

A caller that mixes operations writes its own error type, as it would for any
two unrelated errors. A constructor is not a function value
(`map_err(ReadFailed)` reports "variant does not belong to the expected
type", probed), so the wrapping is a `match` or a lambda:

```blorp
import:
    io/fs: ReadKind(), WriteKind()

union CopyError:
    ReadFailed(IOError[ReadKind])
    WriteFailed(IOError[WriteKind])

func copy(source: Path, target: Path) -> Result[Void, CopyError]:
    match source.read_text():
        Err(error):
            Err(ReadFailed(error))
        Ok(text):
            match target.write_text(text):
                Ok(written): Ok(written)
                Err(error): Err(WriteFailed(error))

-- what default_if_not_found did
func settings(path: Path) -> Result[String, IOError[ReadKind]]:
    match path.read_text():
        Ok(text):
            Ok(text)
        Err(error):
            match error.kind:
                ReadKind.NotFound: Ok("")
                _: Err(error)
```

**Decoding.** The file natives' error codes are unchanged (`io/_codes`). Each
kind union gets a private decoder for the codes it can produce. Any other code
becomes `OtherOs` with the code negated, as `decode_error` already does for a
code no constant names, so a disagreement between runtime and library is
never a crash; each decoder has a test for it. Each kind keeps its exact
phrase from today's `IOErrorKind` text; phrases shared by several unions are
private constants.

**`get_current_directory`** needs a new native. Today's builtin returns
English text (`src/compile/runtime/system.brp`), and the compiler calls it
(`load.brp`), so the seed must know the new builtin before the library uses
it. A new builtin label returns a code; the old one is deleted in landing 5.

**The kinds.** From an audit of the runtime at 70f8b7479
(`src/compile/runtime/fs.brp`, `process.brp`, `system.brp`) and the system
calls each native makes. A union holds every kind the runtime can deliver on
the three supported 64-bit targets, races and platform differences included
(proposal 6); a kind reachable only on 32-bit systems is left out.
Abbreviations: NF `NotFound`, PD `PermissionDenied`, AE `AlreadyExists`, ND
`NotADirectory`, ID `IsADirectory`, DNE `DirectoryNotEmpty`, NRF
`NotARegularFile`, RO `ReadOnlyFilesystem`, NS `NoSpace`, FTL
`FileTooLarge`, XD `CrossesDevices`, U8 `InvalidUtf8`, CDR
`ChangedDuringRemoval`, OS `OtherOs(Int)`.

| Union | Operations | Kinds | Drops |
| --- | --- | --- | --- |
| `ReadKind` | `read_text`, `fold_lines` | NF PD ND ID FTL U8 OS | 8 |
| `WriteKind` | `write_text` | NF PD AE ND ID DNE NRF RO NS FTL OS | 4 |
| `LookupKind` | `entry_kind` | PD OS | 13 |
| `ListKind` | `list_directory` | NF PD ND U8 OS | 10 |
| `CreateDirectoryKind` | `create_directory`, `create_directories` | NF PD AE ND RO NS OS | 8 |
| `RemoveFileKind` | `remove_file` | NF PD ND ID RO OS | 9 |
| `RemoveDirectoryKind` | `remove_directory` | NF PD ND DNE RO OS | 9 |
| `RemoveTreeKind` | `remove_directory_tree` | NF PD ND ID DNE RO XD CDR OS | 6 |
| `RenameKind` | `rename` | NF PD ND ID DNE RO NS XD OS | 6 |
| `TemporaryDirectoryKind` | `with_temporary_directory` | see below | 5 |
| `CurrentDirectoryKind` | `get_current_directory` | NF PD `NotUtf8` `Unreachable` OS | new |

"Drops" counts today's 15 `IOErrorKind` variants the union leaves out.

- **`with_temporary_directory`** takes one `io_error` callback for creating
  and removing its directory, so its union covers both steps: NF PD ND ID DNE
  RO NS XD CDR `InvalidPrefix` OS. `InvalidPrefix` replaces today's
  `PathContainsNul` and `OtherOs(EINVAL)` for a prefix with NUL or `/`.
- **Races.** `write_text` keeps AE and DNE, and `remove_directory_tree` keeps
  ID, because another process can swap a directory in during the call.
- **Platforms.** `create_directory("file/")` is ND on macOS and AE on Linux.
  `remove_file` on a directory is ID on both, because the runtime already
  rewrites macOS's EPERM.
- **`rename`'s ID** (EISDIR, a file renamed onto a directory) is missing from
  `FILESYSTEM_DECISIONS.md` today; landing 5 documents it.
- **`get_current_directory`** has no caller path, so its error is the kind
  alone. `Unreachable` is today's "native path must be nonempty and absolute"
  message; the "exceeds the String capacity" case becomes OS.

Process errors take the same shape, with `ProcessError[K]` keeping
`program: String`:

- `FindProgramKind`, for `find_program`: `NotOnPath`, `ContainsNul`.
- `CaptureKind`, for `capture`: `InvalidVariableName(String)`,
  `ContainsNul`, `LaunchFailed(LaunchKind)`, `NotExecutable`,
  `DirectoryFailed(IOError[DirectoryKind])`, `StdoutNotUtf8(Exit)`,
  `StderrNotUtf8(Exit)`.
- `OutputKind`, for `output`: `CaptureFailed(CaptureKind)`,
  `Unsuccessful(Captured)` (proposal 5).
- `LaunchKind` (exec, fork and pipes) and `DirectoryKind` (`chdir`): NF PD ND
  OS each.

`Command.directory` becomes `Option[Path]` (P8), so `DirectoryFailed` loses
`PathContainsNul`.

## Landings

1. **Qualified variants.** Namespace, checker and diagnostics; the parser
   changes only message wording ("after the qualifier"). `README.md` and
   `grammar.ebnf` (imports, variant uniqueness, the qualified-form and
   pattern-head comments, binding reuse). No library change.
   - Tests: a shared variant name in one module; qualified constructors and
     patterns; `x = Kind.NotFound` unannotated; `Union(V)` from a module whose
     unions share `V`; `A(V), B(V)` rejected at the import; ambiguous bare and
     `alias.V` uses with their help; a wrong-union qualified pattern; an
     unknown `Kind.Missing`; the binding rejection; `union Unit: Unit` with
     `Unit.size()` still compiling; the formatter's chain case.
   - Ceilings: production lines at most +250. Self-compile allocations and
     retired instructions each at most +0.3%.
   - Review: the brief goes through parser and ergonomics review before
     implementation; documenter review after.
2. **`Path` in `path.brp`, beside the String functions.** P2 to P5, P10's
   methods, `PathError`, and unit tests. No compiler change; independent of
   landing 1.
   - Ceilings: production lines at most +130; self-compile allocations and
     instructions each at most +0.3%.
3. **The `get_current_directory` native.** A new builtin returning a code,
   beside the old one; no library caller yet.
   - Ceilings: production lines at most +60; self-compile unchanged.
4. **Seed rotation** onto main after landings 1 and 3, so seed-built code
   (`src/`, `scripts/`, the library the compiler embeds) may use qualified
   variants and the new native. Until then, library and compiler code use
   neither.
5. **Signatures move to `Path` and exact kinds.** `io/fs`, `io/error`,
   `io/environment` and `io/process`. `IOErrorKind`, `default_if_not_found`,
   the old current-directory builtin, the String functions in `path.brp`,
   `cli.file_name` and `module_stem` are deleted. Every caller, both READMEs,
   `FILESYSTEM_DECISIONS.md` and `PROCESS_DECISIONS.md` are updated. Process
   L2 (`Command.program`, `ProcessError.program`, removing `run_to_files`)
   stays in the process plan.
   - Ceilings, estimates: compiler production lines at most +40 net; standard
     library at most +300 net, mostly the kind unions, their decoders and
     their text. Self-compile allocations and instructions each at most
     +0.5%. Test growth reported separately.
6. **The prelude (P12).** The empty-program compile at most +55,000
   allocations and +55% instructions; self-compile at most +0.1%; e2e
   ceilings reset with their existing margins and recorded.
7. **If proposal 7 is approved, `Path` literals,** after landing 2, with
   their own ceilings. Nothing else depends on them; seed-built code uses
   them only after a later rotation.
8. **Optional:** the lazy prelude loader, under its own plan.

Landings 1, 2 and 3 are independent. Landing 4 needs 1 and 3; landing 5
needs 2 and 4; landing 6 needs 5.

## Out of scope

Globbing, symlink operations, Windows paths, byte-backed paths, a
normalized-path type inside the compiler, `Orderable`, `/` for joining,
`copy_file`, permissions and timestamps. For qualified variants: choosing a
variant by expected type, the three-part `alias.Type.Variant` (a pattern head
has two parts, and no caller needs it), and hints for `Kind::NotFound` and
`.NotFound`, which today give unrelated parse errors.

## Not verified

- The line ceilings, which are estimates; landing 1's is the reviewer's
  200 to 280.
- `IOError[K: Stringable]` with its `Stringable` implementation compiles at
  70f8b7479 (probed); it was not run.
- The kind table comes from reading the runtime and the system calls' manual
  pages; "race only" entries are judgement. Landing 5's tests cover each
  deterministic kind per operation.
- Whether the bare-variant rule keeps every existing program compiling beyond
  the two cases probed; landing 1's full suite shows it.
