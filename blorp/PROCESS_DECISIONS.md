# Process API

`describe` below is history: the error unions implement `Stringable` instead
(MODULES_AND_STRINGABLE_PLAN.md, landing 3). The module is now `io/process`
(landing 4). PATH_PLAN.md landing 6 replaced `ProcessError` and
`ProcessErrorKind` with one exact union per operation, none holding the
program or the directory, and made `Command.directory` an `Option[Path]` and
`find_program` return a `Path`; the types below are as they are now.

Status: approved by Keith on 2026-11-06 (revision 3, after ergonomics,
data-model and feasibility reviews), with P1 to P4 decided as recommended.
Earlier, Keith had approved the direction:
- a command record;
- signals and timeouts as outcomes, not errors;
- explicit PATH lookup;
- text capture until Blorp has bytes;
- no size cap and no resource limits;
- streaming later;
- `Exit` as a `fixed union`.

L0, L1 and L2 are implemented. L2 (2026-11-11) moved every caller to
`capture` and `output` and deleted `run_to_files`, and Keith decided then that
`Command.program` is a `Path`. The Problem below describes the state before
L2. The feasibility review had prototyped the C core on macOS 26 and
Linux arm64, and compiled every declaration and example below against a
scratch library.

## Problem

`process.run_to_files(program, arguments, stdout_path, stderr_path,
timeout_ms) -> Result[Int, String]` is the only way to run a program. Its 17
call sites in 8 files, plus the process suite itself, all do the same work by
hand:

- they invent two capture paths and read them back with `fs.read_text`;
- they change the environment through `/usr/bin/env -u NAME NAME=value`, and
  the directory or limits through `sh -c 'cd "$1" && shift && exec "$@"'`;
- they get an error String they cannot match. A missing program, a script
  without `#!` and a failed `setpgid` look alike, and a child killed by a
  signal or by the timeout is an `Err` whose output is lost.

## The API

Five types and six functions:

```blorp
import:
    io/process:
        Command, Exit(Exited, Signaled, TimedOut), Captured, SystemCallError(...),
        FindProgramError(...), CaptureError(...), OutputError(...),
        command, capture, output, find_program
    path: Path

-- What to run. Build one with `command`, then change fields by record update.
record Command {
    program: Path,                               -- find_program searches PATH
    arguments: List[String],                     -- without argv[0]; each passed literally
    directory: Option[Path],                     -- None runs in the parent's directory
    environment: Dict[String, Option[String]],   -- Some sets, None removes, the rest is inherited
    stdin: Option[String],                       -- None is /dev/null; Some is written, then closed
    timeout_ms: Option[Int],                     -- None waits; Some(n) with n <= 0 times out at once
}

-- How the child ended. Each is an outcome, not an error.
fixed union Exit:
    Exited(Int)        -- its status, 0 to 255
    Signaled(Int)      -- the signal number
    TimedOut           -- the deadline passed, and the child's process group was killed

record Captured { exit: Exit, stdout: String, stderr: String }

-- Why an exec, fork, pipe or chdir failed.
union SystemCallError:
    NotFound
    PermissionDenied
    NotADirectory
    OtherOs(Int)                   -- any other errno, as the platform numbers it

union FindProgramError:
    NotOnPath                      -- no executable regular file of that name on an absolute PATH entry
    NameContainsNul

union CaptureError:
    InvalidVariableName(String)    -- empty, or contains "="; before any system call
    ContainsNul                    -- in an argument or the environment; before any system call
    LaunchFailed(SystemCallError)  -- exec, fork or a pipe failed
    NotExecutable                  -- ENOEXEC: a file the system cannot run, such as a script without #!
    DirectoryFailed(SystemCallError)  -- the child could not enter `directory`
    StdoutNotUtf8(Exit)            -- P1: carries how the child ended
    StderrNotUtf8(Exit)

union OutputError:
    CaptureFailed(CaptureError)
    Unsuccessful(Captured)         -- anything but Exited(0), with everything the child printed

pure func command(program: Path, arguments: List[String]) -> Command
-- { program, arguments, directory = None, environment = {}, stdin = None, timeout_ms = None }

func capture(invocation: Command) -> Result[Captured, CaptureError]    -- every Exit is Ok
func output(invocation: Command) -> Result[String, OutputError]        -- stdout, or Unsuccessful
func find_program(name: String) -> Result[Path, FindProgramError]      -- absolute PATH entries only
pure func succeeded(exit: Exit) -> Bool                                -- Exited(0)
```

`output` is `capture` that insists on success, like Python's `check=True` and
Go's `Output`. `?=` over `output` runs a sequence and stops at the first
failure, carrying everything the failed command printed. It shows nothing
until the command ends; live output comes with streaming. `Stringable` renders
`Unsuccessful` as "exited 2" followed by its stderr, `DirectoryFailed(cause)`
as "cannot enter the directory: <cause>", and every other variant with fixed
text. No text names the program or the directory: the caller has its `Command`.

## Examples

```blorp
-- A caller that mixes operations writes its own error type; a constructor is
-- not a function value, so the wrapping is a lambda or a match.
union CommitError:
    GitMissing(FindProgramError)
    GitFailed(OutputError)

-- Run, require success, use stdout.
func current_commit(repository: Path) -> Result[String, CommitError]:
    git ?= find_program("git").map_err(pure func(error: FindProgramError): GitMissing(error))
    output({ command(git, ["rev-parse", "HEAD"]) | directory = Some(repository) })
        .map_err(pure func(error: OutputError): GitFailed(error))

-- A sequence that stops at the first failure, sharing one base command.
func rebuild(make: Path, project: Path) -> Result[Void, OutputError]:
    base = { command(make, []) | directory = Some(project) }
    _ ?= output({ base | arguments = ["clean"] })
    _ ?= output({ base | arguments = ["all"] })
    Ok(void)

-- Input text and a timeout.
func sorted(sort: Path, text: String) -> Result[String, OutputError]:
    output({ command(sort, []) | stdin = Some(text), timeout_ms = Some(5000) })

-- Every outcome is a value.
func report(result: Result[Captured, CaptureError]) -> Void:
    match result:
        Err(error): print_error("${error}")
        Ok(captured):
            match captured.exit:
                Exited(0): print(captured.stdout)
                Exited(status): print_error("exited ${status.to_string()}: ${captured.stderr}")
                Signaled(signal): print_error("killed by signal ${signal.to_string()}")
                TimedOut: print_error("timed out")
```

`Exited(0)` uses the Int literal patterns that landed in `c3b304e60`.

The e2e harness needs no `/usr/bin/env` and no capture files. Each child is
a command like this one (the harness's own `isolated` first turns the text
path its suites build into a `Path`):

```blorp
pure func isolated(binary: Path, arguments: List[String], timeout_ms: Int) -> Command:
    { command(binary, arguments) |
        environment = { "BLORP_LEAK_CHECK" => None, "BLORP_MEMORY_STATS" => None },
        timeout_ms = Some(timeout_ms) }
```

## Behaviour

- No shell and no implicit PATH search; arguments are literal.
- A child never outlives the call. When it exits, or the deadline passes, its
  process group is killed and only what is already buffered is read (at most
  16 MiB per stream, which only a process that left the group can reach), so a
  grandchild that keeps a pipe open cannot hang the call. Python, Rust, and Go
  before 1.20's `WaitDelay` hang there.
- Writing `stdin` while capturing both streams runs one poll loop over the
  three pipes and the deadline. A child that exits without reading its input
  is not an error. SIGPIPE is blocked in the calling thread only, consumed if
  our write raised it, and the mask restored. No signal disposition changes.
- Output is validated as UTF-8 once, after the child is reaped. After
  `Signaled` or `TimedOut`, up to three trailing bytes of a cut-off character
  are dropped first, so a timeout is not reported as bad text.
- The parent's SIGCHLD disposition must be the default, and it is never
  changed. If foreign code has changed it, `capture` is
  `LaunchFailed(OtherOs(ECHILD))`, decided before anything starts, since the
  system would reap the child itself and the wait would report ECHILD.
- A timeout of 0 or less is `Ok` with `TimedOut` and empty output as soon as
  the command is validated, without starting the program.
- The program and a `directory` are `Path`s, which cannot hold NUL, so
  `ContainsNul` is about the arguments and the environment, and
  `DirectoryFailed` has no NUL case. The native still checks every input.
- `find_program` skips empty and relative PATH entries (Go's `ErrDot`) and
  entries that are not UTF-8, and accepts a regular file the process may
  execute (`faccessat(X_OK, AT_EACCESS)`). A name that is empty or contains
  `/` is `NotOnPath` without a search; one with NUL is `NameContainsNul`.
- A reply the library cannot decode (an exit that is not decimal text of a
  known Exit code, an error tag the C side does not build, a list of another
  length) is a runtime defect, never an outcome (P5): the C side checks every
  code before replying, and the library's unreachable branches call the
  `process.fault` native, which prints "blorp: process runtime defect:" and
  the message, then aborts.
- Inherited descriptors rely on `O_CLOEXEC`, which the runtime already uses
  everywhere, as Go and Rust do.
- `fork` stays. `posix_spawn` reports a missing directory and a missing
  program both as ENOENT, and its chdir action is deprecated or missing across
  our targets.

## Decisions

- **P1, output that is not UTF-8.** The errors `StdoutNotUtf8(Exit)` and
  `StderrNotUtf8(Exit)` keep how the child ended, as `read_text` reports
  `InvalidUtf8`. Silent replacement with U+FFFD was rejected. Binary capture
  comes with `Bytes` (`UINT8_BYTES_PLAN.md`).
- **P2, record update.** A command is changed by record update only, the one
  Blorp way to build a changed value; a shared base command removes
  repetition. Five chained helpers (`.in_directory(d)` and the like) were
  rejected: they add five names and a second way to set each field.
- **P3, no `run` yet.** `?=` over `output` covers sequences. A build tool that
  must show progress live is the consumer that brings `run` back, with
  streaming. `run_to_files` goes: it is `capture` plus two `fs.write_text`
  calls.
- **P4, one code table.** Natives can return only Ints, Strings and Lists of
  them, so Blorp mirrors the C runtime's error enum in Int constants
  (`NOT_FOUND_CODE` and the rest) and decodes them in `decode_error`.
  `LaunchFailed(IOErrorKind)` and `DirectoryFailed(IOError)` need the same
  decoder as `fs`, so there is one: `standard_library/_io_errors.brp`, which
  `fs` uses and `process` will use.

  On 2026-11-08 Keith chose to move the public `IOErrorKind`, `IOError` and
  `describe` to the existing `io` module, and all imports were updated (landed
  in `23f25d7d3`).
  - `fs` and `_io_errors` import those types from `io`, and `io` imports
    neither, so there is no cycle.
  - Modules do not reexport imported names, so callers import errors and
    `describe` from `io`, and filesystem operations and entry types from `fs`.
  - This replaced a decision from earlier the same day (`163da8a37`): keep the
    table in `fs` and make `decode_error` public. That was chosen because
    Blorp has no re-exports, so a shared decoder module seemed to require
    moving `IOErrorKind` out of `fs`. Moving the public identities to `io`
    resolved that.

  Letting a native return a library `fixed union` instead was estimated at 250
  to 300 compiler lines, plus a seed rotation with a dual-accept transition.
  It would move the table into the compiler rather than remove it, and every
  new error kind would then need a compiler change and a rotation. Revisit it
  as one general design if several libraries come to need it.
- **P5, the native reply boundary** (Keith, 2026-11-09). `capture`'s native
  replies `Ok([exit, stdout, stderr])`, the exit as the decimal text of its
  Int code that `snprintf` writes, or `Err(code)` with the error's tag and
  detail; `find_program`'s replies the path or such a code. Keith first chose
  to carry the exit as an Int that needs no parsing (A) with an abort for
  impossible replies (C). A proved unbuildable: a native returns one value,
  an Int, a String, a `List[String]` or Void, so an Int cannot travel beside
  two Strings without a handle table of finished captures or a new tuple
  payload in the compiler. He then chose C alone: keep the decimal text, and
  treat every reply the C side cannot produce as an internal defect. The
  natives and the library ship together, so these states are unreachable;
  aborting is honest, while decoding them into a `CaptureError` such as
  `LaunchFailed(OtherOs(0))` would invent a failure the operating system never
  reported. The C side checks each code as it builds it, and the library calls
  the `process.fault` native from its impossible branches.

Removed during review:
- the `Environment` and `Input` unions, because a Dict and an Option say the
  same with no new names;
- variants that repeated `fs`'s `NotFound`, `PermissionDenied` and `OtherOs`:
  importing them beside `fs`'s fails with "NotFound is already imported";
- `Unsuccessful(Exit, String)`, which could hold `Exited(0)` and dropped
  stdout;
- a separate `Stream` type, replaced by two variants.

## Landings

The process API itself needs no seed rotation, since the compiler does not
import `process` yet. `blorp run` and `blorp test` (`RUN_AND_TEST_PLAN.md`)
will make it import `process`, and that needs a rotation first.

1. **L0, the shared code table** (P4). Move fs's codes and `decode_error` into
   `_io_errors`, with shared public error types/formatting owned by `io` and
   all caller imports migrated. Error values and wording do not change.
   The compiler imports `fs`,
   so this landing measures self-compile cost.
2. **L1, the natives and the library.**
   - The natives `process.capture` and `process.find_program`, at about 10
     compiler lines.
   - The C core in `blorp/src/common/codegen/runtime/process.brp`, at about 300
     lines.
   - `process.brp`, growing from 13 lines to about 230, and its suites.
   - The old `run_to_files` stays for now.
3. **L2, the migration** (landed 2026-11-11; costs and call sites in
   `benchmarks/results/blorp_process_l2_2026-11-11.md`).
   - `Command.program` becomes a `Path` (Keith, 2026-11-11), which
     `PATH_PLAN.md`'s P8 left to this landing.
   - Move the call sites over, removing the `env` and `sh -c` wrappers and
     the read-backs.
   - Delete `run_to_files`, with its native, C and label.
   - Update both READMEs.
   - Coordinate the harness changes with whoever owns `blorp/test/e2e/`.

Each landing gets its own brief, and sets numerical ceilings before
implementation.
