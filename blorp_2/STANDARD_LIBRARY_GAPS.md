# Standard-library dependencies for self-compilation

Snapshot: accepted main `1d02a670027ee05c2e18e0d19cbd22ac64ad23e4`,
2026-10-19. Pending worktrees do not count as implemented. This inventory
supersedes the historical counts in [LIBRARY_PARITY.md](LIBRARY_PARITY.md);
the existing API plans still own implementation and acceptance contracts.

Signed Int update: all 14 called Int APIs and both constants are now declared;
37 called names are present and 28 absent. The source-demand snapshot below is
unchanged; the [numeric report](../benchmarks/results/blorp_2_int_comparisons_2026-10-19.md) records validation.

An [isolated library integration probe](../benchmarks/results/blorp_2_library_namespace_frontier_2026-10-19.md)
has passed namespace and signature checking on the actual compiler source. Its
next failure is the overlapping String receiver on `utils/text.equals`; the
pending cohort is not merged and does not change the accepted API counts below.

The compiler's 41 source modules use **65 resolved library functions at 2,408
distinct call sites**. The target library declares 30 of those names; **35 names
and two Int constants are absent**. Two missing names need source migrations to
the intended APIs, rather than implementations of the old names. Export presence
alone proves neither matching signatures nor successful target compilation.

| Module | Called APIs | Call sites | Names present | Names absent |
| --- | ---: | ---: | ---: | ---: |
| float | 10 | 16 | 3 | 7 |
| int | 14 | 833 | 7 | 7 |
| io | 1 | 4 | 1 | 0 |
| list | 17 | 1,134 | 6 | 11 |
| option | 5 | 204 | 4 | 1 |
| path | 3 | 10 | 1 | 2 |
| result | 4 | 26 | 1 | 3 |
| string | 8 | 178 | 5 | 3 |
| system | 3 | 3 | 2 | 1 |
| **Total** | **65** | **2,408** | **30** | **35** |

## Missing called functions

All functions below are pure except `system.getcwd`. Type letters denote
independent type parameters. Signatures describe host demand; the notes below
identify deliberate bootstrap restrictions and replacement APIs.

| Module | Function and parameter types | Result | Sites |
| --- | --- | --- | ---: |
| float | `abs(Float)` | `Float` | 1 |
| float | `copysign(Float, Float)` | `Float` | 1 |
| float | `equals(Float, Float)` | `Bool` | 1 |
| float | `greater_than_or_equal(Float, Float)` | `Bool` | 2 |
| float | `is_finite(Float)` | `Bool` | 3 |
| float | `is_nan(Float)` | `Bool` | 1 |
| float | `less_than(Float, Float)` | `Bool` | 2 |
| int | `greater_than(Int, Int)` | `Bool` | 70 |
| int | `greater_than_or_equal(Int, Int)` | `Bool` | 20 |
| int | `less_than(Int, Int)` | `Bool` | 57 |
| int | `less_than_or_equal(Int, Int)` | `Bool` | 11 |
| int | `max(Int, Int)` | `Int` | 1 |
| int | `min(Int, Int)` | `Int` | 5 |
| int | `not_equals(Int, Int)` | `Bool` | 8 |
| list | `any(List[T], pure (T) -> Bool)` | `Bool` | 12 |
| list | `contains[T: Equatable](List[T], T)` | `Bool` | 2 |
| list | `filter(List[T], pure (T) -> Bool)` | `List[T]` | 1 |
| list | `get_or(List[T], Int, T)` | `T` | 10 |
| list | `is_empty(List[T])` | `Bool` | 55 |
| list | `join(List[String], String)` | `String` | 13 |
| list | `last(List[T])` | `Option[T]` | 1 |
| list | `map(List[T], pure (T) -> U)` | `List[U]` | 20 |
| list | `remove(List[T], Int)` | `Option[List[T]]` | 2 |
| list | `sort_by[T, K: Orderable](List[T], pure (T) -> K)` | `List[T]` | 3 |
| list | `take(List[T], Int)` | `List[T]` | 2 |
| option | `map(Option[T], pure (T) -> U)` | `Option[U]` | 5 |
| path | `dirname(String)` | `String` | 2 |
| path | `normalize(String)` | `String` | 2 |
| result | `and_then(Result[T, E], pure (T) -> Result[U, E])` | `Result[U, E]` | 4 |
| result | `map(Result[T, E], pure (T) -> U)` | `Result[U, E]` | 14 |
| result | `map_err(Result[T, E], pure (E) -> F)` | `Result[T, F]` | 6 |
| string | `append_int(String, Int)` | `String` | 115 |
| string | `starts_with(String, String)` | `Bool` | 2 |
| string | `substring(String, start: Int, length: Int)` | `String` | 7 |
| system | `getcwd()` | `String` | 1 |

The additional constants are `int.INT_MIN` (emit:191 and parse:858) and
`int.INT_MAX` (utils/source:46 and parse:860): four reads, outside the function
counts. `list.set_index` is imported by `src/own/own.brp:3` but never called.
It exists in the target. Thus List has **17 called APIs**, plus that import-only
dependency: **18 required export names**, 16 called APIs besides `contains`.

## Already declared called functions

These are the remaining 30 names, counted once each:

| Module | Present called APIs |
| --- | --- |
| float | `divide`, `multiply`, `subtract` |
| int | `add`, `divide`, `equals`, `multiply`, `remainder`, `subtract`, `to_string` |
| io | `print_error` |
| list | `append`, `concat`, `get`, `length`, `repeat`, `set` |
| option | `get_or`, `is_none`, `is_some`, `to_result` |
| path | `join` |
| result | `is_ok` |
| string | `add`, `byte_at`, `from_codepoint`, `length`, `parse_float` |
| system | `read_file`, `write_file` |

## Parallel implementation ownership and temporary restrictions

Each row is a separately bounded slice, with its own tests, cost evidence and
two reviews before root integration. Assigned work is not accepted code.

| Owner | Assigned slice | Restrictions and follow-up |
| --- | --- | --- |
| List query/join worker | `get_or`, `is_empty`, `last`, and String-specific `join` | Preserve generic query element types. The [join plan](LIST_JOIN_PLAN.md) documents temporary copying costs; recursive traversal must state its stack limit. |
| List callback/import worker | `any`, `map`, `filter`; compiler Option/Result and IO import closure | Ordinary generic named/forwarded callbacks with explicit stack/copy limits. Import closure adds demanded visibility and five qualified Option.map spellings, with no prelude/control-flow change; pending exports and M7 remain separate. |
| Membership worker | `contains_with` plus `contains` | Ordinary generic binary equality callback, with a temporary Int-only two-argument adapter because the subset excludes traits. The current recursive implementation has linear stack use. Behavior passes; its first cost control failed, so publication is held. [Plan](LIST_CONTAINS_PLAN.md). |
| Numeric worker | Seven Int functions and `INT_MIN`/`INT_MAX` | Int64 is the supported scalar type; this is not a restriction of an otherwise generic collection API. Retain approved numeric cost limits and exact current-main composition checks. |
| Float/sort worker | Seven Float functions; then List `sort_by` | Preserve NaN/signed-zero semantics. Sorting remains generic in element type with temporary Int keys until generic ordering is accepted; stability and recursive copying limits belong beside its signature. |
| Option/Result worker | Four callback helpers | Ordinary generic match implementations. Named and forwarded callbacks suffice for the definitions; compiler clients with lambdas/captures still depend on M7. [Plan](OPTION_RESULT_PLAN.md). |
| Append/take-remove worker | `string.append_int`; then generic List `take`/`remove` | Append uses ordinary `int.to_string` and String concatenation; its approved caps require explicit Numeric composition. Keep collection element types generic and traversal/copy limits explicit. |
| Slice/path/migration worker | Checked String `slice`, `starts_with`, `path.dirname`/`normalize`; compiler substring/current-directory migrations | Declare slicing/API dependencies. Preserve checked byte bounds and meaningful Result propagation; lexical paths need no Path carrier or filesystem abstraction. State recursive stack/copy limits. |
| Root integration | Independent reviews, resource gates and final composition | Workers own the slices above; delegation does not grant implementation, budget acceptance or publication. |

`substring(start, length)` and `slice(start, end)` have different parameters and
failure behavior. The [source plan](BOOTSTRAP_SOURCE_PLAN.md#string-and-library-boundary)
requires half-open byte offsets, scalar-boundary checks and `Option[String]`.
Do not add both public forms. The directory replacement returns
`Result[String, String]`, so the loader must propagate a meaningful failure.

Target prelude methods come only from int, float, string and list. Existing
Option/Result exports therefore still require explicit imports in compiler
modules. Four `print_error` calls in `src/main.brp` also need an explicit IO
import; the host prelude currently supplies it. API presence does not close
these visibility gaps or the remaining loop/lambda language requirements.

Temporary limitations belong beside the implementation and in its API docs,
with the intended general form and the condition for replacing the limitation.
Do not label a naturally concrete API temporary merely because it accepts Int,
Float or String. No host-library additions are assigned by this inventory.

## Method and evidence

One FRESH host compilation against explicit `standard_library/src` dumped Core
after lowering. Original source-function bodies were walked; call `def_id`s were
joined to declarations whose module origin is `stdlib`. UFCS, aliases and trait
operators resolve to the same declaration. All 2,408 `(def_id, full source span)`
pairs are distinct: 1,331 direct and 1,077 selected-trait calls. Actual host
declaration headers supplied names/signatures; no mangled-name inference was used.

All 620 calls lacking a declaration ID were checked: 566 propagation builtins,
52 verified user constructors, one local callback and one synthetic exit-status
call. No additional library function references occur outside call positions.
All 125 compiler global initializers are literals. Three runtime modules contain
only String globals; runtime Float/String modules also have literal-return
functions, giving five files without calls. Constants and import-only selections
were checked separately. An independent reviewer reproduced the counts.

The target export catalog covers all 11 modules: 38 public functions, eight
owned types, six constructors and no public constants. Its 12 files, compiler
41 and host-library 91 inputs were checked against the retained pins/current Git.
The dump's two textual headers were removed before JSON decoding.

Local raw evidence and all call sites remain under ignored
`build/bootstrap-evidence/stdlib-accounting-2026-10-19/`, including
`RESOLVED_API_ACCOUNTING.json` and `TARGET_PUBLIC_DECLARATIONS.json`.
Raw dump SHA256:
`79c9a505eb5099afbe33ed3fb978f1fcb27754d587d78b611cf232e33a41909b`.
This is dependency accounting, not a successful self-compilation claim.
