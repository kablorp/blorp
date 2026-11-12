# Organize `blorp/src` by command

**Status: approved by Keith on 2026-11-10, with its four choices as
recommended.** It lands before the language server (`LSP_PLAN.md`) and
before any other material change to `src/`. Both steps have landed: step 1
as `acecd2a5c`, and step 2 in the commit that splits `main.brp` and `cli.brp`.

## Problem

The tree does not say which code belongs to which command:

```console
$ ls blorp/src blorp/src/compile
blorp/src:
cli.brp  compile  format  main.brp  source_walk.brp  syntax  utils

blorp/src/compile:
assemble.brp  check  emit  ids.brp  load  lower  namespace  own  runtime  specialize  verify
```

**`compile/` holds every compiler phase.** That is 41 files and 56,811
lines, and three planned commands will need them:

| Command | Needs | Plan |
| --- | --- | --- |
| `blorp run` | the phases up to C | approved in `RUN_AND_TEST_PLAN.md` |
| `blorp test` | the phases up to C | approved in `RUN_AND_TEST_PLAN.md` |
| `blorp lsp` | the analysis half | `LSP_PLAN.md` |

**The compile command's own code is not in `compile/`.** Its option parsing
is in `src/cli.brp`, and its shell (`compile_request` and `publish`) is in
`src/main.brp`. Both files also hold the format command's code and the
diagnostic reporting that both commands share.

**`src/source_walk.brp` serves only `blorp format`,** but it sits at the
top level.

## Background

**Keith's decision, 2026-11-10.**

- `blorp/src` is organized by command: `compile/`, `format/`, `lsp/` and
  `run/`.
- Code used by more than one command lives in one shared directory. That
  directory holds `syntax/`, `analysis/` and the rest.
- This cleanup comes first.

It supersedes the 2026-11-07 layout, which kept `syntax/` at the top level
(`065e5e9ce`).

**The import graph already splits cleanly.** I computed it from every `import:`
block under `src/`:

| Group | Directories | Imports |
| --- | --- | --- |
| **Analysis** (26 files, 30,339 lines) | `load/`, `assemble.brp`, `ids.brp`, `namespace/`, `check/` | only itself, `syntax/` and `utils/`, plus the generated library module (`load.brp:15`) |
| **Code generation** (15 files, 26,472 lines) | `specialize/`, `lower/`, `own/`, `verify/`, `emit/`, `runtime/` | itself, analysis, `syntax/` and `utils/` |
| **`format/`** | | `syntax/` and `utils/` |

No analysis module imports code generation.

**Generated C keeps its bytes across a directory move.** Function labels come
from the file name alone (`file_stem`, `src/common/syntax/source.brp`), and
they appear only in C comments. The 2026-11-07 move produced byte-identical
C the same way.

**Today's layer rules** are in `test/unit/test_format/test_dependencies.brp:16`:

- `syntax/` may import `syntax/` and `utils/`;
- `format/` may import `format/`, `syntax/` and `utils/`, and never
  `compile/`.

## Choices, approved by Keith on 2026-11-10

1. **The shared directory is named `common/`.** It holds Blorp's shared
   layers, not just helpers. `common/utils/` keeps today's meaning of
   `utils/`: code with no Blorp knowledge. Every shared layer is then a
   subdirectory, so the dependency rules stay one rule per directory.
2. **Code generation moves to `common/codegen/` now.**
   - **Why now:** `blorp run` and `blorp test` are approved, and both compile
     to C. Moving now is one move instead of two.
   - **The alternative:** keep the phases in `compile/` until `run` lands,
     then move them.
3. **Command modules get distinct file names:** `compile/compile_command.brp`
   and `format/format_command.brp`. Labels and allocation-site reports name
   functions by file stem, and two files called `command.brp` would make
   those reports ambiguous.
4. **`SourceFile` and `SourceInputs` move** from `analysis/load/load.brp` to
   `common/syntax/source.brp`. Today they live in the loader. After the move,
   the format command and diagnostic reporting can use them without importing
   analysis, as the 2026-11-07 rule ("the formatter never imports the
   compiler") requires.

## Proposed solution

The target tree:

```text
blorp/src/
  main.brp                  entry: reads the command word, dispatches, `blorp help`
  compile/
    compile_command.brp     `blorp compile`: options, help text, shell
  format/                   `blorp format`: the formatter (unchanged), and
    format_command.brp      its options, help text and shell
    source_walk.brp         from src/
  lsp/                      later, LSP_PLAN.md
  run/                      later, RUN_AND_TEST_PLAN.md
  common/
    utils/                  results, stack, text: no Blorp knowledge (from src/utils/)
    syntax/                 lex, parse, names, source, syntax (from src/syntax/)
    analysis/               load, assemble, ids, namespace, check (from src/compile/)
    codegen/                specialize, lower, own, verify, emit, runtime (from src/compile/)
    cli/                    exit statuses, usage errors, option helpers, diagnostic reports
```

**The rules, enforced by one dependency suite:**

- **Commands.** A command directory imports only itself and `common/`. It
  never imports another command or `main.brp`.
- **`common/`** never imports a command or `main.brp`.
- **Layers inside `common/`** import only downward:

  | Layer | May import |
  | --- | --- |
  | `utils/` | `utils/` |
  | `syntax/` | `syntax/`, `utils/` |
  | `analysis/` | `analysis/`, `syntax/`, `utils/`, and `blorp/build/generated/` (the embedded library) |
  | `codegen/` | `codegen/`, `analysis/`, `syntax/`, `utils/` |
  | `cli/` | `cli/`, `syntax/`, `utils/` |

- **The formatter.** `format/` imports only `common/syntax/`, `common/cli/`
  and `common/utils/`. It never imports `analysis/` or `codegen/`.
- **`main.brp`** imports the commands and `common/cli/`.

**When each rule applies.** The rules for `common/`'s layers, and the rule
that `common/` imports no command, hold from step 1. The rules for commands,
the formatter and `main.brp` hold from step 2. Until then `main.brp` and
`cli.brp` stay at the root of `src/`, and `format/source_walk.brp` still
imports `cli.brp`.

**Where step 2 puts the contents of `main.brp` and `cli.brp`:**

| What | Goes to |
| --- | --- |
| `main`, `Command`, `parse_command`, `OVERVIEW`, `HELP_HELP`, `parse_help` | `main.brp` |
| Compile options, `CompileRequest`, `COMPILE_HELP` (now public), `compile_request`, `publish` | `compile/compile_command.brp` |
| Format options, `FormatRequest`, `FORMAT_HELP` (now public), `format_request`, `format_file` | `format/format_command.brp` |
| `EXIT_*`, `error_message`, option helpers, `has_source_suffix`, location and diagnostic rendering, `report_failure`, `kind_status`, `diagnostics_status` | `common/cli/` |
| `compile(program)`, renamed `generate_c` | `common/codegen/` |

`main.brp` imports the help texts from the commands, and no command imports
`main.brp`, so there is no cycle. Once `SourceFile` and `SourceInputs` are in
`common/syntax/source.brp`, the renderers need only syntax types. Their sole
use of `render_failure`, from `check/render.brp`, leaves with `compile`.

The work lands in two steps, so each step can be proved on its own.

1. **Move directories.** A mechanical move that keeps file names:
   - `syntax/` becomes `common/syntax/`;
   - `utils/` becomes `common/utils/`;
   - the analysis group becomes `common/analysis/`;
   - the code-generation group becomes `common/codegen/`;
   - `source_walk.brp` moves into `format/`.

   Tests move to mirror `src/`, and every path that names a moved file
   changes. No file is renamed, so the generated C is byte-identical.
2. **Split `main.brp` and `cli.brp` by command.**
   - Each command's options, help text and shell go to its `*_command.brp`.
   - Shared reporting and option helpers go to `common/cli/`.
   - `main.brp`'s `compile(program)` pipeline goes to `common/codegen/` as
     `generate_c`.
   - `SourceFile` and `SourceInputs` move to `common/syntax/source.brp`.

   Behaviour is identical. The C changes only in function order and comment
   labels.

**Rejected:**

- **`syntax/` directly under `utils/`.** That would turn `utils/` into
  "anything shared" and hide the grammar authority.
- **A top-level `src/language_server.brp`,** which I suggested earlier.
  Each command now owns its shell inside its own directory.
- **Splitting before moving.** The split creates `compile/compile_command.brp`,
  but `compile/` cannot hold the command until the phases have left it.

## Code

**Imports inside analysis keep their text,** because the group moves
together. So do analysis and code generation's imports into `syntax/` and
`utils/`, because those directories move under `common/` as well. Every other
import changes: those of `format/`, `main.brp`, `cli.brp`, `source_walk.brp`
and `scripts/embed_library.brp`, those between analysis and code generation,
and `load.brp:15`'s import of the generated library, which goes two levels
deeper. For example,
`src/compile/check/check.brp:5`, which becomes
`src/common/analysis/check/check.brp`:

```blorp
import:
    result: Result methods
    ../assemble: ParsedProgram
    ../ids: FunctionId, RecordId, UnionId, DeclarationInventory
    ../namespace/builtins: CheckedFoundation, ParsedProgram methods
```

These lines are unchanged. **Imports between analysis and code generation do
change.** `emit` gains one level:

```blorp
-- before, src/compile/emit/emit.brp:18
    ../check/model: MatchArmId, DecisionNodeId, ListLengthTest(ExactLength, MinimumLength)
-- after, src/common/codegen/emit/emit.brp:18
    ../../analysis/check/model: MatchArmId, DecisionNodeId, ListLengthTest(ExactLength, MinimumLength)
```

**The path rewrite is a script, run once.** It maps every moved file's old
path to its new one, then rewrites each relative import from the importing
file's new location. That covers `src/`, `test/`,
`scripts/embed_library.brp` and `test_bootstrap.sh`'s fixture paths. It also rewrites repository-relative strings
such as `COMPONENT_SOURCES` in `test/e2e/self_hosted.brp`. The script stays
outside the repository, and its path goes in the handback, so that sessions
with open branches can run it after rebasing.

**The dependency suite,** today (`test/unit/test_format/test_dependencies.brp:25`):

```blorp
private SYNTAX_LAYER: Layer = {
    directory = "blorp/src/syntax",
    allowed = ["blorp/src/syntax", "blorp/src/utils"],
}
```

After the change, it moves to `test/unit/test_layout/test_dependencies.brp`,
because it now governs every directory. `repository_sources.brp` stays in
`test_format/`, which uses it too, and the moved suite imports it from there.
Its layers follow the rules above:

```blorp
private CODEGEN_LAYER: Layer = {
    directory = "blorp/src/common/codegen",
    allowed = [
        "blorp/src/common/codegen",
        "blorp/src/common/analysis",
        "blorp/src/common/syntax",
        "blorp/src/common/utils",
    ],
}
```

**`main.brp` after step 2** keeps only the dispatch, the overview and
`blorp help`:

```blorp
func main(args: List[String]) -> Int:
    match (
        args
            .drop(1)
            .parse_command()
    ):
        Ok(Compile(request)):
            request.compile_request()
        Ok(Format(request)):
            request.format_request()
        Ok(Help(text)):
            print(text)
            0
        Err(usage):
            print_error(usage)
            EXIT_USAGE
```

The function's text is unchanged. What changes is where its callees live:
`compile_request` and `COMPILE_HELP` move to
`compile/compile_command.brp`, `format_request` and `FORMAT_HELP` move to
`format/format_command.brp`, and `EXIT_USAGE` moves to `common/cli/`.

## Scope and non-goals

**Paths that change in step 1:**

| File | Line | What names the old path |
| --- | --- | --- |
| `blorp/Makefile` | 31, 46 | a comment, and the dependency on `src/utils/text.brp` |
| `blorp/test/tooling/test_bootstrap.sh` | 10, 16, 336 | the fixture tree's `blorp/src/utils/text.brp` |
| `blorp/scripts/embed_library.brp` | 21 | its import of that file |
| `blorp/scripts/attribution/patch_emit_markers.py` | 313 | `/compile/emit/emit.brp` |
| `.gitignore` | 80–81 | the `runtime/` exception |
| `.github/workflows/blorp-seed.yml` | 74 | a comment |
| `standard_library/io/_codes.brp`, `io/process.brp` | | comments |
| `test/e2e/self_hosted.brp` | | `COMPONENT_SOURCES` |

**Documents that change:**

- `blorp/README.md`;
- the test-mirror rule in `blorp/AGENTS.md`, which now nests:
  `src/common/<layer>/<name>.brp` is tested in `test/unit/test_common/test_<layer>/`;
- every `blorp/*.md` plan that names a moved path.

`standard_library/README.md` names `src/` only in links to the old
repository, and stays.

**Not in scope:**

- Landed decision records keep their paths,
  because they record the tree as it was;
- any behaviour, name or API change beyond the four choices above;
- the LSP's own modules.

## Risks and unknowns

- **Concurrent branches.** The Bytes session's `PATH_PLAN.md` landings edit
  `runtime/`, `namespace/builtins.brp` and `syntax/parse.brp`. The String,
  process and UInt8 plans queue work in the same places.
  - Step 1 lands at a quiet point agreed with the Bytes session before it
    starts.
  - Git's rename detection carries edits to moved files through a rebase.
  - The rewrite script then fixes the import paths those branches added.
- **`.gitignore`.** Every `runtime/` directory is ignored except the ones
  listed. Moved files stay tracked, but a new file under
  `common/codegen/runtime/` would be silently ignored if lines 80–81 were
  left as they are. A check catches this: `git check-ignore` on a new path
  there prints nothing.
- **The seed.** It builds `blorp/src/main.brp` through relative imports, and
  `scripts/blorp-fixpoint --prove` proves the new tree.
- **Stale paths.** A path missed in a script or document fails late. A
  `git grep` for the old prefixes catches it; see the acceptance criteria.

## Dependencies

- Step 1 needs a quiet point with the Bytes session.
- Step 2 follows step 1.
- Every `LSP_PLAN.md` landing follows step 2. That plan's paths are updated
  in step 1.

## Release strategy

Each step is one squashed commit, gated, reviewed and pushed on its own.
Either one is backed out by reverting it, and open branches then re-run the
rewrite script in reverse.

**Ceilings:**

| Step | Ceiling |
| --- | --- |
| 1 | The self-compile C is byte-identical to its parent's. Production lines are unchanged; only import lines differ. |
| 2 | Self-compile instructions within ±0.2%. Allocations within ±0.01%. At most +40 net production lines, for new module headers and imports; raised to +62 on 2026-11-10, when the headers and imports measured that (see the results). |

## Testing

**Step 1:**

- The dependency suite gains a mutation proof for each rule active in step 1.
  Each case checks that one reported line names the file, the import and the
  layer:
  - a `common/` module importing `compile/`;
  - `common/syntax/` importing `common/analysis/`;
  - `common/analysis/` importing `common/codegen/`.
- Each existing suite moves to its mirror:
  - `test_syntax/` becomes `test_common/test_syntax/`;
  - `test_utils/` becomes `test_common/test_utils/`;
  - `test_compile/test_<phase>/` becomes
    `test_common/test_analysis/test_<phase>/` or
    `test_common/test_codegen/test_<phase>/`;
  - `test_source_walk/` moves into `test_format/`.

**Step 2:**

- The suite gains mutation proofs for the rules that start in step 2:
  - a `format/` module importing `common/analysis/`;
  - one command importing another;
  - a command importing `main.brp`.
- `self_hosted_cli.brp`'s expectations do not change by a byte: help texts,
  usage errors and exit statuses.
- `test_cli/` and `test_main/` move to the mirrors of the new modules.

**Commands for both steps,** in order:

1. `make -C blorp test-target-components TARGET_COMPONENT_SOURCES=<the dependency suite>`
2. `make -C blorp test`
3. `scripts/blorp-fixpoint --prove`
4. `bash blorp/test/tooling/test_bootstrap.sh`
5. `make -C blorp format-check`
6. `gh workflow run blorp.yml --ref <branch>` (branch CI on all four
   platforms)

## Acceptance criteria

- [ ] **Step 1.**
  - `git diff -M --summary` lists only renames for `src/` and `test/`.
  - The self-compile C equals the parent's (`cmp` exits 0).
  - `git grep -nE 'src/(compile|syntax|utils|source_walk)'`
    prints only lines from landed records, and each is listed in the handback.
  - `git check-ignore blorp/src/common/codegen/runtime/new.brp` prints
    nothing.
- [ ] **Step 2.**
  - `main.brp` holds only the dispatch, the overview and `blorp help`.
  - Each command directory imports only itself and `common/`, and the suite
    proves it.
  - The CLI e2e expectations are unchanged.
- [ ] **Both steps** pass every command above, and have code-reviewer and
  test-runner reports.

## Handback

Each step returns:

- its commit;
- the evidence for each criterion;
- for step 1, the rewrite script's path and the list of old-path lines kept
  on purpose;
- for step 2, the measurements.

**Stop and ask** if:

- any analysis module turns out to need code generation;
- the C differs in step 1;
- a behaviour change seems necessary in step 2;
- the Bytes session cannot pause.
