# Process API

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

Nothing is implemented yet. The feasibility review prototyped the C core on
macOS 26 and Linux arm64, and compiled every declaration and example below
against a scratch library. Those spikes were not kept.

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
    process:
        Command, Exit(Exited, Signaled, TimedOut), Captured, ProcessError, ProcessErrorKind(...),
        command, capture, output, find_program

-- What to run. Build one with `command`, then change fields by record update.
record Command {
    program: String,                             -- a path; find_program searches PATH
    arguments: List[String],                     -- without argv[0]; each passed literally
    directory: Option[String],                   -- None runs in the parent's directory
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

-- `program` is exactly what the caller passed: the name for find_program,
-- the path for everything else.
record ProcessError { program: String, kind: ProcessErrorKind }

union ProcessErrorKind:
    NotOnPath                      -- find_program: no executable file of that name
    LaunchFailed(IOErrorKind)      -- exec, fork or a pipe failed, as fs words the errno
    NotExecutable                  -- ENOEXEC: a file the system cannot run, such as a script without #!
    DirectoryFailed(IOError)       -- the child could not enter `directory`; the error names it
    ContainsNul                    -- in the program, an argument or the environment; before any system call
    InvalidVariableName(String)    -- empty, or contains "="; before any system call
    StdoutNotUtf8(Exit)            -- P1: carries how the child ended
    StderrNotUtf8(Exit)
    Unsuccessful(Captured)         -- output only: anything but Exited(0)

pure func command(program: String, arguments: List[String]) -> Command
-- { program, arguments, directory = None, environment = {}, stdin = None, timeout_ms = None }

func capture(invocation: Command) -> Result[Captured, ProcessError]     -- every Exit is Ok
func output(invocation: Command) -> Result[String, ProcessError]        -- stdout, or Unsuccessful
func find_program(name: String) -> Result[String, ProcessError]         -- absolute PATH entries only
pure func succeeded(exit: Exit) -> Bool                                 -- Exited(0)
pure func describe(error: ProcessError) -> String                       -- "<program>: <phrase>"
```

`output` is `capture` that insists on success, like Python's `check=True` and
Go's `Output`. `?=` over `output` runs a sequence and stops at the first
failure, carrying everything the failed command printed. It shows nothing
until the command ends; live output comes with streaming. `describe` renders
`Unsuccessful` as "make: exited 2" followed by its stderr, and every other
kind with fixed text, as `fs.describe` does.

`succeeded` and `describe` need no import. Selecting `Exit` and
`ProcessError` makes them available as `exit.succeeded()` and
`error.describe()`, which also keeps `process`'s `describe` from colliding
with `fs`'s. A program that passes `describe` as a value aliases the module,
as `process as Process`, and writes `.map_err(Process.describe)`.

## Examples

```blorp
-- Run, require success, use stdout.
func current_commit(repository: String) -> Result[String, ProcessError]:
    git ?= find_program("git")
    output({ command(git, ["rev-parse", "HEAD"]) | directory = Some(repository) })

-- A sequence that stops at the first failure, sharing one base command.
func rebuild(make: String, project: String) -> Result[Void, ProcessError]:
    base = { command(make, []) | directory = Some(project) }
    _ ?= output({ base | arguments = ["clean"] })
    _ ?= output({ base | arguments = ["all"] })
    Ok(void)

-- Input text and a timeout.
func sorted(sort: String, text: String) -> Result[String, ProcessError]:
    output({ command(sort, []) | stdin = Some(text), timeout_ms = Some(5000) })

-- Every outcome is a value.
func report(result: Result[Captured, ProcessError]) -> Void:
    match result:
        Err(error): print_error(error.describe())
        Ok(captured):
            match captured.exit:
                Exited(0): print(captured.stdout)
                Exited(status): print_error("exited ${status.to_string()}: ${captured.stderr}")
                Signaled(signal): print_error("killed by signal ${signal.to_string()}")
                TimedOut: print_error("timed out")
```

`Exited(0)` uses the Int literal patterns that landed in `c3b304e60`.

The e2e harness after migration needs no `/usr/bin/env` and no capture files:

```blorp
private func isolated(binary: String, arguments: List[String]) -> Result[Captured, ProcessError]:
    capture({ command(binary, arguments) |
        environment = { "BLORP_LEAK_CHECK" => None, "BLORP_MEMORY_STATS" => None },
        timeout_ms = Some(CHILD_TIMEOUT_MS) })
```

## Behaviour

- No shell and no implicit PATH search; arguments are literal.
- A child never outlives the call. When it exits, or the deadline passes, its
  process group is killed and only what is already buffered is read, so a
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
  changed.
- `find_program` skips empty and relative PATH entries (Go's `ErrDot`), and
  accepts a regular file the process may execute
  (`faccessat(X_OK, AT_EACCESS)`).
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
  them, so `fs.brp` mirrors the C runtime's error enum in private Int
  constants (`NOT_FOUND_CODE` and the rest) and decodes them in
  `decode_error`. `LaunchFailed(IOErrorKind)` and `DirectoryFailed(IOError)`
  need the same decoder. So fs's code constants and `decode_error` move into
  one shared internal module, which `process` also uses.

  Letting a native return a library `fixed union` instead was estimated at 250
  to 300 compiler lines, plus a seed rotation with a dual-accept transition.
  It would move the table into the compiler rather than remove it, and every
  new error kind would then need a compiler change and a rotation. Revisit it
  as one general design if several libraries come to need it.

Removed during review:
- the `Environment` and `Input` unions, because a Dict and an Option say the
  same with no new names;
- variants that repeated `fs`'s `NotFound`, `PermissionDenied` and `OtherOs`:
  importing them beside `fs`'s fails with "NotFound is already imported";
- `Unsuccessful(Exit, String)`, which could hold `Exited(0)` and dropped
  stdout;
- a separate `Stream` type, replaced by two variants.

## Landings

There is no seed rotation: the compiler never imports `process`.

1. **L0, the shared code table** (P4). Move fs's codes and `decode_error` into
   one internal module, with no behaviour change. The compiler imports `fs`,
   so this landing measures self-compile cost.
2. **L1, the natives and the library.**
   - The natives `process.capture` and `process.find_program`, at about 10
     compiler lines.
   - The C core in `blorp/src/compile/runtime/process.brp`, at about 300
     lines.
   - `process.brp`, growing from 13 lines to about 230, and its suites.
   - The old `run_to_files` stays for now.
3. **L2, the migration.**
   - Move the call sites over, removing the `env` and `sh -c` wrappers and
     the read-backs.
   - Delete `run_to_files`, with its native, C and label.
   - Update both READMEs.
   - Coordinate the harness changes with whoever owns `blorp/test/e2e/`.

Each landing gets its own brief, and sets numerical ceilings before
implementation.
