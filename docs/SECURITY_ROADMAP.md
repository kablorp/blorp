# Blorp Security Roadmap

Last updated: 2026-05-19

This is the early security roadmap for Blorp. The current priority is not a
complete sandbox or a broad supply-chain program. The priority is making the
runtime and compiler-owned native boundaries hard to misuse:

- runtime C memory safety;
- OS and C string boundary safety;
- cryptographic randomness correctness;
- FFI metadata and call-boundary safety;
- generated C escaping and name hygiene.

The main working assumption is that ordinary Blorp source should stay safe by
default, while native interop remains an explicit trust boundary.

## Current Focus

Focus now:

- Phase 2: runtime memory and OS boundary hardening.
- Phase 3: randomness and hash seeding.
- Phase 4: FFI boundary hardening.
- Phase 8: generated C hygiene.

Implemented in the first focused slice:

- `process.run` drains stdout and stderr together instead of reading one pipe
  to completion before the other.
- `process.run` has internal timeout and output-size bounds, kills the child
  process group on timeout or output exhaustion, and returns `Err` instead of
  blocking indefinitely.
- file read/write helpers reject embedded-NUL paths and check seek, read,
  write, and close results;
- filesystem query/mutation helpers, shell command helpers, and environment
  variable helpers reject embedded NULs at the OS C-string boundary;
- `crypto_random_bytes` and hash seeding require a fully initialized CSPRNG
  result;
- foreign C names, header includes, and link flags are validated before code
  emission;
- generated string literals carry explicit byte lengths, so embedded NULs are
  preserved in generated C.
- OS-boundary runtime builtins now have explicit ownership contracts, so
  borrowed managed temporaries are dropped by the compiler after the call.
- core String and Bytes constructors now use typed allocation helpers with
  checked header-plus-payload arithmetic, including negative-size regressions
  for `string()` and `bytes()`.
- runtime text, regex, file, environment, stream, and process-output paths now
  reuse those helpers instead of open-coded variable-length String/Bytes
  allocation.
- `Stream.from_lines` now uses the shared OS C-string guard instead of a fixed
  4096-byte path buffer, rejects embedded-NUL paths, and marks yielded file
  lines as owned managed values.
- `time.format_time`, `time.parse_time`, and regex builtins now reject
  embedded-NUL strings before crossing into C APIs that require NUL-terminated
  input.
- `make c-static-analysis` now analyzes both `runtime_decl.c` and `runtime.c`
  with the same `minicoro.h` context used by the embedded runtime. The focused
  pass keeps the broad blocking-in-critical-section checker disabled so this
  phase stays centered on C memory and OS-boundary issues.
- The first `runtime.c` analyzer pass fixed exact random-source fallback reads,
  reactor snapshot sizing, primitive filter_map callback storage contracts, and
  `for_each_chunk` read/close error handling.
- `for_each_line` now reports stream read and close failures instead of
  returning `Ok` after a failed `getline` loop.
- `make security-check` is a narrow opt-in gate for the current scope: C static
  analysis, compiler FFI/codegen tests, targeted runtime security tests, and
  targeted leak checks.

Defer for now:

- full restricted execution mode;
- broad capability policy for every std module;
- full package ecosystem security process;
- large fuzzing infrastructure;
- cache format replacement, unless it directly blocks a security gate.

## Principles

- Treat `runtime.c`, generated C, and FFI as the main early risk surface.
- Prefer compile-time rejection over runtime conventions.
- Keep unsafe native behavior explicit in source syntax and diagnostics.
- Do not rely on comments or docs when a parser/typechecker/codegen check can
  enforce the invariant.
- Add a regression test for each concrete issue before or with the fix.
- Run sanitizer and leak checks for memory-sensitive runtime and FFI changes.
- Keep ordinary Blorp APIs infallible where that is a language guarantee, but
  return `Result` at OS boundaries where the operating system can fail.

## Phase 2: Runtime Memory And OS Boundary Hardening

Goal: make runtime C safe around buffers, ownership, process I/O, files, and
conversion from Blorp values to C/OS representations.

### Work Items

- Rework `process.run` so stdout and stderr are drained concurrently.
- Add timeout-capable internal process execution.
- Consider public process timeout/output-limit APIs after the internal behavior
  is correct.
- Make `read_file` and `read_bytes` verify exact read counts.
- Make write APIs verify `fwrite` and `fclose`.
- Add shared helpers for converting `String` to OS C strings.
- Reject embedded NULs for paths, environment variable names/values, process
  program names, process arguments, shell commands, and C-string FFI arguments.
- Audit runtime functions that allocate from user-controlled lengths.
- Audit runtime functions that copy bytes based on file size, list length,
  tensor size, string length, or FFI input length.
- Prefer one helper per risky pattern:
  - checked allocation size;
  - exact read loop;
  - exact write loop;
  - OS C-string conversion;
  - process pipe drain.

### Acceptance

- `process.run` cannot deadlock if a child fills stderr while stdout stays open.
- File reads never return uninitialized heap bytes on short reads.
- File writes report failure when the write or close fails.
- Embedded NUL inputs are rejected consistently at OS boundaries.
- Runtime memory tests pass under ASan/UBSan.
- Leak checks cover success, error, timeout, and early-return paths.

### Tests To Add

- Runtime test: child writes more than one pipe buffer to stderr.
- Runtime test: child writes large stdout and large stderr.
- Runtime test: missing process returns `Err`, not a crash.
- Runtime test: process timeout kills the child or process group.
- Runtime test: `read_file` and `read_bytes` reject short reads where practical.
- Runtime test: `write_file` and `write_bytes` report write/close failures where
  practical.
- Runtime test: path with embedded NUL is rejected.
- Runtime test: process argument with embedded NUL is rejected.
- Runtime test: environment name/value with embedded NUL is rejected.
- Leak test: process failure and timeout paths release all intermediate strings,
  lists, pipes, and buffers.

### Edge Cases To Probe

- Child writes only stderr and never closes stdout.
- Child writes only stdout and never closes stderr.
- Child alternates stdout and stderr in small chunks.
- Child emits output forever.
- Child forks a subprocess and exits.
- Child ignores SIGTERM.
- Child exits while pipes still contain unread data.
- Path names with embedded NUL.
- Path names that refer to directories, FIFOs, devices, or non-seekable files.
- File shrinks between size check and read.
- File grows between size check and read.
- `fread` returns a short count with `ferror` set.
- `fwrite` writes fewer bytes than requested.
- `fclose` fails after buffered writes.
- Negative or huge lengths reaching allocation helpers.
- Integer overflow in `sizeof(header) + len + 1` patterns.

## Phase 3: Randomness And Hash Seeding

Goal: cryptographic randomness must either fully succeed or fail loudly. Hash
seeding should not silently fall back to predictable state.

### Work Items

- Loop on `getrandom` until the requested byte count is filled.
- Retry on `EINTR`.
- Verify `/dev/urandom` fallback reads the exact requested byte count.
- Fail hard if no CSPRNG fully fills the buffer.
- Ensure hash seed initialization cannot silently leave the seed as zero due to
  a short read or failed fallback.
- Keep `random` and `crypto_random` clearly separate in docs and tests.
- Consider a stronger keyed hash later if dict/set keys will commonly come from
  hostile users.

### Acceptance

- `crypto_random_bytes(n)` returns exactly `n` initialized bytes or terminates
  with a clear fatal runtime error.
- Hash seed initialization either obtains a full seed or fails clearly.
- Negative byte counts produce the documented safe behavior.
- Large byte counts do not overflow allocation sizes.

### Tests To Add

- Runtime test: zero bytes returns empty bytes.
- Runtime test: negative count behavior remains documented and safe.
- Runtime test: large count either succeeds or fails without overflow.
- C-level or shim test: partial random source read is retried.
- C-level or shim test: interrupted random source read is retried.
- C-level or shim test: unavailable random source fails loudly.

### Edge Cases To Probe

- `getrandom` returns `EINTR`.
- `getrandom` returns fewer bytes than requested.
- `/dev/urandom` returns short reads.
- random source cannot be opened.
- requested byte count is 0.
- requested byte count is negative.
- requested byte count is large enough to approach allocation limits.
- platform-specific behavior on macOS, Linux, and fallback Unix targets.

## Phase 4: FFI Boundary Hardening

Goal: default FFI should be conservative, and unsafe FFI choices should be
deliberate, visible, and mechanically checked.

### Work Items

- Keep default impure `foreign:` defensive-copy behavior for `String` and `Bytes`.
- Continue rejecting unsupported managed values in default foreign mode.
- Validate foreign C symbol names before Core lowering.
- Validate `include:` values before code emission.
- Keep `link:` values in a narrow structured subset: `-lNAME`, `-LDIR`,
  `-IDIR`, `-framework NAME`, and `-pthread`.
- Reject raw linker/compiler escape hatches such as response files, `-Wl,...`,
  and `-Xlinker`.
- Make `foreign pure` and `@no_copy` diagnostics/docs more explicit about
  borrowed direct runtime memory.
- Consider an `unsafe` spelling or annotation for direct-borrow native calls.
- Keep foreign return-type restrictions for refinements like `LiteralString` and
  range types.
- Add a single validation module for FFI metadata so parser, typecheck, Core,
  and emit do not drift.

### Acceptance

- Malicious `include:` strings cannot inject C preprocessor lines.
- Malicious foreign C names cannot inject C expressions or statements.
- Malicious foreign link flags cannot inject compiler/linker control flags
  outside the narrow supported set.
- Unsupported managed default arguments fail in typecheck with helpful guidance.
- `foreign pure` and `@no_copy` remain explicit trust assertions.
- Existing package FFI declarations still compile after validation.
- Codegen audit proves validated foreign metadata emits in the expected shape.

### Tests To Add

- Compiler `should_fail`: foreign C name with whitespace.
- Compiler `should_fail`: foreign C name with semicolon.
- Compiler `should_fail`: foreign C name with quotes.
- Compiler `should_fail`: `include:` containing a quote.
- Compiler `should_fail`: `include:` containing a newline.
- Compiler `should_fail`: `include:` containing control characters.
- Compiler `should_fail`: `link:` containing shell metacharacters.
- Compiler `should_fail`: `link:` containing unsupported raw linker flags.
- Compiler `should_fail`: default foreign block function with `List[T]` argument.
- Compiler `should_fail`: foreign block function returning `LiteralString`.
- Codegen audit: default String argument copies and releases the copy.
- Codegen audit: default Bytes argument copies and releases the copy.
- Codegen audit: `@no_copy` String argument borrows direct data.
- Codegen audit: `foreign pure` is callable from pure code only by assertion.

### Edge Cases To Probe

- `include: "x\"\nint pwned;"`.
- `include: "../native/foo.h"`.
- `include: "/tmp/foo.h"`.
- C name containing punctuation, whitespace, comments, quotes, or semicolons.
- Link flags containing shell metacharacters.
- Link flags containing spaces that should remain grouped.
- Link flags containing raw linker escapes such as `-Wl,@file`.
- `foreign pure` mutates a `String`.
- `foreign pure` mutates a `Bytes`.
- `@no_copy` retains a borrowed pointer after returning.
- Foreign function returns a pointer to a defensive-copy argument.
- Foreign function accepts `String` with embedded NUL.
- Foreign function accepts `Bytes` but treats it as a C string.
- Foreign function accepts or returns `Ptr`.
- Foreign declaration appears in an imported user module.
- Foreign declaration appears in a package module.
- Foreign declaration appears in std and is rejected.

## Phase 8: Generated C Hygiene

Goal: generated C should only contain raw source-controlled text where that text
has been validated as FFI metadata. Everything else should be escaped, mangled,
or registry-owned.

### Work Items

- Audit every path where source text reaches C output.
- Keep user function symbols DefId-mangled.
- Keep C identifier sanitization centralized.
- Keep string literal escaping centralized.
- Replace ad hoc C-string escaping with the shared escaping helper where needed.
- Ensure builtin C names come from compiler registries, not user source.
- Ensure foreign C names and includes are validated before emission.
- Add codegen audit cases for malicious identifiers and literals.
- Add codegen audit cases for malicious FFI metadata once Phase 4 validation is
  in place.
- Include `runtime.c` in C static analysis.
- Keep generated-C warning sweeps focused on warning classes that imply memory
  or ABI risk.

### Acceptance

- Source identifiers cannot collide with generated helper names in a way that
  changes behavior.
- Source strings cannot escape generated C string literals.
- Foreign metadata is the only intentional raw-C-adjacent source input.
- Warning sweeps catch incompatible pointer types and unsequenced behavior.
- `runtime.c` static analysis is part of the local security/quality gate.

### Tests To Add

- Codegen audit: identifier that is a C keyword.
- Codegen audit: identifier matching libc/POSIX names.
- Codegen audit: identifiers that sanitize to the same text.
- Codegen audit: module path with dots and slashes.
- Codegen audit: string literal with quotes and backslashes.
- Codegen audit: string literal with NUL/control bytes.
- Codegen audit: string literal with non-ASCII bytes.
- Codegen audit: pattern matching on string literals with control bytes.
- Codegen audit: generated helper name collision attempt.
- Static-analysis gate: `compiler/lib/runtime.c`.

### Edge Cases To Probe

- Source name `system`, `malloc`, `free`, `open`, `read`, `write`, `fork`.
- Source names that differ only by punctuation after sanitization.
- Source names containing Unicode bytes.
- Very long identifiers.
- Very long module paths.
- Strings ending with octal-looking or hex-looking bytes.
- Strings containing `\0`, quotes, backslashes, newlines, carriage returns, and
  tabs.
- Docstrings containing code-like C text.
- Foreign declarations in modules imported under aliases.
- Builtin runtime names leaking from user code.

## Minimal Security Gate For This Scope

This is intentionally narrower than a full future `security-check`.

Add a fast gate that runs:

- C static analysis for `runtime.c` and `runtime_decl.c`;
- compiler tests for FFI metadata validation;
- codegen audit tests for generated-C escaping and name hygiene;
- targeted runtime tests for process, file, NUL-boundary, and randomness fixes;
- targeted sanitizer/leak checks for the runtime tests above;
- all of the above with test result caching disabled.

Acceptance:

- the gate catches regressions in phases 2, 3, 4, and 8;
- the gate is small enough to run during normal compiler/runtime work;
- broad sandbox, package policy, and long fuzzing gates stay separate for now.

Current command:

```bash
make security-check
```

## Suggested Implementation Order

1. Add targeted tests for the known runtime P1s.
2. Fix process stdout/stderr draining.
3. Fix exact file reads and writes.
4. Add OS C-string conversion helpers with embedded-NUL rejection.
5. Harden `crypto_random_bytes` and hash seed initialization.
6. Add FFI metadata validation.
7. Add malicious FFI parser/typecheck/codegen tests.
8. Add generated-C escaping/name-hygiene audit cases.
9. Include `runtime.c` in static analysis.
10. Add a narrow security gate for these checks.

## Known Findings To Track

- `foreign pure` and `@no_copy` are powerful trust assertions.
- The TCP runtime still has broader concurrency-design questions, including
  nonblocking socket calls while a handle mutex is held. That is intentionally
  outside this memory/FFI-focused slice.
- Generated C still needs broader audit cases for malicious source names.
