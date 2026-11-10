# `Path`, exact I/O errors and qualified variants

**Status: plan, 2026-11-10, revision 2.** Keith approved P1 to P12 of the
earlier `PATH_DECISIONS.md` (full text, with its precedent survey and the
alternatives each point weighed, at `4b5b7fe65`) with the changes recorded
under "Decisions". Revision 1 (`541f55f9d`) let unions in one module share
variant names; Keith rejected that, and the choices it left open are decided
below. This plan is landing 7 of `MODULES_AND_STRINGABLE_PLAN.md`. When the
landings are done it amends `FILESYSTEM_DECISIONS.md` R3, R4, D8, D13 and D14,
`PROCESS_DECISIONS.md`'s error types, and decision 8 of
`MODULES_AND_STRINGABLE_PLAN.md`. Keep it
small: no traits, no subset unions, no wrapper records and no library helpers
for errors.

## Problem

- **Paths are Strings.** Swapped arguments type-check (`write_text(path, text)`,
  `rename(source, destination)`). Callers join paths by hand: about 120 `+ "/" +`
  or `"${dir}/…"` sites in `test/`. The separator is declared three times, the
  last component is parsed twice, and "under this directory" is written three
  ways (`src/cli.brp`, `src/syntax/source.brp`, `src/source_walk.brp`,
  `src/compile/load/load.brp`).
- **Errors are broader than the operation.** Every `io/fs` operation returns
  `IOError`, whose kind has 15 variants. `read_text` cannot return
  `AlreadyExists`, `DirectoryNotEmpty`, `ReadOnlyFilesystem`, `NoSpace`,
  `CrossesDevices` or `ChangedDuringRemoval`, but a caller that matches every
  case must write arms for them, or a `_` that also hides any kind added
  later. `find_program` can produce 2 of `ProcessErrorKind`'s 9 variants.
  `get_current_directory` returns `Result[String, String]`.
- **A variant cannot name its union.** `ReadError.NotFound` reports "unknown
  module alias ReadError" (probed at 70f8b7479): only an import alias may
  stand before the dot. So a caller must import each variant it matches by
  name, and two imported unions from different modules that both have a
  `NotFound` conflict.

## Decisions

Recorded from Keith, 2026-11-10. P1 to P12 are the earlier proposal's
numbers; each is approved as drafted there unless amended here.

- **P1, construction:** `"a/b".to_path()`. No `Path` literals: a String
  literal never becomes a `Path`, because that would confuse readers.
- **P2, validation (amended):** `to_path(String) -> Result[Path, PathError]`.
  `PathError` is `Empty` or `ContainsNul`. Nothing else is checked: a String
  is always UTF-8, and length limits depend on the filesystem, so the system
  call reports them as `OtherOs`. A String can hold NUL: a `"\0"` literal,
  `from_codepoint(0)` and the contents of a file. Program arguments and
  environment values cannot. A `Path` never holds NUL, so no operation that
  takes one reports it.
- **P3:** no normalization at construction; `normalize()` stays explicit.
- **P4:** `join(Path, String) -> Path`, no `/`. An absolute child replaces
  the base.
- **P5:** `Stringable`, `Equatable` and `Hashable` on the spelling, so
  `a//b != a/b`; no `Orderable`.
- **P6:** operations take only `Path`.
- **P7 (replaced):** errors carry no path ("leave the path out"). `IOError`, its `path` and
  `destination` fields and `io/error` are deleted. The caller knows the path
  and names it when it reports the error: `"${path}: ${error}"`. This amends
  D14 and D34.
- **P8 (amended):** no String errors. `get_current_directory` returns
  `Result[Path, CurrentDirectoryError]`. `Entry.name` stays a String,
  `Command.directory` becomes `Option[Path]`, `find_program` returns `Path`,
  and `main(args: List[String])` is unchanged. `Command.program` stays a
  String until process L2 decides it, so until then a found program is
  passed as `found.to_string()`.
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
- **P12 (amended):** file utilities may stay out of the prelude ("if that
  means we keep a lot of file utilities out of the prelude, that's ok").
- **Exact errors:** every fallible I/O operation returns a union whose
  variants it can all produce. The union is the error: there is no separate
  "kind" type and no generic error record.
- **Unique variant names, type-oriented modules.** Two unions in one module
  still may not share a variant name. Modules resolve naming, and a module
  organised around its main type is good practice.
- **Qualified variants:** `Union.Variant` names a variant through its union,
  in an expression and a pattern, wherever the union type is visible.
- **No helpers:** no traits or library functions over errors.
  `default_if_not_found` is deleted; its callers match `NotFound` themselves.
- **`rename`:** left to the coordinator's judgement.

## Coordinator choices, for Keith to confirm

Made to fill gaps in the decisions above; each can change without touching
the rest of the plan.

- **Defaulted, unanswered:** `InvalidPrefix` and `Unreachable` (below);
  `output`'s error wraps `capture`'s; races count, so a variant that another
  process can cause during the call is in the operation's union.
- **No program in process errors,** extending "leave the path out": the
  caller has its `Command`.
- **The prelude takes `Path` and `to_path` only;** every file operation is
  an explicit import.
- **One module per error union under `io/fs/`,** with the names below.
  Operations with the same set share one union. `rename` gets a plain
  `RenameError` like every other operation.
- **Names:** `SystemCallError` for the cause inside `capture`'s errors, and
  `NameContainsNul` for `find_program`.
- **Qualified-variant details:** a local wins over a union of the same name
  in an expression; no new rule restricts binding names.
- **Order and ceilings:** the seed rotation's place and every ceiling in
  "Landings".
- **Information lost with the path:** when `with_temporary_directory`
  cannot remove its directory, the error no longer names it (D34's exception);
  the caller has only the body's `Path`.

## Proposed solution

### Qualified variants

```blorp
import:
    io/fs/read: read_text, ReadError
    io/fs/write: write_text, WriteError

func missing() -> ReadError:
    ReadError.NotFound

func copy(source: Path, target: Path) -> Int:
    match source.read_text():
        Err(ReadError.NotFound):
            1
        Err(error):
            print_error("${source}: ${error}")
            2
        Ok(text):
            match target.write_text(text):
                Err(WriteError.NoSpace): 3
                Err(error): 4
                Ok(_): 0
```

Importing `ReadError` and `WriteError`, both of which have a `NotFound`, is
fine: a type selection (`ReadError` or `ReadError()`) enters only the type and
its methods, never a variant, so nothing conflicts. Either form makes the
union's variants reachable qualified. Importing `A(NotFound)` and
`B(NotFound)` bare still conflicts, as today.

- **Declaration.** Unchanged: variant names are unique across a module's
  unions, and every other value-namespace conflict stays.
- **Patterns.** The parser already reads `X.Y` in a pattern head as
  qualified. If `X` is an import alias it qualifies as today; otherwise `X`
  must be a visible union type, equal to the scrutinee's, and `Y` one of its
  variants ("ReadError has no variant Missing"). An alias and a type cannot
  share a spelling already (`claimant`, `namespace/namespace.brp`).
- **Expressions.** The parser is unchanged: Blorp has no capitalization rule,
  so `X.y` cannot be told from a method call by spelling, and the parser
  mints a qualified form only for an import alias. The checker reads `X.Y`
  or `X.Y(…)` as a qualified variant when `X` is not an import alias, not a
  local, parameter or capture, and not a name in the module's value namespace
  (constant, constructor, function, method), and names a visible union type.
  So a local wins: with a local `Kind`, `Kind.NotFound` is a field read, as
  today. Programs that compile today keep their meaning, including
  `union Unit: Unit` with `Unit.size()` (`Unit` is a constructor) and a local
  `Kind = 3` beside `union Kind`.
- **One rewrite point.** `X.Y` arrives as a name plus a field or receiver
  postfix (`syntax/syntax.brp`), at five sites in `check/expressions.brp`,
  including constant initializers, which today reject any postfix, and the
  callable-operand classifiers. One normalizer at the top of expression
  planning serves all of them, so `DEFAULT: Kind = Kind.A` works as the alias
  form does today.
- **Privacy.** A qualified variant passes the same offer check as
  `alias.Name` and `Union(Name)`, so a private or opaque union's variants
  stay hidden.
- **No expected type needed.** A qualified variant of a non-generic union
  names its type, so `x = ReadError.NotFound` checks without an annotation;
  the "constructor needs an expected union type" help suggests the qualified
  form.
- **Representation.** None changes: the checker resolves a qualified variant
  to the variant id a bare one gets. `grammar.ebnf`'s "bare variants resolve
  in the expected union type" is inaccurate today (the name picks the
  variant, and the expected type only checks it) and is corrected.
- **Formatter.** No change. Its chain rule counts `ReadError.Failed(x)` as a
  call link, so `ReadError.Failed(x).to_string()` breaks where a module call
  would not; the brief records this with a formatter test.

### Exact errors

Each error is a fixed union whose variants carry only what the operation
learned, never the path. A file error's `to_string` is today's phrase for
that kind ("no such file"), byte for byte; process errors change, below.

**Modules.** Variant names stay unique per module, so unions that share
names go in separate modules under `io/fs/`, each organised around its
operation and its error. Abbreviations: NF `NotFound`, PD
`PermissionDenied`, AE `AlreadyExists`, ND `NotADirectory`, ID
`IsADirectory`, DNE `DirectoryNotEmpty`, NRF `NotARegularFile`, RO
`ReadOnlyFilesystem`, NS `NoSpace`, FTL `FileTooLarge`, XD `CrossesDevices`,
U8 `InvalidUtf8`, CDR `ChangedDuringRemoval`, OS `OtherOs(Int)`.

| Module (`io/fs/…`) | Operations | Error | Variants |
| --- | --- | --- | --- |
| `read` | `read_text`, `fold_lines` | `ReadError` | NF PD ND ID FTL U8 OS |
| `write` | `write_text` | `WriteError` | NF PD AE ND ID DNE NRF RO NS FTL OS |
| `entry` | `entry_kind`, with `Entry` and `EntryKind` | `EntryError` | PD OS |
| `list` | `list_directory` | `ListError` | NF PD ND U8 OS |
| `create_directory` | `create_directory`, `create_directories` | `CreateDirectoryError` | NF PD AE ND RO NS OS |
| `remove_file` | `remove_file` | `RemoveFileError` | NF PD ND ID RO OS |
| `remove_directory` | `remove_directory` | `RemoveDirectoryError` | NF PD ND DNE RO OS |
| `remove_tree` | `remove_directory_tree` | `RemoveTreeError` | NF PD ND ID DNE RO XD CDR OS |
| `rename` | `rename` | `RenameError` | NF PD ND ID DNE RO NS XD OS |
| `temporary_directory` | `with_temporary_directory` | `TemporaryDirectoryError` | see below |

The sets come from an audit of the runtime at 70f8b7479
(`src/compile/runtime/fs.brp`, `process.brp`, `system.brp`) and the system
calls each native makes, on the three supported 64-bit targets; a kind
reachable only on 32-bit systems is left out.

- **`with_temporary_directory`** takes one `io_error` callback for creating
  and removing its directory, so its union covers both steps: NF PD ND ID DNE
  RO NS XD CDR `InvalidPrefix` OS. `prefix` stays a String; `InvalidPrefix`
  replaces today's `PathContainsNul` and `OtherOs(EINVAL)` for a prefix with
  NUL or `/`. Its callback becomes `pure (TemporaryDirectoryError) -> E`, and
  `fold_lines`'s becomes `pure (ReadError) -> E`. Its body receives a `Path`.
- **Races.** `write_text` keeps AE and DNE, and `remove_directory_tree` keeps
  ID, because another process can swap a directory in during the call.
- **Platforms.** `create_directory("file/")` is ND on macOS and AE on Linux.
  `remove_file` on a directory is ID on both, because the runtime already
  rewrites macOS's EPERM.
- **`rename`'s ID** (EISDIR, a file renamed onto a directory) is missing from
  `FILESYSTEM_DECISIONS.md` today; landing 5 documents it.
- **`io/fs.brp`** is deleted, and `io/error.brp` with it.

**`io/environment`.** `get_current_directory` returns
`Result[Path, CurrentDirectoryError]`: `NotFound`, `PermissionDenied`,
`InvalidUtf8`, `Unreachable` and `OtherOs(Int)`. `Unreachable` is Linux's
working directory outside the process's root, today's "native path must be
nonempty and absolute" message; the "exceeds the String capacity" case
becomes `OtherOs`. Today's builtin returns English text
(`src/compile/runtime/system.brp`), and the compiler calls it (`load.brp`),
so a new builtin that returns a code lands first, and the seed learns it
before the library uses it.

**`io/process`.** The same rules, with no `program` in any error: the caller
has its `Command`. One module, because no names collide:

- `FindProgramError`: `NotOnPath`, `NameContainsNul`.
- `CaptureError`: `InvalidVariableName(String)`, `ContainsNul`,
  `LaunchFailed(SystemCallError)`, `NotExecutable`,
  `DirectoryFailed(SystemCallError)`, `StdoutNotUtf8(Exit)`,
  `StderrNotUtf8(Exit)`.
- `OutputError`: `CaptureFailed(CaptureError)`, `Unsuccessful(Captured)`.
- `SystemCallError`, the cause inside `LaunchFailed` (exec, fork, pipes) and
  `DirectoryFailed` (`chdir`): `NotFound`, `PermissionDenied`,
  `NotADirectory`, `OtherOs(Int)`.

`Command.directory` becomes `Option[Path]` (P8), so `DirectoryFailed` loses
its `PathContainsNul` case. Process error text loses the program and the
directory: "make: exited 2" becomes "exited 2", and `DirectoryFailed`'s
"cannot enter <directory>" becomes "cannot enter the directory: <cause>".
The process tests that assert this text change with it. `find_program`'s
variant is `NameContainsNul` because `CaptureError` in the same module has
`ContainsNul`.

**Decoding.** The file natives' error codes are unchanged; `io/_codes` keeps
them as named constants. Each module's private decoder maps the codes its
union can produce. Any other code becomes `OtherOs` with the code negated, as
`decode_error` already does for a code no constant names, so a disagreement
between runtime and library is never a crash; each decoder has a test for it.

**Callers.** A caller that mixes operations writes its own error type. A
constructor is not a function value (`map_err(ReadFailed)` reports "variant
does not belong to the expected type", probed), so the wrapping is a `match`
or a lambda:

```blorp
import:
    io/fs/read: read_text, ReadError
    io/fs/write: write_text, WriteError

union CopyError:
    ReadFailed(ReadError)
    WriteFailed(WriteError)

func copy(source: Path, target: Path) -> Result[Void, CopyError]:
    match source.read_text():
        Err(error):
            Err(ReadFailed(error))
        Ok(text):
            match target.write_text(text):
                Ok(written): Ok(written)
                Err(error): Err(WriteFailed(error))

-- what default_if_not_found did
func settings(path: Path) -> Result[String, ReadError]:
    result = path.read_text()
    match result:
        Err(ReadError.NotFound): Ok("")
        _: result
```

The compiler's own messages that print a file error today (`"${error}"`,
which included the path) now print `"${path}: ${error}"`, so their text is
unchanged; messages that print a process error add the program the same way.

## Landings

1. **Qualified variants.** Checker (`check/expressions.brp`,
   `constructors.brp`, `patterns.brp`), diagnostics (`errors.brp`,
   `render.brp`) and a namespace query from a union and variant name to its
   id; the parser changes only message wording ("after the qualifier").
   `README.md` and `grammar.ebnf`: the qualified-form and pattern-head
   comments, the expected-type sentence, and that a local wins over a union
   of the same name. No library change.
   - Tests: qualified constructors and patterns; two imported unions that
     share a variant name, used qualified; `x = Kind.NotFound` unannotated; a
     constant `DEFAULT: Kind = Kind.A`; a wrong-union and an unknown variant
     (`Kind.Missing`); a private variant and an opaque union refused; a union
     not imported, with the help "import ReadError"; `union Unit: Unit` with
     `Unit.size()`; a local beside a same-named union, where the local wins;
     the formatter's chain case.
   - Ceilings: production lines at most +250, which assumes the one rewrite
     point. Self-compile allocations and retired instructions each at most
     +0.3%.
   - Review: the brief goes through parser and ergonomics review before
     implementation; documenter review after.
2. **`Path` in `path.brp`, beside the String functions.** P2 to P5, P10's
   methods, `PathError` and unit tests. No compiler change.
   - Ceilings: production lines at most +130; self-compile allocations and
     instructions each at most +0.3%.
3. **The current-directory native.** A new builtin returning a code, beside
   the old one, with no library caller yet.
   - Ceilings: production lines at most +60; self-compile unchanged.
4. **Seed rotation** after landings 1 and 3, so seed-built code (`src/`,
   `scripts/`, the library the compiler embeds) may use qualified variants
   and the new native. Until then it uses neither.
5. **Signatures move to `Path`, with exact errors.** The `io/fs/` modules,
   `io/environment` and `io/process`. `io/fs.brp`, `io/error.brp`,
   `IOErrorKind`, `default_if_not_found`, the old current-directory builtin,
   the String functions in `path.brp`, `cli.file_name` and `module_stem` are
   deleted. Every caller, both READMEs, `FILESYSTEM_DECISIONS.md` and
   `PROCESS_DECISIONS.md` are updated. The rest of process L2
   (`Command.program`, removing `run_to_files`) stays in the process plan.
   - Ceilings, estimates: compiler production lines at most +40 net;
     standard library at most +300 net, mostly the unions, their decoders and
     their text. Self-compile allocations and instructions each at most
     +0.5%. Test growth reported separately.
6. **The prelude.** `Path` and `to_path`. The prelude loads all of
   `path.brp`, and every loaded module is checked in full; today's
   `path.brp`, with similar functions, cost +13,222 allocations and +10.7%
   instructions to compile an empty program (measured at about `ce8753b6f`,
   against 89,222 allocations and 333.6 M instructions). Ceilings: the
   empty-program compile at most +15,000 allocations and +12% instructions,
   remeasured on landing 2's module before this landing starts; self-compile
   at most +0.1%; e2e ceilings reset with their existing margins and
   recorded.

Landings 1, 2 and 3 are independent. Landing 4 needs 1 and 3; landing 5
needs 2 and 4; landing 6 needs 5.

## Out of scope

Globbing, symlink operations, Windows paths, byte-backed paths, a
normalized-path type inside the compiler, `Orderable`, `/` for joining,
`copy_file`, permissions and timestamps, and `Path` literals. For qualified
variants: shared variant names in one module, choosing a variant by expected
type, the three-part `alias.Union.Variant` (a pattern head has two parts, and
importing the union serves), and hints for `Union::Variant` and `.Variant`,
which today give unrelated parse errors.

## Not verified

- The line ceilings, which are estimates, and the prelude cost of the full
  `Path` module, which landing 2 measures.
- The variant sets come from reading the runtime and the system calls'
  manual pages; "race only" entries are judgement. Landing 5's tests cover
  each deterministic variant per operation.
- `Err(ReadError.NotFound)` was probed with a module-qualified variant
  (`Err(read.NotFound)`), which nests today; the union-qualified form is
  landing 1's.
- That the qualified-variant rule keeps every existing program compiling
  beyond the two cases probed; landing 1's full suite shows it.
