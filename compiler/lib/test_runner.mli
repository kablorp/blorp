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

type sanitizer_mode =
  | SanitizerOff
  | SanitizerAddressUndefined
  | SanitizerUndefinedOnly

val sanitizer_mode_of_string : string -> sanitizer_mode option
(** Parse CLI/env sanitizer mode values. *)

val sanitizer_mode_to_string : sanitizer_mode -> string
(** Stable display/cache string for a sanitizer mode. *)

val sanitizer_enabled : sanitizer_mode -> bool
(** Whether the mode emits any sanitizer instrumentation. *)

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
  string ->
  int
(** Run tests: dispatches to sequential or parallel based on job count *)

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
  string list ->
  int
(** Run tests across multiple file/directory roots as one combined file set. *)

(* Utilities also used by the CLI *)

val run_process_timeout : timeout:int option -> string -> string list -> int
(** Run a program directly with timeout, inheriting stdin/stdout/stderr.
    Returns exit code (124 = timed out). For interactive use (blorp run). *)

val run_process_capture_timeout :
  ?cwd:string ->
  ?env:(string * string) list ->
  timeout:int option ->
  string ->
  string list ->
  int * string
(** Run a program directly with timeout, capturing stdout+stderr.
    Returns exit code 124 on timeout. *)

val with_run_artifacts : (unit -> 'a) -> 'a
(** Run [f] with a process-local mutable artifact root.
    Nested calls reuse the current root. The root is deleted on normal exit. *)

val run_artifact_path : kind:string -> prefix:string -> suffix:string -> string
(** Allocate a unique mutable artifact path under the active run root. *)

val run_compilation_dir : unit -> string
(** Allocate a per-run directory for one compile/link/run lifecycle. *)

val sanitizer_cc_args : sanitizer_mode -> string list
(** Compiler flags for the selected sanitizer mode. *)

val cc_is_clang : bool Lazy.t
(** Whether the system C compiler is Clang (vs GCC). Lazy-evaluated. *)

val has_raylib_import : unit -> bool
(** Check if raylib was imported after a pipeline compile run. *)

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

val generate_suite_run_all_harness : string list -> string
(** Generate a multi-suite harness that imports each test file once and runs
    ordinary suites through generated suite functions. Exposed for tests. *)

val requires_filesystem_isolation : string -> bool
(** True when a test path is configured for isolated process filesystem state. *)

val requires_process_isolation : string -> bool
(** True when a test path is configured to stay out of aggregate run-all
    harnesses because it exercises process-global runtime state. *)

val requires_compilation_isolation : string -> bool
(** True only when a test path cannot safely share a compiled selector harness.
    Execution isolation alone does not imply recompiling the test program. *)

val source_text_matches_current_file : string -> string option -> bool
(** True when cached source text, if supplied, still matches the current file
    contents. Used to avoid saving cache entries for stale classified source. *)

val raylib_linker_flags : unit -> string
(** Platform-specific linker flags for raylib *)

(** Runtime TLS backend selected for compiling and linking the C runtime.
    [TlsUnsupported] is the portable default. [TlsOpenSsl] selects the native
    OpenSSL backend profile and requires discoverable or explicitly configured
    OpenSSL compiler and linker arguments. *)
type tls_backend_profile = TlsUnsupported | TlsOpenSsl

val configured_tls_backend_profile :
  unit -> (tls_backend_profile, string) result
(** Parse BLORP_TLS_BACKEND. Missing/empty values select [TlsUnsupported]. *)

val current_tls_backend_profile : unit -> tls_backend_profile
(** Current parsed TLS backend profile, raising [Invalid_argument] if
    BLORP_TLS_BACKEND is set to an unsupported value. *)

val tls_backend_profile_to_string : tls_backend_profile -> string
(** Stable name used in runtime cache manifests. *)

val tls_backend_link_cc_args : tls_backend_profile -> string list
(** Linker arguments required by the selected TLS backend. OpenSSL arguments
    come from BLORP_OPENSSL_LIBS when set, otherwise pkg-config. *)

val tls_backend_runtime_cc_args : tls_backend_profile -> string list
(** C compiler defines required when embedding/compiling the runtime source for
    the selected TLS backend. OpenSSL include arguments come from
    BLORP_OPENSSL_CFLAGS when set, otherwise pkg-config. *)

type precompiled = {
  runtime_obj : string;
  header_file : string;
  pch_file : string option;
  tls_backend : tls_backend_profile;
}
(** Precompiled artifacts for fast compilation *)

val precompile_runtime :
  ?sanitize:bool ->
  ?sanitizer_mode:sanitizer_mode ->
  ?opt:string ->
  unit ->
  precompiled option
(** Precompile runtime.o and header to a persistent content-addressed cache.
    Returns cached artifacts only after verifying their manifest hashes.
    @param opt Optimization level string (default "O0", use "O2" for release) *)

val compile_c_from_stdin : string -> string -> string list -> int * string
(** Compile C code piped via stdin. Returns (exit_code, compiler_output). *)
