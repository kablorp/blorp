# Nested modules, `Stringable`, `io/` and the prelude

Plan revision 2, 2026-11-09. Keith decided every point in "Decisions" below in
discussion on 2026-11-09. "Probe results" answers the technical questions the
decisions left open.

## Problem

- **Flat library.** The standard library is flat, and a bare import path names
  one file under the library root. Related modules cannot be grouped, so `io`
  mixes console output (`print`, `print_error`) with the error identity that
  `fs` and `process` share (`IOError`, `IOErrorKind`, `describe`).
- **Colliding `describe`.** Each library error type gets its own `describe`:
  `io`'s today, JSON's with its pending review fix (`blorp/json-review-fixes`),
  and `process`'s with the process API. A program that imports two of them by
  name gets "describe is already imported", and passing one as a value needs a
  module alias.
- **String-only interpolation.** A hole must already be a String, so
  `"${count} items"` has to be written `"${count.to_string()} items"`, and an
  error cannot be interpolated at all.
- **No prelude output.** The prelude has no output, so even hello-world must
  import `io: print`.

## Decisions (Keith, 2026-11-09)

1. **Nested library modules.** A library module may live in a folder, as
   `standard_library/io/error.brp`, imported as `io/error`. A module file
   beside a folder of the same name (`io.brp` next to `io/`) is an error.
2. **One main type per module where possible.** A module is named after the
   data type it owns. Selecting that type brings its functions in through UFCS,
   so one import name gives the whole API.
3. **`Stringable`, and nothing else for now.**

   ```blorp
   trait Stringable:
       pure func to_string(value: Self) -> String
   ```

   - Int, Float, String and Bool implement it, and so does every library error
     type.
   - It means "can be converted to a String". There are no rules about human
     versus program text.
   - A human-facing `Displayable` with `display` is deferred.
   - Records, unions, Lists, Options and tuples don't implement it unless their
     author writes the implementation; nothing derives it.
4. **Interpolation uses `Stringable`.** `${…}` accepts any implementor, and a
   hole whose type does not implement it is an error that names the trait.
5. **`describe` is replaced.** `IOErrorKind` implements `Stringable` with
   today's phrase table ("no such file" … "operating system error 24").
   `IOError` implements it with today's exact text ("<path>: <phrase>", with
   the destination for two-path operations), built on the kind's text. Then:
   - `describe` is deleted, with no alias;
   - JSON's `ParseError` gets the same treatment, once its `describe` lands
     with the pending JSON review fix;
   - `process`'s `ProcessError` and `ProcessErrorKind` get the same
     treatment (process L1 landed before this plan's landings; see
     "Landings");
   - code still branches on `error.kind`, never on the text.
6. **The `io/` layout.**

   ```
   io/console.brp      print, print_error
   io/error.brp        IOError, IOErrorKind
   io/fs.brp           the filesystem operations, Entry and EntryKind
   io/process.brp      Command, Exit, Captured, ProcessError
   io/environment.brp  get_current_directory, absorbing system.brp
   io/_codes.brp       the native-code decoder, today's _io_errors.brp
   ```

   - **Pure data stays top-level:** `path.brp`, `json.brp`, and later
     `bytes.brp`. No `encoding/` folder.
   - **The name `IOError` stays,** rather than a bare `Error`.
   - **`fs` is not split** into file and directory modules until `Path` exists.
7. **The prelude gains `print` and `print_error`.** Purity tracking still marks
   every caller impure. This amends R3 in `FILESYSTEM_DECISIONS.md`, "IO stays
   an explicit import, and the prelude does not change":
   - console output is in the prelude;
   - filesystem, process, environment and networking stay explicit.
8. **`Path` reopens D13, ahead of `Bytes`.** A String-backed opaque `Path`
   carries the filesystem operations as its methods, as in
   `config.read_text()`. `Path` and `IOError` join the prelude when it lands,
   so file I/O needs no import. A `File` handle type is ruled out, because
   Blorp deliberately has no open or close. `Path`'s details get their own
   decisions when its brief is written, and amend D13 in
   `FILESYSTEM_DECISIONS.md`.

## O1, decided

- **A user's own `print` is an error** (Keith, 2026-11-09). Once `print` and
  `print_error` are in the prelude, a user module that declares either gets
  the error that redeclaring a prelude constructor gets today, with help to
  rename it.

## Probe results

Probed on 2026-11-09 against `390945503`, with scratch programs only.

1. **Nested library paths.**
   - **The directory layout works today.** With `--library-root`, the imports
     `io/error: code` and `io/error as E` both compile and run, and so does a
     relative `./error` import between two modules in `io/`. The parser reads
     `a/b` as a library path (`consume_path_parts`, `syntax/parse.brp`), and
     the loader joins every part under the root (`import_path`,
     `compile/load/load.brp`).
   - **The pinned seed accepts the same programs.** Nesting library modules,
     including ones the compiler imports, needs no seed rotation.
   - **The embedded layout does not work.** The generator
     (`scripts/embed_library.brp`, `library_row`) rejects any folder, with "the
     embedded library holds only the files directly under its root". The
     compiler's lookup (`module_store`) already handles `io/error.brp`, so only
     the generator needs to change, and the Makefile, whose
     `standard_library/*.brp` wildcard misses edits in subfolders.
   - **Nothing checks for a file beside a folder.** `io.brp` and `io/` coexist
     today.
   - **Estimate:** 60 to 80 production lines, plus 3 or 4 fixtures (nested,
     alias, relative, collision).
2. **A trait method as a value works today.** `apply(equals, 1, 1)`,
   `result.map_err(describe)` with a scratch trait, and the same inside a
   generic `E: Describe` all compile and run (`PendingMethodCallable`,
   `check/expressions.brp`). So `.map_err(to_string)` needs nothing new. One
   catch: a plain `to_string` and the trait's `to_string` in scope together
   are two method families. Moving Int's and Float's plain `to_string` into
   their trait implementations removes it.
3. **Interpolation through a trait.**
   - **Today:** `"${count} items"` fails with "interpolation hole has type
     Int; expected String".
   - **Design (unprototyped):** the operator traits' route. The prelude designates the trait,
     the checker keeps its `to_string` member in `CanonicalContracts`
     (`check/model.brp`), and each hole is scheduled as a call to that member
     in the `PlannedInterpolation` arm (`check/expressions.brp`). The
     String-equality constraint, its freeze check and the error
     `InterpolationRequiresString` are deleted. Lowering is unchanged. A hole
     whose type is not `Stringable` gets the existing trait-call error, with a
     help line written for holes.
   - **Estimate:** about +90 and −60 production lines, plus fixtures and the
     rewritten expectations that pin "expected String".
   - **Cost risk:** every String hole would become a call to an identity
     `to_string`, and the compiler source has many. A hole's type is not
     always known when the hole is planned: `FinishInterpolation` sees a
     pending inference type, which may hold unsolved slots, as in
     `"${xs.first_or("")}"`. Only `freeze_interpolated`, after solving, sees
     the solved type. So every hole is scheduled as a call, and freezing
     replaces the call with its argument when the hole's solved type is
     String. The landing gates on matched before/after self-compile cost.
   - **Bool:** `Stringable` is declared in `_base.brp` beside the arithmetic
     traits, and Bool implements it in `bool.brp` beside its `Hashable`.
   - **Not run:** no prototype was built, so this design, its line estimate,
     the outputs for `"${flag}"` and `"${3.5}"`, and the non-`Stringable`
     error are all unverified.
4. **The seed.** The seed builds the compiler, the formatter and the
   scripts, so what they may use is what the seed accepts.
   - Interpolating a non-String, as `"${error}"`, needs a seed that knows the
     new rule (landing 6).
   - **Unverified:** the probe ran the seed only on nested-path programs. That
     it accepts a trait `to_string` in place of Int's plain one (about 94 UFCS
     uses in `src` and `scripts`, including on literals, as `5.to_string()`),
     and `.map_err(to_string)` with a trait method, is likely, because the
     arithmetic traits already work this way, but has not been run.

## Landings, in order

1. **Nested library modules.** No rotation.
   - The generator recurses into folders and writes names like
     `io/error.brp`, in byte order.
   - The Makefile's prerequisites see subfolders.
   - The loader rejects a file beside a folder of the same name, in both
     layouts. It is the single authority: the generator only lists files.
   - Fixtures and the README.
2. **`Stringable`.**
   - The trait in `_base.brp` and the prelude.
   - Implementations for Int, Float, String and Bool. Int's and Float's plain
     `to_string` become their implementations. A `.to_string()` call reaches
     the member through its receiver, so no module's imports change, library
     modules included. Only `to_string` named as a value needs an import, as
     `int: to_string`, which follows `int: equals`.
   - `${…}` accepts implementors. Freezing replaces the call with its
     argument when a hole's solved type is String.
   - **First step:** run the seed on a library with the trait in place of
     Int's plain `to_string`, including `5.to_string()`. If the seed rejects
     it, the rotation (landing 6) moves ahead of this landing.
   - **Budget correction (coordinator, 2026-11-09):** the production-line
     ceiling went from +70 net to +75 net. The smallest design measured +72,
     and 8 of those lines are the formatter putting `string.brp`'s imports one
     per line. Review then asked for 3 lines of comment. The allocation (+0.3%) and instruction (+0.5%) ceilings are
     unchanged; it measured +0.026% and +0.044%.
3. **Errors become `Stringable`.**
   - `IOErrorKind`, `IOError`, JSON's `ParseError` and `process`'s
     `ProcessErrorKind` and `ProcessError` implement it.
   - `describe` is deleted, and every caller and README is migrated. Code the
     seed builds (`src/main.brp`, `load.brp`, `scripts/embed_library.brp`)
     uses `.to_string()` calls and lambdas, unless the seed is shown to
     accept `.map_err(to_string)`, and can't write `"${error}"` until
     landing 6.
4. **The `io/` move,** as in decision 6, with every import migrated: the
   compiler, the tests and the docs. `process.brp` becomes `io/process.brp`.
   It needs landing 1.
5. **The prelude:** `print` and `print_error` (decision 7), with R3 amended.
   O1 is decided: a user's own `print` is an error.
6. **A seed rotation.** It lets library and compiler code interpolate
   non-Strings, and carries the pending seed-family switch and the seed's
   move to the `blorp compile` command line (`UINT8_BYTES_PLAN.md`, L2). It can
   go any time after landing 2, and the `"${error}"` clean-up in seed-built
   code follows it. The new seed also knows the process natives, which
   `blorp run` and `blorp test` need (`RUN_AND_TEST_PLAN.md`).
7. **`Path` (D13),** with its own brief and decisions.

Process API L1 was planned here as a landing after the rotation, as
`io/process` with a `Stringable` `ProcessError`. On 2026-11-09 Keith chose to
land it first instead, as `process.brp` with its own `describe`, so that the
rotation in landing 6 carries its natives and `blorp run` needs no second
rotation. Landings 3 and 4 migrate it with the other error types.

Each landing gets its own brief, with ceilings set before implementation. The
landings that touch the compiler record matched self-compile and fixed-input
costs.
