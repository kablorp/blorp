# Loader and shell source integration

Draft for root and independent compiler/test review. Planning base is accepted
main `a9ea383cff354be0d3bd24639d9f614ffeb017ce`, in the separate owned branch
`codex/loader-shell-integration-plan`. No source edit or compiled job is claimed.
The original-R0 SOURCE cost hold remains: neither these drafts nor a library
feature's acceptance authorize source-cost acceptance, a substitute baseline or
a new epoch. Library feature acceptance and source migration stay separate.

The maintained authorities are [the seven shell/path contracts](ROADMAP.md#seven-shell-and-path-functions),
[library parity](LIBRARY_PARITY.md) and [the source plan](BOOTSTRAP_SOURCE_PLAN.md).
Statuses below describe this accepted planning base, not another worker's draft.

## Current ownership and gaps

| Actual caller or requirement | Accepted target readiness | Smallest remaining action and owner |
| --- | --- | --- |
| `load/load.brp:306` queries `system.getcwd() -> String` | `system.get_current_directory() -> Result[String,String]` exists, with matching host API and accepted native ownership/error contract | Replace this one legacy call/import; query once before module identities; translate Err to a compiler-source failure with an empty source inventory. This plan owns the source edit. |
| `load/load.brp:161` reads module text | `system.read_file(String) -> Result[String,String]` exists under the same name/signature | Preserve this direct call and current failure context. Preserve exact counted UTF-8, CRLF/BOM/NUL contents and malformed-encoding rejection; no new read abstraction. |
| `main.brp:150` publishes generated C | `system.write_file(String,String) -> Result[Void,String]` exists under the same name/signature | Preserve the existing relative output path and explicit Result match; no normalization carrier, atomic-write policy or retry. |
| `main.brp` usage/load/check/write errors call bare `print_error` | Concrete target `io.print_error(String) -> Void` exists; host provides the matching String instantiation | Add explicit `io: print_error`; no final reliance on the host prelude or generic target traits. |
| `load/load.brp` uses `Path.join`, including `library_layout`'s trailing separator | No `path.brp` in this accepted target library | Path owner has an ordinary join candidate, not acceptance in this base. Consume only its separately accepted module; preserve absolute-child and empty-child behavior. |
| `import_path` uses `Path.dirname`; `library_layout`/root loading use `Path.normalize` | Both target functions are absent | Exact missing ordinary path leaves. Path owner is planning them separately; coordinate through root. Do not copy Char/split/take-based host bodies or create a filesystem policy layer. |
| `module_role` uses `path.starts_with(contents.prefix)`; `utils/text.equals` also calls host `starts_with` | No target String prefix API; no source writer assigned | Add first-order `Text.starts_with(String,String) -> Bool` over accepted `byte_at`, `length`, Int equality/add and ordinary source control. Route these two source calls to it. Proposed ownership is this plan, subject to root's file assignment. |
| Main diagnostic locations use `IntOps.less_than`; loader parent traversal uses `IntOps.greater_than` | Target Int exports equality/arithmetic/formatting, not these ordering names | Exact missing signed-Int leaves. Sorter owns the readiness map, no implementation is assigned. Root must assign the bounded machine-operation slice; no arithmetic approximation here. |
| `string.slice(String,Int,Int) -> Option[String]` | Absent from accepted host/target libraries at this base | Slice app `01a14aed-bbe4-7681-9765-b5a86f9d282e` owns it. Needed by proposed bounded path extraction, not by the first CWD migration or byte prefix leaf. No unchecked substring fallback. |
| `main.brp:126` and `load/load.brp:341` join diagnostic/cycle Strings | Target `List[String].join` is absent | ListJoin owner `source_port_refresh` has the candidate. Its reported full-gate allocation failure `11514 > 11500` remains failed/held; do not assume availability or widen its cap. |
| Loader uses `.is_none`, `.get_or`, `.to_result` | No accepted operation modules in this base | Option/Result feature owns the five ordinary functions. Its source-import migration follows feature acceptance and separate SOURCE review; never copy unaccepted bodies into this branch. |
| `main.render_file_location` uses two `"".append_int(...)` calls | Target append_int remains unaccepted after its failed shared caps | Later bounded main edit can use accepted `IntOps.to_string` plus existing concat at these two sites. This does not erase the remaining compiler-wide append_int inventory or its historical failure. |
| Main pure pipeline uses `result.map_err`; competing diagnostic notes use List.map | Callback APIs are not in the first-order target surface | Later explicit Result matches / a local note loop, under the source plan and its cost hold. No generic mapping wrapper or callback dispatcher. Compilation and rendering remain pure. |
| `main(args)` matches five List/String literal positions | List/String pattern source migration remains a separate bootstrap dependency | Preserve the current CLI while staging IO integration. Any later indexed rewrite uses the existing List length/get APIs and reviewed source-pattern rules, not a new argument schema or driver. |

Accepted adapters do not mean the complete compiler source already loads/checks
under the target. Ordinary loop, opaque/managed-control and remaining source
dependencies retain their existing milestone owners and gates.

## First source slice: fallible CWD and explicit stderr import

Only `src/load/load.brp`, `src/main.brp` and their existing test owners change.
Proposed physical ceilings: production20 gross/+20 net, tests120 gross/+120 net,
implementation docs10. These are review proposals, not an inherited-budget waiver.
Commit the reviewed plan before code; source acceptance remains held at original R0.

Make the error-context conversion one ordinary pure fact producer, directly
testable with Ok/Err data. It performs no filesystem operation and adds no loader
entrypoint, callback provider, hidden configuration or fallback:

```blorp
pure func working_directory_result(result: Result[String, String]) -> Result[String, LoadFailure]:
    match result:
        Ok(directory): Ok(directory)
        Err(error):
            Err(failure([], rejection(
                { source = compiler_source(), start = 0, end = 0 },
                Text.concat("could not determine current directory: ", error),
                "run the compiler from an accessible working directory",
            )))
```

The loader's existing public entrypoint then begins:

```blorp
-- import system: get_current_directory, read_file
func load_program(root_path: String, library_root: String) -> Result[LoadedProgram, LoadFailure]:
    working_directory ?= working_directory_result(get_current_directory())
    layout = library_layout(Path.join(working_directory, library_root))
    -- existing root normalization, requests, loading and sealing follow unchanged
```

Main adds only `io: print_error` to its imports in this slice. It retains
`main(args: List[String]) -> Int`, its existing five-element CLI match, `compile`,
diagnostic rendering, `publish` and relative output path. The CWD projection
does not repeat the native path/UTF-8 validation or manufacture a SourceFile row.
The sole CWD query occurs before any source identity or file read.

Exact tests in existing owners must cover the projection's Ok bytes (including
spaces/UTF-8), Err source=`compiler_source()`, span0..0, note=None, empty sources,
the complete message/help above, and ordinary rendering as a compiler diagnostic.
This is a data-boundary test, not claimed execution of an OS CWD failure. Existing
native get_current_directory error oracles retain that leaf coverage; do not add
an injectable filesystem provider merely to force it through load_program.

Use the existing import/CLI harness and actual compiler entrypoint for two explicit
process CWDs, including a space/UTF-8 directory. Supply a relative library root,
relative input and relative output; check actual output location, exact generated
C and status0 with empty stdout/stderr. Check wrong argument shape/flag, missing
input/library, parse/check rejection and missing output parent: status1, empty
stdout, exact useful stderr and preserved preexisting output before publication.
Use native leaf tests and direct loader String inputs for NUL-path rejection;
an OS argv cannot carry an embedded NUL. Never confuse NUL contents with NUL paths.
Reuse malformed-UTF-8, CRLF/BOM/NUL-content and byte-column tests already owned by
file admission, loading and main. Publication may leave partial output on IO failure.

## Next bounded source slices

After the first slice and explicit root assignment, implement the missing
`Text.starts_with` leaf in `src/utils/text.brp` and route module-role/equality
consumers to it. Empty prefix is true; a longer/mismatching prefix is false;
UTF-8/NUL bytes compare exactly. Read with safe byte_at, use no String allocation
per byte, Char, slice fallback or signed-Int substitute. Direct source tests name
empty/short/equal/mismatched/Unicode/NUL cases and loader containment boundaries
`/library/` versus `/library-extra/`. Ordinary source loop readiness remains an
explicit dependency of eventual target-source acceptance. Propose this slice's
separate LOC bound and SOURCE gates before editing; it is not part of production20.

After separately accepted Path leaves and library helpers land, update only the
needed explicit imports and verify normalized logical module identity, relative
parents, roots, duplicate reads, cycles, and library/user containment. Preserve
the original request spelling for the root's displayed path. Path operations
remain pure and lexical, preserving counted NUL text; OS boundaries reject NUL
before opening. Do not add realpath/symlink lookup, chdir, directory listing,
metadata, subprocess calls, checkout discovery or compile-time source locations.

Later main-only first-order cleanup can replace its two diagnostic append_int
sites with to_string/concat and its exact callback sites with direct matches/a
local loop. Preserve first-error ordering, every note's source identity and byte
columns. CLI pattern migration is a separately reviewed source-shape slice.
No body rewrite makes a missing library function accepted by declaration alone.

## Review, evidence and stop

Root plus independent compiler/code-reviewer and test-runner review the plan and
each bounded code slice. Root coordinates Path/Slice/ListJoin/Sorter overlaps and
serialized compiled lanes. No feature budget stacks into another feature or
source migration. Preserve Option/Result and append worktrees/evidence; no archive.

Use coordinator-named source-matched functional artifacts and explicit host
library selection for functional checks. A normal-main success, a diagnostic
pilot counter or a library FEATURE verdict does not discharge original-R0 SOURCE
cost acceptance. No SOURCE baseline, artifact-role substitution or measurement
campaign is selected here. If a required leaf, language shape, exact error oracle,
LOC bound or original cost contract is unavailable, return that precise blocker
and bounded follow-up; do not broaden the shell or silently accept a partial M6.
