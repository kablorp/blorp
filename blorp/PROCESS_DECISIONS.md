# Process API

`describe` below is history: the error unions implement `Stringable` instead
(the `Stringable` landing). The module is now `io/process`. The `Path`
landing replaced `ProcessError` and
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

A terminal-sharing `run` for `blorp run` and `blorp test` is decided in the
amendment at the end of this file, which Keith approved on 2026-11-11.

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
    result: Result methods                       -- map_err, in the examples

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
    git: Path ?= find_program("git").map_err(pure func(error: FindProgramError): GitMissing(error))
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
3. **L2, the migration** (landed 2026-11-11; self-compile
   allocations −0.030% and retired instructions −0.073%, identical C for the
   fixed input).
   - `Command.program` becomes a `Path` (Keith, 2026-11-11), a change
     the `Path` landing left to this one.
   - Move the call sites over, removing the `env` and `sh -c` wrappers and
     the read-backs.
   - Delete `run_to_files`, with its native, C and label.
   - Update both READMEs.
   - Coordinate the harness changes with whoever owns `blorp/test/e2e/`.

Each landing gets its own brief, and sets numerical ceilings before
implementation.

## Amendment: `run`, a program on this terminal

Status: approved by Keith on 2026-11-11, with P6 to P11 decided as
recommended, after an independent ergonomics and data-model review (an Opus
code-reviewer: no blockers; its findings are folded in). Not implemented.
`RUN_AND_TEST_PLAN.md`'s R0(a) asks for it: `blorp run` and `blorp test`
need a child that shares the user's terminal. P3 deferred `run` until a
consumer needed it; `blorp run` is that consumer. It needs no streaming,
since the child writes to the terminal itself, so streaming stays a later
consumer's need, under another name.

### Problem

`capture` is built for tools. The child leads its own process group, so that
the deadline and the final cleanup can kill everything it started; its output
is returned after it ends; its stdin is text or `/dev/null`. Built on
`capture`, `blorp run hello.brp` would show nothing until the program ends,
give it no input, and send Ctrl-C to `blorp` instead: the child's group is
not the terminal's foreground group. The program must instead share the
terminal: its output appears as it is written, it reads the real stdin,
Ctrl-C reaches it, and nothing times out.

### The API

```blorp
import:
    io/terminal:
        INTERRUPT_SIGNAL, TerminalCommand, RunExit(Exited, Signaled), RunError(...),
        terminal_command, run, exit_interrupted
    io/process: SystemCallError(...), FindProgramError, find_program
    path: Path
    result: Result methods                       -- map_err, in the examples

-- What to run on this terminal. Build one with `terminal_command`, then change
-- fields by record update. There is no stdin text and no timeout.
record TerminalCommand {
    program: Path,                               -- find_program searches PATH
    arguments: List[String],                     -- without argv[0]; each passed literally
    directory: Option[Path],                     -- None runs in the parent's directory
    environment: Dict[String, Option[String]],   -- Some sets, None removes, the rest is inherited
}

-- SIGINT, the signal Ctrl-C sends: 2 under XSI, which every supported platform follows.
INTERRUPT_SIGNAL: Int = 2

-- How the child ended. Each is an outcome, not an error.
fixed union RunExit:
    Exited(Int)        -- its status, 0 to 255
    Signaled(Int)      -- the signal number: Ctrl-C is Signaled(INTERRUPT_SIGNAL)

-- Why the program did not start.
union RunError:
    InvalidVariableName(String)       -- empty, or contains "="; before any system call
    ContainsNul                       -- in an argument or the environment; before any system call
    LaunchFailed(SystemCallError)     -- exec, fork or the exec report's pipe failed
    NotExecutable                     -- ENOEXEC: a script without #!, for example
    DirectoryFailed(SystemCallError)  -- the child could not enter `directory`

pure func terminal_command(program: Path, arguments: List[String]) -> TerminalCommand
-- { program, arguments, directory = None, environment = {} }

func run(invocation: TerminalCommand) -> Result[RunExit, RunError]   -- every RunExit is Ok
func exit_interrupted() -> Void                  -- P11: ends this process by SIGINT
```

`RunError` is `CaptureError` without the two UTF-8 variants, which need
captured output, and `run` can produce each of its variants: the environment
and arguments are checked as `capture` checks them, and the fork, the
directory and the exec are the same steps. Each variant's `Stringable` text is
`CaptureError`'s. Nothing about the terminal can fail: the child keeps the
caller's descriptors and group (P8), so no terminal call is made.

### Examples

```blorp
-- How blorp run ends once the program has ended and its temporary directory
-- is gone (RUN_AND_TEST_PLAN.md's R5, as P11 amends it).
func exit_status(ended: RunExit) -> Int:
    match ended:
        Exited(status):
            status
        Signaled(signal):
            if signal == INTERRUPT_SIGNAL:
                exit_interrupted()
            128 + signal

-- blorp test: the suite gets the terminal and the strict leak check.
func run_suite(suite: Path) -> Result[RunExit, RunError]:
    run({ terminal_command(suite, []) | environment = { "BLORP_LEAK_CHECK" => Some("strict") } })

-- Let the user edit a file, as git commit does: the editor needs the terminal.
-- A `?=` checks its right side against its binder's annotation and nothing
-- else, so `vi: Path` is what gives map_err's lambda the union of its bare
-- constructor; the tail map_err gets it from the return type.
union EditError:
    EditorMissing(FindProgramError)
    EditorFailed(RunError)

func edit(file: Path) -> Result[RunExit, EditError]:
    vi: Path ?= find_program("vi").map_err(pure func(error: FindProgramError): EditorMissing(error))
    run(terminal_command(vi, ["${file}"])).map_err(pure func(error: RunError): EditorFailed(error))
```

These examples compile against the library prototype (Spike), and their C
builds with `-Wall -Wextra -Werror -pedantic`.

A file that uses both forms qualifies one set of variants, as a file that
reads and writes files does: `Exit.Exited(status)` beside
`RunExit.Exited(status)`. Importing `Exited` bare from both modules is
"Exited is already imported", whose help names that form.

### Behaviour

- **Shared with `capture`:** no shell, no PATH search, literal arguments; the
  same environment rules and checks before any system call; a relative
  program is found from `directory`; SIGCHLD must keep its default
  disposition, or the call is `LaunchFailed(OtherOs(ECHILD))` before anything
  starts; a reply the library cannot decode faults (P5). The native replies
  `Ok(exit)` with the exit as its Int code, which needs no text since nothing
  travels beside it, or `Err(code)`.
- **The terminal** (P8). The child inherits stdin, stdout and stderr and stays
  in the caller's process group, as `system(3)` runs a command. It is in the
  terminal's foreground group exactly when the caller is, so its reads work
  and Ctrl-C, Ctrl-\ and Ctrl-Z reach both. With no terminal (pipes, files,
  CI) nothing changes: the child reads and writes what the caller would, and a
  signal to the caller's group, such as CI cancelling a job or `timeout(1)`,
  reaches the child too.
- **The caller's signals** (P9). SIGINT and SIGQUIT are ignored from just
  before the fork until the child is reaped, then restored. This is the one
  disposition the process API changes, and only for the call. The child
  starts with each at its default, unless the caller had it ignored (a
  script's background job, `nohup`), which the child then inherits, as from a
  shell. A signal sent to the caller alone, such as SIGTERM, is not
  intercepted: the caller ends and the child runs on, as under `system(3)`.
  The save and restore are exact because a Blorp program has one thread;
  the landing that brings threads makes them a counted section under a
  lock, as glibc's `system` does.
- **Job control.** SIGTSTP, SIGTTIN and SIGTTOU are left alone. Ctrl-Z stops
  the caller with the child, so the shell, which waits only on the caller,
  reports the job stopped, and `fg` continues both. A child of a background
  caller that reads the terminal gets SIGTTIN, which stops the whole group
  until `fg`. The caller waits without `WUNTRACED`, so a child stopped by a
  signal sent to it alone (`kill -STOP`) is waited for until it continues or
  ends.
- **Buffered output** (P10). Before the fork, the caller flushes its stdout
  and stderr buffers, so what it printed comes before what the child prints,
  on a pipe or a file as on a terminal. A failed flush is ignored, as `print`
  ignores a failed write. Input that the caller read ahead and did not
  consume is not the child's; Blorp cannot read stdin today, and the byte
  console (`LSP_PLAN.md`) must say so when its reads buffer.
- **Ctrl-C.** The child ends by SIGINT, the caller survives it, and `run`
  returns `Ok(Signaled(INTERRUPT_SIGNAL))` after restoring the dispositions;
  Ctrl-\ is `Signaled(3)`. Ctrl-C ends only the current child, so a caller
  that runs programs in turn must stop at `Signaled(INTERRUPT_SIGNAL)`, as a
  shell does, and once it has cleaned up end with `exit_interrupted` (P11,
  in `io/terminal`); otherwise its loop goes on, which is what P11 fixes for
  `blorp run`. `run`'s documentation says so.
- **No group kill.** `run` returns when the child ends, and nothing is killed
  afterwards: a process the child started and left running goes on, as it
  does after `system(3)`. `capture` keeps its guarantee.

### The C core

What `blorp_process_run` shares with `capture`, and what is new:

- **Already shared** (`PROCESS_HELPERS_RUNTIME`): the exit and error
  encoders, the defect abort, `blorp_process_close` and
  `blorp_process_private`.
- **Moved out of `capture`, unchanged**, into the shared helpers: the NUL
  check of the inputs, the SIGCHLD check, building argv and the environment,
  the exec report's pipe and its reading, the stage-to-error mapping, and the
  child's tail (enter the directory, exec, report a failure, exit 127).
  `capture`'s child keeps `setpgid` and the `dup2`s, then calls the tail, so
  its `chdir` moves after the `dup2`s; the stages and errors are the same.
- **New:** the flush, the two `sigaction` pairs, the child's reset of SIGINT
  and SIGQUIT, a blocking `waitpid`, and one read of the report after the
  child is reaped, when its write end is closed, so a descriptor another fork
  inherited cannot hold the call.
- **Not used:** the poll loop, the output buffers, the stdin writer, the
  SIGPIPE guard, the group kill and the UTF-8 handling.

### Decisions

- **P6, the input: a record of its own.** `TerminalCommand` holds the four
  `Command` fields that mean the same to both forms. `directory` stays,
  though no consumer needs it yet: the child's tail enters it at no cost, and
  without it the two records would differ by more than what `run` cannot
  take. The alternatives lose:
  - `Command` with a rule: its `stdin = None` means `/dev/null`, which for
    `run` would have to mean the terminal, so one field would mean two
    things; and a timeout would need an error variant for an input the types
    could have refused.
  - `Command` minus fields (`stdin` and `timeout_ms` moved to `capture`'s own
    record): the most normalized, but it changes every `capture` call that
    sets either (the e2e harness, its selection and CLI suites, the fs and
    process suites) and lengthens the common one, while only declarations,
    not stored values, are shared.
  - `run(program, arguments)`: no environment for `blorp test`, and no record
    update.
- **P7, its own module, `io/terminal`.** A module's unions cannot share
  variant names, so inside the one module `io/process` the result could not
  be `Exited` and `Signaled`, nor the errors `ContainsNul` and
  `LaunchFailed`. The `Path` landing answered the same clash with a module
  per operation (`io/fs/read`, `io/fs/write`; the library README's "The file
  modules"), and `io/process/run` cannot sit beside the file
  `io/process.brp`, so the module is named for what the child shares.
  `io/process` and its nine importers do not change, and `io/process`'s
  header comment and the library README point a reader who looks for `run`
  there to `io/terminal`. The alternative was splitting `io/process` into a
  folder (`capture`, `run`, and homes for `find_program` and
  `SystemCallError`): it puts `run` where Python, Go and Rust users look and
  follows `io/fs/`, at the cost of moving nine importers and giving
  `SystemCallError` a public module of its own.

  What `capture` keeps private and `run` also needs (the code constants and
  their arithmetic, the environment check and encoding, the directory
  encoding and the fault path) moves to an internal module, `io/_launch`, as
  `io/_codes` holds fs's codes, so the protocol has one mirror and the fault
  workaround one copy. Blorp has no module-internal visibility (`NEXT.md`
  lists a test-visible `private` as open), so its names are public: a program could import `fault`, and only
  the leading underscore says not to. That adds a name but no capability,
  since any module may already bind `builtin("process.fault")` itself (a
  user program that does compiles; Spike). The alternative, a private copy
  of the 12-line fault pair in each module, is the workaround `NEXT.md` says
  not to copy, so the export stays. Also rejected:
  - reusing `Exit`, whose `TimedOut` every `run` caller would match though it
    cannot happen;
  - a `RunExit` in `io/process` with other names (`Finished`, `Killed`,
    `RunContainsNul`): two names for one concept;
  - restructuring `io/process`, with `Exit` losing `TimedOut` and a shared
    launch error nested in `CaptureError`: it reopens the approved `capture`
    API and deepens its matches to
    `CaptureFailed(NotLaunched(LaunchFailed(NotFound)))`;
- **P8, the child stays in the caller's process group** (`system(3)`), rather
  than leading its own group and being handed the terminal with `tcsetpgrp`.
  The hand-off sends Ctrl-C to the child alone without touching a
  disposition, but the spike shows what it costs:
  - Ctrl-Z stops only the child while the shell waits on the caller, so the
    caller must act as a job-control shell: take the terminal back, stop
    itself, and on `fg` hand it back and continue the child;
  - without a terminal, a signal to the caller's group (CI, `timeout`) kills
    the caller and misses the child, which runs on;
  - a background caller must not hand off, and its child then stops alone on
    its first read;
  - a shell script's loop over `blorp run` never sees Ctrl-C, so it cannot
    stop, whatever `blorp run` does afterwards.
  Also rejected: replacing the caller with the program, as `cargo run` does
  on Unix, since `blorp run` must remove its temporary directory afterwards;
  and `posix_spawn`, for `capture`'s reasons and the shared exec report.
- **P9, the caller ignores SIGINT and SIGQUIT while it waits**, and restores
  them. Rejected:
  - leaving them at their defaults, as Go's `Cmd.Run`, Rust's `status` and
    Python's `subprocess.run` do: Ctrl-C would also end `blorp run`, which
    would leave its temporary directory and report nothing;
  - blocking them in the calling thread: a process-directed signal is
    delivered to any thread that does not block it, and the pending SIGINT
    must then be consumed (macOS has no `sigtimedwait`);
  - a handler: code run asynchronously, for nothing ignoring does not give.
- **P10, flush stdout and stderr before the fork.** Rejected: no flush, which
  is Python's well-known surprise and reorders the spike's output on a pipe;
  and `fflush(NULL)`, which also flushes streams that foreign code owns.
- **P11, how `blorp run` ends after Ctrl-C** (amends `RUN_AND_TEST_PLAN.md`'s
  R5, decided here because a native it needs must ride the same seed
  rotation). With R5's 128 + 2, a shell loop over `blorp run` goes on after
  Ctrl-C: in the spike, loops typed at a bash or zsh prompt and a loop in a
  `bash -c` script all ran their next iteration. A shell stops a loop only
  when its child died by SIGINT (its "wait and cooperative exit"), which is
  why Python since 3.8 ends by SIGINT after an uncaught `KeyboardInterrupt`
  instead of exiting 130. Decided: when the program ended by SIGINT,
  `blorp run` and `blorp test` remove their temporary directory and then end
  by SIGINT themselves; with that, every loop in the spike stopped. Every
  other signal stays 128 + s, since ending `blorp` by SIGSEGV or SIGABRT
  would blame it and could dump its core. It costs one more native, about 25
  compiler lines, 12 of C and 16 of library:

  ```blorp
  -- Ends this process by SIGINT, as Ctrl-C would have, so that a shell running
  -- it in a loop stops too: flushes stdout and stderr, resets SIGINT to its
  -- default and raises it, as the spike's caller and CPython do. For a caller
  -- whose child run reported Signaled(INTERRUPT_SIGNAL). It returns only if
  -- SIGINT cannot end the process, as when a parent left SIGINT blocked across
  -- exec; the caller then returns 130.
  func exit_interrupted() -> Void
  ```

  A diagnostics build skips its leak check on this path. R5's `Signaled(s)`
  row in `RUN_AND_TEST_PLAN.md` changes in the same commit. The alternative
  was R5 as written: one Ctrl-C per remaining iteration.

Also rejected, one line each:
- a timeout on `run`: without the group kill it would end only the direct
  child, and R0(a) wants none;
- killing the child's group when `run` returns: the child shares the caller's
  group, so that would kill the caller;
- ignoring SIGTSTP in the caller: the shell would wait on a running caller
  while the child sat stopped, and the terminal would hang;
- waiting with `WUNTRACED` and stopping the caller when the child stops: it
  matters only for a stop sent to the child alone, since the terminal's
  job-control signals already reach both.

### Spike

On macOS 26.7 (arm64, Apple clang 21), 2026-11-11. The spike lives in the
design session's scratch directory and is never landed. `run_core.c` holds
both candidate cores in the runtime's shape; `run_spike [--no-flush]
[--reraise] group|handoff PROGRAM ...` runs a program with either; `child`
has a mode per case; `pty_probe` drives a pseudo-terminal from C; and
`shells.exp` and `debug_ctrlz.exp` drive interactive bash 3.2 and zsh 5.9
through expect. All are built with `-std=c11 -Wall -Wextra -Werror
-pedantic`, and `no_terminal.sh`, `terminal.sh`, `shells_only.sh` and
`ctrlz.sh` wrote the results below.

| Case | Group (P8) | Hand-off |
| --- | --- | --- |
| live output, then a line typed on the pty (`pty_probe`) | pass | pass |
| the child is in the terminal's foreground group | pass | pass |
| Ctrl-C on the pty: `Signaled(2)`, the caller survives, SIGINT restored | pass | pass |
| Ctrl-\ on the pty: `Signaled(3)` | pass | pass |
| stdin from a pipe, then from `/dev/null` (no terminal) | reads it; end of input | the same |
| the child sends SIGINT to its own group (Ctrl-C without a terminal) | `Signaled(2)`, the caller survives | the same |
| SIGINT to the caller's group, as CI cancels (`kill -INT -pgid`) | child ended, the caller reports `Signaled(2)` | **the caller dies; the child runs on** |
| the caller has SIGINT ignored (a script's `&` job) | the child inherits it ignored | the same |
| stdout a pipe: the caller's `printf` line, then the child's | in order | in order |
| the same with `--no-flush` | **the caller's line comes last** | the same |
| `--no-flush` and the exec fails | the caller's line once, not twice | the same |
| Ctrl-Z, then `fg` and a typed line (bash 3.2 and zsh 5.9 at a prompt) | the job stops and resumes; the line is read | the same, through 16 more lines that act as a job-control shell |
| a background job reads the terminal, then `fg` | stops for tty input; the line is read after `fg` | the same |
| Ctrl-C in a loop at a bash or zsh prompt; the caller exits 130 | **the loop goes on** | the same |
| the same; the caller ends by SIGINT (`--reraise`) | the loop stops | the same |
| Ctrl-C in a `bash -c` loop; exit 130, or by SIGINT | goes on; stops | **goes on either way: the script's shell never sees Ctrl-C** |
| Ctrl-C in a `zsh -c` loop | stops either way: zsh itself ends by SIGINT | **goes on either way** |

A terminal read that a stop and `fg` interrupt fails with EINTR on macOS,
under either core and also when the child runs straight from the shell, so
the spike's child retries; it is the platform's behaviour, which `run` does
not change.

**The library prototype** is a scratch copy of `standard_library` with
`io/_launch` and `io/terminal` as proposed (the natives stubbed, since their
labels do not exist) and `io/process` rewired onto `io/_launch`. The
worktree's compiler, built from the pinned seed, accepts all three modules
unchanged by `blorp format`, and compiles the examples above and a file that
uses both `Exit` and `RunExit` through qualified variants; their C builds
with `-Werror`. Importing `Exited` bare from both modules is rejected as
P7 says. The same compiler showed that the approved `current_commit` example
did not compile: without `result: Result methods`, `map_err` is unknown, and
with it, an unannotated `?=` leaves `GitMissing` without an expected union.
This change annotates `git: Path` and adds the import, here and in the
library README, and that form compiles. A user module that binds
`builtin("process.fault")` compiles too.

Both cores cost the same: 500 runs of `/usr/bin/true` took 1.9 to 2.8 ms
each with either, without and with a terminal, which is fork and exec.
The group core is 58 lines and the hand-off core 74, beside 110 lines of
helpers both share, most of which `capture` already has.

### Landings

Numbered after L2. The process API needs no seed rotation until the compiler
imports `io/terminal`.

3. **L3, the native and the library,** one landing in two commits.
   - Commit 1 moves the shared pieces, with no change in behaviour: the C
     helpers out of `capture`'s body (The C core, above) and `io/_launch` out
     of `io/process`. The process suite passes unchanged.
   - Commit 2 adds the `process.run` label, `blorp_process_run`,
     `io/terminal`, the tests and both READMEs' text. A reader who looks for
     `run` in `io/process`, as a Python or Go user will, is sent to
     `io/terminal` by `io/process`'s header comment and by the library
     README's "Process execution", which gains a part for `run`.

   Ceilings, set from the spike and a library prototype that type-checks
   (Spike, above):

   | What | Ceiling | Basis |
   | --- | --- | --- |
   | native tables (`syntax`, `builtins`, `system`) and `grammar.ebnf` | +35 lines, +25 more for P11's native | L1 added about 30 lines per native |
   | `runtime/process.brp` | commit 1 +40 net; commit 2 +120, +12 more for P11 | spike: shared helpers 110 lines, mostly moved; the group core 58 |
   | `io/_launch.brp` | 120 lines | prototype 114 |
   | `io/process.brp` | −55 net | prototype 428 to 365 |
   | `io/terminal.brp` | 180 lines, +20 for P11 | prototype 167, and 184 with P11 |
   | self-compile allocations, retired instructions | +0.15% each | the compiler embeds the library's text, about 235 lines more, and gains one label, two with P11; L1 measured +0.21% for 373 library lines and three labels |
   | fixed-input C | identical | a program that does not call `run` emits the same C |

   Test lines are reported separately; about 350 are expected, most of them
   C probes.
4. **L4, the seed rotation.** `blorp run` makes the compiler import
   `io/terminal`, whose `process.run` label the pinned seed
   (`0bb93894dcf2`, built from UInt8 L1) does not know; it knows `capture`'s
   three. UInt8's L2 rotation pinned a commit without L3, so L4 is a plain
   rotation of its own that carries `process.run` and P11's label, unless a
   later rotation that includes L3 lands first.
5. Then `RUN_AND_TEST_PLAN.md`'s CLI landing. One question for it, which
   this amendment does not decide: `blorp run` compiles the C with `capture`,
   whose child leads its own group, so Ctrl-C during that compile ends
   `blorp` (SIGINT at its default) and not `cc`, which runs on, and the
   temporary directory stays. Running `cc` with `run` instead would let
   Ctrl-C reach it and `blorp` clean up, at the cost of showing its output
   live rather than as R5's fault in Blorp.

### Testing

L3 tests through the process suite and its C child (`process_child.c`, built
with the unmodified production fragments):

- **Through the library,** exact outcomes as text: `Exited(23)`,
  `Signaled(15)`, and each `RunError` variant (a missing program, a plain
  file, a script without `#!`, a missing directory, a NUL, a bad variable
  name), with every `Stringable` text. The five phrases `RunError` shares
  with `CaptureError` are written in both modules, as each `io/fs/` union
  writes its own; the suite asserts both, so they cannot drift apart
  unnoticed.
- **Native probes:**
  - SIGINT and SIGQUIT are restored after `Exited` and after `Signaled`; the
    child sees them at their defaults, and ignored when the caller ignores
    them;
  - an interrupt without a terminal: the child sends SIGINT to its own group,
    the caller survives, and the reply is `Signaled(INTERRUPT_SIGNAL)`;
  - a real terminal, as the spike's `pty_probe.c` does: a session on a pty
    (`posix_openpt`, `setsid`, `TIOCSCTTY`) types a line the child reads,
    then Ctrl-C and Ctrl-\;
  - the caller's buffered stdout on a pipe comes before the child's line;
  - SIGCHLD ignored is `LaunchFailed(OtherOs(ECHILD))`, and an impossible
    reply faults;
  - with P11, a child that calls `exit_interrupted` is
    `Signaled(INTERRUPT_SIGNAL)`, and its buffered stdout arrives first.
- **e2e:** a fixture that runs a child with `run` and is itself captured, so
  the order of the two programs' lines is checked.
- **Linux, on CI:** the pty probe, the group interrupt and the disposition
  probes, which this Mac could not run there. Linux acquires a controlling
  terminal on `open` and Darwin only through `TIOCSCTTY`; the probe does
  both, and the Linux run must show that the second is harmless there. Job
  control with a real shell (Ctrl-Z, `fg`, a background read) needs an
  interactive shell, which CI does not have: the spike checked it here, and
  L3 records it as a manual check on Linux.
