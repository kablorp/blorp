# What's next

An index of open work, as of 2026-11-11. Each entry says where the work
stands, its next step, any decision it waits on, and the document that owns
it. The owning document is the authority; this file only points to it.
Update the entry when a workstream moves, and delete it when the work is
done.

## Workstreams

- **Foundation methods for library modules:**
  [`LIBRARY_METHODS_PROPOSAL.md`](LIBRARY_METHODS_PROPOSAL.md).
  - **Status:** Keith chose design 2 on 2026-11-22. Landing 1 adds
    `_methods.brp`, which every library module receives except the modules it
    imports. The 27 library rows stay for now.
  - **Next:** a seed rotation that pins a seed knowing the new role, then a
    landing that removes the 27 rows (about −27 lines).
- **Equality derivation:** [`EQUALITY_PLAN.md`](EQUALITY_PLAN.md).
  - **Status:** opaque types and tuples derive `==` from their constituents
    (landings 1 and 2, landed 2026-11-17).
  - **Next:** landing 3 deletes the 28 hand-written identity implementations
    after a seed rotation.
- **UInt8 and Bytes:** [`UINT8_BYTES_PLAN.md`](UINT8_BYTES_PLAN.md).
  - **Status:** U1 to U9 and B1 to B3 are decided. L0, the
    `IntegerType(Int64Format)` refactor, and L1, the compiler's `UInt8` with
    deferred integer literals and the byte natives (`0bb93894d`), have
    landed. L2 pins the seed built from L1 (`blorp-seed-0bb93894dcf2`).
  - **Landed:** L3, the library: `_base`, `uint8.brp`, `bytes.brp`, and
    `read_bytes`/`write_bytes` in `io/files/`. `LSP_PLAN.md`'s landing 6 needs
    only L1; its console labels ride a later rotation. Its landing 8 can
    now proceed.
  - **Landed:** L4b. `String.byte_at` returns `Option[UInt8]` through
    `string.byte_at_uint8`; the callers are updated and the old label is
    deleted. See the plan's L4.
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
    L3 landed on 2026-11-13: `io/terminal` (`run`, `exit_interrupted`),
    `io/_launch`, and the `process.run` and `process.exit_interrupted`
    natives. L4 pinned a seed that knows both labels
    (`blorp-seed-d62b0aacb2f1`).
  - **Next:** `blorp run` and `blorp test` (`RUN_AND_TEST_PLAN.md`).
  - **Later:** binary capture after `Bytes`, and `run` with streaming.
- **Language server (`blorp lsp`):** [`LSP_PLAN.md`](LSP_PLAN.md).
  - **Status:** the plan was written and revised on 2026-11-10 (name uses
    keyed by the compiler's identities; each analysis records the files it
    read). Keith settled its open decisions on 2026-11-11: CLion first, name
    uses always recorded, and broken files served from the last good
    analysis in a landing after the plugin. He then asked for, and approved, a
    byte console API. Its foundations have landed: the `json` codec and loader
    source snapshots (`load_program_with_sources`, in the README's Load phase).
  - **Landed:** landings 1 to 8: analysis without an entry point; comments as
    lexer output; the lexer's prefix on failure; fixed identities; name uses,
    one inline row per name used in source with its span and the identity it
    resolves to; the console labels with their runtime; a seed rotation to
    `blorp-seed-4fee244ad96f`; and the byte console library, one module per
    error type: `io/console/output` (`print`, `write`, `write_error`,
    `flush`), `io/console/read_line` and `io/console/read_exact`. Then 9a,
    the `blorp lsp` server core: the command, transport, lifecycle, UTF-8
    and UTF-16 positions, open documents and diagnostics (`src/lsp/`). Then
    9b: semantic tokens, with staleness, analysis on demand and watched
    files. Then 9c: definition and references, with the library written to
    a temporary folder as a view.
  - **Landed after the plugin's first checklist run:** the server removes its
    library folder at `shutdown`, asks the client to refresh an importer's
    tokens, and answers definition with `LocationLink`s, which CLion's Cmd-click
    needs.
  - **Landed:** landing 10, the CLion plugin (`editor/intellij/`): colours,
    diagnostics, Cmd-click and Cmd-B into the library, Find Usages and
    scratch files. It asks the server for Go to Declaration itself, because
    CLion's C/C++ engine hides those shortcuts from its LSP support.
  - **Landed:** landing 11: while a file fails to check, it is served from
    its program's last analysis that checked, through a line diff.
  - **Landed:** landing 12, the CLion plugin on LSP4IJ (Keith, 2026-11-21).
    Known limits: Alt+F7 and Cmd-click on a declaration list no usages in
    Keith's CLion.
  - **Landed:** landing 13: library files through
    `workspace/textDocumentContent`, with no folder in `/tmp`, and plain
    `Location`s.
  - **Next:** not chosen yet. The candidates are formatting, hover,
    project-wide references, or a simplification audit of `src/lsp/`. Each
    starts by checking that CLion's path reaches the server.
- **String code points:** [`STRING_PLAN.md`](STRING_PLAN.md).
  - **Status:** approved on 2026-11-10: `length` counts code points, from a
    count stored in each String, and byte work uses `byte_*` functions. L1
    landed on 2026-11-12: every String keeps its count, the compiler knows the
    five byte and code point operations, and strict runs recount each String
    on release. The recount now counts eight bytes per step, and L2 pinned a
    seed that carries it (2026-11-12).
  - **Next:** L3, the breaking switch, starting with its census.
- **Filesystem:** [`FILESYSTEM_DECISIONS.md`](FILESYSTEM_DECISIONS.md).
  - **Status:** Part 1 has landed through `fold_lines`. Part 2, lent
    resources, has a consumer: bounded-memory binary copy and streaming writes.
    S1 implements resource/scoped checking using Check-local completed-body
    admission. Source review, full tests, fixpoint, bootstrap and matched cost
    qualification pass; S3 below exposes the public streaming scopes.
  - **S2:** native chunk reads, shared atomic writer lifecycle and library-only
    raw-handle builtins pass source review, full tests, fixpoint and matched
    cost qualification, with no cost exception.
  - **S3:** qualified S2 seed published and pinned; public Reader/Writer
    scopes and six normal-main byte-streaming families pass focused and full
    ordinary and self-built tests. The user chose `io/files`; that rename
    passes fresh build, full proof, bootstrap and matched cost checks.
    Own-source costs are +0.56% allocations/+0.65% instructions, within limits.
  - **Native error protocol:** fixed typed kinds and shared conversions are
    implemented with precise operation errors preserved and 76 fewer
    production lines. All 2,902 selected checks, fixpoint and bootstrap pass.
    Matched own-source costs are +0.024% allocations/+0.068% instructions,
    within the +1% ceilings; positive-error lookup debt is recorded.
  - **Next:** S4 text decoding/adapters as a separate reviewed increment.
  - **Built:** D40, a pure `String.lines()` with `fold_lines`'s line rules, so
    `read_text(path).lines()` collects lines.
  - **Later:** the plan's "Later" list.
- **Library cost:** [`LIBRARY_COST_PLAN.md`](LIBRARY_COST_PLAN.md).
  - **Status:** option (a) landed: bounded generic functions no longer cost
    time quadratic in their number. Keith approved option (b) on 2026-11-16:
    checking elaborates a library body only when the program reaches it, and
    `make test` checks the whole library. Its landing is in review.
  - **Next:** a faster lexer and parser, which then carry most of a small
    compile's cost (the plan's "Adjacent problems").
- **Cost quirks:** [`COST_QUIRKS_PLAN.md`](COST_QUIRKS_PLAN.md).
  - **Status:** Keith approved four stacked landings on 2026-11-12: L1,
    interpolation as one left-nested chain; L2, loop iterations ending the
    owners they inherit at their last read; L3, stale workaround notes; and
    Q2, emit's failure-flag loops carrying a `Result`.
  - **Next:** land them in order. Records by value has its own plan below.
- **Release in constant C stack:** [`RELEASE_PLAN.md`](RELEASE_PLAN.md).
  - **Status:** Keith approved two stacked landings on 2026-11-16: L1, the
    cold split (a drop only decrements and calls an out-of-line release
    body), and L2, the depth budget (releasing any value uses bounded C
    stack). The plan's measurements record each landing.
  - **Next:** lifting the one-self-payload rule, which no longer protects
    release; it waits for the recursive-unions decision.

- **Recursive unions:** [`RECURSIVE_UNIONS_PLAN.md`](RECURSIVE_UNIONS_PLAN.md).
  - **Status:** approved by Keith on 2026-11-16 and landed, after deep
    release: Check classifies each union that contains itself and
    specialization stores it on the heap, and a generic type may recurse
    unless its arguments grow.
  - **Follow-ups:** records by value joined the same classification.
- **Records by value:** [`RECORDS_PLAN.md`](RECORDS_PLAN.md).
  - **Status:** approved by Keith on 2026-11-16 (a bound of one counted
    pointer per copy) and landed: Check classifies the records that contain
    themselves, records first, and specialize stores every other record
    inline, by value or in a counted cell from what a copy costs; `fixed`
    only constrains fields.
  - **Next:** raising the bound, after field moves in own, borrowed records
    by address and `static` functions each measure (the plan's last
    section).

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
- **Checking cost follows the library, not the program:** see
  [`LIBRARY_COST_PLAN.md`](LIBRARY_COST_PLAN.md).
- **Names and errors:**
  - **The clash message for a prelude String method's name.** A user function
    `lines(text: String)` reports "two functions named lines can accept the
    same receiver" with the help "rename one of them" and the notes "String
    and String". It should say, as the `max` clash does, that the name is
    provided by the prelude, and its help should name only the user's function.
  - **A test-visible form of `private`.** Operation decoders and the native
    protocol helpers in `io/_errors` are public for tests that pass literal
    codes; they are internal APIs by convention.
  - **List constants.** The compiler currently rebuilds a module List at each
    use. The typed-error witness measures one temporary allocation per positive
    error decode; see the accepted debt in FILESYSTEM_DECISIONS. No compiler
    workaround or cache is part of the library refactor.
  - **An opaque `DeclaredName`,** so a declaring site cannot skip its naming
    check even by calling the token reader directly. It needs the syntax
    tree's declaration fields (about 12 in `syntax.brp`, read in 22 files) to
    hold the checked type: measured at +120 to +170 production lines and not
    done. Revisit with the LSP plan's name identities.
  - **Embedded-library size.** A trivial compile costs about 9% more
    instructions since `Path` and the `io/files/` modules, because it follows
    the size of the embedded library text. `Path` stays an explicit import
    for the same reason (about +31,000 allocations and +26% instructions to
    compile an empty program as a prelude name). Option (b) of
    [`LIBRARY_COST_PLAN.md`](LIBRARY_COST_PLAN.md) roughly halves that cost;
    Keith kept `Path` out of the prelude on 2026-11-16 all the same.
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
    not. Keith, 2026-11-12: not worth a change while it has one site
    (`COST_QUIRKS_PLAN.md`, decision 3).
  - **`Orderable for String` is missing,** so `max` and `min`, which take any
    `Orderable`, do not take Strings.
  - **Concatenating onto an empty list copies the other list,** as does
    concatenating a list read out of a record that stays live. `LSP_PLAN.md`'s
    landing 5 measured 12,523 such copies (8.0 MB) per self-compile. Returning
    the other list shared when one side is empty would remove the first kind.
  - **Namespace `ResolvedName` rows are heap records,** about 8.6k allocations
    per self-compile, because `Entity.Alias` holds an `AliasedModule` with a
    path, so they cannot be `fixed`.
  - **`scripts/self-compile-cost` cannot measure a change that makes a base
    role mandatory.** Its fixed-input workload compiles the base's library with
    the candidate compiler, which now rejects a base without the role. UInt8
    L3 took the fixed input from the candidate tree with an uncommitted copy.
- **Peak heap is in the pinned seed** (`blorp-seed-d62b0aacb2f1`, rotated
  2026-11-13 with the process plan's L4). A diagnostic build's strict run
  ends with `blorp: peak heap: N bytes`, and `scripts/self-compile-cost` now
  reports the compiler's peak. The e2e driver requires the line from every
  compile (`positive_allocations`). Plans can set peak heap ceilings from the
  script's table.
- **`scripts/self-compile-cost` leaves its worktrees behind when killed.** The
  next run with the same revisions then fails because
  `build/self-compile-cost/<label>/worktree-*` already exists.
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
- **`test/test_common/test_codegen/test_runtime/fixtures/argv_test.c` is run by no
  suite,** like the two String probes that L1 brought back under `string_suite.brp`.

## Working notes for agents

- **A subagent's commands move to the background after about 180 s.** Start
  long scripts in the background and wait for their exit notification rather
  than polling.
- **Landing.** Squash onto origin/main in a landing branch and run the gates
  there once:
  - the gates `blorp/AGENTS.md` ("Which gates a change runs") names for the
    change, and `git diff --check`;
  - branch CI for platform-sensitive changes:
    `gh workflow run blorp.yml --ref <branch>`.

  Confirm origin/main is an ancestor, then push `HEAD:main` as a separate
  step. If main moves while the gates run, replay, and re-gate only as that
  rule says.
