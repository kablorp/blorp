# The `blorp` command

Status: approved by Keith on 2026-11-07 (revision 3, after two reviews), with
D6 decided as the five statuses. The embedded standard library (P2) gets its
own design note; this plan sets its ceilings. Implementation starts after the
`src/` layout split (`syntax/`, `compile/`, `format/`, `utils/`) lands; paths
below that name `compile/` assume it.

## Problem

The compiler is invoked as a positional-argument program whose first
arguments must be a library root:

```sh
blorp/build/compiler --library-root blorp/standard_library input.brp output.c
blorp/build/compiler --library-root blorp/standard_library --test-suite SUITE.brp [SUITE.brp ...] OUTPUT.c
blorp/build/compiler --format FILE...
blorp/build/compiler --check FILE...
```

- A user must know where the standard library lives to compile anything.
- Modes are flags in the first position, so the commands do not read as
  verbs, and `--format`/`--check` take files only: no directories, no
  exclusions.
- A wrong argument list prints one generic usage message whatever the user
  was trying to do, and every failure, including a fault in Blorp itself,
  exits 1.

Keith (2026-11-07) asked for:

```sh
blorp compile src/main.brp
blorp format
blorp format some_dir
blorp format main.brp
blorp format --exclude tests/format .
blorp format --check
```

## Background

### Decisions (Keith, 2026-11-07)

1. **`blorp compile` emits C**: to `-o PATH`, by default `<input stem>.c` in
   the current directory. Building and running an executable is a later
   `blorp run`.
2. **The standard library is embedded in the binary** at build time, as the
   legacy compiler did: its Makefile had the seed build a generator
   (`blorp/tool/generate_build_sources.brp`) that wrote
   `blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp`, and its
   frontend graph consulted `embedded_std_contains_module` (see
   `a52cf7d44^`). `--library-root DIR` stays as an override.
3. **Exclusions are a repeatable `--exclude PATH` flag.** No environment
   variable: the standard library has no environment read.
4. **Files that do not parse fail.** A walk that meets one reports its
   diagnostic and fails; it never skips silently.
5. **`blorp test SUITE.brp ...`** replaces the `--test-suite` mode, and, as
   proposed, compiles, links and runs the suite program.

Also proposed with those decisions and not objected to: the executable is
`blorp/build/blorp` with a `bin/blorp` link at the repository root, and
`blorp help [command]`. The exit statuses proposed with them (0, 1, 2) are
reopened as D6.

### D6: exit statuses (decided: five statuses, Keith, 2026-11-07)

The first proposal had three (0, 1, 2) and put "bad usage" with "a fault in
Blorp" under 2. Review showed that loses distinctions callers already use:
`scripts/blorp-fixpoint` `classify()` (`:117-125`) separates internal faults
from diagnostics, and an unwritable output or unreadable input is neither a
usage error nor a fault in the program. Recommended:

| Status | Meaning |
| --- | --- |
| 0 | success |
| 1 | the code needs fixing: a diagnostic, a file that does not parse, a file `--check` would reformat |
| 2 | bad usage: unknown command or option, missing or extra argument |
| 3 | a path could not be read or written |
| 4 | a fault in Blorp itself (an internal error; report it) |

The rejected alternative was the original three, with 3 and 4 folded into 2.

### Current callers of the old interface (at `aab3b4bbd`)

- **The seed** (old interface until rotation): `blorp/Makefile:36`
  (`generate-compiler`, through `scripts/blorp-compiler-bootstrap`),
  `.github/workflows/blorp-seed.yml:79`, and the fake seed in
  `blorp/test/tooling/test_bootstrap.sh:41,95,274`, which must keep the seed
  form.
- **Current-source compilers** (move in P1): `blorp/Makefile:48,92`;
  `.github/workflows/blorp-seed.yml:95,110,140,176,190` (it also accepts only
  exit 0 or 1 at `~142-157`); `scripts/blorp-fixpoint:106` and its
  `classify()`; `benchmarks/bench.sh:52`; `blorp/scripts/attribution/run:35`;
  the e2e driver (`blorp/test/e2e/self_hosted_harness.brp:380,566,859`,
  `self_hosted_calls.brp:92` (usage text), `:1365-1386`,
  `self_hosted_strings.brp:60`, `self_hosted_selection.brp:92`,
  `self_hosted_format.brp`); the unit suites
  `test/unit/test_harness/test_self_hosted_selection.brp:254`,
  `test/unit/test_check/test_structural_patterns.brp:60` and three more found
  by `git grep -E "build/compiler|--library-root|--test-suite"`; the READMEs,
  `blorp/AGENTS.md`, `blorp/FORMATTER_PLAN.md`, `scripts/README.md`.
- `BLORP_COMPILER` and `BLORP_COMPILER_C` in `blorp/Makefile` keep their
  names; their values become `blorp/build/blorp` and `blorp/build/blorp.c`.

## Proposed solution

### Commands

```text
blorp compile INPUT.brp [-o OUTPUT.c] [--library-root DIR]
blorp compile --test-suite SUITE.brp [SUITE.brp ...] -o OUTPUT.c [--library-root DIR]
blorp format [--check] [--exclude PATH]... [PATH ...]
blorp help [COMMAND]
blorp test SUITE.brp [SUITE.brp ...]          (P3)
blorp run INPUT.brp [ARGUMENT ...]            (P3)
```

- **`compile`** loads the input and its imports, with the standard library
  from the embedded copy unless `--library-root` is given (required in P1,
  optional since P2), and writes C atomically (today's `publish`). An input must end in
  `.brp` and have a nonempty stem; the output must not be one of the inputs.
  Default output: `<input stem>.c` in the current directory, so
  `blorp compile src/main.brp` writes `./main.c`; the help text says so.
- **`compile --test-suite`** is today's suite mode, unchanged in meaning,
  until `blorp test` replaces it in P3. It requires `-o`: suites from
  different directories have no single natural stem.
- **`format`**: below.
- **`help`**, and `-h` or `--help` anywhere in a command, print usage to
  stdout and exit 0. `blorp` with no command prints the overview to stderr
  and exits 2. There is no `--version` yet; it is an unknown option.
- **`test` and `run`** (P3) compile, link with the configured C compiler and
  run; they get their own plan, which also decides where the C compiler
  setting lives (Make owns `BLORP_CC` today).

### `blorp format`

- Each `PATH` is a `.brp` file or a directory; no `PATH` means `.`.
- **Directories** are walked recursively in byte order of entry name.
  Walked entries whose names start with `.` are skipped, and walked symbolic
  links are not followed (to files or directories). A `PATH` given
  explicitly is used as given, even if hidden or a link. A directory whose
  name ends in `.brp` is a directory.
- **Paths are normalized** with `path.normalize` from the standard library
  before anything else: printed paths are `normalize(join(root, relative))`,
  so `blorp format --check .` prints `src/a.brp`, and a file reached from
  two roots is processed once, at its first occurrence.
- **`--exclude PATH`** (repeatable) removes a normalized file, or a
  normalized directory and everything below it on component boundaries
  (`--exclude a/b` excludes `a/b/c.brp`, not `a/bc.brp`). An excluded path
  that does not exist, or that lies outside every root, is a usage error
  naming it.
- **A file that does not parse** prints the parser's rendered diagnostic, is
  left untouched, and counts as a failure (status 1) in both modes; the
  other files are still processed. `--check` prints `path:line: would
  reformat` for each parsable file that would change.

For this repository, the formatting gate becomes, once the cleanup below has
landed:

```sh
blorp format --check --exclude blorp/test/unit/test_format/fixtures \
    blorp/scripts blorp/src blorp/standard_library blorp/test
```

and `test_repository_formatted.brp` is deleted in favour of it. The roots are
named explicitly so the gate never walks build output, and the layout
fixtures' inputs are unformatted on purpose. This landed on 2026-11-07 as
`make -C blorp format-check`, after the unparsable old-syntax suites were
deleted; it also excludes the four must-fail fixtures that do not parse.
Until a per-file opt-out exists, a bare `blorp format` run in place from the
repository root would also rewrite those fixture inputs; the README's
contributor note says to format the files you changed or to run the gate's
command.

### Parsing

`main` matches the command word and hands the rest to that command's parser,
which returns a request record or a usage error; this follows the driver's
`parse_invocation` (`blorp/test/e2e/self_hosted_selection.brp:302`), a
`Result` of a request and a usage message. Each command has its own record,
so no option can reach the wrong command:

```blorp
-- P1: the library root is required, so the record holds it plainly.
record CompileRequest {
    inputs: CompileInputs,
    output: String,
    library_root: String
}

-- A suite list is never empty: the first suite owns the entry, and the
-- rest follow it in command-line order.
union CompileInputs:
    ProgramInput(String)
    SuiteInputs(String, List[String])

record FormatRequest {
    roots: List[String],
    excluded: List[String],
    check: Bool
}
```

P2 replaces `library_root: String` with a `LibrarySource` union
(`EmbeddedLibrary | LibraryDirectory(String)`) in the same landing that
makes the embedded copy exist, so no state is ever representable that the
code must reject. The argument parsing lives in a new `src/cli.brp`
(`main.brp` is already about 270 lines), pure and unit-tested; `main.brp`
keeps the I/O.

### Embedded standard library (P2)

P2 gets its own design note before any code. It must answer: where the
generated module lives so that `src/` imports it like any other module on a
clean checkout and in every build that compiles `src/main.brp` (Make, the
fixpoint's stage builds, `test_bootstrap.sh`); what builds and runs the
generator (the legacy one was built by the seed); the generated module's
shape and escaping; and how Load chooses between the embedded copy and
`--library-root` through the `LibrarySource` union, with no flag beside an
option. Its ceilings are set now: compiler binary size within +256 KB of
P1's (the library is about 63 KB of source); self-compile allocations and
retired instructions each within +1%; `make -C blorp compiler` wall time
within +10% (to be confirmed once measured).

### Phases

1. **P1: the `blorp` command.** `src/cli.brp`, the new `main`, `compile`,
   `compile --test-suite`, `format` with walks, exclusions and `--check`,
   `help`, the exit statuses of D6, the rename to `blorp/build/blorp`, and
   `bin/blorp` as a tracked symbolic link to `../blorp/build/blorp`
   (dangling until built; deliberately tracked, so a checkout needs no
   install step, and Blorp targets macOS and Linux only). Every
   current-source caller above moves, including the driver's suite compile
   (`self_hosted_harness.brp:566`), whose argument shape changes to `-o`;
   `classify()` in `scripts/blorp-fixpoint` and the seed workflow's status
   check are updated to D6's statuses; the seed callers stay.
2. **P2: the embedded standard library**, after which `--library-root` is
   optional. Landed; the design note is `EMBEDDED_LIBRARY_PLAN.md`.
3. **P3: `blorp test` and `blorp run`**, in their own plan.

Separately, Decision 4 means `blorp format --check` over `blorp/` fails until
its 344 unparsable `.brp` files (old-syntax suites that never run, plus
must-fail parser fixtures) are deleted, ported or excluded. That cleanup is
its own change; the gate switches to the command after it.

## Code

### P1: argument dispatch

Today, `src/main.brp:154-171` (at `aab3b4bbd`):

```blorp
func main(args: List[String]) -> Int:
    match args:
        -- The last path is the output; any paths before it are later suite roots.
        [_, "--library-root", library_root, "--test-suite", root_path, ...later_and_output]:
            ...
        [_, "--library-root", library_root, input_path, output_path]:
            input_path.load_program(library_root).compile_loaded(output_path)
        [_, "--format", ...paths]: paths.format_files(FormatInPlace)
        [_, "--check", ...paths]: paths.format_files(ReportUnformatted)
        _: usage_error()
```

After:

```blorp
func main(args: List[String]) -> Int:
    match args.drop(1).parse_command():
        Ok(Compile(request)): request.compile()
        Ok(Format(request)): request.format()
        Ok(Help(text)): text.print_help()
        Err(usage): usage.report_usage()
```

## Scope and non-goals

In scope: `src/main.brp`, the new `src/cli.brp`, `format`'s file handling
(walks and exclusions), Load's library source (P2), the generator (P2), Make,
scripts, CI, the e2e driver, the unit suites that call the compiler, and the
documents naming the old interface.

Not in scope: `blorp test` and `blorp run` (P3); environment variables;
configuration files; glob patterns in `--exclude`; deleting the unparsable
files; `--version`; the pinned seed.

## Risks and unknowns

- **The seed keeps the old interface.** Done: the rotation to
  `blorp-seed-10c8053d2399` (MODULES_AND_STRINGABLE_PLAN.md landing 6) moved
  the pin, the seed family, the Makefile, the seed workflow and the fake seed
  in `test_bootstrap.sh` to the `compile` command line together.
- **Exit statuses during the window.** Until the rotation, the seed still
  exits 1 for internal faults. `classify()` sees only current-source
  compilers, so this does not affect it; the seed's own call in Make treats
  any nonzero status as failure, which stays right.
- **Embedded library (P2):** its design note and the ceilings above.

## Testing

- **Unit (`src/cli.brp`, pure):** every command's parse: defaults (`compile
  src/main.brp` → output `main.c`; `format` with no paths → roots `["."]`),
  each option, repeated `--exclude`, `-h`/`--help`, unknown command and
  option, a missing input, an input without `.brp`, an output equal to an
  input, and the exact usage text of each error. These cover the default
  rules without running a child in another directory.
- **e2e, new `blorp/test/e2e/self_hosted_cli.brp`** (registered in the
  driver), exact stdout, stderr and status for:
  - `compile` with `-o`; a missing input (status 3); a diagnostic (1); an
    unwritable output (3);
  - `compile --test-suite` with one and two suites;
  - `format` on a file and on a directory, `--exclude` of a file and of a
    directory, an excluded path that does not exist and one outside the
    roots (2), including `--exclude ../x` with no `PATH`, a hidden
    directory and a symbolic link inside a walked tree, an
    unparsable file in a walk (1, others still formatted), `--check` on
    formatted and unformatted trees, a file given twice;
  - `help`, `help format`, `-h`, an unknown command, no command.
  The existing `self_hosted_format.brp` cases move here.
- **P2:** `blorp compile` with no `--library-root` gives the same C as with
  `--library-root blorp/standard_library`; a library module changed on disk
  and passed with `--library-root` wins over the embedded copy; the
  generator's escaping round-trips every library file byte for byte.
- Gates: `make -C blorp test`, then `make -C blorp test-e2e
  INSTRUCTION_CHECK=on`, `bash blorp/test/tooling/test_bootstrap.sh`,
  `scripts/blorp-fixpoint --prove`.

## Acceptance criteria

- P1: `blorp compile src/main.brp --library-root standard_library -o
  main.c` (from `blorp/`) writes C byte-identical to today's compiler output;
  every test above passes; `git grep -E "build/compiler|--format |--check "`
  finds only the seed callers and history; the fixpoint passes.
- P2: `blorp compile src/main.brp` (from `blorp/`) writes the same C; every
  ceiling holds.
- All gates pass after each phase.

## Release strategy

P1 and P2 land separately, each with green gates. P1 breaks the command
line: every current-source caller moves in the same landing (rule 14); the
seed callers move at the next rotation. Back out by reverting the landing.
