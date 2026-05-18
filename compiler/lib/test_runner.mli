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

(** Test mode for --doc / --suite filtering *)
type test_mode = TestAll | DocOnly | SuiteOnly

val run_tests :
  ?profile:bool ->
  ?debug:bool ->
  ?sanitize:bool ->
  ?leak_check:bool ->
  ?mode:test_mode ->
  timeout:int option ->
  ?jobs:int ->
  ?cache:bool ->
  string ->
  int
(** Run tests: dispatches to sequential or parallel based on job count *)

val collect_test_files : string list -> string list
(** Collect valid .brp test files from one or more file/directory roots,
    preserving root order. *)

val run_tests_paths :
  ?profile:bool ->
  ?debug:bool ->
  ?sanitize:bool ->
  ?leak_check:bool ->
  ?mode:test_mode ->
  timeout:int option ->
  ?jobs:int ->
  ?cache:bool ->
  string list ->
  int
(** Run tests across multiple file/directory roots as one combined file set. *)

(* Utilities also used by the CLI *)

val run_process_timeout : timeout:int option -> string -> string list -> int
(** Run a program directly with timeout, inheriting stdin/stdout/stderr.
    Returns exit code (124 = timed out). For interactive use (blorp run). *)

val run_process_capture_timeout :
  timeout:int option -> string -> string list -> int * string
(** Run a program directly with timeout, capturing stdout+stderr.
    Returns exit code 124 on timeout. *)

val with_run_artifacts : (unit -> 'a) -> 'a
(** Run [f] with a process-local mutable artifact root.
    Nested calls reuse the current root. The root is deleted on normal exit
    unless BLORP_KEEP_ARTIFACTS=1 is set. *)

val current_run_artifact_root : unit -> string
(** Current run artifact root, creating one if needed. Exposed for tests and
    callers that need to place generated binaries under the active run. *)

val run_artifact_path : kind:string -> prefix:string -> suffix:string -> string
(** Allocate a unique mutable artifact path under the active run root. *)

val run_compilation_dir : unit -> string
(** Allocate a per-run directory for one compile/link/run lifecycle. *)

val sanitize_cc_args : string list
(** Sanitizer compiler flags (list form) *)

val cc_is_clang : bool Lazy.t
(** Whether the system C compiler is Clang (vs GCC). Lazy-evaluated. *)

val has_raylib_import : unit -> bool
(** Check if raylib was imported (must be called after Pipeline.compile) *)

val has_top_level_main_source : string -> bool
(** True when source contains an actual top-level [func main(...)] declaration.
    This intentionally ignores generated-program snippets inside strings. *)

(* ============================================================================
   Doctest extraction + loc remapping

   Exposed for targeted unit tests that guard the synthetic→original
   line-number remap. The CLI drives the whole [run_doctests] flow;
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

type loc_remap_entry = { original_file : string; original_line : int }
(** Provenance entry in the synthetic→original loc remap table. *)

type loc_remap_table = (int, loc_remap_entry) Hashtbl.t
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

val remap_loc : loc_remap_table -> Ast.loc -> Ast.loc
(** Remap a loc through a synthetic→original table. Returns the input
    unchanged when the loc's [line] has no entry in the table (it
    points into generator-owned scaffolding). [end_line] is remapped
    independently — a multi-line error span preserves its height when
    both endpoints have origin entries. *)

val generate_doctest_program_with_map :
  source_path:string ->
  source_text:string ->
  Ast.program ->
  string * loc_remap_table
(** Generate a synthetic doctest program + its loc remap table.

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

val raylib_linker_flags : unit -> string
(** Platform-specific linker flags for raylib *)

type precompiled = {
  runtime_obj : string;
  header_file : string;
  pch_file : string option;
}
(** Precompiled artifacts for fast compilation *)

val precompile_runtime :
  ?sanitize:bool -> ?opt:string -> unit -> precompiled option
(** Precompile runtime.o and header to a persistent content-addressed cache.
    Returns cached artifacts only after verifying their manifest hashes.
    @param opt Optimization level string (default "O0", use "O2" for release) *)

val compile_c_from_stdin : string -> string -> string list -> int * string
(** Compile C code piped via stdin. Returns (exit_code, compiler_output). *)
