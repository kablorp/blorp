# What's next

An index of open work, as of 2026-11-11. Each entry says where the work
stands, its next step, any decision it waits on, and the document that owns
it. The owning document is the authority; this file only points to it.
Update the entry when a workstream moves, and delete it when the work is
done.

## Workstreams

- **UInt8 and Bytes:** [`UINT8_BYTES_PLAN.md`](UINT8_BYTES_PLAN.md).
  - **Status:** U1 to U9 and B1 to B3 are decided. L0, the
    `IntegerType(Int64Format)` refactor, and L1, the compiler's `UInt8` with
    deferred integer literals and the byte natives (`0bb93894d`), have
    landed. L2 pins the seed built from L1 (`blorp-seed-0bb93894dcf2`).
  - **Landed:** L3, the library: `_base`, `uint8.brp`, `bytes.brp`, and
    `read_bytes`/`write_bytes` in `io/fs/`. `LSP_PLAN.md`'s landing 6 needs
    only L1; its console labels ride a later rotation. Its landing 8 can
    now proceed.
  - **Next:** L4, `String.byte_at` returns `Option[UInt8]`.
- **Process API:** [`PROCESS_DECISIONS.md`](PROCESS_DECISIONS.md).
  - **Status:** L0 is implemented and independently reviewed; final combined
    landing gates and four-platform CI pass; L0 is published. Shared
    errors/formatting belong to `io`,
    with one internal native-code decoder. Existing imports are migrated.
    L1 is implemented: the `process.capture`, `process.find_program` and
    `process.fault` natives, the C core and `process.brp`. A reply the C side
    never builds aborts through `process.fault`.
    L2 landed on 2026-11-11: every caller uses `capture` or `output`,
    `run_to_files` is deleted, and `Command.program` is a `Path`.
  - **Next:** the terminal-sharing `run` (the amendment Keith approved on
    2026-11-11, P6 to P11), then a seed rotation, then `blorp run` and
    `blorp test` (`RUN_AND_TEST_PLAN.md`).
  - **Later:** binary capture after `Bytes`, and `run` with streaming.
- **Language server (`blorp lsp`):** [`LSP_PLAN.md`](LSP_PLAN.md).
  - **Status:** the plan was written and revised on 2026-11-10 (name uses
    keyed by the compiler's identities; each analysis records the files it
    read). Keith settled its open decisions on 2026-11-11: CLion first, name
    uses always recorded, and broken files served from the last good
    analysis in a landing after the plugin. He then asked for, and approved, a
    byte console API, so landing 6 waits for the UInt8 plan's L1 and landing 8 for its
    L3. Its foundations have
    landed: the `json` codec
    and loader source snapshots (`load_program_with_sources`, in the README's
    Load phase).
  - **Landed:** landing 1, analysis without an entry point; landing 2,
    comments as lexer output; and landing 3, the lexer's prefix on failure.
  - **Next:** landing 4, fixed identities: seven plain types become `fixed`,
    so the name-use rows of landing 5 take no allocation each.
- **String code points:** [`STRING_PLAN.md`](STRING_PLAN.md).
  - **Status:** approved on 2026-11-10: `length` counts code points, from a
    count stored in each String, and byte work uses `byte_*` functions. L1
    landed on 2026-11-12: every String keeps its count, the compiler knows the
    five byte and code point operations, and strict runs recount each String
    on release.
  - **Next:** a cheaper recount, because L2's seed would otherwise push the
    e2e compiles over their 15% instruction margin; then L2, a seed rotation,
    and the breaking switch (L3).
- **Filesystem:** [`FILESYSTEM_DECISIONS.md`](FILESYSTEM_DECISIONS.md).
  - **Status:** Part 1 has landed through `fold_lines`. Part 2, lent
    resources, waits for a consumer.
  - **Built:** D40, a pure `String.lines()` with `fold_lines`'s line rules, so
    `read_text(path).lines()` collects lines.
  - **Later:** the plan's "Later" list.

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
- **Checking a bounded generic function costs time quadratic in their number.**
  - Every compile checks every library module the prelude reaches, so
    adding `List.starts_with` (23 M instructions) and `Orderable for List`
    (20 M) raised a hello program's compile from 322 M to 395 M instructions
    (+22%, `-O0`), 51 M of it from the List additions.
  - Probe: N copies of `pure func ne_i[E: Equatable](a: E, b: E) -> Bool: a != b`
    beside hello cost 416 M with none, 653 M for N=10, 2.43 G for N=40 and
    7.12 G for N=80. `==` costs about a tenth as much as `!=` (642 M for 40).
  - Lead: the allocations come from `instantiation_paths.insert` and
    `recursion.dependency_graph`. Raw data is in the main checkout's ignored
    `build/measurements/bounded-generic-checking-2026-11-12/`.
- **Names and errors:**
  - **The clash message for a prelude String method's name.** A user function
    `lines(text: String)` reports "two functions named lines can accept the
    same receiver" with the help "rename one of them" and the notes "String
    and String". It should say, as the `max` clash does, that the name is
    provided by the prelude, and its help should name only the user's function.
  - **A test-visible form of `private`.** The decoders in `io/environment`,
    `io/process` and `io/_codes` are public with a "not API" comment so that
    tests can pass them literal codes.
  - **An opaque `DeclaredName`,** so a declaring site cannot skip its naming
    check even by calling the token reader directly. It needs the syntax
    tree's declaration fields (about 12 in `syntax.brp`, read in 22 files) to
    hold the checked type: measured at +120 to +170 production lines and not
    done. Revisit with the LSP plan's name identities.
  - **Embedded-library size.** A trivial compile costs about 9% more
    instructions since `Path` and the `io/fs/` modules, because it follows
    the size of the embedded library text. `Path` stays an explicit import
    for the same reason (about +31,000 allocations and +26% instructions to
    compile an empty program as a prelude name); revisit once the checker
    checks only the declarations a program uses.
  - **Temporary-directory cleanup and `ENOSPC`.** One native serves
    `RemoveTreeError`, which has no `NoSpace`, and a temporary directory's
    cleanup, so `ENOSPC` during cleanup arrives as `OtherOs(28)`.
  - **`entry_kind` has no injected-errno test,** because its C fixture has
    no `lstat` hook.
- **A human-facing `Displayable`** with `display`, beside `Stringable`, which
  promises only a conversion to String. Wait for a use that needs the
  distinction.
- **Verify's function loop** does not `break` after the return-type
  membership failure (noticed 2026-11-10, not fixed).
- **The natives' path NUL guards are unreachable,** now that no `Path` holds
  NUL, though they send `PATH_CONTAINS_NUL`, which most error unions lack.
- **`import: dict` alone gives no qualified access,** so tests alias it as
  `dict_ops`.
- **`alias.Union.Variant` is deliberately unsupported** (Keith, 2026-11-10): a
  pattern head has two parts, and importing the union serves.
- **Compiler costs found while landing work:**
  - **A named lambda costs one allocation per call.** Binding a lambda to a
    local before passing it costs an allocation that an inline lambda does
    not.
  - **A plain record returned by value is heap-allocated** even when the
    caller destructures it at once. The lexer's `SkippedLines` (`CodeLine`
    before landing 3) costs one allocation per code line, 37,160 in the
    self-compile (`LSP_PLAN.md`, landing 2's measurement).
  - **`Orderable for String` is missing,** so `max` and `min`, which take any
    `Orderable`, do not take Strings.
  - **`scripts/self-compile-cost` cannot measure a change that makes a base
    role mandatory.** Its fixed-input workload compiles the base's library with
    the candidate compiler, which now rejects a base without the role. UInt8
    L3 took the fixed input from the candidate tree with an uncommitted copy.
- **No never-returning type.** `process.brp`'s `fault` calls the `process.fault`
  native, which aborts, and then a second function that is never reached, to
  give the call every type. A never-returning builtin result, or a bottom type,
  would replace the pair; do not copy it as a pattern.
- **Native tables repeat `process_helpers = False`** in 14 entries of
  `src/common/codegen/runtime/system.brp`. A default, or one grouped constructor,
  could remove them.
- **Constants cannot call functions,** so a `Bytes` constant such as a file
  signature must be written as a function.

- **The e2e driver prints a ceiling failure mid-line,** interleaved with the
  next PASS line, so a gate log hides it; search the raw log for "exceed the
  ceiling".
- **`test/runtime/fixtures/argv_test.c` is run by no suite,** like the two
  String probes that L1 brought back under `string_suite.brp`.

## Working notes for agents

- **Never run compiled binaries in parallel with another session's** on macOS.
  Before each build, gate or measurement, wait for
  `pgrep -f '^[^ ]*self-hosted-tests/driver/driver'` and
  `pgrep -f '^[^ ]*blorp/build/(blorp|compiler|fixpoint)'` to come back empty. The
  pattern is anchored so that a waiting shell never matches itself.
- **e2e compile allocations grow with the checkout's depth,** by about four
  per directory level: the compiler normalizes each absolute path it is
  given, one String per component. A deep worktree can exceed an exact
  ceiling that CI meets; compare with main at the same path before calling
  it a regression.
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
