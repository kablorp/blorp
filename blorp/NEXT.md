# What's next

An index of open work, as of 2026-11-09. Each entry says where the work
stands, its next step, any decision it waits on, and the document that owns
it. The owning document is the authority; this file only points to it.
Update the entry when a workstream moves, and delete it when the work is
done.

## Workstreams

- **UInt8 and Bytes:** [`UINT8_BYTES_PLAN.md`](UINT8_BYTES_PLAN.md).
  - **Status:** U1 to U9 and B1 to B3 are decided. S0 and the L0
    `IntegerType(Int64Format)` refactor are implemented and independently
    reviewed and published; combined local gates and four-platform CI pass. Matched costs
    pass unchanged performance ceilings; see
    [`L0 results`](../benchmarks/results/blorp-integer-model-l0-2026-11-08.md).
  - **Next:** L1, adding UInt8 with deferred integer literals.
  - **Afterwards:**
    - L1, the compiler learns `UInt8`, with deferred integer literals;
    - L2, a plain seed rotation onto L1 (the family and command-line switch landed
      with the modules plan's landing 6);
    - L3, the library: `_base`, `uint8.brp`, `bytes.brp`, and
      `fs.read_bytes`/`write_bytes`;
    - L4, `String.byte_at` returns `Option[UInt8]`.
- **Nested modules, `Stringable`, `io/` and the prelude:**
  [`MODULES_AND_STRINGABLE_PLAN.md`](MODULES_AND_STRINGABLE_PLAN.md).
  - **Status:** landings 1 to 6 are done: nested library modules,
    `Stringable` interpolation, library errors as `Stringable` (`describe`
    deleted), `print` and `print_error` in the prelude (run before the move),
    and the `io/` layout (`io/console`, `io/error`, `io/fs`, `io/process`,
    `io/environment`, `io/_codes`).
  - **Landing 6:** the seed rotation is done: pin `blorp-seed-10c8053d2399`,
    family `blorp`, and the `compile` command line. Seed-built code now
    interpolates values directly (`68df72215`).
  - **Next:** `Path` (landing 7), planned in [`PATH_PLAN.md`](PATH_PLAN.md):
    enforced naming rules, qualified union variants, the `Path` type and a
    current-directory native, a seed rotation, exact I/O errors in
    type-oriented modules, then `Path` in the prelude. Landings 1 (naming
    rules), 2 (qualified variants), 3 (the `Path` type), 4 (the
    current-directory native) and 5 (the seed rotation, pinning
    `blorp-seed-4acd2377961d`) have landed. Seed-built code may now use
    `Union.Variant` and the new native. Landing 6, process and environment
    errors, is next.
- **Process API:** [`PROCESS_DECISIONS.md`](PROCESS_DECISIONS.md).
  - **Status:** L0 is implemented and independently reviewed; final combined
    landing gates and four-platform CI pass; L0 is published. Shared
    errors/formatting belong to `io`,
    with one internal native-code decoder. Existing imports are migrated.
    [`L0 results`](../benchmarks/results/blorp-process-l0-2026-11-08.md).
    L1 is implemented: the `process.capture`, `process.find_program` and
    `process.fault` natives, the C core and `process.brp`. A reply the C side
    never builds aborts through `process.fault`.
  - **Next:** L2, migrating the 17 `run_to_files` call sites and deleting it,
    after `PATH_PLAN.md`'s landing 6 changes the process errors.
  - **Later:** binary capture after `Bytes`, and `run` with streaming.
- **Language server (`blorp lsp`):** [`LSP_PLAN.md`](LSP_PLAN.md).
  - **Status:** the plan was written on 2026-11-10 and awaits Keith's review.
    Four choices are open: the first editor, the console API, when
    occurrences are recorded, and serving broken files. Its foundations have
    landed: the `json` codec
    ([results](../benchmarks/results/blorp-json-foundation-2026-11-08.md))
    and loader source snapshots
    ([results](../benchmarks/results/blorp-source-snapshots-2026-11-09.md),
    [`SOURCE_SNAPSHOTS_DECISIONS.md`](SOURCE_SNAPSHOTS_DECISIONS.md)).
  - **Revision still to make:** key name uses by the compiler's existing
    identities rather than by copied definition spans, and record which
    files each analysis read.
  - **Next:** that revision, then the plan's landing 1, analysis without an
    entry point. The source layout it waited for has landed
    ([`SOURCE_LAYOUT_PLAN.md`](SOURCE_LAYOUT_PLAN.md)).
- **String code points:** [`STRING_PLAN.md`](STRING_PLAN.md).
  - **Status:** approved on 2026-11-10: `length` counts code points, from a
    count stored in each String, and byte work uses `byte_*` functions. S0
    measured the count's cost, and S3 to S9 and the ceilings are approved as
    recommended.
  - **Next:** L1, where the runtime keeps the count and the compiler learns
    the new operations, then a seed rotation and the breaking switch (L3).
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
- **Aggregate definition order:** [`AGGREGATE_ORDER_PLAN.md`](AGGREGATE_ORDER_PLAN.md).
  - **Status:** landed 2026-11-10 as `bcc6bfdb1`. Test lines came to +461
    against a +450 ceiling, awaiting the coordinator's budget correction.
  - **Next:** none; remove this entry once the ceiling is settled.

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
- **Tooling found broken or quiet while landing work:**
  - `scripts/blorp-compiler-bootstrap` prints nothing when it downloads or
    reuses a cached seed, so a build log cannot show which seed it used.
  - **Unit files outside `COMPONENT_SOURCES` rot unseen.** No gate compiles
    them: `test_check/test_structural_patterns.brp` no longer compiles
    (`is_ok` is unknown), and ten test imports name files that are gone.
- **Compiler costs found while landing work:**
  - **A named lambda costs one allocation per call.** Binding a lambda to a
    local before passing it costs an allocation that an inline lambda does
    not (`benchmarks/results/blorp_fs_lines_2026-11-05.md`).
  - **`max` and `min` are receiver-only.** `max(a, b)` reports "unknown
    function", so only `a.max(b)` works.
- **No never-returning type.** `process.brp`'s `fault` calls the `process.fault`
  native, which aborts, and then a second function that is never reached, to
  give the call every type. A never-returning builtin result, or a bottom type,
  would replace the pair; do not copy it as a pattern.
- **Native tables repeat `process_helpers = False`** in 14 entries of
  `src/common/codegen/runtime/system.brp`. A default, or one grouped constructor,
  could remove them.
- **Constants cannot call functions,** so a `Bytes` constant such as a file
  signature must be written as a function.

## Working notes for agents

- **Never run compiled binaries in parallel with another session's** on macOS.
  Before each build, gate or measurement, wait for
  `pgrep -f '^[^ ]*self-hosted-tests/driver/driver'` and
  `pgrep -f '^[^ ]*blorp/build/(blorp|compiler|fixpoint)'` to come back empty. The
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
