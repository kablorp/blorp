# `Path`, exact I/O errors, naming rules and qualified variants

**Status: plan, 2026-11-10, revision 4. Landings 4 (`7d8a92f25`), 3
(`4024ef09d`) and 1 (`be98099e6`) have landed.** Revision 4 folds in
landing 2's parser and ergonomics review. Revision 3 adds the naming rules
Keith adopted, which make qualified variants a parser rule. Keith approved P1
to P12 of the earlier `PATH_DECISIONS.md` (full text, with its precedent
survey and the alternatives each point weighed, at `4b5b7fe65`) with the
changes recorded under "Decisions". Revision 1 (`541f55f9d`) let unions in
one module share variant names; Keith rejected that, and the choices it left
open are decided below. This plan is the `Path` landing (item 7) of
`MODULES_AND_STRINGABLE_PLAN.md`. When the landings are done it amends
`FILESYSTEM_DECISIONS.md` R3, R4, D8, D13 and D14, `PROCESS_DECISIONS.md`'s
error types, and decision 8 of `MODULES_AND_STRINGABLE_PLAN.md`. Keep it
small: no traits, no subset unions, no wrapper records and no library helpers
for errors.

## Problem

- **Paths are Strings.** Swapped arguments type-check (`write_text(path, text)`,
  `rename(source, destination)`). Callers join paths by hand: about 120 `+ "/" +`
  or `"${dir}/…"` sites in `test/`. The separator is declared three times, the
  last component is parsed twice, and "under this directory" is written three
  ways (`src/cli.brp`, `src/common/syntax/source.brp`, `src/format/source_walk.brp`,
  `src/common/analysis/load/load.brp`).
- **Errors are broader than the operation.** Every `io/fs` operation returns
  `IOError`, whose kind has 15 variants. `read_text` cannot return
  `AlreadyExists`, `DirectoryNotEmpty`, `ReadOnlyFilesystem`, `NoSpace`,
  `CrossesDevices` or `ChangedDuringRemoval`, but a caller that matches every
  case must write arms for them, or a `_` that also hides any kind added
  later. `find_program` can produce 2 of `ProcessErrorKind`'s 9 variants.
  `get_current_directory` returns `Result[String, String]`.
- **Naming case is not enforced.** Only type parameters must start with a
  capital (`common/syntax/parse.brp`, `valid_type_parameter_name`). This compiles
  at 9f29a0ebc:

  ```blorp
  union shape_kind:
      circle
      Square

  record point_2d {
      X: Int,
  }

  lower_constant: Int = 3

  pure func Area(Width: Int) -> Int:
      Kind = Width
      Kind + lower_constant
  ```

  By rough grep at 9f29a0ebc, `src/`, the library and `scripts/` follow the
  conventions except for 3 capitalized import aliases in `src/` (`Builtins`
  in `verify/verify.brp`, `D` in `namespace.brp` and `specialize.brp`). The
  tests break them in more places:
  - about 185 test files' `tests` suite constants, and a fixture's
    `private tests: TestSuite`;
  - about 370 capitalized import aliases (`D`, `Own`, `Lower`, `Native`,
    `FsTests`), each with its use sites, including `tests = Native.tests`;
  - about 12 lowercase constants in programs embedded in test strings;
  - 3 test function names with capitals (`test_target_numeric_API_…`);
  - the fixture function `Foo`
    (`test/e2e/fixtures/namespace/declared_function_imported_type/`).
- **A variant cannot name its union.** `ReadError.NotFound` reports "unknown
  module alias ReadError" (probed at 70f8b7479): only an import alias may
  stand before the dot. So a caller must import each variant it matches by
  name, and two imported unions from different modules that both have a
  `NotFound` conflict.

## Decisions

Recorded from Keith, 2026-11-10. P1 to P12 are the earlier proposal's
numbers; each is approved as drafted there unless amended here.

- **P1, construction:** `"a/b".to_path()` is the only way to make a `Path`
  from a String; no other function takes a String and returns a `Path`. No
  `Path` literals: a String literal never becomes a `Path`, because that
  would confuse readers.
- **P2, validation (amended):** `to_path(String) -> Result[Path, PathError]`.
  `PathError` is `Empty` or `ContainsNul`. Nothing else is checked: a String
  is always UTF-8, and length limits depend on the filesystem, so the system
  call reports them as `OtherOs`. A String can hold NUL: a `"\0"` literal,
  `from_codepoint(0)` and the contents of a file. Program arguments and
  environment values cannot. A `Path` never holds NUL, so no operation that
  takes one reports it.
- **P3:** no normalization at construction; `normalize()` stays explicit.
- **P4 (amended):** `join(Path, Path) -> Path` puts the second path under
  the first, even when the second is absolute (`/a` joined with `/b` is
  `/a/b`), so it cannot fail and its name says what it does. `Path`
  implements `Addable`: `+` concatenates the spellings exactly as String `+`
  does (`a + b` is `ab`, never `a/b`). No `/`.
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
  | `join` | `join(Path, Path) -> Path`, the second under the first |
  | `dirname` | `parent(Path) -> Path`, total: `"a"` is `.` and `/` is `/` |
  | `normalize` | `normalize(Path) -> Path` |
  | `cli.file_name` | `name(Path) -> Option[String]`, `None` for `/` and `..` |
  | `source.module_stem` | `stem` and `extension(Path) -> Option[String]` |
  | `prefix + ".c"` | `prefix + extension`, `extension ?= ".c".to_path()` first |
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
- **Naming rules,** enforced by the compiler:

  | Names | Form | Spelling |
  | --- | --- | --- |
  | Types, variants, traits, type parameters | CapitalizedCamelCase | `[A-Z][A-Za-z0-9]*` |
  | Module constants | UPPER_SNAKE_CASE | `[A-Z][A-Z0-9]*(_[A-Z0-9]+)*` |
  | Functions, methods, parameters, locals, captures, fields, aliases | lower_snake_case | `[a-z][a-z0-9]*(_[a-z0-9]+)*` |

  Consecutive capitals are allowed, so `IOError` and `UInt8` stay valid. A
  single word in capitals, such as `MAX` or `T`, fits both of the first two
  forms. `_` stays the discard; no other name starts with an underscore.
  Module paths such as `_base` are paths, not names, and are unaffected. A
  test file's suite constant becomes `TESTS`; `TestSuite`'s `tests` field
  stays.
- **`_` parameters (added during landing 1):** a function, method or
  requirement parameter may be `_`, as a lambda's already may, and one
  signature may have several. A `_` cannot be used: any use in the body is an
  error. This holds for every parameter type, function types included.

## Coordinator choices, confirmed by Keith

Made to fill gaps in the decisions above, and confirmed by Keith on
2026-11-10.

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
- **Order and ceilings:** the seed rotation's place and every ceiling in
  "Landings".
- **Information lost with the path:** when `with_temporary_directory`
  cannot remove its directory, the error no longer names it (D34's exception);
  the caller has only the body's `Path`.

## Proposed solution

### Naming rules

**Classified once, at the lexer.** The lexer already scans each identifier's
bytes; it records the result on the token as a closed type, so no later phase
reads a spelling to decide anything (`valid_type_parameter_name`'s comment in
`common/syntax/parse.brp` anticipates this). A single capital word fits two forms,
so the type has one case for it:

```blorp
fixed union NameForm:
    LowerSnake          -- read_text, x1, utf8_valid
    UpperSnake          -- MAX_DEPTH, HTTP_2: an underscore, no lowercase
    SingleCapitalWord   -- MAX, T, IO: a constant or a type
    CapitalizedCamel    -- ReadError, IOError, UInt8: a lowercase letter
    Malformed           -- _x, a__b, a_, A_b, mixedCase
```

The form lives on the token rather than in the name table, because filling
the name table is a host call that would need a seed rotation.

**Checked once, where a name is declared.** Today every name goes through
`consume_name(message)`, about 30 call sites, some of which consume a name
being used rather than declared. Each declaring site calls
`consume_declared_name(role)` instead, where `role` is a closed type
(type, constant, value, and so on), so a site cannot forget its check. The
declaring sites are every declaring production in `grammar.ebnf`: unions,
records, opaque types, traits, variants and their payloads, type
parameters, constants, functions, trait and `implements` methods,
parameters of functions, methods and lambdas, locals, `var`s, pattern,
list-rest (`...rest`), tuple and `?=` binders, loop binders, fields and import
aliases. `foreign func` is not yet parsed on main; when it is, its Blorp name
is checked and its C symbol is not. Module paths, builtin labels and keywords
are exempt. A name in the wrong form is a parse error whose help gives the
converted name:

```text
error: a local is written in lower_snake_case
help: write `kind`
```

Conversion to lower_snake_case splits before a capital that follows a
lowercase letter or digit, and before the last capital of a run that is
followed by a lowercase letter: `ReadError` is `read_error`, `IOError` is
`io_error`, `UInt8` is `u_int8`. To UPPER_SNAKE_CASE it is the same split,
upper-cased. Both are tested.

**Used names.** A name that is used refers to a declaration that passed its
check, so it needs none, with one exception: after a lowercase receiver,
`x.Foo` cannot be a field or a method, and is a parse error ("fields and
methods are lower_snake_case"). In a pattern, case now tells a variant
(`Empty`) from a binding (`empty`), so the parser can record which it is.

**Aliases and locals.** An import alias shares the value namespace with
locals and parameters (`grammar.ebnf`, binding reuse), which is likely why
tests chose capitals. Lowercase aliases may now collide with a local of the
same name; the migration renames whichever is clearer. `grammar.ebnf`'s
"`_name` remains an identifier" changes with the leading-underscore rule.

Assembly's suite discovery looks for `TESTS` instead of `tests`, and every
test file, the test driver and both READMEs change with it.

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
- **Syntax.** With the naming rules, the tokens' forms settle a
  capitalized `X.Y`, in an expression and a pattern alike. An import alias,
  a method and a field are lower_snake_case, so `X.Y` on one line, where `X`
  is a type's form and `Y` a variant's (each `CapitalizedCamel` or a single
  capital word, so `Kind.A` qualifies), can only be a qualified variant.
  Today every capitalized name after a dot is a parse error, so no valid
  program changes meaning. The parser mints the form in every expression
  position, constant initializers included, as its own syntax over one
  record, `ParsedUnionVariant { union_name, variant }`: `VariantName`,
  `VariantApplication`, and `UnionHead` in a pattern. `ParsedQualified`
  stays alias-only, because it is shared with qualified types and receiver
  names, where a union qualifier would be an illegal state. A lowercase
  `x.y` is still an alias call or a field, decided by the parser's alias set
  as today; the new rule sits beside that check and removes nothing.
  `alias.Variant` keeps its current meaning. `alias.Union.Variant` is not
  supported unless Keith decides otherwise (asked 2026-11-10), because
  `read.NotFound` already names that variant.
- **Chains.** `Kind.A.to_string()` is a method call on the variant;
  `Kind.A.B` is a parse error whose help says a variant cannot be followed
  by another variant.
- **Resolution.** A variant is exactly as visible as its union, which the
  namespace already records, so no new query or offer check is needed. One
  checker function resolves `X` as a visible union type and `Y` in its
  declared variants ("ReadError has no variant Missing", with the variants
  listed), and feeds the existing qualified-variant planning. An opaque type
  is not a union, so its representation stays hidden. In a pattern, the
  union must be the scrutinee's, with its own error ("ReadError.NotFound is
  a variant of ReadError, but the matched value is a WriteError"). An `X`
  that is not a visible union is an error naming what it is: "MAX is a
  constant, not a union", "Point is a record, not a union", "Int is a
  builtin type, not a union", or "ReadError is not a union in scope" with
  the help to import its module. The compiler knows only loaded modules, so
  it does not guess which module to import.
- **No expected type needed.** A qualified variant of a non-generic union
  names its type, so `x = ReadError.NotFound` checks without an annotation;
  the "constructor needs an expected union type" help suggests the qualified
  form. A generic union's variant (`Result.Ok(x)`, `Option.None`) still needs
  an expected type to fix its type arguments.
- **Representation.** None changes: a qualified variant resolves to the
  variant id a bare one gets. `grammar.ebnf`'s "bare variants resolve in the
  expected union type" is inaccurate today (the name picks the variant, and
  the expected type only checks it) and is corrected.
- **Formatter.** New syntax nodes, formatted as `alias.name` is
  (`format/flat.brp`, `format/layout.brp`). A qualified variant is an atom:
  the chain rule links only postfix calls, so
  `ReadError.Failed(x).to_string()` has one link, as `alias.f(x).g()` does.
- **Helps that point to the qualified form.** Where a bare variant fails
  today, the help names `ReadError.NotFound`: a non-generic variant with no
  expected type, a variant of an imported union that was not itself
  imported, and two imported variants that share a name.

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
(`src/common/codegen/runtime/fs.brp`, `process.brp`, `system.brp`) and the system
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
  `FILESYSTEM_DECISIONS.md` today; landing 7 documents it.
- **`io/fs.brp`** is deleted, and `io/error.brp` with it.

**`io/environment`.** `get_current_directory` returns
`Result[Path, CurrentDirectoryError]`: `NotFound`, `PermissionDenied`,
`InvalidUtf8`, `Unreachable` and `OtherOs(Int)`. `Unreachable` is Linux's
working directory outside the process's root, today's "native path must be
nonempty and absolute" message; the "exceeds the String capacity" case
becomes `OtherOs`. Today's builtin returns English text
(`src/common/codegen/runtime/system.brp`), and the compiler calls it (`load.brp`),
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

1. **Naming rules.** `NameForm` on identifier tokens, folded into the
   lexer's existing scan; `consume_declared_name(role)` and its messages;
   `TESTS` discovery; the migration of `src/`'s 3 aliases and of every test
   file, fixture and embedded program that breaks a rule. `README.md` and
   `grammar.ebnf` (the identifier productions and the `_name` sentence). No
   seed rotation: the seed does not enforce the rules. The compiler under
   test compiles its own source and the tests in the fixpoint, so `src/` and
   the test migration both land here.
   - Tests: each role with a name in each wrong form and its help; the
     conversion cases above; `x.Foo`; `_` still a discard; `TESTS`
     discovery, and a lowercase `tests` refused.
   - Ceilings: production lines at most +380 (was +200). Self-compile
     allocations and retired instructions each at most +0.3%. Test changes
     reported separately.
   - Coordinator correction, 2026-11-10: production measures +379 net
     (+1929 −1550) against `4024ef09d`; self-compile +0.039% allocations
     and +0.226% instructions, with identical C. The +200 predates the scope
     that landed here:
     - Keith's `_` parameters, about +100. `ParsedParameter` holds a
       binder, record fields became their own `ParsedField`, `builtin`
       bodies take operands by position, and the formatter changed.
     - The reviews' fixes: a capitalized pattern name is always a variant,
       the dead `ConstructorUFCS` error is deleted, and a conversion that
       is a keyword gets its own help.
     - `src/` had 25 capitalized aliases, not 3.
   - Follow-ups, not done here:
     - an opaque `DeclaredName`, so a declaring site cannot skip its check
       even by calling the token reader directly;
     - one shared set of ASCII class helpers for the lexer and `naming.brp`;
     - `import: dict` alone gives no qualified access, so tests alias it as
       `dict_ops`;
     - the two `count` parameters in `parse.brp` become `_` after landing 5,
       because the pinned seed cannot parse `_` parameters.
2. **Qualified variants.** The parser's new syntax (`common/syntax/syntax.brp`,
   `parse.brp`), the checker's resolution (`check/constructors.brp`,
   `patterns.brp`, `expressions.brp`, `bodies.brp`), diagnostics
   (`errors.brp`, `render.brp`), the formatter, `README.md` and
   `grammar.ebnf` (the qualified-form and pattern-head productions and
   comments, the expected-type sentence). No library change, and no use of
   the form in `src/` until the seed rotation.
   - Tests: qualified constructors and patterns; two imported unions that
     share a variant name, used qualified; `x = Kind.NotFound` unannotated; a
     constant `DEFAULT: Kind = Kind.A`; a wrong-union and an unknown variant
     (`Kind.Missing`); a private variant and an opaque union refused; a union
     not imported, with its help; `MAX.Foo` and `Point.X` refused;
     `Kind.A.B` refused; `Result.Ok(x)` with and without an expected type;
     the formatter's chain case. The parser and ergonomics review
     (2026-11-10) added: interpolation, nested and or-patterns, payload
     arity, `Option` patterns, a type parameter, builtin, opaque type, trait
     or constant as `X`, a union declared after its use, `alias.func` and
     `alias.Variant` unchanged, identical C to the bare form, and the two
     e2e fixtures whose capitalized `X.Y` changes meaning.
   - Ceilings: production lines at most +300. Self-compile allocations and
     retired instructions each at most +0.3%.
   - Review: parser and ergonomics review done 2026-11-10 (no blockers;
     its corrections are in "Qualified variants" above); documenter review
     after.
3. **`Path` in `path.brp`, beside the String functions.** P2 to P5, `+`,
   P10's methods except two, `PathError` and unit tests. No compiler change.
   `join` and `normalize` already name String functions in `path.brp`, and a
   module cannot declare one name twice, so their `Path` forms arrive in
   landing 7, which deletes the String ones.
   - Ceilings: production lines at most +185 (was +130); self-compile
     allocations and instructions each at most +0.3%.
   - Coordinator correction, 2026-11-10: `path.brp` measures +185 net by
     `git diff --numstat` (130 without blank and comment lines). The +130
     was set before Keith added `+` (`Addable`), and did not count
     `PathError`'s `Stringable`, the wider import block, or the comments
     that document each edge-case rule.
4. **The current-directory native.** A new builtin returning a code, beside
   the old one, with no library caller yet.
   - Ceilings: production lines at most +60; self-compile unchanged.
5. **Seed rotation** after landings 2 and 4, so seed-built code (`src/`,
   `scripts/`, the library the compiler embeds) may use qualified variants
   and the new native. Until then it uses neither.
6. **Process and environment errors.** `io/environment` and `io/process`:
   `CurrentDirectoryError` on the new builtin, the process unions,
   `Command.directory: Option[Path]`, `find_program` returning `Path`, and
   their callers and tests. The old current-directory builtin is deleted.
   `PROCESS_DECISIONS.md` and both READMEs' process and environment sections
   are updated. The rest of process L2 (`Command.program`, removing
   `run_to_files`) stays in the process plan.
   - Ceilings, estimates: compiler production lines at most +10 net;
     standard library at most +80 net. Self-compile allocations and
     instructions each at most +0.2%.
7. **Files.** The `io/fs/` modules with `Path` signatures and exact errors;
   `join` and `normalize` on `Path`. `io/fs.brp`, `io/error.brp`,
   `IOErrorKind`, `default_if_not_found`, the String functions in `path.brp`,
   `cli.file_name` and `module_stem` are deleted. Every caller, both READMEs'
   file sections and `FILESYSTEM_DECISIONS.md` are updated.
   - Ceilings, estimates: compiler production lines at most +30 net;
     standard library at most +220 net, mostly the unions, their decoders and
     their text. Self-compile allocations and instructions each at most
     +0.3%. Test growth reported separately. With landing 6, these keep the
     single landing's budget (+40, +300, +0.5%).
8. **The prelude.** `Path` and `to_path`. The prelude loads all of
   `path.brp`, and every loaded module is checked in full; today's
   `path.brp`, with similar functions, cost +13,222 allocations and +10.7%
   instructions to compile an empty program (measured at about `ce8753b6f`,
   against 89,222 allocations and 333.6 M instructions). Ceilings: the
   empty-program compile at most +15,000 allocations and +12% instructions,
   remeasured on landing 3's module before this landing starts; self-compile
   at most +0.1%; e2e ceilings reset with their existing margins and
   recorded.

Landings 1, 3 and 4 are independent. Landing 2 needs 1; landing 5 needs 2 and
4; landing 6 needs 3 and 5; landing 7 needs 6; landing 8 needs 7.

## Audit, 2026-11-10

A re-audit of the plan against the code, the other plans and the work in
flight found the following.

**Settled by Keith:** `join` and `with_extension` could have built a `Path`
holding a NUL byte from their String argument. Keith decided that `to_path`
is the only way from a String to a `Path`, that `join` takes two paths and
puts the second under the first, that `+` concatenates, and that
`with_extension` is dropped (recorded under P1, P4 and P10). Every path
piece written as a literal now goes through `to_path` and its own `?=`:

```blorp
suffix ?= "${name}_test".to_path()
executable = directory.join(suffix)
```

A directory entry's name stays a String (P8), so joining it also goes
through `to_path`, although the system never gives an empty name or one
holding NUL.

**Decided by the coordinator, from the decisions above** (Keith may
overturn any; the `fault` handling and the exit status change behaviour):

- **Paths the system gives the library** (the working directory, a found
  program, a temporary directory) never hold NUL and are never empty, but
  only `path.brp` can build a `Path` directly (`into_opaque` is private to the
  defining module). The library builds them with `to_path`, and an `Err`
  there is a disagreement between runtime and library, handled with
  `io/process`'s existing `fault`, as a reply the C side never builds is
  today.
- **Landing 6 is split** into process and environment errors (6) and files
  (7), so each is one change, within the single landing's budget; the
  prelude becomes landing 8.
- **Order with other plans.** Process L2 (the 17 `run_to_files` call sites)
  follows landing 6, and `RUN_AND_TEST_PLAN.md`'s CLI landing, which also
  uses files, follows landing 7, so their call sites are written once,
  against the final errors and `Path`.
- **Command-line paths.** In landing 7, a `blorp` path argument that is
  empty is a usage error (exit 2, `CLI_PLAN.md` D6) with `PathError`'s text.
  Arguments cannot hold NUL.
- **Prelude names.** Landing 8 makes `Path` and `to_path` prelude names, so a
  user type `Path` or function `to_path` is "provided by the prelude". None
  exists in the repository today.
- **Naming migration scope,** added to landing 1's brief:
  `benchmarks/blorp/dict_ops.brp`, the examples in both READMEs,
  `blorp/AGENTS.md`'s test-suite sentence and `docs/CODE_STYLE.md`'s naming
  section. `benchmarks/legacy/` belongs to the pinned legacy compiler and
  the deferred suites are not compiled, so neither changes.
- **Landing order among 1, 3 and 4.** Whichever lands after landing 1
  rebases onto it and conforms to the naming rules before it lands.

**Checked and fine:** no local or remote branch other than these landings
has unmerged work (checked 2026-11-10); `Hashable` (with `Equatable`) is all a `Dict` key needs; the
embedded-library generator already emits `EMBEDDED_LIBRARY_PATHS`;
`FILESYSTEM_DECISIONS.md` D40 (`String.lines()`) is pure and independent.

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
  `Path` module, which landing 3 measures.
- The variant sets come from reading the runtime and the system calls'
  manual pages; "race only" entries are judgement. Landings 6 and 7's tests
  cover each deterministic variant per operation.
- `Err(ReadError.NotFound)` was probed with a module-qualified variant
  (`Err(read.NotFound)`), which nests today; the union-qualified form is
  landing 2's.
- The migration counts are rough greps; landing 1's brief recounts them, and
  its line ceiling covers production code only.
