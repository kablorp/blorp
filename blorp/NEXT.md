# What's next

An index of open work, as of 2026-11-08. Each entry says where the work
stands, its next step, any decision it waits on, and the document that owns
it. The owning document is the authority; this file only points to it.
Update the entry when a workstream moves, and delete it when the work is
done.

## Workstreams

- **UInt8 and Bytes:** [`UINT8_BYTES_PLAN.md`](UINT8_BYTES_PLAN.md).
  - **Status:** U1 to U9 and B1 to B3 are decided. The S0 spike is done.
  - **Next:** L0, a pure refactor that models Int as
    `IntegerType(Int64Format)`, with byte-identical C.
  - **Waits on Keith:** L0's corrected line ceiling (see the plan's
    Ceilings). L0's brief must be rewritten from the plan, because the first
    one lives outside the repository.
  - **Afterwards:**
    - L1, the compiler learns `UInt8`, with deferred integer literals;
    - L2, a seed rotation, which also switches the seed family;
    - L3, the library: `_base`, `uint8.brp`, `bytes.brp`, and
      `fs.read_bytes`/`write_bytes`;
    - L4, `String.byte_at` returns `Option[UInt8]`.
- **Process API:** [`PROCESS_DECISIONS.md`](PROCESS_DECISIONS.md).
  - **Status:** approved; nothing is implemented.
  - **Next:** L0, moving fs's errno codes (the private `…_CODE` constants
    in `standard_library/fs.brp`) and `decode_error` into one shared internal
    module. It changes no behaviour and is independent of the UInt8 work.
  - **Afterwards:**
    - L1, the `process.capture` and `process.find_program` natives, the C core
      and `process.brp`;
    - L2, migrating the 17 `run_to_files` call sites and deleting it.
  - **Later:** binary capture after `Bytes`, and `run` with streaming.
- **Filesystem:** [`FILESYSTEM_DECISIONS.md`](FILESYSTEM_DECISIONS.md).
  - **Status:** Part 1 has landed through `fold_lines`. Part 2, lent
    resources, waits for a consumer.
  - **Next:** D40, a pure `String.lines()` with `fold_lines`'s line rules, so
    `read_text(path).lines()` collects lines.
  - **Later:** the plan's "Later" list.
- **Formatter, `blorp` command, embedded standard library:**
  [`FORMATTER_PLAN.md`](FORMATTER_PLAN.md), [`CLI_PLAN.md`](CLI_PLAN.md) and
  [`EMBEDDED_LIBRARY_PLAN.md`](EMBEDDED_LIBRARY_PLAN.md). Other sessions own
  them; see each plan's status line, and `git log` for what has landed since
  (the embedded library landed in `1a68dbd3b`).

## Smaller follow-ups

None of these is planned yet. Each wants its own short design or brief.

- **Patterns.**
  - Guards, such as `Exited(status) if status != 0`.
  - Whole-value binding while destructuring.
  - Record patterns by field name.
  - The parser's "expected a match pattern" message still suggests "an ASCII
    identifier" for every other token it cannot read.
- **`Char`.** The grammar already reserves Char literals and patterns. A
  `Char` type with ASCII predicates (`is_ascii_digit()` and the like) covers
  most ASCII-only text code without a second string type.
- **Integer bit operations** (UInt8 plan, U7). One change for every integer
  format, with names that do not collide with Bool's `and`, `or` and `not`.
- **Binary patterns.** Erlang-style matching and construction on `Bytes`, with
  sized, endian segments and storage-sharing slices. It waits for a
  binary-format consumer.
- **Generic List gaps:**
  - `slice(start, end)`;
  - `starts_with` and `index_of` for `T: Equatable`;
  - lexicographic `Orderable` for `List[T: Orderable]`.
- **Compiler costs found while landing work:**
  - **A named lambda costs one allocation per call.** Binding a lambda to a
    local before passing it costs an allocation that an inline lambda does
    not (`benchmarks/results/blorp_fs_lines_2026-11-05.md`).
  - **`max` and `min` are receiver-only.** `max(a, b)` reports "unknown
    function", so only `a.max(b)` works.
- **Constants cannot call functions,** so a `Bytes` constant such as a file
  signature must be written as a function.

## Working notes for agents

- **Never run compiled binaries in parallel with another session's** on macOS.
  Before each build, gate or measurement, wait for
  `pgrep -f '^[^ ]*self-hosted-tests/driver/driver'` and
  `pgrep -f '^[^ ]*blorp/build/(compiler|fixpoint)'` to come back empty. The
  pattern is anchored so that a waiting shell never matches itself.
- **A subagent's commands move to the background after about 180 s.** Put the
  busy check inside your own scripts, start long scripts in the background,
  and wait for their exit notification rather than polling.
- **Landing.** Squash onto origin/main in a landing branch and re-run the
  gates:
  - `make -C blorp test`, `scripts/blorp-fixpoint --prove` and
    `git diff --check`;
  - branch CI for platform-sensitive changes:
    `gh workflow run blorp.yml --ref <branch>`.

  Confirm origin/main is an ancestor, then push `HEAD:main` as a separate
  step. If main moves while the gates run, replay and re-gate.
