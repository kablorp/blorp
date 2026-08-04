(** Test Runner for blorp

    Handles test discovery, doctest extraction, test execution (sequential
    and parallel), and result reporting. Extracted from the CLI to keep
    blorp.ml focused on command dispatch. *)

type test_result = {
  file : string;
  passed : bool;
  duration : float;
  output : string;
  error_detail : string;
}
(** Result of running a single test *)

type timing_phase =
  | TestDiscovery
  | HarnessPlanning
  | HarnessPipeline
  | HarnessExecution

type timing_event = {
  timing_phase : timing_phase;
  timing_group : string;
  timing_suite_count : int;
  timing_source_count : int;
  timing_duration_ms : int;
}
(** Stable accounting event emitted by generated TestSuite compilation. *)

val format_timing_event : timing_event -> string
(** Format an event for logs consumed by [scripts/test --timings]. *)

type session_counters = {
  discovered_runnable_files : int;
  unique_discovered_runnable_source_identities : int;
  retained_runnable_source_bytes : int;
  declared_test_suites : int;
  path_policy_process_isolated_files : int;
  path_policy_filesystem_isolated_files : int;
  planned_combined_run_all_harnesses : int;
  planned_combined_selector_harnesses : int;
  planned_combined_suite_files : int;
  planned_combined_native_executions : int;
  planned_individual_source_files : int;
  ocaml_host_invocations : int;
}
(** Session-local structural totals using the Blorp-owned counter protocol. *)

val format_session_counter : session_counters -> string
(** Format session totals for benchmark and migration-accounting consumers. *)

(** Test mode for --doc / --suite filtering *)
type test_mode = TestAll | DocOnly | SuiteOnly

type test_execution_isolation =
  | SharedTestProcess
  | FreshTestProcess of string
  | FreshTestFilesystem of string
(** Process and filesystem isolation required for a discovered test path. The
    fresh variants retain the matched policy root. *)

val execution_isolation : string -> test_execution_isolation
(** Classify a relative or absolute test path using the production isolation
    policy. Exposed for focused path-policy tests. *)

val session_counters_for_test_paths :
  ?sanitize:bool ->
  ?mode:test_mode ->
  leak_check:bool ->
  string list ->
  session_counters
(** Discover runnable files using production classification and return the
    structural and option-sensitive plan totals that would be emitted for those
    files. *)

type sanitizer_mode =
  | SanitizerOff
  | SanitizerAddressUndefined
  | SanitizerUndefinedOnly

val sanitizer_mode_of_string : string -> sanitizer_mode option
(** Parse CLI/env sanitizer mode values. *)

val sanitizer_enabled : sanitizer_mode -> bool
(** Whether the mode emits any sanitizer instrumentation. *)

val sanitizer_mode_to_cli_value : sanitizer_mode -> string
(** Serialize a sanitizer mode for the production Blorp CLI boundary. *)

val run_tests :
  ?profile:bool ->
  ?debug:bool ->
  ?sanitize:bool ->
  ?sanitizer_mode:sanitizer_mode ->
  ?leak_check:bool ->
  ?mode:test_mode ->
  timeout:int option ->
  ?jobs:int ->
  ?cache:bool ->
  ?repeat:int ->
  ?compiler_path:string ->
  ?std_dir:string ->
  string ->
  int
(** Run tests: dispatches to sequential or parallel based on job count.
    [cache] is retained for compatibility with the Blorp-owned test planner.
    The OCaml fallback does not cache individual results because external
    compilation does not yet return a transitive dependency manifest. *)

val run_tests_paths :
  ?profile:bool ->
  ?debug:bool ->
  ?sanitize:bool ->
  ?sanitizer_mode:sanitizer_mode ->
  ?leak_check:bool ->
  ?mode:test_mode ->
  timeout:int option ->
  ?jobs:int ->
  ?cache:bool ->
  ?repeat:int ->
  ?compiler_path:string ->
  ?std_dir:string ->
  string list ->
  int
(** Run tests across multiple file/directory roots as one combined file set.
    [cache] is retained for compatibility with the Blorp-owned test planner.
    The OCaml fallback does not cache individual results because external
    compilation does not yet return a transitive dependency manifest. *)

(* Utilities also used by the CLI *)

val run_process_timeout : timeout:int option -> string -> string list -> int
(** Run a program directly with timeout, inheriting stdin/stdout/stderr.
    Returns exit code (124 = timed out). For interactive use (blorp run). *)

val run_process_capture_timeout :
  ?cwd:string ->
  ?env:(string * string) list ->
  ?progress_marker:string ->
  ?progress_count:int ->
  timeout:int option ->
  string ->
  string list ->
  int * string
(** Run a program directly with timeout, capturing stdout+stderr. When a
    progress marker is supplied, only ordered, paired stderr records of the form
    [MARKER INDEX BEGIN|END ...] reset the deadline. [progress_count] bounds the
    accepted indexes when supplied. Other output and malformed, repeated, or
    out-of-order records do not reset it. Returns exit code 124 on timeout. *)

val with_run_artifacts : (unit -> 'a) -> 'a
(** Run [f] with a process-local mutable artifact root.
    Nested calls reuse the current root. The root is deleted on normal exit. *)

val with_production_compiler :
  ?compiler_path:string -> ?std_dir:string -> (unit -> 'a) -> 'a
(** Scope calls that compile synthetic source through the production Blorp
    executable. Nested scopes restore the previous compiler configuration. *)

val compile_source_to_executable :
  ?debug:bool ->
  ?sanitize:bool ->
  ?sanitizer_mode:sanitizer_mode ->
  ?leak_check:bool ->
  ?release:bool ->
  logical_path:string ->
  source:string ->
  output_path:string ->
  unit ->
  (unit, string) result
(** Compile supplied source through the production Blorp pipeline while
    retaining [logical_path] for module resolution and diagnostics. *)

val run_artifact_path : kind:string -> prefix:string -> suffix:string -> string
(** Allocate a unique mutable artifact path under the active run root. *)

val run_compilation_dir : unit -> string
(** Allocate a per-run directory for one compile/link/run lifecycle. *)

val has_top_level_main_source : string -> bool
(** True when source contains an actual top-level [func main(...)] declaration.
    This intentionally ignores generated-program snippets inside strings. *)

val source_mentions_doctests : string -> bool
(** True when a docstring block contains a [doctests:] section. Escaped source
    snippets in parser tests do not make the containing file a doctest. *)

(* ============================================================================
   Doctest extraction + source mapping

   Exposed for targeted unit tests that guard the synthetic→original
   line-number source map. The CLI drives the whole [run_doctests] flow;
   these surfaces exist so individual stages can be verified in
   isolation without a filesystem round-trip.
   ============================================================================ *)

type doctest_group = {
  dtg_func_name : string;
  dtg_description : string;
  dtg_imports : string list;
  dtg_code : string;
  dtg_code_origins : int list;
}
(** A single doctest group extracted from a docstring. See .ml file
    for the detailed contract on [dtg_code_origins]. *)

type doctest_source_origin = { original_file : string; original_line : int }
(** Original source identity for one generated doctest line. *)

type doctest_source_map = (int, doctest_source_origin) Hashtbl.t
(** Synthetic-source line → original-file + line. *)

val extract_doctests_from_doc :
  ?doc_start_line:int -> string -> string -> doctest_group list
(** Extract doctest groups from a docstring.

    [~doc_start_line] is the 1-based line of the docstring's first
    content line in the original source (defaults to 1 for callers
    that don't care about origin tracking). Each returned group
    carries a [dtg_code_origins] list parallel to its code lines. *)

val find_docstring_start_line : string -> int -> int option
(** Find the source-file line where a docstring's first content line
    lives, given the [decl_line] that a parsed decl's [decl_loc.line]
    reports. Returns [None] when the expected [---] / doc / [---] /
    decl shape isn't found above [decl_line]. Exposed for unit tests
    that pin the parser-position behavior this function depends on —
    parser changes shift where [$symbolstartpos] points and this
    scan's assumption has to track them. *)

val generate_doctest_program_with_map :
  source_path:string ->
  source_text:string ->
  Ast.program ->
  string * doctest_source_map
(** Generate a synthetic doctest program + its source map.

    [~source_path] names the original source file (embedded in remap
    entries). [~source_text] is the original source text; used to
    locate each docstring's start line via a backward scan from
    [decl_loc.line] for the opening [---] marker.

    Tests that don't want to construct a real source string can call
    [extract_doctests_from_doc] + [generate_doctest_program_with_map]
    directly. *)

val generate_suite_selector_harness : ?leak_check:bool -> string list -> string
(** Generate a multi-suite harness that imports each test file once and
    dispatches one selected suite per process via argv[0]. Exposed for tests. *)

val generate_suite_run_all_harness :
  ?progress_marker:string -> string list -> string
(** Generate a multi-suite harness that imports each test file once and runs
    ordinary suites through generated suite functions. Exposed for tests. *)

val suite_run_all_results_from_streams :
  ?progress_marker:string ->
  elapsed:float ->
  string list ->
  stdout_output:string ->
  stderr_output:string ->
  test_result list option
(** Decode ordered stdout result framing and associate stderr diagnostics using
    the independent suite heartbeat stream. Exposed for protocol tests. *)

val group_by_source_size_budget :
  max_source_bytes:int ->
  source_size:('a -> int) ->
  'a list ->
  'a list list
(** Partition items stably by accumulated source work. An item larger than the
    budget forms a one-item group; no item is dropped or reordered. *)

val combined_harness_source_budget_bytes : sanitize:bool -> int
(** Source-work budget for a combined suite harness. Sanitized harnesses use a
    smaller budget because instrumentation materially increases their generated
    code size and execution cost. *)
